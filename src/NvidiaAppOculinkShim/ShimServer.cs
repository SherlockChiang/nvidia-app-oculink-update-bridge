using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace NvidiaAppOculinkShim;

internal sealed class ShimServer(ShimConfig config)
{
    private const string BrowserOrigin = "https://nvfile";
    private const string UpstreamOrigin = "https://gfwsl.geforce.com";
    private static readonly HashSet<string> AllowedMethods =
        new(StringComparer.Ordinal) { "GET", "HEAD", "POST", "OPTIONS" };
    private static readonly string[] AllowedControllerPrefixes =
    [
        "/nvidia_web_services/controller.gfeclientcontent.NG.php/",
        "/nvidia_web_services/controller.driverinstallercontent.NG.php/",
        "/nvidia_web_services/controller.gfeclientaffinity.php/",
        "/nvidia_web_services/controller.gfeclientvrs.php/",
    ];
    private static readonly string[] ForwardedHeaders =
    [
        "Accept", "Accept-Language", "Cache-Control", "Content-Type", "Cookie",
        "Authorization", "User-Agent", "Telemetry", "ot-tracer-sampled",
        "ot-tracer-spanid", "ot-tracer-traceid", "traceparent", "tracestate",
        "baggage", "x-request-id",
    ];

    private readonly JsonLineLog _log = new(config.RuntimeDirectory);
    private readonly HttpClient _httpClient = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
    })
    {
        Timeout = TimeSpan.FromSeconds(30),
    };

    public async Task RunAsync(Action started, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(config.RuntimeDirectory);
        var pidPath = Path.Combine(config.RuntimeDirectory, "shim.pid");
        var listener = new TcpListener(IPAddress.Loopback, config.Port);
        listener.Start();
        await File.WriteAllTextAsync(pidPath, Environment.ProcessId.ToString(), cancellationToken);
        _log.Write("server-start", new { port = config.Port, pid = Environment.ProcessId, version = 4 });
        started();

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken);
                _ = HandleClientSafelyAsync(client, cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            listener.Stop();
            File.Delete(pidPath);
            _log.Write("server-stop");
        }
    }

    private async Task HandleClientSafelyAsync(TcpClient client, CancellationToken serviceToken)
    {
        using (client)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(serviceToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(35));
            var startedAt = Environment.TickCount64;
            try
            {
                client.NoDelay = true;
                var stream = client.GetStream();
                var request = await HttpWire.ReadRequestAsync(stream, timeout.Token);
                if (request is null)
                    return;
                await HandleRequestAsync(stream, request, startedAt, timeout.Token);
            }
            catch (Exception exception)
            {
                _log.Write("request-error", new
                {
                    durationMs = Environment.TickCount64 - startedAt,
                    message = exception.ToString(),
                });
                try
                {
                    await WriteJsonAsync(client.GetStream(), null, 502, "Bad Gateway",
                        new { error = "NVIDIA metadata relay failed" }, false, timeout.Token);
                }
                catch
                {
                }
            }
        }
    }

    private async Task HandleRequestAsync(
        NetworkStream stream,
        WireRequest request,
        long startedAt,
        CancellationToken cancellationToken)
    {
        var headOnly = request.Method == "HEAD";
        if (!AllowedMethods.Contains(request.Method))
        {
            await WriteJsonAsync(stream, request, 405, "Method Not Allowed",
                new { error = "Method not allowed" }, headOnly, cancellationToken,
                new Dictionary<string, string> { ["Allow"] = "GET, HEAD, POST, OPTIONS" });
            return;
        }

        var tokenPrefix = "/" + config.Token + "/";
        if (!request.Target.StartsWith(tokenPrefix, StringComparison.Ordinal))
        {
            await WriteJsonAsync(stream, request, 404, "Not Found",
                new { error = "Not found" }, headOnly, cancellationToken);
            return;
        }

        var relativeTarget = request.Target[tokenPrefix.Length..];
        var queryIndex = relativeTarget.IndexOf('?');
        var rawPath = "/" + (queryIndex >= 0 ? relativeTarget[..queryIndex] : relativeTarget);
        var rawQuery = queryIndex >= 0 ? relativeTarget[queryIndex..] : "";

        if (rawPath == "/health")
        {
            await WriteJsonAsync(stream, request, 200, "OK", new
            {
                status = "ok",
                version = 4,
                port = config.Port,
                upstream = UpstreamOrigin,
                pid = Environment.ProcessId,
                browserOrigin = BrowserOrigin,
            }, headOnly, cancellationToken);
            return;
        }

        if (!IsPermittedMetadataPath(rawPath))
        {
            await WriteJsonAsync(stream, request, 404, "Not Found",
                new { error = "Only NVIDIA metadata controller endpoints are permitted" },
                headOnly, cancellationToken);
            return;
        }

        request.Headers.TryGetValue("Origin", out var origin);
        if (origin is not null && origin != BrowserOrigin)
        {
            await WriteJsonAsync(stream, request, 403, "Forbidden",
                new { error = "Browser origin is not permitted" },
                headOnly, cancellationToken);
            return;
        }

        if (request.Method == "OPTIONS")
        {
            request.Headers.TryGetValue("Access-Control-Request-Method", out var requestedMethod);
            if (origin != BrowserOrigin ||
                requestedMethod is not ("GET" or "HEAD" or "POST"))
            {
                await WriteJsonAsync(stream, request, 403, "Forbidden",
                    new { error = "CORS preflight is not permitted" },
                    false, cancellationToken);
                return;
            }

            var headers = CorsHeaders(request, true);
            await HttpWire.WriteResponseAsync(stream, 204, "No Content", headers,
                ReadOnlyMemory<byte>.Empty, false, cancellationToken);
            _log.Write("cors-preflight", new
            {
                status = 204,
                durationMs = Environment.TickCount64 - startedAt,
                requestedMethod,
            });
            return;
        }

        var rewrite = DriverRequestRewriter.Rewrite(rawPath);
        using var upstreamRequest = new HttpRequestMessage(
            new HttpMethod(request.Method), UpstreamOrigin + rewrite.Path + rawQuery);
        foreach (var header in ForwardedHeaders)
        {
            if (header == "Content-Type")
                continue;
            if (request.Headers.TryGetValue(header, out var value))
                upstreamRequest.Headers.TryAddWithoutValidation(header, value);
        }
        if (request.Method == "POST")
        {
            upstreamRequest.Content = new ByteArrayContent(request.Body);
            if (request.Headers.TryGetValue("Content-Type", out var contentType))
                upstreamRequest.Content.Headers.TryAddWithoutValidation("Content-Type", contentType);
        }

        using var upstream = await _httpClient.SendAsync(
            upstreamRequest, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        const int maximumResponseLength = 8 * 1024 * 1024;
        if (upstream.Content.Headers.ContentLength > maximumResponseLength)
            throw new InvalidDataException("NVIDIA metadata response is too large");
        byte[] body;
        if (request.Method == "HEAD")
        {
            body = [];
        }
        else
        {
            await using var upstreamStream =
                await upstream.Content.ReadAsStreamAsync(cancellationToken);
            using var received = new MemoryStream();
            var buffer = new byte[64 * 1024];
            while (true)
            {
                var count = await upstreamStream.ReadAsync(buffer, cancellationToken);
                if (count == 0)
                    break;
                if (received.Length + count > maximumResponseLength)
                    throw new InvalidDataException("NVIDIA metadata response is too large");
                received.Write(buffer, 0, count);
            }
            body = received.ToArray();
        }

        var responseHeaders = CorsHeaders(request, false);
        responseHeaders["Content-Type"] =
            upstream.Content.Headers.ContentType?.ToString() ?? "application/json";
        foreach (var name in new[] { "ETag", "x-request-id" })
        {
            if (upstream.Headers.TryGetValues(name, out var values))
                responseHeaders[name] = values.First();
        }
        await HttpWire.WriteResponseAsync(stream, (int)upstream.StatusCode,
            upstream.ReasonPhrase ?? "Upstream", responseHeaders, body, headOnly, cancellationToken);
        _log.Write("metadata-relay", new
        {
            status = (int)upstream.StatusCode,
            durationMs = Environment.TickCount64 - startedAt,
            method = request.Method,
            route = rewrite.Route,
            browserOrigin = origin,
            changed = rewrite.Changed,
            before = rewrite.Before,
            after = rewrite.After,
        });
    }

    private static bool IsPermittedMetadataPath(string path) =>
        path.Length <= 128 * 1024 &&
        !path.Contains('\\') &&
        !path.Contains('\0') &&
        !path.Contains("%2f", StringComparison.OrdinalIgnoreCase) &&
        !path.Contains("%5c", StringComparison.OrdinalIgnoreCase) &&
        !path.Split('/').Contains("..") &&
        AllowedControllerPrefixes.Any(prefix =>
            path.StartsWith(prefix, StringComparison.Ordinal));

    private static Dictionary<string, string> CorsHeaders(
        WireRequest? request,
        bool preflight)
    {
        var headers = new Dictionary<string, string>
        {
            ["Cache-Control"] = "no-store",
        };
        if (request is null ||
            !request.Headers.TryGetValue("Origin", out var origin) ||
            origin != BrowserOrigin)
            return headers;

        headers["Access-Control-Allow-Origin"] = BrowserOrigin;
        headers["Access-Control-Allow-Credentials"] = "true";
        headers["Vary"] = preflight
            ? "Origin, Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network"
            : "Origin";
        if (!preflight)
        {
            headers["Access-Control-Expose-Headers"] = "ETag, X-Request-ID";
            return headers;
        }

        headers["Access-Control-Allow-Methods"] = "GET, HEAD, POST, OPTIONS";
        headers["Access-Control-Max-Age"] = "600";
        if (request.Headers.TryGetValue("Access-Control-Request-Headers", out var requestedHeaders) &&
            requestedHeaders.Length > 0)
            headers["Access-Control-Allow-Headers"] = requestedHeaders;
        if (request.Headers.TryGetValue("Access-Control-Request-Private-Network", out var pna) &&
            string.Equals(pna, "true", StringComparison.OrdinalIgnoreCase))
            headers["Access-Control-Allow-Private-Network"] = "true";
        return headers;
    }

    private static Task WriteJsonAsync(
        NetworkStream stream,
        WireRequest? request,
        int status,
        string reason,
        object body,
        bool headOnly,
        CancellationToken cancellationToken,
        Dictionary<string, string>? additionalHeaders = null)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body));
        var headers = CorsHeaders(request, false);
        headers["Content-Type"] = "application/json; charset=utf-8";
        if (additionalHeaders is not null)
            foreach (var pair in additionalHeaders)
                headers[pair.Key] = pair.Value;
        return HttpWire.WriteResponseAsync(
            stream, status, reason, headers, bytes, headOnly, cancellationToken);
    }
}

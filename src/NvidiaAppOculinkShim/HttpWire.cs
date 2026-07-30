using System.Net;
using System.Net.Sockets;
using System.Text;

namespace NvidiaAppOculinkShim;

internal sealed record WireRequest(
    string Method,
    string Target,
    IReadOnlyDictionary<string, string> Headers,
    byte[] Body);

internal static class HttpWire
{
    private const int MaximumHeaderLength = 64 * 1024;
    private const int MaximumBodyLength = 256 * 1024;

    public static async Task<WireRequest?> ReadRequestAsync(
        NetworkStream stream,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        using var received = new MemoryStream();
        var headerEnd = -1;

        while (headerEnd < 0)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken);
            if (count == 0)
                return null;
            received.Write(buffer, 0, count);
            if (received.Length > MaximumHeaderLength)
                throw new InvalidDataException("HTTP request headers are too large");
            headerEnd = FindHeaderEnd(received.GetBuffer(), checked((int)received.Length));
        }

        var all = received.ToArray();
        var headerText = Encoding.ASCII.GetString(all, 0, headerEnd);
        var lines = headerText.Split("\r\n", StringSplitOptions.None);
        var requestLine = lines[0].Split(' ', 3);
        if (requestLine.Length != 3 || !requestLine[2].StartsWith("HTTP/1.", StringComparison.Ordinal))
            throw new InvalidDataException("Malformed HTTP request line");

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var separator = line.IndexOf(':');
            if (separator <= 0)
                throw new InvalidDataException("Malformed HTTP header");
            headers[line[..separator].Trim()] = line[(separator + 1)..].Trim();
        }

        if (headers.TryGetValue("Transfer-Encoding", out var transferEncoding) &&
            !string.Equals(transferEncoding, "identity", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Chunked request bodies are not supported");

        var contentLength = 0;
        if (headers.TryGetValue("Content-Length", out var lengthText) &&
            (!int.TryParse(lengthText, out contentLength) ||
             contentLength is < 0 or > MaximumBodyLength))
            throw new InvalidDataException("Invalid HTTP request body length");

        var body = new byte[contentLength];
        var bodyOffset = headerEnd + 4;
        var alreadyRead = Math.Min(contentLength, all.Length - bodyOffset);
        Array.Copy(all, bodyOffset, body, 0, alreadyRead);
        var offset = alreadyRead;
        while (offset < body.Length)
        {
            var count = await stream.ReadAsync(body.AsMemory(offset), cancellationToken);
            if (count == 0)
                throw new EndOfStreamException("HTTP request body ended early");
            offset += count;
        }

        return new WireRequest(requestLine[0], requestLine[1], headers, body);
    }

    public static async Task WriteResponseAsync(
        NetworkStream stream,
        int status,
        string reason,
        IReadOnlyDictionary<string, string> headers,
        ReadOnlyMemory<byte> body,
        bool headOnly,
        CancellationToken cancellationToken)
    {
        var builder = new StringBuilder()
            .Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n");
        foreach (var (name, value) in headers)
            builder.Append(name).Append(": ").Append(value).Append("\r\n");
        builder.Append("Content-Length: ").Append(body.Length).Append("\r\n")
            .Append("Connection: close\r\n\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(builder.ToString()), cancellationToken);
        if (!headOnly && body.Length > 0)
            await stream.WriteAsync(body, cancellationToken);
    }

    private static int FindHeaderEnd(byte[] bytes, int length)
    {
        for (var index = 0; index <= length - 4; index++)
        {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n' &&
                bytes[index + 2] == '\r' && bytes[index + 3] == '\n')
                return index;
        }
        return -1;
    }
}


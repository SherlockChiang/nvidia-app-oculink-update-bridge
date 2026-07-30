namespace NvidiaAppOculinkShim;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args.Contains("--self-test", StringComparer.Ordinal))
            return SelfTest.Run();

        var configArgument = Array.IndexOf(args, "--config");
        var configPath = configArgument >= 0 && configArgument + 1 < args.Length
            ? args[configArgument + 1]
            : Path.Combine(AppContext.BaseDirectory, "config.json");
        var config = ShimConfig.Load(Path.GetFullPath(configPath));
        var server = new ShimServer(config);

        if (args.Contains("--service", StringComparer.Ordinal))
        {
            var serviceName = GetArgument(args, "--service-name") ??
                "NvidiaAppOculinkShim";
            if (!IsValidServiceName(serviceName))
                throw new ArgumentException("Invalid Windows service name.", nameof(args));
            return WindowsServiceHost.Run(
                serviceName,
                (token, started) => server.RunAsync(started, token));
        }

        using var stop = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            stop.Cancel();
        };
        await server.RunAsync(
            () => Console.WriteLine($"Listening on http://127.0.0.1:{config.Port}/"),
            stop.Token);
        return 0;
    }

    private static string? GetArgument(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        if (index < 0)
            return null;
        if (index + 1 >= args.Length || args[index + 1].StartsWith("--", StringComparison.Ordinal))
            throw new ArgumentException($"Missing value for {name}.", nameof(args));
        return args[index + 1];
    }

    private static bool IsValidServiceName(string value)
    {
        if (value.Length is < 1 or > 80)
            return false;
        return value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '_' or '-' or '.');
    }
}

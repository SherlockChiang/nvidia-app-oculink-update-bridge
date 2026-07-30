using System.Text.Json;

namespace NvidiaAppOculinkShim;

internal sealed record ShimConfig(int Port, string Token, string RuntimeDirectory)
{
    public static ShimConfig Load(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        var config = new ShimConfig(
            root.GetProperty("port").GetInt32(),
            root.GetProperty("token").GetString() ?? "",
            root.GetProperty("runtimeDirectory").GetString() ?? "");

        if (config.Port is not 80 && config.Port is < 1024 or > 65535)
            throw new InvalidDataException("port must be 80 or between 1024 and 65535");
        if (config.Token.Length is < 32 or > 128 ||
            config.Token.Any(character => !Uri.IsHexDigit(character)))
            throw new InvalidDataException("token must contain 32-128 hexadecimal characters");
        if (!Path.IsPathFullyQualified(config.RuntimeDirectory))
            throw new InvalidDataException("runtimeDirectory must be an absolute path");

        return config;
    }
}


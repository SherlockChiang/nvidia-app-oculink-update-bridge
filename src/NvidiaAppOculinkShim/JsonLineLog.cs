using System.Text.Json;

namespace NvidiaAppOculinkShim;

internal sealed class JsonLineLog(string runtimeDirectory)
{
    private readonly object _gate = new();
    private readonly string _path = Path.Combine(runtimeDirectory, "shim.log");

    public void Write(string eventName, object? fields = null)
    {
        try
        {
            lock (_gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                if (File.Exists(_path) && new FileInfo(_path).Length > 5 * 1024 * 1024)
                {
                    File.Move(_path, _path + ".1", true);
                }

                var entry = new Dictionary<string, object?>
                {
                    ["time"] = DateTimeOffset.UtcNow,
                    ["event"] = eventName,
                };
                if (fields is not null)
                {
                    foreach (var property in fields.GetType().GetProperties())
                        entry[property.Name] = property.GetValue(fields);
                }
                File.AppendAllText(_path, JsonSerializer.Serialize(entry) + Environment.NewLine);
            }
        }
        catch
        {
            // Diagnostics must never interrupt NVIDIA App update discovery.
        }
    }
}


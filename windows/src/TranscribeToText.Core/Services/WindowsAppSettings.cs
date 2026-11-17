using System.Text.Json;

namespace TranscribeToText.Core.Services;

public sealed record WindowsAppSettings
{
    public string EngineBackend { get; init; } = "cpu";
    public string DefaultModelId { get; init; } = "large-v3-turbo";
    public string DefaultLanguage { get; init; } = "auto";
    public bool DetectSpeakersByDefault { get; init; }
    public bool MeetingDetectionEnabled { get; init; }
    public bool CaptureMicrophone { get; init; } = true;
    public bool CaptureSystemAudio { get; init; } = true;
}

public sealed class WindowsAppSettingsStore
{
    private readonly string _path;
    private static readonly object Gate = new();

    public WindowsAppSettingsStore(WindowsAppPaths? paths = null)
    {
        _path = Path.Combine((paths ?? new WindowsAppPaths()).Root, "settings.json");
    }

    public WindowsAppSettings Load()
    {
        lock (Gate)
        {
            if (!File.Exists(_path)) return new WindowsAppSettings();
            try
            {
                return JsonSerializer.Deserialize<WindowsAppSettings>(File.ReadAllBytes(_path))
                    ?? new WindowsAppSettings();
            }
            catch (JsonException)
            {
                return new WindowsAppSettings();
            }
            catch (IOException)
            {
                return new WindowsAppSettings();
            }
        }
    }

    public void Save(WindowsAppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var backend = settings.EngineBackend.ToLowerInvariant();
        if (backend is not ("cpu" or "cuda" or "vulkan" or "auto"))
            throw new ArgumentOutOfRangeException(nameof(settings), "The engine backend must be CPU, CUDA, Vulkan, or Auto.");

        lock (Gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(settings with { EngineBackend = backend },
                    new JsonSerializerOptions { WriteIndented = true }));
                File.Move(temporary, _path, overwrite: true);
            }
            finally
            {
                try { File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}

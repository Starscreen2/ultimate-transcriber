namespace TranscribeToText.Core.Services;

public sealed class EnginePaths
{
    private readonly string _baseDirectory;
    private readonly string _backend;

    public EnginePaths(string? baseDirectory = null, string backend = "cpu")
    {
        _baseDirectory = baseDirectory ?? AppContext.BaseDirectory;
        _backend = backend.ToLowerInvariant();
        if (_backend is not ("cpu" or "cuda" or "vulkan" or "auto"))
        {
            throw new ArgumentOutOfRangeException(nameof(backend), "Backend must be cpu, cuda, vulkan, or auto.");
        }
    }

    public string Backend => _backend;

    public string Require(string executableName)
    {
        var path = Find(executableName);
        if (path is null)
        {
            throw new FileNotFoundException(
                $"The {executableName} engine is missing. Reinstall the app or select an engine folder in Settings.");
        }
        return path;
    }

    public string? Find(string executableName)
    {
        var backends = _backend switch
        {
            "auto" => new[] { "cuda", "vulkan", "cpu" },
            "cpu" => new[] { "cpu" },
            _ => new[] { _backend, "cpu" }
        };
        var candidates = backends.Select(backend =>
                Path.Combine(_baseDirectory, "engines", backend, executableName))
            .Append(Path.Combine(_baseDirectory, "engines", executableName))
            .Append(Path.Combine(_baseDirectory, executableName))
            .ToArray();
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate)) return candidate;
        }

        var pathValue = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(pathValue)) return null;
        foreach (var directory in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(directory.Trim(), executableName);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    public string? FindOnBackend(string executableName, string backend)
    {
        var candidate = Path.Combine(_baseDirectory, "engines", backend.ToLowerInvariant(), executableName);
        return File.Exists(candidate) ? candidate : null;
    }
}

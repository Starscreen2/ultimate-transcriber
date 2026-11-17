using System.IO.Compression;
using System.Text;
using System.Text.Json;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;

if (args.FirstOrDefault() == "--engine-runner-child")
{
    Console.WriteLine("runner stdout line");
    Console.Error.WriteLine("runner stderr line");
    return 0;
}

var checks = new List<(string Name, Func<Task> Run)>
{
    ("Mac model catalog", TestModelCatalog),
    ("SRT and VTT formatting", TestTranscriptFormatting),
    ("Swift-compatible library JSON", TestLibraryJson),
    ("Whisper archive round-trip", TestWhisperArchiveRoundTrip),
    ("Corrupt library preservation", TestCorruptLibraryPreservation),
    ("Backend engine lookup", TestEnginePaths),
    ("Engine process output capture", TestEngineRunner)
};

var failures = new List<string>();
foreach (var (name, run) in checks)
{
    try
    {
        await run();
        Console.WriteLine($"PASS {name}");
    }
    catch (Exception error)
    {
        failures.Add($"{name}: {error}");
        Console.Error.WriteLine($"FAIL {name}: {error.Message}");
    }
}

if (failures.Count > 0)
{
    Console.Error.WriteLine(string.Join(Environment.NewLine + Environment.NewLine, failures));
    return 1;
}
return 0;

static Task TestModelCatalog()
{
    Assert(ModelCatalog.TranscriptionModels.Count == 12, "Expected the twelve Mac Whisper model choices.");
    Assert(ModelCatalog.TranscriptionModels.Any(model => model.Id == "large-v3-turbo"), "Turbo model is missing.");
    Assert(ModelCatalog.VadModel.FileName == "ggml-silero-v6.2.0.bin", "VAD model name changed.");
    Assert(ModelCatalog.SummaryModel.FileName == "Qwen3-4B-Q4_K_M.gguf", "Summary model name changed.");
    Assert(ModelCatalog.SpeakerEmbeddingModel.FileName.EndsWith(".onnx", StringComparison.Ordinal), "Expected ONNX speaker model.");
    return Task.CompletedTask;
}

static Task TestTranscriptFormatting()
{
    var parsed = TranscriptExportService.ParseSrt("""
        1
        00:00:01,250 --> 00:00:02,500
        Hello there.

        2
        00:01:00,000 --> 00:01:03,100
        Second line.
        """);
    Assert(parsed.Count == 2, "Expected two parsed segments.");
    Assert(Math.Abs(parsed[0].Start - 1.25) < 0.0001, "First start time changed.");
    Assert(parsed[1].Text == "Second line.", "Segment text changed.");
    Assert(TranscriptExportService.ToSrt(parsed).Contains("00:00:01,250 --> 00:00:02,500", StringComparison.Ordinal), "SRT timestamp is incorrect.");
    Assert(TranscriptExportService.ToWebVtt(parsed).StartsWith("WEBVTT\n\n", StringComparison.Ordinal), "VTT header is missing.");
    return Task.CompletedTask;
}

static Task TestLibraryJson()
{
    const string swiftDateJson = """
        [
          {
            "id": "9f39ef80-3c49-4f89-a381-77cfc92cdd22",
            "title": "demo.wav",
            "sourcePath": "C:\\\\Media\\\\demo.wav",
            "outputBasePath": "C:\\\\Media\\\\demo",
            "folderPath": "C:\\\\Media",
            "modelID": "large-v3-turbo",
            "language": "auto",
            "duration": 4.5,
            "createdAt": 815000000,
            "updatedAt": 815000000,
            "kind": "meeting",
            "segments": [
              {
                "id": "7d1961a2-8797-4a58-bf09-966f1ac6b9bc",
                "start": 1.25,
                "end": 2.5,
                "text": "Hello",
                "speakerID": 0,
                "isFavorite": false,
                "startsNewParagraph": false,
                "isUneven": false
              }
            ],
            "speakerNames": { "0": "Speaker 1" },
            "isDeleted": false,
            "summaryTranscriptDigest": null
          }
        ]
        """;
    var options = TranscriptJson.CreateOptions();
    var entry = JsonSerializer.Deserialize<List<WorkspaceLibraryEntry>>(swiftDateJson, options)!.Single();
    Assert(entry.Kind == WorkspaceRecordKind.Meeting, "Swift enum value was not decoded.");
    Assert(entry.SpeakerNames[0] == "Speaker 1", "Integer speaker key was not decoded.");
    Assert(entry.Segments.Single().SpeakerId == 0, "Segment speaker ID was not decoded.");
    Assert(entry.CreatedAt == DateTimeOffset.FromUnixTimeSeconds(1_793_307_200), "Swift reference-date value was not decoded.");

    var written = JsonSerializer.SerializeToUtf8Bytes(new[] { entry }, options);
    using var document = JsonDocument.Parse(written);
    var root = document.RootElement[0];
    Assert(root.GetProperty("createdAt").ValueKind == JsonValueKind.Number, "Date should remain Swift-compatible numeric JSON.");
    Assert(root.GetProperty("kind").GetString() == "meeting", "Enum should remain Swift-compatible lowercase JSON.");
    Assert(root.GetProperty("segments")[0].TryGetProperty("speakerID", out _), "speakerID JSON key changed.");
    return Task.CompletedTask;
}

static async Task TestWhisperArchiveRoundTrip()
{
    var directory = Path.Combine(Path.GetTempPath(), "TranscribeToText-Core-Test", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    try
    {
        var mediaPath = Path.Combine(directory, "meeting.wav");
        var archivePath = Path.Combine(directory, "meeting.whisper");
        await File.WriteAllBytesAsync(mediaPath, [0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03]);
        var segments = new[]
        {
            new TranscriptSegment
            {
                Start = 1.125,
                End = 2.875,
                Text = "A cross-platform archive.",
                SpeakerId = 0,
                IsFavorite = true,
                IsUneven = true
            }
        };
        var archiveService = new WhisperArchiveService();
        await archiveService.ExportAsync(mediaPath, segments, new Dictionary<int, string> { [0] = "Avery" },
            "large-v3-turbo", "auto", archivePath);
        var imported = await archiveService.ImportAsync(archivePath, Path.Combine(directory, "imports"));

        Assert(imported.Title == "meeting.wav", "Archive media name changed.");
        Assert(imported.ModelId == "large-v3-turbo", "Archive model ID changed.");
        Assert(imported.SpeakerNames.Values.Single() == "Avery", "Archive speaker name changed.");
        Assert(imported.Segments.Single().SpeakerId == 0, "Archive speaker association changed.");
        Assert(imported.Segments.Single().IsFavorite && imported.Segments.Single().IsUneven, "Archive flags changed.");
        Assert(Math.Abs(imported.Segments.Single().Start - 1.125) < 0.001, "Archive timestamp changed.");
        var importedBytes = await File.ReadAllBytesAsync(imported.MediaPath);
        var originalBytes = await File.ReadAllBytesAsync(mediaPath);
        Assert(importedBytes.SequenceEqual(originalBytes), "Archive media bytes changed.");
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static async Task TestCorruptLibraryPreservation()
{
    var directory = Path.Combine(Path.GetTempPath(), "TranscribeToText-Core-Test", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, "transcriptions.json");
    var original = Encoding.UTF8.GetBytes("{ this is not valid JSON");
    await File.WriteAllBytesAsync(path, original);
    try
    {
        var store = new WorkspaceLibraryStore(path);
        Assert(store.LoadFailure is not null, "Corrupt file should surface a load error.");
        try
        {
            await store.SaveAsync(new WorkspaceLibraryEntry
            {
                Id = Guid.NewGuid(),
                Title = "must not overwrite"
            });
            throw new InvalidOperationException("A corrupt library unexpectedly accepted writes.");
        }
        catch (InvalidOperationException error) when (error.Message.Contains("could not be read", StringComparison.Ordinal))
        {
            // The original unreadable data must remain recoverable.
        }
        Assert((await File.ReadAllBytesAsync(path)).SequenceEqual(original), "Corrupt library data was overwritten.");
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
}

static Task TestEnginePaths()
{
    var root = Path.Combine(Path.GetTempPath(), "TranscribeToText-Core-Test", Guid.NewGuid().ToString("N"));
    var cpu = Path.Combine(root, "engines", "cpu", "whisper-cli.exe");
    var vulkan = Path.Combine(root, "engines", "vulkan", "whisper-cli.exe");
    Directory.CreateDirectory(Path.GetDirectoryName(cpu)!);
    Directory.CreateDirectory(Path.GetDirectoryName(vulkan)!);
    File.WriteAllText(cpu, string.Empty);
    File.WriteAllText(vulkan, string.Empty);
    try
    {
        Assert(new EnginePaths(root, "vulkan").Require("whisper-cli.exe") == vulkan, "Selected backend was not preferred.");
        Assert(new EnginePaths(root, "cuda").Require("whisper-cli.exe") == cpu, "CPU fallback was not selected.");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
    }
    return Task.CompletedTask;
}

static async Task TestEngineRunner()
{
    var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Test executable path is unavailable.");
    var result = await new EngineRunner().RunAsync(executable, ["--engine-runner-child"]);
    Assert(result.ExitCode == 0, "Child process did not exit successfully.");
    Assert(result.StandardOutput.Contains("runner stdout line", StringComparison.Ordinal), "Child stdout was not captured.");
    Assert(result.StandardError.Contains("runner stderr line", StringComparison.Ordinal), "Child stderr was not captured.");
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

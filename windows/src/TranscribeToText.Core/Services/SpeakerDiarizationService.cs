using System.Diagnostics;
using System.Text.RegularExpressions;
using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public sealed record DiarizationResult(
    IReadOnlyList<TranscriptSegment> Segments,
    IReadOnlyDictionary<int, string> SpeakerNames,
    string? Warning);

public sealed partial class SpeakerDiarizationService(
    WindowsAppPaths paths,
    EnginePaths engines,
    ModelDownloadService? downloads = null,
    EngineRunner? runner = null)
{
    [GeneratedRegex(@"(?m)^\s*(\d+(?:\.\d+)?)\s*--\s*(\d+(?:\.\d+)?)\s+speaker[_ ]?(\d+)(?:\s+confidence=[^\s]+)?(?:\s+.*)?\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex TurnLine();

    private readonly ModelDownloadService _downloads = downloads ?? new ModelDownloadService();
    private readonly EngineRunner _runner = runner ?? new EngineRunner();

    public async Task<DiarizationResult> AssignSpeakersAsync(
        string sourcePath,
        IReadOnlyList<TranscriptSegment> segments,
        Action<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var empty = new DiarizationResult(segments, new Dictionary<int, string>(), null);
        try
        {
            var diarizer = engines.Require("sherpa-onnx-offline-speaker-diarization.exe");
            var ffmpeg = engines.Require("ffmpeg.exe");
            progress?.Invoke("Preparing local speaker models…");
            var archive = await _downloads.EnsureInstalledAsync(ModelCatalog.SpeakerSegmentationArchive, paths,
                new Progress<DownloadProgress>(value => ReportDownload(progress, "Speaker segmentation model", value)),
                cancellationToken).ConfigureAwait(false);
            var embedding = await _downloads.EnsureInstalledAsync(ModelCatalog.SpeakerEmbeddingModel, paths,
                new Progress<DownloadProgress>(value => ReportDownload(progress, "Speaker recognition model", value)),
                cancellationToken).ConfigureAwait(false);
            var segmentation = await EnsureSegmentationModelAsync(archive, cancellationToken).ConfigureAwait(false);

            var temp = Path.Combine(Path.GetTempPath(), "TranscribeToText", "diarize-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temp);
            var wavPath = Path.Combine(temp, "audio.wav");
            try
            {
                progress?.Invoke("Preparing audio for speaker labeling…");
                var conversion = await _runner.RunAsync(ffmpeg,
                    ["-hide_banner", "-loglevel", "error", "-y", "-i", sourcePath, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavPath],
                    cancellationToken: cancellationToken).ConfigureAwait(false);
                if (conversion.ExitCode != 0 || !File.Exists(wavPath))
                    throw new InvalidOperationException("FFmpeg could not prepare audio for speaker labeling.");

                progress?.Invoke("Identifying speakers locally…");
                var result = await _runner.RunAsync(diarizer,
                    ["--clustering.cluster-threshold=0.95", "--segmentation.num-threads=4", "--embedding.num-threads=2",
                     $"--segmentation.pyannote-model={segmentation}", $"--embedding.model={embedding}", wavPath],
                    cancellationToken: cancellationToken).ConfigureAwait(false);
                if (result.ExitCode != 0)
                    throw new InvalidOperationException(string.Join(Environment.NewLine,
                        result.StandardError.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).TakeLast(8)));

                var turns = ParseTurns(result.StandardOutput + Environment.NewLine + result.StandardError);
                var assigned = segments.Select(segment =>
                {
                    var overlaps = turns.Select(turn => (turn.SpeakerId,
                            Duration: Math.Max(0, Math.Min(segment.End, turn.End) - Math.Max(segment.Start, turn.Start))))
                        .Where(item => item.Duration > 0)
                        .GroupBy(item => item.SpeakerId)
                        .Select(group => (SpeakerId: group.Key, Duration: group.Sum(item => item.Duration)))
                        .OrderByDescending(item => item.Duration)
                        .FirstOrDefault();
                    return segment with { SpeakerId = overlaps.Duration > 0 ? overlaps.SpeakerId : null };
                }).ToArray();
                var speakerIds = assigned.Where(segment => segment.SpeakerId.HasValue)
                    .Select(segment => segment.SpeakerId!.Value).Distinct().Order().ToArray();
                var names = speakerIds.Select((id, index) => (id, name: $"Speaker {index + 1}"))
                    .ToDictionary(item => item.id, item => item.name);
                return new DiarizationResult(assigned, names, null);
            }
            finally
            {
                try { Directory.Delete(temp, recursive: true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error)
        {
            return empty with { Warning = error.Message };
        }
    }

    private async Task<string> EnsureSegmentationModelAsync(string archivePath, CancellationToken cancellationToken)
    {
        var destinationRoot = Path.Combine(paths.SpeakerModels, "sherpa-onnx-pyannote-segmentation-3-0");
        var expected = Path.Combine(destinationRoot, "model.onnx");
        if (File.Exists(expected) && new FileInfo(expected).Length > 1024) return expected;

        var tar = FindExecutable("tar.exe") ?? throw new FileNotFoundException("Windows tar.exe is required to unpack the speaker model.");
        var temp = Path.Combine(Path.GetTempPath(), "TranscribeToText", "speaker-model-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var listing = await _runner.RunAsync(tar, ["-tjf", archivePath], cancellationToken: cancellationToken).ConfigureAwait(false);
            if (listing.ExitCode != 0) throw new InvalidDataException("The speaker model archive could not be listed.");
            foreach (var member in listing.StandardOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
            {
                var normalized = member.Replace('\\', '/');
                if (normalized.StartsWith("/", StringComparison.Ordinal) || normalized.Split('/').Any(part => part == ".."))
                    throw new InvalidDataException("The speaker model archive contains an unsafe path.");
            }
            var extracted = await _runner.RunAsync(tar, ["-xjf", archivePath, "-C", temp], cancellationToken: cancellationToken)
                .ConfigureAwait(false);
            if (extracted.ExitCode != 0) throw new InvalidDataException("The speaker model archive could not be extracted.");
            var model = Directory.EnumerateFiles(temp, "model.onnx", SearchOption.AllDirectories)
                .FirstOrDefault(file => new FileInfo(file).Length > 1024)
                ?? throw new InvalidDataException("The speaker segmentation model file is missing from its archive.");
            Directory.CreateDirectory(destinationRoot);
            File.Copy(model, expected, overwrite: true);
            return expected;
        }
        finally
        {
            try { Directory.Delete(temp, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static IReadOnlyList<(double Start, double End, int SpeakerId)> ParseTurns(string output) =>
        TurnLine().Matches(output).Select(match =>
        {
            var start = double.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
            var end = double.Parse(match.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture);
            var speaker = int.Parse(match.Groups[3].Value, System.Globalization.CultureInfo.InvariantCulture);
            return (Start: start, End: end, SpeakerId: speaker);
        }).Where(turn => double.IsFinite(turn.Start) && double.IsFinite(turn.End) && turn.End > turn.Start).ToArray();

    private static void ReportDownload(Action<string>? progress, string model, DownloadProgress value)
    {
        var percentage = value.Fraction is double fraction ? $" {fraction:P0}" : string.Empty;
        progress?.Invoke($"Downloading {model}…{percentage}");
    }

    private static string? FindExecutable(string name)
    {
        var system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), name);
        if (File.Exists(system)) return system;
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path)) return null;
        return path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(directory => Path.Combine(directory.Trim(), name)).FirstOrDefault(File.Exists);
    }
}

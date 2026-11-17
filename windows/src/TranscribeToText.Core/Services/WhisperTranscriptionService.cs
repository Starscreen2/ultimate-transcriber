using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public sealed record TranscriptionResult(
    string SourcePath,
    string OutputBasePath,
    string ModelId,
    string Language,
    IReadOnlyList<TranscriptSegment> Segments,
    string? SpeakerWarning = null,
    IReadOnlyDictionary<int, string>? SpeakerNames = null);

public sealed class WhisperTranscriptionService(
    WindowsAppPaths paths,
    EnginePaths enginePaths,
    ModelDownloadService? downloads = null,
    EngineRunner? runner = null)
{
    private readonly ModelDownloadService _downloads = downloads ?? new ModelDownloadService();
    private readonly EngineRunner _runner = runner ?? new EngineRunner();

    public async Task<TranscriptionResult> TranscribeAsync(
        string mediaPath,
        string modelId = "large-v3-turbo",
        string language = "auto",
        Action<string>? reportProgress = null,
        CancellationToken cancellationToken = default,
        bool detectSpeakers = false,
        string? outputBasePath = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(mediaPath);
        if (!File.Exists(mediaPath)) throw new FileNotFoundException("The selected media file was not found.", mediaPath);

        var model = ModelCatalog.FindTranscriptionModel(modelId);
        var whisper = enginePaths.Require("whisper-cli.exe");
        var ffmpeg = enginePaths.Find("ffmpeg.exe")
            ?? throw new FileNotFoundException(
                "FFmpeg is required to convert common audio and video files. Install FFmpeg or place ffmpeg.exe in the app's engines folder.");

        reportProgress?.Invoke($"Preparing {model.Name}…");
        var modelPath = await _downloads.EnsureInstalledAsync(
            model,
            paths,
            new Progress<DownloadProgress>(value => ReportDownload(reportProgress, model.Name, value)),
            cancellationToken).ConfigureAwait(false);

        reportProgress?.Invoke("Preparing voice activity detection…");
        var vadPath = await _downloads.EnsureInstalledAsync(
            ModelCatalog.VadModel,
            paths,
            new Progress<DownloadProgress>(value => ReportDownload(reportProgress, "Voice activity model", value)),
            cancellationToken).ConfigureAwait(false);

        cancellationToken.ThrowIfCancellationRequested();
        var temporaryDirectory = Path.Combine(Path.GetTempPath(), "TranscribeToText", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporaryDirectory);
        var wavPath = Path.Combine(temporaryDirectory, "normalized-audio.wav");
        var whisperOutputBase = Path.Combine(temporaryDirectory, "transcript");

        try
        {
            reportProgress?.Invoke($"Converting audio from {Path.GetFileName(mediaPath)}…");
            var conversion = await _runner.RunAsync(
                ffmpeg,
                [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", mediaPath,
                    "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                    wavPath
                ],
                onErrorLine: line => reportProgress?.Invoke(line),
                cancellationToken: cancellationToken).ConfigureAwait(false);
            if (conversion.ExitCode != 0 || !File.Exists(wavPath))
            {
                throw new InvalidOperationException(EngineFailure("FFmpeg could not prepare this media file.", conversion));
            }

            reportProgress?.Invoke($"Transcribing with {model.Id}…");
            var threads = Math.Max(4, Environment.ProcessorCount - 2);
            var whisperArguments = new[]
            {
                    "-t", threads.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    "-mc", "0",
                    "-m", modelPath,
                    "-f", wavPath,
                    "-l", NormalizeLanguage(language, model.Id),
                    "-vm", vadPath,
                    "--vad", "-sns",
                    "-of", whisperOutputBase,
                    "-otxt", "-osrt", "-ovtt", "-np"
            };
            var transcription = await RunWithCpuFallbackAsync(
                "whisper-cli.exe",
                whisper,
                whisperArguments,
                line =>
                {
                    if (line.Contains('%') || line.Contains("error", StringComparison.OrdinalIgnoreCase))
                        reportProgress?.Invoke(line.Trim());
                },
                reportProgress,
                cancellationToken).ConfigureAwait(false);

            if (transcription.ExitCode != 0)
            {
                throw new InvalidOperationException(EngineFailure("Whisper could not transcribe this file.", transcription));
            }

            var srtPath = whisperOutputBase + ".srt";
            if (!File.Exists(srtPath))
            {
                throw new InvalidDataException("Whisper finished, but did not produce timestamped transcript output.");
            }
            var srt = await File.ReadAllTextAsync(srtPath, cancellationToken).ConfigureAwait(false);
            var segments = TranscriptExportService.ParseSrt(srt);
            if (segments.Count == 0)
            {
                throw new InvalidDataException("Whisper did not return any transcript segments.");
            }

            cancellationToken.ThrowIfCancellationRequested();
            IReadOnlyDictionary<int, string> speakerNames = new Dictionary<int, string>();
            string? speakerWarning = null;
            if (detectSpeakers)
            {
                var diarization = await new SpeakerDiarizationService(paths, enginePaths, _downloads, _runner)
                    .AssignSpeakersAsync(mediaPath, segments, reportProgress, cancellationToken).ConfigureAwait(false);
                segments = diarization.Segments;
                speakerNames = diarization.SpeakerNames;
                speakerWarning = diarization.Warning;
            }

            cancellationToken.ThrowIfCancellationRequested();
            var outputBase = outputBasePath is null
                ? Path.Combine(Path.GetDirectoryName(Path.GetFullPath(mediaPath))!, Path.GetFileNameWithoutExtension(mediaPath))
                : Path.GetFullPath(outputBasePath);
            Directory.CreateDirectory(Path.GetDirectoryName(outputBase)!);
            await TranscriptExportService.WriteSidecarsAsync(
                outputBase,
                segments,
                speakerNames,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            reportProgress?.Invoke("Transcription complete.");
            return new TranscriptionResult(
                Path.GetFullPath(mediaPath),
                outputBase,
                model.Id,
                NormalizeLanguage(language, model.Id),
                segments,
                speakerWarning,
                speakerNames);
        }
        finally
        {
            try { Directory.Delete(temporaryDirectory, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static string NormalizeLanguage(string language, string modelId)
    {
        if (modelId.EndsWith(".en", StringComparison.OrdinalIgnoreCase)) return "en";
        return string.IsNullOrWhiteSpace(language) ? "auto" : language.Trim();
    }

    private async Task<EngineRunResult> RunWithCpuFallbackAsync(
        string executableName,
        string preferredExecutable,
        IEnumerable<string> arguments,
        Action<string>? onErrorLine,
        Action<string>? reportProgress,
        CancellationToken cancellationToken)
    {
        var cpuExecutable = enginePaths.FindOnBackend(executableName, "cpu");
        var isDifferentCpuBinary = cpuExecutable is not null && !string.Equals(
            Path.GetFullPath(cpuExecutable), Path.GetFullPath(preferredExecutable),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        try
        {
            var result = await _runner.RunAsync(preferredExecutable, arguments, onErrorLine: onErrorLine,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0 || !isDifferentCpuBinary) return result;
            reportProgress?.Invoke($"The {enginePaths.Backend} engine did not start this job successfully; retrying on CPU.");
            return await _runner.RunAsync(cpuExecutable!, arguments, onErrorLine: onErrorLine,
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (System.ComponentModel.Win32Exception) when (isDifferentCpuBinary)
        {
            cancellationToken.ThrowIfCancellationRequested();
            reportProgress?.Invoke($"The {enginePaths.Backend} engine could not be loaded; retrying on CPU.");
            return await _runner.RunAsync(cpuExecutable!, arguments, onErrorLine: onErrorLine,
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
    }

    private static void ReportDownload(Action<string>? reportProgress, string model, DownloadProgress progress)
    {
        var percentage = progress.Fraction is double fraction ? $" {fraction:P0}" : string.Empty;
        reportProgress?.Invoke($"Downloading {model}…{percentage}");
    }

    private static string EngineFailure(string fallback, EngineRunResult result)
    {
        var diagnostic = result.StandardError
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .TakeLast(8);
        var detail = string.Join(Environment.NewLine, diagnostic);
        return string.IsNullOrWhiteSpace(detail) ? fallback : fallback + Environment.NewLine + detail;
    }
}

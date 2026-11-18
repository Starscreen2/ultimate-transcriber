using System.Net.Http;
using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public sealed record DownloadProgress(long BytesReceived, long? TotalBytes)
{
    public double? Fraction => TotalBytes is > 0 ? Math.Clamp((double)BytesReceived / TotalBytes.Value, 0, 1) : null;
}

public sealed class ModelDownloadService(HttpClient? httpClient = null)
{
    private static readonly HttpClient SharedClient = new(new SocketsHttpHandler
    {
        AutomaticDecompression = System.Net.DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(10)
    });

    private readonly HttpClient _httpClient = httpClient ?? SharedClient;

    public bool IsInstalled(ModelDefinition model, WindowsAppPaths paths)
    {
        var path = paths.PathFor(model);
        if (!File.Exists(path)) return false;

        var info = new FileInfo(path);
        if (info.Length < 4) return false;

        Span<byte> header = stackalloc byte[4];
        using var stream = File.OpenRead(path);
        if (stream.Read(header) != header.Length) return false;

        return model.Purpose switch
        {
            ModelPurpose.Transcription or ModelPurpose.VoiceActivityDetection =>
                header.SequenceEqual("lmgg"u8),
            ModelPurpose.MeetingNotes => header.SequenceEqual("GGUF"u8),
            ModelPurpose.SpeakerSegmentation => header.SequenceEqual("BZh"u8[..3]),
            ModelPurpose.SpeakerEmbedding => info.Length > 1_024,
            _ => false
        };
    }

    public async Task<string> EnsureInstalledAsync(
        ModelDefinition model,
        WindowsAppPaths paths,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        paths.EnsureDirectories();
        var destination = paths.PathFor(model);
        if (IsInstalled(model, paths)) return destination;

        if (File.Exists(destination)) File.Delete(destination);
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".download";
        try
        {
            using var response = await _httpClient.GetAsync(
                model.DownloadUri,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();

            var totalBytes = response.Content.Headers.ContentLength;
            await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = new byte[1024 * 128];
            long received = 0;
            int count;
            await using (var output = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                bufferSize: 1024 * 128, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                while ((count = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                    received += count;
                    progress?.Report(new DownloadProgress(received, totalBytes));
                }
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }

            ValidateDownloadedFile(model, temporary);
            File.Move(temporary, destination, overwrite: true);
            return destination;
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    private static void ValidateDownloadedFile(ModelDefinition model, string path)
    {
        var info = new FileInfo(path);
        if (info.Length < 4)
        {
            throw new InvalidDataException($"The downloaded {model.Name} file is empty or incomplete.");
        }

        Span<byte> header = stackalloc byte[4];
        using (var stream = File.OpenRead(path))
        {
            if (stream.Read(header) != header.Length)
            {
                throw new InvalidDataException($"The downloaded {model.Name} file could not be read.");
            }
        }

        var valid = model.Purpose switch
        {
            ModelPurpose.Transcription or ModelPurpose.VoiceActivityDetection => header.SequenceEqual("lmgg"u8),
            ModelPurpose.MeetingNotes => header.SequenceEqual("GGUF"u8),
            ModelPurpose.SpeakerSegmentation => header.SequenceEqual("BZh"u8[..3]),
            ModelPurpose.SpeakerEmbedding => info.Length > 1_024,
            _ => false
        };

        if (!valid)
        {
            throw new InvalidDataException($"The downloaded {model.Name} file did not match its expected format.");
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

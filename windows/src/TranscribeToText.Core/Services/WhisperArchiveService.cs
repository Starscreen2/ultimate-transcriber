using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;
using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public sealed record ImportedWhisperArchive(
    string MediaPath,
    string Title,
    string ModelId,
    string Language,
    IReadOnlyList<TranscriptSegment> Segments,
    IReadOnlyDictionary<int, string> SpeakerNames);

public sealed class WhisperArchiveService
{
    private const string VersionEntry = "version";
    private const string MetadataEntry = "metadata.json";
    private const string AudioEntry = "originalAudio";
    private const string ModelPrefix = "ggml-model-whisper-";
    private const long MaximumMetadataBytes = 32 * 1024 * 1024;

    private readonly JsonSerializerOptions _jsonOptions = TranscriptJson.CreateOptions();

    public async Task ExportAsync(
        string mediaPath,
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyDictionary<int, string> speakerNames,
        string modelId,
        string language,
        string destinationPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(mediaPath);
        if (!File.Exists(mediaPath)) throw new FileNotFoundException("The original media file is not available.", mediaPath);
        if (IsVideo(mediaPath)) throw new NotSupportedException("Whisper archive export currently supports audio files only.");

        var directory = Path.GetDirectoryName(Path.GetFullPath(destinationPath))!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "." + Path.GetFileName(destinationPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            var metadata = CreateMetadata(mediaPath, segments, speakerNames, modelId, language);
            var metadataBytes = JsonSerializer.SerializeToUtf8Bytes(metadata, _jsonOptions);
            await using (var archiveStream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
                1024 * 128, FileOptions.Asynchronous | FileOptions.SequentialScan))
            using (var archive = new ZipArchive(archiveStream, ZipArchiveMode.Create, leaveOpen: false))
            {
                var versionEntry = archive.CreateEntry(VersionEntry, CompressionLevel.NoCompression);
                await using (var stream = versionEntry.Open())
                {
                    await stream.WriteAsync("2"u8.ToArray(), cancellationToken).ConfigureAwait(false);
                }

                var metadataFile = archive.CreateEntry(MetadataEntry, CompressionLevel.NoCompression);
                await using (var stream = metadataFile.Open())
                {
                    await stream.WriteAsync(metadataBytes, cancellationToken).ConfigureAwait(false);
                }

                var mediaEntry = archive.CreateEntry(AudioEntry, CompressionLevel.NoCompression);
                await using var output = mediaEntry.Open();
                await using var input = new FileStream(
                    mediaPath, FileMode.Open, FileAccess.Read, FileShare.Read,
                    1024 * 128, FileOptions.Asynchronous | FileOptions.SequentialScan);
                await input.CopyToAsync(output, 1024 * 128, cancellationToken).ConfigureAwait(false);
            }

            File.Move(temporary, destinationPath, overwrite: true);
        }
        finally
        {
            TryDelete(temporary);
        }
    }

    public async Task<ImportedWhisperArchive> ImportAsync(
        string archivePath,
        string? destinationRoot = null,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(archivePath)) throw new FileNotFoundException("The archive file was not found.", archivePath);

        await using var file = new FileStream(
            archivePath, FileMode.Open, FileAccess.Read, FileShare.Read,
            1024 * 128, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var archive = new ZipArchive(file, ZipArchiveMode.Read, leaveOpen: false);

        var versionData = await ReadMemberAsync(archive, VersionEntry, 32, cancellationToken).ConfigureAwait(false);
        var version = System.Text.Encoding.UTF8.GetString(versionData).Trim();
        if (version is not ("1" or "2"))
        {
            if (version.Length == 0) throw new InvalidDataException("This archive has no version file.");
            throw new NotSupportedException($"Whisper archive version {version} is not supported.");
        }

        var metadataData = await ReadMemberAsync(archive, MetadataEntry, MaximumMetadataBytes, cancellationToken).ConfigureAwait(false);
        var metadata = JsonSerializer.Deserialize<ArchiveMetadata>(metadataData, _jsonOptions)
            ?? throw new InvalidDataException("The archive metadata could not be read.");
        if (metadata.Transcripts.Any(segment => segment.Start < 0 || segment.End < segment.Start))
        {
            throw new InvalidDataException("The archive contains invalid transcript timestamps.");
        }

        var rawName = string.IsNullOrWhiteSpace(metadata.OriginalMediaFilename)
            ? Path.GetFileNameWithoutExtension(archivePath)
            : metadata.OriginalMediaFilename.Trim();
        var titleBase = Path.GetFileName(rawName.Replace('/', Path.DirectorySeparatorChar)
            .Replace('\\', Path.DirectorySeparatorChar));
        if (string.IsNullOrWhiteSpace(titleBase) || titleBase is "." or "..")
        {
            throw new InvalidDataException("The archive contains an invalid media filename.");
        }
        var extension = SanitizeExtension(metadata.OriginalMediaExtension);
        var title = titleBase + "." + extension;
        var targetRoot = destinationRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TranscribeToText", "imported-archives");
        Directory.CreateDirectory(targetRoot);
        var folder = Path.Combine(targetRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var mediaPath = Path.Combine(folder, title);

        try
        {
            var mediaEntry = archive.GetEntry(AudioEntry)
                ?? throw new InvalidDataException("The archive does not contain its original audio.");
            await using var input = mediaEntry.Open();
            await using var output = new FileStream(
                mediaPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                1024 * 128, FileOptions.Asynchronous | FileOptions.SequentialScan);
            await input.CopyToAsync(output, 1024 * 128, cancellationToken).ConfigureAwait(false);
            await output.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            TryDeleteDirectory(folder);
            throw;
        }

        var speakers = (metadata.Speakers ?? [])
            .Concat(metadata.Transcripts.Where(segment => segment.Speaker is not null).Select(segment => segment.Speaker!))
            .GroupBy(speaker => speaker.Id)
            .Select(group => group.First())
            .OrderBy(speaker => speaker.Id.ToString("D"), StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var speakerIndices = speakers.Select((speaker, index) => (speaker.Id, index))
            .ToDictionary(item => item.Id, item => item.index);
        var names = speakers.Select((speaker, index) => (index, speaker.Name))
            .ToDictionary(item => item.index, item => item.Name);
        var segments = metadata.Transcripts.Select(segment =>
        {
            int? speakerId = null;
            if (segment.Speaker is not null && speakerIndices.TryGetValue(segment.Speaker.Id, out var mappedId))
            {
                speakerId = mappedId;
            }

            return new TranscriptSegment
            {
                Id = segment.Id == Guid.Empty ? Guid.NewGuid() : segment.Id,
                Start = segment.Start / 1000d,
                End = segment.End / 1000d,
                Text = segment.Text ?? string.Empty,
                SpeakerId = speakerId,
                IsFavorite = segment.Favorited,
                IsUneven = segment.UnEven
            };
        }).ToArray();
        var modelId = metadata.ModelQualityId?.StartsWith(ModelPrefix, StringComparison.Ordinal) == true
            ? metadata.ModelQualityId[ModelPrefix.Length..]
            : metadata.ModelQualityId ?? "large-v3-turbo";

        return new ImportedWhisperArchive(
            mediaPath,
            title,
            modelId,
            string.IsNullOrWhiteSpace(metadata.ModelLanguageId) ? "auto" : metadata.ModelLanguageId,
            segments,
            names);
    }

    private ArchiveMetadata CreateMetadata(
        string mediaPath,
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyDictionary<int, string> speakerNames,
        string modelId,
        string language)
    {
        var speakerById = segments.Where(segment => segment.SpeakerId.HasValue)
            .Select(segment => segment.SpeakerId!.Value)
            .Distinct()
            .Order()
            .ToDictionary(
                id => id,
                id => new ArchiveSpeaker
                {
                    Id = Guid.NewGuid(),
                    Name = speakerNames.GetValueOrDefault(id) ?? $"Speaker {id + 1}",
                    Color = Math.Abs(id % 8)
                });

        return new ArchiveMetadata
        {
            OriginalMediaFilename = Path.GetFileNameWithoutExtension(mediaPath),
            OriginalMediaExtension = Path.GetExtension(mediaPath).TrimStart('.').ToLowerInvariant(),
            VideoMediaFilename = null,
            VideoMediaExtension = null,
            Transcripts = segments.Select(segment => new ArchiveSegment
            {
                Id = segment.Id,
                Text = segment.Text,
                Start = ToMilliseconds(segment.Start),
                End = ToMilliseconds(segment.End),
                UnEven = segment.IsUneven,
                Favorited = segment.IsFavorite,
                Speaker = segment.SpeakerId is int id && speakerById.TryGetValue(id, out var speaker) ? speaker : null,
                Words = null
            }).ToArray(),
            TranslatedTranscripts = new Dictionary<string, ArchiveSegment[]>(),
            TranslatedFullText = new Dictionary<string, string>(),
            ModelLanguageId = language,
            ModelQualityId = ModelPrefix + modelId,
            ModelEngine = "whisperCPP",
            StartTimeOffset = new ArchiveTimeOffset(),
            DateCreated = DateTimeOffset.UtcNow,
            DateUpdated = DateTimeOffset.UtcNow,
            Speakers = speakerById.OrderBy(pair => pair.Key).Select(pair => pair.Value).ToArray(),
            WasTranslatedToEnglish = false,
            Tags = [],
            DetectedLanguageRaw = language
        };
    }

    private static async Task<byte[]> ReadMemberAsync(
        ZipArchive archive,
        string name,
        long maximumBytes,
        CancellationToken cancellationToken)
    {
        var entry = archive.GetEntry(name)
            ?? throw new InvalidDataException(name == VersionEntry
                ? "This archive has no version file."
                : $"The archive is missing {name}.");
        if (entry.Length > maximumBytes)
        {
            throw new InvalidDataException($"The archive member {name} is larger than expected.");
        }
        await using var stream = entry.Open();
        using var memory = new MemoryStream((int)Math.Min(entry.Length, int.MaxValue));
        await stream.CopyToAsync(memory, 64 * 1024, cancellationToken).ConfigureAwait(false);
        if (memory.Length > maximumBytes)
        {
            throw new InvalidDataException($"The archive member {name} expanded beyond its allowed size.");
        }
        return memory.ToArray();
    }

    private static string SanitizeExtension(string? value)
    {
        var extension = (value ?? "aiff").Trim().TrimStart('.').ToLowerInvariant();
        return extension.Length is >= 1 and <= 10 && extension.All(char.IsAsciiLetterOrDigit)
            ? extension
            : "aiff";
    }

    private static long ToMilliseconds(double seconds)
    {
        if (!double.IsFinite(seconds)) return 0;
        var bounded = Math.Clamp(seconds, 0, long.MaxValue / 1000d);
        return (long)Math.Round(bounded * 1000, MidpointRounding.AwayFromZero);
    }

    private static bool IsVideo(string path) =>
        new[] { ".mov", ".mp4", ".m4v", ".avi", ".mkv", ".webm" }
            .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { Directory.Delete(path, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private sealed class ArchiveMetadata
    {
        [JsonPropertyName("originalMediaFilename")]
        public string? OriginalMediaFilename { get; set; }
        [JsonPropertyName("originalMediaExtension")]
        public string? OriginalMediaExtension { get; set; }
        [JsonPropertyName("videoMediaFilename")]
        public string? VideoMediaFilename { get; set; }
        [JsonPropertyName("videoMediaExtension")]
        public string? VideoMediaExtension { get; set; }
        [JsonPropertyName("transcripts")]
        public ArchiveSegment[] Transcripts { get; set; } = [];
        [JsonPropertyName("translatedTranscripts")]
        public Dictionary<string, ArchiveSegment[]>? TranslatedTranscripts { get; set; }
        [JsonPropertyName("translatedFullText")]
        public Dictionary<string, string>? TranslatedFullText { get; set; }
        [JsonPropertyName("modelLanguageID")]
        public string? ModelLanguageId { get; set; }
        [JsonPropertyName("modelQualityID")]
        public string? ModelQualityId { get; set; }
        [JsonPropertyName("modelEngine")]
        public string? ModelEngine { get; set; }
        [JsonPropertyName("startTimeOffset")]
        public ArchiveTimeOffset? StartTimeOffset { get; set; }
        [JsonPropertyName("dateCreated")]
        public DateTimeOffset? DateCreated { get; set; }
        [JsonPropertyName("dateUpdated")]
        public DateTimeOffset? DateUpdated { get; set; }
        [JsonPropertyName("speakers")]
        public ArchiveSpeaker[]? Speakers { get; set; }
        [JsonPropertyName("wasTranslatedToEnglish")]
        public bool? WasTranslatedToEnglish { get; set; }
        [JsonPropertyName("tags")]
        public ArchiveTag[]? Tags { get; set; }
        [JsonPropertyName("detectedLanguageRaw")]
        public string? DetectedLanguageRaw { get; set; }
    }

    private sealed class ArchiveSpeaker
    {
        [JsonPropertyName("id")]
        public Guid Id { get; set; }
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;
        [JsonPropertyName("color")]
        public int Color { get; set; }
        [JsonPropertyName("emoji")]
        public string? Emoji { get; set; }
    }

    private sealed class ArchiveSegment
    {
        [JsonPropertyName("id")]
        public Guid Id { get; set; }
        [JsonPropertyName("text")]
        public string? Text { get; set; }
        [JsonPropertyName("start")]
        public long Start { get; set; }
        [JsonPropertyName("end")]
        public long End { get; set; }
        [JsonPropertyName("unEven")]
        public bool UnEven { get; set; }
        [JsonPropertyName("favorited")]
        public bool Favorited { get; set; }
        [JsonPropertyName("speaker")]
        public ArchiveSpeaker? Speaker { get; set; }
        [JsonPropertyName("words")]
        public ArchiveWord[]? Words { get; set; }
    }

    private sealed class ArchiveWord
    {
        [JsonPropertyName("text")]
        public string Text { get; set; } = string.Empty;
        [JsonPropertyName("startTime")]
        public long StartTime { get; set; }
        [JsonPropertyName("endTime")]
        public long EndTime { get; set; }
    }

    private sealed class ArchiveTimeOffset
    {
        [JsonPropertyName("hours")]
        public int Hours { get; set; }
        [JsonPropertyName("minutes")]
        public int Minutes { get; set; }
        [JsonPropertyName("seconds")]
        public int Seconds { get; set; }
        [JsonPropertyName("milliseconds")]
        public int Milliseconds { get; set; }
    }

    private sealed class ArchiveTag
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;
        [JsonPropertyName("color")]
        public int Color { get; set; }
    }
}

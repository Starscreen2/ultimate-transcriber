using System.Text.Json;
using System.Text.Json.Serialization;

namespace TranscribeToText.Core.Models;

public enum WorkspaceRecordKind
{
    Transcription,
    Meeting
}

public sealed record TranscriptSegment
{
    [JsonPropertyName("id")]
    public Guid Id { get; init; } = Guid.NewGuid();

    [JsonPropertyName("start")]
    public double Start { get; init; }

    [JsonPropertyName("end")]
    public double End { get; init; }

    [JsonPropertyName("text")]
    public string Text { get; init; } = string.Empty;

    [JsonPropertyName("speakerID")]
    public int? SpeakerId { get; init; }

    [JsonPropertyName("isFavorite")]
    public bool IsFavorite { get; init; }

    [JsonPropertyName("startsNewParagraph")]
    public bool StartsNewParagraph { get; init; }

    [JsonPropertyName("isUneven")]
    public bool IsUneven { get; init; }
}

public sealed record WorkspaceLibraryEntry
{
    [JsonPropertyName("id")]
    public Guid Id { get; init; }

    [JsonPropertyName("title")]
    public string Title { get; init; } = string.Empty;

    [JsonPropertyName("sourcePath")]
    public string SourcePath { get; init; } = string.Empty;

    [JsonPropertyName("outputBasePath")]
    public string OutputBasePath { get; init; } = string.Empty;

    [JsonPropertyName("folderPath")]
    public string FolderPath { get; init; } = string.Empty;

    [JsonPropertyName("modelID")]
    public string ModelId { get; init; } = "large-v3-turbo";

    [JsonPropertyName("language")]
    public string Language { get; init; } = "auto";

    [JsonPropertyName("duration")]
    public double Duration { get; init; }

    [JsonPropertyName("createdAt")]
    public DateTimeOffset CreatedAt { get; init; }

    [JsonPropertyName("updatedAt")]
    public DateTimeOffset UpdatedAt { get; init; }

    [JsonPropertyName("kind")]
    public WorkspaceRecordKind Kind { get; init; }

    [JsonPropertyName("segments")]
    public IReadOnlyList<TranscriptSegment> Segments { get; init; } = [];

    [JsonPropertyName("speakerNames")]
    public IReadOnlyDictionary<int, string> SpeakerNames { get; init; } = new Dictionary<int, string>();

    [JsonPropertyName("isDeleted")]
    public bool IsDeleted { get; init; }

    [JsonPropertyName("summaryTranscriptDigest")]
    public string? SummaryTranscriptDigest { get; init; }

    [JsonIgnore]
    public int WordCount => Segments.Sum(segment =>
        segment.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length);

    [JsonIgnore]
    public int CharacterCount => Segments.Sum(segment => segment.Text.Length);

    [JsonIgnore]
    public string DurationLabel
    {
        get
        {
            var seconds = Math.Max(0, (long)Math.Round(Duration));
            return $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}";
        }
    }

    [JsonIgnore]
    public string LibraryAction => IsDeleted ? "Restore" : "Move to Recently Deleted";
}

public static class TranscriptJson
{
    public static JsonSerializerOptions CreateOptions(bool indented = false)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = false,
            WriteIndented = indented,
            PropertyNamingPolicy = null,
            AllowTrailingCommas = false
        };
        options.Converters.Add(new SwiftDateTimeOffsetConverter());
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }

    // Swift JSONEncoder's default Date strategy stores seconds since 2001-01-01 UTC.
    private sealed class SwiftDateTimeOffsetConverter : JsonConverter<DateTimeOffset>
    {
        private static readonly DateTimeOffset SwiftEpoch =
            new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.Number)
            {
                return SwiftEpoch.AddSeconds(reader.GetDouble());
            }

            if (reader.TokenType == JsonTokenType.String &&
                DateTimeOffset.TryParse(reader.GetString(), out var parsed))
            {
                return parsed.ToUniversalTime();
            }

            throw new JsonException("Expected a Swift date value.");
        }

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
            writer.WriteNumberValue((value.ToUniversalTime() - SwiftEpoch).TotalSeconds);
    }
}

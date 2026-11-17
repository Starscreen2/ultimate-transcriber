using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public static partial class TranscriptExportService
{
    [GeneratedRegex(@"(?m)^\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*$")]
    private static partial Regex TimestampLine();

    public static IReadOnlyList<TranscriptSegment> ParseSrt(string source)
    {
        var normalized = source.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        var blocks = Regex.Split(normalized.Trim(), @"\n[\t ]*\n");
        var results = new List<TranscriptSegment>();

        foreach (var block in blocks)
        {
            var lines = block.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            var timeIndex = Array.FindIndex(lines, line => TimestampLine().IsMatch(line));
            if (timeIndex < 0) continue;

            var match = TimestampLine().Match(lines[timeIndex]);
            if (!TryTimestamp(match, 1, out var start) || !TryTimestamp(match, 5, out var end) || end < start)
                continue;

            var text = string.Join(" ", lines.Skip(timeIndex + 1))
                .Trim();
            if (text.Length == 0) continue;

            results.Add(new TranscriptSegment
            {
                Start = start,
                End = end,
                Text = text
            });
        }

        return results;
    }

    public static string ToPlainText(IEnumerable<TranscriptSegment> segments, IReadOnlyDictionary<int, string>? speakerNames = null)
    {
        var builder = new StringBuilder();
        foreach (var segment in segments)
        {
            if (segment.SpeakerId is int speakerId)
            {
                var name = speakerNames?.GetValueOrDefault(speakerId) ?? $"Speaker {speakerId + 1}";
                builder.Append(name).Append(": ");
            }
            builder.AppendLine(segment.Text);
        }
        return builder.ToString().TrimEnd();
    }

    public static string ToSrt(IEnumerable<TranscriptSegment> segments, IReadOnlyDictionary<int, string>? speakerNames = null)
    {
        var builder = new StringBuilder();
        var index = 1;
        foreach (var segment in segments)
        {
            builder.Append(index++).AppendLine();
            builder.Append(FormatTimestamp(segment.Start)).Append(" --> ")
                .AppendLine(FormatTimestamp(segment.End));
            AppendSpeakerText(builder, segment, speakerNames);
            builder.AppendLine().AppendLine();
        }
        return builder.ToString();
    }

    public static string ToWebVtt(IEnumerable<TranscriptSegment> segments, IReadOnlyDictionary<int, string>? speakerNames = null)
    {
        var builder = new StringBuilder("WEBVTT").AppendLine().AppendLine();
        foreach (var segment in segments)
        {
            builder.Append(FormatTimestamp(segment.Start, '.')).Append(" --> ")
                .AppendLine(FormatTimestamp(segment.End, '.'));
            AppendSpeakerText(builder, segment, speakerNames);
            builder.AppendLine().AppendLine();
        }
        return builder.ToString();
    }

    public static async Task WriteSidecarsAsync(
        string outputBasePath,
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyDictionary<int, string>? speakerNames = null,
        CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(outputBasePath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(outputBasePath + ".txt", ToPlainText(segments, speakerNames), new UTF8Encoding(false), cancellationToken);
        await File.WriteAllTextAsync(outputBasePath + ".srt", ToSrt(segments, speakerNames), new UTF8Encoding(false), cancellationToken);
        await File.WriteAllTextAsync(outputBasePath + ".vtt", ToWebVtt(segments, speakerNames), new UTF8Encoding(false), cancellationToken);
    }

    public static string FormatTimestamp(double seconds, char decimalSeparator = ',')
    {
        if (!double.IsFinite(seconds) || seconds < 0) seconds = 0;
        var milliseconds = checked((long)Math.Round(seconds * 1000, MidpointRounding.AwayFromZero));
        var hours = milliseconds / 3_600_000;
        var minutes = milliseconds / 60_000 % 60;
        var wholeSeconds = milliseconds / 1000 % 60;
        var millis = milliseconds % 1000;
        return string.Create(CultureInfo.InvariantCulture,
            $"{hours:00}:{minutes:00}:{wholeSeconds:00}{decimalSeparator}{millis:000}");
    }

    private static bool TryTimestamp(Match match, int startGroup, out double seconds)
    {
        seconds = 0;
        if (!match.Success ||
            !int.TryParse(match.Groups[startGroup].Value, out var hours) ||
            !int.TryParse(match.Groups[startGroup + 1].Value, out var minutes) ||
            !int.TryParse(match.Groups[startGroup + 2].Value, out var wholeSeconds) ||
            !int.TryParse(match.Groups[startGroup + 3].Value, out var milliseconds))
        {
            return false;
        }

        seconds = hours * 3600d + minutes * 60d + wholeSeconds + milliseconds / 1000d;
        return double.IsFinite(seconds);
    }

    private static void AppendSpeakerText(
        StringBuilder builder,
        TranscriptSegment segment,
        IReadOnlyDictionary<int, string>? speakerNames)
    {
        if (segment.SpeakerId is int speakerId)
        {
            builder.Append('[').Append(speakerNames?.GetValueOrDefault(speakerId) ?? $"Speaker {speakerId + 1}")
                .Append("] ");
        }
        builder.Append(segment.Text);
    }
}

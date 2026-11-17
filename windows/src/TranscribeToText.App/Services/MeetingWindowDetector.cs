using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace TranscribeToText.Windows.Services;

public sealed record MeetingWindowCandidate(string Key, string Provider, string Title, int ProcessId);

public sealed class MeetingWindowDetector
{
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    public IReadOnlyList<MeetingWindowCandidate> Scan()
    {
        var found = new List<MeetingWindowCandidate>();
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window)) return true;
            var length = GetWindowTextLength(window);
            if (length <= 0 || length > 2048) return true;
            var title = new StringBuilder(length + 1);
            GetWindowText(window, title, title.Capacity);
            var text = title.ToString().Trim();
            if (text.Length == 0) return true;

            GetWindowThreadProcessId(window, out var processId);
            if (processId == 0) return true;
            try
            {
                using var process = Process.GetProcessById((int)processId);
                var provider = DetectProvider(process.ProcessName, text);
                if (provider is not null)
                    found.Add(new MeetingWindowCandidate($"{processId}:{provider}", provider, text, (int)processId));
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            return true;
        }, IntPtr.Zero);
        return found.GroupBy(candidate => candidate.Key, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First()).ToArray();
    }

    private static string? DetectProvider(string processName, string title)
    {
        var process = processName.ToLowerInvariant();
        var text = title.ToLowerInvariant();
        var hasMeetingTerm = text.Contains("meeting", StringComparison.Ordinal) ||
                             text.Contains("call", StringComparison.Ordinal) ||
                             text.Contains("huddle", StringComparison.Ordinal);

        if (process is "zoom" or "zoomrooms" && (hasMeetingTerm || text.Contains("zoom meeting", StringComparison.Ordinal)))
            return "Zoom";
        if (process is "ms-teams" or "teams" or "msteams" &&
            hasMeetingTerm)
            return "Microsoft Teams";
        if (process is "chrome" or "msedge" or "firefox" or "brave" or "opera")
        {
            if (text.Contains("google meet", StringComparison.Ordinal) || text.Contains("meet.google.com", StringComparison.Ordinal))
                return "Google Meet";
            if (text.Contains("teams.microsoft.com", StringComparison.Ordinal) && hasMeetingTerm)
                return "Microsoft Teams";
            if (text.Contains("zoom.us", StringComparison.Ordinal) && hasMeetingTerm)
                return "Zoom";
        }
        return null;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowTextLength(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}

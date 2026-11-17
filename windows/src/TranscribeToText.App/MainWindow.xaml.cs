using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TranscribeToText.Core.Services;
using TranscribeToText.Windows.Pages;
using TranscribeToText.Windows.Services;

namespace TranscribeToText.Windows;

public sealed partial class MainWindow : Window
{
    private readonly WindowsAppSettingsStore _settings = new();
    private readonly MeetingWindowDetector _meetingDetector = new();
    private readonly HashSet<string> _detectedMeetingWindows = new(StringComparer.OrdinalIgnoreCase);
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _meetingTimer;
    private bool _meetingPromptOpen;

    public MainWindow()
    {
        InitializeComponent();
        Closed += MainWindow_Closed;
        RootNavigation.SelectedItem = RootNavigation.MenuItems[0];
        ContentFrame.Navigate(typeof(HomePage));
        _meetingTimer = DispatcherQueue.CreateTimer();
        _meetingTimer.Interval = TimeSpan.FromSeconds(5);
        _meetingTimer.Tick += MeetingTimer_Tick;
        _meetingTimer.Start();
    }

    private void OnNavigationChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = args.SelectedItemContainer?.Tag as string;
        if (tag == "home")
        {
            ContentFrame.Navigate(typeof(HomePage));
            return;
        }

        if (tag is "transcriptions" or "deleted")
        {
            ContentFrame.Navigate(typeof(LibraryPage), tag);
            return;
        }

        if (tag == "settings")
        {
            ContentFrame.Navigate(typeof(SettingsPage));
            return;
        }

        if (tag == "queue")
        {
            ContentFrame.Navigate(typeof(BatchPage));
            return;
        }

        if (tag == "meetings")
        {
            ContentFrame.Navigate(typeof(MeetingPage));
            return;
        }

        ContentFrame.Navigate(typeof(FeaturePage), tag);
    }

    public void OpenTranscript(Guid id) => ContentFrame.Navigate(typeof(TranscriptEditorPage), id);

    private async void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        _meetingTimer.Stop();
        await WindowsMeetingCaptureService.Shared.StopAndPreserveTracksAsync();
    }

    private async void MeetingTimer_Tick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        if (!_settings.Load().MeetingDetectionEnabled || WindowsMeetingCaptureService.Shared.IsRecording || _meetingPromptOpen)
            return;

        var candidates = _meetingDetector.Scan();
        var visibleKeys = candidates.Select(candidate => candidate.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        _detectedMeetingWindows.IntersectWith(visibleKeys);
        var candidate = candidates.FirstOrDefault(item => _detectedMeetingWindows.Add(item.Key));
        if (candidate is null) return;

        _meetingPromptOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                Title = $"{candidate.Provider} window detected",
                Content = $"Window: {candidate.Title}\n\nThis reminder does not confirm a live call. Recording stays off until you start it from Meetings.",
                PrimaryButtonText = "Open Meetings",
                CloseButtonText = "Not now",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = RootNavigation.XamlRoot
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                var meetingItem = RootNavigation.MenuItems.OfType<NavigationViewItem>()
                    .FirstOrDefault(item => (item.Tag as string) == "meetings");
                if (meetingItem is not null) RootNavigation.SelectedItem = meetingItem;
            }
        }
        finally
        {
            _meetingPromptOpen = false;
        }
    }
}

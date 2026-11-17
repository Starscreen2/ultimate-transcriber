using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;
using TranscribeToText.Windows.Services;
using Windows.System;

namespace TranscribeToText.Windows.Pages;

public sealed partial class MeetingPage : Page
{
    private readonly WindowsAppPaths _paths = new();
    private readonly WindowsAppSettingsStore _settingsStore;
    private readonly WorkspaceLibraryStore _library = new();
    private readonly WindowsMeetingCaptureService _capture = WindowsMeetingCaptureService.Shared;
    private CancellationTokenSource? _operation;

    public MeetingPage()
    {
        InitializeComponent();
        _settingsStore = new WindowsAppSettingsStore(_paths);
        var settings = _settingsStore.Load();
        ModelPicker.ItemsSource = ModelCatalog.TranscriptionModels;
        ModelPicker.SelectedItem = ModelCatalog.FindTranscriptionModel(settings.DefaultModelId);
        var savedLanguage = LanguagePicker.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => (item.Tag as string) == settings.DefaultLanguage);
        LanguagePicker.SelectedItem = savedLanguage ?? LanguagePicker.Items[0];
        LanguageCodeBox.Text = savedLanguage is null && settings.DefaultLanguage != "auto"
            ? settings.DefaultLanguage
            : string.Empty;
        LanguagePicker.SelectionChanged += (_, _) => LanguageCodeBox.Text = string.Empty;
        MicrophoneCheckBox.IsChecked = settings.CaptureMicrophone;
        SystemAudioCheckBox.IsChecked = settings.CaptureSystemAudio;
        DetectSpeakersCheckBox.IsChecked = settings.DetectSpeakersByDefault;
        Loaded += Page_Loaded;
        ModelPicker.SelectionChanged += (_, _) => UpdateLanguageMode();
        UpdateLanguageMode();
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshCaptureState();
        if (_capture.IsRecording) StatusText.Text = $"Recording locally to {_capture.SessionFolder}.";
        try
        {
            MeetingsList.ItemsSource = (await _library.SnapshotAsync())
                .Where(entry => entry.Kind == WorkspaceRecordKind.Meeting && !entry.IsDeleted).ToArray();
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        var microphone = MicrophoneCheckBox.IsChecked == true;
        var system = SystemAudioCheckBox.IsChecked == true;
        var settings = _settingsStore.Load();
        _settingsStore.Save(settings with { CaptureMicrophone = microphone, CaptureSystemAudio = system });
        var folder = Path.Combine(_paths.Recordings, DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss"));
        try
        {
            await _capture.StartAsync(folder, microphone, system);
            StatusText.Text = $"Recording locally. Original tracks are saved in {folder}.";
            RefreshCaptureState();
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void Stop_Click(object sender, RoutedEventArgs e)
    {
        if (!_capture.IsRecording) return;
        var sessionFolder = _capture.SessionFolder!;
        var createdAt = _capture.StartedAt ?? DateTimeOffset.UtcNow;
        var settings = _settingsStore.Load();
        var engines = new EnginePaths(backend: settings.EngineBackend);
        try
        {
            var ffmpeg = engines.Require("ffmpeg.exe");
            _operation = new CancellationTokenSource();
            SetBusy(true);
            StatusText.Text = "Saving the original audio tracks and combining the recording…";
            var audioPath = await _capture.StopAndMixAsync(ffmpeg, _operation.Token);
            StatusText.Text = "Transcribing the meeting locally…";
            var model = ModelPicker.SelectedItem as ModelDefinition
                ?? ModelCatalog.FindTranscriptionModel(settings.DefaultModelId);
            var language = string.IsNullOrWhiteSpace(LanguageCodeBox.Text)
                ? (LanguagePicker.SelectedItem as ComboBoxItem)?.Tag as string ?? settings.DefaultLanguage
                : LanguageCodeBox.Text.Trim();
            var service = new WhisperTranscriptionService(_paths, engines);
            var result = await service.TranscribeAsync(audioPath, model.Id, language,
                message => App.MainWindowInstance?.DispatcherQueue.TryEnqueue(() => StatusText.Text = message),
                _operation.Token, DetectSpeakersCheckBox.IsChecked == true, Path.Combine(sessionFolder, "transcript"));
            var now = DateTimeOffset.UtcNow;
            var entry = new WorkspaceLibraryEntry
            {
                Id = Guid.NewGuid(),
                Title = Path.GetFileName(sessionFolder),
                SourcePath = audioPath,
                OutputBasePath = result.OutputBasePath,
                FolderPath = sessionFolder,
                ModelId = result.ModelId,
                Language = result.Language,
                Duration = result.Segments.Count == 0 ? 0 : result.Segments.Max(segment => segment.End),
                CreatedAt = createdAt,
                UpdatedAt = now,
                Kind = WorkspaceRecordKind.Meeting,
                Segments = result.Segments,
                SpeakerNames = result.SpeakerNames ?? new Dictionary<int, string>(),
                IsDeleted = false
            };
            await _library.SaveAsync(entry);
            MeetingsList.ItemsSource = (await _library.SnapshotAsync())
                .Where(item => item.Kind == WorkspaceRecordKind.Meeting && !item.IsDeleted).ToArray();
            StatusText.Text = result.SpeakerWarning is null
                ? $"Meeting transcript and TXT, SRT, and VTT exports saved in {entry.FolderPath}."
                : $"Meeting transcript saved. Speaker labeling was skipped: {result.SpeakerWarning}";
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "Transcription canceled. The audio tracks remain in the recordings folder.";
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
        finally
        {
            _operation?.Dispose();
            _operation = null;
            SetBusy(false);
            RefreshCaptureState();
        }
    }

    private void SetBusy(bool busy)
    {
        BusyIndicator.IsActive = busy;
        StartButton.IsEnabled = !busy && !_capture.IsRecording;
        StopButton.IsEnabled = _capture.IsRecording && !busy;
        ModelPicker.IsEnabled = !busy && !_capture.IsRecording;
        MicrophoneCheckBox.IsEnabled = !busy && !_capture.IsRecording;
        SystemAudioCheckBox.IsEnabled = !busy && !_capture.IsRecording;
        UpdateLanguageMode();
    }

    private void RefreshCaptureState()
    {
        StartButton.IsEnabled = !_capture.IsRecording && _operation is null;
        StopButton.IsEnabled = _capture.IsRecording && _operation is null;
        ModelPicker.IsEnabled = !_capture.IsRecording;
        MicrophoneCheckBox.IsEnabled = !_capture.IsRecording;
        SystemAudioCheckBox.IsEnabled = !_capture.IsRecording;
        UpdateLanguageMode();
    }

    private void UpdateLanguageMode()
    {
        var englishOnly = (ModelPicker.SelectedItem as ModelDefinition)?.Id
            .EndsWith(".en", StringComparison.OrdinalIgnoreCase) == true;
        var canChooseLanguage = !englishOnly && !_capture.IsRecording && _operation is null;
        LanguagePicker.IsEnabled = canChooseLanguage;
        LanguageCodeBox.IsEnabled = canChooseLanguage;
        LanguageModeHint.Text = englishOnly ? "This English-only model always transcribes in English." : string.Empty;
    }

    private void Meeting_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is WorkspaceLibraryEntry entry && App.MainWindowInstance is MainWindow window)
            window.OpenTranscript(entry.Id);
    }

    private void OpenMeeting_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is Guid id && App.MainWindowInstance is MainWindow window)
            window.OpenTranscript(id);
    }

    private async void OpenRecordings_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_paths.Recordings);
        await Launcher.LaunchFolderPathAsync(_paths.Recordings);
    }
}

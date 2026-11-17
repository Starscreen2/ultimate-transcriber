using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.ApplicationModel.DataTransfer;

namespace TranscribeToText.Windows.Pages;

public sealed partial class HomePage : Page
{
    private readonly WindowsAppPaths _paths = new();
    private readonly WorkspaceLibraryStore _library = new();
    private readonly WindowsAppSettingsStore _settingsStore;
    private readonly WhisperArchiveService _archives = new();
    private string? _selectedPath;
    private TranscriptionResult? _currentResult;
    private IReadOnlyDictionary<int, string> _speakerNames = new Dictionary<int, string>();
    private CancellationTokenSource? _operation;
    private bool _isBusy;

    public HomePage()
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
        DetectSpeakersCheckBox.IsChecked = settings.DetectSpeakersByDefault;
        _paths.EnsureDirectories();
        ModelPicker.SelectionChanged += (_, _) => UpdateLanguageMode();
        UpdateLanguageMode();
    }

    private async void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        foreach (var extension in MediaExtensions) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindowInstance!));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        _selectedPath = file.Path;
        _currentResult = null;
        _speakerNames = new Dictionary<int, string>();
        SelectedFileText.Text = Path.GetFileName(file.Path);
        TranscriptBox.Text = string.Empty;
        StatusText.Text = "Ready to transcribe. Model files download on first use.";
        ExportArchiveButton.IsEnabled = false;
        CopyButton.IsEnabled = false;
        OpenOutputButton.IsEnabled = false;
    }

    private async void Transcribe_Click(object sender, RoutedEventArgs e)
    {
        if (_operation is not null)
        {
            _operation.Cancel();
            StatusText.Text = "Cancelling…";
            return;
        }
        if (string.IsNullOrWhiteSpace(_selectedPath))
        {
            StatusText.Text = "Choose an audio or video file first.";
            return;
        }

        var model = ModelPicker.SelectedItem as ModelDefinition
            ?? ModelCatalog.FindTranscriptionModel("large-v3-turbo");
        var language = string.IsNullOrWhiteSpace(LanguageCodeBox.Text)
            ? (LanguagePicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "auto"
            : LanguageCodeBox.Text.Trim();
        var settings = _settingsStore.Load();
        _operation = new CancellationTokenSource();
        SetBusy(true);
        try
        {
            var service = new WhisperTranscriptionService(_paths, new EnginePaths(backend: settings.EngineBackend));
            var result = await service.TranscribeAsync(
                _selectedPath,
                model.Id,
                language,
                ReportStatus,
                _operation.Token,
                DetectSpeakersCheckBox.IsChecked == true);
            _currentResult = result;
            _speakerNames = result.SpeakerNames ?? new Dictionary<int, string>();
            TranscriptBox.Text = TranscriptExportService.ToPlainText(result.Segments, _speakerNames);
            ExportArchiveButton.IsEnabled = true;
            CopyButton.IsEnabled = true;
            OpenOutputButton.IsEnabled = true;

            var now = DateTimeOffset.UtcNow;
            await _library.SaveAsync(new WorkspaceLibraryEntry
            {
                Id = Guid.NewGuid(),
                Title = Path.GetFileName(result.SourcePath),
                SourcePath = result.SourcePath,
                OutputBasePath = result.OutputBasePath,
                FolderPath = Path.GetDirectoryName(result.OutputBasePath) ?? string.Empty,
                ModelId = result.ModelId,
                Language = result.Language,
                Duration = result.Segments.Count == 0 ? 0 : result.Segments.Max(segment => segment.End),
                CreatedAt = now,
                UpdatedAt = now,
                Kind = WorkspaceRecordKind.Transcription,
                Segments = result.Segments,
                SpeakerNames = _speakerNames,
                IsDeleted = false
            });
            StatusText.Text = result.SpeakerWarning is null
                ? $"Saved transcript and TXT, SRT, and VTT exports beside {Path.GetFileName(result.SourcePath)}."
                : $"Transcript saved. Speaker labeling was skipped: {result.SpeakerWarning}";
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "Transcription cancelled.";
        }
        catch (Exception error)
        {
            await ShowErrorAsync(error.Message);
            StatusText.Text = "Transcription failed.";
        }
        finally
        {
            _operation.Dispose();
            _operation = null;
            SetBusy(false);
        }
    }

    private async void ImportArchive_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".whisper");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindowInstance!));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        SetBusy(true);
        try
        {
            var imported = await _archives.ImportAsync(file.Path, _paths.ImportedArchives);
            _selectedPath = imported.MediaPath;
            _speakerNames = imported.SpeakerNames;
            _currentResult = new TranscriptionResult(
                imported.MediaPath,
                Path.Combine(Path.GetDirectoryName(imported.MediaPath)!, Path.GetFileNameWithoutExtension(imported.MediaPath)),
                imported.ModelId,
                imported.Language,
                imported.Segments);
            SelectedFileText.Text = imported.Title;
            TranscriptBox.Text = TranscriptExportService.ToPlainText(imported.Segments, imported.SpeakerNames);
            ModelPicker.SelectedItem = ModelCatalog.FindTranscriptionModel(imported.ModelId);
            ExportArchiveButton.IsEnabled = true;
            CopyButton.IsEnabled = true;
            OpenOutputButton.IsEnabled = true;

            await TranscriptExportService.WriteSidecarsAsync(_currentResult.OutputBasePath, imported.Segments, imported.SpeakerNames);
            var now = DateTimeOffset.UtcNow;
            await _library.SaveAsync(new WorkspaceLibraryEntry
            {
                Id = Guid.NewGuid(),
                Title = imported.Title,
                SourcePath = imported.MediaPath,
                OutputBasePath = _currentResult.OutputBasePath,
                FolderPath = Path.GetDirectoryName(imported.MediaPath)!,
                ModelId = imported.ModelId,
                Language = imported.Language,
                Duration = imported.Segments.Count == 0 ? 0 : imported.Segments.Max(segment => segment.End),
                CreatedAt = now,
                UpdatedAt = now,
                Kind = WorkspaceRecordKind.Transcription,
                Segments = imported.Segments,
                SpeakerNames = imported.SpeakerNames,
                IsDeleted = false
            });
            StatusText.Text = "Imported archive and saved transcript exports locally.";
        }
        catch (Exception error)
        {
            await ShowErrorAsync(error.Message);
            StatusText.Text = "Archive import failed.";
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async void ExportArchive_Click(object sender, RoutedEventArgs e)
    {
        if (_currentResult is null) return;
        var picker = new FileSavePicker();
        picker.SuggestedFileName = Path.GetFileNameWithoutExtension(_currentResult.SourcePath) + ".whisper";
        picker.FileTypeChoices.Add("Whisper archive", [".whisper"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindowInstance!));
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;

        try
        {
            await _archives.ExportAsync(
                _currentResult.SourcePath,
                _currentResult.Segments,
                _speakerNames,
                _currentResult.ModelId,
                _currentResult.Language,
                file.Path);
            StatusText.Text = $"Exported {file.Name}.";
        }
        catch (Exception error)
        {
            await ShowErrorAsync(error.Message);
        }
    }

    private async void CopyTranscript_Click(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(TranscriptBox.Text);
        Clipboard.SetContent(package);
        StatusText.Text = "Transcript copied to the clipboard.";
        await Task.CompletedTask;
    }

    private async void OpenOutput_Click(object sender, RoutedEventArgs e)
    {
        if (_currentResult is null) return;
        var folder = Path.GetDirectoryName(_currentResult.OutputBasePath);
        if (!string.IsNullOrEmpty(folder) && Directory.Exists(folder))
        {
            await Launcher.LaunchFolderPathAsync(folder);
        }
    }

    private void ReportStatus(string status)
    {
        App.MainWindowInstance?.DispatcherQueue.TryEnqueue(() =>
        {
            if (_operation is not null) StatusText.Text = status;
        });
    }

    private void SetBusy(bool busy)
    {
        _isBusy = busy;
        BusyIndicator.IsActive = busy;
        ChooseFileButton.IsEnabled = !busy;
        ImportArchiveButton.IsEnabled = !busy;
        ModelPicker.IsEnabled = !busy;
        LanguageCodeBox.IsEnabled = !busy;
        UpdateLanguageMode();
        ExportArchiveButton.IsEnabled = !busy && _currentResult is not null;
        CopyButton.IsEnabled = !busy && _currentResult is not null;
        OpenOutputButton.IsEnabled = !busy && _currentResult is not null;
        TranscribeButton.Content = busy ? "Cancel" : "Transcribe";
        TranscribeButton.IsEnabled = true;
    }

    private void UpdateLanguageMode()
    {
        var englishOnly = (ModelPicker.SelectedItem as ModelDefinition)?.Id
            .EndsWith(".en", StringComparison.OrdinalIgnoreCase) == true;
        LanguagePicker.IsEnabled = !_isBusy && !englishOnly;
        LanguageCodeBox.IsEnabled = !_isBusy && !englishOnly;
        LanguageModeHint.Text = englishOnly ? "This English-only model always transcribes in English." : string.Empty;
    }

    private async Task ShowErrorAsync(string message)
    {
        var dialog = new ContentDialog
        {
            Title = "Transcribe to Text",
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = XamlRoot
        };
        await dialog.ShowAsync();
    }

    private static readonly string[] MediaExtensions =
    [
        ".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wma", ".aiff", ".aif", ".caf",
        ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".mpg", ".mpeg", ".wmv"
    ];
}

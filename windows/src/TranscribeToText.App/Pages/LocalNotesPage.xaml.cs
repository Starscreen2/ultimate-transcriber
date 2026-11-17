using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;

namespace TranscribeToText.Windows.Pages;

public sealed partial class LocalNotesPage : Page
{
    private readonly WorkspaceLibraryStore _library = new();
    private readonly WindowsAppPaths _paths = new();
    private readonly WindowsAppSettingsStore _settings = new();
    private WorkspaceLibraryEntry? _entry;
    private string? _notesPath;
    private CancellationTokenSource? _operation;

    public LocalNotesPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is not Guid id) return;
        try
        {
            _entry = (await _library.SnapshotAsync()).FirstOrDefault(item => item.Id == id);
            if (_entry is null)
            {
                StatusText.Text = "This transcript is no longer in the library.";
                return;
            }
            Heading.Text = $"Local notes · {_entry.Title}";
            _notesPath = _entry.OutputBasePath + ".summary.md";
            if (File.Exists(_notesPath))
            {
                NotesBox.Text = await File.ReadAllTextAsync(_notesPath);
                SaveButton.IsEnabled = true;
                StatusText.Text = "Loaded saved local notes.";
            }
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (Frame.CanGoBack) Frame.GoBack();
    }

    private async void Generate_Click(object sender, RoutedEventArgs e)
    {
        if (_entry is null) return;
        var settings = _settings.Load();
        var assistant = new LocalTranscriptAssistant(_paths, new EnginePaths(backend: settings.EngineBackend));
        _operation = new CancellationTokenSource();
        SetBusy(true);
        try
        {
            NotesBox.Text = await assistant.SummarizeAsync(_entry.Segments, _entry.SpeakerNames,
                ReportProgress, _operation.Token);
            await SaveNotesAsync(NotesBox.Text);
            SaveButton.IsEnabled = true;
            StatusText.Text = $"Notes generated locally and saved to {_notesPath}.";
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "Notes generation canceled.";
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
        finally
        {
            _operation.Dispose();
            _operation = null;
            SetBusy(false);
        }
    }

    private async void Ask_Click(object sender, RoutedEventArgs e)
    {
        if (_entry is null || string.IsNullOrWhiteSpace(QuestionBox.Text)) return;
        var settings = _settings.Load();
        var assistant = new LocalTranscriptAssistant(_paths, new EnginePaths(backend: settings.EngineBackend));
        _operation = new CancellationTokenSource();
        SetBusy(true);
        try
        {
            AnswerBox.Text = await assistant.AskAsync(QuestionBox.Text, _entry.Segments, _entry.SpeakerNames,
                ReportProgress, _operation.Token);
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "Question canceled.";
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
        finally
        {
            _operation.Dispose();
            _operation = null;
            SetBusy(false);
        }
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(NotesBox.Text) || _notesPath is null) return;
        try
        {
            await SaveNotesAsync(NotesBox.Text);
            StatusText.Text = $"Notes saved to {_notesPath}.";
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => _operation?.Cancel();

    private void ReportProgress(string message) =>
        App.MainWindowInstance?.DispatcherQueue.TryEnqueue(() => StatusText.Text = message);

    private async Task SaveNotesAsync(string markdown)
    {
        if (_notesPath is null) throw new InvalidOperationException("The transcript folder is unavailable.");
        Directory.CreateDirectory(Path.GetDirectoryName(_notesPath)!);
        var temporary = _notesPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllTextAsync(temporary, markdown.TrimEnd() + Environment.NewLine);
            File.Move(temporary, _notesPath, overwrite: true);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
        }
    }

    private void SetBusy(bool busy)
    {
        GenerateButton.IsEnabled = !busy;
        CancelButton.IsEnabled = busy;
        QuestionBox.IsEnabled = !busy;
        SaveButton.IsEnabled = !busy && !string.IsNullOrWhiteSpace(NotesBox.Text);
    }
}

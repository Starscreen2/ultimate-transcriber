using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;
using Windows.Storage.Pickers;

namespace TranscribeToText.Windows.Pages;

public sealed partial class BatchPage : Page
{
    private readonly WindowsBatchQueue _queue = WindowsBatchQueue.Shared;
    public ObservableCollection<BatchQueueItem> QueueItems => _queue.Items;

    public BatchPage()
    {
        InitializeComponent();
        _queue.AttachDispatcher(App.MainWindowInstance?.DispatcherQueue);
        _queue.StateChanged += Queue_StateChanged;
        Loaded += (_, _) => RefreshState();
        Unloaded += (_, _) => _queue.StateChanged -= Queue_StateChanged;
    }

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        foreach (var extension in new[] { ".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wma", ".mp4", ".mov", ".mkv", ".webm" })
            picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindowInstance!));
        var files = await picker.PickMultipleFilesAsync();
        if (files is null || files.Count == 0) return;
        _queue.AddFiles(files.Select(file => file.Path));
        RefreshState();
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        AddFilesButton.IsEnabled = false;
        StartButton.IsEnabled = false;
        CancelButton.IsEnabled = true;
        try
        {
            await _queue.StartAsync();
        }
        finally
        {
            RefreshState();
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => _queue.Cancel();

    private void Queue_StateChanged(object? sender, EventArgs e) =>
        App.MainWindowInstance?.DispatcherQueue.TryEnqueue(RefreshState);

    private void RefreshState()
    {
        QueueSummary.Text = _queue.Summary;
        AddFilesButton.IsEnabled = !_queue.IsRunning;
        StartButton.IsEnabled = !_queue.IsRunning && _queue.Items.Any(item => item.State is "Ready" or "Failed");
        CancelButton.IsEnabled = _queue.IsRunning;
    }
}

public sealed class BatchQueueItem : INotifyPropertyChanged
{
    private string _state = "Ready";
    private string _detail = "Waiting to start";
    public event PropertyChangedEventHandler? PropertyChanged;

    public Guid Id { get; } = Guid.NewGuid();
    public string SourcePath { get; }
    public string OutputBasePath { get; set; }
    public string FileName => Path.GetFileName(SourcePath);
    public string State { get => _state; set { _state = value; OnPropertyChanged(); } }
    public string Detail { get => _detail; set { _detail = value; OnPropertyChanged(); } }

    public BatchQueueItem(string sourcePath, string outputBasePath)
    {
        SourcePath = sourcePath;
        OutputBasePath = outputBasePath;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public sealed class WindowsBatchQueue
{
    private static readonly string[] MediaExtensions = [".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wma", ".mp4", ".mov", ".mkv", ".webm"];
    public static WindowsBatchQueue Shared { get; } = new();

    private readonly WorkspaceLibraryStore _library = new();
    private readonly WindowsAppPaths _paths = new();
    private readonly WindowsAppSettingsStore _settings = new();
    private DispatcherQueue? _dispatcher;
    private CancellationTokenSource? _active;

    public ObservableCollection<BatchQueueItem> Items { get; } = [];
    public bool IsRunning { get; private set; }
    public event EventHandler? StateChanged;
    public string Summary
    {
        get
        {
            if (Items.Count == 0) return "No files selected.";
            var completed = Items.Count(item => item.State == "Finished");
            var failed = Items.Count(item => item.State == "Failed");
            var canceled = Items.Count(item => item.State == "Canceled");
            var running = Items.Count(item => item.State == "Transcribing");
            var pending = Items.Count(item => item.State == "Ready");
            var parts = new List<string> { $"{completed} finished", $"{failed} failed", $"{canceled} canceled" };
            if (running > 0) parts.Add($"{running} running");
            if (pending > 0) parts.Add($"{pending} ready");
            return $"{Items.Count} files · " + string.Join(" · ", parts);
        }
    }

    public void AttachDispatcher(DispatcherQueue? dispatcher) => _dispatcher = dispatcher;

    public void AddFiles(IEnumerable<string> paths)
    {
        var known = Items.Select(item => Path.GetFullPath(item.SourcePath)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var files = paths.Select(Path.GetFullPath)
            .Where(path => File.Exists(path) && MediaExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
            .Where(path => known.Add(path)).ToArray();
        foreach (var path in files)
        {
            var basePath = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path));
            var collision = Items.Any(item => string.Equals(item.OutputBasePath, basePath, StringComparison.OrdinalIgnoreCase))
                || files.Count(other => string.Equals(
                    Path.Combine(Path.GetDirectoryName(other)!, Path.GetFileNameWithoutExtension(other)), basePath,
                    StringComparison.OrdinalIgnoreCase)) > 1;
            if (collision)
            {
                var suffix = Path.GetExtension(path).TrimStart('.');
                if (string.IsNullOrWhiteSpace(suffix)) suffix = "file";
                basePath += $" ({suffix})";
            }
            var original = basePath;
            var number = 2;
            while (Items.Any(item => string.Equals(item.OutputBasePath, basePath, StringComparison.OrdinalIgnoreCase)))
                basePath = $"{original} ({number++})";
            Items.Add(new BatchQueueItem(path, basePath));
        }
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Cancel() => _active?.Cancel();

    public async Task StartAsync()
    {
        if (IsRunning) return;
        var settings = _settings.Load();
        var ready = Items.Where(item => item.State is "Ready" or "Failed").ToArray();
        if (ready.Length == 0) return;
        IsRunning = true;
        _active = new CancellationTokenSource();
        var cancellationToken = _active.Token;
        Notify();
        try
        {
            foreach (var item in ready)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    Set(item, "Canceled", "Canceled before starting");
                    continue;
                }
                Set(item, "Transcribing", "Preparing the local engine…");
                try
                {
                    var service = new WhisperTranscriptionService(_paths, new EnginePaths(backend: settings.EngineBackend));
                    var result = await service.TranscribeAsync(item.SourcePath, settings.DefaultModelId, settings.DefaultLanguage,
                        line => Set(item, "Transcribing", line), cancellationToken,
                        settings.DetectSpeakersByDefault, item.OutputBasePath);
                    var now = DateTimeOffset.UtcNow;
                    var speakerNames = result.SpeakerNames ?? new Dictionary<int, string>();
                    await _library.SaveAsync(new WorkspaceLibraryEntry
                    {
                        Id = Guid.NewGuid(),
                        Title = item.FileName,
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
                        SpeakerNames = speakerNames,
                        IsDeleted = false
                    });
                    Set(item, "Finished", result.SpeakerWarning is null ? "TXT, SRT, and VTT exports saved" : $"Saved; speaker detection skipped: {result.SpeakerWarning}");
                }
                catch (OperationCanceledException)
                {
                    Set(item, "Canceled", "Canceled");
                    foreach (var pending in ready.Where(candidate => candidate.State == "Ready"))
                        Set(pending, "Canceled", "Canceled before starting");
                    break;
                }
                catch (Exception error)
                {
                    Set(item, "Failed", error.Message);
                }
            }
        }
        finally
        {
            IsRunning = false;
            _active.Dispose();
            _active = null;
            Notify();
        }
    }

    private void Set(BatchQueueItem item, string state, string detail) => Dispatch(() =>
    {
        item.State = state;
        item.Detail = detail;
        StateChanged?.Invoke(this, EventArgs.Empty);
    });

    private void Notify() => Dispatch(() => StateChanged?.Invoke(this, EventArgs.Empty));

    private void Dispatch(Action action)
    {
        if (_dispatcher is null || _dispatcher.HasThreadAccess) action();
        else _dispatcher.TryEnqueue(() => action());
    }
}

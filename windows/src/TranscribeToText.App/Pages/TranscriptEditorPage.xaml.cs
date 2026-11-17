using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace TranscribeToText.Windows.Pages;

public sealed partial class TranscriptEditorPage : Page
{
    private readonly WorkspaceLibraryStore _library = new();
    private readonly ObservableCollection<SegmentEditorRow> _rows = [];
    private readonly ObservableCollection<SpeakerEditorRow> _speakerRows = [];
    private WorkspaceLibraryEntry? _entry;
    private MediaPlayer? _mediaPlayer;

    public TranscriptEditorPage()
    {
        InitializeComponent();
        SegmentsList.ItemsSource = _rows;
        SpeakersList.ItemsSource = _speakerRows;
        Loaded += Page_Loaded;
        Unloaded += Page_Unloaded;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is not Guid id)
        {
            StatusText.Text = "The selected transcript could not be identified.";
            return;
        }

        try
        {
            var snapshot = await _library.SnapshotAsync();
            _entry = snapshot.FirstOrDefault(entry => entry.Id == id);
            if (_entry is null)
            {
                StatusText.Text = "This transcript is no longer in the library.";
                return;
            }

            TitleText.Text = _entry.Title;
            StatusText.Text = $"{_entry.Language} · {_entry.ModelId} · {_entry.Segments.Count} segments";
            _speakerRows.Clear();
            var speakerIds = _entry.SpeakerNames.Keys.Concat(_entry.Segments
                .Where(segment => segment.SpeakerId.HasValue).Select(segment => segment.SpeakerId!.Value))
                .Distinct().Order().ToArray();
            foreach (var speakerId in speakerIds)
            {
                var name = _entry.SpeakerNames.GetValueOrDefault(speakerId) ?? $"Speaker {speakerId + 1}";
                _speakerRows.Add(new SpeakerEditorRow(speakerId, name));
            }
            _rows.Clear();
            foreach (var segment in _entry.Segments) _rows.Add(new SegmentEditorRow(segment, _entry.SpeakerNames));
            await LoadAudioAsync();
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        await LoadAudioAsync();
    }

    private async Task LoadAudioAsync()
    {
        if (!IsLoaded || _entry is null || _mediaPlayer is not null || !File.Exists(_entry.SourcePath)) return;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(_entry.SourcePath);
            if (!IsLoaded || _mediaPlayer is not null) return;
            _mediaPlayer = new MediaPlayer();
            MediaElement.SetMediaPlayer(_mediaPlayer);
            _mediaPlayer.Source = MediaSource.CreateFromStorageFile(file);
        }
        catch
        {
            StatusText.Text = "Transcript loaded; audio playback is unavailable for this file.";
        }
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        _mediaPlayer?.Dispose();
        _mediaPlayer = null;
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (Frame.CanGoBack) Frame.GoBack();
    }

    private void Notes_Click(object sender, RoutedEventArgs e)
    {
        if (_entry is not null) Frame.Navigate(typeof(LocalNotesPage), _entry.Id);
    }

    private async void ExportArchive_Click(object sender, RoutedEventArgs e)
    {
        if (_entry is null) return;
        var picker = new FileSavePicker
        {
            SuggestedFileName = Path.GetFileNameWithoutExtension(_entry.SourcePath) + ".whisper"
        };
        picker.FileTypeChoices.Add("Whisper archive", [".whisper"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindowInstance!));
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            var names = _speakerRows.ToDictionary(row => row.Id, row => row.Name.Trim());
            await new WhisperArchiveService().ExportAsync(
                _entry.SourcePath,
                _rows.Select(row => row.ToSegment()).ToArray(),
                names,
                _entry.ModelId,
                _entry.Language,
                file.Path);
            StatusText.Text = $"Exported {file.Name}.";
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (_entry is null) return;
        try
        {
            var segments = _rows.Select(row => row.ToSegment()).ToArray();
            var updated = _entry with
            {
                Segments = segments,
                SpeakerNames = _speakerRows.ToDictionary(row => row.Id, row => row.Name.Trim()),
                UpdatedAt = DateTimeOffset.UtcNow,
                SummaryTranscriptDigest = null
            };
            await _library.SaveAsync(updated);
            await TranscriptExportService.WriteSidecarsAsync(
                updated.OutputBasePath,
                segments,
                updated.SpeakerNames);
            _entry = updated;
            StatusText.Text = "Transcript and TXT, SRT, and VTT exports saved.";
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_entry is null) return;
        try
        {
            await _library.MarkDeletedAsync(_entry.Id);
            if (Frame.CanGoBack) Frame.GoBack();
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }
}

public sealed class SegmentEditorRow : INotifyPropertyChanged
{
    private string _text;

    public event PropertyChangedEventHandler? PropertyChanged;

    public Guid Id { get; }
    public double Start { get; }
    public double End { get; }
    public int? SpeakerId { get; }
    public string SpeakerLabel { get; }
    public bool IsFavorite { get; }
    public bool StartsNewParagraph { get; }
    public bool IsUneven { get; }
    public string TimeLabel => $"{TranscriptExportService.FormatTimestamp(Start)}";

    public string Text
    {
        get => _text;
        set
        {
            if (_text == value) return;
            _text = value;
            OnPropertyChanged();
        }
    }

    public SegmentEditorRow(TranscriptSegment segment, IReadOnlyDictionary<int, string> speakerNames)
    {
        Id = segment.Id;
        Start = segment.Start;
        End = segment.End;
        SpeakerId = segment.SpeakerId;
        SpeakerLabel = segment.SpeakerId is int id
            ? speakerNames.GetValueOrDefault(id) ?? $"Speaker {id + 1}"
            : string.Empty;
        IsFavorite = segment.IsFavorite;
        StartsNewParagraph = segment.StartsNewParagraph;
        IsUneven = segment.IsUneven;
        _text = segment.Text;
    }

    public TranscriptSegment ToSegment() => new()
    {
        Id = Id,
        Start = Start,
        End = End,
        Text = Text,
        SpeakerId = SpeakerId,
        IsFavorite = IsFavorite,
        StartsNewParagraph = StartsNewParagraph,
        IsUneven = IsUneven
    };

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public sealed class SpeakerEditorRow : INotifyPropertyChanged
{
    private string _name;
    public event PropertyChangedEventHandler? PropertyChanged;
    public int Id { get; }
    public string Label => $"Speaker {Id + 1}";
    public string Name
    {
        get => _name;
        set
        {
            if (_name == value) return;
            _name = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Name)));
        }
    }

    public SpeakerEditorRow(int id, string name)
    {
        Id = id;
        _name = name;
    }
}

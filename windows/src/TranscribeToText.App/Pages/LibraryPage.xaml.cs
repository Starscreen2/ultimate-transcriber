using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;

namespace TranscribeToText.Windows.Pages;

public sealed partial class LibraryPage : Page
{
    private readonly WorkspaceLibraryStore _library = new();
    private string _section = "transcriptions";

    public LibraryPage()
    {
        InitializeComponent();
        Loaded += Page_Loaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _section = e.Parameter as string ?? "transcriptions";
        Heading.Text = _section switch
        {
            "meetings" => "Meetings",
            "deleted" => "Recently Deleted",
            _ => "Transcriptions"
        };
        ClearRecentlyDeletedButton.Visibility = _section == "deleted" ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            var snapshot = await _library.SnapshotAsync();
            var visible = _section switch
            {
                "meetings" => snapshot.Where(entry => entry.Kind == WorkspaceRecordKind.Meeting && !entry.IsDeleted),
                "deleted" => snapshot.Where(entry => entry.IsDeleted),
                _ => snapshot.Where(entry => entry.Kind == WorkspaceRecordKind.Transcription && !entry.IsDeleted)
            };
            var entries = visible.ToArray();
            EntriesList.ItemsSource = entries;
            if (_library.LoadFailure is string failure)
            {
                StatusText.Text = $"The library could not be read. Existing data was preserved. {failure}";
            }
            else if (entries.Length == 0)
            {
                StatusText.Text = _section == "deleted"
                    ? "Nothing has been moved to Recently Deleted."
                    : "Completed local work will appear here.";
            }
            else
            {
                StatusText.Text = $"{entries.Length} local item{(entries.Length == 1 ? "" : "s")}.";
            }
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private void Entry_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is WorkspaceLibraryEntry entry)
        {
            if (App.MainWindowInstance is MainWindow window)
                window.OpenTranscript(entry.Id);
        }
    }

    private void OpenEntry_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is Guid id && App.MainWindowInstance is MainWindow window)
        {
            window.OpenTranscript(id);
        }
    }

    private async void DeleteEntry_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not Guid id) return;
        try
        {
            if (_section == "deleted")
            {
                await _library.RestoreAsync(id);
            }
            else
            {
                await _library.MarkDeletedAsync(id);
            }
            Page_Loaded(this, new RoutedEventArgs());
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void DeleteForever_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not Guid id) return;
        if (await ConfirmPermanentDeleteAsync() != ContentDialogResult.Primary) return;
        try
        {
            await _library.PermanentlyDeleteAsync(id);
            await RefreshEntriesAsync();
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async void ClearRecentlyDeleted_Click(object sender, RoutedEventArgs e)
    {
        if (await ConfirmPermanentDeleteAsync(clearAll: true) != ContentDialogResult.Primary) return;
        try
        {
            await _library.ClearRecentlyDeletedAsync();
            await RefreshEntriesAsync();
        }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
        }
    }

    private async Task<ContentDialogResult> ConfirmPermanentDeleteAsync(bool clearAll = false)
    {
        var dialog = new ContentDialog
        {
            Title = clearAll ? "Clear Recently Deleted?" : "Permanently delete this library entry?",
            Content = "This removes the transcript from the library. The original media and exported files are kept.",
            PrimaryButtonText = "Delete from library",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot
        };
        return await dialog.ShowAsync();
    }

    private async Task RefreshEntriesAsync()
    {
        var snapshot = await _library.SnapshotAsync();
        var visible = _section switch
        {
            "deleted" => snapshot.Where(entry => entry.IsDeleted),
            _ => snapshot.Where(entry => entry.Kind == WorkspaceRecordKind.Transcription && !entry.IsDeleted)
        };
        var entries = visible.ToArray();
        EntriesList.ItemsSource = entries;
        StatusText.Text = entries.Length == 0
            ? "There are no items in this section."
            : $"{entries.Length} local item{(entries.Length == 1 ? "" : "s")}.";
    }
}

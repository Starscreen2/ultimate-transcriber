using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace TranscribeToText.Windows.Pages;

public sealed partial class FeaturePage : Page
{
    public FeaturePage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var section = e.Parameter as string ?? "workspace";
        Heading.Text = section switch
        {
            "queue" => "Queue",
            "transcriptions" => "Transcriptions",
            "meetings" => "Meetings",
            "deleted" => "Recently Deleted",
            "settings" => "Settings",
            _ => "Workspace"
        };
        Description.Text = section switch
        {
            "queue" => "The Windows job queue will show transcription and meeting activity here.",
            "transcriptions" => "Completed transcripts will be saved to the local library here.",
            "meetings" => "Meeting capture and detection are being built for Windows.",
            "deleted" => "Items moved out of the library will appear here.",
            "settings" => "Model downloads, engine backends, and recording settings will appear here.",
            _ => "This Windows workspace is being built."
        };
    }
}

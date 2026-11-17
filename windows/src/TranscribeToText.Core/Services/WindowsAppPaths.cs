using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public sealed class WindowsAppPaths
{
    public string Root { get; }
    public string Models => Path.Combine(Root, "models");
    public string SummaryModels => Path.Combine(Root, "summary-models");
    public string SpeakerModels => Path.Combine(Root, "speaker-models");
    public string ImportedArchives => Path.Combine(Root, "imported-archives");
    public string Library => Path.Combine(Root, "library");
    public string Recordings => Path.Combine(Root, "recordings");

    public WindowsAppPaths(string? root = null)
    {
        Root = root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TranscribeToText");
    }

    public string PathFor(ModelDefinition model) => model.Purpose switch
    {
        ModelPurpose.Transcription or ModelPurpose.VoiceActivityDetection => Path.Combine(Models, model.FileName),
        ModelPurpose.MeetingNotes => Path.Combine(SummaryModels, model.FileName),
        ModelPurpose.SpeakerSegmentation or ModelPurpose.SpeakerEmbedding => Path.Combine(SpeakerModels, model.FileName),
        _ => throw new ArgumentOutOfRangeException(nameof(model))
    };

    public void EnsureDirectories()
    {
        foreach (var path in new[] { Root, Models, SummaryModels, SpeakerModels, ImportedArchives, Library, Recordings })
        {
            Directory.CreateDirectory(path);
        }
    }
}

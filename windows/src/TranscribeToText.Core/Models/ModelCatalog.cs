namespace TranscribeToText.Core.Models;

public enum ModelPurpose
{
    Transcription,
    VoiceActivityDetection,
    MeetingNotes,
    SpeakerSegmentation,
    SpeakerEmbedding
}

public sealed record ModelDefinition(
    string Id,
    string Name,
    string FileName,
    Uri DownloadUri,
    ModelPurpose Purpose,
    string Description,
    long? ExpectedBytes = null);

public static class ModelCatalog
{
    private static readonly Uri WhisperBase = new("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/");
    private static readonly Uri SherpaSegmentationArchive = new(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2");
    private static readonly Uri SherpaEmbedding = new(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx");

    public static IReadOnlyList<ModelDefinition> TranscriptionModels { get; } =
    [
        Whisper("tiny", "Tiny · Fastest · Multilingual", "ggml-tiny.bin", "Small and fast; best for quick drafts."),
        Whisper("base", "Base · Fast · Multilingual", "ggml-base.bin", "Fast multilingual option."),
        Whisper("small", "Small · Balanced · Multilingual", "ggml-small.bin", "Balanced speed and accuracy for many languages."),
        Whisper("medium", "Medium · More accurate · Multilingual", "ggml-medium.bin", "Higher accuracy with slower processing and a larger download."),
        Whisper("large-v1", "Large v1 · Legacy · Multilingual", "ggml-large-v1.bin", "Original Large model, retained for comparison."),
        Whisper("large-v2", "Large v2 · Stable alternative · Multilingual", "ggml-large-v2.bin", "Older Large release that can work well for some recordings."),
        Whisper("large-v3", "Large v3 · Highest overall accuracy", "ggml-large-v3.bin", "Highest overall accuracy in many cases."),
        Whisper("large-v3-turbo", "Large v3 Turbo · Much faster", "ggml-large-v3-turbo.bin", "Much faster than Large v3 with a small accuracy tradeoff."),
        Whisper("tiny.en", "Tiny.en · Fastest · English only", "ggml-tiny.en.bin", "English-only Tiny model."),
        Whisper("base.en", "Base.en · Fast · English only", "ggml-base.en.bin", "English-only Base model."),
        Whisper("small.en", "Small.en · Balanced · English only", "ggml-small.en.bin", "English-only model with a useful speed/accuracy balance."),
        Whisper("medium.en", "Medium.en · More accurate · English only", "ggml-medium.en.bin", "English-only Medium model with higher accuracy and more processing time.")
    ];

    public static ModelDefinition VadModel { get; } = new(
        "silero-v6.2.0",
        "Silero VAD",
        "ggml-silero-v6.2.0.bin",
        new Uri("https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"),
        ModelPurpose.VoiceActivityDetection,
        "Voice activity model used to skip silence during transcription.");

    public static ModelDefinition SummaryModel { get; } = new(
        "qwen3-4b-q4-k-m",
        "Qwen3 4B · Q4_K_M",
        "Qwen3-4B-Q4_K_M.gguf",
        new Uri("https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"),
        ModelPurpose.MeetingNotes,
        "Local model for summaries and transcript chat.",
        2_500_000_000);

    public static ModelDefinition SpeakerSegmentationArchive { get; } = new(
        "pyannote-segmentation-3",
        "Pyannote speaker segmentation",
        "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
        SherpaSegmentationArchive,
        ModelPurpose.SpeakerSegmentation,
        "Speaker-turn segmentation model archive.");

    public static ModelDefinition SpeakerEmbeddingModel { get; } = new(
        "wespeaker-voxceleb-resnet34",
        "WeSpeaker VoxCeleb ResNet34",
        "wespeaker_en_voxceleb_resnet34.onnx",
        SherpaEmbedding,
        ModelPurpose.SpeakerEmbedding,
        "Speaker embedding model used for diarization.");

    public static IReadOnlyList<ModelDefinition> All { get; } =
        TranscriptionModels
            .Concat([VadModel, SummaryModel, SpeakerSegmentationArchive, SpeakerEmbeddingModel])
            .ToArray();

    public static ModelDefinition FindTranscriptionModel(string id) =>
        TranscriptionModels.FirstOrDefault(model => model.Id.Equals(id, StringComparison.OrdinalIgnoreCase))
        ?? TranscriptionModels.First(model => model.Id == "large-v3-turbo");

    private static ModelDefinition Whisper(string id, string name, string fileName, string description) =>
        new(id, name, fileName, new Uri(WhisperBase, fileName), ModelPurpose.Transcription, description);
}

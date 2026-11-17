# Windows client architecture

The Windows target is a native WinUI 3 desktop app with a portable C# core. Its source and Windows-only dependencies stay inside `windows/`.

## Projects

| Path | Responsibility |
| --- | --- |
| `src/TranscribeToText.App` | WinUI window, navigation, pages, media playback, file pickers, and Windows audio capture via NAudio. |
| `src/TranscribeToText.Core` | Transcript models and services that do not depend on WinUI or NAudio. |
| `tests/TranscribeToText.Core.Tests` | Portable checks for model metadata, transcript formats, archive compatibility, library JSON, engine paths, and process execution. |
| `scripts/build-engines.ps1` | Builds pinned whisper.cpp, llama.cpp, and sherpa-onnx engine binaries for CPU, CUDA, or Vulkan. |
| `scripts/publish-windows.ps1` | Publishes the self-contained x64 app and creates a local ZIP after runtime and license inputs are present. |

## Main flows

### File and batch transcription

The Home, Batch, and Meetings pages call `WhisperTranscriptionService`. It downloads the selected Whisper and VAD models if needed, converts input with FFmpeg to normalized WAV, invokes `whisper-cli.exe`, parses SRT timestamps, optionally requests speaker labels, and writes TXT/SRT/WebVTT sidecars. Batch processing uses the saved model, language, and speaker defaults and saves each successful item to the library.

### Speaker labels

`SpeakerDiarizationService` prepares mono 16 kHz audio with FFmpeg and calls `sherpa-onnx-offline-speaker-diarization.exe`. It aligns speaker turns to transcript segments by overlap. Sherpa diarization is CPU-based in this target; labels remain editable in the transcript editor.

### Local notes and questions

`LocalTranscriptAssistant` runs the downloaded Qwen3 GGUF model through `llama-cli.exe`. Notes and transcript questions stay local. Generated notes are saved as `<output-base>.summary.md` beside the transcript.

### Meeting recording

`WindowsMeetingCaptureService` records microphone input and Windows system loopback audio independently with NAudio/WASAPI. Stop combines available tracks with FFmpeg and preserves the source WAV tracks. The app's visible-window detector only offers a reminder; it never starts recording automatically.

## Runtime and user data

- During development, native engines are placed in `windows/runtime/engines/{cpu,cuda,vulkan}`. The app project copies them to `engines/{backend}` beside its output.
- `EnginePaths` resolves the chosen backend and falls back to CPU when a GPU binary is missing. Transcription and local notes retry CPU when a packaged GPU engine cannot start or exits unsuccessfully.
- User models, the transcript library, imported archives, and meeting recordings are stored beneath `%LOCALAPPDATA%\TranscribeToText` in separate subfolders; settings are in `settings.json` at that root.
- Normal file/batch transcript sidecars are written beside the selected source. Meeting outputs stay in that meeting's recording folder.
- `.whisper` archives contain a version file, `metadata.json`, and the original audio payload. Import/export supports archive versions 1 and 2. Library JSON is Mac-compatible, but its absolute media paths are machine-specific.

## Hardware boundary

CUDA and Vulkan are backend builds for Whisper and llama.cpp. CPU is always the fallback. Vulkan is the AMD route; CUDA is the NVIDIA route. Actual device/driver support and performance are not guaranteed until checked on Windows PCs. FFmpeg and Sherpa diarization remain CPU paths.

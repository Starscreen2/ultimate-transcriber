# Codex instructions for the Windows client

These instructions apply to files under `windows/`. Read [README.md](README.md) for setup and build commands and [ARCHITECTURE.md](ARCHITECTURE.md) before changing engine, storage, or page flows.

## Scope and project boundaries

- The Windows client is a separate WinUI 3 app. Keep its UI, portable C# logic, PowerShell build scripts, and generated runtime files under `windows/`.
- The SwiftUI/macOS app at the repository root is a separate product target. Do not port Windows code into it or change its behavior as a side effect.
- `MeetingWhisper/CMakeLists.txt` is shared native build configuration. Change it only when the behavior is platform-conditional and keep Apple Metal enabled on macOS.
- Do not add `windows/build`, `windows/runtime`, `windows/artifacts`, model downloads, recordings, or generated `bin`/`obj` files to Git. Their ignore rules are in the root `.gitignore`.
- The local `reconstruction/` evidence directory is intentionally ignored. Do not read, move, or add it to commits unless the user asks.

## Architecture

- `src/TranscribeToText.Core` contains platform-neutral transcript models, model downloads, process execution, engine lookup, archives, exports, library persistence, transcription, diarization, and local notes.
- `src/TranscribeToText.App` contains WinUI pages and the Windows-only NAudio meeting capture service.
- `scripts/build-engines.ps1` builds pinned whisper.cpp, llama.cpp, and sherpa-onnx sources into ignored runtime folders. Keep upstream revisions pinned; update them deliberately and rebuild each supported backend.
- `scripts/publish-windows.ps1` makes a local ZIP only. It does not publish or upload GitHub releases.

## Engine and hardware rules

- CPU is the supported baseline. CUDA is the NVIDIA option; Vulkan is the AMD option and may also work on supported NVIDIA devices. Auto prefers CUDA, then Vulkan, then CPU.
- CUDA/Vulkan builds accelerate Whisper and llama.cpp local notes. FFmpeg and sherpa-onnx speaker diarization run on CPU.
- Keep CPU fallback available when adding engine selection or failure handling. Never describe AMD/NVIDIA support as validated until the Windows checklist has been completed on the relevant hardware and driver.
- Runtime executables resolve relative to the app output under `engines/{cpu,cuda,vulkan}`. Model files and user data live under `%LOCALAPPDATA%\TranscribeToText`.

## Data and compatibility

- Keep transcript and settings data local; do not add cloud services or telemetry without the user's request.
- `.whisper` v1/v2 archives carry transcript metadata and source audio across macOS and Windows. Library JSON stores absolute file paths, so it is not a portable library backup.
- Keep the model IDs and file formats aligned with the Mac catalog. Windows stores its own downloads and does not reuse the Mac app's filesystem paths.
- When editing a transcript, preserve timestamps, speaker IDs/names, favorites, and paragraph/uneven flags unless the user asks to change them.

## Build and release checks

- The GitHub Actions workflow on `windows-latest` is the authoritative WinUI/XAML build check; the Windows XAML compiler cannot run on macOS.
- For portable C# changes, build `TranscribeToText.Core` and run the core compatibility checks. For UI changes, also build the WinUI project on Windows.
- For engine-script changes, parse the PowerShell files and build the CPU path on Windows before treating the script as ready.
- Do not publish Windows assets until Windows runtime, archive interoperability, audio capture, CPU, and applicable GPU paths have been checked using [VALIDATION.md](VALIDATION.md). Attach a validated Windows ZIP to the matching existing GitHub release tag; do not replace the macOS asset.
- Packaged FFmpeg and CUDA runtimes need their applicable redistribution notices. Keep notices in the Windows bundle.

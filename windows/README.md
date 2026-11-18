# Windows client

This is the separate Windows version of Transcribe to Text. Windows source, native build scripts, and packaging inputs live under `windows/`; the macOS app and its build remain at the repository root. The Windows client is not included in the current GitHub release yet.

For future Codex work on this client, see the scoped [AGENTS.md](AGENTS.md) instructions and the [architecture guide](ARCHITECTURE.md).

## Current capabilities

| Capability | Windows implementation |
| --- | --- |
| File transcription | Local whisper.cpp, FFmpeg conversion, Silero VAD, all 12 Whisper choices from the Mac app, and custom Whisper language codes |
| Models | Download and validation for Whisper, VAD, Qwen3 local notes, and speaker models |
| Transcript formats | TXT, SRT, WebVTT, and version 1/2 `.whisper` archive import/export |
| Batch queue | Sequential file queue with per-file status, cancellation, and saved library records |
| Transcript library | Local library, audio playback, segment editing, speaker-name editing, exports, and Recently Deleted |
| Local notes and transcript questions | Qwen3 through llama.cpp, saved beside each transcript |
| Speaker labels | Sherpa-onnx diarization with editable speaker names |
| Meeting recording | Manual microphone and system-output capture, preserved source tracks, mixed audio, then local transcription |
| Meeting reminders | Optional best-effort visible-window reminders for Zoom, Teams, and Google Meet; recording only starts after a manual click |
| Hardware backends | CPU baseline; optional CUDA build for NVIDIA and Vulkan build for AMD and supported NVIDIA GPUs; Auto tries available backends then CPU |

The first implementation is complete enough for a Windows build and hardware smoke-test pass, but is not a fully validated release. A CPU-only preview is attached to the v0.4.0 GitHub release and was built from the `codex/windows-client` branch. WinUI, native engine packaging, real recording and transcription, archives created by the Mac app, and representative AMD/NVIDIA GPUs still need validation on Windows. Meeting-window detection is deliberately limited to visible window titles and process names; it does not start recording automatically or reproduce the Mac app's deeper call-control detection.

## Build and run on Windows

Use Windows 10 version 2004 (build 19041) or later, or Windows 11, on x64. Install the .NET 10 SDK, Visual Studio with the Desktop development with C++ workload, CMake, Git, and a Windows FFmpeg build. CUDA Toolkit is required only for the CUDA build. Vulkan SDK is required only for the Vulkan build. FFmpeg's separate license terms depend on the build you supply.

From the repository root in PowerShell, first build the CPU baseline and package FFmpeg:

```powershell
.\windows\scripts\build-engines.ps1 -Backend CPU -FfmpegPath C:\ffmpeg\bin\ffmpeg.exe
```

Optional GPU engines can be added to the same local runtime folder:

```powershell
.\windows\scripts\build-engines.ps1 -Backend CUDA -FfmpegPath C:\ffmpeg\bin\ffmpeg.exe
.\windows\scripts\build-engines.ps1 -Backend Vulkan -FfmpegPath C:\ffmpeg\bin\ffmpeg.exe
```

The native build script writes engines into ignored `windows/runtime/engines/{cpu,cuda,vulkan}` folders. The app build copies those folders beside the application. Then build and launch the client:

```powershell
dotnet build windows\src\TranscribeToText.App\TranscribeToText.App.csproj -c Release -p:Platform=x64
dotnet run --project windows\src\TranscribeToText.App\TranscribeToText.App.csproj -c Release -p:Platform=x64
```

To create a self-contained Windows x64 EXE and a ZIP with the EXE and third-party notices, pass the license and README for the FFmpeg build you supplied. If a CUDA engine is present, also pass its applicable redistribution license/notice:

```powershell
.\windows\scripts\publish-windows.ps1 -Version v0.5.0 -FfmpegLicensePath C:\ffmpeg\LICENSE.txt -FfmpegReadmePath C:\ffmpeg\README.txt
```

For a bundle that contains CUDA runtime DLLs, add `-CudaLicensePath` with the applicable NVIDIA notice. The script writes `TranscribeToText.App.exe` and a versioned companion ZIP under ignored `windows/artifacts/`. The EXE is a single-file, self-contained app with the engine backends present in `windows/runtime/engines/`; a Windows user does not need to install .NET, CMake, Git, or FFmpeg. Keep the EXE's filename when downloading it because WinUI uses the compiled app name at startup. The ZIP contains the same EXE plus third-party license files, the supplied FFmpeg build README, and the MSVC redistributable notice. The app downloads selected models on first use, so internet access is needed for that initial download; transcription runs locally after the models are available.

The v0.4.0 release includes the current Windows CPU-only preview EXE and companion ZIP; these are not a claim that the full Windows checklist in [VALIDATION.md](VALIDATION.md) has passed. Attach a validated Windows build to the matching release after the checklist is complete, and do not replace the macOS release asset.

Run the portable core checks with:

```powershell
dotnet run --project windows\tests\TranscribeToText.Core.Tests\TranscribeToText.Core.Tests.csproj -c Release
```

When you're ready to try the client on Windows, use the manual [validation checklist](VALIDATION.md) to cover audio, archive compatibility, meetings, and GPU fallbacks.

Downloaded model files and the transcript library stay in `%LOCALAPPDATA%\TranscribeToText`. Keep models, generated engine binaries, CMake builds, and user recordings out of Git.

## Hardware behavior

CPU is the baseline and remains available when a GPU engine is missing or fails to start. CUDA requires a compatible NVIDIA driver/runtime. Vulkan uses the Vulkan implementation exposed by the GPU driver and is the AMD path; actual support depends on the card, driver, and engine build. `Auto` prefers CUDA, then Vulkan, then CPU. The support list and default backend should be set only after testing representative AMD and NVIDIA PCs.

CUDA and Vulkan acceleration are built for Whisper and local notes. Speaker diarization (sherpa-onnx) and audio conversion (FFmpeg) run on the CPU. The Windows client uses the same model files and formats as the Mac app: all twelve Whisper weights, Silero VAD, Qwen3 GGUF, and the Sherpa speaker models. Windows downloads them separately under `%LOCALAPPDATA%\TranscribeToText`. `.whisper` archives are the portable way to move a transcript and its source audio between the apps; library records themselves contain platform-specific absolute paths.

The Windows GitHub Actions workflow builds the UI and runs portable core checks on `windows-latest`. This Mac development machine cannot execute WinUI's Windows XAML compiler or validate microphone/system-audio capture or GPU runtime behavior. The package script prepares a release ZIP locally on Windows; it does not publish or attach files to GitHub.

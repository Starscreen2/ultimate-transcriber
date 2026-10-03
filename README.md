# Ultimate Transcriber

An Apple Silicon Mac app for local audio and video transcription, speaker labels, and meeting notes. Audio, transcripts, and summaries stay on your Mac.

## Build

Requires macOS 13+, Xcode Command Line Tools, CMake, Git, and FFmpeg (`brew install ffmpeg`). Run:

```sh
./build-app.sh
```

Open `build/TranscribeToText.app`. The app is unsigned and may trigger a macOS security warning.

Run `./tests/run-regressions.sh` for local regression checks.

## Transcribe files

Choose a media file, model, and language, then select **Transcribe**. Text appears as it is recognized. **Copy Transcript** copies the preview; **Export…** saves TXT, SRT, or WebVTT. Speaker labels can be renamed and are reflected in the exports. Models are downloaded on first use and stored in `~/Library/Application Support/TranscribeToText/`.

## Capture meetings

Use the waveform menu bar icon to start or stop a meeting, open the app, or find recordings. **Meeting Settings…** controls microphone and system audio. System audio capture requires macOS 14.2 or later; microphone capture works on macOS 13+. The app records no screen video. Sessions save audio and speaker-labeled transcripts in timestamped folders.

**Generate Local Notes** creates an overview, key points, decisions, and action items. The first meeting may download Whisper Large v3 Turbo (about 1.6 GB); local notes download Qwen3-4B (about 2.5 GB) when first requested.

## License

The app is MIT licensed. It bundles whisper.cpp, llama.cpp, and sherpa-onnx; their notices are in [`ThirdPartyLicenses/`](ThirdPartyLicenses/). FFmpeg and downloaded models are separate and remain subject to their upstream licenses. See [`ThirdPartyNotices.md`](ThirdPartyNotices.md).

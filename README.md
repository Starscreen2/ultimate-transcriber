# Ultimate Transcriber

An Apple Silicon Mac app for local audio and video transcription, speaker labels, and meeting notes. Audio, transcripts, and summaries stay on your Mac.

## Build

Requires macOS 13+, Xcode Command Line Tools, CMake, Git, Python 3, and FFmpeg (`brew install ffmpeg`). Run:

```sh
./build-app.sh
```

Open `build/Transcribe to Text.app`. Local builds are certificate-signed using a persistent identity stored in `~/Library/Application Support/TranscribeToText/Signing/`. They are not notarized for distribution and may still trigger a macOS security warning. To use an existing developer certificate, set `SIGNING_IDENTITY` when running the build.

Run `./tests/run-regressions.sh` for local regression checks.

## Download

Download the prebuilt **Apple Silicon** app from [GitHub Releases](https://github.com/Starscreen2/ultimate-transcriber/releases/latest). Unzip it and move `Transcribe to Text.app` to Applications. It requires macOS 13 or later; system audio capture requires macOS 14.2 or later. Models are downloaded separately when first used. This release is not notarized and may trigger a macOS security warning.

## Transcribe files

Choose a media file, model, and language, then select **Transcribe**. Text appears as it is recognized. **Copy Transcript** copies the preview; **Export…** saves TXT, SRT, or WebVTT. Speaker labels can be renamed and are reflected in the exports. Models are downloaded on first use and stored in `~/Library/Application Support/TranscribeToText/`.

Select **Batch…** to add multiple files, remove selections, and start a sequential queue. The model, language, and speaker setting selected in the main window apply to the batch. Each file gets TXT, SRT, and WebVTT exports beside its source; the batch window shows progress, lets you cancel the current or remaining files, retry failures, open output folders, and load completed transcripts into the preview.

## Workspace and transcript library

The main window now uses a persistent workspace with Home, Queue, Transcriptions, Meetings, Recently Deleted, Folders, People, and Settings navigation. It keeps the existing local transcription engine, meeting capture, speaker recognition, model downloads, batch window, and activity queue behind the new interface.

Completed transcripts are saved to `~/Library/Application Support/TranscribeToText/library/transcriptions.json`. This library stores transcript text, segment times, speaker labels, the source and export paths, the chosen model/language, and basic counts/dates. Editing a segment or speaker and marking a favorite is saved to the library and refreshes the adjacent TXT/SRT/VTT exports. Moving an item to Recently Deleted only marks the library entry; the original media and exports stay in place. Permanent deletion removes the library record only. If the saved JSON cannot be read, the workspace surfaces a warning and blocks writes so a new save cannot overwrite the unreadable file.

The transcript workspace includes synchronized audio playback, transcript/Summary/Chat views, speaker reassignment, text search and replace, favorites, and a local Info inspector. Summary and transcript chat use the existing local Qwen notes model; first use may download about 2.5 GB. Chat is grounded in the open transcript. These local features do not call a cloud service.

**Export .whisper** writes a version 2 archive containing `version`, `metadata.json`, and the original audio, and the file chooser can import version 1 or 2 archives. Imported audio is extracted beneath `~/Library/Application Support/TranscribeToText/imported-archives/`. This implementation currently archives audio only; video archives, word-level timing, translations, tags, and richer editor metadata are not preserved. TXT, SRT, WebVTT, and the current archive path have regression coverage; archives from every MacWhisper release have not been validated.

Direct URL intake, cloud transcription, live caption overlays, per-app audio capture, voice memos, podcast track editing, watched-folder automation, translation, and external integrations are not implemented in this build. The workspace labels unavailable actions rather than suggesting that they work.

## Capture meetings

Use the waveform menu bar icon to start or stop a meeting, open the app, or find recordings. **Meeting Settings…** controls microphone and system audio. System audio capture requires macOS 14.2 or later; microphone capture works on macOS 13+. The app records no screen video. macOS asks for microphone and system-audio access on first use and reuses those approvals for subsequent meetings. Switching from an older hash-based build to the certificate-signed build requires one new approval; later rebuilds keep the same identity. If you revoke a permission in System Settings, the app respects that change. Keep the Signing folder private and intact: losing its certificate requires approving the replacement identity. Sessions save audio and speaker-labeled transcripts in timestamped folders.

If Whisper is still processing when you start another meeting, the new recording begins immediately and its transcription waits in line. File transcriptions use the same queue, so only one Whisper job runs at a time. The app waits for queued transcription work to finish before quitting.

**Meeting Settings… → Meeting detection** offers **Manual**, **Remind me** (default), and **Auto start recording and transcription**. Opening reminders cover native Zoom, Microsoft Teams, FaceTime, Slack, Discord, WhatsApp, Telegram, and WeChat, plus supported meeting websites. The banner offers **Start recording**, **Dismiss**, and **Snooze 10 min**. Desktop opening reminders work on macOS 13+ without extra permissions. Apps already running when the transcriber starts are eligible when you next bring them forward. Chat apps remind on opening even without a call. Dismiss prevents repeats for that app launch; quitting and reopening allows a new reminder. The transcriber must be running. **Preview reminder** shows the banner without recording.

Website reminders cover Google Meet, Teams, Zoom meeting links, FaceTime join links, Webex, Jitsi Meet, Whereby, RingCentral Video, GoTo Meeting, Slack, Discord, and WhatsApp Web. They require Accessibility access and an exposed URL in a supported browser. Installed Chrome/Edge/Brave/Safari web apps are inspected too when their URL is exposed. Landing pages and call pages count as one opening; briefly switching tabs does not repeat the reminder. **Add another app…** selects any other installed native calling app, including Webex, Signal or RingCentral. **Add meeting website…** watches an exact host for private, self-hosted or otherwise unlisted platforms. See [platform coverage and limits](docs/MeetingDetection.md#platform-coverage).

Auto start is limited to Zoom, Teams and Google Meet: it requires macOS 14.2+, confirmed English call controls, a recordings folder, and the downloaded meeting model. All other platforms show reminders. Opening an app or site alone never starts automatic capture.

The menu bar turns red while recording. Stop recordings manually: muting and silence do not stop capture. Automatic call detection currently matches English controls; hidden controls and inactive browser tabs may prevent detection. Manual Start Meeting is always available. See [detection research and limitations](docs/MeetingDetection.md).

**Generate Local Notes** creates an overview, key points, decisions, and action items. The first meeting may download Whisper Large v3 Turbo (about 1.6 GB); local notes download Qwen3-4B (about 2.5 GB) when first requested.

## License

The app is MIT licensed. It bundles whisper.cpp, llama.cpp, and sherpa-onnx; their notices are in [`ThirdPartyLicenses/`](ThirdPartyLicenses/). FFmpeg and downloaded models are separate and remain subject to their upstream licenses. See [`ThirdPartyNotices.md`](ThirdPartyNotices.md).

Meeting recovery: TXT, SRT and VTT are retained if audio conversion or speaker detection fails. The app checks the finished mix for usable audio before removing the original capture tracks; if the mix is silent or only contains a noise floor, it saves no transcript and keeps the original tracks. If an audio source fails, the app warns immediately and keeps any healthy source recording; when all sources fail, it finishes the session. Cancelled startup also preserves text and audio already captured. A stalled live engine has a bounded audio queue; after overflow, audio continues saving and the app warns that it needs transcription afterward.

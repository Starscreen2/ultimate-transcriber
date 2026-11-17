# Windows validation checklist

Use this checklist on a Windows 10/11 x64 PC. Start with the CPU engine; test GPU engines only after the CPU path works.

## App and transcription

- [ ] Build and launch the WinUI app from the commands in `README.md`.
- [ ] Download `tiny` or `base`, transcribe a short speech recording, and confirm TXT, SRT, and WebVTT files are written beside the source.
- [ ] Try an English-only model and confirm its language controls are locked to English.
- [ ] Try a custom Whisper language code with a multilingual model.
- [ ] Add two files to Batch, start the queue, cancel an active file, and confirm the remaining queue status is clear.

## Cross-platform data and local models

- [ ] Import a `.whisper` file exported by the Mac app; confirm the source audio, segment times, and speaker labels appear.
- [ ] Edit transcript text and speaker names, save, and confirm the sidecar exports and library update.
- [ ] Export a Windows `.whisper` file and import it back into both apps.
- [ ] Download Qwen3 and generate notes plus an answer to a question while disconnected from model hosts after download.
- [ ] Move an entry to Recently Deleted, restore it, then permanently remove the library entry and confirm its source audio remains on disk.

## Meeting capture

- [ ] Record microphone audio only, stop, and transcribe.
- [ ] Record system audio only, stop, and transcribe.
- [ ] Record both sources, then confirm the mixed file and both original WAV tracks remain in the session folder.
- [ ] Close the app during a recording and confirm the original tracks are finalized and preserved.
- [ ] Turn on meeting reminders and confirm a detected window only opens the Meetings page; it must not start recording.

## Hardware

- [ ] On an NVIDIA PC, build the CUDA engines and transcribe with CUDA; then select Auto and confirm it chooses a working backend.
- [ ] On an AMD PC, build the Vulkan engines and transcribe with Vulkan; test at least one multilingual Whisper model and local notes.
- [ ] Confirm CPU transcription still works after removing or disabling the GPU engine folder.
- [ ] Record the GPU model, driver version, selected backend, and any engine error text with the result.

Speaker diarization uses the CPU in this Windows version. Test it on a recording with two clearly distinct speakers, then rename the labels and save.

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEST_PYTHON="${TEST_PYTHON:-$(command -v python3)}"
export TEST_PYTHON
export PYTHONDONTWRITEBYTECODE=1
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/transcriber-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
SWIFT_FLAGS=(-DREGRESSION_TESTS -parse-as-library -swift-version 5 -target arm64-apple-macos13.0
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework ApplicationServices -framework UniformTypeIdentifiers)
TEST_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_SOURCES=(TranscribeToText.swift BatchTranscription.swift ActivityCenter.swift MeetingCapture.swift LocalMeetingSummarizer.swift MeetingDetection.swift)
swiftc "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" tests/CoreRegressionTests.swift -o "$TEMP_ROOT/core-regressions"
swiftc "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" tests/MeetingDetectionTests.swift -o "$TEMP_ROOT/detection-regressions"
"${CXX:-c++}" -std=c++17 -isystem"$TEST_MACOS_SDK/usr/include/c++/v1" \
  tests/meeting_whisper_audio_gate.cpp -o "$TEMP_ROOT/audio-gate-regressions"
"$TEMP_ROOT/audio-gate-regressions"
"$TEMP_ROOT/detection-regressions"
"$TEMP_ROOT/core-regressions"
swiftc "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" tests/summary-regressions.swift -o "$TEMP_ROOT/summary-regressions"
"$TEMP_ROOT/summary-regressions" "$@"
"$TEST_PYTHON" tests/meeting_worker_regressions.py
"$TEST_PYTHON" tests/meeting_capture_regressions.py
"$TEST_PYTHON" tests/test_meeting_whisper.py
"$TEST_PYTHON" tests/test_build_packaging.py
"$TEST_PYTHON" tests/signing_identity_regressions.py
if [[ " $* " == *" --real-model "* ]]; then
  SMOKE_APP="$TEMP_ROOT/FileSmoke.app"
  mkdir -p "$SMOKE_APP/Contents/MacOS"
  ln -s "$ROOT/build/Transcribe to Text.app/Contents/Resources" "$SMOKE_APP/Contents/Resources"
  cat > "$SMOKE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>FileSmoke</string><key>CFBundleIdentifier</key><string>local.transcriber.tests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
  swiftc "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" tests/FileTranscriptionSmoke.swift -o "$SMOKE_APP/Contents/MacOS/FileSmoke"
  "$SMOKE_APP/Contents/MacOS/FileSmoke"
  swiftc "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" tests/MeetingCaptureStartupSmoke.swift -o "$SMOKE_APP/Contents/MacOS/StartupSmoke"
  "$SMOKE_APP/Contents/MacOS/StartupSmoke"
fi

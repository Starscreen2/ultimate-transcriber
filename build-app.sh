#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor/whisper.cpp"
SHERPA="$ROOT/vendor/sherpa-onnx"
LLAMA="$ROOT/vendor/llama.cpp"
APP_DESTINATION="$ROOT/build/TranscribeToText.app"

if ! command -v cmake >/dev/null 2>&1; then
  echo "CMake is required. Install it with: brew install cmake" >&2
  exit 1
fi

if [ ! -d "$SHERPA/.git" ]; then
  mkdir -p "$ROOT/vendor"
  git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx.git "$SHERPA"
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift is required. Install the Xcode Command Line Tools first." >&2
  exit 1
fi

if [ ! -d "$VENDOR/.git" ]; then
  mkdir -p "$ROOT/vendor"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$VENDOR"
fi
if [ ! -d "$LLAMA/.git" ]; then
  mkdir -p "$ROOT/vendor"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA"
fi

# Some macOS Command Line Tools installations have incomplete toolchain C++
# header directories; point clang at the SDK's libc++ headers explicitly.
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

cmake -S "$ROOT/MeetingWhisper" -B "$ROOT/build/meeting-whisper" \
  -DWHISPER_CPP_PATH="$VENDOR" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-isystem${MACOS_SDK}/usr/include/c++/v1" \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_BLAS=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$ROOT/build/meeting-whisper" --config Release --target whisper-cli meeting-whisper -j "$(sysctl -n hw.ncpu)"

cmake -S "$LLAMA" -B "$LLAMA/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_CXX_FLAGS="-isystem${MACOS_SDK}/usr/include/c++/v1" \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_BLAS=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_SERVER=ON
cmake --build "$LLAMA/build" --config Release --target llama-cli -j "$(sysctl -n hw.ncpu)"

cmake -S "$SHERPA" -B "$SHERPA/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_CXX_FLAGS="-isystem${MACOS_SDK}/usr/include/c++/v1" \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=OFF \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=OFF
cmake --build "$SHERPA/build" --config Release --target sherpa-onnx-offline-speaker-diarization -j "$(sysctl -n hw.ncpu)"

# Assemble and verify a new bundle before replacing the installed build. A Swift
# compilation or resource failure must leave the previous working app available.
STAGING_ROOT="$(mktemp -d "$ROOT/build/.TranscribeToText-build.XXXXXX")"
APP="$STAGING_ROOT/TranscribeToText.app"
cleanup_staging() {
  if [ -e "$STAGING_ROOT/Previous.app" ] && [ ! -e "$APP_DESTINATION" ]; then
    if ! mv "$STAGING_ROOT/Previous.app" "$APP_DESTINATION"; then
      echo "The previous app is preserved at $STAGING_ROOT/Previous.app" >&2
      return
    fi
  fi
  rm -rf "$STAGING_ROOT"
}
trap cleanup_staging EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AVFoundation -framework UniformTypeIdentifiers -framework AppKit \
  -framework CoreAudio \
  "$ROOT/TranscribeToText.swift" "$ROOT/MeetingCapture.swift" "$ROOT/LocalMeetingSummarizer.swift" \
  -o "$APP/Contents/MacOS/TranscribeToText"
cp "$ROOT/build/meeting-whisper/bin/whisper-cli" "$APP/Contents/Resources/whisper-cli"
cp "$ROOT/build/meeting-whisper/bin/meeting-whisper" "$APP/Contents/Resources/meeting-whisper"
cp "$LLAMA/build/bin/llama-cli" "$APP/Contents/Resources/llama-cli"
cp "$SHERPA/build/bin/sherpa-onnx-offline-speaker-diarization" "$APP/Contents/Resources/sherpa-onnx-offline-speaker-diarization"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp -R "$ROOT/ThirdPartyLicenses/." "$APP/Contents/Resources/ThirdPartyLicenses/"
cp "$LLAMA/LICENSE" "$APP/Contents/Resources/ThirdPartyLicenses/llama.cpp-MIT.txt"
chmod +x "$APP/Contents/Resources/whisper-cli" "$APP/Contents/Resources/meeting-whisper" "$APP/Contents/Resources/llama-cli"
chmod +x "$APP/Contents/Resources/sherpa-onnx-offline-speaker-diarization"
# All third-party engines are statically linked. Reject a cached configuration
# that would make the copied helper rely on a library outside this app bundle.
for EXECUTABLE in "$APP/Contents/Resources/whisper-cli" \
  "$APP/Contents/Resources/meeting-whisper" \
  "$APP/Contents/Resources/llama-cli" \
  "$APP/Contents/Resources/sherpa-onnx-offline-speaker-diarization"; do
  if ! lipo -verify_arch arm64 "$EXECUTABLE"; then
    echo "The bundled engine is missing its arm64 build: $EXECUTABLE" >&2
    exit 1
  fi
  UNBUNDLED_LIBRARIES="$(otool -L "$EXECUTABLE" | awk 'NR > 1 {print $1}' | \
    awk '!/^\/usr\/lib\// && !/^\/System\/Library\//')"
  if [ -n "$UNBUNDLED_LIBRARIES" ]; then
    echo "The bundled engine depends on libraries outside the app: $EXECUTABLE" >&2
    echo "$UNBUNDLED_LIBRARIES" >&2
    exit 1
  fi
done
ICONSET="$STAGING_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TranscribeToText</string>
  <key>CFBundleIdentifier</key><string>local.transcribetotext.app</string>
  <key>CFBundleName</key><string>Transcribe to Text</string>
  <key>CFBundleDisplayName</key><string>Transcribe to Text</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Transcribe to Text uses microphone audio to record and transcribe meetings on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Transcribe to Text captures audio playing through this Mac so it can transcribe and save meeting notes locally.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
if [ -e "$APP_DESTINATION" ]; then
  mv "$APP_DESTINATION" "$STAGING_ROOT/Previous.app"
fi
if ! mv "$APP" "$APP_DESTINATION"; then
  if [ -e "$STAGING_ROOT/Previous.app" ]; then
    mv "$STAGING_ROOT/Previous.app" "$APP_DESTINATION"
  fi
  exit 1
fi
echo "Built $APP_DESTINATION"

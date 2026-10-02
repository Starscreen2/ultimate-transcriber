#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor/whisper.cpp"
SHERPA="$ROOT/vendor/sherpa-onnx"
APP="$ROOT/build/TranscribeToText.app"

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

# Some macOS Command Line Tools installations have incomplete toolchain C++
# header directories; point clang at the SDK's libc++ headers explicitly.
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

cmake -S "$VENDOR" -B "$VENDOR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-isystem${MACOS_SDK}/usr/include/c++/v1" \
  -DGGML_METAL=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$VENDOR/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"

cmake -S "$SHERPA" -B "$SHERPA/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-isystem${MACOS_SDK}/usr/include/c++/v1" \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=OFF
cmake --build "$SHERPA/build" --config Release --target sherpa-onnx-offline-speaker-diarization -j "$(sysctl -n hw.ncpu)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AVFoundation -framework UniformTypeIdentifiers -framework AppKit \
  "$ROOT/TranscribeToText.swift" -o "$APP/Contents/MacOS/TranscribeToText"
cp "$VENDOR/build/bin/whisper-cli" "$APP/Contents/Resources/whisper-cli"
cp "$SHERPA/build/bin/sherpa-onnx-offline-speaker-diarization" "$APP/Contents/Resources/sherpa-onnx-offline-speaker-diarization"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp -R "$ROOT/ThirdPartyLicenses/." "$APP/Contents/Resources/ThirdPartyLicenses/"
chmod +x "$APP/Contents/Resources/whisper-cli"
chmod +x "$APP/Contents/Resources/sherpa-onnx-offline-speaker-diarization"
ICONSET="$ROOT/build/AppIcon.iconset"
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "Built $APP"

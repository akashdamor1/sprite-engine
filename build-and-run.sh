#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/GrokAvatar.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES"
cp -f "$ROOT/Models/tifa_animated.usdz" "$RES/tifa_animated.usdz"
cp -f "$ROOT/Models/tifa_sexy.usdz" "$RES/tifa_sexy.usdz"
cp -f "$ROOT/Models/facecap.usdz" "$RES/facecap.usdz"
cp -f "$ROOT/Models/skin_albedo.png" "$RES/skin_albedo.png"
cp -f "$ROOT/Models/eye_albedo.png" "$RES/eye_albedo.png"
cp -f "$ROOT/Models/anime-face.jpg" "$RES/anime-face.jpg"
# VN sprite frames (head/eyes/mouth) for AnimeFaceView
rm -rf "$RES/sprites"
mkdir -p "$RES/sprites"
cp -f "$ROOT/Models/sprites/"*.png "$ROOT/Models/sprites/sprite_manifest.json" "$RES/sprites/"

# Quit any previous instance
pkill -x GrokAvatar 2>/dev/null || true
sleep 0.3

SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework SceneKit \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework Vision \
  -framework CoreMedia \
  -framework Accelerate \
  -framework SwiftUI \
  -framework AppKit \
  -framework QuartzCore \
  -O \
  "$ROOT/GrokAvatar/GrokAvatarApp.swift" \
  "$ROOT/GrokAvatar/HeadSceneView.swift" \
  "$ROOT/GrokAvatar/HeadRig.swift" \
  "$ROOT/GrokAvatar/LipSyncEngine.swift" \
  "$ROOT/GrokAvatar/FaceTracker.swift" \
  "$ROOT/GrokAvatar/SystemAudioCapture.swift" \
  "$ROOT/GrokAvatar/AnimeFaceView.swift" \
  -o "$MACOS/GrokAvatar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>GrokAvatar</string>
  <key>CFBundleIdentifier</key>
  <string>com.akashdamor.GrokAvatar</string>
  <key>CFBundleName</key>
  <string>GrokAvatar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>GrokAvatar captures system audio levels (not screen content) so the avatar can lip-sync to Grok Bot and other playing audio.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>GrokAvatar measures system audio so the avatar mouth can sync to playing speech.</string>
  <key>NSCameraUsageDescription</key>
  <string>GrokAvatar uses the camera to track your face so the avatar eyes can look toward you.</string>
</dict>
</plist>
PLIST

open "$APP"
echo "Launched $APP"

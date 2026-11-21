#!/bin/zsh
# Builds Kiri.app (universal: Apple Silicon + Intel, macOS 14+). Double-click to run; no Dock icon.
#   ./make-app.sh          universal release build
#   ./make-app.sh --fast   quicker build for this Mac only
#   ./make-app.sh --install  build and move into /Applications
set -e
cd "${0:A:h}"
VERSION="1.2.1"

if [[ "$1" == "--fast" ]]; then
  swift build -c release
  BIN=.build/release/Kiri
else
  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -vE "x86_64 architecture is deprecated" || true
  BIN=.build/out/Products/Release/Kiri
  [[ -f "$BIN" ]] || BIN=.build/apple/Products/Release/Kiri
fi

APP="Kiri.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kiri"
[ -d characters ] && cp -R characters "$APP/Contents/Resources/characters"
[ -f packaging/Kiri.icns ] && cp packaging/Kiri.icns "$APP/Contents/Resources/Kiri.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kiri</string>
  <key>CFBundleDisplayName</key><string>Kiri</string>
  <key>CFBundleIdentifier</key><string>app.kiri.owl</string>
  <key>CFBundleExecutable</key><string>Kiri</string>
  <key>CFBundleIconFile</key><string>Kiri</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Kiri listens when you press ⌥Space or the mic button, so you can give voice commands.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Kiri turns your voice commands into text (on your Mac when possible).</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Kiri adds reminders when you ask it to.</string>
  <key>NSRemindersUsageDescription</key><string>Kiri adds reminders when you ask it to.</string>
  <key>NSHumanReadableCopyright</key><string>Kiri — a desktop pet that codes with you.</string>
</dict>
</plist>
PLIST
# Sign with the stable local identity only if macOS trusts it (an untrusted one is refused by Screen Recording), so macOS keeps Kiri's permissions across rebuilds.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Kiri Local Signing"/ {print $2; exit}')
if [[ -n "$SIGN_ID" ]] && codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
  echo "Signed with Kiri Local Signing"
else
  # Ad-hoc, but with a requirement that names only the app ID (not this exact build), so macOS
  # keeps Kiri's permissions (Screen Recording, Downloads...) across rebuilds.
  codesign --force --deep --sign - -r='designated => identifier "app.kiri.owl"' "$APP" >/dev/null 2>&1 || true
  echo "Signed ad-hoc with a stable requirement (permissions survive rebuilds)"
fi
echo "Built $(pwd)/$APP  ($(lipo -archs "$APP/Contents/MacOS/Kiri"))"

# ./make-app.sh --install   also moves the app into /Applications (needed for Screen Recording permission)
if [[ " $* " == *" --install "* ]]; then
  pkill -f "MacOS/Kiri" 2>/dev/null || true
  rm -rf /Applications/Kiri.app && mv "$APP" /Applications/Kiri.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Kiri.app
  echo "Installed to /Applications/Kiri.app"
fi

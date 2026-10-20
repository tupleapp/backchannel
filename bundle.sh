#!/bin/sh
# Build and wrap the executable in a .app bundle at build/Backchannel.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Backchannel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Backchannel "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Backchannel</string>
  <key>CFBundleIdentifier</key><string>app.tuple.backchannel</string>
  <key>CFBundleExecutable</key><string>Backchannel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>While you're muted in Tuple, what you say goes privately to Amp.</string>
</dict></plist>
PLIST
# Sign so macOS can grant microphone access.
codesign --force --sign - "$APP"
echo "Built $APP"

#!/bin/bash
# Builds a universal, ad-hoc signed "dist/Notes Thing.app" and dist/NotesThing.zip.
# Usage: VERSION=1.2.3 scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
APP="dist/Notes Thing.app"

swift build -c release --arch arm64 --arch x86_64

rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp .build/apple/Products/Release/NotesThing "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Notes Thing</string>
  <key>CFBundleDisplayName</key><string>Notes Thing</string>
  <key>CFBundleIdentifier</key><string>com.yoelgal.notesthing</string>
  <key>CFBundleExecutable</key><string>NotesThing</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records your lectures so they can be transcribed on this Mac.</string>
</dict></plist>
PLIST

# Ad-hoc signature: required to run on Apple Silicon. No Apple Developer account needed.
# ponytail: macOS re-asks for mic access after each rebuild; a Developer ID signature fixes that.
codesign --force --sign - "$APP"
(cd dist && ditto -c -k --keepParent "Notes Thing.app" NotesThing.zip)
echo "Built $APP ($VERSION)"

if [ "${1:-}" = "--install" ]; then
  pkill -x NotesThing 2>/dev/null || true
  rm -rf "/Applications/Notes Thing.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Notes Thing.app"
fi

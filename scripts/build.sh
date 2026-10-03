#!/bin/bash
# Builds a universal, ad-hoc signed "dist/Notes Thing.app" and dist/NotesThing.zip.
# Usage: VERSION=1.2.3 scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
APP="dist/Notes Thing.app"

swift build -c release --package-path app --arch arm64 --arch x86_64

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/.build/apple/Products/Release/NotesThing "$APP/Contents/MacOS/"
cp app/AppIcon.icns "$APP/Contents/Resources/"
# Sparkle, minus the XPC services only sandboxed apps need.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto app/.build/apple/Products/Release/Sparkle.framework "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Notes Thing</string>
  <key>CFBundleDisplayName</key><string>Notes Thing</string>
  <key>CFBundleIdentifier</key><string>com.yoelgal.notesthing</string>
  <key>CFBundleExecutable</key><string>NotesThing</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://github.com/yoelgal/notes-thing/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>OIXJMQORA3X2MJW+sf9lDwE9vwV1tKCvIhDqkdyjruE=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records audio so it can be transcribed on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Records what your Mac plays, like the other side of a call, so it can be transcribed on this Mac.</string>
</dict></plist>
PLIST

# Signed with a fixed self-signed certificate, so macOS keeps the mic permission across updates
# (an ad-hoc signature changes every build, so each update looked like a new app). No Apple account needed.
# CI imports it into $SIGN_KEYCHAIN; locally it's in the login keychain. Without it, local builds fall back
# to ad-hoc, but CI fails: shipping ad-hoc would reset everyone's mic permission.
IDENTITY="Notes Thing Signing"
KEYCHAIN_ARGS=()
[ -n "${SIGN_KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
if ! security find-identity -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} | grep -q "\"$IDENTITY\""; then
  [ -n "${CI:-}" ] && { echo "error: \"$IDENTITY\" certificate missing" >&2; exit 1; }
  echo "warning: \"$IDENTITY\" not in keychain, signing ad-hoc"
  IDENTITY=-
fi
# Sparkle's helpers get the same signature: it won't launch them if they don't match the app.
for p in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE" "$APP"; do
  codesign --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$p"
done
(cd dist && ditto -c -k --keepParent "Notes Thing.app" NotesThing.zip)
echo "Built $APP ($VERSION)"

if [ "${1:-}" = "--install" ]; then
  pkill -x NotesThing 2>/dev/null || true
  rm -rf "/Applications/Notes Thing.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Notes Thing.app"
fi

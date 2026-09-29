#!/bin/sh
# Builds build/Notes Thing.app. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Notes Thing.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotesThing "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# ponytail: ad-hoc signature, so macOS re-asks for mic access after each rebuild; use a Developer ID if that gets annoying
codesign --force --sign - "$APP"
if [ "$1" = "--install" ]; then
  rm -rf "/Applications/Notes Thing.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Notes Thing.app"
fi

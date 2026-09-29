#!/bin/bash
# Notes Thing installer: curl -fsSL https://notesthing.yoelgal.com/install.sh | bash
#
# Why a script? The app isn't notarized (no paid Apple Developer account). Files downloaded
# by a browser get a quarantine flag that makes macOS block unnotarized apps. Files fetched
# with curl don't, so the app opens normally. Read this script before running it, it's short.
set -euo pipefail

REPO="yoelgal/notes-thing"
NAME="Notes Thing.app"
URL="https://github.com/$REPO/releases/latest/download/NotesThing.zip"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
step() { printf "%s==>%s %s\n" "$bold" "$reset" "$1"; }
fail() { printf "%sError:%s %s\n" "$red" "$reset" "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "Notes Thing is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Notes Thing needs macOS 14 (Sonoma) or newer."

# /Applications is writable for admin users; fall back to ~/Applications otherwise.
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

step "Downloading the latest release"
curl -fL --progress-bar "$URL" -o "$tmp/app.zip" || fail "Download failed. Check your connection and try again."
ditto -x -k "$tmp/app.zip" "$tmp"

if pgrep -x NotesThing >/dev/null; then
  step "Quitting the running copy"
  osascript -e 'quit app id "com.yoelgal.notesthing"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x NotesThing 2>/dev/null || true
fi

step "Installing to $DEST"
rm -rf "$DEST/$NAME"
mv "$tmp/$NAME" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$NAME" 2>/dev/null || true

step "Opening Notes Thing"
open "$DEST/$NAME"

printf "\n%s✓ Installed.%s Look for the icon in your menu bar. ⌃⌥P starts a session.\n" "$green" "$reset"
printf "%s  First run downloads the speech model (~650 MB).\n" "$dim"
printf "  Update: run this command again.\n"
printf "  Uninstall: quit the app and drag it from %s to the Trash. Your sessions stay in ~/Sessions.%s\n" "$DEST" "$reset"

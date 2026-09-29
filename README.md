# Notes Thing

Menu bar recorder for lectures: record, pause, jot notes, get a transcript with your notes slotted in where you wrote them. Transcribes on-device with Parakeet TDT v2 (via FluidAudio). UI adapted from [Hex](https://github.com/kitlangton/Hex) (MIT, see `LICENSE-Hex`).

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/yoelgal/notes-thing/main/install.sh | bash
```

It downloads the latest release to `/Applications` and opens it. Look for the waveform in your menu bar.

Or with Homebrew: `brew install --cask yoelgal/tap/notes-thing`

Requires macOS 14 (Sonoma) or newer. The first run downloads the speech model (~650 MB).

<details>
<summary>Why a terminal command? / Manual install</summary>

Notes Thing isn't notarized by Apple (that needs a paid developer account). macOS blocks
unnotarized apps downloaded in a browser, but not ones fetched with `curl`, so the one-liner
just works. [Read the script](install.sh): it's 50 lines.

**Manual install:** download `NotesThing.zip` from the [latest release](https://github.com/yoelgal/notes-thing/releases/latest),
unzip it, and drag **Notes Thing** to Applications. The first time you open it, macOS will say it
can't verify the developer. Click **Done**, then go to **System Settings → Privacy & Security**,
scroll down, and click **Open Anyway**. You only need to do this once.

To update, run the install command again.
</details>

## Uninstall

Quit from the menu, then drag **Notes Thing** from Applications to the Trash. Your recordings stay in `~/Sessions`.

## Use
- `⌃⌥P`: start a session / pause / resume
- `⌃⌥N`: note field (Enter saves, Esc cancels). A note is timed from its first keystroke.
- Menu bar → **Stop & Transcribe**: writes `~/Sessions/<id>/session.md` and copies `/notes <id>` to the clipboard.

Each session folder: `events.jsonl` (written live), `audio.caf` while recording → `audio.m4a` after, `session.md`.

Quit mid-session? The audio and notes are safe on disk; rebuild the transcript with
`"/Applications/Notes Thing.app/Contents/MacOS/NotesThing" --finish ~/Sessions/<id>`.

## Build from source

```sh
git clone https://github.com/yoelgal/notes-thing && cd notes-thing
scripts/build.sh              # → dist/Notes Thing.app
scripts/build.sh --install    # also copies it to /Applications
swift build && .build/debug/NotesThing --selfcheck   # transcript formatting check
```

Needs Xcode 16+ (Swift 6). Releases are built by GitHub Actions from tags (`git tag v1.2.3 && git push --tags`).

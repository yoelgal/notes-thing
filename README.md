# Notes Thing

Menu bar recorder for lectures: record, pause, jot notes, get a transcript with your notes slotted in where you wrote them. Transcribes on-device with Parakeet TDT v2 (via FluidAudio). UI adapted from [Hex](https://github.com/kitlangton/Hex) (MIT, see `LICENSE-Hex`).

## Use
- `⌃⌥P`: start a session / pause / resume
- `⌃⌥N`: note field (Enter saves, Esc cancels). A note is timed from its first keystroke.
- Menu bar → **Stop & Transcribe**: writes `~/Sessions/<id>/session.md` and copies `/notes <id>` to the clipboard.

Each session folder: `events.jsonl` (written live), `audio.caf` while recording → `audio.m4a` after, `session.md`.

Quit mid-session? The audio and notes are safe on disk; rebuild the transcript with
`"/Applications/Notes Thing.app/Contents/MacOS/NotesThing" --finish ~/Sessions/<id>`.

## Build
```sh
./build.sh            # → build/Notes Thing.app
./build.sh --install  # also copies to /Applications
.build/debug/NotesThing --selfcheck   # transcript formatting check (after `swift build`)
```
First launch downloads the model (~650 MB) to `~/Library/Application Support/FluidAudio`.

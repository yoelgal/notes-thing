---
name: notes
description: Read a Notes Thing recording (~/Sessions/<id>/session.md), a timestamped transcript with the user's own notes slotted in where they wrote them. Use when the user runs /notes <id> or asks about a meeting, lecture, call or other recording they made with Notes Thing.
argument-hint: "[session id]"
---

Session id: $ARGUMENTS

Find the sessions folder: run `defaults read com.yoelgal.notesthing sessionsFolder`, and if that prints nothing, it's `~/Sessions`. Read `<folder>/<id>/session.md` for that id. If it's a path instead, read `session.md` in that folder. If nothing was given, use the newest session in the folder.

How the file reads:
- The front matter has the id, date, start time and duration.
- Transcript lines start with `[mm:ss]` from the start of the recording, with `**Speaker 1:**` style labels when there was more than one voice.
- `> **note [mm:ss]:** …` lines are the user's own notes, placed after what was being said when they started typing. They mark what the user found important, confusing or worth acting on, so read each one with the lines around it.
- `--- paused … ---` marks a pause; a note tagged `paused` was written during it.

Unless the user asks for something else: give a short summary, then go through every note and explain what it refers to using the surrounding transcript. Answer questions in the notes, expand shorthand, and pull out action items. Cite timestamps so the user can find the moment in `audio.m4a`.

import AVFoundation

/// One line of `events.jsonl`. `t` is recording time: it only advances while recording,
/// so it matches positions in the audio file (and the transcript's token timings).
struct Event: Codable {
  enum Kind: String, Codable { case start, pause, resume, note, stop }
  var kind: Kind
  var t: TimeInterval
  var wall: Date
  var text: String?
  var paused: Bool?
}

/// A transcribed token: `text` uses the SentencePiece "▁" (or a leading space) to mark a word start.
struct Token {
  var text: String
  var start: TimeInterval
  /// "Speaker 1", "Speaker 2"… from diarization; nil if it didn't run.
  var speaker: String? = nil
}

struct Sentence {
  var start: TimeInterval
  var text: String
  var speaker: String? = nil
}

enum Transcript {
  /// Tags each token with the diarized speaker talking at its start time. A token in a gap between
  /// segments goes to the nearer one (a speaker's first word often starts just before their segment).
  /// Raw cluster ids are renamed "Speaker N" in order of first appearance, so Speaker 1 talks first.
  static func assignSpeakers(_ tokens: [Token], segments: [(start: TimeInterval, end: TimeInterval, id: String)]) -> [Token] {
    let segs = segments.sorted { $0.start < $1.start }
    guard !segs.isEmpty else { return tokens }
    var names: [String: String] = [:]
    var i = 0
    return tokens.map { token in
      while i + 1 < segs.count, segs[i + 1].start <= token.start { i += 1 }
      var seg = segs[i]
      if token.start > seg.end, i + 1 < segs.count, segs[i + 1].start - token.start < token.start - seg.end { seg = segs[i + 1] }
      if names[seg.id] == nil { names[seg.id] = "Speaker \(names.count + 1)" }
      var t = token
      t.speaker = names[seg.id]
      return t
    }
  }

  /// Maps a piece's speakers (id → voice embedding) to speakers from earlier pieces: the most
  /// similar voice if it's close enough, else a new speaker. `voices` holds each speaker's
  /// running sum of unit embeddings.
  static func match(_ piece: [String: [Float]], voices: inout [[Float]], threshold: Float = 0.4) -> [String: String] {
    func unit(_ v: [Float]) -> [Float] {
      let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
      return n > 0 ? v.map { $0 / n } : v
    }
    func cos(_ a: [Float], _ b: [Float]) -> Float { zip(unit(a), b).reduce(0) { $0 + $1.0 * $1.1 } }
    var ids: [String: String] = [:]
    for (id, raw) in piece.sorted(by: { $0.key < $1.key }) {
      let v = unit(raw)
      if let i = voices.indices.max(by: { cos(voices[$0], v) < cos(voices[$1], v) }), cos(voices[i], v) >= threshold {
        voices[i] = zip(voices[i], v).map(+)
        ids[id] = "V\(i)"
      } else {
        voices.append(v)
        ids[id] = "V\(voices.count - 1)"
      }
    }
    return ids
  }

  /// Groups tokens into sentences, breaking on . ? ! and at every pause so a pause marker
  /// never lands in the middle of a sentence.
  static func sentences(_ tokens: [Token], breaks: [TimeInterval]) -> [Sentence] {
    var out: [Sentence] = []
    var current: Sentence?
    var pending = breaks.sorted()[...]
    func flush() {
      if let s = current, !s.text.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append(Sentence(start: s.start, text: s.text.trimmingCharacters(in: .whitespaces), speaker: s.speaker))
      }
      current = nil
    }
    for token in tokens {
      if let b = pending.first, token.start >= b {
        flush()
        while let b = pending.first, token.start >= b { pending.removeFirst() }
      }
      // ponytail: 30 s cap on run-on sentences, the recogniser sometimes omits punctuation
      if let s = current, token.start - s.start > 30 { flush() }
      if let s = current, s.speaker != token.speaker { flush() }
      let piece = token.text.replacingOccurrences(of: "▁", with: " ")
      if current == nil { current = Sentence(start: token.start, text: "", speaker: token.speaker) }
      current!.text += piece
      if let last = piece.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last) { flush() }
    }
    flush()
    return out
  }

  static func stamp(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
      : String(format: "%02d:%02d", s / 60, s % 60)
  }

  /// Renders `session.md`: sentences with notes and pause markers slotted in after the
  /// sentence that was being spoken at their recording time. With two or more speakers, a
  /// `**Speaker N:**` label marks each change of speaker; `names` swaps in names from speakers.json.
  static func render(id: String, events: [Event], tokens: [Token], names: [String: String] = [:], error: String? = nil) -> String {
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm"
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"

    // Inserts: (recording time, markdown). Pauses pair with the next resume/stop for their wall-clock span.
    var inserts: [(TimeInterval, String)] = []
    for (i, e) in events.enumerated() {
      switch e.kind {
      case .pause:
        let end = events[(i + 1)...].first { $0.kind == .resume || $0.kind == .stop }
        let span = end.map { "\(clock.string(from: e.wall))–\(clock.string(from: $0.wall))" } ?? clock.string(from: e.wall)
        inserts.append((e.t, "--- paused \(span) ---"))
      case .note:
        let tag = e.paused == true ? ", paused" : ""
        inserts.append((e.t, "> **note [\(stamp(e.t))\(tag)]:** \(e.text ?? "")"))
      default: break
      }
    }

    let start = events.first?.wall ?? Date()
    let duration = events.last?.t ?? 0
    var lines = [
      "---", "id: \(id)", "date: \(day.string(from: start))", "start: \(clock.string(from: start))",
      "duration: \(stamp(duration))", "---", "",
    ]
    if let error { lines += ["> [!warning] Transcription failed: \(error). Notes below; audio is in the session folder.", ""] }

    let pauses = events.filter { $0.kind == .pause }.map(\.t)
    var queue = inserts[...] // already in time order: events are appended as they happen
    let labelled = Set(tokens.compactMap(\.speaker)).count > 1
    var lastSpeaker: String?
    for s in sentences(tokens, breaks: pauses) {
      while let (t, md) = queue.first, t < s.start { lines.append(md); queue.removeFirst() }
      var label = ""
      if labelled, let sp = s.speaker, sp != lastSpeaker { label = "**\(names[sp] ?? sp):** " }
      lastSpeaker = s.speaker
      lines.append("[\(stamp(s.start))] \(label)\(s.text)")
    }
    lines += queue.map(\.1)
    return lines.joined(separator: "\n") + "\n"
  }

  /// Run with `NotesThing --selfcheck`.
  static func selfCheck() {
    let w = Date(timeIntervalSince1970: 0)
    let events = [
      Event(kind: .start, t: 0, wall: w),
      Event(kind: .note, t: 3, wall: w, text: "why?", paused: false),
      Event(kind: .pause, t: 6, wall: w),
      Event(kind: .note, t: 6, wall: w, text: "later", paused: true),
      Event(kind: .resume, t: 6, wall: w),
      Event(kind: .stop, t: 9, wall: w),
    ]
    let tokens = [
      Token(text: "▁Hello", start: 0), Token(text: "▁world", start: 1), Token(text: ".", start: 2),
      Token(text: "▁So", start: 4), Token(text: "▁then", start: 5), // no full stop: pause must split it
      Token(text: "▁next", start: 7), Token(text: ".", start: 8),
    ]
    let s = sentences(tokens, breaks: [6])
    assert(s.map(\.text) == ["Hello world.", "So then", "next."], "\(s)")
    let md = render(id: "x", events: events, tokens: tokens)
    let body = md.components(separatedBy: "---\n\n")[1]
    assert(body.contains("[00:00] Hello world.\n> **note [00:03]:** why?\n[00:04] So then\n--- paused"), body)
    assert(body.contains("---\n> **note [00:06, paused]:** later\n[00:07] next."), body)
    assert(stamp(3725) == "1:02:05")

    // Speakers: raw ids renumbered by first appearance; a label only on each change.
    let spoken = assignSpeakers(tokens, segments: [(0, 2.5, "S7"), (4.2, 5.5, "S2"), (7.5, 9, "S7")])
    assert(spoken.map { $0.speaker! } == ["Speaker 1", "Speaker 1", "Speaker 1", "Speaker 2", "Speaker 2", "Speaker 1", "Speaker 1"])
    let named = render(id: "x", events: events, tokens: spoken, names: ["Speaker 2": "Me"])
    assert(named.contains("[00:00] **Speaker 1:** Hello world.\n> **note [00:03]:** why?\n[00:04] **Me:** So then"), named)
    assert(named.contains("[00:07] **Speaker 1:** next."), named)
    let solo = assignSpeakers(tokens, segments: [(0, 9, "S1")])
    assert(!render(id: "x", events: events, tokens: solo).contains("**Speaker"), "one speaker: no labels")

    // Live pieces: speakers matched across pieces by voice, cut at the quietest spot, CAF read back.
    var voices: [[Float]] = []
    let p1 = match(["S1": [1, 0], "S2": [0, 1]], voices: &voices)
    let p2 = match(["S1": [0.1, 1], "S2": [1, 0.1]], voices: &voices)
    assert(p1["S1"] == p2["S2"] && p1["S2"] == p2["S1"] && voices.count == 2, "\(p1) \(p2)")
    _ = match(["S1": [-1, 0]], voices: &voices)
    assert(voices.count == 3, "a new voice is a new speaker")
    let r = Live.rate
    var audio = [Float](repeating: 0.5, count: 10 * r)
    audio.replaceSubrange(7 * r..<7 * r + r / 10, with: repeatElement(0, count: r / 10))
    assert(Live.quietest(audio[...]) == 7 * r + r / 20)
    let caf = FileManager.default.temporaryDirectory.appendingPathComponent("selfcheck.caf")
    do {
      let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: r, AVNumberOfChannelsKey: 1,
                                     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
      let f = try! AVAudioFile(forWriting: caf, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
      let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 100)!
      b.frameLength = 100
      for i in 0..<100 { b.int16ChannelData![0][i] = Int16(i * 100) }
      try! f.write(from: b)
    }
    let read = try! Live.samples(caf, from: 10)
    assert(read.count == 90 && read[0] == 1000 / 32768, "\(read.prefix(3))")
    print("selfcheck ok")
  }
}

import AppKit
import AVFoundation
import FluidAudio
import Observation

@MainActor @Observable
final class Session {
  enum State { case idle, recording, paused, transcribing }

  static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sessions")

  var state: State = .idle
  var meter: Double = 0
  var lastID: String?
  var modelReady = false

  private var recorder: AVAudioRecorder?
  private var meterTimer: Timer?
  private var dir: URL!
  private var id = ""
  private var events: [Event] = []
  private var recordedBefore: TimeInterval = 0
  private var runStart: Date?

  /// The session being recorded or transcribed, which History leaves out.
  var activeID: String? { state == .idle ? nil : id }

  /// Recording time: frozen while paused, so it lines up with the audio file.
  var t: TimeInterval { recordedBefore + (runStart.map { Date().timeIntervalSince($0) } ?? 0) }

  private var asr: Task<AsrManager, Error>!

  init() {
    loadModel()
  }

  /// Loads the model picked in Settings (downloading it on first run). A session that's
  /// already stopped keeps the model it started transcribing with.
  func loadModel() {
    let m = Models.shared.selected
    modelReady = false
    let task = Self.load(m, progress: Models.shared.reporter(for: m))
    asr = task
    Task {
      _ = try? await task.value
      Models.shared.finished(m)
      if asr == task { modelReady = true }
    }
  }

  nonisolated static func load(_ m: TranscriptionModel, progress: ProgressHandler? = nil) -> Task<AsrManager, Error> {
    Task {
      let manager = AsrManager()
      try await manager.loadModels(try await AsrModels.downloadAndLoad(version: m.version, progressHandler: progress))
      return manager
    }
  }

  // MARK: Controls

  /// One key for everything: start when idle, otherwise toggle pause.
  func toggle() {
    switch state {
    case .idle: Task { await start() }
    case .recording: pause()
    case .paused: resume()
    case .transcribing: break
    }
  }

  func start() async {
    guard await AVCaptureDevice.requestAccess(for: .audio) else { return alert("Microphone access is off. Enable it in System Settings → Privacy → Microphone.") }
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmm"
    id = f.string(from: Date())
    dir = Self.root.appendingPathComponent(id)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      // PCM in CAF survives a crash (unlike m4a, which is unreadable until finalised).
      let r = try AVAudioRecorder(url: dir.appendingPathComponent("audio.caf"), settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
      ])
      r.isMeteringEnabled = true
      guard r.record() else { return alert("Couldn't start recording.") }
      recorder = r
    } catch { return alert("Couldn't start recording: \(error.localizedDescription)") }
    events = []
    recordedBefore = 0
    runStart = Date()
    state = .recording
    log(.start)
    meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let r = self.recorder, self.state == .recording else { self?.meter = 0; return }
        r.updateMeters()
        self.meter = pow(10, Double(r.averagePower(forChannel: 0)) / 20)
      }
    }
  }

  func pause() {
    guard state == .recording else { return }
    recorder?.pause()
    recordedBefore = t
    runStart = nil
    state = .paused
    log(.pause)
  }

  func resume() {
    guard state == .paused else { return }
    recorder?.record()
    runStart = Date()
    state = .recording
    log(.resume)
  }

  /// `at` is the recording time of the note's first keystroke.
  func addNote(_ text: String, at: TimeInterval, paused: Bool) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, state == .recording || state == .paused else { return }
    log(.note, t: at, text: text, paused: paused)
  }

  func stop() {
    guard state == .recording || state == .paused else { return }
    recordedBefore = t
    runStart = nil
    log(.stop)
    recorder?.stop()
    recorder = nil
    meterTimer?.invalidate()
    state = .transcribing
    let (dir, id, events) = (dir!, id, events)
    Task {
      await Self.finish(dir: dir, id: id, events: events, asr: asr)
      lastID = id
      copyNotesCommand()
      state = .idle
    }
  }

  /// Quitting mid-session: finalise the audio file so nothing is lost. `session.md` isn't written.
  func stopRecorderForQuit() {
    guard state == .recording || state == .paused else { return }
    log(.stop)
    recorder?.stop()
  }

  func copyNotesCommand() {
    guard let lastID else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("/notes \(lastID)", forType: .string)
  }

  // MARK: Private

  private func log(_ kind: Event.Kind, t: TimeInterval? = nil, text: String? = nil, paused: Bool? = nil) {
    let e = Event(kind: kind, t: t ?? self.t, wall: Date(), text: text, paused: paused)
    events.append(e)
    // Append each event to disk as it happens so notes survive a crash.
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    guard var line = try? enc.encode(e) else { return }
    line.append(0x0A)
    let url = dir.appendingPathComponent("events.jsonl")
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile(); h.write(line); try? h.close()
    } else {
      try? line.write(to: url)
    }
  }

  /// `NotesThing --finish <session dir>`: rebuilds session.md from events.jsonl and the audio,
  /// e.g. after quitting mid-session.
  nonisolated static func finish(dir: URL) async {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let text = (try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
    let events = text.split(separator: "\n").compactMap { try? dec.decode(Event.self, from: Data($0.utf8)) }
    let model = UserDefaults.standard.string(forKey: "model").flatMap(TranscriptionModel.init) ?? .parakeetV2
    await finish(dir: dir, id: dir.lastPathComponent, events: events, asr: load(model))
  }

  private nonisolated static func finish(dir: URL, id: String, events: [Event], asr: Task<AsrManager, Error>) async {
    let caf = dir.appendingPathComponent("audio.caf")
    var tokens: [Token] = []
    var failure: String?
    do {
      let manager = try await asr.value
      var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
      let result = try await manager.transcribe(caf, decoderState: &state)
      tokens = (result.tokenTimings ?? []).map { Token(text: $0.token, start: $0.startTime) }
    } catch {
      failure = error.localizedDescription
    }
    // Who spoke when. Best effort: if it fails, the transcript just has no speaker labels.
    if failure == nil, let segments = try? await diarize(caf) {
      tokens = Transcript.assignSpeakers(tokens, segments: segments)
    }
    let names = Speakers.load(dir)
    let md = Transcript.render(id: id, events: events, tokens: tokens, names: names, error: failure)
    let labels = Set(tokens.compactMap(\.speaker))
    if labels.count > 1 { Speakers.save(dir, labels.reduce(into: names) { $0[$1] = $0[$1] ?? $1 }) }
    try? md.write(to: dir.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)

    // Shrink audio to AAC with the built-in afconvert; keep the CAF if that fails or transcription did.
    let m4a = dir.appendingPathComponent("audio.m4a")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    p.arguments = ["-f", "m4af", "-d", "aac", caf.path, m4a.path]
    if (try? p.run()) != nil {
      p.waitUntilExit()
      if p.terminationStatus == 0, failure == nil { try? FileManager.default.removeItem(at: caf) }
    }
  }

  /// Offline diarizer (pyannote + WeSpeaker + VBx clustering); downloads its models on first use.
  private nonisolated static func diarize(_ audio: URL) async throws -> [(start: TimeInterval, end: TimeInterval, id: String)] {
    let diarizer = OfflineDiarizerManager()
    try await diarizer.prepareModels()
    return try await diarizer.process(audio).segments.map {
      (TimeInterval($0.startTimeSeconds), TimeInterval($0.endTimeSeconds), $0.speakerId)
    }
  }

  private func alert(_ message: String) {
    let a = NSAlert()
    a.messageText = message
    a.runModal()
  }
}

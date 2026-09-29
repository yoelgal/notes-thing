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

  /// Recording time: frozen while paused, so it lines up with the audio file.
  var t: TimeInterval { recordedBefore + (runStart.map { Date().timeIntervalSince($0) } ?? 0) }

  private let asr = Task { () throws -> AsrManager in
    let models = try await AsrModels.downloadAndLoad(version: .v2)
    let manager = AsrManager()
    try await manager.loadModels(models)
    return manager
  }

  init() {
    Task { _ = try? await asr.value; modelReady = true }
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
    let asr = Task { () throws -> AsrManager in
      let manager = AsrManager()
      try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .v2))
      return manager
    }
    await finish(dir: dir, id: dir.lastPathComponent, events: events, asr: asr)
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
    let md = Transcript.render(id: id, events: events, tokens: tokens, error: failure)
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

  private func alert(_ message: String) {
    let a = NSAlert()
    a.messageText = message
    a.runModal()
  }
}

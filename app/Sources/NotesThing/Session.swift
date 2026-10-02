import AppKit
import AVFoundation
import FluidAudio
import Observation

@MainActor @Observable
final class Session {
  enum State { case idle, recording, paused, transcribing }

  static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sessions")

  var state: State = .idle {
    didSet {
      // Keeps a long lecture (and its transcription) going when the Mac sits idle.
      if state == .idle {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        Updater.shared.sessionEnded()
      } else if awake == nil, UserDefaults.standard.object(forKey: "preventSleep") as? Bool ?? true {
        awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Recording a session")
      }
    }
  }
  var meter: Double = 0
  var lastID: String?
  var modelReady = false

  private var recorder: Recorder?
  private var awake: NSObjectProtocol?
  private var meterTimer: Timer?
  private var live: Live?
  private var liveTimer: Timer?
  private var liveQueue: Task<Live.Result?, Never>?
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
      recorder = try Recorder(url: dir.appendingPathComponent("audio.caf")) { [weak self] error in
        self?.alert("Recording stopped: \(error) The audio up to now is saved.")
      }
    } catch { return alert("Couldn't start recording: \(error.localizedDescription)") }
    live = Live(caf: dir.appendingPathComponent("audio.caf"), asr: asr)
    liveQueue = nil
    liveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.queueLive() }
    }
    events = []
    recordedBefore = 0
    runStart = Date()
    state = .recording
    log(.start)
    meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let r = self.recorder, self.state == .recording else { self?.meter = 0; return }
        self.meter = r.level
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
    recorder?.resume()
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
    let recorder = recorder
    self.recorder = nil
    meterTimer?.invalidate()
    liveTimer?.invalidate()
    state = .transcribing
    let (dir, id, events) = (dir!, id, events)
    Task {
      await recorder?.stop()
      let done = await queueLive(final: true).value
      live = nil
      let ok = await Self.finish(dir: dir, id: id, events: events, asr: asr, live: done)
      lastID = id
      copyNotesCommand()
      state = .idle
      await Self.compress(dir, keepCaf: !ok)
    }
  }

  /// Quitting mid-session: finalise the audio file so nothing is lost. `session.md` isn't written.
  func stopRecorderForQuit() {
    guard state == .recording || state == .paused else { return }
    log(.stop)
    recorder?.stopNow()
  }

  func copyNotesCommand() {
    guard let lastID else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("/notes \(lastID)", forType: .string)
  }

  // MARK: Private

  /// Queues a step of the live transcription after any still running.
  private func queueLive(final: Bool = false) -> Task<Live.Result?, Never> {
    let (previous, live) = (liveQueue, live)
    let task = Task {
      _ = await previous?.value
      return await live?.step(final: final)
    }
    liveQueue = task
    return task
  }

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
    let ok = await finish(dir: dir, id: dir.lastPathComponent, events: events, asr: load(model))
    await compress(dir, keepCaf: !ok)
  }

  /// Writes session.md, from `live`'s transcript if it has one, else by transcribing the whole file.
  /// Returns false if transcription failed.
  private nonisolated static func finish(dir: URL, id: String, events: [Event], asr: Task<AsrManager, Error>, live: Live.Result? = nil) async -> Bool {
    let caf = dir.appendingPathComponent("audio.caf")
    var tokens: [Token] = []
    var segments: [Live.Segment] = []
    var failure: String?
    if let live {
      (tokens, segments) = live
    } else {
      do {
        let manager = try await asr.value
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(caf, decoderState: &state)
        tokens = (result.tokenTimings ?? []).map { Token(text: $0.token, start: $0.startTime) }
      } catch {
        failure = error.localizedDescription
      }
      // Who spoke when. Best effort: if it fails, the transcript just has no speaker labels.
      if failure == nil, let s = try? await diarize(caf) { segments = s }
    }
    tokens = Transcript.assignSpeakers(tokens, segments: segments)
    let names = Speakers.load(dir)
    let md = Transcript.render(id: id, events: events, tokens: tokens, names: names, error: failure)
    let labels = Set(tokens.compactMap(\.speaker))
    if labels.count > 1 { Speakers.save(dir, labels.reduce(into: names) { $0[$1] = $0[$1] ?? $1 }) }
    try? md.write(to: dir.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
    return failure == nil
  }

  /// Shrinks the audio to AAC with the built-in afconvert, keeping the CAF if that fails (or `keepCaf`).
  /// Converts under a temporary name so History never plays a half-written m4a.
  private nonisolated static func compress(_ dir: URL, keepCaf: Bool) async {
    let caf = dir.appendingPathComponent("audio.caf")
    let tmp = dir.appendingPathComponent("audio-partial.m4a")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    p.arguments = ["-f", "m4af", "-d", "aac", caf.path, tmp.path]
    guard (try? p.run()) != nil else { return }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return }
    let m4a = dir.appendingPathComponent("audio.m4a")
    try? FileManager.default.removeItem(at: m4a)
    guard (try? FileManager.default.moveItem(at: tmp, to: m4a)) != nil else { return }
    if !keepCaf { try? FileManager.default.removeItem(at: caf) }
  }

  /// Offline diarizer (pyannote + WeSpeaker + VBx clustering); downloads its models on first use.
  private nonisolated static func diarize(_ audio: URL) async throws -> [Live.Segment] {
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

/// Records one mic to a file. Unlike AVAudioRecorder, AVCaptureSession can use any input
/// without changing the system default.
@MainActor
final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
  private let capture = AVCaptureSession()
  private let output = AVCaptureAudioFileOutput()
  private let failed: (String) -> Void
  private var stopping: CheckedContinuation<Void, Never>?
  private var done = false

  /// The mic picked in Settings, or the system default if none was picked or it's unplugged.
  static var device: AVCaptureDevice? {
    UserDefaults.standard.string(forKey: "microphone").flatMap(AVCaptureDevice.init(uniqueID:)) ?? .default(for: .audio)
  }

  static func devices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
  }

  /// `failed` is called if recording ends on its own, e.g. the mic was unplugged.
  init(url: URL, failed: @escaping (String) -> Void) throws {
    self.failed = failed
    super.init()
    guard let device = Self.device else {
      throw NSError(domain: "NotesThing", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard capture.canAddInput(input), capture.canAddOutput(output) else {
      throw NSError(domain: "NotesThing", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(device.localizedName) can't be recorded."])
    }
    capture.addInput(input)
    capture.addOutput(output)
    // PCM in CAF survives a crash (unlike m4a, which is unreadable until finalised).
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    capture.startRunning() // ponytail: blocks the main thread for a moment at start; move off-main if it's noticeable
    output.startRecording(to: url, outputFileType: .caf, recordingDelegate: self)
  }

  /// 0…1 loudness, like AVAudioRecorder's metering.
  var level: Double {
    guard let db = output.connections.first?.audioChannels.first?.averagePowerLevel else { return 0 }
    return pow(10, Double(db) / 20)
  }

  func pause() { output.pauseRecording() }
  func resume() { output.resumeRecording() }

  /// Returns once the file is finalised.
  func stop() async {
    if !done { await withCheckedContinuation { stopping = $0; output.stopRecording() } }
    capture.stopRunning()
  }

  /// Quitting: finalise the file before the process exits, pumping the run loop for the callback.
  func stopNow() {
    output.stopRecording()
    let deadline = Date() + 3
    while !done, Date() < deadline { RunLoop.current.run(until: Date() + 0.05) }
    capture.stopRunning()
  }

  nonisolated func fileOutput(_: AVCaptureFileOutput, didFinishRecordingTo _: URL, from _: [AVCaptureConnection], error: Error?) {
    let ok = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
    let message = ok ? nil : error?.localizedDescription
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.done = true
        if let stopping = self.stopping {
          stopping.resume()
          self.stopping = nil
        } else if let message {
          self.failed(message)
        }
      }
    }
  }
}

import AppKit
import AVFoundation
import FluidAudio
import Observation

@MainActor @Observable
final class Session {
  enum State { case idle, recording, paused, transcribing }

  /// Where sessions live: ~/Sessions unless moved with Settings → Change…. The path is remembered once
  /// the folder exists, so one moved in Finder is reported instead of silently recreated empty.
  /// The /notes skill reads the same default (`defaults read com.yoelgal.notesthing sessionsFolder`).
  static var root: URL {
    UserDefaults.standard.string(forKey: "sessionsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sessions", isDirectory: true)
  }

  static var rootMissing: Bool {
    UserDefaults.standard.string(forKey: "sessionsFolder") != nil && !FileManager.default.fileExists(atPath: root.path)
  }

  /// Pins the current folder once it exists (covers installs from before the setting).
  static func rememberRoot() {
    if !rootMissing, FileManager.default.fileExists(atPath: root.path) {
      UserDefaults.standard.set(root.path, forKey: "sessionsFolder")
    }
  }

  /// Opens the folder in Finder, or Settings if it has gone missing.
  static func openRoot() {
    if rootMissing { return AppDelegate.shared?.window.show(.settings) ?? () }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    rememberRoot()
    NSWorkspace.shared.open(root)
  }

  /// Settings → Change…: moves every session into `new`, then points the app there.
  /// Checks for clashes first so a failure can't leave sessions split across two folders.
  static func moveRoot(to new: URL) throws {
    let fm = FileManager.default, old = root.standardizedFileURL, new = new.standardizedFileURL
    guard new != old else { return }
    guard !new.path.hasPrefix(old.path + "/") else {
      throw NSError(domain: "NotesThing", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pick a folder outside the current sessions folder."])
    }
    let items = ((try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent != ".DS_Store" }
    if let clash = items.first(where: { fm.fileExists(atPath: new.appendingPathComponent($0.lastPathComponent).path) }) {
      throw NSError(domain: "NotesThing", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(new.lastPathComponent) already has a \(clash.lastPathComponent). Pick an empty folder."])
    }
    for item in items { try fm.moveItem(at: item, to: new.appendingPathComponent(item.lastPathComponent)) }
    if (try? fm.contentsOfDirectory(atPath: old.path).filter { $0 != ".DS_Store" })?.isEmpty == true { try? fm.removeItem(at: old) }
    UserDefaults.standard.set(new.path, forKey: "sessionsFolder")
  }

  var state: State = .idle {
    didSet {
      // Keeps a long recording (and its transcription) going when the Mac sits idle.
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
    if Self.rootMissing {
      AppDelegate.shared?.window.show(.settings)
      return alert("Your sessions folder isn't at \((Self.root.path as NSString).abbreviatingWithTildeInPath) any more. If you moved it, choose where it is now in Settings → Sessions Folder → Change….")
    }
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmm"
    id = f.string(from: Date())
    dir = Self.root.appendingPathComponent(id)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      Self.rememberRoot()
      recorder = try Recorder(url: dir.appendingPathComponent("audio.caf")) { [weak self] error in
        self?.alert("Recording stopped: \(error) The audio up to now is saved.")
      }
    } catch { return alert("Couldn't start recording: \(error.localizedDescription)") }
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
    state = .transcribing
    let (dir, id, events) = (dir!, id, events)
    Task {
      await recorder?.stop()
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
    recorder?.stopNow()
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

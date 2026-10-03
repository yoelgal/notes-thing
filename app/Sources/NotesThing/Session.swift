import AppKit
import AVFoundation
import CoreAudio
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
      recorder?.stop()
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
    recorder?.stop()
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


/// Records the mic, plus everything the Mac plays (the other side of a call, a video) when "systemAudio"
/// is on, mixed into one 16 kHz mono CAF. Both come through one private aggregate device, so they share
/// a clock and stay in sync however long the session runs.
final class Recorder: @unchecked Sendable {
  /// Process taps need macOS 14.2.
  static var systemAudioSupported: Bool { if #available(macOS 14.2, *) { true } else { false } }
  static var systemAudio: Bool { systemAudioSupported && UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true }

  /// The mic picked in Settings, or the system default if none was picked or it's unplugged.
  static var device: AVCaptureDevice? {
    UserDefaults.standard.string(forKey: "microphone").flatMap(AVCaptureDevice.init(uniqueID:)) ?? .default(for: .audio)
  }

  static func devices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
  }

  /// 0…1 loudness of the mix.
  private(set) var level: Double = 0 // ponytail: written on the IO queue, read on main; a stale meter is harmless
  private let queue = DispatchQueue(label: "com.yoelgal.notesthing.recorder", qos: .userInitiated)
  private var tap = AudioObjectID(kAudioObjectUnknown)
  private var aggregate = AudioObjectID(kAudioObjectUnknown)
  private var proc: AudioDeviceIOProcID?
  private var micID = AudioObjectID(kAudioObjectUnknown)
  private var unplugged: AudioObjectPropertyListenerBlock?
  // Only touched on `queue`.
  private var file: AVAudioFile?
  private var converter: AVAudioConverter!
  private var paused = false

  /// `failed` is called if recording ends on its own: the mic was unplugged.
  init(url: URL, failed: @escaping @MainActor (String) -> Void) throws {
    guard let mic = Self.device?.uniqueID else { throw Self.error("No microphone found.") }
    var desc: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Notes Thing",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: mic,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: mic]],
    ]
    if Self.systemAudio, #available(macOS 14.2, *) {
      // macOS asks for "System Audio Recording" the first time; if refused, the tap is silent and only the mic records.
      let t = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
      t.isPrivate = true
      try Self.check(AudioHardwareCreateProcessTap(t, &tap), "Couldn't record system audio")
      desc[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: t.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
      desc[kAudioAggregateDeviceTapAutoStartKey] = true
    }
    do {
      try Self.check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregate), "Couldn't open the microphone")
      var rate = Float64(0)
      try Self.check(Self.get(aggregate, kAudioDevicePropertyNominalSampleRate, &rate), "Couldn't read the sample rate")
      // PCM in CAF survives a crash (unlike m4a, which is unreadable until finalised).
      let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Live.rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
      self.file = file
      converter = AVAudioConverter(from: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, to: file.processingFormat)
      try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [unowned self] _, input, _, _, _ in
        write(input)
      }, "Couldn't open the microphone")
      try Self.check(AudioDeviceStart(aggregate, proc), "Couldn't start the microphone")
    } catch {
      stop()
      throw error
    }
    // Unplugging the mic stops the recording, as with any other input.
    var uid = mic as CFString
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), &uid, &size, &micID)
    let unplugged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      var alive = UInt32(1)
      guard Self.get(micID, kAudioDevicePropertyDeviceIsAlive, &alive) != noErr || alive == 0 else { return }
      DispatchQueue.main.async {
        guard self.aggregate != kAudioObjectUnknown else { return }
        self.stop()
        failed("The microphone was disconnected.")
      }
    }
    self.unplugged = unplugged
    address = Self.address(kAudioDevicePropertyDeviceIsAlive)
    AudioObjectAddPropertyListenerBlock(micID, &address, queue, unplugged)
  }

  func pause() { queue.async { self.paused = true } }
  func resume() { queue.async { self.paused = false } }

  /// Finalises the file. Safe to call twice.
  func stop() {
    if let unplugged {
      var address = Self.address(kAudioDevicePropertyDeviceIsAlive)
      AudioObjectRemovePropertyListenerBlock(micID, &address, queue, unplugged)
      self.unplugged = nil
    }
    if let proc {
      AudioDeviceStop(aggregate, proc)
      AudioDeviceDestroyIOProcID(aggregate, proc)
      self.proc = nil
    }
    queue.sync { file = nil } // after any write in flight; closing the file finalises it
    if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
    if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    aggregate = AudioObjectID(kAudioObjectUnknown)
    tap = AudioObjectID(kAudioObjectUnknown)
    level = 0
  }

  /// Mixes every input stream (the mic's, then the tap's) down to mono and appends it at 16 kHz.
  private func write(_ input: UnsafePointer<AudioBufferList>) {
    guard let file, !paused else { level = 0; return }
    let streams = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = streams.first, first.mNumberChannels > 0 else { return }
    let frames = Int(first.mDataByteSize) / 4 / Int(first.mNumberChannels)
    guard frames > 0, let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
    mono.frameLength = AVAudioFrameCount(frames)
    let out = mono.floatChannelData![0]
    out.initialize(repeating: 0, count: frames)
    for s in streams {
      guard let data = s.mData?.assumingMemoryBound(to: Float.self), s.mNumberChannels > 0 else { continue }
      let ch = Int(s.mNumberChannels)
      for i in 0..<min(frames, Int(s.mDataByteSize) / 4 / ch) {
        var sum: Float = 0
        for c in 0..<ch { sum += data[i * ch + c] }
        out[i] += sum / Float(ch)
      }
    }
    var power: Float = 0
    for i in 0..<frames {
      out[i] = max(-1, min(1, out[i]))
      power += out[i] * out[i]
    }
    level = Double((power / Float(frames)).squareRoot())
    let capacity = AVAudioFrameCount(Double(frames) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate) + 32
    guard let resampled = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
    var given = false
    converter.convert(to: resampled, error: nil) { _, status in
      if given { status.pointee = .noDataNow; return nil }
      given = true
      status.pointee = .haveData
      return mono
    }
    try? file.write(from: resampled)
  }

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }

  private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var address = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
  }

  private static func check(_ status: OSStatus, _ message: String) throws {
    guard status != noErr else { return }
    throw error("\(message) (error \(status)).")
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: "NotesThing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

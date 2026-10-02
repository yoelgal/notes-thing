import Foundation
import FluidAudio

/// Transcribes and diarizes the recording a few minutes at a time while it's still going,
/// so stopping only leaves the last piece to do. Speakers are matched across pieces by voice.
/// Calls must not overlap: Session chains them.
actor Live {
  typealias Segment = (start: TimeInterval, end: TimeInterval, id: String)
  typealias Result = (tokens: [Token], segments: [Segment])
  static let rate = 16_000
  /// ponytail: 3 min pieces, so a stop waits on ≤ 3 min of audio (~2 s). Shorter pieces diarize worse.
  static let piece = 180 * rate

  private let caf: URL
  private let asr: Task<AsrManager, Error>
  private let diarizer = OfflineDiarizerManager()
  private var done = 0 // samples handled so far
  private var tokens: [Token] = []
  private var segments: [Segment] = []
  private var voices: [[Float]] = [] // running sum of each speaker's embeddings
  private var failed = false

  init(caf: URL, asr: Task<AsrManager, Error>) {
    self.caf = caf
    self.asr = asr
  }

  /// Handles every whole piece recorded so far; `final` also handles the rest (the file must be finalised).
  /// Returns the transcript so far, or nil if anything failed, in which case the caller redoes the whole file.
  @discardableResult
  func step(final: Bool = false) async -> Result? {
    guard !failed else { return nil }
    do {
      var samples = try Self.samples(caf, from: done)[...]
      while samples.count >= Self.piece || (final && !samples.isEmpty) {
        let n = samples.count >= Self.piece ? Self.quietest(samples.prefix(Self.piece)) : samples.count
        try await handle(Array(samples.prefix(n)))
        samples = samples.dropFirst(n)
      }
    } catch {
      failed = true
      return nil
    }
    return (tokens, segments)
  }

  private func handle(_ audio: [Float]) async throws {
    let offset = TimeInterval(done) / TimeInterval(Self.rate)
    let manager = try await asr.value
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let min = ASRConstants.minimumRequiredSamples(forSampleRate: Self.rate)
    let result = try await manager.transcribe(audio + [Float](repeating: 0, count: max(0, min - audio.count)), decoderState: &state)
    tokens += (result.tokenTimings ?? []).map { Token(text: $0.token, start: $0.startTime + offset) }
    // Best effort, as before: a piece that fails to diarize borrows its neighbours' speakers.
    if let d = try? await diarizer.process(audio: audio) {
      let ids = Transcript.match(d.speakerDatabase ?? [:], voices: &voices)
      segments += d.segments.compactMap { s in
        ids[s.speakerId].map { (offset + TimeInterval(s.startTimeSeconds), offset + TimeInterval(s.endTimeSeconds), $0) }
      }
    }
    done += audio.count
  }

  /// Where to cut a piece: the middle of its quietest 0.1 s in the last 5 s, so no word is split.
  static func quietest(_ s: ArraySlice<Float>) -> Int {
    let w = rate / 10
    let from = s.startIndex + max(0, s.count - 5 * rate)
    let best = stride(from: from, to: s.endIndex - w + 1, by: w).min { a, b in
      s[a..<a + w].reduce(0) { $0 + $1 * $1 } < s[b..<b + w].reduce(0) { $0 + $1 * $1 }
    }
    return best.map { $0 - s.startIndex + w / 2 } ?? s.count
  }

  /// Samples from `from` on, out of the 16 kHz mono Int16 CAF the Recorder writes. Works mid-recording:
  /// the data chunk is last, and its size is -1 until the file is finalised.
  static func samples(_ url: URL, from: Int) throws -> [Float] {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    let head = try h.read(upToCount: 1 << 16) ?? Data()
    func int(_ at: Int, _ n: Int) -> Int64 { head[at..<at + n].reduce(0) { $0 << 8 | Int64($1) } }
    func tag(_ at: Int) -> String { String(decoding: head[at..<at + 4], as: UTF8.self) }
    var pos = 8
    var pcm = false
    while pos + 12 <= head.count {
      let size = int(pos + 4, 8)
      if tag(pos) == "desc", pos + 44 <= head.count {
        // rate, format, CAF flags (little-endian, not float), bytes/packet, frames/packet, channels, bits
        pcm = Double(bitPattern: UInt64(int(pos + 12, 8))) == Double(rate) && tag(pos + 20) == "lpcm"
          && int(pos + 24, 4) & 3 == 2 && int(pos + 28, 4) == 2 && int(pos + 32, 4) == 1 && int(pos + 36, 4) == 1 && int(pos + 40, 4) == 16
      }
      if tag(pos) == "data" {
        guard pcm else { break }
        let start = UInt64(pos + 16) // after the 4-byte edit count
        try h.seek(toOffset: start + UInt64(from * 2))
        var data = try h.readToEnd() ?? Data()
        if size >= 4 { data = data.prefix(max(0, Int(size) - 4 - from * 2)) }
        return data.withUnsafeBytes { raw in
          (0..<data.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
      }
      guard size >= 0 else { break }
      pos += 12 + Int(size)
    }
    throw NSError(domain: "NotesThing", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected audio file layout."])
  }
}

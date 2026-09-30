import AppKit
import AVFoundation
import SwiftUI

/// One folder in ~/Sessions, read back from events.jsonl and session.md.
struct SessionRecord: Identifiable {
  let id: String
  let dir: URL
  let date: Date
  let duration: TimeInterval
  let notes: [String]
  /// The first few transcript sentences; nil if session.md hasn't been written yet.
  let preview: String?
  let audio: URL?
  /// speakers.json: "Speaker N" → the name shown in session.md. Empty for one-speaker sessions.
  let speakers: [String: String]

  var markdown: URL { dir.appendingPathComponent("session.md") }

  init?(dir: URL) {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    guard let text = try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return nil }
    let events = text.split(separator: "\n").compactMap { try? dec.decode(Event.self, from: Data($0.utf8)) }
    guard let first = events.first else { return nil }
    id = dir.lastPathComponent
    self.dir = dir
    date = first.wall
    duration = events.last?.t ?? 0
    notes = events.filter { $0.kind == .note }.compactMap(\.text)
    let md = try? String(contentsOf: dir.appendingPathComponent("session.md"), encoding: .utf8)
    preview = md.map { md in
      let sentences = md.split(separator: "\n")
        .filter { $0.first == "[" }
        .map { $0.drop { $0 != "]" }.dropFirst().trimmingCharacters(in: .whitespaces) }
        .map { $0.replacingOccurrences(of: #"^\*\*[^*]+:\*\* "#, with: "", options: .regularExpression) }
      return sentences.isEmpty ? "No speech was transcribed." : sentences.prefix(3).joined(separator: " ")
    }
    audio = ["audio.m4a", "audio.caf"].map { dir.appendingPathComponent($0) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
    speakers = Speakers.load(dir)
  }
}

/// `speakers.json` in a session folder: which name each diarized voice gets in session.md.
enum Speakers {
  static func url(_ dir: URL) -> URL { dir.appendingPathComponent("speakers.json") }

  static func load(_ dir: URL) -> [String: String] {
    (try? Data(contentsOf: url(dir))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
  }

  static func save(_ dir: URL, _ names: [String: String]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(names).write(to: url(dir), options: .atomic)
  }

  /// Renames a voice by rewriting its `**name:**` labels in session.md, so hand edits survive.
  /// ponytail: voices given the same name are merged, and rename together from then on.
  static func rename(_ dir: URL, _ label: String, to name: String) {
    var names = load(dir)
    let old = names[label] ?? label
    let new = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*", with: "")
    let resolved = new.isEmpty ? label : new
    guard resolved != old else { return }
    let md = dir.appendingPathComponent("session.md")
    if let text = try? String(contentsOf: md, encoding: .utf8) {
      try? text.replacingOccurrences(of: "] **\(old):** ", with: "] **\(resolved):** ")
        .write(to: md, atomically: true, encoding: .utf8)
    }
    for (k, v) in names where v == old { names[k] = resolved }
    save(dir, names)
  }
}

@MainActor @Observable
final class History {
  static let shared = History()

  private(set) var records: [SessionRecord] = []
  private(set) var playing: String?
  private(set) var transcribing: Set<String> = []
  private var player: AVAudioPlayer?

  func reload(excluding active: String?) {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: Session.root, includingPropertiesForKeys: nil)) ?? []
    records = dirs.filter { $0.lastPathComponent != active }
      .compactMap(SessionRecord.init)
      .sorted { $0.date > $1.date }
  }

  func togglePlay(_ r: SessionRecord) {
    if playing == r.id { player?.stop(); playing = nil; return }
    guard let url = r.audio, let p = try? AVAudioPlayer(contentsOf: url) else { return }
    player?.stop()
    player = p
    p.play()
    playing = r.id
  }

  /// Moves the session folder to the Trash, so it can be restored.
  func trash(_ r: SessionRecord) {
    if playing == r.id { player?.stop(); playing = nil }
    try? FileManager.default.trashItem(at: r.dir, resultingItemURL: nil)
    records.removeAll { $0.id == r.id }
  }

  func rename(_ r: SessionRecord, _ label: String, to name: String) {
    Speakers.rename(r.dir, label, to: name)
    if let i = records.firstIndex(where: { $0.id == r.id }), let fresh = SessionRecord(dir: r.dir) { records[i] = fresh }
  }

  /// For sessions that were quit mid-lecture: same as `NotesThing --finish`.
  func transcribe(_ r: SessionRecord) {
    transcribing.insert(r.id)
    Task {
      await Session.finish(dir: r.dir)
      transcribing.remove(r.id)
      if let i = records.firstIndex(where: { $0.id == r.id }), let fresh = SessionRecord(dir: r.dir) { records[i] = fresh }
    }
  }
}

// MARK: Views (Hex's HistoryView / TranscriptView)

struct HistoryView: View {
  var session: Session
  private var history: History { .shared }

  var body: some View {
    Group {
      if history.records.isEmpty {
        ContentUnavailableView {
          Label("No Sessions", systemImage: "text.bubble")
        } description: {
          Text("Your lectures will appear here. Press \(Prefs.shared[.toggle].display) to start one.")
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(history.records) { SessionCard(record: $0) }
          }
          .padding()
        }
      }
    }
    .onAppear { history.reload(excluding: session.activeID) }
    .onChange(of: session.state) { history.reload(excluding: session.activeID) }
  }
}

private struct SessionCard: View {
  let record: SessionRecord
  private var history: History { .shared }

  @State private var showCopied = false
  @State private var showSpeakers = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(record.preview ?? "Not transcribed yet. The audio and notes are saved.")
          .font(.body)
          .foregroundStyle(record.preview == nil ? .secondary : .primary)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
        if !record.notes.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(record.notes.prefix(3).enumerated()), id: \.offset) { _, n in
              Label(n, systemImage: "square.and.pencil")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            }
            if record.notes.count > 3 {
              Text("+ \(record.notes.count - 3) more").font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.leading, 8)
          .overlay(alignment: .leading) { Rectangle().fill(Color.red).frame(width: 2) }
        }
      }
      .padding(.trailing, 40)
      .padding(12)

      Divider()

      HStack {
        HStack(spacing: 6) {
          Image(systemName: "clock")
          Text(record.date.formatted(.relative(presentation: .named)))
          Text("•")
          Text(record.date.formatted(date: .abbreviated, time: .shortened))
          Text("•")
          Text(Transcript.stamp(record.duration))
          if !record.notes.isEmpty {
            Text("•")
            Text(record.notes.count == 1 ? "1 note" : "\(record.notes.count) notes")
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)

        Spacer()

        HStack(spacing: 10) {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("/notes \(record.id)", forType: .string)
            copied()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
              if showCopied { Text("Copied").font(.caption) }
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(showCopied ? .green : .secondary)
          .help("Copy /notes \(record.id)")

          if !record.speakers.isEmpty {
            Button { showSpeakers = true } label: { Image(systemName: "person.2.fill") }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("Name the speakers")
              .popover(isPresented: $showSpeakers, arrowEdge: .bottom) { SpeakerNames(record: record) }
          }

          if record.audio != nil {
            Button { history.togglePlay(record) } label: {
              Image(systemName: history.playing == record.id ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(history.playing == record.id ? .blue : .secondary)
            .help(history.playing == record.id ? "Stop playback" : "Play audio")
          }

          if history.transcribing.contains(record.id) {
            ProgressView().controlSize(.small)
          } else if record.preview == nil {
            Button("Transcribe") { history.transcribe(record) }
              .controlSize(.small)
              .help("Write session.md from the saved audio and notes")
          } else {
            Button { NSWorkspace.shared.open(record.markdown) } label: { Image(systemName: "doc.text.fill") }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("Open session.md")
          }

          Button { NSWorkspace.shared.activateFileViewerSelecting([record.dir]) } label: { Image(systemName: "folder.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show in Finder")

          Button { history.trash(record) } label: { Image(systemName: "trash.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Move to Trash")
        }
        .font(.subheadline)
      }
      .frame(height: 20)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(.windowBackgroundColor).opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
    )
  }

  private func copied() {
    withAnimation { showCopied = true }
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      withAnimation { showCopied = false }
    }
  }
}

/// One field per detected voice; Enter (or closing the popover) renames it in session.md.
private struct SpeakerNames: View {
  let record: SessionRecord
  @State private var drafts: [String: String] = [:]

  private var labels: [String] {
    record.speakers.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Speakers").font(.headline)
      ForEach(labels, id: \.self) { label in
        LabeledContent(label) {
          TextField(label, text: Binding(get: { drafts[label] ?? "" }, set: { drafts[label] = $0 }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .onSubmit { commit(label) }
        }
      }
      Text("Give two voices the same name to merge them.").font(.caption).foregroundStyle(.secondary)
    }
    .padding(14)
    .onAppear { drafts = record.speakers.filter { $0.key != $0.value } }
    .onDisappear { labels.forEach(commit) }
  }

  private func commit(_ label: String) {
    let name = drafts[label] ?? ""
    let current = record.speakers[label] ?? label
    guard name != (current == label ? "" : current) else { return }
    History.shared.rename(record, label, to: name)
  }
}

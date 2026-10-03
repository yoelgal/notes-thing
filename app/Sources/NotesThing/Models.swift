import AppKit
import FluidAudio
import SwiftUI

// MARK: Catalog (Hex's models.json, Parakeet entries)

/// ponytail: Parakeet only, since FluidAudio is already here. Hex's Whisper models need WhisperKit;
/// add it if Parakeet ever falls short on a language.
enum TranscriptionModel: String, CaseIterable, Identifiable {
  case parakeetV2 = "parakeet-tdt-0.6b-v2"
  /// Replaced v3 (more accurate, same speed); keeps v3's key so a saved v3 selection carries over.
  case parakeetUltra = "parakeet-tdt-0.6b-v3"

  var id: String { rawValue }
  var version: AsrModelVersion { self == .parakeetV2 ? .v2 : .ultra }
  var displayName: String { self == .parakeetV2 ? "Parakeet TDT v2" : "Parakeet Ultra" }
  var size: String { self == .parakeetV2 ? "English" : "Multilingual" }
  var storageSize: String { "650 MB" }
  var accuracyStars: Int { 5 }
  var speedStars: Int { 5 }
  var badge: String? { self == .parakeetV2 ? "Best for English" : "25 languages" }
  var folder: URL { AsrModels.defaultCacheDirectory(for: version) }
}

/// Which model is selected, which are on disk, and the one download that can run at a time.
@MainActor @Observable
final class Models {
  static let shared = Models()

  private(set) var selected: TranscriptionModel
  private(set) var downloaded: Set<TranscriptionModel> = []
  private(set) var downloading: TranscriptionModel?
  private(set) var progress: Double = 0
  var error: String?
  /// Called after the selection changes, so the session loads the new model.
  var onSelect: (() -> Void)?

  private var task: Task<Void, Never>?

  private init() {
    selected = UserDefaults.standard.string(forKey: "model").flatMap(TranscriptionModel.init) ?? .parakeetV2
    // v3 is no longer offered; free its download.
    try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: .v3))
    refresh()
  }

  func refresh() {
    downloaded = Set(TranscriptionModel.allCases.filter {
      AsrModels.modelsExist(at: $0.folder, version: $0.version)
    })
  }

  func select(_ m: TranscriptionModel) {
    guard m != selected, downloaded.contains(m) else { return }
    selected = m
    UserDefaults.standard.set(m.rawValue, forKey: "model")
    onSelect?()
  }

  /// Progress callback for FluidAudio; also used when the session downloads its model on first run.
  nonisolated func reporter(for m: TranscriptionModel) -> ProgressHandler {
    { p in
      // Loading a model that's already on disk reports progress too (compiling); that isn't a download.
      if case .compiling = p.phase { return }
      Task { @MainActor in
        let models = Models.shared
        guard !models.downloaded.contains(m) else { return }
        models.downloading = m
        models.progress = p.fractionCompleted
      }
    }
  }

  func finished(_ m: TranscriptionModel) {
    if downloading == m { downloading = nil }
    refresh()
  }

  /// Downloads, then switches to it (like Hex).
  func download(_ m: TranscriptionModel) {
    guard downloading == nil else { return }
    error = nil
    downloading = m
    progress = 0
    task = Task {
      do {
        _ = try await AsrModels.download(version: m.version, progressHandler: reporter(for: m))
        finished(m)
        select(m)
      } catch {
        finished(m)
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    downloading = nil
  }

  func remove(_ m: TranscriptionModel) {
    try? FileManager.default.removeItem(at: m.folder)
    refresh()
  }

  func showInFinder(_ m: TranscriptionModel) {
    NSWorkspace.shared.activateFileViewerSelecting([m.folder])
  }
}

// MARK: Views (adapted from Hex's ModelDownloadView)

struct ModelSection: View {
  var session: Session
  @State private var libraryOpen = false
  private var models: Models { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Image(systemName: needsDownload ? "exclamationmark.triangle.fill" : "waveform")
          .font(.title3)
          .foregroundStyle(needsDownload ? Color.orange : Color.accentColor)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 5) {
          Text(models.selected.displayName).font(.body.weight(.medium))
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(needsDownload ? Color.orange : Color.secondary)
          if let d = models.downloading {
            if d != models.selected { Text("Downloading \(d.displayName)…").font(.caption).foregroundStyle(.secondary) }
            ProgressView(value: models.progress).progressViewStyle(.linear)
          }
        }
        Spacer()
        if models.downloading != nil {
          VStack(alignment: .trailing, spacing: 4) {
            Text("\(Int(models.progress * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Cancel", role: .destructive) { models.cancel() }.controlSize(.small)
          }
        } else {
          HStack(spacing: 8) {
            if needsDownload {
              Button("Download") { models.download(models.selected) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button("Browse Models…") { libraryOpen = true }.controlSize(.small)
          }
        }
      }
      if let err = models.error {
        Text("Model error: \(err)").font(.caption).foregroundStyle(.red)
      }
    }
    .padding(10)
    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .sheet(isPresented: $libraryOpen) { ModelLibrarySheet() }
  }

  private var needsDownload: Bool {
    !models.downloaded.contains(models.selected) && models.downloading == nil
  }

  private var subtitle: String {
    if needsDownload { return "Not downloaded. Transcription won't work until you download it." }
    if !session.modelReady, models.downloading == nil { return "Loading…" }
    return "\(models.selected.size) · \(models.selected.storageSize)"
  }
}

private struct ModelLibrarySheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var pendingDelete: TranscriptionModel?
  private var models: Models { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Model Library").font(.title2.weight(.semibold))
          Text("Select an installed model to use it, or download another model for local transcription.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }

      VStack(spacing: 0) {
        ForEach(TranscriptionModel.allCases) { m in
          ModelLibraryRow(model: m, onDelete: { pendingDelete = m })
          if m != TranscriptionModel.allCases.last { Divider().padding(.leading, 54) }
        }
      }
      .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

      Label("Models run locally on your Mac. Downloads are stored on this device.", systemImage: "lock.shield")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(18)
    .frame(width: 680)
    .onAppear { models.refresh() }
    .confirmationDialog(
      "Remove \(pendingDelete?.displayName ?? "model")?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      if let pendingDelete {
        Button("Remove Download", role: .destructive) { models.remove(pendingDelete); self.pendingDelete = nil }
      }
      Button("Cancel", role: .cancel) { pendingDelete = nil }
    } message: {
      if let pendingDelete {
        Text("This frees \(pendingDelete.storageSize) on this Mac. You can download it again anytime.")
      }
    }
  }
}

private struct ModelLibraryRow: View {
  let model: TranscriptionModel
  let onDelete: () -> Void
  private var models: Models { .shared }

  private var isSelected: Bool { models.selected == model && isDownloaded }
  private var isDownloaded: Bool { models.downloaded.contains(model) }
  private var isDownloading: Bool { models.downloading == model }
  private var isDisabled: Bool { models.downloading != nil && !isDownloading }

  var body: some View {
    HStack(spacing: 0) {
      Button { models.select(model) } label: {
        HStack(spacing: 12) {
          Image(systemName: leadingIcon)
            .foregroundStyle(isDownloading || isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 24)
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
              Text(model.displayName).font(.body.weight(.medium))
              if !isDownloaded, let badge = model.badge {
                Text(badge)
                  .font(.caption2.weight(.medium))
                  .foregroundStyle(Color.accentColor)
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(Color.accentColor.opacity(0.12), in: Capsule())
              }
            }
            HStack(spacing: 12) {
              Text(model.size).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              HStack(spacing: 5) { Text("Accuracy").font(.caption2).foregroundStyle(.secondary); Dots(model.accuracyStars) }
              HStack(spacing: 5) { Text("Speed").font(.caption2).foregroundStyle(.secondary); Dots(model.speedStars) }
            }
            .fixedSize()
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 3) {
            Text(model.storageSize).font(.caption).foregroundStyle(.secondary)
            if let status {
              Text(status).font(.caption2).foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)

      trailing.padding(.trailing, 12)
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.55 : 1)
    .background(isSelected ? Color.accentColor.opacity(0.06) : .clear)
    .contextMenu { if isDownloaded { menuItems } }
  }

  @ViewBuilder private var menuItems: some View {
    Button("Show in Finder") { models.showInFinder(model) }
    Divider()
    Button("Remove Download…", role: .destructive, action: onDelete)
  }

  @ViewBuilder private var trailing: some View {
    if isDownloading {
      HStack(spacing: 8) {
        ProgressView(value: models.progress).progressViewStyle(.circular).controlSize(.small)
        Text("\(Int(models.progress * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        Button("Cancel", role: .destructive) { models.cancel() }.controlSize(.small)
      }
    } else if isDownloaded {
      SwiftUI.Menu { menuItems } label: {
        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Show in Finder or remove this download")
    } else {
      Button("Download") { models.download(model) }
        .controlSize(.small)
        .help("Download \(model.storageSize) and switch to this model")
    }
  }

  private var status: String? {
    if isDownloading { return "Downloading…" }
    if isSelected { return "In Use" }
    if isDownloaded { return "Installed" }
    return nil
  }

  private var leadingIcon: String {
    if isDownloading { return "arrow.down.circle.fill" }
    if isSelected { return "checkmark.circle.fill" }
    if isDownloaded { return "circle" }
    return "arrow.down.circle"
  }
}

/// Hex's StarRatingView.
private struct Dots: View {
  let filled: Int
  init(_ filled: Int) { self.filled = filled }

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0 ..< 5, id: \.self) { i in
        Image(systemName: i < filled ? "circle.fill" : "circle")
          .font(.system(size: 7))
          .foregroundColor(i < filled ? .blue : .gray.opacity(0.5))
      }
    }
  }
}

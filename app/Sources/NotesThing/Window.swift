import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// The app window, laid out like Hex's: a sidebar with Settings, History and About.

enum Tab: Hashable { case settings, history, about }

@MainActor @Observable
final class WindowState {
  var tab: Tab = .settings
}

final class AppWindow: NSWindow {
  private let state = WindowState()

  init(session: Session) {
    // Hex's settings window: 700×700, 620×560 minimum, unified toolbar.
    super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
               backing: .buffered, defer: false)
    title = "Notes Thing"
    isReleasedWhenClosed = false
    contentMinSize = NSSize(width: 620, height: 560)
    toolbarStyle = .unified
    contentViewController = NSHostingController(rootView: AppView(session: session, state: state))
    setContentSize(NSSize(width: 700, height: 700))
    center()
  }

  func show(_ tab: Tab = .settings) {
    state.tab = tab
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }
}

struct AppView: View {
  var session: Session
  @Bindable var state: WindowState

  var body: some View {
    NavigationSplitView {
      List(selection: $state.tab) {
        Label("Settings", systemImage: "gearshape").tag(Tab.settings)
        Label("History", systemImage: "clock").tag(Tab.history)
        Label("About", systemImage: "info.circle").tag(Tab.about)
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    } detail: {
      switch state.tab {
      case .settings: SettingsView(session: session).navigationTitle("Settings")
      case .history: HistoryView(session: session).navigationTitle("History")
      case .about: AboutView().navigationTitle("About")
      }
    }
  }
}

// MARK: Settings

struct SettingsView: View {
  var session: Session

  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginError: String?
  @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
  @State private var recording: Action?
  @AppStorage("showDockIcon") private var showDockIcon = true
  @AppStorage("preventSleep") private var preventSleep = true

  var body: some View {
    Form {
      if mic != .authorized {
        Section("Permissions") {
          PermissionCard(title: "Microphone", icon: "mic.fill", granted: false) {
            if mic == .notDetermined {
              Task { _ = await AVCaptureDevice.requestAccess(for: .audio); mic = AVCaptureDevice.authorizationStatus(for: .audio) }
            } else {
              NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
          }
        }
      }

      Section("Transcription Model") {
        ModelSection(session: session)
      }

      Section {
        ForEach(Action.allCases, id: \.self) { a in
          VStack(alignment: .leading, spacing: 6) {
            Label(a.title, systemImage: a == .toggle ? "record.circle" : "square.and.pencil")
            HotKeyRecorder(action: a, recording: $recording)
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("Hot Keys")
      } footer: {
        Text("Click a shortcut, then press the new keys. Esc cancels. They work from any app.")
          .font(.footnote).foregroundStyle(.secondary)
      }

      if mic == .authorized {
        MicrophoneSection()
      }

      Section("General") {
        Label {
          Toggle("Open on Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, on in
              do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
              } catch {
                loginError = error.localizedDescription
              }
            }
          if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        } icon: {
          Image(systemName: "arrow.right.circle")
        }
        Label {
          Toggle("Show Dock Icon", isOn: $showDockIcon)
            .onChange(of: showDockIcon) { AppDelegate.updateDockIcon() }
        } icon: {
          Image(systemName: "dock.rectangle")
        }
        Label {
          Toggle("Prevent System Sleep while Recording", isOn: $preventSleep)
        } icon: {
          Image(systemName: "zzz")
        }
        Label {
          HStack {
            Text("Sessions Folder")
            Spacer()
            Button("~/Sessions") {
              try? FileManager.default.createDirectory(at: Session.root, withIntermediateDirectories: true)
              NSWorkspace.shared.open(Session.root)
            }
            .buttonStyle(.link)
          }
        } icon: {
          Image(systemName: "folder")
        }
      }
    }
    .formStyle(.grouped)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      mic = AVCaptureDevice.authorizationStatus(for: .audio)
    }
  }
}

/// Hex's MicrophoneSelectionSectionView.
private struct MicrophoneSection: View {
  @AppStorage("microphone") private var selected = "" // "" is the system default
  @State private var devices = Recorder.devices()

  private var missing: Bool { !selected.isEmpty && !devices.contains { $0.uniqueID == selected } }

  var body: some View {
    Section {
      HStack {
        Label {
          Picker("Input Device", selection: $selected) {
            Text(AVCaptureDevice.default(for: .audio).map { "System Default (\($0.localizedName))" } ?? "System Default").tag("")
            ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            if missing { Text("Unavailable Device").tag(selected) }
          }
          .pickerStyle(.menu)
        } icon: {
          Image(systemName: "mic.circle")
        }
        Button { devices = Recorder.devices() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .help("Refresh available input devices")
      }
      if missing {
        Text("Selected device not connected. System default will be used.").font(.caption).foregroundStyle(.secondary)
      }
    } header: {
      Text("Microphone Selection")
    } footer: {
      Text("Record from a specific input device instead of the system default. Applies from the next session.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }
}

/// Hex's PermissionsSectionView card.
private struct PermissionCard: View {
  let title: String
  let icon: String
  let granted: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
      Text(title).font(.body.weight(.medium))
      Spacer()
      if granted {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      } else {
        Button("Grant", action: action).buttonStyle(.bordered).controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: Hot keys (Hex's HotKeyView + KeyView)

/// Click to record. Held modifiers show live; the first non-modifier key completes it.
struct HotKeyRecorder: View {
  let action: Action
  @Binding var recording: Action?

  @State private var held: NSEvent.ModifierFlags = []
  @State private var monitor: Any?
  @State private var error: String?

  private var isActive: Bool { recording == action }

  var body: some View {
    VStack(spacing: 4) {
      HotKeyView(parts: isActive ? Self.symbols(held) : Prefs.shared[action].parts, isActive: isActive)
        .contentShape(Rectangle())
        .onTapGesture { isActive ? stop() : start() }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .onChange(of: recording) { _, now in if now != action { stop(keepRecording: true) } }
    .onDisappear { stop() }
  }

  static func symbols(_ f: NSEvent.ModifierFlags) -> [String] {
    [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { f.contains($0.0) }.map(\.1)
  }

  private func start() {
    error = nil
    held = []
    recording = action
    HotKeys.setEnabled(false)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
      if e.type == .flagsChanged {
        held = e.modifierFlags.intersection([.control, .option, .shift, .command])
        return nil
      }
      if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
      guard let s = Shortcut(e) else {
        error = "Include ⌃, ⌥ or ⌘."
        return nil
      }
      stop()
      error = Prefs.shared.set(action, s)
      return nil
    }
  }

  /// `keepRecording`: another row took over, so leave the shared state alone.
  private func stop(keepRecording: Bool = false) {
    guard monitor != nil else { return }
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    held = []
    if !keepRecording {
      recording = nil
      HotKeys.setEnabled(true)
    }
  }
}

struct HotKeyView: View {
  var parts: [String]
  var isActive: Bool

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
        KeyView(text: p).transition(.blurReplace)
      }
      if parts.isEmpty {
        Color.clear.frame(width: 48, height: 48)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity)
    .background {
      if isActive && parts.isEmpty {
        Text("Enter a key combination").foregroundColor(.secondary).transition(.blurReplace)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.blue.opacity(isActive ? 0.1 : 0))
        .stroke(Color.blue.opacity(isActive ? 0.2 : 0), lineWidth: 1)
    )
    .animation(.bouncy(duration: 0.3), value: parts)
    .animation(.bouncy(duration: 0.3), value: isActive)
  }
}

struct KeyView: View {
  var text: String

  var body: some View {
    Text(text)
      .font(.title.weight(.bold))
      .foregroundColor(.white)
      .frame(minWidth: 48, minHeight: 48)
      .padding(.horizontal, text.count > 1 ? 8 : 0)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(
            Color(white: 0.2)
              .shadow(.inner(color: .white.opacity(0.3), radius: 1, y: 1))
              .shadow(.inner(color: .white.opacity(0.1), radius: 5, y: 8))
              .shadow(.inner(color: .black.opacity(0.3), radius: 1, y: -3))
          )
      )
      .shadow(radius: 4, y: 2)
  }
}

// MARK: About

struct AboutView: View {
  private var updater: Updater { .shared }

  var body: some View {
    Form {
      Section {
        HStack {
          Label("Version", systemImage: "info.circle")
          Spacer()
          Text(updater.current)
          Button(updater.available.map { "Update to \($0)" } ?? "Check for Updates") { updater.check() }
            .buttonStyle(.bordered)
            .disabled(!updater.canCheck)
        }
        HStack {
          Label("Notes Thing is open source", systemImage: "apple.terminal.on.rectangle")
          Spacer()
          Link("Visit the GitHub", destination: URL(string: "https://github.com/yoelgal/notes-thing")!)
        }
        HStack {
          Label("Website", systemImage: "globe")
          Spacer()
          Link("notesthing.yoelgal.com", destination: URL(string: "https://notesthing.yoelgal.com")!)
        }
        HStack {
          Label("Interface adapted from Hex", systemImage: "hexagon")
          Spacer()
          Link("kitlangton/Hex", destination: URL(string: "https://github.com/kitlangton/Hex")!)
        }
      }
    }
    .formStyle(.grouped)
  }
}

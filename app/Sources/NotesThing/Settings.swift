import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: Shortcuts

struct Shortcut: Codable, Equatable {
  var keyCode: UInt32
  var modifiers: UInt // NSEvent.ModifierFlags raw value: ⌃⌥⇧⌘ only
  var key: String

  var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

  var carbonModifiers: UInt32 {
    var m = 0
    if flags.contains(.command) { m |= cmdKey }
    if flags.contains(.option) { m |= optionKey }
    if flags.contains(.control) { m |= controlKey }
    if flags.contains(.shift) { m |= shiftKey }
    return UInt32(m)
  }

  /// Symbols in Apple's order, then the key: ["⌃", "⌥", "P"].
  var parts: [String] {
    [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { flags.contains($0.0) }.map(\.1) + [key]
  }

  var display: String { parts.joined() }

  init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
    self.keyCode = UInt32(keyCode)
    self.modifiers = modifiers.intersection([.control, .option, .shift, .command]).rawValue
    self.key = key
  }

  /// nil if the event can't be a global shortcut (needs ⌃, ⌥ or ⌘; ⇧ alone would eat typing).
  init?(_ e: NSEvent) {
    let mods = e.modifierFlags.intersection([.control, .option, .shift, .command])
    guard !mods.subtracting(.shift).isEmpty else { return nil }
    let named: [UInt16: String] = [
      49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
      122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
      101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    guard let key = named[e.keyCode] ?? e.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
    self.init(keyCode: Int(e.keyCode), modifiers: mods, key: key)
  }
}

enum Action: String, CaseIterable {
  case toggle, note

  var title: String {
    switch self {
    case .toggle: "Start / pause session"
    case .note: "Add a note"
    }
  }

  var defaultShortcut: Shortcut {
    switch self {
    case .toggle: Shortcut(keyCode: kVK_ANSI_P, modifiers: [.control, .option], key: "P")
    case .note: Shortcut(keyCode: kVK_ANSI_N, modifiers: [.control, .option], key: "N")
    }
  }
}

@MainActor @Observable
final class Prefs {
  static let shared = Prefs()

  private(set) var shortcuts: [Action: Shortcut] = [:]

  private init() {
    for a in Action.allCases {
      let saved = UserDefaults.standard.data(forKey: "shortcut.\(a.rawValue)")
        .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
      shortcuts[a] = saved ?? a.defaultShortcut
    }
  }

  subscript(_ a: Action) -> Shortcut { shortcuts[a] ?? a.defaultShortcut }

  /// Returns an error message if the shortcut can't be used.
  func set(_ a: Action, _ s: Shortcut) -> String? {
    if let other = Action.allCases.first(where: { $0 != a && self[$0] == s }) {
      return "Already used for “\(other.title.lowercased())”."
    }
    guard HotKeys.rebind(a, s) else {
      HotKeys.rebind(a, self[a])
      return "Another app is using \(s.display)."
    }
    shortcuts[a] = s
    UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "shortcut.\(a.rawValue)")
    return nil
  }
}

/// Global shortcuts via Carbon, which needs no Accessibility permission.
@MainActor
enum HotKeys {
  private static var actions: [Action: () -> Void] = [:]
  private static var refs: [Action: EventHotKeyRef] = [:]

  static func bind(_ a: Action, _ s: Shortcut, _ action: @escaping () -> Void) {
    if actions.isEmpty {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        MainActor.assumeIsolated {
          let a = Action.allCases[Int(id.id)]
          HotKeys.actions[a]?()
        }
        return noErr
      }, 1, &spec, nil, nil)
    }
    actions[a] = action
    rebind(a, s)
  }

  @discardableResult
  static func rebind(_ a: Action, _ s: Shortcut) -> Bool {
    unbind(a)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x4E_54_48_4B), id: UInt32(Action.allCases.firstIndex(of: a)!)) // "NTHK"
    let status = RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
    refs[a] = ref
    return status == noErr
  }

  static func unbind(_ a: Action) {
    if let ref = refs.removeValue(forKey: a) { UnregisterEventHotKey(ref) }
  }

  /// Off while recording a new shortcut, so pressing the current one doesn't fire it.
  static func setEnabled(_ on: Bool) {
    for a in Action.allCases {
      if on { rebind(a, Prefs.shared[a]) } else { unbind(a) }
    }
  }
}

// MARK: Window

final class SettingsWindow: NSWindow {
  init(session: Session) {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    title = "Notes Thing Settings"
    titlebarAppearsTransparent = true
    isReleasedWhenClosed = false
    contentView = NSHostingView(rootView: SettingsView(session: session))
    center()
  }

  func show() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }
}

struct SettingsView: View {
  var session: Session

  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var loginError: String?
  @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

  var body: some View {
    Form {
      Section {
        ForEach(Action.allCases, id: \.self) { a in
          HStack {
            Text(a.title)
            Spacer()
            ShortcutRecorder(action: a)
          }
        }
      } header: {
        Text("Shortcuts")
      } footer: {
        Text("Click a shortcut, then press the new keys. Works from any app.")
          .foregroundStyle(.secondary)
      }

      Section("General") {
        Toggle("Open at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, on in
            do {
              if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
              loginError = nil
            } catch {
              loginError = error.localizedDescription
            }
          }
        if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        LabeledContent("Microphone") {
          switch mic {
          case .authorized: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          case .notDetermined:
            Button("Allow…") {
              Task { _ = await AVCaptureDevice.requestAccess(for: .audio); mic = AVCaptureDevice.authorizationStatus(for: .audio) }
            }
          default:
            Button("Open System Settings…") {
              NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
          }
        }
        LabeledContent("Speech model") {
          if session.modelReady {
            Label("Parakeet TDT v2 ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…") }
          }
        }
      }

      Section("Sessions") {
        LabeledContent("Saved to") {
          Button("~/Sessions") {
            try? FileManager.default.createDirectory(at: Session.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Session.root)
          }
          .buttonStyle(.link)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 6) {
        Text("Notes Thing \(Updater.shared.current)")
        Text("·")
        Button(Updater.shared.available.map { "Update to \($0)" } ?? "Check for updates") {
          Updater.shared.checkInteractively()
        }
        .buttonStyle(.link)
      }
      .font(.caption).foregroundStyle(.tertiary).padding(.bottom, 12)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      mic = AVCaptureDevice.authorizationStatus(for: .audio)
    }
  }
}

/// Click, press keys. Esc cancels. Keycaps styled after Hex's hotkey view.
struct ShortcutRecorder: View {
  let action: Action

  @State private var recording = false
  @State private var monitor: Any?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      Button { recording ? stop() : start() } label: {
        HStack(spacing: 3) {
          if recording {
            Text("Press keys…").foregroundStyle(.secondary).padding(.horizontal, 6)
          } else {
            ForEach(Array(Prefs.shared[action].parts.enumerated()), id: \.offset) { _, p in
              Text(p)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, p.count > 1 ? 4 : 0)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
          }
        }
        .padding(3)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(recording ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Click to change")
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .onDisappear(perform: stop)
  }

  private func start() {
    error = nil
    recording = true
    HotKeys.setEnabled(false)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
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

  private func stop() {
    guard recording else { return }
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    HotKeys.setEnabled(true)
  }
}

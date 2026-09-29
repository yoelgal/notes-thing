import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct NotesThingApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  init() {
    if CommandLine.arguments.contains("--selfcheck") {
      Transcript.selfCheck()
      exit(0)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--finish"), i + 1 < CommandLine.arguments.count {
      let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
      Task.detached {
        await Session.finish(dir: dir)
        print(dir.appendingPathComponent("session.md").path)
        exit(0)
      }
      dispatchMain()
    }
  }

  var body: some Scene {
    MenuBarExtra {
      Menu(session: delegate.session)
    } label: {
      Image(systemName: icon)
    }
  }

  private var icon: String {
    switch delegate.session.state {
    case .idle: "waveform"
    case .recording: "record.circle"
    case .paused: "pause.circle"
    case .transcribing: "ellipsis.circle"
    }
  }
}

struct Menu: View {
  var session: Session

  var body: some View {
    switch session.state {
    case .idle:
      Button("New Session  ⌃⌥P") { session.toggle() }
    case .recording, .paused:
      Button(session.state == .paused ? "Resume  ⌃⌥P" : "Pause  ⌃⌥P") { session.toggle() }
      Button("Add Note  ⌃⌥N") { AppDelegate.shared?.notePanel.show() }
      Button("Stop & Transcribe") { session.stop() }
    case .transcribing:
      Text("Transcribing…")
    }
    if !session.modelReady { Text("Loading Parakeet model…") }
    Divider()
    if let id = session.lastID {
      Button("Copy /notes \(id)") { session.copyNotesCommand() }
    }
    Button("Open Sessions Folder") {
      try? FileManager.default.createDirectory(at: Session.root, withIntermediateDirectories: true)
      NSWorkspace.shared.open(Session.root)
    }
    Divider()
    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var shared: AppDelegate?

  let session = Session()
  lazy var notePanel = NotePanel(session: session)
  private var overlay: OverlayWindow?

  func applicationDidFinishLaunching(_: Notification) {
    Self.shared = self
    overlay = OverlayWindow(CapsuleView(session: session))
    overlay?.orderFrontRegardless()
    HotKeys.register(kVK_ANSI_P) { [session] in session.toggle() }
    HotKeys.register(kVK_ANSI_N) { [weak self] in self?.notePanel.show() }
  }

  func applicationWillTerminate(_: Notification) {
    session.stopRecorderForQuit()
  }
}

/// Global ⌃⌥<key> shortcuts via Carbon, which needs no Accessibility permission.
@MainActor
enum HotKeys {
  private static var handlers: [UInt32: () -> Void] = [:]
  private static var refs: [EventHotKeyRef?] = []

  static func register(_ keyCode: Int, _ action: @escaping () -> Void) {
    if handlers.isEmpty {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        MainActor.assumeIsolated { HotKeys.handlers[id.id]?() }
        return noErr
      }, 1, &spec, nil, nil)
    }
    let id = UInt32(handlers.count + 1)
    handlers[id] = action
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey),
                        EventHotKeyID(signature: OSType(0x4E_54_48_4B), id: id), // "NTHK"
                        GetApplicationEventTarget(), 0, &ref)
    refs.append(ref)
  }
}

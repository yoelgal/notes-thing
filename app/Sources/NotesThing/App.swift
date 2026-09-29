import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct NotesThingApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  init() {
    if CommandLine.arguments.contains("--selfcheck") {
      Transcript.selfCheck()
      let s = Shortcut(keyCode: 45, modifiers: [.command, .control, .shift, .function], key: "N")
      precondition(s.display == "⌃⇧⌘N" && s.carbonModifiers == UInt32(cmdKey | controlKey | shiftKey), "shortcut")
      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
                               context: nil, characters: "N", charactersIgnoringModifiers: "N", isARepeat: false, keyCode: 45)!
      precondition(Shortcut(e) == nil, "shift-only shortcuts must be rejected")
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
      Image(nsImage: MenuIcon.image(delegate.session.state))
    }
  }
}

struct Menu: View {
  var session: Session
  private var keys: Prefs { .shared }

  var body: some View {
    switch session.state {
    case .idle:
      Button("New Session  \(keys[.toggle].display)") { session.toggle() }
    case .recording, .paused:
      Button("\(session.state == .paused ? "Resume" : "Pause")  \(keys[.toggle].display)") { session.toggle() }
      Button("Add Note  \(keys[.note].display)") { AppDelegate.shared?.notePanel.show() }
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
    let updater = Updater.shared
    if updater.installing {
      Text("Updating…")
    } else if let v = updater.available {
      Button("Update to \(v)…") { updater.install() }
    } else {
      Button("Check for Updates…") { updater.checkInteractively() }
    }
    Button("Settings…") { AppDelegate.shared?.settings.show() }.keyboardShortcut(",")
    Divider()
    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var shared: AppDelegate?

  let session = Session()
  lazy var notePanel = NotePanel(session: session)
  lazy var settings = SettingsWindow(session: session)
  private var overlay: OverlayWindow?

  func applicationDidFinishLaunching(_: Notification) {
    Self.shared = self
    _ = Updater.shared
    overlay = OverlayWindow(CapsuleView(session: session))
    overlay?.orderFrontRegardless()
    HotKeys.bind(.toggle, Prefs.shared[.toggle]) { [session] in session.toggle() }
    HotKeys.bind(.note, Prefs.shared[.note]) { [weak self] in self?.notePanel.show() }
  }

  func applicationWillTerminate(_: Notification) {
    session.stopRecorderForQuit()
  }
}

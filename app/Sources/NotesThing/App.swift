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
      precondition(s.keyEquivalent == KeyEquivalent("n") && s.eventModifiers == SwiftUI.EventModifiers([.command, .control, .shift]), "menu shortcut")
      precondition(Shortcut(keyCode: 122, modifiers: .option, key: "F1").keyEquivalent == KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), "F-key")
      // Moving the sessions folder: everything arrives, the old folder goes, and a folder inside the old one is refused.
      let fm = FileManager.default, saved = UserDefaults.standard.string(forKey: "sessionsFolder")
      let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString), from = tmp.appendingPathComponent("a"), to = tmp.appendingPathComponent("b")
      try! fm.createDirectory(at: from.appendingPathComponent("20260101-0900"), withIntermediateDirectories: true)
      try! fm.createDirectory(at: to, withIntermediateDirectories: true)
      UserDefaults.standard.set(from.path, forKey: "sessionsFolder")
      try! Session.moveRoot(to: to)
      precondition(fm.fileExists(atPath: to.appendingPathComponent("20260101-0900").path) && !fm.fileExists(atPath: from.path), "move sessions")
      precondition(Session.root.standardizedFileURL == to.standardizedFileURL && !Session.rootMissing, "repoint")
      precondition((try? Session.moveRoot(to: to.appendingPathComponent("inner"))) == nil, "refuse a folder inside the old one")
      UserDefaults.standard.set(saved, forKey: "sessionsFolder")
      try? fm.removeItem(at: tmp)
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
      Button("New Session") { session.toggle() }.shortcut(keys[.toggle])
    case .recording, .paused:
      Button(session.state == .paused ? "Resume" : "Pause") { session.toggle() }.shortcut(keys[.toggle])
      Button("Add Note") { AppDelegate.shared?.notePanel.show() }.shortcut(keys[.note])
      Button("Stop & Transcribe") { session.stop() }
    case .transcribing:
      Text("Transcribing…")
    }
    if !session.modelReady { Text("Loading \(Models.shared.selected.displayName)…") }
    Divider()
    if let id = session.lastID {
      Button("Copy /notes \(id)") { session.copyNotesCommand() }
    }
    Button("Open Sessions Folder") { Session.openRoot() }
    let updater = Updater.shared
    if let v = updater.available {
      Button("Update to \(v)…") { updater.check() }
    } else {
      Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
    Button("History…") { AppDelegate.shared?.window.show(.history) }
    Button("Settings…") { AppDelegate.shared?.window.show(.settings) }.keyboardShortcut(",")
    Divider()
    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

extension View {
  /// Shows a global shortcut on a menu item, like Hex's Paste Last Transcript.
  @ViewBuilder func shortcut(_ s: Shortcut) -> some View {
    if let k = s.keyEquivalent { keyboardShortcut(k, modifiers: s.eventModifiers) } else { self }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var shared: AppDelegate?

  let session = Session()
  lazy var notePanel = NotePanel(session: session)
  lazy var window = AppWindow(session: session)
  private var overlay: OverlayWindow?

  func applicationDidFinishLaunching(_: Notification) {
    Self.shared = self
    _ = Updater.shared
    Models.shared.onSelect = { [session] in session.loadModel() }
    overlay = OverlayWindow(CapsuleView(session: session))
    overlay?.orderFrontRegardless()
    HotKeys.bind(.toggle, Prefs.shared[.toggle]) { [session] in session.toggle() }
    HotKeys.bind(.note, Prefs.shared[.note]) { [weak self] in self?.notePanel.show() }
    Self.updateDockIcon()
    Session.rememberRoot()
    // Hex's onboarding: open the window on every launch except a login launch, so permissions and the model are up front.
    // The very first launch opens on Get Started instead.
    if !Self.launchedAtLogin() {
      let firstLaunch = !UserDefaults.standard.bool(forKey: "seenGetStarted")
      UserDefaults.standard.set(true, forKey: "seenGetStarted")
      window.show(firstLaunch ? .start : .settings)
    }
  }

  static func updateDockIcon() {
    NSApp.setActivationPolicy(UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true ? .regular : .accessory)
  }

  private static func launchedAtLogin() -> Bool {
    guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
    return e.eventID == AEEventID(kAEOpenApplication)
      && e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    window.show()
    return true
  }

  func applicationWillTerminate(_: Notification) {
    session.stopRecorderForQuit()
  }
}

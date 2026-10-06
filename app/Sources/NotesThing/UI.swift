import AppKit
import SwiftUI

// MARK: Capsule (adapted from Hex's TranscriptionIndicatorView, minus the Pow/Inject effects)

struct CapsuleView: View {
  var session: Session

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56

  private var state: Session.State { session.state }
  @State private var pulse = false

  private var backgroundColor: Color {
    switch state {
    case .idle: .clear
    case .recording: mixedColor(mixedNSColor(.red, with: .black, by: 0.5), with: .red, by: session.meter * 3)
    case .paused: Color(white: 0.25)
    case .transcribing: mixedColor(.blue, with: .black, by: 0.5)
    }
  }

  private var strokeColor: Color {
    switch state {
    case .idle: .clear
    case .recording: mixedColor(.red, with: .white, by: 0.1).opacity(0.6)
    case .paused: Color.white.opacity(0.3)
    case .transcribing: mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
    }
  }

  private var innerShadowColor: Color {
    switch state {
    case .idle, .paused: .clear
    case .recording: .red
    case .transcribing: .blue
    }
  }

  var body: some View {
    let averagePower = min(1, session.meter * 3)
    Capsule()
      .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
      .overlay {
        Capsule().stroke(strokeColor, lineWidth: 1).blendMode(.screen)
      }
      .overlay(alignment: .center) {
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(Color.red.opacity(state == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0))
          .blur(radius: 2)
          .blendMode(.screen)
          .padding(6)
      }
      .overlay(alignment: .center) {
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(Color.white.opacity(state == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0))
          .blur(radius: 1)
          .blendMode(.screen)
          .padding(7)
      }
      .cornerRadius(cornerRadius)
      .shadow(color: state == .recording ? .red.opacity(averagePower) : .clear, radius: 4)
      .shadow(color: state == .recording ? .red.opacity(averagePower * 0.5) : .clear, radius: 8)
      .animation(.interactiveSpring(), value: session.meter)
      .frame(width: state == .recording ? expandedWidth : baseWidth, height: baseWidth)
      .opacity(state == .idle ? 0 : state == .transcribing && pulse ? 0.5 : 1)
      .scaleEffect(state == .idle ? 0 : 1)
      .blur(radius: state == .idle ? 4 : 0)
      .animation(.bouncy(duration: 0.3), value: state)
      .task(id: state == .transcribing) {
        while state == .transcribing, !Task.isCancelled {
          withAnimation(.easeInOut(duration: 0.5)) { pulse.toggle() }
          try? await Task.sleep(for: .seconds(0.5))
        }
        pulse = false
      }
  }

  private func mixedColor(_ color: NSColor, with other: NSColor, by fraction: Double) -> Color {
    Color(nsColor: mixedNSColor(color, with: other, by: fraction))
  }

  private func mixedNSColor(_ color: NSColor, with other: NSColor, by fraction: Double) -> NSColor {
    color.blended(withFraction: min(max(fraction, 0), 1), of: other) ?? color
  }
}

extension NSScreen {
  /// The display the pointer is on, so the capsule and note field show up where you're looking.
  static var withMouse: NSScreen {
    screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? main ?? screens[0]
  }
}

/// Hex's InvisibleWindow: a click-through panel covering the screen with the mouse, capsule drawn top-centre.
final class OverlayWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private var mouseMonitor: Any?

  init<V: View>(_ view: V) {
    super.init(contentRect: NSScreen.withMouse.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
               backing: .buffered, defer: false)
    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
    contentView = NSHostingView(rootView: view.padding().padding(.top).padding(.top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    // Follow the mouse across displays, and refit when a monitor is plugged in, unplugged or rearranged
    // (a frame fixed at launch leaves the capsule off-screen).
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                           queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.follow() }
    }
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      MainActor.assumeIsolated { self?.follow() }
    }
  }

  private func follow() {
    let frame = NSScreen.withMouse.frame
    if self.frame != frame { setFrame(frame, display: true) }
  }
}

// MARK: Menu bar icon

/// The app icon's mark: the recording capsule above three lines of notes.
/// The capsule fills while recording and is an outline otherwise; paused dims everything,
/// transcribing turns the lines into dots.
@MainActor
enum MenuIcon {
  private static var cache: [Session.State: NSImage] = [:]

  static func image(_ state: Session.State) -> NSImage {
    if let img = cache[state] { return img }
    let img = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
      draw(state, NSColor.black)
      return true
    }
    img.isTemplate = true
    cache[state] = img
    return img
  }

  /// Same geometry as the icon() function in site/index.html.
  nonisolated static func draw(_ state: Session.State, _ color: NSColor) {
    func pill(_ r: NSRect) -> NSBezierPath { let c = min(r.width, r.height) / 2; return NSBezierPath(roundedRect: r, xRadius: c, yRadius: c) }
    let ink = state == .paused ? color.withAlphaComponent(0.4) : color
    ink.setFill(); ink.setStroke()
    if state == .recording {
      pill(NSRect(x: 4, y: 13.5, width: 11, height: 4.5)).fill()
    } else {
      let cap = pill(NSRect(x: 4.65, y: 14.15, width: 9.7, height: 3.2))
      cap.lineWidth = 1.3
      cap.stroke()
    }
    for (y, w) in [(9.5, 15.0), (5.25, 15.0), (1.0, 10.0)] {
      if state == .transcribing {
        for i in 0 ..< Int((w / 3).rounded()) {
          NSBezierPath(ovalIn: NSRect(x: 2 + Double(i) * 3, y: y, width: 2.5, height: 2.5)).fill()
        }
      } else {
        pill(NSRect(x: 2, y: y, width: w, height: 2.5)).fill()
      }
    }
  }
}

// MARK: Note field

/// A Spotlight-style panel: takes keystrokes without activating the app, so focus
/// returns to whatever you were in when it closes.
final class NotePanel: NSPanel {
  override var canBecomeKey: Bool { true }

  private let session: Session

  init(session: Session) {
    self.session = session
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
               backing: .buffered, defer: false)
    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
  }

  func show() {
    guard session.state == .recording || session.state == .paused else { return }
    contentView = NSHostingView(rootView: NoteField(session: session) { [weak self] in self?.orderOut(nil) })
    let screen = NSScreen.withMouse
    let size = NSSize(width: 460, height: 44)
    setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 118, width: size.width, height: size.height),
             display: true)
    makeKeyAndOrderFront(nil)
    // SwiftUI drops focus requests made before the window is key, so focus the field once it is.
    DispatchQueue.main.async { [weak self] in
      guard let self, let field = self.contentView.flatMap(Self.textField) else { return }
      self.makeFirstResponder(field)
    }
  }

  private static func textField(in view: NSView) -> NSTextField? {
    view as? NSTextField ?? view.subviews.lazy.compactMap(textField).first
  }

  override func resignKey() {
    super.resignKey()
    orderOut(nil) // clicking elsewhere dismisses, like Spotlight
  }
}

struct NoteField: View {
  var session: Session
  var close: () -> Void

  @State private var text = ""
  @State private var anchor: (t: TimeInterval, paused: Bool)?

  var body: some View {
    TextField(session.state == .paused ? "Note (paused)" : "Note", text: $text)
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Capsule().fill(Color.black.opacity(0.85)))
      .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
      .onChange(of: text) { old, new in
        // Anchor to the first keystroke, not Enter: you start typing right after the thing you heard.
        if old.isEmpty, !new.isEmpty, anchor == nil { anchor = (session.t, session.state == .paused) }
      }
      .onSubmit {
        if let anchor { session.addNote(text, at: anchor.t, paused: anchor.paused) }
        close()
      }
      .onExitCommand(perform: close)
  }
}

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

/// Hex's InvisibleWindow: a click-through panel covering the screen, capsule drawn top-centre.
/// ponytail: main screen only, Hex follows the mouse across displays if that's ever needed.
final class OverlayWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init<V: View>(_ view: V) {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
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
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let size = NSSize(width: 460, height: 44)
    setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 110, width: size.width, height: size.height),
             display: true)
    makeKeyAndOrderFront(nil)
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
  @FocusState private var focused: Bool

  var body: some View {
    TextField(session.state == .paused ? "Note (paused)" : "Note", text: $text)
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .foregroundStyle(.white)
      .focused($focused)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Capsule().fill(Color.black.opacity(0.85)))
      .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
      .onAppear { focused = true }
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

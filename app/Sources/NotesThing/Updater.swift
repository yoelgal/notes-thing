import AppKit
import Observation
import Sparkle

/// Sparkle, like Hex. No Apple Developer ID needed: Sparkle trusts an update because it's signed
/// with our EdDSA key (the SPARKLE_PRIVATE_KEY secret in CI), and lets the ad-hoc signature change.
@MainActor @Observable
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  static let shared = Updater()

  /// Found by a background check. Shown in the menu rather than popping a window mid-session.
  private(set) var available: String?
  private(set) var canCheck = false

  @ObservationIgnored private var controller: SPUStandardUpdaterController!
  @ObservationIgnored private var observation: NSKeyValueObservation?
  /// "Install and Relaunch" during a session: held until the session is transcribed.
  @ObservationIgnored private var pendingRelaunch: (() -> Void)?

  var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

  override private init() {
    super.init()
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
      MainActor.assumeIsolated { self?.canCheck = u.canCheckForUpdates }
    }
  }

  func check() {
    NSApp.activate(ignoringOtherApps: true)
    controller.checkForUpdates(nil)
  }

  func sessionEnded() {
    pendingRelaunch?()
    pendingRelaunch = nil
  }

  // MARK: SPUUpdaterDelegate

  nonisolated func updater(_: SPUUpdater, shouldPostponeRelaunchForUpdate _: SUAppcastItem,
                           untilInvokingBlock install: @escaping () -> Void) -> Bool {
    MainActor.assumeIsolated {
      // Relaunching quits the app, which would cut a recording short.
      guard let session = AppDelegate.shared?.session, session.state != .idle else { return false }
      pendingRelaunch = install
      let a = NSAlert()
      a.messageText = "Update ready"
      a.informativeText = "Notes Thing will update once this session is transcribed. Your recording is safe."
      a.runModal()
      return true
    }
  }

  // MARK: Gentle reminders (Sparkle's advice for menu bar apps)

  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Sparkle shows the window itself only when it would be in focus anyway (just after launch).
  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
    immediateFocus
  }

  nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state _: SPUUserUpdateState) {
    let version = update.displayVersionString
    MainActor.assumeIsolated { if !handleShowingUpdate { available = version } }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated { available = nil }
  }
}

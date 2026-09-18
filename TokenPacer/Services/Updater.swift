import AppKit
import Sparkle

/// Sparkle, owned for the app's lifetime.
///
/// The controller schedules its own background checks against `SUFeedURL`; the
/// menu item only exists for people who want to ask. An accessory app has no
/// Dock icon to bounce and no menu bar of its own, so a check has to activate
/// the app or Sparkle's dialog opens behind whatever is in front.
@MainActor
// @preconcurrency: Sparkle's delegate protocol predates strict concurrency and
// is not annotated, but it calls back on the main thread.
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    /// Optional, not implicitly unwrapped: it cannot be built before `super.init()`
    /// because Sparkle takes `self` as its user-driver delegate, and an `!` there is
    /// a force unwrap with the crash moved to first use.
    private var controller: SPUStandardUpdaterController?
    private let notifier: Notifier

    init(notifier: Notifier = Notifier()) {
        self.notifier = notifier
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
        )
    }

    /// False while a check is already running — the menu row greys out rather
    /// than queueing a second one.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        NSApp.activate()
        controller?.updater.checkForUpdates()
    }

    // MARK: - gentle reminders

    /// Sparkle asks for this, and for a background app it is not optional: an
    /// alert panel from an app with no Dock icon and no menu bar arrives from
    /// nowhere and is missed behind whatever is in front.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check that found something says so quietly, through the same
    /// banner the thresholds use. A check the user asked for shows Sparkle's own
    /// window, because they are looking at it.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        notifier.alert(
            title: "Token Pacer \(update.displayVersionString) is available",
            body: "Right-click the notch and choose Check for updates to install it.",
            sound: false, whenNotchHidden: false
        )
    }
}

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
@Observable
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    /// Optional, not implicitly unwrapped: it cannot be built before `super.init()`
    /// because Sparkle takes `self` as its user-driver delegate, and an `!` there is
    /// a force unwrap with the crash moved to first use.
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// The version a background check found, until somebody installs it. The
    /// notch menu says so in its own row; this app asks macOS for nothing.
    private(set) var pendingVersion: String?

    override init() {
        // Debug hook: `TOKENPACER_SIMULATE_UPDATE=1.2.0` puts the badge and the
        // card's row on screen. The real state needs a signed appcast, and the
        // key that signs one is not something a review should have to reach
        // for. A sibling of `TOKENPACER_SIMULATE_ERROR`.
        pendingVersion = ProcessInfo.processInfo.environment["TOKENPACER_SIMULATE_UPDATE"]
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
        )
    }

    /// False while a check is already running — the menu row greys out rather
    /// than queueing a second one.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// One switch, both halves: checking and installing are the same question
    /// to everyone but Sparkle, and leaving them apart puts a second checkbox
    /// in Sparkle's own update dialog for the setting the pane already owns.
    ///
    /// Sparkle owns the storage — `SUEnableAutomaticChecks` and
    /// `SUAutomaticallyUpdate` in Info.plist are the defaults until the switch
    /// is touched, and the user defaults they write win afterwards. Nothing in
    /// `Preferences` mirrors it, so "Restore defaults" leaves it alone.
    var updatesAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? true }
        set {
            // Order matters: `automaticallyDownloadsUpdates` reports NO while
            // checks are off, so turning on has to enable checking first.
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.updater.checkForUpdates()
    }

    // MARK: - gentle reminders

    /// Sparkle asks for this, and for a background app it is not optional: an
    /// alert panel from an app with no Dock icon and no menu bar arrives from
    /// nowhere and is missed behind whatever is in front.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check that found something leaves it in the menu. A check the
    /// user asked for shows Sparkle's own window, because they are looking at it.
    ///
    /// It used to raise a macOS banner, which meant asking for notification
    /// permission — for an app whose whole surface is already on screen, and on a
    /// Mac where that permission is declined the news simply never arrived.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        pendingVersion = update.displayVersionString
    }

    /// Put the row back once the update is no longer waiting on anybody.
    ///
    /// Sparkle names this as the place to take down whatever the line above put
    /// up, and without it the menu kept offering a version the user had already
    /// skipped — for the rest of the session, since nothing else clears it.
    /// A dismissed update is not a pending one.
    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}

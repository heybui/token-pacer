import Foundation
import ServiceManagement

/// `SMAppService` registers the bundle itself — no helper target, no login-item
/// plist. It only works from a signed bundle, so a `swift run` build reports
/// disabled rather than pretending.
struct LaunchAtLogin: Sendable {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Denied, unsigned, or run from a build directory: worth a line, not
            // a dialog — the toggle simply reports what the system says.
            Log.notch.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// On by default, but only once. A usage tracker you have to remember to
    /// start has a gap in it every morning — and "default" has to mean the first
    /// launch alone, or turning the toggle off would last exactly until the next
    /// one.
    ///
    /// The marker is written only after the system actually took the
    /// registration, so an unsigned or ad-hoc build that cannot register tries
    /// again next launch rather than burning its one chance.
    func enableOnFirstLaunch(store: UserDefaults = .standard) {
        guard !store.bool(forKey: Self.defaultAppliedKey) else { return }
        set(true)
        // `.requiresApproval` counts: the system has it, and it is the user's
        // switch in System Settings from here on.
        guard SMAppService.mainApp.status != .notRegistered else { return }
        store.set(true, forKey: Self.defaultAppliedKey)
    }

    private static let defaultAppliedKey = "launchAtLogin.defaultApplied"
}

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
}

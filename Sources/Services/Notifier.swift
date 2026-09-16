import AppKit
import UserNotifications

/// Banners, but only when the notch cannot speak for itself.
///
/// "Only shown when a full-screen app hides the notch — otherwise the notch
/// itself carries the alert." A banner beside a pill that is already showing the
/// same number is noise.
@MainActor
struct Notifier {
    var isNotchVisible: () -> Bool = { FullScreenDetector.isMenuBarVisible }
    var center: UNUserNotificationCenter? = Self.availableCenter

    /// `UNUserNotificationCenter` traps outside an app bundle, so a `swift run`
    /// build gets no notifications rather than a crash.
    private static var availableCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func alert(title: String, body: String, sound: Bool) {
        guard !isNotchVisible(), let center else { return }

        // Asked for on the first crossing rather than at launch: permission for
        // something that has not happened yet is the most ignorable prompt there
        // is, and the app works without it.
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                if let error {
                    Log.notch.error("notifications: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body                       // one coach line, no buttons
            if sound { content.sound = .default }

            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            ))
        }
    }
}

/// Full screen is detected by the menu bar being gone rather than by enumerating
/// windows: window enumeration needs Screen Recording permission, and this needs
/// nothing.
///
/// ponytail: also true when the menu bar is set to auto-hide, which costs a
/// banner the user would have seen anyway. Upgrade to CGWindowListCopyWindowInfo
/// only if that misfires in practice.
enum FullScreenDetector {
    @MainActor
    static var isMenuBarVisible: Bool {
        guard let screen = NSScreen.main else { return true }
        return screen.visibleFrame.maxY < screen.frame.maxY
    }
}

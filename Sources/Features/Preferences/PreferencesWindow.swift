import AppKit
import SwiftUI

/// One window, kept alive between openings so its position sticks.
///
/// An accessory app has no Dock icon and no menu bar, so nothing else would
/// bring this forward: opening it activates the app, and closing it hands focus
/// back to whatever was in front.
@MainActor
final class PreferencesWindow {
    private var window: NSWindow?

    func show(preferences: Preferences, launchAtLogin: LaunchAtLogin = LaunchAtLogin()) {
        if window == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Burn Tracker"
            window.titlebarAppearsTransparent = true
            // AppKit draws the title in the *window's* appearance, not the
            // content's: on a light desktop it came out dark-on-dark.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Color(hex: 0x141416))
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: PreferencesView(preferences: preferences, launchAtLogin: launchAtLogin)
            )
            window.center()
            self.window = window
        }

        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

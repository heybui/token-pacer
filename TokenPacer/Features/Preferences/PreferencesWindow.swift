import AppKit
import SwiftUI

/// The settings window, built when it is opened and let go when it is closed.
///
/// An accessory app has no Dock icon and no menu bar, so nothing else would
/// bring this forward: opening it activates the app, and closing it hands focus
/// back to whatever was in front.
@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Where it was last time. The window itself does not survive closing, but
    /// where the user put it should.
    private var origin: CGPoint?

    func show(
        preferences: Preferences, launchAtLogin: LaunchAtLogin = LaunchAtLogin(),
        updater: Updater? = nil
    ) {
        let window = window ?? make(
            preferences: preferences, launchAtLogin: launchAtLogin, updater: updater
        )
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing has to end what is inside, not just hide it.
    ///
    /// A SwiftUI view in a window that merely closed is never told it
    /// disappeared: the Appearance pane's preview lap went on stepping twelve
    /// marks ten times a second, at **8% of a core, for as long as the app ran**.
    /// Letting the window go takes the view tree with it, and every task it
    /// started.
    func windowWillClose(_ notification: Notification) {
        origin = window?.frame.origin
        window = nil
    }

    private func make(
        preferences: Preferences, launchAtLogin: LaunchAtLogin, updater: Updater?
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Token Pacer"
        window.titlebarAppearsTransparent = true
        // AppKit draws the title in the *window's* appearance, not the
        // content's: on a light desktop it came out dark-on-dark.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Color(hex: 0x141416))
        window.isReleasedWhenClosed = false
        // The pill floats at .statusBar, above every ordinary window, so a
        // settings window at .normal opens *underneath* the notch. One level
        // higher puts it in front of the thing it configures — and it hides
        // when the app deactivates, so it never floats over another app's
        // work once you have moved on.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.hidesOnDeactivate = ProcessInfo.processInfo.environment["TP_OPEN_PREFS"] == nil
        window.delegate = self
        // The content sizes the window, which is why it is installed before the
        // window is placed: a hosting view reports nothing until it has one.
        window.contentView = NSHostingView(
            rootView: PreferencesView(
                preferences: preferences, launchAtLogin: launchAtLogin, updater: updater
            )
        )
        if let origin { window.setFrameOrigin(origin) } else { window.center() }
        self.window = window
        return window
    }

    /// Named for the test that pins the close: what a window does to what is in
    /// it is not something a view can be asked about afterwards.
    var isOpen: Bool { window != nil }
    func closeForTesting() { window?.close() }
}

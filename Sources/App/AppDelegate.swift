import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode runs unit tests inside the app; don't throw a panel over the
        // screen while they do.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Typography.register()   // before any view is built
        notch = NotchController()
    }
}

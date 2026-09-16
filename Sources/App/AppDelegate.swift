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

    /// The last few minutes of events would otherwise be re-read from 700MB of
    /// logs on the next launch. `.terminateLater` gives the write time to land.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let notch else { return .terminateNow }
        Task {
            await notch.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

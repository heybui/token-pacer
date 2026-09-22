import AppKit
import SwiftUI

/// The report's own window, built when it is opened and let go when it is
/// closed — `PreferencesWindow`, in miniature, and for one reason it does not
/// share: a sheet is sized by its content and cannot be dragged bigger. A wall
/// of JSON read through a fixed 420pt slot is read through a keyhole.
///
/// Letting the window go on close also ends the view inside it, and with it the
/// three CLI reads if they are still running.
@MainActor
final class DiagnosticsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let window = window ?? make()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }

    private func make() -> NSWindow {
        let window = NSWindow(
            // Small to open, because it opens over the settings window it was
            // asked for from and a report is not the thing being worked on.
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Diagnostics")
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Color(hex: 0x141416))
        window.isReleasedWhenClosed = false
        // Above the pill, as the settings window is: both are opened from a
        // panel that floats at `.statusBar`, and a window under it opens behind
        // the notch.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Unlike settings: this is the window whose text is being pasted into
        // somewhere else, and one that vanishes the moment you click the other
        // app is a window you cannot copy out of twice.
        window.hidesOnDeactivate = false
        // Below the opening size, not equal to it: a window that cannot be made
        // smaller than it opens is a window with a resize handle that only goes
        // one way.
        window.contentMinSize = NSSize(width: 340, height: 220)
        window.delegate = self
        let content = NSHostingView(rootView: DiagnosticsView())
        // Nothing in a report has a natural size, and a hosting view left to
        // its own devices asks for one anyway: the caption's ideal width is the
        // whole sentence on one line and the scroll view's ideal height is
        // every line at once, so the window opened 650pt wide and 2,000 tall.
        // The window says how big it is; the content fills it.
        content.sizingOptions = []
        window.contentView = content
        window.setContentSize(NSSize(width: 420, height: 300))
        window.center()
        self.window = window
        return window
    }

    var isOpen: Bool { window != nil }
}

/// What each provider replied, on screen.
///
/// The same report as `TokenPacer --raw`, for the person who will never open a
/// terminal to run it. A row that reads "could not read Copilot's usage panel"
/// states that something went wrong and nothing about what; the reply behind it
/// is the whole evidence, and asking somebody to paste a shell command to get at
/// it is asking most people for nothing.
struct DiagnosticsView: View {
    /// Nil until the readers come back — they are started by `.task`, not by a
    /// button, because a sheet opened for this report is the ask.
    @State private var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnostics")
                    .font(Typography.sans(14, .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("What each provider answered, with the terminal's escape codes taken out and the account id removed.")
                    .font(Typography.sans(11.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }

            DiagnosticsReport(report: report)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Copy") {
                    guard let report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(report == nil)
            }
            .font(Typography.sans(12))
        }
        .padding(20)
        // Whatever the window is: the report is the one thing in this app with
        // no right size, and the person reading it knows how much of their
        // screen they want to give it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: 0x141416))
        .environment(\.colorScheme, .dark)
        .task { report = await Probe.rawReport() }
    }
}

/// The report itself, or the wait for it.
///
/// Claude's CLI paints its panel over the better part of a minute and the three
/// readers run together, so that minute is the floor. Saying so is the
/// difference between a slow window and a broken one.
private struct DiagnosticsReport: View {
    var report: String?

    var body: some View {
        ScrollView {
            if let report {
                Text(report)
                    .font(Typography.mono(10.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating the diagnostics log takes about a minute.")
                        .font(Typography.sans(11.5))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
        .background(Color(hex: 0x0E0E10))
        .clipShape(.rect(cornerRadius: 10))
        .frame(maxHeight: .infinity)
    }
}

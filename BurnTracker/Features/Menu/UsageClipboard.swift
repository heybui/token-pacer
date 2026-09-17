import AppKit

/// Shared by the menu item and by ⌘C, which the panel handles itself because a
/// menu-bar-less app has no responder chain to route it through.
@MainActor
enum UsageClipboard {
    static func copy(_ snapshot: UsageSnapshot?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Format.usageSummary(snapshot), forType: .string)
    }
}

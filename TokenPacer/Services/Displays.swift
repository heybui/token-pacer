import AppKit

/// A connected screen, as Settings offers it.
struct DisplayOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// The screens attached right now. Settings has no AppKit of its own, so the
/// list and the notification that it changed are asked for here.
enum Displays {
    /// Connected, disconnected, rearranged or resized.
    static let didChange = NSApplication.didChangeScreenParametersNotification

    @MainActor
    static func connected() -> [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            screen.displayUUID.map { DisplayOption(id: $0, name: screen.localizedName) }
        }
    }
}

extension NSScreen {
    /// Survives unplugging and reconnecting, unlike `NSScreenNumber`, which a
    /// monitor can come back under a different value of.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}

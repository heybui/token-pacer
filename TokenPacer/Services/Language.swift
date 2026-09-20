import Foundation

/// Which languages this build actually carries.
///
/// Read off the bundle rather than listed here: a language arrives as an
/// `.lproj` compiled out of `Localizable.xcstrings`, and the picker is meant to
/// grow with the catalog rather than with an edit to a switch nobody remembers.
/// A `swift run` build has no bundle and no resources, so it reads one language
/// and the row that offers a choice never appears.
enum Language {
    /// Every language in the bundle, in a stable order. "Base" is a layout, not
    /// a language, so it is never offered.
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted()
    }

    /// Whether there is a choice to make. One language is not a picker, it is a
    /// row that says the same thing every time it is opened.
    static var isOffered: Bool { available.count > 1 }

    /// The language's name in itself — "Tiếng Việt", never "Vietnamese". A
    /// picker labelled in a language you do not read is a picker you cannot
    /// leave once you have landed in it.
    static func name(_ code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.localizedCapitalized
            ?? code
    }
}

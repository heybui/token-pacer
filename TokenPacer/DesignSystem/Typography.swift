import AppKit
import CoreText
import SwiftUI

/// Instrument Sans is a Google font — no Mac ships with it, so it is bundled and
/// registered at launch.
///
/// If registration fails the app keeps working: `Font.custom` silently falls back
/// to the system face, which is why availability is checked explicitly and logged.
/// A silent fallback that nobody notices is how a design drifts.
enum Typography {
    static let family = "Instrument Sans"

    private nonisolated(unsafe) static var registered = false

    /// True once the bundled face is usable.
    static var isAvailable: Bool { registered }

    /// Call once at launch, before any view is built.
    static func register(bundle: Bundle = .main) {
        guard !registered else { return }
        guard let url = bundle.url(forResource: "InstrumentSans", withExtension: "ttf") else {
            Log.notch.notice("Instrument Sans not bundled; falling back to the system face")
            return
        }

        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // A bundled app registers the face from ATSApplicationFontsPath before
            // this runs, so "already registered" is the expected path, not a fault.
            let failure = error?.takeRetainedValue() as? Error
            let code = failure.map { ($0 as NSError).code } ?? 0
            if code != alreadyRegistered {
                Log.notch.error("font registration failed: \(failure?.localizedDescription ?? "unknown", privacy: .public)")
            }
        }

        // Availability is the only thing that decides this, never the return value
        // above. A face that registered elsewhere is still usable, and a silent
        // fallback nobody notices is how a design drifts.
        registered = isFamilyInstalled()
        Log.notch.info("\(family, privacy: .public) available=\(registered, privacy: .public)")
    }

    /// kCTFontManagerErrorAlreadyRegistered
    private static let alreadyRegistered = 105

    private static func isFamilyInstalled() -> Bool {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return families.contains(family)
    }

    /// Body and label text. Falls back to the system face when unregistered.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registered
            ? .custom(family, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    /// Every figure. SF Mono, as the design specifies — always present.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// How wide a string is when `OdometerText` draws it.
    ///
    /// Asked of the font rather than estimated. "0.6em a character" is the cell
    /// the odometer gives a *digit*, and it was used for the whole string to size
    /// the flanks — which came out about a point short per character, so a
    /// six-figure countdown sat 6pt into its own gutter and a seven-figure one
    /// would have run off the end of the shell.
    ///
    /// Digits keep the cell, because that is what the odometer draws them in.
    /// Everything else is measured.
    static func monoWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .medium) -> CGFloat {
        // AppKit declares this non-optional and it has come back nil anyway,
        // once, mid-layout — a nil value in an attributes dictionary aborts the
        // process from inside CoreText, which is a crash for a figure that is
        // three points wide. Bridged through an Optional so a font the system
        // declines to make costs an estimate instead: the digit cell below,
        // applied to every character. Slightly wide for letters, which errs the
        // way the wing can survive.
        let font: NSFont? = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        guard let font else {
            Log.notch.error("no monospaced system font at \(size, privacy: .public)pt; estimating")
            return CGFloat(text.count) * size * 0.6
        }
        return text.reduce(0) { total, character in
            guard !character.isNumber else { return total + size * 0.6 }
            return total + (String(character) as NSString)
                .size(withAttributes: [.font: font]).width
        }
    }
}

# Token Pacer — agent rules

macOS notch usage tracker. `docs/PRD.md` is the product, `docs/ARCHITECTURE.md`
the technical spec, `docs/ACCESS.md` what it reads off disk.

## Commits

**Conventional Commits, always.** `<type>(<scope>): <subject>`

- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert`.
- Scope is the area touched, lowercase: `notch`, `pill`, `panel`, `sources`, `engine`, `store`, `prefs`, `design-system`. Omit it when a change is genuinely repo-wide.
- Subject: imperative mood, lowercase, no trailing period, ≤ 72 chars. "add cursor reader", not "Added cursor reader."
- Breaking change: `!` after the scope (`feat(sources)!: …`) plus a `BREAKING CHANGE:` footer.
- Body only when the *why* isn't obvious from the diff. Wrap at 72.
- One logical change per commit. Don't bundle a refactor with a feature.

## Build

- `swift build` / `swift test` — fast CLI loop.
- `xcodebuild -scheme TokenPacer build|test` — the shipping path (signing, entitlements, Sparkle later).
- Both read the same `TokenPacer/` and `TokenPacerTests/` folders, so they cannot drift. Adding a file needs no project edit: the Xcode target uses synchronized folder groups.

## Code

- `TokenPacer/Core/` imports Foundation and `os` only — no SwiftUI, no AppKit. That constraint is what keeps the engine testable and the usage sources swappable; `os.Logger` is infrastructure, not a UI framework, so it does not break it.
- Logging is `os.Logger` via `Log`, never `print`: a bundled app launched from Finder has nowhere to send stdout. Mark safe values `.public` — `os_log` redacts dynamic values otherwise — and never log a token.
- User-facing copy goes through `Resources/Localizable.xcstrings`. SwiftUI's
  `Text`/`Button`/`Toggle`/`.help` take a `LocalizedStringKey`, so a literal is
  already a key — pass a `LocalizedStringKey` through a helper rather than a
  `String`, or the call site silently stops being translatable. Everywhere else
  it is `String(localized:)`. Product names (`Claude Code`, `Token Pacer`) are
  never keys.
- Design tokens and the tone rule (green <75, amber 75–90, red >90) live in `DesignSystem/Tokens.swift`. One place, no exceptions.
- Shell dimensions come from the design board and belong in `PillState`, never inline in a view.

## Swift

macOS 15, Swift 6 strict concurrency. The modern spelling is the rule, not a preference.

- `async`/`await` over completion handlers wherever both exist. No `DispatchQueue` and no `asyncAfter` — what is left of it wraps a C callback that takes one.
- Shared mutable state is an `@Observable` class marked `@MainActor`. Never `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`.
- `FormatStyle`, never a `Formatter` subclass: `date.formatted(date: .abbreviated, time: .shortened)`, `Date(text, strategy: .iso8601)`, `count.formatted(.number)`. `Format.swift`'s compact "2.3M" is the exception — no built-in style produces it.
- Swift-native over the Foundation bridge: `replacing(_:with:)`, `URL.homeDirectory.appending(path:)`.
- Static member lookup: `.circle`, `.utility`, `.borderedProminent`.
- No force unwrap and no force `try` under `TokenPacer/`. Tests may force a fixture: a wrong fixture should fail loudly.
- No new package without asking. Sparkle is the only one, vendored at `Vendor/Sparkle`.

## SwiftUI

- `foregroundStyle()`, not `foregroundColor()`. `clipShape(.rect(cornerRadius:))`, not `cornerRadius()`.
- `onChange(of:)` in its two-parameter or zero-parameter form only.
- `Button` for anything clickable; `onTapGesture` only when the location or the click count is the point.
- `Task.sleep(for:)`, never `nanoseconds:`.
- Split a view by adding a `View` struct, never a computed property.
- No `AnyView`. No `GeometryReader` where `visualEffect()` or `containerRelativeFrame()` reaches.
- AppKit belongs to `Notch/`, `App/` and `Services/` — the panel, the status item and login items have no SwiftUI equivalent. Never in a view body.
- Type sizes are fixed points from `Typography`, not Dynamic Type. The shell is a 37 pt row that has to fit; this is the one place the platform default loses.

# Burn Tracker — agent rules

macOS notch usage tracker. See `PLAN.md` for architecture and phases.

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
- `xcodebuild -scheme BurnTracker build|test` — the shipping path (signing, entitlements, Sparkle later).
- Both read the same `Sources/` and `Tests/` folders, so they cannot drift. Adding a file needs no project edit: the Xcode target uses synchronized folder groups.

## Code

- `Sources/Core/` imports Foundation only — no SwiftUI, no AppKit. That constraint is what keeps the engine testable and the usage sources swappable.
- Design tokens and the tone rule (green <75, amber 75–90, red >90) live in `DesignSystem/Tokens.swift`. One place, no exceptions.
- Shell dimensions come from the design board and belong in `PillState`, never inline in a view.

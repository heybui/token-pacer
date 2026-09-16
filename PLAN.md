# Burn Tracker — implementation plan

macOS notch usage tracker. Design source: `design/Burn Tracker.dc.html`.

## 0. Ground truth (verified on this machine, 2026-09-16)

| | Claude Code | Codex |
|---|---|---|
| Logs | `~/.claude/projects/<slug>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Usage record | line `type:"assistant"` → `message.usage` | line `type:"token_usage_record"` → `payload.usage` |
| Fields | `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` | `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens` |
| Dedupe key | `message.id` + `requestId` | `response_id` |
| Context | `cwd`, `sessionId`, `message.model`, `timestamp`, `gitBranch` | `session_meta.payload.cwd`, `model_provider`, `cli_version` |
| **Authoritative limits** | **none found** — must infer | **present**: `payload.rate_limits` = `{primary:{used_percent, window_minutes:300, resets_at}, secondary:{…,window_minutes:10080}, plan_type}` |

Consequences:
- Claude's 5-hour % is **inferred** (ccusage approach) — exactly what the design's `limits` build note already specifies. Show raw tokens until a full window is observed.
- Codex is the *easier* source, not the harder one. `used_percent` / `resets_at` / weekly `secondary` come free. The "future extension" is ~80 lines.
- So the source seam must carry **both** an authoritative and an inferred snapshot origin. That is the one real abstraction in this app; everything else is one implementation.

Toolchain: Xcode 27, Swift 6.4. **Deployment target macOS 15+** (drops availability branches for `@Observable`, `UnevenRoundedRectangle`, modern spring APIs).

## 0.1 Decisions taken

- **Codex ships in phase 1**, not phase 5 — two conformances prove the seam instead of guessing it, and Codex's authoritative `used_percent` is a free correctness check on Claude's inferred one.
- **macOS 15+**.
- **API spend gauge cut entirely** — the card is removed from the pinned panel. No Keychain, no Console admin key, no network. The app is 100% local.
- **Instrument Sans bundled** (OFL) + SF Mono for numerics, matching the design's metrics exactly.

## 1. Architecture

Three layers, one process, no XPC, no daemon.

```
  Host (AppKit)        NotchPanel — one borderless NSPanel, fixed size, pinned to notch
        ↕
  UI (SwiftUI)         PillView / HoverCard / PinnedPanel / Warning  ← @Observable UsageStore
        ↕
  Core (Swift actors)  UsageSource → Engine → UsageSnapshot
```

### 1.1 Host: one fixed window, not a resizing one

The design morphs the shell 226×36 → 404×98 → 752×540 with a spring that overshoots. **Do not animate `NSWindow.setFrame`** — you cannot get spring overshoot out of it and it jitters against the compositor.

Instead: one `NSPanel` sized to the max state (`792 × 580`, includes context-menu drop), permanently. SwiftUI animates the shell *inside* it. To stop the invisible remainder from eating menu-bar clicks, subclass the hosting view:

```swift
final class PassthroughHostingView<V: View>: NSHostingView<V> {
    var liveRect: CGRect = .zero            // published by the shell view via a preference key
    override func hitTest(_ p: NSPoint) -> NSView? {
        liveRect.contains(p) ? super.hitTest(p) : nil
    }
}
```

~15 lines, removes every window-resize animation problem. This is the single decision worth getting right first.

Panel config: `.borderless + .nonactivatingPanel`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `isOpaque = false`, `backgroundColor = .clear`, `hidesOnDeactivate = false`, `isMovable = false`. App is `LSUIElement` (no Dock icon, no main window).

Notch geometry: notch present when `screen.safeAreaInsets.top > 0`; notch width = `screen.frame.width - (auxiliaryTopLeftArea.width + auxiliaryTopRightArea.width)`. Non-notch Macs and external displays: dock to top-centre of the menu bar, same code path. Re-anchor on `NSApplication.didChangeScreenParametersNotification` and on active-screen change.

> Escape hatch: if multi-display re-anchoring turns ugly, swap in `DynamicNotchKit` (MIT). Not a starting dependency — its sizing model would fight the 5-state shell.

### 1.2 Core: sources → engine → snapshot

```swift
protocol UsageSource: Actor {
    var id: SourceID { get }                      // .claude | .codex
    func poll() async throws -> SourceSnapshot    // events since last cursor + optional authoritative limits
}
```

Two conformances, one aggregator. No registry, no DI container.

**Incremental reading is mandatory.** Re-parsing every JSONL every 5s would read hundreds of MB. `JSONLCursor` keeps `(path, inode, offset)`; each poll stats mtime, seeks to offset, decodes only new lines, and drops a cursor whose inode changed (log rotation).

**Engine** (pure, synchronous, fully testable — no I/O, no dates from `Date()`, inject a clock):
- `WindowCalculator` — ccusage block rule: a block starts at the first event after a ≥5h gap, floored to the hour; block spans `[start, start+5h)`.
- `CeilingEstimator` — ceiling = max observed weighted-token total across completed windows, persisted. Below one observed window → `.unknown`, UI shows raw tokens (`1.24M`).
- `BurnRate` — weighted tokens/hour over a trailing 30 min → headroom minutes.
- `Aggregator` — folds events into **5-minute buckets** keyed by `(source, model, project, surface)`. 30 days ≈ 8.6k buckets; the sparkline, splits and history all read buckets, never raw events. Persist buckets as JSON in Application Support; never persist raw events. No SQLite.

Output is one value type the whole UI binds to:

```swift
struct UsageSnapshot {
    enum Origin { case authoritative, inferred, unknown }   // Codex vs Claude
    var origin: Origin
    var sessionPct: Double?, sessionTokens: Int, resetsAt: Date
    var weeklyPct: Double?, weeklyResetsAt: Date
    var burnRatePerHour: Double, headroomMinutes: Int
    var sparkline: [Double]          // 26 buckets, matches the design
    var splits: Splits               // by model / project / surface
    var history: [DayUsage]          // 30 days
}
```

Weighted tokens: one `TokenWeights` struct (output ×5, cache-write ×1.25, cache-read ×0.1 — ccusage's ratios), per-model overrides in a plist. Calibration knob, not a constant buried in code — the real ratios drift with pricing.

### 1.3 UI: one view tree, state enum drives size

`PillState` enum mirrors the design exactly: `dormant, ghost, collapsed, hover, warning, exhausted, paused, pinned`. Derived from `(snapshot, pointerInside, isPinned, warnAcknowledged, trackingPaused)` in one function — no scattered booleans.

Shell sizes and radii lifted verbatim from the design:

| State | W × H | radius |
|---|---|---|
| dormant | 226 × 3 | 6 |
| ghost / collapsed / exhausted / paused | 226 × 36 | 13 |
| hover / warning | 404 × 98 | 26 |
| pinned | 752 × 540 | 26 |

Animation: `.interpolatingSpring(stiffness: 220, damping: 24)`, per build note. Reduce Motion deliberately ignored for the shell morph (design decision — but keep it honoured for the pulsing dot, which is a real accessibility nuisance, not the product).

Components worth owning (everything else is stock SwiftUI):
- `OdometerText` — digit strips translated by `-d em`, spring transition + brief blur. Used at 5 sizes (11/11.5/12/26/30px).
- `UsageRing` — `Circle().trim(to: pct).stroke(tone, lineWidth:)` rotated −90°, not an AngularGradient. Crisper, cheaper.
- `CapBar`, `Sparkline`, `SplitRow`, `HistoryRow` (monospace `█`/`░` blocks, as designed).

Tokens (`DesignSystem/Tokens.swift`): `green #3ec98a`, `amber #e8b33c`, `red #e2543f`, `blue #5aa9d6`, shell `#000`, thresholds 75 / 90. One `tone(for:)` function — the design applies the same rule to session, weekly and API bars; it must exist in exactly one place.

Font: design uses Instrument Sans (OFL). Bundle it to match pixel-for-pixel; SF Mono for all numerics.

## 2. Scaffold

**One Xcode target, folders only.** No SPM multi-module split until build times actually hurt — the layering below is enforced by import discipline and tests, not by module boundaries.

Two build systems over one set of folders:
- `BurnTracker.xcodeproj` — the shipping path (Info.plist, entitlements, hardened runtime, signing, Sparkle in phase 6). Uses Xcode 16+ **synchronized folder groups**, so `Sources/` and `Tests/` are picked up wholesale and new files never need registering.
- `Package.swift` — fast terminal loop (`swift build` ≈ 1.5s, `swift test`).

Neither carries a file list, so they cannot drift.

```
BurnTracker.xcodeproj     synchronized groups → Sources/, Tests/
Package.swift             same folders, CLI loop
Sources/
  App/                 BurnTrackerApp.swift · AppDelegate.swift · Composition.swift
  Notch/               NotchPanel.swift · NotchAnchor.swift · PassthroughHostingView.swift · ScreenObserver.swift
  Features/
    Pill/              PillView.swift · PillState.swift
    HoverCard/         HoverCardView.swift
    Panel/             PinnedPanelView.swift · WeeklyCapSection.swift · BurnSparklineSection.swift
                       SplitsSection.swift · HistorySection.swift
    Warning/           WarningView.swift · WarningPolicy.swift
    ContextMenu/       NotchContextMenu.swift
    Preferences/       PreferencesWindow.swift · PreferencesView.swift
  Core/
    Model/             UsageEvent.swift · UsageBucket.swift · UsageSnapshot.swift · SourceID.swift
    Ingest/            UsageSource.swift · ClaudeCodeSource.swift · CodexSource.swift · JSONLReader.swift
    Engine/            WindowCalculator.swift · CeilingEstimator.swift · BurnRate.swift · Aggregator.swift · TokenWeights.swift
    Store/             UsageStore.swift · BucketArchive.swift
    Services/          Notifier.swift · LaunchAtLogin.swift · Preferences.swift · FullScreenDetector.swift
  DesignSystem/        Tokens.swift · OdometerText.swift · UsageRing.swift · CapBar.swift · Sparkline.swift
Resources/             Assets.xcassets · InstrumentSans/ · Info.plist · BurnTracker.entitlements
Tests/
  Fixtures/            claude-session.jsonl · codex-rollout.jsonl (trimmed real logs)
  EngineTests.swift · SourceTests.swift · PillStateTests.swift
```

Rule that keeps it honest: `Core/` imports Foundation only — no SwiftUI, no AppKit. That single constraint is what makes the engine testable and the Codex source a drop-in.

## 3. Phases

| # | Deliverable | Why this order |
|---|---|---|
| 0 | Xcode project, `LSUIElement`, empty black pill pinned to the notch, survives display change / full-screen / space switch | Hardest unknown first. If notch anchoring is wrong, everything else is wasted. |
| 1 | ✅ `JSONLReader` + **both** sources + engine + 29 tests on sanitised real fixtures. `--probe` prints a % per source. | Data correctness before pixels; two sources validated the seam. |
| 2 | Design system + `dormant / ghost / collapsed / exhausted / paused` + spring morph | Ships something usable. |
| 3 | Hover card, warning auto-expand, pinned panel, context menu | The rest of the design surface. |
| 4 | Preferences, notifications (full-screen fallback only), launch at login, pause-survives-relaunch | Product polish. |
| 5 | Source switcher in the pill + prefs (Claude / Codex / combined) | Sources already exist; this is just presentation. |
| 6 | Notarized DMG, Sparkle feed, Homebrew cask, MIT licence | Ship. |

Phase 0 + 1 are the risk. 2–6 are execution.

## 4. Deliberate simplifications

- 5s polling timer, not FSEvents — a 5-hour window does not need sub-second freshness, and a watcher on `~/.claude/projects` fires constantly.
- 5-minute buckets, not raw event persistence — caps disk and memory regardless of usage volume.
- Full-screen detection by menu-bar visibility (`screen.visibleFrame.maxY == screen.frame.maxY`) rather than window enumeration — no Screen Recording permission needed. `ponytail:` heuristic; upgrade to `CGWindowListCopyWindowInfo` only if it misfires.
- No network, no credentials, no Keychain — the app only ever reads local files. (API spend gauge cut.)

## 4.1 Measured on real logs (2026-09-16)

`--probe` against this machine: Claude 10,618 events / 49 completed windows, Codex 4,315 events / 23 windows.

- **Cold start reads 707MB** (309MB `~/.claude` + 398MB `~/.codex`) in ~8s at 100% CPU. It is I/O bound, not decode bound — adding a byte prefilter before `JSONDecoder` changed nothing. Incremental polls after that are nearly free, since cursors only read appended bytes. **The fix is persistence, not parsing:** `BucketArchive` in phase 3 must save cursors *and* aggregates so a relaunch never re-reads history. Until then, the first snapshot lands ~8s after launch and the pill must show a loading state rather than a fake 0%.
- **Outliers dominate the inferred ceiling.** Max-observed put Claude's ceiling at 32.4M weighted tokens, so a normal window reads ~4%. One unusually heavy day permanently flattens every later reading. Candidate fixes: a high percentile (p95) of completed windows instead of the max, or the max of the trailing N windows so the ceiling can decay. Needs a decision before the percentage is trustworthy.

## 5. Standing risks

1. **Undocumented log formats.** Both `~/.claude` and `~/.codex` schemas are private and unversioned; a CLI update can rename a field and the tracker silently reads zero. Mitigation: decode defensively, and when a source yields no parseable usage record in a window where the CLI *is* running, show an explicit `no data` pill state — never a confident `0%`.
2. **Claude's percentage is an estimate.** Until a full 5-hour window is observed the ceiling is unknown; the UI shows raw tokens (`1.24M`), not a percentage, and only switches to `%` once confident. Codex's authoritative number is the calibration reference — if the two diverge wildly on similar usage, the weights in `TokenWeights` are wrong, not the engine.
3. **Bundle id** `com.redevify.tokenburn` vs product name "Burn Tracker" — kept as-is from the design's ship note; say the word if you want them aligned.

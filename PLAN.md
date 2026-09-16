# Burn Tracker — implementation plan

macOS notch usage tracker. Design source: `design/Burn Tracker.dc.html`.

## 0. Ground truth (corrected 2026-09-16)

### Limits come from an API, not the logs

Claude Code reads its own usage from an authenticated endpoint. This is the source of truth for every percentage; the earlier plan inferred a ceiling from log volume because this endpoint had not been found, which was wrong.

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>      # Keychain service "Claude Code-credentials" → claudeAiOauth.accessToken
anthropic-beta: oauth-2025-04-20
```

Response (verbatim from Claude Code's `src/services/api/usage.ts`):

```ts
type RateLimit = { utilization: number | null,  // percentage 0–100
                   resets_at:   string | null } // ISO 8601
type Utilization = {
  five_hour?, seven_day?, seven_day_oauth_apps?, seven_day_opus?, seven_day_sonnet?,
  extra_usage?: { is_enabled, monthly_limit, used_credits, utilization }
}
```

Gating: returns `{}` unless the session is a managed OAuth subscriber holding the `user:profile` scope. API-key users get nothing, so the log-derived fallback still has to exist.

**Keychain access is a user-visible cost.** The item belongs to Claude Code, so macOS prompts the
first time Burn Tracker reads it — *"BurnTracker wants to use the 'Claude Code-credentials' keychain
item"* — and the ACL is keyed to the code signature. Consequences:

- **Ad-hoc signing re-prompts on every rebuild.** During development that is constant. A stable
  Developer ID makes it a single "Always Allow".
- **No file fallback on macOS.** `~/.claude/.credentials.json` does not exist here; the Keychain is
  the only source. The file path is still read for installs that have one.
- **Denial must not be terminal.** A denied prompt, a missing sign-in and an expired token all
  resolve without any action from this app, so they back off rather than disabling live limits.
  Only `403` — a scope or plan refusal — stops us asking for good.
- **The token is read, never refreshed.** The blob carries a refresh token, but spending it rotates
  the pair and could sign Claude Code itself out. When the token is expired we wait for Claude Code
  to renew it.
- Worth evaluating: `claude setup-token` mints a long-lived token intended for external tooling,
  which would sidestep the Keychain prompt entirely — if it is accepted by this endpoint.

Codex needs no network at all — its rollout logs already carry `rate_limits` with `used_percent`, `window_minutes` and `resets_at`.

### Network policy — the endpoint is undocumented, treat it as a guest

The 5s tick stays **local only**. Log reading is free; the network call is not, and hammering an
undocumented endpoint is how an account or IP earns a block. Rules, enforced in one place:

1. **Activity-gated.** A call is only made when local logs show new token events since the last one.
   Utilization cannot move without them. An idle machine makes **zero** requests.
2. **Hard floor of 10 minutes between routine calls**, with jitter so installs don't synchronise.
   A heavy 8-hour day is ≤48 calls; an idle day is 0. Threshold confirmations may jump the queue on
   a 2-minute floor — set `confirmFloor = floor` to make every call strictly 10 minutes apart.
3. **Anchor + interpolate.** The API result is an anchor: utilization *u* at time *T*. Between calls
   the pill extrapolates from local weighted-token deltas since *T*, so it still moves every 5s
   while the network is touched at most once per 10 minutes.

   Consecutive anchors also *calibrate* the conversion — the quantity `CeilingEstimator` could only
   guess at:

   ```
   anchor A: 11%  ──  W weighted tokens logged locally  ──  anchor B: 15%
                      ⇒ weightedPerPercent = W / (15 − 11)
   ```

   Pairs that span a reset, or that saw no local tokens, teach nothing and are discarded. Accuracy
   between anchors is bounded by usage this machine cannot see — other devices, claude.ai, the web
   app — which the next anchor corrects.
4. **A reset costs no request.** `resets_at` is already known and the extrapolation restarts from
   zero on its own, so an idle machine stays silent straight through a rollover.
5. **Backoff by status.** 429/5xx → exponential backoff with jitter, honouring `Retry-After`.
   401 → stop and fall back to inference (a token problem; retrying cannot fix it).
   403 → stop for the session, do not retry.
6. **One in-flight request**, coalesced. No concurrency, no retry storms.
7. **Sleep-aware.** No polling while the display is asleep; one fetch on wake.
8. **Serve stale on failure** with an age indicator. Never spin trying to refresh.

Failure is never fatal: `CeilingEstimator` remains the fallback, so the app degrades to log-only
rather than breaking. The live source is a Preferences toggle (default on) so it can be turned off
outright.

Standing caveat: this endpoint is community-discovered, not a published API. It may change or be
restricted without notice. The requests are the user's own token against the same endpoint their own
client calls, which is the defensible position — but the fallback path is what makes it safe to ship.

### What each layer is actually for

| Value | Source |
|---|---|
| 5-hour %, 7-day %, per-model weekly %, reset times | **Claude: OAuth usage endpoint. Codex: rollout logs.** |
| Monthly credit spend | `extra_usage` — free, no Console admin key |
| Burn rate, sparkline, headroom | Log token counts (the API gives no rate of change) |
| Splits by model / project / surface | Log token counts (the API gives no attribution) |
| 30-day history | Log token counts |
| Fallback % for API-key users | `CeilingEstimator` over observed windows |

So log parsing stays — it answers everything the endpoint cannot — but it stops being the source of the headline number.

### Log formats (verified on this machine)

| | Claude Code | Codex |
|---|---|---|
| Logs | `~/.claude/projects/<slug>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Usage record | `type:"assistant"` → `message.usage` | `type:"token_usage_record"` → `payload.usage` |
| Fields | `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` | `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens` |
| Dedupe key | `message.id` + `requestId` | `response_id` |
| Context | `cwd`, `sessionId`, `message.model`, `timestamp` | `session_meta.payload.cwd`, `turn_context.cwd` |
| Nesting trap | cache counts are **separate from** `input_tokens` | `cached_input_tokens` is **inside** `input_tokens`; `reasoning_output_tokens` is inside `output_tokens` |

Toolchain: Xcode 27, Swift 6.4. **Deployment target macOS 15+**.

## 0.1 Decisions taken

- **Codex ships in phase 1**, not phase 5 — two conformances prove the seam instead of guessing it, and Codex's authoritative `used_percent` is a free correctness check on Claude's inferred one.
- **macOS 15+**.
- **API spend gauge**: cut as a *Console Admin API* feature, but `extra_usage` on the OAuth endpoint returns monthly credit spend for free. Revisit — it now costs nothing.
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

| # | Deliverable | Status |
|---|---|---|
| 0 | Notch panel: borderless `NSPanel`, `LSUIElement`, click passthrough, re-anchoring | ✅ done |
| 1 | `JSONLReader` + both sources + window/ceiling/burn engine, `--probe` | ✅ done |
| 1.5 | **Live limits** — OAuth usage endpoint, Keychain, calibration, 10-min activity-gated polling, attention badge, single-instance guard | ✅ done (unplanned; see §0) |
| 2 | Design system + the remaining pill states + spring morph | 🔨 **in progress** |
| 3 | Warning auto-expand, pinned panel, context menu | ⬜ not started |
| 4 | Preferences, notifications, launch at login, pause-survives-relaunch | ⬜ not started |
| 5 | Source switcher in the pill + prefs (Claude / Codex / combined) | ⬜ not started |
| 6 | Notarized DMG, Sparkle feed, Homebrew cask | ⬜ not started |

Phase 1.5 was not in the original plan. It exists because the limits source was wrong: the first
version inferred a ceiling from log volume, and the endpoint that publishes the real figures was
found later. It absorbed most of the time since phase 1.

### What phase 2 still needs

Two of eight states render distinctly today — `collapsed` and `hover`. Everything else falls through
to `collapsed`.

- **States**: `dormant`, `ghost`, `exhausted`, `paused` (`warning` and `pinned` are phase 3).
- **`OdometerText`** — digit strips with the roll and blur, used at five sizes. The single most
  visible missing piece; every figure is plain text today.
- **Instrument Sans** — decided, not bundled. The pill is on the system font, so metrics differ from
  the design at 11–13px.
- **`CapBar`** — the weekly bar. It now has a real data source (`seven_day`), which it did not when
  phase 2 was written.
- **Pulsing activity dot** — static today; the design pulses it at 2.6s.
- **Reduce Motion** — honoured for the dot, deliberately ignored for the shell morph.

### Verified on hardware

- Live endpoint request succeeds; hover reads `reported`, matching Claude Code's own `/usage` panel.
- Single instance enforced, including a raw binary launched past LaunchServices.
- Shadow follows the clipped shape; headroom no longer outlasts its window.

### Still unverified

- **Notch hardware.** Every run so far has been on an external display with no notch, so the
  no-notch fallback is what has been exercised. The notch path has unit tests only.
- **Menu-bar click passthrough** and full-screen / space-switch behaviour.
- **Calibration over time** — `weightedPerPercent` needs two anchors 10 minutes apart; no session has
  yet been observed running long enough to confirm the figure it settles on.

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

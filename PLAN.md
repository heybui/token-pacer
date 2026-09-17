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

- **Ad-hoc signing re-prompts on every rebuild** — the ACL is keyed to the designated
  requirement, and an ad-hoc one is `cdhash H"…"`, a fresh identity every build. `make app` now
  signs with the first identity `security find-identity -p codesigning` reports, so the requirement
  is the stable `certificate leaf[subject.CN]` form and "Always Allow" survives rebuilds. The
  prompt returns once when the identity itself changes. `make app SIGN=-` goes back to ad-hoc.
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
- **API spend gauge**: cut as a *Console Admin API* feature, then restored — `extra_usage` on the
  OAuth endpoint carries monthly credit spend for free. The panel draws it only when the account has
  extra usage enabled.
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
- `BurnTracker.xcodeproj` — the shipping path (Info.plist, entitlements, hardened runtime, signing, Sparkle in phase 6). Uses Xcode 16+ **synchronized folder groups**, so `BurnTracker/` and `Tests/` are picked up wholesale and new files never need registering.
- `Package.swift` — fast terminal loop (`swift build` ≈ 1.5s, `swift test`).

Neither carries a file list, so they cannot drift.

```
BurnTracker.xcodeproj     synchronized groups → BurnTracker/, Tests/
Package.swift             same folders, CLI loop
BurnTracker/               the target's sources; named for it, not "Sources"
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
| 2 | Design system + the remaining pill states + spring morph | ✅ done |
| 3 | Warning auto-expand, pinned panel, context menu | ✅ done |
| 4 | Preferences, notifications, launch at login, pause-survives-relaunch | ✅ done |
| 5 | Source switcher in the pill + prefs (Claude / Codex / combined) | ⬜ not started |
| 6 | Notarized DMG, Sparkle feed, Homebrew cask | 🔨 pipeline built; blocked on a Developer ID certificate |

Phase 1.5 was not in the original plan. It exists because the limits source was wrong: the first
version inferred a ceiling from log volume, and the endpoint that publishes the real figures was
found later. It absorbed most of the time since phase 1.

### Carried out of phase 3

- **⌘⇧B — cut.** The design's global shortcut for the panel. A system-wide hotkey
  needs a Carbon registration (the `NSEvent` route would demand Accessibility
  permission for one shortcut), and the pill is a click away. Out of scope by
  decision, not by oversight; the row is gone from Preferences with it.
- ~~**Nothing survives a relaunch.**~~ ✅ fixed: one archive, two files — `state.json` for the
  limits state, `events.json` for events and cursors. What it closed:
  - Calibration accumulates across launches, so `weightedPerPercent` is finally
    reachable — `samples=0` on every earlier run was the tracker restarting, not
    the calibration failing.
  - The 10-minute floor survives, so a relaunch no longer jumps the queue.
  - Pause survives.
  - The cold start: 4171ms → 305ms (§4.1).
  - It also uncovered a latent bug worth remembering: a cold start replays every
    retained event, and counting that as "usage since the anchor"
    (`weighted=527694804` in the log) would have taught calibration a conversion
    out by orders of magnitude the moment two anchors survived together. Only
    events newer than the anchor count, and the running total is deliberately
    not archived.
- **By surface** — the design's third split. Nothing local can tell claude.ai from
  the web app, so it splits by CLI instead; revisit if the endpoint ever says.
- **History is relative.** The grid shades each day against the busiest in range;
  there is no daily cap to be a percentage of. Worth revisiting if the endpoint
  ever publishes one.

### Carried out of phase 4

- **Preferences shipped** with four rows: the alert scale, sound on threshold,
  launch at login (`SMAppService.mainApp`), and hide-when-dormant. Alerts fire
  through `AlertPolicy` → `UNUserNotificationCenter`, and only when the notch is
  hidden — a full-screen app or another space — because a pill already showing
  93% does not need to be told.
- **One scale, two handles.** The design's two sliders became a single 0–100
  track with a warn handle and a critical one, clamped so warn can never pass
  critical. Reset restores that scale and nothing else; the other rows are
  preferences, not a configuration to be undone.
- **Three deltas against the design board**, chosen from a scan: the ring pops on
  a threshold crossing, the ghost fades rather than cuts, and zero headroom reads
  red. A silent return to dormant was offered and declined.
- **A light runs the shell's border** while tokens flow — not in the design, asked
  for on top of it. Tone follows the alert scale; the pinned panel is exempt,
  since a 752×540 sheet with a light running round it is a screensaver.
- **The app icon is bundled** and the Xcode target carries it explicitly, as
  synchronized folder groups do not pick up a Resources phase entry.

### Phase 6 — cutting a release

```
make dmg        # build, sign for distribution, stage a drag-to-Applications image
make notarize   # submit to Apple, staple the ticket, assess it
make appcast    # sign the update with the EdDSA key, write build/appcast.xml
make cask       # print the tap formula with the image's real checksum
```

Then upload `BurnTracker-<version>.dmg` **and `appcast.xml`** to a GitHub release
tagged `v<version>`, and put the cask in a tap.

One-time setup, in order:

1. **A Developer ID Application certificate.** The paid Developer Program; this
   machine has only an Apple Development certificate, which cannot be notarized
   and which Gatekeeper refuses on any other Mac. `make check-devid` says so.
2. `xcrun notarytool store-credentials burn-tracker` — Apple ID, team, and an
   app-specific password. Silent thereafter.
3. ~~Sparkle's EdDSA key pair~~ ✅ generated. The public half is in `Info.plist`;
   the private half is in the login Keychain as *Private key for signing Sparkle
   updates*. **It is not in this repo and cannot be recovered.** Lose it and no
   installed copy can ever be updated again — back it up with
   `generate_keys -x` before the first release.

Signing the first release also resets the Keychain grant on Claude Code's
credentials once, because the designated requirement changes with the identity.

### Standing design decisions

- **Reduce Motion** — deliberately not honoured, for the activity dot or the shell morph.
- **Sparkle ships alongside the cask, not instead of it.** `brew upgrade` covers people who install
  through the tap; the feed covers people who download the DMG. Gentle reminders are implemented
  because this app has no Dock icon and no menu bar — Sparkle's own panel would arrive from nowhere,
  so a scheduled find speaks through the threshold banner and only a check the user asked for opens
  the panel.
- **The bundle id stays `com.redevify.tokenburn`.** Decided at the last moment it was free to change:
  after a public release it is what every install, preference file and Keychain grant is keyed to.
- **Instrument Sans is bundled** and registered twice over (`ATSApplicationFontsPath` for the bundle,
  `CTFontManagerRegisterFontsForURL` for `swift run`). Availability decides whether it is used, never
  the registration return value — a silent fallback to the system face is how a design drifts.
- **The activity dot follows the turn**, not the open window and not logged tokens alone. A usage
  record lands only when an exchange *completes*, so the stretch that most wants a signal — a long
  think, or a five-minute build under a tool call — logs nothing at all. Nothing on disk says an
  agent is working: `~/.claude/ide/*.lock` and the `claude` process both outlive a turn by hours.
  The live signal is the newest *conversational* line, read back past the bookkeeping that makes up
  two thirds of a session log (`ai-title`, `mode`, `attachment`, `queue-operation`): a `user` line
  awaiting an answer, or an `assistant` line whose `stop_reason` is `tool_use`, means work is
  happening. 735 of 792 assistant lines in a real session are the model stopping for a tool, so
  reading "assistant" as "finished" was wrong most of the time. Capped at 15 minutes, so a CLI
  killed mid-turn does not pulse all day; a 12s quiet window (two polls) covers the rest.
- **Headroom is only projected four sample-lengths ahead.** A rate measured over thirty minutes told
  a live machine it had 269 minutes left at 0.3% used. It fitted inside the window, which was the
  only guard there was. Past the horizon there is no figure, and the countdown speaks instead.

### Verified on hardware

- Live endpoint request succeeds; hover reads `reported`, matching Claude Code's own `/usage` panel.
- Single instance enforced, including a raw binary launched past LaunchServices.
- Shadow follows the clipped shape; headroom no longer outlasts its window.
- Collapsed pill and hover card, on screen, against live figures.
- Context menu on right-click — and the reason it first rendered white-on-white: `.regularMaterial`
  follows the desktop appearance. Nothing in this app may track the system scheme.
- `make app` signs with a real identity, so the Keychain grant survives a rebuild.
- Preferences, the dual-handle alert scale and the reset, on screen.
- The border chase, and the two bugs behind it: a gradient stroke fades by position in the *view*,
  so the light vanished down the left and right edges; and animating a `phase` from 0 to 1 animates
  the trim bounds it produces, where 0 and 1 wrap to the same point — so every arc interpolated from
  where it was to where it already was and the light sat perfectly still. It is driven by the clock
  now, and measured in points so it looks the same on the pill and on the card.
- The pinned panel and its context menu, on screen, against live figures.
- Four bugs only the hardware could show: the host clipped the shell's shadow; the shadow reverted
  to a bounding box because a ScrollView cannot be rasterised into a compositing group; `.onHover`
  installed a tracking area over the whole host, which ignores the hitTest that makes the rest
  click-through, so most of the upper screen expanded the pill; and spend read minor units as whole
  currency — S$11.99 shown as $1199.

### Still unverified

- **Notch hardware.** Every run so far has been on an external display with no notch, so the
  no-notch fallback is what has been exercised. The notch path has unit tests only.
- **Menu-bar click passthrough** and full-screen / space-switch behaviour.
- ~~**Calibration over time**~~ ✅ measured. Persistence was the blocker: `perPercent=0 samples=0`
  on every earlier run was the tracker restarting, not the calibration failing. The probe now reads
  a conversion near 190k weighted a point against an inferred ceiling of 324k — so the ceiling is
  roughly 70% too high, which is §4.1's outlier problem quantified rather than argued. Calibration
  already wins wherever both exist; the ceiling still decides for API-key users.
- **The warning state on screen** — it needs a window past 90% to appear, which no run has reached.
  Every other state has now been seen, and with it the ring pop, which shares the crossing.

## 4. Deliberate simplifications

- 5s polling timer, not FSEvents — a 5-hour window does not need sub-second freshness, and a watcher on `~/.claude/projects` fires constantly.
- 5-minute buckets, not raw event persistence — caps disk and memory regardless of usage volume.
- Full-screen detection by menu-bar visibility (`screen.visibleFrame.maxY == screen.frame.maxY`) rather than window enumeration — no Screen Recording permission needed. `ponytail:` heuristic; upgrade to `CGWindowListCopyWindowInfo` only if it misfires.
- ~~No network, no credentials, no Keychain~~ — overtaken by phase 1.5. The app reads the OAuth usage
  endpoint with the user's own token, read-only, activity-gated, with a 10-minute floor. It still
  degrades to log-only inference when that fails.
- The panel aggregates straight from the 30 days of events the store already holds, rather than the
  planned persisted 5-minute buckets. Cheap per refresh, and it leaves the cold start unfixed —
  `BucketArchive` is still the answer to §4.1, not a second copy of the buckets.

## 4.1 Measured on real logs (2026-09-16)

`--probe` against this machine: Claude 10,618 events / 49 completed windows, Codex 4,315 events / 23 windows.

- ~~**Cold start reads 707MB**~~ ✅ fixed in phase 4. It was I/O bound, not decode bound — a byte
  prefilter before `JSONDecoder` changed nothing — so the fix was persistence, not parsing. The
  archive keeps the events *and* each file's byte offset, so only appended bytes are read.
  Measured on this machine, 714MB across 544 files: **4171ms over 17,354 events → 305ms**, of which
  114ms is reading the 4.5MB archive. Raw events rather than the planned buckets, so windows, burn
  rate, splits and the ceiling keep their exact fidelity and nothing downstream changed.
  The loading state stays: the first read is still not instant, and a fake 0% would still be a lie.
- **Outliers dominate the inferred ceiling.** Max-observed put Claude's ceiling at 32.4M weighted tokens, so a normal window reads ~4%. One unusually heavy day permanently flattens every later reading. Candidate fixes: a high percentile (p95) of completed windows instead of the max, or the max of the trailing N windows so the ceiling can decay. Needs a decision before the percentage is trustworthy.

## 5. Standing risks

1. **Undocumented log formats.** Both `~/.claude` and `~/.codex` schemas are private and unversioned; a CLI update can rename a field and the tracker silently reads zero. Mitigation: decode defensively, and when a source yields no parseable usage record in a window where the CLI *is* running, show an explicit `no data` pill state — never a confident `0%`.
2. **Claude's percentage is an estimate.** Until a full 5-hour window is observed the ceiling is unknown; the UI shows raw tokens (`1.24M`), not a percentage, and only switches to `%` once confident. Codex's authoritative number is the calibration reference — if the two diverge wildly on similar usage, the weights in `TokenWeights` are wrong, not the engine.
3. ~~**Bundle id**~~ — settled: `com.redevify.tokenburn` stays, product name notwithstanding.
4. **The Sparkle private key is a single point of failure.** It lives only in the login Keychain of
   this machine. No backup means no future update for anyone already installed — not a bug that can
   be fixed later, so back it up before the first release, not after.

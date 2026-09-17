# Token Pacer — implementation plan

macOS notch usage tracker. Design source: `design/Token Pacer.dc.html`.

## 0. Ground truth (corrected 2026-09-16)

### Limits come from the CLI's own `/usage` panel

Claude Code reads its own usage from an authenticated endpoint. This app does not
call it. It drives the CLI through a pseudo-terminal, types `/usage`, and reads the
panel the CLI draws — which is that endpoint's response, already fetched and
rendered by the one client that legitimately holds the credentials.

```
openpty → posix_spawn(claude, POSIX_SPAWN_SETSID) → wait for the screen to go quiet
        → write "/usage\r" → read until "Resets" and the screen settles → kill the group
```

Measured on this machine: **~4s per run, 4.2KB of terminal output, $0.0000** — a
`/usage` run makes no model call. `ClaudeCLI` owns the pty; `ClaudeUsagePanel` owns
the parsing and imports Foundation only, so the hard part is testable without
spawning anything.

**What this buys.** No Keychain prompt, no token of our own, no `setup-token` step,
nothing of Claude Code's to keep in sync, and no undocumented endpoint to be a good
guest at — the CLI makes that call on its own terms, with its own caching.

**What it costs, stated plainly:**

- **Whole percentages.** The panel prints `7%`, never `7.3%`. Everything that needed
  a fraction of a point is gone with it — see below.
- **No typed failures.** 401, 403 and 429 were three different decisions; through a
  terminal they are one absent regex match. What survives is what is visible from
  outside the process: no binary, no trusted directory, a timeout, a login prompt,
  an unparseable screen. Only the first two are fatal.
- **A UI is the contract.** Claude Code ships weekly and the panel has no
  compatibility promise. Two real quirks are already handled: the CLI positions the
  cursor instead of emitting padding, so stripping escapes welds `Current session`
  into `Currentsession` and `Resets Sep 22 at 1am` into `ResetsSep22at1am` — every
  pattern treats whitespace as optional and re-spaces stamps on letter/digit
  boundaries. `PanelTests` pins both shapes against a captured render.
- **Cached first, fresh second.** The panel paints a cached figure, then repaints
  when the refresh lands, and nothing in the output says which is which. The reader
  waits for the screen to stop changing and the parser takes the *last* match.
- **An untrusted directory blocks it.** The CLI draws "is this a project you trust?"
  instead of the panel, so the working directory is taken from the first project in
  `~/.claude.json` with `hasTrustDialogAccepted`.
- **A GUI app has no PATH.** launchd gives it `/usr/bin:/bin:/usr/sbin:/sbin`, so the
  binary is found by looking in the known install locations, or `TOKENPACER_CLAUDE_BIN`.

### What whole percentages cost: calibration is gone

The previous design anchored on a float from the endpoint and interpolated between
anchors from local token deltas, calibrating the conversion from consecutive pairs:

```
anchor A: 11%  ──  W weighted tokens logged locally  ──  anchor B: 15%
                   ⇒ weightedPerPercent = W / (15 − 11)
```

That cannot survive rounding. At a 5-minute cadence the true delta is routinely
under one point, so the rounded delta is `0`, every pair is discarded, and the
conversion is never measured. `LimitsCalibration`, `LimitsRefreshPolicy` and
`LiveLimitsTracker` are deleted rather than kept limping — a calibration fed
rounded inputs is not a degraded measurement, it is a fabricated one.

So the pill now shows the **last reading**, unmoved between runs, and `PanelPoller`
keeps that honest: it refuses to run without local token activity, which is exactly
when a frozen number is the correct one. The one thing inferred without a reading is
a reset — the window is simply empty, no conversion required.

`BurnRate` loses its calibrated input and falls back to `ceiling.weightedTokens / 100`
from `CeilingEstimator`, which is the path API-key users were always on.

### Cadence

Five minutes, activity-gated, exponential backoff to an hour on failure, persisted
across launches. There is no network etiquette left to enforce — the constraint is
local: each run boots a whole Claude Code process for four seconds, which is far too
much to spend on a machine nobody is typing at. An idle machine spawns nothing.

Codex needs none of this — its rollout logs already carry `rate_limits` with
`used_percent`, `window_minutes` and `resets_at`.

### What each layer is actually for

| Value | Source |
|---|---|
| 5-hour %, 7-day %, reset times | **Claude: the CLI's `/usage` panel, to the whole percent. Codex: rollout logs.** |
| Monthly credit spend | the panel's `Usage credits` row — free, no Console admin key |
| Burn rate, sparkline, headroom | Log token counts (the API gives no rate of change) |
| Splits by model / project / surface | Log token counts (the API gives no attribution) |
| 30-day history | Log token counts |
| Fallback % when the CLI cannot be read | `CeilingEstimator` over observed windows |

So log parsing stays — it answers everything the panel cannot — but it stops being the source of the headline number.

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
- **API spend gauge**: cut as a *Console Admin API* feature, then restored — the `Usage credits` row
  of the CLI's own panel carries monthly credit spend for free, currency symbol and all. Drawn only
  when the account has extra usage enabled.
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
- `TokenPacer.xcodeproj` — the shipping path (Info.plist, entitlements, hardened runtime, signing, Sparkle in phase 6). Uses Xcode 16+ **synchronized folder groups**, so `TokenPacer/` and `Tests/` are picked up wholesale and new files never need registering.
- `Package.swift` — fast terminal loop (`swift build` ≈ 1.5s, `swift test`).

Neither carries a file list, so they cannot drift.

```
TokenPacer.xcodeproj     synchronized groups → TokenPacer/, TokenPacerTests/
Package.swift             same folders, CLI loop
TokenPacer/              the target's sources, named for it rather than "Sources"
  Info.plist              build inputs, not bundle resources: the synchronized
  TokenPacer.entitlements  group carries a membership exception for both
  Resources/              InstrumentSans.ttf · TokenPacer.icns
  App/                    main.swift · AppDelegate.swift · Probe.swift
  Notch/                  NotchPanel.swift · NotchController.swift · NotchAnchor.swift
                          PassthroughHostingView.swift
  Features/
    Pill/                 PillView.swift · PillState.swift · PillStateResolver.swift
                          PillModel.swift · PillRootView.swift
    Panel/                PinnedPanelView.swift
    Menu/                 NotchMenuView.swift · UsageClipboard.swift
    Preferences/          PreferencesWindow.swift · PreferencesView.swift
  Core/
    Model/                UsageEvent.swift · UsageSnapshot.swift · TokenCounts.swift · SourceID.swift
    Ingest/               UsageSource.swift · ClaudeCodeSource.swift · CodexSource.swift
                          ClaudeUsagePanel.swift · JSONLReader.swift
    Engine/               WindowCalculator.swift · CeilingEstimator.swift · BurnRate.swift
                          Aggregator.swift · TokenWeights.swift · AlertPolicy.swift
                          PanelPoller.swift
    Store/                UsageStore.swift · Archive.swift
    Log.swift
  Services/               ClaudeCLI.swift · Notifier.swift · LaunchAtLogin.swift
                          Preferences.swift · SingleInstance.swift · Updater.swift
  DesignSystem/           Tokens.swift · ToneScale.swift · Typography.swift · Format.swift
                          OdometerText.swift · UsageRing.swift · CapBar.swift
                          PulsingDot.swift · ChasingBorder.swift · AttentionBadge.swift
TokenPacerTests/
  Fixtures/               claude-session.jsonl · codex-rollout.jsonl (trimmed real logs)
  EngineTests.swift · SourceTests.swift · PillStateTests.swift · ArchiveTests.swift · …
```

No `Resources/` at the repo root and no file lists anywhere: everything the app
ships lives under `TokenPacer/`, and the synchronized group registers it. Adding
a font or an icon needs no project edit. `Info.plist` and the entitlements sit
beside it as build-setting inputs, excluded from the group's membership so they
are not also copied in as resources, and from SPM's target so it does not warn
about files it cannot compile. `ATSApplicationFontsPath` is `.` rather than
`Fonts`, because a synchronized group flattens a folder of resources into
`Contents/Resources` and the Makefile has to land them in the same place.

Rule that keeps it honest: `Core/` imports Foundation only — no SwiftUI, no AppKit. That single constraint is what makes the engine testable and the Codex source a drop-in.

## 3. Phases

| # | Deliverable | Status |
|---|---|---|
| 0 | Notch panel: borderless `NSPanel`, `LSUIElement`, click passthrough, re-anchoring | ✅ done |
| 1 | `JSONLReader` + both sources + window/ceiling/burn engine, `--probe` | ✅ done |
| 1.5 | **Live limits** — the CLI's `/usage` panel over a pty, 5-min activity-gated polling, attention badge, single-instance guard | ✅ done (unplanned; see §0) |
| 2 | Design system + the remaining pill states + spring morph | ✅ done |
| 3 | Warning auto-expand, pinned panel, context menu | ✅ done |
| 4 | Preferences, notifications, launch at login, pause-survives-relaunch | ✅ done |
| 5 | Source switcher in the pill + prefs (Claude / Codex / combined) | ⬜ not started |
| 6 | Notarized DMG, Sparkle feed, Homebrew cask | 🔨 pipeline built; blocked on a Developer ID certificate |

Phase 1.5 was not in the original plan. It exists because the limits source was wrong: the first
version inferred a ceiling from log volume. It was then rebuilt twice — first onto the OAuth usage
endpoint read with the user's own Keychain token, then onto the CLI's `/usage` panel, which reaches
the same figures without asking for a credential at all. It absorbed most of the time since phase 1.

### Carried out of phase 3

- **⌘⇧B — cut.** The design's global shortcut for the panel. A system-wide hotkey
  needs a Carbon registration (the `NSEvent` route would demand Accessibility
  permission for one shortcut), and the pill is a click away. Out of scope by
  decision, not by oversight; the row is gone from Preferences with it, and from
  the board, so it stops reading as an unbuilt feature.
- ~~**Nothing survives a relaunch.**~~ ✅ fixed: one archive, two files — `state.json` for the
  limits state, `events.json` for events and cursors. What it closed:
  - The refresh floor survives, so a relaunch no longer spawns a CLI straight away.
  - Pause survives.
  - The cold start: 4171ms → 305ms (§4.1).
  - It also uncovered a latent bug worth remembering: a cold start replays every
    retained event, and counting that as "usage since the last reading"
    (`weighted=527694804` in the log) reads as activity on a machine that has been
    idle for weeks. Only events newer than the last run count, and the running
    total is deliberately not archived.
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
- **The Windows group — cut.** The design's reset hour and time zone. Neither is
  ours to set: the window opens on first use and the CLI states when it resets,
  so a picker here would either be ignored or disagree with the countdown beside
  it. Removed from the board along with the group that held them.
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

Then upload `TokenPacer-<version>.dmg` **and `appcast.xml`** to a GitHub release
tagged `v<version>`, and put the cask in a tap.

One-time setup, in order:

1. **A Developer ID Application certificate.** The paid Developer Program; this
   machine has only an Apple Development certificate, which cannot be notarized
   and which Gatekeeper refuses on any other Mac. `make check-devid` says so.
2. `xcrun notarytool store-credentials token-pacer` — Apple ID, team, and an
   app-specific password. Silent thereafter.
3. ~~Sparkle's EdDSA key pair~~ ✅ generated. The public half is in `Info.plist`;
   the private half is in the login Keychain as *Private key for signing Sparkle
   updates*. **It is not in this repo and cannot be recovered.** Lose it and no
   installed copy can ever be updated again — back it up with
   `generate_keys -x` before the first release.

Signing the first release changes the designated requirement once. Nothing is
keyed to it any more now that the Keychain is out of the picture, but Sparkle's
update path is — an installed copy will only accept an update signed the same way.

### Standing design decisions

- **Reduce Motion** — deliberately not honoured, for the activity dot or the shell morph.
- **Sparkle ships alongside the cask, not instead of it.** `brew upgrade` covers people who install
  through the tap; the feed covers people who download the DMG. Gentle reminders are implemented
  because this app has no Dock icon and no menu bar — Sparkle's own panel would arrive from nowhere,
  so a scheduled find speaks through the threshold banner and only a check the user asked for opens
  the panel.
- **The bundle id is `com.redevify.token-pacer`.** Changed with the rename, while it was still free:
  after a public release it is what every install and preference file is keyed to, and nothing had
  shipped yet.
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

- `/usage` panel read over a pty: 4.1s, 4.2KB, parsed to 7% session / 19% weekly / S$11.99 of S$12.00,
  matching what the CLI draws on screen. `--probe` reports `[authoritative]`.
- Single instance enforced, including a raw binary launched past LaunchServices.
- Shadow follows the clipped shape; headroom no longer outlasts its window.
- Collapsed pill and hover card, on screen, against live figures.
- Context menu on right-click — and the reason it first rendered white-on-white: `.regularMaterial`
  follows the desktop appearance. Nothing in this app may track the system scheme.
- `make app` signs with a real identity. This no longer guards a Keychain grant — nothing is read
  from the Keychain any more — but the stable designated requirement still matters for updates.
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
- ~~**Calibration over time**~~ — gone with the endpoint. Before it was removed it measured a
  conversion near 190k weighted a point against an inferred ceiling of 324k, so **the ceiling reads
  roughly 70% too high**: §4.1's outlier problem quantified rather than argued, and the one finding
  worth keeping from that design. `CeilingEstimator` is now the only conversion there is — it feeds
  headroom for everyone — so that 70% is a live inaccuracy, not a footnote.
- **The warning state on screen** — it needs a window past 90% to appear, which no run has reached.
  Every other state has now been seen, and with it the ring pop, which shares the crossing.

## 4. Deliberate simplifications

- 5s polling timer, not FSEvents — a 5-hour window does not need sub-second freshness, and a watcher on `~/.claude/projects` fires constantly.
- 5-minute buckets, not raw event persistence — caps disk and memory regardless of usage volume.
- Full-screen detection by menu-bar visibility (`screen.visibleFrame.maxY == screen.frame.maxY`) rather than window enumeration — no Screen Recording permission needed. `ponytail:` heuristic; upgrade to `CGWindowListCopyWindowInfo` only if it misfires.
- **No network, no credentials, no Keychain** — held, after a detour. Phase 1.5 briefly read the OAuth
  usage endpoint with the user's own token out of the Keychain; that is gone. The app now spawns the
  user's own CLI and reads the panel it draws, so it holds no secret and opens no socket of its own.
  It still degrades to log-only inference when the CLI cannot be read.
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
3. ~~**Bundle id**~~ — settled: `com.redevify.token-pacer`, renamed with the product before release.
4. **The Sparkle private key is a single point of failure.** It lives only in the login Keychain of
   this machine. No backup means no future update for anyone already installed — not a bug that can
   be fixed later, so back it up before the first release, not after.

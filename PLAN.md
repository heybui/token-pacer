# Token Pacer — implementation plan

macOS notch usage tracker. Design source: `design/project/Token Pacer.dc.html`.

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

`BurnRate` lost its calibrated input, leaned on `CeilingEstimator` for a while,
and has since lost that too — see §0.4. It now reports a measured rate and
projects nothing.

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
| Copilot's monthly allowance | **The desktop app's own local daemon** (`~/.copilot/run/`), the same idea as the CLI panel — unproven, see §0 |
| Monthly credit spend | the panel's `Usage credits` row — free, no Console admin key |
| Burn rate, sparkline | Log token counts (no provider states a rate of change) |
| Splits by model / project / surface | Log token counts (the API gives no attribution) |
| 30-day history | Log token counts |

So log parsing stays — it answers everything the panel cannot — but it stops being the source of the headline number.

### Log formats (verified on this machine)

| | Claude Code | Codex | Copilot |
|---|---|---|---|
| Store | `~/.claude/projects/<slug>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `~/.copilot/session-store.db` — SQLite, WAL |
| Usage record | `type:"assistant"` → `message.usage` | `type:"token_usage_record"` → `payload.usage` | a row in `assistant_usage_events` |
| Fields | `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` | `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens` | `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens` |
| Dedupe key | `message.id` + `requestId` | `response_id` | `id`, the row's own autoincrement |
| Context | `cwd`, `sessionId`, `message.model`, `timestamp` | `session_meta.payload.cwd`, `turn_context.cwd` | `sessions.cwd`, `sessions.repository`, `model`, `created_at` (ISO-8601 UTC) |
| Nesting trap | cache counts are **separate from** `input_tokens` | `cached_input_tokens` is **inside** `input_tokens`; `reasoning_output_tokens` is inside `output_tokens` | none — every count is its own column |

Two notes on reading `~/.copilot`: open it `mode=ro`, never `immutable=1` — the
database runs in WAL mode with a multi-megabyte `-wal` beside it and `immutable`
skips that file, so the newest turns would simply be invisible. And reading it
means `import SQLite3` in `Core/Ingest`: a C library out of the SDK,
infrastructure in the same sense as `os.Logger` rather than a break in the
Foundation-only rule. Never open it for writing; it belongs to another app.

### One mechanism, three providers: each one's own figure

The headline percentage is always the provider's own, read from wherever that
provider already keeps it. No quota is ever reconstructed here — the quotas
differ in period, in unit and in how they are counted, and an app that models
three of them is three times wrong the week any of them changes.

| | Where its own figure is | What that costs |
|---|---|---|
| Claude | the CLI's `/usage` panel, over a pty | ~4s a run, whole percentages, a UI for a contract |
| Codex | `rate_limits` in the rollout logs — `used_percent` to one decimal, `window_minutes` 300 and 10080, `resets_at` | nothing: it writes it down itself, so there is nothing to drive |
| Copilot | the desktop app's own local daemon — `~/.copilot/run/ws.port` and `ws.token`, message kind `get_account_quota`, seen in its logs | unproven; there is no `copilot` binary to drive, so this is the pty's equivalent |

The rule that follows, and the reason there is no per-provider arithmetic here:
**a provider whose own figure cannot be read has no row.** Not an estimate, not a
row built from token counts against an assumed plan size. Local token counts keep
answering what no quota endpoint ever will — rate of change, attribution, history
— and never the headline. Nothing infers a percentage any more: `CeilingEstimator`
is deleted, §0.4.

Toolchain: Xcode 27, Swift 6.4. **Deployment target macOS 15+**.

## 0.1 Decisions taken

- **Codex ships in phase 1**, not phase 5 — two conformances prove the seam instead of guessing it, and Codex's authoritative `used_percent` is a free correctness check on Claude's inferred one.
- **macOS 15+**.
- **API spend gauge**: cut as a *Console Admin API* feature, then restored — the `Usage credits` row
  of the CLI's own panel carries monthly credit spend for free, currency symbol and all. Drawn only
  when the account has extra usage enabled.
- **Instrument Sans bundled** (OFL) + SF Mono for numerics, matching the design's metrics exactly.

## 0.2 The board was redrawn (2026-09-18)

The design changed shape, not detail. Five things moved; each is a real delta
against what is built, and they are listed here rather than folded silently into
the sections below, because most of phase 2–4 was built against the old board.

### The pill is gone from the menu bar row

The collapsed state is no longer a shell. It is a **bar row**: flat, no
background of its own, straddling the notch. The mark and the exact percentage
sit in the **left wing**, the time left in the **right wing**, the hardware
between them, and *nothing is ever drawn where the hardware is*. Only the
expanded states — hover, over, pinned — are a shell, and that shell is the
**drop panel**: it grows downward out of the notch, corners `0 0 R R`, and spans
past the notch on both sides.

What this contradicts: the app currently fills the whole band, notch width
included, with the shell's own black so the pill reads as grown out of the
hardware. The board now says that black is only for the drop panel. The band
geometry (`NotchBand`, `PillState.flank`) survives; what it is filled with does not.

- Notch measured on the board: **190 × 37**, 12.6% of the menu bar.
- A capsule-bar wing readout is ~160pt (44 wordmark + 76 bar + number + 7 gaps);
  a ring wing is ~70pt, which is the argument for the ring.
- **The left wing yields.** When the frontmost app's menus reach it, it drops and
  the right wing carries the highest provider alone. New behaviour, no code.
- Off a notch, or once the left wing has yielded: **right wing alone, 226 × 34,
  radius 12** — mark, bar, percentage, countdown in one row.

### Three providers, not two

Claude, Codex and **Copilot**. Every provider gets the same bar — 0–100% of its
own quota — and differs only in the clock behind it: Claude a rolling 5 hours,
Codex a week, Copilot a month. Each row carries its own reset.

- **Measured left, estimated right.** The left wing takes the highest *measured*
  provider, the right the highest *estimated* one; position carries attribution
  once the wordmark no longer fits.
- **Estimated is drawn, not just stated**: a hollow marker that overhangs the bar
  by 4pt top and bottom, plus a `~` on the number.
- **Stacked, 226 × 34** below the notch when two need showing: bars halve to
  2.5pt, each row keeps its own countdown.
- **Hover card, 404 × 98**: one row per provider, same capsules, same domain, each
  ending in its own reset — because 81% of a week and 81% of a month are not the
  same problem. The board drew it at 116; the shipped 98 stands and the board was
  changed to match (§0.3).

Copilot's store is `~/.copilot`, and its quota is not in it: the desktop app asks
its own local daemon, which asks the server. That daemon is reachable — port and
token sit in `~/.copilot/run/` — so the figure is fetched the same way Claude's
is, from the client that already holds the credential. Until that is proven,
Copilot has no row (§0). The board's hollow marker stays what it is for: a figure
that is not the provider's own, which after this rule means Claude's log-only
fallback and nothing else.

### The mark is a choice of twelve

The lead figure is no longer the ring. It is a **mark**, chosen in Preferences
from twelve drawn at menu-bar size, default **Capsule bar**:

| | | |
|---|---|---|
| Capsule bar · position on a zone track | Ring wings · angle on a zone track | Notch tank · liquid remaining |
| Pips · count of 8 | Half gauge · needle angle | Eclipse · disc occluded |
| Token stack · discs remaining | Hourglass · sand transferred | Dotted arc · count of 12 |
| Dot matrix · count of 9 | Signal strength · bars remaining | Thermometer · column height |

Two rules run through all twelve:

- **The track is the scale, the marker is the reading.** The bar is not a fill —
  it is three static capsules (0–74 green, 76–89 amber, 91–100 red, 2% gaps) with
  a marker riding at the provider's position. Zone colour comes from where the
  marker is, so the mark, the border and the banner can never disagree.
- **The mark carries "working".** Each animates on its own mechanism while a model
  is answering — the next increment charges, a meniscus bobs, a grain falls, a
  shadow creeps — never one shared blink. This replaces `PulsingDot` as the
  activity signal; the signal itself (`LogWatcher`, the turn heuristic) is unchanged.

Marker light tints, distinct from the zone tints: `#a5f0cd` safe, `#fbcda2` watch,
`#f4ab9e` over. **Amber stays `#e8b33c`** — the board had moved it to `#f0913a`;
that was decided against and the board was changed back (§0.3). `Tokens.swift` is
unchanged.

### The running border is a choice of twelve too

Comet (the current one, and still the default), Dual comet, Zone sweep, Marching
dashes, Pulse wave, Quarter trace, Counter pair, Breathe, Breathe glow, Edge
runners, Side drip, Bottom sweep. All take their colour from the zone the panel is
in; all leave the top edge dark, which `ShellTrack` already does. One switch gates
the whole group. `ChasingBorder` is one of the twelve, not the only one.

### Preferences becomes two panes

- **General** — *Zones*: the dual-handle track, relabelled "Watch starts at" /
  "Over starts at", and now the source of every zone colour in the app rather than
  only of alerts. *Alerts*: notify when over, sound when over. *App*: launch at
  login, hide when nothing is running, restore defaults.
- **Appearance** — two grids of twelve tiles, drawn live at real size, plus a
  Safe / Watch / Over preview switch that recolours all twenty-four at once, a
  working-indicator switch, and a preview of both choices together. A popup menu
  is ruled out by the board: "Eclipse" tells you nothing about what lands in your
  menu bar.

Settled by the board and now built: **the over banner fires alongside the notch**,
not only when the notch is hidden. The notch carries the state, the banner carries
the moment it changed. Only going over fires one — watch stays silent and visual,
the mark just tints amber — and the copy is the board's: "Over", then the
percentage, the time left and one coach line.

## 0.3 Reflected back into the board (2026-09-18)

Where the board and the shipped app disagreed on something already settled, the
app was right and the board was corrected — the design files are a source of
truth, so a prototype carrying a cut feature reads as an unbuilt one forever.
Changed in `design/project/`:

- **Amber back to `#e8b33c`** — 29 occurrences across the board, the landing page
  and the app-icon sheet, glows included.
- **Hover card 116 → 98**, label and mocks, radius 22 → 26, matching `PillState`.
- **The context menu as built**: Preferences, Pause tracking, Check for updates,
  Send feedback, Quit. Copy usage summary and About are gone; feedback is in.
- **⌘⇧B struck from the pinned-panel card** — the global hotkey was cut (§3).
- **The build notes**: macOS 15+, `com.redevify.token-pacer`, the CLI's `/usage`
  panel over a pty instead of "rate-limit fields", and no Console API key.
- **The landing page** now says macOS 15+.

**The icon was re-exported** with the corrected amber and the real zone
boundaries (the old export had watch at 70% and over at 95%), and
`TokenPacer.icns` rebuilt from it — all ten sizes, no `#f0913a` left at any of
them. That rebuild is now `make icon` rather than folklore: the export names the
Retina rungs `icon_512x512_2x.png`, `iconutil` only recognises `@2x`, and it
drops what it does not recognise without a word — which yields an icns that
stops at 512 and looks soft in a Retina Finder.

## 0.4 The ceiling is deleted (2026-09-18)

`CeilingEstimator` is gone, and with it every number this app worked out for
itself. What is on screen is what a provider said, or nothing.

It had two jobs and both were already hollow:

- **The fallback percentage** when a reading could not be taken. Dead the moment
  the rule in §0 was written: a provider whose figure cannot be read has no row,
  so there was nothing left for an inferred percentage to be shown *as*.
- **The token→percent conversion** that turned a burn rate into headroom. The
  conversion never existed to be measured — the panel prints `7%`, never how many
  tokens made it — so it came from the largest window ever observed, which read
  about 70% high (§4.1) and drifted with one heavy afternoon.

**What went with it:** `Ceiling`, `CeilingEstimator`, `UsageSnapshot.Origin` and
its three cases, `BurnRate.headroomMinutes`, the horizon guard, the "estimated"
and "no ceiling yet" labels, the ceiling line in `--probe`, and nine tests. Net
−225 lines, and `BurnRate` is now four lines of arithmetic over the trailing
thirty minutes.

**What it costs, stated plainly:** the board's over banner said "90% used, ~18 min
left" and now says "90% used, 2h 04m to the reset". The hover card's pace line
loses its projection the same way. A countdown to a reset is a fact; minutes of
headroom was three guesses stacked — a rate, a conversion, and the assumption
that the next hour looks like the last half one.

`sessionTokens` stays, because a token count is a measurement: it is what the
pinned panel's hero shows before the first reading lands, and what `1.25M` in the
flank width is sized for.

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
    var id: SourceID { get }                      // .claude | .codex | .copilot
    func poll() async throws -> SourceSnapshot    // events since last cursor + optional authoritative limits
}
```

Two conformances today, three on the redrawn board, one aggregator. No registry,
no DI container. Copilot's is a SQLite read rather than a JSONL tail, which is
what the cursor abstraction has to stretch to cover: `(path, inode, offset)`
becomes `(path, last row id)` for that one source.

**Incremental reading is mandatory.** Re-parsing every JSONL every 5s would read hundreds of MB. `JSONLCursor` keeps `(path, inode, offset)`; each poll stats mtime, seeks to offset, decodes only new lines, and drops a cursor whose inode changed (log rotation).

**Engine** (pure, synchronous, fully testable — no I/O, no dates from `Date()`, inject a clock):
- `WindowCalculator` — ccusage block rule: a block starts at the first event after a ≥5h gap, floored to the hour; block spans `[start, start+5h)`.
- `BurnRate` — weighted tokens/hour over a trailing 30 min. A measurement, not a projection.
- `Aggregator` — folds events into **5-minute buckets** keyed by `(source, model, project, surface)`. 30 days ≈ 8.6k buckets; the sparkline, splits and history all read buckets, never raw events. Persist buckets as JSON in Application Support; never persist raw events. No SQLite.

Output is one value type the whole UI binds to:

```swift
struct UsageSnapshot {
    var sessionPct: Double?, sessionTokens: Int, resetsAt: Date   // nil = not reported
    var weeklyPct: Double?, weeklyResetsAt: Date
    var burnRatePerHour: Double
    var sparkline: [Double]          // 26 buckets, matches the design
    var splits: Splits               // by model / project / surface
    var history: [DayUsage]          // 30 days
}
```

Weighted tokens: one `TokenWeights` struct (output ×5, cache-write ×1.25, cache-read ×0.1 — ccusage's ratios), per-model overrides in a plist. Calibration knob, not a constant buried in code — the real ratios drift with pricing.

### 1.3 UI: one view tree, state enum drives size

`PillState` enum mirrors the design exactly: `dormant, ghost, collapsed, hover, warning, exhausted, paused, pinned` — the redrawn board renames them (hidden, ghost, collapsed·resting, hover card, over, over·at the cap, paused, pinned panel) but keeps all eight. Derived from `(snapshot, pointerInside, isPinned, warnAcknowledged, trackingPaused)` in one function — no scattered booleans.

**Two surfaces, not one shell.** Four states live in the flat bar row either side
of the notch and draw no background at all; four are the drop panel, a shell with
bottom-only corners growing down out of the notch:

| State | Surface | W × H | radius |
|---|---|---|---|
| hidden | bar row | both wings empty — the menu bar reads as stock hardware | — |
| ghost | bar row | both wings at 45%, showing the weekly cap | — |
| collapsed | bar row | mark + exact % left, time left right | — |
| exhausted | bar row | split across both wings, mark full, % and countdown red | — |
| paused | bar row | pause glyph left, the word "paused" right | — |
| right wing alone | bar row | 226 × 34 — no notch, or the left wing has yielded | 12 |
| stacked | drop panel | 226 × 34, two provider rows, bars at 2.5pt | 12 |
| hover | drop panel | 404 × 98, one row per provider | 26 |
| over | drop panel | big percentage, the countdown, one coach line | 26 |
| pinned | drop panel | 752 × 540 | 26 |

The board's old 226 × 3 dormant hairline is gone with the shell: hidden now means
both wings are simply empty.

Animation: `.interpolatingSpring(stiffness: 220, damping: 24)`, per build note. Reduce Motion deliberately ignored for the shell morph (design decision — but keep it honoured for the pulsing dot, which is a real accessibility nuisance, not the product).

Components worth owning (everything else is stock SwiftUI):
- `OdometerText` — digit strips translated by `-d em`, spring transition + brief blur. Used at 5 sizes (11/11.5/12/26/30px).
- **`Mark`** — one protocol, twelve conformances, each drawing a zone track and a
  marker and owning its own working animation (§0.2). `UsageRing` becomes *Ring
  wings*, one of the twelve; the capsule bar is the default and the only one that
  shows position and all three boundaries at once.
- **`BorderEffect`** — twelve edge treatments over the existing `ShellTrack`.
  `ChasingBorder` becomes *Comet*, the default.
- `CapBar`, `Sparkline`, `SplitRow`, `HistoryRow` (monospace `█`/`░` blocks, as designed).

Tokens (`DesignSystem/Tokens.swift`): `green #3ec98a`, `amber #e8b33c`, `red #e2543f`, `blue #5aa9d6`, shell `#000`, thresholds 75 / 90 but user-set. Marker lights are a second scale: `#a5f0cd` / `#fbcda2` / `#f4ab9e`. One `tone(for:)` function — the design applies the same rule to session, weekly, every mark and every border; it must exist in exactly one place.

Font: design uses Instrument Sans (OFL). Bundle it to match pixel-for-pixel; SF Mono for all numerics.

## 2. Scaffold

**One Xcode target, folders only.** No SPM multi-module split until build times actually hurt — the layering below is enforced by import discipline and tests, not by module boundaries.

Two build systems over one set of folders:
- `TokenPacer.xcodeproj` — the shipping path (Info.plist, entitlements, hardened runtime, signing, Sparkle in phase 9). Uses Xcode 16+ **synchronized folder groups**, so `TokenPacer/` and `Tests/` are picked up wholesale and new files never need registering.
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
    Engine/               WindowCalculator.swift · BurnRate.swift
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
| 2 | Design system + the remaining pill states + spring morph | ✅ done (old board) |
| 3 | Warning auto-expand, pinned panel, context menu | ✅ done (old board) |
| 4 | Preferences, notifications, launch at login, pause-survives-relaunch | ✅ done (old board) |
| 5 | **Two wings** — the flat bar row, the drop panel, the left wing yielding to app menus | ⬜ not started |
| 6 | **Marks** — the `Mark` protocol, twelve of them, the capsule bar as default | ⬜ not started |
| 7 | **Appearance** — the second prefs pane, twelve border effects, the live grids | ⬜ not started |
| 8 | **Copilot** — its quota from the app's local daemon, `~/.copilot/session-store.db` for everything else | ⬜ spike the daemon first |
| 9 | Notarized DMG, Sparkle feed, Homebrew cask | 🔨 pipeline built; blocked on a Developer ID certificate |

Phases 2–4 shipped against the board as it stood; §0.2 is what the redraw asks
back. Nothing in `Core/` is affected — the redraw is entirely above the snapshot.
The old phase 5, a source switcher between Claude and Codex, is cut: the board
puts every provider on screen at once instead of choosing between them.

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
  through `AlertPolicy` → `UNUserNotificationCenter`. It fired only when the notch
  was hidden — a full-screen app or another space — on the grounds that a pill
  already showing 93% does not need to be told. ~~That~~ ✅ changed with the
  redraw: the banner fires beside a notch in plain sight, once per window, on
  going over only.
- **The Windows group — cut.** The design's reset hour and time zone. Neither is
  ours to set: the window opens on first use and the CLI states when it resets,
  so a picker here would either be ignored or disagree with the countdown beside
  it. Removed from the board along with the group that held them.
- **One scale, two handles.** The design's two sliders became a single 0–100
  track with a warn handle and a critical one, clamped so warn can never pass
  critical. Reset restores that scale and nothing else; the other rows are
  preferences, not a configuration to be undone.
- **Three deltas against the design board**, chosen from a scan: the ring pops on
  a threshold crossing, the ghost fades rather than cuts, and a spent window reads
  red. A silent return to dormant was offered and declined.
- **A light runs the shell's border** while tokens flow — not in the design, asked
  for on top of it. Tone follows the alert scale; the pinned panel is exempt,
  since a 752×540 sheet with a light running round it is a screensaver.
- **The app icon is bundled** and the Xcode target carries it explicitly, as
  synchronized folder groups do not pick up a Resources phase entry.

### Phase 9 — cutting a release

```
make release VERSION=0.1.0
```

That is `notarize` → `appcast` → `cask`, then the publish. The order is
sequenced by hand in the recipe because it is load bearing: stapling rewrites
the disk image, so the feed has to be signed after it or it signs bytes nobody
downloads. The individual targets still stand alone for a dry run.

**Where it publishes, and why it is not this repo.** The source is private, and a
private repo's release assets have no unauthenticated URL at all — there is no
setting to flip. Sparkle cannot authenticate, and neither can `brew`. So two
public repos carry the distribution surface, both checked out beside this one:

| Repo | Holds | Reached by |
|---|---|---|
| `heybui/tokenpacer.com` | the landing page, `appcast.xml`, and the DMG as a release asset | Sparkle, at `https://tokenpacer.com/appcast.xml` |
| `redevify/homebrew-tap` | `Casks/token-pacer.rb` | `brew tap redevify/tap` |

The feed is served from the domain rather than from the release it ships with,
because a build polls the URL it was compiled with for ever. Everything else —
the DMG's URL, the cask's checksum — is rewritten every release and can move
freely. `SITE_REPO`, `SITE_DIR`, `TAP_REPO` and `TAP_DIR` in the Makefile are the
only knobs.

**Deliberately not in CI.** Automating this would mean putting the Developer ID
`.p12`, the notary password and the Sparkle signing key into repository secrets —
three irrecoverable credentials leaving the Mac to save one `make` on a solo
release cadence.

One-time setup, in order:

0. **The two public repos and the domain.** `tokenpacer.com` pointed at
   `heybui/tokenpacer.com` Pages with a `CNAME`, and `redevify/homebrew-tap`
   created empty. `gh` has to be authenticated as the account that owns them.
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
- ~~**Headroom is only projected four sample-lengths ahead.**~~ Gone with the ceiling (§0.4). The
  horizon guard existed because a rate measured over thirty minutes told a live machine it had 269
  minutes left at 0.3% used. Nothing is projected now, so there is nothing to bound.

### Verified on hardware

- `/usage` panel read over a pty: 4.1s, 4.2KB, parsed to 7% session / 19% weekly / S$11.99 of S$12.00,
  matching what the CLI draws on screen. `--probe` reports `[authoritative]`.
- Single instance enforced, including a raw binary launched past LaunchServices.
- Shadow follows the clipped shape.
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

- **Notch hardware.** Mostly run on an external display with no notch, so the no-notch fallback is
  what has been exercised. `--probe` now resolves the built-in Retina display as the host — safe-area
  top 38, notch 220 wide, a 39pt row, collapsed shell 368×39 against the board's 226×36 — so the
  geometry is no longer theoretical. What it looks like around the real camera is still an eye
  check nobody has made.
- **Menu-bar click passthrough** and full-screen / space-switch behaviour.
- ~~**Calibration over time**~~ — gone with the endpoint, and the ceiling it fed is gone too (§0.4).
  Before it was removed it measured a conversion near 190k weighted a point against an inferred
  ceiling of 324k: the ceiling read roughly 70% high. That is now a fact about a deleted file.
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
- ~~**Outliers dominate the inferred ceiling.**~~ ✅ answered by deletion, not by a better estimator (§0.4). Max-observed put Claude's ceiling at 32.4M weighted tokens, so a normal window read ~4%; p95 and a decaying trailing max were the candidate fixes. Neither was built. A percentage nobody publishes is not a percentage.

## 5. Standing risks

1. **Undocumented log formats.** Both `~/.claude` and `~/.codex` schemas are private and unversioned; a CLI update can rename a field and the tracker silently reads zero. Mitigation: decode defensively, and when a source yields no parseable usage record in a window where the CLI *is* running, show an explicit `no data` pill state — never a confident `0%`.
2. **A provider can go quiet.** Every percentage is now the provider's own, so when a reading cannot be taken — the CLI moved, the panel changed, the daemon is down — there is no number at all rather than a wrong one. The pill shows the window's token count and the countdown; the risk is a user reading "no figure" as "no usage". `TokenWeights` no longer touches anything on screen except the burn rate and the splits, where only the ordering matters.
3. ~~**Bundle id**~~ — settled: `com.redevify.token-pacer`, renamed with the product before release.
4. **Copilot's quota comes from a daemon nobody documents.** The port and token
   in `~/.copilot/run/` belong to the desktop app and are rewritten when it
   restarts; the message shape is known only from its own logs. Same class of risk
   as the CLI panel, with less to go on — and the same answer: when it cannot be
   read, Copilot has no row rather than an invented one.
5. **The Sparkle private key is a single point of failure.** It lives only in the login Keychain of
   this machine. No backup means no future update for anyone already installed — not a bug that can
   be fixed later, so back it up before the first release, not after.

# Token Pacer — technical specification

How the app is built and why it is built that way. Product decisions live in
[PRD.md](PRD.md); the exhaustive list of what is read off disk is
[ACCESS.md](ACCESS.md).

Toolchain: Xcode 16+, Swift 6 strict concurrency, **deployment target macOS 15**.
One process, one target, no XPC, no daemon, no network.

```
  Host (AppKit)        NotchPanel — one borderless NSPanel pinned to the notch
        ↕
  UI (SwiftUI)         PillView / HoverCard / WarningCard / PinnedPanel  ← @Observable UsageStore
        ↕
  Core (Swift actors)  UsageSource → Engine → UsageSnapshot
```

`Core/` imports Foundation and `os` only — no SwiftUI, no AppKit. That single
constraint is what keeps the engine testable and the sources swappable.

---

## 1. Where the figures come from

### 1.1 The panel is the source

Each CLI already fetches its own quota with its own credentials and draws it on
screen. The app drives the CLI through a pseudo-terminal and reads that screen.

```
openpty → posix_spawn(cli, POSIX_SPAWN_SETSID) → wait for the screen to go quiet
        → write "/usage" ⏎ → read until the marker and the screen settles → kill the group
```

Measured on this machine: **~4s and 4.2KB for Claude's `/usage`**, **$0.0000** —
no model call.

Codex and Copilot do not go through any of this. Both ship a JSON-RPC server in
the same binary — `codex app-server` on newline-delimited JSON, `copilot
--headless --stdio` on `Content-Length` frames — so their limits are asked for
and answered as numbers: **~1s each**, no terminal, no trusted project, no
composer a stray keystroke can be typed into, and for Copilot no folder-trust
dialog in front of the answer. `CodexAppServer` and `CopilotAppServer` own the
processes; `CodexUsagePanel` and `CopilotUsagePanel` own the decodes. Claude
Code is the last CLI here that only states its quota on a screen.

`TerminalCLI` owns the pty and holds one `Spec` per CLI it drives — Claude's,
today: where the binary lives, what to type, what says the panel arrived, how a
trusted directory is found. `ClaudeUsagePanel`, `CodexUsagePanel` and `CopilotUsagePanel` own the
parsing, import Foundation only and share `PanelText` — so the hard part is
testable without spawning anything.

**What it buys:** no Keychain prompt, no token of our own, no `setup-token` step,
no undocumented endpoint to be a good guest at.

**What it costs, stated plainly:**

- **Whole percentages.** The panel prints `7%`, never `7.3%`.
- **No typed failures.** 401, 403 and 429 are one absent regex match. What
  survives is what is visible from outside the process: no binary, no trusted
  directory, a timeout, a login prompt, an unparseable screen.
- **A UI is the contract.** The CLIs ship weekly and no panel has a
  compatibility promise. (Codex's RPC is a wire format rather than a screen, and
  carries the one real promise here.) Two quirks are already handled: the CLI positions the
  cursor rather than emitting padding, so stripping escapes welds `Current
  session` into `Currentsession` and `Resets Sep 22 at 1am` into
  `ResetsSep22at1am` — every pattern treats whitespace as optional and re-spaces
  stamps on letter/digit boundaries. `PanelTests` pins both shapes against a
  captured render.
- **Cached first, fresh second.** The panel paints a cached figure then repaints,
  and nothing says which is which. The reader waits for the screen to stop
  changing; the parser takes the *last* match.
- **An untrusted directory blocks it.** Claude draws "is this a project you
  trust?" where the panel should be, so the working directory is one already
  answered for: the first project in `~/.claude.json` with
  `hasTrustDialogAccepted`. Codex and Copilot start no session and draw no
  screen, so neither needs one.
- **A GUI app has no PATH.** launchd gives it `/usr/bin:/bin:/usr/sbin:/sbin`, so
  each binary is found by full path in the known install locations, or via
  `TOKENPACER_CLAUDE_BIN` / `TOKENPACER_CODEX_BIN` / `TOKENPACER_COPILOT_BIN`.
- **The render is the only evidence.** A panel that fails to parse fails where no
  debugger is, so `TOKENPACER_PANEL_DUMP=<dir>` writes every run's raw screen.

One thing the driver had to learn: **the command and its newline are two
writes.** A completion popup drawn over the composer swallows a newline arriving
in the same read, and the command then sits there until the budget runs out.

### 1.2 Never an inferred number

`CeilingEstimator`, `LimitsCalibration`, `LimitsRefreshPolicy`,
`LiveLimitsTracker` and `BurnRate` are all deleted. The reasoning, kept because
it is the rule the product rests on:

- Calibration anchored on a float and interpolated from local token deltas. At a
  5-minute cadence the true delta is routinely under one point, so a rounded
  delta is `0`, every pair is discarded and the conversion is never measured. Fed
  rounded inputs, a calibration is not a degraded measurement — it is a
  fabricated one.
- The inferred ceiling came from the largest window ever observed. Measured
  against a real conversion it read ~70% high and drifted with one heavy
  afternoon.
- `BurnRate`, stripped of its projection, reported weighted tokens an hour — and
  81% of that figure was cache reads. A number in a unit nobody publishes.

So the pill shows the **last reading**, unmoved between runs, and `--` where
there is none. The only thing inferred without a reading is a reset: the window
is simply empty.

### 1.3 What each layer answers

| Value | Source |
|---|---|
| 5-hour %, 7-day %, reset times | Claude: the `/usage` panel. Codex: rollout logs, and `account/rateLimits/read` once those go quiet |
| Copilot's plan quota | its CLI's `account.getQuota` — used, entitlement and the percentage remaining |
| Copilot's volume and sessions in flight | `~/.copilot/data.db`'s `sessions` row per session, read as growth |
| Monthly credit spend | Claude's `Usage credits` row — free, no Console admin key. Codex's `individualLimit` |
| The plan name | Codex's `planType`. Claude's panel never states one |
| Sparkline, splits by model/project, 30-day history | local log token counts |

Log parsing answers everything the panel cannot, and is never the headline.

### 1.4 Log formats (verified on this machine)

| | Claude Code | Codex | Copilot |
|---|---|---|---|
| Store | `~/.claude/projects/<slug>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `~/.copilot/data.db` (SQLite) |
| Usage record | `type:"assistant"` → `message.usage` | `type:"token_usage_record"` → `payload.usage` | `sessions.total_*_tokens` — a running total, not a record |
| Dedupe key | `message.id` + `requestId` | `response_id` | the totals themselves, written into the event id |
| Context | `cwd`, `sessionId`, `message.model`, `timestamp` | `session_meta.payload.cwd`, `turn_context.cwd` | `sessions.model`, `updated_at`, `workspaces` → `projects` |
| Nesting trap | cache counts are **separate from** `input_tokens` | `cached_input_tokens` is **inside** `input_tokens`; `reasoning_output_tokens` inside `output_tokens` | `total_cached_tokens` is **inside** `total_input_tokens`; there is no cache-write column |

Copilot 1.0.8x dropped `assistant_usage_events`, the row-per-request table this
used to read, and stopped refreshing `open-sessions-state.json` after opening a
session. Both facts moved into one rewritten-in-place row per session in
`data.db`, so Copilot is still an ordinary `UsageSource` — but the unit is a
**running total**, and what becomes an event is the growth between two reads. A
session met for the first time is baselined rather than counted, and the
sparkline is as fine as the poll rather than as fine as the request. See
ACCESS.md for the watermark and why it lives in the event id.

`UsageStore.refreshPanelOnlyProviders` remains the seam for a provider that has
a panel and no source. Every provider shipped today has one.

### 1.5 Homes, cadence, activity

`~/.claude`, `~/.codex` and `~/.copilot` are defaults, not addresses:
`CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `COPILOT_HOME` each move one. Every read
goes through `AgentHome`, which resolves the variable fresh each time and honours
absolute paths only. Claude's `.claude.json` is looked for in the configuration
home *and* beside it — a default install keeps a small one inside `~/.claude` and
the real one in `$HOME`, and taking the first that merely parses cost a whole
provider's reading.

**Cadence:** five minutes, activity-gated, exponential backoff to an hour on
failure, persisted across launches. The constraint is local, not etiquette: each
run boots a whole CLI for several seconds. An idle machine spawns nothing. Codex
needs less of it — its rollout logs carry `rate_limits` with `used_percent`,
`window_minutes` and `resets_at`, so while it is working the figure arrives free
and a log-stated reading counts as a run in `PanelPoller`.

**The activity signal follows the turn**, not the open window and not logged
tokens. A usage record lands only when an exchange *completes*, so the stretch
that most wants a signal — a long think, a five-minute build under a tool call —
logs nothing. The live signal is the newest *conversational* line, read back past
the bookkeeping that is two thirds of a session log (`ai-title`, `mode`,
`attachment`, `queue-operation`): a `user` line awaiting an answer, or an
`assistant` line whose `stop_reason` is `tool_use`. 735 of 792 assistant lines in
a real session are the model stopping for a tool, so reading "assistant" as
"finished" was wrong most of the time. Capped at 15 minutes; a 12s quiet window
covers the rest.

---

## 2. Core

```swift
protocol UsageSource: Actor {
    nonisolated var id: SourceID { get }
    func poll() throws -> SourceSnapshot
    func restore(cursors: [String: JSONLReader.Cursor], seen: Set<String>)
    func cursors() -> [String: JSONLReader.Cursor]
}
```

Two conformances, one aggregator. No registry, no DI container. A source states
limits when its logs carry them (Codex) and `nil` when they do not (Claude);
panel readings arrive on a separate path, `UsageStore` holding one `UsagePanel`
per source, and the newer of the two wins.

**Incremental reading is mandatory.** `JSONLReader.Cursor` keeps `(path, inode,
offset)`; each poll stats mtime, seeks, decodes only new lines, and drops a
cursor whose inode changed. Re-parsing every JSONL would read hundreds of MB —
measured at 714MB across 544 files.

**Engine** — pure, synchronous, no I/O, no `Date()`, inject a clock:

- `WindowCalculator` — ccusage's block rule: a block starts at the first event
  after a ≥5h gap, floored to the hour, and spans `[start, start+5h)`.
- `Aggregator` — folds events into 5-minute buckets keyed by `(source, model,
  project, surface)`. The sparkline, splits and history read buckets, never raw
  events.
- `TokenWeights` — output ×5, cache-write ×1.25, cache-read ×0.1 (ccusage's
  ratios), per-model overrides in a plist. A calibration knob, not a constant
  buried in code: the real ratios drift with pricing. Nothing on screen depends
  on them except the ordering of the splits.

One value type the whole UI binds to:

```swift
struct UsageSnapshot {
    var source: SourceID
    var sessionPercent: Double?          // nil = not reported, never 0
    var sessionTokens: Int = 0
    var resetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    var isActive: Bool = false           // a window with something in it
    var isBurning: Bool = false          // a model is answering right now
    var confirmedAt: Date?               // when the panel last stated this
    var lastActivity: Date?
    var planType: String?
    var panel: PanelData = .empty        // sparkline · byModel · byProject · history
    var spend: Spend?
}
```

`PanelData` lives on the aggregator rather than on the snapshot: it is what the
*pinned panel* reads, and the band never touches it.

**Persistence:** one archive, two files — `state.json` for limits state,
`events.json` for events and cursors, both under
`~/Library/Application Support/TokenPacer/`. Raw events, not buckets, so windows
and splits keep their fidelity. Cold start **4171ms → 305ms**. A cold start
replays every retained event, so only events newer than the last run count as
activity; the running total is deliberately not archived.

---

## 3. Host

### 3.1 One panel, and the window follows the state

**Do not animate `NSWindow.setFrame`** — spring overshoot cannot be got out of it
and it jitters against the compositor. One `NSPanel`; SwiftUI animates the shell
*inside* it.

The rule is "the frame never moves *while a spring runs*". The window **grows at
once** when a state change asks for more room, before the spring starts, and
**shrinks 0.75s after** the shell settles, the pending shrink cancelled by
whatever happens next. `NotchController.fit` is the whole of it.

What does **not** move is the hosting view: it keeps the largest state's frame
for ever and `NotchClipView` repositions it as the window shrinks around it. This
is load-bearing. The first version let the content fill the host
(`maxWidth/maxHeight: .infinity`), which hands SwiftUI the window's bounds, so a
frame change re-lays the tree out *in the same transaction as the state change* —
and the morph stopped being a morph: the shell jumped from hover to pinned.
Sampled mid-flight it read 533 → 625 → 719pt across a 404 → 752 morph. Do not
"simplify" it back.

Click-through is a hit test, not a shape:

```swift
final class PassthroughHostingView<V: View>: NSHostingView<V> {
    var liveRect: CGRect = .zero            // published by the shell view
    override func hitTest(_ p: NSPoint) -> NSView? {
        liveRect.contains(p) ? super.hitTest(p) : nil
    }
}
```

Panel config: `.borderless + .nonactivatingPanel`, `level = .statusBar`,
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
`isOpaque = false`, `backgroundColor = .clear`, `hidesOnDeactivate = false`,
`isMovable = false`. The app is `LSUIElement`.

### 3.2 Notch geometry

Notch present when `screen.safeAreaInsets.top > 0`; notch width is
`screen.frame.width - (auxiliaryTopLeftArea.width + auxiliaryTopRightArea.width)`.
Non-notch Macs and external displays dock to top-centre of the menu bar through
the same code path. Re-anchor on
`NSApplication.didChangeScreenParametersNotification` and on active-screen
change.

The black band has to span the hardware: stop it at the chin and the wallpaper
shows either side of the camera. What goes *in* the band is the flanks, never the
middle. A state that fits there is exactly the band tall, so its bottom edge
lines up with the end of the menu bar.

`PillState.Wings` measures what the two wings hold — the mark's width, the
headline as it reads, the countdown as it reads, the badge when there is one —
and the wider side sets both, because the shell is centred on the notch and
unequal flanks would sit the hardware off-centre in its own shell. One function
measures and the view draws from it, so the rect that takes clicks is the rect
that was drawn.

Widths are **measured, never declared**: `Mark.width` is
`NSHostingView(rootView: MarkView(…)).fittingSize`, cached per mark. A hand-kept
figure drifts the first time a mark is nudged, and it drifts silently.

---

## 4. UI

`PillState` — `hidden, ghost, collapsed, hover, warning, exhausted, pinned` —
derived from `(snapshot, pointerInside, isPinned, warnAcknowledged)` in one
function. No scattered booleans. Anything not in the enum
is not a state.

| State | Surface | W × H | radius |
|---|---|---|---|
| hidden | bar row | both wings empty | — |
| ghost | bar row | both wings at 45% | — |
| collapsed | bar row | mark + % left, time left right | — |
| exhausted | bar row | mark full, % and countdown red | — |
| hover | drop panel | 404 × 98 floor, then sizes to its rows | 26 |
| warning | drop panel | big percentage, countdown, one coach line | 26 |
| pinned | drop panel | 752 × 540 | 26 |

Off a notched screen every bar-row state draws as one 226 × 36 row.

Animation: `Animation.spring(duration: 0.6, bounce: 0.18)` — the board's
`interpolatingSpring(stiffness: 220, damping: 24)` restated as the thing actually
being tuned, which is how long the expansion reads for.

Tokens (`DesignSystem/Tokens.swift`): green `#3ec98a`, amber `#e8b33c`, red
`#e2543f`, blue `#5aa9d6`, shell `#000`. Marker lights are a second scale:
`#a5f0cd` / `#fbcda2` / `#f4ab9e`. One `tone(for:)` function — the same rule
applies to session, weekly, every mark and every border, so it must exist in
exactly one place. Instrument Sans (OFL) bundled for text, SF Mono for numerics.

Components worth owning: `OdometerText` (digit strips translated by `-d em`,
spring transition plus a brief blur), `Mark` + `MarkView` (one protocol, twelve
conformances), `BorderEffect` + `BorderLight`, `CapsuleBar`, `CapBar`,
`Sparkline`, `SplitColumn`, `HistoryHeatmap`, `CreepingMarker`.

### 4.1 The running border

The board shipped a rendering spec for this one, and it names the mistake the
first port made:

> CSS spins a conic gradient at constant ANGULAR speed, so on a 3.07:1 rect the
> head sprints across the 56pt ends and crawls along the 172pt edges. A
> CAShapeLayer with animated strokeStart/strokeEnd moves at constant PATH-LENGTH
> speed — visually even, and noticeably calmer.

Built the spec's way:

- **One masked container.** `CAShapeLayer` stroking `ShellTrack` at 1.5pt is the
  mask — a band on three sides, nothing along the top. Not `layer.borderWidth`,
  which cannot be partial and draws the top edge.
- **The band lies outside the shell.** The stroke is centred half a line *beyond*
  the silhouette, so the light is on the desktop rather than in the black the
  shell already fills. The container and its mask grow by that bleed on the three
  edges the light runs along, never at the top; the outset corner takes the wider
  radius so it stays parallel. The spec masked with an even-odd pair of subpaths,
  which has no offset to choose — a stroked path does, and this is it. An earlier
  build ran the light a point *inside* the edge to stop it reading as a loose bar
  under the pill on an external display; on a notched Mac that is exactly where
  it cannot be seen, because a flanking state ends at the hardware.
- **Seven are angular**: a ramp drawn once into a `CGImage` from the spec's stop
  tables — absolute angles, clockwise from twelve, alphas premultiplied as CSS
  interpolates them — set as a square host's `contents` and turned with
  `transform.rotation.z`. `CAGradientLayer.conic` ignores the mid-stop precision
  these tables need.
- **Three are bands**: axial gradients 52% of the height or 46% of the width,
  travelling −130% → 230% of their own length on one shared timeline with the
  spec's begin offsets and `fillMode = .backwards`.
- **Two stand still**: the hairline breathing 0.22 → 1, and the glow — a shadow
  on the layer itself with `shadowPath` set, the only light that paints outside
  the mask, with the silhouette cut back out of it so the blur haloes rather than
  fills.
- **Four run left to right** against the board's clockwise spin, so their stop
  tables are mirrored — every angle to its reflection, read backwards. Reversing
  the turn alone would put a comet's tail in front of its head.
- **The dash train is snapped to 24 dashes.** At the board's 15.12° there are
  23.8 in a lap and the seam rotates past once every turn.

Consequence to keep in view: an angular sweep hides whatever is over the top
edge, and that share grows with how flat the shell is — ~40% of the lap on the
3:1 panel the spec was drawn for, ~53% on the 11:1 band.

---

## 5. Performance rules

The app is on screen for hours. Idle cost is a hard budget, and every claim here
was measured as Δ CPU-time over a fixed window.

- **`ps %cpu` is a lifetime average, not a rate.** It reported a creeping marker
  at 0.2–0.4% on a fresh process. Measured properly it was **11%**.
- **Nothing in the band animates on the main thread.** An animated geometry
  modifier re-lays out the whole hosting view every display cycle, and this app's
  host is sized for the pinned panel whether or not it is open. Movement is a
  `CABasicAnimation` installed once and run on the render server.

  | | % of one core |
  |---|---|
  | before the capsule bar | 0.63% |
  | marker creeping in SwiftUI (`repeatForever`) | **11.00%** |
  | creep removed | 0.43% |
  | creep on CoreAnimation | 0.57–0.77% |

- **Twelve live drawings cost more than the thing they draw.** The Appearance lap
  started at 21% of a core and came down to 9%: `markEasing` as an environment
  value so a walked grid does not ease, resting marks drawn as plain shapes
  rather than hosted `NSView`s, and rasterising the resting tiles (14% → 9%,
  the only one measured against itself).
- **A closed window is not a stopped window.** The lap kept stepping twelve marks
  ten times a second after the settings window closed — 8% of a core for the rest
  of the run — because a SwiftUI view in a merely-closed window is never told it
  disappeared. The window is released on close and rebuilt on open, and the lap
  is gated on `controlActiveState`. Pinned by a test.
- **Twelve borders turning at once: 0.40% of a core**, less than the twenty-two
  stroke layers the single comet used to cost.
- **`swift build -c release` does not always rebuild.** It has reported "Build
  complete" in half a second on changed sources. `touch` the file or check the
  binary before trusting a screenshot of a release build.

---

## 6. Layout

Two build systems over one set of folders, neither carrying a file list, so they
cannot drift: `TokenPacer.xcodeproj` (synchronized folder groups — adding a file
needs no project edit) and `Package.swift` (fast CLI loop).

```
TokenPacer/
  Info.plist · TokenPacer.entitlements    build inputs, excluded from the group's membership
  Resources/        InstrumentSans.ttf · TokenPacer.icns
  App/              main.swift · AppDelegate.swift · Probe.swift · LogWatcher.swift
  Notch/            NotchPanel · NotchController · NotchAnchor · PassthroughHostingView · NotchClipView
  Features/
    Pill/           PillView · PillState · PillStateResolver · PillModel · PillRootView
                    PillWings · HoverCard · WarningCard · ScaleLine · ScaleRow
    Panel/          PinnedPanelView
    Menu/           NotchMenuView
    Preferences/    PreferencesWindow · PreferencesView · AppearancePane · PaneSwitcher
  Core/
    Model/          UsageEvent · UsageSnapshot · TokenCounts · SourceID
    Ingest/         UsageSource · ClaudeCodeSource · CodexSource · SessionRegistry
                    JSONLReader · AgentHome · UsagePanel · {Claude,Codex,Copilot} panels
    Engine/         WindowCalculator · Aggregator · TokenWeights · AlertPolicy · PanelPoller
    Store/          UsageStore · Archive
    Log.swift
  Services/         TerminalCLI · Notifier · LaunchAtLogin · AppInfo · Preferences
                    SingleInstance · Updater
  DesignSystem/     Tokens · ToneScale · Typography · Format · Mark · Marks · CapsuleBar
                    RingMark · UsageRing · BorderEffect · ChasingBorder · CreepingMarker
                    OdometerText · CapBar · AttentionBadge · JobBadge
TokenPacerTests/    Fixtures/ (trimmed real logs) + EngineTests · SourceTests · PillStateTests
                    ArchiveTests · PanelTests · CodexPanelTests · LimitsTests · …
```

`ATSApplicationFontsPath` is `.` rather than `Fonts`: a synchronized group
flattens a resources folder into `Contents/Resources`, and the Makefile has to
land them in the same place.

---

## 7. Release

```
# Releases → Draft a new release → tag v0.1.0, write the notes, Publish
make release VERSION=0.1.0                   # the same thing, from a laptop
```

`notarize` → `appcast` → `cask`, then the publish. The order is load-bearing:
stapling rewrites the disk image, so the feed is signed *after* it or it signs
bytes nobody downloads. Individual targets stand alone for a dry run.

**Where it publishes, and why not here.** The source is private, and a private
repo's release assets have no unauthenticated URL — there is no setting to flip.
Sparkle cannot authenticate and neither can `brew`, so two public repos carry the
distribution surface, both checked out beside this one:

| Repo | Holds | Reached by |
|---|---|---|
| `heybui/tokenpacer.com` | landing page, `appcast.xml`, the DMG as a release asset | Sparkle, at `https://tokenpacer.com/appcast.xml` |
| `redevify/homebrew-tap` | `Casks/token-pacer.rb` | `brew tap redevify/tap` |

The feed is served from the domain, never from the release it ships with: a build
polls the URL it was compiled with for ever. `SITE_REPO`, `SITE_DIR`, `HOMEBREW_TAP_REPO`
and `HOMEBREW_TAP_DIR` in the Makefile are the only knobs.

**Publishing a release in this repo is the release.** Its tag names the version
and its body is the notes. The workflow hands the tag to `make` as `VERSION`,
and `make app` stamps it into `CFBundleShortVersionString`; the figure in
`TokenPacer/Info.plist` is only the fallback a local build uses. So nothing has
to be bumped before releasing, and no button can disagree with the tag about
what shipped. Drafts do not fire it — the event is `published`.

**The same version can be released twice.** Force-pushing a tag that already
exists is deliberate, so a second run is a retry — of a release that notarized
and then died on the tap, say. It replaces the notes and the image on the
existing GitHub release rather than failing the run, keeping that release's URL
and the download link already in someone's hands. The feed, the cask and the
site commit are idempotent to match: nothing to commit is success, not a failure
to publish.

**Release notes are written, not generated.** The body of that release is the
only copy: CI writes it to `build/notes.md`, `gh api /markdown` renders the
fragment Sparkle embeds, and the site's release page carries the same text. A
generated log was tried and thrown out — it lists `chore` and `ci` under a
version, and the update dialog is the last place anyone wants to read that.
Locally, `make notes` reads the body back off the release, so a laptop and a
runner publish the same words. An empty body publishes without a description
rather than failing. `docs/RELEASE_NOTES.md` is the template and the house rules
for writing one: what that dialog can render, and what leaks out of a private
repo if you paste it in.

**Also from CI.** `.github/workflows/release.yml` runs that same `make release`
on a `macos-26` runner, triggered by the tag push. It only supplies what a
laptop already has: a throwaway keychain holding the Developer ID identity, a
checkout of the site repo as `SITE_DIR`, and the two overrides the Makefile
exposes — `NOTARY_ARGS` for credentials that live in that keychain rather than
the login one, `APPCAST_ARGS` for a signing key read from a file rather than a
Keychain. Nothing about the release is described twice, so the two paths cannot
drift apart.

The cost was weighed, not avoided. Seven secrets live in this repo, three of
them irrecoverable:

| Secret | What it is |
|---|---|
| `DEVID_P12_BASE64` | the Developer ID certificate and its private key |
| `DEVID_P12_PASSWORD` | the password on that `.p12` |
| `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID` | an Apple ID, an app-specific password, `B2WR56QVT7` |
| `SPARKLE_ED_PRIVATE_KEY` | the EdDSA key every update is signed with |
| `SITE_REPO_TOKEN` | fine-grained PAT, contents write on the site repo |

A compromise of this repository is now a compromise of the signing identity. The
certificate can be revoked and reissued; the Sparkle key cannot be rotated at
all, because every installed copy checks updates against the public half
compiled into it. `SUPublicEDKey` in `Info.plist` is a one-way door.

One-time setup, in order:

0. The two public repos and the domain; `gh` authenticated as their owner for
   the local path, `SITE_REPO_TOKEN` for the CI one.
1. **A Developer ID Application certificate** (paid Developer Program). An Apple
   Development certificate cannot be notarized and Gatekeeper refuses it on any
   other Mac; `make check-devid` says so. Take the **G2 sub-CA** when the portal
   offers a choice: a leaf cannot outlive the CA that issued it, and the older
   Developer ID CA expires 2027-02-01, so a certificate issued under it is capped
   at that date no matter when it was created. G2 runs to 2031.
2. `xcrun notarytool store-credentials token-pacer`, once.
3. Sparkle's EdDSA key pair — public half in `Info.plist`, private half in the
   login Keychain as *Private key for signing Sparkle updates*, exported with
   `generate_keys -x` for the CI secret.

Never set Trust on an Apple certificate by hand. Marking the Developer ID
intermediate *Always Trust* makes it an anchor that is not self-signed, and every
signature then fails with `unable to build chain to self-signed root` followed by
`errSecInternalComponent` — a message that points nowhere near the cause.
`security dump-trust-settings` should print nothing; `security remove-trusted-cert`
puts it back.

Updates: **Sparkle ships alongside the cask, not instead of it.** `brew upgrade`
covers the tap; the feed covers the DMG. Gentle reminders are implemented because
this app has no Dock icon and no menu bar — Sparkle's own panel would arrive from
nowhere, so a scheduled find speaks through the threshold banner and only a check
the user asked for opens the panel. Automatic checking is on by default
(`SUEnableAutomaticChecks`), with a switch in Preferences → General → App;
Sparkle owns that setting's storage, so "Restore defaults" leaves it alone.

Bundle id: `com.redevify.token-pacer`.

---

## 8. Standing decisions

- **No new package without asking.** Sparkle is the only dependency, and it is
  vendored under `Vendor/Sparkle` as a local package rather than fetched —
  upstream ships it as a release asset, which SwiftPM pulls once per clean
  checkout with no retry, no timeout and no progress. `Vendor/Sparkle/Package.swift`
  carries the reasoning and the upgrade steps. Only the framework reaches the
  app bundle; the CLI tools beside it are release-time only, and the disk image
  is the same size to within compression noise.
- **Reduce Motion is not honoured**, anywhere, by decision.
- **Nothing in this app tracks the system colour scheme.** `.regularMaterial`
  follows the desktop appearance, which once rendered the context menu
  white-on-white.
- **Instrument Sans is registered twice** — `ATSApplicationFontsPath` for the
  bundle, `CTFontManagerRegisterFontsForURL` for `swift run`. Availability
  decides whether it is used, never the registration return value: a silent
  fallback to the system face is how a design drifts.
- **Full-screen is detected from the menu bar** (`screen.visibleFrame.maxY ==
  screen.frame.maxY`), not by enumerating windows — no Screen Recording
  permission. `ponytail:` heuristic; upgrade to `CGWindowListCopyWindowInfo` only
  if it misfires.
- **FSEvents and a timer, not one or the other.** The tick decides when a reading
  is worth its cost; FSEvents answers "has anything changed at all", because the
  poll's cost was never reading — cursors made that incremental — it was walking
  the tree to find the file being written to. The session registry is the
  exception: its watcher reads on the spot, at 0.3s, because a session that stops
  to ask something is a thing the notch has to say quickly.
- **The instance lock needs `FD_CLOEXEC`.** It is a descriptor, and every CLI the
  app spawns inherited it — one orphaned `claude` process held the lock on the
  app's behalf and the app refused to start with no copy running.
- **Turning a provider off means not polling it.** `UsageStore` skips untracked
  sources entirely — no log walk, no pty — rather than filtering what they
  return. `pref.knownSources` records what has been offered, so a provider added
  by an update is switched on once; switched off after that, it stays off.

---

## 9. Standing risks

1. **Undocumented log formats, and three panels that are UIs.** Both schemas are
   private and unversioned; a CLI update can rename a field and the tracker
   silently reads zero. The panels have no compatibility promise at all. Decode
   defensively, and never a confident `0%`.
2. **A panel-only provider has no second opinion.** Claude and Codex still leave
   volume, activity and a shape behind a broken reading. Copilot leaves nothing:
   if `account.getQuota` moves, that row goes to `--`.
3. **A provider can go quiet**, and `--` has to read as "not reported" rather
   than "no usage". The attention badge carries that difference.
4. **The Sparkle private key is a single point of failure.** It lives only in one
   login Keychain. No backup means no future update for anyone already installed
   — back it up with `generate_keys -x` before the first release, not after.

---

## 10. Still unverified

- Menu-bar click passthrough, and full-screen / space-switch behaviour.
- The **over** state on screen: it needs a window past 90%, which no run has
  reached. Every other state has been seen.

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
then went entirely — §0.4. Nothing states a rate of consumption any more.

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
| Copilot's monthly allowance | **Nowhere reachable.** Its daemon holds it and will not hand it over — spiked and failed, see §0.5 |
| Monthly credit spend | the panel's `Usage credits` row — free, no Console admin key |
| The sparkline — the shape of recent activity | Log token counts (no provider states a rate of change) |
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
| Copilot | nothing that can be read. The daemon that has it refuses a second client (§0.5) | no row |

The rule that follows, and the reason there is no per-provider arithmetic here:
**a provider whose own figure cannot be read has no row.** Not an estimate, not a
row built from token counts against a plan size the app assumed for itself. A plan
size the *user states* is a different thing — a stated premise rather than an
inference — and is the one door left open, for Copilot (§0.2). Local token counts keep
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

### ~~The pill is gone from the menu bar row~~ — tried and rejected

The board asked for a **flat bar row**: no shell, no background of its own, the
mark and the percentage in the left wing, the time left in the right, and nothing
drawn where the hardware is. It was built, put on screen, and reverted the same
hour — **the board is wrong here, and the board was changed to match the app.**

Why it fails: the board assumes the menu bar behind the wings is a plain dark
strip. It is not. The bar is translucent, so a flat row puts the figures straight
onto whatever the wallpaper happens to be — two loose numbers on a patch of sky,
with the camera as a gap between them. The black band is what welds both wings and
the hardware into one object, and that was the argument for it the first time.

What survives from the section: the **drop panel** is still the shell that hangs
below — corners `0 0 R R`, growing downward, spanning past the notch — and the
`NotchBand` / `PillState.flank` geometry is unchanged. What is rejected is only the
idea that the band goes unpainted.

- Notch measured on the board: **190 × 37**, 12.6% of the menu bar.
- A capsule-bar wing readout is ~160pt (44 wordmark + 76 bar + number + 7 gaps);
  a ring wing is ~70pt, which is the argument for the ring.
- ~~**The left wing yields.**~~ Cut. The board had it drop when the frontmost app's
  menus reached it, which means knowing how wide those menus are — and nothing
  short of the Accessibility permission says. One system prompt, for one app's
  worth of politeness, is the wrong trade. Both wings are always drawn; an app with
  a very long menu bar will overlap the left one.
- Off a notch: **right wing alone, 226 × 34, radius 12** — mark, bar, percentage,
  countdown in one row.

### Three providers, not two

Claude, Codex and **Copilot**. Every provider gets the same bar — 0–100% of its
own quota — and differs only in the clock behind it: Claude a rolling 5 hours,
Codex a week, Copilot a month. Each row carries its own reset.

- **Measured left, estimated right.** The left wing takes the highest *measured*
  provider, the right the highest *estimated* one; position carries attribution
  once the wordmark no longer fits.
- **Estimated is drawn, not just stated.** The `~` on the number says it
  everywhere. The hollow marker — an outlined dot instead of a filled one — says it
  on the **ring**, which has a 6.5pt dot to put a ring inside. The **capsule bar
  stays solid in every case**: its marker is a 2pt rule, too narrow to read as an
  outline at menu-bar size, and widening it stops it reading as a position.
- **Stacked, 226 × 34** below the notch when two need showing: bars halve to
  2.5pt, each row keeps its own countdown.
- **Hover card, 404 × 98**: one row per provider, same capsules, same domain, each
  ending in its own reset — because 81% of a week and 81% of a month are not the
  same problem. The board drew it at 116; the shipped 98 stands and the board was
  changed to match (§0.3).

Copilot's store is `~/.copilot`, and its quota is not in it: the desktop app asks
its own local daemon, which asks the server. The daemon was spiked and will not
serve anyone but the app itself — §0.5. So
Copilot has no row (§0.5). The board keeps its vocabulary for an
estimated figure — the `~`, and the hollow marker on the ring — but **nothing in the
app produces one today**: `CeilingEstimator` was the only estimator and it is
deleted (§0.4). So the device is reserved, not in use, and the distinction it draws
is between *approximate* and *absent*: a row that is soft, against no row at all.
If Copilot's daemon turns out to state spend without stating the allowance, that is
the row it is reserved for.

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

Comet (the default), Dual comet, Zone sweep, Marching dashes, Pulse wave, Quarter
trace, Counter pair, Breathe, Breathe glow, Edge runners, Side drip, Bottom sweep.
All take their colour from the zone the panel is in; all leave the top edge dark,
which `ShellTrack` already does. One switch gates the whole group. All twelve are
built (§0.7): `BorderEffect` describes a light as pieces and `BorderLight`
installs them, so `ChasingBorder` is now the seam rather than the one light.

### The mark is chosen, and the card is not

`Mark` names the choice, its axis and what it costs in a wing; `MarkView` is the
one place a reading becomes a drawn mark. The choice is stored in `Preferences`
already — the Appearance pane sets the value the app is reading, rather than the
pane arriving with a value nothing consumes.

The expanded card keeps the **capsule bar whatever the menu bar wears**. Its rows
are a comparison — four readings down one column on one domain — which is the job
position on a line does better than the other eleven, and it is the only mark that
can take the width the card has to give it. The choice dresses the menu bar, where
space is the constraint.

### Preferences becomes two panes

- **General** — *Alerts*: the dual-handle track (Warn / Critical), the sentence
  that says what the two numbers do, Reset beside it, and the sound. *Providers*:
  one switch per provider — off means its CLI is not asked anything. *General*:
  launch at login, hide pill when dormant. The board drew three groups named
  Zones / Alerts / App and relabelled the handles "Watch starts at" / "Over starts
  at"; the shipped pane stands and the board was changed to match it (§0.7).
- **Appearance** — two grids of twelve tiles, drawn live at real size, and
  between them the one switch that changes what the menu bar *holds* rather than
  how it looks: **percentage beside the mark**, on by default. A popup menu is
  ruled out by the board: "Eclipse" tells you nothing about what lands in your
  menu bar. The board's Safe / Watch / Over preview switch was replaced before it
  was built: the mark grid is **walked** from 0 to 100% instead, six seconds a
  lap, two of them in each zone, with the figure beside it (§0.7). One switch
  gates the whole border group and dims the grid rather than hiding it. The final
  preview of both choices together is still unbuilt.

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
- **The hollow marker is solid on every capsule bar**, and only there: a 2pt rule
  cannot read as an outline at menu-bar size. It survives on the ring wings, where
  the dot is 6.5pt, and the `~` on the number carries the same meaning everywhere.

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
and "no ceiling yet" labels, the ceiling line in `--probe`, and nine tests.

Then `BurnRate` itself, in a second pass. Stripped of its projection it reported
weighted tokens an hour — and on a live machine 81% of that figure was cache
reads, so `4.78M/hr` meant "this much context is being re-read", not "this much
is being spent". A number in a unit nobody publishes, that no reader can act on.
The pinned panel keeps the sparkline, which was always the part that said
something: its row is now captioned by its own span rather than by a rate.

**What it costs, stated plainly:** the board's over banner said "90% used, ~18 min
left" and now says "90% used, 2h 04m to the reset". The hover card's pace line is
gone rather than shortened. A countdown to a reset is a fact; minutes of
headroom was three guesses stacked — a rate, a conversion, and the assumption
that the next hour looks like the last half one.

`sessionTokens` stays as a measurement, but it is no longer a headline: the pill
and the panel show **a percentage in every case**, and `--` where a provider has
not reported. Raw tokens read as a figure of the same kind — a big number where a
small one usually sits, on a scale nothing else on screen shares — so "56.7M" beside
a countdown looked like a reading rather than the absence of one. The count is left
to `--probe` and the splits.

## 0.5 The Copilot daemon says no (2026-09-18)

Spiked, and it fails at the last step. Recorded in full because the next person to
have this idea deserves the four hours back.

**What works.** `~/.copilot/run/ws.port` holds the port on its first line and the
app's pid on its second; `ws.token` holds a 48-character token. The token is read
from the query string, and it is genuinely checked:

```
GET /?token=<wrong>  → HTTP/1.1 401 Unauthorized
GET /?token=<right>  → connection closed, no reply at all
```

So the credential is right and the auth layer passes. `get_account_quota` is a
real message kind on that socket — it sits in a list beside `get_session_state`
and `list_session_models`, and the binary carries the handler symbol
`github_app::handlers::misc::get_account_quota` with the failure strings "failed
to fetch account quota" and "get_account_quota hit a Copilot auth failure". That
last one confirms the shape of the thing: the daemon **fetches** the quota from
GitHub on demand and caches nothing to disk, which is why no amount of reading
`~/.copilot` will ever find it.

**What does not.** After the token passes, the upgrade is refused without a
response. Tried: no auth, bearer header, `X-Copilot-Token`, the token as a
subprotocol, `/ws` as the path, and four plausible `Origin` values including
`tauri://localhost`. Every one either 401s or is dropped in under a millisecond.
The socket speaks only to the app it belongs to.

**Why it stops here rather than going further.** What is left is reverse
engineering a Tauri app's private IPC — and the prize is a protocol with no
compatibility promise, on a port and token that rotate every time the app
restarts. The CLI panel is already a UI as a contract (§0); this would be a
private socket as a contract, which is the same bet with worse odds and no user
visible to notice when it breaks.

**Where that leaves Copilot.** Its spend is beautifully recorded — every request
with tokens, model and timestamp in `assistant_usage_events` — and its allowance
is unreachable. A numerator with no denominator, which by §0's rule is no row.
The board still draws three providers; the app can draw two. Reopening it needs
one of: GitHub shipping a `copilot` CLI that states usage, a documented endpoint,
or a decision to let the *user* state their plan size in Preferences and count
premium requests locally — which is a real option, but it brings back the
request-multiplier and initiator arithmetic that was deliberately cut.

## 0.6 What phase 5 actually built (2026-09-18)

The board asked for two wings and a drop panel. What shipped is the panel, the
mark that fills the wings, and one deletion from the board itself.

**The mark.** `CapsuleBar` replaces the ring in the menu bar: three capsules at
full colour standing for safe, watch and over, a point of gap either side of each
threshold, and a marker riding them at the reported percentage. The zones follow
the user's own thresholds, so moving the slider moves the capsules. Drawn at
**36pt** — the board draws 46 and says it wants 76, but both figures buy a 44pt
wordmark beside the bar, and with one provider there is nothing to name.

**The card is a list.** One row per provider on one scale: wordmark, bar,
percentage, the week, its reset. It sizes to its content rather than to a number,
because a preference is coming that turns providers off and any fixed height is
wrong for some of the lists the card can hold.

**The week rides the provider's own bar.** It was a row of its own for an hour,
which made it the *app's* week — and there is no such thing, since Claude states
a weekly cap and so does Codex and they end on different days. It is a dot on the
same track now, told apart from the window by shape rather than by fill: a
1.25pt outline is what dies first at menu-bar size. In the card the dot has its
figure spelled out beside it; in the menu bar there is neither dot nor number,
because a second marker whose number does not fit is a mark nobody can read.

**Cut from the board, twice.** The flat bar row (§0.2) and the left wing yielding
to app menus: the first because the menu bar is translucent and the figures ended
up on the wallpaper, the second because measuring another app's menus needs the
Accessibility permission, and one system prompt is too much to ask for one app's
worth of politeness.

**Still the ring**: the over card and the pinned panel's hero. The board wants
every expanded state to lead with the same mark scaled up, which is phase 6's
job, not a swap to make while ten marks are still unwritten.

### The flanks are a measurement (added with phase 6's second mark)

`PillState.Wings` measures what the two wings hold — the mark's own width, the
headline as it reads, the countdown as it reads, the badge when there is one — and
the wider side sets both. The shell is centred on the notch, so unequal flanks
would sit the hardware off-centre inside its own shell.

One function measures and the view draws from it, so the rect that takes clicks is
the rect that was drawn. The host keeps reserving the widest the wings can ever be:
the window is resized by the controller and the shell by a spring inside it, and a
shell that outgrew its window would be clipped mid-morph.

Band on this machine: **390pt** with the capsule bar, **330** with the ring, against
a flat 396 before. Two mistakes were paid for on the way, both now pinned by tests:
widths were estimated at "0.6em a character" when that is only the cell the odometer
gives a *digit* (letters are measured now, through the same rule the odometer draws
by), and the row's own 12pt between a wing and the notch gap was left out of the
formula, so the countdown drew through its own gutter.


## 0.7 The twelve marks, and what drawing twelve of them cost (2026-09-18)

All twelve are drawn and pickable. `Mark` still names the choice and `MarkView` is
still the one place a reading becomes a drawing; the ten new ones live in
`Marks.swift` together, because each is a dozen lines of geometry and the set is
only worth anything compared against itself.

### The wing measures the mark, it does not declare it

`Mark.width` used to be a number written next to each case. It is now the mark
itself, laid out once and asked how wide it came out — `NSHostingView(rootView:
MarkView(...)).fittingSize`, cached per mark, since a resting mark's size cannot
change. A hand-kept figure drifts the first time a mark is nudged, and it drifts
*silently*: the band would still be laid out to the old number while the new
drawing ran over its own gutter.

What they cost, with a 200pt notch, `100%` and `4h 59m`:

| mark | drawn | flank | band |
|---|---|---|---|
| Thermometer | 8 | 73 | 346 |
| Hourglass | 14 | 79 | 358 |
| Token stack · Dot matrix | 15 | 80 | 360 |
| Eclipse | 17 | 82 | 364 |
| Ring wings | 18 | 83 | 366 |
| Dotted arc | 19 | 84 | 368 |
| Notch tank | 22 | 87 | 374 |
| Signal strength | 25 | 90 | 380 |
| Capsule bar · Half gauge | 36 | 101 | 402 |
| Pips | 38 | 103 | 406 |

The mark is paid for twice — both wings take the wider one — so the choice between
the thermometer and the pips is 60pt of menu bar.

### Where the slack goes is a decision

The flank is the wider wing's measurement, so the narrower wing has slack — and it
used to land wherever the flexible space happened to be, which was beside the
notch. That left the mark pressed into the shell's own rounded corner with a
hand's width of nothing next to the camera.

Each wing is now half of what is left, and each says where its own slack goes:

- **The mark leans in**, towards the hardware. Against the outer edge it sits in
  the corner radius.
- **The countdown leans out**, to the end of the row. Pulled in beside the notch
  it read as a second figure attached to the first rather than as the far end of
  a band. Settled by eye, against the alternative, at the user's call.

Two constants where there was one: `markGap` (12) is spacing between two figures,
`notchClearance` (12) is clearance from a piece of hardware. Same number, free to
disagree. The outer gutters went 11/13 → **15/15**: equal, because a row centred
on the notch with two different gutters reads as a mistake.

### The figure is optional, and the band knows it

`Preferences.showsPercentage` drops the headline from the row and its width from
the wing — one measurement, so the shell narrows by exactly what left it rather
than leaving a hole where the figure was. It sits in Appearance beside the mark
grid, not in General: the mark and the figure are the two halves of the row and
they cost about the same 30pt each.

### The border is twelve too, and it turns rather than travels

The board shipped a rendering spec for this one — `design/project/Token Pacer
Running Border.dc.html`, "Rendering spec · Core Animation" — and it names the
mistake the first port made before anyone could make it twice:

> CSS spins a conic gradient at constant ANGULAR speed, so on a 3.07:1 rect the
> head sprints across the 56pt ends and crawls along the 172pt edges. A
> CAShapeLayer with animated strokeStart/strokeEnd moves at constant PATH-LENGTH
> speed — visually even, and noticeably calmer.

Which is exactly what the first port did, and exactly why it read as a different
animation. It is built the spec's way now:

- **One masked container.** `CAShapeLayer` stroking `ShellTrack` at 1.5pt is the
  mask — a band on three sides and nothing along the top. Every variant paints
  inside it. Not `layer.borderWidth`, which cannot be partial and draws the top
  edge, and that quiet top edge is the whole point.
- **Seven are angular**: a ramp drawn once into a `CGImage` from the spec's own
  stop tables — absolute angles, clockwise from twelve o'clock, alphas
  premultiplied as CSS interpolates them — set as a square host's `contents` and
  turned with `transform.rotation.z`. `CAGradientLayer.conic` is not good enough:
  it ignores the mid-stop precision these tables need.
- **Three are bands**: axial gradients 52% of the height or 46% of the width,
  travelling −130% → 230% of their own length on one shared timeline with the
  spec's begin offsets and `fillMode = .backwards`.
- **Two stand still**: the hairline breathing 0.22 → 1, and the glow, which is a
  shadow on the layer itself with `shadowPath` set — the only light that paints
  outside the mask.
- **Four of them run left to right**, against the board's clockwise spin: the
  comet, the dual comet, the dash train and the quarter trace. Reversing the turn
  alone would put a comet's tail in front of its head, so the stop table is
  mirrored with it — every angle to its reflection, read backwards.
- **The dash train is snapped to 24 dashes.** At the board's own 15.12° there are
  23.8 in a lap and the seam rotates past once every turn.

Twelve of them turning at once in the Appearance grid: **0.40% of a core**, less
than the twenty-two stroke layers the single comet used to cost.

One consequence to keep in view: an angular sweep hides whatever is over the top
edge, and the top edge's share of the turn grows with how flat the shell is. On
the 3:1 panel the spec was drawn for it is about 40% of the lap; on the collapsed
band, which is 11:1, it is about 53%. That is the construction doing what it does
rather than a defect — the alternative is a host scaled to the shell's own aspect,
which evens the travel out and is no longer what the board drew.

### Every expanded state leads with the mark### Every expanded state leads with the mark

The over card led with a red ring and the pinned panel with a 118pt one, which
made them a second opinion on the reading the band had just given. `MarkHero`
scales the chosen mark instead — a mark is a proportion, and the proportion is the
reading. The panel's figure moves out from inside the ring to under the mark:
only one of the twelve has a hole in the middle to put a number in.

### A provider can be turned off, which means not polled

One switch per provider in General. It reaches `UsageStore`, which skips untracked
sources entirely — no log walk, no pty, no `/usage` — rather than filtering what
they return, because the point of turning Claude off is that its CLI stops being
asked anything. The band follows: a source that is no longer read cannot go on
being the active one. The last one on cannot be turned off.

### `swift build -c release` does not always rebuild

It reported "Build complete" in half a second on changed sources more than once in
this session, and the app then ran code that had been replaced — which is a very
good way to conclude that a fix did not work. `touch` the changed file, or check
the binary, before trusting a screenshot of a release build.

### Twelve live drawings cost more than the thing they draw

The Appearance pane walks every tile from 0 to 100% and round again — six seconds,
two in each zone, because at an even rate the over zone would be gone in half a
second. Ten steps a second, not sixty: a mark is a drawing that changes when a
figure changes.

It still started at **21% of a core**. What it came down to, measured by ΔCPU-time
over 20s:

| | of a core |
|---|---|
| the lap, as first written | 21% |
| the lap, after the three fixes below | **9%** |
| the pane open, not lapping | 1.0% |
| the band alone | 0.6% |

Rasterising the resting tiles was the last of the three and the only one measured
against itself under identical conditions: **14% → 9%**. The others were measured
as they were made, and the figures in between are not comparable — a settings
window that is not the frontmost one is redrawn less often, which was worth 5% on
its own and made two of the readings flatter than they should have been.

Three lessons, all of them the same lesson:

- **An `.animation(_:value:)` inside a mark is a per-frame layout of the whole
  window when something *steps* that value.** Four of the twelve ease towards a
  new reading, which is right in the band — a figure lands every few seconds — and
  wrong in a grid being walked. It is an environment value now (`markEasing`), and
  the pane turns it off.
- **A hosted `NSView` at rest is a shape.** `CreepingMarker` draws a plain
  `RoundedRectangle` unless it is actually animating. Every mark's marker went
  through AppKit before, on every layout pass, for the whole life of the app.
- **A closed window is not a stopped window.** The pane's lap kept stepping twelve
  marks ten times a second after the settings window was closed — 8% of a core,
  for the rest of the run — because a SwiftUI view inside a window that merely
  closed is never told it disappeared. The window is let go on close now and
  rebuilt on open, and the lap is also gated on `controlActiveState` so that a
  window hidden behind another app stops too. Pinned by a test.

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

The design morphs the shell between sizes with a spring that overshoots. **Do not animate `NSWindow.setFrame`** — you cannot get spring overshoot out of it and it jitters against the compositor.

Instead: one `NSPanel` sized to the largest state, permanently. The figure is derived rather than typed in — `PillState.hostSize(around:)` takes the pinned panel, the menu's drop, the shadow's whole reach and the band, so it cannot drift from the shells it has to clear. SwiftUI animates the shell *inside* it. To stop the invisible remainder from eating menu-bar clicks, subclass the hosting view:

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
- `Aggregator` — folds events into **5-minute buckets** keyed by `(source, model, project, surface)`. 30 days ≈ 8.6k buckets; the sparkline, splits and history all read buckets, never raw events. Two revisions to what was planned here: the archive persists **raw events**, not buckets (§4, §4.1), and SQLite arrives after all — read-only, as Copilot's store, which this app never writes to.

Output is one value type the whole UI binds to:

```swift
struct UsageSnapshot {
    var sessionPct: Double?, sessionTokens: Int, resetsAt: Date   // nil = not reported
    var weeklyPct: Double?, weeklyResetsAt: Date
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

Animation: `Animation.spring(duration: 0.6, bounce: 0.18)` — the board's `interpolatingSpring(stiffness: 220, damping: 24)` restated as the thing actually being tuned, which is how long the expansion reads for. Reduce Motion is not honoured anywhere, by decision: there is no branch on it in the app and none is wanted.

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
  App/                    main.swift · AppDelegate.swift · Probe.swift · LogWatcher.swift
  Notch/                  NotchPanel.swift · NotchController.swift · NotchAnchor.swift
                          PassthroughHostingView.swift
  Features/
    Pill/                 PillView.swift · PillState.swift · PillStateResolver.swift
                          PillModel.swift · PillRootView.swift
    Panel/                PinnedPanelView.swift
    Menu/                 NotchMenuView.swift
    Preferences/          PreferencesWindow.swift · PreferencesView.swift
  Core/
    Model/                UsageEvent.swift · UsageSnapshot.swift · TokenCounts.swift · SourceID.swift
    Ingest/               UsageSource.swift · ClaudeCodeSource.swift · CodexSource.swift
                          ClaudeUsagePanel.swift · JSONLReader.swift
    Engine/               WindowCalculator.swift
                          Aggregator.swift · TokenWeights.swift · AlertPolicy.swift
                          PanelPoller.swift
    Store/                UsageStore.swift · Archive.swift
    Log.swift
  Services/               ClaudeCLI.swift · Notifier.swift · LaunchAtLogin.swift
                          Preferences.swift · SingleInstance.swift · Updater.swift
  DesignSystem/           Tokens.swift · ToneScale.swift · Typography.swift · Format.swift
                          OdometerText.swift · UsageRing.swift · CapBar.swift
                          ChasingBorder.swift · AttentionBadge.swift
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
| 5 | **Two wings** — the drop panel, the card as a list, the week on the bar (§0.6) | ✅ done |
| 6 | **Marks** — all twelve drawn, `Mark` + `MarkView` the seam, widths measured from the drawings (§0.7) | ✅ done |
| 7 | **Appearance** — both grids live, the preview lap, the percentage switch, the border gate (§0.7) | ✅ done |
| 8 | ~~**Copilot**~~ | ⛔ cut: nothing local states its quota (§0.5) |
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
- **Nothing in the band animates on its own.** Measured as CPU time over a window, on the
  same machine, same build, one variable at a time:

  | | % of one core |
  |---|---|
  | before the capsule bar | 0.63% |
  | capsule bar, marker creeping in SwiftUI (`repeatForever`) | **11.00%** |
  | capsule bar, creep removed | 0.43% |
  | capsule bar, **creep on CoreAnimation** | 0.57 / 0.77 / 0.67% |

  It is not the drawing that costs. The profile is `NSHostingView.layout()` on **every
  display cycle**: an animated geometry modifier re-lays out the whole hosting view, and
  this app's host is sized for the pinned panel whether or not the panel is open.

  So movement in the band is drawn by CoreAnimation — a `CABasicAnimation` installed once
  and run on the render server, nothing on the main thread per frame. `ChasingBorder` had
  already learned this and written it down (`TimelineView` over a `Canvas`: ~18% of a core
  for a decoration); `CreepingMarker` is the same lesson applied to the mark, after paying
  for it a second time. The board's "every mark says working in its own movement" is funded
  again, at the price of a `NSViewRepresentable` per moving part.

- **`ps %cpu` is a lifetime average, not a rate.** It reported a creeping marker at 0.2–0.4%
  on a freshly launched process and that number went into a commit message and into this
  plan as "the creep is free". It is not: measuring Δ CPU-time over a fixed window put it at
  11%. Anything drawn in the band is measured that way, before and after, or not claimed.
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
- ~~**Headroom is only projected four sample-lengths ahead.**~~ Gone with the ceiling, and the burn
  rate behind it went too (§0.4). The horizon guard existed because a rate measured over thirty
  minutes told a live machine it had 269 minutes left at 0.3% used.

### Verified on hardware

- `/usage` panel read over a pty: 4.1s, 4.2KB, parsed to 7% session / 19% weekly / S$11.99 of S$12.00,
  matching what the CLI draws on screen. Re-run 2026-09-18: 15% session / 34% weekly, and Codex
  correctly reporting nothing, its last reading belonging to a window that has since reset.
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
- ✅ **Notch hardware, by eye.** The band around the real camera, checked on the built-in
  display rather than the external monitor every earlier run used.
- The capsule bar and the provider card, on screen against live figures, through four
  rounds of screenshots: the bar drew an eighth of itself past its own right edge (`.offset`
  does not take part in layout, so a centred frame sat the zones to the right of where the
  offsets were measured from), the card read a third empty, its columns were wider than
  their contents, and its rows were too close to read as separate readings.
- **A bug the measuring found.** The app refused to start with no copy of it running: the
  instance lock is a descriptor, and every CLI the app spawns for `/usage` inherited it. One
  orphaned `claude` process held the lock on the app's behalf. `FD_CLOEXEC`, one line.
- Four bugs only the hardware could show: the host clipped the shell's shadow; the shadow reverted
  to a bounding box because a ScrollView cannot be rasterised into a compositing group; `.onHover`
  installed a tracking area over the whole host, which ignores the hitTest that makes the rest
  click-through, so most of the upper screen expanded the pill; and spend read minor units as whole
  currency — S$11.99 shown as $1199.

### Still unverified

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
  ~~It still degrades to log-only inference when the CLI cannot be read.~~ It does
  not: §0.4 removed the inference, so an unreadable CLI means no percentage.
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
  splits and the windows kept their exact fidelity and nothing downstream changed.
  The loading state stays: the first read is still not instant, and a fake 0% would still be a lie.
- ~~**Outliers dominate the inferred ceiling.**~~ ✅ answered by deletion, not by a better estimator (§0.4). Max-observed put Claude's ceiling at 32.4M weighted tokens, so a normal window read ~4%; p95 and a decaying trailing max were the candidate fixes. Neither was built. A percentage nobody publishes is not a percentage.

## 5. Standing risks

1. **Undocumented log formats.** Both `~/.claude` and `~/.codex` schemas are private and unversioned; a CLI update can rename a field and the tracker silently reads zero. Mitigation: decode defensively, and never a confident `0%`. The promised `no data` pill state is now simply what the pill does: `--` wherever a percentage would go, for want of a reading rather than for want of usage.
2. **A provider can go quiet.** Every percentage is now the provider's own, so when a reading cannot be taken — the CLI moved, the panel changed, the daemon is down — there is no number at all rather than a wrong one. The pill shows `--` and the countdown, and the risk is a user reading that as "no usage" rather than "not reported". The attention badge is what has to carry the difference. `TokenWeights` no longer touches anything on screen except the sparkline and the splits, where only the ordering matters.
3. ~~**Bundle id**~~ — settled: `com.redevify.token-pacer`, renamed with the product before release.
4. ~~**Copilot's quota comes from a daemon nobody documents.**~~ Settled by §0.5:
   it cannot be read at all, so there is no risk to carry — only a provider the
   board draws and the app cannot.
5. **The Sparkle private key is a single point of failure.** It lives only in the login Keychain of
   this machine. No backup means no future update for anyone already installed — not a bug that can
   be fixed later, so back it up before the first release, not after.

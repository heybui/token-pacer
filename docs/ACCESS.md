# What Token Pacer reads from your agents

Every path by which this app learns anything about your usage. Four flows for
Claude Code, three for Codex, three for Copilot, all read-only: nothing under
`~/.claude`, `~/.claude.json`, `~/.codex` or `~/.copilot` is ever written, and
the only file this app writes is its own state under
`~/Library/Application Support/TokenPacer/`.

Those three directories are defaults, not addresses. `CLAUDE_CONFIG_DIR`,
`CODEX_HOME` and `COPILOT_HOME` each move one, and every read below goes through
whichever the environment names.

## Claude Code

| # | Flow | Reads | Mechanism | Cadence |
|---|---|---|---|---|
| 1 | The headline percentage | the `claude` binary's `/usage` screen | pty + `posix_spawn` | ≥ 5 min, activity-gated |
| 2 | Volume, models, projects | `~/.claude/projects/**/*.jsonl` | incremental byte cursors + FSEvents | 5 s tick, gated |
| 3 | Sessions waiting / jobs running | `~/.claude/sessions/*.json` | full re-read on FSEvents | on change (0.3 s coalesce) |
| 4 | Where to run the CLI | `~/.claude.json` | one JSON decode per `/usage` run | per run |

---

### 1. The `/usage` panel — the only source of the percentage

`TokenPacer/Services/TerminalCLI.swift` → `TokenPacer/Core/Ingest/ClaudeUsagePanel.swift`

Claude Code fetches its own limits from an authenticated endpoint. This app
never calls that endpoint and holds no token of its own. It drives the user's
own CLI and reads the screen the CLI draws.

**Binary.** First executable found among, in order: `$TOKENPACER_CLAUDE_BIN`,
`~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`,
`/usr/local/bin/claude`, `~/.bun/bin/claude`, `~/.volta/bin/claude`. A GUI app
inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd, so nothing is found
by name.

**Mechanism.**

```
openpty(60×120)
  → posix_spawn(claude, POSIX_SPAWN_SETSID, chdir = trusted project)
      child opens the slave tty itself (fd 0, dup2 → 1, 2) so it acquires a
      controlling terminal; closing the master then delivers SIGHUP
  → wait for the screen to go quiet for 0.8 s   (boot done)
  → write "/usage\r"                            (retried once after 4 s)
  → read until "Resets" appears and the screen settles for 1.5 s
  → kill(-pid, SIGKILL), waitpid, close
```

Whole run capped at 30 s. A pty rather than a pipe because the CLI only renders
the panel when it believes it is talking to a terminal. `TERM=xterm-256color` is
set explicitly (launchd provides none) and every `CLAUDE_CODE_*` variable is
stripped, so a Token Pacer launched from inside Claude Code behaves like any
other session. Its own session id means killing the group takes the CLI and any
MCP server it started.

**What is parsed** (`ClaudeUsagePanel.parse`, Foundation only, no spawning —
testable against a captured render in `PanelTests`):

- `Current session … N% used … Resets …` → the 5-hour window
- `Current week (all models) … N% used … Resets …` → the 7-day window
- `Usage credits … N% used … S$11.99 / S$12.00 spent` → monthly credit spend

Escape sequences are stripped first; because the CLI positions the cursor
instead of emitting padding, every pattern treats whitespace as optional and
re-spaces stamps on letter/digit boundaries. The panel repaints — cached figure
first, refreshed second — so the **last** match wins.

**Cost and gating** (`Core/Engine/PanelPoller.swift`): ~4 s and one whole Claude
Code process per run, $0.0000 — a `/usage` run makes no model call. Therefore:

- floor 5 min, and only when local token activity has been logged since the last run;
- 30 min floor with no local activity at all (web and Claude Design burn the same limit and log nothing here);
- back at the 5 min floor while a reading keeps moving without local tokens to explain it;
- exponential backoff to 1 h on failure, persisted across launches;
- never at all when the source is untracked — untracked means the CLI is not spawned.

An idle machine spawns nothing.

### 2. Transcripts — everything the panel cannot say

`TokenPacer/Core/Ingest/ClaudeCodeSource.swift`, `JSONLReader.swift`, `UsageSource.swift`

Reads `~/.claude/projects/<slug>/<uuid>.jsonl`. Answers volume, the sparkline,
splits by model/project, and 90 days of history — none of which any provider
states. It is **not** the source of the headline percentage (`limits` is always
nil here).

Per file, only bytes appended since the last read, via a `(offset, inode)`
cursor; a changed inode or a shrunken file resets to the start, and a trailing
partial line is left for next time. Files whose mtime predates the 90-day
retention window are never opened. Lines without the byte sequence `assistant`
are skipped before `JSONDecoder` sees them, so prompts and tool output are not
decoded.

Decoded fields, and nothing else: `type`, `timestamp`, `cwd` (last component
only, as the project name), `sessionId`, `requestId`, `message.id`,
`message.model`, `message.usage.*`, `message.stop_reason`. Prompt and response
text is never read. Identity is `message.id#requestId` — `message.id` alone
repeats across a resumed session's replayed history.

`~/.claude/projects` is watched with FSEvents (1 s coalesce, directory-level, no
per-file events) purely as a "scan or don't" flag: discovery — walking the tree
and stat-ing every log — was the cost, not reading. A full scan still runs at
least every 60 s in case FSEvents drops an event. The store's tick is 5 s.

Cursors and the retained events are archived to Application Support so a
relaunch reads a few megabytes instead of the ~700 MB corpus.

### 3. The session registry — who is waiting, what is running

`TokenPacer/Core/Ingest/SessionRegistry.swift`

Claude Code writes one `<pid>.json` under `~/.claude/sessions` per live session
and rewrites it on every state change. The whole directory is re-read on change
(eleven files of half a kilobyte; no cursor — the question is "what is true
now"). Fields used: `pid`, `kind`, `name`, `cwd`, `status`, `updatedAt` /
`statusUpdatedAt`. The `.key` files beside them are peer-messaging secrets and
are never opened.

A registry file outlives its session, so each entry is liveness-checked:
`kill(pid, 0)`, then `sysctl(KERN_PROC_PID)` for the process start time — a
process that started *after* the file was last written cannot be the one that
wrote it (recycled PIDs). Unknown statuses are dropped, which reads as "nothing
is waiting".

Watched with its own FSEvents stream at 0.3 s — the callback *is* the whole
update, so coalescing a second would be a second of the pill claiming nobody is
waiting. Watching one level up (`~/.claude`) would wake on every token written
anywhere on the machine. The 5 s tick re-reads it too, as a floor under a
session that dies without tidying up.

Nothing here is inferred from a transcript and nothing is asked of the session
itself. `~/.claude/ide/*.lock` is deliberately not used: it outlives a turn by
hours and says nothing about whether work is in flight.

### 4. `~/.claude.json` — picking a working directory

`TerminalCLI.claudeTrustedDirectory()`. The CLI draws a blocking "is this a project you
trust?" prompt instead of the panel in an untrusted directory, so a `/usage` run
is chdir'd into the first still-existing directory in `projects` with
`hasTrustDialogAccepted == true` (sorted, for a stable choice). Only that one
key is decoded. No trusted project → `PanelError.noTrustedDirectory`, which is
fatal: unlike a timeout or a login prompt, it cannot resolve on its own.

---

---

## Codex

Not the same pattern. Codex ships a JSON-RPC server in the same binary as the
TUI, so nothing here drives a terminal: the limits are asked for and answered as
numbers. Codex also states them in its own rollout logs, so the RPC read is not
how the figure is normally learned — it is how the figure stays true when the
work happened somewhere that writes no log here (the Codex desktop app, the web
app, a cloud task), and it is the only place the credit budget appears at all.

| # | Flow | Reads | Mechanism | Cadence |
|---|---|---|---|---|
| 1 | Percentages, plan, credit budget | `codex app-server` | `Process` + JSON-RPC on a pipe | only once the logs go quiet, ≥ 30 min |
| 2 | Percentages, volume, models, projects | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | incremental byte cursors + FSEvents | 5 s tick, gated |

Nothing in `~/.codex/config.toml` is read any more: an RPC read needs no trusted
project to start in, because it starts no session.

### 1. `codex app-server`

`TokenPacer/Services/CodexAppServer.swift` → `TokenPacer/Core/Ingest/CodexUsagePanel.swift`

`codex -s read-only -a never app-server`, newline-delimited JSON on stdin and
stdout. Three lines go in and one matters:

```
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"Token Pacer","version":"1"}}}
{"method":"initialized","params":{}}
{"id":2,"method":"account/rateLimits/read","params":{}}
```

The binary is found under `$TOKENPACER_CODEX_BIN`,
`~/.codex/packages/standalone/current/bin`, `~/.local/bin`, Homebrew,
`/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin` — the same search as before.
`-s read-only -a never` is belt and braces: nothing here asks the server to run
a turn, and a background usage read must not be able to.

Three things the transport has to get right:

- **Replies come back out of order.** An unauthenticated server answered the
  rate-limit read *before* the initialize sent ahead of it, and notifications
  like `remoteControl/status/changed` carry no id at all. The id is how the
  right line is found.
- **stdin stays open until the answer is in hand.** The server exits the moment
  it reads EOF, and it does that well before the round trip to OpenAI comes
  back. Closing the handle is how the child is told to stop — which is also what
  unblocks the reader when the budget runs out, since a `read(2)` in flight on a
  pipe does not notice a cancelled `Task`.
- **`CODEX_*` is left alone.** A TUI run strips it so the child behaves like any
  other session; here `CODEX_HOME` is *which account is being asked about*, and
  `AgentHome` reads that same one's logs.

What comes back, and what is taken from it:

```json
{"id":2,"result":{"rateLimits":{
  "primary":   {"usedPercent":0,"windowDurationMins":300,  "resetsAt":1789981987},
  "secondary": {"usedPercent":4,"windowDurationMins":10080,"resetsAt":1790428515},
  "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},
  "individualLimit":null,
  "planType":"plus"}}}
```

Used percent, not left. The window states its own length, the reset is a Unix
stamp, and the plan is lowercase on the wire and capitalised for display. Not
decoded: `credits.balance` (a remaining balance with no cap, which nothing here
has a row for), `rateLimitsByLimitId`, `rateLimitResetCredits`, `accountId`.

#### The credit budget

`individualLimit` is the account's monthly credit budget — an Enterprise
workspace metered in credits reports one and no windows at all. It is carried
as `Spend`, and for an account with no five-hour window it also stands in as
the headline window.

Both sides of the ratio arrive and they need not agree, so each fact takes the
field that states it:

| Shown | Comes from | Why |
| --- | --- | --- |
| the amount, `33,140 of 40,000` | `used`, then `limit` | derived from `remainingPercent` only when absent |
| the percentage | `100 - remainingPercent` | derived from `used / limit` only when absent |

The percentage is the server's, not a ratio worked out here. A ratio would
disagree with the figure Codex itself reports, and at a tone threshold that is
the difference between amber and red — being right about 89.6 against a source
that says 90 is not worth showing a different colour for. The `/status` parser
this replaced preferred the ratio and was right to: the panel printed a rounded
whole number, so the pair was strictly finer. That was an artefact of rendering
a screen, and the RPC field is a `Double`.

**Thirty days is claimed, not stated.** The reply gives the budget no length,
and a calendar month is 28 to 31 days. `windowMinutes` is set to 43,200 anyway
because the span is load-bearing — `SnapshotBuilder` measures the panel's
splits back from the reset by exactly it, and without one they fall back to a
five-hour window the account does not have and read "no open window" for days.
CodexBar, which has no such span to feed, leaves it nil and labels the lane
"Monthly credit limit" instead of "Monthly". Here the headline tag reads
`MONTHLY` and the cell beside it reads `Plan credits · month to date`, so the
approximation never has to carry the meaning on its own.

Not signed in, the reply is an error object reading `codex account
authentication required to read rate limits` — surfaced as
`PanelError.notSignedIn`, the same as a `/login` prompt on a TUI.

**When it runs.** `PanelPoller` is shared with Claude, and a log-stated reading
counts as a run: while Codex is working, its rollout logs keep the reading fresh
and nothing is ever spawned. Only once those have been quiet for the idle floor
(30 min) does an RPC read happen, and a reading that then comes back *higher*
with no local tokens to explain it puts the poller back on the 5-minute floor —
that is what tracking a desktop-app or cloud session looks like from here.

### 2. Rollout logs

`TokenPacer/Core/Ingest/CodexSource.swift` — unchanged by any of this. Reads
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` with the same cursors, prefilter
and FSEvents gate as Claude's transcripts, and decodes four line types:
`session_meta` and `turn_context` for the working directory, `token_usage_record`
for the counts, and `event_msg`'s `token_count` for `rate_limits` — the same
windows `account/rateLimits/read` answers with, stated verbatim.

Nothing else in `~/.codex` is opened: not `auth.json`, not the sqlite stores
(`thread_history_1`, `state_5`, `logs_2`), not `history.jsonl`, not
`session_index.jsonl`.

---

---

## Copilot

| # | Flow | Reads | Mechanism | Cadence |
|---|---|---|---|---|
| 1 | Plan budget | the `copilot` binary's `/usage` screen | pty + `posix_spawn` | idle floor only, ≥ 30 min |
| 2 | Volume, models, projects, sessions running now | `~/.copilot/data.db` | SQLite, read-only | a `stat` per tick, queried only when it moved |

### The `/usage` panel

`TokenPacer/Services/TerminalCLI.swift` → `TokenPacer/Core/Ingest/CopilotUsagePanel.swift`

Same driver again, started in Copilot's own store (`COPILOT_HOME`, else
`~/.copilot`) with `--disable-builtin-mcps --no-auto-update`: the first halves a
23-second boot, the second keeps a background read from downloading a new CLI
behind your back. Nothing here ever sends a prompt, so no model call is made and
no tool runs. What it parses is one row:

```
   Plan ████████████████████ 39% used  7,074 / 18,000 AIC
```

The percentage, and the credits as a used-of-limit pair. `AI Credits 0 (24s)` on
the line above is what *that* conversation spent and is deliberately not read.
Copilot has no five-hour or weekly window, so this is the only figure, and the
reset is inferred as the month boundary — the panel never prints the billing
anniversary.

### The sessions table

`TokenPacer/Core/Ingest/CopilotSource.swift`

`data.db` keeps one row per session, rewritten in place:

```
sessions(id, model, updated_at, is_running,
         total_input_tokens, total_output_tokens,
         total_cached_tokens, total_reasoning_tokens)
```

joined through `workspaces.session_id` → `projects` for the repository it was
opened in, which gives `owner/name` rather than a folder. It is opened
read-only with `SQLITE_OPEN_READONLY` and never written to, not even to
checkpoint; the connection is opened only when the store or its `-wal` has
moved.

`total_cached_tokens` is part of `total_input_tokens`, so it is subtracted and
only the fresh remainder is charged as input — exactly as Codex needs. There is
no cache-write column, so a write is counted as plain input rather than
invented.

**Totals, not requests.** The row states what the session has spent since it
opened, so the *growth* between two reads is the event and the totals
themselves never are. Two consequences, both deliberate:

- A session met for the first time is **baselined, not counted**. Its totals are
  however long it has been running, and landing a week of tokens on today is
  worse than missing them.
- Copilot's sparkline and splits are as fine as the poll, where Claude's and
  Codex's are as fine as the request. Nothing finer is left on disk.

The watermark — how much of each session is already spent as events — rides in
the event id (`copilot:<session>:<in>-<out>-<cached>-<reasoning>`), because
`UsageSource` persists byte offsets and a running total is not one. `restore`
hands back the archived ids, and an id *is* the watermark. A session whose
events have all aged out of retention comes back unknown and is baselined again.

`is_running` is the live flag behind the activity dot, believed only while the
row is still moving: it outlives a session killed mid-turn, so the same 15-minute
in-flight cap every other provider uses applies to `updated_at`.

### What moved, and when

Both of Copilot's older surfaces went quiet under CLI 1.0.8x, and the app read
them until this was rewritten:

- `session-store.db` → `assistant_usage_events`, a row per request, **last
  written 11 Sep 2026**. The table is still there; nothing appends to it.
- `open-sessions-state.json` is still written, but only once, at session open.
  `refreshedAt` never advances past `openedAt`, and `working` was `false` in all
  109 entries on the machine this was rewritten against — so a dot waiting for
  that flag could never light.

Neither is read any more. History already ingested from `assistant_usage_events`
survives in this app's own event archive until retention drops it.

### Not read

`~/.copilot/session-store.db` and `open-sessions-state.json` — see above.
Within `data.db`, only `sessions`, `workspaces` and `projects` are read;
accounts, activity items, review threads and workspace state are not. The
desktop app's local daemon (`~/.copilot/run/ws.port`, `ws.token`) is not spoken to at all: it serves
only the app it belongs to, and reaching into it would mean reverse engineering a
private socket whose port and token rotate (ARCHITECTURE.md §1.1).

---

### Not accessed

- No Anthropic API or OAuth endpoint, no token, no Keychain, no `setup-token`.
- No network traffic of this app's own at all, except Sparkle's update feed.
- No prompt or response text, ever — and no token is logged (`Log`, `os.Logger`, `.public` on safe values only).
- Codex: `auth.json`, the sqlite stores, `history.jsonl`, `session_index.jsonl` — and `codex exec`, which would cost a model call.
- Copilot: `session-store.db` (prompts and replies in full live in its `turns` table), `open-sessions-state.json`, `config.json`, the chat store, the logs, and the desktop app's daemon socket.

# What Token Pacer reads from your agents

Every path by which this app learns anything about your usage. Four flows for
Claude Code, three for Codex, one for Copilot, all read-only: nothing under
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

The same pattern, bought for a different gain. Codex states its limits in its
own rollout logs, so the `/status` panel is not how the figure is normally
learned — it is how the figure stays true when the work happened somewhere that
writes no log here: the Codex desktop app, the web app, a cloud task.

| # | Flow | Reads | Mechanism | Cadence |
|---|---|---|---|---|
| 1 | Percentages, plan | the `codex` binary's `/status` screen | pty + `posix_spawn` | only once the logs go quiet, ≥ 30 min |
| 2 | Percentages, volume, models, projects | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | incremental byte cursors + FSEvents | 5 s tick, gated |
| 3 | Where to run the CLI | `~/.codex/config.toml` | one regex per `/status` run | per run |

### 1. The `/status` panel

`TokenPacer/Services/TerminalCLI.swift` → `TokenPacer/Core/Ingest/CodexStatusPanel.swift`

Same driver as Claude's, with a different `Spec`: binary `codex` (found under
`$TOKENPACER_CODEX_BIN`, `~/.codex/packages/standalone/current/bin`,
`~/.local/bin`, Homebrew, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`),
command `/status`, marker `limit:`.

Two things the shared driver had to learn for it:

- **The command and the newline are two writes.** Typing `/status` opens a
  completion popup that swallows a newline arriving in the same read, and the
  command then sits in the composer until the budget runs out. Measured on Codex
  0.155; the driver now waits for the popup to finish drawing before submitting.
- **The marker is searched only in what arrives after the ask.** The TUI's status
  line already carries `5h 100% left · weekly 43…` at boot, so a marker matched
  against the whole stream would fire before the panel exists.

What it renders, and what is parsed:

```
 Account:      someone@example.com (Plus)
 5h limit:     [████████████████████] 100% left (resets 03:59 on 19 Sep)
 Weekly limit: [█████████░░░░░░░░░░░] 43% left (resets 15:23 on 19 Sep)
```

The plan, never the address. Note it counts what is **left**, not what is used,
and its reset stamps are local, 24-hour and often dateless — the CLI has already
converted them, so no timezone is printed. No credit row: the panel points at
chatgpt.com for that.

**When it runs.** `PanelPoller` is shared with Claude, and a log-stated reading
counts as a run: while Codex is working, its rollout logs keep the reading fresh
and nothing is ever spawned. Only once those have been quiet for the idle floor
(30 min) does a `/status` run happen, and a reading that then comes back *higher*
with no local tokens to explain it puts the poller back on the 5-minute floor —
that is what tracking a desktop-app or cloud session looks like from here.

### 2. Rollout logs

`TokenPacer/Core/Ingest/CodexSource.swift` — unchanged by any of this. Reads
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` with the same cursors, prefilter
and FSEvents gate as Claude's transcripts, and decodes four line types:
`session_meta` and `turn_context` for the working directory, `token_usage_record`
for the counts, and `event_msg`'s `token_count` for `rate_limits` — the figures
`/status` draws, stated verbatim.

Nothing else in `~/.codex` is opened: not `auth.json`, not the sqlite stores
(`thread_history_1`, `state_5`, `logs_2`), not `history.jsonl`, not
`session_index.jsonl`.

### 3. `~/.codex/config.toml` — picking a working directory

Codex refuses to start in a directory it has not been trusted in, exactly as
Claude does. The file is TOML:

```toml
[projects."/Users/me/code/thing"]
trust_level = "trusted"
```

Matched with a regex rather than decoded — a TOML parser is a dependency for one
key of one table, and everything else in that file (models, hooks, MCP servers,
sandbox policy) is none of this app's business. First still-existing trusted
path, sorted, so the choice is stable between runs.

---

---

## Copilot

One flow, and no logs at all.

| # | Flow | Reads | Mechanism | Cadence |
|---|---|---|---|---|
| 1 | Plan budget | the `copilot` binary's `/usage` screen | pty + `posix_spawn` | idle floor only, ≥ 30 min |

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

### Not read

`~/.copilot/data.db` is opened by nothing here. In CLI 1.0.86 it holds sessions,
context-window rows and workspace state — no per-request token rows — so Copilot
contributes no sparkline, no splits and no history, and the card shows those
sections empty rather than filled from somewhere else. The desktop app's local
daemon (`~/.copilot/run/ws.port`, `ws.token`) is not spoken to at all: it serves
only the app it belongs to, and reaching into it would mean reverse engineering a
private socket whose port and token rotate (ARCHITECTURE.md §1.1).

---

### Not accessed

- No Anthropic API or OAuth endpoint, no token, no Keychain, no `setup-token`.
- No network traffic of this app's own at all, except Sparkle's update feed.
- No prompt or response text, ever — and no token is logged (`Log`, `os.Logger`, `.public` on safe values only).
- Codex: `auth.json`, the sqlite stores, `history.jsonl`, `session_index.jsonl` — and `codex exec`, which would cost a model call.
- Copilot: `data.db`, `config.json`, the chat store, the logs, and the desktop app's daemon socket.

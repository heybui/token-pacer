# Token Pacer

Claude Code and Codex usage, live in the notch.

## Prerequisites

### To run the app

| | |
|---|---|
| macOS | 15 (Sequoia) or later — `LSMinimumSystemVersion` 15.0 |
| Mac | Any. A notched Mac hides the shell behind the hardware; on an external display or a pre‑2021 Mac the pill just docks top‑centre in the menu bar row |
| Permissions | **None.** Not sandboxed, no Accessibility, no Screen Recording, no Automation. Full‑screen is detected from the menu bar, not by enumerating windows |
| Notifications | Optional. Asked for on the first time you cross a threshold, never at launch. Denied just means no banner |
| Disk | `~/Library/Application Support/TokenPacer/` for the archive and the instance lock; `~/Library/Preferences/com.redevify.token-pacer.plist` for settings |

### To have anything to show

At least one provider's logs must exist. Nothing is installed, nothing is asked
for — the app only reads files that are already there:

- **Claude Code** — `~/.claude/projects/<slug>/<uuid>.jsonl`. Gives volume,
  models and projects.
- **Codex** — `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Gives volume *and*
  its own rate limits, which it states verbatim.

A provider whose directory does not exist contributes nothing — no error, no
prompt. Either one can also be switched off in Preferences → General, which
stops it being polled at all.

### For the Claude percentage figure

Claude Code publishes no rate‑limit state in its logs, so the percentage comes
from the CLI's own `/usage` panel. That needs both:

1. The `claude` binary on disk. A GUI app inherits launchd's bare `PATH`, so it
   is looked up by full path: `~/.local/bin`, `~/.claude/local`,
   `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`.
   Elsewhere → set `TOKENPACER_CLAUDE_BIN=/path/to/claude`.
2. **One trusted project directory** in `~/.claude.json`
   (`hasTrustDialogAccepted: true`). The CLI refuses to start anywhere else — it
   draws the trust prompt instead of the panel. Run `claude` once in any project
   and answer it.

Without these, everything else still works; only the percentage is missing.

### To build

| | |
|---|---|
| Xcode | 16 or later (Swift 6 toolchain, `swift-tools-version: 6.0`) |
| Network | First build resolves **Sparkle** 2.6+ from SPM. The only dependency |
| Xcode.app | Only for `make xcbuild` / `xctest`. `swift build` and `make app` need the command‑line tools alone |

```sh
make run     # debug, runs in place (sets DYLD_FRAMEWORK_PATH for Sparkle)
make test    # swift test
make app     # assembles build/TokenPacer.app, signed with the first codesigning
             # identity found, or ad-hoc if there is none
```

Running in place (`swift run`) is not a bundle, and two things degrade:
**notifications** are skipped entirely (`UNUserNotificationCenter` traps outside
a bundle) and **launch at login** reports disabled (`SMAppService` needs a signed
bundle). Use `make app` when either one matters.

### To cut a release

Only needed for `make release` — see the Makefile:

- A paid Apple Developer Program membership and a **Developer ID Application**
  certificate in the Keychain (an Apple Development one cannot be notarized).
- `xcrun notarytool store-credentials token-pacer`, once.
- The Sparkle EdDSA private key in the login Keychain as *"Private key for
  signing Sparkle updates"*. It is not in this repo and cannot be recovered.
- `gh` authenticated, plus `../tokenpacer.com` and `../homebrew-tap` checked out
  beside this repo.

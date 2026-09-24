# Token Pacer

Claude Code, Codex and Copilot usage, live in the notch.

The figures already exist — each CLI draws them on `/usage`, or answers for them
over its own JSON-RPC — but
you have to stop and ask. Token Pacer keeps them in front of you: a mark, the
percentage and the time to your next reset, in the menu bar, all day. It asks for
no account, no API key and no system permission; it spawns the CLI you already
trust and reads the answer it already has.

- **What it is and why it's built this way** — [docs/PRD.md](docs/PRD.md)
- **How it's built** — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Every file it reads off your disk** — [docs/ACCESS.md](docs/ACCESS.md)

## Running it

| | |
|---|---|
| macOS | 15 (Sequoia) or later |
| Mac | any. A notched Mac hides the shell behind the hardware; elsewhere the pill docks top-centre in the menu bar row. Settings → Show on picks the display |
| Permissions | **none.** Not sandboxed, no Accessibility, no Screen Recording, no Automation |
| Alerts | none from macOS. The pill opens by itself when a provider crosses a mark, so there is no notification permission to ask for |

To see anything, at least one provider's logs must exist —
`~/.claude/projects/…jsonl`, `~/.codex/sessions/…jsonl` or
`~/.copilot/data.db`. To see its **percentage**, that provider's CLI must be on
disk in a known location (or named by `TOKENPACER_CLAUDE_BIN` /
`TOKENPACER_CODEX_BIN` / `TOKENPACER_COPILOT_BIN`), and Claude needs one
directory you have already answered its trust prompt for — Codex and Copilot
answer over JSON-RPC and start no session. Without that, everything else still
works — only that row's percentage is missing.

## Development setup

Xcode 26 or later — older toolchains fail on SwiftUI isolation this relies on.
**Sparkle** is the only dependency and it is checked in under `Vendor/Sparkle`,
so a clone builds with nothing to download.

```sh
git clone <this repo> && cd token-pacer
make run     # debug build, runs in place (sets DYLD_FRAMEWORK_PATH for Sparkle)
make test    # swift test
make app     # assembles build/TokenPacer.app, signed with the first identity found
```

Two build systems over one set of folders, so they cannot drift:

- `swift build` / `swift test` — the fast terminal loop.
- `xcodebuild -scheme TokenPacer build|test` — the shipping path (signing,
  entitlements, hardened runtime). Uses synchronized folder groups, so **adding a
  file needs no project edit**.

Running in place is not a bundle, so **launch at login** reports disabled
(`SMAppService` needs a signed bundle). Use `make app` when that matters.

Useful while working:

```sh
TP_OPEN_PREFS=1 build/TokenPacer.app/Contents/MacOS/TokenPacer   # straight to Preferences
TOKENPACER_PANEL_DUMP=/tmp/panels make run                       # dump every CLI screen read
swift run TokenPacer --probe                                     # parse the logs, print, exit
swift run TokenPacer --raw                                       # every provider's reply, verbatim
```

Conventions for anything committed here are in [CLAUDE.md](CLAUDE.md) — commit
format, the Swift and SwiftUI rules, and the one that matters most: `Core/`
imports Foundation and `os` only.

## Releasing

`make release VERSION=x.y.z` — notarize, sign the appcast, update the cask.
Requires a Developer ID Application certificate, stored notary credentials and
the Sparkle signing key. See §7 of [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Licence

Proprietary — see [LICENSE](LICENSE). Bundled third-party components keep their
own terms: Sparkle (MIT) and Instrument Sans (SIL OFL 1.1).

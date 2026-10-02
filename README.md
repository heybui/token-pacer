<div align="center">

# ⏱️ Token Pacer

**Your Claude Code, Codex and Copilot usage — live in the notch.**

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![No permissions](https://img.shields.io/badge/permissions-none-blue)

</div>

---

Stop typing `/usage` to check how much you have left.
Token Pacer shows it **all day, right in your menu bar**:

- 📊 **How much you used** — a percentage for each tool
- ⏳ **When it resets** — a countdown to your next window
- 🟢🟡🔴 **How close you are** — green is fine, amber is careful, red is almost out

No account. No API key. No system permission. It asks the CLI you already use
and shows you the answer.

## ✨ Why you'll like it

| | |
|---|---|
| 🔒 **Private** | Nothing leaves your Mac. See every file it reads in [docs/ACCESS.md](docs/ACCESS.md) |
| 🪶 **Light** | Sits quietly in the notch, uses almost no CPU |
| 🖥️ **Any Mac** | Notched Mac? It hides behind the notch. No notch? It sits top‑centre in the menu bar |
| 🔔 **Heads‑up** | Opens by itself when you cross a limit — no notification permission needed |

## 🚀 Install locally

You need **macOS 15+** and **Xcode 26+**. Nothing else to download — the only
dependency (Sparkle) is already in the repo.

```sh
# 1. Get the code
git clone https://github.com/heybui/token-pacer.git
cd token-pacer

# 2. Build the app
make app

# 3. Put it in Applications and open it
cp -R build/TokenPacer.app /Applications/
open /Applications/TokenPacer.app
```

That's it. Look at the top of your screen. 🎉

> 💡 **Just want to try it?** `make run` starts it straight from the source,
> no install. (Launch at login only works from the installed app.)

### What it needs to show numbers

Token Pacer reads what your tools already save. Use at least one of them:

| Tool | Where it looks |
|---|---|
| Claude Code | `~/.claude/projects/` |
| Codex | `~/.codex/sessions/` |
| Copilot | `~/.copilot/data.db` |

To show the **percentage**, the tool's CLI must be installed. If it lives
somewhere unusual, point to it with `TOKENPACER_CLAUDE_BIN`,
`TOKENPACER_CODEX_BIN` or `TOKENPACER_COPILOT_BIN`.

## 🛠️ For developers

```sh
make run     # debug build, run in place
make test    # run the tests
make app     # build build/TokenPacer.app
```

Handy extras:

```sh
swift run TokenPacer --probe                 # read the logs, print, exit
swift run TokenPacer --raw                   # show each tool's raw reply
TOKENPACER_PANEL_DUMP=/tmp/panels make run   # save every CLI screen it reads
```

Want to dig deeper?

- 📘 **What and why** — [docs/PRD.md](docs/PRD.md)
- 🏗️ **How it's built** — [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 📏 **Code rules** — [CLAUDE.md](CLAUDE.md)

Releasing: `make release VERSION=x.y.z` (needs a Developer ID certificate —
see §7 of [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

## 📄 License

[MIT](LICENSE) © 2026 Hey Bui — free to use, change and share.

Bundled parts keep their own licenses: Sparkle (MIT) and Instrument Sans
(SIL OFL 1.1).

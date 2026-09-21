# Release notes

What you type in the release form is the release notes. It is not a changelog
for this repo — it lands in three places, all of them read by people running the
app:

| Where | Looks like |
|---|---|
| Sparkle's update dialog | a ~400pt scrolling panel, above **Install Update** |
| `tokenpacer.com` release page | the public download, the only one anyone can reach |
| the release in this repo | where you wrote it |

The pipeline copies the body verbatim — `gh api /markdown` renders it with
GitHub's own renderer, so what the release page shows is what the dialog shows.
Nothing is generated and nothing is filtered: an empty body ships a release with
no description at all.

## The template

Copy from inside the block, delete what does not apply.

```markdown
⚡ **One line saying what this release is for.**

### ✨ New
- 🚀 

### 🔧 Fixed
- 🐛 
```

## How to fill it

- **The first line is the whole story.** Most people read it and press Install.
  "Copilot is tracked alongside Claude and Codex." — not "Version 0.3.0".
- **Write the change, not the commit.** "The notch keeps its place after the lid
  opens", not "fix(notch): re-anchor on screen change". Nobody outside this repo
  knows what a scope is, and the log is not on the other side of that dialog.
- **Three to seven bullets.** A list longer than the panel gets scrolled past.
  Roll the small things into one: "Assorted fixes to the panel readers."
- **Drop the section that is empty.** A "Fixed" heading with nothing under it
  reads as something that failed to load.
- **Anything that needs a decision goes first**, on its own, as
  `⚠️ **Heads up:** …` — a preference that resets, a CLI version now required.
- **One emoji per line, and it has to earn its place.** The 1.0 notes set the
  voice and the dialog is a wall of grey text at that size: a glyph at the head
  of each bullet is what makes it scannable. Pick one that says what the change
  is about — 💳 for credits, 📊 for a figure, 🧹 for a sweep of small fixes —
  never a decorative ✅ or 🎯 on every line. Two in one bullet is noise, and an
  emoji mid-sentence is worse than none.
- **Close with the feedback line.** `💬 Tell me what breaks:
  https://tokenpacer.com/#feedback` — the notes are the only place most people
  will ever be invited to answer back.

## What breaks in the dialog

- **No `#123`, no `@name`.** This repo is private: the autolink points at
  something the reader cannot open, and a mention leaks a handle to everyone.
- **Absolute `https://` links only.** A relative path resolves against the
  release page, not the app, and 404s for every reader.
- **`###` and lists.** `#` and `##` are shouting at that size; tables run off
  the side; an image has to be a public URL and is usually a scroll of nothing.
- **No screenshots of internal tooling** — the notes are public the moment the
  site release is created.

## A good one

```markdown
🎉 **Copilot joins Claude and Codex in the notch.**

### ✨ New
- 📊 Copilot's usage panel is read alongside the others; pick which provider the
  pill shows in Preferences → Providers.
- 🕒 The card says how old each reading is, so a frozen number is never mistaken
  for a current one.

### 🔧 Fixed
- 🖥️ The notch no longer loses its place when an external display wakes up.
- ⚠️ A provider that cannot be read says so in its own row instead of blanking
  the whole card.

💬 Tell me what breaks: https://tokenpacer.com/#feedback
```

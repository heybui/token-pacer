# Token Pacer — product

What the app is, who it is for, and every decision that is a product decision
rather than an implementation one. The technical spec lives in
[ARCHITECTURE.md](ARCHITECTURE.md); what the app reads off your disk is
enumerated in [ACCESS.md](ACCESS.md).

Design source: the **macOS notch usage tracker** project in Claude Design, board
"Token Pacer". Read it from there, never from a checkout — an export in the repo
went stale inside a day the one time it was tried.

## The problem

You run coding agents all day. Each one has a quota, each quota is on a
different clock, and the only way to see any of them is to stop what you are
doing and ask the CLI. So you find out you are at 94% by being told you are at
100% — usually mid-task, usually on the one afternoon it matters.

The figures exist. Claude Code draws them on `/usage`; Codex and Copilot answer
for them over their own JSON-RPC. Nothing keeps them in front of you.

## The product, in one line

The notch shows how much of your agent quota is left, always, without being
asked.

## Who it is for

One person: someone running Claude Code, Codex or Copilot on a Mac for hours at
a time, who would change what they do if they knew they were near the cap. Not
teams, not billing administrators, not dashboards. There is no account, no
sign-in and no server — this is a thing that watches your own machine.

## The four rules

Everything below follows from these, and every future feature is checked against
them.

1. **Never invent a number.** Every percentage on screen is the provider's own,
   read from where that provider already keeps it. A provider whose figure
   cannot be read gets `--`, not an estimate. The app once inferred a ceiling
   from log volume; it read ~70% high and is deleted. A wrong number is worse
   than no number, because a wrong one is acted on.
2. **Less is the product.** The menu bar is 37pt tall and shared with every
   other app. What goes there is one mark, one figure and one countdown. Every
   request to add a second thing to the band has been refused — the stacked
   two-provider row, the weekly dot, the raw token count — and the comparison
   lives in the card instead.
3. **Ask for nothing.** No account, no API key, no token of our own, no
   Accessibility, no Screen Recording, no Automation, no notification
   permission, and no network call but the update check. The app asks the CLI
   you already trust, and reads the answer it already has.
4. **The state is in the notch, and so is the moment.** The notch always
   carries where you are, and opens by itself only for the two transitions that
   change what you should do — crossing watch, crossing over. It waits there
   until you look; there is no banner.

## The zone rule

One scale, applied everywhere — the mark, the border, the card, the banner and
the icon. There is exactly one function that decides it.

| | |
|---|---|
| **Safe** | below the watch threshold — green `#3ec98a` |
| **Watch** | watch → over — amber `#e8b33c` |
| **Over** | above the over threshold — red `#e2543f` |

Defaults 75 / 90, set per provider on its own two-handle track where watch can
never pass over: a row read against another provider's marks is coloured by a
rule that does not apply to it. Moving a handle moves that provider's capsules,
the colour of its border and the point the pill opens, together.

## What you see

### The band — always on screen

Seven states, one object. On a notched Mac the shell spans the hardware and the
figures sit in the wings either side; off one it is a single 226 × 36 row docked
top-centre. Settings picks the display — Automatic is the notch, or the main
screen without one — and a chosen monitor that is unplugged hands the pill back
to Automatic until it returns.

| State | What it says |
|---|---|
| **Hidden** | nothing is running and you asked for quiet — the menu bar reads as stock hardware |
| **Ghost** | resting at 45%, showing the weekly cap |
| **Collapsed** | the normal one: mark and percentage left, time to reset right |
| **At the cap** | a red dot and the countdown in red — at 100% there is nothing to report but the wait |
| **Hover card** | one row per provider on one scale, each with its own reset and its own sessions working |
| **Warning** | whichever provider crossed: its mark at twice the size, the percentage, the countdown, one line |
| **Pinned panel** | the provider picker as its title, the sparkline, splits by model, project and kind, 90-day history |

Hover opens the card, and clicking a provider's row puts it in the band — the
choice is made where the three stand side by side. Double-click pins the panel —
a single click was tried and reverted; the menu bar is a strip people click at
all day. Esc or a click outside closes it. Right-click opens the menu:
Preferences, Check for updates, Send feedback, Quit.

The right wing can end in one badge: a triangle while any provider cannot be
read, otherwise the count of sessions answering on the pinned provider. A
waiting build is not a third contender — it keeps, so it is an Install button in
the card's footer, beside Settings and Open the panel. While anything is failing,
Check again takes the place of the card's "Updated …" line.

### The mark — twelve of them

The lead figure is a **mark**, chosen in Preferences, drawn at menu-bar size.
Default **Capsule bar**.

Capsule bar · Ring wings · Notch tank · Pips · Half gauge · Eclipse · Token
stack · Hourglass · Dotted arc · Dot matrix · Signal strength · Thermometer.

Two rules run through all twelve:

- **The track is the scale, the marker is the reading.** The bar is not a fill.
  It is three static capsules — safe, watch, over — with a marker riding at the
  provider's position, so the mark and the border can never disagree about the
  zone.
- **The mark carries "working".** Each one animates on its own mechanism while a
  model is answering: the next increment charges, a meniscus bobs, a grain
  falls, a shadow creeps. Never a shared blink.

The expanded card keeps the capsule bar whatever the band wears. Its rows are a
comparison down one column, which is the job position-on-a-line does best; the
choice dresses the menu bar, where space is the constraint.

### The running border — twelve of those too

A light runs the shell's outline while a model is answering, in the zone's
colour: Comet (default), Dual comet, Zone sweep, Marching dashes, Pulse wave,
Quarter trace, Counter pair, Breathe, Breathe glow, Edge runners, Side drip,
Bottom sweep. One switch turns the whole group off.

The top edge is never lit — it lies against the hardware — and the light runs
*outside* the shell, on the desktop side of the edge, so it reads as an outline
rather than as a second border drawn inside the black.

### Preferences — two panes

**General.** *Providers*: every CLI found on this Mac is tracked, and there is no
switch to track one. Each row carries that provider's own two-handle track, a
button that gives the others the same marks, and a tick for whether it has a row
on the card; a CLI that is missing says so and links to its install page. Reset
alert configuration puts the marks and both alert switches back. *Alerts*: tell
me at watch and over, and play a sound with it (greyed out with the first off —
a sound with nothing on screen to explain it is a noise). *App*: which display
shows the pill, launch at login, minutes of quiet before the pill hides (0 never
hides), update automatically. A language picker appears on its own once a
second language ships. The footer carries the version, Check for updates,
Diagnostics — every provider's raw reply, with the account id and home paths
stripped — and Send feedback.

**Appearance.** Two grids of twelve, drawn live at real size and walked from 0 to
100% so you pick a mark by watching it work rather than by reading its name. Plus
the two switches that change what the band *holds* rather than how it looks: the
percentage beside the mark and the count of sessions working, both on by
default.

### Alerts

No banner, and no permission to ask for one. When any tracked provider crosses
its watch or its over mark, the pill opens into the warning card by itself —
pinned provider or not — and holds there until the pointer comes near: reading
it is answering it. Each mark fires once per window. The card names the
provider and says the percentage, the time to reset and one line — "still room"
past watch, "wrap up soon" past over. The sound is optional.

## What each provider gives you

| | Session window | Week | Other |
|---|---|---|---|
| **Claude Code** | 5-hour rolling %, to the whole point | weekly cap % | monthly credit spend, where the account buys past the plan |
| **Codex** | 5-hour % | weekly % | the plan name; a workspace metered in credits reports a monthly credit budget instead, and that becomes the headline |
| **Copilot** | — | — | one monthly plan budget in credits, e.g. `7,074 / 18,000 AIC` |

All three also contribute the sparkline, the splits by model, project and kind,
and the 90-day history, from what they already write locally — Claude and Codex
their session logs, Copilot its `data.db`. What they write also says which
sessions have a model answering right now, and that is what the job count
counts.

A provider's directory that does not exist contributes nothing — no error, no
prompt, no row.

## What it deliberately does not do

Each of these was built or specified, then cut. They are listed so they stop
reading as missing features.

- **No estimates, no burn rate, no "minutes of headroom."** A countdown to a
  reset is a fact; headroom was three guesses stacked. Nothing states a rate of
  consumption.
- **No usage from the web app, the desktop app or cloud tasks.** They spend the
  same quota and leave nothing on your disk. The panel readings catch the total
  when they refresh; nothing local can attribute it. This is the product's
  largest open hole.
- **No modelling of anyone's quota.** Three providers, three periods, three
  units. An app that models them is three times wrong the week any one changes.
- **No global hotkey.** ⌘⇧B needed a Carbon registration or the Accessibility
  permission. The pill is a click away.
- **No Reduce Motion branch.** The animations ship unconditionally.
- **The left wing does not yield to app menus.** Knowing how wide another app's
  menus are needs Accessibility. One system prompt is too much to pay for one
  app's worth of politeness; a very long menu bar overlaps the left wing.
- **No flat bar row.** The board asked for the figures drawn straight onto the
  menu bar with no shell. Built, put on screen, reverted the same hour: the menu
  bar is translucent, so the figures landed on the wallpaper with the camera as
  a gap between them. The black band is what welds both wings and the hardware
  into one object.

## Where it stands

| | |
|---|---|
| The band, all seven states | ✅ on screen, against live figures |
| Three providers | ✅ Claude, Codex, Copilot |
| Twelve marks, twelve borders, both grids live | ✅ |
| Preferences, alerts in the pill, launch at login | ✅ |
| Pinned panel — sparkline, splits, history | ✅ |
| In-app updates | ✅ Sparkle, automatic checks on by default |
| Release — notarized DMG, appcast | ✅ cut by CI on a published release, served from tokenpacer.com |
| Homebrew cask | 🔨 written every release, published only when the tap is checked out beside this repo — CI has none |

## Open questions

- **Web and desktop-app spend is invisible.** No local artefact records it. The
  only honest handling today is that the panel reading jumps when it refreshes.
- **Copilot's reset date is inferred** from the month boundary. GitHub knows the
  billing anniversary; `account.getQuota`'s `resetDate` states when the quota
  was read, not when it refills. The day it points forward, the inference goes.
- **Copilot's figure has no second opinion.** If `account.getQuota` changes
  shape, that row goes to `--` with nothing behind it: `data.db` records its
  volume, never its quota.
- **`--` has to read as "not reported", never as "no usage."** The attention
  badge is what carries the difference, and it has never been tested on someone
  who did not build it.
- **The over state has never been seen on hardware.** It needs a window past 90%,
  which no run has reached.

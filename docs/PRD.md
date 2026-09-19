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

The figures exist. Claude Code draws them on `/usage`, Codex on `/status`,
Copilot on `/usage`. Nothing keeps them in front of you.

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
   Accessibility, no Screen Recording, no Automation, no network call. The app
   spawns the CLI you already trust and reads the screen it already draws.
4. **The state is in the notch; the moment is in the banner.** The notch always
   carries where you are. A banner fires only for the one transition that
   changes what you should do: going over.

## The zone rule

One scale, applied everywhere — the mark, the border, the card, the banner and
the icon. There is exactly one function that decides it.

| | |
|---|---|
| **Safe** | below the watch threshold — green `#3ec98a` |
| **Watch** | watch → over — amber `#e8b33c` |
| **Over** | above the over threshold — red `#e2543f` |

Defaults 75 / 90, both user-set on a single two-handle track where watch can
never pass over. Moving a handle moves the capsules on the mark, the colour of
the border and the point the banner fires, together.

## What you see

### The band — always on screen

Seven states, one object. On a notched Mac the shell spans the hardware and the
figures sit in the wings either side; off one it is a single 226 × 36 row docked
top-centre.

| State | What it says |
|---|---|
| **Hidden** | nothing is running and you asked for quiet — the menu bar reads as stock hardware |
| **Ghost** | resting at 45%, showing the weekly cap |
| **Collapsed** | the normal one: mark and percentage left, time to reset right |
| **Over · at the cap** | the same row, mark full, figure and countdown red |
| **Hover card** | one row per provider on one scale, each with its own reset |
| **Over** | the big percentage, the countdown, one coach line |
| **Pinned panel** | the sparkline, splits by model and project, 30-day history |

Hover opens the card. Double-click pins the panel — a single click was tried and
reverted; the menu bar is a strip people click at all day. Esc closes. Right-click
opens the menu: Preferences, Check for updates, Send feedback, Quit.

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

**General.** *Zones*: the two-handle track and a sentence saying what the numbers
do. *Alerts*: notify when over, sound when over (greyed out with the banner off —
a sound with nothing to carry it is nothing). *Providers*: one switch each; off
means that CLI is never asked anything, and the last one on cannot be turned off.
*App*: launch at login, minutes of quiet before the pill hides (0 never hides), check for updates
automatically, restore defaults — which restores every switch in both panes.

**Appearance.** Two grids of twelve, drawn live at real size and walked from 0 to
100% so you pick a mark by watching it work rather than by reading its name. Plus
the one switch that changes what the band *holds* rather than how it looks:
percentage beside the mark, on by default.

### Notifications

One banner, once per window, on going over only. Watch stays silent and visual —
the mark simply tints amber. The banner says the percentage, the time left and
one coach line. Permission is asked the first time you cross, never at launch;
denying it costs the banner and nothing else.

## What each provider gives you

| | Session window | Week | Other |
|---|---|---|---|
| **Claude Code** | 5-hour rolling %, to the whole point | weekly cap % | monthly credit spend, where the account buys past the plan |
| **Codex** | 5-hour % | weekly % | the plan name |
| **Copilot** | — | — | one monthly plan budget in credits, e.g. `7,074 / 18,000 AIC` |

Claude and Codex also contribute the sparkline, the model and project splits and
the 30-day history, all from their local logs. Copilot writes nothing readable,
so it is a single row with no history behind it.

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
| Preferences, notifications, launch at login | ✅ |
| Pinned panel — sparkline, splits, history | ✅ |
| In-app updates | ✅ Sparkle, automatic checks on by default |
| Release — notarized DMG, appcast, Homebrew cask | 🔨 pipeline built, blocked on a Developer ID certificate |

## Open questions

- **Web and desktop-app spend is invisible.** No local artefact records it. The
  only honest handling today is that the panel reading jumps when it refreshes.
- **Copilot's reset date is inferred** from the month boundary. GitHub knows the
  billing anniversary; the panel does not print it. The day it does, the
  inference goes.
- **A panel-only provider has no second opinion.** If Copilot's `/usage` screen
  changes, that row goes to `--` with nothing behind it. Claude and Codex at
  least keep logs.
- **`--` has to read as "not reported", never as "no usage."** The attention
  badge is what carries the difference, and it has never been tested on someone
  who did not build it.
- **The over state has never been seen on hardware.** It needs a window past 90%,
  which no run has reached.

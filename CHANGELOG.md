# Changelog

All notable changes to Liova are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Liova uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every pull request adds a line under **[Unreleased]** (CI checks this; maintainers can apply the
`skip changelog` label to changes users won't notice, like CI or refactors). When a version is
released, its section becomes the GitHub release notes.

## [Unreleased]

## [1.4.0] - 2026-11-14

### Added

- **Calls in the notch.** While you're on a call (WhatsApp, Zoom, FaceTime, Teams, Slack,
  Discord, Google Meet in your browser and more), the notch shows the app and how long the
  call has run, with **Mute** and **Hang Up** right there. Mute works in every app and is
  undone when the call ends. Hang Up presses the app's own button, so it needs Accessibility
  access. Turn it off in Settings → General.
- The heat alert finds what's warming your Mac when no single app is to blame: several apps
  adding up ("Your Mac is working hard", each one with its share and a Quit button), and
  macOS's own background work, like Photos analyzing your library or Spotlight indexing.
- The iOS Simulator counts as one app, with its devices and their apps, instead of five small
  processes.
- The heat alert speaks up sooner on a fanless Mac: apps adding up to one core are enough, an
  app hovering around the line keeps counting through small dips, and a Mac that's only warm
  (not yet hot) is listened to.
- Plugged in, a busy app is "warming your Mac"; on battery, it's "draining battery".

## [1.3.0] - 2026-11-13

### Added

- **Keyboard shortcuts** that work in every app: ⌃⌥N opens or closes the notch, ⌃⌥V opens
  Clipboard history. Change them, or turn them off, in Settings → General. If another app
  already uses one, Settings says so.
- Settings can be minimized (the yellow button, or ⌘M).

### Fixed

- Dropping a file on the open notch shows two large targets, Keep on Shelf and AirDrop, that
  fill the notch instead of leaving empty space.
- The status icons beside the camera no longer slide under it or past the edge when many are
  on: the camera and microphone become small dots first, then less important icons step aside.
- The open notch keeps its width when many pages are on.

## [1.2.0] - 2026-11-11

### Added

- **Clipboard history**: a Clipboard page in the notch keeps the last 30 things you copy (text,
  links, images and files). Click one to copy it again, drag it into any app, pin what you
  reuse. Kept in memory only, except what you pin; passwords and anything copied in a password
  manager are never kept. Turn it off in Settings → Activities.
- The Calendar page marks holidays and festivals from holiday calendars, and birthdays, so they
  don't read like your own plans, and says which day it shows.

### Fixed

- Page icons no longer sit under the camera when many pages are on: the extra ones move to
  the right of it.
- Long Settings tabs scroll instead of growing past the bottom of the screen.

## [1.1.0] - 2026-11-10

### Added

- **Glass notch**: choose Black or Glass in Settings → Notch. Glass shows the desktop through
  the open notch (Liquid Glass on macOS 26); closed, it stays black to match the camera.
- **What's using your Mac**: the System page lists the apps using the most CPU or memory, says
  when one is heating up the Mac or filling memory, and quits it (Force Quit if it hangs on).
- **Heavy-app alert**: when one app keeps the processor busy for minutes, or fills memory while
  it's running short, the closed notch shows its icon and the open notch offers to quit it.
  On by default; turn it off in Settings.
- The rain heads-up now shows rain (or snow) falling from the cloud.

### Changed

- Downloads and other activities fade and morph into place when they start, finish or take
  over from music, instead of snapping.

## [1.0.0] - 2026-11-06

The first public release.

### Added

- **The notch.** Matches the camera housing on notched MacBooks and draws a virtual notch on
  other Macs and external displays, one per display. Hover to open it, click through to the menu
  bar underneath, and it hides over full-screen apps until you hover it.
- **Now Playing** from any app that reports to macOS: artwork, play/pause, skip and a draggable
  scrubber, with a rippling line in the album art's colour in the closed notch. Repeat (off,
  all, one) for players that report it, on or off for Spotify (it asks once to control
  Spotify), and a two-finger swipe on the player for the next or
  previous song.
- **Synced lyrics** (opt-in) from lrclib.net, with the line being sung under the closed notch.
  When a song has none, Liova says why: instrumental, not timed, not found, offline, or not a
  song at all.
- **Volume and brightness HUDs** (opt-in): slim bars at the screen edges or in the notch.
- **Agent Island**: Claude Code and Codex status with approve/deny from the notch; Gemini CLI and
  Cursor status. Set up with one click in Settings or `liova agents install`. Choose whether a
  working agent or your music shows first.
- **Switch what's in front**: click anything listed under the open notch's main card to bring it
  forward; urgent things like an agent asking for permission still come first.
- **AirPods and headphones**: battery for each bud and the case, low-battery warning, noise
  control switching; Bluetooth, USB-C EarPods, USB headsets and the headphone jack.
- **Charging moment**, battery status and an unplug animation.
- **Downloads** from browsers and Telegram with size, speed and time left.
- **File Shelf** with drag in, drag out and AirDrop.
- **Timers**, **calendar "Next Up"** with a Join button, and a **camera and microphone alert**.
- **Weather** (opt-in) with a rain heads-up in the closed notch.
- **System page**: live CPU, memory (used of installed) and GPU, each with a minute of history,
  coloured calm, busy or maxed.
- **Plugin API**: the `liova` CLI, a local socket and `liova://` links.
- **Built-in updates**: checked daily, installed in place only when the download's checksum and
  signature match Liova's release certificate. Beta updates are opt-in.
- One universal app for Apple Silicon and Intel Macs, macOS 14 or later.

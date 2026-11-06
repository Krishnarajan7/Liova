# Changelog

All notable changes to Liova are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Liova uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every pull request adds a line under **[Unreleased]** (CI checks this; maintainers can apply the
`skip changelog` label to changes users won't notice, like CI or refactors). When a version is
released, its section becomes the GitHub release notes.

## [Unreleased]

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

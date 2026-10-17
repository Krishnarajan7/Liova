# Roadmap

> Dates assume **one developer working full time**. At half time, roughly double each span. Dates are targets, not promises; the exit criteria matter more than the calendar.

## Milestones

| Milestone | Target dates | Outcome |
| --- | --- | --- |
| **Foundations** | Oct 19 – Nov 1, 2026 | Notch panel, geometry, motion system, activity engine skeleton, CI |
| **MVP features** | Nov 2 – Dec 13, 2026 | Media, HUDs, battery, shelf, settings |
| **Alpha** to testers | Dec 14, 2026 | First DMG on GitHub Releases, Sparkle updates working |
| **v1.0 features + performance** | Dec 14, 2026 – Feb 7, 2027 | Live activities, Agent Island, plugin tiers 1–2, budget met |
| **Beta** on notched Macs | Jan 18 – Feb 7, 2027 | External testers, bug bash |
| **v1.0 public launch** | **Tue Feb 9, 2027** | Public release with Agent Island |
| **v1.1** | Mar 2027 onward | Plugin SDK tier 3 (ExtensionKit), lock-screen widgets |

Agent Island was originally planned as a separate v1.1 launch. It now ships in **v1.0** (see [ADR-006](DECISIONS.md#adr-006-agent-island-ships-in-v10)), which makes the Dec–Feb window the tightest part of the plan.

## Exit criteria

A gate is passed only when everything in its row is true.

| Gate | Must be true before moving on |
| --- | --- |
| **Foundations done** | Notch panel works on real and virtual notches; multi-display geometry tests pass; motion system in place; CI green; idle CPU 0.0% |
| **Alpha** | Media, HUDs, battery, shelf and settings work; ad-hoc signed DMG on GitHub Releases with tested first-launch instructions; Sparkle updates work end to end with EdDSA signatures |
| **Beta** | Live-activity engine with 8+ activity types; plugin tiers 1 and 2; Agent Island working for at least Claude Code and Codex; every [performance budget](PERFORMANCE.md) met; 3+ testers on notched Macs |
| **v1.0 launch** | Zero open crash bugs; Agent Island supports Claude Code, Codex, Cursor and Gemini CLI with approve/deny from the notch and one-command setup; README video, comparison table and docs; self-hosted Homebrew tap live; 20+ `good first issue` tickets filed |

## Features by release

| Area | MVP (alpha) | v1.0 (public launch) | Later |
| --- | --- | --- | --- |
| **Core surface** | Notch panel per display, virtual notch, hover/click/swipe, compact and expanded states | Multi-display by UUID, fullscreen-aware hiding, themes, Liquid Glass on macOS 26 | Menu-bar-only mode |
| **Media** | Now Playing for any player, artwork, controls, scrubber | Visualizer, synced lyrics (lrclib), AirPlay and output picker | Per-app volume |
| **Live activities** | Charging and battery, timers | Downloads, Focus, AirPods connect and battery, Caps Lock, camera/mic in use, calendar "next up" | iPhone Live Activities, if Apple opens an API |
| **HUDs** | Volume and brightness | Keyboard backlight, 3 HUD styles, safe auto-restore | Per-display brightness for external monitors |
| **Productivity** | File shelf with AirDrop | Calendar and reminders, clipboard history, quick notes | Webcam mirror, color picker, teleprompter |
| **Extensibility** | `liova` CLI and `liova://` URL scheme | Socket API stable, declarative widgets (tier 2), plugin gallery | ExtensionKit SDK (tier 3), Shortcuts / App Intents, Raycast extension |
| **AI: Agent Island** | — | **Claude Code, Codex, Cursor and Gemini CLI status, with approve and deny from the notch; one-command hook setup** | More agents, usage meters |
| **Lock screen** | — | — | Media and timer widgets |
| **Distribution** | Build from source, ad-hoc signed DMG | Self-hosted Homebrew tap, Sparkle auto-updates | Notarization if an Apple Developer account is obtained |

## First two weeks

- [x] **Day 1–2:** repo skeleton, MIT license, DCO, CONTRIBUTING, XcodeGen project with the `LiovaKit` local package, SwiftLint and SwiftFormat, CI.
- [x] **Day 3–5:** `DisplayManager` keyed by display UUID; notch geometry as a pure struct, tested against values recorded on a MacBook Air M4; one fixed `NSPanel` per display; virtual notch on displays without one.
- [x] **Day 6–7:** notch `Shape` with animatable radii, the shared springs, event-driven hover with a tested state machine (ADR-012), click-through outside the hot zone, trackpad haptics.
- [x] **Day 8–10:** activity engine (priority stack with preempt, restore and event-driven expiry); battery activities (charging, on battery, fully charged, low battery) from IOKit push notifications.
- [ ] **Day 11–12:** performance harness with signposts and an `xctrace` script in CI.
- [x] **Day 13–14:** Now Playing provider on the mediaremote-adapter bridge with diff mode, plus the AppleScript fallback.

Day 1–2 detail:

- [x] Repo skeleton and layout
- [x] MIT license
- [x] DCO sign-off documented
- [x] CONTRIBUTING.md and community files
- [x] XcodeGen project with local package
- [x] SwiftLint and SwiftFormat configured
- [x] CI: build, `swift test`, SwiftLint

Also done ahead of schedule:

- [x] Now Playing for any player (artwork, controls, seekable scrubber) via the vendored mediaremote-adapter
- [x] Volume and brightness HUDs (opt-in, event tap only, watchdog, safe mode)
- [x] Agent Island (app side): sessions in the notch, Allow / Deny prompts that open the notch, safe fallbacks to the agent's own prompt
- [x] Agent Island (CLI side): `liova hook claude-code` (~17 ms per event, prompt text never sent) and `liova agents install|uninstall|status claude-code`
- [x] Delight pass: charging moment (battery fill, bolt, light sweep), stepped music meter, side-bar HUD with level-meter colors, brief events as a chip so the open notch keeps your music
- [x] Open notch with pages (Home, System) and a header with battery status and Settings
- [x] System page: live CPU, memory and GPU graphs (sampled only while visible)
- [x] Unplug animation (bolt flies off, fill cools, light sweeps back)
- [x] Downloads: browsers and Telegram, with size, speed and time left; metadata only
- [x] Side-bar HUDs: volume on the right (green to red), brightness on the left
- [x] Settings window (launch at login, display placement, hover, haptics, battery) and a demo activity in the menu
- [x] Measured on a Release build: 0.0% CPU idle, 0.17% with music playing, under 25 MB memory

- [x] Plugin tier 1: Unix-socket API, `liova` CLI and `liova://` URL scheme, wired into the app and tested end to end ([PLUGIN-API.md](PLUGIN-API.md))

## How to influence the roadmap

Open a [feature request](https://github.com/Krishnarajan7/Liova/issues/new/choose) or start a thread in [Discussions](https://github.com/Krishnarajan7/Liova/discussions). Many ideas fit well as plugins, which don't need to wait for a Liova release.

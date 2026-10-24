<div align="center">

# Liova

**The free, open-source notch for your Mac, in the style of Dynamic Island.**

Music, charging, volume, your coding agents and anything your scripts want to say, in the notch.
Native Swift, smooth by design, and it uses no CPU while there's nothing to show.

[![CI](https://github.com/Krishnarajan7/Liova/actions/workflows/ci.yml/badge.svg)](https://github.com/Krishnarajan7/Liova/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![Idle CPU 0%](https://img.shields.io/badge/idle%20CPU-0.0%25-brightgreen)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)


</div>

> [!NOTE]
> **Early preview.** Liova builds and runs today and is used daily by its author, but there's no
> signed release yet. Build it from source (two commands, below) or ⭐ star the repo to hear when
> the first release lands.

## What it does

<table>
<tr>
<td width="50%" valign="top">

**🎵 Now Playing, from any app**<br>
Spotify, Apple Music, YouTube in your browser, podcasts. Artwork, play/pause, skip and a scrubber you can drag. Small bars move in the closed notch while music plays. Turn on **synced lyrics** and the words follow the song, line by line, even with the notch closed.

</td>
<td width="50%" valign="top">

**🤖 Agent Island**<br>
See what Claude Code is doing ("Running `swift test`", "Editing App.swift") and approve or deny its requests from the notch. One command to set up. If you ignore it, Claude simply asks in the terminal as usual.

</td>
</tr>
<tr>
<td valign="top">

**🎧 AirPods and headphones**<br>
Connect and the notch shows each bud's and the case's battery; disconnect and it shows them leaving. It warns once when they run low, and on AirPods with noise control you can switch between Off, Noise Cancellation and Transparency from the open notch. Works with other Bluetooth headphones too, and with wired ones: USB-C EarPods, USB headsets and the headphone jack.

</td>
<td valign="top">

**🎤 Synced lyrics**<br>
Opt-in. The line being sung slides in under the closed notch, and the open player shows it with the next one, from the free [lrclib.net](https://lrclib.net) database. The strip folds away for intros, solos and pauses. Only the song's name, artist and length are sent; answers are cached.

</td>
</tr>
<tr>
<td valign="top">

**⚡ A charging moment**<br>
Plug in and a little battery fills up, a bolt pops in and a streak of light runs along the notch. Quick events show as a chip, so the notch keeps showing your music.

</td>
<td valign="top">

**🔊 A better volume and brightness HUD**<br>
Slim level bars at the edges of the screen: volume on the right, running green to red as it gets louder, and brightness on the left. Or keep them in the notch. Opt-in, and they can never break the system HUD.

</td>
</tr>
<tr>
<td valign="top">

**📊 System at a glance**<br>
Live CPU, memory and GPU with a minute of history, one tap away in the open notch. It measures only while you're looking.

</td>
<td valign="top">

**⬇️ Downloads**<br>
Browser and Telegram downloads show up with size, speed and time left, then flash when they're done. Liova only looks at file names and sizes, never their contents.

</td>
</tr>
</table>

Also:

- **A File Shelf.** Drag files onto the notch to keep them handy, drag them out into any app, or AirDrop them in one click.
- **Weather.** Opt-in: the temperature, today's high and low and the next hours in the open notch, plus a heads-up in the closed notch when rain is about to start. Uses a city you pick or your approximate location, rounded to about a kilometre. Data by [Open-Meteo](https://open-meteo.com).
- **Timers and your calendar.** Start a timer in one tap and watch it count down in the notch; your next meeting appears ten minutes early with a Join button.
- **Camera and mic alerts.** The notch flashes when any app turns on your camera or microphone, even in full-screen apps.
- **Stays out of your movie.** Over full-screen apps the notch hides until you hover it, and nothing in it animates.
- **Every Mac.** It matches the camera housing exactly on notched MacBooks and draws a virtual notch on everything else, including external displays, one per display.
- **Feels right.** Springs that never overshoot, a hover that ignores a passing pointer, and clicks that go straight through to the menu bar underneath.
- **Scriptable.** Anything can light up the notch:

  ```bash
  liova activity start --id deploy --title "Deploying" --progress 0.4 --symbol hammer.fill
  ```

  The same works over a local socket and `liova://` links. See the [plugin API](docs/PLUGIN-API.md).

> Screenshots and a short demo video are coming. Want to help? See [#1](https://github.com/Krishnarajan7/Liova/issues/1).

## Get it

Liova runs on Apple Silicon and Intel Macs (one universal app). To build it you'll need macOS 14 or later and Xcode 26 or later.

```bash
brew install xcodegen swiftlint swiftformat cmake
git clone https://github.com/Krishnarajan7/Liova.git && cd Liova
make setup && make run
```

Liova appears in your menu bar. Choose **Show Demo Activity** to see it work.

**Set up Agent Island for Claude Code** (optional):

```bash
make cli
build/cli/liova agents install claude-code   # adds hooks to ~/.claude/settings.json, keeps a backup
```

The same works for `codex`, `gemini-cli` and `cursor`; `liova agents status` shows all four. Undo any of them with `liova agents uninstall <agent>`. See [Agent Island](docs/AGENT-ISLAND.md) for exactly what is and isn't sent.

> [!TIP]
> Volume and brightness HUDs need the Accessibility permission. Development builds change identity
> on every rebuild, so run `make dev-cert` once to keep permissions across rebuilds.

## Troubleshooting

- **"Liova can't be opened" or "cannot verify" on first launch.** Liova isn't notarized yet (that needs a paid Apple account). Open **System Settings → Privacy & Security** and click **Open Anyway**, once. Details in [DISTRIBUTION.md](docs/DISTRIBUTION.md#first-launch-for-users).
- **Volume and brightness keys show the old macOS overlay.** Turn on **Settings → HUDs → Replace the volume and brightness overlays**, then allow Liova under **Privacy & Security → Accessibility**. If it's already listed, switch it off and on again.
- **The calendar says Liova can't see your calendars.** Click **Allow Access…** in the open notch's calendar page, or turn Liova on under **Privacy & Security → Calendars**.
- **Nothing shows over a full-screen app.** That's on purpose: hover the notch to bring it back, or turn off **Settings → General → Hide over full-screen apps until hovered**.
- **No music in the notch.** Liova shows what macOS reports as Now Playing. Check that the app shows up in Control Center's Now Playing first.
- **Something else.** [Open an issue](https://github.com/Krishnarajan7/Liova/issues/new/choose) with your Mac model, macOS version and Liova version (Settings → About). Logs help:

  ```bash
  log show --last 10m --predicate 'subsystem == "app.liova.Liova"' > liova.log
  ```

## Built to sip battery

A notch app is on screen all day, so performance is a feature here, and we publish what we measure.

| Measured on a MacBook Air M4, Release build | Liova CPU | Memory |
| --- | --- | --- |
| Idle, nothing showing | **0.0%** | 15 MB |
| Music playing, notch closed | **~1%** with moving bars, **0.2%** without | 17–25 MB |
| Claude Code hook, per event | 17 ms, then exits | — |

How we keep it there:

- **Nothing polls.** Battery, music, displays and agents all push changes to Liova.
- **The window never moves.** Only the shape inside it animates.
- **Features render separately.** A battery tick can't redraw your music player.
- **Moving parts stay cheap.** The music bars cap their frame rate (30 fps plugged in, 20 on battery) and stop when paused, hidden or in Low Power Mode.

Every number and rule is in [PERFORMANCE.md](docs/PERFORMANCE.md).

## Private and safe by default

- **No telemetry, ever.** Once a day Liova asks GitHub whether there's a new version (the request carries only Liova's version; turn it off in Settings → Updates). Beyond that it makes no network requests of its own, with two opt-in exceptions, both off until you turn them on: synced lyrics, which look up the song's title, artist, album and length on [lrclib.net](https://lrclib.net) and cache the answer on your Mac; and weather, which sends [Open-Meteo](https://open-meteo.com) a city's position or your approximate one, rounded to about a kilometre.
- **Permissions only when needed.** Each one is asked for only when you turn on the feature that needs it. Accessibility is used solely to read the volume and brightness keys, never what you type.
- **No private-API tricks that can bite.** Liova never freezes system processes and never pretends to be an Apple app.
- **Plugins stay outside.** They run in their own processes, and the local socket only accepts your own user account.
- **Agent prompts stay with the agent.** Agent Island sends the event type, the project folder name and a short tool summary, and never your prompt text.

## How it's built

Swift 6 with strict concurrency, SwiftUI inside AppKit panels, and one `@Observable` store per feature. Everything goes through a small priority-stack **activity engine**: a timer beats music, a volume change beats both, and each one hands the notch back when it's done.

```
App ─► LiovaUI ─► LiovaCore ─► LiovaPluginKit ◄─ LiovaIPC ◄─ liova (CLI)
          ▲            ▲
          └── LiovaFeatures ──► LiovaProviders
```

Read more in [ARCHITECTURE.md](docs/ARCHITECTURE.md) and the [decision log](docs/DECISIONS.md).

## Roadmap

- [x] Notch on every display, smooth motion, hover and click-through
- [x] Activity engine, battery, Now Playing, volume and brightness HUDs
- [x] Plugin API: CLI, socket and `liova://` links
- [x] Agent Island for Claude Code
- [x] Downloads, System page, open-notch pages with battery status
- [x] File Shelf with AirDrop
- [x] Agent Island for Codex (with approve/deny), Gemini CLI and Cursor (status)
- [x] Timers, calendar "Next Up", camera and mic indicator
- [x] AirPods, Bluetooth and wired headphones (battery per bud and case, noise control), synced lyrics, weather
- [ ] Focus, Caps Lock and more live activities
- [x] One-click updates, installed only when signed with Liova's release certificate
- [ ] Homebrew tap
- [ ] **v1.0, planned for February 2027**

The full plan is in [ROADMAP.md](docs/ROADMAP.md).

## Contributing

Contributions are welcome, from bug reports to whole features. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Every commit needs a DCO sign-off (`git commit -s`). Good first issues are labelled `good first issue`.

## Thanks

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg (BSD-3-Clause) makes Now Playing possible on modern macOS.

## License

[MIT](LICENSE) © 2026 Krishnarajan.

"Dynamic Island", "AirPods", "EarPods" and "Mac" are trademarks of Apple Inc., used here only to describe what Liova works with. Liova is not affiliated with or endorsed by Apple. Synced lyrics come from [LRCLIB](https://lrclib.net), a free community database; the lyrics belong to their rights holders, and Liova fetches them on your Mac only when you turn the feature on. Weather data by [Open-Meteo.com](https://open-meteo.com), licensed CC BY 4.0. License notices for everything Liova ships are in Settings > About > Licenses.

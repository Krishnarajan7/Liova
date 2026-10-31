# Troubleshooting

- **"Liova can't be opened" or "cannot verify" on first launch.** Liova isn't notarized yet (that needs a paid Apple account). Open **System Settings → Privacy & Security** and click **Open Anyway**, once. Details in [DISTRIBUTION.md](DISTRIBUTION.md#first-launch-for-users).
- **Volume and brightness keys show the old macOS overlay.** Turn on **Settings → HUDs → Replace the volume and brightness overlays**, then allow Liova under **Privacy & Security → Accessibility**. If it's already listed, switch it off and on again.
- **The calendar says Liova can't see your calendars.** Click **Allow Access…** in the open notch's calendar page, or turn Liova on under **Privacy & Security → Calendars**.
- **Nothing shows over a full-screen app.** That's on purpose: hover the notch to bring it back, or turn off **Settings → General → Hide over full-screen apps until hovered**.
- **No music in the notch.** Liova shows what macOS reports as Now Playing. Check that the app shows up in Control Center's Now Playing first.
- **Something else.** [Open an issue](https://github.com/Krishnarajan7/Liova/issues/new/choose) with your Mac model, macOS version and Liova version (Settings → About). Logs help:

  ```bash
  log show --last 10m --predicate 'subsystem == "app.liova.Liova"' > liova.log
  ```

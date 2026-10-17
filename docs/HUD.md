# Volume and brightness HUDs

Liova can replace the macOS volume and brightness overlays with a HUD in the notch. It's off by default (**Settings → HUD replacement**) because it needs the Accessibility permission.

## How it works

```
media key ─► CGEventTap (main run loop) ─► MediaKeyDecoder ─► MediaKeyFilter ─► HUDFeature
                                                                                   │
                         Core Audio / DisplayServices ◄── apply new level ◄────────┤
                         ActivityEngine ◄── "system.hud" activity (critical, 1.5 s) ◄┘
```

| Piece | Module | Role |
| --- | --- | --- |
| `CGEventMediaKeyTap` (`MediaKeyTapping`) | LiovaProviders/HUD | Session event tap for `NSEvent.EventType.systemDefined` events, with a watchdog |
| `MediaKeyDecoder`, `MediaKeyFilter`, `TapWatchdog` | LiovaProviders/HUD | Pure, unit-tested decoding, swallow decisions and disable tracking |
| `CoreAudioSystemVolume` (`SystemVolumeControlling`) | LiovaProviders/HUD | Default output device volume and mute, with property listeners |
| `DisplayServicesBrightness` (`DisplayBrightnessControlling`) | LiovaProviders/HUD | Built-in display brightness via `DisplayServices`, resolved with `dlsym` |
| `HUDPolicy` | LiovaFeatures/HUD | Pure step math and activity mapping |
| `HUDFeature` | LiovaFeatures/HUD | `@Observable` store: lifecycle, permission, key handling, external changes |

1. The tap sees every *system-defined* event (subtype 8, `NX_SUBTYPE_AUX_CONTROL_BUTTONS`). `data1` holds the key code (`(data1 & 0xFFFF0000) >> 16`), the key state (`0x0A` down, `0x0B` up) and a repeat bit.
2. Only sound up/down, mute and brightness up/down are decoded. Everything else (play/pause, keyboard illumination, other subtypes) passes through untouched.
3. `HUDFeature` computes the new level, applies it, and starts the `system.hud` activity. **The tap swallows a key only if the change was applied.** If anything fails, the key goes to macOS as if Liova weren't running, and the system HUD appears.
4. A key-up is swallowed only if its key-down was.
5. Pressing again within 1.5 s updates the same activity in place and extends its expiry, so the HUD never flickers or re-stacks.

### Levels

Like macOS: 16 steps per press, 64 (quarter steps) with **Shift+Option**. A level between steps snaps to the next step in the key's direction; a level within a quarter step of a grid point counts as on it, because devices quantize what they store. Mute toggles mute and keeps the level; volume up while muted unmutes; volume down while muted stays muted. At full volume a press still shows the full HUD.

Modifiers macOS gives another meaning pass through: **Option** alone (opens Sound or Displays settings) and anything with **Command** or **Control**. Shift alone and Fn are normal presses.

### External changes

Core Audio property listeners (default output device, volume, mute) reflect changes from Control Center, AirPods, the Touch Bar or other apps. While HUD replacement is running they also flash the HUD. They don't when:

- the change is the echo of our own key press (same level, or any change within 0.75 s of it, which covers intermediate states like "unmuted, old level");
- the output device itself switched (macOS shows nothing either);
- HUD replacement is off or waiting for permission (the listener isn't even registered).

## Why an event tap, and never SIGSTOP

The other way to hide the system HUD is to suspend its process (`OSDUIHelper`) with `SIGSTOP`. If the app then crashes or is force-quit, the system HUD stays frozen until the user finds and kills that process. Liova never suspends, signals or otherwise interferes with system processes, and never impersonates Apple bundle IDs (ADR-011).

With a tap, the failure mode is benign: if Liova quits, crashes or the tap stops, macOS simply handles the keys again with its own HUD.

### The watchdog

macOS disables a tap that takes too long to answer (`tapDisabledByTimeout`) or when user input requires it (`tapDisabledByUserInput`). The tap re-enables itself each time. If it is disabled more than 3 times within 60 s, it removes itself completely and reports failure; `HUDFeature` moves to `.unavailable(…)`, clears the HUD and stops listening. Keys then go to macOS. The next `syncWithSettings()` (e.g. toggling the setting) tries again from scratch.

Other guarantees:

- `stop()` always disables the tap, removes its run-loop source and invalidates its mach port, and is safe to call any number of times. The tap's `deinit` does the same as a backstop.
- The tap holds the feature weakly. A released feature makes every key pass through.
- If the callback ever ran off the main thread, it passes the event through instead of touching main-actor state.

## Permissions

The tap needs **Accessibility** (System Settings → Privacy & Security → Accessibility).

- `HUDFeature` checks `AXIsProcessTrusted()` before creating a tap. Without it, the state is `.needsPermission` and nothing is installed.
- `requestPermission()` shows the system prompt (`AXIsProcessTrustedWithOptions` with the prompt option). Call it only from the settings UI, in response to the user.
- Trust can change while Liova runs, so the app calls `recheckPermission()` when it becomes active: it starts the tap if permission was just granted and tears it down (state `.needsPermission`) if it was revoked.

## Safe mode

If something goes wrong, launch Liova with HUD replacement disabled:

- hold **Option** while Liova launches, or
- set `LIOVA_SAFE_MODE=1` (also `true` or `yes`), e.g. `LIOVA_SAFE_MODE=1 open -a Liova` or from a launch agent's environment.

In safe mode `HUDFeature` never creates a tap and reports `.unavailable("Safe mode is on…")`. The setting itself is untouched, so a normal relaunch restores it. `HUDFeature.isSafeModeRequested` is checked once, when the feature is created at launch.

## States

| State | Meaning | System HUD |
| --- | --- | --- |
| `.off` | Setting is off | Yes |
| `.needsPermission` | Setting is on, Accessibility missing or revoked | Yes |
| `.running` | Tap installed, Liova shows the HUD | No (for keys Liova handled) |
| `.unavailable(reason)` | Safe mode, or the tap failed or was removed by the watchdog | Yes |

## Limitations

- **External displays:** brightness keys only control the built-in display. With the lid closed, or on a Mac without a built-in display, the brightness keys pass through to macOS (which handles Apple displays itself).
- **Brightness uses a private framework.** `DisplayServicesGetBrightness`/`SetBrightness` are resolved at runtime with `dlopen`/`dlsym`, never linked. If a macOS release removes them, brightness keys pass through to macOS; nothing crashes.
- **Outputs without volume control** (some HDMI, DisplayPort and AirPlay outputs) report `canSetVolume == false`, so their volume keys pass through and macOS shows its "not adjustable" HUD. Mute works if the device supports it.
- **Volume control order:** virtual main volume (keeps balance), then the main element, then each preferred stereo channel (the level shown is their average).
- **External brightness changes** (Control Center, auto-brightness) don't flash the HUD; there is no event-driven brightness change notification we can use without polling.
- **Keyboards that send brightness as plain function keys** (some third-party keyboards) aren't intercepted; macOS handles them.
- **The tap runs on the main run loop.** If the main thread stalls for about a second, macOS disables the tap; the watchdog re-enables it, and gives up after repeated stalls.
- **Secure input** (password fields, some terminals with Secure Keyboard Entry) can stop events reaching taps; macOS handles the keys in that case.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Settings say permission is needed after granting it | Switch back to Liova (it re-checks on activation). If the entry in Accessibility is stale after an update, remove Liova from the list and grant it again. |
| The system HUD appears instead of Liova's | Expected for keys Liova can't handle: fixed-volume outputs, external displays, lid closed, Option/Command/Control held. Otherwise check the state in Settings. |
| HUD replacement shows "unavailable" | The watchdog removed the tap after repeated disables. Toggle the setting to retry and look at the log (below). |
| Keys feel wrong or nothing happens | Relaunch holding **Option** (safe mode). If the system HUD works in safe mode, file an issue with the log. |

Logs:

```sh
log stream --level debug --predicate 'subsystem == "app.liova.Liova" AND (category == "hud" OR category == "feature")'
```

## Testing

Everything is behind protocols, so the tests never create a real tap, never change volume or brightness, and never prompt for permission:

- `HUDMediaKeyTests` (LiovaProvidersTests): decoding of every key, down/up, repeat, modifiers, unknown subtypes, keys and states; the swallow filter; the watchdog; a tap without permission; DisplayServices missing.
- `HUDPolicyTests` (LiovaFeaturesTests): step math, mute behaviour, symbols, priority, expiry.
- `HUDFeatureTests` (LiovaFeaturesTests): lifecycle, permission, safe mode, key handling, in-place updates, echo dedupe, watchdog fallback, using fakes from `HUDTestSupport.swift`.

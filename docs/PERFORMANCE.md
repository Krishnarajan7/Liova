# Performance

Smoothness is Liova's headline feature, so we treat it as a spec with numbers, not a vibe. This page lists the budget, the rules that keep us inside it, and how we measure.

## The budget

Every row is a **release blocker**: if a release build misses one, it doesn't ship.

| Metric | Budget | How it's measured |
| --- | --- | --- |
| CPU, idle, notch closed | **0.0%** (under 0.05%) average over 30 s, app + helpers | `make perf`: kernel CPU counters, median of 5 runs, on CI |
| Wakeups, idle | **≤ 2 per second** | `make perf`, same runs |
| CPU, music playing, notch closed | **< 0.5%** | Same |
| CPU, notch expanded with visualizer | **< 4%** | Same |
| Memory, idle | **< 60 MB**, app + helpers | `make perf` (physical footprint) |
| Hover to first animation frame | **< 16 ms** | `os_signpost` interval |
| Dropped frames per open/close at 120 Hz | **0** hitches longer than 1 frame | Animation Hitches instrument |
| Cold launch to visible notch | **< 300 ms** | `make perf`: from process start until the notch window is on screen |
| Energy impact | **"Low"** in Activity Monitor over ~12 hours | Manual check before each release |

"Idle" means nothing is live: no media playing, no activities, notch closed. In that state Liova should do no work at all.

## Architecture rules

These decide whether the budget is even reachable. They are enforced in review.

1. **Fixed panel, animated shape.** One `NSPanel` per display, sized for the largest expanded state, created once and never resized. The notch is a `Shape` with animatable radii inside it. Outside the notch's hot zone the panel ignores mouse events, so clicks pass through. Window-server resizes are the biggest source of jank, so we never do them.
2. **Render isolation.** Each feature has its own `@Observable` store and each view reads only the properties it draws. There is no root `ObservableObject`, so a battery tick cannot re-render the media view.
3. **Event-driven, no polling.** Use push sources: power-source run-loop notifications, Core Audio property listeners, `NSWorkspace` notifications, EventKit change notifications, the Now Playing helper in diff mode. Anything that truly needs a timer goes through the shared scheduler, which stops when the notch is closed and nothing is live.
4. **Hover without polling.** An event-driven pointer monitor (nothing runs while the mouse is still), separate open and close behaviour, and a 120 ms default intent delay inside a cancellable task. Never a mouse-position timer.
5. **One motion system.** All motion uses the shared springs in `LiovaUI`. Content morphs with `matchedGeometryEffect`; the window frame never animates.
6. **Streaming values bypass animation.** Scrubbers, volume and progress values are written in a `Transaction` with animations disabled. `TimelineView` and visualizer updates are capped at 30 fps and paused when hidden.
7. **Cheap visuals.** Blur album-art glow once with Core Image and cache the result. Use one `NSVisualEffectView` (or Liquid Glass on macOS 26) instead of stacking SwiftUI materials. Draw the visualizer with `CALayer` bars fed by a Core Audio process tap and a vDSP FFT.
8. **Off the main thread.** File I/O, image decoding, helper IPC and the plugin socket run on actors or background executors. Swift 6 strict concurrency is on everywhere to catch data races at compile time.

## Smoothness rules

The motion-level details that make the notch feel right.

1. **Critically damped open and close.** Open is `spring(response: 0.42, dampingFraction: 1.0)`, close is `response: 0.45`. The notch never overshoots. Only hover feedback is allowed a little bounce (`.bouncy`, scaled ~1.2×).
2. **Never animate the window frame.** If the window must change at all, change it instantly and animate only the SwiftUI content.
3. **Debounce any window change** by 100–150 ms so bursts of display or layout events collapse into one.
4. **Drop duplicates everywhere.** Every state pipeline ignores values equal to the current one, and sizes are compared before starting an animation.
5. **No animation on streaming writes.** Slider and progress updates are written with animations disabled.
6. **Cap timelines at 30 fps and pause when idle.** An uncapped timeline on a 120 Hz ProMotion display redraws four times as often for no visible gain and can burn tens of percent of CPU.
7. **Pre-blur and cache** expensive effects like artwork glow; never blur live per frame.
8. **Stagger heavy mounts.** Expensive views (calendar grids, video) mount a beat after the open animation starts, not in the same frame.
9. **Visualizer on `CALayer`**, not SwiftUI shapes, fed by a Core Audio process tap.
10. **Hover-open is a cancellable task** that re-checks state (is the pointer still there? is something else animating?) before acting.

## How we measure

**Measured so far** (Release build, MacBook Air M4 on battery, `make perf`):

| Scenario | CPU | Wakeups | Memory (app + helpers) | Launch |
| --- | --- | --- | --- | --- |
| Idle, notch closed, 40 s after launch | 0.002% | 0 per second | 20.8 + 9.3 MB | 160–190 ms |
| First 5 s after launch | 2–10% | 20–100 per second | | |

Earlier `ps`-based numbers (rounded to 0.1%): music playing with static bars 0.17%; with moving bars at 30 fps ~1% plus ~7% WindowServer.

"Helpers" are the Now Playing bridge (`/usr/bin/perl` running the vendored adapter, ~6 MB) and the small guard that ends it when Liova exits (~4 MB, see below).

**Lessons that are now rules:**

- *Continuous animation is expensive, and not in Liova.* Any animation running every frame keeps WindowServer recompositing: measured +7.5% WindowServer CPU at 60 fps, +3.7% at 30 fps and +1.8% at 20 fps, even for a 16 pt meter in a tiny window (window size barely matters). So the music bars use a display link capped at 30 fps plugged in and 20 fps on battery, rest when paused, hidden or in Low Power Mode, and can be turned off. Stepping at 10 Hz was cheaper still but looked choppy. Always measure WindowServer too, not just Liova.
- *No `drawingGroup()` around the notch.* It moves rendering into the app on every frame of any animation (13% CPU with one looping symbol). Core Animation already composites the shape off-process.
- *No animated shadows.* A shadow whose radius animates forces an extra offscreen pass per frame; it was the main cause of a hover stutter.
- *Moving music bars run on battery too, at 20 fps.* The default was once **When plugged in**, but bars that froze the moment the charger came out read as a bug. 20 fps on battery costs about 1.8% WindowServer CPU while music plays and nothing while paused. **When plugged in** (move on power, rest on battery, switching the moment the Mac is plugged in or unplugged) and **Off** are in Settings for anyone who wants that back.
- *The lyric under the closed notch costs one wakeup per line.* When lyrics are on, the line being sung shows in a strip under the closed notch. Nothing polls: the next line change is scheduled for the moment it starts, only while the strip's notch is on screen (not while the notch is open, hidden or covered by a full-screen app), and only while playing. The notch's shape depends on a separate flag that changes only when the strip comes or goes (paused, intro, long instrumental breaks, after the last line), so a new line redraws one `Text`, not the notch. The line slides in with a single short spring; nothing loops.
- *The bars heal themselves.* A display link can go quiet after sleep or a display change, and macOS doesn't always announce that the window is visible again after waking. So the bars restart their link on wake, unlock and display changes, and while music plays a check every 4 seconds (with 2 seconds of tolerance, so it coalesces with other wakeups) resumes or restarts them if they're not doing what they should. Paused, the check is off.
- *Never ask the window server on the main thread.* `CGWindowListCopyWindowInfo` copies every window's details; the full-screen check runs it on a background queue, and checks requested meanwhile collapse into one.
- *Decode big payloads once.* Now Playing artwork arrives as megabytes of base64; it's decoded when it changes, not on every play/pause or position update, and later updates share the same bytes, so comparing them costs nothing.
- *Show the notch first, start the rest after.* Only what draws at launch runs before the first frame; Now Playing, HUD key tap, downloads, capture, calendar and the plugin socket start one run-loop turn later. Launch went from 287 to 191 ms (median of 7).
- *Child processes must not outlive Liova.* The Now Playing helper runs under a guard that holds a pipe from Liova; however Liova ends (quit, crash, `kill -9`), the kernel closes the pipe and the guard stops the helper. Before this, every crash or force quit left a 20 MB helper running.
- *Use exact counters, not `ps`.* `ps` rounds CPU to 0.1% and showed "0.0%" while Liova was really at 0.4% shortly after launch. `make perf` reads `proc_pid_rusage`.

**Signposts.** Key intervals are wrapped in `os_signpost` under the `app.liova.Liova` subsystem: launch to first draw, hover to first frame, open and close animations, activity transitions. They show up in Instruments' Points of Interest and in `xctrace` exports.

**`make perf`.** Builds Release, then [`scripts/perf/liova-perf.swift`](../scripts/perf/liova-perf.swift) launches Liova several times (with first-run UI off, saved settings untouched), times launch until the notch is on screen, lets it settle, and reads the kernel's counters for Liova and its helpers: CPU time, wakeups, energy and physical footprint. The median is compared with the budget and any miss exits non-zero.

```sh
make perf                                                    # 5 × 30 s idle runs
make perf PERF_ARGS="--runs 3 --manual 'play music'"         # waits for you, then measures
make perf PERF_ARGS="--timeline 40"                          # CPU and wakeups per second after launch
```

Don't touch the Mac during an idle run: moving the pointer near the notch or switching apps is real work and shows up in the numbers.

**On CI.** The `Performance budget` job runs `make perf` on every push and PR and writes a table to the job summary. Idle CPU, wakeups and memory use the real budget. Launch uses a 1500 ms limit there because GitHub's virtual machines start apps far slower than a Mac; the 300 ms launch budget is checked on real hardware before each release.

**Animation Hitches.** Locally, profile open/close with the **Animation Hitches** instrument on a 120 Hz display. Any hitch longer than one frame is a bug.

**Memory.** `make perf` reports it; `footprint Liova` for a one-off look.

**Energy.** Before each release, leave a Release build running for a working day and check Activity Monitor's Energy tab. It should read "Low".

**Re-render checks.** During development, `Self._printChanges()` in a view's `body` shows why it re-rendered. If an unrelated store change triggers it, render isolation is broken.

### Measuring tips

- Always profile a **Release** build. Debug numbers are meaningless.
- Quit other heavy apps and let the Mac settle for a minute before an idle measurement.
- Test on a ProMotion (120 Hz) display when checking hitches; 60 Hz hides problems.
- Include the before and after numbers in your PR if you touched anything that renders or runs while idle.

# Performance

Smoothness is Liova's headline feature, so we treat it as a spec with numbers, not a vibe. This page lists the budget, the rules that keep us inside it, and how we measure.

## The budget

Every row is a **release blocker**: if a release build misses one, it doesn't ship.

| Metric | Budget | How it's measured |
| --- | --- | --- |
| CPU, idle, notch closed | **0.0%** average over 60 s | `xctrace` CPU profiler on Apple Silicon CI runners; median of 5 runs |
| CPU, music playing, notch closed | **< 0.5%** | Same |
| CPU, notch expanded with visualizer | **< 4%** | Same |
| Memory, idle | **< 60 MB** | `footprint` |
| Hover to first animation frame | **< 16 ms** | `os_signpost` interval |
| Dropped frames per open/close at 120 Hz | **0** hitches longer than 1 frame | Animation Hitches instrument |
| Cold launch to visible notch | **< 300 ms** | Signpost from `main` to first draw |
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

**Measured so far** (Release build, MacBook Air M4, Activity Monitor-equivalent `ps` CPU time over 30 s):

| Scenario | CPU | Memory |
| --- | --- | --- |
| Idle, notch closed | 0.0% | 15 MB |
| Music playing, notch closed, static bars | 0.17% | 17 MB |
| Music playing, notch closed, moving bars (30 fps) | ~1% (+~7% WindowServer) | 24 MB |

**Lessons that are now rules:**

- *Continuous animation is expensive, and not in Liova.* Any animation running every frame keeps WindowServer recompositing: measured +7.5% WindowServer CPU at 60 fps, +3.7% at 30 fps and +1.8% at 20 fps, even for a 16 pt meter in a tiny window (window size barely matters). So the music bars use a display link capped at 30 fps plugged in and 20 fps on battery, rest when paused, hidden or in Low Power Mode, and can be turned off. Stepping at 10 Hz was cheaper still but looked choppy. Always measure WindowServer too, not just Liova.
- *No `drawingGroup()` around the notch.* It moves rendering into the app on every frame of any animation (13% CPU with one looping symbol). Core Animation already composites the shape off-process.
- *No animated shadows.* A shadow whose radius animates forces an extra offscreen pass per frame; it was the main cause of a hover stutter.

**Signposts.** Key intervals are wrapped in `os_signpost` under the `app.liova.Liova` subsystem: launch to first draw, hover to first frame, open and close animations, activity transitions. They show up in Instruments' Points of Interest and in `xctrace` exports.

**`xctrace` in CI.** The performance job builds a Release configuration, launches Liova, and records with `xctrace`:

```sh
xcrun xctrace record --template 'Time Profiler' --time-limit 60s \
  --attach Liova --output idle.trace
xcrun xctrace export --input idle.trace --toc
```

It runs each scenario (idle, music playing, expanded) five times and compares the median against the budget. A regression fails the PR.

**Animation Hitches.** Locally, profile open/close with the **Animation Hitches** instrument on a 120 Hz display. Any hitch longer than one frame is a bug.

**Memory.** `footprint Liova` after launch and after a few minutes idle.

**Energy.** Before each release, leave a Release build running for a working day and check Activity Monitor's Energy tab. It should read "Low".

**Re-render checks.** During development, `Self._printChanges()` in a view's `body` shows why it re-rendered. If an unrelated store change triggers it, render isolation is broken.

### Measuring tips

- Always profile a **Release** build. Debug numbers are meaningless.
- Quit other heavy apps and let the Mac settle for a minute before an idle measurement.
- Test on a ProMotion (120 Hz) display when checking hitches; 60 Hz hides problems.
- Include the before and after numbers in your PR if you touched anything that renders or runs while idle.

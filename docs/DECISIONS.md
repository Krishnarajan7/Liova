# Architecture decision records

A lightweight log of significant decisions and why we made them. Each entry is short: context, decision, consequences. To change a decision, add a new ADR that supersedes the old one rather than rewriting history.

| ADR | Decision | Status |
| --- | --- | --- |
| [001](#adr-001-mit-license) | MIT license | Accepted |
| [002](#adr-002-swift-6-and-swiftui-inside-appkit) | Swift 6 + SwiftUI inside AppKit | Accepted |
| [003](#adr-003-one-local-package-liovakit-with-multiple-targets) | One local package, `LiovaKit`, with multiple targets | Accepted |
| [004](#adr-004-xcodegen-generated-project-not-committed) | XcodeGen; generated project not committed | Accepted |
| [005](#adr-005-macos-14-sonoma-minimum) | macOS 14 minimum | Accepted |
| [006](#adr-006-agent-island-ships-in-v10) | Agent Island in v1.0 | Accepted |
| [007](#adr-007-no-apple-developer-account-for-now) | No Apple Developer account for now | Accepted |
| [008](#adr-008-bundle-id-appliovaliova) | Bundle ID `app.liova.Liova` | Accepted |
| [009](#adr-009-no-telemetry) | No telemetry | Accepted |
| [010](#adr-010-now-playing-via-the-mediaremote-adapter-bridge) | Now Playing via mediaremote-adapter | Accepted |
| [011](#adr-011-hud-replacement-via-event-tap-only) | HUD replacement via event tap only | Accepted |

---

## ADR-001: MIT license

**Date:** 2026-10-17

**Context.** Most capable free notch apps are GPL-licensed. That prevents companies, forks and other apps from embedding or building on them under their own terms. A permissive license is one of Liova's main differentiators.

**Decision.** Liova is licensed under MIT. Contributions are accepted under MIT with a DCO sign-off. All dependencies must be MIT, BSD, Apache-2.0 or similarly permissive. GPL code is never copied, and contributors follow a clean-room rule (see [CONTRIBUTING.md](../CONTRIBUTING.md#the-clean-room-rule)).

**Consequences.** Anyone can use, fork and embed Liova. We must be disciplined about provenance: no GPL repos open while writing the matching subsystem, techniques described in our own words, and dependency licenses checked in review.

## ADR-002: Swift 6 and SwiftUI inside AppKit

**Date:** 2026-10-17

**Context.** The notch needs precise control over windows (levels, collection behaviour, hit-testing, tracking areas), which SwiftUI's window APIs don't provide. It also needs the best possible animation, which SwiftUI does well. Data races in UI-adjacent code cause hard-to-reproduce glitches.

**Decision.** Use Swift 6 language mode with strict concurrency in every target from the first commit. AppKit owns the windows (`NSPanel`, levels, mouse handling); SwiftUI renders everything inside them via `NSHostingView`. State uses `@Observable` stores per feature; I/O uses actors.

**Consequences.** Concurrency bugs are caught at compile time, at the cost of some upfront friction with Apple frameworks that aren't fully annotated. Contributors need to understand both AppKit and SwiftUI at the boundary, but most feature work is pure SwiftUI.

## ADR-003: One local package, `LiovaKit`, with multiple targets

**Date:** 2026-10-17

**Context.** We want clear module boundaries (core logic without UI, a dependency-free public SDK) and fast tests that don't need the app. The original plan used several separate local packages.

**Decision.** Use a single local Swift package, `Packages/LiovaKit`, with one target per module: `LiovaCore`, `LiovaUI`, `LiovaPluginKit`, and later `Features/*` and `Providers/*`. The app target depends on it.

**Consequences.** Same module isolation as separate packages (Swift enforces target dependencies), but one `Package.swift`, one `swift test` for everything, and less dependency-resolution churn. If `LiovaPluginKit` later needs its own versioned release for third-party plugin authors, it can be split out into its own package then.

## ADR-004: XcodeGen; generated project not committed

**Date:** 2026-10-17

**Context.** `.xcodeproj` files are large, opaque, and cause merge conflicts, which hurts an open-source project with many contributors.

**Decision.** Describe the project in `project.yml` and generate `Liova.xcodeproj` with XcodeGen (`make setup`). The generated project is in `.gitignore`.

**Consequences.** Reviewable, conflict-free project changes. Contributors need XcodeGen installed and must re-run `make setup` after `project.yml` changes. Settings changed in Xcode's UI are lost unless also made in `project.yml`.

## ADR-005: macOS 14 Sonoma minimum

**Date:** 2026-10-17

**Context.** `@Observable` (Observation framework) requires macOS 14. Supporting older versions would mean falling back to `ObservableObject`, losing render isolation. macOS 14 covers every notched Mac and most Macs in use.

**Decision.** The deployment target is macOS 14. Newer features, such as Liquid Glass on macOS 26, are adopted behind `#available` checks with a fallback.

**Consequences.** Users on macOS 13 or earlier can't run Liova. We test on 14 and the current release, and keep fallbacks working.

## ADR-006: Agent Island ships in v1.0

**Date:** 2026-10-17

**Context.** The fastest-growing notch projects in 2026 are AI coding-agent status apps. The original plan held Agent Island back for a second launch in v1.1. Shipping it at launch gives v1.0 a sharp, demo-able hook and positions Liova as a general hub that also covers agents.

**Decision.** Agent Island is part of v1.0: Claude Code, Codex, Cursor and Gemini CLI status, with approve and deny from the notch, and one-command hook setup. It is built on the tier 1 socket API like any plugin.

**Consequences.** More scope in the Dec 2026 – Feb 2027 window; the socket API must be stable earlier. If the schedule slips, we cut other v1.0 features before Agent Island. Approve/deny is security-sensitive and must be covered by the socket's peer-UID check and threat review before launch.

## ADR-007: No Apple Developer account for now

**Date:** 2026-10-17

**Context.** Developer ID signing and notarization need a paid Apple Developer Program membership ($99/year), which we don't have yet. Without notarization, Gatekeeper blocks the first launch, and Homebrew's official cask repository disables casks that fail Gatekeeper.

**Decision.** Builds are ad-hoc signed (`CODE_SIGN_IDENTITY=-`). Distribution is: build from source (`make run`); an ad-hoc signed DMG on GitHub Releases with clear first-launch instructions; and a self-hosted Homebrew tap (`brew install --cask krishnarajan7/tap/liova`). Sparkle updates use EdDSA signatures, which need no Apple account. Notarization is added later if an account is obtained. Details in [DISTRIBUTION.md](DISTRIBUTION.md).

**Consequences.** Users see a Gatekeeper warning on first launch and must approve Liova in System Settings. No official Homebrew cask. Developers' ad-hoc builds change identity each rebuild, so we recommend a local self-signed certificate for stable permissions. Moving to notarization later requires no architectural changes.

## ADR-008: Bundle ID `app.liova.Liova`

**Date:** 2026-10-17

**Context.** A bundle ID is effectively permanent: macOS ties permissions, preferences and update identity to it.

**Decision.** The app's bundle ID is `app.liova.Liova`. Helpers and extensions use the `app.liova.` prefix (e.g. `app.liova.Liova.NowPlayingHelper`). Logging subsystems match.

**Consequences.** A reverse-DNS namespace we control, never Apple's. Changing it later would reset every user's permissions and settings, so we don't.

## ADR-009: No telemetry

**Date:** 2026-10-17

**Context.** Liova sees sensitive things: what you're listening to, your calendar, your coding-agent sessions. Users and companies need to trust it without auditing network traffic.

**Decision.** Liova collects no analytics or usage data. Crash reports are opt-in and stay local unless the user chooses to share them. Network access is limited to features that clearly need it (update checks, lyrics) and can be turned off.

**Consequences.** We learn about usage only from issues, Discussions and voluntary feedback. Performance claims are backed by our own CI measurements instead of field data.

## ADR-010: Now Playing via the mediaremote-adapter bridge

**Date:** 2026-10-17

**Context.** Since macOS 15.4, the system's Now Playing information is restricted to Apple's own processes. One way around this is to give a helper an Apple bundle ID; that is impersonation, risks certificate revocation, and can break in any update.

**Decision.** Read Now Playing through the BSD-3-Clause [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) bridge, which runs via the system Perl, in a helper process, in diff mode. Wrap it in a `NowPlayingProvider` protocol with a startup probe. Fallbacks: AppleScript and distributed notifications for Music and Spotify. We never use a `com.apple.*` bundle ID or otherwise impersonate Apple.

**Consequences.** A permissive, honest route that works today. If Apple closes it, the provider falls back and the UI shows a degraded state rather than breaking. We depend on an external project and should contribute fixes upstream.

## ADR-011: HUD replacement via event tap only

**Date:** 2026-10-17

**Context.** Replacing the system volume and brightness HUD can be done by suspending the system HUD process with `SIGSTOP`. If the app then crashes, the system HUD stays frozen until the user kills that process.

**Decision.** Use a keyboard event tap only: intercept the media keys, apply the change, and draw our own HUD. Never `SIGSTOP` or otherwise suspend system processes. A watchdog re-enables or removes the tap if macOS disables it, and a safe-mode launch flag turns HUD replacement off entirely.

**Consequences.** If Liova crashes or the tap fails, the system HUD simply returns. Requires the Accessibility permission, requested only when HUD replacement is turned on.

## ADR-012: Event-driven pointer monitor for hover and click-through

**Date:** 2026-10-17

**Context.** The notch panel is fixed and larger than the visible shape. Clicks on its transparent parts must reach the menu bar and apps underneath, and hover must work even while the panel ignores mouse events. `NSTrackingArea` stops firing when a window ignores mouse events, and transparent-pixel click-through is not reliable for SwiftUI-hosted content.

**Decision.** A `PointerMonitor` with a global and a local `NSEvent` monitor for mouse-moved, drag and mouse-down events. Each controller checks the point against its notch's hot zone and toggles `ignoresMouseEvents` only when the answer changes. The hover/click logic is a pure state machine (`NotchInteraction`) that is unit-tested.

**Consequences.** Click-through is exact, hover works on every display, and nothing runs while the mouse is still (measured 0.0% idle CPU). Mouse monitors need no permission. While the mouse moves, each event costs one rectangle check per display.

## ADR-013: Public window level first; private window-server space later

**Date:** 2026-10-17

**Context.** Drawing above full-screen apps and the lock screen reliably needs a private window-server space (CGS/SLS calls). Private calls can break in any macOS release.

**Decision.** Ship with public APIs first: an `NSPanel` at `statusBar + 1` with `.canJoinAllSpaces`, `.fullScreenAuxiliary` and `.stationary`, which already shows over full-screen Spaces. A `WindowServerBridge` that resolves private symbols with `dlsym` at runtime, and falls back to this public path if they are missing, comes later and stays isolated in one file.

**Consequences.** The notch works today with zero private API. Lock-screen presence waits for the bridge.

## ADR-014: Activity renderers for feature-specific views

**Date:** 2026-10-18

**Context.** Some activities need more than a symbol, title and progress: Now Playing needs artwork, a scrubber and controls. Putting media views inside the notch UI would couple `LiovaUI` to every feature.

**Decision.** `LiovaUI` defines an `ActivityRenderer` protocol and an `ActivityRendererRegistry` keyed by activity source. Features register a renderer at launch; the notch asks it for the compact ears and the expanded card and falls back to its default views. `LiovaFeatures` may depend on `LiovaUI` for this; `LiovaUI` never depends on features.

**Consequences.** The notch stays generic and features stay self-contained. The same hook can later host tier 3 (native) plugin views.

## ADR-015: Vendored mediaremote-adapter, built with CMake

**Date:** 2026-10-18

**Context.** Now Playing data is entitlement-gated since macOS 15.4. ADR-010 chose the BSD-3 mediaremote-adapter bridge.

**Decision.** Vendor its source at a pinned commit in `Vendor/mediaremote-adapter` (license and provenance in `VENDORED.md`, no local changes). `make vendor` builds the framework with CMake; the app embeds it in `Contents/Frameworks` (signed, never linked) and the Perl script in `Contents/Resources`. The source was reviewed before vendoring: no network access, and no process launches outside its optional `test` command.

**Consequences.** CMake joins the build prerequisites (preinstalled on GitHub's macOS runners). Updating the adapter is a reviewed re-vendor. If Apple closes the route, only `MediaRemoteAdapterProvider` changes.

## ADR-016: Agent Island speaks one agent-agnostic protocol

**Date:** 2026-10-18

**Context.** Claude Code, Codex, Cursor and Gemini CLI each have their own hook formats, and those formats change. Approve/deny must never leave an agent stuck.

**Decision.** The wire protocol gains two ops, `agentEvent` and `agentPermission`, with generic payloads (`AgentEvent`, `AgentPermissionRequest`, `AgentDecision`). Per-agent adapters live in the `liova` CLI, which the agent runs as its hook. A permission request holds its socket request open until the user answers; any timeout, error or "answer in terminal" returns `ask`, and the hook then prints nothing so the agent falls back to its own prompt. Agent activities use the reserved `system.agents` source, so no other client can fake or dismiss a prompt. Prompt text is never sent, only event kinds, the project folder name and a short tool summary.

**Consequences.** Adding an agent is a CLI adapter plus an installer, with no app changes. If Liova isn't running, hooks exit immediately and agents behave exactly as without Liova.


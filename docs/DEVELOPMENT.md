# Development guide

How to build, run, test, and debug Liova from source.

## Prerequisites

| Tool | Version | Install |
| --- | --- | --- |
| macOS | 14 Sonoma or later to run; macOS 26 recommended for development (Liquid Glass) | |
| Xcode | 26 or later | Mac App Store or [developer.apple.com](https://developer.apple.com/xcode/) |
| XcodeGen | latest | `brew install xcodegen` |
| SwiftLint | latest | `brew install swiftlint` |
| SwiftFormat | latest | `brew install swiftformat` |
| CMake | 3.20+ | `brew install cmake` (builds the vendored Now Playing adapter) |

Make sure the command-line tools point at Xcode 26:

```sh
xcode-select -p                                   # should print .../Xcode.app/Contents/Developer
sudo xcode-select -s /Applications/Xcode.app      # if it doesn't
```

You do **not** need a paid Apple Developer account. Local builds are ad-hoc signed.

A Mac with a physical notch is helpful but not required: Liova draws a virtual notch on Macs and displays without one, and notch geometry is unit-tested against real display values.

## Quick start

```sh
git clone https://github.com/Krishnarajan7/Liova.git
cd Liova
make setup    # checks tools are installed, runs xcodegen to create Liova.xcodeproj
make run      # builds the app and launches it
```

Liova is a menu-bar agent (`LSUIElement`), so it has no Dock icon. Look at the notch and the menu bar.

## Make targets

| Command | What it does |
| --- | --- |
| `make setup` | Checks that Xcode, XcodeGen, SwiftLint and SwiftFormat are installed, then generates `Liova.xcodeproj` from `project.yml`. Re-run it after pulling changes to `project.yml`. |
| `make build` | Builds the app (Debug) with `xcodebuild`, ad-hoc signed. |
| `make run` | Builds, then launches `Liova.app`. Accepts `SIGN_IDENTITY=...` (see below). |
| `make test` | Runs `swift test` in `Packages/LiovaKit`. Fast, no app launch needed. |
| `make lint` | Runs SwiftLint in strict mode. Must pass with zero warnings. |
| `make format` | Runs SwiftFormat over the repo, rewriting files in place. |
| `make clean` | Removes build products and the generated Xcode project. |

Before pushing, run `make format lint test`. CI runs the same checks.

## Working in Xcode

```sh
make setup
open Liova.xcodeproj
```

`Liova.xcodeproj` is **generated** from `project.yml` by XcodeGen and is not committed (it's in `.gitignore`). Don't edit project settings in Xcode's UI; they'll be lost on the next `make setup`. Change `project.yml` instead.

The same goes for `App/Info.plist` and `App/Liova.entitlements`: XcodeGen rewrites both from `project.yml` (`info.properties` and `entitlements.properties`) on every build, so an edit made directly to either file silently disappears. A privacy feature needs both a usage description (`NS…UsageDescription`) and, under the hardened runtime, a `com.apple.security.personal-information.*` entitlement; without the entitlement macOS refuses access without ever asking, and Liova never appears in System Settings → Privacy & Security. CI checks both in the built app.

The `LiovaKit` local package appears in the project navigator. You can also open `Packages/LiovaKit/Package.swift` on its own in Xcode to work on core modules and run their tests without building the app.

## The `liova` command-line tool

```bash
make cli                 # builds build/cli/liova (release)
build/cli/liova ping     # "Liova is running (plugin API v1)."
build/cli/liova activity start --id build --title "Building" --progress 0.3 --symbol hammer.fill
build/cli/liova activity list
build/cli/liova activity end --id build
```

The app must be running (`make run`). See [PLUGIN-API.md](PLUGIN-API.md) for every command and the raw socket protocol.

## Releases and icons

- `make release VERSION=x.y.z` builds the universal DMG; see [DISTRIBUTION.md](DISTRIBUTION.md).
- `make run` also bundles the CLI into the app, so Settings → Agents can connect agents with one click.
- The app icon is drawn in code: `swift scripts/icon/make-icon.swift App/Assets.xcassets/AppIcon.appiconset` regenerates every size. The menu bar icon is `App/MenuBarIcon.swift`.

## Apple Silicon and Intel

Release builds of the app and `make cli` are universal (arm64 + x86_64). On an Apple Silicon Mac, `make test-intel` runs the whole test suite as Intel code under Rosetta. Hardware-specific paths (brightness, GPU statistics) still deserve a check on a real Intel Mac before a release.

## Repo layout

```
Liova/
├─ project.yml            # XcodeGen spec; Liova.xcodeproj is generated, not committed
├─ Makefile               # make setup | build | run | test | lint | format | clean
├─ App/                   # thin app target: LiovaApp.swift, AppDelegate.swift, Info.plist, entitlements
├─ Packages/LiovaKit/     # ONE local Swift package, multiple module targets:
│   ├─ Sources/LiovaCore/       # activity engine, display manager, geometry, scheduler (no UI)
│   ├─ Sources/LiovaUI/         # notch shape, motion system (springs), shared components
│   ├─ Sources/LiovaPluginKit/  # public SDK: activity models, manifest schema (no deps)
│   └─ Tests/...                # swift test
│   (Features/* and Providers/* become additional targets in this package later)
├─ .github/workflows/ci.yml  # build + swift test + swiftlint on macos-26 (Apple Silicon)
└─ docs/
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for what goes where and which modules may depend on which.

Key facts:

- Bundle ID: `app.liova.Liova`
- Swift 6 language mode, strict concurrency on in every target
- Minimum deployment target: macOS 14

## Stable signing for local builds (recommended)

Quickest way: `make dev-cert` (runs `scripts/create-dev-cert.sh`). It creates a self-signed "Liova Development" certificate in your login keychain, trusted only for code signing on your Mac; macOS asks for your password once. From then on `make` signs with it automatically and permissions stick across rebuilds.


Ad-hoc signed builds (`CODE_SIGN_IDENTITY=-`) get a **new code identity on every rebuild**. macOS ties privacy permissions such as Accessibility to that identity, so after a rebuild it may forget them and prompt again, or show Liova as enabled in System Settings while silently denying it.

Fix this once by creating a local self-signed certificate:

1. Open **Keychain Access**.
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `Liova Development`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**. Click **Create**.
4. Find the new certificate in the **login** keychain, double-click it, expand **Trust**, and set **Code Signing** to **Always Trust**.
5. Check it shows up:

   ```sh
   security find-identity -v -p codesigning
   ```

Then build with it:

```sh
make run SIGN_IDENTITY="Liova Development"
```

Permissions now survive rebuilds. This certificate is only trusted on your Mac; it's for development, not distribution.

## Debugging tips

**Logs.** Liova uses `os.Logger` with subsystem `app.liova.Liova` (and `app.liova.*` for helpers). Stream them live:

```sh
log stream --level debug --predicate 'subsystem BEGINSWITH "app.liova"'
```

Or filter by the same subsystem in Console.app.

**Reset permissions** when testing first-run flows or when TCC gets confused:

```sh
tccutil reset Accessibility app.liova.Liova
tccutil reset All app.liova.Liova
```

**Quit a stuck instance.** There's no Dock icon, so use the menu-bar item, or:

```sh
pkill -x Liova
```

**Only one instance at a time.** If you run from Xcode while a release build is also running, quit the release build first; two copies will fight over the notch and the socket.

**Inspect the notch window.** In Xcode, run the app and use **Debug → View Debugging → Capture View Hierarchy** to see the panel, hosting view, and SwiftUI tree. Remember the panel is a fixed size; if the notch looks wrong, the problem is in the shape or geometry, not the window frame.

**SwiftUI re-renders.** To check render isolation, temporarily add `let _ = Self._printChanges()` at the top of a view's `body`. A battery update should not print anything from the media view. Remove it before committing.

**Performance.** Use the Instruments templates described in [PERFORMANCE.md](PERFORMANCE.md#how-we-measure): Time Profiler, Animation Hitches, and our `os_signpost` intervals. Always profile a **Release** build; Debug builds are much slower and the numbers mean nothing.

**Multiple displays.** Test plug/unplug, lid close, and changing the main display. Each display's notch is keyed by its UUID, so these should reconcile without recreating every panel.

**No notch on your test Mac?** The virtual notch is first-class. To exercise real-notch geometry without the hardware, add a unit test using the recorded `safeAreaInsets` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` values in the geometry test fixtures.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `make setup` says a tool is missing | `brew install xcodegen swiftlint swiftformat cmake` |
| Xcode can't find `LiovaKit` modules | Run `make setup` again, then **File → Packages → Reset Package Caches** |
| Accessibility prompt after every build | Use the self-signed certificate above |
| Build fails with Swift concurrency errors | That's strict concurrency doing its job. Fix the isolation rather than suppressing it; ask in your PR if unsure. |
| `swift test` fails but the app builds | Run `make test` from the repo root; it runs inside `Packages/LiovaKit` |

# Contributing to Liova

Thanks for helping build Liova, the free, open-source notch for your Mac. This guide covers everything you need to get a change merged.

- [Getting set up](#getting-set-up)
- [Branches and pull requests](#branches-and-pull-requests)
- [Sign your commits (DCO)](#sign-your-commits-dco)
- [The clean-room rule](#the-clean-room-rule)
- [Code style](#code-style)
- [Performance rules](#performance-rules)
- [Pull request checklist](#pull-request-checklist)
- [Good first issues](#good-first-issues)

By taking part you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Getting set up

You need an Apple Silicon or Intel Mac on macOS 14 or later, Xcode 26+, and three Homebrew tools:

```sh
brew install xcodegen swiftlint swiftformat cmake
make setup   # checks tools, generates Liova.xcodeproj
make run     # builds and launches Liova
make test    # runs swift test in Packages/LiovaKit
```

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has the full walkthrough, the repo layout, and debugging tips. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before touching anything in `LiovaCore`.

## Branches and pull requests

1. Fork the repo and create a branch from `main`. Name it after the change: `fix/hover-flicker`, `feat/battery-activity`, `docs/plugin-guide`.
2. Keep each pull request to one logical change. Small PRs get reviewed fast; large ones stall.
3. For anything bigger than a bug fix, open an issue or a Discussion first so we can agree on the approach before you write code.
4. Run `make format lint test` before pushing. CI runs the same checks on Apple Silicon and must be green.
5. Add a line for users under **[Unreleased]** in [CHANGELOG.md](CHANGELOG.md): what changed for them, not how. Changes nobody using Liova would notice (CI, refactors, tests) don't need one; a maintainer adds the `skip changelog` label.
6. Open the PR against `main` and fill in the template. Link the issue it closes.
7. A maintainer reviews it. We squash-merge, so the PR title becomes the commit message. Write it in the imperative ("Add charging activity", not "Added...").

`main` should always build and pass tests. Release tags (`v0.3.0`) are cut from `main`.

## Sign your commits (DCO)

Liova uses the [Developer Certificate of Origin](https://developercertificate.org/) instead of a CLA. By signing off a commit you certify that you wrote the change, or otherwise have the right to submit it under the MIT license.

Add the sign-off with `-s`:

```sh
git commit -s -m "Add charging live activity"
```

This appends a line to the commit message:

```
Signed-off-by: Your Name <you@example.com>
```

The name and email must match your Git config. Every commit in a PR needs it; the DCO check blocks merging otherwise. If you forgot:

```sh
git commit --amend -s --no-edit          # last commit only
git rebase --signoff main                # every commit on your branch
git push --force-with-lease
```

Why we care: a notch app touches the same problems as several GPL-licensed projects, and GPL code in this repo would break the MIT license for everyone who depends on it. The sign-off is our record that each line has a clean origin.

## The clean-room rule

Liova is MIT-licensed. To keep it that way:

- **Never open the source of a GPL (or AGPL, or unlicensed) notch app while writing the matching Liova subsystem.** If you have studied how another project draws its notch, don't then write our notch shape with their code in another tab. Close it, and write ours from your own understanding and Apple's documentation.
- **Describe techniques in your own words.** "Use one fixed panel per display and animate only the content" is an idea and is fine to discuss. Pasting, translating, or closely paraphrasing someone else's code is not.
- **No code from decompiled or reverse-engineered binaries**, ever, in any form.
- **Dependencies must be MIT, BSD, Apache-2.0, or similarly permissive.** No GPL, LGPL, AGPL, or unlicensed packages. Call out any new dependency in your PR description with its license.
- If you are unsure whether something is clean, ask in the PR. We would rather rewrite a function than defend a takedown notice.

## Code style

**Formatting and linting.** SwiftFormat and SwiftLint are the source of truth; their configs live in the repo root. Run `make format` before committing, and `make lint` must pass with zero warnings. Don't argue with the formatter in review; change the config in a separate PR if it's wrong.

**Language.** Swift 6 language mode with strict concurrency, everywhere. Don't add `@unchecked Sendable` or `nonisolated(unsafe)` without a comment explaining why it's safe and a reviewer agreeing.

**State and structure.**

- **No singletons.** No `static let shared`. Pass dependencies in through initializers. This keeps features testable and swappable.
- **No root `ObservableObject`.** There is no app-wide state object that every view watches.
- **One `@Observable` store per feature** (media, battery, shelf...). Views read only the properties they render, so a battery tick never re-renders the media view.
- **Actors for I/O.** File, network, helper and socket work runs off the main actor.
- **Providers behind protocols.** Anything that talks to the system (Now Playing, power, key events, window server) is a protocol with a real and a fake implementation, so stores can be tested without a Mac's hardware.
- **Respect module boundaries.** `LiovaPluginKit` depends on nothing. `LiovaCore` does not import SwiftUI. The `App` target stays thin. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#module-boundaries).

**Tests.** New logic in `LiovaCore`, stores, and geometry gets unit tests in `Packages/LiovaKit/Tests`. Pure structs (like notch geometry) should be tested against real display values.

**Comments.** Explain *why*, not *what*. Link the Apple doc or issue when the reason is non-obvious.

## Performance rules

Smoothness is a feature and our budget is a release blocker. The short version of the architecture rules; [docs/PERFORMANCE.md](docs/PERFORMANCE.md) has the full set, the budget, and how to measure:

1. **Fixed panel, animated shape.** One `NSPanel` per display, never resized. Animate the SwiftUI shape inside it.
2. **Render isolation.** Per-feature `@Observable` stores; views read only what they draw.
3. **Event-driven, no polling.** Use system notifications and listeners. Any timer goes through the shared, visibility-aware scheduler.
4. **Hover without polling.** Event-driven pointer monitoring with an intent delay in a cancellable task. Never a mouse-position timer.
5. **One motion system.** Use the shared springs in `LiovaUI`. Never animate the window frame.
6. **Streaming values bypass animation.** Sliders and progress are written with animations disabled; timelines capped at 30 fps and paused when hidden.
7. **Cheap visuals.** Blur once and cache; one material/glass layer, not stacks.
8. **Off the main thread.** I/O, decoding, IPC and sockets run on actors.

If your change touches anything that renders or runs while idle, say how you checked it in the PR.

## Pull request checklist

Before you request review:

- [ ] Every commit is signed off (`git commit -s`).
- [ ] `make format lint test` passes locally.
- [ ] CHANGELOG.md has a line under [Unreleased] (or the change is invisible to users).
- [ ] New logic has tests; existing tests still pass.
- [ ] No new polling, timers, or always-on work while the notch is closed.
- [ ] No new singletons or app-wide observable state.
- [ ] UI changes include a screenshot or short GIF (light and dark if relevant).
- [ ] Any new dependency is permissively licensed and named in the description.
- [ ] Any new permission prompt is requested only when the feature that needs it is turned on.
- [ ] Docs updated if behaviour, setup, or the public API changed.

## Good first issues

Issues labelled [`good first issue`](https://github.com/Krishnarajan7/Liova/labels/good%20first%20issue) are scoped to be finishable in an evening and come with pointers to the files involved. To pick one:

1. Comment on the issue to claim it, so two people don't do the same work.
2. If you get stuck, ask in the issue. Questions are welcome; that's what the label is for.
3. If you go quiet for two weeks, we may unassign it so someone else can pick it up. No hard feelings.

Good places to start: unit tests for geometry and the activity engine, new live-activity types, accessibility labels, translations, and docs.

Larger ideas belong in [Discussions](https://github.com/Krishnarajan7/Liova/discussions) first.

# Distribution

How Liova is built and shipped without a paid Apple Developer account, what users need to do on first launch, and what changes if we add notarization later. The reasoning is in [ADR-007](DECISIONS.md#adr-007-no-apple-developer-account-for-now).

## Summary

| Channel | Status | Command / link |
| --- | --- | --- |
| Build from source | Available | `make setup && make run` |
| DMG on GitHub Releases | From alpha | [Releases](https://github.com/Krishnarajan7/Liova/releases) |
| Self-hosted Homebrew tap | Planned for v1.0 | `brew install --cask krishnarajan7/tap/liova` |
| In-app updates | Available | Checked daily; install in place when signed with the release certificate |
| Official Homebrew cask | Not possible yet | Needs notarization |
| Mac App Store | Never | Its sandbox rules out what a notch app needs |

## How releases are built

Locally, one command builds a release:

```bash
make release VERSION=0.2.0     # → build/release/Liova-0.2.0.dmg and .sha256
```

It builds the **universal** (Apple Silicon + Intel) Release app, puts the `liova` CLI inside it at `Contents/Helpers/liova` (so Settings can connect agents with one click), signs it all with `scripts/release/sign-app.sh` (see [The release certificate](#the-release-certificate)), and packages a drag-to-install DMG with an `/Applications` shortcut and an "If Liova won't open" note. Locally it's signed with the "Liova Development" certificate when present (`make dev-cert`), otherwise ad-hoc; pass `SIGN_IDENTITY=` to choose.

On GitHub, pushing a tag runs `.github/workflows/release.yml`:

1. Check that [CHANGELOG.md](../CHANGELOG.md) has a `## [<version>]` section; it becomes the release notes. A missing section stops the release.
2. Run the tests; a failure stops the release.
3. Sign with the release certificate in the `LIOVA_SIGNING_P12` / `LIOVA_SIGNING_PASSWORD` secrets. A tag without them stops the release: a copy signed ad-hoc can never update itself to a signed one, so its users would have to update by hand forever. (A manual run from the Actions tab may sign ad-hoc, for testing only.)
4. `make release VERSION=<tag>` and compute the SHA-256.
5. Create a **draft** GitHub Release with the DMG, the checksum, install notes and the changelog section. Nothing is public until a maintainer reviews it and clicks **Publish**.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

### Release checklist

Before tagging:

- [ ] CI is green on `main`.
- [ ] In [CHANGELOG.md](../CHANGELOG.md), the `[Unreleased]` entries are moved under `## [x.y.z] - YYYY-MM-DD`, and an empty `[Unreleased]` is left on top.
- [ ] `CURRENT_PROJECT_VERSION` in `project.yml` is one higher than the last release's. (The version number itself comes from the tag.)
- [ ] `make perf` passes on a real Mac, hands off (the strict budgets CI can't check: 300 ms launch, 0.05% idle CPU).
- [ ] A clean install works in a second macOS user account: first launch, every permission prompt, the welcome screen.
- [ ] The previous release updates itself to this one from Settings → Updates (from v0.2.0 on).

After publishing:

- [ ] The README's "Early preview" note and "Get it" section point at the download (first release only).
- [ ] Issues fixed in this release are closed with a link to it, and the `fixed in next release` label removed.

Not done yet: the Homebrew tap.

## First launch for users

Because Liova isn't notarized, macOS blocks it the first time with a message that it "cannot verify" the app or that it "was not opened". This is expected. Approve it once:

**Option A: System Settings (recommended)**

1. Open the DMG and drag **Liova** to **Applications**.
2. Open Liova from Applications. macOS shows a warning; click **Done** (or **Cancel**).
3. Open **System Settings → Privacy & Security**.
4. Scroll to the **Security** section. You'll see "Liova was blocked to protect your Mac." Click **Open Anyway**.
5. Confirm with your password or Touch ID, then click **Open Anyway** again in the dialog.

You only do this once per installed copy.

**Option B: Terminal**

```sh
xattr -dr com.apple.quarantine /Applications/Liova.app
```

This removes the quarantine flag that Gatekeeper checks. Only do this for a copy you downloaded from the official [Releases page](https://github.com/Krishnarajan7/Liova/releases) or built yourself.

**Verifying a download.** Each release lists the DMG's SHA-256:

```sh
shasum -a 256 ~/Downloads/Liova-<version>.dmg
```

Compare it with the value in the release notes.

**Permissions.** Liova asks for each permission (Accessibility, Calendar, and so on) only when you turn on a feature that needs it. Note that with ad-hoc signing, macOS may ask you to grant Accessibility again after an update, because it sees the updated app as a new identity. Release notes will say when this applies.

## Updates

Liova updates itself without Sparkle or any other dependency ([ADR-017](DECISIONS.md#adr-017-built-in-updates-trust-the-release-certificate)). The code is in `LiovaProviders/Updates` and `LiovaFeatures/Updates`.

**Finding one.** About a minute after launch, and then once a day, Liova asks GitHub's public API for the repository's releases (one unauthenticated request carrying only Liova's name and version). It offers the newest one above the running version that has an installer; betas only when **Include beta versions** is on. The closed notch says so once per version, the menu bar menu shows **Update to x.y.z…**, and **Settings → Updates** shows the release notes. **Skip** silences that version; **Check for updates automatically** turns the daily check off.

**Installing it.** On **Update** (in the notch) or **Install and Relaunch** (in Settings):

1. Download `Liova-x.y.z.dmg` (only from `github.com/Krishnarajan7/Liova/releases/download/…`, at most 300 MB) and check it against the release's `.sha256`. This catches a broken download; it isn't what makes the update trusted.
2. Mount the image read-only and check the app inside: same bundle ID, the version the release claims, and a valid signature (every architecture, everything nested) that **satisfies the running copy's designated requirement**. For a release build that requirement pins the release certificate (`certificate leaf = H"…"`), so only an app signed with that certificate's private key passes. Copy it out and check the copy again.
3. Start a small shell helper (paths passed as arguments, never pasted into the script) and quit. Once Liova has quit, the helper moves the old app aside, moves the new one in (putting the old one back if that fails), and opens it.

**When it can't install in place**, it downloads and checks the installer the same way and opens it in Finder; Settings explains why:

- the running copy is signed ad-hoc (built from source, or a release made without the certificate), so it has no certificate to pin;
- macOS is running it from a temporary location because it wasn't moved to Applications;
- it can't write to its folder.

## The release certificate

Releases are signed with a self-signed "Liova Release" certificate that lives only in GitHub secrets and the maintainer's offline backup. It does two jobs: macOS keeps users' permissions (Accessibility, Calendar, Location) across updates because the app's identity stays the same, and updates install themselves only when they carry this signature.

**Creating it (once):**

```sh
scripts/release/create-release-cert.sh        # writes ~/Desktop/liova-release-cert/
```

It prints the two commands that store the `.p12` and its password as the `LIOVA_SIGNING_P12` and `LIOVA_SIGNING_PASSWORD` secrets. Then back the folder up offline (a password manager) and delete it from the Mac. Never commit it.

**Signing.** `make release` builds ad-hoc, then `scripts/release/sign-app.sh` signs inside out with `codesign`: the Now Playing framework, the `liova` CLI, then the app with the hardened runtime and exactly `App/Liova.entitlements`. It's done with `codesign` rather than Xcode because Xcode only offers identities the Mac trusts, and a self-signed certificate is trusted nowhere (verifying a signature against a pinned certificate doesn't need trust). The script fails the release if the app carries `get-task-allow` or if its designated requirement doesn't pin a certificate. In CI the identity is picked by its SHA-1 from a temporary keychain.

**Rules:**

- **Make it once.** Copies only trust updates signed with the certificate they were signed with. A new certificate means every user installs the next version by hand once.
- **It's valid for 20 years.** Signatures carry no secure timestamp, so they're only valid while the certificate is. Plan a hand-installed migration long before it expires.
- **If it leaks,** anyone holding it can ship an update that installs itself. Remove the secrets, make a new certificate, publish a security advisory, and ask users to reinstall from the Releases page.
- **The first signed release** replaces ad-hoc builds by hand (they have nothing to pin). From then on, updates install themselves.

## Self-hosted Homebrew tap

Homebrew's official cask repository disables casks that fail Gatekeeper checks, so Liova can't be listed there until it's notarized. Instead we maintain our own tap:

- Repository: `github.com/Krishnarajan7/homebrew-tap`, containing `Casks/liova.rb`.
- Install: `brew install --cask krishnarajan7/tap/liova`
- The release workflow updates the cask's `version` and `sha256` on each release.
- The cask declares `auto_updates true`, since Liova updates itself.
- The cask's `caveats` print the first-launch instructions above. We don't strip the quarantine flag silently; users should see and approve what they're running.

## If we add notarization later

If an Apple Developer Program membership is obtained, the switch is a build-pipeline change only. No app architecture changes.

| Area | Today (ad-hoc) | With notarization |
| --- | --- | --- |
| Signing | `CODE_SIGN_IDENTITY=-` | Developer ID Application certificate, stored as a CI secret |
| Notarization | None | `xcrun notarytool submit --wait`, then `xcrun stapler staple` on the DMG |
| First launch | Gatekeeper warning, "Open Anyway" | Opens normally |
| Permissions after updates | May need re-granting | Persist, because the signing identity is stable |
| Homebrew | Self-hosted tap only | Submit to the official cask repository; keep the tap as an alias or retire it |
| Updates | Installed in place when signed with the pinned release certificate | Same check, pinning the Developer ID requirement instead |
| Helpers and extensions | Ad-hoc signed | Signed with the same Developer ID; tier 3 extensions can require it |

One-time migration notes:

- Copies signed with the release certificate won't install a Developer ID build by themselves (it doesn't satisfy their pinned requirement), so the first notarized release is installed by hand once; Settings opens its installer in Finder. Updates are automatic again from then on.
- Users may need to re-grant permissions once, because the code identity changes from ad-hoc to Developer ID.
- The README and release notes drop the first-launch instructions.

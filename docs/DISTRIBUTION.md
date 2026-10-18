# Distribution

How Liova is built and shipped without a paid Apple Developer account, what users need to do on first launch, and what changes if we add notarization later. The reasoning is in [ADR-007](DECISIONS.md#adr-007-no-apple-developer-account-for-now).

## Summary

| Channel | Status | Command / link |
| --- | --- | --- |
| Build from source | Available | `make setup && make run` |
| DMG on GitHub Releases | From alpha | [Releases](https://github.com/Krishnarajan7/Liova/releases) |
| Self-hosted Homebrew tap | Planned for v1.0 | `brew install --cask krishnarajan7/tap/liova` |
| In-app updates (Sparkle) | From alpha | Automatic, EdDSA-verified |
| Official Homebrew cask | Not possible yet | Needs notarization |
| Mac App Store | Never | Its sandbox rules out what a notch app needs |

## How releases are built

Locally, one command builds a release:

```bash
make release VERSION=0.2.0     # → build/release/Liova-0.2.0.dmg and .sha256
```

It builds the **universal** (Apple Silicon + Intel) Release app, puts the `liova` CLI inside it at `Contents/Helpers/liova` (so Settings can connect agents with one click), re-signs the app, and packages a drag-to-install DMG with an `/Applications` shortcut and an "If Liova won't open" note. It's signed with the local "Liova Development" certificate when present (`make dev-cert`), otherwise ad-hoc.

On GitHub, pushing a tag runs `.github/workflows/release.yml`:

1. Run the tests; a failure stops the release.
2. Sign with the certificate in the `LIOVA_SIGNING_P12` / `LIOVA_SIGNING_PASSWORD` secrets if they exist (a stable identity keeps users' macOS permissions across updates), otherwise ad-hoc.
3. `make release VERSION=<tag>` and compute the SHA-256.
4. Create a **draft** GitHub Release with the DMG, the checksum and install notes. Nothing is public until a maintainer edits the notes and clicks **Publish**.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

Not done yet: Sparkle auto-updates (needs the Sparkle dependency, see below) and the Homebrew tap.

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

## Sparkle updates and the EdDSA key

Sparkle verifies every update with an **EdDSA (Ed25519) signature** before installing it. This is independent of Apple code signing, so it works without a Developer account and protects users even though our builds aren't notarized.

**Keys:**

- The **public key** is embedded in the app's `Info.plist` as `SUPublicEDKey`. It's safe to commit.
- The **private key** signs updates. Whoever holds it can push code to every Liova user, so:
  - It is **never committed** to the repository, in any form, in any branch.
  - It lives in a GitHub Actions secret, `SPARKLE_ED_PRIVATE_KEY`, available only to the release workflow, and only on tag builds from `main`.
  - The maintainer keeps one offline backup (for example, in a password manager). If the key is lost, existing installs cannot be updated automatically and users must reinstall manually.

**Generating the key (one time, maintainer only):**

```sh
# Sparkle's tools ship in the Sparkle release archive (bin/)
./bin/generate_keys                 # creates the key in your login Keychain, prints the public key
./bin/generate_keys -x sparkle_private_key   # exports the private key to a file
```

Paste the public key into `Info.plist`. Paste the contents of `sparkle_private_key` into the GitHub secret, store the backup, then **delete the exported file**.

**Signing in CI:** the release workflow pipes the secret to Sparkle's `sign_update` tool and never writes it to the log or to disk outside the job's temp directory. `appcast.xml` is published alongside the release so the app can find updates.

**If the private key leaks:** rotate immediately. Generate a new key pair, ship a release signed with the **old** key that contains the **new** public key, then switch CI to the new private key. Publish a security advisory.

## Self-hosted Homebrew tap

Homebrew's official cask repository disables casks that fail Gatekeeper checks, so Liova can't be listed there until it's notarized. Instead we maintain our own tap:

- Repository: `github.com/Krishnarajan7/homebrew-tap`, containing `Casks/liova.rb`.
- Install: `brew install --cask krishnarajan7/tap/liova`
- The release workflow updates the cask's `version` and `sha256` on each release.
- The cask declares `auto_updates true`, since Sparkle handles updates in the app.
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
| Sparkle | EdDSA | EdDSA (unchanged), plus Sparkle also validates the Developer ID signature |
| Helpers and extensions | Ad-hoc signed | Signed with the same Developer ID; tier 3 extensions can require it |

One-time migration notes:

- The first notarized release is installed over ad-hoc builds by Sparkle as usual, since EdDSA verification doesn't change.
- Users may need to re-grant permissions once, because the code identity changes from ad-hoc to Developer ID.
- The README and release notes drop the first-launch instructions.

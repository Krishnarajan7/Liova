# Vendored: mediaremote-adapter

- Upstream: https://github.com/ungive/mediaremote-adapter
- Commit: `0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd` (2026-10-17)
- License: BSD-3-Clause (see `LICENSE`), compatible with Liova's MIT license.
- Copied: `LICENSE`, `README.md`, `CMakeLists.txt`, `bin/`, `include/`, `src/`. Not copied: editor, CI and dev scripts.
- Local changes: none. Keep it that way; fix upstream and re-vendor.

Why: since macOS 15.4, `mediaremoted` only serves processes with an Apple bundle
identifier. `/usr/bin/perl` has one, so the adapter's Perl script loads this framework
inside Perl and streams Now Playing data as JSON. Liova never impersonates an Apple
bundle ID itself (see ADR-010).

Built by `make` (`make vendor`) into `build/vendor/`, then copied into
`Liova.app/Contents/Resources/MediaRemoteAdapter/`.

To update: clone upstream, review the diff (no network, no process spawning outside
`test`), replace these files, update the commit above, run `make vendor && make test`.

# Security Policy

Liova runs as a background agent with access to things like Accessibility events, media state, and a local socket that other programs can talk to. We take that trust seriously.

## Supported versions

Liova is pre-1.0. Only the latest release receives security fixes.

| Version | Supported |
| --- | --- |
| Latest release on [GitHub Releases](https://github.com/Krishnarajan7/Liova/releases) | Yes |
| `main` branch | Yes (fixes land here first) |
| Anything older | No, please update |

After v1.0 we will support the latest minor release line.

## Reporting a vulnerability

**Do not open a public issue, Discussion, or pull request for a security problem.**

Report it privately through GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/Krishnarajan7/Liova/security) of the repo.
2. Click **Report a vulnerability** ([direct link](https://github.com/Krishnarajan7/Liova/security/advisories/new)).
3. Describe the issue, the affected version and macOS version, and steps to reproduce. A proof of concept helps a lot.

What to expect:

- An acknowledgement within **3 days**.
- An initial assessment within **7 days**.
- A fix or mitigation plan within **30 days** for confirmed issues, faster for anything actively exploitable.
- Credit in the release notes and the advisory, unless you'd rather stay anonymous.

Please give us a reasonable chance to ship a fix before disclosing publicly. We will coordinate the disclosure date with you.

## Scope

In scope, with examples of what we most want to hear about:

| Area | Examples |
| --- | --- |
| **Local socket API** and the `liova` CLI | Another local user connecting to your socket; bypassing the peer UID check; malformed JSON crashing the app or causing memory corruption; path traversal through activity payloads |
| **`liova://` URL scheme** | A web page or document triggering actions without user intent |
| **Plugin model** | A declarative (tier 2) widget executing code inside the Liova process; an extension (tier 3) escaping its sandbox or reading another plugin's data; unsigned extensions being loaded |
| **Helpers** (e.g. the Now Playing bridge) | Command injection into the helper; the helper being replaceable or hijackable by another process |
| **Updates** | Sparkle appcast or update package accepted without a valid EdDSA signature |
| **Permissions** | Liova gaining or using a permission (Accessibility, Calendar, etc.) for a feature that is turned off |
| **Agent Island** | A coding-agent hook allowing approvals to be spoofed, or leaking prompts or tokens |

Out of scope:

- Problems that need an attacker who already has full control of your user account (e.g. can already edit `~/Library` freely and run arbitrary code as you).
- Gatekeeper warnings on our ad-hoc signed builds; that is expected until we notarize (see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)).
- Vulnerabilities in macOS itself or in third-party apps. Please report those to their vendors.
- Denial of service by flooding your own socket as your own user.

## Our security principles

These are design commitments, and violating any of them is a bug.

1. **Least privilege.** Each permission is requested only when the feature that needs it is switched on, with the reason shown in the app. Turning a feature off stops using that permission.
2. **No telemetry, ever.** Liova sends no analytics or usage data. Crash reports are opt-in and stay local unless you choose to share them. Network access is limited to features that obviously need it (update checks, lyrics) and can be disabled.
3. **Plugins are out-of-process.** No third-party code runs inside the Liova process. Tier 1 pushes JSON over the socket, tier 2 is a declarative manifest rendered by our own templates, and tier 3 extensions run in their own sandboxed process and must be signed.
4. **A locked-down socket.** The socket lives in Liova's Application Support folder in a directory with mode `0700`. Every connection's peer UID is checked against the current user, and messages are size-limited and validated against a schema before use.
5. **No impersonation of Apple.** We never use Apple bundle IDs (`com.apple.*`) or otherwise pretend to be a system component to get access. Now Playing goes through an open, documented bridge.
6. **No freezing system processes.** We never `SIGSTOP` or otherwise suspend system processes. HUD replacement uses an event tap, with a watchdog that restores normal behaviour if the tap is disabled, and a safe-mode launch flag.
7. **Private APIs are isolated.** The few private window-server calls we use live in one module, are resolved at runtime, and fall back to public APIs if missing.
8. **Signed updates.** Every update is verified with Sparkle's EdDSA signature. The private key is never committed to the repo.
9. **Permissive, auditable dependencies.** Small dependency tree, all MIT/BSD/Apache, pinned versions.

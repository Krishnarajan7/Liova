# Agent Island

Agent Island shows what your coding agent is doing, right in the notch: when it starts working, which tool it is running ("Running `npm test`", "Editing App.swift"), when it is waiting for you, and when it is done. When the agent asks for permission to do something, you can **approve or deny it from the notch** without switching to the terminal.

Claude Code is supported today. Codex, Cursor and Gemini CLI are next (see [the plan](#other-agents)).

- [Setup](#setup)
- [What Liova sees](#what-liova-sees)
- [Approve and deny](#approve-and-deny)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Other agents](#other-agents)

## Setup

With Liova installed, run one command:

```sh
liova agents install claude-code
```

Then start a new Claude Code session. That's it.

The installer adds a few hooks to your Claude Code user settings (`~/.claude/settings.json`). It is careful with that file:

- **Nothing else changes.** Your other settings and any hooks you or other tools added are kept as they are, in the same order.
- **A backup comes first.** Before writing, it saves the current file next to it as `settings.json.liova-backup-YYYYMMDD-HHMMSS`.
- **Atomic writes.** The new file is written to a temporary file and renamed into place, with the original permissions, so Claude Code never sees a half-written file.
- **Invalid files are left alone.** If `settings.json` isn't valid JSON, the installer says where the problem is and stops without touching it.
- **Safe to run again.** Running it again replaces Liova's own hooks (for example after you move Liova) and never duplicates them. If nothing needs to change, nothing is written.
- **Symlinks survive.** If your settings file is a symlink into a dotfiles repository, the target is edited and the link stays.

To see what it would do first:

```sh
liova agents install claude-code --dry-run
```

To check the setup at any time:

```sh
$ liova agents status
Claude Code: installed (/Users/you/.claude/settings.json)
```

`status` also tells you when the hooks are **outdated**, for example because Liova moved and the hooks still point at the old location. Run `liova agents install claude-code` again to fix that.

To use another settings file (a project's `.claude/settings.json`, say), pass `--settings PATH` to `install`, `uninstall` and `status`.

## What Liova sees

The hooks send Liova only what the notch needs:

| Sent | Example |
| --- | --- |
| The kind of event | session started, working, tool started, tool finished, waiting for you, finished, session ended |
| The project folder's name (not its full path) | `MyApp` |
| A short summary of the current tool | `Running npm test`, `Editing App.swift`, `Searching`, `Using github` |
| Claude Code's session ID | to tell sessions apart |
| For a permission request: the tool and what it wants to do | `Bash`: `rm -rf node_modules && npm install` |

**Never sent:** your prompts, Claude's replies, file contents, tool output, or anything from subagents except their permission requests.

Everything stays on your Mac. The hooks talk to Liova over a private Unix socket that only your user account can open; nothing goes over the network. See the [security model](PLUGIN-API.md#security-model).

## Approve and deny

When Claude Code needs your permission (to run a command, edit a file, fetch a URL...), Liova shows the request in the notch with the tool and exactly what it wants to do.

- **Allow** lets Claude Code go ahead.
- **Deny** stops it. Claude is told "Denied from the Liova notch." and carries on with that in mind.
- **Answer in the terminal** hands the question back, and Claude Code shows its usual permission prompt.

Liova never makes a decision on its own. If you don't answer within 5 minutes, if Liova isn't running, or if anything goes wrong, the hook steps aside and Claude Code asks in the terminal as it always does. Requests are not sent at all when Claude Code is in a mode that doesn't ask (`bypassPermissions` or `dontAsk`).

While a request is shown in the notch, Claude Code waits for that answer before showing its own prompt. If you'd rather it fall back to the terminal sooner, edit the `PermissionRequest` hook's command in `~/.claude/settings.json` to add a shorter timeout:

```
'/Applications/Liova.app/Contents/MacOS/liova' hook claude-code --timeout 60
```

Keep it below the hook's own `timeout` (310 seconds), or Claude Code stops waiting first.

## Uninstall

```sh
liova agents uninstall claude-code
```

This removes only Liova's hooks. Everything else in your settings stays, and the previous file is backed up first. `--dry-run` works here too.

## Troubleshooting

**Nothing shows up in the notch.**

1. Is Liova running? `liova ping` should say so.
2. Are the hooks installed and current? `liova agents status`.
3. Did you start a **new** Claude Code session after installing? Claude Code reads hooks when a session starts; a running session may ask you to review the change in its `/hooks` menu first.
4. Run Claude Code with hook debugging on, and check its transcript or verbose output for lines starting with `liova hook:`:

   ```sh
   LIOVA_HOOK_DEBUG=1 claude
   ```

   You can also try the hook by hand:

   ```sh
   echo '{"session_id":"test","cwd":"/tmp/demo","hook_event_name":"Stop"}' \
       | LIOVA_HOOK_DEBUG=1 liova hook claude-code
   ```

**`liova agents install` says the file isn't valid JSON.** Open the file it names at the line it gives, fix the mistake (often a trailing comma), and run the command again. Liova never overwrites a file it can't read correctly.

**I moved Liova.app.** Run `liova agents install claude-code` again. It updates the hooks in place.

**Does it slow Claude Code down?** No. Each event hook connects to Liova, hands over a few hundred bytes and exits, typically in well under 30 ms. If Liova isn't running or doesn't answer within 300 ms, the hook gives up silently. It never prints anything Claude Code would see (except your permission decision) and always exits successfully, so it can't block or break a session.

## How it works

`liova agents install` registers one command, `liova hook claude-code`, for these Claude Code hook events:

| Claude Code event | Shown in the notch |
| --- | --- |
| `SessionStart` | Session started |
| `UserPromptSubmit` | Working (the prompt itself is not sent) |
| `PreToolUse` | The tool being run, e.g. "Editing App.swift" |
| `PostToolUse` | Tool finished |
| `PermissionRequest` | The approval request |
| `Notification` (idle) | Waiting for you |
| `Stop` | Finished |
| `SessionEnd` | Session ended |

The hook reads the event from stdin, turns it into Liova's agent-neutral format, and sends it over the socket as an `agentEvent` or `agentPermission` request (see [the protocol](PLUGIN-API.md#agent-island)). For a permission request it waits for your answer and prints Claude Code's decision JSON; in every other case it prints nothing.

The hook's settings entries look like this (the path is wherever your `liova` lives):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/Applications/Liova.app/Contents/MacOS/liova hook claude-code", "timeout": 5 }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/Applications/Liova.app/Contents/MacOS/liova hook claude-code", "timeout": 310 }
        ]
      }
    ]
  }
}
```

## Other agents

Liova's side only speaks one agent-neutral vocabulary (`agentEvent`, `agentPermission`); each agent gets a small adapter in the `liova` command that translates its hook format. The plan for v1.0:

| Agent | Status | Approach |
| --- | --- | --- |
| Claude Code | **Supported** | Hooks in `~/.claude/settings.json` |
| Codex | Planned | Codex CLI's notification and approval hooks in `~/.codex/config.toml` |
| Cursor | Planned | Cursor's agent hooks (`hooks.json`) |
| Gemini CLI | Planned | Gemini CLI's hooks in `~/.gemini/settings.json` |

Each will get the same one-command setup (`liova agents install <agent>`), the same privacy rules, and approve/deny wherever the agent lets a hook answer a permission request. Building an adapter for another agent? The [plugin API](PLUGIN-API.md#agent-island) documents the two requests, and contributions are welcome.

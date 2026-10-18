# Agent Island

Agent Island shows what your coding agent is doing, right in the notch: when it starts working, which tool it is running ("Running `npm test`", "Editing App.swift"), when it is waiting for you, and when it is done. When the agent asks for permission to do something, you can **approve or deny it from the notch** without switching to the terminal.

| Agent | Shows what it's doing | Approve and deny from the notch | Settings file |
| --- | --- | --- | --- |
| Claude Code | Yes | Yes | `~/.claude/settings.json` |
| Codex CLI | Yes | Yes | `~/.codex/hooks.json` |
| Gemini CLI | Yes, including "waiting for your approval" | No ([why](#gemini-cli)) | `~/.gemini/settings.json` |
| Cursor | Yes | No ([why](#cursor)) | `~/.cursor/hooks.json` |

- [Setup](#setup)
- [Codex CLI](#codex-cli)
- [Gemini CLI](#gemini-cli)
- [Cursor](#cursor)
- [What Liova sees](#what-liova-sees)
- [Approve and deny](#approve-and-deny)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Sources](#sources)

## Setup

With Liova installed, run one command for each agent you use:

```sh
liova agents install claude-code
liova agents install codex
liova agents install gemini-cli
liova agents install cursor
```

Then start a new session of that agent. That's it. (Codex asks you to trust new hooks first; see [Codex CLI](#codex-cli).)

The installer adds a few hooks to the agent's user settings (for Claude Code, `~/.claude/settings.json`; the table above lists the others). It is careful with that file:

- **Nothing else changes.** Your other settings and any hooks you or other tools added are kept as they are, in the same order.
- **A backup comes first.** Before writing, it saves the current file next to it as, for example, `settings.json.liova-backup-YYYYMMDD-HHMMSS`.
- **Atomic writes.** The new file is written to a temporary file and renamed into place, with the original permissions, so the agent never sees a half-written file.
- **Invalid files are left alone.** If the file isn't valid JSON (Gemini CLI also accepts comments in `settings.json`; Liova doesn't edit such a file), the installer says where the problem is and stops without touching it. You can then add the hooks by hand from the examples below.
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
Codex: installed (/Users/you/.codex/hooks.json)
Gemini CLI: not installed (/Users/you/.gemini/settings.json)
  Set it up with: liova agents install gemini-cli
Cursor: not installed (/Users/you/.cursor/hooks.json)
  Set it up with: liova agents install cursor
```

`status` also tells you when the hooks are **outdated**, for example because Liova moved and the hooks still point at the old location. Run `liova agents install <agent>` again to fix that. It warns about settings that stop the hooks from running, such as Gemini CLI's hooks being turned off.

To use another file (a project's `.claude/settings.json` or `.codex/hooks.json`, say), pass `--settings PATH` to `install`, `uninstall` and `status <agent>`.

### Codex CLI

Liova uses Codex's hooks, which Codex reads from `~/.codex/hooks.json` (same format as Claude Code's hooks). Your `config.toml` is never edited; `liova agents install codex` only reads it to warn you if hooks are turned off there (`[features] hooks = false`) or if it also has inline `[hooks]` tables (Codex runs both, but warns at startup when one folder uses both forms).

**Trust the hooks once.** Codex runs a new or changed hook only after you've reviewed and trusted it. After installing, start Codex and trust Liova's hooks when it asks, or in its `/hooks` menu. Do it again after `liova agents install codex` changes the hooks (for example after you moved Liova).

What's supported: session start and end, working, the current tool (`Running swift test`, `Editing App.swift` for a patch), finished, and **approve or deny** for Codex's `PermissionRequest` hook. For a patch, the notch shows which files it adds, updates or deletes, never the patch itself. Requests aren't sent when Codex runs in a mode that doesn't ask (`bypassPermissions`, `dontAsk`).

**Older Codex without hooks.** Codex's `notify` setting runs a program when a turn finishes. Liova understands it too, but won't edit your `config.toml` for it (only one `notify` program is allowed, and it may already be in use). Add this top-level line yourself, before any `[table]`:

```toml
notify = ["/Applications/Liova.app/Contents/MacOS/liova", "hook", "codex"]
```

That shows only "finished"; use hooks when your Codex has them.

### Gemini CLI

Liova adds hooks to the `hooks` object of `~/.gemini/settings.json`, named `liova` so `/hooks disable liova` and `/hooks enable liova` work. Gemini CLI's hooks must be on (`"hooksConfig": {"enabled": true}` is the default).

What's supported: session start and end, working, the current tool, finished, and **"waiting for your approval"** with what Gemini wants to do ("Approve? Running \`rm -rf build\`"). You answer in the terminal: Gemini CLI's hooks can block a tool or force a confirmation, but a hook's "allow" doesn't answer Gemini's own approval prompt, so approving in the notch would make you approve twice. The diff and file contents Gemini includes in its approval notification are never sent.

Gemini CLI reads a hook's stderr when its stdout is empty, so with `LIOVA_HOOK_DEBUG=1` the debug lines show up in Gemini's output. That's harmless, and only happens while debugging.

### Cursor

Liova adds hooks to `~/.cursor/hooks.json` (creating it with `"version": 1` if needed). Cursor reloads the file on its own; restart Cursor if nothing shows up. Liova's entries go after any hooks you already have for an event.

What's supported: session start and end, working, the current tool (`preToolUse`), tool finished, and finished or stopped.

Approve and deny aren't supported. Cursor's permission hooks reliably enforce only "deny": a hook's "allow" doesn't skip Cursor's own approval, and "ask" isn't enforced in shell commands. Approving from the notch would either ask you twice or not hold, so Liova never answers Cursor's hooks and leaves approvals to Cursor. Liova's hooks print nothing, which Cursor treats as "no opinion".

## What Liova sees

The hooks send Liova only what the notch needs:

| Sent | Example |
| --- | --- |
| The kind of event | session started, working, tool started, tool finished, waiting for you, finished, session ended |
| The project folder's name (not its full path) | `MyApp` |
| A short summary of the current tool | `Running npm test`, `Editing App.swift`, `Searching`, `Using github` |
| The agent's session ID | to tell sessions apart |
| For a permission request: the tool and what it wants to do | `Bash`: `rm -rf node_modules && npm install` |

**Never sent:** your prompts, the agent's replies or thoughts, file contents, diffs and patch contents, tool output, or anything from subagents except their permission requests. Text that is sent is cut to a fixed length and stripped of control and invisible characters (including bidirectional overrides).

Everything stays on your Mac. The hooks talk to Liova over a private Unix socket that only your user account can open; nothing goes over the network. See the [security model](PLUGIN-API.md#security-model).

## Approve and deny

This works for **Claude Code and Codex**; Gemini CLI and Cursor don't let a hook answer their prompts (see their sections above).

When Claude Code or Codex needs your permission (to run a command, edit a file, fetch a URL...), Liova shows the request in the notch with the tool and exactly what it wants to do.

- **Allow** lets the agent go ahead.
- **Deny** stops it. The agent is told "Denied from the Liova notch." and carries on with that in mind.
- **Answer in the terminal** hands the question back, and the agent shows its usual permission prompt.

Liova never makes a decision on its own. If you don't answer within 5 minutes, if Liova isn't running, or if anything goes wrong, the hook steps aside and the agent asks in the terminal as it always does. Requests are not sent at all when the agent is in a mode that doesn't ask (`bypassPermissions` or `dontAsk`).

While a request is shown in the notch, Claude Code waits for that answer before showing its own prompt. If you'd rather it fall back to the terminal sooner, edit the `PermissionRequest` hook's command in `~/.claude/settings.json` to add a shorter timeout:

```
'/Applications/Liova.app/Contents/MacOS/liova' hook claude-code --timeout 60
```

Keep it below the hook's own `timeout` (310 seconds), or Claude Code stops waiting first. The same works for Codex's `PermissionRequest` hook in `~/.codex/hooks.json` (`hook codex --timeout 60`); Codex will ask you to trust the changed hook.

## Uninstall

```sh
liova agents uninstall claude-code   # or codex, gemini-cli, cursor
```

This removes only Liova's hooks. Everything else in your settings stays, and the previous file is backed up first. `--dry-run` works here too.

## Troubleshooting

**Nothing shows up in the notch.**

1. Is Liova running? `liova ping` should say so.
2. Are the hooks installed and current? `liova agents status`.
3. Did you start a **new** session after installing? Agents read hooks when a session starts; Claude Code may ask you to review the change in its `/hooks` menu first, and Codex skips hooks you haven't trusted in `/hooks`.
4. Run Claude Code with hook debugging on, and check its transcript or verbose output for lines starting with `liova hook:`:

   ```sh
   LIOVA_HOOK_DEBUG=1 claude
   ```

   You can also try the hook by hand (use `codex`, `gemini-cli` with `AfterAgent`, or `cursor` with `{"conversation_id":"test","hook_event_name":"stop"}` the same way):

   ```sh
   echo '{"session_id":"test","cwd":"/tmp/demo","hook_event_name":"Stop"}' \
       | LIOVA_HOOK_DEBUG=1 liova hook claude-code
   ```

**`liova agents install` says the file isn't valid JSON.** Open the file it names at the line it gives, fix the mistake (often a trailing comma, or a comment in Gemini CLI's `settings.json`), and run the command again. Liova never overwrites a file it can't read correctly.

**I moved Liova.app.** Run `liova agents install <agent>` again for each agent. It updates the hooks in place. Codex then asks you to trust the changed hooks.

**Does it slow my agent down?** No. Each event hook connects to Liova, hands over a few hundred bytes and exits, typically in well under 30 ms. If Liova isn't running or doesn't answer within 300 ms, the hook gives up silently. It never prints anything the agent would see (except your permission decision) and always exits successfully, so it can't block or break a session.

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

The other agents get the same single command (`liova hook codex`, `liova hook gemini-cli`, `liova hook cursor`) for these events:

| Shown in the notch | Codex | Gemini CLI | Cursor |
| --- | --- | --- | --- |
| Session started | `SessionStart` | `SessionStart` | `sessionStart` |
| Working | `UserPromptSubmit` | `BeforeAgent` | `beforeSubmitPrompt` |
| The current tool | `PreToolUse` | `BeforeTool` | `preToolUse` |
| Tool finished | `PostToolUse` | `AfterTool` | `postToolUse`, `postToolUseFailure` |
| The approval request | `PermissionRequest` | | |
| Waiting for your approval | | `Notification` (`ToolPermission`) | |
| Finished | `Stop` | `AfterAgent` | `stop` |
| Session ended | `SessionEnd` | `SessionEnd` | `sessionEnd` |

`liova hook cursor` also understands `beforeShellExecution`, `beforeMCPExecution`, `afterShellExecution`, `afterMCPExecution` and `afterFileEdit` if you wire them up yourself (for older Cursor versions without `preToolUse`). Timeouts: 5 seconds for events (3 for Codex's `SessionEnd`, Codex's maximum; Gemini CLI counts in milliseconds, so 5000), 310 seconds for Codex's `PermissionRequest`.

The hook reads the event from stdin, turns it into Liova's agent-neutral format, and sends it over the socket as an `agentEvent` or `agentPermission` request (see [the protocol](PLUGIN-API.md#agent-island)). For a permission request it waits for your answer and prints the decision JSON Claude Code and Codex share; in every other case it prints nothing.

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

## Sources

The hook formats come from each agent's documentation, as of October 2026. Formats change; if an agent stops showing up after it updates, `liova agents status` and `LIOVA_HOOK_DEBUG=1` are the first things to check.

- Claude Code: [Hooks reference](https://docs.claude.com/en/docs/claude-code/hooks)
- Codex CLI: [Hooks](https://developers.openai.com/codex/hooks) (events, `hooks.json` and inline `config.toml` forms, trust, `PermissionRequest` output); the `notify` setting in Codex's [configuration docs](https://developers.openai.com/codex/config-reference)
- Gemini CLI: [Hooks](https://geminicli.com/docs/hooks/), [Hooks reference](https://geminicli.com/docs/hooks/reference/) (events, stdin fields, millisecond timeouts, decisions) and [settings](https://geminicli.com/docs/reference/configuration/) (`hooksConfig`). Google replaced Gemini CLI with Antigravity CLI for personal accounts in June 2026 (see the notice on Gemini CLI's docs); Gemini CLI itself still works with API keys and enterprise accounts.
- Cursor: [Hooks](https://cursor.com/docs/hooks) (events, `hooks.json`, `permission` output, exit codes). On "allow" and "ask" not being enforced: [allow-list takes precedence](https://forum.cursor.com/t/beforeshellexecution-hook-permissions-allow-ask-ignored-allow-list-takes-precedence/144244), [ask ignored in shell execution](https://forum.cursor.com/t/beforeshellexecution-returns-permission-ask-but-sandboxed-agent-shell-still-runs-the-command-sandbox-true/155438), [allow doesn't bypass MCP approval](https://forum.cursor.com/t/hooks-return-allow-but-mcp-tool-still-requires-manual-approval-gets-skipped/155434).

Building an adapter for another agent? The [plugin API](PLUGIN-API.md#agent-island) documents the two requests, and contributions are welcome.

# Plugin API (tier 1)

Anything running on your Mac can put a live activity in Liova's notch: a build script, a CI runner, a coding agent, a cron job. This page is the reference for doing that.

There are three ways in, and they all end up in the same place:

| Way in | Best for | Trust |
| --- | --- | --- |
| [The `liova` command](#the-liova-command) | Shell scripts, hooks, one-liners | Full (runs as you) |
| [The socket](#the-socket) | Long-running programs in any language | Full (runs as you) |
| [`liova://` URLs](#liova-urls) | Links in documents, Shortcuts, other apps | Low (anything can open a URL) |

This is **tier 1** of Liova's plugin model: plugins push plain data, and Liova draws it with its own views. No plugin code ever runs inside Liova. (Tier 2 adds declarative widgets and tier 3 native extensions; see [ARCHITECTURE.md](ARCHITECTURE.md#plugin-tiers).)

## Concepts

An **activity** is one thing the notch can show: a title, optional subtitle, SF Symbol, progress bar and tint.

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string, required | 1 to 128 characters of `A-Z a-z 0-9 . _ -`. Starting an activity with an ID that is already live replaces it. |
| `source` | string | Who owns it, same character rules as `id`. Defaults to `cli` in the CLI. Names starting with `system.` (and `system` itself, any case) are reserved for Liova's built-in features. |
| `title` | string, required | Up to 200 characters, one line, not blank. |
| `subtitle` | string | Up to 200 characters, one line. |
| `symbol` | string | An SF Symbol name, such as `hammer.fill`. |
| `progress` | number | `0` to `1`. Omit it for no progress bar. Out-of-range values are clamped. |
| `tint` | string | `accent` (default), `green`, `yellow`, `orange`, `red`, `blue`, `purple`, `pink`, `gray`. |
| `priority` | string or integer | `low` (100), `normal` (200, default), `high` (300), `critical` (400), or any integer from 0 to 1000. |
| `expiresAt` | number or string | When Liova should end it on its own: seconds since 1970, or an ISO-8601 date like `2026-10-17T12:00:00Z`. |

The notch shows the **highest-priority** live activity. Among equal priorities, the most recently started one wins. When it ends, the next one comes back. An activity belongs to its source: a `start` can't take over an ID that another source owns.

Give long-running activities an expiry (`--ttl` in the CLI) so a crashed script doesn't leave one behind forever.

## The `liova` command

The `liova` command-line tool ships inside Liova. It talks to the socket for you.

```
liova <command> [options]

ping                 Check that Liova is running
activity start       Show an activity (or replace one with the same ID)
activity update      Change fields of a live activity
activity end         End one activity, or every activity from a source
activity list        List live activities
agents install       Show a coding agent (e.g. claude-code) in the notch
agents uninstall     Remove Liova's hooks from a coding agent
agents status        Check which agents are set up
hook <agent>         Run as an agent hook (used by the installed hooks)
help <command>       Show help for a command
```

Options can go anywhere, as `--name value` or `--name=value`. A value that starts with `--` must use the `=` form (`--title=--weird--`). Every command accepts `--help`.

### Global options

| Option | Meaning |
| --- | --- |
| `--json` | Print Liova's response as JSON on stdout. |
| `--socket PATH` | Socket to use. Default: `$LIOVA_SOCKET`, or `~/Library/Application Support/Liova/liova.sock`. |
| `--timeout DURATION` | How long to wait for Liova. Default `5s`, at most `10m`. |
| `-h`, `--help` | Show help. |
| `--version` | Print the tool and plugin API versions. |

Durations are seconds with an optional unit: `30`, `90s`, `1.5m`, `2h`, `1d`, `500ms`.

### `liova ping`

Checks that Liova is running and prints its plugin API version.

```sh
$ liova ping
Liova is running (plugin API v1).
```

### `liova activity start`

```
liova activity start --title TEXT [--id ID] [options]
```

| Option | Meaning |
| --- | --- |
| `--title TEXT` | Main text. Required. |
| `--id ID` | Unique ID. Defaults to the source name, so each tool gets one activity without thinking about IDs. |
| `--subtitle TEXT` | Secondary text. |
| `--symbol NAME` | SF Symbol name. |
| `--progress VALUE` | `0` to `1`, or a percentage like `40%`. |
| `--tint COLOR` | One of the tints above. |
| `--priority LEVEL` | `low`, `normal`, `high`, `critical`, or an integer from 0 to 1000. |
| `--ttl DURATION` | End automatically after this long. |
| `--source NAME` | Owner name, used by `end --source`. Default `cli`. |

```sh
liova activity start --id build --title "Building" --symbol hammer --progress 0
liova activity start --id deploy --title "Deployed" --tint green --ttl 10s
```

### `liova activity update`

Changes some fields of a live activity and leaves the rest alone. Fails (exit 1, `notFound`) if no activity has that ID.

```
liova activity update --id ID [--title …] [--subtitle …] [--symbol …] [--progress …]
                      [--tint …] [--priority …] [--ttl …] [--clear FIELDS]
```

`--clear` removes optional fields: any of `subtitle`, `symbol`, `progress`, `ttl`, comma-separated. You can't set and clear the same field in one update.

```sh
liova activity update --id build --progress 75% --subtitle "Linking"
liova activity update --id build --clear progress,subtitle
```

### `liova activity end`

```sh
liova activity end --id build      # one activity
liova activity end --source ci     # every activity from a source
```

Ending by source succeeds even if the source has no live activities.

### `liova activity list`

Lists live activities in **display order**: the first row, marked `*`, is the one the notch is showing. Among equal priorities the most recently started comes first.

```sh
$ liova activity list
   ID      SOURCE  PRIORITY  PROGRESS  EXPIRES  TITLE
*  build   ci      high      40%       9m 58s   Building - staging
   music   player  low       -         -        Song
```

Use `--json` for the full data.

### Output and exit codes

Successful `start`, `update` and `end` print nothing, so scripts can call them in tight loops. Errors go to stderr, prefixed with `liova: error:`.

| Exit code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Liova answered with an error (the message includes its code, e.g. `[notFound]`), or didn't answer in time. |
| `2` | Usage error: the command line itself is wrong. Nothing was sent. |
| `3` | Liova isn't running (nothing is listening on the socket). |

```sh
$ liova ping
liova: error: Liova isn't running. Open Liova.app and try again. (…)
$ echo $?
3
```

### Example: CI build progress

```sh
#!/bin/sh
# Show build progress in the notch; harmless if Liova isn't running.
notch() { liova "$@" >/dev/null 2>&1 || true; }

notch activity start --id ci-build --source ci --title "Building" --symbol hammer --progress 0 --ttl 30m

steps="fetch compile test package"
total=4
done_count=0
for step in $steps; do
    notch activity update --id ci-build --subtitle "$step" --progress "$((done_count * 100 / total))%"
    ./build.sh "$step" || {
        notch activity start --id ci-build --source ci --title "Build failed" --subtitle "$step" \
            --symbol xmark.octagon.fill --tint red --priority high --ttl 2m
        exit 1
    }
    done_count=$((done_count + 1))
done

notch activity start --id ci-build --source ci --title "Build passed" --symbol checkmark.circle.fill \
    --tint green --ttl 15s
```

### Agent Island: `liova agents` and `liova hook`

To show a coding agent in the notch, run `liova agents install` with its name:

```sh
liova agents install claude-code     # --dry-run to preview, --settings PATH for another file
liova agents install codex           # ~/.codex/hooks.json; trust the hooks in Codex's /hooks
liova agents install gemini-cli      # ~/.gemini/settings.json
liova agents install cursor          # ~/.cursor/hooks.json
liova agents status                  # every agent; or 'status codex [--settings PATH]'
liova agents uninstall codex
```

| Command | What it does |
| --- | --- |
| `liova agents install AGENT [--settings PATH] [--dry-run]` | Merges Liova's hooks into the agent's settings, keeping everything else and backing the file up first. Idempotent; refuses files that aren't valid JSON. |
| `liova agents uninstall AGENT [--settings PATH] [--dry-run]` | Removes only Liova's hooks. |
| `liova agents status [AGENT [--settings PATH]]` | Installed, not installed, or outdated (with reasons), plus warnings such as the agent's hooks being turned off. Exits 0 only when every listed agent is installed and current. |
| `liova hook AGENT [--timeout DURATION] [--socket PATH]` | Run by the installed hooks: reads the hook event on stdin, sends an [`agentEvent` or `agentPermission`](#agent-island) request, prints the agent's decision format for a permission answer and nothing otherwise, and always exits 0. |
| `liova hook codex PAYLOAD` | The same for Codex's older `notify` setting, which passes its JSON as an argument. |

`AGENT` is `claude-code`, `codex`, `gemini-cli` or `cursor`. Approve and deny work for Claude Code and Codex; Gemini CLI and Cursor show status only, because their hooks can't answer the agent's own permission prompt. See [AGENT-ISLAND.md](AGENT-ISLAND.md) for what is sent, how approval works, each agent's setup, and troubleshooting.

### Example: Claude Code hooks by hand

`liova agents install` is the easy way. If you'd rather show plain activities from your own hooks, [Claude Code hooks](https://docs.claude.com/en/docs/claude-code/hooks) run shell commands on agent events. This shows an activity while Claude is working, raises it when Claude needs you, and clears it when Claude stops. Add it to `~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "liova activity start --source claude-code --title 'Claude is working' --symbol sparkles --tint orange --ttl 1h || true"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "liova activity start --source claude-code --title 'Claude needs you' --symbol hand.raised.fill --tint yellow --priority high --ttl 10m || true"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "liova activity end --source claude-code || true"
          }
        ]
      }
    ]
  }
}
```

Without `--id`, the activity's ID is the source name (`claude-code`), so each `start` replaces the previous one instead of piling up. The `|| true` keeps the hook from failing when Liova isn't running.

## The socket

Liova listens on a Unix domain socket:

```
~/Library/Application Support/Liova/liova.sock
```

Set the `LIOVA_SOCKET` environment variable to use a different path, for both Liova and clients (a leading `~` is expanded). Socket paths are limited to 103 bytes by macOS.

### Wire format

The protocol is **newline-delimited JSON**:

- Each request is one line: a UTF-8 JSON object followed by `\n`. `\r\n` works too.
- Liova answers each request with exactly one response line, in order.
- A connection can carry any number of requests. Blank lines are ignored.
- A final request without a trailing newline is still answered if you half-close the connection (shut down writing).
- Every request has `"v"` (the protocol version, currently `1`) and `"op"` (the operation).
- Key order doesn't matter. Unknown keys are ignored.

#### Requests

**ping**: check that Liova is running.

```json
{"v":1,"op":"ping"}
```

**start**: show an activity, or replace a live one with the same ID.

```json
{"v":1,"op":"start","activity":{"id":"build","source":"ci","title":"Building","subtitle":"staging","symbol":"hammer.fill","progress":0.4,"tint":"blue","priority":"high","expiresAt":1800000000}}
```

Only `id` and `title` are required; `source` defaults to `unknown`, so set it.

**update**: change some fields of a live activity.

```json
{"v":1,"op":"update","patch":{"id":"build","progress":0.8,"subtitle":"Linking"}}
```

To remove an optional field, list it in `clear` or set it to `null`. Clearable fields are `subtitle`, `symbol`, `progress` and `expiresAt`:

```json
{"v":1,"op":"update","patch":{"id":"build","clear":["progress","subtitle"]}}
{"v":1,"op":"update","patch":{"id":"build","progress":null}}
```

`title`, `tint` and `priority` can be changed but not cleared. `source` can't be changed.

**end**: end one activity.

```json
{"v":1,"op":"end","id":"build"}
```

**endAll**: end every activity from a source.

```json
{"v":1,"op":"endAll","source":"ci"}
```

**list**: get the live activities.

```json
{"v":1,"op":"list"}
```

#### Agent Island

Two requests carry coding-agent activity. Agent-specific hook formats are translated on the client side (`liova hook <agent>` does this), so these are the only agent requests Liova knows. `liova agents install` sets everything up for supported agents; see [AGENT-ISLAND.md](AGENT-ISLAND.md).

**agentEvent**: report what an agent is doing.

```json
{"v":1,"op":"agentEvent","event":{"agent":"claude-code","sessionID":"abc123","project":"MyApp","kind":"toolStarted","detail":"Running `npm test`"}}
```

| Field | Type | Notes |
| --- | --- | --- |
| `agent` | string, required | 1 to 64 characters of `A-Z a-z 0-9 . _ -`, e.g. `claude-code`. |
| `sessionID` | string, required | The agent's session, 1 to 256 characters. Groups events into one session. |
| `project` | string | Up to 200 characters, usually the working directory's folder name. |
| `kind` | string, required | `sessionStarted`, `working`, `toolStarted`, `toolFinished`, `waitingForUser`, `finished` or `sessionEnded`. |
| `detail` | string | Up to 300 characters describing the current step, e.g. `Editing App.swift`. |

The response is `{"ok":true,"v":1}`.

**agentPermission**: ask the user to allow or deny an agent action.

```json
{"v":1,"op":"agentPermission","permission":{"agent":"claude-code","sessionID":"abc123","project":"MyApp","tool":"Bash","summary":"rm -rf node_modules","timeout":300}}
```

| Field | Type | Notes |
| --- | --- | --- |
| `agent`, `sessionID`, `project` | | As for `agentEvent`. |
| `tool` | string, required | The tool or capability, 1 to 64 characters, e.g. `Bash`, `Edit`, `WebFetch`. |
| `summary` | string, required | What exactly it wants to do (the command, file path or URL), up to 2000 characters. Shown verbatim. |
| `timeout` | number, required | Seconds Liova may wait for the user, 1 to 3600. `liova hook` sends 300. |

The response arrives when the user answers or the timeout passes, so the request may stay open for minutes (the idle timeout doesn't apply while a request is in flight). Wait a little longer than `timeout` on the client side. The response carries a `decision`:

```json
{"decision":"allow","ok":true,"v":1}
```

`decision` is `allow`, `deny`, or `ask` (no decision from Liova: the timeout passed, or the user chose to answer in the agent's own prompt). Treat a missing decision, an error response or a dropped connection like `ask`: fall back to the agent's normal prompt.

#### Responses

Every response has `ok` and `v` (the server's protocol version). Liova writes keys in sorted order, with dates as seconds since 1970 and priorities as integers.

Success:

```json
{"ok":true,"v":1}
```

Success for `list`, with activities in **display order** (the first is the one the notch is showing; among equal priorities, the most recently started comes first):

```json
{"activities":[{"expiresAt":1800000000,"id":"build","priority":300,"progress":0.4,"source":"ci","subtitle":"staging","symbol":"hammer.fill","tint":"blue","title":"Building"}],"ok":true,"v":1}
```

Failure:

```json
{"error":{"code":"notFound","message":"No live activity with ID 'build'."},"ok":false,"v":1}
```

#### Error codes

| Code | Meaning | What to do |
| --- | --- | --- |
| `badRequest` | Not valid JSON, unknown `op`, missing or invalid field. The message names the field. | Fix the request. |
| `unsupportedVersion` | `v` is not a version this Liova speaks. | Check `v` in any response, or update Liova. |
| `notFound` | No live activity with that ID. | Use `start` instead of `update`. |
| `forbidden` | A reserved `system.` source, an activity owned by another source, or a connection from another user. | Use your own source name. |
| `tooLarge` | The request line is over 64 KiB. Liova closes the connection after sending this. | Send smaller requests. |
| `rateLimited` | Too many requests on this connection, or too many live activities from your source. | Slow down and retry. |
| `busy` | Too many open connections. Liova closes the connection after sending this. | Retry shortly. |
| `unavailable` | Liova can't serve the request right now, e.g. it is still launching. | Retry shortly. |
| `internal` | A bug in Liova. | Please [report it](https://github.com/Krishnarajan7/Liova/issues). |

New codes may be added without a version bump, so treat unknown codes as generic failures.

### Talking to the socket

With `nc` (interactive; type requests and press Return):

```sh
nc -U ~/Library/Application\ Support/Liova/liova.sock
{"v":1,"op":"ping"}
{"ok":true,"v":1}
```

With `socat`:

```sh
echo '{"v":1,"op":"list"}' | socat - UNIX-CONNECT:"$HOME/Library/Application Support/Liova/liova.sock"
```

From bash, a small helper that sends one request and prints the response:

```bash
LIOVA_SOCK="${LIOVA_SOCKET:-$HOME/Library/Application Support/Liova/liova.sock}"

liova_send() {
    printf '%s\n' "$1" | nc -U "$LIOVA_SOCK"
}

liova_send '{"v":1,"op":"start","activity":{"id":"backup","source":"backup","title":"Backing up","progress":0}}'
liova_send '{"v":1,"op":"update","patch":{"id":"backup","progress":0.5}}'
liova_send '{"v":1,"op":"end","id":"backup"}'
```

(The `liova` command is easier and checks your input before sending; use raw JSON when the CLI isn't available.)

From Python, with only the standard library:

```python
import json
import os
import socket

SOCKET_PATH = os.environ.get(
    "LIOVA_SOCKET",
    os.path.expanduser("~/Library/Application Support/Liova/liova.sock"),
)


class Liova:
    """One connection to Liova; send any number of requests over it."""

    def __init__(self, path=SOCKET_PATH, timeout=5.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)  # FileNotFoundError / ConnectionRefusedError: not running
        self.reader = self.sock.makefile("r", encoding="utf-8")

    def send(self, op, **fields):
        request = {"v": 1, "op": op, **fields}
        self.sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        response = json.loads(self.reader.readline())
        if not response["ok"]:
            raise RuntimeError(f'{response["error"]["code"]}: {response["error"]["message"]}')
        return response

    def close(self):
        self.reader.close()
        self.sock.close()


liova = Liova()
liova.send("start", activity={"id": "train", "source": "ml", "title": "Training", "progress": 0})
for epoch in range(1, 11):
    # ... train one epoch ...
    liova.send("update", patch={"id": "train", "progress": epoch / 10, "subtitle": f"Epoch {epoch}/10"})
liova.send("end", id="train")
liova.close()
```

## `liova://` URLs

Liova handles `liova://` links, so a document, a Shortcut or another app can show an activity:

```
liova://activity/start?id=build&title=Deploying&progress=0.4&symbol=hammer&tint=blue&ttl=600
liova://activity/update?id=build&progress=0.8
liova://activity/update?id=build&clear=progress,subtitle
liova://activity/end?id=build
```

| Action | Parameters |
| --- | --- |
| `start` | `id` and `title` (required); `subtitle`, `symbol`, `progress`, `tint`, `priority`, `ttl` |
| `update` | `id` (required); the same optional fields, plus `clear` (comma-separated: `subtitle`, `symbol`, `progress`) |
| `end` | `id` (required) |

Values are percent-encoded as usual (`Deploying%20app`; a `+` is a literal plus, not a space). Each parameter may appear only once, and unknown parameters are rejected.

URLs are **low trust**: any web page, document or app can open one without you noticing. So Liova limits them:

- The source is always `url`. A `source` parameter is rejected.
- URL commands can only update or end activities that URLs created.
- Priority is capped at `normal`. Higher values (`high`, `critical`, or an integer above 200) are lowered to `normal`.
- Every URL activity expires. `ttl` defaults to 10 minutes and is capped at 1 hour; larger values are lowered to 3600 seconds. The expiry can't be cleared.
- URLs longer than 4096 bytes are rejected, and every field goes through the same validation as the socket.

Use the CLI or the socket when you need more.

## Security model

The socket is only for programs running as you.

- **Private directory.** The socket's directory is mode `0700` and must be a real directory (not a symlink) owned by you. If it is more open, Liova tightens it; if it is owned by someone else or is a symlink, Liova refuses to start the socket.
- **Owner-only socket.** The socket file is mode `0600`.
- **Peer check.** For every connection, Liova asks the kernel for the peer's user ID (`getpeereid`) and rejects anyone who isn't you with `forbidden`.
- **Size limit.** A request line can be at most 64 KiB; larger lines get `tooLarge` and the connection is closed.
- **Rate limit.** Each connection may send a burst of 100 requests, then 50 per second. At most 32 connections are open at once, and a connection idle for 30 seconds is closed.
- **Validation.** Every request is decoded and validated against the rules above before Liova acts on it. Malformed input gets an error response; it never crashes Liova or stops the server.
- **Reserved sources.** Activities from `system` and `system.*` sources belong to Liova's built-in features (battery, volume and so on). Plugins can't create, change or end them.
- **Ownership.** You can't take over an ID that another source owns.
- **Stale sockets.** If Liova crashed and left a socket file behind, the next launch checks that nobody is listening and replaces it. It never removes a file that isn't a socket, and it never steals a socket another running Liova is using.
- **No idle cost.** The server is event-driven. With no clients connected it does no work at all.

To report a security problem, see [SECURITY.md](../SECURITY.md).

## Versioning

The protocol version is `v`, currently `1`. It is the same number as the plugin API version that `liova --version` and `liova ping` print.

- **Additive changes don't bump the version.** New optional fields, new `op`s, new error codes and new response fields can appear in version 1. Clients must ignore response fields they don't know and treat unknown error codes as generic failures.
- **Breaking changes bump the version.** Removing or renaming a field or `op`, or changing what an existing field means, needs a new version.
- **Old versions keep working.** Liova accepts a range of versions. A request with a version outside that range gets `unsupportedVersion`, with a message naming the supported range, and every response's `v` tells you what the server speaks.
- **Version first.** Liova checks `v` before anything else, so a newer client always learns that the version is the problem rather than getting a vague `badRequest`.

// Help text for `liova hook` and `liova agents`.

extension CLIHelp {
    static let agents = """
    USAGE
      liova agents <install|uninstall|status> [agent] [options]

    Agent Island shows what your coding agent is doing in the notch, and lets you
    approve or deny its permission requests from there (Claude Code and Codex).

    SUBCOMMANDS
      install AGENT     Add Liova's hooks to the agent's settings
      uninstall AGENT   Remove Liova's hooks; everything else is kept
      status [AGENT]    Show whether the hooks are installed and current

    AGENTS
      claude-code       Claude Code (~/.claude/settings.json), with approvals
      codex             Codex CLI (~/.codex/hooks.json), with approvals
      gemini-cli        Gemini CLI (~/.gemini/settings.json), status only
      cursor            Cursor (~/.cursor/hooks.json), status only

    Run 'liova agents <subcommand> --help' for its options.
    Docs: https://github.com/Krishnarajan7/Liova/blob/main/docs/AGENT-ISLAND.md
    """

    static let agentsInstall = """
    USAGE
      liova agents install AGENT [--settings PATH] [--dry-run]

    Adds Liova's hooks to a coding agent's user settings, so the notch shows what the
    agent is doing and, for Claude Code and Codex, lets you approve or deny its
    permission requests there. Run it again after moving Liova; it replaces its own
    hooks and never duplicates them.

    Your other settings and hooks are kept. The previous file is backed up next to it
    (NAME.liova-backup-YYYYMMDD-HHMMSS) before anything is written, and a file that
    isn't valid JSON is never overwritten.

    AGENTS AND THE FILES THEY USE
      claude-code       ~/.claude/settings.json
      codex             ~/.codex/hooks.json (trust the hooks in Codex's /hooks afterwards)
      gemini-cli        ~/.gemini/settings.json
      cursor            ~/.cursor/hooks.json

    OPTIONS
      --settings PATH   File to edit instead of the agent's default
      --dry-run         Show what would change without writing anything

    EXAMPLES
      liova agents install claude-code
      liova agents install codex --dry-run
      liova agents install claude-code --settings ./.claude/settings.json
    """

    static let agentsUninstall = """
    USAGE
      liova agents uninstall AGENT [--settings PATH] [--dry-run]

    Removes Liova's hooks from the agent's settings. Other hooks and settings are
    kept. The previous file is backed up first. AGENT is claude-code, codex,
    gemini-cli or cursor.

    OPTIONS
      --settings PATH   File to edit instead of the agent's default
      --dry-run         Show what would change without writing anything
    """

    static let agentsStatus = """
    USAGE
      liova agents status [AGENT [--settings PATH]]

    Shows whether Liova's hooks are installed, and whether they point at this copy
    of liova. Without an agent, lists claude-code, codex, gemini-cli and cursor.
    Exits with 0 when they are all installed and current, 1 otherwise.

    OPTIONS
      --settings PATH   File to check instead of the agent's default (needs AGENT)
    """

    static let hook = """
    USAGE
      liova hook AGENT [--timeout DURATION] [--socket PATH]
      liova hook codex [PAYLOAD]

    Used by the hooks that 'liova agents install' adds; you don't run it yourself.
    AGENT is claude-code, codex, gemini-cli or cursor. Reads the agent's hook event on
    stdin and passes it to Liova. For a permission request (Claude Code and Codex) it
    waits for your answer in the notch and prints it for the agent; if Liova isn't
    running or you don't answer in time, the agent asks as usual. It always exits 0
    and prints nothing else.

    Codex's older 'notify' setting passes its JSON as an argument (PAYLOAD) instead.

    OPTIONS
      --timeout DURATION  How long to wait for an answer to a permission request
                          (default: 5m, at most 1h; keep it below the hook's own
                          timeout in the agent's settings, 310s by default)
      --socket PATH       Socket to use (default: $LIOVA_SOCKET, or Liova's default)

    ENVIRONMENT
      LIOVA_HOOK_DEBUG=1  Log what the hook does to stderr
    """
}

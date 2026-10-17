// Help text for `liova hook` and `liova agents`.

extension CLIHelp {
    static let agents = """
    USAGE
      liova agents <install|uninstall|status> [agent] [options]

    Agent Island shows what your coding agent is doing in the notch, and lets you
    approve or deny its permission requests from there.

    SUBCOMMANDS
      install AGENT     Add Liova's hooks to the agent's settings
      uninstall AGENT   Remove Liova's hooks; everything else is kept
      status [AGENT]    Show whether the hooks are installed and current

    AGENTS
      claude-code       Claude Code (~/.claude/settings.json)

    Run 'liova agents <subcommand> --help' for its options.
    Docs: https://github.com/Krishnarajan7/Liova/blob/main/docs/AGENT-ISLAND.md
    """

    static let agentsInstall = """
    USAGE
      liova agents install claude-code [--settings PATH] [--dry-run]

    Adds Liova's hooks to Claude Code's user settings, so the notch shows what Claude
    is doing and you can approve or deny its permission requests there. Run it again
    after moving Liova; it replaces its own hooks and never duplicates them.

    Your other settings and hooks are kept. The previous file is backed up next to it
    (settings.json.liova-backup-YYYYMMDD-HHMMSS) before anything is written, and a file
    that isn't valid JSON is never overwritten.

    OPTIONS
      --settings PATH   Settings file to edit (default: ~/.claude/settings.json)
      --dry-run         Show what would change without writing anything

    EXAMPLES
      liova agents install claude-code
      liova agents install claude-code --dry-run
      liova agents install claude-code --settings ./.claude/settings.json
    """

    static let agentsUninstall = """
    USAGE
      liova agents uninstall claude-code [--settings PATH] [--dry-run]

    Removes Liova's hooks from Claude Code's settings. Other hooks and settings are
    kept. The previous file is backed up first.

    OPTIONS
      --settings PATH   Settings file to edit (default: ~/.claude/settings.json)
      --dry-run         Show what would change without writing anything
    """

    static let agentsStatus = """
    USAGE
      liova agents status [claude-code] [--settings PATH]

    Shows whether Liova's hooks are installed, and whether they point at this copy
    of liova. Exits with 0 when they are installed and current, 1 otherwise.

    OPTIONS
      --settings PATH   Settings file to check (default: ~/.claude/settings.json)
    """

    static let hook = """
    USAGE
      liova hook claude-code [--timeout DURATION] [--socket PATH]

    Used by the hooks that 'liova agents install' adds; you don't run it yourself.
    Reads the agent's hook event on stdin and passes it to Liova. For a permission
    request it waits for your answer in the notch and prints it for the agent; if
    Liova isn't running or you don't answer in time, the agent asks in the terminal
    as usual. It always exits 0 and prints nothing else.

    OPTIONS
      --timeout DURATION  How long to wait for an answer to a permission request
                          (default: 5m, at most 1h; keep it below the hook's own
                          timeout in the agent's settings, 310s by default)
      --socket PATH       Socket to use (default: $LIOVA_SOCKET, or Liova's default)

    ENVIRONMENT
      LIOVA_HOOK_DEBUG=1  Log what the hook does to stderr
    """
}

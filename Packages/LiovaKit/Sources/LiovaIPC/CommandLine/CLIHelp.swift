// Help text for the `liova` command line.

enum CLIHelp {
    static let main = """
    liova: push live activities to Liova's notch.

    USAGE
      liova <command> [options]

    COMMANDS
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

    GLOBAL OPTIONS
      --json               Print Liova's response as JSON
      --socket PATH        Socket to use (default: $LIOVA_SOCKET, or
                           ~/Library/Application Support/Liova/liova.sock)
      --timeout DURATION   How long to wait for Liova (default: 5s)
      -h, --help           Show help
      --version            Show the version

    EXIT CODES
      0  success
      1  Liova reported an error, or didn't answer
      2  usage error (bad command line)
      3  Liova isn't running

    EXAMPLES
      liova activity start --id build --title "Deploying" --symbol hammer --progress 0.4
      liova activity update --id build --progress 80%
      liova activity end --id build

    Docs: https://github.com/Krishnarajan7/Liova/blob/main/docs/PLUGIN-API.md
    """

    static let activity = """
    USAGE
      liova activity <start|update|end|list> [options]

    SUBCOMMANDS
      start    Show an activity (or replace one with the same ID)
      update   Change fields of a live activity
      end      End one activity, or every activity from a source
      list     List live activities

    Run 'liova activity <subcommand> --help' for its options.
    """

    static let ping = """
    USAGE
      liova ping [--json] [--socket PATH] [--timeout DURATION]

    Checks that Liova is running and prints its plugin API version.
    Exits with 3 if Liova isn't running, so scripts can test for it:

      liova ping >/dev/null 2>&1 && liova activity start --id hello --title "Hi"
    """

    static let start = """
    USAGE
      liova activity start --title TEXT [--id ID] [options]

    Shows an activity in the notch. If an activity with the same ID is live, it is replaced.

    OPTIONS
      --title TEXT         Main text, up to 200 characters                     (required)
      --id ID              Unique ID: 1-128 characters of A-Z a-z 0-9 . _ -
                           (default: the source, so each tool has one activity)
      --subtitle TEXT      Secondary text, up to 200 characters
      --symbol NAME        SF Symbol name, e.g. hammer, checkmark.circle.fill
      --progress VALUE     Progress from 0 to 1, or a percentage like 40%
      --tint COLOR         accent, green, yellow, orange, red, blue, purple, pink, gray
      --priority LEVEL     low, normal (default), high, critical, or an integer 0-1000
      --ttl DURATION       End automatically after this long: 30, 90s, 10m, 2h
      --source NAME        Owner name, used by 'end --source' (default: cli).
                           Names starting with 'system.' are reserved.

    EXAMPLES
      liova activity start --id build --title "Building" --symbol hammer --progress 0
      liova activity start --id deploy --title "Deployed" --tint green --ttl 10s
    """

    static let update = """
    USAGE
      liova activity update --id ID [options]

    Changes some fields of a live activity; everything else stays as it is.
    Fails (exit 1) if no activity has that ID.

    OPTIONS
      --id ID              The activity to change                              (required)
      --title TEXT         New title
      --subtitle TEXT      New subtitle
      --symbol NAME        New SF Symbol name
      --progress VALUE     New progress, 0 to 1 or a percentage like 80%
      --tint COLOR         New tint
      --priority LEVEL     New priority
      --ttl DURATION       End this long from now
      --clear FIELDS       Remove fields: subtitle, symbol, progress, ttl (comma-separated)

    EXAMPLES
      liova activity update --id build --progress 0.75 --subtitle "Linking"
      liova activity update --id build --clear progress,subtitle
    """

    static let end = """
    USAGE
      liova activity end --id ID
      liova activity end --source NAME

    Ends one activity, or every activity from a source.

    OPTIONS
      --id ID              The activity to end
      --source NAME        End all activities with this source

    EXAMPLES
      liova activity end --id build
      liova activity end --source ci
    """

    static let list = """
    USAGE
      liova activity list [--json]

    Lists live activities in display order. The first one, marked '*', is the one the
    notch is showing. Use --json for the full data.
    """

    static func text(for command: CLIParser.Command) -> String {
        switch command {
        case .ping: ping
        case .start: start
        case .update: update
        case .end: end
        case .list: list
        }
    }
}

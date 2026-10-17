import Foundation
import LiovaPluginKit

/// What the `liova` command line asked for. Produced by ``CLIParser/parse(_:now:)``, a pure
/// function, so all argument handling is unit-tested without touching a socket.
public enum CLIInvocation: Equatable, Sendable {
    /// Print this text to stdout and exit 0.
    case showHelp(String)
    /// Print the version and exit 0.
    case showVersion
    /// Send a command to Liova.
    case send(IPCCommand, CLIOptions)
    /// Run as an agent hook (`liova hook claude-code`): read stdin, tell Liova, print the
    /// agent's answer. Always exits 0.
    case hook(AgentHookOptions)
    /// Install, remove or check agent hooks (`liova agents ...`).
    case agents(AgentsRequest)
}

/// Options shared by every command that talks to Liova.
public struct CLIOptions: Equatable, Sendable {
    /// Print the raw response as JSON instead of human-readable text.
    public var json: Bool
    /// Overrides the socket path (otherwise `$LIOVA_SOCKET` or the default).
    public var socketPath: String?
    /// Seconds to wait for Liova to answer.
    public var timeout: TimeInterval

    public init(json: Bool = false, socketPath: String? = nil, timeout: TimeInterval = 5) {
        self.json = json
        self.socketPath = socketPath
        self.timeout = timeout
    }
}

/// A command line that can't be run. The CLI prints ``message`` to stderr and exits with 2.
public struct CLIUsageError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// The command whose help explains the mistake, e.g. `liova activity start`.
    public var command: String
    /// Full usage text to print as well (only for a missing command).
    public var usage: String?

    public init(_ message: String, command: String = "liova", usage: String? = nil) {
        self.message = message
        self.command = command
        self.usage = usage
    }

    public var description: String {
        message
    }
}

/// Hand-rolled, dependency-free parser for the `liova` command line.
///
/// Options may appear anywhere, as `--name value` or `--name=value`. A value that itself starts
/// with `--` must use the `=` form. `--` ends option parsing.
public enum CLIParser {
    /// Version printed by `liova --version`. Keep in step with `MARKETING_VERSION` in project.yml.
    public static let toolVersion = "0.1.0"
    /// Source used by `activity start` when `--source` isn't given.
    public static let defaultSource = "cli"

    static let flagOptions: Set<String> = ["json", "help", "version", "dry-run"]
    static let valueOptions: Set<String> = [
        "socket", "timeout", "id", "title", "subtitle", "symbol", "progress", "tint", "priority", "ttl", "source",
        "clear", "settings",
    ]
    static let globalOptions: Set<String> = ["json", "help", "version", "socket", "timeout"]

    enum Command: String, CaseIterable {
        case ping
        case start = "activity start"
        case update = "activity update"
        case end = "activity end"
        case list = "activity list"

        var options: Set<String> {
            switch self {
            case .ping, .list: []
            case .start: ["id", "title", "subtitle", "symbol", "progress", "tint", "priority", "ttl", "source"]
            case .update: ["id", "title", "subtitle", "symbol", "progress", "tint", "priority", "ttl", "clear"]
            case .end: ["id", "source"]
            }
        }

        var displayName: String {
            "liova \(rawValue)"
        }
    }

    /// Parses arguments (without the program name).
    public static func parse(_ arguments: [String], now: Date = Date()) throws(CLIUsageError) -> CLIInvocation {
        let (words, options) = try tokenize(arguments)
        if options["version"] != nil {
            return .showVersion
        }
        let wantsHelp = options["help"] != nil

        var path = words
        if path.first == "help" {
            path.removeFirst()
            if path.isEmpty {
                return .showHelp(CLIHelp.main)
            }
            return try .showHelp(help(for: path))
        }
        guard let first = path.first else {
            if wantsHelp {
                return .showHelp(CLIHelp.main)
            }
            throw CLIUsageError("Missing command.", usage: CLIHelp.main)
        }
        if AgentCommandParser.commandWords.contains(first) {
            return try AgentCommandParser.parse(path, options: options, wantsHelp: wantsHelp)
        }
        if first == "activity", path.count == 1 {
            if wantsHelp {
                return .showHelp(CLIHelp.activity)
            }
            throw CLIUsageError(
                "Missing subcommand. Use start, update, end or list.",
                command: "liova activity",
                usage: CLIHelp.activity
            )
        }
        let command = try resolve(path)
        if wantsHelp {
            return .showHelp(CLIHelp.text(for: command))
        }

        for name in options.keys where !globalOptions.contains(name) && !command.options.contains(name) {
            throw CLIUsageError("'\(command.displayName)' has no option --\(name).", command: command.displayName)
        }
        let cliOptions = try globalCLIOptions(options, command: command)
        let built = try CommandBuilder(command: command, values: options, now: now).build()
        return .send(built, cliOptions)
    }

    /// Whether `arguments` run `liova hook`, whose usage errors must still exit 0.
    public static func isHookInvocation(_ arguments: [String]) -> Bool {
        AgentCommandParser.isHookInvocation(arguments)
    }

    // MARK: Tokenizing

    static func tokenize(_ arguments: [String]) throws(CLIUsageError) -> ([String], [String: String]) {
        var words: [String] = []
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            if token == "--" {
                words.append(contentsOf: arguments[index...])
                break
            }
            guard token.hasPrefix("-"), token != "-" else {
                words.append(token)
                continue
            }
            let (name, value) = try option(token, arguments: arguments, index: &index)
            guard options[name] == nil || flagOptions.contains(name) else {
                throw CLIUsageError("--\(name) was given more than once.")
            }
            options[name] = value
        }
        return (words, options)
    }

    /// Parses one option token, consuming the next argument as its value when needed.
    private static func option(
        _ token: String,
        arguments: [String],
        index: inout Int
    ) throws(CLIUsageError) -> (name: String, value: String) {
        if token == "-h" {
            return ("help", "")
        }
        guard token.hasPrefix("--") else {
            throw CLIUsageError("Unknown option '\(token)'. Options start with '--', e.g. --id.")
        }
        let body = token.dropFirst(2)
        let equals = body.firstIndex(of: "=")
        let name = String(body[..<(equals ?? body.endIndex)])
        let inlineValue = equals.map { String(body[body.index(after: $0)...]) }
        if flagOptions.contains(name) {
            guard inlineValue == nil else { throw CLIUsageError("--\(name) doesn't take a value.") }
            return (name, "")
        }
        guard valueOptions.contains(name) else {
            throw CLIUsageError("Unknown option '--\(name)'.\(suggestion(for: name))")
        }
        if let inlineValue {
            return (name, inlineValue)
        }
        guard index < arguments.count, !isKnownOption(arguments[index]) else {
            throw CLIUsageError("--\(name) needs a value.")
        }
        defer { index += 1 }
        return (name, arguments[index])
    }

    private static func isKnownOption(_ token: String) -> Bool {
        guard token.hasPrefix("--") else { return token == "-h" }
        let name = token.dropFirst(2).split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        return token == "--" || flagOptions.contains(name) || valueOptions.contains(name)
    }

    private static func resolve(_ path: [String]) throws(CLIUsageError) -> Command {
        for length in [2, 1] where path.count >= length {
            if let command = Command(rawValue: path.prefix(length).joined(separator: " ")) {
                if path.count > length {
                    throw CLIUsageError(
                        "Unexpected argument '\(path[length])'. Values are passed with options, e.g. --title \"...\".",
                        command: command.displayName
                    )
                }
                return command
            }
        }
        if path.first == "activity" {
            let hint = suggestion(for: path[1], among: ["start", "update", "end", "list"])
            throw CLIUsageError(
                "Unknown subcommand 'activity \(path[1])'.\(hint) Use start, update, end or list.",
                command: "liova activity"
            )
        }
        let hint = suggestion(for: path[0], among: ["ping", "activity", "hook", "agents", "help"])
        throw CLIUsageError("Unknown command '\(path[0])'.\(hint)")
    }

    private static func help(for path: [String]) throws(CLIUsageError) -> String {
        if path == ["activity"] {
            return CLIHelp.activity
        }
        if let first = path.first, AgentCommandParser.commandWords.contains(first) {
            return try AgentCommandParser.helpText(for: path)
        }
        return try CLIHelp.text(for: resolve(path))
    }

    private static func globalCLIOptions(
        _ options: [String: String],
        command: Command
    ) throws(CLIUsageError) -> CLIOptions {
        var result = CLIOptions(json: options["json"] != nil, socketPath: options["socket"])
        if let socket = result.socketPath, socket.isEmpty {
            throw CLIUsageError("--socket needs a path.", command: command.displayName)
        }
        if let text = options["timeout"] {
            guard let seconds = CLIValues.duration(text), seconds <= 600 else {
                throw CLIUsageError(
                    "--timeout must be a duration up to 10m, like 5 or 2.5s; got '\(text)'.",
                    command: command.displayName
                )
            }
            result.timeout = seconds
        }
        return result
    }

    // MARK: Suggestions

    static func suggestion(for name: String, among candidates: Set<String>? = nil) -> String {
        let pool = candidates ?? flagOptions.union(valueOptions)
        let prefix = candidates == nil ? "--" : ""
        var best: (name: String, distance: Int)?
        for candidate in pool.sorted() {
            let distance = editDistance(name, candidate)
            if distance <= 2, distance < best?.distance ?? Int.max {
                best = (candidate, distance)
            }
        }
        return best.map { " Did you mean '\(prefix)\($0.name)'?" } ?? ""
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs), rhs = Array(rhs)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0 ... rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: rhs.count)
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1, substitution)
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

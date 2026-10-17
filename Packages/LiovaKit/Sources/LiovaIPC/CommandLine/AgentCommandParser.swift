import Foundation
import LiovaPluginKit

/// Options for `liova hook <agent>`.
public struct AgentHookOptions: Equatable, Sendable {
    public var agent: AgentKind
    /// Seconds Liova may take to answer a permission request.
    public var permissionTimeout: TimeInterval
    /// Overrides the socket path (otherwise `$LIOVA_SOCKET` or the default).
    public var socketPath: String?

    public init(agent: AgentKind, permissionTimeout: TimeInterval = 300, socketPath: String? = nil) {
        self.agent = agent
        self.permissionTimeout = permissionTimeout
        self.socketPath = socketPath
    }
}

/// What `liova agents ...` asked for.
public enum AgentsRequest: Equatable, Sendable {
    case install(AgentKind, settingsPath: String?, dryRun: Bool)
    case uninstall(AgentKind, settingsPath: String?, dryRun: Bool)
    /// Status of one agent, or of every supported agent.
    case status(AgentKind?, settingsPath: String?)
}

/// Parses `liova hook ...` and `liova agents ...`. Pure, like ``CLIParser``.
enum AgentCommandParser {
    static let commandWords: Set<String> = ["hook", "agents"]

    private enum Command: String {
        case hook
        case install = "agents install"
        case uninstall = "agents uninstall"
        case status = "agents status"

        var displayName: String {
            "liova \(rawValue)"
        }

        var options: Set<String> {
            switch self {
            case .hook: ["timeout", "socket"]
            case .install, .uninstall: ["settings", "dry-run"]
            case .status: ["settings"]
            }
        }

        var help: String {
            switch self {
            case .hook: CLIHelp.hook
            case .install: CLIHelp.agentsInstall
            case .uninstall: CLIHelp.agentsUninstall
            case .status: CLIHelp.agentsStatus
            }
        }
    }

    /// Whether `arguments` (without the program name) run `liova hook`. Usage errors there must
    /// still exit 0, because agents treat some exit codes as "block this action".
    static func isHookInvocation(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            if token == "--" {
                return index < arguments.count && arguments[index] == "hook"
            }
            if token.hasPrefix("-"), token != "-" {
                let name = token.drop { $0 == "-" }
                if !name.contains("="), CLIParser.valueOptions.contains(String(name)) {
                    index += 1 // Skip the option's value.
                }
                continue
            }
            return token == "hook"
        }
        return false
    }

    static func parse(
        _ path: [String],
        options: [String: String],
        wantsHelp: Bool
    ) throws(CLIUsageError) -> CLIInvocation {
        let (command, agentWord) = try resolve(path)
        if wantsHelp {
            return .showHelp(command?.help ?? CLIHelp.agents)
        }
        guard let command else {
            throw CLIUsageError(
                "Missing subcommand. Use install, uninstall or status.",
                command: "liova agents",
                usage: CLIHelp.agents
            )
        }
        for name in options.keys where name != "help" && !command.options.contains(name) {
            throw CLIUsageError("'\(command.displayName)' has no option --\(name).", command: command.displayName)
        }
        var agent: AgentKind?
        if let agentWord {
            agent = try agentKind(agentWord, command: command)
        }
        if command == .hook {
            guard let agent else { throw missingAgent(command) }
            return try .hook(AgentHookOptions(
                agent: agent,
                permissionTimeout: permissionTimeout(options),
                socketPath: socketPath(options, command: command)
            ))
        }
        return try .agents(agentsRequest(command, agent: agent, options: options))
    }

    private static func agentsRequest(
        _ command: Command,
        agent: AgentKind?,
        options: [String: String]
    ) throws(CLIUsageError) -> AgentsRequest {
        let settings = try settingsPath(options, command: command)
        let dryRun = options["dry-run"] != nil
        switch command {
        case .hook:
            throw CLIUsageError("Not an agents command.", command: command.displayName)
        case .install:
            guard let agent else { throw missingAgent(command) }
            return .install(agent, settingsPath: settings, dryRun: dryRun)
        case .uninstall:
            guard let agent else { throw missingAgent(command) }
            return .uninstall(agent, settingsPath: settings, dryRun: dryRun)
        case .status:
            return .status(agent, settingsPath: settings)
        }
    }

    static func helpText(for path: [String]) throws(CLIUsageError) -> String {
        try resolve(path).command?.help ?? CLIHelp.agents
    }

    // MARK: Helpers

    /// The command and the agent word after it. `nil` command means bare `liova agents`.
    private static func resolve(_ path: [String]) throws(CLIUsageError) -> (command: Command?, agent: String?) {
        let command: Command?
        let rest: ArraySlice<String>
        if path[0] == "hook" {
            command = .hook
            rest = path.dropFirst()
        } else if path.count == 1 {
            command = nil
            rest = []
        } else if let found = Command(rawValue: "agents \(path[1])"), found != .hook {
            command = found
            rest = path.dropFirst(2)
        } else {
            let hint = CLIParser.suggestion(for: path[1], among: ["install", "uninstall", "status"])
            throw CLIUsageError(
                "Unknown subcommand 'agents \(path[1])'.\(hint) Use install, uninstall or status.",
                command: "liova agents"
            )
        }
        if rest.count > 1, let command {
            throw CLIUsageError("Unexpected argument '\(rest[rest.startIndex + 1])'.", command: command.displayName)
        }
        return (command, rest.first)
    }

    private static func agentKind(_ word: String, command: Command) throws(CLIUsageError) -> AgentKind {
        if let agent = AgentKind(rawValue: word.lowercased()) {
            return agent
        }
        let names = AgentKind.allCases.map(\.rawValue)
        let hint = CLIParser.suggestion(for: word.lowercased(), among: Set(names))
        throw CLIUsageError(
            "Unknown agent '\(word)'.\(hint) Supported: \(names.joined(separator: ", ")).",
            command: command.displayName
        )
    }

    private static func missingAgent(_ command: Command) -> CLIUsageError {
        let names = AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
        return CLIUsageError("Missing agent name. Supported: \(names).", command: command.displayName)
    }

    private static func permissionTimeout(_ options: [String: String]) throws(CLIUsageError) -> TimeInterval {
        guard let text = options["timeout"] else { return 300 }
        guard let seconds = CLIValues.duration(text), LiovaValidation.agentTimeoutRange.contains(seconds) else {
            throw CLIUsageError(
                "--timeout must be a duration from 1s to 1h, like 120 or 5m; got '\(text)'.",
                command: Command.hook.displayName
            )
        }
        return seconds
    }

    private static func socketPath(_ options: [String: String], command: Command) throws(CLIUsageError) -> String? {
        guard let socket = options["socket"] else { return nil }
        guard !socket.isEmpty else { throw CLIUsageError("--socket needs a path.", command: command.displayName) }
        return socket
    }

    private static func settingsPath(
        _ options: [String: String],
        command: Command
    ) throws(CLIUsageError) -> String? {
        guard let path = options["settings"] else { return nil }
        guard !path.isEmpty else { throw CLIUsageError("--settings needs a path.", command: command.displayName) }
        return path
    }
}

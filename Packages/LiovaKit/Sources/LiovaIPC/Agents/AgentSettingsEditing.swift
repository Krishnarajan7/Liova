import Foundation

/// Pure edits to one agent's hook configuration file, on an ``OrderedJSON`` document.
///
/// Implementations recognise Liova's own entries by their command (`liova hook <agent>`) and
/// leave everything else exactly as it was.
public protocol AgentSettingsEditing: Sendable {
    /// The command to register for a `liova` binary at `executablePath`.
    func command(executablePath: String) -> String

    /// `root` with Liova's hooks for every event, replacing older Liova entries in place.
    func installing(
        _ root: OrderedJSON,
        command: String
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange])

    /// `root` without any Liova entry. Containers that only held Liova's entries go too.
    func uninstalling(
        _ root: OrderedJSON
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange])

    /// Whether Liova's hooks are installed, and whether they match `expectedCommand`.
    func status(_ root: OrderedJSON, expectedCommand: String) -> AgentHookStatus
}

/// One change the installer makes (or would make) to an agent's hook configuration.
public struct AgentHookChange: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case added, updated, unchanged, removed
    }

    /// The hook event, e.g. `PreToolUse`.
    public var event: String
    public var kind: Kind

    public init(event: String, kind: Kind) {
        self.event = event
        self.kind = kind
    }
}

/// Whether Liova's hooks are set up in an agent's settings.
public struct AgentHookStatus: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// No Liova hooks.
        case notInstalled
        /// Every hook is present and points at this `liova`.
        case installed
        /// Some Liova hooks exist but are incomplete or point elsewhere; re-install to fix.
        case outdated
    }

    public var state: State
    /// Why the hooks are outdated, for people.
    public var problems: [String]
    /// The distinct Liova hook commands found.
    public var commands: [String]
    /// Things outside Liova's hooks that stop them working, e.g. the agent's hooks being
    /// turned off. Re-installing doesn't fix these.
    public var warnings: [String]

    public init(state: State, problems: [String] = [], commands: [String] = [], warnings: [String] = []) {
        self.state = state
        self.problems = problems
        self.commands = commands
        self.warnings = warnings
    }
}

/// Why agent settings can't be changed safely.
public struct AgentSettingsShapeError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

/// Recognises Liova's hook commands: the `liova` binary (any path, possibly quoted) followed
/// by `hook <agent>` and optional flags.
enum LiovaHookCommand {
    static func make(executablePath: String, agent: String) -> String {
        "\(ShellWords.quote(executablePath)) hook \(agent)"
    }

    static func matches(_ command: String, agent: String) -> Bool {
        let arguments = " hook \(agent)"
        guard let range = command.range(of: arguments) else { return false }
        let after = command[range.upperBound...]
        guard after.isEmpty || after.first?.isWhitespace == true else { return false }
        let prefix = String(command[..<range.lowerBound])
        guard let (binary, rest) = ShellWords.firstWord(of: prefix),
              rest.allSatisfy(\.isWhitespace)
        else { return false }
        return (binary as NSString).lastPathComponent == "liova"
    }
}

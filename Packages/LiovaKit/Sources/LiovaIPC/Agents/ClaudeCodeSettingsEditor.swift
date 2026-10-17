import Foundation

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

    public init(state: State, problems: [String] = [], commands: [String] = []) {
        self.state = state
        self.problems = problems
        self.commands = commands
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

/// Pure edits to Claude Code's `settings.json` hooks, on an ``OrderedJSON`` document.
///
/// Liova's handlers are recognised by their command: the `liova` binary followed by
/// `hook claude-code`. Everything else (other keys, other tools' hooks, matcher groups we
/// didn't create) is left exactly as it was.
public enum ClaudeCodeSettingsEditor {
    public typealias HookEvent = ClaudeCodeHookAdapter.HookEvent

    /// The arguments after the binary in every Liova hook command.
    public static let hookArguments = "hook claude-code"
    /// Seconds Claude Code gives event hooks. They take milliseconds; this only bounds a hang.
    public static let eventTimeout = 5
    /// Seconds Claude Code gives the permission hook: the 300 s wait plus slack.
    public static let permissionTimeout = 310

    /// Events whose matcher filters by tool name; we register them with `*`.
    static let toolEvents: Set<HookEvent> = [.preToolUse, .postToolUse, .permissionRequest]

    /// The command to register for a `liova` binary at `executablePath`.
    public static func command(executablePath: String) -> String {
        "\(ShellWords.quote(executablePath)) \(hookArguments)"
    }

    public static func timeout(for event: HookEvent) -> Int {
        event == .permissionRequest ? permissionTimeout : eventTimeout
    }

    /// Whether `command` runs a `liova` binary's `hook claude-code`.
    public static func isLiovaCommand(_ command: String) -> Bool {
        guard let range = command.range(of: " \(hookArguments)") else { return false }
        let after = command[range.upperBound...]
        guard after.isEmpty || after.first?.isWhitespace == true else { return false }
        let prefix = String(command[..<range.lowerBound])
        guard let (binary, rest) = ShellWords.firstWord(of: prefix),
              rest.allSatisfy(\.isWhitespace)
        else { return false }
        return (binary as NSString).lastPathComponent == "liova"
    }

    // MARK: Install / uninstall

    /// `root` with Liova's handlers for every event, replacing older Liova handlers in place.
    public static func installing(
        _ root: OrderedJSON,
        command: String
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        guard root.members != nil else { throw AgentSettingsShapeError("The settings file isn't a JSON object.") }
        var hooks = try hooksObject(root)
        var changes: [AgentHookChange] = []

        for event in HookEvent.allCases {
            let handler = makeHandler(command: command, timeout: timeout(for: event))
            var groups: [OrderedJSON] = []
            if let existing = hooks[event.rawValue] {
                guard let elements = existing.elements else {
                    throw AgentSettingsShapeError("\"hooks.\(event.rawValue)\" isn't a list, so it can't be extended.")
                }
                groups = elements
            }
            let (updated, kind) = install(handler, into: groups, event: event)
            hooks.set(event.rawValue, .array(updated))
            changes.append(AgentHookChange(event: event.rawValue, kind: kind))
        }
        // Stray Liova handlers under other events (e.g. from a future version) are removed.
        hooks = removingLiovaHandlers(from: hooks, except: Set(HookEvent.allCases.map(\.rawValue)), changes: &changes)

        var result = root
        result.set("hooks", hooks)
        return (result, changes)
    }

    /// `root` without any Liova handler. Groups and event lists that only held Liova's
    /// handlers are removed, and so is `hooks` if nothing else is left in it.
    public static func uninstalling(
        _ root: OrderedJSON
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        guard root.members != nil else { throw AgentSettingsShapeError("The settings file isn't a JSON object.") }
        guard root["hooks"] != nil else { return (root, []) }
        let hooks = try hooksObject(root)
        var changes: [AgentHookChange] = []
        let cleaned = removingLiovaHandlers(from: hooks, except: [], changes: &changes)
        guard !changes.isEmpty else { return (root, []) }
        var result = root
        result.set("hooks", cleaned.members?.isEmpty == true ? nil : cleaned)
        return (result, changes)
    }

    /// Whether Liova's hooks are installed, and whether they match `expectedCommand`.
    public static func status(_ root: OrderedJSON, expectedCommand: String) -> AgentHookStatus {
        let hooks = root["hooks"]?.members ?? []
        var commands: [String] = []
        var problems: [String] = []
        for member in hooks {
            let ours = liovaHandlers(in: member.value)
            for command in ours.compactMap({ $0.handler["command"]?.stringValue }) where !commands.contains(command) {
                commands.append(command)
            }
            if HookEvent(rawValue: member.key) == nil, !ours.isEmpty {
                problems.append("Unexpected Liova hook under \(member.key).")
            }
        }
        guard !commands.isEmpty else { return AgentHookStatus(state: .notInstalled) }

        var missing: [String] = []
        for event in HookEvent.allCases {
            let ours = root["hooks"]?[event.rawValue].map(liovaHandlers) ?? []
            if ours.isEmpty {
                missing.append(event.rawValue)
            } else if let problem = problem(event, ours: ours, expectedCommand: expectedCommand) {
                problems.append(problem)
            }
        }
        if !missing.isEmpty {
            problems.insert("Missing hooks for \(missing.joined(separator: ", ")).", at: 0)
        }
        for command in commands where command != expectedCommand {
            problems.append("A hook runs '\(command)', not this liova ('\(expectedCommand)').")
        }
        return AgentHookStatus(state: problems.isEmpty ? .installed : .outdated, problems: problems, commands: commands)
    }

    /// What's wrong with an event's Liova handlers, beyond pointing at another binary.
    private static func problem(
        _ event: HookEvent,
        ours: [(handler: OrderedJSON, matchesAll: Bool)],
        expectedCommand: String
    ) -> String? {
        guard ours.count == 1 else { return "\(event.rawValue) has \(ours.count) Liova hooks." }
        guard ours[0].matchesAll else { return "\(event.rawValue) hook only runs for some tools." }
        let handler = ours[0].handler
        if handler["command"]?.stringValue == expectedCommand,
           handler != makeHandler(command: expectedCommand, timeout: timeout(for: event))
        {
            return "\(event.rawValue) hook has different settings (e.g. its timeout)."
        }
        return nil
    }

    // MARK: Helpers

    static func makeHandler(command: String, timeout: Int) -> OrderedJSON {
        .object([
            .init("type", .string("command")),
            .init("command", .string(command)),
            .init("timeout", .number(String(timeout))),
        ])
    }

    private static func hooksObject(_ root: OrderedJSON) throws(AgentSettingsShapeError) -> OrderedJSON {
        guard let hooks = root["hooks"] else { return .object([]) }
        guard hooks.members != nil else {
            throw AgentSettingsShapeError("\"hooks\" in the settings file isn't an object.")
        }
        return hooks
    }

    private static func isLiovaHandler(_ handler: OrderedJSON) -> Bool {
        handler["command"]?.stringValue.map(isLiovaCommand) ?? false
    }

    private static func matchesAll(_ group: OrderedJSON) -> Bool {
        guard let matcher = group["matcher"] else { return true }
        return matcher == .string("") || matcher == .string("*") || matcher == .null
    }

    private static func liovaHandlers(in groups: OrderedJSON) -> [(handler: OrderedJSON, matchesAll: Bool)] {
        (groups.elements ?? []).flatMap { group in
            (group["hooks"]?.elements ?? []).filter(isLiovaHandler).map { ($0, matchesAll(group)) }
        }
    }

    /// Puts `handler` into the first match-all group that holds a Liova handler (keeping its
    /// position), drops every other Liova handler, or appends a new group.
    private static func install(
        _ handler: OrderedJSON,
        into groups: [OrderedJSON],
        event: HookEvent
    ) -> ([OrderedJSON], AgentHookChange.Kind) {
        var placed = false
        var previous: [OrderedJSON] = []
        var result: [OrderedJSON] = []
        for group in groups {
            let rewritten = rewriting(group, replacement: !placed && matchesAll(group) ? handler : nil)
            previous += rewritten.found
            placed = placed || rewritten.placed
            if let updated = rewritten.group {
                result.append(updated)
            }
        }
        if !placed {
            var members: [OrderedJSON.Member] = []
            if toolEvents.contains(event) {
                members.append(.init("matcher", .string("*")))
            }
            members.append(.init("hooks", .array([handler])))
            result.append(.object(members))
        }
        return (result, changeKind(previous: previous, handler: handler, changedGroups: result != groups))
    }

    /// `group` with its Liova handlers removed, or the first one swapped for `replacement`.
    /// The group is `nil` when no handlers are left in it.
    private static func rewriting(
        _ group: OrderedJSON,
        replacement: OrderedJSON?
    ) -> Rewritten {
        guard group.members != nil, let handlers = group["hooks"]?.elements else {
            return Rewritten(group: group, found: [], placed: false)
        }
        var kept: [OrderedJSON] = []
        var found: [OrderedJSON] = []
        for existing in handlers {
            guard isLiovaHandler(existing) else {
                kept.append(existing)
                continue
            }
            found.append(existing)
            if let replacement, found.count == 1 {
                kept.append(replacement)
            }
        }
        guard !found.isEmpty else { return Rewritten(group: group, found: [], placed: false) }
        guard !kept.isEmpty else { return Rewritten(group: nil, found: found, placed: false) }
        var updated = group
        updated.set("hooks", .array(kept))
        return Rewritten(group: updated, found: found, placed: replacement != nil)
    }

    private struct Rewritten {
        /// The new group, or `nil` if it should be dropped.
        var group: OrderedJSON?
        /// The Liova handlers it held.
        var found: [OrderedJSON]
        /// Whether the replacement handler went into it.
        var placed: Bool
    }

    private static func changeKind(
        previous: [OrderedJSON],
        handler: OrderedJSON,
        changedGroups: Bool
    ) -> AgentHookChange.Kind {
        if previous.isEmpty {
            .added
        } else if previous == [handler], !changedGroups {
            .unchanged
        } else {
            .updated
        }
    }

    /// `hooks` without Liova handlers under any event not in `except`.
    private static func removingLiovaHandlers(
        from hooks: OrderedJSON,
        except kept: Set<String>,
        changes: inout [AgentHookChange]
    ) -> OrderedJSON {
        var result = hooks
        for member in hooks.members ?? [] where !kept.contains(member.key) {
            guard let groups = member.value.elements else { continue }
            var removed = 0
            var cleaned: [OrderedJSON] = []
            for group in groups {
                let rewritten = rewriting(group, replacement: nil)
                removed += rewritten.found.count
                if let updated = rewritten.group {
                    cleaned.append(updated)
                }
            }
            guard removed > 0 else { continue }
            result.set(member.key, cleaned.isEmpty ? nil : .array(cleaned))
            changes.append(AgentHookChange(event: member.key, kind: .removed))
        }
        return result
    }
}

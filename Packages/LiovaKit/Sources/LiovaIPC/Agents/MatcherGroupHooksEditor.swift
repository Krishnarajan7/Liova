import Foundation

/// Pure edits to hook settings shaped like Claude Code's, which Codex (`hooks.json`) and
/// Gemini CLI (`settings.json`) share:
///
/// ```json
/// {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "…"}]}]}}
/// ```
///
/// Liova's handlers are recognised by their command: the `liova` binary followed by
/// `hook <agent>`. Everything else (other keys, other tools' hooks, matcher groups we didn't
/// create) is left exactly as it was.
public struct MatcherGroupHooksEditor: AgentSettingsEditing {
    /// One hook event Liova registers.
    public struct Event: Equatable, Sendable {
        public var name: String
        /// The handler's `timeout`, in the agent's unit (seconds, or milliseconds for Gemini).
        public var timeout: Int
        /// Whether the event's matcher filters by tool name; Liova's group then matches `*`.
        public var matchesTools: Bool

        public init(name: String, timeout: Int, matchesTools: Bool) {
            self.name = name
            self.timeout = timeout
            self.matchesTools = matchesTools
        }
    }

    /// The agent word after `liova hook`, e.g. `claude-code`.
    public var agent: String
    /// The events Liova registers, in order.
    public var events: [Event]
    /// A `name` for each handler, if the agent supports one (Gemini CLI's `/hooks` uses it).
    public var handlerName: String?

    public init(agent: String, events: [Event], handlerName: String? = nil) {
        self.agent = agent
        self.events = events
        self.handlerName = handlerName
    }

    public func command(executablePath: String) -> String {
        LiovaHookCommand.make(executablePath: executablePath, agent: agent)
    }

    /// Whether `command` runs a `liova` binary's `hook <agent>`.
    public func isLiovaCommand(_ command: String) -> Bool {
        LiovaHookCommand.matches(command, agent: agent)
    }

    // MARK: Install / uninstall

    /// `root` with Liova's handlers for every event, replacing older Liova handlers in place.
    public func installing(
        _ root: OrderedJSON,
        command: String
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        guard root.members != nil else { throw AgentSettingsShapeError("The settings file isn't a JSON object.") }
        var hooks = try hooksObject(root)
        var changes: [AgentHookChange] = []

        for event in events {
            let handler = makeHandler(command: command, timeout: event.timeout)
            var groups: [OrderedJSON] = []
            if let existing = hooks[event.name] {
                guard let elements = existing.elements else {
                    throw AgentSettingsShapeError("\"hooks.\(event.name)\" isn't a list, so it can't be extended.")
                }
                groups = elements
            }
            let (updated, kind) = install(handler, into: groups, event: event)
            hooks.set(event.name, .array(updated))
            changes.append(AgentHookChange(event: event.name, kind: kind))
        }
        // Stray Liova handlers under other events (e.g. from a future version) are removed.
        hooks = removingLiovaHandlers(from: hooks, except: Set(events.map(\.name)), changes: &changes)

        var result = root
        result.set("hooks", hooks)
        return (result, changes)
    }

    /// `root` without any Liova handler. Groups and event lists that only held Liova's
    /// handlers are removed, and so is `hooks` if nothing else is left in it.
    public func uninstalling(
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
    public func status(_ root: OrderedJSON, expectedCommand: String) -> AgentHookStatus {
        let hooks = root["hooks"]?.members ?? []
        var commands: [String] = []
        var problems: [String] = []
        for member in hooks {
            let ours = liovaHandlers(in: member.value)
            for command in ours.compactMap({ $0.handler["command"]?.stringValue }) where !commands.contains(command) {
                commands.append(command)
            }
            if !events.contains(where: { $0.name == member.key }), !ours.isEmpty {
                problems.append("Unexpected Liova hook under \(member.key).")
            }
        }
        guard !commands.isEmpty else { return AgentHookStatus(state: .notInstalled) }

        var missing: [String] = []
        for event in events {
            let ours = root["hooks"]?[event.name].map(liovaHandlers) ?? []
            if ours.isEmpty {
                missing.append(event.name)
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
    private func problem(
        _ event: Event,
        ours: [(handler: OrderedJSON, matchesAll: Bool)],
        expectedCommand: String
    ) -> String? {
        guard ours.count == 1 else { return "\(event.name) has \(ours.count) Liova hooks." }
        guard ours[0].matchesAll else { return "\(event.name) hook only runs for some tools." }
        let handler = ours[0].handler
        if handler["command"]?.stringValue == expectedCommand,
           handler != makeHandler(command: expectedCommand, timeout: event.timeout)
        {
            return "\(event.name) hook has different settings (e.g. its timeout)."
        }
        return nil
    }

    // MARK: Helpers

    func makeHandler(command: String, timeout: Int) -> OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if let handlerName {
            members.append(.init("name", .string(handlerName)))
        }
        members += [
            .init("type", .string("command")),
            .init("command", .string(command)),
            .init("timeout", .number(String(timeout))),
        ]
        return .object(members)
    }

    private func hooksObject(_ root: OrderedJSON) throws(AgentSettingsShapeError) -> OrderedJSON {
        guard let hooks = root["hooks"] else { return .object([]) }
        guard hooks.members != nil else {
            throw AgentSettingsShapeError("\"hooks\" in the settings file isn't an object.")
        }
        return hooks
    }

    private func isLiovaHandler(_ handler: OrderedJSON) -> Bool {
        handler["command"]?.stringValue.map { isLiovaCommand($0) } ?? false
    }

    private func matchesAll(_ group: OrderedJSON) -> Bool {
        guard let matcher = group["matcher"] else { return true }
        return matcher == .string("") || matcher == .string("*") || matcher == .null
    }

    private func liovaHandlers(in groups: OrderedJSON) -> [(handler: OrderedJSON, matchesAll: Bool)] {
        (groups.elements ?? []).flatMap { group in
            (group["hooks"]?.elements ?? []).filter(isLiovaHandler).map { ($0, matchesAll(group)) }
        }
    }

    /// Puts `handler` into the first match-all group that holds a Liova handler (keeping its
    /// position), drops every other Liova handler, or appends a new group.
    private func install(
        _ handler: OrderedJSON,
        into groups: [OrderedJSON],
        event: Event
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
            if event.matchesTools {
                members.append(.init("matcher", .string("*")))
            }
            members.append(.init("hooks", .array([handler])))
            result.append(.object(members))
        }
        return (result, changeKind(previous: previous, handler: handler, changedGroups: result != groups))
    }

    /// `group` with its Liova handlers removed, or the first one swapped for `replacement`.
    /// The group is `nil` when no handlers are left in it.
    private func rewriting(
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

    private func changeKind(
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
    private func removingLiovaHandlers(
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

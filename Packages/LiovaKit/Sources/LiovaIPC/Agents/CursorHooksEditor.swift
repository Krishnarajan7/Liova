import Foundation

/// Pure edits to Cursor's `hooks.json`:
///
/// ```json
/// {"version": 1, "hooks": {"preToolUse": [{"command": "…", "timeout": 5}]}}
/// ```
///
/// Each event holds a flat list of handlers. Liova's are recognised by their command
/// (`liova hook cursor`); other handlers, keys and events are left exactly as they were, and
/// Liova's handler goes after the user's own so theirs keep running first.
public struct CursorHooksEditor: AgentSettingsEditing {
    /// The only `hooks.json` schema version this editor knows.
    public static let supportedVersion = "1"
    /// Seconds Cursor gives each hook. They take milliseconds; this only bounds a hang.
    public static let timeout = 5

    public static var events: [String] {
        CursorHookAdapter.HookEvent.registered.map(\.rawValue)
    }

    public init() {}

    public func command(executablePath: String) -> String {
        LiovaHookCommand.make(executablePath: executablePath, agent: CursorHookAdapter.agentName)
    }

    public func isLiovaCommand(_ command: String) -> Bool {
        LiovaHookCommand.matches(command, agent: CursorHookAdapter.agentName)
    }

    func makeHandler(command: String) -> OrderedJSON {
        .object([
            .init("command", .string(command)),
            .init("timeout", .number(String(Self.timeout))),
        ])
    }

    // MARK: Install / uninstall

    public func installing(
        _ root: OrderedJSON,
        command: String
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        guard let members = root.members else { throw AgentSettingsShapeError("The hooks file isn't a JSON object.") }
        try checkVersion(root)
        var hooks = try hooksObject(root)
        let handler = makeHandler(command: command)
        var changes: [AgentHookChange] = []
        for event in Self.events {
            var handlers: [OrderedJSON] = []
            if let existing = hooks[event] {
                guard let elements = existing.elements else {
                    throw AgentSettingsShapeError("\"hooks.\(event)\" isn't a list, so it can't be extended.")
                }
                handlers = elements
            }
            let (updated, kind) = install(handler, into: handlers)
            hooks.set(event, .array(updated))
            changes.append(AgentHookChange(event: event, kind: kind))
        }
        hooks = removingLiovaHandlers(from: hooks, except: Set(Self.events), changes: &changes)

        var result = root
        if members.isEmpty {
            // A new file: version first, as Cursor's own examples write it.
            result = .object([.init("version", .number(Self.supportedVersion))])
        } else if root["version"] == nil {
            result.set("version", .number(Self.supportedVersion))
        }
        result.set("hooks", hooks)
        return (result, changes)
    }

    public func uninstalling(
        _ root: OrderedJSON
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        guard root.members != nil else { throw AgentSettingsShapeError("The hooks file isn't a JSON object.") }
        guard root["hooks"] != nil else { return (root, []) }
        let hooks = try hooksObject(root)
        var changes: [AgentHookChange] = []
        let cleaned = removingLiovaHandlers(from: hooks, except: [], changes: &changes)
        guard !changes.isEmpty else { return (root, []) }
        var result = root
        // Cursor requires `hooks`, so an emptied file keeps `"hooks": {}`.
        result.set("hooks", cleaned)
        return (result, changes)
    }

    public func status(_ root: OrderedJSON, expectedCommand: String) -> AgentHookStatus {
        let hooks = root["hooks"]?.members ?? []
        var commands: [String] = []
        var problems: [String] = []
        for member in hooks {
            let ours = (member.value.elements ?? []).filter(isLiovaHandler)
            for command in ours.compactMap({ $0["command"]?.stringValue }) where !commands.contains(command) {
                commands.append(command)
            }
            if !Self.events.contains(member.key), !ours.isEmpty {
                problems.append("Unexpected Liova hook under \(member.key).")
            }
        }
        guard !commands.isEmpty else { return AgentHookStatus(state: .notInstalled) }

        var missing: [String] = []
        for event in Self.events {
            let ours = (root["hooks"]?[event]?.elements ?? []).filter(isLiovaHandler)
            if ours.isEmpty {
                missing.append(event)
            } else if ours.count > 1 {
                problems.append("\(event) has \(ours.count) Liova hooks.")
            } else if ours[0]["command"]?.stringValue == expectedCommand,
                      ours[0] != makeHandler(command: expectedCommand)
            {
                problems.append("\(event) hook has different settings (e.g. its timeout).")
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

    // MARK: Helpers

    /// `handlers` with `handler` in place of the first Liova handler (other Liova handlers
    /// dropped), or appended after the user's own.
    private func install(
        _ handler: OrderedJSON,
        into handlers: [OrderedJSON]
    ) -> ([OrderedJSON], AgentHookChange.Kind) {
        let ours = handlers.filter(isLiovaHandler)
        var updated = handlers.filter { !isLiovaHandler($0) }
        if let first = handlers.firstIndex(where: isLiovaHandler) {
            // Keep the first Liova handler's position among the user's own.
            let foreignBefore = handlers[..<first].filter { !isLiovaHandler($0) }.count
            updated.insert(handler, at: foreignBefore)
        } else {
            updated.append(handler)
        }
        let kind: AgentHookChange.Kind = if ours.isEmpty {
            .added
        } else if ours == [handler], updated == handlers {
            .unchanged
        } else {
            .updated
        }
        return (updated, kind)
    }

    private func checkVersion(_ root: OrderedJSON) throws(AgentSettingsShapeError) {
        guard let version = root["version"] else { return }
        guard case let .number(literal) = version, Double(literal) == Double(Self.supportedVersion) else {
            throw AgentSettingsShapeError(
                "\"version\" isn't \(Self.supportedVersion), a hooks.json format this Liova doesn't know."
            )
        }
    }

    private func hooksObject(_ root: OrderedJSON) throws(AgentSettingsShapeError) -> OrderedJSON {
        guard let hooks = root["hooks"] else { return .object([]) }
        guard hooks.members != nil else {
            throw AgentSettingsShapeError("\"hooks\" in the hooks file isn't an object.")
        }
        return hooks
    }

    private func isLiovaHandler(_ handler: OrderedJSON) -> Bool {
        handler["command"]?.stringValue.map { isLiovaCommand($0) } ?? false
    }

    /// `hooks` without Liova handlers under any event not in `kept`. Events left empty go.
    private func removingLiovaHandlers(
        from hooks: OrderedJSON,
        except kept: Set<String>,
        changes: inout [AgentHookChange]
    ) -> OrderedJSON {
        var result = hooks
        for member in hooks.members ?? [] where !kept.contains(member.key) {
            guard let handlers = member.value.elements else { continue }
            let remaining = handlers.filter { !isLiovaHandler($0) }
            guard remaining.count < handlers.count else { continue }
            result.set(member.key, remaining.isEmpty ? nil : .array(remaining))
            changes.append(AgentHookChange(event: member.key, kind: .removed))
        }
        return result
    }
}

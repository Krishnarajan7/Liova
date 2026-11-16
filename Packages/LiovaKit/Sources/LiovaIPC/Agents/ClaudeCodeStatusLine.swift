import Foundation
import LiovaPluginKit

/// Reads the JSON Claude Code gives a status line command and turns it into what Liova
/// shows: how much of the 5-hour and 7-day limits, the context window and the session's
/// cost is used. Pure, so every mapping is unit-tested.
///
/// A status line is the only place Claude Code hands this out. Liova's command runs there,
/// reports the numbers, and prints a line of its own (or runs the status line you already
/// had, see ``ClaudeCodeStatusLineEditor``).
///
/// Privacy: only the numbers, the model's name and the project folder's name are read.
public enum ClaudeCodeStatusLine {
    /// The usage event for one status line input, or `nil` when it carries nothing to show.
    public static func usageEvent(from input: Data) -> AgentEvent? {
        guard case let .success(object) = AgentHookFields.object(input),
              let sessionID = AgentHookFields.sessionID(object.string("session_id"))
        else { return nil }
        let usage = usage(from: object)
        guard !usage.isEmpty else { return nil }
        let folder = object.object("workspace")?.string("current_dir") ?? object.string("cwd")
        return AgentEvent(
            agent: ClaudeCodeHookAdapter.agentName,
            sessionID: sessionID,
            project: AgentHookFields.project(fromPath: folder),
            kind: .usage,
            usage: usage
        )
    }

    static func usage(from object: HookInput) -> AgentUsage {
        let limits = object.object("rate_limits")
        let model = object.object("model")?.string("display_name")
        return AgentUsage(
            fiveHour: window(limits?.object("five_hour")),
            sevenDay: window(limits?.object("seven_day")),
            contextUsedPercentage: percentage(object.object("context_window")?.number("used_percentage")),
            costUSD: object.object("cost")?.number("total_cost_usd").flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            model: model.map { String($0.prefix(LiovaValidation.maxAgentNameLength)) }
        )
    }

    private static func window(_ object: HookInput?) -> AgentUsage.Window? {
        guard let used = percentage(object?.number("used_percentage")) else { return nil }
        let resetsAt = object?.number("resets_at").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return AgentUsage.Window(usedPercentage: used, resetsAt: resetsAt)
    }

    private static func percentage(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    /// The line Liova prints when you had no status line of your own:
    /// `Opus · 42% context · 5h 23% · 7d 41%`.
    public static func defaultLine(from input: Data) -> String {
        guard case let .success(object) = AgentHookFields.object(input) else { return "" }
        let usage = usage(from: object)
        var parts: [String] = []
        if let model = usage.model, !model.isEmpty {
            parts.append(model)
        }
        if let context = usage.contextUsedPercentage {
            parts.append("\(Int(context.rounded()))% context")
        }
        if let window = usage.fiveHour {
            parts.append("5h \(Int(window.usedPercentage.rounded()))%")
        }
        if let window = usage.sevenDay {
            parts.append("7d \(Int(window.usedPercentage.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }
}

extension HookInput {
    /// A JSON number (never a boolean, which JSONSerialization also reads as NSNumber).
    func number(_ key: String) -> Double? {
        guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

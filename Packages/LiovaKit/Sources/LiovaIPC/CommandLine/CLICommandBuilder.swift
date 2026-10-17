import Foundation
import LiovaPluginKit

/// Turns parsed option values into an ``IPCCommand``.
struct CommandBuilder {
    let command: CLIParser.Command
    let values: [String: String]
    let now: Date

    func build() throws(CLIUsageError) -> IPCCommand {
        let built: IPCCommand = switch command {
        case .ping: .ping
        case .list: .list
        case .start: try .start(activity())
        case .update: try .update(patch())
        case .end: try end()
        }
        do {
            try LiovaValidation.validate(built)
        } catch {
            throw usage(error.message)
        }
        return built
    }

    private func activity() throws(CLIUsageError) -> Activity {
        let source = values["source"] ?? CLIParser.defaultSource
        // Without --id, the source names the activity: one live activity per tool.
        return try Activity(
            id: ActivityID(values["id"] ?? source),
            source: source,
            priority: priority() ?? .normal,
            title: required("title"),
            subtitle: values["subtitle"],
            symbol: values["symbol"],
            progress: progress(),
            tint: tint() ?? .accent,
            expiresAt: ttl().map(now.addingTimeInterval)
        )
    }

    private func patch() throws(CLIUsageError) -> ActivityPatch {
        var patch = try ActivityPatch(
            id: ActivityID(required("id")),
            title: values["title"],
            subtitle: values["subtitle"],
            symbol: values["symbol"],
            progress: progress(),
            tint: tint(),
            priority: priority(),
            expiresAt: ttl().map(now.addingTimeInterval)
        )
        if let list = values["clear"] {
            patch.clear = try clearFields(list)
        }
        guard !patch.isEmpty else {
            throw usage("Nothing to update. Pass at least one field (e.g. --progress 0.5) or --clear.")
        }
        return patch
    }

    private func end() throws(CLIUsageError) -> IPCCommand {
        switch (values["id"], values["source"]) {
        case let (id?, nil): .end(ActivityID(id))
        case let (nil, source?): .endAll(source: source)
        case (.some, .some): throw usage("Pass either --id or --source, not both.")
        case (nil, nil): throw usage("Missing --id (one activity) or --source (all of a source's activities).")
        }
    }

    // MARK: Values

    private func required(_ name: String) throws(CLIUsageError) -> String {
        guard let value = values[name] else { throw usage("Missing required option --\(name).") }
        return value
    }

    private func progress() throws(CLIUsageError) -> Double? {
        guard let text = values["progress"] else { return nil }
        guard let value = CLIValues.progress(text) else {
            throw usage("--progress must be a number from 0 to 1 (or a percentage like 40%), got '\(text)'.")
        }
        return value
    }

    private func priority() throws(CLIUsageError) -> ActivityPriority? {
        guard let text = values["priority"] else { return nil }
        guard let value = CLIValues.priority(text) else {
            throw usage("--priority must be low, normal, high, critical or an integer, got '\(text)'.")
        }
        return value
    }

    private func tint() throws(CLIUsageError) -> ActivityTint? {
        guard let text = values["tint"] else { return nil }
        guard let value = ActivityTint(rawValue: text.lowercased()) else {
            let names = ActivityTint.allCases.map(\.rawValue).joined(separator: ", ")
            throw usage("Unknown --tint '\(text)'. Use one of: \(names).")
        }
        return value
    }

    private func ttl() throws(CLIUsageError) -> TimeInterval? {
        guard let text = values["ttl"] else { return nil }
        guard let seconds = CLIValues.duration(text) else {
            throw usage("--ttl must be a positive duration like 30, 90s, 10m or 2h; got '\(text)'.")
        }
        return seconds
    }

    private func clearFields(_ list: String) throws(CLIUsageError) -> Set<ActivityPatch.Field> {
        var fields: Set<ActivityPatch.Field> = []
        for raw in list.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "subtitle": fields.insert(.subtitle)
            case "symbol": fields.insert(.symbol)
            case "progress": fields.insert(.progress)
            case "ttl", "expiresat", "expiry": fields.insert(.expiresAt)
            default: throw usage("Can't clear '\(name)'. Clearable: subtitle, symbol, progress, ttl.")
            }
        }
        guard !fields.isEmpty else { throw usage("--clear needs a comma-separated list, e.g. progress,subtitle.") }
        return fields
    }

    private func usage(_ message: String) -> CLIUsageError {
        CLIUsageError(message, command: command.displayName)
    }
}

/// Lenient parsers for human-typed values.
enum CLIValues {
    /// `0.4` or `40%`, in `0...1`.
    static func progress(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let value: Double? = trimmed.hasSuffix("%") ? Double(trimmed.dropLast()).map { $0 / 100 } : Double(trimmed)
        guard let value, value.isFinite, (0 ... 1).contains(value) else { return nil }
        return value
    }

    /// A level name or an integer.
    static func priority(_ text: String) -> ActivityPriority? {
        switch text.lowercased() {
        case "low": .low
        case "normal": .normal
        case "high": .high
        case "critical": .critical
        default: Int(text).map(ActivityPriority.init(rawValue:))
        }
    }

    /// Seconds, optionally with a unit: `30`, `30s`, `1.5m`, `2h`, `1d`. Must be positive.
    static func duration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(suffix: String, seconds: Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600), ("d", 86400)]
        var number = Substring(trimmed)
        var multiplier = 1.0
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            number = trimmed.dropLast(unit.suffix.count)
            multiplier = unit.seconds
            break
        }
        guard let value = Double(number), value.isFinite, value > 0 else { return nil }
        let seconds = value * multiplier
        return seconds.isFinite ? seconds : nil
    }
}

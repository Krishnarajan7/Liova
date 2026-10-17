import Foundation
import LiovaPluginKit

/// Parses `liova://` URLs into commands.
///
/// ```
/// liova://activity/start?id=build&title=Deploying&progress=0.4&symbol=hammer&tint=blue&ttl=10
/// liova://activity/update?id=build&progress=0.8
/// liova://activity/end?id=build
/// ```
///
/// URLs are **low trust**: any web page, document or app can open one without the user
/// noticing. So URL activities always get the source ``source`` (`url`), priority is capped at
/// `.normal`, and every activity expires: `ttl` defaults to ``defaultTTL`` and is capped at
/// ``maxTTL`` (one hour), and can't be cleared. The app must also only let URL `update` and
/// `end` commands touch activities whose source is `url`.
public enum LiovaURL {
    public static let scheme = "liova"
    /// The source given to every activity created from a URL.
    public static let source = "url"
    /// Longest accepted URL, in UTF-8 bytes.
    public static let maxURLLength = 4096
    /// Upper bound for `ttl`, in seconds. Longer values are lowered to this.
    public static let maxTTL: TimeInterval = 60 * 60
    /// Expiry used by `start` when the URL gives no `ttl`.
    public static let defaultTTL: TimeInterval = 10 * 60
    /// Highest priority a URL can request; higher values are lowered to this.
    public static let maxPriority = ActivityPriority.normal

    private static let startKeys: Set<String> = [
        "id", "title", "subtitle", "symbol", "progress", "tint", "priority", "ttl",
    ]
    private static let updateKeys = startKeys.union(["clear"])
    private static let endKeys: Set<String> = ["id"]

    /// Parses and validates a `liova://` URL.
    ///
    /// - Parameter now: The current time, used to turn `ttl` into an expiry date.
    /// - Throws: ``IPCErrorInfo`` with code `badRequest` (or `tooLarge`, `forbidden`), with a
    ///   message suitable for logging.
    public static func command(from url: URL, now: Date = Date()) throws(IPCErrorInfo) -> IPCCommand {
        let text = url.absoluteString
        guard text.utf8.count <= maxURLLength else {
            throw IPCErrorInfo(.tooLarge, "URL is longer than \(maxURLLength) bytes.")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme
        else {
            throw IPCErrorInfo(.badRequest, "Not a \(scheme):// URL.")
        }
        guard components.user == nil, components.password == nil, components.port == nil else {
            throw IPCErrorInfo(.badRequest, "\(scheme):// URLs can't contain a user, password or port.")
        }
        guard components.host?.lowercased() == "activity" else {
            throw IPCErrorInfo(
                .badRequest,
                "Unknown \(scheme):// target '\(components.host?.prefix(40) ?? "")'. "
                    + "Use \(scheme)://activity/start, update or end."
            )
        }
        let action = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = try parameters(components)

        let command: IPCCommand
        switch action {
        case "start":
            try rejectUnknown(query, allowed: startKeys, action: action)
            command = try .start(activity(from: query, now: now))
        case "update":
            try rejectUnknown(query, allowed: updateKeys, action: action)
            command = try .update(patch(from: query, now: now))
        case "end":
            try rejectUnknown(query, allowed: endKeys, action: action)
            command = try .end(ActivityID(required("id", query)))
        default:
            throw IPCErrorInfo(.badRequest, "Unknown action '\(action.prefix(40))'. Use start, update or end.")
        }
        try LiovaValidation.validate(command)
        return command
    }

    // MARK: Building commands

    private static func activity(from query: [String: String], now: Date) throws(IPCErrorInfo) -> Activity {
        let ttl = try query["ttl"].map { value throws(IPCErrorInfo) in try parseTTL(value) } ?? defaultTTL
        return try Activity(
            id: ActivityID(required("id", query)),
            source: source,
            priority: query["priority"].map { value throws(IPCErrorInfo) in try parsePriority(value) } ?? .normal,
            title: required("title", query),
            subtitle: query["subtitle"],
            symbol: query["symbol"],
            progress: query["progress"].map { value throws(IPCErrorInfo) in try parseProgress(value) },
            tint: query["tint"].map { value throws(IPCErrorInfo) in try parseTint(value) } ?? .accent,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    private static func patch(from query: [String: String], now: Date) throws(IPCErrorInfo) -> ActivityPatch {
        var patch = try ActivityPatch(id: ActivityID(required("id", query)))
        patch.title = query["title"]
        patch.subtitle = query["subtitle"]
        patch.symbol = query["symbol"]
        if let value = query["progress"] {
            patch.progress = try parseProgress(value)
        }
        if let value = query["tint"] {
            patch.tint = try parseTint(value)
        }
        if let value = query["priority"] {
            patch.priority = try parsePriority(value)
        }
        if let value = query["ttl"] {
            patch.expiresAt = try now.addingTimeInterval(parseTTL(value))
        }
        if let value = query["clear"] {
            patch.clear = try parseClear(value)
        }
        return patch
    }

    // MARK: Values

    private static func parameters(_ components: URLComponents) throws(IPCErrorInfo) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard result[item.name] == nil else {
                throw IPCErrorInfo(.badRequest, "Parameter '\(item.name.prefix(40))' appears more than once.")
            }
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private static func rejectUnknown(
        _ query: [String: String],
        allowed: Set<String>,
        action: String
    ) throws(IPCErrorInfo) {
        let unknown = Set(query.keys).subtracting(allowed).sorted().map { String($0.prefix(40)) }
        guard unknown.isEmpty else {
            let hint = unknown.contains("source") ? " URL activities always have source '\(source)'." : ""
            throw IPCErrorInfo(
                .badRequest,
                "Unknown parameter(s) for '\(action)': \(unknown.joined(separator: ", ")).\(hint) "
                    + "Allowed: \(allowed.sorted().joined(separator: ", "))."
            )
        }
    }

    private static func required(_ key: String, _ query: [String: String]) throws(IPCErrorInfo) -> String {
        guard let value = query[key], !value.isEmpty else {
            throw IPCErrorInfo(.badRequest, "Missing required parameter '\(key)'.")
        }
        return value
    }

    private static func parseClear(_ value: String) throws(IPCErrorInfo) -> Set<ActivityPatch.Field> {
        var fields: Set<ActivityPatch.Field> = []
        for name in value.split(separator: ",", omittingEmptySubsequences: true) {
            let name = name.trimmingCharacters(in: .whitespaces)
            switch name {
            case "subtitle": fields.insert(.subtitle)
            case "symbol": fields.insert(.symbol)
            case "progress": fields.insert(.progress)
            case "ttl", "expiresAt":
                throw IPCErrorInfo(.forbidden, "URL activities must expire; 'ttl' can't be cleared.")
            default:
                throw IPCErrorInfo(
                    .badRequest,
                    "Can't clear '\(name.prefix(40))'. Clearable: subtitle, symbol, progress."
                )
            }
        }
        return fields
    }

    /// Seconds, capped at ``maxTTL``.
    private static func parseTTL(_ value: String) throws(IPCErrorInfo) -> TimeInterval {
        guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
            throw IPCErrorInfo(.badRequest, "'ttl' must be a positive number of seconds, got '\(value.prefix(40))'.")
        }
        return min(seconds, maxTTL)
    }

    private static func parseProgress(_ value: String) throws(IPCErrorInfo) -> Double {
        guard let progress = Double(value), progress.isFinite, (0 ... 1).contains(progress) else {
            throw IPCErrorInfo(.badRequest, "'progress' must be a number from 0 to 1, got '\(value.prefix(40))'.")
        }
        return progress
    }

    private static func parseTint(_ value: String) throws(IPCErrorInfo) -> ActivityTint {
        guard let tint = ActivityTint(rawValue: value.lowercased()) else {
            let names = ActivityTint.allCases.map(\.rawValue).joined(separator: ", ")
            throw IPCErrorInfo(.badRequest, "Unknown tint '\(value.prefix(40))'. Use one of: \(names).")
        }
        return tint
    }

    /// Accepts a level name or an integer, then caps it at ``maxPriority``.
    private static func parsePriority(_ value: String) throws(IPCErrorInfo) -> ActivityPriority {
        let requested: ActivityPriority
        switch value.lowercased() {
        case "low": requested = .low
        case "normal": requested = .normal
        case "high": requested = .high
        case "critical": requested = .critical
        default:
            guard let raw = Int(value) else {
                throw IPCErrorInfo(
                    .badRequest,
                    "'priority' must be low, normal, high, critical or an integer, got '\(value.prefix(40))'."
                )
            }
            requested = ActivityPriority(rawValue: raw)
        }
        return min(requested, maxPriority)
    }
}

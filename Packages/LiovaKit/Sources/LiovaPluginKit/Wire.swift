import Foundation

// The tier 1 wire protocol: newline-delimited JSON over a Unix domain socket.
//
// One request is one line of UTF-8 JSON terminated by `\n`; the server answers each request
// with exactly one response line, in order. A connection may carry any number of requests.
// See docs/PLUGIN-API.md for the user-facing reference.

/// Shared settings and coders for the tier 1 wire format, so clients and the server agree.
public enum LiovaWire {
    /// Oldest request version the server still accepts.
    public static let minimumSupportedVersion = 1
    /// Largest request line the server accepts, newline excluded.
    public static let maxRequestLineBytes = 64 * 1024

    /// The encoder every party uses for wire messages.
    ///
    /// Dates are encoded as **seconds since 1970** (a JSON number). Output is compact (one line)
    /// with sorted keys, so it is stable and diff-friendly.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    /// The decoder every party uses for wire messages.
    ///
    /// Dates are read as seconds since 1970. As a convenience for shell scripts, an ISO-8601
    /// string (`2026-10-17T12:00:00Z`, optionally with fractional seconds) is accepted too.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                guard seconds.isFinite else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date must be finite.")
                }
                return Date(timeIntervalSince1970: seconds)
            }
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) {
                return date
            }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected seconds since 1970 or an ISO-8601 date, got '\(text)'."
            )
        }
        return decoder
    }

    /// Encodes a message as one wire line, including the trailing newline.
    public static func encodeLine(_ value: some Encodable) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// Decodes one request line (without its newline) into a request, or explains why it can't.
    ///
    /// Never throws or traps on hostile input. The version is checked before the body, so an
    /// old server answers a newer client with `unsupportedVersion` rather than a vague
    /// `badRequest`.
    public static func decodeRequest(_ line: Data) -> Result<IPCRequest, IPCErrorInfo> {
        let decoder = makeDecoder()
        let header: RequestHeader
        do {
            header = try decoder.decode(RequestHeader.self, from: line)
        } catch {
            return .failure(IPCErrorInfo(.badRequest, "Request is not a JSON object: \(describe(error))"))
        }
        guard let version = header.version else {
            return .failure(IPCErrorInfo(
                .badRequest,
                "Missing or non-integer protocol version \"v\". Send \"v\":\(currentVersion)."
            ))
        }
        guard (minimumSupportedVersion ... currentVersion).contains(version) else {
            return .failure(IPCErrorInfo(
                .unsupportedVersion,
                "Protocol version \(version) is not supported. This server speaks versions "
                    + "\(minimumSupportedVersion) through \(currentVersion)."
            ))
        }
        guard let opName = header.opName else {
            return .failure(IPCErrorInfo(
                .badRequest,
                "Missing or non-string \"op\". Expected one of: \(IPCCommand.opNames)."
            ))
        }
        guard IPCCommand.Op(rawValue: opName) != nil else {
            return .failure(IPCErrorInfo(
                .badRequest,
                "Unknown op '\(opName)'. Expected one of: \(IPCCommand.opNames)."
            ))
        }
        do {
            return try .success(decoder.decode(IPCRequest.self, from: line))
        } catch {
            return .failure(IPCErrorInfo(.badRequest, "Invalid '\(opName)' request: \(describe(error))"))
        }
    }

    /// A short, human-readable description of a coding error, including the JSON path.
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else {
            return String(describing: error)
        }
        func path(_ codingPath: [any CodingKey]) -> String {
            let joined = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "the top level" : "'\(joined)'"
        }
        switch error {
        case let .keyNotFound(key, context):
            let parent = context.codingPath.isEmpty ? "" : " in \(path(context.codingPath))"
            return "missing required field '\(key.stringValue)'\(parent)."
        case let .typeMismatch(type, context):
            return "wrong type at \(path(context.codingPath)); expected \(type)."
        case let .valueNotFound(type, context):
            return "null at \(path(context.codingPath)); expected \(type)."
        case let .dataCorrupted(context):
            let underlying = context.underlyingError.map { " (\(($0 as NSError).localizedDescription))" } ?? ""
            return "\(context.debugDescription)\(underlying) at \(path(context.codingPath))."
        @unknown default:
            return String(describing: error)
        }
    }

    static var currentVersion: Int {
        LiovaPluginKit.apiVersion
    }
}

/// Just enough of a request to route it, decoded leniently first.
private struct RequestHeader: Decodable {
    var version: Int?
    var opName: String?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case opName = "op"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Wrong types are reported later by the full decode, with a precise path.
        version = try? container.decodeIfPresent(Int.self, forKey: .version)
        opName = try? container.decodeIfPresent(String.self, forKey: .opName)
    }
}

// MARK: - Requests

/// One request line: a protocol version and a command.
///
/// Wire shape (one line): `{"v":1,"op":"start","activity":{...}}`.
public struct IPCRequest: Codable, Sendable, Equatable {
    /// The protocol version the client speaks. Defaults to ``LiovaPluginKit/apiVersion``.
    public var version: Int
    public var command: IPCCommand

    public init(version: Int = LiovaPluginKit.apiVersion, command: IPCCommand) {
        self.version = version
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case operation = "op"
        case activity, patch, id, source, event, permission
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        let opName = try container.decode(String.self, forKey: .operation)
        guard let operation = IPCCommand.Op(rawValue: opName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .operation,
                in: container,
                debugDescription: "Unknown op '\(opName)'. Expected one of: \(IPCCommand.opNames)."
            )
        }
        switch operation {
        case .ping: command = .ping
        case .list: command = .list
        case .start: command = try .start(container.decode(Activity.self, forKey: .activity))
        case .update: command = try .update(container.decode(ActivityPatch.self, forKey: .patch))
        case .end: command = try .end(container.decode(ActivityID.self, forKey: .id))
        case .endAll: command = try .endAll(source: container.decode(String.self, forKey: .source))
        case .agentEvent: command = try .agentEvent(container.decode(AgentEvent.self, forKey: .event))
        case .agentPermission:
            command = try .agentPermission(container.decode(AgentPermissionRequest.self, forKey: .permission))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(command.op.rawValue, forKey: .operation)
        switch command {
        case .ping, .list:
            break
        case let .start(activity):
            try container.encode(activity, forKey: .activity)
        case let .update(patch):
            try container.encode(patch, forKey: .patch)
        case let .end(id):
            try container.encode(id, forKey: .id)
        case let .endAll(source):
            try container.encode(source, forKey: .source)
        case let .agentEvent(event):
            try container.encode(event, forKey: .event)
        case let .agentPermission(request):
            try container.encode(request, forKey: .permission)
        }
    }
}

/// What a client asks Liova to do.
public enum IPCCommand: Sendable, Equatable {
    /// Liveness check. Answered by the server itself with `ok` and the server version.
    case ping
    /// Shows an activity, or replaces it entirely if one with the same ID exists (upsert).
    case start(Activity)
    /// Changes some fields of an existing activity. Fails with `notFound` if there is none.
    case update(ActivityPatch)
    /// Ends one activity by ID.
    case end(ActivityID)
    /// Ends every activity owned by `source`.
    case endAll(source: String)
    /// Returns the live activities.
    case list
    /// Reports what a coding agent is doing (Agent Island).
    case agentEvent(AgentEvent)
    /// Asks the user to allow or deny an agent action. The response carries a `decision`;
    /// the request may stay open until the user answers or the request's timeout passes.
    case agentPermission(AgentPermissionRequest)

    /// The `op` string used on the wire.
    public enum Op: String, Sendable, CaseIterable { // swiftlint:disable:this type_name
        case ping, start, update, end, endAll, list, agentEvent, agentPermission
    }

    /// The wire name of this command, matching the wire field `op`.
    public var op: Op { // swiftlint:disable:this identifier_name
        switch self {
        case .ping: .ping
        case .start: .start
        case .update: .update
        case .end: .end
        case .endAll: .endAll
        case .list: .list
        case .agentEvent: .agentEvent
        case .agentPermission: .agentPermission
        }
    }

    static var opNames: String {
        Op.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

// MARK: - Responses

/// The single response line sent for each request.
///
/// Wire shape: `{"ok":true,"v":1}`, `{"ok":true,"v":1,"activities":[...]}` or
/// `{"ok":false,"v":1,"error":{"code":"notFound","message":"..."}}`.
public struct IPCResponse: Codable, Sendable, Equatable {
    /// Whether the request succeeded, matching the wire field `ok`.
    public var ok: Bool // swiftlint:disable:this identifier_name
    public var error: IPCErrorInfo?
    /// The live activities for `list`. Handlers may also return the affected activity for
    /// `start` and `update`.
    public var activities: [Activity]?
    /// The protocol version the server speaks, so clients can detect what is available.
    public var serverVersion: Int
    /// The user's answer to `agentPermission`.
    public var decision: AgentDecision?

    public init(
        ok: Bool, // swiftlint:disable:this identifier_name
        error: IPCErrorInfo? = nil,
        activities: [Activity]? = nil,
        serverVersion: Int = LiovaPluginKit.apiVersion,
        decision: AgentDecision? = nil
    ) {
        self.ok = ok
        self.error = error
        self.activities = activities
        self.serverVersion = serverVersion
        self.decision = decision
    }

    /// A successful answer to `agentPermission`.
    public static func decided(_ decision: AgentDecision) -> IPCResponse {
        IPCResponse(ok: true, decision: decision)
    }

    /// A successful response, optionally carrying activities.
    public static func success(activities: [Activity]? = nil) -> IPCResponse {
        IPCResponse(ok: true, activities: activities)
    }

    /// A failed response.
    public static func failure(_ code: IPCErrorCode, _ message: String) -> IPCResponse {
        IPCResponse(ok: false, error: IPCErrorInfo(code, message))
    }

    /// A failed response.
    public static func failure(_ error: IPCErrorInfo) -> IPCResponse {
        IPCResponse(ok: false, error: error)
    }

    private enum CodingKeys: String, CodingKey {
        case ok, error, activities, decision // swiftlint:disable:this identifier_name
        case serverVersion = "v"
    }
}

/// A machine-readable error code plus a human-readable message.
public struct IPCErrorInfo: Codable, Sendable, Equatable, Error, CustomStringConvertible {
    public var code: IPCErrorCode
    public var message: String

    public init(_ code: IPCErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public init(code: IPCErrorCode, message: String) {
        self.init(code, message)
    }

    public var description: String {
        "\(code.rawValue): \(message)"
    }
}

/// Error codes. Open-ended: clients must treat unknown codes as generic failures, so new
/// codes can be added without a protocol version bump.
public struct IPCErrorCode: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The request is malformed or fails validation.
    public static let badRequest = IPCErrorCode(rawValue: "badRequest")
    /// The request's `v` is newer (or older) than the server supports.
    public static let unsupportedVersion = IPCErrorCode(rawValue: "unsupportedVersion")
    /// No activity with that ID (or source) exists.
    public static let notFound = IPCErrorCode(rawValue: "notFound")
    /// The client may not do this, e.g. touch a `system.*` activity or connect as another user.
    public static let forbidden = IPCErrorCode(rawValue: "forbidden")
    /// The request line is over the size limit. The server closes the connection after this.
    public static let tooLarge = IPCErrorCode(rawValue: "tooLarge")
    /// The client sent requests faster than the per-connection limit. Retry later.
    public static let rateLimited = IPCErrorCode(rawValue: "rateLimited")
    /// The server has too many open connections. The connection is closed; retry later.
    public static let busy = IPCErrorCode(rawValue: "busy")
    /// The app can't serve the request right now (e.g. still launching).
    public static let unavailable = IPCErrorCode(rawValue: "unavailable")
    /// A bug or unexpected failure inside Liova.
    public static let `internal` = IPCErrorCode(rawValue: "internal")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }
}

import Foundation

/// Validation rules shared by clients and the server, so a client can reject bad input
/// before sending it and the server enforces exactly the same limits.
///
/// Every failure is an ``IPCErrorInfo`` with code `badRequest` (or `forbidden` for reserved
/// sources) and a message that names the offending field.
public enum LiovaValidation {
    /// Max length of an activity ID, in characters. IDs use ``identifierCharacters``.
    public static let maxIDLength = 128
    /// Max length of a source name, in characters. Sources use ``identifierCharacters``.
    public static let maxSourceLength = 128
    /// Max length of a title, in Unicode scalars.
    public static let maxTitleLength = 200
    /// Max length of a subtitle, in Unicode scalars.
    public static let maxSubtitleLength = 200
    /// Max length of an SF Symbol name, in characters.
    public static let maxSymbolLength = 100
    /// Accepted range for raw priority values. Named levels are 100, 200, 300 and 400.
    public static let priorityRange = 0 ... 1000
    /// Sources starting with this prefix belong to Liova's built-in features. External clients
    /// can't create, change or end their activities.
    public static let reservedSourcePrefix = "system."

    /// Characters allowed in IDs and sources: `A-Z a-z 0-9 . _ -`.
    public static func isIdentifierCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", ".", "_", "-": true
        default: false
        }
    }

    /// True for sources reserved to built-in features (`system` and `system.*`, any case).
    public static func isReservedSource(_ source: String) -> Bool {
        let lowered = source.lowercased()
        return lowered == "system" || lowered.hasPrefix(reservedSourcePrefix)
    }

    // MARK: Commands

    /// Validates a command as received from an external client.
    ///
    /// - Parameter allowReservedSources: Pass `true` only for trusted, in-process callers.
    ///   External clients (socket, CLI, URLs) must never be allowed to use `system.*`.
    public static func validate(_ command: IPCCommand, allowReservedSources: Bool = false) throws(IPCErrorInfo) {
        switch command {
        case .ping, .list:
            return
        case let .start(activity):
            try validate(activity, allowReservedSources: allowReservedSources)
        case let .update(patch):
            try validate(patch)
        case let .end(id):
            try validateID(id)
        case let .endAll(source):
            try validateSource(source, allowReserved: allowReservedSources)
        case let .agentEvent(event):
            try validate(event)
        case let .agentPermission(request):
            try validate(request)
        }
    }

    /// Validates a complete activity, as sent with `start`.
    public static func validate(_ activity: Activity, allowReservedSources: Bool = false) throws(IPCErrorInfo) {
        try validateID(activity.id)
        try validateSource(activity.source, allowReserved: allowReservedSources)
        try validateTitle(activity.title)
        if let subtitle = activity.subtitle {
            try validateSubtitle(subtitle)
        }
        if let symbol = activity.symbol {
            try validateSymbol(symbol)
        }
        try validatePriority(activity.priority)
        if let expiresAt = activity.expiresAt {
            try validateDate(expiresAt, field: "expiresAt")
        }
    }

    /// Validates a patch, as sent with `update`.
    public static func validate(_ patch: ActivityPatch) throws(IPCErrorInfo) {
        try validateID(patch.id)
        if let title = patch.title {
            try validateTitle(title)
        }
        if let subtitle = patch.subtitle {
            try validateSubtitle(subtitle)
        }
        if let symbol = patch.symbol {
            try validateSymbol(symbol)
        }
        if let progress = patch.progress, !progress.isFinite {
            throw IPCErrorInfo(.badRequest, "'progress' must be a finite number in 0...1.")
        }
        if let priority = patch.priority {
            try validatePriority(priority)
        }
        if let expiresAt = patch.expiresAt {
            try validateDate(expiresAt, field: "expiresAt")
        }
        let conflicts = patch.conflictingFields
        if !conflicts.isEmpty {
            let names = conflicts.sorted().map(\.rawValue).joined(separator: ", ")
            throw IPCErrorInfo(.badRequest, "A patch can't both set and clear the same field (\(names)).")
        }
    }

    // MARK: Fields

    public static func validateID(_ id: ActivityID) throws(IPCErrorInfo) {
        try validateIdentifier(id.rawValue, field: "id", maxLength: maxIDLength)
    }

    public static func validateSource(_ source: String, allowReserved: Bool = false) throws(IPCErrorInfo) {
        try validateIdentifier(source, field: "source", maxLength: maxSourceLength)
        if !allowReserved, isReservedSource(source) {
            throw IPCErrorInfo(
                .forbidden,
                "Source '\(source)' is reserved for Liova's built-in features. Use your own name, e.g. 'my-tool'."
            )
        }
    }

    public static func validateTitle(_ title: String) throws(IPCErrorInfo) {
        if title.allSatisfy(\.isWhitespace) {
            throw IPCErrorInfo(.badRequest, "'title' must not be empty.")
        }
        try validateText(title, field: "title", maxLength: maxTitleLength)
    }

    public static func validateSubtitle(_ subtitle: String) throws(IPCErrorInfo) {
        try validateText(subtitle, field: "subtitle", maxLength: maxSubtitleLength)
    }

    /// SF Symbol names: letters, digits and single dots between them, e.g. `hammer.fill`.
    public static func validateSymbol(_ symbol: String) throws(IPCErrorInfo) {
        let scalars = symbol.unicodeScalars
        let charactersOK = scalars.allSatisfy { scalar in
            switch scalar {
            case "A" ... "Z", "a" ... "z", "0" ... "9", ".", "_", "-": true
            default: false
            }
        }
        guard !symbol.isEmpty, scalars.count <= maxSymbolLength, charactersOK,
              !symbol.hasPrefix("."), !symbol.hasSuffix("."), !symbol.contains("..")
        else {
            throw IPCErrorInfo(
                .badRequest,
                "'symbol' must be an SF Symbol name like 'hammer.fill' (letters, digits and dots, "
                    + "at most \(maxSymbolLength) characters)."
            )
        }
    }

    public static func validatePriority(_ priority: ActivityPriority) throws(IPCErrorInfo) {
        guard priorityRange.contains(priority.rawValue) else {
            throw IPCErrorInfo(
                .badRequest,
                "'priority' must be low, normal, high, critical or an integer in "
                    + "\(priorityRange.lowerBound)...\(priorityRange.upperBound), got \(priority.rawValue)."
            )
        }
    }

    // MARK: Helpers

    private static func validateIdentifier(_ value: String, field: String, maxLength: Int) throws(IPCErrorInfo) {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxLength, scalars.allSatisfy(isIdentifierCharacter) else {
            throw IPCErrorInfo(
                .badRequest,
                "'\(field)' must be 1 to \(maxLength) characters of A-Z, a-z, 0-9, '.', '_' or '-'"
                    + (value.isEmpty ? "." : ", got '\(truncated(value))'.")
            )
        }
    }

    private static func validateText(_ text: String, field: String, maxLength: Int) throws(IPCErrorInfo) {
        let scalars = text.unicodeScalars
        guard scalars.count <= maxLength else {
            throw IPCErrorInfo(
                .badRequest,
                "'\(field)' is too long (\(scalars.count) characters; the limit is \(maxLength))."
            )
        }
        let forbidden = scalars.first { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
        if let forbidden {
            let code = String(forbidden.value, radix: 16, uppercase: true)
            throw IPCErrorInfo(
                .badRequest,
                "'\(field)' must be a single line without control characters (found U+\(code))."
            )
        }
    }

    private static func validateDate(_ date: Date, field: String) throws(IPCErrorInfo) {
        let seconds = date.timeIntervalSince1970
        // Year 1970 through year ~5138: generous, but rules out garbage like 1e300.
        guard seconds.isFinite, seconds >= 0, seconds < 1e11 else {
            throw IPCErrorInfo(.badRequest, "'\(field)' is not a sensible date.")
        }
    }

    private static func truncated(_ value: String) -> String {
        let limit = 40
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.prefix(limit).map { scalar in
            scalar.properties.generalCategory == .control ? "?" : scalar
        }))
        return value.unicodeScalars.count > limit ? filtered + "…" : filtered
    }
}

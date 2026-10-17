import Foundation

/// A live activity: one thing the notch can show.
///
/// Activities are plain values. Every source — built-in features, the CLI,
/// plugins and AI agents — describes what it wants shown with this type and
/// hands it to the activity engine, which decides what is actually visible.
public struct Activity: Identifiable, Codable, Sendable, Equatable {
    /// Stable identity. Starting an activity with an existing ID updates it in place.
    public var id: ActivityID
    /// Who owns this activity, e.g. `system.battery`, `cli`, or a plugin's bundle ID.
    public var source: String
    public var priority: ActivityPriority
    public var title: String
    public var subtitle: String?
    /// SF Symbol name shown on the leading side of the compact island.
    public var symbol: String?
    /// Determinate progress in `0...1`. `nil` means no progress indicator.
    public var progress: Double? {
        didSet { progress = progress.map(Self.clamp) }
    }

    public var tint: ActivityTint
    /// When set, the engine ends the activity automatically at this time.
    public var expiresAt: Date?

    public init(
        id: ActivityID,
        source: String,
        priority: ActivityPriority = .normal,
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        progress: Double? = nil,
        tint: ActivityTint = .accent,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.priority = priority
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.progress = progress.map(Self.clamp)
        self.tint = tint
        self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActivityID.self, forKey: .id)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        priority = try container.decodeIfPresent(ActivityPriority.self, forKey: .priority) ?? .normal
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress).map(Self.clamp)
        tint = try container.decodeIfPresent(ActivityTint.self, forKey: .tint) ?? .accent
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Identity of an activity, unique across all sources.
public struct ActivityID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

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

/// How strongly an activity competes for the notch. Higher wins.
///
/// Encoded as a plain integer so clients can use values between the named levels.
public struct ActivityPriority: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Ambient information, e.g. a long-running download.
    public static let low = ActivityPriority(rawValue: 100)
    /// The default for most activities, e.g. music or a timer.
    public static let normal = ActivityPriority(rawValue: 200)
    /// Things the user is waiting on, e.g. a finished build or an agent needing approval.
    public static let high = ActivityPriority(rawValue: 300)
    /// Brief, direct feedback to user input, e.g. a volume HUD. Should always expire.
    public static let critical = ActivityPriority(rawValue: 400)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            rawValue = value
            return
        }
        switch try container.decode(String.self) {
        case "low": self = .low
        case "normal": self = .normal
        case "high": self = .high
        case "critical": self = .critical
        case let other:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown priority '\(other)'. Use low, normal, high, critical or an integer."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Named colors, so the host keeps control of the palette in light, dark and glass modes.
public enum ActivityTint: String, Codable, Sendable, CaseIterable {
    case accent, green, yellow, orange, red, blue, purple, pink, gray
}

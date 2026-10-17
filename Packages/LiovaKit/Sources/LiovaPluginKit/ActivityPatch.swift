import Foundation

/// A partial update to a live activity.
///
/// Fields left `nil` keep their current value. To remove an optional field (for example to
/// hide the progress bar), name it in ``clear``. On the wire a patch looks like
/// `{"id":"build","progress":0.5}` or `{"id":"build","clear":["progress"]}`; an explicit JSON
/// `null` for a clearable field (`{"id":"build","progress":null}`) means the same as clearing it.
///
/// `source` can't be patched: ownership of an activity never changes.
public struct ActivityPatch: Codable, Sendable, Equatable {
    /// The optional activity fields a patch can remove.
    public enum Field: String, Codable, Sendable, CaseIterable, Comparable {
        case subtitle, symbol, progress, expiresAt

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The activity to change.
    public var id: ActivityID
    public var title: String?
    public var subtitle: String?
    public var symbol: String?
    /// New progress in `0...1`; out-of-range values are clamped when applied.
    public var progress: Double?
    public var tint: ActivityTint?
    public var priority: ActivityPriority?
    public var expiresAt: Date?
    /// Optional fields to remove. Setting and clearing the same field is a validation error.
    public var clear: Set<Field>

    public init(
        id: ActivityID,
        title: String? = nil,
        subtitle: String? = nil,
        symbol: String? = nil,
        progress: Double? = nil,
        tint: ActivityTint? = nil,
        priority: ActivityPriority? = nil,
        expiresAt: Date? = nil,
        clear: Set<Field> = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.progress = progress
        self.tint = tint
        self.priority = priority
        self.expiresAt = expiresAt
        self.clear = clear
    }

    /// True when the patch sets or clears nothing.
    public var isEmpty: Bool {
        title == nil && subtitle == nil && symbol == nil && progress == nil && tint == nil
            && priority == nil && expiresAt == nil && clear.isEmpty
    }

    /// Fields that are both set and cleared. Validation rejects a patch where this is non-empty.
    public var conflictingFields: Set<Field> {
        var set: Set<Field> = []
        if subtitle != nil {
            set.insert(.subtitle)
        }
        if symbol != nil {
            set.insert(.symbol)
        }
        if progress != nil {
            set.insert(.progress)
        }
        if expiresAt != nil {
            set.insert(.expiresAt)
        }
        return set.intersection(clear)
    }

    /// Returns `activity` with this patch applied. The activity's ID and source are kept.
    ///
    /// Values are set first, then ``clear`` is applied, so a (rejected-by-validation)
    /// conflicting patch would end with the field cleared.
    public func applied(to activity: Activity) -> Activity {
        var result = activity
        setValues(on: &result)
        for field in clear {
            Self.remove(field, from: &result)
        }
        return result
    }

    private func setValues(on activity: inout Activity) {
        activity.title = title ?? activity.title
        activity.subtitle = subtitle ?? activity.subtitle
        activity.symbol = symbol ?? activity.symbol
        activity.progress = progress ?? activity.progress
        activity.tint = tint ?? activity.tint
        activity.priority = priority ?? activity.priority
        activity.expiresAt = expiresAt ?? activity.expiresAt
    }

    private static func remove(_ field: Field, from activity: inout Activity) {
        switch field {
        case .subtitle: activity.subtitle = nil
        case .symbol: activity.symbol = nil
        case .progress: activity.progress = nil
        case .expiresAt: activity.expiresAt = nil
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, symbol, progress, tint, priority, expiresAt, clear
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActivityID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        tint = try container.decodeIfPresent(ActivityTint.self, forKey: .tint)
        priority = try container.decodeIfPresent(ActivityPriority.self, forKey: .priority)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)

        var clear: Set<Field> = []
        if container.contains(.clear) {
            var list = try container.nestedUnkeyedContainer(forKey: .clear)
            while !list.isAtEnd {
                let name = try list.decode(String.self)
                guard let field = Field(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(
                        in: list,
                        debugDescription: "Can't clear '\(name)'. Clearable fields: "
                            + Field.allCases.map(\.rawValue).joined(separator: ", ") + "."
                    )
                }
                clear.insert(field)
            }
        }
        // An explicit JSON null on a clearable field means "remove it", like JSON Merge Patch.
        for field in Field.allCases {
            let key = Self.codingKey(for: field)
            if container.contains(key), try container.decodeNil(forKey: key) {
                clear.insert(field)
            }
        }
        for key in [CodingKeys.title, .tint, .priority] where container.contains(key) {
            if try container.decodeNil(forKey: key) {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "'\(key.stringValue)' can't be null or cleared."
                )
            }
        }
        self.clear = clear
    }

    private static func codingKey(for field: Field) -> CodingKeys {
        switch field {
        case .subtitle: .subtitle
        case .symbol: .symbol
        case .progress: .progress
        case .expiresAt: .expiresAt
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(tint, forKey: .tint)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        if !clear.isEmpty {
            try container.encode(clear.sorted().map(\.rawValue), forKey: .clear)
        }
    }
}

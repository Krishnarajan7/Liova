import Foundation

/// Connected headphones: a Bluetooth pair (AirPods, Beats, or anything else that plays
/// audio) with whatever battery and noise-control details macOS knows about it, or wired
/// ones (USB-C EarPods, a USB headset, or the headphone jack), which report neither.
public struct HeadphonesState: Equatable, Sendable, Identifiable {
    /// The Bluetooth address or Core Audio device UID, stable across connections.
    public var id: String
    public var name: String
    public var kind: Kind
    public var battery: Battery
    /// The current noise-control mode, when the headphones have one (AirPods Pro, AirPods
    /// Max, AirPods 4 with ANC, some Beats).
    public var listeningMode: ListeningMode?
    /// The modes this pair can switch to. Empty when it has no noise control.
    public var availableModes: [ListeningMode]
    /// Plugged in by cable, so there's no battery to report.
    public var isWired: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        battery: Battery = Battery(),
        listeningMode: ListeningMode? = nil,
        availableModes: [ListeningMode] = [],
        isWired: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.battery = battery
        self.listeningMode = listeningMode
        self.availableModes = availableModes
        self.isWired = isWired
    }

    public enum Kind: String, Sendable {
        case airPods
        case airPodsPro
        case airPodsMax
        case beats
        case earPods
        case other

        /// An SF Symbol for this kind.
        public var symbol: String {
            switch self {
            case .airPods: "airpods"
            case .airPodsPro: "airpodspro"
            case .airPodsMax: "airpodsmax"
            case .beats: "beats.headphones"
            case .earPods: "earpods"
            case .other: "headphones"
            }
        }
    }

    /// Percentages, 0…100. Nil when the headphones don't report that part.
    public struct Battery: Equatable, Sendable {
        public var left: Int?
        public var right: Int?
        public var caseLevel: Int?
        /// One level for the whole device (over-ear headphones, most third-party buds).
        public var single: Int?

        public init(left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil, single: Int? = nil) {
            self.left = left
            self.right = right
            self.caseLevel = caseLevel
            self.single = single
        }

        /// The level that runs out first: the lower bud, or the single level. Ignores the case,
        /// which can't stop the music.
        public var lowest: Int? {
            [left, right, single].compactMap(\.self).min()
        }

        public var isEmpty: Bool {
            left == nil && right == nil && caseLevel == nil && single == nil
        }
    }

    /// Noise control. Raw values are what macOS uses for `listeningMode`.
    public enum ListeningMode: Int, Sendable, CaseIterable {
        case off = 1
        case noiseCancellation = 2
        case transparency = 3
        case adaptive = 4

        public var title: String {
            switch self {
            case .off: "Off"
            case .noiseCancellation: "Noise Cancellation"
            case .transparency: "Transparency"
            case .adaptive: "Adaptive"
            }
        }

        public var shortTitle: String {
            switch self {
            case .off: "Off"
            case .noiseCancellation: "Noise"
            case .transparency: "Transparency"
            case .adaptive: "Adaptive"
            }
        }

        public var symbol: String {
            switch self {
            case .off: "person.fill"
            case .noiseCancellation: "person.wave.2.fill"
            case .transparency: "person.2.wave.2.fill"
            case .adaptive: "sparkles"
            }
        }
    }
}

/// Reads the raw values IOBluetooth exposes into a `HeadphonesState`. Pure, so it's tested
/// without hardware.
public enum HeadphonesReading {
    /// Bluetooth product IDs of Apple and Beats headphones, as documented by open-source
    /// AirPods tools. Only picks the icon; unknown or newer IDs fall back to the device name.
    static let kindsByProductID: [Int: HeadphonesState.Kind] = [
        0x2002: .airPods, 0x200F: .airPods, 0x2013: .airPods, 0x2019: .airPods, 0x201B: .airPods,
        0x200E: .airPodsPro, 0x2014: .airPodsPro, 0x2024: .airPodsPro,
        0x200A: .airPodsMax, 0x201F: .airPodsMax,
        0x2003: .beats, 0x2005: .beats, 0x2006: .beats, 0x2009: .beats, 0x200B: .beats, 0x200C: .beats,
        0x200D: .beats, 0x2010: .beats, 0x2011: .beats, 0x2012: .beats, 0x2016: .beats, 0x2017: .beats,
    ]

    public static func kind(productID: Int?, isApple: Bool, name: String) -> HeadphonesState.Kind {
        if let productID, let kind = kindsByProductID[productID] {
            return kind
        }
        // Unknown or new product IDs: fall back to the name the user sees.
        let lowered = name.lowercased()
        if lowered.contains("airpods max") {
            return .airPodsMax
        }
        if lowered.contains("airpods pro") {
            return .airPodsPro
        }
        if lowered.contains("airpods") {
            return .airPods
        }
        if isApple, lowered.contains("beats") {
            return .beats
        }
        return .other
    }

    /// macOS reports 0 for "unknown"; a real reading is 1…100.
    public static func level(_ raw: Int?) -> Int? {
        guard let raw, (1 ... 100).contains(raw) else { return nil }
        return raw
    }

    public static func battery(left: Int?, right: Int?, caseLevel: Int?, single: Int?, combined: Int?)
        -> HeadphonesState.Battery
    {
        let left = level(left)
        let right = level(right)
        // Some headphones report only a combined level; treat it as the single one.
        let single = level(single) ?? ((left == nil && right == nil) ? level(combined) : nil)
        return .init(left: left, right: right, caseLevel: level(caseLevel), single: single)
    }

    /// The modes to offer. Adaptive has no "supported" flag macOS exposes, so it's offered only
    /// once the headphones report being in it (switched there from the headphones or iPhone).
    public static func modes(
        current: Int?,
        noiseCancellation: Bool,
        transparency: Bool
    ) -> (current: HeadphonesState.ListeningMode?, available: [HeadphonesState.ListeningMode]) {
        guard noiseCancellation || transparency else { return (nil, []) }
        let current = current.flatMap(HeadphonesState.ListeningMode.init(rawValue:))
        var available: [HeadphonesState.ListeningMode] = [.off]
        if noiseCancellation {
            available.append(.noiseCancellation)
        }
        if transparency {
            available.append(.transparency)
        }
        if current == .adaptive {
            available.append(.adaptive)
        }
        return (current, available)
    }
}

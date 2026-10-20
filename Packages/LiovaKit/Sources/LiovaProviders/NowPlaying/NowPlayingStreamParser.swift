import Foundation

/// Turns the adapter's `stream` output into `NowPlayingInfo` values.
///
/// Each line is `{"type":"data","diff":Bool,"payload":{...}}`. A full payload replaces the
/// state; a diff is merged into it, where a key set to `null` means the key was removed.
/// An empty payload means nothing is playing. Pure and synchronous, so it's unit-tested.
///
/// Artwork (often megabytes of base64) is decoded once, when it arrives, and kept apart from
/// the other state; later lines share the same bytes, so comparing infos stays cheap.
public struct NowPlayingStreamParser: Sendable {
    private var state: [String: JSONValue] = [:]
    private var artwork: Data?
    private static let artworkKey = "artworkData"

    public init() {}

    public enum Output: Equatable, Sendable {
        /// The line changed nothing we track.
        case unchanged
        case info(NowPlayingInfo?)
    }

    public enum ParseError: Error, Equatable {
        case notJSON
        case unexpectedShape
    }

    /// Feeds one line. Returns the new state, or `.unchanged` for lines we ignore.
    public mutating func consume(_ line: Data) throws(ParseError) -> Output {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let message = object as? [String: Any]
        else { throw .notJSON }
        guard (message["type"] as? String) == "data" else { return .unchanged }
        guard let payload = message["payload"] as? [String: Any] else { throw .unexpectedShape }

        let isDiff = message["diff"] as? Bool ?? false
        if !isDiff {
            state.removeAll()
            artwork = nil
        }
        for (key, value) in payload {
            if key == Self.artworkKey {
                artwork = (value as? String).flatMap { Data(base64Encoded: $0) }
            } else if value is NSNull {
                state[key] = nil
            } else if let converted = JSONValue(value) {
                state[key] = converted
            }
        }
        return .info(Self.info(from: state, artwork: artwork))
    }

    static func info(from state: [String: JSONValue], artwork: Data?) -> NowPlayingInfo? {
        guard case let .string(bundle)? = state["bundleIdentifier"],
              case let .string(title)? = state["title"], !title.isEmpty
        else { return nil }

        let isPlaying = state["playing"]?.bool ?? false
        return NowPlayingInfo(
            bundleIdentifier: bundle,
            parentBundleIdentifier: state["parentApplicationBundleIdentifier"]?.string,
            title: title,
            artist: state["artist"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            album: state["album"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            duration: state["duration"]?.number.flatMap { $0 > 0 ? $0 : nil },
            elapsedTime: state["elapsedTime"]?.number,
            timestamp: state["timestamp"]?.string.flatMap(Self.parseDate),
            playbackRate: state["playbackRate"]?.number ?? (isPlaying ? 1 : 0),
            isPlaying: isPlaying,
            artworkData: artwork
        )
    }

    private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDate = Date.ISO8601FormatStyle()

    private static func parseDate(_ string: String) -> Date? {
        (try? fractionalDate.parse(string)) ?? (try? wholeSecondDate.parse(string))
    }
}

/// The JSON values the adapter emits, kept Sendable.
enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init?(_ value: Any) {
        switch value {
        case let number as NSNumber:
            // JSONSerialization encodes booleans as NSNumber; tell them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        default:
            return nil
        }
    }

    var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    var number: Double? {
        if case let .number(value) = self {
            value
        } else {
            nil
        }
    }

    var bool: Bool? {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        case .string: nil
        }
    }
}

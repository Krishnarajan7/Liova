import Foundation

/// Lyrics with a start time for each line.
public struct SyncedLyrics: Equatable, Sendable, Codable {
    public struct Line: Equatable, Sendable, Codable {
        /// Seconds from the start of the track.
        public var time: TimeInterval
        /// Empty for an instrumental break.
        public var text: String

        public init(time: TimeInterval, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// Sorted by time.
    public private(set) var lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines.sorted { $0.time < $1.time }
    }

    /// The line being sung at `time`: the last one that has started. Nil before the first.
    public func lineIndex(at time: TimeInterval) -> Int? {
        // Binary search for the first line starting after `time`.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    /// When the next line starts after `time`, if any.
    public func nextLineTime(after time: TimeInterval) -> TimeInterval? {
        let next = lineIndex(at: time).map { $0 + 1 } ?? 0
        return next < lines.count ? lines[next].time : nil
    }
}

/// Reads the LRC format: `[mm:ss.xx] text` lines.
///
/// Handles several timestamps on one line (`[00:12.00][01:30.00] chorus`), two- or three-digit
/// fractions or none, an `[offset:±ms]` tag, metadata tags (`[ar:…]`), and word-level
/// `<mm:ss.xx>` stamps from "enhanced" LRC, which are dropped. Pure, so it's unit-tested.
public enum LRCParser {
    public static func parse(_ text: String) -> SyncedLyrics? {
        var lines: [SyncedLyrics.Line] = []
        var offset: TimeInterval = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex) ..< close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if let value = tagValue(tag, named: "offset"), let milliseconds = Double(value) {
                    // A positive offset means the lyrics come sooner.
                    offset = milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let words = stripWordStamps(String(rest)).trimmingCharacters(in: .whitespaces)
            lines += times.map { .init(time: $0, text: words) }
        }
        guard !lines.isEmpty else { return nil }
        if offset != 0 {
            lines = lines.map { .init(time: max(0, $0.time - offset), text: $0.text) }
        }
        return SyncedLyrics(lines: lines)
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` (also with `:` before the fraction).
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsPart = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let seconds = Double(secondsPart), seconds >= 0, seconds < 60,
              secondsPart.first?.isNumber == true
        else { return nil }
        return TimeInterval(minutes * 60) + seconds
    }

    private static func tagValue(_ tag: Substring, named name: String) -> String? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name else {
            return nil
        }
        return parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
    }

    private static func stripWordStamps(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">"),
               timestamp(text[text.index(after: index) ..< close]) != nil
            {
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result.replacingOccurrences(of: "  ", with: " ")
    }
}

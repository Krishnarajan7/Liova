import Foundation

/// How far a Telegram download has come, from the record Telegram keeps beside it.
public struct TelegramPartialProgress: Sendable, Equatable {
    /// Bytes on disk so far: the sum of the downloaded ranges.
    public var completed: Int64
    /// The file's full size, once Telegram knows it.
    public var total: Int64?

    public init(completed: Int64, total: Int64?) {
        self.completed = completed
        self.total = total
    }

    public var isComplete: Bool {
        total.map { completed >= $0 } ?? false
    }
}

/// Reads `<name>_partial.meta`, the small record Telegram for macOS keeps beside each
/// download: the file's full size and which byte ranges have arrived.
///
/// The partial file's own size can't say this. Telegram fetches a video's last bytes first,
/// so the file is full-length from the first second, and it keeps the partial file (linked
/// to the finished one) after the download ends.
///
/// Layout, little-endian: magic `0x7BAC1487`, a checksum, the number of ranges (`UInt32`),
/// the full size (`Int64`, -1 if unknown), then that many `(offset, length)` pairs of
/// `Int64`. Telegram rewrites it in place, so bytes after the counted ranges are stale.
public enum TelegramPartialMeta {
    static let magic: UInt32 = 0x7BAC_1487
    static let headerSize = 20
    static let rangeSize = 16
    /// Far more than any real record; anything longer isn't read.
    static let maximumSize = 64 * 1024

    /// `nil` when `data` isn't a record this version understands.
    public static func parse(_ data: Data) -> TelegramPartialProgress? {
        guard data.count >= headerSize, data.count <= maximumSize else { return nil }
        return data.withUnsafeBytes { bytes -> TelegramPartialProgress? in
            guard UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == magic else {
                return nil
            }
            let count = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            let size = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: Int64.self))
            guard count <= (bytes.count - headerSize) / rangeSize, size >= -1 else { return nil }
            var ranges: [(start: Int64, end: Int64)] = []
            for index in 0 ..< count {
                let start = headerSize + index * rangeSize
                let offset = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: Int64.self))
                let length = Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 8, as: Int64.self))
                let (end, overflow) = offset.addingReportingOverflow(length)
                guard offset >= 0, length >= 0, !overflow else { return nil }
                ranges.append((offset, end))
            }
            let total: Int64? = size > 0 ? size : nil
            let completed = covered(by: ranges)
            return TelegramPartialProgress(completed: total.map { min(completed, $0) } ?? completed, total: total)
        }
    }

    /// Bytes covered by `ranges`, counting overlaps once.
    static func covered(by ranges: [(start: Int64, end: Int64)]) -> Int64 {
        var sum: Int64 = 0
        var reach: Int64 = 0
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.end > reach {
            sum += range.end - max(range.start, reach)
            reach = range.end
        }
        return sum
    }

    /// The record's path for a partial file.
    public static func path(forPartial partialPath: String) -> String {
        partialPath + ".meta"
    }

    /// Reads and parses the record at `path`. `nil` if it's missing, too long or not understood.
    static func read(atPath path: String) -> TelegramPartialProgress? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumSize + 1) else { return nil }
        return parse(data)
    }
}

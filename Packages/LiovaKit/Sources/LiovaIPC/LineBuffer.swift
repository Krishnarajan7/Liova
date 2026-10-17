import Foundation

/// Accumulates bytes from a stream and splits them into newline-terminated lines, with a cap
/// on line length. Remembers how far it has already scanned, so a long line arriving in many
/// small reads costs linear time, not quadratic.
struct LineBuffer {
    enum Next: Equatable {
        /// A complete line, without its `\n`.
        case line([UInt8])
        /// The current line is over the limit (with or without its newline yet).
        case tooLarge
        /// No complete line buffered.
        case incomplete
    }

    let maxLineBytes: Int
    private(set) var bytes: [UInt8] = []
    /// Bytes of `bytes` already known to contain no newline.
    private var scanned = 0

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    var isEmpty: Bool {
        bytes.isEmpty
    }

    mutating func append(_ chunk: UnsafeBufferPointer<UInt8>) {
        bytes.append(contentsOf: chunk)
    }

    mutating func next() -> Next {
        if let newline = bytes[scanned...].firstIndex(of: 0x0A) {
            guard newline <= maxLineBytes else { return .tooLarge }
            let line = Array(bytes[..<newline])
            bytes.removeSubrange(...newline)
            scanned = 0
            return .line(line)
        }
        scanned = bytes.count
        return bytes.count > maxLineBytes ? .tooLarge : .incomplete
    }

    /// Returns whatever is buffered (a final line without a newline) and empties the buffer.
    mutating func takeRemainder() -> [UInt8] {
        defer { removeAll() }
        return bytes
    }

    mutating func removeAll() {
        bytes.removeAll()
        scanned = 0
    }
}

/// A token bucket: `burst` requests at once, refilled at `perSecond`. Uses the monotonic clock.
struct TokenBucket {
    let burst: Double
    let perSecond: Double
    private var tokens: Double
    private var lastRefill: UInt64

    init(burst: Int, perSecond: Double, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.burst = Double(max(burst, 1))
        self.perSecond = max(perSecond, 0)
        tokens = self.burst
        lastRefill = now
    }

    /// Takes one token if available.
    mutating func take(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        let elapsed = now > lastRefill ? Double(now - lastRefill) / 1e9 : 0
        lastRefill = max(lastRefill, now)
        tokens = min(burst, tokens + elapsed * perSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

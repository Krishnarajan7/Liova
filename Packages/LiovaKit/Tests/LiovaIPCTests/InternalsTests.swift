import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

@Suite("CLI output")
struct CLIOutputTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func listKeepsServerOrderAndMarksTheShowingActivity() {
        // Display order from the server: deliberately not sorted by priority or ID.
        let activities = [
            Activity(id: "zeta", source: "ci", priority: .normal, title: "Showing"),
            Activity(id: "alpha", source: "ci", priority: .critical, title: "Second", progress: 0.5),
            Activity(
                id: "mid",
                source: "cli",
                priority: ActivityPriority(rawValue: 250),
                title: "Third",
                subtitle: "sub",
                expiresAt: now.addingTimeInterval(90)
            ),
        ]
        let lines = CLIOutput.table(activities, now: now).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("   ID"))
        #expect(lines[1].hasPrefix("*  zeta"))
        #expect(lines[2].hasPrefix("   alpha"))
        #expect(lines[3].hasPrefix("   mid"))
        #expect(lines[2].contains("critical"))
        #expect(lines[2].contains("50%"))
        #expect(lines[3].contains("250"))
        #expect(lines[3].contains("1m 30s"))
        #expect(lines[3].hasSuffix("Third - sub"))
    }

    @Test func emptyList() {
        #expect(CLIOutput.table([], now: now) == "No live activities.")
    }

    @Test func textForCommands() {
        #expect(CLIOutput.text(for: .ping, response: .success()) == "Liova is running (plugin API v1).")
        #expect(CLIOutput.text(for: .end("a"), response: .success()) == nil)
        #expect(CLIOutput.text(for: .list, response: .success(activities: [])) == "No live activities.")
    }

    @Test(arguments: [
        (0.0, "now"),
        (-5, "now"),
        (1, "1s"),
        (59.2, "1m"),
        (60, "1m"),
        (3599, "59m 59s"),
        (3600, "1h"),
        (5400, "1h 30m")
    ])
    func remainingTime(seconds: TimeInterval, expected: String) {
        #expect(CLIOutput.remaining(until: now.addingTimeInterval(seconds), now: now) == expected)
    }

    @Test func jsonIsPrettyAndDecodable() throws {
        let response = IPCResponse.failure(.notFound, "Nope")
        let text = CLIOutput.json(response)
        #expect(text.contains("\n"))
        #expect(try LiovaWire.makeDecoder().decode(IPCResponse.self, from: Data(text.utf8)) == response)
    }
}

@Suite("Line buffer and rate limiter")
struct LineBufferTests {
    private func buffer(_ text: String, max: Int = 16) -> LineBuffer {
        var buffer = LineBuffer(maxLineBytes: max)
        append(text, to: &buffer)
        return buffer
    }

    private func append(_ text: String, to buffer: inout LineBuffer) {
        Array(text.utf8).withUnsafeBufferPointer { buffer.append($0) }
    }

    /// Drains `buffer` until it reports something other than a line.
    private func drain(_ buffer: inout LineBuffer) -> [LineBuffer.Next] {
        var results: [LineBuffer.Next] = []
        while true {
            let next = buffer.next()
            results.append(next)
            guard case .line = next else { return results }
        }
    }

    private func line(_ text: String) -> LineBuffer.Next {
        .line(Array(text.utf8))
    }

    @Test func splitsLines() {
        var lines = buffer("one\ntwo\nthr")
        let drained = drain(&lines)
        #expect(drained == [line("one"), line("two"), .incomplete])
        let remainder = lines.takeRemainder()
        #expect(remainder == Array("thr".utf8))
        #expect(lines.isEmpty)
    }

    @Test func enforcesTheLimitWithAndWithoutANewline() {
        var exact = buffer(String(repeating: "a", count: 16) + "\n")
        var over = buffer(String(repeating: "a", count: 17) + "\n")
        var unterminated = buffer(String(repeating: "a", count: 17))
        let results = [exact.next(), over.next(), unterminated.next()]
        #expect(results == [line(String(repeating: "a", count: 16)), .tooLarge, .tooLarge])
    }

    @Test func resumesScanningAfterMoreData() {
        var lines = buffer("abc")
        let first = lines.next()
        append("def\nx", to: &lines)
        let second = lines.next()
        lines.removeAll()
        let third = lines.next()
        #expect([first, second, third] == [.incomplete, line("abcdef"), .incomplete])
    }

    @Test func tokenBucketAllowsABurstThenRefills() {
        var bucket = TokenBucket(burst: 2, perSecond: 10, now: 0)
        let times: [UInt64] = [
            0, 0, 0, // Burst of two, then empty.
            50_000_000, // 0.05 s: half a token.
            100_000_000, // 0.1 s: one token.
            10_000_000_000, 10_000_000_000, 10_000_000_000, // Long pause: refilled, capped at the burst.
        ]
        let results = times.map { bucket.take(now: $0) }
        #expect(results == [true, true, false, false, true, true, true, false])
    }

    @Test func tokenBucketIgnoresClockGoingBackwards() {
        var bucket = TokenBucket(burst: 1, perSecond: 1, now: 5_000_000_000)
        let results = [bucket.take(now: 5_000_000_000), bucket.take(now: 1_000_000_000)]
        #expect(results == [true, false])
    }
}

@Suite("Socket paths")
struct IPCPathsTests {
    @Test func defaultPathIsInApplicationSupport() {
        let url = IPCPaths.socketURL(environment: [:], homeDirectory: "/Users/test")
        #expect(url.path == "/Users/test/Library/Application Support/Liova/liova.sock")
    }

    @Test func environmentOverrides() {
        let url = IPCPaths.socketURL(environment: ["LIOVA_SOCKET": "/tmp/custom.sock"], homeDirectory: "/Users/test")
        #expect(url.path == "/tmp/custom.sock")
        let blank = IPCPaths.socketURL(environment: ["LIOVA_SOCKET": "  "], homeDirectory: "/Users/test")
        #expect(blank.path.hasSuffix("Liova/liova.sock"))
    }

    @Test func tildeIsExpanded() {
        let url = IPCPaths.socketURL(environment: ["LIOVA_SOCKET": "~/x.sock"])
        #expect(!url.path.contains("~"))
        #expect(url.path.hasSuffix("/x.sock"))
    }

    @Test func socketAddressLimits() throws {
        #expect(IPCPaths.maxSocketPathBytes == 103)
        _ = try UnixSocket.address(for: "/" + String(repeating: "a", count: 102))
        #expect(throws: UnixSocket.AddressError.self) {
            try UnixSocket.address(for: "/" + String(repeating: "a", count: 103))
        }
        #expect(throws: UnixSocket.AddressError.self) { try UnixSocket.address(for: "") }
    }
}

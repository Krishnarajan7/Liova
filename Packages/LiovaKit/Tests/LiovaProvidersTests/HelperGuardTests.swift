import Darwin
import Foundation
@testable import LiovaProviders
import Testing

/// Runs the real guard around a stand-in helper (a Perl one-liner) and checks that the
/// helper never outlives the process holding the lifeline.
struct HelperGuardTests {
    /// A guard running `helper`, its stdin lifeline, and the helper's pid (printed first).
    private struct Running {
        let process: Process
        let lifeline: Pipe
        let output: Pipe
        let helperPID: pid_t
    }

    private func start(helper: String) throws -> Running {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", MediaRemoteAdapterProvider.helperGuard, "--", "-e", helper]
        let lifeline = Pipe()
        let output = Pipe()
        process.standardInput = lifeline
        process.standardOutput = output
        try process.run()
        let line = try #require(readLine(from: output.fileHandleForReading))
        let pid = try #require(pid_t(line))
        return Running(process: process, lifeline: lifeline, output: output, helperPID: pid)
    }

    private func readLine(from handle: FileHandle) -> String? {
        var bytes = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard let first = byte.first else { return nil }
            if first == 0x0A {
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(first)
        }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date() + timeout
        while process.isRunning, Date() < deadline {
            usleep(10000)
        }
        return !process.isRunning
    }

    private let sleeper = #"$| = 1; print "$$\n"; sleep 30;"#

    @Test func closingTheLifelineStopsTheHelper() throws {
        let running = try start(helper: sleeper)
        #expect(isAlive(running.helperPID))
        try running.lifeline.fileHandleForWriting.close()
        #expect(waitForExit(running.process))
        // The guard reaps the helper before exiting, so it's gone, not a zombie.
        #expect(!isAlive(running.helperPID))
    }

    @Test func terminatingTheGuardStopsTheHelper() throws {
        let running = try start(helper: sleeper)
        running.process.terminate()
        #expect(waitForExit(running.process))
        #expect(!isAlive(running.helperPID))
        #expect(running.process.terminationStatus == 128 + SIGTERM)
    }

    @Test func helperExitStatusPassesThrough() throws {
        let running = try start(helper: #"$| = 1; print "$$\n"; exit 3;"#)
        #expect(waitForExit(running.process))
        #expect(running.process.terminationStatus == 3)
    }

    @Test func helperOutputReachesTheReader() throws {
        let running = try start(helper: #"$| = 1; print "$$\nhello\n"; exit 0;"#)
        #expect(readLine(from: running.output.fileHandleForReading) == "hello")
        #expect(waitForExit(running.process))
    }
}

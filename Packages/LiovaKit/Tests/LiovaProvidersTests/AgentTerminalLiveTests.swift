import AppKit
import Darwin
@testable import LiovaProviders
import Testing

/// Finds the app this test run was started from, through the real process table.
/// Run from a terminal: `LIOVA_LIVE_TESTS=1 swift test --filter AgentTerminalLiveTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_LIVE_TESTS"] == "1"))
struct AgentTerminalLiveTests {
    @Test func findsTheTerminalTheseTestsRunIn() throws {
        let terminal = try #require(AgentTerminalLocator.locate(from: getpid()))
        let app = try #require(NSRunningApplication(processIdentifier: terminal.pid))
        let name = app.localizedName ?? "?"
        print("Running in \(name) (\(terminal.bundleID ?? "no bundle ID")), tty \(terminal.tty ?? "none")")
        #expect(app.activationPolicy == .regular)
    }
}

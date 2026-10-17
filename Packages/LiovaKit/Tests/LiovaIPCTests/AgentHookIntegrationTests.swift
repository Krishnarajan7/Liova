import Darwin
import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// End to end: the hook logic against a real ``IPCServer`` on a temporary socket.
@Suite("Agent hook integration", .serialized)
struct AgentHookIntegrationTests {
    /// A server whose handler answers `agentPermission` with `decision` (or an error).
    private struct AgentServer {
        let temp = TemporarySocketDirectory()
        let server: IPCServer
        let recorder = CommandRecorder()

        init(decision: AgentDecision?, delay: Duration = .zero) throws {
            let recorder = recorder
            server = IPCServer(socketURL: temp.socketURL, handler: IPCClosureHandler { command, client in
                recorder.record(command, client)
                guard case .agentPermission = command else { return .success() }
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
                guard let decision else { return .failure(.unavailable, "Not now.") }
                return .decided(decision)
            })
            do {
                try server.start()
            } catch {
                temp.remove()
                throw error
            }
        }

        func runner(permissionTimeout: TimeInterval = 300) -> AgentHookRunner {
            AgentHookRunner(socketURL: temp.socketURL, permissionTimeout: permissionTimeout)
        }

        func tearDown() {
            server.stop()
            temp.remove()
        }
    }

    @Test(arguments: [
        (AgentDecision.allow, ClaudeCodeHookOutput.permissionDecision(.allow)),
        (.deny, ClaudeCodeHookOutput.permissionDecision(.deny)),
        (.ask, nil),
    ])
    func permissionDecisionsArePrinted(decision: AgentDecision, expected: String?) async throws {
        let running = try AgentServer(decision: decision)
        defer { running.tearDown() }
        let runner = running.runner()
        let output = try await blocking { runner.run(input: ClaudeFixtures.permissionRequest) }
        #expect(output == expected)
        guard case let .agentPermission(request)? = running.recorder.received.first else {
            Issue.record("Liova didn't receive the permission request")
            return
        }
        #expect(request.tool == "Bash")
        #expect(request.summary == "rm -rf node_modules && npm install")
        #expect(request.project == "MyApp")
    }

    @Test func serverErrorsPrintNothing() async throws {
        let running = try AgentServer(decision: nil)
        defer { running.tearDown() }
        let runner = running.runner()
        let output = try await blocking { runner.run(input: ClaudeFixtures.permissionRequest) }
        #expect(output == nil)
    }

    @Test func permissionWaitsForASlowAnswer() async throws {
        let running = try AgentServer(decision: .allow, delay: .milliseconds(700))
        defer { running.tearDown() }
        let runner = running.runner()
        let output = try await blocking { runner.run(input: ClaudeFixtures.permissionRequest) }
        #expect(output == ClaudeCodeHookOutput.permissionDecision(.allow))
    }

    @Test func eventsAreSentAndPrintNothing() async throws {
        let running = try AgentServer(decision: .allow)
        defer { running.tearDown() }
        let runner = running.runner()
        let inputs = [
            ClaudeFixtures.hook("SessionStart", #""source": "startup""#),
            ClaudeFixtures.hook("UserPromptSubmit", #""prompt": "secret prompt""#),
            ClaudeFixtures.preToolUse("Bash", #"{"command": "swift test"}"#),
            ClaudeFixtures.hook("Stop", #""stop_hook_active": false"#),
        ]
        for input in inputs {
            let output = try await blocking { runner.run(input: input) }
            #expect(output == nil)
        }
        let kinds = running.recorder.received.compactMap { command -> AgentEventKind? in
            if case let .agentEvent(event) = command {
                event.kind
            } else {
                nil
            }
        }
        #expect(kinds == [.sessionStarted, .working, .toolStarted, .finished])
        #expect(running.recorder.received.contains(.agentEvent(AgentEvent(
            agent: "claude-code", sessionID: "abc123-def456", project: "MyApp",
            kind: .toolStarted, detail: "Running `swift test`"
        ))))
    }

    @Test func eventsGiveUpWithinTheirBudgetWhenLiovaIsSlow() async throws {
        let temp = TemporarySocketDirectory()
        let server = IPCServer(socketURL: temp.socketURL, handler: IPCClosureHandler { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return .success()
        })
        try server.start()
        defer {
            server.stop()
            temp.remove()
        }
        let runner = AgentHookRunner(socketURL: temp.socketURL)
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await blocking { runner.run(input: ClaudeFixtures.hook("Stop")) }
        #expect(output == nil)
        #expect(clock.now - start < .milliseconds(450))
    }

    @Test func liovaNotRunningPrintsNothingQuickly() async throws {
        let temp = TemporarySocketDirectory()
        defer { temp.remove() }
        let runner = AgentHookRunner(socketURL: temp.socketURL)
        let clock = ContinuousClock()
        let start = clock.now
        for input in [ClaudeFixtures.permissionRequest, ClaudeFixtures.hook("Stop")] {
            let output = try await blocking { runner.run(input: input) }
            #expect(output == nil)
        }
        #expect(clock.now - start < .milliseconds(500))
    }

    @Test func ignoredAndUnreadableInputPrintsNothing() async throws {
        let running = try AgentServer(decision: .allow)
        defer { running.tearDown() }
        let runner = running.runner()
        let bypass = Data(#"""
        {"session_id":"s","permission_mode":"bypassPermissions","hook_event_name":"PermissionRequest",
         "tool_name":"Bash","tool_input":{"command":"ls"}}
        """#.utf8)
        for input in [nil, Data("garbage".utf8), bypass] {
            let output = try await blocking { runner.run(input: input) }
            #expect(output == nil)
        }
        #expect(running.recorder.received.isEmpty)
    }

    @Test func debugLoggingGoesToTheLogClosure() async throws {
        let temp = TemporarySocketDirectory()
        defer { temp.remove() }
        let lines = LockedLines()
        let runner = AgentHookRunner(socketURL: temp.socketURL, log: { lines.append($0) })
        _ = try await blocking { runner.run(input: ClaudeFixtures.hook("Stop")) }
        #expect(lines.all.contains { $0.contains("Couldn't send finished event") })
        #expect(AgentHookRunner.isDebugEnabled(["LIOVA_HOOK_DEBUG": "1"]))
        #expect(!AgentHookRunner.isDebugEnabled(["LIOVA_HOOK_DEBUG": "0"]))
        #expect(!AgentHookRunner.isDebugEnabled([:]))
    }

    // MARK: Reading stdin

    @Test func stdinIsReadToTheEnd() throws {
        let payload = Data(repeating: 0x61, count: 200_000)
        #expect(try readThroughPipe(payload, limit: AgentHookRunner.maxInputBytes) == payload)
    }

    @Test func oversizedStdinIsDrainedAndIgnored() throws {
        let payload = Data(repeating: 0x61, count: 300_000)
        #expect(try readThroughPipe(payload, limit: 100_000) == nil)
    }

    /// Writes `payload` into a pipe from another thread and reads it like a hook's stdin.
    private func readThroughPipe(_ payload: Data, limit: Int) throws -> Data? {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: payload)
            try? writer.close()
            done.signal()
        }
        let data = AgentHookInput.read(from: pipe.fileHandleForReading.fileDescriptor, limit: limit)
        // The writer finishing proves the reader drained everything (no broken pipe, no hang).
        #expect(done.wait(timeout: .now() + 5) == .success)
        return data
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var all: [String] {
        lock.withLock { lines }
    }
}

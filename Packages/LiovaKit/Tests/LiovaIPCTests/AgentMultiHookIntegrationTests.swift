import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// End to end for Codex, Gemini CLI and Cursor: the hook logic against a real ``IPCServer``.
@Suite("Agent hook integration: Codex, Gemini CLI, Cursor", .serialized)
struct AgentMultiHookIntegrationTests {
    private struct Running {
        let temp = TemporarySocketDirectory()
        let server: IPCServer
        let recorder = CommandRecorder()

        init(decision: AgentDecision) throws {
            let recorder = recorder
            server = IPCServer(socketURL: temp.socketURL, handler: IPCClosureHandler { command, client in
                recorder.record(command, client)
                guard case .agentPermission = command else { return .success() }
                return .decided(decision)
            })
            do {
                try server.start()
            } catch {
                temp.remove()
                throw error
            }
        }

        func runner(_ agent: AgentKind) -> AgentHookRunner {
            AgentHookRunner(agent: agent, socketURL: temp.socketURL)
        }

        var events: [AgentEvent] {
            recorder.received.compactMap { command in
                if case let .agentEvent(event) = command {
                    event
                } else {
                    nil
                }
            }
        }

        func tearDown() {
            server.stop()
            temp.remove()
        }
    }

    @Test(arguments: [AgentDecision.allow, .deny, .ask])
    func codexPermissionDecisionsArePrinted(decision: AgentDecision) async throws {
        let running = try Running(decision: decision)
        defer { running.tearDown() }
        let runner = running.runner(.codex)
        let output = try await blocking { runner.run(input: CodexFixtures.permissionRequest) }
        #expect(output == CodexHookAdapter().output(for: decision))
        guard case let .agentPermission(request)? = running.recorder.received.first else {
            Issue.record("Liova didn't receive the permission request")
            return
        }
        #expect(request.agent == "codex")
        #expect(request.summary == "rm -rf node_modules && npm install")
    }

    @Test func codexEventsAndNotifyPrintNothing() async throws {
        let running = try Running(decision: .allow)
        defer { running.tearDown() }
        let runner = running.runner(.codex)
        for input in [
            CodexFixtures.hook("SessionStart"),
            CodexFixtures.preToolUse("Bash", #"{"command": "swift test"}"#),
            CodexFixtures.notify,
        ] {
            let output = try await blocking { runner.run(input: input) }
            #expect(output == nil)
        }
        #expect(running.events.map(\.kind) == [.sessionStarted, .toolStarted, .finished])
        #expect(running.events.allSatisfy { $0.agent == "codex" })
    }

    @Test func geminiAndCursorEventsAreSentAndNeverAnswered() async throws {
        let running = try Running(decision: .allow)
        defer { running.tearDown() }
        let gemini = running.runner(.geminiCLI)
        let cursor = running.runner(.cursor)
        let inputs: [(AgentHookRunner, Data)] = [
            (gemini, GeminiFixtures.beforeTool("run_shell_command", #"{"command": "npm test"}"#)),
            (gemini, GeminiFixtures.permission(#"{"type": "exec", "command": "rm -rf build"}"#)),
            (cursor, CursorFixtures.preToolUse("Shell", #"{"command": "npm install"}"#)),
            (cursor, CursorFixtures.hook("stop", #""status": "completed""#)),
        ]
        for (runner, input) in inputs {
            let output = try await blocking { runner.run(input: input) }
            #expect(output == nil)
        }
        #expect(running.events.map(\.agent) == ["gemini-cli", "gemini-cli", "cursor", "cursor"])
        #expect(running.events.map(\.kind) == [.toolStarted, .waitingForUser, .toolStarted, .finished])
        #expect(!running.recorder.received.contains {
            if case .agentPermission = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func liovaNotRunningPrintsNothingQuickly() async throws {
        let temp = TemporarySocketDirectory()
        defer { temp.remove() }
        let clock = ContinuousClock()
        let start = clock.now
        let cases: [(AgentKind, Data)] = [
            (.codex, CodexFixtures.permissionRequest),
            (.codex, CodexFixtures.notify),
            (.geminiCLI, GeminiFixtures.hook("SessionStart")),
            (.cursor, CursorFixtures.hook("sessionStart")),
        ]
        for (agent, input) in cases {
            let runner = AgentHookRunner(agent: agent, socketURL: temp.socketURL)
            let output = try await blocking { runner.run(input: input) }
            #expect(output == nil)
        }
        #expect(clock.now - start < .milliseconds(500))
    }
}

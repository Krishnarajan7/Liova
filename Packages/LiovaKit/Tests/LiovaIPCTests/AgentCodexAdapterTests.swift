import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// Realistic Codex CLI hook inputs, shaped like what Codex writes on a hook's stdin.
enum CodexFixtures {
    static let common = """
    "session_id": "019a2b3c-thr", "transcript_path": "/Users/me/.codex/sessions/2026/10/18/rollout.jsonl",
    "cwd": "/Users/me/Projects/MyApp", "model": "gpt-5-codex", "permission_mode": "default"
    """

    static func hook(_ event: String, _ fields: String = "") -> Data {
        let extra = fields.isEmpty ? "" : ", \(fields)"
        return Data("{\(common), \"hook_event_name\": \"\(event)\"\(extra)}".utf8)
    }

    static func preToolUse(_ tool: String, _ input: String) -> Data {
        hook(
            "PreToolUse",
            #""turn_id": "t1", "tool_name": "\#(tool)", "tool_input": \#(input), "tool_use_id": "call_1""#
        )
    }

    static let patch = """
    *** Begin Patch
    *** Update File: Sources/App/App.swift
    @@ struct App
    -    let secret = "old-secret-value"
    +    let secret = "new-secret-value"
    *** Add File: Sources/App/New.swift
    +// brand new file content
    *** End Patch
    """

    static var patchInput: String {
        let encoded = try? JSONSerialization.data(withJSONObject: ["command": patch])
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static let permissionRequest = hook("PermissionRequest", #"""
    "turn_id": "t1", "tool_name": "Bash",
    "tool_input": {"command": "rm -rf node_modules && npm install", "description": null}
    """#)

    /// What Codex's `notify` program setting passes as its last argument.
    static let notify = Data(#"""
    {"type":"agent-turn-complete","thread-id":"019a2b3c-thr","turn-id":"t7","cwd":"/Users/me/Projects/MyApp",
     "client":"codex-tui","input-messages":["secret prompt text"],"last-assistant-message":"secret reply text"}
    """#.utf8)
}

@Suite("Codex hook adapter")
struct AgentCodexAdapterTests {
    private let adapter = CodexHookAdapter()

    private func event(_ data: Data) throws -> AgentEvent {
        guard case let .event(event) = adapter.adapt(data) else {
            Issue.record("Expected an event, got \(adapter.adapt(data))")
            throw CancellationError()
        }
        return event
    }

    private func permission(_ data: Data) throws -> AgentPermissionRequest {
        guard case let .permission(request) = adapter.adapt(data) else {
            Issue.record("Expected a permission request, got \(adapter.adapt(data))")
            throw CancellationError()
        }
        return request
    }

    @Test func lifecycleEventsMapToKinds() throws {
        let cases: [(Data, AgentEventKind)] = [
            (CodexFixtures.hook("SessionStart", #""source": "startup""#), .sessionStarted),
            (CodexFixtures.hook("UserPromptSubmit", #""turn_id": "t1", "prompt": "secret""#), .working),
            (CodexFixtures.preToolUse("Bash", #"{"command": "swift test"}"#), .toolStarted),
            (CodexFixtures.hook("PostToolUse", #""tool_name": "Bash", "tool_response": "ok""#), .toolFinished),
            (CodexFixtures.hook("Stop", #""stop_hook_active": false, "last_assistant_message": "x""#), .finished),
            (CodexFixtures.hook("SessionEnd", #""reason": "other""#), .sessionEnded),
        ]
        for (input, kind) in cases {
            let event = try event(input)
            #expect(event.kind == kind)
            #expect(event.agent == "codex")
            #expect(event.sessionID == "019a2b3c-thr")
            #expect(event.project == "MyApp")
        }
    }

    @Test(arguments: [
        ("Bash", #"{"command": "swift test --parallel"}"#, "Running `swift test --parallel`"),
        ("Bash", #"{"command": ["bash", "-lc", "make lint"]}"#, "Running `make lint`"),
        ("Bash", #"{}"#, "Running a command"),
        ("mcp__github__create_issue", #"{"title": "x"}"#, "Using github"),
        ("custom_tool", #"{}"#, "Using custom_tool"),
        (
            "apply_patch",
            #"{"command": "*** Begin Patch\n*** Delete File: a/Old.swift\n*** End Patch"}"#,
            "Editing Old.swift"
        ),
    ])
    func toolDetails(tool: String, input: String, expected: String) throws {
        #expect(try event(CodexFixtures.preToolUse(tool, input)).detail == expected)
    }

    @Test func patchesAreReducedToFileNames() throws {
        let detail = try event(CodexFixtures.preToolUse("apply_patch", CodexFixtures.patchInput)).detail
        #expect(detail == "Editing 2 files")
        let request = try permission(CodexFixtures.hook(
            "PermissionRequest",
            #""tool_name": "apply_patch", "tool_input": \#(CodexFixtures.patchInput)"#
        ))
        #expect(request.summary == "Update Sources/App/App.swift\nAdd Sources/App/New.swift")
        #expect(!request.summary.contains("secret"))
        #expect(!request.summary.contains("brand new"))
    }

    @Test func permissionRequestCarriesTheCommand() throws {
        let request = try permission(CodexFixtures.permissionRequest)
        #expect(request == AgentPermissionRequest(
            agent: "codex", sessionID: "019a2b3c-thr", project: "MyApp",
            tool: "Bash", summary: "rm -rf node_modules && npm install", timeout: 300
        ))
    }

    @Test func mcpPermissionShowsItsArguments() throws {
        let request = try permission(CodexFixtures.hook(
            "PermissionRequest",
            #""tool_name": "mcp__db__query", "tool_input": {"sql": "DROP TABLE users"}"#
        ))
        #expect(request.tool == "mcp__db__query")
        #expect(request.summary == #"{"sql":"DROP TABLE users"}"#)
    }

    @Test(arguments: ["bypassPermissions", "dontAsk"])
    func silentPermissionModesAreIgnored(mode: String) {
        let input = Data(#"""
        {"session_id":"s","cwd":"/x","permission_mode":"\#(mode)","hook_event_name":"PermissionRequest",
         "tool_name":"Bash","tool_input":{"command":"ls"}}
        """#.utf8)
        #expect(adapter.adapt(input) == .ignore(reason: "Permission mode '\(mode)' doesn't ask the user."))
    }

    @Test func promptsRepliesAndToolOutputAreNeverForwarded() throws {
        let inputs = [
            CodexFixtures.hook("UserPromptSubmit", #""prompt": "SECRET-PROMPT""#),
            CodexFixtures.hook("Stop", #""last_assistant_message": "SECRET-REPLY""#),
            CodexFixtures.hook("PostToolUse", #""tool_name": "Bash", "tool_response": "SECRET-OUTPUT""#),
            CodexFixtures.notify,
        ]
        for input in inputs {
            let encoded = try String(bytes: JSONEncoder().encode(event(input)), encoding: .utf8) ?? ""
            #expect(!encoded.contains("SECRET"))
            #expect(!encoded.lowercased().contains("secret"))
        }
    }

    @Test func notifyPayloadMeansTheTurnFinished() throws {
        #expect(try event(CodexFixtures.notify) == AgentEvent(
            agent: "codex", sessionID: "019a2b3c-thr", project: "MyApp", kind: .finished
        ))
        let old = try event(Data(#"{"type":"agent-turn-complete","turn-id":"1","cwd":"/w/Old"}"#.utf8))
        #expect(old.sessionID == "notify-Old")
        #expect(adapter.adapt(Data(#"{"type":"approval-requested"}"#.utf8))
            == .ignore(reason: "Unhandled notify type 'approval-requested'."))
    }

    @Test func subagentsStopAndMalformedInputAreIgnored() {
        let ignored = [
            CodexFixtures.hook("Stop", #""stop_hook_active": true"#),
            CodexFixtures.hook("PreToolUse", #""agent_id": "sub1", "tool_name": "Bash""#),
            CodexFixtures.hook("SubagentStart"),
            Data(#"{"hook_event_name":"Stop"}"#.utf8),
            Data("[1,2]".utf8),
            Data("not json".utf8),
            Data(#"{"session_id":"s","hook_event_name":"PermissionRequest"}"#.utf8),
        ]
        for input in ignored {
            guard case .ignore = adapter.adapt(input) else {
                Issue.record("Expected \(String(bytes: input, encoding: .utf8) ?? "?") to be ignored")
                continue
            }
        }
    }

    @Test func everyAdaptedValueValidates() throws {
        let huge = String(repeating: "x\u{202E}\u{0301}", count: 50000)
        let hugeJSON = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["command": huge]),
            encoding: .utf8
        ))
        let inputs = CodexHookAdapter.HookEvent.allCases.map { CodexFixtures.hook($0.rawValue) } + [
            CodexFixtures.preToolUse("Bash", hugeJSON),
            CodexFixtures.hook("PermissionRequest", #""tool_name": "Bash", "tool_input": \#(hugeJSON)"#),
            CodexFixtures.notify,
        ]
        for input in inputs {
            switch adapter.adapt(input) {
            case let .event(event):
                try LiovaValidation.validate(event)
                #expect(!(event.detail ?? "").unicodeScalars.contains("\u{202E}"))
            case let .permission(request):
                try LiovaValidation.validate(request)
                #expect(request.summary.utf8.count <= AgentHookFields.maxSummaryBytes)
                #expect(!request.summary.unicodeScalars.contains("\u{202E}"))
            case .ignore:
                break
            }
        }
    }

    @Test func decisionOutputMatchesCodexFormatExactly() throws {
        let allow = try #require(adapter.output(for: .allow))
        #expect(allow ==
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        let deny = try #require(adapter.output(for: .deny))
        let object = try #require(JSONSerialization.jsonObject(with: Data(deny.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: String])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(decision == ["behavior": "deny", "message": "Denied from the Liova notch."])
        #expect(adapter.output(for: .ask) == nil)
    }
}

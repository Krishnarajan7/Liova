import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// Realistic Claude Code hook inputs, shaped like what Claude Code writes on the hook's stdin.
enum ClaudeFixtures {
    static let common = """
    "session_id": "abc123-def456", "transcript_path": "/Users/me/.claude/projects/app/abc123.jsonl",
    "cwd": "/Users/me/Projects/MyApp", "permission_mode": "default"
    """

    static func hook(_ event: String, _ fields: String = "") -> Data {
        let extra = fields.isEmpty ? "" : ", \(fields)"
        return Data("{\(common), \"hook_event_name\": \"\(event)\"\(extra)}".utf8)
    }

    static func preToolUse(_ tool: String, _ input: String) -> Data {
        hook("PreToolUse", #""tool_name": "\#(tool)", "tool_input": \#(input), "tool_use_id": "toolu_01ABC""#)
    }

    static let permissionRequest = Data(#"""
    {
      "session_id": "abc123-def456",
      "transcript_path": "/Users/me/.claude/projects/app/abc123.jsonl",
      "cwd": "/Users/me/Projects/MyApp",
      "permission_mode": "default",
      "hook_event_name": "PermissionRequest",
      "tool_name": "Bash",
      "tool_input": {"command": "rm -rf node_modules && npm install", "description": "Reinstall dependencies"},
      "permission_suggestions": [
        {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
         "behavior": "allow", "destination": "localSettings"}
      ]
    }
    """#.utf8)
}

@Suite("Claude Code hook adapter")
struct AgentHookAdapterTests {
    private let adapter = ClaudeCodeHookAdapter()

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

    private func isIgnored(_ data: Data) -> Bool {
        if case .ignore = adapter.adapt(data) {
            true
        } else {
            false
        }
    }

    // MARK: Events

    @Test func lifecycleEventsMapToKinds() throws {
        let cases: [(Data, AgentEventKind)] = [
            (ClaudeFixtures.hook("SessionStart", #""source": "startup""#), .sessionStarted),
            (ClaudeFixtures.hook("SessionStart", #""source": "resume""#), .sessionStarted),
            (ClaudeFixtures.hook("UserPromptSubmit", #""prompt": "fix the bug""#), .working),
            (
                ClaudeFixtures.hook("PostToolUse", #""tool_name": "Bash", "tool_response": {"stdout": "ok"}"#),
                .toolFinished
            ),
            (ClaudeFixtures.hook("Stop", #""stop_hook_active": false, "last_assistant_message": "Done!""#), .finished),
            (ClaudeFixtures.hook("SessionEnd", #""reason": "exit""#), .sessionEnded),
        ]
        for (data, kind) in cases {
            let event = try event(data)
            #expect(event.kind == kind)
            #expect(event.agent == "claude-code")
            #expect(event.sessionID == "abc123-def456")
            #expect(event.project == "MyApp")
            #expect(event.detail == nil)
        }
    }

    @Test func promptTextAndAssistantMessagesAreNeverForwarded() throws {
        let secret = "my secret API key is sk-12345"
        let inputs = [
            ClaudeFixtures.hook("UserPromptSubmit", #""prompt": "\#(secret)""#),
            ClaudeFixtures.hook("Stop", #""stop_hook_active": false, "last_assistant_message": "\#(secret)""#),
            ClaudeFixtures.hook("PostToolUse", #""tool_name": "Read", "tool_response": {"content": "\#(secret)"}"#),
        ]
        for input in inputs {
            let action = adapter.adapt(input)
            let encoded = try String(bytes: JSONEncoder().encode(event(input)), encoding: .utf8) ?? ""
            #expect(!encoded.contains("secret"), "Leaked in \(action)")
        }
    }

    @Test(arguments: [
        ("Bash", #"{"command": "npm test"}"#, "Running `npm test`"),
        ("Bash", #"{"command": "\n\n  git status --short\nexit 0"}"#, "Running `git status --short`"),
        ("Bash", #"{}"#, "Running a command"),
        ("Edit", #"{"file_path": "/Users/me/MyApp/Sources/App.swift", "old_string": "a"}"#, "Editing App.swift"),
        ("Write", #"{"file_path": "/tmp/notes.md", "content": "secret"}"#, "Editing notes.md"),
        ("MultiEdit", #"{"file_path": "README.md", "edits": []}"#, "Editing README.md"),
        ("NotebookEdit", #"{"notebook_path": "/x/analysis.ipynb", "new_source": "x"}"#, "Editing analysis.ipynb"),
        ("Edit", #"{}"#, "Editing a file"),
        ("Read", #"{"file_path": "/Users/me/Projects/MyApp/Package.swift"}"#, "Reading Package.swift"),
        ("Grep", #"{"pattern": "TODO", "path": "."}"#, "Searching"),
        ("Glob", #"{"pattern": "**/*.swift"}"#, "Searching"),
        ("WebFetch", #"{"url": "https://example.com", "prompt": "x"}"#, "Browsing the web"),
        ("WebSearch", #"{"query": "swift testing"}"#, "Browsing the web"),
        ("Task", #"{"description": "Explore", "prompt": "secret plan"}"#, "Running a subagent"),
        ("Agent", #"{"prompt": "secret plan"}"#, "Running a subagent"),
        ("mcp__github__create_issue", #"{"title": "x"}"#, "Using github"),
        ("mcp__claude_ai_Linear__list_issues", #"{}"#, "Using claude_ai_Linear"),
        ("TodoWrite", #"{"todos": []}"#, "Using TodoWrite"),
        ("", #"{}"#, "Using a tool"),
    ])
    func toolDetails(tool: String, input: String, expected: String) throws {
        let event = try event(ClaudeFixtures.preToolUse(tool, input))
        #expect(event.kind == .toolStarted)
        #expect(event.detail == expected)
    }

    @Test func longCommandsAreTruncatedToEightyCharacters() throws {
        let command = String(repeating: "x", count: 500)
        let event = try event(ClaudeFixtures.preToolUse("Bash", #"{"command": "\#(command)"}"#))
        let detail = try #require(event.detail)
        #expect(detail == "Running `\(String(repeating: "x", count: 79))…`")
    }

    @Test func unicodeSurvivesAndIsCutOnCharacterBoundaries() throws {
        let command = "echo " + String(repeating: "👨‍👩‍👧‍👦é", count: 60)
        let event = try event(ClaudeFixtures.preToolUse("Bash", #"{"command": "\#(command)"}"#))
        let detail = try #require(event.detail)
        #expect(detail.hasPrefix("Running `echo 👨‍👩‍👧‍👦é"))
        #expect(detail.hasSuffix("…`"))
        let preview = detail.dropFirst("Running `".count).dropLast()
        #expect(preview.count == 80)
        #expect(event.project == "MyApp")
        let unicodeProject = try self.event(Data(#"""
        {"session_id":"s","cwd":"/Users/me/Projekte/Café ☕️","hook_event_name":"Stop"}
        """#.utf8))
        #expect(unicodeProject.project == "Café ☕️")
    }

    @Test func idleNotificationMeansWaitingForUser() throws {
        let event = try event(ClaudeFixtures.hook(
            "Notification",
            #""message": "Claude is waiting for your input", "notification_type": "idle_prompt""#
        ))
        #expect(event.kind == .waitingForUser)
        #expect(event.detail == "Claude is waiting for your input")
        // Older versions send no type.
        let legacy = try self.event(
            ClaudeFixtures.hook("Notification", #""message": "Claude is waiting for your input""#)
        )
        #expect(legacy.kind == .waitingForUser)
    }

    @Test func otherNotificationsAreIgnored() {
        #expect(isIgnored(ClaudeFixtures.hook(
            "Notification",
            #""message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt""#
        )))
        #expect(isIgnored(ClaudeFixtures.hook("Notification", #""message": "x", "notification_type": "auth_success""#)))
        #expect(isIgnored(ClaudeFixtures.hook("Notification", #""message": "Claude needs your permission""#)))
    }

    @Test func stopWhileStopHookActiveIsIgnored() {
        #expect(isIgnored(ClaudeFixtures.hook("Stop", #""stop_hook_active": true"#)))
        // A non-boolean flag is treated as absent.
        #expect(!isIgnored(ClaudeFixtures.hook("Stop", #""stop_hook_active": "yes""#)))
    }

    @Test func subagentEventsAreIgnoredButTheirPermissionRequestsAreNot() throws {
        let subagent = #""agent_id": "agent-7", "agent_type": "Explore""#
        #expect(isIgnored(ClaudeFixtures.hook("PreToolUse", #"\#(subagent), "tool_name": "Read", "tool_input": {}"#)))
        #expect(isIgnored(ClaudeFixtures.hook("Stop", subagent)))
        let request = try permission(ClaudeFixtures.hook(
            "PermissionRequest",
            #"\#(subagent), "tool_name": "Bash", "tool_input": {"command": "ls"}"#
        ))
        #expect(request.summary == "ls")
    }

    @Test func malformedOrIncompleteInputIsIgnored() {
        let inputs = [
            "", "null", "[]", "{", #"{"hook_event_name": "Stop"}"#,
            #"{"session_id": "", "hook_event_name": "Stop"}"#,
            #"{"session_id": 42, "hook_event_name": "Stop"}"#,
            #"{"session_id": "s", "hook_event_name": "SubagentStop"}"#,
            #"{"session_id": "s", "hook_event_name": "PreCompact"}"#,
            #"{"session_id": "s"}"#,
        ]
        for input in inputs {
            #expect(isIgnored(Data(input.utf8)), "\(input)")
        }
    }

    @Test func unknownFieldsAndMissingOptionalFieldsAreFine() throws {
        let event = try event(Data(#"""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","future_field":{"a":[1,2]}}
        """#.utf8))
        #expect(event.project == nil)
        #expect(event.detail == "Running a command")
        let root = try self.event(Data(#"{"session_id":"s","cwd":"/","hook_event_name":"Stop"}"#.utf8))
        #expect(root.project == nil)
    }

    // MARK: Permission requests

    @Test func permissionRequestWithSuggestions() throws {
        let request = try permission(ClaudeFixtures.permissionRequest)
        #expect(request == AgentPermissionRequest(
            agent: "claude-code",
            sessionID: "abc123-def456",
            project: "MyApp",
            tool: "Bash",
            summary: "rm -rf node_modules && npm install",
            timeout: 300
        ))
    }

    @Test(arguments: [
        ("Edit", #"{"file_path": "/Users/me/a.swift", "old_string": "x", "new_string": "y"}"#, "/Users/me/a.swift"),
        ("Write", #"{"file_path": "/etc/hosts", "content": "secret"}"#, "/etc/hosts"),
        ("NotebookEdit", #"{"notebook_path": "/x/n.ipynb"}"#, "/x/n.ipynb"),
        ("WebFetch", #"{"url": "https://example.com/a?b=c", "prompt": "summarize"}"#, "https://example.com/a?b=c"),
        ("WebSearch", #"{"query": "liova notch"}"#, "liova notch"),
        ("mcp__github__create_issue", #"{"title": "Bug", "repo": "a/b"}"#, #"{"repo":"a/b","title":"Bug"}"#),
        ("Bash", #"{"command": "line1\nline2\u001b[31m"}"#, "line1\nline2[31m"),
    ])
    func permissionSummaries(tool: String, input: String, expected: String) throws {
        let request = try permission(ClaudeFixtures.hook(
            "PermissionRequest",
            #""tool_name": "\#(tool)", "tool_input": \#(input)"#
        ))
        #expect(request.tool == tool)
        #expect(request.summary == expected)
    }

    @Test func hugeInputIsTruncatedToTheValidationLimits() throws {
        let huge = String(repeating: "a", count: 100_000)
        let longTool = "mcp__" + String(repeating: "s", count: 100) + "__tool"
        let request = try permission(ClaudeFixtures.hook(
            "PermissionRequest",
            #""tool_name": "\#(longTool)", "tool_input": {"command": "\#(huge)"}"#
        ))
        #expect(request.summary.count == LiovaValidation.maxSummaryLength)
        #expect(request.summary.hasSuffix("…"))
        #expect(request.tool.count == LiovaValidation.maxAgentNameLength)
        try LiovaValidation.validate(request)

        let zalgo = "a" + String(repeating: "\u{0301}", count: 50000)
        let hostile = try permission(ClaudeFixtures.hook(
            "PermissionRequest",
            #""session_id": "\#(huge)", "tool_name": "Bash", "tool_input": {"command": "\#(zalgo)"}"#
        ))
        try LiovaValidation.validate(hostile)
        let line = try LiovaWire.encodeLine(IPCRequest(command: .agentPermission(hostile)))
        #expect(line.count < LiovaWire.maxRequestLineBytes)
    }

    @Test func everyAdaptedValueValidates() throws {
        let inputs = [ClaudeFixtures.permissionRequest] + ClaudeCodeHookAdapter.HookEvent.allCases.map {
            ClaudeFixtures.hook($0.rawValue, #"""
            "tool_name": "Bash", "tool_input": {"command": "ls"}, "notification_type": "idle_prompt", "message": "Hi"
            """#)
        }
        for input in inputs {
            switch adapter.adapt(input) {
            case let .event(event): try LiovaValidation.validate(event)
            case let .permission(request): try LiovaValidation.validate(request)
            case let .ignore(reason): Issue.record("Unexpectedly ignored: \(reason)")
            }
        }
    }

    @Test(arguments: ["bypassPermissions", "dontAsk"])
    func silentPermissionModesAreIgnored(mode: String) {
        let input = Data(#"""
        {"session_id":"s","cwd":"/x","permission_mode":"\#(mode)","hook_event_name":"PermissionRequest",
         "tool_name":"Bash","tool_input":{"command":"ls"}}
        """#.utf8)
        #expect(isIgnored(input))
    }

    @Test func permissionRequestWithoutToolIsIgnored() {
        #expect(isIgnored(ClaudeFixtures.hook("PermissionRequest", #""tool_input": {"command": "ls"}"#)))
    }

    @Test func permissionTimeoutIsClampedToTheValidRange() throws {
        let short = try #require(Self.request(ClaudeCodeHookAdapter(permissionTimeout: 0.1)))
        #expect(short.timeout == 1)
        let long = try #require(Self.request(ClaudeCodeHookAdapter(permissionTimeout: 99999)))
        #expect(long.timeout == 3600)
    }

    private static func request(_ adapter: ClaudeCodeHookAdapter) -> AgentPermissionRequest? {
        if case let .permission(request) = adapter.adapt(ClaudeFixtures.permissionRequest) {
            request
        } else {
            nil
        }
    }
}

@Suite("Claude Code hook output")
struct AgentHookOutputTests {
    @Test func decisionOutputMatchesClaudeCodesFormatExactly() throws {
        #expect(ClaudeCodeHookOutput.permissionDecision(.allow)
            == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        #expect(ClaudeCodeHookOutput.permissionDecision(.deny)
            == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"#
            + #"{"behavior":"deny","message":"Denied from the Liova notch."}}}"#)
        #expect(ClaudeCodeHookOutput.permissionDecision(.ask) == nil)
        for decision in [AgentDecision.allow, .deny] {
            let text = try #require(ClaudeCodeHookOutput.permissionDecision(decision))
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let output = try #require(object["hookSpecificOutput"] as? [String: Any])
            let body = try #require(output["decision"] as? [String: Any])
            #expect(body["behavior"] as? String == decision.rawValue)
        }
    }
}

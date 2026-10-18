import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// Realistic Gemini CLI hook inputs.
enum GeminiFixtures {
    static let common = """
    "session_id": "gem-7f3a", "transcript_path": "/Users/me/.gemini/tmp/abc/chats/session.json",
    "cwd": "/Users/me/Projects/MyApp", "timestamp": "2026-10-18T09:15:02.123Z"
    """

    static func hook(_ event: String, _ fields: String = "") -> Data {
        let extra = fields.isEmpty ? "" : ", \(fields)"
        return Data("{\(common), \"hook_event_name\": \"\(event)\"\(extra)}".utf8)
    }

    static func beforeTool(_ tool: String, _ input: String, mcp: String? = nil) -> Data {
        let context = mcp.map { #", "mcp_context": \#($0)"# } ?? ""
        return hook("BeforeTool", #""tool_name": "\#(tool)", "tool_input": \#(input)\#(context)"#)
    }

    static func permission(_ details: String) -> Data {
        hook(
            "Notification",
            #""notification_type": "ToolPermission", "message": "Tool requires", "details": \#(details)"#
        )
    }
}

/// Realistic Cursor hook inputs.
enum CursorFixtures {
    static let common = """
    "conversation_id": "conv-91c2", "generation_id": "gen-1", "model": "claude-4.5-sonnet",
    "cursor_version": "2.6.0", "workspace_roots": ["/Users/me/Projects/MyApp"],
    "user_email": "me@example.com", "transcript_path": null
    """

    static func hook(_ event: String, _ fields: String = "") -> Data {
        let extra = fields.isEmpty ? "" : ", \(fields)"
        return Data("{\(common), \"hook_event_name\": \"\(event)\"\(extra)}".utf8)
    }

    static func preToolUse(_ tool: String, _ input: String) -> Data {
        hook("preToolUse", #"""
        "tool_name": "\#(tool)", "tool_input": \#(input), "tool_use_id": "abc123",
        "cwd": "/Users/me/Projects/MyApp/Sources", "agent_message": "SECRET-AGENT-MESSAGE"
        """#)
    }
}

private func adaptedEvent(_ action: AgentHookAction) throws -> AgentEvent {
    guard case let .event(event) = action else {
        Issue.record("Expected an event, got \(action)")
        throw CancellationError()
    }
    return event
}

@Suite("Gemini CLI hook adapter")
struct AgentGeminiAdapterTests {
    private let adapter = GeminiCLIHookAdapter()

    @Test func lifecycleEventsMapToKinds() throws {
        let cases: [(Data, AgentEventKind)] = [
            (GeminiFixtures.hook("SessionStart", #""source": "startup""#), .sessionStarted),
            (GeminiFixtures.hook("BeforeAgent", #""prompt": "SECRET-PROMPT""#), .working),
            (GeminiFixtures.beforeTool("run_shell_command", #"{"command": "npm test"}"#), .toolStarted),
            (
                GeminiFixtures.hook(
                    "AfterTool",
                    #""tool_name": "read_file", "tool_response": {"llmContent": "SECRET"}"#
                ),
                .toolFinished
            ),
            (
                GeminiFixtures.permission(#"{"type": "exec", "title": "Shell", "command": "ls", "rootCommand": "ls"}"#),
                .waitingForUser
            ),
            (
                GeminiFixtures.hook(
                    "AfterAgent",
                    #""prompt": "SECRET", "prompt_response": "SECRET", "stop_hook_active": false"#
                ),
                .finished
            ),
            (GeminiFixtures.hook("SessionEnd", #""reason": "exit""#), .sessionEnded),
        ]
        for (input, kind) in cases {
            let event = try adaptedEvent(adapter.adapt(input))
            #expect(event.kind == kind)
            #expect(event.agent == "gemini-cli")
            #expect(event.sessionID == "gem-7f3a")
            #expect(event.project == "MyApp")
            #expect(!(event.detail ?? "").contains("SECRET"))
        }
    }

    @Test(arguments: [
        (
            "run_shell_command",
            #"{"command": "npm run build\nnpm test", "description": "x"}"#,
            "Running `npm run build`"
        ),
        ("write_file", #"{"file_path": "/w/App.swift", "content": "SECRET"}"#, "Editing App.swift"),
        (
            "replace",
            #"{"file_path": "/w/Model.swift", "old_string": "a", "new_string": "SECRET"}"#,
            "Editing Model.swift"
        ),
        ("read_file", #"{"file_path": "/w/README.md"}"#, "Reading README.md"),
        ("read_many_files", #"{"include": ["*.swift"]}"#, "Reading files"),
        ("grep_search", #"{"pattern": "TODO"}"#, "Searching"),
        ("google_web_search", #"{"query": "swift"}"#, "Browsing the web"),
        ("invoke_agent", #"{}"#, "Running a subagent"),
        ("write_todos", #"{}"#, "Using write_todos"),
    ])
    func toolDetails(tool: String, input: String, expected: String) throws {
        #expect(try adaptedEvent(adapter.adapt(GeminiFixtures.beforeTool(tool, input))).detail == expected)
    }

    @Test func mcpToolsShowTheirServer() throws {
        let input = GeminiFixtures.beforeTool(
            "mcp_github_create_issue", #"{"title": "x"}"#,
            mcp: #"{"server_name": "github", "tool_name": "create_issue", "command": "npx"}"#
        )
        #expect(try adaptedEvent(adapter.adapt(input)).detail == "Using github")
    }

    @Test(arguments: [
        (
            #"{"type": "exec", "title": "Shell", "command": "rm -rf build", "rootCommand": "rm"}"#,
            "Approve? Running `rm -rf build`"
        ),
        (
            #"{"type": "edit", "title": "Edit", "fileName": "App.swift", "filePath": "/w/App.swift", "#
                + #""fileDiff": "SECRET-DIFF", "originalContent": "SECRET", "newContent": "SECRET"}"#,
            "Approve? Editing App.swift"
        ),
        (#"{"type": "mcp", "title": "MCP", "serverName": "github", "toolName": "x"}"#, "Approve? Using github"),
        (
            #"{"type": "info", "title": "Fetch", "prompt": "SECRET", "urls": ["https://x"]}"#,
            "Approve? Fetching from the web"
        ),
        (#"{"type": "new-kind"}"#, "Needs your approval"),
    ])
    func toolPermissionNotificationsSayWhatIsWaiting(details: String, expected: String) throws {
        let event = try adaptedEvent(adapter.adapt(GeminiFixtures.permission(details)))
        #expect(event.detail == expected)
        #expect(!(event.detail ?? "").contains("SECRET"))
    }

    @Test func ignoredInputs() {
        let ignored = [
            GeminiFixtures.hook("Notification", #""notification_type": "Other", "message": "x", "details": {}"#),
            GeminiFixtures.hook("AfterAgent", #""stop_hook_active": true"#),
            GeminiFixtures.hook("BeforeModel", #""llm_request": {}"#),
            GeminiFixtures.hook("PreCompress", #""trigger": "auto""#),
            Data(#"{"hook_event_name": "SessionStart"}"#.utf8),
            Data("garbage".utf8),
        ]
        for input in ignored {
            guard case .ignore = adapter.adapt(input) else {
                Issue.record("Expected \(String(bytes: input, encoding: .utf8) ?? "?") to be ignored")
                continue
            }
        }
    }

    @Test func neverPrintsADecision() {
        for decision in AgentDecision.allCases {
            #expect(adapter.output(for: decision) == nil)
        }
    }
}

@Suite("Cursor hook adapter")
struct AgentCursorAdapterTests {
    private let adapter = CursorHookAdapter()

    @Test func registeredEventsMapToKinds() throws {
        let cases: [(Data, AgentEventKind)] = [
            (
                CursorFixtures.hook("sessionStart", #""session_id": "conv-91c2", "is_background_agent": false"#),
                .sessionStarted
            ),
            (CursorFixtures.hook("beforeSubmitPrompt", #""prompt": "SECRET-PROMPT", "attachments": []"#), .working),
            (
                CursorFixtures.preToolUse("Shell", #"{"command": "npm install", "working_directory": "/x"}"#),
                .toolStarted
            ),
            (
                CursorFixtures.hook("postToolUse", #""tool_name": "Shell", "tool_output": "SECRET-OUTPUT""#),
                .toolFinished
            ),
            (
                CursorFixtures.hook("postToolUseFailure", #""tool_name": "Shell", "error_message": "SECRET""#),
                .toolFinished
            ),
            (CursorFixtures.hook("stop", #""status": "completed", "loop_count": 0"#), .finished),
            (CursorFixtures.hook("sessionEnd", #""reason": "completed", "duration_ms": 1000"#), .sessionEnded),
        ]
        for (input, kind) in cases {
            let event = try adaptedEvent(adapter.adapt(input))
            #expect(event.kind == kind)
            #expect(event.agent == "cursor")
            #expect(event.sessionID == "conv-91c2")
            #expect(event.project == "MyApp")
            let encoded = try String(bytes: JSONEncoder().encode(event), encoding: .utf8) ?? ""
            #expect(!encoded.contains("SECRET"))
            #expect(!encoded.contains("me@example.com"))
        }
        #expect(CursorHookAdapter.HookEvent.registered.map(\.rawValue) == CursorHooksEditor.events)
    }

    @Test(arguments: [
        ("Shell", #"{"command": "npm install"}"#, "Running `npm install`"),
        ("Read", #"{"file_path": "/w/App.swift"}"#, "Reading App.swift"),
        ("Write", #"{"file_path": "/w/App.swift", "contents": "SECRET"}"#, "Editing App.swift"),
        ("Delete", #"{"path": "/w/Old.swift"}"#, "Deleting Old.swift"),
        ("Grep", #"{"pattern": "x"}"#, "Searching"),
        ("Task", #"{"description": "x"}"#, "Running a subagent"),
        ("MCP:create_issue", #"{}"#, "Using create_issue"),
        ("Mystery", #"{}"#, "Using Mystery"),
    ])
    func toolDetails(tool: String, input: String, expected: String) throws {
        #expect(try adaptedEvent(adapter.adapt(CursorFixtures.preToolUse(tool, input))).detail == expected)
    }

    @Test func olderEventsAreUnderstood() throws {
        let shell = try adaptedEvent(adapter.adapt(CursorFixtures.hook(
            "beforeShellExecution", #""command": "git status", "cwd": "/w", "sandbox": false"#
        )))
        #expect(shell.kind == .toolStarted)
        #expect(shell.detail == "Running `git status`")
        let mcp = try adaptedEvent(adapter.adapt(CursorFixtures.hook(
            "beforeMCPExecution", #""tool_name": "q", "tool_input": "{\"sql\":\"SECRET\"}", "mcp_server_name": "db""#
        )))
        #expect(mcp.detail == "Using db")
        let edit = try adaptedEvent(adapter.adapt(CursorFixtures.hook(
            "afterFileEdit", #""file_path": "/w/a.swift", "edits": [{"old_string": "SECRET", "new_string": "SECRET"}]"#
        )))
        #expect(edit.kind == .toolFinished)
        #expect(edit.detail == nil)
    }

    @Test(arguments: [("aborted", "Stopped"), ("error", "Stopped with an error"), ("completed", nil)])
    func stopStatus(status: String, detail: String?) throws {
        let event = try adaptedEvent(adapter.adapt(CursorFixtures.hook("stop", #""status": "\#(status)""#)))
        #expect(event.detail == detail)
    }

    @Test func projectFallsBackToCwdAndSessionToSessionID() throws {
        let input = Data(#"""
        {"session_id": "s-1", "hook_event_name": "preToolUse", "cwd": "/w/Other",
         "tool_name": "Shell", "tool_input": {"command": "ls"}}
        """#.utf8)
        let event = try adaptedEvent(adapter.adapt(input))
        #expect(event.sessionID == "s-1")
        #expect(event.project == "Other")
    }

    @Test func ignoredInputs() {
        let ignored = [
            CursorFixtures.hook("beforeReadFile", #""file_path": "/w/.env", "content": "SECRET""#),
            CursorFixtures.hook("afterAgentResponse", #""text": "SECRET""#),
            CursorFixtures.hook("afterAgentThought", #""text": "SECRET""#),
            CursorFixtures.hook("subagentStart", #""subagent_id": "x""#),
            Data(#"{"hook_event_name": "stop"}"#.utf8),
            Data("{".utf8),
        ]
        for input in ignored {
            guard case .ignore = adapter.adapt(input) else {
                Issue.record("Expected \(String(bytes: input, encoding: .utf8) ?? "?") to be ignored")
                continue
            }
        }
    }

    @Test func neverPrintsADecision() {
        for decision in AgentDecision.allCases {
            #expect(adapter.output(for: decision) == nil)
        }
    }
}

@Suite("Agent kinds")
struct AgentKindTests {
    @Test func namesMatchTheAppAndTheAdapters() {
        #expect(AgentKind.allCases.map(\.rawValue) == ["claude-code", "codex", "gemini-cli", "cursor"])
        #expect(AgentKind.allCases.map(\.displayName) == ["Claude Code", "Codex", "Gemini CLI", "Cursor"])
        #expect(AgentKind.allCases.filter(\.supportsApprovals) == [.claudeCode, .codex])
        #expect(ClaudeCodeHookAdapter.agentName == AgentKind.claudeCode.rawValue)
        #expect(CodexHookAdapter.agentName == AgentKind.codex.rawValue)
        #expect(GeminiCLIHookAdapter.agentName == AgentKind.geminiCLI.rawValue)
        #expect(CursorHookAdapter.agentName == AgentKind.cursor.rawValue)
    }

    @Test func defaultSettingsLiveInTheHomeDirectory() {
        let paths = AgentKind.allCases
            .map { $0.defaultSettingsURL(homeDirectory: "/Users/me").path(percentEncoded: false) }
        #expect(paths == [
            "/Users/me/.claude/settings.json", "/Users/me/.codex/hooks.json",
            "/Users/me/.gemini/settings.json", "/Users/me/.cursor/hooks.json",
        ])
    }

    @Test func bidiAndInvisibleControlsAreStrippedInsideCharacters() {
        let text = "a\u{202E}\u{0301}b\u{200B}c\u{2066}d 👩‍💻"
        let single = AgentText.singleLine(text)
        #expect(!single.unicodeScalars.contains { $0.properties.generalCategory == .format && $0.value != 0x200D })
        #expect(single.hasSuffix("👩‍💻"))
        let verbatim = AgentText.removingControlCharacters("rm\u{202E} -rf\n/tmp")
        #expect(verbatim == "rm -rf\n/tmp")
    }
}

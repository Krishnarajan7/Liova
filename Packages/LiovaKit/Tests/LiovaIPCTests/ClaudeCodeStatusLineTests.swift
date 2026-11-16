import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

struct ClaudeCodeStatusLineTests {
    private let full = Data(#"""
    {"session_id":"abc","cwd":"/Users/me/Projects/shop","model":{"id":"x","display_name":"Opus"},
     "workspace":{"current_dir":"/Users/me/Projects/shop/api"},
     "cost":{"total_cost_usd":1.2345},
     "context_window":{"used_percentage":42.4},
     "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                    "seven_day":{"used_percentage":141.2}}}
    """#.utf8)

    @Test func readsLimitsContextCostAndModel() throws {
        let event = try #require(ClaudeCodeStatusLine.usageEvent(from: full))
        #expect(event.agent == "claude-code")
        #expect(event.sessionID == "abc")
        #expect(event.project == "api")
        #expect(event.kind == .usage)
        let usage = try #require(event.usage)
        #expect(usage.fiveHour == .init(usedPercentage: 23.5, resetsAt: 1_738_425_600))
        // Out of range is clamped, never rejected: the status line must keep working.
        #expect(usage.sevenDay == .init(usedPercentage: 100, resetsAt: nil))
        #expect(usage.contextUsedPercentage == 42.4)
        #expect(usage.costUSD == 1.2345)
        #expect(usage.model == "Opus")
        #expect(throws: Never.self) { try LiovaValidation.validate(event) }
    }

    @Test func aSessionWithoutLimitsStillReportsContext() throws {
        // API-key users and the first moments of a session have no rate_limits.
        let input = Data(#"{"session_id":"s","context_window":{"used_percentage":8},"cost":{"total_cost_usd":0}}"#.utf8)
        let usage = try #require(ClaudeCodeStatusLine.usageEvent(from: input)?.usage)
        #expect(usage.fiveHour == nil)
        #expect(usage.sevenDay == nil)
        #expect(usage.contextUsedPercentage == 8)
    }

    @Test func nothingToShowMeansNoEvent() {
        #expect(ClaudeCodeStatusLine
            .usageEvent(from: Data(#"{"session_id":"s","model":{"display_name":"Opus"}}"#.utf8)) == nil)
        #expect(ClaudeCodeStatusLine.usageEvent(from: Data(#"{"context_window":{"used_percentage":8}}"#.utf8)) == nil)
        #expect(ClaudeCodeStatusLine.usageEvent(from: Data("not json".utf8)) == nil)
        // null early in a session, and a boolean where a number belongs.
        let odd = Data(#"{"session_id":"s","context_window":{"used_percentage":null},"cost":{"total_cost_usd":true}}"#
            .utf8)
        #expect(ClaudeCodeStatusLine.usageEvent(from: odd) == nil)
    }

    @Test func theDefaultLineSaysWhatItKnows() {
        #expect(ClaudeCodeStatusLine.defaultLine(from: full) == "Opus · 42% context · 5h 24% · 7d 100%")
        #expect(ClaudeCodeStatusLine.defaultLine(from: Data(#"{"model":{"display_name":"Opus"}}"#.utf8)) == "Opus")
        #expect(ClaudeCodeStatusLine.defaultLine(from: Data("junk".utf8)).isEmpty)
    }

    // MARK: Settings

    private let liova = "/Applications/Liova.app/Contents/Helpers/liova"

    private func parse(_ text: String) throws -> OrderedJSON {
        try OrderedJSON.parse(Data(text.utf8))
    }

    @Test func installsAStatusLineWhereThereWasNone() throws {
        let root = try parse(#"{"model":"opus"}"#)
        let installed = try ClaudeCodeStatusLineEditor.installing(root, executablePath: liova)
        let command = try #require(installed["statusLine"]?["command"]?.stringValue)
        #expect(command.hasSuffix("liova hook claude-code --statusline"))
        #expect(installed["statusLine"]?["type"]?.stringValue == "command")
        #expect(installed["model"]?.stringValue == "opus")
        #expect(ClaudeCodeStatusLineEditor.isInstalled(installed))
        // Removing it leaves the file as it was.
        #expect(ClaudeCodeStatusLineEditor.uninstalling(installed) == root)
    }

    @Test func carriesTheUsersOwnStatusLineAndPutsItBack() throws {
        let own = #"jq -r '"[\(.model.display_name)] $HOME"' | sed "s/a/b/""#
        let root = OrderedJSON.object([.init("statusLine", .object([
            .init("type", .string("command")), .init("command", .string(own)), .init("padding", .number("2")),
        ]))])
        let installed = try ClaudeCodeStatusLineEditor.installing(root, executablePath: liova)
        let command = try #require(installed["statusLine"]?["command"]?.stringValue)
        #expect(ClaudeCodeStatusLineEditor.isLiovaCommand(command))
        #expect(ClaudeCodeStatusLineEditor.original(in: command) == own)
        #expect(installed["statusLine"]?["padding"] == .number("2"))
        // Installing again (a newer Liova, another path) never wraps Liova in Liova.
        let again = try ClaudeCodeStatusLineEditor.installing(installed, executablePath: "/usr/local/bin/liova")
        let newer = try #require(again["statusLine"]?["command"]?.stringValue)
        #expect(newer.contains("/usr/local/bin/liova"))
        #expect(ClaudeCodeStatusLineEditor.original(in: newer) == own)
        #expect(ClaudeCodeStatusLineEditor.uninstalling(again) == root)
    }

    @Test func leavesAnotherStatusLineAloneWhenUninstalling() throws {
        let root = try parse(#"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh"}}"#)
        #expect(!ClaudeCodeStatusLineEditor.isInstalled(root))
        #expect(ClaudeCodeStatusLineEditor.uninstalling(root) == root)
        #expect(!ClaudeCodeStatusLineEditor.isLiovaCommand("echo liova hook claude-code --statusline"))
        #expect(!ClaudeCodeStatusLineEditor.isLiovaCommand("\(liova) hook claude-code"))
    }

    @Test func refusesASettingsFileItDoesNotUnderstand() throws {
        #expect(throws: AgentSettingsShapeError.self) {
            try ClaudeCodeStatusLineEditor.installing(parse("[]"), executablePath: liova)
        }
        #expect(throws: AgentSettingsShapeError.self) {
            try ClaudeCodeStatusLineEditor.installing(parse(#"{"statusLine":"off"}"#), executablePath: liova)
        }
    }

    @Test func theCommandLineUnderstandsTheStatusLineOptions() throws {
        let encoded = Data("my line".utf8).base64EncodedString()
        guard case let .hook(options) = try CLIParser.parse(["hook", "claude-code", "--statusline", "--then", encoded])
        else {
            Issue.record("Expected a hook invocation")
            return
        }
        #expect(options.statusLine)
        #expect(options.thenCommand == "my line")
        guard case let .agents(request) = try CLIParser.parse(["agents", "usage", "claude-code", "--off"]) else {
            Issue.record("Expected an agents request")
            return
        }
        #expect(request == .usage(enabled: false, settingsPath: nil))
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(["agents", "usage", "codex"]) }
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(["hook", "codex", "--statusline"]) }
    }
}

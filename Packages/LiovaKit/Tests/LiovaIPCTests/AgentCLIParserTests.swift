import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

@Suite("CLI parsing: hook and agents")
struct AgentCLIParserTests {
    private func parse(_ line: String) throws(CLIUsageError) -> CLIInvocation {
        try CLIParser.parse(line.split(separator: " ").map(String.init))
    }

    private func usageError(_ line: String) -> CLIUsageError? {
        do {
            _ = try parse(line)
            return nil
        } catch {
            return error
        }
    }

    @Test(arguments: [
        ("hook claude-code", AgentHookOptions(agent: .claudeCode)),
        ("hook Claude-Code", AgentHookOptions(agent: .claudeCode)),
        ("hook claude-code --timeout 2m", AgentHookOptions(agent: .claudeCode, permissionTimeout: 120)),
        ("hook claude-code --timeout=45", AgentHookOptions(agent: .claudeCode, permissionTimeout: 45)),
        ("hook claude-code --socket /tmp/s.sock", AgentHookOptions(agent: .claudeCode, socketPath: "/tmp/s.sock")),
        ("--socket /tmp/s.sock hook claude-code", AgentHookOptions(agent: .claudeCode, socketPath: "/tmp/s.sock")),
    ])
    func hookCommands(line: String, expected: AgentHookOptions) throws {
        #expect(try parse(line) == .hook(expected))
    }

    @Test(arguments: [
        ("agents install claude-code", AgentsRequest.install(.claudeCode, settingsPath: nil, dryRun: false)),
        (
            "agents install claude-code --settings /tmp/x.json --dry-run",
            .install(.claudeCode, settingsPath: "/tmp/x.json", dryRun: true)
        ),
        ("agents uninstall claude-code", .uninstall(.claudeCode, settingsPath: nil, dryRun: false)),
        ("agents uninstall claude-code --dry-run", .uninstall(.claudeCode, settingsPath: nil, dryRun: true)),
        ("agents status", .status(nil, settingsPath: nil)),
        ("agents status claude-code --settings=/tmp/s.json", .status(.claudeCode, settingsPath: "/tmp/s.json")),
    ])
    func agentsCommands(line: String, expected: AgentsRequest) throws {
        #expect(try parse(line) == .agents(expected))
    }

    @Test(arguments: [
        ("agents --help", CLIHelp.agents),
        ("agents install --help", CLIHelp.agentsInstall),
        ("agents uninstall claude-code -h", CLIHelp.agentsUninstall),
        ("agents status --help", CLIHelp.agentsStatus),
        ("hook --help", CLIHelp.hook),
        ("help hook", CLIHelp.hook),
        ("help agents", CLIHelp.agents),
        ("help agents install", CLIHelp.agentsInstall),
    ])
    func help(line: String, expected: String) throws {
        #expect(try parse(line) == .showHelp(expected))
    }

    @Test(arguments: [
        ("agents", "Missing subcommand"),
        ("agents instal claude-code", "Did you mean 'install'?"),
        ("agents install", "Missing agent name. Supported: claude-code."),
        ("agents install codex", "Unknown agent 'codex'."),
        ("agents install claude-cod", "Did you mean 'claude-code'?"),
        ("agents install claude-code extra", "Unexpected argument 'extra'."),
        ("agents install claude-code --json", "has no option --json"),
        ("agents status --dry-run", "has no option --dry-run"),
        ("agents install claude-code --settings", "--settings needs a value."),
        ("hook", "Missing agent name."),
        ("hook claude-code --timeout 0", "--timeout must be a duration from 1s to 1h"),
        ("hook claude-code --timeout 2h", "--timeout must be a duration from 1s to 1h"),
        ("hook claude-code --settings /x", "has no option --settings"),
        ("activity start --title T --dry-run", "has no option --dry-run"),
        ("agnets status", "Did you mean 'agents'?"),
    ])
    func usageErrors(line: String, message: String) throws {
        let error = try #require(usageError(line))
        #expect(error.message.contains(message), "\(error.message)")
    }

    @Test(arguments: [
        (["hook", "claude-code"], true),
        (["hook"], true),
        (["hook", "bogus", "--bad"], true),
        (["--socket", "/tmp/s", "hook", "claude-code"], true),
        (["--socket=/tmp/s", "hook"], true),
        (["--json", "hook"], true),
        (["--", "hook"], true),
        (["ping"], false),
        (["agents", "install", "hook"], false),
        (["--socket", "hook"], false),
        ([], false),
    ])
    func detectsHookInvocations(arguments: [String], expected: Bool) {
        #expect(CLIParser.isHookInvocation(arguments) == expected)
    }

    @Test func mainHelpListsTheNewCommands() {
        #expect(CLIHelp.main.contains("agents install"))
        #expect(CLIHelp.main.contains("hook <agent>"))
    }
}

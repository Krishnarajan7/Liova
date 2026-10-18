import Foundation
@testable import LiovaIPC
import Testing

@Suite("Agent installers: details and diagnostics")
struct AgentInstallerDiagnosticsTests {
    @Test func cursorUninstallOfAFreshInstallKeepsAValidFile() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let installer = home.installer(.cursor)
        try installer.apply(installer.plan(.install))
        try installer.apply(installer.plan(.uninstall))
        #expect(try home.read(home.url(.cursor)) == "{\n  \"version\": 1,\n  \"hooks\": {}\n}\n")
    }

    @Test func cursorHandlersGoAfterTheUsersOwn() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        try home.write(AgentMultiInstallerTests.existing(.cursor), to: home.url(.cursor))
        let installer = home.installer(.cursor)
        try installer.apply(installer.plan(.install))
        let stop = try registeredCommands(home.json(home.url(.cursor)))["stop"]
        #expect(stop == ["./hooks/notify.sh", "\(AgentMultiInstallerTests.binary) hook cursor"])
    }

    @Test func staleHandlersUnderOtherEventsAreRemoved() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        try home.write(#"""
        {"version": 1, "hooks": {"afterAgentThought": [{"command": "/x/liova hook cursor"}, {"command": "keep.sh"}]}}
        """#, to: home.url(.cursor))
        let installer = home.installer(.cursor)
        #expect(try installer.status().problems.contains("Unexpected Liova hook under afterAgentThought."))
        let plan = try installer.plan(.install)
        #expect(plan.changes.contains(AgentHookChange(event: "afterAgentThought", kind: .removed)))
        try installer.apply(plan)
        #expect(try registeredCommands(home.json(home.url(.cursor)))["afterAgentThought"] == ["keep.sh"])
    }

    @Test func codexWarnsAboutDisabledOrInlineHooksInConfigTOML() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let config = CodexSettings.configURL(besideHooksAt: home.url(.codex))
        let installer = home.installer(.codex)
        #expect(installer.warnings().isEmpty)
        try home.write("""
        model = "gpt-5-codex"
        notify = ["say", "done"]

        [features]
        web_search = true
        hooks = false # off for now

        [[hooks.PreToolUse]]
        matcher = "^Bash$"
        """, to: config)
        let warnings = installer.warnings()
        #expect(warnings.count == 2)
        #expect(warnings[0].contains("hooks = false"))
        #expect(warnings[1].contains("inline"))
        try installer.apply(installer.plan(.install))
        #expect(try installer.status().warnings == warnings)
        #expect(try home.read(config).contains("hooks = false # off for now"))
    }

    @Test(arguments: [
        ("[features]\nhooks = true\n", 0),
        ("[features]\ncodex_hooks = false\n", 1),
        ("features.hooks = false\n", 1),
        ("[profiles.fast]\nhooks = false\n", 0),
        ("instructions = \"\"\"\n[hooks]\nhooks = false\n\"\"\"\n", 0),
        ("# [hooks]\n[\"features\"]\n\"hooks\" = false\n", 1),
    ])
    func codexConfigScan(text: String, warnings: Int) {
        #expect(CodexSettings.warnings(configTOML: text).count == warnings)
    }

    @Test func geminiWarnsWhenHooksAreTurnedOff() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        try home.write(#"{"hooksConfig": {"enabled": false, "disabled": ["liova"]}}"#, to: home.url(.geminiCLI))
        let installer = home.installer(.geminiCLI)
        try installer.apply(installer.plan(.install))
        let status = try installer.status()
        #expect(status.state == .installed)
        #expect(status.warnings.count == 2)
        let text = AgentCLIOutput.status(status, agent: .geminiCLI, settingsPath: "/x/settings.json")
        #expect(text.hasPrefix("Gemini CLI: installed (/x/settings.json)"))
        #expect(text.contains("Warning: Gemini CLI's hooks are turned off"))
    }

    @Test func statusAndReportsNameTheAgent() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        for agent in AgentMultiInstallerTests.others {
            let installer = home.installer(agent)
            let text = try AgentCLIOutput.status(installer.status(), agent: agent, settingsPath: "/p")
            #expect(text ==
                "\(agent.displayName): not installed (/p)\n  Set it up with: liova agents install \(agent.rawValue)")
            let plan = try installer.plan(.install)
            let report = AgentCLIOutput.report(for: plan, agent: agent, result: nil, dryRun: false)
            #expect(report.contains("Installed Liova's \(agent.displayName) hooks"))
        }
        let codex = try AgentCLIOutput.report(
            for: home.installer(.codex).plan(.install), agent: .codex, result: nil, dryRun: false
        )
        #expect(codex.contains("trust"))
    }

    @Test func commandsAreRecognisedPerAgent() {
        let codex = CodexSettings.editor
        #expect(codex.isLiovaCommand("'/Applications/My Apps/liova' hook codex"))
        #expect(codex.isLiovaCommand("/usr/local/bin/liova hook codex --timeout 60"))
        #expect(!codex.isLiovaCommand("/usr/local/bin/liova hook codexx"))
        #expect(!codex.isLiovaCommand("/usr/local/bin/liova hook claude-code"))
        #expect(!codex.isLiovaCommand("/usr/local/bin/notliova hook codex"))
        #expect(CursorHooksEditor().isLiovaCommand("liova hook cursor"))
        #expect(!CursorHooksEditor().isLiovaCommand("echo liova hook cursor"))
        #expect(GeminiCLISettings.editor.command(executablePath: "/a b/liova") == "'/a b/liova' hook gemini-cli")
    }
}

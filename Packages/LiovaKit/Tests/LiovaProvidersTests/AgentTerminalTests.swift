import Darwin
@testable import LiovaProviders
import Testing

struct AgentTerminalTests {
    typealias Process = AgentTerminalLocator.Process

    /// hook 500 → agent 400 (on a terminal) → shell 300 → login 200 → Terminal 100.
    private let chain: [pid_t: Process] = [
        500: Process(parent: 400, tty: nil),
        400: Process(parent: 300, tty: "/dev/ttys002"),
        300: Process(parent: 200, tty: "/dev/ttys002"),
        200: Process(parent: 100, tty: "/dev/ttys002"),
        100: Process(parent: 1, tty: nil),
    ]

    private func locate(from pid: pid_t, apps: [pid_t: String]) -> AgentTerminal? {
        AgentTerminalLocator.locate(from: pid, process: { chain[$0] }, appBundleID: { apps[$0] })
    }

    @Test func findsTheAppAndTheNearestTerminalDevice() {
        let found = locate(from: 500, apps: [100: "com.apple.Terminal"])
        #expect(found == AgentTerminal(pid: 100, bundleID: "com.apple.Terminal", tty: "/dev/ttys002"))
    }

    @Test func stopsAtTheFirstAppOnTheWayUp() {
        // An editor's terminal: the shell's parent is the editor itself.
        let found = locate(from: 500, apps: [200: "com.microsoft.VSCode", 100: "com.apple.Terminal"])
        #expect(found?.pid == 200)
        #expect(found?.bundleID == "com.microsoft.VSCode")
    }

    @Test func noAppOnTheWayUpMeansNothingToJumpTo() {
        #expect(locate(from: 500, apps: [:]) == nil) // e.g. an agent run over ssh or by launchd
        #expect(locate(from: 999, apps: [100: "com.apple.Terminal"]) == nil) // the hook already exited
    }

    @Test func aLoopInTheProcessTableEnds() {
        let loop: [pid_t: Process] = [10: Process(parent: 11, tty: nil), 11: Process(parent: 10, tty: nil)]
        #expect(AgentTerminalLocator.locate(from: 10, process: { loop[$0] }, appBundleID: { _ in nil }) == nil)
    }

    @Test func readsThisProcessFromTheKernel() {
        let own = AgentTerminalLocator.systemProcess(getpid())
        #expect(own?.parent == getppid())
        #expect(AgentTerminalLocator.ttyPath(device: UInt32.max) == nil)
    }

    @Test func onlyTerminalAndITermHaveATabScript() throws {
        let terminal = try #require(SystemAgentTerminalFocus.tabScript(
            bundleID: SystemAgentTerminalFocus.terminalApp, tty: "/dev/ttys002"
        ))
        #expect(terminal.contains("\"/dev/ttys002\""))
        #expect(SystemAgentTerminalFocus
            .tabScript(bundleID: SystemAgentTerminalFocus.iTerm, tty: "/dev/ttys014") != nil)
        #expect(SystemAgentTerminalFocus.tabScript(bundleID: "com.microsoft.VSCode", tty: "/dev/ttys002") == nil)
    }

    /// The device name goes into a script, so anything that isn't exactly one is refused.
    @Test func aDeviceNameThatIsNotOneNeverReachesAScript() {
        for bad in ["/dev/ttys002\" then\nquit", "ttys002", "/dev/../etc/passwd", "", "/dev/ttys002 "] {
            #expect(SystemAgentTerminalFocus.tabScript(bundleID: SystemAgentTerminalFocus.terminalApp, tty: bad) == nil)
        }
    }

    @Test func picksTheWindowThatNamesTheProject() {
        let titles = ["notes.md — LiovaSite", "AppCoordinator.swift — Liova", "krishv — zsh"]
        #expect(SystemAgentTerminalFocus.windowIndex(in: titles, project: "Liova") == 1)
        #expect(SystemAgentTerminalFocus.windowIndex(in: titles, project: "liovasite") == 0)
        #expect(SystemAgentTerminalFocus.windowIndex(in: titles, project: "Other") == nil)
        #expect(SystemAgentTerminalFocus.windowIndex(in: titles, project: "") == nil)
    }
}

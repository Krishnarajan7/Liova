import AppKit
import Darwin

/// Where a coding agent runs: the app whose window it's in, and its terminal device.
public struct AgentTerminal: Equatable, Sendable {
    /// The terminal or editor app (Terminal, iTerm, VS Code, Ghostty…).
    public var pid: pid_t
    public var bundleID: String?
    /// The agent's terminal device, e.g. `/dev/ttys002`, which names its tab in apps that
    /// can be asked for one.
    public var tty: String?

    public init(pid: pid_t, bundleID: String?, tty: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.tty = tty
    }
}

/// Finds the app an agent runs in by walking up from the process that reported it.
///
/// An agent's hook is a child of the agent, which is a child of a shell, which (through
/// `login`, a helper or a multiplexer) is a child of the app with the window. The first
/// ancestor that is an app with a Dock icon is that app; the first ancestor with a terminal
/// device names the tab. Only process IDs and device names are read.
public enum AgentTerminalLocator {
    /// What the walk needs to know about one process.
    public struct Process: Equatable, Sendable {
        public var parent: pid_t
        public var tty: String?

        public init(parent: pid_t, tty: String?) {
            self.parent = parent
            self.tty = tty
        }
    }

    /// Deeper than any real chain of shells; stops a loop in bad data.
    static let maxDepth = 32

    @MainActor
    public static func locate(from pid: pid_t) -> AgentTerminal? {
        locate(from: pid, process: systemProcess) { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else {
                return nil
            }
            return app.bundleIdentifier ?? ""
        }
    }

    /// The walk itself. `appBundleID` returns a bundle identifier (possibly empty) when the
    /// process is an app with windows of its own, nil otherwise.
    static func locate(
        from pid: pid_t,
        process: (pid_t) -> Process?,
        appBundleID: (pid_t) -> String?
    ) -> AgentTerminal? {
        var current = pid
        var tty: String?
        for _ in 0 ..< maxDepth {
            guard current > 1, let info = process(current) else { return nil }
            tty = tty ?? info.tty
            if let bundleID = appBundleID(current) {
                return AgentTerminal(pid: current, bundleID: bundleID.isEmpty ? nil : bundleID, tty: tty)
            }
            guard info.parent != current else { return nil }
            current = info.parent
        }
        return nil
    }

    /// A process's parent and terminal device, from the kernel. Through `sysctl`, as `ps`
    /// does, because the chain passes through `login`, which runs as root: `proc_pidinfo`
    /// refuses to describe another user's process.
    static func systemProcess(_ pid: pid_t) -> Process? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        return Process(parent: info.kp_eproc.e_ppid, tty: ttyPath(device: UInt32(bitPattern: info.kp_eproc.e_tdev)))
    }

    /// `/dev/ttys002` for a terminal device number, nil when the process has none.
    static func ttyPath(device: UInt32) -> String? {
        guard device != UInt32.max, device != 0, let name = devname(dev_t(bitPattern: device), S_IFCHR) else {
            return nil
        }
        let text = String(cString: name)
        return text.hasPrefix("tty") ? "/dev/" + text : nil
    }
}

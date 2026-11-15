import AppKit
import ApplicationServices
import os

/// Brings the window (and, where the app can be asked, the tab) an agent runs in to the front.
@MainActor
public protocol AgentTerminalFocusing: AnyObject {
    /// `project` is the folder's name, used to pick the right window by its title.
    func focus(_ terminal: AgentTerminal, project: String?)
}

/// Three steps, each a fallback for the one before:
///
/// 1. Terminal and iTerm can select the tab that owns a terminal device, through their own
///    scripting. macOS asks the user once (Automation).
/// 2. With Accessibility access (which Liova may already have for the volume keys or Hang Up),
///    the window whose title names the project is raised. Never asked for here.
/// 3. The app comes to the front, on whichever window it had last. Always works.
@MainActor
public final class SystemAgentTerminalFocus: AgentTerminalFocusing {
    nonisolated static let terminalApp = "com.apple.Terminal"
    nonisolated static let iTerm = "com.googlecode.iterm2"

    nonisolated static let log = Logger(subsystem: "app.liova.Liova", category: "agents")
    /// One script at a time, off the main thread: a first-time permission prompt waits for
    /// the user, and the notch mustn't freeze meanwhile.
    nonisolated static let queue = DispatchQueue(label: "app.liova.terminal-focus", qos: .userInitiated)

    public init() {}

    public func focus(_ terminal: AgentTerminal, project: String?) {
        guard let app = NSRunningApplication(processIdentifier: terminal.pid), !app.isTerminated,
              terminal.bundleID == nil || app.bundleIdentifier == terminal.bundleID
        else {
            Self.log.notice("The agent's terminal app is gone")
            return
        }
        guard let bundleID = terminal.bundleID, let tty = terminal.tty,
              let script = Self.tabScript(bundleID: bundleID, tty: tty)
        else {
            raiseAndActivate(app, project: project)
            return
        }
        Self.queue.async {
            let selected = Self.run(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if selected {
                        app.activate()
                    } else {
                        self.raiseAndActivate(app, project: project)
                    }
                }
            }
        }
    }

    private func raiseAndActivate(_ app: NSRunningApplication, project: String?) {
        if let project, AXIsProcessTrusted() {
            Self.raiseWindow(of: app.processIdentifier, titled: project)
        }
        app.activate()
    }

    // MARK: - Tabs, by scripting

    /// The script that selects the tab on `tty`, for the apps that have one. Nil for any
    /// other app, or a device name that isn't exactly a terminal's (it goes into the script).
    nonisolated static func tabScript(bundleID: String, tty: String) -> String? {
        guard tty.wholeMatch(of: /\/dev\/ttys?[0-9a-z]{1,6}/) != nil else { return nil }
        switch bundleID {
        case terminalApp:
            return """
            tell application id "\(terminalApp)"
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        if tty of theTab is "\(tty)" then
                            set selected tab of theWindow to theTab
                            set index of theWindow to 1
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case iTerm:
            return """
            tell application id "\(iTerm)"
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        repeat with theSession in sessions of theTab
                            if tty of theSession is "\(tty)" then
                                select theWindow
                                tell theTab to select
                                tell theSession to select
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    /// True when the script ran and found the tab.
    nonisolated static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            log.notice("Couldn't select the agent's tab (error \(number))")
            return false
        }
        return result?.booleanValue ?? false
    }

    // MARK: - Windows, by title

    /// Which of an app's window titles belongs to `project`: one that names it as a whole
    /// word ("main.swift — Liova", "Liova — zsh"), so "Liova" doesn't pick "LiovaSite".
    nonisolated static func windowIndex(in titles: [String], project: String) -> Int? {
        let wanted = project.lowercased()
        guard !wanted.isEmpty else { return nil }
        return titles.firstIndex { title in
            title.lowercased()
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
                .contains { $0 == wanted }
        }
    }

    private static func raiseWindow(of pid: pid_t, titled project: String) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }
        let titles = windows.map { window -> String in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String ?? ""
        }
        guard let index = windowIndex(in: titles, project: project) else { return }
        AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(windows[index], kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}

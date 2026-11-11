import AppKit
import CoreGraphics
import Security

@MainActor
public protocol ScreenRecordingWatching: AnyObject {
    /// `onChange` gets true while macOS's own screen recording runs.
    func start(onChange: @escaping @MainActor (Bool) -> Void)
    func stop()
    /// Stops it, as the menu bar's Stop button would.
    func stopRecording()
    /// Opens the Screenshot toolbar, where a recording starts.
    func openToolbar()
}

/// macOS's screen recording (⌘⇧5): screencaptureui runs while the toolbar is up or a
/// recording is going, and puts a Stop button in the menu bar while recording. Liova looks
/// for that button about once a second, and only while screencaptureui runs.
@MainActor
public final class SystemScreenRecording: ScreenRecordingWatching {
    private var onChange: (@MainActor (Bool) -> Void)?
    private var observers: [any NSObjectProtocol] = []
    private var timer: Timer?
    private var isRecording = false

    nonisolated static let bundleID = "com.apple.screencaptureui"

    public init() {}

    public func start(onChange: @escaping @MainActor (Bool) -> Void) {
        stop()
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.followCaptureUI() }
            })
        }
        followCaptureUI()
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        onChange = nil
        isRecording = false
    }

    /// ⌃⌘Esc is macOS's own shortcut to stop a screen recording.
    public func stopRecording() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: isDown)
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }

    public func openToolbar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
    }

    private func followCaptureUI() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if running, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !running {
            timer?.invalidate()
            timer = nil
        }
        check()
    }

    private func check() {
        let recording = Self.hasStopButton(Self.windows())
        guard recording != isRecording else { return }
        isRecording = recording
        onChange?(recording)
    }

    private static func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// The Stop button is a menu bar item (status window level) owned by screencaptureui.
    /// Window owners and levels need no screen recording permission; titles would.
    nonisolated static func hasStopButton(_ windows: [[String: Any]]) -> Bool {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return windows.contains { window in
            window[kCGWindowOwnerName as String] as? String == "screencaptureui"
                && window[kCGWindowLayer as String] as? Int == statusLevel
        }
    }
}

/// The OBS WebSocket password, in the login Keychain.
public enum OBSPassword {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.liova.obs-websocket",
            kSecAttrAccount as String: "obs",
        ]
    }

    public static func load() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ password: String?) {
        SecItemDelete(query as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

import AppKit
import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// A screen recording in progress, from OBS or macOS (⌘⇧5).
public struct Recording: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case obs, screen
    }

    public var source: Source
    public var isPaused: Bool
    /// Recorded so far, pauses left out, as of `measuredAt`.
    public var elapsed: TimeInterval
    public var measuredAt: Date

    /// When a clock started now would read `elapsed`: what a running timer counts from.
    public var clockStart: Date {
        measuredAt - elapsed
    }

    /// macOS's recording can only be stopped.
    public var canPause: Bool {
        source == .obs
    }
}

/// Screen recordings in the notch: how long, Pause and Stop, and a Record button.
///
/// OBS is reached through its WebSocket server only while OBS is open; macOS's own
/// recording is looked for only while its Screenshot tool runs.
@MainActor
@Observable
public final class RecordingFeature {
    public private(set) var recording: Recording?
    public private(set) var obs = OBSConnection.disconnected
    public private(set) var isOBSOpen = false

    public static let pageID = "record"
    nonisolated static let obsBundleID = "com.obsproject.obs-studio"

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let obsClient: any OBSControlling
    @ObservationIgnored private let screen: any ScreenRecordingWatching
    @ObservationIgnored private let password: @MainActor () -> String?
    @ObservationIgnored private let isAvailable: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var isScreenRecording = false

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        obsClient: any OBSControlling = OBSClient(),
        screen: any ScreenRecordingWatching = SystemScreenRecording(),
        password: @escaping @MainActor () -> String? = { OBSPassword.load() },
        isAvailable: @escaping @MainActor () -> Bool = { PreviewFeature.recording.isEnabled() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.obsClient = obsClient
        self.screen = screen
        self.password = password
        self.isAvailable = isAvailable
        self.now = now
    }

    public var isEnabled: Bool {
        settings.recordingControlsEnabled && isAvailable()
    }

    public func syncWithSettings() {
        guard isEnabled else {
            stop()
            return
        }
        guard !isRunning else { return }
        isRunning = true
        screen.start { [weak self] recording in self?.screenRecordingChanged(recording) }
        watchOBS()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        connectTask?.cancel()
        obsClient.disconnect()
        screen.stop()
        obs = .disconnected
        isScreenRecording = false
        update(nil)
    }

    // MARK: - Actions

    /// Stops the recording, or starts one: in OBS when it's connected, otherwise macOS's
    /// Screenshot toolbar opens to pick what to record.
    public func toggleRecording() {
        if recording != nil {
            stopRecording()
        } else if case .connected = obs {
            obsClient.send(.start)
        } else {
            screen.openToolbar()
        }
    }

    public func startOBSRecording() {
        obsClient.send(.start)
    }

    public func openScreenToolbar() {
        screen.openToolbar()
    }

    public func stopRecording() {
        switch recording?.source {
        case .obs: obsClient.send(.stop)
        case .screen: screen.stopRecording()
        case nil: break
        }
    }

    /// Pauses or resumes (OBS only). The notch changes at once; OBS confirms a moment later.
    public func togglePause() {
        guard var current = recording, current.canPause else { return }
        obsClient.send(current.isPaused ? .resume : .pause)
        let date = now()
        if !current.isPaused {
            current.elapsed += date.timeIntervalSince(current.measuredAt)
        }
        current.measuredAt = date
        current.isPaused.toggle()
        update(current)
    }

    /// Tries OBS again, after its password changed.
    public func reconnect() {
        guard isRunning, isOBSOpen else { return }
        connectOBS(attempt: 0, after: .zero)
    }

    public func openOBS() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.obsBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Sources

    private func watchOBS() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.obsBundleID else { return }
                MainActor.assumeIsolated { self?.obsOpenChanged() }
            })
        }
        obsOpenChanged()
    }

    private func obsOpenChanged() {
        isOBSOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.obsBundleID).isEmpty
        if isOBSOpen {
            // OBS starts its server a moment after it opens.
            connectOBS(attempt: 0, after: .seconds(2))
        } else {
            connectTask?.cancel()
            obsClient.disconnect()
            obsChanged(.disconnected)
        }
    }

    /// A few tries, further apart each time, while OBS finishes starting.
    private func connectOBS(attempt: Int, after delay: Duration) {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            obsClient.connect(password: password()) { [weak self] connection in
                self?.obsChanged(connection)
                if connection == .serverOff, attempt < 3, self?.isOBSOpen == true {
                    self?.connectOBS(attempt: attempt + 1, after: .seconds(2 << attempt))
                }
            }
        }
    }

    func obsChanged(_ connection: OBSConnection) {
        obs = connection
        if case let .connected(obsRecording) = connection, let obsRecording {
            update(Recording(
                source: .obs, isPaused: obsRecording.isPaused,
                elapsed: obsRecording.elapsed, measuredAt: obsRecording.measuredAt
            ))
        } else if recording?.source == .obs {
            update(screenRecording)
        }
    }

    private func screenRecordingChanged(_ isRecording: Bool) {
        isScreenRecording = isRecording
        if recording?.source != .obs {
            update(screenRecording)
        }
    }

    private var screenRecording: Recording? {
        guard isScreenRecording else { return nil }
        if let recording, recording.source == .screen {
            return recording
        }
        return Recording(source: .screen, isPaused: false, elapsed: 0, measuredAt: now())
    }

    private func update(_ new: Recording?) {
        guard new != recording else { return }
        recording = new
        if let new {
            try? engine.start(RecordingPolicy.activity(for: new))
        } else {
            engine.end(RecordingPolicy.activityID)
        }
    }
}

public enum RecordingPolicy {
    public static let source = "system.recording"
    public static let activityID: ActivityID = "system.recording.active"

    static func activity(for recording: Recording) -> Activity {
        Activity(
            id: activityID,
            source: source,
            // A recording is the one thing you must not forget is running.
            priority: .high,
            title: recording.isPaused ? "Recording paused" : "Recording",
            subtitle: recording.source == .obs ? "OBS" : "Screen recording",
            symbol: recording.isPaused ? "pause.circle.fill" : "record.circle.fill",
            tint: recording.isPaused ? .orange : .red
        )
    }
}

import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

// MARK: - Fakes (no real tap, no real volume or brightness changes)

@MainActor
final class HUDFakeVolume: SystemVolumeControlling {
    var state: VolumeState?
    var canSet = true
    private(set) var setVolumeCalls: [Double] = []
    private(set) var setMutedCalls: [Bool] = []
    private(set) var isStarted = false
    private var onChange: (@MainActor (VolumeState?) -> Void)?

    init(_ state: VolumeState?) {
        self.state = state
    }

    func setVolume(_ volume: Double) -> Bool {
        guard canSet, var state else { return false }
        setVolumeCalls.append(volume)
        state.volume = volume
        self.state = state
        return true
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard canSet, var state else { return false }
        setMutedCalls.append(muted)
        state.isMuted = muted
        self.state = state
        return true
    }

    func start(onChange: @escaping @MainActor (VolumeState?) -> Void) {
        isStarted = true
        self.onChange = onChange
        onChange(state)
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    /// A change reported by the Core Audio listener.
    func send(_ state: VolumeState?) {
        self.state = state
        onChange?(state)
    }
}

@MainActor
final class HUDFakeBrightness: DisplayBrightnessControlling {
    var level: Double?
    private(set) var setCalls: [Double] = []

    init(_ level: Double?) {
        self.level = level
    }

    var isAvailable: Bool {
        level != nil
    }

    func brightness() -> Double? {
        level
    }

    func setBrightness(_ value: Double) -> Bool {
        guard level != nil else { return false }
        setCalls.append(value)
        level = value
        return true
    }
}

@MainActor
final class HUDFakeKeyTap: MediaKeyTapping {
    var status: MediaKeyTapStatus = .stopped
    var isPermissionGranted: Bool
    var failure: String?
    private(set) var permissionRequests = 0
    private(set) var stopCount = 0
    private var onKey: (@MainActor (MediaKeyEvent) -> Bool)?
    private var onStatusChange: (@MainActor (MediaKeyTapStatus) -> Void)?

    init(trusted: Bool = true) {
        isPermissionGranted = trusted
    }

    func requestPermission() {
        permissionRequests += 1
    }

    func start(
        onKey: @escaping @MainActor (MediaKeyEvent) -> Bool,
        onStatusChange: @escaping @MainActor (MediaKeyTapStatus) -> Void
    ) -> MediaKeyTapStatus {
        if let failure {
            status = .failed(failure)
        } else if !isPermissionGranted {
            status = .needsPermission
        } else {
            status = .running
            self.onKey = onKey
            self.onStatusChange = onStatusChange
        }
        return status
    }

    func stop() {
        stopCount += 1
        status = .stopped
        onKey = nil
        onStatusChange = nil
    }

    var isTapInstalled: Bool {
        onKey != nil
    }

    /// Simulates a key press; returns whether the tap would swallow it.
    @discardableResult
    func press(_ key: MediaKey, fine: Bool = false) -> Bool {
        onKey?(MediaKeyEvent(key: key, isDown: true, isFineStep: fine)) ?? false
    }

    func watchdogGivesUp() {
        let callback = onStatusChange
        stop()
        status = .failed("gave up")
        callback?(status)
    }
}

// MARK: - Fixture

final class HUDTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date += seconds }
    }
}

/// One feature wired to fakes and a controllable clock. A class, so suites share it by reference.
@MainActor
final class HUDFeatureFixture {
    let clock = HUDTestClock()
    let engine: ActivityEngine
    let settings: LiovaSettings
    let volume = HUDFakeVolume(VolumeState(deviceID: 7, volume: 0.5, isMuted: false, canSetVolume: true, canMute: true))
    let brightness = HUDFakeBrightness(0.5)
    let tap = HUDFakeKeyTap()

    init() throws {
        let clock = clock
        engine = ActivityEngine(now: { clock.now })
        settings = try LiovaSettings(defaults: #require(UserDefaults(suiteName: "app.liova.tests.\(UUID())")))
    }

    func makeFeature(safeMode: Bool = false) -> HUDFeature {
        let clock = clock
        return HUDFeature(
            engine: engine,
            settings: settings,
            volume: volume,
            brightness: brightness,
            keyTap: tap,
            now: { clock.now },
            isSafeMode: safeMode
        )
    }

    /// Callers must keep the returned feature alive: the tap holds it weakly.
    func enabledFeature() -> HUDFeature {
        settings.hudReplacementEnabled = true
        let feature = makeFeature()
        feature.syncWithSettings()
        return feature
    }
}

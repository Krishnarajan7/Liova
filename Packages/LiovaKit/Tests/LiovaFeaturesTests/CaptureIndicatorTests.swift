import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaProviders
import Testing

@MainActor
final class FakeCaptureMonitor: CaptureMonitoring {
    private var onChange: (@MainActor (CaptureState) -> Void)?
    private(set) var isStarted = false

    func start(onChange: @escaping @MainActor (CaptureState) -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func send(_ state: CaptureState) {
        onChange?(state)
    }
}

@MainActor
struct CaptureIndicatorTests {
    let engine = ActivityEngine()
    let monitor = FakeCaptureMonitor()
    let settings: LiovaSettings
    let feature: CaptureIndicatorFeature

    private let scratch = ScratchDefaults()

    init() throws {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = CaptureIndicatorFeature(engine: engine, settings: settings, monitor: monitor)
    }

    @Test func cameraTurningOnFlashes() {
        feature.syncWithSettings()
        monitor.send(CaptureState(isCameraOn: true, isMicrophoneOn: false))
        #expect(engine.current?.title == "Camera on")
        #expect(engine.current?.priority == .high)
        #expect(feature.state.isCameraOn)
    }

    @Test func micAddedToCameraFlashesBoth() {
        feature.syncWithSettings()
        monitor.send(CaptureState(isCameraOn: true, isMicrophoneOn: false))
        monitor.send(CaptureState(isCameraOn: true, isMicrophoneOn: true))
        #expect(engine.current?.title == "Camera and microphone on")
    }

    @Test func turningOffDoesNotFlash() {
        let off = CapturePolicy.flash(
            from: CaptureState(isCameraOn: true, isMicrophoneOn: true), to: .off, now: Date()
        )
        #expect(off == nil)
    }

    @Test func micBlipWhenHeadsetUnpluggedDoesNotFlash() {
        let clock = HUDTestClock()
        let feature = CaptureIndicatorFeature(
            engine: engine, settings: settings, monitor: monitor, now: { clock.now }
        )
        feature.syncWithSettings()
        monitor.send(CaptureState(isCameraOn: true, isMicrophoneOn: true))
        engine.endAll(source: CapturePolicy.source)
        // The headset's mic disappears, then the call picks up the built-in one.
        clock.advance(0.5)
        monitor.send(CaptureState(isCameraOn: true, isMicrophoneOn: false))
        clock.advance(0.5)
        monitor.send(CaptureState(isCameraOn: true, isMicrophoneOn: true))
        #expect(engine.current == nil)
    }

    @Test func turningBackOnLaterFlashesAgain() {
        let start = Date(timeIntervalSince1970: 1000)
        let cameraOn = CaptureState(isCameraOn: true, isMicrophoneOn: false)
        let soon = CapturePolicy.flash(from: .off, to: cameraOn, now: start + 2, cameraOffAt: start)
        let later = CapturePolicy.flash(
            from: .off, to: cameraOn, now: start + CapturePolicy.restartGrace, cameraOffAt: start
        )
        #expect(soon == nil)
        #expect(later?.title == "Camera on")
    }

    @Test func disablingStopsAndClears() {
        feature.syncWithSettings()
        monitor.send(CaptureState(isCameraOn: false, isMicrophoneOn: true))
        settings.captureIndicatorEnabled = false
        feature.syncWithSettings()
        #expect(!monitor.isStarted)
        #expect(feature.state == .off)
        #expect(engine.current == nil)
    }
}

@MainActor
struct WelcomeTests {
    @Test func showsOnceEver() {
        let scratch = ScratchDefaults()
        let defaults = scratch.defaults
        let engine = ActivityEngine()
        let welcome = WelcomeFeature(engine: engine, settings: LiovaSettings(defaults: defaults))
        #expect(welcome.showIfNeeded())
        #expect(engine.current?.id == WelcomeFeature.activityID)
        #expect(!welcome.showIfNeeded())
        let again = WelcomeFeature(engine: ActivityEngine(), settings: LiovaSettings(defaults: defaults))
        #expect(!again.showIfNeeded())
    }
}

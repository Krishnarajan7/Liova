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

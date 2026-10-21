import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

@MainActor
final class FakeHeadphonesMonitor: HeadphonesMonitoring {
    private var onChange: (@MainActor ([HeadphonesState]) -> Void)?
    private(set) var isStarted = false
    private(set) var refreshes = 0
    private(set) var modeRequests: [(HeadphonesState.ListeningMode, String)] = []

    func start(onChange: @escaping @MainActor ([HeadphonesState]) -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func refresh() {
        refreshes += 1
    }

    func setListeningMode(_ mode: HeadphonesState.ListeningMode, for id: String) {
        modeRequests.append((mode, id))
    }

    func send(_ states: [HeadphonesState]) {
        onChange?(states)
    }
}

private func pods(
    left: Int? = 80, right: Int? = 75, caseLevel: Int? = 50,
    mode: HeadphonesState.ListeningMode? = .noiseCancellation
) -> HeadphonesState {
    HeadphonesState(
        id: "aa-bb", name: "My AirPods Pro", kind: .airPodsPro,
        battery: .init(left: left, right: right, caseLevel: caseLevel),
        listeningMode: mode, availableModes: mode == nil ? [] : [.off, .noiseCancellation, .transparency]
    )
}

private let buds = HeadphonesState(id: "cc-dd", name: "Nord Buds 3", kind: .other, battery: .init(single: 60))

struct HeadphonesReadingTests {
    @Test func zeroMeansUnknown() {
        #expect(HeadphonesReading.level(0) == nil)
        #expect(HeadphonesReading.level(101) == nil)
        #expect(HeadphonesReading.level(nil) == nil)
        #expect(HeadphonesReading.level(1) == 1)
        #expect(HeadphonesReading.level(100) == 100)
    }

    @Test func budsAndCase() {
        let battery = HeadphonesReading.battery(left: 80, right: 0, caseLevel: 40, single: 0, combined: 0)
        #expect(battery == .init(left: 80, right: nil, caseLevel: 40, single: nil))
        #expect(battery.lowest == 80)
    }

    @Test func combinedLevelStandsInForSingle() {
        let battery = HeadphonesReading.battery(left: 0, right: 0, caseLevel: 0, single: 0, combined: 55)
        #expect(battery.single == 55)
        // Not when the buds report their own levels.
        #expect(HeadphonesReading.battery(left: 70, right: 0, caseLevel: 0, single: 0, combined: 55).single == nil)
    }

    @Test func lowestIgnoresTheCase() {
        #expect(HeadphonesState.Battery(left: 50, right: 30, caseLevel: 5).lowest == 30)
        #expect(HeadphonesState.Battery(caseLevel: 5).lowest == nil)
    }

    @Test func kindFromProductIDThenName() {
        #expect(HeadphonesReading.kind(productID: 0x2014, isApple: true, name: "Pods") == .airPodsPro)
        #expect(HeadphonesReading.kind(productID: 0x200A, isApple: true, name: "Max") == .airPodsMax)
        #expect(HeadphonesReading.kind(productID: 0x9999, isApple: true, name: "My AirPods Max") == .airPodsMax)
        #expect(HeadphonesReading.kind(productID: nil, isApple: false, name: "AirPods") == .airPods)
        #expect(HeadphonesReading.kind(productID: 10, isApple: false, name: "Airdopes 148") == .other)
    }

    @Test func noNoiseControlMeansNoModes() {
        let modes = HeadphonesReading.modes(current: 0, noiseCancellation: false, transparency: false)
        #expect(modes.current == nil)
        #expect(modes.available.isEmpty)
    }

    @Test func modesFollowSupport() {
        let modes = HeadphonesReading.modes(current: 3, noiseCancellation: true, transparency: true)
        #expect(modes.current == .transparency)
        #expect(modes.available == [.off, .noiseCancellation, .transparency])
    }

    @Test func adaptiveOfferedOnceReported() {
        let modes = HeadphonesReading.modes(current: 4, noiseCancellation: true, transparency: true)
        #expect(modes.current == .adaptive)
        #expect(modes.available.last == .adaptive)
    }
}

struct HeadphonesPolicyTests {
    @Test func connectingIsReported() {
        let outcome = HeadphonesPolicy.changes(from: [], to: [pods()], alerted: [])
        #expect(outcome.connected.map(\.id) == ["aa-bb"])
        #expect(outcome.lowBattery.isEmpty)
    }

    @Test func stayingConnectedIsNotReportedAgain() {
        let outcome = HeadphonesPolicy.changes(from: [pods()], to: [pods(left: 79)], alerted: [])
        #expect(outcome.connected.isEmpty)
    }

    @Test func lowBatteryAlertsOnceWithHysteresis() {
        var alerted: Set<String> = []
        var outcome = HeadphonesPolicy.changes(from: [pods(left: 12)], to: [pods(left: 10)], alerted: alerted)
        #expect(outcome.lowBattery.count == 1)
        alerted = outcome.alerted
        // Bouncing around the threshold doesn't nag.
        outcome = HeadphonesPolicy.changes(from: [pods(left: 10)], to: [pods(left: 11)], alerted: alerted)
        alerted = outcome.alerted
        outcome = HeadphonesPolicy.changes(from: [pods(left: 11)], to: [pods(left: 9)], alerted: alerted)
        #expect(outcome.lowBattery.isEmpty)
        alerted = outcome.alerted
        // Charged past the re-arm level, then low again: alerts again.
        outcome = HeadphonesPolicy.changes(from: [pods(left: 9)], to: [pods(left: 25)], alerted: alerted)
        alerted = outcome.alerted
        #expect(alerted.isEmpty)
        outcome = HeadphonesPolicy.changes(from: [pods(left: 25)], to: [pods(left: 8)], alerted: alerted)
        #expect(outcome.lowBattery.count == 1)
    }

    @Test func connectingLowShowsInTheConnectCardNotASecondAlert() {
        let outcome = HeadphonesPolicy.changes(from: [], to: [pods(left: 5)], alerted: [])
        #expect(outcome.connected.count == 1)
        #expect(outcome.lowBattery.isEmpty)
        #expect(outcome.alerted == ["aa-bb"])
        let activity = HeadphonesPolicy.connectedActivity(for: pods(left: 5), expiresAt: .now)
        #expect(activity.tint == .red)
    }

    @Test func disconnectingForgetsTheAlert() {
        let outcome = HeadphonesPolicy.changes(from: [pods(left: 5)], to: [], alerted: ["aa-bb"])
        #expect(outcome.alerted.isEmpty)
    }

    @Test func summaries() {
        #expect(HeadphonesPolicy.batterySummary(pods().battery) == "L 80%  R 75%  Case 50%")
        #expect(HeadphonesPolicy.batterySummary(buds.battery) == "60%")
        #expect(HeadphonesPolicy.batterySummary(.init()) == nil)
    }
}

@MainActor
struct HeadphonesFeatureTests {
    let engine = ActivityEngine()
    let monitor = FakeHeadphonesMonitor()
    let settings: LiovaSettings
    let feature: HeadphonesFeature
    let clock = TestClock()

    final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let scratch = ScratchDefaults()

    init() throws {
        settings = LiovaSettings(defaults: scratch.defaults)
        let clock = clock
        feature = HeadphonesFeature(engine: engine, settings: settings, monitor: monitor, now: { clock.now })
    }

    @Test func onByDefaultAndStartsTheMonitor() {
        #expect(settings.headphonesEnabled)
        feature.syncWithSettings()
        #expect(monitor.isStarted)
    }

    @Test func connectingShowsTheHeadphones() throws {
        feature.syncWithSettings()
        monitor.send([pods()])
        let activity = try #require(engine.current)
        #expect(activity.id == HeadphonesPolicy.connectedID)
        #expect(activity.title == "My AirPods Pro")
        #expect(activity.subtitle == "L 80%  R 75%  Case 50%")
        #expect(feature.deviceIDByActivity[activity.id] == "aa-bb")
        #expect(feature.isConnected)
    }

    @Test func lateBatteryFillsInTheSameMoment() throws {
        feature.syncWithSettings()
        monitor.send([pods(left: nil, right: nil, caseLevel: nil)])
        let first = try #require(engine.current)
        #expect(first.subtitle == "Connected")
        clock.now += 1
        monitor.send([pods()])
        let second = try #require(engine.current)
        #expect(second.subtitle == "L 80%  R 75%  Case 50%")
        #expect(second.expiresAt == first.expiresAt)
    }

    @Test func lowBatteryWhileListeningAlerts() throws {
        feature.syncWithSettings()
        monitor.send([pods(left: 30)])
        clock.now += 600
        monitor.send([pods(left: 10)])
        let alert = try #require(engine.activity(HeadphonesPolicy.lowBatteryID))
        #expect(alert.priority == .high)
        #expect(alert.title == "My AirPods Pro battery low")
    }

    @Test func disconnectingEndsTheConnectMoment() {
        feature.syncWithSettings()
        monitor.send([pods()])
        monitor.send([])
        #expect(engine.activity(HeadphonesPolicy.connectedID) == nil)
        #expect(!feature.isConnected)
    }

    @Test func unpluggingShowsTheGoodbye() throws {
        let earPods = HeadphonesState(id: "wired.x", name: "EarPods", kind: .earPods, isWired: true)
        feature.syncWithSettings()
        monitor.send([earPods])
        clock.now += 30
        monitor.send([])
        let goodbye = try #require(engine.activity(HeadphonesPolicy.disconnectedID))
        #expect(goodbye.title == "EarPods")
        #expect(goodbye.subtitle == "Disconnected")
        #expect(goodbye.symbol == "earpods")
        #expect(goodbye.expiresAt == clock.now + HeadphonesPolicy.disconnectedDuration)
        #expect(feature.lastDisconnected == earPods)
        #expect(feature.deviceIDByActivity[HeadphonesPolicy.disconnectedID] == "wired.x")
    }

    @Test func pluggingBackInReplacesTheGoodbye() {
        feature.syncWithSettings()
        monitor.send([buds])
        monitor.send([])
        monitor.send([buds])
        #expect(engine.activity(HeadphonesPolicy.disconnectedID) == nil)
        #expect(engine.activity(HeadphonesPolicy.connectedID) != nil)
    }

    @Test func swappingShowsTheNewPair() throws {
        let earPods = HeadphonesState(id: "wired.x", name: "EarPods", kind: .earPods, isWired: true)
        feature.syncWithSettings()
        monitor.send([earPods])
        monitor.send([buds])
        #expect(engine.activity(HeadphonesPolicy.disconnectedID) == nil)
        #expect(try #require(engine.activity(HeadphonesPolicy.connectedID)).title == "Nord Buds 3")
    }

    @Test func turningOffSaysNoGoodbye() {
        feature.syncWithSettings()
        monitor.send([buds])
        settings.headphonesEnabled = false
        feature.syncWithSettings()
        #expect(engine.activity(HeadphonesPolicy.disconnectedID) == nil)
    }

    @Test func switchingModeIsOptimisticAndAsksTheHeadphones() {
        feature.syncWithSettings()
        monitor.send([pods()])
        feature.setListeningMode(.transparency, for: "aa-bb")
        #expect(feature.devices.first?.listeningMode == .transparency)
        #expect(monitor.modeRequests.map(\.0) == [.transparency])
    }

    @Test func unsupportedModeIsIgnored() {
        feature.syncWithSettings()
        monitor.send([buds])
        feature.setListeningMode(.noiseCancellation, for: "cc-dd")
        #expect(monitor.modeRequests.isEmpty)
    }

    @Test func turningOffStopsAndClears() {
        feature.syncWithSettings()
        monitor.send([pods()])
        settings.headphonesEnabled = false
        feature.syncWithSettings()
        #expect(!monitor.isStarted)
        #expect(feature.devices.isEmpty)
        #expect(engine.activities.allSatisfy { $0.source != HeadphonesPolicy.source })
    }

    @Test func refreshGoesToTheMonitorOnlyWhileRunning() {
        feature.refresh()
        #expect(monitor.refreshes == 0)
        feature.syncWithSettings()
        feature.refresh()
        #expect(monitor.refreshes == 1)
    }
}

struct WiredHeadphonesReadingTests {
    private func output(
        _ name: String, transport: UInt32, terminals: [UInt32] = [], source: UInt32? = nil, uid: String = "uid"
    ) -> AudioOutputDescription {
        AudioOutputDescription(uid: uid, name: name, transport: transport, terminalTypes: terminals, dataSource: source)
    }

    private let usb: UInt32 = 0x7573_6220 // 'usb '
    private let builtIn: UInt32 = 0x626C_746E // 'bltn'

    @Test func usbEarPodsByTerminalType() throws {
        let device = output("EarPods", transport: usb, terminals: [0x6864_7068], uid: "AppleUSBAudioEngine:EarPods:1")
        let state = try #require(WiredHeadphonesReading.headphones(from: device))
        #expect(state.kind == .earPods)
        #expect(state.isWired)
        #expect(state.id == "wired.AppleUSBAudioEngine:EarPods:1")
        #expect(state.battery.isEmpty && state.availableModes.isEmpty)
    }

    @Test func usbHeadsetByUSBTerminalOrName() {
        #expect(WiredHeadphonesReading.headphones(from: output("Jabra", transport: usb, terminals: [0x402])) != nil)
        #expect(WiredHeadphonesReading
            .headphones(from: output("USB Headset", transport: usb, terminals: [0x301])) != nil)
    }

    @Test func usbSpeakersAndInterfacesStayQuiet() {
        #expect(WiredHeadphonesReading
            .headphones(from: output("Scarlett 2i2", transport: usb, terminals: [0x301])) == nil)
    }

    @Test func headphoneJack() throws {
        // Apple silicon: a separate "External Headphones" device.
        let external = output("External Headphones", transport: builtIn, uid: "BuiltInHeadphoneOutputDevice")
        let state = try #require(WiredHeadphonesReading.headphones(from: external))
        #expect(state.name == "Headphones")
        #expect(state.id == "wired.jack")
        // Older Macs: the speakers switch their data source to 'hdpn'.
        let switched = output("Built-in Output", transport: builtIn, source: 0x6864_706E)
        #expect(WiredHeadphonesReading.headphones(from: switched)?.id == "wired.jack")
    }

    @Test func speakersBluetoothAndAirPlayAreNotWiredHeadphones() {
        let speakers = output("MacBook Air Speakers", transport: builtIn, terminals: [0x301], source: 0x6973_706B)
        #expect(WiredHeadphonesReading.headphones(from: speakers) == nil)
        #expect(WiredHeadphonesReading.headphones(from: output("AirPods", transport: 0x626C_7565)) == nil)
        #expect(WiredHeadphonesReading
            .headphones(from: output("Living Room headphones", transport: 0x6169_7270)) == nil)
    }

    @Test func oneEntryPerPair() {
        let jack = output("External Headphones", transport: builtIn, uid: "BuiltInHeadphoneOutputDevice")
        let switched = output("Built-in Output", transport: builtIn, source: 0x6864_706E)
        #expect(WiredHeadphonesReading.headphones(from: [jack, switched]).count == 1)
    }

    @MainActor
    @Test func wiredConnectSaysWired() {
        let earPods = HeadphonesState(id: "wired.x", name: "EarPods", kind: .earPods, isWired: true)
        let activity = HeadphonesPolicy.connectedActivity(for: earPods, expiresAt: .distantFuture)
        #expect(activity.subtitle == "Wired")
        #expect(activity.symbol == "earpods")
        #expect(HeadphonesPolicy.changes(from: [], to: [earPods], alerted: []).lowBattery.isEmpty)
    }
}

@MainActor
struct CombinedHeadphonesMonitorTests {
    @Test func mergesBluetoothThenWired() {
        let bluetooth = FakeHeadphonesMonitor()
        let wired = FakeHeadphonesMonitor()
        let combined = CombinedHeadphonesMonitor([bluetooth, wired])
        var received: [[HeadphonesState]] = []
        combined.start { received.append($0) }
        let earPods = HeadphonesState(id: "wired.x", name: "EarPods", kind: .earPods, isWired: true)
        wired.send([earPods])
        bluetooth.send([buds])
        #expect(received.last == [buds, earPods])
        wired.send([])
        #expect(received.last == [buds])
        combined.refresh()
        combined.stop()
        #expect(bluetooth.refreshes == 1 && wired.refreshes == 1)
        #expect(!bluetooth.isStarted && !wired.isStarted)
    }
}

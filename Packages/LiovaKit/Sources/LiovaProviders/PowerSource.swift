import Foundation
import IOKit.ps

/// The Mac's power state at one moment.
public struct PowerSnapshot: Equatable, Sendable {
    /// False on desktops (Mac mini, iMac, Mac Studio, Mac Pro).
    public var hasBattery: Bool
    /// Battery charge, 0–100.
    public var percentage: Int
    public var isPluggedIn: Bool
    public var isCharging: Bool
    public var isFullyCharged: Bool
    public var isLowPowerMode: Bool
    /// Minutes until empty or full, when macOS has an estimate.
    public var minutesRemaining: Int?

    public init(
        hasBattery: Bool,
        percentage: Int,
        isPluggedIn: Bool,
        isCharging: Bool,
        isFullyCharged: Bool = false,
        isLowPowerMode: Bool = false,
        minutesRemaining: Int? = nil
    ) {
        self.hasBattery = hasBattery
        self.percentage = min(max(percentage, 0), 100)
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.isLowPowerMode = isLowPowerMode
        self.minutesRemaining = minutesRemaining
    }

    public static let noBattery = PowerSnapshot(
        hasBattery: false,
        percentage: 100,
        isPluggedIn: true,
        isCharging: false
    )
}

/// A source of power-state changes. Behind a protocol so features are testable
/// and the implementation can change without touching them.
@MainActor
public protocol PowerSourceProviding: AnyObject {
    var snapshot: PowerSnapshot { get }
    /// Starts delivering changes on the main actor. Delivers the current state first.
    func start(onChange: @escaping @MainActor (PowerSnapshot) -> Void)
    func stop()
}

/// Reads power state from IOKit and listens for changes with
/// `IOPSNotificationCreateRunLoopSource`, which macOS fires only when the
/// state changes. No timers.
@MainActor
public final class IOKitPowerSource: PowerSourceProviding {
    public private(set) var snapshot: PowerSnapshot = .noBattery

    private var runLoopSource: CFRunLoopSource?
    private var lowPowerObserver: (any NSObjectProtocol)?
    private var onChange: (@MainActor (PowerSnapshot) -> Void)?

    public init() {
        snapshot = Self.read()
    }

    public func start(onChange: @escaping @MainActor (PowerSnapshot) -> Void) {
        stop()
        self.onChange = onChange

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let provider = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            // Delivered on the main run loop, where the source was added.
            MainActor.assumeIsolated { provider.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        snapshot = Self.read()
        onChange(snapshot)
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
        lowPowerObserver = nil
        onChange = nil
    }

    private func refresh() {
        let latest = Self.read()
        guard latest != snapshot else { return }
        snapshot = latest
        onChange?(latest)
    }

    /// Reads the internal battery, if there is one.
    static func read() -> PowerSnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return withLowPower(.noBattery, lowPower) }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                description[kIOPSIsPresentKey] as? Bool ?? true
            else { continue }
            return parse(description, lowPower: lowPower)
        }
        return withLowPower(.noBattery, lowPower)
    }

    /// Converts an IOKit power-source description. Separate from IOKit for testing.
    static func parse(_ description: [String: Any], lowPower: Bool) -> PowerSnapshot {
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let percentage = Int((Double(current) / Double(maximum) * 100).rounded())
        let isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        let timeKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = (description[timeKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return PowerSnapshot(
            hasBattery: true,
            percentage: percentage,
            isPluggedIn: isPluggedIn,
            isCharging: isCharging,
            isFullyCharged: isCharged || (isPluggedIn && percentage >= 100),
            isLowPowerMode: lowPower,
            minutesRemaining: minutes
        )
    }

    private static func withLowPower(_ snapshot: PowerSnapshot, _ lowPower: Bool) -> PowerSnapshot {
        var copy = snapshot
        copy.isLowPowerMode = lowPower
        return copy
    }
}

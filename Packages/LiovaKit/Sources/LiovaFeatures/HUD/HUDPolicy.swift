import Foundation
import LiovaPluginKit
import LiovaProviders

/// Level math and activity mapping for the volume and brightness HUDs. Pure, so every rule is unit-tested.
///
/// Behaviour follows macOS:
/// - 16 steps per key press, 64 (quarter steps) with Shift+Option.
/// - A level between steps snaps to the next step in the direction of the key.
/// - Mute toggles mute and leaves the level alone.
/// - Volume up while muted unmutes and goes up one step; volume down while muted stays muted.
public enum HUDPolicy {
    public static let activityID: ActivityID = "system.hud"
    public static let source = "system.hud"
    /// How long the HUD stays after the last key press or change.
    public static let displayDuration: TimeInterval = 1.5
    public static let coarseSteps = 16
    public static let fineSteps = 64
    /// Two levels closer than this are the same level (Core Audio rounds through `Float32`
    /// and some devices quantize to their own step size).
    public static let levelTolerance = 0.005

    public enum Direction: Sendable {
        case increase, decrease
    }

    /// What the volume should become after a key press.
    public struct VolumeTarget: Equatable, Sendable {
        public var volume: Double
        public var isMuted: Bool

        public init(volume: Double, isMuted: Bool) {
            self.volume = volume
            self.isMuted = isMuted
        }
    }

    // MARK: - Level math

    /// The next level one step up or down, snapped to the step grid and clamped to `0...1`.
    public static func step(_ level: Double, _ direction: Direction, fine: Bool) -> Double {
        let steps = Double(fine ? fineSteps : coarseSteps)
        let scaled = (level.isFinite ? min(max(level, 0), 1) : 0) * steps
        // A level within a quarter step of a grid point counts as on it. Devices quantize the
        // level to their own steps (0.0625 may read back as 0.06), and without this snap a key
        // press could land on the level it started from and appear stuck.
        let nearest = scaled.rounded()
        let isOnGrid = abs(scaled - nearest) < 0.25
        let next = switch direction {
        case .increase: (isOnGrid ? nearest : scaled.rounded(.down)) + 1
        case .decrease: (isOnGrid ? nearest : scaled.rounded(.up)) - 1
        }
        return min(max(next, 0), steps) / steps
    }

    /// The volume after pressing `key`, or `nil` for keys that aren't volume keys.
    public static func volumeTarget(for key: MediaKey, current: VolumeState, fine: Bool) -> VolumeTarget? {
        switch key {
        case .mute:
            VolumeTarget(volume: current.volume, isMuted: !current.isMuted)
        case .soundUp:
            VolumeTarget(volume: step(current.volume, .increase, fine: fine), isMuted: false)
        case .soundDown:
            VolumeTarget(volume: step(current.volume, .decrease, fine: fine), isMuted: current.isMuted)
        case .brightnessUp, .brightnessDown:
            nil
        }
    }

    /// The brightness after pressing `key`, or `nil` for keys that aren't brightness keys.
    public static func brightnessTarget(for key: MediaKey, current: Double, fine: Bool) -> Double? {
        switch key {
        case .brightnessUp: step(current, .increase, fine: fine)
        case .brightnessDown: step(current, .decrease, fine: fine)
        case .soundUp, .soundDown, .mute: nil
        }
    }

    public static func isSameLevel(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < levelTolerance
    }

    /// Whether two volume states look the same in the HUD.
    public static func isSameVolume(_ lhs: VolumeState, _ rhs: VolumeState) -> Bool {
        lhs.isMuted == rhs.isMuted && isSameLevel(lhs.volume, rhs.volume)
    }

    // MARK: - Activities

    public static func volumeActivity(volume: Double, isMuted: Bool, now: Date) -> Activity {
        let shown = isMuted ? 0 : volume
        return Activity(
            id: activityID,
            source: source,
            priority: .critical,
            title: "Volume",
            subtitle: isMuted ? "Muted" : percent(volume),
            symbol: volumeSymbol(volume: volume, isMuted: isMuted),
            progress: shown,
            tint: .gray,
            expiresAt: now + displayDuration
        )
    }

    public static func brightnessActivity(brightness: Double, now: Date) -> Activity {
        Activity(
            id: activityID,
            source: source,
            priority: .critical,
            title: "Brightness",
            subtitle: percent(brightness),
            symbol: brightnessSymbol(brightness),
            progress: brightness,
            tint: .yellow,
            expiresAt: now + displayDuration
        )
    }

    public static func volumeSymbol(volume: Double, isMuted: Bool) -> String {
        if isMuted || volume < levelTolerance {
            return "speaker.slash.fill"
        }
        return switch volume {
        case ..<(1.0 / 3): "speaker.wave.1.fill"
        case ..<(2.0 / 3): "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    public static func brightnessSymbol(_ brightness: Double) -> String {
        brightness < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }

    static func percent(_ level: Double) -> String {
        "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }
}

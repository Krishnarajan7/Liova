import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
///
/// Each property is observed individually, so a view that reads `hoverDelay`
/// does not re-render when `hapticsEnabled` changes.
@MainActor
@Observable
public final class LiovaSettings {
    public var openOnHover: Bool {
        didSet { store(openOnHover, .openOnHover) }
    }

    /// Seconds the pointer must rest on the notch before it opens.
    public var hoverDelay: Double {
        didSet {
            let clamped = Self.clampHoverDelay(hoverDelay)
            if clamped != hoverDelay {
                hoverDelay = clamped
            }
            store(hoverDelay, .hoverDelay)
        }
    }

    public var displayPlacement: DisplayPlacement {
        didSet { store(displayPlacement.rawValue, .displayPlacement) }
    }

    public var hapticsEnabled: Bool {
        didSet { store(hapticsEnabled, .hapticsEnabled) }
    }

    public var showVirtualNotchWhenIdle: Bool {
        didSet { store(showVirtualNotchWhenIdle, .showVirtualNotchWhenIdle) }
    }

    public var batteryActivitiesEnabled: Bool {
        didSet { store(batteryActivitiesEnabled, .batteryActivitiesEnabled) }
    }

    /// Replace the system volume and brightness overlays with notch HUDs.
    /// Off by default: it needs the Accessibility permission.
    public var hudReplacementEnabled: Bool {
        didSet { store(hudReplacementEnabled, .hudReplacementEnabled) }
    }

    /// Show active downloads (browsers, Telegram, …) in the notch.
    public var downloadsEnabled: Bool {
        didSet { store(downloadsEnabled, .downloadsEnabled) }
    }

    /// Also watch Telegram for macOS' downloads. Off by default: reading the folder names in
    /// another app's container makes macOS ask for permission.
    public var telegramDownloadsEnabled: Bool {
        didSet { store(telegramDownloadsEnabled, .telegramDownloadsEnabled) }
    }

    /// Animate the music bars in the closed notch while something plays.
    public var animatedMusicBars: Bool {
        didSet { store(animatedMusicBars, .animatedMusicBars) }
    }

    /// Where volume and brightness changes appear.
    public var hudStyle: HUDStyle {
        didSet { store(hudStyle.rawValue, .hudStyle) }
    }

    /// Keep the notch out of the way over full-screen apps until hovered.
    public var hideInFullScreen: Bool {
        didSet { store(hideInFullScreen, .hideInFullScreen) }
    }

    /// Flash the notch when any app turns on the camera or microphone.
    public var captureIndicatorEnabled: Bool {
        didSet { store(captureIndicatorEnabled, .captureIndicatorEnabled) }
    }

    /// Show the next calendar event. Off by default: it needs calendar access.
    public var calendarEnabled: Bool {
        didSet { store(calendarEnabled, .calendarEnabled) }
    }

    /// Set after the first-launch welcome has been shown.
    public var hasSeenWelcome: Bool {
        didSet { store(hasSeenWelcome, .hasSeenWelcome) }
    }

    /// Show what's playing (music, podcasts, video) in the notch.
    public var nowPlayingEnabled: Bool {
        didSet { store(nowPlayingEnabled, .nowPlayingEnabled) }
    }

    /// Show coding agents (Claude Code and others) in the notch.
    public var agentIslandEnabled: Bool {
        didSet { store(agentIslandEnabled, .agentIslandEnabled) }
    }

    /// Open the notch by itself when an agent asks for permission.
    public var agentOpensNotchForApprovals: Bool {
        didSet { store(agentOpensNotchForApprovals, .agentOpensNotchForApprovals) }
    }

    public var lowBatteryThreshold: Int {
        didSet {
            let clamped = min(max(lowBatteryThreshold, 5), 50)
            if clamped != lowBatteryThreshold {
                lowBatteryThreshold = clamped
            }
            store(lowBatteryThreshold, .lowBatteryThreshold)
        }
    }

    public static let hoverDelayRange: ClosedRange<Double> = 0 ... 1

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openOnHover = defaults.object(forKey: Key.openOnHover.rawValue) as? Bool ?? true
        hoverDelay = Self.clampHoverDelay(defaults.object(forKey: Key.hoverDelay.rawValue) as? Double ?? 0.12)
        displayPlacement = defaults.string(forKey: Key.displayPlacement.rawValue)
            .flatMap(DisplayPlacement.init(rawValue:)) ?? .allDisplays
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled.rawValue) as? Bool ?? true
        showVirtualNotchWhenIdle = defaults.object(forKey: Key.showVirtualNotchWhenIdle.rawValue) as? Bool ?? true
        batteryActivitiesEnabled = defaults.object(forKey: Key.batteryActivitiesEnabled.rawValue) as? Bool ?? true
        hudReplacementEnabled = defaults.object(forKey: Key.hudReplacementEnabled.rawValue) as? Bool ?? false
        downloadsEnabled = defaults.object(forKey: Key.downloadsEnabled.rawValue) as? Bool ?? true
        telegramDownloadsEnabled = defaults.object(forKey: Key.telegramDownloadsEnabled.rawValue) as? Bool ?? false
        animatedMusicBars = defaults.object(forKey: Key.animatedMusicBars.rawValue) as? Bool ?? true
        hideInFullScreen = defaults.object(forKey: Key.hideInFullScreen.rawValue) as? Bool ?? true
        captureIndicatorEnabled = defaults.object(forKey: Key.captureIndicatorEnabled.rawValue) as? Bool ?? true
        calendarEnabled = defaults.object(forKey: Key.calendarEnabled.rawValue) as? Bool ?? false
        hasSeenWelcome = defaults.object(forKey: Key.hasSeenWelcome.rawValue) as? Bool ?? false
        hudStyle = defaults.string(forKey: Key.hudStyle.rawValue).flatMap(HUDStyle.init(rawValue:)) ?? .sideBar
        nowPlayingEnabled = defaults.object(forKey: Key.nowPlayingEnabled.rawValue) as? Bool ?? true
        agentIslandEnabled = defaults.object(forKey: Key.agentIslandEnabled.rawValue) as? Bool ?? true
        agentOpensNotchForApprovals = defaults.object(forKey: Key.agentOpensNotchForApprovals.rawValue) as? Bool
            ?? true
        lowBatteryThreshold = min(max(defaults.object(forKey: Key.lowBatteryThreshold.rawValue) as? Int ?? 20, 5), 50)
    }

    private enum Key: String {
        case openOnHover
        case hoverDelay
        case displayPlacement
        case hapticsEnabled
        case showVirtualNotchWhenIdle
        case batteryActivitiesEnabled
        case lowBatteryThreshold
        case hudReplacementEnabled
        case nowPlayingEnabled
        case hudStyle
        case hasSeenWelcome
        case calendarEnabled
        case captureIndicatorEnabled
        case hideInFullScreen
        case animatedMusicBars
        case downloadsEnabled
        case telegramDownloadsEnabled
        case agentIslandEnabled
        case agentOpensNotchForApprovals
    }

    private func store(_ value: some Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private static func clampHoverDelay(_ value: Double) -> Double {
        value.isFinite ? min(max(value, hoverDelayRange.lowerBound), hoverDelayRange.upperBound) : 0.12
    }
}

/// Where the volume and brightness HUD appears.
public enum HUDStyle: String, CaseIterable, Codable, Sendable {
    /// A vertical level bar at the right edge of the screen.
    case sideBar
    /// Inside the notch.
    case notch
}

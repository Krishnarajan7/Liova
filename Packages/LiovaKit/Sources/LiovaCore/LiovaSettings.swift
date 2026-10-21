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

    /// When the music bars in the closed notch move while something plays. Moving bars keep
    /// the window server compositing every frame; they run at 20 fps on battery.
    public var musicBars: MusicBarsMode {
        didSet { store(musicBars.rawValue, .musicBars) }
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

    /// Show synced lyrics for what's playing. Off by default: it looks the song up on lrclib.net.
    public var lyricsEnabled: Bool {
        didSet { store(lyricsEnabled, .lyricsEnabled) }
    }

    /// With lyrics on, the line being sung also shows under the closed notch.
    public var lyricsInClosedNotch: Bool {
        didSet { store(lyricsInClosedNotch, .lyricsInClosedNotch) }
    }

    /// Weather in the open notch. Off by default: it asks Open-Meteo about a location.
    public var weatherEnabled: Bool {
        didSet { store(weatherEnabled, .weatherEnabled) }
    }

    /// The city to show weather for, or nil for the Mac's approximate location.
    public var weatherPlace: WeatherPlace? {
        didSet {
            if let weatherPlace, let data = try? JSONEncoder().encode(weatherPlace) {
                store(data, .weatherPlace)
            } else {
                defaults.removeObject(forKey: Key.weatherPlace.rawValue)
            }
        }
    }

    public var temperatureUnit: TemperatureUnit {
        didSet { store(temperatureUnit.rawValue, .temperatureUnit) }
    }

    /// A short heads-up in the notch when rain is about to start.
    public var rainAlertsEnabled: Bool {
        didSet { store(rainAlertsEnabled, .rainAlertsEnabled) }
    }

    /// Show AirPods and other Bluetooth headphones when they connect, with their battery.
    public var headphonesEnabled: Bool {
        didSet { store(headphonesEnabled, .headphonesEnabled) }
    }

    /// Show coding agents (Claude Code and others) in the notch.
    public var agentIslandEnabled: Bool {
        didSet { store(agentIslandEnabled, .agentIslandEnabled) }
    }

    /// Open the notch by itself when an agent asks for permission.
    public var agentOpensNotchForApprovals: Bool {
        didSet { store(agentOpensNotchForApprovals, .agentOpensNotchForApprovals) }
    }

    /// Look for a new version once a day (one request to GitHub's public API).
    public var automaticUpdateChecks: Bool {
        didSet { store(automaticUpdateChecks, .automaticUpdateChecks) }
    }

    /// Offer pre-release (beta) versions too.
    public var betaUpdates: Bool {
        didSet { store(betaUpdates, .betaUpdates) }
    }

    /// A version the user chose to skip; it isn't announced again.
    public var skippedUpdateVersion: String? {
        didSet { storeOptional(skippedUpdateVersion, .skippedUpdateVersion) }
    }

    /// When Liova last looked for a new version.
    public var lastUpdateCheck: Date? {
        didSet { storeOptional(lastUpdateCheck, .lastUpdateCheck) }
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
        musicBars = Self.loadMusicBars(defaults)
        hideInFullScreen = defaults.object(forKey: Key.hideInFullScreen.rawValue) as? Bool ?? true
        captureIndicatorEnabled = defaults.object(forKey: Key.captureIndicatorEnabled.rawValue) as? Bool ?? true
        calendarEnabled = defaults.object(forKey: Key.calendarEnabled.rawValue) as? Bool ?? false
        hasSeenWelcome = defaults.object(forKey: Key.hasSeenWelcome.rawValue) as? Bool ?? false
        hudStyle = defaults.string(forKey: Key.hudStyle.rawValue).flatMap(HUDStyle.init(rawValue:)) ?? .sideBar
        nowPlayingEnabled = defaults.object(forKey: Key.nowPlayingEnabled.rawValue) as? Bool ?? true
        agentIslandEnabled = defaults.object(forKey: Key.agentIslandEnabled.rawValue) as? Bool ?? true
        headphonesEnabled = defaults.object(forKey: Key.headphonesEnabled.rawValue) as? Bool ?? true
        lyricsEnabled = defaults.object(forKey: Key.lyricsEnabled.rawValue) as? Bool ?? false
        lyricsInClosedNotch = defaults.object(forKey: Key.lyricsInClosedNotch.rawValue) as? Bool ?? true
        weatherEnabled = defaults.object(forKey: Key.weatherEnabled.rawValue) as? Bool ?? false
        weatherPlace = defaults.data(forKey: Key.weatherPlace.rawValue)
            .flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) }
        temperatureUnit = defaults.string(forKey: Key.temperatureUnit.rawValue)
            .flatMap(TemperatureUnit.init(rawValue:)) ?? .automatic
        rainAlertsEnabled = defaults.object(forKey: Key.rainAlertsEnabled.rawValue) as? Bool ?? true
        agentOpensNotchForApprovals = defaults.object(forKey: Key.agentOpensNotchForApprovals.rawValue) as? Bool
            ?? true
        lowBatteryThreshold = min(max(defaults.object(forKey: Key.lowBatteryThreshold.rawValue) as? Int ?? 20, 5), 50)
        automaticUpdateChecks = defaults.object(forKey: Key.automaticUpdateChecks.rawValue) as? Bool ?? true
        betaUpdates = defaults.object(forKey: Key.betaUpdates.rawValue) as? Bool ?? false
        skippedUpdateVersion = defaults.string(forKey: Key.skippedUpdateVersion.rawValue)
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck.rawValue) as? Date
    }

    private enum Key: String {
        case automaticUpdateChecks
        case betaUpdates
        case skippedUpdateVersion
        case lastUpdateCheck
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
        case musicBars
        /// Before `musicBars`: a plain on/off switch.
        case animatedMusicBars
        case downloadsEnabled
        case telegramDownloadsEnabled
        case agentIslandEnabled
        case headphonesEnabled
        case lyricsEnabled
        case lyricsInClosedNotch
        case weatherEnabled
        case weatherPlace
        case temperatureUnit
        case rainAlertsEnabled
        case agentOpensNotchForApprovals
    }

    private func store(_ value: some Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func storeOptional(_ value: (some Any)?, _ key: Key) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    private static func loadMusicBars(_ defaults: UserDefaults) -> MusicBarsMode {
        if let mode = defaults.string(forKey: Key.musicBars.rawValue).flatMap(MusicBarsMode.init(rawValue:)) {
            return mode
        }
        // The old switch was only stored once someone flipped it, so either value was a choice.
        if let animated = defaults.object(forKey: Key.animatedMusicBars.rawValue) as? Bool {
            return animated ? .always : .off
        }
        // Resting bars on battery read as broken, and 20 fps there costs about 1.8%
        // WindowServer CPU (docs/PERFORMANCE.md). When plugged in and Off stay a choice.
        return .always
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

/// When the closed-notch music bars move.
public enum MusicBarsMode: String, CaseIterable, Codable, Sendable {
    case always
    /// Moving while on power, resting on battery.
    case pluggedIn
    /// Always resting.
    case off

    /// Whether the bars should move right now.
    public func animates(onBattery: Bool) -> Bool {
        switch self {
        case .always: true
        case .pluggedIn: !onBattery
        case .off: false
        }
    }
}

/// A place to show weather for, picked by name.
public struct WeatherPlace: Codable, Equatable, Sendable, Identifiable {
    /// What the user sees: "Chennai, Tamil Nadu, India".
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public var id: String {
        "\(name)|\(latitude)|\(longitude)"
    }

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
    /// Whatever the Mac's region uses.
    case automatic
    case celsius
    case fahrenheit

    /// Fahrenheit or not, with `automatic` resolved through `locale`.
    public func usesFahrenheit(locale: Locale = .current) -> Bool {
        switch self {
        case .automatic: locale.measurementSystem == .us
        case .celsius: false
        case .fahrenheit: true
        }
    }
}

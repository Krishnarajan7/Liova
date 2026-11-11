import Foundation

/// What the notch is made of.
public enum NotchStyle: String, CaseIterable, Codable, Sendable {
    /// Solid black, one with the camera housing.
    case black
    /// Liquid Glass (a blur before macOS 26) once open; the closed notch stays black so it
    /// still blends with the camera housing.
    case glass
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

public extension LiovaSettings {
    /// The shortcut for `action`: the user's own, or the default.
    func shortcut(for action: HotkeyAction) -> Shortcut {
        customShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        customShortcuts[action.rawValue] = shortcut == action.defaultShortcut ? nil : shortcut
    }
}

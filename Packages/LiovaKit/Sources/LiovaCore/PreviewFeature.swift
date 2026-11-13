import Foundation

/// Features that are built and merged but not released yet.
///
/// They ship in every build, switched off: release builds hide them until the release that
/// introduces one deletes its case here (and the checks with it). Debug builds show them
/// all, and anyone can try one early with
/// `defaults write app.liova.Liova previewFeatures -array calls`.
public enum PreviewFeature: String, CaseIterable, Sendable {
    /// Mute and hang up calls from the notch.
    case calls
    /// Start, pause and stop screen recordings (OBS, macOS) from the notch.
    case recording
    /// A short moment in the notch when the Mac is unlocked.
    case unlock

    static let defaultsKey = "previewFeatures"

    public func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
            true
        #else
            (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(rawValue)
        #endif
    }
}

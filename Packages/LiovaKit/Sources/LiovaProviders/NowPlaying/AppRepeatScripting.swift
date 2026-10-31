import AppKit
import CoreServices

/// Repeat for players that don't report it to macOS, through their own AppleScript.
///
/// Spotify is the one that matters: it neither reports repeat to MediaRemote nor obeys
/// MediaRemote's repeat command, but its scripting dictionary has `repeating` (on or off;
/// there's no "repeat one"). Scripting another app needs the user's OK once (Automation),
/// which macOS asks for the first time the user turns repeat on from the notch.
public protocol AppRepeatScripting: Sendable {
    /// Whether `bundleIdentifier` can be scripted for repeat at all.
    func supports(_ bundleIdentifier: String) -> Bool
    /// The player's repeat, without ever asking the user: nil when Liova may not script it
    /// yet (not allowed, or never asked) or it isn't running.
    func repeating(in bundleIdentifier: String) async -> Bool?
    /// Sets repeat, asking the user for permission the first time. True when it took.
    func setRepeating(_ isOn: Bool, in bundleIdentifier: String) async -> Bool
}

public struct AppleScriptRepeat: AppRepeatScripting {
    public static let spotify = "com.spotify.client"

    public init() {}

    public func supports(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == Self.spotify
    }

    public func repeating(in bundleIdentifier: String) async -> Bool? {
        guard supports(bundleIdentifier), await Self.permission(for: bundleIdentifier, ask: false) else { return nil }
        return await Self.run("tell application id \"\(bundleIdentifier)\" to return repeating")
    }

    public func setRepeating(_ isOn: Bool, in bundleIdentifier: String) async -> Bool {
        guard supports(bundleIdentifier), await Self.permission(for: bundleIdentifier, ask: true) else { return false }
        let source = "tell application id \"\(bundleIdentifier)\" to set repeating to \(isOn)"
        return await Self.run(source) != nil
    }

    /// One script at a time, off the main thread: a first-time permission prompt waits for
    /// the user, and the notch mustn't freeze meanwhile.
    private static let queue = DispatchQueue(label: "app.liova.repeat-scripting", qos: .userInitiated)

    private static func permission(for bundleIdentifier: String, ask: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc, typeWildCard, typeWildCard, ask
                )
                continuation.resume(returning: status == noErr)
            }
        }
    }

    /// The script's result as a Boolean (false for no result), or nil when it failed.
    private static func run(_ source: String) async -> Bool? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result?.booleanValue ?? false : nil)
            }
        }
    }
}

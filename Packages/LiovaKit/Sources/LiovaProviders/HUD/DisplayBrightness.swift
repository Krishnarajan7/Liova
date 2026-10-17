import CoreGraphics
import Darwin
import Foundation

/// Reads and changes the built-in display's brightness. Behind a protocol so features are
/// testable without touching the user's screen.
@MainActor
public protocol DisplayBrightnessControlling: AnyObject {
    /// True when the built-in display is online and its brightness can be read and set.
    /// False with the lid closed, on Macs without a built-in display, or if the private
    /// framework changed. External displays are not supported yet.
    var isAvailable: Bool { get }
    /// Built-in display brightness in `0...1`, or `nil` when unavailable.
    func brightness() -> Double?
    /// Returns false (and changes nothing) when unavailable or when the call fails.
    @discardableResult func setBrightness(_ value: Double) -> Bool
}

/// Built-in display brightness through the private `DisplayServices` framework.
///
/// The symbols are resolved with `dlopen`/`dlsym` at runtime and never linked, so a macOS
/// release that removes or renames them makes the provider report unavailable instead of
/// crashing. The keys then pass through to the system, which shows its own HUD.
@MainActor
public final class DisplayServicesBrightness: DisplayBrightnessControlling {
    public static let defaultFrameworkPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Symbols {
        var get: GetBrightness
        var set: SetBrightness
        var canChange: CanChangeBrightness?
    }

    private let frameworkPath: String
    private let builtInDisplay: () -> CGDirectDisplayID?
    private var resolved = false
    private var symbols: Symbols?

    /// - Parameters:
    ///   - frameworkPath: injectable so tests can exercise the missing-framework path.
    ///   - builtInDisplay: injectable so tests never read or change a real display.
    public init(
        frameworkPath: String = DisplayServicesBrightness.defaultFrameworkPath,
        builtInDisplay: @escaping () -> CGDirectDisplayID? = BuiltInDisplay.onlineID
    ) {
        self.frameworkPath = frameworkPath
        self.builtInDisplay = builtInDisplay
    }

    public var isAvailable: Bool {
        brightness() != nil
    }

    public func brightness() -> Double? {
        guard let symbols = resolveSymbols(), let display = controllableDisplay(symbols) else { return nil }
        var value: Float = 0
        guard symbols.get(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    @discardableResult
    public func setBrightness(_ value: Double) -> Bool {
        guard value.isFinite, let symbols = resolveSymbols(), let display = controllableDisplay(symbols) else {
            return false
        }
        let status = symbols.set(display, Float(min(max(value, 0), 1)))
        if status != 0 {
            HUDLog.logger.error("DisplayServicesSetBrightness failed: \(status)")
        }
        return status == 0
    }

    private func controllableDisplay(_ symbols: Symbols) -> CGDirectDisplayID? {
        guard let display = builtInDisplay() else { return nil }
        if let canChange = symbols.canChange, !canChange(display) {
            return nil
        }
        return display
    }

    /// Resolves once. The handle is intentionally never closed: the framework stays loaded for
    /// the life of the process, and unloading a system framework is never worth the risk.
    private func resolveSymbols() -> Symbols? {
        if resolved {
            return symbols
        }
        resolved = true
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            HUDLog.logger.notice("DisplayServices unavailable; brightness keys stay with the system")
            return nil
        }
        guard let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness")
        else {
            HUDLog.logger.notice("DisplayServices brightness symbols missing; brightness keys stay with the system")
            return nil
        }
        symbols = Symbols(
            get: unsafeBitCast(get, to: GetBrightness.self),
            set: unsafeBitCast(set, to: SetBrightness.self),
            canChange: dlsym(handle, "DisplayServicesCanChangeBrightness")
                .map { unsafeBitCast($0, to: CanChangeBrightness.self) }
        )
        return symbols
    }
}

/// Finds the built-in display.
public enum BuiltInDisplay {
    /// The online built-in display, if any. Returns `nil` in clamshell mode and on desktop Macs.
    public static func onlineID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

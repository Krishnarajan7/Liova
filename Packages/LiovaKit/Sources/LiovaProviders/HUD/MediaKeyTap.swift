import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Where a media-key tap stands.
public enum MediaKeyTapStatus: Equatable, Sendable {
    case stopped
    case running
    /// The Accessibility permission is missing, so no tap was created. The system handles the keys.
    case needsPermission
    /// The tap couldn't be created or was torn down by the watchdog. The system handles the keys.
    case failed(String)
}

/// Intercepts the volume and brightness keys. Behind a protocol so features are testable
/// without creating a real tap (which needs Accessibility and affects the user's keyboard).
@MainActor
public protocol MediaKeyTapping: AnyObject {
    var status: MediaKeyTapStatus { get }
    /// Whether the process is trusted for Accessibility right now. Never prompts.
    var isPermissionGranted: Bool { get }
    /// Shows the system Accessibility prompt if the process isn't trusted yet.
    func requestPermission()
    /// Creates the tap. `onKey` returns true when it handled the key; only then is the event
    /// swallowed. `onStatusChange` reports later changes, e.g. the watchdog giving up.
    @discardableResult
    func start(
        onKey: @escaping @MainActor (MediaKeyEvent) -> Bool,
        onStatusChange: @escaping @MainActor (MediaKeyTapStatus) -> Void
    ) -> MediaKeyTapStatus
    /// Removes the tap and its run-loop source. Safe to call at any time, any number of times.
    func stop()
}

/// A `CGEventTap` for `NSEvent.EventType.systemDefined` events on the main run loop.
///
/// Safety properties (see docs/HUD.md and ADR-011):
/// - Checks Accessibility first and reports `.needsPermission` instead of failing silently.
/// - Swallows only keys it handled successfully; everything else passes through untouched.
/// - When macOS disables the tap it is re-enabled; if that keeps happening the tap is removed
///   and the system handles the keys again (with its own HUD).
/// - Never suspends or signals any system process.
@MainActor
public final class CGEventMediaKeyTap: MediaKeyTapping {
    public private(set) var status: MediaKeyTapStatus = .stopped

    private let context = TapContext()
    private let isTrusted: () -> Bool
    private let now: () -> Date
    private var watchdog: TapWatchdog
    private var filter = MediaKeyFilter()
    private var onKey: (@MainActor (MediaKeyEvent) -> Bool)?
    private var onStatusChange: (@MainActor (MediaKeyTapStatus) -> Void)?

    /// - Parameter isTrusted: injectable so tests never create a real tap.
    public init(
        watchdog: TapWatchdog = TapWatchdog(),
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        now: @escaping () -> Date = Date.init
    ) {
        self.watchdog = watchdog
        self.isTrusted = isTrusted
        self.now = now
    }

    deinit {
        // Owners call `stop()`; this is a backstop so a tap can never outlive its owner.
        context.invalidate()
    }

    public var isPermissionGranted: Bool {
        isTrusted()
    }

    public func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func start(
        onKey: @escaping @MainActor (MediaKeyEvent) -> Bool,
        onStatusChange: @escaping @MainActor (MediaKeyTapStatus) -> Void
    ) -> MediaKeyTapStatus {
        stop()
        guard isTrusted() else {
            HUDLog.logger.notice("Media-key tap not started: Accessibility permission missing")
            status = .needsPermission
            return status
        }

        context.owner = self
        let mask = CGEventMask(1) << CGEventMask(MediaKeyDecoder.systemDefinedEventType)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            context.owner = nil
            HUDLog.logger.error("CGEvent.tapCreate failed")
            status = .failed("macOS refused to create the key event tap.")
            return status
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            context.owner = nil
            status = .failed("Couldn't attach the key event tap to the run loop.")
            return status
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        context.install(port: port, source: source)

        self.onKey = onKey
        self.onStatusChange = onStatusChange
        filter.reset()
        watchdog.reset()
        status = .running
        HUDLog.logger.info("Media-key tap started")
        return status
    }

    public func stop() {
        let wasInstalled = context.invalidate()
        context.owner = nil
        onKey = nil
        onStatusChange = nil
        filter.reset()
        if status != .stopped {
            status = .stopped
        }
        if wasInstalled {
            HUDLog.logger.info("Media-key tap stopped")
        }
    }

    // MARK: - Callback handling (main thread)

    /// Returns true to swallow the event.
    fileprivate func receive(_ input: TapInput) -> Bool {
        switch input {
        case let .disabled(type):
            handleDisabled(type)
            return false
        case let .systemDefined(subtype, data1, flags):
            guard status == .running,
                  let onKey,
                  let decoded = MediaKeyDecoder.decode(subtype: subtype, data1: data1, flags: flags)
            else { return false }
            return filter.shouldSwallow(decoded, handle: onKey)
        case .other:
            return false
        }
    }

    private func handleDisabled(_ type: CGEventType) {
        guard status == .running, let port = context.port else { return }
        switch watchdog.recordDisable(at: now()) {
        case .reenable:
            HUDLog.logger.notice("Media-key tap disabled by macOS (\(type.rawValue)); re-enabling")
            CGEvent.tapEnable(tap: port, enable: true)
        case .giveUp:
            HUDLog.logger.error("Media-key tap disabled repeatedly; removing it so the system handles the keys")
            let callback = onStatusChange
            stop()
            status = .failed("macOS kept disabling the key event tap, so the system HUD is back.")
            callback?(status)
        }
    }
}

/// The parts of a tapped event the main actor needs, extracted on the tap's thread.
private enum TapInput: Sendable {
    case disabled(CGEventType)
    case systemDefined(subtype: Int, data1: Int, flags: CGEventFlags)
    case other

    init(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            self = .disabled(type)
        } else if type.rawValue == MediaKeyDecoder.systemDefinedEventType, let nsEvent = NSEvent(cgEvent: event) {
            self = .systemDefined(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1, flags: event.flags)
        } else {
            self = .other
        }
    }
}

/// Holds the tap's Core Foundation objects, separate from the main-actor class so `deinit`
/// can tear them down. Touched only on the main thread (the tap's run loop).
private final class TapContext: @unchecked Sendable {
    weak var owner: CGEventMediaKeyTap?
    private(set) var port: CFMachPort?
    private var source: CFRunLoopSource?

    func install(port: CFMachPort, source: CFRunLoopSource) {
        self.port = port
        self.source = source
    }

    /// Disables and removes the tap. Returns true if one was installed.
    @discardableResult
    func invalidate() -> Bool {
        guard let port else { return false }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        return true
    }
}

private func mediaKeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // The source is on the main run loop, so this always runs on the main thread. If that ever
    // weren't true, pass the event through rather than touch main-actor state.
    guard let userInfo, Thread.isMainThread else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    let input = TapInput(type: type, event: event)
    let swallow = MainActor.assumeIsolated {
        context.owner?.receive(input) ?? false
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

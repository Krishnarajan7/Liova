import Foundation

@MainActor
public protocol ScreenLockWatching: AnyObject {
    /// `onChange` gets true when the screen locks and false when it unlocks.
    func start(onChange: @escaping @MainActor (Bool) -> Void)
    func stop()
}

/// The screen locking and unlocking, from the notifications macOS posts for both. Nothing
/// runs in between: no timer, no camera.
@MainActor
public final class SystemScreenLock: ScreenLockWatching {
    private var observers: [any NSObjectProtocol] = []

    static let locked = Notification.Name("com.apple.screenIsLocked")
    static let unlocked = Notification.Name("com.apple.screenIsUnlocked")

    public init() {}

    public func start(onChange: @escaping @MainActor (Bool) -> Void) {
        stop()
        let center = DistributedNotificationCenter.default()
        for (name, isLocked) in [(Self.locked, true), (Self.unlocked, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(isLocked) }
            })
        }
    }

    public func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers = []
    }
}

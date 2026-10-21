import Foundation

/// A throwaway settings store for one test, kept in memory only. A real suite, even one
/// removed afterwards, gets written to ~/Library/Preferences by cfprefsd in the background,
/// so test runs left thousands of files behind.
final class ScratchDefaults: @unchecked Sendable {
    let defaults: UserDefaults = InMemoryDefaults()
}

/// `UserDefaults` backed by a dictionary: reads and writes never reach cfprefsd or disk.
/// The typed getters (`string(forKey:)`, `data(forKey:)`, …) go through `object(forKey:)`.
private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    init() {
        // The suite is never touched: every accessor below is overridden.
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }

    override func set(_ value: Bool, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: Int, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: Double, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: Float, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ url: URL?, forKey key: String) {
        set(url as Any?, forKey: key)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { values }
    }
}

import os

/// Shared loggers and signposters. Stream with:
/// `log stream --level debug --predicate 'subsystem BEGINSWITH "app.liova"'`
public enum Log {
    public static let subsystem = "app.liova.Liova"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let activity = Logger(subsystem: subsystem, category: "activity")
    public static let interaction = Logger(subsystem: subsystem, category: "interaction")
    public static let feature = Logger(subsystem: subsystem, category: "feature")

    /// Signposts for the performance budget (Instruments → Points of Interest).
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}

import Foundation

/// macOS's own background work that runs for a while and warms the Mac: Photos analyzing the
/// library, Spotlight indexing, iCloud syncing. Not the user's to quit, but worth naming,
/// because otherwise the heat has no explanation: none of it shows up as an app.
public struct SystemWork: Equatable, Hashable, Sendable {
    public var id: String
    /// Who's doing it, as the user knows them: "Photos", not `mediaanalysisd`.
    public var name: String
    /// "Analyzing your library".
    public var activity: String
    /// The app whose icon stands for it.
    public var appBundleID: String?
    /// Shown when there's no app icon.
    public var symbol: String

    /// The work a macOS process does, by its executable name. Only processes that run as the
    /// user are seen; root's daemons can't be read without asking for a password.
    public static func of(process name: String) -> SystemWork? {
        byProcess[name]
    }

    static let photos = SystemWork(
        id: "photos", name: "Photos", activity: "Analyzing your library",
        appBundleID: "com.apple.Photos", symbol: "photo.on.rectangle"
    )
    static let spotlight = SystemWork(
        id: "spotlight", name: "Spotlight", activity: "Indexing your files",
        appBundleID: nil, symbol: "magnifyingglass"
    )
    static let iCloud = SystemWork(
        id: "icloud", name: "iCloud", activity: "Syncing your files",
        appBundleID: nil, symbol: "icloud"
    )
    static let intelligence = SystemWork(
        id: "intelligence", name: "Apple Intelligence", activity: "Learning from your Mac",
        appBundleID: nil, symbol: "sparkles"
    )

    private static let byProcess: [String: SystemWork] = [
        "mediaanalysisd": photos, "photoanalysisd": photos, "photolibraryd": photos,
        "mdworker_shared": spotlight, "mdworker": spotlight, "corespotlightd": spotlight,
        "cloudd": iCloud, "bird": iCloud, "fileproviderd": iCloud,
        "intelligenceplatformd": intelligence, "knowledgeconstructiond": intelligence,
        "generativeexperiencesd": intelligence,
    ]
}

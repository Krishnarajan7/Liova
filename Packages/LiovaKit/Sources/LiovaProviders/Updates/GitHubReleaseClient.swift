import Foundation

/// A published Liova release and the files an update needs.
public struct ReleaseInfo: Equatable, Sendable, Identifiable {
    public var version: AppVersion
    /// "Liova 0.2.0".
    public var name: String
    /// The release notes, in Markdown.
    public var notes: String
    /// The release's page on GitHub.
    public var pageURL: URL
    public var publishedAt: Date?
    public var isPrerelease: Bool
    public var installer: Asset?
    /// The installer's SHA-256, as `shasum -a 256` writes it.
    public var checksum: Asset?

    public var id: String {
        version.description
    }

    public struct Asset: Equatable, Sendable {
        public var name: String
        public var url: URL
        /// Bytes.
        public var size: Int

        public init(name: String, url: URL, size: Int) {
            self.name = name
            self.url = url
            self.size = size
        }
    }

    public init(
        version: AppVersion,
        name: String,
        notes: String = "",
        pageURL: URL,
        publishedAt: Date? = nil,
        isPrerelease: Bool = false,
        installer: Asset? = nil,
        checksum: Asset? = nil
    ) {
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.installer = installer
        self.checksum = checksum
    }
}

public protocol ReleaseFetching: Sendable {
    /// Recent published releases, newest first as the server lists them.
    func releases() async throws -> [ReleaseInfo]
}

/// Liova's releases on GitHub. One unauthenticated request to the public API; it carries
/// only the app's name and version (in the User-Agent), nothing about the user or the Mac.
public struct GitHubReleaseClient: ReleaseFetching {
    public static let repository = "Krishnarajan7/Liova"
    /// Every installer and checksum must be served from under here.
    static let downloadPrefix = "https://github.com/\(repository)/releases/download/"
    static let pagePrefix = "https://github.com/\(repository)/releases/"

    private let session: URLSession
    private let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=15")!

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Liova/\(version) (https://github.com/\(repository))"
    }()

    public init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            configuration.httpAdditionalHeaders = [
                "User-Agent": Self.userAgent,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            ]
            return URLSession(configuration: configuration)
        }()
    }

    public func releases() async throws -> [ReleaseInfo] {
        let (data, response) = try await session.data(from: endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Self.parse(data)
    }

    // MARK: - Parsing

    /// Published releases with a version tag. Drafts, odd tags and links that don't point
    /// into Liova's own repository are left out.
    static func parse(_ data: Data) throws -> [ReleaseInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data).compactMap(info)
    }

    static func info(from release: GitHubRelease) -> ReleaseInfo? {
        guard release.draft != true,
              let version = AppVersion(release.tagName),
              let page = URL(string: release.htmlURL), release.htmlURL.hasPrefix(pagePrefix)
        else { return nil }
        let assets = release.assets ?? []
        let installerName = "Liova-\(version).dmg"
        let installer = assets.first { $0.name == installerName }.flatMap(asset)
        let checksum = assets.first { $0.name == installerName + ".sha256" }.flatMap(asset)
        let name = release.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Liova \(version)"
        return ReleaseInfo(
            version: version,
            name: name,
            notes: release.body ?? "",
            pageURL: page,
            publishedAt: release.publishedAt,
            isPrerelease: release.prerelease ?? version.isPrerelease,
            installer: installer,
            checksum: checksum
        )
    }

    private static func asset(_ asset: GitHubAsset) -> ReleaseInfo.Asset? {
        guard asset.downloadURL.hasPrefix(downloadPrefix), let url = URL(string: asset.downloadURL) else { return nil }
        return ReleaseInfo.Asset(name: asset.name, url: url, size: asset.size ?? 0)
    }
}

/// The parts of GitHub's release JSON that Liova reads.
struct GitHubRelease: Decodable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: String
    var draft: Bool?
    var prerelease: Bool?
    var publishedAt: Date?
    var assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAsset: Decodable {
    var name: String
    var size: Int?
    var downloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case downloadURL = "browser_download_url"
    }
}

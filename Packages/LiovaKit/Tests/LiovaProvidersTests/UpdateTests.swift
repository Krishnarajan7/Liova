import Foundation
@testable import LiovaProviders
import Testing

struct AppVersionTests {
    @Test(arguments: [
        ("0.1.0", "0.2.0"), ("0.9.0", "0.10.0"), ("1.0.0-beta.1", "1.0.0"), ("1.0.0-alpha", "1.0.0-beta"),
        ("1.0.0-beta.2", "1.0.0-beta.10"), ("1.0.0-beta", "1.0.0-beta.1"), ("1.0.0-1", "1.0.0-alpha"),
        ("1.2", "1.2.1"), ("v1.9.9", "2.0.0"),
    ])
    func ordersLikeSemanticVersions(lower: String, higher: String) throws {
        let low = try #require(AppVersion(lower))
        let high = try #require(AppVersion(higher))
        #expect(low < high)
        #expect(!(high < low))
        #expect(low != high)
    }

    @Test func trailingZerosAndPrefixesDontMatter() throws {
        #expect(try #require(AppVersion("v1.2")) == #require(AppVersion("1.2.0")))
        #expect(Set([AppVersion("1.2"), AppVersion("1.2.0")]).count == 1)
        #expect(AppVersion("1.0.0+build.7") == AppVersion("1.0.0"))
    }

    @Test func describesItself() {
        #expect(AppVersion("v0.2.0")?.description == "0.2.0")
        #expect(AppVersion("1.0.0-beta.2")?.description == "1.0.0-beta.2")
        #expect(AppVersion("1.0.0-beta.2")?.isPrerelease == true)
    }

    @Test(arguments: ["", "v", "latest", "1..2", "1.2.3.4.5", "1.-2", "1.0.0-", "1.0.0-beta..1", "１.0", "-1.0"])
    func rejectsWhatIsntAVersion(_ text: String) {
        #expect(AppVersion(text) == nil)
    }
}

struct GitHubReleaseParsingTests {
    private func json(
        tag: String = "v0.2.0",
        draft: Bool = false,
        prerelease: Bool = false,
        page: String = "https://github.com/Krishnarajan7/Liova/releases/tag/v0.2.0",
        download: String = "https://github.com/Krishnarajan7/Liova/releases/download/v0.2.0/"
    ) -> String {
        """
        {"tag_name":"\(tag)","name":"","body":"## What's new\\n- Faster","html_url":"\(page)",
         "draft":\(draft),"prerelease":\(prerelease),"published_at":"2026-10-20T08:00:00Z",
         "assets":[
           {"name":"Liova-0.2.0.dmg","size":9000000,"browser_download_url":"\(download)Liova-0.2.0.dmg"},
           {"name":"Liova-0.2.0.dmg.sha256","size":82,"browser_download_url":"\(download)Liova-0.2.0.dmg.sha256"},
           {"name":"notes.txt","size":3,"browser_download_url":"\(download)notes.txt"}
         ]}
        """
    }

    @Test func readsAReleaseAndItsInstaller() throws {
        let releases = try GitHubReleaseClient.parse(Data("[\(json())]".utf8))
        let release = try #require(releases.first)
        #expect(release.version == AppVersion("0.2.0"))
        #expect(release.name == "Liova 0.2.0")
        #expect(release.notes.hasPrefix("## What's new"))
        #expect(release.installer?.name == "Liova-0.2.0.dmg")
        #expect(release.installer?.size == 9_000_000)
        #expect(release.checksum?.name == "Liova-0.2.0.dmg.sha256")
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_792_483_200))
        #expect(!release.isPrerelease)
    }

    @Test func leavesOutDraftsAndOddTags() throws {
        let data = Data("[\(json(draft: true)),\(json(tag: "nightly"))]".utf8)
        #expect(try GitHubReleaseClient.parse(data).isEmpty)
    }

    @Test func ignoresLinksOutsideLiovasRepository() throws {
        let elsewhere = json(download: "https://example.com/Liova/releases/download/v0.2.0/")
        let release = try #require(GitHubReleaseClient.parse(Data("[\(elsewhere)]".utf8)).first)
        #expect(release.installer == nil)
        #expect(release.checksum == nil)
        let otherPage = json(page: "https://github.com/someone/Liova/releases/tag/v0.2.0")
        #expect(try GitHubReleaseClient.parse(Data("[\(otherPage)]".utf8)).isEmpty)
    }

    @Test func marksPrereleases() throws {
        let release = try #require(GitHubReleaseClient.parse(Data("[\(json(prerelease: true))]".utf8)).first)
        #expect(release.isPrerelease)
    }
}

struct UpdateInstallerTests {
    @Test func readsShasumOutput() {
        let digest = String(repeating: "ab", count: 32)
        #expect(UpdateInstaller.parseChecksum("\(digest)  Liova-0.2.0.dmg\n") == digest)
        #expect(UpdateInstaller.parseChecksum(digest.uppercased()) == digest)
        #expect(UpdateInstaller.parseChecksum("") == nil)
        #expect(UpdateInstaller.parseChecksum("abc  Liova.dmg") == nil)
        #expect(UpdateInstaller.parseChecksum(String(repeating: "zz", count: 32)) == nil)
    }

    @Test func hashesFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "liova-hash-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256(of: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func aTranslocatedCopyCantReplaceItself() {
        let url = URL(filePath: "/private/var/folders/x/AppTranslocation/ABC/d/Liova.app")
        #expect(UpdateInstaller.inPlaceSupport(for: url) == .translocated)
    }

    @Test func anUnsignedFolderCantVerifyUpdates() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "liova-unsigned-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(UpdateInstaller.inPlaceSupport(for: folder) == .adHocBuild)
    }

    @Test func refusesAReleaseWithoutAnInstallerOrChecksum() async throws {
        let installer = UpdateInstaller(
            workDirectory: FileManager.default.temporaryDirectory.appending(path: "liova-updates-\(UUID())")
        )
        let page = try #require(URL(string: "https://github.com/Krishnarajan7/Liova/releases/tag/v9.0.0"))
        let bare = try ReleaseInfo(version: #require(AppVersion("9.0.0")), name: "Liova 9.0.0", pageURL: page)
        await #expect(throws: UpdateInstaller.Failure.noInstaller) {
            try await installer.download(bare) { _ in }
        }
        var noChecksum = bare
        noChecksum.installer = .init(name: "Liova-9.0.0.dmg", url: page, size: 10)
        await #expect(throws: UpdateInstaller.Failure.checksumMissing) {
            try await installer.download(noChecksum) { _ in }
        }
        var huge = noChecksum
        huge.checksum = .init(name: "Liova-9.0.0.dmg.sha256", url: page, size: 10)
        huge.installer?.size = UpdateInstaller.maximumInstallerSize + 1
        await #expect(throws: UpdateInstaller.Failure.tooLarge) {
            try await installer.download(huge) { _ in }
        }
    }

    /// The swap script never pastes paths into code: odd names stay arguments.
    @Test func swapScriptKeepsPathsAsArguments() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "liova swap $(touch pwned) \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Liova.app")
        let new = root.appending(path: "staged/Liova.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: app.appending(path: "marker"))
        try Data("new".utf8).write(to: new.appending(path: "marker"))

        // Swap only: pid 0 isn't ours to signal, and `open` is swapped for `true`.
        let script = UpdateInstaller.swapScript.replacingOccurrences(of: "/usr/bin/open", with: "true")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "test", "999999999", new.path, app.path]
        try process.run()
        process.waitUntilExit()

        #expect(try String(contentsOf: app.appending(path: "marker"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: new.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.sorted() == ["Liova.app", "staged"])
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/pwned"))
    }
}

import Foundation
@testable import LiovaProviders
import Testing

/// The real install checks against a real Release build: a disk image is made from a copy
/// of it, and `prepare` must accept an update signed with the same certificate and refuse
/// one signed ad-hoc or carrying the wrong version. Off unless `LIOVA_LIVE_TESTS=1`; needs
/// `make build CONFIG=Release` signed with the "Liova Development" certificate:
///
///     LIOVA_LIVE_TESTS=1 swift test --filter UpdateInstallerLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_LIVE_TESTS"] == "1"), .serialized)
struct UpdateInstallerLiveTests {
    static let identity = "Liova Development"
    let builtApp = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/Build/Products/Release/Liova.app")
    let root = FileManager.default.temporaryDirectory.appending(path: "liova-update-live-\(UUID())")

    private func release(_ version: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(version)!,
            name: "Liova \(version)",
            pageURL: URL(string: "https://github.com/Krishnarajan7/Liova/releases/tag/v\(version)")!
        )
    }

    private func shell(_ tool: String, _ arguments: [String]) throws {
        let status = try Process.runAndWait(URL(filePath: tool), arguments: arguments)
        guard status == 0 else { throw CocoaError(.executableLoad) }
    }

    /// A copy of the built app at `version`, signed with `identity`, in a disk image.
    private func diskImage(version: String, identity: String) throws -> URL {
        let folder = root.appending(path: "dmg-\(UUID())")
        let app = folder.appending(path: "Liova.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try shell("/usr/bin/ditto", [builtApp.path, app.path])
        try shell("/usr/libexec/PlistBuddy", [
            "-c", "Set :CFBundleShortVersionString \(version)", app.appending(path: "Contents/Info.plist").path,
        ])
        try shell("/usr/bin/codesign", [
            "--force", "--preserve-metadata=entitlements,flags,runtime", "-s", identity, app.path,
        ])
        let image = root.appending(path: "Liova-\(version)-\(UUID()).dmg")
        try shell("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", folder.path, "-format", "UDZO", image.path])
        return image
    }

    private func currentApp() throws -> URL {
        let app = root.appending(path: "current/Liova.app")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try shell("/usr/bin/ditto", [builtApp.path, app.path])
        return app
    }

    @Test func acceptsOnlyAnUpdateSignedLikeThisCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let requirement = try CodeSignature.designatedRequirement(ofAppAt: builtApp)
        try #require(!CodeSignature.isAdHoc(requirement), "Build with the \(Self.identity) certificate first")
        let current = try currentApp()
        #expect(UpdateInstaller.inPlaceSupport(for: current) == .supported)
        let installer = UpdateInstaller(workDirectory: root.appending(path: "work"))

        let good = try diskImage(version: "9.9.9", identity: Self.identity)
        let staged = try await installer.prepare(installer: good, release: release("9.9.9"), replacing: current)
        #expect(Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "9.9.9")
        #expect(CodeSignature.isValid(appAt: staged, satisfying: requirement))

        let impostor = try diskImage(version: "9.9.9", identity: "-")
        await #expect(throws: UpdateInstaller.Failure.signatureMismatch) {
            try await installer.prepare(installer: impostor, release: release("9.9.9"), replacing: current)
        }

        await #expect(throws: UpdateInstaller.Failure.wrongApp) {
            try await installer.prepare(installer: good, release: release("9.9.8"), replacing: current)
        }

        // Nothing stays mounted.
        let mounts = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "work").path)
        #expect(!mounts.contains { $0.hasPrefix("mount-") })
    }

    /// The real feed: answers, and anything it lists is well formed.
    @Test func readsLiovasReleasesOnGitHub() async throws {
        let releases = try await GitHubReleaseClient().releases()
        for release in releases {
            #expect(release.pageURL.absoluteString.hasPrefix(GitHubReleaseClient.pagePrefix))
        }
    }
}

import CryptoKit
import Foundation
import os
import Security

/// Downloads, checks and installs a Liova update, without any dependency.
///
/// The trust rule matches what Sparkle relies on for Developer ID apps: an update is only
/// installed in place when its code signature satisfies the running app's designated
/// requirement, which for Liova pins the release certificate. So only whoever holds that
/// certificate's private key can ship an update that installs itself. The installer's
/// SHA-256 is checked too, but it comes from the same place, so it only catches a broken
/// download; the signature is what's trusted.
///
/// An ad-hoc signed build has no certificate to pin, so it can't verify an update. Then the
/// checked download is opened in Finder for the user to install by hand.
public protocol UpdateInstalling: Sendable {
    func inPlaceSupport(for appURL: URL) -> UpdateInstaller.InPlaceSupport
    func download(
        _ release: ReleaseInfo,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(UpdateInstaller.Failure) -> URL
    func prepare(installer: URL, release: ReleaseInfo, replacing currentApp: URL) async throws(UpdateInstaller.Failure)
        -> URL
    func installAfterQuit(staged: URL, replacing currentApp: URL) throws(UpdateInstaller.Failure)
}

public struct UpdateInstaller: UpdateInstalling {
    public enum Failure: Error, Equatable, Sendable {
        case noInstaller
        case tooLarge
        case download(String)
        case checksumMissing
        case checksumMismatch
        case mountFailed
        case appMissing
        /// The app inside isn't Liova, or isn't the version the release says.
        case wrongApp
        case signatureMismatch
        case stagingFailed
        case relaunchFailed

        /// What Settings says when an update fails.
        public var message: String {
            switch self {
            case .noInstaller: "This release has no installer for Liova yet."
            case .tooLarge: "The installer is larger than expected, so it wasn't downloaded."
            case let .download(reason): "The download didn't finish: \(reason)"
            case .checksumMissing: "The release has no checksum to check the download against."
            case .checksumMismatch: "The download was damaged (its checksum doesn't match). Try again."
            case .mountFailed: "The installer couldn't be opened."
            case .appMissing: "The installer doesn't contain Liova."
            case .wrongApp: "The installer contains a different app or version than expected."
            case .signatureMismatch: "The update isn't signed by the same developer as this copy of Liova."
            case .stagingFailed: "The update couldn't be prepared for installing."
            case .relaunchFailed: "Liova couldn't restart to finish the update."
            }
        }
    }

    /// Whether this copy can replace itself.
    public enum InPlaceSupport: Equatable, Sendable {
        case supported
        /// Signed ad-hoc (built from source or an unsigned release): no certificate to pin.
        case adHocBuild
        /// macOS runs this copy from a temporary read-only location (it was opened straight
        /// from the download without being moved to Applications).
        case translocated
        case notWritable
    }

    /// Larger than any Liova installer will plausibly be.
    static let maximumInstallerSize = 300 * 1024 * 1024

    private static let log = Logger(subsystem: "app.liova.Liova", category: "updates")

    /// Where downloads and the prepared app live until the update is installed.
    let workDirectory: URL

    public init(workDirectory: URL? = nil) {
        self.workDirectory = workDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.liova.Liova/Updates", directoryHint: .isDirectory)
    }

    // MARK: - Can this copy update itself?

    public func inPlaceSupport(for appURL: URL) -> InPlaceSupport {
        Self.inPlaceSupport(for: appURL)
    }

    public static func inPlaceSupport(for appURL: URL) -> InPlaceSupport {
        if appURL.path.contains("/AppTranslocation/") {
            return .translocated
        }
        guard let requirement = try? CodeSignature.designatedRequirement(ofAppAt: appURL),
              !CodeSignature.isAdHoc(requirement)
        else { return .adHocBuild }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
              manager.isWritableFile(atPath: appURL.path)
        else { return .notWritable }
        return .supported
    }

    // MARK: - Download

    /// Downloads the release's installer and checks it against the release's checksum.
    /// Returns the checked installer.
    @concurrent public func download(
        _ release: ReleaseInfo,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(Failure) -> URL {
        guard let installer = release.installer else { throw .noInstaller }
        guard let checksumAsset = release.checksum else { throw .checksumMissing }
        guard installer.size <= Self.maximumInstallerSize else { throw .tooLarge }

        let folder = workDirectory.appending(path: release.version.description, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: workDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .download(error.localizedDescription)
        }

        let expected: String
        do {
            let (data, response) = try await URLSession.shared.data(from: checksumAsset.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  let digest = Self.parseChecksum(text)
            else { throw Failure.checksumMissing }
            expected = digest
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .download(error.localizedDescription)
        }

        let destination = folder.appending(path: installer.name)
        do {
            let downloaded = try await FileDownload.run(
                installer.url,
                maximumSize: Self.maximumInstallerSize,
                progress: progress
            )
            try FileManager.default.moveItem(at: downloaded, to: destination)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .download(error.localizedDescription)
        }

        guard let actual = try? Self.sha256(of: destination), actual == expected else {
            try? FileManager.default.removeItem(at: destination)
            throw .checksumMismatch
        }
        Self.log.info("Update \(release.version.description, privacy: .public) downloaded and checksum verified")
        return destination
    }

    // MARK: - Prepare

    /// Opens the installer, checks the app inside is Liova at the release's version and
    /// signed like the app at `currentApp`, and copies it out, ready to swap in.
    @concurrent public func prepare(
        installer: URL,
        release: ReleaseInfo,
        replacing currentApp: URL
    ) async throws(Failure) -> URL {
        let requirement: SecRequirement
        do {
            requirement = try CodeSignature.designatedRequirement(ofAppAt: currentApp)
        } catch {
            throw .signatureMismatch
        }
        guard !CodeSignature.isAdHoc(requirement) else { throw .signatureMismatch }

        let mountPoint = workDirectory.appending(path: "mount-\(UUID().uuidString)", directoryHint: .isDirectory)
        try DiskImage.attach(installer, at: mountPoint)
        defer { DiskImage.detach(mountPoint) }

        let name = currentApp.lastPathComponent
        let candidate = mountPoint.appending(path: name.hasSuffix(".app") ? name : "Liova.app")
        let mounted = FileManager.default.fileExists(atPath: candidate.path)
            ? candidate : mountPoint.appending(path: "Liova.app")
        guard FileManager.default.fileExists(atPath: mounted.path) else { throw .appMissing }
        try Self.check(mounted, isRelease: release, like: currentApp, requirement: requirement)

        let staged = workDirectory
            .appending(path: "staged-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Liova.app")
        do {
            try FileManager.default.createDirectory(
                at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Process.runChecked(URL(filePath: "/usr/bin/ditto"), arguments: [mounted.path, staged.path])
        } catch {
            throw .stagingFailed
        }
        // Checked again where it will be installed from: the copy is what runs.
        try Self.check(staged, isRelease: release, like: currentApp, requirement: requirement)
        Self.log.info("Update \(release.version.description, privacy: .public) verified and staged")
        return staged
    }

    static func check(
        _ app: URL,
        isRelease release: ReleaseInfo,
        like currentApp: URL,
        requirement: SecRequirement
    ) throws(Failure) {
        guard let new = Bundle(url: app), let current = Bundle(url: currentApp),
              new.bundleIdentifier != nil, new.bundleIdentifier == current.bundleIdentifier,
              let shortVersion = new.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppVersion(shortVersion) == release.version
        else { throw .wrongApp }
        guard CodeSignature.isValid(appAt: app, satisfying: requirement) else { throw .signatureMismatch }
    }

    // MARK: - Install

    /// Starts a small helper that waits for this process to quit, swaps the prepared app in
    /// for the current one (putting the old one back if that fails), and opens it. The
    /// caller quits right after.
    public func installAfterQuit(staged: URL, replacing currentApp: URL) throws(Failure) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Paths are passed as arguments, never pasted into the script.
        process.arguments = [
            "-c", Self.swapScript, "liova-update",
            String(ProcessInfo.processInfo.processIdentifier), staged.path, currentApp.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .relaunchFailed
        }
        Self.log.notice("Installing update after quitting")
    }

    /// Waits up to 30 s for Liova to quit, then swaps and relaunches.
    static let swapScript = """
    pid="$1"; new="$2"; app="$3"; waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.2; waited=$((waited + 1))
      [ "$waited" -gt 150 ] && exit 1
    done
    old="$app.previous-$$"
    mv "$app" "$old" || { /usr/bin/open "$app"; exit 1; }
    if mv "$new" "$app"; then
      rm -rf "$old"
    else
      mv "$old" "$app"
    fi
    /usr/bin/open "$app"
    """

    // MARK: - Helpers

    /// The digest from a `shasum -a 256` line ("<hex>  Liova-0.2.0.dmg"), lowercased.
    static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let digest = first.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
        return digest
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import Security

/// Code-signature checks through the Security framework.
enum CodeSignature {
    struct Unsigned: Error {}

    static func designatedRequirement(ofAppAt url: URL) throws -> SecRequirement {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw Unsigned() }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw Unsigned()
        }
        return requirement
    }

    /// An ad-hoc signature's requirement names only its exact code hash ("cdhash H\"…\""),
    /// so no other build can ever satisfy it.
    static func isAdHoc(_ requirement: SecRequirement) -> Bool {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return true }
        return !(text as String).contains("certificate")
    }

    /// The whole bundle, every architecture and everything nested in it, unmodified and
    /// signed in a way that satisfies `requirement`.
    static func isValid(appAt url: URL, satisfying requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// Mounting and unmounting the installer with `hdiutil`.
enum DiskImage {
    static func attach(_ image: URL, at mountPoint: URL) throws(UpdateInstaller.Failure) {
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let status = try Process.runAndWait(
                URL(filePath: "/usr/bin/hdiutil"),
                arguments: [
                    "attach",
                    image.path,
                    "-nobrowse",
                    "-readonly",
                    "-noautoopen",
                    "-quiet",
                    "-mountpoint",
                    mountPoint.path,
                ]
            )
            guard status == 0 else { throw UpdateInstaller.Failure.mountFailed }
        } catch {
            throw .mountFailed
        }
    }

    static func detach(_ mountPoint: URL) {
        _ = try? Process.runAndWait(
            URL(filePath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path, "-force", "-quiet"]
        )
        try? FileManager.default.removeItem(at: mountPoint)
    }
}

extension Process {
    /// Runs a tool to completion; throws if it fails.
    @discardableResult
    static func runChecked(_ tool: URL, arguments: [String]) throws -> Int32 {
        let status = try runAndWait(tool, arguments: arguments)
        guard status == 0 else { throw CocoaError(.executableLoad) }
        return status
    }

    static func runAndWait(_ tool: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// One file download with progress, refused if it grows past a size limit.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let maximumSize: Int
    private var continuation: CheckedContinuation<URL, any Error>?
    private let lock = NSLock()

    private init(maximumSize: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.maximumSize = maximumSize
        self.progress = progress
    }

    static func run(
        _ url: URL,
        maximumSize: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let delegate = FileDownload(maximumSize: maximumSize, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": GitHubReleaseClient.userAgent]
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        if written > maximumSize {
            downloadTask.cancel()
            finish(.failure(UpdateInstaller.Failure.tooLarge))
            return
        }
        if expected > 0 {
            progress(min(Double(written) / Double(expected), 1))
        }
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status == 200 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // The file is deleted when this returns, so move it somewhere it stays.
        let kept = FileManager.default.temporaryDirectory.appending(path: "liova-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        }
    }
}

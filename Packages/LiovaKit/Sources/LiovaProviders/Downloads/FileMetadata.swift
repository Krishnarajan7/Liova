import Foundation

/// File-system metadata only: sizes, dates and existence. Never opens a file.
enum FileMetadata {
    /// Changes whenever a file is rewritten.
    struct Stamp: Equatable {
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }

    static func stamp(atPath path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = info.st_mtimespec
        return Stamp(size: Int64(info.st_size), seconds: modified.tv_sec, nanoseconds: modified.tv_nsec)
    }

    static func size(atPath path: String, isBundle: Bool) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG {
            return Int64(info.st_size)
        }
        guard type == S_IFDIR, isBundle else { return nil }
        // A Safari `.download` bundle: the sum of the sizes of the files directly inside it.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.reduce(Int64(0)) { total, name in
            var child = stat()
            let childPath = (path as NSString).appendingPathComponent(name)
            guard lstat(childPath, &child) == 0, child.st_mode & S_IFMT == S_IFREG else { return total }
            return total + Int64(child.st_size)
        }
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

import Foundation

/// The one module that writes or deletes anything in `~/Library/Application Support/Sesame/`.
/// Every name taken here is a plain file name inside the folder: a name with a slash, `.` or `..` is refused.
public enum SesameFolder {
    /// Why a call was refused.
    public enum Failure: Error, Equatable {
        case notAPlainFileName(String)
        case systemCall(String, Int32)
    }

    /// Where a name lives: the Sesame folder itself, its `models/` subfolder (the model files and their
    /// `.partial`), or its `logs/` subfolder. A name is a plain file name in any place.
    public enum Place: Sendable {
        case folder, models, logs
    }

    /// A name ending in this is a log and never grows past `logCap` bytes.
    static let logSuffix = ".log"
    public static let logCap = 1_048_576

    /// `~/Library/Application Support/Sesame`. The base is the `HOME` environment variable when it is set
    /// and not empty (the kit sets it; `NSHomeDirectory()` ignores it for apps started by Launch Services),
    /// else `NSHomeDirectory()`. Read at each call.
    public static var url: URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Sesame", isDirectory: true)
    }

    /// The home every path here starts from, read from `HOME` at each call.
    private static var homeURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return URL(fileURLWithPath: home ?? NSHomeDirectory(), isDirectory: true)
    }

    /// The two folders under `Library/Caches` that Sesame and its helper make. These two names are the only ones
    /// `deleteCaches()` can reach; nothing is taken from a caller.
    enum CachePlace: String, CaseIterable {
        case app = "app.sesame.Sesame"
        case helper = "SesameHelper"

        var url: URL {
            SesameFolder.homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(rawValue, isDirectory: true)
        }
    }

    /// Removes `Library/Caches/app.sesame.Sesame` and `Library/Caches/SesameHelper` whole. A folder that is not
    /// there is no error.
    public static func deleteCaches() throws {
        for place in CachePlace.allCases {
            do { try FileManager.default.removeItem(at: place.url) } catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }

    /// Makes the folder if it is missing and sets its mode to 0700 (also when it already exists).
    public static func create() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// `~/Library/Application Support/Sesame/models`.
    public static var modelsURL: URL { url.appendingPathComponent("models", isDirectory: true) }

    /// Makes `models/` (and the Sesame folder) if missing, both with mode 0700.
    public static func createModels() throws {
        try create()
        try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: modelsURL.path)
    }

    /// `~/Library/Application Support/Sesame/logs`.
    public static var logsURL: URL { url.appendingPathComponent("logs", isDirectory: true) }

    /// Makes `logs/` (and the Sesame folder) if missing, both with mode 0700.
    public static func createLogs() throws {
        try create()
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsURL.path)
    }

    /// Writes `data` to a temp file in the folder, then renames it over `name`: the final name holds the old
    /// bytes or the new bytes whole, and no temp file is left behind.
    public static func write(_ data: Data, to name: String, in place: Place = .folder) throws {
        let target = try file(name, in: place)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            try move(temp.path, to: target.path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Adds `data` to the end of `name` (made when missing). A log name that would pass `logCap` starts over
    /// with the newest bytes of `data` (up to `logCap`); this module never reads a file back.
    public static func append(_ data: Data, to name: String, in place: Place = .folder) throws {
        let target = try file(name, in: place)
        let existing = (try? size(of: name, in: place)) ?? 0
        if name.hasSuffix(logSuffix), existing + data.count > logCap {
            try write(Data(data.suffix(logCap)), to: name, in: place)
            return
        }
        guard let stream = OutputStream(toFileAtPath: target.path, append: true) else {
            throw Failure.systemCall("open for append", errno)
        }
        stream.open()
        defer { stream.close() }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { raw in
                stream.write(raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, maxLength: data.count - offset)
            }
            if count <= 0 { throw stream.streamError ?? Failure.systemCall("write", errno) }
            offset += count
        }
    }

    /// Renames a file inside the folder; an existing `new` is replaced.
    public static func rename(_ old: String, to new: String, in place: Place = .folder) throws {
        try move(try file(old, in: place).path, to: try file(new, in: place).path)
    }

    public static func delete(_ name: String, in place: Place = .folder) throws {
        try FileManager.default.removeItem(at: try file(name, in: place))
    }

    /// What `IndexStore` keeps in the folder: the index, its write-ahead log and shared memory, and the lock file.
    static let indexFiles = ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "index.lock"]

    /// Deletes every index file that is there. The caller closes the store first.
    public static func deleteIndexFiles() throws {
        for name in indexFiles {
            do { try delete(name) } catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }

    /// Sets mode 0600 on every index file that is there (SQLite makes them with the umask, 0644).
    public static func restrictIndexFiles() throws {
        for name in indexFiles {
            let path = try file(name, in: .folder).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    /// Bytes in `name`.
    public static func size(of name: String, in place: Place = .folder) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: try file(name, in: place).path)
        return (attributes[.size] as? Int) ?? 0
    }

    private static func file(_ name: String, in place: Place) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw Failure.notAPlainFileName(name)
        }
        let folder: URL
        switch place {
        case .folder: folder = url
        case .models: folder = modelsURL
        case .logs: folder = logsURL
        }
        return folder.appendingPathComponent(name)
    }

    private static func move(_ from: String, to: String) throws {
        if Darwin.rename(from, to) != 0 { throw Failure.systemCall("rename", errno) }
    }
}

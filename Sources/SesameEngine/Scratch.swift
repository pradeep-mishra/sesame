import Darwin
import Foundation

/// The helper's own scratch folder, `$TMPDIR/Sesame-<pid>` (design section 1): the preview PNGs it makes, mode 0600 in
/// a folder of mode 0700. It is removed at exit, and a folder whose process is gone is removed at the next start. The
/// app deletes a PNG after loading it. One of the three modules allowed to write or delete (design section 12).
public final class Scratch: @unchecked Sendable {
    private let lock = NSLock()
    private let folder: URL
    private var made = false

    /// `$TMPDIR` as this process sees it, else the system's temporary folder.
    private static var base: URL {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: tmp, isDirectory: true)
    }

    private static let prefix = "Sesame-"

    public init() {
        folder = Self.base.appendingPathComponent("\(Self.prefix)\(getpid())", isDirectory: true)
    }

    /// Writes `data` as a new file `name` (a plain file name) in the folder, made on first use, and returns its path.
    public func write(_ data: Data, name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        if !made {
            try fileManager.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            made = true
        }
        let target = folder.appendingPathComponent(name)
        try? fileManager.removeItem(at: target)
        guard fileManager.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // The umask may have cleared bits the attribute asked for; say the mode again.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target.path
    }

    /// Deletes one file this scratch folder made.
    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard URL(fileURLWithPath: path).deletingLastPathComponent().path == folder.path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Removes the whole folder: at exit.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder)
        made = false
    }

    /// Removes every `Sesame-<pid>` folder in the temporary folder whose process is no longer running.
    public static func removeStale() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), pid > 0, pid != getpid() else { continue }
            if kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
            }
        }
    }
}

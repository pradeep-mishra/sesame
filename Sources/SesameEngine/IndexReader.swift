import Foundation
import SQLite3

/// The number of files of one kind in one status.
public struct KindStatusCount: Equatable, Sendable {
    public let kind: String
    public let status: String
    public let files: Int
}

/// A passage that holds a typed phrase, with its file's path and kind.
public struct KeywordHit: Equatable, Sendable {
    public let passageID: Int64
    public let path: String
    public let kind: String
}

/// A file Sesame could not read: its path, its name (the last path component) and why.
public struct UnreadableFile: Equatable, Sendable {
    public let path: String
    public let name: String
    public let reason: String
}

/// Where a passage sits in its file as stored: an audio window's seconds, a frame's second, a page's number or a chunk's offsets.
public struct PassageSpot: Equatable, Sendable {
    public let source: String
    public let start: Double
    public let end: Double
}

/// The app's one read connection to `index.sqlite` (design section 1). Opens read-only, so a second writer
/// fails at the API. A missing file is zero counts, an empty keyword search and no meta; every call tries the
/// open again while there is no connection, so rows show up once the store makes the file. No call throws.
public final class IndexReader: @unchecked Sendable {
    private let mutex = NSLock()
    private var db: OpaquePointer?

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Device and inode of the file `db` was opened on.
    private var openedFile: FileIdentity?
    /// The path `db` was opened on; replaced or deleted is judged on this path, not on where the index would be now.
    private var openedPath: String?

    public init() {}

    deinit { close() }

    public func fileCount() -> Int {
        Int(firstRow("SELECT count(*) FROM files") { sqlite3_column_int64($0, 0) } ?? 0)
    }

    public func passageCount() -> Int {
        Int(firstRow("SELECT count(*) FROM passages") { sqlite3_column_int64($0, 0) } ?? 0)
    }

    /// Ids of the passages whose `name` or `body` holds the whole text as a phrase (the `fts` rowid is the
    /// passage id). The text is quoted, so no character of it is FTS5 syntax.
    public func keywordSearch(_ query: String) -> [Int64] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return rows("SELECT rowid FROM fts WHERE fts MATCH ?", bind: { statement in
            sqlite3_bind_text(statement, 1, phrase, -1, sqliteTransient)
        }, read: { sqlite3_column_int64($0, 0) })
    }

    /// One value per passage whose `name` or `body` holds the whole text as a phrase, by passage id, with its file's
    /// path and kind. The text is quoted, so no character of it is FTS5 syntax. No `Visible` is applied.
    public func keywordHits(_ query: String) -> [KeywordHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return rows("""
            SELECT p.id, f.path, f.kind FROM fts JOIN passages p ON p.id = fts.rowid JOIN files f ON f.id = p.file_id
            WHERE fts MATCH ? ORDER BY p.id
            """, bind: { statement in
            sqlite3_bind_text(statement, 1, phrase, -1, sqliteTransient)
        }, read: { statement in
            KeywordHit(
                passageID: sqlite3_column_int64(statement, 0),
                path: String(cString: sqlite3_column_text(statement, 1)),
                kind: String(cString: sqlite3_column_text(statement, 2)))
        })
    }

    public func meta(_ key: String) -> String? {
        firstRow("SELECT value FROM meta WHERE key = ?", bind: { statement in
            sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        }, read: { sqlite3_column_text($0, 0).map { String(cString: $0) } }) ?? nil
    }

    /// The 768 numbers of a passage, or nil for a passage with no vector or an id nobody has.
    public func vector(ofPassage id: Int64) -> [Float]? {
        let blob: Data?? = firstRow("SELECT vec FROM passages WHERE id = ?", bind: { statement in
            sqlite3_bind_int64(statement, 1, id)
        }, read: { statement -> Data? in
            guard sqlite3_column_type(statement, 0) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, 0) else {
                return nil
            }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        })
        guard let data = blob ?? nil, data.count == Schema.vectorLength * 2 else { return nil }
        return (0..<Schema.vectorLength).map { index in
            let bits = UInt16(data[data.startIndex + 2 * index]) | UInt16(data[data.startIndex + 2 * index + 1]) << 8
            return Float(Float16(bitPattern: bits))
        }
    }

    /// Every passage that has a vector, with its file's path and kind: what `Search` loads once.
    /// Rows with a vector of the wrong length are left out.
    public func vectoredPassages() -> [VectoredPassage] {
        rows("""
            SELECT p.id, f.path, f.kind, p.modality, p.vec FROM passages p JOIN files f ON f.id = p.file_id
            WHERE p.vec IS NOT NULL ORDER BY p.id
            """, read: { statement -> VectoredPassage? in
            guard sqlite3_column_type(statement, 4) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, 4),
                  sqlite3_column_bytes(statement, 4) == Schema.vectorLength * 2
            else { return nil }
            let raw = bytes.assumingMemoryBound(to: UInt8.self)
            let vector = (0..<Schema.vectorLength).map { index in
                Float16(bitPattern: UInt16(raw[2 * index]) | UInt16(raw[2 * index + 1]) << 8)
            }
            return VectoredPassage(
                id: sqlite3_column_int64(statement, 0),
                path: String(cString: sqlite3_column_text(statement, 1)),
                kind: String(cString: sqlite3_column_text(statement, 2)),
                modality: String(cString: sqlite3_column_text(statement, 3)),
                vector: vector)
        }).compactMap { $0 }
    }

    /// The path of the file a passage belongs to (a passage without a vector too), or nil for an id nobody has.
    public func pathForPassage(_ id: Int64) -> String? {
        firstRow("SELECT f.path FROM passages p JOIN files f ON f.id = p.file_id WHERE p.id = ?", bind: { statement in
            sqlite3_bind_int64(statement, 1, id)
        }, read: { String(cString: sqlite3_column_text($0, 0)) })
    }

    /// What a passage stored for its place in the file, or nil for an id nobody has.
    public func passageSpot(_ id: Int64) -> PassageSpot? {
        firstRow("SELECT source, start, \"end\" FROM passages WHERE id = ?", bind: { statement in
            sqlite3_bind_int64(statement, 1, id)
        }, read: { statement in
            PassageSpot(
                source: String(cString: sqlite3_column_text(statement, 0)),
                start: sqlite3_column_double(statement, 1),
                end: sqlite3_column_double(statement, 2))
        })
    }

    public func passageText(_ id: Int64) -> String? {
        firstRow("SELECT body FROM fts WHERE rowid = ?", bind: { statement in
            sqlite3_bind_int64(statement, 1, id)
        }, read: { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        })
    }

    /// How many files there are of each kind in each status; a pair with no files is left out.
    public func statusCounts() -> [KindStatusCount] {
        rows("SELECT kind, status, count(*) FROM files GROUP BY kind, status", read: { statement in
            KindStatusCount(
                kind: String(cString: sqlite3_column_text(statement, 0)),
                status: String(cString: sqlite3_column_text(statement, 1)),
                files: Int(sqlite3_column_int64(statement, 2)))
        })
    }

    /// The path of the `done` file whose passage has the greatest id (passage ids are never reused), or nil with none.
    public func lastIndexedPath() -> String? {
        firstRow("""
            SELECT f.path FROM passages p JOIN files f ON f.id = p.file_id
            WHERE f.status = 'done' ORDER BY p.id DESC LIMIT 1
            """, read: { String(cString: sqlite3_column_text($0, 0)) })
    }

    /// The files that ended `could_not_read` (with their stored reason) or `needs_permission` ("needs permission"),
    /// sorted by path; empty with no index file.
    public func couldNotRead() -> [UnreadableFile] {
        rows("""
            SELECT path, status, reason FROM files
            WHERE status IN ('could_not_read', 'needs_permission') ORDER BY path
            """, read: { statement in
            let path = String(cString: sqlite3_column_text(statement, 0))
            let needsPermission = String(cString: sqlite3_column_text(statement, 1)) == "needs_permission"
            let stored = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            return UnreadableFile(
                path: path, name: (path as NSString).lastPathComponent,
                reason: needsPermission ? "needs permission" : (stored ?? "could not read"))
        })
    }

    /// Closes the connection; the next call opens it again.
    public func close() {
        mutex.lock()
        defer { mutex.unlock() }
        sqlite3_close_v2(db)
        db = nil
        openedFile = nil
        openedPath = nil
    }

    // MARK: helpers

    /// The connection, opened now if there is none and the file exists.
    /// A connection on a file that was deleted or replaced is dropped here, so the next open follows the path.
    private func connection() -> OpaquePointer? {
        if let db, let openedPath {
            if Self.identity(of: openedPath) == openedFile { return db }
            sqlite3_close_v2(db)
            self.db = nil
            openedFile = nil
            self.openedPath = nil
        }
        let path = Schema.indexPath
        guard let onDisk = Self.identity(of: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else {
            sqlite3_close_v2(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 1000)
        db = handle
        openedFile = onDisk
        openedPath = path
        return handle
    }

    private static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        return stat(path, &info) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }

    /// Every row of `sql`, each read by `read`; empty when there is no file, no table or no match.
    private func rows<T>(
        _ sql: String, bind: (OpaquePointer) -> Void = { _ in }, read: (OpaquePointer) -> T
    ) -> [T] {
        mutex.lock()
        defer { mutex.unlock() }
        guard let db = connection() else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var found: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(read(statement)) }
        return found
    }

    private func firstRow<T>(
        _ sql: String, bind: (OpaquePointer) -> Void = { _ in }, read: (OpaquePointer) -> T
    ) -> T? {
        rows(sql, bind: bind, read: read).first
    }
}

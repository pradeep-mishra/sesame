import Foundation
import SQLite3

/// The one writer of `index.sqlite` (design section 1). Finds the file in the Sesame folder (HOME read at
/// call time), makes the file but never the folder, and fails to open while another store holds it.
/// Every call commits at once, so the app's `IndexReader` sees each row as soon as it is written.
public final class IndexStore: @unchecked Sendable {
    private let mutex = NSLock()
    private var db: OpaquePointer?
    /// Holds an exclusive SQLite lock on the side file for as long as this store is open.
    private var exclusion: OpaquePointer?

    public init() throws {
        exclusion = try Self.takeExclusion()
        do {
            db = try Self.openIndex()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// Adds a `files` row and returns its id.
    public func addFile(
        path: String, kind: String, size: Int64, mtimeNs: Int64, inode: Int64, device: Int64, status: String
    ) throws -> Int64 {
        try withDB { db in
            try Self.run(db, """
                INSERT INTO files (path, kind, size, mtime_ns, inode, device, status) VALUES (?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                sqlite3_bind_text(statement, 1, path, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, kind, -1, sqliteTransient)
                sqlite3_bind_int64(statement, 3, size)
                sqlite3_bind_int64(statement, 4, mtimeNs)
                sqlite3_bind_int64(statement, 5, inode)
                sqlite3_bind_int64(statement, 6, device)
                sqlite3_bind_text(statement, 7, status, -1, sqliteTransient)
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Adds a `passages` row and its `fts` row (rowid = passage id) in one transaction and returns the id.
    /// `vector` is 768 numbers, stored as 768 little-endian half floats (1,536 bytes), or nil for NULL.
    public func addPassage(
        fileID: Int64, source: String, start: Double, end: Double, modality: String, vector: [Float]?,
        name: String, body: String
    ) throws -> Int64 {
        if let vector, vector.count != Schema.vectorLength { throw IndexError.badVector(vector.count) }
        let blob = vector.map(Self.halfFloats)
        return try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                let id = try Self.insertPassage(
                    db, fileID: fileID, source: source, start: start, end: end, modality: modality, blob: blob,
                    name: name, body: body)
                try Self.exec(db, "COMMIT")
                return id
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// The `passages` row and its `fts` row, inside a transaction the caller holds.
    private static func insertPassage(
        _ db: OpaquePointer, fileID: Int64, source: String, start: Double, end: Double, modality: String,
        blob: Data?, name: String, body: String
    ) throws -> Int64 {
        try run(db, """
            INSERT INTO passages (file_id, source, start, "end", modality, vec) VALUES (?, ?, ?, ?, ?, ?)
            """) { statement in
            sqlite3_bind_int64(statement, 1, fileID)
            sqlite3_bind_text(statement, 2, source, -1, sqliteTransient)
            sqlite3_bind_double(statement, 3, start)
            sqlite3_bind_double(statement, 4, end)
            sqlite3_bind_text(statement, 5, modality, -1, sqliteTransient)
            if let blob {
                blob.withUnsafeBytes {
                    _ = sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), sqliteTransient)
                }
            } else {
                sqlite3_bind_null(statement, 6)
            }
        }
        let id = sqlite3_last_insert_rowid(db)
        try run(db, "INSERT INTO fts (rowid, name, body) VALUES (?, ?, ?)") { statement in
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_bind_text(statement, 2, name, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, body, -1, sqliteTransient)
        }
        return id
    }

    /// Sets a `meta` fact, replacing any earlier value of the key.
    public func setMeta(_ key: String, _ value: String) throws {
        try withDB { db in
            try Self.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") { statement in
                sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
            }
        }
    }

    /// What one `reconcile` changed.
    public struct ReconcileOutcome: Equatable, Sendable {
        public var added = 0
        public var updated = 0
        public var removed = 0
    }

    /// Makes the `files` rows match `found` in one transaction. A found file is matched to a row first by its path
    /// with the same size, modified time, inode and kind (untouched; only a changed device number is written), then by device, inode, size,
    /// modified time and kind alone (a move or rename, also a swap or chain of names: the row keeps its id, status and
    /// passages, takes the new path, and its `name` passage is rewritten for the new file and folder names), then by
    /// path alone (a changed file: reset to `pending`, its passages go, its id stays); a found file with no row is new
    /// and `pending`. A row nothing matched goes with its passages, unless it is one of `unreadable` or below one of
    /// them (a folder or file the walk could not look at: the row stays as it is). The same transaction sets
    /// `meta.vector_source` when it is absent and `meta.walk_done_at` to `walkDoneAt`. A path in `found` twice counts
    /// once. A file of a kind in `kindsOff` (`files.kind` words) gets no new row, and a row of such a kind that matches
    /// a changed file stays as it is until the kind is on again; a row whose file is gone is still removed.
    public func reconcile(
        _ found: [(file: WalkedFile, device: Int64)], unreadable: [String], vectorSource: String, walkDoneAt: String,
        kindsOff: Set<String> = []
    ) throws -> ReconcileOutcome {
        let unreadablePaths = Set(unreadable.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        // True when the path is an unreadable path or has one for a parent folder, at any depth.
        func isUnder(_ path: String) -> Bool {
            var current = Substring(path)
            while !current.isEmpty {
                if unreadablePaths.contains(String(current)) { return true }
                guard let slash = current.lastIndex(of: "/") else { return false }
                current = current[..<slash]
            }
            return unreadablePaths.contains("/")
        }
        return try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                var rows: [KnownFile] = []
                try Self.forEachRow(db, "SELECT id, path, size, mtime_ns, inode, device, kind FROM files") { statement in
                    rows.append(KnownFile(
                        id: sqlite3_column_int64(statement, 0), path: String(cString: sqlite3_column_text(statement, 1)),
                        size: sqlite3_column_int64(statement, 2), mtimeNs: sqlite3_column_int64(statement, 3),
                        inode: sqlite3_column_int64(statement, 4), device: sqlite3_column_int64(statement, 5),
                        kind: String(cString: sqlite3_column_text(statement, 6))))
                }
                var byPath: [String: KnownFile] = [:]
                var byIdentity: [FileIdentity: [KnownFile]] = [:]
                for row in rows {
                    byPath[row.path] = row
                    byIdentity[row.identity, default: []].append(row)
                }
                var seen = Set<String>()
                let files = found.filter { seen.insert($0.file.path).inserted }
                let identities = files.map {
                    FileIdentity(
                        size: $0.file.size, mtimeNs: $0.file.mtimeNs, inode: Int64(bitPattern: $0.file.inode),
                        device: $0.device, kind: $0.file.kind)
                }
                var claimed = Set<Int64>()
                var unmatched: [Int] = []
                // 1. Same path, same file. The device number need not match here (a drive that came back as another
                // device is the same file); the row takes the new number so a later move still finds it.
                var remounted: [(id: Int64, device: Int64)] = []
                for (index, entry) in files.enumerated() {
                    let identity = identities[index]
                    if let row = byPath[entry.file.path], row.size == identity.size, row.mtimeNs == identity.mtimeNs,
                       row.inode == identity.inode, row.kind == identity.kind {
                        claimed.insert(row.id)
                        if row.device != identity.device { remounted.append((row.id, identity.device)) }
                    } else {
                        unmatched.append(index)
                    }
                }
                // 2. Same file, another path. A row under an unreadable path that the walk did not reach stays put.
                var moves: [(row: KnownFile, entry: (file: WalkedFile, device: Int64))] = []
                var rest: [Int] = []
                for index in unmatched {
                    let entry = files[index]
                    let row = byIdentity[identities[index]]?.first {
                        !claimed.contains($0.id) && (seen.contains($0.path) || !isUnder($0.path))
                    }
                    if let row {
                        claimed.insert(row.id)
                        moves.append((row, entry))
                    } else {
                        rest.append(index)
                    }
                }
                // 3. Same path, another file: changed. Else new.
                var changes: [(row: KnownFile, entry: (file: WalkedFile, device: Int64))] = []
                var adds: [(file: WalkedFile, device: Int64)] = []
                for index in rest {
                    let entry = files[index]
                    if let row = byPath[entry.file.path], !claimed.contains(row.id) {
                        claimed.insert(row.id)
                        if !kindsOff.contains(entry.file.kind) { changes.append((row, entry)) }
                    } else if !kindsOff.contains(entry.file.kind) {
                        adds.append(entry)
                    }
                }
                var outcome = ReconcileOutcome()
                for row in rows where !claimed.contains(row.id) {
                    if !seen.contains(row.path) && isUnder(row.path) { continue }
                    try Self.deletePassages(db, fileID: row.id)
                    try Self.run(db, "DELETE FROM files WHERE id = ?") { sqlite3_bind_int64($0, 1, row.id) }
                    outcome.removed += 1
                }
                for (id, device) in remounted {
                    try Self.run(db, "UPDATE files SET device = ? WHERE id = ?") { statement in
                        sqlite3_bind_int64(statement, 1, device)
                        sqlite3_bind_int64(statement, 2, id)
                    }
                }
                // A swap or chain of names would meet UNIQUE(path) halfway, so every moved row steps aside first.
                for move in moves {
                    try Self.run(db, "UPDATE files SET path = ? WHERE id = ?") { statement in
                        sqlite3_bind_text(statement, 1, "\u{1}moving \(move.row.id)", -1, sqliteTransient)
                        sqlite3_bind_int64(statement, 2, move.row.id)
                    }
                }
                for move in moves {
                    try Self.run(db, "UPDATE files SET path = ? WHERE id = ?") { statement in
                        sqlite3_bind_text(statement, 1, move.entry.file.path, -1, sqliteTransient)
                        sqlite3_bind_int64(statement, 2, move.row.id)
                    }
                    try Self.run(db, "UPDATE fts SET name = ? WHERE rowid IN (SELECT id FROM passages WHERE file_id = ? AND source = 'name')") { statement in
                        sqlite3_bind_text(statement, 1, PhotoReader.nameWords(for: move.entry.file.path), -1, sqliteTransient)
                        sqlite3_bind_int64(statement, 2, move.row.id)
                    }
                }
                for change in changes {
                    let (row, file, device) = (change.row, change.entry.file, change.entry.device)
                    try Self.deletePassages(db, fileID: row.id)
                    try Self.run(db, """
                        UPDATE files SET kind = ?, size = ?, mtime_ns = ?, inode = ?, device = ?,
                            status = 'pending', reason = NULL, read_to = NULL, tries = 0 WHERE id = ?
                        """) { statement in
                        sqlite3_bind_text(statement, 1, file.kind, -1, sqliteTransient)
                        sqlite3_bind_int64(statement, 2, file.size)
                        sqlite3_bind_int64(statement, 3, file.mtimeNs)
                        sqlite3_bind_int64(statement, 4, Int64(bitPattern: file.inode))
                        sqlite3_bind_int64(statement, 5, device)
                        sqlite3_bind_int64(statement, 6, row.id)
                    }
                    outcome.updated += 1
                }
                for (file, device) in adds {
                    try Self.run(db, """
                        INSERT INTO files (path, kind, size, mtime_ns, inode, device, status)
                        VALUES (?, ?, ?, ?, ?, ?, 'pending')
                        """) { statement in
                        sqlite3_bind_text(statement, 1, file.path, -1, sqliteTransient)
                        sqlite3_bind_text(statement, 2, file.kind, -1, sqliteTransient)
                        sqlite3_bind_int64(statement, 3, file.size)
                        sqlite3_bind_int64(statement, 4, file.mtimeNs)
                        sqlite3_bind_int64(statement, 5, Int64(bitPattern: file.inode))
                        sqlite3_bind_int64(statement, 6, device)
                    }
                    outcome.added += 1
                }
                try Self.run(db, "INSERT OR IGNORE INTO meta (key, value) VALUES ('vector_source', ?)") { statement in
                    sqlite3_bind_text(statement, 1, vectorSource, -1, sqliteTransient)
                }
                try Self.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('walk_done_at', ?)") { statement in
                    sqlite3_bind_text(statement, 1, walkDoneAt, -1, sqliteTransient)
                }
                try Self.exec(db, "COMMIT")
                return outcome
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    // MARK: photo batches

    /// A `pending` (or, for a long file, `partial`) row as the reader needs it: where it is and what it looked like when
    /// it was walked. Named for photos, which came first; a PDF is one too.
    public struct PendingPhoto: Equatable, Sendable {
        public let id: Int64
        public let path: String
        public let size: Int64
        public let mtimeNs: Int64
        public let inode: UInt64
        /// The attempt marker: how many reads of this file started and never ended (a death), 0 to 2.
        public let tries: Int
        /// The row's `reason`: a hint (`hint:solo`, `hint:memory`) on a `pending` row, else nil.
        public let reason: String?
        /// `photo` or `pdf`.
        public let kind: String
        /// The last page already stored (a `partial` file), else nil.
        public let readTo: Int?
    }

    /// The hint that makes a `pending` photo the first to be read, alone.
    public static let soloHint = "hint:solo"
    /// The hint left by a memory trip during a solo read.
    public static let memoryHint = "hint:memory"

    /// Up to `limit` `pending` photos, a `hint:solo` photo first, then newest first (design section 3), leaving out
    /// the ids in `excluding`.
    public func pendingPhotos(limit: Int, excluding: Set<Int64> = []) throws -> [PendingPhoto] {
        try pendingFiles(kind: "photo", limit: limit, excluding: excluding)
    }

    /// Up to `limit` files that still need reading (`pending`, or `partial` for the next step of a long one), of one `kind`
    /// or, with nil, of every kind that has a reader. A `hint:solo` file comes first, then every `pending` file (the first
    /// step of each) and only after them the `partial` ones (the later steps), each group newest first. A kind in
    /// `excludingKinds` is left out.
    public func pendingFiles(
        kind: String? = nil, limit: Int, excluding: Set<Int64> = [], excludingKinds: Set<String> = []
    ) throws -> [PendingPhoto] {
        try withDB { db in
            let skip = excluding.isEmpty ? "" : "AND id NOT IN (\(excluding.map(String.init).joined(separator: ",")))"
            let kinds = (kind.map { [$0] } ?? Walker.readerKinds).filter { !excludingKinds.contains($0) }
                .map { "'\($0)'" }.joined(separator: ",")
            var found: [PendingPhoto] = []
            try Self.forEachRow(db, """
                SELECT id, path, size, mtime_ns, inode, tries, reason, kind, read_to FROM files
                WHERE status IN ('pending', 'partial') AND kind IN (\(kinds)) \(skip)
                ORDER BY COALESCE(reason = '\(Self.soloHint)', 0) DESC, status = 'partial', mtime_ns DESC, id LIMIT \(max(limit, 0))
                """) { statement in
                found.append(PendingPhoto(
                    id: sqlite3_column_int64(statement, 0), path: String(cString: sqlite3_column_text(statement, 1)),
                    size: sqlite3_column_int64(statement, 2), mtimeNs: sqlite3_column_int64(statement, 3),
                    inode: UInt64(bitPattern: sqlite3_column_int64(statement, 4)),
                    tries: Int(sqlite3_column_int64(statement, 5)),
                    reason: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                    kind: String(cString: sqlite3_column_text(statement, 7)),
                    readTo: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 8))))
            }
            return found
        }
    }

    /// Starts an attempt: adds 1 to `tries` of each file of a unit, in one committed transaction, before any is read.
    /// Only a death leaves the marker; `completePhoto` and `markCouldNotRead` clear it and `endAttempt` puts it back.
    public func beginAttempt(_ files: [PendingPhoto]) throws {
        try changeTries(files, by: "tries + 1", only: "")
    }

    /// Puts the marker of `beginAttempt` back for the files of a unit that were not written (skipped, deferred,
    /// changed under the read): subtracts 1 from `tries` where it is above 0, in one transaction. A file that
    /// `completePhoto`, `markCouldNotRead` or `markNeedsPermission` wrote already holds 0 and is left alone.
    public func endAttempt(_ files: [PendingPhoto]) throws {
        try changeTries(files, by: "tries - 1", only: "AND tries > 0")
    }

    /// What a memory trip leaves on the files of the unit being read, in one committed transaction, by each file's
    /// `reason` as it was listed: none becomes `hint:solo` with `tries` 0 (a first trip spends no try); `hint:solo`
    /// becomes `hint:memory` with `tries` as the solo read's marker left it; `hint:memory` stays. Only a row that is
    /// still `pending` is changed, and writing the same trip twice changes nothing more.
    public func recordMemoryTrip(_ files: [PendingPhoto]) throws {
        let first = files.filter { $0.reason != Self.soloHint && $0.reason != Self.memoryHint }.map { String($0.id) }
        let solo = files.filter { $0.reason == Self.soloHint }.map { String($0.id) }
        guard !first.isEmpty || !solo.isEmpty else { return }
        try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                if !first.isEmpty {
                    try Self.exec(db, """
                        UPDATE files SET reason = '\(Self.soloHint)', tries = 0
                        WHERE status = 'pending' AND id IN (\(first.joined(separator: ",")))
                        """)
                }
                if !solo.isEmpty {
                    try Self.exec(db, """
                        UPDATE files SET reason = '\(Self.memoryHint)'
                        WHERE status = 'pending' AND id IN (\(solo.joined(separator: ",")))
                        """)
                }
                try Self.exec(db, "COMMIT")
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    private func changeTries(_ files: [PendingPhoto], by expression: String, only condition: String) throws {
        guard !files.isEmpty else { return }
        try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                try Self.exec(db, """
                    UPDATE files SET tries = \(expression)
                    WHERE id IN (\(files.map { String($0.id) }.joined(separator: ","))) \(condition)
                    """)
                try Self.exec(db, "COMMIT")
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// One transaction for one photo: its `name` passage (words only, no vector), its `image` passage (the vector and
    /// the OCR text as the keyword body) and `status = done`, so the file is all-new or all-old to any reader. Writes
    /// nothing and returns false when the row is no longer the `pending` row that was read (a reconcile changed it).
    public func completePhoto(_ file: PendingPhoto, nameWords: String, ocrText: String, vector: [Float]) throws -> Bool {
        guard vector.count == Schema.vectorLength else { throw IndexError.badVector(vector.count) }
        // A NaN or infinite component would poison every search score: nothing is stored, the file is damaged.
        guard vector.allSatisfy(\.isFinite) else { return try markCouldNotRead(file, reason: "damaged") }
        let blob = Self.halfFloats(vector)
        return try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                guard try Self.stillPending(db, file) else {
                    try Self.exec(db, "ROLLBACK")
                    return false
                }
                try Self.deletePassages(db, fileID: file.id)
                _ = try Self.insertPassage(
                    db, fileID: file.id, source: "name", start: 0, end: 0, modality: "none", blob: nil,
                    name: nameWords, body: "")
                _ = try Self.insertPassage(
                    db, fileID: file.id, source: "image", start: 0, end: 0, modality: "image", blob: blob,
                    name: "", body: ocrText)
                try Self.run(db, "UPDATE files SET status = 'done', reason = NULL, read_to = NULL, tries = 0 WHERE id = ?") {
                    sqlite3_bind_int64($0, 1, file.id)
                }
                try Self.exec(db, "COMMIT")
                return true
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// One page and its vector, as `commitStep` stores it: a text page (`modality` "text", `text` its text) or a scan page
    /// (`modality` "image", `text` the words Vision read in its picture).
    public struct PagePassage: Sendable {
        public let page: Int
        public let text: String
        public let vector: [Float]
        public let modality: String

        public init(page: Int, text: String, vector: [Float], modality: String = "text") {
            self.page = page
            self.text = text
            self.vector = vector
            self.modality = modality
        }
    }

    /// One transaction for one step of a PDF: the first step (`firstPage` 1) replaces the file's old passages and
    /// writes its `name` passage; each page of `pages` gets a `page` passage (`start = end =` the page, its modality,
    /// the vector, the text as the keyword body), text pages and scan pages together. `read_to` becomes `readTo` and the
    /// status `partial`, or `done` with `read_to` cleared once `readTo` reaches `pageCount`; the attempt marker goes back
    /// to 0. Writes nothing and returns false when the row is no longer the one that was read (a reconcile changed it,
    /// or another step was stored).
    public func commitStep(
        _ file: PendingPhoto, nameWords: String, pages: [PagePassage], firstPage: Int, readTo: Int, pageCount: Int
    ) throws -> Bool {
        try commitStep(
            file, nameWords: nameWords, first: firstPage == 1,
            passages: pages.map {
                StepPassage(source: "page", start: $0.page, end: $0.page, modality: $0.modality, text: $0.text, vector: $0.vector)
            }, readTo: readTo, total: pageCount)
    }

    /// One piece of a step with its place and vector: a `source` ("page", "chunk"), its `start` and `end` as the
    /// index stores them, its `modality`, `text` the keyword body and the `vector`.
    public struct StepPassage: Sendable {
        public let source: String
        public let start: Int
        public let end: Int
        public let modality: String
        public let text: String
        public let vector: [Float]
        public let name: String

        public init(source: String, start: Int, end: Int, modality: String, text: String, vector: [Float], name: String = "") {
            self.source = source
            self.start = start
            self.end = end
            self.modality = modality
            self.text = text
            self.vector = vector
            self.name = name
        }
    }

    /// One transaction for one step of a file read in steps (a PDF's pages, a document's chunks): the `first` step replaces
    /// the file's old passages and writes its `name` passage; every one of `passages` is written; `read_to` becomes `readTo`
    /// and the status `partial`, or `done` with `read_to` cleared once `readTo` reaches `total`. `passages` may be empty
    /// (a document with no text is done with its name passage only). Same refusals as the PDF form above.
    public func commitStep(
        _ file: PendingPhoto, nameWords: String, first: Bool, passages: [StepPassage], readTo: Int, total: Int
    ) throws -> Bool {
        for passage in passages where passage.vector.count != Schema.vectorLength { throw IndexError.badVector(passage.vector.count) }
        // A NaN or infinite component would poison every search score: nothing is stored, the file is damaged.
        guard passages.allSatisfy({ $0.vector.allSatisfy(\.isFinite) }) else { return try markCouldNotRead(file, reason: "damaged") }
        let blobs = passages.map { Self.halfFloats($0.vector) }
        return try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                guard try Self.stillPending(db, file) else {
                    try Self.exec(db, "ROLLBACK")
                    return false
                }
                if first {
                    try Self.deletePassages(db, fileID: file.id)
                    _ = try Self.insertPassage(
                        db, fileID: file.id, source: "name", start: 0, end: 0, modality: "none", blob: nil,
                        name: nameWords, body: "")
                }
                for (passage, blob) in zip(passages, blobs) {
                    _ = try Self.insertPassage(
                        db, fileID: file.id, source: passage.source, start: Double(passage.start), end: Double(passage.end),
                        modality: passage.modality, blob: blob, name: passage.name, body: passage.text)
                }
                let finished = readTo >= total
                try Self.run(db, "UPDATE files SET status = ?, read_to = ?, reason = NULL, tries = 0 WHERE id = ?") { statement in
                    sqlite3_bind_text(statement, 1, finished ? "done" : "partial", -1, sqliteTransient)
                    if finished { sqlite3_bind_null(statement, 2) } else { sqlite3_bind_int64(statement, 2, Int64(readTo)) }
                    sqlite3_bind_int64(statement, 3, file.id)
                }
                try Self.exec(db, "COMMIT")
                return true
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// Marks a file that cannot be decoded `could_not_read` with a reason, in one transaction, so it is not read again.
    /// Same rule as `completePhoto` for a row that has changed. A `partial` file loses its passages and its `read_to`.
    public func markCouldNotRead(_ file: PendingPhoto, reason: String) throws -> Bool {
        try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                guard try Self.stillPending(db, file) else {
                    try Self.exec(db, "ROLLBACK")
                    return false
                }
                try Self.deletePassages(db, fileID: file.id)
                try Self.run(db, "UPDATE files SET status = 'could_not_read', reason = ?, read_to = NULL, tries = 0 WHERE id = ?") { statement in
                    sqlite3_bind_text(statement, 1, reason, -1, sqliteTransient)
                    sqlite3_bind_int64(statement, 2, file.id)
                }
                try Self.exec(db, "COMMIT")
                return true
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// Marks a photo the process may not open `needs_permission`, in one transaction, with no passages and no try spent.
    /// Same rule as `completePhoto` for a row that has changed.
    public func markNeedsPermission(_ file: PendingPhoto) throws -> Bool {
        try withDB { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                guard try Self.stillPending(db, file) else {
                    try Self.exec(db, "ROLLBACK")
                    return false
                }
                try Self.deletePassages(db, fileID: file.id)
                try Self.run(db, "UPDATE files SET status = 'needs_permission', reason = NULL, read_to = NULL, tries = 0 WHERE id = ?") {
                    sqlite3_bind_int64($0, 1, file.id)
                }
                try Self.exec(db, "COMMIT")
                return true
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// Turns every `needs_permission` row back to `pending`, so the next read tries it again.
    public func retryNeedsPermission() throws {
        try withDB { db in
            try Self.run(db, "UPDATE files SET status = 'pending' WHERE status = 'needs_permission'") { _ in }
        }
    }

    /// True when the row still needs reading (`pending`, or `partial` for a long file) and holds the size, time, inode
    /// and `read_to` the reader was given.
    private static func stillPending(_ db: OpaquePointer, _ file: PendingPhoto) throws -> Bool {
        var matches = false
        try forEachRow(db, "SELECT status, size, mtime_ns, inode, COALESCE(read_to, 0) FROM files WHERE id = \(file.id)") { statement in
            let status = String(cString: sqlite3_column_text(statement, 0))
            matches = (status == "pending" || status == "partial")
                && sqlite3_column_int64(statement, 1) == file.size && sqlite3_column_int64(statement, 2) == file.mtimeNs
                && UInt64(bitPattern: sqlite3_column_int64(statement, 3)) == file.inode
                && Int(sqlite3_column_int64(statement, 4)) == (file.readTo ?? 0)
        }
        return matches
    }

    /// What a walk can see of a file that stays the same file when it is moved or renamed.
    private struct FileIdentity: Hashable {
        let size: Int64
        let mtimeNs: Int64
        let inode: Int64
        let device: Int64
        let kind: String
    }

    private struct KnownFile {
        let id: Int64
        let path: String
        let size: Int64
        let mtimeNs: Int64
        let inode: Int64
        let device: Int64
        let kind: String

        var identity: FileIdentity { FileIdentity(size: size, mtimeNs: mtimeNs, inode: inode, device: device, kind: kind) }
    }

    /// Removes a file's keyword rows (their rowid is the passage id) and its passages.
    private static func deletePassages(_ db: OpaquePointer, fileID: Int64) throws {
        try run(db, "DELETE FROM fts WHERE rowid IN (SELECT id FROM passages WHERE file_id = ?)") {
            sqlite3_bind_int64($0, 1, fileID)
        }
        try run(db, "DELETE FROM passages WHERE file_id = ?") { sqlite3_bind_int64($0, 1, fileID) }
    }

    /// Closes the file and gives up the one-writer exclusion. Safe to call twice.
    public func close() {
        mutex.lock()
        defer { mutex.unlock() }
        sqlite3_close_v2(db)
        db = nil
        sqlite3_close_v2(exclusion)
        exclusion = nil
    }

    // MARK: opening

    /// SQLite's own file lock on a side file, held by a connection that stays open (exclusive locking mode):
    /// a second store gets SQLITE_BUSY, and the lock goes when the connection closes or the process dies.
    private static func takeExclusion() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(Schema.lockPath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let error = failure("open lock", handle)
            sqlite3_close_v2(handle)
            throw error
        }
        do {
            try exec(handle, "PRAGMA locking_mode = EXCLUSIVE")
            try exec(handle, "BEGIN EXCLUSIVE")
            try exec(handle, "COMMIT")
        } catch {
            let busy = sqlite3_errcode(handle) & 0xff == SQLITE_BUSY
            sqlite3_close_v2(handle)
            throw busy ? IndexError.alreadyOpen : error
        }
        return handle
    }

    private static func openIndex() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(Schema.indexPath, &handle, flags, nil) == SQLITE_OK, let handle else {
            let error = failure("open index", handle)
            sqlite3_close_v2(handle)
            throw error
        }
        do {
            try exec(handle, "PRAGMA journal_mode = WAL")
            try exec(handle, "PRAGMA synchronous = NORMAL")
            try exec(handle, "PRAGMA foreign_keys = ON")
            sqlite3_busy_timeout(handle, 5000)
            for statement in Schema.statements { try exec(handle, statement) }
            try run(handle, "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema', ?)") { statement in
                sqlite3_bind_text(statement, 1, Schema.version, -1, sqliteTransient)
            }
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        return handle
    }

    // MARK: helpers

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard let db else { throw IndexError.closed }
        return try body(db)
    }

    private static func failure(_ call: String, _ db: OpaquePointer?) -> IndexError {
        guard let db else { return .sqlite(call, "no handle", SQLITE_NOMEM) }
        return .sqlite(call, String(cString: sqlite3_errmsg(db)), sqlite3_errcode(db))
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(sql, db) }
    }

    /// Prepares `sql`, binds, runs it once to the end and finalizes it.
    private static func run(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure(sql, db)
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else { throw failure(sql, db) }
    }

    /// Runs `sql` and calls `row` for each result row.
    private static func forEachRow(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure(sql, db)
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw failure(sql, db) }
            row(statement)
        }
    }

    /// Little-endian IEEE half floats, two bytes a number.
    private static func halfFloats(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 2)
        for value in vector {
            let bits = Float16(value).bitPattern
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
}

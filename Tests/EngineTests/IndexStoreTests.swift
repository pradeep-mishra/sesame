import Foundation
import SQLite3
import Testing
import SesameEngine

// IndexStore is the one writer of `index.sqlite`; IndexReader is the app's one read connection.
// Both find the file in the Sesame folder under HOME, read at call time, so every test runs
// against a throwaway HOME (withTempHome and createFolder come from SesameFolderTests.swift).
// The tests look inside the file with their own read-only SQLite connection, so what they
// check is what is on disk, not what the product says about itself.

private func indexFile(_ t: TempHome) -> URL {
    t.folder.appendingPathComponent("index.sqlite")
}

// MARK: raw read-only SQLite, independent of the product

private struct RawError: Error, CustomStringConvertible {
    let description: String
}

private func rawRows(_ path: String, _ sql: String) throws -> [[String?]] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
        sqlite3_close(db)
        throw RawError(description: "cannot open \(path): \(message)")
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw RawError(description: "cannot prepare \(sql): \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String?]] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else {
            throw RawError(description: "cannot step \(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
        var row: [String?] = []
        for column in 0..<sqlite3_column_count(statement) {
            if sqlite3_column_type(statement, column) == SQLITE_NULL {
                row.append(nil)
            } else if let text = sqlite3_column_text(statement, column) {
                row.append(String(cString: text))
            } else {
                row.append(nil)
            }
        }
        rows.append(row)
    }
    return rows
}

// The raw bytes of the first column of every row (nil for NULL).
private func rawBlobs(_ path: String, _ sql: String) throws -> [Data?] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw RawError(description: "cannot open \(path)")
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw RawError(description: "cannot prepare \(sql): \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(statement) }
    var blobs: [Data?] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if sqlite3_column_type(statement, 0) == SQLITE_NULL {
            blobs.append(nil)
        } else {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let pointer = sqlite3_column_blob(statement, 0) {
                blobs.append(Data(bytes: pointer, count: count))
            } else {
                blobs.append(Data())
            }
        }
    }
    return blobs
}

// Little-endian IEEE half floats, decoded here and not by the product.
private func decodeHalfFloats(_ data: Data) -> [Float] {
    let count = data.count / 2
    return (0..<count).map { index in
        let low = UInt16(data[data.startIndex + 2 * index])
        let high = UInt16(data[data.startIndex + 2 * index + 1])
        return Float(Float16(bitPattern: low | (high << 8)))
    }
}

// MARK: the rows every test writes (values chosen here, by hand)

private func vector(_ phase: Float) -> [Float] {
    (0..<768).map { index in sin(Float(index) * 0.37 + phase) * 0.9 }
}

private let beachFile = "/photos/beach-dog.jpg"
private let invoiceFile = "/photos/invoice-scan.png"
private let pendingFile = "/photos/not-read-yet.gif"

private struct Written {
    let fileA: Int64
    let fileB: Int64
    let fileC: Int64
    let nameA: Int64    // name passage of the beach photo: words only, no vector
    let imageA: Int64
    let nameB: Int64
    let imageB: Int64
    let vectorA: [Float]
    let vectorB: [Float]
}

// 3 files, 4 passages. Words (name column, then body column):
//   nameA  name "beach dog holiday"
//   imageA vector only
//   nameB  name "invoice scan"
//   imageB body "Invoice number 4417 payable by Friday, the café on the corner, two dogs running"
private func writeFixtureRows(_ store: IndexStore) throws -> Written {
    let vectorA = vector(0.0)
    let vectorB = vector(1.9)
    let fileA = try store.addFile(path: beachFile, kind: "photo", size: 48211,
                                  mtimeNs: 1_700_000_000_123_456_789, inode: 9001,
                                  device: 16_777_220, status: "done")
    let fileB = try store.addFile(path: invoiceFile, kind: "photo", size: 20480,
                                  mtimeNs: 1_700_000_001_000_000_000, inode: 9002,
                                  device: 16_777_220, status: "done")
    let fileC = try store.addFile(path: pendingFile, kind: "photo", size: 7,
                                  mtimeNs: 1_700_000_002_000_000_000, inode: 9003,
                                  device: 16_777_220, status: "pending")
    let nameA = try store.addPassage(fileID: fileA, source: "name", start: 0, end: 0,
                                     modality: "none", vector: nil,
                                     name: "beach dog holiday", body: "")
    let imageA = try store.addPassage(fileID: fileA, source: "image", start: 0, end: 0,
                                      modality: "image", vector: vectorA, name: "", body: "")
    let nameB = try store.addPassage(fileID: fileB, source: "name", start: 0, end: 0,
                                     modality: "none", vector: nil,
                                     name: "invoice scan", body: "")
    let imageB = try store.addPassage(fileID: fileB, source: "image", start: 0, end: 0,
                                      modality: "image", vector: vectorB, name: "",
                                      body: "Invoice number 4417 payable by Friday, the café on the corner, two dogs running")
    return Written(fileA: fileA, fileB: fileB, fileC: fileC, nameA: nameA, imageA: imageA,
                   nameB: nameB, imageB: imageB, vectorA: vectorA, vectorB: vectorB)
}

// True while this process holds the file open (lsof, matched by file identity).
private func thisProcessHasOpen(_ url: URL) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-a", "-p", String(getpid()), "--", url.path]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return !data.isEmpty
}

@Suite("IndexStoreTests")
struct IndexStoreTests {

    // MARK: schema, read from the file itself

    @Test func theFileHoldsTheFourTablesAndTheColumnsOfDesignSection1() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            store.close()

            let path = indexFile(t).path
            let tables = try rawRows(path, "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
                .compactMap { $0[0] }
            for expected in ["files", "passages", "fts", "meta"] {
                #expect(tables.contains(expected), "table \(expected) is missing; the file has \(tables)")
            }

            func columns(_ table: String) throws -> Set<String> {
                Set(try rawRows(path, "SELECT name FROM pragma_table_info('\(table)')").compactMap { $0[0] })
            }
            let files = try columns("files")
            for expected in ["id", "path", "kind", "size", "mtime_ns", "inode", "device",
                             "status", "reason", "read_to", "tries"] {
                #expect(files.contains(expected), "files has no column \(expected); it has \(files)")
            }
            let passages = try columns("passages")
            for expected in ["id", "file_id", "source", "start", "end", "modality", "vec"] {
                #expect(passages.contains(expected), "passages has no column \(expected); it has \(passages)")
            }
            let fts = try columns("fts")
            #expect(fts == ["name", "body"], "fts columns are \(fts)")
        }
    }

    @Test func theFtsTableIsDefinedWithTheExactTokenizerText() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            store.close()

            let definition = try rawRows(indexFile(t).path,
                                         "SELECT sql FROM sqlite_master WHERE name = 'fts'")
            let sql = try #require(definition.first?.first ?? nil, "no definition for fts in sqlite_master")
            #expect(sql.lowercased().contains("fts5"), "fts is not an FTS5 table: \(sql)")
            #expect(sql.contains("porter unicode61 remove_diacritics 2"), "tokenizer text not found in: \(sql)")
        }
    }

    @Test func journalModeIsWALOnTheFile() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            _ = try writeFixtureRows(store)

            let whileOpen = try rawRows(indexFile(t).path, "PRAGMA journal_mode")
            #expect(whileOpen.first?.first == "wal")

            store.close()
            let afterClose = try rawRows(indexFile(t).path, "PRAGMA journal_mode")
            #expect(afterClose.first?.first == "wal")
        }
    }

    @Test func noTableOrColumnNameHoldsQueryOpenCountOrHistory() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            _ = try writeFixtureRows(store)
            try store.setMeta("vector_source", "test-source")
            store.close()

            let path = indexFile(t).path
            let tables = try rawRows(path, "SELECT name FROM sqlite_master").compactMap { $0[0] }
            #expect(tables.count >= 4)
            var listed = tables
            for table in tables {
                let columns = try rawRows(path, "SELECT name FROM pragma_table_info('\(table)')")
                listed.append(contentsOf: columns.compactMap { $0[0] })
            }
            for name in listed {
                for banned in ["query", "open", "count", "history"] {
                    #expect(!name.lowercased().contains(banned), "name \"\(name)\" contains \"\(banned)\"")
                }
            }
        }
    }

    // MARK: rows written, then read back by the reader and from the file

    @Test func filesAndPassagesAreStoredWithTheValuesTheTestWrote() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            let written = try writeFixtureRows(store)
            store.close()

            let path = indexFile(t).path
            let files = try rawRows(path, "SELECT path, kind, size, mtime_ns, inode, device, status FROM files ORDER BY path")
            #expect(files.count == 3)
            #expect(files[0] == [beachFile, "photo", "48211", "1700000000123456789", "9001", "16777220", "done"])
            #expect(files[1] == [invoiceFile, "photo", "20480", "1700000001000000000", "9002", "16777220", "done"])
            #expect(files[2] == [pendingFile, "photo", "7", "1700000002000000000", "9003", "16777220", "pending"])

            let passages = try rawRows(path, "SELECT id, file_id, source, modality, vec IS NULL FROM passages ORDER BY id")
            #expect(passages.count == 4)
            let byID = Dictionary(uniqueKeysWithValues: passages.map { ($0[0] ?? "", $0) })
            #expect(byID["\(written.nameA)"] == ["\(written.nameA)", "\(written.fileA)", "name", "none", "1"])
            #expect(byID["\(written.imageA)"] == ["\(written.imageA)", "\(written.fileA)", "image", "image", "0"])
            #expect(byID["\(written.nameB)"] == ["\(written.nameB)", "\(written.fileB)", "name", "none", "1"])
            #expect(byID["\(written.imageB)"] == ["\(written.imageB)", "\(written.fileB)", "image", "image", "0"])
            #expect(Set(byID.keys).count == 4, "passage ids must be distinct")
        }
    }

    @Test func theReaderCountsWhatTheStoreWrote() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            let reader = IndexReader()
            #expect(reader.fileCount() == 0)
            #expect(reader.passageCount() == 0)

            _ = try writeFixtureRows(store)

            // the store is still open: the reader sees committed rows at once
            #expect(reader.fileCount() == 3)
            #expect(reader.passageCount() == 4)

            store.close()
            #expect(reader.fileCount() == 3)
            #expect(reader.passageCount() == 4)
            reader.close()
        }
    }

    @Test func keywordSearchFindsPassagesByNameWordsAndBodyWords() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            let written = try writeFixtureRows(store)
            let reader = IndexReader()

            // a word of a name passage
            #expect(Set(reader.keywordSearch("beach")) == [written.nameA])
            #expect(Set(reader.keywordSearch("holiday")) == [written.nameA])
            // a word of a body, and a word that is in a name and in a body
            #expect(Set(reader.keywordSearch("friday")) == [written.imageB])
            #expect(Set(reader.keywordSearch("invoice")) == [written.nameB, written.imageB])
            // case does not matter (unicode61)
            #expect(Set(reader.keywordSearch("INVOICE")) == [written.nameB, written.imageB])
            // porter: "dog" finds "dogs" in a body and "dog" in a name
            #expect(Set(reader.keywordSearch("dog")) == [written.nameA, written.imageB])
            // remove_diacritics 2: "cafe" finds "café"
            #expect(Set(reader.keywordSearch("cafe")) == [written.imageB])
            // a word nobody wrote
            #expect(reader.keywordSearch("zebra").isEmpty)
            // a file with no passages has nothing to hit
            #expect(reader.keywordSearch("gif").isEmpty)

            store.close()
            #expect(Set(reader.keywordSearch("beach")) == [written.nameA])
        }
    }

    @Test func theFtsRowIdIsThePassageId() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            let written = try writeFixtureRows(store)
            store.close()

            let path = indexFile(t).path
            #expect(try rawRows(path, "SELECT rowid FROM fts WHERE fts MATCH 'beach'") == [["\(written.nameA)"]])
            #expect(try rawRows(path, "SELECT rowid FROM fts WHERE name MATCH 'invoice'") == [["\(written.nameB)"]])
            #expect(try rawRows(path, "SELECT rowid FROM fts WHERE body MATCH 'invoice'") == [["\(written.imageB)"]])
            #expect(try rawRows(path, "SELECT count(*) FROM fts") == [["4"]])
        }
    }

    // MARK: vectors

    @Test func vectorsAreStoredAs1536ByteBlobsAndReadBackWithin1eMinus3() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            let written = try writeFixtureRows(store)
            let reader = IndexReader()

            // straight from the file: 768 half floats = 1,536 bytes, NULL for a name passage
            let path = indexFile(t).path
            func blob(_ id: Int64) throws -> Data? {
                let found = try rawBlobs(path, "SELECT vec FROM passages WHERE id = \(id)")
                #expect(found.count == 1)
                return found.first ?? nil
            }
            let blobA = try #require(try blob(written.imageA))
            let blobB = try #require(try blob(written.imageB))
            #expect(blobA.count == 1536)
            #expect(blobB.count == 1536)
            #expect(try blob(written.nameA) == nil)
            #expect(try blob(written.nameB) == nil)

            let decodedA = decodeHalfFloats(blobA)
            let decodedB = decodeHalfFloats(blobB)
            #expect(decodedA.count == 768)
            #expect(decodedB.count == 768)
            #expect(zip(decodedA, written.vectorA).allSatisfy { abs($0 - $1) < 1e-3 })
            #expect(zip(decodedB, written.vectorB).allSatisfy { abs($0 - $1) < 1e-3 })
            // the two passages did not get each other's vector
            #expect(zip(decodedA, written.vectorB).contains { abs($0 - $1) > 1e-2 })

            // through the reader
            let readA = try #require(reader.vector(ofPassage: written.imageA))
            let readB = try #require(reader.vector(ofPassage: written.imageB))
            #expect(readA.count == 768)
            #expect(readB.count == 768)
            #expect(zip(readA, written.vectorA).allSatisfy { abs($0 - $1) < 1e-3 })
            #expect(zip(readB, written.vectorB).allSatisfy { abs($0 - $1) < 1e-3 })
            #expect(reader.vector(ofPassage: written.nameA) == nil)
            #expect(reader.vector(ofPassage: 987_654) == nil)

            store.close()
        }
    }

    // MARK: meta

    @Test func metaHoldsSchemaVectorSourceAndWalkDoneAt() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            let reader = IndexReader()

            // a new index records its schema; the other two facts are absent until written
            let schema = try #require(reader.meta("schema"), "a new index has no meta.schema")
            #expect(!schema.isEmpty)
            #expect(reader.meta("vector_source") == nil)
            #expect(reader.meta("walk_done_at") == nil)

            try store.setMeta("vector_source", "embeddinggemma-2-Q8_0.gguf|mmproj|rev-a|v1")
            #expect(reader.meta("vector_source") == "embeddinggemma-2-Q8_0.gguf|mmproj|rev-a|v1")
            #expect(reader.meta("walk_done_at") == nil)

            try store.setMeta("walk_done_at", "1700000123")
            #expect(reader.meta("walk_done_at") == "1700000123")

            // a second write of the same key replaces the value, it does not add a row
            try store.setMeta("walk_done_at", "1700009999")
            #expect(reader.meta("walk_done_at") == "1700009999")
            #expect(reader.meta("schema") == schema)
            #expect(reader.meta("no_such_key") == nil)

            store.close()
            #expect(reader.meta("vector_source") == "embeddinggemma-2-Q8_0.gguf|mmproj|rev-a|v1")
        }
    }

    // MARK: a reader on a missing file

    @Test func aReaderOnAMissingIndexReturnsZerosAndSeesRowsOnceTheStoreCreatesTheFile() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = indexFile(t)
            #expect(!FileManager.default.fileExists(atPath: file.path))

            let reader = IndexReader()
            #expect(reader.fileCount() == 0)
            #expect(reader.passageCount() == 0)
            #expect(reader.keywordSearch("beach").isEmpty)
            #expect(reader.meta("schema") == nil)
            // asking never creates the file
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try names(in: t.folder).isEmpty)

            let store = try IndexStore()
            #expect(FileManager.default.fileExists(atPath: file.path))
            // the same reader, no new object: each call tries the open again
            #expect(reader.fileCount() == 0)
            #expect(reader.meta("schema") != nil)

            let written = try writeFixtureRows(store)
            #expect(reader.fileCount() == 3)
            #expect(reader.passageCount() == 4)
            #expect(Set(reader.keywordSearch("beach")) == [written.nameA])
            store.close()
        }
    }

    @Test func aReaderWithNoSesameFolderAtAllReturnsZeros() throws {
        try withTempHome { t in
            #expect(!FileManager.default.fileExists(atPath: t.folder.path))
            let reader = IndexReader()
            #expect(reader.fileCount() == 0)
            #expect(reader.passageCount() == 0)
            #expect(reader.keywordSearch("beach").isEmpty)
            #expect(reader.meta("walk_done_at") == nil)
            #expect(reader.vector(ofPassage: 1) == nil)
            #expect(!FileManager.default.fileExists(atPath: t.folder.path))
        }
    }

    // MARK: one writer, and close()

    @Test func aSecondStoreOnTheSameFileFailsToOpenAndTheFirstKeepsWorking() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let first = try IndexStore()
            _ = try writeFixtureRows(first)

            #expect(throws: (any Error).self) {
                _ = try IndexStore()
            }

            // the failed open changed nothing for the first store or for readers
            let reader = IndexReader()
            #expect(reader.fileCount() == 3)
            let more = try first.addFile(path: "/photos/after-second-open.jpg", kind: "photo", size: 1,
                                         mtimeNs: 1_700_000_003_000_000_000, inode: 9004,
                                         device: 16_777_220, status: "pending")
            #expect(more > 0)
            #expect(reader.fileCount() == 4)
            first.close()
        }
    }

    @Test func closeReleasesTheFileSoANewStoreCanOpenIt() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = indexFile(t)

            let first = try IndexStore()
            let written = try writeFixtureRows(first)
            // control: while the store is open this process does hold the file
            #expect(try thisProcessHasOpen(file), "lsof did not see the open index file, so the check below proves nothing")

            first.close()
            #expect(try !thisProcessHasOpen(file), "the store still holds index.sqlite after close()")

            // released, and the rows survive for the next writer
            let second = try IndexStore()
            let reader = IndexReader()
            #expect(reader.fileCount() == 3)
            #expect(reader.passageCount() == 4)
            #expect(Set(reader.keywordSearch("beach")) == [written.nameA])
            second.close()
            reader.close()
        }
    }

    @Test func closeOnTheReaderReleasesItsConnection() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let file = indexFile(t)
            let store = try IndexStore()
            _ = try writeFixtureRows(store)
            store.close()
            #expect(try !thisProcessHasOpen(file))

            let reader = IndexReader()
            #expect(reader.fileCount() == 3)
            #expect(try thisProcessHasOpen(file), "control: a reader that has answered holds the file open")

            reader.close()
            #expect(try !thisProcessHasOpen(file), "the reader still holds index.sqlite after close()")
        }
    }
}

// MARK: plan-2-t2 (carry-over R2): the status `needs_permission`
//
// Written from the plan-2-t2 entry (Tests: paragraph) and design section 1 and 3 only. The names the entry gives are
// `IndexStore.markNeedsPermission(_:)` and `IndexStore.retryNeedsPermission()`, and the status text `needs_permission`.
//
// SHAPES THESE TESTS PIN (the entry gives only the names; if a shape is wrong, ask for a test change):
//   `func markNeedsPermission(_ file: IndexStore.PendingPhoto) throws -> Bool`   the same shape as the existing
//        `markCouldNotRead(_:reason:)`: the argument is the row as it was read (`IndexStore.pendingPhotos`), the result
//        is true when this call changed the row, false when it changed nothing.
//   `func retryNeedsPermission() throws`   the result, if it returns one, is ignored.
// The values written are checked in the file itself with this file's own read-only SQLite connection.

private func rowTexts(_ t: TempHome, _ sql: String) throws -> [[String?]] {
    try rawRows(indexFile(t).path, sql)
}

private func pendingPhoto(_ store: IndexStore, path: String) throws -> IndexStore.PendingPhoto {
    let found = try store.pendingPhotos(limit: 50).filter { $0.path == path }
    return try #require(found.first, "pendingPhotos(limit: 50) does not list \(path)")
}

extension IndexStoreTests {

    @Test func markNeedsPermissionSetsTheStatusOfThePendingRowItWasReadFromAndNothingElse() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            _ = try store.addFile(path: "/photos/locked.jpg", kind: "photo", size: 1234,
                                  mtimeNs: 1_700_000_005_000_000_000, inode: 9101, device: 16_777_220, status: "pending")
            _ = try store.addFile(path: "/photos/other.jpg", kind: "photo", size: 4321,
                                  mtimeNs: 1_700_000_006_000_000_000, inode: 9102, device: 16_777_220, status: "pending")
            let locked = try pendingPhoto(store, path: "/photos/locked.jpg")

            let changed = try store.markNeedsPermission(locked)
            #expect(changed, "markNeedsPermission said it changed nothing for a row that is still pending with the identity that was read")

            let rows = try rowTexts(t, "SELECT path, status, tries FROM files ORDER BY path")
            #expect(rows == [["/photos/locked.jpg", "needs_permission", "0"], ["/photos/other.jpg", "pending", "0"]],
                    "rows after the mark: \(rows)")
            let passages = try rowTexts(t, "SELECT count(*) FROM passages")
            #expect(passages == [["0"]], "marking a row writes no passage, got \(passages)")

            // It is no longer pending work: the queue the helper reads from does not offer it again.
            let queue = try store.pendingPhotos(limit: 50).map(\.path)
            #expect(queue == ["/photos/other.jpg"], "pendingPhotos after the mark lists \(queue)")
        }
    }

    @Test func markNeedsPermissionChangesNothingForARowThatIsNoLongerPending() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            _ = try store.addFile(path: "/photos/beach.jpg", kind: "photo", size: 1234,
                                  mtimeNs: 1_700_000_005_000_000_000, inode: 9101, device: 16_777_220, status: "pending")
            let read = try pendingPhoto(store, path: "/photos/beach.jpg")
            // Another reader of the queue finished the photo between the read and the mark.
            let completed = try store.completePhoto(read, nameWords: "beach", ocrText: "", vector: vector(0.3))
            #expect(completed, "setup: completePhoto said it changed nothing")
            let passagesBefore = try rowTexts(t, "SELECT count(*) FROM passages")

            let changed = try store.markNeedsPermission(read)
            #expect(!changed, "a row that is already done must not be marked needs_permission")

            let rows = try rowTexts(t, "SELECT status, tries FROM files")
            #expect(rows == [["done", "0"]], "the done row changed: \(rows)")
            #expect(try rowTexts(t, "SELECT count(*) FROM passages") == passagesBefore, "the passages of the done row changed")
        }
    }

    @Test func markNeedsPermissionChangesNothingWhenTheSizeTheTimeOrTheInodeChangedSinceTheRead() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            // Three real files (a walk reads names, sizes and times only, so the bytes need not be pictures); a
            // `WalkedFile` can only come from a real walk. The rows hold exactly what the first walk saw.
            let tree = FileManager.default.temporaryDirectory
                .appendingPathComponent("sesame-markneeds-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tree) }
            let sizeFile = tree.appendingPathComponent("size.jpg")
            let timeFile = tree.appendingPathComponent("time.jpg")
            let nodeFile = tree.appendingPathComponent("node.jpg")
            for url in [sizeFile, timeFile, nodeFile] { try Data(repeating: 7, count: 100).write(to: url) }
            let device: Int64 = 16_777_220
            let first = try Walker.walk(root: tree.path, mode: .read)
            #expect(first.count == 3, "setup: the first walk found \(first.count) files, expected 3")
            for walked in first {
                _ = try store.addFile(path: walked.path, kind: walked.kind, size: walked.size, mtimeNs: walked.mtimeNs,
                                      inode: Int64(walked.inode), device: device, status: "pending")
            }
            let bySize = try pendingPhoto(store, path: sizeFile.path)
            let byTime = try pendingPhoto(store, path: timeFile.path)
            let byNode = try pendingPhoto(store, path: nodeFile.path)

            // The files change on disk after the helper read the rows: a new size, a new modified time, a new inode.
            let handle = try FileHandle(forWritingTo: sizeFile)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 8, count: 50))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                  ofItemAtPath: timeFile.path)
            let replacement = tree.appendingPathComponent("replacement.tmp")
            try Data(repeating: 7, count: 100).write(to: replacement)
            #expect(rename(replacement.path, nodeFile.path) == 0, "setup: could not replace node.jpg")

            // The next walk updates the rows (they go back to pending with what is on disk now).
            let second = try Walker.walk(root: tree.path, mode: .read)
            let outcome = try store.reconcile(second.map { (file: $0, device: device) }, unreadable: [],
                                              vectorSource: "v", walkDoneAt: "t1")
            #expect(outcome.removed == 0, "setup: the reconcile removed \(outcome.removed) rows, expected none")
            let before = try rowTexts(t, "SELECT path, status, size, mtime_ns, inode FROM files ORDER BY path")
            #expect(before.count == 3 && before.allSatisfy { $0[1] == "pending" },
                    "setup: the three changed files should be rows that are pending, got \(before)")

            #expect(try !store.markNeedsPermission(bySize), "marked a row whose size changed since the read")
            #expect(try !store.markNeedsPermission(byTime), "marked a row whose modified time changed since the read")
            #expect(try !store.markNeedsPermission(byNode), "marked a row whose inode changed since the read")

            let after = try rowTexts(t, "SELECT path, status, size, mtime_ns, inode FROM files ORDER BY path")
            #expect(after == before, "rows after three refused marks: \(after), before: \(before)")
        }
    }

    @Test func markNeedsPermissionChangesNothingWhenTheRowIsGone() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            _ = try store.addFile(path: "/photos/vanished.jpg", kind: "photo", size: 100,
                                  mtimeNs: 1_700_000_005_000_000_000, inode: 9301, device: 16_777_220, status: "pending")
            let read = try pendingPhoto(store, path: "/photos/vanished.jpg")
            let outcome = try store.reconcile([], unreadable: [], vectorSource: "v", walkDoneAt: "t1")
            #expect(outcome.removed == 1, "setup: the reconcile removed \(outcome.removed) rows, expected 1")

            #expect(try !store.markNeedsPermission(read), "marked a row that is gone")
            #expect(try rowTexts(t, "SELECT count(*) FROM files") == [["0"]], "a mark brought a row back")
        }
    }

    @Test func retryNeedsPermissionTurnsOnlyTheNeedsPermissionRowsBackToPending() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let device: Int64 = 16_777_220
            var inode: Int64 = 9400
            for (name, status) in [("a-needs", "needs_permission"), ("b-needs", "needs_permission"), ("c-done", "done"),
                                   ("d-pending", "pending"), ("e-bad", "could_not_read")] {
                inode += 1
                _ = try store.addFile(path: "/photos/\(name).jpg", kind: "photo", size: 10,
                                      mtimeNs: 1_700_000_005_000_000_000, inode: inode, device: device, status: status)
            }

            _ = try store.retryNeedsPermission()
            let rows = try rowTexts(t, "SELECT path, status FROM files ORDER BY path")
            #expect(rows == [["/photos/a-needs.jpg", "pending"], ["/photos/b-needs.jpg", "pending"],
                             ["/photos/c-done.jpg", "done"], ["/photos/d-pending.jpg", "pending"],
                             ["/photos/e-bad.jpg", "could_not_read"]],
                    "rows after the retry: \(rows)")

            // Nothing is left to turn back: a second call changes nothing.
            _ = try store.retryNeedsPermission()
            #expect(try rowTexts(t, "SELECT path, status FROM files ORDER BY path") == rows, "a second retry changed a row")
        }
    }
}

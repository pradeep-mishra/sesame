import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-2 fix round A, tester step: item A6 (S2(b), S2(a)). Written from the fix-round entry A6, the reviewer's finding
// ("one NaN or inf vector blanks all photo search") and SearchTests.swift (same index recipe, own copies below). No
// product source read.
//
// What the entry fixes (expected values written by hand):
//   - `completePhoto` refuses a vector with any non-finite component (NaN, +inf, -inf): nothing is stored (no passage, so
//     no vector row) and the file ends `could_not_read` with the reason "damaged" and `tries` 0. PINNED SHAPE: after the call
//     returns or throws (the test uses `try?`, so either is fine) the row is in that state; that is, `completePhoto`
//     does the marking itself in its own write, so a caller that gets a refusal has nothing left to do. A caller that
//     passes a good vector is unaffected (control in the same test).
//   - `Search` ignores a stored vector with a non-finite component rather than letting it poison the modality's mean:
//     one NaN row and one infinite row among good rows still return the good hits, in the same order as without them. The
//     bad rows are written with the test's own SQL (half-float bytes: 0x7E00 is a NaN, 0x7C00 is +inf), because the fix may
//     also make `addPassage` and `completePhoto` refuse them, and this test is about what Search does with a file that already holds one.
// Red today: the store test (the NaN vector is stored and the file is `done`); the Search test (the NaN row blanks the
// image rows' gate and the good hits disappear).

private let pvDevice: Int64 = 16_777_220
private let pvDimension = 768

private func pvGood(_ phase: Double) -> [Float] {
    (0..<pvDimension).map { Float(sin(Double($0) * 0.37 + phase) * 0.9) }
}

private func pvIndexPath(_ t: TempHome) -> String {
    t.folder.appendingPathComponent("index.sqlite").path
}

private func pvRows(_ t: TempHome) -> [String: AtRow] {
    AtDB(path: pvIndexPath(t)).flatMap(atRows) ?? [:]
}

// MARK: Search data, as in SearchTests (query e0, a stored vector is a*e0 + sqrt(1-a^2)*e_k, so its dot with the query is a)

private let pvQuery: [Float] = (0..<pvDimension).map { $0 == 0 ? 1 : 0 }

private func pvVector(dot a: Float, noise k: Int) -> [Float] {
    var v = [Float](repeating: 0, count: pvDimension)
    v[0] = a
    v[k] = (1 - a * a).squareRoot()
    return v
}

private let pvGradedOrder = ["/photos/a/g1.jpg", "/photos/b/g2.pdf", "/photos/a/g3.jpg", "/photos/b/g4.pdf", "/photos/a/g5.jpg"]

private func pvAdd(_ store: IndexStore, inode: Int64, path: String, kind: String, name: String, source: String, dot: Float, noise: Int) throws {
    let file = try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000,
                                 inode: inode, device: pvDevice, status: "done")
    _ = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: name, body: "")
    _ = try store.addPassage(fileID: file, source: source, start: 0, end: 0, modality: "image",
                             vector: pvVector(dot: dot, noise: noise), name: "", body: "")
}

/// 5 graded files over 100 noise files, all image modality: only the 5 stand out (the SearchTests recipe).
private func pvFill(_ store: IndexStore) throws {
    let graded: [(String, String, String, Float, Int)] = [
        ("/photos/a/g1.jpg", "photo", "harbour boats morning", 0.95, 101),
        ("/photos/b/g2.pdf", "pdf", "ledger summary", 0.85, 103),
        ("/photos/a/g3.jpg", "photo", "market crowd", 0.75, 105),
        ("/photos/b/g4.pdf", "pdf", "tenancy terms", 0.65, 106),
        ("/photos/a/g5.jpg", "photo", "mountain ridge", 0.55, 107),
    ]
    var inode: Int64 = 100
    for (path, kind, name, dot, noise) in graded {
        inode += 1
        try pvAdd(store, inode: inode, path: path, kind: kind, name: name, source: kind == "pdf" ? "page" : "image", dot: dot, noise: noise)
    }
    for k in 1...100 {
        inode += 1
        try pvAdd(store, inode: inode, path: String(format: "/photos/b/n%03d.pdf", k), kind: "pdf",
                  name: String(format: "scan%03d", k), source: "page", dot: 0, noise: k)
    }
}

private func pvEverything() -> Visible {
    Visible(folders: [Settings.Folder(path: "/photos", code: false, reading: true)], codeSearchOn: true,
            kindsOn: ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true])
}

private func pvRanked(_ search: Search) throws -> [String] {
    let ticket = search.newTicket()
    let hits = try #require(search.rank(text: "a quiet harbour at dawn", vector: pvQuery, ticket: ticket, visible: pvEverything()),
                            "the newest ticket must get a list")
    return hits.map(\.path)
}

/// 768 half floats, little endian: zeros, with `bad` (a half bit pattern) at component 5.
private func pvBadBlob(_ bad: UInt16) -> Data {
    var data = Data(count: pvDimension * 2)
    data[10] = UInt8(bad & 0xFF)
    data[11] = UInt8(bad >> 8)
    return data
}

private func pvSetVector(_ path: String, passage: Int64, blob: Data) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close_v2(db); return "cannot open the index" }
    defer { sqlite3_close_v2(db) }
    sqlite3_busy_timeout(db, 5000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "update passages set vec = ? where id = ?", -1, &statement, nil) == SQLITE_OK else {
        return "cannot prepare: \(String(cString: sqlite3_errmsg(db)))"
    }
    defer { sqlite3_finalize(statement) }
    _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    sqlite3_bind_int64(statement, 2, passage)
    guard sqlite3_step(statement) == SQLITE_DONE else { return "cannot write: \(String(cString: sqlite3_errmsg(db)))" }
    return sqlite3_changes(db) == 1 ? nil : "the update changed \(sqlite3_changes(db)) rows"
}

@Suite("PhotoVectorFiniteTests", .serialized)
struct PhotoVectorFiniteTests {

    // MARK: the store refuses a non-finite vector

    @Test(arguments: [("NaN", Float.nan), ("+inf", Float.infinity), ("-inf", -Float.infinity)])
    func completePhotoWithAVectorHoldingANonFiniteComponentStoresNothingAndEndsTheFileCouldNotReadDamaged(label: String, bad: Float) throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            for number in 1...2 {
                _ = try store.addFile(path: "/photos/v-\(number).jpg", kind: "photo", size: Int64(900 + number),
                                      mtimeNs: 1_700_000_000_000_000_000 + Int64(number) * 1_000_000_000,
                                      inode: Int64(3000 + number), device: pvDevice, status: "pending")
            }
            let photos = try store.pendingPhotos(limit: 10)
            let poisoned = try #require(photos.first { $0.path.hasSuffix("v-1.jpg") }, "setup: no v-1.jpg")
            let fine = try #require(photos.first { $0.path.hasSuffix("v-2.jpg") }, "setup: no v-2.jpg")

            var vector = pvGood(0.4)
            vector[100] = bad
            try store.beginAttempt([poisoned])
            _ = try? store.completePhoto(poisoned, nameWords: "poisoned", ocrText: "", vector: vector)

            var rows = pvRows(t)
            #expect(rows["v-1.jpg"]?.status == "could_not_read" && rows["v-1.jpg"]?.reason == "damaged" && rows["v-1.jpg"]?.tries == 0,
                    "[\(label)] a vector with a non-finite component must end the file could_not_read, damaged, tries 0; rows \(atDescribe(rows))")
            let passages = AtDB(path: pvIndexPath(t))?.int("select count(*) from passages")
            #expect(passages == 0, "[\(label)] a refused vector left \(passages.map(String.init) ?? "?") passages in the index")
            #expect(rows["v-2.jpg"]?.status == "pending" && rows["v-2.jpg"]?.tries == 0, "[\(label)] the neighbour changed: \(atDescribe(rows))")

            // the control: a finite vector for the other file is stored as before
            try store.beginAttempt([fine])
            #expect(try store.completePhoto(fine, nameWords: "fine", ocrText: "", vector: pvGood(1.2)), "[\(label)] completePhoto of a finite vector changed nothing")
            rows = pvRows(t)
            #expect(rows["v-2.jpg"]?.status == "done" && rows["v-2.jpg"]?.tries == 0, "[\(label)] the finite vector's file is \(atDescribe(rows))")
            #expect(AtDB(path: pvIndexPath(t))?.int("select count(*) from passages") == 2, "[\(label)] the finite file should hold a name and an image passage")
        }
    }

    // MARK: Search ignores a stored non-finite vector

    @Test func oneNaNRowAndOneInfiniteRowAmongGoodRowsStillReturnTheGoodHitsInTheirOrder() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            try pvFill(store)
            store.close()

            // control: the clean index returns the five graded files, in dot order (hand-written, see SearchTests)
            do {
                let reader = IndexReader()
                defer { reader.close() }
                let clean = try pvRanked(Search(reader: reader))
                #expect(clean == pvGradedOrder, "setup: the clean index returned \(clean)")
            }

            let db = try #require(AtDB(path: pvIndexPath(t)))
            func passage(_ path: String) -> Int64? {
                db.int("select p.id from passages p join files f on f.id = p.file_id where f.path = '\(path)' and p.modality = 'image'").map { Int64($0) }
            }
            let nanRow = try #require(passage("/photos/b/n050.pdf"), "setup: no image passage for n050")
            let infRow = try #require(passage("/photos/b/n060.pdf"), "setup: no image passage for n060")
            #expect(pvSetVector(pvIndexPath(t), passage: nanRow, blob: pvBadBlob(0x7E00)) == nil, "setup: could not write the NaN vector")
            #expect(pvSetVector(pvIndexPath(t), passage: infRow, blob: pvBadBlob(0x7C00)) == nil, "setup: could not write the infinite vector")

            let reader = IndexReader()
            defer { reader.close() }
            let found = try pvRanked(Search(reader: reader))
            #expect(found == pvGradedOrder, "with one NaN row and one infinite row among 105 the hits are \(found), expected \(pvGradedOrder)")
        }
    }
}

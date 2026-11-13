import Foundation
import Testing
import SesameEngine

// plan-1 review round A, tester step: F6 (the keyword path loads every vector a second time only to map a passage
// id to a path) and F12 (the app's `IndexProgress.counts()` opens a second read connection for a GROUP BY).
// Both go through the one read connection, `IndexReader`. Written from the review report (F6, F12), the brief and
// design sections 1 and 3 only. Product source read for names: Sources/SesameEngine/IndexReader.swift and
// IndexStore.swift (public calls), and Sources/Sesame/StateViews.swift (what `IndexProgress.counts()` computes:
// files per kind and status).
//
// THE SHAPE THESE TESTS PIN (new API; today it does not exist, so this file does not compile until it does):
//
//     public struct KindStatusCount: Equatable, Sendable {
//         public let kind: String      // "photo", "pdf", "doc", ...
//         public let status: String    // "pending", "partial", "done", "could_not_read"
//         public let files: Int        // number of FILES (rows of `files`), not passages
//     }
//     IndexReader.statusCounts() -> [KindStatusCount]     // one entry per (kind, status) that has files; no zero entries; order not fixed
//     IndexReader.pathForPassage(_ id: Int64) -> String?  // the path of the file the passage belongs to, name passages included; nil for an id nobody has
//
// Like every IndexReader call: no throw, an empty answer (`[]`, nil) while there is no index file, and the open is
// tried again on each call, so rows show up once the store has made the file.

private func counted(_ counts: [KindStatusCount]) -> [String: Int] {
    var out: [String: Int] = [:]
    for count in counts { out["\(count.kind)|\(count.status)", default: 0] += count.files }
    return out
}

private func addFile(_ store: IndexStore, _ path: String, kind: String, status: String, inode: Int64) throws -> Int64 {
    try store.addFile(path: path, kind: kind, size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                      device: 1, status: status)
}

@Suite("IndexReaderCountsTests")
struct IndexReaderCountsTests {

    @Test func statusCountsGivesTheNumberOfFilesPerKindAndStatus() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            var inode: Int64 = 0
            func add(_ kind: String, _ status: String, _ count: Int, passages: Int = 0) throws {
                for number in 0..<count {
                    inode += 1
                    let file = try addFile(store, "/f/\(kind)-\(status)-\(number)", kind: kind, status: status, inode: inode)
                    for p in 0..<passages {
                        _ = try store.addPassage(fileID: file, source: "name", start: Double(p), end: Double(p), modality: "none",
                                                 vector: nil, name: "w", body: "")
                    }
                }
            }
            try add("photo", "done", 3, passages: 2)      // two passages a file: files are counted, not passages
            try add("photo", "pending", 2)
            try add("pdf", "partial", 1, passages: 3)
            try add("pdf", "could_not_read", 1)
            try add("pdf", "done", 1)
            try add("doc", "done", 2)

            let reader = IndexReader()
            defer { reader.close() }
            let counts = reader.statusCounts()
            let expected = ["photo|done": 3, "photo|pending": 2, "pdf|partial": 1, "pdf|could_not_read": 1, "pdf|done": 1, "doc|done": 2]
            #expect(counted(counts) == expected, "got \(counted(counts))")
            #expect(counts.count == expected.count, "one entry per kind and status, got \(counts.count): \(counted(counts))")
        }
    }

    @Test func aHandBuiltOldCodeRowIsStillCountedUnderCodeNextToTheFiveKinds() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            _ = try addFile(store, "/f/a.jpg", kind: "photo", status: "done", inode: 1)
            _ = try addFile(store, "/f/b.pdf", kind: "pdf", status: "pending", inode: 2)
            _ = try addFile(store, "/f/c.txt", kind: "doc", status: "done", inode: 3)
            _ = try addFile(store, "/f/d.mp3", kind: "audio", status: "partial", inode: 4)
            _ = try addFile(store, "/f/e.mp4", kind: "video", status: "done", inode: 5)
            _ = try addFile(store, "/f/old.py", kind: "code", status: "done", inode: 6)
            _ = try addFile(store, "/f/older.py", kind: "code", status: "done", inode: 7)
            _ = try addFile(store, "/f/oldest.py", kind: "code", status: "pending", inode: 8)

            let reader = IndexReader()
            defer { reader.close() }
            let expected = ["photo|done": 1, "pdf|pending": 1, "doc|done": 1, "audio|partial": 1, "video|done": 1,
                            "code|done": 2, "code|pending": 1]
            #expect(counted(reader.statusCounts()) == expected, "got \(counted(reader.statusCounts()))")
        }
    }

    @Test func statusCountsFollowsLaterWritesThroughTheSameReader() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.statusCounts().isEmpty, "no index file yet: no counts")

            let store = try IndexStore()
            defer { store.close() }
            _ = try addFile(store, "/f/a.jpg", kind: "photo", status: "pending", inode: 1)
            _ = try addFile(store, "/f/b.jpg", kind: "photo", status: "pending", inode: 2)
            #expect(counted(reader.statusCounts()) == ["photo|pending": 2], "got \(counted(reader.statusCounts()))")

            _ = try addFile(store, "/f/c.jpg", kind: "photo", status: "done", inode: 3)
            #expect(counted(reader.statusCounts()) == ["photo|pending": 2, "photo|done": 1], "got \(counted(reader.statusCounts()))")

            reader.close()
            #expect(counted(reader.statusCounts()) == ["photo|pending": 2, "photo|done": 1], "after close() the next call opens it again")
        }
    }

    @Test func pathForPassageGivesTheFilePathOfAnyPassageNamePassagesIncluded() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let fileA = try addFile(store, "/f/a.jpg", kind: "photo", status: "done", inode: 1)
            let fileB = try addFile(store, "/f/sub/b.txt", kind: "doc", status: "done", inode: 2)
            let nameA = try store.addPassage(fileID: fileA, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                             name: "a jpg", body: "")
            var unit = [Float](repeating: 0, count: 768); unit[0] = 1
            let imageA = try store.addPassage(fileID: fileA, source: "image", start: 0, end: 0, modality: "image", vector: unit,
                                              name: "", body: "words")
            let nameB = try store.addPassage(fileID: fileB, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                             name: "b txt", body: "")
            let chunkB = try store.addPassage(fileID: fileB, source: "chunk", start: 0, end: 0, modality: "text", vector: unit,
                                              name: "", body: "hello")

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.pathForPassage(nameA) == "/f/a.jpg", "a name passage (no vector) has a path, got \(String(describing: reader.pathForPassage(nameA)))")
            #expect(reader.pathForPassage(imageA) == "/f/a.jpg")
            #expect(reader.pathForPassage(nameB) == "/f/sub/b.txt")
            #expect(reader.pathForPassage(chunkB) == "/f/sub/b.txt")
            let unknown = max(nameA, imageA, nameB, chunkB) + 1000
            #expect(reader.pathForPassage(unknown) == nil, "an id nobody has gives nil")
            #expect(reader.pathForPassage(0) == nil)
            #expect(reader.pathForPassage(-1) == nil)
        }
    }

    @Test func withNoIndexFileTheNewCallsAnswerEmptyAndNilAndDoNotThrow() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.statusCounts().isEmpty)
            #expect(reader.pathForPassage(1) == nil)
        }
    }

    // The keyword path of the app maps ids to paths. A name passage has no vector, so it is not in
    // `vectoredPassages()`; the hit on it is still mapped to its path through the same connection (F5 and F6 together).
    @Test func aKeywordHitOnANamePassageIsMappedToItsPathWithoutLoadingVectors() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let file = try addFile(store, "/f/harbour-sunrise.png", kind: "photo", status: "done", inode: 1)
            let name = try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                            name: "harbour sunrise", body: "")
            let reader = IndexReader()
            defer { reader.close() }
            let ids = reader.keywordSearch("harbour sunrise")
            #expect(ids == [name], "keywordSearch found \(ids)")
            #expect(ids.compactMap { reader.pathForPassage($0) } == ["/f/harbour-sunrise.png"])
        }
    }
}

// plan-2-t24, tester step: `IndexReader.couldNotRead()`, the list behind Settings' "could not read" (spec: a damaged or
// password-protected file is "listed in Settings as could not read"; plan-2 R2: a photo the process cannot open is
// `needs_permission`). Written from the t24 entry (Tests: paragraph), design section 1 (the `files` columns: path,
// status, reason; no name column) and the sealed tests of this file; no product source read.
//
// THE SHAPE THESE TESTS PIN (new API; the entry names the call and the three facts of a row, not the row's type, so the
// tests use only `.path`, `.name` and `.reason` of each element and never name its type; if a shape is wrong, ask for a
// test change rather than guessing):
//
//     IndexReader.couldNotRead() -> [<row>]      // public, never throws, no argument
//     <row>.path    String   the file's full path, as stored in `files.path`
//     <row>.name    String   the file's name: the LAST COMPONENT of the path, extension kept ("locked.jpg"). Design
//                            section 1 gives `files` no name column, so the name is derived from the path (a pick of
//                            this file; the Settings row reads "<name>, <reason>")
//     <row>.reason  String (or String?)   `could_not_read` rows: the row's `reason` text as stored ("damaged",
//                            "password-protected", "needed too much memory"); `needs_permission` rows: "needs permission"
//
// Rows returned: status `could_not_read` or `needs_permission`, of any kind; never `pending`, `partial` or `done`.
// Order: by path, written here by hand over lower-case ASCII names that sort the same under any comparison. An empty
// answer while there is no index file; like every IndexReader call the open is tried again on each call.

/// A photo row that ended `could_not_read` with `reason`, made the way the helper makes one: the row is read from the
/// queue as `pending`, then marked (`IndexStore.markCouldNotRead(_:reason:)`, plan 1).
private func addCouldNotRead(_ store: IndexStore, _ path: String, reason: String, inode: Int64) throws {
    _ = try store.addFile(path: path, kind: "photo", size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                          device: 1, status: "pending")
    let queue = try store.pendingPhotos(limit: 50)
    let row = try #require(queue.first { $0.path == path }, "setup: pendingPhotos does not list \(path)")
    _ = try store.markCouldNotRead(row, reason: reason)
}

extension IndexReaderCountsTests {

    @Test func couldNotReadGivesPathNameAndReasonOfEveryUnreadableRowAndNothingElse() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try addCouldNotRead(store, "/f/a-bad.jpg", reason: "damaged", inode: 1)
            try addCouldNotRead(store, "/f/b-big.jpg", reason: "needed too much memory", inode: 2)
            _ = try addFile(store, "/f/m-locked.jpg", kind: "photo", status: "needs_permission", inode: 3)
            _ = try addFile(store, "/f/z-locked.pdf", kind: "pdf", status: "needs_permission", inode: 4)
            // none of these may come back
            _ = try addFile(store, "/f/c-done.jpg", kind: "photo", status: "done", inode: 5)
            _ = try addFile(store, "/f/d-pending.jpg", kind: "photo", status: "pending", inode: 6)
            _ = try addFile(store, "/f/e-partial.pdf", kind: "pdf", status: "partial", inode: 7)
            _ = try addFile(store, "/f/y-done.doc", kind: "doc", status: "done", inode: 8)

            let reader = IndexReader()
            defer { reader.close() }
            let rows = reader.couldNotRead()
            #expect(rows.map(\.path) == ["/f/a-bad.jpg", "/f/b-big.jpg", "/f/m-locked.jpg", "/f/z-locked.pdf"],
                    "paths: \(rows.map(\.path))")
            #expect(rows.map(\.name) == ["a-bad.jpg", "b-big.jpg", "m-locked.jpg", "z-locked.pdf"], "names: \(rows.map(\.name))")
            #expect(rows.map { $0.reason } == ["damaged", "needed too much memory", "needs permission", "needs permission"],
                    "reasons: \(rows.map { $0.reason })")
        }
    }

    @Test func couldNotReadIsSortedByPathWhateverTheOrderTheRowsWereWritten() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            var inode: Int64 = 0
            for path in ["/f/zz/last.jpg", "/f/mm/middle.jpg", "/f/aa/first.jpg", "/f/aa/second.jpg", "/g/other.jpg"] {
                inode += 1
                _ = try addFile(store, path, kind: "photo", status: "needs_permission", inode: inode)
            }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.couldNotRead().map(\.path)
                    == ["/f/aa/first.jpg", "/f/aa/second.jpg", "/f/mm/middle.jpg", "/f/zz/last.jpg", "/g/other.jpg"],
                    "paths: \(reader.couldNotRead().map(\.path))")
        }
    }

    @Test func theNameIsTheLastPathComponentWithItsExtension() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            _ = try addFile(store, "/f/deep/er/still/scan.final.png", kind: "photo", status: "needs_permission", inode: 1)
            let reader = IndexReader()
            defer { reader.close() }
            let rows = reader.couldNotRead()
            #expect(rows.map(\.name) == ["scan.final.png"], "names: \(rows.map(\.name))")
            #expect(rows.map(\.path) == ["/f/deep/er/still/scan.final.png"])
        }
    }

    @Test func rowsThatAreDonePendingOrPartialAreNeverReturned() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            var inode: Int64 = 0
            for (kind, status) in [("photo", "done"), ("photo", "pending"), ("pdf", "partial"), ("doc", "done"),
                                   ("audio", "pending"), ("video", "partial"), ("code", "done")] {
                inode += 1
                _ = try addFile(store, "/f/\(kind)-\(status)", kind: kind, status: status, inode: inode)
            }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.couldNotRead().isEmpty, "got \(reader.couldNotRead().map(\.path))")
        }
    }

    @Test func withNoIndexFileCouldNotReadIsEmptyAndDoesNotThrow() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.couldNotRead().isEmpty)
            #expect(reader.couldNotRead().isEmpty, "a second call with still no file")
        }
    }

    @Test func couldNotReadFollowsLaterWritesThroughTheSameReaderAndAfterClose() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.couldNotRead().isEmpty, "no index file yet")

            let store = try IndexStore()
            defer { store.close() }
            _ = try addFile(store, "/f/ok.jpg", kind: "photo", status: "done", inode: 1)
            #expect(reader.couldNotRead().isEmpty, "a done row is not listed")

            _ = try addFile(store, "/f/locked.jpg", kind: "photo", status: "needs_permission", inode: 2)
            #expect(reader.couldNotRead().map(\.path) == ["/f/locked.jpg"], "got \(reader.couldNotRead().map(\.path))")

            try addCouldNotRead(store, "/f/broken.jpg", reason: "damaged", inode: 3)
            #expect(reader.couldNotRead().map(\.path) == ["/f/broken.jpg", "/f/locked.jpg"],
                    "got \(reader.couldNotRead().map(\.path))")

            reader.close()
            #expect(reader.couldNotRead().map(\.path) == ["/f/broken.jpg", "/f/locked.jpg"], "after close() the next call opens it again")
        }
    }
}

// plan-2-t27, tester step: `IndexReader.lastIndexedPath()`, the file behind the menu's "Last indexed: <file name>" (S7.1).
// Written from the t27 entry ("the path of the `done` file whose passage has the greatest id (passage ids are never
// reused), nil when none"), design section 1 (`files.status`, `passages.id` never reused) and the sealed tests of this file;
// no product source read. Every expected path is written by hand from the order the rows were added here.
//
// THE SHAPE THESE TESTS PIN (new API; today it does not exist, so this file does not compile until it does):
//
//     IndexReader.lastIndexedPath() -> String?     // public, never throws, no argument; the full path as stored in `files.path`
//
// Like every IndexReader call: nil while there is no index file, and the open is tried again on each call.
//
// How a "latest" file is made here: `IndexStore.addPassage` hands out increasing ids, so the order of the `addPassage`
// calls is the order of the ids. A file that is read again gets new passages with greater ids than every passage written
// before (ids are not reused); the tests write a later passage for an earlier file to stand for that. The greatest FILE id
// is never the answer in these tests unless the passage order says so, so a reader that sorts by file id fails.

private func addPassageOf(_ store: IndexStore, _ file: Int64, _ position: Double = 0) throws -> Int64 {
    try store.addPassage(fileID: file, source: "name", start: position, end: position, modality: "none", vector: nil,
                         name: "w", body: "")
}

extension IndexReaderCountsTests {

    @Test func lastIndexedPathIsTheDoneFileWhoseLatestPassageHasTheGreatestId() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let fileA = try addFile(store, "/f/a.jpg", kind: "photo", status: "done", inode: 1)
            let fileB = try addFile(store, "/f/b.jpg", kind: "photo", status: "done", inode: 2)
            let fileC = try addFile(store, "/f/c.pdf", kind: "pdf", status: "done", inode: 3)
            _ = try addPassageOf(store, fileA)
            _ = try addPassageOf(store, fileB)
            _ = try addPassageOf(store, fileC)

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == "/f/c.pdf", "got \(String(describing: reader.lastIndexedPath()))")
        }
    }

    @Test func aLaterPassageOfAnEarlierFileMakesThatFileTheLastIndexedOne() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let fileA = try addFile(store, "/f/a.jpg", kind: "photo", status: "done", inode: 1)
            let fileB = try addFile(store, "/f/b.jpg", kind: "photo", status: "done", inode: 2)
            let fileC = try addFile(store, "/f/c.jpg", kind: "photo", status: "done", inode: 3)
            _ = try addPassageOf(store, fileA)
            _ = try addPassageOf(store, fileB)
            _ = try addPassageOf(store, fileC)
            // the first file is read again: its new passage has an id above every passage written so far
            _ = try addPassageOf(store, fileA, 1)

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == "/f/a.jpg", "got \(String(describing: reader.lastIndexedPath())), the file id order is not the answer")
        }
    }

    @Test func theGreatestPassageIdDecidesNotTheFileIdOrTheNumberOfPassages() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            // file ids 1, 2, 3 in this order; passages are written 2, 3, 1 with the biggest pile on file 3
            let fileA = try addFile(store, "/f/a.txt", kind: "doc", status: "done", inode: 1)
            let fileB = try addFile(store, "/f/b.txt", kind: "doc", status: "done", inode: 2)
            let fileC = try addFile(store, "/f/c.txt", kind: "doc", status: "done", inode: 3)
            _ = try addPassageOf(store, fileB)
            for position in 0..<5 { _ = try addPassageOf(store, fileC, Double(position)) }
            _ = try addPassageOf(store, fileA)

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == "/f/a.txt", "got \(String(describing: reader.lastIndexedPath()))")
        }
    }

    @Test func aFileThatIsNotDoneIsNeverTheLastIndexedOneEvenWithTheGreatestPassageId() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let done = try addFile(store, "/f/done.jpg", kind: "photo", status: "done", inode: 1)
            let partial = try addFile(store, "/f/partial.pdf", kind: "pdf", status: "partial", inode: 2)
            let pending = try addFile(store, "/f/pending.jpg", kind: "photo", status: "pending", inode: 3)
            let locked = try addFile(store, "/f/locked.jpg", kind: "photo", status: "needs_permission", inode: 4)
            _ = try addPassageOf(store, done)
            _ = try addPassageOf(store, partial)      // a long file read up to `read_to` has passages
            _ = try addPassageOf(store, pending)
            _ = try addPassageOf(store, locked)

            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == "/f/done.jpg", "got \(String(describing: reader.lastIndexedPath()))")
        }
    }

    @Test func withNoDoneFileTheAnswerIsNil() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == nil, "no index file yet")

            let store = try IndexStore()
            defer { store.close() }
            #expect(reader.lastIndexedPath() == nil, "an empty index")

            let partial = try addFile(store, "/f/partial.pdf", kind: "pdf", status: "partial", inode: 1)
            let pending = try addFile(store, "/f/pending.jpg", kind: "photo", status: "pending", inode: 2)
            _ = try addFile(store, "/f/locked.jpg", kind: "photo", status: "needs_permission", inode: 3)
            _ = try addPassageOf(store, partial)
            _ = try addPassageOf(store, pending)
            #expect(reader.lastIndexedPath() == nil, "rows that are not done: got \(String(describing: reader.lastIndexedPath()))")
        }
    }

    @Test func withNoIndexFileLastIndexedPathIsNilAndDoesNotThrow() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == nil)
            #expect(reader.lastIndexedPath() == nil, "a second call with still no file")
        }
    }

    @Test func lastIndexedPathFollowsLaterWritesThroughTheSameReaderAndAfterClose() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.lastIndexedPath() == nil, "no index file yet")

            let store = try IndexStore()
            defer { store.close() }
            let first = try addFile(store, "/f/first.jpg", kind: "photo", status: "done", inode: 1)
            _ = try addPassageOf(store, first)
            #expect(reader.lastIndexedPath() == "/f/first.jpg", "got \(String(describing: reader.lastIndexedPath()))")

            let second = try addFile(store, "/f/sub/second.txt", kind: "doc", status: "done", inode: 2)
            _ = try addPassageOf(store, second)
            #expect(reader.lastIndexedPath() == "/f/sub/second.txt", "got \(String(describing: reader.lastIndexedPath()))")

            _ = try addPassageOf(store, first, 1)
            #expect(reader.lastIndexedPath() == "/f/first.jpg", "the first file was read again, got \(String(describing: reader.lastIndexedPath()))")

            reader.close()
            #expect(reader.lastIndexedPath() == "/f/first.jpg", "after close() the next call opens it again")
        }
    }
}

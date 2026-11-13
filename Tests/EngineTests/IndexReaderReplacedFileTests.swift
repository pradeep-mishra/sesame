import Foundation
import Testing
import SesameEngine

// plan-2 fix round B, tester step, item B7 (the reader after Delete index): `IndexReader` must notice that `index.sqlite`
// was replaced or deleted and reopen, so after a delete and a new index the menu, counts and search show the new index.
// Written from the fix-round document (B7: "Test with a real file: open, query, delete and recreate the file with other
// rows, query again, expect the new rows (store-level, Engine tests)"), the reviewer's measurement (a read-only SQLite
// connection kept open across a delete and a recreate kept answering from the old rows) and the sealed
// IndexReaderCountsTests (the calls `statusCounts()`, `pathForPassage(_:)`, `keywordSearch(_:)`, `couldNotRead()`, `close()`
// and the rule "no throw, an empty answer while there is no index file"). No product source was read. Every expected
// count and path below is written by hand from the rows each test stores.
//
// The index file is `<Sesame folder>/index.sqlite` with its `-wal` and `-shm` beside it (the name the sealed
// DeleteIndexTests plant). "Replaced" here moves the three files aside and lets a second `IndexStore` make a new
// `index.sqlite`, so the old file keeps its inode and the reader still holds a live handle on it: that is the stale case.
//
// WHAT THE RED MEANS. Today the reader opens once and reuses its connection while it is open, so after the file is
// replaced it keeps answering from the old rows (the first, third and fourth tests fail on their first expectation) and
// after the file is deleted it keeps answering from the deleted file (the second test fails).

private let indexNames = ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"]

private func add(_ store: IndexStore, _ path: String, kind: String = "photo", status: String = "done", inode: Int64) throws -> Int64 {
    try store.addFile(path: path, kind: kind, size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode, device: 1, status: status)
}

private func counted(_ counts: [KindStatusCount]) -> [String: Int] {
    var out: [String: Int] = [:]
    for count in counts { out["\(count.kind)|\(count.status)", default: 0] += count.files }
    return out
}

// Moves the index files that exist into `aside/` (the old file stays alive for anyone who still holds it open).
private func moveAside(_ t: TempHome) throws {
    let fm = FileManager.default
    let aside = t.folder.appendingPathComponent("aside", isDirectory: true)
    try fm.createDirectory(at: aside, withIntermediateDirectories: true)
    for name in indexNames {
        let from = t.folder.appendingPathComponent(name)
        if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: aside.appendingPathComponent(name)) }
    }
}

private func deleteIndexFiles(_ t: TempHome) throws {
    let fm = FileManager.default
    for name in indexNames {
        let url = t.folder.appendingPathComponent(name)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
}

@Suite("IndexReaderReplacedFileTests")
struct IndexReaderReplacedFileTests {

    @Test func afterTheIndexFileIsReplacedTheReaderCountsTheNewFilesRows() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let reader = IndexReader()
            defer { reader.close() }

            let old = try IndexStore()
            for number in 1...3 { _ = try add(old, "/old/photo-\(number).jpg", inode: Int64(number)) }
            old.close()
            #expect(counted(reader.statusCounts()) == ["photo|done": 3], "the old index: \(counted(reader.statusCounts()))")

            try moveAside(t)
            let new = try IndexStore()
            defer { new.close() }
            _ = try add(new, "/new/a.jpg", status: "pending", inode: 11)
            _ = try add(new, "/new/b.pdf", kind: "pdf", status: "done", inode: 12)

            let expected = ["photo|pending": 1, "pdf|done": 1]
            #expect(counted(reader.statusCounts()) == expected,
                    "after the file was replaced the reader still answers \(counted(reader.statusCounts())), the new file holds \(expected)")
        }
    }

    @Test func afterTheIndexFileIsDeletedTheReaderAnswersEmptyAndThenFollowsTheNextIndex() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let reader = IndexReader()
            defer { reader.close() }

            let old = try IndexStore()
            for number in 1...4 { _ = try add(old, "/old/photo-\(number).jpg", inode: Int64(number)) }
            let passage = try old.addPassage(fileID: try add(old, "/old/harbour.png", inode: 9), source: "name", start: 0, end: 0,
                                             modality: "none", vector: nil, name: "harbour sunrise", body: "")
            old.close()
            #expect(counted(reader.statusCounts()) == ["photo|done": 5])
            #expect(reader.keywordSearch("harbour sunrise") == [passage], "setup: the old index finds its own file")

            try deleteIndexFiles(t)
            #expect(reader.statusCounts().isEmpty, "the index file is gone but the reader still counts \(counted(reader.statusCounts()))")
            #expect(reader.keywordSearch("harbour sunrise").isEmpty, "the index file is gone but the keyword search still finds rows")
            #expect(reader.couldNotRead().isEmpty)
            #expect(reader.pathForPassage(passage) == nil, "a passage of the deleted index still maps to \(String(describing: reader.pathForPassage(passage)))")

            // a new index appears: the same reader follows it
            let new = try IndexStore()
            defer { new.close() }
            _ = try add(new, "/new/only.jpg", status: "pending", inode: 21)
            #expect(counted(reader.statusCounts()) == ["photo|pending": 1], "the new index: \(counted(reader.statusCounts()))")
        }
    }

    @Test func afterTheIndexFileIsReplacedSearchAndPathsComeFromTheNewFileOnly() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let reader = IndexReader()
            defer { reader.close() }

            let old = try IndexStore()
            let oldFile = try add(old, "/old/harbour.png", inode: 1)
            let oldPassage = try old.addPassage(fileID: oldFile, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                                name: "harbour sunrise", body: "")
            old.close()
            #expect(reader.keywordSearch("harbour") == [oldPassage])
            #expect(reader.pathForPassage(oldPassage) == "/old/harbour.png")

            try moveAside(t)
            let new = try IndexStore()
            defer { new.close() }
            let newFile = try add(new, "/new/forest.png", inode: 2)
            let newPassage = try new.addPassage(fileID: newFile, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                                name: "forest morning", body: "")

            #expect(reader.keywordSearch("harbour").isEmpty, "a word of the old index still finds \(reader.keywordSearch("harbour")) after the replace")
            #expect(reader.keywordSearch("forest") == [newPassage], "the new index is not searched: \(reader.keywordSearch("forest"))")
            #expect(reader.pathForPassage(newPassage) == "/new/forest.png",
                    "the new passage maps to \(String(describing: reader.pathForPassage(newPassage)))")
        }
    }

    @Test func afterTheIndexFileIsReplacedTheCouldNotReadListIsTheNewFilesList() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let reader = IndexReader()
            defer { reader.close() }

            let old = try IndexStore()
            _ = try add(old, "/old/locked.jpg", status: "needs_permission", inode: 1)
            old.close()
            #expect(reader.couldNotRead().map(\.path) == ["/old/locked.jpg"], "setup: \(reader.couldNotRead().map(\.path))")

            try moveAside(t)
            let new = try IndexStore()
            defer { new.close() }
            _ = try add(new, "/new/fine.jpg", inode: 2)
            _ = try add(new, "/new/secret.pdf", kind: "pdf", status: "needs_permission", inode: 3)

            #expect(reader.couldNotRead().map(\.path) == ["/new/secret.pdf"],
                    "after the replace the list is \(reader.couldNotRead().map(\.path)), the new file lists only /new/secret.pdf")
        }
    }
}

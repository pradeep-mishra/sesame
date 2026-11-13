import Foundation
import Testing
import SesameEngine

// plan-5-t7, tester step. Written from the entry plan-5-t7 of plan-5-tasks.md (Files: "`IndexStore.reconcile` takes the kinds that are
// off"; Tests: `IndexReconcileKindsTests`), spec S4.6 and S7, and the sealed IndexReconcileMovesTests.swift as the one place the existing
// names are read (`IndexStore.addFile`, `addPassage`, `reconcile(_:unreadable:vectorSource:walkDoneAt:)` and its outcome's `added` and
// `removed`, `Walker.scan(root:mode:)`, `WalkedFile`, `AtDB`). No product source is read.
//
// THE SHAPE THIS FILE PINS (the entry says "takes the kinds that are off" and fixes no signature; if it is wrong, ask for a test change,
// `krReconcile` below is the one place to edit):
//   reconcile(_ found:, unreadable:, vectorSource:, walkDoneAt:, kindsOff: Set<String> = [])
// `kindsOff` is the set of `files.kind` words whose switch is off ("audio", "video", "pdf", "doc"), the last parameter, defaulted to the
// empty set so every sealed call compiles unchanged. A walked file whose kind is in `kindsOff` is treated by this reconcile as if the walk
// had not found it for ADDING: no row is made. What it does to a row that already exists is pinned below (the entry fixes it: "rows of
// audio already in the index when the switch goes off stay, unchanged (same ids, same passages, none re-read)").
//
// What the entry does not fix and this file pins, each one place to edit:
//   1. A row of an off kind that is `done` or `partial` and whose file is still there and unchanged is left exactly as it is by a
//      reconcile with that kind off (every column of the row, every passage id), however many times it runs.
//   2. A file of an off kind that is deleted from disk is still removed from the index by a reconcile (S7: a deleted file disappears from
//      the index within 30 seconds; the switch hides results, it does not keep a row of a file that is gone).
//   3. `outcome.added` counts only the rows made: a skipped file of an off kind adds 0.
// Not pinned, on purpose: what a reconcile does to a CHANGED file (new size or time) of an off kind, a moved or renamed one, and the
// row of an off kind whose file is gone while the kind is off and comes back.
//
// `WalkedFile` cannot be built outside the module, so every walk is a real `Walker.scan` of a real temp tree; the expected kinds are
// written here by hand and a setup check shows the walk reports them. The rows are written with `addFile` and `addPassage` from what the
// walk saw, so the ids and the columns the test expects are read from the index file with the test's own read-only connection before the
// reconcile and compared after it.

private let krDevice: Int64 = 1

// One sample file per kind: (kind word of `files.kind`, relative path, how many bytes).
private let krFiles: [(kind: String, name: String, bytes: Int)] = [
    ("photo", "pics/harbour.jpg", 111),
    ("audio", "pics/talk.wav", 222),
    ("video", "pics/clip.mp4", 333),
    ("pdf", "pics/paper.pdf", 444),
    ("doc", "pics/note.txt", 555),
]

private final class KrTree {
    let base: String
    private var made = 0

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-kinds-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { base + "/" + relative }

    /// A file of its own size and its own past modified time (never "modified a moment ago").
    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> String {
        made += 1
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: UInt8(truncatingIfNeeded: made), count: bytes).write(to: URL(fileURLWithPath: full))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(made))],
                                              ofItemAtPath: full)
        return full
    }

    func fillAll() throws {
        for item in krFiles { try file(item.name, bytes: item.bytes) }
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

private func krWithTree(_ body: (KrTree) throws -> Void) throws {
    let tree = try KrTree()
    defer { tree.remove() }
    try body(tree)
}

private typealias KrFound = [(file: WalkedFile, device: Int64)]

private func krWalk(_ roots: [String]) -> (found: KrFound, unreadable: [String]) {
    var found: KrFound = []
    var unreadable: [String] = []
    for root in roots {
        let scanned = Walker.scan(root: root, mode: .read)
        found += scanned.files.map { (file: $0, device: krDevice) }
        unreadable += scanned.unreadable
    }
    return (found, unreadable)
}

private func krVector(_ phase: Double) -> [Float] {
    (0..<768).map { Float(sin(Double($0) * 0.37 + phase) * 0.9) }
}

/// One row per walked file with the given status, each with a `name` passage and an image passage (the passages are the test's own).
private func krSeed(_ store: IndexStore, _ found: KrFound, status: (String) -> String) throws {
    var phase = 0.0
    for entry in found {
        phase += 0.7
        let id = try store.addFile(path: entry.file.path, kind: entry.file.kind, size: entry.file.size,
                                   mtimeNs: entry.file.mtimeNs, inode: Int64(entry.file.inode),
                                   device: entry.device, status: status(entry.file.kind))
        _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                 name: URL(fileURLWithPath: entry.file.path).lastPathComponent.lowercased(), body: "")
        _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image",
                                 vector: krVector(phase), name: "", body: "")
    }
}

private func krReconcile(_ store: IndexStore, _ walk: (found: KrFound, unreadable: [String]), off: Set<String>,
                         stamp: String) throws -> (added: Int, removed: Int) {
    let outcome = try store.reconcile(walk.found, unreadable: walk.unreadable, vectorSource: "v", walkDoneAt: stamp, kindsOff: off)
    return (Int(outcome.added), Int(outcome.removed))
}

// MARK: reading the index file, independent of the product

private func krIndexPath(_ home: TempHome) -> String {
    home.folder.appendingPathComponent("index.sqlite").path
}

/// The identity and state columns of every `files` row, by path, as text. Column names are the ones the sealed tests read
/// (`id`, `kind`, `size`, `mtime_ns`, `inode`, `status`, `reason`, `read_to`, `tries`); a column that does not exist would make the
/// query fail and the result empty, which every test that compares rows guards with a non-empty setup check.
private func krRows(_ home: TempHome) -> [String: String] {
    guard let db = AtDB(path: krIndexPath(home)),
          let rows = db.rows("select path, id, kind, size, mtime_ns, inode, status, reason, read_to, tries from files order by id")
    else { return [:] }
    var out: [String: String] = [:]
    for row in rows {
        guard let path = row[0] else { continue }
        out[path] = row.dropFirst().map { $0 ?? "NULL" }.joined(separator: "|")
    }
    return out
}

private func krKinds(_ home: TempHome) -> [String: String] {
    guard let db = AtDB(path: krIndexPath(home)), let rows = db.rows("select path, kind from files") else { return [:] }
    var out: [String: String] = [:]
    for row in rows { if let path = row[0], let kind = row[1] { out[path] = kind } }
    return out
}

/// The passage ids of every file, by path, ascending.
private func krPassageIDs(_ home: TempHome) -> [String: [Int]] {
    guard let db = AtDB(path: krIndexPath(home)),
          let rows = db.rows("select f.path, p.id from files f join passages p on p.file_id = f.id order by p.id") else { return [:] }
    var out: [String: [Int]] = [:]
    for row in rows { if let path = row[0], let text = row[1], let id = Int(text) { out[path, default: []].append(id) } }
    return out
}

private func krCount(_ home: TempHome, _ sql: String) -> Int {
    AtDB(path: krIndexPath(home))?.int(sql) ?? -1
}

private let krOffKinds = ["audio", "video", "pdf", "doc"]

@Suite("IndexReconcileKindsTests")
struct IndexReconcileKindsTests {

    // The setup check the other tests rest on: the real walk reports the kind words this file writes by hand.
    @Test func theWalkReportsTheFiveKindWordsThisFileExpects() throws {
        try krWithTree { tree in
            try tree.fillAll()
            let found = krWalk([tree.path("pics")]).found
            #expect(found.count == 5, "the walk found \(found.map { $0.file.path })")
            for item in krFiles {
                #expect(found.first { $0.file.path == tree.path(item.name) }?.file.kind == item.kind,
                        "setup: \(item.name) is not reported as \(item.kind): \(found.map { "\($0.file.path) \($0.file.kind)" })")
            }
        }
    }

    // MARK: a new file of a kind that is off gets no row

    @Test(arguments: krOffKinds)
    func aNewFileOfAKindThatIsOffGetsNoRowWhileThePhotoBesideItGetsOne(kind: String) throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()
                let item = try #require(krFiles.first { $0.kind == kind })

                let outcome = try krReconcile(store, krWalk([tree.path("pics")]), off: [kind], stamp: "t1")

                let kinds = krKinds(home)
                #expect(kinds[tree.path(item.name)] == nil, "\(kind) is off and \(item.name) has a row: \(kinds)")
                #expect(kinds[tree.path("pics/harbour.jpg")] == "photo", "the photo has no row: \(kinds)")
                #expect(Set(kinds.values) == Set(krFiles.map(\.kind)).subtracting([kind]), "rows by kind: \(kinds)")
                #expect(kinds.count == 4, "rows: \(kinds.keys.sorted()), expected the 4 files of the kinds that are on")
                #expect(outcome.added == 4, "a skipped file of an off kind adds nothing; added \(outcome.added), expected 4")
                #expect(outcome.removed == 0)
                #expect(krCount(home, "select count(*) from files where kind = '\(kind)'") == 0, "a \(kind) row exists")
            }
        }
    }

    @Test func audioAndVideoBothOffGetNoRowAndPdfAndDocumentsAreStillAdded() throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()

                let outcome = try krReconcile(store, krWalk([tree.path("pics")]), off: ["audio", "video"], stamp: "t1")

                let kinds = krKinds(home)
                #expect(Set(kinds.values) == ["photo", "pdf", "doc"], "rows by kind: \(kinds)")
                #expect(kinds.count == 3 && outcome.added == 3, "rows \(kinds.count), added \(outcome.added), expected 3 and 3")
            }
        }
    }

    @Test func withNoKindOffEveryFileIsAddedAsBefore() throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()

                let outcome = try krReconcile(store, krWalk([tree.path("pics")]), off: [], stamp: "t1")

                #expect(Set(krKinds(home).values) == ["photo", "audio", "video", "pdf", "doc"], "rows by kind: \(krKinds(home))")
                #expect(outcome.added == 5, "added \(outcome.added), expected 5")
            }
        }
    }

    @Test func theSealedFourArgumentCallStillAddsEveryFile() throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()
                let walk = krWalk([tree.path("pics")])

                let outcome = try store.reconcile(walk.found, unreadable: walk.unreadable, vectorSource: "v", walkDoneAt: "t1")

                #expect(Int(outcome.added) == 5, "added \(outcome.added), expected 5")
                #expect(krKinds(home).count == 5)
            }
        }
    }

    // MARK: rows that were already there stay, unchanged

    @Test(arguments: krOffKinds, ["done", "partial"])
    func aRowOfAKindThatGoesOffStaysUnchangedThroughFurtherReconcilesWhateverItsStatus(kind: String, status: String) throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()
                let root = tree.path("pics")
                try krSeed(store, krWalk([root]).found, status: { $0 == kind ? status : "done" })
                let rowsBefore = krRows(home)
                let idsBefore = krPassageIDs(home)
                let item = try #require(krFiles.first { $0.kind == kind })
                #expect(rowsBefore.count == 5 && idsBefore[tree.path(item.name)]?.count == 2, "setup: \(rowsBefore.count) rows, passages \(idsBefore)")

                for round in 1...3 {
                    let outcome = try krReconcile(store, krWalk([root]), off: [kind], stamp: "t\(round)")
                    #expect(outcome.added == 0 && outcome.removed == 0, "round \(round): added \(outcome.added), removed \(outcome.removed)")
                    #expect(krRows(home) == rowsBefore, "round \(round): a row changed (\(kind), \(status)): \(krRows(home))")
                    #expect(krPassageIDs(home) == idsBefore, "round \(round): passages changed or were read again (\(kind), \(status)): \(krPassageIDs(home))")
                }
                #expect(krRows(home)[tree.path(item.name)]?.contains(status) == true, "the \(kind) row is no longer \(status)")
            }
        }
    }

    @Test func everyKindOffTogetherLeavesAllTheirRowsUnchanged() throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()
                let root = tree.path("pics")
                try krSeed(store, krWalk([root]).found, status: { $0 == "video" ? "partial" : "done" })
                let rowsBefore = krRows(home)
                let idsBefore = krPassageIDs(home)
                #expect(rowsBefore.count == 5 && idsBefore.count == 5, "setup: \(rowsBefore.count) rows, passages of \(idsBefore.count) files")

                let outcome = try krReconcile(store, krWalk([root]), off: Set(krOffKinds), stamp: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed)")
                #expect(krRows(home) == rowsBefore, "a row changed: \(krRows(home))")
                #expect(krPassageIDs(home) == idsBefore, "passages changed: \(krPassageIDs(home))")
            }
        }
    }

    // MARK: a new file while the kind is off, then the kind comes back

    @Test(arguments: krOffKinds)
    func aFileCreatedWhileTheKindIsOffHasNoRowAndTheNextReconcileWithItOnAddsItAndKeepsEveryOldRowId(kind: String) throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()
                let root = tree.path("pics")
                try krSeed(store, krWalk([root]).found, status: { _ in "done" })
                let rowsBefore = krRows(home)
                let idsBefore = krPassageIDs(home)
                let item = try #require(krFiles.first { $0.kind == kind })
                #expect(rowsBefore.count == 5 && idsBefore.count == 5, "setup: \(rowsBefore.count) rows, passages of \(idsBefore.count) files")
                let ext = (item.name as NSString).pathExtension
                let newName = "pics/fresh-\(kind).\(ext)"

                try tree.file(newName, bytes: 666)
                let whileOff = try krReconcile(store, krWalk([root]), off: [kind], stamp: "t1")
                #expect(whileOff.added == 0 && whileOff.removed == 0, "while off: added \(whileOff.added), removed \(whileOff.removed)")
                #expect(krKinds(home)[tree.path(newName)] == nil, "a \(kind) file created while \(kind) is off has a row")
                let secondOff = try krReconcile(store, krWalk([root]), off: [kind], stamp: "t2")
                #expect(secondOff.added == 0, "a second reconcile with the kind off added \(secondOff.added)")
                #expect(krKinds(home)[tree.path(newName)] == nil)
                #expect(krRows(home) == rowsBefore, "an old row changed while the kind was off")

                let backOn = try krReconcile(store, krWalk([root]), off: [], stamp: "t3")
                #expect(backOn.added == 1 && backOn.removed == 0, "back on: added \(backOn.added), removed \(backOn.removed), expected 1 and 0")
                #expect(krKinds(home)[tree.path(newName)] == kind, "the new file has no \(kind) row after the kind came back")
                let rowsNow = krRows(home)
                for (path, row) in rowsBefore {
                    #expect(rowsNow[path] == row, "the old row of \(path) changed when the kind came back")
                }
                let idsNow = krPassageIDs(home)
                for (path, ids) in idsBefore {
                    #expect(idsNow[path] == ids, "the passages of \(path) changed when the kind came back: \(String(describing: idsNow[path])), were \(ids)")
                }
            }
        }
    }

    // MARK: a kind that is on is not touched by another kind being off

    @Test func audioOffDoesNotStopANewVideoPdfOrDocumentFromBeingAdded() throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("pics")
                try tree.file("pics/harbour.jpg", bytes: 111)
                try krSeed(store, krWalk([root]).found, status: { _ in "done" })

                try tree.file("pics/new-talk.wav", bytes: 120)
                try tree.file("pics/new-clip.mp4", bytes: 130)
                try tree.file("pics/new-paper.pdf", bytes: 140)
                try tree.file("pics/new-note.txt", bytes: 150)
                let outcome = try krReconcile(store, krWalk([root]), off: ["audio"], stamp: "t1")

                #expect(outcome.added == 3, "audio is off: added \(outcome.added), expected video, pdf and doc = 3")
                let kinds = krKinds(home)
                #expect(kinds[tree.path("pics/new-talk.wav")] == nil, "an audio file was added while audio is off")
                #expect(kinds[tree.path("pics/new-clip.mp4")] == "video")
                #expect(kinds[tree.path("pics/new-paper.pdf")] == "pdf")
                #expect(kinds[tree.path("pics/new-note.txt")] == "doc")
            }
        }
    }

    // MARK: a file that is gone is still removed

    @Test(arguments: krOffKinds)
    func aFileOfAnOffKindThatIsDeletedFromDiskIsStillRemovedFromTheIndex(kind: String) throws {
        try krWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                try tree.fillAll()
                let root = tree.path("pics")
                try krSeed(store, krWalk([root]).found, status: { _ in "done" })
                let item = try #require(krFiles.first { $0.kind == kind })
                let rowsBefore = krRows(home)
                #expect(rowsBefore.count == 5, "setup: \(rowsBefore.count) rows")

                try FileManager.default.removeItem(atPath: tree.path(item.name))
                let outcome = try krReconcile(store, krWalk([root]), off: [kind], stamp: "t1")

                #expect(outcome.removed == 1 && outcome.added == 0, "added \(outcome.added), removed \(outcome.removed), expected 0 and 1")
                #expect(krRows(home)[tree.path(item.name)] == nil, "the row of the deleted \(kind) file is still there")
                #expect(krCount(home, "select count(*) from passages where file_id not in (select id from files)") == 0,
                        "passages of the removed row are left over")
                for (path, row) in rowsBefore where path != tree.path(item.name) {
                    #expect(krRows(home)[path] == row, "the row of \(path) changed")
                }
            }
        }
    }
}

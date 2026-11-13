import Foundation
import Testing
import SesameEngine

// plan-2-t39, tester step (S7.6, S7.7, S7.9, S7.15, S1.6). Written from the t39 entry, plan-2 Decisions D10, design
// sections 1, 3 and 9 and the spec line on moved, renamed and unplugged files only. Product source read for nothing.
// Names used (all exist today and are pinned by sealed tests): `IndexStore.addFile`, `addPassage`, `reconcile(_:unreadable:
// vectorSource:walkDoneAt:)` and its outcome's `added` and `removed`, `Walker.scan(root:mode:)` and `WalkedFile`
// (`path`, `kind`, `size`, `mtimeNs`, `inode`), `IndexReader.keywordSearch` and `meta`.
//
// THE SHAPE THESE TESTS PIN: no new call. The store's `reconcile` already takes a walk (the files found under every
// ticked folder, each with its device) and the list of unreadable folders. Plan 2 changes what it DOES with a file whose
// path vanished and whose device, inode, size and modified time match a file at a new path:
//   - it keeps the row: same `files.id`, same `status`, the image passage kept untouched (nothing is read again);
//   - the row takes the new path and its `name` passage words are rewritten for the new file name and folder name, so
//     `IndexReader.keywordSearch` finds the file by the new words and no longer by the old ones;
//   - all of that, with every other change of the same reconcile, in ONE transaction;
//   - `outcome.added` and `outcome.removed` count new files and deleted rows only, so a pure move or rename is 0 and 0.
// A moved file whose size or modified time differs is a changed file (the row is `pending` again at the new path). A
// copy (a new inode) is a new file. Two files that swap names, or a chain of renames, are both handled even though a
// row's path is UNIQUE.
//
// `WalkedFile` cannot be built outside the module, so every walk here is a real `Walker.scan` of a real temp tree. The
// "hand-built" part is the rows: the test writes them with `addFile` and `addPassage` from what the walk saw (a `name`
// passage whose words are the folder name and the file name, and an image passage with a vector), so the words and the
// ids the test expects are the test's own. Rename, move, copy and delete are done on the real tree with `FileManager`.
// Every name word is unique letters only, so a keyword match is exact.
//
// Where the expected value comes from: row ids, passage ids, paths, sizes, modified times and inodes are read from the
// index file with the test's own read-only connection (`AtDB`, IndexAttemptTests.swift) and compared with what the test
// wrote before the reconcile and with `stat` of the tree afterwards.

private let mvDevice: Int64 = 1

private final class MvTree {
    let base: String
    private var made = 0
    private var locked: [(path: String, mode: mode_t)] = []

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-moves-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { base + "/" + relative }

    /// A photo-named file with its own size and its own past modified time (never "modified a moment ago").
    @discardableResult
    func photo(_ relative: String) throws -> String {
        made += 1
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: UInt8(truncatingIfNeeded: made), count: 100 + made).write(to: URL(fileURLWithPath: full))
        try setTime(full, atPast - Double(made))
        return full
    }

    func setTime(_ full: String, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: full)
    }

    func move(_ from: String, _ to: String) throws {
        let target = path(to)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path(from), toPath: target)
    }

    func lock(_ relative: String) {
        let full = path(relative)
        var info = stat()
        guard stat(full, &info) == 0 else { return }
        locked.append((full, info.st_mode & 0o7777))
        chmod(full, 0)
    }

    func remove() {
        for item in locked.reversed() { chmod(item.path, item.mode) }
        try? FileManager.default.removeItem(atPath: base)
    }
}

private func mvWithTree(_ body: (MvTree) throws -> Void) throws {
    let tree = try MvTree()
    defer { tree.remove() }
    try body(tree)
}

private func mvCanTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root lists through chmod 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

private typealias MvFound = [(file: WalkedFile, device: Int64)]

/// A real walk of each root, in read mode, put together the way the helper's one reconcile gets it.
private func mvWalk(_ roots: [String]) -> (found: MvFound, unreadable: [String]) {
    var found: MvFound = []
    var unreadable: [String] = []
    for root in roots {
        let scanned = Walker.scan(root: root, mode: .read)
        found += scanned.files.map { (file: $0, device: mvDevice) }
        unreadable += scanned.unreadable
    }
    return (found, unreadable)
}

/// The words the test puts in a `name` passage: the folder name and the file name, lowercase.
private func mvWords(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return (url.deletingLastPathComponent().lastPathComponent + " " + url.deletingPathExtension().lastPathComponent).lowercased()
}

private func mvVector(_ phase: Double) -> [Float] {
    (0..<768).map { Float(sin(Double($0) * 0.37 + phase) * 0.9) }
}

/// One `done` row per walked file (a path met twice gets one row), each with a `name` passage and an image passage.
private func mvSeed(_ store: IndexStore, _ found: MvFound) throws {
    var seen = Set<String>()
    var phase = 0.0
    for entry in found where seen.insert(entry.file.path).inserted {
        phase += 0.7
        let id = try store.addFile(path: entry.file.path, kind: entry.file.kind, size: entry.file.size,
                                   mtimeNs: entry.file.mtimeNs, inode: Int64(entry.file.inode),
                                   device: entry.device, status: "done")
        _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                 name: mvWords(entry.file.path), body: "")
        _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image",
                                 vector: mvVector(phase), name: "", body: "")
    }
}

private func mvReconcile(_ store: IndexStore, _ walk: (found: MvFound, unreadable: [String]),
                         stamp: String) throws -> (added: Int, removed: Int) {
    let outcome = try store.reconcile(walk.found, unreadable: walk.unreadable, vectorSource: "v", walkDoneAt: stamp)
    return (Int(outcome.added), Int(outcome.removed))
}

// MARK: reading the index file, independent of the product

private struct MvRow: Equatable {
    let id: Int64
    let path: String
    let status: String
    let size: Int64
    let mtimeNs: Int64
    let inode: Int64
}

private struct MvPassage: Equatable {
    let id: Int64
    let source: String
}

private func mvIndexPath(_ home: TempHome) -> String {
    home.folder.appendingPathComponent("index.sqlite").path
}

private func mvRows(_ home: TempHome) -> [String: MvRow] {
    guard let db = AtDB(path: mvIndexPath(home)),
          let rows = db.rows("select id, path, status, size, mtime_ns, inode from files") else { return [:] }
    var out: [String: MvRow] = [:]
    for row in rows {
        guard let id = Int64(row[0] ?? ""), let path = row[1], let status = row[2], let size = Int64(row[3] ?? ""),
              let mtime = Int64(row[4] ?? ""), let inode = Int64(row[5] ?? "") else { continue }
        out[path] = MvRow(id: id, path: path, status: status, size: size, mtimeNs: mtime, inode: inode)
    }
    return out
}

/// The passages of every file, by `files.id`, in id order.
private func mvPassages(_ home: TempHome) -> [Int64: [MvPassage]] {
    guard let db = AtDB(path: mvIndexPath(home)),
          let rows = db.rows("select file_id, id, source from passages order by id") else { return [:] }
    var out: [Int64: [MvPassage]] = [:]
    for row in rows {
        guard let fileID = Int64(row[0] ?? ""), let id = Int64(row[1] ?? ""), let source = row[2] else { continue }
        out[fileID, default: []].append(MvPassage(id: id, source: source))
    }
    return out
}

private func mvCount(_ home: TempHome, _ sql: String) -> Int {
    AtDB(path: mvIndexPath(home))?.int(sql) ?? -1
}

/// The id of the `name` passage of the row at `path`.
private func mvNameID(_ home: TempHome, _ rows: [String: MvRow], _ path: String) -> Int64? {
    guard let row = rows[path] else { return nil }
    return mvPassages(home)[row.id]?.first { $0.source == "name" }?.id
}

private func mvHits(_ reader: IndexReader, _ word: String) -> Set<Int64> {
    Set(reader.keywordSearch(word))
}

private func mvStat(_ path: String) -> (size: Int64, mtimeNs: Int64, inode: Int64)? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return (Int64(info.st_size),
            Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            Int64(info.st_ino))
}

/// The row of a file the test moved: same row id and status, the image passage and the passage count untouched, the
/// path, size, time and inode of the file as it is now.
private func mvExpectKept(_ home: TempHome, before: [String: MvRow], passagesBefore: [Int64: [MvPassage]],
                          from oldPath: String, to newPath: String, _ label: String) {
    let rows = mvRows(home)
    guard let was = before[oldPath] else {
        Issue.record("\(label): setup: no row was seeded for \(oldPath)")
        return
    }
    guard let now = rows[newPath] else {
        Issue.record("\(label): no row at the new path \(newPath); rows are \(rows.keys.sorted())")
        return
    }
    #expect(rows[oldPath] == nil, "\(label): a row is still at the old path \(oldPath)")
    #expect(now.id == was.id, "\(label): the row id was \(was.id) and is now \(now.id); a moved file must keep its row")
    #expect(now.status == "done", "\(label): the moved file's status is \(now.status), expected done (it must not be read again)")
    #expect(now.inode == was.inode, "\(label): the inode changed, so the test moved the wrong thing")
    if let info = mvStat(newPath) {
        #expect(now.size == info.size && now.mtimeNs == info.mtimeNs && now.inode == info.inode,
                "\(label): the row holds size \(now.size), time \(now.mtimeNs), inode \(now.inode); the file is \(info)")
    }
    let passagesNow = mvPassages(home)[now.id] ?? []
    let imageBefore = passagesBefore[was.id]?.filter { $0.source == "image" } ?? []
    #expect(passagesNow.filter { $0.source == "image" } == imageBefore,
            "\(label): the image passage changed from \(imageBefore) to \(passagesNow); it must not be read again")
    #expect(passagesNow.filter { $0.source == "name" }.count == 1, "\(label): the row should hold exactly one name passage, has \(passagesNow)")
}

// MARK: the suite

@Suite("IndexReconcileMovesTests")
struct IndexReconcileMovesTests {

    // MARK: a rename or move keeps the row

    @Test func aFileRenamedInItsFolderKeepsItsRowStatusAndPassagesAndGetsTheNewNameWords() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let root = tree.path("pics")
                let oldPath = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let other = try tree.photo("pics/harbortrip/kelmipax.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)
                let oldName = try #require(mvNameID(home, before, oldPath), "setup: no name passage for zorbalon.jpg")
                #expect(mvHits(reader, "zorbalon") == [oldName], "setup: the old name word should find the file before the rename")

                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/harbortrip/quixmerel.jpg")
                let newPath = tree.path("pics/harbortrip/quixmerel.jpg")
                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0,
                        "a rename adds and removes nothing; added \(outcome.added), removed \(outcome.removed)")
                mvExpectKept(home, before: before, passagesBefore: passagesBefore, from: oldPath, to: newPath, "rename")
                let rows = mvRows(home)
                #expect(Set(rows.keys) == [newPath, other], "rows are \(rows.keys.sorted())")
                #expect(rows[other] == before[other], "the untouched file's row changed")
                #expect(mvHits(reader, "quixmerel") == [mvNameID(home, rows, newPath) ?? -1],
                        "the new file name must find the renamed file's name passage")
                #expect(mvHits(reader, "zorbalon").isEmpty, "the old file name still finds \(mvHits(reader, "zorbalon"))")
                #expect(mvHits(reader, "kelmipax") == [mvNameID(home, rows, other) ?? -1], "the untouched file's words changed")
                #expect(mvCount(home, "select count(*) from passages") == 4, "passages: \(mvCount(home, "select count(*) from passages")), expected the 4 there were")
                #expect(reader.meta("walk_done_at") == "t1", "walk_done_at is not written by the same reconcile")
            }
        }
    }

    @Test func aRenamedFolderKeepsEveryRowInItAndTheFolderWordsAreRewritten() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let root = tree.path("pics")
                let names = ["zorbalon", "quixmerel", "vandorix"]
                for name in names { try tree.photo("pics/harbortrip/\(name).jpg") }
                try tree.photo("pics/elsewhere/kelmipax.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)
                #expect(mvHits(reader, "harbortrip").count == 3, "setup: the old folder word should find its 3 files")

                try tree.move("pics/harbortrip", "pics/lakeweekend")
                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0,
                        "a folder rename adds and removes nothing; added \(outcome.added), removed \(outcome.removed)")
                for name in names {
                    mvExpectKept(home, before: before, passagesBefore: passagesBefore,
                                 from: tree.path("pics/harbortrip/\(name).jpg"), to: tree.path("pics/lakeweekend/\(name).jpg"), "folder rename of \(name)")
                }
                let rows = mvRows(home)
                let expectedNew = Set(names.compactMap { mvNameID(home, rows, tree.path("pics/lakeweekend/\($0).jpg")) })
                #expect(expectedNew.count == 3, "setup: the three renamed rows should each hold a name passage")
                #expect(mvHits(reader, "lakeweekend") == expectedNew, "the new folder word finds \(mvHits(reader, "lakeweekend")), expected \(expectedNew)")
                #expect(mvHits(reader, "harbortrip").isEmpty, "the old folder word still finds \(mvHits(reader, "harbortrip"))")
                for name in names {
                    #expect(mvHits(reader, name).count == 1, "the file word \(name) should still find exactly its file")
                }
                #expect(rows[tree.path("pics/elsewhere/kelmipax.jpg")] == before[tree.path("pics/elsewhere/kelmipax.jpg")],
                        "a file outside the renamed folder changed")
            }
        }
    }

    @Test func aFileMovedToAnotherFolderOrAnotherPickedFolderKeepsItsRowAndGetsTheNewWords() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let rootA = tree.path("pics"), rootB = tree.path("archive")
                let inside = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let across = try tree.photo("pics/harbortrip/quixmerel.jpg")
                try tree.photo("pics/harbortrip/kelmipax.jpg")
                try tree.photo("archive/oldstuff/vandorix.jpg")
                try mvSeed(store, mvWalk([rootA, rootB]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)

                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/lakeweekend/zorbalon.jpg")
                try tree.move("pics/harbortrip/quixmerel.jpg", "archive/summerroll/quixmerel.jpg")
                let outcome = try mvReconcile(store, mvWalk([rootA, rootB]), stamp: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0,
                        "moves add and remove nothing; added \(outcome.added), removed \(outcome.removed)")
                mvExpectKept(home, before: before, passagesBefore: passagesBefore, from: inside,
                             to: tree.path("pics/lakeweekend/zorbalon.jpg"), "move inside a root")
                mvExpectKept(home, before: before, passagesBefore: passagesBefore, from: across,
                             to: tree.path("archive/summerroll/quixmerel.jpg"), "move to another root")
                let rows = mvRows(home)
                #expect(mvHits(reader, "lakeweekend") == [mvNameID(home, rows, tree.path("pics/lakeweekend/zorbalon.jpg")) ?? -1],
                        "the new folder word should find the moved file")
                #expect(mvHits(reader, "summerroll") == [mvNameID(home, rows, tree.path("archive/summerroll/quixmerel.jpg")) ?? -1],
                        "the new folder word should find the file moved to the other root")
                #expect(mvHits(reader, "harbortrip").count == 1, "the old folder word should find only the one file left in it, found \(mvHits(reader, "harbortrip"))")
                #expect(mvHits(reader, "zorbalon").count == 1 && mvHits(reader, "quixmerel").count == 1, "a moved file must still be found by its own name")
            }
        }
    }

    @Test func aFileMovedAwayWhileAnotherFileTakesItsOldPathKeepsItsRowAndTheNewFileIsNew() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("pics")
                let path = try tree.photo("pics/harbortrip/zorbalon.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)

                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/lakeweekend/zorbalon.jpg")
                try tree.photo("pics/harbortrip/zorbalon.jpg")      // a different file (a new inode) at the old path
                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                #expect(outcome.added == 1 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed); expected the one new file only")
                let rows = mvRows(home)
                let moved = tree.path("pics/lakeweekend/zorbalon.jpg")
                let was = try #require(before[path])
                #expect(Set(rows.keys) == [path, moved], "rows are \(rows.keys.sorted())")
                #expect(rows[moved]?.id == was.id && rows[moved]?.status == "done" && rows[moved]?.inode == was.inode,
                        "the moved file must keep row \(was.id), done, got \(String(describing: rows[moved]))")
                #expect(mvPassages(home)[was.id] == passagesBefore[was.id] || (mvPassages(home)[was.id]?.filter { $0.source == "image" } == passagesBefore[was.id]?.filter { $0.source == "image" }),
                        "the moved file's image passage changed")
                let fresh = try #require(rows[path], "the new file at the old path has no row")
                #expect(fresh.id != was.id && fresh.status == "pending" && fresh.inode != was.inode,
                        "the new file at the old path must be its own pending row, got \(fresh)")
                #expect(mvPassages(home)[fresh.id] == nil, "the new file has passages before it was read")
            }
        }
    }

    // MARK: a moved file that also changed is a changed file

    @Test func aMovedFileWhoseSizeChangedIsAChangedFileAtTheNewPath() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("pics")
                let oldPath = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let other = try tree.photo("pics/harbortrip/kelmipax.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let keptTime = try #require(try FileManager.default.attributesOfItem(atPath: oldPath)[.modificationDate] as? Date)

                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/lakeweekend/zorbalon.jpg")
                let newPath = tree.path("pics/lakeweekend/zorbalon.jpg")
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: newPath))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 9, count: 37))
                try handle.close()
                try tree.setTime(newPath, keptTime.timeIntervalSince1970)
                let info = try #require(mvStat(newPath))
                #expect(info.size != before[oldPath]?.size && info.mtimeNs == before[oldPath]?.mtimeNs,
                        "setup: the size should differ and the modified time be the same")

                _ = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                let rows = mvRows(home)
                #expect(Set(rows.keys) == [newPath, other], "rows are \(rows.keys.sorted()); one row for the moved file, none at the old path")
                #expect(rows[newPath]?.status == "pending", "a moved file whose size changed is a changed file: status \(rows[newPath]?.status ?? "no row"), expected pending")
                #expect(rows[newPath]?.size == info.size && rows[newPath]?.mtimeNs == info.mtimeNs,
                        "the row must hold the file's new size and time, has \(String(describing: rows[newPath]))")
                #expect(rows[other] == before[other], "the untouched file's row changed")
            }
        }
    }

    @Test func aMovedFileWhoseModifiedTimeChangedIsAChangedFileAtTheNewPath() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("pics")
                let oldPath = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let other = try tree.photo("pics/harbortrip/kelmipax.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)

                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/lakeweekend/zorbalon.jpg")
                let newPath = tree.path("pics/lakeweekend/zorbalon.jpg")
                try tree.setTime(newPath, atPast - 9000)
                let info = try #require(mvStat(newPath))
                #expect(info.size == before[oldPath]?.size && info.mtimeNs != before[oldPath]?.mtimeNs,
                        "setup: the size should be the same and the modified time differ")

                _ = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                let rows = mvRows(home)
                #expect(Set(rows.keys) == [newPath, other], "rows are \(rows.keys.sorted()); one row for the moved file, none at the old path")
                #expect(rows[newPath]?.status == "pending", "a moved file whose time changed is a changed file: status \(rows[newPath]?.status ?? "no row"), expected pending")
                #expect(rows[newPath]?.mtimeNs == info.mtimeNs, "the row must hold the file's new time, has \(String(describing: rows[newPath]))")
                #expect(rows[other] == before[other], "the untouched file's row changed")
            }
        }
    }

    // MARK: a copy is a new file

    @Test func aCopyWithANewInodeIsANewFileAndTheOriginalKeepsItsRowAndPassages() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("pics")
                let original = try tree.photo("pics/harbortrip/zorbalon.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)

                let copy = tree.path("pics/harbortrip/zorbalon-copy.jpg")
                try FileManager.default.copyItem(atPath: original, toPath: copy)
                let kept = try #require(try FileManager.default.attributesOfItem(atPath: original)[.modificationDate] as? Date)
                try tree.setTime(copy, kept.timeIntervalSince1970)          // the same size and the same time, only the inode differs
                let a = try #require(mvStat(original)), b = try #require(mvStat(copy))
                #expect(a.size == b.size && a.mtimeNs == b.mtimeNs && a.inode != b.inode, "setup: the copy should differ from the original in its inode only")

                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                let rows = mvRows(home)
                #expect(outcome.added == 1 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed); expected the copy added and nothing removed")
                #expect(rows[original] == before[original], "the original's row changed: \(String(describing: rows[original]))")
                #expect(mvPassages(home)[before[original]?.id ?? -1] == passagesBefore[before[original]?.id ?? -2], "the original's passages changed")
                let row = try #require(rows[copy], "the copy has no row")
                #expect(row.id != before[original]?.id && row.inode == b.inode, "the copy must be its own row with its own inode, got \(row)")
                #expect(row.status == "pending", "the copy is a new file to read: status \(row.status), expected pending")
                #expect(mvPassages(home)[row.id] == nil, "the copy has passages before it was read: \(String(describing: mvPassages(home)[row.id]))")
            }
        }
    }

    @Test func aCopyThatReplacesItsOriginalIsANewFileAndTheOriginalAndItsPassagesGo() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let root = tree.path("pics")
                let original = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let other = try tree.photo("pics/harbortrip/kelmipax.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let oldID = try #require(before[original]?.id)

                let copy = tree.path("pics/lakeweekend/zorbalon.jpg")
                try FileManager.default.createDirectory(atPath: tree.path("pics/lakeweekend"), withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: original, toPath: copy)
                let kept = try #require(try FileManager.default.attributesOfItem(atPath: original)[.modificationDate] as? Date)
                try tree.setTime(copy, kept.timeIntervalSince1970)
                try FileManager.default.removeItem(atPath: original)
                let info = try #require(mvStat(copy))
                #expect(info.inode != before[original]?.inode, "setup: the copy has the original's inode")

                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                let rows = mvRows(home)
                #expect(outcome.added == 1 && outcome.removed == 1, "added \(outcome.added), removed \(outcome.removed); a copy that replaces its original is one new file and one removed row")
                #expect(Set(rows.keys) == [copy, other], "rows are \(rows.keys.sorted())")
                let row = try #require(rows[copy])
                #expect(row.id != oldID && row.status == "pending", "the copy must be a new pending row, got \(row), the original was row \(oldID)")
                #expect(mvPassages(home)[oldID] == nil && mvPassages(home)[row.id] == nil, "no passage may remain for the original or the copy before it is read")
                #expect(mvHits(reader, "zorbalon").isEmpty, "the removed original is still found by its name")
                #expect(mvCount(home, "select count(*) from passages") == 2, "only the untouched file's 2 passages should remain")
            }
        }
    }

    // MARK: swaps and chains

    @Test func twoFilesThatSwapNamesAreBothHandledAndEachKeepsItsOwnRow() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let root = tree.path("pics")
                let pathA = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let pathB = try tree.photo("pics/harbortrip/quixmerel.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)
                let idA = try #require(before[pathA]?.id), idB = try #require(before[pathB]?.id)

                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/harbortrip/swap.tmp")
                try tree.move("pics/harbortrip/quixmerel.jpg", "pics/harbortrip/zorbalon.jpg")
                try tree.move("pics/harbortrip/swap.tmp", "pics/harbortrip/quixmerel.jpg")
                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0, "a swap adds and removes nothing; added \(outcome.added), removed \(outcome.removed)")
                let rows = mvRows(home)
                #expect(Set(rows.keys) == [pathA, pathB], "rows are \(rows.keys.sorted())")
                #expect(rows[pathA]?.id == idB && rows[pathB]?.id == idA,
                        "each file keeps its row: the file now named zorbalon is row \(idB), now quixmerel is row \(idA); got \(String(describing: rows[pathA]?.id)) and \(String(describing: rows[pathB]?.id))")
                #expect(rows[pathA]?.status == "done" && rows[pathB]?.status == "done", "both rows should stay done")
                #expect(mvPassages(home)[idA]?.filter { $0.source == "image" } == passagesBefore[idA]?.filter { $0.source == "image" }
                        && mvPassages(home)[idB]?.filter { $0.source == "image" } == passagesBefore[idB]?.filter { $0.source == "image" },
                        "an image passage changed, so a file was read again")
                #expect(mvHits(reader, "zorbalon") == [mvNameID(home, rows, pathA) ?? -1], "the name zorbalon must find the file that carries it now")
                #expect(mvHits(reader, "quixmerel") == [mvNameID(home, rows, pathB) ?? -1], "the name quixmerel must find the file that carries it now")
            }
        }
    }

    @Test func aChainOfRenamesWhereOneFileTakesTheOldNameOfAnotherIsHandled() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let root = tree.path("pics")
                let pathX = try tree.photo("pics/harbortrip/zorbalon.jpg")
                let pathY = try tree.photo("pics/harbortrip/quixmerel.jpg")
                try mvSeed(store, mvWalk([root]).found)
                let before = mvRows(home)
                let idX = try #require(before[pathX]?.id), idY = try #require(before[pathY]?.id)

                try tree.move("pics/harbortrip/quixmerel.jpg", "pics/harbortrip/vandorix.jpg")      // Y gets a new name
                try tree.move("pics/harbortrip/zorbalon.jpg", "pics/harbortrip/quixmerel.jpg")      // X takes Y's old name
                let outcome = try mvReconcile(store, mvWalk([root]), stamp: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed)")
                let rows = mvRows(home)
                let newY = tree.path("pics/harbortrip/vandorix.jpg")
                #expect(Set(rows.keys) == [pathY, newY], "rows are \(rows.keys.sorted())")
                #expect(rows[pathY]?.id == idX, "X moved to Y's old path and must keep row \(idX), got \(String(describing: rows[pathY]?.id))")
                #expect(rows[newY]?.id == idY, "Y was renamed and must keep row \(idY), got \(String(describing: rows[newY]?.id))")
                #expect(rows[pathY]?.status == "done" && rows[newY]?.status == "done", "both rows should stay done")
                #expect(mvHits(reader, "quixmerel") == [mvNameID(home, rows, pathY) ?? -1], "quixmerel must find the file that carries it now (row \(idX))")
                #expect(mvHits(reader, "vandorix") == [mvNameID(home, rows, newY) ?? -1], "vandorix must find the renamed file")
                #expect(mvHits(reader, "zorbalon").isEmpty, "zorbalon belongs to no file now but finds \(mvHits(reader, "zorbalon"))")
            }
        }
    }

    // MARK: a missing root, an unreadable root, an overlapping folder

    @Test func aRootThatIsGoneRemovesEveryRowUnderItAndOnlyThose() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let drive = tree.path("drive"), home2 = tree.path("pics")
                try tree.photo("drive/trip/zorbalon.jpg")
                try tree.photo("drive/trip/deep/quixmerel.jpg")
                try tree.photo("drive/vandorix.jpg")
                try tree.photo("pics/harbortrip/kelmipax.jpg")
                try mvSeed(store, mvWalk([drive, home2]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)
                let survivor = tree.path("pics/harbortrip/kelmipax.jpg")

                try FileManager.default.removeItem(atPath: drive)      // the unplugged drive: the root is no longer there
                let walk = mvWalk([drive, home2])
                #expect(walk.unreadable.isEmpty, "setup: a missing root must not be reported unreadable, got \(walk.unreadable)")
                let outcome = try mvReconcile(store, walk, stamp: "t1")

                #expect(outcome.removed == 3 && outcome.added == 0, "removed \(outcome.removed), added \(outcome.added); expected the 3 rows under the missing root")
                let rows = mvRows(home)
                #expect(Set(rows.keys) == [survivor], "rows are \(rows.keys.sorted())")
                #expect(rows[survivor] == before[survivor], "the row of the other root changed")
                #expect(mvPassages(home) == [before[survivor]!.id: passagesBefore[before[survivor]!.id]!], "passages of the removed rows must go with them, passages are \(mvPassages(home))")
                for word in ["zorbalon", "quixmerel", "vandorix"] {
                    #expect(mvHits(reader, word).isEmpty, "\(word) still finds a file of the missing root")
                }
                #expect(mvHits(reader, "kelmipax").count == 1, "the other root's file is no longer found")
                #expect(reader.meta("walk_done_at") == "t1", "walk_done_at is not written by the same reconcile")
            }
        }
    }

    @Test func aRootThatExistsButCannotBeListedKeepsItsRowsAndPassages() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                guard mvCanTestPermissions() else { return }
                let store = try IndexStore()
                defer { store.close() }
                let locked = tree.path("drive"), readable = tree.path("pics")
                try tree.photo("drive/trip/zorbalon.jpg")
                try tree.photo("drive/vandorix.jpg")
                try tree.photo("pics/harbortrip/kelmipax.jpg")
                try mvSeed(store, mvWalk([locked, readable]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)

                tree.lock("drive")                                    // it exists, it cannot be listed
                let walk = mvWalk([locked, readable])
                #expect(walk.unreadable == [locked], "setup: the locked root should be reported unreadable, got \(walk.unreadable)")
                let outcome = try mvReconcile(store, walk, stamp: "t1")

                #expect(outcome.removed == 0 && outcome.added == 0, "removed \(outcome.removed), added \(outcome.added); an unreadable root keeps its rows")
                #expect(mvRows(home) == before, "rows changed: \(mvRows(home).keys.sorted())")
                #expect(mvPassages(home) == passagesBefore, "passages changed")
            }
        }
    }

    @Test func aFileStillReachableThroughAnInnerTickedFolderStaysWhenTheOuterFolderIsRemoved() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let reader = IndexReader()
                defer { reader.close() }
                let outer = tree.path("pics"), inner = tree.path("pics/inner")
                let onlyOuter = try tree.photo("pics/zorbalon.jpg")
                let viaBoth = try tree.photo("pics/inner/quixmerel.jpg")
                let deep = try tree.photo("pics/inner/deeper/vandorix.jpg")
                try mvSeed(store, mvWalk([outer]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)

                // Both folders ticked: the walk meets two files twice. One row per path, nothing changes.
                let both = try mvReconcile(store, mvWalk([outer, inner]), stamp: "t1")
                #expect(both.added == 0 && both.removed == 0, "an overlapping pair of folders: added \(both.added), removed \(both.removed)")
                #expect(mvRows(home) == before, "overlapping folders changed the rows: \(mvRows(home).keys.sorted())")

                // The outer folder is removed from the list: only the inner one is walked now.
                let after = try mvReconcile(store, mvWalk([inner]), stamp: "t2")
                #expect(after.removed == 1 && after.added == 0, "removed \(after.removed), added \(after.added); only the file outside the inner folder goes")
                let rows = mvRows(home)
                #expect(Set(rows.keys) == [viaBoth, deep], "rows are \(rows.keys.sorted())")
                #expect(rows[viaBoth] == before[viaBoth] && rows[deep] == before[deep], "a file still reachable lost or changed its row")
                for path in [viaBoth, deep] {
                    let id = before[path]!.id
                    #expect(mvPassages(home)[id] == passagesBefore[id], "\(path): its passages changed")
                }
                #expect(mvPassages(home)[before[onlyOuter]!.id] == nil, "the removed file's passages remain")
                #expect(mvHits(reader, "zorbalon").isEmpty, "the removed file is still found")
                #expect(mvHits(reader, "quixmerel").count == 1 && mvHits(reader, "vandorix").count == 1, "a file still reachable is no longer found")
            }
        }
    }

    @Test func nothingIsRemovedWhenTheInnerFolderOfAnOverlappingPairIsRemoved() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let outer = tree.path("pics"), inner = tree.path("pics/inner")
                try tree.photo("pics/zorbalon.jpg")
                try tree.photo("pics/inner/quixmerel.jpg")
                try tree.photo("pics/inner/deeper/vandorix.jpg")
                try mvSeed(store, mvWalk([outer]).found)
                let before = mvRows(home)
                let passagesBefore = mvPassages(home)

                _ = try mvReconcile(store, mvWalk([outer, inner]), stamp: "t1")
                let after = try mvReconcile(store, mvWalk([outer]), stamp: "t2")

                #expect(after.removed == 0 && after.added == 0, "removed \(after.removed), added \(after.added); every file is still reachable through the outer folder")
                #expect(mvRows(home) == before, "rows changed")
                #expect(mvPassages(home) == passagesBefore, "passages changed")
            }
        }
    }

    // MARK: one transaction

    // A second connection polls while the store reconciles. A reconcile that renamed rows one by one would show it a
    // state with some rows on the old path and old words and some on the new ones; one transaction shows it all old or all new.
    @Test func aRenamedFolderOfManyFilesIsMovedInOneTransaction() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let total = 800
                let root = tree.path("pics")
                for number in 0..<total { try tree.photo("pics/oldharbor/bulk\(number).jpg") }
                try mvSeed(store, mvWalk([root]).found)
                try tree.move("pics/oldharbor", "pics/newharbor")
                let walk = mvWalk([root])
                #expect(walk.found.count == total, "setup: the walk found \(walk.found.count) of \(total)")

                let poller = AtPoller()
                poller.start(path: mvIndexPath(home), sql: """
                    select (select count(*) from files), (select count(*) from files where path like '%/oldharbor/%'), \
                    (select count(*) from files where path like '%/newharbor/%'), \
                    (select count(*) from fts where fts match 'name:oldharbor'), (select count(*) from fts where fts match 'name:newharbor')
                    """) { rows in
                    guard let row = rows.first, row.count == 5, let all = Int(row[0] ?? ""), let oldPaths = Int(row[1] ?? ""),
                          let newPaths = Int(row[2] ?? ""), let oldWords = Int(row[3] ?? ""), let newWords = Int(row[4] ?? "") else { return "unreadable" }
                    let allOld = oldPaths == all && oldWords == all && newPaths == 0 && newWords == 0
                    let allNew = newPaths == all && newWords == all && oldPaths == 0 && oldWords == 0
                    return (allOld || allNew) ? nil : "a snapshot of \(all) rows with \(oldPaths) on the old path, \(newPaths) on the new, \(oldWords) old words, \(newWords) new words"
                }
                Thread.sleep(forTimeInterval: 0.05)
                let outcome = try mvReconcile(store, walk, stamp: "t1")
                Thread.sleep(forTimeInterval: 0.15)
                let seen = poller.stop()

                #expect(seen.problems.isEmpty, "the move was not one transaction: \(seen.problems)")
                #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
                #expect(outcome.added == 0 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed)")
                let rows = mvRows(home)
                #expect(rows.count == total && rows.values.allSatisfy { $0.path.contains("/newharbor/") && $0.status == "done" },
                        "after the reconcile \(rows.count) rows, not all done under the new folder")
                #expect(mvCount(home, "select count(*) from passages") == 2 * total, "passages: \(mvCount(home, "select count(*) from passages")), expected \(2 * total)")
            }
        }
    }

    @Test func aMissingRootWithManyFilesIsRemovedWithItsPassagesInOneTransaction() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let each = 500
                let drive = tree.path("drive"), keep = tree.path("pics")
                for number in 0..<each {
                    try tree.photo("drive/trip/gone\(number).jpg")
                    try tree.photo("pics/harbortrip/stay\(number).jpg")
                }
                try mvSeed(store, mvWalk([drive, keep]).found)
                try FileManager.default.removeItem(atPath: drive)
                let walk = mvWalk([drive, keep])

                let poller = AtPoller()
                poller.start(path: mvIndexPath(home), sql: "select (select count(*) from files), (select count(*) from passages), (select count(*) from fts)") { rows in
                    guard let row = rows.first, row.count == 3, let files = Int(row[0] ?? ""), let passages = Int(row[1] ?? ""), let fts = Int(row[2] ?? "") else { return "unreadable" }
                    let before = files == 2 * each && passages == 4 * each && fts == 4 * each
                    let after = files == each && passages == 2 * each && fts == 2 * each
                    return (before || after) ? nil : "a snapshot with \(files) files, \(passages) passages, \(fts) fts rows"
                }
                Thread.sleep(forTimeInterval: 0.05)
                let outcome = try mvReconcile(store, walk, stamp: "t1")
                Thread.sleep(forTimeInterval: 0.15)
                let seen = poller.stop()

                #expect(seen.problems.isEmpty, "the removal of the missing root was not one transaction: \(seen.problems)")
                #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
                #expect(outcome.removed == each && outcome.added == 0, "removed \(outcome.removed), added \(outcome.added); expected \(each) removed")
                #expect(mvRows(home).count == each, "rows left: \(mvRows(home).count), expected \(each)")
            }
        }
    }

    @Test func removingAnOuterFolderOfAnOverlappingPairIsOneTransactionAndKeepsTheInnerFiles() throws {
        try mvWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let each = 500
                let outer = tree.path("pics"), inner = tree.path("pics/inner")
                for number in 0..<each {
                    try tree.photo("pics/outeronly/top\(number).jpg")
                    try tree.photo("pics/inner/low\(number).jpg")
                }
                try mvSeed(store, mvWalk([outer]).found)
                let before = mvRows(home)
                let walk = mvWalk([inner])
                #expect(walk.found.count == each, "setup: the inner walk found \(walk.found.count) of \(each)")

                let poller = AtPoller()
                poller.start(path: mvIndexPath(home), sql: "select (select count(*) from files), (select count(*) from passages), (select count(*) from fts)") { rows in
                    guard let row = rows.first, row.count == 3, let files = Int(row[0] ?? ""), let passages = Int(row[1] ?? ""), let fts = Int(row[2] ?? "") else { return "unreadable" }
                    let was = files == 2 * each && passages == 4 * each && fts == 4 * each
                    let now = files == each && passages == 2 * each && fts == 2 * each
                    return (was || now) ? nil : "a snapshot with \(files) files, \(passages) passages, \(fts) fts rows"
                }
                Thread.sleep(forTimeInterval: 0.05)
                let outcome = try mvReconcile(store, walk, stamp: "t1")
                Thread.sleep(forTimeInterval: 0.15)
                let seen = poller.stop()

                #expect(seen.problems.isEmpty, "the removal was not one transaction: \(seen.problems)")
                #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
                #expect(outcome.removed == each && outcome.added == 0, "removed \(outcome.removed), added \(outcome.added); expected the \(each) files outside the inner folder")
                let rows = mvRows(home)
                #expect(rows.count == each && rows.allSatisfy { $0.key.contains("/inner/") && before[$0.key] == $0.value },
                        "the files reachable through the inner folder must keep their rows unchanged; \(rows.count) rows left")
            }
        }
    }
}

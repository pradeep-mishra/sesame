import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-1 review round A, tester step: F1 at `IndexStore.reconcile`: rows of files under an unreadable path are KEPT;
// rows of files that vanished from readable folders are still deleted; an unreadable root keeps all its rows; a root
// that does not exist (the unplugged drive of design section 14, Q4) loses them.
// Written from the review report (F1), the brief and design sections 3 and 14 only. Product source read for names:
// Sources/SesameEngine/IndexStore.swift (`addFile`, `addPassage`, `reconcile`, `ReconcileOutcome`) and Walker.swift.
//
// THE SHAPE THESE TESTS PIN (new parameter; today the label does not exist, so this file does not compile until it does):
//
//     reconcile(_ found: [(file: WalkedFile, device: Int64)], unreadable: [String],
//               vectorSource: String, walkDoneAt: String) throws -> ReconcileOutcome
//
// (`unreadable:` may default to `[]` so the old call keeps compiling; the tests always pass it.)
// Meaning: a `files` row whose path is one of `unreadable`, or lies below one of them (path + "/" prefix, so a
// sibling like `/r/lockedother/z.jpg` or a file `/r/locked.jpg` is NOT below `/r/locked`), is neither deleted, updated
// nor re-added, and keeps its passages. Every other row not in `found` goes with its passages, as before. The same
// transaction still sets `meta.walk_done_at`. `ReconcileOutcome.removed` counts the deleted rows only.
//
// `WalkedFile` cannot be built outside the module, so `found` comes from a real walk of a real temp tree
// (`Walker.walk`, existing and sealed); the rows of paths that need not exist on disk are added with `addFile`.

private final class RDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(db) }

    func strings(_ sql: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { out.append(String(cString: text)) }
        }
        return out
    }
}

private func filePaths(_ home: TempHome) -> Set<String> {
    let index = home.folder.appendingPathComponent("index.sqlite").path
    return Set(RDB(path: index)?.strings("select path from files") ?? [])
}

/// A real readable tree: `<root>/ok/a.jpg` and `<root>/ok/b.jpg` (bytes are never decoded by a walk).
private func makeRealTree() throws -> (root: String, found: [(file: WalkedFile, device: Int64)]) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-reconcile-unreadable-" + UUID().uuidString, isDirectory: true)
    let root = url.resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(atPath: root + "/ok", withIntermediateDirectories: true)
    for name in ["a.jpg", "b.jpg"] {
        try Data(repeating: 3, count: 80).write(to: URL(fileURLWithPath: root + "/ok/" + name))
    }
    let walked = try Walker.walk(root: root, mode: .read)
    return (root, walked.map { (file: $0, device: Int64(1)) })
}

/// A `done` row with one passage (a `name` passage, words only), so a kept row is seen to keep its passage.
@discardableResult
private func addRow(_ store: IndexStore, path: String, inode: Int64) throws -> Int64 {
    let file = try store.addFile(path: path, kind: "photo", size: 10, mtimeNs: 1_700_000_000_000_000_000,
                                 inode: inode, device: 1, status: "done")
    return try store.addPassage(fileID: file, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                name: "n\(inode)", body: "")
}

@Suite("ReconcileUnreadableTests")
struct ReconcileUnreadableTests {

    @Test func rowsUnderAnUnreadableFolderAreKeptAndRowsThatVanishedFromReadableFoldersAreDeleted() throws {
        let tree = try makeRealTree()
        defer { try? FileManager.default.removeItem(atPath: tree.root) }
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let root = tree.root
            let kept = [root + "/locked/x.jpg", root + "/locked/deep/y.jpg"]
            let deleted = [root + "/ok/gone.jpg", root + "/lockedother/z.jpg", root + "/locked.jpg"]
            var inode: Int64 = 10
            for path in kept + deleted {
                inode += 1
                try addRow(store, path: path, inode: inode)
            }

            let outcome = try store.reconcile(tree.found, unreadable: [root + "/locked"], vectorSource: "v", walkDoneAt: "t1")

            #expect(filePaths(home) == Set(kept + [root + "/ok/a.jpg", root + "/ok/b.jpg"]),
                    "rows should be the 2 new files plus the 2 under the unreadable folder, got \(filePaths(home).sorted())")
            #expect(outcome.added == 2, "added \(outcome.added), expected the 2 walked photos")
            #expect(outcome.removed == 3, "removed \(outcome.removed), expected exactly the 3 rows outside the unreadable folder: gone.jpg, lockedother/z.jpg, locked.jpg")
            let reader = IndexReader()
            defer { reader.close() }
            #expect(reader.meta("walk_done_at") == "t1", "walk_done_at not written")
            // The kept rows keep their passages; the deleted rows' passages are gone (2 kept passages remain).
            #expect(reader.passageCount() == 2, "passages: \(reader.passageCount()), expected the 2 of the kept rows")
        }
    }

    @Test func anUnreadableRootKeepsEveryRowUnderItAndOnlyThatRoot() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let under = ["/vol/pics/a.jpg", "/vol/pics/sub/b.jpg"]
            let outside = ["/other/c.jpg", "/vol/pics2/d.jpg"]
            var inode: Int64 = 20
            for path in under + outside { inode += 1; try addRow(store, path: path, inode: inode) }

            let outcome = try store.reconcile([], unreadable: ["/vol/pics"], vectorSource: "v", walkDoneAt: "t2")

            #expect(filePaths(home) == Set(under), "an unreadable root keeps its rows only; got \(filePaths(home).sorted())")
            #expect(outcome.removed == 2, "removed \(outcome.removed), expected the 2 rows outside the root")
            #expect(IndexReader().passageCount() == 2)
        }
    }

    // A guard of design section 14, Q4: nothing unreadable, nothing found (the drive is unplugged): every row goes.
    @Test func aRootThatIsGoneLosesAllItsRows() throws {
        try withTempHome { home in
            guard try createFolder(home) else { return }
            let store = try IndexStore()
            defer { store.close() }
            var inode: Int64 = 30
            for path in ["/Volumes/Drive/a.jpg", "/Volumes/Drive/sub/b.jpg"] { inode += 1; try addRow(store, path: path, inode: inode) }

            let outcome = try store.reconcile([], unreadable: [], vectorSource: "v", walkDoneAt: "t3")

            #expect(filePaths(home).isEmpty, "got \(filePaths(home).sorted())")
            #expect(outcome.removed == 2)
            #expect(IndexReader().passageCount() == 0, "the passages of deleted rows must go too")
        }
    }
}

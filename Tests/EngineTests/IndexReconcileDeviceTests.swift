import Foundation
import Testing
import SesameEngine

// plan-2 fix round A, tester step: item A10 (S7.8, S6.12). Written from the fix-round entry A10, the reviewer's finding
// ("a remounted drive can be re-embedded in full") and the sealed IndexReconcileMovesTests.swift (same harness idea, own
// copies below). No product source read.
//
// What the entry fixes (expected values written by hand): "the same file" at the SAME PATH is (inode, size, mtime, kind);
// the device number is not required to match. So a walk in which every path, inode, size and modified time is as
// stored but the `st_dev` differs (a drive remounted as another device node, a reboot) leaves each row as it was: same
// `files.id`, same `status` (done), the passages untouched (nothing read again), and `outcome.added` and `removed` are 0.
// A move to a NEW path keeps the rule it has today: the device must match, or the move is not made (no new false merges
// across two volumes, where two different files can share an inode number).
//
// `WalkedFile` cannot be built outside the module, so every walk is a real `Walker.scan` of a real temp tree; the device
// number is the hand-set half of each `(file:, device:)` pair, which is how the helper's reconcile gets it. Rows are
// written with `addFile` and `addPassage`.
// Red today: the first test (a changed device is a changed file, the row goes `pending` and its passages are deleted)
// and the second (the file at the same path is replaced by a new row). The others are guards.

private let rdOld: Int64 = 1
private let rdNew: Int64 = 2

private final class RdTree {
    let base: String
    private var made = 0

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-device-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { base + "/" + relative }

    @discardableResult
    func photo(_ relative: String) throws -> String {
        made += 1
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: UInt8(truncatingIfNeeded: made), count: 100 + made).write(to: URL(fileURLWithPath: full))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(made))], ofItemAtPath: full)
        return full
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

private func rdWithTree(_ body: (RdTree) throws -> Void) throws {
    let tree = try RdTree()
    defer { tree.remove() }
    try body(tree)
}

private typealias RdFound = [(file: WalkedFile, device: Int64)]

private func rdWalk(_ root: String, device: Int64) -> (found: RdFound, unreadable: [String]) {
    let scanned = Walker.scan(root: root, mode: .read)
    return (scanned.files.map { (file: $0, device: device) }, scanned.unreadable)
}

private func rdVector(_ phase: Double) -> [Float] {
    (0..<768).map { Float(sin(Double($0) * 0.37 + phase) * 0.9) }
}

private func rdSeed(_ store: IndexStore, _ found: RdFound, device: Int64) throws {
    var phase = 0.0
    for entry in found {
        phase += 0.7
        let id = try store.addFile(path: entry.file.path, kind: entry.file.kind, size: entry.file.size,
                                   mtimeNs: entry.file.mtimeNs, inode: Int64(entry.file.inode), device: device, status: "done")
        _ = try store.addPassage(fileID: id, source: "name", start: 0, end: 0, modality: "none", vector: nil,
                                 name: "name\(Int(phase * 10))", body: "")
        _ = try store.addPassage(fileID: id, source: "image", start: 0, end: 0, modality: "image",
                                 vector: rdVector(phase), name: "", body: "")
    }
}

private struct RdRow: Equatable {
    let id: Int64
    let status: String
}

private func rdIndexPath(_ home: TempHome) -> String {
    home.folder.appendingPathComponent("index.sqlite").path
}

private func rdRows(_ home: TempHome) -> [String: RdRow] {
    guard let db = AtDB(path: rdIndexPath(home)), let rows = db.rows("select path, id, status from files") else { return [:] }
    var out: [String: RdRow] = [:]
    for row in rows {
        if let path = row[0], let id = Int64(row[1] ?? ""), let status = row[2] { out[path] = RdRow(id: id, status: status) }
    }
    return out
}

/// Every passage id by file id, ascending.
private func rdPassages(_ home: TempHome) -> [Int64: [Int64]] {
    guard let db = AtDB(path: rdIndexPath(home)), let rows = db.rows("select file_id, id from passages order by id") else { return [:] }
    var out: [Int64: [Int64]] = [:]
    for row in rows { if let file = Int64(row[0] ?? ""), let id = Int64(row[1] ?? "") { out[file, default: []].append(id) } }
    return out
}

@Suite("IndexReconcileDeviceTests")
struct IndexReconcileDeviceTests {

    @Test func aWalkWhereOnlyTheDeviceNumberChangedKeepsEveryRowItsStatusAndItsPassages() throws {
        try rdWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("drive")
                try tree.photo("drive/trip/a.jpg")
                try tree.photo("drive/trip/b.jpg")
                try tree.photo("drive/c.jpg")
                try rdSeed(store, rdWalk(root, device: rdOld).found, device: rdOld)
                let rowsBefore = rdRows(home)
                let passagesBefore = rdPassages(home)
                #expect(rowsBefore.count == 3 && rowsBefore.values.allSatisfy { $0.status == "done" }, "setup: \(rowsBefore)")
                #expect(passagesBefore.values.allSatisfy { $0.count == 2 }, "setup: passages \(passagesBefore)")

                // the drive is plugged in again as another device: every path, inode, size and modified time is as stored
                let outcome = try store.reconcile(rdWalk(root, device: rdNew).found, unreadable: [], vectorSource: "v", walkDoneAt: "t1")

                #expect(outcome.added == 0 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed); a remount adds and removes nothing")
                #expect(rdRows(home) == rowsBefore, "rows after a remount: \(rdRows(home)); before: \(rowsBefore) (a changed device must not reset a file to pending)")
                #expect(rdPassages(home) == passagesBefore, "passages after a remount: \(rdPassages(home)); before: \(passagesBefore) (nothing may be deleted or read again)")
            }
        }
    }

    @Test func aChangedDeviceTogetherWithAChangedSizeIsStillAChangedFile() throws {
        try rdWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("drive")
                let changed = try tree.photo("drive/a.jpg")
                try tree.photo("drive/b.jpg")
                try rdSeed(store, rdWalk(root, device: rdOld).found, device: rdOld)
                let before = rdRows(home)
                try Data(repeating: 7, count: 999).write(to: URL(fileURLWithPath: changed))     // new size, same inode

                _ = try store.reconcile(rdWalk(root, device: rdNew).found, unreadable: [], vectorSource: "v", walkDoneAt: "t1")

                let rows = rdRows(home)
                #expect(rows[changed]?.status == "pending", "a file whose size changed must be read again, row is \(String(describing: rows[changed]))")
                let other = tree.path("drive/b.jpg")
                #expect(rows[other] == before[other], "the file that did not change lost its row or status: \(String(describing: rows[other]))")
            }
        }
    }

    // MARK: moves keep their rule

    @Test func aFileMovedToANewPathOnTheSameDeviceStillKeepsItsRow() throws {
        try rdWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("drive")
                let oldPath = try tree.photo("drive/old/a.jpg")
                try tree.photo("drive/b.jpg")
                try rdSeed(store, rdWalk(root, device: rdOld).found, device: rdOld)
                let before = rdRows(home)
                let passagesBefore = rdPassages(home)
                try FileManager.default.createDirectory(atPath: tree.path("drive/new"), withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: oldPath, toPath: tree.path("drive/new/a.jpg"))

                let outcome = try store.reconcile(rdWalk(root, device: rdOld).found, unreadable: [], vectorSource: "v", walkDoneAt: "t1")

                let rows = rdRows(home)
                #expect(outcome.added == 0 && outcome.removed == 0, "added \(outcome.added), removed \(outcome.removed)")
                #expect(rows[tree.path("drive/new/a.jpg")]?.id == before[oldPath]?.id, "the moved file did not keep its row: \(rows)")
                #expect(rows[oldPath] == nil, "a row is left at the old path")
                #expect(rdPassages(home) == passagesBefore, "a move changed passages")
            }
        }
    }

    // A row at a path that is gone, whose inode, size and modified time equal those of a file at a new path, is moved ONLY
    // when the device matches. Here the new path is reported on another device: two volumes can share an inode number,
    // so the ghost's row is removed and the file is a new one, read from scratch.
    @Test func aFileAtANewPathOnAnotherDeviceWithTheSameInodeSizeAndTimeIsNotMergedWithAVanishedRow() throws {
        try rdWithTree { tree in
            try withTempHome { home in
                guard try createFolder(home) else { return }
                let store = try IndexStore()
                defer { store.close() }
                let root = tree.path("drive")
                let real = try tree.photo("drive/other/a.jpg")
                let walked = try #require(rdWalk(root, device: rdNew).found.first { $0.file.path == real }, "setup: the walk did not see \(real)")
                // a row of the OLD volume, at a path that no longer exists, with the very inode, size and time of the file just found
                let ghostPath = "/ghost-volume/a.jpg"
                let ghost = try store.addFile(path: ghostPath, kind: walked.file.kind, size: walked.file.size, mtimeNs: walked.file.mtimeNs,
                                              inode: Int64(walked.file.inode), device: rdOld, status: "done")
                _ = try store.addPassage(fileID: ghost, source: "name", start: 0, end: 0, modality: "none", vector: nil, name: "ghostname", body: "")
                _ = try store.addPassage(fileID: ghost, source: "image", start: 0, end: 0, modality: "image", vector: rdVector(0.3), name: "", body: "")
                let ghostPassages = rdPassages(home)[ghost] ?? []
                #expect(ghostPassages.count == 2, "setup: the ghost's passages are \(ghostPassages)")

                let outcome = try store.reconcile(rdWalk(root, device: rdNew).found, unreadable: [], vectorSource: "v", walkDoneAt: "t1")

                let rows = rdRows(home)
                #expect(rows[ghostPath] == nil, "the vanished row is still there: \(rows)")
                let now = try #require(rows[real], "the file at the new path has no row: \(rows)")
                #expect(now.id != ghost, "the file on another device took over the vanished row \(ghost): a false merge across two volumes")
                #expect(now.status == "pending", "a new file must be pending, got \(now.status)")
                #expect(outcome.added == 1 && outcome.removed == 1, "added \(outcome.added), removed \(outcome.removed); expected one new file and one removed row")
                let passages = rdPassages(home)
                #expect(Set(passages.values.flatMap { $0 }).isDisjoint(with: Set(ghostPassages)), "the ghost's passages were kept: \(passages)")
            }
        }
    }
}

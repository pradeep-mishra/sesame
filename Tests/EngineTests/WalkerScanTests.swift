import Foundation
import Testing
import SesameEngine

// plan-1 review round A, tester step: F1 (the walk survives an unreadable folder and reports it) and F7, the
// dataless part (an evicted iCloud file is skipped by the walk and never opened or read).
// Written from the review report, the brief, design sections 4 and 14 (Q4) and spec S8 (cloud-only files, the sparse
// stand-in) only. Product source read for names: Sources/SesameEngine/Walker.swift (`Walker.walk`, `WalkedFile`,
// `Walker.Mode`).
//
// THE SHAPE THESE TESTS PIN (new API; today it does not exist, so this file does not compile until it does):
//
//     public struct WalkResult {
//         public let files: [WalkedFile]      // every admitted file that could be listed, nothing else
//         public let unreadable: [String]     // the folders that exist but could not be listed
//     }
//     Walker.scan(root: String, mode: Walker.Mode,
//                 flags: (String) -> UInt32 = <lstat st_flags of the path>) -> WalkResult      // never throws
//     Walker.isDataless(flags: UInt32) -> Bool                                                 // pure
//
// - `unreadable` holds the path of each folder the walk could not list (EACCES and the like), as the walk spelled
//   it (`root` + "/" + names), once each, and nothing below it (a folder that cannot be listed has no known children).
//   An unreadable ROOT is `[root]`.
// - A root that does not exist (ENOENT, the unplugged drive of design section 14, Q4) is NOT unreadable: no files,
//   `unreadable` empty, no throw. That difference is what lets the index delete its rows (gone) or keep them
//   (could not look).
// - `Walker.walk` (throwing, `[WalkedFile]`) is left as it is: the sealed RulesTests call it.
// - `flags` is the injected `st_flags` source, called with the path of each non-directory entry; the walk skips a file
//   when `Walker.isDataless(flags:)` is true for it, in read mode (count mode is not pinned: the spec says the setup
//   estimate counts by names, sizes and types only). `Walker.isDataless(flags:)` is true when the macOS
//   SF_DATALESS bit 0x40000000 is set (from <sys/stat.h>, not from product code).
// - The sparse stand-in of spec S8 (a size above 0 with no blocks on disk) is skipped too, in read mode.
//
// Permissions: `chmod 000` on a folder; every lock is undone in a defer. Run as root the tests say so and stop.

private let sfDataless: UInt32 = 0x4000_0000

private final class Tree {
    let root: String
    private var locked: [(path: String, mode: mode_t)] = []

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-walkscan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().path
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func file(_ relative: String, bytes: Int = 64) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: full))
    }

    func lock(_ relative: String) {
        let full = relative.isEmpty ? root : path(relative)
        var info = stat()
        guard stat(full, &info) == 0 else { return }
        locked.append((full, info.st_mode & 0o7777))
        chmod(full, 0)
    }

    func remove() {
        for item in locked.reversed() { chmod(item.path, item.mode) }
        try? FileManager.default.removeItem(atPath: root)
    }
}

private func withTree(_ body: (Tree) throws -> Void) throws {
    let tree = try Tree()
    defer { tree.remove() }
    try body(tree)
}

private func canTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root lists through chmod 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

private func names(_ files: [WalkedFile], under root: String) -> Set<String> {
    Set(files.map { String($0.path.dropFirst(root.count + 1)) })
}

@Suite("WalkerScanTests")
struct WalkerScanTests {

    // F1: one unreadable subfolder costs only that subfolder.
    @Test func anUnreadableSubfolderDoesNotCostTheReadableFilesAndIsReported() throws {
        try withTree { tree in
            guard canTestPermissions() else { return }
            try tree.file("a.jpg")
            try tree.file("ok/b.png")
            try tree.file("ok/deeper/c.jpg")
            try tree.file("locked/d.jpg")
            try tree.file("locked/inner/e.jpg")
            tree.lock("locked")
            let result = Walker.scan(root: tree.root, mode: .read)
            #expect(names(result.files, under: tree.root) == ["a.jpg", "ok/b.png", "ok/deeper/c.jpg"],
                    "got \(names(result.files, under: tree.root).sorted())")
            #expect(result.unreadable == [tree.path("locked")], "unreadable should be exactly the locked folder, got \(result.unreadable)")
        }
    }

    // F1: two unreadable folders, one nested in a readable one, are both reported once.
    @Test func everyUnreadableFolderIsReportedOnce() throws {
        try withTree { tree in
            guard canTestPermissions() else { return }
            try tree.file("a.jpg")
            try tree.file("x/y/locked1/p.jpg")
            try tree.file("x/q.jpg")
            try tree.file("locked2/r.jpg")
            tree.lock("x/y/locked1")
            tree.lock("locked2")
            let result = Walker.scan(root: tree.root, mode: .read)
            #expect(names(result.files, under: tree.root) == ["a.jpg", "x/q.jpg"], "got \(names(result.files, under: tree.root).sorted())")
            #expect(Set(result.unreadable) == [tree.path("x/y/locked1"), tree.path("locked2")] && result.unreadable.count == 2,
                    "got \(result.unreadable)")
        }
    }

    // F1: count mode behaves the same.
    @Test func countModeAlsoSurvivesAnUnreadableSubfolder() throws {
        try withTree { tree in
            guard canTestPermissions() else { return }
            try tree.file("a.jpg")
            try tree.file("ok/notes.txt")
            try tree.file("locked/song.mp3")
            tree.lock("locked")
            let result = Walker.scan(root: tree.root, mode: .count)
            #expect(names(result.files, under: tree.root) == ["a.jpg", "ok/notes.txt"], "got \(names(result.files, under: tree.root).sorted())")
            #expect(result.unreadable == [tree.path("locked")], "got \(result.unreadable)")
        }
    }

    // F1: an unreadable root is reported as the root, with no files.
    @Test func anUnreadableRootIsReportedAsTheRootWithNoFiles() throws {
        try withTree { tree in
            guard canTestPermissions() else { return }
            try tree.file("a.jpg")
            tree.lock("")
            let result = Walker.scan(root: tree.root, mode: .read)
            #expect(result.files.isEmpty, "got \(result.files.map(\.path))")
            #expect(result.unreadable == [tree.root], "got \(result.unreadable)")
        }
    }

    // F1 / design section 14, Q4: a root that does not exist is gone, not unreadable.
    @Test func aRootThatDoesNotExistGivesNoFilesAndNothingUnreadable() throws {
        try withTree { tree in
            let result = Walker.scan(root: tree.path("not-here"), mode: .read)
            #expect(result.files.isEmpty)
            #expect(result.unreadable.isEmpty, "a missing root is not an unreadable one, got \(result.unreadable)")
        }
    }

    // The new call agrees with the old one on a tree with nothing unreadable.
    // plan-4-t6, amended by the fresh tester: this expected only the two pictures because `ok/skip.txt` had no reader. Documents
    // have a reader now, so the txt is returned by both calls. The rest is unchanged: the two calls agree and nothing is unreadable.
    // plan-5-t2, amended by the fresh tester: audio has a reader now, so the readable tree holds `ok/hum.wav` and both calls return it
    // (the tree of the entry: `plain/audio/hum.wav`). The rest is unchanged: the two calls agree and nothing is unreadable.
    // plan-5-t3, amended by the fresh tester: video has a reader now, so the readable tree also holds `plain/video/clip.mp4` and both calls
    // return it. The rest is unchanged: the two calls agree and nothing is unreadable.
    @Test func onAFullyReadableTreeScanGivesWhatWalkGivesAndNothingUnreadable() throws {
        try withTree { tree in
            try tree.file("a.jpg")
            try tree.file("ok/b.png")
            try tree.file("ok/skip.txt")
            try tree.file("plain/audio/hum.wav")
            try tree.file("plain/video/clip.mp4")
            try tree.file("plain/code/tool.py")
            try tree.file("plain/code/helper.swift")
            let scanned = Walker.scan(root: tree.root, mode: .read)
            let walked = try Walker.walk(root: tree.root, mode: .read)
            #expect(Set(scanned.files.map(\.path)) == Set(walked.map(\.path)))
            let others: Set<String> = [tree.path("a.jpg"), tree.path("ok/b.png"), tree.path("ok/skip.txt"), tree.path("plain/audio/hum.wav"), tree.path("plain/video/clip.mp4")]
            #expect(Set(scanned.files.map(\.path)) == others, "an unticked pick returns no code file, got \(scanned.files.map(\.path).sorted())")
            #expect(scanned.unreadable.isEmpty)
            let ticked = Walker.scan(root: tree.root, mode: .read, picks: [HelperFolder(path: tree.root, code: true)])
            #expect(Set(ticked.files.map(\.path)) == others, "a ticked pick returns no code file either, got \(ticked.files.map(\.path).sorted())")
            #expect(ticked.unreadable.isEmpty)
        }
    }

    // F7: the pure seam.
    @Test func isDatalessIsTrueForTheSFDatalessBitAndOnlyThen() {
        #expect(Walker.isDataless(flags: sfDataless))
        #expect(Walker.isDataless(flags: sfDataless | 0x20))
        #expect(Walker.isDataless(flags: UInt32.max))
        #expect(!Walker.isDataless(flags: 0))
        #expect(!Walker.isDataless(flags: 0x20))
        #expect(!Walker.isDataless(flags: 0x3FFF_FFFF))
        #expect(!Walker.isDataless(flags: 0x8000_0000))
    }

    // F7: the read-mode walk skips a file marked dataless through the injected flags source and lists the rest.
    // (Count mode is not pinned: the spec says the setup estimate counts by names, sizes and types only.)
    @Test func theReadWalkSkipsAFileTheFlagsSourceMarksDataless() throws {
        try withTree { tree in
            try tree.file("keep.jpg")
            try tree.file("ok/evicted.jpg")
            try tree.file("ok/also-keep.png")
            let flags: (String) -> UInt32 = { path in
                (path as NSString).lastPathComponent.hasPrefix("evicted") ? sfDataless : 0
            }
            let read = Walker.scan(root: tree.root, mode: .read, flags: flags)
            #expect(names(read.files, under: tree.root) == ["keep.jpg", "ok/also-keep.png"], "read mode: \(names(read.files, under: tree.root).sorted())")
            #expect(read.unreadable.isEmpty)
        }
    }

    // F7: nothing is skipped when the flags source says nothing is dataless (a real tree has no such flag).
    @Test func withNoDatalessFlagEveryAdmittedFileIsListed() throws {
        try withTree { tree in
            try tree.file("a.jpg")
            try tree.file("b/c.png")
            let result = Walker.scan(root: tree.root, mode: .read, flags: { _ in 0 })
            #expect(names(result.files, under: tree.root) == ["a.jpg", "b/c.png"])
        }
    }

    // F7, spec S8: the sparse stand-in for a cloud-only file (a size, no blocks on disk) is skipped in read mode.
    @Test func aSparseFileWithASizeAndNoBlocksIsSkippedAsCloudOnly() throws {
        try withTree { tree in
            try tree.file("real.jpg")
            let sparse = tree.path("cloud.jpg")
            let fd = open(sparse, O_CREAT | O_WRONLY, 0o600)
            try #require(fd >= 0, "could not create the sparse file")
            ftruncate(fd, 1_048_576)
            close(fd)
            var info = stat()
            try #require(stat(sparse, &info) == 0)
            guard info.st_size > 0 && info.st_blocks == 0 else {
                print("NOTE sparse stand-in not creatable on this volume (blocks \(info.st_blocks)); test not exercised")
                return
            }
            let result = Walker.scan(root: tree.root, mode: .read)
            #expect(names(result.files, under: tree.root) == ["real.jpg"],
                    "a file of size \(info.st_size) with 0 blocks is cloud-only and must be skipped, got \(names(result.files, under: tree.root).sorted())")
        }
    }
}

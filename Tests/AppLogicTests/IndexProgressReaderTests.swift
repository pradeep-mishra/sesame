import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1 review round B (app), tester step: finding F12 (the app side of F6/F12). `IndexProgress.counts()` opens a second
// read-only SQLite connection on the main thread at every panel open and every second, with a GROUP BY over `files`. The
// design allows the app one read connection, `IndexReader`; round A gave it `statusCounts()`.
// Written from the review report (F12), the brief's acceptance line and design sections 1 and 3 only, and from the sealed
// IndexReaderCountsTests (`KindStatusCount`, `statusCounts()`). Product source read for names and where the logic lives:
// Sources/Sesame/StateViews.swift (`IndexProgress.counts()`, `PanelSnapshot.read(reader:model:)`, which kind and status
// feed which field of `IndexCounts`), scripts/check-static.sh (the `sqlite-app-open` rule and `$SQLITE_APP_OPEN_IS_FAIL`).
// The expected counts come from the rows these tests write and from `IndexCounts`' own meaning (files done, files pending
// per kind, files partial per kind; a file that could not be read is none of them, so "Still indexing (N%)" is not held
// back by it), not from the code under test.
//
// SUITE PLACEMENT. HOME is process-wide: nested inside `ModelDownloadTests`.
//
// API SHAPES these tests pin (new; if a shape is wrong, ask for a test change rather than guessing). In `Sesame`.
//   1. `IndexProgress.counts(reader: IndexReader) -> IndexCounts` (the type the panel's snapshot already holds). It asks
//      `reader.statusCounts()` and opens nothing itself. The no-argument `counts()` goes away (a test cannot prove a
//      deletion; the static test below does).
//   2. `PanelSnapshot.read(reader:model:)` keeps its signature and takes `counts` from that call.
//
// HOW "THROUGH THE READER" IS PROVED. An `IndexReader` opens its connection on its first call and keeps it. The tests
// open the reader while HOME holds the index, then point HOME at a folder with no index, and only then ask for the
// counts: a function that opens `index.sqlite` itself (from HOME) finds nothing and reads zeros; one that goes through
// the reader still sees the rows. The tests put HOME back before they return.
//
// WHAT THIS CANNOT PIN: that the main thread is not blocked (that is the real app, F13), and that the reader is not
// called more often than the panel needs.

private func ipAddFile(_ store: IndexStore, _ name: String, kind: String, status: String, inode: Int64) throws {
    _ = try store.addFile(path: "/photos/\(name)", kind: kind, size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                          device: 1, status: status)
}

/// 3 photos + 1 pdf done, 2 photos + 1 doc pending, 1 pdf partial, 2 files that could not be read (not counted).
private func ipWriteIndex() throws {
    let store = try IndexStore()
    defer { store.close() }
    var inode: Int64 = 0
    func add(_ kind: String, _ status: String, _ count: Int) throws {
        for number in 0..<count {
            inode += 1
            try ipAddFile(store, "\(kind)-\(status)-\(number)", kind: kind, status: status, inode: inode)
        }
    }
    try add("photo", "done", 3)
    try add("pdf", "done", 1)
    try add("photo", "pending", 2)
    try add("doc", "pending", 1)
    try add("pdf", "partial", 1)
    try add("photo", "could_not_read", 1)
    try add("pdf", "could_not_read", 1)
}

private let ipExpected = IndexCounts(done: 4, pending: ["photo": 2, "doc": 1], partial: ["pdf": 1])

// plan-2-t2 (R2): files the process cannot open carry the status `needs_permission` in the index. They are none of
// done, pending or partial; `IndexCounts.needsPermission` (new field, default 0 in `IndexCounts.init`) holds their number
// over every kind. Written from the plan-2-t2 entry only.

/// `photos` photo rows and `pdfs` pdf rows with the status `needs_permission`, added to whatever index is there.
private func ipAddNeedsPermission(photos: Int, pdfs: Int) throws {
    let store = try IndexStore()
    defer { store.close() }
    var inode: Int64 = 5000
    for number in 0..<photos {
        inode += 1
        try ipAddFile(store, "locked-photo-\(number).jpg", kind: "photo", status: "needs_permission", inode: inode)
    }
    for number in 0..<pdfs {
        inode += 1
        try ipAddFile(store, "locked-pdf-\(number).pdf", kind: "pdf", status: "needs_permission", inode: inode)
    }
}

/// Runs `body` with HOME pointing at an empty folder (no index), then puts HOME back.
@MainActor
private func ipWithHomeMovedAway(_ body: @MainActor () throws -> Void) throws {
    let fm = FileManager.default
    let elsewhere = fm.temporaryDirectory.appendingPathComponent("sesame-progress-elsewhere-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let previous = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", elsewhere.path, 1)
    defer {
        if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: elsewhere)
    }
    _ = try SesameFolder.create()
    try body()
}

extension ModelDownloadTests {
    @Suite("IndexProgressReaderTests", .serialized)
    struct IndexProgressReaderTests {

        @MainActor
        @Test func countsAreTheFilesDonePendingAndPartialPerKindAndCouldNotReadFilesAreNone() async throws {
            try await spWithHome { _ in
                try ipWriteIndex()
                let reader = IndexReader()
                defer { reader.close() }
                #expect(IndexProgress.counts(reader: reader) == ipExpected, "got \(IndexProgress.counts(reader: reader))")
            }
        }

        @MainActor
        @Test func countsComeThroughTheReadersOwnConnectionNotAnotherOne() async throws {
            try await spWithHome { _ in
                try ipWriteIndex()
                let reader = IndexReader()
                defer { reader.close() }
                #expect(reader.fileCount() == 10, "setup: the reader should see the 10 files")
                try ipWithHomeMovedAway {
                    let counts = IndexProgress.counts(reader: reader)
                    #expect(counts == ipExpected, "got \(counts): a second connection opened from HOME would find no index and read zeros")
                }
            }
        }

        @MainActor
        @Test func thePanelSnapshotTakesItsCountsFromTheSameReader() async throws {
            try await spWithHome { _ in
                try ipWriteIndex()
                let reader = IndexReader()
                defer { reader.close() }
                #expect(reader.fileCount() == 10, "setup: the reader should see the 10 files")
                try ipWithHomeMovedAway {
                    let snapshot = PanelSnapshot.read(reader: reader, model: .whole)
                    #expect(snapshot.counts == ipExpected, "the snapshot's counts are \(snapshot.counts)")
                }
            }
        }

        @MainActor
        @Test func noIndexFileGivesZeroCountsAndTheSameReaderThenFollowsLaterWrites() async throws {
            try await spWithHome { _ in
                let reader = IndexReader()
                defer { reader.close() }
                let none = IndexCounts(done: 0, pending: [:], partial: [:])
                #expect(IndexProgress.counts(reader: reader) == none, "no index yet: \(IndexProgress.counts(reader: reader))")
                try ipWriteIndex()
                #expect(IndexProgress.counts(reader: reader) == ipExpected,
                        "after the store made the file: \(IndexProgress.counts(reader: reader))")
            }
        }

        // MARK: plan-2-t2: needs_permission rows

        @Test func theDefaultOfTheNeedsPermissionFieldIsZero() {
            #expect(IndexCounts(done: 1, pending: [:], partial: [:]).needsPermission == 0)
            #expect(IndexCounts(done: 1, pending: ["photo": 1], partial: ["pdf": 2]).needsPermission == 0)
        }

        @MainActor
        @Test func needsPermissionRowsComeBackInTheirOwnFieldAndAreNeverCountedAsDonePendingOrPartial() async throws {
            try await spWithHome { _ in
                try ipWriteIndex()
                try ipAddNeedsPermission(photos: 2, pdfs: 1)
                let reader = IndexReader()
                defer { reader.close() }
                let counts = IndexProgress.counts(reader: reader)
                #expect(counts.needsPermission == 3, "needsPermission is \(counts.needsPermission), expected the 2 photos and 1 pdf")
                #expect(counts.done == 4, "done is \(counts.done): a needs_permission row must not count as done")
                #expect(counts.pending == ["photo": 2, "doc": 1], "pending is \(counts.pending)")
                #expect(counts.partial == ["pdf": 1], "partial is \(counts.partial)")
                #expect(counts == IndexCounts(done: 4, pending: ["photo": 2, "doc": 1], partial: ["pdf": 1], needsPermission: 3),
                        "got \(counts)")
            }
        }

        @MainActor
        @Test func anIndexWithNoNeedsPermissionRowsReadsZero() async throws {
            try await spWithHome { _ in
                try ipWriteIndex()
                let reader = IndexReader()
                defer { reader.close() }
                #expect(IndexProgress.counts(reader: reader).needsPermission == 0)
            }
        }

        @MainActor
        @Test func anIndexHoldingOnlyNeedsPermissionRowsHasNothingDonePendingOrPartial() async throws {
            try await spWithHome { _ in
                try ipAddNeedsPermission(photos: 2, pdfs: 0)
                let reader = IndexReader()
                defer { reader.close() }
                let counts = IndexProgress.counts(reader: reader)
                #expect(counts.needsPermission == 2, "needsPermission is \(counts.needsPermission), expected the 2 locked photos")
                #expect(counts.done == 0 && counts.pending.isEmpty && counts.partial.isEmpty, "got \(counts)")
                #expect(counts == IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 2), "got \(counts)")
            }
        }

        @MainActor
        @Test func thePanelSnapshotCarriesTheNeedsPermissionCountFromTheSameReader() async throws {
            try await spWithHome { _ in
                try ipWriteIndex()
                try ipAddNeedsPermission(photos: 1, pdfs: 0)
                let reader = IndexReader()
                defer { reader.close() }
                let snapshot = PanelSnapshot.read(reader: reader, model: .whole)
                #expect(snapshot.counts.needsPermission == 1, "the snapshot's counts are \(snapshot.counts)")
                #expect(snapshot.counts.done == 4, "the snapshot's counts are \(snapshot.counts)")
            }
        }

        // MARK: the static rule

        /// Static, like check-static.sh's `sqlite-app-open`: no file under Sources/Sesame calls `sqlite3_open*`. Today
        /// StateViews.swift does (IndexProgress). The rule in scripts/check-static.sh is WARN until the controller sets
        /// `$SQLITE_APP_OPEN_IS_FAIL = 1` (line 60), which is the flip to make once this is green.
        @Test func noFileOfTheAppTargetOpensSQLiteItself() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let app = root.appendingPathComponent("Sources/Sesame", isDirectory: true)
            let found = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
            var swiftFiles = 0
            var offenders: [String] = []
            let pattern = try NSRegularExpression(pattern: #"\bsqlite3_open\w*\s*\("#)
            while let url = found?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                swiftFiles += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                let whole = NSRange(location: 0, length: (text as NSString).length)
                if pattern.firstMatch(in: text, range: whole) != nil {
                    offenders.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
            #expect(swiftFiles > 10, "setup: found only \(swiftFiles) Swift files under \(app.path); the test looked in the wrong place")
            #expect(offenders.isEmpty, "the app target opens SQLite itself in: \(offenders.sorted())")
        }
    }
}

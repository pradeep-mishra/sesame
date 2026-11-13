import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-1-t31, tester step. Written from the t31 entry, the Helper protocol table of the plan's Conventions and
// design sections 1, 2, 3, 8 and 9 only; no product source read.
//
// These tests start the helper the way the app does: `SesameHelper index` (no model flag at all), with
// `SESAME_FAKE_EMBEDDER=1` and `HOME` pointing at a throwaway folder, send hand-written `folders` lines on its stdin
// and read the JSON lines it writes on stdout. The index is looked at with this file's own read-only SQLite
// connection (the file is `$HOME/Library/Application Support/Sesame/index.sqlite`), so what is checked is what is on
// disk, not what the product says about itself. Expected values come from the test's own inputs and from `stat` of
// the files the test made, never from the code under test.
//
// The helper is the debug build that `swift test` builds next to the test bundle (the test target depends on it).
// The suite is nested in `EncodeHelperTests` (Reading.swift), so no helper suite runs beside it: it sets
// `SESAME_FAKE_EMBEDDER` and `HOME` for the moment of the launch only, and no encode helper may inherit them.
//
// What the entry fixes and what these tests do not assume:
// - Photos are the only kind read. Reading them is t32, so no test here looks at `passages` except to show a repeat
//   line adds none, and none looks at `status`, `tries` or `read_to` except to show a repeat line leaves them alone.
// - A changed file may keep or lose its row id (the entry fixes the id only for unchanged rows), so only the rows
//   of untouched files are checked for id.
// - `walked` and `changed` are separate events whose relative order the table does not fix. Only "after the commit"
//   is asserted: when either arrives the index already holds the rows.
// - The value of `walk_done_at` is a time whose text form the design does not fix; it is checked as present and
//   non-empty. The `meta` table may be one row of named columns or key and value rows (kit-index.sh reads both
//   shapes); so does this file.

// MARK: raw read-only SQLite, independent of the product

private final class T31DB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
    }

    deinit { sqlite3_close_v2(db) }

    /// Every row as text (nil for NULL), or nil when the statement cannot run (no such table yet, a lock).
    func rows(_ sql: String) -> [[String?]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
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
            out.append(row)
        }
        return out
    }

    func count(_ table: String) -> Int? {
        guard let result = rows("select count(*) from \(table)"), let cell = result.first?.first,
              let text = cell, let number = Int(text) else { return nil }
        return number
    }

    /// The value of a meta fact, nil when absent or unreadable.
    func meta(_ name: String) -> String? {
        guard let columns = rows("select name from pragma_table_info('meta') order by cid") else { return nil }
        let names = columns.compactMap { row -> String? in
            guard let cell = row.first, let text = cell else { return nil }
            return text
        }
        var sql: String?
        if names.contains(name) {
            sql = "select \"\(name)\" from meta limit 1"
        } else if names.count == 2 {
            sql = "select \"\(names[1])\" from meta where \"\(names[0])\" = '\(name)' limit 1"
        }
        guard let sql, let result = rows(sql), let row = result.first, let cell = row.first, let text = cell else {
            return nil
        }
        return text
    }

    /// One consistent snapshot: the number of `files` rows and `meta.walk_done_at` (nil when absent or empty).
    func state() -> (rows: Int, walkDone: String?)? {
        guard rows("BEGIN") != nil else { return nil }
        defer { _ = rows("COMMIT") }
        guard let files = count("files") else { return nil }
        let walk = meta("walk_done_at")
        return (files, (walk ?? "").isEmpty ? nil : walk)
    }
}

private struct T31Row: Equatable {
    let id: Int64?
    let path: String
    let kind: String?
    let size: Int64?
    let mtimeNs: Int64?
    let inode: UInt64?
}

private func t31Normal(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

private func t31FileRows(_ db: T31DB) -> [T31Row]? {
    guard let rows = db.rows("select id, path, kind, size, mtime_ns, inode from files order by path") else { return nil }
    return rows.map { row in
        func text(_ index: Int) -> String? { index < row.count ? (row[index] ?? nil) : nil }
        return T31Row(id: text(0).flatMap { Int64($0) }, path: t31Normal(text(1) ?? ""), kind: text(2),
                      size: text(3).flatMap { Int64($0) }, mtimeNs: text(4).flatMap { Int64($0) },
                      inode: text(5).flatMap { UInt64($0) })
    }
}

/// Every column of every `files` row, plus the passage and fts row counts: what "no row changed" is measured on.
private func t31Snapshot(_ db: T31DB) -> [String]? {
    guard let files = db.rows("select * from files order by id") else { return nil }
    var lines = files.map { $0.map { $0 ?? "NULL" }.joined(separator: "|") }
    lines.append("passages=\(db.count("passages").map(String.init) ?? "unreadable")")
    lines.append("fts=\(db.count("fts").map(String.init) ?? "unreadable")")
    return lines
}

// MARK: the throwaway world

private final class T31World {
    let root: URL
    let home: URL
    let photos: URL

    var support: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var indexFile: String { support.appendingPathComponent("index.sqlite").path }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sesame-t31-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        photos = root.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        // The app makes this folder (mode 0700) before it ever starts a helper.
        try fm.createDirectory(at: support, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func t31WithWorld(_ body: (T31World) throws -> Void) throws {
    let world = try T31World()
    defer { world.remove() }
    try body(world)
}

/// The mtime every generated photo gets: an hour or more in the past, so no "modified a moment ago" wait applies.
private let t31Past = Date().timeIntervalSince1970.rounded(.down) - 3600

private func t31PhotoData(seed: Int, side: Int, png: Bool) -> Data {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12_345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 41)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 49)
        pixels[index + 3] = 255
    }
    let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let data = NSMutableData()
    if let image, let destination = CGImageDestinationCreateWithData(
        data, (png ? "public.png" : "public.jpeg") as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return data as Data
}

/// Writes (or rewrites in place, same inode) one photo and sets its modified time.
private func t31WritePhoto(_ url: URL, seed: Int, side: Int, mtime: TimeInterval) throws {
    let png = url.pathExtension == "png"
    let data = t31PhotoData(seed: seed, side: side, png: png)
    #expect(!data.isEmpty, "the test could not encode \(url.lastPathComponent)")
    try data.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                          ofItemAtPath: url.path)
}

/// `count` photos named `<prefix>-NN.jpg` or `.png` in `directory`; each gets its own pixels and a past mtime.
private func t31MakePhotos(in directory: URL, count: Int, prefix: String = "photo", firstSeed: Int = 1) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var made: [URL] = []
    for number in 1...count {
        let name = String(format: "%@-%02d.%@", prefix, number, number % 2 == 0 ? "png" : "jpg")
        let url = directory.appendingPathComponent(name)
        try t31WritePhoto(url, seed: firstSeed + number, side: 64, mtime: t31Past - Double(number))
        made.append(url)
    }
    return made
}

private func t31Stat(_ url: URL) -> (size: Int64, mtimeNs: Int64, inode: UInt64)? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return (Int64(info.st_size),
            Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            UInt64(info.st_ino))
}

// MARK: the helper

private func t31StartHelper(_ world: T31World) throws -> HelperProcess {
    let executable = try #require(KitPaths.debugHelper(),
                                  "debug SesameHelper not found next to the test bundle or in .build/debug")
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    setenv("SESAME_FAKE_EMBEDDER", "1", 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    // No `--text-model`, no `--mm-model`: with the fake embedder set, no model path is passed.
    return try HelperProcess(executable: executable, arguments: ["index"])
}

private func t31JSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

/// The hand-written `folders` line of the Helper protocol table: the whole list, `code` false.
private func t31FoldersLine(_ folders: [URL]) -> String {
    let items = folders.map { "{\"path\":\(t31JSONString($0.path)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private func t31Parse(_ line: (text: String, at: Date)) -> HelperReply? {
    if let reply = HelperReply(line.text), reply.event != nil { return reply }
    Issue.record("a line from the helper is not one JSON object with an `event`: \(line.text.prefix(200))")
    return nil
}

/// Reads events until `quiet` seconds pass with none (or `cap` seconds in all, or the helper's output ends).
private func t31Drain(_ helper: HelperProcess, quiet: TimeInterval = 3, cap: TimeInterval = 60)
    -> (events: [HelperReply], lastAt: Date?) {
    var events: [HelperReply] = []
    var lastAt: Date?
    let deadline = Date().addingTimeInterval(cap)
    while Date() < deadline {
        guard let line = helper.nextLine(timeout: quiet) else { break }
        lastAt = line.at
        if let reply = t31Parse(line) { events.append(reply) }
    }
    return (events, lastAt)
}

/// Reads events until one named `name` arrives, the helper's output ends, or `cap` seconds pass.
private func t31Wait(_ helper: HelperProcess, for name: String, cap: TimeInterval = 60)
    -> (events: [HelperReply], found: Bool) {
    var events: [HelperReply] = []
    let deadline = Date().addingTimeInterval(cap)
    while Date() < deadline {
        guard let line = helper.nextLine(timeout: min(5, max(0.1, deadline.timeIntervalSinceNow))) else {
            if helper.isRunning { continue }
            break
        }
        guard let reply = t31Parse(line) else { continue }
        events.append(reply)
        if reply.event == name { return (events, true) }
    }
    return (events, false)
}

private func t31Count(_ events: [HelperReply], _ name: String) -> Int {
    events.filter { $0.event == name }.count
}

private func t31Open(_ world: T31World) -> T31DB? { T31DB(path: world.indexFile) }

/// Asserts the `files` rows are exactly the photos in `expected`, each with the size, mtime_ns and inode
/// `stat` gives for it now and kind `photo`.
private func t31CheckRows(_ db: T31DB, expected: [URL], _ label: String) {
    guard let rows = t31FileRows(db) else {
        Issue.record("\(label): the `files` table cannot be read")
        return
    }
    let wanted = Set(expected.map { t31Normal($0.path) })
    let got = Set(rows.map { $0.path })
    #expect(rows.count == expected.count, "\(label): \(rows.count) rows, expected \(expected.count)")
    #expect(got == wanted, "\(label): missing \(wanted.subtracting(got).sorted().map { ($0 as NSString).lastPathComponent }), unexpected \(got.subtracting(wanted).sorted().map { ($0 as NSString).lastPathComponent })")
    for url in expected {
        guard let row = rows.first(where: { $0.path == t31Normal(url.path) }), let info = t31Stat(url) else { continue }
        let name = url.lastPathComponent
        #expect(row.kind == "photo", "\(label): \(name) has kind \(row.kind ?? "nil"), expected photo")
        #expect(row.size == info.size, "\(label): \(name) has size \(String(describing: row.size)), the file is \(info.size)")
        #expect(row.mtimeNs == info.mtimeNs,
                "\(label): \(name) has mtime_ns \(String(describing: row.mtimeNs)), the file is \(info.mtimeNs)")
        #expect(row.inode == info.inode, "\(label): \(name) has inode \(String(describing: row.inode)), the file is \(info.inode)")
        #expect(row.id != nil, "\(label): \(name) has no id")
    }
}

private func t31IDs(_ db: T31DB) -> [String: Int64] {
    var ids: [String: Int64] = [:]
    for row in t31FileRows(db) ?? [] { if let id = row.id { ids[row.path] = id } }
    return ids
}

// The parent suite serializes every helper suite, so one helper (and one set of launch variables) at a time.
extension EncodeHelperTests {
@Suite("IndexReconcileTests", .serialized)
struct IndexReconcileTests {

    // MARK: the first folders line

    @Test func aFoldersLineMakesOneTransactionOf40NewRowsAndWalkDoneAtIsSetBeforeWalkedIsSent() throws {
        try t31WithWorld { world in
            let photos = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([world.photos]))

            // While the helper reconciles, look at the index as fast as possible. One transaction means a reader
            // sees 0 rows or all 40, and never `walk_done_at` without the 40 rows.
            var events: [HelperReply] = []
            var sawWalked = false
            var partial = Set<Int>()
            var walkDoneWithoutRows: [Int] = []
            var db: T31DB?
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                if let line = helper.nextLine(timeout: 0.002) {
                    guard let reply = t31Parse(line) else { continue }
                    events.append(reply)
                    if reply.event == "walked" { sawWalked = true; break }
                } else if !helper.isRunning {
                    break
                }
                if db == nil { db = t31Open(world) }
                if let state = db?.state() {
                    if (1..<40).contains(state.rows) { partial.insert(state.rows) }
                    if state.walkDone != nil && state.rows != 40 { walkDoneWithoutRows.append(state.rows) }
                }
            }
            #expect(sawWalked, "no `walked` event within 90 s of the folders line; events \(events.map { $0.event ?? "?" }), exit \(helper.waitForExit(timeout: 0.1)?.status.description ?? "still running"), stderr: \(helper.errors)")
            guard sawWalked else { return }

            // At the moment `walked` arrives the commit is done: 40 rows and walk_done_at, in the same snapshot.
            let after = try #require(t31Open(world), "no index.sqlite once `walked` was sent")
            let state = try #require(after.state(), "the index cannot be read once `walked` was sent")
            #expect(state.rows == 40, "`walked` was sent with \(state.rows) rows in `files`, expected 40")
            #expect(state.walkDone != nil, "`walked` was sent but meta.walk_done_at is not set")
            #expect(partial.isEmpty, "a reader saw \(partial.sorted()) rows: the reconcile was not one transaction")
            #expect(walkDoneWithoutRows.isEmpty,
                    "a reader saw walk_done_at with \(walkDoneWithoutRows) rows: it was not written in the same transaction as the rows")

            let rest = t31Drain(helper)
            events += rest.events
            let names = Set(events.compactMap { $0.event })
            #expect(names.isSubset(of: ["changed", "walked"]), "unexpected events \(names.sorted())")
            #expect(t31Count(events, "walked") == 1, "\(t31Count(events, "walked")) `walked` events, expected exactly 1")
            #expect(t31Count(events, "changed") >= 1, "no `changed` event after the commit")
            t31CheckRows(after, expected: photos, "first folders line")
        }
    }

    // MARK: new, changed and deleted files

    @Test func aSecondLineCreatesTheNewFileUpdatesTheChangedOneAndRemovesTheDeletedOne() throws {
        try t31WithWorld { world in
            var photos = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            let line = t31FoldersLine([world.photos])
            helper.send(line)
            let first = t31Wait(helper, for: "walked")
            #expect(first.found, "no `walked` event after the first folders line; stderr: \(helper.errors)")
            guard first.found else { return }
            _ = t31Drain(helper)
            let before = try #require(t31Open(world))
            t31CheckRows(before, expected: photos, "before the change")
            let idsBefore = t31IDs(before)
            let sizeBefore = try #require(t31FileRows(before)?.first { $0.path == t31Normal(photos[4].path) }?.size)

            // The test rewrites one file (new pixels, new size, new modified time), deletes one, adds one.
            let changed = photos[4]
            let deleted = photos[6]
            try t31WritePhoto(changed, seed: 999, side: 96, mtime: t31Past - 1800)
            try FileManager.default.removeItem(at: deleted)
            let added = world.photos.appendingPathComponent("photo-41.jpg")
            try t31WritePhoto(added, seed: 4_141, side: 64, mtime: t31Past - 41)
            photos = photos.filter { $0 != deleted } + [added]
            let newSize = try #require(t31Stat(changed)?.size)
            #expect(newSize != sizeBefore, "the test's rewrite did not change the file's size")

            helper.send(line)
            let second = t31Wait(helper, for: "changed", cap: 30)
            #expect(second.found, "no `changed` event after a line over a changed tree; stderr: \(helper.errors)")
            _ = t31Drain(helper)

            let after = try #require(t31Open(world))
            t31CheckRows(after, expected: photos, "after new, changed and deleted")
            let rows = t31FileRows(after) ?? []
            #expect(!rows.contains { $0.path == t31Normal(deleted.path) }, "the deleted file still has a row")
            #expect(rows.contains { $0.path == t31Normal(added.path) }, "the new file has no row")
            #expect(rows.first { $0.path == t31Normal(changed.path) }?.size == newSize, "the changed file's row still holds its old size")
            let idsAfter = t31IDs(after)
            let untouched = photos.filter { $0 != changed && $0 != added }
            for url in untouched {
                let key = t31Normal(url.path)
                #expect(idsAfter[key] == idsBefore[key],
                        "\(url.lastPathComponent): row id \(String(describing: idsBefore[key])) became \(String(describing: idsAfter[key])) though the file did not change")
            }
        }
    }

    // MARK: a shorter list

    @Test func aFoldersLineWithAShorterListRemovesTheRowsOutsideIt() throws {
        try t31WithWorld { world in
            let folderA = world.photos.appendingPathComponent("a", isDirectory: true)
            let folderB = world.photos.appendingPathComponent("b", isDirectory: true)
            let inA = try t31MakePhotos(in: folderA, count: 20, prefix: "a", firstSeed: 100)
            let inB = try t31MakePhotos(in: folderB, count: 20, prefix: "b", firstSeed: 200)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([folderA, folderB]))
            let first = t31Wait(helper, for: "walked")
            #expect(first.found, "no `walked` event after the first folders line; stderr: \(helper.errors)")
            guard first.found else { return }
            _ = t31Drain(helper)
            let both = try #require(t31Open(world))
            t31CheckRows(both, expected: inA + inB, "two folders")
            let idsBoth = t31IDs(both)

            helper.send(t31FoldersLine([folderA]))
            let second = t31Wait(helper, for: "changed", cap: 30)
            #expect(second.found, "no `changed` event after a shorter list; stderr: \(helper.errors)")
            _ = t31Drain(helper)
            let onlyA = try #require(t31Open(world))
            t31CheckRows(onlyA, expected: inA, "list shortened to folder a")
            let idsA = t31IDs(onlyA)
            for url in inA {
                let key = t31Normal(url.path)
                #expect(idsA[key] == idsBoth[key], "\(url.lastPathComponent): the row id changed though the file did not")
            }

            helper.send(t31FoldersLine([]))
            let third = t31Wait(helper, for: "changed", cap: 30)
            #expect(third.found, "no `changed` event after the empty list; stderr: \(helper.errors)")
            _ = t31Drain(helper)
            let none = try #require(t31Open(world))
            #expect(none.count("files") == 0, "the empty list left \(String(describing: none.count("files"))) rows")
        }
    }

    // MARK: a second identical line

    @Test func aSecondIdenticalLineOverUnchangedFilesChangesNoRowKeepsEveryIdAndEmbedsNothing() throws {
        try t31WithWorld { world in
            let photos = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            let line = t31FoldersLine([world.photos])
            helper.send(line)
            let first = t31Wait(helper, for: "walked")
            #expect(first.found, "no `walked` event after the first folders line; stderr: \(helper.errors)")
            guard first.found else { return }
            _ = t31Drain(helper)
            let beforeDB = try #require(t31Open(world))
            let before = try #require(t31Snapshot(beforeDB), "the index cannot be read")
            let idsBefore = t31IDs(beforeDB)
            #expect(idsBefore.count == 40)

            helper.send(line)
            _ = t31Drain(helper, quiet: 4, cap: 40)
            #expect(helper.isRunning, "the helper exited after a repeated folders line")

            let afterDB = try #require(t31Open(world))
            let after = try #require(t31Snapshot(afterDB), "the index cannot be read after the repeat")
            #expect(after == before, "the repeat changed the index.\nbefore: \(before.prefix(3))...\nafter:  \(after.prefix(3))...")
            #expect(t31IDs(afterDB) == idsBefore, "a row id changed on the repeat")
            t31CheckRows(afterDB, expected: photos, "after the repeat")
        }
    }

    // MARK: an empty folder

    @Test func anEmptyFolderGivesZeroRowsAWalkedEventAndWalkDoneAt() throws {
        try t31WithWorld { world in
            let empty = world.photos.appendingPathComponent("empty", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([empty]))
            let walked = t31Wait(helper, for: "walked")
            #expect(walked.found, "no `walked` event for an empty folder; events \(walked.events.map { $0.event ?? "?" }), stderr: \(helper.errors)")
            guard walked.found else { return }
            let rest = t31Drain(helper)
            let all = walked.events + rest.events
            #expect(t31Count(all, "walked") == 1, "\(t31Count(all, "walked")) `walked` events, expected exactly 1")
            #expect(t31Count(all, "changed") >= 1, "no `changed` event after the commit that wrote walk_done_at")
            let db = try #require(t31Open(world), "no index.sqlite after an empty walk")
            let state = try #require(db.state(), "the index cannot be read")
            #expect(state.rows == 0, "an empty folder gave \(state.rows) rows")
            #expect(state.walkDone != nil, "meta.walk_done_at is not set after an empty walk")
        }
    }

    // MARK: exits

    @Test func theHelperExitsAtStdinEofAfterItsCurrentUnit() throws {
        try t31WithWorld { world in
            _ = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([world.photos]))
            let walked = t31Wait(helper, for: "walked")
            #expect(walked.found, "no `walked` event; stderr: \(helper.errors)")
            guard walked.found else { return }
            helper.closeStdin()
            let gone = helper.waitForExit(timeout: 20)
            let exit = try #require(gone, "the helper was still running 20 s after stdin was closed")
            #expect(exit.status == 0, "exit status \(exit.status) at stdin EOF, expected 0")
        }
    }

    @Test func theHelperStartedAndThenGivenEofAtOnceExitsWithStatusZero() throws {
        try t31WithWorld { world in
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.closeStdin()
            let gone = helper.waitForExit(timeout: 20)
            let exit = try #require(gone, "the helper was still running 20 s after stdin was closed")
            #expect(exit.status == 0, "exit status \(exit.status) at stdin EOF in `index` mode, expected 0; stderr: \(helper.errors)")
        }
    }

    @Test func theHelperExitsByItselfSixtySecondsAfterItsLastWork() throws {
        try t31WithWorld { world in
            _ = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([world.photos]))
            let walked = t31Wait(helper, for: "walked")
            #expect(walked.found, "no `walked` event; stderr: \(helper.errors)")
            guard walked.found else { return }
            let rest = t31Drain(helper)
            let lastWork = rest.lastAt ?? Date()
            // stdin stays open the whole time: this is the idle exit, not the EOF exit.
            Thread.sleep(until: lastWork.addingTimeInterval(30))
            #expect(helper.isRunning, "the helper exited about 30 s after its last work, before 60 s")
            let gone = try #require(helper.waitForExit(timeout: 70), "the helper was still running 100 s after its last work")
            let after = gone.at.timeIntervalSince(lastWork)
            #expect(gone.status == 0, "idle exit status \(gone.status), expected 0")
            #expect(after >= 55 && after <= 75, "the helper exited \(after) s after its last work, expected 60 s (55 to 75)")
        }
    }

    // MARK: the fake embedder

    @Test func withTheFakeEmbedderSetNoModelIsLoaded() throws {
        try t31WithWorld { world in
            _ = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([world.photos]))
            let walked = t31Wait(helper, for: "walked")
            #expect(walked.found, "no `walked` event with no model path and the fake embedder set; stderr: \(helper.errors)")
            guard walked.found else { return }
            _ = t31Drain(helper)
            #expect(helper.isRunning, "the helper exited by itself without a model; stderr: \(helper.errors)")
            let footprint = try #require(Tools.footprintMB(pid: helper.pid), "footprint could not read the helper")
            #expect(footprint < 100, "the helper holds \(footprint) MB: a model (250 MB or more) looks loaded")
            let open = try #require(Tools.capture("/usr/sbin/lsof", ["-n", "-P", "-p", String(helper.pid)]), "lsof could not run")
            #expect(!open.output.contains(".gguf"), "the helper holds a model file open:\n\(open.output.split(separator: "\n").filter { $0.contains(".gguf") })")
            let models = world.support.appendingPathComponent("models")
            #expect(!FileManager.default.fileExists(atPath: models.path), "something made a models folder in the throwaway home")
        }
    }

    @Test func theIndexWrittenUnderTheFakeCarriesTheRealVectorSource() throws {
        try t31WithWorld { world in
            _ = try t31MakePhotos(in: world.photos, count: 40)
            let helper = try t31StartHelper(world)
            defer { helper.stop() }
            helper.send(t31FoldersLine([world.photos]))
            let walked = t31Wait(helper, for: "walked")
            #expect(walked.found, "no `walked` event; stderr: \(helper.errors)")
            guard walked.found else { return }
            let db = try #require(t31Open(world), "no index.sqlite")
            let source = try #require(db.meta("vector_source"), "meta.vector_source is not set in an index written under the fake")
            #expect(!LlamaEmbedder.vectorSource.isEmpty)
            #expect(source == LlamaEmbedder.vectorSource,
                    "meta.vector_source is \(source), the app expects \(LlamaEmbedder.vectorSource)")
        }
    }
}
}

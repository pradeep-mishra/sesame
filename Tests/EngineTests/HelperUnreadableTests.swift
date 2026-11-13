import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SQLite3
import Testing
import Vision

// plan-1 review round A, tester step: findings F1 and F2 at the helper (index mode) level.
// Written from the review report (F1, F2), the brief's acceptance lines and design sections 3 and 14 (Q4) only.
// Product source read for names and where logic lives: Sources/SesameHelper/Reconcile.swift, Index.swift,
// Sources/SesameEngine/PhotoReader.swift. No expected value comes from them.
//
// These tests start the helper the way the app does: `SesameHelper index` (debug build), `SESAME_FAKE_EMBEDDER=1`,
// `HOME` pointing at a throwaway folder, hand-written `folders` lines on stdin, JSON events on stdout. The index is
// read with this file's own read-only SQLite connection, so what is checked is what is on disk.
//
// Permissions: `chmod 000` on a folder or a photo. Every lock goes through `HWorld.lock`, which remembers the old
// mode, and `HWorld.remove()` puts every mode back before the throwaway tree is deleted (also when a test fails).
// The tests need a user who is not root (root reads through chmod 000); they say so and stop when run as root.
//
// What the review and design fix (the expected values):
// - F1: an unreadable subfolder (or root) of a picked folder never costs the readable files, `walked` is still sent,
//   and the rows of files under the unreadable path are KEPT. Rows of files that vanished from readable folders are
//   still deleted. A root that does not exist (the unplugged drive of design section 14, Q4) still deletes its rows.
// - F2, as changed by plan-2-t2 (carry-over R2): a photo the process may not open gets the new status
//   `needs_permission` (never `could_not_read`, and no longer `pending` for good, which kept the panel on "Still
//   indexing" forever). It is written by the helper with `tries` 0 and no passages, it is not read again in the same
//   helper run, the helper still exits at stdin end, and the next helper run turns the row back to `pending` once, at
//   its first `folders` line, so it becomes `done` once the permission is back. A changed file (new size or modified
//   time) is reset by the reconcile as any changed file. A photo whose bytes are read but are not an image is
//   `could_not_read` with reason `damaged`. A file that vanished between the walk and the read stays `pending` and is
//   removed by the next walk.
//   Names used from the entry: status `needs_permission`, `IndexStore.retryNeedsPermission()` (the retry at the first
//   `folders` line). Everything else is read from the index file with this file's own SQLite connection.

// MARK: raw read-only SQLite, independent of the product

private final class HDB {
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

    func statuses() -> [String: Int]? {
        guard let result = rows("select status, count(*) from files group by status") else { return nil }
        var out: [String: Int] = [:]
        for row in result {
            if let status = row[0], let text = row[1], let n = Int(text) { out[status] = n }
        }
        return out
    }
}

// MARK: drawing photos

private func hNoiseJPEG(seed: Int, side: Int = 64) -> Data {
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
    if let image, let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return data as Data
}

/// The first text recognition on a Mac compiles its model, which takes tens of seconds and is kept for every later
/// process. The test does it once itself, so a helper's first photo is not mistaken for a stall.
private let hVisionWarm: Bool = {
    let width = 1500, height = 500
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 190, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: 60, y: 160)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "WARM UP 0123", attributes: attributes)), context)
    guard let image = context.makeImage() else { return false }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return true
}()

private let hPast = Date().timeIntervalSince1970.rounded(.down) - 3600

// MARK: the throwaway world

private final class HWorld {
    let root: URL
    let home: URL
    let pics: URL
    private var locked: [(path: String, mode: mode_t)] = []

    var support: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var indexFile: String { support.appendingPathComponent("index.sqlite").path }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sesame-hunreadable-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        pics = root.appendingPathComponent("pics", isDirectory: true)
        try fm.createDirectory(at: pics, withIntermediateDirectories: true)
        // The app makes this folder (mode 0700) before it ever starts a helper.
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// `chmod 000`, remembering the mode `remove()` puts back.
    func lock(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        locked.append((url.path, info.st_mode & 0o7777))
        chmod(url.path, 0)
    }

    func unlockAll() {
        for item in locked.reversed() { chmod(item.path, item.mode) }
        locked = []
    }

    func remove() {
        unlockAll()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The first photo through a freshly signed helper can take about 35 s (a cold Vision compile inside that binary; the
/// compile in this test process above does not warm it). Once per test process, one photo goes through a real helper
/// first, with up to 120 s allowed for it (cap 150 s); the tests' own stall limits then start from a warm binary.
/// Nothing is asserted here: a helper that never warms makes the real test fail with its own message.
private let hHelperWarm: Bool = {
    guard let world = try? HWorld() else { return false }
    defer { world.remove() }
    guard (try? hMakePhotos(in: world.pics, ["warm"])) != nil,
          let helper = try? hStartHelper(world) else { return false }
    defer { helper.stop() }
    helper.send(hFoldersLine([world.pics]))
    return hWaitDone(world, helper, total: 1, stall: 120, cap: 150).done == 1
}()

private func hWithWorld(_ body: (HWorld) throws -> Void) throws {
    _ = hVisionWarm
    _ = hHelperWarm
    let world = try HWorld()
    defer { world.remove() }
    try body(world)
}

/// chmod 000 does not stop root, so a test run as root says so and stops instead of passing or failing for nothing.
private func hCanTestPermissions() -> Bool {
    if getuid() == 0 {
        Issue.record("this test runs as root, and root reads through chmod 000: it cannot show anything; run it as the person")
        return false
    }
    return true
}

/// Writes `<folder>/<name>.jpg` for each name: noise pixels, a distinct seed, an hour or more in the past (newer
/// names first: the first name is the newest). Returns the URLs.
@discardableResult
private func hMakePhotos(in folder: URL, _ names: [String], firstSeed: Int = 1) throws -> [URL] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var made: [URL] = []
    for (index, name) in names.enumerated() {
        let url = folder.appendingPathComponent(name + ".jpg")
        try hNoiseJPEG(seed: firstSeed + index).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: hPast - Double(index))],
                                              ofItemAtPath: url.path)
        made.append(url)
    }
    return made
}

private func hRelative(_ path: String, to root: URL) -> String {
    let normal = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let prefix = root.path + "/"
    return normal.hasPrefix(prefix) ? String(normal.dropFirst(prefix.count)) : normal
}

/// Every `files` row as relative path to (status, reason), or nil when the index cannot be read.
private func hRows(_ world: HWorld) -> [String: (status: String, reason: String?)]? {
    guard let db = HDB(path: world.indexFile), let rows = db.rows("select path, status, reason from files") else { return nil }
    var out: [String: (status: String, reason: String?)] = [:]
    for row in rows {
        guard let path = row[0], let status = row[1] else { continue }
        out[hRelative(path, to: world.pics)] = (status, row[2])
    }
    return out
}

private func hKeys(_ rows: [String: (status: String, reason: String?)]?) -> Set<String> {
    Set((rows ?? [:]).keys)
}

private func hDescribe(_ rows: [String: (status: String, reason: String?)]?) -> String {
    guard let rows else { return "index unreadable" }
    return rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)\(rows[$0]!.reason.map { "(\($0))" } ?? "")" }.joined(separator: ", ")
}

// MARK: the helper

private func hStartHelper(_ world: HWorld) throws -> HelperProcess {
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
    return try HelperProcess(executable: executable, arguments: ["index"])
}

private func hJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

private func hFoldersLine(_ folders: [URL]) -> String {
    let items = folders.map { "{\"path\":\(hJSONString($0.path)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

/// Reads events until one named `name` arrives, the helper's output ends, or `cap` seconds pass.
private func hWait(_ helper: HelperProcess, for name: String, cap: TimeInterval = 60) -> (events: [String], found: Bool) {
    var events: [String] = []
    let deadline = Date().addingTimeInterval(cap)
    while Date() < deadline {
        guard let line = helper.nextLine(timeout: min(5, max(0.1, deadline.timeIntervalSinceNow))) else {
            if helper.isRunning { continue }
            break
        }
        guard let reply = HelperReply(line.text), let event = reply.event else { continue }
        events.append(event)
        if event == name { return (events, true) }
    }
    return (events, false)
}

/// Reads and drops events until `quiet` seconds pass with none (or `cap` seconds in all).
private func hDrain(_ helper: HelperProcess, quiet: TimeInterval = 2, cap: TimeInterval = 60) {
    let deadline = Date().addingTimeInterval(cap)
    while Date() < deadline {
        guard helper.nextLine(timeout: quiet) != nil else { break }
    }
}

private struct HWait {
    let done: Int
    let statuses: [String: Int]
    let seconds: Double
    func why(_ helper: HelperProcess) -> String {
        "\(done) done after \(Int(seconds)) s, statuses \(statuses.isEmpty ? "none (no files rows)" : "\(statuses)"), helper \(helper.isRunning ? "still running" : "exited"), stderr: \(helper.errors)"
    }
}

/// Polls the index until `total` files are `done`, until the done count has not changed for `stall` seconds, until
/// `cap` seconds in all, or until the helper is gone.
private func hWaitDone(_ world: HWorld, _ helper: HelperProcess, total: Int, stall: TimeInterval = 30,
                       cap: TimeInterval = 240) -> HWait {
    let started = Date()
    var lastChange = started
    var lastDone = -1
    var db: HDB?
    var statuses: [String: Int] = [:]
    while true {
        if db == nil { db = HDB(path: world.indexFile) }
        if let found = db?.statuses() {
            statuses = found
            let done = found["done"] ?? 0
            if done != lastDone { lastDone = done; lastChange = Date() }
            if done == total { break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return HWait(done: max(lastDone, 0), statuses: statuses, seconds: Date().timeIntervalSince(started))
}

/// Polls the index until `until` holds for the status counts, until `cap` seconds pass, or until the helper is gone and
/// the condition still does not hold. Returns the last counts read (empty when the index could not be read).
private func hWaitStatuses(_ world: HWorld, _ helper: HelperProcess, cap: TimeInterval = 90,
                           until: ([String: Int]) -> Bool) -> [String: Int] {
    let deadline = Date().addingTimeInterval(cap)
    var last: [String: Int] = [:]
    var db: HDB?
    while Date() < deadline {
        if db == nil { db = HDB(path: world.indexFile) }
        if let found = db?.statuses() {
            last = found
            if until(found) { break }
        }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return last
}

/// One value of one column of the one `files` row whose path ends with `/<name>`, as text, or nil.
private func hFileColumn(_ world: HWorld, _ name: String, _ column: String) -> String? {
    guard let db = HDB(path: world.indexFile),
          let rows = db.rows("select \(column) from files where path like '%/\(name)'"), rows.count == 1 else { return nil }
    return rows[0][0]
}

/// How many passages the file named `name` has.
private func hPassageCount(_ world: HWorld, _ name: String) -> Int? {
    guard let db = HDB(path: world.indexFile),
          let rows = db.rows("select count(*) from passages where file_id in (select id from files where path like '%/\(name)')"),
          let text = rows.first?.first ?? nil else { return nil }
    return Int(text)
}

/// Closes the helper's stdin and returns its exit status, or nil when it has not exited within `timeout` seconds.
private func hCleanStop(_ helper: HelperProcess, timeout: TimeInterval = 60) -> Int32? {
    helper.closeStdin()
    return helper.waitForExit(timeout: timeout)?.status
}

/// User plus system CPU seconds the process has used so far.
private func hCPUSeconds(pid: Int32) -> Double? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom) / 1_000_000_000
}

// MARK: F1, the helper's reconcile over unreadable paths

extension EncodeHelperTests {
/// The parent of both suites below, so `swift test --filter HelperUnreadableTests` runs all of them.
@Suite("HelperUnreadableTests", .serialized)
enum HelperUnreadableTests {}
}

extension EncodeHelperTests.HelperUnreadableTests {
@Suite("HelperUnreadableFolderTests", .serialized)
struct HelperUnreadableFolderTests {

    // F1 (a): the first walk. Today one unreadable subfolder aborts the whole walk, so nothing of the folder is read.
    @Test func aFirstWalkOverAFolderWithAnUnreadableSubfolderStillIndexesTheReadablePhotosAndSaysWalked() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            try hMakePhotos(in: world.pics.appendingPathComponent("ok"), ["a", "b", "c"])
            try hMakePhotos(in: world.pics.appendingPathComponent("locked"), ["x", "y"], firstSeed: 50)
            world.lock(world.pics.appendingPathComponent("locked"))
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            helper.send(hFoldersLine([world.pics]))

            let walked = hWait(helper, for: "walked")
            #expect(walked.found, "no `walked` event with one unreadable subfolder; events \(walked.events), stderr: \(helper.errors)")
            guard walked.found else { return }
            let wait = hWaitDone(world, helper, total: 3, stall: 20)
            #expect(wait.done == 3, "the 3 readable photos did not all reach done: \(wait.why(helper))")
            let rows = hRows(world)
            #expect(hKeys(rows) == ["ok/a.jpg", "ok/b.jpg", "ok/c.jpg"],
                    "rows should be exactly the 3 readable photos, got: \(hDescribe(rows))")
        }
    }

    // F1 (b): a later walk. Rows under the unreadable subfolder stay; a file that vanished from a readable folder goes.
    @Test func aLaterWalkKeepsTheRowsUnderAnUnreadableSubfolderAndStillDeletesRowsOfFilesThatVanishedFromReadableFolders() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            try hMakePhotos(in: world.pics.appendingPathComponent("ok"), ["a", "b", "c"])
            try hMakePhotos(in: world.pics.appendingPathComponent("locked"), ["x", "y"], firstSeed: 50)
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            let line = hFoldersLine([world.pics])
            helper.send(line)
            let first = hWaitDone(world, helper, total: 5)
            #expect(first.done == 5, "setup: the 5 photos did not reach done: \(first.why(helper))")
            guard first.done == 5 else { return }
            hDrain(helper)

            world.lock(world.pics.appendingPathComponent("locked"))
            try FileManager.default.removeItem(at: world.pics.appendingPathComponent("ok/c.jpg"))
            helper.send(line)
            let changed = hWait(helper, for: "changed", cap: 30)
            #expect(changed.found, "no `changed` event after the second folders line; stderr: \(helper.errors)")
            hDrain(helper)

            let rows = hRows(world)
            #expect(hKeys(rows) == ["ok/a.jpg", "ok/b.jpg", "locked/x.jpg", "locked/y.jpg"],
                    "expected the 2 readable rows and the 2 rows under the unreadable folder (ok/c.jpg gone), got: \(hDescribe(rows))")
            #expect(rows?["locked/x.jpg"]?.status == "done" && rows?["locked/y.jpg"]?.status == "done",
                    "the kept rows must be untouched (done), got: \(hDescribe(rows))")
        }
    }

    // F1 (c): an unreadable ROOT folder keeps all its rows, on the same helper and on a fresh one (which sends `walked`).
    @Test func anUnreadableRootFolderKeepsAllItsRowsAndAFreshHelperStillSaysWalked() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            try hMakePhotos(in: world.pics, ["a", "b", "c"])
            let line = hFoldersLine([world.pics])
            let wanted: Set<String> = ["a.jpg", "b.jpg", "c.jpg"]
            do {
                let helper = try hStartHelper(world)
                defer { helper.stop() }
                helper.send(line)
                let first = hWaitDone(world, helper, total: 3)
                #expect(first.done == 3, "setup: the 3 photos did not reach done: \(first.why(helper))")
                guard first.done == 3 else { return }
                hDrain(helper)

                world.lock(world.pics)
                helper.send(line)
                let changed = hWait(helper, for: "changed", cap: 30)
                #expect(changed.found, "no `changed` event after a folders line over an unreadable root; stderr: \(helper.errors)")
                hDrain(helper)
                let rows = hRows(world)
                #expect(hKeys(rows) == wanted, "an unreadable root must keep all its rows, got: \(hDescribe(rows))")
            }
            // A fresh helper over the same index, the root still unreadable.
            let fresh = try hStartHelper(world)
            defer { fresh.stop() }
            fresh.send(line)
            let walked = hWait(fresh, for: "walked")
            #expect(walked.found, "a fresh helper sent no `walked` over an unreadable root; events \(walked.events), stderr: \(fresh.errors)")
            hDrain(fresh)
            let rows = hRows(world)
            #expect(hKeys(rows) == wanted,
                    "after the fresh helper's walk of an unreadable root the rows must still be all 3, got: \(hDescribe(rows))")
        }
    }

    // F1 (d), a guard that holds today: a root that does not exist loses its rows (design section 14, Q4, the unplugged drive).
    @Test func aRootThatDoesNotExistAnyMoreLosesAllItsRows() throws {
        try hWithWorld { world in
            try hMakePhotos(in: world.pics, ["a", "b", "c"])
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            let line = hFoldersLine([world.pics])
            helper.send(line)
            let first = hWaitDone(world, helper, total: 3)
            #expect(first.done == 3, "setup: the 3 photos did not reach done: \(first.why(helper))")
            guard first.done == 3 else { return }
            hDrain(helper)

            try FileManager.default.moveItem(at: world.pics, to: world.root.appendingPathComponent("pics-unplugged"))
            helper.send(line)
            let changed = hWait(helper, for: "changed", cap: 30)
            #expect(changed.found, "no `changed` event after a folders line over a missing root; stderr: \(helper.errors)")
            hDrain(helper)
            let rows = hRows(world)
            #expect(rows?.isEmpty == true, "a root that no longer exists must lose its rows, got: \(hDescribe(rows))")
        }
    }
}
}

// MARK: F2, a photo the process cannot open

extension EncodeHelperTests.HelperUnreadableTests {
@Suite("HelperUnopenablePhotoTests", .serialized)
struct HelperUnopenablePhotoTests {

    // F2 (a), plan-2-t2: three readable photos and one mode-000 photo. The three end `done`; the 000 photo ends
    // `needs_permission` (not `pending`, not `could_not_read`) with `tries` 0 and no passages; nothing is read again in
    // that run (the helper is idle, the row does not change); the helper still exits 0 at stdin end and leaves the row
    // as it was (a clean stop spends no try).
    @Test func aPhotoTheProcessCannotOpenEndsNeedsPermissionWithNoTryAndNoPassagesIsNotRereadAndTheHelperStillExitsAtStdinEnd() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            let photos = try hMakePhotos(in: world.pics, ["a", "locked", "c", "d"])
            world.lock(photos[1])
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            helper.send(hFoldersLine([world.pics]))

            let wait = hWaitDone(world, helper, total: 3, stall: 30)
            #expect(wait.done == 3, "the 3 openable photos did not reach done: \(wait.why(helper))")
            guard wait.done == 3 else { return }
            let settled = hWaitStatuses(world, helper, cap: 30) { ($0["needs_permission"] ?? 0) == 1 }
            let rows = hRows(world)
            #expect(rows?["locked.jpg"]?.status == "needs_permission",
                    "a photo the process may not open must end needs_permission (not pending, not could_not_read); got: \(hDescribe(rows)); statuses \(settled)")
            #expect(settled == ["done": 3, "needs_permission": 1],
                    "statuses should be exactly 3 done and 1 needs_permission (nothing pending, nothing could_not_read), got \(settled)")
            #expect(hFileColumn(world, "locked.jpg", "tries") == "0",
                    "needs_permission is not an attempt that failed: tries should be 0, got \(hFileColumn(world, "locked.jpg", "tries") ?? "no row")")
            #expect(hPassageCount(world, "locked.jpg") == 0,
                    "a photo that was never opened has no passages, got \(hPassageCount(world, "locked.jpg").map(String.init) ?? "unreadable")")

            // Nothing is read again in this run: the helper is idle and the row does not change.
            if let before = hCPUSeconds(pid: helper.pid) {
                Thread.sleep(forTimeInterval: 3)
                let after = hCPUSeconds(pid: helper.pid) ?? before
                #expect(after - before < 1.0,
                        "the helper used \(after - before) s of CPU in 3 idle seconds: it is reading the locked photo again")
            } else {
                Issue.record("could not read the helper's CPU time")
            }
            #expect(helper.isRunning, "the helper exited while a photo needed permission; stderr: \(helper.errors)")
            #expect(hFileColumn(world, "locked.jpg", "status") == "needs_permission", "the row changed while the helper was idle")
            #expect(hFileColumn(world, "locked.jpg", "tries") == "0", "an idle helper spent a try on the locked photo")

            // The helper exits at stdin end, and the row is still as it was.
            let status = hCleanStop(helper)
            #expect(status == 0, "the helper did not exit 0 within 60 s of its stdin ending (status \(status.map(String.init) ?? "still running")); stderr: \(helper.errors)")
            #expect(hFileColumn(world, "locked.jpg", "status") == "needs_permission", "the clean stop changed the row")
            #expect(hFileColumn(world, "locked.jpg", "tries") == "0", "the clean stop left an attempt marker on the row")
        }
    }

    // F2 (a2), plan-2-t2: the mode comes back and a second helper run over the same index retries the file once, at its
    // first `folders` line (`IndexStore.retryNeedsPermission()`), and it ends `done` with its passages and `tries` 0.
    @Test func aSecondHelperRunAfterTheModeIsRestoredRetriesTheFileAndItEndsDone() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            let photos = try hMakePhotos(in: world.pics, ["a", "locked", "c", "d"])
            world.lock(photos[1])
            let line = hFoldersLine([world.pics])
            do {
                let first = try hStartHelper(world)
                defer { first.stop() }
                first.send(line)
                let wait = hWaitDone(world, first, total: 3, stall: 30)
                #expect(wait.done == 3, "setup: the 3 openable photos did not reach done: \(wait.why(first))")
                guard wait.done == 3 else { return }
                let settled = hWaitStatuses(world, first, cap: 30) { ($0["needs_permission"] ?? 0) == 1 }
                #expect(settled["needs_permission"] == 1, "setup: the locked photo did not reach needs_permission, statuses \(settled)")
                guard settled["needs_permission"] == 1 else { return }
                #expect(hCleanStop(first) == 0, "setup: the first helper did not exit 0 at stdin end; stderr: \(first.errors)")
            }

            world.unlockAll()
            let again = try hStartHelper(world)
            defer { again.stop() }
            again.send(line)
            let wait = hWaitDone(world, again, total: 4, stall: 30)
            #expect(wait.done == 4, "after the permission came back and a new helper ran, the photo must become done: \(wait.why(again))")
            let rows = hRows(world)
            #expect(rows?["locked.jpg"]?.status == "done", "locked.jpg should be done, got: \(hDescribe(rows))")
            #expect(hFileColumn(world, "locked.jpg", "tries") == "0", "tries should be 0 once it is done")
            #expect((hPassageCount(world, "locked.jpg") ?? 0) > 0, "a done photo has passages, got \(hPassageCount(world, "locked.jpg").map(String.init) ?? "unreadable")")
            let statuses = hWaitStatuses(world, again, cap: 5) { _ in true }
            #expect(statuses == ["done": 4], "no row should be left in another status, got \(statuses)")
        }
    }

    // F2 (a3), plan-2-t2: a second helper run while the mode is still 000 does not leave the row stuck in `pending` or
    // turn it into `could_not_read`: it ends `needs_permission` again, tries 0, with the other three untouched.
    @Test func aSecondHelperRunWhileTheModeIsStillLockedEndsNeedsPermissionAgainWithNoTry() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            let photos = try hMakePhotos(in: world.pics, ["a", "locked", "c", "d"])
            world.lock(photos[1])
            let line = hFoldersLine([world.pics])
            do {
                let first = try hStartHelper(world)
                defer { first.stop() }
                first.send(line)
                let wait = hWaitDone(world, first, total: 3, stall: 30)
                guard wait.done == 3 else {
                    Issue.record("setup: the 3 openable photos did not reach done: \(wait.why(first))")
                    return
                }
                _ = hWaitStatuses(world, first, cap: 30) { ($0["needs_permission"] ?? 0) == 1 }
                #expect(hCleanStop(first) == 0, "setup: the first helper did not exit 0 at stdin end; stderr: \(first.errors)")
            }

            let again = try hStartHelper(world)
            defer { again.stop() }
            again.send(line)
            _ = hWait(again, for: "walked")
            let statuses = hWaitStatuses(world, again, cap: 30) { $0 == ["done": 3, "needs_permission": 1] }
            Thread.sleep(forTimeInterval: 3)
            let after = hWaitStatuses(world, again, cap: 5) { _ in true }
            #expect(statuses == ["done": 3, "needs_permission": 1], "after the second run over a locked photo, statuses are \(statuses)")
            #expect(after == ["done": 3, "needs_permission": 1], "3 s later the statuses are \(after)")
            #expect(hFileColumn(world, "locked.jpg", "tries") == "0", "the retry spent a try")
            #expect(hPassageCount(world, "locked.jpg") == 0, "a photo that is still locked has no passages")
        }
    }

    // F2 (a4), plan-2-t2: a file that CHANGED (new size, or the same bytes with a new modified time) is reset by the
    // reconcile like any changed file, even in the same helper run in which it became `needs_permission`. A file that
    // only had its mode restored, with nothing else changed, waits for the next helper run (the retry is once, at the
    // first `folders` line).
    @Test func aNeedsPermissionFileThatChangedIsResetByTheReconcileAndOneThatOnlyGotItsModeBackWaitsForTheNextRun() throws {
        try hWithWorld { world in
            guard hCanTestPermissions() else { return }
            let photos = try hMakePhotos(in: world.pics, ["a", "sized", "timed", "same"])
            let sized = photos[1], timed = photos[2], same = photos[3]
            world.lock(sized)
            world.lock(timed)
            world.lock(same)
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            let line = hFoldersLine([world.pics])
            helper.send(line)
            let wait = hWaitDone(world, helper, total: 1, stall: 30)
            #expect(wait.done == 1, "setup: the readable photo did not reach done: \(wait.why(helper))")
            guard wait.done == 1 else { return }
            let settled = hWaitStatuses(world, helper, cap: 30) { ($0["needs_permission"] ?? 0) == 3 }
            #expect(settled == ["done": 1, "needs_permission": 3], "setup: statuses are \(settled)")
            guard settled == ["done": 1, "needs_permission": 3] else { return }
            hDrain(helper)

            world.unlockAll()
            let bigger = hNoiseJPEG(seed: 99, side: 96)
            try bigger.write(to: sized)                       // same file, new size, in place
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: hPast - 777)],
                                                  ofItemAtPath: timed.path)   // same bytes, new modified time
            _ = same                                          // only its mode is back
            helper.send(line)
            let changed = hWait(helper, for: "changed", cap: 30)
            #expect(changed.found, "no `changed` event after the second folders line; stderr: \(helper.errors)")
            let after = hWaitStatuses(world, helper, cap: 60) { ($0["done"] ?? 0) == 3 }
            hDrain(helper)
            let rows = hRows(world)
            #expect(rows?["sized.jpg"]?.status == "done", "the file with a new size should be reset and read, got: \(hDescribe(rows))")
            #expect(rows?["timed.jpg"]?.status == "done", "the file with a new modified time should be reset and read, got: \(hDescribe(rows))")
            #expect(rows?["same.jpg"]?.status == "needs_permission",
                    "a file that only got its mode back is retried by the next helper run, not by a later folders line; got: \(hDescribe(rows)); statuses \(after)")
            #expect(hFileColumn(world, "sized.jpg", "size") == String(bigger.count), "the row should hold the new size")
        }
    }

    // F2 (b), a guard that holds today: bytes that read fine but are not an image are could_not_read, reason damaged.
    @Test func aJpgWhoseBytesAreReadableButNotAnImageBecomesCouldNotReadDamaged() throws {
        try hWithWorld { world in
            try hMakePhotos(in: world.pics, ["a", "b", "c"])
            let broken = world.pics.appendingPathComponent("broken.jpg")
            try Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }).write(to: broken)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: hPast - 100)],
                                                  ofItemAtPath: broken.path)
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            helper.send(hFoldersLine([world.pics]))
            let wait = hWaitDone(world, helper, total: 3)
            #expect(wait.done == 3, "the 3 good photos did not reach done: \(wait.why(helper))")
            Thread.sleep(forTimeInterval: 2)
            let rows = hRows(world)
            #expect(rows?["broken.jpg"]?.status == "could_not_read", "got: \(hDescribe(rows))")
            #expect(rows?["broken.jpg"]?.reason == "damaged", "reason should be damaged, got: \(hDescribe(rows))")
        }
    }

    // F2 (c), a guard that holds today: a file that vanished between the walk and the read stays pending, and the
    // next walk removes the row. The oldest of 40 photos is deleted right after `walked`, long before it is read
    // (photos are read newest first, a photo takes tens of milliseconds).
    @Test func aPhotoThatVanishedBetweenTheWalkAndTheReadStaysPendingAndTheNextWalkRemovesIt() throws {
        try hWithWorld { world in
            let names = (1...40).map { String(format: "p%02d", $0) }
            let photos = try hMakePhotos(in: world.pics, names)
            let oldest = try #require(photos.last)
            let helper = try hStartHelper(world)
            defer { helper.stop() }
            let line = hFoldersLine([world.pics])
            helper.send(line)
            let walked = hWait(helper, for: "walked")
            #expect(walked.found, "no `walked` event; stderr: \(helper.errors)")
            guard walked.found else { return }
            try FileManager.default.removeItem(at: oldest)

            let wait = hWaitDone(world, helper, total: 39, stall: 30)
            #expect(wait.done == 39, "the 39 remaining photos did not reach done: \(wait.why(helper))")
            Thread.sleep(forTimeInterval: 2)
            let rows = hRows(world)
            #expect(rows?["p40.jpg"]?.status == "pending",
                    "a vanished file must stay pending (not could_not_read, not done), got p40: \(rows?["p40.jpg"]?.status ?? "no row")")

            hDrain(helper)
            helper.send(line)
            let changed = hWait(helper, for: "changed", cap: 30)
            #expect(changed.found, "no `changed` event after the next folders line; stderr: \(helper.errors)")
            hDrain(helper)
            let after = hRows(world)
            #expect(after?["p40.jpg"] == nil, "the next walk must remove the row of the vanished file")
            #expect(after?.count == 39, "expected 39 rows after the next walk, got \(after?.count ?? -1)")
        }
    }
}
}

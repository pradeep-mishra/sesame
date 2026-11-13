import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-2-t33, tester step (carry-over F8). Written from the t33 entry, design sections 1, 3 and 9 and the Helper
// protocol table only; no product source read. This file also holds the harness that IndexCleanStopTests.swift and
// IndexKillLoopTests.swift use (the `At...` names below are internal to the test target on purpose).
//
// What the entry fixes (the expected values; none comes from the code under test):
// - `IndexStore.beginAttempt` adds 1 to `files.tries` for every file of a unit, all in ONE committed transaction, before
//   the files are read. `completePhoto` and `markCouldNotRead` set `tries` back to 0 in the SAME transaction as their
//   write. "One transaction" is observed from outside: a second read-only connection polls while the store works, and
//   every snapshot it sees must be a whole state (all of the unit marked or none; never `done` or `could_not_read` or a
//   stored passage on a row whose `tries` is still above 0).
// - The helper's queue reads a file whose `tries` is 0 or 1 (a 1 is "once more"); a file whose `tries` is 2 becomes
//   `could_not_read` with reason "damaged", or "needed too much memory" when the row's `reason` holds `hint:memory`; a
//   `pending` row holding `hint:solo` is read alone before any other work. Those rules live in the helper, so they are
//   observed through the built helper (the bundled release one, `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME), after the
//   test has put a row into the state under test with its own SQL write while NO helper has the index open. The row
//   states are written with the design's column names only (`files.status`, `files.reason`, `files.tries`).
//   "Read again" is observed from the passage ids: a passage id is never reused, so a file that was read again has new
//   ids and a file that was not has the ids it had. "Before any other work" is the order of the new passage ids.
//
// SHAPES THESE TESTS PIN (the entry gives the names only; if a shape is wrong, ask for a test change):
//   `func beginAttempt(_ files: [IndexStore.PendingPhoto]) throws`   the rows as `pendingPhotos(limit:)` returned them;
//        a returned value is ignored. An empty list changes nothing and does not throw.
//   `completePhoto(_:nameWords:ocrText:vector:)` and `markCouldNotRead(_:reason:)` keep the shapes plan 1 and plan 2 gave.
//   After the queue turns a `tries` 2 file into `could_not_read`, its `tries` is 0 (markCouldNotRead sets it to 0).

// MARK: raw SQLite, independent of the product

final class AtDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close_v2(db) }

    /// Every row as text (nil for NULL), or nil when the statement cannot run.
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

    func int(_ sql: String) -> Int? {
        guard let result = rows(sql), let row = result.first, let cell = row.first, let text = cell else { return nil }
        return Int(text)
    }

    func integrity() -> String {
        guard let result = rows("pragma integrity_check") else { return "integrity_check could not run" }
        return result.compactMap { $0.first ?? nil }.joined(separator: " | ")
    }
}

/// The test's own setup write, used only while no helper and no store has the index open. Returns an error text, or nil.
func atWrite(_ path: String, _ sql: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
        sqlite3_close_v2(db)
        return "cannot open \(path) for the test's own setup write: \(message)"
    }
    defer { sqlite3_close_v2(db) }
    sqlite3_busy_timeout(db, 5000)
    var failure: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &failure) == SQLITE_OK else {
        let message = failure.map { String(cString: $0) } ?? "unknown error"
        sqlite3_free(failure)
        return "setup write failed (\(sql)): \(message)"
    }
    return nil
}

struct AtRow {
    let name: String
    let status: String
    let reason: String?
    let tries: Int
}

/// Every `files` row by file name (the last path component), or nil when the index cannot be read.
func atRows(_ db: AtDB) -> [String: AtRow]? {
    guard let rows = db.rows("select path, status, reason, tries from files") else { return nil }
    var out: [String: AtRow] = [:]
    for row in rows {
        guard let path = row[0], let status = row[1] else { continue }
        let name = (path as NSString).lastPathComponent
        out[name] = AtRow(name: name, status: status, reason: row[2], tries: Int(row[3] ?? "") ?? -1)
    }
    return out
}

/// The passage ids of every file by file name, ascending.
func atPassageIDs(_ db: AtDB) -> [String: [Int]]? {
    guard let rows = db.rows("select f.path, p.id from files f join passages p on p.file_id = f.id order by p.id") else { return nil }
    var out: [String: [Int]] = [:]
    for row in rows {
        guard let path = row[0], let text = row[1], let id = Int(text) else { continue }
        out[(path as NSString).lastPathComponent, default: []].append(id)
    }
    return out
}

func atDescribe(_ rows: [String: AtRow]?) -> String {
    guard let rows else { return "index unreadable" }
    return rows.keys.sorted().map { key in
        let row = rows[key]!
        return "\(key)=\(row.status)\(row.reason.map { "(\($0))" } ?? "") tries \(row.tries)"
    }.joined(separator: ", ")
}

/// What is wrong with the index as a whole: a file's passages are all there or not there at all (a `name` and an
/// `image` passage or none), a `done` file has them, every passage has its `fts` row and no `fts` row is left over,
/// `tries` is 0, 1 or 2, and `integrity_check` says `ok`. Empty means whole. This is "all-new or all-old" in design
/// section 9.1: a half-replaced file would show one passage, or four.
func atWholeProblems(_ db: AtDB) -> [String] {
    var problems: [String] = []
    guard let files = db.rows("""
        select f.path, f.status, f.tries, count(p.id), coalesce(sum(p.source = 'name'), 0), coalesce(sum(p.source = 'image'), 0) \
        from files f left join passages p on p.file_id = f.id group by f.id
        """) else { return ["the files and passages tables cannot be read"] }
    for row in files {
        let name = ((row[0] ?? "") as NSString).lastPathComponent
        let status = row[1] ?? "nil"
        let tries = Int(row[2] ?? "") ?? -1
        let all = Int(row[3] ?? "") ?? -1, names = Int(row[4] ?? "") ?? -1, images = Int(row[5] ?? "") ?? -1
        if !(0...2).contains(tries) { problems.append("\(name): tries \(tries), expected 0, 1 or 2") }
        if all != 0 && !(all == 2 && names == 1 && images == 1) {
            problems.append("\(name): \(all) passages (\(names) name, \(images) image), expected none or one name and one image")
        }
        if status == "done" && all != 2 { problems.append("\(name): done with \(all) passages, expected 2") }
    }
    let lost = db.int("select count(*) from passages where id not in (select rowid from fts)") ?? -1
    if lost != 0 { problems.append("\(lost) passages have no fts row") }
    let left = db.int("select count(*) from fts where rowid not in (select id from passages)") ?? -1
    if left != 0 { problems.append("\(left) fts rows belong to no passage") }
    let integrity = db.integrity()
    if integrity != "ok" { problems.append("integrity_check: \(integrity)") }
    return problems
}

// MARK: drawing the photos

private func atNoise(seed: Int, side: Int) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    var state = UInt64(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12_345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 41)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 49)
        pixels[index + 3] = 255
    }
    return pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
}

private func atJPEG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

let atPast = Date().timeIntervalSince1970.rounded(.down) - 3600

/// `<folder>/<name>.jpg` for each name: noise pixels, a distinct picture per seed, an hour or more in the past. The
/// first name is the newest (the helper reads newest first); `age` makes the whole set that many seconds older.
@discardableResult
func atMakePhotos(in folder: URL, names: [String], seedBase: Int, age: Int = 0) throws -> [URL] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var made: [URL] = []
    for (index, name) in names.enumerated() {
        let url = folder.appendingPathComponent(name + ".jpg")
        guard let image = atNoise(seed: seedBase + index + 1, side: 96), let data = atJPEG(image) else {
            throw AtError("the test could not draw \(name)")
        }
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(age + index))],
                                              ofItemAtPath: url.path)
        made.append(url)
    }
    return made
}

/// `<prefix>-001` to `<prefix>-040` and so on: letters, digits and a dash only, so a SQL LIKE on the name is exact.
func atNames(_ prefix: String, _ range: ClosedRange<Int>) -> [String] {
    range.map { String(format: "%@-%03d", prefix, $0) }
}

struct AtError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: the throwaway world and the helper

final class AtWorld {
    let root: URL
    let home: URL
    let photos: URL
    private var locked: [(path: String, mode: mode_t)] = []

    var support: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var indexFile: String { support.appendingPathComponent("index.sqlite").path }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sesame-t33-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        photos = root.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        // The app makes this folder (mode 0700) before it ever starts a helper.
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func db() -> AtDB? { AtDB(path: indexFile) }

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

/// The bundled release helper (`dist/Sesame.app/Contents/MacOS/SesameHelper`), started the way the app starts it:
/// `SesameHelper index`, `SESAME_FAKE_EMBEDDER=1`, `HOME` at the throwaway folder. The Run builds release and bundles
/// just before these tests (a stale bundle makes them fail, never pass).
func atStartHelper(_ world: AtWorld) throws -> HelperProcess {
    let executable = KitPaths.bundledHelper
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw AtError("the bundled helper is missing: \(executable.path) (run scripts/bundle.sh)")
    }
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

private func atJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

/// The hand-written `folders` line of the Helper protocol table: the whole list, `code` false.
func atFoldersLine(_ folders: [URL]) -> String {
    let items = folders.map { "{\"path\":\(atJSONString($0.path)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private func atTextImage() -> CGImage? {
    let width = 600, height = 200
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: 20, y: 60)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "WARM UP 0123", attributes: attributes)), context)
    return context.makeImage()
}

/// The first text recognition in a freshly signed helper binary compiles its model (about 35 s measured). Once per test
/// process, one photo with text goes through a real helper first, with up to 120 s allowed (cap 150 s); the tests' own
/// stall limits then start from a warm binary. Nothing is asserted: a helper that never warms makes the real test fail
/// with its own message.
let atHelperWarm: Bool = {
    guard let world = try? AtWorld(), let image = atTextImage(), let data = atJPEG(image) else { return false }
    defer { world.remove() }
    let photo = world.photos.appendingPathComponent("warm-up.jpg")
    guard (try? data.write(to: photo)) != nil,
          (try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast)],
                                                  ofItemAtPath: photo.path)) != nil,
          let helper = try? atStartHelper(world) else { return false }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    return atWaitStatuses(world, helper, stall: 120, cap: 150, until: { ($0["done"] ?? 0) >= 1 }).met
}()

// MARK: reading the helper's events and the index, from outside

/// Counts what the helper says. `read` pulls lines until `stop()` holds, the output ends or `cap` seconds pass.
final class AtEvents {
    let helper: HelperProcess
    private(set) var changed = 0
    private(set) var walked = false

    init(_ helper: HelperProcess) { self.helper = helper }

    @discardableResult
    func read(cap: TimeInterval, until stop: () -> Bool) -> Bool {
        if stop() { return true }
        let deadline = Date().addingTimeInterval(cap)
        while Date() < deadline {
            guard let line = helper.nextLine(timeout: min(2, max(0.05, deadline.timeIntervalSinceNow))) else {
                if helper.isRunning { continue }
                return stop()
            }
            guard let reply = HelperReply(line.text), let event = reply.event else { continue }
            if event == "changed" { changed += 1 }
            if event == "walked" { walked = true }
            if stop() { return true }
        }
        return false
    }
}

struct AtWait {
    let statuses: [String: Int]
    let met: Bool
    let seconds: Double
}

/// Polls `select status, count(*) from files group by status` (a read-only connection) until `until` holds, until the
/// counts have not changed for `stall` seconds, until `cap` seconds in all, or until the helper is gone.
func atWaitStatuses(_ world: AtWorld, _ helper: HelperProcess, stall: TimeInterval = 60, cap: TimeInterval = 240,
                    until: ([String: Int]) -> Bool) -> AtWait {
    let started = Date()
    var lastChange = started
    var last: [String: Int] = [:]
    var db: AtDB?
    var met = false
    while true {
        if db == nil { db = world.db() }
        if let rows = db?.rows("select status, count(*) from files group by status") {
            var found: [String: Int] = [:]
            for row in rows { if let status = row[0], let text = row[1], let n = Int(text) { found[status] = n } }
            if found != last { last = found; lastChange = Date() }
            if until(found) { met = true; break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > stall || now.timeIntervalSince(started) > cap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return AtWait(statuses: last, met: met, seconds: Date().timeIntervalSince(started))
}

/// Ends the helper's stdin and returns its exit status, or nil when it has not exited within `timeout` seconds.
func atCleanStop(_ helper: HelperProcess, timeout: TimeInterval = 120) -> Int32? {
    helper.closeStdin()
    return helper.waitForExit(timeout: timeout)?.status
}

/// SIGKILL, then waits for the process to be gone.
func atKill(_ helper: HelperProcess) {
    kill(helper.pid, SIGKILL)
    _ = helper.waitForExit(timeout: 30)
}

/// A world whose helper has indexed every named photo (all `done`) and has been stopped cleanly, so the test may write
/// a row's state itself with no helper holding the index.
func atIndexedWorld(_ names: [String], seedBase: Int = 0) throws -> AtWorld {
    _ = atHelperWarm
    let world = try AtWorld()
    do {
        try atMakePhotos(in: world.photos, names: names, seedBase: seedBase)
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, until: { $0 == ["done": names.count] })
        guard wait.met else {
            throw AtError("setup: the \(names.count) photos did not all reach done: \(wait.statuses), stderr: \(helper.errors)")
        }
        guard atCleanStop(helper) == 0 else {
            throw AtError("setup: the helper did not exit 0 within 120 s of its stdin ending; stderr: \(helper.errors)")
        }
    } catch {
        world.remove()
        throw error
    }
    return world
}

// MARK: seeded jitter

struct AtRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The seed of a run: the number in the environment variable `T33_SEED` when it is set (to replay a printed seed),
/// else the clock. The caller prints it.
func atSeed() -> UInt64 {
    if let text = ProcessInfo.processInfo.environment["T33_SEED"], let value = UInt64(text) { return value }
    return UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF
}

// MARK: a second connection that watches while the store works

/// Polls one query on its own read-only connection as fast as it can and hands each result to `check`; a non-nil answer
/// is a problem (the first five are kept). It sees only committed states, so a problem is a half-done transaction.
final class AtPoller: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var count = 0
    private var bad: [String] = []
    private let finished = DispatchSemaphore(value: 0)

    func start(path: String, sql: String, check: @escaping @Sendable ([[String?]]) -> String?) {
        Thread.detachNewThread { [self] in
            var db: AtDB?
            while true {
                lock.lock(); let stop = stopped; lock.unlock()
                if stop { break }
                if db == nil { db = AtDB(path: path) }
                guard let rows = db?.rows(sql) else { Thread.sleep(forTimeInterval: 0.001); continue }
                let problem = check(rows)
                lock.lock()
                count += 1
                if let problem, bad.count < 5 { bad.append(problem) }
                lock.unlock()
            }
            finished.signal()
        }
    }

    func stop() -> (snapshots: Int, problems: [String]) {
        lock.lock(); stopped = true; lock.unlock()
        finished.wait()
        lock.lock(); defer { lock.unlock() }
        return (count, bad)
    }
}

// MARK: the suite

private let atDevice: Int64 = 16_777_220

private func atVector(_ phase: Double) -> [Float] {
    (0..<768).map { Float(sin(Double($0) * 0.37 + phase) * 0.9) }
}

private func atIndexPath(_ t: TempHome) -> String {
    t.folder.appendingPathComponent("index.sqlite").path
}

/// The rows the store wrote, by file name, read with the test's own connection.
private func atStoreRows(_ t: TempHome) -> [String: AtRow] {
    guard let db = AtDB(path: atIndexPath(t)), let rows = atRows(db) else { return [:] }
    return rows
}

private func atAddPending(_ store: IndexStore, count: Int, prefix: String = "at") throws {
    for number in 1...count {
        _ = try store.addFile(path: "/photos/\(prefix)-\(String(format: "%04d", number)).jpg", kind: "photo",
                              size: Int64(1000 + number), mtimeNs: 1_700_000_000_000_000_000 + Int64(number) * 1_000_000_000,
                              inode: Int64(9000 + number), device: atDevice, status: "pending")
    }
}

private func atPhoto(_ photos: [IndexStore.PendingPhoto], _ name: String) throws -> IndexStore.PendingPhoto {
    try #require(photos.first { ($0.path as NSString).lastPathComponent == name + ".jpg" },
                 "pendingPhotos does not list \(name).jpg")
}

extension EncodeHelperTests {
@Suite("IndexAttemptTests", .serialized)
struct IndexAttemptTests {

    // MARK: beginAttempt, at the store

    @Test func beginAttemptAddsOneToTriesOfEachFileOfTheUnitAndOnlyThose() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try atAddPending(store, count: 4)
            let photos = try store.pendingPhotos(limit: 50)
            let one = try atPhoto(photos, "at-0001"), two = try atPhoto(photos, "at-0002"), three = try atPhoto(photos, "at-0003")

            #expect(atStoreRows(t).values.allSatisfy { $0.tries == 0 }, "setup: a new row starts with tries 0, got \(atDescribe(atStoreRows(t)))")

            try store.beginAttempt([one, two, three])
            var rows = atStoreRows(t)
            #expect(rows.mapValues(\.tries) == ["at-0001.jpg": 1, "at-0002.jpg": 1, "at-0003.jpg": 1, "at-0004.jpg": 0],
                    "after beginAttempt of three files: \(atDescribe(rows))")
            #expect(rows.values.allSatisfy { $0.status == "pending" && $0.reason == nil },
                    "beginAttempt must change only tries; rows are \(atDescribe(rows))")

            // A second attempt on the same file (it died, the helper came back) adds one more, for that file only.
            try store.beginAttempt([one])
            rows = atStoreRows(t)
            #expect(rows.mapValues(\.tries) == ["at-0001.jpg": 2, "at-0002.jpg": 1, "at-0003.jpg": 1, "at-0004.jpg": 0],
                    "after a second beginAttempt of one file: \(atDescribe(rows))")

            // An empty unit marks nothing and is not an error.
            try store.beginAttempt([])
            #expect(atStoreRows(t).mapValues(\.tries) == rows.mapValues(\.tries), "an empty unit changed a row")
            let passages = AtDB(path: atIndexPath(t))?.int("select count(*) from passages")
            #expect(passages == 0, "beginAttempt writes no passage, got \(passages.map(String.init) ?? "unreadable")")
        }
    }

    @Test func theWholeUnitIsMarkedInOneCommittedTransaction() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let total = 400
            try atAddPending(store, count: total)
            let photos = try store.pendingPhotos(limit: total + 10)
            #expect(photos.count == total, "setup: pendingPhotos(limit: \(total + 10)) listed \(photos.count) of \(total)")
            guard photos.count == total else { return }

            // A second connection polls while beginAttempt runs. Marking file by file would show it a state with some
            // of the 400 marked and the rest not; one transaction shows it none or all.
            let poller = AtPoller()
            poller.start(path: atIndexPath(t), sql: "select coalesce(sum(tries = 1), 0), count(*) from files") { rows in
                guard let row = rows.first, let ones = Int(row[0] ?? ""), let all = Int(row[1] ?? "") else { return "unreadable" }
                return (ones == 0 || ones == all) ? nil : "a snapshot with \(ones) of \(all) files marked"
            }
            Thread.sleep(forTimeInterval: 0.05)
            try store.beginAttempt(photos)
            Thread.sleep(forTimeInterval: 0.15)
            let seen = poller.stop()
            #expect(seen.problems.isEmpty, "beginAttempt is not one transaction: \(seen.problems)")
            #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
            let marked = AtDB(path: atIndexPath(t))?.int("select count(*) from files where tries = 1")
            #expect(marked == total, "after beginAttempt \(marked.map(String.init) ?? "?") of \(total) files have tries 1")
        }
    }

    // MARK: completePhoto and markCouldNotRead put the marker back with their own write

    @Test func completePhotoSetsTriesBackToZeroWithItsWrite() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            try atAddPending(store, count: 3)
            let photos = try store.pendingPhotos(limit: 50)
            let one = try atPhoto(photos, "at-0001"), two = try atPhoto(photos, "at-0002")

            try store.beginAttempt([one, two])
            try store.beginAttempt([two])   // two has now died once and is being read again: tries 2
            #expect(atStoreRows(t)["at-0002.jpg"]?.tries == 2, "setup: tries after two attempts is \(atStoreRows(t)["at-0002.jpg"]?.tries ?? -1)")

            #expect(try store.completePhoto(one, nameWords: "beach holiday", ocrText: "", vector: atVector(0.2)), "completePhoto of at-0001 changed nothing")
            #expect(try store.completePhoto(two, nameWords: "invoice scan", ocrText: "", vector: atVector(1.1)), "completePhoto of at-0002 changed nothing")

            let rows = atStoreRows(t)
            #expect(rows["at-0001.jpg"]?.status == "done" && rows["at-0001.jpg"]?.tries == 0, "at-0001 after completePhoto: \(atDescribe(rows))")
            #expect(rows["at-0002.jpg"]?.status == "done" && rows["at-0002.jpg"]?.tries == 0, "at-0002 (tries 2) after completePhoto: \(atDescribe(rows))")
            #expect(rows["at-0003.jpg"]?.status == "pending" && rows["at-0003.jpg"]?.tries == 0, "the untouched file changed: \(atDescribe(rows))")
            let passages = AtDB(path: atIndexPath(t))?.int("select count(*) from passages")
            #expect(passages == 4, "two photos, a name and an image passage each, got \(passages.map(String.init) ?? "unreadable")")
        }
    }

    @Test func completePhotoWritesAndClearsTheMarkerInOneTransaction() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let total = 150
            try atAddPending(store, count: total)
            let photos = try store.pendingPhotos(limit: total + 10)
            #expect(photos.count == total, "setup: pendingPhotos listed \(photos.count) of \(total)")
            guard photos.count == total else { return }

            // The marker is real before the loop relies on it (without this the polling below could not see a violation).
            try store.beginAttempt([photos[0]])
            #expect(atStoreRows(t).values.filter { $0.tries == 1 }.count == 1,
                    "setup: beginAttempt of one file should leave exactly one row with tries 1, got \(atDescribe(atStoreRows(t)).prefix(300))")

            // Never a committed state in which the row is done, or holds passages, and still carries a marker.
            let poller = AtPoller()
            poller.start(path: atIndexPath(t), sql: """
                select count(*) from files f where f.tries > 0 and (f.status = 'done' \
                or exists (select 1 from passages p where p.file_id = f.id))
                """) { rows in
                guard let text = rows.first?.first ?? nil, let bad = Int(text) else { return "unreadable" }
                return bad == 0 ? nil : "\(bad) rows are done or hold passages with tries still above 0"
            }
            Thread.sleep(forTimeInterval: 0.05)
            for (index, photo) in photos.enumerated() {
                try store.beginAttempt([photo])
                _ = try store.completePhoto(photo, nameWords: "word\(index)", ocrText: "", vector: atVector(Double(index)))
            }
            Thread.sleep(forTimeInterval: 0.1)
            let seen = poller.stop()
            #expect(seen.problems.isEmpty, "completePhoto does not clear tries in the transaction that writes: \(seen.problems)")
            #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
            let rows = atStoreRows(t)
            #expect(rows.count == total && rows.values.allSatisfy { $0.status == "done" && $0.tries == 0 },
                    "after \(total) attempts and completes some row is not done with tries 0")
        }
    }

    @Test func markCouldNotReadSetsTriesBackToZeroWithItsWrite() throws {
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            defer { store.close() }
            let total = 150
            try atAddPending(store, count: total)
            let photos = try store.pendingPhotos(limit: total + 10)
            #expect(photos.count == total, "setup: pendingPhotos listed \(photos.count) of \(total)")
            guard photos.count == total else { return }

            // The marker is real before the loop relies on it (without this the polling below could not see a violation).
            try store.beginAttempt([photos[0]])
            try store.beginAttempt([photos[0]])
            #expect(atStoreRows(t).values.filter { $0.tries == 2 }.count == 1,
                    "setup: two beginAttempt of one file should leave exactly one row with tries 2, got \(atDescribe(atStoreRows(t)).prefix(300))")

            let poller = AtPoller()
            poller.start(path: atIndexPath(t), sql: "select count(*) from files where tries > 0 and status = 'could_not_read'") { rows in
                guard let text = rows.first?.first ?? nil, let bad = Int(text) else { return "unreadable" }
                return bad == 0 ? nil : "\(bad) rows are could_not_read with tries still above 0"
            }
            Thread.sleep(forTimeInterval: 0.05)
            for photo in photos {
                try store.beginAttempt([photo])
                try store.beginAttempt([photo])
                _ = try store.markCouldNotRead(photo, reason: "damaged")
            }
            Thread.sleep(forTimeInterval: 0.1)
            let seen = poller.stop()
            #expect(seen.problems.isEmpty, "markCouldNotRead does not clear tries in the transaction that writes: \(seen.problems)")
            #expect(seen.snapshots > 0, "the polling connection read nothing, so it proved nothing")
            let rows = atStoreRows(t)
            #expect(rows.count == total && rows.values.allSatisfy { $0.status == "could_not_read" && $0.reason == "damaged" && $0.tries == 0 },
                    "after \(total) attempts and marks some row is not could_not_read damaged with tries 0")
        }
    }

    // MARK: the helper's queue, through the built helper

    // `tries` 0 and 1 are read; 1 is "once more". Each ends done, with tries 0 and passages that are new (it was read).
    @Test func aFileWithTriesZeroOrOneIsReadAndEndsDoneWithTriesZero() throws {
        let names = atNames("q", 1...12)
        let world = try atIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0 where path like '%/q-003.jpg'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 1 where path like '%/q-004.jpg'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, until: { $0 == ["done": 12] })
        #expect(wait.met, "the files with tries 0 and 1 did not both end done: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let rows = atRows(db)
        #expect(rows?.values.allSatisfy { $0.tries == 0 } == true, "every row should end with tries 0: \(atDescribe(rows))")
        let after = try #require(atPassageIDs(db))
        for name in ["q-003.jpg", "q-004.jpg"] {
            #expect(after[name] != nil && after[name] != before[name], "\(name) (tries \(name == "q-003.jpg" ? 0 : 1)) was not read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
        }
        for name in names.map({ $0 + ".jpg" }) where name != "q-003.jpg" && name != "q-004.jpg" {
            #expect(after[name] == before[name], "\(name) was done and was read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
        }
        #expect(atWholeProblems(db).isEmpty, "the index is not whole: \(atWholeProblems(db))")
    }

    // `tries` 2 is not read: the queue turns it into could_not_read. The reason is "damaged", or "needed too much memory"
    // when the row's reason holds `hint:memory`. A neighbour with tries 1 is still read once more.
    @Test func aFileWithTriesTwoBecomesCouldNotReadDamagedOrNeededTooMuchMemoryByItsHintAndIsNeverReadAgain() throws {
        let names = atNames("q", 1...12)
        let world = try atIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2 where path like '%/q-005.jpg'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2, reason = 'hint:memory' where path like '%/q-006.jpg'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 1 where path like '%/q-007.jpg'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, until: { $0 == ["done": 10, "could_not_read": 2] })
        #expect(wait.met, "expected 10 done and 2 could_not_read (the two files with tries 2), got \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        var db = try #require(world.db())
        var rows = atRows(db)
        #expect(rows?["q-005.jpg"]?.status == "could_not_read" && rows?["q-005.jpg"]?.reason == "damaged",
                "tries 2 with no hint must be could_not_read with reason damaged, got \(atDescribe(rows))")
        #expect(rows?["q-006.jpg"]?.status == "could_not_read" && rows?["q-006.jpg"]?.reason == "needed too much memory",
                "tries 2 with hint:memory must be could_not_read with reason needed too much memory, got \(atDescribe(rows))")
        #expect(rows?["q-005.jpg"]?.tries == 0 && rows?["q-006.jpg"]?.tries == 0,
                "a could_not_read row holds tries 0 (markCouldNotRead puts it back), got \(atDescribe(rows))")
        #expect(rows?["q-007.jpg"]?.status == "done" && rows?["q-007.jpg"]?.tries == 0,
                "tries 1 is read once more and ends done with tries 0, got \(atDescribe(rows))")
        var after = try #require(atPassageIDs(db))
        for name in ["q-005.jpg", "q-006.jpg"] {
            #expect(Set(after[name] ?? []).isSubset(of: Set(before[name] ?? [])),
                    "\(name) (tries 2) was read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
        }
        #expect(after["q-007.jpg"] != before["q-007.jpg"], "q-007.jpg (tries 1) was not read again")
        #expect(atWholeProblems(db).isEmpty, "the index is not whole: \(atWholeProblems(db))")

        // The next helper run leaves them as they are: could_not_read stays until the file changes.
        let again = try atStartHelper(world)
        defer { again.stop() }
        again.send(atFoldersLine([world.photos]))
        let events = AtEvents(again)
        events.read(cap: 60, until: { events.walked })
        let second = atWaitStatuses(world, again, stall: 5, cap: 15, until: { _ in false })
        #expect(second.statuses == ["done": 10, "could_not_read": 2], "a second run changed the statuses to \(second.statuses)")
        #expect(atCleanStop(again) == 0, "the second helper did not exit 0 at stdin end; stderr: \(again.errors)")
        db = try #require(world.db())
        rows = atRows(db)
        #expect(rows?["q-005.jpg"]?.reason == "damaged" && rows?["q-006.jpg"]?.reason == "needed too much memory",
                "a second run changed the reasons: \(atDescribe(rows))")
        after = try #require(atPassageIDs(db))
        #expect(after["q-005.jpg"].map { Set($0).isSubset(of: Set(before["q-005.jpg"] ?? [])) } ?? true, "a second run read q-005.jpg")
    }

    // A pending row holding `hint:solo` is read alone before any other work: of 12 pending files, the oldest (the one
    // the queue would reach last) carries the hint, and it must be the first to be written, ahead of all eleven others.
    @Test func aPendingRowHoldingHintSoloIsReadFirstAndAloneBeforeAnyOtherWork() throws {
        let names = atNames("q", 1...12)
        let world = try atIndexedWorld(names)
        defer { world.remove() }
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        #expect(atWrite(world.indexFile, "update files set reason = 'hint:solo' where path like '%/q-012.jpg'") == nil)
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, until: { $0 == ["done": 12] })
        #expect(wait.met, "the twelve pending files did not all end done: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let after = try #require(atPassageIDs(db))
        let newest = before.values.flatMap { $0 }.max() ?? 0
        let first = after.compactMap { (name, ids) -> (String, Int)? in ids.min().map { (name, $0) } }.sorted { $0.1 < $1.1 }
        #expect(first.count == 12 && first.allSatisfy { $0.1 > newest }, "every file should have been read again (new ids above \(newest)): \(first)")
        #expect(first.first?.0 == "q-012.jpg",
                "the file with hint:solo must be written before every other file, but the order of writes is \(first.map(\.0))")
        #expect(atWholeProblems(db).isEmpty, "the index is not whole: \(atWholeProblems(db))")
        #expect(atRows(db)?.values.allSatisfy { $0.tries == 0 && $0.status == "done" } == true, "rows: \(atDescribe(atRows(db)))")
    }
}
}

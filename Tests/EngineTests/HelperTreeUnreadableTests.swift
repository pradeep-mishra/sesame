import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-3-t14, tester step (S8.6 damaged and unsupported photos, S8.5 the unsupported cells): the S8 fixture tree's
// `damaged` and `unsupported` folders, indexed through the bundled release helper alone.
// Written from the t14 entry, `scripts/kit-lib/tree.tsv` (the hand-written file list), the spec's S8.6 and the
// sealed tests of plan 1 and 2 (HelperUnreadableTests, IndexReaderCountsTests, KitIndexReadersTests) for style.
// No product source read; no expected value comes from the code under test.
//
// What happens, in one run shared by every test below (the run is made once per test process):
//   1. `scripts/kit-fixtures.sh build tree` as a child process under a temp KIT_ROOT (`sesame-kit-t14`), a temp TMPDIR
//      and HOME = `$KIT_ROOT/home` (so `kit-index.sh` finds the index there). It needs `ffmpeg`.
//   2. The bundled release helper (`dist/Sesame.app/Contents/MacOS/SesameHelper index`) is started alone with
//      `SESAME_FAKE_EMBEDDER=1`. No app, no window. One warm-up photo goes through a helper first, once per test
//      process, with 120 s allowed, so the first photo's cold start is not mistaken for a stall.
//   3. A `folders` line holds `tree/damaged` and `tree/unsupported`; the test waits (300 s of slack, never a tight
//      bound) until a row exists and no row is `pending`.
//   4. The index is read with this file's own read-only SQLite connection, with `IndexReader().couldNotRead()` (HOME set
//      for that call only) and with `scripts/kit-index.sh reasons` as a child with the same HOME.
//   5. stdin is closed; the helper must exit 0.
//
// Hand-written truth (tree.tsv and the spec, written here by hand; the helper's readers support photos and PDFs so far):
//   damaged/broken.png      a PNG cut to 300 bytes: status could_not_read, reason "damaged"
//   damaged/good.png        done
//   unsupported/ok.png      done
//   damaged/broken.pdf      a PDF cut to 200 bytes: status could_not_read, reason "damaged"      (plan-4-t4)
//   damaged/good.pdf        a one-page PDF: done                                                 (plan-4-t4)
//   every other file of the two folders has NO row: deck.pptx, sheet.xlsx, book.pages, raw.dng, README, ok.txt (in
//   unsupported/), and in damaged/ the documents, audio, video and code (broken.docx, broken.wav, broken.mp4,
//   broken.swift, good.txt, good.wav, good.mp4, good.swift). Those kinds have no reader yet (documents: plan-4-t6).
//
// plan-4-t6, amended by the fresh tester: documents now have a reader, so `damaged/good.txt` is done, `damaged/broken.docx` (plain
// text under a docx name, not a zip) is could_not_read "damaged", and `unsupported/ok.txt` (a txt, not named by the entry but a
// document all the same: the rules give it kind `doc`) is done; the three leave the no-row list. Audio, video and code
// (`broken.wav`, `broken.mp4`, `broken.swift`, `good.wav`, `good.mp4`, `good.swift`) and the unsupported types (`.pptx`, `.xlsx`,
// `.pages`, `.dng`, `README` with no extension) still have no row. Everything the test pins about the could-not-read list follows
// (three files, `broken.png`, `broken.pdf` and `broken.docx`; the kit's `reasons` prints three rows and `could_not_read 3`). Nothing
// is weakened: the five rows of t4, the no-row files that remain and the integrity and exit checks are as before.
//
// plan-4-t4, amended by the fresh tester: PDFs now have a reader, so the two PDFs of `damaged/` get a row (good.pdf done,
// broken.pdf could_not_read "damaged"), they leave the no-row list, and everything the test pins about the could-not-read list
// follows (two files, `broken.png` and `broken.pdf`; the kit's `reasons` prints two rows and `could_not_read 2`). Nothing is
// weakened: the three photo rows, the no-row files and the integrity and exit checks are as before.

// plan-5-t2, amended by the fresh tester: audio now has a reader, so `damaged/good.wav` (a 1 s tone) is done and `damaged/broken.wav`
// (4,096 random bytes under a wav name, tree.tsv) is could_not_read "damaged"; the two leave the no-row list and everything the test pins
// about the could-not-read list follows (four files: `broken.png`, `broken.pdf`, `broken.docx` and `broken.wav`; the kit's `reasons`
// prints four rows and `could_not_read 4`). Video (`broken.mp4`, `good.mp4`) and code (`broken.swift`, `good.swift`) and the unsupported
// types still have no row (video arrives in plan-5-t3). Nothing is weakened: the eight rows of earlier plans, the no-row files that
// remain and the integrity and exit checks are as before.

// plan-5-t3, amended by the fresh tester: video now has a reader, so `damaged/good.mp4` (a real clip, tree.tsv) is done and
// `damaged/broken.mp4` (a cut mp4, tree.tsv) is could_not_read "damaged"; the two leave the no-row list and everything the test pins about
// the could-not-read list follows (five files: `broken.png`, `broken.pdf`, `broken.docx`, `broken.wav` and `broken.mp4`; the kit's `reasons`
// prints five rows and `could_not_read 5`). Only code (`broken.swift`, `good.swift`) and the unsupported types still have no row (code
// arrives in plan 6). Nothing is weakened: the ten rows of earlier plans, the no-row files that remain and the integrity and exit checks
// are as before.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// What the test expects of `damaged/broken.png`.
private let htBrokenPngStatus = "could_not_read"

private let htExpectedRows: [String: String] = [
    "damaged/broken.png": htBrokenPngStatus,
    "damaged/good.png": "done",
    "unsupported/ok.png": "done",
    "damaged/broken.pdf": "could_not_read",
    "damaged/good.pdf": "done",
    "damaged/broken.docx": "could_not_read",
    "damaged/good.txt": "done",
    "unsupported/ok.txt": "done",
    "damaged/broken.wav": "could_not_read",
    "damaged/good.wav": "done",
    "damaged/broken.mp4": "could_not_read",
    "damaged/good.mp4": "done",
]

private let htNoRowFiles: [String] = [
    "unsupported/deck.pptx", "unsupported/sheet.xlsx", "unsupported/book.pages", "unsupported/raw.dng",
    "unsupported/README", "damaged/broken.swift", "damaged/good.swift",
]

// MARK: running a program

private struct HTRan {
    let status: Int32
    let output: String
}

private func htRun(_ exe: String, _ args: [String], env: [String: String], limit: TimeInterval = 900) -> HTRan? {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("httree-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    guard let handle = try? FileHandle(forWritingTo: out) else { return nil }
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(limit)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    var status: Int32
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        status = 124
    } else {
        status = process.terminationStatus
    }
    try? handle.synchronize()
    return HTRan(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

private func htTail(_ text: String, _ lines: Int = 8) -> String {
    text.split(separator: "\n").suffix(lines).joined(separator: " / ")
}

// MARK: raw read-only SQLite, independent of the product

private final class HTDB {
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

    /// Status counts of the `files` table, or nil while the table cannot be read.
    func statuses() -> [String: Int]? {
        guard let result = rows("select status, count(*) from files group by status") else { return nil }
        var out: [String: Int] = [:]
        for row in result {
            if let status = row[0], let text = row[1], let n = Int(text) { out[status] = n }
        }
        return out
    }
}

// MARK: the helper

private func htJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

private func htFoldersLine(_ folders: [String], codeTicked: Set<String> = []) -> String {
    let items = folders.map { "{\"path\":\(htJSONString($0)),\"code\":\(codeTicked.contains($0))}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

/// The bundled release helper in index mode, `HOME` and `SESAME_FAKE_EMBEDDER=1` set for the start only.
private func htStartHelper(home: String) throws -> HelperProcess {
    let executable = KitPaths.bundledHelper
    try #require(FileManager.default.isExecutableFile(atPath: executable.path),
                 "the bundled helper is missing: run `scripts/bundle.sh` (expected \(executable.path))")
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", home, 1)
    setenv("SESAME_FAKE_EMBEDDER", "1", 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    return try HelperProcess(executable: executable, arguments: ["index"])
}

/// Reads events until one named `name` arrives, the helper's output ends, or `cap` seconds pass.
private func htWaitEvent(_ helper: HelperProcess, _ name: String, cap: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(cap)
    while Date() < deadline {
        guard let line = helper.nextLine(timeout: min(5, max(0.1, deadline.timeIntervalSinceNow))) else {
            if helper.isRunning { continue }
            return false
        }
        if HelperReply(line.text)?.event == name { return true }
    }
    return false
}

private func htMakeSupportFolder(home: String) throws {
    let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
    // The app makes this folder (mode 0700) before it ever starts a helper.
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
}

private func htIndexFile(home: String) -> String {
    home + "/Library/Application Support/Sesame/index.sqlite"
}

private func htNoiseJPEG(seed: Int, side: Int = 64) -> Data {
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

/// The first photo through a freshly signed helper can take tens of seconds (a cold Vision compile inside that binary).
/// Once per test process, one photo goes through a real helper first, with 120 s allowed (cap 150 s). Nothing is
/// asserted here: a helper that never warms makes the real test fail with its own message.
private let htHelperWarm: Bool = {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-httree-warm-" + UUID().uuidString, isDirectory: true)
    guard (try? fm.createDirectory(at: base, withIntermediateDirectories: true)) != nil else { return false }
    defer { try? fm.removeItem(at: base) }
    let root = base.resolvingSymlinksInPath()
    let home = root.appendingPathComponent("home", isDirectory: true).path
    let pics = root.appendingPathComponent("pics", isDirectory: true)
    guard (try? fm.createDirectory(at: pics, withIntermediateDirectories: true)) != nil,
          (try? htMakeSupportFolder(home: home)) != nil,
          (try? htNoiseJPEG(seed: 1).write(to: pics.appendingPathComponent("warm.jpg"))) != nil,
          let helper = try? htStartHelper(home: home) else { return false }
    defer { helper.stop() }
    helper.send(htFoldersLine([pics.path]))
    let deadline = Date().addingTimeInterval(150)
    var lastChange = Date()
    var lastDone = -1
    var db: HTDB?
    while Date() < deadline {
        if db == nil { db = HTDB(path: htIndexFile(home: home)) }
        if let found = db?.statuses() {
            let done = found["done"] ?? 0
            if done != lastDone { lastDone = done; lastChange = Date() }
            if done == 1 { return true }
        }
        if Date().timeIntervalSince(lastChange) > 120 { break }
        if !helper.isRunning { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}()

// MARK: the one shared run

private struct HTOutcome {
    /// Set when the run could not be made; every test then fails with it.
    var setupProblem: String?
    /// Every `files` row as path relative to `fixtures/tree/` to (status, reason).
    var rows: [String: (status: String, reason: String?)] = [:]
    /// The files that exist under `fixtures/tree/damaged` and `fixtures/tree/unsupported`, relative to `fixtures/tree/`.
    var onDisk: Set<String> = []
    var waitSummary = ""
    var pendingAtEnd = -1
    var integrity: [String?] = []
    var couldNotRead: [(path: String, name: String, reason: String)] = []
    var reasons: HTRan?
    var helperExit: Int32?
    var helperErrors = ""
    var treeRoot = ""
}

private func htRelative(_ path: String, to root: String) -> String {
    let normal = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let prefix = root + "/"
    return normal.hasPrefix(prefix) ? String(normal.dropFirst(prefix.count)) : normal
}

private func htReadRows(_ home: String, treeRoot: String) -> [String: (status: String, reason: String?)] {
    guard let db = HTDB(path: htIndexFile(home: home)),
          let rows = db.rows("select path, status, reason from files") else { return [:] }
    var out: [String: (status: String, reason: String?)] = [:]
    for row in rows {
        guard let path = row[0], let status = row[1] else { continue }
        out[htRelative(path, to: treeRoot)] = (status, row[2])
    }
    return out
}

private let htOutcome: HTOutcome = {
    var outcome = HTOutcome()
    let fm = FileManager.default
    _ = htHelperWarm

    let made = fm.temporaryDirectory.appendingPathComponent("httree-" + UUID().uuidString, isDirectory: true)
    guard (try? fm.createDirectory(at: made, withIntermediateDirectories: true)) != nil else {
        outcome.setupProblem = "could not make a temp folder"
        return outcome
    }
    defer { try? fm.removeItem(at: made) }
    let base = made.resolvingSymlinksInPath().path
    let kit = base + "/sesame-kit-t14"
    let tmp = base + "/tmp"
    let home = kit + "/home"
    let treeRoot = kit + "/fixtures/tree"
    outcome.treeRoot = treeRoot
    do {
        try fm.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try htMakeSupportFolder(home: home)
    } catch {
        outcome.setupProblem = "could not make the temp kit root: \(error)"
        return outcome
    }
    let env = ["KIT_ROOT": kit, "TMPDIR": tmp + "/", "HOME": home,
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

    // 1. the fixture tree
    let script = projectRoot.appendingPathComponent("scripts/kit-fixtures.sh").path
    let built = htRun("/bin/bash", [script, "build", "tree"], env: env)
    guard let built, built.status == 0 else {
        outcome.setupProblem = "kit-fixtures.sh build tree failed (status \(built.map { String($0.status) } ?? "not run")): \(htTail(built?.output ?? "no output"))"
        return outcome
    }
    for folder in ["damaged", "unsupported"] {
        let listed = (try? fm.contentsOfDirectory(atPath: treeRoot + "/" + folder)) ?? []
        for name in listed { outcome.onDisk.insert(folder + "/" + name) }
    }

    // 2. the helper
    guard let helper = try? htStartHelper(home: home) else {
        outcome.setupProblem = "the bundled helper could not be started (run swift build -c release and scripts/bundle.sh)"
        return outcome
    }
    defer { helper.stop() }
    helper.send(htFoldersLine([treeRoot + "/damaged", treeRoot + "/unsupported"], codeTicked: [treeRoot + "/damaged"]))

    // 3. wait until a row exists and none is pending
    let walked = htWaitEvent(helper, "walked", cap: 300)
    let started = Date()
    var db: HTDB?
    var statuses: [String: Int] = [:]
    var settled = false
    while Date().timeIntervalSince(started) < 300 {
        if db == nil { db = HTDB(path: htIndexFile(home: home)) }
        if let found = db?.statuses() {
            statuses = found
            let total = found.values.reduce(0, +)
            if total > 0 && (found["pending"] ?? 0) == 0 { settled = true; break }
        }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.2); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if settled {
        // the index must stay as it is for a moment: nothing is still being written
        Thread.sleep(forTimeInterval: 1.5)
        statuses = db?.statuses() ?? statuses
    }
    outcome.pendingAtEnd = statuses["pending"] ?? 0
    outcome.waitSummary = "walked event \(walked ? "seen" : "NOT seen"), \(Int(Date().timeIntervalSince(started))) s, statuses \(statuses.isEmpty ? "none (no files rows)" : "\(statuses)"), helper \(helper.isRunning ? "running" : "exited"), stderr: \(helper.errors)"

    // 4. read the index three ways
    outcome.rows = htReadRows(home, treeRoot: treeRoot)
    outcome.integrity = HTDB(path: htIndexFile(home: home))?.rows("pragma integrity_check")?.map { $0.first ?? nil } ?? []
    homeLock.lock()
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home, 1)
    let reader = IndexReader()
    let listed = reader.couldNotRead()
    outcome.couldNotRead = listed.map { (path: $0.path, name: $0.name, reason: "\($0.reason)") }
    reader.close()
    if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
    homeLock.unlock()
    let index = projectRoot.appendingPathComponent("scripts/kit-index.sh").path
    outcome.reasons = htRun("/bin/bash", [index, "reasons"], env: env, limit: 120)

    // 5. stdin ends: the helper exits
    helper.closeStdin()
    outcome.helperExit = helper.waitForExit(timeout: 60)?.status
    outcome.helperErrors = helper.errors
    return outcome
}()

private func htDescribe(_ rows: [String: (status: String, reason: String?)]) -> String {
    rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)\(rows[$0]!.reason.map { "(\($0))" } ?? "")" }.joined(separator: ", ")
}

private func htOutcomeOrStop() throws -> HTOutcome {
    let outcome = htOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HTStop()
    }
    return outcome
}

private struct HTStop: Error {}

// MARK: the tests

@Suite("HelperTreeUnreadableTests", .serialized)
struct HelperTreeUnreadableTests {

    @Test func theFixtureTreeHasEveryFileOfTheTwoFoldersSoAnAbsentRowMeansSomething() throws {
        let outcome = try htOutcomeOrStop()
        let wanted = Set(htExpectedRows.keys).union(htNoRowFiles)
        #expect(outcome.onDisk == wanted,
                "the damaged and unsupported folders should hold exactly \(wanted.sorted()); missing \(wanted.subtracting(outcome.onDisk).sorted()), extra \(outcome.onDisk.subtracting(wanted).sorted())")
    }

    @Test func indexingReachedItsEndWithNoRowPending() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.rows.isEmpty == false, "no files rows at all: \(outcome.waitSummary)")
        #expect(outcome.pendingAtEnd == 0, "rows are still pending: \(outcome.waitSummary)")
        let pending = outcome.rows.filter { $0.value.status == "pending" }.keys.sorted()
        #expect(pending.isEmpty, "pending rows: \(pending); \(outcome.waitSummary)")
    }

    @Test func theDamagedPngIsCouldNotReadWithAReasonDamaged() throws {
        let outcome = try htOutcomeOrStop()
        let row = outcome.rows["damaged/broken.png"]
        #expect(row?.status == htBrokenPngStatus,
                "damaged/broken.png should be \(htBrokenPngStatus), got \(row?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        #expect((row?.reason ?? "").isEmpty == false, "damaged/broken.png has no reason; rows: \(htDescribe(outcome.rows))")
        #expect(row?.reason == "damaged", "the reason should be damaged, got \(row?.reason ?? "none")")
    }

    @Test func theGoodPngsAreDone() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.rows["damaged/good.png"]?.status == "done",
                "damaged/good.png should be done, got \(outcome.rows["damaged/good.png"]?.status ?? "no row"); \(outcome.waitSummary)")
        #expect(outcome.rows["unsupported/ok.png"]?.status == "done",
                "unsupported/ok.png should be done, got \(outcome.rows["unsupported/ok.png"]?.status ?? "no row"); \(outcome.waitSummary)")
    }

    // plan-4-t4: the PDF reader makes a row for each PDF of `damaged/`.
    @Test func theGoodPdfIsDoneAndTheDamagedPdfIsCouldNotReadWithAReasonDamaged() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.rows["damaged/good.pdf"]?.status == "done",
                "damaged/good.pdf should be done, got \(outcome.rows["damaged/good.pdf"]?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        let row = outcome.rows["damaged/broken.pdf"]
        #expect(row?.status == "could_not_read",
                "damaged/broken.pdf should be could_not_read, got \(row?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        #expect(row?.reason == "damaged", "the reason of damaged/broken.pdf should be damaged, got \(row?.reason ?? "none")")
    }

    @Test func theUnsupportedFilesNeverGetARow() throws {
        let outcome = try htOutcomeOrStop()
        for name in ["unsupported/deck.pptx", "unsupported/sheet.xlsx", "unsupported/book.pages", "unsupported/raw.dng", "unsupported/README"] {
            #expect(outcome.onDisk.contains(name), "setup: \(name) is not in the built tree")
            #expect(outcome.rows[name] == nil, "\(name) must have no row, got \(outcome.rows[name]?.status ?? "")")
        }
    }

    // plan-4-t6: the document reader makes a row for each document of `damaged/` and `unsupported/`.
    @Test func theGoodTxtsAreDoneAndTheDamagedDocxIsCouldNotReadWithAReasonDamaged() throws {
        let outcome = try htOutcomeOrStop()
        for name in ["damaged/good.txt", "unsupported/ok.txt"] {
            #expect(outcome.onDisk.contains(name), "setup: \(name) is not in the built tree")
            #expect(outcome.rows[name]?.status == "done",
                    "\(name) should be done, got \(outcome.rows[name]?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        }
        let row = outcome.rows["damaged/broken.docx"]
        #expect(row?.status == "could_not_read",
                "damaged/broken.docx should be could_not_read, got \(row?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        #expect(row?.reason == "damaged", "the reason of damaged/broken.docx should be damaged, got \(row?.reason ?? "none")")
    }

    // plan-5-t2: the audio reader makes a row for each audio file of `damaged/`.
    @Test func theGoodWavIsDoneAndTheDamagedWavIsCouldNotReadWithAReasonDamaged() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.onDisk.contains("damaged/good.wav") && outcome.onDisk.contains("damaged/broken.wav"), "setup: the wavs are not in the built tree")
        #expect(outcome.rows["damaged/good.wav"]?.status == "done",
                "damaged/good.wav should be done, got \(outcome.rows["damaged/good.wav"]?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        let row = outcome.rows["damaged/broken.wav"]
        #expect(row?.status == "could_not_read",
                "damaged/broken.wav should be could_not_read, got \(row?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        #expect(row?.reason == "damaged", "the reason of damaged/broken.wav should be damaged, got \(row?.reason ?? "none")")
    }

    // plan-5-t3: the video reader makes a row for each video file of `damaged/`.
    @Test func theGoodMp4IsDoneAndTheDamagedMp4IsCouldNotReadWithAReasonDamaged() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.onDisk.contains("damaged/good.mp4") && outcome.onDisk.contains("damaged/broken.mp4"), "setup: the mp4s are not in the built tree")
        #expect(outcome.rows["damaged/good.mp4"]?.status == "done",
                "damaged/good.mp4 should be done, got \(outcome.rows["damaged/good.mp4"]?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        let row = outcome.rows["damaged/broken.mp4"]
        #expect(row?.status == "could_not_read",
                "damaged/broken.mp4 should be could_not_read, got \(row?.status ?? "no row"); rows: \(htDescribe(outcome.rows))")
        #expect(row?.reason == "damaged", "the reason of damaged/broken.mp4 should be damaged, got \(row?.reason ?? "none")")
    }

    @Test func theGoodSwiftAndTheDamagedSwiftHaveNoRowAndAreNotListedAsCouldNotRead() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.onDisk.contains("damaged/good.swift") && outcome.onDisk.contains("damaged/broken.swift"), "setup: the swift files are not in the built tree")
        #expect(outcome.rows["damaged/good.swift"] == nil,
                "damaged/good.swift is code, an unsupported file: no row, got \(outcome.rows["damaged/good.swift"]?.status ?? ""); rows: \(htDescribe(outcome.rows))")
        #expect(outcome.rows["damaged/broken.swift"] == nil,
                "damaged/broken.swift is code, an unsupported file: no row, got \(outcome.rows["damaged/broken.swift"]?.status ?? ""); rows: \(htDescribe(outcome.rows))")
        let listed = outcome.couldNotRead.map { htRelative($0.path, to: outcome.treeRoot) }
        #expect(!listed.contains("damaged/broken.swift"), "a damaged .swift is unsupported, not could not read; listed \(listed)")
    }

    @Test func onlyTheUnsupportedTypesAndCodeHaveNoRow() throws {
        let outcome = try htOutcomeOrStop()
        for name in htNoRowFiles {
            #expect(outcome.onDisk.contains(name), "setup: \(name) is not in the built tree")
            #expect(outcome.rows[name] == nil, "\(name) must have no row (an unsupported type), got \(outcome.rows[name]?.status ?? "")")
        }
    }

    @Test func theIndexHoldsExactlyTheThreePhotoRowsTheTwoPdfRowsTheThreeDocumentRowsTheTwoAudioRowsAndTheTwoVideoRows() throws {
        let outcome = try htOutcomeOrStop()
        let got = outcome.rows.mapValues { $0.status }
        #expect(got == htExpectedRows, "rows should be exactly \(htExpectedRows), got: \(htDescribe(outcome.rows))")
    }

    @Test func theCouldNotReadListHoldsExactlyBrokenPngBrokenPdfBrokenDocxBrokenWavAndBrokenMp4WithTheirNamesAndReasons() throws {
        let outcome = try htOutcomeOrStop()
        let listed = outcome.couldNotRead
        #expect(listed.count == 5, "IndexReader.couldNotRead() should list exactly five files, got \(listed.map(\.path))")
        let byPath = Dictionary(listed.map { (htRelative($0.path, to: outcome.treeRoot), $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(byPath.keys) == ["damaged/broken.png", "damaged/broken.pdf", "damaged/broken.docx", "damaged/broken.wav", "damaged/broken.mp4"], "the listed paths are \(listed.map(\.path))")
        #expect(byPath["damaged/broken.mp4"]?.name == "broken.mp4", "the listed name should be broken.mp4, got \(byPath["damaged/broken.mp4"]?.name ?? "none")")
        #expect(byPath["damaged/broken.wav"]?.name == "broken.wav", "the listed name should be broken.wav, got \(byPath["damaged/broken.wav"]?.name ?? "none")")
        #expect(byPath["damaged/broken.png"]?.name == "broken.png", "the listed name should be broken.png, got \(byPath["damaged/broken.png"]?.name ?? "none")")
        #expect(byPath["damaged/broken.pdf"]?.name == "broken.pdf", "the listed name should be broken.pdf, got \(byPath["damaged/broken.pdf"]?.name ?? "none")")
        #expect(byPath["damaged/broken.docx"]?.name == "broken.docx", "the listed name should be broken.docx, got \(byPath["damaged/broken.docx"]?.name ?? "none")")
        for (path, item) in byPath {
            #expect(item.reason == "damaged", "the listed reason of \(path) should be damaged, got \(item.reason)")
        }
    }

    @Test func theKitsReasonsListPrintsTheBrokenPngBrokenPdfBrokenDocxBrokenWavAndBrokenMp4RowsWithTheirReasons() throws {
        let outcome = try htOutcomeOrStop()
        let ran = try #require(outcome.reasons, "kit-index.sh reasons could not be run")
        #expect(ran.status == 0, "kit-index.sh reasons exited \(ran.status): \(htTail(ran.output))")
        let lines = ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let rowLines = lines.filter { $0.hasPrefix("/") }
        #expect(rowLines.count == 5, "exactly five row lines expected, got \(rowLines)")
        var seen: [String: String] = [:]
        for line in rowLines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            #expect(fields.count == 2, "a row line is `<path><tab><reason>`, got \(fields)")
            if fields.count == 2 { seen[htRelative(fields[0], to: outcome.treeRoot)] = fields[1] }
        }
        #expect(seen == ["damaged/broken.png": "damaged", "damaged/broken.pdf": "damaged", "damaged/broken.docx": "damaged", "damaged/broken.wav": "damaged", "damaged/broken.mp4": "damaged"], "the rows are \(seen)")
        #expect(lines.last == "could_not_read 5", "the last line should be `could_not_read 5`, got \(lines.last ?? "nothing")")
    }

    @Test func theIndexPassesItsIntegrityCheck() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.integrity == ["ok"], "PRAGMA integrity_check gave \(outcome.integrity); \(outcome.waitSummary)")
    }

    @Test func theHelperExitsZeroWhenItsStdinEnds() throws {
        let outcome = try htOutcomeOrStop()
        #expect(outcome.helperExit == 0,
                "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.helperExit.map(String.init) ?? "still running"); stderr: \(outcome.helperErrors)")
    }
}

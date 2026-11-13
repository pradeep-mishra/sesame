import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-3-t16, tester step (S1.6 a file once, S8.5 excluded places never get a row): overlapping and excluded folders,
// through the bundled release helper alone. Written from the t16 entry of plan-3-tasks.md (Tests, Decisions D4 to D7), the
// sealed tests of plan 1 and 2 (HelperTreeUnreadableTests, IndexReconcileTests) for style, and the spec. No product source
// is read; no expected value comes from the code under test.
//
// What happens, for each test:
//   1. The test builds a small tree of real photos under a temp folder (every photo has bytes of its own).
//   2. The bundled release helper (`dist/Sesame.app/Contents/MacOS/SesameHelper index`) is started alone with
//      `SESAME_FAKE_EMBEDDER=1` and a temp `HOME`. No app, no window. One warm-up photo goes through a helper first, once
//      per test process, with 120 s allowed, so the cold start of the first photo is not mistaken for a stall.
//   3. A `folders` line (or several, one after the other) is sent; the test waits until a row exists, none is `pending`
//      and the rows have stayed the same for a few seconds (never a tight bound; 300 s of slack).
//   4. The `files` table is read with this file's own read-only SQLite connection and compared with a hand-written list.
//
// Row paths are compared after the system resolves them (`/var` and `/private/var` are one place), so a spelling of a
// path is never what the test checks; the number of rows per photo is.

// MARK: running

private func ioJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

private func ioFoldersLine(_ folders: [(path: String, code: Bool)]) -> String {
    let items = folders.map { "{\"path\":\(ioJSONString($0.path)),\"code\":\($0.code ? "true" : "false")}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private func ioStartHelper(home: String) throws -> HelperProcess {
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

private func ioMakeSupportFolder(home: String) throws {
    let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
}

private func ioIndexFile(home: String) -> String {
    home + "/Library/Application Support/Sesame/index.sqlite"
}

private final class IODB {
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

    /// Every `files` row as (path, status), or nil while the table cannot be read.
    func rows() -> [(path: String, status: String)]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select path, status from files", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var out: [(path: String, status: String)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let path = sqlite3_column_text(statement, 0), let status = sqlite3_column_text(statement, 1) else { continue }
            out.append((String(cString: path), String(cString: status)))
        }
        return out
    }
}

private func ioPhoto(seed: Int, type: String = "public.jpeg", side: Int = 64) -> Data {
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
    if let image, let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return data as Data
}

/// One tree under a temp folder: `root` is the real path, `home` the helper's home.
private final class IOTree {
    let root: String
    let home: String
    private var seed = 100

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-overlap-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = ioResolved(url.path)
        home = root + "/home"
        try ioMakeSupportFolder(home: home)
        try FileManager.default.createDirectory(atPath: root + "/t", withIntermediateDirectories: true)
    }

    /// The folder every test tree lives in (the helper's home is beside it, never inside a pick).
    var base: String { root + "/t" }

    func path(_ relative: String) -> String { base + "/" + relative }

    @discardableResult
    func photo(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        seed += 1
        let type = full.lowercased().hasSuffix(".png") ? "public.png" : "public.jpeg"
        try ioPhoto(seed: seed, type: type).write(to: URL(fileURLWithPath: full))
        return full
    }

    func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func plainFile(_ relative: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("print(1)\n".utf8).write(to: URL(fileURLWithPath: full))
    }

    func hardLink(_ relative: String, to target: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try #require(link(path(target), full) == 0, "could not make a hard link \(relative)")
    }

    /// A real repo (`git init`) at `relative`, made with the real git in a scrubbed environment and the temp home. Nothing is
    /// added: the pictures are untracked and not ignored, which git lists.
    func repo(_ relative: String) throws {
        try dir(relative)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path(relative), "init", "-q", "-b", "main"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["HOME"] = home
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "setup: git init in \(relative) exited \(process.terminationStatus)")
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

/// The system's own resolution (`realpath`): `/var/...` and `/private/var/...` come out the same. (Foundation's
/// `resolvingSymlinksInPath` would turn `/private/var` into `/var`, which is why it is not used here.) A path that
/// cannot be resolved stays as it is.
private func ioResolved(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// One snapshot of the index: rows per resolved path (a count above 1 is a photo indexed twice), and every status.
private struct IOSnapshot {
    var rowsByPath: [String: Int] = [:]
    var statusByPath: [String: String] = [:]
    var total = 0
    var spelled: [String] = []

    init(_ rows: [(path: String, status: String)]) {
        total = rows.count
        for row in rows {
            let resolved = ioResolved(row.path)
            rowsByPath[resolved, default: 0] += 1
            statusByPath[resolved] = row.status
            spelled.append(row.path)
        }
    }

    var pending: Int { statusByPath.values.filter { $0 == "pending" }.count }
    var paths: Set<String> { Set(rowsByPath.keys) }
    var twice: [String] { rowsByPath.filter { $0.value > 1 }.keys.sorted() }

    func describe(under root: String) -> String {
        spelled.sorted().map { String($0.dropFirst($0.hasPrefix(root) ? root.count + 1 : 0)) }.joined(separator: ", ")
    }
}

/// Waits until a row exists (when `needRows`), none is pending and the rows have not changed for `quiet` seconds.
private func ioSettle(_ helper: HelperProcess, home: String, needRows: Bool, quiet: TimeInterval = 3,
                      cap: TimeInterval = 300) -> (snapshot: IOSnapshot, settled: Bool, note: String) {
    let started = Date()
    var lastChange = Date()
    var last = ""
    var db: IODB?
    var snapshot = IOSnapshot([])
    while Date().timeIntervalSince(started) < cap {
        if db == nil { db = IODB(path: ioIndexFile(home: home)) }
        if let rows = db?.rows() {
            snapshot = IOSnapshot(rows)
            let key = rows.map { "\($0.path)|\($0.status)" }.sorted().joined(separator: "\n")
            if key != last { last = key; lastChange = Date() }
            if (!needRows || !rows.isEmpty) && snapshot.pending == 0 && Date().timeIntervalSince(lastChange) >= quiet {
                return (snapshot, true, "")
            }
        }
        if !helper.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            if !helper.isRunning { return (snapshot, false, "the helper exited; stderr: \(helper.errors)") }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return (snapshot, false, "no settled index within \(Int(cap)) s; pending \(snapshot.pending), rows \(snapshot.total); stderr: \(helper.errors)")
}

/// The first photo through a freshly signed helper can take tens of seconds (a cold Vision compile inside that binary).
/// Once per test process, one photo goes through a real helper first, with 120 s allowed (cap 150 s). Nothing is asserted
/// here: a helper that never warms makes the real test fail with its own message.
private let ioHelperWarm: Bool = {
    guard let tree = try? IOTree() else { return false }
    defer { tree.remove() }
    guard (try? tree.photo("warm/warm.jpg")) != nil, let helper = try? ioStartHelper(home: tree.home) else { return false }
    defer { helper.stop() }
    helper.send(ioFoldersLine([(tree.path("warm"), false)]))
    let deadline = Date().addingTimeInterval(150)
    var lastChange = Date()
    var lastDone = -1
    var db: IODB?
    while Date() < deadline {
        if db == nil { db = IODB(path: ioIndexFile(home: tree.home)) }
        if let rows = db?.rows() {
            let done = rows.filter { $0.status == "done" }.count
            if done != lastDone { lastDone = done; lastChange = Date() }
            if done == 1 { return true }
        }
        if Date().timeIntervalSince(lastChange) > 120 || !helper.isRunning { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}()

/// Starts a helper over `tree`, sends each `folders` line in turn, settles after each one and returns the snapshots.
private func ioRun(_ tree: IOTree, lines: [[(path: String, code: Bool)]]) throws -> [IOSnapshot] {
    _ = ioHelperWarm
    let helper = try ioStartHelper(home: tree.home)
    defer { helper.stop() }
    var snapshots: [IOSnapshot] = []
    for (index, line) in lines.enumerated() {
        helper.send(ioFoldersLine(line))
        let settled = ioSettle(helper, home: tree.home, needRows: index == 0)
        #expect(settled.settled, "after folders line \(index + 1): \(settled.note)")
        snapshots.append(settled.snapshot)
    }
    return snapshots
}

private func ioPaths(_ tree: IOTree, _ relatives: [String]) -> Set<String> {
    Set(relatives.map { ioResolved(tree.path($0)) })
}

@Suite("IndexOverlapTests", .serialized)
struct IndexOverlapTests {

    // MARK: overlapping picks

    @Test func anOuterFolderItsInnerFolderAndTheOuterAgainWithOtherTicksGiveOneRowPerPhoto() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        for name in ["outer/a.jpg", "outer/b.jpg", "outer/inner/c.jpg", "outer/inner/deeper/d.jpg"] { try tree.photo(name) }
        let line: [(path: String, code: Bool)] = [(tree.path("outer"), false), (tree.path("outer/inner"), true), (tree.path("outer"), true)]
        let shot = try #require(try ioRun(tree, lines: [line]).first)
        let want = ioPaths(tree, ["outer/a.jpg", "outer/b.jpg", "outer/inner/c.jpg", "outer/inner/deeper/d.jpg"])
        #expect(shot.paths == want, "rows: \(shot.describe(under: tree.base)); want \(want.count) photos")
        #expect(shot.twice.isEmpty, "photos with more than one row: \(shot.twice)")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) photos: \(shot.describe(under: tree.base))")
        #expect(shot.statusByPath.values.allSatisfy { $0 == "done" }, "statuses: \(shot.statusByPath)")
    }

    @Test func theInnerFolderListedFirstAndTheOuterAfterItGivesTheSameRows() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        for name in ["outer/a.jpg", "outer/inner/c.jpg", "outer/inner/d.png"] { try tree.photo(name) }
        let line: [(path: String, code: Bool)] = [(tree.path("outer/inner"), false), (tree.path("outer"), false)]
        let shot = try #require(try ioRun(tree, lines: [line]).first)
        let want = ioPaths(tree, ["outer/a.jpg", "outer/inner/c.jpg", "outer/inner/d.png"])
        #expect(shot.paths == want, "rows: \(shot.describe(under: tree.base))")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) photos: \(shot.describe(under: tree.base))")
    }

    // MARK: the same folder under two spellings

    @Test func theVarAndThePrivateSpellingsOfOneFolderGiveOneRowPerPhoto() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        for name in ["pics/a.jpg", "pics/b.jpg", "pics/sub/c.jpg"] { try tree.photo(name) }
        let real = tree.path("pics")
        guard real.hasPrefix("/private/var/") else {
            Issue.record("the temp folder is \(real): it has no /private/var spelling, so this test cannot name one folder two ways")
            return
        }
        let short = String(real.dropFirst("/private".count))
        #expect(ioResolved(short) == real, "setup: \(short) and \(real) should be one folder")
        let shot = try #require(try ioRun(tree, lines: [[(short, false), (real, false)]]).first)
        let want = ioPaths(tree, ["pics/a.jpg", "pics/b.jpg", "pics/sub/c.jpg"])
        #expect(shot.paths == want, "rows: \(shot.spelled.sorted())")
        #expect(shot.twice.isEmpty, "photos with two rows (one per spelling): \(shot.twice)")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) photos: \(shot.spelled.sorted())")
    }

    @Test func theVarSpellingAloneAndThePrivateSpellingAloneEachGiveOneRowPerPhoto() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        for name in ["pics/a.jpg", "pics/b.jpg"] { try tree.photo(name) }
        let real = tree.path("pics")
        guard real.hasPrefix("/private/var/") else {
            Issue.record("the temp folder is \(real): it has no /private/var spelling")
            return
        }
        let short = String(real.dropFirst("/private".count))
        let want = ioPaths(tree, ["pics/a.jpg", "pics/b.jpg"])
        let viaVar = try #require(try ioRun(tree, lines: [[(short, false)]]).first)
        #expect(viaVar.paths == want && viaVar.total == want.count, "var spelling: \(viaVar.spelled.sorted())")
        let viaPrivate = try #require(try ioRun(tree, lines: [[(real, false)]]).first)
        #expect(viaPrivate.paths == want && viaPrivate.total == want.count, "private spelling: \(viaPrivate.spelled.sorted())")
    }

    // MARK: hard links

    @Test func twoHardLinksToOnePictureGiveOneRowAndTheFirstPathInSortedOrderWins() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        try tree.photo("pics/a.jpg")
        try tree.hardLink("pics/b-link.jpg", to: "pics/a.jpg")
        try tree.photo("pics/c.jpg")
        let shot = try #require(try ioRun(tree, lines: [[(tree.path("pics"), false)]]).first)
        let want = ioPaths(tree, ["pics/a.jpg", "pics/c.jpg"])
        #expect(shot.paths == want, "two hard links are one file: rows \(shot.describe(under: tree.base)); want a.jpg and c.jpg")
        #expect(shot.total == 2, "\(shot.total) rows: \(shot.describe(under: tree.base))")
    }

    @Test func aHardLinkInAnotherPickedFolderIsStillOneRow() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        try tree.photo("one/a.jpg")
        try tree.hardLink("two/a-again.jpg", to: "one/a.jpg")
        try tree.photo("two/other.jpg")
        let line: [(path: String, code: Bool)] = [(tree.path("one"), false), (tree.path("two"), false)]
        let shot = try #require(try ioRun(tree, lines: [line]).first)
        let want = ioPaths(tree, ["one/a.jpg", "two/other.jpg"])
        #expect(shot.paths == want, "rows: \(shot.describe(under: tree.base)); want one/a.jpg and two/other.jpg")
        #expect(shot.total == 2, "\(shot.total) rows: \(shot.describe(under: tree.base))")
    }

    // MARK: excluded pictures

    @Test func excludedPicturesGetNoRowAndTheSamePictureInAPlainFolderIsDone() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        // plain places: each name read from a plain folder is `done`
        for name in ["ok/hid.jpg", "ok/cache.jpg", "ok/app.jpg", "ok/vendor.jpg", "ok/env.png", "ok/shot.jpg"] { try tree.photo(name) }
        // the same names in excluded places: no row
        try tree.photo(".hidden/hid.jpg")
        try tree.photo("Caches/cache.jpg")
        try tree.photo("Thing.app/Contents/Resources/app.jpg")
        try tree.repo("repo")
        try tree.photo("repo/node_modules/vendor.jpg")
        try tree.photo("repo/Pods/vendor2.jpg")
        try tree.photo("repo/shot.jpg")
        try tree.photo("keys/.env.png")
        try tree.photo("keys/id_rsa.png")
        // vendored names outside a repo marker are ordinary
        try tree.photo("loose/node_modules/loose.jpg")
        let line: [(path: String, code: Bool)] = [(tree.base, false)]
        let shot = try #require(try ioRun(tree, lines: [line]).first)
        let want = ioPaths(tree, ["ok/hid.jpg", "ok/cache.jpg", "ok/app.jpg", "ok/vendor.jpg", "ok/env.png", "ok/shot.jpg",
                                  "repo/shot.jpg", "loose/node_modules/loose.jpg"])
        #expect(shot.paths == want,
                "missing \(want.subtracting(shot.paths).map { String($0.dropFirst(tree.base.count + 1)) }.sorted()), unexpected \(shot.paths.subtracting(want).map { String($0.dropFirst(tree.base.count + 1)) }.sorted())")
        #expect(shot.statusByPath.filter { want.contains($0.key) }.values.allSatisfy { $0 == "done" },
                "every kept photo is done: \(shot.statusByPath)")
    }

    @Test func eachExcludedPlaceIsCheckedOnItsOwnWithAPlainControlBesideIt() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        let excluded = [".hidden/a.jpg", "Caches/a.jpg", "Thing.app/a.jpg", "Upper.APP/a.jpg", "repo/dist/a.jpg", "repo/build/a.jpg",
                        "repo/vendor/a.jpg", "keys/id_rsa.jpg", "keys/.env.local.jpg"]
        try tree.repo("repo")
        for name in excluded { try tree.photo(name) }
        try tree.photo("control/a.jpg")
        let shot = try #require(try ioRun(tree, lines: [[(tree.base, true)]]).first)
        #expect(shot.paths == ioPaths(tree, ["control/a.jpg"]),
                "only the control gets a row, rows: \(shot.describe(under: tree.base))")
        #expect(shot.statusByPath[ioResolved(tree.path("control/a.jpg"))] == "done", "the control is done")
    }

    // MARK: the code tick

    @Test func changingACodeTickInTheNextFoldersLineChangesNoRowAndCodeFilesNeverGetOne() throws {
        let tree = try IOTree()
        defer { tree.remove() }
        for name in ["pics/a.jpg", "pics/sub/b.png", "repo/shot.jpg"] { try tree.photo(name) }
        try tree.repo("repo")
        try tree.plainFile("repo/tool.py")
        try tree.plainFile("pics/tool.py")
        let off: [(path: String, code: Bool)] = [(tree.path("pics"), false), (tree.path("repo"), false)]
        let on: [(path: String, code: Bool)] = [(tree.path("pics"), true), (tree.path("repo"), true)]
        let shots = try ioRun(tree, lines: [off, on, off])
        try #require(shots.count == 3, "three folders lines, three snapshots")
        let photos = ioPaths(tree, ["pics/a.jpg", "pics/sub/b.png", "repo/shot.jpg"])
        #expect(shots[0].paths == photos, "ticks off: rows \(shots[0].describe(under: tree.base))")
        #expect(shots[1].paths == photos, "ticks on: rows \(shots[1].describe(under: tree.base))")
        #expect(shots[2].paths == photos, "ticks off again: rows \(shots[2].describe(under: tree.base))")
        for (i, shot) in shots.enumerated() {
            let photoStatus = shot.statusByPath.filter { photos.contains($0.key) }
            #expect(photoStatus.count == photos.count && photoStatus.values.allSatisfy { $0 == "done" },
                    "line \(i): every photo row is done: \(photoStatus)")
        }
        #expect(shots[0].total == photos.count && shots[1].total == photos.count && shots[2].total == photos.count,
                "row counts \(shots[0].total), \(shots[1].total), \(shots[2].total); want \(photos.count) each")
    }
}

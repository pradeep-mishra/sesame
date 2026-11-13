import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-3 fix round 2, t17-8, tester step. Written from the reviewer's round 2 findings (reviewer-plan-3-2 report: pick `/`,
// nested repos, two spellings of one folder), the spec (S8.3, S8.5, S8.13) and the sealed PickInsideRepoTests for style. No
// product source is read; every expected list below is written by hand.
//
// (1) A pick of `/` must not hang. `Walker.scan(root: <temp folder>, mode: .read, picks: [HelperFolder(path: "/", code: false)])`
//     runs on a plain Foundation Thread (a thread stuck in a loop cannot be killed; a Thread does not keep the test process
//     from exiting, so the stuck one is simply left behind). A 30 s guard records an Issue and returns. The test is the LAST
//     one in the suite on purpose; Swift Testing does not promise the order of a serialized suite, so the source order is the
//     best that can be done.
//
// (2) Nested repos. The outer repo R (real `git init`, .gitignore holds `external/`):
//       R/a.png                       tracked by R
//       R/sub/b.png                   untracked, not ignored
//       R/libs/inner/                 a nested real repo: tracked.png (committed), fresh.png (untracked, not ignored), ignored.png
//                                     (ignored by its OWN .gitignore). Not under a vendored name and not in a folder R ignores,
//                                     so it is admitted and filtered by its own git list.
//       R/node_modules/pkg/n.png      a nested repo under a vendored name: not admitted.
//       R/vendor/lib/v.png            a nested repo under a vendored name (spec line 22 lists `vendor`): not admitted.
//       R/external/clone/e.png        a nested repo in a folder R ignores: not descended into, so not admitted.
//       R/external/plain.png          ignored by R: not admitted.
//     Expected: a.png, sub/b.png, libs/inner/tracked.png, libs/inner/fresh.png (never libs/inner/ignored.png).
//     Controller's decision (logged): the vendored names `node_modules`, `Pods`, `build`, `dist`, `.build` and `vendor` are
//     skipped inside a git repo for every kind, so a nested repo below one of them is excluded.
//
// (3) Spellings: picks A = the real spelling of R and B = the other spelling of R/sub (the /var one when the temp folder is
//     under /var, otherwise a symlink to R/sub's parent). And a symlinked pick folder. R/sub/ignored.png is ignored by R.
//
// The helper tests run the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`,
// SESAME_FAKE_EMBEDDER=1, a temp HOME, no app).

// MARK: running (shared with JpegFillBytesTests, same module)

func rxJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

func rxFoldersLine(_ folders: [(path: String, code: Bool)]) -> String {
    let items = folders.map { "{\"path\":\(rxJSONString($0.path)),\"code\":\($0.code ? "true" : "false")}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

func rxStartHelper(home: String) throws -> HelperProcess {
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

func rxIndexFile(home: String) -> String {
    home + "/Library/Application Support/Sesame/index.sqlite"
}

final class RXDB {
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

/// A noisy square picture ImageIO writes as `type`.
func rxPicture(seed: Int, type: String = "public.png", side: Int = 64) -> Data {
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

func rxResolved(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// One tree under a temp folder; the helper's home sits beside it, never inside a pick. `root` is the real spelling;
/// `rawRoot` is the spelling the system gave (the /var one on most Macs).
final class RXTree {
    let rawRoot: String
    let root: String
    let home: String
    private var seed = 900

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-rx-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rawRoot = url.path
        root = rxResolved(url.path)
        home = root + "/home"
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: root + "/t", withIntermediateDirectories: true)
    }

    var base: String { root + "/t" }

    func path(_ relative: String) -> String { base + "/" + relative }

    /// The other spelling of `path(relative)`: the same folder under the raw (/var) root when that differs from the real
    /// one, otherwise through a symlink made for the purpose.
    func otherSpelling(_ relative: String) throws -> String {
        if rawRoot != root { return rawRoot + "/t/" + relative }
        let link = root + "/alias-of-t"
        if !FileManager.default.fileExists(atPath: link) {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base)
        }
        return link + "/" + relative
    }

    /// A symlink `<root>/<name>` to `path(relative)`; returns the link's path.
    func symlink(_ name: String, to relative: String) throws -> String {
        let link = root + "/" + name
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path(relative))
        return link
    }

    func photo(_ relative: String) throws {
        seed += 1
        let type = relative.lowercased().hasSuffix(".png") ? "public.png" : "public.jpeg"
        try bytes(relative, [UInt8](rxPicture(seed: seed, type: type)))
    }

    func bytes(_ relative: String, _ content: [UInt8]) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(content).write(to: URL(fileURLWithPath: full))
    }

    func text(_ relative: String, _ content: String) throws { try bytes(relative, [UInt8](content.utf8)) }

    /// The real git, a scrubbed environment and the temp home.
    func git(_ repoRelative: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path(repoRelative)] + args
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
        try #require(process.terminationStatus == 0, "setup: git \(args.joined(separator: " ")) exited \(process.terminationStatus)")
    }

    func initRepo(_ repoRelative: String) throws {
        try FileManager.default.createDirectory(atPath: path(repoRelative), withIntermediateDirectories: true)
        try git(repoRelative, ["init", "-q", "-b", "main"])
    }

    func commit(_ repoRelative: String, adding files: [String]) throws {
        try git(repoRelative, ["add"] + files)
        try git(repoRelative, ["-c", "user.name=tester", "-c", "user.email=tester@example.invalid", "-c", "commit.gpgsign=false",
                               "commit", "-q", "-m", "one"])
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

struct RXSnapshot {
    var paths: Set<String> = []
    var names: [String] = []
    var total = 0

    init(_ rows: [(path: String, status: String)]) {
        total = rows.count
        names = rows.map { $0.path }
        paths = Set(rows.map { rxResolved($0.path) })
    }
}

/// Waits until `expectRows` rows exist, none is pending and the rows have not changed for `quiet` seconds (300 s of slack).
func rxSettle(_ helper: HelperProcess, home: String, expectRows: Int = 1, quiet: TimeInterval = 4, cap: TimeInterval = 300)
    -> (snapshot: RXSnapshot, rows: [(path: String, status: String)], settled: Bool, note: String) {
    let started = Date()
    var lastChange = Date()
    var last = ""
    var db: RXDB?
    var rows: [(path: String, status: String)] = []
    while Date().timeIntervalSince(started) < cap {
        if db == nil { db = RXDB(path: rxIndexFile(home: home)) }
        if let read = db?.rows() {
            rows = read
            let key = rows.map { "\($0.path)|\($0.status)" }.sorted().joined(separator: "\n")
            if key != last { last = key; lastChange = Date() }
            let pending = rows.filter { $0.status == "pending" }.count
            if rows.count >= expectRows && pending == 0 && Date().timeIntervalSince(lastChange) >= quiet {
                return (RXSnapshot(rows), rows, true, "")
            }
        }
        if !helper.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            if !helper.isRunning { return (RXSnapshot(rows), rows, false, "the helper exited; stderr: \(helper.errors)") }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return (RXSnapshot(rows), rows, false, "no settled index within \(Int(cap)) s; rows \(rows.count); stderr: \(helper.errors)")
}

/// Starts a helper, sends one `folders` line with these picks (code ticks off) and settles.
func rxRun(_ tree: RXTree, picks: [String], expectRows: Int = 1) throws -> RXSnapshot {
    let helper = try rxStartHelper(home: tree.home)
    defer { helper.stop() }
    helper.send(rxFoldersLine(picks.map { ($0, false) }))
    let settled = rxSettle(helper, home: tree.home, expectRows: expectRows)
    #expect(settled.settled, "\(settled.note)")
    return settled.snapshot
}

private func rxResolvedSet(_ tree: RXTree, _ relatives: [String]) -> Set<String> {
    Set(relatives.map { rxResolved(tree.path($0)) })
}

private func rxDescribe(_ paths: Set<String>, under tree: RXTree) -> String {
    paths.map { String($0.dropFirst($0.hasPrefix(tree.base) ? tree.base.count + 1 : 0)) }.sorted().joined(separator: ", ")
}

private func rxScan(root: String, picks: [String]) -> [String] {
    let result = Walker.scan(root: root, mode: .read, picks: picks.map { HelperFolder(path: $0, code: false) })
    return result.files.map { rxResolved($0.path) }
}

private func rxCompare(_ got: Set<String>, _ want: Set<String>, under tree: RXTree) -> String {
    "missing [\(rxDescribe(want.subtracting(got), under: tree))], unexpected [\(rxDescribe(got.subtracting(want), under: tree))]"
}

// MARK: the trees

/// The nested-repo tree of section (2) above.
private func rxBuildNested(_ tree: RXTree) throws {
    try tree.initRepo("R")
    try tree.text("R/.gitignore", "external/\n")
    try tree.photo("R/a.png")
    try tree.commit("R", adding: [".gitignore", "a.png"])
    try tree.photo("R/sub/b.png")

    try tree.initRepo("R/libs/inner")
    try tree.text("R/libs/inner/.gitignore", "ignored.png\n")
    try tree.photo("R/libs/inner/tracked.png")
    try tree.commit("R/libs/inner", adding: [".gitignore", "tracked.png"])
    try tree.photo("R/libs/inner/fresh.png")
    try tree.photo("R/libs/inner/ignored.png")

    try tree.initRepo("R/vendor/lib")
    try tree.photo("R/vendor/lib/v.png")
    try tree.commit("R/vendor/lib", adding: ["v.png"])

    try tree.initRepo("R/node_modules/pkg")
    try tree.photo("R/node_modules/pkg/n.png")
    try tree.commit("R/node_modules/pkg", adding: ["n.png"])

    try tree.initRepo("R/external/clone")
    try tree.photo("R/external/clone/e.png")
    try tree.commit("R/external/clone", adding: ["e.png"])
    try tree.photo("R/external/plain.png")
    try tree.text("R/notes.txt", "nested repo note")
    try tree.text("R/libs/inner/fresh.txt", "inner repo note")
    try tree.text("R/node_modules/pkg/n.txt", "vendored note")
    try tree.text("R/external/plain.txt", "ignored note")
}

private let rxNestedWant = ["R/a.png", "R/sub/b.png", "R/libs/inner/tracked.png", "R/libs/inner/fresh.png", "R/notes.txt", "R/libs/inner/fresh.txt"]

private func rxBuildSpelling(_ tree: RXTree) throws {
    try tree.initRepo("R")
    try tree.text("R/.gitignore", "ignored.*\n")
    try tree.photo("R/top.png")
    try tree.commit("R", adding: [".gitignore", "top.png"])
    try tree.photo("R/sub/normal.png")
    try tree.photo("R/sub/ignored.png")
    try tree.text("R/sub/normal.txt", "a plain note")
    try tree.text("R/sub/ignored.txt", "an ignored note")
}

private let rxSpellingWantInSub = ["R/sub/normal.png", "R/sub/normal.txt"]
private let rxSpellingWantAll = ["R/top.png", "R/sub/normal.png", "R/sub/normal.txt"]

private func rxExpectScan(_ tree: RXTree, root: String, picks: [String], label: String) {
    let got = rxScan(root: root, picks: picks)
    let want = rxResolvedSet(tree, rxSpellingWantInSub)
    #expect(Set(got) == want, "\(label): \(rxCompare(Set(got), want, under: tree))")
    #expect(got.count == 2, "\(label): \(got.count) files returned, want exactly 2")
}

private func rxExpectIndex(_ tree: RXTree, picks: [String], label: String) throws {
    let shot = try rxRun(tree, picks: picks, expectRows: 1)
    let want = rxResolvedSet(tree, rxSpellingWantAll)
    #expect(shot.paths == want, "\(label): \(rxCompare(shot.paths, want, under: tree))")
    #expect(shot.total == want.count, "\(label): \(shot.total) rows for \(want.count) pictures: \(shot.names)")
}

// MARK: scan guard for pick `/`

private final class RXScanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String]?

    func set(_ value: [String]) { lock.lock(); stored = value; lock.unlock() }
    var value: [String]? { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite("RepoEdgeCaseTests", .serialized)
struct RepoEdgeCaseTests {

    // MARK: (2) nested repos

    @Test func theScanOfRHoldsOnlyWhatTheRulesAndGitAdmitInNestedReposToo() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rxBuildNested(tree)
        let got = rxScan(root: tree.path("R"), picks: [tree.path("R")])
        let want = rxResolvedSet(tree, rxNestedWant)
        #expect(Set(got) == want, "scan of R with the pick R: \(rxCompare(Set(got), want, under: tree))")
        #expect(got.count == want.count, "\(got.count) files returned for \(want.count) pictures")
    }

    @Test func theHelperIndexesOnlyWhatTheRulesAndGitAdmitInNestedReposToo() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rxBuildNested(tree)
        let shot = try rxRun(tree, picks: [tree.path("R")], expectRows: 1)
        let want = rxResolvedSet(tree, rxNestedWant)
        #expect(shot.paths == want, "helper, pick R: \(rxCompare(shot.paths, want, under: tree))")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) pictures: \(shot.names)")
    }

    // MARK: (3) two spellings of one folder

    @Test func theScanOfTheOtherSpellingWithBothPicksDropsTheIgnoredPictureAndHoldsTheNormalOneOnce() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rxBuildSpelling(tree)
        let a = tree.path("R")
        let b = try tree.otherSpelling("R/sub")
        #expect(b != tree.path("R/sub"), "setup: the second spelling is the same string")
        rxExpectScan(tree, root: b, picks: [a, b], label: "scan of B, picks A then B")
        rxExpectScan(tree, root: b, picks: [b, a], label: "scan of B, picks B then A")
    }

    @Test func theHelperHoldsTheIgnoredPictureOfTheOtherSpellingNowhereAndTheNormalOneOnce() throws {
        for aFirst in [true, false] {
            let tree = try RXTree()
            defer { tree.remove() }
            try rxBuildSpelling(tree)
            let a = tree.path("R")
            let b = try tree.otherSpelling("R/sub")
            try rxExpectIndex(tree, picks: aFirst ? [a, b] : [b, a], label: aFirst ? "helper, picks A then B" : "helper, picks B then A")
        }
    }

    // MARK: (3) a symlinked pick folder

    @Test func aLoneSymlinkedPickFolderIsScannedLikeAnyOtherLonePick() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rxBuildSpelling(tree)
        let link = try tree.symlink("link-sub", to: "R/sub")
        let got = Set(rxScan(root: link, picks: [link]))
        let want = rxResolvedSet(tree, ["R/sub/normal.png", "R/sub/ignored.png", "R/sub/normal.txt", "R/sub/ignored.txt"])
        #expect(got == want, "guard, lone symlinked pick: \(rxCompare(got, want, under: tree))")
    }

    @Test func theScanOfASymlinkedPickFolderWithTheRepoAmongThePicksDropsTheIgnoredPicture() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try rxBuildSpelling(tree)
        let a = tree.path("R")
        let link = try tree.symlink("link-sub", to: "R/sub")
        rxExpectScan(tree, root: link, picks: [a, link], label: "scan of the link, picks R then link")
        rxExpectScan(tree, root: link, picks: [link, a], label: "scan of the link, picks link then R")
    }

    @Test func theHelperHoldsTheIgnoredPictureNowhereWhenOnePickIsASymlinkAndTheNormalOneOnce() throws {
        for repoFirst in [true, false] {
            let tree = try RXTree()
            defer { tree.remove() }
            try rxBuildSpelling(tree)
            let a = tree.path("R")
            let link = try tree.symlink("link-sub", to: "R/sub")
            try rxExpectIndex(tree, picks: repoFirst ? [a, link] : [link, a],
                              label: repoFirst ? "helper, picks R then link" : "helper, picks link then R")
        }
    }

    // MARK: (1) pick `/` (keep this test LAST: a stuck scan spins one core until the process exits)

    @Test func aPickOfSlashReturnsAndHoldsThePictureOfTheRoot() throws {
        let tree = try RXTree()
        defer { tree.remove() }
        try tree.photo("only.png")
        let root = tree.base
        let box = RXScanBox()
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            let result = Walker.scan(root: root, mode: .read, picks: [HelperFolder(path: "/", code: false)])
            box.set(result.files.map { rxResolved($0.path) })
            finished.signal()
        }
        worker.name = "RepoEdgeCaseTests-pick-slash"
        let started = Date()
        worker.start()
        guard finished.wait(timeout: .now() + 30) == .success else {
            Issue.record("Walker.scan with a pick of `/` did not return within 30 s (the guard); its thread is left running and dies with the test process")
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10, "Walker.scan with a pick of `/` took \(elapsed) s, want under 10 s")
        let want: Set<String> = [rxResolved(tree.path("only.png"))]
        let got = Set(box.value ?? [])
        #expect(got == want, "root with one picture, pick `/`: \(rxCompare(got, want, under: tree))")
    }
}

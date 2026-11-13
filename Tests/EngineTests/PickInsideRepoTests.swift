import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-3 fix round, t17-5, tester step (A): a pick inside a repo (S8.5). Written from the reviewer's finding "Git-ignore and
// vendored rules depend on which pick reaches a file" (reviewer-plan-3-1 report), the spec and design (D5: a pick inside a
// repo is not a repo, written for a LONE pick), and the sealed IndexOverlapTests / WalkerReadRulesTests for style. No product
// source is read; every expected list below is written by hand.
//
// The rule these tests pin: a file under a repo that some scan listed is admitted only if git listed it, whichever pick
// reached it. The picks are R (a real repo, made with the real `git init`) and R/sub (a sub folder of R).
//
//   R/.gitignore            ignored.jpg and ignored.png (a name with no slash matches at every depth)
//   R/tracked.jpg           tracked (added and committed)
//   R/fresh.jpg             untracked, not ignored: git lists it
//   R/ignored.jpg           ignored by R/.gitignore
//   R/node_modules/vendored.jpg   a vendored place inside the repo
//   R/sub/normal.jpg        untracked, not ignored: git lists it
//   R/sub/ignored.png       ignored by R/.gitignore
//
// Through the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, SESAME_FAKE_EMBEDDER=1, a
// temp HOME, no app): picks R then R/sub, and R/sub then R. Both must give exactly tracked, fresh and sub/normal. A lone pick
// R/sub (no enclosing pick) is a guard: today's behaviour (not a repo, nothing dropped), so both of its pictures are rows.
// Through `Walker.scan(root:mode:picks:flags:repoFiles:)` (its default `repoFiles` runs the real git): a scan whose root is
// R/sub, with R among the picks, must not return sub/ignored.png. NOTE for the controller: that Walker test pins WHERE the
// rule is applied (in the scan of the inner root); if the fix is made after the scans (in the merge), drop the two Walker
// tests marked "scan of the inner root" and keep the helper tests.

// MARK: running (copied from IndexOverlapTests, which keeps its own copy private)

private func piJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

private func piFoldersLine(_ folders: [(path: String, code: Bool)]) -> String {
    let items = folders.map { "{\"path\":\(piJSONString($0.path)),\"code\":\($0.code ? "true" : "false")}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private func piStartHelper(home: String) throws -> HelperProcess {
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

private func piIndexFile(home: String) -> String {
    home + "/Library/Application Support/Sesame/index.sqlite"
}

private final class PIDB {
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

private func piPhoto(seed: Int, type: String = "public.jpeg", side: Int = 64) -> Data {
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

private func piResolved(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// One tree under a temp folder; the helper's home sits beside it, never inside a pick.
private final class PITree {
    let root: String
    let home: String
    private var seed = 500

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-pickinrepo-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = piResolved(url.path)
        home = root + "/home"
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: root + "/t", withIntermediateDirectories: true)
    }

    var base: String { root + "/t" }

    func path(_ relative: String) -> String { base + "/" + relative }

    func photo(_ relative: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        seed += 1
        let type = full.lowercased().hasSuffix(".png") ? "public.png" : "public.jpeg"
        try piPhoto(seed: seed, type: type).write(to: URL(fileURLWithPath: full))
    }

    func text(_ relative: String, _ content: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: full))
    }

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

    /// The repo R described at the top of this file.
    func buildRepoR() throws {
        try FileManager.default.createDirectory(atPath: path("R"), withIntermediateDirectories: true)
        try git("R", ["init", "-q", "-b", "main"])
        try text("R/.gitignore", "ignored.jpg\nignored.png\nignored.txt\n")
        try photo("R/tracked.jpg")
        try git("R", ["add", ".gitignore", "tracked.jpg"])
        try git("R", ["-c", "user.name=tester", "-c", "user.email=tester@example.invalid", "-c", "commit.gpgsign=false",
                      "commit", "-q", "-m", "one"])
        try photo("R/fresh.jpg")
        try photo("R/ignored.jpg")
        try photo("R/node_modules/vendored.jpg")
        try photo("R/sub/normal.jpg")
        try photo("R/sub/ignored.png")
        try text("R/notes.txt", "a repo note")
        try text("R/ignored.txt", "an ignored note")
        try text("R/node_modules/vendored.txt", "a vendored note")
        try text("R/sub/normal.txt", "a sub note")
        try text("R/sub/ignored.txt", "an ignored sub note")
        try text("R/tool.py", "print(1)\n")
        try text("R/sub/tool.py", "print(2)\n")
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private struct PISnapshot {
    var paths: Set<String> = []
    var total = 0

    init(_ rows: [(path: String, status: String)]) {
        total = rows.count
        paths = Set(rows.map { piResolved($0.path) })
    }
}

/// Waits until a row exists, none is pending and the rows have not changed for `quiet` seconds (300 s of slack).
private func piSettle(_ helper: HelperProcess, home: String, quiet: TimeInterval = 4, cap: TimeInterval = 300)
    -> (snapshot: PISnapshot, settled: Bool, note: String) {
    let started = Date()
    var lastChange = Date()
    var last = ""
    var db: PIDB?
    var snapshot = PISnapshot([])
    while Date().timeIntervalSince(started) < cap {
        if db == nil { db = PIDB(path: piIndexFile(home: home)) }
        if let rows = db?.rows() {
            snapshot = PISnapshot(rows)
            let key = rows.map { "\($0.path)|\($0.status)" }.sorted().joined(separator: "\n")
            if key != last { last = key; lastChange = Date() }
            let pending = rows.filter { $0.status == "pending" }.count
            if !rows.isEmpty && pending == 0 && Date().timeIntervalSince(lastChange) >= quiet {
                return (snapshot, true, "")
            }
        }
        if !helper.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            if !helper.isRunning { return (snapshot, false, "the helper exited; stderr: \(helper.errors)") }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return (snapshot, false, "no settled index within \(Int(cap)) s; rows \(snapshot.total); stderr: \(helper.errors)")
}

/// Once per test process one photo goes through a real helper first (a cold first photo can take tens of seconds).
private let piHelperWarm: Bool = {
    guard let tree = try? PITree() else { return false }
    defer { tree.remove() }
    guard (try? tree.photo("warm/warm.jpg")) != nil, let helper = try? piStartHelper(home: tree.home) else { return false }
    defer { helper.stop() }
    helper.send(piFoldersLine([(tree.path("warm"), false)]))
    let deadline = Date().addingTimeInterval(150)
    var lastChange = Date()
    var lastDone = -1
    var db: PIDB?
    while Date() < deadline {
        if db == nil { db = PIDB(path: piIndexFile(home: tree.home)) }
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

/// Starts a helper over `tree`, sends one `folders` line with these picks (code ticks off) and settles.
private func piRun(_ tree: PITree, picks: [String]) throws -> PISnapshot {
    _ = piHelperWarm
    let helper = try piStartHelper(home: tree.home)
    defer { helper.stop() }
    helper.send(piFoldersLine(picks.map { ($0, false) }))
    let settled = piSettle(helper, home: tree.home)
    #expect(settled.settled, "\(settled.note)")
    return settled.snapshot
}

private func piPaths(_ tree: PITree, _ relatives: [String]) -> Set<String> {
    Set(relatives.map { piResolved(tree.path($0)) })
}

private func piDescribe(_ paths: Set<String>, under tree: PITree) -> String {
    paths.map { String($0.dropFirst($0.hasPrefix(tree.base) ? tree.base.count + 1 : 0)) }.sorted().joined(separator: ", ")
}

// What git lists and the rules keep, written by hand from the tree above.
private let piWantInRepoPicks = ["R/tracked.jpg", "R/fresh.jpg", "R/sub/normal.jpg", "R/notes.txt", "R/sub/normal.txt"]

private let piWantLoneSub = ["R/sub/normal.jpg", "R/sub/ignored.png", "R/sub/normal.txt", "R/sub/ignored.txt"]

private let piWantSubInRepoScan = ["R/sub/normal.jpg", "R/sub/normal.txt"]

// MARK: walker

private func piPick(_ path: String) -> HelperFolder { HelperFolder(path: path, code: false) }

private func piScanNames(_ tree: PITree, root: String, picks: [HelperFolder]) -> Set<String> {
    let result = Walker.scan(root: root, mode: .read, picks: picks)
    return Set(result.files.map { piResolved($0.path) })
}

@Suite("PickInsideRepoTests", .serialized)
struct PickInsideRepoTests {

    // MARK: through the helper alone

    @Test func picksRThenRSubGiveOnlyThePicturesGitListsAndTheIgnoredOneOfSubIsNotARow() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let shot = try piRun(tree, picks: [tree.path("R"), tree.path("R/sub")])
        let want = piPaths(tree, piWantInRepoPicks)
        #expect(shot.paths == want,
                "missing [\(piDescribe(want.subtracting(shot.paths), under: tree))], unexpected [\(piDescribe(shot.paths.subtracting(want), under: tree))]")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) pictures")
    }

    @Test func picksRSubThenRGiveTheSameRows() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let shot = try piRun(tree, picks: [tree.path("R/sub"), tree.path("R")])
        let want = piPaths(tree, piWantInRepoPicks)
        #expect(shot.paths == want,
                "missing [\(piDescribe(want.subtracting(shot.paths), under: tree))], unexpected [\(piDescribe(shot.paths.subtracting(want), under: tree))]")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) pictures")
    }

    @Test func aLonePickInsideARepoKeepsTodaysBehaviourItIsNotARepoAndNothingIsDropped() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let shot = try piRun(tree, picks: [tree.path("R/sub")])
        let want = piPaths(tree, piWantLoneSub)
        #expect(shot.paths == want,
                "a lone pick R/sub is not a repo: missing [\(piDescribe(want.subtracting(shot.paths), under: tree))], unexpected [\(piDescribe(shot.paths.subtracting(want), under: tree))]")
        #expect(shot.total == want.count, "\(shot.total) rows for \(want.count) pictures")
    }

    // MARK: through Walker

    @Test func theScanOfRWithBothPicksReturnsOnlyThePicturesGitListsAndTheVendoredOneIsOut() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let got = piScanNames(tree, root: tree.path("R"), picks: [piPick(tree.path("R")), piPick(tree.path("R/sub"))])
        let want = piPaths(tree, piWantInRepoPicks)
        #expect(got == want,
                "missing [\(piDescribe(want.subtracting(got), under: tree))], unexpected [\(piDescribe(got.subtracting(want), under: tree))]")
    }

    // scan of the inner root (see the note at the top: drop these two if the fix is made after the scans)
    @Test func theScanOfTheInnerRootWithTheRepoAmongThePicksDropsTheIgnoredPicture() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let got = piScanNames(tree, root: tree.path("R/sub"), picks: [piPick(tree.path("R")), piPick(tree.path("R/sub"))])
        #expect(got == piPaths(tree, piWantSubInRepoScan),
                "scan of R/sub with R among the picks: got [\(piDescribe(got, under: tree))], want only R/sub/normal.jpg and R/sub/normal.txt")
    }

    // scan of the inner root
    @Test func theScanOfTheInnerRootGivesTheSameWhicheverOrderThePicksAreListedIn() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let got = piScanNames(tree, root: tree.path("R/sub"), picks: [piPick(tree.path("R/sub")), piPick(tree.path("R"))])
        #expect(got == piPaths(tree, piWantSubInRepoScan),
                "scan of R/sub, picks R/sub then R: got [\(piDescribe(got, under: tree))], want only R/sub/normal.jpg and R/sub/normal.txt")
    }

    @Test func aLoneScanOfTheInnerRootStaysAsItIsNotARepoAndBothPicturesAreReturned() throws {
        let tree = try PITree()
        defer { tree.remove() }
        try tree.buildRepoR()
        let got = piScanNames(tree, root: tree.path("R/sub"), picks: [piPick(tree.path("R/sub"))])
        #expect(got == piPaths(tree, piWantLoneSub),
                "lone pick R/sub: got [\(piDescribe(got, under: tree))]")
    }
}

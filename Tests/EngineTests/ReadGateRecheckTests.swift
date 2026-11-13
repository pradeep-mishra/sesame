import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import SesameEngine

// plan-3 fix round, t17-5, tester step (B): the read-time gate (S8.3, S8.5, and the non-goal of never downloading a
// cloud-only file). Written from the reviewer's finding "The read-time gate re-checks less than the walk does" (reviewer-plan-3-1
// report), the spec and design, and the sealed IndexOverlapTests / ReconcileUnreadableTests for style and names. No product
// source is read; every expected value is written by hand.
//
// The rule these tests pin: the helper keeps the picks it was given and re-checks `Rules.admit(path:picks:)` before each read,
// so a pending row whose file is now under a hidden folder, `Caches`, a `.app` bundle or a vendored folder, or is now
// cloud-only (sparse or dataless), is never opened. The row stays as it is.
//
// How the state is built (no product source needed):
//   - The helper is NOT running while the rows are planted. A pending `photo` row is added with `IndexStore.addFile(...)` in the
//     helper's temp HOME (the way ReconcileUnreadableTests does), for a file that exists on disk with the stat values the row
//     carries. Then the bundled release helper (`SesameHelper index`, SESAME_FAKE_EMBEDDER=1, temp HOME, no app) gets a
//     `folders` line.
//   - A pending row survives the helper's own walk only when the walk could not see its folder or file: a sparse file is set
//     aside by the walk (rows under it are kept as they are, ReconcileUnreadableTests), and a repo git cannot answer for is
//     skipped as unreadable (its rows are kept as they are). The repo here has a garbage `.git/HEAD`: the real `git ls-files`
//     exits 128 for it (checked in the test before anything else), and `.git` is still the repo marker the rules look for.
//
// How "never opened" is seen (nothing reads product source, and no FIFO is used): through the row status only.
// Every photo here is a real, readable picture, so a file the helper opens becomes `done`. A row still `pending`
// after the helper has finished its other work was never read. (The sparse file is not decodable: if it were opened its
// row would leave `pending` too, as `could not read`.)
// The access time is deliberately not used as a witness: measured on this Mac, another process (an outside reader) reads new
// files in the temp folder within about a second, so a file's access time changes without the helper being involved.
// A control sits in each state: a pending row for a plain, admitted picture in the same repo (or a new plain picture beside
// the cloud-only one). It must end `done`, so a `pending` row elsewhere is the gate and never a helper that did nothing.

// MARK: running (copied from IndexOverlapTests, which keeps its own copy private)

private func rgJSONString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}

private func rgFoldersLine(_ folders: [String]) -> String {
    let items = folders.map { "{\"path\":\(rgJSONString($0)),\"code\":false}" }.joined(separator: ",")
    return "{\"cmd\":\"folders\",\"folders\":[\(items)]}"
}

private func rgStartHelper(home: String) throws -> HelperProcess {
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

private func rgIndexFile(home: String) -> String {
    home + "/Library/Application Support/Sesame/index.sqlite"
}

private final class RGDB {
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

private func rgPhoto(seed: Int, side: Int = 64) -> Data {
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

private func rgResolved(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private final class RGTree {
    let root: String
    let home: String
    private var seed = 900

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-readgate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = rgResolved(url.path)
        home = root + "/home"
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: root + "/t", withIntermediateDirectories: true)
    }

    var base: String { root + "/t" }

    func path(_ relative: String) -> String { base + "/" + relative }

    /// A real photo.
    @discardableResult
    func photo(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        seed += 1
        try rgPhoto(seed: seed).write(to: URL(fileURLWithPath: full))
        return full
    }

    /// A file with a size and no blocks (what the walk sets aside as cloud-only). False when this volume does not make one.
    func sparse(_ relative: String) throws -> String? {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let fd = open(full, O_CREAT | O_WRONLY, 0o600)
        try #require(fd >= 0, "could not create the sparse file")
        ftruncate(fd, 1_048_576)
        close(fd)
        var info = stat()
        try #require(stat(full, &info) == 0)
        guard info.st_size > 0 && info.st_blocks == 0 else { return nil }
        return full
    }

    func text(_ relative: String, _ content: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: full))
    }

    func git(_ repoRelative: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", path(repoRelative)] + args
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
        return process.terminationStatus
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

/// Adds a pending photo row for each existing path, in the helper's temp HOME, the helper not running.
private func rgPlantPending(home: String, paths: [String]) throws {
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home, 1)
    defer { if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") } }
    let store = try IndexStore()
    defer { store.close() }
    for path in paths {
        var info = stat()
        try #require(stat(path, &info) == 0, "setup: cannot stat \(path)")
        let mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        _ = try store.addFile(path: path, kind: "photo", size: Int64(info.st_size), mtimeNs: mtimeNs,
                              inode: Int64(info.st_ino), device: Int64(info.st_dev), status: "pending")
    }
}

private func rgStatuses(home: String) -> [String: String]? {
    guard let rows = RGDB(path: rgIndexFile(home: home))?.rows() else { return nil }
    var out: [String: String] = [:]
    for row in rows { out[rgResolved(row.path)] = row.status }
    return out
}

/// Waits until every control path is `done` and the rows have not changed for `quiet` seconds (a generous slack, 300 s cap).
private func rgSettle(_ helper: HelperProcess, home: String, controls: [String], quiet: TimeInterval = 8,
                      cap: TimeInterval = 300) -> (statuses: [String: String], settled: Bool, note: String) {
    let started = Date()
    var lastChange = Date()
    var last = ""
    var statuses: [String: String] = [:]
    let wanted = controls.map(rgResolved)
    while Date().timeIntervalSince(started) < cap {
        if let now = rgStatuses(home: home) {
            statuses = now
            let key = now.map { "\($0.key)|\($0.value)" }.sorted().joined(separator: "\n")
            if key != last { last = key; lastChange = Date() }
            if wanted.allSatisfy({ now[$0] == "done" }) && Date().timeIntervalSince(lastChange) >= quiet {
                return (statuses, true, "")
            }
        }
        if !helper.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            if !helper.isRunning {
                return (rgStatuses(home: home) ?? statuses, false, "the helper exited before the controls were done; stderr: \(helper.errors)")
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return (statuses, false, "no settled index within \(Int(cap)) s; stderr: \(helper.errors)")
}

/// Once per test process one photo goes through a real helper first (a cold first photo can take tens of seconds).
private let rgHelperWarm: Bool = {
    guard let tree = try? RGTree() else { return false }
    defer { tree.remove() }
    guard (try? tree.photo("warm/warm.jpg")) != nil, let helper = try? rgStartHelper(home: tree.home) else { return false }
    defer { helper.stop() }
    helper.send(rgFoldersLine([tree.path("warm")]))
    let deadline = Date().addingTimeInterval(150)
    var lastChange = Date()
    var lastDone = -1
    var db: RGDB?
    while Date() < deadline {
        if db == nil { db = RGDB(path: rgIndexFile(home: tree.home)) }
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

/// Starts a helper over `tree`, sends one `folders` line, settles, returns the statuses.
private func rgRun(_ tree: RGTree, picks: [String], controls: [String]) throws -> [String: String] {
    _ = rgHelperWarm
    let helper = try rgStartHelper(home: tree.home)
    defer { helper.stop() }
    helper.send(rgFoldersLine(picks))
    let settled = rgSettle(helper, home: tree.home, controls: controls)
    #expect(settled.settled, "\(settled.note) statuses: \(settled.statuses)")
    return settled.statuses
}

private func rgDescribe(_ statuses: [String: String], under tree: RGTree) -> String {
    statuses.map { "\($0.key.hasPrefix(tree.base) ? String($0.key.dropFirst(tree.base.count + 1)) : $0.key)=\($0.value)" }
        .sorted().joined(separator: ", ")
}

@Suite("ReadGateRecheckTests", .serialized)
struct ReadGateRecheckTests {

    // MARK: a file that is now cloud-only

    @Test func aPendingRowOfACloudOnlyFileIsNotOpenedAndStaysPendingWhileAPlainControlIsDone() throws {
        let tree = try RGTree()
        defer { tree.remove() }
        guard let cloud = try tree.sparse("pics/cloud.jpg") else {
            Issue.record("this volume makes no sparse file (a size and no blocks): the cloud-only stand-in cannot be built")
            return
        }
        let control = try tree.photo("pics/control.jpg")
        try rgPlantPending(home: tree.home, paths: [cloud])
        try #require(rgStatuses(home: tree.home)?[rgResolved(cloud)] == "pending", "setup: the planted row is not pending")

        let statuses = try rgRun(tree, picks: [tree.path("pics")], controls: [control])
        #expect(statuses[rgResolved(control)] == "done", "control: the plain new picture should be done, got \(rgDescribe(statuses, under: tree))")
        #expect(statuses[rgResolved(cloud)] == "pending",
                "the cloud-only file's pending row must stay pending (never opened), got \(rgDescribe(statuses, under: tree))")
    }

    // MARK: files that are now under an excluded place of a repo git cannot answer for

    @Test func pendingRowsUnderHiddenCachesAppAndVendoredPlacesOfARepoGitCannotAnswerForAreNotOpened() throws {
        let tree = try RGTree()
        defer { tree.remove() }
        try FileManager.default.createDirectory(atPath: tree.path("R"), withIntermediateDirectories: true)
        try #require(try tree.git("R", ["init", "-q", "-b", "main"]) == 0, "setup: git init failed")
        // a garbage HEAD: git no longer takes the folder for a repository, but `.git` is still there as the repo marker
        try tree.text("R/.git/HEAD", "this is not a ref\n")
        try #require(try tree.git("R", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) != 0,
                     "setup: git still answers for R, so the repo is not a repo git cannot answer for")

        let control = try tree.photo("R/ok.jpg")
        let excluded = [
            try tree.photo("R/.hid/h.jpg"),
            try tree.photo("R/Caches/c.jpg"),
            try tree.photo("R/Thing.app/Contents/a.jpg"),
            try tree.photo("R/node_modules/v.jpg"),
        ]
        // the rules decide this, whatever the helper does (setup, hand-written expectations)
        let picks = [HelperFolder(path: tree.path("R"), code: false)]
        for path in excluded { #expect(Rules.admit(path: path, picks: picks) == nil, "setup: \(path) should be refused by the rules") }
        #expect(Rules.admit(path: control, picks: picks) != nil, "setup: the control should be admitted by the rules")

        try rgPlantPending(home: tree.home, paths: [control] + excluded)
        let planted = try #require(rgStatuses(home: tree.home), "setup: no rows were planted")
        try #require(planted.count == 5 && planted.values.allSatisfy { $0 == "pending" }, "setup: planted rows \(rgDescribe(planted, under: tree))")

        let statuses = try rgRun(tree, picks: [tree.path("R")], controls: [control])
        #expect(statuses[rgResolved(control)] == "done", "control: the admitted picture should be done, got \(rgDescribe(statuses, under: tree))")
        for path in excluded {
            #expect(statuses[rgResolved(path)] == "pending",
                    "\(path.dropFirst(tree.base.count + 1)) must stay pending (never opened), got \(rgDescribe(statuses, under: tree))")
        }
    }
}

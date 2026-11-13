import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-5-t3 repair, tester step: the kit's idle rule. kit-launch.sh keeps the index helper's stdin open and closes it when
// the index is idle; an end of stdin drops the step in flight, so the rule must not call an index idle while a file is still
// pending or partial, however quiet the counts are, until a long quiet window (90 s, KIT_IDLE_LONG_QUIET_S in
// scripts/kit-lib/common.sh) says the helper is stuck. The rule is read through scripts/kit-index.sh as
//     wait idle <quiet seconds>
// (exit 0 when idle: the counts have not moved for <quiet> s and no file row is pending or partial, or, when one is, the
// counts have not moved for the long window; the long window comes from KIT_IDLE_LONG_QUIET_S, default 90, so a test can
// shorten it) and through kit-launch.sh helper index, which must use it with the 10 s quiet it has always used.
//
// Every state below is hand-written by this file: rows written into a throwaway index (the public IndexStore calls the
// engine tests already use), copied into a throwaway kit root, and read by the scripts as child processes. No app is
// started, no real helper is run (kit-launch gets a fake helper that only reads its stdin), no model is read, and the real
// kit root and home are never touched. Times are measured by the test; the bounds are the stated windows (10 s quiet, the
// long window) with room for a slow machine above them.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let indexScript = projectRoot.appendingPathComponent("scripts/kit-index.sh").path
private let launchScript = projectRoot.appendingPathComponent("scripts/kit-launch.sh").path
private let libFolder = projectRoot.appendingPathComponent("scripts/kit-lib").path

private struct Ran: Sendable {
    let status: Int32
    let output: String
    let seconds: Double
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 240) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitidle-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "KIT_IDLE_LONG_QUIET_S")
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    let started = Date()
    try p.run()
    let deadline = started.addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    let seconds = Date().timeIntervalSince(started)
    try? handle.synchronize()
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text, seconds: seconds)
}

// MARK: the rig

private struct Row {
    let name: String
    let status: String
    let passages: Int
}

private struct Rig: Sendable {
    let base: String
    var kit: String { base + "/sesame-kit-idle" }
    var home: String { base + "/home" }
    var tmp: String { base + "/tmp" }
    var db: String { home + "/Library/Application Support/Sesame/index.sqlite" }
    var env: [String: String] { ["KIT_ROOT": kit, "HOME": home, "TMPDIR": tmp + "/", "KIT_NO_EVIDENCE": "1"] }

    func index(_ args: String..., extra: [String: String] = [:], limit: TimeInterval = 240) throws -> Ran {
        try run("/bin/bash", [indexScript] + args, env: env.merging(extra) { $1 }, limit: limit)
    }

    /// Sets the status of a file row by hand, as the helper does while it works.
    func setStatus(_ name: String, _ status: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(handle); return }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_exec(handle, "update files set status='\(status)' where path='/idle/\(name)';", nil, nil, nil)
    }
}

/// A throwaway kit root whose home holds an index of exactly `rows` (none: no index file). The index is written under the
/// engine tests' throwaway HOME, copied out, and the script runs after that lock is released, so slow waits can run side by side.
private func withIdleRig(_ rows: [Row]?, walkDone: Bool = true, _ body: (Rig) throws -> Void) throws {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-idle-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: made) }
    let rig = Rig(base: made.resolvingSymlinksInPath().path)
    let sesame = rig.home + "/Library/Application Support/Sesame"
    try fm.createDirectory(atPath: sesame, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: rig.tmp, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: rig.kit + "/run", withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: rig.kit + "/home", withDestinationPath: rig.home)
    var built = true
    if let rows {
        try withTempHome { t in
            guard try createFolder(t) else { built = false; return }
            let store = try IndexStore()
            var inode: Int64 = 0
            for row in rows {
                inode += 1
                let file = try store.addFile(path: "/idle/" + row.name, kind: "photo", size: 10, mtimeNs: 1_700_000_000_000_000_000,
                                             inode: inode, device: 1, status: row.status)
                for p in 0..<row.passages {
                    _ = try store.addPassage(fileID: file, source: "name", start: Double(p), end: Double(p), modality: "none",
                                             vector: nil, name: "\(row.name) \(p)", body: "")
                }
            }
            if walkDone { try store.setMeta("walk_done_at", "1700000123") }
            store.close()
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: t.folder.path + "/index.sqlite" + suffix) {
                try fm.copyItem(atPath: t.folder.path + "/index.sqlite" + suffix, toPath: sesame + "/index.sqlite" + suffix)
            }
        }
    }
    guard built else { return }
    try body(rig)
}

private func rows(_ statuses: [String]) -> [Row] {
    statuses.enumerated().map { Row(name: "f\($0.offset).jpg", status: $0.element, passages: 2) }
}

private let withPartial = rows(["done", "done", "done", "partial"])
private let withPending = rows(["done", "done", "done", "pending"])
private let noWorkLeft = rows(["done", "done", "done", "could_not_read", "needs_permission"])
private let allDone = rows(["done", "done", "done", "done"])

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    func get() -> Double? { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("KitIdleRuleTests")
struct KitIdleRuleTests {

    // MARK: the rule on hand-written index states (kit-index.sh wait idle)

    @Test func theOldStableRuleClosesOnAPartialRowAfterItsQuietWindowWhichIsTheDefect() throws {
        try withIdleRig(withPartial) { rig in
            let ran = try rig.index("wait", "stable", "2")
            #expect(ran.status == 0, "wait stable 2 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds < 8, "wait stable 2 took \(ran.seconds) s on a quiet index")
        }
    }

    @Test func aPartialRowStableForTenSecondsDoesNotCloseUntilTheLongQuietWindow() throws {
        try withIdleRig(withPartial) { rig in
            let ran = try rig.index("wait", "idle", "10", extra: ["KIT_IDLE_LONG_QUIET_S": "16"])
            #expect(ran.status == 0, "wait idle 10 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 15.5, "wait idle 10 closed after \(ran.seconds) s with a partial row and a 16 s long window: \(ran.output)")
            #expect(ran.seconds < 60, "wait idle 10 took \(ran.seconds) s: the long window did not end it: \(ran.output)")
        }
    }

    @Test func aPendingRowStableForTenSecondsDoesNotCloseUntilTheLongQuietWindow() throws {
        try withIdleRig(withPending) { rig in
            let ran = try rig.index("wait", "idle", "10", extra: ["KIT_IDLE_LONG_QUIET_S": "16"])
            #expect(ran.status == 0, "wait idle 10 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 15.5, "wait idle 10 closed after \(ran.seconds) s with a pending row and a 16 s long window: \(ran.output)")
            #expect(ran.seconds < 60, "wait idle 10 took \(ran.seconds) s: the long window did not end it: \(ran.output)")
        }
    }

    @Test func theSameIndexWithNoWorkLeftClosesAfterTenSecondsOfQuiet() throws {
        try withIdleRig(noWorkLeft) { rig in
            let ran = try rig.index("wait", "idle", "10", extra: ["KIT_IDLE_LONG_QUIET_S": "60"])
            #expect(ran.status == 0, "wait idle 10 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 9.5, "wait idle 10 closed after \(ran.seconds) s: before 10 s of quiet: \(ran.output)")
            #expect(ran.seconds < 25, "wait idle 10 took \(ran.seconds) s with no work left and a quiet index: \(ran.output)")
        }
    }

    @Test func aPlainIndexWithEveryFileDoneClosesAfterTenSecondsAsToday() throws {
        try withIdleRig(allDone) { rig in
            let ran = try rig.index("wait", "idle", "10")
            #expect(ran.status == 0, "wait idle 10 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 9.5, "wait idle 10 closed after \(ran.seconds) s: before 10 s of quiet: \(ran.output)")
            #expect(ran.seconds < 25, "wait idle 10 took \(ran.seconds) s on a finished quiet index: \(ran.output)")
        }
    }

    @Test func noIndexFileYetCountsAsNoWorkAndClosesAfterTenSeconds() throws {
        try withIdleRig(nil) { rig in
            let ran = try rig.index("wait", "idle", "10")
            #expect(ran.status == 0, "wait idle 10 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 9.5, "wait idle 10 closed after \(ran.seconds) s: before 10 s of quiet: \(ran.output)")
            #expect(ran.seconds < 25, "wait idle 10 took \(ran.seconds) s with no index: \(ran.output)")
        }
    }

    @Test func withWorkLeftAndTheDefaultLongWindowOfNinetySecondsItClosesAtNinety() throws {
        try withIdleRig(withPartial) { rig in
            let ran = try rig.index("wait", "idle", "10")
            #expect(ran.status == 0, "wait idle 10 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 89.5, "wait idle 10 closed after \(ran.seconds) s with a partial row: before the 90 s long window: \(ran.output)")
            #expect(ran.seconds < 150, "wait idle 10 took \(ran.seconds) s: the 90 s long window did not end it: \(ran.output)")
        }
    }

    private func movingCounts(leaveOpen: Bool) throws {
        let states = leaveOpen ? ["partial", "partial", "partial", "partial"] : ["pending", "pending", "pending", "pending"]
        try withIdleRig(rows(states)) { rig in
            let finished = Box()
            let started = Date()
            let writer = Thread {
                let flips = leaveOpen ? 3 : 4
                for i in 0..<flips {
                    Thread.sleep(forTimeInterval: 1.5)
                    rig.setStatus("f\(i).jpg", "done")
                }
                finished.set(Date().timeIntervalSince(started))
            }
            writer.start()
            let ran = try rig.index("wait", "idle", "2", extra: ["KIT_IDLE_LONG_QUIET_S": "6"])
            let wrote = try #require(finished.get(), "setup: the writer had not finished when the wait ended (\(ran.seconds) s): the wait closed while the counts were moving")
            let window = leaveOpen ? 6.0 : 2.0
            #expect(ran.status == 0, "wait idle 2 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= wrote + window - 0.7,
                    "closed at \(ran.seconds) s; the last change was at \(wrote) s and the window is \(window) s: the quiet is counted from the last change, not from the start: \(ran.output)")
            #expect(ran.seconds < wrote + window + 20, "closed at \(ran.seconds) s, long after the last change at \(wrote) s: \(ran.output)")
        }
    }

    @Test func movingCountsWithWorkLeftRestartTheLongQuietWindow() throws {
        try movingCounts(leaveOpen: true)
    }

    @Test func movingCountsThatEndWithNoWorkLeftCloseAfterTheQuietWindowFromTheLastChange() throws {
        try movingCounts(leaveOpen: false)
    }

    // MARK: kit-launch.sh helper index, with a fake helper that only reads its stdin

    /// A copy of the kit's layout whose helper is a script: it prints the walked event, then reads stdin to its end and
    /// writes a file (it closes the pipe end it inherits from the launcher, as the real helper must for an end of stdin to reach it). The scripts and kit-lib are links to the real ones, so the real kit-launch.sh and kit-index.sh run.
    private func launch(_ rig: Rig, long: String) throws -> (ran: Ran, sawEnd: Bool) {
        let fm = FileManager.default
        let project = rig.base + "/project"
        try fm.createDirectory(atPath: project + "/scripts", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: project + "/dist/Sesame.app", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: project + "/scripts/kit-launch.sh", withDestinationPath: launchScript)
        try fm.createSymbolicLink(atPath: project + "/scripts/kit-index.sh", withDestinationPath: indexScript)
        try fm.createSymbolicLink(atPath: project + "/scripts/kit-lib", withDestinationPath: libFolder)
        let macos = rig.kit + "/apps/Sesame.app/Contents/MacOS"
        try fm.createDirectory(atPath: macos, withIntermediateDirectories: true)
        let helper = macos + "/SesameHelper"
        let text = "#!/bin/bash\nexec 7>&-\necho '{\"event\":\"walked\"}'\ncat > /dev/null\necho closed > \"$KIT_ROOT/run/helper-saw-end\"\n"
        try text.write(toFile: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        try fm.createDirectory(atPath: rig.kit + "/fixtures/golden/photos", withIntermediateDirectories: true)
        try "\(rig.kit)/evidence\n".write(toFile: rig.kit + "/run/evidence-dir", atomically: true, encoding: .utf8)
        let ran = try run("/bin/bash", [project + "/scripts/kit-launch.sh", "helper", "index", "--folders", "golden/photos", "--no-model"],
                          env: rig.env.merging(["KIT_IDLE_LONG_QUIET_S": long]) { $1 }, limit: 240)
        return (ran, fm.fileExists(atPath: rig.kit + "/run/helper-saw-end"))
    }

    @Test func theLaunchKeepsTheHelpersStdinOpenWhileAPartialRowIsLeftUntilTheLongWindow() throws {
        try withIdleRig(withPartial) { rig in
            let result = try launch(rig, long: "18")
            #expect(result.ran.status == 0, "kit-launch.sh helper index exited \(result.ran.status): \(result.ran.output)")
            #expect(result.sawEnd, "the fake helper never saw the end of its stdin: \(result.ran.output)")
            #expect(result.ran.seconds >= 17.5, "the run took \(result.ran.seconds) s: stdin was closed before the 18 s long window with a partial row left: \(result.ran.output)")
            #expect(result.ran.seconds < 80, "the run took \(result.ran.seconds) s: the long window did not end it: \(result.ran.output)")
        }
    }

    @Test func theLaunchClosesTheHelpersStdinAfterTenQuietSecondsWhenNoWorkIsLeft() throws {
        try withIdleRig(noWorkLeft) { rig in
            let result = try launch(rig, long: "60")
            #expect(result.ran.status == 0, "kit-launch.sh helper index exited \(result.ran.status): \(result.ran.output)")
            #expect(result.sawEnd, "the fake helper never saw the end of its stdin: \(result.ran.output)")
            #expect(result.ran.seconds >= 9.5, "the run took \(result.ran.seconds) s: stdin was closed before 10 quiet seconds: \(result.ran.output)")
            #expect(result.ran.seconds < 30, "the run took \(result.ran.seconds) s with no work left: \(result.ran.output)")
        }
    }
}

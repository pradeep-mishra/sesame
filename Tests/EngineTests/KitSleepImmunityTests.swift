import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-5-t3 repair, tester step: the kit must survive a sleeping Mac. Found by the GroupATests diagnosis: the Mac slept 15
// minutes in the middle of a golden prepare; scripts/kit-index.sh `wait idle` (and `wait stable`) measured quiet as the
// difference of the shell's SECONDS clock, so after the wake they counted 15 minutes of quiet, closed the helper's stdin with
// work left, and the helper dropped its unfinished step. Two repairs are read here.
//
// A. Quiet time is immune to sleep. The wait keeps a running quiet total, adds 1 for a look that took more than 5 s longer
// than its half-second pause (a sleep or a stall), and resets it when the counts change; the 3600 s "still changing" cap
// counts the same way. A test cannot sleep the Mac, so it uses the test-only hook documented in the header of
// scripts/kit-index.sh: KIT_TEST_CLOCK_JUMP names a file; when the file exists the wait reads the number of seconds in it,
// adds them to the shell's clock as a jump, and removes the file. The tests write the file before the wait starts or while
// it runs, so no test sleeps for the length of the jump.
//
// B. scripts/kit-golden.sh `prepare` (the photo-scoped one) runs the helper again while the 40 golden photos are not all done,
// as `prepare --whole` does: it stops after 2 runs in a row with no photo more done, and runs at most 10 times, so a helper
// that was closed early costs a run, not the prepare. The helper here is a script ($KIT_ROOT/apps/Sesame.app/.../SesameHelper,
// as in KitIdleRuleTests) that marks the rows of a hand-made index done as a plan file says, and exits early when the plan
// stops short of 40. kit-launch.sh, kit-index.sh and kit-golden.sh are the real ones; kit-reset.sh and kit-fixtures.sh are
// stubs that do nothing (the fixtures and the model files are made by this file). No app is started, the real helper and the
// model are never run, and the real kit root and home are never touched. Times are measured by the test.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let indexScript = projectRoot.appendingPathComponent("scripts/kit-index.sh").path
private let launchScript = projectRoot.appendingPathComponent("scripts/kit-launch.sh").path
private let goldenScript = projectRoot.appendingPathComponent("scripts/kit-golden.sh").path
private let libFolder = projectRoot.appendingPathComponent("scripts/kit-lib").path

private struct SleepRan: Sendable {
    let status: Int32
    let output: String
    let seconds: Double
}

private func sleepRun(_ exe: String, _ args: [String], env: [String: String], limit: TimeInterval) throws -> SleepRan {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitsleep-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for key in ["KIT_IDLE_LONG_QUIET_S", "KIT_TEST_CLOCK_JUMP"] { environment.removeValue(forKey: key) }
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
    return SleepRan(status: status, output: text, seconds: seconds)
}

private struct SleepRig: Sendable {
    let base: String
    var kit: String { base + "/sesame-kit-sleep" }
    var home: String { base + "/home" }
    var tmp: String { base + "/tmp" }
    var project: String { base + "/project" }
    var db: String { home + "/Library/Application Support/Sesame/index.sqlite" }
    var jump: String { base + "/clock-jump" }
    var env: [String: String] { ["KIT_ROOT": kit, "HOME": home, "TMPDIR": tmp + "/", "KIT_NO_EVIDENCE": "1"] }

    func index(_ args: String..., extra: [String: String] = [:], limit: TimeInterval = 120) throws -> SleepRan {
        try sleepRun("/bin/bash", [indexScript] + args, env: env.merging(extra) { $1 }, limit: limit)
    }

    func jumpEnv(_ extra: [String: String] = [:]) -> [String: String] {
        extra.merging(["KIT_TEST_CLOCK_JUMP": jump]) { $1 }
    }

    func writeJump(_ seconds: Int) {
        try? "\(seconds)\n".write(toFile: jump, atomically: true, encoding: .utf8)
    }

    func setStatus(_ path: String, _ status: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(handle); return }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_exec(handle, "update files set status='\(status)' where path='\(path)';", nil, nil, nil)
    }

    func countRows(_ status: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(handle); return -1 }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "select count(*) from files where status='\(status)';", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }
}

private struct SleepRow {
    let path: String
    let status: String
}

/// A throwaway kit root whose home holds an index of exactly `rows`, written under the engine tests' throwaway HOME, copied out
/// and read by the scripts as child processes.
private func withSleepRig(_ rows: [SleepRow], _ body: (SleepRig) throws -> Void) throws {
    try withSleepRig(rowsFor: { _ in rows }, body)
}

private func withSleepRig(rowsFor makeRows: (SleepRig) -> [SleepRow], _ body: (SleepRig) throws -> Void) throws {
    let fm = FileManager.default
    let made = fm.temporaryDirectory.appendingPathComponent("kit-sleep-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: made, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: made) }
    let rig = SleepRig(base: made.resolvingSymlinksInPath().path)
    let sesame = rig.home + "/Library/Application Support/Sesame"
    try fm.createDirectory(atPath: sesame, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: rig.tmp, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: rig.kit + "/run", withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: rig.kit + "/home", withDestinationPath: rig.home)
    var built = true
    try withTempHome { t in
        guard try createFolder(t) else { built = false; return }
        let store = try IndexStore()
        var inode: Int64 = 0
        for row in makeRows(rig) {
            inode += 1
            let file = try store.addFile(path: row.path, kind: "photo", size: 10, mtimeNs: 1_700_000_000_000_000_000,
                                         inode: inode, device: 1, status: row.status)
            for p in 0..<2 {
                _ = try store.addPassage(fileID: file, source: "name", start: Double(p), end: Double(p), modality: "none",
                                         vector: nil, name: "\(inode) \(p)", body: "")
            }
        }
        try store.setMeta("walk_done_at", "1700000123")
        store.close()
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: t.folder.path + "/index.sqlite" + suffix) {
            try fm.copyItem(atPath: t.folder.path + "/index.sqlite" + suffix, toPath: sesame + "/index.sqlite" + suffix)
        }
    }
    guard built else { return }
    try body(rig)
}

private func idleRows(_ statuses: [String]) -> [SleepRow] {
    statuses.enumerated().map { SleepRow(path: "/idle/f\($0.offset).jpg", status: $0.element) }
}

private let workLeft = idleRows(["done", "done", "done", "partial"])
private let noWorkLeft = idleRows(["done", "done", "done", "done"])

private final class SleepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    func get() -> Double? { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("KitSleepImmunityTests")
struct KitSleepImmunityTests {

    // MARK: A. the idle wait and a jump of the clock (a sleeping Mac)

    @Test func aFifteenMinuteJumpWithWorkLeftDoesNotEndTheIdleWaitBeforeTheLongWindow() throws {
        try withSleepRig(workLeft) { rig in
            rig.writeJump(900)
            let ran = try rig.index("wait", "idle", "2", extra: rig.jumpEnv(["KIT_IDLE_LONG_QUIET_S": "8"]))
            #expect(!FileManager.default.fileExists(atPath: rig.jump), "setup: the wait never read the clock-jump file, so no jump was made")
            #expect(ran.status == 0, "wait idle 2 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 7.5, "wait idle 2 ended after \(ran.seconds) s with a partial row left and an 8 s long window: the 900 s jump was counted as quiet: \(ran.output)")
            #expect(ran.seconds < 40, "wait idle 2 took \(ran.seconds) s: the long window did not end it: \(ran.output)")
        }
    }

    @Test func aJumpThatComesWhileTheWaitRunsDoesNotShortenTheLongWindow() throws {
        try withSleepRig(workLeft) { rig in
            let writer = Thread {
                Thread.sleep(forTimeInterval: 2.5)
                rig.writeJump(900)
            }
            writer.start()
            let ran = try rig.index("wait", "idle", "2", extra: rig.jumpEnv(["KIT_IDLE_LONG_QUIET_S": "8"]))
            #expect(!FileManager.default.fileExists(atPath: rig.jump), "setup: the wait never read the clock-jump file, so no jump was made")
            #expect(ran.status == 0, "wait idle 2 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 7.5, "wait idle 2 ended after \(ran.seconds) s: a 900 s jump at 2.5 s ended the 8 s long window at once: \(ran.output)")
            #expect(ran.seconds < 40, "wait idle 2 took \(ran.seconds) s: the long window did not end it: \(ran.output)")
        }
    }

    @Test func aFifteenMinuteJumpWithNoWorkLeftStillEndsTheIdleWaitOnlyAfterTheNormalQuiet() throws {
        try withSleepRig(noWorkLeft) { rig in
            rig.writeJump(900)
            let ran = try rig.index("wait", "idle", "3", extra: rig.jumpEnv(["KIT_IDLE_LONG_QUIET_S": "60"]))
            #expect(!FileManager.default.fileExists(atPath: rig.jump), "setup: the wait never read the clock-jump file, so no jump was made")
            #expect(ran.status == 0, "wait idle 3 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 2.5, "wait idle 3 ended after \(ran.seconds) s: the 900 s jump was counted as quiet: \(ran.output)")
            #expect(ran.seconds < 25, "wait idle 3 took \(ran.seconds) s on a finished quiet index: \(ran.output)")
        }
    }

    @Test func theLongQuietWindowStillEndsTheWaitWhenTheClockDoesNotJump() throws {
        try withSleepRig(workLeft) { rig in
            let ran = try rig.index("wait", "idle", "2", extra: rig.jumpEnv(["KIT_IDLE_LONG_QUIET_S": "6"]))
            #expect(ran.status == 0, "wait idle 2 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 5.5, "wait idle 2 ended after \(ran.seconds) s with a 6 s long window: \(ran.output)")
            #expect(ran.seconds < 30, "wait idle 2 took \(ran.seconds) s: the long window did not end it: \(ran.output)")
        }
    }

    @Test func aFifteenMinuteJumpDoesNotEndWaitStableBeforeItsQuietWindow() throws {
        try withSleepRig(noWorkLeft) { rig in
            rig.writeJump(900)
            let ran = try rig.index("wait", "stable", "6", extra: rig.jumpEnv())
            #expect(!FileManager.default.fileExists(atPath: rig.jump), "setup: the wait never read the clock-jump file, so no jump was made")
            #expect(ran.status == 0, "wait stable 6 exited \(ran.status): \(ran.output)")
            #expect(ran.seconds >= 3.5, "wait stable 6 ended after \(ran.seconds) s: the 900 s jump was counted as quiet (the jump may count 1 s, and the clock has whole seconds): \(ran.output)")
            #expect(ran.seconds < 25, "wait stable 6 took \(ran.seconds) s on a quiet index: \(ran.output)")
        }
    }

    @Test func aJumpPastThirtySixHundredSecondsWhileTheCountsMoveIsNotTheStillChangingCap() throws {
        let pending = idleRows(Array(repeating: "pending", count: 30))
        try withSleepRig(pending) { rig in
            let finished = SleepBox()
            let started = Date()
            let writer = Thread {
                for i in 0..<18 {
                    Thread.sleep(forTimeInterval: 0.3)
                    if i == 8 { rig.writeJump(4000) }
                    rig.setStatus("/idle/f\(i).jpg", "done")
                }
                finished.set(Date().timeIntervalSince(started))
            }
            writer.start()
            let ran = try rig.index("wait", "idle", "2", extra: rig.jumpEnv(["KIT_IDLE_LONG_QUIET_S": "6"]))
            let wrote = try #require(finished.get(), "setup: the writer had not finished when the wait ended (\(ran.seconds) s, exit \(ran.status)): \(ran.output)")
            #expect(!FileManager.default.fileExists(atPath: rig.jump), "setup: the wait never read the clock-jump file, so no jump was made")
            #expect(ran.status == 0, "wait idle 2 exited \(ran.status) (4 is the 3600 s cap): \(ran.output)")
            #expect(!ran.output.contains("3600"), "the 4000 s jump was counted against the 3600 s cap while the counts moved: \(ran.output)")
            #expect(ran.seconds >= wrote + 6 - 0.7, "closed at \(ran.seconds) s; the last change was at \(wrote) s and the long window is 6 s: \(ran.output)")
        }
    }

    // MARK: B. kit-golden.sh prepare (photo-scoped) runs the helper again while photos are left

    private static let helperText = #"""
        #!/bin/bash
        exec 7>&-
        read -r first
        case "$first" in
          *'"folders"'*) ;;
          *) echo '{"event":"unit","n":1}'; exit 0 ;;
        esac
        runs="$KIT_ROOT/run/fake-runs"
        n=$(( $(cat "$runs" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$runs"
        target=$(awk -v n="$n" '{ print (n <= NF) ? $n : $NF }' "$KIT_ROOT/run/fake-plan")
        db="$HOME/Library/Application Support/Sesame/index.sqlite"
        sqlite3 "$db" "update files set status='done' where id in (select id from files order by id limit $target);"
        echo '{"event":"walked"}'
        if [ "$target" -lt 40 ]; then exit 0; fi
        cat > /dev/null
        """#

    /// A kit layout the real kit-golden.sh prepare runs in: the real kit-golden.sh, kit-launch.sh, kit-index.sh and kit-lib, stubs for
    /// kit-reset.sh and kit-fixtures.sh, a fake helper that follows `plan` (the number of photos done after each run, the last
    /// number repeating; a number under 40 makes the helper exit at once, as a helper does when its stdin is closed early), whole
    /// model files (sparse) and an index of the 40 golden photos, all pending.
    private func prepare(plan: String, _ body: (SleepRig, SleepRan) throws -> Void) throws {
        let photos: (SleepRig) -> [SleepRow] = { rig in
            (0..<40).map { SleepRow(path: rig.kit + "/fixtures/golden/photos/p\(String(format: "%02d", $0)).jpg", status: "pending") }
        }
        try withSleepRig(rowsFor: photos) { rig in
            try body(rig, try self.runPrepare(rig, plan: plan))
        }
    }

    private func runPrepare(_ rig: SleepRig, plan: String) throws -> SleepRan {
        let fm = FileManager.default
        let scripts = rig.project + "/scripts"
        try fm.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rig.project + "/dist/Sesame.app/Contents/MacOS", withIntermediateDirectories: true)
        try "bundle\n".write(toFile: rig.project + "/dist/Sesame.app/Contents/MacOS/SesameHelper", atomically: true, encoding: .utf8)
        for (name, target) in [("kit-golden.sh", goldenScript), ("kit-launch.sh", launchScript), ("kit-index.sh", indexScript), ("kit-lib", libFolder)] {
            try fm.createSymbolicLink(atPath: scripts + "/" + name, withDestinationPath: target)
        }
        for name in ["kit-reset.sh", "kit-fixtures.sh"] {
            try "#!/bin/bash\nexit 0\n".write(toFile: scripts + "/" + name, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts + "/" + name)
        }
        let macos = rig.kit + "/apps/Sesame.app/Contents/MacOS"
        try fm.createDirectory(atPath: macos, withIntermediateDirectories: true)
        let helper = macos + "/SesameHelper"
        try Self.helperText.write(toFile: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        try fm.createDirectory(atPath: rig.kit + "/cache", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rig.kit + "/fixtures/golden/photos", withIntermediateDirectories: true)
        let models = try String(contentsOfFile: libFolder + "/models.tsv", encoding: .utf8)
        for line in models.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 2, let size = UInt64(cols[1]) else { continue }
            let file = rig.kit + "/cache/" + cols[0]
            fm.createFile(atPath: file, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
            try handle.truncate(atOffset: size)
            try handle.close()
        }
        try "S1\n".write(toFile: rig.kit + "/run/id", atomically: true, encoding: .utf8)
        try "v1\n".write(toFile: rig.kit + "/run/version", atomically: true, encoding: .utf8)
        try "\(rig.kit)/evidence\n".write(toFile: rig.kit + "/run/evidence-dir", atomically: true, encoding: .utf8)
        try plan.write(toFile: rig.kit + "/run/fake-plan", atomically: true, encoding: .utf8)
        return try sleepRun("/bin/bash", [scripts + "/kit-golden.sh", "prepare"],
                            env: rig.env.merging(["KIT_IDLE_LONG_QUIET_S": "10"]) { $1 }, limit: 300)
    }

    @Test func aPhotoPrepareWhoseHelperStopsEarlyOnItsFirstRunIsRunAgainAndEndsWithAllFortyDone() throws {
        try prepare(plan: "16 40") { rig, ran in
            let runs = (try? String(contentsOfFile: rig.kit + "/run/fake-runs", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(ran.status == 0, "kit-golden.sh prepare exited \(ran.status): \(ran.output)")
            #expect(rig.countRows("done") == 40, "the index holds \(rig.countRows("done")) done photos, not 40: \(ran.output)")
            #expect(runs == "2", "the helper was run \(runs ?? "no") times, expected 2 (16 of 40 done on the first run, the rest on the second): \(ran.output)")
            #expect(ran.output.contains("index.sqlite"), "prepare did not print the index path: \(ran.output)")
        }
    }

    @Test func aPhotoPrepareWithNoProgressInTwoRunsEndsWithAClearFailure() throws {
        try prepare(plan: "16 16 16 40") { rig, ran in
            let runs = (try? String(contentsOfFile: rig.kit + "/run/fake-runs", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(ran.status == 1, "kit-golden.sh prepare exited \(ran.status), expected 1: \(ran.output)")
            #expect(runs == "3", "the helper was run \(runs ?? "no") times, expected 3 (16 done, then two runs with no photo more done): \(ran.output)")
            #expect(ran.output.contains("no progress"), "the failure does not say the helper made no progress: \(ran.output)")
            #expect(ran.output.contains("16 of 40"), "the failure does not say how many of the 40 photos are done: \(ran.output)")
            #expect(rig.countRows("done") == 16, "the index holds \(rig.countRows("done")) done photos, expected the 16 of the first run")
        }
    }
}

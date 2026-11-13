import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-2 fix round A, tester step: item A9 (S8(d)). Written from the fix-round entry A9 and the reviewer's finding ("three
// helper warnings write a user file path to stderr"). No product source read for the expected values; the entry gives
// the rule: no path, name or text in any helper log or stderr line (a fixed word and a count instead).
//
// The helper (the bundled release one, `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME) runs over a folder holding: six ordinary
// photos, one photo the process may not open (`chmod 000`, ends needs_permission), one file named like a photo whose bytes
// are text (ends could_not_read), and one photo that vanishes after the walk (before it is read). Every one of the three odd
// files has the same marker word `zqxsecret` in its name, the folder has a long unique name, and the test then looks at
// everything the helper wrote on its own: all of stderr (read whole) and `index.log` (the typed log under the Sesame
// folder). Neither may hold the marker word, any of the three file names, or the photos folder path. The test also shows
// the helper really did meet the three cases (statuses), so a silent helper cannot pass by doing nothing.
// Needs a user who is not root (root reads through chmod 000).
//
// Two tests. The first is the entry's own plant. The second forces the failed index writes that the three warnings are on:
// the tester read Sources/SesameHelper/Index.swift lines 300 to 357 (and nothing else of it) to learn when the warnings are
// written: only when a write to the index throws, which a plain locked, vanished or damaged file does not cause, so the first test may pass today
// (it is then listed as a guard) and only the second can be red. The second holds the index's write lock from the test's
// own connection for 12 s at the moment a file is marked, which makes the helper's end write for that file fail after its
// busy timeout; it also requires that the helper wrote some warning at all, so a run that never reached a warning
// cannot pass.

private let nlMarker = "zqxsecret"

/// The test's own write connection: takes the index's write lock (`BEGIN IMMEDIATE`) and keeps it for `seconds`, then rolls
/// back. While it is held, every write the helper makes waits for its busy timeout and then fails. Returns an error text, or nil.
private func nlHoldWriteLock(_ path: String, seconds: TimeInterval) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close_v2(db); return "cannot open the index" }
    defer { sqlite3_close_v2(db) }
    sqlite3_busy_timeout(db, 30_000)
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return "cannot take the write lock: \(String(cString: sqlite3_errmsg(db)))" }
    Thread.sleep(forTimeInterval: seconds)
    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    return nil
}

extension EncodeHelperTests {
@Suite("HelperNoPathLogTests", .serialized)
struct HelperNoPathLogTests {

    // The three warnings the reviewer found (could not store, could not mark, could not mark) are written only when a write to
    // the index FAILS, so the plain locked/vanished/damaged files above may never reach them. This test makes the helper's
    // writes fail: the moment a file is marked (the helper is reading it, after its marker write), the test takes the index's
    // write lock and holds it past the helper's busy timeout. The file's end write (stored, could_not_read or needs_permission)
    // then fails and the helper warns. 30 ordinary photos, one locked, one damaged; every name carries the marker word.
    @Test func aFailedIndexWriteWarnsWithoutAnyPathOrNameInStderrOrIndexLog() throws {
        guard getuid() != 0 else {
            Issue.record("this test runs as root, and root reads through chmod 000: it cannot show anything; run it as the person")
            return
        }
        _ = atHelperWarm
        let executable = KitPaths.bundledHelper
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AtError("the bundled helper is missing: \(executable.path) (run scripts/bundle.sh)")
        }
        let world = try AtWorld()
        defer { world.remove() }
        let ordinary = atNames("zqxsecret-ordinary", 1...30)
        let locked = "zqxsecret-locked", damaged = "zqxsecret-damaged"
        let urls = try atMakePhotos(in: world.photos, names: ordinary + [locked, damaged], seedBase: 1300)
        try Data("this is text, not a picture, in a file that is named like one".utf8).write(to: urls[31])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - 31)], ofItemAtPath: urls[31].path)
        world.lock(urls[30])

        let rig = try PipeRig(helper: executable, home: world.home, models: nil, scratch: world.root)
        defer { rig.cleanup() }
        rig.send(atFoldersLine([world.photos]))
        #expect(rig.read(cap: 120, until: { rig.walked }), "no `walked` event; stderr: \(rig.stderrText.prefix(300))")

        // wait for a marker (the helper is now reading a file), then take the write lock at once
        let started = Date()
        var held: String?
        var gotLock = false
        let db = world.db()
        while Date().timeIntervalSince(started) < 120 {
            if (db?.int("select count(*) from files where tries > 0") ?? 0) > 0 {
                held = nlHoldWriteLock(world.indexFile, seconds: 12)
                gotLock = held == nil
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(gotLock,"the test could not take the index's write lock while a file was marked: \(held ?? "no file was ever marked")")

        // the helper carries on; end it cleanly and let it finish
        rig.closeStdin()
        _ = rig.read(cap: 90, until: { false })
        let exit = rig.waitForExit(timeout: 90)
        #expect(exit != nil, "the helper was still running 90 s after its stdin ended; stderr: \(rig.stderrText.prefix(300))")

        let errors = rig.stderrText
        let log = (try? String(contentsOf: sesameLogURL(world.support, "index.log"), encoding: .utf8)) ?? ""
        print("READING no-path-log stderr_lines=\(errors.split(separator: "\n").count) log_lines=\(log.split(separator: "\n").count)")
        #expect(errors.contains("SesameHelper"), "the helper wrote no warning at all, so the failed writes did not reach a warning path and the test proved nothing; stderr: \(errors.prefix(300))")
        let forbidden = [nlMarker, world.photos.path, world.root.lastPathComponent]
        for (label, text) in [("stderr", errors), ("index.log", log)] {
            for word in forbidden where text.contains(word) {
                let line = text.split(separator: "\n").first { $0.contains(word) }.map(String.init) ?? ""
                Issue.record("\(label) holds \"\(word)\": \(line.prefix(200))")
            }
        }
    }

    @Test func aLockedAVanishedAndADamagedPhotoLeaveNoPathOrNameInStderrOrIndexLog() throws {
        guard getuid() != 0 else {
            Issue.record("this test runs as root, and root reads through chmod 000: it cannot show anything; run it as the person")
            return
        }
        _ = atHelperWarm
        let executable = KitPaths.bundledHelper
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AtError("the bundled helper is missing: \(executable.path) (run scripts/bundle.sh)")
        }
        let world = try AtWorld()
        defer { world.remove() }
        let ordinary = atNames("pl", 1...6)
        let locked = "lk-\(nlMarker)-lockedphoto", damaged = "dm-\(nlMarker)-damagedphoto", vanished = "vn-\(nlMarker)-vanishedphoto"
        let urls = try atMakePhotos(in: world.photos, names: ordinary + [locked, damaged, vanished], seedBase: 900)
        try Data("this is text, not a picture, in a file that is named like one".utf8).write(to: urls[7])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - 7)], ofItemAtPath: urls[7].path)
        world.lock(urls[6])

        let rig = try PipeRig(helper: executable, home: world.home, models: nil, scratch: world.root)
        defer { rig.cleanup() }
        rig.send(atFoldersLine([world.photos]))
        #expect(rig.read(cap: 120, until: { rig.walked }), "no `walked` event; stderr: \(rig.stderrText.prefix(300))")
        try FileManager.default.removeItem(at: urls[8])       // the oldest file: read last, long after the walk

        // wait until the ordinary photos are done and the locked and the damaged ones have their end states
        let deadline = Date().addingTimeInterval(240)
        var statuses: [String: Int] = [:]
        var lastChange = Date()
        var db: AtDB?
        while Date() < deadline {
            if db == nil { db = world.db() }
            if let rows = db?.rows("select status, count(*) from files group by status") {
                var found: [String: Int] = [:]
                for row in rows { if let status = row[0], let text = row[1], let n = Int(text) { found[status] = n } }
                if found != statuses { statuses = found; lastChange = Date() }
                if found["done"] == 6 && found["needs_permission"] == 1 && found["could_not_read"] == 1 { break }
            }
            if Date().timeIntervalSince(lastChange) > 60 || !rig.isRunning { break }
            _ = rig.read(cap: 0.1, until: { false })           // keep the pipe drained
        }
        #expect(statuses["done"] == 6 && statuses["needs_permission"] == 1 && statuses["could_not_read"] == 1,
                "the helper did not meet the cases (6 done, 1 locked, 1 damaged): statuses \(statuses); stderr: \(rig.stderrText.prefix(300))")

        rig.closeStdin()
        #expect(rig.read(cap: 60, until: { false }) == false)   // drain until the output ends
        let exit = rig.waitForExit(timeout: 60)
        #expect(exit?.status == 0, "the helper did not exit 0 at stdin end (\(exit.map { String($0.status) } ?? "still running")); stderr: \(rig.stderrText.prefix(300))")

        let errors = rig.stderrText
        let log = (try? String(contentsOf: sesameLogURL(world.support, "index.log"), encoding: .utf8)) ?? ""
        let forbidden = [nlMarker, locked, damaged, vanished, world.photos.path, world.root.lastPathComponent]
        for (label, text) in [("stderr", errors), ("index.log", log)] {
            for word in forbidden where text.contains(word) {
                let line = text.split(separator: "\n").first { $0.contains(word) }.map(String.init) ?? ""
                Issue.record("\(label) holds \"\(word)\": \(line.prefix(200))")
            }
        }
    }
}
}

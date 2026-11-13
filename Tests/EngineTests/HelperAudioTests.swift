import Foundation
import Testing
import SesameEngine

// plan-5-t2, tester step. Written from the entry plan-5-t2 of plan-5-tasks.md (Tests), the Conventions (lessons 1 to 8, the
// persistent-failure rule of lesson 6) and the Decisions D4, D5, D7, D8 only; no product source is read. The rig is MediaRig.swift
// (the clips) and IndexAttemptTests.swift (`AtWorld`, `AtDB`, `atStartHelper`, `atFoldersLine`, `atWrite`, `atPassageIDs`, `atPast`).
//
// How a run is made: the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run `scripts/bundle.sh`
// first: a stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME. The index is read with the
// read-only connection of IndexAttemptTests.swift. Every clip is made by this file under $TMPDIR and removed again.
//
// The one shared run (`haOutcome`), a folder of six files:
//   zephyrtone.wav       40 s of a continuous 440 Hz tone at -20 dBFS, 16 kHz mono: two windows, [0, 30] and [25, 40] (D5: with
//                        continuous sound the start is the design's grid; the last window ends at the clip's end)
//   marathonlong.wav     900 s of continuous tone, 8 kHz mono (the reader brings it to 16 kHz): 36 windows, starts 0 to 875 by 25, in two
//                        steps (`stepSeconds` 500: read_to 500, then done)
//   hushedsilence.wav    60 s of digital silence: done with its name passage and no window
//   zqxsecretbroken.m4a  6,000 random bytes under an m4a name
//   zqxsecretnoise.wav   5,000 random bytes under a wav name
//   zqxsecretempty.wav   a zero-byte file
// While the helper works, a read-only connection takes a snapshot of the long clip as fast as it can (one BEGIN, a few statements, one
// COMMIT: one consistent state) and records any state that is not one the design allows: nothing yet (`pending`, no passage); `partial`
// with `read_to` 500, one `name` passage and exactly 20 `audio` passages (starts 0 to 475), no window from 500 on; `done` with one `name`
// passage and 36 `audio` passages and `read_to` cleared. Then the helper is stopped and run again over the same folder, and the second
// state is read: nothing is read again.
//
// SHAPES THIS FILE PINS that the entry did not fix (each is one place to edit):
//   1. A window passage is `source` "audio", `modality` "audio", `vec` 1536 bytes (768 half floats, as a text page), and its `fts` row
//      exists with an empty `body` (the entry: "an fts row with an empty body (no words stored)"). The name passage is `source` "name",
//      modality "none", no vector, as for a PDF (HelperPdfTests).
//   2. A file given up (could_not_read) keeps no passages (D8) and has `tries` 0 (the sealed rule of a could_not_read row).
//   3. The first step's commit is observed from the index (the row shows `partial`); the log's `unit` line is not used to decide it,
//      because its format is not fixed by the entry. The stop test ends stdin right after that and requires the file to be `partial`.
//   4. A zero-byte `.wav` is could_not_read; its reason is not pinned.

private let haTone = (hz: 440.0, db: -20.0)

private func haWrite(_ world: AtWorld, _ name: String, _ build: (String) throws -> Void, age: Int) throws -> String {
    let path = world.photos.appendingPathComponent(name).path
    try build(path)
    try mrAge(path, age)
    return path
}

private func haRandomBytes(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 2_654_435_761 &+ 12_345
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

// MARK: snapshots of the long clip

private struct HaSnap {
    let status: String
    let readTo: Int?
    let names: Int
    let windows: Int
    let maxStart: Int
    let lateWindows: Int
}

private func haSnapshot(_ db: AtDB, file: String, late: Int) -> HaSnap? {
    guard db.rows("BEGIN") != nil else { return nil }
    defer { _ = db.rows("COMMIT") }
    guard let row = db.rows("select id, status, read_to from files where path like '%/\(file)'")?.first,
          let idText = row[0], let id = Int(idText), let status = row[1],
          let counts = db.rows("""
              select coalesce(sum(source = 'name'), 0), coalesce(sum(source = 'audio'), 0), \
              cast(coalesce(max(case when source = 'audio' then start end), -1) as integer), \
              coalesce(sum(source = 'audio' and start >= \(late)), 0) from passages where file_id = \(id)
              """)?.first
    else { return nil }
    return HaSnap(status: status, readTo: row[2].flatMap { Int($0) }, names: Int(counts[0] ?? "") ?? -1, windows: Int(counts[1] ?? "") ?? -1,
                  maxStart: Int(counts[2] ?? "") ?? -2, lateWindows: Int(counts[3] ?? "") ?? -1)
}

/// What is wrong with a snapshot of the 900 s clip; nil when it is one of the three allowed states.
private func haProblem(_ snap: HaSnap) -> String? {
    switch snap.status {
    case "pending":
        return snap.names == 0 && snap.windows == 0 ? nil : "pending but holding \(snap.names) name and \(snap.windows) audio passages"
    case "partial":
        if snap.readTo != 500 { return "partial with read_to \(snap.readTo.map(String.init) ?? "none"), expected 500" }
        if snap.names != 1 || snap.windows != 20 || snap.maxStart != 475 || snap.lateWindows != 0 {
            return "partial at 500 with \(snap.names) name passages, \(snap.windows) windows, highest start \(snap.maxStart), \(snap.lateWindows) from 500 on; expected 1, 20, 475, 0"
        }
        return nil
    case "done":
        if snap.names != 1 || snap.windows != 36 || snap.maxStart != 875 {
            return "done with \(snap.names) name passages, \(snap.windows) windows, highest start \(snap.maxStart); expected 1, 36, 875"
        }
        if let readTo = snap.readTo, readTo != 0 { return "done but read_to is \(readTo)" }
        return nil
    default:
        return "status \(snap.status)"
    }
}

// MARK: the one shared run

private struct HaOutcome {
    var setupProblem: String?
    var rows: [String: MrRow] = [:]
    var passages: [String: [MrPassage]] = [:]
    var nameFinds: [String: [(file: String, source: String)]] = [:]
    var violations: [String] = []
    var partials: [Int] = []
    var snapshots = 0
    var integrity = ""
    var wholeProblems: [String] = []
    var helperExit: Int32?
    var summary = ""
    var log = ""
    var stderr = ""
    var forbidden: [String] = []
    var secondRows: [String: MrRow] = [:]
    var secondPassageIDs: [String: [Int]] = [:]
    var firstPassageIDs: [String: [Int]] = [:]
    var secondExit: Int32?
}

private let haOutcome: HaOutcome = {
    var out = HaOutcome()
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    do {
        _ = try haWrite(world, "zephyrtone.wav", { try MediaRig.writeWav($0, [.tone(40, db: haTone.db, hz: haTone.hz)]) }, age: 1)
        _ = try haWrite(world, "marathonlong.wav", { try MediaRig.writeWav($0, rate: 8000, [.tone(900, db: -20, hz: 330)]) }, age: 2)
        _ = try haWrite(world, "hushedsilence.wav", { try MediaRig.writeWav($0, [.silence(60)]) }, age: 3)
        _ = try haWrite(world, "zqxsecretbroken.m4a", { try haRandomBytes(6000, seed: 1).write(to: URL(fileURLWithPath: $0)) }, age: 4)
        _ = try haWrite(world, "zqxsecretnoise.wav", { try haRandomBytes(5000, seed: 2).write(to: URL(fileURLWithPath: $0)) }, age: 5)
        _ = try haWrite(world, "zqxsecretempty.wav", { try Data().write(to: URL(fileURLWithPath: $0)) }, age: 6)
    } catch {
        out.setupProblem = "could not make the files: \(error)"
        return out
    }
    out.forbidden = ["zqxsecret", world.photos.path, world.root.lastPathComponent]
    let helper: HelperProcess
    do { helper = try atStartHelper(world) } catch {
        out.setupProblem = "the bundled helper could not be started: \(error)"
        return out
    }
    helper.send(atFoldersLine([world.photos]))

    let expectedFiles = 6
    let started = Date()
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    var settled = false
    var settledSince: Date?
    while true {
        if db == nil { db = world.db() }
        if let db {
            if let snap = haSnapshot(db, file: "marathonlong.wav", late: 500) {
                out.snapshots += 1
                if let problem = haProblem(snap), out.violations.count < 20 { out.violations.append(problem) }
                if snap.status == "partial", let readTo = snap.readTo, !out.partials.contains(readTo) { out.partials.append(readTo) }
            }
            if let rows = mrRows(db) {
                let signature = rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)/\(rows[$0]!.readTo ?? -1)" }.joined(separator: ",")
                if signature != lastSignature { lastSignature = signature; lastChange = Date(); settledSince = nil }
                if rows.count == expectedFiles && rows.values.allSatisfy({ mrIsFinal($0.status) }) {
                    if settledSince == nil { settledSince = Date() }
                    if Date().timeIntervalSince(settledSince!) > 1.5 { settled = true; break }
                }
            }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > 60 || now.timeIntervalSince(started) > 600 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.0005)
    }
    out.summary = "settled \(settled), \(Int(Date().timeIntervalSince(started))) s, statuses \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    if let db = world.db() ?? db {
        out.rows = mrRows(db) ?? [:]
        out.passages = mrPassages(db) ?? [:]
        for word in ["zephyrtone", "hushedsilence", "marathonlong"] { out.nameFinds[word] = mrFind(db, column: "name", word) ?? [] }
        out.firstPassageIDs = atPassageIDs(db) ?? [:]
        out.wholeProblems = mrWholeProblems(db)
    }
    out.integrity = world.db()?.integrity() ?? "no index"
    helper.closeStdin()
    out.helperExit = helper.waitForExit(timeout: 60)?.status
    out.stderr = helper.errors

    // the second run over the same folder: nothing is read again
    if let again = try? atStartHelper(world) {
        again.send(atFoldersLine([world.photos]))
        let wait = mrWaitSettled(world, again, expected: expectedFiles, quiet: 6, stall: 60, cap: 300)
        out.secondRows = wait.rows
        out.secondPassageIDs = world.db().flatMap(atPassageIDs) ?? [:]
        again.closeStdin()
        out.secondExit = again.waitForExit(timeout: 60)?.status
        out.stderr += again.errors
    }
    out.log = mrIndexLog(world)
    return out
}()

private struct HaStop: Error {}

private func haOutcomeOrStop() throws -> HaOutcome {
    let outcome = haOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HaStop()
    }
    return outcome
}

// MARK: worlds for the tests that plant a row

private func haIndexedWorld(_ names: [String], seconds: Double = 5) throws -> AtWorld {
    let world = try AtWorld()
    do {
        for (index, name) in names.enumerated() {
            _ = try haWrite(world, name + ".wav", { try MediaRig.writeWav($0, [.tone(seconds, db: -20, hz: 300 + Double(index) * 40)]) }, age: index)
        }
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = mrWaitSettled(world, helper, expected: names.count, stall: 60, cap: 300)
        guard wait.met, wait.rows.values.allSatisfy({ $0.status == "done" }) else {
            throw AtError("setup: the \(names.count) clips did not all reach done: \(mrDescribe(wait.rows)), stderr: \(helper.errors)")
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

extension EncodeHelperTests {
@Suite("HelperAudioTests", .serialized)
struct HelperAudioTests {

    // MARK: a tone clip

    @Test func aToneClipIsDoneKindAudioWithOneNamePassageAndAWindowPassagePerWindowWithAVectorAndNoWordsStored() throws {
        let outcome = try haOutcomeOrStop()
        let row = outcome.rows["zephyrtone.wav"]
        #expect(row?.status == "done", "zephyrtone.wav should be done, got \(row?.status ?? "no row"); rows: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        #expect(row?.kind == "audio", "the kind of zephyrtone.wav is \(row?.kind ?? "none"), expected audio")
        let passages = outcome.passages["zephyrtone.wav"] ?? []
        let names = passages.filter { $0.source == "name" }
        let windows = passages.filter { $0.source == "audio" }
        #expect(names.count == 1, "name passages: \(names.count), expected 1")
        #expect(names.first?.modality == "none" && names.first?.vecBytes == -1, "the name passage is \(names.first?.modality ?? "none") with \(names.first?.vecBytes ?? -9) vector bytes, expected none and no vector")
        #expect(windows.map { [$0.start ?? -1, $0.end ?? -1] }.sorted { $0[0] < $1[0] } == [[0, 30], [25, 40]],
                "the windows (start, end) are \(windows.map { [$0.start ?? -1, $0.end ?? -1] }), expected [0, 30] and [25, 40]: a 40 s tone gives the 30 s grid every 25 s and the last window ends where the clip ends")
        #expect(windows.allSatisfy { $0.modality == "audio" && $0.vecBytes == 1536 }, "a window is not audio with a 1536 byte vector: \(windows.map { "\($0.modality) \($0.vecBytes)" })")
        #expect(passages.count == 3, "passages: \(passages.map(\.source)), expected one name and two windows")
        #expect(passages.allSatisfy { $0.ftsRows == 1 }, "every passage has exactly one fts row: \(passages.map(\.ftsRows))")
        #expect(windows.allSatisfy { $0.body.isEmpty }, "an audio window's fts body holds words: \(windows.map(\.body)); no words are stored for audio")
    }

    @Test func theNameWordsOfAnAudioFileAreFoundByFtsOnTheNamePassageAndNoWordOfNobodyIsFound() throws {
        let outcome = try haOutcomeOrStop()
        for word in ["zephyrtone", "hushedsilence", "marathonlong"] {
            let hits = outcome.nameFinds[word] ?? []
            #expect(hits.count == 1 && hits.first?.source == "name" && hits.first?.file == word + ".wav",
                    "a MATCH name:\(word) found \(hits.map { "\($0.file) \($0.source)" }), expected the name passage of \(word).wav")
        }
    }

    // MARK: the long clip, in steps of 500 s

    @Test func aNineHundredSecondClipIsPartialWithReadToFiveHundredAfterItsFirstStepAndItsLateWindowsAreAbsentUntilItIsDone() throws {
        let outcome = try haOutcomeOrStop()
        #expect(outcome.snapshots > 0, "the poll never saw a row for marathonlong.wav: \(outcome.summary)")
        #expect(outcome.partials == [500], "the 900 s clip was seen partial at read_to \(outcome.partials), expected only 500 (a poll without a pause sees the window between its two steps); \(outcome.summary)")
        #expect(outcome.violations.isEmpty, "a snapshot of marathonlong.wav was not one of the allowed states: \(outcome.violations.prefix(5)); \(outcome.summary)")
        let row = outcome.rows["marathonlong.wav"]
        #expect(row?.status == "done" && row?.kind == "audio", "marathonlong.wav ends \(row?.status ?? "no row")")
        #expect(row?.readTo == nil || row?.readTo == 0, "read_to is \(row?.readTo.map(String.init) ?? "nil") on the finished clip, expected it cleared")
        let windows = (outcome.passages["marathonlong.wav"] ?? []).filter { $0.source == "audio" }
        #expect(windows.map { $0.start ?? -1 }.sorted() == Array(stride(from: 0, through: 875, by: 25)),
                "the window starts are \(windows.map { $0.start ?? -1 }.sorted()), expected 0 to 875 by 25")
        #expect(windows.first { $0.start == 875 }?.end == 900, "the last window ends at \(windows.first { $0.start == 875 }?.end ?? -1), expected the clip's end 900")
        #expect(windows.first { $0.start == 0 }?.end == 30 && windows.first { $0.start == 500 }?.end == 530, "a full window is 30 s: \(windows.map { [$0.start ?? -1, $0.end ?? -1] }.prefix(3))")
    }

    // MARK: silence, and files that cannot be read

    @Test func aClipOfOnlySilenceIsDoneWithItsNamePassageAndNoWindowAndIsFoundByName() throws {
        let outcome = try haOutcomeOrStop()
        let row = outcome.rows["hushedsilence.wav"]
        #expect(row?.status == "done" && row?.kind == "audio", "hushedsilence.wav should be done audio, got \(row?.kind ?? "none") \(row?.status ?? "no row"); rows: \(mrDescribe(outcome.rows))")
        let passages = outcome.passages["hushedsilence.wav"] ?? []
        #expect(passages.map(\.source) == ["name"], "a silent clip holds \(passages.map(\.source)), expected only its name passage")
    }

    @Test func randomBytesUnderAnM4aAndAWavAreCouldNotReadDamagedAtOnceAndAZeroByteWavIsCouldNotReadAndNoneKeepsAPassage() throws {
        let outcome = try haOutcomeOrStop()
        for name in ["zqxsecretbroken.m4a", "zqxsecretnoise.wav"] {
            let row = outcome.rows[name]
            #expect(row?.status == "could_not_read" && row?.reason == "damaged" && row?.tries == 0 && row?.kind == "audio",
                    "\(name) should be audio could_not_read (damaged) with tries 0 after the first run, got \(row.map { "\($0.kind) \($0.status) \($0.reason ?? "no reason") tries \($0.tries)" } ?? "no row"); \(outcome.summary)")
            #expect((outcome.passages[name] ?? []).isEmpty, "\(name) was given up and keeps passages: \((outcome.passages[name] ?? []).map(\.source)) (D8)")
        }
        let empty = outcome.rows["zqxsecretempty.wav"]
        #expect(empty?.status == "could_not_read" && empty?.kind == "audio",
                "the zero-byte wav should be audio could_not_read, got \(empty.map { "\($0.kind) \($0.status)" } ?? "no row"); \(outcome.summary)")
        #expect((outcome.passages["zqxsecretempty.wav"] ?? []).isEmpty, "the zero-byte wav keeps passages")
    }

    @Test func everyOtherFileIsDoneTheIndexIsWholeAndTheHelperEndsAtItsStdinEnd() throws {
        let outcome = try haOutcomeOrStop()
        #expect(outcome.rows.count == 6, "the index holds \(outcome.rows.count) files rows, expected 6: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        let good = outcome.rows.filter { !$0.key.hasPrefix("zqxsecret") }
        #expect(good.count == 3 && good.values.allSatisfy { $0.status == "done" && $0.kind == "audio" },
                "the three readable clips should be done audio beside the given-up ones: \(mrDescribe(outcome.rows))")
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.wholeProblems.isEmpty, "the index is not whole: \(outcome.wholeProblems)")
        #expect(outcome.helperExit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.helperExit.map(String.init) ?? "still running")")
    }

    // The persistent-failure rule, first half: a given-up file is not read again by the next start, and the log and stderr hold no path
    // and no file name (every given-up name carries the marker `zqxsecret`, and the folder has a long unique name).
    @Test func aGivenUpFileIsNotReadAgainAtTheNextStartTheHelperEndsAndTheLogAndStderrHoldNoPathOrName() throws {
        let outcome = try haOutcomeOrStop()
        #expect(outcome.secondExit == 0, "the second helper run should exit 0 at its stdin end, status \(outcome.secondExit.map(String.init) ?? "still running"); \(outcome.summary)")
        #expect(outcome.secondRows.count == 6, "the second run's index holds \(outcome.secondRows.count) rows, expected 6")
        for name in ["zqxsecretbroken.m4a", "zqxsecretnoise.wav", "zqxsecretempty.wav"] {
            let row = outcome.secondRows[name]
            #expect(row?.status == "could_not_read" && row?.tries == 0, "after the next start \(name) is \(row.map { "\($0.status) tries \($0.tries)" } ?? "no row"), expected could_not_read with tries 0")
        }
        #expect(outcome.secondPassageIDs == outcome.firstPassageIDs, "the next start read something again: passage ids \(outcome.firstPassageIDs) then \(outcome.secondPassageIDs)")
        for (label, text) in [("stderr", outcome.stderr), ("index.log", outcome.log)] {
            for word in outcome.forbidden where text.contains(word) {
                let line = text.split(separator: "\n").first { $0.contains(word) }.map(String.init) ?? ""
                Issue.record("\(label) holds \"\(word)\": \(line.prefix(200))")
            }
        }
    }

    // MARK: a stop in the middle of a four-step clip

    // 2,000 s at 8 kHz is four steps of 500 s. The test ends stdin the moment the first step shows in the index (`partial`); the
    // helper stops at its next stop check, so the file is left `partial` with whole rows, and the next run finishes it and keeps what
    // the first run stored (same passage ids).
    @Test func aFourStepClipStoppedAfterItsFirstStepIsPartialWithWholeRowsAndTheNextRunFinishesItKeepingEarlierWindows() throws {
        let world = try AtWorld()
        defer { world.remove() }
        _ = try haWrite(world, "fourstepclip.wav", { try MediaRig.writeWav($0, rate: 8000, [.tone(2000, db: -20, hz: 250)]) }, age: 1)
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        var db: AtDB?
        var seenPartial = false
        let started = Date()
        while Date().timeIntervalSince(started) < 240 {
            if db == nil { db = world.db() }
            if let row = db?.rows("select status from files where path like '%/fourstepclip.wav'")?.first, row[0] == "partial" { seenPartial = true; break }
            if !helper.isRunning { break }
            Thread.sleep(forTimeInterval: 0.0005)
        }
        helper.closeStdin()
        #expect(seenPartial, "the 2,000 s clip never showed as partial: stderr \(helper.errors)")
        let exit = helper.waitForExit(timeout: 120)?.status
        #expect(exit == 0, "the helper should exit 0 after its stdin ended, status \(exit.map(String.init) ?? "still running")")

        let after = try #require(world.db())
        let row = try #require(mrRows(after)?["fourstepclip.wav"], "no row for the clip after the stop")
        #expect(row.status == "partial", "after a stop in the middle the clip should be partial, got \(row.status) read_to \(row.readTo.map(String.init) ?? "nil")")
        guard row.status == "partial", let readTo = row.readTo else { return }
        #expect([500, 1000, 1500].contains(readTo), "read_to is \(readTo), expected a whole step: 500, 1000 or 1500")
        let storedAll = try #require(mrPassages(after))
        let stored = storedAll["fourstepclip.wav"] ?? []
        let windows = stored.filter { $0.source == "audio" }
        #expect(stored.filter { $0.source == "name" }.count == 1 && windows.count == readTo / 25 && (windows.map { $0.start ?? -1 }.max() ?? -1) == readTo - 25,
                "a stopped clip at read_to \(readTo) holds \(stored.filter { $0.source == "name" }.count) name passages, \(windows.count) windows (expected \(readTo / 25)), highest start \(windows.map { $0.start ?? -1 }.max() ?? -1) (expected \(readTo - 25))")
        #expect(mrWholeProblems(after).isEmpty, "the index after the stop is not whole: \(mrWholeProblems(after))")
        let idsBefore = Set(stored.map(\.id))

        let second = try atStartHelper(world)
        defer { second.stop() }
        second.send(atFoldersLine([world.photos]))
        let wait = mrWaitSettled(world, second, expected: 1, stall: 120, cap: 300)
        #expect(wait.met && wait.rows["fourstepclip.wav"]?.status == "done", "the next run did not finish the clip: \(mrDescribe(wait.rows)); stderr \(second.errors)")
        #expect(atCleanStop(second) == 0, "the second helper did not exit 0 at stdin end")
        let final = try #require(world.db())
        let finalAll = try #require(mrPassages(final))
        let finalWindows = (finalAll["fourstepclip.wav"] ?? []).filter { $0.source == "audio" }
        #expect(finalWindows.map { $0.start ?? -1 }.sorted() == Array(stride(from: 0, through: 1975, by: 25)), "the finished clip's window starts: \(finalWindows.map { $0.start ?? -1 }.sorted())")
        #expect(idsBefore.isSubset(of: Set(finalWindows.map(\.id) + [stored.first { $0.source == "name" }?.id ?? -1])),
                "the next run read the first steps again: passage ids \(idsBefore.sorted()) are not all still there")
        #expect(final.integrity() == "ok", "integrity_check: \(final.integrity())")
    }

    // MARK: a clip replaced between two batches

    // The reader's own identity check (a changed size, mtime or inode throws `.changed`) is AudioReaderTests'. Here the whole path: a
    // 900 s clip is indexed and done; the file is replaced by a 700 s clip of another size and time and the helper walks again. Every
    // snapshot is a whole state (all old, or new and partial, or all new), never old and new windows together.
    @Test func aClipChangedBetweenBatchesIsReplacedAndNeverMixedWithItsOldWindows() throws {
        let world = try AtWorld()
        defer { world.remove() }
        let path = try haWrite(world, "shifting.wav", { try MediaRig.writeWav($0, rate: 8000, [.tone(900, db: -20, hz: 200)]) }, age: 3600)
        let oldSize = try #require(mrSeen(path)).size
        let helper = try atStartHelper(world)
        defer { helper.stop() }
        let line = atFoldersLine([world.photos])
        helper.send(line)
        let first = mrWaitSettled(world, helper, expected: 1, stall: 120, cap: 300)
        #expect(first.met && first.rows["shifting.wav"]?.status == "done", "the 900 s clip did not reach done: \(mrDescribe(first.rows)), stderr: \(helper.errors)")
        guard first.met, let db = world.db() else { return }

        try MediaRig.writeWav(path, rate: 8000, [.tone(700, db: -20, hz: 520)])
        try mrAge(path, 1800)
        let newSize = try #require(mrSeen(path)).size
        try #require(newSize != oldSize, "setup: the rewrite did not change the file's size")
        helper.send(line)

        var states: [String] = []
        var violations: [String] = []
        let started = Date()
        var lastChange = started
        var lastState = ""
        while Date().timeIntervalSince(started) < 240 {
            guard db.rows("BEGIN") != nil else { continue }
            var state = "no row"
            if let row = db.rows("select id, size, status, read_to from files where path like '%/shifting.wav'")?.first,
               let idText = row[0], let id = Int(idText) {
                let size = row[1].flatMap { Int($0) }
                let status = row[2] ?? "nil"
                let readTo = row[3].flatMap { Int($0) }
                let counts = db.rows("select coalesce(sum(source = 'audio'), 0), cast(coalesce(max(case when source = 'audio' then \"end\" end), -1) as integer) from passages where file_id = \(id)")?.first
                let windows = Int(counts?[0] ?? "") ?? -1
                let maxEnd = Int(counts?[1] ?? "") ?? -2
                if size == Int(oldSize) {
                    state = "old"
                    if status != "done" || windows != 36 || maxEnd != 900 { state = "inconsistent"; violations.append("old size, status \(status), \(windows) windows ending at \(maxEnd); expected done, 36, 900") }
                } else if size == Int(newSize) {
                    switch status {
                    case "pending": state = "pending"
                    case "partial": state = "partial"; if readTo != 500 || windows != 20 || maxEnd > 530 { violations.append("new size partial at read_to \(readTo.map(String.init) ?? "nil") with \(windows) windows ending at \(maxEnd); expected 500, 20, at most 530") }
                    case "done": state = "new"; if windows != 28 || maxEnd != 700 { violations.append("new size done with \(windows) windows ending at \(maxEnd); expected 28 windows, last end 700") }
                    default: state = status
                    }
                } else {
                    state = "inconsistent"
                    violations.append("size \(size.map(String.init) ?? "nil"), neither \(oldSize) nor \(newSize)")
                }
            }
            _ = db.rows("COMMIT")
            if state != lastState { states.append(state); lastState = state; lastChange = Date() }
            if state == "new" { break }
            if Date().timeIntervalSince(lastChange) > 120 { break }
            Thread.sleep(forTimeInterval: 0.0005)
        }
        #expect(violations.isEmpty, "a reader saw the replaced clip in a bad state (\(violations.count) times), first: \(violations.first ?? ""); states \(states)")
        #expect(states.last == "new", "the replaced clip never became new and complete; states seen \(states); stderr: \(helper.errors)")
        let after = try #require(world.db())
        #expect(after.integrity() == "ok", "integrity_check: \(after.integrity())")
        #expect(after.int("select count(*) from passages where source = 'audio'") == 28, "audio passages after the change: \(after.int("select count(*) from passages where source = 'audio'").map(String.init) ?? "nil"), expected 28")
    }

    // MARK: the attempt marker and the hints of plan 2, on audio

    // `tries` 2 is not read: `could_not_read`, reason "damaged", or "needed too much memory" when the row's reason holds `hint:memory`.
    // A neighbour with tries 1 or 0 is read again.
    @Test func anAudioFileWithTriesTwoBecomesCouldNotReadDamagedOrNeededTooMuchMemoryByItsHintAndIsNeverReadAgain() throws {
        let names = atNames("q", 1...5)
        let world = try haIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2 where path like '%/q-001.wav'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2, reason = 'hint:memory' where path like '%/q-002.wav'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 1 where path like '%/q-003.wav'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0 where path like '%/q-004.wav'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 3, "could_not_read": 2] })
        #expect(wait.met, "expected 3 done and 2 could_not_read, got \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let rows = atRows(db)
        #expect(rows?["q-001.wav"]?.status == "could_not_read" && rows?["q-001.wav"]?.reason == "damaged",
                "tries 2 with no hint must be could_not_read (damaged), got \(atDescribe(rows))")
        #expect(rows?["q-002.wav"]?.status == "could_not_read" && rows?["q-002.wav"]?.reason == "needed too much memory",
                "tries 2 with hint:memory must be could_not_read (needed too much memory), got \(atDescribe(rows))")
        #expect(rows?["q-001.wav"]?.tries == 0 && rows?["q-002.wav"]?.tries == 0, "a could_not_read row holds tries 0, got \(atDescribe(rows))")
        for name in ["q-003.wav", "q-004.wav"] {
            #expect(rows?[name]?.status == "done" && rows?[name]?.tries == 0, "\(name) should be read again and end done with tries 0, got \(atDescribe(rows))")
        }
        let after = try #require(atPassageIDs(db))
        for name in ["q-003.wav", "q-004.wav"] {
            #expect(after[name] != nil && after[name] != before[name], "\(name) was not read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
            #expect((mrPassages(db)?[name] ?? []).contains { $0.source == "audio" && $0.vecBytes == 1536 }, "\(name) was read again without a window vector")
        }
        #expect(after["q-005.wav"] == before["q-005.wav"], "q-005.wav was done and was read again")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // A pending clip holding `hint:solo` is read alone before any other work: the oldest carries the hint and must be written first.
    @Test func aPendingAudioFileHoldingHintSoloIsReadFirstBeforeAnyOtherWork() throws {
        let names = atNames("s", 1...6)
        let world = try haIndexedWorld(names)
        defer { world.remove() }
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        #expect(atWrite(world.indexFile, "update files set reason = 'hint:solo' where path like '%/s-006.wav'") == nil)
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 6] })
        #expect(wait.met, "the six pending clips did not all end done: \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let after = try #require(atPassageIDs(db))
        let newest = before.values.flatMap { $0 }.max() ?? 0
        let first = after.compactMap { (name, ids) -> (String, Int)? in ids.min().map { (name, $0) } }.sorted { $0.1 < $1.1 }
        #expect(first.count == 6 && first.allSatisfy { $0.1 > newest }, "every clip should have been read again (new ids above \(newest)): \(first)")
        #expect(first.first?.0 == "s-006.wav", "the clip with hint:solo must be written before every other file, but the order of writes is \(first.map(\.0))")
        #expect(atRows(db)?.values.allSatisfy { $0.tries == 0 && $0.status == "done" } == true, "rows: \(atDescribe(atRows(db)))")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }
}
}

// MARK: plan-5-t3, Pause on an audio unit, with the fake embedder (no real audio model: D3)

// plan-5-t3, tester step. The t2 stop test above (`aFourStepClipStoppedAfterItsFirstStep...`) is left exactly as it was: it ends stdin AFTER the
// first step is stored, so it pins "partial with whole rows, then resumes", which stays true with the new stop checks. This sibling ends
// stdin in the MIDDLE of a step, at the K-th `unit n=` line of `index.log` (the entry: the stop checks sit between decoding steps and between
// embed units, an interrupted step is dropped uncommitted and Resume reads that step again), for K = 1, 2 and 3.
//
// What is asserted, by hand-written numbers (a 2,000 s tone at 8 kHz is four steps of 500 s: 80 windows, starts 0 to 1975 by 25):
//   - the helper exits (status 0) no later than 4.0 s after stdin ended (the entry's bar: Pause lands within 5 s, the helper's share is 4 s);
//   - the index is whole; the file is `pending` with no passage (the step in flight was dropped) or `partial` with `read_to` a whole step
//     (500, 1000, 1500) holding exactly one `name` passage and `read_to / 25` windows; never `done`, never half a step;
//   - the next run finishes the clip with the 80 windows an uninterrupted run holds (starts 0 to 1975), and every passage the first run
//     stored is still there with its id (Resume continues from where it stopped, nothing is read twice).
// Honest limit (the report says it too): with the fake embedder an embed unit takes microseconds, so this cannot show the time of a unit
// of the real audio model; that reading is HelperPauseLatencyTests' disabled audio test (D3). What this test can show is that the stop poll
// exists inside a step and leaves nothing half stored.
// SHAPE PINNED that the entry did not fix: an audio step writes `unit n=<k>` lines to index.log (the entry's latency test waits on them for
// every kind); a run with no such line at all is a failure.

private func haUnitLineCount(_ world: AtWorld) -> Int {
    mrIndexLog(world).split(separator: "\n").filter { $0.hasPrefix("unit n=") }.count
}

private struct HaPauseRun {
    var unitLines = 0
    var trigger = ""
    var exitGap: Double?
    var exitStatus: Int32?
    var status = ""
    var readTo: Int?
    var tries = -1
    var names = 0
    var windows: [Int] = []
    var ids: [Int] = []
    var whole: [String] = []
    var stderr = ""
}

private func haPauseRun(_ world: AtWorld, afterUnitLine k: Int) -> HaPauseRun {
    var run = HaPauseRun()
    guard let helper = try? atStartHelper(world) else { run.stderr = "the bundled helper could not be started"; return run }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    let started = Date()
    var db: AtDB?
    while Date().timeIntervalSince(started) < 240 {
        if haUnitLineCount(world) >= k { run.trigger = "unit line \(k)"; break }
        if db == nil { db = world.db() }
        if let row = db?.rows("select status from files where path like '%/pauseclip.wav'")?.first, row[0] == "done" { run.trigger = "done before any stop"; break }
        if !helper.isRunning { run.trigger = "helper gone"; break }
        Thread.sleep(forTimeInterval: 0.005)
    }
    let stopAt = Date()
    run.unitLines = haUnitLineCount(world)
    helper.closeStdin()
    if let ended = helper.waitForExit(timeout: 60) {
        run.exitGap = ended.at.timeIntervalSince(stopAt)
        run.exitStatus = ended.status
    }
    run.stderr = helper.errors
    if let after = world.db() {
        run.whole = mrWholeProblems(after)
        if let row = mrRows(after)?["pauseclip.wav"] {
            run.status = row.status
            run.readTo = row.readTo
            run.tries = row.tries
        }
        let passages = mrPassages(after)?["pauseclip.wav"] ?? []
        run.names = passages.filter { $0.source == "name" }.count
        run.windows = passages.filter { $0.source == "audio" }.compactMap(\.start).sorted()
        run.ids = passages.map(\.id).sorted()
    }
    return run
}

extension EncodeHelperTests {
@Suite("HelperAudioPauseTests", .serialized)
struct HelperAudioPauseTests {

    // Measured today (plan-5-t2 helper, no stop check inside a step): stdin ended at unit line K lets the NEXT step run to its end and commit,
    // so K + 1 steps are stored (K = 1: partial at 1,000; K = 2: partial at 1,500; K = 3: done) and the helper exits 0.05 s later. A step is
    // about 50 ms with the fake embedder, so a stop is only seen inside a step when the helper polls inside it; that is what this test
    // can be red for. Because the race is real (the test reads the log every 5 ms), each K is tried up to three times: every try must leave a
    // whole index and a resumable file, and at least one try must show the step in flight dropped (at most K steps stored).
    @Test func stdinEndedAtTheKthUnitLineOfAFourStepClipDropsTheStepInFlightExitsWithinFourSecondsAndTheNextRunFinishesItKeepingEarlierPassages() throws {
        for k in [1, 2, 3] {
            var dropped = false
            var summary: [String] = []
            for attempt in 1...3 {
                let world = try AtWorld()
                defer { world.remove() }
                _ = try haWrite(world, "pauseclip.wav", { try MediaRig.writeWav($0, rate: 8000, [.tone(2000, db: -20, hz: 250)]) }, age: 1)
                let run = haPauseRun(world, afterUnitLine: k)
                let tag = "stop at unit line \(k), try \(attempt) (\(run.trigger), \(run.unitLines) unit lines when stdin ended)"
                let stored = run.status == "partial" ? (run.readTo ?? -1) / 500 : (run.status == "done" ? 4 : 0)
                summary.append("try \(attempt): \(run.status) with \(stored) step(s) stored, exit \(run.exitGap.map { String(format: "%.2f s", $0) } ?? "none")")
                print("READING audio pause fake-embedder \(tag): exit \(run.exitGap.map { String(format: "%.2f s", $0) } ?? "none"), file \(run.status) read_to \(run.readTo.map(String.init) ?? "nil") windows \(run.windows.count)")
                #expect(run.unitLines > 0, "\(tag): an audio step wrote no `unit n=` line to index.log, so no embed unit of audio can be timed or stopped between; stderr: \(run.stderr)")
                #expect(run.exitStatus == 0, "\(tag): the helper should exit 0 after its stdin ended, status \(run.exitStatus.map(String.init) ?? "still running"); stderr: \(run.stderr)")
                #expect((run.exitGap ?? .infinity) <= 4.0, "\(tag): the helper exited \(run.exitGap.map { String(format: "%.2f", $0) } ?? "never") s after its stdin ended, the bar is 4.0 s")
                #expect(run.whole.isEmpty, "\(tag): the index is not whole: \(run.whole)")
                #expect(run.tries == 0, "\(tag): a clean stop left the attempt marker at \(run.tries), expected 0 (only a death leaves it set)")
                switch run.status {
                case "pending":
                    #expect(run.names == 0 && run.windows.isEmpty, "\(tag): pending but holding \(run.names) name and \(run.windows.count) audio passages: the step in flight was stored half")
                case "partial":
                    let readTo = run.readTo ?? -1
                    #expect([500, 1000, 1500].contains(readTo), "\(tag): partial with read_to \(readTo), expected a whole step: 500, 1000 or 1500")
                    #expect(run.names == 1 && run.windows == Array(stride(from: 0, to: readTo, by: 25)),
                            "\(tag): partial at \(readTo) holds \(run.names) name passages and window starts \(run.windows.prefix(4))...\(run.windows.suffix(2)) (\(run.windows.count)); expected 1 and 0 to \(readTo - 25) by 25")
                case "done":
                    #expect(run.windows == Array(stride(from: 0, through: 1975, by: 25)), "\(tag): done with window starts \(run.windows.prefix(4))... (\(run.windows.count)), expected 80")
                default:
                    Issue.record("\(tag): the clip is \(run.status) after the stop, expected pending, partial or done")
                }
                if stored <= k, run.status != "done" { dropped = true }

                let second = try atStartHelper(world)
                defer { second.stop() }
                second.send(atFoldersLine([world.photos]))
                let wait = mrWaitSettled(world, second, expected: 1, stall: 120, cap: 300)
                #expect(wait.met && wait.rows["pauseclip.wav"]?.status == "done", "\(tag): the next run did not finish the clip: \(mrDescribe(wait.rows)); stderr \(second.errors)")
                #expect(atCleanStop(second) == 0, "\(tag): the second helper did not exit 0 at stdin end")
                guard let final = world.db() else { Issue.record("\(tag): the index cannot be read after the second run"); continue }
                let passages = mrPassages(final)?["pauseclip.wav"] ?? []
                let windows = passages.filter { $0.source == "audio" }
                #expect(windows.compactMap(\.start).sorted() == Array(stride(from: 0, through: 1975, by: 25)), "\(tag): the finished clip's window starts: \(windows.compactMap(\.start).sorted().prefix(5))... (\(windows.count)), expected 80, 0 to 1975 by 25")
                #expect(passages.filter { $0.source == "name" }.count == 1, "\(tag): the finished clip holds \(passages.filter { $0.source == "name" }.count) name passages, expected 1")
                #expect(Set(run.ids).isSubset(of: Set(passages.map(\.id))), "\(tag): the next run read the first steps again: ids \(run.ids.prefix(5)) are not all still there")
                #expect(mrWholeProblems(final).isEmpty, "\(tag): the index after the second run is not whole: \(mrWholeProblems(final))")
                if dropped { break }
            }
            #expect(dropped, "stop at unit line \(k): in 3 tries the step in flight after the stop was never dropped (at most \(k) step(s) stored, not done): the helper has no stop check inside an audio step; \(summary)")
        }
    }
}
}

// MARK: lesson 6, a file the decoder keeps failing on (helper level, real undecodable files)

private struct HgRun {
    var rows: [String: MrRow] = [:]
    var idle = false
    var exit: Int32?
    var seconds = 0.0
    var idleCPU = 0.0
    var idleWindow = 0.0
    var passageIDs: [String: [Int]] = [:]
    var stderr = ""
}

private let hgStable: TimeInterval = 6

private func hgRunHelper(_ world: AtWorld, files: Int) -> HgRun {
    var run = HgRun()
    let started = Date()
    guard let helper = try? atStartHelper(world) else {
        run.stderr = "the bundled helper could not be started (run scripts/bundle.sh)"
        return run
    }
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    var db: AtDB?
    var lastSignature = ""
    var lastChange = Date()
    var cpuAtChange = mrCPUSeconds(pid: helper.pid) ?? 0
    while true {
        if db == nil { db = world.db() }
        if let db, let rows = mrRows(db), rows.count == files, let count = db.int("select count(*) from passages") {
            let signature = rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)/\(rows[$0]!.tries)/\(rows[$0]!.reason ?? "-")/\(rows[$0]!.readTo ?? -1)" }.joined(separator: ",") + "|\(count)"
            if signature != lastSignature {
                lastSignature = signature
                lastChange = Date()
                cpuAtChange = mrCPUSeconds(pid: helper.pid) ?? cpuAtChange
            }
            run.rows = rows
            if Date().timeIntervalSince(lastChange) >= hgStable {
                run.idle = true
                run.idleWindow = Date().timeIntervalSince(lastChange)
                run.idleCPU = (mrCPUSeconds(pid: helper.pid) ?? cpuAtChange) - cpuAtChange
                break
            }
        }
        if Date().timeIntervalSince(started) > 240 || (run.rows.isEmpty && Date().timeIntervalSince(started) > 60) { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.1)
    }
    run.exit = atCleanStop(helper, timeout: 60)
    run.seconds = Date().timeIntervalSince(started)
    run.stderr = helper.errors
    if let db = world.db() ?? db {
        run.rows = mrRows(db) ?? run.rows
        run.passageIDs = atPassageIDs(db) ?? [:]
    }
    return run
}

private func hgDescribe(_ run: HgRun) -> String {
    "\(mrDescribe(run.rows)); idle \(run.idle), exit \(run.exit.map(String.init) ?? "none"), \(Int(run.seconds)) s, idle CPU \(String(format: "%.2f", run.idleCPU)) of \(String(format: "%.1f", run.idleWindow)) s; stderr: \(run.stderr)"
}

extension EncodeHelperTests {
@Suite("HelperAudioGiveUpTests", .serialized)
struct HelperAudioGiveUpTests {

    // Convention 6: the two newest files are real undecodable audio (random bytes under .m4a and under .wav), three older files read
    // fine. After two runs at most: both are could_not_read "damaged" with tries 0 (given up, never again), the three older clips are
    // done (nothing is blocked), every run ends at its stdin end, an idle helper does not spin, a third run changes nothing, and the log
    // and stderr hold no path and no name.
    @Test func twoUndecodableNewestFilesAreGivenUpByTheEndOfTheSecondRunNeverBlockOlderClipsAndLeaveNoPathInTheLog() throws {
        let world = try AtWorld()
        defer { world.remove() }
        _ = try haWrite(world, "zqxsecretbadone.m4a", { try haRandomBytes(6000, seed: 11).write(to: URL(fileURLWithPath: $0)) }, age: 1)
        _ = try haWrite(world, "zqxsecretbadtwo.wav", { try haRandomBytes(5000, seed: 12).write(to: URL(fileURLWithPath: $0)) }, age: 2)
        for (index, name) in ["olderone", "oldertwo", "olderthree"].enumerated() {
            _ = try haWrite(world, name + ".wav", { try MediaRig.writeWav($0, [.tone(5, db: -20, hz: 300 + Double(index) * 90)]) }, age: 10 + 10 * index)
        }
        let forbidden = ["zqxsecret", world.photos.path, world.root.lastPathComponent]

        let first = hgRunHelper(world, files: 5)
        #expect(first.idle && first.exit == 0, "run 1 did not end quiet and clean: \(hgDescribe(first))")
        #expect(first.rows["zqxsecretbadone.m4a"]?.status != "done" && first.rows["zqxsecretbadtwo.wav"]?.status != "done", "an undecodable file is done after run 1: \(hgDescribe(first))")
        let second = hgRunHelper(world, files: 5)
        #expect(second.idle && second.exit == 0, "run 2 did not end quiet and clean: \(hgDescribe(second))")
        for name in ["zqxsecretbadone.m4a", "zqxsecretbadtwo.wav"] {
            let row = second.rows[name]
            #expect(row?.status == "could_not_read" && row?.reason == "damaged" && row?.tries == 0,
                    "\(name) should be given up (could_not_read, damaged, tries 0) no later than the end of the second run, got \(row.map { "\($0.status) \($0.reason ?? "no reason") tries \($0.tries)" } ?? "no row"): \(hgDescribe(second))")
        }
        for name in ["olderone.wav", "oldertwo.wav", "olderthree.wav"] {
            #expect(second.rows[name]?.status == "done" && second.rows[name]?.tries == 0, "\(name) is blocked behind the undecodable files: \(hgDescribe(second))")
        }
        #expect(second.idleCPU < 1.0, "the idle helper used \(String(format: "%.2f", second.idleCPU)) s of CPU in \(String(format: "%.1f", second.idleWindow)) s: a loop at full speed")

        let third = hgRunHelper(world, files: 5)
        #expect(third.idle && third.exit == 0, "run 3 did not end quiet and clean: \(hgDescribe(third))")
        #expect(third.passageIDs == second.passageIDs, "a third run read something again: ids \(second.passageIDs) then \(third.passageIDs)")
        #expect(third.rows["zqxsecretbadone.m4a"]?.status == "could_not_read" && third.rows["zqxsecretbadtwo.wav"]?.status == "could_not_read", "a given-up file came back: \(hgDescribe(third))")
        #expect(world.db()?.integrity() == "ok", "integrity_check: \(world.db()?.integrity() ?? "no index")")

        let log = mrIndexLog(world)
        for (label, text) in [("stderr", first.stderr + second.stderr + third.stderr), ("index.log", log)] {
            for word in forbidden where text.contains(word) {
                let line = text.split(separator: "\n").first { $0.contains(word) }.map(String.init) ?? ""
                Issue.record("\(label) holds \"\(word)\": \(line.prefix(200))")
            }
        }
    }
}
}

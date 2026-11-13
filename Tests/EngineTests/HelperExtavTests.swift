import Foundation
import Testing
import SesameEngine

// plan-5-t2, tester step. Written from the entry plan-5-t2 of plan-5-tasks.md (Tests: HelperExtavTests) and the table
// scripts/kit-lib/gate-matrix.csv (the cells `extav-*`, each `yes`, one row, `ok`; written by t1 and read here, never changed) only; no
// product source is read.
//
// The kit builds the matrix (`kit-fixtures.sh build matrix`, a child process under a throwaway KIT_ROOT, outside the sandbox); the
// bundled release helper alone, with the fake embedder and a throwaway HOME, indexes the folder `matrix/extav`. t2 reads audio only, so
// the three video cells (mp4, mov, m4v) have no row yet and are not asserted here (t3's HelperVideoTests names them): this file looks
// at the rows of kind `audio` only, so it stays right when video arrives.
//
// SHAPE THIS FILE PINS that the entry did not fix: the name words of a cell are found by the `zq` token of its name (the cell
// `extav/mp3_zq1301.mp3` by `name:zq1301`), that is, the name is split at the underscore and the dot as a photo's name is. The entry
// says "found first by its name stem"; ranking is plan 5 t6's, so here "first" is that the MATCH finds that file and no other.

private let heCells: [(cell: String, file: String, token: String)] = [
    ("extav-mp3", "mp3_zq1301.mp3", "zq1301"), ("extav-m4a", "m4a_zq1302.m4a", "zq1302"), ("extav-wav", "wav_zq1303.wav", "zq1303"),
    ("extav-aac", "aac_zq1304.aac", "zq1304"), ("extav-flac", "flac_zq1305.flac", "zq1305"),
]

private struct HeOutcome {
    var setupProblem: String?
    var rows: [String: MrRow] = [:]
    var passages: [String: [MrPassage]] = [:]
    var finds: [String: [(file: String, source: String)]] = [:]
    var integrity = ""
    var exit: Int32?
    var summary = ""
}

private let heOutcome: HeOutcome = {
    var out = HeOutcome()
    guard let kit = MrKit() else { out.setupProblem = "could not make a temp kit root"; return out }
    let built = kit.build("matrix")
    guard let built, built.status == 0 else {
        out.setupProblem = "kit-fixtures.sh build matrix failed (status \(built.map { String($0.status) } ?? "not run")): \(mrTail(built?.output ?? "no output"))"
        return out
    }
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    let folder = URL(fileURLWithPath: kit.fixtures + "/matrix/extav", isDirectory: true)
    for item in heCells where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(item.file).path) {
        out.setupProblem = "the matrix has no \(item.file) under extav/"
        return out
    }
    guard let helper = try? atStartHelper(world) else { out.setupProblem = "the bundled helper could not be started (run scripts/bundle.sh)"; return out }
    defer { helper.stop() }
    helper.send(atFoldersLine([folder]))
    let started = Date()
    var settled = false
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    while true {
        if db == nil { db = world.db() }
        if let db, let rows = mrRows(db) {
            let audio = rows.filter { $0.value.kind == "audio" }
            let signature = audio.keys.sorted().map { "\($0)=\(audio[$0]!.status)" }.joined(separator: ",")
            if signature != lastSignature { lastSignature = signature; lastChange = Date() }
            if audio.count == heCells.count && audio.values.allSatisfy({ mrIsFinal($0.status) }) { settled = true; break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > 120 || now.timeIntervalSince(started) > 600 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    out.summary = "settled \(settled), statuses \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    if settled { Thread.sleep(forTimeInterval: 1.5) }
    if let db = world.db() ?? db {
        out.rows = mrRows(db) ?? [:]
        out.passages = mrPassages(db) ?? [:]
        for item in heCells { out.finds[item.token] = mrFind(db, column: "name", item.token) ?? [] }
    }
    out.integrity = world.db()?.integrity() ?? "no index"
    helper.closeStdin()
    out.exit = helper.waitForExit(timeout: 60)?.status
    return out
}()

private struct HeStop: Error {}

private func heOutcomeOrStop() throws -> HeOutcome {
    let outcome = heOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HeStop()
    }
    return outcome
}

extension EncodeHelperTests {
@Suite("HelperExtavTests", .serialized)
struct HelperExtavTests {

    @Test func theFiveAudioCellsOfTheMatrixAreDoneWithKindAudioAndANamePassage() throws {
        let outcome = try heOutcomeOrStop()
        for item in heCells {
            let row = outcome.rows[item.file]
            #expect(row?.status == "done" && row?.kind == "audio",
                    "cell \(item.cell) (\(item.file)) should be done audio, got \(row.map { "\($0.kind) \($0.status) \($0.reason ?? "")" } ?? "no row"); \(outcome.summary)")
            let names = (outcome.passages[item.file] ?? []).filter { $0.source == "name" }
            #expect(names.count == 1, "cell \(item.cell) holds \(names.count) name passages, expected 1")
        }
    }

    @Test func eachAudioCellIsFoundByItsNameTokenAndByNoOtherFile() throws {
        let outcome = try heOutcomeOrStop()
        for item in heCells {
            let hits = outcome.finds[item.token] ?? []
            #expect(hits.count == 1 && hits.first?.file == item.file && hits.first?.source == "name",
                    "a MATCH name:\(item.token) found \(hits.map { "\($0.file) \($0.source)" }), expected only the name passage of \(item.file)")
        }
    }

    @Test func theIndexIsWholeAndTheHelperExitsZero() throws {
        let outcome = try heOutcomeOrStop()
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.exit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.exit.map(String.init) ?? "still running")")
        let audioRows = outcome.rows.filter { $0.value.kind == "audio" }
        #expect(audioRows.count == heCells.count, "the index holds \(audioRows.count) audio rows, expected \(heCells.count): \(mrDescribe(outcome.rows))")
    }
}
}

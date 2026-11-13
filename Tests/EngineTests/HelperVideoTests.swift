import Foundation
import Testing
import SesameEngine

// plan-5-t3, tester step. Written from the entry plan-5-t3 of plan-5-tasks.md (Tests: HelperVideoTests), the Conventions (lessons 1 to 8, the
// persistent-failure rule of lesson 6) and the Decisions D4, D5, D7, D8 and D13 only; no product source is read. The rig is MediaRig.swift
// and MediaRigVideo.swift (the clips: mp4 files of shots the test draws, see the comment in MediaRigVideo.swift) and IndexAttemptTests.swift
// (`AtWorld`, `AtDB`, `atStartHelper`, `atFoldersLine`, `atPassageIDs`, `atPast`, `atCleanStop`, `atWrite`, `atNames`, `atWaitStatuses`).
//
// How a run is made: the bundled release helper alone (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run `scripts/bundle.sh` first: a
// stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME. The index is read with the read-only SQLite
// connection of IndexAttemptTests.swift, never with the product. The fake embedder knows no audio tower, so nothing here needs the real audio
// model (D3); the real model is HelperVideoModelTests'.
//
// THE SHARED RUN (`hvOutcome`), a folder of six files, every one made by this file:
//   zephyrvideo.mp4        40 s, four shots of 10 s (shades 0 to 3), a soundtrack: 20 s of silence, a 6 s tone, 14 s of silence
//                          -> done; one `name` passage; `frame` passages at seconds 0, 12, 21, 30 (the first sample, a multiple of 3, inside
//                          each shot); one `audio` passage whose window starts at 20 (D5) and ends with the clip, at 40
//   marathonvideo.mp4      400 s, 40 shots of 10 s, no audio track -> partial at read_to 180, then 360, then done; frame seconds
//                          ceil(10 k / 3) x 3 for k = 0 to 39 (18 of them in step one, 18 in step two, 4 in step three)
//   silenttrackvideo.mp4   12 s, two shots of 6 s, a track of digital silence -> done; frames at 0 and 6; no audio passage
//   zqxsecretbrokenvideo.mp4   6,000 random bytes under an mp4 name  -> could_not_read "damaged", tries 0, no passage (D8)
//   zqxsecretcutvideo.mp4      a real mp4 cut to its first 40 percent (its index is at the end) -> the same
//   zqxsecretemptyvideo.mov    a zero-byte file -> could_not_read
// While the helper works a read-only connection takes snapshots of the long clip as fast as it can (one BEGIN, a few statements, one COMMIT: one
// consistent state) and records any state the design does not allow: nothing yet (`pending`, no passage); `partial` at 180 with one `name` and 18
// frames; `partial` at 360 with one `name` and 36 frames; `done` with 40 frames. Then the helper is stopped and run again over the same folder:
// nothing is read again.
//
// SHAPES THIS FILE PINS that the entry did not fix (each is one place to edit):
//   1. A frame passage is `source` "frame", `start` = `end` = the second, `modality` "image", `vec` 1536 bytes, and an `fts` row with an empty body; an
//      audio window of a video is `source` "audio", modality "audio", 1536 bytes, an empty `fts` body (as a plain audio file's); the name passage is
//      `source` "name", modality "none", no vector.
//   2. A given-up file (could_not_read) keeps no passages (D8) and has `tries` 0. A zero-byte `.mov` is could_not_read; its reason is not pinned.
//   3. The matrix video cells and the golden clips are indexed the same way; the golden checks are in `HelperVideoTests` below.

private func hvWrite(_ world: AtWorld, _ name: String, _ build: (String) throws -> Void, age: Int) throws -> String {
    let path = world.photos.appendingPathComponent(name).path
    try build(path)
    try mrAge(path, age)
    return path
}

private func hvRandomBytes(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 2_654_435_761 &+ 12_345
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

/// The seconds a 3 s sampling keeps on a clip of `count` shots of `each` seconds: the first multiple of 3 at or after each shot's start.
private func hvKept(shotsEvery each: Int, count: Int) -> [Int] {
    (0..<count).map { Int((Double($0 * each) / 3.0).rounded(.up)) * 3 }
}

// MARK: the golden clips and the matrix, built once per test process by the kit (outside the sandbox: say and ffmpeg)

final class MrGoldenAV: @unchecked Sendable {
    let kit: MrKit?
    let av: String
    let problem: String?
    init(kit: MrKit?, av: String, problem: String?) { self.kit = kit; self.av = av; self.problem = problem }
}

/// `kit-fixtures.sh build golden-av` under a throwaway KIT_ROOT, once per test process, shared by HelperVideoTests and HelperVideoModelTests.
let mrGoldenAV: MrGoldenAV = {
    guard let kit = MrKit() else { return MrGoldenAV(kit: nil, av: "", problem: "could not make a temp kit root") }
    let built = kit.build("golden-av")
    guard let built, built.status == 0 else {
        return MrGoldenAV(kit: kit, av: "", problem: "kit-fixtures.sh build golden-av failed (status \(built.map { String($0.status) } ?? "not run")): \(mrTail(built?.output ?? "no output"))")
    }
    return MrGoldenAV(kit: kit, av: kit.fixtures + "/golden-av", problem: nil)
}()

// MARK: snapshots of the long clip

private struct HvSnap {
    let status: String
    let readTo: Int?
    let names: Int
    let frames: Int
    let audio: Int
    let lateFrames360: Int
    let lateFrames180: Int
}

private func hvSnapshot(_ db: AtDB, file: String) -> HvSnap? {
    guard db.rows("BEGIN") != nil else { return nil }
    defer { _ = db.rows("COMMIT") }
    guard let row = db.rows("select id, status, read_to from files where path like '%/\(file)'")?.first,
          let idText = row[0], let id = Int(idText), let status = row[1],
          let counts = db.rows("""
              select coalesce(sum(source = 'name'), 0), coalesce(sum(source = 'frame'), 0), coalesce(sum(source = 'audio'), 0), \
              coalesce(sum(source = 'frame' and start >= 360), 0), coalesce(sum(source = 'frame' and start >= 180), 0) from passages where file_id = \(id)
              """)?.first
    else { return nil }
    func number(_ index: Int) -> Int { Int(counts[index] ?? "") ?? -1 }
    return HvSnap(status: status, readTo: row[2].flatMap { Int($0) }, names: number(0), frames: number(1), audio: number(2), lateFrames360: number(3), lateFrames180: number(4))
}

/// What is wrong with a snapshot of the 400 s clip; nil when it is one of the four allowed states.
private func hvProblem(_ snap: HvSnap) -> String? {
    switch snap.status {
    case "pending":
        return snap.names == 0 && snap.frames == 0 && snap.audio == 0 ? nil : "pending but holding \(snap.names) name, \(snap.frames) frame and \(snap.audio) audio passages"
    case "partial":
        if snap.audio != 0 { return "partial holding \(snap.audio) audio passages, the clip has no soundtrack" }
        if snap.readTo == 180 {
            return snap.names == 1 && snap.frames == 18 && snap.lateFrames180 == 0 ? nil
                : "partial at 180 with \(snap.names) name and \(snap.frames) frame passages, \(snap.lateFrames180) from 180 on; expected 1, 18, 0"
        }
        if snap.readTo == 360 {
            return snap.names == 1 && snap.frames == 36 && snap.lateFrames360 == 0 ? nil
                : "partial at 360 with \(snap.names) name and \(snap.frames) frame passages, \(snap.lateFrames360) from 360 on; expected 1, 36, 0"
        }
        return "partial with read_to \(snap.readTo.map(String.init) ?? "none"), expected 180 or 360"
    case "done":
        if snap.names != 1 || snap.frames != 40 || snap.audio != 0 { return "done with \(snap.names) name, \(snap.frames) frame and \(snap.audio) audio passages; expected 1, 40, 0" }
        if let readTo = snap.readTo, readTo != 0 { return "done but read_to is \(readTo)" }
        return nil
    default:
        return "status \(snap.status)"
    }
}

// MARK: the one shared run

private struct HvOutcome {
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

private let hvOutcome: HvOutcome = {
    var out = HvOutcome()
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    guard let dir = try? MrDir() else { out.setupProblem = "could not make a temp folder"; return out }
    defer { dir.remove() }
    do {
        let wav = dir.file("sound.wav")
        try MediaRig.writeWav(wav, rate: 44100, [.silence(20), .tone(6, db: -20, hz: 440), .silence(14)])
        let silentWav = dir.file("silent.wav")
        try MediaRig.writeWav(silentWav, rate: 44100, [.silence(12)])
        _ = try hvWrite(world, "zephyrvideo.mp4", { try MediaRig.writeVideo($0, shots: MediaRig.shots([10, 10, 10, 10]), soundtrack: wav) }, age: 1)
        _ = try hvWrite(world, "marathonvideo.mp4", { try MediaRig.writeVideo($0, shots: MediaRig.shots(Array(repeating: 10, count: 40))) }, age: 2)
        _ = try hvWrite(world, "silenttrackvideo.mp4", { try MediaRig.writeVideo($0, shots: MediaRig.shots([6, 6]), soundtrack: silentWav) }, age: 3)
        _ = try hvWrite(world, "zqxsecretbrokenvideo.mp4", { try hvRandomBytes(6000, seed: 1).write(to: URL(fileURLWithPath: $0)) }, age: 4)
        let whole = dir.file("whole.mp4")
        try MediaRig.writeVideo(whole, shots: MediaRig.shots([6, 6, 6, 6]))
        _ = try hvWrite(world, "zqxsecretcutvideo.mp4", { try MediaRig.cutCopy(of: whole, to: $0, fraction: 0.4) }, age: 5)
        _ = try hvWrite(world, "zqxsecretemptyvideo.mov", { try Data().write(to: URL(fileURLWithPath: $0)) }, age: 6)
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
            if let snap = hvSnapshot(db, file: "marathonvideo.mp4") {
                out.snapshots += 1
                if let problem = hvProblem(snap), out.violations.count < 20 { out.violations.append(problem) }
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
        if now.timeIntervalSince(lastChange) > 90 || now.timeIntervalSince(started) > 600 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.0005)
    }
    out.summary = "settled \(settled), \(Int(Date().timeIntervalSince(started))) s, statuses \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    if let db = world.db() ?? db {
        out.rows = mrRows(db) ?? [:]
        out.passages = mrPassages(db) ?? [:]
        for word in ["zephyrvideo", "marathonvideo", "silenttrackvideo"] { out.nameFinds[word] = mrFind(db, column: "name", word) ?? [] }
        out.firstPassageIDs = atPassageIDs(db) ?? [:]
        out.wholeProblems = mrWholeProblems(db)
    }
    out.integrity = world.db()?.integrity() ?? "no index"
    helper.closeStdin()
    out.helperExit = helper.waitForExit(timeout: 60)?.status
    out.stderr = helper.errors

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

private struct HvStop: Error {}

private func hvOutcomeOrStop() throws -> HvOutcome {
    let outcome = hvOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw HvStop()
    }
    return outcome
}

// MARK: the matrix cells of the three video extensions

private struct HvExtavCell {
    let cell: String
    let file: String
    let token: String
}

private func hvExtavCells() -> [HvExtavCell] {
    let table = KitPaths.projectRoot.appendingPathComponent("scripts/kit-lib/gate-matrix.csv")
    guard let text = try? String(contentsOf: table, encoding: .utf8) else { return [] }
    var cells: [HvExtavCell] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, fields[0].hasPrefix("extav-"), ["mp4", "mov", "m4v"].contains((fields[1] as NSString).pathExtension.lowercased()) else { continue }
        let name = (fields[1] as NSString).lastPathComponent
        guard let range = name.range(of: "zq[0-9]+", options: .regularExpression) else { continue }
        cells.append(HvExtavCell(cell: fields[0], file: name, token: String(name[range])))
    }
    return cells
}

private struct HvExtavOutcome {
    var setupProblem: String?
    var rows: [String: MrRow] = [:]
    var passages: [String: [MrPassage]] = [:]
    var finds: [String: [(file: String, source: String)]] = [:]
    var integrity = ""
    var exit: Int32?
    var summary = ""
}

private let hvExtavOutcome: HvExtavOutcome = {
    var out = HvExtavOutcome()
    let cells = hvExtavCells()
    guard cells.count == 3 else { out.setupProblem = "the table holds \(cells.count) video extav cells, expected 3 (mp4, mov, m4v)"; return out }
    guard let kit = MrKit() else { out.setupProblem = "could not make a temp kit root"; return out }
    let built = kit.build("matrix")
    guard let built, built.status == 0 else {
        out.setupProblem = "kit-fixtures.sh build matrix failed (status \(built.map { String($0.status) } ?? "not run")): \(mrTail(built?.output ?? "no output"))"
        return out
    }
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    let folder = URL(fileURLWithPath: kit.fixtures + "/matrix/extav", isDirectory: true)
    for cell in cells where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(cell.file).path) {
        out.setupProblem = "the matrix has no \(cell.file) under extav/"
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
            let video = rows.filter { $0.value.kind == "video" }
            let signature = video.keys.sorted().map { "\($0)=\(video[$0]!.status)" }.joined(separator: ",")
            if signature != lastSignature { lastSignature = signature; lastChange = Date() }
            if video.count == cells.count && video.values.allSatisfy({ mrIsFinal($0.status) }) { settled = true; break }
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
        for cell in cells { out.finds[cell.token] = mrFind(db, column: "name", cell.token) ?? [] }
    }
    out.integrity = world.db()?.integrity() ?? "no index"
    helper.closeStdin()
    out.exit = helper.waitForExit(timeout: 60)?.status
    return out
}()

// MARK: the golden clips

private struct HvGoldenOutcome {
    var setupProblem: String?
    var rows: [String: MrRow] = [:]
    var passages: [String: [MrPassage]] = [:]
    var integrity = ""
    var exit: Int32?
    var summary = ""
}

private let hvGoldenOutcome: HvGoldenOutcome = {
    var out = HvGoldenOutcome()
    let golden = mrGoldenAV
    if let problem = golden.problem { out.setupProblem = problem; return out }
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    guard let helper = try? atStartHelper(world) else { out.setupProblem = "the bundled helper could not be started (run scripts/bundle.sh)"; return out }
    defer { helper.stop() }
    helper.send(atFoldersLine([URL(fileURLWithPath: golden.av + "/video", isDirectory: true), URL(fileURLWithPath: golden.av + "/damaged", isDirectory: true)]))
    let started = Date()
    var settled = false
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    while true {
        if db == nil { db = world.db() }
        if let db, let rows = mrRows(db) {
            let video = rows.filter { $0.value.kind == "video" }
            let signature = video.keys.sorted().map { "\($0)=\(video[$0]!.status)/\(video[$0]!.readTo ?? -1)" }.joined(separator: ",")
            if signature != lastSignature { lastSignature = signature; lastChange = Date() }
            if video.count == 13 && video.values.allSatisfy({ mrIsFinal($0.status) }) { settled = true; break }
        }
        let now = Date()
        if now.timeIntervalSince(lastChange) > 180 || now.timeIntervalSince(started) > 900 { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.05)
    }
    out.summary = "settled \(settled), \(Int(Date().timeIntervalSince(started))) s, statuses \(lastSignature), helper \(helper.isRunning ? "running" : "gone"), stderr: \(helper.errors)"
    if settled { Thread.sleep(forTimeInterval: 1.5) }
    if let db = world.db() ?? db {
        out.rows = mrRows(db) ?? [:]
        out.passages = mrPassages(db) ?? [:]
    }
    out.integrity = world.db()?.integrity() ?? "no index"
    helper.closeStdin()
    out.exit = helper.waitForExit(timeout: 60)?.status
    return out
}()

// MARK: worlds for the tests that plant a row

private func hvIndexedWorld(_ names: [String]) throws -> AtWorld {
    let world = try AtWorld()
    do {
        for (index, name) in names.enumerated() {
            _ = try hvWrite(world, name + ".mp4", { try MediaRig.writeVideo($0, shots: [MediaRig.VideoShot(seconds: 6, shade: index % 8, row: 3 + index)]) }, age: index)
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

// MARK: the tests

extension EncodeHelperTests {
@Suite("HelperVideoTests", .serialized)
struct HelperVideoTests {

    // MARK: a video with a soundtrack

    @Test func aVideoIsDoneKindVideoWithOneNamePassageFramePassagesAtTheFirstSampleOfEachShotAndOneAudioPassageForItsSoundtrack() throws {
        let outcome = try hvOutcomeOrStop()
        let row = outcome.rows["zephyrvideo.mp4"]
        #expect(row?.status == "done", "zephyrvideo.mp4 should be done, got \(row?.status ?? "no row"); rows: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        #expect(row?.kind == "video", "the kind of zephyrvideo.mp4 is \(row?.kind ?? "none"), expected video")
        let passages = outcome.passages["zephyrvideo.mp4"] ?? []
        let names = passages.filter { $0.source == "name" }
        let frames = passages.filter { $0.source == "frame" }.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        let audio = passages.filter { $0.source == "audio" }
        #expect(names.count == 1, "name passages: \(names.count), expected 1")
        #expect(names.first?.modality == "none" && names.first?.vecBytes == -1, "the name passage is \(names.first?.modality ?? "none") with \(names.first?.vecBytes ?? -9) vector bytes, expected none and no vector")
        #expect(frames.map { $0.start ?? -1 } == [0, 12, 21, 30], "the frame passages are at seconds \(frames.map { $0.start ?? -1 }), expected [0, 12, 21, 30] (the first multiple of 3 inside each of the four shots)")
        #expect(frames.allSatisfy { $0.start == $0.end }, "a frame passage has start and end apart: \(frames.map { "\($0.start ?? -1)-\($0.end ?? -1)" })")
        #expect(frames.allSatisfy { $0.modality == "image" && $0.vecBytes == 1536 }, "a frame is not image with a 1536 byte vector: \(frames.map { "\($0.modality) \($0.vecBytes)" })")
        #expect(audio.count == 1 && (19...21).contains(audio.first?.start ?? -1) && (39...40).contains(audio.first?.end ?? -1),
                "the audio passages are \(audio.map { "\($0.start ?? -1)-\($0.end ?? -1)" }), expected one window from 20 (the tone starts there after 20 s of silence, D5) to the clip's end 40")
        #expect(audio.allSatisfy { $0.modality == "audio" && $0.vecBytes == 1536 }, "an audio window is not audio with a 1536 byte vector: \(audio.map { "\($0.modality) \($0.vecBytes)" })")
        #expect(passages.count == 6, "passages: \(passages.map(\.source)), expected one name, four frames and one window")
        #expect(passages.allSatisfy { $0.ftsRows == 1 }, "every passage has exactly one fts row: \(passages.map(\.ftsRows))")
        #expect((frames + audio).allSatisfy { $0.body.isEmpty }, "a frame or window has words in its fts body: \((frames + audio).map(\.body)); no words are stored for video")
    }

    @Test func theNameWordsOfAVideoAreFoundByFtsOnItsNamePassageAndByNoOtherPassage() throws {
        let outcome = try hvOutcomeOrStop()
        for word in ["zephyrvideo", "marathonvideo", "silenttrackvideo"] {
            let hits = outcome.nameFinds[word] ?? []
            #expect(hits.count == 1 && hits.first?.source == "name" && hits.first?.file == word + ".mp4",
                    "a MATCH name:\(word) found \(hits.map { "\($0.file) \($0.source)" }), expected the name passage of \(word).mp4")
        }
    }

    // MARK: the long clip, in steps of 180 s

    @Test func aFourHundredSecondVideoIsPartialAtOneEightyThenThreeSixtyThenDoneAndEveryStepIsStoredInOneTransaction() throws {
        let outcome = try hvOutcomeOrStop()
        #expect(outcome.snapshots > 0, "the poll never saw a row for marathonvideo.mp4: \(outcome.summary)")
        #expect(outcome.partials == [180, 360], "the 400 s clip was seen partial at read_to \(outcome.partials), expected 180 and then 360 (a poll without a pause sees the window between steps); \(outcome.summary)")
        #expect(outcome.violations.isEmpty, "a snapshot of marathonvideo.mp4 was not one of the allowed states: \(outcome.violations.prefix(5)); \(outcome.summary)")
        let row = outcome.rows["marathonvideo.mp4"]
        #expect(row?.status == "done" && row?.kind == "video", "marathonvideo.mp4 ends \(row?.status ?? "no row")")
        #expect(row?.readTo == nil || row?.readTo == 0, "read_to is \(row?.readTo.map(String.init) ?? "nil") on the finished clip, expected it cleared")
        let frames = (outcome.passages["marathonvideo.mp4"] ?? []).filter { $0.source == "frame" }.compactMap(\.start).sorted()
        #expect(frames == hvKept(shotsEvery: 10, count: 40), "the frame seconds are \(frames), expected the first multiple of 3 inside each of the 40 shots: \(hvKept(shotsEvery: 10, count: 40))")
        #expect((outcome.passages["marathonvideo.mp4"] ?? []).filter { $0.source == "audio" }.isEmpty, "a clip with no audio track holds audio passages")
    }

    // MARK: no sound, silence, and files that cannot be read

    @Test func aClipWithASilentTrackIsDoneWithFramesAndNoAudioPassageAndIsFoundByName() throws {
        let outcome = try hvOutcomeOrStop()
        let row = outcome.rows["silenttrackvideo.mp4"]
        #expect(row?.status == "done" && row?.kind == "video", "silenttrackvideo.mp4 should be done video, got \(row?.kind ?? "none") \(row?.status ?? "no row"); rows: \(mrDescribe(outcome.rows))")
        let passages = outcome.passages["silenttrackvideo.mp4"] ?? []
        #expect(passages.filter { $0.source == "frame" }.compactMap(\.start).sorted() == [0, 6], "the frames are at \(passages.filter { $0.source == "frame" }.compactMap(\.start).sorted()), expected [0, 6]")
        #expect(passages.filter { $0.source == "audio" }.isEmpty, "a silent soundtrack gave audio passages \(passages.filter { $0.source == "audio" }.map { $0.start ?? -1 })")
        #expect(passages.filter { $0.source == "name" }.count == 1, "the clip has \(passages.filter { $0.source == "name" }.count) name passages, expected 1")
    }

    @Test func randomBytesAndACutMp4AreCouldNotReadDamagedAtOnceAndAZeroByteMovIsCouldNotReadAndNoneKeepsAPassage() throws {
        let outcome = try hvOutcomeOrStop()
        for name in ["zqxsecretbrokenvideo.mp4", "zqxsecretcutvideo.mp4"] {
            let row = outcome.rows[name]
            #expect(row?.status == "could_not_read" && row?.reason == "damaged" && row?.tries == 0 && row?.kind == "video",
                    "\(name) should be video could_not_read (damaged) with tries 0 after the first run, got \(row.map { "\($0.kind) \($0.status) \($0.reason ?? "no reason") tries \($0.tries)" } ?? "no row"); \(outcome.summary)")
            #expect((outcome.passages[name] ?? []).isEmpty, "\(name) was given up and keeps passages: \((outcome.passages[name] ?? []).map(\.source)) (D8)")
        }
        let empty = outcome.rows["zqxsecretemptyvideo.mov"]
        #expect(empty?.status == "could_not_read" && empty?.kind == "video",
                "the zero-byte mov should be video could_not_read, got \(empty.map { "\($0.kind) \($0.status)" } ?? "no row"); \(outcome.summary)")
        #expect((outcome.passages["zqxsecretemptyvideo.mov"] ?? []).isEmpty, "the zero-byte mov keeps passages")
    }

    @Test func everyOtherFileIsDoneTheIndexIsWholeAndTheHelperEndsAtItsStdinEnd() throws {
        let outcome = try hvOutcomeOrStop()
        #expect(outcome.rows.count == 6, "the index holds \(outcome.rows.count) files rows, expected 6: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        let good = outcome.rows.filter { !$0.key.hasPrefix("zqxsecret") }
        #expect(good.count == 3 && good.values.allSatisfy { $0.status == "done" && $0.kind == "video" },
                "the three readable clips should be done video beside the given-up ones: \(mrDescribe(outcome.rows))")
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.wholeProblems.isEmpty, "the index is not whole: \(outcome.wholeProblems)")
        #expect(outcome.helperExit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.helperExit.map(String.init) ?? "still running")")
    }

    // The persistent-failure rule, first half: a given-up file is not read again by the next start, and the log and stderr hold no path and no
    // file name (every given-up name carries the marker `zqxsecret`, and the folder has a long unique name).
    @Test func aGivenUpVideoIsNotReadAgainAtTheNextStartTheHelperEndsAndTheLogAndStderrHoldNoPathOrName() throws {
        let outcome = try hvOutcomeOrStop()
        #expect(outcome.secondExit == 0, "the second helper run should exit 0 at its stdin end, status \(outcome.secondExit.map(String.init) ?? "still running"); \(outcome.summary)")
        #expect(outcome.secondRows.count == 6, "the second run's index holds \(outcome.secondRows.count) rows, expected 6")
        for name in ["zqxsecretbrokenvideo.mp4", "zqxsecretcutvideo.mp4", "zqxsecretemptyvideo.mov"] {
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

    // MARK: the three video extensions (the matrix cells)

    @Test func theThreeVideoCellsOfTheMatrixAreDoneVideoWithANamePassageAndAFrameAndEachIsFoundByItsNameToken() throws {
        let outcome = hvExtavOutcome
        if let problem = outcome.setupProblem { Issue.record("setup failed: \(problem)"); return }
        let cells = hvExtavCells()
        for cell in cells {
            let row = outcome.rows[cell.file]
            #expect(row?.status == "done" && row?.kind == "video",
                    "cell \(cell.cell) (\(cell.file)) should be done video, got \(row.map { "\($0.kind) \($0.status) \($0.reason ?? "")" } ?? "no row"); \(outcome.summary)")
            let passages = outcome.passages[cell.file] ?? []
            #expect(passages.filter { $0.source == "name" }.count == 1, "cell \(cell.cell) holds \(passages.filter { $0.source == "name" }.count) name passages, expected 1")
            #expect(passages.contains { $0.source == "frame" && $0.start == 0 && $0.vecBytes == 1536 }, "cell \(cell.cell) holds no frame passage at second 0 with a vector: \(passages.map { "\($0.source)@\($0.start ?? -1)" })")
            let hits = outcome.finds[cell.token] ?? []
            #expect(hits.count == 1 && hits.first?.file == cell.file && hits.first?.source == "name",
                    "a MATCH name:\(cell.token) found \(hits.map { "\($0.file) \($0.source)" }), expected only the name passage of \(cell.file)")
        }
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.exit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.exit.map(String.init) ?? "still running")")
    }

    // MARK: the golden clips (kit-fixtures.sh build golden-av, say and ffmpeg)

    @Test func theTwelveGoldenVideosAreDoneAndTheDamagedMp4IsCouldNotReadWithNoPassage() throws {
        let outcome = hvGoldenOutcome
        if let problem = outcome.setupProblem { Issue.record("setup failed: \(problem)"); return }
        let video = outcome.rows.filter { $0.value.kind == "video" }
        #expect(video.count == 13, "the index holds \(video.count) video rows, expected 12 clips and broken.mp4: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        let broken = outcome.rows["broken.mp4"]
        #expect(broken?.status == "could_not_read" && broken?.reason == "damaged" && broken?.tries == 0,
                "broken.mp4 should be could_not_read (damaged), got \(broken.map { "\($0.status) \($0.reason ?? "no reason")" } ?? "no row"); \(outcome.summary)")
        #expect((outcome.passages["broken.mp4"] ?? []).isEmpty, "broken.mp4 was given up and keeps passages")
        let others = video.filter { $0.key != "broken.mp4" }
        #expect(others.count == 12 && others.values.allSatisfy { $0.status == "done" }, "every other video should be done: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        for (name, _) in others {
            let passages = outcome.passages[name] ?? []
            #expect(passages.filter { $0.source == "name" }.count == 1, "\(name) holds \(passages.filter { $0.source == "name" }.count) name passages, expected 1")
            #expect(passages.contains { $0.source == "frame" }, "\(name) holds no frame passage")
            #expect(passages.filter { $0.source == "frame" || $0.source == "audio" }.allSatisfy { $0.vecBytes == 1536 }, "\(name) holds a passage without a vector")
        }
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.exit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.exit.map(String.init) ?? "still running")")
    }

    @Test func theSafariZebraHasAFrameAtSecond42AndTheSilentTrackClipHasFramesAndNoAudioPassageAndTheSpeechClipOneFrameAndAWindowFromTwenty() throws {
        let outcome = hvGoldenOutcome
        if let problem = outcome.setupProblem { Issue.record("setup failed: \(problem)"); return }
        let zebra = (outcome.passages["safari-zebra.mp4"] ?? []).filter { $0.source == "frame" }.compactMap(\.start).sorted()
        #expect(zebra.contains(42) && zebra.count >= 3 && zebra.count <= 20,
                "safari-zebra.mp4 (a zebra scene from 42 s for 10 s) has frame passages at \(zebra), expected one at exactly 42 (zero tolerance before) and between 3 and 20 in all")
        let v12 = outcome.passages["clip-v12.mp4"] ?? []
        #expect(v12.contains { $0.source == "frame" }, "clip-v12.mp4 holds no frame passage")
        #expect(!v12.contains { $0.source == "audio" }, "clip-v12.mp4 (a silent track) holds audio passages \(v12.filter { $0.source == "audio" }.map { $0.start ?? -1 })")
        let v11 = outcome.passages["clip-v11.mp4"] ?? []
        #expect(v11.filter { $0.source == "frame" }.count == 1, "clip-v11.mp4 (plain gray frames) holds \(v11.filter { $0.source == "frame" }.count) frame passages, expected 1")
        let windows = v11.filter { $0.source == "audio" }
        #expect(windows.count == 1 && abs((windows.first?.start ?? -99) - 20) <= 2,
                "clip-v11.mp4 holds audio passages \(windows.map { "\($0.start ?? -1)-\($0.end ?? -1)" }), expected one that starts at 20 (the key's videospeech row, locator 00:20) within 2 s")
    }

    // MARK: the attempt marker and the hints of plan 2, on a video step

    // `tries` 2 is not read: `could_not_read`, reason "damaged", or "needed too much memory" when the row's `reason` holds `hint:memory`.
    // A neighbour with tries 1 or 0 is read again.
    @Test func aVideoWithTriesTwoBecomesCouldNotReadDamagedOrNeededTooMuchMemoryByItsHintAndIsNeverReadAgain() throws {
        let names = atNames("q", 1...5)
        let world = try hvIndexedWorld(names)
        defer { world.remove() }
        let before = try #require(world.db().flatMap(atPassageIDs), "setup: the passages cannot be read")
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2 where path like '%/q-001.mp4'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 2, reason = 'hint:memory' where path like '%/q-002.mp4'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 1 where path like '%/q-003.mp4'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0 where path like '%/q-004.mp4'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 3, "could_not_read": 2] })
        #expect(wait.met, "expected 3 done and 2 could_not_read, got \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let rows = atRows(db)
        #expect(rows?["q-001.mp4"]?.status == "could_not_read" && rows?["q-001.mp4"]?.reason == "damaged",
                "tries 2 with no hint must be could_not_read (damaged), got \(atDescribe(rows))")
        #expect(rows?["q-002.mp4"]?.status == "could_not_read" && rows?["q-002.mp4"]?.reason == "needed too much memory",
                "tries 2 with hint:memory must be could_not_read (needed too much memory), got \(atDescribe(rows))")
        #expect(rows?["q-001.mp4"]?.tries == 0 && rows?["q-002.mp4"]?.tries == 0, "a could_not_read row holds tries 0, got \(atDescribe(rows))")
        for name in ["q-003.mp4", "q-004.mp4"] {
            #expect(rows?[name]?.status == "done" && rows?[name]?.tries == 0, "\(name) should be read again and end done with tries 0, got \(atDescribe(rows))")
        }
        let after = try #require(atPassageIDs(db))
        for name in ["q-003.mp4", "q-004.mp4"] {
            #expect(after[name] != nil && after[name] != before[name], "\(name) was not read again: ids \(before[name] ?? []) then \(after[name] ?? [])")
            #expect((mrPassages(db)?[name] ?? []).contains { $0.source == "frame" && $0.vecBytes == 1536 }, "\(name) was read again without a frame vector")
        }
        #expect(after["q-005.mp4"] == before["q-005.mp4"], "q-005.mp4 was done and was read again")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // A pending clip holding `hint:solo` is read alone before any other work: the oldest carries the hint and must be written first.
    @Test func aPendingVideoHoldingHintSoloIsReadFirstBeforeAnyOtherWork() throws {
        let names = atNames("s", 1...6)
        let world = try hvIndexedWorld(names)
        defer { world.remove() }
        #expect(atWrite(world.indexFile, "update files set status = 'pending', tries = 0") == nil)
        #expect(atWrite(world.indexFile, "update files set reason = 'hint:solo' where path like '%/s-006.mp4'") == nil)
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
        #expect(first.first?.0 == "s-006.mp4", "the clip with hint:solo must be written before every other file, but the order of writes is \(first.map(\.0))")
        #expect(atRows(db)?.values.allSatisfy { $0.tries == 0 && $0.status == "done" } == true, "rows: \(atDescribe(atRows(db)))")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }

    // The marker covers a step of a long clip: a partial row with tries 2 is `could_not_read` and is not read again; one with tries 1 reads its
    // next step (the seconds after `read_to`), adds its passages and leaves the earlier steps' passages as they are.
    @Test func aPartialVideoWithTriesTwoIsCouldNotReadAndOneWithTriesOneReadsItsNextStepAndKeepsTheEarlierSteps() throws {
        let world = try AtWorld()
        defer { world.remove() }
        for (index, name) in ["u-001", "u-002"].enumerated() {
            _ = try hvWrite(world, name + ".mp4", { try MediaRig.writeVideo($0, shots: MediaRig.shots(Array(repeating: 10, count: 22), firstShade: index)) }, age: index)
        }
        let first = try atStartHelper(world)
        defer { first.stop() }
        first.send(atFoldersLine([world.photos]))
        let ready = mrWaitSettled(world, first, expected: 2, stall: 120, cap: 300)
        #expect(ready.met && ready.rows.values.allSatisfy { $0.status == "done" }, "setup: the two 220 s clips did not reach done: \(mrDescribe(ready.rows)); stderr: \(first.errors)")
        #expect(atCleanStop(first) == 0, "setup: the first helper did not exit 0")
        func ids(_ db: AtDB, _ file: String, _ clause: String) -> [Int] {
            (db.rows("select p.id from passages p join files f on f.id = p.file_id where f.path like '%/\(file).mp4' and \(clause) order by p.id") ?? [])
                .compactMap { $0[0].flatMap { Int($0) } }
        }
        let before = try #require(world.db())
        let oneAll = ids(before, "u-001", "1 = 1")
        let twoEarlier = ids(before, "u-002", "p.source = 'frame' and p.start < 180"), twoAll = ids(before, "u-002", "1 = 1")
        #expect(twoEarlier.count == 18 && twoAll.count > 18, "setup: u-002.mp4 should hold 18 frames before second 180 and more in all, it holds \(twoEarlier.count) and \(twoAll.count)")
        #expect(atWrite(world.indexFile, "update files set status = 'partial', read_to = 180, tries = 2 where path like '%/u-001.mp4'") == nil)
        #expect(atWrite(world.indexFile, "update files set status = 'partial', read_to = 180, tries = 1 where path like '%/u-002.mp4'") == nil)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { $0 == ["done": 1, "could_not_read": 1] })
        #expect(wait.met, "expected 1 done and 1 could_not_read, got \(wait.statuses), stderr: \(helper.errors)")
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")

        let db = try #require(world.db())
        let rows = try #require(mrRows(db))
        #expect(rows["u-001.mp4"]?.status == "could_not_read" && rows["u-001.mp4"]?.reason == "damaged", "a partial row with tries 2 should be could_not_read (damaged), got \(mrDescribe(rows))")
        #expect(Set(ids(db, "u-001", "1 = 1")).isSubset(of: Set(oneAll)), "u-001.mp4 (tries 2) was read again: ids \(oneAll) then \(ids(db, "u-001", "1 = 1"))")
        #expect(rows["u-002.mp4"]?.status == "done" && rows["u-002.mp4"]?.tries == 0, "a partial row with tries 1 should be read and end done with tries 0, got \(mrDescribe(rows))")
        #expect(ids(db, "u-002", "p.source = 'frame' and p.start < 180") == twoEarlier, "the passages of the earlier step of u-002.mp4 were replaced: \(twoEarlier) then \(ids(db, "u-002", "p.source = 'frame' and p.start < 180"))")
        #expect(!ids(db, "u-002", "p.id > \(twoAll.max() ?? 0)").isEmpty, "the next step of u-002.mp4 stored no new passage")
        #expect(db.integrity() == "ok", "integrity_check: \(db.integrity())")
    }
}
}

// MARK: lesson 6, a video the decoder keeps failing on (helper level, real undecodable files)

private struct HgvRun {
    var rows: [String: MrRow] = [:]
    var idle = false
    var exit: Int32?
    var seconds = 0.0
    var idleCPU = 0.0
    var idleWindow = 0.0
    var passageIDs: [String: [Int]] = [:]
    var stderr = ""
}

private let hgvStable: TimeInterval = 6

private func hgvRunHelper(_ world: AtWorld, files: Int) -> HgvRun {
    var run = HgvRun()
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
            if Date().timeIntervalSince(lastChange) >= hgvStable {
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

private func hgvDescribe(_ run: HgvRun) -> String {
    "\(mrDescribe(run.rows)); idle \(run.idle), exit \(run.exit.map(String.init) ?? "none"), \(Int(run.seconds)) s, idle CPU \(String(format: "%.2f", run.idleCPU)) of \(String(format: "%.1f", run.idleWindow)) s; stderr: \(run.stderr)"
}

extension EncodeHelperTests {
@Suite("HelperVideoGiveUpTests", .serialized)
struct HelperVideoGiveUpTests {

    // Convention 6: the two newest files are a real undecodable mp4 (random bytes) and a real cut mp4 (a good clip cut to 40 percent, index at the
    // end of the file), three older clips read fine. After two runs at most: both are could_not_read "damaged" with tries 0 (given up, never again),
    // the three older clips are done (nothing is blocked), every run ends at its stdin end, an idle helper does not spin, a third run changes
    // nothing, and the log and stderr hold no path and no name.
    @Test func anUndecodableMp4AndACutMp4AreGivenUpByTheEndOfTheSecondRunNeverBlockOlderClipsAndLeaveNoPathInTheLog() throws {
        let world = try AtWorld()
        defer { world.remove() }
        let dir = try MrDir()
        defer { dir.remove() }
        let whole = dir.file("whole.mp4")
        try MediaRig.writeVideo(whole, shots: MediaRig.shots([6, 6, 6, 6]))
        _ = try hvWrite(world, "zqxsecretbadone.mp4", { try hvRandomBytes(6000, seed: 11).write(to: URL(fileURLWithPath: $0)) }, age: 1)
        _ = try hvWrite(world, "zqxsecretbadtwo.mp4", { try MediaRig.cutCopy(of: whole, to: $0, fraction: 0.4) }, age: 2)
        for (index, name) in ["olderone", "oldertwo", "olderthree"].enumerated() {
            _ = try hvWrite(world, name + ".mp4", { try MediaRig.writeVideo($0, shots: MediaRig.shots([6, 6], firstShade: index)) }, age: 10 + 10 * index)
        }
        #expect(MediaRig.probeSeconds(world.photos.appendingPathComponent("zqxsecretbadone.mp4").path) == nil && MediaRig.probeSeconds(world.photos.appendingPathComponent("zqxsecretbadtwo.mp4").path) == nil,
                "setup: ffprobe still reads one of the two damaged clips")
        let forbidden = ["zqxsecret", world.photos.path, world.root.lastPathComponent]

        let first = hgvRunHelper(world, files: 5)
        #expect(first.idle && first.exit == 0, "run 1 did not end quiet and clean: \(hgvDescribe(first))")
        #expect(first.rows["zqxsecretbadone.mp4"]?.status != "done" && first.rows["zqxsecretbadtwo.mp4"]?.status != "done", "an undecodable clip is done after run 1: \(hgvDescribe(first))")
        let second = hgvRunHelper(world, files: 5)
        #expect(second.idle && second.exit == 0, "run 2 did not end quiet and clean: \(hgvDescribe(second))")
        for name in ["zqxsecretbadone.mp4", "zqxsecretbadtwo.mp4"] {
            let row = second.rows[name]
            #expect(row?.status == "could_not_read" && row?.reason == "damaged" && row?.tries == 0,
                    "\(name) should be given up (could_not_read, damaged, tries 0) no later than the end of the second run, got \(row.map { "\($0.status) \($0.reason ?? "no reason") tries \($0.tries)" } ?? "no row"): \(hgvDescribe(second))")
        }
        for name in ["olderone.mp4", "oldertwo.mp4", "olderthree.mp4"] {
            #expect(second.rows[name]?.status == "done" && second.rows[name]?.tries == 0, "\(name) is blocked behind the undecodable clips: \(hgvDescribe(second))")
        }
        #expect(second.idleCPU < 1.0, "the idle helper used \(String(format: "%.2f", second.idleCPU)) s of CPU in \(String(format: "%.1f", second.idleWindow)) s: a loop at full speed")

        let third = hgvRunHelper(world, files: 5)
        #expect(third.idle && third.exit == 0, "run 3 did not end quiet and clean: \(hgvDescribe(third))")
        #expect(third.passageIDs == second.passageIDs, "a third run read something again: ids \(second.passageIDs) then \(third.passageIDs)")
        #expect(third.rows["zqxsecretbadone.mp4"]?.status == "could_not_read" && third.rows["zqxsecretbadtwo.mp4"]?.status == "could_not_read", "a given-up clip came back: \(hgvDescribe(third))")
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

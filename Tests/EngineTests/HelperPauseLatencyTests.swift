import Foundation
import Testing
import SesameEngine

// plan-5-t3, tester step. Written from the entry plan-5-t3 of plan-5-tasks.md (Tests: HelperPauseLatencyTests), Decisions D3 and D10, the spec's
// S7.2 (Pause within 5 s on every unit kind) and design section 8 only; no product source is read. Pause is the app ending the helper's stdin; the
// helper stops at its next stop check, drops the step in flight uncommitted and exits. These tests run the bundled release helper with the cached
// REAL model (a unit of the real model is what can be slow), in the background, each file alone in its folder (the test makes the files).
//
// What every case does (T0 is the moment the test ends the helper's stdin):
//   1. T0 comes from a trigger: the helper's `unit` line count in the temp HOME's `index.log` (the entry says the second line; the first is used,
//      see the PDF case: a unit line is written once per step, so the second line of a two-step file is its last), or the moment the
//      file's attempt marker is first seen (`tries` 1: the step is in flight) plus a short wait (the "in flight" variant, which lands inside the
//      page recognition of a scan step or inside the frame decoding of a video step, before any embed unit exists).
//   2. At T0 the test checks the step really is in flight (the file is not `done`), ends stdin, and reads the rows once a second for 20 s.
//   3. Asserted (the entry's numbers): no passage is added later than T0 + 4.0 s; the helper exits (status 0) by then; the file is still `partial` or
//      `pending`, never half stored (no tries left set, integrity_check ok, every passage has its fts row); the index is whole.
//   4. A second helper run (the fake embedder: the ids do not depend on the embedder) finishes the file, and its passages (id, source, start, end)
//      are exactly those of an uninterrupted fake run of the same file in another throwaway HOME: Resume continues from where it stopped, and the
//      passages the first run stored are still there with the same ids.
//   5. Printed per case: the time from T0 to the last passage added and to the helper's exit (`READING pause ...`), for the report (U10).
//
// D3 (the audio tower under the 0.85 GB cap; fixed by the audio-only switch, the cases are enabled): the 12-minute WAV with the real model, and the
// preview case that rides on it, assertions unchanged. Audio is also covered with the fake embedder by `HelperAudioPauseTests`
// (HelperAudioTests.swift), which can show the stop check inside a step but not the time of a real audio unit.
//
// Note: a preview request that arrives inside a long scan or video step waits for the unit to end before it is answered.
//
// A unit is one embed unit (at most 16 inputs, 4 while the panel is open; for audio windows `audioUnitWindows` 4, fewer when 2,048 tokens do not
// fit) or one scan page's recognition. If a unit can exceed 4 s the unit shrinks (lever: 4 inputs; for a scan page, a smaller render); if one still
// exceeds 4 s the bar is not lowered: STOP-ASK naming the kind and its longest time.
//
// SHAPES THIS FILE PINS that the entry did not fix (each is one place to edit):
//   - a `unit n=<k>` line is written to `index.log` for every embed unit of a PDF, audio and video step, and nothing else starts a line with `unit`;
//   - the attempt marker (`files.tries` 1) is committed before a step starts (design section 1), so "in flight" is observable from the index;
//   - the helper exits 0 after its stdin ends in the middle of a step, as after any clean stop (IndexCleanStopTests).

private struct PlModels {
    let text: URL
    let mm: URL
}

private func plModels() throws -> PlModels {
    let text = try #require(KitPaths.textModel(),
                            "model file missing: $KIT_ROOT/cache/\(KitPaths.textModelName) (seed the cache: scripts/kit-mirror.sh seed --real)")
    let mm = text.deletingLastPathComponent().appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    try #require(FileManager.default.fileExists(atPath: mm.path), "model file missing: \(mm.path) (seed the cache: scripts/kit-mirror.sh seed --real)")
    return PlModels(text: text, mm: mm)
}

private func plStartReal(_ world: AtWorld, models: PlModels) throws -> HelperProcess {
    let executable = KitPaths.bundledHelper
    try #require(FileManager.default.isExecutableFile(atPath: executable.path), "the bundled helper is missing: run `scripts/bundle.sh` (expected \(executable.path))")
    homeLock.lock()
    defer { homeLock.unlock() }
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousFake = getenv("SESAME_FAKE_EMBEDDER").map { String(cString: $0) }
    setenv("HOME", world.home.path, 1)
    unsetenv("SESAME_FAKE_EMBEDDER")
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousFake { setenv("SESAME_FAKE_EMBEDDER", previousFake, 1) } else { unsetenv("SESAME_FAKE_EMBEDDER") }
    }
    return try HelperProcess(executable: executable, arguments: ["index", "--text-model", models.text.path, "--mm-model", models.mm.path])
}

private func plUnitLines(_ world: AtWorld) -> Int {
    mrIndexLog(world).split(separator: "\n").filter { $0.hasPrefix("unit n=") }.count
}

private func plPassageCount(_ db: AtDB, _ file: String) -> Int {
    db.int("select count(*) from passages p join files f on f.id = p.file_id where f.path like '%/\(file)'") ?? -1
}

private struct PlRow {
    let status: String
    let tries: Int
    let readTo: Int?
}

private func plRow(_ db: AtDB, _ file: String) -> PlRow? {
    guard let row = db.rows("select status, tries, read_to from files where path like '%/\(file)'")?.first, let status = row[0] else { return nil }
    return PlRow(status: status, tries: Int(row[1] ?? "") ?? -1, readTo: row[2].flatMap { Int($0) })
}

/// (id, source, start, end) of every passage of a file, in id order.
private func plShape(_ db: AtDB, _ file: String) -> [String] {
    (db.rows("select p.id, p.source, cast(p.start as integer), cast(p.\"end\" as integer) from passages p join files f on f.id = p.file_id where f.path like '%/\(file)' order by p.id") ?? [])
        .map { "\($0[0] ?? "?")|\($0[1] ?? "?")|\($0[2] ?? "?")|\($0[3] ?? "?")" }
}

private enum PlTrigger {
    /// Stdin ends when the helper's `index.log` holds this many `unit n=` lines.
    case unitLines(Int)
    /// Stdin ends this many seconds after the file's attempt marker is first seen (the step is in flight, no embed unit needed).
    case inFlight(after: TimeInterval)

    var label: String {
        switch self {
        case .unitLines(let n): return "unit line \(n)"
        case .inFlight(let seconds): return "in flight +\(seconds) s"
        }
    }
}

/// A clip made once in a temp folder and copied into each world (the interrupted run and the uninterrupted baseline hold the same bytes).
private struct PlClip {
    let name: String
    let source: String

    func place(in world: AtWorld) throws {
        let target = world.photos.appendingPathComponent(name).path
        try FileManager.default.copyItem(atPath: source, toPath: target)
        try mrAge(target, 1)
    }
}

/// The passages (id|source|start|end) an uninterrupted fake-embedder run of the clip stores, and the status it ends in.
private func plBaseline(_ clip: PlClip) throws -> [String] {
    let world = try AtWorld()
    defer { world.remove() }
    try clip.place(in: world)
    let helper = try atStartHelper(world)
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    let wait = mrWaitSettled(world, helper, expected: 1, stall: 300, cap: 900)
    guard wait.met, wait.rows[clip.name]?.status == "done" else {
        throw AtError("setup: the uninterrupted run of \(clip.name) did not reach done: \(mrDescribe(wait.rows)); stderr \(helper.errors)")
    }
    guard let db = world.db() else { throw AtError("setup: the baseline index cannot be read") }
    return plShape(db, clip.name)
}

private struct PlCase {
    var triggerSeen = false
    var triggerNote = ""
    var statusAtT0 = ""
    var passagesAtT0 = -1
    var growthAt: Double = 0
    var exitGap: Double?
    var exitStatus: Int32?
    var statusAfter = ""
    var triesAfter = -1
    var passagesAfter: [String] = []
    var whole: [String] = []
    var integrity = ""
    var stderr = ""
    var second = ""
    var secondShape: [String] = []
    var secondWhole: [String] = []
    var resumeNote = ""
}

/// One interrupted run (real model), then the resume run (fake embedder).
private func plRunCase(_ clip: PlClip, trigger: PlTrigger, models: PlModels) throws -> PlCase {
    var result = PlCase()
    let world = try AtWorld()
    defer { world.remove() }
    try clip.place(in: world)
    let helper = try plStartReal(world, models: models)
    defer { helper.stop() }
    helper.send(atFoldersLine([world.photos]))
    var db: AtDB?
    let started = Date()
    var markedAt: Date?
    waiting: while Date().timeIntervalSince(started) < 900 {
        if db == nil { db = world.db() }
        switch trigger {
        case .unitLines(let wanted):
            if plUnitLines(world) >= wanted { result.triggerSeen = true; break waiting }
        case .inFlight(let after):
            if let row = db.flatMap({ plRow($0, clip.name) }), row.tries >= 1 {
                if markedAt == nil { markedAt = Date() }
                if Date().timeIntervalSince(markedAt!) >= after { result.triggerSeen = true; break waiting }
            }
        }
        if let row = db.flatMap({ plRow($0, clip.name) }), row.status == "done" { result.triggerNote = "the file was done before the stop could be made"; break }
        if !helper.isRunning { result.triggerNote = "the helper was gone before the trigger"; break }
        if db.flatMap({ plRow($0, clip.name) }) == nil, Date().timeIntervalSince(started) > 240 { result.triggerNote = "the file has no row after 240 s"; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard result.triggerSeen else {
        if result.triggerNote.isEmpty { result.triggerNote = "the trigger \(trigger.label) never came in 900 s" }
        result.stderr = helper.errors
        return result
    }
    let t0 = Date()
    if let db {
        result.statusAtT0 = plRow(db, clip.name)?.status ?? "no row"
        result.passagesAtT0 = plPassageCount(db, clip.name)
    }
    helper.closeStdin()

    // read the rows once a second for 20 s
    var counts: [Int] = []
    for second in 1...20 {
        let due = t0.addingTimeInterval(Double(second))
        let wait = due.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        if db == nil { db = world.db() }
        counts.append(db.map { plPassageCount($0, clip.name) } ?? -1)
    }
    for (index, count) in counts.enumerated() where index > 0 && count > counts[index - 1] { result.growthAt = Double(index + 1) }
    if let ended = helper.waitForExit(timeout: 10) {
        result.exitGap = ended.at.timeIntervalSince(t0)
        result.exitStatus = ended.status
    }
    result.stderr = helper.errors
    if let after = world.db() {
        let row = plRow(after, clip.name)
        result.statusAfter = row?.status ?? "no row"
        result.triesAfter = row?.tries ?? -1
        result.passagesAfter = plShape(after, clip.name)
        result.whole = mrWholeProblems(after)
        result.integrity = after.integrity()
    }

    // the resume run, the fake embedder
    let second = try atStartHelper(world)
    defer { second.stop() }
    second.send(atFoldersLine([world.photos]))
    let wait = mrWaitSettled(world, second, expected: 1, stall: 300, cap: 900)
    result.second = wait.rows[clip.name]?.status ?? "no row"
    result.resumeNote = "\(mrDescribe(wait.rows)); stderr \(second.errors)"
    _ = atCleanStop(second)
    if let final = world.db() {
        result.secondShape = plShape(final, clip.name)
        result.secondWhole = mrWholeProblems(final)
    }
    return result
}

private func plCheck(_ result: PlCase, kind: String, trigger: PlTrigger, baseline: [String]) {
    let tag = "\(kind), stop at \(trigger.label)"
    guard result.triggerSeen else {
        Issue.record("\(tag): \(result.triggerNote); stderr: \(result.stderr.prefix(300))")
        return
    }
    let growth = result.growthAt == 0 ? "none after T0" : String(format: "%.0f s after T0", result.growthAt)
    print("READING pause \(tag): helper exit \(result.exitGap.map { String(format: "%.2f s", $0) } ?? "never") after T0, last passage added \(growth), file \(result.statusAfter), \(result.passagesAfter.count) passages (\(result.passagesAtT0) at T0)")
    #expect(result.statusAtT0 != "done", "\(tag): the file was already \(result.statusAtT0) at T0, so no step was in flight and the case proved nothing")
    #expect(result.exitStatus == 0, "\(tag): the helper should exit 0 after its stdin ended, status \(result.exitStatus.map(String.init) ?? "still running"); stderr: \(result.stderr.prefix(300))")
    #expect((result.exitGap ?? .infinity) <= 4.0, "\(tag): STOP-ASK if a unit cannot be made shorter: the helper exited \(result.exitGap.map { String(format: "%.2f", $0) } ?? "never") s after its stdin ended, the bar is 4.0 s (Pause lands within 5 s)")
    #expect(result.growthAt <= 4.0, "\(tag): a passage was added \(result.growthAt) s after T0, the bar is 4.0 s")
    #expect(result.statusAfter == "pending" || result.statusAfter == "partial", "\(tag): the file is \(result.statusAfter) after the stop, expected pending or partial (never half stored)")
    #expect(result.triesAfter == 0, "\(tag): a clean stop left the attempt marker at \(result.triesAfter), expected 0")
    #expect(result.integrity == "ok" && result.whole.isEmpty, "\(tag): the index is not whole after the stop: integrity \(result.integrity), \(result.whole)")
    #expect(result.second == "done", "\(tag): the next run did not finish the file: \(result.resumeNote)")
    #expect(result.secondWhole.isEmpty, "\(tag): the index is not whole after the resume: \(result.secondWhole)")
    #expect(result.secondShape == baseline, "\(tag): the finished file's passages (id|source|start|end) are \(result.secondShape.prefix(6))... (\(result.secondShape.count)), an uninterrupted run holds \(baseline.prefix(6))... (\(baseline.count)): Resume did not continue from where it stopped")
    #expect(Set(result.passagesAfter).isSubset(of: Set(result.secondShape)), "\(tag): a passage the first run stored is not there after the resume: the first steps were read again")
}

// MARK: the files, each made once

/// One temp folder for the three clips, removed at exit.
private let plDirPath: String? = {
    guard let dir = try? MrDir() else { return nil }
    atexit { if let path = plDirPath { try? FileManager.default.removeItem(atPath: path) } }
    return dir.path
}()

/// 60 picture pages (a word each; MARMALADE on page 12, TURQUOISE on page 55): two steps of 30 pages.
private let plPdf: PlClip? = {
    guard let dir = plDirPath else { return nil }
    let words = ["APRICOT", "BALLAD", "CANYON", "DOLPHIN", "EMBER", "FALCON", "GARNET", "HARVEST", "ISLAND", "JASMINE"]
    let pages: [ScanPdf.Page] = (1...60).map { page in
        switch page {
        case 12: return .picture("MARMALADE")
        case 55: return .picture("TURQUOISE")
        default: return .picture(words[page % words.count])
        }
    }
    let path = dir + "/longscan.pdf"
    guard (try? ScanPdf.write(pages, to: path)) != nil else { return nil }
    return PlClip(name: "longscan.pdf", source: path)
}()

/// 4 minutes, a new shot every 3 s (80 frames, none dropped as a repeat), no audio track: the vision path only.
private let plVideo: PlClip? = {
    guard let dir = plDirPath else { return nil }
    let path = dir + "/fourminutes.mp4"
    guard (try? MediaRig.writeVideo(path, shots: MediaRig.shots(Array(repeating: 3, count: 80)))) != nil else { return nil }
    return PlClip(name: "fourminutes.mp4", source: path)
}()

/// 12 minutes of continuous tone: about 29 windows over two steps of 500 s.
private let plAudio: PlClip? = {
    guard let dir = plDirPath else { return nil }
    let path = dir + "/twelveminutes.wav"
    guard (try? MediaRig.writeWav(path, rate: 16000, [.tone(720, db: -22, hz: 330)])) != nil else { return nil }
    return PlClip(name: "twelveminutes.wav", source: path)
}()

private func plRunKind(_ clip: PlClip?, kind: String, trigger: PlTrigger) throws {
    let models = try plModels()
    let clip = try #require(clip, "setup: the \(kind) file could not be made")
    let baseline = try plBaseline(clip)
    #expect(!baseline.isEmpty, "setup: the uninterrupted run of the \(kind) file stored nothing")
    let result = try plRunCase(clip, trigger: trigger, models: models)
    plCheck(result, kind: kind, trigger: trigger, baseline: baseline)
}

extension EncodeHelperTests {
@Suite("HelperPauseLatencyTests", .serialized)
struct HelperPauseLatencyTests {

    // (a) a 60-page picture-only PDF: the first step is 30 pages of recognition, then embed units of the scans.
    @Test func aSixtyPagePicturePdfStopsWithinFourSecondsOfStdinEndingInTheMiddleOfItsFirstStepOfPageRecognition() throws {
        try plRunKind(plPdf, kind: "60-page picture PDF", trigger: .inFlight(after: 2))
    }

    // The entry says "the second unit line". Measured against the plan-5-t2 helper with the real model: a 60-page picture PDF reaches `done` (two
    // steps) before a second `unit n=` line shows in the log, so a trigger on the second line never comes and the file is already done. The pick is
    // the first unit line, which lands inside the first step (the second step, 30 pages of recognition, is what a stop has to cut short).
    @Test func aSixtyPagePicturePdfStopsWithinFourSecondsOfStdinEndingAtItsFirstUnitLine() throws {
        try plRunKind(plPdf, kind: "60-page picture PDF", trigger: .unitLines(1))
    }

    // (c) a 4-minute mp4 whose shot changes every 3 s (80 frames): the first step is 60 frames, decoded and embedded in units.
    @Test func aFourMinuteVideoStopsWithinFourSecondsOfStdinEndingInTheMiddleOfItsFirstStepOfFrameDecoding() throws {
        try plRunKind(plVideo, kind: "4-minute video", trigger: .inFlight(after: 1.5))
    }

    // The first unit line, for the reason given at the PDF case (the entry's "second unit line" is unreachable when a unit line is written once per step).
    @Test func aFourMinuteVideoStopsWithinFourSecondsOfStdinEndingAtItsFirstUnitLine() throws {
        try plRunKind(plVideo, kind: "4-minute video", trigger: .unitLines(1))
    }

    // (b) a 12-minute continuous tone WAV, about 29 windows: needs the audio tower to load (D3, fixed by the audio-only switch).
    @Test func aTwelveMinuteWavStopsWithinFourSecondsOfStdinEndingAtItsFirstUnitLine() throws {
        try plRunKind(plAudio, kind: "12-minute WAV", trigger: .unitLines(1))
    }

    @Test func aTwelveMinuteWavStopsWithinFourSecondsOfStdinEndingInTheMiddleOfItsFirstStep() throws {
        try plRunKind(plAudio, kind: "12-minute WAV", trigger: .inFlight(after: 1))
    }

    // The fourth case: a preview request that arrives in the middle of a step is answered within 4.0 s (a plan 4 review note). The WAV is the
    // 12-minute one of (b); D3 is fixed (audio-only switch) and the case is enabled: once the first `unit` line is in the log and the file is
    // `partial` with no passage of the second step, the test writes a `preview` line for a photo in the same folder (indexed beforehand by the fake
    // embedder, so its row exists); the helper's reply line arrives within 4.0 s of that write; the file then finishes with the passages an
    // uninterrupted run holds. A preview that arrives inside a long scan or video step waits for the unit to end.
    @Test func aPreviewRequestThatArrivesInTheMiddleOfAnAudioStepIsAnsweredWithinFourSeconds() throws {
        let models = try plModels()
        let clip = try #require(plAudio, "setup: the WAV could not be made")
        let baseline = try plBaseline(clip)
        let world = try AtWorld()
        defer { world.remove() }
        let photo = world.photos.appendingPathComponent("previewphoto.jpg")
        try atMakePhotos(in: world.photos, names: ["previewphoto"], seedBase: 77, age: 3600)
        let warm = try atStartHelper(world)
        defer { warm.stop() }
        warm.send(atFoldersLine([world.photos]))
        let ready = mrWaitSettled(world, warm, expected: 1, stall: 120, cap: 300)
        #expect(ready.met && ready.rows["previewphoto.jpg"]?.status == "done", "setup: the photo did not reach done: \(mrDescribe(ready.rows))")
        #expect(atCleanStop(warm) == 0, "setup: the first helper did not exit 0")
        try clip.place(in: world)

        let helper = try plStartReal(world, models: models)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        var db: AtDB?
        let started = Date()
        var ready2 = false
        while Date().timeIntervalSince(started) < 900 {
            if db == nil { db = world.db() }
            if plUnitLines(world) >= 1, let row = db.flatMap({ plRow($0, clip.name) }), row.status == "partial", plPassageCount(db!, clip.name) > 0 { ready2 = true; break }
            if !helper.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(ready2, "the WAV never showed as partial after its first unit line; stderr: \(helper.errors)")
        let firstStepEnd = db.flatMap { plRow($0, clip.name)?.readTo }
        let pathJSON = String(data: try JSONSerialization.data(withJSONObject: photo.path, options: [.fragmentsAllowed]), encoding: .utf8) ?? "\"\""
        let writtenAt = Date()
        helper.send("{\"cmd\":\"preview\",\"ticket\":7,\"file\":\(pathJSON),\"passage\":null,\"query\":\"\"}")
        var replyAt: Date?
        while Date().timeIntervalSince(writtenAt) < 30 {
            guard let line = helper.nextLine(timeout: 0.05) else { continue }
            if let reply = HelperReply(line.text), reply.event == "preview", (reply.object["ticket"] as? Int) == 7 {
                replyAt = line.at
                break
            }
        }
        let gap = replyAt.map { $0.timeIntervalSince(writtenAt) }
        print("READING pause preview-in-step: reply \(gap.map { String(format: "%.2f s", $0) } ?? "never") after the preview line (first step ended at \(firstStepEnd.map(String.init) ?? "nil"))")
        // Owner's decision: the helper answers a preview only after the current unit or step ends; a between-units answer is not built. The spec
        // promises responsiveness, not an ordering mechanism, so the entry's "before the step commits" check (read_to still the first step's at
        // the reply) over-specified it and is removed. The 4.0 s bar stays; the measured reply was 3.42 s.
        #expect((gap ?? .infinity) <= 4.0, "the preview reply came \(gap.map { String(format: "%.2f", $0) } ?? "never") s after the request, the bar is 4.0 s")
        let wait = mrWaitSettled(world, helper, expected: 2, stall: 300, cap: 900)
        #expect(wait.met && wait.rows[clip.name]?.status == "done", "the WAV did not finish after the preview: \(mrDescribe(wait.rows))")
        if let final = world.db() { #expect(plShape(final, clip.name).map { $0.split(separator: "|").dropFirst().joined(separator: "|") } == baseline.map { $0.split(separator: "|").dropFirst().joined(separator: "|") }, "the finished WAV's passages differ from an uninterrupted run's") }
    }
}
}

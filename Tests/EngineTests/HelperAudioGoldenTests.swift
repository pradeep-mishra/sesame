import Foundation
import Testing
import SesameEngine

// plan-5-t2, tester step. Written from the entry plan-5-t2 of plan-5-tasks.md (Tests: HelperAudioGoldenTests), Decision D5, the key
// fixtures/answers.csv (the eight `audio` rows, read here, never changed) and t1's report only; no product source is read.
//
// `kit-fixtures.sh build golden-av` is a child process under a throwaway KIT_ROOT (it needs `say` and `ffmpeg`: outside the sandbox).
// The bundled release helper alone, fake embedder, throwaway HOME, indexes `golden-av/audio` (12 clips) and `golden-av/damaged`
// (`broken.m4a`, `broken.mp4`). t2 reads audio only: the video clips are not picked here, and `broken.mp4` (in `damaged/`) has no row
// until t3, so this file looks at the rows of kind `audio` only.
//
// The independent reader is `ffmpeg`: the test decodes each clip to 16 kHz mono float samples, takes the RMS of every 0.5 s frame and
// walks the rule of D5 with constants written HERE (frame 0.5 s, stride 25 s, window 30 s, silence at -54 dBFS): a window starts at the
// first frame whose RMS is at or above the silence level, at or after `next`, and `next` is that start plus 25 s. The helper's stored
// window starts are compared with that walk.
//
// What is asserted (the entry's, then one more):
//   - the 12 golden clips are done, kind audio; the damaged `broken.m4a` is could_not_read (damaged) and keeps no passage;
//   - the first window of `sleep-interview.m4a` whose span holds second 130 starts within 2 s of 130 (the spec's [02:10, 02:40]); the
//     same for each of the 8 `audio` rows' `locator` (windows start at the sound, D5: "within 2 s" is [locator, locator + 2]);
//   - the stored window starts of `sleep-interview.m4a` match the independent walk (each stored start has a walked start within 1 s and
//     each walked start a stored one within 1 s): the reader read against t1's independent window starts.
//
// SHAPE PINNED that the entry did not fix: a window "holds" a second S when start <= S < end, with the stored whole seconds.

private let ggProject = KitPaths.projectRoot
private let ggFfmpeg = "/opt/homebrew/bin/ffmpeg"

private struct GgRow {
    let id: String
    let file: String
    let locator: Int
}

private let ggRows: [GgRow] = {
    guard let text = try? String(contentsOf: ggProject.appendingPathComponent("fixtures/answers.csv"), encoding: .utf8) else { return [] }
    var rows: [GgRow] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where index > 0 {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7, fields[1] == "audio" else { continue }
        let parts = fields[4].split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { continue }
        rows.append(GgRow(id: fields[0], file: fields[3], locator: parts[0] * 60 + parts[1]))
    }
    return rows
}()

/// The clip as 16 kHz mono float samples, decoded by ffmpeg (an independent reader).
private func ggDecode(_ path: String) -> [Float]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ggFfmpeg)
    process.arguments = ["-v", "error", "-i", path, "-ac", "1", "-ar", "16000", "-f", "f32le", "-"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, !data.isEmpty else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// The rule of D5 over decoded samples, constants by hand: the start seconds of every window.
private func ggWalk(_ samples: [Float]) -> [Double] {
    let frame = 8000
    let threshold = pow(10.0, -54.0 / 20.0)
    var loud: [Bool] = []
    var index = 0
    while index + frame <= samples.count {
        var sum = 0.0
        for value in samples[index..<(index + frame)] { sum += Double(value) * Double(value) }
        loud.append((sum / Double(frame)).squareRoot() >= threshold)
        index += frame
    }
    var starts: [Double] = []
    var next = 0.0
    while true {
        guard let found = loud.indices.first(where: { Double($0) * 0.5 >= next && loud[$0] }) else { break }
        let start = Double(found) * 0.5
        starts.append(start)
        next = start + 25
    }
    return starts
}

private struct GgOutcome {
    var setupProblem: String?
    var rows: [String: MrRow] = [:]
    var passages: [String: [MrPassage]] = [:]
    var walked: [Double] = []
    var integrity = ""
    var exit: Int32?
    var summary = ""
}

private let ggOutcome: GgOutcome = {
    var out = GgOutcome()
    guard let kit = MrKit() else { out.setupProblem = "could not make a temp kit root"; return out }
    let built = kit.build("golden-av")
    guard let built, built.status == 0 else {
        out.setupProblem = "kit-fixtures.sh build golden-av failed (status \(built.map { String($0.status) } ?? "not run")): \(mrTail(built?.output ?? "no output"))"
        return out
    }
    let av = kit.fixtures + "/golden-av"
    guard let clip = ggDecode(av + "/audio/sleep-interview.m4a") else {
        out.setupProblem = "ffmpeg could not decode sleep-interview.m4a"
        return out
    }
    out.walked = ggWalk(clip)
    guard let world = try? AtWorld() else { out.setupProblem = "could not make a temp world"; return out }
    defer { world.remove() }
    guard let helper = try? atStartHelper(world) else { out.setupProblem = "the bundled helper could not be started (run scripts/bundle.sh)"; return out }
    defer { helper.stop() }
    helper.send(atFoldersLine([URL(fileURLWithPath: av + "/audio", isDirectory: true), URL(fileURLWithPath: av + "/damaged", isDirectory: true)]))
    let started = Date()
    var settled = false
    var lastChange = started
    var lastSignature = ""
    var db: AtDB?
    while true {
        if db == nil { db = world.db() }
        if let db, let rows = mrRows(db) {
            let audio = rows.filter { $0.value.kind == "audio" }
            let signature = audio.keys.sorted().map { "\($0)=\(audio[$0]!.status)/\(audio[$0]!.readTo ?? -1)" }.joined(separator: ",")
            if signature != lastSignature { lastSignature = signature; lastChange = Date() }
            if audio.count == 13 && audio.values.allSatisfy({ mrIsFinal($0.status) }) { settled = true; break }
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

private struct GgStop: Error {}

private func ggOutcomeOrStop() throws -> GgOutcome {
    let outcome = ggOutcome
    if let problem = outcome.setupProblem {
        Issue.record("setup failed: \(problem)")
        throw GgStop()
    }
    return outcome
}

/// The stored windows of a clip, in start order.
private func ggWindows(_ outcome: GgOutcome, _ name: String) -> [(start: Int, end: Int)] {
    (outcome.passages[name] ?? []).filter { $0.source == "audio" }.compactMap { passage -> (start: Int, end: Int)? in
        guard let start = passage.start, let end = passage.end else { return nil }
        return (start, end)
    }.sorted { $0.start < $1.start }
}

extension EncodeHelperTests {
@Suite("HelperAudioGoldenTests", .serialized)
struct HelperAudioGoldenTests {

    @Test func theKeyHoldsEightAudioRowsAndTheSpecsExampleIsAtTwoTen() {
        #expect(ggRows.count == 8, "fixtures/answers.csv holds \(ggRows.count) audio rows, expected 8")
        #expect(ggRows.first { $0.file == "audio/sleep-interview.m4a" }?.locator == 130, "the sleep interview's locator is not 02:10")
    }

    @Test func theTwelveGoldenClipsAreDoneAudioAndTheDamagedM4aIsCouldNotReadWithNoPassage() throws {
        let outcome = try ggOutcomeOrStop()
        let audio = outcome.rows.filter { $0.value.kind == "audio" }
        #expect(audio.count == 13, "the index holds \(audio.count) audio rows, expected 12 clips and broken.m4a: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        let broken = outcome.rows["broken.m4a"]
        #expect(broken?.status == "could_not_read" && broken?.reason == "damaged" && broken?.tries == 0,
                "broken.m4a should be could_not_read (damaged), got \(broken.map { "\($0.status) \($0.reason ?? "no reason")" } ?? "no row"); \(outcome.summary)")
        #expect((outcome.passages["broken.m4a"] ?? []).isEmpty, "broken.m4a was given up and keeps passages")
        let others = audio.filter { $0.key != "broken.m4a" }
        #expect(others.count == 12 && others.values.allSatisfy { $0.status == "done" },
                "every other audio file should be done: \(mrDescribe(outcome.rows)); \(outcome.summary)")
        for (name, _) in others {
            let passages = outcome.passages[name] ?? []
            #expect(passages.filter { $0.source == "name" }.count == 1, "\(name) holds \(passages.filter { $0.source == "name" }.count) name passages, expected 1")
            #expect(passages.filter { $0.source == "audio" }.allSatisfy { $0.vecBytes == 1536 && $0.modality == "audio" }, "\(name) holds a window without a vector")
        }
        #expect(outcome.integrity == "ok", "PRAGMA integrity_check gave \(outcome.integrity)")
        #expect(outcome.exit == 0, "the helper should exit 0 within 60 s of its stdin ending, status \(outcome.exit.map(String.init) ?? "still running")")
    }

    @Test func theFirstWindowOfTheSleepInterviewThatHoldsSecondOneThirtyStartsWithinTwoSecondsOfOneThirty() throws {
        let outcome = try ggOutcomeOrStop()
        let windows = ggWindows(outcome, "sleep-interview.m4a")
        #expect(!windows.isEmpty, "sleep-interview.m4a has no window passage; \(outcome.summary)")
        let first = windows.first { $0.start <= 130 && 130 < $0.end }
        #expect(first != nil && (130...132).contains(first!.start),
                "the first window holding second 130 starts at \(first.map { String($0.start) } ?? "none"), expected 130 to 132 (the spec's [02:10, 02:40]); windows \(windows.map { "\($0.start)-\($0.end)" })")
    }

    @Test func theFirstWindowHoldingEachAudioRowsLocatorStartsWithinTwoSecondsOfIt() throws {
        let outcome = try ggOutcomeOrStop()
        #expect(ggRows.count == 8, "the key holds \(ggRows.count) audio rows")
        for row in ggRows {
            let name = (row.file as NSString).lastPathComponent
            let windows = ggWindows(outcome, name)
            let first = windows.first { $0.start <= row.locator && row.locator < $0.end }
            #expect(first != nil && (row.locator...(row.locator + 2)).contains(first!.start),
                    "\(row.id) \(name): the first window holding second \(row.locator) starts at \(first.map { String($0.start) } ?? "none"), expected \(row.locator) to \(row.locator + 2); windows \(windows.map { "\($0.start)-\($0.end)" })")
        }
    }

    @Test func theStoredWindowStartsOfTheSleepInterviewMatchTheIndependentWalkOfTheRuleOfD5() throws {
        let outcome = try ggOutcomeOrStop()
        let stored = ggWindows(outcome, "sleep-interview.m4a").map { Double($0.start) }
        #expect(!outcome.walked.isEmpty, "the independent walk found no sound in sleep-interview.m4a")
        for start in stored {
            #expect(outcome.walked.contains { abs($0 - start) <= 1 }, "stored window start \(start) has no walked start within 1 s; walked \(outcome.walked), stored \(stored)")
        }
        for start in outcome.walked {
            #expect(stored.contains { abs($0 - start) <= 1 }, "walked window start \(start) has no stored start within 1 s; walked \(outcome.walked), stored \(stored)")
        }
        #expect(stored.count == outcome.walked.count, "stored \(stored.count) windows, the independent walk makes \(outcome.walked.count)")
    }
}
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import SesameEngine

// plan-4 review round 2, fix round, tester step: must-fix 2 (a file Vision keeps failing on blocks the files behind it, and is
// never given up). Written from the reviewer's report, the brief and the existing helper rigs only. Product source read: none.
// The harness is IndexAttemptTests.swift's (`At...`: AtWorld, AtDB, atRows, atStartHelper, atFoldersLine, atMakePhotos, atPast,
// atHelperWarm, atCleanStop); a run is the bundled release helper (`dist/Sesame.app/Contents/MacOS/SesameHelper index`, run
// `scripts/bundle.sh` first: a stale bundle makes these tests fail, never pass), `SESAME_FAKE_EMBEDDER=1`, a throwaway HOME.
//
// THE SEAM (measured, no product change). Vision's text recognition throws for a picture that is 2 pixels or less in one
// dimension ("The image is too small in at least one dimension ... each dimension has to be more than 2 pixels", Vision error
// code 13). A PNG of 1 x 1, 2 x 2, 1 x 200 or 200 x 1 pixels decodes (ImageIO reads it, so it is not "damaged") but Vision fails on
// it, in both attempts of the retry, every time. Measured in a probe run through the bundled helper: such a photo stays `pending`
// with tries 1 when another photo was read first in the run, and a 300 x 200 PNG is `done`. So `tinyPhoto(...)` below is the
// file "Vision keeps failing on". It is a photo, not a scan PDF: no PDF page was found that fails (a PDF page is rendered at a
// size the product chooses).
//
// THE RULE these tests pin (the brief's):
//   - A scan file whose Vision recognition fails in two separate helper runs becomes `could_not_read` (reason "damaged", tries 0),
//     whether or not another file succeeded earlier in either run.
//   - A failing file that is the NEWEST pending file does not block older files forever: after at most two failing runs the older
//     readable files are `done`.
//   - A file that failed once is not given up: after one failing run it is not `could_not_read`.
//   - A run always ends: the helper exits 0 within 60 s of its stdin ending, and idles at no full-speed loop.
//
// HOW A RUN IS MADE. The helper is started, given the one `folders` line, and left alone until the index is quiet: every file has
// a row, and the statuses, tries and passage count have not changed for 8 s (that is "to idle"; there is no idle event). Then its
// stdin ends and it must exit 0. A run takes about 10 s. Between runs the test may add or replace files, the way a person does.
//
// SHAPES THIS FILE PINS that the brief did not fix:
//   - "damaged" is the reason of the given-up file, and its `tries` is 0 (the sealed rule of a could_not_read row).
//   - Scenario (d) replaces the file between the two runs (a new picture under the same name, a new size and time): a file that
//     fails once and then reads fine can only be built that way without a product seam. It must end `done` with tries 0.
//   - "A few runs" of scenario (c) is at most 4.
//   - After the first failing run a text file may be done or still pending (not pinned); after the second it must be done.

private let vgStable: TimeInterval = 8
private let vgCap: TimeInterval = 150

// MARK: the files

/// A solid-colour PNG of `width` x `height` pixels. Vision cannot recognise text in it when a side is 2 pixels or less (so it is a
/// "tiny photo" then; at 300 x 200 it reads fine, which scenario (d) uses as the replacement picture).
private func vgTinyPhoto(_ folder: URL, _ name: String, width: Int, height: Int, age: Int) throws {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw AtError("the test could not make a \(width) x \(height) context")
    }
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw AtError("the test could not make a \(width) x \(height) picture") }
    let url = folder.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw AtError("the test could not start \(name)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw AtError("the test could not write \(name)") }
    try vgAge(url, age)
}

private func vgAge(_ url: URL, _ seconds: Int) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - Double(seconds))], ofItemAtPath: url.path)
}

/// A good picture Vision reads (noise, 96 x 96; no words, a read that finds nothing is still a success).
private func vgGoodPhoto(_ folder: URL, _ name: String, seed: Int, age: Int) throws {
    try atMakePhotos(in: folder, names: [name], seedBase: seed, age: age)
}

private func vgTextFile(_ folder: URL, _ name: String, word: String, age: Int) throws {
    let url = folder.appendingPathComponent(name)
    try "A short note about \(word) and the harvest of the year, written for the neighbours.\n".write(to: url, atomically: true, encoding: .utf8)
    try vgAge(url, age)
}

// MARK: one helper run, to idle

private struct VgRun {
    var rows: [String: AtRow] = [:]
    var idle = false
    var exit: Int32?
    var seconds = 0.0
    /// CPU seconds the helper used over the last quiet stretch (the last `vgStable` s of a run, give or take a poll).
    var idleCPU = 0.0
    var idleWindow = 0.0
    var passages = 0
    var stderr = ""
}

private func vgCPUSeconds(pid: Int32) -> Double? {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else { return nil }
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)
    return Double(info.ri_user_time &+ info.ri_system_time) * Double(base.numer) / Double(base.denom) / 1_000_000_000
}

/// Starts the helper, sends the folder, waits until `files` rows exist and nothing has changed for `vgStable` s, ends stdin and waits
/// for the exit.
private func vgRunHelper(_ world: AtWorld, files: Int) -> VgRun {
    var run = VgRun()
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
    var cpuAtChange = vgCPUSeconds(pid: helper.pid) ?? 0
    while true {
        if db == nil { db = world.db() }
        if let db, let rows = atRows(db), rows.count == files, let count = db.int("select count(*) from passages") {
            let signature = rows.keys.sorted().map { "\($0)=\(rows[$0]!.status)/\(rows[$0]!.tries)/\(rows[$0]!.reason ?? "-")" }.joined(separator: ",") + "|\(count)"
            if signature != lastSignature {
                lastSignature = signature
                lastChange = Date()
                cpuAtChange = vgCPUSeconds(pid: helper.pid) ?? cpuAtChange
            }
            run.rows = rows
            run.passages = count
            if Date().timeIntervalSince(lastChange) >= vgStable {
                run.idle = true
                run.idleWindow = Date().timeIntervalSince(lastChange)
                run.idleCPU = (vgCPUSeconds(pid: helper.pid) ?? cpuAtChange) - cpuAtChange
                break
            }
        }
        if Date().timeIntervalSince(started) > vgCap { break }
        if !helper.isRunning { Thread.sleep(forTimeInterval: 0.3); if !helper.isRunning { break } }
        Thread.sleep(forTimeInterval: 0.1)
    }
    run.exit = atCleanStop(helper, timeout: 60)
    run.seconds = Date().timeIntervalSince(started)
    run.stderr = helper.errors
    if let db = world.db() ?? db, let rows = atRows(db) { run.rows = rows }
    return run
}

private func vgDescribe(_ run: VgRun) -> String {
    "\(atDescribe(run.rows)); idle \(run.idle), exit \(run.exit.map(String.init) ?? "none"), \(Int(run.seconds)) s, idle CPU \(String(format: "%.2f", run.idleCPU)) of \(String(format: "%.1f", run.idleWindow)) s; stderr: \(run.stderr)"
}

/// What every run must do, whatever the files: reach idle, exit 0 at stdin end.
private func vgExpectRunEnds(_ run: VgRun, _ label: String) {
    #expect(run.idle, "\(label): the index never went quiet within \(Int(vgCap)) s with every file listed: \(vgDescribe(run))")
    #expect(run.exit == 0, "\(label): the helper should exit 0 within 60 s of its stdin ending: \(vgDescribe(run))")
}

private func vgIsGivenUp(_ row: AtRow?) -> Bool {
    row?.status == "could_not_read" && row?.reason == "damaged" && row?.tries == 0
}

private func vgIsDone(_ row: AtRow?) -> Bool { row?.status == "done" && row?.tries == 0 }

private func vgWithWorld(_ body: (AtWorld) throws -> Void) throws {
    _ = atHelperWarm
    let world = try AtWorld()
    defer { world.remove() }
    try body(world)
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("HelperVisionGiveUpTests", .serialized)
struct HelperVisionGiveUpTests {

    // The seam itself: a control. A good photo beside a tiny one is read (done); the tiny one is not read and not damaged.
    @Test func aTinyPhotoIsNotReadByVisionAndIsNotDamagedAfterOneRunWhileAGoodPhotoBesideItIsDone() throws {
        try vgWithWorld { world in
            try vgGoodPhoto(world.photos, "good-photo", seed: 11, age: 1)
            try vgTinyPhoto(world.photos, "tiny-photo.png", width: 1, height: 1, age: 2)
            let run = vgRunHelper(world, files: 2)
            vgExpectRunEnds(run, "run 1")
            #expect(vgIsDone(run.rows["good-photo.jpg"]), "the good photo should be done: \(vgDescribe(run))")
            #expect(run.rows["tiny-photo.png"]?.status == "pending" && run.rows["tiny-photo.png"]?.tries == 1,
                    "the tiny photo should be pending with tries 1 (Vision failed on it once, a success came first): \(vgDescribe(run))")
        }
    }

    // (a) a bad scan file NEWEST, three good older text files: two runs.
    @Test func aBadFileThatIsTheNewestPendingOneDoesNotBlockThreeOlderTextFilesAfterTwoRuns() throws {
        try vgWithWorld { world in
            try vgTinyPhoto(world.photos, "bad-newest.png", width: 1, height: 1, age: 1)
            for (index, word) in ["lanterns", "meadows", "orchards"].enumerated() {
                try vgTextFile(world.photos, "note-\(index + 1).txt", word: word, age: 10 + 10 * index)
            }
            let first = vgRunHelper(world, files: 4)
            vgExpectRunEnds(first, "run 1")
            #expect(first.rows["bad-newest.png"]?.status != "could_not_read",
                    "one failed run must not give a file up: \(vgDescribe(first))")
            let second = vgRunHelper(world, files: 4)
            vgExpectRunEnds(second, "run 2")
            #expect(vgIsGivenUp(second.rows["bad-newest.png"]),
                    "after two runs in which Vision failed on it the file should be could_not_read (damaged) with tries 0: \(vgDescribe(second))")
            for number in 1...3 {
                #expect(vgIsDone(second.rows["note-\(number).txt"]),
                        "after two runs the older text file note-\(number).txt should be done, the bad newest file must not block it: \(vgDescribe(second))")
            }
        }
    }

    // (b) a bad file OLDER than a good scan file that succeeds: two runs.
    @Test func aBadPhotoOlderThanAGoodPhotoIsGivenUpAfterTwoRunsAndTheGoodPhotoIsDone() throws {
        try vgWithWorld { world in
            try vgGoodPhoto(world.photos, "good-newer", seed: 21, age: 1)
            try vgTinyPhoto(world.photos, "bad-older.png", width: 1, height: 1, age: 5)
            let first = vgRunHelper(world, files: 2)
            vgExpectRunEnds(first, "run 1")
            #expect(vgIsDone(first.rows["good-newer.jpg"]), "the good photo should be done after run 1: \(vgDescribe(first))")
            #expect(first.rows["bad-older.png"]?.status != "could_not_read", "one failed run must not give a file up: \(vgDescribe(first))")
            let second = vgRunHelper(world, files: 2)
            vgExpectRunEnds(second, "run 2")
            #expect(vgIsGivenUp(second.rows["bad-older.png"]),
                    "after two runs in which Vision failed on it the file should be could_not_read (damaged) with tries 0: \(vgDescribe(second))")
            #expect(vgIsDone(second.rows["good-newer.jpg"]), "the good photo stays done: \(vgDescribe(second))")
        }
    }

    // A failure in a run in which nothing had succeeded yet counts as a failed run: a bad file alone in run 1, a good newer
    // photo is added for run 2 and is read first, so in run 2 the bad file fails after a success. Two separate runs, one of each kind.
    @Test func aFailureInARunWithNoEarlierSuccessAndAFailureInALaterRunWithOneTogetherGiveTheFileUp() throws {
        try vgWithWorld { world in
            try vgTinyPhoto(world.photos, "bad-alone.png", width: 1, height: 1, age: 5)
            let first = vgRunHelper(world, files: 1)
            vgExpectRunEnds(first, "run 1")
            #expect(first.rows["bad-alone.png"]?.status != "could_not_read", "one failed run must not give a file up: \(vgDescribe(first))")
            try vgGoodPhoto(world.photos, "good-added", seed: 31, age: 1)
            let second = vgRunHelper(world, files: 2)
            vgExpectRunEnds(second, "run 2")
            #expect(vgIsDone(second.rows["good-added.jpg"]), "the added good photo should be done after run 2: \(vgDescribe(second))")
            #expect(vgIsGivenUp(second.rows["bad-alone.png"]),
                    "Vision failed on it in run 1 (nothing had succeeded) and in run 2 (a photo had): two separate runs, so it should be could_not_read (damaged), tries 0: \(vgDescribe(second))")
        }
    }

    // The same two kinds of run the other way round: run 1 fails after a success, run 2 fails with none.
    @Test func aFailureAfterASuccessInRunOneAndAFailureWithNoneInRunTwoGiveTheFileUpToo() throws {
        try vgWithWorld { world in
            try vgGoodPhoto(world.photos, "good-first", seed: 41, age: 1)
            try vgTinyPhoto(world.photos, "bad-second.png", width: 2, height: 2, age: 5)
            let first = vgRunHelper(world, files: 2)
            vgExpectRunEnds(first, "run 1")
            let second = vgRunHelper(world, files: 2)
            vgExpectRunEnds(second, "run 2")
            #expect(vgIsGivenUp(second.rows["bad-second.png"]),
                    "a 2 x 2 photo Vision fails on in two runs should be could_not_read (damaged), tries 0: \(vgDescribe(second))")
            #expect(vgIsDone(second.rows["good-first.jpg"]), "the good photo stays done: \(vgDescribe(second))")
        }
    }

    // (c) two failing files and one good file (an older photo): resolved in a few runs, every run ends, nothing spins.
    @Test func twoFailingPhotosAndOneGoodOlderPhotoAreAllResolvedWithinFourRunsAndEveryRunEndsWithoutSpinning() throws {
        try vgWithWorld { world in
            try vgTinyPhoto(world.photos, "bad-one.png", width: 1, height: 1, age: 1)
            try vgTinyPhoto(world.photos, "bad-two.png", width: 1, height: 200, age: 2)
            try vgGoodPhoto(world.photos, "good-old", seed: 51, age: 30)
            var last = VgRun()
            var runs = 0
            var describe: [String] = []
            while runs < 4 {
                runs += 1
                last = vgRunHelper(world, files: 3)
                vgExpectRunEnds(last, "run \(runs)")
                #expect(last.idleCPU < 0.5 * max(last.idleWindow, 1),
                        "run \(runs): the helper used \(String(format: "%.2f", last.idleCPU)) s of CPU in its last \(String(format: "%.1f", last.idleWindow)) s of quiet: it spins")
                describe.append("run \(runs): \(atDescribe(last.rows))")
                if vgIsGivenUp(last.rows["bad-one.png"]) && vgIsGivenUp(last.rows["bad-two.png"]) && vgIsDone(last.rows["good-old.jpg"]) { break }
            }
            #expect(vgIsGivenUp(last.rows["bad-one.png"]), "bad-one.png should be could_not_read (damaged) within 4 runs: \(describe)")
            #expect(vgIsGivenUp(last.rows["bad-two.png"]), "bad-two.png should be could_not_read (damaged) within 4 runs: \(describe)")
            #expect(vgIsDone(last.rows["good-old.jpg"]), "good-old.jpg should be done within 4 runs: \(describe)")
        }
    }

    // (d) a file that fails once and then reads fine on the next run is done, not given up.
    @Test func aPhotoThatFailedInRunOneAndIsReplacedByAGoodPictureIsDoneAfterRunTwoNotGivenUp() throws {
        try vgWithWorld { world in
            try vgTinyPhoto(world.photos, "flaky.png", width: 1, height: 1, age: 3)
            try vgTextFile(world.photos, "older-note.txt", word: "willows", age: 20)
            let first = vgRunHelper(world, files: 2)
            vgExpectRunEnds(first, "run 1")
            #expect(first.rows["flaky.png"]?.status != "could_not_read", "one failed run must not give a file up: \(vgDescribe(first))")
            try FileManager.default.removeItem(at: world.photos.appendingPathComponent("flaky.png"))
            try vgTinyPhoto(world.photos, "flaky.png", width: 300, height: 200, age: 1)
            let second = vgRunHelper(world, files: 2)
            vgExpectRunEnds(second, "run 2")
            #expect(vgIsDone(second.rows["flaky.png"]), "the replaced file reads fine, it should be done with tries 0, not given up: \(vgDescribe(second))")
            #expect(vgIsDone(second.rows["older-note.txt"]), "the older text file should be done: \(vgDescribe(second))")
        }
    }
}
}

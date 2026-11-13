import Foundation
import Speech
import Testing
import SesameEngine

// plan-5-t4, tester step. Written from the entry plan-5-t4 of plan-5-tasks.md (Tests), the Conventions, the Decisions D3 to D8 and D11, the
// t2 and t3 tester and implementer reports and the plan 4 preview tests (PreviewReaderPdfTests is the model) only; no product source is
// read. The shapes this file pins that the entry did not fix are listed at the top of PreviewMediaRig.swift.
//
// How a run is made, as PreviewReaderAudioTests does it: one shared world, the bundled release helper alone with the fake embedder and a
// throwaway HOME indexes six mp4 files this file writes with `MediaRig.writeVideo` (t3's rig: a SHOT is a pattern drawn in one of the eight
// shades of `MediaRig.shades`, a new shot every 10 s or so); then `PreviewReader(scratch:speech:).reply` is called in this process with passage
// ids read from the index. The speech service is a fake that cannot recognize (`supportsOnDevice` false) so no test of this file can reach
// the live recognizer or its authorization.
//
// The file `vidcuts.mp4` is 90 s of eight shots (320 x 192, 5 frames a second, H.264) that start at 0, 12, 22, 32, 42, 52, 62 and 72 and have
// the shades 0 to 7 in that order (the shade of a shot is its number), with a soundtrack of 20 s of digital silence and then a 330 Hz tone to
// the end. By the t3 pins its frame passages are the first multiple of 3 s inside each shot (0, 12, 24, 33, 42, 54, 63, 72) and its soundtrack
// windows start at 20, 45 and 70. Shade 7 is a light grey that a pane's own background can look like, so no test reads it. The other five files
// (`vidswap-longer.mp4`, `vidswap-shorter.mp4`, `vidgone-deleted.mp4`, `vidgone-moved.mp4`, `vidbroken.mp4`) are the same picture with no
// soundtrack; each test mutates only its own.
//
// The independent judges: how the test built the clip (a shot's start second and its shade), the t3 rig's palette (a shade and its dim cell),
// and this file's own pixel counts in the PNG the reply names: the dominant shade of the picture is the shade of the shot at that second and
// not of the shot 20 s earlier; the timeline marker is found as the place where the PNGs of two replies of one file differ in a narrow strip.

private let pvdMainName = "vidcuts.mp4"
private let pvdDurations: [Double] = [12, 10, 10, 10, 10, 10, 10, 18]

private func pvdWrite(_ path: String, durations: [Double], firstShade: Int = 0, soundtrack: String? = nil) throws {
    try MediaRig.writeVideo(path, shots: MediaRig.shots(durations, firstShade: firstShade), soundtrack: soundtrack)
}

private struct PvdWorld: @unchecked Sendable {
    var world: AtWorld?
    var problem: String?

    var folder: String { world?.photos.path ?? "" }
    func path(_ name: String) -> String { folder + "/" + name }
    var home: String { world?.home.path ?? "" }

    func passage(_ file: String, source: String, start: Int) -> Int? {
        world?.db()?.int("""
            select p.id from passages p join files f on f.id = p.file_id \
            where f.path like '%/\(file)' and p.source = '\(source)' and cast(p.start as integer) = \(start)
            """)
    }
}

private let pvdWorld: PvdWorld = {
    var out = PvdWorld()
    guard let world = try? AtWorld() else { out.problem = "could not make a temp world"; return out }
    out.world = world
    pmKeeper.add(world)
    atexit { pmKeeper.run() }
    let source = world.root.appendingPathComponent("src", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sound = source.appendingPathComponent("soundtrack.wav").path
        try MediaRig.writeWav(sound, [.silence(20), .tone(70, db: -25, hz: 330)])
        try pvdWrite(out.path(pvdMainName), durations: pvdDurations, soundtrack: sound)
        try mrAge(out.path(pvdMainName), 10)
        for (index, name) in ["vidswap-longer.mp4", "vidswap-shorter.mp4", "vidgone-deleted.mp4", "vidgone-moved.mp4", "vidbroken.mp4"].enumerated() {
            try pvdWrite(out.path(name), durations: pvdDurations)
            try mrAge(out.path(name), 20 + index)
        }
    } catch {
        out.problem = "could not make the files: \(error)"
        return out
    }
    let helper: HelperProcess
    do { helper = try atStartHelper(world) } catch {
        out.problem = "the bundled helper could not be started: \(error)"
        return out
    }
    helper.send(atFoldersLine([world.photos]))
    let settled = mrWaitSettled(world, helper, expected: 6, quiet: 1.5, stall: 240, cap: 900)
    let notDone = settled.rows.filter { $0.value.status != "done" }
    guard settled.met, notDone.isEmpty else {
        out.problem = "the 6 clips did not all reach done: \(mrDescribe(settled.rows)), stderr: \(helper.errors)"
        helper.closeStdin()
        _ = helper.waitForExit(timeout: 60)
        return out
    }
    helper.closeStdin()
    guard helper.waitForExit(timeout: 120)?.status == 0 else {
        out.problem = "the helper did not exit 0 within 120 s of its stdin ending; stderr: \(helper.errors)"
        return out
    }
    return out
}()

private struct PvdStop: Error {}

private func pvdWorldOrStop() throws -> PvdWorld {
    let outcome = pvdWorld
    if let problem = outcome.problem {
        Issue.record("setup failed: \(problem)")
        throw PvdStop()
    }
    return outcome
}

private func pvdReply(_ world: PvdWorld, file: String, passage: Int?) -> PreviewReply {
    pmReply(world.home, speech: PmSpeech(supportsOnDevice: false), file: file, passage: passage, query: "the keeper repaired the lamp")
}

extension EncodeHelperTests {
@Suite("PreviewReaderVideoTests", .serialized)
struct PreviewReaderVideoTests {

    // MARK: the frame, its numbers and the file left alone

    @Test func theFrameAtFortyTwoIsOkWithItsSecondsItsLocatorAndAFrameOfTheShotThatStartsThereNotTheShotTwentySecondsEarlier() throws {
        let world = try pvdWorldOrStop()
        let path = world.path(pvdMainName)
        let id = try #require(world.passage(pvdMainName, source: "frame", start: 42), "the index holds no frame passage at 42 of \(pvdMainName)")
        let before = try #require(pmFacts(path))
        let list = MediaRig.shots(pvdDurations)
        let shade = list[MediaRig.shotIndex(at: 42, in: list)].shade
        let earlier = list[MediaRig.shotIndex(at: 22, in: list)].shade
        #expect(shade != earlier, "setup: the shot at 42 and the shot at 22 have the same shade")

        let reply = pvdReply(world, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok, "status is \(reply.status), expected ok")
        #expect(reply.name == pvdMainName, "name is \(reply.name)")
        #expect(reply.kind == "video", "kind is \(reply.kind)")
        #expect(reply.size == Int(before.size), "size is \(String(describing: reply.size)), stat says \(before.size)")
        #expect(reply.mtime == Int(before.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)), stat says \(before.mtimeNs / 1_000_000_000)")
        #expect(reply.seconds == 42, "seconds is \(String(describing: reply.seconds)), expected the passage's second 42")
        #expect(reply.locator == "Opens at 00:42", "locator is \(String(describing: reply.locator)), expected exactly `Opens at 00:42`")
        #expect(reply.text == nil, "a frame reply carries no words: \(String(describing: reply.text))")
        #expect(reply.marks.isEmpty, "a video reply carries no text marks: \(reply.marks)")
        #expect(reply.page == nil && reply.pageCount == nil)

        let png = try #require(reply.png, "no png path in an ok video reply")
        #expect(png.hasPrefix("/"), "the png path is not absolute: \(png)")
        let decoded = try #require(pmDecode(png), "the png at \(png) cannot be read by ImageIO")
        #expect(decoded.type == "public.png", "the picture is of type \(decoded.type ?? "nil"), expected public.png")
        let found = pmDominantShade(decoded.pixels)
        #expect(found?.shade == shade, "the picture's dominant shade is \(String(describing: found?.shade)) (share \(String(describing: found?.share))), expected the shade \(shade) of the shot that starts at 42, not \(earlier)")

        let after = try #require(pmFacts(path))
        #expect(after == before, "the preview changed the file (size, mtime, inode or bytes)")
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder still holds \(pmScratchLeftovers()) besides PNG files: a staged copy was not removed")
    }

    @Test(arguments: [(0, "Opens at 00:00", 0), (12, "Opens at 00:12", 1), (24, "Opens at 00:24", 2), (33, "Opens at 00:33", 3),
                      (42, "Opens at 00:42", 4), (54, "Opens at 00:54", 5), (63, "Opens at 01:03", 6)])
    func everyFramePassageGivesItsSecondItsLocatorAndTheShadeOfItsShot(_ second: Int, _ locator: String, _ shade: Int) throws {
        let world = try pvdWorldOrStop()
        let id = try #require(world.passage(pvdMainName, source: "frame", start: second), "the index holds no frame passage at \(second)")
        let reply = pvdReply(world, file: world.path(pvdMainName), passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok)
        #expect(reply.seconds == second, "seconds is \(String(describing: reply.seconds)), expected \(second)")
        #expect(reply.locator == locator, "locator is \(String(describing: reply.locator)), expected exactly `\(locator)`")
        let png = try #require(reply.png, "no png path")
        let decoded = try #require(pmDecode(png), "the png does not decode")
        #expect(pmDominantShade(decoded.pixels)?.shade == shade, "the dominant shade is \(String(describing: pmDominantShade(decoded.pixels)?.shade)), expected \(shade)")
    }

    // MARK: the timeline

    @Test func theTimelineMarkerLiesAtTheSecondOverTheDurationWithinTwoPercentOfTheWidth() throws {
        let world = try pvdWorldOrStop()
        let path = world.path(pvdMainName)
        let first = try #require(world.passage(pvdMainName, source: "frame", start: 42))
        let second = try #require(world.passage(pvdMainName, source: "frame", start: 63))
        let a = pvdReply(world, file: path, passage: first)
        let b = pvdReply(world, file: path, passage: second)
        defer { pmDropPNG(a); pmDropPNG(b) }
        let pngA = try #require(a.png, "no png for the frame at 42")
        let pngB = try #require(b.png, "no png for the frame at 63")
        let pixelsA = try #require(pmDecode(pngA), "the png at 42 does not decode").pixels
        let pixelsB = try #require(pmDecode(pngB), "the png at 63 does not decode").pixels
        #expect(pixelsA.width == pixelsB.width && pixelsA.height == pixelsB.height,
                "the two pictures are \(pixelsA.width) x \(pixelsA.height) and \(pixelsB.width) x \(pixelsB.height): one file's frames come out one size")

        let centres = try #require(pmMarkerCentres(pixelsA, pixelsB), "the two pictures are not of one size")
        #expect(centres.count == 2, "the two pictures differ in \(centres.count) narrow places \(centres) (as a share of the width), expected exactly two: a marker at 42 and a marker at 63")
        if centres.count == 2 {
            #expect(abs(centres[0] - 42.0 / 90.0) <= 0.02, "the marker of the frame at 42 lies at \(centres[0]) of the width, expected \(42.0 / 90.0) within 0.02")
            #expect(abs(centres[1] - 63.0 / 90.0) <= 0.02, "the marker of the frame at 63 lies at \(centres[1]) of the width, expected \(63.0 / 90.0) within 0.02")
        }
    }

    // MARK: the soundtrack of a video

    @Test(arguments: [(20, "Opens at 00:20", 1), (45, "Opens at 00:45", 4), (70, "Opens at 01:10", 6)])
    func aWindowOfTheSoundtrackShowsTheFrameOfItsStartSecondWithThatSecondAsTheSpot(_ start: Int, _ locator: String, _ shade: Int) throws {
        let world = try pvdWorldOrStop()
        let id = try #require(world.passage(pvdMainName, source: "audio", start: start), "the index holds no soundtrack window passage at \(start)")
        let reply = pvdReply(world, file: world.path(pvdMainName), passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok, "status is \(reply.status)")
        #expect(reply.kind == "video", "kind is \(reply.kind): the file is a video even when the passage is its soundtrack")
        #expect(reply.seconds == start, "seconds is \(String(describing: reply.seconds)), expected the window's start \(start)")
        #expect(reply.locator == locator, "locator is \(String(describing: reply.locator)), expected exactly `\(locator)`")
        let png = try #require(reply.png, "no png path")
        let decoded = try #require(pmDecode(png), "the png does not decode")
        #expect(pmDominantShade(decoded.pixels)?.shade == shade, "the dominant shade is \(String(describing: pmDominantShade(decoded.pixels)?.shade)), expected the shade \(shade) of the shot at second \(start)")
    }

    // MARK: changed

    @Test func aFileReplacedByALongerVideoIsChangedAndShowsTheStoredSecondOfTheVideoAsItIsNow() throws {
        let world = try pvdWorldOrStop()
        let path = world.path("vidswap-longer.mp4")
        let id = try #require(world.passage("vidswap-longer.mp4", source: "frame", start: 42))
        let durations: [Double] = [12] + [Double](repeating: 10, count: 9) + [18]
        try pvdWrite(path, durations: durations, firstShade: 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 600)], ofItemAtPath: path)
        let now = try #require(pmFacts(path))
        let list = MediaRig.shots(durations, firstShade: 1)
        let shade = list[MediaRig.shotIndex(at: 42, in: list)].shade

        let reply = pvdReply(world, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.kind == "video")
        #expect(reply.size == Int(now.size), "size is \(String(describing: reply.size)), stat says \(now.size) (the current size)")
        #expect(reply.mtime == Int(now.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)) (the current time)")
        #expect(reply.seconds == 42, "seconds is \(String(describing: reply.seconds)), expected the stored 42 (still inside the 120 s video)")
        #expect(reply.locator == "Opens at 00:42", "locator is \(String(describing: reply.locator))")
        let png = try #require(reply.png, "no png path in a changed video reply")
        let decoded = try #require(pmDecode(png), "the png does not decode")
        #expect(pmDominantShade(decoded.pixels)?.shade == shade, "the dominant shade is \(String(describing: pmDominantShade(decoded.pixels)?.shade)), expected the shade \(shade) of the new video's frame at 42 (the old video's was 4)")
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder holds \(pmScratchLeftovers()) besides PNG files")
    }

    @Test func aFileReplacedByAShorterVideoIsChangedAndShowsItsFirstFrame() throws {
        let world = try pvdWorldOrStop()
        let path = world.path("vidswap-shorter.mp4")
        let id = try #require(world.passage("vidswap-shorter.mp4", source: "frame", start: 42))
        try pvdWrite(path, durations: [10, 10, 10], firstShade: 2)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 700)], ofItemAtPath: path)

        let reply = pvdReply(world, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.seconds == 0, "seconds is \(String(describing: reply.seconds)), expected 0 (the stored 42 is past the end of the 30 s video)")
        #expect(reply.locator == "Opens at 00:00", "locator is \(String(describing: reply.locator))")
        let png = try #require(reply.png, "no png path in a changed video reply")
        let decoded = try #require(pmDecode(png), "the png does not decode")
        #expect(pmDominantShade(decoded.pixels)?.shade == 2, "the dominant shade is \(String(describing: pmDominantShade(decoded.pixels)?.shade)), expected the shade 2 of the new video's first shot")
    }

    // MARK: gone

    @Test func aDeletedVideoIsGoneWithNothingToShow() throws {
        let world = try pvdWorldOrStop()
        let path = world.path("vidgone-deleted.mp4")
        let id = try #require(world.passage("vidgone-deleted.mp4", source: "frame", start: 42))
        try FileManager.default.removeItem(atPath: path)

        let reply = pvdReply(world, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .gone, "status is \(reply.status), expected gone")
        #expect(reply.name == "vidgone-deleted.mp4", "name is \(reply.name)")
        #expect(reply.png == nil, "a gone file has a png: \(String(describing: reply.png))")
        #expect(reply.size == nil && reply.mtime == nil, "a gone file has size \(String(describing: reply.size)) and mtime \(String(describing: reply.mtime))")
        #expect(reply.page == nil && reply.pageCount == nil && reply.locator == nil && reply.text == nil && reply.seconds == nil,
                "a gone file keeps a locator or a spot: \(String(describing: reply.locator)), \(String(describing: reply.seconds))")
    }

    @Test func aVideoMovedIntoACachesFolderIsGoneAtItsNewPathAndAtItsOldOne() throws {
        let world = try pvdWorldOrStop()
        let old = world.path("vidgone-moved.mp4")
        let id = try #require(world.passage("vidgone-moved.mp4", source: "frame", start: 42))
        let caches = world.folder + "/Caches"
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let moved = caches + "/vidgone-moved.mp4"
        try FileManager.default.moveItem(atPath: old, toPath: moved)
        #expect(FileManager.default.fileExists(atPath: moved), "the test's moved file is not on disk")

        for (label, file) in [("its new path inside Caches", moved), ("its old path", old)] {
            let reply = pvdReply(world, file: file, passage: id)
            defer { pmDropPNG(reply) }
            #expect(reply.status == .gone, "\(label): status is \(reply.status), expected gone")
            #expect(reply.png == nil, "\(label): a gone file has a png: \(String(describing: reply.png))")
            #expect(reply.locator == nil && reply.seconds == nil, "\(label): a gone file keeps a locator or a spot")
        }
    }

    // MARK: a video that no longer opens (G20)

    @Test func aVideoThatNoLongerOpensIsOkWithNoPngAndNoLocatorSoThePaneSaysItCannotPreviewIt() throws {
        let world = try pvdWorldOrStop()
        let path = world.path("vidbroken.mp4")
        let id = try #require(world.passage("vidbroken.mp4", source: "frame", start: 42))
        let facts = try #require(pmFacts(path))
        let handle = try #require(FileHandle(forWritingAtPath: path), "the test cannot open vidbroken.mp4 for writing")
        try handle.write(contentsOf: Data(count: Int(facts.size)))
        try handle.close()
        mrSetMtime(path, ns: facts.mtimeNs)
        let now = try #require(pmFacts(path))
        #expect(now.size == facts.size && now.inode == facts.inode && now.mtimeNs == facts.mtimeNs,
                "setup: the test's overwrite changed the file's identity (size \(now.size) vs \(facts.size), mtime \(now.mtimeNs) vs \(facts.mtimeNs))")
        #expect(MediaRig.probeSeconds(path) == nil, "setup: ffprobe still reads the overwritten file")

        let reply = pvdReply(world, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok, "status is \(reply.status), expected ok (the pane then says `Can't preview this file`)")
        #expect(reply.name == "vidbroken.mp4", "name is \(reply.name)")
        #expect(reply.png == nil, "a video that does not open has a png: \(String(describing: reply.png))")
        #expect(reply.locator == nil, "a video that does not open has a locator: \(String(describing: reply.locator))")
        #expect(reply.text == nil && reply.seconds == nil, "a video that does not open has words or a spot: \(String(describing: reply.text)), \(String(describing: reply.seconds))")
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder holds \(pmScratchLeftovers()) besides PNG files")
    }
}
}

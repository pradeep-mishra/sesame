import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import SesameEngine

// plan-5-t3, tester step. Written from the entry plan-5-t3 of plan-5-tasks.md (Tests: VideoReaderTests), the Conventions, Decisions D4, D5, D8 and
// D13 and t2's AudioReaderTests (the style and the helpers' names) only; no product source is read. The rig is MediaRig.swift (a clip is an
// mp4 the test writes with AVAssetWriter: shots drawn by the test, see the comment in MediaRigVideo.swift) and every expected value
// (a frame's second, a shot's shade, a window start, a pixel count) is written by hand from how the clip was built, never from the reader.
// The independent readers are `ffprobe` and `ffmpeg` (the rig check in MediaRigVideoTests, and the setup checks here) and ImageIO (the photo path's area).
//
// Names, and how they were found:
//   - `VideoReader.read(path:expecting:fromSecond:scratch:shouldStop:) throws -> VideoStep`, `VideoStep.duration`, `.frames` (`VideoFrame.second`,
//     `.bitmap`), `.windows` (`AudioWindow`), `.readTo`, `.finished`, `.nameWords`, `VideoReader.frame(path:expecting:second:maxSide:scratch:shouldStop:)
//     throws -> VideoStill` (`.image`, `.duration`), `VideoReadError` (`.unreadable`, `.changed`, `.notAdmitted`, `.cannotOpen`), `VideoReader.frameSeconds`
//     3, `.stepSeconds` 180, `.shotBits`: the names the entry fixes. None exists yet. `MediaStopped` and `AudioWindow` are t2's.
//   - `FileIdentity`, `Scratch()` and `Rules.admit(path:)`: as AudioReaderTests.
//   - `PhotoBitmap` with `width`, `height` and `rgb` (the sealed PdfScanTests); `PhotoReader.read(path:expecting:wantBitmap:)` (the sealed PhotoDamageTests).
//
// SHAPES THIS FILE PINS (the entry names the fields, not their types; each is one place to edit, the helpers below):
//   1. `expecting` is a `FileIdentity`, `scratch` a `Scratch`, `shouldStop` a `() -> Bool`, `fromSecond` and `second` whole seconds (`Int`),
//      `maxSide` an `Int`. `VideoFrame.second` is whole seconds (the test reads it with `Int(...)`); `VideoStep.duration` is a number (read with
//      `Double(...)`), `readTo` an `Int` in seconds, `finished` a `Bool`.
//   2. Frames are sampled every `frameSeconds` seconds ANCHORED AT `fromSecond` (a step that starts at 180 samples 180, 183, ...); a frame is kept
//      when the first frame of the call or its 8 x 8 hash differs from the last KEPT frame's by more than `shotBits` bits; the chain restarts at
//      each call (D13: "the hash chain restarting at each 180 s step"). A call covers [fromSecond, fromSecond + 180).
//   3. `readTo` is `fromSecond + 180` for a step that does not reach the end of the clip and is asserted only there; `finished` is true when the
//      step reaches the end.
//   4. A shot is told from the next by a pattern of cells, not by a plain colour (see the rig): the entry's "a clip that changes colour every 3 s
//      keeps 10" cannot hold for a flat picture under any 8 x 8 hash, so every shot here is a different pattern in a different shade.
//   5. The soundtrack windows of a video are AudioReader's for the same samples: the same lattice, the same onset rule, so a tone that starts
//      at 20 s after silence gives a window that starts at 20 (within 1 s: the AAC encoder moves an onset by milliseconds) and ends at the clip's end.
//   6. Scratch staging is observed as in AudioReaderTests: one copy of the file's size in `$TMPDIR/Sesame-<pid>` while a call runs, none after.

private func scratchEntries() -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: scratchFolderPath())) ?? [])
}

private func scratchFolderPath() -> String {
    (NSTemporaryDirectory() as NSString).appendingPathComponent("Sesame-\(getpid())")
}

private final class StopClock: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Date] = []
    func tick() { lock.lock(); times.append(Date()); lock.unlock() }
    var all: [Date] { lock.lock(); defer { lock.unlock() }; return times }
}

private final class StopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

private func stopAfter(_ n: Int) -> () -> Bool {
    let counter = StopCounter()
    return { counter.bump() >= n }
}

private final class ScratchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    let folder: String
    let size: Int
    init(folder: String, size: Int) { self.folder = folder; self.size = size }
    func look(ignoring before: Set<String>) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !before.contains($0) }
        let sizes = names.compactMap { name -> String? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder + "/" + name)
            return (attributes?[.size] as? Int) == size ? name : nil
        }
        lock.lock(); seen.append(sizes); lock.unlock()
    }
    var copies: [[String]] { lock.lock(); defer { lock.unlock() }; return seen }
}

private func probing(_ probe: ScratchProbe, ignoring before: Set<String>) -> () -> Bool {
    { probe.look(ignoring: before); return false }
}

private func ticking(_ clock: StopClock) -> () -> Bool {
    { clock.tick(); return false }
}

private struct Outcome {
    let step: VideoStep?
    let error: String?
}

private func attempt(_ path: String, expecting: MrSeen? = nil, from: Int = 0, stop: @escaping () -> Bool = { false }) -> Outcome {
    let known = expecting ?? mrSeen(path) ?? MrSeen(size: 0, mtimeNs: 0, inode: 0)
    do {
        return Outcome(step: try VideoReader.read(path: path, expecting: mrIdentity(known), fromSecond: from, scratch: Scratch(), shouldStop: stop), error: nil)
    } catch is MediaStopped {
        return Outcome(step: nil, error: "stopped")
    } catch let error as VideoReadError {
        return Outcome(step: nil, error: String(describing: error))
    } catch {
        return Outcome(step: nil, error: "other: \(error)")
    }
}

private func describe(_ outcome: Outcome) -> String {
    if let error = outcome.error { return "threw \(error)" }
    guard let step = outcome.step else { return "no step and no error" }
    return "read \(step.frames.count) frame(s) and \(step.windows.count) window(s) of a \(step.duration) s clip"
}

private func seconds(_ step: VideoStep) -> [Int] { step.frames.map { Int($0.second) } }

private func starts(_ step: VideoStep) -> [Int] { step.windows.map(\.start) }

private func shadeOf(_ frame: VideoFrame) -> Int { MediaRig.nearestShade(MediaRig.meanColor(rgb: Array(frame.bitmap.rgb))) }

/// The seconds a 3 s sampling keeps on a clip of shots every `each` seconds (one frame per shot, the first sample inside it): the sample is the
/// first multiple of 3 at or after the shot's start, for the shots that start inside [from, to).
private func keptSeconds(shotsEvery each: Int, count: Int, from: Int, to: Int) -> [Int] {
    var kept: [Int] = []
    for shot in 0..<count {
        let sample = Int((Double(shot * each) / 3.0).rounded(.up)) * 3
        if sample >= from && sample < to && sample < count * each { kept.append(sample) }
    }
    return kept
}

private func tone(_ at: Double, _ length: Double) -> [MediaRig.Part] { [.silence(at), .tone(length, db: -20, hz: 440)] }

@Suite("VideoReaderTests", .serialized)
struct VideoReaderTests {

    // MARK: the numbers

    @Test func theFrameIsThreeSecondsTheStepOneHundredEightySecondsAndShotBitsIsASmallWholeNumber() {
        #expect(VideoReader.frameSeconds == 3, "frameSeconds is \(VideoReader.frameSeconds)")
        #expect(VideoReader.stepSeconds == 180, "stepSeconds is \(VideoReader.stepSeconds)")
        #expect((1...12).contains(VideoReader.shotBits), "shotBits is \(VideoReader.shotBits): a shot is told from the last kept one by more than a few bits of the 64 (D13 guesses 6)")
    }

    // MARK: one frame per shot (the rig itself is checked against ffprobe and ffmpeg in MediaRigVideoTests)

    @Test func aThirtySecondClipOfOneShotKeepsOneFrameAtSecondZeroAndNoWindow() throws {
        try mrWithDir { dir in
            let path = dir.file("oneshot.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([30]))
            let outcome = attempt(path)
            let step = try #require(outcome.step, "the clip should read, it \(describe(outcome))")
            #expect(seconds(step) == [0], "the kept frames are at seconds \(seconds(step)), expected only [0]: a clip of one shot keeps one frame")
            #expect(step.windows.isEmpty, "a clip with no audio track gave \(starts(step)) windows")
            #expect(step.finished, "a 30 s clip is read to its end in one step")
            #expect(abs(Double(step.duration) - 30) < 1, "duration is \(step.duration), expected 30")
            if let frame = step.frames.first {
                #expect(frame.bitmap.rgb.count == frame.bitmap.width * frame.bitmap.height * 3, "the bitmap holds \(frame.bitmap.rgb.count) bytes for \(frame.bitmap.width) x \(frame.bitmap.height), expected width x height x 3")
                #expect(frame.bitmap.width > 0 && frame.bitmap.height > 0)
                #expect(shadeOf(frame) == 0, "the frame's shade is \(shadeOf(frame)), the shot was drawn in shade 0")
            }
            #expect(String(describing: step.nameWords).lowercased().contains("oneshot"), "nameWords \(step.nameWords) does not hold the file name word")
        }
    }

    @Test func aClipThatChangesShotEveryThreeSecondsKeepsTenFramesAtSecondsZeroToTwentySevenEachShowingItsOwnShot() throws {
        try mrWithDir { dir in
            let path = dir.file("tenshots.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots(Array(repeating: 3, count: 10)))
            let step = try #require(attempt(path).step, "the clip should read")
            #expect(seconds(step) == Array(stride(from: 0, through: 27, by: 3)), "the kept frames are at seconds \(seconds(step)), expected every 3 s from 0 to 27 (10 frames)")
            for frame in step.frames {
                let shot = Int(frame.second) / 3
                #expect(shadeOf(frame) == shot % 8, "the frame at \(frame.second) s has shade \(shadeOf(frame)), shot \(shot) was drawn in shade \(shot % 8)")
            }
            #expect(step.finished)
        }
    }

    @Test func aShotThatStartsAtSecond42GivesItsFrameTheSecond42AndNeverTheFrameOfSecond41() throws {
        try mrWithDir { dir in
            let durations: [Double] = [12, 10, 10, 10, 10, 10, 10, 10]   // shots start at 0, 12, 22, 32, 42, 52, 62, 72; the clip is 82 s
            let list = MediaRig.shots(durations)
            let path = dir.file("shotsat42.mp4")
            try MediaRig.writeVideo(path, shots: list)
            let step = try #require(attempt(path).step, "the clip should read")
            // the first sample (a multiple of 3) inside each shot: 0, 12, 24, 33, 42, 54, 63, 72
            #expect(seconds(step) == [0, 12, 24, 33, 42, 54, 63, 72], "the kept frames are at seconds \(seconds(step)), expected [0, 12, 24, 33, 42, 54, 63, 72] (the first sample inside each of the 8 shots)")
            for frame in step.frames {
                let index = MediaRig.shotIndex(at: Double(frame.second), in: list)
                #expect(shadeOf(frame) == list[index].shade, "the frame at \(frame.second) s has shade \(shadeOf(frame)); at that second the clip shows shot \(index), shade \(list[index].shade)")
            }
            if let at42 = step.frames.first(where: { Int($0.second) == 42 }) {
                #expect(shadeOf(at42) == 4, "the frame at 42 s shows shade \(shadeOf(at42)), the shot that starts at 42 is shade 4 (the shot before it, which a frame taken at 41 shows, is shade 3)")
            }
        }
    }

    @Test func aShotWhosePictureDiffersByAFewCellsIsTheSameShotAndOneThatDiffersByManyIsANewOne() throws {
        try mrWithDir { dir in
            // shot 0 (0 to 3 s); shot 1 is shot 0 with 2 cells toggled (3 to 6 s); shot 2 is shot 0 with 20 other cells toggled (6 to 9 s)
            let base = MediaRig.VideoShot(seconds: 3, shade: 2, row: 9)
            let near = MediaRig.VideoShot(seconds: 3, shade: 2, row: 9, flips: [5, 40])
            let far = MediaRig.VideoShot(seconds: 3, shade: 2, row: 9, flips: Array(10..<30))
            let path = dir.file("flips.mp4")
            try MediaRig.writeVideo(path, shots: [base, near, far])
            let step = try #require(attempt(path).step, "the clip should read")
            #expect(seconds(step) == [0, 6], "the kept frames are at seconds \(seconds(step)), expected [0, 6]: 2 toggled cells are the same shot (at most \(VideoReader.shotBits) bits), 20 toggled cells are a new one")
        }
    }

    // MARK: the soundtrack

    @Test func aToneFromTwentySecondsAfterSilenceGivesTheWindowAudioReaderGivesAndFramesBesideIt() throws {
        try mrWithDir { dir in
            let wav = dir.file("sound.wav")
            try MediaRig.writeWav(wav, rate: 44100, tone(20, 6) + [.silence(14)])
            let path = dir.file("withsound.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([40]), soundtrack: wav)
            let streams = try #require(MediaRig.probeStreams(path), "ffprobe cannot list the streams")
            #expect(streams.video == 1 && streams.audio == 1, "setup: the clip has \(streams.video) video and \(streams.audio) audio streams, expected 1 and 1")

            let step = try #require(attempt(path).step, "the clip should read")
            #expect(step.windows.count == 1 && abs((step.windows.first?.start ?? -99) - 20) <= 1,
                    "the window starts are \(starts(step)), expected one window that starts at 20 (the tone starts there after 20 s of silence)")
            #expect(abs((step.windows.first?.end ?? -99) - 40) <= 1, "the window ends at \(step.windows.first?.end ?? -1), expected the clip's end 40")
            if let window = step.windows.first {
                #expect(abs(window.samples.count - (window.end - window.start) * 16_000) <= 1_600, "the window holds \(window.samples.count) samples for \(window.end - window.start) s, expected 16,000 a second within 0.1 s")
                #expect(MediaRig.rms(Array(window.samples.dropFirst(16_000 * 3).prefix(16_000 * 2))) > 0.05, "the window's samples hold no tone where the clip has one")
            }
            #expect(seconds(step) == [0], "the frames are at seconds \(seconds(step)), expected [0] (one shot)")
            #expect(step.finished)

            // the same sound read from its WAV by AudioReader: the same window start, the lattice and the onset rule are one rule
            let known = try #require(mrSeen(wav))
            let reference = try AudioReader.read(path: wav, expecting: mrIdentity(known), fromSecond: 0, scratch: Scratch(), shouldStop: { false })
            #expect(reference.windows.map(\.start) == [20], "setup: AudioReader reads the wav's windows as \(reference.windows.map(\.start)), expected [20]")
            #expect(step.windows.map(\.start).map { $0 - 20 }.allSatisfy { abs($0) <= 1 }, "the video's window starts \(starts(step)) are not AudioReader's [20] within 1 s")
        }
    }

    @Test func aClipWithNoAudioTrackAndOneWithASilentTrackGiveFramesAndNoWindowAndNoError() throws {
        try mrWithDir { dir in
            let none = dir.file("notrack.mp4")
            try MediaRig.writeVideo(none, shots: MediaRig.shots([6, 6]))
            let silentWav = dir.file("silent.wav")
            try MediaRig.writeWav(silentWav, rate: 44100, [.silence(12)])
            let silent = dir.file("silenttrack.mp4")
            try MediaRig.writeVideo(silent, shots: MediaRig.shots([6, 6]), soundtrack: silentWav)
            #expect(MediaRig.probeStreams(none)?.audio == 0, "setup: the first clip should have no audio stream")
            #expect(MediaRig.probeStreams(silent)?.audio == 1, "setup: the second clip should have one audio stream")
            for path in [none, silent] {
                let name = (path as NSString).lastPathComponent
                let outcome = attempt(path)
                #expect(outcome.error == nil && outcome.step != nil, "\(name) should read, it \(describe(outcome))")
                #expect(outcome.step.map(seconds) == [0, 6], "\(name): the kept frames are at seconds \(outcome.step.map(seconds) ?? []), expected [0, 6]")
                #expect(outcome.step?.windows.isEmpty == true, "\(name): a clip with no sound gave windows \(outcome.step.map(starts) ?? [])")
                #expect(outcome.step?.finished == true)
            }
        }
    }

    // MARK: steps of at most 180 seconds

    @Test func oneCallCoversAtMostOneHundredEightySecondsAndAFourHundredSecondClipReadsAsThreeStepsByFromSecond() throws {
        try mrWithDir { dir in
            let path = dir.file("fourhundred.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots(Array(repeating: 10, count: 40)))   // 40 shots of 10 s
            let first = try #require(attempt(path, from: 0).step, "step one should read")
            #expect(first.readTo == 180 && !first.finished, "step one: readTo \(first.readTo), finished \(first.finished), expected 180 and not finished")
            #expect(seconds(first) == keptSeconds(shotsEvery: 10, count: 40, from: 0, to: 180), "step one's frames are at \(seconds(first)), expected \(keptSeconds(shotsEvery: 10, count: 40, from: 0, to: 180))")
            #expect(abs(Double(first.duration) - 400) < 1, "duration is \(first.duration), expected 400")
            let second = try #require(attempt(path, from: 180).step, "step two should read")
            #expect(second.readTo == 360 && !second.finished, "step two: readTo \(second.readTo), finished \(second.finished), expected 360 and not finished")
            #expect(seconds(second) == keptSeconds(shotsEvery: 10, count: 40, from: 180, to: 360), "step two's frames are at \(seconds(second)), expected \(keptSeconds(shotsEvery: 10, count: 40, from: 180, to: 360))")
            let third = try #require(attempt(path, from: 360).step, "step three should read")
            #expect(third.finished, "step three reaches the clip's end")
            #expect(seconds(third) == keptSeconds(shotsEvery: 10, count: 40, from: 360, to: 400), "step three's frames are at \(seconds(third)), expected \(keptSeconds(shotsEvery: 10, count: 40, from: 360, to: 400))")
            for step in [first, second, third] {
                for frame in step.frames { #expect(shadeOf(frame) == (Int(frame.second) / 10) % 8, "the frame at \(frame.second) s has shade \(shadeOf(frame))") }
            }
        }
    }

    @Test func theHashChainRestartsAtEachStepSoAOneShotClipKeepsTheFirstFrameOfEveryStep() throws {
        try mrWithDir { dir in
            let path = dir.file("oneshotlong.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([400]))
            for (from, want) in [(0, [0]), (180, [180]), (360, [360])] {
                let outcome = attempt(path, from: from)
                #expect(outcome.step.map(seconds) == want, "from \(from): the kept frames are at \(outcome.step.map(seconds) ?? []), expected \(want): every call keeps its first frame and drops the repeats")
            }
        }
    }

    @Test func readingLeavesTheFileAsItWasAndTwoReadsAgree() throws {
        try mrWithDir { dir in
            let path = dir.file("steady.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([6, 6, 6]))
            let before = try #require(mrSeen(path))
            let first = try #require(attempt(path).step)
            let second = try #require(attempt(path).step)
            #expect(mrSeen(path) == before, "reading changed the file's size, modified time or inode")
            #expect(seconds(first) == seconds(second) && zip(first.frames, second.frames).allSatisfy { $0.bitmap.rgb == $1.bitmap.rgb }, "two reads of one file differ")
        }
    }

    // MARK: the 70-token bitmap

    // The picture the model sees for a video frame is smaller than a photo's: 70 soft tokens against 140. The expected value is the photo path's
    // own area for the same picture (a 1,920 x 1,080 JPEG read through `PhotoReader`), halved: within 10 percent [guess: the area is proportional
    // to the token budget].
    @Test func aFullHdFrameIsAboutHalfTheAreaOfThePhotoPathsBitmapForTheSamePicture() throws {
        try mrWithDir { dir in
            let video = dir.file("fullhd.mp4")
            try MediaRig.writeVideo(video, width: 1920, height: 1080, fps: 2, shots: MediaRig.shots([3]))
            let step = try #require(attempt(video).step, "the 1,920 x 1,080 clip should read")
            let frame = try #require(step.frames.first, "no frame")
            #expect(frame.bitmap.rgb.count == frame.bitmap.width * frame.bitmap.height * 3, "the bitmap holds \(frame.bitmap.rgb.count) bytes for \(frame.bitmap.width) x \(frame.bitmap.height)")
            let videoArea = frame.bitmap.width * frame.bitmap.height

            let jpeg = dir.file("fullhd.jpg")
            try writeFullHdJpeg(jpeg)
            let known = try #require(mrSeen(jpeg))
            let read = try PhotoReader.read(path: jpeg, expecting: mrIdentity(known), wantBitmap: true)
            let photo = try #require(bitmap(in: read), "setup: PhotoReader returned no bitmap for the 1,920 x 1,080 photo")
            let photoArea = photo.width * photo.height
            print("READING video bitmap \(frame.bitmap.width)x\(frame.bitmap.height) = \(videoArea) pixels, photo bitmap \(photo.width)x\(photo.height) = \(photoArea) pixels")
            #expect(photoArea > 0 && abs(Double(videoArea) - Double(photoArea) / 2) <= 0.10 * Double(photoArea) / 2,
                    "the video frame's bitmap holds \(videoArea) pixels, half of the photo path's \(photoArea) is \(photoArea / 2): expected within 10 percent (70 tokens against 140)")
            let aspect = Double(frame.bitmap.width) / Double(frame.bitmap.height)
            #expect(abs(aspect - 16.0 / 9.0) < 0.1, "the bitmap's shape is \(frame.bitmap.width) x \(frame.bitmap.height) (\(aspect)), the frame is 16:9")
        }
    }

    // MARK: stopping

    @Test func shouldStopReturningTrueThrowsMediaStoppedAndReturnsNoFrameAndItIsCalledBetweenFramesAndDecodeSteps() throws {
        try mrWithDir { dir in
            let path = dir.file("stoppable.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots(Array(repeating: 3, count: 80)))   // 240 s, a frame kept every 3 s
            #expect(attempt(path, stop: { true }).error == "stopped", "a shouldStop that is true from the start should throw MediaStopped")

            let clock = StopClock()
            let step = try #require(attempt(path, stop: ticking(clock)).step, "the clip should read")
            #expect(step.frames.count == 60 && step.readTo == 180, "step one holds \(step.frames.count) frames and readTo \(step.readTo), expected 60 and 180")
            let times = clock.all
            #expect(times.count >= 60, "shouldStop was called \(times.count) time(s) over a step of 60 frames, expected at least one between frames")
            let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
            let longest = gaps.max() ?? 0
            print("READING video shouldStop calls=\(times.count) longest gap=\(String(format: "%.2f", longest)) s (a step of 60 frames)")
            #expect(longest < 2.0, "the longest time between two stop checks is \(longest) s, expected well under 2 s (a frame decode)")

            let stopped = attempt(path, stop: stopAfter(5))
            #expect(stopped.error == "stopped" && stopped.step == nil, "a stop at the fifth check should throw MediaStopped and return no step, it \(describe(stopped))")
        }
    }

    // MARK: files that cannot be read

    @Test func randomBytesUnderMp4ACutMp4AndAZeroByteMovThrowUnreadable() throws {
        try mrWithDir { dir in
            let whole = dir.file("whole.mp4")
            try MediaRig.writeVideo(whole, shots: MediaRig.shots([6, 6, 6, 6]))
            let control = attempt(whole)
            #expect(control.step != nil, "control: the uncut mp4 should read, it \(describe(control))")

            let cut = dir.file("cut.mp4")
            try MediaRig.cutCopy(of: whole, to: cut, fraction: 0.4)
            var generator = SystemRandomNumberGenerator()
            func noise(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
            let cases: [(name: String, data: Data?)] = [("noise.mp4", noise(6000)), ("noise.m4v", noise(6000)), ("cut.mp4", nil), ("empty.mov", Data())]
            for item in cases {
                let path = dir.file(item.name)
                if let data = item.data { try data.write(to: URL(fileURLWithPath: path)) }
                #expect(MediaRig.probeSeconds(path) == nil, "setup: ffprobe still reads \(item.name)")
                let outcome = attempt(path)
                #expect(outcome.error == "unreadable", "\(item.name) should throw unreadable, it \(describe(outcome))")
            }
        }
    }

    @Test func aChangedSizeOrMtimeOrInodeThrowsChangedAndTheUnchangedFileStillReads() throws {
        try mrWithDir { dir in
            let path = dir.file("shifting.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([6]))
            let before = try #require(mrSeen(path))
            #expect(attempt(path, expecting: before).step != nil, "control: with the identity it has, the file reads")

            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0, count: 64))
            try handle.close()
            mrSetMtime(path, ns: before.mtimeNs)
            let grown = try #require(mrSeen(path))
            #expect(grown.size != before.size && grown.mtimeNs == before.mtimeNs && grown.inode == before.inode, "setup: the size-only change did not isolate the size: \(before) then \(grown)")
            #expect(attempt(path, expecting: before).error == "changed", "a different size should throw changed")

            mrSetMtime(path, ns: before.mtimeNs + 5_000_000_000)
            let later = try #require(mrSeen(path))
            #expect(later.size == grown.size && later.mtimeNs != grown.mtimeNs && later.inode == grown.inode, "setup: the time-only change did not isolate the time")
            #expect(attempt(path, expecting: grown).error == "changed", "a different modified time should throw changed")

            let copy = dir.file("copy-of-shifting.tmp")
            try FileManager.default.copyItem(atPath: path, toPath: copy)
            mrSetMtime(copy, ns: later.mtimeNs)
            #expect(rename(copy, path) == 0, "setup: could not rename the copy over the file")
            let replaced = try #require(mrSeen(path))
            #expect(replaced.size == later.size && replaced.mtimeNs == later.mtimeNs && replaced.inode != later.inode, "setup: the inode-only change did not isolate the inode: \(later) then \(replaced)")
            #expect(attempt(path, expecting: later).error == "changed", "a different inode should throw changed")
            #expect(attempt(path, expecting: replaced).step != nil, "control: with its new identity the file reads")
        }
    }

    @Test func aGoneFileAKeyNameALinkAndAFolderAreNotAdmittedWhateverIdentityIsGiven() throws {
        try mrWithDir { dir in
            let real = dir.file("realclip.mp4")
            try MediaRig.writeVideo(real, shots: MediaRig.shots([6]))
            #expect(attempt(real).step != nil, "control: the plain clip reads")

            #expect(attempt(dir.file("vanished.mp4"), expecting: MrSeen(size: 5, mtimeNs: 5, inode: 5)).error == "notAdmitted", "a path with nothing at it should throw notAdmitted")

            let key = dir.file("id_rsa.mp4")
            try FileManager.default.copyItem(atPath: real, toPath: key)
            #expect(Rules.admit(path: key) == nil, "setup: the rules should refuse a key name")
            #expect(Rules.admit(path: real) != nil, "setup: the rules should admit the plain name")
            #expect(attempt(key).error == "notAdmitted", "a key-name file should throw notAdmitted")

            let link = dir.file("linkedclip.mp4")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            #expect(Rules.admit(path: link) == nil, "setup: the rules should refuse a link")
            #expect(attempt(link).error == "notAdmitted", "a symbolic link should throw notAdmitted")

            let folder = dir.file("foldernamed.mp4")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #expect(attempt(folder).error == "notAdmitted", "a folder named like a clip should throw notAdmitted")
        }
    }

    @Test func aFileTheProcessMayNotOpenThrowsCannotOpen() throws {
        try mrWithDir { dir in
            guard mrCanTestPermissions() else { return }
            let path = dir.file("closedclip.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([6]))
            #expect(attempt(path).step != nil, "control: the file reads while it is open to the process")
            #expect(chmod(path, 0) == 0, "setup: could not remove the file's permissions")
            let outcome = attempt(path)
            #expect(outcome.error == "cannotOpen", "a file with mode 000 should throw cannotOpen, it \(describe(outcome))")
        }
    }

    // MARK: the staged copy (D4)

    @Test func theBytesAreStagedAsOneCopyInTheScratchFolderWhileACallRunsAndNoCopyIsLeftAfterAnyCall() throws {
        try mrWithDir { dir in
            let path = dir.file("staged.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots(Array(repeating: 3, count: 10)))
            let size = Int(try #require(mrSeen(path)).size)
            let before = scratchEntries()

            let probe = ScratchProbe(folder: scratchFolderPath(), size: size)
            let outcome = attempt(path, stop: probing(probe, ignoring: before))
            #expect(outcome.step != nil, "the clip should read, it \(describe(outcome))")
            #expect(probe.copies.contains { $0.count == 1 }, "during the call no single copy of the \(size) byte file stood in \(scratchFolderPath()); the checks saw \(probe.copies)")
            #expect(probe.copies.allSatisfy { $0.count <= 1 }, "more than one copy stood in the scratch folder at once: \(probe.copies)")
            #expect(scratchEntries().subtracting(before).isEmpty, "after the call the scratch folder holds \(scratchEntries().subtracting(before))")

            let bad = dir.file("bad.mp4")
            try Data(repeating: 9, count: 5000).write(to: URL(fileURLWithPath: bad))
            #expect(attempt(bad).error == "unreadable")
            #expect(scratchEntries().subtracting(before).isEmpty, "after an unreadable file the scratch folder holds \(scratchEntries().subtracting(before))")
            #expect(attempt(path, stop: { true }).error == "stopped")
            #expect(scratchEntries().subtracting(before).isEmpty, "after a stop the scratch folder holds \(scratchEntries().subtracting(before))")
        }
    }

    // MARK: the single frame for the pane

    private func frameAttempt(_ path: String, second: Int, maxSide: Int = 400, expecting: MrSeen? = nil, stop: @escaping () -> Bool = { false }) -> (still: VideoStill?, error: String?) {
        let known = expecting ?? mrSeen(path) ?? MrSeen(size: 0, mtimeNs: 0, inode: 0)
        do {
            return (try VideoReader.frame(path: path, expecting: mrIdentity(known), second: second, maxSide: maxSide, scratch: Scratch(), shouldStop: stop), nil)
        } catch is MediaStopped {
            return (nil, "stopped")
        } catch let error as VideoReadError {
            return (nil, String(describing: error))
        } catch {
            return (nil, "other: \(error)")
        }
    }

    private func shade(of still: VideoStill?) -> Int? {
        guard let image = still?.image, let mean = MediaRig.meanColor(of: image) else { return nil }
        return MediaRig.nearestShade(mean)
    }

    @Test func theFrameAtSecond42ShowsTheShotThatStartsThereAndNotTheShotTwentySecondsEarlierNorTheFrameOfSecond41() throws {
        try mrWithDir { dir in
            let list = MediaRig.shots([12, 10, 10, 10, 10, 10, 10, 10])   // shots start at 0, 12, 22, 32, 42, 52, 62, 72; the clip is 82 s
            let path = dir.file("panefames.mp4")
            try MediaRig.writeVideo(path, shots: list)
            let at42 = frameAttempt(path, second: 42)
            #expect(at42.error == nil && at42.still != nil, "the frame at 42 should read, it threw \(at42.error ?? "nothing")")
            #expect(shade(of: at42.still) == list[4].shade, "the frame at 42 s has shade \(shade(of: at42.still).map(String.init) ?? "none"), the shot that starts at 42 is shade \(list[4].shade)")
            #expect(shade(of: at42.still) != list[MediaRig.shotIndex(at: 22, in: list)].shade, "the frame at 42 shows the shot 20 s earlier")
            #expect(shade(of: frameAttempt(path, second: 41).still) == list[3].shade, "the frame at 41 s should be shot 3 (shade \(list[3].shade)): zero tolerance before means the frame at 42 is not the frame at 41")
            #expect(shade(of: frameAttempt(path, second: 22).still) == list[2].shade, "the frame at 22 s should be shot 2 (shade \(list[2].shade))")
            #expect(abs(Double(at42.still?.duration ?? 0) - 82) < 1, "duration is \(at42.still?.duration ?? -1), expected 82")
        }
    }

    @Test func theFramesLongestSideIsAtMostMaxSideAndASecondAtOrPastTheDurationClampsToTheLastFrame() throws {
        try mrWithDir { dir in
            let list = MediaRig.shots([12, 10, 10, 10, 10, 10, 10, 10])
            let path = dir.file("panesize.mp4")
            try MediaRig.writeVideo(path, shots: list)
            let small = try #require(frameAttempt(path, second: 5, maxSide: 200).still, "a frame with maxSide 200 should read")
            #expect(max(small.image.width, small.image.height) <= 200 && max(small.image.width, small.image.height) > 100,
                    "the frame is \(small.image.width) x \(small.image.height), expected a longest side of at most 200 (and not a thumbnail of nothing)")
            #expect(abs(Double(small.image.width) / Double(small.image.height) - 320.0 / 192.0) < 0.1, "the frame's shape \(small.image.width) x \(small.image.height) is not the clip's 320 x 192")
            let large = try #require(frameAttempt(path, second: 5, maxSide: 1000).still, "a frame with maxSide 1000 should read")
            #expect(max(large.image.width, large.image.height) <= 1000, "the frame is \(large.image.width) x \(large.image.height), expected a longest side of at most 1000")
            for second in [82, 83, 500] {
                let past = frameAttempt(path, second: second)
                #expect(past.error == nil && shade(of: past.still) == list[7].shade, "the frame at \(second) s (the clip is 82 s) should be the last shot's, shade \(list[7].shade); got \(past.error ?? "shade \(shade(of: past.still).map(String.init) ?? "none")")")
            }
        }
    }

    @Test func theSingleFrameKeepsTheIdentityErrorsUnreadableMediaStoppedAndLeavesNoCopyInTheScratchFolder() throws {
        try mrWithDir { dir in
            let before = scratchEntries()
            let path = dir.file("framed.mp4")
            try MediaRig.writeVideo(path, shots: MediaRig.shots([6, 6]))
            let known = try #require(mrSeen(path))
            #expect(frameAttempt(path, second: 3, expecting: MrSeen(size: known.size + 1, mtimeNs: known.mtimeNs, inode: known.inode)).error == "changed", "a different size should throw changed")
            #expect(frameAttempt(path, second: 3, expecting: MrSeen(size: known.size, mtimeNs: known.mtimeNs + 1, inode: known.inode)).error == "changed", "a different modified time should throw changed")
            #expect(frameAttempt(path, second: 3, expecting: MrSeen(size: known.size, mtimeNs: known.mtimeNs, inode: known.inode + 1)).error == "changed", "a different inode should throw changed")
            #expect(frameAttempt(dir.file("vanished.mp4"), second: 0, expecting: MrSeen(size: 5, mtimeNs: 5, inode: 5)).error == "notAdmitted", "a gone path should throw notAdmitted")
            let noise = dir.file("noise.mp4")
            try Data(repeating: 9, count: 5000).write(to: URL(fileURLWithPath: noise))
            #expect(frameAttempt(noise, second: 0).error == "unreadable", "random bytes should throw unreadable")
            let cut = dir.file("cut.mp4")
            try MediaRig.cutCopy(of: path, to: cut, fraction: 0.4)
            #expect(frameAttempt(cut, second: 0).error == "unreadable", "a cut mp4 should throw unreadable")
            #expect(frameAttempt(path, second: 3, stop: { true }).error == "stopped", "a shouldStop that is true should throw MediaStopped")
            if mrCanTestPermissions() {
                let closed = dir.file("closed.mp4")
                try MediaRig.writeVideo(closed, shots: MediaRig.shots([3]))
                chmod(closed, 0)
                #expect(frameAttempt(closed, second: 0).error == "cannotOpen", "a file with mode 000 should throw cannotOpen")
            }
            #expect(frameAttempt(path, second: 3).still != nil, "control: the frame reads with its own identity")
            #expect(scratchEntries().subtracting(before).isEmpty, "after the calls the scratch folder holds \(scratchEntries().subtracting(before))")
        }
    }
}

// MARK: helpers for the 70-token test

private func writeFullHdJpeg(_ path: String) throws {
    let width = 1920, height = 1080
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            bytes[i] = UInt8(x * 255 / (width - 1))
            bytes[i + 1] = UInt8(y * 255 / (height - 1))
            bytes[i + 2] = UInt8((x / 40 + y / 40) % 2 == 0 ? 60 : 200)
            bytes[i + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw MrError("cannot draw the 1,920 x 1,080 picture")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MrError("cannot write the 1,920 x 1,080 JPEG") }
}

/// The `PhotoBitmap` a `PhotoReader.read` result carries. The entry fixes the call, not the result's field names, so the field is found by its
/// type: the first child of the result (an optional or not) that is a `PhotoBitmap` (SHAPE: one place to edit).
private func bitmap(in result: Any) -> PhotoBitmap? {
    for child in Mirror(reflecting: result).children {
        if let found = child.value as? PhotoBitmap { return found }
    }
    return nil
}

import Foundation
import Testing
import SesameEngine

// plan-5-t2, tester step. Written from the entry plan-5-t2 of plan-5-tasks.md (Tests: AudioReaderTests), Decisions D3 to D5 and D13,
// the Conventions of plan-5-tasks.md and the spec's S4 only; no product source is read. The rig is MediaRig.swift: every clip is made by
// this file under $TMPDIR (a WAV written byte by byte, an m4a or aac made by the system's `afconvert`) and removed again; every expected
// value (a window start, a sample count, a level) is written by hand from how the clip was built, never from the reader.
//
// Names, and how they were found:
//   - `AudioReader.read(path:expecting:fromSecond:scratch:shouldStop:) throws -> AudioStep`, `AudioStep.duration`, `.windows`
//     (`AudioWindow.start`, `.end`, `.samples`), `.readTo`, `.finished`, `.nameWords`, `AudioReader.window(path:expecting:start:scratch:shouldStop:)
//     throws -> AudioWindow?`, `AudioReadError` (`.unreadable`, `.changed`, `.notAdmitted`, `.cannotOpen`), `MediaStopped`,
//     `AudioReader.windowSeconds` 30, `.strideSeconds` 25, `.stepSeconds` 500, `.silenceRMS`: the names the entry fixes. None exists yet.
//   - `FileIdentity(size:mtimeNs:inode:)` (the `expecting` argument, as PdfReader's) and `Rules.admit(path:)`: the sealed PdfReaderTests.
//   - `Scratch()` with no argument: what the compiler accepted for `PreviewReader(scratch:)` (the sealed PreviewReaderPdfTests).
//
// SHAPES THIS FILE PINS (the entry names the fields, not their types; each is one place to edit, the helpers below):
//   1. `read(path:expecting:fromSecond:scratch:shouldStop:)`: `expecting` is a `FileIdentity`, `scratch` a `Scratch`, `shouldStop` a
//      closure `() -> Bool`. `fromSecond` is the whole second where the lattice resumes: the first window of the call is the first
//      sound at or after it (the entry: "then from 500 with `fromSecond: 500`").
//   2. `AudioStep.duration` is the clip's length in seconds (the test reads it as a number within 1 s); `windows` are in start order;
//      `AudioWindow.start` and `.end` are whole seconds (`end` the start plus 30, or the clip's end); `samples` are 16 kHz mono Float32,
//      a full window holds exactly 480,000 and a short one (start to end) holds (end - start) x 16,000 within 16 samples.
//   3. `readTo` is asserted only where the entry gives it (500 for the first step of a continuous 900 s clip); `finished` is true when the
//      step reached the clip's end.
//   4. The scratch folder is `$TMPDIR/Sesame-<pid>` (the sealed ScratchPNGTests: "the helper's scratch folder"). That a copy of the file
//      exists in it while a call runs, and none after, is observed from the `shouldStop` closure (the entry: it is called between
//      decoding steps of at most about 1 s each [guess]; a clip of 40 s or more must call it more than once, and no two calls are
//      further apart than 2 s).
//   5. Lossy copies (m4a, aac) are asserted against the WAV's windows with a tolerance of one second on a start (an encoder's priming
//      shifts a burst by milliseconds) and one second on an end; the count of windows is equal.

private func scratchEntries() -> Set<String> {
    let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("Sesame-\(getpid())")
    return Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
}

private func scratchFolderPath() -> String {
    (NSTemporaryDirectory() as NSString).appendingPathComponent("Sesame-\(getpid())")
}

/// Records the time of every stop check.
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

/// A shouldStop that turns true at its `n`th call.
private func stopAfter(_ n: Int) -> () -> Bool {
    let counter = StopCounter()
    return { counter.bump() >= n }
}

/// A shouldStop that never stops and looks into the scratch folder at each call.
private func probing(_ probe: ScratchProbe, ignoring before: Set<String>) -> () -> Bool {
    { probe.look(ignoring: before); return false }
}

/// A shouldStop that never stops and notes the time of each call.
private func ticking(_ clock: StopClock) -> () -> Bool {
    { clock.tick(); return false }
}

/// At every stop check, which new files of the size of the media file stand in the scratch folder.
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

private struct Outcome {
    let step: AudioStep?
    let error: String?
}

/// Reads one step. `expecting` defaults to what `lstat` says now. An error is its case name ("unreadable", "stopped", ...).
private func attempt(_ path: String, expecting: MrSeen? = nil, from: Int = 0, stop: @escaping () -> Bool = { false }) -> Outcome {
    let known = expecting ?? mrSeen(path) ?? MrSeen(size: 0, mtimeNs: 0, inode: 0)
    do {
        return Outcome(step: try AudioReader.read(path: path, expecting: mrIdentity(known), fromSecond: from, scratch: Scratch(), shouldStop: stop), error: nil)
    } catch is MediaStopped {
        return Outcome(step: nil, error: "stopped")
    } catch let error as AudioReadError {
        return Outcome(step: nil, error: String(describing: error))
    } catch {
        return Outcome(step: nil, error: "other: \(error)")
    }
}

private func describe(_ outcome: Outcome) -> String {
    if let error = outcome.error { return "threw \(error)" }
    guard let step = outcome.step else { return "no step and no error" }
    return "read \(step.windows.count) window(s) of a \(step.duration) s clip"
}

private func starts(_ step: AudioStep) -> [Int] { step.windows.map(\.start) }

private func nearly(_ value: Int, _ expected: Int, within: Int = 16) -> Bool { abs(value - expected) <= within }

private let toneLevel = -20.0

// Serialized: every call stages its copy in the one scratch folder of this process, and the staging tests look into that folder.
@Suite("AudioReaderTests", .serialized)
struct AudioReaderTests {

    // MARK: the numbers

    @Test func theWindowIsThirtySecondsTheStrideTwentyFiveAStepFiveHundredAndSilenceIsBetweenMinusSeventyAndMinusThirtyDbfs() {
        #expect(AudioReader.windowSeconds == 30, "windowSeconds is \(AudioReader.windowSeconds)")
        #expect(AudioReader.strideSeconds == 25, "strideSeconds is \(AudioReader.strideSeconds)")
        #expect(AudioReader.stepSeconds == 500, "stepSeconds is \(AudioReader.stepSeconds)")
        let db = 20 * log10(Double(AudioReader.silenceRMS))
        #expect(db > -70 && db < -30, "silenceRMS is \(AudioReader.silenceRMS), \(db) dBFS: the entry brackets it between -70 and -30 dBFS (D5: about -54)")
    }

    // MARK: D5, the window starts at a sound

    @Test func aClipOf130SecondsOfSilenceThenASixSecondBurstStartsItsFirstWindowAt130NotAt125() throws {
        try mrWithDir { dir in
            let path = dir.file("onset.wav")
            try MediaRig.writeWav(path, [.silence(130), .tone(6, db: toneLevel)])
            let outcome = attempt(path)
            let step = try #require(outcome.step, "the clip should read, it \(describe(outcome))")
            #expect(starts(step) == [130], "the window starts are \(starts(step)), expected [130] (a grid from 0 would give 125)")
            #expect(step.windows.first?.end == 136, "the window ends at \(step.windows.first?.end ?? -1), expected the clip's end 136")
            #expect(nearly(step.windows.first?.samples.count ?? -1, 96_000), "the window holds \(step.windows.first?.samples.count ?? -1) samples, expected 96,000 (6 s at 16 kHz)")
            #expect(step.finished, "a 136 s clip read from 0 is read to its end in one step")
            #expect(abs(Double(step.duration) - 136) < 1, "duration is \(step.duration), expected 136")
        }
    }

    @Test func aSecondBurstTwentySixSecondsLaterStartsTheSecondWindowAt156AndNoWindowStartsInsideSilence() throws {
        try mrWithDir { dir in
            let path = dir.file("two-bursts.wav")
            try MediaRig.writeWav(path, [.silence(130), .tone(6, db: toneLevel), .silence(20), .tone(6, db: toneLevel, hz: 660)])
            let outcome = attempt(path)
            let step = try #require(outcome.step, "the clip should read, it \(describe(outcome))")
            #expect(starts(step) == [130, 156], "the window starts are \(starts(step)), expected [130, 156] (after the window at 130 the lattice point is 155, inside silence, so the next window starts at the sound at 156)")
            #expect(step.windows.last?.end == 162, "the last window ends at \(step.windows.last?.end ?? -1), expected 162")
        }
    }

    @Test func aClipWithSoundFromTheFirstSecondStartsWindowsAtZeroTwentyFiveFiftyAndSoOn() throws {
        try mrWithDir { dir in
            let path = dir.file("continuous.wav")
            try MediaRig.writeWav(path, [.tone(160, db: toneLevel)])
            let outcome = attempt(path)
            let step = try #require(outcome.step, "the clip should read, it \(describe(outcome))")
            #expect(starts(step) == [0, 25, 50, 75, 100, 125, 150], "the window starts are \(starts(step)), expected every 25 s from 0")
            #expect(step.windows.dropLast().allSatisfy { $0.samples.count == 480_000 && $0.end - $0.start == 30 },
                    "a full window should be 30 s and hold 480,000 samples: \(step.windows.map { "\($0.start)-\($0.end) \($0.samples.count)" })")
            #expect(step.windows.last?.end == 160 && nearly(step.windows.last?.samples.count ?? -1, 160_000), "the tail window is \(step.windows.last.map { "\($0.start)-\($0.end) \($0.samples.count)" } ?? "none"), expected 150-160 with 160,000 samples")
            #expect(step.finished, "the clip is read to its end")
        }
    }

    @Test func aBurstAtMinus70DbfsCountsAsSilenceAndOneAtMinus30DbfsAsSound() throws {
        try mrWithDir { dir in
            let quiet = dir.file("quiet.wav")
            try MediaRig.writeWav(quiet, [.tone(60, db: -70)])
            let quietOutcome = attempt(quiet)
            let quietStep = try #require(quietOutcome.step, "the quiet clip should read, it \(describe(quietOutcome))")
            #expect(quietStep.windows.isEmpty, "a clip at -70 dBFS is silence and gives no window, got \(starts(quietStep))")
            #expect(quietStep.finished, "a clip with no sound is finished")

            let mixed = dir.file("mixed.wav")
            try MediaRig.writeWav(mixed, [.tone(20, db: -70), .tone(10, db: -30, hz: 550), .tone(20, db: -70)])
            let mixedOutcome = attempt(mixed)
            let mixedStep = try #require(mixedOutcome.step, "the mixed clip should read, it \(describe(mixedOutcome))")
            #expect(starts(mixedStep) == [20], "the window starts are \(starts(mixedStep)), expected [20]: the -70 dBFS part is silence and the -30 dBFS burst is sound")
        }
    }

    @Test func aClipOfOnlyDigitalSilenceReturnsNoWindowAndIsFinishedAndAClipUnderThirtySecondsReturnsOneWindowAsLongAsTheClip() throws {
        try mrWithDir { dir in
            let silent = dir.file("silent.wav")
            try MediaRig.writeWav(silent, [.silence(90)])
            let silentOutcome = attempt(silent)
            let silentStep = try #require(silentOutcome.step, "a silent clip should read, it \(describe(silentOutcome))")
            #expect(silentStep.windows.isEmpty && silentStep.finished, "a silent clip gives \(starts(silentStep)) and finished \(silentStep.finished)")
            #expect(abs(Double(silentStep.duration) - 90) < 1, "duration is \(silentStep.duration), expected 90")

            let shortClip = dir.file("short.wav")
            try MediaRig.writeWav(shortClip, [.tone(12, db: toneLevel)])
            let shortOutcome = attempt(shortClip)
            let shortStep = try #require(shortOutcome.step, "a 12 s clip should read, it \(describe(shortOutcome))")
            #expect(starts(shortStep) == [0] && shortStep.windows.first?.end == 12, "a 12 s clip gives \(shortStep.windows.map { "\($0.start)-\($0.end)" }), expected one window 0-12")
            #expect(nearly(shortStep.windows.first?.samples.count ?? -1, 192_000), "a 12 s window holds \(shortStep.windows.first?.samples.count ?? -1) samples, expected 192,000")
        }
    }

    // MARK: steps of at most 500 seconds

    @Test func oneCallReturnsAtMostTwentyWindowsAndFromSecondMovesTheStep() throws {
        try mrWithDir { dir in
            let path = dir.file("nine-hundred.wav")
            try MediaRig.writeWav(path, rate: 8000, [.tone(900, db: toneLevel)])
            let first = try #require(attempt(path, from: 0).step, "step one should read")
            #expect(starts(first) == Array(stride(from: 0, through: 475, by: 25)), "step one starts: \(starts(first)), expected 0 to 475 by 25 (20 windows)")
            #expect(first.readTo == 500, "readTo is \(first.readTo), expected 500")
            #expect(!first.finished, "a 900 s clip is not finished after one step")
            #expect(abs(Double(first.duration) - 900) < 1, "duration is \(first.duration), expected 900")
            #expect(first.windows.allSatisfy { $0.samples.count == 480_000 }, "a window of an 8 kHz clip should arrive as 480,000 samples at 16 kHz: \(first.windows.map(\.samples.count).prefix(3))")

            let second = try #require(attempt(path, from: 500).step, "step two should read")
            #expect(starts(second) == Array(stride(from: 500, through: 875, by: 25)), "step two starts: \(starts(second)), expected 500 to 875 by 25")
            #expect(second.finished, "step two reaches the clip's end")
            #expect(second.windows.last?.end == 900, "the last window ends at \(second.windows.last?.end ?? -1), expected 900")
        }
    }

    // MARK: formats

    @Test func aSixSecondToneInATwoChannel44100HertzFileArrivesAs16KilohertzMonoWithTheLevelItWasMadeAt() throws {
        try mrWithDir { dir in
            let path = dir.file("stereo.wav")
            try MediaRig.writeWav(path, rate: 44100, channels: 2, [.tone(6, db: toneLevel, hz: 440)])
            let outcome = attempt(path)
            let step = try #require(outcome.step, "the stereo clip should read, it \(describe(outcome))")
            let samples = try #require(step.windows.first?.samples, "no window")
            #expect(step.windows.count == 1 && nearly(samples.count, 96_000, within: 160), "the window holds \(samples.count) samples, expected 96,000 within 160 (10 ms: a resampler may drop its tail)")
            let level = MediaRig.rms(Array(samples.dropFirst(2000).dropLast(2000)))
            #expect(abs(level - 0.1) < 0.012, "the window's RMS is \(level), the tone was made at -20 dBFS (0.1): the clip was mixed down or resampled wrongly")
        }
    }

    @Test func aWavAnM4aAndAnAacMadeFromTheSameSoundReadTheSameWindows() throws {
        try mrWithDir { dir in
            let wav = dir.file("same.wav")
            try MediaRig.writeWav(wav, [.silence(10), .tone(8, db: toneLevel, hz: 440), .silence(22), .tone(8, db: toneLevel, hz: 700)])
            let m4a = dir.file("same.m4a"), aac = dir.file("same.aac")
            try MediaRig.encode(wav, to: m4a, container: "m4af")
            try MediaRig.encode(wav, to: aac, container: "adts")
            let reference = try #require(attempt(wav).step, "the wav should read")
            #expect(starts(reference) == [10, 40], "the wav's window starts are \(starts(reference)), expected [10, 40]")
            for path in [m4a, aac] {
                let outcome = attempt(path)
                let step = try #require(outcome.step, "\((path as NSString).lastPathComponent) should read, it \(describe(outcome))")
                #expect(step.windows.count == reference.windows.count, "\((path as NSString).lastPathComponent) gives \(starts(step)), the wav gives \(starts(reference))")
                for (got, want) in zip(step.windows, reference.windows) {
                    #expect(abs(got.start - want.start) <= 1 && abs(got.end - want.end) <= 1,
                            "\((path as NSString).lastPathComponent): window \(got.start)-\(got.end), the wav's is \(want.start)-\(want.end)")
                }
            }
        }
    }

    // MARK: stopping

    @Test func shouldStopReturningTrueThrowsMediaStoppedAndReturnsNoWindowAndItIsCalledBetweenDecodingStepsOfAboutASecond() throws {
        try mrWithDir { dir in
            let path = dir.file("long-tone.wav")
            try MediaRig.writeWav(path, [.tone(100, db: toneLevel)])
            #expect(attempt(path, stop: { true }).error == "stopped", "a shouldStop that is true from the start should throw MediaStopped")

            // never stopping: how often it is called and the longest gap between two calls
            let count = StopClock()
            let step = try #require(attempt(path, stop: ticking(count)).step, "the clip should read")
            #expect(step.windows.count == 4, "a 100 s tone gives windows at 0, 25, 50 and 75, got \(starts(step))")
            let times = count.all
            #expect(times.count >= 2, "shouldStop was called \(times.count) time(s) over a 100 s clip, expected a call between decoding steps")
            let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
            let longest = gaps.max() ?? 0
            print("READING audio shouldStop calls=\(times.count) longest gap=\(String(format: "%.2f", longest)) s")
            #expect(longest < 2.0, "the longest time between two stop checks is \(longest) s, expected about a second at most")

            // stopping after two calls
            let stopped = attempt(path, stop: stopAfter(2))
            #expect(stopped.error == "stopped" && stopped.step == nil, "a stop at the second check should throw MediaStopped and return no step, it \(describe(stopped))")
        }
    }

    // MARK: files that cannot be read

    @Test func randomBytesUnderMp3M4aAndWavACutM4aAndAZeroByteFileThrowUnreadable() throws {
        try mrWithDir { dir in
            let whole = dir.file("whole.wav")
            try MediaRig.writeWav(whole, [.tone(40, db: toneLevel)])
            let m4a = dir.file("whole.m4a")
            try MediaRig.encode(whole, to: m4a, container: "m4af")
            let control = attempt(m4a)
            #expect(control.step != nil, "control: the uncut m4a should read, it \(describe(control))")

            var generator = SystemRandomNumberGenerator()
            func noise(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
            let cases: [(name: String, data: Data)] = [
                ("noise.mp3", noise(6000)), ("noise.m4a", noise(6000)), ("noise.wav", noise(6000)),
                ("cut.m4a", (try Data(contentsOf: URL(fileURLWithPath: m4a))).prefix(2000)), ("empty.wav", Data()),
            ]
            for item in cases {
                let path = dir.file(item.name)
                try item.data.write(to: URL(fileURLWithPath: path))
                let outcome = attempt(path)
                #expect(outcome.error == "unreadable", "\(item.name) should throw unreadable, it \(describe(outcome))")
            }
        }
    }

    @Test func aChangedSizeOrMtimeOrInodeThrowsChangedAndTheUnchangedFileStillReads() throws {
        try mrWithDir { dir in
            let path = dir.file("shifting.wav")
            try MediaRig.writeWav(path, [.tone(10, db: toneLevel)])
            let before = try #require(mrSeen(path))
            #expect(attempt(path, expecting: before).step != nil, "control: with the identity it has, the file reads")

            // size only: bytes added at the end (after the data chunk), the modified time put back, the same inode
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0, count: 64))
            try handle.close()
            mrSetMtime(path, ns: before.mtimeNs)
            let grown = try #require(mrSeen(path))
            #expect(grown.size != before.size && grown.mtimeNs == before.mtimeNs && grown.inode == before.inode, "setup: the size-only change did not isolate the size: \(before) then \(grown)")
            #expect(attempt(path, expecting: before).error == "changed", "a different size should throw changed")

            // modified time only
            mrSetMtime(path, ns: before.mtimeNs + 5_000_000_000)
            let later = try #require(mrSeen(path))
            #expect(later.size == grown.size && later.mtimeNs != grown.mtimeNs && later.inode == grown.inode, "setup: the time-only change did not isolate the time")
            #expect(attempt(path, expecting: grown).error == "changed", "a different modified time should throw changed")

            // inode only: a copy renamed over the file, same bytes, same modified time
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

    @Test func aGoneFileAKeyNameALinkAFolderAndAFileInACachesFolderAreNotAdmittedWhateverIdentityIsGiven() throws {
        try mrWithDir { dir in
            let real = dir.file("realclip.wav")
            try MediaRig.writeWav(real, [.tone(5, db: toneLevel)])
            #expect(attempt(real).step != nil, "control: the plain clip reads")

            let gone = dir.file("vanished.wav")
            #expect(attempt(gone, expecting: MrSeen(size: 5, mtimeNs: 5, inode: 5)).error == "notAdmitted", "a path with nothing at it should throw notAdmitted")

            let key = dir.file("id_rsa.wav")
            try FileManager.default.copyItem(atPath: real, toPath: key)
            #expect(Rules.admit(path: key) == nil, "setup: the rules should refuse a key name")
            #expect(Rules.admit(path: real) != nil, "setup: the rules should admit the plain name")
            #expect(attempt(key).error == "notAdmitted", "a key-name file should throw notAdmitted")

            let link = dir.file("linkedclip.wav")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
            #expect(Rules.admit(path: link) == nil, "setup: the rules should refuse a link")
            #expect(attempt(link).error == "notAdmitted", "a symbolic link should throw notAdmitted")

            let folder = dir.file("foldernamed.wav")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #expect(attempt(folder).error == "notAdmitted", "a folder named like a clip should throw notAdmitted")

            // The Caches-folder case is dropped on purpose (plan-5-t2 tester amendment): only Rules.admit(path:picks:) refuses a file in a
            // Caches, hidden or .app folder, and AudioReader.read has no picks, so it cannot see the folder rule. That rule belongs to
            // the helper's own re-check before a step, which the helper tests cover; do not re-add it here.
        }
    }

    @Test func aFileTheProcessMayNotOpenThrowsCannotOpen() throws {
        try mrWithDir { dir in
            guard mrCanTestPermissions() else { return }
            let path = dir.file("closedclip.wav")
            try MediaRig.writeWav(path, [.tone(5, db: toneLevel)])
            #expect(attempt(path).step != nil, "control: the file reads while it is open to the process")
            #expect(chmod(path, 0) == 0, "setup: could not remove the file's permissions")
            let outcome = attempt(path)
            #expect(outcome.error == "cannotOpen", "a file with mode 000 should throw cannotOpen, it \(describe(outcome))")
        }
    }

    // MARK: the staged copy (D4)

    @Test func theBytesAreStagedAsOneCopyInTheScratchFolderWhileACallRunsAndNoCopyIsLeftAfterAnyCall() throws {
        try mrWithDir { dir in
            let path = dir.file("staged.wav")
            try MediaRig.writeWav(path, [.tone(60, db: toneLevel)])
            let size = Int(try #require(mrSeen(path)).size)
            let before = scratchEntries()

            let probe = ScratchProbe(folder: scratchFolderPath(), size: size)
            let outcome = attempt(path, stop: probing(probe, ignoring: before))
            #expect(outcome.step != nil, "the clip should read, it \(describe(outcome))")
            #expect(probe.copies.contains { $0.count == 1 }, "during the call no single copy of the \(size) byte file stood in \(scratchFolderPath()); the checks saw \(probe.copies)")
            #expect(probe.copies.allSatisfy { $0.count <= 1 }, "more than one copy stood in the scratch folder at once: \(probe.copies)")
            #expect(scratchEntries().subtracting(before).isEmpty, "after the call the scratch folder holds \(scratchEntries().subtracting(before))")

            // after a failure and after a stop, too
            let bad = dir.file("bad.wav")
            try Data(repeating: 9, count: 5000).write(to: URL(fileURLWithPath: bad))
            #expect(attempt(bad).error == "unreadable")
            #expect(scratchEntries().subtracting(before).isEmpty, "after an unreadable file the scratch folder holds \(scratchEntries().subtracting(before))")
            #expect(attempt(path, stop: { true }).error == "stopped")
            #expect(scratchEntries().subtracting(before).isEmpty, "after a stop the scratch folder holds \(scratchEntries().subtracting(before))")
        }
    }

    // MARK: the single window for the pane

    private func windowAttempt(_ path: String, start: Int, expecting: MrSeen? = nil, stop: @escaping () -> Bool = { false }) -> (window: AudioWindow?, error: String?) {
        let known = expecting ?? mrSeen(path) ?? MrSeen(size: 0, mtimeNs: 0, inode: 0)
        do {
            return (try AudioReader.window(path: path, expecting: mrIdentity(known), start: start, scratch: Scratch(), shouldStop: stop), nil)
        } catch is MediaStopped {
            return (nil, "stopped")
        } catch let error as AudioReadError {
            return (nil, String(describing: error))
        } catch {
            return (nil, "other: \(error)")
        }
    }

    @Test func theSingleWindowAt130HasTheSamplesAnIndependentDecodeCutsAtThatSecondAndNoOnsetSearchMovesIt() throws {
        try mrWithDir { dir in
            let path = dir.file("pane.wav")
            try MediaRig.writeWav(path, [.silence(130), .tone(20, db: toneLevel, hz: 523)])
            let at130 = windowAttempt(path, start: 130)
            let window = try #require(at130.window, "the window at 130 should read, it threw \(at130.error ?? "nothing")")
            #expect(window.start == 130 && window.end == 150, "the window is \(window.start)-\(window.end), expected 130-150 (the clip ends at 150)")
            let want = try MediaRig.frames(of: path, from: 130 * 16_000, count: 30 * 16_000)
            #expect(window.samples.count == want.count && want.count == 320_000, "the window holds \(window.samples.count) samples, the independent cut holds \(want.count), expected 320,000")
            if window.samples.count == want.count {
                let worst = zip(window.samples, want).map { abs($0 - $1) }.max() ?? 1
                #expect(worst < 1e-3, "the window's samples differ from the independent decode by up to \(worst)")
            }

            // the start is the stored one: a start inside the silence is not moved to the sound
            let at120 = try #require(windowAttempt(path, start: 120).window, "the window at 120 should read")
            let want120 = try MediaRig.frames(of: path, from: 120 * 16_000, count: 30 * 16_000)
            #expect(at120.start == 120 && at120.end == 150 && at120.samples.count == want120.count, "the window at 120 is \(at120.start)-\(at120.end) with \(at120.samples.count) samples, expected 120-150 with \(want120.count)")
            if at120.samples.count == want120.count {
                let worst = zip(at120.samples, want120).map { abs($0 - $1) }.max() ?? 1
                #expect(worst < 1e-3, "the window at 120 differs from the independent decode by up to \(worst): the start was moved to the sound")
                #expect(MediaRig.rms(Array(at120.samples.prefix(8 * 16_000))) < 1e-4, "the first 8 s of the window at 120 should be the silence the clip holds")
            }
        }
    }

    @Test func aWindowNearTheEndIsShorterAndEndsAtTheDurationAndAStartAtOrAfterTheDurationReturnsNil() throws {
        try mrWithDir { dir in
            let path = dir.file("tail.wav")
            try MediaRig.writeWav(path, [.tone(150, db: toneLevel)])
            let tail = try #require(windowAttempt(path, start: 140).window, "the window at 140 should read")
            #expect(tail.start == 140 && tail.end == 150 && nearly(tail.samples.count, 160_000), "the tail window is \(tail.start)-\(tail.end) with \(tail.samples.count) samples, expected 140-150 with 160,000")
            let full = try #require(windowAttempt(path, start: 100).window, "the window at 100 should read")
            #expect(full.end == 130 && full.samples.count == 480_000, "a full window is \(full.start)-\(full.end) with \(full.samples.count) samples, expected 100-130 with 480,000")
            for start in [150, 151, 400] {
                let outcome = windowAttempt(path, start: start)
                #expect(outcome.window == nil && outcome.error == nil, "a start of \(start) at or after the 150 s duration should return nil without an error, got \(outcome.window.map { "\($0.start)-\($0.end)" } ?? "nil") \(outcome.error ?? "")")
            }
        }
    }

    @Test func theSingleWindowKeepsTheIdentityErrorsUnreadableMediaStoppedAndLeavesNoCopyInTheScratchFolder() throws {
        try mrWithDir { dir in
            let before = scratchEntries()
            let path = dir.file("windowed.wav")
            try MediaRig.writeWav(path, [.tone(60, db: toneLevel)])
            let known = try #require(mrSeen(path))
            #expect(windowAttempt(path, start: 10, expecting: MrSeen(size: known.size + 1, mtimeNs: known.mtimeNs, inode: known.inode)).error == "changed", "a different size should throw changed")
            #expect(windowAttempt(path, start: 10, expecting: MrSeen(size: known.size, mtimeNs: known.mtimeNs + 1, inode: known.inode)).error == "changed", "a different modified time should throw changed")
            #expect(windowAttempt(path, start: 10, expecting: MrSeen(size: known.size, mtimeNs: known.mtimeNs, inode: known.inode + 1)).error == "changed", "a different inode should throw changed")
            #expect(windowAttempt(dir.file("vanished.wav"), start: 0, expecting: MrSeen(size: 5, mtimeNs: 5, inode: 5)).error == "notAdmitted", "a gone path should throw notAdmitted")
            let noise = dir.file("noise.wav")
            try Data(repeating: 9, count: 5000).write(to: URL(fileURLWithPath: noise))
            #expect(windowAttempt(noise, start: 0).error == "unreadable", "random bytes should throw unreadable")
            #expect(windowAttempt(path, start: 10, stop: { true }).error == "stopped", "a shouldStop that is true should throw MediaStopped")
            if mrCanTestPermissions() {
                let closed = dir.file("closed.wav")
                try MediaRig.writeWav(closed, [.tone(5, db: toneLevel)])
                chmod(closed, 0)
                #expect(windowAttempt(closed, start: 0).error == "cannotOpen", "a file with mode 000 should throw cannotOpen")
            }
            #expect(windowAttempt(path, start: 10).window != nil, "control: the window reads with its own identity")
            #expect(scratchEntries().subtracting(before).isEmpty, "after the calls the scratch folder holds \(scratchEntries().subtracting(before))")
        }
    }
}

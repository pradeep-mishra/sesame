import AVFoundation
import Foundation
import Speech
import Testing
import SesameEngine

// plan-5-t4, tester step. Written from the entry plan-5-t4 of plan-5-tasks.md (Tests), the Conventions, the Decisions D3 to D8 and D11, the
// t2 and t3 tester and implementer reports and the plan 4 preview tests (PreviewReaderPdfTests is the model) only; no product source is
// read. The shapes this file pins that the entry did not fix are listed at the top of PreviewMediaRig.swift.
//
// How a run is made. One shared world (a lazily built global, like PreviewReaderPdfTests): a folder of seven WAV files this file writes,
// picked by the bundled release helper alone (`scripts/bundle.sh` first), fake embedder, throwaway HOME. When all seven are `done` the
// helper is stopped, so the index is closed. Each test then calls `PreviewReader(scratch:speech:).reply(ticket:file:passage:query:)` in
// this process with a passage id read from the index, under the world's HOME and `homeLock`.
//
// D3 does not apply to this file: the preview decodes the stored window with `AudioReader.window` and asks Apple's on-device Speech
// (here a recording fake); it never loads the embedding model.
//
// The clip `harborwalk.wav` (16 kHz mono, 220 s, written by hand; every level is an RMS level, `MediaRig.Part.tone`):
//     0 to 95 s     sound, level -35 to -15 dB by the formula `paEarly` (period 17 s)
//     95 to 130 s   digital silence
//     130 to 160 s  the block the waveform judge is asked for: levels -40 to -12 dB by `paBlock` (period 23 s)
//     160 to 220 s  sound again, levels -38 to -14 dB by `paTail` (period 19 s)
// By the D5 rule (a window starts at the first sound at or after the last start plus 25 s, floored to a whole second) its windows start at
// 0, 25, 50, 75, then, because 100 and 125 fall inside the silence, at 130, and then 155, 180 and 205 (the last one ends at 220, 15 s
// long). `theIndexHoldsTheWindowsOfTheD5RuleForTheClip` pins that table, written here by hand, so a reader that disagrees fails there and
// not in the tests that depend on it. The other files of the world: `harborswap-longer.wav`, `harborswap-shorter.wav`, `harborgone-deleted.wav`,
// `harborgone-moved.wav` and `harborbroken.wav` are the same clip (each test mutates only its own), and `harborlate.wav` is 8 kHz mono,
// 4,500 s of digital silence and then a 20 s tone (its one window starts at 4,500 s: "75:00").
//
// The judge of the waveform is the kit's `scripts/kit-readback.sh waveform-check <png> <wav> <start>` (t1), a child process. A control
// run claims the wrong start and must exit 1, so the judge is shown able to say no on this very picture.

// MARK: the clip, written by hand

private func paEarly(_ second: Int) -> Double { -35 + 20 * Double((second * 3 + 1) % 17) / 16 }
private func paBlock(_ second: Int) -> Double { -40 + 28 * Double((second * 7 + 3) % 23) / 22 }
private func paTail(_ second: Int) -> Double { -38 + 24 * Double((second * 5 + 11) % 19) / 18 }
private func paOther(_ second: Int) -> Double { -36 + 22 * Double((second * 13 + 5) % 29) / 28 }

private func paMainParts() -> [MediaRig.Part] {
    var parts: [MediaRig.Part] = []
    for second in 0..<95 { parts.append(.tone(1, db: paEarly(second))) }
    parts.append(.silence(35))
    for second in 130..<160 { parts.append(.tone(1, db: paBlock(second))) }
    for second in 160..<220 { parts.append(.tone(1, db: paTail(second))) }
    return parts
}

private func paOtherParts(seconds: Int) -> [MediaRig.Part] { (0..<seconds).map { .tone(1, db: paOther($0)) } }

private let paMainName = "harborwalk.wav"
private let paWindowStarts = [0, 25, 50, 75, 130, 155, 180, 205]
private let paWords = "the keeper repaired the lamp at the lighthouse"

// MARK: the shared world

private struct PaWorld: @unchecked Sendable {
    var world: AtWorld?
    var problem: String?

    var folder: String { world?.photos.path ?? "" }
    func path(_ name: String) -> String { folder + "/" + name }
    var home: String { world?.home.path ?? "" }

    func passage(_ file: String, source: String = "audio", start: Int) -> Int? {
        world?.db()?.int("""
            select p.id from passages p join files f on f.id = p.file_id \
            where f.path like '%/\(file)' and p.source = '\(source)' and cast(p.start as integer) = \(start)
            """)
    }

    func end(of id: Int) -> Int? { world?.db()?.int("select cast(\"end\" as integer) from passages where id = \(id)") }

    func starts(_ file: String) -> [Int] {
        let rows = world?.db()?.rows("""
            select cast(p.start as integer) from passages p join files f on f.id = p.file_id \
            where f.path like '%/\(file)' and p.source = 'audio' order by p.start
            """) ?? []
        return rows.compactMap { $0.first.flatMap { $0 }.flatMap { Int($0) } }
    }
}

private let paWorld: PaWorld = {
    var out = PaWorld()
    guard let world = try? AtWorld() else { out.problem = "could not make a temp world"; return out }
    out.world = world
    pmKeeper.add(world)
    atexit { pmKeeper.run() }
    let names = [paMainName, "harborswap-longer.wav", "harborswap-shorter.wav", "harborgone-deleted.wav", "harborgone-moved.wav", "harborbroken.wav"]
    do {
        for (index, name) in names.enumerated() {
            let path = out.path(name)
            try MediaRig.writeWav(path, paMainParts())
            try mrAge(path, index + 10)
        }
        let late = out.path("harborlate.wav")
        try MediaRig.writeWav(late, rate: 8000, [.silence(4500), .tone(20, db: -25, hz: 330)])
        try mrAge(late, 30)
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
    let settled = mrWaitSettled(world, helper, expected: 7, quiet: 1.5, stall: 240, cap: 900)
    let notDone = settled.rows.filter { $0.value.status != "done" }
    guard settled.met, notDone.isEmpty else {
        out.problem = "the 7 clips did not all reach done: \(mrDescribe(settled.rows)), stderr: \(helper.errors)"
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

private struct PaStop: Error {}

private func paWorldOrStop() throws -> PaWorld {
    let outcome = paWorld
    if let problem = outcome.problem {
        Issue.record("setup failed: \(problem)")
        throw PaStop()
    }
    return outcome
}

private func paSamples(_ path: String, start: Int, end: Int) throws -> [Float] {
    try MediaRig.frames(of: path, from: start * 16000, count: (end - start) * 16000)
}

private func paMaxDifference(_ a: [Float], _ b: [Float]) -> Double {
    zip(a, b).reduce(0.0) { max($0, abs(Double($1.0) - Double($1.1))) }
}

// MARK: the tests

extension EncodeHelperTests {
@Suite("PreviewReaderAudioTests", .serialized)
struct PreviewReaderAudioTests {

    // MARK: the precondition, by hand

    @Test func theIndexHoldsTheWindowsOfTheD5RuleForTheClip() throws {
        let world = try paWorldOrStop()
        #expect(world.starts(paMainName) == paWindowStarts, "the stored window starts are \(world.starts(paMainName)), the D5 rule by hand gives \(paWindowStarts)")
        let id = try #require(world.passage(paMainName, start: 130), "no window passage starts at 130")
        #expect(world.end(of: id) == 160, "the window at 130 ends at \(String(describing: world.end(of: id))), expected 160")
        let last = try #require(world.passage(paMainName, start: 205), "no window passage starts at 205")
        #expect(world.end(of: last) == 220, "the last window ends at \(String(describing: world.end(of: last))), expected the clip's end 220")
        let late = world.starts("harborlate.wav")
        #expect(late.count == 1 && (4499...4500).contains(late[0]), "the late clip's windows start at \(late), expected one window at 4500 (or 4499: measured with the t2 reader, whose floor puts a tone that begins exactly on a 500 s step edge one second early)")
    }

    // MARK: the reply of a window

    @Test func theWindowAtOneThirtyIsOkWithItsSecondsItsLocatorItsWordsAndAPngThatDecodes() throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        let id = try #require(world.passage(paMainName, start: 130))
        let before = try #require(pmFacts(path))
        let speech = PmSpeech(words: paWords)
        let ticket = pmTickets.next()
        let reply = pmReply(world.home, speech: speech, file: path, passage: id, ticket: ticket)
        defer { pmDropPNG(reply) }

        #expect(reply.status == .ok, "status is \(reply.status), expected ok")
        #expect(reply.ticket == ticket)
        #expect(reply.name == paMainName, "name is \(reply.name)")
        #expect(reply.kind == "audio", "kind is \(reply.kind)")
        #expect(reply.size == Int(before.size), "size is \(String(describing: reply.size)), stat says \(before.size)")
        #expect(reply.mtime == Int(before.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)), stat says \(before.mtimeNs / 1_000_000_000)")
        #expect(reply.seconds == 130, "seconds is \(String(describing: reply.seconds)), expected 130")
        #expect(reply.locator == "Opens at 02:10", "locator is \(String(describing: reply.locator)), expected exactly `Opens at 02:10`")
        #expect(reply.text == paWords, "text is \(String(describing: reply.text)), expected the words the speech service returned")
        #expect(reply.marks.isEmpty, "an audio reply carries no text marks: \(reply.marks)")
        #expect(reply.page == nil && reply.pageCount == nil, "an audio reply has a page: \(String(describing: reply.page)) of \(String(describing: reply.pageCount))")

        let png = try #require(reply.png, "no png path in an ok audio reply")
        #expect(png.hasPrefix("/"), "the png path is not absolute: \(png)")
        let decoded = try #require(pmDecode(png), "the png at \(png) cannot be read by ImageIO")
        #expect(decoded.type == "public.png", "the picture is of type \(decoded.type ?? "nil"), expected public.png")

        let after = try #require(pmFacts(path))
        #expect(after == before, "the preview changed the file (size, mtime, inode or bytes)")
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder still holds \(pmScratchLeftovers()) besides PNG files: a staged copy was not removed")
    }

    @Test(arguments: [(0, "Opens at 00:00"), (25, "Opens at 00:25"), (50, "Opens at 00:50"), (75, "Opens at 01:15"),
                      (130, "Opens at 02:10"), (155, "Opens at 02:35"), (180, "Opens at 03:00"), (205, "Opens at 03:25")])
    func theLocatorIsTheStoredWindowStartAsMinutesAndSeconds(_ start: Int, _ locator: String) throws {
        let world = try paWorldOrStop()
        let id = try #require(world.passage(paMainName, start: start), "the index holds no window passage at \(start)")
        let reply = pmReply(world.home, speech: PmSpeech(supportsOnDevice: false), file: world.path(paMainName), passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok)
        #expect(reply.seconds == start, "seconds is \(String(describing: reply.seconds)), expected \(start)")
        #expect(reply.locator == locator, "locator is \(String(describing: reply.locator)), expected exactly `\(locator)`")
    }

    @Test func aWindowPastAnHourReadsMinutesAboveFiftyNineNotAnHourAndMinutes() throws {
        let world = try paWorldOrStop()
        let stored = try #require(world.starts("harborlate.wav").first, "the index holds no window passage of harborlate.wav")
        let id = try #require(world.passage("harborlate.wav", start: stored))
        let reply = pmReply(world.home, speech: PmSpeech(supportsOnDevice: false), file: world.path("harborlate.wav"), passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok, "status is \(reply.status)")
        #expect(reply.kind == "audio")
        #expect(reply.seconds == stored, "seconds is \(String(describing: reply.seconds)), expected the stored \(stored)")
        let expected = String(format: "Opens at %d:%02d", stored / 60, stored % 60)
        #expect(stored >= 4499 && expected.hasPrefix("Opens at 7"), "setup: the stored start \(stored) is not 74 or 75 minutes in")
        #expect(reply.locator == expected, "locator is \(String(describing: reply.locator)), expected exactly `\(expected)` (75:00 for 4500 s: minutes are not capped at 59 and there is no hour)")
        #expect(reply.png != nil, "no png for the late window")
    }

    // MARK: the waveform, judged by the kit

    @Test(arguments: [130, 155, 25])
    func theDrawnWaveformIsTheThirtySecondBlockAtTheStoredStartAsTheKitsWaveformCheckReadsIt(_ start: Int) throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        let id = try #require(world.passage(paMainName, start: start))
        let reply = pmReply(world.home, speech: PmSpeech(supportsOnDevice: false), file: path, passage: id)
        defer { pmDropPNG(reply) }
        let png = try #require(reply.png, "no png path in an ok audio reply")

        let ran = try #require(pmWaveformCheck(png: png, audio: path, start: start))
        #expect(ran.status == 0, "waveform-check exited \(ran.status), expected 0 (the drawn envelope is the block that starts at \(start)): \(ran.output)")
    }

    @Test func theWaveformJudgeSaysNoToTheSamePictureWhenTheWrongStartIsClaimed() throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        let id = try #require(world.passage(paMainName, start: 130))
        let reply = pmReply(world.home, speech: PmSpeech(supportsOnDevice: false), file: path, passage: id)
        defer { pmDropPNG(reply) }
        let png = try #require(reply.png, "no png path in an ok audio reply")

        let wrong = try #require(pmWaveformCheck(png: png, audio: path, start: 100))
        #expect(wrong.status == 1, "waveform-check exited \(wrong.status) for a claimed start of 100 on the picture of 130, expected 1: \(wrong.output)")
    }

    // MARK: Speech, the one seam

    @Test func everyCallOfTheSpeechServiceIsOnDeviceAndSeesExactlyTheStoredWindowsSamples() throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        for start in [130, 155, 205, 25] {
            let id = try #require(world.passage(paMainName, start: start), "the index holds no window passage at \(start)")
            let end = try #require(world.end(of: id), "the passage \(id) has no end")
            let expected = try paSamples(path, start: start, end: end)
            #expect(expected.count == (end - start) * 16000, "setup: the test's own decode of \(start) to \(end) holds \(expected.count) samples")

            let speech = PmSpeech(words: paWords)
            let reply = pmReply(world.home, speech: speech, file: path, passage: id)
            defer { pmDropPNG(reply) }
            let calls = speech.calls
            #expect(calls.count == 1, "window \(start): the speech service was called \(calls.count) times, expected once")
            guard let call = calls.first else { continue }
            #expect(call.onDevice, "window \(start): the request is not on-device (requiresOnDeviceRecognition is false)")
            #expect(call.samples.count == expected.count, "window \(start): the service saw \(call.samples.count) samples, expected exactly \(expected.count) (the stored window and nothing else)")
            if call.samples.count == expected.count {
                let difference = paMaxDifference(call.samples, expected)
                #expect(difference < 0.002, "window \(start): the service's samples differ from the clip's own decode by up to \(difference)")
            }
            #expect(reply.text == paWords, "window \(start): text is \(String(describing: reply.text))")
        }
    }

    @Test func withNoOnDeviceSupportTheServiceIsNeverCalledThereAreNoWordsAndTheWaveformIsStillThere() throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        let id = try #require(world.passage(paMainName, start: 130))
        let speech = PmSpeech(supportsOnDevice: false, words: paWords)
        let reply = pmReply(world.home, speech: speech, file: path, passage: id)
        defer { pmDropPNG(reply) }

        #expect(speech.calls.isEmpty, "the speech service was called \(speech.calls.count) times although it cannot recognize on this device: nothing may fall back to a server")
        #expect(reply.status == .ok, "status is \(reply.status), expected ok")
        #expect(reply.text == nil, "text is \(String(describing: reply.text)), expected nil")
        #expect(reply.locator == "Opens at 02:10" && reply.seconds == 130, "locator \(String(describing: reply.locator)), seconds \(String(describing: reply.seconds))")
        let png = try #require(reply.png, "no waveform png")
        #expect(pmDecode(png) != nil, "the png at \(png) does not decode")
    }

    @Test func nothingTheServiceReturnedIsWrittenToTheScratchFolderTheIndexOrTheLog() throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        let id = try #require(world.passage(paMainName, start: 130))
        let marker = "zqmarker-lighthouse-keeper-7731"
        let speech = PmSpeech(words: marker + " " + paWords)
        let reply = pmReply(world.home, speech: speech, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.text?.contains(marker) == true, "setup: the reply does not carry the service's words: \(String(describing: reply.text))")

        let inHome = pmFolderHolds(marker, under: world.home)
        #expect(inHome.isEmpty, "the service's words were written under the HOME (the index, its log or another file): \(inHome)")
        let inScratch = pmFolderHolds(marker, under: pmScratchFolder)
        #expect(inScratch.isEmpty, "the service's words were written to the scratch folder: \(inScratch)")
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder holds \(pmScratchLeftovers()) besides PNG files")
        let log = mrIndexLog(world.world!)
        #expect(!log.contains(marker), "the helper's log holds the service's words")
    }

    @Test func aNewerTicketCancelsTheRecognitionInFlightAndTheOlderCallEndsPromptly() throws {
        let world = try paWorldOrStop()
        let path = world.path(paMainName)
        let id = try #require(world.passage(paMainName, start: 130))
        let speech = PmSpeech(words: "late words that must never be needed", hold: 30)
        nonisolated(unsafe) let reader = PreviewReader(scratch: Scratch(), speech: speech)
        let older = pmTickets.next(), newer = pmTickets.next()
        let gone = world.path("harbor-no-such-file.wav")

        pmWithHome(world.home) {
            let first = PmAsync<PreviewReply> { reader.reply(ticket: older, file: path, passage: id, query: "keeper") }
            #expect(speech.waitEntered(90), "the older call never reached the speech service")
            let started = Date()
            let second = reader.reply(ticket: newer, file: gone, passage: nil, query: "keeper")
            pmDropPNG(second)
            #expect(second.status == .gone, "the newer call (a file that is not there) is \(second.status), expected gone")
            #expect(speech.waitCancelled(5), "the speech service was not cancelled within 5 s of a newer ticket arriving")
            let firstReply = first.wait(10)
            #expect(firstReply != nil, "the older call did not return within 10 s of a newer ticket arriving")
            pmDropPNG(firstReply)
            #expect(Date().timeIntervalSince(started) < 15, "cancelling took \(Date().timeIntervalSince(started)) s")
        }
    }

    @Test func theLiveSpeechRequestIsOnDeviceOnTheLiveCodeItself() {
        let request = LiveSpeech.makeRequest()
        #expect(request.requiresOnDeviceRecognition == true, "LiveSpeech.makeRequest() builds a request with requiresOnDeviceRecognition \(request.requiresOnDeviceRecognition): audio would go to a server")
    }

    // MARK: changed

    @Test func aFileReplacedByALongerClipIsChangedAndShowsTheStoredSecondOfTheClipAsItIsNow() throws {
        let world = try paWorldOrStop()
        let path = world.path("harborswap-longer.wav")
        let id = try #require(world.passage("harborswap-longer.wav", start: 130))
        try MediaRig.writeWav(path, paOtherParts(seconds: 200))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 600)], ofItemAtPath: path)
        let now = try #require(pmFacts(path))
        let expected = try paSamples(path, start: 130, end: 160)

        let speech = PmSpeech(words: paWords)
        let reply = pmReply(world.home, speech: speech, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.kind == "audio", "kind is \(reply.kind)")
        #expect(reply.size == Int(now.size), "size is \(String(describing: reply.size)), stat says \(now.size) (the current size)")
        #expect(reply.mtime == Int(now.mtimeNs / 1_000_000_000), "mtime is \(String(describing: reply.mtime)) (the current time)")
        #expect(reply.seconds == 130, "seconds is \(String(describing: reply.seconds)), expected the stored 130 (still inside the 200 s clip)")
        #expect(reply.locator == "Opens at 02:10", "locator is \(String(describing: reply.locator))")
        let png = try #require(reply.png, "no png path in a changed audio reply")
        let ran = try #require(pmWaveformCheck(png: png, audio: path, start: 130))
        #expect(ran.status == 0, "waveform-check of the clip as it is now exited \(ran.status), expected 0 (the current waveform at 130): \(ran.output)")
        let call = speech.calls.first
        #expect(speech.calls.count == 1 && call?.onDevice == true, "the speech service was called \(speech.calls.count) times")
        if let call, call.samples.count == expected.count {
            #expect(paMaxDifference(call.samples, expected) < 0.002, "the service heard the old clip, not the current one")
        } else {
            #expect(call?.samples.count == expected.count, "the service saw \(String(describing: call?.samples.count)) samples, expected \(expected.count) of the current clip")
        }
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder holds \(pmScratchLeftovers()) besides PNG files")
    }

    @Test func aFileReplacedByAShorterClipIsChangedAndShowsTheStartOfTheNewClip() throws {
        let world = try paWorldOrStop()
        let path = world.path("harborswap-shorter.wav")
        let id = try #require(world.passage("harborswap-shorter.wav", start: 130))
        try MediaRig.writeWav(path, paOtherParts(seconds: 60))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast + 700)], ofItemAtPath: path)
        let expected = try paSamples(path, start: 0, end: 30)

        let speech = PmSpeech(words: paWords)
        let reply = pmReply(world.home, speech: speech, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .changed, "status is \(reply.status), expected changed")
        #expect(reply.seconds == 0, "seconds is \(String(describing: reply.seconds)), expected 0 (the stored 130 is past the end of the 60 s clip)")
        #expect(reply.locator == "Opens at 00:00", "locator is \(String(describing: reply.locator))")
        let png = try #require(reply.png, "no png path in a changed audio reply")
        let ran = try #require(pmWaveformCheck(png: png, audio: path, start: 0))
        #expect(ran.status == 0, "waveform-check of the clip as it is now exited \(ran.status), expected 0 (the current waveform at 0): \(ran.output)")
        if let call = speech.calls.first, call.samples.count == expected.count {
            #expect(paMaxDifference(call.samples, expected) < 0.002, "the service did not hear the first 30 s of the current clip")
        } else {
            #expect(speech.calls.first?.samples.count == expected.count, "the service saw \(String(describing: speech.calls.first?.samples.count)) samples, expected \(expected.count)")
        }
    }

    // MARK: gone

    @Test func aDeletedClipIsGoneWithNothingToShowAndNoCallToTheService() throws {
        let world = try paWorldOrStop()
        let path = world.path("harborgone-deleted.wav")
        let id = try #require(world.passage("harborgone-deleted.wav", start: 130))
        try FileManager.default.removeItem(atPath: path)

        let speech = PmSpeech(words: paWords)
        let reply = pmReply(world.home, speech: speech, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .gone, "status is \(reply.status), expected gone")
        #expect(reply.name == "harborgone-deleted.wav", "name is \(reply.name)")
        #expect(reply.png == nil, "a gone file has a png: \(String(describing: reply.png))")
        #expect(reply.size == nil && reply.mtime == nil, "a gone file has size \(String(describing: reply.size)) and mtime \(String(describing: reply.mtime))")
        #expect(reply.page == nil && reply.pageCount == nil && reply.locator == nil && reply.text == nil && reply.seconds == nil,
                "a gone file keeps a locator, words or a spot: \(String(describing: reply.locator)), \(String(describing: reply.text)), \(String(describing: reply.seconds))")
        #expect(speech.calls.isEmpty, "the speech service was called for a file that is not there")
    }

    @Test func aClipMovedIntoACachesFolderIsGoneAtItsNewPathAndAtItsOldOne() throws {
        let world = try paWorldOrStop()
        let old = world.path("harborgone-moved.wav")
        let id = try #require(world.passage("harborgone-moved.wav", start: 130))
        let caches = world.folder + "/Caches"
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let moved = caches + "/harborgone-moved.wav"
        try FileManager.default.moveItem(atPath: old, toPath: moved)
        #expect(FileManager.default.fileExists(atPath: moved), "the test's moved file is not on disk")

        for (label, file) in [("its new path inside Caches", moved), ("its old path", old)] {
            let speech = PmSpeech(words: paWords)
            let reply = pmReply(world.home, speech: speech, file: file, passage: id)
            defer { pmDropPNG(reply) }
            #expect(reply.status == .gone, "\(label): status is \(reply.status), expected gone")
            #expect(reply.png == nil, "\(label): a gone file has a png: \(String(describing: reply.png))")
            #expect(reply.locator == nil && reply.seconds == nil && reply.text == nil, "\(label): a gone file keeps a locator, words or a spot")
            #expect(speech.calls.isEmpty, "\(label): the speech service was called")
        }
    }

    // MARK: a clip that no longer opens (G20)

    @Test func aClipThatNoLongerOpensIsOkWithNoPngNoLocatorAndNoWordsSoThePaneSaysItCannotPreviewIt() throws {
        let world = try paWorldOrStop()
        let path = world.path("harborbroken.wav")
        let id = try #require(world.passage("harborbroken.wav", start: 130))
        let facts = try #require(pmFacts(path))
        let handle = try #require(FileHandle(forWritingAtPath: path), "the test cannot open harborbroken.wav for writing")
        try handle.write(contentsOf: Data(count: Int(facts.size)))
        try handle.close()
        mrSetMtime(path, ns: facts.mtimeNs)
        let now = try #require(pmFacts(path))
        #expect(now.size == facts.size && now.inode == facts.inode && now.mtimeNs == facts.mtimeNs,
                "setup: the test's overwrite changed the file's identity (size \(now.size) vs \(facts.size), mtime \(now.mtimeNs) vs \(facts.mtimeNs))")
        #expect((try? AVAudioFile(forReading: URL(fileURLWithPath: path))) == nil, "setup: AVFoundation still opens the overwritten file")

        let speech = PmSpeech(words: paWords)
        let reply = pmReply(world.home, speech: speech, file: path, passage: id)
        defer { pmDropPNG(reply) }
        #expect(reply.status == .ok, "status is \(reply.status), expected ok (the pane then says `Can't preview this file`)")
        #expect(reply.name == "harborbroken.wav", "name is \(reply.name)")
        #expect(reply.png == nil, "a clip that does not open has a png: \(String(describing: reply.png))")
        #expect(reply.locator == nil, "a clip that does not open has a locator: \(String(describing: reply.locator))")
        #expect(reply.text == nil && reply.seconds == nil, "a clip that does not open has words or a spot: \(String(describing: reply.text)), \(String(describing: reply.seconds))")
        #expect(speech.calls.isEmpty, "the speech service was called for a clip that does not open")
        #expect(pmScratchLeftovers().isEmpty, "the scratch folder holds \(pmScratchLeftovers()) besides PNG files")
    }
}
}

// MARK: the static facts of the entry's run line 12, read from the files the app ships with (the rules themselves are the kit's)

@Suite("SpeechUsageStringTests")
struct SpeechUsageStringTests {
    private func plist(_ name: String) throws -> [String: Any] {
        let url = KitPaths.projectRoot.appendingPathComponent("Resources/" + name)
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any], "\(name) is not a dictionary")
    }

    @Test func theInfoPlistHoldsTheSpeechRecognitionUsageStringAndNoCameraOrMicrophoneString() throws {
        let info = try plist("Info.plist")
        let speech = info["NSSpeechRecognitionUsageDescription"] as? String
        #expect(speech?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "Info.plist has no NSSpeechRecognitionUsageDescription string (D11): the helper's first authorization request would end the process: \(String(describing: speech))")
        for key in info.keys.sorted() {
            #expect(!key.localizedCaseInsensitiveContains("camera") && !key.localizedCaseInsensitiveContains("microphone"), "Info.plist has the key \(key): Sesame never asks for the camera or the microphone")
        }
        for (key, value) in info {
            guard let text = value as? String else { continue }
            #expect(!text.localizedCaseInsensitiveContains("camera") && !text.localizedCaseInsensitiveContains("microphone"), "the string of \(key) mentions the camera or the microphone: \(text)")
        }
        let events = info["NSAppleEventsUsageDescription"] as? String
        #expect(events?.contains("QuickTime Player") == true, "NSAppleEventsUsageDescription no longer names QuickTime Player: \(String(describing: events))")
    }

    @Test func theEntitlementsStillHoldOnlyTheAppleEventsKey() throws {
        let entitlements = try plist("Sesame.entitlements")
        #expect(Set(entitlements.keys) == ["com.apple.security.automation.apple-events"], "the entitlements are \(entitlements.keys.sorted()), expected only the apple-events key (no audio-input, no camera, no network)")
    }
}

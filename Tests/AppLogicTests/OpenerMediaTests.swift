import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-5-t5, tester step. Written from the entry plan-5-t5 of plan-5-tasks.md (Tests), Decisions D6 and D12, the t4 reports (`PreviewReply.seconds`)
// and the sealed ScratchPNGTests (`Opener.action`, `Opener.opensInText`) only; no product source is read. Every expected text is written by hand.
// The real NSAppleScript run against QuickTime Player is the accept stage (U5): nothing here runs a script, opens an app or touches a file.
//
// WHAT THE ENTRY FIXES (names and behaviour): `Opener.mediaTarget(chosen:)`, `Opener.moment(reply:stored:)`, `Opener.quickTimeScript(path:seconds:)`,
// `MediaScripting` with `run(_ source: String) -> Bool` and a recording fake; the script holds `open POSIX file`, `set current time`, `play` and
// `activate` in that order, the path escaped for quotes and backslashes, the seconds whole and 0 or more; a failed script falls back to one open of the
// default app and nothing else; every other chosen app opens the default app; a photo and a document open the default app; opening twice runs twice.
//
// SHAPES THIS FILE PINS THAT THE ENTRY DID NOT FIX (the implementer reads this block; one place to edit each, the fake `OMFakeScripting` and `OMOpen`):
//   1. `enum MediaTarget: Equatable { case quickTime, defaultApp }` is the result of `Opener.mediaTarget(chosen: String)`.
//   2. `protocol MediaScripting` has two requirements, `func run(_ source: String) -> Bool` and `func open(_ url: URL)`. The entry says the fake
//      sees "one open(url)", so the workspace open goes through the same seam: without it no test could keep from opening a real app. The fake
//      conforms from a nonisolated `final class ..., @unchecked Sendable`.
//   3. `Opener.open(kind: String, path: String, spot: Int?, chosen: String, using scripting: any MediaScripting)` is the one entry that opens a
//      photo, a document, an audio or a video file through the seam. `kind` is the engine's kind word, `spot` the whole seconds, `chosen` the text of
//      `openWith.media` ("" is the first build's QuickTime Player). It returns nothing (a returned value would only draw a compiler warning here).
//   4. An audio or video file with a nil `spot` and QuickTime Player chosen still runs the script, at second 0 (it opens in the app the pane names).
//   5. The seconds in the script are the last whole number written between `set current time` and `play`.
// NOT PINNED (the entry is silent): `Opener.moment` for a reply that exists but has no `seconds` while a stored second exists; the exact words of
// the AppleScript around the four phrases; how `Panel` takes the seam (PanelOpenMediaTests pins that).

private enum OMEvent: Equatable {
    case script(String)
    case open(URL)
}

final class OMFakeScripting: MediaScripting, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [OMEvent] = []
    private let answer: Bool

    init(answer: Bool = true) { self.answer = answer }

    func run(_ source: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        log.append(.script(source))
        return answer
    }

    func open(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        log.append(.open(url))
    }

    fileprivate var events: [OMEvent] { lock.lock(); defer { lock.unlock() }; return log }
    var scripts: [String] { events.compactMap { if case .script(let text) = $0 { return text } else { return nil } } }
    var opens: [URL] { events.compactMap { if case .open(let url) = $0 { return url } else { return nil } } }
    var count: Int { events.count }
}

/// The text of `script` from the first `from` to the next `to` after it, or nil when either is missing.
func omBetween(_ script: String, _ from: String, _ to: String) -> String? {
    guard let start = script.range(of: from), let end = script.range(of: to, range: start.upperBound..<script.endIndex) else { return nil }
    return String(script[start.upperBound..<end.lowerBound])
}

/// The last whole number written between `set current time` and `play`, as text; nil when there is none.
func omSeconds(in script: String) -> String? {
    guard let between = omBetween(script, "set current time", "play") else { return nil }
    var last: String?
    var search = between.startIndex..<between.endIndex
    while let found = between.range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression, range: search) {
        last = String(between[found])
        search = found.upperBound..<between.endIndex
    }
    return last
}

/// True when `needles` all occur in `script`, each after the one before it.
func omInOrder(_ script: String, _ needles: [String]) -> Bool {
    var from = script.startIndex
    for needle in needles {
        guard let found = script.range(of: needle, range: from..<script.endIndex) else { return false }
        from = found.upperBound
    }
    return true
}

@MainActor
private func omOpen(_ kind: String, _ path: String, spot: Int?, chosen: String, _ scripting: OMFakeScripting) {
    Opener.open(kind: kind, path: path, spot: spot, chosen: chosen, using: scripting)
}

private let omAudioPath = "/Users/test/Music/harbor interview.m4a"
private let omVideoPath = "/Users/test/Movies/trip clip.mov"

private func omReply(kind: String, seconds: Int?) -> PreviewReply {
    PreviewReply(ticket: 1, status: .ok, png: nil, name: "clip", kind: kind, size: 1_000, mtime: 1_700_000_000,
                 locator: seconds == nil ? nil : "Opens at 00:00", seconds: seconds)
}

@Suite("OpenerMediaTests")
struct OpenerMediaTests {

    // MARK: Opener.mediaTarget

    @MainActor
    @Test(arguments: ["QuickTime Player", ""])
    func quickTimePlayerAndAnEmptyNameAreQuickTime(_ chosen: String) {
        #expect(Opener.mediaTarget(chosen: chosen) == .quickTime, "\"\(chosen)\" gave \(Opener.mediaTarget(chosen: chosen))")
    }

    @MainActor
    @Test(arguments: ["IINA", "VLC", "Infuse", "Some Player That Is Not Installed"])
    func everyOtherNameIsTheDefaultApp(_ chosen: String) {
        #expect(Opener.mediaTarget(chosen: chosen) == .defaultApp, "\"\(chosen)\" gave \(Opener.mediaTarget(chosen: chosen))")
    }

    // MARK: Opener.moment

    @MainActor
    @Test func theRepliesSecondsWinOverTheStoredSecond() {
        #expect(Opener.moment(reply: omReply(kind: "audio", seconds: 130), stored: 25) == 130)
        #expect(Opener.moment(reply: omReply(kind: "video", seconds: 42), stored: nil) == 42)
    }

    @MainActor
    @Test func aRepliesSecondOfZeroIsAMomentNotAnAbsence() {
        #expect(Opener.moment(reply: omReply(kind: "video", seconds: 0), stored: 25) == 0)
    }

    @MainActor
    @Test func withNoReplyTheStoredSecondIsTheMoment() {
        #expect(Opener.moment(reply: nil, stored: 25) == 25)
        #expect(Opener.moment(reply: nil, stored: 0) == 0)
    }

    @MainActor
    @Test func withNeitherThereIsNoMoment() {
        #expect(Opener.moment(reply: nil, stored: nil) == nil)
    }

    // MARK: Opener.quickTimeScript

    @MainActor
    @Test func theScriptHoldsOpenSetTimePlayAndActivateInThatOrder() {
        let script = Opener.quickTimeScript(path: "/Users/test/Music/clip.m4a", seconds: 130)
        #expect(omInOrder(script, ["open POSIX file", "set current time", "play", "activate"]), "the script is \(script)")
        #expect(omSeconds(in: script) == "130", "the seconds written are \(String(describing: omSeconds(in: script))) in \(script)")
        #expect(script.contains("QuickTime Player"), "the script does not name QuickTime Player: \(script)")
    }

    @MainActor
    @Test func thePathIsWrittenInsideQuotesAfterOpenPosixFile() throws {
        let script = Opener.quickTimeScript(path: "/Users/test/Music/clip.m4a", seconds: 5)
        let after = try #require(omBetween(script, "open POSIX file", "set current time"), "no `open POSIX file` before `set current time`: \(script)")
        #expect(after.contains(#""/Users/test/Music/clip.m4a""#), "the path is not one quoted text after `open POSIX file`: \(after)")
    }

    @MainActor
    @Test(arguments: [
        (#"/Users/test/Mov"ies/clip.m4a"#, #""/Users/test/Mov\"ies/clip.m4a""#),
        (#"/Users/test/back\slash/clip.m4a"#, #""/Users/test/back\\slash/clip.m4a""#),
        (#"/Users/test/a\"b.m4a"#, #""/Users/test/a\\\"b.m4a""#),
        (#"/Users/test/x" & (do shell script "touch /tmp/pwned") & "/clip.m4a"#, #""/Users/test/x\" & (do shell script \"touch /tmp/pwned\") & \"/clip.m4a""#),
        ("/Users/test/My Music/clip two.m4a", #""/Users/test/My Music/clip two.m4a""#),
        ("/Users/test/Mus\u{00ED}ca/caf\u{00E9} \u{65E5}\u{672C}\u{8A9E} \u{1F3A7}.m4a", "\"/Users/test/Mus\u{00ED}ca/caf\u{00E9} \u{65E5}\u{672C}\u{8A9E} \u{1F3A7}.m4a\""),
        (#"/Users/test/Mov"ies/back\slash/Café été clip.m4a"#, #""/Users/test/Mov\"ies/back\\slash/Café été clip.m4a""#),
    ])
    func aNameWithQuotesBackslashesSpacesOrNonAsciiLettersSurvivesAsOneQuotedText(_ path: String, _ literal: String) {
        let script = Opener.quickTimeScript(path: path, seconds: 7)
        #expect(script.contains(literal), "the script does not hold \(literal): \(script)")
        #expect(omInOrder(script, ["open POSIX file", literal, "set current time", "play", "activate"]), "the order is wrong: \(script)")
    }

    @MainActor
    @Test func aQuoteInTheNameNeverEndsTheQuotedTextEarly() {
        let script = Opener.quickTimeScript(path: #"/Users/test/Mov"ies/clip.m4a"#, seconds: 7)
        #expect(!script.contains(#"Mov"ies"#), "an unescaped quote is in the script: \(script)")
    }

    @MainActor
    @Test(arguments: [(130, "130"), (0, "0"), (1, "1"), (4_500, "4500"), (-5, "0"), (-1, "0")])
    func theSecondsAreAWholeNumberOfZeroOrMore(_ seconds: Int, _ written: String) {
        let script = Opener.quickTimeScript(path: "/Users/test/Music/clip.m4a", seconds: seconds)
        #expect(omSeconds(in: script) == written, "\(seconds) was written as \(String(describing: omSeconds(in: script))) in \(script)")
    }

    // MARK: Opener.open through the seam

    @MainActor
    @Test(arguments: [("audio", 130, "QuickTime Player", "130"), ("audio", 130, "", "130"), ("video", 42, "QuickTime Player", "42"),
                      ("video", 0, "", "0"), ("audio", 4_500, "QuickTime Player", "4500")])
    func anAudioOrVideoFileRunsOneScriptAtTheSpotWhenQuickTimeIsChosen(_ kind: String, _ spot: Int, _ chosen: String, _ written: String) {
        let path = kind == "audio" ? omAudioPath : omVideoPath
        let fake = OMFakeScripting()
        omOpen(kind, path, spot: spot, chosen: chosen, fake)
        #expect(fake.count == 1, "the seam saw \(fake.count) calls: \(fake.scripts), \(fake.opens)")
        #expect(fake.opens.isEmpty, "the default app was opened as well: \(fake.opens)")
        guard let script = fake.scripts.first else {
            Issue.record("no script ran for \(kind) at \(spot) with \"\(chosen)\" chosen")
            return
        }
        #expect(omInOrder(script, ["open POSIX file", "set current time", "play", "activate"]), "the script is \(script)")
        #expect(omSeconds(in: script) == written, "the seconds written are \(String(describing: omSeconds(in: script))) in \(script)")
        #expect(script.contains(path), "the script does not name the file: \(script)")
    }

    @MainActor
    @Test(arguments: ["audio", "video"])
    func aMediaFileWithNoSpotStillRunsTheScriptAtTheStart(_ kind: String) {
        let fake = OMFakeScripting()
        omOpen(kind, kind == "audio" ? omAudioPath : omVideoPath, spot: nil, chosen: "QuickTime Player", fake)
        #expect(fake.count == 1 && fake.opens.isEmpty, "the seam saw \(fake.scripts), \(fake.opens)")
        if let script = fake.scripts.first {
            #expect(omSeconds(in: script) == "0", "the seconds written are \(String(describing: omSeconds(in: script))) in \(script)")
        }
    }

    @MainActor
    @Test(arguments: ["audio", "video"])
    func aScriptThatFailsFallsBackToOneOpenOfTheDefaultAppAndNothingElse(_ kind: String) {
        let path = kind == "audio" ? omAudioPath : omVideoPath
        let fake = OMFakeScripting(answer: false)
        omOpen(kind, path, spot: 130, chosen: "QuickTime Player", fake)
        #expect(fake.events == [.script(fake.scripts.first ?? ""), .open(URL(fileURLWithPath: path))],
                "the seam saw \(fake.scripts.count) script(s) and \(fake.opens.count) open(s): \(fake.opens)")
        #expect(fake.scripts.count == 1, "the script ran \(fake.scripts.count) times")
        #expect(fake.opens == [URL(fileURLWithPath: path)], "the default app got \(fake.opens)")
    }

    @MainActor
    @Test(arguments: ["IINA", "VLC", "Infuse", "An App That Is Not Installed"])
    func anyOtherChosenAppOpensTheDefaultAppWithNoScript(_ chosen: String) {
        for (kind, path) in [("audio", omAudioPath), ("video", omVideoPath)] {
            let fake = OMFakeScripting()
            omOpen(kind, path, spot: 130, chosen: chosen, fake)
            #expect(fake.scripts.isEmpty, "\(kind) with \"\(chosen)\" chosen ran a script: \(fake.scripts)")
            #expect(fake.opens == [URL(fileURLWithPath: path)], "\(kind) with \"\(chosen)\" chosen opened \(fake.opens)")
            #expect(fake.count == 1, "the seam saw \(fake.count) calls")
        }
    }

    @MainActor
    @Test(arguments: ["QuickTime Player", "", "IINA"])
    func aPhotoAndADocumentOpenTheDefaultAppWithNoScript(_ chosen: String) {
        let photo = "/Users/test/Pictures/beach dog.jpg"
        let doc = "/Users/test/Documents/lease.docx"
        for (kind, path, spot) in [("photo", photo, Int?.none), ("photo", photo, 4), ("doc", doc, nil), ("doc", doc, 2)] {
            let fake = OMFakeScripting()
            omOpen(kind, path, spot: spot, chosen: chosen, fake)
            #expect(fake.scripts.isEmpty, "a \(kind) with \"\(chosen)\" chosen ran a script: \(fake.scripts)")
            #expect(fake.opens == [URL(fileURLWithPath: path)], "a \(kind) with \"\(chosen)\" chosen opened \(fake.opens)")
            #expect(fake.count == 1, "the seam saw \(fake.count) calls")
        }
    }

    @MainActor
    @Test func openingTheSameFileTwiceRunsTheScriptTwiceWithoutAnOpen() {
        let fake = OMFakeScripting()
        omOpen("audio", omAudioPath, spot: 130, chosen: "QuickTime Player", fake)
        omOpen("audio", omAudioPath, spot: 130, chosen: "QuickTime Player", fake)
        #expect(fake.scripts.count == 2, "the script ran \(fake.scripts.count) times")
        #expect(fake.opens.isEmpty, "the default app was opened: \(fake.opens)")
        if fake.scripts.count == 2 {
            #expect(fake.scripts[0] == fake.scripts[1], "the two scripts differ: \(fake.scripts)")
        }
    }

    @MainActor
    @Test func aFailedFirstOpenDoesNotStopTheNextOneFromRunningTheScript() {
        let fake = OMFakeScripting(answer: false)
        omOpen("video", omVideoPath, spot: 42, chosen: "", fake)
        omOpen("video", omVideoPath, spot: 66, chosen: "", fake)
        #expect(fake.scripts.count == 2 && fake.opens.count == 2, "the seam saw \(fake.scripts.count) scripts and \(fake.opens.count) opens")
        if fake.scripts.count == 2 {
            #expect(omSeconds(in: fake.scripts[0]) == "42" && omSeconds(in: fake.scripts[1]) == "66",
                    "the seconds written were \(fake.scripts.map { omSeconds(in: $0) ?? "none" })")
        }
    }
}

import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// Acceptance tests for plan-1-t25 (the not-ready function and PanelState).
// Every expected text and every order below is written by hand from spec S1 ("Not ready",
// "Error variants") and design section 3 ("Not-ready screen", "Panel states"); none comes from
// the code under test.
//
// Contract these tests pin (the design names the types but fixes no signatures). All of it is
// `public` in SesameEngine, because the tests use `import SesameEngine`, not `@testable`:
//
//   enum ModelState { case whole, downloading, damaged }
//       downloading = not present or not whole; damaged = failed its check, being fetched again.
//   struct IndexCounts { init(done: Int, pending: [String: Int], partial: [String: Int]) }
//       status counts of `files`; the two dictionaries are kind -> number of rows.
//   struct PanelInputs { init(model:startPressed:indexDeleted:walkDoneAt:counts:vectorSourceOK:
//                              kindsOn:typed:rankedCount:) }
//       walkDoneAt: Date? (nil = no walk finished); kindsOn: Set<String> of kinds switched on;
//       typed: the text in the box; rankedCount: Int? (nil = the ranked list is not in yet).
//   enum PanelState: Equatable, with at least these cases
//       .notReady(NotReadyView)   NotReadyView { heading: String, text: String, note: String? }
//       .indexing(IndexingBanner) IndexingBanner { percent: Int, title: String, missing: String }
//       .emptyHint(EmptyHint)     EmptyHint { text: String, samples: [String] }
//       .noMatches(NoMatches)     NoMatches { title: String, hint: String }
//       .results
//   PanelState.evaluate(_ inputs: PanelInputs) -> PanelState      (pure)
//   PanelState.cut(_ text: String) -> String                      (the 500-character cut)

private let allKinds: Set<String> = ["photo", "pdf", "doc", "audio", "video"]
private let walkDone = Date(timeIntervalSince1970: 1_700_000_000)

private let heading = "Not ready yet"
private let text1Downloading = "The model is still downloading"
private let text1Damaged = "The model file was damaged and is downloading again"
private let text2 = "Indexing has not been started"
private let text4 = "Nothing is indexed yet"
private let text4Line = "Delete index in Settings to start over"

private let hintText = "Describe what you want, or type part of a name or text."
private let hintSamples = [
    "a dog on the beach",
    "the clause about pets in the lease",
    "where they talk about sleep",
]
private let noMatchesTitle = "No matches"
private let noMatchesHint = "Describe what is in the file, or type part of its exact name or text."

private let noRows = IndexCounts(done: 0, pending: [:], partial: [:])
private let allDone = IndexCounts(done: 4, pending: [:], partial: [:])
private let someDone = IndexCounts(done: 1, pending: ["photo": 2], partial: ["pdf": 1])  // 1 of 4
private let nonePending = IndexCounts(done: 0, pending: ["photo": 4], partial: [:])      // 0 of 4

private func inputs(
    model: ModelState = .whole,
    startPressed: Bool = true,
    indexDeleted: Bool = false,
    walkDoneAt: Date? = walkDone,
    counts: IndexCounts = allDone,
    vectorSourceOK: Bool = true,
    kindsOn: Set<String> = allKinds,
    typed: String = "dog on the beach",
    rankedCount: Int? = 3
) -> PanelInputs {
    PanelInputs(
        model: model, startPressed: startPressed, indexDeleted: indexDeleted,
        walkDoneAt: walkDoneAt, counts: counts, vectorSourceOK: vectorSourceOK,
        kindsOn: kindsOn, typed: typed, rankedCount: rankedCount)
}

// One line per state, built only from fields the panel shows, so a table row is a plain string.
private func describe(_ s: PanelState) -> String {
    if case .notReady(let v) = s { return "notReady | \(v.heading) | \(v.text) | \(v.note ?? "-")" }
    if case .indexing(let b) = s { return "indexing | \(b.percent) | \(b.title)" }
    if case .emptyHint = s { return "emptyHint" }
    if case .noMatches = s { return "noMatches" }
    if case .results = s { return "results" }
    return "other"
}

private func notReady(_ text: String, note: String? = nil) -> String {
    "notReady | \(heading) | \(text) | \(note ?? "-")"
}

private func indexing(_ percent: Int) -> String {
    "indexing | \(percent) | Still indexing (\(percent)%)"
}

private func missingKinds(_ s: PanelState) -> (text: String, kinds: Set<String>)? {
    guard case .indexing(let b) = s else { return nil }
    let lower = b.missing.lowercased()
    return (b.missing, Set(allKinds.filter { lower.contains($0) }))
}

@Suite("PanelStateTests")
struct PanelStateTests {

    // MARK: the not-ready function, spec order

    @Test func modelNotWholeShowsText1WhateverElseHolds() {
        // spec S1 Not ready 1 beats 2, 3 and 4: sweep every other input.
        let states: [(startPressed: Bool, indexDeleted: Bool)] = [(false, false), (false, true), (true, false)]
        let countsList = [noRows, allDone, someDone, nonePending]
        var bad: [String] = []
        for (model, expected) in [(ModelState.downloading, text1Downloading), (.damaged, text1Damaged)] {
            for s in states {
                for walk in [nil, walkDone] as [Date?] {
                    for counts in countsList {
                        for vectorOK in [true, false] {
                            let got = describe(PanelState.evaluate(inputs(
                                model: model, startPressed: s.startPressed, indexDeleted: s.indexDeleted,
                                walkDoneAt: walk, counts: counts, vectorSourceOK: vectorOK)))
                            if got != notReady(expected) {
                                bad.append("model \(model) start \(s) walk \(walk != nil) vectorOK \(vectorOK): \(got)")
                            }
                        }
                    }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    @Test func text1BeatsText2WhenStartWasNeverPressed() {
        let s = PanelState.evaluate(inputs(model: .downloading, startPressed: false, indexDeleted: false,
                                           walkDoneAt: nil, counts: noRows))
        #expect(describe(s) == notReady(text1Downloading))
    }

    @Test func damagedModelTextIsExactlyTheSpecs() {
        let s = PanelState.evaluate(inputs(model: .damaged, startPressed: false, walkDoneAt: nil, counts: noRows))
        #expect(describe(s) == notReady("The model file was damaged and is downloading again"))
    }

    @Test func neverStartedShowsText2() {
        let s = PanelState.evaluate(inputs(startPressed: false, indexDeleted: false, walkDoneAt: nil, counts: noRows))
        #expect(describe(s) == notReady(text2))
    }

    @Test func indexDeletedAndNotStartedSinceShowsText4() {
        let s = PanelState.evaluate(inputs(startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: noRows))
        #expect(describe(s) == notReady(text4))
    }

    @Test func startPressedBeforeAnyWalkFinishedShowsStillIndexingZeroPercent() {
        let s = PanelState.evaluate(inputs(startPressed: true, walkDoneAt: nil, counts: noRows))
        #expect(describe(s) == indexing(0))
    }

    @Test func stillIndexingZeroPercentBeatsNothingIsIndexedYet() {
        // zero rows and no walk finished: the spec says Still indexing wins once Start was pressed.
        let started = PanelState.evaluate(inputs(startPressed: true, indexDeleted: false, walkDoneAt: nil, counts: noRows))
        #expect(describe(started) == indexing(0))
        // the same zero rows after the walk finished is text 4
        let finished = PanelState.evaluate(inputs(startPressed: true, indexDeleted: false, walkDoneAt: walkDone, counts: noRows))
        #expect(describe(finished) == notReady(text4))
    }

    @Test func indexingFinishedWithNoFilesShowsText4WithoutTheDeleteLine() {
        let s = PanelState.evaluate(inputs(startPressed: true, walkDoneAt: walkDone, counts: noRows))
        guard case .notReady(let v) = s else {
            Issue.record("expected notReady, got \(describe(s))")
            return
        }
        #expect(v.text == text4)
        #expect(v.note == nil)
    }

    @Test func vectorSourceMismatchShowsText4WithTheDeleteLine() {
        let s = PanelState.evaluate(inputs(startPressed: true, walkDoneAt: walkDone, counts: allDone, vectorSourceOK: false))
        #expect(describe(s) == notReady(text4, note: text4Line))
    }

    @Test func vectorSourceMismatchBeatsTexts2AndStillIndexing() {
        let neverStarted = PanelState.evaluate(inputs(startPressed: false, indexDeleted: false,
                                                      walkDoneAt: nil, counts: noRows, vectorSourceOK: false))
        #expect(describe(neverStarted) == notReady(text4, note: text4Line))
        let mid = PanelState.evaluate(inputs(startPressed: true, walkDoneAt: walkDone,
                                             counts: someDone, vectorSourceOK: false))
        #expect(describe(mid) == notReady(text4, note: text4Line))
    }

    @Test func theHeadingIsNotReadyYetForTexts1And2And4() {
        let cases: [PanelInputs] = [
            inputs(model: .downloading),
            inputs(model: .damaged),
            inputs(startPressed: false, indexDeleted: false),
            inputs(startPressed: false, indexDeleted: true),
            inputs(walkDoneAt: walkDone, counts: noRows),
            inputs(vectorSourceOK: false),
        ]
        for c in cases {
            guard case .notReady(let v) = PanelState.evaluate(c) else {
                Issue.record("expected notReady")
                continue
            }
            #expect(v.heading == "Not ready yet")
            #expect(!v.text.isEmpty)
        }
    }

    @Test func stillIndexingIsNotTheNotReadyHeadingAndKeepsThePanelUsable() {
        // spec S1 Not ready 3: heading "Not ready yet" is for the first, second and fourth only.
        let s = PanelState.evaluate(inputs(counts: someDone))
        if case .notReady = s { Issue.record("Still indexing must not be a NotReadyView") }
        #expect(describe(s) == indexing(25))
    }

    @Test func allDoneAndTypedTextGivesResults() {
        let s = PanelState.evaluate(inputs(counts: allDone, typed: "dog on the beach", rankedCount: 3))
        #expect(describe(s) == "results")
    }

    // The whole table: every combination of the not-ready inputs, expected from the spec order
    // (model, then vector_source, then Start, then walk, then rows, then pending or partial).
    @Test func theNotReadyTableMatchesTheSpecOrderForEveryInput() {
        let models: [ModelState] = [.whole, .downloading, .damaged]
        let starts: [(Bool, Bool)] = [(false, false), (false, true), (true, false)]  // (startPressed, indexDeleted)
        let walks: [Date?] = [nil, walkDone]
        let countsList: [(IndexCounts, total: Int, pendingOrPartial: Int, percent: Int)] = [
            (noRows, 0, 0, 0), (allDone, 4, 0, 100), (someDone, 4, 3, 25), (nonePending, 4, 4, 0),
        ]
        var bad: [String] = []
        var rows = 0
        for model in models {
            for (started, deleted) in starts {
                for walk in walks {
                    for c in countsList {
                        // a walk that has not finished has written no rows yet
                        if walk == nil && c.total > 0 { continue }
                        for vectorOK in [true, false] {
                            rows += 1
                            let expected: String
                            if model == .downloading { expected = notReady(text1Downloading) }
                            else if model == .damaged { expected = notReady(text1Damaged) }
                            else if !vectorOK { expected = notReady(text4, note: text4Line) }
                            else if !started { expected = deleted ? notReady(text4) : notReady(text2) }
                            else if walk == nil { expected = indexing(0) }
                            else if c.total == 0 { expected = notReady(text4) }
                            else if c.pendingOrPartial > 0 { expected = indexing(c.percent) }
                            else { expected = "results" }
                            let got = describe(PanelState.evaluate(inputs(
                                model: model, startPressed: started, indexDeleted: deleted,
                                walkDoneAt: walk, counts: c.0, vectorSourceOK: vectorOK)))
                            if got != expected {
                                bad.append("\(model) start \(started) deleted \(deleted) walk \(walk != nil) rows \(c.total) pending \(c.pendingOrPartial) vectorOK \(vectorOK): got \(got), want \(expected)")
                            }
                        }
                    }
                }
            }
        }
        #expect(rows > 60)
        #expect(bad.isEmpty, "\(bad.count) of \(rows) wrong, first: \(bad.prefix(3))")
    }

    @Test func theSameInputsGiveTheSameState() {
        let a = PanelState.evaluate(inputs(counts: someDone))
        let b = PanelState.evaluate(inputs(counts: someDone))
        #expect(a == b)
    }

    // MARK: Still indexing (N%) and May be missing

    @Test func percentComesFromTheCounts() {
        let rows: [(IndexCounts, Int)] = [
            (IndexCounts(done: 0, pending: ["photo": 4], partial: [:]), 0),
            (IndexCounts(done: 1, pending: ["photo": 3], partial: [:]), 25),
            (IndexCounts(done: 2, pending: ["photo": 1], partial: ["pdf": 1]), 50),
            (IndexCounts(done: 3, pending: ["photo": 1], partial: [:]), 75),
            (IndexCounts(done: 1, pending: ["photo": 2], partial: [:]), 33),   // 1 of 3
        ]
        for (counts, percent) in rows {
            #expect(describe(PanelState.evaluate(inputs(counts: counts))) == indexing(percent),
                    "done \(counts) wanted \(percent)%")
        }
    }

    @Test func theBannerTitleReadsStillIndexingWithThePercentInBrackets() {
        guard case .indexing(let b) = PanelState.evaluate(inputs(counts: someDone)) else {
            Issue.record("expected the indexing state")
            return
        }
        #expect(b.title == "Still indexing (25%)")
        #expect(b.percent == 25)
    }

    @Test func untilTheFirstWalkFinishesEveryKindThatIsOnMayBeMissing() throws {
        let s = PanelState.evaluate(inputs(startPressed: true, walkDoneAt: nil, counts: noRows,
                                           kindsOn: ["photo", "pdf"]))
        let m = try #require(missingKinds(s))
        #expect(m.text.hasPrefix("May be missing: "))
        #expect(m.kinds == ["photo", "pdf"])

        let all = try #require(missingKinds(PanelState.evaluate(inputs(startPressed: true, walkDoneAt: nil,
                                                                       counts: noRows, kindsOn: allKinds))))
        #expect(all.kinds == allKinds)
    }

    @Test func afterTheWalkOnlyKindsWithPendingOrPartialRowsMayBeMissing() throws {
        let s = PanelState.evaluate(inputs(walkDoneAt: walkDone, counts: someDone, kindsOn: allKinds))
        let m = try #require(missingKinds(s))
        #expect(m.text.hasPrefix("May be missing: "))
        #expect(m.kinds == ["photo", "pdf"])   // photo is pending, pdf is partial; the rest are done or absent

        let onlyAudio = IndexCounts(done: 3, pending: ["audio": 2], partial: [:])
        let a = try #require(missingKinds(PanelState.evaluate(inputs(walkDoneAt: walkDone, counts: onlyAudio))))
        #expect(a.kinds == ["audio"])
    }

    // MARK: EmptyHint

    @Test func emptyAndSpacesOnlyShowTheEmptyHint() {
        for typed in ["", " ", "     "] {
            let s = PanelState.evaluate(inputs(typed: typed, rankedCount: nil))
            guard case .emptyHint(let h) = s else {
                Issue.record("typed \"\(typed)\": expected the empty hint, got \(describe(s))")
                continue
            }
            #expect(h.text == hintText)
            #expect(h.samples == hintSamples)
        }
    }

    @Test func spacesOnlyShowTheHintEvenWhenARankedListOfZeroIsIn() {
        // a quiet hint, never "No matches", for text that is only spaces
        let s = PanelState.evaluate(inputs(typed: "   ", rankedCount: 0))
        #expect(describe(s) == "emptyHint")
    }

    @Test func realTextIsNotTheEmptyHint() {
        for typed in ["dog", "a", " dog ", "code: dog"] {
            if case .emptyHint = PanelState.evaluate(inputs(typed: typed, rankedCount: 3)) {
                Issue.record("typed \"\(typed)\" must not show the empty hint")
            }
        }
    }

    @Test func notReadyReplacesTheEmptyHintAndNoMatches() {
        let empty = PanelState.evaluate(inputs(startPressed: false, indexDeleted: false, walkDoneAt: nil,
                                               counts: noRows, typed: "", rankedCount: nil))
        #expect(describe(empty) == notReady(text2))
        let none = PanelState.evaluate(inputs(model: .downloading, typed: "zzqx", rankedCount: 0))
        #expect(describe(none) == notReady(text1Downloading))
    }

    // MARK: NoMatches

    @Test func aRankedListThatIsInAndEmptyShowsNoMatches() {
        let s = PanelState.evaluate(inputs(typed: "zzqx", rankedCount: 0))
        guard case .noMatches(let n) = s else {
            Issue.record("expected No matches, got \(describe(s))")
            return
        }
        #expect(n.title == noMatchesTitle)
        #expect(n.hint == noMatchesHint)
    }

    @Test func noMatchesNeverShowsBeforeTheRankedListIsIn() {
        // design section 3: "No matches" appears only after the ranked list is in and empty
        let s = PanelState.evaluate(inputs(typed: "zzqx", rankedCount: nil))
        #expect(describe(s) != "noMatches")
    }

    @Test func aNonEmptyRankedListIsResultsNotNoMatches() {
        #expect(describe(PanelState.evaluate(inputs(typed: "dog", rankedCount: 1))) == "results")
        #expect(describe(PanelState.evaluate(inputs(typed: "dog", rankedCount: 40))) == "results")
    }

    // MARK: the 500-character cut

    @Test func textOfFiveHundredOrLessIsLeftAlone() {
        for n in [0, 1, 499, 500] {
            let t = String(repeating: "a", count: n)
            #expect(PanelState.cut(t) == t, "length \(n)")
        }
        let accents = String(repeating: "é", count: 500)   // 500 characters, 1000 bytes
        #expect(PanelState.cut(accents) == accents)
    }

    @Test func longerTextIsCutToItsFirstFiveHundredCharacters() {
        let base = (0..<1000).map { String($0 % 10) }.joined()   // 1,000 characters
        let cut501 = PanelState.cut(String(base.prefix(501)))
        #expect(cut501 == String(base.prefix(500)))
        let cut1000 = PanelState.cut(base)
        #expect(cut1000.count == 500)
        #expect(cut1000 == String(base.prefix(500)))
        let accents = String(repeating: "é", count: 600)
        #expect(PanelState.cut(accents) == String(repeating: "é", count: 500))
    }

    @Test func theCutKeepsSpacesAtTheStart() {
        let t = String(repeating: " ", count: 10) + String(repeating: "x", count: 600)
        let cut = PanelState.cut(t)
        #expect(cut.count == 500)
        #expect(cut.hasPrefix(String(repeating: " ", count: 10) + "x"))
    }

    // MARK: plan-2-t2 (R2): files that need permission
    //
    // Expected values written by hand from the plan-2-t2 entry and design section 3. A photo the process cannot open
    // has the status `needs_permission`; the panel must not hold "Still indexing" for it. The note is a quiet line,
    // never a state of its own.
    //
    // SHAPES THESE TESTS PIN (the entry gives the names; if a shape is wrong, ask for a test change):
    //   `IndexCounts.init(done:pending:partial:needsPermission:)` with `needsPermission: Int = 0`
    //   `static func PanelState.permissionNote(_ inputs: PanelInputs) -> String?`   nil when `inputs.counts.needsPermission`
    //       is 0, else "N files need permission to be read", or "1 file needs permission to be read" for one file
    //   percent and the pending-or-partial test count `done + pending + partial` only (never `needsPermission`)

    @Test func readyWithFilesThatNeedPermissionShowsResultsAndTheNote() {
        let two = IndexCounts(done: 10, pending: [:], partial: [:], needsPermission: 2)
        #expect(describe(PanelState.evaluate(inputs(counts: two))) == "results")
        #expect(PanelState.permissionNote(inputs(counts: two)) == "2 files need permission to be read")

        let one = IndexCounts(done: 10, pending: [:], partial: [:], needsPermission: 1)
        #expect(describe(PanelState.evaluate(inputs(counts: one))) == "results")
        #expect(PanelState.permissionNote(inputs(counts: one)) == "1 file needs permission to be read")

        let many = IndexCounts(done: 10, pending: [:], partial: [:], needsPermission: 12)
        #expect(PanelState.permissionNote(inputs(counts: many)) == "12 files need permission to be read")
    }

    @Test func filesThatNeedPermissionNeverHoldTheBannerAtStillIndexing() {
        // 10 done and 2 that need permission: nothing is pending or partial, so the panel is ready, not "Still indexing".
        let ready = PanelState.evaluate(inputs(counts: IndexCounts(done: 10, pending: [:], partial: [:], needsPermission: 2)))
        if case .indexing = ready { Issue.record("Still indexing for files only permission blocks: \(describe(ready))") }
        #expect(describe(ready) == "results")
    }

    @Test func stillIndexingKeepsItsPercentOverDonePlusPendingPlusPartialOnlyAndTheNoteToo() {
        // 8 done, 1 pending, 1 needs permission: 8 of 9 = 88 (a file that needs permission is not in the sum).
        let counts = IndexCounts(done: 8, pending: ["photo": 1], partial: [:], needsPermission: 1)
        #expect(describe(PanelState.evaluate(inputs(counts: counts))) == indexing(88))
        #expect(PanelState.permissionNote(inputs(counts: counts)) == "1 file needs permission to be read")

        // 3 done, 1 pending, 4 need permission: 3 of 4 = 75, not 3 of 8.
        let more = IndexCounts(done: 3, pending: ["photo": 1], partial: [:], needsPermission: 4)
        #expect(describe(PanelState.evaluate(inputs(counts: more))) == indexing(75))
        #expect(PanelState.permissionNote(inputs(counts: more)) == "4 files need permission to be read")

        // a partial file counts like a pending one: 2 done, 1 partial, 1 pending, 3 need permission: 2 of 4 = 50
        let partial = IndexCounts(done: 2, pending: ["photo": 1], partial: ["pdf": 1], needsPermission: 3)
        #expect(describe(PanelState.evaluate(inputs(counts: partial))) == indexing(50))
    }

    @Test func onlyFilesThatNeedPermissionShowsNothingIsIndexedYetAndTheNote() {
        let counts = IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 3)
        let state = PanelState.evaluate(inputs(counts: counts))
        guard case .notReady(let view) = state else {
            Issue.record("expected the not-ready screen (text 4), got \(describe(state))")
            return
        }
        #expect(view.heading == heading)
        #expect(view.text == text4)
        #expect(PanelState.permissionNote(inputs(counts: counts)) == "3 files need permission to be read")
    }

    @Test func noFilesThatNeedPermissionGivesNoNoteInAnyState() {
        let states: [IndexCounts] = [noRows, allDone, someDone, nonePending,
                                     IndexCounts(done: 4, pending: [:], partial: [:], needsPermission: 0)]
        for counts in states {
            #expect(PanelState.permissionNote(inputs(counts: counts)) == nil, "counts \(counts) must give no note")
        }
        // and no note while the model is not whole or before the walk, when there are no such files
        #expect(PanelState.permissionNote(inputs(model: .downloading, walkDoneAt: nil, counts: noRows)) == nil)
    }

    @Test func theNoteDoesNotChangeWhichStateIsShown() {
        // the same inputs with and without files that need permission give the same state, whatever the state is
        let bases: [(PanelInputs, PanelInputs)] = [
            (inputs(counts: allDone), inputs(counts: IndexCounts(done: 4, pending: [:], partial: [:], needsPermission: 2))),
            (inputs(counts: someDone), inputs(counts: IndexCounts(done: 1, pending: ["photo": 2], partial: ["pdf": 1], needsPermission: 5))),
            (inputs(startPressed: false, walkDoneAt: nil, counts: noRows),
             inputs(startPressed: false, walkDoneAt: nil, counts: IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 2))),
            (inputs(model: .downloading, counts: noRows),
             inputs(model: .downloading, counts: IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 2))),
        ]
        for (plain, withNeeds) in bases {
            #expect(describe(PanelState.evaluate(plain)) == describe(PanelState.evaluate(withNeeds)),
                    "files that need permission changed the state from \(describe(PanelState.evaluate(plain))) to \(describe(PanelState.evaluate(withNeeds)))")
        }
    }
}

// The panel's value (what the views draw) carries the same note to its quiet status line.
extension PanelStateTests {

    @MainActor
    @Test func theScreenCarriesTheNoteForReadyIndexingAndNothingIsIndexedYet() {
        let ready = PanelScreen.choose(inputs(counts: IndexCounts(done: 10, pending: [:], partial: [:], needsPermission: 2)),
                                       keywordRows: 0)
        #expect(ready.body == .rows, "ready body is \(ready.body)")
        #expect(ready.banner == nil)
        #expect(ready.permissionNote == "2 files need permission to be read", "ready note: \(String(describing: ready.permissionNote))")

        let busy = PanelScreen.choose(inputs(counts: IndexCounts(done: 8, pending: ["photo": 1], partial: [:], needsPermission: 1)),
                                      keywordRows: 0)
        #expect(busy.banner?.percent == 88, "banner percent \(String(describing: busy.banner?.percent))")
        #expect(busy.permissionNote == "1 file needs permission to be read", "indexing note: \(String(describing: busy.permissionNote))")

        let empty = PanelScreen.choose(inputs(counts: IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 3)),
                                       keywordRows: 0)
        if case .notReady(let view) = empty.body {
            #expect(view.text == text4)
        } else {
            Issue.record("expected the not-ready body (text 4), got \(empty.body)")
        }
        #expect(empty.permissionNote == "3 files need permission to be read", "text 4 note: \(String(describing: empty.permissionNote))")
    }

    @MainActor
    @Test func theScreenHasNoNoteWhenNoFileNeedsPermission() {
        for counts in [noRows, allDone, someDone] {
            let screen = PanelScreen.choose(inputs(counts: counts), keywordRows: 0)
            #expect(screen.permissionNote == nil, "counts \(counts) must give no note, got \(String(describing: screen.permissionNote))")
        }
    }

    // MARK: plan-2-t22 (S1.21 (b), S1.22 (iii) and (iv)): after Delete index, and a damaged model part way through indexing
    //
    // Expected values written by hand from spec S1 (the four texts) and design section 3 ("Not startPressed: text 4 if
    // indexDeleted, else text 2"; "Model not whole: text 1" first). The inputs are the ones Delete index leaves behind: the
    // model whole, `startPressed` false, `indexDeleted` true, the index file gone (no walk finished, no rows).

    @Test func afterDeleteIndexWithTheModelWholeEveryInputGivesText4NeverText2() {
        var bad: [String] = []
        var rows = 0
        for walk in [nil, walkDone] as [Date?] {
            for counts in [noRows, IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 2)] {
                for (typed, ranked) in [("", nil), ("dog on the beach", nil), ("dog", 0), ("dog", 3), ("code:", nil)] as [(String, Int?)] {
                    for kinds in [allKinds, Set(["photo"])] {
                        rows += 1
                        let state = PanelState.evaluate(inputs(startPressed: false, indexDeleted: true, walkDoneAt: walk, counts: counts,
                                                               kindsOn: kinds, typed: typed, rankedCount: ranked))
                        let got = describe(state)
                        if got != notReady(text4) { bad.append("walk \(walk != nil) counts \(counts) typed \"\(typed)\": \(got)") }
                        if got == notReady(text2) { bad.append("TEXT 2 after Delete index: walk \(walk != nil) typed \"\(typed)\"") }
                    }
                }
            }
        }
        #expect(rows == 40)
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    @Test func afterDeleteIndexTheOnlyDifferenceFromNeverStartedIsText4AgainstText2() {
        let never = PanelState.evaluate(inputs(startPressed: false, indexDeleted: false, walkDoneAt: nil, counts: noRows))
        let deleted = PanelState.evaluate(inputs(startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: noRows))
        #expect(describe(never) == notReady(text2))
        #expect(describe(deleted) == notReady(text4))
        #expect(describe(never) != describe(deleted))
        // and a Start after the Delete index clears it: Still indexing (0%) until the first walk finishes
        let restarted = PanelState.evaluate(inputs(startPressed: true, indexDeleted: false, walkDoneAt: nil, counts: noRows))
        #expect(describe(restarted) == indexing(0))
    }

    @MainActor
    @Test func theScreenAfterDeleteIndexIsTheNotReadyBodyWithText4AndNotText2() {
        let screen = PanelScreen.choose(inputs(startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: noRows, typed: "", rankedCount: nil),
                                        keywordRows: 0)
        guard case .notReady(let view) = screen.body else {
            Issue.record("expected the not-ready body (text 4), got \(screen.body)")
            return
        }
        #expect(view.heading == heading)
        #expect(view.text == text4)
        #expect(view.text != text2)
        #expect(view.note == nil)
    }

    @Test func aDamagedModelWithIndexingPausedPartWayGivesText1OverStillIndexingAndText3ReturnsWhenTheModelIsWholeAgain() {
        // Start was pressed, a walk finished, 1 of 4 rows done (someDone is 25 %): the person paused, then the model broke
        for damaged in [ModelState.damaged, .downloading] {
            let broken = PanelState.evaluate(inputs(model: damaged, startPressed: true, indexDeleted: false,
                                                    walkDoneAt: walkDone, counts: someDone))
            let expected = damaged == .damaged ? text1Damaged : text1Downloading
            #expect(describe(broken) == notReady(expected), "model \(damaged): \(describe(broken))")
            if case .indexing = broken { Issue.record("Still indexing showed over a \(damaged) model") }
        }

        // the same counts with the model whole again: text 3 is back, with its percent
        let whole = PanelState.evaluate(inputs(model: .whole, startPressed: true, indexDeleted: false,
                                               walkDoneAt: walkDone, counts: someDone))
        #expect(describe(whole) == indexing(25), "model whole again: \(describe(whole))")
    }

    @MainActor
    @Test func theScreenShowsText1ForTheDamagedModelAndTheStillIndexingBannerAgainWhenItIsWhole() {
        let broken = PanelScreen.choose(inputs(model: .damaged, startPressed: true, walkDoneAt: walkDone, counts: someDone), keywordRows: 0)
        guard case .notReady(let view) = broken.body else {
            Issue.record("expected the not-ready body (text 1), got \(broken.body)")
            return
        }
        #expect(view.text == text1Damaged)

        let whole = PanelScreen.choose(inputs(model: .whole, startPressed: true, walkDoneAt: walkDone, counts: someDone), keywordRows: 0)
        #expect(whole.banner?.percent == 25, "banner after the model is whole again: \(String(describing: whole.banner?.percent))")
        if case .notReady = whole.body { Issue.record("still the not-ready body after the model is whole again") }
    }

    @MainActor
    @Test func theNoteAndStillRankingAreTwoLinesNotOne() {
        let counts = IndexCounts(done: 10, pending: [:], partial: [:], needsPermission: 2)
        let screen = PanelScreen.choose(inputs(counts: counts), keywordRows: 0, stillRanking: true)
        #expect(screen.status == PanelScreen.stillRankingText, "status is \(String(describing: screen.status))")
        #expect(screen.permissionNote == "2 files need permission to be read",
                "Still ranking replaced the note: \(String(describing: screen.permissionNote))")
    }
}

// MARK: plan-2 fix round D, tester step, item D1 (R3-01): the panel's not-ready text while the model download has failed
//
// Written from the fix-round document ("the panel and the menu must not say only 'Downloading' while the download is
// failed: ... the panel's not-ready text (a pure value test each: ... the panel text names the failure and tells the person to
// open Sesame Settings or the setup window to Retry). The same holds after Delete index when the model is missing") and spec S1
// "Not ready". No product source was read.
//
// SHAPE D1 pins here (new): `ModelState.failed` (see the round D block of MenuStateTests). `PanelState.evaluate` gives
// `.notReady(view)` whenever `inputs.model == .failed`, before every other not-ready rule (the same place as text 1): the
// heading is "Not ready yet", `view.text` is ONE fixed text for every other input, and it
//   - names the failure: it holds the word "failed" (any case),
//   - tells the person how to go on: it holds "Retry" (any case) and names a place to do it, "Sesame Settings" or "setup window"
//     (RE-PINNED IN ROUND E, E1: the place is the Sesame menu; see `pfFailedTextOfRoundE` below),
//   - is neither the text of a model still downloading nor the damaged text.
// The exact wording is the fixer's pick; the three properties above are the document's. `PanelScreen.choose` carries it as
// the not-ready body.

// ROUND E (E1, R4-01) re-pin of the round D properties above: the place to Retry is no longer "Sesame Settings" or "the setup
// window" (the person can close the window) but the Sesame menu, where the failed menu's first action is "Retry model download".
// The exact text of the ruling is pinned: "The model download failed. Choose Retry model download in the Sesame menu."

private let pfFailedTextOfRoundE = "The model download failed. Choose Retry model download in the Sesame menu."

/// The properties of the ruling: names the failure, says Retry, names the Sesame menu, and no longer points to Settings or the setup window.
private func pfIsFailureText(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("failed") && lower.contains("retry") && text.contains("Sesame menu")
        && !text.contains("Sesame Settings") && !lower.contains("setup window")
}

private func pfFailedTexts(_ inputs: PanelInputs) -> String? {
    if case .notReady(let view) = PanelState.evaluate(inputs) { return view.text }
    return nil
}

extension PanelStateTests {

    @Test func aFailedDownloadShowsOneNotReadyTextWhateverElseHolds() {
        var texts = Set<String>()
        var bad: [String] = []
        let states: [(startPressed: Bool, indexDeleted: Bool)] = [(false, false), (false, true), (true, false)]
        for s in states {
            for walk in [nil, walkDone] as [Date?] {
                for counts in [noRows, allDone, someDone, nonePending] {
                    for vectorOK in [true, false] {
                        let state = PanelState.evaluate(inputs(model: .failed, startPressed: s.startPressed, indexDeleted: s.indexDeleted,
                                                               walkDoneAt: walk, counts: counts, vectorSourceOK: vectorOK))
                        guard case .notReady(let view) = state else {
                            bad.append("start \(s) walk \(walk != nil) vectorOK \(vectorOK): \(describe(state))")
                            continue
                        }
                        if view.heading != heading { bad.append("heading \(view.heading)") }
                        texts.insert(view.text)
                    }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
        #expect(texts.count == 1, "the failed text is not one text for every input: \(texts)")
        #expect(texts.allSatisfy(pfIsFailureText), "the not-ready text of a failed download does not name the failure and the Retry: \(texts)")
    }

    // ROUND E (E1) re-pin: was `...RetryFromSettingsOrTheSetupWindow`; the place to Retry is now the Sesame menu, with the exact text.
    @Test func theFailedTextNamesTheFailureAndTellsThePersonToChooseRetryModelDownloadInTheSesameMenu() throws {
        let text = try #require(pfFailedTexts(inputs(model: .failed)), "a failed download is not a not-ready state")
        let lower = text.lowercased()
        #expect(text == pfFailedTextOfRoundE, "the failed text is \(text.debugDescription)")
        #expect(lower.contains("failed"), "the text does not name the failure: \(text)")
        #expect(lower.contains("retry"), "the text does not say to Retry: \(text)")
        #expect(text.contains("Sesame menu"), "the text does not name the Sesame menu: \(text)")
        #expect(text.contains("Retry model download"), "the text does not name the menu item: \(text)")
        #expect(!text.contains("Sesame Settings") && !lower.contains("setup window"), "the text still points to Settings or the setup window: \(text)")
        #expect(text != text1Downloading && text != text1Damaged, "the failed text is the downloading or the damaged text: \(text)")
        #expect(!text.contains(text1Downloading), "the failed text still says the model is downloading: \(text)")
    }

    @Test func afterDeleteIndexWithTheModelMissingAndTheDownloadFailedTheTextIsTheFailureNotText4() throws {
        let failed = try #require(pfFailedTexts(inputs(model: .failed)))
        let afterDelete = try #require(pfFailedTexts(inputs(model: .failed, startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: noRows)),
                                       "after Delete index with a failed download the panel is not the not-ready screen")
        #expect(afterDelete == failed, "after Delete index the text is \(afterDelete)")
        #expect(pfIsFailureText(afterDelete), "after Delete index the text does not name the failure and the Retry: \(afterDelete)")
        #expect(afterDelete != text4, "text 4 hides the failed download after Delete index")
        let neverStarted = try #require(pfFailedTexts(inputs(model: .failed, startPressed: false, indexDeleted: false, walkDoneAt: nil, counts: noRows)))
        #expect(neverStarted == failed, "Start never pressed: \(neverStarted)")
    }

    @Test func downloadingAndDamagedKeepTheirTextsAndAWholeModelIsNotTheFailedText() throws {
        #expect(describe(PanelState.evaluate(inputs(model: .downloading))) == notReady(text1Downloading))
        #expect(describe(PanelState.evaluate(inputs(model: .damaged))) == notReady(text1Damaged))
        let failed = try #require(pfFailedTexts(inputs(model: .failed)))
        #expect(pfFailedTexts(inputs(model: .whole, counts: someDone)) != failed)
        #expect(describe(PanelState.evaluate(inputs(model: .whole, counts: someDone))) == indexing(25))
    }

    @MainActor
    @Test func theScreenOfAFailedDownloadIsTheNotReadyBodyWithTheFailedTextNeverTheIndexingBanner() throws {
        let failed = try #require(pfFailedTexts(inputs(model: .failed)))
        for (name, input) in [
            ("indexing otherwise", inputs(model: .failed, startPressed: true, walkDoneAt: walkDone, counts: someDone)),
            ("ready otherwise, text typed", inputs(model: .failed, counts: allDone, typed: "dog", rankedCount: 3)),
            ("after Delete index", inputs(model: .failed, startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: noRows, typed: "", rankedCount: nil)),
        ] {
            let screen = PanelScreen.choose(input, keywordRows: 0)
            guard case .notReady(let view) = screen.body else {
                Issue.record("\(name): expected the not-ready body, got \(screen.body)")
                continue
            }
            #expect(view.text == failed, "\(name): body text \(view.text)")
            #expect(pfIsFailureText(view.text), "\(name): the body text does not name the failure and the Retry: \(view.text)")
            #expect(view.heading == heading, "\(name): heading \(view.heading)")
            #expect(screen.banner == nil, "\(name): an indexing banner shows over a failed download: \(String(describing: screen.banner))")
        }
    }
}

// MARK: plan-2-t36 (F14): a failed embed shows "Could not search just now", never "Searching" for good
//
// Tester step, written from the t36 entry and design section 3 ("Searching": a quiet "Searching" line, "No matches"
// only after the ranked list is in) only; no product source read. The expected texts are the entry's own.
//
// SHAPES THESE TESTS PIN (the entry gives the names; if a shape is wrong, ask for a test change):
//   `PanelScreen.choose(_:keywordRows:stillRanking:searchFailed:)` with `searchFailed: Bool = false` (every existing call
//       stays as it is). `searchFailed` is what the panel passes while the newest ticket's embed has failed and no
//       newer ticket has been typed: the panel owns that flag, `choose` stays a pure function of its arguments.
//   `PanelScreen.Body.searchFailed`, a case with no payload (compared with `==`), and the two fixed texts as
//       `static let PanelScreen.searchFailedText = "Could not search just now"` and
//       `static let PanelScreen.searchFailedHint = "Try typing again in a moment."` (the entry's wording; the hint is its pick).
//   With `searchFailed: true`, typed text that is not empty and no ranked list in (`rankedCount` nil): body `.searchFailed`
//       when no keyword rows are shown; body `.rows` when keyword rows are shown (tier-1 rows already shown stay). The
//       indexing banner, if any, stays above the body. `status` is not "Searching" in any case.
//   Not pinned, on purpose: what `choose` does with `searchFailed: true` when a ranked list is in, when the box is empty,
//       or when the not-ready screen applies; where the failure is drawn when keyword rows stay; the look of the view.

extension PanelStateTests {

    @MainActor
    @Test func theSearchFailedTextsAreTheEntrysOwn() {
        #expect(PanelScreen.searchFailedText == "Could not search just now")
        #expect(PanelScreen.searchFailedHint == "Try typing again in a moment.")
    }

    @MainActor
    @Test func aFailedSearchWithNoKeywordRowsIsTheSearchFailedBodyNotSearching() {
        let screen = PanelScreen.choose(inputs(typed: "a quiet harbour at dawn", rankedCount: nil),
                                        keywordRows: 0, searchFailed: true)
        #expect(screen.body == .searchFailed, "body is \(screen.body)")
        #expect(screen.body != .searching, "the quiet Searching line is still the body")
        #expect(screen.status != PanelScreen.searchingText, "status says Searching: \(String(describing: screen.status))")
        #expect(screen.banner == nil)
    }

    @MainActor
    @Test func theSameInputsWithoutTheFailureStillShowTheSearchingLine() {
        let typed = "a quiet harbour at dawn"
        let waiting = PanelScreen.choose(inputs(typed: typed, rankedCount: nil), keywordRows: 0, searchFailed: false)
        #expect(waiting.body == .searching, "body is \(waiting.body)")
        // leaving the argument out is the same as false: every earlier call keeps its meaning
        #expect(PanelScreen.choose(inputs(typed: typed, rankedCount: nil), keywordRows: 0) == waiting)
    }

    @MainActor
    @Test func theFailureClearsWhenThePanelStopsPassingIt() {
        // the panel passes the flag only while the failed ticket is the newest: a new ticket brings the Searching line back,
        // and a ranked list that comes in later is shown as it is
        let typed = "a quiet harbour at dawn"
        let failed = PanelScreen.choose(inputs(typed: typed, rankedCount: nil), keywordRows: 0, searchFailed: true)
        let typedOn = PanelScreen.choose(inputs(typed: typed + "s", rankedCount: nil), keywordRows: 0, searchFailed: false)
        #expect(failed.body == .searchFailed)
        #expect(typedOn.body == .searching, "after the next keystroke the body is \(typedOn.body)")
        let ranked = PanelScreen.choose(inputs(typed: typed + "s", rankedCount: 3), keywordRows: 0, searchFailed: false)
        #expect(ranked.body == .rows, "body is \(ranked.body)")
        let none = PanelScreen.choose(inputs(typed: typed + "s", rankedCount: 0), keywordRows: 0, searchFailed: false)
        if case .noMatches = none.body {} else { Issue.record("a ranked list of none is No matches, got \(none.body)") }
    }

    @MainActor
    @Test func tierOneKeywordRowsAlreadyShownStayWhenTheEmbedFails() {
        for keywordRows in [1, 2, 5] {
            let screen = PanelScreen.choose(inputs(typed: "pier lights", rankedCount: nil),
                                            keywordRows: keywordRows, searchFailed: true)
            #expect(screen.body == .rows, "keyword rows \(keywordRows): body is \(screen.body)")
            #expect(screen.status != PanelScreen.searchingText)
        }
    }

    @MainActor
    @Test func theFailureShowsUnderTheIndexingBannerAndThePanelStaysUsable() {
        let screen = PanelScreen.choose(inputs(counts: someDone, typed: "a quiet harbour at dawn", rankedCount: nil),
                                        keywordRows: 0, searchFailed: true)
        #expect(screen.banner?.percent == 25, "banner percent \(String(describing: screen.banner?.percent))")
        #expect(screen.body == .searchFailed, "body is \(screen.body)")
    }
}

// Through the real Panel (PanelRig), as a person uses it. The rig's helper file does not exist, so the encode helper can
// never start and every embed fails; nothing is launched. Expected values are the entry's texts and the design's hint.
// Each wait is 30 s because a failure that only comes after the embedder's own 20 s timeout is still a failure shown, and
// "Searching" for good is the defect (F14). `Probe.sink` records the pipeline's `keyword` and `ranked` events.

private final class PFEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ event: String, _ ticket: Int) { lock.lock(); list.append("\(event):\(ticket)"); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return list }
    func count(_ name: String) -> Int { events.filter { $0.hasPrefix(name + ":") }.count }
}

extension ModelDownloadTests {
    @Suite("PanelStateTestsSearchFailed", .serialized)
    struct PanelStateTestsSearchFailed {

        private static let failedText = "Could not search just now"
        private static let failedHint = "Try typing again in a moment."
        private static let emptyHintText = "Describe what you want, or type part of a name or text."
        private static let description = "a quiet harbour at dawn"
        private static let photos = [
            PRPhoto(name: "a.jpg", words: "a dog on the beach"),
            PRPhoto(name: "b.jpg", words: "a dog on the lawn"),
        ]

        @MainActor
        private static func shown(_ panel: Panel) -> [String] { prShownTexts(panel.contentView!) }

        @MainActor
        private static func failureShown(_ panel: Panel) -> Bool { shown(panel).contains(failedText) }

        @MainActor
        private static func pressEnter(_ panel: Panel) {
            panel.sendEvent(prKey("\r", in: panel, keyCode: 36))
        }

        @MainActor
        @Test func aFailedEmbedReplacesSearchingWithCouldNotSearchJustNowAndItsHint() async throws {
            try await prWithPanel(photos: Self.photos) { panel in
                await prType(Self.description, into: panel, pauseMilliseconds: 20)
                let failed = await spEventually(timeout: 30) { Self.failureShown(panel) }
                let shown = Self.shown(panel)
                let text = panel.queryBox.text
                #expect(failed, "the panel never said \"\(Self.failedText)\"; shown: \(shown)")
                #expect(shown.contains(Self.failedHint), "the hint is missing; shown: \(shown)")
                #expect(!shown.contains { $0.contains("Searching") }, "\"Searching\" is still shown after the failure; shown: \(shown)")
                #expect(!shown.contains("No matches"), "a failed search is not No matches; shown: \(shown)")
                #expect(text == Self.description, "the box holds \"\(text)\"")
            }
        }

        @MainActor
        @Test func escClearsTheTextAndTheFailureGoesAndTheHintIsBack() async throws {
            try await prWithPanel(photos: Self.photos) { panel in
                await prType(Self.description, into: panel, pauseMilliseconds: 20)
                let failed = await spEventually(timeout: 30) { Self.failureShown(panel) }
                let before = Self.shown(panel)
                #expect(failed, "the panel never said \"\(Self.failedText)\"; shown: \(before)")

                panel.pressEscape()
                await spWait(0.3)
                let shown = Self.shown(panel)
                let text = panel.queryBox.text
                #expect(text == "", "the first Esc left \"\(text)\"")
                #expect(!shown.contains(Self.failedText), "the failure stayed after the box was emptied; shown: \(shown)")
                #expect(shown.contains(Self.emptyHintText), "the empty hint is not back; shown: \(shown)")
            }
        }

        @MainActor
        @Test func enterAfterTheFailureDoesNothingAndNeverShowsStillRanking() async throws {
            try await prWithPanel(photos: Self.photos) { panel in
                await prType(Self.description, into: panel, pauseMilliseconds: 20)
                let failed = await spEventually(timeout: 30) { Self.failureShown(panel) }
                let before = Self.shown(panel)
                #expect(failed, "the panel never said \"\(Self.failedText)\"; shown: \(before)")

                // Enter with no results does nothing at once; it does not wait 2 s for a list that cannot come
                Self.pressEnter(panel)
                await spWait(2.8)
                let shown = Self.shown(panel)
                let text = panel.queryBox.text
                #expect(!shown.contains { $0.contains("Still ranking") },
                        "Enter waited for a list that cannot come and the panel says Still ranking; shown: \(shown)")
                #expect(shown.contains(Self.failedText), "the failure went away after Enter; shown: \(shown)")
                #expect(text == Self.description, "Enter changed the box to \"\(text)\"")
            }
        }

        @MainActor
        @Test func aKeystrokeAfterTheFailureSearchesAgainAndTheBoxStaysUsable() async throws {
            let events = PFEvents()
            let previous = Probe.sink
            Probe.sink = { @Sendable event, ticket in events.add(event, ticket) }
            defer { Probe.sink = previous }
            try await prWithPanel(photos: Self.photos) { panel in
                await prType(Self.description, into: panel, pauseMilliseconds: 20)
                let failed = await spEventually(timeout: 30) { Self.failureShown(panel) }
                let first = Self.shown(panel)
                #expect(failed, "the panel never said \"\(Self.failedText)\"; shown: \(first)")

                // the next keystroke is a new ticket: the pipeline runs again for it (its keyword list is produced) and
                // it fails again, shown the same way
                let before = events.count("keyword")
                await prType("s", into: panel, pauseMilliseconds: 20)
                let text = panel.queryBox.text
                #expect(text == Self.description + "s", "the box holds \"\(text)\"")
                let searched = await spEventually { events.count("keyword") > before }
                #expect(searched, "the keystroke after the failure started no new search; events: \(events.events)")
                let again = await spEventually(timeout: 30) { Self.failureShown(panel) }
                let second = Self.shown(panel)
                #expect(again, "the second failure was not shown; shown: \(second)")
                #expect(events.count("ranked") == 0, "a ranked list was produced although every embed failed: \(events.events)")
            }
        }

        // A guard, green before the work as well: keyword rows already shown are not taken away by the failure.
        @MainActor
        @Test func tierOneKeywordRowsStayOnScreenWhenTheEmbedFails() async throws {
            try await prWithPanel(photos: Self.photos) { panel in
                await prType("a dog on the beach", into: panel, pauseMilliseconds: 40)
                let rows = await spEventually { prShownTexts(panel.contentView!).contains("/photos/a.jpg") }
                let first = Self.shown(panel)
                #expect(rows, "the keyword rows never showed; shown: \(first)")
                await spWait(3)
                let shown = Self.shown(panel)
                #expect(shown.contains("/photos/a.jpg"), "the failure took the keyword rows away; shown: \(shown)")
                #expect(!shown.contains { $0.contains("Searching") }, "\"Searching\" is shown over keyword rows; shown: \(shown)")
            }
        }
    }
}

private let codeTexts = ["code: retry a failed call", "code:", "code: ", "code: x", "  CODE:x", "Code:  ", "code:code: a"]
private let threeDone = IndexCounts(done: 3, pending: [:], partial: [:])

private func wiringWord(_ body: PanelScreen.Body) -> String {
    String(String(describing: body).prefix { $0 != "(" })
}

extension PanelStateTests {

    @Test func aCodeTextIsPlainTextSoTheRankedListDecidesTheState() {
        var bad: [String] = []
        for typed in codeTexts {
            for (ranked, want) in [(nil, "results"), (1, "results"), (3, "results"), (40, "results"), (0, "noMatches")] as [(Int?, String)] {
                let got = describe(PanelState.evaluate(inputs(counts: threeDone, typed: typed, rankedCount: ranked)))
                if got != want { bad.append("\(typed.debugDescription) ranked \(String(describing: ranked)): got \(got), want \(want)") }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    @Test func aCodeTextWithNothingRankedShowsNoMatchesWithItsTitleAndOneLineHint() {
        for typed in ["code: retry a failed call", "code:"] {
            guard case .noMatches(let n) = PanelState.evaluate(inputs(counts: threeDone, typed: typed, rankedCount: 0)) else {
                Issue.record("\(typed.debugDescription): expected No matches")
                continue
            }
            #expect(n.title == "No matches")
            #expect(n.hint == "Describe what is in the file, or type part of its exact name or text.")
        }
    }

    @Test func onlyAnEmptyOrSpacesOnlyBoxShowsTheHintWithTheThreeSamples() {
        for typed in ["", " ", "     "] {
            guard case .emptyHint(let h) = PanelState.evaluate(inputs(counts: threeDone, typed: typed, rankedCount: nil)) else {
                Issue.record("\(typed.debugDescription): expected the empty hint")
                continue
            }
            #expect(h.text == "Describe what you want, or type part of a name or text.")
            #expect(h.samples == ["a dog on the beach", "the clause about pets in the lease", "where they talk about sleep"])
        }
    }

    @Test func noSampleOfTheHintStartsWithCode() {
        guard case .emptyHint(let h) = PanelState.evaluate(inputs(counts: threeDone, typed: "", rankedCount: nil)) else {
            Issue.record("expected the empty hint")
            return
        }
        #expect(h.samples.count == 3)
        #expect(!h.samples.contains { $0.lowercased().contains("code") }, "samples: \(h.samples)")
    }

    @Test func aPendingOrPartialCodeRowAloneNeverShowsStillIndexing() {
        let rows = [
            IndexCounts(done: 3, pending: ["code": 2], partial: [:]),
            IndexCounts(done: 3, pending: [:], partial: ["code": 1]),
            IndexCounts(done: 3, pending: ["code": 1], partial: ["code": 4]),
        ]
        for counts in rows {
            let state = PanelState.evaluate(inputs(counts: counts, typed: "dog on the beach", rankedCount: 3))
            #expect(describe(state) == "results", "counts \(counts): \(describe(state))")
            #expect(PanelScreen.choose(inputs(counts: counts, typed: "dog on the beach", rankedCount: 3), keywordRows: 0).banner == nil,
                    "counts \(counts) put a banner up")
        }
    }

    @Test func theMayBeMissingLineNeverNamesCode() throws {
        let withCode = allKinds.union(["code"])
        let before = PanelState.evaluate(inputs(startPressed: true, walkDoneAt: nil, counts: noRows, kindsOn: withCode))
        let beforeMissing = try #require(missingKinds(before))
        #expect(beforeMissing.kinds == allKinds, "missing text: \(beforeMissing.text)")
        #expect(!beforeMissing.text.lowercased().contains("code"), "missing text: \(beforeMissing.text)")

        let counts = IndexCounts(done: 1, pending: ["photo": 1, "code": 3], partial: [:])
        let after = PanelState.evaluate(inputs(walkDoneAt: walkDone, counts: counts, kindsOn: withCode))
        let afterMissing = try #require(missingKinds(after))
        #expect(afterMissing.kinds == ["photo"], "missing text: \(afterMissing.text)")
        #expect(!afterMissing.text.lowercased().contains("code"), "missing text: \(afterMissing.text)")
    }

    @Test func aCodeTextKeepsTheNotReadyTextsAndTheBannerAboveIt() {
        var bad: [String] = []
        for typed in ["code: x", "  CODE:x", "code:"] {
            let cases: [(String, PanelInputs, String)] = [
                ("model downloading", inputs(model: .downloading, typed: typed, rankedCount: nil), notReady(text1Downloading)),
                ("model damaged", inputs(model: .damaged, typed: typed, rankedCount: nil), notReady(text1Damaged)),
                ("not started", inputs(startPressed: false, walkDoneAt: nil, counts: noRows, typed: typed, rankedCount: nil), notReady(text2)),
                ("index deleted", inputs(startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: noRows, typed: typed, rankedCount: nil), notReady(text4)),
                ("vector source", inputs(vectorSourceOK: false, typed: typed, rankedCount: nil), notReady(text4, note: text4Line)),
                ("nothing indexed", inputs(counts: noRows, typed: typed, rankedCount: nil), notReady(text4)),
                ("still indexing 25", inputs(counts: someDone, typed: typed, rankedCount: nil), indexing(25)),
                ("still indexing 0", inputs(startPressed: true, walkDoneAt: nil, counts: noRows, typed: typed, rankedCount: nil), indexing(0)),
            ]
            for (name, input, expected) in cases {
                let got = describe(PanelState.evaluate(input))
                if got != expected { bad.append("\(name), typed \(typed.debugDescription): got \(got), want \(expected)") }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    @MainActor
    @Test func theScreenOfACodeTextIsTheScreenOfAnyPlainText() {
        let noMatches = PanelScreen.choose(inputs(counts: threeDone, typed: "code: x", rankedCount: 0), keywordRows: 0)
        guard case .noMatches(let none) = noMatches.body else {
            Issue.record("a ranked list of none for `code: x` chose \(wiringWord(noMatches.body))")
            return
        }
        #expect(none.title == "No matches")
        #expect(none.hint == "Describe what is in the file, or type part of its exact name or text.")
        #expect(wiringWord(PanelScreen.choose(inputs(counts: threeDone, typed: "code: x", rankedCount: 3), keywordRows: 0).body) == "rows")
        #expect(wiringWord(PanelScreen.choose(inputs(counts: threeDone, typed: "code: x", rankedCount: nil), keywordRows: 2).body) == "rows")
        #expect(wiringWord(PanelScreen.choose(inputs(counts: threeDone, typed: "code: x", rankedCount: nil), keywordRows: 0).body) == "searching")
        #expect(wiringWord(PanelScreen.choose(inputs(counts: threeDone, typed: "code: x", rankedCount: nil), keywordRows: 0, searchFailed: true).body) == "searchFailed")
    }

    @MainActor
    @Test func aBareCodeBoxChoosesSearchingNotTheEmptyHint() {
        for typed in ["code:", "code: ", "code:   "] {
            let screen = PanelScreen.choose(inputs(counts: threeDone, typed: typed, rankedCount: nil), keywordRows: 0)
            #expect(wiringWord(screen.body) == "searching", "typed \(typed.debugDescription): \(wiringWord(screen.body))")
        }
        let empty = PanelScreen.choose(inputs(counts: threeDone, typed: "", rankedCount: nil), keywordRows: 0)
        guard case .emptyHint(let hint) = empty.body else {
            Issue.record("an empty box chose \(wiringWord(empty.body))")
            return
        }
        #expect(hint.samples == ["a dog on the beach", "the clause about pets in the lease", "where they talk about sleep"])
    }
}

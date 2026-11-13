import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t27, tester step: the menu bar's state and its text as pure values (S7.1, S7.16, S1.6, S1.30). Written from the
// t27 entry (its Tests paragraph), design section 3 ("The menu bar takes the same inputs plus the pause set: Downloading
// while the model is not whole, Paused if a pause reason is set, Indexing while startPressed and (no walk finished or
// rows pending or partial), else Ready"), design section 6, spec S7, mockup F2 (the wording of the labels) and the
// sealed tests of the plan-1 `PanelState` and the t15 `Estimator` (the only places the existing names are read). No
// product source was read. Every expected value below is written by hand from those texts; none is computed by the
// code under test.
//
// THE SHAPE THESE TESTS PIN (new API; today `MenuState` does not exist, so this file does not compile until it does).
// The entry names `MenuState.evaluate(MenuInputs)`, `MenuModel` and the texts, not the signatures; these are this
// file's picks, taken from the plan-1 `PanelInputs`/`PanelState` pair. If a shape is wrong, ask for a test change.
//
//   enum PauseReason: Hashable { case you, cpu, lowPower, battery }      // the four reasons of design section 6; t29's
//                                                                        // PauseSet holds a Set of these
//   struct MenuInputs { init(model: ModelState, startPressed: Bool, indexDeleted: Bool, walkDoneAt: Date?,
//                            counts: IndexCounts, pauseReasons: Set<PauseReason>) }   // memberwise, in this order
//   enum MenuState: Equatable { case downloading, paused, indexing, ready }           // no payloads
//   MenuState.evaluate(_ inputs: MenuInputs) -> MenuState                              // pure
//
//   struct MenuModel { init(inputs: MenuInputs, downloadPercent: Int, doneByKind: [String: Int],
//                           speeds: [String: Double], kindsOn: [String: Bool]) }
//     downloadPercent  0...100, only read while the model is not whole
//     doneByKind       files with status `done`, per kind ("photo", "pdf", ...), as the cached snapshot holds them
//     speeds, kindsOn  what `Estimator.left(remaining:speeds:kindsOn:)` takes (settings.json's `speeds` and `kindsOn`)
//   MenuModel reads (all `let` or computed, no call needed):
//     state                MenuState      = MenuState.evaluate(inputs)
//     statusItemLabel      String         the status item's accessibility label and title: never empty
//     statusLine           String         the menu's first line, never empty
//     detailLine           String?        the second line while Indexing: "<N> files left · <Estimator.left text> left"
//     permissionLine       String?        "N files need permission to be read" ("1 file needs ..."); nil when none
//     firstActionTitle     String         "Pause indexing" or "Resume indexing"
//     firstActionEnabled   Bool
//     resumeAnywayTitle    String?        "Resume anyway, on battery" when `battery` is among the reasons, else nil
//     doneCounts           [String: Int]  per kind from the `done` rows only (pending, partial and the rest never added)
//
//   PanelSnapshot (plan 1, t3) gains `doneByKind: [String: Int]` and `lastIndexedPath: String?`, filled by
//   `PanelSnapshot.read(reader:model:)` from `IndexReader.statusCounts()` and `IndexReader.lastIndexedPath()` ("StatusCache's
//   snapshot gains the per-kind done counts and that path"). StatusCacheTests is not in this step's touch list, so the
//   cache's own wiring is not pinned here; the function a background source calls is.
//
// Not pinned (the entry does not say): the status line of Downloading and of Ready after Start, the status line when
// several reasons hold, the text when nothing was indexed yet, the order and layout of the per-kind rows.

private let msWalk = Date(timeIntervalSince1970: 1_700_000_000)

private func msCounts(done: Int = 0, pending: [String: Int] = [:], partial: [String: Int] = [:], needs: Int = 0) -> IndexCounts {
    IndexCounts(done: done, pending: pending, partial: partial, needsPermission: needs)
}

private let msNone = msCounts()
private let msDone4 = msCounts(done: 4)
private let msPending = msCounts(done: 1, pending: ["photo": 2])
private let msPartial = msCounts(done: 1, partial: ["pdf": 2])
private let msPermOnly = msCounts(done: 3, needs: 2)
private let msPermAndPending = msCounts(done: 3, pending: ["photo": 1], needs: 2)

private let msAllOn: [String: Bool] = ["photo": true, "pdf": true, "doc": true, "audio": true, "video": true, "code": true]

private func msInputs(model: ModelState = .whole, startPressed: Bool = true, indexDeleted: Bool = false, walkDone: Bool = true,
                      counts: IndexCounts, reasons: Set<PauseReason> = []) -> MenuInputs {
    MenuInputs(model: model, startPressed: startPressed, indexDeleted: indexDeleted, walkDoneAt: walkDone ? msWalk : nil,
               counts: counts, pauseReasons: reasons)
}

private func msModel(_ inputs: MenuInputs, downloadPercent: Int = 0, doneByKind: [String: Int] = [:],
                     speeds: [String: Double] = ["photo": 0.16],
                     kindsOn: [String: Bool] = msAllOn) -> MenuModel {
    MenuModel(inputs: inputs, downloadPercent: downloadPercent, doneByKind: doneByKind,
              speeds: speeds, kindsOn: kindsOn)
}

private func msName(_ state: MenuState) -> String { String(describing: state) }

private struct MSRow {
    let name: String
    let inputs: MenuInputs
    let expected: MenuState
}

// The hand-written table, in the order of design section 3. Each row says what is different from the plain Ready row.
private let msRows: [MSRow] = [
    // Ready: Start not pressed (the walk and the rows do not matter), or everything read
    MSRow(name: "not started, nothing yet", inputs: msInputs(startPressed: false, walkDone: false, counts: msNone), expected: .ready),
    MSRow(name: "not started, index deleted", inputs: msInputs(startPressed: false, indexDeleted: true, walkDone: false, counts: msNone), expected: .ready),
    MSRow(name: "not started, rows left over from before", inputs: msInputs(startPressed: false, counts: msPending), expected: .ready),
    MSRow(name: "not started, a walk finished, all done", inputs: msInputs(startPressed: false, counts: msDone4), expected: .ready),
    MSRow(name: "started, walk finished, all done", inputs: msInputs(counts: msDone4), expected: .ready),
    MSRow(name: "started, walk finished, zero rows", inputs: msInputs(counts: msNone), expected: .ready),
    MSRow(name: "started after a delete, walk finished, all done", inputs: msInputs(indexDeleted: true, counts: msDone4), expected: .ready),
    MSRow(name: "needs_permission rows alone", inputs: msInputs(counts: msPermOnly), expected: .ready),
    // Indexing: Start pressed and (no walk finished, or pending or partial rows)
    MSRow(name: "started, no walk finished, zero rows", inputs: msInputs(walkDone: false, counts: msNone), expected: .indexing),
    MSRow(name: "started, no walk finished, all rows done", inputs: msInputs(walkDone: false, counts: msDone4), expected: .indexing),
    MSRow(name: "started, no walk finished, needs_permission alone", inputs: msInputs(walkDone: false, counts: msPermOnly), expected: .indexing),
    MSRow(name: "started, walk finished, pending rows", inputs: msInputs(counts: msPending), expected: .indexing),
    MSRow(name: "started, walk finished, partial rows", inputs: msInputs(counts: msPartial), expected: .indexing),
    MSRow(name: "started, walk finished, pending and needs_permission", inputs: msInputs(counts: msPermAndPending), expected: .indexing),
    MSRow(name: "started, no walk, pending rows", inputs: msInputs(walkDone: false, counts: msPending), expected: .indexing),
    // Downloading: the model is not whole, over everything
    MSRow(name: "model downloading, ready otherwise", inputs: msInputs(model: .downloading, counts: msDone4), expected: .downloading),
    MSRow(name: "model damaged, ready otherwise", inputs: msInputs(model: .damaged, counts: msDone4), expected: .downloading),
    MSRow(name: "model downloading, not started", inputs: msInputs(model: .downloading, startPressed: false, walkDone: false, counts: msNone), expected: .downloading),
    MSRow(name: "model damaged, indexing otherwise", inputs: msInputs(model: .damaged, walkDone: false, counts: msPending), expected: .downloading),
    // Paused: any reason, over Indexing and over Ready
    MSRow(name: "paused by you while indexing", inputs: msInputs(counts: msPending, reasons: [.you]), expected: .paused),
    MSRow(name: "paused by the CPU while indexing", inputs: msInputs(walkDone: false, counts: msNone, reasons: [.cpu]), expected: .paused),
    MSRow(name: "paused by Low Power Mode while indexing", inputs: msInputs(counts: msPartial, reasons: [.lowPower]), expected: .paused),
    MSRow(name: "paused by the battery while indexing", inputs: msInputs(counts: msPending, reasons: [.battery]), expected: .paused),
    MSRow(name: "reason set while everything is read", inputs: msInputs(counts: msDone4, reasons: [.battery]), expected: .paused),
    MSRow(name: "reason set before Start", inputs: msInputs(startPressed: false, walkDone: false, counts: msNone, reasons: [.you]), expected: .paused),
    MSRow(name: "all four reasons", inputs: msInputs(counts: msPending, reasons: [.you, .cpu, .lowPower, .battery]), expected: .paused),
    // the precedence pairs
    MSRow(name: "Downloading over Paused (you)", inputs: msInputs(model: .downloading, counts: msPending, reasons: [.you]), expected: .downloading),
    MSRow(name: "Downloading over Paused (all four), damaged", inputs: msInputs(model: .damaged, walkDone: false, counts: msNone, reasons: [.you, .cpu, .lowPower, .battery]), expected: .downloading),
    MSRow(name: "Paused over Indexing (no walk finished)", inputs: msInputs(walkDone: false, counts: msNone, reasons: [.cpu]), expected: .paused),
]

private let msAllReasons: [PauseReason] = [.you, .cpu, .lowPower, .battery]

/// All 16 sets of reasons, the empty one first.
private func msReasonSets() -> [Set<PauseReason>] {
    (0..<16).map { mask in
        var set = Set<PauseReason>()
        for (bit, reason) in msAllReasons.enumerated() where mask & (1 << bit) != 0 { set.insert(reason) }
        return set
    }
}

private let msOtherInputs: [(startPressed: Bool, indexDeleted: Bool, walkDone: Bool, counts: IndexCounts)] = [
    (false, false, false, msNone), (false, true, false, msNone), (true, false, false, msNone), (true, false, true, msDone4),
    (true, false, true, msPending), (true, false, true, msPartial), (true, false, true, msPermOnly), (false, false, true, msPending),
]

extension ModelDownloadTests {
    @Suite("MenuStateTests", .serialized)
    struct MenuStateTests {

        // MARK: the state, over the hand-written table

        @Test func everyRowOfTheTableGivesItsState() {
            #expect(msRows.count >= 20, "the table has \(msRows.count) rows, the entry wants at least 20")
            var bad: [String] = []
            for row in msRows {
                let got = MenuState.evaluate(row.inputs)
                if got != row.expected { bad.append("\(row.name): got \(msName(got)), want \(msName(row.expected))") }
            }
            #expect(bad.isEmpty, "\(bad.count) of \(msRows.count) rows wrong: \(bad)")
        }

        @Test func aModelThatIsNotWholeIsDownloadingWhateverElseHolds() {
            var bad: [String] = []
            for model in [ModelState.downloading, .damaged] {
                for reasons in msReasonSets() {
                    for other in msOtherInputs {
                        let state = MenuState.evaluate(msInputs(model: model, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                                walkDone: other.walkDone, counts: other.counts, reasons: reasons))
                        if state != .downloading { bad.append("model \(model) reasons \(reasons.count) \(other): \(msName(state))") }
                    }
                }
            }
            #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
        }

        @Test func aWholeModelWithAnyPauseReasonIsPausedWhateverElseHolds() {
            var bad: [String] = []
            for reasons in msReasonSets() where !reasons.isEmpty {
                for other in msOtherInputs {
                    let state = MenuState.evaluate(msInputs(startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                            walkDone: other.walkDone, counts: other.counts, reasons: reasons))
                    if state != .paused { bad.append("reasons \(reasons.sorted { "\($0)" < "\($1)" }) \(other): \(msName(state))") }
                }
            }
            #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
        }

        @Test func withNoReasonAndAWholeModelTheStateIsIndexingOrReadyByTheRuleOfSection3() {
            // Indexing exactly when Start was pressed and (no walk finished, or a pending or partial row); else Ready.
            let expected: [MenuState] = [.ready, .ready, .indexing, .ready, .indexing, .indexing, .ready, .ready]
            for (other, want) in zip(msOtherInputs, expected) {
                let state = MenuState.evaluate(msInputs(startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                        walkDone: other.walkDone, counts: other.counts))
                #expect(state == want, "\(other): got \(msName(state)), want \(msName(want))")
            }
        }

        // MARK: the status item label (S7.1, S7.16: never empty)

        @Test func theStatusItemLabelForEachStateIsTheMockupsWording() {
            let indexing = msModel(msInputs(counts: msCounts(done: 7400, pending: ["photo": 4520])))
            #expect(indexing.statusItemLabel == "Sesame: indexing, 62 percent", "got \(indexing.statusItemLabel)")

            let ready = msModel(msInputs(counts: msDone4))
            #expect(ready.statusItemLabel == "Sesame: ready", "got \(ready.statusItemLabel)")

            let notStarted = msModel(msInputs(startPressed: false, walkDone: false, counts: msNone))
            #expect(notStarted.statusItemLabel == "Sesame: ready", "Ready before Start too, got \(notStarted.statusItemLabel)")

            let downloading = msModel(msInputs(model: .downloading, startPressed: false, walkDone: false, counts: msNone), downloadPercent: 34)
            #expect(downloading.statusItemLabel == "Sesame: downloading the model, 34 percent", "got \(downloading.statusItemLabel)")
            let damaged = msModel(msInputs(model: .damaged, counts: msDone4), downloadPercent: 7)
            #expect(damaged.statusItemLabel == "Sesame: downloading the model, 7 percent", "got \(damaged.statusItemLabel)")
            let fullyDownloadedButNotWhole = msModel(msInputs(model: .downloading, counts: msDone4), downloadPercent: 100)
            #expect(fullyDownloadedButNotWhole.statusItemLabel == "Sesame: downloading the model, 100 percent")

            for reasons in [[PauseReason.you], [.cpu], [.lowPower], [.battery], [.you, .battery], [.cpu, .lowPower]] {
                let paused = msModel(msInputs(counts: msPending, reasons: Set(reasons)))
                #expect(paused.statusItemLabel == "Sesame: paused", "reasons \(reasons): got \(paused.statusItemLabel)")
            }
        }

        @Test func theLabelAndTheStatusLineAreNeverEmptyForAnyInput() {
            var bad: [String] = []
            for model in [ModelState.whole, .downloading, .damaged] {
                for reasons in msReasonSets() {
                    for other in msOtherInputs {
                        for percent in [0, 34, 100] {
                            let m = msModel(msInputs(model: model, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                     walkDone: other.walkDone, counts: other.counts, reasons: reasons),
                                            downloadPercent: percent)
                            if m.statusItemLabel.isEmpty { bad.append("empty label: \(model) \(reasons.count) \(other) \(percent)") }
                            if m.statusLine.isEmpty { bad.append("empty status line: \(model) \(reasons.count) \(other) \(percent)") }
                            if m.state != MenuState.evaluate(msInputs(model: model, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                                      walkDone: other.walkDone, counts: other.counts, reasons: reasons)) {
                                bad.append("model.state differs from MenuState.evaluate: \(model) \(reasons.count) \(other)")
                            }
                        }
                    }
                }
            }
            #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
        }

        // MARK: the status line and the second line

        @Test func theIndexingStatusLineIsThePercentRoundedDown() {
            // percent = done / (done + pending + partial), rounded down; needs_permission is not in it. Hand numbers.
            let rows: [(counts: IndexCounts, percent: Int)] = [
                (msCounts(done: 7400, pending: ["photo": 4520]), 62),          // 62.08
                (msCounts(done: 1, pending: ["photo": 2]), 33),                // 33.3
                (msCounts(done: 2, pending: ["photo": 1]), 66),                // 66.67: down, not 67
                (msCounts(done: 2, partial: ["pdf": 1]), 66),                  // partial counts as left
                (msCounts(done: 1, pending: ["photo": 1], partial: ["pdf": 1]), 33),
                (msCounts(done: 999, pending: ["photo": 1]), 99),              // 99.9: never 100 while a file is left
                (msCounts(done: 99, pending: ["photo": 1]), 99),               // 99.0
                (msCounts(done: 1, pending: ["photo": 199]), 0),               // 0.5
                (msCounts(done: 0, pending: ["photo": 5]), 0),
                (msCounts(done: 1, pending: ["photo": 1], needs: 8), 50),      // needs_permission is not part of the whole
                (msCounts(done: 50, pending: ["photo": 25], partial: ["pdf": 25]), 50),
            ]
            for row in rows {
                let m = msModel(msInputs(counts: row.counts))
                #expect(m.state == .indexing, "\(row.counts): state \(msName(m.state))")
                #expect(m.statusLine == "Indexing \(row.percent)%", "\(row.counts): got \(m.statusLine)")
                #expect(m.statusItemLabel == "Sesame: indexing, \(row.percent) percent", "\(row.counts): got \(m.statusItemLabel)")
            }
        }

        @Test func startPressedBeforeAnyRowIsZeroPercent() {
            // the panel's "Still indexing (0%)" (spec S1 text 3): Start pressed, no walk finished, no rows
            let m = msModel(msInputs(walkDone: false, counts: msNone))
            #expect(m.state == .indexing)
            #expect(m.statusLine == "Indexing 0%", "got \(m.statusLine)")
            #expect(m.statusItemLabel == "Sesame: indexing, 0 percent", "got \(m.statusItemLabel)")
        }

        @Test func theSecondLineIsFilesLeftWithThousandsSeparatorsAndTheEstimatorsTimeLeft() {
            // remaining = pending + partial rows of every kind; the time goes through Estimator.left, whose pdf has no speed here
            let rows: [(counts: IndexCounts, speeds: [String: Double], line: String)] = [
                // 4,520 x 0.16 = 723.2 s = 12.05 min
                (msCounts(done: 7400, pending: ["photo": 4520]), ["photo": 0.16], "4,520 files left · about 12 min left"),
                // 4,000 photos x 0.18 = 720 s = 12 min; the 520 partial pdf files have no speed and add no time, but are files left
                (msCounts(done: 7400, pending: ["photo": 4000], partial: ["pdf": 520]), ["photo": 0.18], "4,520 files left · about 12 min left"),
                // 26,000 x 0.3 = 7,800 s
                (msCounts(done: 10, pending: ["photo": 26_000]), ["photo": 0.3], "26,000 files left · about 2 h 10 min left"),
                // 1,234,567 x 0.001 = 1,234.567 s = 20.58 min
                (msCounts(done: 10, pending: ["photo": 1_234_567]), ["photo": 0.001], "1,234,567 files left · about 21 min left"),
                // under a thousand: no separator; 999 x 0.1 = 99.9 s = 1.67 min
                (msCounts(done: 1, pending: ["photo": 999]), ["photo": 0.1], "999 files left · about 2 min left"),
                // 1,000 x 0.3 = 300 s
                (msCounts(done: 1, pending: ["photo": 1000]), ["photo": 0.3], "1,000 files left · about 5 min left"),
            ]
            for row in rows {
                let m = msModel(msInputs(counts: row.counts), speeds: row.speeds)
                #expect(m.state == .indexing)
                #expect(m.detailLine == row.line, "\(row.counts) speeds \(row.speeds): got \(String(describing: m.detailLine)), want \(row.line)")
            }
        }

        @Test func aKindSwitchedOffAddsNoTimeToTheTimeLeft() {
            // 1,000 photos x 0.3 = 300 s; 500 pdf x 2.0 = 1,000 s, but pdf is off in kindsOn
            let counts = msCounts(done: 5, pending: ["photo": 1000, "pdf": 500])
            var kindsOn = msAllOn
            kindsOn["pdf"] = false
            let m = msModel(msInputs(counts: counts), speeds: ["photo": 0.3, "pdf": 2.0], kindsOn: kindsOn)
            let line = m.detailLine ?? "nil"
            #expect(line.hasSuffix("· about 5 min left"), "pdf is off, so only the photos' 5 min: got \(line)")
        }

        @Test func notStartedShowsIndexingHasNotBeenStarted() {
            for (deleted, counts) in [(false, msNone), (true, msNone), (false, msPending)] {
                let m = msModel(msInputs(startPressed: false, indexDeleted: deleted, walkDone: false, counts: counts))
                #expect(m.state == .ready, "deleted \(deleted) \(counts): state \(msName(m.state))")
                #expect(m.statusLine == "Indexing has not been started", "deleted \(deleted) \(counts): got \(m.statusLine)")
            }
            let started = msModel(msInputs(counts: msDone4))
            #expect(started.statusLine != "Indexing has not been started", "Ready after Start is not 'not started'")
        }

        @Test func filesThatNeedPermissionAreReadyWithTheCountInItsOwnLine() {
            let two = msModel(msInputs(counts: msPermOnly))
            #expect(two.state == .ready)
            #expect(two.permissionLine == "2 files need permission to be read", "got \(String(describing: two.permissionLine))")

            let one = msModel(msInputs(counts: msCounts(done: 9, needs: 1)))
            #expect(one.state == .ready)
            #expect(one.permissionLine == "1 file needs permission to be read", "got \(String(describing: one.permissionLine))")

            let twelve = msModel(msInputs(counts: msCounts(done: 9, needs: 12)))
            #expect(twelve.permissionLine == "12 files need permission to be read", "got \(String(describing: twelve.permissionLine))")

            for counts in [msNone, msDone4, msPending, msPartial] {
                let m = msModel(msInputs(counts: counts))
                #expect(m.permissionLine == nil, "no file needs permission, got \(String(describing: m.permissionLine)) for \(counts)")
            }
        }

        @Test func theStatusLineNamesWhyItIsPaused() {
            let rows: [(reasons: Set<PauseReason>, line: String)] = [
                ([.you], "Paused by you"),
                ([.cpu], "Paused: the Mac is busy"),
                ([.lowPower], "Paused: Low Power Mode is on"),
                ([.battery], "Paused: on battery"),
            ]
            for row in rows {
                let m = msModel(msInputs(counts: msPending, reasons: row.reasons))
                #expect(m.state == .paused)
                #expect(m.statusLine == row.line, "\(row.reasons): got \(m.statusLine)")
            }
            // several reasons: the entry fixes no wording for the mix, only that it says Paused
            for reasons: Set<PauseReason> in [[.you, .battery], [.cpu, .lowPower], [.you, .cpu, .lowPower, .battery]] {
                let m = msModel(msInputs(counts: msPending, reasons: reasons))
                #expect(m.statusLine.hasPrefix("Paused"), "\(reasons): got \(m.statusLine)")
            }
        }

        // MARK: the first action and "Resume anyway, on battery"

        @Test func pauseIndexingIsEnabledOnlyWhileIndexing() {
            let indexing = msModel(msInputs(counts: msPending))
            #expect(indexing.firstActionTitle == "Pause indexing", "got \(indexing.firstActionTitle)")
            #expect(indexing.firstActionEnabled, "Pause is disabled while Indexing")

            let ready: [(String, MenuInputs)] = [
                ("ready after Start", msInputs(counts: msDone4)),
                ("not started", msInputs(startPressed: false, walkDone: false, counts: msNone)),
                ("needs_permission only", msInputs(counts: msPermOnly)),
            ]
            for (name, inputs) in ready {
                let m = msModel(inputs)
                #expect(m.state == .ready)
                #expect(m.firstActionTitle == "Pause indexing", "\(name): got \(m.firstActionTitle)")
                #expect(!m.firstActionEnabled, "\(name): Pause is enabled while Ready")
            }

            for model in [ModelState.downloading, .damaged] {
                let m = msModel(msInputs(model: model, counts: msPending), downloadPercent: 34)
                #expect(m.firstActionTitle == "Pause indexing", "\(model): got \(m.firstActionTitle)")
                #expect(!m.firstActionEnabled, "\(model): Pause is enabled while Downloading")
            }
        }

        @Test func resumeIndexingIsEnabledWhenYouIsAmongTheReasonsAndDisabledWhenOnlyAutomaticReasonsHold() {
            let rows: [(reasons: Set<PauseReason>, enabled: Bool)] = [
                ([.you], true),
                ([.you, .cpu], true),
                ([.you, .lowPower], true),
                ([.you, .battery], true),
                ([.you, .cpu, .lowPower, .battery], true),
                ([.cpu], false),
                ([.lowPower], false),
                ([.battery], false),
                ([.cpu, .lowPower], false),
                ([.cpu, .battery], false),
                ([.cpu, .lowPower, .battery], false),
            ]
            for row in rows {
                let m = msModel(msInputs(counts: msPending, reasons: row.reasons))
                #expect(m.state == .paused)
                #expect(m.firstActionTitle == "Resume indexing", "\(row.reasons): got \(m.firstActionTitle)")
                #expect(m.firstActionEnabled == row.enabled, "\(row.reasons): enabled is \(m.firstActionEnabled), want \(row.enabled)")
            }
        }

        @Test func resumeAnywayOnBatteryIsOfferedExactlyWhenTheBatteryReasonHolds() {
            let battery = "Resume anyway, on battery"
            for reasons in msReasonSets() where reasons.contains(.battery) {
                let m = msModel(msInputs(counts: msPending, reasons: reasons))
                #expect(m.state == .paused)
                #expect(m.resumeAnywayTitle == battery, "\(reasons): got \(String(describing: m.resumeAnywayTitle))")
            }
            for reasons in msReasonSets() where !reasons.contains(.battery) && !reasons.isEmpty {
                let m = msModel(msInputs(counts: msPending, reasons: reasons))
                #expect(m.resumeAnywayTitle == nil, "\(reasons): got \(String(describing: m.resumeAnywayTitle))")
            }
            for counts in [msPending, msDone4] {
                let m = msModel(msInputs(counts: counts))
                #expect(m.resumeAnywayTitle == nil, "not paused: got \(String(describing: m.resumeAnywayTitle))")
            }
        }

        // MARK: counts per kind (S1.6, S1.30)

        @Test func perKindCountsAreTheDoneRowsOnly() {
            // 9,690 photos are done while 310 are pending and 40 partial; a model that added them would show 10,000
            let counts = msCounts(done: 9690 + 1083 + 1068, pending: ["photo": 310], partial: ["pdf": 40], needs: 5)
            let m = msModel(msInputs(counts: counts),
                            doneByKind: ["photo": 9690, "pdf": 1083, "doc": 1068, "audio": 0])
            #expect(m.doneCounts["photo"] == 9690, "photo is \(String(describing: m.doneCounts["photo"]))")
            #expect(m.doneCounts["pdf"] == 1083, "pdf is \(String(describing: m.doneCounts["pdf"]))")
            #expect(m.doneCounts["doc"] == 1068, "doc is \(String(describing: m.doneCounts["doc"]))")
            #expect((m.doneCounts["audio"] ?? 0) == 0, "audio is \(String(describing: m.doneCounts["audio"]))")
            #expect((m.doneCounts["video"] ?? 0) == 0 && (m.doneCounts["code"] ?? 0) == 0, "kinds with no done file show 0 or nothing")
        }

        // MARK: the snapshot a background source builds (needs a real index; the cache's own wiring is StatusCacheTests')

        @MainActor
        @Test func theSnapshotReadFromTheIndexHoldsTheDoneCountPerKindAndTheLastIndexedPath() async throws {
            try await spWithHome { _ in
                var settings = Settings()
                settings.startPressed = true
                try SettingsFile().write(settings)
                let store = try IndexStore()
                var inode: Int64 = 0
                func add(_ path: String, _ kind: String, _ status: String) throws -> Int64 {
                    inode += 1
                    return try store.addFile(path: path, kind: kind, size: 1000, mtimeNs: 1_700_000_000_000_000_000, inode: inode,
                                             device: 16_777_220, status: status)
                }
                func passage(_ file: Int64, _ start: Double) throws {
                    _ = try store.addPassage(fileID: file, source: "name", start: start, end: start, modality: "none", vector: nil,
                                             name: "w", body: "")
                }
                // done: 3 photos (three passages each: a file is counted once, not per passage), 1 pdf, 2 docs
                for name in ["a", "b", "c"] {
                    let file = try add("/p/\(name).jpg", "photo", "done")
                    for start in 0..<3 { try passage(file, Double(start)) }
                }
                let pdf = try add("/d/lease.pdf", "pdf", "done")
                try passage(pdf, 0)
                let notes = try add("/d/notes.md", "doc", "done")
                try passage(notes, 0)
                let other = try add("/d/other.md", "doc", "done")
                try passage(other, 0)
                // not done: none of these is a done count, and the last passage written belongs to a partial file
                _ = try add("/p/pending1.jpg", "photo", "pending")
                _ = try add("/p/pending2.jpg", "photo", "pending")
                _ = try add("/p/locked.jpg", "photo", "needs_permission")
                _ = try add("/a/clip.mp3", "audio", "pending")
                let partial = try add("/d/long.pdf", "pdf", "partial")
                // the done file with the greatest passage id is notes.md, written after every other done file's passages
                try passage(notes, 1)
                try passage(partial, 0)
                store.close()

                let reader = IndexReader()
                defer { reader.close() }
                let snapshot = PanelSnapshot.read(reader: reader, model: .whole)
                let done = snapshot.doneByKind.filter { $0.value != 0 }
                #expect(done == ["photo": 3, "pdf": 1, "doc": 2], "doneByKind is \(snapshot.doneByKind)")
                #expect(snapshot.lastIndexedPath == "/d/notes.md", "lastIndexedPath is \(String(describing: snapshot.lastIndexedPath))")
                // the plan-1 fields are still read (a guard: it passes before the change too, apart from the compile)
                #expect(snapshot.counts.done == 6, "done is \(snapshot.counts.done)")
                #expect(snapshot.counts.needsPermission == 1, "needsPermission is \(snapshot.counts.needsPermission)")
            }
        }

        @MainActor
        @Test func theSnapshotOfAnEmptyIndexHasNoDoneCountsAndNoLastIndexedPath() async throws {
            try await spWithHome { _ in
                try SettingsFile().write(Settings())
                let reader = IndexReader()
                defer { reader.close() }
                let snapshot = PanelSnapshot.read(reader: reader, model: .whole)
                #expect(snapshot.doneByKind.values.allSatisfy { $0 == 0 }, "doneByKind is \(snapshot.doneByKind)")
                #expect(snapshot.lastIndexedPath == nil, "lastIndexedPath is \(String(describing: snapshot.lastIndexedPath))")
            }
        }
    }
}

// =================================================================================================================
// plan-2 fix round D, tester step, item D1 (R3-01): the menu must not say only "Downloading" while the download has failed.
// Written from the fix-round document ("add a failed state to `MenuState`/`MenuModel` ... a pure value test each: the status
// line 'Model download failed', the first action disabled") and the sealed tests above. No product source was read. Every
// expected text is written by hand.
//
// API SHAPES D1 pins here (new):
//   1. `ModelState` (SesameEngine, public) gains `case failed`: the model is not whole, its download gave up (ModelDownload's
//      retry delays are spent, or the watcher's refetch failed) and it waits for Retry. It is what the app puts in the
//      status snapshot's `model` while the failure stands, also after Delete index when the model is missing. The existing
//      cases keep their meaning.
//   2. `MenuState` gains `case failed`. `MenuState.evaluate` gives `.failed` whenever `inputs.model == .failed`, over
//      Downloading's neighbours: over Paused (any reason), over Indexing and over Ready, whatever Start, the delete flag,
//      the walk and the counts say (the same precedence as `.downloading`).
//   3. `MenuModel` for `.failed`:
//        statusLine          "Model download failed"          (exactly; no percent in it)
//        statusItemLabel     "Sesame: model download failed"  (exactly; never empty)
//        firstActionTitle    "Pause indexing", firstActionEnabled false   <- RE-PINNED IN ROUND E (E1, R4-01): see below
//        detailLine          nil, resumeAnywayTitle nil       (no second line, no battery offer: nothing is indexing)
//      ROUND E (E1, R4-01) re-pin: the failed `MenuModel`'s firstActionTitle is "Retry model download" and firstActionEnabled is
//      true (the person who closed the failure window needs a way back). Everything else of this list stands.
//      `downloadPercent` is read only for `.downloading` and `.damaged`.
//   4. `StatusIcons.image(for: .failed)` is a menu bar template image like the others (MenuBuilderTests).
// The sealed tests above sweep only whole, downloading and damaged models, so none of them changes.
// =================================================================================================================

extension ModelDownloadTests.MenuStateTests {

    @Test func aFailedDownloadIsTheFailedStateWhateverElseHolds() {
        var bad: [String] = []
        for reasons in msReasonSets() {
            for other in msOtherInputs {
                let state = MenuState.evaluate(msInputs(model: .failed, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                        walkDone: other.walkDone, counts: other.counts, reasons: reasons))
                if state != .failed { bad.append("reasons \(reasons.count) \(other): \(msName(state))") }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    @Test func theFailedStateIsOverPausedIndexingAndReadyAndAfterDeleteIndexToo() {
        let rows: [(String, MenuInputs)] = [
            ("indexing otherwise", msInputs(model: .failed, counts: msPending)),
            ("ready otherwise", msInputs(model: .failed, counts: msDone4)),
            ("paused by you otherwise", msInputs(model: .failed, counts: msPending, reasons: [.you])),
            ("paused on battery otherwise", msInputs(model: .failed, counts: msPending, reasons: [.battery])),
            ("after Delete index, model missing", msInputs(model: .failed, startPressed: false, indexDeleted: true, walkDone: false, counts: msNone)),
            ("Start never pressed", msInputs(model: .failed, startPressed: false, walkDone: false, counts: msNone)),
        ]
        for (name, inputs) in rows {
            #expect(MenuState.evaluate(inputs) == .failed, "\(name): got \(msName(MenuState.evaluate(inputs)))")
        }
    }

    // ROUND E (E1) re-pin: was `...AndDisablesTheFirstAction` with "Pause indexing" disabled; now an enabled "Retry model download".
    @Test func theFailedMenuModelSaysModelDownloadFailedAndOffersAnEnabledRetryAsTheFirstAction() {
        for reasons in [Set<PauseReason>(), [.you], [.battery], [.cpu, .lowPower]] {
            for counts in [msNone, msPending, msDone4] {
                let m = msModel(msInputs(model: .failed, counts: counts, reasons: reasons), downloadPercent: 34)
                let where_ = "reasons \(reasons.count), counts \(counts)"
                #expect(m.state == .failed, "\(where_): state \(msName(m.state))")
                #expect(m.statusLine == "Model download failed", "\(where_): status line \(m.statusLine.debugDescription)")
                #expect(m.statusItemLabel == "Sesame: model download failed", "\(where_): label \(m.statusItemLabel.debugDescription)")
                #expect(m.firstActionTitle == "Retry model download", "\(where_): first action \(m.firstActionTitle)")
                #expect(m.firstActionEnabled, "\(where_): the Retry is disabled while the download failed")
                #expect(m.detailLine == nil, "\(where_): a second line while the download failed: \(String(describing: m.detailLine))")
                #expect(m.resumeAnywayTitle == nil, "\(where_): a battery offer while the download failed: \(String(describing: m.resumeAnywayTitle))")
            }
        }
    }

    @Test func theFailedLabelAndStatusLineAreNeverEmptyAndCarryNoPercent() {
        var bad: [String] = []
        for reasons in msReasonSets() {
            for other in msOtherInputs {
                for percent in [0, 34, 100] {
                    let m = msModel(msInputs(model: .failed, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                             walkDone: other.walkDone, counts: other.counts, reasons: reasons), downloadPercent: percent)
                    if m.statusItemLabel.isEmpty || m.statusLine.isEmpty { bad.append("empty: \(reasons.count) \(other) \(percent)") }
                    if m.statusLine.contains("%") || m.statusItemLabel.contains("percent") { bad.append("a percent in a failed line: \(m.statusLine) / \(m.statusItemLabel)") }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    // GUARD: passes today once the new case compiles. Downloading and damaged keep their words.
    @Test func downloadingAndDamagedAreStillDownloadingWithTheirWords() {
        let downloading = msModel(msInputs(model: .downloading, startPressed: false, walkDone: false, counts: msNone), downloadPercent: 34)
        #expect(downloading.state == .downloading)
        #expect(downloading.statusItemLabel == "Sesame: downloading the model, 34 percent", "got \(downloading.statusItemLabel)")
        #expect(downloading.statusLine != "Model download failed")
        let damaged = msModel(msInputs(model: .damaged, counts: msDone4), downloadPercent: 7)
        #expect(damaged.state == .downloading)
        #expect(damaged.statusLine != "Model download failed")
    }

    // ROUND E (E1). GUARD: passes today. Retry is the first action of the failed state alone; every other state keeps Pause or Resume.
    @Test func noStateButFailedOffersRetryModelDownloadAsItsFirstAction() {
        var bad: [String] = []
        for model in [ModelState.whole, .downloading, .damaged] {
            for reasons in msReasonSets() {
                for other in msOtherInputs {
                    let m = msModel(msInputs(model: model, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                             walkDone: other.walkDone, counts: other.counts, reasons: reasons), downloadPercent: 34)
                    if m.firstActionTitle == "Retry model download" { bad.append("\(model) \(reasons.count) \(other): Retry offered") }
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }
}

// =================================================================================================================
// plan-3-t21, tester step: a stalled helper is a pause reason, so the menu says so and offers Resume (S7.1, S7.2, S7.12).
// Written from the t21 entry of plan-3-tasks.md (its Tests paragraph) and decision D11, and the sealed tests above (the only
// place `MenuInputs`, `MenuModel` and the existing texts are read). No product source was read. Every expected text is
// written by hand.
//
// SHAPE t21 pins here (new): `PauseReason` gains `case stalled` (raised by the death cap and by an idle exit with rows left).
// In the set it makes the state `.paused` (under Downloading and Failed, as every reason is). The status line is exactly
// "Paused: indexing stopped, press Resume to try again"; the status item label stays "Sesame: paused". When several reasons
// hold the status line names the first of: you, stalled, the Mac is busy, Low Power Mode, battery. `firstActionTitle` is
// "Resume indexing" and `firstActionEnabled` is true when `.you` or `.stalled` is in the set (an automatic reason alone
// stays disabled, the sealed test above). The sealed 16-set tables above are not changed: they sweep no `.stalled`.
// =================================================================================================================

private let msStalledLine = "Paused: indexing stopped, press Resume to try again"

private let msFiveReasons: [PauseReason] = [.you, .stalled, .cpu, .lowPower, .battery]

/// All 16 sets of the five reasons that hold `.stalled`.
private func msStalledSets() -> [Set<PauseReason>] {
    (0..<32).compactMap { mask in
        var set = Set<PauseReason>()
        for (bit, reason) in msFiveReasons.enumerated() where mask & (1 << bit) != 0 { set.insert(reason) }
        return set.contains(.stalled) ? set : nil
    }
}

extension ModelDownloadTests.MenuStateTests {

    @Test func aStalledReasonAloneOrWithAnyOthersIsPausedWhateverElseHolds() {
        var bad: [String] = []
        #expect(msStalledSets().count == 16)
        for reasons in msStalledSets() {
            for other in msOtherInputs {
                let state = MenuState.evaluate(msInputs(startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                        walkDone: other.walkDone, counts: other.counts, reasons: reasons))
                if state != .paused { bad.append("reasons \(reasons.count) \(other): \(msName(state))") }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) wrong, first: \(bad.prefix(3))")
    }

    @Test func aStalledHelperWithRowsLeftIsPausedNeverIndexing() {
        // D11: an idle helper with rows still pending must not show "Indexing N%" with no helper
        let m = msModel(msInputs(counts: msCounts(done: 7400, pending: ["photo": 4520]), reasons: [.stalled]))
        #expect(m.state == .paused, "state \(msName(m.state))")
        #expect(m.statusLine == msStalledLine, "got \(m.statusLine.debugDescription)")
        #expect(m.statusItemLabel == "Sesame: paused", "got \(m.statusItemLabel.debugDescription)")
    }

    @Test func downloadingAndFailedModelsStayOverAStalledReason() {
        for reasons in msStalledSets() {
            for other in msOtherInputs {
                for model in [ModelState.downloading, .damaged] {
                    let state = MenuState.evaluate(msInputs(model: model, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                            walkDone: other.walkDone, counts: other.counts, reasons: reasons))
                    #expect(state == .downloading, "\(model) \(reasons.count) \(other): \(msName(state))")
                }
                let failed = MenuState.evaluate(msInputs(model: .failed, startPressed: other.startPressed, indexDeleted: other.indexDeleted,
                                                         walkDone: other.walkDone, counts: other.counts, reasons: reasons))
                #expect(failed == .failed, "failed \(reasons.count) \(other): \(msName(failed))")
            }
        }
    }

    @Test func theStatusItemLabelOfEveryStalledSetIsSesamePaused() {
        for reasons in msStalledSets() {
            for counts in [msPending, msDone4, msPartial, msNone] {
                let m = msModel(msInputs(counts: counts, reasons: reasons))
                #expect(m.statusItemLabel == "Sesame: paused", "\(reasons) \(counts): got \(m.statusItemLabel.debugDescription)")
            }
        }
    }

    @Test func theStatusLineOfAStalledSetIsTheOneTextUnlessYouIsAlsoThere() {
        // the order when several reasons hold: you, stalled, the Mac is busy, Low Power Mode, battery
        let rows: [(reasons: Set<PauseReason>, line: String)] = [
            ([.stalled], msStalledLine),
            ([.stalled, .cpu], msStalledLine),
            ([.stalled, .lowPower], msStalledLine),
            ([.stalled, .battery], msStalledLine),
            ([.stalled, .cpu, .lowPower, .battery], msStalledLine),
            ([.you, .stalled], "Paused by you"),
            ([.you, .stalled, .cpu], "Paused by you"),
            ([.you, .stalled, .cpu, .lowPower, .battery], "Paused by you"),
            ([.cpu, .lowPower], "Paused: the Mac is busy"),
            ([.cpu, .battery], "Paused: the Mac is busy"),
            ([.lowPower, .battery], "Paused: Low Power Mode is on"),
        ]
        for row in rows {
            for counts in [msPending, msDone4, msPartial] {
                let m = msModel(msInputs(counts: counts, reasons: row.reasons))
                #expect(m.statusLine == row.line, "\(row.reasons) \(counts): got \(m.statusLine.debugDescription), want \(row.line.debugDescription)")
            }
        }
    }

    @Test func resumeIndexingIsEnabledForEverySetThatHoldsStalled() {
        for reasons in msStalledSets() {
            let m = msModel(msInputs(counts: msPending, reasons: reasons))
            #expect(m.state == .paused)
            #expect(m.firstActionTitle == "Resume indexing", "\(reasons): got \(m.firstActionTitle)")
            #expect(m.firstActionEnabled, "\(reasons): Resume is disabled while stalled")
        }
        // the first action is Resume, enabled, also when the walk finished and nothing is left to read
        let ready = msModel(msInputs(counts: msDone4, reasons: [.stalled]))
        #expect(ready.firstActionTitle == "Resume indexing" && ready.firstActionEnabled, "got \(ready.firstActionTitle) enabled \(ready.firstActionEnabled)")
    }

    @Test func pendingOrPartialRowsOfAKindOutsideTheFiveNamedKindsLeaveTheMenuIdle() {
        let codePending = msCounts(done: 1, pending: ["code": 2])
        let codePartial = msCounts(done: 1, partial: ["code": 2])
        for counts in [codePending, codePartial] {
            let m = msModel(msInputs(counts: counts))
            #expect(m.state == .ready, "\(counts): state \(msName(m.state))")
            #expect(m.detailLine == nil, "\(counts): a files-left line for rows of a kind that is not named: \(String(describing: m.detailLine))")
            #expect(!m.statusLine.hasPrefix("Indexing"), "\(counts): got \(m.statusLine)")
            #expect(m.statusItemLabel == "Sesame: ready", "\(counts): got \(m.statusItemLabel)")
            #expect(!m.firstActionEnabled, "\(counts): Pause is enabled with nothing named to read")
        }
    }

    @Test func rowsOfAKindOutsideTheNamedKindsAreNotFilesLeftNorPartOfThePercent() {
        let counts = msCounts(done: 2, pending: ["photo": 2, "code": 8])
        let m = msModel(msInputs(counts: counts))
        #expect(m.state == .indexing, "state \(msName(m.state))")
        #expect(m.statusLine == "Indexing 50%", "two done, two photos left, the 8 code rows are not counted: got \(m.statusLine)")
        #expect((m.detailLine ?? "").hasPrefix("2 files left"), "got \(String(describing: m.detailLine))")
        let more = msModel(msInputs(counts: msCounts(done: 2, pending: ["photo": 3], partial: ["pdf": 1, "code": 5])))
        #expect((more.detailLine ?? "").hasPrefix("4 files left"), "3 photos and 1 pdf are left, the 5 code rows are not: got \(String(describing: more.detailLine))")
    }

    @Test func anAutomaticReasonAloneStillLeavesResumeDisabledWhenNothingIsStalled() {
        // GUARD (passes once the new case compiles): Resume is enabled by `.you` or `.stalled`, not by the automatic reasons
        for reasons in [Set<PauseReason>([.cpu]), [.lowPower], [.battery], [.cpu, .lowPower, .battery]] {
            let m = msModel(msInputs(counts: msPending, reasons: reasons))
            #expect(m.firstActionTitle == "Resume indexing" && !m.firstActionEnabled, "\(reasons): got \(m.firstActionTitle) enabled \(m.firstActionEnabled)")
        }
    }
}

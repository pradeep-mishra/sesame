import AppKit
import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t38, tester step. Written from the t38 entry, spec S1 ("Pressing the shortcut while the panel is open closes
// it", "Esc takes two presses: the first clears the text, the second closes the panel (with an empty box, one press
// closes)", "After fast typing then Enter, the file opened is the first result for the text in the box at that moment,
// never one for an earlier keystroke", "reopening never shows the previous text"), design section 3 ("Searching": the
// ticket per keystroke, Enter's 2 s limit, "Still ranking", "Searching"; "Panel states": NotReadyView, IndexingBanner,
// EmptyHint, NoMatches) and the t25, t28 and t36 tests only; no product source read.
//
// SCOPE. Pure logic only, by the person's hard rule: Sesame is never launched or driven here, so the real keys, the
// drawn views and the t15 and t16 kit checks are NOT shown red; they run later in one batch.
//
// SUITE PLACEMENT. The ticket gate and the screen choice touch no HOME, probe or window and are top-level suites. The
// Panel and SetupModel suites set HOME or `Probe.sink`, which are process-wide, so they are nested inside the
// serialized `ModelDownloadTests` with the other suites that do. Side effect: `swift test --filter ModelDownloadTests`
// also runs them.
//
// API SHAPES these tests pin (the design names the views and the ticket and fixes no signature; if a shape is wrong,
// ask for a test change rather than guessing). All are in the `Sesame` target; the new ones live in the files the t38
// entry lists (`Tickets.swift`, `StateViews.swift`, `Panel.swift`).
//
//  1. The ticket gate, `Tickets.swift`. Pure state, no window, no helper:
//       `@MainActor final class TicketGate`
//       `static let enterWait: Double`                   2 seconds, the design's limit
//       `init(wait: Double = TicketGate.enterWait)`      the wait Enter allows; a test passes a short one
//       `func boxChanged(text: String, ticket: Int)`     the box now holds `text`, the keystroke's ticket is `ticket`;
//                                                        the latest call is the CURRENT ticket; any earlier list is old
//       `func rankedListArrived(ticket: Int, count: Int)`  the ranked list of `ticket` is in, holding `count` files
//       `func pressEnter() async -> EnterDecision`       see 2
//       `var stillRankingShown: Bool`                    true from the moment Enter gave up until the next keystroke or
//                                                        until the current ticket's ranked list arrives
//     A fresh gate has no current ticket and nothing typed.
//  2. `enum EnterDecision: Equatable { case open(ticket: Int), nothing, stillRanking }`. `pressEnter` looks at the CURRENT
//     ticket at the moment of the press:
//       - text empty or only spaces, or nothing typed yet: `.nothing` at once, never waits;
//       - its ranked list is in and holds files: `.open(ticket: current)` at once;
//       - its ranked list is in and empty: `.nothing` at once (Enter does nothing with no results);
//       - its ranked list is not in: waits for it, at most `wait` seconds; `.open(ticket: current)` the moment it
//         arrives; after `wait` seconds with no list of the current ticket, `.stillRanking` and the panel shows
//         "Still ranking". A list that arrives for an OLDER ticket neither ends the wait nor is ever opened.
//     `.open(ticket: n)` means "open the file selected in the list of ticket n": the gate never returns a ticket that is
//     not the current one at the press.
//  3. The screen choice, `StateViews.swift`: what the panel shows for the inputs it already has.
//       `struct PanelScreen: Equatable { let banner: IndexingBanner?; let body: PanelScreen.Body; let status: String? }`
//       `enum PanelScreen.Body: Equatable { case notReady(NotReadyView), emptyHint(EmptyHint), searching,`
//       `                                   noMatches(NoMatches), rows }`
//       `static let PanelScreen.searchingText = "Searching"`  and  `PanelScreen.stillRankingText = "Still ranking"`
//       `static func PanelScreen.choose(_ inputs: PanelInputs, keywordRows: Int, stillRanking: Bool = false) -> PanelScreen`
//     `inputs` is the t25 `PanelInputs` (`rankedCount` nil = the ranked list of the typed text is not in yet);
//     `keywordRows` is how many rows the keyword match of the typed text found (tier 1 only, design section 3);
//     `stillRanking` is `TicketGate.stillRankingShown`. `banner` is the `IndexingBanner` of `PanelState` when it says
//     Still indexing, shown ABOVE the body, and the body is then chosen as if the panel were ready (the panel stays usable).
//     `status` is "Still ranking" when `stillRanking` is true and text is typed, else nil.
//  4. `Panel` (`Panel.swift`), besides the t10 and t36 names `Panel()`, `show()`, `hide()`:
//       `var isShown: Bool`                  false for a new panel; true after `show()`; false after `hide()`
//       `var queryBox: QueryBox`             the panel's own box (t36), always the same object
//       `func shortcutPressed()`             the global shortcut: `show()` when hidden, `hide()` when shown
//       `func pressEscape()`                 the Esc key: text in the box (spaces count) clears it and the panel stays
//                                            shown; an empty box hides the panel
//     `show()` empties the box every time and emits the probe event `shown` (t36); `hide()` emits nothing.
//  5. `SetupModel.canStartIndexing` is true with no folder picked once the model is whole (spec S6: Start is unavailable
//     only until the model is present; carry-over of the t28 report), and `startIndexing()` then writes `startPressed`
//     true with an empty `folders` list and calls `onStart` once. This one is expected to be green already (t28 made
//     the change); it is pinned here so nothing takes it back.
//  6. Not pinned, on purpose: what the pane or the list draws, the look of the views, whether the gate polls or waits on
//     a continuation, what the panel does with Esc while a search is running beyond clearing the box, the order of the
//     keyword rows, and every kit-driven fact (focus, frontmost, Light and Dark).

// MARK: small helpers (file-private)

private func tkSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

// The wait these tests give a gate, and the main-actor scheduling slack a timing bound allows (finding F18). Other
// real-panel suites hold the main actor for a while when the suites run in parallel, so a bound close to the wait is
// a flake. The wait is long, the slack is 1 s: a gate that sat out its whole wait took `tkWait` seconds, far past
// the bound, and the decision value (`.stillRanking` after a timeout) says the same.
private let tkWait = 4.0
private let tkSlack = 1.0

private func tkSleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// Runs `body` and says how many seconds it took.
@MainActor
private func tkTimed<T>(_ body: () async -> T) async -> (value: T, seconds: Double) {
    let start = ContinuousClock.now
    let value = await body()
    return (value, tkSeconds(ContinuousClock.now - start))
}

private final class TKCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class TKEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ event: String, _ ticket: Int) { lock.lock(); list.append("\(event):\(ticket)"); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

// The tickets a pipeline hands out, taken from whatever thread a box asks on.
private final class TKTickets: @unchecked Sendable {
    private let lock = NSLock()
    private let pipeline: SearchPipeline
    private var taken: [Int] = []
    init(_ pipeline: SearchPipeline) { self.pipeline = pipeline }
    func take() -> Int {
        let ticket = MainActor.assumeIsolated { pipeline.newTicket() }
        lock.lock(); taken.append(ticket); lock.unlock()
        return ticket
    }
    var issued: [Int] { lock.lock(); defer { lock.unlock() }; return taken }
}

// MARK: the ticket gate

@Suite("TicketTests")
struct TicketTests {

    // MARK: Enter, the 2 s limit

    @MainActor
    @Test func theLimitIsTwoSecondsAndAFreshGateIsTheDefault() {
        #expect(TicketGate.enterWait == 2)
    }

    @MainActor
    @Test func enterWithNothingTypedDoesNothingAtOnce() async {
        let gate = TicketGate(wait: tkWait)
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value == .nothing, "got \(result.value)")
        #expect(result.seconds < tkSlack, "Enter waited \(result.seconds) s with nothing typed (its wait is \(tkWait) s)")
        #expect(!gate.stillRankingShown)
    }

    @MainActor
    @Test func enterWithAnEmptyOrSpacesOnlyBoxDoesNothingAtOnceEvenWhenAnOlderListIsIn() async {
        let gate = TicketGate(wait: tkWait)
        gate.boxChanged(text: "d", ticket: 1)
        gate.rankedListArrived(ticket: 1, count: 4)
        gate.boxChanged(text: "", ticket: 2)   // the text was cleared: ticket 1's list belongs to text that is gone
        let cleared = await tkTimed { await gate.pressEnter() }
        #expect(cleared.value == .nothing, "an emptied box: \(cleared.value)")
        #expect(cleared.seconds < tkSlack, "waited \(cleared.seconds) s on an empty box (its wait is \(tkWait) s)")

        gate.boxChanged(text: "   ", ticket: 3)
        let spaces = await tkTimed { await gate.pressEnter() }
        #expect(spaces.value == .nothing, "spaces only: \(spaces.value)")
        #expect(spaces.seconds < tkSlack, "waited \(spaces.seconds) s on spaces (its wait is \(tkWait) s)")
        #expect(!gate.stillRankingShown)
    }

    @MainActor
    @Test func enterOpensTheListOfTheCurrentTicketAtOnceWhenItIsAlreadyIn() async {
        let gate = TicketGate(wait: tkWait)
        gate.boxChanged(text: "dog on the beach", ticket: 41)
        gate.rankedListArrived(ticket: 41, count: 5)
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value == .open(ticket: 41), "got \(result.value)")
        #expect(result.seconds < tkSlack, "Enter waited \(result.seconds) s for a list that was already in (its wait is \(tkWait) s)")
        #expect(!gate.stillRankingShown)
    }

    @MainActor
    @Test func enterDoesNothingWhenTheCurrentTicketsRankedListIsInAndEmpty() async {
        let gate = TicketGate(wait: tkWait)
        gate.boxChanged(text: "zzqx", ticket: 8)
        gate.rankedListArrived(ticket: 8, count: 0)
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value == .nothing, "got \(result.value)")
        #expect(result.seconds < tkSlack, "waited \(result.seconds) s for no results (its wait is \(tkWait) s)")
        #expect(!gate.stillRankingShown, "Still ranking shown although the list is in and empty")
    }

    @MainActor
    @Test func enterWaitsForTheListAndOpensItTheMomentItArrives() async {
        // The gate's wait is `tkWait` (4 s); the list arrives after `arrival`. Opening the moment it arrives means the
        // press ends about `arrival` seconds in, never near the wait: the bound is the arrival plus `tkSlack` of
        // main-actor scheduling slack, a quarter of the wait, so a gate that only opened at its timeout cannot pass.
        let arrival = 0.15
        let gate = TicketGate(wait: tkWait)
        gate.boxChanged(text: "a dog on the beach", ticket: 5)
        let late = Task { @MainActor in
            await tkSleep(arrival)
            gate.rankedListArrived(ticket: 5, count: 3)
        }
        let result = await tkTimed { await gate.pressEnter() }
        await late.value
        #expect(result.value == .open(ticket: 5), "got \(result.value)")
        #expect(result.seconds >= 0.1, "Enter did not wait for the list: \(result.seconds) s")
        #expect(result.seconds < arrival + tkSlack,
                "Enter went on waiting after the list arrived: \(result.seconds) s (list at \(arrival) s, wait \(tkWait) s)")
        #expect(!gate.stillRankingShown)
    }

    @MainActor
    @Test func whenTheLimitRunsOutEnterDoesNothingAndThePanelShowsStillRanking() async {
        let gate = TicketGate(wait: 0.3)
        gate.boxChanged(text: "a dog on the beach", ticket: 5)
        #expect(!gate.stillRankingShown, "Still ranking shown before Enter was pressed")
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value == .stillRanking, "got \(result.value)")
        #expect(result.seconds >= 0.25, "Enter gave up after \(result.seconds) s, before its \(0.3) s")
        #expect(result.seconds < 1.5, "Enter waited \(result.seconds) s of a 0.3 s limit")
        #expect(gate.stillRankingShown)
    }

    @MainActor
    @Test func theRealLimitIsTwoSecondsNotMoreAndNotLess() async {
        let gate = TicketGate()
        gate.boxChanged(text: "a dog on the beach", ticket: 1)
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value == .stillRanking, "got \(result.value)")
        #expect(result.seconds >= 1.9, "Enter gave up after \(result.seconds) s, before the 2 s limit")
        #expect(result.seconds < 3.5, "Enter waited \(result.seconds) s, past the 2 s limit")
        #expect(gate.stillRankingShown)
    }

    @MainActor
    @Test func stillRankingGoesAwayWithTheNextKeystrokeAndWithTheListThatWasLate() async {
        let gate = TicketGate(wait: 0.2)
        gate.boxChanged(text: "dog", ticket: 3)
        _ = await gate.pressEnter()
        #expect(gate.stillRankingShown)

        // the list was only late: it arrives now, the note goes, and a second Enter opens it
        gate.rankedListArrived(ticket: 3, count: 2)
        #expect(!gate.stillRankingShown, "Still ranking stayed after the list arrived")
        let again = await gate.pressEnter()
        #expect(again == .open(ticket: 3), "got \(again)")

        // or the person types on: the note goes with the keystroke
        gate.boxChanged(text: "dogs", ticket: 4)
        _ = await gate.pressEnter()
        #expect(gate.stillRankingShown)
        gate.boxChanged(text: "dogs ", ticket: 5)
        #expect(!gate.stillRankingShown, "Still ranking stayed after a keystroke")
    }

    // MARK: a result for an older ticket is never opened

    @MainActor
    @Test func aListThatIsInForAnOlderTicketIsNeverOpenedByEnterOnANewerKeystroke() async {
        let gate = TicketGate(wait: 0.3)
        gate.boxChanged(text: "dog", ticket: 10)
        gate.rankedListArrived(ticket: 10, count: 6)
        gate.boxChanged(text: "dogs", ticket: 11)   // typed on; ticket 11's list is not in
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value != .open(ticket: 10), "Enter opened the list of the keystroke before")
        #expect(result.value == .stillRanking, "got \(result.value)")
        #expect(result.seconds >= 0.25, "Enter did not wait for ticket 11: \(result.seconds) s")
    }

    @MainActor
    @Test func aListThatArrivesLateForAnOlderTicketNeitherEndsTheWaitNorIsOpened() async {
        let gate = TicketGate(wait: 0.4)
        gate.boxChanged(text: "dog", ticket: 20)
        gate.boxChanged(text: "dogs", ticket: 21)
        let stale = Task { @MainActor in
            await tkSleep(0.1)
            gate.rankedListArrived(ticket: 20, count: 9)
        }
        let result = await tkTimed { await gate.pressEnter() }
        await stale.value
        #expect(result.value == .stillRanking, "got \(result.value)")
        #expect(result.seconds >= 0.35, "an older ticket's list ended the wait after \(result.seconds) s")
        #expect(gate.stillRankingShown)
    }

    @MainActor
    @Test func aKeystrokeWhileEnterWaitsMakesTheOlderListNeverOpen() async {
        let gate = TicketGate(wait: 0.5)
        gate.boxChanged(text: "dog", ticket: 30)
        let typing = Task { @MainActor in
            await tkSleep(0.1)
            gate.boxChanged(text: "dogs", ticket: 31)
            await tkSleep(0.1)
            gate.rankedListArrived(ticket: 30, count: 4)   // too late: ticket 30 is old
        }
        let result = await gate.pressEnter()
        await typing.value
        #expect(result != .open(ticket: 30), "the file of an earlier keystroke would have been opened")
    }

    @MainActor
    @Test func aNewerListIsTheOneThatOpensOnceItsTicketIsCurrent() async {
        let gate = TicketGate(wait: tkWait)
        gate.boxChanged(text: "dog", ticket: 50)
        gate.rankedListArrived(ticket: 50, count: 6)
        gate.boxChanged(text: "dogs", ticket: 51)
        gate.rankedListArrived(ticket: 51, count: 2)
        let result = await tkTimed { await gate.pressEnter() }
        #expect(result.value == .open(ticket: 51), "got \(result.value)")
        #expect(result.seconds < tkSlack, "Enter waited \(result.seconds) s for a list that was already in (its wait is \(tkWait) s)")
    }

    // MARK: the whole chain: box, ticket, real pipeline, gate

    @MainActor
    @Test func fastTypingThenEnterOpensTheListOfTheTextInTheBoxAtThatMoment() async throws {
        try await spWithPipeline(text: spDescription) { h in
            let fixture = try #require(h.fixture)
            let gate = TicketGate()
            let source = TKTickets(h.pipeline)
            let box = QueryBox(nextTicket: { source.take() })
            box.onChange = { text, ticket in
                gate.boxChanged(text: text, ticket: ticket)
                h.pipeline.submit(text: text, ticket: ticket)
            }
            let log = h.log
            h.pipeline.onRanked = { @Sendable ticket, hits in
                log.ranked(ticket, hits.map { SPHit(path: $0.path, passageID: $0.passageID) })
                let count = hits.count
                Task { @MainActor in gate.rankedListArrived(ticket: ticket, count: count) }
            }

            // one keystroke per character, Enter straight after the last one
            box.type(spDescription)
            let decision = await gate.pressEnter()

            let issued = source.issued
            #expect(issued.count == spDescription.count, "tickets taken: \(issued.count)")
            let last = try #require(issued.last)
            #expect(decision == .open(ticket: last), "Enter decided \(decision), the last keystroke's ticket was \(last)")
            if case .open(let ticket) = decision {
                #expect(ticket == last, "Enter opened ticket \(ticket)")
                // the list it opens is the list of the whole text, in the order the test computed
                #expect(h.log.rankedList(ticket) == fixture.bestFirst,
                        "list of ticket \(ticket): \(String(describing: h.log.rankedList(ticket)?.map(\.path)))")
            }
            #expect(!gate.stillRankingShown)
        }
    }
}

// MARK: Esc, the shortcut and reopening, on the real Panel

@MainActor
private func tkPanelRun(_ body: (Panel, TKEvents) async throws -> Void) async throws {
    _ = NSApplication.shared
    let previous = getenv("SESAME_PROBE_FILE").map { String(cString: $0) }
    unsetenv("SESAME_PROBE_FILE")
    let events = TKEvents()
    Probe.sink = { @Sendable event, ticket in events.add(event, ticket) }
    let panel = Panel()
    defer {
        panel.hide()
        Probe.sink = nil
        if let previous { setenv("SESAME_PROBE_FILE", previous, 1) }
    }
    try await body(panel, events)
}

extension ModelDownloadTests {
    @Suite("PanelKeysTests", .serialized)
    struct PanelKeysTests {

        // MARK: Esc

        @MainActor
        @Test func escClearsTheTextOnTheFirstPressAndClosesOnTheSecond() async throws {
            try await tkPanelRun { panel, _ in
                panel.show()
                #expect(panel.isShown)
                panel.queryBox.type("a dog on the beach")
                #expect(panel.queryBox.text == "a dog on the beach")

                panel.pressEscape()
                #expect(panel.queryBox.text == "", "the first Esc left \"\(panel.queryBox.text)\"")
                #expect(panel.isShown, "the first Esc closed the panel")

                panel.pressEscape()
                #expect(!panel.isShown, "the second Esc did not close the panel")
            }
        }

        @MainActor
        @Test func oneEscClosesAnEmptyBox() async throws {
            try await tkPanelRun { panel, _ in
                panel.show()
                #expect(panel.queryBox.text == "")
                panel.pressEscape()
                #expect(!panel.isShown, "Esc on an empty box did not close the panel")
            }
        }

        @MainActor
        @Test func spacesCountAsTextSoTheFirstEscClearsThemAndTheSecondCloses() async throws {
            try await tkPanelRun { panel, _ in
                panel.show()
                panel.queryBox.type("   ")
                panel.pressEscape()
                #expect(panel.queryBox.text == "")
                #expect(panel.isShown, "Esc on spaces closed the panel at once")
                panel.pressEscape()
                #expect(!panel.isShown)
            }
        }

        @MainActor
        @Test func escClearsAFullBoxOf500CharactersOnTheFirstPress() async throws {
            try await tkPanelRun { panel, _ in
                panel.show()
                panel.queryBox.paste(String(repeating: "x", count: 700))
                #expect(panel.queryBox.text.count == 500)
                panel.pressEscape()
                #expect(panel.queryBox.text == "")
                #expect(panel.isShown)
            }
        }

        @MainActor
        @Test func typingAfterTheFirstEscStartsTheCountAgain() async throws {
            try await tkPanelRun { panel, _ in
                panel.show()
                panel.queryBox.type("cat")
                panel.pressEscape()          // clears
                panel.queryBox.type("dog")
                panel.pressEscape()          // clears again, does not close
                #expect(panel.queryBox.text == "")
                #expect(panel.isShown, "an Esc after new typing closed the panel")
                panel.pressEscape()
                #expect(!panel.isShown)
            }
        }

        @MainActor
        @Test func escEmitsNoShownEventAndTakesNoPartInTheKeyProbe() async throws {
            try await tkPanelRun { panel, events in
                panel.show()
                let before = events.events
                #expect(before == ["shown:0"], "recorded: \(before)")
                panel.pressEscape()          // empty box: closes
                #expect(events.events == before, "Esc emitted \(events.events)")
            }
        }

        // MARK: the shortcut while open

        @MainActor
        @Test func theShortcutOpensAHiddenPanelAndClosesAnOpenOne() async throws {
            try await tkPanelRun { panel, events in
                #expect(!panel.isShown, "a new panel is shown")

                panel.shortcutPressed()
                #expect(panel.isShown, "the shortcut did not open the panel")
                #expect(events.events == ["shown:0"], "recorded: \(events.events)")

                panel.shortcutPressed()
                #expect(!panel.isShown, "the shortcut while open did not close the panel")
                #expect(events.events == ["shown:0"], "closing emitted \(events.events)")

                panel.shortcutPressed()
                #expect(panel.isShown, "the shortcut did not open the panel the second time")
                #expect(events.events == ["shown:0", "shown:0"], "recorded: \(events.events)")
            }
        }

        @MainActor
        @Test func theShortcutClosesAPanelThatHoldsTextAndTheNextOpenIsEmpty() async throws {
            try await tkPanelRun { panel, _ in
                panel.shortcutPressed()
                panel.queryBox.type("a dog on the beach")
                panel.shortcutPressed()      // while open: closes
                #expect(!panel.isShown)
                panel.shortcutPressed()      // opens again
                #expect(panel.isShown)
                #expect(panel.queryBox.text == "", "the reopened box shows \"\(panel.queryBox.text)\"")
            }
        }

        // MARK: reopening shows no old text

        @MainActor
        @Test func reopeningShowsNoOldTextWhicheverWayThePanelWasClosed() async throws {
            try await tkPanelRun { panel, _ in
                // closed by hide() (what Enter does after opening a file)
                panel.show()
                panel.queryBox.type("the clause about pets in the lease")
                panel.hide()
                panel.show()
                #expect(panel.queryBox.text == "", "after hide and show: \"\(panel.queryBox.text)\"")

                // closed by Esc, pressed twice
                panel.queryBox.type("dog")
                panel.pressEscape()
                panel.pressEscape()
                #expect(!panel.isShown)
                panel.show()
                #expect(panel.queryBox.text == "", "after Esc Esc and show: \"\(panel.queryBox.text)\"")

                // a box that was full
                panel.queryBox.paste(String(repeating: "y", count: 600))
                panel.hide()
                panel.show()
                #expect(panel.queryBox.text == "")
            }
        }

        @MainActor
        @Test func thePanelKeepsOneQueryBoxForGood() async throws {
            try await tkPanelRun { panel, _ in
                let first = panel.queryBox
                panel.show()
                panel.hide()
                panel.show()
                #expect(panel.queryBox === first, "the panel built a second box")
            }
        }
    }

    // MARK: Start with no folder (spec S6; carry-over of the t28 report)

    @Suite("StartWithNoFolderTests", .serialized)
    struct StartWithNoFolderTests {

        @MainActor
        @Test func startIsAllowedWithNoFolderPickedOnceTheModelIsWholeAndNotBefore() async throws {
            try await spWithHome { home in
                let fm = FileManager.default
                let folder = home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
                let models = folder.appendingPathComponent("models", isDirectory: true)
                try fm.createDirectory(at: models, withIntermediateDirectories: true)

                let bytes = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let file = ModelFile(name: "tk-whole.gguf", size: bytes.count, sha256: hash)

                let starts = TKCounter()
                let model = SetupModel(files: [file], onStart: { starts.bump() })
                model.refresh()
                #expect(model.pickedFolders.isEmpty)

                // not whole: nothing downloaded yet, still no Start
                #expect(!model.canStartIndexing, "Start is available with no model")
                model.startIndexing()
                #expect(starts.value == 0, "Start pressed with no model called the hook")

                // whole, and no folder picked: Start is allowed
                try bytes.write(to: models.appendingPathComponent(file.name))
                model.refresh()
                #expect(model.canStartIndexing, "the model is whole, yet Start is unavailable because no folder is picked")

                model.startIndexing()
                #expect(starts.value == 1, "the Start hook was called \(starts.value) times")

                let data = try Data(contentsOf: folder.appendingPathComponent("settings.json"))
                let onDisk = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
                #expect(onDisk["startPressed"] as? Bool == true, "startPressed on disk: \(String(describing: onDisk["startPressed"]))")
                #expect((onDisk["folders"] as? [Any])?.count == 0, "folders on disk: \(String(describing: onDisk["folders"]))")
            }
        }
    }
}

// MARK: the screen choice: which view the panel shows for the inputs

private let tkAllKinds: Set<String> = ["photo", "pdf", "doc", "audio", "video"]
private let tkWalkDone = Date(timeIntervalSince1970: 1_700_000_000)
private let tkDone = IndexCounts(done: 4, pending: [:], partial: [:])
private let tkSome = IndexCounts(done: 1, pending: ["photo": 2], partial: ["pdf": 1])    // 1 of 4: 25%
private let tkNoRows = IndexCounts(done: 0, pending: [:], partial: [:])

private let tkHintText = "Describe what you want, or type part of a name or text."
private let tkSamples = ["a dog on the beach", "the clause about pets in the lease", "where they talk about sleep"]

private func tkInputs(
    model: ModelState = .whole,
    startPressed: Bool = true,
    indexDeleted: Bool = false,
    walkDoneAt: Date? = tkWalkDone,
    counts: IndexCounts = tkDone,
    vectorSourceOK: Bool = true,
    typed: String = "dog on the beach",
    rankedCount: Int? = 3
) -> PanelInputs {
    PanelInputs(
        model: model, startPressed: startPressed, indexDeleted: indexDeleted,
        walkDoneAt: walkDoneAt, counts: counts, vectorSourceOK: vectorSourceOK,
        kindsOn: tkAllKinds, typed: typed, rankedCount: rankedCount)
}

// One word per body, so a failure reads plainly.
private func tkWord(_ body: PanelScreen.Body) -> String {
    switch body {
    case .notReady: return "notReady"
    case .emptyHint: return "emptyHint"
    case .searching: return "searching"
    case .noMatches: return "noMatches"
    case .rows: return "rows"
    case .searchFailed: return "searchFailed"
    }
}

@Suite("PanelScreenTests")
struct PanelScreenTests {

    // MARK: the fixed texts

    @Test func theSearchingAndStillRankingTextsAreExact() {
        #expect(PanelScreen.searchingText == "Searching")
        #expect(PanelScreen.stillRankingText == "Still ranking")
    }

    // MARK: NotReadyView replaces everything

    @Test func eachNotReadyStateShowsItsNotReadyViewWithTheFixedTextAndNoBanner() {
        let cases: [(inputs: PanelInputs, text: String)] = [
            (tkInputs(model: .downloading, typed: "dog", rankedCount: nil), "The model is still downloading"),
            (tkInputs(model: .damaged, typed: "", rankedCount: nil), "The model file was damaged and is downloading again"),
            (tkInputs(startPressed: false, walkDoneAt: nil, counts: tkNoRows, typed: "", rankedCount: nil), "Indexing has not been started"),
            (tkInputs(startPressed: false, indexDeleted: true, walkDoneAt: nil, counts: tkNoRows, typed: "", rankedCount: nil), "Nothing is indexed yet"),
            (tkInputs(walkDoneAt: tkWalkDone, counts: tkNoRows, typed: "zzqx", rankedCount: 0), "Nothing is indexed yet"),
        ]
        for (inputs, text) in cases {
            let screen = PanelScreen.choose(inputs, keywordRows: 0)
            guard case .notReady(let view) = screen.body else {
                Issue.record("expected NotReadyView for \"\(text)\", got \(tkWord(screen.body))")
                continue
            }
            #expect(view.heading == "Not ready yet")
            #expect(view.text == text)
            #expect(screen.banner == nil, "a banner above a Not ready screen")
            #expect(screen.status == nil)
        }
    }

    @Test func aNotReadyScreenShowsNoRowsAndNoSearchingLineWhateverWasTyped() {
        for typed in ["", "dog", "   "] {
            for rankedCount in [nil, 0, 3] as [Int?] {
                for keywordRows in [0, 2] {
                    let screen = PanelScreen.choose(tkInputs(model: .downloading, typed: typed, rankedCount: rankedCount),
                                                    keywordRows: keywordRows)
                    #expect(tkWord(screen.body) == "notReady",
                            "typed \"\(typed)\" ranked \(String(describing: rankedCount)) keyword \(keywordRows): \(tkWord(screen.body))")
                }
            }
        }
    }

    // MARK: IndexingBanner above a usable panel

    @Test func stillIndexingShowsTheBannerAboveTheBodyAndTheBodyStaysUsable() {
        // 1 of 4 done, 25 percent: typed text with a ranked list in shows rows under the banner
        let withRows = PanelScreen.choose(tkInputs(counts: tkSome, typed: "dog", rankedCount: 3), keywordRows: 0)
        #expect(withRows.banner?.title == "Still indexing (25%)", "banner: \(String(describing: withRows.banner?.title))")
        #expect(withRows.banner?.percent == 25)
        #expect(tkWord(withRows.body) == "rows", "body: \(tkWord(withRows.body))")

        // an empty box under the banner is the hint, not a Not ready screen
        let empty = PanelScreen.choose(tkInputs(counts: tkSome, typed: "", rankedCount: nil), keywordRows: 0)
        #expect(empty.banner != nil)
        #expect(tkWord(empty.body) == "emptyHint", "body: \(tkWord(empty.body))")

        // a search that is still running under the banner shows the quiet line
        let waiting = PanelScreen.choose(tkInputs(counts: tkSome, typed: "dog", rankedCount: nil), keywordRows: 0)
        #expect(waiting.banner != nil)
        #expect(tkWord(waiting.body) == "searching", "body: \(tkWord(waiting.body))")
    }

    @Test func theBannerCarriesTheMayBeMissingLine() {
        let screen = PanelScreen.choose(tkInputs(counts: tkSome, typed: "dog", rankedCount: 3), keywordRows: 0)
        #expect(screen.banner?.missing.hasPrefix("May be missing: ") == true, "missing: \(String(describing: screen.banner?.missing))")
    }

    @Test func atZeroFilesReadTheBannerReadsZeroPercentAndTheListHoldsNoRows() {
        for typed in ["dog", "a dog on the beach"] {
            for rankedCount in [nil, 0] as [Int?] {
                let screen = PanelScreen.choose(
                    tkInputs(walkDoneAt: nil, counts: tkNoRows, typed: typed, rankedCount: rankedCount), keywordRows: 0)
                #expect(screen.banner?.title == "Still indexing (0%)", "banner: \(String(describing: screen.banner?.title))")
                let word = tkWord(screen.body)
                #expect(word != "rows" && word != "notReady", "typed \"\(typed)\": body \(word)")
            }
        }
        let empty = PanelScreen.choose(tkInputs(walkDoneAt: nil, counts: tkNoRows, typed: "", rankedCount: nil), keywordRows: 0)
        #expect(empty.banner?.title == "Still indexing (0%)")
        #expect(tkWord(empty.body) == "emptyHint")
    }

    @Test func noBannerWhenIndexingIsDone() {
        let screen = PanelScreen.choose(tkInputs(counts: tkDone, typed: "dog", rankedCount: 3), keywordRows: 0)
        #expect(screen.banner == nil)
        #expect(tkWord(screen.body) == "rows")
    }

    // MARK: EmptyHint

    @Test func anEmptyOrSpacesOnlyBoxShowsTheEmptyHintWithItsThreeSamples() {
        for typed in ["", " ", "     "] {
            let screen = PanelScreen.choose(tkInputs(typed: typed, rankedCount: nil), keywordRows: 0)
            guard case .emptyHint(let hint) = screen.body else {
                Issue.record("typed \"\(typed)\": expected EmptyHint, got \(tkWord(screen.body))")
                continue
            }
            #expect(hint.text == tkHintText)
            #expect(hint.samples == tkSamples, "samples: \(hint.samples)")
            #expect(hint.samples.count == 3)
            #expect(screen.banner == nil)
        }
    }

    @Test func spacesOnlyShowTheHintAndNeverNoMatchesEvenWithAnEmptyRankedList() {
        let screen = PanelScreen.choose(tkInputs(typed: "   ", rankedCount: 0), keywordRows: 0)
        #expect(tkWord(screen.body) == "emptyHint", "got \(tkWord(screen.body))")
    }

    // MARK: Searching, keyword rows at once, NoMatches

    @Test func aDescriptionWhoseRankedListIsNotInShowsOnlyTheQuietSearchingLine() {
        let screen = PanelScreen.choose(tkInputs(typed: "a dog on the beach", rankedCount: nil), keywordRows: 0)
        #expect(tkWord(screen.body) == "searching", "got \(tkWord(screen.body))")
        #expect(screen.banner == nil)
        #expect(screen.status == nil)
    }

    @Test func aTierOnePhraseHitShowsItsKeywordRowsAtOnceBeforeTheRankedListIsIn() {
        let screen = PanelScreen.choose(tkInputs(typed: "pier lights", rankedCount: nil), keywordRows: 2)
        #expect(tkWord(screen.body) == "rows", "got \(tkWord(screen.body))")
    }

    @Test func noMatchesNeverShowsBeforeTheRankedListIsInWhateverTheKeywordMatchFound() {
        for keywordRows in [0, 1, 5] {
            let screen = PanelScreen.choose(tkInputs(typed: "zzqx", rankedCount: nil), keywordRows: keywordRows)
            #expect(tkWord(screen.body) != "noMatches", "keyword rows \(keywordRows): \(tkWord(screen.body))")
        }
    }

    @Test func aRankedListThatIsInAndEmptyShowsNoMatchesWithItsTextAndHint() {
        let screen = PanelScreen.choose(tkInputs(typed: "zzqx", rankedCount: 0), keywordRows: 0)
        guard case .noMatches(let view) = screen.body else {
            Issue.record("expected NoMatches, got \(tkWord(screen.body))")
            return
        }
        #expect(view.title == "No matches")
        #expect(view.hint == "Describe what is in the file, or type part of its exact name or text.")
    }

    @Test func aRankedListThatIsInReplacesTheSearchingLineWithRows() {
        let screen = PanelScreen.choose(tkInputs(typed: "dog", rankedCount: 1), keywordRows: 0)
        #expect(tkWord(screen.body) == "rows", "got \(tkWord(screen.body))")
        #expect(PanelScreen.choose(tkInputs(typed: "dog", rankedCount: 40), keywordRows: 3).body == .rows)
    }

    // MARK: Still ranking, the note after Enter gave up

    @Test func stillRankingShowsItsNoteOnlyWhenAskedAndTextIsTypedAndKeepsTheSearchingLine() {
        let asked = PanelScreen.choose(tkInputs(typed: "a dog on the beach", rankedCount: nil), keywordRows: 0, stillRanking: true)
        #expect(asked.status == "Still ranking", "status: \(String(describing: asked.status))")
        #expect(tkWord(asked.body) == "searching", "the body changed to \(tkWord(asked.body))")

        let notAsked = PanelScreen.choose(tkInputs(typed: "a dog on the beach", rankedCount: nil), keywordRows: 0, stillRanking: false)
        #expect(notAsked.status == nil)

        let noText = PanelScreen.choose(tkInputs(typed: "", rankedCount: nil), keywordRows: 0, stillRanking: true)
        #expect(noText.status == nil, "Still ranking with nothing typed: \(String(describing: noText.status))")
    }

    // MARK: the views carry the texts of PanelState (t25), not their own

    @Test func theViewsCarryTheSamePayloadsAsPanelState() {
        let hintInputs = tkInputs(typed: "", rankedCount: nil)
        if case .emptyHint(let fromState) = PanelState.evaluate(hintInputs),
           case .emptyHint(let fromScreen) = PanelScreen.choose(hintInputs, keywordRows: 0).body {
            #expect(fromScreen == fromState)
        } else {
            Issue.record("EmptyHint missing from PanelState or from the screen")
        }

        let noneInputs = tkInputs(typed: "zzqx", rankedCount: 0)
        if case .noMatches(let fromState) = PanelState.evaluate(noneInputs),
           case .noMatches(let fromScreen) = PanelScreen.choose(noneInputs, keywordRows: 0).body {
            #expect(fromScreen == fromState)
        } else {
            Issue.record("NoMatches missing from PanelState or from the screen")
        }

        let notReadyInputs = tkInputs(startPressed: false, walkDoneAt: nil, counts: tkNoRows, typed: "", rankedCount: nil)
        if case .notReady(let fromState) = PanelState.evaluate(notReadyInputs),
           case .notReady(let fromScreen) = PanelScreen.choose(notReadyInputs, keywordRows: 0).body {
            #expect(fromScreen == fromState)
        } else {
            Issue.record("NotReadyView missing from PanelState or from the screen")
        }

        let indexingInputs = tkInputs(counts: tkSome)
        if case .indexing(let fromState) = PanelState.evaluate(indexingInputs) {
            #expect(PanelScreen.choose(indexingInputs, keywordRows: 0).banner == fromState)
        } else {
            Issue.record("IndexingBanner missing from PanelState")
        }
    }

    @Test func theSameInputsGiveTheSameScreen() {
        let a = PanelScreen.choose(tkInputs(counts: tkSome, typed: "dog", rankedCount: nil), keywordRows: 1, stillRanking: true)
        let b = PanelScreen.choose(tkInputs(counts: tkSome, typed: "dog", rankedCount: nil), keywordRows: 1, stillRanking: true)
        #expect(a == b)
    }
}

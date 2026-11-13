import Foundation
import Testing
@testable import Sesame

// plan-2-t37, tester step (1 of 2): `ChangeDebouncer`, the pure rule that turns a stream of file-change events into at
// most one "sync needed" request (S7.6, S7.7, S7.15). Written from the t37 entry (its Tests paragraph), design section 8
// ("Change searchable within 30 s: FSEvents, 2 s debounce, a file modified under 2 s ago waits, metadata-only sync") and
// design section 3 only. No product source was read. Every time, count and flag below is written by hand from the
// events each test builds.
//
// API SHAPES these tests pin. The entry names `ChangeDebouncer`, "a manual clock" and "each event carries the file's
// modified time", and fixes no signatures; these are this file's picks. If a shape is wrong, ask for a test change
// rather than guessing.
//   1. `ChangeEvent` (new, in the `Sesame` target, shared with FolderWatcherTests.swift):
//        struct ChangeEvent: Equatable, Sendable { var path: String; var modified: Date? }
//        memberwise init `ChangeEvent(path:modified:)`.
//      `path` is the full path of the file or folder that changed. `modified` is its modified time read at the moment
//      of the event, and nil when there is none (the file is gone: a delete, or the old name after a rename).
//   2. `ChangeDebouncer` is a value type (a struct; the tests hold it in a `var`), not tied to an actor, with no clock of
//      its own: every call that depends on time takes `now`. The manual clock is the `now` the test passes.
//        init(roots: [String])
//        var roots: [String]                              // the watched folders, as `settings.json` writes them
//        mutating func record(_ event: ChangeEvent, at now: Date)
//        var dueDate: Date? { get }                       // when the pending request is due; nil while nothing is pending
//        mutating func takeDue(at now: Date) -> Bool      // true exactly once per request, when `now` has reached
//                                                         // `dueDate`; it then leaves nothing pending. False otherwise,
//                                                         // and then it changes nothing.
//   3. The rule. An event is kept when its path is a watched root or lies under one (a path component boundary:
//      "/w/photosX/a.jpg" is NOT under "/w/photos"; a root written with a trailing slash matches the same paths); any
//      other event is dropped without trace (it neither creates nor restarts a wait). While a request is pending its due
//      date is the later of (the arrival time of the last kept event + 2 s) and (the latest `modified` among the kept
//      events since the last request + 2 s); an event whose `modified` is nil adds nothing to the second term. A request
//      is therefore due 2 s after the last event, and a file whose modified time is under 2 s before the decision (the
//      decision is at last-event + 2 s) pushes the decision to its modified time + 2 s. `takeDue` clears the pending
//      state, the remembered modified times included.
//   Time margins: the tests never sit on the exact boundary; they check 1 ms before and 1 ms after it.
// Not pinned, on purpose: the type of `roots` storage, thread safety, what happens to a pending request when `roots`
// changes, case folding of paths.
// CHANGED BY plan-2 fix round A (item A4, finding "one pending sync request can be held indefinitely"): the cap on a
// `modified` time far in the future is now pinned, and so is a maximum wait. See ChangeDebouncerMaxWaitTests.swift: a
// modified time later than the event's arrival counts as the arrival, and a request is due no later than 30 s after the
// FIRST event of the request. The rows of this file whose modified time was after the event's arrival were changed to
// match (marked "re-sealed" below); every other row is as sealed.

private let cdBase = Date(timeIntervalSinceReferenceDate: 100_000)

private func cdAt(_ seconds: Double) -> Date { cdBase.addingTimeInterval(seconds) }

private func cdEvent(_ path: String, modified: Double?) -> ChangeEvent {
    ChangeEvent(path: path, modified: modified.map { cdAt($0) })
}

private func cdIs(_ date: Date?, _ seconds: Double) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince(cdBase) - seconds) < 0.0005
}

private func cdSeconds(_ date: Date?) -> String {
    guard let date else { return "nil" }
    return String(format: "%.4f", date.timeIntervalSince(cdBase))
}

// `takeDue` mutates, and #expect cannot call a mutating member inside its expansion, so the call is made here.
private func cdTake(_ d: inout ChangeDebouncer, at seconds: Double) -> Bool {
    d.takeDue(at: cdAt(seconds))
}

private func cdExpectTaken(_ d: inout ChangeDebouncer, at seconds: Double, _ message: Comment,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    let taken = cdTake(&d, at: seconds)
    #expect(taken, message, sourceLocation: sourceLocation)
}

private func cdExpectNotTaken(_ d: inout ChangeDebouncer, at seconds: Double, _ message: Comment,
                              sourceLocation: SourceLocation = #_sourceLocation) {
    let taken = cdTake(&d, at: seconds)
    #expect(taken == false, message, sourceLocation: sourceLocation)
}

private let cdRoot = "/w/photos"

@Suite("ChangeDebouncerTests")
@MainActor
struct ChangeDebouncerTests {

    // MARK: one event

    @Test func aSyncRequestIsDueTwoSecondsAfterTheLastEvent() {
        var d = ChangeDebouncer(roots: [cdRoot])
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        #expect(cdIs(d.dueDate, 2), "due \(cdSeconds(d.dueDate)) s, expected 2 s")
        cdExpectNotTaken(&d, at: 1.999, "taken before the 2 s were over")
        #expect(cdIs(d.dueDate, 2), "a refused take changed the due date to \(cdSeconds(d.dueDate))")
        cdExpectTaken(&d, at: 2.001, "not due 2 s after the event")
        cdExpectNotTaken(&d, at: 2.002, "the same request was taken twice")
        #expect(d.dueDate == nil, "a taken request left a due date: \(cdSeconds(d.dueDate))")
    }

    @Test func nothingPendingIsNeverDue() {
        var d = ChangeDebouncer(roots: [cdRoot])
        #expect(d.dueDate == nil)
        cdExpectNotTaken(&d, at: 0, "a request came out of nothing")
        cdExpectNotTaken(&d, at: 1_000, "a request came out of nothing")
        #expect(d.dueDate == nil)
    }

    // (name, modified offset from the event's arrival in seconds, expected due offset). The decision is at arrival + 2 s;
    // a file modified under 2 s before it waits until its modified time + 2 s.
    private static let modifiedTable: [(String, Double?, Double)] = [
        ("modified long ago", -60, 2),
        ("modified 2 s before the event", -2, 2),
        ("modified 0.5 s before the event", -0.5, 2),
        ("modified at the event", 0, 2),
        // plan-2 fix round A, A4 (re-sealed by that round's tester): a modified time LATER than the event's arrival counts as the
        // arrival, so these three rows (2.5, 3.5 and 7 before) are due 2 s after the event. The old values pinned finding A4(a):
        // a modified time years ahead held the request for years.
        ("modified 0.5 s after the event", 0.5, 2),
        ("modified 1.5 s after the event", 1.5, 2),
        ("modified 5 s after the event", 5, 2),
        ("a file that is gone, no modified time", nil, 2),
    ]

    @Test func aFileModifiedUnderTwoSecondsBeforeTheDecisionWaitsUntilItsModifiedTimePlusTwo() {
        for (name, modified, due) in Self.modifiedTable {
            var d = ChangeDebouncer(roots: [cdRoot])
            d.record(cdEvent("\(cdRoot)/a.jpg", modified: modified), at: cdAt(0))
            #expect(cdIs(d.dueDate, due), "\(name): due \(cdSeconds(d.dueDate)) s, expected \(due) s")
            cdExpectNotTaken(&d, at: due - 0.001, "\(name): taken 1 ms before \(due) s")
            cdExpectTaken(&d, at: due + 0.001, "\(name): not taken 1 ms after \(due) s")
            cdExpectNotTaken(&d, at: due + 5, "\(name): taken twice")
        }
    }

    @Test func theLatestModifiedTimeAmongThePendingEventsGovernsTheWait() {
        var d = ChangeDebouncer(roots: [cdRoot])
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -10), at: cdAt(0))
        // plan-2 fix round A, A4 (re-sealed): b.jpg's modified time (2.0 s) is later than its event's arrival (0.5 s), so it
        // counts as the arrival, 0.5 s: due 2.5 s (it was 4 s, which pinned finding A4(a)). The later event at 1.0 s moves it to 3 s.
        d.record(cdEvent("\(cdRoot)/b.jpg", modified: 2.0), at: cdAt(0.5))
        #expect(cdIs(d.dueDate, 2.5), "b.jpg's modified time is after its event, so it counts as the event's arrival, 0.5 s; due 2.5 s; got \(cdSeconds(d.dueDate))")
        d.record(cdEvent("\(cdRoot)/c.jpg", modified: -10), at: cdAt(1.0))
        #expect(cdIs(d.dueDate, 3), "a later event for an old file: due 2 s after it, 3 s; got \(cdSeconds(d.dueDate))")
        cdExpectNotTaken(&d, at: 2.999, "taken before 2 s after the last event")
        cdExpectTaken(&d, at: 3.001, "not taken 2 s after the last event")
    }

    // MARK: bursts

    @Test func aThousandEventsInsideTwoSecondsMakeOneRequestNotAThousand() {
        var d = ChangeDebouncer(roots: [cdRoot])
        var requests = 0
        var last = 0.0
        for i in 0..<1000 {
            last = Double(i) * 0.0019            // the last event is at 1.8981 s
            d.record(cdEvent("\(cdRoot)/img-\(i).jpg", modified: last - 60), at: cdAt(last))
            if cdTake(&d, at: last) { requests += 1 }
        }
        #expect(requests == 0, "a request came out while the events were still arriving: \(requests)")
        cdExpectNotTaken(&d, at: last + 1.999, "taken before 2 s of quiet")
        if cdTake(&d, at: last + 2.001) { requests += 1 }
        for step in 0..<200 where cdTake(&d, at: last + 3 + Double(step)) { requests += 1 }
        #expect(requests == 1, "1,000 events made \(requests) requests, expected 1")
        #expect(d.dueDate == nil)
    }

    @Test func aNewEventRestartsTheWait() {
        var d = ChangeDebouncer(roots: [cdRoot])
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        d.record(cdEvent("\(cdRoot)/b.jpg", modified: -60), at: cdAt(1.5))
        #expect(cdIs(d.dueDate, 3.5), "due \(cdSeconds(d.dueDate)) s, expected 3.5 s (2 s after the second event)")
        cdExpectNotTaken(&d, at: 2.001, "the first event's 2 s ended it, the second event did not restart the wait")
        cdExpectNotTaken(&d, at: 3.499, "taken before 2 s after the second event")
        cdExpectTaken(&d, at: 3.501, "not taken 2 s after the second event")
        cdExpectNotTaken(&d, at: 60, "taken twice")
    }

    @Test func aSteadyTrickleOfEventsHoldsTheRequestBackUntilTwoSecondsAfterTheLast() {
        var d = ChangeDebouncer(roots: [cdRoot])
        var early = 0
        for second in 0..<10 {
            d.record(cdEvent("\(cdRoot)/log.txt", modified: Double(second) - 0.1), at: cdAt(Double(second)))
            if cdTake(&d, at: Double(second) + 0.5) { early += 1 }
            if cdTake(&d, at: Double(second) + 0.99) { early += 1 }
        }
        #expect(early == 0, "\(early) requests came while an event arrived every second")
        cdExpectNotTaken(&d, at: 10.999, "the last event was at 9 s, 2 s of quiet end at 11 s")
        cdExpectTaken(&d, at: 11.001, "not taken 2 s after the last event")
    }

    @Test func afterARequestANewEventMakesANewRequestWithItsOwnWait() {
        var d = ChangeDebouncer(roots: [cdRoot])
        // plan-2 fix round A, A4 (re-sealed): modified far ahead of the event counts as the event's arrival, so due 2 s
        // (it was 102 s, which pinned finding A4(a)).
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: 100), at: cdAt(0))      // modified far ahead of the event
        #expect(cdIs(d.dueDate, 2), "due \(cdSeconds(d.dueDate)) s, expected 2 s")
        cdExpectTaken(&d, at: 2.001, "not taken 2 s after the event")
        d.record(cdEvent("\(cdRoot)/b.jpg", modified: 90), at: cdAt(110))
        #expect(cdIs(d.dueDate, 112), "due \(cdSeconds(d.dueDate)) s, expected 112 s (2 s after the new event)")
        cdExpectNotTaken(&d, at: 111.999, "taken before 2 s after the new event")
        cdExpectTaken(&d, at: 112.001, "not taken 2 s after the new event")
        cdExpectNotTaken(&d, at: 500, "taken twice")
        d.record(cdEvent("\(cdRoot)/c.jpg", modified: -60), at: cdAt(600))
        #expect(cdIs(d.dueDate, 602), "a third burst: due \(cdSeconds(d.dueDate)) s")
    }

    // MARK: only watched folders

    @Test func eventsForAFolderThatIsNotWatchedAreDropped() {
        var d = ChangeDebouncer(roots: [cdRoot])
        let outside = [
            "/w/other/a.jpg",             // another folder
            "/w/photosX/a.jpg",           // shares the text prefix, not the folder
            "/w/photos-old/a.jpg",
            "/w/a.jpg",                   // the parent of the root
            "/w",
            "/elsewhere/w/photos/a.jpg",  // the root's text inside another path
        ]
        for (index, path) in outside.enumerated() {
            d.record(cdEvent(path, modified: -60), at: cdAt(Double(index)))
        }
        #expect(d.dueDate == nil, "an event outside every watched folder made a request due at \(cdSeconds(d.dueDate)) s")
        cdExpectNotTaken(&d, at: 1_000, "a request for events of folders that are not watched")
    }

    @Test func aDroppedEventNeitherStartsNorRestartsTheWait() {
        var d = ChangeDebouncer(roots: [cdRoot])
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        d.record(cdEvent("/w/other/b.jpg", modified: -60), at: cdAt(1.5))
        d.record(cdEvent("/w/other/c.jpg", modified: 50), at: cdAt(1.9))     // a recent file, but of an unwatched folder
        #expect(cdIs(d.dueDate, 2), "an event of an unwatched folder moved the due date to \(cdSeconds(d.dueDate)) s")
        cdExpectTaken(&d, at: 2.001, "not taken 2 s after the one watched event")
    }

    @Test func filesInSubfoldersAndTheRootItselfAreWatched() {
        for path in ["\(cdRoot)/a.jpg", "\(cdRoot)/sub/deeper/b.png", cdRoot] {
            var d = ChangeDebouncer(roots: [cdRoot])
            d.record(cdEvent(path, modified: -60), at: cdAt(0))
            #expect(cdIs(d.dueDate, 2), "\(path): due \(cdSeconds(d.dueDate)) s, expected 2 s")
        }
    }

    @Test func aRootWrittenWithATrailingSlashWatchesTheSameFolder() {
        var d = ChangeDebouncer(roots: ["\(cdRoot)/"])
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        #expect(cdIs(d.dueDate, 2), "due \(cdSeconds(d.dueDate)) s")
        cdExpectTaken(&d, at: 2.001, "not taken 2 s after the event")
        d.record(cdEvent("\(cdRoot)X/a.jpg", modified: -60), at: cdAt(10))
        #expect(d.dueDate == nil, "a sibling folder was taken for a child of the root")
    }

    @Test func settingTheRootsChangesWhatIsWatched() {
        var d = ChangeDebouncer(roots: [cdRoot])
        d.roots = ["/w/scans"]
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        #expect(d.dueDate == nil, "an event of a folder that is no longer watched was kept")
        d.record(cdEvent("/w/scans/b.jpg", modified: -60), at: cdAt(1))
        #expect(cdIs(d.dueDate, 3), "due \(cdSeconds(d.dueDate)) s, expected 3 s")
        d.roots = []
        d.record(cdEvent("/w/scans/c.jpg", modified: -60), at: cdAt(5))
        #expect(cdIs(d.dueDate, 3), "with no roots an event moved the due date to \(cdSeconds(d.dueDate)) s")
        var empty = ChangeDebouncer(roots: [])
        empty.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        #expect(empty.dueDate == nil, "a debouncer with no roots kept an event")
    }

    @Test func eventsOfTwoWatchedFoldersShareOneRequest() {
        var d = ChangeDebouncer(roots: [cdRoot, "/w/scans"])
        d.record(cdEvent("\(cdRoot)/a.jpg", modified: -60), at: cdAt(0))
        d.record(cdEvent("/w/scans/b.pdf", modified: -60), at: cdAt(1))
        d.record(cdEvent("\(cdRoot)/c.jpg", modified: -60), at: cdAt(1.2))
        #expect(cdIs(d.dueDate, 3.2), "due \(cdSeconds(d.dueDate)) s, expected 3.2 s")
        var requests = 0
        for step in 0..<100 where cdTake(&d, at: Double(step) * 0.1) { requests += 1 }
        #expect(requests == 1, "\(requests) requests for events of two folders in one burst")
    }
}

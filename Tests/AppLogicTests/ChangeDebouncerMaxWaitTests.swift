import Foundation
import Testing
@testable import Sesame

// plan-2 fix round A, tester step: item A4 (S7.6, S7.7, S7.15). Written from the fix-round entry A4, the reviewer's finding
// ("one pending sync request can be held indefinitely") and ChangeDebouncerTests.swift (same shapes, same manual clock).
// No product source read.
//
// What the entry fixes (every time below is written by hand):
//   (a) a modified time later than the event's arrival counts as the arrival, so a file stamped a year ahead gives a
//       request due 2 s after the event, not a year;
//   (b) in every case a request is due no later than 30 s after the FIRST event of the request: an absolute maximum wait.
//       A file written every second therefore makes a request at 30 s, and the request after it starts clean, with its own
//       30 s counted from ITS first event.
// Rule in one line: due = min(last kept event's arrival + 2 s, first event's arrival + 30 s), a modified time after its
// event's arrival being read as that arrival (so the modified-time term can never push the date later than the last
// arrival + 2 s; the entry words it as "the later of (last arrival + 2 s) and (min(modified, arrival) + 2 s), capped").
//
// SHAPE PINNED FOR THE FIXER (no test refers to it, the tests use the hand value 30): a named constant in
// Sources/Sesame/ChangeDebouncer.swift, `static let maximumWait: TimeInterval = 30` on `ChangeDebouncer`. The API of the
// sealed ChangeDebouncerTests is unchanged (`init(roots:)`, `record(_:at:)`, `dueDate`, `takeDue(at:)`); no test here needs
// a new name, so each one fails today at run time for the stated reason.
//
// The earlier ChangeDebouncerTests and FolderWatcherTests rows stay true except the ones that pinned the bug: five
// values were changed there and marked "re-sealed" (the three modified-after-arrival rows of `modifiedTable`, the
// "latest modified" test and "afterARequest..." in ChangeDebouncerTests, one row in FolderWatcherTests).

private let mwBase = Date(timeIntervalSinceReferenceDate: 100_000)
private let mwRoot = "/w/photos"

private func mwAt(_ seconds: Double) -> Date { mwBase.addingTimeInterval(seconds) }

private func mwEvent(_ name: String, modified: Double?) -> ChangeEvent {
    ChangeEvent(path: "\(mwRoot)/\(name)", modified: modified.map { mwAt($0) })
}

private func mwDue(_ d: ChangeDebouncer) -> Double? {
    d.dueDate.map { $0.timeIntervalSince(mwBase) }
}

private func mwDescribe(_ d: ChangeDebouncer) -> String {
    guard let due = mwDue(d) else { return "nil" }
    return String(format: "%.4f", due)
}

private func mwTake(_ d: inout ChangeDebouncer, at seconds: Double) -> Bool {
    d.takeDue(at: mwAt(seconds))
}

@Suite("ChangeDebouncerMaxWaitTests")
@MainActor
struct ChangeDebouncerMaxWaitTests {

    // MARK: (a) a modified time ahead of the event

    @Test func aModifiedTimeOneYearAheadGivesARequestDueTwoSecondsAfterTheEvent() {
        let year: Double = 365 * 24 * 3600
        var d = ChangeDebouncer(roots: [mwRoot])
        d.record(mwEvent("camera-clock.jpg", modified: year), at: mwAt(0))
        #expect(mwDue(d).map { abs($0 - 2) < 0.0005 } == true, "a file stamped a year ahead: due \(mwDescribe(d)) s, expected 2 s")
        #expect(mwTake(&d, at: 1.999) == false, "taken before 2 s")
        #expect(mwTake(&d, at: 2.001), "not due 2 s after the event: a modified time ahead of the arrival must count as the arrival")
        #expect(mwTake(&d, at: 2.002) == false, "the same request was taken twice")
        #expect(d.dueDate == nil, "a taken request left a due date: \(mwDescribe(d))")
    }

    @Test(arguments: [0.001, 0.5, 5.0, 29.0, 3600.0, 86_400.0 * 400])
    func aModifiedTimeAfterTheEventsArrivalCountsAsTheArrival(ahead: Double) {
        var d = ChangeDebouncer(roots: [mwRoot])
        d.record(mwEvent("a.jpg", modified: ahead), at: mwAt(0))
        #expect(mwDue(d).map { abs($0 - 2) < 0.0005 } == true, "modified \(ahead) s after the event: due \(mwDescribe(d)) s, expected 2 s")
    }

    @Test func aFarFutureFileAmongOrdinaryEventsDoesNotHoldTheRequestBack() {
        var d = ChangeDebouncer(roots: [mwRoot])
        d.record(mwEvent("old.jpg", modified: -60), at: mwAt(0))
        d.record(mwEvent("stamped-ahead.jpg", modified: 4_000_000_000), at: mwAt(0.5))
        d.record(mwEvent("new.jpg", modified: -1), at: mwAt(1))
        #expect(mwDue(d).map { abs($0 - 3) < 0.0005 } == true, "three events, the last at 1 s: due \(mwDescribe(d)) s, expected 3 s")
        #expect(mwTake(&d, at: 3.001), "not taken 2 s after the last event")
    }

    @Test func aNewRequestAfterAFarFutureOneStartsClean() {
        var d = ChangeDebouncer(roots: [mwRoot])
        d.record(mwEvent("stamped-ahead.jpg", modified: 4_000_000_000), at: mwAt(0))
        #expect(mwTake(&d, at: 2.001), "the far-future request was never due")
        d.record(mwEvent("b.jpg", modified: -60), at: mwAt(100))
        #expect(mwDue(d).map { abs($0 - 102) < 0.0005 } == true, "the next request: due \(mwDescribe(d)) s, expected 102 s")
        #expect(mwTake(&d, at: 102.001), "not taken 2 s after the new event")
    }

    // MARK: (b) an absolute maximum wait of 30 s from the first event

    @Test func oneEventPerSecondForOneHundredSecondsMakesARequestAt30sAndEveryNextRequestStartsClean() {
        var d = ChangeDebouncer(roots: [mwRoot])
        var taken: [Double] = []
        // an event at each whole second 0 to 99; the clock is looked at half a second after each event
        for second in 0..<100 {
            let t = Double(second)
            d.record(mwEvent("log.txt", modified: t - 0.1), at: mwAt(t))
            if second == 31 {
                // the request of events 0 to 30 was taken at 30.5; the event at 31 starts a new request, due 2 s after it
                #expect(mwDue(d).map { abs($0 - 33) < 0.0005 } == true, "the request after the first started with a stale date: due \(mwDescribe(d)) s, expected 33 s")
            }
            if mwTake(&d, at: t + 0.5) { taken.append(t + 0.5) }
        }
        // the first request is the one the 30 s cap makes due; nothing is taken earlier while events keep coming
        #expect(taken.first.map { abs($0 - 30.5) < 0.0005 } == true, "the first request came at \(taken.first.map { String($0) } ?? "never") s, expected within the 30 s cap (30.5 s at the half-second looks)")
        // a 30 s cap from the first event of each request: first events at 0, 31, 62 and 93 give looks at 30.5, 61.5 and 92.5
        #expect(taken.count >= 3 && Array(taken.prefix(3)) == [30.5, 61.5, 92.5], "requests were taken at \(taken); expected 30.5, 61.5 and 92.5 while the events kept coming")
        // the burst that began at 93 s has events until 99 s: due 101 s, the cap (123 s) is far away
        #expect(mwDue(d).map { abs($0 - 101) < 0.0005 } == true, "the last burst (first event 93 s, last 99 s): due \(mwDescribe(d)) s, expected 101 s")
        #expect(mwTake(&d, at: 100.999) == false, "taken before 2 s after the last event")
        #expect(mwTake(&d, at: 101.001), "not taken 2 s after the last event")
    }

    @Test func aRequestIsNeverDueLaterThan30sAfterItsFirstEventWhateverArrives() {
        var d = ChangeDebouncer(roots: [mwRoot])
        // events every half second for a minute, each with a modified time ahead of its arrival as well
        for step in 0..<120 {
            let t = Double(step) * 0.5
            d.record(mwEvent("busy.dat", modified: t + 3), at: mwAt(t))
            if let due = mwDue(d), due > 30.0005 {
                Issue.record("at \(t) s the request is due at \(due) s, later than 30 s after its first event (0 s)")
                break
            }
        }
    }

    @Test func eventsEveryOneAndAHalfSecondsHoldTheRequestOnlyUntilThirtySeconds() {
        var d = ChangeDebouncer(roots: [mwRoot])
        for step in 0..<20 {                                  // events at 0, 1.5, ..., 28.5 s: no gap reaches 2 s
            d.record(mwEvent("download.part", modified: Double(step) * 1.5 - 0.1), at: mwAt(Double(step) * 1.5))
        }
        #expect(mwDue(d).map { abs($0 - 30) < 0.0005 } == true, "events until 28.5 s: 2 s after the last is 30.5 s, the cap 30 s; due \(mwDescribe(d)) s, expected 30 s")
        #expect(mwTake(&d, at: 29.999) == false, "taken before 30 s")
        #expect(mwTake(&d, at: 30.001), "not taken at the 30 s cap although events never stopped for 2 s")
        #expect(d.dueDate == nil, "a taken request left a due date: \(mwDescribe(d))")
    }

    @Test func theCapCountsFromTheFirstEventOfTheRequestNotFromTheFirstEverSeen() {
        var d = ChangeDebouncer(roots: [mwRoot])
        d.record(mwEvent("a.jpg", modified: -60), at: mwAt(0))
        #expect(mwTake(&d, at: 2.001), "the first request was not taken")
        // a second request starts at 1,000 s; events every second for 40 s must make it due at 1,030 s
        for second in 0..<40 {
            d.record(mwEvent("b.log", modified: 1_000 + Double(second) - 0.1), at: mwAt(1_000 + Double(second)))
        }
        #expect(mwDue(d).map { abs($0 - 1_030) < 0.0005 } == true, "the second request's first event was at 1,000 s: due \(mwDescribe(d)) s, expected 1,030 s")
    }

    @Test func eventsOutsideTheWatchedFoldersDoNotStartTheCap() {
        var d = ChangeDebouncer(roots: [mwRoot])
        d.record(ChangeEvent(path: "/w/other/x.jpg", modified: mwAt(-60)), at: mwAt(0))     // dropped: no request, no cap
        d.record(mwEvent("a.jpg", modified: -60), at: mwAt(20))                               // the first kept event
        for second in 21...60 { d.record(mwEvent("a.jpg", modified: Double(second) - 0.1), at: mwAt(Double(second))) }
        #expect(mwDue(d).map { abs($0 - 50) < 0.0005 } == true, "the first kept event was at 20 s: due \(mwDescribe(d)) s, expected 50 s")
    }
}

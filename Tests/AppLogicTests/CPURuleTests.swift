import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t29, tester step (2 of 2): `CPURule`, the pure pause rule for "whole-system CPU apart from Sesame"
// (S7.3, S7.17). Written from the t29 entry (its Tests paragraph), spec S7 ("pauses by itself when whole-system CPU
// use apart from Sesame stays above 70 percent for 10 seconds ... resumes by itself when CPU use apart from Sesame
// stays below 50 percent for 30 seconds"), design section 8 ("monitor samples every 1 s") and verify.md K17 (a 5 s,
// an 8 s burst and a steady 60 percent never pause). No product source was read. Every expected value is written by
// hand from those texts; a sample is a number of percent and a timestamp, and no test sleeps: a test feeds the
// samples it likes, one second apart, as the 1 s scheduler of t30 would.
//
// API SHAPES these tests pin. The entry names `CPURule`, a "pause event" and a "resume event" and fixes no signature;
// these are this file's picks. If a shape is wrong, ask for a test change rather than guessing.
//   1. `CPURule` is in the `Sesame` target, with `init()`; a class or a struct both satisfy these tests (they hold it
//      in a `var`). It holds the rule's own count of consecutive samples and nothing else: it knows nothing of
//      `PauseSet`, files or the clock.
//   2. `enum CPURule.Event: Equatable { case pause, resume }`.
//   3. `rule.feed(_ percent: Double, at time: Date) -> CPURule.Event?` takes one sample, percent 0...100, with its
//      timestamp, and returns the event this sample causes, or nil. The tests give timestamps exactly one second apart.
//   4. The count is in samples at one per second: "above 70 for 10 consecutive seconds" is the tenth consecutive
//      sample above 70 (that sample returns `.pause`, the first nine return nil); "below 50 for 30 consecutive
//      seconds" is the thirtieth consecutive sample below 50 after a pause (that sample returns `.resume`).
//   5. Above 70 means strictly above, below 50 strictly below. A sample at exactly 70 is not above and a sample at
//      exactly 50 is not below, so neither adds to a count. One sample below 70 in a build-up resets it (a sample
//      at exactly 70 inside a build-up is not tested: the entry names only "below 70"). Once paused, any sample that
//      is not below 50 (50 itself, 55, 69.9, 70) resets the resume count and never causes an event.
// Not pinned, on purpose: what the rule returns for a sample that is neither of the above (only that the tests below
// that say "no event" see nil), whether a resume event is ever returned while the rule is not paused, whether samples
// above 70 after a pause return anything, the behaviour when timestamps are not one second apart, how a gap in
// time is read, and whether a pause is repeated while the load stays high.

private let crBase = Date(timeIntervalSince1970: 1_700_000_000)

// Feeds one sample a second, in order, to one rule; remembers the second it is at so no test counts by hand.
private struct CRDrive {
    var rule = CPURule()
    private(set) var seconds = 0

    mutating func feed(_ percent: Double) -> CPURule.Event? {
        let event = rule.feed(percent, at: crBase.addingTimeInterval(Double(seconds)))
        seconds += 1
        return event
    }

    // The events of `count` samples at the same percent, in order.
    mutating func feed(_ percent: Double, times count: Int) -> [CPURule.Event?] {
        (0..<count).map { _ in feed(percent) }
    }

    // The events of the given samples, in order.
    mutating func feed(each percents: [Double]) -> [CPURule.Event?] {
        percents.map { feed($0) }
    }

    // A rule that has paused: ten samples at 100, the last one returns the pause.
    static func paused() -> CRDrive {
        var drive = CRDrive()
        _ = drive.feed(100, times: 9)
        _ = drive.feed(100)
        return drive
    }
}

private func crNone(_ count: Int) -> [CPURule.Event?] { Array(repeating: nil, count: count) }

private func crPauses(_ events: [CPURule.Event?]) -> Int { events.filter { $0 == .pause }.count }

@Suite("CPURuleTests")
@MainActor
struct CPURuleTests {

    // MARK: pause: above 70 for 10 consecutive seconds

    @Test func theTenthConsecutiveSampleAbove70GivesThePauseAndNoEarlierSampleDoes() {
        var drive = CRDrive()
        #expect(drive.feed(100, times: 9) == crNone(9), "nine samples at 100 are not yet ten seconds")
        #expect(drive.feed(100) == .pause, "the tenth sample at 100 is the pause")
    }

    @Test func anyValuesAbove70CountTowardsTheTenSecondsNotOnlyOneValue() {
        var drive = CRDrive()
        let build: [Double] = [71, 100, 70.01, 99.9, 85, 71, 72.5, 73, 74, 75]
        let events = drive.feed(each: build)
        #expect(Array(events.prefix(9)) == crNone(9))
        #expect(events[9] == .pause, "the tenth sample, 75, is the pause")
    }

    @Test func aSampleAtExactly70IsNotAboveSoNothingEverPauses() {
        var drive = CRDrive()
        let events = drive.feed(70, times: 120)
        #expect(crPauses(events) == 0, "120 seconds at exactly 70 is not above 70")
    }

    @Test func aSampleJustAbove70DoesCount() {
        var drive = CRDrive()
        let events = drive.feed(70.01, times: 10)
        #expect(Array(events.prefix(9)) == crNone(9))
        #expect(events[9] == .pause, "ten seconds at 70.01 is above 70 for ten seconds")
    }

    @Test func burstsOf5And8And9SecondsAt100NeverPause() {
        for burst in [5, 8, 9] {
            var drive = CRDrive()
            var events = drive.feed(100, times: burst)
            events += drive.feed(10, times: 60)
            #expect(crPauses(events) == 0, "a \(burst) s burst at 100 then 60 s at 10")
        }
    }

    @Test func repeatedNineSecondBurstsWithOneQuietSecondBetweenNeverPause() {
        var drive = CRDrive()
        var events: [CPURule.Event?] = []
        for _ in 0..<30 {
            events += drive.feed(100, times: 9)
            events.append(drive.feed(20))
        }
        #expect(crPauses(events) == 0, "30 rounds of 9 s at 100 and one second at 20")
    }

    @Test func aSteady60PercentForSixtySecondsNeverPausesAndNeverFiresAnything() {
        var drive = CRDrive()
        let events = drive.feed(60, times: 60)
        #expect(events == crNone(60), "60 is neither above 70 nor below 50, so no event")
    }

    @Test func oneSampleBelow70InsideTheBuildUpResetsIt() {
        var drive = CRDrive()
        var events = drive.feed(100, times: 9)
        events.append(drive.feed(60))
        events += drive.feed(100, times: 9)
        #expect(events == crNone(19), "9 at 100, one at 60, 9 at 100: never ten in a row")
        #expect(drive.feed(100) == .pause, "the tenth consecutive sample after the reset pauses")
    }

    @Test func aDipJustBelow70AlsoResetsTheBuildUp() {
        var drive = CRDrive()
        var events = drive.feed(100, times: 5)
        events.append(drive.feed(69.9))
        events += drive.feed(100, times: 9)
        #expect(events == crNone(15))
        #expect(drive.feed(100) == .pause, "ten consecutive samples counted from after the 69.9")
    }

    // MARK: staying paused: samples between 50 and 70

    @Test func onceSamplesBetween50And70KeepItPausedForAnyLength() {
        var drive = CRDrive.paused()
        let between: [Double] = [50, 51, 55, 60, 65, 69.9, 70]
        var events: [CPURule.Event?] = []
        for _ in 0..<600 {
            events += drive.feed(each: between)
        }
        #expect(events == crNone(600 * between.count), "an hour and more of samples from 50 to 70 gives no event")
        // Still paused: only now does a clean 30 s below 50 resume it.
        #expect(drive.feed(10, times: 29) == crNone(29))
        #expect(drive.feed(10) == .resume, "still paused after the long stretch, so 30 s below 50 resumes")
    }

    // MARK: resume: below 50 for 30 consecutive seconds

    @Test func theThirtiethConsecutiveSampleBelow50GivesTheResumeAndNoEarlierSampleDoes() {
        var drive = CRDrive.paused()
        #expect(drive.feed(10, times: 29) == crNone(29), "29 s below 50 is not yet 30 s")
        #expect(drive.feed(10) == .resume, "the thirtieth sample below 50 is the resume")
    }

    @Test func anyValuesBelow50CountTowardsTheThirtySeconds() {
        var drive = CRDrive.paused()
        let quiet: [Double] = (0..<30).map { [0, 49.9, 20, 35.5, 10, 1][$0 % 6] }
        let events = drive.feed(each: quiet)
        #expect(Array(events.prefix(29)) == crNone(29))
        #expect(events[29] == .resume)
    }

    @Test func aSampleAtExactly50IsNotBelowSoItNeverResumes() {
        var drive = CRDrive.paused()
        #expect(drive.feed(50, times: 200) == crNone(200), "200 s at exactly 50 is not below 50")
        // The 50s were not counted: the thirty seconds start after them.
        #expect(drive.feed(10, times: 29) == crNone(29))
        #expect(drive.feed(10) == .resume)
    }

    @Test func aSampleJustBelow50Counts() {
        var drive = CRDrive.paused()
        #expect(drive.feed(49.99, times: 29) == crNone(29))
        #expect(drive.feed(49.99) == .resume, "thirty seconds at 49.99 is below 50 for thirty seconds")
    }

    @Test func twentyNineSecondsBelow50ThenOneAt55ResetsTheCount() {
        var drive = CRDrive.paused()
        var events = drive.feed(10, times: 29)
        events.append(drive.feed(55))
        #expect(events == crNone(30), "29 s below 50 then 55: no resume")
        #expect(drive.feed(10, times: 29) == crNone(29), "the count restarted: 29 more is not enough")
        #expect(drive.feed(10) == .resume, "the thirtieth sample after the 55 resumes")
    }

    @Test func twentyNineSecondsBelow50ThenOneAboveTheCpuThresholdAlsoResetsTheCount() {
        var drive = CRDrive.paused()
        var events = drive.feed(10, times: 29)
        events.append(drive.feed(90))
        let resumes = events.filter { $0 == .resume }.count
        #expect(resumes == 0, "no resume after 29 s then a spike")
        #expect(drive.feed(10, times: 29) == crNone(29))
        #expect(drive.feed(10) == .resume)
    }

    // MARK: after a resume the rule starts clean

    @Test func afterTheResumeTheRuleCanPauseAgainOnAFreshTenSeconds() {
        var drive = CRDrive.paused()
        _ = drive.feed(10, times: 29)
        #expect(drive.feed(10) == .resume)
        #expect(drive.feed(100, times: 9) == crNone(9), "nine seconds of load after the resume is not enough")
        #expect(drive.feed(100) == .pause, "the tenth is a second pause")
        _ = drive.feed(10, times: 29)
        #expect(drive.feed(10) == .resume, "and a second resume after 30 s below 50")
    }

    // MARK: a pause by the CPU rule leaves the other reasons alone

    @Test func theRulesEventsAddAndRemoveOnlyCpuAndLeaveYouLowPowerAndBatteryAlone() {
        var set = PauseSet()
        set.add(.you)
        set.add(.lowPower)
        set.add(.battery)
        let others: Set<PauseReason> = [.you, .lowPower, .battery]
        var drive = CRDrive()

        // The 1 s scheduler's job (t30), written out here: a pause event sets `cpu`, a resume event clears it.
        func apply(_ event: CPURule.Event?) {
            switch event {
            case .pause: set.add(.cpu)
            case .resume: set.remove(.cpu)
            case nil: break
            }
        }

        for _ in 0..<9 { apply(drive.feed(100)) }
        #expect(set.reasons == others, "nine seconds of load: the set is untouched")
        apply(drive.feed(100))
        #expect(set.reasons == others.union([.cpu]), "the pause event adds cpu next to the other three")
        for _ in 0..<29 { apply(drive.feed(10)) }
        #expect(set.reasons == others.union([.cpu]), "29 quiet seconds: cpu still set")
        apply(drive.feed(10))
        #expect(set.reasons == others, "the resume event removes cpu and only cpu")
        #expect(set.isPaused == true, "you, lowPower and battery still pause")
    }

    @Test func aCpuPauseOnItsOwnClearsToNotPausedAtTheResume() {
        var set = PauseSet()
        var drive = CRDrive()
        for _ in 0..<10 {
            if drive.feed(100) == .pause { set.add(.cpu) }
        }
        #expect(set.reasons == [.cpu])
        #expect(set.isPaused == true)
        for _ in 0..<30 {
            if drive.feed(5) == .resume { set.remove(.cpu) }
        }
        #expect(set.reasons.isEmpty)
        #expect(set.isPaused == false)
    }
}

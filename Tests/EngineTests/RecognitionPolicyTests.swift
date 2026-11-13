import Testing
import SesameEngine

// plan-4 review round 1, fix round, tester step (must-fix 4: one page Vision keeps failing on blocks every file behind it).
// Written from the brief only; no product source read. The product has no `RecognitionPolicy` yet, so this file does not compile
// until it does.
//
// THE SHAPE THESE TESTS PIN (the brief fixes it; a struct in SesameEngine, pure, no clock and no I/O):
//   struct RecognitionPolicy                       a value type, created empty with `RecognitionPolicy()`
//   mutating func recordSuccess()                  one recognition (Vision text or scan) worked in this helper run
//   mutating func recordFailure() -> RecognitionPolicy.Verdict
//   enum RecognitionPolicy.Verdict { case skipFile, stopRun }    equatable (no payload)
//   static let RecognitionPolicy.giveUpAfterFailedRuns           2, a whole number
// THE RULE: `.skipFile` when at least one recognition has succeeded earlier in this helper run (Vision itself works, so only this
// file is the problem: go on with the next), `.stopRun` when none has (Vision may be broken for the whole run: stop). A fresh
// policy's first failure is `.stopRun`. After a success every failure is `.skipFile`, however many. A failure never counts as a
// success, so `.stopRun` repeats while nothing has succeeded. A file whose Vision failed in two separate runs becomes
// could_not_read: the helper counts that with the store's existing `tries`, so the number here is only documented. The helper
// wiring is read by the reviewer, not tested here.
//
// SHAPES THIS FILE PINS that the brief did not fix: `RecognitionPolicy()` is a public no-argument initialiser; `Verdict` is
// `Equatable` (the tests compare with `==`); `giveUpAfterFailedRuns` compares equal to the integer literal 2; the policy is a value
// (a copy made before a success does not take it); a `.stopRun` failure leaves the policy as it was (a later success still works).

@Suite("RecognitionPolicyTests")
struct RecognitionPolicyTests {

    @Test func aFreshPolicysFirstFailureStopsTheRun() {
        var policy = RecognitionPolicy()
        #expect(policy.recordFailure() == .stopRun)
    }

    @Test func failuresKeepStoppingTheRunForAsLongAsNothingHasSucceeded() {
        var policy = RecognitionPolicy()
        for attempt in 1...5 {
            #expect(policy.recordFailure() == .stopRun, "failure \(attempt) with no success yet")
        }
    }

    @Test func afterASuccessEveryFailureSkipsOnlyThatFile() {
        var policy = RecognitionPolicy()
        policy.recordSuccess()
        for attempt in 1...5 {
            #expect(policy.recordFailure() == .skipFile, "failure \(attempt) after a success")
        }
    }

    @Test func aSuccessAfterAStoppedFailureTurnsLaterFailuresIntoSkips() {
        var policy = RecognitionPolicy()
        #expect(policy.recordFailure() == .stopRun)
        policy.recordSuccess()
        #expect(policy.recordFailure() == .skipFile)
        #expect(policy.recordFailure() == .skipFile)
    }

    @Test func moreSuccessesNeverTakeTheSkipBack() {
        var policy = RecognitionPolicy()
        policy.recordSuccess()
        #expect(policy.recordFailure() == .skipFile)
        policy.recordSuccess()
        policy.recordSuccess()
        #expect(policy.recordFailure() == .skipFile)
    }

    @Test func aPolicyIsAValueSoACopyMadeBeforeASuccessKeepsStopping() {
        var original = RecognitionPolicy()
        var copy = original
        original.recordSuccess()
        #expect(copy.recordFailure() == .stopRun, "the copy took the original's success")
        #expect(original.recordFailure() == .skipFile)
    }

    @Test func aFileIsGivenUpAfterTwoFailedRuns() {
        #expect(RecognitionPolicy.giveUpAfterFailedRuns == 2)
    }
}

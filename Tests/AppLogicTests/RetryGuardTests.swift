import Foundation
import Testing
@testable import Sesame

// plan-2 fix round F, tester step, R5-01: a second "Retry model download" within about 2 s must not start a second download
// beside the first. The retry decision sits in AppDelegate's `modelRetried()`, which no test reaches, so the decision is a
// small pure value. Written from the reviewer's report (R5-01), the controller's rule ("retry handling acts only while a
// failure stands and the model is not whole; once per failure") and the brief. No product source was read. Every expected
// value is written by hand.
//
// SHAPE F pins here (new), in the `Sesame` target:
//   struct RetryGuard {
//       init()                                     // no failure recorded yet
//       mutating func recordFailure()              // a download failure now stands: arms one Retry
//       mutating func shouldRetry(failureStands: Bool, isWhole: Bool) -> Bool
//   }
// Rules: `shouldRetry` answers true only when a failure has been recorded and not yet answered, `failureStands` is true
// and `isWhole` is false; that true uses the failure up, so a second press answers false until `recordFailure()` is
// called again. A fresh guard answers false (nothing was recorded). Recording twice before a press is still one failure.
// `failureStands` is the app's own view (the model failure is still set); `isWhole` is `ModelStateSource.isWhole()`.
//
// NOT pinned, on purpose: whether an answer of false because `failureStands` is false or `isWhole` is true keeps or drops
// the recorded failure. These tests never rely on either.
//
// NOT TESTABLE HERE, listed for a reviewer to read: that `modelRetried()` asks the guard first and does nothing on false,
// that every place that sets the failure also calls `recordFailure()`, and that the menu is redrawn at once after Retry.

@Suite("RetryGuardTests")
struct RetryGuardTests {

    @Test func aFreshGuardAnswersFalseBecauseNoFailureWasRecorded() {
        var guardValue = RetryGuard()
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: false) == false, "nothing was recorded, yet it said retry")
        #expect(guardValue.shouldRetry(failureStands: false, isWhole: false) == false)
    }

    @Test func aRecordedFailureAnswersTrueOnceForTheFirstPress() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: false) == true)
    }

    @Test func aSecondPressOfTheSameFailureAnswersFalse() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        let answers = [
            guardValue.shouldRetry(failureStands: true, isWhole: false),
            guardValue.shouldRetry(failureStands: true, isWhole: false),
        ]
        #expect(answers == [true, false], "a double press answered \(answers), want [true, false]: a second download would start")
    }

    @Test func manyPressesOfOneFailureAnswerTrueExactlyOnce() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        let answers = (0..<6).map { _ in guardValue.shouldRetry(failureStands: true, isWhole: false) }
        #expect(answers == [true, false, false, false, false, false], "six presses answered \(answers)")
    }

    @Test func aPressWhileNoFailureStandsAnswersFalseEvenAfterOneWasRecorded() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        #expect(guardValue.shouldRetry(failureStands: false, isWhole: false) == false, "a stale press with no failure standing started a download")
    }

    @Test func aPressAfterTheModelBecameWholeAnswersFalse() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: true) == false, "a press on a whole model started a download")
        #expect(guardValue.shouldRetry(failureStands: false, isWhole: true) == false)
    }

    @Test func aWholeModelNeverRetriesWhateverTheFailureFlagSays() {
        for stands in [true, false] {
            var guardValue = RetryGuard()
            guardValue.recordFailure()
            #expect(guardValue.shouldRetry(failureStands: stands, isWhole: true) == false, "failureStands \(stands), isWhole true")
        }
    }

    @Test func aNewFailureArmsTheGuardAgainSoEachFailureGetsOneRetry() {
        var guardValue = RetryGuard()
        var answers: [Bool] = []
        guardValue.recordFailure()
        answers.append(guardValue.shouldRetry(failureStands: true, isWhole: false))
        answers.append(guardValue.shouldRetry(failureStands: true, isWhole: false))
        guardValue.recordFailure()   // the Retry's own download failed
        answers.append(guardValue.shouldRetry(failureStands: true, isWhole: false))
        answers.append(guardValue.shouldRetry(failureStands: true, isWhole: false))
        guardValue.recordFailure()
        answers.append(guardValue.shouldRetry(failureStands: true, isWhole: false))
        #expect(answers == [true, false, true, false, true], "answers \(answers)")
    }

    @Test func recordingTheSameFailureTwiceBeforeAPressIsStillOneRetry() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        guardValue.recordFailure()
        let answers = [
            guardValue.shouldRetry(failureStands: true, isWhole: false),
            guardValue.shouldRetry(failureStands: true, isWhole: false),
        ]
        #expect(answers == [true, false], "answers \(answers)")
    }

    @Test func theWindowsRetryThenTheMenusRetryWithinTwoSecondsStartsOneDownload() {
        // The window's Retry runs first. The menu is not redrawn for up to 2 s, so it still shows the failed state: the
        // failure still stands as far as the menu knows and the model is not whole yet.
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        let window = guardValue.shouldRetry(failureStands: true, isWhole: false)
        let menu = guardValue.shouldRetry(failureStands: true, isWhole: false)
        #expect(window == true, "the window's Retry did not start the download")
        #expect(menu == false, "the stale menu's Retry started a second download beside the window's")
    }

    @Test func theMenusRetryThenTheWindowsRetryStartsOneDownloadToo() {
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        let menu = guardValue.shouldRetry(failureStands: true, isWhole: false)
        let window = guardValue.shouldRetry(failureStands: true, isWhole: false)
        #expect([menu, window] == [true, false], "menu then window answered \([menu, window])")
    }

    @Test func aStaleMenuPressAfterTheModelWasDamagedAgainWhileTheWatcherFetchesDoesNothing() {
        // Retry ran; later the watcher found damage and is fetching (the app cleared the failure: failureStands false). A
        // press on the still-open failed menu must not start a second fetch.
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: false) == true)
        #expect(guardValue.shouldRetry(failureStands: false, isWhole: false) == false)
    }

    @Test func aFailureThatFollowsASuccessfulPressIsRetriedAgain() {
        // failure, Retry works (model whole, a press on the stale item is refused), the model is damaged and fails later
        var guardValue = RetryGuard()
        guardValue.recordFailure()
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: false) == true)
        #expect(guardValue.shouldRetry(failureStands: false, isWhole: true) == false)
        guardValue.recordFailure()
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: false) == true, "the later failure got no Retry")
        #expect(guardValue.shouldRetry(failureStands: true, isWhole: false) == false)
    }

    @Test func twoValuesShareNoState() {
        var a = RetryGuard()
        var b = RetryGuard()
        a.recordFailure()
        #expect(b.shouldRetry(failureStands: true, isWhole: false) == false, "b never recorded a failure")
        #expect(a.shouldRetry(failureStands: true, isWhole: false) == true)
        b.recordFailure()
        #expect(b.shouldRetry(failureStands: true, isWhole: false) == true)
        #expect(a.shouldRetry(failureStands: true, isWhole: false) == false)
    }

    @Test func aCopyKeepsItsOwnHistory() {
        var original = RetryGuard()
        original.recordFailure()
        var copy = original
        #expect(original.shouldRetry(failureStands: true, isWhole: false) == true)
        #expect(copy.shouldRetry(failureStands: true, isWhole: false) == true, "the copy was taken while armed, so it has its own Retry")
        #expect(original.shouldRetry(failureStands: true, isWhole: false) == false)
        #expect(copy.shouldRetry(failureStands: true, isWhole: false) == false)
    }
}

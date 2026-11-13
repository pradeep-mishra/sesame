import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2 fix round E, tester step, item E2 (R4-02): the whole-model hook must not live in the setup window's 0.5 s ticker.
// Written from the fix-round document ("add a window-independent hook: when the model state goes from not whole to whole
// (seen by the 2 s menu tick, and by the watcher's success), run `measureSpeeds()` and `supervisor.reevaluate()` exactly
// once per transition. Put the edge detection in a small pure value ... true once on a not-whole to whole change and never
// at the first observation when already whole"). No product source was read. Every expected value is written by hand.
//
// SHAPE E2 pins here (new):
//   struct ModelWholeEdge {                                  // a plain value; in `Sesame` or `SesameEngine`, either compiles
//       init()                                               // no observation yet
//       mutating func update(isWhole: Bool) -> Bool          // feed one observation; true = "the model just became whole"
//   }
// Rules, from the document: the answer is true exactly on an observation of `true` that follows an observation of `false`;
// the first observation never answers true, whatever it is (a launch with the model already whole runs nothing here: the
// launch path does its own measuring); a repeated `true` answers false; after a `false` the next `true` is a new transition
// and answers true again, so it is once per transition and not once per launch. Two values share nothing.
//
// NOT TESTABLE HERE, and listed in the fixer's report for a reviewer to read: the AppDelegate wiring (the 2 s menu tick and
// the watcher's success both feed one `ModelWholeEdge`, and a true answer runs `measureSpeeds()` and `supervisor.reevaluate()`
// once, with the setup window closed).

@Suite("ModelWholeEdgeTests")
struct ModelWholeEdgeTests {

    /// Feeds the observations in order and returns the answers.
    private func answers(_ observations: [Bool]) -> [Bool] {
        var edge = ModelWholeEdge()
        return observations.map { edge.update(isWhole: $0) }
    }

    @Test func aModelThatWasNotWholeAndBecomesWholeAnswersTrueOnceAtTheChange() {
        #expect(answers([false, false, true]) == [false, false, true])
        #expect(answers([false, true]) == [false, true])
    }

    @Test func theFirstObservationAnswersFalseWhetherTheModelIsWholeOrNot() {
        #expect(answers([true]) == [false], "a first observation of a whole model is not a transition")
        #expect(answers([false]) == [false])
    }

    @Test func aModelThatIsWholeFromTheStartNeverAnswersTrue() {
        #expect(answers([true, true, true, true]) == [false, false, false, false])
    }

    @Test func aModelThatStaysNotWholeNeverAnswersTrue() {
        #expect(answers([false, false, false, false]) == [false, false, false, false])
    }

    @Test func staysWholeAfterTheChangeAnswersFalseAgain() {
        #expect(answers([false, true, true, true]) == [false, true, false, false], "the hook would run on every 2 s tick")
    }

    @Test func eachNotWholeToWholeTransitionAnswersTrueOnceSoADamagedModelThatIsFetchedAgainRunsTheHookAgain() {
        // whole at launch, damaged (not whole), whole again: one true; then damaged and whole once more: a second true
        #expect(answers([true, true, false, false, true, true, false, true]) == [false, false, false, false, true, false, false, true])
    }

    @Test func aWholeToNotWholeChangeAnswersFalse() {
        #expect(answers([false, true, false]) == [false, true, false])
        #expect(answers([true, false]) == [false, false])
    }

    @Test func aLongRunOfTicksAnswersTrueExactlyOncePerTransition() {
        // 3 transitions in 31 observations: not whole x5, whole x10, not whole x3, whole x6, not whole x2, whole x5
        let run = Array(repeating: false, count: 5) + Array(repeating: true, count: 10) + Array(repeating: false, count: 3)
            + Array(repeating: true, count: 6) + Array(repeating: false, count: 2) + Array(repeating: true, count: 5)
        #expect(run.count == 31)
        let result = answers(run)
        #expect(result.filter { $0 }.count == 3, "true \(result.filter { $0 }.count) times, want 3")
        // and exactly at the first observation of each whole stretch that follows a not-whole one: indices 5, 18 and 26
        #expect(result.enumerated().filter { $0.element }.map(\.offset) == [5, 18, 26], "true at \(result.enumerated().filter { $0.element }.map(\.offset))")
    }

    @Test func twoValuesShareNoState() {
        var a = ModelWholeEdge()
        var b = ModelWholeEdge()
        #expect(a.update(isWhole: false) == false)
        #expect(b.update(isWhole: true) == false, "b's first observation is its own, not a change after a's false")
        #expect(a.update(isWhole: true) == true)
        #expect(b.update(isWhole: true) == false)
    }

    @Test func aCopyKeepsItsOwnHistory() {
        var original = ModelWholeEdge()
        _ = original.update(isWhole: false)
        var copy = original
        #expect(original.update(isWhole: true) == true)
        #expect(copy.update(isWhole: true) == true, "the copy was taken while not whole, so its next whole is a change")
        #expect(original.update(isWhole: true) == false)
    }
}

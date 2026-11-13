import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t31, tester step (1 of 2): `HelperSupervisor`, the app's decision to run, stop and start the `index` helper
// (S7.2 Pause, S7.4, S7.5, S7.10 relaunch resume). Written from the t31 entry (its Tests paragraph), design section 3
// ("a resume after pause" starts a new `index` helper and sends `folders`), design section 6 (pause reasons are a set),
// the plan-2 Conventions (Helper protocol: Pause, Resume, Quit add no command, a helper that sees its stdin end is a
// clean stop) and the sealed t29 tests (`PauseSet`, `PauseReason`) only. No product source was read. Every expected
// value below is written by hand from those texts.
//
// API SHAPES these tests pin. The entry names `HelperSupervisor`, `IndexHost` (start, stopClean, isRunning, an exit
// callback), `syncNeeded()` and a manual clock, and fixes no signatures; the rest are this file's picks. If a shape is
// wrong, ask for a test change rather than guessing.
//   1. Isolation. `HelperSupervisor`, `IndexHost` and the closures below are `@MainActor`; closures are plain, not
//      `@Sendable`. Swift 6 mode is on in this package.
//   2. `HelperExit` (new, public to the app target, `Equatable` and `Sendable`):
//        enum HelperExit: Equatable, Sendable { case planned; case unplanned(status: Int32) }
//      It is what `IndexHost.onExit` and `HelperClient.onExit` (HelperClientTests) hand over: `.planned` for an exit that
//      follows a clean stop the app asked for, `.unplanned(status:)` for every other exit.
//   3. `@MainActor protocol IndexHost: AnyObject` with
//        var isRunning: Bool { get }              // a process is alive, an exiting one included
//        var onExit: ((HelperExit) -> Void)? { get set }   // called once per exit of the process, after it is gone
//        func start()                             // make sure ONE `index` helper runs and send it the whole `folders`
//                                                 // list, once per call (HelperClient.sendFolders does both). Called
//                                                 // while a helper runs it only re-sends the list; called while the
//                                                 // old helper is still exiting it is a bug (a second process or a line
//                                                 // into a closed pipe): the supervisor must wait for the exit first.
//        func stopClean()                         // end the helper's stdin; returns at once; `isRunning` stays true
//                                                 // until the process has exited. Called with no helper running, or a
//                                                 // second time while it exits, it is a bug: the supervisor never does.
//   4. `HelperSupervisor.Inputs` (nested struct, memberwise init with these labels, in this order):
//        Inputs(startPressed: Bool, indexDeleted: Bool, modelWhole: Bool, pauseReasons: Set<PauseReason>, quitting: Bool)
//      `HelperSupervisor(host: any IndexHost, inputs: @escaping () -> Inputs)`. The supervisor reads `inputs` each time
//      it decides, never caches it, and sets `host.onExit` itself at init. Creating a supervisor may or may not start
//      the helper (not pinned); every test below calls `reevaluate()` for the launch.
//   5. `func reevaluate()`: decides from the inputs now. Indexing is wanted exactly when startPressed, not
//      indexDeleted, modelWhole, `pauseReasons` empty and not quitting. Wanted and no helper alive: `host.start()` once.
//      Wanted and a helper alive and not exiting: nothing. Not wanted and a helper alive and not already asked to stop:
//      `host.stopClean()` once. Wanted while the helper exits (a resume before the exit): nothing now, and exactly one
//      `host.start()` when `onExit` arrives. Not wanted when `onExit` arrives: nothing. A `.planned` exit makes the
//      supervisor re-decide by itself (the tests never call `reevaluate()` for it). Unplanned exits are t33's: no test
//      here sends one. `reevaluate()` is the same call whatever changed (a pause reason, Start, the model, quitting),
//      and it is what t32's menu actions and the launch call; it is synchronous: no timer, no clock is involved, so these
//      tests need no manual clock (the entry's clock belongs to the t33 restart delays).
//   6. `func syncNeeded()`: indexing wanted and no helper alive or exiting: `host.start()` once. Wanted and a helper
//      alive, not exiting: `host.start()` once more (the helper reconciles the re-sent list; one call per `syncNeeded()`).
//      Wanted while the helper exits: the same single start after the exit, no start now. Not wanted: nothing now, and
//      the need is remembered: the one `host.start()` of the next resume carries it (so the resume still makes exactly
//      one start, never two), and a later pause and resume makes no extra start for it.
// Not pinned, on purpose: what the supervisor does before its first `reevaluate()`, unplanned exits, threads outside the
// main actor, how `Inputs` are produced in the app (t32), a `quit()` method (quitting is an input here).

// MARK: the fake host

@MainActor private final class HSHost: IndexHost {
    // true while a process is alive; an exiting one counts.
    private(set) var isRunning = false
    private(set) var exiting = false
    var onExit: ((HelperExit) -> Void)?

    // "start" or "stop", in call order.
    private(set) var log: [String] = []
    // Calls the entry forbids: two index processes, a start into an exiting helper, a stop with nothing to stop.
    private(set) var violations: [String] = []
    // Processes launched (a `start()` with none alive).
    private(set) var processes = 0

    var starts: Int { log.filter { $0 == "start" }.count }
    var stops: Int { log.filter { $0 == "stop" }.count }

    func start() {
        log.append("start")
        if exiting {
            violations.append("start() while the old helper was still exiting (log \(log))")
            return
        }
        if !isRunning {
            isRunning = true
            processes += 1
        }
    }

    func stopClean() {
        log.append("stop")
        if !isRunning {
            violations.append("stopClean() with no helper running (log \(log))")
            return
        }
        if exiting {
            violations.append("stopClean() a second time while the helper exits (log \(log))")
            return
        }
        exiting = true
    }

    // The process finishes its unit and exits 0 after a clean stop: the planned exit.
    func finishExit() {
        guard isRunning else { return }
        isRunning = false
        exiting = false
        onExit?(.planned)
    }
}

// MARK: the world: inputs, pause reasons and the supervisor

@MainActor private final class HSState {
    var startPressed = true
    var indexDeleted = false
    var modelWhole = true
    var pauses = PauseSet()
    var quitting = false
    // plan-2 fix round B (B4): the speed bench is running. A new input of `HelperSupervisor.Inputs`, last, default false.
    var measuring = false
}

@MainActor private struct HSWorld {
    let state = HSState()
    let host = HSHost()
    let supervisor: HelperSupervisor

    init(startPressed: Bool = true, indexDeleted: Bool = false, modelWhole: Bool = true) {
        let state = state
        state.startPressed = startPressed
        state.indexDeleted = indexDeleted
        state.modelWhole = modelWhole
        supervisor = HelperSupervisor(host: host, inputs: {
            HelperSupervisor.Inputs(startPressed: state.startPressed, indexDeleted: state.indexDeleted,
                                    modelWhole: state.modelWhole, pauseReasons: state.pauses.reasons,
                                    quitting: state.quitting, measuring: state.measuring)
        })
    }

    // A launch: the app calls `reevaluate()` once with what settings.json and the model say.
    func launch() { supervisor.reevaluate() }

    func pause(_ reason: PauseReason = .you) {
        state.pauses.add(reason)
        supervisor.reevaluate()
    }

    func resume(_ reason: PauseReason = .you) {
        state.pauses.remove(reason)
        supervisor.reevaluate()
    }

    func quit() {
        state.quitting = true
        supervisor.reevaluate()
    }

    var log: [String] { host.log }
}

@Suite("HelperSupervisorTests")
@MainActor
struct HelperSupervisorTests {

    // MARK: when indexing is wanted (a hand table)

    // (name, startPressed, indexDeleted, modelWhole, reasons, quitting, a start is expected)
    private static let table: [(String, Bool, Bool, Bool, Set<PauseReason>, Bool, Bool)] = [
        ("everything holds", true, false, true, [], false, true),
        ("Start not pressed", false, false, true, [], false, false),
        ("index deleted", true, true, true, [], false, false),
        ("model not whole", true, false, false, [], false, false),
        ("paused by you", true, false, true, [.you], false, false),
        ("paused by cpu", true, false, true, [.cpu], false, false),
        ("paused by Low Power Mode", true, false, true, [.lowPower], false, false),
        ("paused by battery", true, false, true, [.battery], false, false),
        ("paused by all four", true, false, true, [.you, .cpu, .lowPower, .battery], false, false),
        ("quitting", true, false, true, [], true, false),
        ("quitting and paused", true, false, true, [.you], true, false),
        ("Start not pressed and index deleted", false, true, true, [], false, false),
        ("nothing holds", false, true, false, [.you], true, false),
    ]

    @Test func indexingIsWantedOnlyWhenEveryConditionHolds() {
        for (name, pressed, deleted, whole, reasons, quitting, wanted) in Self.table {
            let world = HSWorld(startPressed: pressed, indexDeleted: deleted, modelWhole: whole)
            for reason in reasons { world.state.pauses.add(reason) }
            world.state.quitting = quitting
            world.launch()
            world.launch()
            #expect(world.host.starts == (wanted ? 1 : 0), "\(name): expected \(wanted ? "one start" : "no start"), log \(world.log)")
            #expect(world.host.stops == 0, "\(name): nothing was running, so nothing is stopped; log \(world.log)")
            #expect(world.host.violations.isEmpty, "\(name): \(world.host.violations)")
        }
    }

    // MARK: launch (S7.10)

    @Test func aLaunchWithStartPressedStartsIndexingWithNoPress() {
        let world = HSWorld(startPressed: true)
        world.launch()
        #expect(world.log == ["start"], "S7.10: relaunch resumes with no click; log \(world.log)")
        #expect(world.host.isRunning)
        world.launch()
        world.launch()
        #expect(world.log == ["start"], "a repeated evaluation starts no second helper; log \(world.log)")
        #expect(world.host.processes == 1)
    }

    @Test func aFreshLaunchStartsNothingUntilStartIsPressed() {
        let world = HSWorld(startPressed: false)
        for _ in 0..<3 { world.launch() }
        #expect(world.log.isEmpty, "first run, nothing before Start; log \(world.log)")
        world.state.startPressed = true
        world.launch()
        #expect(world.log == ["start"], "the press of Start starts indexing once; log \(world.log)")
        world.launch()
        #expect(world.log == ["start"])
    }

    @Test func indexDeletedNeverStartsIndexingWhateverElseHappens() {
        let world = HSWorld(startPressed: true, indexDeleted: true)
        world.launch()
        world.supervisor.syncNeeded()
        world.pause()
        world.resume()
        world.launch()
        #expect(world.log.isEmpty, "after Delete index nothing starts; log \(world.log)")
        #expect(world.host.violations.isEmpty)
    }

    @Test func aModelThatIsNotWholeDefersIndexingUntilItIs() {
        let world = HSWorld(modelWhole: false)
        for _ in 0..<3 { world.launch() }
        world.supervisor.syncNeeded()
        #expect(world.log.isEmpty, "the download is still running; log \(world.log)")
        world.state.modelWhole = true
        world.launch()
        #expect(world.log == ["start"], "once the model is whole indexing starts once; log \(world.log)")
    }

    // MARK: Pause is a clean stop, Resume starts again (S7.2)

    @Test func aPauseStopsTheHelperCleanlyOnceAndStartsNothing() {
        let world = HSWorld()
        world.launch()
        world.pause(.you)
        world.supervisor.reevaluate()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "one clean stop, however often it is evaluated; log \(world.log)")
        #expect(world.host.exiting, "the stop is stdin ending; the process is still finishing its unit")
        world.host.finishExit()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "a planned exit while paused starts nothing; log \(world.log)")
        #expect(world.host.isRunning == false)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func aResumeStartsTheHelperAgainOnce() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.host.finishExit()
        world.resume()
        world.supervisor.reevaluate()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop", "start"], "one start per resume; log \(world.log)")
        #expect(world.host.isRunning)
        #expect(world.host.processes == 2)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func everyPauseReasonOnItsOwnStopsAndItsRemovalResumes() {
        for reason in [PauseReason.you, .cpu, .lowPower, .battery] {
            let world = HSWorld()
            world.launch()
            world.pause(reason)
            world.host.finishExit()
            #expect(world.log == ["start", "stop"], "\(reason): log \(world.log)")
            world.resume(reason)
            #expect(world.log == ["start", "stop", "start"], "\(reason): log \(world.log)")
            #expect(world.host.violations.isEmpty, "\(reason): \(world.host.violations)")
        }
    }

    @Test func theHelperStaysStoppedWhileAnyReasonIsLeftAndStartsWhenTheLastGoes() {
        let world = HSWorld()
        world.launch()
        world.pause(.you)
        world.pause(.cpu)
        world.pause(.battery)
        #expect(world.log == ["start", "stop"], "three reasons, one stop; log \(world.log)")
        world.host.finishExit()
        world.resume(.you)
        world.resume(.battery)
        #expect(world.log == ["start", "stop"], "cpu still pauses; log \(world.log)")
        world.resume(.cpu)
        #expect(world.log == ["start", "stop", "start"], "the last reason is gone; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func repeatedPauseAndResumeCausesNoDuplicateStartOrStop() {
        let world = HSWorld()
        world.launch()
        for _ in 0..<5 {
            world.pause()
            world.supervisor.reevaluate()
            world.host.finishExit()
            world.resume()
            world.supervisor.reevaluate()
        }
        let expected = ["start"] + Array(repeating: ["stop", "start"], count: 5).flatMap { $0 }
        #expect(world.log == expected, "five cycles; log \(world.log)")
        #expect(world.host.processes == 6)
        #expect(world.host.isRunning)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // MARK: a resume while the old helper is still exiting

    @Test func aResumeWhileTheOldHelperIsStillExitingWaitsForItsExit() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.resume()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "never a second index process; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        world.host.finishExit()
        #expect(world.log == ["start", "stop", "start"], "the exit lets the resume start exactly once; log \(world.log)")
        #expect(world.host.processes == 2)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func pausingAndResumingSeveralTimesBeforeTheExitStillMakesOneStartAfterIt() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.resume()
        world.pause()
        world.resume()
        world.pause(.cpu)
        world.resume(.cpu)
        #expect(world.log == ["start", "stop"], "one stop, no start while it exits; log \(world.log)")
        world.host.finishExit()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop", "start"], "log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func aPauseAgainBeforeTheExitLeavesNothingToStart() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.resume()
        world.pause()
        world.host.finishExit()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "paused when the exit came, so no start; log \(world.log)")
        world.resume()
        #expect(world.log == ["start", "stop", "start"], "log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // MARK: quitting

    @Test func quittingStopsTheHelperAndNeverRestartsIt() {
        let world = HSWorld()
        world.launch()
        world.quit()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "Quit stops the running helper once; log \(world.log)")
        world.host.finishExit()
        world.supervisor.reevaluate()
        world.supervisor.syncNeeded()
        world.state.pauses.add(.you)
        world.supervisor.reevaluate()
        world.state.pauses.remove(.you)
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "nothing restarts it while the app is quitting; log \(world.log)")
        #expect(world.host.isRunning == false)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func quittingWhileTheHelperIsExitingFromAPauseDoesNotRestartItAfterTheExit() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.resume()
        world.quit()
        world.host.finishExit()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "stop"], "the resume was overtaken by Quit; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func quittingWithNoHelperRunningStopsAndStartsNothing() {
        let world = HSWorld(startPressed: false)
        world.launch()
        world.quit()
        world.supervisor.syncNeeded()
        #expect(world.log.isEmpty, "log \(world.log)")
        let paused = HSWorld()
        paused.launch()
        paused.pause()
        paused.host.finishExit()
        paused.quit()
        #expect(paused.log == ["start", "stop"], "already stopped by the pause, so Quit stops nothing more; log \(paused.log)")
        #expect(paused.host.violations.isEmpty, "\(paused.host.violations)")
    }

    // MARK: syncNeeded

    @Test func syncNeededWhileIndexingRunsSendsFoldersOnceMoreToTheSameHelper() {
        let world = HSWorld()
        world.launch()
        world.supervisor.syncNeeded()
        #expect(world.log == ["start", "start"], "one folders send per sync, no new process; log \(world.log)")
        #expect(world.host.processes == 1)
        world.supervisor.syncNeeded()
        world.supervisor.syncNeeded()
        #expect(world.host.starts == 4)
        #expect(world.host.stops == 0)
        #expect(world.host.processes == 1)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func syncNeededStartsTheHelperWhenIndexingIsWantedAndNoneRuns() {
        let world = HSWorld()
        world.supervisor.syncNeeded()
        #expect(world.log == ["start"], "a watcher event with Start pressed starts indexing; log \(world.log)")
        #expect(world.host.processes == 1)
        #expect(world.host.isRunning)
    }

    @Test func syncNeededWhilePausedStartsNothingAndTheResumeMakesOneStart() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.host.finishExit()
        for _ in 0..<3 { world.supervisor.syncNeeded() }
        #expect(world.log == ["start", "stop"], "paused: remembered, not sent; log \(world.log)")
        world.resume()
        #expect(world.log == ["start", "stop", "start"], "the resume sends it, once, not once per sync; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func aRememberedSyncIsSpentByTheResumeAndCausesNoExtraStartLater() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.host.finishExit()
        world.supervisor.syncNeeded()
        world.resume()
        #expect(world.log == ["start", "stop", "start"])
        world.pause()
        world.host.finishExit()
        world.resume()
        #expect(world.log == ["start", "stop", "start", "stop", "start"], "the second cycle has no leftover sync; log \(world.log)")
        world.supervisor.reevaluate()
        #expect(world.host.starts == 3)
    }

    @Test func syncNeededWhileTheHelperExitsFromAPauseWaitsAndStartsOnceAtTheResume() {
        let world = HSWorld()
        world.launch()
        world.pause()
        world.supervisor.syncNeeded()
        #expect(world.log == ["start", "stop"], "log \(world.log)")
        world.resume()
        world.supervisor.syncNeeded()
        #expect(world.log == ["start", "stop"], "wanted again but the old helper still exits; log \(world.log)")
        world.host.finishExit()
        #expect(world.log == ["start", "stop", "start"], "one start after the exit carries every sync; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func syncNeededWhenIndexingIsNotWantedForAnyOtherReasonStartsNothingAndIsSentAtTheNextStart() {
        let notPressed = HSWorld(startPressed: false)
        notPressed.launch()
        notPressed.supervisor.syncNeeded()
        #expect(notPressed.log.isEmpty, "log \(notPressed.log)")
        notPressed.state.startPressed = true
        notPressed.launch()
        #expect(notPressed.log == ["start"], "Start starts it once, with the sync in that one send; log \(notPressed.log)")

        let deleted = HSWorld(startPressed: true, indexDeleted: true)
        deleted.supervisor.syncNeeded()
        #expect(deleted.log.isEmpty, "log \(deleted.log)")

        let download = HSWorld(modelWhole: false)
        download.supervisor.syncNeeded()
        #expect(download.log.isEmpty, "log \(download.log)")
        download.state.modelWhole = true
        download.launch()
        #expect(download.log == ["start"], "log \(download.log)")

        let quitting = HSWorld()
        quitting.state.quitting = true
        quitting.supervisor.syncNeeded()
        #expect(quitting.log.isEmpty, "log \(quitting.log)")
    }
}

// MARK: plan-2-t35, tester step (1 of 2): the restart of a dead helper (F8)
//
// Everything above this line is sealed from t31 and unchanged. This section is written from the t35 entry (its Tests
// paragraph, first half), design section 1 (`tries`: "the app, not the helper, restarts the helper after any unplanned
// exit while Start is pressed, not paused and work remains") and the t31 names only. No product source was read. The end
// to end half (the bundled helper, 20 photos, two planted crash files) is HelperRestartTests.swift.
//
// API SHAPES t35 adds (the entry names `HelperSupervisor`, `IndexHost`, `StatusCache`, a manual clock, the delays and the
// `changed` event, and fixes no signatures; these are this file's picks, and the t31 pins above keep holding):
//   7. The restart delay seam. `HelperSupervisor.init` gains two parameters AFTER `inputs`, both with default values (so
//      the t31 call `HelperSupervisor(host:inputs:)` above still compiles; the defaults are not pinned):
//        init(host: any IndexHost, inputs: @escaping () -> Inputs,
//             workRemains: @escaping () -> Bool,
//             schedule: @escaping (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void)
//      Both closures are plain (not @Sendable) and are called on the main actor. `schedule` means "run `work` on the main
//      actor after `delay` seconds"; the supervisor calls it for a restart, and `delay` is a plain number of seconds
//      (1, 2, 5, 10, 30 as `TimeInterval`). The manual clock below records every call and runs the work when the test
//      says; the end to end test answers at once whatever the delay ("a delay seam set to 0"). The supervisor never
//      sleeps, never makes a `Timer`, never reads `Date()` for a restart: only `schedule`.
//   8. `workRemains` is "work remains", read from `StatusCache`: in the app it is `{ cache.workRemains }`.
//      `StatusCache.workRemains: Bool` (read-only computed property of the cache's stored snapshot, any thread, calls no
//      source) is true when `snapshot().walkDone` is false, or any kind has `counts.pending` or `counts.partial` rows;
//      false otherwise (`needsPermission` rows and `done` rows are no work). The supervisor asks `workRemains()` when the
//      restart is due (when `schedule`'s work runs), not only when the exit arrives.
//   9. `HelperSupervisor.helperChanged()`: what the app's relay calls for every `changed` event of the index helper. It
//      starts and stops nothing; it sets the next restart delay back to 1 s.
//  10. An unplanned exit (`HelperExit.unplanned(status:)` from `onExit`):
//        - while indexing is wanted (the t31 rule: Start pressed, not deleted, model whole, no pause reason, not
//          quitting) and `workRemains()` holds at that moment, the supervisor makes exactly one `schedule(delay, work)`
//          call with the delay of the ladder 1, 2, 5, 10, 30, 30, 30 ... (the n-th unplanned exit since the last
//          `helperChanged()` takes the n-th value; the 6th and later stay at 30), and when `work` runs and indexing is
//          still wanted and work still remains it makes exactly one `host.start()` (the whole `folders` list once);
//        - `host.start()` is never called before `work` runs: until then neither `reevaluate()` calls with unchanged
//          inputs nor anything else starts the helper early, and `work` run twice makes only the one start;
//        - when indexing is not wanted at the exit, or not wanted when `work` runs, or no work remains when `work` runs,
//          there is no `start()` and no `stopClean()` (there is nothing alive to stop);
//        - a `.planned` exit never uses `schedule` (the t31 rules above: it re-decides at once).
//      Not pinned, on purpose: whether `schedule` is called at all for an exit that will not restart, what a pause and a
//      resume (or a `syncNeeded()`) while a restart is waiting do, the real timer behind the default.

private extension HSHost {
    // The process dies by itself (a crash or a kill), whether or not a clean stop had been asked for. No `stop` or
    // `start` is logged: the app did nothing.
    func crash(status: Int32 = 1) {
        guard isRunning else { return }
        isRunning = false
        exiting = false
        onExit?(.unplanned(status: status))
    }
}

/// A manual clock for the restart delay: records every `schedule` call and runs the work only when told to.
@MainActor private final class RSClock {
    private(set) var delays: [TimeInterval] = []
    private var pending: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        delays.append(delay)
        pending.append(work)
    }

    // Runs the work that is waiting now, oldest first (work scheduled while this runs waits for the next call).
    func fireAll() {
        let due = pending
        pending = []
        for work in due { work() }
    }
}

@MainActor private final class RSWork {
    var remains = true
}

@MainActor private struct RSWorld {
    let state = HSState()
    let host = HSHost()
    let clock = RSClock()
    let work = RSWork()
    let supervisor: HelperSupervisor

    init(startPressed: Bool = true, indexDeleted: Bool = false, modelWhole: Bool = true) {
        let state = state
        let clock = clock
        let work = work
        state.startPressed = startPressed
        state.indexDeleted = indexDeleted
        state.modelWhole = modelWhole
        supervisor = HelperSupervisor(
            host: host,
            inputs: {
                HelperSupervisor.Inputs(startPressed: state.startPressed, indexDeleted: state.indexDeleted,
                                        modelWhole: state.modelWhole, pauseReasons: state.pauses.reasons,
                                        quitting: state.quitting, measuring: state.measuring)
            },
            workRemains: { work.remains },
            schedule: { delay, job in clock.schedule(delay, job) })
    }

    func launch() { supervisor.reevaluate() }

    func pause(_ reason: PauseReason = .you) {
        state.pauses.add(reason)
        supervisor.reevaluate()
    }

    func resume(_ reason: PauseReason = .you) {
        state.pauses.remove(reason)
        supervisor.reevaluate()
    }

    func quit() {
        state.quitting = true
        supervisor.reevaluate()
    }

    var log: [String] { host.log }
}

// MARK: StatusCache.workRemains, over fake sources

private final class WRSources: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: IndexCounts
    private var walkDoneAt: String?
    private var countsCalls = 0
    private var allCalls = 0

    init(counts: IndexCounts, walkDoneAt: String?) {
        self.counts = counts
        self.walkDoneAt = walkDoneAt
    }

    func set(counts: IndexCounts, walkDoneAt: String?) {
        lock.lock(); defer { lock.unlock() }
        self.counts = counts
        self.walkDoneAt = walkDoneAt
    }

    var countsReads: Int { lock.lock(); defer { lock.unlock() }; return countsCalls }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return allCalls }

    func sources() -> StatusSources {
        StatusSources(
            settings: { [self] in
                lock.lock(); allCalls += 1; lock.unlock()
                var settings = Settings()
                settings.startPressed = true
                return settings
            },
            counts: { [self] in
                lock.lock(); allCalls += 1; countsCalls += 1; let value = counts; lock.unlock()
                return value
            },
            meta: { [self] key in
                lock.lock(); allCalls += 1; let value = key == "walk_done_at" ? walkDoneAt : nil; lock.unlock()
                return value
            },
            modelState: { [self] in
                lock.lock(); allCalls += 1; lock.unlock()
                return .whole
            })
    }
}

private func wrDrain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async { continuation.resume() }
    }
}

/// A cache that has loaded `world` once (the refresh has run and stored its value).
@MainActor
private func wrLoaded(_ world: WRSources) async -> (StatusCache, DispatchQueue) {
    let queue = DispatchQueue(label: "sesame.helpersupervisor.workremains.test", qos: .utility)
    let cache = StatusCache(sources: world.sources(), queue: queue)
    cache.refresh()
    _ = await spEventually { world.countsReads >= 1 }
    await wrDrain(queue)
    await spWait(0.2)
    return (cache, queue)
}

extension HelperSupervisorTests {

    // MARK: the restart after an unplanned exit

    @Test func anUnplannedExitWhileIndexingIsWantedAndWorkRemainsRestartsAfterTheDelayWithOneFoldersSend() {
        let world = RSWorld()
        world.launch()
        #expect(world.log == ["start"])
        world.host.crash(status: 9)
        #expect(world.log == ["start"], "no start before the delay is over; log \(world.log)")
        #expect(world.clock.delays == [1], "the first restart waits 1 s; delays \(world.clock.delays)")
        world.supervisor.reevaluate()
        world.supervisor.reevaluate()
        world.supervisor.reevaluate()
        #expect(world.log == ["start"], "an evaluation with nothing changed started the helper before its delay; log \(world.log)")
        #expect(world.host.processes == 1)

        world.clock.fireAll()
        #expect(world.log == ["start", "start"], "the delay is over: one restart, one folders send; log \(world.log)")
        #expect(world.host.processes == 2)
        #expect(world.host.isRunning)
        world.clock.fireAll()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "start"], "the restart happens once; log \(world.log)")
        #expect(world.host.processes == 2)
        #expect(world.clock.delays == [1], "the restart asked for nothing more; delays \(world.clock.delays)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // The 30 s delay is unreachable under the cap of 5: the 5th death in a row stalls and schedules nothing.
    @Test func theRestartDelaysAreOneTwoFiveAndTenSeconds() {
        let world = RSWorld()
        world.launch()
        let expected: [TimeInterval] = [1, 2, 5, 10]
        for (index, delay) in expected.enumerated() {
            world.host.crash()
            #expect(world.clock.delays == Array(expected[...index]),
                    "after \(index + 1) deaths in a row the delays are \(world.clock.delays), expected \(Array(expected[...index])) (the last is \(delay) s)")
            #expect(world.host.starts == index + 1, "a start before its delay: log \(world.log)")
            world.clock.fireAll()
            #expect(world.host.starts == index + 2, "restart \(index + 1) was not made: log \(world.log)")
            #expect(world.host.isRunning)
        }
        #expect(world.host.processes == expected.count + 1)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func aChangedEventBringsTheDelayBackToOneSecond() {
        let world = RSWorld()
        world.launch()
        for _ in 0..<3 {
            world.host.crash()
            world.clock.fireAll()
        }
        #expect(world.clock.delays == [1, 2, 5], "delays \(world.clock.delays)")
        let before = world.log
        world.supervisor.helperChanged()
        #expect(world.log == before, "a changed event started or stopped the helper; log \(world.log)")
        world.host.crash()
        world.clock.fireAll()
        world.host.crash()
        world.clock.fireAll()
        #expect(world.clock.delays == [1, 2, 5, 1, 2], "after a changed event the ladder starts again at 1 s; delays \(world.clock.delays)")
        #expect(world.host.starts == 6, "log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func aChangedEventWithNoDeathChangesNothing() {
        let world = RSWorld()
        world.launch()
        world.supervisor.helperChanged()
        world.supervisor.helperChanged()
        #expect(world.log == ["start"], "log \(world.log)")
        #expect(world.clock.delays.isEmpty, "delays \(world.clock.delays)")
        world.host.crash()
        #expect(world.clock.delays == [1], "delays \(world.clock.delays)")
    }

    @Test func aRestartedHelperIsStoppedCleanlyOnceByALaterPauseAndNothingRestartsIt() {
        let world = RSWorld()
        world.launch()
        world.host.crash()
        world.clock.fireAll()
        world.pause()
        world.supervisor.reevaluate()
        #expect(world.log == ["start", "start", "stop"], "one clean stop of the restarted helper; log \(world.log)")
        world.host.finishExit()
        world.clock.fireAll()
        #expect(world.log == ["start", "start", "stop"], "a planned exit while paused starts nothing; log \(world.log)")
        #expect(world.clock.delays == [1], "a planned exit used the delay seam: \(world.clock.delays)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // MARK: no restart

    @Test func aPlannedExitNeverUsesTheDelaySeamAndIsNeverRestartedByIt() {
        let world = RSWorld()
        world.launch()
        world.pause()
        world.host.finishExit()
        world.clock.fireAll()
        #expect(world.log == ["start", "stop"], "log \(world.log)")
        world.resume()
        #expect(world.log == ["start", "stop", "start"], "a resume starts at once, with no delay; log \(world.log)")
        world.pause()
        world.resume()
        world.host.finishExit()
        #expect(world.log == ["start", "stop", "start", "stop", "start"], "log \(world.log)")
        #expect(world.clock.delays.isEmpty, "a planned exit asked for a restart delay: \(world.clock.delays)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // (name, startPressed, indexDeleted, modelWhole, work remains, a restart is expected). The state holds at the moment
    // of the death; a pause reason is added just before it (that case is its own test below).
    private static let notWanted: [(String, Bool, Bool, Bool, Bool)] = [
        ("Start not pressed", false, false, true, true),
        ("index deleted", true, true, true, true),
        ("model not whole", true, false, false, true),
        ("no work remains", true, false, true, false),
        ("nothing holds", false, true, false, false),
    ]

    @Test func noRestartWhenIndexingIsNotWantedOrNoWorkRemainsAtTheDeath() {
        for (name, pressed, deleted, whole, remains) in Self.notWanted {
            let world = RSWorld()
            world.launch()
            #expect(world.log == ["start"], "\(name): setup \(world.log)")
            world.state.startPressed = pressed
            world.state.indexDeleted = deleted
            world.state.modelWhole = whole
            world.work.remains = remains
            world.host.crash(status: 11)
            world.clock.fireAll()
            world.clock.fireAll()
            #expect(world.log == ["start"], "\(name): the helper died and was started again, or a stop was sent to nothing; log \(world.log)")
            #expect(world.host.processes == 1, "\(name)")
            #expect(world.host.violations.isEmpty, "\(name): \(world.host.violations)")
        }
    }

    @Test func noRestartWhileAnyPauseReasonHoldsAtTheDeath() {
        for reason in [PauseReason.you, .cpu, .lowPower, .battery] {
            let world = RSWorld()
            world.launch()
            world.pause(reason)                     // a clean stop is asked for ...
            #expect(world.log == ["start", "stop"], "\(reason): \(world.log)")
            world.host.crash(status: 11)            // ... and the helper dies instead of exiting 0
            world.clock.fireAll()
            world.supervisor.reevaluate()
            world.clock.fireAll()
            #expect(world.log == ["start", "stop"], "\(reason): restarted while paused, or stopped twice; log \(world.log)")
            #expect(world.host.violations.isEmpty, "\(reason): \(world.host.violations)")
        }
    }

    @Test func noRestartAfterQuitEvenIfTheHelperDiesWhileItIsBeingStopped() {
        let world = RSWorld()
        world.launch()
        world.quit()
        #expect(world.log == ["start", "stop"], "\(world.log)")
        world.host.crash(status: 9)
        world.clock.fireAll()
        world.supervisor.reevaluate()
        world.supervisor.syncNeeded()
        world.clock.fireAll()
        #expect(world.log == ["start", "stop"], "the app is quitting; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // The death was fine to restart from, but the world changed during the delay.
    @Test func noStartWhenThePauseTheQuitTheDeleteOrTheEndOfWorkComesDuringTheDelay() {
        let changes: [(String, (RSWorld) -> Void)] = [
            ("a pause by you", { $0.pause(.you) }),
            ("a pause by cpu", { $0.pause(.cpu) }),
            ("Low Power Mode", { $0.pause(.lowPower) }),
            ("battery", { $0.pause(.battery) }),
            ("Quit", { $0.quit() }),
            ("Delete index", { $0.state.indexDeleted = true; $0.supervisor.reevaluate() }),
            ("Start unpressed", { $0.state.startPressed = false; $0.supervisor.reevaluate() }),
            ("the model going not whole", { $0.state.modelWhole = false; $0.supervisor.reevaluate() }),
            ("the work running out", { $0.work.remains = false; $0.supervisor.reevaluate() }),
        ]
        for (name, change) in changes {
            let world = RSWorld()
            world.launch()
            world.host.crash(status: 9)
            #expect(world.log == ["start"], "\(name): setup \(world.log)")
            change(world)
            world.clock.fireAll()
            #expect(world.log == ["start"], "\(name): the helper was started when the delay ended, or something was stopped that was not running; log \(world.log)")
            #expect(world.host.processes == 1, "\(name)")
            #expect(world.host.violations.isEmpty, "\(name): \(world.host.violations)")
        }
    }

    @Test func workRemainsIsAskedWhenTheRestartIsDueNotOnlyAtTheDeath() {
        let world = RSWorld()
        world.launch()
        world.work.remains = true
        world.host.crash()
        world.work.remains = false
        world.clock.fireAll()
        #expect(world.log == ["start"], "the last file was done during the delay, yet the helper was started; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // MARK: StatusCache.workRemains

    // (name, walk done at, counts, work remains) written by hand from the entry: "a walk not finished, or rows pending or
    // partial".
    private static let workTable: [(String, String?, IndexCounts, Bool)] = [
        ("walk not finished, nothing indexed", nil, IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0), true),
        ("walk not finished, all rows done", nil, IndexCounts(done: 12, pending: [:], partial: [:], needsPermission: 0), true),
        ("walk finished, a photo pending", "1700000000", IndexCounts(done: 12, pending: ["photo": 1], partial: [:], needsPermission: 0), true),
        ("walk finished, a pdf partial", "1700000000", IndexCounts(done: 12, pending: [:], partial: ["pdf": 1], needsPermission: 0), true),
        ("walk finished, pending and partial", "1700000000", IndexCounts(done: 0, pending: ["photo": 3], partial: ["pdf": 2], needsPermission: 0), true),
        ("walk finished, every row done", "1700000000", IndexCounts(done: 12, pending: [:], partial: [:], needsPermission: 0), false),
        ("walk finished, an empty index", "1700000000", IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0), false),
        ("walk finished, only files that need permission", "1700000000", IndexCounts(done: 12, pending: [:], partial: [:], needsPermission: 3), false),
    ]

    @Test func statusCacheSaysWorkRemainsWhenTheWalkIsNotFinishedOrRowsArePendingOrPartial() async {
        for (name, walkDoneAt, counts, expected) in Self.workTable {
            let world = WRSources(counts: counts, walkDoneAt: walkDoneAt)
            let (cache, _) = await wrLoaded(world)
            #expect(cache.workRemains == expected, "\(name): workRemains is \(cache.workRemains), expected \(expected)")
        }
    }

    @Test func statusCacheWorkRemainsFollowsTheNextRefreshAndReadsNoSource() async {
        let world = WRSources(counts: IndexCounts(done: 10, pending: ["photo": 2], partial: [:], needsPermission: 0),
                              walkDoneAt: "1700000000")
        let (cache, queue) = await wrLoaded(world)
        #expect(cache.workRemains, "two photos are pending")
        let reads = world.reads
        for _ in 0..<25 { _ = cache.workRemains }
        #expect(world.reads == reads, "workRemains called a source \(world.reads - reads) times")

        world.set(counts: IndexCounts(done: 12, pending: [:], partial: [:], needsPermission: 0), walkDoneAt: "1700000000")
        #expect(cache.workRemains, "nothing refreshed yet, so the cached answer holds")
        cache.refresh()
        #expect(await spEventually { !cache.workRemains }, "the refresh stored all-done counts, yet work still remains")
        await wrDrain(queue)

        world.set(counts: IndexCounts(done: 12, pending: [:], partial: [:], needsPermission: 0), walkDoneAt: nil)
        cache.refresh()
        #expect(await spEventually { cache.workRemains }, "a walk that is not finished (reset or a new folder) is work")
    }
}

// MARK: plan-2 fix round B, tester step: items B4 (the `measuring` input) and B11 (a sync asked for while paused)
//
// Everything above this line is sealed and unchanged except the two helper closures (`HSWorld`, `RSWorld`), which now
// pass the new input `measuring` from `HSState.measuring` (default false). Written from the fix-round document (B4: "the
// supervisor's inputs gain a `measuring` flag and the index helper is not started until the bench has finished"; B11:
// "removing or unticking a folder while paused: `syncNeeded` remembers a pending sync and sends it when indexing is next
// wanted (resume) even when no folder changed since") and the t31 and t35 pins above. No product source was read.
//
// API SHAPE B4 pins (new): `HelperSupervisor.Inputs` gains a last stored property `measuring: Bool`, so the memberwise
// init reads
//     Inputs(startPressed:indexDeleted:modelWhole:pauseReasons:quitting:measuring:)
// and `measuring` has the default value false, so every sealed call that omits it still compiles (AppLifecycleTests,
// HelperRestartTests, the two worlds above before this edit). Rule: indexing is wanted exactly when startPressed, not
// indexDeleted, modelWhole, `pauseReasons` empty, not quitting AND NOT measuring. Nothing is said about a helper that is
// already running when `measuring` turns true: the bench is started only when no index helper runs (the app's ordering),
// so that case does not arise and is not pinned.
//
// B11 is a GUARD: the supervisor already sends `folders` at every start, so a sync asked for while paused is carried by
// the one start of the resume. The test keeps that from being lost when `measuring` is added.

extension HelperSupervisorTests {

    @Test func indexingIsNotWantedWhileTheSpeedBenchRunsAndStartsOnceWhenItEnds() {
        let world = HSWorld()
        world.state.measuring = true
        world.launch()
        world.launch()
        world.supervisor.syncNeeded()
        #expect(world.log.isEmpty, "the bench is running, yet the helper was started or stopped: log \(world.log)")

        world.state.measuring = false
        world.launch()
        #expect(world.log == ["start"], "the bench ended: one start, carrying the sync asked for meanwhile; log \(world.log)")
        world.launch()
        world.launch()
        #expect(world.log == ["start"], "a repeated evaluation started a second helper; log \(world.log)")
        #expect(world.host.processes == 1)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // (name, startPressed, indexDeleted, modelWhole, reasons, quitting, a start is expected after the bench ends)
    private static let measuringTable: [(String, Bool, Bool, Bool, Set<PauseReason>, Bool, Bool)] = [
        ("everything else holds", true, false, true, [], false, true),
        ("Start not pressed", false, false, true, [], false, false),
        ("index deleted", true, true, true, [], false, false),
        ("model not whole", true, false, false, [], false, false),
        ("paused by you", true, false, true, [.you], false, false),
        ("paused by the battery", true, false, true, [.battery], false, false),
        ("quitting", true, false, true, [], true, false),
    ]

    @Test func theBenchOnlyHoldsBackAStartThatWouldOtherwiseHappen() {
        for (name, pressed, deleted, whole, reasons, quitting, startsAfter) in Self.measuringTable {
            let world = HSWorld(startPressed: pressed, indexDeleted: deleted, modelWhole: whole)
            for reason in reasons { world.state.pauses.add(reason) }
            world.state.quitting = quitting
            world.state.measuring = true
            world.launch()
            #expect(world.log.isEmpty, "\(name): started while the bench ran; log \(world.log)")

            world.state.measuring = false
            world.launch()
            #expect(world.host.starts == (startsAfter ? 1 : 0), "\(name): expected \(startsAfter ? "one start" : "no start") after the bench; log \(world.log)")
            #expect(world.host.stops == 0, "\(name): nothing ran, so nothing is stopped; log \(world.log)")
            #expect(world.host.violations.isEmpty, "\(name): \(world.host.violations)")
        }
    }

    @Test func aPauseAndAResumeDuringTheBenchStartNothingUntilTheBenchEnds() {
        let world = HSWorld()
        world.state.measuring = true
        world.launch()
        world.pause(.you)
        world.resume(.you)
        #expect(world.log.isEmpty, "the bench still runs after a pause and a resume; log \(world.log)")
        world.state.measuring = false
        world.supervisor.reevaluate()
        #expect(world.log == ["start"], "log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // GUARD (B11): passes today.
    @Test func aFolderRemovedWhilePausedIsSentAtTheResumeEvenWhenNoFolderChangedSince() {
        for reason in [PauseReason.battery, .lowPower, .cpu, .you] {
            let world = HSWorld()
            world.launch()
            world.pause(reason)
            world.host.finishExit()
            // the person removed or unticked a folder while Sesame was paused: its rows stay in the index until a helper runs
            world.supervisor.syncNeeded()
            world.supervisor.reevaluate()
            #expect(world.log == ["start", "stop"], "\(reason): a helper was started while paused; log \(world.log)")

            world.resume(reason)
            #expect(world.log == ["start", "stop", "start"], "\(reason): the resume made no start that re-sends the folders; log \(world.log)")

            // nothing is left over: the next pause and resume is one start, not two
            world.pause(reason)
            world.host.finishExit()
            world.resume(reason)
            #expect(world.log == ["start", "stop", "start", "stop", "start"], "\(reason): log \(world.log)")
            #expect(world.host.violations.isEmpty, "\(reason): \(world.host.violations)")
        }
    }
}

// MARK: plan-3-t20, tester step: an idle exit is not a death, and restarts have a cap
//
// Everything above this line is sealed and unchanged. Written from the t20 entry of plan-3-tasks.md (its Tests paragraph),
// Decision D11 and the sealed t31 and t35 pins above; no product source was read. Every expected value is written by hand.
//
// API SHAPES t20 adds (the entry names them and fixes no signatures; if a shape is wrong, ask for a test change):
//   11. `HelperExit.idle` (see HelperClientTests): what `IndexHost.onExit` hands over for an exit 0 nobody asked for.
//   12. `HelperSupervisor.maxDeaths`: a static number, 5.
//   13. `var onStalled: (() -> Void)?` on `HelperSupervisor`, set by the owner after init (t21 wires it:
//       `supervisor.onStalled = { ... }`). Called synchronously, on the main actor, from the exit handler that finds the
//       stall, never from `reevaluate()` or `syncNeeded()`. "Stalled" is one state with two causes: the death cap, and an
//       idle exit while indexing is wanted and work remains (`workRemains()` true at the exit).
//   14. `func resetStall()`: clears the stall and the death count (the next death restarts after 1 s). It starts nothing
//       itself (the owner calls `reevaluate()` after it, t21); the tests below call `reevaluate()` after it and do not
//       pin whether `resetStall()` itself starts the helper.
//   15. `helperChanged()` (t35 pin 9) also clears the death count and the stall, and still starts and stops nothing.
//   16. The cap (D11): the 5th death in a row with no `helperChanged()` or `resetStall()` between them is not restarted:
//       nothing is scheduled for it and `onStalled` is called once. The deaths 1 to 4 restart after 1, 2, 5 and 10 s. [pick:
//       "the fifth in a row stops the restarts" is D11's wording; the reading "five restarts, then the sixth death
//       stalls" is the other possible one and is NOT what these tests pin.]
//   17. While stalled, `reevaluate()` and `syncNeeded()` start nothing. A death after the stall (a helper started by
//       something else, e.g. a preview, that dies) schedules nothing, starts nothing and calls nothing.
//   18. An `.idle` exit is never a death: it adds nothing to the death count and never schedules a restart.

private extension HSHost {
    // The helper exits 0 by itself after its stdin was not closed by the app: its own idle exit.
    func idleExit() {
        guard isRunning else { return }
        isRunning = false
        exiting = false
        onExit?(.idle)
    }
}

private final class STStalls {
    var count = 0
}

@MainActor private func stWatch(_ world: RSWorld) -> STStalls {
    let stalls = STStalls()
    world.supervisor.onStalled = { stalls.count += 1 }
    return stalls
}

// `deaths` deaths in a row, each followed by the restart its delay allows. The helper is running again afterwards.
@MainActor private func stDieAndRestart(_ world: RSWorld, times: Int) {
    for _ in 0..<times {
        world.host.crash()
        world.clock.fireAll()
    }
}

extension HelperSupervisorTests {

    @Test func theCapIsFiveDeathsInARow() {
        #expect(HelperSupervisor.maxDeaths == 5)
    }

    // MARK: an idle exit with no work left

    @Test func anIdleExitWithNoWorkLeftStartsNothingSchedulesNothingAndDoesNotStall() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        world.work.remains = false
        world.host.idleExit()
        #expect(world.log == ["start"], "an idle exit restarted the helper or stopped something; log \(world.log)")
        #expect(world.clock.delays.isEmpty, "an idle exit asked for a restart delay: \(world.clock.delays)")
        #expect(stalls.count == 0, "nothing is left to do, yet onStalled was called \(stalls.count) times")
        world.clock.fireAll()
        #expect(world.log == ["start"], "log \(world.log)")
        #expect(world.host.isRunning == false)

        // a later change starts as before
        world.supervisor.syncNeeded()
        #expect(world.log == ["start", "start"], "syncNeeded after an idle exit must start the helper as before; log \(world.log)")
        #expect(world.host.isRunning)
        #expect(world.host.processes == 2)
        #expect(stalls.count == 0)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func idleExitsWithNoWorkLeftAreNotDeathsSoNeitherTheLadderNorTheCapAdvance() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        // four real deaths (delays 1, 2, 5, 10), each followed by an idle exit with no work left and a sync that starts again
        for _ in 0..<4 {
            world.work.remains = true
            world.host.crash()
            world.clock.fireAll()
            world.work.remains = false
            world.host.idleExit()
            world.supervisor.syncNeeded()
            #expect(world.host.isRunning, "syncNeeded did not start the helper after an idle exit; log \(world.log)")
        }
        #expect(world.clock.delays == [1, 2, 5, 10],
                "idle exits moved the delay ladder: \(world.clock.delays), expected [1, 2, 5, 10]")
        #expect(stalls.count == 0, "onStalled was called \(stalls.count) times after four deaths and four idle exits")

        // many more idle exits never stall, never schedule, and every sync starts the helper
        let startsBefore = world.host.starts
        for round in 1...6 {
            world.work.remains = false
            world.host.idleExit()
            world.supervisor.syncNeeded()
            #expect(world.host.isRunning, "idle exit \(round): the sync did not start the helper; log \(world.log)")
        }
        #expect(world.host.starts == startsBefore + 6, "log \(world.log)")
        #expect(world.clock.delays == [1, 2, 5, 10], "an idle exit scheduled a restart: \(world.clock.delays)")
        #expect(stalls.count == 0)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // MARK: an idle exit with work left is told to the person

    @Test func anIdleExitWithWorkLeftStartsNothingSchedulesNothingAndCallsOnStalledOnce() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        world.work.remains = true
        world.host.idleExit()
        #expect(stalls.count == 1, "rows are still pending and no helper runs: onStalled must be called once, got \(stalls.count)")
        #expect(world.log == ["start"], "an idle exit restarted the helper; log \(world.log)")
        #expect(world.clock.delays.isEmpty, "an idle exit is not a death, yet a restart was scheduled: \(world.clock.delays)")
        #expect(world.host.isRunning == false)

        world.clock.fireAll()
        world.supervisor.reevaluate()
        world.supervisor.reevaluate()
        world.supervisor.syncNeeded()
        #expect(stalls.count == 1, "onStalled was called again by an evaluation: \(stalls.count)")
        #expect(world.log == ["start"], "a stalled supervisor started the helper; log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func anIdleExitWhileIndexingIsNotWantedCallsNothingAndStartsNothing() {
        // Start unpressed, Delete index, model not whole, a pause reason and Quit: there is nobody to tell and nothing to start.
        let cases: [(String, (RSWorld) -> Void)] = [
            ("Start unpressed", { $0.state.startPressed = false }),
            ("index deleted", { $0.state.indexDeleted = true }),
            ("model not whole", { $0.state.modelWhole = false }),
            ("paused by cpu", { $0.state.pauses.add(.cpu) }),
            ("quitting", { $0.state.quitting = true }),
        ]
        for (name, change) in cases {
            let world = RSWorld()
            let stalls = stWatch(world)
            world.launch()
            change(world)
            world.work.remains = true
            world.host.idleExit()
            world.clock.fireAll()
            #expect(world.log == ["start"], "\(name): log \(world.log)")
            #expect(world.clock.delays.isEmpty, "\(name): \(world.clock.delays)")
            #expect(stalls.count == 0, "\(name): onStalled was called though indexing is not wanted")
            #expect(world.host.violations.isEmpty, "\(name): \(world.host.violations)")
        }
    }

    @Test func whileStalledByAnIdleExitNothingStartsUntilHelperChangedOrResetStall() {
        // (name, the call that ends the stall)
        let clears: [(String, (RSWorld) -> Void)] = [
            ("helperChanged", { $0.supervisor.helperChanged() }),
            ("resetStall", { $0.supervisor.resetStall() }),
        ]
        for (name, clear) in clears {
            let world = RSWorld()
            let stalls = stWatch(world)
            world.launch()
            world.host.idleExit()
            #expect(stalls.count == 1, "\(name): setup, stalls \(stalls.count)")

            world.supervisor.reevaluate()
            world.supervisor.syncNeeded()
            world.supervisor.syncNeeded()
            world.pause(.you)
            world.resume(.you)
            world.clock.fireAll()
            #expect(world.log == ["start"], "\(name): a stalled supervisor started or stopped the helper; log \(world.log)")
            #expect(world.clock.delays.isEmpty, "\(name): \(world.clock.delays)")
            #expect(stalls.count == 1, "\(name): onStalled again: \(stalls.count)")

            clear(world)
            if name == "helperChanged" {
                #expect(world.log == ["start"], "helperChanged started or stopped the helper; log \(world.log)")
            }
            world.supervisor.reevaluate()
            #expect(world.host.isRunning, "\(name): after the stall ended, reevaluate must start the helper; log \(world.log)")
            #expect(world.host.processes == 2, "\(name): processes \(world.host.processes), log \(world.log)")
            #expect(stalls.count == 1, "\(name): onStalled was called by the clearing: \(stalls.count)")
            #expect(world.host.violations.isEmpty, "\(name): \(world.host.violations)")
        }
    }

    @Test func afterHelperChangedASyncStartsTheHelperAgainOnAStalledIdleExit() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        world.host.idleExit()
        world.supervisor.syncNeeded()
        #expect(world.log == ["start"], "stalled: log \(world.log)")
        world.supervisor.helperChanged()
        world.supervisor.syncNeeded()
        #expect(world.host.isRunning, "a change after the stall must start the helper; log \(world.log)")
        #expect(world.host.processes == 2)
        #expect(stalls.count == 1)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func resetStallAfterAnIdleStallRearmsTheDelayAndALaterStallCallsOnStalledAgain() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        stDieAndRestart(world, times: 2)
        #expect(world.clock.delays == [1, 2], "setup \(world.clock.delays)")
        world.host.idleExit()
        #expect(stalls.count == 1)

        world.supervisor.resetStall()
        world.supervisor.reevaluate()
        #expect(world.host.isRunning, "log \(world.log)")
        world.host.crash()
        #expect(world.clock.delays == [1, 2, 1], "after resetStall the next death restarts after 1 s; delays \(world.clock.delays)")
        world.clock.fireAll()
        #expect(world.host.isRunning)

        world.host.idleExit()
        #expect(stalls.count == 2, "a later idle exit with work left calls onStalled again; got \(stalls.count)")
        #expect(world.clock.delays == [1, 2, 1])
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    // MARK: the cap

    @Test func fourDeathsInARowAreAllRestartedAndTheFifthIsNotAndCallsOnStalledOnce() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        stDieAndRestart(world, times: 4)
        #expect(world.clock.delays == [1, 2, 5, 10], "delays \(world.clock.delays)")
        #expect(world.host.starts == 5, "log \(world.log)")
        #expect(world.host.isRunning)
        #expect(stalls.count == 0, "onStalled before the cap: \(stalls.count)")

        world.host.crash()
        #expect(world.clock.delays == [1, 2, 5, 10], "the fifth death in a row scheduled a restart: \(world.clock.delays)")
        #expect(stalls.count == 1, "the fifth death in a row must call onStalled once, got \(stalls.count)")
        world.clock.fireAll()
        #expect(world.host.starts == 5, "the fifth death was restarted; log \(world.log)")
        #expect(world.host.isRunning == false)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func whileStalledByTheCapReevaluateAndSyncNeededStartNothing() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        stDieAndRestart(world, times: 4)
        world.host.crash()
        #expect(stalls.count == 1)
        let startsAtStall = world.host.starts

        for _ in 0..<3 {
            world.supervisor.reevaluate()
            world.supervisor.syncNeeded()
            world.clock.fireAll()
        }
        world.pause(.you)
        world.resume(.you)
        #expect(world.host.starts == startsAtStall, "a stalled supervisor started the helper; log \(world.log)")
        #expect(world.host.stops == 0, "nothing was running, so nothing is stopped; log \(world.log)")
        #expect(world.host.isRunning == false)
        #expect(world.clock.delays == [1, 2, 5, 10], "\(world.clock.delays)")
        #expect(stalls.count == 1, "onStalled was called again: \(stalls.count)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func aDeathAfterTheStallSchedulesNothingStartsNothingAndCallsNothing() {
        // the helper is started by something other than the supervisor (a preview or a reset sent by the app) while stalled
        let capped = RSWorld()
        let cappedStalls = stWatch(capped)
        capped.launch()
        stDieAndRestart(capped, times: 4)
        capped.host.crash()
        #expect(cappedStalls.count == 1)
        let startsAtStall = capped.host.starts
        capped.host.start()
        #expect(capped.host.isRunning, "setup: the direct start did not run a process")
        capped.host.crash()
        capped.clock.fireAll()
        #expect(capped.clock.delays == [1, 2, 5, 10], "a death after the stall scheduled a restart: \(capped.clock.delays)")
        #expect(capped.host.starts == startsAtStall + 1, "only the direct start is in the log; log \(capped.log)")
        #expect(cappedStalls.count == 1, "a death after the stall called onStalled again: \(cappedStalls.count)")

        let idle = RSWorld()
        let idleStalls = stWatch(idle)
        idle.launch()
        idle.host.idleExit()
        #expect(idleStalls.count == 1)
        idle.host.start()
        idle.host.crash()
        idle.clock.fireAll()
        #expect(idle.clock.delays.isEmpty, "a death after the idle stall scheduled a restart: \(idle.clock.delays)")
        #expect(idle.host.starts == 2, "log \(idle.log)")
        #expect(idleStalls.count == 1, "a death after the idle stall called onStalled again: \(idleStalls.count)")
        #expect(idle.host.violations.isEmpty && capped.host.violations.isEmpty)
    }

    @Test func helperChangedClearsTheDeathCountSoDeathsAfterItStartAtOneSecondAndNeverCapEarly() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        stDieAndRestart(world, times: 4)
        world.supervisor.helperChanged()
        stDieAndRestart(world, times: 4)
        #expect(world.clock.delays == [1, 2, 5, 10, 1, 2, 5, 10], "delays \(world.clock.delays)")
        #expect(world.host.starts == 9, "log \(world.log)")
        #expect(stalls.count == 0, "eight deaths with a change between the fours must not stall; got \(stalls.count)")
        #expect(world.host.isRunning)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func helperChangedEndsTheStallOfTheCapAndTheNextDeathRestartsAfterOneSecond() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        stDieAndRestart(world, times: 4)
        world.host.crash()
        #expect(stalls.count == 1)

        world.supervisor.helperChanged()
        world.supervisor.reevaluate()
        #expect(world.host.isRunning, "after a change the stall is over and reevaluate starts the helper; log \(world.log)")
        world.host.crash()
        #expect(world.clock.delays == [1, 2, 5, 10, 1], "delays \(world.clock.delays)")
        world.clock.fireAll()
        #expect(world.host.isRunning, "the death after the change was not restarted; log \(world.log)")
        #expect(stalls.count == 1)
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func resetStallRearmsTheCapTheNextDeathRestartsAfterOneSecondAndALaterCapCallsOnStalledAgain() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        stDieAndRestart(world, times: 4)
        world.host.crash()
        #expect(stalls.count == 1)

        world.supervisor.resetStall()
        world.supervisor.reevaluate()
        #expect(world.host.isRunning, "after resetStall, reevaluate must start the helper; log \(world.log)")
        world.host.crash()
        #expect(world.clock.delays == [1, 2, 5, 10, 1], "after resetStall the next death restarts after 1 s; delays \(world.clock.delays)")
        world.clock.fireAll()
        stDieAndRestart(world, times: 3)
        #expect(world.clock.delays == [1, 2, 5, 10, 1, 2, 5, 10], "delays \(world.clock.delays)")
        #expect(stalls.count == 1, "four deaths since the reset are not a cap yet; got \(stalls.count)")

        world.host.crash()
        #expect(world.clock.delays == [1, 2, 5, 10, 1, 2, 5, 10], "the fifth death since the reset was restarted: \(world.clock.delays)")
        #expect(stalls.count == 2, "a later cap must call onStalled again; got \(stalls.count)")
        world.clock.fireAll()
        world.supervisor.reevaluate()
        #expect(world.host.isRunning == false, "log \(world.log)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }

    @Test func resetStallWithNothingStalledChangesNothing() {
        let world = RSWorld()
        let stalls = stWatch(world)
        world.launch()
        world.supervisor.resetStall()
        #expect(stalls.count == 0)
        #expect(world.log == ["start"], "resetStall started or stopped a running helper; log \(world.log)")
        world.host.crash()
        #expect(world.clock.delays == [1], "delays \(world.clock.delays)")
        #expect(world.host.violations.isEmpty, "\(world.host.violations)")
    }
}

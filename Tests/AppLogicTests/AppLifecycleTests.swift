import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t32, tester step: the app's lifecycle, that is what a launch decides, what Quit does, and what the menu's
// actions do (S7.1, S7.2, S7.10 relaunch resume, S7.11 Quit leaves the index and the settings, S1.29 the menu).
// Written from the t32 entry of plan-2-tasks.md (its Tests paragraph), design section 3 ("a resume after pause" starts a
// new `index` helper and sends `folders`), design section 6 (pause reasons are a set, "Resume anyway, on battery" removes
// only battery), decisions D8 and D11 of that file, and the sealed tests of earlier tasks as the one place existing names
// are read (`Settings`, `SettingsFile`, `PauseSet`, `PauseReason`, `LoadMonitor` and its seams from t30,
// `HelperSupervisor`, `IndexHost`, `HelperExit` from t31, `MenuActions` from t28). No product source was read. Every
// expected value below is written by hand from those texts; none is computed by the code under test. No app is
// launched, no status item or window is created, no process is started, and nothing terminates the test process.
//
// API SHAPES these tests pin. The entry names `LaunchPlan.decide(settings:modelWhole:indexFileExists:)`, `QuitPlan`,
// "a fake HelperSupervisor", "a manual clock", `MenuActions` over fakes and the `LoadMonitor` started at launch, and fixes
// no other signature; the rest are this file's picks. If a shape is wrong, ask for a test change rather than guessing.
// All new names go in the files of the entry's Files list (`AppLifecycle.swift`, `MenuActions.swift`); `MenuActions` is
// NOT redefined (its struct is in MenuBuilder.swift since t28; MenuActions.swift builds the real actions on top of it).
//
//   1. `struct LaunchPlan: Equatable` with these readable members, and
//        static func decide(settings: Settings, modelWhole: Bool, indexFileExists: Bool) -> LaunchPlan
//        var showsSetup: Bool                     // the setup window opens. It is also the window that holds the model
//                                                 // download, so "shows the download" of the entry is `showsSetup`
//                                                 // true with the model not whole (as `SetupFlow.needed`, t20, reads it)
//        var startsIndexing: Bool                 // indexing resumes by itself now (no window, no press)
//        var defersIndexingUntilModelWhole: Bool  // Start was pressed but the model is not whole: wait for it
//        var requestsReset: Bool                  // the crash recovery of t22: send `reset` again
//      `Settings()` is a fresh install (startPressed false, indexDeleted false). A launch never writes anything.
//   2. `@MainActor final class QuitPlan`
//        init(stopIndexing: @escaping () -> Void,
//             shutdownHelpers: @escaping (_ timeout: TimeInterval, _ completion: @escaping @Sendable () -> Void) -> Void,
//             terminate: @escaping () -> Void)
//        func begin()
//      `stopIndexing` is what the app does to make the supervisor stop (it sets the supervisor's `quitting` input and calls
//      `reevaluate()`); the tests give it exactly that over a real `HelperSupervisor` and a fake `IndexHost`, so "a fake
//      HelperSupervisor" of the entry is the supervisor over a fake host. `shutdownHelpers` is the seam over
//      `HelperClient.shutdown(timeout:completion:)` (t31): it ends BOTH helpers' stdin and calls `completion` once both
//      have exited, after killing any that is still alive `timeout` seconds later (the manual clock of the entry lives in
//      the fake that stands behind this seam). `terminate` ends the app. `begin()` calls `stopIndexing` once, then
//      `shutdownHelpers(4, ...)` once (4 seconds exactly), and calls `terminate` once, on the main thread, only after
//      `completion` has been called, whichever thread `completion` is called on. When `completion` is called ON the main
//      thread, `terminate` has already run when that call returns (no hop through the run loop: the manual clock of the
//      tests is synchronous); from another thread it runs soon after, on the main thread. A second `begin()` (Command+Q twice,
//      Quit while quitting) does nothing more. Quit deletes nothing and writes nothing.
//   3. `AppLifecycle` (an enum with static functions, in AppLifecycle.swift):
//        @MainActor static func launch(monitor: LoadMonitor,
//                                      settingsChanged: @escaping () -> Void,
//                                      reevaluate: @escaping () -> Void)
//      It is what the app does at launch after `LaunchPlan.decide`: it sets `monitor.onChange` (the monitor's changes are
//      the only thing that sets it), starts the monitor FIRST (a Mac that wakes up on battery is paused at once, so the
//      helper is never started and then stopped), then calls `reevaluate()` (the supervisor's decision, which resumes
//      indexing by itself when Start was pressed, S7.10). Each later change the monitor makes calls `settingsChanged()`
//      once and `reevaluate()` once, after `monitor.pauseSet` holds the new state. The tests never set `onChange`.
//   4. `MenuActions.live(...)`, an extension of the t28 struct in MenuActions.swift:
//        @MainActor static func live(monitor: LoadMonitor,
//                                    settingsChanged: @escaping () -> Void,
//                                    reevaluate: @escaping () -> Void,
//                                    openPanel: @escaping () -> Void,
//                                    openSettings: @escaping () -> Void,
//                                    quit: QuitPlan) -> MenuActions
//      The pause set is `monitor.pauseSet`: the one the load monitor writes into. `pause` adds `.you`, `resume` removes
//      `.you`, `resumeAnyway` calls `pauseSet.resumeAnyway()`; each of the three calls `settingsChanged()` once and
//      `reevaluate()` once, after the pause set holds the new state. `open` calls `openPanel` once and `settings` calls
//      `openSettings` once, and neither touches the pause set, `settingsChanged` or `reevaluate`. `quit` calls
//      `quit.begin()` once and nothing else. `settingsChanged` is `StatusCache.settingsChanged()` in the app and
//      `reevaluate` is `HelperSupervisor.reevaluate()`; closures keep the tests free of a window, a status cache and a
//      process.
// Not pinned, on purpose: what `LaunchPlan` says for a launch with `indexDeleted` true and the model not whole beyond
// "starts nothing" and the reset flag, what `defersIndexingUntilModelWhole` is for a launch that never pressed Start,
// the order of `settingsChanged` and `reevaluate` inside one action, how many monitor changes `start()` makes when two
// reasons hold at launch, what `launch` does if called twice, `QuitPlan` on a thread other than the main actor, and any
// window or `NSApplication` call.
//
// SUITE PLACEMENT. One test sets HOME (process-wide, as the other Setup and Settings suites do), so this suite is nested
// inside `ModelDownloadTests` and runs one at a time with the other HOME suites. Side effect: `swift test --filter
// ModelDownloadTests` also runs these tests.

// MARK: the launch table

private func alSettings(startPressed: Bool = false, indexDeleted: Bool = false, folders: [Settings.Folder] = []) -> Settings {
    var settings = Settings()
    settings.startPressed = startPressed
    settings.indexDeleted = indexDeleted
    settings.folders = folders
    return settings
}

private var alTicked: [Settings.Folder] { [Settings.Folder(path: "/Users/test/Pictures", code: false, reading: true)] }

private struct ALLaunchRow {
    let name: String
    let settings: Settings
    let modelWhole: Bool
    let indexFileExists: Bool
    // nil means "not pinned for this row"
    let showsSetup: Bool?
    let startsIndexing: Bool
    let defers: Bool?
    let requestsReset: Bool
}

private var alLaunchTable: [ALLaunchRow] { [
    // a first run: setup, nothing started
    ALLaunchRow(name: "first run, model whole", settings: alSettings(), modelWhole: true, indexFileExists: false,
                showsSetup: true, startsIndexing: false, defers: nil, requestsReset: false),
    ALLaunchRow(name: "first run, model downloading", settings: alSettings(), modelWhole: false, indexFileExists: false,
                showsSetup: true, startsIndexing: false, defers: nil, requestsReset: false),
    ALLaunchRow(name: "first run with a stray index file", settings: alSettings(), modelWhole: true, indexFileExists: true,
                showsSetup: true, startsIndexing: false, defers: nil, requestsReset: false),
    // D11: Finish without Start leaves startPressed false, so the setup shows again until Start was pressed once
    ALLaunchRow(name: "setup finished without Start, folders ticked", settings: alSettings(folders: alTicked),
                modelWhole: true, indexFileExists: false,
                showsSetup: true, startsIndexing: false, defers: nil, requestsReset: false),
    // S7.10: Start was pressed, the model is whole: indexing resumes by itself, no window
    ALLaunchRow(name: "Start pressed, model whole, index present", settings: alSettings(startPressed: true, folders: alTicked),
                modelWhole: true, indexFileExists: true,
                showsSetup: false, startsIndexing: true, defers: false, requestsReset: false),
    ALLaunchRow(name: "Start pressed, model whole, index file not made yet", settings: alSettings(startPressed: true, folders: alTicked),
                modelWhole: true, indexFileExists: false,
                showsSetup: false, startsIndexing: true, defers: false, requestsReset: false),
    ALLaunchRow(name: "Start pressed, nothing ticked, model whole", settings: alSettings(startPressed: true),
                modelWhole: true, indexFileExists: true,
                showsSetup: false, startsIndexing: true, defers: false, requestsReset: false),
    // Start was pressed but the model is not whole: the download is shown and indexing waits
    ALLaunchRow(name: "Start pressed, model not whole, index present", settings: alSettings(startPressed: true, folders: alTicked),
                modelWhole: false, indexFileExists: true,
                showsSetup: true, startsIndexing: false, defers: true, requestsReset: false),
    ALLaunchRow(name: "Start pressed, model not whole, no index", settings: alSettings(startPressed: true, folders: alTicked),
                modelWhole: false, indexFileExists: false,
                showsSetup: true, startsIndexing: false, defers: true, requestsReset: false),
    // indexDeleted: no setup, nothing started, and a leftover index file asks for `reset` again (t22)
    ALLaunchRow(name: "index deleted, model whole, index file still there", settings: alSettings(indexDeleted: true, folders: alTicked),
                modelWhole: true, indexFileExists: true,
                showsSetup: false, startsIndexing: false, defers: nil, requestsReset: true),
    ALLaunchRow(name: "index deleted, model whole, index file gone", settings: alSettings(indexDeleted: true, folders: alTicked),
                modelWhole: true, indexFileExists: false,
                showsSetup: false, startsIndexing: false, defers: nil, requestsReset: false),
    ALLaunchRow(name: "index deleted, model not whole, index file still there", settings: alSettings(indexDeleted: true),
                modelWhole: false, indexFileExists: true,
                showsSetup: nil, startsIndexing: false, defers: nil, requestsReset: true),
    ALLaunchRow(name: "index deleted, model not whole, index file gone", settings: alSettings(indexDeleted: true),
                modelWhole: false, indexFileExists: false,
                showsSetup: nil, startsIndexing: false, defers: nil, requestsReset: false),
] }

// MARK: fakes shared by the quit and menu tests

// The fake `IndexHost` of the supervisor (the same contract as the t31 tests): ONE helper, an exiting one counts as alive.
@MainActor private final class ALHost: IndexHost {
    private(set) var isRunning = false
    private(set) var exiting = false
    var onExit: ((HelperExit) -> Void)?
    private(set) var log: [String] = []
    private(set) var violations: [String] = []

    var starts: Int { log.filter { $0 == "start" }.count }
    var stops: Int { log.filter { $0 == "stop" }.count }

    func start() {
        log.append("start")
        if exiting {
            violations.append("start() while the old helper was still exiting (log \(log))")
            return
        }
        isRunning = true
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

    // The helper finishes its unit and exits 0 after its stdin ended: a planned exit.
    func finishExit() {
        guard isRunning else { return }
        isRunning = false
        exiting = false
        onExit?(.planned)
    }
}

@MainActor private final class ALState {
    var startPressed = true
    var indexDeleted = false
    var modelWhole = true
    var quitting = false
}

// The calls the closures of the world make, in order, with the pause reasons that held at the moment of each call.
@MainActor private final class ALLog {
    private(set) var events: [String] = []
    private(set) var reasonsAtCall: [String: [Set<PauseReason>]] = [:]
    private(set) var terminations: [(at: TimeInterval, onMainThread: Bool)] = []

    func note(_ name: String, reasons: Set<PauseReason>? = nil) {
        events.append(name)
        if let reasons { reasonsAtCall[name, default: []].append(reasons) }
    }

    func noteTermination(at time: TimeInterval) {
        events.append("terminate")
        terminations.append((time, Thread.isMainThread))
    }

    func count(_ name: String) -> Int { events.filter { $0 == name }.count }
    func reasons(_ name: String) -> [Set<PauseReason>] { reasonsAtCall[name] ?? [] }

    func clear() {
        events.removeAll()
        reasonsAtCall.removeAll()
    }
}

// The two helpers (`index` and `encode`) as the real `HelperClient.shutdown(timeout:completion:)` treats them: it ends
// both stdins, calls `completion` once both are gone, and kills one still alive `timeout` seconds after the call. The
// manual clock is `now`; a test moves it with `advance(by:)` and makes a helper finish its unit with `exit(_:)`.
@MainActor private final class ALHelpers {
    private(set) var now: TimeInterval = 0
    private(set) var alive: Set<String> = ["index", "encode"]
    private(set) var asked: [TimeInterval] = []
    private(set) var killed: [String] = []
    private var deadline: TimeInterval?
    private var completion: (@Sendable () -> Void)?
    private var completed = false
    private let log: ALLog
    // Call `completion` from a background queue, as the real client may.
    var completeFromBackground = false

    init(log: ALLog) { self.log = log }

    func shutdown(timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
        log.note("shutdown")
        asked.append(timeout)
        self.completion = completion
        deadline = now + timeout
        finishIfGone()
    }

    func exit(_ name: String) {
        alive.remove(name)
        finishIfGone()
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        if let deadline, now >= deadline, !alive.isEmpty {
            for name in alive.sorted() { killed.append(name) }
            alive.removeAll()
        }
        finishIfGone()
    }

    private func finishIfGone() {
        guard alive.isEmpty, let completion, !completed else { return }
        completed = true
        if completeFromBackground {
            DispatchQueue.global().async { completion() }
        } else {
            completion()
        }
    }
}

// The quit side of the world: a real supervisor over the fake host, the fake helpers, and a `QuitPlan` over them.
@MainActor private struct ALQuitWorld {
    let state = ALState()
    let host = ALHost()
    let log = ALLog()
    let helpers: ALHelpers
    let supervisor: HelperSupervisor
    let plan: QuitPlan

    init() {
        let state = state
        let host = host
        let log = log
        let helpers = ALHelpers(log: log)
        self.helpers = helpers
        let supervisor = HelperSupervisor(host: host, inputs: {
            HelperSupervisor.Inputs(startPressed: state.startPressed, indexDeleted: state.indexDeleted,
                                    modelWhole: state.modelWhole, pauseReasons: [], quitting: state.quitting)
        })
        self.supervisor = supervisor
        plan = QuitPlan(
            stopIndexing: {
                log.note("stopIndexing")
                state.quitting = true
                supervisor.reevaluate()
            },
            shutdownHelpers: { timeout, completion in helpers.shutdown(timeout: timeout, completion: completion) },
            terminate: { log.noteTermination(at: helpers.now) })
    }

    // A launch with indexing running.
    func launch() { supervisor.reevaluate() }
}

// MARK: fakes for the load monitor (the t30 seams, copied as this file's own)

@MainActor private final class ALPower: PowerSource {
    var onBattery: Bool
    var onChange: (() -> Void)?
    init(onBattery: Bool = false) { self.onBattery = onBattery }
    func change(to value: Bool) {
        onBattery = value
        onChange?()
    }
}

@MainActor private final class ALLowPower: LowPowerSource {
    var isOn = false
    var onChange: (() -> Void)?
    func change(to value: Bool) {
        isOn = value
        onChange?()
    }
}

@MainActor private final class ALCPU: CPUSource {
    func sample() -> Double { 0 }
}

@MainActor private final class ALScheduler: SampleScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var active = false
    func every(_ interval: TimeInterval, _ tick: @escaping (Date) -> Void) {
        intervals.append(interval)
        active = true
    }
    func cancel() { active = false }
}

// The whole menu side: a load monitor over fakes, a real supervisor over a fake host that reads the monitor's pause set,
// recorded closures, and `MenuActions.live` over them. `launch()` is what the app does at launch.
@MainActor private struct ALMenuWorld {
    let state = ALState()
    let host = ALHost()
    let log = ALLog()
    let power: ALPower
    let lowPower = ALLowPower()
    let scheduler = ALScheduler()
    let monitor: LoadMonitor
    let supervisor: HelperSupervisor
    let helpers: ALHelpers
    let quitPlan: QuitPlan
    let actions: MenuActions

    init(onBattery: Bool = false, startPressed: Bool = true, modelWhole: Bool = true) {
        let state = state
        state.startPressed = startPressed
        state.modelWhole = modelWhole
        let host = host
        let log = log
        let power = ALPower(onBattery: onBattery)
        self.power = power
        let monitor = LoadMonitor(power: power, lowPower: lowPower, cpu: ALCPU(), scheduler: scheduler)
        self.monitor = monitor
        let supervisor = HelperSupervisor(host: host, inputs: {
            HelperSupervisor.Inputs(startPressed: state.startPressed, indexDeleted: state.indexDeleted,
                                    modelWhole: state.modelWhole, pauseReasons: monitor.pauseSet.reasons,
                                    quitting: state.quitting)
        })
        self.supervisor = supervisor
        let helpers = ALHelpers(log: log)
        self.helpers = helpers
        let quitPlan = QuitPlan(
            stopIndexing: {
                log.note("stopIndexing")
                state.quitting = true
                supervisor.reevaluate()
            },
            shutdownHelpers: { timeout, completion in helpers.shutdown(timeout: timeout, completion: completion) },
            terminate: { log.noteTermination(at: helpers.now) })
        self.quitPlan = quitPlan
        actions = MenuActions.live(
            monitor: monitor,
            settingsChanged: { log.note("settingsChanged", reasons: monitor.pauseSet.reasons) },
            reevaluate: {
                log.note("reevaluate", reasons: monitor.pauseSet.reasons)
                supervisor.reevaluate()
            },
            retryDownload: { log.note("retryDownload") },
            openPanel: { log.note("openPanel") },
            openSettings: { log.note("openSettings") },
            quit: quitPlan)
    }

    func launch() {
        let log = log
        let monitor = monitor
        let supervisor = supervisor
        AppLifecycle.launch(
            monitor: monitor,
            settingsChanged: { log.note("settingsChanged", reasons: monitor.pauseSet.reasons) },
            reevaluate: {
                log.note("reevaluate", reasons: monitor.pauseSet.reasons)
                supervisor.reevaluate()
            })
    }

    var reasons: Set<PauseReason> { monitor.pauseSet.reasons }
}

// One line per entry under `root`, recursively: relative path, kind, size, modification time (ns) and, for a file, its
// bytes as base64. Sorted, so two listings of an untouched tree are equal.
private func alListing(_ root: URL) throws -> [String] {
    let fm = FileManager.default
    var lines: [String] = []
    guard let walker = fm.enumerator(atPath: root.path) else { return lines }
    for case let relative as String in walker {
        let path = root.appendingPathComponent(relative).path
        let attributes = try fm.attributesOfItem(atPath: path)
        let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let modified = ((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000_000_000
        var content = ""
        if !isDirectory, let data = fm.contents(atPath: path) { content = data.base64EncodedString() }
        lines.append("\(relative)|\(isDirectory ? "dir" : "file")|\(size)|\(Int64(modified))|\(content)")
    }
    return lines.sorted()
}

// MARK: the suite

extension ModelDownloadTests {
    @Suite("AppLifecycleTests", .serialized)
    @MainActor
    struct AppLifecycleTests {

        // MARK: LaunchPlan (S7.10, D11, t22's recovery)

        @Test func theLaunchTableHoldsForEveryRow() {
            for row in alLaunchTable {
                let plan = LaunchPlan.decide(settings: row.settings, modelWhole: row.modelWhole,
                                             indexFileExists: row.indexFileExists)
                if let showsSetup = row.showsSetup {
                    #expect(plan.showsSetup == showsSetup, "\(row.name): showsSetup \(plan.showsSetup), wanted \(showsSetup)")
                }
                #expect(plan.startsIndexing == row.startsIndexing,
                        "\(row.name): startsIndexing \(plan.startsIndexing), wanted \(row.startsIndexing)")
                if let defers = row.defers {
                    #expect(plan.defersIndexingUntilModelWhole == defers,
                            "\(row.name): defers \(plan.defersIndexingUntilModelWhole), wanted \(defers)")
                }
                #expect(plan.requestsReset == row.requestsReset,
                        "\(row.name): requestsReset \(plan.requestsReset), wanted \(row.requestsReset)")
            }
        }

        @Test func aFirstRunStartsNothingWhateverTheModelAndTheFilesSay() {
            for modelWhole in [true, false] {
                for indexFileExists in [true, false] {
                    let plan = LaunchPlan.decide(settings: Settings(), modelWhole: modelWhole, indexFileExists: indexFileExists)
                    #expect(plan.showsSetup, "model whole \(modelWhole), index file \(indexFileExists)")
                    #expect(plan.startsIndexing == false, "model whole \(modelWhole), index file \(indexFileExists)")
                    #expect(plan.requestsReset == false, "model whole \(modelWhole), index file \(indexFileExists)")
                }
            }
        }

        @Test func aResumeAtLaunchOpensNoWindowAndAsksForNoReset() {
            let plan = LaunchPlan.decide(settings: alSettings(startPressed: true, folders: alTicked),
                                         modelWhole: true, indexFileExists: true)
            #expect(plan.startsIndexing, "S7.10: relaunch resumes with no click")
            #expect(plan.showsSetup == false, "S7.10: no window at a resume")
            #expect(plan.requestsReset == false)
            #expect(plan.defersIndexingUntilModelWhole == false)
        }

        @Test func deletedIndexNeverStartsIndexingAndAsksForResetOnlyWhileTheFileIsThere() {
            for modelWhole in [true, false] {
                let present = LaunchPlan.decide(settings: alSettings(indexDeleted: true), modelWhole: modelWhole, indexFileExists: true)
                let gone = LaunchPlan.decide(settings: alSettings(indexDeleted: true), modelWhole: modelWhole, indexFileExists: false)
                #expect(present.startsIndexing == false, "model whole \(modelWhole)")
                #expect(gone.startsIndexing == false, "model whole \(modelWhole)")
                #expect(present.requestsReset, "model whole \(modelWhole): a crash between the write and the reset")
                #expect(gone.requestsReset == false, "model whole \(modelWhole): the reset had gone through")
            }
        }

        // MARK: QuitPlan over a real supervisor, a fake host and fake helpers with a manual clock (S7.2, S7.11)

        @Test func quitStopsIndexingOnceAndAsksBothHelpersToEndWithAFourSecondTimeout() {
            let world = ALQuitWorld()
            world.launch()
            #expect(world.host.log == ["start"])
            world.plan.begin()
            #expect(world.host.log == ["start", "stop"], "Quit stops indexing with one clean stop; log \(world.host.log)")
            #expect(world.helpers.asked == [4], "both helpers are asked to end once, with a 4 s timeout: \(world.helpers.asked)")
            #expect(world.log.events == ["stopIndexing", "shutdown"], "stop indexing first, then end both helpers; \(world.log.events)")
            #expect(world.log.terminations.isEmpty, "the helpers are still alive, so the app has not ended")
            #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        }

        @Test func quitCompletesAsSoonAsBothHelpersHaveExitedAndKillsNothing() {
            let world = ALQuitWorld()
            world.launch()
            world.plan.begin()
            world.helpers.advance(by: 1)
            world.host.finishExit()
            world.helpers.exit("index")
            #expect(world.log.terminations.isEmpty, "encode is still alive; the app must wait for it")
            world.helpers.advance(by: 1.5)
            #expect(world.log.terminations.isEmpty)
            world.helpers.exit("encode")
            #expect(world.log.terminations.count == 1, "both gone: the app ends now, not at the timeout; \(world.log.events)")
            #expect(world.log.terminations.first?.at == 2.5, "ended at \(String(describing: world.log.terminations.first?.at)) s on the manual clock")
            #expect(world.helpers.killed.isEmpty, "nobody needed killing: \(world.helpers.killed)")
            #expect(world.log.events == ["stopIndexing", "shutdown", "terminate"], "\(world.log.events)")
            #expect(world.host.log == ["start", "stop"], "nothing restarted the helper; \(world.host.log)")
            #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        }

        @Test func aHelperThatIgnoresTheEndIsTerminatedAfterFourSecondsAndTheAppEndsWithinFive() {
            let world = ALQuitWorld()
            world.launch()
            world.plan.begin()
            world.host.finishExit()
            world.helpers.exit("index")
            // encode never finishes by itself
            world.helpers.advance(by: 3.75)
            #expect(world.helpers.killed.isEmpty, "killed before 4 s: \(world.helpers.killed)")
            #expect(world.log.terminations.isEmpty, "the app ended at 3.75 s with encode alive")
            world.helpers.advance(by: 0.25)
            #expect(world.helpers.killed == ["encode"], "at 4 s the helper that was still alive is killed: \(world.helpers.killed)")
            #expect(world.log.terminations.count == 1, "\(world.log.events)")
            if let at = world.log.terminations.first?.at {
                #expect(at >= 4 && at <= 5, "ended at \(at) s; no Sesame process may remain after 5 s")
            }
        }

        @Test func bothHelpersIgnoringTheEndAreBothKilledAtFourSeconds() {
            let world = ALQuitWorld()
            world.launch()
            world.plan.begin()
            world.helpers.advance(by: 4)
            #expect(world.helpers.killed.sorted() == ["encode", "index"], "\(world.helpers.killed)")
            #expect(world.log.terminations.count == 1)
            #expect(world.log.events.last == "terminate", "\(world.log.events)")
        }

        @Test func theAppNeverEndsBeforeTheCompletionHasBeenCalled() {
            let world = ALQuitWorld()
            world.plan.begin()
            for step in 1...3 {
                world.helpers.advance(by: 1)
                #expect(world.log.terminations.isEmpty, "ended after \(step) s with both helpers alive")
            }
            world.helpers.exit("index")
            #expect(world.log.terminations.isEmpty, "one helper is still alive")
            world.helpers.exit("encode")
            #expect(world.log.terminations.count == 1)
        }

        @Test func aSecondQuitWhileShuttingDownAsksForNothingMore() {
            let world = ALQuitWorld()
            world.launch()
            world.plan.begin()
            world.plan.begin()
            world.plan.begin()
            #expect(world.log.count("stopIndexing") == 1, "\(world.log.events)")
            #expect(world.helpers.asked == [4], "\(world.helpers.asked)")
            #expect(world.host.stops == 1, "\(world.host.log)")
            world.host.finishExit()
            world.helpers.exit("index")
            world.helpers.exit("encode")
            world.plan.begin()
            #expect(world.log.count("terminate") == 1, "\(world.log.events)")
            #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        }

        @Test func quitWithNothingRunningStillEndsTheAppOnceTheHelpersAreGone() {
            let world = ALQuitWorld()
            world.state.startPressed = false
            world.launch()
            #expect(world.host.log.isEmpty)
            world.helpers.exit("index")
            world.helpers.exit("encode")
            world.plan.begin()
            #expect(world.host.log.isEmpty, "no helper was running, so no stop is sent; \(world.host.log)")
            #expect(world.log.terminations.count == 1, "both helpers were already gone: the app ends at once; \(world.log.events)")
            #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        }

        @Test func theCompletionMayArriveOnAnotherThreadAndTheAppStillEndsOnceOnTheMainThread() async {
            let world = ALQuitWorld()
            world.helpers.completeFromBackground = true
            world.launch()
            world.plan.begin()
            world.host.finishExit()
            world.helpers.exit("index")
            world.helpers.exit("encode")
            let ended = await spEventually { world.log.terminations.count >= 1 }
            #expect(ended, "the app never ended after a completion from a background queue; \(world.log.events)")
            await spWait(0.2)
            #expect(world.log.terminations.count == 1, "\(world.log.events)")
            #expect(world.log.terminations.first?.onMainThread == true, "the app must end on the main thread")
        }

        @Test func quitDeletesNothingAndKeepsTheIndexAndTheSettings() async throws {
            try await spWithHome { home in
                var settings = Settings()
                settings.startPressed = true
                settings.folders = [Settings.Folder(path: home.appendingPathComponent("Pictures").path, code: false, reading: true)]
                try SettingsFile().write(settings)
                let folder = home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
                let models = folder.appendingPathComponent("models", isDirectory: true)
                let logs = folder.appendingPathComponent("logs", isDirectory: true)
                try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                try Data("the index".utf8).write(to: folder.appendingPathComponent("index.sqlite"))
                try Data("wal bytes".utf8).write(to: folder.appendingPathComponent("index.sqlite-wal"))
                try Data("model bytes".utf8).write(to: models.appendingPathComponent("model.gguf"))
                try Data("a log line\n".utf8).write(to: logs.appendingPathComponent("app.log"))
                let caches = home.appendingPathComponent("Library/Caches/app.sesame.Sesame", isDirectory: true)
                try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
                try Data("cache".utf8).write(to: caches.appendingPathComponent("scratch.png"))

                let before = try alListing(home)
                #expect(!before.isEmpty)

                let world = ALQuitWorld()
                world.launch()
                world.plan.begin()
                world.host.finishExit()
                world.helpers.exit("index")
                world.helpers.exit("encode")
                #expect(world.log.terminations.count == 1, "\(world.log.events)")

                let after = try alListing(home)
                #expect(after == before, "Quit changed the Sesame folder or the Caches: \(Set(after).symmetricDifference(Set(before)).sorted())")
                let read = try SettingsFile().read()
                #expect(read.startPressed, "Quit cleared startPressed, so the next launch would not resume")
                #expect(read.indexDeleted == false)
                #expect(read.folders.count == 1, "Quit changed the folder list")
            }
        }

        // MARK: AppLifecycle.launch: the load monitor starts, the supervisor resumes (S7.10, S7.4)

        @Test func launchStartsTheLoadMonitorWithAOneSecondTick() {
            let world = ALMenuWorld()
            world.launch()
            #expect(world.scheduler.intervals == [1], "the monitor asks for a 1 s tick at launch; \(world.scheduler.intervals)")
            #expect(world.scheduler.active)
        }

        @Test func aLaunchWithStartPressedResumesIndexingByItselfAndOtherLaunchesDoNot() {
            let resumed = ALMenuWorld(startPressed: true, modelWhole: true)
            resumed.launch()
            #expect(resumed.host.log == ["start"], "S7.10: relaunch resumes with no press; \(resumed.host.log)")

            let fresh = ALMenuWorld(startPressed: false, modelWhole: true)
            fresh.launch()
            #expect(fresh.host.log.isEmpty, "a first run starts nothing; \(fresh.host.log)")

            let downloading = ALMenuWorld(startPressed: true, modelWhole: false)
            downloading.launch()
            #expect(downloading.host.log.isEmpty, "the model is not whole, so indexing waits; \(downloading.host.log)")
            downloading.state.modelWhole = true
            downloading.supervisor.reevaluate()
            #expect(downloading.host.log == ["start"], "the model became whole; \(downloading.host.log)")
        }

        @Test func aMacThatWakesUpOnBatteryIsPausedBeforeTheHelperEverStarts() {
            let world = ALMenuWorld(onBattery: true)
            world.launch()
            #expect(world.reasons == [.battery])
            #expect(world.host.log.isEmpty, "the helper was started and then stopped; \(world.host.log)")
            world.log.clear()
            world.power.change(to: false)
            #expect(world.reasons.isEmpty)
            #expect(world.host.log == ["start"], "plugged in: indexing resumes; \(world.host.log)")
            #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
            #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
        }

        @Test func eachChangeTheMonitorMakesCallsSettingsChangedAndReevaluateOnceAfterTheSetHoldsIt() {
            let world = ALMenuWorld()
            world.launch()
            world.log.clear()
            world.power.change(to: true)
            #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
            #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
            #expect(world.log.reasons("settingsChanged") == [[.battery]], "the set did not hold the change yet: \(world.log.reasons("settingsChanged"))")
            #expect(world.log.reasons("reevaluate") == [[.battery]])
            world.log.clear()
            world.lowPower.change(to: true)
            #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
            #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
            #expect(world.log.reasons("reevaluate") == [[.battery, .lowPower]])
            world.log.clear()
            world.lowPower.change(to: true)
            #expect(world.log.events.isEmpty, "a change that changes nothing calls nothing; \(world.log.events)")
        }

        // MARK: MenuActions over fakes (S7.1, S1.29 the menu)

        @Test func pauseInsertsYouAndResumeRemovesItEachCallingSettingsChangedAndReevaluateOnce() {
            let world = ALMenuWorld()
            world.launch()
            world.log.clear()

            world.actions.pause()
            #expect(world.reasons == [.you])
            #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
            #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
            #expect(world.log.reasons("settingsChanged") == [[.you]], "settingsChanged ran before the set held the change")
            #expect(world.log.reasons("reevaluate") == [[.you]], "reevaluate ran before the set held the change")

            world.log.clear()
            world.actions.resume()
            #expect(world.reasons.isEmpty)
            #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
            #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
            #expect(world.log.reasons("settingsChanged") == [[]])
            #expect(world.log.reasons("reevaluate") == [[]])
        }

        @Test func pauseAndResumeTouchOnlyTheYouReason() {
            let world = ALMenuWorld()
            world.launch()
            world.power.change(to: true)
            world.lowPower.change(to: true)
            world.log.clear()
            world.actions.pause()
            #expect(world.reasons == [.battery, .lowPower, .you])
            world.actions.resume()
            #expect(world.reasons == [.battery, .lowPower], "Resume removed more than \"you\": \(world.reasons)")
        }

        @Test func resumeAnywayRemovesOnlyBatteryAndIgnoresTheNextBatteryEventThisSession() {
            let world = ALMenuWorld()
            world.launch()
            world.power.change(to: true)
            world.lowPower.change(to: true)
            world.actions.pause()
            #expect(world.reasons == [.battery, .lowPower, .you])
            world.log.clear()

            world.actions.resumeAnyway()
            #expect(world.reasons == [.lowPower, .you], "only battery goes: \(world.reasons)")
            #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
            #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
            #expect(world.log.reasons("reevaluate") == [[.lowPower, .you]], "reevaluate ran before the set held the change")

            world.power.change(to: false)
            world.power.change(to: true)
            #expect(world.reasons == [.lowPower, .you], "a later battery event in the same session must be ignored: \(world.reasons)")
        }

        @Test func openSesameAndSettingsRunTheirOwnClosureOnceAndChangeNothingElse() {
            let world = ALMenuWorld()
            world.launch()
            world.actions.pause()
            world.log.clear()

            world.actions.open()
            #expect(world.log.events == ["openPanel"], "Open Sesame called \(world.log.events)")
            world.log.clear()
            world.actions.settings()
            #expect(world.log.events == ["openSettings"], "Settings called \(world.log.events)")
            #expect(world.reasons == [.you], "opening a window changed the pause set")
        }

        @Test func quitRunsTheQuitPlanOnceAndNothingElse() {
            let world = ALMenuWorld()
            world.launch()
            world.log.clear()
            world.actions.quit()
            #expect(world.log.events == ["stopIndexing", "shutdown"], "Quit called \(world.log.events)")
            #expect(world.helpers.asked == [4], "\(world.helpers.asked)")
            #expect(world.host.log == ["start", "stop"], "Quit stops indexing once; \(world.host.log)")
            #expect(world.reasons.isEmpty, "Quit changed the pause set")
            world.helpers.exit("index")
            world.helpers.exit("encode")
            #expect(world.log.count("terminate") == 1, "\(world.log.events)")
        }

        // MARK: the actions and the monitor share one pause set, and the supervisor follows it (S7.2, S7.4)

        @Test func menuAndMonitorFeedOnePauseSetAndTheHelperFollowsIt() {
            let world = ALMenuWorld()
            world.launch()
            #expect(world.host.log == ["start"], "S7.10; \(world.host.log)")

            // the Mac goes onto battery: the monitor pauses, the helper stops cleanly
            world.power.change(to: true)
            #expect(world.reasons == [.battery])
            #expect(world.host.log == ["start", "stop"], "\(world.host.log)")
            world.host.finishExit()

            // the person also pauses: still one stop, no new one
            world.actions.pause()
            #expect(world.reasons == [.battery, .you])
            #expect(world.host.log == ["start", "stop"], "\(world.host.log)")

            // Resume removes "you" only: the battery still pauses, so nothing starts
            world.actions.resume()
            #expect(world.reasons == [.battery])
            #expect(world.host.log == ["start", "stop"], "Resume started the helper while on battery; \(world.host.log)")

            // Resume anyway removes battery: indexing starts again, once
            world.actions.resumeAnyway()
            #expect(world.reasons.isEmpty)
            #expect(world.host.log == ["start", "stop", "start"], "\(world.host.log)")

            // and the battery event of this session is ignored
            world.power.change(to: false)
            world.power.change(to: true)
            #expect(world.reasons.isEmpty)
            #expect(world.host.log == ["start", "stop", "start"], "a battery event after Resume anyway stopped the helper; \(world.host.log)")
            #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        }

        @Test func pauseFromTheMenuStopsTheHelperAndResumeStartsItAgain() {
            let world = ALMenuWorld()
            world.launch()
            world.actions.pause()
            #expect(world.host.log == ["start", "stop"], "\(world.host.log)")
            world.host.finishExit()
            world.actions.resume()
            #expect(world.host.log == ["start", "stop", "start"], "\(world.host.log)")
            #expect(world.host.violations.isEmpty, "\(world.host.violations)")
        }
    }
}

// =================================================================================================================
// plan-3-t21, tester step: `MenuActions.live` Resume clears a stall (S7.2, S7.12). Written from the t21 entry of
// plan-3-tasks.md (its Tests paragraph): "`MenuActions.live` Resume removes `.you` and `.stalled`, calls `resetStall` once,
// then the status cache and the supervisor once each; a Resume with only automatic reasons does not call `resetStall`; the
// new parameter has a default of `{}` so the plan 2 tests compile unchanged". No product source was read.
//
// SHAPE t21 pins here (new): `PauseReason.stalled`; `MenuActions.live(...)` gains `resetStall: @escaping () -> Void = {}`.
// Its place among the labelled arguments is this file's pick (a call must list them in declaration order): right after
// `reevaluate:` and before `retryDownload:`. The world below calls it so; the sealed `ALMenuWorld` above does not pass
// it and so shows the default. `resetStall` is `HelperSupervisor.resetStall()` in the app. `settingsChanged` is the status
// cache and `reevaluate` the supervisor, as above. The load monitor is never started and no helper exists: the pause set is
// seeded directly, and only the closures are recorded.
//
// Pinned: after Resume the set holds the reasons it held minus `.you` and `.stalled`; `resetStall` ran exactly once, before
// `settingsChanged` and `reevaluate`, which each ran once and saw the new set (a re-evaluation must not see the old stall).
// Resume with `.you` alone calls `resetStall` once too (inferred from the entry: only a Resume that holds no `.you` and no
// `.stalled` is exempt). Not pinned: the order of `settingsChanged` and `reevaluate`, and what the pause and resumeAnyway
// actions do with `resetStall` (they are not in the entry; they are checked below only to leave the stall alone).
// =================================================================================================================

@MainActor private struct ALStallWorld {
    let log = ALLog()
    let monitor: LoadMonitor
    let actions: MenuActions

    init(reasons: Set<PauseReason>) {
        let log = log
        let monitor = LoadMonitor(power: ALPower(), lowPower: ALLowPower(), cpu: ALCPU(), scheduler: ALScheduler())
        self.monitor = monitor
        for reason in reasons { monitor.pauseSet.add(reason) }
        let quit = QuitPlan(stopIndexing: {}, shutdownHelpers: { _, completion in completion() }, terminate: {})
        actions = MenuActions.live(
            monitor: monitor,
            settingsChanged: { log.note("settingsChanged", reasons: monitor.pauseSet.reasons) },
            reevaluate: { log.note("reevaluate", reasons: monitor.pauseSet.reasons) },
            resetStall: { log.note("resetStall", reasons: monitor.pauseSet.reasons) },
            retryDownload: { log.note("retryDownload") },
            openPanel: { log.note("openPanel") },
            openSettings: { log.note("openSettings") },
            quit: quit)
    }

    var reasons: Set<PauseReason> { monitor.pauseSet.reasons }
}

extension ModelDownloadTests.AppLifecycleTests {

    @Test func resumeClearsAStallCallsResetStallOnceAndThenTheStatusCacheAndTheSupervisorOnceEach() {
        let world = ALStallWorld(reasons: [.stalled])
        #expect(world.reasons == [.stalled])
        world.actions.resume()
        #expect(world.reasons.isEmpty, "Resume left \(world.reasons)")
        #expect(world.log.count("resetStall") == 1, "\(world.log.events)")
        #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
        #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
        #expect(world.log.events.first == "resetStall", "resetStall must run before the others: \(world.log.events)")
        #expect(world.log.reasons("settingsChanged") == [[]], "settingsChanged saw the old set: \(world.log.reasons("settingsChanged"))")
        #expect(world.log.reasons("reevaluate") == [[]], "reevaluate saw the old set: \(world.log.reasons("reevaluate"))")
    }

    @Test func resumeRemovesYouAndStalledTogetherAndLeavesTheAutomaticReasons() {
        let world = ALStallWorld(reasons: [.you, .stalled, .battery, .lowPower])
        world.actions.resume()
        #expect(world.reasons == [.battery, .lowPower], "Resume removed more or less than you and stalled: \(world.reasons)")
        #expect(world.log.count("resetStall") == 1, "\(world.log.events)")
        #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
        #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
        #expect(world.log.events.first == "resetStall", "resetStall must run before the others: \(world.log.events)")
        #expect(world.log.reasons("reevaluate") == [[.battery, .lowPower]], "reevaluate saw \(world.log.reasons("reevaluate"))")
    }

    @Test func resumeOfAStallWithAnAutomaticReasonStillResetsTheStallOnceAndKeepsTheAutomaticReason() {
        for automatic in [PauseReason.cpu, .lowPower, .battery] {
            let world = ALStallWorld(reasons: [.stalled, automatic])
            world.actions.resume()
            #expect(world.reasons == [automatic], "\(automatic): Resume left \(world.reasons)")
            #expect(world.log.count("resetStall") == 1, "\(automatic): \(world.log.events)")
            #expect(world.log.events.first == "resetStall", "\(automatic): \(world.log.events)")
        }
    }

    @Test func resumeOfYouAloneCallsResetStallOnce() {
        let world = ALStallWorld(reasons: [.you])
        world.actions.resume()
        #expect(world.reasons.isEmpty, "Resume left \(world.reasons)")
        #expect(world.log.count("resetStall") == 1, "\(world.log.events)")
        #expect(world.log.count("settingsChanged") == 1, "\(world.log.events)")
        #expect(world.log.count("reevaluate") == 1, "\(world.log.events)")
    }

    @Test func aResumeWithOnlyAutomaticReasonsDoesNotCallResetStall() {
        for reasons in [Set<PauseReason>([.cpu]), [.lowPower], [.battery], [.cpu, .lowPower, .battery]] {
            let world = ALStallWorld(reasons: reasons)
            world.actions.resume()
            #expect(world.reasons == reasons, "Resume changed the automatic reasons \(reasons) to \(world.reasons)")
            #expect(world.log.count("resetStall") == 0, "\(reasons): resetStall ran: \(world.log.events)")
        }
    }

    @Test func aResumeWithNoReasonAtAllDoesNotCallResetStall() {
        let world = ALStallWorld(reasons: [])
        world.actions.resume()
        #expect(world.reasons.isEmpty)
        #expect(world.log.count("resetStall") == 0, "\(world.log.events)")
    }

    @Test func pauseOpenSettingsAndRetryDoNotResetTheStallOrTouchIt() {
        let world = ALStallWorld(reasons: [.stalled])
        world.actions.pause()
        #expect(world.reasons == [.stalled, .you], "Pause changed more than you: \(world.reasons)")
        world.actions.open()
        world.actions.settings()
        world.actions.retryDownload()
        #expect(world.reasons == [.stalled, .you], "a window or a retry changed the set: \(world.reasons)")
        #expect(world.log.count("resetStall") == 0, "only Resume resets the stall: \(world.log.events)")
    }

    @Test func resumeAnywayOnBatteryLeavesAStallAndDoesNotResetIt() {
        let world = ALStallWorld(reasons: [.stalled, .battery])
        world.actions.resumeAnyway()
        #expect(world.reasons == [.stalled], "Resume anyway removed more than battery: \(world.reasons)")
        #expect(world.log.count("resetStall") == 0, "Resume anyway must not reset the stall: \(world.log.events)")
    }

    @Test func resumeCanBeUsedAgainAfterAStallIsRaisedAgain() {
        // the stall is raised again (the supervisor's onStalled adds the reason): the next Resume resets once more
        let world = ALStallWorld(reasons: [.stalled])
        world.actions.resume()
        world.monitor.pauseSet.add(.stalled)
        world.actions.resume()
        #expect(world.reasons.isEmpty, "Resume left \(world.reasons)")
        #expect(world.log.count("resetStall") == 2, "\(world.log.events)")
    }
}

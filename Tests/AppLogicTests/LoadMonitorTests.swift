import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t30, tester step: `LoadMonitor`, the app's watcher of power source, Low Power Mode and "CPU apart from Sesame"
// (S7.3, S7.4, S7.17). Written from the t30 entry (its Tests paragraph), design section 6 ("Pause reasons are a set (you,
// CPU, Low Power, battery)"), design section 8 ("monitor samples every 1 s: system CPU minus Sesame's own processes"),
// spec S7 (pause above 70 percent for 10 s, resume below 50 percent for 30 s, Low Power Mode, battery) and the sealed
// t29 tests `PauseSetTests` and `CPURuleTests` (the only places `PauseSet`, `PauseReason` and `CPURule` are read). No
// product source was read. Every expected value below is written by hand from those texts; none is computed by the code
// under test, and no test reads the real battery, the real Low Power Mode or the real CPU load except the two headless
// "returns a value" tests the entry asks for, which assert no value.
//
// API SHAPES these tests pin. The entry names `LoadMonitor`, `PowerSource`, "a Low Power Mode source", "a CPU sampler",
// "a manual scheduler", `CPUSampler.apart(system:own:)`, `HostCPUSampler`, `PowerSourceReader.onBattery()`, `PauseSet`
// and `onChange`, and fixes no signature; the rest are this file's picks. If a shape is wrong, ask for a test change
// rather than guessing.
//   1. Isolation. The monitor, the four seam protocols below and `HostCPUSampler` are `@MainActor` (the notifications and
//      the 1 s timer run on the main run loop); every closure is a plain `() -> Void` or `(Date) -> Void`, not
//      `@Sendable`. The fakes below are `@MainActor` classes. Swift 6 mode is on in this package.
//   2. `@MainActor protocol PowerSource: AnyObject { var onBattery: Bool { get }; var onChange: (() -> Void)? { get set } }`
//      `onChange` is called with no payload when the source may have changed; the monitor re-reads `onBattery`.
//   3. `@MainActor protocol LowPowerSource: AnyObject { var isOn: Bool { get }; var onChange: (() -> Void)? { get set } }`
//      same contract for Low Power Mode.
//   4. `@MainActor protocol CPUSource: AnyObject { func sample() -> Double }` returns the percent (0...100) of CPU used
//      apart from Sesame's own processes since the previous call; the monitor calls it once per scheduler tick and
//      feeds the value to a `CPURule` (sealed, t29) with the tick's time. The entry's "CPU sampler" fake is a
//      `CPUSource`; the name `CPUSampler` is kept for the namespace of the two pure functions in 7 and 8 (a Swift
//      protocol extension cannot offer `CPUSampler.apart(...)` on the protocol itself, which a typecheck showed).
//   5. `@MainActor protocol SampleScheduler: AnyObject { func every(_ interval: TimeInterval, _ tick: @escaping (Date) -> Void);
//      func cancel() }` repeats `tick` every `interval` seconds, passing the time of the tick, until `cancel()`.
//      The monitor asks for an interval of exactly 1.
//   6. `@MainActor final class LoadMonitor` (a class: the callbacks and the shared state need identity):
//      `init(power: any PowerSource, lowPower: any LowPowerSource, cpu: any CPUSource, scheduler: any SampleScheduler)`,
//      `var pauseSet: PauseSet { get set }` (a new `PauseSet()` at init; the monitor's changes go into it and the owner
//      may read and mutate it through the monitor, as t32's menu actions do), `var onChange: (() -> Void)?` (called once
//      for each reason the monitor adds or removes, after `pauseSet` holds the new state, and never for a call that
//      changes nothing, such as an ignored battery event after `resumeAnyway()`), `start()` and `stop()`.
//      `start()` reads the two sources once (a Mac that wakes up on battery is paused at once), sets their `onChange`,
//      and asks the scheduler for the 1 s tick; it takes no CPU sample of its own (the first sample is the first tick,
//      so the tenth tick at full load is the pause). `stop()` cancels the tick and stops reacting to the sources.
//      Before `start()` the monitor reacts to nothing and holds no reason.
//   7. `CPUSampler.apart(system: (busy: ..., total: ...), own: ...) -> Double`: a static function of the namespace
//      `CPUSampler` (an enum or a struct, no instance is made), pure. The system
//      snapshot is the busy ticks and all ticks of one sampling interval, `own` the ticks Sesame's processes used in that
//      interval (same unit): (system busy minus own) over total, as percent, clamped to 0...100. Numbers are passed as
//      literals, so any numeric parameter type fits.
//   8. `CPUSampler.ownPIDs(appPID: Int32, parentOf: [Int32: Int32]) -> Set<Int32>`: static on the same namespace, pure. The
//      own set is the app's pid and the pids whose parent is the app's pid (the helper processes). `parentOf` maps a pid
//      to its parent pid, as `proc_listpids` and `proc_pidinfo` would give it. Whether deeper descendants join is not
//      pinned.
//   9. `HostCPUSampler: CPUSource` with `init()`; `PowerSourceReader.onBattery() -> Bool` static, headless.
// Not pinned, on purpose: the number of `onChange` calls while `start()` reads two reasons at once, whether `stop()`
// clears the reasons, whether `start()` twice is safe, what `apart` returns for a total of 0 (only that it is in range),
// what `HostCPUSampler.sample()` returns on its first call, whether the monitor is restartable, threading outside the
// main actor, and anything about the real IOKit or Low Power Mode notifications.

// MARK: fakes

@MainActor private final class LMPower: PowerSource {
    var onBattery: Bool
    var onChange: (() -> Void)?
    init(onBattery: Bool = false) { self.onBattery = onBattery }
    // The person plugs in or unplugs: the source changes, then calls back.
    func change(to value: Bool) {
        onBattery = value
        onChange?()
    }
    // A callback with the same state (the OS notifies for any power source detail).
    func ping() { onChange?() }
}

@MainActor private final class LMLowPower: LowPowerSource {
    var isOn: Bool
    var onChange: (() -> Void)?
    init(isOn: Bool = false) { self.isOn = isOn }
    func change(to value: Bool) {
        isOn = value
        onChange?()
    }
    func ping() { onChange?() }
}

@MainActor private final class LMCPU: CPUSource {
    var value: Double = 0
    private(set) var calls = 0
    func sample() -> Double {
        calls += 1
        return value
    }
}

// A scheduler a test steps by hand: `fire()` is one second.
@MainActor private final class LMScheduler: SampleScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var active = false
    private(set) var cancels = 0
    private var tick: ((Date) -> Void)?
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    func every(_ interval: TimeInterval, _ tick: @escaping (Date) -> Void) {
        intervals.append(interval)
        self.tick = tick
        active = true
    }

    func cancel() {
        cancels += 1
        tick = nil
        active = false
    }

    // One tick of the schedule, if it is running; a cancelled schedule does nothing.
    func fire() {
        guard active, let tick, let interval = intervals.last else { return }
        now = now.addingTimeInterval(interval)
        tick(now)
    }
}

// The reasons the monitor's `pauseSet` held at each `onChange` call, in order.
@MainActor private final class LMChanges {
    private(set) var seen: [Set<PauseReason>] = []
    func record(_ reasons: Set<PauseReason>) { seen.append(reasons) }
    func clear() { seen.removeAll() }
}

@MainActor private struct LMRig {
    let power: LMPower
    let lowPower: LMLowPower
    let cpu = LMCPU()
    let scheduler = LMScheduler()
    let monitor: LoadMonitor
    let changes = LMChanges()

    init(onBattery: Bool = false, lowPowerOn: Bool = false, start: Bool = true) {
        power = LMPower(onBattery: onBattery)
        lowPower = LMLowPower(isOn: lowPowerOn)
        monitor = LoadMonitor(power: power, lowPower: lowPower, cpu: cpu, scheduler: scheduler)
        let changes = changes
        monitor.onChange = { [weak monitor] in
            if let monitor { changes.record(monitor.pauseSet.reasons) }
        }
        if start { monitor.start() }
    }

    var reasons: Set<PauseReason> { monitor.pauseSet.reasons }

    // `count` seconds at one CPU percent.
    func seconds(_ count: Int, at percent: Double) {
        cpu.value = percent
        for _ in 0..<count { scheduler.fire() }
    }
}

private func lmClose(_ got: Double, _ want: Double) -> Bool { abs(got - want) < 1e-6 }

@Suite("LoadMonitorTests")
@MainActor
struct LoadMonitorTests {

    // MARK: start and stop

    @Test func startAsksForAOneSecondTickAndHoldsNothingOnPowerWithNormalMode() {
        let rig = LMRig(start: false)
        #expect(rig.scheduler.active == false, "before start() nothing is scheduled")
        #expect(rig.scheduler.intervals.isEmpty)
        rig.monitor.start()
        #expect(rig.scheduler.active == true)
        #expect(rig.scheduler.intervals == [1], "the sample is every 1 second (design section 8)")
        #expect(rig.reasons.isEmpty)
        #expect(rig.monitor.pauseSet.isPaused == false)
        #expect(rig.changes.seen.isEmpty, "no change, no onChange")
    }

    @Test func startOnBatteryPausesAtOnceWithOneOnChange() {
        let rig = LMRig(onBattery: true)
        #expect(rig.reasons == [.battery])
        #expect(rig.monitor.pauseSet.isPaused == true)
        #expect(rig.changes.seen == [[.battery]])
    }

    @Test func startInLowPowerModePausesAtOnceWithOneOnChange() {
        let rig = LMRig(lowPowerOn: true)
        #expect(rig.reasons == [.lowPower])
        #expect(rig.changes.seen == [[.lowPower]])
    }

    @Test func startOnBatteryInLowPowerModeHoldsBothReasons() {
        let rig = LMRig(onBattery: true, lowPowerOn: true)
        #expect(rig.reasons == [.battery, .lowPower])
        #expect(rig.changes.seen.last == [.battery, .lowPower], "the last onChange sees both reasons set")
    }

    @Test func beforeStartThePowerChangesAndTicksChangeNothing() {
        let rig = LMRig(start: false)
        rig.power.change(to: true)
        rig.lowPower.change(to: true)
        rig.seconds(30, at: 100)
        #expect(rig.reasons.isEmpty)
        #expect(rig.changes.seen.isEmpty)
        #expect(rig.cpu.calls == 0, "the sampler is not called before start()")
    }

    @Test func stopCancelsTheTickAndIgnoresTheSources() {
        let rig = LMRig()
        rig.monitor.stop()
        #expect(rig.scheduler.active == false, "stop() cancels the schedule")
        let held = rig.reasons
        rig.changes.clear()
        let callsAtStop = rig.cpu.calls
        rig.power.change(to: true)
        rig.lowPower.change(to: true)
        rig.seconds(20, at: 100)
        #expect(rig.reasons == held, "nothing is added after stop()")
        #expect(rig.changes.seen.isEmpty, "no onChange after stop()")
        #expect(rig.cpu.calls == callsAtStop, "the sampler is not called after stop()")
    }

    // MARK: battery

    @Test func unpluggingAddsBatteryAndPluggingInRemovesIt() {
        let rig = LMRig()
        rig.power.change(to: true)
        #expect(rig.reasons == [.battery], "on battery adds battery")
        #expect(rig.monitor.pauseSet.isPaused == true)
        rig.power.change(to: false)
        #expect(rig.reasons.isEmpty, "on power removes battery")
        #expect(rig.monitor.pauseSet.isPaused == false)
        #expect(rig.changes.seen == [[.battery], []], "one onChange per change, each after the set was updated")
    }

    @Test func aPowerCallbackWithTheSameStateIsNoChange() {
        let rig = LMRig()
        rig.power.ping()
        #expect(rig.changes.seen.isEmpty, "a callback on power while on power changes nothing")
        rig.power.change(to: true)
        rig.power.ping()
        rig.power.ping()
        #expect(rig.reasons == [.battery])
        #expect(rig.changes.seen == [[.battery]], "a callback on battery while already on battery changes nothing")
    }

    @Test func aRepeatedBatteryStateCallbackAfterPluggingInIsNoChangeEither() {
        let rig = LMRig(onBattery: true)
        rig.power.change(to: false)
        rig.changes.clear()
        rig.power.ping()
        #expect(rig.reasons.isEmpty)
        #expect(rig.changes.seen.isEmpty)
    }

    // MARK: Low Power Mode

    @Test func lowPowerModeOnAddsLowPowerAndOffRemovesIt() {
        let rig = LMRig()
        rig.lowPower.change(to: true)
        #expect(rig.reasons == [.lowPower])
        #expect(rig.monitor.pauseSet.isPaused == true)
        rig.lowPower.change(to: false)
        #expect(rig.reasons.isEmpty)
        #expect(rig.monitor.pauseSet.isPaused == false)
        #expect(rig.changes.seen == [[.lowPower], []])
    }

    @Test func aLowPowerCallbackWithTheSameStateIsNoChange() {
        let rig = LMRig()
        rig.lowPower.ping()
        #expect(rig.changes.seen.isEmpty)
        rig.lowPower.change(to: true)
        rig.lowPower.ping()
        #expect(rig.changes.seen == [[.lowPower]])
    }

    @Test func batteryAndLowPowerModeComeAndGoIndependently() {
        let rig = LMRig()
        rig.power.change(to: true)
        rig.lowPower.change(to: true)
        rig.power.change(to: false)
        #expect(rig.reasons == [.lowPower], "plugging in leaves Low Power Mode paused")
        rig.power.change(to: true)
        rig.lowPower.change(to: false)
        #expect(rig.reasons == [.battery], "Low Power Mode off leaves the battery pause")
        rig.power.change(to: false)
        #expect(rig.reasons.isEmpty)
        #expect(rig.changes.seen == [[.battery], [.battery, .lowPower], [.lowPower], [.battery, .lowPower], [.battery], []])
    }

    // MARK: the CPU rule, through the monitor

    @Test func theTenthSecondAtFullLoadAddsCpuAndNoEarlierSecondDoes() {
        let rig = LMRig()
        rig.seconds(9, at: 100)
        #expect(rig.reasons.isEmpty, "nine seconds are not ten")
        #expect(rig.changes.seen.isEmpty)
        rig.seconds(1, at: 100)
        #expect(rig.reasons == [.cpu], "the tenth second adds cpu")
        #expect(rig.monitor.pauseSet.isPaused == true)
        #expect(rig.changes.seen == [[.cpu]])
    }

    @Test func staysPausedWhileTheLoadIsHighOrInBetweenAndOnChangeIsNotRepeated() {
        let rig = LMRig()
        rig.seconds(10, at: 100)
        rig.seconds(15, at: 100)
        rig.seconds(40, at: 60)
        rig.seconds(40, at: 50)
        #expect(rig.reasons == [.cpu], "50 and 60 percent keep the pause, for any length of time")
        #expect(rig.changes.seen == [[.cpu]], "still one change: nothing new happened")
    }

    @Test func thirtySecondsBelowFiftyRemoveCpuAndNoEarlierSecondDoes() {
        let rig = LMRig()
        rig.seconds(10, at: 100)
        rig.seconds(29, at: 40)
        #expect(rig.reasons == [.cpu], "twenty-nine seconds below 50 are not thirty")
        rig.seconds(1, at: 40)
        #expect(rig.reasons.isEmpty, "the thirtieth second removes cpu")
        #expect(rig.monitor.pauseSet.isPaused == false)
        #expect(rig.changes.seen == [[.cpu], []])
    }

    @Test func aBurstAtFiftyOrAboveBeforeTheThirtiethSecondRestartsTheResumeCount() {
        let rig = LMRig()
        rig.seconds(10, at: 100)
        rig.seconds(29, at: 40)
        rig.seconds(1, at: 55)
        rig.seconds(29, at: 40)
        #expect(rig.reasons == [.cpu], "29 s below 50, one at 55, then 29 s below 50 is not 30 in a row")
        rig.seconds(1, at: 40)
        #expect(rig.reasons.isEmpty)
    }

    @Test func shortBurstsAndASteadySixtyNeverPause() {
        let rig = LMRig()
        rig.seconds(5, at: 100)
        rig.seconds(1, at: 0)
        rig.seconds(8, at: 100)
        rig.seconds(1, at: 0)
        rig.seconds(9, at: 100)
        rig.seconds(1, at: 0)
        #expect(rig.reasons.isEmpty, "a 5 s, an 8 s and a 9 s burst never pause")
        rig.seconds(60, at: 60)
        #expect(rig.reasons.isEmpty, "a steady 60 percent for 60 s never pauses")
        #expect(rig.changes.seen.isEmpty)
    }

    @Test func seventyItselfIsNotAboveSeventy() {
        let rig = LMRig()
        rig.seconds(30, at: 70)
        #expect(rig.reasons.isEmpty)
    }

    @Test func theSamplerIsCalledOncePerTickAndNeverAtStart() {
        let rig = LMRig()
        #expect(rig.cpu.calls == 0, "start() takes no CPU sample of its own: the first sample is the first tick")
        rig.seconds(7, at: 20)
        #expect(rig.cpu.calls == 7)
        rig.seconds(5, at: 80)
        #expect(rig.cpu.calls == 12)
    }

    // MARK: the CPU rule leaves the other reasons alone

    @Test func theCpuPauseAndResumeLeaveBatteryLowPowerAndYouAlone() {
        let rig = LMRig(onBattery: true, lowPowerOn: true)
        rig.monitor.pauseSet.add(.you)
        rig.changes.clear()
        rig.seconds(10, at: 100)
        #expect(rig.reasons == [.battery, .lowPower, .you, .cpu])
        rig.seconds(30, at: 10)
        #expect(rig.reasons == [.battery, .lowPower, .you], "resume removes cpu and nothing else")
        #expect(rig.changes.seen == [[.battery, .lowPower, .you, .cpu], [.battery, .lowPower, .you]])
    }

    @Test func aPowerChangeWhileTheCpuPauseHoldsKeepsTheCpuReasonAndTheCountGoesOn() {
        let rig = LMRig()
        rig.seconds(10, at: 100)
        rig.power.change(to: true)
        rig.power.change(to: false)
        #expect(rig.reasons == [.cpu], "plugging in and out does not touch cpu")
        rig.seconds(30, at: 10)
        #expect(rig.reasons.isEmpty)
    }

    @Test func aCpuPauseWhileOnBatteryAddsToItAndPluggingInKeepsTheCpuPause() {
        let rig = LMRig(onBattery: true)
        rig.seconds(10, at: 100)
        #expect(rig.reasons == [.battery, .cpu])
        rig.power.change(to: false)
        #expect(rig.reasons == [.cpu])
    }

    // MARK: Resume anyway, on battery, through the monitor

    @Test func resumeAnywayThroughTheMonitorIsNotUndoneByALaterBatteryEvent() {
        let rig = LMRig(onBattery: true)
        rig.monitor.pauseSet.resumeAnyway()
        #expect(rig.reasons.isEmpty, "Resume anyway removes battery")
        rig.power.change(to: false)
        rig.power.change(to: true)
        rig.changes.clear()
        rig.power.ping()
        #expect(rig.reasons.isEmpty, "a later battery event in the same session is ignored")
        #expect(rig.monitor.pauseSet.isPaused == false)
        #expect(rig.changes.seen.isEmpty, "an ignored event is not a change, so no onChange")
        rig.lowPower.change(to: true)
        #expect(rig.reasons == [.lowPower], "Low Power Mode still pauses after Resume anyway")
        rig.seconds(10, at: 100)
        #expect(rig.reasons == [.lowPower, .cpu], "and so does the CPU rule")
    }

    // MARK: CPUSampler.apart(system:own:), hand numbers

    @Test func apartSubtractsSesamesOwnTicksFromTheSystemBusyTicks() {
        #expect(lmClose(CPUSampler.apart(system: (busy: 800, total: 1000), own: 300), 50), "(800 - 300) / 1000")
        #expect(lmClose(CPUSampler.apart(system: (busy: 1000, total: 1000), own: 250), 75), "(1000 - 250) / 1000")
        #expect(lmClose(CPUSampler.apart(system: (busy: 400, total: 2000), own: 100), 15), "(400 - 100) / 2000")
        #expect(lmClose(CPUSampler.apart(system: (busy: 30, total: 40), own: 10), 50), "(30 - 10) / 40")
    }

    @Test func apartWithNoOwnTicksIsTheSystemBusyShare() {
        #expect(lmClose(CPUSampler.apart(system: (busy: 500, total: 1000), own: 0), 50))
        #expect(lmClose(CPUSampler.apart(system: (busy: 250, total: 1000), own: 0), 25))
        #expect(lmClose(CPUSampler.apart(system: (busy: 1000, total: 1000), own: 0), 100))
        #expect(lmClose(CPUSampler.apart(system: (busy: 0, total: 1000), own: 0), 0))
    }

    @Test func apartNeverGoesBelowZero() {
        #expect(lmClose(CPUSampler.apart(system: (busy: 250, total: 1000), own: 250), 0), "all of the busy ticks are Sesame's")
        #expect(lmClose(CPUSampler.apart(system: (busy: 100, total: 1000), own: 300), 0), "own above busy (sampling skew) clamps to 0")
        #expect(lmClose(CPUSampler.apart(system: (busy: 0, total: 1000), own: 50), 0))
    }

    @Test func apartNeverGoesAboveOneHundred() {
        #expect(lmClose(CPUSampler.apart(system: (busy: 1200, total: 1000), own: 0), 100), "busy above total clamps to 100")
        #expect(lmClose(CPUSampler.apart(system: (busy: 1200, total: 1000), own: 100), 100), "(1200 - 100) / 1000 is still above 100")
    }

    @Test func apartStaysInRangeAndIsAnumberForAnEmptyInterval() {
        for got in [CPUSampler.apart(system: (busy: 0, total: 0), own: 0),
                    CPUSampler.apart(system: (busy: 5, total: 0), own: 0),
                    CPUSampler.apart(system: (busy: 5, total: 0), own: 9)] {
            #expect(got.isFinite, "a zero-length interval must not give NaN or infinity")
            #expect(got >= 0 && got <= 100)
        }
    }

    // MARK: the own set: the app and its child processes

    @Test func theOwnSetIsTheAppPidAndItsChildPids() {
        let parentOf: [Int32: Int32] = [
            1: 0,       // launchd
            100: 1,     // the app
            101: 100,   // a helper
            102: 100,   // the other helper
            200: 1,     // an unrelated app
            201: 200,   // its child
            300: 1,     // a busy stand-in the person started
        ]
        #expect(CPUSampler.ownPIDs(appPID: 100, parentOf: parentOf) == [100, 101, 102])
    }

    @Test func theOwnSetOfAnAppWithNoChildrenIsJustTheApp() {
        #expect(CPUSampler.ownPIDs(appPID: 100, parentOf: [1: 0, 100: 1, 200: 1]) == [100])
    }

    @Test func theOwnSetKeepsTheAppPidWhenTheProcessTableDoesNotListIt() {
        #expect(CPUSampler.ownPIDs(appPID: 100, parentOf: [:]) == [100])
    }

    // MARK: the real sources, headless, no assertion on the value

    @Test func hostCpuSamplerReturnsTwoConsecutiveValuesWithinZeroToOneHundred() {
        let sampler = HostCPUSampler()
        var values: [Double] = [sampler.sample()]
        // Some work between the two reads so the interval is not empty.
        var sink = 0.0
        let end = Date().addingTimeInterval(0.2)
        while Date() < end { sink += sqrt(Double(values.count) + 2) }
        values.append(sampler.sample())
        #expect(sink > 0)
        for (index, value) in values.enumerated() {
            #expect(value.isFinite, "value \(index) is a number")
            #expect(value >= 0 && value <= 100, "value \(index) is a percent: \(value)")
        }
    }

    @Test func powerSourceReaderGivesABoolWithoutLaunchingAnything() {
        let value: Bool = PowerSourceReader.onBattery()
        #expect(type(of: value) == Bool.self)
    }
}

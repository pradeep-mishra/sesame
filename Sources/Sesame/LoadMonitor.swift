import Foundation

/// Whether the Mac runs on battery. `onChange` fires when the power source may have changed; the monitor re-reads `onBattery`.
@MainActor protocol PowerSource: AnyObject {
    var onBattery: Bool { get }
    var onChange: (() -> Void)? { get set }
}

/// Whether Low Power Mode is on. Same contract as `PowerSource`.
@MainActor protocol LowPowerSource: AnyObject {
    var isOn: Bool { get }
    var onChange: (() -> Void)? { get set }
}

/// Percent (0...100) of CPU used apart from Sesame's own processes since the previous call.
@MainActor protocol CPUSource: AnyObject {
    func sample() -> Double
}

/// Repeats `tick` every `interval` seconds, with the time of the tick, until `cancel()`.
@MainActor protocol SampleScheduler: AnyObject {
    func every(_ interval: TimeInterval, _ tick: @escaping (Date) -> Void)
    func cancel()
}

/// Pure helpers for "system CPU apart from Sesame" (design section 8).
enum CPUSampler {
    /// `system` is the busy and all ticks of one interval, `own` the ticks Sesame's processes used in it (same unit).
    /// The result is (busy - own) over total, as percent, clamped to 0...100; an empty interval is 0.
    static func apart(system: (busy: Double, total: Double), own: Double) -> Double {
        guard system.total > 0 else { return 0 }
        let percent = (system.busy - own) / system.total * 100
        return min(100, max(0, percent))
    }

    /// The app's pid and the pids whose parent is the app (the helper processes). `parentOf` maps a pid to its parent.
    static func ownPIDs(appPID: Int32, parentOf: [Int32: Int32]) -> Set<Int32> {
        var own: Set<Int32> = [appPID]
        for (pid, parent) in parentOf where parent == appPID { own.insert(pid) }
        return own
    }
}

/// Watches the power source, Low Power Mode and the CPU load apart from Sesame, and keeps the matching reasons
/// (`battery`, `lowPower`, `cpu`) in `pauseSet`. It starts no process and writes no file.
@MainActor final class LoadMonitor {
    var pauseSet = PauseSet()
    /// Called once for each reason added or removed, after `pauseSet` holds the new state.
    var onChange: (() -> Void)?

    private let power: any PowerSource
    private let lowPower: any LowPowerSource
    private let cpu: any CPUSource
    private let scheduler: any SampleScheduler
    private var rule = CPURule()
    private var running = false

    init(power: any PowerSource, lowPower: any LowPowerSource, cpu: any CPUSource, scheduler: any SampleScheduler) {
        self.power = power
        self.lowPower = lowPower
        self.cpu = cpu
        self.scheduler = scheduler
    }

    /// Reads both sources once (a Mac that wakes up on battery is paused at once), listens to them and starts the 1 s sample.
    func start() {
        running = true
        rule = CPURule()
        power.onChange = { [weak self] in self?.readBattery() }
        lowPower.onChange = { [weak self] in self?.readLowPower() }
        readBattery()
        readLowPower()
        scheduler.every(1) { [weak self] now in self?.sampleCPU(at: now) }
    }

    func stop() {
        running = false
        scheduler.cancel()
        power.onChange = nil
        lowPower.onChange = nil
    }

    private func readBattery() {
        guard running else { return }
        set(.battery, power.onBattery)
    }

    private func readLowPower() {
        guard running else { return }
        set(.lowPower, lowPower.isOn)
    }

    private func sampleCPU(at now: Date) {
        guard running else { return }
        switch rule.feed(cpu.sample(), at: now) {
        case .pause: set(.cpu, true)
        case .resume: set(.cpu, false)
        case nil: break
        }
    }

    private func set(_ reason: PauseReason, _ on: Bool) {
        let before = pauseSet.reasons
        if on { pauseSet.add(reason) } else { pauseSet.remove(reason) }
        if pauseSet.reasons != before { onChange?() }
    }
}

/// The real scheduler: a repeating sleep on the main actor.
@MainActor final class TimerScheduler: SampleScheduler {
    private var task: Task<Void, Never>?

    func every(_ interval: TimeInterval, _ tick: @escaping (Date) -> Void) {
        cancel()
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                tick(Date())
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

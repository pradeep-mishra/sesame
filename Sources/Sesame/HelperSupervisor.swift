import Foundation

/// The `index` helper as the supervisor sees it. `start()` makes sure one helper runs and sends it the whole
/// `folders` list, once per call; `stopClean()` ends its stdin and returns at once, `isRunning` stays true until the
/// exit has been reported through `onExit`. The supervisor never calls `start()` while a stopped helper is still
/// exiting, and never calls `stopClean()` with none running or twice.
@MainActor
protocol IndexHost: AnyObject {
    var isRunning: Bool { get }
    var onExit: ((HelperExit) -> Void)? { get set }
    func start()
    func stopClean()
}

/// Decides when the `index` helper runs (design section 3): Pause is a clean stop, Resume starts a new helper that
/// is sent `folders`. After an unplanned exit it starts a new one when indexing is still wanted and work remains, after a
/// delay of 1, 2, 5, then 10 s (back to 1 s after a `changed` event); the `maxDeaths`-th death in a row is not
/// restarted and stalls the supervisor. An idle exit (status 0 nobody asked for) is no death: with work left it stalls
/// too, with none left it does nothing. A stalled supervisor starts nothing until `resetStall()` or `helperChanged()`.
/// Every other caller says that something changed with `reevaluate()`.
@MainActor
final class HelperSupervisor {
    struct Inputs {
        var startPressed: Bool
        var indexDeleted: Bool
        var modelWhole: Bool
        var pauseReasons: Set<PauseReason>
        var quitting: Bool
        /// The speed bench runs: the index helper is not started beside it.
        var measuring: Bool = false
    }

    /// The wait before the n-th restart in a row.
    static let restartDelays: [TimeInterval] = [1, 2, 5, 10]
    /// The death in a row (no `helperChanged()` between) that is not restarted.
    static let maxDeaths = 5

    /// Called once when the supervisor stalls: the cap was reached, or the helper idled out with work left.
    var onStalled: (() -> Void)?

    /// Runs `work` on the main actor after `delay` seconds, on a real timer.
    nonisolated static func timerSchedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    private let host: any IndexHost
    private let inputs: () -> Inputs
    private let workRemains: () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var stopping = false
    /// Unplanned exits answered with a restart since the last `changed` event.
    private var deaths = 0
    /// A restart is waiting for its delay; `restartID` names it, so a cancelled or spent one does nothing when due.
    private var restartWaiting = false
    private var restartID = 0
    /// No helper is started by the supervisor until `resetStall()` or `helperChanged()`.
    private var stalled = false

    init(
        host: any IndexHost, inputs: @escaping () -> Inputs, workRemains: @escaping () -> Bool = { true },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = HelperSupervisor.timerSchedule
    ) {
        self.host = host
        self.inputs = inputs
        self.workRemains = workRemains
        self.schedule = schedule
        host.onExit = { [weak self] exit in self?.hostExited(exit) }
    }

    private var wanted: Bool {
        let now = inputs()
        return now.startPressed && !now.indexDeleted && now.modelWhole && now.pauseReasons.isEmpty && !now.quitting
            && !now.measuring
    }

    /// Something that decides whether indexing runs changed (a pause reason, Start, the model, Quit), or the app
    /// just launched.
    func reevaluate() {
        if wanted {
            // A helper that is exiting from a stop is waited for: its exit starts the new one. A restart that is
            // waiting for its delay is waited for too.
            if !host.isRunning, !restartWaiting, !stalled { host.start() }
        } else {
            restartWaiting = false
            if host.isRunning, !stopping {
                stopping = true
                host.stopClean()
            }
        }
    }

    /// A folder or a drive changed. A running helper is sent the list again; with none running one is started when
    /// indexing is wanted. Not wanted: nothing now, and the next resume sends the list anyway.
    func syncNeeded() {
        guard wanted, !stalled, !(host.isRunning && stopping) else { return }
        restartWaiting = false
        host.start()
    }

    /// The index helper said `changed`: the next restart waits 1 s again, and a stall ends.
    func helperChanged() {
        deaths = 0
        stalled = false
    }

    /// Clears the stall and the death count; the owner calls `reevaluate()` after it.
    func resetStall() {
        deaths = 0
        stalled = false
    }

    private func stall() {
        stalled = true
        onStalled?()
    }

    private func hostExited(_ exit: HelperExit) {
        stopping = false
        switch exit {
        case .planned:
            reevaluate()
        case .idle:
            guard wanted, !stalled, workRemains() else { return }
            stall()
        case .unplanned:
            guard wanted, !stalled, workRemains() else { return }
            deaths += 1
            if deaths >= Self.maxDeaths { stall(); return }
            let delay = Self.restartDelays[deaths - 1]
            restartID += 1
            let id = restartID
            restartWaiting = true
            schedule(delay) { [weak self] in self?.restartDue(id) }
        }
    }

    private func restartDue(_ id: Int) {
        guard restartWaiting, restartID == id else { return }
        restartWaiting = false
        guard wanted, workRemains(), !host.isRunning else { return }
        host.start()
    }
}

/// The real `HelperClient` as an `IndexHost`: `start()` is the Start hook (`sendFolders()` starts the `index`
/// helper when none runs), `stopClean()` is `stopIndex()`, and the client's exit report for `index` is the host's.
@MainActor
final class HelperClientIndexHost: IndexHost {
    private let client: HelperClient
    private(set) var isRunning = false
    var onExit: ((HelperExit) -> Void)?

    init(client: HelperClient) {
        self.client = client
        client.onExit = { [weak self] helper, exit in
            guard helper == "index" else { return }
            Task { @MainActor in self?.exited(exit) }
        }
    }

    func start() {
        if client.queueFolders() { isRunning = true }
    }

    func stopClean() {
        client.stopIndex()
    }

    private func exited(_ exit: HelperExit) {
        isRunning = false
        onExit?(exit)
    }
}

import Foundation

/// What a "Start indexing" or "Re-index" press does about a stalled helper (the supervisor gave up). Pressing Start is a
/// fresh ask, like Resume: the stall reason goes, the supervisor's give-up state is reset, and the status cache and the
/// supervisor read again, once each. With no stall nothing runs.
enum StallRecovery {
    /// `resetStall` runs first, then `settingsChanged` and `reevaluate`. Only `.stalled` leaves `pauseSet`.
    static func recover(
        pauseSet: inout PauseSet, resetStall: () -> Void, settingsChanged: () -> Void, reevaluate: () -> Void
    ) {
        guard pauseSet.reasons.contains(.stalled) else { return }
        pauseSet.remove(.stalled)
        resetStall()
        settingsChanged()
        reevaluate()
    }
}

import Foundation

/// The reasons indexing is paused right now (design section 6). Memory only: a new `PauseSet` is a new session,
/// holds no reason and has no override. Nothing here reads or writes a file.
struct PauseSet: Equatable {
    private(set) var reasons: Set<PauseReason> = []
    private var batteryOverridden = false

    var isPaused: Bool { !reasons.isEmpty }

    mutating func add(_ reason: PauseReason) {
        if reason == .battery && batteryOverridden { return }
        reasons.insert(reason)
    }

    mutating func remove(_ reason: PauseReason) {
        reasons.remove(reason)
    }

    /// "Resume anyway, on battery": drops the battery reason and ignores later battery events in this session.
    /// The other reasons stay.
    mutating func resumeAnyway() {
        batteryOverridden = true
        reasons.remove(.battery)
    }
}

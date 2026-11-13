import Foundation

extension MenuActions {
    /// The menu's real actions. Pause adds "you" to the monitor's pause set and Resume removes "you" and "stalled"; when it
    /// removed one of them it first calls `resetStall`, so the supervisor starts again. "Resume anyway, on battery"
    /// drops only the battery reason. Each of the three tells the status cache and the supervisor once, after the
    /// set holds the change. Retry model download runs the setup window's Retry path. Open Sesame and Settings only open
    /// their window; Quit runs the quit plan.
    @MainActor
    static func live(
        monitor: LoadMonitor,
        settingsChanged: @escaping () -> Void,
        reevaluate: @escaping () -> Void,
        resetStall: @escaping () -> Void = {},
        retryDownload: @escaping () -> Void,
        openPanel: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quit: QuitPlan
    ) -> MenuActions {
        func changed() {
            settingsChanged()
            reevaluate()
        }
        return MenuActions(
            pause: {
                monitor.pauseSet.add(.you)
                changed()
            },
            resume: {
                let reasons = monitor.pauseSet.reasons
                monitor.pauseSet.remove(.you)
                monitor.pauseSet.remove(.stalled)
                if reasons.contains(.you) || reasons.contains(.stalled) { resetStall() }
                changed()
            },
            resumeAnyway: {
                monitor.pauseSet.resumeAnyway()
                changed()
            },
            retryDownload: { retryDownload() },
            open: { openPanel() },
            settings: { openSettings() },
            quit: { quit.begin() })
    }
}

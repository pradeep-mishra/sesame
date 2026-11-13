import Foundation

/// Joins Retry (the setup window's button and the menu's "Retry model download", both through `AppDelegate.modelRetried()`)
/// to whichever fetch failed. Retry goes to the watcher when it is waiting for one; otherwise the launch download failed
/// and one launch download is started. Never both, so two fetches never write one `.partial`. Once Retry has gone to the
/// watcher, another Retry does nothing until the watcher fails again: the watcher's own `retry()` clears `needsRetry` at
/// once, and a second press must not read that as "the launch download failed".
@MainActor
final class ModelRecovery {
    private let setup: SetupModel
    private let watcher: any ModelWatching
    private let startLaunchDownload: @MainActor () -> Void
    /// A Retry went to the watcher and the watcher has not failed again; its fetch is the one running.
    private var watcherIsFetching = false

    init(setup: SetupModel, watcher: any ModelWatching, startLaunchDownload: @escaping @MainActor () -> Void) {
        self.setup = setup
        self.watcher = watcher
        self.startLaunchDownload = startLaunchDownload
    }

    /// Shows a watcher failure in the setup model. The app does not call this: `AppDelegate.modelDownloadFailed` shows
    /// every failure (the launch download's and the watcher's) through `OnDemandSetup.downloadFailed`. Only tests call it.
    func watcherFailed(_ text: String) {
        watcherIsFetching = false
        setup.downloadFailed(text)
    }

    func retry() {
        if watcher.needsRetry {
            watcherIsFetching = true
            watcher.retry()
        } else if !watcherIsFetching {
            startLaunchDownload()
        }
    }
}

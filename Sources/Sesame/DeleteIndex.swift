import Foundation
import SesameEngine

/// Delete index, in the order design section 1 gives so a crash in the middle can be recovered:
/// (1) the app's index connection is closed, (2) `settings.json` is written with `startPressed` false and
/// `indexDeleted` true (folders and everything else kept), (3) `reset` goes to the helper, which deletes the index
/// files, (4) the two Caches folders are deleted. The models are never touched. Start sets `indexDeleted` false.
final class DeleteIndex {
    private let closeIndex: () -> Void
    private let sendReset: () -> Void
    private let deleteCaches: () throws -> Void

    init(
        closeIndex: @escaping () -> Void,
        sendReset: @escaping () -> Void,
        deleteCaches: @escaping () throws -> Void = { try SesameFolder.deleteCaches() }
    ) {
        self.closeIndex = closeIndex
        self.sendReset = sendReset
        self.deleteCaches = deleteCaches
    }

    /// Does nothing without `confirmed`. Throws when the settings cannot be written; then no reset is sent and no
    /// Caches folder is deleted, because a reset while `settings.json` still says Start was pressed is not recoverable.
    func run(confirmed: Bool) throws {
        guard confirmed else { return }
        closeIndex()
        var settings = try SettingsFile().read()
        settings.startPressed = false
        settings.indexDeleted = true
        try SettingsFile().write(settings)
        sendReset()
        try deleteCaches()
    }

    /// At launch: `indexDeleted` with an index file still there is a crash between (2) and (3), so `reset` goes out again.
    func resumeIfNeeded(indexFileExists: Bool, settings: Settings) {
        guard settings.indexDeleted, indexFileExists else { return }
        sendReset()
    }
}

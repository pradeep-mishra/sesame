import Foundation
import Observation
import SesameEngine

/// What the Settings model tells after a write: "send the `folders` command". `HelperClient` is the real one.
protocol FoldersSender {
    func sendFolders()
}

extension HelperClient: FoldersSender {}

extension Settings {
    /// A folder's tick differs from what the helper reads: it waits for Start indexing.
    var hasPendingTicks: Bool { folders.contains { $0.ticked != $0.reading } }
}

/// The folder list and the file kinds of Settings (design section 3, "Folder changes"). Every change
/// is written to `settings.json` first and only then sent to the helper, so the query-time `Visible` filter already
/// hides what was unticked or removed when the helper hears of it. Adding or re-ticking a folder only counts it:
/// its `reading` stays false on disk, and nothing is sent, until `startIndexing()`.
@MainActor
@Observable
final class SettingsModel {
    private(set) var rows: [FolderRow] = []
    private(set) var errorText: String?
    private(set) var setAsideNotice: String?

    var modelIsWhole: Bool { modelWhole() }

    @ObservationIgnored private let sender: any FoldersSender
    @ObservationIgnored private let counter: @Sendable ([String]) -> FolderCounts
    @ObservationIgnored private let modelWhole: () -> Bool
    /// Runs after `sendFolders()` of each "Start indexing" and "Re-index" press, and of nothing else.
    @ObservationIgnored private let onIndexingRequested: () -> Void
    /// The count in flight for each path; an older answer is dropped.
    @ObservationIgnored private var generation: [String: Int] = [:]

    init(
        sender: any FoldersSender,
        counter: @escaping @Sendable ([String]) -> FolderCounts = { FolderCounts.count(folders: $0) },
        modelWhole: @escaping () -> Bool,
        onIndexingRequested: @escaping () -> Void = {}
    ) {
        self.sender = sender
        self.counter = counter
        self.modelWhole = modelWhole
        self.onIndexingRequested = onIndexingRequested
        if SettingsFile().setAsideIfCorrupt() { setAsideNotice = SettingsScreen.settingsSetAsideText }
        let settings = (try? SettingsFile().read()) ?? Settings()
        for folder in settings.folders {
            rows.append(FolderRow(path: folder.path, ticked: folder.ticked))
            if folder.ticked { count(folder.path) }
        }
    }

    func dismissSetAsideNotice() {
        setAsideNotice = nil
    }

    // MARK: actions

    /// "Add folder…": a ticked row, counted at once, stored with `reading` false and the tick pending. Nothing is sent.
    func addFolder(_ url: URL) {
        let path = url.path
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !rows.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == key }) else { return }
        guard change({ $0.folders.append(Settings.Folder(path: path, code: false, reading: false, ticked: true)) }) else { return }
        rows.append(FolderRow(path: path, ticked: true))
        count(path)
    }

    /// Unticking writes `reading` false and `ticked` false, then sends if the folder was reading. Ticking stores the tick,
    /// counts the folder again and waits for Start indexing: `reading` stays false and nothing is sent.
    func setTicked(_ path: String, _ ticked: Bool) {
        guard let index = rows.firstIndex(where: { $0.path == path }), rows[index].ticked != ticked else { return }
        let wasReading = ((try? SettingsFile().read())?.folders.first { $0.path == path }?.reading) ?? false
        guard change({ settings in
            guard let at = settings.folders.firstIndex(where: { $0.path == path }) else { return }
            settings.folders[at].ticked = ticked
            if !ticked { settings.folders[at].reading = false }
        }) else { return }
        rows[index].ticked = ticked
        if ticked {
            count(path)
        } else if wasReading {
            sender.sendFolders()
        }
    }

    /// Needs `confirmed`; without it nothing changes. Writes the list without the folder, then sends.
    func removeFolder(_ path: String, confirmed: Bool) {
        guard confirmed, rows.contains(where: { $0.path == path }) else { return }
        guard change({ $0.folders.removeAll { $0.path == path } }) else { return }
        rows.removeAll { $0.path == path }
        generation[path] = nil
        sender.sendFolders()
    }

    /// A kind switched off hides its results at once through `Visible`, which reads the file at each search, and sends
    /// nothing. A kind switched on sends `folders` once, after the write, so the helper reconciles what it skipped. It never
    /// calls `onIndexingRequested`: that hook is the stalled-start check of Start indexing and Re-index only.
    func setKind(_ kind: String, on: Bool) {
        guard change({ $0.kindsOn[kind] = on }) else { return }
        refreshEstimates()
        if on { sender.sendFolders() }
    }

    /// "Start indexing": `reading` is true for the ticked rows and false for the others, then one send.
    @discardableResult
    func startIndexing() -> Bool {
        let ticked = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0.ticked) })
        guard change({ settings in
            for at in settings.folders.indices {
                let tick = ticked[settings.folders[at].path] ?? false
                settings.folders[at].reading = tick
                settings.folders[at].ticked = tick
            }
            settings.startPressed = true
            settings.indexDeleted = false
        }) else { return false }
        sender.sendFolders()
        onIndexingRequested()
        return true
    }

    func clearError() {
        errorText = nil
    }

    /// The per-folder "Re-index". A folder whose tick waits for Start gets it applied like Start does (its `reading`
    /// follows its tick, `startPressed` is set, one send); it is not a destructive re-read. Any other folder only asks for a
    /// sync: nothing is written and `folders` is sent once. While the model is not whole a waiting tick is left waiting.
    /// Returns true when it applied a waiting tick (Start state changed).
    @discardableResult
    func reindex(_ path: String) -> Bool {
        let pending = ((try? SettingsFile().read())?.folders.first { $0.path == path }).map { $0.ticked != $0.reading } ?? false
        guard pending, modelWhole() else {
            sender.sendFolders()
            onIndexingRequested()
            return false
        }
        guard change({ settings in
            guard let at = settings.folders.firstIndex(where: { $0.path == path }) else { return }
            settings.folders[at].reading = settings.folders[at].ticked
            settings.startPressed = true
            settings.indexDeleted = false
        }) else { return false }
        sender.sendFolders()
        onIndexingRequested()
        return true
    }

    // MARK: the file

    /// Reads, changes and writes `settings.json`. A failure gives `errorText` and returns false.
    private func change(_ edit: (inout Settings) -> Void) -> Bool {
        do {
            var settings = try SettingsFile().read()
            edit(&settings)
            try SettingsFile().write(settings)
            errorText = nil
            return true
        } catch {
            errorText = "Could not save your settings."
            return false
        }
    }

    // MARK: counting

    private func count(_ path: String) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        let id = (generation[path] ?? 0) + 1
        generation[path] = id
        rows[index].state = .counting
        rows[index].counts = [:]
        rows[index].estimateText = "counting"
        let counter = self.counter
        Task { [weak self] in
            let counts = await Task.detached(priority: .utility) { counter([path]).perFolder[path] ?? [:] }.value
            self?.counted(path, id, counts)
        }
    }

    private func counted(_ path: String, _ id: Int, _ counts: [String: Int]) {
        guard generation[path] == id, let index = rows.firstIndex(where: { $0.path == path }) else { return }
        rows[index].counts = counts
        rows[index].state = .ready
        rows[index].estimateText = estimate(counts, at: path)
    }

    private func refreshEstimates() {
        for index in rows.indices where rows[index].state == .ready {
            rows[index].estimateText = estimate(rows[index].counts, at: rows[index].path)
        }
    }

    private func estimate(_ counts: [String: Int], at path: String) -> String {
        let settings = (try? SettingsFile().read()) ?? Settings()
        return Estimator.estimate(
            counts: counts, speeds: settings.speeds, kindsOn: settings.kindsOn, modelWhole: modelWhole()
        ).text
    }
}

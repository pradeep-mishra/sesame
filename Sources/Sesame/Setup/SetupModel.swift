import Foundation
import Observation
import SesameEngine

/// What the setup window shows and does (design sections 1 and 9). Progress is never copied: `refresh()`
/// reads the files under `models/` (a file under its real name is whole; a `.partial` counts its bytes on disk).
/// The window calls `refresh()` a few times a second; the download side calls `downloadFailed(_:)`, the model
/// watcher's message calls `modelWasDamaged()`.
@MainActor
@Observable
final class SetupModel {
    static let startTitle = "Start indexing"
    static let addFolderTitle = "Add folder\u{2026}"
    static let retryTitle = "Retry"
    static let damagedMessage = "The model file was damaged, so it was deleted. Downloading it again."
    nonisolated static let downloadFailedMessage = "Could not download the model"

    private(set) var progressText = ""
    private(set) var fractionDone = 0.0
    private(set) var modelIsWhole = false
    private(set) var errorText: String?
    private(set) var damagedText: String?
    private(set) var startErrorText: String?
    private(set) var pickedFolders: [String] = []
    private var untickedFolders: Set<String> = []
    /// Start was pressed, here or in an earlier window: set from settings.json at init and at each refresh, in both
    /// directions (Delete index makes it false again), so a setup window built after Start (the damaged-model re-show)
    /// never offers Start again. The folder rows and Add folder are disabled then, because Finish writes only the flag and
    /// a change made here would be lost.
    private(set) var started = false

    @ObservationIgnored private let files: [ModelFile]
    /// Set by the window that owns the model, once the window exists.
    @ObservationIgnored var onStart: () -> Void
    @ObservationIgnored var onRetry: () -> Void

    init(files: [ModelFile] = ModelFiles.all, onStart: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {}) {
        self.files = files
        self.onStart = onStart
        self.onRetry = onRetry
        refresh()
    }

    var showsRetry: Bool { errorText != nil }

    /// Unavailable until every model file is whole (spec S6); no folder is needed to press it (S6.7 reads the
    /// button enabled with none picked, and the folder list in settings.json may be empty).
    var canStartIndexing: Bool { modelIsWhole && !started }

    /// Re-reads the model files and `startPressed` now. `startIndexing()` sets `started` itself when the write succeeds.
    func refresh() {
        let pressed = (try? SettingsFile().read().startPressed) == true
        if started != pressed { started = pressed }
        var have = 0
        var total = 0
        var whole = true
        for file in files {
            total += file.size
            if size(of: file.name) == file.size {
                have += file.size
            } else {
                whole = false
                have += min(size(of: file.name + ".partial") ?? 0, file.size)
            }
        }
        // Each value is set only when it changed: the window reads this twice a second, and a redundant
        // set makes the view redraw its text, which the accessibility tree shows as a blank line.
        if modelIsWhole != whole { modelIsWhole = whole }
        let fraction = total > 0 ? (Double(have) / Double(total) * 1000).rounded() / 1000 : 0
        if fractionDone != fraction { fractionDone = fraction }
        let text = "\(Self.megabytes(have)) of \(Self.megabytes(total)) MB"
        if progressText != text { progressText = text }
        if whole {
            if errorText != nil { errorText = nil }
            if damagedText != nil { damagedText = nil }
        }
    }

    func downloadFailed(_ text: String) {
        errorText = text
    }

    func retry() {
        errorText = nil
        onRetry()
    }

    /// The watcher fetches again now, so an earlier failure line and its Retry go: Retry would start a launch download
    /// beside the watcher's fetch.
    func modelWasDamaged() {
        errorText = nil
        damagedText = Self.damagedMessage
    }

    func addFolder(_ url: URL) {
        guard !pickedFolders.contains(url.path) else { return }
        pickedFolders.append(url.path)
    }

    func setFolder(_ path: String, ticked: Bool) {
        guard pickedFolders.contains(path) else { return }
        if ticked { untickedFolders.remove(path) } else { untickedFolders.insert(path) }
    }

    func isTicked(_ path: String) -> Bool {
        pickedFolders.contains(path) && !untickedFolders.contains(path)
    }

    /// Writes `startPressed` and every picked folder (reading only when ticked) to settings.json,
    /// then calls the Start hook once.
    func startIndexing() {
        guard canStartIndexing else { return }
        do {
            let file = SettingsFile()
            var settings = try file.read()
            settings.startPressed = true
            settings.indexDeleted = false
            settings.setupFinished = true
            // The picked rows replace their own entries; a folder of the person's that is not among them (not found
            // today, say) stays as it was.
            let kept = settings.folders.filter { !pickedFolders.contains($0.path) }
            let before = settings.folders
            settings.folders = pickedFolders.map { path in
                Settings.Folder(path: path, code: before.first { $0.path == path }?.code ?? false, reading: isTicked(path))
            } + kept
            try file.write(settings)
        } catch {
            startErrorText = "Could not save the settings, so indexing did not start."
            return
        }
        startErrorText = nil
        started = true
        onStart()
    }

    /// Finish: setup is finished for good. Before Start, every picked folder is kept as a waiting tick (`ticked`, not
    /// `reading`) so Settings shows it; `startPressed` is never written. After Start only the flag is written.
    func finishSetup() {
        do {
            let file = SettingsFile()
            var settings = try file.read()
            if !settings.startPressed {
                for path in pickedFolders {
                    let tick = isTicked(path)
                    if let at = settings.folders.firstIndex(where: { $0.path == path }) {
                        settings.folders[at].ticked = tick
                    } else if tick {
                        settings.folders.append(Settings.Folder(path: path, code: false, reading: false, ticked: true))
                    }
                }
            }
            settings.setupFinished = true
            try file.write(settings)
        } catch {
            // The window closes anyway; with no flag written, the next launch shows setup again.
        }
    }

    // MARK: helpers

    /// Decimal megabytes (1,000,000 bytes), rounded to the nearest whole number.
    private static func megabytes(_ bytes: Int) -> Int {
        (bytes + 500_000) / 1_000_000
    }

    private func size(of name: String) -> Int? {
        let path = SesameFolder.modelsURL.appendingPathComponent(name).path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }
}

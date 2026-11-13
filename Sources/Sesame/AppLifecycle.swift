import Foundation
import SesameEngine

/// What a launch does, from what is on disk (design section 3, the first-window rule): setup until Start was pressed
/// once, the download while the model is not whole, a resume by itself after Start, and nothing at all after Delete
/// index apart from the reset a crash left undone. It reads nothing and writes nothing.
struct LaunchPlan: Equatable {
    /// The setup window opens (it also holds the model download).
    let showsSetup: Bool
    /// Indexing resumes by itself now: Start was pressed, the model is whole, the index was not deleted.
    let startsIndexing: Bool
    /// Start was pressed but the model is not whole: indexing waits for it.
    let defersIndexingUntilModelWhole: Bool
    /// `indexDeleted` with an index file still there: the crash recovery of Delete index sends `reset` again.
    let requestsReset: Bool

    static func decide(settings: Settings, modelWhole: Bool, indexFileExists: Bool) -> LaunchPlan {
        let wantsIndexing = settings.startPressed && !settings.indexDeleted
        return LaunchPlan(
            // Start pressed with the model not whole: the setup window carries the download (no Start in it).
            showsSetup: SetupFlow.needed(settings: settings, modelWhole: modelWhole) || (wantsIndexing && !modelWhole),
            startsIndexing: wantsIndexing && modelWhole,
            defersIndexingUntilModelWhole: wantsIndexing && !modelWhole,
            requestsReset: settings.indexDeleted && indexFileExists)
    }
}

/// Quit (S7.2, S7.11): indexing stops, both helpers are asked to end, and the app ends as soon as both are gone. A helper
/// that has not ended `timeout` seconds after the ask is killed by the client, so no Sesame process outlives the app by
/// more than a few seconds. Quit deletes nothing and writes nothing: the index and settings stay for the next launch.
@MainActor
final class QuitPlan {
    static let helperTimeout: TimeInterval = 4

    private let stopIndexing: () -> Void
    private let shutdownHelpers: (_ timeout: TimeInterval, _ completion: @escaping @Sendable () -> Void) -> Void
    private let terminate: () -> Void
    private var begun = false
    private var finished = false

    init(
        stopIndexing: @escaping () -> Void,
        shutdownHelpers: @escaping (_ timeout: TimeInterval, _ completion: @escaping @Sendable () -> Void) -> Void,
        terminate: @escaping () -> Void
    ) {
        self.stopIndexing = stopIndexing
        self.shutdownHelpers = shutdownHelpers
        self.terminate = terminate
    }

    /// A second call (Quit twice, Quit while quitting) does nothing.
    func begin() {
        guard !begun else { return }
        begun = true
        stopIndexing()
        shutdownHelpers(Self.helperTimeout) { [self] in
            // The client calls back from any thread. On the main thread the app ends before this returns.
            if Thread.isMainThread {
                MainActor.assumeIsolated { finish() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish() } }
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        terminate()
    }
}

enum AppLifecycle {
    /// What the app does at launch after `LaunchPlan.decide`: the load monitor's changes feed the status and the
    /// supervisor, the monitor starts first (a Mac that wakes up on battery is paused before any helper starts), and the
    /// supervisor then decides, which resumes indexing by itself when Start was pressed.
    @MainActor
    static func launch(monitor: LoadMonitor, settingsChanged: @escaping () -> Void, reevaluate: @escaping () -> Void) {
        monitor.onChange = {
            settingsChanged()
            reevaluate()
        }
        monitor.start()
        reevaluate()
    }
}

extension MenuModel {
    /// The menu from the cached status, the pause reasons held now and `settings.json` (speeds and the kinds that are on).
    static func make(snapshot: PanelSnapshot, pauseReasons: Set<PauseReason>, settings: Settings) -> MenuModel {
        MenuModel(
            inputs: MenuInputs(
                model: snapshot.model, startPressed: snapshot.startPressed, indexDeleted: snapshot.indexDeleted,
                walkDoneAt: snapshot.walkDone ? .distantPast : nil, counts: snapshot.counts, pauseReasons: pauseReasons),
            downloadPercent: snapshot.model == .whole ? 100 : ModelProgress.percent(),
            doneByKind: snapshot.doneByKind,
            speeds: settings.speeds,
            kindsOn: settings.kindsOn)
    }
}

/// How much of the model is on disk: a file under its real name counts whole, a `.partial` counts its bytes.
enum ModelProgress {
    static func percent(files: [ModelFile] = ModelFiles.all) -> Int {
        var have = 0
        var total = 0
        for file in files {
            total += file.size
            if size(of: file.name) == file.size {
                have += file.size
            } else {
                have += min(size(of: file.name + ".partial") ?? 0, file.size)
            }
        }
        return total > 0 ? Int(Double(have) / Double(total) * 100) : 0
    }

    private static func size(of name: String) -> Int? {
        let path = SesameFolder.modelsURL.appendingPathComponent(name).path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }
}

import Foundation
import SesameEngine

/// Where the status comes from: the four things the panel (and the menu) show. Each closure may block on disk or on the
/// index reader, so `StatusCache` calls them only on its own queue, never on the main thread.
struct StatusSources: Sendable {
    var settings: @Sendable () -> Settings
    var counts: @Sendable () -> IndexCounts
    /// The index's `meta` table: `walk_done_at` and `vector_source` are asked.
    var meta: @Sendable (String) -> String?
    var modelState: @Sendable () -> ModelState
    /// Files with status `done`, per kind (the menu's counts).
    var doneByKind: @Sendable () -> [String: Int] = { [:] }
    /// The path of the `done` file indexed last (the menu's "Last indexed").
    var lastIndexedPath: @Sendable () -> String? = { nil }

    /// The app's own sources: `settings.json`, the one `IndexReader`, and the given model state.
    static func live(reader: IndexReader, modelState: @escaping @Sendable () -> ModelState) -> StatusSources {
        StatusSources(
            settings: { (try? SettingsFile().read()) ?? Settings() },
            counts: { IndexProgress.counts(reader: reader) },
            meta: { reader.meta($0) },
            modelState: modelState,
            doneByKind: { doneByKind(reader: reader) },
            lastIndexedPath: { reader.lastIndexedPath() })
    }

    /// One count of `done` files per kind; a kind with none is left out.
    static func doneByKind(reader: IndexReader) -> [String: Int] {
        var done: [String: Int] = [:]
        for row in reader.statusCounts() where row.status == "done" { done[row.kind, default: 0] += row.files }
        return done
    }
}

/// The one holder of what the panel and the menu read (design sections 3 and 8). `snapshot()` returns the last stored
/// value and calls no source, so the main thread never waits on the index reader (which the matrix load holds for its
/// whole read). `refresh()` reads the sources on `queue` and stores the result; calls that arrive while one refresh runs
/// share one more.
final class StatusCache: @unchecked Sendable {
    private let sources: StatusSources
    private let queue: DispatchQueue
    /// The `vector_source` this app expects; nil means the index's value is not compared.
    private let expectedVectorSource: String?
    private let lock = NSLock()
    private var stored = PanelSnapshot()
    private var running = false
    private var again = false
    private var handler: (@Sendable () -> Void)?
    private var changedHandler: (@Sendable () -> Void)?

    init(sources: StatusSources, queue: DispatchQueue = DispatchQueue(label: "app.sesame.status", qos: .utility),
         vectorSource: String? = nil) {
        self.sources = sources
        self.queue = queue
        self.expectedVectorSource = vectorSource
    }

    static func live(reader: IndexReader, modelState: @escaping @Sendable () -> ModelState) -> StatusCache {
        StatusCache(sources: .live(reader: reader, modelState: modelState), vectorSource: LlamaEmbedder.vectorSource)
    }

    /// Called on the cache's queue, once per refresh whose value differs from the stored one.
    var onChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); handler = newValue; lock.unlock() }
    }

    func snapshot() -> PanelSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func refresh() {
        lock.lock()
        if running {
            again = true
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [self] in drain() }
    }

    /// True when the stored snapshot says there is indexing left to do: the walk is not finished, or a row is `pending` or
    /// `partial`. Reads the stored value only, on any thread; `needs_permission` and `done` rows are no work.
    var workRemains: Bool {
        let value = snapshot()
        return !value.walkDone || value.counts.pending.values.contains { $0 > 0 }
            || value.counts.partial.values.contains { $0 > 0 }
    }

    /// Called for every `changed` event of the index helper (the panel's relay calls `helperChanged()` for each), after
    /// the refresh is asked for. Any thread.
    var onHelperChanged: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changedHandler }
        set { lock.lock(); changedHandler = newValue; lock.unlock() }
    }

    func helperChanged() {
        refresh()
        onHelperChanged?()
    }
    func settingsChanged() { refresh() }
    func panelOpened() { refresh() }

    private func drain() {
        while true {
            let value = PanelSnapshot(sources: sources, vectorSource: expectedVectorSource)
            lock.lock()
            let changed = value != stored
            stored = value
            let notify = handler
            lock.unlock()
            if changed { notify?() }
            lock.lock()
            if again {
                again = false
                lock.unlock()
                continue
            }
            running = false
            lock.unlock()
            return
        }
    }
}

/// The model state for a background source: whole is read from the file sizes under `models/`, as `SetupModel.refresh()`
/// reads them. Two flags are set by the app delegate: "damaged" (the watcher deleted a file) and "failed" (a download
/// gave up; `retried()` clears it). A whole model clears both. Not whole, the first that holds wins: failed, then
/// damaged, then downloading.
final class ModelStateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var damaged = false
    private var failed = false
    private let isWhole: @Sendable () -> Bool

    /// `isWhole` is the test seam; the app uses the real check of the files.
    init(isWhole: @escaping @Sendable () -> Bool = { ModelStateSource.isWhole() }) {
        self.isWhole = isWhole
    }

    func markDamaged() {
        lock.lock()
        damaged = true
        lock.unlock()
    }

    /// The download gave up: the state is `failed` until `retried()` or until the model is whole.
    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    /// Retry was pressed: a download is running again.
    func retried() {
        lock.lock()
        failed = false
        lock.unlock()
    }

    func state() -> ModelState {
        if isWhole() {
            lock.lock()
            damaged = false
            failed = false
            lock.unlock()
            return .whole
        }
        lock.lock()
        defer { lock.unlock() }
        if failed { return .failed }
        return damaged ? .damaged : .downloading
    }

    static func isWhole() -> Bool {
        ModelFiles.all.allSatisfy { file in
            let path = SesameFolder.modelsURL.appendingPathComponent(file.name).path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int == file.size
        }
    }
}

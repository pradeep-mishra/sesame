import Foundation
import Observation
import SesameEngine

/// One line of the setup's folder list (design section 3, "Setup, before Start").
struct FolderRow: Equatable, Sendable {
    enum State: Equatable, Sendable { case counting, ready }

    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var ticked: Bool
    /// Kind to files under the folder; an absent kind means none.
    var counts: [String: Int] = [:]
    var estimateText = ""
    var state = State.ready
    /// "not found" for a folder that does not exist, else nil.
    var note: String?
    /// True for a row that was never counted (shown unticked): nothing was looked at in that folder.
    var uncounted = false
}

/// The folder list of the setup (and of Settings): which folders are ticked, how many files of each kind they
/// hold, and how long reading them takes. It only counts: no folder is written with `reading` true and nothing
/// is sent to the helper before Start. Counting runs through the injected `counter`, off the main thread.
@MainActor
@Observable
final class SetupFolders {
    static let readNote = "Photos, PDFs, documents, audio and video are read."
    static let notFoundNote = "not found"
    private static let suggested = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]

    private(set) var rows: [FolderRow] = []

    @ObservationIgnored private let counter: @Sendable ([String]) -> FolderCounts
    @ObservationIgnored private let picker: () -> [URL]
    @ObservationIgnored private let speeds: () -> [String: Double]
    @ObservationIgnored private let kindsOn: () -> [String: Bool]
    @ObservationIgnored private let modelWhole: () -> Bool
    /// The count in flight for each path; an older answer is dropped.
    @ObservationIgnored private var generation: [String: Int] = [:]

    init(
        home: URL,
        counter: @escaping @Sendable ([String]) -> FolderCounts = { FolderCounts.count(folders: $0) },
        picker: @escaping () -> [URL],
        speeds: @escaping () -> [String: Double],
        kindsOn: @escaping () -> [String: Bool],
        modelWhole: @escaping () -> Bool
    ) {
        self.counter = counter
        self.picker = picker
        self.speeds = speeds
        self.kindsOn = kindsOn
        self.modelWhole = modelWhole
        let stored = try? SettingsFile().read()
        // The person's own folders first, as their settings hold them; then the suggestions the settings do not hold, unticked
        // when the settings hold any folder (a first run, with none, shows them ticked).
        let held = stored?.folders ?? []
        for folder in held { add(folder.path, ticked: folder.ticked) }
        for name in Self.suggested { add(home.appendingPathComponent(name).path, ticked: held.isEmpty) }
    }

    // MARK: the estimate lines

    /// "About 5 min in total" for the ticked folders, once the model is whole, a photo speed is known and every ticked
    /// folder is counted; nil before.
    var totalText: String? {
        guard modelWhole(), speeds()["photo"] != nil, !rows.contains(where: { $0.ticked && $0.state == .counting }) else { return nil }
        let result = Estimator.estimate(counts: summaryCounts, speeds: speeds(), kindsOn: kindsOn(), modelWhole: true)
        guard result.seconds > 0, let first = result.text.first else { return nil }
        return first.uppercased() + result.text.dropFirst() + " in total"
    }

    // MARK: the summary

    /// Kind to files over the ticked folders. A folder inside another ticked folder is already part of it, so
    /// each file counts once.
    var summaryCounts: [String: Int] {
        let ticked = rows.filter(\.ticked)
        var sum: [String: Int] = [:]
        for row in ticked {
            let nested = ticked.contains { Self.holds($0.path, row.path) }
            if !nested { sum.merge(row.counts, uniquingKeysWith: +) }
        }
        return sum
    }

    var summaryTotal: Int { summaryCounts.values.reduce(0, +) }

    // MARK: actions

    func setTicked(_ path: String, _ ticked: Bool) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        guard rows[index].note == nil, rows[index].ticked != ticked else { return }
        rows[index].ticked = ticked
        if ticked { count(path) }
    }

    /// "Add folder…": a ticked row for each folder the picker returns, counted at once.
    func addFolder() {
        for url in picker() { add(url.path) }
    }

    /// Recomputes every ready row's estimate from the current speeds, kinds and model state.
    func refreshEstimates() {
        for index in rows.indices where rows[index].state == .ready && rows[index].note == nil {
            rows[index].estimateText = estimate(rows[index].counts, at: rows[index].path)
        }
    }

    // MARK: counting

    /// A ticked row is counted at once; an unticked one is not looked at until it is ticked.
    private func add(_ path: String, ticked: Bool = true) {
        let key = Self.resolved(path)
        guard !rows.contains(where: { Self.resolved($0.path) == key }) else { return }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            rows.append(FolderRow(path: path, ticked: false, note: Self.notFoundNote))
            return
        }
        guard ticked else {
            rows.append(FolderRow(path: path, ticked: false, uncounted: true))
            return
        }
        rows.append(FolderRow(path: path, ticked: true))
        count(path)
    }

    private func count(_ path: String) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        let id = (generation[path] ?? 0) + 1
        generation[path] = id
        rows[index].uncounted = false
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

    private func estimate(_ counts: [String: Int], at path: String) -> String {
        Estimator.estimate(counts: counts, speeds: speeds(), kindsOn: kindsOn(), modelWhole: modelWhole()).text
    }

    /// True when `inner` is a folder under `outer` (a different path).
    private static func holds(_ outer: String, _ inner: String) -> Bool {
        let outer = resolved(outer), inner = resolved(inner)
        return outer != inner && inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/")
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

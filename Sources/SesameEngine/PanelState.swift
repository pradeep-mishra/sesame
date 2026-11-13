import Foundation

/// The model file as the panel sees it. `downloading` is not present or not whole;
/// `damaged` failed its check and is being fetched again; `failed` is not whole and its download gave up, so it waits
/// for Retry in the setup window.
public enum ModelState: Equatable, Sendable {
    case whole, downloading, damaged, failed
}

/// Row counts of the `files` table by status: kind to number of rows. `needsPermission` is the number of files (all
/// kinds) the process may not open; it is none of done, pending or partial and is not part of `total`.
public struct IndexCounts: Equatable, Sendable {
    public let done: Int
    public let pending: [String: Int]
    public let partial: [String: Int]
    public let needsPermission: Int

    public init(done: Int, pending: [String: Int], partial: [String: Int], needsPermission: Int = 0) {
        self.done = done
        self.pending = pending
        self.partial = partial
        self.needsPermission = needsPermission
    }

    var total: Int { done + pending.values.reduce(0, +) + partial.values.reduce(0, +) }
}

/// Everything the panel state depends on.
public struct PanelInputs: Sendable {
    public let model: ModelState
    public let startPressed: Bool
    public let indexDeleted: Bool
    public let walkDoneAt: Date?
    public let counts: IndexCounts
    public let vectorSourceOK: Bool
    public let kindsOn: Set<String>
    public let typed: String
    public let rankedCount: Int?

    public init(
        model: ModelState, startPressed: Bool, indexDeleted: Bool, walkDoneAt: Date?,
        counts: IndexCounts, vectorSourceOK: Bool, kindsOn: Set<String>, typed: String, rankedCount: Int?
    ) {
        self.model = model
        self.startPressed = startPressed
        self.indexDeleted = indexDeleted
        self.walkDoneAt = walkDoneAt
        self.counts = counts
        self.vectorSourceOK = vectorSourceOK
        self.kindsOn = kindsOn
        self.typed = typed
        self.rankedCount = rankedCount
    }
}

public struct NotReadyView: Equatable, Sendable {
    public let heading: String
    public let text: String
    public let note: String?
}

public struct IndexingBanner: Equatable, Sendable {
    public let percent: Int
    public let title: String
    public let missing: String
}

public struct EmptyHint: Equatable, Sendable {
    public let text: String
    public let samples: [String]
}

public struct NoMatches: Equatable, Sendable {
    public let title: String
    public let hint: String
}

/// What the panel shows, the first that applies (design section 3).
public enum PanelState: Equatable, Sendable {
    case notReady(NotReadyView)
    case indexing(IndexingBanner)
    case emptyHint(EmptyHint)
    case noMatches(NoMatches)
    case results

    private static let kindNames: [(kind: String, name: String)] = [
        ("photo", "Photos"), ("pdf", "PDFs"), ("doc", "Documents"),
        ("audio", "Audio"), ("video", "Video"),
    ]

    private static func notReady(_ text: String, note: String? = nil) -> PanelState {
        .notReady(NotReadyView(heading: "Not ready yet", text: text, note: note))
    }

    private static func indexing(percent: Int, kinds: Set<String>) -> PanelState {
        let names = kindNames.filter { kinds.contains($0.kind) }.map(\.name)
        return .indexing(IndexingBanner(
            percent: percent,
            title: "Still indexing (\(percent)%)",
            missing: "May be missing: " + names.joined(separator: ", ")))
    }

    public static func evaluate(_ inputs: PanelInputs) -> PanelState {
        switch inputs.model {
        case .downloading: return notReady("The model is still downloading")
        case .damaged: return notReady("The model file was damaged and is downloading again")
        case .failed: return notReady("The model download failed. Choose Retry model download in the Sesame menu.")
        case .whole: break
        }
        if !inputs.vectorSourceOK {
            return notReady("Nothing is indexed yet", note: "Delete index in Settings to start over")
        }
        if !inputs.startPressed {
            return notReady(inputs.indexDeleted ? "Nothing is indexed yet" : "Indexing has not been started")
        }
        if inputs.walkDoneAt == nil {
            return indexing(percent: 0, kinds: inputs.kindsOn)
        }
        let counts = inputs.counts
        let total = counts.total
        if total == 0 { return notReady("Nothing is indexed yet") }
        let named = Set(kindNames.map(\.kind))
        let unfinished = Set(counts.pending.filter { $0.value > 0 }.keys)
            .union(counts.partial.filter { $0.value > 0 }.keys)
            .intersection(named)
        if !unfinished.isEmpty {
            return indexing(percent: 100 * counts.done / total, kinds: unfinished)
        }

        let trimmed = inputs.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .emptyHint(EmptyHint(
                text: "Describe what you want, or type part of a name or text.",
                samples: [
                    "a dog on the beach",
                    "the clause about pets in the lease",
                    "where they talk about sleep",
                ]))
        }
        if inputs.rankedCount == 0 {
            return .noMatches(NoMatches(
                title: "No matches",
                hint: "Describe what is in the file, or type part of its exact name or text."))
        }
        return .results
    }

    /// The quiet line for files the process may not open; nil when there are none. It never changes the state shown.
    public static func permissionNote(_ inputs: PanelInputs) -> String? {
        let count = inputs.counts.needsPermission
        switch count {
        case ..<1: return nil
        case 1: return "1 file needs permission to be read"
        default: return "\(count) files need permission to be read"
        }
    }

    /// The first 500 characters of what was typed; spaces are kept.
    public static func cut(_ text: String) -> String {
        String(text.prefix(500))
    }
}

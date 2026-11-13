import Foundation
import SesameEngine

/// Why indexing is paused (design section 6). The pause set holds a `Set` of these; `you` and `stalled` are the two a
/// person can undo (Resume): `stalled` means the helper kept dying or idled out with work left.
enum PauseReason: Hashable {
    case you, stalled, cpu, lowPower, battery
}

/// Everything the menu bar's state depends on: the panel's inputs plus the pause set.
struct MenuInputs: Equatable {
    let model: ModelState
    let startPressed: Bool
    let indexDeleted: Bool
    let walkDoneAt: Date?
    let counts: IndexCounts
    let pauseReasons: Set<PauseReason>
}

/// What the menu bar shows, the first that applies (design section 3): the model download failed, the model is not
/// whole, a pause reason holds, Start was pressed and (no walk finished or rows are left), else Ready.
enum MenuState: Equatable {
    case downloading, failed, paused, indexing, ready

    static func evaluate(_ inputs: MenuInputs) -> MenuState {
        if inputs.model == .failed { return .failed }
        if inputs.model != .whole { return .downloading }
        if !inputs.pauseReasons.isEmpty { return .paused }
        let rowsLeft = inputs.counts.pending.merging(inputs.counts.partial, uniquingKeysWith: +)
            .contains { MenuModel.namedKinds.contains($0.key) && $0.value > 0 }
        if inputs.startPressed && (inputs.walkDoneAt == nil || rowsLeft) { return .indexing }
        return .ready
    }
}

enum MenuHeaderDot: Equatable {
    case ready, active, neutral, failed
}

/// The menu's text and enabled flags as plain values, from the state and the cached counts.
struct MenuModel: Equatable {
    let inputs: MenuInputs
    let downloadPercent: Int
    /// Files with status `done`, per kind.
    let doneByKind: [String: Int]
    let speeds: [String: Double]
    let kindsOn: [String: Bool]

    static let namedKinds: Set<String> = ["photo", "pdf", "doc", "audio", "video"]

    var state: MenuState { MenuState.evaluate(inputs) }

    var doneCounts: [String: Int] { doneByKind }

    var statusItemLabel: String {
        switch state {
        case .downloading: return "Sesame: downloading the model, \(clampedDownloadPercent) percent"
        case .failed: return "Sesame: model download failed"
        case .paused: return "Sesame: paused"
        case .indexing: return "Sesame: indexing, \(indexingPercent) percent"
        case .ready: return "Sesame: ready"
        }
    }

    var statusLine: String {
        switch state {
        case .downloading: return "Downloading the model, \(clampedDownloadPercent)%"
        case .failed: return "Model download failed"
        case .paused: return Self.pausedLine(inputs.pauseReasons)
        case .indexing: return "Indexing \(indexingPercent)%"
        case .ready: return inputs.startPressed ? "Ready" : "Indexing has not been started"
        }
    }

    /// "4,520 files left · about 12 min left", only while Indexing and with files left.
    var detailLine: String? {
        guard state == .indexing else { return nil }
        var remaining: [String: Int] = [:]
        for (kind, count) in inputs.counts.pending where Self.namedKinds.contains(kind) { remaining[kind, default: 0] += count }
        for (kind, count) in inputs.counts.partial where Self.namedKinds.contains(kind) { remaining[kind, default: 0] += count }
        let files = remaining.values.reduce(0, +)
        guard files > 0 else { return nil }
        let number = Self.grouped(files)
        var line = files == 1 ? "\(number) file left" : "\(number) files left"
        let time = Estimator.left(remaining: remaining, speeds: speeds, kindsOn: kindsOn)
        if time.seconds > 0 {
            line += " · \(time.text) left"
        } else if time.text == "measuring speed" {
            line += " · \(time.text)"
        }
        return line
    }

    /// The same quiet line as the panel's note; nil when no file needs permission.
    var permissionLine: String? {
        switch inputs.counts.needsPermission {
        case ..<1: return nil
        case 1: return "1 file needs permission to be read"
        case let count: return "\(count) files need permission to be read"
        }
    }

    var headerTitle: String {
        switch state {
        case .ready: return "Ready"
        case .paused: return "Paused"
        default: return statusLine
        }
    }

    var headerDetail: String? {
        switch state {
        case .ready: return inputs.startPressed ? nil : "Indexing has not been started"
        case .indexing: return detailLine
        case .paused: return Self.pausedDetail(inputs.pauseReasons)
        case .downloading, .failed: return nil
        }
    }

    var headerDot: MenuHeaderDot {
        switch state {
        case .ready: return .ready
        case .indexing: return .active
        case .paused, .downloading: return .neutral
        case .failed: return .failed
        }
    }

    var firstActionTitle: String {
        switch state {
        case .paused: return "Resume indexing"
        case .failed: return "Retry model download"
        default: return "Pause indexing"
        }
    }

    var firstActionEnabled: Bool {
        switch state {
        case .indexing, .failed: return true
        case .paused: return inputs.pauseReasons.contains(.you) || inputs.pauseReasons.contains(.stalled)
        case .downloading, .ready: return false
        }
    }

    var resumeAnywayTitle: String? {
        state == .paused && inputs.pauseReasons.contains(.battery) ? "Resume anyway, on battery" : nil
    }

    private var clampedDownloadPercent: Int { min(max(downloadPercent, 0), 100) }

    /// `done` over `done + pending + partial`, rounded down; `needs_permission` is not part of the whole.
    private var indexingPercent: Int {
        let counts = inputs.counts
        let left = counts.pending.merging(counts.partial, uniquingKeysWith: +).filter { Self.namedKinds.contains($0.key) }
        let total = counts.done + left.values.reduce(0, +)
        return total == 0 ? 0 : 100 * counts.done / total
    }

    private static func pausedLine(_ reasons: Set<PauseReason>) -> String {
        if reasons.contains(.you) { return "Paused by you" }
        if reasons.contains(.stalled) { return "Paused: indexing stopped, press Resume to try again" }
        if reasons.contains(.cpu) { return "Paused: the Mac is busy" }
        if reasons.contains(.lowPower) { return "Paused: Low Power Mode is on" }
        return "Paused: on battery"
    }

    private static func pausedDetail(_ reasons: Set<PauseReason>) -> String {
        if reasons.contains(.you) { return "By you" }
        if reasons.contains(.stalled) { return "Indexing stopped, press Resume" }
        if reasons.contains(.cpu) { return "The Mac is busy" }
        if reasons.contains(.lowPower) { return "Low Power Mode is on" }
        return "On battery"
    }

    static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

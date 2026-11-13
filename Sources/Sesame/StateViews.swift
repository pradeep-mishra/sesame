import AppKit
import SesameEngine

// MARK: which screen

/// What the panel shows for the inputs it already has (design section 3, "Panel states"). The texts come from
/// `PanelState` (the one function that decides); this adds the body that goes with a ready panel and the
/// "Still ranking" note.
struct PanelScreen: Equatable {
    enum Body: Equatable {
        case notReady(NotReadyView)
        case emptyHint(EmptyHint)
        case searching
        /// The typed text could not be embedded (the helper refused, timed out or died) and no keyword rows are shown.
        case searchFailed
        case noMatches(NoMatches)
        case rows
    }

    static let searchingText = "Searching"
    static let searchFailedText = "Could not search just now"
    static let searchFailedHint = "Try typing again in a moment."
    static let stillRankingText = "Still ranking"

    /// Shown above the body when the index is still being built; the body is then the one of a ready panel.
    let banner: IndexingBanner?
    let body: Body
    /// "Still ranking" after Enter gave up while text is typed; nothing otherwise.
    let status: String?
    /// "N files need permission to be read" when the index holds files the process may not open; its own quiet line,
    /// apart from `status`.
    let permissionNote: String?

    /// `keywordRows` is how many rows the keyword match of the typed text found (tier 1 only); `inputs.rankedCount`
    /// is nil until the ranked list of the typed text is in. `searchFailed` is true while the newest typed text's embed
    /// has failed; keyword rows already shown stay, and the quiet "Searching" line is not shown.
    static func choose(
        _ inputs: PanelInputs, keywordRows: Int, stillRanking: Bool = false, searchFailed: Bool = false
    ) -> PanelScreen {
        let typed = !inputs.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let status = stillRanking && typed ? stillRankingText : nil
        let note = PanelState.permissionNote(inputs)
        switch PanelState.evaluate(inputs) {
        case let .notReady(view):
            return PanelScreen(banner: nil, body: .notReady(view), status: nil, permissionNote: note)
        case let .indexing(banner):
            let ready = PanelState.evaluate(asReady(inputs))
            return PanelScreen(
                banner: banner, body: body(of: ready, inputs, keywordRows, searchFailed), status: status, permissionNote: note)
        case let state:
            return PanelScreen(
                banner: nil, body: body(of: state, inputs, keywordRows, searchFailed), status: status, permissionNote: note)
        }
    }

    private static func body(of state: PanelState, _ inputs: PanelInputs, _ keywordRows: Int, _ searchFailed: Bool) -> Body {
        switch state {
        case let .emptyHint(hint): return .emptyHint(hint)
        case let .noMatches(none): return .noMatches(none)
        case .notReady, .indexing, .results:
            if keywordRows > 0 || inputs.rankedCount != nil { return .rows }
            return searchFailed ? .searchFailed : .searching
        }
    }

    /// The same inputs with the index counted as done: the banner sits above a panel that stays usable.
    private static func asReady(_ inputs: PanelInputs) -> PanelInputs {
        PanelInputs(
            model: .whole, startPressed: true, indexDeleted: false, walkDoneAt: inputs.walkDoneAt ?? .distantPast,
            counts: IndexCounts(done: 1, pending: [:], partial: [:]), vectorSourceOK: true,
            kindsOn: inputs.kindsOn, typed: inputs.typed, rankedCount: inputs.rankedCount)
    }
}

// MARK: what the panel reads

/// The parts of `PanelInputs` that come from the model files, `settings.json` and the index. Read when the panel
/// opens and then about once a second while it is open, never on a keystroke.
struct PanelSnapshot: Equatable {
    var model: ModelState = .whole
    var startPressed = true
    var indexDeleted = false
    var walkDone = true
    var counts = IndexCounts(done: 1, pending: [:], partial: [:])
    var vectorSourceOK = true
    var kindsOn: Set<String> = ["photo"]
    /// Files with status `done`, per kind, and the path indexed last: the menu's counts and "Last indexed".
    var doneByKind: [String: Int] = [:]
    var lastIndexedPath: String?

    /// Blocks on disk and on the reader: only a background source (`StatusCache`) calls this, never the main thread.
    static func read(reader: IndexReader, model: ModelState) -> PanelSnapshot {
        PanelSnapshot(
            sources: .live(reader: reader, modelState: { model }), vectorSource: LlamaEmbedder.vectorSource)
    }

    func inputs(typed: String, rankedCount: Int?) -> PanelInputs {
        PanelInputs(
            model: model, startPressed: startPressed, indexDeleted: indexDeleted,
            walkDoneAt: walkDone ? .distantPast : nil, counts: counts, vectorSourceOK: vectorSourceOK,
            kindsOn: kindsOn, typed: typed, rankedCount: rankedCount)
    }
}

extension PanelSnapshot {
    /// Reads each source once. `vectorSource` is the value the index must carry; nil skips that comparison.
    init(sources: StatusSources, vectorSource expected: String?) {
        let settings = sources.settings()
        let source = sources.meta("vector_source")
        self.init(
            model: sources.modelState(), startPressed: settings.startPressed, indexDeleted: settings.indexDeleted,
            walkDone: sources.meta("walk_done_at") != nil, counts: sources.counts(),
            vectorSourceOK: expected == nil || source == nil || source == expected,
            kindsOn: Set(["photo", "pdf", "doc", "audio", "video"].filter { settings.kindsOn[$0] != false }),
            doneByKind: sources.doneByKind(), lastIndexedPath: sources.lastIndexedPath())
    }
}

/// Row counts of the index by status, for the "Still indexing (N%)" figure, read through the app's one reader.
/// Only `done`, `pending` and `partial` count toward the percent; a `could_not_read` file is none of them, and a
/// `needs_permission` file is counted on its own.
enum IndexProgress {
    static func counts(reader: IndexReader) -> IndexCounts {
        var done = 0
        var pending: [String: Int] = [:]
        var partial: [String: Int] = [:]
        var needsPermission = 0
        for row in reader.statusCounts() {
            switch row.status {
            case "done": done += row.files
            case "pending": pending[row.kind, default: 0] += row.files
            case "partial": partial[row.kind, default: 0] += row.files
            case "needs_permission": needsPermission += row.files
            default: break
            }
        }
        return IndexCounts(done: done, pending: pending, partial: partial, needsPermission: needsPermission)
    }
}

@MainActor private func makeLabel(font: NSFont, color: NSColor, wrapping: Bool = false) -> NSTextField {
    let label = wrapping ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
    label.font = font
    label.textColor = color
    label.alignment = .center
    return label
}

@MainActor
class FilledView: NSView {
    private let fill: () -> NSColor

    init(radius: CGFloat, fill: @escaping () -> NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        refreshFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        refreshFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }

    private func refreshFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill().cgColor
        }
    }
}

@MainActor
final class NotReadyPanel: NSView {
    private var shown: NotReadyView?
    private var content: StateView?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Not ready")
        setAccessibilityIdentifier("NotReadyView")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: NotReadyView?) {
        if isHidden != (view == nil) { isHidden = view == nil }
        guard let view, view != shown else { return }
        shown = view
        content?.removeFromSuperview()
        let next = StateView(symbol: "hourglass", title: view.heading, body: view.text, caption: view.note)
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: topAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor),
            next.leadingAnchor.constraint(equalTo: leadingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        content = next
    }
}

@MainActor
final class EmptyHintPanel: NSView {
    private static let textWidth: CGFloat = 320
    private static let topShare: CGFloat = 0.38
    private let text = makeLabel(font: Typeface.body, color: Design.secondaryLabel, wrapping: true)
    private let samples = (0..<3).map { _ in makeLabel(font: Typeface.body, color: Design.label) }
    private let chips: [FilledView]

    init() {
        chips = samples.map { sample in
            let chip = FilledView(radius: Radius.chip, fill: { Design.groupFill })
            sample.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(sample)
            NSLayoutConstraint.activate([
                sample.topAnchor.constraint(equalTo: chip.topAnchor, constant: Space.s2),
                sample.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -Space.s2),
                sample.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Space.s4),
                sample.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -Space.s4),
            ])
            return chip
        }
        super.init(frame: .zero)
        text.preferredMaxLayoutWidth = Self.textWidth
        text.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth).isActive = true
        let views: [NSView] = [text] + chips
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Space.s3
        stack.setCustomSpacing(Space.s4, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let top = NSLayoutGuide()
        addLayoutGuide(top)
        addSubview(stack)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.heightAnchor.constraint(equalTo: heightAnchor, multiplier: Self.topShare),
            stack.topAnchor.constraint(equalTo: top.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search hint")
        setAccessibilityIdentifier("EmptyHint")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ hint: EmptyHint?) {
        if isHidden != (hint == nil) { isHidden = hint == nil }
        guard let hint else { return }
        set(text, hint.text)
        for (index, chip) in chips.enumerated() {
            let sample = index < hint.samples.count ? hint.samples[index] : nil
            set(samples[index], sample)
            if chip.isHidden != (sample == nil) { chip.isHidden = sample == nil }
        }
    }
}

@MainActor
final class SearchFailedPanel: NSView {
    init() {
        super.init(frame: .zero)
        let content = StateView.error(title: PanelScreen.searchFailedText, body: PanelScreen.searchFailedHint)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(PanelScreen.searchFailedText)
        setAccessibilityIdentifier("SearchFailedView")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ shown: Bool) {
        if isHidden == shown { isHidden = !shown }
    }
}

@MainActor
final class IndexingBannerPanel: FilledView {
    static let height: CGFloat = 46
    private let title = makeLabel(font: Typeface.groupLabel, color: Design.label)
    private let missing = makeLabel(font: Typeface.secondary, color: Design.secondaryLabel)
    private let bar = NSProgressIndicator()

    init() {
        super.init(radius: 0, fill: { Design.bannerFill })
        title.alignment = .left
        missing.alignment = .left
        missing.lineBreakMode = .byTruncatingTail
        missing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.setAccessibilityElement(false)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [title, missing])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Space.s4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(bar)
        let rowTop = row.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        let barBottom = bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        rowTop.priority = .defaultHigh
        barBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rowTop,
            barBottom,
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Space.s6),
            bar.topAnchor.constraint(greaterThanOrEqualTo: row.bottomAnchor, constant: Space.s2),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s6),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s6),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Indexing progress")
        setAccessibilityIdentifier("IndexingBanner")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ banner: IndexingBanner?) {
        if isHidden != (banner == nil) { isHidden = banner == nil }
        guard let banner else { return }
        set(title, banner.title)
        set(missing, banner.missing)
        if bar.doubleValue != Double(banner.percent) { bar.doubleValue = Double(banner.percent) }
    }
}

@MainActor
class QuietLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

@MainActor
final class StatusNote: QuietLabel {
    init(identifier: String = "StatusNote") {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = Typeface.caption
        textColor = Design.secondaryLabel
        setAccessibilityIdentifier(identifier)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ status: String?) {
        if isHidden != (status == nil) { isHidden = status == nil }
        set(self, status)
        if accessibilityLabel() != status { setAccessibilityLabel(status) }
    }
}

/// Sets a label only when its text changed: a redundant set makes the accessibility tree show a blank line.
@MainActor private func set(_ label: NSTextField, _ text: String?) {
    let value = text ?? ""
    if label.stringValue != value { label.stringValue = value }
    if label.isHidden != (text == nil) { label.isHidden = text == nil }
}

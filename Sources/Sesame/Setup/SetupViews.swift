import AppKit
import SesameEngine

/// Everything the setup window shows, as one value (design section 3, mockup F1): built from the flow's step, the
/// model's state and the folder rows, and holding no view. The window draws it; a test reads it.
struct SetupScreen {
    struct Button: Equatable {
        let title: String
        let isEnabled: Bool
    }

    /// A control a person can reach, with its accessibility label.
    struct Control: Equatable {
        let label: String
        let isEnabled: Bool
    }

    /// One folder line: the tick's name, what a screen reader says for it, and the counts and estimate beside it.
    struct Row: Equatable {
        let path: String
        let name: String
        let ticked: Bool
        let isEnabled: Bool
        let label: String
        let detail: String
        let count: String
        let tooltip: String
    }

    static let welcomeHeading = "Welcome to Sesame"
    static let welcomeNote = "Nothing is read until you press Start indexing."
    static let welcomeSubline = "Search your files by what is inside them."
    static let welcomePromises: [(symbol: String, title: String, detail: String)] = [
        ("doc.text", "Search by meaning", "Type what a photo shows or what a document says."),
        ("lock", "Private by design", "Everything stays on this Mac."),
        ("play.circle", "You choose when", welcomeNote),
    ]
    static let foldersHeading = "Folders to read"
    static let nothingIndexedText = "Nothing will be indexed."
    static let countingText = "Counting files\u{2026}"
    static let permissionsHeading = "Permissions"
    static let permissionsIntro = "macOS asks once, the first time Sesame reads each of these:"
    static let shortcutHeading = "Open Sesame from anywhere"
    static let shortcutLead = "Press these keys together."
    static let shortcutNote = "You can change the shortcut later in Settings."
    static let shortcutRunningLine = "Indexing is running. Watch it from the magnifier in the menu bar."
    static let foldersHint = "Indexing starts when you press Start indexing, and runs in the background."
    static let foldersTickHint = "Tick at least one folder to start."
    static let notNowTitle = "Not now"
    static let modelHeading = "The search model"
    static let modelReadyText = "Search model ready"
    static let modelLabel = "Model download"
    static let nextStepText = "Try again in a moment."
    static let permissionRows: [(name: String, detail: String)] = [
        ("Desktop", "Files on your Desktop"),
        ("Documents", "Files in your Documents folder"),
        ("Downloads", "Files in your Downloads folder"),
        ("Removable volumes", "USB drives and external disks"),
    ]
    static let finishTitle = "Finish"
    static let nextTitle = "Next"
    static let backTitle = "Back"

    let step: SetupFlow.Step
    let stepText: String
    let modelIsWhole: Bool
    let modelProgress: String
    let modelFraction: Double
    let damagedText: String?
    let errorText: String?
    let startErrorText: String?
    let rows: [Row]
    let summary: String
    /// "About 5 min in total"; nil until the model is whole and a speed is known.
    let totalText: String?
    let shortcutText: String
    let hint: String?
    let showsRunningLine: Bool
    let texts: [String]
    let buttons: [Button]
    let controls: [Control]

    @MainActor
    init(flow: SetupFlow, model: SetupModel, folders: SetupFolders) {
        step = flow.step
        stepText = Self.stepText(flow.step)
        modelIsWhole = model.modelIsWhole
        modelProgress = model.progressText
        modelFraction = model.fractionDone
        damagedText = model.damagedText
        errorText = model.errorText
        startErrorText = model.startErrorText
        rows = folders.rows.map { Self.row($0, locked: model.started) }
        summary = Self.summaryText(folders)
        totalText = folders.totalText
        shortcutText = flow.step == .shortcut ? ShortcutControl().displayText : ""

        let startShown = flow.showsStartIndexing && model.canStartIndexing
        let anyTicked = folders.rows.contains(where: \.ticked)
        hint = startShown ? (anyTicked ? Self.foldersHint : Self.foldersTickHint) : nil
        showsRunningLine = flow.step == .shortcut && model.started

        var buttons = [Button(title: Self.backTitle, isEnabled: flow.canGoBack)]
        if flow.canFinish {
            buttons.append(Button(title: Self.finishTitle, isEnabled: true))
        } else if startShown {
            buttons.append(Button(title: SetupModel.startTitle, isEnabled: flow.canGoNext && anyTicked))
        } else {
            buttons.append(Button(title: Self.nextTitle, isEnabled: flow.canGoNext))
        }
        if flow.showsStartIndexing {
            buttons.append(Button(title: SetupModel.addFolderTitle, isEnabled: !model.started))
            if startShown { buttons.append(Button(title: Self.notNowTitle, isEnabled: true)) }
        }
        if model.showsRetry { buttons.append(Button(title: SetupModel.retryTitle, isEnabled: true)) }
        self.buttons = buttons

        var texts = [stepText]
        var controls: [Control] = []
        switch flow.step {
        case .welcome:
            texts += [Self.welcomeHeading, Self.welcomeSubline]
            texts += Self.welcomePromises.flatMap { [$0.title, $0.detail] }
        case .folders:
            texts += [Self.foldersHeading, summary]
            if let totalText { texts.append(totalText) }
            texts += rows.map { $0.count.isEmpty ? $0.name : "\($0.name): \($0.count)" }
            if let hint { texts.append(hint) }
            texts.append(SetupFolders.readNote)
            controls += rows.map { Control(label: $0.label, isEnabled: $0.isEnabled) }
        case .permissions:
            texts += [Self.permissionsHeading, Self.permissionsIntro]
            texts += SetupFlow.permissionFolders
            texts.append(SetupFlow.neverAskedLine)
        case .shortcut:
            texts += [Self.shortcutHeading, Self.shortcutLead, shortcutText, Self.shortcutNote]
            if showsRunningLine { texts.append(Self.shortcutRunningLine) }
        }
        if model.modelIsWhole {
            texts.append(Self.modelReadyText)
        } else {
            texts.append(Self.modelHeading)
            texts.append(model.progressText)
            controls.append(Control(label: Self.modelLabel, isEnabled: true))
        }
        if let damaged = model.damagedText { texts.append(damaged) }
        if let error = model.errorText { texts.append(error) }
        if let startError = model.startErrorText { texts.append(startError) }
        controls += buttons.map { Control(label: $0.title, isEnabled: $0.isEnabled) }
        self.texts = texts
        self.controls = controls
    }

    @MainActor
    static func stepText(_ step: SetupFlow.Step) -> String {
        "Step \(step.rawValue + 1) of \(SetupFlow.steps.count): \(step.title)"
    }

    // MARK: rows

    private static let kindWords: [(kind: String, one: String, many: String)] = [
        ("photo", "photo", "photos"), ("pdf", "PDF", "PDFs"), ("doc", "document", "documents"),
        ("audio", "audio file", "audio files"), ("video", "video", "videos"),
    ]

    /// "100 photos, 3 PDFs"; "no files" when nothing is there.
    static func countsText(_ counts: [String: Int]) -> String {
        let parts = kindWords.compactMap { word -> String? in
            guard let n = counts[word.kind], n > 0 else { return nil }
            return "\(n) \(n == 1 ? word.one : word.many)"
        }
        return parts.isEmpty ? "no files" : parts.joined(separator: ", ")
    }

    /// `locked`: Start was pressed, so the tick is shown but cannot be changed.
    private static func row(_ row: FolderRow, locked: Bool) -> Row {
        let detail: String
        let label: String
        let count: String
        let tooltip: String
        if let note = row.note {
            detail = note
            label = "\(row.name), \(note)"
            count = note
            tooltip = note
        } else if row.uncounted {
            detail = "not counted"
            label = "\(row.name), not counted"
            count = ""
            tooltip = "not counted"
        } else if row.state == .counting {
            detail = "counting\u{2026}"
            label = "\(row.name), counting"
            count = "counting"
            tooltip = "counting"
        } else {
            let counts = countsText(row.counts)
            detail = [counts, row.estimateText].filter { !$0.isEmpty }.joined(separator: ", ")
            label = "\(row.name), \(detail)"
            count = fileCountText(row.counts.values.reduce(0, +))
            tooltip = counts
        }
        return Row(path: row.path, name: row.name, ticked: row.ticked, isEnabled: row.note == nil && !locked, label: label, detail: detail, count: count, tooltip: tooltip)
    }

    static func fileCountText(_ n: Int) -> String {
        var digits = String(n)
        var out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return digits + out
    }

    @MainActor
    private static func summaryText(_ folders: SetupFolders) -> String {
        let ticked = folders.rows.filter(\.ticked)
        if ticked.isEmpty { return nothingIndexedText }
        if ticked.contains(where: { $0.state == .counting }) { return countingText }
        let total = folders.summaryTotal
        let m = ticked.count
        return "\(fileCountText(total)) \(total == 1 ? "file" : "files") in \(m) \(m == 1 ? "folder" : "folders")"
    }
}

/// A button that Tab always reaches while it is enabled. AppKit lets Tab stop on a button only when Full Keyboard Access
/// is on; a disabled one is skipped.
@MainActor
final class SetupButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

/// The download figure, drawn by hand. Measured with the kit's `dump setup`: System Events names a static text by
/// its value and holds each element by that name, so a text that changes (the figure, every second or two) read
/// blank about one dump in six, in SwiftUI and in an NSTextField alike. This view is a group with a fixed title
/// and the figure as its value, so the name never changes.
@MainActor
final class FigureView: NSView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(Typeface.body.boundingRectForFont.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        (text as NSString).draw(in: bounds, withAttributes: [
            .font: Typeface.body, .foregroundColor: Design.label, .paragraphStyle: style,
        ])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityTitle() -> String? { SetupScreen.modelLabel }
    override func accessibilityValue() -> Any? { text }
}

@MainActor
private final class KeycapView: NSView {
    private let face: NSTextField
    private let edge = CALayer()
    private let style: KeycapStyle

    init(face text: String, font: NSFont, style: KeycapStyle) {
        self.style = style
        face = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        face.font = font
        face.textColor = Design.label
        face.alignment = .center
        face.setAccessibilityElement(false)
        wantsLayer = true
        layer?.cornerRadius = style.radius
        layer?.borderWidth = style.border
        addSubview(face)
        edge.borderColor = nil
        layer?.addSublayer(edge)
        refreshColours()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let height = ceil(face.intrinsicContentSize.height)
        face.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let edgeY = layer?.isGeometryFlipped == true ? bounds.height - style.lowerEdge : 0
        edge.frame = CGRect(x: style.radius, y: edgeY, width: max(0, bounds.width - 2 * style.radius), height: style.lowerEdge)
        CATransaction.commit()
        refreshColours()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColours()
    }

    private func refreshColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Design.groupFill.cgColor
            layer?.borderColor = Design.separator.cgColor
            edge.backgroundColor = Design.separator.cgColor
        }
    }
}

@MainActor
final class KeycapRow: NSView {
    private struct Column {
        let key: KeycapView
        let caption: NSTextField?
        let keyWidth: CGFloat
        let width: CGFloat
    }

    private static let symbols = ["Control": "\u{2303}", "Option": "\u{2325}", "Shift": "\u{21E7}", "Command": "\u{2318}"]
    private let style: KeycapStyle
    private var columns: [Column] = []
    private var captionHeight: CGFloat = 0

    init(style: KeycapStyle = .setup) {
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var text = "" {
        didSet { if text != oldValue { rebuild() } }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let widths = columns.map(\.width)
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * style.gap
        let caption = style.captionGap.map { $0 + captionHeight } ?? 0
        return NSSize(width: total, height: columns.isEmpty ? 0 : style.height + caption)
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func rebuild() {
        for column in columns {
            column.key.removeFromSuperview()
            column.caption?.removeFromSuperview()
        }
        let words = text.split(separator: " ").map(String.init)
        let faces = words.map { word -> (text: String, font: NSFont, minimum: CGFloat) in
            let symbol = Self.symbols[word]
            return (symbol ?? word, symbol == nil ? style.wordFont : style.symbolFont, word == "Space" ? style.spaceWidth : style.minWidth)
        }
        func sizes(_ padding: CGFloat) -> [(key: CGFloat, column: CGFloat)] {
            zip(words, faces).map { word, face in
                let key = max(face.minimum, Self.width(face.text, face.font) + 2 * padding)
                return (key, style.captionGap == nil ? key : max(key, Self.width(word, Typeface.caption)))
            }
        }
        var fitted = sizes(style.padding)
        let total = fitted.map(\.column).reduce(0, +) + CGFloat(max(0, words.count - 1)) * style.gap
        if total > style.maxRow { fitted = sizes(style.tightPadding) }
        columns = zip(zip(words, faces), fitted).map { pair, size in
            let key = KeycapView(face: pair.1.text, font: pair.1.font, style: style)
            addSubview(key)
            var caption: NSTextField?
            if style.captionGap != nil {
                let field = NSTextField(labelWithString: pair.0)
                field.font = Typeface.caption
                field.textColor = Design.secondaryLabel
                field.alignment = .center
                field.setAccessibilityElement(false)
                addSubview(field)
                caption = field
            }
            return Column(key: key, caption: caption, keyWidth: size.key, width: size.column)
        }
        captionHeight = style.captionGap == nil ? 0 : ceil(Typeface.caption.boundingRectForFont.height)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for column in columns {
            let inset = ((column.width - column.keyWidth) / 2).rounded()
            column.key.frame = NSRect(x: x + inset, y: 0, width: column.keyWidth, height: style.height)
            if let captionGap = style.captionGap {
                column.caption?.frame = NSRect(x: x, y: style.height + captionGap, width: column.width, height: captionHeight)
            }
            x += column.width + style.gap
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityChildren() -> [Any]? { nil }
}

@MainActor
final class StepDots: NSView {
    private static let diameter: CGFloat = 8
    private static let gap: CGFloat = 8
    private let dots: [NSView]

    var step: SetupFlow.Step {
        didSet { recolour() }
    }

    init(step: SetupFlow.Step) {
        self.step = step
        dots = SetupFlow.steps.map { _ in NSView() }
        super.init(frame: .zero)
        for dot in dots {
            dot.wantsLayer = true
            dot.layer?.cornerRadius = Self.diameter / 2
            addSubview(dot)
        }
        recolour()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(dots.count)
        return NSSize(width: count * Self.diameter + (count - 1) * Self.gap, height: Self.diameter)
    }

    override func layout() {
        super.layout()
        let size = intrinsicContentSize
        let originX = ((bounds.width - size.width) / 2).rounded()
        let originY = ((bounds.height - Self.diameter) / 2).rounded()
        for (index, dot) in dots.enumerated() {
            dot.frame = NSRect(x: originX + CGFloat(index) * (Self.diameter + Self.gap), y: originY, width: Self.diameter, height: Self.diameter)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolour()
    }

    private func recolour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, dot) in dots.enumerated() {
                let color = index == step.rawValue ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
                dot.layer?.backgroundColor = color.cgColor
            }
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityTitle() -> String? { SetupScreen.stepText(step) }
    override func accessibilityChildren() -> [Any]? { nil }
}

import AppKit

@MainActor
final class SettingsPopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

@MainActor
final class WarningLine: NSStackView {
    static let nextStepText = "Try again in a moment."

    private let symbol = WarningSymbolView(pointSize: 16)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let nextStep = NSTextField(wrappingLabelWithString: WarningLine.nextStepText)

    init(width: CGFloat) {
        super.init(frame: .zero)
        let textWidth = width - ceil(symbol.intrinsicContentSize.width) - Space.s3
        message.font = Typeface.body
        message.preferredMaxLayoutWidth = textWidth
        nextStep.font = Typeface.secondary
        nextStep.textColor = Design.secondaryLabel
        nextStep.preferredMaxLayoutWidth = textWidth
        symbol.isEnabled = false

        let column = NSStackView(views: [message, nextStep])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Space.s2

        orientation = .horizontal
        alignment = .top
        spacing = Space.s3
        addArrangedSubview(symbol)
        addArrangedSubview(column)
        for view in [symbol, message, nextStep, self] as [NSView] { view.isHidden = true }
    }

    required init?(coder: NSCoder) {
        fatalError("WarningLine is built in code")
    }

    func show(_ text: String?, color: NSColor, warning: Bool = true) {
        let shown = !(text ?? "").isEmpty
        if message.stringValue != (text ?? "") { message.stringValue = text ?? "" }
        if message.textColor != color { message.textColor = color }
        setHidden(message, !shown)
        setHidden(symbol, !(shown && warning))
        setHidden(nextStep, !(shown && warning))
        setHidden(self, !shown)
    }

    private func setHidden(_ view: NSView, _ hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }
}

extension NSStackView {
    @discardableResult
    func addCard(rows: [NSView], at index: Int? = nil) -> GroupCard {
        let card = GroupCard(rows: rows, style: .settings)
        card.translatesAutoresizingMaskIntoConstraints = false
        if let index { insertArrangedSubview(card, at: index) } else { addArrangedSubview(card) }
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let minimum = card.heightAnchor.constraint(equalToConstant: 0)
        minimum.priority = .defaultLow
        minimum.isActive = true
        return card
    }
}

extension NSTextField {
    static func groupLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Typeface.groupLabel
        field.textColor = Design.label
        return field
    }
}

@MainActor
final class SettingsSearchView: NSStackView {
    private static let width: CGFloat = 500
    private static let labelWidth: CGFloat = 140
    private static let popupWidth: CGFloat = 200

    let shortcutView = ShortcutSettingsView()
    var onPick: (_ kind: String, _ appName: String) -> Void = { _, _ in }

    private(set) var keyViews: [NSView] = []

    private var popups: [String: SettingsPopUp] = [:]
    private var notes: [String: NSTextField] = [:]
    private let errorLine = WarningLine(width: SettingsSearchView.width)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSearchView is built in code")
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = Space.s3

        addArrangedSubview(shortcutView)
        shortcutView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        setCustomSpacing(Space.s6, after: shortcutView)

        addArrangedSubview(NSTextField.groupLabel(SettingsScreen.appsHeading))

        var rows: [NSView] = []
        for (kind, label) in SettingsScreen.appLabels {
            let caption = NSTextField(labelWithString: label)
            caption.font = Typeface.body
            caption.setAccessibilityElement(false)
            caption.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
            let popup = SettingsPopUp(frame: .zero, pullsDown: false)
            popup.identifier = NSUserInterfaceItemIdentifier(kind)
            popup.setAccessibilityLabel(label)
            popup.target = self
            popup.action = #selector(picked(_:))
            popup.widthAnchor.constraint(equalToConstant: Self.popupWidth).isActive = true
            let line = NSStackView(views: [caption, popup])
            line.spacing = 0
            line.alignment = .centerY
            let note = NSTextField(wrappingLabelWithString: "")
            note.font = Typeface.secondary
            note.textColor = Design.secondaryLabel
            note.preferredMaxLayoutWidth = Self.width - 2 * Space.s5
            note.isHidden = true
            let row = NSStackView(views: [line, note])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = Space.s2
            popups[kind] = popup
            notes[kind] = note
            rows.append(row)
        }
        let appsCard = addCard(rows: rows)
        setCustomSpacing(Space.s4, after: appsCard)

        addArrangedSubview(errorLine)
    }

    func render(_ screen: SettingsScreen) {
        shortcutView.render(screen)
        for pick in screen.appPicks {
            guard let popup = popups[pick.kind], let note = notes[pick.kind] else { continue }
            if popup.itemTitles != pick.options {
                popup.removeAllItems()
                popup.addItems(withTitles: pick.options)
            }
            if popup.titleOfSelectedItem != pick.selected { popup.selectItem(withTitle: pick.selected) }
            if popup.isEnabled != pick.control.isEnabled { popup.isEnabled = pick.control.isEnabled }
            setText(note, pick.note ?? "")
            setHidden(note, pick.note == nil)
        }
        errorLine.show(screen.errorText, color: Design.error)

        keyViews = shortcutView.keyViews + SettingsScreen.appLabels.compactMap { popups[$0.kind] } as [NSView]
    }

    private func setText(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    private func setHidden(_ view: NSView, _ hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        guard let kind = sender.identifier?.rawValue, let name = sender.titleOfSelectedItem else { return }
        onPick(kind, name)
    }
}

import AppKit

private final class FlushLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

@MainActor
private final class UnreadableRow: NSView {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        toolTip = text

        let parts = Self.split(text)
        let name = FlushLabel(labelWithString: parts.name)
        name.font = Typeface.settingsName
        name.textColor = Design.label
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.setAccessibilityElement(false)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(name)

        var constraints = [
            name.topAnchor.constraint(equalTo: topAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
        if let reason = parts.reason {
            let field = FlushLabel(labelWithString: reason)
            field.font = Typeface.note
            field.textColor = Design.secondaryLabel
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setAccessibilityElement(false)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(field)
            constraints += [
                field.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Space.s1),
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(name.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    private static func split(_ text: String) -> (name: String, reason: String?) {
        guard let separator = text.range(of: ", ", options: .backwards) else { return (text, nil) }
        let reason = String(text[separator.upperBound...])
        guard !reason.isEmpty else { return (text, nil) }
        return (String(text[..<separator.lowerBound]), reason.prefix(1).uppercased() + reason.dropFirst())
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityChildren() -> [Any]? { [] }
}

@MainActor
final class SettingsIndexingView: NSStackView {
    private static let width: CGFloat = 500
    private static let listLimit = 100

    var onStart: () -> Void = {}
    var onLogin: (Bool) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}

    private(set) var keyViews: [NSView] = []

    private let startButton = SetupButton(title: SetupModel.startTitle, target: nil, action: nil)
    private let loginSwitch = KindSwitch()
    private let loginName = FlushLabel(labelWithString: SettingsScreen.loginTitle)
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    private let loginLine = WarningLine(width: SettingsIndexingView.width - 2 * Space.s5)
    private let deleteButton = SetupButton(title: SettingsScreen.deleteTitle, target: nil, action: nil)
    private var confirmCard: GroupCard?
    private let confirmLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = SetupButton(title: SettingsScreen.cancelTitle, target: nil, action: nil)
    private let confirmButton = SetupButton(title: SettingsScreen.deleteConfirmTitle, target: nil, action: nil)
    private var listCard: GroupCard?
    private let errorLine = WarningLine(width: SettingsIndexingView.width)
    private var shownRows: [String]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsIndexingView is built in code")
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = Space.s3

        startButton.bezelColor = Design.accent

        deleteButton.cell = QuietTitleCell(textCell: SettingsScreen.deleteTitle)
        deleteButton.isBordered = false
        deleteButton.alignment = .left
        deleteButton.attributedTitle = NSAttributedString(string: SettingsScreen.deleteTitle, attributes: [
            .font: Typeface.body,
            .foregroundColor: Design.error,
        ])

        for (button, action) in [(startButton, #selector(startPressed)), (deleteButton, #selector(deletePressed)),
                                 (cancelButton, #selector(cancelPressed)), (confirmButton, #selector(confirmPressed))] {
            button.target = self
            button.action = action
            if button !== deleteButton { button.bezelStyle = .rounded }
            button.setAccessibilityLabel(button.title)
        }

        loginSwitch.target = self
        loginSwitch.action = #selector(loginPressed(_:))
        loginSwitch.translatesAutoresizingMaskIntoConstraints = false
        loginSwitch.setAccessibilityLabel(SettingsScreen.loginTitle)

        loginName.font = Typeface.settingsName
        loginName.textColor = Design.label
        loginName.setAccessibilityElement(false)
        loginNote.font = Typeface.note
        loginNote.textColor = Design.secondaryLabel
        loginNote.preferredMaxLayoutWidth = Self.width - 2 * SettingsShell.cardPadding - Space.s4
            - ceil(loginSwitch.intrinsicContentSize.width)

        let controls = addCard(rows: [makeLoginRow()])
        setCustomSpacing(Space.s5, after: controls)

        let actions = addCard(rows: [leadingRow(startButton), leadingRow(deleteButton)])
        setCustomSpacing(Space.s5, after: actions)

        let confirm = makeConfirmCard()
        confirm.isHidden = true
        confirmCard = confirm
        setCustomSpacing(Space.s5, after: confirm)

        addArrangedSubview(NSTextField.groupLabel(SettingsScreen.unreadableHeading))
        addArrangedSubview(errorLine)
    }

    private func makeLoginRow() -> NSView {
        let block = NSStackView(views: [loginName, loginNote])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = Space.s1

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = Space.s4
        top.setViews([block], in: .leading)
        top.setViews([loginSwitch], in: .trailing)

        let row = NSStackView(views: [top, loginLine])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Space.s2
        top.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    private func leadingRow(_ button: NSButton) -> NSView {
        let row = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func makeConfirmCard() -> GroupCard {
        confirmLabel.font = Typeface.body
        confirmLabel.textColor = Design.label
        confirmLabel.preferredMaxLayoutWidth = Self.width - 2 * Space.s5
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [cancelButton, confirmButton] { button.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        let buttons = NSStackView(views: [cancelButton, spacer, confirmButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        let content = NSStackView(views: [confirmLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Space.s3
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return addCard(rows: [content])
    }

    func render(_ screen: SettingsScreen) {
        if let start = screen.startControl { apply(start, to: startButton) }
        if let login = screen.loginControl { applyLogin(login) }
        setText(loginNote, LoginItem.note)
        loginLine.show(screen.loginMessage, color: Design.error)
        if let delete = screen.deleteControl { apply(delete, to: deleteButton) }

        if let confirm = screen.confirm {
            setText(confirmLabel, confirm.message)
            if confirmButton.title != confirm.confirmTitle {
                confirmButton.title = confirm.confirmTitle
                confirmButton.setAccessibilityLabel(confirm.confirmTitle)
            }
            if cancelButton.title != confirm.cancelTitle {
                cancelButton.title = confirm.cancelTitle
                cancelButton.setAccessibilityLabel(confirm.cancelTitle)
            }
        }
        if let confirmCard { setHidden(confirmCard, screen.confirm == nil) }

        if let list = screen.unreadable { renderList(list.emptyText.map { [$0] } ?? list.rows, empty: list.emptyText != nil) }
        errorLine.show(screen.errorText, color: Design.error)

        keyViews = [loginSwitch, startButton, deleteButton]
        if screen.confirm != nil { keyViews += [cancelButton, confirmButton] }
    }

    private func renderList(_ lines: [String], empty: Bool) {
        guard shownRows != lines else { return }
        shownRows = lines
        if let old = listCard {
            removeArrangedSubview(old)
            old.removeFromSuperview()
            listCard = nil
        }
        let shown = Array(lines.prefix(Self.listLimit))
        var rows: [NSView] = shown.map { line in
            if empty { return Self.textRow(line, font: Typeface.body) }
            return UnreadableRow(text: line)
        }
        if lines.count > Self.listLimit {
            rows.append(Self.textRow("and \(lines.count - Self.listLimit) more", font: Typeface.note))
        }
        guard !rows.isEmpty, let errorIndex = arrangedSubviews.firstIndex(of: errorLine) else { return }
        listCard = addCard(rows: rows, at: errorIndex)
    }

    private static func textRow(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byTruncatingMiddle
        field.textColor = Design.secondaryLabel
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func apply(_ control: SettingsScreen.Control, to button: SetupButton) {
        if button.isEnabled != control.isEnabled { button.isEnabled = control.isEnabled }
        if button.accessibilityLabel() != control.label { button.setAccessibilityLabel(control.label) }
    }

    private func applyLogin(_ control: SettingsScreen.Control) {
        if control.isOn != nil {
            let state: NSControl.StateValue = control.isOn == true ? .on : .off
            if loginSwitch.state != state { loginSwitch.state = state }
        }
        if loginSwitch.isEnabled != control.isEnabled { loginSwitch.isEnabled = control.isEnabled }
        if loginSwitch.accessibilityLabel() != control.label { loginSwitch.setAccessibilityLabel(control.label) }
    }

    private func setText(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    private func setHidden(_ view: NSView, _ hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }

    @objc private func startPressed() { onStart() }

    @objc private func loginPressed(_ sender: NSSwitch) { onLogin(sender.state == .on) }

    @objc private func deletePressed() { onDelete() }

    @objc private func cancelPressed() { onCancel() }

    @objc private func confirmPressed() { onConfirm() }
}

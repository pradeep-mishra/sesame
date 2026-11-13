import AppKit

private final class FlushLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

private final class OwnTitleCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        title.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return frame
    }
}

private final class MoreBacking: NSView {
    init(button: NSView) {
        let size = SettingsShell.moreButton
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = size / 2
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        addSubview(button)
        refreshColours()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        refreshColours()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColours()
    }

    private func refreshColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Design.moreFill.cgColor
        }
    }
}

@MainActor
final class SettingsFoldersView: NSStackView {
    private static let width: CGFloat = 500
    private static let noteInset: CGFloat = 4

    var onTick: (String, Bool) -> Void = { _, _ in }
    var onReindex: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onCancel: () -> Void = {}
    var onConfirm: (String) -> Void = { _ in }

    private(set) var keyViews: [NSView] = []

    private final class RowViews {
        let row: NSView
        let tick: SetupButton
        let detail: NSTextField
        let more: SettingsPopUp
        let reindex: NSMenuItem
        let remove: NSMenuItem
        var shownName: String?
        var shownOn: Bool?

        init(row: NSView, tick: SetupButton, detail: NSTextField, more: SettingsPopUp, reindex: NSMenuItem, remove: NSMenuItem) {
            self.row = row
            self.tick = tick
            self.detail = detail
            self.more = more
            self.reindex = reindex
            self.remove = remove
        }
    }

    private var rowViews: [String: RowViews] = [:]
    private var shownPaths: [String] = []
    private var confirmPath: String?
    private var listCard: GroupCard?

    private let titleLabel = SettingsFoldersView.titleField(SettingsScreen.foldersSectionTitle)
    private let emptyLabel = SettingsFoldersView.wrapping(SettingsScreen.noFoldersText, color: Design.secondaryLabel, width: SettingsFoldersView.width)
    private let addButton = SetupButton(title: SetupModel.addFolderTitle, target: nil, action: nil)
    private lazy var addCard = makeAddCard()
    private let noteLabel = SettingsFoldersView.wrapping(
        SettingsScreen.foldersNote, color: Design.secondaryLabel, width: SettingsFoldersView.width - SettingsFoldersView.noteInset, font: Typeface.note)
    private lazy var noteRow = makeNoteRow()
    private lazy var confirmCard = makeConfirmCard()
    private let confirmLabel = SettingsFoldersView.wrapping("", color: Design.label, width: SettingsFoldersView.width)
    private let cancelButton = SetupButton(title: SettingsScreen.cancelTitle, target: nil, action: nil)
    private let confirmButton = SetupButton(title: SettingsScreen.removeConfirmTitle, target: nil, action: nil)
    private let errorLine = WarningLine(width: SettingsFoldersView.width)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsFoldersView is built in code")
    }

    private static func wrapping(_ text: String, color: NSColor, width: CGFloat, font: NSFont = Typeface.body) -> NSTextField {
        let field = FlushLabel(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        return field
    }

    private static func titleField(_ text: String) -> NSTextField {
        let field = FlushLabel(labelWithString: text)
        field.font = Typeface.groupLabel
        field.textColor = Design.label
        return field
    }

    private static func shrink(_ card: GroupCard) {
        let minimum = card.heightAnchor.constraint(equalToConstant: 0)
        minimum.priority = .defaultLow
        minimum.isActive = true
    }

    private func makeAddCard() -> GroupCard {
        let card = GroupCard(rows: [addButton], style: .settings)
        Self.shrink(card)
        return card
    }

    private func makeNoteRow() -> NSStackView {
        let row = NSStackView(views: [noteLabel])
        row.orientation = .vertical
        row.alignment = .leading
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.noteInset, bottom: 0, right: 0)
        return row
    }

    private func makeConfirmCard() -> GroupCard {
        confirmLabel.preferredMaxLayoutWidth = Self.width - 2 * SettingsShell.cardPadding
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
        let card = GroupCard(rows: [content], style: .settings)
        Self.shrink(card)
        return card
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = Space.s4

        addButton.cell = OwnTitleCell(textCell: SetupModel.addFolderTitle)
        for (button, action) in [(addButton, #selector(addPressed)), (cancelButton, #selector(cancelPressed)),
                                 (confirmButton, #selector(confirmPressed))] {
            button.target = self
            button.action = action
            button.setAccessibilityLabel(button.title)
        }
        for button in [cancelButton, confirmButton] { button.bezelStyle = .rounded }
        addButton.isBordered = false
        addButton.alignment = .left
        addButton.attributedTitle = NSAttributedString(string: addButton.title, attributes: [
            .font: Typeface.body,
            .foregroundColor: Design.secondaryLabel,
        ])

        for card in [addCard, confirmCard] { card.translatesAutoresizingMaskIntoConstraints = false }
        confirmCard.isHidden = true

        for view in [titleLabel, emptyLabel, addCard, noteRow, confirmCard, errorLine] { addArrangedSubview(view) }
        for view in [titleLabel, emptyLabel, addCard] { setCustomSpacing(Space.s3, after: view) }
        addCard.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        confirmCard.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func render(_ screen: SettingsScreen) {
        let rows = screen.folderRows
        for row in rows { update(row) }
        let paths = rows.map(\.path)
        if paths != shownPaths {
            shownPaths = paths
            rowViews = rowViews.filter { paths.contains($0.key) }
            rebuildList(paths)
        }
        setHidden(emptyLabel, !rows.isEmpty)

        let confirmWasShown = !confirmCard.isHidden
        confirmPath = screen.confirm?.path
        if let confirm = screen.confirm {
            cancelButton.setAccessibilityHelp(confirm.path)
            confirmButton.setAccessibilityHelp(confirm.path)
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
        setHidden(confirmCard, screen.confirm == nil)
        if screen.confirm != nil, !confirmWasShown {
            window?.contentView?.layoutSubtreeIfNeeded()
            confirmCard.scrollToVisible(confirmCard.bounds)
            window?.makeFirstResponder(cancelButton)
        }
        errorLine.show(screen.errorText, color: Design.error)

        keyViews = rows.compactMap { rowViews[$0.path] }.flatMap { [$0.tick, $0.more] } as [NSView]
        keyViews.append(addButton)
        if screen.confirm != nil { keyViews += [cancelButton, confirmButton] }
    }

    private func rebuildList(_ paths: [String]) {
        if let old = listCard {
            removeArrangedSubview(old)
            old.removeFromSuperview()
            listCard = nil
        }
        let rows = paths.compactMap { rowViews[$0]?.row }
        for row in rows { row.removeFromSuperview() }
        guard !rows.isEmpty else { return }
        let card = GroupCard(rows: rows, style: .settings)
        card.translatesAutoresizingMaskIntoConstraints = false
        insertArrangedSubview(card, at: 2)
        setCustomSpacing(Space.s3, after: card)
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        Self.shrink(card)
        listCard = card
    }

    private func update(_ row: SettingsScreen.FolderRow) {
        let views = rowViews[row.path] ?? makeRow(row.path)
        rowViews[row.path] = views
        let on = row.tick.isOn == true
        if views.shownName != row.name || views.shownOn != on {
            views.shownName = row.name
            views.shownOn = on
            views.tick.attributedTitle = Self.nameTitle(row.name, on: on)
        }
        let state: NSControl.StateValue = on ? .on : .off
        if views.tick.state != state { views.tick.state = state }
        if views.tick.isEnabled != row.tick.isEnabled { views.tick.isEnabled = row.tick.isEnabled }
        if views.tick.accessibilityLabel() != row.tick.label { views.tick.setAccessibilityLabel(row.tick.label) }
        if views.tick.toolTip != row.detail { views.tick.toolTip = row.detail }
        if views.more.isEnabled != row.more.isEnabled { views.more.isEnabled = row.more.isEnabled }
        if views.more.accessibilityLabel() != row.more.label { views.more.setAccessibilityLabel(row.more.label) }
        if views.reindex.isEnabled != row.reindex.isEnabled { views.reindex.isEnabled = row.reindex.isEnabled }
        if views.remove.isEnabled != row.remove.isEnabled { views.remove.isEnabled = row.remove.isEnabled }
        setText(views.detail, row.detail)
    }

    private static func nameTitle(_ name: String, on: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return NSAttributedString(string: name, attributes: [
            .font: Typeface.settingsName,
            .foregroundColor: on ? Design.label : Design.secondaryLabel,
            .paragraphStyle: style,
        ])
    }

    private func makeMenu(path: String) -> (menu: NSMenu, reindex: NSMenuItem, remove: NSMenuItem) {
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let symbol = Design.symbol("ellipsis", pointSize: 11)
        symbol?.isTemplate = true
        face.image = symbol
        face.isHidden = true
        let reindex = NSMenuItem(title: SettingsScreen.reindexLabel, action: #selector(reindexChosen(_:)), keyEquivalent: "")
        let remove = NSMenuItem(title: SettingsScreen.removeLabel, action: #selector(removeChosen(_:)), keyEquivalent: "")
        remove.attributedTitle = NSAttributedString(string: SettingsScreen.removeLabel, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: Design.error,
        ])
        for item in [reindex, remove] {
            item.target = self
            item.representedObject = path
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in [face, reindex, remove] { menu.addItem(item) }
        return (menu, reindex, remove)
    }

    private func makeRow(_ path: String) -> RowViews {
        let tick = SetupButton(title: "", target: self, action: #selector(tickPressed(_:)))
        tick.identifier = NSUserInterfaceItemIdentifier(path)
        tick.setButtonType(.switch)
        tick.font = Typeface.settingsName
        tick.lineBreakMode = .byTruncatingMiddle
        tick.setAccessibilityHelp(path)
        tick.translatesAutoresizingMaskIntoConstraints = false
        tick.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tick.title = "x"
        let titleStart = (tick.cell as? NSButtonCell)?.titleRect(forBounds: NSRect(x: 0, y: 0, width: 200, height: 20)).minX ?? 22

        let more = SettingsPopUp(frame: .zero, pullsDown: true)
        let built = makeMenu(path: path)
        more.menu = built.menu
        more.isBordered = false
        more.imagePosition = .imageOnly
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.contentTintColor = Design.secondaryLabel
        more.setAccessibilityHelp(path)
        let backing = MoreBacking(button: more)

        let detail = FlushLabel(labelWithString: "")
        detail.font = Typeface.note
        detail.textColor = Design.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.setAccessibilityElement(false)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSView()
        for view in [tick, detail, backing] as [NSView] { row.addSubview(view) }
        NSLayoutConstraint.activate([
            tick.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tick.topAnchor.constraint(equalTo: row.topAnchor),
            tick.trailingAnchor.constraint(lessThanOrEqualTo: backing.leadingAnchor, constant: -Space.s3),
            detail.leadingAnchor.constraint(equalTo: tick.leadingAnchor, constant: titleStart - tick.alignmentRectInsets.left),
            detail.topAnchor.constraint(equalTo: tick.bottomAnchor, constant: Space.s1),
            detail.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: backing.leadingAnchor, constant: -Space.s3),
            backing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            backing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return RowViews(row: row, tick: tick, detail: detail, more: more, reindex: built.reindex, remove: built.remove)
    }

    private func setText(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    private func setHidden(_ view: NSView, _ hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }

    @objc private func tickPressed(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onTick(path, sender.state == .on)
    }

    @objc private func reindexChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onReindex(path)
    }

    @objc private func removeChosen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onRemove(path)
    }

    @objc private func addPressed() { onAdd() }

    @objc private func cancelPressed() { onCancel() }

    @objc private func confirmPressed() {
        guard let path = confirmPath else { return }
        onConfirm(path)
    }
}

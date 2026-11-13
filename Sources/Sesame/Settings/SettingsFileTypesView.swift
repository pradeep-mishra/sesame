import AppKit

private final class FlushLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

@MainActor
final class KindSwitch: NSSwitch {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        super.performClick(sender)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        _ = super.accessibilityPerformPress()
        return true
    }
}

@MainActor
final class SettingsFileTypesView: NSStackView {
    private static let width: CGFloat = 500

    var onKind: (String, Bool) -> Void = { _, _ in }

    private(set) var keyViews: [NSView] = []

    private var kindViews: [String: KindSwitch] = [:]
    private let titleLabel = SettingsFileTypesView.titleField(SettingsScreen.fileTypesSectionTitle)
    private let errorLine = WarningLine(width: SettingsFileTypesView.width)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsFileTypesView is built in code")
    }

    private static func titleField(_ text: String) -> NSTextField {
        let field = FlushLabel(labelWithString: text)
        field.font = Typeface.groupLabel
        field.textColor = Design.label
        return field
    }

    private func makeRow(key: String, title: String) -> NSView {
        let name = FlushLabel(labelWithString: title)
        name.font = Typeface.settingsName
        name.textColor = Design.label
        name.setAccessibilityElement(false)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toggle = KindSwitch()
        toggle.target = self
        toggle.action = #selector(kindPressed(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(key)
        toggle.setAccessibilityLabel(title)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        kindViews[key] = toggle

        let row = NSView()
        row.addSubview(name)
        row.addSubview(toggle)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -Space.s3),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toggle.topAnchor.constraint(equalTo: row.topAnchor),
            toggle.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = Space.s4

        let rows = SettingsScreen.kindList.map { makeRow(key: $0.key, title: $0.title) }
        let card = GroupCard(rows: rows, style: .settings)
        card.translatesAutoresizingMaskIntoConstraints = false
        let minimum = card.heightAnchor.constraint(equalToConstant: 0)
        minimum.priority = .defaultLow
        minimum.isActive = true

        addArrangedSubview(titleLabel)
        addArrangedSubview(card)
        addArrangedSubview(errorLine)
        setCustomSpacing(Space.s3, after: titleLabel)
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func render(_ screen: SettingsScreen) {
        for kind in screen.kinds {
            guard let toggle = kindViews[kind.key] else { continue }
            apply(kind.control, to: toggle)
        }
        errorLine.show(screen.errorText, color: Design.error)

        keyViews = SettingsScreen.kindList.compactMap { kindViews[$0.key] } as [NSView]
    }

    private func apply(_ control: SettingsScreen.Control, to toggle: KindSwitch) {
        let state: NSControl.StateValue = control.isOn == true ? .on : .off
        if toggle.state != state { toggle.state = state }
        if toggle.isEnabled != control.isEnabled { toggle.isEnabled = control.isEnabled }
        if toggle.accessibilityLabel() != control.label { toggle.setAccessibilityLabel(control.label) }
    }

    @objc private func kindPressed(_ sender: NSSwitch) {
        guard let key = sender.identifier?.rawValue else { return }
        onKind(key, sender.state == .on)
    }
}

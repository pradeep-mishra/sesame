import AppKit
import Carbon.HIToolbox

final class QuietTitleCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        title.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return frame
    }
}

@MainActor
final class ShortcutSettingsView: NSStackView {
    enum Recorded: Equatable {
        case cancelled
        case combination(String)
        case unnamedKey
    }

    private static let width: CGFloat = 500

    var onStartRecording: () -> Void = {}
    var onRecorded: (Recorded) -> Void = { _ in }
    var onBackToDefault: () -> Void = {}

    private(set) var isRecording = false

    var keyViews: [NSView] { [recordButton, defaultButton] }

    private static let lineInset: CGFloat = 4

    private let nameLabel = NSTextField(labelWithString: SettingsScreen.shortcutRowName)
    private let keycaps = KeycapRow(style: .compact)
    private let statusLine = WarningLine(width: ShortcutSettingsView.width - 2 * Space.s5)
    private let noticeLine = WarningLine(width: ShortcutSettingsView.width - 2 * Space.s5)
    private let recordButton = SetupButton(title: ShortcutControl.recordTitle, target: nil, action: nil)
    private let defaultButton = SetupButton(title: ShortcutControl.backToDefaultTitle, target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutSettingsView is built in code")
    }

    private func build() {
        orientation = .vertical
        alignment = .leading
        spacing = Space.s3

        nameLabel.font = Typeface.settingsName
        nameLabel.textColor = Design.label
        nameLabel.setAccessibilityElement(false)
        keycaps.setContentHuggingPriority(.required, for: .horizontal)
        keycaps.setContentCompressionResistancePriority(.required, for: .horizontal)

        recordButton.target = self
        recordButton.action = #selector(recordPressed)
        recordButton.bezelStyle = .rounded
        recordButton.setAccessibilityLabel(recordButton.title)

        defaultButton.cell = QuietTitleCell(textCell: ShortcutControl.backToDefaultTitle)
        defaultButton.target = self
        defaultButton.action = #selector(defaultPressed)
        defaultButton.setAccessibilityLabel(defaultButton.title)
        defaultButton.isBordered = false
        defaultButton.alignment = .left
        defaultButton.attributedTitle = NSAttributedString(string: defaultButton.title, attributes: [
            .font: Typeface.note,
            .foregroundColor: Design.secondaryLabel,
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.s4
        row.setViews([nameLabel], in: .leading)
        row.setViews([keycaps, recordButton], in: .trailing)

        let lines = NSStackView(views: [defaultButton, statusLine, noticeLine])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Space.s2
        lines.edgeInsets = NSEdgeInsets(top: 0, left: Self.lineInset, bottom: 0, right: 0)

        addArrangedSubview(NSTextField.groupLabel(SettingsScreen.shortcutHeading))
        let card = addCard(rows: [row])
        addArrangedSubview(lines)
        setCustomSpacing(Space.s3 - Space.s1, after: card)
    }

    func render(_ screen: SettingsScreen) {
        keycaps.text = screen.shortcutText ?? ""
        if isRecording {
            statusLine.show("Press the new shortcut, or Esc to cancel.", color: Design.secondaryLabel, warning: false)
        } else {
            statusLine.show(screen.shortcutMessage, color: Design.error)
        }
        noticeLine.show(screen.notice, color: Design.secondaryLabel)
    }

    func stopRecording() {
        isRecording = false
    }

    @objc private func recordPressed() {
        isRecording = true
        onStartRecording()
    }

    @objc private func defaultPressed() {
        isRecording = false
        onBackToDefault()
    }

    func consume(_ event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        isRecording = false
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
            onRecorded(.cancelled)
        } else if let combination = HotKey.combination(keyCode: Int(event.keyCode), modifiers: modifiers) {
            onRecorded(.combination(combination))
        } else {
            onRecorded(.unnamedKey)
        }
        return true
    }
}

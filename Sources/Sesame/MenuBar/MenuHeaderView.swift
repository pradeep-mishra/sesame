import AppKit

final class MenuHeaderView: NSView {
    private let kind: MenuHeaderDot
    private let dot = NSView()

    let label: String

    override var isFlipped: Bool { true }

    init(title: String, detail: String?, dot kind: MenuHeaderDot) {
        self.kind = kind
        label = detail.map { "\(title), \($0)" } ?? title

        let titleField = Self.field(title, font: Typeface.rowName, color: Design.label)
        let detailField = detail.map { Self.field($0, font: Typeface.menuDetail, color: Design.secondaryLabel) }
        let titleHeight = titleField.intrinsicContentSize.height
        var height = MenuHeader.top + titleHeight + MenuHeader.bottom
        if let detailField { height += MenuHeader.lineGap + detailField.intrinsicContentSize.height }

        super.init(frame: NSRect(x: 0, y: 0, width: MenuHeader.width, height: height))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)

        let textX = MenuHeader.padding + MenuHeader.dot + MenuHeader.dotGap
        let textWidth = MenuHeader.width - textX - MenuHeader.padding
        titleField.frame = NSRect(x: textX, y: MenuHeader.top, width: textWidth, height: titleHeight)
        addSubview(titleField)
        if let detailField {
            detailField.frame = NSRect(x: textX, y: MenuHeader.top + titleHeight + MenuHeader.lineGap,
                                       width: textWidth, height: detailField.intrinsicContentSize.height)
            addSubview(detailField)
        }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = MenuHeader.dot / 2
        dot.setAccessibilityElement(false)
        dot.frame = NSRect(x: MenuHeader.padding, y: MenuHeader.top + (titleHeight - MenuHeader.dot) / 2,
                           width: MenuHeader.dot, height: MenuHeader.dot)
        addSubview(dot)
        refreshDot()
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityChildren() -> [Any]? { [] }

    override func layout() {
        super.layout()
        refreshDot()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDot()
    }

    private func refreshDot() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = colour.cgColor
        }
    }

    private var colour: NSColor {
        switch kind {
        case .ready: return Design.statusReady
        case .active: return Design.accent
        case .neutral: return Design.tertiaryLabel
        case .failed: return Design.error
        }
    }

    private static func field(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityElement(false)
        return field
    }
}

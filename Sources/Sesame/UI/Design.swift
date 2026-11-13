import AppKit
import SesameEngine

enum Space {
    static let s1: CGFloat = 2
    static let s2: CGFloat = 4
    static let s3: CGFloat = 8
    static let s4: CGFloat = 12
    static let s5: CGFloat = 16
    static let s6: CGFloat = 20
    static let s7: CGFloat = 24
    static let s8: CGFloat = 32
}

enum Radius {
    static let group: CGFloat = 10
    static let row: CGFloat = 7
    static let chip: CGFloat = 6
    static let card: CGFloat = 12
    static let sidebarRow: CGFloat = 8
}

enum SettingsShell {
    static let inset: CGFloat = 8
    static let sidebarWidth: CGFloat = 180
    static let rowStart: CGFloat = 46
    static let stripHeight: CGFloat = 46
    static let contentMargin: CGFloat = 16
    static let cardPadding: CGFloat = 14
    static let cardRowPadding: CGFloat = 10
    static let hairlineInset: CGFloat = 14
    static let moreButton: CGFloat = 22
    static let iconBox: CGFloat = 22
    static let iconGap: CGFloat = 10
    static let separator: CGFloat = 1
}

enum Typeface {
    static var query: NSFont { .systemFont(ofSize: 22, weight: .regular) }
    static var sectionTitle: NSFont { .systemFont(ofSize: 17, weight: .semibold) }
    static var groupLabel: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var body: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static var rowName: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var secondary: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var caption: NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static var figure: NSFont { .systemFont(ofSize: 22, weight: .semibold) }
    static var heroTitle: NSFont { .systemFont(ofSize: 24, weight: .bold) }
    static var keySymbol: NSFont { .systemFont(ofSize: 20, weight: .regular) }
    static var keyName: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    static var menuDetail: NSFont { .systemFont(ofSize: 11.5, weight: .regular) }
    static var paneTitle: NSFont { .systemFont(ofSize: 15, weight: .bold) }
    static var settingsName: NSFont { .systemFont(ofSize: 12.5, weight: .semibold) }
    static var note: NSFont { .systemFont(ofSize: 11.5, weight: .regular) }
}

enum MenuHeader {
    static let width: CGFloat = 280
    static let padding: CGFloat = 14
    static let top: CGFloat = 8
    static let bottom: CGFloat = 6
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 8
    static let lineGap: CGFloat = 2
}

enum Keycap {
    static let height: CGFloat = 44
    static let minWidth: CGFloat = 44
    static let spaceWidth: CGFloat = 104
    static let radius: CGFloat = 8
    static let border: CGFloat = 1
    static let lowerEdge: CGFloat = 1.5
    static let gap: CGFloat = 8
    static let padding: CGFloat = 12
    static let tightPadding: CGFloat = 4
    static let captionGap: CGFloat = 4
    static let maxRow: CGFloat = 520
}

struct KeycapStyle {
    let height: CGFloat
    let minWidth: CGFloat
    let spaceWidth: CGFloat
    let gap: CGFloat
    let radius: CGFloat
    let border: CGFloat
    let lowerEdge: CGFloat
    let padding: CGFloat
    let tightPadding: CGFloat
    let maxRow: CGFloat
    let captionGap: CGFloat?
    let symbolFont: NSFont
    let wordFont: NSFont

    static var setup: KeycapStyle {
        KeycapStyle(
            height: Keycap.height, minWidth: Keycap.minWidth, spaceWidth: Keycap.spaceWidth, gap: Keycap.gap,
            radius: Keycap.radius, border: Keycap.border, lowerEdge: Keycap.lowerEdge, padding: Keycap.padding,
            tightPadding: Keycap.tightPadding, maxRow: Keycap.maxRow, captionGap: Keycap.captionGap,
            symbolFont: Typeface.keySymbol, wordFont: Typeface.keyName
        )
    }

    static var compact: KeycapStyle {
        KeycapStyle(
            height: 26, minWidth: 26, spaceWidth: 52, gap: 6, radius: 6, border: 0.5, lowerEdge: 1, padding: 8,
            tightPadding: 4, maxRow: 220, captionGap: nil,
            symbolFont: .systemFont(ofSize: 13, weight: .regular), wordFont: .systemFont(ofSize: 12, weight: .medium)
        )
    }
}

enum Design {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var accent: NSColor { .controlAccentColor }
    static var selectedText: NSColor { .alternateSelectedControlTextColor }
    static var selectedSecondaryText: NSColor { NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.82) }
    static var windowBackground: NSColor { .windowBackgroundColor }
    static var controlBackground: NSColor { .controlBackgroundColor }
    static var error: NSColor { .systemRed }
    static var statusReady: NSColor { .systemGreen }
    static var groupFill: NSColor { NSColor.labelColor.withAlphaComponent(0.05) }
    static var bannerFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var cardFill: NSColor {
        dynamic(light: .textBackgroundColor, dark: NSColor.labelColor.withAlphaComponent(0.06))
    }
    static var cardLine: NSColor { .separatorColor }
    static var sidebarFill: NSColor {
        dynamic(light: NSColor.textBackgroundColor.withAlphaComponent(0.55), dark: NSColor.labelColor.withAlphaComponent(0.05))
    }
    static var moreFill: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }
    static var templateInk: NSColor { .black }
    static var matchFill: NSColor { matchColor(alpha: MatchMark.fillAlpha) }

    private static func matchColor(alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: MatchMark.red, green: MatchMark.green, blue: MatchMark.blue, alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func templateInk(alpha: CGFloat) -> NSColor {
        NSColor.black.withAlphaComponent(alpha)
    }

    static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class WarningSymbolView: NSImageView {
    init(pointSize: CGFloat) {
        super.init(frame: .zero)
        image = Design.symbol("exclamationmark.triangle", pointSize: pointSize)
        contentTintColor = Design.error
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Warning")
    }

    required init?(coder: NSCoder) { nil }
}

final class StateView: NSView {
    private static let textWidth: CGFloat = 320
    private static let symbolPointSize: CGFloat = 28
    private static let topShare: CGFloat = 0.38

    convenience init(symbol: String, title: String, body: String, caption: String? = nil) {
        let view = NSImageView()
        view.image = Design.symbol(symbol, pointSize: Self.symbolPointSize)
        view.contentTintColor = Design.secondaryLabel
        view.setAccessibilityElement(false)
        self.init(symbolView: view, title: title, body: body, caption: caption)
    }

    static func error(title: String, body: String, caption: String? = nil) -> StateView {
        StateView(symbolView: WarningSymbolView(pointSize: symbolPointSize), title: title, body: body, caption: caption)
    }

    private init(symbolView: NSImageView, title: String, body: String, caption: String?) {
        super.init(frame: .zero)
        let titleField = Self.label(title, font: Typeface.sectionTitle, color: Design.label)
        let bodyField = Self.label(body, font: Typeface.body, color: Design.secondaryLabel)
        var items: [(NSView, CGFloat)] = [(symbolView, 0), (titleField, Space.s3), (bodyField, Space.s2)]
        if let caption {
            items.append((Self.label(caption, font: Typeface.caption, color: Design.secondaryLabel), Space.s3))
        }
        let top = NSLayoutGuide()
        addLayoutGuide(top)
        var constraints = [
            top.topAnchor.constraint(equalTo: topAnchor),
            top.heightAnchor.constraint(equalTo: heightAnchor, multiplier: Self.topShare),
        ]
        var above = top.bottomAnchor
        for (view, gap) in items {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            constraints.append(view.topAnchor.constraint(equalTo: above, constant: gap))
            constraints.append(view.centerXAnchor.constraint(equalTo: centerXAnchor))
            above = view.bottomAnchor
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.isSelectable = false
        field.preferredMaxLayoutWidth = textWidth
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        return field
    }
}

enum CardStyle {
    case setup
    case settings
}

private extension CardStyle {
    var radius: CGFloat { self == .settings ? Radius.card : Radius.group }
    var border: CGFloat { self == .settings ? 0.5 : 0 }
    var across: CGFloat { self == .settings ? SettingsShell.cardPadding : Space.s5 }
    var down: CGFloat { self == .settings ? SettingsShell.cardRowPadding : Space.s4 }
    var lineStart: CGFloat { self == .settings ? SettingsShell.hairlineInset : Space.s5 }
    var lineEnd: CGFloat { self == .settings ? 0 : Space.s5 }
    var fill: NSColor { self == .settings ? Design.cardFill : Design.groupFill }
}

final class GroupCard: NSView {
    private static let minRowHeight: CGFloat = 40
    private var lines: [NSView] = []
    private let style: CardStyle

    init(rows: [NSView], style: CardStyle = .setup) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style.radius
        layer?.borderWidth = style.border
        var above = topAnchor
        for (index, row) in rows.enumerated() {
            let cell = NSLayoutGuide()
            addLayoutGuide(cell)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            var constraints = [
                cell.topAnchor.constraint(equalTo: above),
                cell.leadingAnchor.constraint(equalTo: leadingAnchor),
                cell.trailingAnchor.constraint(equalTo: trailingAnchor),
                cell.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minRowHeight),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.across),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.across),
                row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                row.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: style.down),
                row.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -style.down),
            ]
            if index < rows.count - 1 {
                let line = NSView()
                line.translatesAutoresizingMaskIntoConstraints = false
                line.wantsLayer = true
                addSubview(line)
                lines.append(line)
                constraints.append(line.topAnchor.constraint(equalTo: cell.bottomAnchor))
                constraints.append(line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.lineStart))
                constraints.append(line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.lineEnd))
                constraints.append(line.heightAnchor.constraint(equalToConstant: 1))
                above = line.bottomAnchor
            } else {
                let pin = cell.bottomAnchor.constraint(equalTo: bottomAnchor)
                pin.priority = .defaultHigh
                constraints.append(pin)
            }
            NSLayoutConstraint.activate(constraints)
        }
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
            layer?.backgroundColor = style.fill.cgColor
            if style == .settings { layer?.borderColor = Design.cardLine.cgColor }
            for line in lines {
                line.layer?.backgroundColor = Design.separator.cgColor
            }
        }
    }
}

private final class SidebarButtonCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: Space.s3, dy: 0))
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        var image = super.imageRect(forBounds: rect)
        image.origin.x = Space.s3 + (SettingsShell.iconBox - image.width) / 2
        return image
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        let left = Space.s3 + SettingsShell.iconBox + SettingsShell.iconGap
        title.size.width = max(0, title.maxX - left)
        title.origin.x = left
        return title
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: 8, yRadius: 8).fill()
    }
}

final class SidebarButton: NSButton {
    private static let height: CGFloat = 28

    override class var cellClass: AnyClass? {
        get { SidebarButtonCell.self }
        set {}
    }

    var isSelected = false {
        didSet { refresh() }
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        alignment = .left
        imagePosition = .imageLeading
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .regular).applying(.preferringMonochrome()))
        self.title = title
        wantsLayer = true
        layer?.cornerRadius = Radius.sidebarRow
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        state = isSelected ? .on : .off
        contentTintColor = isSelected ? Design.selectedText : nil
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Typeface.body,
            .foregroundColor: isSelected ? Design.selectedText : Design.label,
        ])
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? Design.accent.cgColor : nil
        }
    }
}

enum Hero {
    static let glyph: CGFloat = 56
    static let promiseGlyph: CGFloat = 17
    static let statusGlyph: CGFloat = 14
    static let column: CGFloat = 360
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 8
}

enum Glass {
    static var isAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    @MainActor
    static func backdrop(enabled: Bool) -> NSView? {
        guard enabled else { return nil }
        if #available(macOS 26, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.setAccessibilityElement(false)
            return view
        }
        return nil
    }

    @MainActor
    static func panel(enabled: Bool, cornerRadius: CGFloat) -> NSView? {
        guard enabled else { return nil }
        if #available(macOS 26, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = cornerRadius
            view.setAccessibilityElement(false)
            return view
        }
        return nil
    }

    @MainActor
    static func style(_ button: NSButton, accent: Bool, glass: Bool) {
        if glass {
            if #available(macOS 26, *) {
                button.bezelStyle = .glass
                button.bezelColor = accent ? Design.accent : nil
                return
            }
        }
        button.bezelStyle = .rounded
        button.bezelColor = nil
    }
}

final class SidebarPanel: NSView {
    private let isFlat: Bool

    init(glass: Bool) {
        let backdrop = Glass.panel(enabled: glass, cornerRadius: 0)
        isFlat = backdrop == nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        if let backdrop {
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            addSubview(backdrop)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            wantsLayer = true
            refreshColours()
        }
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
        guard isFlat, let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Design.sidebarFill.cgColor
        }
    }
}

final class PaneHairline: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
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
            layer?.backgroundColor = Design.separator.cgColor
        }
    }
}

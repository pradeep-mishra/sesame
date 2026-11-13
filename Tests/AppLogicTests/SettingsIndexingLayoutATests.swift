import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let saStart = "Start indexing"
private let saLogin = "Launch at login"
private let saLoginNote = "The shortcut works only while Sesame is running."
private let saLoginFailure = "Could not change Launch at login."
private let saDelete = "Delete index\u{2026}"
private let saDeleteConfirm = "Delete index"
private let saDeleteMessage = "Delete the index? Sesame forgets what it has read and starts again when you press Start indexing. Your files and folders are not touched."
private let saDeleteFailure = "Could not delete the index."
private let saListTitle = "Files Sesame could not read"
private let saEmpty = "Nothing here. Files Sesame could not read are listed here."
private let saSidebar = ["Folders", "File types", "Search", "Indexing"]

private final class SACount: NSObject, @unchecked Sendable {
    private let real: AnyObject
    private let action: Selector
    private(set) var calls = 0

    init(real: AnyObject, action: Selector) {
        self.real = real
        self.action = action
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        aSelector == action || super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == action {
            calls += 1
            return real
        }
        return super.forwardingTarget(for: aSelector)
    }
}

private final class SACounter: @unchecked Sendable {
    var starts = 0
    var deletes = 0
}

@MainActor
private func saWith(
    glass: Bool,
    deleteFails: Bool = false,
    _ body: @MainActor (SettingsContainerWindow, SYLoginService) async throws -> Void
) async throws {
    let login = SYLoginService()
    try await sxWithWindow([], make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: login),
            appChoices: AppChoices(lookup: SYLookup(installed: [])),
            deleteIndex: DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: { if deleteFails { throw SYRefused() } }),
            glass: glass)
    }) { window, _ in try await body(window, login) }
}

@MainActor
private func saIndexing(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, SettingsIndexingView) {
    let root = sxLayout(window, .indexing, look)
    return (root, try #require(syIndexingSection(root), "no Indexing section view"))
}

@MainActor
private func saRelayout(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, SettingsIndexingView) {
    let root = sxRelayout(window, look)
    return (root, try #require(syIndexingSection(root), "no Indexing section view"))
}

@MainActor
private func saCards(_ root: NSView, _ section: NSView) -> [GroupCard] {
    sxVisibleCards(section).sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func saSwitches(_ section: NSView) -> [NSSwitch] {
    prViews(section).compactMap { $0 as? NSSwitch }.filter { plVisible($0) }
}

@MainActor
private func saLoginSwitch(_ section: NSView) -> NSSwitch? {
    saSwitches(section).first { ($0.accessibilityLabel() ?? "") == saLogin }
}

@MainActor
private func saValue(_ control: NSControl) -> Int? {
    ((control as NSAccessibilityProtocol).accessibilityValue() as? NSNumber)?.intValue
}

private func saMid(_ box: PLBox) -> CGFloat {
    (box.top + box.bottom) / 2
}

@MainActor
private func saField(_ section: NSView, _ text: String) -> NSTextField? {
    let fields = plTexts(section).filter { $0.stringValue == text }
    return fields.count == 1 ? fields.first : nil
}

@MainActor
private func saHairlines(_ root: NSView, _ card: GroupCard) -> [NSView] {
    let width = plBox(root, card).width
    return prViews(card)
        .filter { $0 !== card && plVisible($0) && $0.frame.height > 0 && $0.frame.height <= 1.01 && $0.frame.width >= width - 14 - 0.5 }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func saExpectSettingsCard(_ root: NSView, _ card: GroupCard, _ look: DTLook, _ tag: String) {
    #expect(card.layer?.cornerRadius == 12, "\(look) \(tag): radius \(String(describing: card.layer?.cornerRadius))")
    #expect(abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look) \(tag): border width \(String(describing: card.layer?.borderWidth))")
    let border = dtRGBA(cgColor: card.layer?.borderColor)
    #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "\(look) \(tag): border \(String(describing: border))")
    let box = plBox(root, card)
    #expect(abs(box.minX - 197) <= 1 && abs(box.maxX - 704) <= 1, "\(look) \(tag): the card spans \(box.minX) to \(box.maxX)")
}

@MainActor
private func saExpectHairline(_ root: NSView, _ line: NSView, in card: GroupCard, _ look: DTLook, _ tag: String) {
    let cardBox = plBox(root, card)
    let box = plBox(root, line)
    #expect(abs(line.frame.height - 1) <= 0.01, "\(look) \(tag): the hairline is \(line.frame.height) tall")
    #expect(abs((box.minX - cardBox.minX) - 14) <= 1, "\(look) \(tag): the hairline starts \(box.minX - cardBox.minX) in from the card's left edge")
    #expect(abs(cardBox.maxX - box.maxX) <= 1, "\(look) \(tag): the hairline ends \(cardBox.maxX - box.maxX) from the card's right edge")
    let fill = dtRGBA(cgColor: line.layer?.backgroundColor)
    #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.separatorColor, look)), "\(look) \(tag): the hairline colour \(String(describing: fill))")
}

@MainActor
private func saTitleLeft(_ root: NSView, _ button: NSButton) -> CGFloat? {
    guard let cell = button.cell as? NSButtonCell else { return nil }
    let rect = cell.titleRect(forBounds: button.bounds)
    let width = button.attributedTitle.size().width
    let offset: CGFloat
    switch button.alignment {
    case .left, .natural: offset = rect.minX
    case .right: offset = rect.maxX - width
    default: offset = rect.midX - width / 2
    }
    return plBox(root, button).minX + offset
}

@MainActor
private func saTitleFont(_ button: NSButton) -> NSFont? {
    let text = button.attributedTitle
    if text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return font }
    return button.font
}

@MainActor
private func saPress(_ control: NSSwitch, accessibility: Bool) async -> (calls: Int, handled: Bool?) {
    guard let real = control.target, let action = control.action else {
        Issue.record("the switch has no target or no action")
        return (0, nil)
    }
    let counter = SACount(real: real, action: action)
    control.target = counter
    defer { control.target = real }
    var handled: Bool?
    if accessibility {
        handled = control.accessibilityPerformPress()
    } else {
        control.performClick(nil)
    }
    await Task.yield()
    return (counter.calls, handled)
}

@MainActor
private func saKeyLoop(_ window: NSWindow) -> (names: [String], closed: Bool) {
    guard let start = window.initialFirstResponder else { return ([], false) }
    var views: [NSView] = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, views.count < 100 {
        views.append(current)
        next = current.nextValidKeyView
    }
    return (views.map { $0.accessibilityLabel() ?? "" }, next === start)
}

private func saHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { saHasGradient($0) }
}

@MainActor
private func saExpectPalette(_ section: NSView, redTexts: [String], _ look: DTLook) {
    let allowed: [NSColor] = [.labelColor, .secondaryLabelColor, .systemRed]
    for field in plTexts(section) {
        #expect(allowed.contains { sxColour(field.textColor, is: $0) }, "\(look): \"\(field.stringValue)\" is drawn in \(String(describing: field.textColor))")
        if sxColour(field.textColor, is: .systemRed) {
            #expect(redTexts.contains(field.stringValue), "\(look): \"\(field.stringValue)\" is red")
        }
    }
    for button in sxVisibleButtons(section) {
        let inks = sxInks(button)
        for ink in inks {
            #expect(allowed.contains { sxColour(ink, is: $0) }, "\(look): \(button.title) is inked \(ink)")
        }
        let red = inks.contains { sxColour($0, is: .systemRed) }
        #expect(red == (button.title == saDelete), "\(look): \(button.title) red ink \(red)")
        let accent = sxColour(button.bezelColor, is: .controlAccentColor)
        #expect(accent == (button.title == saStart), "\(look): \(button.title) accent bezel \(accent)")
    }
    let views = prViews(section)
    #expect(!views.contains { $0 is NSVisualEffectView || slIsGlass($0) }, "\(look): an effect or glass view in the section")
    #expect(!views.contains { saHasGradient($0.layer) }, "\(look): a gradient layer in the section")
    let accentRGBA = dtRGBA(.controlAccentColor, look)
    let own = views.filter { view in !(view is NSControl) && !sxAncestors(view).contains { $0 is NSControl } }
    for view in own {
        for cgColor in [view.layer?.backgroundColor, view.layer?.borderColor] {
            let rgba = dtRGBA(cgColor: cgColor)
            #expect(rgba == nil || !dtSame(rgba ?? [], accentRGBA), "\(look): a \(type(of: view)) layer is drawn in the accent colour")
        }
    }
}

@MainActor
private func saPosition(_ root: NSView, _ view: NSView) -> (CGFloat, CGFloat) {
    let box = plBox(root, view)
    return (box.top.rounded(), box.minX)
}

extension ModelDownloadTests {
    @Suite("SettingsIndexingLayoutATests", .serialized)
    struct SettingsIndexingLayoutATests {

        @MainActor
        @Test(arguments: slPaths)
        func theSectionRunsCardOneCardTwoThenTheListTitleAndTheListCardWithTheConfirmBetweenCardTwoAndTheTitleAndTheErrorLineLast(glass: Bool) async throws {
            try await saWith(glass: glass, deleteFails: true) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try saIndexing(window, look)
                    #expect(plVisible(section), "\(look): the section is hidden")
                    syExpectPlainSection(root, section, name: "Indexing", look)
                    let cards = saCards(root, section)
                    #expect(cards.count == 3, "\(look): \(cards.count) visible cards, wanted card one, card two and the list card")
                    guard cards.count == 3 else { continue }
                    for (index, card) in cards.enumerated() {
                        saExpectSettingsCard(root, card, look, "card \(index)")
                        syExpectHugs(root, card, look)
                    }
                    let name = try #require(saField(section, saLogin), "\(look): no single text \"\(saLogin)\": \(plTexts(section).map(\.stringValue))")
                    let start = try #require(sxButtons(section, titled: saStart).first, "\(look): no Start indexing")
                    let delete = try #require(sxButtons(section, titled: saDelete).first, "\(look): no Delete index\u{2026}")
                    let empty = try #require(plText(section, saEmpty), "\(look): no empty text")
                    #expect(sxCard(of: name) === cards[0], "\(look): the Launch at login name is not in the first card")
                    #expect(sxCard(of: start) === cards[1] && sxCard(of: delete) === cards[1], "\(look): Start indexing and Delete index\u{2026} are not both in the second card")
                    #expect(sxCard(of: empty) === cards[2], "\(look): the empty text is not in the third card")

                    let title = try #require(saField(section, saListTitle), "\(look): no single text \"\(saListTitle)\"")
                    #expect(sxFont(title.font, size: 13, weight: .semibold), "\(look): list title font \(String(describing: title.font))")
                    #expect(sxColour(title.textColor, is: .labelColor), "\(look): list title colour")
                    #expect(sxCard(of: title) == nil, "\(look): the list title is inside a card")
                    let titleBox = plBox(root, title)
                    let boxes = cards.map { plBox(root, $0) }
                    #expect(boxes[0].bottom <= boxes[1].top + 0.5, "\(look): card one ends at \(boxes[0].bottom), card two starts at \(boxes[1].top)")
                    #expect(boxes[1].bottom <= titleBox.top + 0.5, "\(look): card two ends at \(boxes[1].bottom), the list title starts at \(titleBox.top)")
                    #expect(titleBox.bottom <= boxes[2].top + 0.5 && boxes[2].top - titleBox.bottom <= 20, "\(look): the list title ends \(boxes[2].top - titleBox.bottom) pt above the list card")
                    #expect(cards.filter { plBox(root, $0).top < titleBox.top }.count == 2, "\(look): not exactly two cards above the list title")
                    let ordered = [boxes[0].top, boxes[1].top, titleBox.top, boxes[2].top]
                    #expect(ordered == ordered.sorted() && Set(ordered).count == 4, "\(look): the tops are not in order \(ordered)")
                }

                var (root, section) = try saIndexing(window)
                try #require(sxButtons(section, titled: saDelete).first).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    (root, section) = try saRelayout(window, look)
                    let cards = saCards(root, section)
                    #expect(cards.count == 4, "\(look): \(cards.count) visible cards with the confirm open")
                    guard cards.count == 4 else { continue }
                    for (index, card) in cards.enumerated() { saExpectSettingsCard(root, card, look, "card \(index) with the confirm") }
                    let message = try #require(plText(section, saDeleteMessage), "\(look): no confirm message")
                    #expect(sxCard(of: message) === cards[2], "\(look): the confirm is not the third card")
                    let delete = try #require(sxButtons(section, titled: saDelete).first)
                    #expect(sxCard(of: delete) === cards[1], "\(look): Delete index\u{2026} left the second card")
                    let title = try #require(saField(section, saListTitle))
                    let titleBox = plBox(root, title)
                    #expect(plBox(root, cards[2]).bottom <= titleBox.top + 0.5, "\(look): the confirm card ends at \(plBox(root, cards[2]).bottom), the list title starts at \(titleBox.top)")
                    #expect(titleBox.bottom <= plBox(root, cards[3]).top + 0.5, "\(look): the list title is not above the list card")
                    #expect(cards.filter { plBox(root, $0).top < titleBox.top }.count == 3, "\(look): not exactly three cards above the list title with the confirm open")
                }

                try #require(sxButtons(section, titled: saDeleteConfirm).first).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    (root, section) = try saRelayout(window, look)
                    let cards = saCards(root, section)
                    let failure = try #require(plText(section, saDeleteFailure), "\(look): no failure line: \(plTexts(section).map(\.stringValue))")
                    #expect(sxCard(of: failure) == nil, "\(look): the failure line is inside a card")
                    let failureBox = plBox(root, failure)
                    let list = try #require(plText(section, saEmpty).flatMap { sxCard(of: $0) }, "\(look): no list card")
                    #expect(failureBox.top >= plBox(root, list).bottom - 0.5, "\(look): the failure line starts at \(failureBox.top), the list card ends at \(plBox(root, list).bottom)")
                    #expect(cards.allSatisfy { plBox(root, $0).bottom <= failureBox.top + 0.5 }, "\(look): a card ends under the failure line")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func cardOneIsOneRowWithTheNameAndItsCaptionAtTheLeftAndOneSystemSwitchAtTheRight(glass: Bool) async throws {
            let reference = NSSwitch().intrinsicContentSize
            try await saWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try saIndexing(window, look)
                    let cards = saCards(root, section)
                    guard let card = cards.first else {
                        Issue.record("\(look): no visible card")
                        continue
                    }
                    let cardBox = plBox(root, card)
                    let switches = saSwitches(section)
                    #expect(switches.count == 1, "\(look): \(switches.count) NSSwitch in the section")
                    let named = prViews(section).compactMap { $0 as? NSButton }.filter { $0.title == saLogin || $0.accessibilityLabel() == saLogin }
                    #expect(named.isEmpty, "\(look): an NSButton for Launch at login: \(named.map { String(describing: type(of: $0)) })")
                    let control = try #require(saLoginSwitch(section), "\(look): no switch labelled \"\(saLogin)\"")
                    #expect(sxCard(of: control) === card, "\(look): the switch is not in card one")
                    #expect(control.controlSize == .regular, "\(look): control size \(control.controlSize.rawValue)")
                    let box = plBox(root, control)
                    #expect(abs(box.width - reference.width) <= 0.5 && abs(box.height - reference.height) <= 0.5, "\(look): the switch is \(box.width) x \(box.height), a system switch is \(reference.width) x \(reference.height)")
                    #expect(abs((cardBox.maxX - box.maxX) - 14) <= 1, "\(look): the switch ends \(cardBox.maxX - box.maxX) from the card's right edge")

                    let name = try #require(saField(section, saLogin), "\(look): no single text \"\(saLogin)\": \(plTexts(section).map(\.stringValue))")
                    let caption = try #require(saField(section, saLoginNote), "\(look): no caption: \(plTexts(section).map(\.stringValue))")
                    #expect(sxCard(of: name) === card && sxCard(of: caption) === card, "\(look): the name or the caption is not in card one")
                    #expect(sxFont(name.font, size: 12.5, weight: .semibold), "\(look): name font \(String(describing: name.font))")
                    #expect(sxColour(name.textColor, is: .labelColor), "\(look): name colour")
                    #expect(!name.isAccessibilityElement(), "\(look): the name is an accessibility element")
                    #expect(sxFont(caption.font, size: 11.5, weight: .regular), "\(look): caption font \(String(describing: caption.font))")
                    #expect(sxColour(caption.textColor, is: .secondaryLabelColor), "\(look): caption colour")

                    let nameBox = sxAlignBox(root, name)
                    let captionBox = sxAlignBox(root, caption)
                    #expect(abs((nameBox.minX - cardBox.minX) - 14) <= 1, "\(look): the name starts \(nameBox.minX - cardBox.minX) in from the card's left edge")
                    #expect(abs(captionBox.minX - nameBox.minX) <= 0.5, "\(look): the caption starts at \(captionBox.minX), the name at \(nameBox.minX)")
                    #expect(captionBox.top - nameBox.bottom >= 1 - 0.5 && captionBox.top - nameBox.bottom <= 4 + 0.5, "\(look): the caption starts \(captionBox.top - nameBox.bottom) pt under the name")

                    let block = nameBox.union(captionBox)
                    let rowMid = saMid(cardBox)
                    #expect(abs(saMid(block) - rowMid) <= 1.5, "\(look): the name and caption centre is \(saMid(block)), the row's \(rowMid)")
                    #expect(abs(saMid(box) - rowMid) <= 1.5, "\(look): the switch centre is \(saMid(box)), the row's \(rowMid)")
                    #expect(block.maxX <= box.minX - 12 + 0.5, "\(look): the name and caption end at \(block.maxX), the switch starts at \(box.minX)")
                    #expect(!nameBox.intersects(box) && !captionBox.intersects(box) && !nameBox.intersects(captionBox), "\(look): two parts of the row overlap")
                    #expect(cardBox.height >= 40 - 0.5 && cardBox.height <= 70 + 0.5, "\(look): the row is \(cardBox.height) tall")

                    let texts = plTexts(section).filter { sxCard(of: $0) === card }.sorted { plBox(root, $0).top < plBox(root, $1).top }.map(\.stringValue)
                    #expect(texts == [saLogin, saLoginNote], "\(look): texts in card one \(texts)")
                    let controls = prViews(card).compactMap { $0 as? NSControl }.filter { plVisible($0) && !($0 is NSTextField) }
                    #expect(controls.count == 1 && controls.first === control, "\(look): controls in card one \(controls.map { String(describing: type(of: $0)) })")
                    #expect(saHairlines(root, card).isEmpty, "\(look): a hairline inside card one")
                    #expect(plAccessibilityImages(section).filter { plVisible($0) }.isEmpty, "\(look): a warning symbol with nothing wrong")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKitReadsOneCheckBoxSwitchLabelledLaunchAtLoginWithValueOneThenZeroAndNoOtherSwitchInTheSection(glass: Bool) async throws {
            try await saWith(glass: glass) { window, _ in
                let (_, section) = try saIndexing(window)
                let control = try #require(saLoginSwitch(section), "no switch labelled \"\(saLogin)\": \(saSwitches(section).map { $0.accessibilityLabel() ?? "nil" })")
                #expect(control.accessibilityLabel() == saLogin, "label \(String(describing: control.accessibilityLabel()))")
                #expect(control.isAccessibilityElement(), "the switch is not an accessibility element")
                #expect(control.accessibilityRole()?.rawValue == "AXCheckBox", "role \(String(describing: control.accessibilityRole()?.rawValue))")
                #expect(control.accessibilitySubrole()?.rawValue == "AXSwitch", "subrole \(String(describing: control.accessibilitySubrole()?.rawValue))")
                let title = control.accessibilityTitle() ?? ""
                #expect(title.isEmpty || title == saLogin, "the title \"\(title)\" would be read before the label")
                #expect((control.accessibilityHelp() ?? "").isEmpty, "help \"\(control.accessibilityHelp() ?? "nil")\"")
                #expect(control.isEnabled, "the switch is disabled")
                #expect(control.state == .on && saValue(control) == 1, "state \(control.state.rawValue) value \(String(describing: saValue(control))) with the login item enabled")
                control.state = .off
                #expect(saValue(control) == 0, "value \(String(describing: saValue(control))) while off")
                control.state = .on
                #expect(saValue(control) == 1, "value \(String(describing: saValue(control))) while on")

                #expect(control.acceptsFirstResponder && !control.refusesFirstResponder, "acceptsFirstResponder \(control.acceptsFirstResponder)")
                #expect(control.canBecomeKeyView, "canBecomeKeyView \(control.canBecomeKeyView)")
                #expect(type(of: control) != NSSwitch.self, "a plain NSSwitch, a key stop only while Full Keyboard Access is on")

                let elements = prViews(section).filter { plVisible($0) && $0.isAccessibilityElement() }
                let dumped = elements.filter { $0.accessibilityRole()?.rawValue == "AXCheckBox" && $0.accessibilitySubrole()?.rawValue == "AXSwitch" }
                #expect(dumped.count == 1 && dumped.first === control, "\(dumped.count) AXCheckBox/AXSwitch elements in the section")
                let checkboxes = elements.filter { $0.accessibilityRole()?.rawValue == "AXCheckBox" }
                #expect(checkboxes.count == 1, "\(checkboxes.count) AXCheckBox elements in the section")
                let named = elements.filter { ($0.accessibilityLabel() ?? "") == saLogin }
                #expect(named.count == 1, "elements labelled \"\(saLogin)\": \(named.map { String(describing: type(of: $0)) })")
                let staticNames = elements.filter { view in
                    view.accessibilityRole() == .staticText && ((view.accessibilityLabel() ?? "") == saLogin || ((view as? NSTextField)?.stringValue ?? "") == saLogin)
                }
                #expect(staticNames.isEmpty, "AXStaticText named \"\(saLogin)\"")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func performClickAndTheAccessibilityPressEachFlipTheSwitchCallTheActionOnceAndMoveTheLoginItem(glass: Bool) async throws {
            try await saWith(glass: glass) { window, login in
                for accessibility in [false, true] {
                    let how = accessibility ? "accessibility press" : "performClick"
                    var (_, section) = try saIndexing(window)
                    var control = try #require(saLoginSwitch(section), "\(how): no switch labelled \"\(saLogin)\"")
                    #expect(control.state == .on && saValue(control) == 1, "\(how): state \(control.state.rawValue) before the press")
                    #expect(login.status == .enabled, "\(how): the login item before the press \(login.status)")

                    let first = await saPress(control, accessibility: accessibility)
                    #expect(first.calls == 1, "\(how): the first press called the action \(first.calls) times")
                    if accessibility { #expect(first.handled == true, "\(how): the first accessibility press returned \(String(describing: first.handled))") }
                    #expect(control.state == .off && saValue(control) == 0, "\(how): state \(control.state.rawValue) after the first press")
                    #expect(login.status == .notRegistered, "\(how): the login item after a press \(login.status)")

                    (_, section) = try saRelayout(window)
                    control = try #require(saLoginSwitch(section), "\(how): no switch after a redraw")
                    #expect(control.state == .off && saValue(control) == 0, "\(how): drawn \(control.state.rawValue) after the redraw")

                    let second = await saPress(control, accessibility: accessibility)
                    #expect(second.calls == 1, "\(how): the second press called the action \(second.calls) times")
                    if accessibility { #expect(second.handled == true, "\(how): the second accessibility press returned \(String(describing: second.handled))") }
                    #expect(control.state == .on && saValue(control) == 1, "\(how): state \(control.state.rawValue) after the second press")
                    #expect(login.status == .enabled, "\(how): the login item after a second press \(login.status)")

                    (_, section) = try saRelayout(window)
                    control = try #require(saLoginSwitch(section))
                    #expect(control.state == .on, "\(how): drawn \(control.state.rawValue) after the second redraw")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aRefusedChangeLeavesTheSwitchOnTheLiveStatusAndShowsOneMessageInCardOneUnderTheCaptionUntilAChangeWorks(glass: Bool) async throws {
            try await saWith(glass: glass) { window, login in
                var (root, section) = try saIndexing(window)
                #expect(plText(section, saLoginFailure) == nil, "a failure before anything went wrong")
                login.refuse(true)
                try #require(saLoginSwitch(section)).performClick(nil)
                await Task.yield()

                for look in DTLook.allCases {
                    (root, section) = try saRelayout(window, look)
                    let cards = saCards(root, section)
                    #expect(cards.count == 3, "\(look): \(cards.count) visible cards with a refusal")
                    guard let card = cards.first else { continue }
                    let control = try #require(saLoginSwitch(section), "\(look): no switch after a refusal")
                    #expect(control.state == .on && saValue(control) == 1, "\(look): the switch shows \(control.state.rawValue) after a refusal")
                    #expect(login.status == .enabled, "\(look): the login item moved to \(login.status)")
                    syExpectWarningLine(root, section, text: saLoginFailure, red: true, look)

                    let caption = try #require(saField(section, saLoginNote), "\(look): no caption")
                    let line = try #require(saField(section, saLoginFailure), "\(look): no failure line")
                    let next = try #require(saField(section, syNextStep), "\(look): no next-step line")
                    #expect(sxCard(of: line) === card && sxCard(of: next) === card, "\(look): the message is outside card one")
                    let symbols = plAccessibilityImages(section).filter { plVisible($0) }
                    #expect(symbols.count == 1 && symbols.first.flatMap { sxCard(of: $0) } === card, "\(look): the Warning symbol is not in card one")
                    let captionBox = sxAlignBox(root, caption)
                    let lineBox = sxAlignBox(root, line)
                    let nextBox = sxAlignBox(root, next)
                    #expect(lineBox.top >= captionBox.bottom - 0.5, "\(look): the message starts at \(lineBox.top), the caption ends at \(captionBox.bottom)")
                    #expect(nextBox.top >= lineBox.bottom - 0.5, "\(look): the next-step line is above the message")
                    #expect(plBox(root, card).bottom >= nextBox.bottom - 0.5, "\(look): the next-step line leaves card one")
                    #expect(saHairlines(root, card).isEmpty, "\(look): a hairline inside card one with a refusal")
                }

                login.refuse(false)
                try #require(saLoginSwitch(section)).performClick(nil)
                await Task.yield()
                (root, section) = try saRelayout(window)
                #expect(plText(section, saLoginFailure) == nil, "the failure stayed after a change that worked")
                syExpectNoWarning(section, .light)
                #expect(login.status == .notRegistered, "the login item after a change that worked \(login.status)")
                let after = try #require(saLoginSwitch(section), "no switch after a change that worked")
                #expect(after.state == .off, "the switch after a change that worked")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func cardTwoHoldsStartIndexingAtItsNaturalSizeAboveOneHairlineAndTheRedBorderlessDeleteIndexRow(glass: Bool) async throws {
            try await saWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try saIndexing(window, look)
                    let cards = saCards(root, section)
                    guard cards.count == 3 else {
                        Issue.record("\(look): \(cards.count) visible cards")
                        continue
                    }
                    let card = cards[1]
                    let cardBox = plBox(root, card)
                    let starts = sxButtons(section, titled: saStart)
                    #expect(starts.count == 1, "\(look): \(starts.count) Start indexing buttons")
                    let start = try #require(starts.first)
                    let deletes = sxButtons(section, titled: saDelete)
                    #expect(deletes.count == 1, "\(look): \(deletes.count) Delete index\u{2026} buttons")
                    let delete = try #require(deletes.first)
                    #expect(sxCard(of: start) === card && sxCard(of: delete) === card, "\(look): Start indexing and Delete index\u{2026} are not in card two")

                    let lines = saHairlines(root, card)
                    #expect(lines.count == 1, "\(look): \(lines.count) hairlines in card two")
                    guard let line = lines.first else { continue }
                    saExpectHairline(root, line, in: card, look, "card two")
                    let lineBox = plBox(root, line)
                    let startBox = sxAlignBox(root, start)
                    let deleteBox = sxAlignBox(root, delete)
                    #expect(lineBox.top >= startBox.bottom - 0.5, "\(look): the hairline starts at \(lineBox.top), Start indexing ends at \(startBox.bottom)")
                    #expect(lineBox.bottom <= deleteBox.top + 0.5, "\(look): the hairline ends at \(lineBox.bottom), Delete index\u{2026} starts at \(deleteBox.top)")

                    let rowOne = (top: cardBox.top, bottom: saMid(lineBox))
                    let rowTwo = (top: saMid(lineBox), bottom: cardBox.bottom)
                    #expect(rowOne.bottom - rowOne.top >= 40 - 0.5, "\(look): the Start indexing row is \(rowOne.bottom - rowOne.top) tall")
                    #expect(rowTwo.bottom - rowTwo.top >= 40 - 0.5, "\(look): the Delete index\u{2026} row is \(rowTwo.bottom - rowTwo.top) tall")

                    #expect(start is SetupButton, "\(look): Start indexing is a \(type(of: start))")
                    #expect(start.isEnabled, "\(look): Start indexing is disabled")
                    #expect(start.isBordered && start.bezelStyle == .rounded, "\(look): Start indexing is not a rounded push button")
                    #expect(sxColour(start.bezelColor, is: .controlAccentColor), "\(look): Start indexing bezel colour \(String(describing: start.bezelColor))")
                    #expect(start.keyEquivalent.isEmpty, "\(look): Start indexing key equivalent \(start.keyEquivalent.debugDescription)")
                    #expect(start.accessibilityLabel() == saStart, "\(look): Start indexing label \(String(describing: start.accessibilityLabel()))")
                    let natural = start.intrinsicContentSize.width
                    #expect(abs(startBox.width - natural) <= 1, "\(look): Start indexing is \(startBox.width) wide, its natural width is \(natural)")
                    #expect(startBox.width >= 90 && startBox.width <= 200 + 0.5, "\(look): Start indexing is \(startBox.width) wide")
                    #expect(abs((startBox.minX - cardBox.minX) - 14) <= 1, "\(look): Start indexing starts \(startBox.minX - cardBox.minX) in from the card's left edge")
                    #expect(abs(saMid(startBox) - (rowOne.top + rowOne.bottom) / 2) <= 1.5, "\(look): Start indexing centre is \(saMid(startBox)), its row's \((rowOne.top + rowOne.bottom) / 2)")

                    #expect(delete is SetupButton, "\(look): Delete index\u{2026} is a \(type(of: delete))")
                    #expect(!delete.isBordered, "\(look): Delete index\u{2026} is bordered")
                    #expect(delete.keyEquivalent.isEmpty, "\(look): Delete index\u{2026} key equivalent \(delete.keyEquivalent.debugDescription)")
                    #expect(delete.bezelColor == nil, "\(look): Delete index\u{2026} bezel colour \(String(describing: delete.bezelColor))")
                    let inks = sxInks(delete)
                    #expect(!inks.isEmpty && inks.allSatisfy { sxColour($0, is: .systemRed) }, "\(look): Delete index\u{2026} is inked \(inks)")
                    #expect(sxFont(saTitleFont(delete), size: 13, weight: .regular), "\(look): Delete index\u{2026} font \(String(describing: saTitleFont(delete)))")
                    #expect(delete.accessibilityLabel() == saDelete, "\(look): Delete index\u{2026} label \(String(describing: delete.accessibilityLabel()))")
                    #expect(delete.isEnabled, "\(look): Delete index\u{2026} is disabled")
                    let titleLeft = try #require(saTitleLeft(root, delete), "\(look): Delete index\u{2026} has no button cell")
                    #expect(abs((titleLeft - cardBox.minX) - 14) <= 2, "\(look): the Delete index\u{2026} title starts \(titleLeft - cardBox.minX) in from the card's left edge")
                    #expect(abs(saMid(deleteBox) - (rowTwo.top + rowTwo.bottom) / 2) <= 1.5, "\(look): Delete index\u{2026} centre is \(saMid(deleteBox)), its row's \((rowTwo.top + rowTwo.bottom) / 2)")
                    #expect(deleteBox.top > startBox.top, "\(look): Delete index\u{2026} is not below Start indexing")

                    for button in sxVisibleButtons(section) {
                        #expect(button.keyEquivalent.isEmpty, "\(look): \(button.title) has key equivalent \(button.keyEquivalent.debugDescription)")
                        #expect(!sxColour(button.bezelColor, is: .systemRed), "\(look): \(button.title) has a red bezel")
                        let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
                        #expect(fill == nil || !dtSame(fill ?? [], dtRGBA(.systemRed, look)), "\(look): \(button.title) is filled red")
                    }
                }

                var (root, section) = try saIndexing(window)
                let start = try #require(sxButtons(section, titled: saStart).first)
                #expect(start.isEnabled, "Start indexing is disabled before it is pressed")
                start.performClick(nil)
                await Task.yield()
                let dimmed = await sxEventually {
                    root = sxRelayout(window)
                    section = syIndexingSection(root) ?? section
                    return sxButtons(section, titled: saStart).first?.isEnabled == false
                }
                #expect(dimmed, "Start indexing stays enabled after it was pressed")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aPressOfStartIndexingAndOfDeleteIndexCallsOnStartAndOnDeleteOnceEach(glass: Bool) async throws {
            try await saWith(glass: glass) { window, _ in
                let (_, section) = try saIndexing(window)
                let counter = SACounter()
                section.onStart = { counter.starts += 1 }
                section.onDelete = { counter.deletes += 1 }
                try #require(sxButtons(section, titled: saStart).first).performClick(nil)
                #expect(counter.starts == 1 && counter.deletes == 0, "after Start indexing: \(counter.starts) starts, \(counter.deletes) deletes")
                try #require(sxButtons(section, titled: saDelete).first).performClick(nil)
                #expect(counter.starts == 1 && counter.deletes == 1, "after Delete index\u{2026}: \(counter.starts) starts, \(counter.deletes) deletes")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theConfirmIsAThirdCardUnderCardTwoWithCancelAtTheLeftAndAPlainConfirmAtTheRightAndCancelHidesIt(glass: Bool) async throws {
            try await saWith(glass: glass) { window, _ in
                var (root, section) = try saIndexing(window)
                #expect(plText(section, saDeleteMessage) == nil && sxButtons(section, titled: "Cancel").isEmpty && sxButtons(section, titled: saDeleteConfirm).isEmpty, "the confirm is visible before a press")
                try #require(sxButtons(section, titled: saDelete).first).performClick(nil)
                await Task.yield()

                for look in DTLook.allCases {
                    (root, section) = try saRelayout(window, look)
                    let cards = saCards(root, section)
                    #expect(cards.count == 4, "\(look): \(cards.count) visible cards with the confirm open")
                    guard cards.count == 4 else { continue }
                    let message = try #require(plText(section, saDeleteMessage), "\(look): the message is not shown: \(plTexts(section).map(\.stringValue))")
                    let confirmCard = try #require(sxCard(of: message), "\(look): the message is in no card")
                    let delete = try #require(sxButtons(section, titled: saDelete).first, "\(look): no Delete index\u{2026}")
                    #expect(confirmCard === cards[2], "\(look): the confirm is not the third card")
                    let start = try #require(sxButtons(section, titled: saStart).first, "\(look): no Start indexing")
                    #expect(sxCard(of: delete) === cards[1] && sxCard(of: start) === cards[1] && confirmCard !== cards[1], "\(look): the confirm shares card two, or Start indexing is not in card two")
                    #expect(plBox(root, cards[1]).bottom <= plBox(root, confirmCard).top + 0.5, "\(look): the confirm card is not under card two")

                    let cancels = sxButtons(section, titled: "Cancel")
                    let confirms = sxButtons(section, titled: saDeleteConfirm)
                    #expect(cancels.count == 1 && confirms.count == 1, "\(look): \(cancels.count) Cancel and \(confirms.count) confirm buttons")
                    let cancel = try #require(cancels.first)
                    let confirm = try #require(confirms.first)
                    #expect(cancel.isDescendant(of: confirmCard) && confirm.isDescendant(of: confirmCard), "\(look): a button is outside the confirm card")
                    for button in [cancel, confirm] {
                        #expect(sxIsPlainPush(button), "\(look): \(button.title) is not a plain push button")
                        #expect(sxInks(button).allSatisfy { !sxColour($0, is: .systemRed) }, "\(look): \(button.title) is red")
                        #expect(!sxColour(button.bezelColor, is: .systemRed), "\(look): \(button.title) has a red bezel")
                        #expect(button.isEnabled)
                    }
                    #expect(cancel.accessibilityLabel() == "Cancel" && confirm.accessibilityLabel() == saDeleteConfirm, "\(look): the labels are \(String(describing: cancel.accessibilityLabel())) and \(String(describing: confirm.accessibilityLabel()))")

                    let cardBox = plBox(root, confirmCard)
                    let cancelBox = sxAlignBox(root, cancel)
                    let confirmBox = sxAlignBox(root, confirm)
                    #expect(cancelBox.minX - cardBox.minX >= 12 - 0.5 && cancelBox.minX - cardBox.minX <= 28 + 0.5, "\(look): Cancel starts \(cancelBox.minX - cardBox.minX) pt from the card's left edge")
                    #expect(cardBox.maxX - confirmBox.maxX >= 12 - 0.5 && cardBox.maxX - confirmBox.maxX <= 28 + 0.5, "\(look): the confirm button ends \(cardBox.maxX - confirmBox.maxX) pt from the card's right edge")
                    #expect(cancelBox.maxX < confirmBox.minX && cancelBox.midX < cardBox.midX && confirmBox.midX > cardBox.midX, "\(look): Cancel and the confirm button are not on the two sides")
                    #expect(abs(cancelBox.top - confirmBox.top) <= 2 && abs(cancelBox.bottom - confirmBox.bottom) <= 2, "\(look): the two buttons are not in one row")

                    let messageBox = sxAlignBox(root, message)
                    #expect(sxFont(message.font, size: 13, weight: .regular), "\(look): message font \(String(describing: message.font))")
                    #expect(sxColour(message.textColor, is: .labelColor), "\(look): message colour")
                    #expect(!messageBox.intersects(plBox(root, cancel)) && !messageBox.intersects(plBox(root, confirm)), "\(look): the message overlaps a button")
                    #expect(messageBox.bottom <= plBox(root, cancel).top + 0.5, "\(look): the message is not above the buttons")
                }

                try #require(sxButtons(section, titled: "Cancel").first).performClick(nil)
                await Task.yield()
                (root, section) = try saRelayout(window)
                #expect(plText(section, saDeleteMessage) == nil, "the confirm stayed after Cancel")
                #expect(saCards(root, section).count == 3, "\(saCards(root, section).count) visible cards after Cancel")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKeyViewsAreLaunchAtLoginStartIndexingDeleteIndexThenCancelAndTheConfirmAndTheTabWalkFromTheSidebarClosesTheLoop(glass: Bool) async throws {
            try await saWith(glass: glass) { window, _ in
                var (_, section) = try saIndexing(window)
                #expect(section.keyViews.map { $0.accessibilityLabel() ?? "" } == [saLogin, saStart, saDelete], "keyViews \(section.keyViews.map { $0.accessibilityLabel() ?? "" })")
                for view in section.keyViews {
                    let label = view.accessibilityLabel() ?? ""
                    #expect(view.acceptsFirstResponder && (view as? NSControl)?.refusesFirstResponder != true, "\(label): acceptsFirstResponder \(view.acceptsFirstResponder)")
                    #expect(view.canBecomeKeyView, "\(label): canBecomeKeyView \(view.canBecomeKeyView)")
                    #expect(type(of: view) != NSSwitch.self && type(of: view) != NSButton.self, "\(label): a plain \(type(of: view)), a key stop only while Full Keyboard Access is on")
                }
                var loop = saKeyLoop(window)
                #expect(loop.names == saSidebar + [saLogin, saStart, saDelete], "Indexing loop \(loop.names)")
                #expect(loop.closed, "the Indexing loop never came back to its start")

                try #require(sxButtons(section, titled: saDelete).first).performClick(nil)
                await Task.yield()
                (_, section) = try saRelayout(window)
                #expect(section.keyViews.map { $0.accessibilityLabel() ?? "" } == [saLogin, saStart, saDelete, "Cancel", saDeleteConfirm], "keyViews with the confirm \(section.keyViews.map { $0.accessibilityLabel() ?? "" })")
                for view in section.keyViews {
                    let label = view.accessibilityLabel() ?? ""
                    #expect(view.canBecomeKeyView && view.acceptsFirstResponder, "\(label): not a key stop with the confirm open")
                }
                loop = saKeyLoop(window)
                #expect(loop.names == saSidebar + [saLogin, saStart, saDelete, "Cancel", saDeleteConfirm], "Indexing loop with the confirm \(loop.names)")
                #expect(loop.closed, "the Indexing loop with the confirm never came back to its start")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSectionDrawsOnlyLabelSecondaryAndRedWithTheAccentOnlyOnTheStartBezelAndTheSwitchAndNoGradientEffectViewOrGlass(glass: Bool) async throws {
            try await saWith(glass: glass) { window, login in
                for look in DTLook.allCases {
                    let (_, section) = try saIndexing(window, look)
                    saExpectPalette(section, redTexts: [], look)
                }

                var (_, section) = try saIndexing(window)
                try #require(sxButtons(section, titled: saDelete).first).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    (_, section) = try saRelayout(window, look)
                    saExpectPalette(section, redTexts: [], look)
                }
                try #require(sxButtons(section, titled: "Cancel").first).performClick(nil)
                await Task.yield()

                login.refuse(true)
                (_, section) = try saRelayout(window)
                try #require(saLoginSwitch(section)).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    (_, section) = try saRelayout(window, look)
                    saExpectPalette(section, redTexts: [saLoginFailure], look)
                    let failure = try #require(plText(section, saLoginFailure), "\(look): the login failure is not shown")
                    #expect(sxColour(failure.textColor, is: .systemRed), "\(look): the failure is not red")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSectionTextsLabelsAndScreenTextsAreTheListsOfTodayWithOnlyTheNameFieldAddedAndNothingLost(glass: Bool) async throws {
            try await saWith(glass: glass) { window, _ in
                var (root, section) = try saIndexing(window)
                let texts = plTexts(section).sorted { saPosition(root, $0) < saPosition(root, $1) }.map(\.stringValue)
                #expect(texts == [saLogin, saLoginNote, saListTitle, saEmpty], "Indexing texts \(texts)")
                let labels = prViews(section)
                    .filter { plVisible($0) && $0 is NSControl }
                    .sorted { saPosition(root, $0) < saPosition(root, $1) }
                    .compactMap { $0.accessibilityLabel() }
                    .filter { !$0.isEmpty }
                #expect(labels == [saLogin, saStart, saDelete], "Indexing labels \(labels)")
                #expect(window.settingsScreen.texts == ["Indexing", saLoginNote, saListTitle, saEmpty], "Indexing screen texts \(window.settingsScreen.texts)")

                try #require(sxButtons(section, titled: saDelete).first).performClick(nil)
                await Task.yield()
                (root, section) = try saRelayout(window)
                let open = plTexts(section).sorted { saPosition(root, $0) < saPosition(root, $1) }.map(\.stringValue)
                #expect(open == [saLogin, saLoginNote, saDeleteMessage, saListTitle, saEmpty], "Indexing texts with the confirm \(open)")
                #expect(window.settingsScreen.texts == ["Indexing", saLoginNote, saDeleteMessage, saListTitle, saEmpty], "Indexing screen texts with the confirm \(window.settingsScreen.texts)")
            }
        }
    }
}

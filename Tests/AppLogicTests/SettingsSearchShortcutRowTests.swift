import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let rsPdfInstalled = "com.apple.Preview"
private let rsMediaInstalled = "com.apple.QuickTimePlayerX"
private let rsTitle = "Open Sesame with"
private let rsName = "Shortcut"
private let rsApps = "Open files with"
private let rsRecord = "Record new shortcut"
private let rsBack = "Back to default"
private let rsDefault = "Control Option Space"
private let rsCustom = "Option Command K"
private let rsStatus = "Press the new shortcut, or Esc to cancel."
private let rsMessage = "That key can't be used as a shortcut. Pick another."
private let rsNotice = "The shortcut Command Space is taken by another app, so Sesame is using Control Option Space."
private let rsSidebar = ["Folders", "File types", "Search", "Indexing"]
private let rsDefaultFaces = ["\u{2303}", "\u{2325}", "Space"]
private let rsCustomFaces = ["\u{2325}", "\u{2318}", "K"]
private let rsEscapeCode: UInt16 = 53
private let rsSpaceCode: UInt16 = 49
private let rsKCode: UInt16 = 40

private final class RSCount {
    var value = 0
}

@MainActor
private func rsWith(
    glass: Bool,
    hotkey: String? = nil,
    notice: Bool = false,
    _ body: @MainActor (SettingsContainerWindow, ShortcutControl) async throws -> Void
) async throws {
    let login = SYLoginService()
    var made: ShortcutControl?
    try await sxWithWindow([], make: { model in
        if let hotkey {
            var held = Settings()
            held.hotkey = hotkey
            try? SettingsFile().write(held)
        }
        let control = ShortcutControl()
        if notice { control.adoptLive("ctrl+opt+space", refused: "cmd+space") }
        made = control
        return SettingsContainerWindow(
            model: model, shortcut: control, loginItem: LoginItem(service: login),
            appChoices: AppChoices(lookup: SYLookup(installed: [rsPdfInstalled, rsMediaInstalled])),
            deleteIndex: DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: {}), glass: glass)
    }) { window, _ in
        try await body(window, try #require(made, "no shortcut control was made"))
    }
}

@MainActor
private func rsSearch(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, SettingsSearchView) {
    let root = sxLayout(window, .search, look)
    return (root, try #require(sySearchSection(root), "no Search section view"))
}

@MainActor
private func rsRelayout(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, SettingsSearchView) {
    let root = sxRelayout(window, look)
    return (root, try #require(sySearchSection(root), "no Search section view"))
}

@MainActor
private func rsCards(_ root: NSView, _ section: NSView) -> [GroupCard] {
    sxVisibleCards(section).sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func rsRows(_ section: NSView) -> [KeycapRow] {
    prViews(section).compactMap { $0 as? KeycapRow }.filter { plVisible($0) }
}

@MainActor
private func rsFaces(_ root: NSView, _ row: NSView) -> [String] {
    plTexts(row).sorted { plBox(root, $0).minX < plBox(root, $1).minX }.map(\.stringValue)
}

@MainActor
private func rsOutsideTexts(_ root: NSView, _ section: NSView) -> [String] {
    let rows = rsRows(section)
    return plTexts(section)
        .filter { field in !sxAncestors(field).contains { ancestor in rows.contains { $0 === ancestor } } }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
        .map(\.stringValue)
}

@MainActor
private func rsExpectSettingsCard(_ card: GroupCard, _ look: DTLook, _ tag: String) {
    #expect(card.layer?.cornerRadius == 12, "\(look) \(tag): radius \(String(describing: card.layer?.cornerRadius))")
    #expect(abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look) \(tag): border width \(String(describing: card.layer?.borderWidth))")
    let border = dtRGBA(cgColor: card.layer?.borderColor)
    #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "\(look) \(tag): border \(String(describing: border))")
}

@MainActor
private func rsKey(_ window: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

@MainActor
private func rsKeyLoop(_ window: NSWindow) -> (names: [String], closed: Bool) {
    guard let start = window.initialFirstResponder else { return ([], false) }
    var views: [NSView] = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, views.count < 100 {
        views.append(current)
        next = current.nextValidKeyView
    }
    return (views.map { $0.accessibilityLabel() ?? "" }, next === start)
}

@MainActor
private func rsTitleFont(_ button: NSButton) -> NSFont? {
    if button.attributedTitle.length > 0,
       let font = button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
        return font
    }
    return button.font
}

@MainActor
private func rsTitleInk(_ button: NSButton) -> NSColor? {
    if button.attributedTitle.length > 0,
       let colour = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
        return colour
    }
    return button.contentTintColor
}

private func rsHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { rsHasGradient($0) }
}

private func rsLayerColours(_ layer: CALayer?) -> [CGColor] {
    guard let layer else { return [] }
    let own = [layer.backgroundColor, layer.borderColor].compactMap { $0 }
    return own + (layer.sublayers ?? []).flatMap { rsLayerColours($0) }
}

@MainActor
private func rsGroup(_ section: NSView, _ label: String) -> NSView? {
    prViews(section).first { view in
        plVisible(view) && view.isAccessibilityElement() && view.accessibilityRole() == .group && view.accessibilityLabel() == label
    }
}

@MainActor
private func rsExpectOrder(_ root: NSView, _ section: NSView, lines: [String], _ look: DTLook, _ tag: String) throws {
    let cards = rsCards(root, section)
    guard cards.count == 2 else {
        Issue.record("\(look) \(tag): \(cards.count) visible cards in Search")
        return
    }
    let title = try #require(plText(section, rsTitle), "\(look) \(tag): no \"\(rsTitle)\"")
    let back = try #require(sxButtons(section, titled: rsBack).first, "\(look) \(tag): no \(rsBack)")
    let appsTitle = try #require(plText(section, rsApps), "\(look) \(tag): no \"\(rsApps)\"")
    var chain: [(String, PLBox)] = [
        (rsTitle, sxAlignBox(root, title)),
        ("shortcut card", plBox(root, cards[0])),
        (rsBack, sxAlignBox(root, back)),
    ]
    for line in lines {
        let field = try #require(plText(section, line), "\(look) \(tag): no \"\(line)\" in \(plTexts(section).map(\.stringValue))")
        chain.append((line, sxAlignBox(root, field)))
    }
    chain.append((rsApps, sxAlignBox(root, appsTitle)))
    chain.append(("apps card", plBox(root, cards[1])))
    for (before, after) in zip(chain, chain.dropFirst()) {
        #expect(before.1.bottom <= after.1.top + 0.5, "\(look) \(tag): \(before.0) ends at \(before.1.bottom), \(after.0) starts at \(after.1.top)")
    }
    for line in lines {
        let field = try #require(plText(section, line))
        #expect(sxCard(of: field) == nil, "\(look) \(tag): \"\(line)\" is inside a card")
    }
    #expect(sxCard(of: title) == nil && sxCard(of: back) == nil && sxCard(of: appsTitle) == nil, "\(look) \(tag): a title or the Back line is inside a card")
    #expect(sxFont(title.font, size: 13, weight: .semibold), "\(look) \(tag): title font \(String(describing: title.font))")
    #expect(sxColour(title.textColor, is: .labelColor), "\(look) \(tag): title colour")
    let titleBox = sxAlignBox(root, title)
    let cardBox = plBox(root, cards[0])
    #expect(cardBox.top - titleBox.bottom >= -0.5 && cardBox.top - titleBox.bottom <= 20, "\(look) \(tag): the title ends \(cardBox.top - titleBox.bottom) pt above the card")
}

extension ModelDownloadTests {
    @Suite("SettingsSearchShortcutRowTests", .serialized)
    struct SettingsSearchShortcutRowTests {

        @MainActor
        @Test(arguments: slPaths)
        func theSectionReadsTitleShortcutCardBackLineStatusAndNoticeLinesThenTheOpenFilesWithTitleAndTheAppsCardInTwoSettingsCards(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, shortcut in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    let cards = rsCards(root, section)
                    #expect(cards.count == 2, "\(look): \(cards.count) visible cards in Search")
                    let sectionBox = plBox(root, section)
                    for (index, card) in cards.enumerated() {
                        rsExpectSettingsCard(card, look, "Search card \(index)")
                        let box = plBox(root, card)
                        #expect(abs(box.minX - 197) <= 1 && abs(box.maxX - 704) <= 1, "\(look): card \(index) spans \(box.minX) to \(box.maxX)")
                        #expect(abs(box.minX - sectionBox.minX) <= 1 && abs(box.maxX - sectionBox.maxX) <= 1, "\(look): card \(index) leaves the section")
                    }
                    try rsExpectOrder(root, section, lines: [], look, "at rest")
                }

                let (_, section) = try rsSearch(window)
                try #require(sxButtons(section, titled: rsRecord).first).performClick(nil)
                for look in DTLook.allCases {
                    let (root, again) = try rsRelayout(window, look)
                    try rsExpectOrder(root, again, lines: [rsStatus], look, "recording")
                }

                window.sendEvent(rsKey(window, code: rsEscapeCode, flags: [], characters: "\u{1B}"))
                for look in DTLook.allCases {
                    let (root, again) = try rsRelayout(window, look)
                    try rsExpectOrder(root, again, lines: [], look, "after Escape")
                }

                shortcut.refuseUnnamedKey()
                for look in DTLook.allCases {
                    let (root, again) = try rsRelayout(window, look)
                    try rsExpectOrder(root, again, lines: [rsMessage, syNextStep], look, "refused")
                }
            }

            try await rsWith(glass: glass, notice: true) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    try rsExpectOrder(root, section, lines: [rsNotice, syNextStep], look, "with the notice")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theShortcutCardHoldsOneRowOfTheNameTheCompactKeysAndRecordWithNoHairlineAndNothingElse(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    let cards = rsCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    let card = cards[0]
                    let cardBox = plBox(root, card)
                    #expect(cardBox.height >= 40 - 0.5 && cardBox.height <= 60 + 0.5, "\(look): the shortcut card is \(cardBox.height) tall")
                    syExpectHugs(root, card, look)

                    let lines = prViews(card).filter { $0 !== card && plVisible($0) && $0.frame.height > 0 && $0.frame.height <= 1 }
                    #expect(lines.isEmpty, "\(look): \(lines.count) hairlines in a one-row card")

                    let names = plTexts(section).filter { $0.stringValue == rsName }
                    #expect(names.count == 1, "\(look): \(names.count) texts read \"\(rsName)\": \(plTexts(section).map(\.stringValue))")
                    let name = try #require(names.first)
                    #expect(sxCard(of: name) === card, "\(look): the name is not in the shortcut card")
                    #expect(sxFont(name.font, size: 12.5, weight: .semibold), "\(look): the name font \(String(describing: name.font))")
                    #expect(sxColour(name.textColor, is: .labelColor), "\(look): the name colour")
                    #expect(!name.isAccessibilityElement(), "\(look): the name is an accessibility element")

                    let rows = rsRows(card)
                    #expect(rows.count == 1, "\(look): \(rows.count) keycap rows in the shortcut card")
                    let keys = try #require(rows.first, "\(look): no keycaps row in the shortcut card")
                    let records = sxButtons(card, titled: rsRecord)
                    #expect(records.count == 1, "\(look): \(records.count) Record buttons in the shortcut card")
                    let record = try #require(records.first)

                    let outsideRow = plTexts(card).filter { field in !sxAncestors(field).contains { $0 === keys } }.map(\.stringValue)
                    #expect(outsideRow == [rsName], "\(look): texts in the card outside the keycaps: \(outsideRow)")
                    let buttons = sxVisibleButtons(card)
                    #expect(buttons.count == 1 && buttons.first === record, "\(look): buttons in the shortcut card: \(buttons.map(\.title))")

                    let nameBox = sxAlignBox(root, name)
                    let keysBox = plBox(root, keys)
                    let recordBox = sxAlignBox(root, record)
                    #expect(abs((nameBox.minX - cardBox.minX) - 14) <= 1, "\(look): the name starts \(nameBox.minX - cardBox.minX) in from the card's left edge")
                    #expect(abs((nameBox.top + nameBox.bottom) / 2 - (cardBox.top + cardBox.bottom) / 2) <= 1.5, "\(look): the name is not centred in the card")
                    #expect(abs((cardBox.maxX - recordBox.maxX) - 14) <= 1, "\(look): Record ends \(cardBox.maxX - recordBox.maxX) from the card's right edge")
                    #expect(abs((recordBox.minX - keysBox.maxX) - 12) <= 1.5, "\(look): the keycaps end \(recordBox.minX - keysBox.maxX) before Record")
                    #expect(abs((keysBox.top + keysBox.bottom) / 2 - (cardBox.top + cardBox.bottom) / 2) <= 1.5, "\(look): the keycaps are not centred in the card")
                    #expect(abs((recordBox.top + recordBox.bottom) / 2 - (cardBox.top + cardBox.bottom) / 2) <= 1.5, "\(look): Record is not centred in the card")
                    #expect(keysBox.minX - nameBox.maxX >= 12, "\(look): the name ends \(keysBox.minX - nameBox.maxX) before the keycaps")
                    #expect(nameBox.maxX <= keysBox.minX && keysBox.maxX <= recordBox.minX, "\(look): the name, the keycaps and Record overlap")
                    #expect(abs(keysBox.height - 26) <= 0.5, "\(look): the keycaps row is \(keysBox.height) tall")

                    let back = try #require(sxButtons(section, titled: rsBack).first, "\(look): no \(rsBack)")
                    #expect(sxCard(of: back) == nil, "\(look): \(rsBack) is inside a card")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKeycapsAreOneGroupLabelledWithTheFullShortcutWithNoChildrenAndNoFigureAndNoKeyboardShortcutLabelRemain(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    let rows = rsRows(section)
                    #expect(rows.count == 1, "\(look): \(rows.count) keycap rows in Search")
                    let row = try #require(rows.first)
                    #expect(row.isAccessibilityElement(), "\(look): the keycaps row is not an accessibility element")
                    #expect(row.accessibilityRole() == .group, "\(look): the keycaps role \(String(describing: row.accessibilityRole()))")
                    #expect(row.accessibilityLabel() == rsDefault, "\(look): the keycaps label \"\(row.accessibilityLabel() ?? "nil")\"")
                    #expect((row.accessibilityChildren() ?? []).isEmpty, "\(look): the keycaps group has children")
                    let inside = prViews(row).filter { $0 !== row && $0.isAccessibilityElement() }
                    #expect(inside.isEmpty, "\(look): \(inside.count) key or face views are accessibility elements")
                    #expect(rsFaces(root, row) == rsDefaultFaces, "\(look): the faces read \(rsFaces(root, row))")

                    let fields = plTexts(section)
                    #expect(!fields.contains { $0.stringValue == rsDefault }, "\(look): a text reads \"\(rsDefault)\"")
                    #expect(!fields.contains { $0.stringValue.contains("Control") || $0.stringValue.contains("Option") }, "\(look): a text names a key: \(fields.map(\.stringValue))")
                    #expect(!fields.contains { abs(($0.font?.pointSize ?? 0) - 22) < 0.01 }, "\(look): a 22 pt text is in the section")
                    let labelled = prViews(section).filter { $0.isAccessibilityElement() && $0.accessibilityLabel() == "Keyboard shortcut" }
                    #expect(labelled.isEmpty, "\(look): \(labelled.count) elements are labelled \"Keyboard shortcut\"")
                    #expect(rsGroup(section, rsDefault) === row, "\(look): the group labelled \"\(rsDefault)\" is not the keycaps row")
                }
            }

            try await rsWith(glass: glass, hotkey: "cmd+opt+k") { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    let row = try #require(rsRows(section).first, "\(look): no keycaps row")
                    #expect(row.accessibilityLabel() == rsCustom, "\(look): the keycaps label \"\(row.accessibilityLabel() ?? "nil")\" with cmd+opt+k stored")
                    #expect(rsFaces(root, row) == rsCustomFaces, "\(look): the faces read \(rsFaces(root, row))")
                    #expect((row.accessibilityChildren() ?? []).isEmpty, "\(look): the keycaps group has children")
                    #expect(window.settingsScreen.shortcutText == rsCustom, "\(look): the screen reads \(String(describing: window.settingsScreen.shortcutText))")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func recordIsAPlainPushButtonBackToDefaultIsAQuietBorderlessLineUnderTheCardAndThePressesAndTheKeyLoopAreAsBefore(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    let cards = rsCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    #expect(sxButtons(section, titled: rsRecord).count == 1 && sxButtons(section, titled: rsBack).count == 1, "\(look): a button is missing or doubled")
                    let record = try #require(sxButtons(section, titled: rsRecord).first)
                    let back = try #require(sxButtons(section, titled: rsBack).first)
                    #expect(sxCard(of: record) === cards[0], "\(look): Record is not in the shortcut card")
                    #expect(sxIsPlainPush(record), "\(look): Record is not a plain push button")
                    #expect(record.isEnabled)
                    #expect(record.accessibilityLabel() == record.title, "\(look): Record label \"\(record.accessibilityLabel() ?? "nil")\"")

                    #expect(back is SetupButton, "\(look): \(rsBack) is a \(type(of: back))")
                    #expect(!back.isBordered, "\(look): \(rsBack) has a bezel")
                    #expect(back.keyEquivalent.isEmpty, "\(look): \(rsBack) key equivalent \"\(back.keyEquivalent)\"")
                    #expect(back.bezelColor == nil, "\(look): \(rsBack) has a bezel colour")
                    #expect(back.isEnabled)
                    #expect(back.accessibilityLabel() == back.title, "\(look): \(rsBack) label \"\(back.accessibilityLabel() ?? "nil")\"")
                    #expect(sxColour(rsTitleInk(back), is: .secondaryLabelColor), "\(look): \(rsBack) title colour \(String(describing: rsTitleInk(back)))")
                    #expect(sxFont(rsTitleFont(back), size: 11.5, weight: .regular), "\(look): \(rsBack) title font \(String(describing: rsTitleFont(back)))")
                    #expect(sxCard(of: back) == nil, "\(look): \(rsBack) is inside a card")
                    let cardBox = plBox(root, cards[0])
                    let backBox = sxAlignBox(root, back)
                    #expect(backBox.top - cardBox.bottom >= 4 - 0.5 && backBox.top - cardBox.bottom <= 10 + 0.5, "\(look): \(rsBack) starts \(backBox.top - cardBox.bottom) pt under the card")
                    #expect(abs((backBox.minX - cardBox.minX) - 4) <= 1, "\(look): \(rsBack) starts \(backBox.minX - cardBox.minX) in from the card's left edge")
                }

                let (_, section) = try rsSearch(window)
                #expect(section.shortcutView.keyViews.map { $0.accessibilityLabel() ?? "" } == [rsRecord, rsBack], "keyViews \(section.shortcutView.keyViews.map { $0.accessibilityLabel() ?? "" })")
                let loop = rsKeyLoop(window)
                #expect(loop.names == rsSidebar + [rsRecord, rsBack, "PDF app", "Media app"], "Search loop \(loop.names)")
                #expect(loop.closed, "the Search loop never came back to its start")

                let shortcutView = section.shortcutView
                let started = RSCount()
                let backed = RSCount()
                let oldStart = shortcutView.onStartRecording
                let oldBack = shortcutView.onBackToDefault
                shortcutView.onStartRecording = {
                    started.value += 1
                    oldStart()
                }
                shortcutView.onBackToDefault = {
                    backed.value += 1
                    oldBack()
                }
                let record = try #require(sxButtons(section, titled: rsRecord).first)
                let back = try #require(sxButtons(section, titled: rsBack).first)
                record.performClick(nil)
                #expect(started.value == 1 && backed.value == 0, "Record called onStartRecording \(started.value) times and onBackToDefault \(backed.value) times")
                #expect(shortcutView.isRecording, "a press of Record did not start recording")
                back.performClick(nil)
                #expect(backed.value == 1 && started.value == 1, "Back to default called onBackToDefault \(backed.value) times and onStartRecording \(started.value) times")
                #expect(!shortcutView.isRecording, "a press of Back to default left recording on")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func whileRecordingTheStatusLineAsksForTheNewShortcutAndTheKeysStayThenEscapeAnAcceptedKeyAndBackToDefaultEachRedrawTheKeys(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, _ in
                var (root, section) = try rsSearch(window)
                try #require(sxButtons(section, titled: rsRecord).first).performClick(nil)
                for look in DTLook.allCases {
                    (root, section) = try rsRelayout(window, look)
                    #expect(section.shortcutView.isRecording, "\(look): not recording after a press of Record")
                    let cards = rsCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    let lines = plTexts(section).filter { $0.stringValue == rsStatus }
                    #expect(lines.count == 1, "\(look): \(lines.count) status lines in \(plTexts(section).map(\.stringValue))")
                    let line = try #require(lines.first)
                    #expect(sxColour(line.textColor, is: .secondaryLabelColor), "\(look): the status line colour")
                    #expect(plAccessibilityImages(section).filter { plVisible($0) }.isEmpty, "\(look): a warning symbol beside the status line")
                    #expect(plText(section, syNextStep) == nil, "\(look): a next-step line while recording")
                    #expect(sxCard(of: line) == nil, "\(look): the status line is inside a card")
                    let back = try #require(sxButtons(section, titled: rsBack).first)
                    let lineBox = sxAlignBox(root, line)
                    let backBox = sxAlignBox(root, back)
                    let cardBox = plBox(root, cards[0])
                    #expect(lineBox.top >= backBox.bottom - 0.5, "\(look): the status line starts at \(lineBox.top), \(rsBack) ends at \(backBox.bottom)")
                    #expect(abs((lineBox.minX - cardBox.minX) - 4) <= 1, "\(look): the status line starts \(lineBox.minX - cardBox.minX) in from the card's left edge")
                    let sectionBox = plBox(root, section)
                    #expect(lineBox.minX >= sectionBox.minX - 0.5 && lineBox.maxX <= sectionBox.maxX + 0.5, "\(look): the status line leaves the section")
                    let row = try #require(rsRows(section).first)
                    #expect(row.accessibilityLabel() == rsDefault && rsFaces(root, row) == rsDefaultFaces, "\(look): the keys changed while recording: \(row.accessibilityLabel() ?? "nil") \(rsFaces(root, row))")
                }

                window.sendEvent(rsKey(window, code: rsEscapeCode, flags: [], characters: "\u{1B}"))
                for look in DTLook.allCases {
                    (root, section) = try rsRelayout(window, look)
                    #expect(!section.shortcutView.isRecording, "\(look): still recording after Escape")
                    #expect(rsOutsideTexts(root, section) == [rsTitle, rsName, rsApps, "PDF app", "Media app"], "\(look): texts after Escape \(rsOutsideTexts(root, section))")
                    let row = try #require(rsRows(section).first)
                    #expect(row.accessibilityLabel() == rsDefault && rsFaces(root, row) == rsDefaultFaces, "\(look): Escape changed the keys: \(row.accessibilityLabel() ?? "nil") \(rsFaces(root, row))")
                    syExpectNoWarning(section, look)
                }

                try #require(sxButtons(section, titled: rsRecord).first).performClick(nil)
                window.sendEvent(rsKey(window, code: rsKCode, flags: [.command, .option], characters: "k"))
                for look in DTLook.allCases {
                    (root, section) = try rsRelayout(window, look)
                    #expect(!section.shortcutView.isRecording, "\(look): still recording after a key")
                    let row = try #require(rsRows(section).first)
                    #expect(rsRows(section).count == 1, "\(look): \(rsRows(section).count) keycap rows")
                    #expect(row.accessibilityLabel() == rsCustom, "\(look): the keys read \"\(row.accessibilityLabel() ?? "nil")\" after cmd+opt+k")
                    #expect(rsFaces(root, row) == rsCustomFaces, "\(look): the faces read \(rsFaces(root, row)) after cmd+opt+k")
                    #expect((row.accessibilityChildren() ?? []).isEmpty, "\(look): the keycaps group has children")
                    #expect(rsOutsideTexts(root, section) == [rsTitle, rsName, rsApps, "PDF app", "Media app"], "\(look): texts after cmd+opt+k \(rsOutsideTexts(root, section))")
                    syExpectNoWarning(section, look)
                }

                try #require(sxButtons(section, titled: rsBack).first).performClick(nil)
                for look in DTLook.allCases {
                    (root, section) = try rsRelayout(window, look)
                    let row = try #require(rsRows(section).first)
                    #expect(row.accessibilityLabel() == rsDefault, "\(look): the keys read \"\(row.accessibilityLabel() ?? "nil")\" after Back to default")
                    #expect(rsFaces(root, row) == rsDefaultFaces, "\(look): the faces read \(rsFaces(root, row)) after Back to default")
                    syExpectNoWarning(section, look)
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aRefusedCombinationLeavesTheOldKeysAndShowsOneRedMessageWithTheWarningSymbolUnderTheBackLineOutsideEveryCardAndTheNoticeFollowsInSecondary(glass: Bool) async throws {
            try await rsWith(glass: glass, hotkey: "cmd+opt+k") { window, shortcut in
                var (root, section) = try rsSearch(window)
                shortcut.refuseUnnamedKey()
                for look in DTLook.allCases {
                    (root, section) = try rsRelayout(window, look)
                    syExpectWarningLine(root, section, text: rsMessage, red: true, look)
                    let message = try #require(plText(section, rsMessage))
                    let cards = rsCards(root, section)
                    #expect(sxCard(of: message) == nil, "\(look): the message is inside a card")
                    let back = try #require(sxButtons(section, titled: rsBack).first)
                    #expect(sxAlignBox(root, message).top >= sxAlignBox(root, back).bottom - 0.5, "\(look): the message is not under \(rsBack)")
                    if let card = cards.first { #expect(sxAlignBox(root, message).top >= plBox(root, card).bottom, "\(look): the message is not under the shortcut card") }
                    let row = try #require(rsRows(section).first)
                    #expect(row.accessibilityLabel() == rsCustom && rsFaces(root, row) == rsCustomFaces, "\(look): the keys changed after a refusal: \(row.accessibilityLabel() ?? "nil") \(rsFaces(root, row))")
                    #expect(plTexts(section).filter { $0.stringValue == rsMessage }.count == 1, "\(look): more than one message")
                }

                shortcut.clearMessage()
                (root, section) = try rsRelayout(window)
                syExpectNoWarning(section, .light)

                try #require(sxButtons(section, titled: rsRecord).first).performClick(nil)
                window.sendEvent(rsKey(window, code: rsSpaceCode, flags: [.command], characters: " "))
                let refusal = try #require(shortcut.message, "cmd+space was not refused")
                for look in DTLook.allCases {
                    (root, section) = try rsRelayout(window, look)
                    syExpectWarningLine(root, section, text: refusal, red: true, look)
                    let message = try #require(plText(section, refusal))
                    #expect(sxCard(of: message) == nil, "\(look): the refusal is inside a card")
                    let back = try #require(sxButtons(section, titled: rsBack).first)
                    #expect(sxAlignBox(root, message).top >= sxAlignBox(root, back).bottom - 0.5, "\(look): the refusal is not under \(rsBack)")
                    let row = try #require(rsRows(section).first)
                    #expect(row.accessibilityLabel() == rsCustom && rsFaces(root, row) == rsCustomFaces, "\(look): the keys changed after cmd+space: \(row.accessibilityLabel() ?? "nil") \(rsFaces(root, row))")
                    #expect(!section.shortcutView.isRecording, "\(look): still recording after a refusal")
                }
            }

            try await rsWith(glass: glass, notice: true) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    syExpectWarningLine(root, section, text: rsNotice, red: false, look)
                    let notice = try #require(plText(section, rsNotice))
                    #expect(sxColour(notice.textColor, is: .secondaryLabelColor), "\(look): the notice colour")
                    #expect(sxCard(of: notice) == nil, "\(look): the notice is inside a card")
                    let back = try #require(sxButtons(section, titled: rsBack).first)
                    #expect(sxAlignBox(root, notice).top >= sxAlignBox(root, back).bottom - 0.5, "\(look): the notice is not under \(rsBack)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theShortcutCardDrawsOnlyLabelSecondaryAndRedWithNoAccentGradientEffectViewOrGlassAndTheKeysUseOnlyTheGroupFillAndSeparator(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, shortcut in
                @MainActor func check(_ section: NSView, red: [String], _ look: DTLook, _ tag: String) throws {
                    let allowed: [NSColor] = [.labelColor, .secondaryLabelColor, .systemRed]
                    for field in plTexts(section) {
                        #expect(allowed.contains { sxColour(field.textColor, is: $0) }, "\(look) \(tag): \"\(field.stringValue)\" is drawn in \(String(describing: field.textColor))")
                        if sxColour(field.textColor, is: .systemRed) {
                            #expect(red.contains(field.stringValue), "\(look) \(tag): \"\(field.stringValue)\" is red")
                        }
                    }
                    for button in sxVisibleButtons(section) {
                        for ink in sxInks(button) {
                            #expect(allowed.contains { sxColour(ink, is: $0) }, "\(look) \(tag): \(button.title) is inked \(ink)")
                        }
                    }
                    let views = prViews(section)
                    #expect(!views.contains { $0 is NSVisualEffectView || slIsGlass($0) }, "\(look) \(tag): an effect or glass view in the section")
                    #expect(!views.contains { rsHasGradient($0.layer) }, "\(look) \(tag): a gradient layer in the section")
                    let accent = dtRGBA(.controlAccentColor, look)
                    let own = views.filter { view in !(view is NSControl) && !sxAncestors(view).contains { $0 is NSControl } }
                    for view in own {
                        for cgColor in [view.layer?.backgroundColor, view.layer?.borderColor] {
                            let rgba = dtRGBA(cgColor: cgColor)
                            #expect(rgba == nil || !dtSame(rgba ?? [], accent), "\(look) \(tag): a \(type(of: view)) layer is drawn in the accent colour")
                        }
                    }
                    for row in rsRows(section) {
                        let separator = dtRGBA(.separatorColor, look)
                        for cgColor in rsLayerColours(row.layer) + prViews(row).flatMap({ rsLayerColours($0.layer) }) {
                            guard let rgba = dtRGBA(cgColor: cgColor) else { continue }
                            let neutralFill = abs(rgba[0] - rgba[1]) <= 0.02 && abs(rgba[1] - rgba[2]) <= 0.02 && rgba[3] < 1
                            #expect(dtSame(rgba, separator) || neutralFill, "\(look) \(tag): a keycap layer is drawn in \(rgba)")
                        }
                    }
                }

                for look in DTLook.allCases {
                    let (_, section) = try rsSearch(window, look)
                    try check(section, red: [], look, "at rest")
                }
                shortcut.refuseUnnamedKey()
                for look in DTLook.allCases {
                    let (_, section) = try rsRelayout(window, look)
                    try check(section, red: [rsMessage], look, "refused")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theOpenFilesWithTitleAndTheTwoAlignedRowsKeepTheirPopUpsTwoHundredWideAndTheLabelColumnAHundredForty(glass: Bool) async throws {
            try await rsWith(glass: glass) { window, _ in
                for look in DTLook.allCases {
                    let (root, section) = try rsSearch(window, look)
                    let cards = rsCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    let cardBox = plBox(root, cards[1])
                    let titles = plTexts(section).filter { $0.stringValue == rsApps }
                    #expect(titles.count == 1, "\(look): \(titles.count) \"\(rsApps)\" titles")
                    let title = try #require(titles.first)
                    #expect(sxFont(title.font, size: 13, weight: .semibold) && sxColour(title.textColor, is: .labelColor), "\(look): the apps title style")
                    #expect(sxCard(of: title) == nil, "\(look): the apps title is inside a card")
                    let popups = syPopUps(section)
                    #expect(popups.count == 2, "\(look): \(popups.count) pop-ups")
                    let pdf = try #require(syPopUp(section, labelled: "PDF app"), "\(look): no PDF app pop-up")
                    let media = try #require(syPopUp(section, labelled: "Media app"), "\(look): no Media app pop-up")
                    let pdfLabel = try #require(plText(section, "PDF app"))
                    let mediaLabel = try #require(plText(section, "Media app"))
                    let pdfBox = sxAlignBox(root, pdf)
                    let mediaBox = sxAlignBox(root, media)
                    #expect(abs(pdfBox.width - 200) <= 1 && abs(mediaBox.width - 200) <= 1, "\(look): pop-up widths \(pdfBox.width) and \(mediaBox.width)")
                    #expect(abs(pdfBox.minX - mediaBox.minX) <= 0.5, "\(look): the pop-ups start at \(pdfBox.minX) and \(mediaBox.minX)")
                    for (label, popup) in [(pdfLabel, pdf), (mediaLabel, media)] {
                        #expect(sxCard(of: label) === cards[1] && sxCard(of: popup) === cards[1], "\(look): \(label.stringValue) is not in the apps card")
                        let labelBox = sxAlignBox(root, label)
                        let box = sxAlignBox(root, popup)
                        #expect(abs((labelBox.minX - cardBox.minX) - 14) <= 1, "\(look): \(label.stringValue) starts \(labelBox.minX - cardBox.minX) in from the card's left edge")
                        #expect(abs((box.minX - labelBox.minX) - 140) <= 1, "\(look): \(label.stringValue): the pop-up starts \(box.minX - labelBox.minX) after its label")
                    }
                }
            }
        }
    }
}

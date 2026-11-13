import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let otPdfInstalled = "com.apple.Preview"
private let otMediaInstalled = "com.apple.QuickTimePlayerX"
private let otDelete = "Delete index\u{2026}"
private let otDeleteConfirm = "Delete index"
private let otStart = "Start indexing"
private let otLogin = "Launch at login"
private let otLoginNote = "The shortcut works only while Sesame is running."
private let otLoginFailure = "Could not change Launch at login."
private let otDeleteMessage = "Delete the index? Sesame forgets what it has read and starts again when you press Start indexing. Your files and folders are not touched."
private let otListLabel = "Files Sesame could not read"
private let otEmpty = "Nothing here. Files Sesame could not read are listed here."
private let otMessage = "That key can't be used as a shortcut. Pick another."
private let otSidebar = ["Folders", "File types", "Search", "Indexing"]

@MainActor
private func otWith(
    glass: Bool,
    _ body: @MainActor (SettingsContainerWindow, ShortcutControl, SYLoginService) async throws -> Void
) async throws {
    let login = SYLoginService()
    let shortcut = ShortcutControl()
    try await sxWithWindow([], make: { model in
        SettingsContainerWindow(
            model: model, shortcut: shortcut, loginItem: LoginItem(service: login),
            appChoices: AppChoices(lookup: SYLookup(installed: [otPdfInstalled, otMediaInstalled])),
            deleteIndex: DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: {}), glass: glass)
    }) { window, _ in try await body(window, shortcut, login) }
}

@MainActor
private func otSearch(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, NSView) {
    let root = sxLayout(window, .search, look)
    return (root, try #require(sySearchSection(root), "no Search section view"))
}

@MainActor
private func otIndexing(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, NSView) {
    let root = sxLayout(window, .indexing, look)
    return (root, try #require(syIndexingSection(root), "no Indexing section view"))
}

@MainActor
private func otRelayoutIndexing(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, NSView) {
    let root = sxRelayout(window, look)
    return (root, try #require(syIndexingSection(root), "no Indexing section view"))
}

@MainActor
private func otCards(_ root: NSView, _ section: NSView) -> [GroupCard] {
    sxVisibleCards(section).sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func otLoginSwitch(_ section: NSView) -> NSSwitch? {
    prViews(section).compactMap { $0 as? NSSwitch }.first { plVisible($0) && ($0.accessibilityLabel() ?? "") == otLogin }
}

@MainActor
private func otAddUnreadable(_ store: IndexStore, _ name: String, inode: Int64) throws {
    let path = "/photos/" + name
    _ = try store.addFile(path: path, kind: "photo", size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode, device: 1, status: "pending")
    let queue = try store.pendingPhotos(limit: 50)
    let row = try #require(queue.first { $0.path == path }, "setup: pendingPhotos does not list \(path)")
    _ = try store.markCouldNotRead(row, reason: "damaged")
}

@MainActor
private func otExpectSettingsCard(_ card: GroupCard, _ look: DTLook, _ tag: String) {
    #expect(card.layer?.cornerRadius == 12, "\(look) \(tag): radius \(String(describing: card.layer?.cornerRadius))")
    #expect(abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look) \(tag): border width \(String(describing: card.layer?.borderWidth))")
    let border = dtRGBA(cgColor: card.layer?.borderColor)
    #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "\(look) \(tag): border \(String(describing: border))")
}

@MainActor
private func otExpectSpan(_ root: NSView, _ card: GroupCard, _ look: DTLook, _ tag: String) {
    let box = plBox(root, card)
    #expect(abs(box.minX - 197) <= 1 && abs(box.maxX - 704) <= 1, "\(look) \(tag): the card spans \(box.minX) to \(box.maxX)")
}

@MainActor
private func otParts(_ card: GroupCard) -> [NSView] {
    prViews(card).filter { view in
        guard plVisible(view), view !== card else { return false }
        if let field = view as? NSTextField { return !field.stringValue.isEmpty && !(field.superview is NSButton) }
        return view is NSButton
    }
}

@MainActor
private func otExpectPadding(_ root: NSView, _ card: GroupCard, _ look: DTLook, _ tag: String) {
    let parts = otParts(card)
    guard let first = parts.first else {
        Issue.record("\(look) \(tag): the card holds no text or button")
        return
    }
    let content = parts.dropFirst().reduce(sxAlignBox(root, first)) { $0.union(sxAlignBox(root, $1)) }
    let box = plBox(root, card)
    #expect(abs((content.minX - box.minX) - 14) <= 1, "\(look) \(tag): the content starts \(content.minX - box.minX) in from the card's left edge")
    #expect(content.maxX <= box.maxX - 13.5, "\(look) \(tag): the content ends \(box.maxX - content.maxX) from the card's right edge")
}

@MainActor
private func otExpectHairlines(_ root: NSView, _ card: GroupCard, count: Int, _ look: DTLook, _ tag: String) {
    let cardBox = plBox(root, card)
    let lines = prViews(card).filter { $0 !== card && plVisible($0) && $0.frame.height > 0 && $0.frame.height <= 1 }
    #expect(lines.count == count, "\(look) \(tag): \(lines.count) hairlines, wanted \(count)")
    for line in lines {
        let box = plBox(root, line)
        #expect(abs(line.frame.height - 1) <= 0.01, "\(look) \(tag): a hairline is \(line.frame.height) tall")
        #expect(abs((box.minX - cardBox.minX) - 14) <= 1, "\(look) \(tag): a hairline starts \(box.minX - cardBox.minX) in from the card's left edge")
        #expect(abs(cardBox.maxX - box.maxX) <= 1, "\(look) \(tag): a hairline ends \(cardBox.maxX - box.maxX) from the card's right edge")
        let fill = dtRGBA(cgColor: line.layer?.backgroundColor)
        #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.separatorColor, look)), "\(look) \(tag): a hairline colour \(String(describing: fill))")
    }
}

@MainActor
private func otExpectTitleAbove(_ root: NSView, _ section: NSView, _ text: String, card: GroupCard, _ look: DTLook) throws {
    let titles = plTexts(section).filter { $0.stringValue == text }
    #expect(titles.count == 1, "\(look): \(titles.count) texts equal \"\(text)\"")
    let title = try #require(titles.first)
    #expect(sxFont(title.font, size: 13, weight: .semibold), "\(look): \"\(text)\" font \(String(describing: title.font))")
    #expect(sxColour(title.textColor, is: .labelColor), "\(look): \"\(text)\" colour")
    #expect(sxCard(of: title) == nil, "\(look): \"\(text)\" is inside a card")
    let titleBox = sxAlignBox(root, title)
    let cardBox = plBox(root, card)
    #expect(titleBox.bottom <= cardBox.top + 0.5 && cardBox.top - titleBox.bottom <= 20, "\(look): \"\(text)\" ends \(cardBox.top - titleBox.bottom) pt above its card")
}

@MainActor
private func otPosition(_ root: NSView, _ view: NSView) -> (CGFloat, CGFloat) {
    let box = plBox(root, view)
    return (box.top.rounded(), box.minX)
}

@MainActor
private func otTexts(_ root: NSView, _ section: NSView) -> [String] {
    let rows = prViews(section).compactMap { $0 as? KeycapRow }
    return plTexts(section)
        .filter { field in !sxAncestors(field).contains { ancestor in rows.contains { $0 === ancestor } } }
        .sorted { otPosition(root, $0) < otPosition(root, $1) }
        .map(\.stringValue)
}

@MainActor
private func otLabels(_ root: NSView, _ section: NSView) -> [String] {
    prViews(section)
        .filter { plVisible($0) && ($0 is NSControl || $0 is NSImageView || $0 is KeycapRow) }
        .sorted { otPosition(root, $0) < otPosition(root, $1) }
        .compactMap { $0.accessibilityLabel() }
        .filter { !$0.isEmpty }
}

@MainActor
private func otKeyLoop(_ window: NSWindow) -> (names: [String], closed: Bool) {
    guard let start = window.initialFirstResponder else { return ([], false) }
    var views: [NSView] = [start]
    var next = start.nextValidKeyView
    while let current = next, current !== start, views.count < 100 {
        views.append(current)
        next = current.nextValidKeyView
    }
    return (views.map { $0.accessibilityLabel() ?? "" }, next === start)
}

private func otHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { otHasGradient($0) }
}

@MainActor
private func otExpectPalette(_ section: NSView, red: [String], _ look: DTLook) {
    let allowed: [NSColor] = [.labelColor, .secondaryLabelColor, .systemRed]
    for field in plTexts(section) {
        #expect(allowed.contains { sxColour(field.textColor, is: $0) }, "\(look): \"\(field.stringValue)\" is drawn in \(String(describing: field.textColor))")
        if sxColour(field.textColor, is: .systemRed) {
            #expect(red.contains(field.stringValue), "\(look): \"\(field.stringValue)\" is red")
        }
    }
    for button in sxVisibleButtons(section) {
        for ink in sxInks(button) {
            #expect(allowed.contains { sxColour(ink, is: $0) }, "\(look): \(button.title) is inked \(ink)")
        }
    }
    let views = prViews(section)
    #expect(!views.contains { $0 is NSVisualEffectView || slIsGlass($0) }, "\(look): an effect or glass view in the section")
    #expect(!views.contains { otHasGradient($0.layer) }, "\(look): a gradient layer in the section")
    let accent = dtRGBA(.controlAccentColor, look)
    let own = views.filter { view in !(view is NSControl) && !sxAncestors(view).contains { $0 is NSControl } }
    for view in own {
        for cgColor in [view.layer?.backgroundColor, view.layer?.borderColor] {
            let rgba = dtRGBA(cgColor: cgColor)
            #expect(rgba == nil || !dtSame(rgba ?? [], accent), "\(look): a \(type(of: view)) layer is drawn in the accent colour")
        }
    }
}

extension ModelDownloadTests {
    @Suite("SettingsOtherTabsCardTests", .serialized)
    struct SettingsOtherTabsCardTests {

        @MainActor
        @Test(arguments: slPaths)
        func searchHoldsTwoSettingsCardsAcross197To704WithTheOpenFilesWithTitleOutsideAndAboveTheAppsCard(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                for look in DTLook.allCases {
                    let (root, section) = try otSearch(window, look)
                    let cards = otCards(root, section)
                    #expect(cards.count == 2, "\(look): \(cards.count) visible cards in Search")
                    guard cards.count == 2 else { continue }
                    for (index, card) in cards.enumerated() {
                        let tag = "Search card \(index)"
                        otExpectSettingsCard(card, look, tag)
                        otExpectSpan(root, card, look, tag)
                        otExpectPadding(root, card, look, tag)
                    }
                    try otExpectTitleAbove(root, section, "Open files with", card: cards[1], look)
                    let heading = try #require(plText(section, "Open Sesame with"), "\(look): no \"Open Sesame with\"")
                    #expect(sxCard(of: heading) == nil, "\(look): \"Open Sesame with\" is inside a card")
                    #expect(plBox(root, heading).bottom <= plBox(root, cards[0]).top + 0.5, "\(look): \"Open Sesame with\" is not above the shortcut card")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func indexingHoldsThreeSettingsCardsAndAFourthWhileDeleteIsOpenAllAcross197To704WithTheCouldNotReadTitleAboveItsCard(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                for look in DTLook.allCases {
                    let (root, section) = try otIndexing(window, look)
                    let cards = otCards(root, section)
                    #expect(cards.count == 3, "\(look): \(cards.count) visible cards in Indexing")
                    guard cards.count == 3 else { continue }
                    for (index, card) in cards.enumerated() {
                        let tag = "Indexing card \(index)"
                        otExpectSettingsCard(card, look, tag)
                        otExpectSpan(root, card, look, tag)
                        otExpectPadding(root, card, look, tag)
                    }
                    try otExpectTitleAbove(root, section, otListLabel, card: cards[2], look)
                    #expect(sxCard(of: try #require(plText(section, otEmpty))) === cards[2], "\(look): the empty text is not in the third card")
                }

                var (_, section) = try otIndexing(window)
                try #require(sxButtons(section, titled: otDelete).first).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    let (root, again) = try otRelayoutIndexing(window, look)
                    section = again
                    let cards = otCards(root, section)
                    #expect(cards.count == 4, "\(look): \(cards.count) visible cards with the Delete confirm open")
                    guard cards.count == 4 else { continue }
                    for (index, card) in cards.enumerated() {
                        let tag = "Indexing card \(index) with the confirm"
                        otExpectSettingsCard(card, look, tag)
                        otExpectSpan(root, card, look, tag)
                        otExpectPadding(root, card, look, tag)
                    }
                    let message = try #require(plText(section, otDeleteMessage), "\(look): no confirm message")
                    #expect(sxCard(of: message) === cards[2], "\(look): the confirm is not the third card, between Delete index\u{2026} and the list")
                    try otExpectTitleAbove(root, section, otListLabel, card: cards[3], look)
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func searchRowHairlinesAreOnePointInsetFourteenFromTheLeftAndReachTheRightEdge(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                for look in DTLook.allCases {
                    let (root, section) = try otSearch(window, look)
                    let cards = otCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    otExpectHairlines(root, cards[0], count: 0, look, "shortcut card")
                    otExpectHairlines(root, cards[1], count: 1, look, "apps card")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func indexingRowHairlinesAreOnePointInsetFourteenFromTheLeftAndReachTheRightEdge(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                var (root, section) = try otIndexing(window)
                let before = otCards(root, section)
                guard before.count == 3 else {
                    Issue.record("\(before.count) visible cards in Indexing")
                    return
                }
                for look in DTLook.allCases {
                    (root, section) = try otRelayoutIndexing(window, look)
                    let cards = otCards(root, section)
                    guard cards.count == 3 else {
                        Issue.record("\(look): \(cards.count) visible cards in Indexing")
                        continue
                    }
                    otExpectHairlines(root, cards[0], count: 0, look, "Launch at login card")
                    otExpectHairlines(root, cards[1], count: 1, look, "Start indexing and Delete index card")
                    otExpectHairlines(root, cards[2], count: 0, look, "empty could-not-read card")
                }

                let store = try IndexStore()
                defer { store.close() }
                try otAddUnreadable(store, "locked.jpg", inode: 1)
                try otAddUnreadable(store, "broken.jpg", inode: 2)
                try otAddUnreadable(store, "other.jpg", inode: 3)
                for look in DTLook.allCases {
                    (root, section) = try otRelayoutIndexing(window, look)
                    let cards = otCards(root, section)
                    guard cards.count == 3 else {
                        Issue.record("\(look): \(cards.count) visible cards in Indexing with three unreadable files")
                        continue
                    }
                    otExpectHairlines(root, cards[2], count: 2, look, "could-not-read card of three rows")
                    for field in plTexts(section).filter({ sxCard(of: $0) === cards[2] }) {
                        let left = sxAlignBox(root, field).minX - plBox(root, cards[2]).minX
                        #expect(abs(left - 14) <= 1, "\(look): \"\(field.stringValue)\" starts \(left) in from the card's left edge")
                    }
                }

                try #require(sxButtons(section, titled: otDelete).first).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    (root, section) = try otRelayoutIndexing(window, look)
                    let cards = otCards(root, section)
                    guard cards.count == 4 else {
                        Issue.record("\(look): \(cards.count) visible cards with the confirm open")
                        continue
                    }
                    otExpectHairlines(root, cards[2], count: 0, look, "confirm card")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theVisibleTextsTheAccessibilityLabelsAndTheScreenTextsAreTheListsOfTodayWithOnlyTheShortcutNameAndTheKeycapsGroupChanged(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                var (root, section) = try otSearch(window)
                #expect(otTexts(root, section) == ["Open Sesame with", "Shortcut", "Open files with", "PDF app", "Media app"], "Search texts \(otTexts(root, section))")
                let searchLabels = otLabels(root, section)
                #expect(Set(searchLabels.prefix(2)) == ["Control Option Space", "Record new shortcut"] && Array(searchLabels.dropFirst(2)) == ["Back to default", "PDF app", "Media app"], "Search labels \(searchLabels)")
                #expect(window.settingsScreen.texts == ["Search", "Open Sesame with", "Shortcut", "Control Option Space", "Open files with", "PDF app", "Media app"], "Search screen texts \(window.settingsScreen.texts)")

                (root, section) = try otIndexing(window)
                #expect(otTexts(root, section) == [otLogin, otLoginNote, otListLabel, otEmpty], "Indexing texts \(otTexts(root, section))")
                #expect(otLabels(root, section) == [otLogin, otStart, otDelete], "Indexing labels \(otLabels(root, section))")
                #expect(window.settingsScreen.texts == ["Indexing", otLoginNote, otListLabel, otEmpty], "Indexing screen texts \(window.settingsScreen.texts)")

                try #require(sxButtons(section, titled: otDelete).first).performClick(nil)
                await Task.yield()
                (root, section) = try otRelayoutIndexing(window)
                #expect(otTexts(root, section) == [otLogin, otLoginNote, otDeleteMessage, otListLabel, otEmpty], "Indexing texts with the confirm \(otTexts(root, section))")
                #expect(otLabels(root, section) == [otLogin, otStart, otDelete, "Cancel", otDeleteConfirm], "Indexing labels with the confirm \(otLabels(root, section))")
                #expect(window.settingsScreen.texts == ["Indexing", otLoginNote, otDeleteMessage, otListLabel, otEmpty], "Indexing screen texts with the confirm \(window.settingsScreen.texts)")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKeyLoopOfEachSectionIsTheFourSidebarRowsThenItsOwnControlsAndClosesOnItself(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                _ = try otSearch(window)
                var loop = otKeyLoop(window)
                #expect(loop.names == otSidebar + ["Record new shortcut", "Back to default", "PDF app", "Media app"], "Search loop \(loop.names)")
                #expect(loop.closed, "the Search loop never came back to its start")

                var (_, section) = try otIndexing(window)
                loop = otKeyLoop(window)
                #expect(loop.names == otSidebar + [otLogin, otStart, otDelete], "Indexing loop \(loop.names)")
                #expect(loop.closed, "the Indexing loop never came back to its start")

                try #require(sxButtons(section, titled: otDelete).first).performClick(nil)
                await Task.yield()
                (_, section) = try otRelayoutIndexing(window)
                loop = otKeyLoop(window)
                #expect(loop.names == otSidebar + [otLogin, otStart, otDelete, "Cancel", otDeleteConfirm], "Indexing loop with the confirm \(loop.names)")
                #expect(loop.closed, "the Indexing loop with the confirm never came back to its start")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func searchDrawsOnlyLabelSecondaryAndRedWithNoAccentGradientEffectViewOrGlassInAnyCard(glass: Bool) async throws {
            try await otWith(glass: glass) { window, shortcut, _ in
                for look in DTLook.allCases {
                    let (_, section) = try otSearch(window, look)
                    otExpectPalette(section, red: [], look)
                }
                shortcut.refuseUnnamedKey()
                for look in DTLook.allCases {
                    let (_, section) = try otSearch(window, look)
                    otExpectPalette(section, red: [otMessage], look)
                    let message = try #require(plText(section, otMessage), "\(look): the refused-key message is not shown")
                    #expect(sxColour(message.textColor, is: .systemRed), "\(look): the message is not red")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func indexingDrawsOnlyLabelSecondaryAndRedWithAccentOnlyOnTheStartBezelAndNoGradientEffectViewOrGlass(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, login in
                for look in DTLook.allCases {
                    let (_, section) = try otIndexing(window, look)
                    otExpectPalette(section, red: [], look)
                    for button in sxVisibleButtons(section) {
                        let accent = sxColour(button.bezelColor, is: .controlAccentColor)
                        #expect(accent == (button.title == otStart), "\(look): \(button.title) accent bezel \(accent)")
                        let red = sxInks(button).contains { sxColour($0, is: .systemRed) }
                        #expect(red == (button.title == otDelete), "\(look): \(button.title) red ink \(red)")
                    }
                }
                login.refuse(true)
                var (_, section) = try otIndexing(window)
                try #require(otLoginSwitch(section)).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    (_, section) = try otRelayoutIndexing(window, look)
                    otExpectPalette(section, red: [otLoginFailure], look)
                    let failure = try #require(plText(section, otLoginFailure), "\(look): the login failure is not shown")
                    #expect(sxColour(failure.textColor, is: .systemRed), "\(look): the failure is not red")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSearchFormKeepsTwoTwoHundredWidePopUpsInOneColumnWithAHundredFortyLabelColumnInsideTheFourteenPadding(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                for look in DTLook.allCases {
                    let (root, section) = try otSearch(window, look)
                    let cards = otCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    let cardBox = plBox(root, cards[1])
                    let pdf = try #require(syPopUp(section, labelled: "PDF app"), "\(look): no PDF app pop-up")
                    let media = try #require(syPopUp(section, labelled: "Media app"), "\(look): no Media app pop-up")
                    let pdfLabel = try #require(plText(section, "PDF app"))
                    let mediaLabel = try #require(plText(section, "Media app"))
                    let pdfBox = sxAlignBox(root, pdf)
                    let mediaBox = sxAlignBox(root, media)
                    #expect(abs(pdfBox.width - 200) <= 1 && abs(mediaBox.width - 200) <= 1, "\(look): pop-up widths \(pdfBox.width) and \(mediaBox.width)")
                    #expect(abs(pdfBox.minX - mediaBox.minX) <= 0.5, "\(look): the pop-ups start at \(pdfBox.minX) and \(mediaBox.minX)")
                    for (label, popup) in [(pdfLabel, pdf), (mediaLabel, media)] {
                        let labelBox = sxAlignBox(root, label)
                        let box = sxAlignBox(root, popup)
                        #expect(abs((labelBox.minX - cardBox.minX) - 14) <= 1, "\(look): \(label.stringValue) starts \(labelBox.minX - cardBox.minX) in from the card's left edge")
                        #expect(abs((box.minX - labelBox.minX) - 140) <= 1, "\(look): \(label.stringValue): the pop-up starts \(box.minX - labelBox.minX) after its label")
                        #expect(box.maxX <= cardBox.maxX - 13.5, "\(look): the pop-up ends at \(box.maxX), the card at \(cardBox.maxX)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theIndexingButtonsAndTheConfirmCardKeepTheirKindsAndSitInsideTheFourteenPadding(glass: Bool) async throws {
            try await otWith(glass: glass) { window, _, _ in
                for look in DTLook.allCases {
                    let (root, section) = try otIndexing(window, look)
                    let start = try #require(sxButtons(section, titled: otStart).first, "\(look): no Start indexing")
                    let delete = try #require(sxButtons(section, titled: otDelete).first, "\(look): no Delete index\u{2026}")
                    #expect(start.isBordered && start.bezelStyle == .rounded && start.keyEquivalent.isEmpty, "\(look): Start indexing is not a rounded push button without a key equivalent")
                    #expect(sxColour(start.bezelColor, is: .controlAccentColor), "\(look): Start indexing bezel colour")
                    #expect(!delete.isBordered && delete.bezelColor == nil && delete.keyEquivalent.isEmpty, "\(look): Delete index\u{2026} is not a borderless button")
                    let deleteInks = sxInks(delete)
                    #expect(!deleteInks.isEmpty && deleteInks.allSatisfy { sxColour($0, is: .systemRed) }, "\(look): Delete index\u{2026} is inked \(deleteInks)")
                    for button in [start, delete] {
                        let card = try #require(sxCard(of: button), "\(look): \(button.title) is in no card")
                        let cardBox = plBox(root, card)
                        let box = sxAlignBox(root, button)
                        #expect(abs((box.minX - cardBox.minX) - 14) <= 1, "\(look): \(button.title) starts \(box.minX - cardBox.minX) in from the card's left edge")
                        #expect(cardBox.maxX - box.maxX >= 13.5, "\(look): \(button.title) ends \(cardBox.maxX - box.maxX) from the card's right edge")
                    }
                }

                var (_, section) = try otIndexing(window)
                try #require(sxButtons(section, titled: otDelete).first).performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    let (root, again) = try otRelayoutIndexing(window, look)
                    section = again
                    let message = try #require(plText(section, otDeleteMessage), "\(look): no confirm message")
                    let card = try #require(sxCard(of: message), "\(look): the message is in no card")
                    let cancel = try #require(sxButtons(section, titled: "Cancel").first, "\(look): no Cancel")
                    let confirm = try #require(sxButtons(section, titled: otDeleteConfirm).first, "\(look): no Delete index")
                    #expect(sxIsPlainPush(cancel) && sxIsPlainPush(confirm), "\(look): Cancel or the confirm button is not a plain push button")
                    let cardBox = plBox(root, card)
                    let cancelBox = sxAlignBox(root, cancel)
                    let confirmBox = sxAlignBox(root, confirm)
                    let messageBox = sxAlignBox(root, message)
                    #expect(abs((cancelBox.minX - cardBox.minX) - 14) <= 1, "\(look): Cancel starts \(cancelBox.minX - cardBox.minX) in from the card's left edge")
                    #expect(abs((cardBox.maxX - confirmBox.maxX) - 14) <= 1, "\(look): the confirm button ends \(cardBox.maxX - confirmBox.maxX) from the card's right edge")
                    #expect(abs((messageBox.minX - cardBox.minX) - 14) <= 1, "\(look): the message starts \(messageBox.minX - cardBox.minX) in from the card's left edge")
                    #expect(messageBox.maxX <= cardBox.maxX - 13.5, "\(look): the message ends \(cardBox.maxX - messageBox.maxX) from the card's right edge")
                    #expect(cancelBox.maxX < confirmBox.minX && cancelBox.midX < cardBox.midX && confirmBox.midX > cardBox.midX, "\(look): Cancel and the confirm button are not on the two sides")
                }
            }
        }
    }
}

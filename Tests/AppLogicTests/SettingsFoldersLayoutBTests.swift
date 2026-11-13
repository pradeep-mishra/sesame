import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let fbTitle = "Folders Sesame reads"
private let fbNote = "Tick a folder to read it. Use the more button on a row to re-index or remove it."
private let fbEmpty = "No folders. Add a folder to read it."
private let fbSaveError = "Could not save your settings."
private let fbAdd = "Add folder\u{2026}"
private let fbWaiting = "Waiting for Start indexing"
private let fbRemoveMessageForExtra = "Remove Extra from search? Its files leave the index. The files themselves are not touched."
private let fbLongDetail = "81 photos, 70 PDFs, 19 documents, 3 audio files, 5 videos, Waiting for Start indexing"
private let fbFortyName = "Album-Album-Album-Album-Album-Album-2019"
private let fbHundredTwentyName = String(repeating: "Holiday-", count: 15)

private let fbDetails: [String: String] = [
    "Trips": "40 photos, " + fbWaiting,
    "Notes": "3 photos, " + fbWaiting,
    "Extra": "2 photos, " + fbWaiting,
    sxLongName: "3 photos, " + fbWaiting,
]

private func fbDownloads(_ name: String = "Downloads") -> SXFolder {
    SXFolder(path: name, photos: 81, pdfs: 70, documents: 19, audio: 3, videos: 5)
}

@MainActor
private func fbWith(
    glass: Bool,
    _ folders: [SXFolder] = sxDefaultFolders,
    _ body: @MainActor (SettingsContainerWindow, SXEnv) async throws -> Void
) async throws {
    try await sxWithWindow(folders, make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(), glass: glass)
    }, body)
}

@MainActor
private func fbTexts(_ section: NSView) -> [NSTextField] {
    plTexts(section).filter { !($0.superview is NSButton) }
}

@MainActor
private func fbCards(_ root: NSView, _ section: NSView) -> [GroupCard] {
    sxVisibleCards(section).sorted { plBox(root, $0).top < plBox(root, $1).top }
}

private func fbMidY(_ box: PLBox) -> CGFloat {
    (box.top + box.bottom) / 2
}

@MainActor
private func fbNameLeft(_ root: NSView, _ check: NSButton) -> CGFloat {
    let rect = (check.cell as? NSButtonCell)?.titleRect(forBounds: check.bounds) ?? .zero
    return plBox(root, check).minX + rect.minX
}

@MainActor
private func fbTitleWidth(_ check: NSButton, _ name: String) -> CGFloat {
    (name as NSString).size(withAttributes: [.font: check.font ?? NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
}

@MainActor
private func fbBreakdown(_ root: NSView, _ section: NSView, _ check: NSButton, _ detail: String) -> NSTextField? {
    let checkBox = plBox(root, check)
    return fbTexts(section)
        .filter { $0.stringValue == detail && sxFont($0.font, size: 11.5, weight: .regular) }
        .min { abs(plBox(root, $0).top - checkBox.top) < abs(plBox(root, $1).top - checkBox.top) }
}

@MainActor
private func fbNameInk(_ button: NSButton) -> NSColor? {
    if button.attributedTitle.length > 0,
       let colour = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
        return colour
    }
    return button.contentTintColor
}

@MainActor
private func fbExpectSettingsCard(_ card: GroupCard, _ look: DTLook, _ tag: String) {
    #expect(card.layer?.cornerRadius == 12, "\(look) \(tag): radius \(String(describing: card.layer?.cornerRadius))")
    #expect(abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look) \(tag): border width \(String(describing: card.layer?.borderWidth))")
    let border = dtRGBA(cgColor: card.layer?.borderColor)
    #expect(border != nil && dtSame(border ?? [], dtRGBA(.separatorColor, look)), "\(look) \(tag): border \(String(describing: border))")
}

@MainActor
private func fbKeyName(_ view: NSView) -> String {
    if let popup = view as? NSPopUpButton { return popup.accessibilityLabel() ?? "" }
    if let button = view as? NSButton { return button.title }
    return String(describing: type(of: view))
}

@MainActor
private func fbKeyOrder(_ section: NSView, from start: NSView) -> [String] {
    var names: [String] = []
    var current: NSView? = start
    while let view = current, view.isDescendant(of: section), names.count < 40 {
        names.append(fbKeyName(view))
        current = view.nextValidKeyView
        if current === start { break }
    }
    return names
}

@MainActor
private func fbHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { fbHasGradient($0) }
}

extension ModelDownloadTests {
    @Suite("SettingsFoldersLayoutBTests", .serialized)
    struct SettingsFoldersLayoutBTests {

        @MainActor
        @Test(arguments: slPaths)
        func theTitleThenTheListCardThenTheAddFolderCardThenTheNoteRunTopToBottomWithBothCardsInTheSettingsStyle(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let cards = fbCards(root, section)
                    #expect(cards.count == 2, "\(look): \(cards.count) visible cards, wanted the list card and the Add folder card")
                    guard cards.count == 2 else { continue }
                    let listCard = cards[0]
                    let addCard = cards[1]
                    let checks = sxChecks(root, section, env)
                    #expect(checks.count == 4 && checks.allSatisfy { sxCard(of: $0) === listCard }, "\(look): the rows are not all in the first card")
                    let add = try #require(sxButtons(section, titled: fbAdd).first, "\(look): no Add folder")
                    #expect(sxCard(of: add) === addCard, "\(look): Add folder is not in the second card")
                    fbExpectSettingsCard(listCard, look, "list card")
                    fbExpectSettingsCard(addCard, look, "Add folder card")

                    let title = try #require(plText(section, fbTitle), "\(look): no \"\(fbTitle)\": \(plTexts(section).map(\.stringValue))")
                    #expect(sxFont(title.font, size: 13, weight: .semibold), "\(look): title font \(String(describing: title.font))")
                    #expect(sxColour(title.textColor, is: .labelColor), "\(look): title colour")
                    #expect(sxCard(of: title) == nil, "\(look): the title is inside a card")
                    let note = try #require(plText(section, fbNote), "\(look): no note: \(plTexts(section).map(\.stringValue))")
                    #expect(sxFont(note.font, size: 11.5, weight: .regular), "\(look): note font \(String(describing: note.font))")
                    #expect(sxColour(note.textColor, is: .secondaryLabelColor), "\(look): note colour")
                    #expect(sxCard(of: note) == nil, "\(look): the note is inside a card")

                    let titleBox = plBox(root, title)
                    let listBox = plBox(root, listCard)
                    let addBox = plBox(root, addCard)
                    let noteBox = plBox(root, note)
                    #expect(titleBox.bottom <= listBox.top + 0.5, "\(look): the title ends at \(titleBox.bottom), the list card starts at \(listBox.top)")
                    #expect(listBox.bottom <= addBox.top + 0.5, "\(look): the list card ends at \(listBox.bottom), the Add folder card starts at \(addBox.top)")
                    #expect(addBox.bottom <= noteBox.top + 0.5, "\(look): the Add folder card ends at \(addBox.bottom), the note starts at \(noteBox.top)")
                    #expect(titleBox.top < listBox.top && listBox.top < addBox.top && addBox.top < noteBox.top, "\(look): tops \(titleBox.top), \(listBox.top), \(addBox.top), \(noteBox.top)")
                    #expect(abs(noteBox.minX - (listBox.minX + 4)) <= 1, "\(look): the note starts \(noteBox.minX - listBox.minX) in from the card edge")
                    #expect(abs(listBox.minX - 197) <= 1 && abs(listBox.maxX - 704) <= 1, "\(look): list card spans \(listBox.minX) to \(listBox.maxX)")
                    #expect(abs(addBox.minX - 197) <= 1 && abs(addBox.maxX - 704) <= 1, "\(look): Add folder card spans \(addBox.minX) to \(addBox.maxX)")
                    #expect(listBox.height >= 40 * 4 - 0.5, "\(look): the list card is \(listBox.height) tall for 4 rows")
                    #expect(addBox.height >= 40 - 0.5, "\(look): the Add folder card is \(addBox.height) tall")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func withTheConfirmOpenItsSettingsCardSitsBelowTheNoteWithTheMessageAndTheTwoButtons(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, _ in
                var root = sxLayout(window, .folders)
                #expect(await smrChoose("Remove", folder: "Extra", in: root), "no Remove item under the more button of Extra")
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    let section = try #require(sxFoldersSection(root))
                    let cards = fbCards(root, section)
                    #expect(cards.count == 3, "\(look): \(cards.count) visible cards with the confirm open")
                    guard cards.count == 3 else { continue }
                    let message = try #require(plText(section, fbRemoveMessageForExtra), "\(look): no confirm message: \(plTexts(section).map(\.stringValue))")
                    let confirmCard = try #require(sxCard(of: message), "\(look): the message is in no card")
                    #expect(confirmCard === cards[2], "\(look): the confirm card is not the third card")
                    fbExpectSettingsCard(confirmCard, look, "confirm card")
                    let note = try #require(plText(section, fbNote), "\(look): no note")
                    #expect(plBox(root, note).bottom <= plBox(root, confirmCard).top + 0.5, "\(look): the confirm card starts above the end of the note")
                    #expect(sxButtons(section, titled: "Cancel").count == 1 && sxButtons(section, titled: "Remove folder").count == 1, "\(look): the confirm buttons")
                    for button in sxButtons(section, titled: "Cancel") + sxButtons(section, titled: "Remove folder") {
                        #expect(button.isDescendant(of: confirmCard) && sxIsPlainPush(button), "\(look): \(button.title) is not a plain push button in the confirm card")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theErrorLineSitsBelowTheNote(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                let extra = try #require(sxChecks(root, section, env).first { $0.title == "Extra" })
                #expect(await sxProvokeSaveError(pressing: extra), "could not make a failed write")
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFoldersSection(root))
                    let text = try #require(plText(section, fbSaveError), "\(look): no error text: \(plTexts(section).map(\.stringValue))")
                    let note = try #require(plText(section, fbNote), "\(look): no note")
                    #expect(plBox(root, note).bottom <= plBox(root, text).top + 0.5, "\(look): the error starts at \(plBox(root, text).top), the note ends at \(plBox(root, note).bottom)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func withNoFoldersTheEmptyTextTakesTheListCardsPlaceAndTheAddFolderCardAndTheNoteStayBelowIt(glass: Bool) async throws {
            try await fbWith(glass: glass, []) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let cards = fbCards(root, section)
                    #expect(cards.count == 1, "\(look): \(cards.count) visible cards, wanted only the Add folder card")
                    let add = try #require(sxButtons(section, titled: fbAdd).first, "\(look): no Add folder")
                    #expect(cards.first.map { sxCard(of: add) === $0 } == true, "\(look): Add folder is not in the one card")
                    let title = try #require(plText(section, fbTitle), "\(look): no title")
                    let empty = try #require(plText(section, fbEmpty), "\(look): no empty text: \(plTexts(section).map(\.stringValue))")
                    let note = try #require(plText(section, fbNote), "\(look): no note")
                    guard let addCard = cards.first else { continue }
                    #expect(sxColour(empty.textColor, is: .secondaryLabelColor), "\(look): empty text colour")
                    #expect(plBox(root, title).bottom <= plBox(root, empty).top + 0.5, "\(look): the empty text is above the title")
                    #expect(plBox(root, empty).bottom <= plBox(root, addCard).top + 0.5, "\(look): the empty text is below the Add folder card")
                    #expect(plBox(root, addCard).bottom <= plBox(root, note).top + 0.5, "\(look): the note is above the Add folder card")
                    #expect(sxChecks(root, section, env).isEmpty && smrMoreButtons(root).isEmpty, "\(look): a row without a folder")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func eachRowIsTheCheckboxThenTheNameInItThenTheBreakdownUnderTheNameThenTheMoreButtonAtTheRight(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                #expect(sxLongName.count == 60, "the fixture name is \(sxLongName.count) characters")
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let cards = fbCards(root, section)
                    guard let listCard = cards.first else {
                        Issue.record("\(look): no list card")
                        continue
                    }
                    let cardBox = plBox(root, listCard)
                    let checks = sxChecks(root, section, env)
                    #expect(checks.map(\.title) == env.names, "\(look): rows \(checks.map(\.title)), wanted \(env.names)")
                    for check in checks {
                        let name = check.title
                        let tag = "\(look) \(name.prefix(12))"
                        let checkBox = plBox(root, check)
                        #expect(sxIsSwitchTyped(check) && check is SetupButton, "\(tag): not a switch-type SetupButton")
                        #expect(sxFont(check.font, size: 12.5, weight: .semibold), "\(tag): name font \(String(describing: check.font))")
                        #expect(abs((checkBox.minX - cardBox.minX) - 14) <= 1, "\(tag): the checkbox starts \(checkBox.minX - cardBox.minX) in from the card edge")
                        #expect(check.frame.width >= fbTitleWidth(check, name) + 14, "\(tag): the checkbox is \(check.frame.width) wide for \(fbTitleWidth(check, name)) of name")

                        let detail = try #require(fbDetails[name])
                        let label = try #require(fbBreakdown(root, section, check, detail), "\(tag): no breakdown label \"\(detail)\": \(fbTexts(section).map(\.stringValue))")
                        let labelBox = plBox(root, label)
                        #expect(!label.isAccessibilityElement(), "\(tag): the breakdown is an accessibility element")
                        #expect(sxColour(label.textColor, is: .secondaryLabelColor), "\(tag): breakdown colour")
                        #expect(label.lineBreakMode == .byTruncatingTail, "\(tag): breakdown line break mode \(label.lineBreakMode.rawValue)")
                        let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 11.5))
                        #expect(labelBox.height <= lineHeight + 2, "\(tag): the breakdown is \(labelBox.height) tall, a line is \(lineHeight)")
                        #expect(sxCard(of: label) === listCard, "\(tag): the breakdown is outside the list card")
                        #expect(abs(labelBox.minX - fbNameLeft(root, check)) <= 1, "\(tag): the breakdown starts at \(labelBox.minX), the name at \(fbNameLeft(root, check))")
                        #expect(labelBox.top >= fbMidY(checkBox) - 0.5, "\(tag): the breakdown starts at \(labelBox.top), above the middle \(fbMidY(checkBox)) of the name's row")

                        let more = try #require(smrMoreButton(root, folder: name), "\(tag): no more button")
                        let moreBox = plBox(root, more)
                        #expect(abs((cardBox.maxX - moreBox.maxX) - 14) <= 1, "\(tag): the more button ends \(cardBox.maxX - moreBox.maxX) from the card's right edge")
                        #expect(checkBox.maxX <= moreBox.minX + 0.5, "\(tag): the checkbox reaches \(checkBox.maxX), the more button starts at \(moreBox.minX)")
                        #expect(labelBox.maxX <= moreBox.minX + 0.5, "\(tag): the breakdown reaches \(labelBox.maxX), the more button starts at \(moreBox.minX)")
                        #expect(moreBox.top >= cardBox.top && moreBox.bottom <= cardBox.bottom, "\(tag): the more button leaves the card")
                        #expect(fbMidY(moreBox) >= checkBox.top - 0.5 && fbMidY(moreBox) <= labelBox.bottom + 0.5, "\(tag): the more button is not in the row")
                    }
                    #expect(smrMoreButtons(root).count == 4, "\(look): \(smrMoreButtons(root).count) more buttons")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aRowsLabelHelpAndValueAreUnchangedAndAnUntickedNameDrawsInSecondaryColour(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                for check in sxChecks(root, section, env) {
                    let name = check.title
                    #expect(check.accessibilityLabel() == name + ", " + (fbDetails[name] ?? "?"), "\(name): label \"\(check.accessibilityLabel() ?? "nil")\"")
                    #expect(check.accessibilityHelp() == env.path(name), "\(name): help \"\(check.accessibilityHelp() ?? "nil")\"")
                    #expect(check.state == .on && check.isEnabled, "\(name): state \(check.state.rawValue)")
                    #expect(sxColour(fbNameInk(check), is: .labelColor), "\(name): a ticked name is not in the label colour")
                }
                let extra = try #require(sxChecks(root, section, env).first { $0.title == "Extra" })
                extra.performClick(nil)
                await Task.yield()
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFoldersSection(root))
                    let checks = sxChecks(root, section, env)
                    let unticked = try #require(checks.first { $0.title == "Extra" })
                    #expect(unticked.state == .off, "\(look): Extra state \(unticked.state.rawValue)")
                    #expect(sxColour(fbNameInk(unticked), is: .secondaryLabelColor), "\(look): an unticked name is not in the secondary colour")
                    for other in checks where other.title != "Extra" {
                        #expect(sxColour(fbNameInk(other), is: .labelColor), "\(look): \(other.title) is not in the label colour")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aVeryLongBreakdownTailTruncatesOnOneLineWhileTheNameTheCheckboxAndTheMoreButtonKeepTheirPlace(glass: Bool) async throws {
            let longRow = [SXFolder(path: "Trips", photos: 40), fbDownloads()]
            let shortRow = [SXFolder(path: "Trips", photos: 40), SXFolder(path: "Downloads", photos: 1)]
            var shortWidth: CGFloat = 0
            try await fbWith(glass: glass, shortRow) { window, env in
                let root = sxLayout(window, .folders)
                let section = try #require(sxFoldersSection(root))
                shortWidth = try #require(sxChecks(root, section, env).first { $0.title == "Downloads" }).frame.width
            }
            try await fbWith(glass: glass, longRow) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let listCard = try #require(fbCards(root, section).first, "\(look): no list card")
                    let cardBox = plBox(root, listCard)
                    let check = try #require(sxChecks(root, section, env).first { $0.title == "Downloads" }, "\(look): no Downloads row")
                    let checkBox = plBox(root, check)
                    #expect(check.accessibilityLabel() == "Downloads, " + fbLongDetail, "\(look): label \"\(check.accessibilityLabel() ?? "nil")\"")

                    let fullWidth = (fbLongDetail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)]).width
                    #expect(fullWidth > 430, "the fixture breakdown is only \(fullWidth) wide, so it would not be cut")

                    let nameWidth = fbTitleWidth(check, "Downloads")
                    #expect(nameWidth > 40, "the name \"Downloads\" measures \(nameWidth)")
                    #expect(check.frame.width >= nameWidth + 14, "\(look): the checkbox is \(check.frame.width) wide for a name of \(nameWidth): the breakdown squeezed it")
                    #expect(abs(check.frame.width - shortWidth) <= 0.5, "\(look): the checkbox is \(check.frame.width) wide with a long breakdown and \(shortWidth) with a short one")
                    #expect(check.frame.height >= 14, "\(look): the checkbox is \(check.frame.height) tall")

                    let label = try #require(fbBreakdown(root, section, check, fbLongDetail), "\(look): no breakdown label: \(fbTexts(section).map(\.stringValue))")
                    let labelBox = plBox(root, label)
                    #expect(label.lineBreakMode == .byTruncatingTail, "\(look): line break mode \(label.lineBreakMode.rawValue)")
                    let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 11.5))
                    #expect(labelBox.height <= lineHeight + 2, "\(look): the breakdown is \(labelBox.height) tall: it wraps")
                    #expect(label.frame.width + 0.5 < fullWidth, "\(look): the breakdown frame is \(label.frame.width) wide for a text of \(fullWidth): it is not cut")
                    #expect(check.toolTip == fbLongDetail, "\(look): the tooltip is \"\(check.toolTip ?? "nil")\"")

                    let more = try #require(smrMoreButton(root, folder: "Downloads"), "\(look): no more button")
                    let moreBox = plBox(root, more)
                    #expect(moreBox.minX >= cardBox.minX && moreBox.maxX <= cardBox.maxX - 13, "\(look): the more button spans \(moreBox.minX) to \(moreBox.maxX) in a card to \(cardBox.maxX)")
                    #expect(abs(moreBox.width - 22) <= 0.5 && abs(moreBox.height - 22) <= 0.5, "\(look): the more button is \(moreBox.width) x \(moreBox.height)")
                    #expect(checkBox.maxX <= moreBox.minX + 0.5 && labelBox.maxX <= moreBox.minX + 0.5, "\(look): a part reaches the more button")
                    #expect(labelBox.maxX <= cardBox.maxX - 13, "\(look): the breakdown ends at \(labelBox.maxX), the card at \(cardBox.maxX)")

                    let sectionBox = plBox(root, section)
                    #expect(sectionBox.maxX <= 704.5, "\(look): the section reaches \(sectionBox.maxX)")
                    #expect(cardBox.minX >= 196 && cardBox.maxX <= 704.5, "\(look): the card spans \(cardBox.minX) to \(cardBox.maxX)")
                    let trips = try #require(sxChecks(root, section, env).first { $0.title == "Trips" })
                    #expect(trips.frame.width >= fbTitleWidth(trips, "Trips") + 14, "\(look): the Trips checkbox is \(trips.frame.width) wide")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aFortyCharacterNameWithALongBreakdownKeepsItsWholeNameAndTheMoreButtonInsideTheCard(glass: Bool) async throws {
            #expect(fbFortyName.count == 40, "the fixture name is \(fbFortyName.count) characters")
            try await fbWith(glass: glass, [fbDownloads(fbFortyName)]) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let listCard = try #require(fbCards(root, section).first, "\(look): no list card")
                    let cardBox = plBox(root, listCard)
                    let check = try #require(sxChecks(root, section, env).first, "\(look): no row")
                    #expect(check.title == fbFortyName)
                    #expect(check.frame.width >= fbTitleWidth(check, fbFortyName) + 14, "\(look): the 40-character name is cut: \(check.frame.width) wide for \(fbTitleWidth(check, fbFortyName))")
                    let label = try #require(fbBreakdown(root, section, check, fbLongDetail), "\(look): no breakdown label: \(fbTexts(section).map(\.stringValue))")
                    #expect(label.lineBreakMode == .byTruncatingTail && plBox(root, label).height <= 15, "\(look): the breakdown is not one tail-truncated line")
                    let more = try #require(smrMoreButton(root, folder: fbFortyName), "\(look): no more button")
                    let moreBox = plBox(root, more)
                    #expect(moreBox.maxX <= cardBox.maxX - 13 && moreBox.minX >= cardBox.minX, "\(look): the more button spans \(moreBox.minX) to \(moreBox.maxX) in a card to \(cardBox.maxX)")
                    #expect(plBox(root, check).maxX <= moreBox.minX + 0.5 && plBox(root, label).maxX <= moreBox.minX + 0.5, "\(look): a part reaches the more button")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aHundredTwentyCharacterNameShortensWithAnEllipsisInTheMiddleOnOneLineAndStaysInsideTheCardClearOfTheMoreButton(glass: Bool) async throws {
            #expect(fbHundredTwentyName.count == 120, "the fixture name is \(fbHundredTwentyName.count) characters")
            try await fbWith(glass: glass, [SXFolder(path: fbHundredTwentyName, photos: 3), SXFolder(path: "Trips", photos: 40)]) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let listCard = try #require(fbCards(root, section).first, "\(look): no list card")
                    let cardBox = plBox(root, listCard)
                    let check = try #require(sxChecks(root, section, env).first { $0.title == fbHundredTwentyName }, "\(look): no row for the long name")
                    let checkBox = plBox(root, check)
                    let nameWidth = fbTitleWidth(check, fbHundredTwentyName)
                    #expect(check.frame.width + 0.5 < nameWidth + 14, "\(look): the checkbox is \(check.frame.width) wide for \(nameWidth) of name: it was not shortened")
                    #expect(check.lineBreakMode == .byTruncatingMiddle, "\(look): line break mode \(check.lineBreakMode.rawValue)")
                    #expect(check.frame.height <= 24, "\(look): the name is \(check.frame.height) tall: it wraps")
                    #expect(check.accessibilityHelp() == env.path(fbHundredTwentyName), "\(look): the help is not the full path")

                    let more = try #require(smrMoreButton(root, folder: fbHundredTwentyName), "\(look): no more button")
                    let moreBox = plBox(root, more)
                    #expect(checkBox.maxX <= moreBox.minX + 0.5, "\(look): the name ends at \(checkBox.maxX), the more button starts at \(moreBox.minX)")
                    #expect(moreBox.maxX <= cardBox.maxX - 13, "\(look): the more button ends at \(moreBox.maxX), the card at \(cardBox.maxX)")
                    for part in fbTexts(section).map({ plBox(root, $0) }) + [checkBox] {
                        #expect(part.minX >= cardBox.minX && part.maxX <= cardBox.maxX - 13, "\(look): a part spans \(part.minX) to \(part.maxX) in a card from \(cardBox.minX) to \(cardBox.maxX)")
                        for button in smrMoreButtons(root) {
                            #expect(!part.intersects(plBox(root, button)), "\(look): a part overlaps a more button")
                        }
                    }
                    for field in fbTexts(section) where field.stringValue != fbTitle && field.stringValue != fbNote {
                        #expect(field.frame.height <= 24, "\"\(field.stringValue.prefix(20))\" is \(field.frame.height) tall: it wraps")
                    }
                    #expect(plBox(root, section).maxX <= 704.5, "\(look): the section reaches \(plBox(root, section).maxX)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theMoreButtonIsABorderlessTwentyTwoPointRoundPullDownWithAnEllipsisAndTheFullPathAsHelpAndNoRowButtonsRemain(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                var seen: [[CGFloat]] = []
                for look in [DTLook.light, .dark, .light] {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    #expect(smrMoreButtons(root).count == 4, "\(look): \(smrMoreButtons(root).count) more buttons for 4 rows")
                    var fills: [[CGFloat]] = []
                    for name in env.names {
                        let tag = "\(look) \(name.prefix(12))"
                        let button = try #require(smrMoreButton(root, folder: name), "\(tag): no more button")
                        #expect(button is SettingsPopUp, "\(tag): a \(type(of: button)), not a SettingsPopUp")
                        #expect(button.pullsDown, "\(tag): the button does not pull down")
                        #expect(!button.isBordered, "\(tag): the button has a bezel")
                        #expect(button.isEnabled, "\(tag): the button is disabled")
                        #expect(button.accessibilityLabel() == "More actions for " + name, "\(tag): label \"\(button.accessibilityLabel() ?? "nil")\"")
                        #expect(button.accessibilityHelp() == env.path(name),"\(tag): help \"\(button.accessibilityHelp() ?? "nil")\"")
                        let axTitle = button.accessibilityTitle() ?? ""
                        #expect(axTitle.isEmpty || axTitle == "More actions for " + name, "\(tag): the accessibility title \"\(axTitle)\" would be read before the label")
                        #expect(button.imagePosition == .imageOnly, "\(tag): image position \(button.imagePosition.rawValue)")
                        let images = [button.image, button.menu?.items.first?.image].compactMap { $0 }
                        #expect(images.contains { String(describing: $0).hasSuffix("symbol = ellipsis>") && $0.isTemplate }, "\(tag): images \(images)")
                        #expect(sxColour(button.contentTintColor, is: .secondaryLabelColor), "\(tag): tint \(String(describing: button.contentTintColor))")

                        let box = plBox(root, button)
                        #expect(abs(box.width - 22) <= 0.5 && abs(box.height - 22) <= 0.5, "\(tag): the button is \(box.width) x \(box.height)")
                        let round = ([button] + sxAncestors(button).prefix(3)).first { view in
                            abs((view.layer?.cornerRadius ?? 0) - 11) <= 0.01 && abs(view.frame.width - 22) <= 0.5 && abs(view.frame.height - 22) <= 0.5
                        }
                        #expect(round != nil, "\(tag): no round 22 pt backing of radius 11")
                        let fill = dtRGBA(cgColor: round?.layer?.backgroundColor) ?? []
                        #expect(dtSame(fill, dtRGBA(Design.moreFill, look)), "\(tag): fill \(fill), wanted \(dtRGBA(Design.moreFill, look))")
                        #expect(fill.count == 4 && sgsNeutral(fill) && fill[3] > 0.01 && fill[3] < 1, "\(tag): the fill \(fill) is not a translucent neutral")
                        fills.append(fill)
                    }
                    seen.append(fills.first ?? [])
                    for title in ["Re-index", "Remove"] {
                        #expect(sxButtons(section, titled: title).isEmpty, "\(look): a button titled \(title) is still drawn")
                        #expect(!sxVisibleButtons(section).contains { ($0.accessibilityLabel() ?? "") == title && !($0 is NSPopUpButton) }, "\(look): a button labelled \(title) is still drawn")
                    }
                }
                #expect(seen.count == 3 && !dtSame(seen[0], seen[1]) && dtSame(seen[0], seen[2]), "the fill did not repaint with the look: \(seen)")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theKeyLoopOfTheFoldersSectionIsPerRowTheCheckboxThenTheMoreButtonThenAddFolderThenTheConfirmButtons(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                var start = try #require(sxChecks(root, section, env).first, "no first row")
                let rows = env.names.flatMap { [$0, "More actions for " + $0] }
                #expect(fbKeyOrder(section, from: start) == rows + [fbAdd], "key views \(fbKeyOrder(section, from: start))")
                #expect(await smrChoose("Remove", folder: "Extra", in: root), "no Remove item under the more button of Extra")
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                start = try #require(sxChecks(root, section, env).first, "no first row with the confirm open")
                #expect(fbKeyOrder(section, from: start) == rows + [fbAdd, "Cancel", "Remove folder"], "key views with the confirm open \(fbKeyOrder(section, from: start))")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theMenuHoldsReIndexAndRemoveWithRemoveInRedAndNoKeyEquivalentImageOrMissingTarget(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    for name in env.names {
                        let tag = "\(look) \(name.prefix(12))"
                        let button = try #require(smrMoreButton(root, folder: name), "\(tag): no more button")
                        let menu = try #require(button.menu, "\(tag): no menu")
                        #expect(menu.items.count == 3 && menu.items.first?.isHidden == true, "\(tag): items \(menu.items.map { "\($0.title)\($0.isHidden ? " (hidden)" : "")" }): wanted a hidden leading title item and two more")
                        let visible = smrVisibleItems(button)
                        #expect(visible.map(\.title) == ["Re-index", "Remove"], "\(tag): visible items \(visible.map(\.title))")
                        guard visible.count == 2 else { continue }
                        for item in visible {
                            #expect(item.isEnabled, "\(tag): \(item.title) is disabled")
                            #expect(item.keyEquivalent.isEmpty, "\(tag): \(item.title) has the key equivalent \"\(item.keyEquivalent)\"")
                            #expect(item.image == nil, "\(tag): \(item.title) has an image")
                            #expect(item.target != nil, "\(tag): \(item.title) has no target")
                        }
                        let remove = visible[1]
                        #expect(remove.title == "Remove", "\(tag): title \"\(remove.title)\"")
                        let removeInk = (remove.attributedTitle?.length ?? 0) > 0
                            ? remove.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
                        #expect(sxColour(removeInk, is: .systemRed), "\(tag): Remove ink \(String(describing: removeInk))")
                        let reindex = visible[0]
                        let reindexInk = (reindex.attributedTitle?.length ?? 0) > 0
                            ? reindex.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
                        #expect(reindexInk == nil || sxColour(reindexInk, is: .labelColor), "\(tag): Re-index ink \(String(describing: reindexInk))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func choosingRemoveFromTheMenuOpensTheConfirmAndRemovesNothingUntilRemoveFolderIsPressed(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                #expect(sxButtons(section, titled: "Remove folder").isEmpty && plText(section, fbRemoveMessageForExtra) == nil, "the confirm is visible before any choice")
                #expect(await smrChoose("Remove", folder: "Extra", in: root), "no Remove item under the more button of Extra")
                #expect(await sxEventually(3) { window.settingsScreen.confirm != nil }, "choosing Remove opened no confirm")
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                #expect(plText(section, fbRemoveMessageForExtra) != nil, "the message is not shown: \(plTexts(section).map(\.stringValue))")
                #expect(sxButtons(section, titled: "Cancel").count == 1 && sxButtons(section, titled: "Remove folder").count == 1, "the confirm buttons")
                #expect(window.settingsScreen.folderRows.map(\.name) == env.names, "a row left on Remove alone: \(window.settingsScreen.folderRows.map(\.name))")

                let cancel = try #require(sxButtons(section, titled: "Cancel").first)
                cancel.performClick(nil)
                await Task.yield()
                #expect(await sxEventually(3) { window.settingsScreen.confirm == nil }, "Cancel left the confirm open")
                #expect(window.settingsScreen.folderRows.map(\.name) == env.names, "a row left on Cancel")

                root = sxRelayout(window)
                #expect(await smrChoose("Remove", folder: "Extra", in: root), "no Remove item after Cancel")
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                let confirm = try #require(sxButtons(section, titled: "Remove folder").first, "no Remove folder button")
                confirm.performClick(nil)
                await Task.yield()
                let expected = env.names.filter { $0 != "Extra" }
                #expect(await sxEventually(3) { window.settingsScreen.folderRows.map(\.name) == expected }, "after Remove folder the rows are \(window.settingsScreen.folderRows.map(\.name)), wanted \(expected)")
                #expect(FileManager.default.fileExists(atPath: env.path("Extra") + "/photo-0.jpg"), "a file of the removed folder was deleted")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func choosingReIndexFromTheMenuIsPerformedOpensNoConfirmAndRemovesNothing(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                let root = sxLayout(window, .folders)
                #expect(await smrChoose("Re-index", folder: "Trips", in: root), "no Re-index item under the more button of Trips")
                try await Task.sleep(nanoseconds: 200_000_000)
                #expect(window.settingsScreen.confirm == nil, "Re-index opened a confirm")
                #expect(window.settingsScreen.folderRows.map(\.name) == env.names, "Re-index changed the rows: \(window.settingsScreen.folderRows.map(\.name))")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func addFolderIsABorderlessSecondaryTitledButtonAloneInItsCardOnTheCheckboxColumn(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let adds = sxButtons(section, titled: fbAdd)
                    #expect(adds.count == 1, "\(look): \(adds.count) Add folder buttons")
                    let add = try #require(adds.first)
                    #expect(add is SetupButton, "\(look): Add folder is a \(type(of: add))")
                    #expect(add.accessibilityLabel() == fbAdd, "\(look): label \"\(add.accessibilityLabel() ?? "nil")\"")
                    #expect(!add.isBordered, "\(look): Add folder has a bezel")
                    #expect(add.keyEquivalent.isEmpty, "\(look): key equivalent \"\(add.keyEquivalent)\"")
                    #expect(add.bezelColor == nil, "\(look): a bezel colour")
                    #expect(add.isEnabled)
                    #expect(add.target != nil && add.action != nil, "\(look): Add folder is not wired to an action")
                    #expect(sxColour(fbNameInk(add), is: .secondaryLabelColor), "\(look): title colour \(String(describing: fbNameInk(add)))")

                    let card = try #require(sxCard(of: add), "\(look): Add folder is in no card")
                    let controls = prViews(card).compactMap { $0 as? NSControl }.filter { plVisible($0) }
                    #expect(controls.count == 1 && controls.first === add, "\(look): \(controls.count) controls in the Add folder card")
                    let cardBox = plBox(root, card)
                    let addBox = plBox(root, add)
                    let first = try #require(sxChecks(root, section, env).first)
                    #expect(addBox.minX >= 196 && addBox.maxX <= 704.5, "\(look): Add folder spans \(addBox.minX) to \(addBox.maxX)")
                    #expect(abs(addBox.minX - (cardBox.minX + 14)) <= 1, "\(look): Add folder starts \(addBox.minX - cardBox.minX) in from the card edge")
                    #expect(abs(addBox.minX - plBox(root, first).minX) <= 1, "\(look): Add folder starts at \(addBox.minX), the checkboxes at \(plBox(root, first).minX)")
                    for button in smrMoreButtons(root) {
                        #expect(!addBox.intersects(plBox(root, button)), "\(look): Add folder overlaps a more button")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theFoldersSectionDrawsOnlyLabelSecondaryAndRedWithNoGradientEffectViewOrGlass(glass: Bool) async throws {
            try await fbWith(glass: glass) { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                let extra = try #require(sxChecks(root, section, env).first { $0.title == "Extra" })
                #expect(await sxProvokeSaveError(pressing: extra), "could not make a failed write")
                #expect(await smrChoose("Remove", folder: "Trips", in: root), "no Remove item under the more button of Trips")
                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFoldersSection(root))
                    let allowed: [NSColor] = [.labelColor, .secondaryLabelColor, .systemRed]
                    for field in fbTexts(section) {
                        #expect(allowed.contains { sxColour(field.textColor, is: $0) }, "\(look): \"\(field.stringValue.prefix(24))\" is drawn in \(String(describing: field.textColor))")
                    }
                    for button in sxVisibleButtons(section) {
                        for ink in sxInks(button) {
                            #expect(!sxColour(ink, is: .controlAccentColor), "\(look): \(button.accessibilityLabel() ?? button.title) has an accent ink")
                            #expect(allowed.contains { sxColour(ink, is: $0) }, "\(look): \(button.accessibilityLabel() ?? button.title) has the ink \(ink)")
                        }
                    }
                    let views = prViews(section)
                    #expect(!views.contains { $0 is NSVisualEffectView || slIsGlass($0) }, "\(look): an effect or glass view in the section")
                    #expect(!views.contains { fbHasGradient($0.layer) }, "\(look): a gradient layer in the section")
                }
            }
        }
    }
}

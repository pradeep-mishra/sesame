import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let sfRemoveMessageForExtra = "Remove Extra from search? Its files leave the index. The files themselves are not touched."
private let sfSaveError = "Could not save your settings."
private let sfNoFolders = "No folders. Add a folder to read it."
private let sfTitle = "Folders Sesame reads"
private let sfNote = "Tick a folder to read it. Use the more button on a row to re-index or remove it."

@MainActor
private func sfOwnTexts(_ section: NSView) -> [NSTextField] {
    plTexts(section).filter { !($0.superview is NSButton) }
}

@MainActor
private func sfTextBoxes(_ root: NSView, _ section: NSView, _ env: SXEnv) -> [(label: String, box: PLBox)] {
    let fields = sfOwnTexts(section).map { (label: $0.stringValue, box: plBox(root, $0)) }
    let checks = sxChecks(root, section, env).map { (label: $0.title, box: plBox(root, $0)) }
    return fields + checks
}

extension ModelDownloadTests {
    @Suite("SettingsFoldersLayoutTests", .serialized)
    struct SettingsFoldersLayoutTests {

        @MainActor
        @Test func theRowsSitInOneFlippedGroupCardWithNoBezelScrollBoxAndNoHeadingOfTheirOwn() async throws {
            try await sxWith { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    #expect(plVisible(section))

                    let cards = sxVisibleCards(section).sorted { plBox(root, $0).top < plBox(root, $1).top }
                    #expect(cards.count == 2, "\(look): \(cards.count) visible GroupCards in the Folders section, wanted the list card and the Add folder card")
                    #expect(!prViews(section).contains { $0 is NSScrollView }, "\(look): a scroll view inside the Folders section")
                    #expect(!prViews(section).contains { $0 is NSBox }, "\(look): an NSBox inside the Folders section")
                    for scroll in sxAncestors(section).compactMap({ $0 as? NSScrollView }) {
                        #expect(scroll.borderType == .noBorder, "\(look): a scroll view around the section has a bezel border")
                        #expect(scroll.documentView?.isFlipped == true, "\(look): the pane's document view is not flipped")
                    }

                    let checks = sxChecks(root, section, env)
                    #expect(checks.map(\.title) == env.names, "\(look): rows drawn \(checks.map(\.title)), wanted \(env.names)")
                    #expect(plTexts(section).filter { $0.stringValue == "Folders" }.isEmpty, "\(look): the section draws its own \"Folders\" heading")
                    let titled = plTexts(section).filter { $0.font?.pointSize == 17 }
                    #expect(titled.isEmpty, "\(look): the section draws a 17 pt text")
                    let sectionTitle = plText(section, sfTitle)
                    #expect(sectionTitle != nil && sxFont(sectionTitle?.font, size: 13, weight: .semibold), "\(look): the title \"\(sfTitle)\" is \(String(describing: sectionTitle?.font))")
                    guard let card = cards.first, let first = checks.first, let last = checks.last, cards.count == 2 else { continue }
                    for check in checks {
                        #expect(sxCard(of: check) === card, "\(look): \(check.title) is not in the card")
                    }

                    let cardBox = plBox(root, card)
                    let sectionBox = plBox(root, section)
                    #expect(abs(cardBox.minX - sectionBox.minX) <= 1 && abs(cardBox.maxX - sectionBox.maxX) <= 1,
                            "\(look): card spans \(cardBox.minX) to \(cardBox.maxX), the section \(sectionBox.minX) to \(sectionBox.maxX)")
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): card spans \(cardBox.minX) to \(cardBox.maxX)")

                    let firstGap = plBox(root, first).top - cardBox.top
                    #expect(firstGap >= 0 && firstGap <= 20, "\(look): the first row starts \(firstGap) pt below the top of the card")
                    let lastTop = plBox(root, last).top
                    let lastRowTexts = sfOwnTexts(section).filter { sxCard(of: $0) === card && plBox(root, $0).top >= lastTop - 0.5 }
                    let lastRowBottom = ([plBox(root, last).bottom] + lastRowTexts.map { plBox(root, $0).bottom }).max() ?? 0
                    let lastGap = cardBox.bottom - lastRowBottom
                    #expect(lastGap >= 0 && lastGap <= 20, "\(look): the last row ends \(lastGap) pt above the bottom of the card")

                    let tops = checks.map { plBox(root, $0).top }
                    for (index, pair) in zip(tops, tops.dropFirst()).enumerated() {
                        #expect(pair.1 - pair.0 >= 40 - 0.5, "\(look): rows \(index) and \(index + 1) are \(pair.1 - pair.0) pt apart")
                    }
                    #expect(cardBox.height >= 40 * CGFloat(checks.count) - 0.5, "\(look): the card is \(cardBox.height) pt tall for \(checks.count) rows")

                    let separators = prViews(card).filter { $0 !== card && $0.frame.height > 0 && $0.frame.height <= 1 && $0.frame.width >= cardBox.width - 14 - 0.5 }
                    #expect(separators.count == checks.count - 1, "\(look): \(separators.count) separators for \(checks.count) rows")
                }
            }
        }

        @MainActor
        @Test func eachTickIsASwitchTypeCheckboxWithTheNameThenDetailLabelTheFullPathAsHelpAndTheValueOnOrOff() async throws {
            try await sxWith { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root), "no Folders section view")
                #expect(!prViews(section).contains { $0 is NSSwitch }, "an NSSwitch is in the Folders section")
                var checks = sxChecks(root, section, env)
                #expect(checks.count == 4, "\(checks.count) ticks")
                for check in checks {
                    #expect(sxIsSwitchTyped(check), "\(check.title) is not a switch-type button")
                    #expect((check.accessibilityLabel() ?? "").hasPrefix(check.title + ", "), "\(check.title): label \"\(check.accessibilityLabel() ?? "nil")\"")
                    #expect(check.accessibilityHelp() == env.path(check.title), "\(check.title): help \"\(check.accessibilityHelp() ?? "nil")\"")
                    #expect(check.state == .on, "\(check.title): state \(check.state.rawValue)")
                    #expect(check.isEnabled)
                }
                let trips = try #require(checks.first { $0.title == "Trips" })
                #expect(trips.accessibilityLabel()?.hasPrefix("Trips, 40 photos") == true, "Trips label \"\(trips.accessibilityLabel() ?? "nil")\"")
                for check in checks {
                    let titleWidth = (check.title as NSString).size(withAttributes: [.font: check.font ?? NSFont.systemFont(ofSize: 13)]).width
                    #expect(check.frame.width >= titleWidth + 14, "\(check.title): \(check.frame.width) pt wide for \(titleWidth) pt of title")
                }

                let detail = try #require(sfOwnTexts(section).first { $0.stringValue.hasPrefix("40 photos") }, "no detail text for Trips: \(plTexts(section).map(\.stringValue))")
                #expect(!detail.isAccessibilityElement(), "the detail is an accessibility element")
                #expect(sxColour(detail.textColor, is: .secondaryLabelColor), "detail colour")
                #expect(sxFont(detail.font, size: 11.5, weight: .regular), "detail font \(String(describing: detail.font))")
                #expect(sxCard(of: detail) === sxCard(of: trips), "the detail is outside the row's card")
                #expect(plBox(root, detail).top >= (plBox(root, trips).top + plBox(root, trips).bottom) / 2 - 0.5, "the detail is not under the name")

                let extra = try #require(checks.first { $0.title == "Extra" })
                extra.performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                checks = sxChecks(root, section, env)
                let unticked = try #require(checks.first { $0.title == "Extra" })
                #expect(unticked.state == .off, "Extra after a press: state \(unticked.state.rawValue)")
                #expect(window.settingsScreen.folderRows.first { $0.name == "Extra" }?.tick.isOn == false)
                #expect(checks.filter { $0.title != "Extra" }.allSatisfy { $0.state == .on }, "another tick changed")
                unticked.performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                let reticked = try #require(sxChecks(root, section, env).first { $0.title == "Extra" })
                #expect(reticked.state == .on, "Extra after a second press: state \(reticked.state.rawValue)")
            }
        }

        @MainActor
        @Test func theInlineConfirmIsAGroupCardWithTheMessageCancelAtTheLeftAndAPlainConfirmAtTheRight() async throws {
            try await sxWith { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root), "no Folders section view")
                #expect(sxVisibleCards(section).count == 2, "the list card and the Add folder card before any Remove choice")
                #expect(sxButtons(section, titled: "Remove folder").isEmpty && sxButtons(section, titled: "Cancel").isEmpty, "the confirm is visible before a Remove choice")
                #expect(await smrChoose("Remove", folder: "Extra", in: root), "no Remove item under the more button of Extra")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFoldersSection(root))
                    let cards = sxVisibleCards(section)
                    #expect(cards.count == 3, "\(look): \(cards.count) visible cards with the confirm open")
                    let message = try #require(plText(section, sfRemoveMessageForExtra), "\(look): the message is not shown: \(plTexts(section).map(\.stringValue))")
                    let confirmCard = try #require(sxCard(of: message), "\(look): the message is in no card")
                    let rowsCard = try #require(sxChecks(root, section, env).first.flatMap { sxCard(of: $0) }, "\(look): no list card")
                    #expect(rowsCard !== confirmCard, "\(look): the confirm sits in the list card")
                    #expect(sxChecks(root, section, env).allSatisfy { sxCard(of: $0) === rowsCard }, "\(look): a row sits in another card")

                    let cancel = try #require(sxButtons(section, titled: "Cancel").first, "\(look): no Cancel")
                    let confirm = try #require(sxButtons(section, titled: "Remove folder").first, "\(look): no Remove folder")
                    #expect(sxButtons(section, titled: "Cancel").count == 1 && sxButtons(section, titled: "Remove folder").count == 1)
                    #expect(cancel.isDescendant(of: confirmCard) && confirm.isDescendant(of: confirmCard), "\(look): a button is outside the confirm card")
                    for button in [cancel, confirm] {
                        #expect(sxIsPlainPush(button), "\(look): \(button.title) is not a plain push button")
                        #expect(sxInks(button).allSatisfy { !sxColour($0, is: .systemRed) }, "\(look): \(button.title) is red")
                        #expect(button.isEnabled)
                    }
                    #expect(cancel.accessibilityLabel() == "Cancel" && confirm.accessibilityLabel() == "Remove folder")

                    let cardBox = plBox(root, confirmCard)
                    let cancelBox = sxAlignBox(root, cancel)
                    let confirmBox = sxAlignBox(root, confirm)
                    #expect(cancelBox.minX - cardBox.minX >= 12 && cancelBox.minX - cardBox.minX <= 28, "\(look): Cancel starts \(cancelBox.minX - cardBox.minX) pt from the card's left edge")
                    #expect(cardBox.maxX - confirmBox.maxX >= 12 && cardBox.maxX - confirmBox.maxX <= 28, "\(look): the confirm button ends \(cardBox.maxX - confirmBox.maxX) pt from the card's right edge")
                    #expect(cancelBox.maxX < confirmBox.minX, "\(look): Cancel is not left of the confirm button")
                    #expect(cancelBox.midX < cardBox.midX && confirmBox.midX > cardBox.midX, "\(look): Cancel and the confirm button are not on the two sides")
                    #expect(abs(cancelBox.top - confirmBox.top) <= 2 && abs(cancelBox.bottom - confirmBox.bottom) <= 2, "\(look): the two buttons are not in one row")

                    let messageBox = plBox(root, message)
                    #expect(messageBox.minX >= cardBox.minX + 13.5 && messageBox.maxX <= cardBox.maxX - 13.5, "\(look): the message spans \(messageBox.minX) to \(messageBox.maxX) in a card from \(cardBox.minX) to \(cardBox.maxX)")
                    #expect(!messageBox.intersects(plBox(root, cancel)) && !messageBox.intersects(plBox(root, confirm)), "\(look): the message overlaps a button")
                    #expect(messageBox.bottom <= plBox(root, cancel).top + 0.5, "\(look): the message is not above the buttons")
                    #expect(sxFont(message.font, size: 13, weight: .regular), "\(look): message font \(String(describing: message.font))")
                    #expect(sxColour(message.textColor, is: .labelColor), "\(look): message colour")
                    #expect(message.frame.height > 0 && messageBox.height <= 60, "\(look): the message is \(messageBox.height) pt tall")
                }
            }
        }

        @MainActor
        @Test func aSixtyCharacterNameStaysWholeAndAHundredTwentyCharacterPathNeverOverlapsTheMoreButtons() async throws {
            try await sxWith { window, env in
                #expect(sxLongName.count == 60, "the fixture name is \(sxLongName.count) characters")
                #expect(env.path(sxLongName).count >= 120, "the fixture path is \(env.path(sxLongName).count) characters")
                let root = sxLayout(window, .folders)
                let section = try #require(sxFoldersSection(root), "no Folders section view")
                let anchor: NSView = sxVisibleCards(section).first.map { $0 as NSView } ?? section
                let cardBox = plBox(root, anchor)
                let long = try #require(sxChecks(root, section, env).first { $0.title == sxLongName }, "no row named \(sxLongName)")
                let more = try #require(smrMoreButton(root, folder: sxLongName), "no more button for \(sxLongName)")
                #expect(long.accessibilityHelp() == env.path(sxLongName), "the long path is not the help in full")

                let titleWidth = (sxLongName as NSString).size(withAttributes: [.font: long.font ?? NSFont.systemFont(ofSize: 13)]).width
                #expect(long.frame.width >= titleWidth + 14, "the long name is \(long.frame.width) pt wide for \(titleWidth) pt of title: it was shortened")
                #expect([NSLineBreakMode.byTruncatingTail, .byTruncatingMiddle, .byTruncatingHead].contains(long.lineBreakMode), "line break mode \(long.lineBreakMode.rawValue)")
                #expect(long.frame.height <= 24, "the long name is \(long.frame.height) pt tall: it wraps")

                let longBox = plBox(root, long)
                #expect(longBox.maxX <= plBox(root, more).minX + 0.5, "the name ends at \(longBox.maxX), the more button starts at \(plBox(root, more).minX)")
                #expect(plBox(root, more).maxX <= cardBox.maxX - 13, "the more button ends at \(plBox(root, more).maxX), the card at \(cardBox.maxX)")

                let buttons = smrMoreButtons(root)
                #expect(buttons.count == 4, "\(buttons.count) more buttons")
                for part in sfTextBoxes(root, section, env) {
                    #expect(part.box.maxX <= cardBox.maxX - 13.5, "\(part.label) ends at \(part.box.maxX), the card at \(cardBox.maxX)")
                    for button in buttons {
                        #expect(!part.box.intersects(plBox(root, button)), "\(part.label) overlaps a more button")
                    }
                }
                for field in sfOwnTexts(section) where field.stringValue != "Folders" {
                    if field.stringValue != sfTitle && field.stringValue != sfNote {
                        #expect([NSLineBreakMode.byTruncatingTail, .byTruncatingMiddle, .byTruncatingHead].contains(field.lineBreakMode), "\"\(field.stringValue)\": line break mode \(field.lineBreakMode.rawValue)")
                    }
                    #expect(field.frame.height <= 24, "\"\(field.stringValue)\" is \(field.frame.height) pt tall: it wraps")
                }
            }
        }

        @MainActor
        @Test func theErrorLineCarriesTheWarningSymbolBesideTheExistingText() async throws {
            try await sxWith { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root), "no Folders section view")
                #expect(plText(section, sfSaveError) == nil, "an error before anything went wrong")
                #expect(plAccessibilityImages(section).filter { plVisible($0) }.isEmpty, "a warning symbol before anything went wrong")
                let extra = try #require(sxChecks(root, section, env).first { $0.title == "Extra" })
                #expect(await sxProvokeSaveError(pressing: extra), "could not make a failed write")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFoldersSection(root))
                    let text = try #require(plText(section, sfSaveError), "\(look): the error text is not shown: \(plTexts(section).map(\.stringValue))")
                    let symbols = plAccessibilityImages(section).filter { plVisible($0) }
                    #expect(symbols.count == 1, "\(look): \(symbols.count) accessibility images")
                    let symbol = try #require(symbols.first)
                    #expect(symbol.accessibilityLabel() == "Warning", "\(look): symbol label \"\(symbol.accessibilityLabel() ?? "nil")\"")
                    #expect(symbol.accessibilityRole() == .image)
                    #expect(symbol is NSImageView, "\(look): the symbol is a \(type(of: symbol))")
                    #expect((symbol as? NSImageView)?.isEnabled == false, "\(look): the warning symbol is an enabled control")
                    let symbolBox = plBox(root, symbol)
                    let textBox = plBox(root, text)
                    #expect(symbolBox.maxX <= textBox.minX + 0.5, "\(look): the symbol ends at \(symbolBox.maxX), the text starts at \(textBox.minX)")
                    #expect(symbolBox.top < textBox.bottom && textBox.top < symbolBox.bottom, "\(look): the symbol and the text share no line")
                    let sectionBox = plBox(root, section)
                    #expect(symbolBox.minX >= sectionBox.minX - 0.5 && textBox.maxX <= sectionBox.maxX + 0.5, "\(look): the error line leaves the section")
                    let images = prViews(section).compactMap { $0 as? NSImageView }.filter { plVisible($0) }
                    #expect(images.allSatisfy { !$0.isEnabled }, "\(look): an enabled NSImageView in the section")
                }
            }
        }

        @MainActor
        @Test func theErrorRowCarriesASeparateTryAgainInAMomentLineUnderTheMessage() async throws {
            try await sxWith { window, env in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root), "no Folders section view")
                syExpectNoWarning(section, .light)
                let extra = try #require(sxChecks(root, section, env).first { $0.title == "Extra" })
                #expect(await sxProvokeSaveError(pressing: extra), "could not make a failed write")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFoldersSection(root))
                    syExpectWarningLine(root, section, text: sfSaveError, red: false, look)
                }
            }
        }

        @MainActor
        @Test func withNoFoldersTheEmptyTextShowsInSecondaryColourWithAddFolderAndNoRow() async throws {
            try await sxWith([]) { window, env in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let section = try #require(sxFoldersSection(root), "no Folders section view")
                    let text = try #require(plText(section, sfNoFolders), "\(look): the empty text is not shown: \(plTexts(section).map(\.stringValue))")
                    #expect(sxColour(text.textColor, is: .secondaryLabelColor), "\(look): empty text colour")
                    #expect(sxChecks(root, section, env).isEmpty)
                    #expect(sxButtons(section, titled: "Re-index").isEmpty && sxButtons(section, titled: "Remove").isEmpty, "\(look): a row button without a row")
                    #expect(smrMoreButtons(root).isEmpty, "\(look): a more button without a row")
                    #expect(sxButtons(section, titled: "Add folder\u{2026}").count == 1, "\(look): Add folder is missing")
                    let cards = sxVisibleCards(section)
                    #expect(cards.count == 1 && sxButtons(section, titled: "Add folder\u{2026}").first.flatMap { sxCard(of: $0) } === cards.first, "\(look): Add folder is not alone in its card: \(cards.count) cards")
                    #expect(plText(section, sfNote) != nil, "\(look): the note is missing: \(plTexts(section).map(\.stringValue))")
                    #expect(!prViews(section).contains { $0 is NSScrollView }, "\(look): a scroll view inside the Folders section")
                    #expect(plTexts(section).filter { $0.stringValue == "Folders" }.isEmpty, "\(look): the section draws its own \"Folders\" heading")
                }
            }
        }
    }
}

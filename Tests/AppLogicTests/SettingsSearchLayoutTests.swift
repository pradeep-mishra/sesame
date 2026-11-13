import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let sqPdfInstalled = "com.apple.Preview"
private let sqMediaInstalled = "com.apple.QuickTimePlayerX"
private let sqRecord = "Record new shortcut"
private let sqBack = "Back to default"
private let sqDefaultShortcut = "Control Option Space"
private let sqMessage = "That key can't be used as a shortcut. Pick another."
private let sqNotice = "The shortcut Command Space is taken by another app, so Sesame is using Control Option Space."
private let sqSaveError = "Could not save your settings."
private let sqPreviewNote = "Preview is not installed. Enter opens the file in the default app."
private let sqSkimNote = "Skim is not installed. Enter opens the file in the default app."

@MainActor
private func sqCards(_ root: NSView, _ section: NSView) -> [GroupCard] {
    sxVisibleCards(section).sorted { plBox(root, $0).top < plBox(root, $1).top }
}

extension ModelDownloadTests {
    @Suite("SettingsSearchLayoutTests", .serialized)
    struct SettingsSearchLayoutTests {

        @MainActor
        @Test func theShortcutCardIsAboveTheAppsCardTheTwoSpanTheSectionAndHugTheirContent() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .search, look)
                    let section = try #require(sySearchSection(root), "no Search section view")
                    #expect(plVisible(section))
                    let cards = sqCards(root, section)
                    #expect(cards.count == 2, "\(look): \(cards.count) visible GroupCards in the Search section")
                    guard cards.count == 2 else { continue }
                    let shortcutCard = cards[0]
                    let appsCard = cards[1]
                    let sectionBox = plBox(root, section)
                    for card in cards {
                        let box = plBox(root, card)
                        #expect(abs(box.minX - sectionBox.minX) <= 1 && abs(box.maxX - sectionBox.maxX) <= 1, "\(look): a card spans \(box.minX) to \(box.maxX), the section \(sectionBox.minX) to \(sectionBox.maxX)")
                        #expect(abs(box.minX - 197) <= 1 && abs(box.maxX - 704) <= 1, "\(look): a card spans \(box.minX) to \(box.maxX)")
                    }
                    #expect(plBox(root, shortcutCard).bottom <= plBox(root, appsCard).top + 0.5, "\(look): the shortcut card is not above the apps card")
                    for card in cards { syExpectHugs(root, card, look) }

                    for popup in syPopUps(section) {
                        #expect(sxCard(of: popup) === appsCard, "\(look): a pop-up is outside the apps card")
                    }
                    syExpectNoWarning(section, look)
                }
            }
        }

        @MainActor
        @Test func openFilesWithIsAThirteenSemiboldGroupLabelAboveACardOfTwoAlignedFormRows() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .search, look)
                    let section = try #require(sySearchSection(root), "no Search section view")
                    let cards = sqCards(root, section)
                    guard cards.count == 2 else {
                        Issue.record("\(look): \(cards.count) visible cards in Search")
                        continue
                    }
                    let appsCard = cards[1]
                    let cardBox = plBox(root, appsCard)

                    let groupLabels = plTexts(section).filter { $0.stringValue == "Open files with" }
                    #expect(groupLabels.count == 1, "\(look): \(groupLabels.count) group labels")
                    let groupLabel = try #require(groupLabels.first)
                    #expect(sxFont(groupLabel.font, size: 13, weight: .semibold), "\(look): group label font \(String(describing: groupLabel.font))")
                    let groupBox = sxAlignBox(root, groupLabel)
                    #expect(groupBox.bottom <= cardBox.top + 0.5 && cardBox.top - groupBox.bottom <= 20, "\(look): the group label ends \(cardBox.top - groupBox.bottom) pt above the card")
                    #expect(groupBox.minX >= cardBox.minX - 0.5 && groupBox.minX <= cardBox.minX + 16.5, "\(look): the group label starts \(groupBox.minX - cardBox.minX) pt inside the card's edge")
                    #expect(!(groupLabel.superview is GroupCard) && sxCard(of: groupLabel) == nil, "\(look): the group label is inside a card")

                    let popups = syPopUps(section)
                    #expect(popups.count == 2, "\(look): \(popups.count) pop-ups")
                    let pdf = try #require(syPopUp(section, labelled: "PDF app"), "\(look): no PDF app pop-up")
                    let media = try #require(syPopUp(section, labelled: "Media app"), "\(look): no Media app pop-up")
                    #expect(pdf is SettingsPopUp && media is SettingsPopUp, "\(look): a pop-up is not a SettingsPopUp")
                    #expect(pdf.itemTitles == ["Preview", "Adobe Acrobat", "Skim"], "\(look): PDF items \(pdf.itemTitles)")
                    #expect(media.itemTitles == ["QuickTime Player", "IINA", "VLC"], "\(look): Media items \(media.itemTitles)")
                    #expect(pdf.isEnabled && media.isEnabled)

                    let pdfLabel = try #require(plText(section, "PDF app"), "\(look): no PDF app text")
                    let mediaLabel = try #require(plText(section, "Media app"), "\(look): no Media app text")
                    #expect(!pdfLabel.isAccessibilityElement() && !mediaLabel.isAccessibilityElement(), "\(look): a row label is an accessibility element")

                    let pdfBox = sxAlignBox(root, pdf)
                    let mediaBox = sxAlignBox(root, media)
                    #expect(abs(pdfBox.width - 200) <= 1 && abs(mediaBox.width - 200) <= 1, "\(look): pop-up widths \(pdfBox.width) and \(mediaBox.width)")
                    #expect(abs(pdfBox.minX - mediaBox.minX) <= 0.5, "\(look): the pop-ups start at \(pdfBox.minX) and \(mediaBox.minX)")
                    #expect(mediaBox.top - pdfBox.top >= 40 - 0.5, "\(look): the rows are \(mediaBox.top - pdfBox.top) pt apart")

                    for (label, popup) in [(pdfLabel, pdf), (mediaLabel, media)] {
                        #expect(sxCard(of: label) === appsCard && sxCard(of: popup) === appsCard, "\(look): \(label.stringValue) is not in the apps card")
                        let labelBox = sxAlignBox(root, label)
                        let box = sxAlignBox(root, popup)
                        #expect(labelBox.minX - cardBox.minX >= 13 && labelBox.minX - cardBox.minX <= 15, "\(look): \(label.stringValue) starts \(labelBox.minX - cardBox.minX) pt inside the card")
                        #expect(box.minX - labelBox.minX >= 139 && box.minX - labelBox.minX <= 141, "\(look): \(label.stringValue): the pop-up starts \(box.minX - labelBox.minX) pt after its label")
                        #expect(labelBox.maxX <= box.minX + 0.5, "\(look): \(label.stringValue) runs into its pop-up")
                        #expect(abs((labelBox.top + labelBox.bottom) / 2 - (box.top + box.bottom) / 2) <= 4, "\(look): \(label.stringValue) and its pop-up are not on one line")
                        #expect(box.maxX <= cardBox.maxX - 13.5, "\(look): the pop-up ends at \(box.maxX), the card at \(cardBox.maxX)")
                    }

                    let separators = prViews(appsCard).filter { $0 !== appsCard && $0.frame.height > 0 && $0.frame.height <= 1 && $0.frame.width >= cardBox.width - 14 - 0.5 }
                    #expect(separators.count == 1, "\(look): \(separators.count) separators for two rows")
                    for separator in separators {
                        let box = plBox(root, separator)
                        #expect(abs((box.minX - cardBox.minX) - 14) <= 1 && abs(cardBox.maxX - box.maxX) <= 1, "\(look): the separator spans \(box.minX - cardBox.minX) to \(cardBox.maxX - box.maxX) in from the card's edges")
                    }
                }
            }
        }

        @MainActor
        @Test func aNotInstalledAppShowsItsNoteInSecondaryTextUnderItsRowAndTheNoteFollowsAPick() async throws {
            let services = SYServices(installed: [sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                var root = sxLayout(window, .search)
                var section = try #require(sySearchSection(root), "no Search section view")
                #expect(plTexts(section).filter { $0.stringValue.contains("is not installed") }.count == 1, "notes shown: \(plTexts(section).map(\.stringValue))")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sySearchSection(root))
                    let note = try #require(plText(section, sqPreviewNote), "\(look): the note is not shown: \(plTexts(section).map(\.stringValue))")
                    let pdf = try #require(syPopUp(section, labelled: "PDF app"))
                    let media = try #require(syPopUp(section, labelled: "Media app"))
                    let label = try #require(plText(section, "PDF app"))
                    #expect(sxColour(note.textColor, is: .secondaryLabelColor), "\(look): note colour")
                    #expect(sxFont(note.font, size: 12, weight: .regular), "\(look): note font \(String(describing: note.font))")
                    let cards = sqCards(root, section)
                    #expect(cards.count == 2 && sxCard(of: note) === cards.last, "\(look): the note is not in the apps card")
                    let noteBox = sxAlignBox(root, note)
                    let pdfBox = sxAlignBox(root, pdf)
                    let mediaBox = sxAlignBox(root, media)
                    #expect(noteBox.top >= pdfBox.bottom - 0.5, "\(look): the note starts \(noteBox.top) above the end of its row \(pdfBox.bottom)")
                    #expect(noteBox.bottom <= mediaBox.top + 0.5, "\(look): the note ends at \(noteBox.bottom), the next row starts at \(mediaBox.top)")
                    #expect(noteBox.minX >= sxAlignBox(root, label).minX - 0.5, "\(look): the note starts left of its row's label")
                    if let card = cards.last {
                        let cardBox = plBox(root, card)
                        #expect(noteBox.maxX <= cardBox.maxX - 15.5, "\(look): the note ends at \(noteBox.maxX), the card at \(cardBox.maxX)")
                    }
                }

                let pdf = try #require(syPopUp(section, labelled: "PDF app"))
                #expect(await syChoose("Skim", in: pdf))
                root = sxRelayout(window)
                section = try #require(sySearchSection(root))
                #expect(plText(section, sqSkimNote) != nil, "after a pick of Skim: \(plTexts(section).map(\.stringValue))")
                #expect(plText(section, sqPreviewNote) == nil, "the old note is still shown")
            }
        }

        @MainActor
        @Test func aPickInEachPopUpIsSavedAndStaysSelected() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                var root = sxLayout(window, .search)
                var section = try #require(sySearchSection(root), "no Search section view")
                let pdf = try #require(syPopUp(section, labelled: "PDF app"))
                let media = try #require(syPopUp(section, labelled: "Media app"))
                let pickedPdf = await syChoose("Skim", in: pdf)
                let pickedMedia = await syChoose("IINA", in: media)
                #expect(pickedPdf && pickedMedia)
                root = sxRelayout(window)
                section = try #require(sySearchSection(root))
                #expect(syPopUp(section, labelled: "PDF app")?.titleOfSelectedItem == "Skim")
                #expect(syPopUp(section, labelled: "Media app")?.titleOfSelectedItem == "IINA")
                let settings = try SettingsFile().read()
                #expect(settings.openWith.pdf == "Skim", "pdf stored as \(settings.openWith.pdf)")
                #expect(settings.openWith.media == "IINA", "media stored as \(settings.openWith.media)")
            }
        }

        @MainActor
        @Test func theSectionDrawsNoHeadingOfItsOwnNoScrollBoxAndOnlyDisabledImages() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .search, look)
                    let section = try #require(sySearchSection(root), "no Search section view")
                    syExpectPlainSection(root, section, name: "Search", look)
                    syExpectNoWarning(section, look)
                }
            }
        }

        @MainActor
        @Test func theShortcutMessageCarriesTheWarningSymbolOutsideEveryCardUnderTheShortcutCardAndTheNextStepLine() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                var root = sxLayout(window, .search)
                var section = try #require(sySearchSection(root), "no Search section view")
                syExpectNoWarning(section, .light)
                let shortcut = try #require(services.shortcut)
                shortcut.refuseUnnamedKey()

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sySearchSection(root))
                    syExpectWarningLine(root, section, text: sqMessage, red: true, look)
                    let message = try #require(plText(section, sqMessage))
                    #expect(sxCard(of: message) == nil, "\(look): the message is inside a card")
                    let cards = sqCards(root, section)
                    #expect(cards.count == 2, "\(look): \(cards.count) visible cards in Search")
                    if let shortcutCard = cards.first {
                        #expect(sxAlignBox(root, message).top >= plBox(root, shortcutCard).bottom, "\(look): the message is not under the shortcut card")
                    }
                    let keys = prViews(section).compactMap { $0 as? KeycapRow }.filter { plVisible($0) }
                    #expect(keys.count == 1, "\(look): \(keys.count) keycap rows")
                    #expect(keys.first?.isAccessibilityElement() == true && keys.first?.accessibilityRole() == .group, "\(look): the keycaps are not one group")
                    #expect(keys.first?.accessibilityLabel() == sqDefaultShortcut, "\(look): the keycaps group is labelled \"\(keys.first?.accessibilityLabel() ?? "nil")\"")
                }

                shortcut.clearMessage()
                root = sxRelayout(window)
                section = try #require(sySearchSection(root))
                #expect(plText(section, sqMessage) == nil, "the message stayed after it was cleared")
                syExpectNoWarning(section, .light)
            }
        }

        @MainActor
        @Test func theShortcutNoticeCarriesTheWarningSymbolAndTheNextStepLine() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled], adoptNotice: true)
            try await sxWithWindow([], make: services.window) { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .search, look)
                    let section = try #require(sySearchSection(root), "no Search section view")
                    syExpectWarningLine(root, section, text: sqNotice, red: false, look)
                }
            }
        }

        @MainActor
        @Test func aFailedPickCarriesTheWarningSymbolBesideTheExistingTextAndTheNextStepLine() async throws {
            let services = SYServices(installed: [sqPdfInstalled, sqMediaInstalled])
            try await sxWithWindow([], make: services.window) { window, _ in
                var root = sxLayout(window, .search)
                var section = try #require(sySearchSection(root), "no Search section view")
                #expect(plText(section, sqSaveError) == nil, "an error before anything went wrong")
                let pdf = try #require(syPopUp(section, labelled: "PDF app"))
                #expect(await syProvokePickError("Skim", in: pdf), "could not make a failed write")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sySearchSection(root))
                    syExpectWarningLine(root, section, text: sqSaveError, red: true, look)
                }

                window.select(.search)
                root = sxRelayout(window)
                section = try #require(sySearchSection(root))
                #expect(plText(section, sqSaveError) == nil, "the error stayed after the section was opened again")
                syExpectNoWarning(section, .light)
            }
        }
    }
}

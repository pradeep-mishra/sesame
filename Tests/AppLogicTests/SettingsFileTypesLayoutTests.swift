import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let ftKinds = ["Photos", "PDFs", "Documents", "Audio", "Video"]
private let ftSaveError = "Could not save your settings."
private let ftSectionTitle = "File types Sesame reads"

@MainActor
private func ftKindButtons(_ root: NSView, _ section: NSView) -> [NSSwitch] {
    prViews(section)
        .compactMap { $0 as? NSSwitch }
        .filter { plVisible($0) && ftKinds.contains($0.accessibilityLabel() ?? "") }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func ftName(_ kind: NSSwitch) -> String {
    kind.accessibilityLabel() ?? ""
}

extension ModelDownloadTests {
    @Suite("SettingsFileTypesLayoutTests", .serialized)
    struct SettingsFileTypesLayoutTests {

        @MainActor
        @Test func theFiveKindsSitInOneGroupCardInOrderWithNoBezelBoxAndNoHeadingOfTheirOwn() async throws {
            try await sxWith { window, _ in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .fileTypes, look)
                    let section = try #require(sxFileTypesSection(root), "no File types section view")
                    #expect(plVisible(section))

                    let cards = sxVisibleCards(section)
                    #expect(cards.count == 1, "\(look): \(cards.count) visible GroupCards in the File types section")
                    #expect(!prViews(section).contains { $0 is NSScrollView }, "\(look): a scroll view inside the File types section")
                    #expect(!prViews(section).contains { $0 is NSBox }, "\(look): an NSBox inside the File types section")

                    let kinds = ftKindButtons(root, section)
                    #expect(kinds.map(ftName) == ftKinds, "\(look): kinds drawn \(kinds.map(ftName))")
                    #expect(kinds.count == 5 && sxVisibleButtons(section).isEmpty, "\(look): \(kinds.count) NSSwitch and \(sxVisibleButtons(section).count) buttons in the section: \(sxVisibleButtons(section).map(\.title))")
                    #expect(plTexts(section).filter { $0.stringValue == "File types" }.isEmpty, "\(look): the section draws its own \"File types\" heading")
                    let titled = plTexts(section).filter { $0.font?.pointSize == 17 }
                    #expect(titled.isEmpty, "\(look): the section draws a 17 pt text")
                    let sectionTitle = plText(section, ftSectionTitle)
                    #expect(sectionTitle != nil && sxFont(sectionTitle?.font, size: 13, weight: .semibold), "\(look): the section title is \(String(describing: sectionTitle?.font))")
                    guard let card = cards.first, let first = kinds.first, let last = kinds.last else { continue }
                    for kind in kinds {
                        #expect(sxCard(of: kind) === card, "\(look): \(ftName(kind)) is not in the card")
                    }

                    let cardBox = plBox(root, card)
                    let sectionBox = plBox(root, section)
                    #expect(abs(cardBox.minX - sectionBox.minX) <= 1 && abs(cardBox.maxX - sectionBox.maxX) <= 1,
                            "\(look): card spans \(cardBox.minX) to \(cardBox.maxX), the section \(sectionBox.minX) to \(sectionBox.maxX)")
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): card spans \(cardBox.minX) to \(cardBox.maxX)")

                    let firstGap = plBox(root, first).top - cardBox.top
                    #expect(firstGap >= 0 && firstGap <= 20, "\(look): the first kind starts \(firstGap) pt below the top of the card")
                    let lastGap = cardBox.bottom - plBox(root, last).bottom
                    #expect(lastGap >= 0 && lastGap <= 20, "\(look): the last kind ends \(lastGap) pt above the bottom of the card")

                    let tops = kinds.map { plBox(root, $0).top }
                    for (index, pair) in zip(tops, tops.dropFirst()).enumerated() {
                        #expect(pair.1 - pair.0 >= 40 - 0.5, "\(look): kinds \(index) and \(index + 1) are \(pair.1 - pair.0) pt apart")
                    }
                    #expect(cardBox.height >= 200 - 0.5, "\(look): the card is \(cardBox.height) pt tall for five rows")

                    let separators = prViews(card).filter { $0 !== card && $0.frame.height > 0 && $0.frame.height <= 1 && $0.frame.width >= cardBox.width - 14 - 0.5 }
                    #expect(separators.count == 4, "\(look): \(separators.count) separators for five rows")
                }
            }
        }

        @MainActor
        @Test func eachKindIsAnNSSwitchWithItsLabelAndAPressSavesTheChoice() async throws {
            try await sxWith { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                #expect(prViews(section).compactMap { $0 as? NSSwitch }.count == 5, "\(prViews(section).compactMap { $0 as? NSSwitch }.count) NSSwitch in the File types section")
                #expect(sxVisibleButtons(section).isEmpty, "a button in the File types section: \(sxVisibleButtons(section).map(\.title))")
                var kinds = ftKindButtons(root, section)
                #expect(kinds.map(ftName) == ftKinds, "labels \(kinds.map(ftName))")
                for kind in kinds {
                    #expect(kind.state == .on, "\(ftName(kind)): state \(kind.state.rawValue)")
                    #expect(kind.isEnabled)
                }

                let photos = try #require(kinds.first { ftName($0) == "Photos" })
                photos.performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(sxFileTypesSection(root))
                kinds = ftKindButtons(root, section)
                #expect(kinds.first { ftName($0) == "Photos" }?.state == .off, "Photos after a press")
                #expect(kinds.filter { ftName($0) != "Photos" }.allSatisfy { $0.state == .on }, "another kind changed")
                #expect(try SettingsFile().read().kindsOn["photo"] == false, "the press was not saved")

                try #require(kinds.first { ftName($0) == "Photos" }).performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(sxFileTypesSection(root))
                #expect(ftKindButtons(root, section).first { ftName($0) == "Photos" }?.state == .on, "Photos after a second press")
                #expect(try SettingsFile().read().kindsOn["photo"] == true, "the second press was not saved")
            }
        }

        @MainActor
        @Test func theErrorLineCarriesTheWarningSymbolBesideTheExistingText() async throws {
            try await sxWith { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                #expect(plText(section, ftSaveError) == nil, "an error before anything went wrong")
                #expect(plAccessibilityImages(section).filter { plVisible($0) }.isEmpty, "a warning symbol before anything went wrong")
                let video = try #require(ftKindButtons(root, section).first { ftName($0) == "Video" })
                #expect(await sxProvokeSaveError(pressing: video), "could not make a failed write")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFileTypesSection(root))
                    let text = try #require(plText(section, ftSaveError), "\(look): the error text is not shown: \(plTexts(section).map(\.stringValue))")
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
            try await sxWith { window, _ in
                var root = sxLayout(window, .fileTypes)
                var section = try #require(sxFileTypesSection(root), "no File types section view")
                syExpectNoWarning(section, .light)
                let video = try #require(ftKindButtons(root, section).first { ftName($0) == "Video" })
                #expect(await sxProvokeSaveError(pressing: video), "could not make a failed write")

                for look in DTLook.allCases {
                    root = sxRelayout(window, look)
                    section = try #require(sxFileTypesSection(root))
                    syExpectWarningLine(root, section, text: ftSaveError, red: false, look)
                }
            }
        }
    }
}

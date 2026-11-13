import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let suLogin = "Launch at login"
private let suLoginNote = "The shortcut works only while Sesame is running."
private let suListTitle = "Files Sesame could not read"
private let suEmpty = "Nothing here. Files Sesame could not read are listed here."
private let suLongName = String(repeating: "abcdefghij", count: 11) + "klmnop.jpg"

private struct SURow {
    let name: String
    let reason: String
    let stored: String
}

private let suRows = [
    SURow(name: suLongName, reason: "Damaged", stored: suLongName + ", damaged"),
    SURow(name: "locked.jpg", reason: "Needs permission", stored: "locked.jpg, needs permission"),
    SURow(name: "broken.jpg", reason: "Damaged", stored: "broken.jpg, damaged"),
]

@MainActor
private func suWith(
    glass: Bool,
    _ body: @MainActor (SettingsContainerWindow) async throws -> Void
) async throws {
    try await sxWithWindow([], make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: SYLoginService()),
            appChoices: AppChoices(lookup: SYLookup(installed: [])),
            deleteIndex: DeleteIndex(closeIndex: {}, sendReset: {}, deleteCaches: {}), glass: glass)
    }) { window, _ in try await body(window) }
}

@MainActor
private func suAdd(_ store: IndexStore, _ path: String, status: String, reason: String?, inode: Int64) throws {
    _ = try store.addFile(path: path, kind: "photo", size: 100, mtimeNs: 1_700_000_000_000_000_000, inode: inode, device: 1, status: status)
    guard let reason else { return }
    let queue = try store.pendingPhotos(limit: 50)
    let row = try #require(queue.first { $0.path == path }, "setup: pendingPhotos does not list \(path)")
    _ = try store.markCouldNotRead(row, reason: reason)
}

@MainActor
private func suFillMain(_ store: IndexStore) throws {
    try suAdd(store, "/photos/locked.jpg", status: "needs_permission", reason: nil, inode: 1)
    try suAdd(store, "/photos/trip/broken.jpg", status: "pending", reason: "damaged", inode: 2)
    try suAdd(store, "/photos/" + suLongName, status: "pending", reason: "damaged", inode: 3)
    try suAdd(store, "/photos/fine.jpg", status: "done", reason: nil, inode: 4)
}

@MainActor
private func suSection(_ window: SettingsContainerWindow, _ look: DTLook = .light) throws -> (NSView, SettingsIndexingView) {
    let root = sxLayout(window, .indexing, look)
    return (root, try #require(syIndexingSection(root), "no Indexing section view"))
}

@MainActor
private func suField(_ section: NSView, _ text: String) -> NSTextField? {
    let fields = plTexts(section).filter { $0.stringValue == text }
    return fields.count == 1 ? fields.first : nil
}

@MainActor
private func suRowElements(_ section: NSView) -> [NSView] {
    prViews(section).filter { plVisible($0) && $0.isAccessibilityElement() && $0.accessibilityRole() == .staticText }
}

@MainActor
private func suHairlines(_ root: NSView, _ card: GroupCard) -> [NSView] {
    let width = plBox(root, card).width
    return prViews(card)
        .filter { $0 !== card && plVisible($0) && $0.frame.height > 0 && $0.frame.height <= 1.01 && $0.frame.width >= width - 14 - 0.5 }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

private func suMid(_ box: PLBox) -> CGFloat {
    (box.top + box.bottom) / 2
}

@MainActor
private func suPosition(_ root: NSView, _ view: NSView) -> (CGFloat, CGFloat) {
    let box = plBox(root, view)
    return (box.top.rounded(), box.minX)
}

@MainActor
private func suRowExtents(_ root: NSView, _ card: GroupCard, _ lines: [NSView], count: Int) -> [(top: CGFloat, bottom: CGFloat)] {
    let cardBox = plBox(root, card)
    let mids = lines.map { suMid(plBox(root, $0)) }
    return (0..<count).map { index in
        (top: index == 0 ? cardBox.top : mids[index - 1], bottom: index == count - 1 ? cardBox.bottom : mids[index])
    }
}

@MainActor
private func suNaturalWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
}

extension ModelDownloadTests {
    @Suite("SettingsIndexingUnreadableTests", .serialized)
    struct SettingsIndexingUnreadableTests {

        @MainActor
        @Test(arguments: slPaths)
        func withNoUnreadableFileTheEmptyTextIsOneRowOfThirteenRegularSecondaryInTheListCardWithNoRowElement(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    let empty = try #require(suField(section, suEmpty), "\(look): the empty text is not shown once: \(plTexts(section).map(\.stringValue))")
                    #expect(sxColour(empty.textColor, is: .secondaryLabelColor), "\(look): empty text colour")
                    #expect(sxFont(empty.font, size: 13, weight: .regular), "\(look): empty text font \(String(describing: empty.font))")
                    let card = try #require(sxCard(of: empty), "\(look): the empty text is in no card")
                    let inside = plTexts(section).filter { sxCard(of: $0) === card }.map(\.stringValue)
                    #expect(inside == [suEmpty], "\(look): texts in the list card \(inside)")
                    #expect(suHairlines(root, card).isEmpty, "\(look): a hairline in the empty list card")
                    #expect(suRowElements(section).isEmpty, "\(look): a row element with nothing to list: \(suRowElements(section).map { $0.accessibilityLabel() ?? "nil" })")
                    let cardBox = plBox(root, card)
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): the list card spans \(cardBox.minX) to \(cardBox.maxX)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func eachUnreadableFileIsOneRowInOneHuggingSettingsCardSpanning197To704EachRowFortyFourToSixtyTallAndAllTheSameHeight(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suFillMain(store)
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    #expect(plText(section, suEmpty) == nil, "\(look): the empty text is shown beside rows")
                    let names = try suRows.map { try #require(suField(section, $0.name), "\(look): no single text \"\($0.name)\": \(plTexts(section).map(\.stringValue))") }
                    let card = try #require(sxCard(of: names[0]), "\(look): the first name is in no card")
                    for field in names { #expect(sxCard(of: field) === card, "\(look): \"\(field.stringValue)\" is in another card") }
                    #expect(card.layer?.cornerRadius == 12 && abs((card.layer?.borderWidth ?? 0) - 0.5) <= 0.01, "\(look): the list card is not a settings card")
                    let cardBox = plBox(root, card)
                    #expect(abs(cardBox.minX - 197) <= 1 && abs(cardBox.maxX - 704) <= 1, "\(look): the list card spans \(cardBox.minX) to \(cardBox.maxX)")
                    syExpectHugs(root, card, look)

                    let lines = suHairlines(root, card)
                    #expect(lines.count == 2, "\(look): \(lines.count) hairlines for three rows")
                    guard lines.count == 2 else { continue }
                    let extents = suRowExtents(root, card, lines, count: 3)
                    let heights = extents.map { $0.bottom - $0.top }
                    for (index, height) in heights.enumerated() {
                        #expect(height >= 44 - 0.5 && height <= 60 + 0.5, "\(look): row \(index) is \(height) tall")
                    }
                    #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= 1, "\(look): the rows differ in height \(heights)")

                    let reasons = plTexts(section).filter { sxCard(of: $0) === card && !suRows.map(\.name).contains($0.stringValue) }.sorted { plBox(root, $0).top < plBox(root, $1).top }
                    #expect(reasons.count == 3, "\(look): \(reasons.count) reason fields: \(reasons.map(\.stringValue))")
                    guard reasons.count == 3 else { continue }
                    let elements = suRowElements(section)
                    for (index, row) in suRows.enumerated() {
                        let element = elements.first { ($0.accessibilityLabel() ?? "") == row.stored }
                        guard let element else {
                            Issue.record("\(look): no row element labelled \"\(row.stored)\": \(elements.map { $0.accessibilityLabel() ?? "nil" })")
                            continue
                        }
                        let box = plBox(root, element)
                        let name = plBox(root, names[index])
                        let reasonBox = plBox(root, reasons[index])
                        #expect(box.minX <= name.minX + 1 && box.maxX >= name.maxX - 1 && box.top <= name.top + 1 && box.bottom >= reasonBox.bottom - 1, "\(look): the row element of \"\(row.stored)\" does not hold its name and reason")
                        #expect(box.top >= extents[index].top - 1 && box.bottom <= extents[index].bottom + 1, "\(look): the row element of \"\(row.stored)\" leaves its row")
                        #expect(sxCard(of: element) === card, "\(look): the row element of \"\(row.stored)\" is in another card")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func eachRowIsTheNameOverItsReasonBothOnTheCardPaddingWithALongNameShortenedInTheMiddleAndItsReasonWhole(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suFillMain(store)
                let longNatural = suNaturalWidth(suLongName, size: 12.5, weight: .semibold)
                let reasonNatural = suNaturalWidth("Damaged", size: 11.5, weight: .regular)
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    let names = try suRows.map { try #require(suField(section, $0.name), "\(look): no single text \"\($0.name)\"") }
                    let card = try #require(sxCard(of: names[0]), "\(look): the first name is in no card")
                    let cardBox = plBox(root, card)
                    let reasons = plTexts(section).filter { sxCard(of: $0) === card && !suRows.map(\.name).contains($0.stringValue) }.sorted { plBox(root, $0).top < plBox(root, $1).top }
                    #expect(reasons.map(\.stringValue) == ["Damaged", "Needs permission", "Damaged"], "\(look): reason fields \(reasons.map(\.stringValue))")
                    guard reasons.count == 3 else { continue }
                    let ordered = names.sorted { plBox(root, $0).top < plBox(root, $1).top }
                    #expect(ordered.map(\.stringValue) == suRows.map(\.name), "\(look): name order \(ordered.map(\.stringValue))")
                    for (index, name) in ordered.enumerated() {
                        let reason = reasons[index]
                        let tag = "\(look) \"\(name.stringValue)\""
                        #expect(sxFont(name.font, size: 12.5, weight: .semibold), "\(tag): name font \(String(describing: name.font))")
                        #expect(sxColour(name.textColor, is: .labelColor), "\(tag): name colour")
                        #expect(name.lineBreakMode == .byTruncatingMiddle, "\(tag): name line break mode \(name.lineBreakMode.rawValue)")
                        #expect(name.frame.height <= 24, "\(tag): the name is \(name.frame.height) tall: it wraps")
                        #expect(sxFont(reason.font, size: 11.5, weight: .regular), "\(tag): reason font \(String(describing: reason.font))")
                        #expect(sxColour(reason.textColor, is: .secondaryLabelColor), "\(tag): reason colour")
                        #expect(reason.lineBreakMode != .byWordWrapping && reason.lineBreakMode != .byCharWrapping, "\(tag): the reason wraps (line break mode \(reason.lineBreakMode.rawValue))")
                        #expect(reason.frame.height <= 24, "\(tag): the reason is \(reason.frame.height) tall: it wraps")

                        let nameBox = sxAlignBox(root, name)
                        let reasonBox = sxAlignBox(root, reason)
                        #expect(abs((nameBox.minX - cardBox.minX) - 14) <= 1, "\(tag): the name starts \(nameBox.minX - cardBox.minX) in from the card's left edge")
                        #expect(nameBox.maxX <= cardBox.maxX - 13.5, "\(tag): the name ends \(cardBox.maxX - nameBox.maxX) from the card's right edge")
                        #expect(abs(reasonBox.minX - nameBox.minX) <= 0.5, "\(tag): the reason starts at \(reasonBox.minX), the name at \(nameBox.minX)")
                        #expect(reasonBox.top - nameBox.bottom >= 1 - 0.5 && reasonBox.top - nameBox.bottom <= 4 + 0.5, "\(tag): the reason starts \(reasonBox.top - nameBox.bottom) pt under the name")
                        #expect(!nameBox.intersects(reasonBox), "\(tag): the name and the reason overlap")
                        #expect(reasonBox.width >= reasonNatural - 1, "\(tag): the reason is \(reasonBox.width) wide for \(reasonNatural) pt of text: it was cut")
                    }
                    let long = try #require(ordered.first { $0.stringValue == suLongName })
                    #expect(long.frame.width < longNatural, "\(look): the long name is \(long.frame.width) pt wide for \(longNatural) pt of text: it was not shortened")
                    let tops = ordered.map { plBox(root, $0).top }
                    #expect(Set(tops).count == 3, "\(look): two rows share a line: \(tops)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theHairlinesBetweenRowsAreOnePointInsetFourteenWithNoneAboveTheFirstRowOrBelowTheLast(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suFillMain(store)
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    let first = try #require(suField(section, suRows[0].name), "\(look): no first row")
                    let card = try #require(sxCard(of: first), "\(look): the first row is in no card")
                    let cardBox = plBox(root, card)
                    let lines = suHairlines(root, card)
                    #expect(lines.count == 2, "\(look): \(lines.count) hairlines for three rows")
                    guard lines.count == 2 else { continue }
                    for line in lines {
                        let box = plBox(root, line)
                        #expect(abs(line.frame.height - 1) <= 0.01, "\(look): a hairline is \(line.frame.height) tall")
                        #expect(abs((box.minX - cardBox.minX) - 14) <= 1, "\(look): a hairline starts \(box.minX - cardBox.minX) in from the card's left edge")
                        #expect(abs(cardBox.maxX - box.maxX) <= 1, "\(look): a hairline ends \(cardBox.maxX - box.maxX) from the card's right edge")
                        let fill = dtRGBA(cgColor: line.layer?.backgroundColor)
                        #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.separatorColor, look)), "\(look): a hairline colour \(String(describing: fill))")
                    }
                    let fields = plTexts(section).filter { sxCard(of: $0) === card }.sorted { plBox(root, $0).top < plBox(root, $1).top }
                    let firstBottom = fields.prefix(2).map { plBox(root, $0).bottom }.max() ?? 0
                    let lastTop = fields.suffix(2).map { plBox(root, $0).top }.min() ?? 0
                    #expect(plBox(root, lines[0]).top >= firstBottom - 0.5, "\(look): the first hairline starts at \(plBox(root, lines[0]).top), the first row ends at \(firstBottom)")
                    #expect(plBox(root, lines[1]).bottom <= lastTop + 0.5, "\(look): the last hairline ends at \(plBox(root, lines[1]).bottom), the last row starts at \(lastTop)")
                    #expect(plBox(root, lines[0]).top > cardBox.top && plBox(root, lines[1]).bottom < cardBox.bottom, "\(look): a hairline sits at a card edge")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func eachRowIsOneStaticTextElementLabelledWithTheWholeStoredStringWithItsTooltipAndNoChildrenAndTheFieldsAreNeverElements(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suFillMain(store)
                let (_, section) = try suSection(window)
                let elements = suRowElements(section)
                #expect(elements.count == 3, "\(elements.count) static text elements in the section: \(elements.map { $0.accessibilityLabel() ?? "nil" })")
                for row in suRows {
                    let matching = elements.filter { ($0.accessibilityLabel() ?? "") == row.stored }
                    #expect(matching.count == 1, "\(matching.count) elements labelled \"\(row.stored)\"")
                    guard let element = matching.first else { continue }
                    #expect(element.accessibilityRole() == .staticText, "\"\(row.stored)\": role \(String(describing: element.accessibilityRole()?.rawValue))")
                    #expect(element.toolTip == row.stored, "\"\(row.stored)\": tooltip \(String(describing: element.toolTip))")
                    #expect((element.accessibilityChildren() ?? []).isEmpty, "\"\(row.stored)\": children \(String(describing: element.accessibilityChildren()))")
                    #expect(!(element is NSTextField), "\"\(row.stored)\": the element is a text field, \(type(of: element))")
                }
                let bare = suRows.flatMap { [$0.name, $0.reason, $0.reason.lowercased()] }
                for view in prViews(section) where plVisible(view) {
                    let text = (view as? NSTextField)?.stringValue
                    if view.isAccessibilityElement() {
                        #expect(!bare.contains(view.accessibilityLabel() ?? "") && !bare.contains(text ?? ""), "an element is a bare name or reason: \(view.accessibilityLabel() ?? text ?? "nil")")
                    }
                }
                let fields = plTexts(section).filter { field in bare.contains(field.stringValue) }
                #expect(fields.count == 6, "\(fields.count) name and reason fields: \(fields.map(\.stringValue))")
                for field in fields {
                    #expect(!field.isAccessibilityElement(), "\"\(field.stringValue)\" is an accessibility element")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aHundredAndFiveUnreadableFilesShowAHundredRowsAndOneSingleLineAndFiveMoreRow(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                var expected: [String] = []
                for number in 1...105 {
                    let name = "f" + String(format: "%03d", number) + ".jpg"
                    try suAdd(store, "/photos/" + name, status: "pending", reason: "damaged", inode: Int64(number))
                    expected.append(name + ", damaged")
                }
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    let elements = suRowElements(section)
                    #expect(elements.count == 100, "\(look): \(elements.count) row elements")
                    #expect(Set(elements.compactMap { $0.accessibilityLabel() }) == Set(expected.prefix(100)), "\(look): the rows are not the first hundred in path order")
                    let more = try #require(suField(section, "and 5 more"), "\(look): no single \"and 5 more\" row: \(plTexts(section).filter { $0.stringValue.hasPrefix("and ") }.map(\.stringValue))")
                    #expect(sxFont(more.font, size: 11.5, weight: .regular), "\(look): the more row font \(String(describing: more.font))")
                    #expect(sxColour(more.textColor, is: .secondaryLabelColor), "\(look): the more row colour")
                    #expect(more.frame.height <= 24, "\(look): the more row is \(more.frame.height) tall: it wraps")
                    let card = try #require(sxCard(of: more), "\(look): the more row is in no card")
                    let cardBox = plBox(root, card)
                    #expect(abs((sxAlignBox(root, more).minX - cardBox.minX) - 14) <= 1, "\(look): the more row starts \(sxAlignBox(root, more).minX - cardBox.minX) in from the card's left edge")
                    #expect(plTexts(section).filter { $0.stringValue == "f101.jpg" || $0.stringValue == "f105.jpg" }.isEmpty, "\(look): a file after the hundredth is listed")
                    #expect(elements.allSatisfy { sxCard(of: $0) === card }, "\(look): a row is in another card")
                    #expect(plBox(root, more).top >= (elements.map { plBox(root, $0).bottom }.max() ?? 0) - 1, "\(look): the more row is not under the last file row")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aNameHoldingACommaAndASpaceSplitsAtTheLastOneAndShowsTheWholeNameOverItsReason(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suAdd(store, "/photos/a, b.jpg", status: "pending", reason: "damaged", inode: 1)
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    let name = try #require(suField(section, "a, b.jpg"), "\(look): no single \"a, b.jpg\": \(plTexts(section).map(\.stringValue))")
                    let reason = try #require(suField(section, "Damaged"), "\(look): no single \"Damaged\"")
                    #expect(plText(section, "a") == nil && plText(section, "b.jpg") == nil && plText(section, "b.jpg, Damaged") == nil, "\(look): the name was split at its own comma: \(plTexts(section).map(\.stringValue))")
                    #expect(plBox(root, reason).top >= plBox(root, name).bottom - 0.5, "\(look): the reason is not under the name")
                    let elements = suRowElements(section)
                    #expect(elements.map { $0.accessibilityLabel() ?? "nil" } == ["a, b.jpg, damaged"], "\(look): elements \(elements.map { $0.accessibilityLabel() ?? "nil" })")
                    #expect(elements.first?.toolTip == "a, b.jpg, damaged", "\(look): tooltip \(String(describing: elements.first?.toolTip))")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func everyStoredReasonShowsItsFirstLetterCapitalisedWhileTheLabelAndTooltipKeepTheStoredLowercaseText(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suAdd(store, "/photos/a-pw.jpg", status: "pending", reason: "password-protected", inode: 1)
                try suAdd(store, "/photos/b-memory.jpg", status: "pending", reason: "needed too much memory", inode: 2)
                try suAdd(store, "/photos/c-large.jpg", status: "pending", reason: "too large to read", inode: 3)
                let wanted: [(name: String, shown: String, stored: String)] = [
                    ("a-pw.jpg", "Password-protected", "a-pw.jpg, password-protected"),
                    ("b-memory.jpg", "Needed too much memory", "b-memory.jpg, needed too much memory"),
                    ("c-large.jpg", "Too large to read", "c-large.jpg, too large to read"),
                ]
                for look in DTLook.allCases {
                    let (root, section) = try suSection(window, look)
                    let elements = suRowElements(section)
                    for row in wanted {
                        let name = try #require(suField(section, row.name), "\(look): no single \"\(row.name)\"")
                        let reason = try #require(suField(section, row.shown), "\(look): no single \"\(row.shown)\": \(plTexts(section).map(\.stringValue))")
                        #expect(plBox(root, reason).top >= plBox(root, name).bottom - 0.5, "\(look): \"\(row.shown)\" is not under \"\(row.name)\"")
                        #expect(plText(section, row.shown.lowercased()) == nil, "\(look): the reason is also shown lowercase")
                        let element = elements.first { ($0.accessibilityLabel() ?? "") == row.stored }
                        #expect(element != nil, "\(look): no element labelled \"\(row.stored)\": \(elements.map { $0.accessibilityLabel() ?? "nil" })")
                        #expect(element?.toolTip == row.stored, "\(look): tooltip \(String(describing: element?.toolTip))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func noRowShowsAFolderPathAndAFileThatWasReadIsNotListed(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suFillMain(store)
                for look in DTLook.allCases {
                    let (_, section) = try suSection(window, look)
                    let texts = plTexts(section).map(\.stringValue)
                    #expect(!texts.contains { $0.contains("/") || $0.contains("photos") || $0.contains("trip") }, "\(look): a folder path is shown: \(texts)")
                    #expect(!texts.contains { $0.hasPrefix("fine.jpg") }, "\(look): a file that was read is listed: \(texts)")
                    #expect(!suRowElements(section).contains { ($0.accessibilityLabel() ?? "").hasPrefix("fine.jpg") }, "\(look): a file that was read has a row element")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSectionTextsAndTheScreenTextsWithRowsAreTheListsOfTodayWithEachRowNowTwoFieldsAndTheNameFieldAdded(glass: Bool) async throws {
            try await suWith(glass: glass) { window in
                let store = try IndexStore()
                defer { store.close() }
                try suFillMain(store)
                let (root, section) = try suSection(window)
                let texts = plTexts(section).sorted { suPosition(root, $0) < suPosition(root, $1) }.map(\.stringValue)
                #expect(texts == [suLogin, suLoginNote, suListTitle, suLongName, "Damaged", "locked.jpg", "Needs permission", "broken.jpg", "Damaged"], "Indexing texts with rows \(texts)")
                #expect(window.settingsScreen.texts == ["Indexing", suLoginNote, suListTitle, suLongName + ", damaged", "locked.jpg, needs permission", "broken.jpg, damaged"], "Indexing screen texts with rows \(window.settingsScreen.texts)")
                #expect(window.settingsScreen.unreadable?.rows == [suLongName + ", damaged", "locked.jpg, needs permission", "broken.jpg, damaged"], "unreadable rows \(String(describing: window.settingsScreen.unreadable?.rows))")
            }
        }
    }
}

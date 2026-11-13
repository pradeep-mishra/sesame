import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let rrFiles: [(path: String, symbol: String, label: String)] = [
    ("/photos/a.jpg", "photo", "a.jpg (photo)"),
    ("/docs/b.pdf", "doc.richtext", "b.pdf (pdf)"),
    ("/docs/c.txt", "doc.text", "c.txt (doc)"),
    ("/audio/d.mp3", "waveform", "d.mp3 (audio)"),
    ("/video/e.mp4", "film", "e.mp4 (video)"),
]

private let rrHint = "Describe what is in the file, or type part of its exact name or text."

@MainActor
private func rrMake(paths: [String]? = nil, look: DTLook = .light, width: CGFloat = 384, height: CGFloat = 470) -> (list: ResultList, table: NSTableView?) {
    let list = ResultList()
    list.view.appearance = dtAppearance(look)
    list.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let all = paths ?? rrFiles.map(\.path)
    list.show(.rows(all.enumerated().map { SearchHit(path: $1, passageID: Int64($0)) }))
    list.view.layoutSubtreeIfNeeded()
    let table = prViews(list.view).compactMap { $0 as? NSTableView }.first
    table?.layoutSubtreeIfNeeded()
    return (list, table)
}

@MainActor
private func rrCell(_ table: NSTableView?, _ row: Int) -> NSTableCellView? {
    let cell = table?.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
    cell?.layoutSubtreeIfNeeded()
    return cell
}

@MainActor
private func rrField(_ cell: NSView, _ text: String) -> NSTextField? {
    prViews(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
}

@MainActor
private func rrSymbolView(_ cell: NSView) -> NSImageView? {
    let images = prViews(cell).compactMap { $0 as? NSImageView }
    return images.count == 1 ? images[0] : nil
}

private func rrSymbolName(_ image: NSImage?) -> String? {
    guard let text = image?.description, let range = text.range(of: "symbol = ") else { return nil }
    return String(text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." })
}

@MainActor
private func rrRect(_ cell: NSView, _ view: NSView) -> NSRect {
    cell.convert(view.alignmentRect(forFrame: view.frame), from: view.superview ?? cell)
}

@MainActor
private func rrPixel(_ rep: NSBitmapImageRep, _ row: NSView, x: CGFloat, y: CGFloat) -> [CGFloat] {
    let scale = CGFloat(rep.pixelsWide) / row.bounds.width
    guard let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return [] }
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}

@MainActor
private func rrDraw(_ row: NSView) -> NSBitmapImageRep? {
    guard let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return nil }
    row.cacheDisplay(in: row.bounds, to: rep)
    return rep
}

@MainActor
private func rrBlock(_ state: NSView, in root: NSView) -> NSRect {
    let parts: [NSView] = rrShownTexts(state) + prViews(state).compactMap { $0 as? NSImageView }.filter { !$0.isHiddenOrHasHiddenAncestor }
    return parts.map { root.convert($0.bounds, from: $0) }.reduce(NSRect.null) { $0.union($1) }
}

private func rrSourceText() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/Sesame/ResultList.swift"), encoding: .utf8)
}

@MainActor
private func rrShownTexts(_ view: NSView) -> [NSTextField] {
    prViews(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
}

@Suite("ResultRowsLayoutTests", .serialized)
struct ResultRowsLayoutTests {

    @MainActor
    @Test func everyRowIsThirtyTwoPointsTall() throws {
        let (_, table) = rrMake()
        let found = try #require(table, "no NSTableView inside ResultList().view")
        #expect(found.rowHeight == 32)
        for row in 0..<rrFiles.count {
            #expect(abs(found.rect(ofRow: row).height - 32) <= 0.5, "row \(row)")
            let cell = try #require(rrCell(found, row))
            #expect(abs(cell.frame.height - 32) <= 0.5, "cell \(row) is \(cell.frame.height)")
        }
    }

    @MainActor
    @Test func theKindSymbolIsSixteenPointsSecondaryAtOneXForEveryRowAndNotAnAccessibilityElement() throws {
        for look in DTLook.allCases {
            let (_, table) = rrMake(look: look)
            var xs: [CGFloat] = []
            for (row, file) in rrFiles.enumerated() {
                let cell = try #require(rrCell(table, row))
                let symbol = try #require(rrSymbolView(cell), "row \(row) \(file.symbol): not exactly one image view in the cell")
                let reference = NSImage(systemSymbolName: file.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
                let wanted = rrSymbolName(reference)
                #expect(wanted != nil, "the system has no symbol named \(file.symbol)")
                #expect(rrSymbolName(symbol.image) == wanted, "row \(row): symbol is \(String(describing: rrSymbolName(symbol.image))), \(file.symbol) is \(String(describing: wanted))")
                let rect = rrRect(cell, symbol)
                #expect(abs(rect.width - 16) <= 0.5 && abs(rect.height - 16) <= 0.5, "row \(row) symbol is \(rect.width) x \(rect.height)")
                #expect(abs(rect.midY - cell.bounds.midY) <= 1.5, "row \(row) symbol midY \(rect.midY), cell midY \(cell.bounds.midY)")
                xs.append(rect.minX)
                #expect(!symbol.isAccessibilityElement(), "row \(row)")
                #expect(dtSame(dtRGBA(symbol.contentTintColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "row \(row) tint \(look)")
                let size = symbol.image?.size ?? .zero
                #expect(abs(size.width - (reference?.size.width ?? -100)) <= 3 && abs(size.height - (reference?.size.height ?? -100)) <= 3, "row \(row) image \(size)")
            }
            #expect(xs.allSatisfy { abs($0 - 16) <= 1 }, "symbol x values \(xs)")
            #expect((xs.max() ?? 0) - (xs.min() ?? 0) <= 0.5, "symbol x values \(xs)")
        }
    }

    @MainActor
    @Test func theNamesShareOneXAfterTheSymbolAndTheNameIsThirteenSemiboldWithTailTruncation() throws {
        for look in DTLook.allCases {
            let (_, table) = rrMake(look: look)
            var xs: [CGFloat] = []
            for (row, file) in rrFiles.enumerated() {
                let cell = try #require(rrCell(table, row))
                let symbol = rrRect(cell, try #require(rrSymbolView(cell)))
                let name = try #require(rrField(cell, (file.path as NSString).lastPathComponent), "row \(row): no name field")
                let rect = rrRect(cell, name)
                xs.append(rect.minX)
                #expect(rect.minX >= symbol.maxX + 4 - 0.5 && rect.minX <= symbol.maxX + 12 + 0.5, "row \(row): symbol ends \(symbol.maxX), name starts \(rect.minX)")
                #expect(name.font?.pointSize == 13)
                #expect(abs(dtWeight(name.font ?? .systemFont(ofSize: 13)) - NSFont.Weight.semibold.rawValue) < 0.05)
                #expect(name.lineBreakMode == .byTruncatingTail)
            }
            #expect((xs.max() ?? 0) - (xs.min() ?? 0) <= 0.5, "name x values \(xs)")
        }
    }

    @MainActor
    @Test func theFolderIsTwelveSecondaryHeadTruncatedAndAbbreviatesTheHomeFolderWithATilde() throws {
        let home = NSHomeDirectory()
        let paths = [home + "/Documents/Photos/trip/a.jpg", "/photos/b.jpg"]
        let expected = ["~/Documents/Photos/trip", "/photos"]
        for look in DTLook.allCases {
            let (_, table) = rrMake(paths: paths, look: look)
            for (row, text) in expected.enumerated() {
                let cell = try #require(rrCell(table, row))
                let folder = try #require(rrField(cell, text), "row \(row): no folder field reading \(text); fields \(rrShownTexts(cell).map(\.stringValue))")
                #expect(folder.font?.pointSize == 12)
                #expect(abs(dtWeight(folder.font ?? .systemFont(ofSize: 12)) - NSFont.Weight.regular.rawValue) < 0.05)
                #expect(folder.lineBreakMode == .byTruncatingHead)
                if row == 1 {
                    #expect(dtSame(dtRGBA(folder.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "row \(row) folder colour \(look)")
                }
                let name = try #require(rrField(cell, (paths[row] as NSString).lastPathComponent))
                #expect(rrRect(cell, folder).minX >= rrRect(cell, name).maxX + 8 - 0.5, "row \(row): the folder starts before the name ends and a gap of 8")
            }
        }
    }

    @MainActor
    @Test func aLongNameAndALongFolderStayInsideTheRowWithATrailingInsetOfSixteen() throws {
        let longName = String(repeating: "holiday-photo-of-the-beach-", count: 6) + "end.jpg"
        let longFolder = "/photos/" + (0..<12).map { "a-rather-long-folder-name-\($0)" }.joined(separator: "/")
        let paths = [longFolder + "/short.jpg", "/photos/" + longName, longFolder + "/" + longName]
        let (_, table) = rrMake(paths: paths)
        for (row, path) in paths.enumerated() {
            let cell = try #require(rrCell(table, row))
            let symbol = rrRect(cell, try #require(rrSymbolView(cell)))
            let name = try #require(rrField(cell, (path as NSString).lastPathComponent), "row \(row): no name field")
            let nameRect = rrRect(cell, name)
            let folderText = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            let folder = try #require(rrField(cell, folderText), "row \(row): no folder field")
            let folderRect = rrRect(cell, folder)
            #expect(nameRect.minX >= symbol.maxX, "row \(row): the name starts inside the symbol")
            #expect(nameRect.maxX <= folderRect.minX + 0.5 || folderRect.width < 1, "row \(row): the name \(nameRect.minX) to \(nameRect.maxX) runs into the folder at \(folderRect.minX)")
            #expect(nameRect.maxX <= cell.bounds.width - 16 + 0.5, "row \(row): the name ends at \(nameRect.maxX) of \(cell.bounds.width)")
            #expect(folderRect.maxX <= cell.bounds.width - 16 + 0.5, "row \(row): the folder ends at \(folderRect.maxX) of \(cell.bounds.width)")
            if folderRect.width >= 1 {
                #expect(abs(folderRect.maxX - (cell.bounds.width - 16)) <= 1, "row \(row): trailing inset \(cell.bounds.width - folderRect.maxX)")
            }
        }
        let shortRow = try #require(rrCell(table, 0))
        let folderOfShort = try #require(rrField(shortRow, ((paths[0] as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath))
        let nameOfShort = try #require(rrField(shortRow, "short.jpg"))
        #expect(rrRect(shortRow, folderOfShort).minX >= rrRect(shortRow, nameOfShort).maxX + 8 - 0.5)
    }

    @MainActor
    @Test func theSelectionPillIsInsetSixHasRadiusSevenAndIsTheAccentColourInBothLooks() throws {
        for look in DTLook.allCases {
            let (_, table) = rrMake(look: look)
            let selected = try #require(table?.rowView(atRow: 0, makeIfNecessary: true))
            let other = try #require(table?.rowView(atRow: 1, makeIfNecessary: true))
            selected.appearance = dtAppearance(look)
            other.appearance = dtAppearance(look)
            let accent = dtRGBA(.controlAccentColor, look)
            let rep = try #require(rrDraw(selected))
            let inside = rrPixel(rep, selected, x: 10, y: 16)
            #expect(inside.count == 4 && dtSame(Array(inside[0..<3]), Array(accent[0..<3]), tolerance: 0.05) && inside[3] > 0.95, "pill centre \(look): \(inside) accent \(accent)")
            let farRight = selected.bounds.width - 10
            let right = rrPixel(rep, selected, x: farRight, y: 16)
            #expect(right.count == 4 && dtSame(Array(right[0..<3]), Array(accent[0..<3]), tolerance: 0.05) && right[3] > 0.95, "pill right part \(look): \(right)")
            let leftOutside = rrPixel(rep, selected, x: 3, y: 16)
            #expect(leftOutside.count == 4 && leftOutside[3] < 0.5, "left of the inset \(look): \(leftOutside)")
            let rightOutside = rrPixel(rep, selected, x: selected.bounds.width - 3, y: 16)
            #expect(rightOutside.count == 4 && rightOutside[3] < 0.5, "right of the inset \(look): \(rightOutside)")
            let justInsideLeft = rrPixel(rep, selected, x: 8, y: 16)
            #expect(justInsideLeft.count == 4 && justInsideLeft[3] > 0.95, "two points inside the left inset \(look): \(justInsideLeft)")
            let cornerA = rrPixel(rep, selected, x: 7, y: 1)
            #expect(cornerA.count == 4 && cornerA[3] < 0.5, "corner point (1,1) from the pill's corner is outside a radius of 7 \(look): \(cornerA)")
            let cornerB = rrPixel(rep, selected, x: 6.8, y: 3)
            #expect(cornerB.count == 4 && cornerB[3] < 0.5, "corner point (0.8,3) is outside a radius of 7 \(look): \(cornerB)")
            let cornerC = rrPixel(rep, selected, x: 8.5, y: 2.5)
            #expect(cornerC.count == 4 && cornerC[3] > 0.9, "corner point (2.5,2.5) is inside a radius of 7 \(look): \(cornerC)")
            let plain = try #require(rrDraw(other))
            let idle = rrPixel(plain, other, x: 10, y: 16)
            #expect(idle.count == 4 && idle[3] < 0.5, "an unselected row draws no pill \(look): \(idle)")
        }
    }

    @MainActor
    @Test func theSelectedRowUsesTheSelectedTextColoursAndEveryOtherRowTheLabelColoursInBothLooks() throws {
        for look in DTLook.allCases {
            let (list, table) = rrMake(look: look)
            let base = dtRGBA(.alternateSelectedControlTextColor, look)
            let selectedSecondary = [base[0], base[1], base[2], 0.82]
            func check(selectedRow: Int, _ stage: String) throws {
                for (row, file) in rrFiles.enumerated() {
                    let cell = try #require(rrCell(table, row))
                    let name = try #require(rrField(cell, (file.path as NSString).lastPathComponent))
                    let folder = try #require(rrField(cell, (file.path as NSString).deletingLastPathComponent))
                    let nameColour = dtRGBA(name.textColor ?? .clear, look)
                    let folderColour = dtRGBA(folder.textColor ?? .clear, look)
                    if row == selectedRow {
                        #expect(dtSame(nameColour, base), "\(stage) \(look) row \(row) name \(nameColour) expected \(base)")
                        #expect(dtSame(folderColour, selectedSecondary), "\(stage) \(look) row \(row) folder \(folderColour) expected \(selectedSecondary)")
                    } else {
                        #expect(dtSame(nameColour, dtRGBA(.labelColor, look)), "\(stage) \(look) row \(row) name \(nameColour)")
                        #expect(dtSame(folderColour, dtRGBA(.secondaryLabelColor, look)), "\(stage) \(look) row \(row) folder \(folderColour)")
                    }
                }
            }
            try check(selectedRow: 0, "first row selected")
            list.move(by: 1)
            list.move(by: 1)
            table?.layoutSubtreeIfNeeded()
            try check(selectedRow: 2, "after Down twice")
        }
    }

    @MainActor
    @Test func theSelectedNameIsNotAColourLiteralAndTheSelectedRowUsesTheCatalogSelectedTextColour() throws {
        let (_, table) = rrMake()
        let cell = try #require(rrCell(table, 0))
        let name = try #require(rrField(cell, "a.jpg"))
        let colour = try #require(name.textColor)
        guard colour.type == .catalog else {
            Issue.record("the selected name colour is not a catalog colour (type \(colour.type.rawValue))")
            return
        }
        #expect(colour.colorNameComponent == NSColor.alternateSelectedControlTextColor.colorNameComponent, "named \(colour.colorNameComponent)")
    }

    @Test func resultListSwiftHoldsNoColourLiteralAndNamesTheTwoSelectedTextColours() throws {
        let text = try rrSourceText()
        let literals = [#"NSColor\.white"#, #"NSColor\.black"#, #"\.white\b"#, #"\.black\b"#, #"NSColor\("#]
        for pattern in literals {
            let regex = try NSRegularExpression(pattern: pattern)
            let hits = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            #expect(hits == 0, "ResultList.swift holds \(hits) match(es) of \(pattern)")
        }
        let namesSelectedText = text.contains("Design.selectedText")
        let namesSelectedSecondaryText = text.contains("Design.selectedSecondaryText")
        #expect(namesSelectedText, "ResultList.swift never names Design.selectedText")
        #expect(namesSelectedSecondaryText, "ResultList.swift never names Design.selectedSecondaryText")
    }

    @MainActor
    @Test func rowAndCellAccessibilityLabelsAreTodaysWords() throws {
        let (_, table) = rrMake()
        for (row, file) in rrFiles.enumerated() {
            let rowView = try #require(table?.rowView(atRow: row, makeIfNecessary: true))
            #expect(rowView.accessibilityLabel() == file.label, "row \(row) label \(String(describing: rowView.accessibilityLabel()))")
            let cell = try #require(rrCell(table, row))
            let folder = try #require(rrField(cell, (file.path as NSString).deletingLastPathComponent))
            #expect(folder.accessibilityLabel() == file.path, "row \(row) folder label \(String(describing: folder.accessibilityLabel()))")
        }
        let (_, other) = rrMake(paths: ["/misc/notes.xyz"])
        let unknown = try #require(other?.rowView(atRow: 0, makeIfNecessary: true))
        #expect(unknown.accessibilityLabel() == "notes.xyz (file)")
    }

    @MainActor
    @Test func searchingIsDrawnThroughAStateViewWithTheSameWordAndNoSpinner() throws {
        let list = ResultList()
        list.view.appearance = dtAppearance(.light)
        list.view.frame = NSRect(x: 0, y: 0, width: 384, height: 470)
        list.show(.searching)
        list.view.layoutSubtreeIfNeeded()
        let states = prViews(list.view).compactMap { $0 as? StateView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(states.count == 1, "visible StateViews: \(states.count)")
        let state = try #require(states.first)
        let words = rrShownTexts(state).map(\.stringValue)
        #expect(words == ["Searching"], "texts in the state: \(words)")
        #expect(rrShownTexts(list.view).map(\.stringValue).filter { $0.contains("Searching") }.count == 1)
        #expect(!rrShownTexts(list.view).contains { $0.stringValue.contains("No matches") })
        #expect(!prViews(list.view).contains { $0 is NSProgressIndicator })
        let rect = list.view.convert(state.bounds, from: state)
        #expect(abs(rect.midX - 192) <= 8, "state centre x \(rect.midX)")
        let block = rrBlock(state, in: list.view)
        let ratio = (470 - block.maxY) / 470
        #expect(ratio >= 0.30 && ratio <= 0.45, "block top at \(ratio)")
    }

    @MainActor
    @Test func noMatchesIsDrawnThroughAStateViewWithTheSameWordsAndTheStateIsCentred() throws {
        let list = ResultList()
        list.view.appearance = dtAppearance(.light)
        list.view.frame = NSRect(x: 0, y: 0, width: 384, height: 470)
        list.show(.noMatches)
        list.view.layoutSubtreeIfNeeded()
        let states = prViews(list.view).compactMap { $0 as? StateView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(states.count == 1, "visible StateViews: \(states.count)")
        let state = try #require(states.first)
        let words = Set(rrShownTexts(state).map(\.stringValue))
        #expect(words == ["No matches", rrHint], "texts in the state: \(words)")
        let title = try #require(rrShownTexts(state).first { $0.stringValue == "No matches" })
        #expect(title.font?.pointSize == 17)
        let hint = try #require(rrShownTexts(state).first { $0.stringValue == rrHint })
        let hintRect = list.view.convert(hint.bounds, from: hint)
        #expect(hintRect.width <= 320.5, "hint width \(hintRect.width)")
        let block = rrBlock(state, in: list.view)
        #expect(abs(block.midX - 192) <= 8, "block centre x \(block.midX)")
        let ratio = (470 - block.maxY) / 470
        #expect(ratio >= 0.30 && ratio <= 0.45, "block top at \(ratio)")
        #expect(!prViews(list.view).contains { $0 is NSProgressIndicator })
    }

    @MainActor
    @Test func rowsAndTheEmptyListShowNoStateView() throws {
        let (list, _) = rrMake()
        #expect(!prViews(list.view).contains { ($0 as? StateView).map { !$0.isHiddenOrHasHiddenAncestor } ?? false })
        list.show(.empty)
        list.view.layoutSubtreeIfNeeded()
        #expect(!prViews(list.view).contains { ($0 as? StateView).map { !$0.isHiddenOrHasHiddenAncestor } ?? false })
        #expect(rrShownTexts(list.view).isEmpty, "texts after .empty: \(rrShownTexts(list.view).map(\.stringValue))")
    }

    @MainActor
    @Test func theViewAndTheKeyViewStillExistAndTheKeyViewTakesNoFocusWithoutATabOrAClick() {
        let list = ResultList()
        #expect(list.view.superview == nil)
        #expect(prViews(list.view).contains { $0 === list.keyView })
        #expect(list.keyView is NSTableView)
        #expect(!list.keyView.acceptsFirstResponder)
        #expect(list.keyView.accessibilityLabel() == "Results")
    }
}

import AppKit
import Foundation
import Testing
@testable import Sesame

private let sibSymbols = [
    ("Folders", "folder"),
    ("File types", "doc.on.doc"),
    ("Search", "magnifyingglass"),
    ("Indexing", "arrow.triangle.2.circlepath"),
]

private let sibSections: [SettingsScreen.Section] = [.folders, .fileTypes, .search, .indexing]

private struct SIBInk {
    var minX = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var minY = CGFloat.infinity
    var maxY = -CGFloat.infinity
    var colours: [[CGFloat]] = []

    var found: Bool { !colours.isEmpty }
}

@MainActor
private func sibSymbolName(_ image: NSImage) -> String? {
    guard let range = image.description.range(of: "symbol = ") else { return nil }
    return image.description[range.upperBound...].prefix { $0 != ">" }.description
}

@MainActor
private func sibCell(_ button: SidebarButton) -> NSButtonCell? {
    button.cell as? NSButtonCell
}

@MainActor
private func sibInk(_ button: SidebarButton, xRange: Range<CGFloat>) -> SIBInk? {
    guard button.bounds.width > 0, button.bounds.height > 0,
          let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
    button.cacheDisplay(in: button.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / button.bounds.width
    var ink = SIBInk()
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let left = CGFloat(x) / scale
            guard xRange.contains(left),
                  let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.5 else { continue }
            ink.minX = min(ink.minX, left)
            ink.maxX = max(ink.maxX, CGFloat(x + 1) / scale)
            ink.minY = min(ink.minY, CGFloat(y) / scale)
            ink.maxY = max(ink.maxY, CGFloat(y + 1) / scale)
            ink.colours.append([colour.redComponent, colour.greenComponent, colour.blueComponent])
        }
    }
    return ink
}

extension ModelDownloadTests {
    @Suite("SidebarIconBoxTests", .serialized)
    struct SidebarIconBoxTests {

        @MainActor
        @Test(arguments: slPaths)
        func theIconBoxIsTwentyTwoWideFromEightToThirtyCentredAtNineteenAndTheLabelStartsAtFortyTenPastTheBoxInAllFourRowsInEverySectionAndBothLooks(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sibSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        let buttons = sgsButtons(root)
                        #expect(buttons.count == 4, "\(section) \(look): \(buttons.count) SidebarButtons")
                        var labelStarts: [CGFloat] = []
                        for button in buttons {
                            let name = "\(button.title) with \(section) selected, \(look)"
                            let cell = try #require(sibCell(button), "\(name): the button has no NSButtonCell")
                            #expect(abs(button.bounds.width - 164) <= 0.5 && abs(button.bounds.height - 28) <= 0.5, "\(name): bounds \(button.bounds)")
                            let image = cell.imageRect(forBounds: button.bounds)
                            let title = cell.titleRect(forBounds: button.bounds)
                            #expect(abs(image.midX - 19) <= 0.5, "\(name): the symbol's centre is at x \(image.midX), wanted 19")
                            #expect(image.width > 0 && image.width <= 22.5, "\(name): the symbol is \(image.width) wide, the box is 22")
                            #expect(abs(title.minX - 40) <= 0.5, "\(name): the label starts at x \(title.minX), wanted 40")
                            #expect(abs(title.minX - (image.midX + 11) - 10) <= 0.5, "\(name): the gap from the box's right edge (\(image.midX + 11)) to the label (\(title.minX)) is \(title.minX - (image.midX + 11)), wanted 10")
                            let box = plBox(root, button)
                            #expect(abs(box.minX + title.minX - 48) <= 0.5, "\(name): the label starts at window x \(box.minX + title.minX), wanted 48")
                            #expect(abs(box.minX + image.midX - 27) <= 0.5, "\(name): the symbol's centre is at window x \(box.minX + image.midX), wanted 27")
                            labelStarts.append(title.minX)
                        }
                        if let low = labelStarts.min(), let high = labelStarts.max() {
                            #expect(high - low <= 0.5, "\(section) \(look): the four label x values are \(labelStarts)")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func eachSymbolIsATemplateSixteenPointImageNamedAfterItsRowAndRequestsMonochromeRenderingInEverySectionAndBothLooks(glass: Bool) async throws {
            let expected = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular).applying(.preferringMonochrome())
            let plain = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            #expect(expected != plain, "this system's SymbolConfiguration equality cannot tell the monochrome request from the plain one")
            try await sgsWith(glass: glass) { window in
                for section in sibSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        let buttons = sgsButtons(root)
                        #expect(buttons.map(\.title) == sibSymbols.map(\.0), "\(section) \(look): titles \(buttons.map(\.title))")
                        for (button, entry) in zip(buttons, sibSymbols) {
                            let name = "\(entry.0) with \(section) selected, \(look)"
                            let image = try #require(button.image, "\(name): no image")
                            #expect(image.isTemplate, "\(name): the symbol is not a template image")
                            let reference = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)?.withSymbolConfiguration(plain)
                            #expect(sibSymbolName(image) != nil && sibSymbolName(image) == reference.flatMap(sibSymbolName), "\(name): image \(image.description), wanted the symbol \(entry.1) (\(String(describing: reference.flatMap(sibSymbolName))))")
                            #expect(abs(image.size.width - (reference?.size.width ?? -100)) <= 3, "\(name): width \(image.size.width)")
                            #expect(abs(image.size.height - (reference?.size.height ?? -100)) <= 3, "\(name): height \(image.size.height)")
                            #expect(image.symbolConfiguration == expected, "\(name): the symbol configuration is not pointSize 16 regular applying preferringMonochrome")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSymbolInkSitsInsideTheTwentyTwoSquareBoxCentredAtNineteenAndFourteenNothingIsDrawnInTheTenPointGapAndTheLabelInkStartsBetweenFortyAndFortyTwoPointFiveInAllFourRowsInBothLooks(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    var labelStarts: [String: [CGFloat]] = [:]
                    for pick in [SettingsScreen.Section.indexing, .folders] {
                        let root = sxLayout(window, pick, look)
                        for button in sgsButtons(root) where !button.isSelected {
                            let name = "\(button.title) with \(pick) selected, \(look)"
                            guard let symbol = sibInk(button, xRange: 0..<30.5), symbol.found else {
                                Issue.record("\(name): no symbol ink")
                                continue
                            }
                            #expect(symbol.minX >= 7.5 && symbol.maxX <= 30.5, "\(name): symbol ink spans x \(symbol.minX) to \(symbol.maxX), the box is 8 to 30")
                            #expect(symbol.minY >= 2.5 && symbol.maxY <= 25.5, "\(name): symbol ink spans y \(symbol.minY) to \(symbol.maxY), the box is 3 to 25")
                            #expect(abs((symbol.minX + symbol.maxX) / 2 - 19) <= 2, "\(name): symbol ink centre x \((symbol.minX + symbol.maxX) / 2), wanted 19")
                            #expect(abs((symbol.minY + symbol.maxY) / 2 - 14) <= 1.5, "\(name): symbol ink centre y \((symbol.minY + symbol.maxY) / 2), wanted 14")
                            guard let label = sibInk(button, xRange: 30.5..<164), label.found else {
                                Issue.record("\(name): no label ink")
                                continue
                            }
                            #expect(label.minX >= 39.5 && label.minX <= 42.5, "\(name): the first label ink column is \(label.minX), wanted 40 to 42.5 with nothing from 30.5 to 39.5")
                            labelStarts[button.title, default: []].append(label.minX)
                        }
                    }
                    for entry in sibSymbols {
                        #expect(!(labelStarts[entry.0] ?? []).isEmpty, "\(look): \(entry.0) was never measured, measured \(labelStarts.keys.sorted())")
                    }
                    let all = labelStarts.values.flatMap { $0 }
                    if let low = all.min(), let high = all.max() {
                        #expect(high - low <= 1.5, "\(look): the first label ink columns are \(labelStarts)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSymbolInkIsNeutralAndWithinPointOneFiveOfTheLabelColourInAllFourRowsInBothLooks(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let label = dtRGBA(.labelColor, look)
                    let wanted = (label[0] + label[1] + label[2]) / 3
                    for pick in [SettingsScreen.Section.indexing, .folders] {
                        let root = sxLayout(window, pick, look)
                        for button in sgsButtons(root) where !button.isSelected {
                            let name = "\(button.title) with \(pick) selected, \(look)"
                            guard let symbol = sibInk(button, xRange: 0..<30.5), symbol.found else {
                                Issue.record("\(name): no symbol ink")
                                continue
                            }
                            let tinted = symbol.colours.filter { colour in
                                max(colour[0], colour[1], colour[2]) - min(colour[0], colour[1], colour[2]) > 0.1
                            }
                            #expect(tinted.isEmpty, "\(name): \(tinted.count) of \(symbol.colours.count) symbol pixels are not neutral, first \(String(describing: tinted.first))")
                            let off = symbol.colours.filter { abs(($0[0] + $0[1] + $0[2]) / 3 - wanted) > 0.15 }
                            #expect(off.isEmpty, "\(name): \(off.count) of \(symbol.colours.count) symbol pixels are not within 0.15 of the label brightness \(wanted), first \(String(describing: off.first))")
                        }
                    }
                }
            }
        }
    }
}

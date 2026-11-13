import AppKit
import Foundation
import Testing
@testable import Sesame

private let sfrSections: [SettingsScreen.Section] = [.folders, .fileTypes, .search, .indexing]
private let sfrTitles = ["Folders", "File types", "Search", "Indexing"]

private struct SFRMask {
    let width: Int
    let height: Int
    let alpha: [UInt8]

    func at(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let px = Int(((x + 8) * 2).rounded(.down))
        let py = Int(((y + 8) * 2).rounded(.down))
        guard px >= 0, py >= 0, px < width, py < height else { return -1 }
        return CGFloat(alpha[py * width + px]) / 255
    }

    var coverage: CGFloat {
        alpha.reduce(0) { $0 + CGFloat($1) / 255 } / 4
    }

    var box: (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x + 1)
                minY = min(minY, y)
                maxY = max(maxY, y + 1)
            }
        }
        guard maxX >= 0 else { return nil }
        return (CGFloat(minX) / 2 - 8, CGFloat(maxX) / 2 - 8, CGFloat(minY) / 2 - 8, CGFloat(maxY) / 2 - 8)
    }
}

@MainActor
private func sfrCell(_ button: SidebarButton) -> NSButtonCell? {
    button.cell as? NSButtonCell
}

@MainActor
private func sfrDraw(_ button: SidebarButton) -> SFRMask? {
    guard let cell = sfrCell(button) else { return nil }
    return sfrRender(appearance: button.effectiveAppearance) {
        cell.drawFocusRingMask(withFrame: button.bounds, in: button)
    }
}

@MainActor
private func sfrRender(appearance: NSAppearance, _ draw: () -> Void) -> SFRMask? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 88, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
    rep.size = NSSize(width: 180, height: 44)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 8, y: 8)
    appearance.performAsCurrentDrawingAppearance(draw)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.bitmapData else { return nil }
    var alpha: [UInt8] = []
    alpha.reserveCapacity(rep.pixelsWide * rep.pixelsHigh)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            alpha.append(data[y * rep.bytesPerRow + x * 4 + 3])
        }
    }
    return SFRMask(width: rep.pixelsWide, height: rep.pixelsHigh, alpha: alpha)
}

@MainActor
private func sfrWalk(_ window: NSWindow) -> [NSView] {
    var walked: [NSView] = []
    var current: NSView? = window.initialFirstResponder
    while let view = current, walked.count < 200, !walked.contains(where: { $0 === view }) {
        walked.append(view)
        current = view.nextKeyView
    }
    return walked
}

private func sfrNear(_ rect: NSRect, _ wanted: NSRect, tolerance: CGFloat = 0.5) -> Bool {
    abs(rect.minX - wanted.minX) <= tolerance && abs(rect.minY - wanted.minY) <= tolerance
        && abs(rect.width - wanted.width) <= tolerance && abs(rect.height - wanted.height) <= tolerance
}

extension ModelDownloadTests {
    @Suite("SidebarFocusRingTests", .serialized)
    struct SidebarFocusRingTests {

        @MainActor
        @Test(arguments: slPaths)
        func theFocusRingMaskOfEverySidebarRowIsTheWholeOneHundredSixtyFourByTwentyEightButtonWithinHalfAPointSelectedOrNotInBothLooks(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sfrSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        let buttons = sgsButtons(root)
                        #expect(buttons.map(\.title) == sfrTitles, "\(section) \(look): rows \(buttons.map(\.title))")
                        for button in buttons {
                            let name = "\(button.title) with \(section) selected (\(button.isSelected ? "selected" : "not selected")), \(look)"
                            let cell = try #require(sfrCell(button), "\(name): the button has no NSButtonCell")
                            #expect(abs(button.bounds.width - 164) <= 0.5 && abs(button.bounds.height - 28) <= 0.5, "\(name): bounds \(button.bounds)")
                            let mask = cell.focusRingMaskBounds(forFrame: button.bounds, in: button)
                            #expect(sfrNear(mask, button.bounds), "\(name): the focus ring mask bounds are \(mask), wanted the whole button \(button.bounds)")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theFocusRingMaskBitmapIsOpaqueAtTheRowCentreTheIconAndOnePointInsideTheLeftEdgeAndTransparentAtTheFourRadiusEightCornersAndOutsideTheRowInBothLooks(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sfrSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        for button in sgsButtons(root) {
                            let name = "\(button.title) with \(section) selected, \(look)"
                            let mask = try #require(sfrDraw(button), "\(name): the mask could not be drawn into a bitmap")
                            let opaque: [(String, CGFloat, CGFloat)] = [
                                ("the row centre", 82, 14),
                                ("the icon centre", 19, 14),
                                ("one point inside the left edge", 1, 14),
                            ]
                            for (what, x, y) in opaque {
                                let alpha = mask.at(x, y)
                                #expect(abs(alpha - 1) <= 0.02, "\(name): alpha at \(what) (\(x), \(y)) is \(alpha), wanted 1")
                            }
                            let transparent: [(String, CGFloat, CGFloat)] = [
                                ("the top left corner", 0.5, 0.5),
                                ("the top right corner", 163.5, 0.5),
                                ("the bottom left corner", 0.5, 27.5),
                                ("the bottom right corner", 163.5, 27.5),
                                ("a point left of the row", -4, 14),
                                ("a point right of the row", 168, 14),
                                ("a point above the row", 82, -4),
                                ("a point below the row", 82, 32),
                            ]
                            for (what, x, y) in transparent {
                                let alpha = mask.at(x, y)
                                #expect(alpha >= 0 && alpha < 0.02, "\(name): alpha at \(what) (\(x), \(y)) is \(alpha), wanted under 0.02")
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theFocusRingMaskCoversAtLeastNinetyFivePercentOfARadiusEightRoundedOneHundredSixtyFourByTwentyEightAndItsBoxIsTheWholeButtonNotTheIconBox(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sfrSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        for button in sgsButtons(root) {
                            let name = "\(button.title) with \(section) selected, \(look)"
                            let mask = try #require(sfrDraw(button), "\(name): the mask could not be drawn into a bitmap")
                            #expect(mask.coverage >= 4310, "\(name): the mask covers \(mask.coverage) pt2, wanted at least 4310 (95 percent of 4537)")
                            #expect(mask.coverage <= 4600, "\(name): the mask covers \(mask.coverage) pt2, wanted at most 4600 (the 164 x 28 rect is 4592)")
                            let box = try #require(mask.box, "\(name): the mask has no opaque pixel")
                            #expect(abs(box.minX - 0) <= 0.5 && abs(box.maxX - 164) <= 0.5, "\(name): the mask spans x \(box.minX) to \(box.maxX), wanted 0 to 164")
                            #expect(abs(box.minY - 0) <= 0.5 && abs(box.maxY - 28) <= 0.5, "\(name): the mask spans y \(box.minY) to \(box.maxY), wanted 0 to 28")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func eachRowTakesFirstResponderInAWindowKeepsTheDefaultFocusRingTypeAndTheCellReportsTheWholeRowMaskForTheRowThatHoldsFocus(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .indexing, look)
                    let rows = sgsButtons(root)
                    #expect(rows.map(\.title) == sfrTitles, "\(look): rows \(rows.map(\.title))")
                    #expect(window.initialFirstResponder === rows.first, "\(look): initialFirstResponder \(String(describing: window.initialFirstResponder))")
                    for row in rows {
                        #expect(row.focusRingType == .default, "\(look) \(row.title): focusRingType is \(row.focusRingType.rawValue), wanted default (\(NSFocusRingType.default.rawValue))")
                    }
                    for row in rows {
                        let name = "\(row.title) as first responder, \(look)"
                        #expect(window.makeFirstResponder(row), "\(name): makeFirstResponder returned false")
                        #expect(window.firstResponder === row, "\(name): the first responder is \(String(describing: window.firstResponder))")
                        let cell = try #require(sfrCell(row), "\(name): the button has no NSButtonCell")
                        let mask = cell.focusRingMaskBounds(forFrame: row.bounds, in: row)
                        #expect(sfrNear(mask, row.bounds), "\(name): the focus ring mask bounds are \(mask), wanted the whole button \(row.bounds)")
                        let drawn = try #require(sfrDraw(row), "\(name): the mask could not be drawn into a bitmap")
                        #expect(abs(drawn.at(82, 14) - 1) <= 0.02, "\(name): alpha at the row centre is \(drawn.at(82, 14))")
                        #expect(abs(drawn.at(1, 14) - 1) <= 0.02, "\(name): alpha at one point inside the left edge is \(drawn.at(1, 14))")
                        #expect(drawn.at(0.5, 0.5) < 0.02, "\(name): alpha at the top left corner is \(drawn.at(0.5, 0.5))")
                        #expect(drawn.coverage >= 4310, "\(name): the mask covers \(drawn.coverage) pt2, wanted at least 4310")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func tabStillWalksFoldersFileTypesSearchIndexingThenThePaneAndReturnsToFoldersInEverySection(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sfrSections {
                    let root = sxLayout(window, section)
                    let rows = sgsButtons(root)
                    let walked = sfrWalk(window)
                    #expect(window.initialFirstResponder === rows.first, "\(section.title): initialFirstResponder \(String(describing: window.initialFirstResponder))")
                    #expect(walked.prefix(4).compactMap { ($0 as? SidebarButton)?.title } == sfrTitles, "\(section.title): the first four stops are \(walked.prefix(4).map { NSStringFromClass(type(of: $0)) })")
                    #expect(walked.count > 4, "\(section.title): no control follows the sidebar")
                    #expect(walked.filter { $0 is SidebarButton }.count == 4, "\(section.title): \(walked.filter { $0 is SidebarButton }.count) sidebar stops")
                    let pane = try #require(sgsSection(root, section), "\(section.title): no section view")
                    for view in walked.dropFirst(4) {
                        #expect(view.isDescendant(of: pane), "\(section.title): the stop \(NSStringFromClass(type(of: view))) is outside the section")
                    }
                    #expect(walked.last?.nextKeyView === walked.first, "\(section.title): Tab from the last stop does not return to the start")
                    #expect(window.makeFirstResponder(rows[0]), "\(section.title): Folders refused first responder")
                    var visited: [String] = []
                    for _ in 0..<4 {
                        window.selectNextKeyView(nil)
                        visited.append((window.firstResponder as? SidebarButton)?.title ?? NSStringFromClass(type(of: window.firstResponder as AnyObject)))
                    }
                    #expect(Array(visited.prefix(3)) == ["File types", "Search", "Indexing"], "\(section.title): selectNextKeyView from Folders visited \(visited)")
                    if let after = window.firstResponder as? NSView {
                        #expect(!(after is SidebarButton), "\(section.title): the fourth Tab from Folders landed on a sidebar row \(visited)")
                        #expect(after.isDescendant(of: pane), "\(section.title): the fourth Tab from Folders landed outside the section: \(visited)")
                    } else {
                        Issue.record("\(section.title): the fourth Tab from Folders left no view first responder: \(visited)")
                    }
                }
            }
        }
    }
}

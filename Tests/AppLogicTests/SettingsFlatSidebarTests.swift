import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private struct SFSEntry {
    let section: SettingsScreen.Section
    let name: String
}

private let sfsEntries = [
    SFSEntry(section: .folders, name: "Folders"),
    SFSEntry(section: .fileTypes, name: "File types"),
    SFSEntry(section: .search, name: "Search"),
    SFSEntry(section: .indexing, name: "Indexing"),
]

@MainActor
private func sfsRect(_ view: NSView) -> NSRect {
    view.convert(view.bounds, to: nil)
}

@MainActor
private func sfsSeparators(_ root: NSView) -> [NSView] {
    prViews(root).filter { view in
        guard plVisible(view) else { return false }
        let box = plBox(root, view)
        return box.width >= 0.99 && box.width <= 1.01 && abs(box.height - 548) <= 0.5
    }
}

@MainActor
private func sfsGlassNumber(_ glass: NSView, _ key: String) -> Double? {
    (glass.value(forKey: key) as? NSNumber)?.doubleValue
}

extension ModelDownloadTests {
    @Suite("SettingsFlatSidebarTests", .serialized)
    struct SettingsFlatSidebarTests {

        @MainActor
        @Test(arguments: slPaths)
        func theColumnIsOneViewOneEightyWideFromTheTopEdgeToTheBottomEdgeAtTheLeftEdgeNotAnAccessibilityElementAndHoldsTheFourRowsAndTheThreeTrafficLights(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let panel = try #require(sgsPanel(root), "\(look): no view of width 180 holds the four SidebarButtons")
                    let box = plBox(root, panel)
                    #expect(plVisible(panel), "\(look): the column is hidden")
                    #expect(abs(box.minX - 0) <= 0.5, "\(look): column x \(box.minX)")
                    #expect(abs(box.top - 0) <= 0.5, "\(look): column y \(box.top)")
                    #expect(abs(box.width - 180) <= 0.5, "\(look): column width \(box.width)")
                    #expect(abs(box.height - 548) <= 0.5, "\(look): column height \(box.height)")
                    #expect(!panel.isAccessibilityElement(), "\(look): the column is an accessibility element")
                    #expect(sgsButtons(root).count == 4, "\(look): \(sgsButtons(root).count) SidebarButtons")
                    #expect(sgsButtons(root).allSatisfy { $0.isDescendant(of: panel) }, "\(look): a SidebarButton is outside the column")
                    let panelRect = sfsRect(panel)
                    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                        let light = try #require(window.standardWindowButton(kind), "\(look): no standard window button \(kind.rawValue)")
                        let rect = sfsRect(light)
                        #expect(rect.width > 0 && rect.height > 0, "\(look): standard button \(kind.rawValue) has no size")
                        #expect(rect.minX >= panelRect.minX - 0.5 && rect.maxX <= panelRect.maxX + 0.5
                                && rect.minY >= panelRect.minY - 0.5 && rect.maxY <= panelRect.maxY + 0.5,
                                "\(look): standard button \(kind.rawValue) at \(rect) is outside the column \(panelRect)")
                    }
                }
            }
        }

        @MainActor
        @Test func theFlatColumnIsALayerOfRadiusZeroAndBorderZeroWithANeutralTranslucentFillThatDiffersBetweenLooksAndRepaintsWithoutARebuild() async throws {
            try await sgsWith(glass: false) { window in
                var first: NSView?
                var fills: [[CGFloat]] = []
                for look in [DTLook.light, .dark, .light] {
                    let root = sxLayout(window, .folders, look)
                    let panel = try #require(sgsPanel(root), "\(look): no column")
                    if let first { #expect(first === panel, "\(look): the column was rebuilt") } else { first = panel }
                    #expect(panel.wantsLayer && panel.layer != nil, "\(look): the column has no layer")
                    #expect(panel.layer?.cornerRadius == 0, "\(look): radius \(String(describing: panel.layer?.cornerRadius))")
                    #expect(panel.layer?.borderWidth == 0, "\(look): border width \(String(describing: panel.layer?.borderWidth))")
                    let fill = dtRGBA(cgColor: panel.layer?.backgroundColor)
                    #expect(fill != nil, "\(look): the column has no fill")
                    if let fill {
                        fills.append(fill)
                        #expect(sgsNeutral(fill), "\(look): the fill \(fill) has a hue")
                        #expect(fill[3] > 0.01 && fill[3] < 1, "\(look): the fill alpha \(fill[3]) is not translucent")
                    }
                    #expect(slGlassViews(window).isEmpty, "\(look): a glass view on the flat path")
                    #expect(prViews(root).filter { $0 is NSVisualEffectView }.isEmpty, "\(look): an effect view in the content")
                }
                #expect(fills.count == 3, "\(fills.count) fills read")
                if fills.count == 3 {
                    #expect(!dtSame(fills[0], fills[1]), "the fill is the same in Light and Dark: \(fills[0])")
                    #expect(dtSame(fills[0], fills[2]), "the fill stayed on the Dark look: Light \(fills[0]), Light again \(fills[2])")
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theGlassColumnIsExactlyOneRegularGlassViewOfRadiusZeroCoveringTheWholeColumnNotAnAccessibilityElementAndInNoCardWithNoEffectViewAnywhere() async throws {
            try await sgsWith(glass: true) { window in
                for entry in sfsEntries {
                    let root = sxLayout(window, entry.section)
                    let found = slGlassViews(window)
                    #expect(found.count == 1, "\(entry.name): \(found.count) glass views")
                    let glass = try #require(found.first, "\(entry.name): no glass view")
                    let panel = try #require(sgsPanel(root), "\(entry.name): no column")
                    #expect(NSStringFromClass(type(of: glass)) == "NSGlassEffectView")
                    #expect(sfsGlassNumber(glass, "style") == 0, "\(entry.name): glass style \(String(describing: glass.value(forKey: "style")))")
                    #expect(sfsGlassNumber(glass, "cornerRadius") == 0, "\(entry.name): glass corner radius \(String(describing: glass.value(forKey: "cornerRadius")))")
                    let glassBox = plBox(root, glass)
                    let panelBox = plBox(root, panel)
                    #expect(abs(glassBox.minX - panelBox.minX) <= 0.5 && abs(glassBox.maxX - panelBox.maxX) <= 0.5
                            && abs(glassBox.top - panelBox.top) <= 0.5 && abs(glassBox.bottom - panelBox.bottom) <= 0.5,
                            "\(entry.name): glass \(glassBox), column \(panelBox)")
                    #expect(abs(glassBox.minX - 0) <= 0.5 && abs(glassBox.maxX - 180) <= 0.5
                            && abs(glassBox.top - 0) <= 0.5 && abs(glassBox.bottom - 548) <= 0.5,
                            "\(entry.name): glass \(glassBox) does not cover x 0 to 180, y 0 to 548")
                    #expect(!glass.isAccessibilityElement(), "\(entry.name): the glass view is an accessibility element")
                    #expect(!sxAncestors(glass).contains { $0 is GroupCard }, "\(entry.name): the glass view is inside a card")
                    for card in prViews(root).compactMap({ $0 as? GroupCard }) {
                        #expect(!prViews(card).contains { slIsGlass($0) }, "\(entry.name): a card holds a glass view")
                    }
                    #expect(prViews(root).filter { $0 is NSVisualEffectView }.isEmpty, "\(entry.name): an effect view in the content")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSeparatorIsOneVisibleViewOnePointWideFullHeightAtXOneEightyInSeparatorColourOutsideTheColumnAndTheScrollViewAndRepaintsWithTheLook(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sfsEntries {
                    for look in [DTLook.light, .dark, .light] {
                        let root = sxLayout(window, entry.section, look)
                        let lines = sfsSeparators(root)
                        #expect(lines.count == 1, "\(entry.name) \(look): \(lines.count) visible views 1 pt wide and 548 tall")
                        guard let line = lines.first else { continue }
                        let box = plBox(root, line)
                        #expect(abs(box.width - 1) <= 0.01, "\(entry.name) \(look): separator width \(box.width)")
                        #expect(abs(box.height - 548) <= 0.5, "\(entry.name) \(look): separator height \(box.height)")
                        #expect(abs(box.minX - 180) <= 0.5, "\(entry.name) \(look): separator x \(box.minX)")
                        #expect(abs(box.top - 0) <= 0.5, "\(entry.name) \(look): separator y \(box.top)")
                        #expect(!line.isAccessibilityElement(), "\(entry.name) \(look): the separator is an accessibility element")
                        let colour = dtRGBA(cgColor: line.layer?.backgroundColor)
                        #expect(colour != nil && dtSame(colour ?? [], dtRGBA(.separatorColor, look)), "\(entry.name) \(look): separator colour \(String(describing: colour)), wanted \(dtRGBA(.separatorColor, look))")
                        if let panel = sgsPanel(root) {
                            #expect(line !== panel && !line.isDescendant(of: panel), "\(entry.name) \(look): the separator is inside the column")
                            #expect(!panel.isDescendant(of: line), "\(entry.name) \(look): the column is inside the separator")
                        }
                        #expect(!sxAncestors(line).contains { $0 is NSScrollView }, "\(entry.name) \(look): the separator is inside a scroll view")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func thePaneStartsRightOfTheSeparatorWithTheStripFromOneEightyOneToSevenTwentyTheTitleAtOneNinetySevenTheHairlineAndTheScrollViewFromOneEightyOneAndTheSectionFromOneNinetySevenToSevenOhFour(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sfsEntries {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, entry.section, look)
                        let titles = sgsTitles(root, entry.name)
                        #expect(titles.count == 1, "\(entry.name) \(look): \(titles.count) visible 15 pt bold texts with that name")
                        let title = try #require(titles.first, "\(entry.name) \(look): no pane title")
                        #expect(title.isAccessibilityElement() && title.accessibilityRole() == .staticText, "\(entry.name) \(look): the title is not an AXStaticText")
                        #expect(sxColour(title.textColor, is: .labelColor), "\(entry.name) \(look): title colour")
                        let strip = try #require(sgsStrip(root, title: title), "\(entry.name) \(look): the title is in no view of 46 x 539 at the top of the pane (181 to 720)")
                        let stripBox = plBox(root, strip)
                        #expect(abs(stripBox.minX - 181) <= 0.5 && abs(stripBox.maxX - 720) <= 0.5, "\(entry.name) \(look): strip spans \(stripBox.minX) to \(stripBox.maxX)")
                        #expect(abs(stripBox.top - 0) <= 0.5 && abs(stripBox.bottom - 46) <= 0.5, "\(entry.name) \(look): strip y \(stripBox.top) to \(stripBox.bottom)")
                        let titleBox = sxAlignBox(root, title)
                        #expect(abs(titleBox.minX - 197) <= 1, "\(entry.name) \(look): title left edge \(titleBox.minX)")
                        #expect(abs((titleBox.top + titleBox.bottom) / 2 - 23) <= 1.5, "\(entry.name) \(look): title centre \((titleBox.top + titleBox.bottom) / 2) in a strip 46 tall")
                        let lines = sgsHairlines(root, panel: sgsPanel(root))
                        #expect(lines.count == 1, "\(entry.name) \(look): \(lines.count) hairlines along the strip's bottom edge")
                        if let line = lines.first {
                            let lineBox = plBox(root, line)
                            #expect(abs(lineBox.minX - 181) <= 1 && abs(lineBox.maxX - 720) <= 1, "\(entry.name) \(look): hairline spans \(lineBox.minX) to \(lineBox.maxX)")
                        }
                        let section = try #require(sgsSection(root, entry.section), "\(entry.name) \(look): no section view")
                        let scroll = try #require(sxAncestors(section).compactMap { $0 as? NSScrollView }.first, "\(entry.name) \(look): no scroll view around the section")
                        let scrollBox = plBox(root, scroll)
                        #expect(abs(scrollBox.minX - 181) <= 0.5, "\(entry.name) \(look): the scroll view starts at x \(scrollBox.minX)")
                        #expect(abs(scrollBox.top - 46) <= 0.5, "\(entry.name) \(look): the scroll view starts at y \(scrollBox.top)")
                        #expect(abs(scrollBox.maxX - 720) <= 0.5, "\(entry.name) \(look): the scroll view ends at x \(scrollBox.maxX)")
                        let box = plBox(root, section)
                        #expect(abs(box.minX - 197) <= 1, "\(entry.name) \(look): section left edge \(box.minX)")
                        #expect(abs(box.maxX - 704) <= 1, "\(entry.name) \(look): section right edge \(box.maxX)")
                        #expect(abs(box.top - 46 - 16) <= 2, "\(entry.name) \(look): the section starts \(box.top - 46) under the strip")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theFourRowsAreTwentyEightTallTwoApartFromXEightToOneSeventyTwoTheFirstTopFortySixAndTheLastBottomOneSixtyFour(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let buttons = sgsButtons(root)
                    #expect(buttons.map(\.title) == sfsEntries.map(\.name), "\(look): titles \(buttons.map(\.title))")
                    for button in buttons {
                        let box = plBox(root, button)
                        #expect(abs(box.height - 28) <= 0.5, "\(button.title) \(look): height \(box.height)")
                        #expect(abs(box.minX - 8) <= 0.5, "\(button.title) \(look): left edge \(box.minX)")
                        #expect(abs(box.maxX - 172) <= 0.5, "\(button.title) \(look): right edge \(box.maxX)")
                    }
                    for (above, below) in zip(buttons, buttons.dropFirst()) {
                        let gap = plBox(root, below).top - plBox(root, above).bottom
                        #expect(abs(gap - 2) <= 0.5, "\(above.title) to \(below.title) \(look): gap \(gap)")
                    }
                    if let first = buttons.first {
                        #expect(abs(plBox(root, first).top - 46) <= 1, "\(look): the first row's top is \(plBox(root, first).top)")
                    }
                    if let last = buttons.last {
                        #expect(abs(plBox(root, last).bottom - 164) <= 1, "\(look): the last row's bottom is \(plBox(root, last).bottom)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSelectedRowIsTheAccentFillOfRadiusEightAndTheOtherThreeDrawNoFillInEverySectionAndBothLooks(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sfsEntries {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, entry.section, look)
                        for button in sgsButtons(root) {
                            let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
                            if button.title == entry.name {
                                #expect(button.layer?.cornerRadius == 8, "\(entry.name) \(look): radius \(String(describing: button.layer?.cornerRadius))")
                                #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.controlAccentColor, look)), "\(entry.name) \(look): fill \(String(describing: fill))")
                            } else {
                                #expect(fill == nil || (fill?[3] ?? 1) < 0.01, "\(button.title) \(look): draws a fill while \(entry.name) is selected")
                            }
                        }
                    }
                }
            }
        }
    }
}

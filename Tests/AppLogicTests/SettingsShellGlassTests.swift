import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private struct SGSEntry {
    let section: SettingsScreen.Section
    let name: String
}

private let sgsEntries = [
    SGSEntry(section: .folders, name: "Folders"),
    SGSEntry(section: .fileTypes, name: "File types"),
    SGSEntry(section: .search, name: "Search"),
    SGSEntry(section: .indexing, name: "Indexing"),
]

@MainActor
func sgsWith(glass: Bool, _ body: @MainActor (SettingsContainerWindow) async throws -> Void) async throws {
    try await sxWithWindow(make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(), glass: glass)
    }) { window, _ in
        try await body(window)
    }
}

@MainActor
private func sgsRect(_ view: NSView) -> NSRect {
    view.convert(view.bounds, to: nil)
}

@MainActor
private func sgsGlassValue(_ glass: NSView, _ key: String) -> Int? {
    (glass.value(forKey: key) as? NSNumber)?.intValue
}

@MainActor
private func sgsParts(_ section: NSView) -> [NSView] {
    prViews(section).filter { view in
        guard plVisible(view), !(view is NSScroller), view.frame.width > 0, view.frame.height > 0 else { return false }
        if let field = view as? NSTextField { return !field.stringValue.isEmpty }
        return view is NSControl
    }
}

extension ModelDownloadTests {
    @Suite("SettingsShellGlassTests", .serialized)
    struct SettingsShellGlassTests {

        @MainActor
        @Test(arguments: slPaths)
        func theWindowIsTitledSettingsFullSizeContentWithATransparentTitleBarAHiddenTitleAndNotResizable(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                let root = sxRelayout(window)
                let mask = window.styleMask
                let transparent = window.titlebarAppearsTransparent
                let visibility = window.titleVisibility
                let hasToolbar = window.toolbar != nil
                #expect(window.title == "Settings")
                #expect(mask.contains(.fullSizeContentView), "style mask \(mask.rawValue)")
                #expect(mask.contains(.titled) && mask.contains(.closable), "style mask \(mask.rawValue)")
                #expect(!mask.contains(.resizable), "the window is resizable")
                #expect(transparent, "the title bar is not transparent")
                #expect(visibility == .hidden, "title visibility \(visibility.rawValue)")
                #expect(!hasToolbar, "the window has a toolbar")
                #expect(SettingsContainerWindow.size == NSSize(width: 720, height: 520), "static size \(SettingsContainerWindow.size)")
                for entry in sgsEntries {
                    let shown = sxLayout(window, entry.section)
                    #expect(window.title == "Settings", "\(entry.name): title \"\(window.title)\"")
                    #expect(window.frame.size == NSSize(width: 720, height: 548), "\(entry.name): frame \(window.frame.size)")
                    #expect(shown.frame.size == NSSize(width: 720, height: 548), "\(entry.name): content view \(shown.frame.size)")
                    #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 720, height: 548), "\(entry.name): content rect \(window.contentRect(forFrameRect: window.frame).size)")
                }
                #expect(root.frame.size == NSSize(width: 720, height: 548), "content view \(root.frame.size)")
            }
        }

        @MainActor
        @Test func aWindowBuiltWithoutTheGlassArgumentTakesTheGlassPathExactlyWhenGlassIsAvailable() async throws {
            try await sxWith { window, _ in
                _ = sxRelayout(window)
                let count = slGlassViews(window).count
                #expect(count == (Glass.isAvailable ? 1 : 0), "\(count) glass views, glass available \(Glass.isAvailable)")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theFlatWindowHoldsNoGlassViewAndTheGlassWindowExactlyOneAndNeitherHoldsAnEffectViewInItsContent(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sgsEntries {
                    let root = sxLayout(window, entry.section)
                    let count = slGlassViews(window).count
                    #expect(count == (glass ? 1 : 0), "\(entry.name): \(count) glass views with glass \(glass)")
                    let effects = prViews(root).filter { $0 is NSVisualEffectView }
                    #expect(effects.isEmpty, "\(entry.name): effect views in the content \(effects.map { NSStringFromClass(type(of: $0)) })")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSidebarPanelIsOneViewOneEightyWideFlushWithTheContentEdgesNotAnAccessibilityElementAndHoldsTheFourButtonsAndNoOtherText(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                let root = sxRelayout(window)
                let buttons = sgsButtons(root)
                #expect(buttons.count == 4, "\(buttons.count) SidebarButtons")
                let panel = try #require(sgsPanel(root), "no view of width 180 holds all four SidebarButtons")
                let box = plBox(root, panel)
                #expect(plVisible(panel))
                #expect(abs(box.width - 180) <= 0.5, "panel width \(box.width)")
                #expect(abs(box.minX - 0) <= 0.5, "panel left edge \(box.minX)")
                #expect(abs(box.top - 0) <= 0.5, "panel top edge \(box.top)")
                #expect(abs((root.bounds.height - box.bottom) - 0) <= 0.5, "panel bottom edge \(root.bounds.height - box.bottom) from the window bottom")
                #expect(abs(box.height - 548) <= 0.5, "panel height \(box.height)")
                #expect(abs(root.bounds.height - 548) <= 0.5, "content height \(root.bounds.height)")
                #expect(!panel.isAccessibilityElement(), "the panel is an accessibility element")
                #expect(buttons.allSatisfy { $0.isDescendant(of: panel) }, "a SidebarButton is outside the panel")
                let outside = prViews(root).compactMap { $0 as? NSTextField }.filter {
                    $0.isDescendant(of: panel) && plVisible($0) && !$0.stringValue.isEmpty && !sxAncestors($0).contains { $0 is NSButton }
                }
                #expect(outside.isEmpty, "text inside the panel: \(outside.map(\.stringValue))")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theTrafficLightsSitInsideThePanel(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                let root = sxRelayout(window)
                window.layoutIfNeeded()
                let panel = try #require(sgsPanel(root), "no panel")
                let panelRect = sgsRect(panel)
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let light = try #require(window.standardWindowButton(kind), "no standard window button \(kind.rawValue)")
                    #expect(!light.isHidden, "standard button \(kind.rawValue) is hidden")
                    let rect = sgsRect(light)
                    #expect(rect.width > 0 && rect.height > 0, "standard button \(kind.rawValue) has no size")
                    #expect(rect.minX >= panelRect.minX - 0.5 && rect.maxX <= panelRect.maxX + 0.5
                            && rect.minY >= panelRect.minY - 0.5 && rect.maxY <= panelRect.maxY + 0.5,
                            "standard button \(kind.rawValue) at \(rect) is outside the panel \(panelRect)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func noSearchFieldAndNoBackOrForwardButtonIsAnywhereInTheWindow(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sgsEntries {
                    let root = sxLayout(window, entry.section)
                    #expect(prViews(root.superview ?? root).compactMap { $0 as? NSSearchField }.isEmpty, "\(entry.name): a search field is in the window")
                    let navigation = prViews(root).compactMap { $0 as? NSButton }.filter { button in
                        guard plVisible(button) else { return false }
                        let words = ["back", "forward", "go back", "go forward", "previous", "next"]
                        let labels = [button.title, button.accessibilityLabel() ?? "", button.accessibilityTitle() ?? ""].map { $0.lowercased() }
                        let symbol = button.image?.description ?? ""
                        return labels.contains { words.contains($0) } || symbol.contains("chevron.left") || symbol.contains("chevron.right")
                    }
                    #expect(navigation.isEmpty, "\(entry.name): back or forward buttons \(navigation.map(\.title))")
                }
            }
        }

        @MainActor
        @Test func theFlatPanelIsALayerOfRadiusZeroWithANeutralTranslucentFillAndNoBorderInBothLooks() async throws {
            try await sgsWith(glass: false) { window in
                var fills: [[CGFloat]] = []
                for look in [DTLook.light, .dark, .light] {
                    let root = sxLayout(window, .folders, look)
                    let panel = try #require(sgsPanel(root), "no panel")
                    if let fill = dtRGBA(cgColor: panel.layer?.backgroundColor) { fills.append(fill) }
                    #expect(panel.wantsLayer && panel.layer != nil, "\(look): the panel has no layer")
                    #expect(panel.layer?.cornerRadius == 0, "\(look): radius \(String(describing: panel.layer?.cornerRadius))")
                    let fill = dtRGBA(cgColor: panel.layer?.backgroundColor)
                    #expect(fill != nil, "\(look): the panel has no fill")
                    if let fill {
                        #expect(sgsNeutral(fill), "\(look): the fill \(fill) has a hue")
                        #expect(fill[3] > 0.01 && fill[3] < 1, "\(look): the fill alpha \(fill[3]) is not translucent")
                    }
                    #expect(panel.layer?.borderWidth == 0, "\(look): border width \(String(describing: panel.layer?.borderWidth))")
                    #expect(slGlassViews(window).isEmpty, "\(look): a glass view on the flat path")
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
        func theGlassPanelIsOneRegularGlassViewOfRadiusZeroOnThePanelNotAnAccessibilityElementAndInNoCard() async throws {
            try await sgsWith(glass: true) { window in
                for entry in sgsEntries {
                    let root = sxLayout(window, entry.section)
                    let found = slGlassViews(window)
                    #expect(found.count == 1, "\(entry.name): \(found.count) glass views")
                    let glass = try #require(found.first, "\(entry.name): no glass view")
                    let panel = try #require(sgsPanel(root), "\(entry.name): no panel")
                    #expect(NSStringFromClass(type(of: glass)) == "NSGlassEffectView")
                    #expect(sgsGlassValue(glass, "style") == 0, "\(entry.name): glass style \(String(describing: glass.value(forKey: "style")))")
                    let radius = (glass.value(forKey: "cornerRadius") as? NSNumber)?.doubleValue
                    #expect(radius == 0, "\(entry.name): glass corner radius \(String(describing: radius))")
                    #expect(!glass.isAccessibilityElement(), "\(entry.name): the glass view is an accessibility element")
                    let content = glass.value(forKey: "contentView") as? NSView
                    #expect(content?.isAccessibilityElement() != true, "\(entry.name): the glass content view is an accessibility element")
                    #expect(glass === panel || glass.isDescendant(of: panel) || panel.isDescendant(of: glass), "\(entry.name): the glass view is not the panel")
                    let glassBox = plBox(root, glass)
                    let panelBox = plBox(root, panel)
                    #expect(abs(glassBox.minX - panelBox.minX) <= 0.5 && abs(glassBox.maxX - panelBox.maxX) <= 0.5
                            && abs(glassBox.top - panelBox.top) <= 0.5 && abs(glassBox.bottom - panelBox.bottom) <= 0.5,
                            "\(entry.name): glass \(glassBox), panel \(panelBox)")
                    #expect(!sxAncestors(glass).contains { $0 is GroupCard }, "\(entry.name): the glass view is inside a card")
                    for card in prViews(root).compactMap({ $0 as? GroupCard }) {
                        #expect(!prViews(card).contains { slIsGlass($0) }, "\(entry.name): a card holds a glass view")
                    }
                    if let section = sgsSection(root, entry.section) {
                        #expect(!sxAncestors(section).contains { slIsGlass($0) }, "\(entry.name): the section sits inside the glass view")
                    }
                    #expect(prViews(root).filter { $0 is NSVisualEffectView }.isEmpty, "\(entry.name): an effect view in the content")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theStripIsFortySixTallAtTheTopOfThePaneFromOneEightyOneToSevenTwentyOutsideTheScrollViewAndTheTitleIsOneStaticTextCentredInIt(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sgsEntries {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, entry.section, look)
                        let titles = sgsTitles(root, entry.name)
                        #expect(titles.count == 1, "\(entry.name) \(look): \(titles.count) visible 15 pt bold texts with that name")
                        let title = try #require(titles.first, "\(entry.name): no pane title")
                        #expect(title.isAccessibilityElement(), "\(entry.name): the title is not an accessibility element")
                        #expect(title.accessibilityRole() == .staticText, "\(entry.name): role \(String(describing: title.accessibilityRole()))")
                        #expect(sxColour(title.textColor, is: .labelColor), "\(entry.name) \(look): title colour")
                        for other in sgsEntries where other.name != entry.name {
                            #expect(sgsTitles(root, other.name).isEmpty, "\(entry.name): a title reading \"\(other.name)\" is visible")
                        }
                        let strip = try #require(sgsStrip(root, title: title), "\(entry.name): the title is in no view of 46 x 539 at the top of the pane (181 to 720)")
                        let stripBox = plBox(root, strip)
                        #expect(plVisible(strip))
                        #expect(abs(stripBox.minX - 181) <= 0.5 && abs(stripBox.maxX - 720) <= 0.5, "\(entry.name): strip spans \(stripBox.minX) to \(stripBox.maxX)")
                        #expect(abs(stripBox.top) <= 0.5 && abs(stripBox.height - 46) <= 0.5, "\(entry.name): strip top \(stripBox.top), height \(stripBox.height)")
                        #expect(!sxAncestors(strip).contains { $0 is NSScrollView }, "\(entry.name): the strip is inside a scroll view")
                        #expect(!prViews(strip).contains { $0 is NSScrollView }, "\(entry.name): a scroll view is inside the strip")
                        let titleBox = sxAlignBox(root, title)
                        #expect(abs(titleBox.minX - 197) <= 1, "\(entry.name): title left edge \(titleBox.minX)")
                        #expect(abs((titleBox.top + titleBox.bottom) / 2 - (stripBox.top + stripBox.bottom) / 2) <= 1.5,
                                "\(entry.name): title centre \((titleBox.top + titleBox.bottom) / 2), strip centre \((stripBox.top + stripBox.bottom) / 2)")
                        #expect(titleBox.maxX <= 704.5, "\(entry.name): title right edge \(titleBox.maxX)")
                        let panel = try #require(sgsPanel(root), "\(entry.name): no panel")
                        #expect(!title.isDescendant(of: panel), "\(entry.name): the title is inside the panel")
                        let all = prViews(root)
                        let titleIndex = all.firstIndex { $0 === title } ?? -1
                        let lastButton = sgsButtons(root).compactMap { button in all.firstIndex { $0 === button } }.max() ?? Int.max
                        #expect(titleIndex > lastButton, "\(entry.name): the title is at tree position \(titleIndex), the last sidebar row at \(lastButton)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func aHairlineInSeparatorColourRunsTheFullPaneWidthAlongTheStripsBottomEdgeAndIsNotAnAccessibilityElement(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sgsEntries {
                    for look in [DTLook.light, .dark, .light] {
                        let root = sxLayout(window, entry.section, look)
                        let lines = sgsHairlines(root, panel: sgsPanel(root))
                        #expect(lines.count == 1, "\(entry.name) \(look): \(lines.count) hairlines along the strip's bottom edge")
                        guard let line = lines.first else { continue }
                        let box = plBox(root, line)
                        #expect(abs(box.minX - 181) <= 1 && abs(box.maxX - 720) <= 1, "\(entry.name) \(look): hairline spans \(box.minX) to \(box.maxX)")
                        #expect([0.5, 1.0].contains(line.frame.height), "\(entry.name) \(look): hairline height \(line.frame.height)")
                        #expect(!line.isAccessibilityElement(), "\(entry.name) \(look): the hairline is an accessibility element")
                        let colour = dtRGBA(cgColor: line.layer?.backgroundColor)
                        #expect(colour != nil && dtSame(colour ?? [], dtRGBA(.separatorColor, look)), "\(entry.name) \(look): hairline colour \(String(describing: colour))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theStripAndItsTitleStayInPlaceWhenTheSectionScrolls(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sgsEntries {
                    let root = sxLayout(window, entry.section)
                    let title = try #require(sgsTitles(root, entry.name).first, "\(entry.name): no pane title")
                    let strip = try #require(sgsStrip(root, title: title), "\(entry.name): no strip")
                    let section = try #require(sgsSection(root, entry.section), "\(entry.name): no section view")
                    let scroll = try #require(sxAncestors(section).compactMap { $0 as? NSScrollView }.first, "\(entry.name): no scroll view around the section")
                    #expect(!scroll.isDescendant(of: strip), "\(entry.name): the scroll view is inside the strip")
                    let stripBefore = plBox(root, strip)
                    let titleBefore = plBox(root, title)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    root.layoutSubtreeIfNeeded()
                    let stripAfter = plBox(root, strip)
                    let titleAfter = plBox(root, title)
                    #expect(abs(stripAfter.top - stripBefore.top) <= 0.5 && abs(stripAfter.bottom - stripBefore.bottom) <= 0.5, "\(entry.name): the strip moved from \(stripBefore) to \(stripAfter)")
                    #expect(abs(titleAfter.top - titleBefore.top) <= 0.5 && abs(titleAfter.minX - titleBefore.minX) <= 0.5, "\(entry.name): the title moved from \(titleBefore) to \(titleAfter)")
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theScrollViewIsBorderlessFromOneEightyOneAndFortySixToTheWindowsEdgeAndEachSectionSpansOneNinetySevenToSevenOhFourStartingSixteenUnderTheStrip(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for entry in sgsEntries {
                    let root = sxLayout(window, entry.section)
                    let section = try #require(sgsSection(root, entry.section), "\(entry.name): no section view")
                    #expect(plVisible(section))
                    let scrolls = sxAncestors(section).compactMap { $0 as? NSScrollView }
                    #expect(scrolls.count == 1, "\(entry.name): \(scrolls.count) scroll views around the section")
                    let scroll = try #require(scrolls.first)
                    #expect(scroll.borderType == .noBorder, "\(entry.name): border type \(scroll.borderType.rawValue)")
                    let scrollBox = plBox(root, scroll)
                    #expect(abs(scrollBox.minX - 181) <= 0.5, "\(entry.name): the scroll view starts at x \(scrollBox.minX)")
                    #expect(abs(scrollBox.top - 46) <= 1, "\(entry.name): the scroll view starts at y \(scrollBox.top)")
                    #expect(abs(scrollBox.maxX - 720) <= 0.5, "\(entry.name): the scroll view ends at x \(scrollBox.maxX)")
                    #expect(scrollBox.bottom <= 548.5, "\(entry.name): the scroll view ends at y \(scrollBox.bottom)")
                    let box = plBox(root, section)
                    #expect(abs(box.minX - 197) <= 1, "\(entry.name): section left edge \(box.minX)")
                    #expect(abs(box.maxX - 704) <= 1, "\(entry.name): section right edge \(box.maxX)")
                    #expect(abs(box.top - 46 - 16) <= 2, "\(entry.name): the section starts \(box.top - 46) under the strip")
                    let bottoms = sgsParts(section).map { plBox(root, $0).bottom }
                    #expect(bottoms.allSatisfy { $0 <= 548 - 20 + 0.5 }, "\(entry.name): the lowest part ends at y \(bottoms.max() ?? 0) of 548")
                    for part in sgsParts(root) where !(sgsPanel(root).map { part.isDescendant(of: $0) } ?? false) {
                        #expect(plBox(root, part).maxX <= 704.5, "\(entry.name): a part reaches x \(plBox(root, part).maxX)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theFourRowsAreTwentyEightTallTwoApartInsetEightInThePanelTheFirstFortySixFromTheWindowTopAndDrawThirteenRegularLabelText(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                let order = sgsEntries
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let panel = try #require(sgsPanel(root), "no panel")
                    let panelBox = plBox(root, panel)
                    let buttons = sgsButtons(root)
                    #expect(buttons.map(\.title) == order.map(\.name), "\(look): titles \(buttons.map(\.title))")
                    for (button, entry) in zip(buttons, order) {
                        let box = plBox(root, button)
                        #expect(abs(box.height - 28) <= 0.5, "\(entry.name) \(look): height \(box.height)")
                        #expect(abs(box.minX - panelBox.minX - 8) <= 0.5, "\(entry.name) \(look): left inset \(box.minX - panelBox.minX)")
                        #expect(abs(panelBox.maxX - box.maxX - 8) <= 0.5, "\(entry.name) \(look): right inset \(panelBox.maxX - box.maxX)")
                        #expect(button.image?.isTemplate == true, "\(entry.name): the symbol is not a template (monochrome) image")
                        let font = button.attributedTitle.length > 0 ? button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
                        #expect(sxFont(font, size: 13, weight: .regular), "\(entry.name) \(look): title font \(String(describing: font))")
                        #expect(button.accessibilityLabel() == entry.name, "\(entry.name): label \(String(describing: button.accessibilityLabel()))")
                        #expect(button.cell?.accessibilityRole()?.rawValue == "AXCheckBox", "\(entry.name): role \(String(describing: button.cell?.accessibilityRole()))")
                        #expect(button.cell?.accessibilitySubrole()?.rawValue == "AXToggle", "\(entry.name): subrole \(String(describing: button.cell?.accessibilitySubrole()))")
                        let value = (button.cell?.accessibilityValue() as? NSNumber)?.intValue
                        #expect(value == (entry.section == .folders ? 1 : 0), "\(entry.name) \(look): value \(String(describing: value))")
                        if entry.section == .folders {
                            #expect(button.isSelected)
                        } else {
                            let ink = plRGBAOfAttribute(button.attributedTitle, look)
                            #expect(ink != nil && dtSame(ink ?? [], dtRGBA(.labelColor, look)), "\(entry.name) \(look): unselected text colour \(String(describing: ink))")
                            let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
                            #expect(fill == nil || (fill?[3] ?? 1) < 0.01, "\(entry.name) \(look): an unselected row draws a fill")
                        }
                    }
                    if let first = buttons.first {
                        #expect(abs(plBox(root, first).top - 46) <= 1, "\(look): the first row's top is \(plBox(root, first).top) from the window top")
                    }
                    for (above, below) in zip(buttons, buttons.dropFirst()) {
                        let gap = plBox(root, below).top - plBox(root, above).bottom
                        #expect(abs(gap - 2) <= 0.5, "\(above.title) to \(below.title) \(look): gap \(gap)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSelectedRowIsAnAccentFillOfRadiusEightDrawingTheSelectedTextColourInTitleAndSymbolAndRepaintsWhenTheLookChanges(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in [SettingsScreen.Section.folders, .indexing] {
                    let entry = try #require(sgsEntries.first { $0.section == section })
                    for look in [DTLook.light, .dark, .light] {
                        let root = sxLayout(window, section, look)
                        for button in sgsButtons(root) {
                            let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
                            if button.title == entry.name {
                                #expect(button.layer?.cornerRadius == 8, "\(entry.name) \(look): radius \(String(describing: button.layer?.cornerRadius))")
                                #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.controlAccentColor, look)), "\(entry.name) \(look): fill \(String(describing: fill))")
                                let ink = plRGBAOfAttribute(button.attributedTitle, look)
                                #expect(ink != nil && dtSame(ink ?? [], dtRGBA(.alternateSelectedControlTextColor, look)), "\(entry.name) \(look): title colour \(String(describing: ink))")
                                #expect(dtSame(dtRGBA(button.contentTintColor ?? .clear, look), dtRGBA(.alternateSelectedControlTextColor, look)), "\(entry.name) \(look): symbol colour")
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

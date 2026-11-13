import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let ft4Sections: [SettingsScreen.Section] = [.folders, .fileTypes, .search, .indexing]
private let ft4NeverAsked = "Sesame never asks for Full Disk Access, camera or microphone."

@MainActor
private func ft4Labels(_ view: NSView) -> [String] {
    var out = [view.accessibilityLabel(), view.accessibilityTitle()].compactMap { $0 }
    if let control = view as? NSControl, let label = control.cell?.accessibilityLabel() { out.append(label) }
    if let button = view as? NSButton { out.append(button.title) }
    if let field = view as? NSTextField { out.append(field.stringValue) }
    return out
}

@MainActor
private func ft4Walk(_ window: NSWindow) -> [NSView] {
    var walked: [NSView] = []
    var current: NSView? = window.initialFirstResponder
    while let view = current, walked.count < 200, !walked.contains(where: { $0 === view }) {
        walked.append(view)
        current = view.nextKeyView
    }
    return walked
}

private func ft4Strings(_ screen: SettingsScreen) -> [String] {
    screen.texts + screen.controls.map(\.label)
}

extension ModelDownloadTests {
    @Suite("SettingsFourTabsTests", .serialized)
    struct SettingsFourTabsTests {

        @Test func theSectionsAreFoldersFileTypesSearchIndexingInThatOrderWithTheirRawValuesAndNoAboutRawValue() {
            #expect(SettingsScreen.Section.allCases.map(\.title) == ["Folders", "File types", "Search", "Indexing"],
                    "titles \(SettingsScreen.Section.allCases.map(\.title))")
            #expect(SettingsScreen.Section.allCases.map(\.rawValue) == ["folders", "fileTypes", "search", "indexing"],
                    "raw values \(SettingsScreen.Section.allCases.map(\.rawValue))")
            #expect(SettingsScreen.Section(rawValue: "about") == nil, "a section has the raw value about")
        }

        @MainActor
        @Test func everyScreenHasFourSectionsStartsOnFoldersAndHoldsNoAboutVersionOrNeverAskedText() async throws {
            try await sxWith { window, _ in
                let model = window.model
                let first = SettingsScreen(model: model)
                #expect(first.section == .folders, "the default section is \(first.section.title)")
                #expect(first.sections.count == 4, "\(first.sections.count) sections")
                #expect(first.sections.map(\.title) == ["Folders", "File types", "Search", "Indexing"], "sections \(first.sections.map(\.title))")
                for section in SettingsScreen.Section.allCases {
                    let screen = SettingsScreen(model: model, section: section)
                    #expect(screen.section == section, "asked for \(section.title), got \(screen.section.title)")
                    #expect(screen.sections.count == 4, "\(section.title): \(screen.sections.count) sections")
                    #expect(screen.texts.first == section.title, "\(section.title): the first text is \(String(describing: screen.texts.first))")
                    let strings = ft4Strings(screen)
                    #expect(!strings.contains("About"), "\(section.title): a string reads About in \(strings)")
                    #expect(!strings.contains { $0.hasPrefix("Version ") }, "\(section.title): a string starts with Version in \(strings)")
                    #expect(!strings.contains(ft4NeverAsked), "\(section.title): the never-asked line is in \(strings)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theWindowDrawsFourSectionsAndNoStringOrViewNamedAbout(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in SettingsScreen.Section.allCases {
                    let root = sxLayout(window, section)
                    let screen = window.settingsScreen
                    #expect(screen.sections.count == 4, "\(section.title): the window's screen has \(screen.sections.count) sections")
                    #expect(!ft4Strings(screen).contains("About"), "\(section.title): the window's screen holds About")
                    #expect(!ft4Strings(screen).contains { $0.hasPrefix("Version ") }, "\(section.title): the window's screen holds a Version text")
                    #expect(!ft4Strings(screen).contains(ft4NeverAsked), "\(section.title): the window's screen holds the never-asked line")
                    let views = prViews(root)
                    let named = views.filter { ft4Labels($0).contains("About") }
                    #expect(named.isEmpty, "\(section.title): views labelled About: \(named.map { NSStringFromClass(type(of: $0)) })")
                    let classes = views.map { NSStringFromClass(type(of: $0)) }.filter { $0.contains("About") }
                    #expect(classes.isEmpty, "\(section.title): view classes named About: \(classes)")
                    let versions = views.filter { ft4Labels($0).contains { $0.hasPrefix("Version ") } }
                    #expect(versions.isEmpty, "\(section.title): views with a Version text: \(versions.map { NSStringFromClass(type(of: $0)) })")
                    #expect(window.title == "Settings", "\(section.title): title \"\(window.title)\"")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theSidebarHasExactlyFourRowsInOrderTwentyEightTallTwoApartInsetEightTheFirstFortySixAndTheLastOneSixtyFourFromTheWindowTop(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    let buttons = sgsButtons(root)
                    #expect(buttons.map(\.title) == ["Folders", "File types", "Search", "Indexing"], "\(look): titles \(buttons.map(\.title))")
                    let panel = try #require(sgsPanel(root), "\(look): no view of width 180 holds exactly four SidebarButtons")
                    let panelBox = plBox(root, panel)
                    for button in buttons {
                        let box = plBox(root, button)
                        #expect(abs(box.height - 28) <= 1, "\(button.title) \(look): height \(box.height)")
                        #expect(abs(box.minX - panelBox.minX - 8) <= 0.5, "\(button.title) \(look): left inset \(box.minX - panelBox.minX)")
                        #expect(abs(panelBox.maxX - box.maxX - 8) <= 0.5, "\(button.title) \(look): right inset \(panelBox.maxX - box.maxX)")
                    }
                    for (above, below) in zip(buttons, buttons.dropFirst()) {
                        let gap = plBox(root, below).top - plBox(root, above).bottom
                        #expect(abs(gap - 2) <= 1, "\(above.title) to \(below.title) \(look): gap \(gap)")
                    }
                    if let first = buttons.first {
                        #expect(abs(plBox(root, first).top - 46) <= 1, "\(look): the first row's top is \(plBox(root, first).top) from the window top")
                    }
                    if let last = buttons.last {
                        #expect(abs(plBox(root, last).bottom - 164) <= 1, "\(look): the last row's bottom is \(plBox(root, last).bottom) from the window top")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func thePanelIsOneViewOneEightyWideFlushOnThreeSidesAsTallAsTheWindowAndNotShortenedToItsRows(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for look in DTLook.allCases {
                    let root = sxLayout(window, .folders, look)
                    #expect(sgsButtons(root).count == 4, "\(look): \(sgsButtons(root).count) SidebarButtons")
                    let panel = try #require(sgsPanel(root), "\(look): no view of width 180 holds exactly four SidebarButtons")
                    let box = plBox(root, panel)
                    #expect(abs(box.width - 180) <= 0.5, "\(look): panel width \(box.width)")
                    #expect(abs(box.minX - 0) <= 0.5, "\(look): panel left edge \(box.minX)")
                    #expect(abs(box.top - 0) <= 0.5, "\(look): panel top edge \(box.top)")
                    #expect(abs((root.bounds.height - box.bottom) - 0) <= 0.5, "\(look): panel bottom edge \(root.bounds.height - box.bottom) from the content bottom")
                    #expect(abs(box.height - 548) <= 0.5, "\(look): panel height \(box.height)")
                    #expect(abs(root.bounds.height - 548) <= 0.5, "\(look): content height \(root.bounds.height)")
                    #expect(!panel.isAccessibilityElement(), "\(look): the panel is an accessibility element")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theWindowIsSevenTwentyByFiveFortyEightWithAStaticSizeOfSevenTwentyByFiveTwentyAndTitledSettingsInAllFourSections(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                #expect(SettingsContainerWindow.size == NSSize(width: 720, height: 520), "static size \(SettingsContainerWindow.size)")
                for section in ft4Sections {
                    let root = sxLayout(window, section)
                    #expect(window.title == "Settings", "\(section.title): title \"\(window.title)\"")
                    #expect(window.frame.size == NSSize(width: 720, height: 548), "\(section.title): frame \(window.frame.size)")
                    #expect(root.frame.size == NSSize(width: 720, height: 548), "\(section.title): content view \(root.frame.size)")
                    #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 720, height: 548), "\(section.title): content rect \(window.contentRect(forFrameRect: window.frame).size)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func pressingEachOfTheFourRowsSelectsItsSectionTitlesThePaneAndMarksOnlyThatRowWithValueOneAndRefreshKeepsIt(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                let order: [(String, SettingsScreen.Section)] = [
                    ("Indexing", .indexing), ("Search", .search), ("File types", .fileTypes), ("Folders", .folders),
                ]
                for (name, section) in order {
                    let before = sxRelayout(window)
                    let button = try #require(sgsButtons(before).first { $0.title == name }, "no SidebarButton titled \(name)")
                    button.performClick(nil)
                    await Task.yield()
                    #expect(window.settingsScreen.section == section, "after \(name): the window draws \(window.settingsScreen.section.title)")
                    let root = sxRelayout(window)
                    let titles = sgsTitles(root, name)
                    #expect(titles.count == 1, "\(name): \(titles.count) pane titles")
                    if let title = titles.first {
                        #expect(title.isAccessibilityElement(), "\(name): the pane title is not an accessibility element")
                        #expect(title.accessibilityRole() == .staticText, "\(name): pane title role \(String(describing: title.accessibilityRole()))")
                        #expect(title.stringValue == name, "\(name): pane title reads \(title.stringValue)")
                    }
                    for other in ["Folders", "File types", "Search", "Indexing"] where other != name {
                        #expect(sgsTitles(root, other).isEmpty, "\(name): a pane title reads \(other)")
                    }
                    let buttons = sgsButtons(root)
                    #expect(buttons.count == 4, "after \(name): \(buttons.count) SidebarButtons")
                    for row in buttons {
                        let value = (row.cell?.accessibilityValue() as? NSNumber)?.intValue
                        #expect(value == (row.title == name ? 1 : 0), "after \(name): \(row.title) reports value \(String(describing: value))")
                    }
                    window.refresh()
                    #expect(window.settingsScreen.section == section, "refresh moved the window from \(name) to \(window.settingsScreen.section.title)")
                    #expect(sgsButtons(sxRelayout(window)).filter(\.isSelected).map(\.title) == [name], "after refresh the selected rows are \(sgsButtons(sxRelayout(window)).filter(\.isSelected).map(\.title))")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func tabStartsAtTheFirstSidebarRowVisitsTheFourRowsInOrderThenTheSelectedSectionsControlsAndComesBackToTheStartInEachSection(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in ft4Sections {
                    let root = sxLayout(window, section)
                    let rows = sgsButtons(root)
                    #expect(rows.map(\.title) == ["Folders", "File types", "Search", "Indexing"], "\(section.title): rows \(rows.map(\.title))")
                    let walked = ft4Walk(window)
                    #expect(window.initialFirstResponder === rows.first, "\(section.title): initialFirstResponder \(String(describing: window.initialFirstResponder))")
                    #expect(walked.prefix(4).compactMap { ($0 as? SidebarButton)?.title } == ["Folders", "File types", "Search", "Indexing"],
                            "\(section.title): the first four stops are \(walked.prefix(4).map { NSStringFromClass(type(of: $0)) })")
                    let tail = Array(walked.dropFirst(4))
                    #expect(!tail.isEmpty, "\(section.title): no control follows the sidebar")
                    #expect(walked.filter { $0 is SidebarButton }.count == 4, "\(section.title): \(walked.filter { $0 is SidebarButton }.count) sidebar stops")
                    let pane = try #require(sgsSection(root, section), "\(section.title): no section view")
                    for view in tail {
                        let kind = NSStringFromClass(type(of: view))
                        let isRow = view is SidebarButton
                        let inside = view.isDescendant(of: pane)
                        let enabled = (view as? NSControl)?.isEnabled == true
                        #expect(!isRow, "\(section.title): a sidebar row follows the pane's controls")
                        #expect(inside, "\(section.title): the stop \(kind) is outside the section")
                        #expect(enabled, "\(section.title): the stop \(kind) is not an enabled control")
                    }
                    #expect(walked.last?.nextKeyView === walked.first, "\(section.title): Tab from the last stop does not return to the start")
                }
            }
        }
    }
}

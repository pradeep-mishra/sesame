import AppKit
import Foundation
import Testing
@testable import Sesame

private let sofSections: [SettingsScreen.Section] = [.folders, .fileTypes, .search, .indexing]
private let sofTitles = ["Folders", "File types", "Search", "Indexing"]

@MainActor
private func sofName(_ responder: NSResponder?) -> String {
    if let button = responder as? SidebarButton { return button.title }
    guard let responder else { return "nil" }
    return NSStringFromClass(type(of: responder))
}

extension ModelDownloadTests {
    @Suite("SettingsOpenFocusTests", .serialized)
    struct SettingsOpenFocusTests {

        @MainActor
        @Test(arguments: slPaths)
        func afterReleaseFocusOnOpenTheWindowItselfIsFirstResponderAndNoSidebarRowIsWhicheverRowHeldFocusBefore(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sofSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        let rows = sgsButtons(root)
                        #expect(rows.map(\.title) == sofTitles, "\(section) \(look): rows \(rows.map(\.title))")
                        for held in rows {
                            let name = "\(section) \(look), \(held.title) focused before"
                            #expect(window.makeFirstResponder(held), "\(name): makeFirstResponder returned false")
                            #expect(window.firstResponder === held, "\(name): the first responder is \(sofName(window.firstResponder)) before the release")
                            window.releaseFocusOnOpen()
                            #expect(window.firstResponder === window, "\(name): after releaseFocusOnOpen the first responder is \(sofName(window.firstResponder)), wanted the window itself")
                            for row in rows {
                                #expect(window.firstResponder !== row, "\(name): after releaseFocusOnOpen \(row.title) is still first responder")
                            }
                        }
                        window.releaseFocusOnOpen()
                        #expect(window.firstResponder === window, "\(section) \(look): a second release left \(sofName(window.firstResponder))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func afterReleaseFocusOnOpenTheFirstTabLandsOnFoldersThenFileTypesSearchIndexingThenThePaneInEverySection(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sofSections {
                    for look in DTLook.allCases {
                        let root = sxLayout(window, section, look)
                        let rows = sgsButtons(root)
                        let pane = try #require(sgsSection(root, section), "\(section.title): no section view")
                        #expect(window.initialFirstResponder === rows.first, "\(section.title) \(look): initialFirstResponder is \(sofName(window.initialFirstResponder)), wanted Folders")
                        for row in rows { _ = window.makeFirstResponder(row) }
                        window.releaseFocusOnOpen()
                        #expect(window.firstResponder === window, "\(section.title) \(look): the first responder is \(sofName(window.firstResponder)) after the release")
                        var visited: [String] = []
                        for _ in 0..<4 {
                            window.selectNextKeyView(nil)
                            visited.append(sofName(window.firstResponder))
                        }
                        #expect(visited == sofTitles, "\(section.title) \(look): four Tabs from the window visited \(visited), wanted \(sofTitles)")
                        window.selectNextKeyView(nil)
                        let fifth = try #require(window.firstResponder as? NSView, "\(section.title) \(look): the fifth Tab left no view first responder")
                        #expect(!(fifth is SidebarButton), "\(section.title) \(look): the fifth Tab landed on the sidebar row \(sofName(fifth))")
                        #expect(fifth.isDescendant(of: pane), "\(section.title) \(look): the fifth Tab landed on \(sofName(fifth)) outside the section")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func afterReleaseFocusOnOpenAFullTabCycleThroughThePaneReturnsToFoldersAndTheLoopIsTheSameFourRowsThenThePane(glass: Bool) async throws {
            try await sgsWith(glass: glass) { window in
                for section in sofSections {
                    let root = sxLayout(window, section)
                    let pane = try #require(sgsSection(root, section), "\(section.title): no section view")
                    window.releaseFocusOnOpen()
                    #expect(window.firstResponder === window, "\(section.title): the first responder is \(sofName(window.firstResponder)) after the release")
                    var stops: [NSResponder?] = []
                    for _ in 0..<200 {
                        window.selectNextKeyView(nil)
                        stops.append(window.firstResponder)
                        if stops.count > 1, window.firstResponder === stops[0] { break }
                    }
                    #expect(stops.first.map { sofName($0) } == "Folders", "\(section.title): the first Tab landed on \(sofName(stops.first ?? nil)), wanted Folders")
                    #expect(stops.count >= 6, "\(section.title): the cycle has only \(stops.count) stops")
                    #expect(stops.count < 200, "\(section.title): Tab never returned to Folders in 200 stops")
                    #expect(stops.last.map { $0 === stops.first.flatMap { $0 } } == true, "\(section.title): the last stop \(sofName(stops.last ?? nil)) is not Folders")
                    let inner = stops.dropFirst(4).dropLast()
                    #expect(!inner.isEmpty, "\(section.title): no pane stop between Indexing and the return to Folders")
                    for stop in inner {
                        let view = stop as? NSView
                        #expect(view != nil && view?.isDescendant(of: pane) == true && !(view is SidebarButton), "\(section.title): the stop \(sofName(stop)) is not a control inside the section")
                    }
                    #expect(stops.prefix(4).map { sofName($0) } == sofTitles, "\(section.title): the first four stops are \(stops.prefix(4).map { sofName($0) })")
                }
            }
        }
    }
}

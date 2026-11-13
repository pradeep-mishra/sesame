import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private final class SSSender: FoldersSender, @unchecked Sendable {
    func sendFolders() {}
}

private struct SSCase {
    let section: SettingsScreen.Section
    let name: String
    let symbol: String
}

private let ssCases = [
    SSCase(section: .folders, name: "Folders", symbol: "folder"),
    SSCase(section: .fileTypes, name: "File types", symbol: "doc.on.doc"),
    SSCase(section: .search, name: "Search", symbol: "magnifyingglass"),
    SSCase(section: .indexing, name: "Indexing", symbol: "arrow.triangle.2.circlepath"),
]

private struct SSMarker {
    let section: SettingsScreen.Section
    let text: String
    let prefix: Bool
}

private let ssMarkers = [
    SSMarker(section: .folders, text: "Add folder\u{2026}", prefix: false),
    SSMarker(section: .fileTypes, text: "PDFs", prefix: false),
    SSMarker(section: .search, text: "Record new shortcut", prefix: false),
    SSMarker(section: .indexing, text: "Start indexing", prefix: false),
]

@MainActor
private func ssEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func ssWith(_ body: @MainActor (SettingsContainerWindow) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-settingsshell-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let home = base.resolvingSymlinksInPath()
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    let model = SettingsModel(sender: SSSender(), modelWhole: { true })
    for name in ["Trips", "Notes", "Extra"] {
        let url = home.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for number in 0..<3 {
            try Data(repeating: 7, count: 32).write(to: url.appendingPathComponent("photo-\(number).jpg"))
        }
        model.addFolder(url)
    }
    #expect(await ssEventually { model.rows.count == 3 && model.rows.allSatisfy { $0.state != .counting } }, "the rows never settled")
    let window = SettingsContainerWindow(model: model)
    window.isReleasedWhenClosed = false
    window.refresh()
    try await body(window)
}

@MainActor
private func ssLayout(_ window: SettingsContainerWindow, _ look: DTLook = .light) -> NSView {
    window.refresh()
    let root = window.contentView!
    root.appearance = dtAppearance(look)
    for button in prViews(root).compactMap({ $0 as? SidebarButton }) { button.appearance = dtAppearance(look) }
    root.layoutSubtreeIfNeeded()
    return root
}

@MainActor
private func ssShow(_ window: SettingsContainerWindow, _ section: SettingsScreen.Section, _ look: DTLook = .light) -> NSView {
    window.select(section)
    return ssLayout(window, look)
}

@MainActor
private func ssSidebarButtons(_ root: NSView) -> [SidebarButton] {
    prViews(root).compactMap { $0 as? SidebarButton }.sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func ssAlignBox(_ root: NSView, _ view: NSView) -> PLBox {
    guard let parent = view.superview else { return plBox(root, view) }
    let rect = root.convert(view.alignmentRect(forFrame: view.frame), from: parent)
    let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
    return PLBox(minX: rect.minX, maxX: rect.maxX, top: top, bottom: top + rect.height)
}

@MainActor
private func ssAncestors(_ view: NSView) -> [NSView] {
    var out: [NSView] = []
    var current = view.superview
    while let next = current {
        out.append(next)
        current = next.superview
    }
    return out
}

@MainActor
private func ssIsSectionView(_ view: NSView) -> Bool {
    view is SettingsFoldersView || view is SettingsFileTypesView || view is SettingsSearchView
        || view is SettingsIndexingView
}

@MainActor
private func ssSectionView(_ root: NSView, _ section: SettingsScreen.Section) -> NSView? {
    prViews(root).first { view in
        switch section.rawValue {
        case "folders": return view is SettingsFoldersView
        case "fileTypes": return view is SettingsFileTypesView
        case "search": return view is SettingsSearchView
        case "indexing": return view is SettingsIndexingView
        default: return false
        }
    }
}

private func ssSymbolName(_ image: NSImage?) -> String? {
    guard let text = image?.description, let range = text.range(of: "symbol = ") else { return nil }
    return String(text[range.upperBound...].prefix { $0 != ">" && !$0.isWhitespace })
}

private func ssFont(_ font: NSFont?, size: CGFloat, weight: NSFont.Weight) -> Bool {
    guard let font else { return false }
    return abs(font.pointSize - size) < 0.01 && abs(dtWeight(font) - weight.rawValue) < 0.05
}

@MainActor
private func ssColour(_ color: NSColor?, is expected: NSColor) -> Bool {
    guard let color else { return false }
    return DTLook.allCases.allSatisfy { dtSame(dtRGBA(color, $0), dtRGBA(expected, $0)) }
}

@MainActor
private func ssKitLabels(_ view: NSView) -> [String] {
    var out = [view.accessibilityTitle(), view.accessibilityLabel()].compactMap { $0 }
    if let button = view as? NSButton { out.append(button.title) }
    if let field = view as? NSTextField { out.append(field.stringValue) }
    return out.filter { !$0.isEmpty }
}

@MainActor
private func ssVisibleLabels(_ root: NSView) -> [String] {
    prViews(root).filter { plVisible($0) }.flatMap { ssKitLabels($0) }
}

@MainActor
private func ssTitleFields(_ root: NSView, _ name: String) -> [NSTextField] {
    prViews(root).compactMap { $0 as? NSTextField }.filter {
        plVisible($0) && $0.stringValue == name && ssFont($0.font, size: 15, weight: .bold)
    }
}

@MainActor
private func ssVisibleParts(_ root: NSView) -> [NSView] {
    prViews(root).filter { view in
        guard plVisible(view), !(view is NSScroller), view.frame.width > 0, view.frame.height > 0 else { return false }
        if let field = view as? NSTextField { return !field.stringValue.isEmpty }
        return view is NSControl
    }
}

extension ModelDownloadTests {
    @Suite("SettingsShellTests", .serialized)
    struct SettingsShellTests {

        @MainActor
        @Test func theWindowIsSevenTwentyByFiveTwentyAndStaysTitledSettingsInEverySection() async throws {
            try await ssWith { window in
                let root = ssLayout(window)
                #expect(window.title == "Settings")
                #expect(window.frame.size == NSSize(width: 720, height: 548), "frame \(window.frame.size)")
                #expect(root.frame.size == NSSize(width: 720, height: 548), "content size \(root.frame.size)")
                #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 720, height: 548), "content rect \(window.contentRect(forFrameRect: window.frame).size)")
                #expect(SettingsContainerWindow.size == NSSize(width: 720, height: 520), "static size \(SettingsContainerWindow.size)")
                #expect(root.frame.width * root.frame.height < 537_600, "area \(root.frame.width * root.frame.height) is not below the panel's 537,600")
                for entry in ssCases {
                    let shown = ssShow(window, entry.section)
                    #expect(window.title == "Settings", "\(entry.name): title \"\(window.title)\"")
                    #expect(window.frame.size == NSSize(width: 720, height: 548), "\(entry.name): frame \(window.frame.size)")
                    #expect(shown.frame.size == NSSize(width: 720, height: 548), "\(entry.name): content size \(shown.frame.size)")
                }
            }
        }

        @MainActor
        @Test func theSidebarPanelHoldsTheFourSidebarButtonsAndNoTextButTheirsInPlaceOfTheOldFullHeightSidebarMaterialColumn() async throws {
            try await ssWith { window in
                let root = ssLayout(window)
                #expect(prViews(root).compactMap { $0 as? NSVisualEffectView }.filter { $0.material == .sidebar }.isEmpty, "a full-height sidebar material view is still in the window")
                let buttons = ssSidebarButtons(root)
                #expect(buttons.count == 4, "\(buttons.count) SidebarButtons")
                let panel = try #require(sgsPanel(root), "no view of width 180 holds all four SidebarButtons")
                #expect(plVisible(panel))
                #expect(buttons.allSatisfy { $0.isDescendant(of: panel) }, "a SidebarButton is outside the panel")
                let outside = prViews(root).compactMap { $0 as? NSTextField }.filter {
                    $0.isDescendant(of: panel) && plVisible($0) && !$0.stringValue.isEmpty && !ssAncestors($0).contains { $0 is NSButton }
                }
                #expect(outside.isEmpty, "text inside the panel: \(outside.map(\.stringValue))")
            }
        }

        @MainActor
        @Test func theFourSidebarButtonsAreSidebarButtonsInOrderWithTheNamesAndSymbolsPlacedByConstraints() async throws {
            try await ssWith { window in
                let root = ssLayout(window)
                let buttons = ssSidebarButtons(root)
                #expect(buttons.map(\.title) == ssCases.map(\.name), "titles \(buttons.map(\.title))")
                #expect(buttons.map { $0.accessibilityLabel() ?? "" } == ssCases.map(\.name), "labels \(buttons.map { $0.accessibilityLabel() ?? "nil" })")
                let wanted = ssCases.map { entry in
                    ssSymbolName(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)) ?? "no such symbol \(entry.symbol)"
                }
                #expect(buttons.map { ssSymbolName($0.image) ?? "nil" } == wanted, "symbols \(buttons.map { ssSymbolName($0.image) ?? "nil" }), wanted \(wanted) for \(ssCases.map(\.symbol))")
                #expect(buttons.allSatisfy { !$0.translatesAutoresizingMaskIntoConstraints }, "a SidebarButton is placed by its frame")
                #expect(buttons.allSatisfy { $0.isEnabled && plVisible($0) })
                let walked = prViews(root).compactMap { $0 as? NSButton }.filter { button in ssCases.contains { $0.name == button.title } }
                #expect(walked.count == 4, "walking contentView finds \(walked.count) NSButtons titled with a section name")
            }
        }

        @MainActor
        @Test func theSidebarItemsAreTwentyEightTallTwoApartInsetEightAndPadEightInside() async throws {
            try await ssWith { window in
                let root = ssLayout(window)
                let panel = try #require(sgsPanel(root), "no sidebar panel")
                let columnBox = plBox(root, panel)
                let buttons = ssSidebarButtons(root)
                #expect(buttons.count == 4)
                for button in buttons {
                    let box = plBox(root, button)
                    #expect(abs(box.height - 28) <= 0.5, "\(button.title): height \(box.height)")
                    #expect(abs(box.minX - columnBox.minX - 8) <= 0.5, "\(button.title): leading inset \(box.minX - columnBox.minX)")
                    #expect(abs(columnBox.maxX - box.maxX - 8) <= 0.5, "\(button.title): trailing inset \(columnBox.maxX - box.maxX)")
                    let drawing = button.cell?.drawingRect(forBounds: button.bounds) ?? .zero
                    #expect(abs(drawing.minX - 8) <= 0.5, "\(button.title): inner padding at the left \(drawing.minX)")
                    #expect(abs(button.bounds.maxX - drawing.maxX - 8) <= 0.5, "\(button.title): inner padding at the right \(button.bounds.maxX - drawing.maxX)")
                }
                if let first = buttons.first {
                    #expect(abs(plBox(root, first).top - 46) <= 1, "first item's top inset \(plBox(root, first).top) from the window top")
                }
                for (above, below) in zip(buttons, buttons.dropFirst()) {
                    let gap = plBox(root, below).top - plBox(root, above).bottom
                    #expect(abs(gap - 2) <= 0.5, "\(above.title) to \(below.title): gap \(gap)")
                }
            }
        }

        @MainActor
        @Test func performClickOnASidebarButtonSelectsItsSectionAndOnlyThatButtonIsSelected() async throws {
            try await ssWith { window in
                let order: [SettingsScreen.Section] = [.search, .folders, .indexing, .fileTypes, .folders]
                for section in order {
                    let entry = try #require(ssCases.first { $0.section == section })
                    let root = ssLayout(window)
                    let button = try #require(ssSidebarButtons(root).first { $0.title == entry.name }, "no SidebarButton titled \(entry.name)")
                    button.performClick(nil)
                    await Task.yield()
                    #expect(window.settingsScreen.section == section, "after \(entry.name): the window draws \(window.settingsScreen.section.title)")
                    let after = ssLayout(window)
                    let selected = ssSidebarButtons(after).filter(\.isSelected).map(\.title)
                    #expect(selected == [entry.name], "after \(entry.name): selected \(selected)")
                }
            }
        }

        @MainActor
        @Test func clickingTheAlreadySelectedSidebarButtonKeepsItsStateOnAndExactlyOneButtonOn() async throws {
            try await ssWith { window in
                let steps: [SettingsScreen.Section] = [.folders, .folders, .search, .search, .search, .indexing, .folders, .folders]
                var previous: SettingsScreen.Section?
                let opening = ssSidebarButtons(ssLayout(window))
                #expect(opening.filter { $0.state.rawValue == 1 }.map(\.title) == ["Folders"], "on opening, buttons with state on \(opening.filter { $0.state.rawValue == 1 }.map(\.title))")
                for section in steps {
                    let entry = try #require(ssCases.first { $0.section == section })
                    let root = ssLayout(window)
                    let button = try #require(ssSidebarButtons(root).first { $0.title == entry.name }, "no SidebarButton titled \(entry.name)")
                    let again = previous == section || (previous == nil && window.settingsScreen.section == section)
                    button.performClick(nil)
                    await Task.yield()
                    let after = ssLayout(window)
                    let buttons = ssSidebarButtons(after)
                    let label = again ? "clicking \(entry.name) while it is selected" : "clicking \(entry.name)"
                    #expect(window.settingsScreen.section == section, "\(label): the window draws \(window.settingsScreen.section.title)")
                    #expect(buttons.count == 4, "\(label): \(buttons.count) SidebarButtons")
                    #expect(buttons.first { $0.title == entry.name }?.state.rawValue == 1, "\(label): its state is \(String(describing: buttons.first { $0.title == entry.name }?.state.rawValue)), wanted 1")
                    let on = buttons.filter { $0.state.rawValue == 1 }.map(\.title)
                    #expect(on == [entry.name], "\(label): buttons with state on \(on)")
                    let off = buttons.filter { $0.title != entry.name }.map { $0.state.rawValue }
                    #expect(off == [0, 0, 0], "\(label): the other three have states \(off)")
                    #expect(buttons.filter(\.isSelected).map(\.title) == [entry.name], "\(label): isSelected on \(buttons.filter(\.isSelected).map(\.title))")
                    previous = section
                }
            }
        }

        @MainActor
        @Test func theSelectedSidebarButtonReportsValueOneAndTheOthersZeroToAccessibilityAfterAnotherClickOnIt() async throws {
            try await ssWith { window in
                for section in [SettingsScreen.Section.folders, .folders, .indexing, .indexing] {
                    let entry = try #require(ssCases.first { $0.section == section })
                    let root = ssLayout(window)
                    let button = try #require(ssSidebarButtons(root).first { $0.title == entry.name }, "no SidebarButton titled \(entry.name)")
                    button.performClick(nil)
                    await Task.yield()
                    let buttons = ssSidebarButtons(ssLayout(window))
                    let values = buttons.map { ($0.title, ($0.cell?.accessibilityValue() as? NSNumber)?.intValue ?? -1) }
                    for (title, value) in values {
                        #expect(value == (title == entry.name ? 1 : 0), "after clicking \(entry.name): \(title) reports accessibility value \(value)")
                    }
                }
            }
        }

        @MainActor
        @Test func theSelectedItemIsAnAccentPillOfRadiusEightWithTheSelectedTextColourInBothLooks() async throws {
            try await ssWith { window in
                for section in [SettingsScreen.Section.folders, .indexing] {
                    let entry = try #require(ssCases.first { $0.section == section })
                    for look in DTLook.allCases {
                        let root = ssShow(window, section, look)
                        let buttons = ssSidebarButtons(root)
                        #expect(buttons.count == 4)
                        for button in buttons {
                            let fill = dtRGBA(cgColor: button.layer?.backgroundColor)
                            if button.title == entry.name {
                                #expect(button.layer?.cornerRadius == 8, "\(entry.name) \(look): radius \(String(describing: button.layer?.cornerRadius))")
                                #expect(fill != nil && dtSame(fill ?? [], dtRGBA(.controlAccentColor, look)), "\(entry.name) \(look): pill \(String(describing: fill))")
                                #expect(dtSame(dtRGBA(button.contentTintColor ?? .clear, look), dtRGBA(.alternateSelectedControlTextColor, look)), "\(entry.name) \(look): text colour")
                            } else {
                                #expect(fill == nil || (fill?[3] ?? 1) < 0.01, "\(button.title) \(look): draws a pill while \(entry.name) is selected")
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test func theSidebarIsTheFirstTabStopAndTabVisitsItsFourItemsInOrder() async throws {
            try await ssWith { window in
                let root = ssLayout(window)
                let buttons = ssSidebarButtons(root)
                #expect(buttons.count == 4)
                #expect(window.initialFirstResponder === buttons.first, "initialFirstResponder \(String(describing: window.initialFirstResponder))")
                for (current, next) in zip(buttons, buttons.dropFirst()) {
                    #expect(current.nextKeyView === next, "\(current.title): next key view \(String(describing: current.nextKeyView))")
                }
            }
        }

        @MainActor
        @Test func thePaneHasATitleOfFifteenBoldEqualToTheSectionNameCentredInTheStripAfterThePanel() async throws {
            try await ssWith { window in
                for entry in ssCases {
                    let root = ssShow(window, entry.section)
                    let titles = ssTitleFields(root, entry.name)
                    #expect(titles.count == 1, "\(entry.name): \(titles.count) visible 15 pt bold texts with that name")
                    guard let title = titles.first else { continue }
                    let panel = try #require(sgsPanel(root), "no sidebar panel")
                    #expect(!title.isDescendant(of: panel), "\(entry.name): the title is inside the sidebar")
                    let all = prViews(root)
                    let titleIndex = all.firstIndex { $0 === title } ?? -1
                    let lastButton = ssSidebarButtons(root).compactMap { button in all.firstIndex { $0 === button } }.max() ?? Int.max
                    #expect(titleIndex > lastButton, "\(entry.name): the title is at tree position \(titleIndex), the last sidebar item at \(lastButton)")
                    let box = ssAlignBox(root, title)
                    #expect(abs(box.minX - 197) <= 1, "\(entry.name): title left edge \(box.minX)")
                    #expect(abs((box.top + box.bottom) / 2 - 23) <= 1.5, "\(entry.name): title centre \((box.top + box.bottom) / 2) in a strip 46 tall")
                    #expect(box.maxX <= 704.5, "\(entry.name): title right edge \(box.maxX)")
                    #expect(ssColour(title.textColor, is: .labelColor), "\(entry.name): title colour")
                    for other in ssCases where other.name != entry.name {
                        #expect(ssTitleFields(root, other.name).isEmpty, "\(entry.name): a title reading \"\(other.name)\" is visible")
                    }
                }
            }
        }

        @MainActor
        @Test func theSelectedSectionSitsUnderTheTitleInsideTheMarginsOfOneBorderlessScrollView() async throws {
            try await ssWith { window in
                let shell = ssLayout(window)
                let shellScrolls = prViews(shell).compactMap { $0 as? NSScrollView }.filter { scroll in
                    !ssAncestors(scroll).contains { ssIsSectionView($0) }
                }
                #expect(shellScrolls.count == 1, "\(shellScrolls.count) scroll views outside the section views")
                #expect(shellScrolls.allSatisfy { $0.borderType == .noBorder }, "a shell scroll view has a border: \(shellScrolls.map(\.borderType.rawValue))")
                for entry in ssCases {
                    let root = ssShow(window, entry.section)
                    let content = try #require(ssSectionView(root, entry.section), "\(entry.name): no section view")
                    #expect(plVisible(content), "\(entry.name): the section view is hidden")
                    let scrolls = ssAncestors(content).compactMap { $0 as? NSScrollView }
                    #expect(scrolls.count == 1, "\(entry.name): \(scrolls.count) scroll views around the section")
                    if let scroll = scrolls.first {
                        #expect(scroll.borderType == .noBorder, "\(entry.name): the pane's scroll view has border type \(scroll.borderType.rawValue)")
                        #expect(plBox(root, scroll).minX >= 180.5, "\(entry.name): the scroll view starts at \(plBox(root, scroll).minX), inside the sidebar column")
                        #expect(plBox(root, scroll).bottom <= 548.5, "\(entry.name): the scroll view ends at \(plBox(root, scroll).bottom)")
                    }
                    for button in ssSidebarButtons(root) {
                        #expect(!ssAncestors(button).contains { $0 is NSScrollView }, "a sidebar item is inside a scroll view")
                    }
                    let box = plBox(root, content)
                    #expect(box.minX >= 196, "\(entry.name): section left edge \(box.minX)")
                    #expect(box.maxX <= 705, "\(entry.name): section right edge \(box.maxX)")
                    let titleBox = try #require(ssTitleFields(root, entry.name).first.map { plBox(root, $0) }, "\(entry.name): no title")
                    #expect(box.top >= titleBox.bottom - 0.5, "\(entry.name): the section starts at \(box.top), above the title's bottom \(titleBox.bottom)")
                    #expect(box.top - titleBox.bottom <= 32, "\(entry.name): \(box.top - titleBox.bottom) pt of blank between the title and the section")
                    let column = sgsPanel(root)
                    for part in ssVisibleParts(root) where column.map({ !part.isDescendant(of: $0) }) ?? true {
                        let partBox = plBox(root, part)
                        #expect(partBox.maxX <= 704.5, "\(entry.name): \(ssKitLabels(part).first ?? String(describing: type(of: part))) reaches x \(partBox.maxX)")
                    }
                }
            }
        }

        @MainActor
        @Test func nothingOutsideThePanesScrollViewLiesWithinTwentyPointsOfTheBottomEdge() async throws {
            try await ssWith { window in
                for entry in ssCases {
                    let root = ssShow(window, entry.section)
                    for part in ssVisibleParts(root) where !ssAncestors(part).contains(where: { $0 is NSScrollView }) {
                        let box = plBox(root, part)
                        #expect(box.bottom <= 528.5, "\(entry.name): \(ssKitLabels(part).first ?? String(describing: type(of: part))) ends at y \(box.bottom) of 548")
                    }
                }
            }
        }

        @MainActor
        @Test func eachSectionsMarkerIsReadableOnlyWhileItsSectionIsSelectedAndOtherSectionsStayHiddenNotRemoved() async throws {
            try await ssWith { window in
                for entry in ssCases {
                    let root = ssShow(window, entry.section)
                    let labels = ssVisibleLabels(root)
                    for marker in ssMarkers {
                        let present = labels.contains { marker.prefix ? $0.hasPrefix(marker.text) : $0 == marker.text }
                        #expect(present == (marker.section == entry.section), "\(entry.name): marker \"\(marker.text)\" present \(present)")
                    }
                    for other in ssCases {
                        let view = try #require(ssSectionView(root, other.section), "no section view for \(other.name)")
                        #expect(view.window === window, "\(other.name): the section view left the window")
                        #expect(view.alphaValue == 1, "\(other.name): the section view is hidden by alpha \(view.alphaValue)")
                        #expect(view.isHiddenOrHasHiddenAncestor == (other.section != entry.section), "\(entry.name): \(other.name) hidden \(view.isHiddenOrHasHiddenAncestor)")
                    }
                }
            }
        }
    }
}

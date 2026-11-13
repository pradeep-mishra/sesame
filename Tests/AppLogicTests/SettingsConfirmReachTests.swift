import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let crAddFolder = "Add folder\u{2026}"

private func crFolders(_ count: Int) -> [SXFolder] {
    (0..<count).map { SXFolder(path: "Folder-" + String(format: "%02d", $0), photos: 2) }
}

@MainActor
private func crWith(
    glass: Bool,
    rows: Int,
    _ body: @MainActor (SettingsContainerWindow, SXEnv) async throws -> Void
) async throws {
    try await sxWithWindow(crFolders(rows), make: { model in
        SettingsContainerWindow(
            model: model, shortcut: ShortcutControl(), loginItem: LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: SettingsContainerWindow.unwiredDeleteIndex(), glass: glass)
    }, body)
}

@MainActor
private func crScroll(_ section: NSView) -> NSScrollView? {
    sxAncestors(section).compactMap { $0 as? NSScrollView }.first
}

@MainActor
private func crCancel(_ section: NSView) -> NSButton? {
    sxButtons(section, titled: "Cancel").first
}

@MainActor
private func crOffset(_ scroll: NSScrollView) -> CGFloat {
    scroll.contentView.bounds.minY
}

@MainActor
private func crScrollTo(_ scroll: NSScrollView, bottom: Bool) {
    guard let document = scroll.documentView else { return }
    let travel = max(0, document.frame.height - scroll.contentView.bounds.height)
    let flippedY = bottom ? travel : 0
    let y = document.isFlipped ? flippedY : (bottom ? 0 : travel)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
}

@MainActor
private func crReach(_ scroll: NSScrollView, _ card: NSView) -> (inside: Bool, top: CGFloat, bottom: CGFloat, height: CGFloat) {
    let clip = scroll.contentView
    let rect = clip.convert(card.bounds, from: card)
    let inside = rect.minX >= clip.bounds.minX - 1 && rect.maxX <= clip.bounds.maxX + 1
        && rect.minY >= clip.bounds.minY - 1 && rect.maxY <= clip.bounds.maxY + 1
    return (inside, rect.minY - clip.bounds.minY, rect.maxY - clip.bounds.minY, clip.bounds.height)
}

@MainActor
private func crFocus(_ window: NSWindow, is view: NSView) -> Bool {
    window.firstResponder === view
}

@MainActor
private func crFocusName(_ window: NSWindow) -> String {
    guard let responder = window.firstResponder else { return "nil" }
    return String(describing: type(of: responder))
}

@MainActor
private func crWalk(_ window: NSWindow) -> [NSView] {
    var walked: [NSView] = []
    var current: NSView? = window.initialFirstResponder
    while let view = current, walked.count < 200, !walked.contains(where: { $0 === view }) {
        walked.append(view)
        current = view.nextKeyView
    }
    return walked
}

extension ModelDownloadTests {
    @Suite("SettingsConfirmReachTests", .serialized)
    struct SettingsConfirmReachTests {
        @MainActor
        @Test(arguments: slPaths)
        func pressingRemoveScrollsTheConfirmCardIntoTheVisibleAreaFromTheTopAndFromTheBottomOfThePane(glass: Bool) async throws {
            for rows in [6, 8, 14] {
                for atBottom in [false, true] {
                    try await crWith(glass: glass, rows: rows) { window, _ in
                        let tag = "\(rows) rows, \(atBottom ? "scrolled to the bottom" : "scrolled to the top")"
                        var root = sxLayout(window, .folders)
                        var section = try #require(sxFoldersSection(root), "\(tag): no Folders section view")
                        let scroll = try #require(crScroll(section), "\(tag): no scroll view around the section")
                        crScrollTo(scroll, bottom: atBottom)
                        #expect(crCancel(section) == nil, "\(tag): the confirm is visible before a Remove choice")
                        #expect(await smrChoose("Remove", folder: "Folder-00", in: root), "\(tag): no Remove item under the more button of Folder-00")
                        section = try #require(sxFoldersSection(root), "\(tag): the section went away")
                        let cancel = try #require(crCancel(section), "\(tag): no Cancel after the Remove choice")
                        let card = try #require(sxCard(of: cancel), "\(tag): Cancel is in no card")
                        let reach = crReach(scroll, card)
                        #expect(reach.inside, "\(tag): the confirm card spans \(reach.top) to \(reach.bottom) in a viewport \(reach.height) tall")
                        for look in [DTLook.dark, .light] {
                            root = sxRelayout(window, look)
                            section = try #require(sxFoldersSection(root))
                            let againCancel = try #require(crCancel(section))
                            let againCard = try #require(sxCard(of: againCancel))
                            let again = crReach(scroll, againCard)
                            #expect(again.inside, "\(tag), \(look): the card spans \(again.top) to \(again.bottom) in a viewport \(again.height) tall")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func pressingRemoveMovesFocusToCancelAndPressingCancelHidesTheCard(glass: Bool) async throws {
            try await crWith(glass: glass, rows: 8) { window, _ in
                var root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                #expect(await smrChoose("Remove", folder: "Folder-00", in: root), "no Remove item under the more button of Folder-00")
                section = try #require(sxFoldersSection(root))
                let cancel = try #require(crCancel(section), "no Cancel after the Remove choice")
                let onCancel = crFocus(window, is: cancel)
                #expect(onCancel, "the first responder is a \(crFocusName(window)), not the Cancel button")
                cancel.performClick(nil)
                await Task.yield()
                root = sxRelayout(window)
                section = try #require(sxFoldersSection(root))
                #expect(crCancel(section) == nil, "Cancel is still visible after it was pressed")
                #expect(cancel.isHiddenOrHasHiddenAncestor, "the card is not hidden after Cancel was pressed")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func theTabLoopHoldsCancelAndThenRemoveFolderAfterTheSidebarWhileTheConfirmIsOpen(glass: Bool) async throws {
            try await crWith(glass: glass, rows: 8) { window, _ in
                let root = sxLayout(window, .folders)
                #expect(await smrChoose("Remove", folder: "Folder-00", in: root), "no Remove item under the more button of Folder-00")
                let walked = crWalk(window)
                let cancelAt = walked.firstIndex { ($0 as? NSButton)?.title == "Cancel" }
                let removeAt = walked.firstIndex { ($0 as? NSButton)?.title == "Remove folder" }
                let sidebar = walked.indices.filter { walked[$0] is SidebarButton }
                #expect(!sidebar.isEmpty, "no sidebar button in the Tab loop")
                #expect(cancelAt != nil && removeAt != nil, "the Tab loop does not hold Cancel and Remove folder")
                if let cancelAt, let removeAt, let lastSidebar = sidebar.max() {
                    #expect(cancelAt > lastSidebar, "Cancel is at \(cancelAt), before the sidebar button at \(lastSidebar)")
                    #expect(removeAt == cancelAt + 1, "Remove folder is at \(removeAt), not right after Cancel at \(cancelAt)")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func renderingAgainWithTheConfirmOpenMovesNeitherTheScrollPositionNorTheFocus(glass: Bool) async throws {
            try await crWith(glass: glass, rows: 8) { window, _ in
                let root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                let scroll = try #require(crScroll(section))
                #expect(await smrChoose("Remove", folder: "Folder-00", in: root), "no Remove item under the more button of Folder-00")
                section = try #require(sxFoldersSection(root))
                let cancel = try #require(crCancel(section))
                let onCancel = crFocus(window, is: cancel)
                #expect(onCancel, "the first responder is a \(crFocusName(window)), not the Cancel button")
                crScrollTo(scroll, bottom: false)
                let add = try #require(sxButtons(section, titled: crAddFolder).first, "no Add folder button")
                #expect(window.makeFirstResponder(add), "the Add folder button did not take focus")
                let onAdd = crFocus(window, is: add)
                #expect(onAdd, "the first responder is a \(crFocusName(window)), not the Add folder button")
                let offset = crOffset(scroll)
                for _ in 0..<10 {
                    _ = sxRelayout(window)
                }
                #expect(abs(crOffset(scroll) - offset) <= 0.5, "the scroll moved from \(offset) to \(crOffset(scroll)) on a later render")
                let stillOnAdd = crFocus(window, is: add)
                #expect(stillOnAdd, "the focus moved to a \(crFocusName(window)) on a later render")
            }
        }

        @MainActor
        @Test(arguments: slPaths)
        func withTwoRowsTheCardIsAlreadyVisibleSoOnlyTheFocusMovesAndTheScrollStays(glass: Bool) async throws {
            try await crWith(glass: glass, rows: 2) { window, _ in
                let root = sxLayout(window, .folders)
                var section = try #require(sxFoldersSection(root))
                let scroll = try #require(crScroll(section))
                let before = crOffset(scroll)
                #expect(await smrChoose("Remove", folder: "Folder-00", in: root), "no Remove item under the more button of Folder-00")
                section = try #require(sxFoldersSection(root))
                let cancel = try #require(crCancel(section))
                let card = try #require(sxCard(of: cancel))
                #expect(crReach(scroll, card).inside, "the card is not inside the viewport with two rows")
                #expect(abs(crOffset(scroll) - before) <= 0.5, "the scroll moved from \(before) to \(crOffset(scroll)) with two rows")
                let onCancel = crFocus(window, is: cancel)
                #expect(onCancel, "the first responder is a \(crFocusName(window)), not the Cancel button")
            }
        }
    }
}

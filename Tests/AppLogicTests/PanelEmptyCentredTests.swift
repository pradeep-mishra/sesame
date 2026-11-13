import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let pcHint = "Describe what you want, or type part of a name or text."
private let pcSamples = ["a dog on the beach", "the clause about pets in the lease", "where they talk about sleep"]

private func pcIndexing() -> PLConditions {
    var conditions = PLConditions()
    conditions.counts = IndexCounts(done: 1, pending: ["photo": 2], partial: ["pdf": 1])
    return conditions
}

private func pcDownloading() -> PLConditions {
    var conditions = PLConditions()
    conditions.model = .downloading
    return conditions
}

private func pcNotReadyCases() -> [(name: String, conditions: PLConditions)] {
    var damaged = PLConditions()
    damaged.model = .damaged
    var failed = PLConditions()
    failed.model = .failed
    var notStarted = PLConditions()
    notStarted.startPressed = false
    notStarted.walkDone = false
    var nothing = PLConditions()
    nothing.counts = IndexCounts(done: 0, pending: [:], partial: [:])
    var other = PLConditions()
    other.vectorSource = (expected: "expected-source", stored: "other-source")
    return [
        ("downloading", pcDownloading()), ("damaged", damaged), ("failed", failed),
        ("not started", notStarted), ("nothing indexed", nothing), ("other index", other),
    ]
}

@MainActor
private func pcAncestors(_ view: NSView) -> [NSView] {
    var out: [NSView] = []
    var current = view.superview
    while let next = current {
        out.append(next)
        current = next.superview
    }
    return out
}

@MainActor
private func pcScroll(_ view: NSView) -> NSView? {
    pcAncestors(view).first { $0 is NSScrollView }
}

@MainActor
private func pcPane(_ root: NSView) -> NSView? {
    prViews(root).first { $0.accessibilityLabel() == "Preview" }
}

@MainActor
private func pcHintView(_ root: NSView) throws -> NSView {
    try #require(plFind(root, "EmptyHint"), "no view with accessibility identifier EmptyHint")
}

@MainActor
private func pcIndex(of view: NSView, before other: NSView) -> Bool? {
    let mine = [view] + pcAncestors(view)
    let theirs = [other] + pcAncestors(other)
    guard let common = mine.first(where: { candidate in theirs.contains { $0 === candidate } }) else { return nil }
    let left = mine.first { $0.superview === common }
    let right = theirs.first { $0.superview === common }
    guard let left, let right,
          let leftIndex = common.subviews.firstIndex(where: { $0 === left }),
          let rightIndex = common.subviews.firstIndex(where: { $0 === right }) else { return nil }
    return leftIndex < rightIndex
}

@MainActor
private func pcExpectEmptyState(_ panel: Panel, _ name: String, banner: Bool) throws {
    for look in DTLook.allCases {
        let root = plLayout(panel, look: look)
        let group = try pcHintView(root)
        #expect(plVisible(group), "\(name) \(look): the hint is not shown")
        let frame = plBox(root, group)
        #expect(abs(frame.minX) <= 1 && abs(frame.width - 960) <= 1, "\(name) \(look): hint frame x \(frame.minX) width \(frame.width)")
        var regionTop: CGFloat = 58
        if banner {
            let bannerView = try #require(plFind(root, "IndexingBanner"), "\(name) \(look): no banner")
            #expect(plVisible(bannerView), "\(name) \(look): the banner is not shown")
            regionTop = plBox(root, bannerView).bottom
            #expect(abs(frame.top - regionTop) <= 1.5, "\(name) \(look): hint frame top \(frame.top), the banner ends at \(regionTop)")
        } else {
            #expect(abs(frame.top - 58) <= 1.5, "\(name) \(look): hint frame top \(frame.top)")
        }
        #expect(abs(frame.bottom - 528) <= 1.5, "\(name) \(look): hint frame bottom \(frame.bottom)")

        let block = try #require(plBlock(root, in: group), "\(name) \(look): no hint block")
        #expect(abs(block.midX - 480) <= 8, "\(name) \(look): block centre \(block.midX)")
        #expect(block.minX >= 240 && block.maxX <= 720, "\(name) \(look): block spans \(block.minX) to \(block.maxX)")
        #expect(block.top >= 209 && block.top <= 269, "\(name) \(look): block top \(block.top)")
        let height = 528 - regionTop
        #expect(block.top >= regionTop + 0.30 * height && block.top <= regionTop + 0.45 * height, "\(name) \(look): block top \(block.top) in a region from \(regionTop) to 528")

        let dividers = plVisibleDividers(root)
        #expect(dividers.isEmpty, "\(name) \(look): \(dividers.count) dividers are shown")
        #expect(plVisible(group) != (dividers.count == 1), "\(name) \(look): the hint and a divider are shown together or neither is shown")
    }
}

@MainActor
private func pcExpectTypedState(_ panel: Panel, _ name: String) throws {
    for look in DTLook.allCases {
        let root = plLayout(panel, look: look)
        let group = try pcHintView(root)
        #expect(!plVisible(group), "\(name) \(look): the hint is still shown")
        let dividers = plVisibleDividers(root)
        #expect(dividers.count == 1, "\(name) \(look): \(dividers.count) dividers are shown")
        if let divider = dividers.first {
            let box = plBox(root, divider)
            #expect(box.minX >= 383 && box.minX <= 385, "\(name) \(look): divider at \(box.minX)")
        }
        #expect(plVisible(group) != (dividers.count == 1), "\(name) \(look): the hint and a divider are shown together or neither is shown")
    }
}

@MainActor
private func pcExpectSplit(_ panel: Panel, _ name: String, banner: Bool) throws {
    for look in DTLook.allCases {
        let root = plLayout(panel, look: look)
        let group = try pcHintView(root)
        #expect(!plVisible(group), "\(name) \(look): the empty hint is shown")
        let dividers = plVisibleDividers(root)
        #expect(dividers.count == 1, "\(name) \(look): \(dividers.count) dividers are shown")
        guard let divider = dividers.first else { continue }
        let box = plBox(root, divider)
        #expect(box.minX >= 383 && box.minX <= 385, "\(name) \(look): divider at \(box.minX)")
        #expect(box.width <= 1.01, "\(name) \(look): divider width \(box.width)")
        var splitTop: CGFloat = 58
        if banner {
            let bannerView = try #require(plFind(root, "IndexingBanner"), "\(name) \(look): no banner")
            splitTop = plBox(root, bannerView).bottom
        }
        #expect(abs(box.top - splitTop) <= 1.5, "\(name) \(look): the split starts at \(box.top), wanted \(splitTop)")
        let table = try #require(plList(root), "\(name) \(look): no list")
        let scroll = try #require(pcScroll(table), "\(name) \(look): no scroll view")
        let list = plBox(root, scroll)
        #expect(plVisible(table), "\(name) \(look): the list is hidden")
        #expect(list.minX >= -1 && list.minX <= 1, "\(name) \(look): list starts at \(list.minX)")
        #expect(abs(list.width - 384) <= 1, "\(name) \(look): list width \(list.width)")
        let pane = try #require(pcPane(root), "\(name) \(look): no pane")
        #expect(plBox(root, pane).minX >= box.maxX - 0.5, "\(name) \(look): pane starts at \(plBox(root, pane).minX)")
    }
}

@MainActor
private func pcExpectNotReady(_ panel: Panel, _ name: String) throws {
    for look in DTLook.allCases {
        let root = plLayout(panel, look: look)
        let view = try #require(plFind(root, "NotReadyView"), "\(name) \(look): no NotReadyView")
        #expect(plVisible(view), "\(name) \(look): Not ready is not shown")
        let frame = plBox(root, view)
        #expect(abs(frame.minX) <= 1 && abs(frame.width - 960) <= 1, "\(name) \(look): x \(frame.minX) width \(frame.width)")
        #expect(!plVisible(try pcHintView(root)), "\(name) \(look): the empty hint is shown")
        #expect(plVisibleDividers(root).isEmpty, "\(name) \(look): a divider is shown")
        let table = try #require(plList(root), "\(name) \(look): no list")
        #expect(!plVisible(table), "\(name) \(look): the list is shown")
        let pane = try #require(pcPane(root), "\(name) \(look): no pane")
        #expect(!plVisible(pane), "\(name) \(look): the pane is shown")
    }
}

@MainActor
private func pcSearching(_ panel: Panel) async {
    await prType("a dog on the beach", into: panel, pauseMilliseconds: 20)
    panel.sendEvent(prKey("\r", in: panel, keyCode: 36))
    let shown = await spEventually(timeout: 8) { prShownTexts(panel.contentView!).contains("Searching") }
    #expect(shown, "never shown Searching; shown: \(prShownTexts(panel.contentView!))")
}

@MainActor
private func pcAttach(_ conditions: PLConditions, to panel: Panel) async -> StatusCache {
    let cache = conditions.cache()
    panel.attach(status: cache)
    cache.refresh()
    let expected = conditions.snapshot()
    _ = await spEventually { cache.snapshot() == expected }
    await spWait(0.3)
    return cache
}

@MainActor
private func pcHiddenStates(_ panel: Panel) throws -> [Bool] {
    let root = plLayout(panel)
    let table = try #require(plList(root))
    let scroll = try #require(pcScroll(table))
    let pane = try #require(pcPane(root))
    let notReady = try #require(plFind(root, "NotReadyView"))
    return plDividers(root).map(\.isHidden) + [
        try pcHintView(root).isHidden, scroll.isHidden, table.isHidden, pane.isHidden, notReady.isHidden,
    ]
}

extension ModelDownloadTests {
    @Suite("PanelEmptyCentredTests", .serialized)
    struct PanelEmptyCentredTests {

        @MainActor
        @Test func theEmptyHintIsCentredOnTheWholePanelBelowTheSearchRowWithNoDividerInBothLooks() async throws {
            try await plWithPanel { panel in
                try pcExpectEmptyState(panel, "empty box", banner: false)
            }
        }

        @MainActor
        @Test func theEmptyHintIsCentredOnTheWholePanelBelowTheIndexingBannerWithNoDivider() async throws {
            try await plWithPanel(pcIndexing()) { panel in
                try pcExpectEmptyState(panel, "empty box under the banner", banner: true)
            }
        }

        @MainActor
        @Test func theHintKeepsItsFourTextsItsGroupAndNoButtonOrImageInsideIt() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let group = try pcHintView(root)
                #expect(plVisible(group))
                #expect(group.isAccessibilityElement(), "the hint is not an accessibility element")
                #expect(group.accessibilityRole() == .group)
                #expect(group.accessibilityLabel() == "Search hint")
                #expect(group.accessibilityIdentifier() == "EmptyHint")
                let texts = plTexts(group).sorted { plBox(root, $0).top < plBox(root, $1).top }.map(\.stringValue)
                #expect(texts == [pcHint] + pcSamples, "texts \(texts)")
                #expect(!prViews(group).contains { $0 is NSButton }, "a sample is a button")
                #expect(plAccessibilityImages(group).isEmpty, "a decorative symbol is an accessibility element")
            }
        }

        @MainActor
        @Test func theHintAndTheChipsKeepTheirTypeColourRadiusWidthAndGapsWhileCentred() async throws {
            try await plWithPanel { panel in
                var root = plLayout(panel)
                let group = try pcHintView(root)
                let hint = try #require(plText(group, pcHint), "no hint text")
                #expect(hint.font?.pointSize == 13, "hint size \(String(describing: hint.font?.pointSize))")
                #expect(abs(dtWeight(hint.font ?? .systemFont(ofSize: 13)) - NSFont.Weight.regular.rawValue) < 0.05, "hint weight")
                #expect(plBox(root, hint).width <= 320.5, "hint width \(plBox(root, hint).width)")
                var chips: [NSView] = []
                for sample in pcSamples {
                    let field = try #require(plText(group, sample), "no sample \(sample)")
                    #expect(field.font?.pointSize == 13, "\(sample): size \(String(describing: field.font?.pointSize))")
                    #expect(abs(dtWeight(field.font ?? .systemFont(ofSize: 13)) - NSFont.Weight.regular.rawValue) < 0.05, "\(sample): weight")
                    var found: NSView?
                    var current: NSView? = field
                    while let view = current, view !== group {
                        if view.layer?.cornerRadius == 6 { found = view }
                        current = view.superview
                    }
                    let chip = try #require(found, "\(sample): no view of radius 6 holds it")
                    #expect(plBox(root, chip).width <= 400, "\(sample): chip width \(plBox(root, chip).width)")
                    chips.append(chip)
                }
                for look in DTLook.allCases {
                    root = plLayout(panel, look: look)
                    #expect(dtSame(dtRGBA(hint.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "hint colour \(look)")
                    let label = dtRGBA(.labelColor, look)
                    for (index, sample) in pcSamples.enumerated() {
                        let field = try #require(plText(group, sample))
                        #expect(dtSame(dtRGBA(field.textColor ?? .clear, look), label), "\(sample): text colour \(look)")
                        let actual = dtRGBA(cgColor: chips[index].layer?.backgroundColor)
                        #expect(actual != nil && dtSame(actual ?? [], [label[0], label[1], label[2], 0.05]), "\(sample): chip fill \(look) \(String(describing: actual))")
                    }
                }
                root = plLayout(panel)
                #expect(abs(plBox(root, chips[0]).top - plBox(root, hint).bottom - 12) <= 1, "gap from the hint to the first chip \(plBox(root, chips[0]).top - plBox(root, hint).bottom)")
                #expect(abs(plBox(root, chips[1]).top - plBox(root, chips[0]).bottom - 8) <= 1, "gap between chips one and two \(plBox(root, chips[1]).top - plBox(root, chips[0]).bottom)")
                #expect(abs(plBox(root, chips[2]).top - plBox(root, chips[1]).bottom - 8) <= 1, "gap between chips two and three \(plBox(root, chips[2]).top - plBox(root, chips[1]).bottom)")
            }
        }

        @MainActor
        @Test func theRuleUnderTheSearchRowAndTheFooterStayWhileTheDividerIsGone() async throws {
            try await plWithTypingPanel { panel in
                for look in DTLook.allCases {
                    let root = plLayout(panel, look: look)
                    let rules = prViews(root).filter { $0.frame.height >= 0.5 && $0.frame.height <= 1.01 && $0.frame.width >= 900 && plVisible($0) }
                    #expect(rules.count == 1, "\(look): \(rules.count) visible horizontal rules")
                    if let rule = rules.first {
                        let box = plBox(root, rule)
                        #expect(abs(box.width - 960) <= 1, "\(look): rule width \(box.width)")
                        #expect(box.height <= 1.01, "\(look): rule height \(box.height)")
                        #expect(abs(box.top - 58) <= 1, "\(look): rule top \(box.top)")
                    }
                    #expect(plVisibleDividers(root).isEmpty, "\(look): a vertical divider is shown")

                    let footer = try #require(plFind(root, "PanelFooter"), "\(look): no footer")
                    let footerBox = plBox(root, footer)
                    #expect(plVisible(footer))
                    #expect(abs(footerBox.height - 32) <= 0.5 && abs(footerBox.top - 528) <= 1.5, "\(look): footer top \(footerBox.top) height \(footerBox.height)")
                    #expect(plText(footer, "↩ Open  ⌘↩ Reveal  ⌘C Copy  esc Close") != nil, "\(look): footer texts \(plTexts(footer).map(\.stringValue))")

                    let field = plBox(root, panel.queryBox.field)
                    #expect(abs((field.top + field.bottom) / 2 - 29) <= 3, "\(look): field spans \(field.top) to \(field.bottom)")
                }
                let responder = panel.firstResponder
                let inField = responder === panel.queryBox.field || (responder as? NSText)?.delegate === panel.queryBox.field
                #expect(inField, "the first responder is \(String(describing: responder))")
            }
        }

        @MainActor
        @Test func theListAndThePaneStayInTheTreeAndTheKeyLoopAndTheHintIsDrawnAboveThem() async throws {
            try await plWithPanel { panel in
                for look in DTLook.allCases {
                    let root = plLayout(panel, look: look)
                    let table = try #require(plList(root), "\(look): no list in the tree")
                    #expect(plVisible(table), "\(look): the list is hidden")
                    #expect((table as? NSTableView)?.numberOfRows == 0, "\(look): the list has \(String(describing: (table as? NSTableView)?.numberOfRows)) rows")
                    let scroll = try #require(pcScroll(table), "\(look): no scroll view")
                    #expect(plVisible(scroll), "\(look): the list's scroll view is hidden")
                    let pane = try #require(pcPane(root), "\(look): no pane in the tree")
                    #expect(plVisible(pane), "\(look): the pane is hidden")
                    let frames = prViews(pane).filter { plVisible($0) && $0.layer?.cornerRadius == 10 }
                    #expect(frames.isEmpty, "\(look): \(frames.count) frames of radius 10 are drawn in the pane")
                    let group = try pcHintView(root)
                    #expect(pcIndex(of: scroll, before: group) == true, "\(look): the hint is not drawn after the list")
                    #expect(pcIndex(of: pane, before: group) == true, "\(look): the hint is not drawn after the pane")
                }
                let field = panel.queryBox.field
                let list = try #require(field.nextKeyView, "the field has no next key view")
                #expect(list.accessibilityLabel() == "Results")
                #expect(list.nextKeyView === field)
            }
        }

        @MainActor
        @Test func searchingKeepsTheSplitWithTheDividerAtThreeEightyFourAndNoEmptyHint() async throws {
            try await plWithTypingPanel { panel in
                await pcSearching(panel)
                try pcExpectSplit(panel, "searching", banner: false)
            }
        }

        @MainActor
        @Test func noMatchesKeepsTheSplitWithTheDividerAtThreeEightyFourAndNoEmptyHint() async throws {
            try await prWithPanel(answering: true) { panel in
                await prType("zzqx", into: panel, pauseMilliseconds: 20)
                let shown = await spEventually(timeout: 30) { prShownTexts(panel.contentView!).contains("No matches") }
                #expect(shown, "never shown No matches; shown: \(prShownTexts(panel.contentView!))")
                try pcExpectSplit(panel, "no matches", banner: false)
            }
        }

        @MainActor
        @Test func searchFailedKeepsTheSplitWithTheDividerAtThreeEightyFourAndNoEmptyHint() async throws {
            let photos = [PRPhoto(name: "a.jpg", words: "a dog on the beach"), PRPhoto(name: "b.jpg", words: "a dog on the lawn")]
            try await prWithPanel(photos: photos) { panel in
                await prType("a quiet harbour at dawn", into: panel, pauseMilliseconds: 20)
                let failed = await spEventually(timeout: 30) { prShownTexts(panel.contentView!).contains("Could not search just now") }
                #expect(failed, "never shown the failure; shown: \(prShownTexts(panel.contentView!))")
                try pcExpectSplit(panel, "search failed", banner: false)
            }
        }

        @MainActor
        @Test func resultRowsKeepTheSplitWithTheDividerAtThreeEightyFourAndNoEmptyHint() async throws {
            let photos = [PRPhoto(name: "a.jpg", words: "a dog on the beach"), PRPhoto(name: "b.jpg", words: "a dog on the lawn")]
            try await prWithPanel(photos: photos, answering: true) { panel in
                await prType("dog", into: panel, pauseMilliseconds: 20)
                let rows = await spEventually(timeout: 30) {
                    guard let table = plList(panel.contentView!) as? NSTableView else { return false }
                    return table.numberOfRows > 0
                }
                #expect(rows, "the list never showed rows; shown: \(prShownTexts(panel.contentView!))")
                try pcExpectSplit(panel, "rows", banner: false)
            }
        }

        @MainActor
        @Test func theIndexingBannerWithTypedTextKeepsTheSplitStartingAtTheBottomOfTheBanner() async throws {
            try await plWithTypingPanel(pcIndexing()) { panel in
                panel.queryBox.type("a")
                try pcExpectSplit(panel, "banner with typed text", banner: true)
            }
        }

        @MainActor
        @Test func eachNotReadyStateKeepsNoDividerNoListNoPaneAndNoEmptyHintWithTheBlockFullWidth() async throws {
            for state in pcNotReadyCases() {
                try await plWithPanel(state.conditions) { panel in
                    try pcExpectNotReady(panel, state.name)
                }
            }
        }

        @MainActor
        @Test func theFirstTypedCharacterLeavesTheEmptyStateInTheSameCallAndClearingReturnsIt() async throws {
            try await plWithTypingPanel { panel in
                try pcExpectEmptyState(panel, "before typing", banner: false)
                panel.queryBox.type("a")
                try pcExpectTypedState(panel, "after a")
                panel.queryBox.type("b")
                #expect(panel.queryBox.text == "ab", "the box holds \"\(panel.queryBox.text)\"")
                try pcExpectTypedState(panel, "after ab")
                panel.pressEscape()
                #expect(panel.queryBox.text == "", "Esc left \"\(panel.queryBox.text)\"")
                try pcExpectEmptyState(panel, "after Esc", banner: false)
            }
        }

        @MainActor
        @Test func fiveSpacesKeepTheEmptyStateAndTheNextCharacterLeavesIt() async throws {
            try await plWithTypingPanel { panel in
                panel.queryBox.type("     ")
                #expect(panel.queryBox.text == "     ", "the box holds \"\(panel.queryBox.text)\"")
                try pcExpectEmptyState(panel, "five spaces", banner: false)
                panel.queryBox.type("x")
                try pcExpectTypedState(panel, "after x")
            }
        }

        @MainActor
        @Test func theBannerWithAnEmptyBoxReturnsAfterEscapeAndTheFirstCharacterBringsTheDividerBack() async throws {
            try await plWithTypingPanel(pcIndexing()) { panel in
                try pcExpectEmptyState(panel, "banner, before typing", banner: true)
                panel.queryBox.type("a")
                try pcExpectSplit(panel, "banner, after a", banner: true)
                panel.pressEscape()
                try pcExpectEmptyState(panel, "banner, after Esc", banner: true)
            }
        }

        @MainActor
        @Test func becomingReadyFromNotReadyShowsTheCentredHintWithNoDividerAndTheList() async throws {
            try await plWithPanel(pcDownloading()) { panel in
                try pcExpectNotReady(panel, "downloading")
                let cache = await pcAttach(PLConditions(), to: panel)
                try pcExpectEmptyState(panel, "after becoming ready", banner: false)
                let root = plLayout(panel)
                let table = try #require(plList(root))
                #expect(plVisible(table), "the list is hidden after becoming ready")
                #expect(plVisible(try #require(pcPane(root))), "the pane is hidden after becoming ready")
                withExtendedLifetime(cache) {}
            }
        }

        @MainActor
        @Test func becomingNotReadyFromTheEmptyStateHidesTheHintAndKeepsNoDivider() async throws {
            try await plWithPanel { panel in
                try pcExpectEmptyState(panel, "before", banner: false)
                let cache = await pcAttach(pcDownloading(), to: panel)
                try pcExpectNotReady(panel, "after becoming not ready")
                withExtendedLifetime(cache) {}
            }
        }

        @MainActor
        @Test func aSecondOfRefreshingWithNothingChangedFlipsNoHiddenFlag() async throws {
            try await plWithPanel { panel in
                let before = try pcHiddenStates(panel)
                let root = plLayout(panel)
                #expect(plVisibleDividers(root).isEmpty, "a divider is shown in the empty state")
                #expect(plVisible(try pcHintView(root)), "the hint is hidden in the empty state")
                await spWait(1.2)
                let after = try pcHiddenStates(panel)
                #expect(before == after, "hidden flags before \(before), after \(after)")
                let laid = plLayout(panel)
                #expect(plVisibleDividers(laid).isEmpty, "a divider is shown after a second")
                #expect(plVisible(try pcHintView(laid)), "the hint is hidden after a second")
            }
        }
    }
}

import AppKit
import Foundation
import Testing
@testable import SesameEngine
@testable import Sesame

private let sfqReadNote = "Photos, PDFs, documents, audio and video are read."
private let sfqStartError = "Could not save the settings, so indexing did not start."
private let sfqAddFolder = "Add folder\u{2026}"
private let sfqHintTicked = "Indexing starts when you press Start indexing, and runs in the background."
private let sfqTotal = "About 5 min in total"
private let sfqSummary = "105 files in 3 folders"
private let sfqReady = "Search model ready"
private let sfqLongName = "Photos-from-the-summer-trip-to-the-coast"
private let sfqVeryLongName = String(repeating: "abcdefghij", count: 12)
private let sfqRowNames = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
private let sfqMissing = ["Downloads", "Movies"]
private let sfqFixture: [(name: String, count: String, tooltip: String, label: String)] = [
    ("Desktop", "3", "3 documents", "Desktop, 3 documents, "),
    ("Documents", "2", "2 PDFs", "Documents, 2 PDFs, "),
    ("Pictures", "100", "100 photos", "Pictures, 100 photos, "),
]

private final class SFQGate: @unchecked Sendable {
    private let cond = NSCondition()
    private var held = true

    func release() { cond.lock(); held = false; cond.broadcast(); cond.unlock() }

    func enter() {
        cond.lock()
        while held { cond.wait() }
        cond.unlock()
    }
}

@MainActor
private func sfqEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func sfqChecks(_ root: NSView, _ rig: SLRig) -> [NSButton] {
    slButtons(root)
        .filter { ($0.accessibilityHelp() ?? "").hasPrefix(rig.env.home.path) }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func sfqCheck(_ root: NSView, _ rig: SLRig, _ name: String) -> NSButton? {
    sfqChecks(root, rig).first { $0.title == name }
}

@MainActor
private func sfqCard(_ root: NSView, _ rig: SLRig) -> GroupCard? {
    sfqCheck(root, rig, "Pictures").flatMap { slCard(of: $0) }
}

@MainActor
private func sfqBeside(_ root: NSView, _ check: NSButton) -> [NSTextField] {
    let row = plBox(root, check)
    return plTexts(root).filter { field in
        let box = plBox(root, field)
        return abs((box.top + box.bottom) / 2 - (row.top + row.bottom) / 2) <= 6 && box.minX >= row.maxX - 0.5
    }
}

@MainActor
private func sfqFits(_ field: NSTextField) -> Bool {
    let width = (field.stringValue as NSString).size(withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: 12)]).width
    return field.frame.width + 0.5 >= width
}

@MainActor
private func sfqAddRows(_ rig: SLRig, _ urls: [URL], _ root: NSView) async -> Bool {
    rig.picks.value = urls
    slButton(root, sfqAddFolder)?.performClick(nil)
    return await sfqEventually { rig.folders.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } }
}

@MainActor
private func sfqTitleColour(_ button: NSButton) -> NSColor? {
    if button.attributedTitle.length > 0,
       let colour = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
        return colour
    }
    return button.contentTintColor
}

@MainActor
private func sfqScrollerShown(_ scroll: NSScrollView) -> Bool {
    scroll.hasVerticalScroller && scroll.verticalScroller.map { !$0.isHidden } == true
}

@MainActor
private func sfqReturn(_ window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
}

@MainActor
private func sfqFoot(_ root: NSView) -> [NSView] {
    [slButton(root, sfqAddFolder), plText(root, sfqHintTicked), plText(root, sfqReadNote), slButton(root, "Not now")].compactMap { $0 }
}

extension ModelDownloadTests {
    @Suite("SetupFoldersQuietListTests", .serialized)
    struct SetupFoldersQuietListTests {

        @MainActor
        @Test(arguments: slPaths) func eachRowIsOneSwitchCheckboxNamedByItsFolderWithTheNameLeftAndOneRightAlignedTwelvePointSecondaryCount(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .folders)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let checks = sfqChecks(root, rig)
                        #expect(checks.map(\.title) == sfqRowNames, "\(tag): rows \(checks.map(\.title))")
                        let reference = NSButton()
                        reference.setButtonType(.switch)
                        var rightEdges: [CGFloat] = []
                        for check in checks {
                            let name = check.title
                            let isMissing = sfqMissing.contains(name)
                            let entry = sfqFixture.first { $0.name == name }
                            #expect(check is SetupButton, "\(tag) \(name): not a SetupButton")
                            let cell = check.cell as? NSButtonCell
                            let want = reference.cell as? NSButtonCell
                            #expect(cell?.showsStateBy == want?.showsStateBy && cell?.highlightsBy == want?.highlightsBy
                                    && cell?.isBordered == want?.isBordered && cell?.bezelStyle == want?.bezelStyle,
                                    "\(tag) \(name): not a switch-type button")
                            #expect(check.accessibilityHelp() == rig.env.home.appendingPathComponent(name).path, "\(tag) \(name): help \(String(describing: check.accessibilityHelp()))")
                            if isMissing {
                                #expect(check.accessibilityLabel() == "\(name), not found", "\(tag) \(name): label \(String(describing: check.accessibilityLabel()))")
                                #expect(check.toolTip == "not found", "\(tag) \(name): tooltip \(String(describing: check.toolTip))")
                                #expect(!check.isEnabled, "\(tag) \(name): enabled")
                            } else if let entry {
                                #expect((check.accessibilityLabel() ?? "").hasPrefix(entry.label), "\(tag) \(name): label \(String(describing: check.accessibilityLabel()))")
                                #expect(check.toolTip == entry.tooltip, "\(tag) \(name): tooltip \(String(describing: check.toolTip)), wanted \(entry.tooltip)")
                                if name == "Pictures", state == .whole {
                                    #expect(check.accessibilityLabel() == "Pictures, 100 photos, about 5 min", "\(tag): label \(String(describing: check.accessibilityLabel()))")
                                }
                            }
                            let counts = sfqBeside(root, check)
                            let wanted = isMissing ? "not found" : (entry?.count ?? "")
                            #expect(counts.map(\.stringValue) == [wanted], "\(tag) \(name): texts right of the checkbox on its row \(counts.map(\.stringValue)), wanted [\(wanted)]")
                            guard let field = counts.first else { continue }
                            #expect(slFont(field.font, size: 12, weight: .regular), "\(tag) \(name): count font \(String(describing: field.font))")
                            #expect(slColour(field.textColor, is: .secondaryLabelColor), "\(tag) \(name): count colour")
                            #expect(!field.isAccessibilityElement(), "\(tag) \(name): the count is an accessibility element")
                            #expect(sfqFits(field), "\(tag) \(name): the count frame \(field.frame.width) is narrower than its text")
                            let ink = slInk(field, look)
                            #expect(ink != nil && (ink?.maxX ?? 0) >= field.bounds.width - 4, "\(tag) \(name): the count is not drawn against its right edge \(String(describing: ink)) of \(field.bounds.width)")
                            #expect(plBox(root, check).minX < plBox(root, field).minX, "\(tag) \(name): the name is not left of the count")
                            rightEdges.append(plBox(root, field).maxX)
                        }
                        if let low = rightEdges.min(), let high = rightEdges.max() {
                            #expect(high - low <= 1, "\(tag): count right edges differ by \(high - low): \(rightEdges)")
                        }
                        let texts = plTexts(root).map(\.stringValue)
                        #expect(!texts.contains("100 photos, about 5 min"), "\(tag): the old detail text is on screen")
                        #expect(!texts.filter { $0 != sfqReadNote }.contains { $0.contains("photos") || $0.contains("PDFs") || $0.contains("documents,") }, "\(tag): a breakdown is on screen: \(texts)")
                        #expect(!texts.contains { $0.contains("measuring speed") || $0.contains("after the model download") || $0.contains("nothing to read") }, "\(tag): a per-row estimate is on screen: \(texts)")
                        #expect(!texts.contains { $0.lowercased().contains("about") && !$0.hasSuffix(" in total") }, "\(tag): an estimate text is on screen: \(texts)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aFolderNameLongerThanTheRowTruncatesInTheMiddleAndTheCountIsNeverTruncated(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                let veryLong = try rig.env.fill(sfqVeryLongName, photo: 3)
                let long = try rig.env.fill(sfqLongName, photo: 3)
                #expect(sfqLongName.count == 40 && sfqVeryLongName.count == 120)
                await slWalk(rig, to: .folders)
                let ready = await sfqAddRows(rig, [veryLong, long], slLayout(rig))
                #expect(ready, "the rows never became ready")
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let card = try #require(sfqCard(root, rig), "\(look): no list card")
                    let cardBox = plBox(root, card)
                    for name in [sfqVeryLongName, sfqLongName] {
                        let check = try #require(sfqCheck(root, rig, name), "\(look): no row named \(name.prefix(12))")
                        #expect(check.lineBreakMode == .byTruncatingMiddle, "\(look) \(name.prefix(12)): line break mode \(check.lineBreakMode.rawValue)")
                        let counts = sfqBeside(root, check)
                        #expect(counts.map(\.stringValue) == ["3"], "\(look) \(name.prefix(12)): count texts \(counts.map(\.stringValue))")
                        guard let field = counts.first else { continue }
                        #expect(sfqFits(field), "\(look) \(name.prefix(12)): the count frame \(field.frame.width) is narrower than its text")
                        #expect(plBox(root, check).maxX <= plBox(root, field).minX + 0.5, "\(look) \(name.prefix(12)): the name reaches \(plBox(root, check).maxX), the count starts at \(plBox(root, field).minX)")
                        #expect(plBox(root, field).maxX <= cardBox.maxX, "\(look) \(name.prefix(12)): the count leaves the card")
                        let titleWidth = (name as NSString).size(withAttributes: [.font: check.font ?? NSFont.systemFont(ofSize: 13)]).width
                        if name == sfqLongName {
                            #expect(check.frame.width >= titleWidth + 14, "\(look): the 40-character name is cut: \(check.frame.width) pt for \(titleWidth) pt")
                        } else {
                            #expect(check.frame.width < titleWidth, "\(look): the 120-character name is not narrowed to the row: \(check.frame.width) pt for \(titleWidth) pt")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aRowBeingCountedReadsCountingInItsCountAndTheTooltipAndNoRowShowsAFigureYet(glass: Bool) async throws {
            let gate = SFQGate()
            defer { gate.release() }
            let counter: @Sendable ([String]) -> FolderCounts = { paths in
                gate.enter()
                var per: [String: [String: Int]] = [:]
                for path in paths { per[path] = ["photo": 1] }
                return FolderCounts(perFolder: per, summary: ["photo": paths.count], total: paths.count, unreadable: [])
            }
            try await slWith(.whole, glass: glass, counter: counter) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "\(look)"
                    for name in ["Desktop", "Documents", "Pictures"] {
                        let check = try #require(sfqCheck(root, rig, name), "\(tag): no row \(name)")
                        #expect(check.toolTip == "counting", "\(tag) \(name): tooltip \(String(describing: check.toolTip))")
                        #expect(check.accessibilityLabel() == "\(name), counting", "\(tag) \(name): label \(String(describing: check.accessibilityLabel()))")
                        let counts = sfqBeside(root, check)
                        #expect(counts.map(\.stringValue) == ["counting"], "\(tag) \(name): count texts \(counts.map(\.stringValue))")
                        if let field = counts.first {
                            #expect(slFont(field.font, size: 12, weight: .regular) && slColour(field.textColor, is: .secondaryLabelColor), "\(tag) \(name): count style")
                            #expect(sfqFits(field), "\(tag) \(name): the count frame is narrower than its text")
                        }
                    }
                    for name in sfqMissing {
                        let check = try #require(sfqCheck(root, rig, name), "\(tag): no row \(name)")
                        #expect(sfqBeside(root, check).map(\.stringValue) == ["not found"], "\(tag) \(name): count texts")
                    }
                    #expect(plText(root, "Counting files\u{2026}") != nil, "\(tag): no counting summary \(plTexts(root).map(\.stringValue))")
                    #expect(!plTexts(root).contains { $0.stringValue.contains("about") || $0.stringValue.contains("in total") }, "\(tag): an estimate is on screen while counting")
                }
                gate.release()
            }
        }

        @MainActor
        @Test(arguments: slPaths) func anUntickedNeverCountedRowHasNoCountTextAndATooltipOfNotCounted(glass: Bool) async throws {
            let settings: (SLEnv) throws -> Settings = { env in
                _ = try env.fill("Trips", photo: 2)
                var held = Settings()
                held.folders = [Settings.Folder(path: env.home.appendingPathComponent("Trips").path, code: false, reading: true)]
                return held
            }
            try await slWith(.whole, glass: glass, settings: settings) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let trips = try #require(sfqCheck(root, rig, "Trips"), "\(look): no Trips row")
                    #expect(trips.state == .on, "\(look): Trips is not ticked")
                    #expect(sfqBeside(root, trips).map(\.stringValue) == ["2"], "\(look): Trips count texts \(sfqBeside(root, trips).map(\.stringValue))")
                    #expect(trips.toolTip == "2 photos", "\(look): Trips tooltip \(String(describing: trips.toolTip))")
                    for name in ["Desktop", "Documents", "Pictures"] {
                        let check = try #require(sfqCheck(root, rig, name), "\(look): no row \(name)")
                        #expect(check.state == .off, "\(look) \(name): ticked")
                        #expect(check.toolTip == "not counted", "\(look) \(name): tooltip \(String(describing: check.toolTip))")
                        #expect(check.accessibilityLabel() == "\(name), not counted", "\(look) \(name): label \(String(describing: check.accessibilityLabel()))")
                        #expect(sfqBeside(root, check).isEmpty, "\(look) \(name): texts right of an unticked never-counted row \(sfqBeside(root, check).map(\.stringValue))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theSummaryBlockIsACentredTitleThenTheThirteenPointSummaryThenTheTotalLineAndNoSpeedLineAnywhere(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let title = try #require(swlTexts(root, "Folders to read").first, "\(look): no title")
                    let summary = try #require(swlTexts(root, sfqSummary).first, "\(look): no summary line in \(plTexts(root).map(\.stringValue))")
                    let total = try #require(swlTexts(root, sfqTotal).first, "\(look): no total line")
                    let card = try #require(sfqCard(root, rig), "\(look): no list card")
                    #expect(plBox(root, title).bottom <= plBox(root, summary).top + 0.5, "\(look): the summary is above the title ends")
                    #expect(slFont(summary.font, size: 13, weight: .regular), "\(look): summary font \(String(describing: summary.font))")
                    #expect(slColour(summary.textColor, is: .labelColor), "\(look): summary colour")
                    #expect(slFont(total.font, size: 12, weight: .regular), "\(look): total font \(String(describing: total.font))")
                    #expect(slColour(total.textColor, is: .secondaryLabelColor), "\(look): total colour")
                    for field in [summary, total] {
                        let mid = swlInkMid(root, field, look)
                        #expect(mid != nil && abs((mid ?? 0) - 280) <= 8, "\(look): \"\(field.stringValue)\" ink centre \(String(describing: mid)), window centre 280")
                    }
                    let gap = swlGap(root, upper: [summary], lower: [total])
                    #expect(gap.near(8), "\(look): \(gap.frame) / \(gap.aligned) pt from the summary to the total, wanted 8")
                    #expect(plBox(root, total).bottom <= plBox(root, card).top + 0.5, "\(look): the total line is not above the card")
                }
            }
            try await slWith(.downloading, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                let root = slLayout(rig)
                #expect(plText(root, sfqSummary) != nil, "downloading: no summary line")
                #expect(!plTexts(root).contains { $0.stringValue.hasSuffix(" in total") }, "downloading: a total line is shown")
            }
            for state in [SLState.whole, SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        let root = slLayout(rig)
                        #expect(!prShownTexts(root).contains { $0.contains("Photos: about") }, "\(state) / \(entry.label): a speed line is on screen")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theCardIsExactlyAsTallAsItsRowsUpToSixRowsThenScrollsInsideItselfAtTheSixRowHeight(glass: Bool) async throws {
            for extra in [0, 1, 2, 3] {
                try await slWith(.whole, glass: glass) { rig in
                    let added = try (0..<extra).map { try rig.env.fill("Extra-\($0)", photo: 1) }
                    await slWalk(rig, to: .folders)
                    if !added.isEmpty {
                        let ready = await sfqAddRows(rig, added, slLayout(rig))
                        #expect(ready, "\(extra) added: the rows never became ready")
                    }
                    let rows = 5 + extra
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(rows) rows \(look)"
                        let checks = sfqChecks(root, rig)
                        #expect(checks.count == rows, "\(tag): \(checks.count) checkboxes")
                        guard let first = checks.first else { continue }
                        let reference = NSButton(checkboxWithTitle: "Pictures", target: nil, action: nil)
                        reference.font = first.font
                        let rowHeight = reference.fittingSize.height
                        let card = try #require(sfqCard(root, rig), "\(tag): no list card")
                        let cardBox = plBox(root, card)
                        let shown = CGFloat(min(rows, 6))
                        let wanted = shown * rowHeight + (shown - 1) * 16 + 32
                        #expect(abs(cardBox.height - wanted) <= 1, "\(tag): the card is \(cardBox.height) pt high, \(shown) rows of \(rowHeight) with 16 between and 32 of padding is \(wanted)")
                        for check in checks {
                            #expect(abs(plBox(root, check).height - rowHeight) <= 1, "\(tag) \(check.title): \(plBox(root, check).height) pt high, a reference switch is \(rowHeight)")
                        }
                        let tops = checks.map { plBox(root, $0).top }
                        for (upper, lower) in zip(tops, tops.dropFirst()) {
                            #expect(abs((lower - upper) - (rowHeight + 16)) <= 1, "\(tag): rows \(lower - upper) pt apart, wanted \(rowHeight + 16)")
                        }
                        #expect(tops[0] - cardBox.top >= 0 && tops[0] - cardBox.top <= 24, "\(tag): the first row starts \(tops[0] - cardBox.top) pt below the top of the card")
                        let scrolls = prViews(root).compactMap { $0 as? NSScrollView }.filter { plVisible($0) }
                        for scroll in scrolls { #expect(slAncestors(scroll).contains { $0 === card }, "\(tag): a visible scroll view is outside the card") }
                        #expect(scrolls.count <= 1, "\(tag): \(scrolls.count) scroll views")
                        let scrollers = prViews(root).compactMap { $0 as? NSScroller }.filter { plVisible($0) }
                        for scroller in scrollers {
                            #expect(slAncestors(scroller).contains { ancestor in scrolls.contains { $0 === ancestor } }, "\(tag): a scroller is outside the one scroll view")
                        }
                        if rows > 6 {
                            #expect(scrolls.count == 1, "\(tag): \(scrolls.count) scroll views, wanted 1")
                            guard let scroll = scrolls.first, let document = scroll.documentView else { continue }
                            #expect(document.frame.height > scroll.contentView.bounds.height + 0.5, "\(tag): the document is \(document.frame.height) pt, the clip \(scroll.contentView.bounds.height)")
                            #expect(sfqScrollerShown(scroll), "\(tag): the scroller is not shown while the rows overflow")
                        } else {
                            let last = checks.map { plBox(root, $0).bottom }.max() ?? 0
                            #expect(abs(cardBox.bottom - (last + 16)) <= 1, "\(tag): the card ends at \(cardBox.bottom), the last row ends at \(last), padding 16")
                            for scroll in scrolls {
                                #expect(!sfqScrollerShown(scroll), "\(tag): a scroller is shown for \(rows) rows")
                                if let document = scroll.documentView { #expect(document.frame.height <= scroll.contentView.bounds.height + 0.5, "\(tag): the rows overflow their clip") }
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func underTheCardAreAddFolderTheHintTheReadNoteAndNotNowTwelveApartAndTheStartErrorRowUnderThem(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .folders)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let card = try #require(sfqCard(root, rig), "\(tag): no list card")
                        let add = try #require(slButton(root, sfqAddFolder), "\(tag): no Add folder")
                        let note = try #require(plText(root, sfqReadNote), "\(tag): no read note")
                        var steps: [(String, SWLGap)] = [("card to Add folder", swlGap(root, upper: [card], lower: [add]))]
                        if state == .whole {
                            let hint = try #require(plText(root, sfqHintTicked), "\(tag): no hint")
                            let notNow = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                            steps.append(("Add folder to the hint", swlGap(root, upper: [add], lower: [hint])))
                            steps.append(("the hint to the read note", swlGap(root, upper: [hint], lower: [note])))
                            steps.append(("the read note to Not now", swlGap(root, upper: [note], lower: [notNow])))
                            #expect(abs(plBox(root, notNow).midX - 280) <= 8, "\(tag): Not now centre \(plBox(root, notNow).midX), window centre 280")
                        } else {
                            #expect(plText(root, sfqHintTicked) == nil && slButton(root, "Not now") == nil, "\(tag): a hint or Not now is shown with a model that is not whole")
                            steps.append(("Add folder to the read note", swlGap(root, upper: [add], lower: [note])))
                        }
                        for (name, gap) in steps { #expect(gap.near(12, 1), "\(tag): \(name) is \(gap.frame) / \(gap.aligned) pt, wanted 12") }
                        #expect(abs(slAlignBox(root, add).minX - plBox(root, card).minX) <= 1 || abs(plBox(root, add).minX - plBox(root, card).minX) <= 1,
                                "\(tag): Add folder starts at \(plBox(root, add).minX), the card at \(plBox(root, card).minX)")
                        let mid = swlInkMid(root, note, look)
                        #expect(mid != nil && abs((mid ?? 0) - 280) <= 8, "\(tag): read note ink centre \(String(describing: mid)), window centre 280")
                        #expect(slFont(note.font, size: 12, weight: .regular), "\(tag): note font \(String(describing: note.font))")
                        #expect(slColour(note.textColor, is: .secondaryLabelColor), "\(tag): note colour")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func addFolderIsABorderlessSecondaryTitledButtonWithNoBezelColourOrKeyEquivalentEnabledBeforeStartOnBothPaths(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let add = try #require(slButton(root, sfqAddFolder), "\(look): no Add folder")
                    #expect(add is SetupButton, "\(look): Add folder is not a SetupButton")
                    #expect(add.title == sfqAddFolder && add.accessibilityLabel() == sfqAddFolder, "\(look): title \(add.title), label \(String(describing: add.accessibilityLabel()))")
                    #expect(!add.isBordered, "\(look): Add folder is bordered")
                    #expect(add.keyEquivalent.isEmpty, "\(look): key equivalent \(add.keyEquivalent.debugDescription)")
                    #expect(add.bezelColor == nil, "\(look): bezel colour \(String(describing: add.bezelColor))")
                    #expect(add.bezelStyle.rawValue != 16, "\(look): a glass bezel")
                    #expect(slColour(sfqTitleColour(add), is: .secondaryLabelColor), "\(look): title colour \(String(describing: sfqTitleColour(add)))")
                    #expect(add.isEnabled, "\(look): Add folder is disabled before Start")
                }
            }
            let started: (SLEnv) throws -> Settings = { _ in
                var held = Settings()
                held.startPressed = true
                return held
            }
            try await slWith(.whole, glass: glass, settings: started) { rig in
                await slWalk(rig, to: .folders)
                let root = slLayout(rig)
                let add = try #require(slButton(root, sfqAddFolder), "no Add folder after Start")
                #expect(!add.isEnabled, "Add folder is enabled after Start")
                #expect(!add.isBordered, "Add folder is bordered after Start")
                #expect(slColour(sfqTitleColour(add), is: .secondaryLabelColor) || !add.isEnabled, "title colour after Start")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func notNowIsABorderlessSecondaryTitledButtonCentredWithNoBezelColourOrKeyEquivalentAndReturnPressesTheFooterButtonThatStartsIndexing(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let notNow = try #require(slButton(root, "Not now"), "\(look): no Not now")
                    #expect(notNow is SetupButton, "\(look): not a SetupButton")
                    #expect(!notNow.isBordered, "\(look): Not now is bordered")
                    #expect(notNow.title == "Not now" && notNow.accessibilityLabel() == "Not now", "\(look): title \(notNow.title), label \(String(describing: notNow.accessibilityLabel()))")
                    #expect(notNow.bezelColor == nil, "\(look): bezel colour \(String(describing: notNow.bezelColor))")
                    #expect(notNow.keyEquivalent.isEmpty, "\(look): key equivalent \(notNow.keyEquivalent.debugDescription)")
                    #expect(slColour(sfqTitleColour(notNow), is: .secondaryLabelColor), "\(look): title colour \(String(describing: sfqTitleColour(notNow)))")
                    #expect(abs(plBox(root, notNow).midX - 280) <= 8, "\(look): centre \(plBox(root, notNow).midX), window centre 280")
                    let primaries = slButtons(root).filter { $0.keyEquivalent == "\r" }.map(\.title)
                    #expect(primaries == ["Start indexing"], "\(look): Return buttons \(primaries)")
                }
                let handled = rig.window.performKeyEquivalent(with: sfqReturn(rig.window))
                #expect(handled, "Return was not handled on Folders")
                #expect(rig.window.flow.step.title == "Permissions", "Return left the window on \(rig.window.flow.step.title)")
                let settings = rig.env.models.deletingLastPathComponent().appendingPathComponent("settings.json")
                let written = (try? Data(contentsOf: settings)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
                #expect(written?["startPressed"] as? Bool == true, "Return on Folders did not start indexing: \(String(describing: written))")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aStartErrorRowSitsTwelveUnderNotNowWithTheWarningSymbolAndSystemRedText(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .folders)
                let settings = rig.env.models.deletingLastPathComponent().appendingPathComponent("settings.json")
                try "not json".write(to: settings, atomically: true, encoding: .utf8)
                var root = slLayout(rig)
                let start = try #require(slButton(root, "Start indexing"), "no Start indexing")
                start.performClick(nil)
                for look in DTLook.allCases {
                    root = slLayout(rig, look)
                    let tag = "\(look)"
                    let message = try #require(plText(root, sfqStartError), "\(tag): no start error text in \(plTexts(root).map(\.stringValue))")
                    #expect(slColour(message.textColor, is: .systemRed), "\(tag): error colour")
                    let warnings = plAccessibilityImages(root).filter { plVisible($0) }.compactMap { $0 as? NSImageView }
                    #expect(warnings.count == 1, "\(tag): \(warnings.count) warning symbols")
                    guard let warning = warnings.first else { continue }
                    #expect(warning.accessibilityLabel() == "Warning", "\(tag): warning label")
                    #expect(slColour(warning.contentTintColor, is: .systemRed), "\(tag): warning tint")
                    #expect(rig.window.flow.step == .folders, "\(tag): the window left Folders after a start error: \(rig.window.flow.step.title)")
                    let begin = try #require(slButton(root, "Not now"), "\(tag): no Not now")
                    let gap = swlGap(root, upper: [begin], lower: [message, warning])
                    #expect(gap.near(12, 1), "\(tag): the error row is \(gap.frame) / \(gap.aligned) pt under Not now, wanted 12")
                    let footer = swlNav(root)
                    let below = swlGap(root, upper: [message, warning], lower: footer)
                    #expect(max(below.frame, below.aligned) >= 15.5, "\(tag): the error row ends \(below.frame) / \(below.aligned) pt above the footer")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aWholeModelShowsNoStatusLineAndNoCardOnFoldersAndPermissionsButWelcomeAloneKeepsTheStatusLine(glass: Bool) async throws {
            try await slWith(.whole, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(entry.label) \(look)"
                        let ready = plText(root, sfqReady) != nil
                        let check = swlImages(root, "checkmark.circle.fill").count
                        let quiet = entry.step == .folders || entry.step == .permissions || entry.step == .shortcut
                        #expect(ready == !quiet, "\(tag): ready line shown \(ready)")
                        #expect(check == (quiet ? 0 : 1), "\(tag): \(check) status checks")
                        #expect(slStyle(root, "The search model") == nil, "\(tag): the model card heading is shown for a whole model")
                        #expect(!prViews(root).contains { ($0 is NSProgressIndicator || $0 is FigureView) && plVisible($0) }, "\(tag): a bar or figure is shown")
                        #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                        if entry.step == .folders {
                            let gap = swlGap(root, upper: sfqFoot(root), lower: swlNav(root))
                            #expect(sfqFoot(root).count == 4, "\(tag): the foot has \(sfqFoot(root).count) of its 4 parts")
                            #expect(max(gap.frame, gap.aligned) >= 15.5, "\(tag): the foot ends \(gap.frame) / \(gap.aligned) pt above the footer, wanted at least 16")
                        }
                    }
                }
                let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                #expect(size.width == 560 && size.height == 600, "content size \(size)")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aModelThatIsNotWholeShowsTheCardBarFigureAndRetryOnFoldersSixteenAboveTheFooterWithNothingOverlapping(glass: Bool) async throws {
            for state in [SLState.downloading, SLState.damaged, SLState.failed] {
                try await slWith(state, glass: glass) { rig in
                    for entry in slStepNames {
                        await slWalk(rig, to: entry.step)
                        let root = slLayout(rig)
                        let tag = "\(state) / \(entry.label)"
                        #expect(plText(root, sfqReady) == nil, "\(tag): the ready line is shown")
                        #expect(swlImages(root, "checkmark.circle.fill").isEmpty, "\(tag): the status check is shown")
                        #expect(slStyle(root, "The search model") != nil, "\(tag): no model heading")
                        let bars = prViews(root).compactMap { $0 as? NSProgressIndicator }.filter { plVisible($0) }
                        let figures = prViews(root).compactMap { $0 as? FigureView }.filter { plVisible($0) }
                        #expect(bars.count == 1 && figures.count == 1, "\(tag): \(bars.count) bars, \(figures.count) figures")
                        guard entry.step == .folders, let bar = bars.first, let figure = figures.first else { continue }
                        #expect(figure.accessibilityTitle() == "Model download", "\(tag): figure title \(String(describing: figure.accessibilityTitle()))")
                        let card = try #require(slCard(of: bar), "\(tag): the bar is in no card")
                        #expect(slCard(of: figure) === card, "\(tag): the figure is in another card")
                        var block: [NSView] = [card]
                        let retry = slButton(root, "Retry")
                        if state == .failed {
                            #expect(retry != nil && retry?.isEnabled == true, "\(tag): no enabled Retry")
                            #expect(plText(root, "Try again in a moment.") != nil, "\(tag): no next-step line")
                            if let retry { block.append(retry) }
                        } else {
                            #expect(retry == nil, "\(tag): Retry is shown")
                        }
                        let gap = swlGap(root, upper: block, lower: swlNav(root))
                        #expect(max(gap.frame, gap.aligned) >= 15.5, "\(tag): the model block ends \(gap.frame) / \(gap.aligned) pt above the footer, wanted at least 16")
                        let foot = sfqFoot(root)
                        #expect(foot.count == 2, "\(tag): the foot has \(foot.count) parts, wanted Add folder and the read note only")
                        let blockBox = block.map { plBox(root, $0) }.dropFirst().reduce(plBox(root, card)) { $0.union($1) }
                        let lowest = foot.map { plBox(root, $0).bottom }.max() ?? 0
                        #expect(lowest <= blockBox.top + 0.5, "\(tag): the foot ends at \(lowest), the model block starts at \(blockBox.top)")
                        for part in foot { #expect(!plBox(root, part).intersects(blockBox), "\(tag): the foot overlaps the model block") }
                        let order = foot.map { plBox(root, $0) }
                        #expect(order.count == 2 && order[0].bottom <= order[1].top + 0.5,
                                "\(tag): the foot is not Add folder, read note from the top: \(order.map(\.top))")
                        let listCard = try #require(sfqCard(root, rig), "\(tag): no list card")
                        #expect(listCard !== card, "\(tag): the list card is the model card")
                        #expect(!plBox(root, listCard).intersects(blockBox), "\(tag): the list overlaps the model block")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func inDamagedFailedAndDamagedThenFailedStatesFoldersContentEndsAtLeastEightAboveTheModelBlockWithFiveOrSixRowsAndTheWindowStaysFiveSixtyBySixHundredWithTheFooterTwentyFromTheBottom(glass: Bool) async throws {
            let states: [(label: String, base: SLState, thenFail: Bool)] = [
                ("damaged", .damaged, false),
                ("failed", .failed, false),
                ("damaged then failed", .damaged, true),
            ]
            for state in states {
                for extra in [0, 1] {
                    for withError in [false, true] {
                        try await slWith(withError ? .whole : state.base, glass: glass) { rig in
                            let added = try (0..<extra).map { try rig.env.fill("Extra-\($0)", photo: 1) }
                            if !withError && state.thenFail {
                                rig.window.model.downloadFailed(slFailedMessage)
                                rig.window.refresh()
                            }
                            await slWalk(rig, to: .folders)
                            if !added.isEmpty {
                                let ready = await sfqAddRows(rig, added, slLayout(rig))
                                #expect(ready, "\(state.label): the rows never became ready")
                            }
                            if withError {
                                let settings = rig.env.models.deletingLastPathComponent().appendingPathComponent("settings.json")
                                try "not json".write(to: settings, atomically: true, encoding: .utf8)
                                let start = try #require(slButton(slLayout(rig), "Start indexing"), "\(state.label): no Start indexing")
                                start.performClick(nil)
                                try FileManager.default.removeItem(at: rig.env.models.appendingPathComponent("sl-whole.gguf"))
                                if state.base == .damaged { rig.window.model.modelWasDamaged() }
                                if state.base == .failed || state.thenFail { rig.window.model.downloadFailed(slFailedMessage) }
                                rig.window.refresh()
                            }
                            for look in DTLook.allCases {
                                let root = slLayout(rig, look)
                                let tag = "\(state.label),\(5 + extra) rows, error row \(withError), \(look)"
                                let card = try #require(sfqCard(root, rig), "\(tag): no list card")
                                #expect(sfqChecks(root, rig).count == 5 + extra, "\(tag): \(sfqChecks(root, rig).count) rows")
                                let heading = try #require(plText(root, "The search model"), "\(tag): no model heading")
                                let modelCard = try #require(slCard(of: heading), "\(tag): the model heading is in no card")
                                #expect(modelCard !== card, "\(tag): the list card is the model card")
                                var block: [NSView] = [modelCard]
                                if let retry = slButton(root, "Retry") { block.append(retry) }
                                let blockTop = block.map { plBox(root, $0).top }.min() ?? 0
                                var content: [(String, NSView)] = [("list card", card)]
                                for (name, view) in [("Add folder", slButton(root, sfqAddFolder)), ("read note", plText(root, sfqReadNote))] {
                                    content.append((name, try #require(view, "\(tag): no \(name)")))
                                }
                                #expect(slButton(root, "Not now") == nil && slButton(root, "Start indexing") == nil, "\(tag): Not now or Start indexing is shown with a model that is not whole")
                                #expect(plText(root, sfqHintTicked) == nil && plText(root, "Tick at least one folder to start.") == nil, "\(tag): a hint is shown with a model that is not whole")
                                if withError {
                                    content.append(("error text", try #require(plText(root, sfqStartError), "\(tag): no start error text")))
                                    let warnings = plAccessibilityImages(root).filter { plVisible($0) }.compactMap { $0 as? NSImageView }
                                    #expect(warnings.count >= 1, "\(tag): no warning symbol")
                                    for warning in warnings where warning.accessibilityLabel() == "Warning" && !slAncestors(warning).contains(where: { $0 === modelCard }) {
                                        content.append(("error symbol", warning))
                                    }
                                }
                                for (name, view) in content {
                                    let box = plBox(root, view)
                                    let align = slAlignBox(root, view)
                                    let margin = blockTop - max(box.bottom, align.bottom)
                                    #expect(margin >= 8, "\(tag): \(name) ends at \(box.bottom), the model block starts at \(blockTop): margin \(margin), wanted at least 8")
                                }
                                for button in swlNav(root) {
                                    let frame = plBox(root, button)
                                    let align = slAlignBox(root, button)
                                    #expect(abs((600 - frame.bottom) - 20) <= 2 || abs((600 - align.bottom) - 20) <= 2, "\(tag): a footer button is \(600 - frame.bottom) pt from the bottom, wanted 20")
                                }
                                let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                                #expect(size.width == 560 && size.height == 600, "\(tag): content size \(size)")
                                #expect(root.bounds.size.width == 560 && root.bounds.size.height == 600, "\(tag): content view \(root.bounds.size)")
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func everyNameIsStillFullyVisibleTheKeyLoopVisitsEachTickedRowThenAddFolderNotNowBackAndTheFooterButtonAndTheFoldersStepHasOnlyTheOneGlassView(glass: Bool) async throws {
            for state in [SLState.whole, SLState.downloading] {
                try await slWith(state, glass: glass) { rig in
                    let long = try rig.env.fill(sfqLongName, photo: 3)
                    await slWalk(rig, to: .folders)
                    #expect(await sfqAddRows(rig, [long], slLayout(rig)), "\(state): the rows never became ready")
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let checks = sfqChecks(root, rig)
                        #expect(checks.count == 6, "\(tag): \(checks.count) rows")
                        for check in checks {
                            let titleWidth = (check.title as NSString).size(withAttributes: [.font: check.font ?? NSFont.systemFont(ofSize: 13)]).width
                            #expect(check.frame.width >= titleWidth + 14, "\(tag) \(check.title): \(check.frame.width) pt wide for \(titleWidth) pt of title")
                            #expect(check.lineBreakMode == .byTruncatingMiddle, "\(tag) \(check.title): line break mode \(check.lineBreakMode.rawValue)")
                            if let card = slCard(of: check) { #expect(plBox(root, check).maxX <= plBox(root, card).maxX, "\(tag) \(check.title): leaves the card") }
                        }
                        let ticked = checks.filter { $0.state == .on }.map(\.title)
                        let wanted = ticked + [sfqAddFolder] + (state == .whole ? ["Not now"] : []) + ["Back", state == .whole ? "Start indexing" : "Next"]
                        var loop = slKeyLoop(rig.window).compactMap { ($0 as? NSButton)?.title }.filter { wanted.contains($0) }
                        if let start = loop.firstIndex(of: ticked.first ?? "") { loop = Array(loop[start...] + loop[..<start]) }
                        #expect(loop == wanted, "\(tag): key loop \(loop), wanted \(wanted)")
                        let found = swlPaletteViolations(root, look, allowError: false, glass: glass)
                        #expect(found.isEmpty, "\(tag): \(found)")
                        let glassViews = slGlassViews(rig.window)
                        #expect(glassViews.count == (glass ? 1 : 0), "\(tag): \(glassViews.count) glass views")
                        for view in glassViews { #expect(slCard(of: view) == nil, "\(tag): the glass view is inside a card") }
                        #expect(!prViews(root).contains { $0 is NSVisualEffectView }, "\(tag): an NSVisualEffectView")
                    }
                }
            }
        }
    }
}

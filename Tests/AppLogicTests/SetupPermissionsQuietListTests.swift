import AppKit
import Foundation
import Testing
@testable import Sesame

private let spqNames = ["Desktop", "Documents", "Downloads", "Removable volumes"]
private let spqReasons = [
    "Files on your Desktop",
    "Files in your Documents folder",
    "Files in your Downloads folder",
    "USB drives and external disks",
]
private let spqHeading = "Permissions"
private let spqIntro = "macOS asks once, the first time Sesame reads each of these:"
private let spqNote = "Sesame never asks for Full Disk Access, camera or microphone."
private let spqReady = "Search model ready"
private let spqDamaged = "The model file was damaged, so it was deleted. Downloading it again."
private let spqNextAction = "Try again in a moment."

private enum SPQState: CaseIterable {
    case whole
    case downloading
    case damaged
    case failed
    case failedAndDamaged

    var base: SLState {
        switch self {
        case .whole: return .whole
        case .downloading: return .downloading
        case .damaged, .failedAndDamaged: return .damaged
        case .failed: return .failed
        }
    }

    var showsFailure: Bool { self == .failed || self == .failedAndDamaged }
    var showsDamage: Bool { self == .damaged || self == .failedAndDamaged }
}

@MainActor
private func spqWith(_ state: SPQState, glass: Bool, _ body: @MainActor (SLRig) async throws -> Void) async throws {
    try await slWith(state.base, glass: glass) { rig in
        if state == .failedAndDamaged {
            rig.window.model.downloadFailed(slFailedMessage)
            rig.window.refresh()
        }
        try await body(rig)
    }
}

private struct SPQParts {
    let title: NSTextField
    let intro: NSTextField
    let note: NSTextField
    let names: [NSTextField]
    let reasons: [NSTextField]
    let card: GroupCard
}

@MainActor
private func spqParts(_ root: NSView) -> SPQParts? {
    func one(_ text: String) -> NSTextField? {
        let found = swlTexts(root, text)
        return found.count == 1 ? found[0] : nil
    }
    let names = spqNames.compactMap { one($0) }
    let reasons = spqReasons.compactMap { one($0) }
    guard let title = one(spqHeading), let intro = one(spqIntro), let note = one(spqNote),
          names.count == 4, reasons.count == 4, let card = slCard(of: names[0]) else { return nil }
    return SPQParts(title: title, intro: intro, note: note, names: names, reasons: reasons, card: card)
}

@MainActor
private func spqLine(_ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
    let label = NSTextField(labelWithString: "Desktop")
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    return label.fittingSize.height
}

@MainActor
private func spqRowHeight() -> CGFloat {
    spqLine(13, .semibold) + 2 + spqLine(12, .regular)
}

@MainActor
private func spqFits(_ field: NSTextField) -> Bool {
    let width = (field.stringValue as NSString).size(withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: 12)]).width
    return field.frame.width + 0.5 >= width
}

@MainActor
private func spqHairlines(_ root: NSView, _ card: NSView) -> [NSView] {
    prViews(card)
        .filter { view in
            view !== card && plVisible(view) && !(view is NSTextField)
                && view.frame.height > 0 && view.frame.height <= 1.01 && view.frame.width >= 100
        }
        .sorted { plBox(root, $0).top < plBox(root, $1).top }
}

@MainActor
private func spqLeftOffsets(_ root: NSView, _ view: NSView, _ card: NSView) -> [CGFloat] {
    let origin = plBox(root, card).minX
    return [plBox(root, view).minX - origin, slAlignBox(root, view).minX - origin]
}

@MainActor
private func spqTopOffsets(_ root: NSView, _ view: NSView, _ card: NSView) -> [CGFloat] {
    let origin = plBox(root, card).top
    return [plBox(root, view).top - origin, slAlignBox(root, view).top - origin]
}

@MainActor
private func spqBottomOffsets(_ root: NSView, _ view: NSView, _ card: NSView) -> [CGFloat] {
    let edge = plBox(root, card).bottom
    return [edge - plBox(root, view).bottom, edge - slAlignBox(root, view).bottom]
}

@MainActor
private func spqModelBlock(_ root: NSView) -> (card: NSView, views: [NSView])? {
    guard let heading = plText(root, "The search model"), let card = slCard(of: heading) else { return nil }
    return (card, [card] + [slButton(root, "Retry")].compactMap { $0 })
}

@MainActor
private func spqElements(_ root: NSView) -> [String] {
    prViews(root).filter { $0.isAccessibilityElement() && plVisible($0) }.map { view in
        let role = view.accessibilityRole()?.rawValue ?? "none"
        let value = view.accessibilityValue().map { String(describing: $0) } ?? ""
        return "\(role)|\(view.accessibilityLabel() ?? "")|\(view.accessibilityTitle() ?? "")|\(value)"
    }.sorted()
}

private struct SPQFrame {
    let tag: String
    let box: PLBox
}

@MainActor
private func spqFrames(_ root: NSView, _ card: NSView) -> [SPQFrame] {
    var out: [SPQFrame] = []
    for view in prViews(root) where plVisible(view) && !slIsGlass(view) && !slAncestors(view).contains(where: { slIsGlass($0) }) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            out.append(SPQFrame(tag: "text|\(field.stringValue)", box: plBox(root, field)))
        } else if let button = view as? NSButton {
            out.append(SPQFrame(tag: "button|\(button.title)", box: plBox(root, button)))
        } else if view is StepDots {
            out.append(SPQFrame(tag: "dots", box: plBox(root, view)))
        } else if view === card {
            out.append(SPQFrame(tag: "card", box: plBox(root, view)))
        }
    }
    for (index, line) in spqHairlines(root, card).enumerated() {
        out.append(SPQFrame(tag: "hairline \(index)", box: plBox(root, line)))
    }
    return out
}

extension ModelDownloadTests {
    @Suite("SetupPermissionsQuietListTests", .serialized)
    struct SetupPermissionsQuietListTests {

        @MainActor
        @Test(arguments: slPaths) func fourRowsEachHaveTheirNameInThirteenSemiboldLabelColourAndTheirReasonTwoUnderItInTwelveSecondaryAsSeparateTextsSixteenInsideTheCardWithNoBulletOrTruncation(glass: Bool) async throws {
            for state in [SPQState.whole, .downloading] {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let parts = try #require(spqParts(root), "\(tag): the eight texts, the title, the intro or the note are not each shown once")
                        let card = parts.card
                        let wantedTexts = Set(spqNames + spqReasons)
                        let inCard = plTexts(card).map(\.stringValue)
                        #expect(inCard.count == 8 && Set(inCard) == wantedTexts, "\(tag): texts in the card \(inCard)")
                        #expect(!prShownTexts(root).contains { $0.contains("\u{2022}") }, "\(tag): a bullet character is shown")
                        let nameTops = parts.names.map { plBox(root, $0).top }
                        #expect(zip(nameTops, nameTops.dropFirst()).allSatisfy { $0 < $1 }, "\(tag): the names are not in order top to bottom: \(nameTops)")
                        for index in 0..<4 {
                            let name = parts.names[index]
                            let reason = parts.reasons[index]
                            let label = "\(tag) \(spqNames[index])"
                            #expect(slCard(of: name) === card && slCard(of: reason) === card, "\(label): not both in the one card")
                            #expect(slFont(name.font, size: 13, weight: .semibold), "\(label): name font \(String(describing: name.font))")
                            #expect(slColour(name.textColor, is: .labelColor), "\(label): name colour")
                            #expect(slFont(reason.font, size: 12, weight: .regular), "\(label): reason font \(String(describing: reason.font))")
                            #expect(slColour(reason.textColor, is: .secondaryLabelColor), "\(label): reason colour")
                            #expect(name.alignment == .left || name.alignment == .natural, "\(label): name alignment \(name.alignment.rawValue)")
                            #expect(reason.alignment == .left || reason.alignment == .natural, "\(label): reason alignment \(reason.alignment.rawValue)")
                            #expect(spqLeftOffsets(root, name, card).contains { abs($0 - 16) <= 1 }, "\(label): the name starts \(spqLeftOffsets(root, name, card)) from the card's left edge, wanted 16")
                            #expect(spqLeftOffsets(root, reason, card).contains { abs($0 - 16) <= 1 }, "\(label): the reason starts \(spqLeftOffsets(root, reason, card)) from the card's left edge, wanted 16")
                            let underName = swlGap(root, upper: [name], lower: [reason])
                            #expect(underName.near(2, 1), "\(label): the reason is \(underName.frame) / \(underName.aligned) pt under the name, wanted 2")
                            #expect(spqFits(name) && spqFits(reason), "\(label): a text frame is narrower than its string")
                            #expect(name.frame.height <= spqLine(13, .semibold) + 1 && reason.frame.height <= spqLine(12, .regular) + 1, "\(label): a text wraps onto a second line")
                            #expect(plBox(root, reason).maxX <= plBox(root, card).maxX && plBox(root, name).maxX <= plBox(root, card).maxX, "\(label): a text leaves the card")
                            #expect(!plBox(root, name).intersects(plBox(root, reason)), "\(label): the name and its reason overlap")
                            if index < 3 {
                                let toNext = swlGap(root, upper: [reason], lower: [parts.names[index + 1]])
                                #expect(toNext.near(16, 1), "\(label): the next name is \(toNext.frame) / \(toNext.aligned) pt under the reason, wanted 16")
                            }
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theCardSpansTwentyToFiveFortyAndIsExactlyAsTallAsSixteenPlusFourRowsPlusThreeSixteensPlusSixteenWithNoBlankBlock(glass: Bool) async throws {
            for state in [SPQState.whole, .downloading] {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let parts = try #require(spqParts(root), "\(tag): the permissions texts are not shown")
                        let card = parts.card
                        let cardBox = plBox(root, card)
                        #expect(abs(cardBox.minX - 20) <= 1 && abs(cardBox.maxX - 540) <= 1, "\(tag): the card spans \(cardBox.minX) to \(cardBox.maxX), wanted 20 to 540")
                        let row = spqRowHeight()
                        let wanted = 16 + 4 * row + 3 * 16 + 16
                        #expect(abs(cardBox.height - wanted) <= 2, "\(tag): the card is \(cardBox.height) pt high, 16 + 4 x \(row) + 48 + 16 is \(wanted)")
                        let first = spqTopOffsets(root, parts.names[0], card)
                        #expect(first.contains { abs($0 - 16) <= 1 }, "\(tag): the first name is \(first) below the card's top, wanted 16")
                        let last = spqBottomOffsets(root, parts.reasons[3], card)
                        #expect(last.contains { abs($0 - 16) <= 1 }, "\(tag): the last reason ends \(last) above the card's bottom, wanted 16")
                        let tops = parts.names.map { plBox(root, $0).top }
                        for (upper, lower) in zip(tops, tops.dropFirst()) {
                            #expect(abs((lower - upper) - (row + 16)) <= 1, "\(tag): the names are \(lower - upper) pt apart, wanted \(row + 16): no row is padded to a minimum height")
                        }
                        let ink = (parts.names + parts.reasons).map { plBox(root, $0) }
                        let spanTop = ink.map(\.top).min() ?? 0
                        let spanBottom = ink.map(\.bottom).max() ?? 0
                        #expect(abs((spanBottom - spanTop) - (4 * row + 48)) <= 2, "\(tag): the rows span \(spanBottom - spanTop) pt, wanted \(4 * row + 48)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func threeSeparatorColourHairlinesSitSixteenInsideEachSideEachCentredInTheGapBetweenTwoRowsAndNothingElseIsDrawnInTheCard(glass: Bool) async throws {
            for state in [SPQState.whole, .downloading] {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let parts = try #require(spqParts(root), "\(tag): the permissions texts are not shown")
                        let card = parts.card
                        let cardBox = plBox(root, card)
                        let lines = spqHairlines(root, card)
                        #expect(lines.count == 3, "\(tag): \(lines.count) hairlines, wanted 3")
                        for (index, line) in lines.enumerated() {
                            let label = "\(tag) hairline \(index + 1)"
                            let box = plBox(root, line)
                            #expect(box.height >= 0.5 && box.height <= 1.01, "\(label): \(box.height) pt thick")
                            #expect(abs((box.minX - cardBox.minX) - 16) <= 1 && abs((cardBox.maxX - box.maxX) - 16) <= 1,
                                    "\(label): it spans \(box.minX - cardBox.minX) from the left edge and \(cardBox.maxX - box.maxX) from the right edge, wanted 16 and 16")
                            let colour = dtRGBA(cgColor: line.layer?.backgroundColor)
                            #expect(colour != nil && dtSame(colour ?? [], dtRGBA(.separatorColor, look)), "\(label): fill \(String(describing: colour)), not the separator colour")
                            #expect(!line.isAccessibilityElement(), "\(label): it is an accessibility element")
                            guard index < 3, index < parts.reasons.count - 1 else { continue }
                            let above = swlGap(root, upper: [parts.reasons[index]], lower: [line])
                            let below = swlGap(root, upper: [line], lower: [parts.names[index + 1]])
                            #expect(above.near(8, 1), "\(label): \(above.frame) / \(above.aligned) pt under the reason above it, wanted 8")
                            #expect(below.near(8, 1), "\(label): \(below.frame) / \(below.aligned) pt above the name below it, wanted 8")
                        }
                        let lineSet = lines
                        let others = prViews(card).filter { view in
                            guard view !== card, plVisible(view), !lineSet.contains(where: { $0 === view }) else { return false }
                            return view is NSBox || view is NSButton || view is NSImageView || view is NSScrollView || view is NSProgressIndicator
                                || (view.layer?.backgroundColor?.alpha ?? 0) > 0.001 || (view.layer?.borderWidth ?? 0) > 0
                        }
                        #expect(others.isEmpty, "\(tag): another line, bezel or tile in the card: \(others.map { String(describing: type(of: $0)) })")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theBlockSitsUnderTheTitleWithTheIntroEightUnderItTheCardEightUnderTheIntroAndTheCentredNoteTwelveUnderTheCard(glass: Bool) async throws {
            for state in [SPQState.whole, .downloading] {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let parts = try #require(spqParts(root), "\(tag): the permissions texts are not shown")
                        let top = plBox(root, parts.title).top
                        #expect(top >= 19.5 && top <= 32.5, "\(tag): the title is \(top) from the top, wanted 20 to 32")
                        let steps: [(String, SWLGap, CGFloat)] = [
                            ("title to the intro", swlGap(root, upper: [parts.title], lower: [parts.intro]), 8),
                            ("intro to the card", swlGap(root, upper: [parts.intro], lower: [parts.card]), 8),
                            ("card to the note", swlGap(root, upper: [parts.card], lower: [parts.note]), 12),
                        ]
                        for (name, gap, wanted) in steps {
                            #expect(gap.near(wanted, 1), "\(tag): \(name) is \(gap.frame) / \(gap.aligned) pt, wanted \(wanted)")
                        }
                        #expect(slFont(parts.intro.font, size: 13, weight: .regular), "\(tag): intro font \(String(describing: parts.intro.font))")
                        #expect(slColour(parts.intro.textColor, is: .labelColor), "\(tag): intro colour")
                        let introMid = swlInkMid(root, parts.intro, look)
                        #expect(introMid != nil && abs((introMid ?? 0) - 280) <= 8, "\(tag): intro ink centre \(String(describing: introMid)), window centre 280")
                        #expect(slFont(parts.note.font, size: 12, weight: .regular), "\(tag): note font \(String(describing: parts.note.font))")
                        #expect(slColour(parts.note.textColor, is: .secondaryLabelColor), "\(tag): note colour")
                        let noteMid = swlInkMid(root, parts.note, look)
                        #expect(noteMid != nil && abs((noteMid ?? 0) - 280) <= 8, "\(tag): note ink centre \(String(describing: noteMid)), window centre 280")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theTitleIsAtTheSameHeightOnStepsTwoThreeAndFourWithinOnePoint(glass: Bool) async throws {
            let headings = [(SetupFlow.Step.folders, "Folders to read"), (.permissions, spqHeading), (.shortcut, "Open Sesame from anywhere")]
            for state in [SPQState.whole, .downloading] {
                try await spqWith(state, glass: glass) { rig in
                    var tops: [CGFloat] = []
                    for (step, heading) in headings {
                        await slWalk(rig, to: step)
                        let root = slLayout(rig)
                        let title = try #require(swlTexts(root, heading).first, "\(state): no title \"\(heading)\"")
                        tops.append(plBox(root, title).top)
                    }
                    #expect((tops.max() ?? 0) - (tops.min() ?? 0) <= 1, "\(state): the titles of steps 2, 3 and 4 are at \(tops), wanted one height within 1")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aWholeModelShowsNeitherTheStatusLineNorTheCardOnPermissionsAndTheNoteEndsSixteenOrMoreAboveTheFooterWhileWelcomeAloneKeepsTheStatusLine(glass: Bool) async throws {
            try await spqWith(.whole, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(entry.label) \(look)"
                        let ready = swlTexts(root, spqReady).count
                        let checks = swlImages(root, "checkmark.circle.fill").count
                        let wantsLine = entry.step == .welcome
                        #expect(ready == (wantsLine ? 1 : 0), "\(tag): \(ready) ready lines")
                        #expect(checks == (wantsLine ? 1 : 0), "\(tag): \(checks) status checks")
                        #expect(slStyle(root, "The search model") == nil, "\(tag): the model card heading is shown for a whole model")
                        #expect(!prViews(root).contains { ($0 is NSProgressIndicator || $0 is FigureView) && plVisible($0) }, "\(tag): a bar or figure is shown")
                        #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                        guard entry.step == .permissions else { continue }
                        let parts = try #require(spqParts(root), "\(tag): the permissions texts are not shown")
                        let gap = swlGap(root, upper: [parts.note], lower: swlNav(root))
                        #expect(max(gap.frame, gap.aligned) >= 15.5, "\(tag): the note ends \(gap.frame) / \(gap.aligned) pt above the footer, wanted at least 16")
                    }
                }
                let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                #expect(size.width == 560 && size.height == 600, "content size \(size)")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aModelThatIsNotWholeShowsTheCardBarFigureAndRetryOnPermissionsSixteenAboveTheFooterWithNothingOverlappingAndTheWindowStaysFiveSixtyBySixHundredEvenForFailedPlusDamaged(glass: Bool) async throws {
            for state in [SPQState.downloading, .damaged, .failed, .failedAndDamaged] {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        #expect(plText(root, spqReady) == nil, "\(tag): the ready line is shown")
                        #expect(swlImages(root, "checkmark.circle.fill").isEmpty, "\(tag): the status check is shown")
                        let heading = slStyle(root, "The search model")
                        #expect(heading != nil && slFont(heading?.font, size: 13, weight: .semibold), "\(tag): heading \(String(describing: heading?.font))")
                        let bars = prViews(root).compactMap { $0 as? NSProgressIndicator }.filter { plVisible($0) }
                        let figures = prViews(root).compactMap { $0 as? FigureView }.filter { plVisible($0) }
                        #expect(bars.count == 1 && figures.count == 1, "\(tag): \(bars.count) bars, \(figures.count) figures")
                        let retry = slButton(root, "Retry")
                        #expect((retry != nil) == state.showsFailure, "\(tag): Retry shown \(retry != nil)")
                        if state.showsFailure {
                            #expect(retry?.isEnabled == true, "\(tag): Retry is disabled")
                            #expect(plText(root, slFailedMessage) != nil && plText(root, spqNextAction) != nil, "\(tag): the failure lines are missing")
                        }
                        #expect((plText(root, spqDamaged) != nil) == state.showsDamage, "\(tag): damaged line shown \(plText(root, spqDamaged) != nil)")
                        let parts = try #require(spqParts(root), "\(tag): the permissions texts are not shown")
                        let block = try #require(spqModelBlock(root), "\(tag): no model card")
                        let blockBox = swlUnion(root, block.views) ?? plBox(root, block.card)
                        let footer = swlNav(root)
                        let toFooter = swlGap(root, upper: block.views, lower: footer)
                        #expect(toFooter.near(16, 1), "\(tag): the model block ends \(toFooter.frame) / \(toFooter.aligned) pt above the footer, wanted 16")
                        let content: [(String, NSView)] = [("title", parts.title), ("intro", parts.intro), ("card", parts.card), ("note", parts.note)]
                        for (name, view) in content {
                            #expect(!plBox(root, view).intersects(blockBox), "\(tag): the \(name) overlaps the model block")
                        }
                        let noteBottom = plBox(root, parts.note).bottom
                        #expect(noteBottom <= blockBox.top + 0.5, "\(tag): the note ends at \(noteBottom), the model block starts at \(blockBox.top): margin \(blockBox.top - noteBottom)")
                        for button in footer {
                            #expect(!plBox(root, parts.note).intersects(plBox(root, button)), "\(tag): the note overlaps \(button)")
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

        @MainActor
        @Test(arguments: slPaths) func theKeyLoopOnPermissionsIsBackAndNextPlusRetryOnlyAfterAFailureAndTheOnlyAccessibilityElementsAreTheDotsGroupTheFigureAndTheWarning(glass: Bool) async throws {
            let dots = "AXGroup||Step 3 of 4: Permissions|"
            let figure = "AXGroup||Model download|20 of 120 MB"
            let warning = "AXImage|Warning||"
            let wanted: [SPQState: [String]] = [
                .whole: [dots],
                .downloading: [figure, dots],
                .damaged: [figure, dots],
                .failed: [figure, dots, warning],
                .failedAndDamaged: [figure, dots, warning],
            ]
            for state in SPQState.allCases {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    let root = slLayout(rig)
                    let loop = slKeyLoop(rig.window).compactMap { ($0 as? NSButton)?.title }
                    let views = slKeyLoop(rig.window)
                    let wantedLoop = state.showsFailure ? ["Back", "Next", "Retry"] : ["Back", "Next"]
                    #expect(views.count == wantedLoop.count && loop.sorted() == wantedLoop, "\(state): key loop \(views.map { String(describing: type(of: $0)) }) \(loop)")
                    #expect(spqElements(root) == wanted[state], "\(state): accessibility elements \(spqElements(root)), wanted \(String(describing: wanted[state]))")
                    let parts = try #require(spqParts(root), "\(state): the permissions texts are not shown")
                    for view in prViews(parts.card) where view !== parts.card {
                        #expect(!view.isAccessibilityElement(), "\(state): \(type(of: view)) in the card is an accessibility element")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func thePaletteHoldsAccentOnlyOnTheCurrentDotAndNextAndNoGradientVisualEffectOrGlassViewIsInsideTheCard(glass: Bool) async throws {
            for state in SPQState.allCases {
                try await spqWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .permissions)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let found = swlPaletteViolations(root, look, allowError: state.showsFailure, glass: glass)
                        #expect(found.isEmpty, "\(tag): \(found)")
                        let parts = try #require(spqParts(root), "\(tag): the permissions texts are not shown")
                        let glassViews = slGlassViews(rig.window)
                        #expect(glassViews.count == (glass ? 1 : 0), "\(tag): \(glassViews.count) glass views")
                        for view in glassViews { #expect(slCard(of: view) == nil, "\(tag): the glass view is inside a card") }
                        #expect(!prViews(parts.card).contains { slIsGlass($0) }, "\(tag): a glass view is inside the permissions card")
                        #expect(!prViews(root).contains { $0 is NSVisualEffectView }, "\(tag): an NSVisualEffectView")
                        let accented = slButtons(root).filter { $0.bezelColor != nil }.map(\.title)
                        #expect(accented.allSatisfy { $0 == "Next" }, "\(tag): accent on \(accented)")
                        #expect(slButtons(root).filter { $0.keyEquivalent == "\r" }.map(\.title) == ["Next"], "\(tag): Return buttons")
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theGlassWindowAndTheFlatWindowAgreeWithinOnePointOnEveryFrameOfThePermissionsStep() async throws {
            for state in SPQState.allCases {
                try await spqWith(state, glass: false) { flat in
                    try await spqWith(state, glass: true) { glass in
                        await slWalk(flat, to: .permissions)
                        await slWalk(glass, to: .permissions)
                        for look in DTLook.allCases {
                            let flatRoot = slLayout(flat, look)
                            let glassRoot = slLayout(glass, look)
                            let tag = "\(state) \(look)"
                            let flatCard = try #require(spqParts(flatRoot), "\(tag): no flat permissions texts").card
                            let glassCard = try #require(spqParts(glassRoot), "\(tag): no glass permissions texts").card
                            let flatFrames = spqFrames(flatRoot, flatCard)
                            let glassFrames = spqFrames(glassRoot, glassCard)
                            #expect(flatFrames.count > 12, "\(tag): only \(flatFrames.count) frames")
                            #expect(flatFrames.map(\.tag) == glassFrames.map(\.tag), "\(tag): flat \(flatFrames.map(\.tag)), glass \(glassFrames.map(\.tag))")
                            for (left, right) in zip(flatFrames, glassFrames) where left.tag == right.tag {
                                let near = abs(left.box.minX - right.box.minX) <= 1 && abs(left.box.maxX - right.box.maxX) <= 1
                                    && abs(left.box.top - right.box.top) <= 1 && abs(left.box.bottom - right.box.bottom) <= 1
                                #expect(near, "\(tag): \(left.tag) flat \(left.box) glass \(right.box)")
                            }
                        }
                    }
                }
            }
        }
    }
}

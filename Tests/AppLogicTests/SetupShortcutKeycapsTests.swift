import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let skHeading = "Open Sesame from anywhere"
private let skLead = "Press these keys together."
private let skNote = "You can change the shortcut later in Settings."
private let skRunning = "Indexing is running. Watch it from the magnifier in the menu bar."
private let skReady = "Search model ready"
private let skDamaged = "The model file was damaged, so it was deleted. Downloading it again."
private let skNextAction = "Try again in a moment."
private let skGroupLabel = "Control Option Space"
private let skControl = "\u{2303}"
private let skOption = "\u{2325}"
private let skShift = "\u{21E7}"
private let skCommand = "\u{2318}"

enum SKState: CaseIterable {
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

private func skSeed(_ hotkey: String?, started: Bool) -> ((SLEnv) throws -> Settings)? {
    guard hotkey != nil || started else { return nil }
    return { _ in
        var held = Settings()
        if let hotkey { held.hotkey = hotkey }
        held.startPressed = started
        return held
    }
}

@MainActor
func skWith(_ state: SKState, glass: Bool, hotkey: String? = nil, started: Bool = false, _ body: @MainActor (SLRig) async throws -> Void) async throws {
    try await slWith(state.base, glass: glass, settings: skSeed(hotkey, started: started)) { rig in
        if state == .failedAndDamaged {
            rig.window.model.downloadFailed(slFailedMessage)
            rig.window.refresh()
        }
        try await body(rig)
    }
}

struct SKRow {
    let keys: [NSView]
    let labels: [[NSTextField]]
    let captions: [NSTextField]

    @MainActor var labelTexts: [String] { labels.map { $0.map { $0.stringValue }.joined(separator: "|") } }
    @MainActor var captionTexts: [String] { captions.map { $0.stringValue } }
}

@MainActor
func skRow(_ root: NSView) -> SKRow {
    let candidates = prViews(root).filter { view in
        plVisible(view) && !(view is NSTextField) && !(view is NSButton) && !slIsGlass(view)
            && view.layer?.cornerRadius == 8 && abs(view.frame.height - 44) <= 0.5
    }
    let keys = candidates
        .filter { candidate in !slAncestors(candidate).contains { ancestor in candidates.contains { $0 === ancestor } } }
        .sorted { plBox(root, $0).minX < plBox(root, $1).minX }
    let texts = plTexts(root)
    let labels = keys.map { key -> [NSTextField] in
        let box = plBox(root, key)
        return texts
            .filter { field in
                let inner = plBox(root, field)
                return inner.midX >= box.minX && inner.midX <= box.maxX
                    && (inner.top + inner.bottom) / 2 >= box.top && (inner.top + inner.bottom) / 2 <= box.bottom
            }
            .sorted { plBox(root, $0).minX < plBox(root, $1).minX }
    }
    let keyBottom = keys.map { plBox(root, $0).bottom }.max() ?? 0
    let captions = texts
        .filter { field in
            let box = plBox(root, field)
            return slFont(field.font, size: 11, weight: .regular) && box.top >= keyBottom - 1 && box.top <= keyBottom + 10
        }
        .sorted { plBox(root, $0).minX < plBox(root, $1).minX }
    return SKRow(keys: keys, labels: labels, captions: captions)
}

@MainActor
func skBlock(_ root: NSView, _ row: SKRow) -> PLBox? {
    swlUnion(root, row.keys + row.captions)
}

@MainActor
private func skGroup(_ root: NSView, _ label: String) -> NSView? {
    prViews(root).first { view in
        plVisible(view) && view.isAccessibilityElement() && view.accessibilityRole() == .group && view.accessibilityLabel() == label
    }
}

@MainActor
private func skWidth(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
}

@MainActor
private func skHasGradient(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if layer is CAGradientLayer { return true }
    return (layer.sublayers ?? []).contains { skHasGradient($0) }
}

private struct SKEdge {
    let width: CGFloat
    let height: CGFloat
    let bottomGap: CGFloat
    let fill: [CGFloat]?
}

@MainActor
private func skEdges(_ root: NSView, _ key: NSView) -> [SKEdge] {
    let keyBox = plBox(root, key)
    var out: [SKEdge] = []
    for view in prViews(key) where view !== key && abs(view.frame.height - 1.5) <= 0.05 {
        let box = plBox(root, view)
        out.append(SKEdge(width: box.width, height: box.height, bottomGap: keyBox.bottom - box.bottom, fill: dtRGBA(cgColor: view.layer?.backgroundColor)))
    }
    if let layer = key.layer {
        let flipped = layer.isGeometryFlipped
        let whole = layer.bounds.height
        for sub in layer.sublayers ?? [] where abs(sub.frame.height - 1.5) <= 0.05 {
            let top = flipped ? sub.frame.minY : whole - sub.frame.maxY
            out.append(SKEdge(width: sub.frame.width, height: sub.frame.height, bottomGap: whole - (top + sub.frame.height), fill: dtRGBA(cgColor: sub.backgroundColor)))
        }
    }
    return out
}

@MainActor
private func skElements(_ root: NSView) -> [String] {
    prViews(root).filter { $0.isAccessibilityElement() && plVisible($0) }.map { view in
        let role = view.accessibilityRole()?.rawValue ?? "none"
        let value = view.accessibilityValue().map { String(describing: $0) } ?? ""
        return "\(role)|\(view.accessibilityLabel() ?? "")|\(view.accessibilityTitle() ?? "")|\(value)"
    }.sorted()
}

@MainActor
private func skModelBlock(_ root: NSView) -> (card: NSView, views: [NSView])? {
    guard let heading = plText(root, "The search model"), let card = slCard(of: heading) else { return nil }
    return (card, [card] + [slButton(root, "Retry")].compactMap { $0 })
}

private struct SKFrame {
    let tag: String
    let box: PLBox
}

@MainActor
private func skFrames(_ root: NSView, _ row: SKRow) -> [SKFrame] {
    var out: [SKFrame] = []
    for view in prViews(root) where plVisible(view) && !slIsGlass(view) && !slAncestors(view).contains(where: { slIsGlass($0) }) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            out.append(SKFrame(tag: "text|\(field.stringValue)", box: plBox(root, field)))
        } else if let button = view as? NSButton {
            out.append(SKFrame(tag: "button|\(button.title)", box: plBox(root, button)))
        } else if view is StepDots {
            out.append(SKFrame(tag: "dots", box: plBox(root, view)))
        }
    }
    if let group = skGroup(root, skGroupLabel) { out.append(SKFrame(tag: "group", box: plBox(root, group))) }
    for (index, key) in row.keys.enumerated() { out.append(SKFrame(tag: "key \(index)", box: plBox(root, key))) }
    return out
}

private let skLooks: [DTLook] = [.light, .dark, .light]

extension ModelDownloadTests {
    @Suite("SetupShortcutKeycapsTests", .serialized)
    struct SetupShortcutKeycapsTests {

        @MainActor
        @Test(arguments: slPaths) func theShortcutTextsAreTheHeadingTheLeadTheKeysTheNoteThenTheModelLineAndOpenSesameWithIsInNoTextOfAnyStep(glass: Bool) async throws {
            try await skWith(.whole, glass: glass) { rig in
                for entry in slStepNames {
                    await slWalk(rig, to: entry.step)
                    let texts = rig.window.setupScreen.texts
                    #expect(!texts.contains { $0.contains("Open Sesame with") }, "\(entry.label): the old heading is in \(texts)")
                    #expect(!prShownTexts(slLayout(rig)).contains { $0.contains("Open Sesame with") }, "\(entry.label): the old heading is on screen")
                    guard entry.step == .shortcut else { continue }
                    let wanted = ["Step 4 of 4: Shortcut", skHeading, skLead, skGroupLabel, skNote, skReady]
                    #expect(texts == wanted, "whole: Shortcut texts \(texts), wanted \(wanted)")
                }
            }
            try await skWith(.downloading, glass: glass) { rig in
                await slWalk(rig, to: .shortcut)
                let texts = rig.window.setupScreen.texts
                let wanted = ["Step 4 of 4: Shortcut", skHeading, skLead, skGroupLabel, skNote]
                #expect(Array(texts.prefix(5)) == wanted, "downloading: Shortcut texts \(texts), wanted them to start with \(wanted)")
                let model = Array(texts.dropFirst(5))
                #expect(!model.isEmpty && !model.contains(skReady), "downloading: the model line is \(model)")
            }
            try await skWith(.whole, glass: glass, hotkey: "cmd+shift+k") { rig in
                await slWalk(rig, to: .shortcut)
                let texts = rig.window.setupScreen.texts
                let wanted = ["Step 4 of 4: Shortcut", skHeading, skLead, "Shift Command K", skNote, skReady]
                #expect(texts == wanted, "seeded cmd+shift+k: Shortcut texts \(texts), wanted \(wanted)")
            }
            try await skWith(.whole, glass: glass, started: true) { rig in
                await slWalk(rig, to: .shortcut)
                let texts = rig.window.setupScreen.texts
                let wanted = ["Step 4 of 4: Shortcut", skHeading, skLead, skGroupLabel, skNote, skRunning, skReady]
                #expect(texts == wanted, "started, whole: Shortcut texts \(texts), wanted \(wanted)")
            }
            try await skWith(.downloading, glass: glass, started: true) { rig in
                await slWalk(rig, to: .shortcut)
                let texts = rig.window.setupScreen.texts
                let wanted = ["Step 4 of 4: Shortcut", skHeading, skLead, skGroupLabel, skNote, skRunning]
                #expect(Array(texts.prefix(6)) == wanted, "started, downloading: Shortcut texts \(texts), wanted them to start with \(wanted)")
                let model = Array(texts.dropFirst(6))
                #expect(!model.isEmpty && !model.contains(skReady), "started, downloading: the model line is \(model)")
            }
            try await skWith(.whole, glass: glass, hotkey: "cmd+shift+k", started: true) { rig in
                await slWalk(rig, to: .shortcut)
                let texts = rig.window.setupScreen.texts
                let wanted = ["Step 4 of 4: Shortcut", skHeading, skLead, "Shift Command K", skNote, skRunning, skReady]
                #expect(texts == wanted, "started, seeded cmd+shift+k: Shortcut texts \(texts), wanted \(wanted)")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func withoutStartPressedTheShortcutHasNoRunningLineAndTheNoteIsTheLowestContentSixteenToTwentyFourAboveTheFooterAsSealedInThirteen(glass: Bool) async throws {
            try await skWith(.whole, glass: glass) { rig in
                await slWalk(rig, to: .shortcut)
                #expect(!rig.window.setupScreen.texts.contains { $0.contains("Indexing is running") }, "the running line is in the texts: \(rig.window.setupScreen.texts)")
                for look in DTLook.allCases {
                    let root = slLayout(rig, look)
                    let tag = "not started \(look)"
                    #expect(!prShownTexts(root).contains { $0.contains("Indexing is running") || $0.contains("magnifier") }, "\(tag): the running line is on screen")
                    let note = try #require(swlTexts(root, skNote).first, "\(tag): no note")
                    let toFooter = swlGap(root, upper: [note], lower: swlNav(root))
                    let inRange = (toFooter.frame >= 15.5 && toFooter.frame <= 24.5) || (toFooter.aligned >= 15.5 && toFooter.aligned <= 24.5)
                    #expect(inRange, "\(tag): the note ends \(toFooter.frame) / \(toFooter.aligned) pt above the footer, wanted 16 to 24")
                    #expect(slContentBottom(root).map { abs($0 - plBox(root, note).bottom) <= 3 } == true, "\(tag): the note is not the lowest content")
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theTitleIsTwentyFourBoldCentredAtTheHeightOfStepsTwoAndThreeAndTheLeadIsThirteenSecondaryCentredEightUnderItWithNoTextBetweenTheLeadAndTheKeys(glass: Bool) async throws {
            let headings = [(SetupFlow.Step.folders, "Folders to read"), (.permissions, "Permissions"), (.shortcut, skHeading)]
            for state in [SKState.whole, .downloading] {
                try await skWith(state, glass: glass) { rig in
                    var tops: [CGFloat] = []
                    for (step, heading) in headings {
                        await slWalk(rig, to: step)
                        let root = slLayout(rig)
                        let title = try #require(swlTexts(root, heading).first, "\(state): no title \"\(heading)\"")
                        tops.append(plBox(root, title).top)
                    }
                    #expect((tops.max() ?? 0) - (tops.min() ?? 0) <= 1, "\(state): the titles of steps 2, 3 and 4 are at \(tops), wanted one height within 1")
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let titles = swlTexts(root, skHeading)
                        let leads = swlTexts(root, skLead)
                        #expect(titles.count == 1 && leads.count == 1, "\(tag): \(titles.count) titles, \(leads.count) leads")
                        guard let title = titles.first, let lead = leads.first else { continue }
                        #expect(slFont(title.font, size: 24, weight: .bold), "\(tag): title font \(String(describing: title.font))")
                        #expect(slColour(title.textColor, is: .labelColor), "\(tag): title colour")
                        let titleMid = swlInkMid(root, title, look)
                        #expect(titleMid != nil && abs((titleMid ?? 0) - 280) <= 8, "\(tag): title ink centre \(String(describing: titleMid)), window centre 280")
                        let top = plBox(root, title).top
                        #expect(top >= 19.5 && top <= 32.5, "\(tag): the title is \(top) from the top, wanted 20 to 32")
                        #expect(slFont(lead.font, size: 13, weight: .regular), "\(tag): lead font \(String(describing: lead.font))")
                        #expect(slColour(lead.textColor, is: .secondaryLabelColor), "\(tag): lead colour")
                        let leadMid = swlInkMid(root, lead, look)
                        #expect(leadMid != nil && abs((leadMid ?? 0) - 280) <= 8, "\(tag): lead ink centre \(String(describing: leadMid)), window centre 280")
                        let gap = swlGap(root, upper: [title], lower: [lead])
                        #expect(gap.near(8, 1), "\(tag): the lead is \(gap.frame) / \(gap.aligned) pt under the title, wanted 8")
                        let row = skRow(root)
                        #expect(!row.keys.isEmpty, "\(tag): no keys")
                        let keysTop = row.keys.map { plBox(root, $0).top }.min() ?? 0
                        let leadBox = plBox(root, lead)
                        let between = plTexts(root).filter { field in
                            let box = plBox(root, field)
                            return box.top >= leadBox.bottom - 1 && box.bottom <= keysTop + 1
                        }
                        #expect(between.isEmpty, "\(tag): text between the lead and the keys: \(between.map(\.stringValue))")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theDefaultCombinationIsThreeLayerBackedKeysControlOptionSpaceRadiusEightFortyFourTallWithAHairlineBorderAndAOnePointFiveEdgeInSeparatorColourOnTheGroupFillAndRepaintingInBothLooks(glass: Bool) async throws {
            for state in [SKState.whole, .downloading] {
                try await skWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in skLooks {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let row = skRow(root)
                        try #require(row.keys.count == 3, "\(tag): \(row.keys.count) keys, wanted 3")
                        #expect(row.labels.map(\.count) == [1, 1, 1], "\(tag): texts inside the keys \(row.labelTexts)")
                        #expect(row.labelTexts == [skControl, skOption, "Space"], "\(tag): key texts \(row.labelTexts), wanted \([skControl, skOption, "Space"])")
                        var fill = dtRGBA(.labelColor, look)
                        fill[3] = 0.05
                        let separator = dtRGBA(.separatorColor, look)
                        for (index, key) in row.keys.enumerated() {
                            let name = ["Control", "Option", "Space"][index]
                            let label = "\(tag) \(name) key"
                            let box = plBox(root, key)
                            #expect(key.wantsLayer || key.layer != nil, "\(label): not layer-backed")
                            #expect(key.layer?.cornerRadius == 8, "\(label): radius \(String(describing: key.layer?.cornerRadius))")
                            #expect(abs(box.height - 44) <= 0.5, "\(label): \(box.height) pt tall")
                            let background = dtRGBA(cgColor: key.layer?.backgroundColor)
                            #expect(background != nil && dtSame(background ?? [], fill), "\(label): fill \(String(describing: background)), wanted label colour at 5% \(fill)")
                            let width = key.layer?.borderWidth ?? 0
                            #expect(width >= 0.5 && width <= 1.01, "\(label): border width \(width)")
                            let border = dtRGBA(cgColor: key.layer?.borderColor)
                            #expect(border != nil && dtSame(border ?? [], separator), "\(label): border colour \(String(describing: border)), wanted separator \(separator)")
                            let edges = skEdges(root, key)
                            #expect(edges.count == 1, "\(label): \(edges.count) 1.5 pt edges")
                            if let edge = edges.first {
                                #expect(abs(edge.height - 1.5) <= 0.05, "\(label): edge \(edge.height) pt thick")
                                #expect(edge.fill != nil && dtSame(edge.fill ?? [], separator), "\(label): edge fill \(String(describing: edge.fill)), wanted separator \(separator)")
                                #expect(abs(edge.bottomGap) <= 1, "\(label): the edge is \(edge.bottomGap) pt above the key's bottom")
                                #expect(edge.width >= box.width - 17, "\(label): the edge is \(edge.width) pt wide on a \(box.width) pt key")
                            }
                            #expect(!skHasGradient(key.layer), "\(label): a gradient layer")
                            #expect(!prViews(key).contains { $0 is NSVisualEffectView || slIsGlass($0) }, "\(label): an effect or glass view inside the key")
                            #expect(!key.isAccessibilityElement(), "\(label): the key is an accessibility element")
                            let symbolKey = index < 2
                            let text = row.labels[index].first
                            if symbolKey {
                                #expect(text.map { slFont($0.font, size: 20, weight: .regular) } == true, "\(label): symbol font \(String(describing: text?.font))")
                            } else {
                                #expect(text.map { slFont($0.font, size: 13, weight: .medium) } == true, "\(label): word font \(String(describing: text?.font))")
                            }
                            #expect(text.map { slColour($0.textColor, is: .labelColor) } == true, "\(label): text colour")
                            #expect(text?.isAccessibilityElement() == false, "\(label): the key text is an accessibility element")
                            if let text {
                                let inner = plBox(root, text)
                                #expect(inner.minX >= box.minX - 0.5 && inner.maxX <= box.maxX + 0.5, "\(label): the text \(inner.minX) to \(inner.maxX) leaves the key \(box.minX) to \(box.maxX)")
                                let ink = swlInkMid(root, text, look)
                                #expect(ink != nil && abs((ink ?? 0) - box.midX) <= 2, "\(label): the text ink centre \(String(describing: ink)), the key centre \(box.midX)")
                                #expect(((inner.top + inner.bottom) / 2 - (box.top + box.bottom) / 2).magnitude <= 4, "\(label): the text is not vertically in the key")
                            }
                        }
                        let widths = row.keys.map { plBox(root, $0).width }
                        #expect(widths[0] >= 43.5 && widths[1] >= 43.5, "\(tag): Control and Option are \(widths[0]) and \(widths[1]) wide, wanted at least 44")
                        #expect(widths[2] >= 103.5, "\(tag): Space is \(widths[2]) wide, wanted at least 104")
                        let tops = row.keys.map { plBox(root, $0).top }
                        #expect((tops.max() ?? 0) - (tops.min() ?? 0) <= 0.5, "\(tag): the keys are at tops \(tops)")
                        for (left, right) in zip(row.keys, row.keys.dropFirst()) {
                            let gap = plBox(root, right).minX - plBox(root, left).maxX
                            #expect(abs(gap - 8) <= 1, "\(tag): keys are \(gap) pt apart, wanted 8")
                        }
                        let span = try #require(swlUnion(root, row.keys), "\(tag): no keys")
                        #expect(abs(span.midX - 280) <= 8, "\(tag): the keys are centred at \(span.midX), window centre 280")
                        let glassViews = slGlassViews(rig.window)
                        #expect(glassViews.count == (glass ? 1 : 0), "\(tag): \(glassViews.count) glass views")
                        for view in glassViews { #expect(!row.keys.contains { key in prViews(key).contains { $0 === view } }, "\(tag): the glass view is inside a key") }
                        #expect(!prViews(root).contains { $0 is NSVisualEffectView }, "\(tag): an NSVisualEffectView")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func eachKeyHasItsWordUnderItInElevenRegularSecondaryFourPointsBelowCentredOnTheKeyAndNoCaptionOverlapsAnotherCaptionOrAKey(glass: Bool) async throws {
            for state in [SKState.whole, .downloading] {
                try await skWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let row = skRow(root)
                        try #require(row.keys.count == 3 && row.captions.count == 3, "\(tag): \(row.keys.count) keys, \(row.captions.count) captions")
                        #expect(row.captionTexts == ["Control", "Option", "Space"], "\(tag): captions \(row.captionTexts)")
                        for (index, caption) in row.captions.enumerated() {
                            let key = row.keys[index]
                            let label = "\(tag) \(caption.stringValue) caption"
                            #expect(slFont(caption.font, size: 11, weight: .regular), "\(label): font \(String(describing: caption.font))")
                            #expect(slColour(caption.textColor, is: .secondaryLabelColor), "\(label): colour")
                            #expect(!caption.isAccessibilityElement(), "\(label): the caption is an accessibility element")
                            let gap = swlGap(root, upper: [key], lower: [caption])
                            #expect(gap.near(4, 1), "\(label): \(gap.frame) / \(gap.aligned) pt under its key, wanted 4")
                            let captionBox = plBox(root, caption)
                            let keyBox = plBox(root, key)
                            #expect(abs(captionBox.midX - keyBox.midX) <= 1, "\(label): centre \(captionBox.midX), the key's centre \(keyBox.midX)")
                            let width = skWidth(caption.stringValue, 11, .regular)
                            #expect(captionBox.width + 0.5 >= width, "\(label): the frame is \(captionBox.width) pt wide for \(width) pt of text")
                            let ink = swlInkMid(root, caption, look)
                            #expect(ink != nil && abs((ink ?? 0) - keyBox.midX) <= 1.5, "\(label): ink centre \(String(describing: ink)), the key's centre \(keyBox.midX)")
                            for (other, otherKey) in zip(row.captions, row.keys) where other !== caption {
                                #expect(!captionBox.intersects(plBox(root, other)), "\(label): overlaps the caption \(other.stringValue)")
                                #expect(!captionBox.intersects(plBox(root, otherKey)), "\(label): overlaps the \(other.stringValue) key")
                            }
                            #expect(!captionBox.intersects(keyBox), "\(label): overlaps its own key")
                        }
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theLeadIsAboveTheKeysBlockAboveTheNoteTheBlockIsCentredBetweenThemWithAtLeastSixteenEachSideAndTheLowestOfTheNoteAndTheRunningLineSitsSixteenToTwentyFourAboveTheFooterWhenWholeOrSixteenOrMoreAboveTheModelCard(glass: Bool) async throws {
            for state in SKState.allCases {
              for started in [false, true] {
                try await skWith(state, glass: glass, started: started) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) started \(started) \(look)"
                        let lead = try #require(swlTexts(root, skLead).first, "\(tag): no lead")
                        let note = try #require(swlTexts(root, skNote).first, "\(tag): no note")
                        let row = skRow(root)
                        let block = try #require(skBlock(root, row), "\(tag): no keys block")
                        let leadBox = plBox(root, lead)
                        let noteBox = plBox(root, note)
                        #expect(leadBox.bottom <= block.top - 15.5, "\(tag): the lead ends at \(leadBox.bottom), the keys block starts at \(block.top): margin \(block.top - leadBox.bottom)")
                        #expect(block.bottom <= noteBox.top - 15.5, "\(tag): the keys block ends at \(block.bottom), the note starts at \(noteBox.top): margin \(noteBox.top - block.bottom)")
                        #expect(!leadBox.intersects(block) && !block.intersects(noteBox) && !leadBox.intersects(noteBox), "\(tag): the lead, the keys block and the note overlap")
                        let middle = (leadBox.bottom + noteBox.top) / 2
                        let blockMiddle = (block.top + block.bottom) / 2
                        #expect(abs(blockMiddle - middle) <= 2, "\(tag): the keys block centre is \(blockMiddle), the space between the lead and the note is centred at \(middle)")
                        #expect(slFont(note.font, size: 12, weight: .regular), "\(tag): note font \(String(describing: note.font))")
                        #expect(slColour(note.textColor, is: .secondaryLabelColor), "\(tag): note colour")
                        let noteMid = swlInkMid(root, note, look)
                        #expect(noteMid != nil && abs((noteMid ?? 0) - 280) <= 8, "\(tag): note ink centre \(String(describing: noteMid)), window centre 280")
                        let running = swlTexts(root, skRunning).first
                        #expect((running != nil) == started, "\(tag): the running line is shown \(running != nil)")
                        let lowest: NSTextField = running ?? note
                        if let running {
                            #expect(slFont(running.font, size: 12, weight: .regular), "\(tag): running line font \(String(describing: running.font))")
                            #expect(slColour(running.textColor, is: .secondaryLabelColor), "\(tag): running line colour")
                            #expect(plBox(root, note).bottom <= plBox(root, running).top + 0.5, "\(tag): the running line is not under the note")
                        }
                        let footer = swlNav(root)
                        let toFooter = swlGap(root, upper: [lowest], lower: footer)
                        if state == .whole {
                            let inRange = (toFooter.frame >= 15.5 && toFooter.frame <= 24.5) || (toFooter.aligned >= 15.5 && toFooter.aligned <= 24.5)
                            #expect(inRange, "\(tag): the lowest of the note and the running line ends \(toFooter.frame) / \(toFooter.aligned) pt above the footer, wanted 16 to 24")
                        } else {
                            let model = try #require(skModelBlock(root), "\(tag): no model card")
                            let modelBox = swlUnion(root, model.views) ?? plBox(root, model.card)
                            let lowestBox = plBox(root, lowest)
                            #expect(lowestBox.bottom <= modelBox.top - 15.5, "\(tag): the lowest of the note and the running line ends at \(lowestBox.bottom), the model block starts at \(modelBox.top): margin \(modelBox.top - lowestBox.bottom)")
                            #expect(!block.intersects(modelBox) && !noteBox.intersects(modelBox) && !lowestBox.intersects(modelBox) && !leadBox.intersects(modelBox), "\(tag): something overlaps the model block")
                        }
                        let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                        #expect(size.width == 560 && size.height == 600, "\(tag): content size \(size)")
                    }
                }
              }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func aWholeModelShowsNeitherTheStatusLineNorACardOnShortcutWhileWelcomeKeepsItAndAModelThatIsNotWholeShowsTheCardBarFigureAndRetrySixteenAboveTheFooter(glass: Bool) async throws {
            try await skWith(.whole, glass: glass) { rig in
                for entry in slStepNames where entry.step == .welcome || entry.step == .shortcut {
                    await slWalk(rig, to: entry.step)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(entry.label) \(look)"
                        let wantsLine = entry.step == .welcome
                        #expect(swlTexts(root, skReady).count == (wantsLine ? 1 : 0), "\(tag): ready lines \(swlTexts(root, skReady).count)")
                        #expect(swlImages(root, "checkmark.circle.fill").count == (wantsLine ? 1 : 0), "\(tag): status checks \(swlImages(root, "checkmark.circle.fill").count)")
                        #expect(slStyle(root, "The search model") == nil, "\(tag): the model card heading is shown")
                        #expect(!prViews(root).contains { ($0 is NSProgressIndicator || $0 is FigureView) && plVisible($0) }, "\(tag): a bar or figure is shown")
                        #expect(slButton(root, "Retry") == nil, "\(tag): Retry is shown")
                        guard entry.step == .shortcut else { continue }
                        #expect(!prViews(root).contains { $0 is GroupCard && plVisible($0) }, "\(tag): a card is shown")
                        let wanted = [skHeading, skLead, skControl, skOption, "Space", "Control", "Option", "Space", skNote].sorted()
                        let shown = plTexts(root).map(\.stringValue).sorted()
                        #expect(shown == wanted, "\(tag): texts on screen \(shown), wanted \(wanted)")
                        #expect(!prViews(root).contains { $0 is NSTextView && plVisible($0) }, "\(tag): a text view is shown")
                        #expect(!plTexts(root).contains { $0.isEditable }, "\(tag): an editable text field is shown")
                    }
                }
                let size = rig.window.contentRect(forFrameRect: rig.window.frame).size
                #expect(size.width == 560 && size.height == 600, "whole: content size \(size)")
            }
            for state in [SKState.downloading, .damaged, .failed, .failedAndDamaged] {
                try await skWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        #expect(plText(root, skReady) == nil, "\(tag): the ready line is shown")
                        #expect(swlImages(root, "checkmark.circle.fill").isEmpty, "\(tag): the status check is shown")
                        let heading = slStyle(root, "The search model")
                        #expect(heading != nil && slFont(heading?.font, size: 13, weight: .semibold), "\(tag): heading \(String(describing: heading?.font))")
                        let bars = prViews(root).compactMap { $0 as? NSProgressIndicator }.filter { plVisible($0) }
                        let figures = prViews(root).compactMap { $0 as? FigureView }.filter { plVisible($0) }
                        #expect(bars.count == 1 && figures.count == 1, "\(tag): \(bars.count) bars, \(figures.count) figures")
                        let cards = prViews(root).filter { $0 is GroupCard && plVisible($0) }
                        #expect(cards.count == 1, "\(tag): \(cards.count) cards, wanted only the model card")
                        let retry = slButton(root, "Retry")
                        #expect((retry != nil) == state.showsFailure, "\(tag): Retry shown \(retry != nil)")
                        if state.showsFailure {
                            #expect(retry?.isEnabled == true, "\(tag): Retry is disabled")
                            #expect(plText(root, slFailedMessage) != nil && plText(root, skNextAction) != nil, "\(tag): the failure lines are missing")
                        }
                        #expect((plText(root, skDamaged) != nil) == state.showsDamage, "\(tag): damaged line shown \(plText(root, skDamaged) != nil)")
                        let model = try #require(skModelBlock(root), "\(tag): no model card")
                        let modelBox = swlUnion(root, model.views) ?? plBox(root, model.card)
                        let footer = swlNav(root)
                        let toFooter = swlGap(root, upper: model.views, lower: footer)
                        #expect(toFooter.near(16, 1), "\(tag): the model block ends \(toFooter.frame) / \(toFooter.aligned) pt above the footer, wanted 16")
                        let row = skRow(root)
                        let block = try #require(skBlock(root, row), "\(tag): no keys block")
                        let title = try #require(swlTexts(root, skHeading).first, "\(tag): no title")
                        let lead = try #require(swlTexts(root, skLead).first, "\(tag): no lead")
                        let note = try #require(swlTexts(root, skNote).first, "\(tag): no note")
                        let content: [(String, PLBox)] = [
                            ("title", plBox(root, title)),
                            ("lead", plBox(root, lead)),
                            ("keys block", block),
                            ("note", plBox(root, note)),
                        ]
                        for (name, box) in content {
                            #expect(!box.intersects(modelBox), "\(tag): the \(name) overlaps the model block")
                            for button in footer { #expect(!box.intersects(plBox(root, button)), "\(tag): the \(name) overlaps \(button)") }
                        }
                        for (upper, lower) in zip(content, content.dropFirst()) {
                            #expect(upper.1.bottom <= lower.1.top + 0.5, "\(tag): \(upper.0) ends at \(upper.1.bottom), \(lower.0) starts at \(lower.1.top)")
                        }
                        let noteBottom = content[3].1.bottom
                        #expect(noteBottom <= modelBox.top - 15.5, "\(tag): the note ends at \(noteBottom), the model block starts at \(modelBox.top): margin \(modelBox.top - noteBottom)")
                        for button in footer {
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
        @Test(arguments: slPaths) func fiveKeysControlOptionShiftCommandSpaceStayInsideTheWindowWithTwentyOnEachSideAndANamedLongestKeyWordBracketrightKeepsTheRowUnderFiveTwentyWithoutWrapping(glass: Bool) async throws {
            let cases: [(hotkey: String, labels: [String], captions: [String], text: String)] = [
                ("ctrl+opt+shift+cmd+space", [skControl, skOption, skShift, skCommand, "Space"], ["Control", "Option", "Shift", "Command", "Space"], "Control Option Shift Command Space"),
                ("ctrl+opt+shift+cmd+bracketright", [skControl, skOption, skShift, skCommand, "Bracketright"], ["Control", "Option", "Shift", "Command", "Bracketright"], "Control Option Shift Command Bracketright"),
                ("cmd+shift+k", [skShift, skCommand, "K"], ["Shift", "Command", "K"], "Shift Command K"),
            ]
            for entry in cases {
                try await skWith(.whole, glass: glass, hotkey: entry.hotkey) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(entry.hotkey) \(look)"
                        #expect(rig.window.setupScreen.texts.contains(entry.text), "\(tag): the texts \(rig.window.setupScreen.texts) lack \(entry.text)")
                        let row = skRow(root)
                        try #require(row.keys.count == entry.labels.count, "\(tag): \(row.keys.count) keys, wanted \(entry.labels.count)")
                        #expect(row.labelTexts == entry.labels, "\(tag): key texts \(row.labelTexts), wanted \(entry.labels)")
                        #expect(row.captionTexts == entry.captions, "\(tag): captions \(row.captionTexts), wanted \(entry.captions)")
                        let block = try #require(skBlock(root, row), "\(tag): no keys block")
                        #expect(block.width <= 520.5, "\(tag): the row is \(block.width) pt wide, wanted at most 520")
                        #expect(block.minX >= 19.5 && block.maxX <= 540.5, "\(tag): the row spans \(block.minX) to \(block.maxX), wanted inside 20 to 540")
                        #expect(abs(block.midX - 280) <= 8, "\(tag): the row is centred at \(block.midX), window centre 280")
                        let tops = row.keys.map { plBox(root, $0).top }
                        #expect((tops.max() ?? 0) - (tops.min() ?? 0) <= 0.5, "\(tag): the keys do not share one top: \(tops)")
                        for (index, key) in row.keys.enumerated() {
                            let box = plBox(root, key)
                            let isSpace = entry.captions[index] == "Space"
                            #expect(box.width >= (isSpace ? 103.5 : 43.5), "\(tag): the \(entry.captions[index]) key is \(box.width) pt wide, wanted at least \(isSpace ? 104 : 44)")
                            if let text = row.labels[index].first {
                                let inner = plBox(root, text)
                                #expect(inner.minX >= box.minX - 0.5 && inner.maxX <= box.maxX + 0.5, "\(tag): the text of the \(entry.captions[index]) key leaves it")
                            }
                        }
                        if entry.captions.last == "Bracketright", let last = row.keys.last {
                            let word = skWidth("Bracketright", 13, .medium)
                            let box = plBox(root, last)
                            #expect(abs(box.width - (word + 24)) <= 2, "\(tag): the Bracketright key is \(box.width) pt wide, its word is \(word) pt and 12 each side makes \(word + 24)")
                        }
                        for (left, right) in zip(row.keys, row.keys.dropFirst()) {
                            let gap = plBox(root, right).minX - plBox(root, left).maxX
                            #expect(gap >= 7, "\(tag): keys are \(gap) pt apart, wanted at least 8")
                        }
                        for (index, caption) in row.captions.enumerated() {
                            let captionBox = plBox(root, caption)
                            #expect(abs(captionBox.midX - plBox(root, row.keys[index]).midX) <= 1, "\(tag): the \(caption.stringValue) caption is not centred on its key")
                            for (other, otherKey) in zip(row.captions, row.keys) where other !== caption {
                                #expect(!captionBox.intersects(plBox(root, other)), "\(tag): the \(caption.stringValue) caption overlaps the \(other.stringValue) caption")
                                #expect(!captionBox.intersects(plBox(root, otherKey)), "\(tag): the \(caption.stringValue) caption overlaps the \(other.stringValue) key")
                            }
                        }
                        let group = try #require(skGroup(root, entry.text), "\(tag): no accessibility group labelled \(entry.text)")
                        let groupBox = plBox(root, group)
                        #expect(groupBox.width <= 520.5 && groupBox.minX >= 19.5 && groupBox.maxX <= 540.5, "\(tag): the group is \(groupBox.minX) to \(groupBox.maxX)")
                    }
                }
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theKeycapsRowIsOneAccessibilityGroupLabelledWithTheFullShortcutWithNoChildrenAndTheKeyLoopIsBackAndFinishPlusRetryOnlyAfterAFailure(glass: Bool) async throws {
            let keys = "AXGroup|Control Option Space||"
            let dots = "AXGroup||Step 4 of 4: Shortcut|"
            let figure = "AXGroup||Model download|20 of 120 MB"
            let warning = "AXImage|Warning||"
            let wanted: [SKState: [String]] = [
                .whole: [keys, dots],
                .downloading: [keys, figure, dots],
                .damaged: [keys, figure, dots],
                .failed: [keys, figure, dots, warning],
                .failedAndDamaged: [keys, figure, dots, warning],
            ]
            for state in SKState.allCases {
                try await skWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    let root = slLayout(rig)
                    #expect(skElements(root) == wanted[state], "\(state): accessibility elements \(skElements(root)), wanted \(String(describing: wanted[state]))")
                    let loop = slKeyLoop(rig.window).compactMap { ($0 as? NSButton)?.title }
                    let views = slKeyLoop(rig.window)
                    let wantedLoop = state.showsFailure ? ["Back", "Finish", "Retry"] : ["Back", "Finish"]
                    #expect(views.count == wantedLoop.count && loop.sorted() == wantedLoop, "\(state): key loop \(views.map { String(describing: type(of: $0)) }) \(loop)")
                    let group = try #require(skGroup(root, skGroupLabel), "\(state): no group labelled \(skGroupLabel)")
                    let children = group.accessibilityChildren() ?? []
                    #expect(children.isEmpty, "\(state): the group has \(children.count) accessibility children")
                    let row = skRow(root)
                    #expect(row.keys.count == 3, "\(state): \(row.keys.count) keys")
                    for view in prViews(group) where view !== group {
                        #expect(!view.isAccessibilityElement(), "\(state): a \(type(of: view)) in the group is an accessibility element")
                    }
                    let groupBox = plBox(root, group)
                    for view in row.keys + row.captions {
                        let box = plBox(root, view)
                        #expect(box.minX >= groupBox.minX - 0.5 && box.maxX <= groupBox.maxX + 0.5 && box.top >= groupBox.top - 0.5 && box.bottom <= groupBox.bottom + 0.5,
                                "\(state): a \(type(of: view)) is outside the group frame \(groupBox)")
                        #expect(prViews(group).contains { $0 === view }, "\(state): a \(type(of: view)) is not inside the group")
                    }
                    #expect(groupBox.width <= 520.5, "\(state): the group is \(groupBox.width) pt wide")
                    #expect(abs(groupBox.midX - 280) <= 8, "\(state): the group is centred at \(groupBox.midX)")
                }
            }
            try await skWith(.whole, glass: glass, hotkey: "cmd+shift+k") { rig in
                await slWalk(rig, to: .shortcut)
                let root = slLayout(rig)
                #expect(skElements(root) == ["AXGroup|Shift Command K||", dots], "seeded: accessibility elements \(skElements(root))")
            }
        }

        @MainActor
        @Test(arguments: slPaths) func theKeysAreNeutralOnlyFinishIsAccentedFinishAloneHoldsReturnAndTheGlassViewIsTheOnlyGlass(glass: Bool) async throws {
            for state in SKState.allCases {
                try await skWith(state, glass: glass) { rig in
                    await slWalk(rig, to: .shortcut)
                    for look in DTLook.allCases {
                        let root = slLayout(rig, look)
                        let tag = "\(state) \(look)"
                        let found = swlPaletteViolations(root, look, allowError: state.showsFailure, glass: glass)
                        #expect(found.isEmpty, "\(tag): \(found)")
                        let row = skRow(root)
                        #expect(row.keys.count == 3, "\(tag): \(row.keys.count) keys")
                        let glassViews = slGlassViews(rig.window)
                        #expect(glassViews.count == (glass ? 1 : 0), "\(tag): \(glassViews.count) glass views")
                        for view in glassViews { #expect(slCard(of: view) == nil, "\(tag): the glass view is inside a card") }
                        for key in row.keys {
                            #expect(!prViews(key).contains { slIsGlass($0) }, "\(tag): a glass view is inside a key")
                            #expect(!slAncestors(key).contains { $0 is NSVisualEffectView }, "\(tag): a key is inside an effect view")
                        }
                        #expect(!prViews(root).contains { $0 is NSVisualEffectView }, "\(tag): an NSVisualEffectView")
                        let accented = slButtons(root).filter { $0.bezelColor != nil }.map(\.title)
                        #expect(accented.allSatisfy { $0 == "Finish" }, "\(tag): accent on \(accented)")
                        #expect(slButtons(root).filter { $0.keyEquivalent == "\r" }.map(\.title) == ["Finish"], "\(tag): Return buttons")
                        #expect(slButton(root, "Next") == nil, "\(tag): Next is shown on the last step")
                    }
                }
            }
        }

        @MainActor
        @Test(.enabled(if: Glass.isAvailable))
        func theGlassWindowAndTheFlatWindowAgreeWithinOnePointOnEveryFrameOfTheShortcutStep() async throws {
            for state in SKState.allCases {
                try await skWith(state, glass: false) { flat in
                    try await skWith(state, glass: true) { glass in
                        await slWalk(flat, to: .shortcut)
                        await slWalk(glass, to: .shortcut)
                        for look in DTLook.allCases {
                            let flatRoot = slLayout(flat, look)
                            let glassRoot = slLayout(glass, look)
                            let tag = "\(state) \(look)"
                            let flatFrames = skFrames(flatRoot, skRow(flatRoot))
                            let glassFrames = skFrames(glassRoot, skRow(glassRoot))
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

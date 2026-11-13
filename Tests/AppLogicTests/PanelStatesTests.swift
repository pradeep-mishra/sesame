import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private struct PSNotReady {
    let name: String
    let conditions: PLConditions
    let text: String
    let note: String?
}

private func psNotReadyCases() -> [PSNotReady] {
    var downloading = PLConditions()
    downloading.model = .downloading
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
        PSNotReady(name: "downloading", conditions: downloading, text: "The model is still downloading", note: nil),
        PSNotReady(name: "damaged", conditions: damaged, text: "The model file was damaged and is downloading again", note: nil),
        PSNotReady(name: "failed", conditions: failed, text: "The model download failed. Choose Retry model download in the Sesame menu.", note: nil),
        PSNotReady(name: "not started", conditions: notStarted, text: "Indexing has not been started", note: nil),
        PSNotReady(name: "nothing indexed", conditions: nothing, text: "Nothing is indexed yet", note: nil),
        PSNotReady(name: "other index", conditions: other, text: "Nothing is indexed yet", note: "Delete index in Settings to start over"),
    ]
}

private let psHeading = "Not ready yet"
private let psHint = "Describe what you want, or type part of a name or text."
private let psSamples = ["a dog on the beach", "the clause about pets in the lease", "where they talk about sleep"]

private func psIndexing(percent: Int) -> PLConditions {
    var conditions = PLConditions()
    if percent == 0 {
        conditions.walkDone = false
        conditions.counts = IndexCounts(done: 0, pending: [:], partial: [:])
    } else {
        conditions.counts = IndexCounts(done: 1, pending: ["photo": 2], partial: ["pdf": 1])
    }
    return conditions
}

@MainActor
private func psView(_ root: NSView, _ identifier: String) throws -> NSView {
    try #require(plFind(root, identifier), "no view with accessibility identifier \(identifier)")
}

@MainActor
private func psPane(_ root: NSView) -> NSView? {
    prViews(root).first { $0.accessibilityLabel() == "Preview" }
}

@MainActor
private func psDrawnFrames(_ pane: NSView) -> [NSView] {
    prViews(pane).filter { plVisible($0) && $0.layer?.cornerRadius == 10 }
}

@MainActor
private func psFillMatches(_ view: NSView, alpha: CGFloat, _ panel: Panel) -> [String] {
    var wrong: [String] = []
    for look in DTLook.allCases {
        _ = plLayout(panel, look: look)
        let label = dtRGBA(.labelColor, look)
        let expected = [label[0], label[1], label[2], alpha]
        let actual = dtRGBA(cgColor: view.layer?.backgroundColor)
        if actual == nil || !dtSame(actual ?? [], expected) { wrong.append("\(look): \(String(describing: actual))") }
    }
    return wrong
}

extension ModelDownloadTests {
    @Suite("PanelStatesTests", .serialized)
    struct PanelStatesTests {

        @MainActor
        @Test func theKeptIdentifiersAndLabelsAreStillInTheTree() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let table: [(String, String?)] = [
                    ("NotReadyView", "Not ready"), ("EmptyHint", "Search hint"), ("IndexingBanner", "Indexing progress"),
                    ("SearchFailedView", "Could not search just now"), ("StatusNote", nil), ("PermissionNote", nil),
                ]
                for (identifier, label) in table {
                    let view = try psView(root, identifier)
                    if let label { #expect(view.accessibilityLabel() == label, "\(identifier) label \(String(describing: view.accessibilityLabel()))") }
                }
                for identifier in ["NotReadyView", "EmptyHint", "IndexingBanner", "SearchFailedView"] {
                    let view = try psView(root, identifier)
                    #expect(view.isAccessibilityElement(), "\(identifier) is not an accessibility element")
                    #expect(view.accessibilityRole() == .group, "\(identifier) role")
                }
            }
        }

        @MainActor
        @Test func eachNotReadyTextIsShownFullWidthCentredWithTheDividerAndTheListHidden() async throws {
            for state in psNotReadyCases() {
                try await plWithPanel(state.conditions) { panel in
                    let root = plLayout(panel)
                    let view = try psView(root, "NotReadyView")
                    #expect(plVisible(view), "\(state.name): not shown")
                    let frame = plBox(root, view)
                    #expect(abs(frame.minX) <= 1 && abs(frame.width - 960) <= 1, "\(state.name): x \(frame.minX) width \(frame.width)")

                    let texts = plTexts(view).map(\.stringValue)
                    var expected = [psHeading, state.text]
                    if let note = state.note { expected.append(note) }
                    #expect(Set(texts) == Set(expected), "\(state.name): texts \(texts)")

                    let title = try #require(plText(view, psHeading), "\(state.name): no heading")
                    let body = try #require(plText(view, state.text), "\(state.name): no body")
                    #expect(title.font?.pointSize == 17, "\(state.name): heading size \(String(describing: title.font?.pointSize))")
                    #expect(abs(dtWeight(title.font ?? .systemFont(ofSize: 17)) - NSFont.Weight.semibold.rawValue) < 0.05, "\(state.name): heading weight")
                    #expect(body.font?.pointSize == 13, "\(state.name): body size \(String(describing: body.font?.pointSize))")
                    #expect(abs(dtWeight(body.font ?? .systemFont(ofSize: 13)) - NSFont.Weight.regular.rawValue) < 0.05, "\(state.name): body weight")
                    for look in DTLook.allCases {
                        #expect(dtSame(dtRGBA(title.textColor ?? .clear, look), dtRGBA(.labelColor, look)), "\(state.name): heading colour \(look)")
                        #expect(dtSame(dtRGBA(body.textColor ?? .clear, look), dtRGBA(.secondaryLabelColor, look)), "\(state.name): body colour \(look)")
                    }
                    #expect(plBox(root, body).width <= 320.5, "\(state.name): body width \(plBox(root, body).width)")
                    if let note = state.note, let field = plText(view, note) {
                        #expect(plBox(root, field).width <= 320.5, "\(state.name): note width \(plBox(root, field).width)")
                    }
                    #expect(plBox(root, title).top < plBox(root, body).top, "\(state.name): heading is not above the body")

                    let block = try #require(plBlock(root, in: view))
                    #expect(abs(block.midX - 480) <= 8, "\(state.name): block centre \(block.midX)")
                    #expect(block.top >= 209 && block.top <= 269, "\(state.name): block top \(block.top)")
                    #expect(block.minX >= 0 && block.maxX <= 960, "\(state.name): block spans \(block.minX) to \(block.maxX)")

                    #expect(plVisibleDividers(root).isEmpty, "\(state.name): a divider is still shown")
                    let list = try #require(plList(root), "\(state.name): no list in the tree")
                    #expect(!plVisible(list), "\(state.name): the list is still shown")
                    #expect(plAccessibilityImages(view).isEmpty, "\(state.name): a decorative symbol is an accessibility element")
                    #expect(!prViews(view).contains { $0 is NSProgressIndicator }, "\(state.name): a progress indicator")
                }
            }
        }

        @MainActor
        @Test func inEachNotReadyStateThePaneAndItsFrameAreHiddenSoNoBorderOrFillSitsUnderOrThroughTheText() async throws {
            for state in psNotReadyCases() {
                try await plWithPanel(state.conditions) { panel in
                    let root = plLayout(panel)
                    let pane = try #require(psPane(root), "\(state.name): no view labelled Preview")
                    #expect(!plVisible(pane), "\(state.name): the pane is still shown under the state text")
                    #expect(psDrawnFrames(pane).isEmpty, "\(state.name): \(psDrawnFrames(pane).count) frames of radius 10 are still visible in the pane")
                    let view = try psView(root, "NotReadyView")
                    let block = try #require(plBlock(root, in: view))
                    let under = prViews(root).filter { candidate in
                        guard plVisible(candidate), candidate !== view, !prViews(view).contains(where: { $0 === candidate }) else { return false }
                        let layer = candidate.layer
                        let drawsBorder = (layer?.borderWidth ?? 0) > 0
                        return drawsBorder && plBox(root, candidate).intersects(block)
                    }
                    #expect(under.isEmpty, "\(state.name): \(under.count) bordered views sit under or through the text block")
                }
            }
        }

        @MainActor
        @Test func theEmptyHintShowsNoEmptyPreviewFrameUnderIt() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let pane = try #require(psPane(root), "no view labelled Preview")
                #expect(plVisible(try psView(root, "EmptyHint")))
                #expect(psDrawnFrames(pane).isEmpty, "\(psDrawnFrames(pane).count) frames of radius 10 are visible in the pane behind the hint")
            }
        }

        @MainActor
        @Test func theSearchingStateShowsNoEmptyPreviewFrame() async throws {
            try await plWithTypingPanel { panel in
                await prType("a dog on the beach", into: panel, pauseMilliseconds: 20)
                panel.sendEvent(prKey("\r", in: panel, keyCode: 36))
                let shown = await spEventually(timeout: 8) { prShownTexts(panel.contentView!).contains("Searching") }
                #expect(shown, "never shown Searching; shown: \(prShownTexts(panel.contentView!))")
                let root = plLayout(panel)
                let pane = try #require(psPane(root), "no view labelled Preview")
                #expect(psDrawnFrames(pane).isEmpty, "\(psDrawnFrames(pane).count) frames of radius 10 are visible in the pane while it says Searching")
            }
        }

        @MainActor
        @Test func theNoMatchesStateShowsNoEmptyPreviewFrame() async throws {
            try await prWithPanel(answering: true) { panel in
                await prType("zzqx", into: panel, pauseMilliseconds: 20)
                let shown = await spEventually(timeout: 30) { prShownTexts(panel.contentView!).contains("No matches") }
                #expect(shown, "never shown No matches; shown: \(prShownTexts(panel.contentView!))")
                let root = plLayout(panel)
                let pane = try #require(psPane(root), "no view labelled Preview")
                #expect(psDrawnFrames(pane).isEmpty, "\(psDrawnFrames(pane).count) frames of radius 10 are visible in the pane while it says No matches")
            }
        }

        @MainActor
        @Test func theEmptyHintIsCentredAcrossTheWholePanelWithItsHintAndThreeStaticSamples() async throws {
            try await plWithPanel { panel in
                let root = plLayout(panel)
                let group = try psView(root, "EmptyHint")
                #expect(plVisible(group))
                #expect(group.accessibilityLabel() == "Search hint")
                let texts = plTexts(group).sorted { plBox(root, $0).top < plBox(root, $1).top }.map(\.stringValue)
                #expect(texts == [psHint] + psSamples, "texts \(texts)")
                #expect(!prViews(group).contains { $0 is NSButton }, "a sample is a button")
                #expect(plAccessibilityImages(group).isEmpty, "a decorative symbol is an accessibility element")
                let block = try #require(plBlock(root, in: group))
                #expect(abs(block.midX - 480) <= 8, "block centre \(block.midX)")
                #expect(block.top >= 209 && block.top <= 269, "block top \(block.top)")
                #expect(block.minX >= 0 && block.maxX <= 960, "block spans \(block.minX) to \(block.maxX)")
                #expect(plVisibleDividers(root).isEmpty, "\(plVisibleDividers(root).count) dividers are shown")
            }
        }

        @MainActor
        @Test func eachSampleSitsOnAChipOfRadiusSixInTheGroupFill() async throws {
            try await plWithPanel { panel in
                var root = plLayout(panel)
                let group = try psView(root, "EmptyHint")
                var chips: [(sample: String, chip: NSView)] = []
                for sample in psSamples {
                    let field = try #require(plText(group, sample), "no sample \(sample)")
                    var current: NSView? = field
                    var found: NSView?
                    while let view = current, view !== group {
                        if view.layer?.cornerRadius == 6 { found = view }
                        current = view.superview
                    }
                    let chip = try #require(found, "\(sample): no view of radius 6 holds it")
                    let outer = plBox(root, chip)
                    let inner = plBox(root, field)
                    #expect(outer.minX <= inner.minX + 0.5 && outer.maxX >= inner.maxX - 0.5 && outer.top <= inner.top + 0.5 && outer.bottom >= inner.bottom - 0.5,
                            "\(sample): the chip does not hold the text")
                    #expect(outer.width <= 400, "\(sample): chip width \(outer.width)")
                    chips.append((sample, chip))
                }
                for (sample, chip) in chips {
                    let wrong = psFillMatches(chip, alpha: 0.05, panel)
                    #expect(wrong.isEmpty, "\(sample): chip fill is not labelColor at 0.05: \(wrong)")
                }
                root = plLayout(panel)
                #expect(plBox(root, chips[0].chip).bottom <= plBox(root, chips[1].chip).top + 0.5)
                #expect(plBox(root, chips[1].chip).bottom <= plBox(root, chips[2].chip).top + 0.5)
            }
        }

        @MainActor
        @Test func theIndexingBannerIs46PointsFullWidthWithASixPercentFillAndAFourPointDeterminateBar() async throws {
            let cases: [(percent: Int, missing: String)] = [
                (25, "May be missing: Photos, PDFs"),
                (0, "May be missing: Photos, PDFs, Documents, Audio, Video"),
            ]
            for state in cases {
                try await plWithPanel(psIndexing(percent: state.percent)) { panel in
                    let root = plLayout(panel)
                    let banner = try psView(root, "IndexingBanner")
                    #expect(plVisible(banner), "\(state.percent)%: not shown")
                    let box = plBox(root, banner)
                    #expect(abs(box.height - 46) <= 0.5, "\(state.percent)%: height \(box.height)")
                    #expect(abs(box.minX) <= 1 && abs(box.width - 960) <= 1, "\(state.percent)%: x \(box.minX) width \(box.width)")
                    #expect(box.top >= 58 - 0.5 && box.top <= 60.5, "\(state.percent)%: top \(box.top)")
                    #expect(banner.accessibilityLabel() == "Indexing progress")

                    let texts = plTexts(banner).map(\.stringValue)
                    #expect(texts.contains("Still indexing (\(state.percent)%)"), "\(state.percent)%: texts \(texts)")
                    #expect(texts.contains(state.missing), "\(state.percent)%: texts \(texts)")

                    let bars = prViews(banner).compactMap { $0 as? NSProgressIndicator }
                    #expect(bars.count == 1, "\(state.percent)%: \(bars.count) bars")
                    if let bar = bars.first {
                        #expect(bar.style == .bar)
                        #expect(!bar.isIndeterminate)
                        #expect(abs(plBox(root, bar).height - 4) <= 0.5, "\(state.percent)%: bar height \(plBox(root, bar).height)")
                        let percent = (bar.doubleValue - bar.minValue) * 100 / (bar.maxValue - bar.minValue)
                        #expect(abs(percent - Double(state.percent)) <= 0.5, "\(state.percent)%: bar at \(percent)")
                        #expect(!bar.isAccessibilityElement(), "\(state.percent)%: the bar is an accessibility element")
                        let inside = plBox(root, bar)
                        #expect(inside.minX >= box.minX && inside.maxX <= box.maxX && inside.top >= box.top - 0.5 && inside.bottom <= box.bottom + 0.5)
                    }
                    #expect(plAccessibilityImages(banner).isEmpty)

                    let wrong = psFillMatches(banner, alpha: 0.06, panel)
                    #expect(wrong.isEmpty, "\(state.percent)%: banner fill is not labelColor at 0.06: \(wrong)")

                    let laid = plLayout(panel)
                    #expect(plVisibleDividers(laid).isEmpty, "\(state.percent)%: \(plVisibleDividers(laid).count) dividers are shown with the banner above the hint")
                }
            }
        }

        @MainActor
        @Test func theSearchFailedStateShowsTheWarningSymbolAndTheNextStepLineCentredInTheListRegion() async throws {
            let photos = [PRPhoto(name: "a.jpg", words: "a dog on the beach"), PRPhoto(name: "b.jpg", words: "a dog on the lawn")]
            try await prWithPanel(photos: photos) { panel in
                await prType("a quiet harbour at dawn", into: panel, pauseMilliseconds: 20)
                let failed = await spEventually(timeout: 30) { prShownTexts(panel.contentView!).contains("Could not search just now") }
                #expect(failed, "never shown the failure; shown: \(prShownTexts(panel.contentView!))")
                let root = plLayout(panel)
                let view = try psView(root, "SearchFailedView")
                #expect(plVisible(view))
                #expect(view.accessibilityLabel() == "Could not search just now")
                let texts = plTexts(view).map(\.stringValue)
                #expect(texts.contains("Could not search just now"), "texts \(texts)")
                #expect(texts.contains("Try typing again in a moment."), "texts \(texts)")
                let images = plAccessibilityImages(view)
                #expect(images.count == 1, "\(images.count) accessibility images inside the failed state")
                if let warning = images.first as? NSImageView {
                    #expect(warning.accessibilityLabel() == "Warning")
                    #expect(warning.image?.description.contains("symbol = exclamationmark.triangle") == true)
                    for look in DTLook.allCases {
                        #expect(dtSame(dtRGBA(warning.contentTintColor ?? .clear, look), dtRGBA(.systemRed, look)), "warning tint \(look)")
                    }
                } else {
                    Issue.record("the accessibility image is not an image view")
                }
                #expect(!prViews(view).contains { $0 is NSProgressIndicator })
                let block = try #require(plBlock(root, in: view))
                #expect(abs(block.midX - 192) <= 8, "block centre \(block.midX)")
                #expect(block.top >= 209 && block.top <= 269, "block top \(block.top)")
                #expect(block.maxX <= 384, "block spans \(block.minX) to \(block.maxX)")
                #expect(!prShownTexts(root).contains("Searching"), "Searching is still shown")
                #expect(!prShownTexts(root).contains("No matches"))
            }
        }
    }
}

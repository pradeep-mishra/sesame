import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step for defect 5 of the real-app batch (tasks 36 to 39): the right pane kept a stale preview
// with an empty box, and the kit counted more sample searches than the three the hint holds.
//
// Written from spec S1 ("Before any text is typed, or when the text is only spaces, the right pane shows only a quiet
// hint and a few sample searches") and S1.24 (kit pass: a hint text and 2 to 5 sample searches, nothing else), design
// section 3 ("Panel states": `EmptyHint` has "three samples") and the batch report (evidence: the empty-box pane
// still held `Preview of screenshot-terminal.png`). The product source was read only for names: `Pane`
// (`show(_:path:image:)`, `showPending(path:)`, `clear()`, `view`), `EmptyHintPanel`, `PreviewReply`, `Panel.pressEscape()`.
//
// SUITE PLACEMENT. The Panel tests set HOME, which is process-wide, so the suite is nested in `ModelDownloadTests`.
//
// WHAT THESE PIN (pure state, no window shown):
//   1. After a preview (or a pending selection) a cleared pane holds nothing of the old file: no picture, no visible
//      text, and no accessibility label that names the file (a screen reader and the kit's AX dump read labels, which
//      is how "Preview of screenshot-terminal.png" survived an empty box).
//   2. With the real `Panel`: emptying the box (Esc), and a text whose list is empty, leave the pane with nothing of
//      the file that was selected.
//   3. The empty-box hint shows its text and exactly three samples, the three the design names.
//
// NOT REACHED here (the real app only): how the kit's AX walk counts "sample searches" (7 and 11 were counted against
// 3 shown: a kit line-filter question or stale labels), and the picture of a real helper reply.

private let psName = "screenshot-terminal.png"
private let psPath = "/photos/screenshot-terminal.png"

@MainActor
private func psReply() -> PreviewReply {
    PreviewReply(ticket: 1, status: .ok, png: nil, name: psName, kind: "photo", size: 123_456, mtime: 1_700_000_000)
}

@MainActor
private func psPicture() -> NSImage {
    NSImage(size: NSSize(width: 8, height: 8))
}

/// What the pane still shows or says about `needles`, as lines, so a failure names the leftover.
@MainActor
private func psLeftovers(_ root: NSView, naming needles: [String], pictures: Bool = true) -> [String] {
    var found: [String] = []
    for text in prShownTexts(root) where needles.contains(where: { text.contains($0) }) {
        found.append("visible text \"\(text)\"")
    }
    for label in prAccessibilityLabels(root) where needles.contains(where: { label.contains($0) }) {
        found.append("accessibility label \"\(label)\"")
    }
    if pictures, !prImages(root).isEmpty { found.append("a picture is still set") }
    return found
}

extension ModelDownloadTests {
    @Suite("PaneStaleTests", .serialized)
    struct PaneStaleTests {

        // MARK: the pane itself

        @MainActor
        @Test func aPaneThatShowedAPreviewHoldsNothingOfThatFileOnceCleared() {
            let pane = Pane()
            pane.show(psReply(), path: psPath, image: psPicture())

            // the walk sees what the pane shows (so an empty result below means something)
            #expect(prShownTexts(pane.view).contains(psName), "shown: \(prShownTexts(pane.view))")
            #expect(!prImages(pane.view).isEmpty)

            pane.clear()

            let left = psLeftovers(pane.view, naming: [psName, psPath])
            #expect(left.isEmpty, "the cleared pane still holds the old file: \(left)")
        }

        @MainActor
        @Test func aPaneThatWasWaitingForAPreviewHoldsNothingOfThatFileOnceCleared() {
            let pane = Pane()
            pane.showPending(path: psPath)
            #expect(prShownTexts(pane.view).contains(psName), "shown: \(prShownTexts(pane.view))")

            pane.clear()

            let left = psLeftovers(pane.view, naming: [psName, psPath])
            #expect(left.isEmpty, "the cleared pane still holds the old file: \(left)")
        }

        @MainActor
        @Test func aSecondFileReplacesTheFirstCompletelyNotJustItsText() {
            let pane = Pane()
            pane.show(psReply(), path: psPath, image: psPicture())
            let other = PreviewReply(ticket: 2, status: .ok, png: nil, name: "snow-cat.png", kind: "photo",
                                     size: 2_048, mtime: 1_700_100_000)
            pane.show(other, path: "/photos/snow-cat.png", image: psPicture())

            let left = psLeftovers(pane.view, naming: [psName, psPath])
            #expect(left.filter { !$0.hasPrefix("a picture") }.isEmpty, "the first file is still named: \(left)")
            #expect(prShownTexts(pane.view).contains("snow-cat.png"))
        }

        // MARK: the list tells its owner when nothing is selected any more (the owner clears the pane on it)

        @MainActor
        @Test(arguments: ["empty", "searching", "noMatches"])
        func aListThatEmptiesTellsItsOwnerThatNothingIsSelectedAnymore(_ emptied: String) {
            let list = ResultList()
            var told: [String] = []
            list.onSelect = { told.append($0?.path ?? "nothing") }

            list.show(.rows([SearchHit(path: "/photos/a.jpg", passageID: 1), SearchHit(path: "/photos/b.jpg", passageID: 2)]))
            #expect(told.last == "/photos/a.jpg", "the first row of a new list is selected and reported: \(told)")

            switch emptied {
            case "empty": list.show(.empty)
            case "searching": list.show(.searching)
            default: list.show(.noMatches)
            }
            #expect(list.hits.isEmpty)
            #expect(told.last == "nothing", "the list emptied (\(emptied)) and its owner was never told: \(told)")
        }

        // MARK: the real panel: emptying the box, and a list that is empty

        @MainActor
        @Test func escapeThatEmptiesTheBoxLeavesNoFileInThePane() async throws {
            let photos = [PRPhoto(name: "a.jpg", words: "a dog on the beach"), PRPhoto(name: "b.jpg", words: "a dog on the lawn")]
            try await prWithPanel(photos: photos) { panel in
                await prType("a dog", into: panel, pauseMilliseconds: 40)
                let selected = await spEventually { prShownTexts(panel.contentView!).contains("/photos/a.jpg") }
                #expect(selected, "the first row never reached the pane: \(prShownTexts(panel.contentView!))")

                panel.pressEscape()
                await spWait(0.3)

                #expect(panel.queryBox.text == "")
                let left = psLeftovers(panel.contentView!, naming: ["a.jpg", "b.jpg", "/photos/"], pictures: false)
                #expect(left.isEmpty, "the pane or list still holds a file after Esc emptied the box: \(left)")
            }
        }

        @MainActor
        @Test func aTextWhoseListIsEmptyLeavesNoFileInThePane() async throws {
            let photos = [PRPhoto(name: "a.jpg", words: "a dog on the beach"), PRPhoto(name: "b.jpg", words: "a dog on the lawn")]
            try await prWithPanel(photos: photos) { panel in
                await prType("a dog", into: panel, pauseMilliseconds: 40)
                let selected = await spEventually { prShownTexts(panel.contentView!).contains("/photos/a.jpg") }
                #expect(selected, "the first row never reached the pane: \(prShownTexts(panel.contentView!))")

                // no stored word holds this, so the keyword list is empty and the ranked list is not in: no rows
                await prType(" qqzzxx", into: panel, pauseMilliseconds: 40)
                await spWait(0.3)

                let left = psLeftovers(panel.contentView!, naming: ["a.jpg", "b.jpg", "/photos/"], pictures: false)
                #expect(left.isEmpty, "the pane or list still holds a file while the list is empty: \(left)")
            }
        }

        // MARK: the empty-box hint holds exactly three samples

        private static let designSamples = [
            "a dog on the beach", "the clause about pets in the lease", "where they talk about sleep",
        ]

        private static func readyInputs(typed: String) -> PanelInputs {
            PanelInputs(
                model: .whole, startPressed: true, indexDeleted: false, walkDoneAt: Date(timeIntervalSince1970: 1),
                counts: IndexCounts(done: 40, pending: [:], partial: [:]), vectorSourceOK: true,
                kindsOn: ["photo"], typed: typed, rankedCount: nil)
        }

        @Test(arguments: ["", "     "])
        func theEmptyBoxHintHoldsExactlyTheThreeSamplesTheDesignNames(_ typed: String) throws {
            guard case let .emptyHint(hint) = PanelState.evaluate(Self.readyInputs(typed: typed)) else {
                Issue.record("\"\(typed)\" did not give the empty hint")
                return
            }
            #expect(hint.samples == Self.designSamples, "samples: \(hint.samples)")
            #expect(hint.samples.count == 3)
        }

        @MainActor
        @Test func theHintViewShowsItsTextAndExactlyThreeSamplesAndNothingElse() throws {
            guard case let .emptyHint(hint) = PanelState.evaluate(Self.readyInputs(typed: "")) else {
                Issue.record("the empty box did not give the empty hint")
                return
            }
            let view = EmptyHintPanel()
            view.show(hint)
            let shown = prShownTexts(view)
            #expect(shown == [hint.text] + Self.designSamples, "the hint view shows \(shown)")
            #expect(!view.isHidden)

            view.show(nil)
            #expect(view.isHidden, "the hint stays on screen when it has nothing to say")
        }

        @MainActor
        @Test func theHintViewKeepsNoOldSampleWhenShownAgain() throws {
            guard case let .emptyHint(hint) = PanelState.evaluate(Self.readyInputs(typed: "  ")) else {
                Issue.record("a box of spaces did not give the empty hint")
                return
            }
            let view = EmptyHintPanel()
            view.show(hint)
            view.show(nil)
            view.show(hint)
            #expect(prShownTexts(view) == [hint.text] + Self.designSamples, "shown: \(prShownTexts(view))")
        }
    }
}

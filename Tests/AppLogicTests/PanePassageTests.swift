import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-4-t7, tester step. Written from the t7 entry of plan-4-tasks.md (Tests, the last two sentences before Red), the Conventions of
// plan-4-tasks.md, Decision D7, design sections 3 and 5 and the spec's S3 only; no product source is read. The names used were found in
// Tests/: `Pane()`, `show(_:path:image:)`, `showPending(path:)`, `clear()` and `view` (PaneStaleTests), the pane walkers `prViews`,
// `prAccessibilityLabels` (PanelRig.swift) and `PreviewReply`'s initialiser with the five new fields of the entry, `page`, `pageCount`,
// `locator`, `text` and `marks`, in that order after `mtime` (the order the entry lists them; each has a default, so a photo reply is built
// as PaneStaleTests builds it).
//
// What these pin, all pure state (no window is shown):
//   1. After `show` of a PDF reply the pane shows the locator, "Page 7 of 12".
//   2. After `show` of a document reply the pane shows the passage text, and the characters in the marked ranges (flat start, end
//      UTF-16 offsets into `text`, as the reply holds them) carry a background colour in the text view, and no other character of the
//      passage does.
//   3. After `clear()`, after `showPending(path:)` and after a reply of another kind replaces them, nothing of the earlier selection is
//      left: no locator, no passage text and no mark colour on the new text. A person (or the kit's AX dump) reads visible text and
//      accessibility labels, so those are what the leftovers are read from, as PaneStaleTests does (the plan 1 stale-pane lesson).
//
// SHAPES THIS FILE PINS (the entry names the behaviour, not the views; each is one place to edit, the walkers `ppTexts` and `ppAttributed`):
//   - The passage is shown in a text view (an `NSTextView`) or an attributed text field, found by walking the pane's views; "shown"
//     means not hidden and with no hidden parent. The text may sit inside a longer shown string (a prefix or a heading in front of it):
//     the marks are applied from where the passage starts.
//   - A mark's background colour is the `NSAttributedString.Key.backgroundColor` attribute on the text view's text storage (or on an
//     attributed text field's string); temporary layout attributes are not read.
//   - `show(_:path:image:)` takes `image: nil` for a reply that has no picture (a document), as `image` of the photo case takes a
//     picture [guess: if `image` is not optional, the one place to edit is `ppShowDocument`].
//   - A PDF reply's locator is shown as text that contains "Page 7 of 12".

// MARK: replies

private let ppPdfName = "lease-2024.pdf"
private let ppPdfPath = "/docs/lease-2024.pdf"
private let ppLocator = "Page 7 of 12"
private let ppDocName = "tenancy.docx"
private let ppDocPath = "/docs/tenancy.docx"
private let ppPassage = "The tenant may keep one cat with written landlord consent, and no other animal."
private let ppOtherPassage = "Quarterly figures were reviewed on Thursday and the budget was approved without change."

/// The flat (start, end) UTF-16 offsets of the first occurrence of each of `words` in `text`, written by the test from the text.
private func ppMarks(_ words: [String], in text: String) -> [Int] {
    let whole = text as NSString
    var flat: [Int] = []
    for word in words {
        let range = whole.range(of: word)
        precondition(range.location != NSNotFound, "the test's own word \(word) is not in its own text")
        flat += [range.location, range.location + range.length]
    }
    return flat
}

private func ppPdfReply() -> PreviewReply {
    PreviewReply(ticket: 1, status: .ok, png: "/var/folders/ab/cdef/T/Sesame-4242/p1.png", name: ppPdfName, kind: "pdf",
                 size: 48_213, mtime: 1_700_000_000, page: 7, pageCount: 12, locator: ppLocator)
}

private func ppDocReply(text: String = ppPassage, words: [String] = ["written", "landlord", "consent"], ticket: Int = 2) -> PreviewReply {
    PreviewReply(ticket: ticket, status: .ok, png: nil, name: ppDocName, kind: "doc", size: 9_001, mtime: 1_700_000_500,
                 text: text, marks: ppMarks(words, in: text))
}

private func ppPhotoReply() -> PreviewReply {
    PreviewReply(ticket: 3, status: .ok, png: nil, name: "screenshot-terminal.png", kind: "photo", size: 123_456, mtime: 1_700_100_000)
}

@MainActor
private func ppPicture() -> NSImage {
    NSImage(size: NSSize(width: 8, height: 8))
}

@MainActor
private func ppShowPdf(_ pane: Pane) {
    pane.show(ppPdfReply(), path: ppPdfPath, image: ppPicture())
}

@MainActor
private func ppShowDocument(_ pane: Pane, _ reply: PreviewReply) {
    pane.show(reply, path: ppDocPath, image: nil)
}

@MainActor
private func ppShowPhoto(_ pane: Pane) {
    pane.show(ppPhotoReply(), path: "/photos/screenshot-terminal.png", image: ppPicture())
}

// MARK: reading the pane

@MainActor
private func ppIsShown(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

/// The text of every text field and text view a person could see: not hidden, no hidden parent, not empty.
@MainActor
private func ppTexts(_ root: NSView) -> [String] {
    prViews(root).compactMap { view in
        guard ppIsShown(view) else { return nil }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { return field.stringValue }
        if let textView = view as? NSTextView, !textView.string.isEmpty { return textView.string }
        return nil
    }
}

/// The attributed text of every shown text view and text field.
@MainActor
private func ppAttributed(_ root: NSView) -> [NSAttributedString] {
    prViews(root).compactMap { view in
        guard ppIsShown(view) else { return nil }
        if let textView = view as? NSTextView, textView.string.isEmpty == false { return textView.textStorage }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { return field.attributedStringValue }
        return nil
    }
}

/// What the pane still shows or says about `needles`, as lines, so a failure names the leftover.
@MainActor
private func ppLeftovers(_ root: NSView, naming needles: [String]) -> [String] {
    var found: [String] = []
    for text in ppTexts(root) where needles.contains(where: { text.contains($0) }) {
        found.append("visible text \"\(text)\"")
    }
    for label in prAccessibilityLabels(root) where needles.contains(where: { label.contains($0) }) {
        found.append("accessibility label \"\(label)\"")
    }
    return found
}

/// What is wrong with the background colours of the passage `text` as the pane shows it: a character in a marked range with none, or
/// one outside every marked range with one. An empty list means the colour is on exactly the marked characters.
@MainActor
private func ppBackgroundProblems(_ root: NSView, text: String, marks: [Int]) -> [String] {
    let whole = text as NSString
    for shown in ppAttributed(root) {
        let place = (shown.string as NSString).range(of: text)
        guard place.location != NSNotFound else { continue }
        var problems: [String] = []
        for index in 0..<whole.length {
            var marked = false
            var pair = 0
            while pair + 1 < marks.count {
                if index >= marks[pair] && index < marks[pair + 1] { marked = true }
                pair += 2
            }
            let coloured = shown.attribute(.backgroundColor, at: place.location + index, effectiveRange: nil) != nil
            if marked != coloured, problems.count < 6 {
                let character = whole.substring(with: NSRange(location: index, length: 1))
                problems.append("offset \(index) `\(character)` is \(marked ? "marked but has no background colour" : "not marked but has a background colour")")
            }
        }
        return problems
    }
    return ["no shown text view or text field holds the passage `\(text)`; shown: \(ppTexts(root))"]
}

// MARK: the tests

@Suite("PanePassageTests", .serialized)
struct PanePassageTests {

    // MARK: a PDF reply

    @MainActor
    @Test func aPdfReplyShowsItsLocatorPageSevenOfTwelve() {
        let pane = Pane()
        ppShowPdf(pane)
        let shown = ppTexts(pane.view)
        #expect(shown.contains { $0.contains(ppLocator) }, "the pane shows \(shown), expected a text holding `\(ppLocator)`")
        #expect(!prImages(pane.view).isEmpty, "the page picture is not set")
    }

    // MARK: a document reply

    @MainActor
    @Test func aDocumentReplyShowsThePassageAndOnlyTheMarkedWordsCarryABackgroundColour() {
        let pane = Pane()
        let reply = ppDocReply()
        ppShowDocument(pane, reply)
        let shown = ppTexts(pane.view)
        #expect(shown.contains { $0.contains(ppPassage) }, "the pane shows \(shown), expected a text holding the passage")
        let problems = ppBackgroundProblems(pane.view, text: ppPassage, marks: reply.marks)
        #expect(problems.isEmpty, "the marked ranges \(reply.marks) are not the coloured ones: \(problems)")
    }

    @MainActor
    @Test func aDocumentReplyWithNoMarksShowsThePassageWithNoBackgroundColourAnywhere() {
        let pane = Pane()
        let reply = PreviewReply(ticket: 4, status: .ok, png: nil, name: ppDocName, kind: "doc", size: 9_001, mtime: 1_700_000_500,
                                 text: ppPassage, marks: [])
        ppShowDocument(pane, reply)
        let problems = ppBackgroundProblems(pane.view, text: ppPassage, marks: [])
        #expect(problems.isEmpty, "a passage with no marks carries a background colour: \(problems)")
    }

    // MARK: nothing of the earlier selection stays (plan 1's stale-pane lesson)

    @MainActor
    @Test func aClearedPaneHoldsNoLocatorAfterAPdfReply() {
        let pane = Pane()
        ppShowPdf(pane)
        #expect(ppTexts(pane.view).contains { $0.contains(ppLocator) }, "setup: the locator is not shown before clear")
        pane.clear()
        let left = ppLeftovers(pane.view, naming: [ppLocator, ppPdfName, ppPdfPath])
        #expect(left.isEmpty, "the cleared pane still holds the PDF: \(left)")
        #expect(prImages(pane.view).isEmpty, "a picture is still set after clear")
    }

    @MainActor
    @Test func aClearedPaneHoldsNoPassageAndNoMarkColourAfterADocumentReply() {
        let pane = Pane()
        ppShowDocument(pane, ppDocReply())
        #expect(ppTexts(pane.view).contains { $0.contains(ppPassage) }, "setup: the passage is not shown before clear")
        pane.clear()
        let left = ppLeftovers(pane.view, naming: [ppPassage, "written landlord", ppDocName, ppDocPath])
        #expect(left.isEmpty, "the cleared pane still holds the document: \(left)")
    }

    @MainActor
    @Test func aPaneWaitingForAnotherSelectionHoldsNoLocatorAndNoPassage() {
        let pane = Pane()
        ppShowPdf(pane)
        #expect(ppTexts(pane.view).contains { $0.contains(ppLocator) }, "setup: the locator is not shown before the pane waits")
        pane.showPending(path: "/photos/next.jpg")
        #expect(ppLeftovers(pane.view, naming: [ppLocator, ppPdfName]).isEmpty, "the waiting pane still holds the PDF: \(ppLeftovers(pane.view, naming: [ppLocator, ppPdfName]))")

        ppShowDocument(pane, ppDocReply())
        #expect(ppTexts(pane.view).contains { $0.contains(ppPassage) }, "setup: the passage is not shown before the pane waits")
        pane.showPending(path: "/photos/next.jpg")
        let left = ppLeftovers(pane.view, naming: [ppPassage, ppDocName])
        #expect(left.isEmpty, "the waiting pane still holds the document: \(left)")
    }

    @MainActor
    @Test func aPhotoReplyThatReplacesAPdfLeavesNoLocator() {
        let pane = Pane()
        ppShowPdf(pane)
        #expect(ppTexts(pane.view).contains { $0.contains(ppLocator) }, "setup: the locator is not shown before the photo replaces it")
        ppShowPhoto(pane)
        let left = ppLeftovers(pane.view, naming: [ppLocator, ppPdfName, ppPdfPath, "Page 7"])
        #expect(left.isEmpty, "the photo's pane still holds the PDF's locator or name: \(left)")
        #expect(ppTexts(pane.view).contains("screenshot-terminal.png"), "the photo is not shown: \(ppTexts(pane.view))")
    }

    @MainActor
    @Test func aPhotoReplyThatReplacesADocumentLeavesNoPassageAndNoMarkColour() {
        let pane = Pane()
        ppShowDocument(pane, ppDocReply())
        #expect(ppTexts(pane.view).contains { $0.contains(ppPassage) }, "setup: the passage is not shown before the photo replaces it")
        ppShowPhoto(pane)
        let left = ppLeftovers(pane.view, naming: [ppPassage, "written landlord", ppDocName, ppDocPath])
        #expect(left.isEmpty, "the photo's pane still holds the document: \(left)")
        #expect(ppAttributed(pane.view).allSatisfy { shown in
            var coloured = false
            shown.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: shown.length)) { value, _, _ in
                if value != nil { coloured = true }
            }
            return !coloured
        }, "a background colour of the earlier marks is still on a shown text")
    }

    @MainActor
    @Test func aPdfReplyThatReplacesADocumentLeavesNoPassageAndADocumentReplyThatReplacesAPdfLeavesNoLocator() {
        let pane = Pane()
        ppShowDocument(pane, ppDocReply())
        ppShowPdf(pane)
        let afterPdf = ppLeftovers(pane.view, naming: [ppPassage, ppDocName, ppDocPath])
        #expect(afterPdf.isEmpty, "the PDF's pane still holds the document: \(afterPdf)")
        #expect(ppTexts(pane.view).contains { $0.contains(ppLocator) }, "the PDF's locator is not shown: \(ppTexts(pane.view))")

        ppShowDocument(pane, ppDocReply())
        let afterDocument = ppLeftovers(pane.view, naming: [ppLocator, ppPdfName, ppPdfPath])
        #expect(afterDocument.isEmpty, "the document's pane still holds the PDF: \(afterDocument)")
        #expect(ppTexts(pane.view).contains { $0.contains(ppPassage) }, "the document's passage is not shown: \(ppTexts(pane.view))")
    }

    @MainActor
    @Test func aDocumentReplyShowsOnePassageTextAreaAsWideAsItsClipViewAndOneOpensInText() {
        let pane = Pane()
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        ppShowDocument(pane, ppDocReply())
        pane.view.layoutSubtreeIfNeeded()
        let holders = prViews(pane.view).compactMap { $0 as? NSTextView }.filter { ppIsShown($0) && $0.string.contains(ppPassage) }
        #expect(holders.count == 1, "text views holding the passage: \(holders.count)")
        let holder = holders.first
        #expect(holder?.accessibilityRole() == .textArea, "role \(String(describing: holder?.accessibilityRole()))")
        #expect(holder?.accessibilityLabel() == "Passage", "label \(String(describing: holder?.accessibilityLabel()))")
        if let holder, let clip = holder.enclosingScrollView?.contentView.bounds.width {
            #expect(abs(holder.frame.width - clip) <= 1, "the passage view is \(holder.frame.width) wide, the clip view \(clip)")
        } else {
            Issue.record("the passage view is not inside a scroll view")
        }
        let opens = ppTexts(pane.view).filter { $0.hasPrefix("Opens in") }
        #expect(opens.count == 1, "the pane says \(opens), expected one Opens in text")
    }

    @MainActor
    @Test func aHandBuiltCodeReplyWithALineAndAFirstLineDrawsNoLineNumbersAndNoMatchLine() {
        let pane = Pane()
        let text = "func a() {\n    return\n}"
        let reply = PreviewReply(ticket: 6, status: .ok, png: nil, name: "retry.swift", kind: "code", size: 412, mtime: 1_700_000_000,
                                 locator: "Lines 12 to 14", text: text, marks: [11, 21], line: 13, firstLine: 12)
        pane.show(reply, path: "/code/retry.swift", image: nil)
        let labels = prAccessibilityLabels(pane.view).map { $0.lowercased() }
        #expect(!labels.contains { $0.contains("line numbers") || $0.contains("match line") }, "labels: \(labels)")
        let gutterLike = prViews(pane.view).compactMap { $0 as? NSTextView }.filter { ppIsShown($0) && Set($0.string.filter { !$0.isWhitespace }).isSubset(of: Set("0123456789")) && !$0.string.isEmpty }
        #expect(gutterLike.isEmpty, "a text view of line numbers is shown: \(gutterLike.map(\.string))")
    }

    @MainActor
    @Test func aSecondDocumentReplacesTheFirstPassageAndItsMarksCompletely() {
        let pane = Pane()
        ppShowDocument(pane, ppDocReply())
        let second = ppDocReply(text: ppOtherPassage, words: ["budget", "approved"], ticket: 5)
        ppShowDocument(pane, second)

        let left = ppLeftovers(pane.view, naming: [ppPassage, "written landlord"])
        #expect(left.isEmpty, "the second document's pane still holds the first passage: \(left)")
        #expect(ppTexts(pane.view).contains { $0.contains(ppOtherPassage) }, "the second passage is not shown: \(ppTexts(pane.view))")
        let problems = ppBackgroundProblems(pane.view, text: ppOtherPassage, marks: second.marks)
        #expect(problems.isEmpty, "the second passage's marks are not the coloured ones (an old mark colour may have stayed): \(problems)")
    }
}

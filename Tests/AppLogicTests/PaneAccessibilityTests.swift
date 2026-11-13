import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

private let paPath = "/code/retry.swift"
private let paStretch = ["/// Calls the operation again", "func retryWithBackoff(attempts: Int) throws {", "    var delay = 1.5", "    return", "}"]
private let paText = paStretch.joined(separator: "\n")

private func paCode(firstLine: Int = 12, matchIndex: Int = 1, text: String = paText, ticket: Int = 1) -> PreviewReply {
    let lines = text.components(separatedBy: "\n")
    var start = 0
    for number in 0..<matchIndex { start += lines[number].utf16.count + 1 }
    return PreviewReply(ticket: ticket, status: .ok, png: nil, name: "retry.swift", kind: "code", size: 412, mtime: 1_700_000_000,
                        locator: "Lines \(firstLine) to \(firstLine + lines.count - 1)", text: text,
                        marks: [start, start + lines[matchIndex].utf16.count], line: firstLine + matchIndex, firstLine: firstLine)
}

private let paDocText = String(repeating: "The tenant may keep one cat with written landlord consent. ", count: 24)

private func paDoc(ticket: Int = 2) -> PreviewReply {
    PreviewReply(ticket: ticket, status: .ok, png: nil, name: "tenancy.docx", kind: "doc", size: 9_001, mtime: 1_700_000_500,
                 text: paDocText, marks: [4, 10])
}

private func paPhoto() -> PreviewReply {
    PreviewReply(ticket: 3, status: .ok, png: nil, name: "screenshot-terminal.png", kind: "photo", size: 123_456, mtime: 1_700_100_000)
}

@MainActor
private func paPane(width: CGFloat = 400, inWindow: Bool = false) -> (pane: Pane, keep: NSWindow?) {
    let pane = Pane()
    var window: NSWindow?
    if inWindow {
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        made.contentView = pane.view
        window = made
    } else {
        pane.view.frame = NSRect(x: 0, y: 0, width: width, height: 500)
    }
    pane.view.layoutSubtreeIfNeeded()
    return (pane, window)
}

@MainActor
private func paShown(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

@MainActor
private func paTextViews(_ pane: Pane) -> [NSTextView] {
    prViews(pane.view).compactMap { view in
        guard let textView = view as? NSTextView, paShown(textView), !textView.string.isEmpty else { return nil }
        return textView
    }
}

@MainActor
private func paMatchLabels(_ pane: Pane) -> [String] {
    prViews(pane.view).compactMap { view in
        guard paShown(view), let label = view.accessibilityLabel(), label.lowercased().contains("match line") else { return nil }
        return label
    }
}

@MainActor
private func paGutters(_ pane: Pane) -> [String] {
    prViews(pane.view).compactMap { view in
        guard paShown(view), let label = view.accessibilityLabel(), label.lowercased().contains("line numbers") else { return nil }
        return label
    }
}

@Suite("PaneAccessibilityTests", .serialized)
struct PaneAccessibilityTests {

    @MainActor
    @Test(arguments: [(12, 0), (12, 2), (12, 4), (247, 1), (1, 0), (10_000, 3)])
    func aCodeReplyDrawsNoGutterAndNoMatchLineWhicheverLineItHolds(_ first: Int, _ index: Int) {
        let (pane, _) = paPane()
        pane.show(paCode(firstLine: first, matchIndex: index), path: paPath, image: nil)
        #expect(paGutters(pane).isEmpty, "firstLine \(first), match index \(index): views labelled Line numbers: \(paGutters(pane))")
        #expect(paMatchLabels(pane).isEmpty, "firstLine \(first), match index \(index): match-line labels: \(paMatchLabels(pane))")
    }

    @MainActor
    @Test func aCodeReplyWithBlankLinesAndASecondOneDrawNoGutterAndNoMatchLine() {
        let (pane, _) = paPane()
        pane.show(paCode(firstLine: 7, matchIndex: 2, text: "func a() {\n\n    return\n\n}"), path: paPath, image: nil)
        #expect(paGutters(pane).isEmpty && paMatchLabels(pane).isEmpty, "gutters \(paGutters(pane)), match lines \(paMatchLabels(pane))")
        pane.show(paCode(firstLine: 100, matchIndex: 2, ticket: 2), path: paPath, image: nil)
        #expect(paGutters(pane).isEmpty && paMatchLabels(pane).isEmpty, "second reply: gutters \(paGutters(pane)), match lines \(paMatchLabels(pane))")
    }

    @MainActor
    @Test func noCodeReplyLeavesAGutterOrAMatchLineWhateverTheSequenceOfReplies() {
        let (pane, _) = paPane()
        pane.show(paCode(), path: paPath, image: nil)
        #expect(paMatchLabels(pane).isEmpty && paGutters(pane).isEmpty, "after a code reply: \(paMatchLabels(pane)) \(paGutters(pane))")
        pane.clear()
        #expect(paMatchLabels(pane).isEmpty && paGutters(pane).isEmpty, "after clear(): \(paMatchLabels(pane)) \(paGutters(pane))")
        pane.show(paCode(ticket: 2), path: paPath, image: nil)
        pane.showPending(path: "/code/next.swift")
        #expect(paMatchLabels(pane).isEmpty && paGutters(pane).isEmpty, "after showPending: \(paMatchLabels(pane)) \(paGutters(pane))")
        pane.show(paCode(ticket: 3), path: paPath, image: nil)
        pane.show(paPhoto(), path: "/photos/screenshot-terminal.png", image: NSImage(size: NSSize(width: 8, height: 8)))
        #expect(paMatchLabels(pane).isEmpty && paGutters(pane).isEmpty, "after a photo: \(paMatchLabels(pane)) \(paGutters(pane))")
        pane.show(paCode(ticket: 4), path: paPath, image: nil)
        pane.show(paDoc(), path: "/docs/tenancy.docx", image: nil)
        #expect(paMatchLabels(pane).isEmpty && paGutters(pane).isEmpty, "after a document: \(paMatchLabels(pane)) \(paGutters(pane))")
    }

    @MainActor
    @Test func aDocumentPassageIsOneTextAreaLabelledPassageAndHoldsItsTextAsItsValue() {
        let (pane, _) = paPane()
        pane.show(paDoc(), path: "/docs/tenancy.docx", image: nil)
        let holders = paTextViews(pane).filter { $0.string.contains("The tenant may keep one cat") }
        #expect(holders.count == 1, "text views holding the passage: \(holders.count)")
        #expect(holders.first?.accessibilityLabel() == "Passage", "the document passage's label is \(String(describing: holders.first?.accessibilityLabel()))")
        #expect(holders.first?.accessibilityRole() == .textArea, "its role is \(String(describing: holders.first?.accessibilityRole()))")
        #expect((holders.first?.accessibilityValue() as? String)?.hasPrefix("The tenant may keep one cat") == true, "its value is \(String(describing: holders.first?.accessibilityValue()))")
    }

    private static let longCodeLine = "    let sentence = \"" + String(repeating: "retry the failed call with backoff ", count: 40) + "\""

    @MainActor
    private func documentPassageFits(_ pane: Pane, _ label: String) {
        pane.view.layoutSubtreeIfNeeded()
        let views = paTextViews(pane).filter { $0.string.contains("The tenant may keep one cat") }
        #expect(views.count == 1, "\(label): text views holding the document passage: \(views.count)")
        guard let textView = views.first, let scroll = textView.enclosingScrollView, let manager = textView.layoutManager, let container = textView.textContainer else {
            Issue.record("\(label): the document passage is not in a text view inside a scroll view")
            return
        }
        manager.ensureLayout(for: container)
        let clip = scroll.contentView.bounds.width
        #expect(abs(textView.frame.width - clip) <= 1, "\(label): the passage view is \(textView.frame.width) wide, the clip view \(clip)")
        #expect(container.size.width <= clip + 1, "\(label): the text container is \(container.size.width) wide, the clip view \(clip)")
        #expect(manager.usedRect(for: container).maxX <= clip + 1, "\(label): the laid-out text reaches \(manager.usedRect(for: container).maxX), past the clip view's \(clip)")
    }

    @MainActor
    @Test func aDocumentPassageAloneWrapsAtThePaneWidth() {
        let (pane, _) = paPane()
        pane.show(paDoc(), path: "/docs/tenancy.docx", image: nil)
        documentPassageFits(pane, "document alone")
    }

    @MainActor
    @Test func aDocumentPassageShownAfterACodeReplyWithALongLineWrapsAtThePaneWidth() {
        let (pane, _) = paPane()
        pane.show(paCode(text: "func a() {\n" + Self.longCodeLine + "\n}", ticket: 1), path: paPath, image: nil)
        pane.show(paDoc(), path: "/docs/tenancy.docx", image: nil)
        documentPassageFits(pane, "document after code")
    }

    @MainActor
    @Test func theSameInAWindowAndWithoutALayoutBetweenTheTwoReplies() {
        let (pane, keep) = paPane(width: 520, inWindow: true)
        pane.show(paCode(text: "func a() {\n" + Self.longCodeLine + "\n}"), path: paPath, image: nil)
        pane.show(paDoc(), path: "/docs/tenancy.docx", image: nil)
        documentPassageFits(pane, "document after code, in a window, no layout between")
        _ = keep
    }

    @MainActor
    @Test func aDocumentThenCodeThenADocumentAgainStillWraps() {
        let (pane, _) = paPane()
        pane.show(paDoc(), path: "/docs/tenancy.docx", image: nil)
        pane.show(paCode(text: "func a() {\n" + Self.longCodeLine + "\n}", ticket: 2), path: paPath, image: nil)
        pane.show(paDoc(ticket: 3), path: "/docs/tenancy.docx", image: nil)
        documentPassageFits(pane, "document, code, document")
    }
}

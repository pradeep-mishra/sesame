import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, implementer step for defect 1 of the real-app batch (the typing scramble: "a dog on the beach" ended as
// "a dog on eachthe " with 17 key events for 18 characters). The scramble was not reproduced headlessly, so these pin
// the defence the implementer added: a list reload or a selection change never takes the focus from the search box,
// and the list takes it only from Tab or a click.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests` (the Panel tests set HOME, which is process-wide).

@MainActor
private func fsFocusIsInBox(_ window: NSWindow, _ field: NSTextField) -> Bool {
    if window.firstResponder === field { return true }
    return (window.firstResponder as? NSText)?.delegate === field
}

private let fsTexts = [
    PRPhoto(name: "beach-dog.jpg", words: "a dog on the beach"),
    PRPhoto(name: "lawn-dog.jpg", words: "a dog on the lawn"),
]

extension ModelDownloadTests {
    @Suite("FocusStabilityTests", .serialized)
    struct FocusStabilityTests {

        @MainActor
        @Test func aListReloadAndSelectionChangesLeaveTheFieldEditorAsFirstResponder() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let list = ResultList()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 560))
            window.contentView = content
            box.field.frame = NSRect(x: 10, y: 500, width: 700, height: 30)
            list.view.frame = NSRect(x: 0, y: 0, width: 380, height: 480)
            for view in [box.field, list.view] { content.addSubview(view) }
            #expect(window.makeFirstResponder(box.field))
            #expect(window.firstResponder is NSText, "the field editor is not active: \(String(describing: window.firstResponder))")

            let rows = (0..<4).map { SearchHit(path: "/photos/f\($0).jpg", passageID: Int64($0)) }
            list.show(.rows(rows))
            #expect(fsFocusIsInBox(window, box.field), "after rows: \(String(describing: window.firstResponder))")
            list.move(by: 1)
            list.move(by: 1)
            #expect(fsFocusIsInBox(window, box.field), "after Down: \(String(describing: window.firstResponder))")
            list.dropGone("/photos/f2.jpg")
            #expect(fsFocusIsInBox(window, box.field), "after a gone file: \(String(describing: window.firstResponder))")
            list.show(.searching)
            list.show(.rows(Array(rows.prefix(2))))
            list.show(.noMatches)
            list.show(.empty)
            #expect(fsFocusIsInBox(window, box.field), "after the list emptied: \(String(describing: window.firstResponder))")
        }

        @MainActor
        @Test func theListDoesNotTakeTheFocusWithoutATabOrAClick() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let list = ResultList()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 560))
            window.contentView = content
            box.field.frame = NSRect(x: 10, y: 500, width: 700, height: 30)
            list.view.frame = NSRect(x: 0, y: 0, width: 380, height: 480)
            for view in [box.field, list.view] { content.addSubview(view) }
            list.show(.rows([SearchHit(path: "/photos/a.jpg", passageID: 1)]))
            #expect(window.makeFirstResponder(box.field))

            // AppKit hands the focus to the window itself when a view refuses it, so the answer is not the test.
            _ = window.makeFirstResponder(list.keyView)
            #expect(window.firstResponder !== list.keyView, "the list took the focus with no key or click")
            #expect(!list.keyView.acceptsFirstResponder)
        }

        @MainActor
        @Test func theRealPanelKeepsTheFocusInTheBoxWhileKeysAndListsArrive() async throws {
            try await prWithPanel(photos: fsTexts, answering: true) { panel in
                let field = panel.queryBox.field
                await prType("a dog on the beach", into: panel, pauseMilliseconds: 30) { count in
                    #expect(fsFocusIsInBox(panel, field), "after key \(count): \(String(describing: panel.firstResponder))")
                }
                await spWait(0.3)
                panel.sendEvent(prKey("\u{F701}", in: panel, keyCode: UInt16(kVK_DownArrow)))
                await spWait(0.1)
                #expect(fsFocusIsInBox(panel, field), "after Down: \(String(describing: panel.firstResponder))")
                #expect(panel.queryBox.text == "a dog on the beach")
            }
        }

        @MainActor
        @Test func aFocusLostBeforeAListChangeIsGivenBackToTheBox() async throws {
            try await prWithPanel(photos: fsTexts) { panel in
                _ = panel.makeFirstResponder(nil)
                #expect(!fsFocusIsInBox(panel, panel.queryBox.field))

                panel.queryBox.type("a")   // the box reports a keystroke, the screen changes, the list is replaced

                #expect(fsFocusIsInBox(panel, panel.queryBox.field), "the focus is \(String(describing: panel.firstResponder))")
            }
        }
    }
}

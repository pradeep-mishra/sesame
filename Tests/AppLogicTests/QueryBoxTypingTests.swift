import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step for defect 1 of the real-app batch (tasks 36 to 39): typing `a dog on the beach` into the
// open panel left `a dog on eachthe ` in the box (3 of 3 runs), with 17 `key` probe events for 18 characters.
//
// Written from spec S1 ("Typing 'a dog on the beach' lists matching files"; S1.10, S1.11 and S1.26 all type that text and
// read it back), design section 3 ("Each keystroke gets a ticket n"; the keyword rows and the ranked list replace each
// other in place while the person types) and the batch report (the caret jumped back to position 9 and the next key
// was lost when results were shown). The product source was read only for names: `QueryBox`, `Panel`,
// `Panel.attach(helper:)`, `Panel.sendEvent`, `ResultList`, `Pane`, `Probe.sink`.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests` (HOME and the probe are process-wide).
//
// WHAT THESE DRIVE. Real key-down events go to a real, never-shown `Panel` (its text field is first responder, so the
// field editor edits it exactly as in the app), with a real index behind its search so the keyword rows arrive between
// keystrokes and select a row, and the pane is asked for a preview. Two cadences: one yield after each key, and 60 ms
// after each key (a list that arrives between two keys). After EVERY key the test reads the box, the field and the
// field editor's selection, so a caret that jumps or a key that is lost shows at once, not only at the end.
//
// WHAT THEY CANNOT SHOW. These ran green against the product at the time of writing: the scramble was NOT reproduced
// headlessly. What a unit test cannot reach, and only the running app shows: a key window in an active app, the window
// server's real key delivery and text input context, the ranked list (it needs the `encode` helper's vectors, and no
// helper is started here), the helper's preview reply drawing a picture while keys arrive, and the one-second state
// refresh of `Panel.show()`. See the report for the list.

private let tyText = "a dog on the beach"

extension ModelDownloadTests {
    @Suite("QueryBoxTypingTests", .serialized)
    struct QueryBoxTypingTests {

        // MARK: the logic alone (no window)

        @MainActor
        @Test func typingTheSentenceOneCharacterAtATimeGivesOneKeyEventAndOneTicketPerCharacterAndExactlyThatText() async throws {
            try await prRecordingKeys { events in
                var next = 40
                let box = QueryBox(nextTicket: { next += 1; return next })
                var reported: [(text: String, ticket: Int)] = []
                box.onChange = { text, ticket in reported.append((text, ticket)) }

                box.type(tyText)

                #expect(box.text == tyText, "the box holds \"\(box.text)\"")
                #expect(events.keys.count == 18, "key events: \(events.keys.count)")
                #expect(events.keys == Array(41...58), "tickets of the key events: \(events.keys)")
                #expect(reported.map(\.text) == (1...18).map { String(tyText.prefix($0)) }, "texts: \(reported.map(\.text))")
                #expect(reported.map(\.ticket) == Array(41...58))
            }
        }

        // MARK: a real text field and field editor, lists re-rendered between keys

        @MainActor
        @Test func typingThroughTheFieldEditorWhileListsAreReRenderedLeavesExactlyThatTextAndTheCaretAtTheEnd() async throws {
            _ = NSApplication.shared
            try await prRecordingKeys { events in
                var next = 0
                let box = QueryBox(nextTicket: { next += 1; return next })
                let list = ResultList()
                let pane = Pane()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 560))
                window.contentView = content
                box.field.frame = NSRect(x: 10, y: 500, width: 700, height: 30)
                list.view.frame = NSRect(x: 0, y: 0, width: 380, height: 480)
                pane.view.frame = NSRect(x: 400, y: 0, width: 540, height: 480)
                for view in [box.field, list.view, pane.view] { content.addSubview(view) }
                list.onSelect = { hit in if let hit { pane.showPending(path: hit.path) } else { pane.clear() } }
                list.returnFocus = { _ = window.makeFirstResponder(box.field) }
                #expect(window.makeFirstResponder(box.field))

                var count = 0
                for character in tyText {
                    window.sendEvent(prKey(String(character), in: window))
                    count += 1
                    // what the panel does after a key: the list is replaced (rows, none, rows with another first row)
                    switch count % 3 {
                    case 0: list.show(.searching)
                    case 1: list.show(.rows([SearchHit(path: "/photos/one-\(count).jpg", passageID: 1)]))
                    default: list.show(.rows((0..<2).map { SearchHit(path: "/photos/f\($0)-\(count).jpg", passageID: Int64($0)) }))
                    }
                    let want = String(tyText.prefix(count))
                    #expect(box.text == want, "after key \(count) the box holds \"\(box.text)\", wanted \"\(want)\"")
                    #expect(box.field.stringValue == want, "after key \(count) the field holds \"\(box.field.stringValue)\"")
                    #expect(prSelection(of: box.field) == NSRange(location: count, length: 0),
                            "after key \(count) the caret is \(String(describing: prSelection(of: box.field))), wanted at \(count)")
                }
                #expect(events.keys.count == 18, "key events: \(events.keys.count)")
            }
        }

        // MARK: the real panel with ranked lists and preview replies arriving between keys

        // Eight photos: with the stand-in helper every text is embedded as axis 0, so the first photo stands out of
        // the other seven (z >= 2) and the ranked list is that one file, as in the batch (1 row).
        private static let eightPhotos = [
            PRPhoto(name: "beach-dog.jpg", words: "a dog on the beach"),
            PRPhoto(name: "lawn-dog.jpg", words: "a dog on the lawn"),
            PRPhoto(name: "dog.jpg", words: "a dog"),
            PRPhoto(name: "dusk.jpg", words: "evening sky"),
            PRPhoto(name: "pier.jpg", words: "red boats at the pier"),
            PRPhoto(name: "market.jpg", words: "crowd at the market"),
            PRPhoto(name: "ridge.jpg", words: "mountain ridge"),
            PRPhoto(name: "lake.jpg", words: "still lake"),
        ]

        @MainActor
        @Test(arguments: [UInt64(0), UInt64(20), UInt64(60), UInt64(150)])
        func theRealPanelKeepsExactlyTheTypedTextWhileRankedListsAndPreviewRepliesArriveBetweenKeys(_ pause: UInt64) async throws {
            try await prWithPanel(photos: Self.eightPhotos, answering: true) { panel in
                try await prRecordingKeys { events in
                    let box = panel.queryBox!
                    await prType(tyText, into: panel, pauseMilliseconds: pause) { count in
                        let want = String(tyText.prefix(count))
                        #expect(box.text == want, "after key \(count) the box holds \"\(box.text)\", wanted \"\(want)\"")
                        #expect(box.field.stringValue == want, "after key \(count) the field holds \"\(box.field.stringValue)\"")
                        #expect(prSelection(of: box.field) == NSRange(location: count, length: 0),
                                "after key \(count) the caret is \(String(describing: prSelection(of: box.field))), wanted at \(count)")
                    }
                    // the ranked list of the whole text arrives and its first file is selected and previewed
                    let settled = await spEventually { prShownTexts(panel.contentView!).contains("/photos/beach-dog.jpg") }
                    #expect(settled, "the ranked list never reached the pane; shown: \(prShownTexts(panel.contentView!))")
                    #expect(box.text == tyText)
                    #expect(box.field.stringValue == tyText)
                    #expect(prSelection(of: box.field) == NSRange(location: 18, length: 0))
                    #expect(events.keys.count == 18, "key events: \(events.keys.count)")
                }
            }
        }

        // MARK: the real panel, keyword rows arriving between keys

        @MainActor
        @Test(arguments: [UInt64(0), UInt64(60)])
        func theRealPanelKeepsExactlyTheTypedTextWhileKeywordRowsArriveBetweenKeys(_ pause: UInt64) async throws {
            let photos = [
                PRPhoto(name: "beach-dog.jpg", words: "a dog on the beach"),
                PRPhoto(name: "lawn-dog.jpg", words: "a dog on the lawn"),
                PRPhoto(name: "dog.jpg", words: "a dog"),
                PRPhoto(name: "dusk.jpg", words: "a dog on the beach at dusk"),
            ]
            try await prWithPanel(photos: photos) { panel in
                try await prRecordingKeys { events in
                    let box = panel.queryBox!
                    await prType(tyText, into: panel, pauseMilliseconds: pause) { count in
                        let want = String(tyText.prefix(count))
                        #expect(box.text == want, "after key \(count) the box holds \"\(box.text)\", wanted \"\(want)\"")
                        #expect(box.field.stringValue == want, "after key \(count) the field holds \"\(box.field.stringValue)\"")
                        #expect(prSelection(of: box.field) == NSRange(location: count, length: 0),
                                "after key \(count) the caret is \(String(describing: prSelection(of: box.field))), wanted at \(count)")
                    }
                    await spWait(0.3)
                    #expect(box.text == tyText)
                    #expect(box.field.stringValue == tyText)
                    #expect(prSelection(of: box.field) == NSRange(location: 18, length: 0))
                    #expect(events.keys.count == 18, "key events: \(events.keys.count)")
                    #expect(events.keys == events.keys.sorted() && Set(events.keys).count == 18,
                            "tickets must rise, one per key: \(events.keys)")
                }
            }
        }
    }
}

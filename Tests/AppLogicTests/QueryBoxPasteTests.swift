import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step for defect 3 of the real-app batch (tasks 36 to 39): pasting 700 characters into the box left
// 0 characters instead of the first 500.
//
// Written from spec S1 ("Text longer than 500 characters is cut to its first 500"), S1.26 (kit pass: a 700-character
// string pasted gives a box value of length 500 equal to the first 500 characters; the kit pastes by putting the text on
// the pasteboard and posting Command+V), and design section 3 ("QueryBox cuts typed or pasted text at 500 and shows the
// cut text"). The product source was read only for names and for where the paste goes: `QueryBox.paste`,
// `QueryBox.field`, `Panel.sendEvent`, `Panel.queryBox`. Reading `Panel.sendEvent` showed that Command+A and Command+C
// are handled by the panel itself and Command+V is not; the app has no Edit menu, so nothing else turns Command+V into
// a paste. That is the likely cause (inference); these tests do not depend on it.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests` (HOME and the probe are process-wide).
//
// WHAT THESE PIN
//   1. `QueryBox.paste` with a made text field: the field's text and `text` agree and are the first 500 characters.
//   2. The real key path: a Command+V key-down delivered to `Panel.sendEvent` puts the general pasteboard's text in the
//      box (cut at 500), with the field showing the same text. A Command+V with no text on the pasteboard changes
//      nothing. The pasted text is added at the end of what is typed (the caret is there).
//   The implementer's choice how Command+V reaches the box (`queryBox.paste(...)` from the pasteboard, or the field
//   editor's paste). The test does not make the panel key, so a route that needs `NSApp.keyWindow` will not pass;
//   deliver it through the panel's own responder chain or `queryBox.paste`.
//
// SIDE EFFECT. The key path test writes text to the general pasteboard (the panel reads the general pasteboard) and puts
// the text it found back afterwards.

private let pbLong = String((0..<700).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })

private func pbCheck(_ got: String, equals want: String, _ what: String,
                     sourceLocation: SourceLocation = #_sourceLocation) {
    guard got != want else { return }
    Issue.record("\(what): got \(got.count) characters ending \"\(got.suffix(6))\", wanted \(want.count) ending \"\(want.suffix(6))\"",
                 sourceLocation: sourceLocation)
}

/// Puts `string` on the general pasteboard for `body`, then what was there as text comes back (or the board is emptied).
@MainActor
private func pbWithPasteboardText(_ string: String?, _ body: @MainActor () async throws -> Void) async rethrows {
    let board = NSPasteboard.general
    let before = board.string(forType: .string)
    board.clearContents()
    if let string { board.setString(string, forType: .string) }
    defer {
        board.clearContents()
        if let before { board.setString(before, forType: .string) }
    }
    try await body()
}

private let pbCommandV = UInt16(kVK_ANSI_V)

extension ModelDownloadTests {
    @Suite("QueryBoxPasteTests", .serialized)
    struct QueryBoxPasteTests {

        // MARK: the box itself, with its real text field

        @MainActor
        @Test func pasting700CharactersLeavesTheFirst500InTheBoxAndInTheField() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            box.paste(pbLong)
            pbCheck(box.text, equals: String(pbLong.prefix(500)), "box.text after a 700 character paste")
            pbCheck(field.stringValue, equals: String(pbLong.prefix(500)), "the field after a 700 character paste")
            #expect(box.text == field.stringValue, "the box says \(box.text.count) characters, the field \(field.stringValue.count)")
        }

        @MainActor
        @Test func pastingAfterTypedTextKeepsTheFirst500OfTheWholeInBoxAndField() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            box.type("a dog on the beach: ")
            box.paste(pbLong)
            let whole = "a dog on the beach: " + pbLong
            pbCheck(box.text, equals: String(whole.prefix(500)), "box.text")
            pbCheck(field.stringValue, equals: String(whole.prefix(500)), "the field")
        }

        // MARK: the key a person presses: Command+V into the panel

        @MainActor
        @Test func commandVWith700CharactersOnThePasteboardLeavesTheFirst500InTheBoxAndInTheField() async throws {
            try await prWithPanel { panel in
                await pbWithPasteboardText(pbLong) {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: pbCommandV))
                    await spWait(0.2)
                    pbCheck(panel.queryBox.text, equals: String(pbLong.prefix(500)), "the box after Command+V of 700 characters")
                    pbCheck(panel.queryBox.field.stringValue, equals: String(pbLong.prefix(500)), "the field after Command+V")
                }
            }
        }

        @MainActor
        @Test func commandVAfterTypedTextAddsTheTextAtTheEndAndCutsAt500() async throws {
            try await prWithPanel { panel in
                await prType("dog ", into: panel)
                await pbWithPasteboardText(pbLong) {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: pbCommandV))
                    await spWait(0.2)
                    let whole = "dog " + pbLong
                    pbCheck(panel.queryBox.text, equals: String(whole.prefix(500)), "the box after typing and Command+V")
                    pbCheck(panel.queryBox.field.stringValue, equals: String(whole.prefix(500)), "the field")
                }
            }
        }

        @MainActor
        @Test func aShortPasteIsKeptWhole() async throws {
            try await prWithPanel { panel in
                await pbWithPasteboardText("a dog on the beach") {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: pbCommandV))
                    await spWait(0.2)
                    #expect(panel.queryBox.text == "a dog on the beach", "the box holds \"\(panel.queryBox.text)\"")
                    #expect(panel.queryBox.field.stringValue == "a dog on the beach")
                }
            }
        }

        @MainActor
        @Test func commandVWithNoTextOnThePasteboardChangesNothing() async throws {
            try await prWithPanel { panel in
                await prType("dog", into: panel)
                await pbWithPasteboardText(nil) {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: pbCommandV))
                    await spWait(0.1)
                    #expect(panel.queryBox.text == "dog", "the box holds \"\(panel.queryBox.text)\"")
                    #expect(panel.queryBox.field.stringValue == "dog")
                }
            }
        }
    }
}

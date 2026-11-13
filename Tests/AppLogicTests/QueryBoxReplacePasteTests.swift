import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1 review round B (app), tester step: finding F11. Command+V always appends at the end of the box and ignores any
// selection (Panel.swift sends `queryBox.paste(text)`, QueryBox.paste is `change(to: text + pasted)`). Scenario: Command+A
// then Command+V adds to the old text instead of replacing it. The sealed QueryBoxPasteTests pin "added at the end" for
// a caret at the end; those stay and are not touched.
// Written from the review report (F11), the brief's acceptance line, spec S1 ("Text longer than 500 characters is cut to
// its first 500") and design section 3 ("QueryBox cuts typed or pasted text at 500") only, and from the sealed
// QueryBoxPasteTests and the rig (PanelRig.swift). Product source read for names and where the logic lives: QueryBox.swift
// (`paste`, `text`, `field`, `onChange`), Panel.swift (`handle`, the `v` case). No expected value comes from them.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests` (HOME and the probe are process-wide). The key path tests write the
// general pasteboard and put its text back, as the sealed file does.
//
// API SHAPES these tests pin (new; if a shape is wrong, ask for a test change rather than guessing). In `Sesame`.
//   1. `QueryBox.paste(_ pasted: String, replacing selection: NSRange)`. `selection` is an NSRange in UTF-16 units, as the
//      field editor's `selectedRange` is. The characters in it are replaced by `pasted` (a range of length 0 inserts at
//      its location), then the whole is cut to its first 500 Characters (Swift `Character`s, as `PanelState.cut` does),
//      shown in the field, and reported as one keystroke: one `nextTicket()` call, one `onChange(text, ticket)`. A range
//      that runs past the end of the text is clamped to the text (a location past the end appends, a length that is too
//      long stops at the end); it never crashes. `paste(_:)` (no range) is unchanged: it appends at the end.
//   2. `Panel`'s Command+V reads the field editor's `selectedRange` and calls `queryBox.paste(_:replacing:)` with it. With
//      the caret at the end and nothing selected that is the old append. With no text on the pasteboard it changes
//      nothing, selection or not. After a paste the caret sits right after the pasted text (when the text was not cut).
//
// NOT REACHED here (the real app only): the real key window, a real Command+V from the kit (S1.26 keeps its own check),
// Command+A reaching the field editor through `NSApp.sendAction` when the panel is the key window (measured: in the rig,
// whose panel is never key, a Command+A key-down through `Panel.sendEvent` leaves the caret where it was, so the two
// "Command+A then Command+V" tests select all through the field editor, which is what Command+A does; the real chord is
// the kit's, S1.26 and the person's), and IME marked text.

private let rpLong = String((0..<700).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })

private func rpUTF16(_ text: String) -> Int { (text as NSString).length }

@MainActor
private func rpWithPasteboardText(_ string: String?, _ body: @MainActor () async throws -> Void) async rethrows {
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

private final class RPChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(text: String, ticket: Int)] = []
    func add(_ text: String, _ ticket: Int) { lock.lock(); list.append((text, ticket)); lock.unlock() }
    var all: [(text: String, ticket: Int)] { lock.lock(); defer { lock.unlock() }; return list }
}

private final class RPTickets: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    func take() -> Int { lock.lock(); defer { lock.unlock() }; next += 1; return next }
    var taken: Int { lock.lock(); defer { lock.unlock() }; return next }
}

extension ModelDownloadTests {
    @Suite("QueryBoxReplacePasteTests", .serialized)
    struct QueryBoxReplacePasteTests {

        // MARK: the box itself, with its real text field

        @MainActor
        @Test func pastingOverTheWholeTextLeavesExactlyThePastedText() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            box.type("hello world")
            box.paste("X", replacing: NSRange(location: 0, length: 11))
            #expect(box.text == "X", "box.text: \"\(box.text)\"")
            #expect(field.stringValue == "X", "the field: \"\(field.stringValue)\"")
        }

        @MainActor
        @Test func pastingOverTheMiddleReplacesOnlyTheSelectedCharacters() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            box.type("hello world")
            box.paste("there", replacing: NSRange(location: 6, length: 5))
            #expect(box.text == "hello there", "box.text: \"\(box.text)\"")
            #expect(field.stringValue == "hello there", "the field: \"\(field.stringValue)\"")
        }

        @MainActor
        @Test func aCaretWithNothingSelectedInsertsAtTheCaret() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            box.type("helloworld")
            box.paste(" ", replacing: NSRange(location: 5, length: 0))
            #expect(box.text == "hello world", "box.text: \"\(box.text)\"")
            #expect(field.stringValue == "hello world", "the field: \"\(field.stringValue)\"")
        }

        @MainActor
        @Test func aCaretAtTheEndAppendsAsTheOldPasteDid() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            box.type("dog ")
            box.paste("on the beach", replacing: NSRange(location: 4, length: 0))
            #expect(box.text == "dog on the beach", "box.text: \"\(box.text)\"")
        }

        @MainActor
        @Test func aLongPasteOverTheWholeTextIsCutToItsFirst500Characters() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            box.type("dog ")
            box.paste(rpLong, replacing: NSRange(location: 0, length: 4))
            #expect(box.text == String(rpLong.prefix(500)), "box.text has \(box.text.count) characters, wanted the first 500 of the paste alone")
            #expect(field.stringValue == String(rpLong.prefix(500)), "the field has \(field.stringValue.count) characters")
        }

        @MainActor
        @Test func aPasteOverAMiddleSelectionIsCutAt500AfterTheReplacement() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            let field = box.field
            let typed = String(rpLong.prefix(400))
            box.type(typed)
            let pasted = String(rpLong.suffix(300))
            box.paste(pasted, replacing: NSRange(location: 390, length: 10))
            let whole = String(typed.prefix(390)) + pasted
            #expect(box.text == String(whole.prefix(500)), "box.text has \(box.text.count) characters ending \"\(box.text.suffix(6))\"")
            #expect(field.stringValue == box.text, "the field and the box disagree")
        }

        @MainActor
        @Test func theRangeIsInUTF16UnitsAndTheCutIsInCharacters() {
            _ = NSApplication.shared
            let box = QueryBox(nextTicket: { 1 })
            box.type("a\u{1F600}b")   // the emoji is two UTF-16 units: the field editor's range for it is length 2
            box.paste("X", replacing: NSRange(location: 1, length: 2))
            #expect(box.text == "aXb", "box.text: \"\(box.text)\"")

            let other = QueryBox(nextTicket: { 1 })
            other.paste(String(repeating: "\u{1F600}", count: 600), replacing: NSRange(location: 0, length: 0))
            #expect(other.text == String(repeating: "\u{1F600}", count: 500), "\(other.text.count) characters, wanted 500")
        }

        @MainActor
        @Test func aRangePastTheEndOfTheTextIsClampedAndNeverCrashes() {
            _ = NSApplication.shared
            let past = QueryBox(nextTicket: { 1 })
            past.type("abc")
            past.paste("Z", replacing: NSRange(location: 10, length: 4))
            #expect(past.text == "abcZ", "a location past the end should append, got \"\(past.text)\"")

            let long = QueryBox(nextTicket: { 1 })
            long.type("abc")
            long.paste("Z", replacing: NSRange(location: 2, length: 50))
            #expect(long.text == "abZ", "a length past the end should stop at the end, got \"\(long.text)\"")
        }

        @MainActor
        @Test func aReplacingPasteIsOneKeystrokeWithOneTicketAndOneOnChange() {
            _ = NSApplication.shared
            let tickets = RPTickets()
            let box = QueryBox(nextTicket: { tickets.take() })
            box.type("dog")
            let changes = RPChanges()
            box.onChange = { text, ticket in changes.add(text, ticket) }
            let before = tickets.taken

            box.paste("cat", replacing: NSRange(location: 0, length: 3))

            #expect(tickets.taken == before + 1, "tickets taken for one paste: \(tickets.taken - before)")
            #expect(changes.all.count == 1, "onChange calls: \(changes.all.count)")
            #expect(changes.all.first?.text == "cat")
            #expect(changes.all.first?.ticket == tickets.taken, "onChange carried ticket \(String(describing: changes.all.first?.ticket)), the paste took \(tickets.taken)")
        }

        // MARK: the key a person presses: Command+V into the panel

        @MainActor
        @Test func selectAllThenCommandVLeavesExactlyThePastedText() async throws {
            try await prWithPanel { panel in
                await prType("dog ", into: panel)
                panel.queryBox.field.currentEditor()?.selectAll(nil)   // what Command+A does (see the note on Command+A above)
                #expect(prSelection(of: panel.queryBox.field) == NSRange(location: 0, length: 4),
                        "setup: select all left the selection \(String(describing: prSelection(of: panel.queryBox.field)))")
                await rpWithPasteboardText("a cat") {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: UInt16(kVK_ANSI_V)))
                    await spWait(0.2)
                    #expect(panel.queryBox.text == "a cat", "the box holds \"\(panel.queryBox.text)\"")
                    #expect(panel.queryBox.field.stringValue == "a cat", "the field holds \"\(panel.queryBox.field.stringValue)\"")
                }
            }
        }

        @MainActor
        @Test func selectAllThenCommandVOf700CharactersLeavesTheFirst500OfThePasteAlone() async throws {
            try await prWithPanel { panel in
                await prType("dog ", into: panel)
                panel.queryBox.field.currentEditor()?.selectAll(nil)   // what Command+A does
                await rpWithPasteboardText(rpLong) {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: UInt16(kVK_ANSI_V)))
                    await spWait(0.2)
                    #expect(panel.queryBox.text == String(rpLong.prefix(500)),
                            "the box has \(panel.queryBox.text.count) characters starting \"\(panel.queryBox.text.prefix(6))\"")
                    #expect(panel.queryBox.field.stringValue == String(rpLong.prefix(500)), "the field has \(panel.queryBox.field.stringValue.count) characters")
                }
            }
        }

        @MainActor
        @Test func aPartialSelectionIsReplacedAndTheCaretLandsAfterThePastedText() async throws {
            try await prWithPanel { panel in
                await prType("a dog on the beach", into: panel)
                panel.queryBox.field.currentEditor()?.selectedRange = NSRange(location: 2, length: 3)   // "dog"
                await rpWithPasteboardText("cat") {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: UInt16(kVK_ANSI_V)))
                    await spWait(0.2)
                    #expect(panel.queryBox.text == "a cat on the beach", "the box holds \"\(panel.queryBox.text)\"")
                    #expect(panel.queryBox.field.stringValue == "a cat on the beach")
                    #expect(prSelection(of: panel.queryBox.field) == NSRange(location: 5, length: 0),
                            "the caret is \(String(describing: prSelection(of: panel.queryBox.field))), wanted right after the pasted text")
                }
            }
        }

        @MainActor
        @Test func aCaretInTheMiddleInsertsThereAndNothingIsDeleted() async throws {
            try await prWithPanel { panel in
                await prType("dogcat", into: panel)
                panel.queryBox.field.currentEditor()?.selectedRange = NSRange(location: 3, length: 0)
                await rpWithPasteboardText("-") {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: UInt16(kVK_ANSI_V)))
                    await spWait(0.2)
                    #expect(panel.queryBox.text == "dog-cat", "the box holds \"\(panel.queryBox.text)\"")
                    #expect(panel.queryBox.field.stringValue == "dog-cat")
                    #expect(prSelection(of: panel.queryBox.field) == NSRange(location: 4, length: 0),
                            "the caret is \(String(describing: prSelection(of: panel.queryBox.field))), wanted after the dash")
                }
            }
        }

        @MainActor
        @Test func commandVWithNothingOnThePasteboardKeepsTheSelectedTextToo() async throws {
            try await prWithPanel { panel in
                await prType("dog", into: panel)
                panel.queryBox.field.currentEditor()?.selectedRange = NSRange(location: 0, length: 3)
                await rpWithPasteboardText(nil) {
                    panel.sendEvent(prKey("v", in: panel, command: true, keyCode: UInt16(kVK_ANSI_V)))
                    await spWait(0.1)
                    #expect(panel.queryBox.text == "dog", "an empty pasteboard deleted the selection: \"\(panel.queryBox.text)\"")
                    #expect(panel.queryBox.field.stringValue == "dog")
                }
            }
        }
    }
}

import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t36, tester step. Written from the t36 entry, spec S1 ("Text longer than 500 characters is cut to its first
// 500", "reopening never shows the previous text") and design section 3 ("Panel opens: ... text cleared"; "QueryBox
// cuts typed or pasted text at 500 and shows the cut text") only; no product source read.
//
// SUITE PLACEMENT. `QueryBox` emits a probe `key` event on every keystroke, and SESAME_PROBE_FILE and `Probe.sink` are
// process-wide, so this suite is nested inside `ModelDownloadTests` with the other probe suites and runs one at a time
// with them. Side effect: `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin (the design names `QueryBox` and fixes no signatures; if a shape is wrong, ask for a
// test change rather than guessing). `QueryBox` is in the `Sesame` target; it may be `@MainActor` (every test is).
//   1. `init(nextTicket: @escaping () -> Int)`. Every keystroke gets its ticket from `nextTicket`, called once per
//      keystroke and not otherwise (in the app it is the pipeline's `newTicket`, design section 3: "Each keystroke
//      gets a ticket n").
//   2. `var text: String { get }` is what the box shows, always at most 500 characters.
//   3. `var onChange: ((String, Int) -> Void)?` is called after each change of the text with the text now in the
//      box and the ticket of the keystroke or paste that made it. It may be called on the main thread only.
//   4. `func type(_ characters: String)` types the characters one at a time, in order, at the end of the text (the
//      cursor sits at the end in these tests): one keystroke each. `func paste(_ pasted: String)` adds the whole
//      text at the end in one change. `func deleteBackward()` is one keystroke that removes the last character (a
//      no-op on an empty box still counts as a keystroke or not: not pinned, the tests never do it).
//   5. `func clear()` is the panel opening: the box is empty afterwards, whatever it held. It is not a keystroke.
// The cut counts Characters (spec: "first 500 characters"), not bytes, UTF-16 units or scalars.
//   6. Not pinned, on purpose: what `onChange` is told when a keystroke or paste changes nothing (a character typed
//      into a full box); how many `key` events a paste emits; selection and the cursor (Command+C is t37 and t38).

private final class QBTickets: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int
    private var issuedList: [Int] = []
    init(start: Int) { next = start }
    func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let value = next
        next += 1
        issuedList.append(value)
        return value
    }
    var issued: [Int] { lock.lock(); defer { lock.unlock() }; return issuedList }
}

private final class QBChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(text: String, ticket: Int)] = []
    func add(_ text: String, _ ticket: Int) { lock.lock(); list.append((text, ticket)); lock.unlock() }
    var all: [(text: String, ticket: Int)] { lock.lock(); defer { lock.unlock() }; return list }
}

@MainActor
private func qbMake(start: Int = 100) -> (box: QueryBox, tickets: QBTickets, changes: QBChanges) {
    let tickets = QBTickets(start: start)
    let changes = QBChanges()
    let box = QueryBox(nextTicket: { tickets.take() })
    box.onChange = { text, ticket in changes.add(text, ticket) }
    return (box, tickets, changes)
}

private func qbFirst500(_ text: String) -> String { String(text.prefix(500)) }

// A long text compared without printing all of it: its length and its last characters say where it went wrong.
private func qbCheck(_ got: String?, equals want: String, _ what: String,
                     sourceLocation: SourceLocation = #_sourceLocation) {
    guard got != want else { return }
    let gotCount = got.map { String($0.count) } ?? "nil"
    let gotTail = got.map { String($0.suffix(6)) } ?? ""
    Issue.record("\(what): got \(gotCount) characters ending \"\(gotTail)\", wanted \(want.count) ending \"\(want.suffix(6))\"",
                 sourceLocation: sourceLocation)
}

extension ModelDownloadTests {
    @Suite("QueryBoxTests", .serialized)
    struct QueryBoxTests {

        // MARK: the box starts empty

        @MainActor
        @Test func aNewBoxIsEmptyAndHasAskedForNoTicket() {
            let made = qbMake()
            #expect(made.box.text == "")
            #expect(made.tickets.issued.isEmpty, "a ticket was taken before any keystroke: \(made.tickets.issued)")
            #expect(made.changes.all.isEmpty)
        }

        @MainActor
        @Test func openingThePanelEmptiesTheBoxEveryTimeWhateverItHeld() {
            let made = qbMake()
            made.box.type("a dog on the beach")
            #expect(made.box.text == "a dog on the beach")
            made.box.clear()
            #expect(made.box.text == "", "the box still shows \"\(made.box.text)\" after the panel opened")

            // a second open of an already empty box leaves it empty
            made.box.clear()
            #expect(made.box.text == "")

            // typing again starts from nothing, not from the old text
            made.box.type("cat")
            #expect(made.box.text == "cat")
            made.box.clear()
            #expect(made.box.text == "")

            // a box holding a full 500 characters is emptied too
            made.box.paste(String(repeating: "z", count: 700))
            #expect(made.box.text.count == 500)
            made.box.clear()
            #expect(made.box.text == "")
            made.box.type("x")
            #expect(made.box.text == "x")
        }

        @MainActor
        @Test func openingThePanelIsNotAKeystrokeSoItTakesNoTicket() {
            let made = qbMake()
            made.box.type("ab")
            let before = made.tickets.issued
            made.box.clear()
            #expect(made.tickets.issued == before, "clear() took a ticket: \(made.tickets.issued)")
        }

        // MARK: typing

        @MainActor
        @Test func typingAddsOneCharacterPerKeystrokeAndEachChangeCarriesItsOwnTicket() {
            let made = qbMake(start: 700)
            made.box.type("dog")
            #expect(made.box.text == "dog")
            #expect(made.tickets.issued == [700, 701, 702], "tickets taken: \(made.tickets.issued)")
            #expect(made.changes.all.map(\.text) == ["d", "do", "dog"], "changes: \(made.changes.all.map(\.text))")
            #expect(made.changes.all.map(\.ticket) == [700, 701, 702], "tickets: \(made.changes.all.map(\.ticket))")

            made.box.type(" on")
            #expect(made.box.text == "dog on")
            #expect(made.changes.all.map(\.ticket) == [700, 701, 702, 703, 704, 705])
        }

        @MainActor
        @Test func deleteBackwardRemovesTheLastCharacterAsOneMoreKeystroke() {
            let made = qbMake(start: 10)
            made.box.type("dog")
            made.box.deleteBackward()
            #expect(made.box.text == "do")
            #expect(made.changes.all.last?.text == "do")
            #expect(made.changes.all.last?.ticket == 13)
            #expect(made.tickets.issued == [10, 11, 12, 13])
        }

        // MARK: the 500-character cut

        @MainActor
        @Test func textTypedBeyond500CharactersIsCutToItsFirst500AndTheCutTextIsShown() {
            let made = qbMake()
            // 505 distinct-enough characters, so a cut at the wrong place shows
            let long = String((0..<505).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
            made.box.type(long)
            #expect(made.box.text.count == 500, "the box shows \(made.box.text.count) characters")
            qbCheck(made.box.text, equals: qbFirst500(long), "505 typed characters")
            qbCheck(made.changes.all.last?.text, equals: qbFirst500(long), "the last change reported")

            // a keystroke into a full box adds nothing
            made.box.type("Q")
            qbCheck(made.box.text, equals: qbFirst500(long), "a keystroke into a full box")
            for change in made.changes.all {
                #expect(change.text.count <= 500, "a change reported \(change.text.count) characters")
            }
        }

        @MainActor
        @Test func exactly500CharactersAreKeptAnd499PlusOneIsNotCutEarly() {
            let made = qbMake()
            let at500 = String(repeating: "m", count: 500)
            made.box.paste(at500)
            qbCheck(made.box.text, equals: at500, "500 pasted characters")
            made.box.clear()
            made.box.paste(String(repeating: "m", count: 499))
            #expect(made.box.text.count == 499)
            made.box.type("n")
            qbCheck(made.box.text, equals: String(repeating: "m", count: 499) + "n", "499 pasted and one typed")
        }

        @MainActor
        @Test func pastedTextBeyond500IsCutToItsFirst500InOneChangeThatReportsTheCutText() {
            let made = qbMake(start: 40)
            let long = String(repeating: "abcdefghij", count: 60)   // 600 characters
            made.box.paste(long)
            qbCheck(made.box.text, equals: qbFirst500(long), "600 pasted characters")
            #expect(made.box.text.count == 500)
            #expect(made.changes.all.count == 1, "a paste is one change: \(made.changes.all.map(\.text.count))")
            qbCheck(made.changes.all.last?.text, equals: qbFirst500(long), "the change reported")
            let ticket = made.changes.all.last?.ticket
            #expect(ticket != nil && made.tickets.issued.contains(ticket!),
                    "the change carries ticket \(String(describing: ticket)); the box took \(made.tickets.issued)")
        }

        @MainActor
        @Test func pastingAfterExistingTextKeepsTheFirst500OfTheWholeThing() {
            let made = qbMake()
            made.box.type("a dog on the beach: ")
            let pasted = String(repeating: "0123456789", count: 60)
            made.box.paste(pasted)
            let whole = "a dog on the beach: " + pasted
            qbCheck(made.box.text, equals: qbFirst500(whole), "typed text then a 600 character paste")
            #expect(made.box.text.hasPrefix("a dog on the beach: 0123"))
            #expect(made.box.text.count == 500)

            // a second paste into the full box changes nothing
            made.box.paste("more")
            qbCheck(made.box.text, equals: qbFirst500(whole), "a paste into a full box")
        }

        @MainActor
        @Test func theCutCountsCharactersNotBytesOrUTF16Units() {
            let made = qbMake()
            // 499 plain characters then two dogs (one Character each, two UTF-16 units each, four bytes each):
            // the first 500 characters end after the first dog.
            let text = String(repeating: "a", count: 499) + "🐕🐕"
            made.box.paste(text)
            qbCheck(made.box.text, equals: String(repeating: "a", count: 499) + "🐕", "499 letters and two dogs")
            #expect(made.box.text.count == 500)

            // an accented letter written as two scalars counts as one character
            made.box.clear()
            let accented = String(repeating: "e\u{0301}", count: 300)   // 300 characters, 600 scalars
            made.box.paste(accented)
            #expect(made.box.text.count == 300, "the box shows \(made.box.text.count) characters of 300")
            qbCheck(made.box.text, equals: accented, "300 accented letters")
        }

        @MainActor
        @Test func theBoxNeverShowsMoreThan500CharactersWhateverIsDoneToIt() {
            let made = qbMake()
            made.box.paste(String(repeating: "x", count: 499))
            made.box.type("yy")
            made.box.paste(String(repeating: "w", count: 3))
            made.box.type("v")
            #expect(made.box.text.count == 500)
            qbCheck(made.box.text, equals: String(repeating: "x", count: 499) + "y", "499 pasted, then typed, pasted, typed")
            made.box.deleteBackward()
            qbCheck(made.box.text, equals: String(repeating: "x", count: 499), "after a delete")
        }
    }
}

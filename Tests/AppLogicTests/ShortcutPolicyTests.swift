import Foundation
import Testing
import SesameEngine

// Acceptance tests for plan-1-t25 (ShortcutPolicy).
// The closed list is written by hand from spec S1 "Error variants" and design section 6:
// refused are Command+Space, Command+Tab, Command+Q, Command+H, Command+W, Control+Command+Q and
// any shortcut without Command, Control or Option (a bare key, or Shift plus a key). The list is
// closed, so any other combination that holds Command, Control or Option is accepted.
//
// Contract these tests pin (the design fixes no signature). Everything is `public` in SesameEngine:
//   ShortcutPolicy.choose(_ proposed: String, keeping current: String) -> ShortcutChoice
//   struct ShortcutChoice { accepted: Bool, combination: String, message: String? }
//       accepted: combination is the one now in force (the proposed one, in any spelling of the same
//       keys); refused: combination == current, unchanged, and message is non-empty.
// A combination is a "+"-joined string in the form settings.json keeps it, lower case: modifiers
// `ctrl`, `opt`, `cmd`, `shift` in any order, then the key: "ctrl+opt+space", "cmd+opt+k".

private let current = "ctrl+opt+space"
private let otherCurrent = "opt+cmd+k"

private func keys(_ combo: String) -> [String] {
    combo.lowercased().split(separator: "+").map(String.init).sorted()
}

private func isBlank(_ s: String?) -> Bool {
    (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

@Suite("ShortcutPolicyTests")
struct ShortcutPolicyTests {

    // The six named combinations, each in the order the spec writes it and in the reverse order.
    @Test(arguments: [
        "cmd+space", "cmd+tab", "cmd+q", "cmd+h", "cmd+w", "ctrl+cmd+q",
    ])
    func theClosedListIsRefusedWithAMessageAndTheOldKeyStays(_ proposed: String) {
        let r = ShortcutPolicy.choose(proposed, keeping: current)
        #expect(r.accepted == false, "\(proposed)")
        #expect(!isBlank(r.message), "\(proposed) needs a message")
        #expect(r.combination == current, "\(proposed) must keep \(current)")
    }

    @Test func controlCommandQIsRefusedInEitherModifierOrder() {
        for proposed in ["ctrl+cmd+q", "cmd+ctrl+q"] {
            let r = ShortcutPolicy.choose(proposed, keeping: current)
            #expect(r.accepted == false, "\(proposed)")
            #expect(!isBlank(r.message))
            #expect(r.combination == current)
        }
    }

    @Test(arguments: [
        "k", "space", "tab", "f5", "q",
        "shift+k", "shift+space", "shift+tab", "shift+f5",
    ])
    func aShortcutWithoutCommandControlOrOptionIsRefused(_ proposed: String) {
        let r = ShortcutPolicy.choose(proposed, keeping: current)
        #expect(r.accepted == false, "\(proposed)")
        #expect(!isBlank(r.message), "\(proposed) needs a message")
        #expect(r.combination == current, "\(proposed) must keep \(current)")
    }

    @Test func theOldCombinationIsKeptWhateverItWas() {
        for old in [current, otherCurrent, "ctrl+cmd+k"] {
            for proposed in ["cmd+space", "shift+k", "k"] {
                let r = ShortcutPolicy.choose(proposed, keeping: old)
                #expect(r.accepted == false)
                #expect(r.combination == old, "kept \(r.combination), wanted \(old)")
            }
        }
    }

    @Test(arguments: [
        "opt+cmd+k", "cmd+opt+k", "ctrl+opt+space", "opt+ctrl+space",
    ])
    func theNamedGoodCombinationsAreAccepted(_ proposed: String) {
        let r = ShortcutPolicy.choose(proposed, keeping: "ctrl+cmd+k")
        #expect(r.accepted == true, "\(proposed)")
        #expect(keys(r.combination) == keys(proposed), "\(proposed) became \(r.combination)")
    }

    // The list is closed: a combination that is not on it and holds Command, Control or Option passes.
    @Test(arguments: [
        "cmd+k", "ctrl+q", "opt+space", "ctrl+space", "cmd+shift+q", "shift+cmd+h", "ctrl+cmd+space", "opt+tab",
    ])
    func anythingElseWithCommandControlOrOptionIsAccepted(_ proposed: String) {
        let r = ShortcutPolicy.choose(proposed, keeping: current)
        #expect(r.accepted == true, "\(proposed) is not on the closed list")
        #expect(keys(r.combination) == keys(proposed), "\(proposed) became \(r.combination)")
    }

    @Test func aRefusalAfterAnAcceptanceKeepsTheAcceptedOne() {
        let first = ShortcutPolicy.choose("opt+cmd+k", keeping: current)
        #expect(first.accepted == true)
        let second = ShortcutPolicy.choose("cmd+space", keeping: first.combination)
        #expect(second.accepted == false)
        #expect(second.combination == first.combination)
        #expect(keys(second.combination) == keys("opt+cmd+k"))
    }
}

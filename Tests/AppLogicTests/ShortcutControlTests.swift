import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step. Written from the t39 entry, spec S1 ("Choosing any of these shortcuts is refused with a
// message and the old shortcut stays", "the search box, result list ... have VoiceOver labels"), design sections 1, 6,
// 13 and the S1 feature map (S1.27 to S1.29) only; no product source read. The existing ShortcutPolicyTests (t25) and
// SettingsFileTests (t21) were read for the combination spelling and the settings value; nothing else.
//
// Everything here is pure logic. The panel, the Settings window and the hotkey are not launched (the person's rule:
// Sesame and its UI are never started from a test). What these tests do not reach is listed at the end of this note.
//
// SUITE PLACEMENT. ShortcutControl reads and writes settings.json under HOME, and HOME is process-wide, so this suite
// is nested inside `ModelDownloadTests` with the other HOME-touching suites and runs one at a time with them. Side
// effect: `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin (the design names `ShortcutControl`, "Back to default" and the labels, and fixes no
// signatures; if a shape is wrong, ask for a test change rather than guessing). All in the `Sesame` target.
//   A combination is the string of ShortcutPolicyTests: "+"-joined, lower case, modifiers `ctrl` `opt` `cmd` `shift`
//   in any order, then the key ("ctrl+opt+space", "opt+cmd+k"). Spelling and modifier order of a stored or reported
//   combination are not pinned: tests compare the sorted parts, as ShortcutPolicyTests does.
//   1. `ShortcutControl`, a final class, may be `@MainActor` (every test is). `init(onChange: @escaping (String) -> Void = { _ in })`.
//      It reads the combination in force from `settings.json` (through `SettingsFile`) when it is made; with no
//      settings.json it holds the default Control+Option+Space (S1.28: "on a fresh start ... Settings read 'Control Option Space'").
//      `onChange` is the one hook t39 connects to the app's hotkey registration; it is called with the new
//      combination after each change that was stored, and is not called for a refusal.
//   2. `var combination: String { get }` the combination in force. `var displayText: String { get }` what the control
//      shows: exactly "Control Option Space" for the default; for any other combination the modifier words
//      Control, Option, Shift, Command (each in full) then the key's name in capitals, separated by single spaces.
//   3. `var message: String? { get }` the control's status area: nil at the start; after a refusal the policy's
//      non-empty message; nil again after an accepted combination and after `backToDefault()`.
//   4. `func record(_ proposed: String)` is what the recorder calls with the key combination it saw. It goes
//      through `ShortcutPolicy.choose(_:keeping:)` (t25). Accepted: `combination`, `displayText` and `settings.json`
//      `hotkey` change to it, every other settings field stays as it was, `onChange` is called once with it,
//      `message` is nil. Refused: `message` is set, `combination`, `displayText` and the stored `hotkey` stay as
//      they were, nothing is written that changes a field, `onChange` is not called.
//   5. `func backToDefault()` (the "Back to default" button) does the accepted path with Control+Option+Space.
//   6. `static let defaultCombination`, `static let recordTitle = "Record new shortcut"`,
//      `static let backToDefaultTitle = "Back to default"` (the labels the kit clicks by, feature map S1.27), and
//      `static let accessibilityLabel: String` (the shortcut control's VoiceOver label).
//   7. `AccessibilityLabels` (an enum with static members): `searchBox` "Search your files", `resultList` "Results",
//      `preview` "Preview" (the panel's labels, t39 entry), and `static func resultRow(name: String, kind: String) -> String`,
//      a row's label: it holds the name then the kind. The exact joining text is not pinned.
//   8. `SettingsWindow` (an enum with static members here, no window made): `title` "Settings" (the kit's
//      `tab-walk "Settings"`), `controlLabels: [String]` the accessibility labels of the controls it holds (only the
//      shortcut control), `static func isOpenCommand(_ combination: String) -> Bool` true for Command+comma written
//      "cmd+," or "cmd+comma" and for nothing else.
//   9. Not pinned, on purpose: the recording state of the control (whether it waits for a key after a refusal), how
//      a key event becomes a combination string, the order of modifier words for a non-default display, the joining
//      text of a row label, the wording of any refusal message.
//
// NOT REACHED here (the kit checks S1.1, S1.27, S1.28, S1.29 and a person): that the panel, list, pane and control
// really carry these labels in the accessibility tree; keyboard reach and Tab order (`kit-ax.sh tab-walk`); that
// Command+comma opens the window in the running app; that a recorded combination re-registers the Carbon hotkey (the
// AppDelegate wiring: only the `onChange` call is tested); macOS-owned keys the recorder never receives.

private let scDefaultKeys = ["ctrl", "opt", "space"].sorted()
private let scOptCmdKKeys = ["cmd", "k", "opt"].sorted()

private func scKeys(_ combo: String) -> [String] {
    combo.lowercased().split(separator: "+").map(String.init).sorted()
}

private func scBlank(_ s: String?) -> Bool {
    (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private final class SCCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ combination: String) { lock.lock(); list.append(combination); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

private struct SCEnv {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var settings: URL { folder.appendingPathComponent("settings.json") }

    // settings.json as it is on disk, nil when there is none.
    func onDisk() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    // The stored hotkey as sorted parts, nil when the file or the key is absent.
    func storedKeys() -> [String]? {
        guard let text = onDisk()?["hotkey"] as? String, !text.isEmpty else { return nil }
        return scKeys(text)
    }
}

// Sets HOME to a fresh folder, makes the Sesame folder, runs the body, puts HOME back.
@MainActor
private func scRun(_ body: @MainActor (SCEnv) throws -> Void) throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-shortcut-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let env = SCEnv(home: home)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try body(env)
}

// Settings a person might already have, written here by hand from design section 1 so nothing in it comes from the
// code under test. Every field but hotkey is distinctive, so a write that resets one shows.
private func scSeedJSON(hotkey: String) -> String {
    """
    {
      "version": 3,
      "startPressed": true,
      "indexDeleted": false,
      "folders": [{"path": "/Users/test/Pictures", "code": false, "reading": true}],
      "codeSearchOn": true,
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "hotkey": "\(hotkey)",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5, "pdf": 2.25},
      "loginDefaultApplied": true
    }
    """
}

private func scDecode<T: Decodable>(like _: T, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func scSeed(hotkey: String) throws {
    let file = SettingsFile()
    try file.write(try scDecode(like: try file.read(), scSeedJSON(hotkey: hotkey)))
}

// What settings.json must still hold after a hotkey change: the seed's fields other than hotkey, as the test wrote them.
private func scSeedWithoutHotkey() throws -> NSDictionary {
    let all = try #require(try JSONSerialization.jsonObject(with: Data(scSeedJSON(hotkey: "x").utf8)) as? NSDictionary)
    let copy = NSMutableDictionary(dictionary: all)
    copy.removeObject(forKey: "hotkey")
    return copy
}

private func scOnDiskWithoutHotkey(_ env: SCEnv) throws -> NSDictionary {
    let disk = try #require(env.onDisk(), "settings.json is missing")
    let copy = NSMutableDictionary(dictionary: disk)
    copy.removeObject(forKey: "hotkey")
    return copy
}

private func scWords(_ text: String) -> [String] {
    text.split(separator: " ").map(String.init)
}

extension ModelDownloadTests {
    @Suite("ShortcutControlTests", .serialized)
    struct ShortcutControlTests {

        // MARK: the default

        @MainActor
        @Test func aFreshControlReadsControlOptionSpaceWithNoMessage() throws {
            try scRun { env in
                let control = ShortcutControl()
                #expect(scKeys(control.combination) == scDefaultKeys, "combination \(control.combination)")
                #expect(control.displayText == "Control Option Space", "the control reads \"\(control.displayText)\"")
                #expect(control.message == nil, "a message with nothing wrong: \(String(describing: control.message))")
                #expect(scKeys(ShortcutControl.defaultCombination) == scDefaultKeys)
                _ = env
            }
        }

        @MainActor
        @Test func aControlReadsTheCombinationSettingsJsonHolds() throws {
            try scRun { _ in
                try scSeed(hotkey: "opt+cmd+k")
                let control = ShortcutControl()
                #expect(scKeys(control.combination) == scOptCmdKKeys, "combination \(control.combination)")
                // the words are Option, Command and the key, whatever order they come in; the key's name ends it
                #expect(Set(scWords(control.displayText)) == ["Option", "Command", "K"], "reads \"\(control.displayText)\"")
                #expect(scWords(control.displayText).last == "K", "reads \"\(control.displayText)\"")
            }
        }

        // MARK: the closed list is refused with a message and the old combination stays

        @MainActor
        @Test(arguments: [
            "cmd+space", "cmd+tab", "cmd+q", "cmd+h", "cmd+w", "ctrl+cmd+q", "cmd+ctrl+q",
            "k", "space", "f5", "shift+k", "shift+space",
        ])
        func eachRefusalOfTheClosedListShowsAMessageAndKeepsTheOldCombination(_ proposed: String) throws {
            for old in ["ctrl+opt+space", "opt+cmd+k"] {
                try scRun { env in
                    try scSeed(hotkey: old)
                    let calls = SCCalls()
                    let control = ShortcutControl(onChange: { calls.add($0) })
                    let shownBefore = control.displayText

                    control.record(proposed)

                    #expect(!scBlank(control.message), "\(proposed) over \(old) shows no message")
                    #expect(scKeys(control.combination) == scKeys(old), "\(proposed) replaced \(old) with \(control.combination)")
                    #expect(control.displayText == shownBefore, "\(proposed) changed the control to \"\(control.displayText)\"")
                    #expect(env.storedKeys() == scKeys(old), "settings.json hotkey became \(String(describing: env.storedKeys()))")
                    #expect(calls.all.isEmpty, "onChange was called for a refusal: \(calls.all)")
                    #expect(try scOnDiskWithoutHotkey(env) == scSeedWithoutHotkey(), "a refusal changed another settings field")
                }
            }
        }

        @MainActor
        @Test func aRefusalOnAFreshStartKeepsTheDefaultAndStoresNothingElse() throws {
            try scRun { env in
                let calls = SCCalls()
                let control = ShortcutControl(onChange: { calls.add($0) })
                control.record("cmd+space")
                #expect(!scBlank(control.message))
                #expect(scKeys(control.combination) == scDefaultKeys)
                #expect(control.displayText == "Control Option Space")
                // nothing stored, or the default stored: never the refused key
                if let stored = env.storedKeys() { #expect(stored == scDefaultKeys, "stored \(stored)") }
                #expect(calls.all.isEmpty)
                // a second control made afterwards still reads the default
                #expect(ShortcutControl().displayText == "Control Option Space")
            }
        }

        // MARK: Option+Command+K is accepted and stored in settings.json

        @MainActor
        @Test func optionCommandKIsAcceptedAndStoredInSettingsJson() throws {
            try scRun { env in
                try scSeed(hotkey: "ctrl+opt+space")
                let calls = SCCalls()
                let control = ShortcutControl(onChange: { calls.add($0) })

                control.record("opt+cmd+k")

                #expect(scKeys(control.combination) == scOptCmdKKeys, "combination \(control.combination)")
                #expect(Set(scWords(control.displayText)) == ["Option", "Command", "K"], "reads \"\(control.displayText)\"")
                #expect(control.message == nil, "a message after an accepted key: \(String(describing: control.message))")
                #expect(env.storedKeys() == scOptCmdKKeys, "settings.json hotkey is \(String(describing: env.onDisk()?["hotkey"]))")
                #expect(try scOnDiskWithoutHotkey(env) == scSeedWithoutHotkey(), "an accepted key changed another settings field")
                #expect(calls.all.count == 1, "onChange calls: \(calls.all)")
                #expect(calls.all.map(scKeys) == [scOptCmdKKeys])

                // a control made later, as at the next launch, reads the stored combination
                let later = ShortcutControl()
                #expect(scKeys(later.combination) == scOptCmdKKeys)
                #expect(Set(scWords(later.displayText)) == ["Option", "Command", "K"])
            }
        }

        @MainActor
        @Test func theOtherSpellingOfTheSameKeysIsAcceptedToo() throws {
            try scRun { env in
                let control = ShortcutControl()
                control.record("cmd+opt+k")
                #expect(control.message == nil)
                #expect(scKeys(control.combination) == scOptCmdKKeys)
                #expect(env.storedKeys() == scOptCmdKKeys)
            }
        }

        // The list is closed: a combination that is not on it and holds Command, Control or Option passes the control too.
        @MainActor
        @Test(arguments: ["cmd+k", "ctrl+q", "opt+space", "cmd+shift+q"])
        func anythingOffTheClosedListWithCommandControlOrOptionIsAccepted(_ proposed: String) throws {
            try scRun { env in
                let control = ShortcutControl()
                control.record(proposed)
                #expect(control.message == nil, "\(proposed) was refused: \(String(describing: control.message))")
                #expect(scKeys(control.combination) == scKeys(proposed))
                #expect(env.storedKeys() == scKeys(proposed))
            }
        }

        // MARK: a refusal after an acceptance keeps the accepted one; an acceptance clears the message

        @MainActor
        @Test func aRefusalAfterAnAcceptanceKeepsTheAcceptedCombinationInTheControlAndInTheFile() throws {
            try scRun { env in
                try scSeed(hotkey: "ctrl+opt+space")
                let calls = SCCalls()
                let control = ShortcutControl(onChange: { calls.add($0) })
                control.record("opt+cmd+k")
                control.record("cmd+space")

                #expect(!scBlank(control.message))
                #expect(scKeys(control.combination) == scOptCmdKKeys, "kept \(control.combination)")
                #expect(env.storedKeys() == scOptCmdKKeys)
                #expect(calls.all.count == 1, "onChange calls: \(calls.all)")
                #expect(Set(scWords(control.displayText)) == ["Option", "Command", "K"])
            }
        }

        @MainActor
        @Test func anAcceptedCombinationClearsTheMessageAnEarlierRefusalLeft() throws {
            try scRun { _ in
                let control = ShortcutControl()
                control.record("shift+k")
                #expect(!scBlank(control.message))
                control.record("opt+cmd+k")
                #expect(control.message == nil, "the old refusal text stayed: \(String(describing: control.message))")
            }
        }

        // MARK: Back to default

        @MainActor
        @Test func backToDefaultRestoresControlOptionSpaceAndStoresIt() throws {
            try scRun { env in
                try scSeed(hotkey: "ctrl+opt+space")
                let calls = SCCalls()
                let control = ShortcutControl(onChange: { calls.add($0) })
                control.record("opt+cmd+k")
                #expect(control.displayText != "Control Option Space")

                control.backToDefault()

                #expect(scKeys(control.combination) == scDefaultKeys, "combination \(control.combination)")
                #expect(control.displayText == "Control Option Space", "the control reads \"\(control.displayText)\"")
                #expect(control.message == nil)
                #expect(env.storedKeys() == scDefaultKeys, "settings.json hotkey is \(String(describing: env.onDisk()?["hotkey"]))")
                #expect(try scOnDiskWithoutHotkey(env) == scSeedWithoutHotkey(), "Back to default changed another settings field")
                #expect(calls.all.count == 2, "onChange calls: \(calls.all)")
                #expect(calls.all.last.map(scKeys) == scDefaultKeys, "the last onChange was \(String(describing: calls.all.last))")

                // the next launch reads the default
                #expect(ShortcutControl().displayText == "Control Option Space")
            }
        }

        @MainActor
        @Test func backToDefaultAlsoClearsARefusalMessage() throws {
            try scRun { _ in
                try scSeed(hotkey: "opt+cmd+k")
                let control = ShortcutControl()
                control.record("cmd+q")
                #expect(!scBlank(control.message))
                control.backToDefault()
                #expect(control.message == nil)
                #expect(control.displayText == "Control Option Space")
            }
        }

        @MainActor
        @Test func backToDefaultOnTheDefaultLeavesTheDefaultInForce() throws {
            try scRun { env in
                let control = ShortcutControl()
                control.backToDefault()
                #expect(control.displayText == "Control Option Space")
                #expect(scKeys(control.combination) == scDefaultKeys)
                if let stored = env.storedKeys() { #expect(stored == scDefaultKeys) }
            }
        }

        // MARK: the labels the panel and the Settings window carry (S1.1, S1.29, t39 entry)

        @MainActor @Test func thePanelLabelsAreTheDesignsWords() {
            #expect(AccessibilityLabels.searchBox == "Search your files")
            #expect(AccessibilityLabels.resultList == "Results")
            #expect(AccessibilityLabels.preview == "Preview")
        }

        @MainActor @Test func theShortcutControlHasALabelThatIsNotABareRoleWordAndDiffersFromThePanelLabels() {
            let label = ShortcutControl.accessibilityLabel
            #expect(!scBlank(label))
            #expect(label.lowercased().contains("shortcut"), "label \"\(label)\" does not say what the control is for")
            for bare in ["button", "text field", "group", "static text"] {
                #expect(label.lowercased() != bare, "label is a bare role word: \(label)")
            }
            #expect(label != AccessibilityLabels.searchBox)
            #expect(label != AccessibilityLabels.resultList)
            #expect(label != AccessibilityLabels.preview)
        }

        @MainActor @Test func theButtonsCarryTheTitlesTheKitClicksBy() {
            #expect(ShortcutControl.recordTitle == "Record new shortcut")
            #expect(ShortcutControl.backToDefaultTitle == "Back to default")
        }

        @MainActor @Test func aResultRowLabelHoldsItsNameThenItsKind() {
            let label = AccessibilityLabels.resultRow(name: "beach-dog.jpg", kind: "photo")
            let name = label.range(of: "beach-dog.jpg")
            let kind = label.range(of: "photo")
            #expect(name != nil, "row label \"\(label)\" lacks the name")
            #expect(kind != nil, "row label \"\(label)\" lacks the kind")
            if let name, let kind {
                #expect(name.lowerBound < kind.lowerBound, "row label \"\(label)\" gives the kind before the name")
            }
        }

        @MainActor @Test func rowLabelsOfDifferentFilesDiffer() {
            let a = AccessibilityLabels.resultRow(name: "beach-dog.jpg", kind: "photo")
            let b = AccessibilityLabels.resultRow(name: "snow-cat.png", kind: "photo")
            let c = AccessibilityLabels.resultRow(name: "beach-dog.jpg", kind: "pdf")
            #expect(a != b)
            #expect(a != c)
            #expect(b.contains("snow-cat.png") && !b.contains("beach-dog.jpg"))
            #expect(c.contains("pdf") && !c.contains("photo"))
        }

        // MARK: the Settings window decision (Command+comma opens a minimal window holding only the shortcut control)

        @MainActor @Test func settingsOpensOnCommandCommaAndOnNothingElse() {
            #expect(SettingsWindow.isOpenCommand("cmd+,"))
            #expect(SettingsWindow.isOpenCommand("cmd+comma"))
            for other in ["cmd+k", "cmd+.", "cmd+shift+,", "ctrl+,", "opt+,", ",", "cmd+space", "ctrl+opt+space", ""] {
                #expect(!SettingsWindow.isOpenCommand(other), "\(other) opened Settings")
            }
        }

        @MainActor @Test func theSettingsWindowIsTitledSettingsAndHoldsOnlyTheShortcutControl() {
            #expect(SettingsWindow.title == "Settings")
            #expect(SettingsWindow.controlLabels == [ShortcutControl.accessibilityLabel],
                    "controls: \(SettingsWindow.controlLabels)")
        }

        // MARK: plan-2-t4 (carry-over R4): a shortcut that fell back to the default is shown once and stored
        //
        // Tester step of plan-2-t4, written from the plan-2-t4 entry, design sections 1 and 6 and Decision D6 only; no
        // product source read. The tests above are untouched and must stay green.
        //
        // API SHAPES pinned here (new, in `Sesame`; if a shape is wrong, ask for a test change rather than guessing).
        //   1. `@MainActor func adoptLive(_ live: String, refused: String)` on `ShortcutControl`, not throwing. `live` is the
        //      combination that registered (the default), `refused` the saved one macOS refused. It makes `live` the
        //      combination in force: `settings.json` `hotkey` becomes `live` through `SettingsFile` with no other field
        //      changed, `combination` and `displayText` read it. It also queues the one notice below. Whether it calls
        //      `onChange` is NOT pinned (the live key is already registered).
        //   2. `func takeNotice() -> String?` returns the queued notice and clears it: the text the first time, nil every
        //      later time, and nil on a control that adopted nothing. The text for a refused `opt+cmd+k` is exactly
        //      "The shortcut Option Command K is taken by another app, so Sesame is using Control Option Space."; for any
        //      other refused combination the words are the ones `displayText` builds for it.
        //   3. `static let notSavedText: String` (not blank): the notice given instead when the write of settings.json
        //      fails. The live combination stays in force in the control, the old file is kept byte for byte.
        //   A failed write is made here with a read-only Sesame folder and a read-only settings.json (design section 1:
        //   the app writes a temp file, then renames it).

        @MainActor
        @Test func adoptLiveStoresTheLiveCombinationAndChangesNothingElseInSettingsJson() throws {
            try scRun { env in
                try scSeed(hotkey: "opt+cmd+k")
                let control = ShortcutControl()
                #expect(Set(scWords(control.displayText)) == ["Option", "Command", "K"], "before: \"\(control.displayText)\"")

                control.adoptLive("ctrl+opt+space", refused: "opt+cmd+k")

                #expect(env.storedKeys() == scDefaultKeys, "settings.json hotkey is \(String(describing: env.onDisk()?["hotkey"]))")
                #expect(try scOnDiskWithoutHotkey(env) == scSeedWithoutHotkey(), "adoptLive changed another settings field")
                #expect(scKeys(control.combination) == scDefaultKeys, "combination \(control.combination)")
                #expect(control.displayText == "Control Option Space", "the control reads \"\(control.displayText)\"")

                // a control made later, as at the next launch, reads the live combination and has nothing to tell
                let later = ShortcutControl()
                #expect(scKeys(later.combination) == scDefaultKeys)
                #expect(later.displayText == "Control Option Space")
                #expect(later.takeNotice() == nil, "a later control showed a notice: \(String(describing: later.takeNotice()))")
            }
        }

        @MainActor
        @Test func theNoticeNamesTheRefusedAndTheLiveShortcutAndComesExactlyOnce() throws {
            try scRun { _ in
                try scSeed(hotkey: "opt+cmd+k")
                let control = ShortcutControl()

                control.adoptLive("ctrl+opt+space", refused: "opt+cmd+k")

                let first = control.takeNotice()
                #expect(first == "The shortcut Option Command K is taken by another app, so Sesame is using Control Option Space.",
                        "notice: \(String(describing: first))")
                #expect(control.takeNotice() == nil, "the notice came a second time")
                #expect(control.takeNotice() == nil, "the notice came a third time")
            }
        }

        @MainActor
        @Test func aControlThatAdoptedNothingHasNoNotice() throws {
            try scRun { _ in
                try scSeed(hotkey: "opt+cmd+k")
                #expect(ShortcutControl().takeNotice() == nil)
                let fresh = ShortcutControl()
                fresh.record("cmd+k")
                fresh.backToDefault()
                #expect(fresh.takeNotice() == nil, "an ordinary change queued a notice")
            }
        }

        // The words of the refused combination are built as `displayText` builds them: the test reads them from a control
        // that holds that combination, so no modifier order is assumed here.
        @MainActor
        @Test(arguments: ["cmd+shift+j", "ctrl+cmd+k"])
        func theNoticeUsesTheWordsDisplayTextBuildsForTheRefusedCombination(_ refused: String) throws {
            try scRun { _ in
                try scSeed(hotkey: refused)
                let control = ShortcutControl()
                let words = control.displayText
                #expect(words != "Control Option Space", "the seed was not read: \(words)")

                control.adoptLive("ctrl+opt+space", refused: refused)

                let notice = control.takeNotice()
                #expect(notice == "The shortcut \(words) is taken by another app, so Sesame is using Control Option Space.",
                        "notice: \(String(describing: notice))")
            }
        }

        @MainActor
        @Test func aFailedWriteLeavesTheLiveCombinationInForceKeepsTheOldFileAndGivesTheNotSavedNotice() throws {
            try scRun { env in
                try scSeed(hotkey: "opt+cmd+k")
                let control = ShortcutControl()
                let before = try Data(contentsOf: env.settings)

                let fm = FileManager.default
                try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: env.settings.path)
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.folder.path)
                defer {
                    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.folder.path)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.settings.path)
                }
                try #require(!fm.isWritableFile(atPath: env.folder.path), "the Sesame folder is still writable, so a failed write cannot be made here")

                control.adoptLive("ctrl+opt+space", refused: "opt+cmd+k")

                #expect(scKeys(control.combination) == scDefaultKeys, "the live combination is not in force: \(control.combination)")
                #expect(control.displayText == "Control Option Space", "the control reads \"\(control.displayText)\"")
                #expect(try Data(contentsOf: env.settings) == before, "the old settings.json was changed")
                #expect(env.storedKeys() == scOptCmdKKeys, "stored hotkey: \(String(describing: env.storedKeys()))")

                #expect(!scBlank(ShortcutControl.notSavedText), "notSavedText is blank")
                let notice = control.takeNotice()
                #expect(notice == ShortcutControl.notSavedText, "notice: \(String(describing: notice))")
                #expect(control.takeNotice() == nil, "the notice came a second time")
            }
        }
    }
}

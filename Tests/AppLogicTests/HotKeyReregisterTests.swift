import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t39, tester step for defect 4 of the real-app batch (tasks 36 to 39): after `alt+cmd+k` was accepted in the
// shortcut control, the kit found that the old default (Control+Option+Space) still opened the panel (S1.27 "a
// combination outside the list (Option+Command+K) is accepted, opens the panel, and the old default no longer does").
// The batch also noted the control and settings.json show the new combination while the old one stays registered.
//
// Written from spec S1 ("Choosing any of these shortcuts is refused with a message and the old shortcut stays"),
// design section 6 ("Hotkey: ... a taken key keeps the old one") and section 2 (Hotkey: Carbon `RegisterEventHotKey`),
// and S1.27 of the feature map. The product source was read only for names and for where the registration lives:
// `AppDelegate` registers and unregisters through Carbon in private methods, and `ShortcutControl` only calls `onChange`
// after it stored the new combination. Reading it showed the current `AppDelegate.register` already unregisters the old
// reference before it registers the new one, so the real cause may not be this ordering (see the report); these tests
// pin the behaviour a person needs, through a seam a unit can reach.
//
// SUITE PLACEMENT. ShortcutControl reads and writes settings.json under HOME, so the suite is nested inside
// `ModelDownloadTests` with the other HOME-touching suites.
//
// API SHAPES these tests pin (new; if a shape is wrong, ask for a test change rather than guessing). All in the `Sesame`
// target.
//   1. `protocol HotKeyRegistrar` with
//        `func register(_ combination: String) -> Bool`  registers the combination (the settings.json spelling, such as
//           "ctrl+opt+space"); true when it is in force, false when it could not be registered (macOS refused it, or
//           the text is not a combination). A failed `register` leaves nothing of that call registered.
//        `func unregister()`  takes away whatever this registrar has registered; harmless when nothing is.
//      The protocol may be `@MainActor`; every test here is. Registering twice without `unregister` leaves BOTH in
//      force (that is how Carbon behaves, and what the fake below models): the defect.
//   2. `ShortcutControl.init(registrar: any HotKeyRegistrar, onChange: @escaping (String) -> Void = { _ in })`. The
//      existing `ShortcutControl()` and `ShortcutControl(onChange:)` keep working and behave as before (a control with
//      no registrar registers nothing). The registrar is told of the combination in force at launch by the caller (the
//      app delegate registers the stored combination at launch); the control does not register at init.
//   3. On every accepted change (`record` of an acceptable combination, and `backToDefault()`), in this order: the
//      registrar's `unregister()`, then `register(new)`. If `register(new)` returns true: the combination, the display
//      text and settings.json `hotkey` become the new one, `message` is nil and `onChange(new)` is called once. If it
//      returns false: the old combination is registered again (`register(old)`), the control's `combination` and
//      `displayText` and settings.json `hotkey` stay the old one, no other settings field changes, `onChange` is not
//      called, and `message` is a non-empty text (the old shortcut stays and the person is told).
//   4. A refusal by the policy (the closed list) never reaches the registrar: no `unregister`, no `register`, so the
//      old combination stays in force untouched.
//   5. `final class CarbonHotKeyRegistrar: HotKeyRegistrar` is the app's real one (the Carbon code now in `AppDelegate`).
//      Only what needs no system call is tested: `register("not a combination")` is false and registers nothing, and
//      `unregister()` with nothing registered is harmless. `init()` takes no arguments.
//
// NOT REACHED here (the real app only): that a real Carbon registration is released by `unregister()`, that macOS
// refuses a combination another app took, and that the old combination really stops opening the panel (S1.27, the kit's
// `hotkey` check). A unit test must not register a real system hotkey.

private func hkKeys(_ combination: String) -> [String] {
    combination.lowercased().split(separator: "+").map(String.init).sorted()
}

private let hkDefault = ["ctrl", "opt", "space"].sorted()
private let hkOptCmdK = ["cmd", "k", "opt"].sorted()
private let hkCmdK = ["cmd", "k"].sorted()

/// A registrar that models Carbon: every successful `register` adds a registration that stays until `unregister()`.
@MainActor
private final class HKFakeRegistrar: HotKeyRegistrar {
    private(set) var events: [String] = []
    /// Combinations in force right now, as sorted parts, in the order they were registered.
    private(set) var live: [[String]] = []
    /// Combinations (sorted parts) macOS refuses.
    var refuses: Set<[String]> = []

    init(alreadyRegistered combination: String? = nil) {
        if let combination { live = [hkKeys(combination)] }
    }

    func register(_ combination: String) -> Bool {
        events.append("register " + hkKeys(combination).joined(separator: "+"))
        if refuses.contains(hkKeys(combination)) { return false }
        live.append(hkKeys(combination))
        return true
    }

    func unregister() {
        events.append("unregister")
        live = []
    }
}

private final class HKCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ combination: String) { lock.lock(); list.append(combination); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

private struct HKEnv {
    let home: URL
    var settings: URL { home.appendingPathComponent("Library/Application Support/Sesame/settings.json") }

    func onDisk() -> NSDictionary? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    func storedKeys() -> [String]? {
        guard let text = onDisk()?["hotkey"] as? String, !text.isEmpty else { return nil }
        return hkKeys(text)
    }

    func withoutHotkey() -> NSDictionary? {
        guard let disk = onDisk() else { return nil }
        let copy = NSMutableDictionary(dictionary: disk)
        copy.removeObject(forKey: "hotkey")
        return copy
    }
}

@MainActor
private func hkRun(storedHotkey: String = "ctrl+opt+space", _ body: @MainActor (HKEnv) throws -> Void) throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-hotkey-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    // Settings written by hand from design section 1; every field but hotkey is distinctive.
    let seed = """
    {
      "version": 3, "startPressed": true, "indexDeleted": false,
      "folders": [{"path": "/Users/test/Pictures", "code": false, "reading": true}],
      "codeSearchOn": true,
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "hotkey": "\(storedHotkey)",
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5, "pdf": 2.25},
      "loginDefaultApplied": true
    }
    """
    let file = SettingsFile()
    try file.write(try JSONDecoder().decode(Settings.self, from: Data(seed.utf8)))
    try body(HKEnv(home: home))
}

private func hkBlank(_ text: String?) -> Bool {
    (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

extension ModelDownloadTests {
    @Suite("HotKeyReregisterTests", .serialized)
    struct HotKeyReregisterTests {

        // MARK: a change takes the old combination away and puts the new one in force

        @MainActor
        @Test func anAcceptedChangeUnregistersTheOldThenRegistersTheNewSoOnlyTheNewIsInForce() throws {
            try hkRun { env in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                let calls = HKCalls()
                let control = ShortcutControl(registrar: registrar, onChange: { calls.add($0) })

                control.record("opt+cmd+k")

                #expect(registrar.live == [hkOptCmdK], "in force after the change: \(registrar.live) (the old default must be gone)")
                #expect(registrar.events == ["unregister", "register " + hkOptCmdK.joined(separator: "+")],
                        "calls in order: \(registrar.events)")
                #expect(hkKeys(control.combination) == hkOptCmdK)
                #expect(env.storedKeys() == hkOptCmdK)
                #expect(control.message == nil)
                #expect(calls.all.map(hkKeys) == [hkOptCmdK], "onChange: \(calls.all)")
            }
        }

        @MainActor
        @Test func backToDefaultUnregistersTheChosenCombinationAndRegistersTheDefault() throws {
            try hkRun(storedHotkey: "opt+cmd+k") { env in
                let registrar = HKFakeRegistrar(alreadyRegistered: "opt+cmd+k")
                let control = ShortcutControl(registrar: registrar)

                control.backToDefault()

                #expect(registrar.live == [hkDefault], "in force after Back to default: \(registrar.live)")
                #expect(registrar.events.first == "unregister", "calls: \(registrar.events)")
                #expect(hkKeys(control.combination) == hkDefault)
                #expect(env.storedKeys() == hkDefault)
            }
        }

        @MainActor
        @Test func severalChangesInARowLeaveExactlyOneCombinationInForceEachTime() throws {
            try hkRun { _ in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                let control = ShortcutControl(registrar: registrar)
                for (proposed, keys) in [("opt+cmd+k", hkOptCmdK), ("cmd+k", hkCmdK), ("ctrl+opt+space", hkDefault)] {
                    control.record(proposed)
                    #expect(registrar.live == [keys], "after \(proposed) in force: \(registrar.live)")
                }
            }
        }

        @MainActor
        @Test func choosingTheCombinationAlreadyInForceLeavesItRegisteredOnce() throws {
            try hkRun { _ in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                let control = ShortcutControl(registrar: registrar)
                control.record("ctrl+opt+space")
                #expect(registrar.live == [hkDefault], "in force: \(registrar.live)")
                #expect(control.message == nil)
            }
        }

        // MARK: macOS refuses the new combination: the old one comes back, in the control and in settings.json

        @MainActor
        @Test func aCombinationThatCannotBeRegisteredKeepsTheOldOneInForceInTheControlAndInSettings() throws {
            try hkRun { env in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                registrar.refuses = [hkOptCmdK]
                let calls = HKCalls()
                let control = ShortcutControl(registrar: registrar, onChange: { calls.add($0) })
                let shownBefore = control.displayText

                control.record("opt+cmd+k")

                #expect(registrar.live == [hkDefault], "in force after a refused registration: \(registrar.live) (the old one must be back)")
                #expect(registrar.events.first == "unregister")
                #expect(registrar.events.contains("register " + hkOptCmdK.joined(separator: "+")), "calls: \(registrar.events)")
                #expect(registrar.events.last == "register " + hkDefault.joined(separator: "+"), "the old one is put back last: \(registrar.events)")
                #expect(hkKeys(control.combination) == hkDefault, "the control says \(control.combination)")
                #expect(control.displayText == shownBefore, "the control reads \"\(control.displayText)\"")
                #expect(env.storedKeys() == hkDefault, "settings.json hotkey is \(String(describing: env.onDisk()?["hotkey"]))")
                #expect(!hkBlank(control.message), "the person is not told: \(String(describing: control.message))")
                #expect(calls.all.isEmpty, "onChange was called for a refused registration: \(calls.all)")
                let seedWithout = try hkSeedWithoutHotkey()
                #expect(env.withoutHotkey() == seedWithout, "a refused registration changed another settings field")
            }
        }

        @MainActor
        @Test func aRefusedRegistrationAfterAnAcceptedOneKeepsTheAcceptedOne() throws {
            try hkRun { env in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                registrar.refuses = [hkCmdK]
                let control = ShortcutControl(registrar: registrar)
                control.record("opt+cmd+k")
                control.record("cmd+k")

                #expect(registrar.live == [hkOptCmdK], "in force: \(registrar.live)")
                #expect(hkKeys(control.combination) == hkOptCmdK)
                #expect(env.storedKeys() == hkOptCmdK)
                #expect(!hkBlank(control.message))
            }
        }

        @MainActor
        @Test func aSuccessfulChangeAfterARefusedOneClearsTheMessage() throws {
            try hkRun { _ in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                registrar.refuses = [hkCmdK]
                let control = ShortcutControl(registrar: registrar)
                control.record("cmd+k")
                #expect(!hkBlank(control.message))
                control.record("opt+cmd+k")
                #expect(control.message == nil, "the old message stayed: \(String(describing: control.message))")
                #expect(registrar.live == [hkOptCmdK])
            }
        }

        // MARK: a refusal by the closed list never touches the registration

        @MainActor
        @Test(arguments: ["cmd+space", "cmd+tab", "cmd+q", "cmd+h", "cmd+w", "ctrl+cmd+q", "k", "shift+k", "f5"])
        func aRefusalByTheClosedListLeavesTheOldCombinationRegisteredAndTouchesNothing(_ proposed: String) throws {
            try hkRun { env in
                let registrar = HKFakeRegistrar(alreadyRegistered: "ctrl+opt+space")
                let control = ShortcutControl(registrar: registrar)

                control.record(proposed)

                #expect(registrar.events.isEmpty, "\(proposed) reached the registrar: \(registrar.events)")
                #expect(registrar.live == [hkDefault], "in force: \(registrar.live)")
                #expect(!hkBlank(control.message))
                #expect(env.storedKeys() == hkDefault)
            }
        }

        // MARK: the app's own registrar (only what needs no system call)

        @MainActor
        @Test func theCarbonRegistrarRefusesTextThatIsNotACombinationAndUnregisterWithNothingRegisteredIsHarmless() {
            let registrar = CarbonHotKeyRegistrar()
            registrar.unregister()
            #expect(registrar.register("not a combination") == false)
            #expect(registrar.register("") == false)
            #expect(registrar.register("ctrl+opt") == false, "modifiers alone are not a combination")
            registrar.unregister()
        }

        // MARK: a control without a registrar behaves as before

        @MainActor
        @Test func aControlMadeWithoutARegistrarStillChangesAndStoresTheCombination() throws {
            try hkRun { env in
                let calls = HKCalls()
                let control = ShortcutControl(onChange: { calls.add($0) })
                control.record("opt+cmd+k")
                #expect(hkKeys(control.combination) == hkOptCmdK)
                #expect(env.storedKeys() == hkOptCmdK)
                #expect(calls.all.map(hkKeys) == [hkOptCmdK])
            }
        }
    }
}

private func hkSeedWithoutHotkey() throws -> NSDictionary {
    let seed = """
    {
      "version": 3, "startPressed": true, "indexDeleted": false,
      "folders": [{"path": "/Users/test/Pictures", "code": false, "reading": true}],
      "codeSearchOn": true,
      "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
      "openWith": {"pdf": "Preview", "media": "QuickTime Player", "code": "VS Code"},
      "speeds": {"photo": 1.5, "pdf": 2.25},
      "loginDefaultApplied": true
    }
    """
    return try #require(try JSONSerialization.jsonObject(with: Data(seed.utf8)) as? NSDictionary)
}

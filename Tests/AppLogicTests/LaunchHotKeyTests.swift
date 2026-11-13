import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1 review round B (app), tester step: finding F9 (a failed global-shortcut registration at launch is ignored, and
// slice 1 has no menu bar, Dock icon or window, so the app is then invisible and cannot be used).
// Written from the review report (F9), the brief's acceptance line, spec S1 ("the old shortcut stays", a taken key is
// refused with a message) and design section 6 ("a taken key keeps the old one") only. Product source read for names and
// where the logic lives: Sources/Sesame/AppDelegate.swift (`registerHotKey` ignores the result of `register`),
// Settings/HotKeyRegistrar.swift (`HotKeyRegistrar`), Settings/ShortcutControl.swift (`ShortcutControl`, `message`).
// No expected value comes from them.
//
// SUITE PLACEMENT. `ShortcutControl` reads settings.json under HOME, so the suite is nested inside `ModelDownloadTests`
// with the other HOME-touching suites. The fake registrar is a copy of the one in HotKeyReregisterTests (that one is
// file-private): it models Carbon, and no real system hotkey is ever registered.
//
// API SHAPES these tests pin (new; if a shape is wrong, ask for a test change rather than guessing). All in `Sesame`.
//   1. `@MainActor enum LaunchHotKey` (a struct or a final class with the same static member is fine) with
//        `@discardableResult static func register(combination: String, registrar: any HotKeyRegistrar,
//                                                  onFailure: (String) -> Void) -> String?`
//      The app delegate calls it once at launch with the combination from settings.json. It tries `combination`. If the
//      registrar says no, it tries `ShortcutControl.defaultCombination`. It returns the combination now in force (the
//      saved one, or the default), or nil when neither could be registered; then, and only then, `onFailure` is called
//      once with a message that is not blank (the app opens the Settings window with it). With a combination in force
//      exactly one registration is live. A failed `register` leaves nothing live (HotKeyRegistrar's own contract).
//      Whether a fallback to the default also calls `onFailure`, and whether it rewrites settings.json, are NOT pinned.
//   2. `ShortcutControl.report(_ text: String)`: puts `text` in `message` (the status line the Settings window shows),
//      changes nothing else: `combination`, `displayText` and settings.json `hotkey` stay as they were. `clearMessage()`
//      (it exists) takes it away again. This is how the launch failure text reaches the window.
//
// NOT REACHED here (the real app only): that `AppDelegate` really calls `LaunchHotKey.register`, that it opens the
// Settings window with the message when it returns nil, that the window then shows the text, and that a failing
// `InstallEventHandler` (the Carbon handler, `installHandlerOnce`) is no longer reported as "registered". A unit test
// must not register a real system hotkey or start the app.

private func lhKeys(_ combination: String) -> [String] {
    combination.lowercased().split(separator: "+").map(String.init).sorted()
}

private let lhDefault = ["ctrl", "opt", "space"].sorted()
private let lhOptCmdK = ["cmd", "k", "opt"].sorted()

/// A registrar that models Carbon: a successful `register` adds a registration that stays until `unregister()`; a
/// combination macOS refuses, or text that is not a combination, is false and leaves nothing behind.
@MainActor
private final class LHFakeRegistrar: HotKeyRegistrar {
    private(set) var events: [String] = []
    private(set) var live: [[String]] = []
    var refuses: Set<[String]> = []

    func register(_ combination: String) -> Bool {
        events.append("register " + lhKeys(combination).joined(separator: "+"))
        if refuses.contains(lhKeys(combination)) || HotKey.parse(combination) == nil { return false }
        live.append(lhKeys(combination))
        return true
    }

    func unregister() {
        events.append("unregister")
        live = []
    }
}

private final class LHFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ text: String) { lock.lock(); list.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

private func lhBlank(_ text: String?) -> Bool {
    (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

extension ModelDownloadTests {
    @Suite("LaunchHotKeyTests", .serialized)
    struct LaunchHotKeyTests {

        @MainActor
        @Test func theSavedCombinationIsRegisteredAndNothingIsReported() {
            let registrar = LHFakeRegistrar()
            let failures = LHFailures()

            let inForce = LaunchHotKey.register(combination: "opt+cmd+k", registrar: registrar, onFailure: { failures.add($0) })

            #expect(inForce.map(lhKeys) == lhOptCmdK, "reported in force: \(String(describing: inForce))")
            #expect(registrar.live == [lhOptCmdK], "live: \(registrar.live)")
            #expect(registrar.events.first == "register " + lhOptCmdK.joined(separator: "+"), "the saved one is tried first: \(registrar.events)")
            #expect(failures.all.isEmpty, "a working shortcut was reported as a failure: \(failures.all)")
        }

        @MainActor
        @Test func theDefaultIsTriedWhenTheSavedCombinationIsRefusedAndExactlyOneIsLive() {
            let registrar = LHFakeRegistrar()
            registrar.refuses = [lhOptCmdK]

            let inForce = LaunchHotKey.register(combination: "opt+cmd+k", registrar: registrar, onFailure: { _ in })

            #expect(inForce.map(lhKeys) == lhDefault, "reported in force: \(String(describing: inForce)), wanted the default")
            #expect(registrar.live == [lhDefault], "live: \(registrar.live) (the default, once)")
            #expect(registrar.events.first == "register " + lhOptCmdK.joined(separator: "+"),
                    "the saved one is tried first: \(registrar.events)")
            #expect(registrar.events.contains("register " + lhDefault.joined(separator: "+")), "the default was never tried: \(registrar.events)")
        }

        @MainActor
        @Test func aSavedCombinationThatIsNotACombinationFallsBackToTheDefault() {
            let registrar = LHFakeRegistrar()

            let inForce = LaunchHotKey.register(combination: "not a combination", registrar: registrar, onFailure: { _ in })

            #expect(inForce.map(lhKeys) == lhDefault, "reported in force: \(String(describing: inForce))")
            #expect(registrar.live == [lhDefault], "live: \(registrar.live)")
        }

        @MainActor
        @Test func whenTheSavedAndTheDefaultAreBothRefusedTheMessageIsGivenOnceAndNothingIsLive() {
            let registrar = LHFakeRegistrar()
            registrar.refuses = [lhOptCmdK, lhDefault]
            let failures = LHFailures()

            let inForce = LaunchHotKey.register(combination: "opt+cmd+k", registrar: registrar, onFailure: { failures.add($0) })

            #expect(inForce == nil, "reported in force: \(String(describing: inForce)), wanted nil")
            #expect(registrar.live.isEmpty, "live: \(registrar.live)")
            #expect(failures.all.count == 1, "onFailure calls: \(failures.all)")
            #expect(!lhBlank(failures.all.first), "the message is blank: \(String(describing: failures.all.first))")
        }

        @MainActor
        @Test func aRefusedDefaultThatWasAlsoTheSavedCombinationIsReportedOnce() {
            let registrar = LHFakeRegistrar()
            registrar.refuses = [lhDefault]
            let failures = LHFailures()

            let inForce = LaunchHotKey.register(combination: ShortcutControl.defaultCombination, registrar: registrar,
                                                onFailure: { failures.add($0) })

            #expect(inForce == nil)
            #expect(registrar.live.isEmpty)
            #expect(failures.all.count == 1, "onFailure calls: \(failures.all)")
            #expect(!lhBlank(failures.all.first))
        }

        // MARK: the message reaches the window's status line

        @MainActor
        @Test func reportPutsTheLaunchMessageInTheControlsStatusLineAndChangesNothingElse() async throws {
            try await spWithHome { _ in
                let control = ShortcutControl()
                let before = (control.combination, control.displayText)
                #expect(control.message == nil)

                control.report("The shortcut could not be registered.")

                #expect(control.message == "The shortcut could not be registered.", "message: \(String(describing: control.message))")
                #expect(control.combination == before.0 && control.displayText == before.1, "report changed the combination")
                let stored = (try? SettingsFile().read().hotkey) ?? ""
                #expect(stored.isEmpty || stored == before.0, "report wrote a hotkey to settings.json: \(stored)")

                control.clearMessage()
                #expect(control.message == nil, "clearMessage left \(String(describing: control.message))")
            }
        }

        // MARK: plan-2-t4 (carry-over R4): a shortcut that fell back to the default is shown once and stored
        //
        // Tester step of plan-2-t4, written from the plan-2-t4 entry, design sections 1 and 6 and Decision D6 only;
        // no product source read. The plan-1 tests above are untouched and must stay green.
        //
        // API SHAPES pinned here (new, all in `Sesame`; if a shape is wrong, ask for a test change rather than guessing).
        //   1. `LaunchHotKey.Outcome`, an enum with exactly three cases:
        //        `.saved(String)`                          the saved combination registered; the value is that combination
        //        `.fellBack(live: String, refused: String)` the saved one was refused (or is not a combination) and the
        //                                                   default registered; `live` is "ctrl+opt+space", `refused` is
        //                                                   the saved text exactly as it was passed in
        //        `.none`                                   both were refused; nothing is live
        //   2. `@MainActor static func resolve(combination: String, registrar: any HotKeyRegistrar,
        //                                      onFailure: (String) -> Void) -> LaunchHotKey.Outcome`
        //      The entry names the enum but not the call. `register(combination:registrar:onFailure:)` keeps its plan-1
        //      shape (`String?`, pinned by the tests above), so the Outcome comes from this sibling; the product may
        //      build `register` on top of `resolve`. `resolve` tries the saved combination first, then the default, with
        //      the same registrar rules as `register`; with both refused `onFailure` is called once with a message that
        //      is not blank ("the existing failure text": its wording is not pinned here, as in the tests above).
        //      Whether a fallback also calls `onFailure` is NOT pinned.
        //   The `ShortcutControl` side (`adoptLive`, `takeNotice`, `notSavedText`) is pinned in ShortcutControlTests.
        //
        // NOT REACHED here (the real app only): that `AppDelegate` calls `resolve` at launch and hands a `.fellBack` to
        // `ShortcutControl.adoptLive`, and that the Settings window shows the notice when it opens (plan-2-t26 renders
        // it). The chain test below plays the delegate's two calls by hand.

        @MainActor
        @Test func resolveSaysSavedWhenTheSavedCombinationRegisters() {
            let registrar = LHFakeRegistrar()
            let failures = LHFailures()

            let outcome = LaunchHotKey.resolve(combination: "opt+cmd+k", registrar: registrar, onFailure: { failures.add($0) })

            #expect(lhShape(outcome) == .saved("opt+cmd+k"), "outcome: \(outcome)")
            #expect(registrar.live == [lhOptCmdK], "live: \(registrar.live)")
            #expect(failures.all.isEmpty, "a working shortcut was reported as a failure: \(failures.all)")
        }

        @MainActor
        @Test func resolveSaysSavedForTheDefaultWhenTheDefaultWasSavedAndRegisters() {
            let registrar = LHFakeRegistrar()

            let outcome = LaunchHotKey.resolve(combination: "ctrl+opt+space", registrar: registrar, onFailure: { _ in })

            #expect(lhShape(outcome) == .saved("ctrl+opt+space"), "outcome: \(outcome)")
            #expect(registrar.live == [lhDefault], "live: \(registrar.live)")
        }

        @MainActor
        @Test func resolveSaysFellBackWithTheLiveDefaultAndTheRefusedSavedCombination() {
            let registrar = LHFakeRegistrar()
            registrar.refuses = [lhOptCmdK]

            let outcome = LaunchHotKey.resolve(combination: "opt+cmd+k", registrar: registrar, onFailure: { _ in })

            #expect(lhShape(outcome) == .fellBack(live: "ctrl+opt+space", refused: "opt+cmd+k"), "outcome: \(outcome)")
            #expect(registrar.live == [lhDefault], "live: \(registrar.live) (the default, once)")
            #expect(registrar.events.first == "register " + lhOptCmdK.joined(separator: "+"), "the saved one is tried first: \(registrar.events)")
        }

        @MainActor
        @Test func resolveSaysFellBackForASavedTextThatIsNotACombination() {
            let registrar = LHFakeRegistrar()

            let outcome = LaunchHotKey.resolve(combination: "not a combination", registrar: registrar, onFailure: { _ in })

            #expect(lhShape(outcome) == .fellBack(live: "ctrl+opt+space", refused: "not a combination"), "outcome: \(outcome)")
            #expect(registrar.live == [lhDefault], "live: \(registrar.live)")
        }

        @MainActor
        @Test func resolveSaysNoneWhenBothAreRefusedAndGivesTheFailureTextOnce() {
            let registrar = LHFakeRegistrar()
            registrar.refuses = [lhOptCmdK, lhDefault]
            let failures = LHFailures()

            let outcome = LaunchHotKey.resolve(combination: "opt+cmd+k", registrar: registrar, onFailure: { failures.add($0) })

            #expect(lhShape(outcome) == .none, "outcome: \(outcome)")
            #expect(registrar.live.isEmpty, "live: \(registrar.live)")
            #expect(failures.all.count == 1, "onFailure calls: \(failures.all)")
            #expect(!lhBlank(failures.all.first), "the message is blank: \(String(describing: failures.all.first))")
        }

        @MainActor
        @Test func resolveSaysNoneWhenTheRefusedDefaultWasAlsoTheSavedCombinationAndReportsOnce() {
            let registrar = LHFakeRegistrar()
            registrar.refuses = [lhDefault]
            let failures = LHFailures()

            let outcome = LaunchHotKey.resolve(combination: "ctrl+opt+space", registrar: registrar, onFailure: { failures.add($0) })

            #expect(lhShape(outcome) == .none, "outcome: \(outcome)")
            #expect(registrar.live.isEmpty)
            #expect(failures.all.count == 1, "onFailure calls: \(failures.all)")
            #expect(!lhBlank(failures.all.first))
        }

        // The delegate's two calls played by hand in a temp HOME: a refused saved combination becomes the live default in
        // settings.json, Settings is told once, and the next launch registers the stored one without a second notice.
        @MainActor
        @Test func aFellBackLaunchStoresTheLiveCombinationAndTheNextLaunchNeedsNoNotice() async throws {
            try await spWithHome { _ in
                _ = try SesameFolder.create()
                let file = SettingsFile()
                let current = try file.read()
                try file.write(try JSONDecoder().decode(type(of: current), from: Data(lhSeedJSON(hotkey: "opt+cmd+k").utf8)))

                let registrar = LHFakeRegistrar()
                registrar.refuses = [lhOptCmdK]
                let control = ShortcutControl()
                #expect(lhKeys(control.combination) == lhOptCmdK, "the control starts on the saved one: \(control.combination)")

                let outcome = LaunchHotKey.resolve(combination: control.combination, registrar: registrar, onFailure: { _ in })
                guard case let .fellBack(live, refused) = outcome else {
                    Issue.record("wanted .fellBack, got \(outcome)")
                    return
                }
                control.adoptLive(live, refused: refused)

                #expect(lhKeys((try? SettingsFile().read().hotkey) ?? "") == lhDefault, "settings.json hotkey is still the refused one")
                #expect(control.displayText == "Control Option Space", "the control reads \"\(control.displayText)\"")
                let notice = control.takeNotice()
                #expect(notice == "The shortcut Option Command K is taken by another app, so Sesame is using Control Option Space.",
                        "notice: \(String(describing: notice))")
                #expect(control.takeNotice() == nil, "the notice came a second time")

                // the next launch: a new control reads the stored live combination, and it registers with nothing to report
                let nextRegistrar = LHFakeRegistrar()
                nextRegistrar.refuses = [lhOptCmdK]
                let next = ShortcutControl()
                let nextOutcome = LaunchHotKey.resolve(combination: next.combination, registrar: nextRegistrar, onFailure: { _ in })
                #expect(lhShape(nextOutcome) == .saved(next.combination), "next launch outcome: \(nextOutcome)")
                #expect(lhKeys(next.combination) == lhDefault, "next launch combination: \(next.combination)")
                #expect(next.takeNotice() == nil, "a later launch showed the notice again")
            }
        }
    }
}

// What a `resolve` returned, as a value the tests compare. Exactly three cases are pinned.
private enum LHShape: Equatable {
    case saved(String)
    case fellBack(live: String, refused: String)
    case none
}

@MainActor
private func lhShape(_ outcome: LaunchHotKey.Outcome) -> LHShape {
    switch outcome {
    case .saved(let combination): return .saved(combination)
    case .fellBack(let live, let refused): return .fellBack(live: live, refused: refused)
    case .none: return .none
    }
}

// Settings a person might already have, written by hand from design section 1.
private func lhSeedJSON(hotkey: String) -> String {
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

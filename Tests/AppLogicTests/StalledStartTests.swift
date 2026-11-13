import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-3 fix round, t17-5, tester step (C): a Settings Start indexing or Re-index while indexing is stalled clears the stall
// like Resume does (S7.2, S7.12; reviewer-plan-3-1 report, "Gap 1"). Written from the controller's ruling, the sealed
// AppLifecycleTests (`ALStallWorld`, the Resume tests: `PauseSet` is held as `monitor.pauseSet`, `reasons`, `add`) and the sealed
// SettingsModelTests / SettingsScreenTests (the recording `FoldersSender`, the `Re-index` button, HOME rig). No product source
// is read; every expected value is written by hand.
//
// NEW NAMES these tests pin (the ruling fixes them; they do not exist yet, so this file does not compile until they do, and
// the compiler's messages name exactly these two):
//   1. `SettingsModel.init(sender:counter:modelWhole:onIndexingRequested:)`: a new LAST parameter
//        onIndexingRequested: @escaping () -> Void = {}
//      called once per Start indexing press and once per per-folder Re-index press, after the press's existing
//      `sendFolders()` call, and for no other action.
//   2. `StallRecovery.recover(pauseSet:resetStall:settingsChanged:reevaluate:)`, a static function. If `.stalled` is in the pause
//      set it removes it (`.you` and the automatic reasons stay), calls `resetStall` once, then `settingsChanged` and
//      `reevaluate` once each; with no `.stalled` it removes and calls nothing.
// SPELLINGS I PICKED (the ruling leaves them open; say so if one is wrong):
//   - `pauseSet:` is `inout PauseSet` (`PauseSet` is a struct: AppLifecycleTests holds it as `monitor.pauseSet` and mutates it
//     through `add`/`remove`). The tests pass a local `var set = PauseSet()` as `&set`. Because the argument is inout, a closure
//     cannot read the set while `recover` runs, so these tests record call ORDER and COUNTS and read the set after the call; the
//     "re-evaluation must not see the old stall" check of the Resume tests is not repeated here. If `pauseSet:` is a reference or
//     a closure pair instead, that check can be added.
//   - The Start press is `SettingsModel.startIndexing()` (SettingsModelTests, pin 10). The Re-index press is the window's
//     "Re-index" button of a folder row (`performClick`), because the model has no method of its own that the existing tests
//     call for it (SettingsScreenTests presses the button in `SettingsContainerWindow(model:)`).
//
// SUITE PLACEMENT. HOME is process-wide, so this suite is nested inside `ModelDownloadTests` like the other Settings suites.

private final class SDSender: FoldersSender, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func sendFolders() { record("sendFolders") }
    func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return names }
    func count(_ name: String) -> Int { events.filter { $0 == name }.count }
}

@MainActor
private func sdRun(_ body: (URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-stalledstart-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let home = base.resolvingSymlinksInPath()
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    try await body(home)
}

/// A folder with a few hand-made pictures, listed in settings.json as reading, Start already pressed.
@MainActor
private func sdSeed(_ home: URL) throws -> URL {
    let trips = home.appendingPathComponent("Trips", isDirectory: true)
    try FileManager.default.createDirectory(at: trips, withIntermediateDirectories: true)
    for name in ["a.jpg", "b.png"] { try Data(repeating: 7, count: 32).write(to: trips.appendingPathComponent(name)) }
    var settings = Settings()
    settings.startPressed = true
    settings.folders = [Settings.Folder(path: trips.path, code: false, reading: true)]
    try SettingsFile().write(settings)
    return trips
}

@MainActor
private func sdEventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func sdQuietPeriod() async { try? await Task.sleep(nanoseconds: 300_000_000) }

@MainActor
private func sdReindexItem(in window: NSWindow) -> NSMenuItem? {
    guard let root = window.contentView else { return nil }
    return smrItem("Re-index", of: smrMoreButtons(root).first)
}

// MARK: what StallRecovery does with a pause set

@MainActor
private final class SDCalls {
    private(set) var events: [String] = []
    func note(_ name: String) { events.append(name) }
    func count(_ name: String) -> Int { events.filter { $0 == name }.count }
}

@MainActor
private func sdRecover(_ reasons: Set<PauseReason>) -> (set: PauseSet, calls: SDCalls) {
    var set = PauseSet()
    for reason in reasons { set.add(reason) }
    let calls = SDCalls()
    StallRecovery.recover(pauseSet: &set,
                          resetStall: { calls.note("resetStall") },
                          settingsChanged: { calls.note("settingsChanged") },
                          reevaluate: { calls.note("reevaluate") })
    return (set, calls)
}

extension ModelDownloadTests {
    @Suite("StalledStartTests", .serialized)
    @MainActor
    struct StalledStartTests {

        // MARK: StallRecovery.recover

        @Test func aStallAloneIsClearedResetStallRunsOnceAndThenTheStatusCacheAndTheSupervisorOnceEach() {
            let (set, calls) = sdRecover([.stalled])
            #expect(set.reasons.isEmpty, "recover left \(set.reasons)")
            #expect(calls.count("resetStall") == 1, "\(calls.events)")
            #expect(calls.count("settingsChanged") == 1, "\(calls.events)")
            #expect(calls.count("reevaluate") == 1, "\(calls.events)")
            #expect(calls.events.count == 3, "\(calls.events)")
            #expect(calls.events.first == "resetStall", "resetStall must run before the other two: \(calls.events)")
        }

        @Test func aStallWithYouClearsOnlyTheStallAndLeavesYou() {
            let (set, calls) = sdRecover([.stalled, .you])
            #expect(set.reasons == [.you], "recover left \(set.reasons)")
            #expect(calls.count("resetStall") == 1, "\(calls.events)")
            #expect(calls.count("settingsChanged") == 1, "\(calls.events)")
            #expect(calls.count("reevaluate") == 1, "\(calls.events)")
            #expect(calls.events.first == "resetStall", "\(calls.events)")
        }

        @Test func aStallWithAnAutomaticReasonClearsOnlyTheStallAndLeavesTheAutomaticReason() {
            for automatic in [PauseReason.cpu, .lowPower, .battery] {
                let (set, calls) = sdRecover([.stalled, automatic])
                #expect(set.reasons == [automatic], "\(automatic): recover left \(set.reasons)")
                #expect(calls.count("resetStall") == 1, "\(automatic): \(calls.events)")
                #expect(calls.count("settingsChanged") == 1, "\(automatic): \(calls.events)")
                #expect(calls.count("reevaluate") == 1, "\(automatic): \(calls.events)")
                #expect(calls.events.first == "resetStall", "\(automatic): \(calls.events)")
            }
        }

        @Test func aStallWithEveryOtherReasonLeavesAllOfThem() {
            let (set, calls) = sdRecover([.stalled, .you, .cpu, .lowPower, .battery])
            #expect(set.reasons == [.you, .cpu, .lowPower, .battery], "recover left \(set.reasons)")
            #expect(calls.events.count == 3 && calls.events.first == "resetStall", "\(calls.events)")
        }

        @Test func withNoStallNothingIsRemovedAndNothingIsCalled() {
            for reasons in [Set<PauseReason>(), [.you], [.cpu], [.lowPower], [.battery], [.you, .cpu, .lowPower, .battery]] {
                let (set, calls) = sdRecover(reasons)
                #expect(set.reasons == reasons, "no stall: recover changed \(reasons) to \(set.reasons)")
                #expect(calls.events.isEmpty, "no stall: \(reasons) called \(calls.events)")
            }
        }

        // MARK: SettingsModel.onIndexingRequested

        @Test func startIndexingCallsTheHookOnceAfterTheFoldersAreSent() async throws {
            try await sdRun { home in
                _ = try sdSeed(home)
                let sender = SDSender()
                let model = SettingsModel(sender: sender, modelWhole: { true }, onIndexingRequested: { sender.record("onIndexingRequested") })
                model.startIndexing()
                #expect(sender.count("onIndexingRequested") == 1, "\(sender.events)")
                #expect(sender.events == ["sendFolders", "onIndexingRequested"], "the hook runs after the send: \(sender.events)")
                await sdQuietPeriod()
                #expect(sender.count("onIndexingRequested") == 1, "a late second call: \(sender.events)")
            }
        }

        @Test func aReindexPressCallsTheHookOnceAfterTheFoldersAreSent() async throws {
            try await sdRun { home in
                _ = try sdSeed(home)
                let sender = SDSender()
                let model = SettingsModel(sender: sender, modelWhole: { true }, onIndexingRequested: { sender.record("onIndexingRequested") })
                #expect(await sdEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } })
                let window = SettingsContainerWindow(model: model)
                window.isReleasedWhenClosed = false
                let item = try #require(sdReindexItem(in: window), "no Re-index menu item under a more button in the Folders section")
                #expect(item.isEnabled, "Re-index is disabled for a reading folder")
                #expect(await smrPerform(item), "the Re-index item cannot be chosen")
                #expect(await sdEventually { sender.count("onIndexingRequested") >= 1 }, "Re-index did not call the hook: \(sender.events)")
                await sdQuietPeriod()
                #expect(sender.count("onIndexingRequested") == 1, "\(sender.events)")
                #expect(sender.events == ["sendFolders", "onIndexingRequested"], "the hook runs after the send: \(sender.events)")
            }
        }

        @Test func otherSettingsActionsNeverCallTheHook() async throws {
            try await sdRun { home in
                let trips = try sdSeed(home)
                let extra = home.appendingPathComponent("Extra", isDirectory: true)
                try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
                let sender = SDSender()
                let model = SettingsModel(sender: sender, modelWhole: { true }, onIndexingRequested: { sender.record("onIndexingRequested") })
                #expect(await sdEventually { model.rows.filter { $0.ticked }.allSatisfy { $0.state == .ready } })

                model.addFolder(extra)
                model.setTicked(extra.path, true)
                model.setTicked(trips.path, false)
                model.setTicked(trips.path, true)
                model.setKind("photo", on: false)
                model.setKind("photo", on: true)
                model.removeFolder(extra.path, confirmed: true)
                await sdQuietPeriod()
                #expect(sender.count("onIndexingRequested") == 0, "a non-indexing action called the hook: \(sender.events)")
            }
        }

        @Test func theHookDefaultsToNothingSoAModelBuiltWithoutItStillStarts() async throws {
            try await sdRun { home in
                _ = try sdSeed(home)
                let sender = SDSender()
                let model = SettingsModel(sender: sender, modelWhole: { true })
                model.startIndexing()
                #expect(sender.events == ["sendFolders"], "\(sender.events)")
            }
        }
    }
}

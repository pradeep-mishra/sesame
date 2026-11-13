import AppKit
import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2 fix round B, tester step, item B5 (R2-12, privacy): a launch must not build the setup window, count folders or
// walk `~/Developer` unless the setup window is going to be shown. Today `setupModel` is `setupWindowMade().model`, and the
// launch download task calls `setupModel.refresh()`, which builds the window and its `SetupFolders`, whose init counts
// Desktop, Documents, Downloads, Pictures and Movies and looks for repos under Developer, for a returning person too.
// Written from the fix-round document ("`setupModel` becomes created on demand; the launch download task refreshes it only
// if it exists") and the review report (R2-12). No product source was read.
//
// API SHAPE B5 pins (new). The document says "created on demand" and names no type, so this file picks one, in the
// `Sesame` target:
//     @MainActor final class OnDemandSetup {
//         init(make: @escaping @MainActor () -> SetupWindow)   // stores the maker; builds nothing
//         var made: SetupWindow? { get }                        // nil until `window()` was first called
//         func window() -> SetupWindow                          // the first call calls `make` once; every call gives that window
//         func refreshModelIfMade()                             // `made?.model.refresh()`; never builds anything
//     }
// `AppDelegate` holds one of these in place of `setupWindowMade()` / `setupModel`: the launch path that shows setup
// calls `window()`, and the launch download task (and the model watcher) call `refreshModelIfMade()`. The AppDelegate
// wiring itself cannot be reached offscreen (no launch): the reviewer reads that `setupModel` is gone from the launch
// path, and the kit's S6.8 file-access trace covers it on the real app. These tests prove the seam: a maker that counts
// calls, building a real `SetupWindow` over a counting folder counter, in a throwaway HOME holding a suggested folder and
// a repo.
//
// WHAT THE RED MEANS. `OnDemandSetup` does not exist, so the test target does not compile until it does.

private final class LPCount: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0
    func add() { lock.lock(); number += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return number }
}

private final class LPFolderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    func enter(_ folders: [String]) { lock.lock(); recorded.append(folders); lock.unlock() }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private func lpHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@MainActor
private func lpRun(_ body: (_ home: URL, _ models: URL) async throws -> Void) async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sesame-launchprivacy-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let home = base.resolvingSymlinksInPath()
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: base)
    }
    _ = try SesameFolder.create()
    let models = home.appendingPathComponent("Library/Application Support/Sesame/models", isDirectory: true)
    try fm.createDirectory(at: models, withIntermediateDirectories: true)
    for (name, photos) in [("Desktop", 4), ("Pictures", 6)] {
        let dir = home.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 0..<photos { try Data(repeating: 7, count: 32).write(to: dir.appendingPathComponent("photo-\(n).jpg")) }
    }
    let repo = home.appendingPathComponent("Developer/api-client/.git", isDirectory: true)
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    try await body(home, models)
}

@MainActor
private func lpQuietStatus() -> StatusCache {
    let sources = StatusSources(
        settings: { Settings() },
        counts: { IndexCounts(done: 0, pending: [:], partial: [:], needsPermission: 0) },
        meta: { _ in nil },
        modelState: { .whole })
    return StatusCache(sources: sources, queue: DispatchQueue(label: "sesame.launchprivacy.test.status", qos: .utility))
}

@MainActor
private func lpWindow(home: URL, file: ModelFile, log: LPFolderLog) -> SetupWindow {
    let folders = SetupFolders(
        home: home,
        counter: { paths in
            log.enter(paths)
            return FolderCounts.count(folders: paths)
        },
        picker: { [] },
        speeds: { [:] },
        kindsOn: { [:] },
        modelWhole: { false })
    let client = HelperClient(helper: home.appendingPathComponent("no-such-helper"), textModel: home, mmModel: home)
    let window = SetupWindow(files: [file], folders: folders, helper: client, status: lpQuietStatus())
    window.isReleasedWhenClosed = false
    return window
}

extension ModelDownloadTests {
    @Suite("LaunchPrivacyTests", .serialized)
    struct LaunchPrivacyTests {

        @MainActor
        @Test func aLaunchThatShowsNoSetupBuildsNoWindowCountsNoFolderAndWalksNothing() async throws {
            try await lpRun { home, models in
                let data = Data(repeating: 3, count: 4_000)
                let file = ModelFile(name: "lp-whole.gguf", size: data.count, sha256: lpHex(data))
                let makes = LPCount()
                let log = LPFolderLog()
                let setup = OnDemandSetup(make: {
                    makes.add()
                    return lpWindow(home: home, file: file, log: log)
                })

                // what the launch download task does for a returning person, and what the model watcher does after it
                for _ in 0..<3 { setup.refreshModelIfMade() }
                try data.write(to: models.appendingPathComponent(file.name))
                setup.refreshModelIfMade()
                try? await Task.sleep(nanoseconds: 500_000_000)

                #expect(setup.made == nil, "a setup window exists although nothing asked for one")
                #expect(makes.value == 0, "the setup window was built \(makes.value) times by a refresh")
                #expect(log.calls.isEmpty, "folders were counted at launch: \(log.calls)")
            }
        }

        @MainActor
        @Test func theSetupWindowIsBuiltOnceWhenItIsAskedForAndOnlyThenTheSuggestedFoldersAreCounted() async throws {
            try await lpRun { home, models in
                let data = Data(repeating: 5, count: 4_000)
                let file = ModelFile(name: "lp-demand.gguf", size: data.count, sha256: lpHex(data))
                let makes = LPCount()
                let log = LPFolderLog()
                let setup = OnDemandSetup(make: {
                    makes.add()
                    return lpWindow(home: home, file: file, log: log)
                })
                #expect(makes.value == 0, "the maker ran at init")

                let first = setup.window()
                let second = setup.window()
                #expect(first === second, "two calls gave two windows")
                #expect(makes.value == 1, "the maker ran \(makes.value) times")
                #expect(setup.made === first, "`made` is not the window that was asked for")
                // the folders a first run shows are counted now: Desktop and Pictures hold the hand-made photos
                #expect(await spEventually { !log.calls.isEmpty }, "the suggested folders were never counted once setup was asked for")
                let counted = Set(log.calls.flatMap { $0 })
                #expect(counted.contains(home.appendingPathComponent("Desktop").path) && counted.contains(home.appendingPathComponent("Pictures").path),
                        "counted: \(counted.sorted())")

                // a window that exists is refreshed by the download task: the model that became whole is seen
                #expect(!first.model.canStartIndexing, "setup: the model file is not there yet")
                try data.write(to: models.appendingPathComponent(file.name))
                setup.refreshModelIfMade()
                #expect(first.model.canStartIndexing, "refreshModelIfMade did not refresh the model of a window that exists")
                #expect(makes.value == 1, "a refresh built another window")
            }
        }
    }
}

// =================================================================================================================
// plan-2 fix round D, tester step, item D1 (R3-01): a failed model download is shown wherever the person is.
//
// Written from the fix-round document D1 ("When it fails and no setup window is visible, the app builds the setup window on
// demand (`OnDemandSetup.window()`) and shows it in a download-failed state: the plain failure line, a Retry button, and no
// Start when Start was already pressed. Retry restarts the download and keeps the bytes already downloaded"), the review
// report (R3-01: `setup.made?.model.downloadFailed(...)` does nothing when the window was never built, or was built and
// closed) and spec S6. No product source was read. The AppDelegate wiring (the download task calling this, the window being
// ordered front, the Retry reaching `ModelRecovery`) cannot be reached offscreen: the fixer's report lists it for a reviewer.
//
// API SHAPES D1 pins here (new; the document names `OnDemandSetup.window()` and the failed state and fixes no signatures):
//   1. `OnDemandSetup.init(make:show:)`: `show: @escaping @MainActor (SetupWindow) -> Void = { _ in }` is a second parameter
//      with a default, so the sealed `OnDemandSetup(make:)` calls above still compile. `show` is what the app wires to
//      "order the window front and make it key"; offscreen it is a recorder.
//   2. `OnDemandSetup.downloadFailed(_ text: String)` (main actor, returns nothing) is what the app's download task and the
//      model watcher call when the download gave up. It (a) gets the window the way `window()` does: builds it with `make` if
//      none was built, and never builds a second one; (b) puts that window's model in its failed state with `text`
//      (`model.downloadFailed(text)`) and redraws the window (`window.refresh()`), so `window.setupScreen` and the buttons
//      show the failure and Retry at once, without the test refreshing; (c) calls `show(window)` exactly once per call, also
//      when the window was built earlier and has been closed. `window()` never calls `show` (the launch path shows its
//      window by its own way, as today).
//   3. `SetupWindow.init` gains a last parameter `onRetry: (@MainActor () -> Void)? = nil` (after `onStarted`, default nil, so
//      every sealed call compiles). It is what the window's Retry reaches: `window.model.retry()` calls it once. The app
//      passes the `ModelRecovery`'s retry. With nil, Retry still clears the failure and calls nothing.
//   4. The failed window: `window.model.errorText == text`, `window.model.showsRetry`, and `window.setupScreen` has a button
//      titled "Retry" that is enabled and carries `text` among its `texts` on every step (SetupScreenTests pins that for a
//      failed model); the NSButton "Retry" is in the window. Start is not available when Start was pressed before
//      (`model.canStartIndexing` false, no enabled "Start indexing" on the Folders step), and the model is not whole anyway.
//      The failure rewrites nothing: settings.json is byte for byte as it was, and the `.partial` bytes stay.
// =================================================================================================================

private let lpFailureLine = "The download stopped because the network is off."
private let lpSecondFailureLine = "The connection was lost again."

/// The windows `show` was given, in order.
@MainActor
private final class LPShown {
    private(set) var windows: [SetupWindow] = []
    func add(_ window: SetupWindow) { windows.append(window) }
}

@MainActor
private final class LPRetries {
    private(set) var count = 0
    func add() { count += 1 }
}

@MainActor
private func lpFailureWindow(home: URL, file: ModelFile, log: LPFolderLog, retries: LPRetries) -> SetupWindow {
    let folders = SetupFolders(
        home: home,
        counter: { paths in
            log.enter(paths)
            return FolderCounts.count(folders: paths)
        },
        picker: { [] },
        speeds: { [:] },
        kindsOn: { [:] },
        modelWhole: { false })
    let client = HelperClient(helper: home.appendingPathComponent("no-such-helper"), textModel: home, mmModel: home)
    let window = SetupWindow(files: [file], folders: folders, helper: client, status: lpQuietStatus(),
                             onRetry: { retries.add() })
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func lpButton(_ title: String, in window: NSWindow) -> NSButton? {
    guard let root = window.contentView else { return nil }
    return prViews(root).compactMap { $0 as? NSButton }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
        .first { $0.title == title || $0.accessibilityLabel() == title }
}

/// A model of 80 MB with 20 MB of it on disk under its `.partial` name: not whole, the bytes to keep.
private func lpPartialFile(_ models: URL, name: String) throws -> ModelFile {
    let file = ModelFile(name: name, size: 80_000_000, sha256: String(repeating: "0", count: 64))
    let url = models.appendingPathComponent(name + ".partial")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 20_000_000)
    return file
}

private func lpPartialSize(_ models: URL, name: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: models.appendingPathComponent(name + ".partial").path))?[.size] as? Int
}

private func lpWriteSettings(startPressed: Bool) throws {
    var settings = Settings()
    settings.startPressed = startPressed
    try SettingsFile().write(settings)
}

private func lpSettingsBytes(_ home: URL) -> Data? {
    try? Data(contentsOf: home.appendingPathComponent("Library/Application Support/Sesame/settings.json"))
}

extension ModelDownloadTests.LaunchPrivacyTests {

    @MainActor
    @Test func aDownloadThatFailedWithNoSetupWindowBuildsOneShowsItOnceWithTheFailureLineAndRetryAndNoStart() async throws {
        try await lpRun { home, models in
            let file = try lpPartialFile(models, name: "lp-d1-a.gguf")
            try lpWriteSettings(startPressed: true)   // the usual road to this: Finish, then Start, then the network drops
            let settingsBefore = lpSettingsBytes(home)
            #expect(settingsBefore != nil, "setup: no settings.json was written")
            let makes = LPCount()
            let log = LPFolderLog()
            let retries = LPRetries()
            let shown = LPShown()
            let setup = OnDemandSetup(make: {
                makes.add()
                return lpFailureWindow(home: home, file: file, log: log, retries: retries)
            }, show: { shown.add($0) })
            #expect(setup.made == nil && makes.value == 0 && shown.windows.isEmpty, "something was built or shown before any failure")

            setup.downloadFailed(lpFailureLine)

            #expect(makes.value == 1, "the setup window was built \(makes.value) times for one failure with none shown")
            let window = try #require(setup.made, "no setup window exists after a failure with none shown: the person is told nothing (R3-01)")
            #expect(shown.windows.count == 1 && shown.windows.first === window,
                    "show was called \(shown.windows.count) times, or with another window")
            #expect(window.model.errorText == lpFailureLine, "error text: \(String(describing: window.model.errorText))")
            #expect(window.model.showsRetry, "the failed window offers no Retry")
            #expect(window.setupScreen.texts.joined(separator: "\n").contains(lpFailureLine),
                    "the window does not say it: \(window.setupScreen.texts)")
            #expect(window.setupScreen.buttons.contains { $0.title == "Retry" && $0.isEnabled },
                    "no enabled Retry among \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
            #expect(lpButton("Retry", in: window)?.isEnabled == true, "no enabled Retry button in the window")

            // Start was pressed before: no Start, on the Folders step too
            #expect(!window.model.canStartIndexing, "Start is available in the failed window although Start was pressed before")
            lpButton("Next", in: window)?.performClick(nil)
            #expect(window.flow.step == .folders, "Next did not reach the Folders step: \(window.flow.step.title)")
            #expect(!window.setupScreen.buttons.contains { $0.title == "Start indexing" && $0.isEnabled },
                    "an enabled Start indexing in the failed window: \(window.setupScreen.buttons.map { ($0.title, $0.isEnabled) })")
            #expect(window.setupScreen.texts.joined(separator: "\n").contains(lpFailureLine), "the failure is not on the Folders step: \(window.setupScreen.texts)")

            // nothing was rewritten, no byte was lost
            #expect(lpSettingsBytes(home) == settingsBefore, "the failure rewrote settings.json")
            #expect(lpPartialSize(models, name: file.name) == 20_000_000, "the downloaded bytes were changed or deleted")
            #expect(retries.count == 0, "the failure itself called Retry")
        }
    }

    @MainActor
    @Test func aSetupWindowThatWasBuiltAndClosedIsReusedAndShownAgainForTheFailure() async throws {
        try await lpRun { home, models in
            let file = try lpPartialFile(models, name: "lp-d1-b.gguf")
            try lpWriteSettings(startPressed: false)   // Finish was pressed earlier, Start never: setupFinished says no setup at launch
            let makes = LPCount()
            let log = LPFolderLog()
            let retries = LPRetries()
            let shown = LPShown()
            let setup = OnDemandSetup(make: {
                makes.add()
                return lpFailureWindow(home: home, file: file, log: log, retries: retries)
            }, show: { shown.add($0) })

            // the person saw the window at first run and closed it (Finish)
            let first = setup.window()
            first.close()
            #expect(shown.windows.isEmpty, "window() itself called show: the launch path shows the window by its own way")

            setup.downloadFailed(lpFailureLine)

            #expect(makes.value == 1, "a second window was built for the failure: \(makes.value)")
            #expect(setup.made === first, "the failure went to another window than the one that exists")
            #expect(shown.windows.count == 1 && shown.windows.first === first, "show was not called once with the closed window: \(shown.windows.count)")
            #expect(first.model.errorText == lpFailureLine && first.model.showsRetry, "the closed window's model does not show the failure")
            #expect(first.setupScreen.buttons.contains { $0.title == "Retry" && $0.isEnabled }, "no enabled Retry in the redrawn window")
            #expect(lpPartialSize(models, name: file.name) == 20_000_000, "the downloaded bytes were changed or deleted")
        }
    }

    @MainActor
    @Test func retryInTheFailedWindowCallsTheHookOnceClearsTheFailureKeepsTheBytesAndAnotherFailureShowsAgain() async throws {
        try await lpRun { home, models in
            let file = try lpPartialFile(models, name: "lp-d1-c.gguf")
            try lpWriteSettings(startPressed: true)
            let makes = LPCount()
            let log = LPFolderLog()
            let retries = LPRetries()
            let shown = LPShown()
            let setup = OnDemandSetup(make: {
                makes.add()
                return lpFailureWindow(home: home, file: file, log: log, retries: retries)
            }, show: { shown.add($0) })

            setup.downloadFailed(lpFailureLine)
            let window = try #require(setup.made)
            let retry = try #require(lpButton("Retry", in: window), "no Retry button in the failed window")
            #expect(retry.isEnabled)
            retry.performClick(nil)

            #expect(retries.count == 1, "the Retry hook was called \(retries.count) times by one press")
            #expect(window.model.errorText == nil && !window.model.showsRetry, "the failure stays after Retry: \(String(describing: window.model.errorText))")
            #expect(!window.setupScreen.buttons.contains { $0.title == "Retry" && $0.isEnabled }, "Retry is still offered after it was pressed")
            #expect(!window.setupScreen.texts.joined(separator: "\n").contains(lpFailureLine), "the failure line stays after Retry")
            #expect(lpPartialSize(models, name: file.name) == 20_000_000, "Retry changed the kept bytes")
            #expect(window.setupScreen.texts.joined(separator: "\n").contains("20 of 80 MB"), "the bytes are not shown: \(window.setupScreen.texts)")

            // the retried download gave up again: the same window, shown again, with the new line
            setup.downloadFailed(lpSecondFailureLine)
            #expect(makes.value == 1, "a second window was built: \(makes.value)")
            #expect(shown.windows.count == 2 && shown.windows.allSatisfy { $0 === window }, "show calls: \(shown.windows.count)")
            #expect(window.model.errorText == lpSecondFailureLine && window.model.showsRetry, "the second failure is not shown")
            #expect(window.setupScreen.texts.joined(separator: "\n").contains(lpSecondFailureLine), "texts: \(window.setupScreen.texts)")
            #expect(lpButton("Retry", in: window)?.isEnabled == true, "Retry did not come back")
        }
    }

    // GUARD: passes today once the names compile. A refresh from the download task or the model watcher still builds
    // nothing, and `downloadFailed` is the only call that builds a window besides `window()`.
    @MainActor
    @Test func aRefreshStillBuildsNothingAndOnlyAFailureOrAskingBuildsTheWindow() async throws {
        try await lpRun { home, models in
            let file = try lpPartialFile(models, name: "lp-d1-d.gguf")
            let makes = LPCount()
            let log = LPFolderLog()
            let retries = LPRetries()
            let shown = LPShown()
            let setup = OnDemandSetup(make: {
                makes.add()
                return lpFailureWindow(home: home, file: file, log: log, retries: retries)
            }, show: { shown.add($0) })
            for _ in 0..<3 { setup.refreshModelIfMade() }
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(setup.made == nil && makes.value == 0 && shown.windows.isEmpty && log.calls.isEmpty,
                    "a refresh built or showed a window, or counted folders: makes \(makes.value), shown \(shown.windows.count), counted \(log.calls)")
        }
    }
}

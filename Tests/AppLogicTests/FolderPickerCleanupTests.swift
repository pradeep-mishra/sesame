import Foundation
import Testing
@testable import Sesame

// plan-1-t40, tester step. Pins the U19 fix: AppKit's folder picker (NSOpenPanel) writes the defaults domain
// ~/Library/Preferences/<bundle id>.plist into the person's REAL home, because cfprefsd ignores HOME. The static
// rule `user-defaults` forbids UserDefaults in the app and `write-delete` allows deletes only through SesameFolder,
// so the app removes the picker's domain right after the picker closes by running
// `/usr/bin/defaults delete <bundle id>` off the main thread, ignoring failure (spec S8(g)).
// Written from the brief and the spec only; no product source read. Nothing here runs the real `defaults`: every
// call goes through a fake runner, so no preference domain on this machine is touched.
//
// API SHAPES these tests pin (the brief names the seam, not its signatures; if a shape is wrong, ask for a test
// change rather than guessing).
//   1. `FolderPickerDefaults` (in the `Sesame` target) is an enum or struct with
//        typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) throws -> Int32
//        static var appBundleID: String? { get }   // exactly Bundle.main.bundleIdentifier
//        static func cleanup(bundleID: String?, run: @escaping Runner)
//      `cleanup` returns at once. It hands the work to a background queue or task, so `run` is never called on
//      the main thread and a slow runner never delays the caller. When `bundleID` is nil, empty or only
//      whitespace, `run` is never called. Otherwise `run` is called exactly once with executable
//      "/usr/bin/defaults" and arguments ["delete", bundleID]. A throw or a nonzero exit from `run` is swallowed.
//      `FolderPickerDefaults` also holds the real runner (it starts /usr/bin/defaults); tests never call it.
//   2. `FolderPicker.pick(present:bundleID:run:) -> [URL]`, a static function (it may be `@MainActor`):
//        static func pick(present: () -> [URL],
//                         bundleID: String? = FolderPickerDefaults.appBundleID,
//                         run: @escaping FolderPickerDefaults.Runner = <the real runner>) -> [URL]
//      `present` stands for the modal panel: the real caller runs `NSOpenPanel.runModal()` inside it and returns
//      the chosen URLs, or [] when the person cancelled. `pick` calls `present` once, then calls
//      `FolderPickerDefaults.cleanup(bundleID:run:)` once, on both outcomes (picked and cancelled), after
//      `present` has returned and never before, and returns exactly what `present` returned. The real
//      `FolderPicker` entry the setup window calls uses `pick` with the default `bundleID` and `run`.
//   3. Not pinned, on purpose: the queue or task type used for the background work; whether `cleanup` also logs;
//      anything in SetupWindow or the panel's own options.

// MARK: helpers (file-private)

/// What the fake runner saw. A lock guards it because the runner runs on another thread.
private final class RunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var calls: [(executable: String, arguments: [String], onMain: Bool)] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var all: [(executable: String, arguments: [String], onMain: Bool)] { lock.lock(); defer { lock.unlock() }; return calls }

    func record(_ executable: String, _ arguments: [String]) {
        lock.lock()
        calls.append((executable, arguments, Thread.isMainThread))
        lock.unlock()
        signal.signal()
    }

    /// Waits until the runner has been called (true) or the timeout passes (false).
    func waitForCall(seconds: Double = 5) -> Bool {
        signal.wait(timeout: .now() + seconds) == .success
    }
}

/// A runner that records the call and returns `exit`, optionally after a delay or by throwing.
private func fakeRunner(_ log: RunnerLog, exit: Int32 = 0, delay: Double = 0, throwing: Bool = false) -> FolderPickerDefaults.Runner {
    return { executable, arguments in
        log.record(executable, arguments)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if throwing { throw FakeRunnerError.boom }
        return exit
    }
}

private enum FakeRunnerError: Error { case boom }

private let fpFolders: [URL] = [
    URL(fileURLWithPath: "/private/var/folders/zz/fp-test/golden", isDirectory: true),
    URL(fileURLWithPath: "/private/var/folders/zz/fp-test/golden/photos", isDirectory: true),
]

/// Gives a stray call time to show up when the test expects none.
private func settle() { Thread.sleep(forTimeInterval: 0.3) }

@Suite("FolderPickerCleanup")
@MainActor
struct FolderPickerCleanupTests {

    // 1. After a pick the runner is called once with /usr/bin/defaults delete <id>.
    @Test func afterAPickTheDefaultsDomainIsDeleted() {
        let log = RunnerLog()
        let got = FolderPicker.pick(present: { fpFolders }, bundleID: "app.fake.PickOne", run: fakeRunner(log))
        #expect(log.waitForCall(), "the runner was never called after a pick")
        settle()
        #expect(got == fpFolders)
        #expect(log.count == 1)
        #expect(log.all.first?.executable == "/usr/bin/defaults")
        #expect(log.all.first?.arguments == ["delete", "app.fake.PickOne"])
    }

    // 2. After a cancel the same call is made, and nothing is picked.
    @Test func afterACancelTheDefaultsDomainIsDeletedToo() {
        let log = RunnerLog()
        let got = FolderPicker.pick(present: { [] }, bundleID: "app.fake.CancelOne", run: fakeRunner(log))
        #expect(log.waitForCall(), "the runner was never called after a cancel")
        settle()
        #expect(got.isEmpty)
        #expect(log.count == 1)
        #expect(log.all.first?.executable == "/usr/bin/defaults")
        #expect(log.all.first?.arguments == ["delete", "app.fake.CancelOne"])
    }

    // 3. Never called before the picker closes, and presented exactly once.
    @Test func neverCalledWhileThePickerIsStillOpen() {
        let log = RunnerLog()
        var seenWhileOpen: [Int] = []
        var presented = 0
        _ = FolderPicker.pick(present: {
            presented += 1
            seenWhileOpen.append(log.count)
            Thread.sleep(forTimeInterval: 0.3)   // the picker stays open; a cleanup started early would show here
            seenWhileOpen.append(log.count)
            return fpFolders
        }, bundleID: "app.fake.Order", run: fakeRunner(log))
        #expect(presented == 1)
        #expect(seenWhileOpen == [0, 0], "the runner was called while the picker was open: \(seenWhileOpen)")
        #expect(log.waitForCall())
        settle()
        #expect(log.count == 1)
    }

    // 4a. A nonzero exit is swallowed and the folders still come back.
    @Test func aNonzeroExitIsSwallowed() {
        let log = RunnerLog()
        let got = FolderPicker.pick(present: { fpFolders }, bundleID: "app.fake.Nonzero", run: fakeRunner(log, exit: 1))
        #expect(log.waitForCall())
        settle()
        #expect(got == fpFolders)
        #expect(log.count == 1)
    }

    // 4b. A throw is swallowed and the folders still come back.
    @Test func aThrowingRunnerIsSwallowed() {
        let log = RunnerLog()
        let got = FolderPicker.pick(present: { fpFolders }, bundleID: "app.fake.Throws", run: fakeRunner(log, throwing: true))
        #expect(log.waitForCall())
        settle()
        #expect(got == fpFolders)
        #expect(log.count == 1)
    }

    // 4c. Same on a cancel: a failing runner leaves the empty result alone.
    @Test func aFailingRunnerAfterACancelStillReturnsNothing() {
        let log = RunnerLog()
        let got = FolderPicker.pick(present: { [] }, bundleID: "app.fake.CancelFail", run: fakeRunner(log, exit: 255, throwing: true))
        #expect(log.waitForCall())
        settle()
        #expect(got.isEmpty)
    }

    // 5a. The runner is not on the main thread.
    @Test func theRunnerIsNotOnTheMainThread() {
        let log = RunnerLog()
        _ = FolderPicker.pick(present: { fpFolders }, bundleID: "app.fake.Thread", run: fakeRunner(log))
        #expect(log.waitForCall())
        #expect(log.all.first?.onMain == false, "the runner was called on the main thread")
    }

    // 5b. A slow runner does not hold back the picked folders.
    @Test func aSlowRunnerDoesNotDelayTheResult() {
        let log = RunnerLog()
        let start = Date()
        let got = FolderPicker.pick(present: { fpFolders }, bundleID: "app.fake.Slow", run: fakeRunner(log, delay: 2))
        let elapsed = Date().timeIntervalSince(start)
        #expect(got == fpFolders)
        #expect(elapsed < 0.5, "pick took \(elapsed) s with a runner that sleeps 2 s")
        #expect(log.waitForCall())   // let the background call finish being recorded before the test ends
    }

    // 5c. cleanup alone returns at once too.
    @Test func cleanupReturnsAtOnceWithASlowRunner() {
        let log = RunnerLog()
        let start = Date()
        FolderPickerDefaults.cleanup(bundleID: "app.fake.SlowDirect", run: fakeRunner(log, delay: 2))
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5, "cleanup took \(elapsed) s with a runner that sleeps 2 s")
        #expect(log.waitForCall())
        #expect(log.all.first?.arguments == ["delete", "app.fake.SlowDirect"])
    }

    // 6. No bundle identifier, no call: never `delete` with an empty domain.
    @Test(arguments: [nil, "", " ", "\n\t "] as [String?])
    func anEmptyOrMissingIdentifierRunsNothing(id: String?) {
        let log = RunnerLog()
        let got = FolderPicker.pick(present: { fpFolders }, bundleID: id, run: fakeRunner(log))
        FolderPickerDefaults.cleanup(bundleID: id, run: fakeRunner(log))
        settle()
        #expect(got == fpFolders)
        #expect(log.count == 0, "the runner was called with id \(String(describing: id)): \(log.all.map(\.arguments))")
    }

    // 7a. Exactly the identifier given, whatever it looks like; never a different app's.
    @Test(arguments: ["app.fake.Exact", "app.sesame.Sesame", "com.example.Other-App_2"])
    func theIdentifierPassedIsTheOneGiven(id: String) {
        let log = RunnerLog()
        FolderPickerDefaults.cleanup(bundleID: id, run: fakeRunner(log))
        #expect(log.waitForCall())
        settle()
        #expect(log.count == 1)
        #expect(log.all.first?.arguments == ["delete", id])
        #expect(log.all.first?.arguments.count == 2)
    }

    // 7b. In the real app the identifier is Bundle.main's. The test process has its own Bundle.main, so the check
    // is that the default is that value, whatever it is here, and that `pick` uses the default when none is given.
    @Test func theDefaultIdentifierIsBundleMains() {
        #expect(FolderPickerDefaults.appBundleID == Bundle.main.bundleIdentifier)
        let log = RunnerLog()
        _ = FolderPicker.pick(present: { fpFolders }, run: fakeRunner(log))
        let want = Bundle.main.bundleIdentifier ?? ""
        if want.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settle()
            #expect(log.count == 0)
        } else {
            #expect(log.waitForCall())
            settle()
            #expect(log.count == 1)
            #expect(log.all.first?.arguments == ["delete", want])
        }
    }
}

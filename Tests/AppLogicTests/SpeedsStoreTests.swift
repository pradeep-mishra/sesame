import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t17, tester step. Written from the t17 entry, design sections 1, 3 and 8, the plan-2 Conventions (the `bench`
// line of the Helper protocol table) and the plan-1 tests' public names only; no product source read.
//
// `SpeedsStore` keeps the measured seconds per file in `settings.json` (design section 1: `speeds {kind: seconds per
// file}`, written by the app only). The bench itself is `SesameHelper index bench`, started by `HelperClient.runBench`.
// These tests give the `HelperClient` a stub helper (a small shell script in a temp folder) that records its start and
// prints a scripted bench line, so no real model, Vision or helper runs. Everything is in a throwaway HOME.
//
// SUITE PLACEMENT. Nested inside `ModelDownloadTests` like the other HOME-setting suites (HOME is process-wide, and a
// child process inherits it); `swift test --filter ModelDownloadTests` also runs this suite.
//
// API SHAPES these tests pin (the entry names `SpeedsStore`, `measureIfNeeded(modelWhole:)` and the
// `StatusCache.settingsChanged()` hook, and fixes no signatures; if a shape is wrong, ask for a test change rather
// than guessing):
//   1. `final class SpeedsStore` in the `Sesame` target, may be `@MainActor` (every test here is):
//        `init(helper: HelperClient, settingsChanged: @escaping () -> Void, failed: @escaping (Error) -> Void)`
//      `settingsChanged` is what the app wires to `StatusCache.settingsChanged()`; `failed` is how the one failure
//      report reaches the app (a caller shows or logs it). Both are called on the main actor, after the work.
//   2. `func measureIfNeeded(modelWhole: Bool)` is synchronous, non-throwing and returns at once; the bench runs in
//      the one-shot helper and the answer comes through the two closures. It reads `settings.json` through
//      `SettingsFile` when called, so a test may write the file before each call.
//   3. A bench that worked writes `speeds` (the helper's seconds per photo, by kind) into `settings.json`, then calls
//      `settingsChanged` once. Nothing else in the file changes. Whether other kinds' existing speeds are kept or
//      replaced is not pinned (the tests start from an empty `speeds`).
//   4. "A new launch" is a new `SpeedsStore` over the same HOME.
// The stub prints `{"event":"bench","speeds":{"photo":0.37}}` in its normal behaviour; 0.37 is written here by hand.

private let ssStubScript = #"""
#!/bin/sh
# Stub helper for SpeedsStoreTests. Started as: <stub> index bench --text-model <p> --mm-model <p>
# Records its start in bench.starts, then behaves as bench.behavior says (ok when the file is absent).
dir=$(dirname "$0")
{
  echo "pid=$$"
  for a in "$@"; do echo "arg=$a"; done
  echo "--"
} >> "$dir/bench.starts"
behavior=$(cat "$dir/bench.behavior" 2>/dev/null)
if [ "$behavior" = "wait-go" ]; then
  while [ ! -f "$dir/bench.go" ]; do sleep 0.05; done
  behavior=ok
fi
case "$behavior" in
  exit1) exit 1 ;;
  silent) exit 0 ;;
  notbench) echo '{"event":"unit","size":4}'; exit 0 ;;
  garbage) echo 'this is not json'; exit 0 ;;
  *) echo '{"event":"bench","speeds":{"photo":0.37}}'; exit 0 ;;
esac
"""#

private let ssSettingsText = """
{
  "version": 3,
  "startPressed": true,
  "indexDeleted": false,
  "folders": [
    {"path": "/Users/test/Pictures", "code": false, "reading": true},
    {"path": "/Users/test/Developer/api-client", "code": true, "reading": false}
  ],
  "codeSearchOn": true,
  "kindsOn": {"photo": true, "pdf": false, "doc": true, "audio": false, "video": false, "code": true},
  "hotkey": "cmd+opt+k",
  "openWith": {"pdf": "Skim", "media": "IINA", "code": "Cursor"},
  "speeds": SPEEDS,
  "loginDefaultApplied": true
}
"""

private func ssSettings(speeds: String) -> String {
    ssSettingsText.replacingOccurrences(of: "SPEEDS", with: speeds)
}

/// Counts and records what the store's two closures were given. Any thread may call it.
private final class SSLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = 0
    private var failures: [String] = []
    private var diskPhotoSpeedWhenChanged: [Double?] = []
    func settingsChanged(photoOnDisk: Double?) {
        lock.lock(); changed += 1; diskPhotoSpeedWhenChanged.append(photoOnDisk); lock.unlock()
    }
    func failed(_ error: Error) {
        lock.lock(); failures.append(String(describing: error)); lock.unlock()
    }
    var changedCount: Int { lock.lock(); defer { lock.unlock() }; return changed }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures.count }
    var photoSpeedsSeenByHook: [Double?] { lock.lock(); defer { lock.unlock() }; return diskPhotoSpeedWhenChanged }
}

@MainActor
private final class SSEnv {
    let dir: URL
    let helper: URL
    let textModel: URL
    let mmModel: URL
    let folder: URL
    var settings: URL { folder.appendingPathComponent("settings.json") }

    init(home: URL) throws {
        let fm = FileManager.default
        folder = home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true)
        dir = fm.temporaryDirectory.appendingPathComponent("sesame-speeds-stub-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        helper = dir.appendingPathComponent("stub-helper")
        try ssStubScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        textModel = dir.appendingPathComponent("text-model.gguf")
        mmModel = dir.appendingPathComponent("mm-model.gguf")
        fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
        fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))
    }

    func makeClient() -> HelperClient {
        HelperClient(helper: helper, textModel: textModel, mmModel: mmModel)
    }

    func setBehavior(_ behavior: String) throws {
        try behavior.write(to: dir.appendingPathComponent("bench.behavior"), atomically: true, encoding: .utf8)
    }

    func release() {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("bench.go").path, contents: Data())
    }

    func writeSettings(speeds: String = "{}") throws {
        try ssSettings(speeds: speeds).write(to: settings, atomically: true, encoding: .utf8)
    }

    /// settings.json on disk, parsed by the test.
    func onDisk() throws -> NSDictionary {
        let data = try Data(contentsOf: settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// The (pid, args) of every start the stub recorded.
    func starts() -> [(pid: Int, args: [String])] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("bench.starts"), encoding: .utf8)) ?? ""
        var result: [(pid: Int, args: [String])] = []
        var pid = 0
        var args: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line == "--" { result.append((pid, args)); pid = 0; args = []; continue }
            if line.hasPrefix("pid=") { pid = Int(line.dropFirst(4)) ?? 0 }
            else if line.hasPrefix("arg=") { args.append(String(line.dropFirst(4))) }
        }
        return result
    }

    func cleanup() {
        for start in starts() { _ = Darwin.kill(pid_t(start.pid), SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    func makeStore(_ client: HelperClient, _ log: SSLog) -> SpeedsStore {
        let settingsURL = settings
        return SpeedsStore(
            helper: client,
            settingsChanged: {
                // what is on disk at the moment the hook runs: the hook must come after the write
                let data = try? Data(contentsOf: settingsURL)
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let photo = (object?["speeds"] as? [String: Any])?["photo"] as? NSNumber
                log.settingsChanged(photoOnDisk: photo?.doubleValue)
            },
            failed: { error in log.failed(error) })
    }
}

@MainActor
private func ssRun(_ body: @MainActor (SSEnv) async throws -> Void) async throws {
    try await spWithHome { home in
        let env = try SSEnv(home: home)
        defer { env.cleanup() }
        try await body(env)
    }
}

private func ssWithoutSpeeds(_ dictionary: NSDictionary) -> NSDictionary {
    let copy = NSMutableDictionary(dictionary: dictionary)
    copy.removeObject(forKey: "speeds")
    return copy
}

extension ModelDownloadTests {
    @Suite("SpeedsStoreTests", .serialized)
    struct SpeedsStoreTests {

        // MARK: nothing while the model is not whole

        @MainActor
        @Test func measureIfNeededDoesNothingWhileTheModelIsNotWhole() async throws {
            try await ssRun { env in
                try env.writeSettings()
                let before = try env.onDisk()
                let log = SSLog()
                let store = env.makeStore(env.makeClient(), log)

                store.measureIfNeeded(modelWhole: false)
                store.measureIfNeeded(modelWhole: false)
                await spWait(1.0)

                #expect(env.starts().isEmpty, "the bench was started with the model not whole: \(env.starts())")
                #expect(log.changedCount == 0, "settingsChanged was called with no bench")
                #expect(log.failureCount == 0, "a failure was reported with no bench")
                #expect(try env.onDisk() == before, "settings.json changed with no bench")
            }
        }

        // MARK: a whole model and no photo speed: one bench, speeds written

        @MainActor
        @Test func withTheModelWholeAndNoPhotoSpeedItRunsTheBenchOnceAndWritesSpeedsAndNothingElse() async throws {
            try await ssRun { env in
                try env.writeSettings()
                let before = try env.onDisk()
                #expect((before["speeds"] as? NSDictionary)?.count == 0, "the starting file should hold no speeds")
                let log = SSLog()
                let store = env.makeStore(env.makeClient(), log)

                store.measureIfNeeded(modelWhole: true)
                let done = await spEventually { log.changedCount >= 1 }
                #expect(done, "settingsChanged was never called; starts \(env.starts().count), failures \(log.failureCount)")
                await spWait(0.5)

                #expect(env.starts().count == 1, "the bench ran \(env.starts().count) times, not once")
                #expect(log.changedCount == 1, "settingsChanged was called \(log.changedCount) times, not once")
                #expect(log.failureCount == 0, "a failure was reported for a bench that worked")
                #expect(log.photoSpeedsSeenByHook == [0.37],
                        "when settingsChanged ran, settings.json held photo speed \(log.photoSpeedsSeenByHook); the write must come first")

                let after = try env.onDisk()
                let speeds = try #require(after["speeds"] as? NSDictionary, "settings.json has no `speeds` object")
                #expect(speeds.count == 1 && (speeds["photo"] as? NSNumber)?.doubleValue == 0.37,
                        "speeds on disk is \(speeds); the stub printed photo 0.37")
                #expect(ssWithoutSpeeds(after) == ssWithoutSpeeds(before),
                        "a key other than `speeds` changed: before \(ssWithoutSpeeds(before)), after \(ssWithoutSpeeds(after))")

                // the speed is present now, so asking again, in this launch, does not run it again
                store.measureIfNeeded(modelWhole: true)
                await spWait(0.8)
                #expect(env.starts().count == 1, "the bench ran again with a photo speed present")
                #expect(log.changedCount == 1)
            }
        }

        @MainActor
        @Test func theBenchStartsWithIndexBenchAndBothModelFlagsAndNoFolder() async throws {
            try await ssRun { env in
                try env.writeSettings()
                let log = SSLog()
                let store = env.makeStore(env.makeClient(), log)
                store.measureIfNeeded(modelWhole: true)
                let started = await spEventually { env.starts().count == 1 }
                #expect(started, "the bench never started")
                let args = try #require(env.starts().first).args
                // the stub's own first argument is `index`; what follows is what the app passed
                #expect(args.first == "index", "the bench helper was started with \(args)")
                #expect(args.dropFirst().first == "bench", "the bench helper was started with \(args)")
                let flags = Array(args.dropFirst(2))
                #expect(flags.count == 4, "expected only --text-model and --mm-model after `index bench`, got \(flags)")
                var pairs: [String: String] = [:]
                var position = 0
                while position + 1 < flags.count {
                    pairs[flags[position]] = URL(fileURLWithPath: flags[position + 1]).resolvingSymlinksInPath().path
                    position += 2
                }
                #expect(pairs["--text-model"] == env.textModel.resolvingSymlinksInPath().path, "text model flag: \(pairs)")
                #expect(pairs["--mm-model"] == env.mmModel.resolvingSymlinksInPath().path, "image model flag: \(pairs)")
                _ = await spEventually { log.changedCount >= 1 }
            }
        }

        // MARK: a photo speed already stored

        @MainActor
        @Test func withAPhotoSpeedPresentItDoesNotRunTheBench() async throws {
            try await ssRun { env in
                try env.writeSettings(speeds: #"{"photo": 0.5}"#)
                let before = try env.onDisk()
                let log = SSLog()
                let store = env.makeStore(env.makeClient(), log)

                store.measureIfNeeded(modelWhole: true)
                await spWait(1.0)

                #expect(env.starts().isEmpty, "the bench ran with a photo speed already stored: \(env.starts())")
                #expect(log.changedCount == 0 && log.failureCount == 0)
                #expect(try env.onDisk() == before, "settings.json changed with no bench")
            }
        }

        // MARK: two calls while one runs share one run

        @MainActor
        @Test func twoCallsWhileTheBenchRunsMakeOneRunAndOneWrite() async throws {
            try await ssRun { env in
                try env.writeSettings()
                try env.setBehavior("wait-go")
                let log = SSLog()
                let store = env.makeStore(env.makeClient(), log)

                store.measureIfNeeded(modelWhole: true)
                #expect(await spEventually { env.starts().count == 1 }, "the bench never started")
                store.measureIfNeeded(modelWhole: true)
                store.measureIfNeeded(modelWhole: true)
                await spWait(0.6)
                #expect(env.starts().count == 1, "a second call started a second bench while one ran: \(env.starts().count) starts")
                #expect(log.changedCount == 0, "the bench had not finished, yet settingsChanged was called")

                env.release()
                #expect(await spEventually { log.changedCount >= 1 }, "the bench finished and nothing was stored")
                await spWait(0.6)
                #expect(env.starts().count == 1, "the bench ran \(env.starts().count) times in all")
                #expect(log.changedCount == 1, "settingsChanged was called \(log.changedCount) times for one bench")
                #expect(log.failureCount == 0)
                let speeds = try #require(try env.onDisk()["speeds"] as? NSDictionary)
                #expect((speeds["photo"] as? NSNumber)?.doubleValue == 0.37, "speeds on disk is \(speeds)")
            }
        }

        // MARK: a bench that fails

        @MainActor
        @Test func aFailedBenchLeavesSpeedsReportsOnceAndIsNotRetriedInALoop() async throws {
            for behavior in ["exit1", "silent", "notbench", "garbage"] {
                try await ssRun { env in
                    try env.writeSettings()
                    try env.setBehavior(behavior)
                    let before = try env.onDisk()
                    let log = SSLog()
                    let store = env.makeStore(env.makeClient(), log)

                    store.measureIfNeeded(modelWhole: true)
                    let reported = await spEventually { log.failureCount >= 1 }
                    #expect(reported, "[\(behavior)] no failure was reported; starts \(env.starts().count)")

                    // a loop would start the bench again and again, and report again
                    await spWait(2.0)
                    #expect(env.starts().count == 1, "[\(behavior)] the bench ran \(env.starts().count) times in one launch")
                    #expect(log.failureCount == 1, "[\(behavior)] the failure was reported \(log.failureCount) times, not once")
                    #expect(log.changedCount == 0, "[\(behavior)] settingsChanged was called after a failed bench")
                    #expect(try env.onDisk() == before, "[\(behavior)] settings.json changed after a failed bench")

                    // the next launch (a new store over the same HOME) asks again, and a bench that works is kept
                    try env.setBehavior("ok")
                    let nextLog = SSLog()
                    let nextStore = env.makeStore(env.makeClient(), nextLog)
                    nextStore.measureIfNeeded(modelWhole: true)
                    #expect(await spEventually { nextLog.changedCount >= 1 }, "[\(behavior)] the next launch did not retry")
                    #expect(env.starts().count == 2, "[\(behavior)] starts after the next launch: \(env.starts().count)")
                    #expect(nextLog.failureCount == 0)
                    let speeds = try #require(try env.onDisk()["speeds"] as? NSDictionary)
                    #expect((speeds["photo"] as? NSNumber)?.doubleValue == 0.37, "[\(behavior)] speeds after the retry: \(speeds)")
                }
            }
        }
    }
}

// MARK: plan-2 fix round B, tester step, item B4 (the bench before Start, and never beside the index helper)
//
// Written from the fix-round document (B4: "the speed bench runs as soon as the model is whole and no speeds are stored,
// not only after Start, and it never runs while the index helper is running: the supervisor's inputs gain a `measuring`
// flag and the index helper is not started until the bench has finished (a bench that fails or times out sets `measuring`
// false and logs one typed line to app.log)") and the t17 pins above. No product source was read.
//
// API SHAPES B4 pins here (new):
//   1. `SpeedsStore.isMeasuring: Bool` (main actor, read-only). It is the supervisor's `measuring` input in the app. True
//      from the moment `measureIfNeeded(modelWhole:)` accepts a bench (the call itself sets it, before it returns) until the
//      bench has ended; false at all other times: before any call, when the model is not whole, when a photo speed is
//      stored, and, above all, already false INSIDE both closures (`settingsChanged` after a bench that worked, `failed`
//      after one that did not), so a `reevaluate()` made from either closure sees false.
//   2. After a bench that failed the store has appended exactly ONE line to `app.log` (through `SesameFolder.append`, as
//      LoginItemTests reads it: `Sesame/app.log`, or `Sesame/logs/app.log` when that is absent) that starts with "bench "
//      and holds no path (no "/"). The exact words are the fixer's pick (the report suggests `bench status=failed`); the
//      line is written before `failed` is called. A bench that worked logs nothing.
//   3. The store itself never looks at `startPressed`: `measureIfNeeded(modelWhole: true)` with `startPressed` false and no
//      photo speed runs the bench once. (The gate on Start lives in the app wiring; this is a guard that the store has none.)

private func ssAppLogLines(_ env: SSEnv) -> [String] {
    for name in ["app.log", "logs/app.log"] {
        let url = env.folder.appendingPathComponent(name)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("bench ") || $0.contains("bench") }
        }
    }
    return []
}

private final class SSMeasuringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: [Bool]] = [:]
    func note(_ closure: String, _ measuring: Bool) { lock.lock(); seen[closure, default: []].append(measuring); lock.unlock() }
    func values(_ closure: String) -> [Bool] { lock.lock(); defer { lock.unlock() }; return seen[closure] ?? [] }
}

@MainActor
private final class SSStoreRef {
    var store: SpeedsStore?
}

extension ModelDownloadTests.SpeedsStoreTests {

    @MainActor
    @Test func isMeasuringIsTrueFromTheCallUntilTheBenchEndedAndFalseInsideTheSettingsChangedClosure() async throws {
        try await ssRun { env in
            try env.writeSettings()
            try env.setBehavior("wait-go")
            let seen = SSMeasuringBox()
            let ref = SSStoreRef()
            let store = SpeedsStore(
                helper: env.makeClient(),
                settingsChanged: { MainActor.assumeIsolated { seen.note("changed", ref.store?.isMeasuring ?? true) } },
                failed: { _ in MainActor.assumeIsolated { seen.note("failed", ref.store?.isMeasuring ?? true) } })
            ref.store = store
            #expect(!store.isMeasuring, "measuring before any call")

            store.measureIfNeeded(modelWhole: true)
            #expect(store.isMeasuring, "measuring is false right after a bench was accepted: the index helper could start beside it")
            #expect(await spEventually { env.starts().count == 1 }, "the bench never started")
            await spWait(0.4)
            #expect(store.isMeasuring, "measuring ended while the bench still runs")

            env.release()
            #expect(await spEventually { seen.values("changed").count >= 1 }, "the bench ended and nothing was stored")
            #expect(seen.values("changed") == [false], "isMeasuring inside settingsChanged: \(seen.values("changed"))")
            #expect(!store.isMeasuring, "still measuring after the bench ended")
            #expect(seen.values("failed").isEmpty)
            #expect(ssAppLogLines(env).isEmpty, "a bench that worked logged: \(ssAppLogLines(env))")
        }
    }

    @MainActor
    @Test func isMeasuringIsFalseWhenNoBenchIsNeeded() async throws {
        try await ssRun { env in
            // model not whole
            try env.writeSettings()
            let notWhole = env.makeStore(env.makeClient(), SSLog())
            notWhole.measureIfNeeded(modelWhole: false)
            #expect(!notWhole.isMeasuring, "measuring with the model not whole")

            try env.writeSettings(speeds: #"{"photo": 0.5}"#)
            let stored = env.makeStore(env.makeClient(), SSLog())
            stored.measureIfNeeded(modelWhole: true)
            #expect(!stored.isMeasuring, "measuring with a photo speed stored")
            await spWait(0.5)
            #expect(env.starts().isEmpty, "a bench ran: \(env.starts())")
        }
    }

    @MainActor
    @Test func aFailedBenchEndsMeasuringBeforeItReportsAndLogsOneTypedLineWithNoPath() async throws {
        for behavior in ["exit1", "silent", "notbench", "garbage"] {
            try await ssRun { env in
                try env.writeSettings()
                try env.setBehavior(behavior)
                let seen = SSMeasuringBox()
                let ref = SSStoreRef()
                let store = SpeedsStore(
                    helper: env.makeClient(),
                    settingsChanged: { MainActor.assumeIsolated { seen.note("changed", ref.store?.isMeasuring ?? true) } },
                    failed: { _ in MainActor.assumeIsolated { seen.note("failed", ref.store?.isMeasuring ?? true) } })
                ref.store = store

                store.measureIfNeeded(modelWhole: true)
                #expect(store.isMeasuring, "[\(behavior)] not measuring right after the call")
                #expect(await spEventually { seen.values("failed").count >= 1 }, "[\(behavior)] no failure was reported")
                await spWait(0.5)

                #expect(seen.values("failed") == [false], "[\(behavior)] isMeasuring inside failed: \(seen.values("failed"))")
                #expect(!store.isMeasuring, "[\(behavior)] still measuring after the bench failed: the index helper would never start")
                let lines = ssAppLogLines(env)
                #expect(lines.count == 1, "[\(behavior)] app.log holds \(lines.count) bench lines: \(lines)")
                #expect(lines.first?.hasPrefix("bench ") == true, "[\(behavior)] the line is \(lines)")
                #expect(lines.first?.contains("/") == false, "[\(behavior)] the line names a path: \(lines)")
            }
        }
    }

    // GUARD: passes today. The store has no gate on Start; the gate is in the app wiring and goes away there.
    @MainActor
    @Test func theBenchRunsBeforeStartWasEverPressedWhenTheModelIsWholeAndNoSpeedIsStored() async throws {
        try await ssRun { env in
            try ssSettings(speeds: "{}").replacingOccurrences(of: "\"startPressed\": true", with: "\"startPressed\": false")
                .write(to: env.settings, atomically: true, encoding: .utf8)
            #expect(try env.onDisk()["startPressed"] as? Bool == false, "setup: Start must not be pressed")
            let log = SSLog()
            let store = env.makeStore(env.makeClient(), log)

            store.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { log.changedCount >= 1 }, "no bench ran before Start; starts \(env.starts().count), failures \(log.failureCount)")
            #expect(env.starts().count == 1, "the bench ran \(env.starts().count) times")
            let speeds = try #require(try env.onDisk()["speeds"] as? NSDictionary)
            #expect((speeds["photo"] as? NSNumber)?.doubleValue == 0.37, "speeds on disk: \(speeds)")
            #expect(try env.onDisk()["startPressed"] as? Bool == false, "the bench pressed Start")
        }
    }
}

// =================================================================================================================
// plan-2 fix round D, tester step, item D2 (R3-02, R3-06): a bench that hangs ends at the timeout, and a bench ended by Quit
// writes nothing. Written from the fix-round document ("`BenchRun` terminates the bench process, ends measuring
// (`isMeasuring` false), writes exactly one typed app.log line `bench status=timeout` (no path), and the supervisor's
// `measuring` input clears so the index helper starts. A bench that is terminated because of Quit (shutdown) must not write
// `bench status=failed` or `timeout` (R3-06). The speeds stay unknown, estimates keep saying "measuring speed", and the
// bench is retried at the next launch only. ... a SpeedsStore test that a timeout ends measuring before it reports") and the
// B4 pins above. No product source was read.
//
// API SHAPES D2 pins here (new; the HelperClient seam is pinned in HelperClientShutdownBenchTests):
//   `HelperClient.init(helper:textModel:mmModel:benchTimeout:)` and `HelperClient.benchTimeout` (240 s).
//   A timeout reaches the store as a failed bench of its own kind: `isMeasuring` is already false inside `failed`, which is
//   called once, and app.log holds exactly ONE bench line, `bench status=timeout`, with no path and no "status=failed". The
//   line is written before `failed` is called, as the B4 failure line is. `settingsChanged` is not called and settings.json
//   is as it was. The bench is not started again in this launch; a new store (the next launch) asks again.
//   A Quit (`HelperClient.shutdown`) that ends a running bench writes no `bench` line at all, neither status=failed nor
//   status=timeout, also not when a timeout comes due after the shutdown. Whether `failed` is called for that bench is not
//   pinned, and what `isMeasuring` says afterwards is not pinned.
// The stub is the one above: `wait-go` never exits until `bench.go` exists, and the tests never create it.
// =================================================================================================================

@MainActor
private extension SSEnv {
    func makeClient(benchTimeout: TimeInterval) -> HelperClient {
        HelperClient(helper: helper, textModel: textModel, mmModel: mmModel, benchTimeout: benchTimeout)
    }
}

@MainActor
private final class SSTimeoutHost: IndexHost {
    private(set) var isRunning = false
    var onExit: ((HelperExit) -> Void)?
    private(set) var log: [String] = []
    func start() { log.append("start"); isRunning = true }
    func stopClean() { log.append("stop") }
}

private final class SSDone: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

extension ModelDownloadTests.SpeedsStoreTests {

    @MainActor
    @Test func aBenchThatHangsEndsMeasuringAtTheTimeoutBeforeItReportsAndLogsOneTimeoutLineWithNoPath() async throws {
        try await ssRun { env in
            try env.writeSettings()
            try env.setBehavior("wait-go")                      // never released
            let before = try env.onDisk()
            let seen = SSMeasuringBox()
            let ref = SSStoreRef()
            let store = SpeedsStore(
                helper: env.makeClient(benchTimeout: 1.5),
                settingsChanged: { MainActor.assumeIsolated { seen.note("changed", ref.store?.isMeasuring ?? true) } },
                failed: { _ in MainActor.assumeIsolated { seen.note("failed", ref.store?.isMeasuring ?? true) } })
            ref.store = store

            store.measureIfNeeded(modelWhole: true)
            #expect(store.isMeasuring, "not measuring right after the call")
            #expect(await spEventually { env.starts().count == 1 }, "the bench never started")
            await spWait(0.5)
            #expect(store.isMeasuring, "measuring ended 0.5 s into a 1.5 s timeout")
            #expect(seen.values("failed").isEmpty, "failed was called before the timeout")

            let failedCalls: @MainActor () -> Int = { seen.values("failed").count }
            let reported = await spEventually(timeout: 15) { failedCalls() >= 1 }
            #expect(reported, "a hung bench was never reported: isMeasuring stays \(store.isMeasuring) for the whole session and no index helper starts (R3-02)")
            await spWait(0.6)
            #expect(seen.values("failed") == [false], "isMeasuring inside failed: \(seen.values("failed"))")
            #expect(!store.isMeasuring, "still measuring after the timeout: the index helper would never start")
            let lines = ssAppLogLines(env)
            #expect(lines.count == 1, "app.log holds \(lines.count) bench lines: \(lines)")
            #expect(lines.first?.hasPrefix("bench status=timeout") == true, "the line is \(lines)")
            #expect(lines.first?.contains("/") == false, "the line names a path: \(lines)")
            #expect(!lines.contains { $0.contains("status=failed") }, "a status=failed line for a timeout: \(lines)")

            // the speeds stay unknown, nothing was written, and the bench is not run again in this launch
            #expect(seen.values("changed").isEmpty, "settingsChanged was called after a timeout")
            #expect(try env.onDisk() == before, "settings.json changed after a timeout")
            store.measureIfNeeded(modelWhole: true)
            await spWait(2.0)
            #expect(env.starts().count == 1, "the bench ran \(env.starts().count) times in one launch")
            #expect(ssAppLogLines(env).count == 1, "more lines after a later call: \(ssAppLogLines(env))")
            #expect(seen.values("failed").count == 1, "the timeout was reported \(seen.values("failed").count) times")
            #expect(Darwin.kill(pid_t(env.starts().first?.pid ?? 0), 0) != 0, "the hung bench process is still running after the timeout")

            // the next launch asks again, and a bench that works is kept
            try env.setBehavior("ok")
            let nextLog = SSLog()
            let next = env.makeStore(env.makeClient(), nextLog)
            next.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { nextLog.changedCount >= 1 }, "the next launch did not retry")
            #expect(env.starts().count == 2)
            let speeds = try #require(try env.onDisk()["speeds"] as? NSDictionary)
            #expect((speeds["photo"] as? NSNumber)?.doubleValue == 0.37, "speeds after the retry: \(speeds)")
        }
    }

    @MainActor
    @Test func aTimeoutClearsTheSupervisorsMeasuringInputSoTheIndexHelperStarts() async throws {
        try await ssRun { env in
            try env.writeSettings()
            try env.setBehavior("wait-go")
            let host = SSTimeoutHost()
            let ref = SSStoreRef()
            let supervisor = HelperSupervisor(host: host, inputs: {
                HelperSupervisor.Inputs(startPressed: true, indexDeleted: false, modelWhole: true, pauseReasons: [],
                                        quitting: false, measuring: ref.store?.isMeasuring ?? false)
            })
            // what the app wires: a reevaluate from both closures, after the bench has ended
            let store = SpeedsStore(
                helper: env.makeClient(benchTimeout: 1.5),
                settingsChanged: { MainActor.assumeIsolated { supervisor.reevaluate() } },
                failed: { _ in MainActor.assumeIsolated { supervisor.reevaluate() } })
            ref.store = store

            store.measureIfNeeded(modelWhole: true)
            supervisor.reevaluate()
            #expect(await spEventually { env.starts().count == 1 }, "the bench never started")
            await spWait(0.6)
            #expect(host.log.isEmpty, "the index helper started beside the bench: \(host.log)")

            #expect(await spEventually(timeout: 15) { host.log == ["start"] },
                    "the index helper never started after the bench timed out (log \(host.log), measuring \(store.isMeasuring))")
            await spWait(0.5)
            #expect(host.log == ["start"], "the index helper log after the timeout: \(host.log)")
        }
    }

    @MainActor
    @Test func aQuitThatEndsARunningBenchWritesNoBenchLine() async throws {
        try await ssRun { env in
            try env.writeSettings()
            try env.setBehavior("wait-go")
            let client = env.makeClient()
            let store = SpeedsStore(helper: client, settingsChanged: {}, failed: { _ in })

            store.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { env.starts().count == 1 }, "the bench never started")
            let pid = env.starts().first?.pid ?? 0

            let done = SSDone()
            client.shutdown(timeout: 3) { done.mark() }
            #expect(await spEventually(timeout: 20) { done.calls >= 1 }, "the shutdown completion was never called")
            #expect(Darwin.kill(pid_t(pid), 0) != 0, "the bench is still running after the shutdown completed")
            await spWait(1.5)
            let lines = ssAppLogLines(env)
            #expect(lines.isEmpty, "a Quit that ended the bench wrote \(lines): the terminated bench is counted as failed (R3-06)")
        }
    }

    @MainActor
    @Test func aTimeoutThatWouldComeDueAfterAQuitWritesNothingEither() async throws {
        try await ssRun { env in
            try env.writeSettings()
            try env.setBehavior("wait-go")
            let client = env.makeClient(benchTimeout: 1.5)
            let store = SpeedsStore(helper: client, settingsChanged: {}, failed: { _ in })

            store.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { env.starts().count == 1 }, "the bench never started")
            await spWait(0.3)
            let done = SSDone()
            client.shutdown(timeout: 3) { done.mark() }
            #expect(await spEventually(timeout: 20) { done.calls >= 1 }, "the shutdown completion was never called")
            await spWait(3.0)                                   // well past the 1.5 s timeout
            let lines = ssAppLogLines(env)
            #expect(lines.isEmpty, "bench lines after a Quit: \(lines)")
        }
    }

    // GUARD: passes today once the new parameter compiles. A bench that works inside the timeout logs nothing.
    @MainActor
    @Test func aBenchThatWorksInsideTheTimeoutWritesItsSpeedsAndNoBenchLine() async throws {
        try await ssRun { env in
            try env.writeSettings()
            let log = SSLog()
            let store = SpeedsStore(
                helper: env.makeClient(benchTimeout: 20),
                settingsChanged: { log.settingsChanged(photoOnDisk: nil) },
                failed: { error in log.failed(error) })
            store.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { log.changedCount >= 1 }, "the bench never finished")
            await spWait(0.5)
            #expect(log.failureCount == 0)
            #expect(ssAppLogLines(env).isEmpty, "a bench that worked logged: \(ssAppLogLines(env))")
            let speeds = try #require(try env.onDisk()["speeds"] as? NSDictionary)
            #expect((speeds["photo"] as? NSNumber)?.doubleValue == 0.37, "speeds on disk: \(speeds)")
        }
    }
}

@MainActor
private func ssSpeedsOnDisk(_ env: SSEnv) -> [String: Double] {
    guard let object = try? env.onDisk(), let speeds = object["speeds"] as? NSDictionary else { return [:] }
    var result: [String: Double] = [:]
    for (key, value) in speeds { if let key = key as? String, let number = value as? NSNumber { result[key] = number.doubleValue } }
    return result
}

extension ModelDownloadTests.SpeedsStoreTests {

    @MainActor
    @Test func aPhotoSpeedAloneIsEnoughWhateverTheOldCodeSwitchSays() async throws {
        try await ssRun { env in
            try env.writeSettings(speeds: #"{"photo": 0.37}"#)
            let before = try env.onDisk()
            #expect((before["codeSearchOn"] as? NSNumber)?.boolValue == true, "the starting file should hold codeSearchOn true")
            let log = SSLog()
            let store = env.makeStore(env.makeClient(), log)

            store.measureIfNeeded(modelWhole: true)
            store.measureIfNeeded(modelWhole: true)
            await spWait(1.0)

            #expect(env.starts().isEmpty, "the bench ran with a photo speed stored and no code speed: \(env.starts())")
            #expect(!store.isMeasuring)
            #expect(log.changedCount == 0 && log.failureCount == 0)
            #expect(try env.onDisk() == before, "settings.json changed with no bench")
        }
    }

    @MainActor
    @Test func aPhotoSpeedAndAnOldCodeSpeedStartNothing() async throws {
        try await ssRun { env in
            try env.writeSettings(speeds: #"{"photo": 0.5, "code": 0.3}"#)
            let before = try env.onDisk()
            let log = SSLog()
            let store = env.makeStore(env.makeClient(), log)

            store.measureIfNeeded(modelWhole: true)
            await spWait(1.0)

            #expect(env.starts().isEmpty, "the bench ran with a photo speed and an old code speed: \(env.starts())")
            #expect(log.changedCount == 0 && log.failureCount == 0)
            #expect(try env.onDisk() == before, "settings.json changed with no bench")
        }
    }

    @MainActor
    @Test func anOldCodeSpeedAloneStillMeasuresBecauseThePhotoSpeedIsMissing() async throws {
        try await ssRun { env in
            try env.writeSettings(speeds: #"{"code": 0.3}"#)
            let log = SSLog()
            let store = env.makeStore(env.makeClient(), log)

            store.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { log.changedCount >= 1 }, "a missing photo speed did not measure; starts \(env.starts().count)")
            await spWait(0.5)

            #expect(env.starts().count == 1, "the bench ran \(env.starts().count) times")
            #expect(ssSpeedsOnDisk(env)["photo"] == 0.37, "speeds on disk: \(ssSpeedsOnDisk(env))")
        }
    }

    @MainActor
    @Test func aBenchWithOnlyAPhotoSpeedIsTheLastBenchWhateverTheOldCodeSwitchSays() async throws {
        try await ssRun { env in
            try env.writeSettings()
            let log = SSLog()
            let store = env.makeStore(env.makeClient(), log)

            store.measureIfNeeded(modelWhole: true)
            #expect(await spEventually { log.changedCount >= 1 }, "no bench ran; failures \(log.failureCount)")
            await spWait(0.5)
            #expect(env.starts().count == 1, "the bench ran \(env.starts().count) times, not once")
            #expect(ssSpeedsOnDisk(env) == ["photo": 0.37], "speeds on disk: \(ssSpeedsOnDisk(env))")

            store.measureIfNeeded(modelWhole: true)
            store.measureIfNeeded(modelWhole: true)
            let next = env.makeStore(env.makeClient(), SSLog())
            next.measureIfNeeded(modelWhole: true)
            await spWait(1.0)
            #expect(env.starts().count == 1, "the bench ran again with a photo speed stored: \(env.starts().count) starts")
            #expect(log.changedCount == 1)
            #expect(!store.isMeasuring && !next.isMeasuring)
        }
    }
}


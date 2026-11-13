import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2 fix round A, tester step: items A5 (S7.10, S7.11) and A8 (S7.2, S7.5). Written from the fix-round entries A5 and
// A8, the reviewer's findings ("Quit does not stop a running `index bench`"; "a second index helper can be started while one
// is stopping") and the sealed HelperClientTests.swift (the stub helper and the shapes of `runBench`, `shutdown`,
// `stopIndex`, `onExit`, `preview`; the stub and the harness are private there, so this file holds its own copies, named
// `hs...`). No product source read.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests`, as HelperClientTests is, for the same reason: HOME is process-wide.
//
// What the entries fix (written by hand):
// A5. `shutdown(timeout:completion:)` also ends a running `index bench`: it terminates it (SIGTERM), kills it when it is
//     still there `timeout` seconds later, and waits for it. `completion` is called once, after encode, index and bench are
//     all gone (no process of the stub remains). A bench is never started after `shutdown` has been called (a `runBench`
//     after it starts nothing). The stub's bench stays alive (`wait-go`, as the t17 tests do) or ignores SIGTERM
//     (`ignore-term`, new, `trap '' TERM`), and the test looks at the pids it recorded.
//     What a bench's own `runBench` completion gets after it is ended is not pinned; it is called at most once.
// A8. A `preview` while the index process is stopping (after `stopIndex()` or during a Pause or a Resume, when the process has
//     been told to end and has not exited yet) starts no second process and does not make the exit of the stopping one
//     unplanned. The preview may be queued (sent to a new process once the old one is gone) or dropped; both pass. The
//     stub index ignores the end of stdin (`ignore-eof`) so the stopping process stays visible for a while. The restart
//     delay that the reviewer names lives in the supervisor and is not driven here: the test shows no unplanned exit was
//     reported and no second process came, which is what raises that count.
// Red today: A5 tests (the completion comes while the bench still runs, the bench is never ended, a bench starts after
// shutdown) and the A8 test (a second index process is started by the preview).

// MARK: the stub helper (a copy of HelperClientTests' stub plus the bench behavior `ignore-term`)

private let hsStubScript = #"""
#!/bin/sh
# Stub helper for HelperClientShutdownBenchTests. First argument is the mode (encode or index); the rest are flags.
dir=$(dirname "$0")
mode="$1"
shift
if [ "$mode" = "index" ] && [ "$1" = "bench" ]; then
  {
    echo "pid=$$"
    for a in "$@"; do echo "arg=$a"; done
    echo "--"
  } >> "$dir/bench.starts"
  behavior=$(cat "$dir/bench.behavior" 2>/dev/null)
  if [ "$behavior" = "ignore-term" ]; then trap '' TERM; fi
  if [ "$behavior" = "wait-go" ] || [ "$behavior" = "ignore-term" ]; then
    while [ ! -f "$dir/bench.go" ]; do sleep 0.05; done
    behavior=ok
  fi
  case "$behavior" in
    *) echo '{"event":"bench","speeds":{"photo":0.31}}'; exit 0 ;;
  esac
fi
{
  echo "pid=$$"
  echo "mode=$mode"
  for a in "$@"; do echo "arg=$a"; done
  echo "--"
} >> "$dir/$mode.starts"
while IFS= read -r line; do
  printf '%s\t%s\n' "$$" "$line" >> "$dir/$mode.stdin"
done
printf '%s\n' "$$" >> "$dir/$mode.eof"
while [ -f "$dir/$mode.ignore-eof" ]; do sleep 0.2; done
"""#

private struct HSStart {
    var pid: Int
    var args: [String]
}

@MainActor
private final class HSEnv {
    let dir: URL
    let helper: URL
    let textModel: URL
    let mmModel: URL
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }

    init(home: URL) throws {
        let fm = FileManager.default
        self.home = home
        dir = fm.temporaryDirectory.appendingPathComponent("sesame-helpershutdown-stub-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        helper = dir.appendingPathComponent("stub-helper")
        try hsStubScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        textModel = dir.appendingPathComponent("text-model.gguf")
        mmModel = dir.appendingPathComponent("mm-model.gguf")
        fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
        fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))
    }

    func makeClient() -> HelperClient {
        HelperClient(helper: helper, textModel: textModel, mmModel: mmModel)
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func starts(_ mode: String) -> [HSStart] {
        var result: [HSStart] = []
        var current = HSStart(pid: 0, args: [])
        for line in read(mode + ".starts").split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line == "--" { result.append(current); current = HSStart(pid: 0, args: []); continue }
            if line.hasPrefix("pid=") { current.pid = Int(line.dropFirst(4)) ?? 0 }
            else if line.hasPrefix("arg=") { current.args.append(String(line.dropFirst(4))) }
        }
        return result
    }

    func stdin(_ mode: String) -> [(pid: Int, line: String)] {
        read(mode + ".stdin").split(separator: "\n", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            return (pid, String(parts[1]))
        }
    }

    func lines(_ mode: String) -> [String] { stdin(mode).map(\.line) }

    func eofPids(_ mode: String) -> [Int] {
        read(mode + ".eof").split(separator: "\n", omittingEmptySubsequences: true).compactMap { Int($0) }
    }

    func isGone(_ pid: Int) -> Bool { Darwin.kill(pid_t(pid), 0) != 0 && errno == ESRCH }

    func setBench(_ behavior: String) throws {
        try behavior.write(to: dir.appendingPathComponent("bench.behavior"), atomically: true, encoding: .utf8)
    }

    func releaseBench() { FileManager.default.createFile(atPath: dir.appendingPathComponent("bench.go").path, contents: Data()) }

    func setIgnoreEOF(_ mode: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(mode + ".ignore-eof").path, contents: Data()) }

    func clearIgnoreEOF(_ mode: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(mode + ".ignore-eof")) }

    /// Every process the stubs recorded that is still alive (a sleeping child of a stub is not one of them).
    func alive() -> [Int] {
        ["encode", "index", "bench"].flatMap { starts($0).map(\.pid) }.filter { !isGone($0) }
    }

    func cleanup() {
        releaseBench()
        for mode in ["encode", "index", "bench"] {
            for start in starts(mode) { _ = Darwin.kill(pid_t(start.pid), SIGKILL) }
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
private func hsRun(_ body: @MainActor (HSEnv) async throws -> Void) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-helpershutdown-home-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    let env = try HSEnv(home: home)
    defer {
        env.cleanup()
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before touching anything")
        return
    }
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)
    try await body(env)
}

private final class HSDone: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func mark() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class HSBenchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record(_ result: Result<[String: Double], Error>) { lock.lock(); count += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class HSExits: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(helper: String, exit: HelperExit)] = []
    func record(_ helper: String, _ exit: HelperExit) { lock.lock(); items.append((helper, exit)); lock.unlock() }
    var all: [(helper: String, exit: HelperExit)] { lock.lock(); defer { lock.unlock() }; return items }
    func of(_ helper: String) -> [HelperExit] { all.filter { $0.helper == helper }.map(\.exit) }
}

@MainActor
private func hsEventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
private func hsWait(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

extension ModelDownloadTests {
    @Suite("HelperClientShutdownBenchTests", .serialized)
    struct HelperClientShutdownBenchTests {

        // MARK: A5, Quit stops a running bench

        @MainActor
        @Test func shutdownTerminatesARunningBenchAndCompletesOnlyAfterItIsGone() async throws {
            try await hsRun { env in
                try env.setBench("wait-go")
                let client = env.makeClient()
                let results = HSBenchResults()
                client.runBench { results.record($0) }
                #expect(await hsEventually { env.starts("bench").count == 1 }, "the bench never started")
                let benchPid = env.starts("bench").first?.pid ?? 0
                #expect(benchPid > 0 && !env.isGone(benchPid), "setup: the bench stub is not running")

                let done = HSDone()
                client.shutdown(timeout: 4) { done.mark() }
                #expect(await hsEventually(timeout: 15) { env.isGone(benchPid) }, "the bench process \(benchPid) is still running 15 s after shutdown: Quit does not stop a running bench")
                #expect(await hsEventually(timeout: 15) { done.calls >= 1 }, "the shutdown completion was never called")
                #expect(env.isGone(benchPid), "the completion was called while the bench was still alive")
                await hsWait(0.6)
                #expect(done.calls == 1, "the completion was called \(done.calls) times")
                #expect(env.alive().isEmpty, "processes of the stub are still alive after the completion: \(env.alive())")
                #expect(results.total <= 1, "the bench's own completion was called \(results.total) times")
                #expect(env.starts("bench").count == 1 && env.starts("index").isEmpty && env.starts("encode").isEmpty,
                        "shutdown started a process: bench \(env.starts("bench").count), index \(env.starts("index").count), encode \(env.starts("encode").count)")

                // a bench is never started after shutdown, not even by a later runBench
                client.runBench { results.record($0) }
                await hsWait(1.2)
                #expect(env.starts("bench").count == 1, "a bench was started after shutdown: \(env.starts("bench").count) starts")
            }
        }

        @MainActor
        @Test func aBenchThatIgnoresTerminateIsKilledAfterTheTimeoutAndTheCompletionWaitsForIt() async throws {
            try await hsRun { env in
                try env.setBench("ignore-term")
                let client = env.makeClient()
                let results = HSBenchResults()
                client.runBench { results.record($0) }
                #expect(await hsEventually { env.starts("bench").count == 1 }, "the bench never started")
                let benchPid = env.starts("bench").first?.pid ?? 0
                try await Task.sleep(nanoseconds: 400_000_000)       // the stub has set its trap by now

                let done = HSDone()
                client.shutdown(timeout: 3) { done.mark() }
                await hsWait(0.8)
                #expect(env.isGone(benchPid) == false, "the bench that ignores terminate was gone 0.8 s into a 3 s timeout")
                #expect(done.calls == 0, "the completion was called while a bench that ignores terminate was alive")
                #expect(await hsEventually(timeout: 16) { env.isGone(benchPid) }, "the bench was not killed after the timeout")
                #expect(await hsEventually(timeout: 16) { done.calls >= 1 }, "the completion was never called after the kill")
                #expect(env.isGone(benchPid), "the completion was called while the bench was still alive")
                await hsWait(0.6)
                #expect(done.calls == 1, "the completion was called \(done.calls) times")
                #expect(results.total <= 1, "the bench's own completion was called \(results.total) times")
            }
        }

        @MainActor
        @Test func shutdownWithEncodeIndexAndABenchRunningCompletesOnceAfterAllThreeAreGone() async throws {
            try await hsRun { env in
                try env.setBench("wait-go")
                let client = env.makeClient()
                client.embed(id: 1, text: "x", role: .query)
                client.reset()
                client.runBench { _ in }
                #expect(await hsEventually { env.lines("encode").count == 1 && env.lines("index").count == 1 && env.starts("bench").count == 1 },
                        "the three helpers did not all start")
                let pids = [env.starts("encode").first?.pid ?? 0, env.starts("index").first?.pid ?? 0, env.starts("bench").first?.pid ?? 0]
                #expect(pids.allSatisfy { $0 > 0 })

                let done = HSDone()
                client.shutdown(timeout: 4) { done.mark() }
                #expect(await hsEventually(timeout: 20) { done.calls >= 1 }, "the completion was never called")
                #expect(pids.allSatisfy { env.isGone($0) }, "the completion was called while a helper was alive: \(pids.filter { !env.isGone($0) })")
                await hsWait(0.6)
                #expect(done.calls == 1, "the completion was called \(done.calls) times")
                #expect(env.alive().isEmpty, "stub processes remain after the completion: \(env.alive())")
                #expect(env.starts("encode").count == 1 && env.starts("index").count == 1 && env.starts("bench").count == 1,
                        "shutdown started a process")
            }
        }

        @MainActor
        @Test func aBenchRequestedAfterShutdownStartsNothing() async throws {
            try await hsRun { env in
                let client = env.makeClient()
                let done = HSDone()
                client.shutdown(timeout: 1) { done.mark() }
                #expect(await hsEventually(timeout: 12) { done.calls >= 1 }, "the completion was never called with nothing running")
                let results = HSBenchResults()
                client.runBench { results.record($0) }
                await hsWait(1.5)
                #expect(env.starts("bench").isEmpty, "a bench was started after shutdown: \(env.starts("bench").count) starts")
                #expect(env.alive().isEmpty, "a stub process is running after shutdown: \(env.alive())")
                #expect(results.total <= 1, "the bench's completion was called \(results.total) times")
            }
        }

        // MARK: A8, a preview while the index process is stopping

        @MainActor
        @Test func aPreviewWhileTheIndexProcessIsStoppingStartsNoSecondProcessAndMakesNoUnplannedExit() async throws {
            try await hsRun { env in
                env.setIgnoreEOF("index")
                let client = env.makeClient()
                let exits = HSExits()
                client.onExit = { helper, exit in exits.record(helper, exit) }
                client.reset()
                #expect(await hsEventually { !env.lines("index").isEmpty }, "index never got the reset")
                let first = env.starts("index").first?.pid ?? 0
                #expect(first > 0)

                client.stopIndex()                                    // a Pause: the process has been told to end and lingers
                #expect(await hsEventually { env.eofPids("index").contains(first) }, "the stub never saw its stdin end")
                #expect(env.isGone(first) == false, "setup: the stopping stub is already gone")

                client.preview(ticket: 1, file: "/tmp/a-photo.jpg", passage: nil, query: "dog")
                await hsWait(1.2)
                #expect(env.starts("index").count == 1, "a preview while the index process was stopping started another process: \(env.starts("index").map(\.pid))")
                #expect(exits.all.isEmpty, "an exit was reported while the stopping process was still alive: \(exits.all)")

                // the stopping process now ends; the preview was dropped or queued, both fine
                env.clearIgnoreEOF("index")
                #expect(await hsEventually(timeout: 15) { env.isGone(first) }, "the stopping stub did not exit")
                await hsWait(1.5)
                #expect(exits.of("index") == [.planned], "the stop the app asked for must be the only exit and planned, got \(exits.of("index"))")
                #expect(env.starts("index").count <= 2, "more than one process was started for one preview: \(env.starts("index").map(\.pid))")
                #expect(!env.stdin("index").contains { $0.pid == first && $0.line.contains("\"preview\"") },
                        "the preview was written to the process that had been told to stop")
                if env.starts("index").count == 2 {
                    let second = env.starts("index")[1].pid
                    #expect(env.stdin("index").contains { $0.pid == second && $0.line.contains("\"preview\"") },
                            "a second process was started after the first exited but it did not get the queued preview")
                }
            }
        }
    }
}

// =================================================================================================================
// plan-2 fix round D, tester step, item D2 (R3-02): the speed bench needs a timeout. Written from the fix-round document
// ("a named constant (the tester pins the name; value 240 s as a starting point, written as a hand value in the tests)
// after which `BenchRun` terminates the bench process, ends measuring, writes exactly one typed app.log line `bench
// status=timeout` ... Tests with a stub bench script that never exits and the manual timeout seam") and the review report
// (R3-02: `BenchRun.measure` blocks on `readDataToEndOfFile()` and `waitUntilExit()` with no time bound). No product source
// was read. The stub is the one above: `wait-go` never exits until `bench.go` exists, and the test never creates it.
//
// API SHAPES D2 pins here (new):
//   1. `HelperClient.benchTimeout: TimeInterval`, a `static let`, the named constant. It is 240 (seconds), the starting
//      value of the document, written here as the hand value.
//   2. The manual seam: `HelperClient.init(helper:textModel:mmModel:benchTimeout:)` gains a last parameter
//      `benchTimeout: TimeInterval = HelperClient.benchTimeout`, so every sealed call compiles. A test passes a small value.
//   3. A bench that has run `benchTimeout` seconds without ending is terminated (SIGTERM, as `shutdown` does) by `BenchRun`;
//      the `runBench` completion is then called exactly once, with a `.failure` (the error type is the fixer's pick; the
//      app's SpeedsStore tells a timeout from another failure, SpeedsStoreTests pins that). The timeout never fires before
//      the stated time, and never for a bench that ended in time.
//   4. Not pinned: how long a bench that ignores SIGTERM lingers after the timeout, and the grace before a kill.
// =================================================================================================================

@MainActor
private extension HSEnv {
    func makeClient(benchTimeout: TimeInterval) -> HelperClient {
        HelperClient(helper: helper, textModel: textModel, mmModel: mmModel, benchTimeout: benchTimeout)
    }
}

private final class HSTimedBench: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(at: Date, ok: Bool)] = []
    func record(_ result: Result<[String: Double], Error>) {
        var ok = false
        if case .success = result { ok = true }
        lock.lock(); items.append((Date(), ok)); lock.unlock()
    }
    var all: [(at: Date, ok: Bool)] { lock.lock(); defer { lock.unlock() }; return items }
}

extension ModelDownloadTests.HelperClientShutdownBenchTests {

    @MainActor
    @Test func theBenchTimeoutIsTheNamedConstantOf240Seconds() {
        #expect(HelperClient.benchTimeout == 240, "the bench timeout is \(HelperClient.benchTimeout) s")
    }

    @MainActor
    @Test func aBenchThatNeverExitsIsTerminatedAtTheTimeoutAndItsCompletionGetsOneFailure() async throws {
        try await hsRun { env in
            try env.setBench("wait-go")                         // never released: the bench hangs
            let client = env.makeClient(benchTimeout: 1.5)
            let timed = HSTimedBench()
            let startedAt = Date()
            client.runBench { timed.record($0) }
            #expect(await hsEventually { env.starts("bench").count == 1 }, "the bench never started")
            let pid = env.starts("bench").first?.pid ?? 0
            #expect(pid > 0)

            await hsWait(0.5)
            #expect(!env.isGone(pid), "the bench was terminated 0.5 s into a 1.5 s timeout")
            #expect(timed.all.isEmpty, "the completion came before the timeout")

            #expect(await hsEventually(timeout: 15) { env.isGone(pid) }, "the bench \(pid) still runs 15 s after a 1.5 s timeout: nothing ends a hung bench (R3-02)")
            #expect(await hsEventually(timeout: 15) { !timed.all.isEmpty }, "the completion was never called after the timeout")
            let first = timed.all.first
            #expect(first?.ok == false, "the completion of a timed-out bench is not a failure")
            if let first {
                let elapsed = first.at.timeIntervalSince(startedAt)
                #expect(elapsed >= 1.2, "the completion came after \(elapsed) s, before the 1.5 s timeout")
            }
            await hsWait(0.8)
            #expect(timed.all.count == 1, "the completion was called \(timed.all.count) times")
            #expect(env.alive().isEmpty, "stub processes are still alive after the timeout: \(env.alive())")
            #expect(env.starts("bench").count == 1, "a second bench was started: \(env.starts("bench").count)")
        }
    }

    // GUARD: passes today once the new parameter compiles. A bench that ends in time is not touched by the timeout.
    @MainActor
    @Test func aBenchThatEndsInTimeSucceedsOnceAndTheTimeoutNeverFiresLater() async throws {
        try await hsRun { env in
            let client = env.makeClient(benchTimeout: 1.5)      // the stub's normal behaviour: prints its speeds and exits 0
            let timed = HSTimedBench()
            client.runBench { timed.record($0) }
            #expect(await hsEventually { !timed.all.isEmpty }, "the bench never completed")
            #expect(timed.all.first?.ok == true, "a bench that worked completed as a failure")
            await hsWait(2.5)                                   // past the timeout
            #expect(timed.all.count == 1, "the completion was called \(timed.all.count) times")
            #expect(env.starts("bench").count == 1)
        }
    }
}

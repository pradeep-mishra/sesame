import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-2-t36 (F14), tester step. Written from the t36 entry ("HelperEmbedder with a stub HelperClient that reports an
// unplanned exit of the encode helper: every waiting embed fails at once, not after its 20 s timeout"), design section 3,
// the plan-1 t35 and t36 reports (names only) and HelperClientTests (the stub-script method); no product source read.
//
// WHAT THESE DRIVE. A real `HelperClient` over a stub helper (a shell script in a temp folder that records its start and
// every stdin line, and answers or dies as the test says), a real `HelperEmbedder` over that client, and `embed` called the
// way the search pipeline calls it: blocking, on a background thread. The stub is never the real SesameHelper and loads no
// model; nothing is launched. Everything runs against a throwaway HOME.
//
// SUITE PLACEMENT. Nested in `ModelDownloadTests` (HOME is process-wide), like HelperClientTests.
//
// API SHAPES these tests pin (the design names `HelperEmbedder`; the entry fixes no signature; if a shape is wrong, ask
// for a test change rather than guessing):
//   1. `HelperEmbedder(client: HelperClient)` conforms to `Embedder` (`embed(_:role:) throws -> [Float]`, blocking). Making
//      it makes it the client's delegate, as the plan-1 t36 report says; the test does no other wiring.
//   2. `HelperEmbedder` learns by ITSELF that the encode helper exited without being asked to (`HelperExit.unplanned`, the
//      `"encode"` exit of `HelperClient.onExit`), or that it could not be started (the client reports that as an unplanned
//      exit with status -1): every `embed` still waiting on that helper throws at once, and so does the `embed` that
//      started a helper that cannot run. The test installs no `onExit` of its own. Which hook carries the exit from
//      `HelperClient` to the embedder is the implementer's choice, but `HelperClient.onExit` is one closure that
//      `HelperClientIndexHost` already takes over (and forwards only the "index" exits), so a second observer of
//      the encode exit is needed in `HelperClient.swift` (or the embedder must be told by the delegate).
//   3. An exit of the `index` helper is not the encode helper's: it fails no waiting embed.
//   4. After a failure the next `embed` is an ordinary one: the client starts the encode helper again (HelperClient
//      already does this on the next command) and the line reaches the new process.
//   5. Not pinned, on purpose: the error type thrown; what happens to an embed that was written after the exit but before
//      it was reported; the embedder's 20 s timeout (the pipeline test covers a timeout through its own stand-in).
//
// "AT ONCE" is read as: well inside the embedder's own 20 s wait. The bound below is 8 s after the helper died; the
// failure is expected in milliseconds, and an embed that sits out its 20 s timeout cannot pass.

private let hfSlack = 8.0

private let hfStubScript = #"""
#!/bin/sh
# Stub helper for HelperEmbedderFailureTests. First argument is the mode (encode or index).
# Records its pid and every stdin line. With <mode>.answer present it answers each embed line with a vector event from
# vector.json. With <mode>.exit-code present it exits with that status after the first line it reads.
dir=$(dirname "$0")
mode="$1"
printf '%s\n' "$$" >> "$dir/$mode.pids"
while IFS= read -r line; do
  printf '%s\t%s\n' "$$" "$line" >> "$dir/$mode.stdin"
  if [ -f "$dir/$mode.answer" ]; then
    case "$line" in
      *'"cmd":"embed"'*)
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
        printf '{"event":"vector","id":%s,"ms":1,"vec":%s}\n' "$id" "$(cat "$dir/vector.json")"
        ;;
    esac
  fi
  if [ -f "$dir/$mode.exit-code" ]; then exit $(( $(cat "$dir/$mode.exit-code") )); fi
done
"""#

// The outcome of one blocking `embed`, written by the background thread, read by the test.
private final class HFOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var vector: [Float]?
    private var failed = false
    private var finished: Date?
    func succeed(_ value: [Float]) { lock.lock(); vector = value; finished = Date(); lock.unlock() }
    func fail() { lock.lock(); failed = true; finished = Date(); lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished != nil }
    var threw: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    var value: [Float]? { lock.lock(); defer { lock.unlock() }; return vector }
    var finishedAt: Date? { lock.lock(); defer { lock.unlock() }; return finished }
}

private final class HFBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// `embed` as the pipeline calls it: blocking, off the main thread.
private func hfEmbed(_ embedder: HelperEmbedder, _ text: String) -> HFOutcome {
    let outcome = HFOutcome()
    let box = HFBox(embedder)
    DispatchQueue.global().async {
        do { outcome.succeed(try box.value.embed(text, role: .query)) } catch { outcome.fail() }
    }
    return outcome
}

@MainActor
private final class HFEnv {
    let dir: URL
    let helper: URL
    let textModel: URL
    let mmModel: URL

    init() throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent("sesame-embedderfail-stub-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        helper = dir.appendingPathComponent("stub-helper")
        try hfStubScript.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        textModel = dir.appendingPathComponent("text-model.gguf")
        mmModel = dir.appendingPathComponent("mm-model.gguf")
        fm.createFile(atPath: textModel.path, contents: Data("t".utf8))
        fm.createFile(atPath: mmModel.path, contents: Data("m".utf8))
        // a vector pointing along axis 0, as the PanelRig helper answers
        let vector = "[" + (0..<768).map { $0 == 0 ? "1" : "0" }.joined(separator: ",") + "]"
        try vector.write(to: dir.appendingPathComponent("vector.json"), atomically: true, encoding: .utf8)
    }

    func makeClient(helper file: URL? = nil) -> HelperClient {
        HelperClient(helper: file ?? helper, textModel: textModel, mmModel: mmModel)
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func pids(_ mode: String) -> [Int] {
        read(mode + ".pids").split(separator: "\n", omittingEmptySubsequences: true).compactMap { Int($0) }
    }

    // (pid of the stub process that read it, the line)
    func stdin(_ mode: String) -> [(pid: Int, line: String)] {
        read(mode + ".stdin").split(separator: "\n", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            return (pid, String(parts[1]))
        }
    }

    func setAnswering(_ mode: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(mode + ".answer").path, contents: Data())
    }

    func setExitCode(_ mode: String, _ code: Int) throws {
        try String(code).write(to: dir.appendingPathComponent(mode + ".exit-code"), atomically: true, encoding: .utf8)
    }

    func kill(_ pid: Int) { _ = Darwin.kill(pid_t(pid), SIGKILL) }

    func cleanup() {
        for mode in ["encode", "index"] { for pid in pids(mode) { kill(pid) } }
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
private func hfRun(_ body: @MainActor (HFEnv) async throws -> Void) async throws {
    try await spWithHome { _ in
        let env = try HFEnv()
        defer { env.cleanup() }
        try await body(env)
    }
}

@MainActor
private func hfEventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

extension ModelDownloadTests {
    @Suite("HelperEmbedderFailureTests", .serialized)
    struct HelperEmbedderFailureTests {

        // A control, green before the work as well: a helper that answers gives the vector, so the harness and the
        // embedder wiring below are the ones the failure tests use.
        @MainActor
        @Test func controlAnAnsweringHelperGivesTheVector() async throws {
            try await hfRun { env in
                env.setAnswering("encode")
                let embedder = HelperEmbedder(client: env.makeClient())
                let outcome = hfEmbed(embedder, "a dog on the beach")
                let answered = await hfEventually { outcome.done }
                #expect(answered, "the stub answered but embed never returned")
                #expect(!outcome.threw, "embed threw although the helper answered")
                #expect(outcome.value?.count == 768, "vector of \(String(describing: outcome.value?.count)) numbers")
                #expect(outcome.value?.first == 1)
            }
        }

        @MainActor
        @Test func aKilledEncodeHelperFailsEveryWaitingEmbedAtOnce() async throws {
            try await hfRun { env in
                let embedder = HelperEmbedder(client: env.makeClient())
                let waiting = (1...3).map { hfEmbed(embedder, "waiting \($0)") }
                let sent = await hfEventually { env.stdin("encode").count == 3 }
                #expect(sent, "the encode stub got \(env.stdin("encode").count) of 3 embed lines")
                #expect(waiting.allSatisfy { !$0.done }, "an embed returned although the helper never answered")
                guard let pid = env.pids("encode").first else {
                    Issue.record("no encode helper was started")
                    return
                }

                let killedAt = Date()
                env.kill(pid)
                let allFailed = await hfEventually(timeout: hfSlack) { waiting.allSatisfy { $0.done } }
                let took = Date().timeIntervalSince(killedAt)
                let stillWaiting = waiting.filter { !$0.done }.count
                #expect(allFailed, "\(stillWaiting) of 3 embeds were still waiting \(took) s after the encode helper died (the embedder's own wait is 20 s)")
                #expect(waiting.allSatisfy { $0.threw || !$0.done }, "an embed returned a vector from a dead helper")
                #expect(waiting.filter { $0.done }.allSatisfy { $0.threw })
            }
        }

        @MainActor
        @Test func anEncodeHelperThatExitsOnItsOwnWithStatusThreeFailsTheWaitingEmbedAtOnce() async throws {
            try await hfRun { env in
                try env.setExitCode("encode", 3)
                let embedder = HelperEmbedder(client: env.makeClient())
                let startedAt = Date()
                let outcome = hfEmbed(embedder, "a dog on the beach")
                let failed = await hfEventually(timeout: hfSlack) { outcome.done }
                let took = Date().timeIntervalSince(startedAt)
                #expect(failed, "the embed was still waiting \(took) s after the encode helper exited with status 3 (the embedder's own wait is 20 s)")
                #expect(outcome.threw, "embed did not throw")
            }
        }

        @MainActor
        @Test func aHelperThatCannotBeStartedFailsTheEmbedAtOnce() async throws {
            try await hfRun { env in
                let missing = env.dir.appendingPathComponent("no-such-helper")
                let embedder = HelperEmbedder(client: env.makeClient(helper: missing))
                let startedAt = Date()
                let outcome = hfEmbed(embedder, "a dog on the beach")
                let failed = await hfEventually(timeout: hfSlack) { outcome.done }
                let took = Date().timeIntervalSince(startedAt)
                #expect(failed, "the embed was still waiting \(took) s although no helper could start (the embedder's own wait is 20 s)")
                #expect(outcome.threw, "embed did not throw")
            }
        }

        @MainActor
        @Test func theNextEmbedAfterAFailureStartsEncodeAgainAndTheLineReachesTheNewProcess() async throws {
            try await hfRun { env in
                let embedder = HelperEmbedder(client: env.makeClient())
                let first = hfEmbed(embedder, "first")
                let firstSent = await hfEventually { env.stdin("encode").count == 1 }
                #expect(firstSent, "the first embed line never reached the stub")
                guard let firstPid = env.pids("encode").first else {
                    Issue.record("no encode helper was started")
                    return
                }
                env.kill(firstPid)
                let failed = await hfEventually(timeout: hfSlack) { first.done }
                #expect(failed, "the first embed was still waiting \(hfSlack) s after the helper died")
                #expect(first.threw)

                let second = hfEmbed(embedder, "second")
                let restarted = await hfEventually { env.pids("encode").count == 2 }
                #expect(restarted, "the next embed did not start the encode helper again: pids \(env.pids("encode"))")
                let delivered = await hfEventually {
                    env.stdin("encode").contains { $0.pid != firstPid && $0.line.contains("\"second\"") }
                }
                #expect(delivered, "the second embed line did not reach the new process: \(env.stdin("encode"))")
                #expect(!second.done, "the second embed returned although the new helper never answered")

                // let go of the second embed: the new helper dies too, and that embed fails at once as well
                if let secondPid = env.pids("encode").last, secondPid != firstPid { env.kill(secondPid) }
                let secondFailed = await hfEventually(timeout: hfSlack) { second.done }
                #expect(secondFailed, "the second embed was still waiting after its helper died")
                #expect(second.threw)
            }
        }

        @MainActor
        @Test func anIndexHelperThatDiesFailsNoWaitingEmbed() async throws {
            try await hfRun { env in
                let client = env.makeClient()
                let embedder = HelperEmbedder(client: client)
                client.reset()   // starts the index stub
                let indexSent = await hfEventually { env.stdin("index").count == 1 }
                #expect(indexSent, "the index stub never got its line")
                let outcome = hfEmbed(embedder, "a dog on the beach")
                let encodeSent = await hfEventually { env.stdin("encode").count == 1 }
                #expect(encodeSent, "the embed line never reached the encode stub")

                if let indexPid = env.pids("index").first { env.kill(indexPid) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                #expect(!outcome.done, "the embed failed because the index helper died; threw: \(outcome.threw)")

                // the encode helper's own death still fails it
                if let encodePid = env.pids("encode").first { env.kill(encodePid) }
                let failedAfterEncodeDied = await hfEventually(timeout: hfSlack) { outcome.done }
                #expect(failedAfterEncodeDied, "the embed was still waiting after the encode helper died")
                #expect(outcome.threw)
            }
        }
    }
}

// MARK: plan-3-t20, tester step: an idle exit of the encode helper fails every waiting embed at once
//
// Everything above this line is sealed and unchanged. Written from the t20 entry of plan-3-tasks.md (its Tests paragraph, last
// sentence: "an `idle` exit of the `encode` helper fails every waiting embed at once, as an unplanned exit does today (a stub,
// 10 s of slack, never the 20 s timeout)") and the sealed tests above; no product source was read.
//
// An exit 0 nobody asked for is `HelperExit.idle` (see HelperClientTests), no longer `.unplanned(status: 0)`. The embedder
// must treat it like the unplanned exit: the embeds that wait on that process throw at once. Two stubs are used, both
// shell scripts, none loads a model:
//   - a premise check on its own client with its own `onExit` (the embedder's client is left to the embedder, as above):
//     the stub that exits 0 after its first line really is reported as `.idle`, so this test is about the idle path and not
//     about a status-0 `.unplanned` exit;
//   - the embedder's client over a stub that reads three embed lines and then exits 0 by itself, so three embeds are waiting
//     when the idle exit comes.

private let hfSlackIdle = 10.0

// Like `hfStubScript`, but with the exit switch `<mode>.exit-code` it exits only after it has read 3 lines.
private let hfThreeLinesStubScript = #"""
#!/bin/sh
dir=$(dirname "$0")
mode="$1"
printf '%s\n' "$$" >> "$dir/$mode.pids"
while IFS= read -r line; do
  printf '%s\t%s\n' "$$" "$line" >> "$dir/$mode.stdin"
  if [ -f "$dir/$mode.exit-code" ] && [ "$(wc -l < "$dir/$mode.stdin")" -ge 3 ]; then exit $(( $(cat "$dir/$mode.exit-code") )); fi
done
"""#

private final class HFExits: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(helper: String, exit: HelperExit)] = []
    func record(_ helper: String, _ exit: HelperExit) { lock.lock(); items.append((helper, exit)); lock.unlock() }
    func of(_ helper: String) -> [HelperExit] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.helper == helper }.map(\.exit)
    }
}

extension ModelDownloadTests.HelperEmbedderFailureTests {

    @MainActor
    @Test func premiseTheStubThatExitsZeroAfterItsFirstLineIsAnIdleExitOfTheEncodeHelper() async throws {
        try await hfRun { env in
            try env.setExitCode("encode", 0)
            let client = env.makeClient()
            let exits = HFExits()
            client.onExit = { helper, exit in exits.record(helper, exit) }
            client.embed(id: 1, text: "probe", role: .query)
            let reported = await hfEventually { !exits.of("encode").isEmpty }
            #expect(reported, "onExit was not called for the encode stub that exited 0")
            #expect(exits.of("encode") == [.idle], "got \(exits.of("encode"))")
        }
    }

    @MainActor
    @Test func anIdleExitOfTheEncodeHelperFailsEveryWaitingEmbedAtOnce() async throws {
        try await hfRun { env in
            try hfThreeLinesStubScript.write(to: env.helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.helper.path)
            try env.setExitCode("encode", 0)
            let embedder = HelperEmbedder(client: env.makeClient())
            let startedAt = Date()
            let waiting = (1...3).map { hfEmbed(embedder, "waiting \($0)") }
            let allFailed = await hfEventually(timeout: hfSlackIdle) { waiting.allSatisfy { $0.done } }
            let took = Date().timeIntervalSince(startedAt)
            let stillWaiting = waiting.filter { !$0.done }.count
            #expect(allFailed, "\(stillWaiting) of 3 embeds were still waiting \(took) s after the encode helper exited 0 (the embedder's own wait is 20 s)")
            #expect(waiting.filter { $0.done }.allSatisfy { $0.threw }, "an embed returned a vector from an exited helper")
            #expect(env.stdin("encode").count == 3, "the stub got \(env.stdin("encode").count) of 3 embed lines")
        }
    }

    @MainActor
    @Test func theNextEmbedAfterAnIdleExitStartsEncodeAgainAndTheLineReachesTheNewProcess() async throws {
        try await hfRun { env in
            try env.setExitCode("encode", 0)
            let embedder = HelperEmbedder(client: env.makeClient())
            let first = hfEmbed(embedder, "first")
            let firstFailed = await hfEventually(timeout: hfSlackIdle) { first.done }
            #expect(firstFailed, "the first embed was still waiting \(hfSlackIdle) s after the encode helper exited 0")
            #expect(first.threw)
            let firstPid = env.pids("encode").first ?? 0
            #expect(firstPid > 0)

            let second = hfEmbed(embedder, "second")
            let restarted = await hfEventually { env.pids("encode").count == 2 }
            #expect(restarted, "the next embed did not start the encode helper again: pids \(env.pids("encode"))")
            let delivered = await hfEventually {
                env.stdin("encode").contains { $0.pid != firstPid && $0.line.contains("\"second\"") }
            }
            #expect(delivered, "the second embed line did not reach the new process: \(env.stdin("encode"))")
            let secondFailed = await hfEventually(timeout: hfSlackIdle) { second.done }
            #expect(secondFailed, "the second embed was still waiting after its helper exited 0")
            #expect(second.threw)
        }
    }

    @MainActor
    @Test func anIdleExitOfTheIndexHelperFailsNoWaitingEmbed() async throws {
        try await hfRun { env in
            try env.setExitCode("index", 0)
            let client = env.makeClient()
            let embedder = HelperEmbedder(client: client)
            client.reset()   // starts the index stub, which exits 0 after this line
            let indexSent = await hfEventually { env.stdin("index").count == 1 }
            #expect(indexSent, "the index stub never got its line")
            let outcome = hfEmbed(embedder, "a dog on the beach")
            let encodeSent = await hfEventually { env.stdin("encode").count == 1 }
            #expect(encodeSent, "the embed line never reached the encode stub")
            if let indexPid = env.pids("index").first {
                _ = await hfEventually { Darwin.kill(pid_t(indexPid), 0) != 0 }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(!outcome.done, "the embed failed because the index helper exited idle; threw: \(outcome.threw)")

            // the encode helper's own death still fails it
            if let encodePid = env.pids("encode").first { env.kill(encodePid) }
            let failedAfterEncodeDied = await hfEventually(timeout: hfSlackIdle) { outcome.done }
            #expect(failedAfterEncodeDied, "the embed was still waiting after the encode helper died")
            #expect(outcome.threw)
        }
    }
}

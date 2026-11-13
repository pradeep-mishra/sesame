import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1 review round B (app), tester step: finding F10. `ModelWatcher.retry()` has no caller; the watcher's failure is
// never given to `SetupModel.downloadFailed`, so no Retry button appears; the screen says "Downloading it again" with
// nothing happening; and the setup Retry runs a separate `ModelDownload` that can overlap a watcher fetch on one `.partial`.
// Written from the review report (F10), the brief's acceptance line, spec S6 and design sections 2, 7 and 9 only, and
// from the sealed ModelWatcherTests and SetupModelTests (the stub-server pattern, the pinned shapes). Product source read
// for names and where the logic lives: Sources/Sesame/AppDelegate.swift (the wiring: `modelWatcher`, `setupModel` and its
// `onRetry`), ModelWatcher.swift (`needsRetry`, `retry()`, `waitingForRetry`), Setup/SetupModel.swift (`downloadFailed`,
// `retry`, `showsRetry`, `errorText`). No expected value comes from them.
//
// SUITE PLACEMENT. HOME and SESAME_MODEL_HOST are process-wide: nested inside `ModelDownloadTests`.
//
// API SHAPES these tests pin (new; if a shape is wrong, ask for a test change rather than guessing). All in `Sesame`.
//   1. `ModelWatcher.init(files: [ModelFile] = ModelFiles.all, onMessage: @escaping @Sendable (String) -> Void = { _ in },
//                         onFailure: @escaping @Sendable (String) -> Void = { _ in })`.
//      `onFailure` is called, on any thread, with a text that is not blank, exactly once each time the watcher gives up
//      on a fetch (its refetch failed, `ModelDownload`'s own second try included), that is each time `needsRetry`
//      becomes true. `needsRetry` is already true when `onFailure` is called. It is not called for a refetch that
//      works, and not again by later polls while the watcher waits for Retry. A `retry()` whose fetch fails again
//      calls it again.
//   2. `protocol ModelWatching: AnyObject { var needsRetry: Bool { get }; func retry() }`, and `ModelWatcher` conforms.
//   3. `@MainActor final class ModelRecovery`, the coordinator the app uses:
//        `init(setup: SetupModel, watcher: any ModelWatching, startLaunchDownload: @escaping @MainActor () -> Void)`
//        `func watcherFailed(_ text: String)`   the app calls it from the watcher's `onFailure`; it calls
//                                               `setup.downloadFailed(text)`, so `setup.errorText == text` and
//                                               `setup.showsRetry` is true.
//        `func retry()`                          what the setup window's Retry reaches (the app gives `SetupModel` an
//                                               `onRetry` that calls it). If `watcher.needsRetry` is true it calls
//                                               `watcher.retry()` once and does NOT call `startLaunchDownload`;
//                                               otherwise it calls `startLaunchDownload` once and does NOT call
//                                               `watcher.retry()`. Never both.
//      The `SetupModel` is the real one, and its own `retry()` still clears the error text and calls its `onRetry`.
//   4. Not pinned, on purpose: the text of the watcher's failure; how the app makes the coordinator and the watcher
//      reach each other (a box, a lazy var); what the coordinator does when the launch download failed AND the watcher
//      is waiting at the same time (one press must not start both; which one goes first is not pinned); whether the
//      damaged-model message path (`onMessage`) goes through the coordinator.
//
// NOT REACHED here (the real app only): that `AppDelegate` builds `ModelRecovery`, gives the watcher the `onFailure`
// and `SetupModel` the `onRetry`, that the Retry button really appears in the setup window and a click on it brings the
// model back, and the real model server. The stub server below is a copy of the one in ModelWatcherTests (file-private
// there), BSD sockets on 127.0.0.1, named by SESAME_MODEL_HOST.

// MARK: bytes, hashes

private func mrHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mrPattern(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(out)
}

private struct MRSynthetic: Sendable {
    let data: Data
    let file: ModelFile
    init(name: String, size: Int, seed: UInt64) {
        let data = mrPattern(size, seed: seed)
        self.data = data
        self.file = ModelFile(name: name, size: size, sha256: mrHex(data))
    }
}

private func mrBytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

private func mrBlank(_ text: String?) -> Bool {
    (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: recorders

private final class MRRecord<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    func add(_ item: Item) { lock.lock(); items.append(item); lock.unlock() }
    var all: [Item] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class MRFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }
}

private final class MRCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: the test server (a copy of ModelWatcherTests', trimmed)

private struct MRRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    var lastComponent: String {
        let noQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(noQuery.split(separator: "/").last ?? "")
    }
}

private enum MRTestError: Error { case socket, bind }

private func mrSend(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let total = data.count
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        while offset < total {
            let written = write(fd, base + offset, total - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

private func mrHead(_ fd: Int32, _ status: Int, _ headers: [(String, String)]) -> Bool {
    let reasons = [200: "OK", 206: "Partial Content", 404: "Not Found", 416: "Range Not Satisfiable"]
    var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
    for (name, value) in headers { text += "\(name): \(value)\r\n" }
    text += "Connection: close\r\n\r\n"
    return mrSend(fd, Data(text.utf8))
}

/// 200 for a plain GET, 206 for `Range: bytes=N-`, 416 past the end.
private func mrServeFile(_ data: Data, _ request: MRRequest, _ fd: Int32) {
    var start = 0
    let ranged = request.headers["range"] != nil
    if let value = request.headers["range"], value.hasPrefix("bytes="),
       let from = Int(value.dropFirst(6).prefix { $0.isNumber }) { start = from }
    var headers: [(String, String)] = [("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes")]
    if start >= data.count && ranged {
        _ = mrHead(fd, 416, headers + [("Content-Range", "bytes */\(data.count)"), ("Content-Length", "0")])
        return
    }
    let length = data.count - start
    if ranged { headers.append(("Content-Range", "bytes \(start)-\(data.count - 1)/\(data.count)")) }
    headers.append(("Content-Length", String(length)))
    guard mrHead(fd, ranged ? 206 : 200, headers) else { return }
    if request.method == "HEAD" { return }
    var sent = 0
    while sent < length {
        let take = min(32_768, length - sent)
        guard mrSend(fd, data.subdata(in: (start + sent)..<(start + sent + take))) else { return }
        sent += take
    }
}

private final class MRServer: @unchecked Sendable {
    typealias Handler = @Sendable (MRRequest, Int32) -> Void

    let port: UInt16
    private let listenFD: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var seen: [MRRequest] = []
    private var stopping = false

    init(handler: @escaping Handler) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MRTestError.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw MRTestError.bind
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = UInt16(bigEndian: assigned.sin_port)
        self.listenFD = fd
        self.handler = handler
        Thread.detachNewThread { [self] in self.acceptLoop() }
    }

    func requests(_ method: String) -> [MRRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen.filter { $0.method == method }
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop() {
        while !isStopping {
            var poller = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            if poll(&poller, 1, 100) <= 0 { continue }
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in self.serve(client) }
        }
        Darwin.close(listenFD)
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 65_536 { return }
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = MRRequest(method: String(first[0]), path: String(first[1]), headers: headers)
        lock.lock()
        seen.append(request)
        lock.unlock()
        handler(request, fd)
    }
}

// MARK: throwaway home, environment

private struct MREnv: Sendable {
    let home: URL
    var models: URL { home.appendingPathComponent("Library/Application Support/Sesame/models", isDirectory: true) }
    func whole(_ name: String) -> URL { models.appendingPathComponent(name) }
}

/// Sets HOME to a fresh folder and SESAME_MODEL_HOST to the server, makes the Sesame folder and `models/`, runs the
/// body on the main actor, puts both settings back.
@MainActor
private func mrRun(handler: @escaping MRServer.Handler, body: @MainActor (MREnv, MRServer) async throws -> Void) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("sesame-recovery-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let env = MREnv(home: home)
    let server = try MRServer(handler: handler)
    let previousHome = getenv("HOME").map { String(cString: $0) }
    let previousHost = getenv("SESAME_MODEL_HOST").map { String(cString: $0) }
    setenv("HOME", home.path, 1)
    setenv("SESAME_MODEL_HOST", "http://127.0.0.1:\(server.port)", 1)
    defer {
        if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
        if let previousHost { setenv("SESAME_MODEL_HOST", previousHost, 1) } else { unsetenv("SESAME_MODEL_HOST") }
        server.stop()
        try? fm.removeItem(at: home)
    }
    _ = try SesameFolder.create()
    guard fm.fileExists(atPath: env.models.deletingLastPathComponent().path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before watching anything")
        return
    }
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)
    try await body(env, server)
}

@MainActor
private func mrWaitUntil(_ timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func mrSleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// A stand-in for the watcher, for the coordinator's own rules. `retry()` clears `needsRetry`, as the real one does.
private final class MRFakeWatcher: ModelWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Bool
    private var calls = 0
    init(needsRetry: Bool) { waiting = needsRetry }
    var needsRetry: Bool {
        get { lock.lock(); defer { lock.unlock() }; return waiting }
        set { lock.lock(); waiting = newValue; lock.unlock() }
    }
    var retryCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func retry() { lock.lock(); calls += 1; waiting = false; lock.unlock() }
}

/// Lets the `SetupModel`'s `onRetry` reach the coordinator that is made after it.
@MainActor
private final class MRBox {
    var recovery: ModelRecovery?
}

extension ModelDownloadTests {
    @Suite("ModelRecoveryTests", .serialized)
    struct ModelRecoveryTests {

        // MARK: the watcher tells its owner when it gives up

        @MainActor
        @Test func theWatcherCallsOnFailureOnceWhenItsRefetchFailsAndAgainWhenARetryFailsToo() async throws {
            let synthetic = MRSynthetic(name: "fail-a.gguf", size: 300_000, seed: 201)
            var wrong = synthetic.data
            wrong[150_000] ^= 0xFF
            let wrongBytes = wrong
            let serveWrong = MRFlag(true)
            let failures = MRRecord<String>()
            let needsRetryAtCall = MRRecord<Bool>()
            try await mrRun(handler: { request, fd in
                guard request.lastComponent == synthetic.file.name else {
                    _ = mrHead(fd, 404, [("Content-Length", "0")])
                    return
                }
                mrServeFile(serveWrong.value ? wrongBytes : synthetic.data, request, fd)
            }, body: { env, server in
                try synthetic.data.prefix(synthetic.data.count - 1_000).write(to: env.whole(synthetic.file.name))
                let holder = MRWatcherHolder()
                let watcher = ModelWatcher(files: [synthetic.file], onMessage: { _ in }, onFailure: { text in
                    failures.add(text)
                    needsRetryAtCall.add(holder.watcher?.needsRetry ?? false)
                })
                holder.watcher = watcher
                defer { watcher.stop() }
                watcher.start()

                let first = await mrWaitUntil(30) { !failures.all.isEmpty }
                #expect(first, "the watcher gave up (needsRetry \(watcher.needsRetry)) but onFailure was never called")
                #expect(failures.all.count == 1, "onFailure calls: \(failures.all)")
                #expect(!mrBlank(failures.all.first), "the failure text is blank")
                #expect(watcher.needsRetry, "needsRetry is false after the watcher gave up")
                #expect(needsRetryAtCall.all.first == true, "needsRetry was not yet true when onFailure was called")

                // Polls pass while it waits for Retry: no second call.
                await mrSleep(ModelWatcher.pollInterval + 1)
                #expect(failures.all.count == 1, "a poll while waiting for Retry called onFailure again: \(failures.all)")

                // Retry with a server that is still wrong: a second failure is reported again.
                watcher.retry()
                let second = await mrWaitUntil(30) { failures.all.count >= 2 }
                #expect(second, "a Retry that failed again was not reported; calls: \(failures.all.count)")
                #expect(watcher.needsRetry, "needsRetry is false after the second failure")
                #expect(server.requests("GET").count == 4, "GETs: \(server.requests("GET").count), wanted 2 + 2")

                // Retry with a good server: no further call.
                serveWrong.value = false
                watcher.retry()
                let healed = await mrWaitUntil(20) { mrBytes(env.whole(synthetic.file.name)) == synthetic.data }
                #expect(healed, "the file is not whole after a good Retry")
                let settled = await mrWaitUntil(5) { !watcher.needsRetry }
                #expect(settled, "needsRetry stayed true after a good fetch")
                #expect(failures.all.count == 2, "onFailure was called for a fetch that worked: \(failures.all)")
            })
        }

        @MainActor
        @Test func aRefetchThatWorksNeverCallsOnFailure() async throws {
            let synthetic = MRSynthetic(name: "fail-b.gguf", size: 250_000, seed: 211)
            let failures = MRRecord<String>()
            try await mrRun(handler: { request, fd in
                guard request.lastComponent == synthetic.file.name else {
                    _ = mrHead(fd, 404, [("Content-Length", "0")])
                    return
                }
                mrServeFile(synthetic.data, request, fd)
            }, body: { env, _ in
                try synthetic.data.prefix(synthetic.data.count - 500).write(to: env.whole(synthetic.file.name))
                let watcher = ModelWatcher(files: [synthetic.file], onMessage: { _ in }, onFailure: { failures.add($0) })
                defer { watcher.stop() }
                watcher.start()
                let healed = await mrWaitUntil(20) { mrBytes(env.whole(synthetic.file.name)) == synthetic.data }
                #expect(healed, "the damaged file was not fetched again")
                await mrSleep(1)
                #expect(failures.all.isEmpty, "onFailure for a refetch that worked: \(failures.all)")
                #expect(!watcher.needsRetry)
            })
        }

        // MARK: the coordinator's rules, with a stand-in watcher

        @MainActor
        @Test func aWatcherFailureShowsTheTextAndTheRetryButtonOnTheSetupModel() async throws {
            try await spWithHome { _ in
                let setup = SetupModel()
                let recovery = ModelRecovery(setup: setup, watcher: MRFakeWatcher(needsRetry: true), startLaunchDownload: {})
                #expect(!setup.showsRetry && setup.errorText == nil)

                recovery.watcherFailed("Could not fetch the model again")

                #expect(setup.errorText == "Could not fetch the model again", "errorText: \(String(describing: setup.errorText))")
                #expect(setup.showsRetry, "no Retry button after the watcher failed")
            }
        }

        @MainActor
        @Test func theSetupRetryGoesToTheWatcherWhenItIsTheOneWaitingAndStartsNoLaunchDownload() async throws {
            try await spWithHome { _ in
                let box = MRBox()
                let setup = SetupModel(onRetry: { box.recovery?.retry() })
                let watcher = MRFakeWatcher(needsRetry: true)
                let launches = MRCounter()
                box.recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                box.recovery?.watcherFailed("failed")
                #expect(setup.showsRetry)

                setup.retry()

                #expect(watcher.retryCalls == 1, "watcher.retry() calls: \(watcher.retryCalls)")
                #expect(launches.value == 0, "a launch download started beside the watcher's retry: \(launches.value)")
                #expect(!setup.showsRetry, "the Retry button stayed after Retry")
            }
        }

        @MainActor
        @Test func theSetupRetryStartsALaunchDownloadWhenTheWatcherIsNotWaitingAndLeavesTheWatcherAlone() async throws {
            try await spWithHome { _ in
                let box = MRBox()
                let setup = SetupModel(onRetry: { box.recovery?.retry() })
                let watcher = MRFakeWatcher(needsRetry: false)
                let launches = MRCounter()
                box.recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                setup.downloadFailed(SetupModel.downloadFailedMessage)   // the launch download failed, as the app reports it
                #expect(setup.showsRetry)

                setup.retry()

                #expect(launches.value == 1, "launch downloads started: \(launches.value)")
                #expect(watcher.retryCalls == 0, "watcher.retry() was called though the watcher was not waiting: \(watcher.retryCalls)")
                #expect(!setup.showsRetry)
            }
        }

        @MainActor
        @Test func twoFailuresInARowEachReachTheWindowAndEachRetryReachesTheWatcher() async throws {
            try await spWithHome { _ in
                let box = MRBox()
                let setup = SetupModel(onRetry: { box.recovery?.retry() })
                let watcher = MRFakeWatcher(needsRetry: true)
                let launches = MRCounter()
                box.recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                for round in 1...2 {
                    box.recovery?.watcherFailed("failed \(round)")
                    #expect(setup.errorText == "failed \(round)", "round \(round): \(String(describing: setup.errorText))")
                    #expect(setup.showsRetry, "round \(round): no Retry button")
                    watcher.needsRetry = true   // the watcher is waiting again, as after a real second failure
                    setup.retry()
                    #expect(watcher.retryCalls == round, "round \(round): watcher.retry() calls \(watcher.retryCalls)")
                }
                #expect(launches.value == 0, "launch downloads: \(launches.value)")
            }
        }

        // MARK: plan-2 fix round F (R5-01): a second Retry must not start a second fetch beside the first
        // Pinned: while a Retry that went to the watcher is still running (the watcher has not failed again),
        // `ModelRecovery.retry()` does nothing. The real watcher's `retry()` clears `needsRetry` at once, which `MRFakeWatcher`
        // copies; so a second call used to see `needsRetry == false` and start a launch download beside the watcher's fetch.
        // A new `watcherFailed` ends the wait: the next `retry()` goes to the watcher again.

        @MainActor
        @Test func twoRetriesInARowAfterOneWatcherFailureStartExactlyOneFetchInTotal() async throws {
            try await spWithHome { _ in
                let box = MRBox()
                let setup = SetupModel(onRetry: { box.recovery?.retry() })
                let watcher = MRFakeWatcher(needsRetry: true)
                let launches = MRCounter()
                let recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                box.recovery = recovery
                recovery.watcherFailed("failed")

                recovery.retry()
                recovery.retry()

                #expect(watcher.retryCalls + launches.value == 1,
                        "fetches started by two Retry presses: watcher.retry() \(watcher.retryCalls) + launch downloads \(launches.value), want 1 in total")
                #expect(watcher.retryCalls == 1, "watcher.retry() calls: \(watcher.retryCalls)")
                #expect(launches.value == 0, "a launch download started beside the watcher's fetch: \(launches.value)")
            }
        }

        @MainActor
        @Test func twoPressesOnTheSetupModelsRetryAfterOneWatcherFailureStartExactlyOneFetchInTotal() async throws {
            try await spWithHome { _ in
                let box = MRBox()
                let setup = SetupModel(onRetry: { box.recovery?.retry() })
                let watcher = MRFakeWatcher(needsRetry: true)
                let launches = MRCounter()
                box.recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                box.recovery?.watcherFailed("failed")

                setup.retry()
                setup.retry()

                #expect(watcher.retryCalls + launches.value == 1,
                        "fetches started by two presses: watcher.retry() \(watcher.retryCalls) + launch downloads \(launches.value), want 1 in total")
                #expect(launches.value == 0, "a launch download started beside the watcher's fetch: \(launches.value)")
            }
        }

        @MainActor
        @Test func aNewWatcherFailureEndsTheWaitSoTheNextRetryReachesTheWatcherAgainAndOnlyOnce() async throws {
            try await spWithHome { _ in
                let box = MRBox()
                let setup = SetupModel(onRetry: { box.recovery?.retry() })
                let watcher = MRFakeWatcher(needsRetry: true)
                let launches = MRCounter()
                let recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                box.recovery = recovery
                recovery.watcherFailed("failed 1")
                recovery.retry()
                recovery.retry()   // the second press of the same failure: nothing
                #expect(watcher.retryCalls == 1 && launches.value == 0, "after the first failure: watcher \(watcher.retryCalls), launches \(launches.value)")

                watcher.needsRetry = true   // the Retry's fetch failed too: the watcher waits again
                recovery.watcherFailed("failed 2")
                recovery.retry()
                recovery.retry()

                #expect(watcher.retryCalls == 2, "the second failure's Retry did not reach the watcher: watcher.retry() calls \(watcher.retryCalls)")
                #expect(launches.value == 0, "launch downloads: \(launches.value)")
            }
        }

        // MARK: the whole chain, with the real watcher and a stub server

        @MainActor
        @Test func aWatcherThatGaveUpShowsRetryAndTheButtonBringsTheModelBackThroughTheWatcherAlone() async throws {
            let synthetic = MRSynthetic(name: "chain-a.gguf", size: 300_000, seed: 221)
            var wrong = synthetic.data
            wrong[150_000] ^= 0xFF
            let wrongBytes = wrong
            let serveWrong = MRFlag(true)
            let failures = MRRecord<String>()
            let launches = MRCounter()
            try await mrRun(handler: { request, fd in
                guard request.lastComponent == synthetic.file.name else {
                    _ = mrHead(fd, 404, [("Content-Length", "0")])
                    return
                }
                mrServeFile(serveWrong.value ? wrongBytes : synthetic.data, request, fd)
            }, body: { env, server in
                let whole = env.whole(synthetic.file.name)
                try synthetic.data.prefix(synthetic.data.count - 1_000).write(to: whole)   // damaged at launch
                let box = MRBox()
                let setup = SetupModel(files: [synthetic.file], onRetry: { box.recovery?.retry() })
                let watcher = ModelWatcher(files: [synthetic.file], onMessage: { _ in }, onFailure: { text in
                    failures.add(text)
                    Task { @MainActor in box.recovery?.watcherFailed(text) }
                })
                box.recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: { launches.bump() })
                defer { watcher.stop() }
                watcher.start()

                let shown = await mrWaitUntil(30) { setup.showsRetry }
                #expect(shown, "the watcher gave up (needsRetry \(watcher.needsRetry)) but the setup window shows no Retry")
                #expect(!mrBlank(setup.errorText), "errorText: \(String(describing: setup.errorText))")
                #expect(setup.errorText == failures.all.first, "the window shows \(String(describing: setup.errorText)), the watcher said \(String(describing: failures.all.first))")
                #expect(watcher.needsRetry)

                serveWrong.value = false
                setup.retry()
                #expect(!setup.showsRetry, "the Retry button stayed after it was pressed")
                let healed = await mrWaitUntil(20) { mrBytes(whole) == synthetic.data }
                #expect(healed, "Retry did not bring the whole file back through the watcher")
                let settled = await mrWaitUntil(5) { !watcher.needsRetry }
                #expect(settled, "needsRetry stayed true after a good fetch")
                #expect(launches.value == 0, "Retry also started a launch download: \(launches.value)")
                #expect(server.requests("GET").count == 3, "GETs: \(server.requests("GET").count): 2 failed, then one for Retry, no second downloader")
                setup.refresh()
                #expect(setup.modelIsWhole, "the setup model does not see the whole file")
                #expect(!setup.showsRetry)
            })
        }

        @MainActor
        @Test func aRetryThatFailsAgainBringsTheRetryButtonBack() async throws {
            let synthetic = MRSynthetic(name: "chain-b.gguf", size: 300_000, seed: 231)
            var wrong = synthetic.data
            wrong[100_000] ^= 0xFF
            let wrongBytes = wrong
            let failures = MRRecord<String>()
            try await mrRun(handler: { request, fd in
                guard request.lastComponent == synthetic.file.name else {
                    _ = mrHead(fd, 404, [("Content-Length", "0")])
                    return
                }
                mrServeFile(wrongBytes, request, fd)
            }, body: { env, _ in
                try synthetic.data.prefix(synthetic.data.count - 1_000).write(to: env.whole(synthetic.file.name))
                let box = MRBox()
                let setup = SetupModel(files: [synthetic.file], onRetry: { box.recovery?.retry() })
                let watcher = ModelWatcher(files: [synthetic.file], onMessage: { _ in }, onFailure: { text in
                    failures.add(text)
                    Task { @MainActor in box.recovery?.watcherFailed(text) }
                })
                box.recovery = ModelRecovery(setup: setup, watcher: watcher, startLaunchDownload: {})
                defer { watcher.stop() }
                watcher.start()

                let shown = await mrWaitUntil(30) { setup.showsRetry }
                #expect(shown, "no Retry button after the first failure")
                setup.retry()
                #expect(!setup.showsRetry)
                let again = await mrWaitUntil(30) { failures.all.count >= 2 && setup.showsRetry }
                #expect(again, "the second failure did not bring the Retry button back; failures \(failures.all.count), showsRetry \(setup.showsRetry)")
            })
        }
    }
}

/// Lets the `onFailure` closure of a watcher look at that watcher.
private final class MRWatcherHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ModelWatcher?
    var watcher: ModelWatcher? {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); held = newValue; lock.unlock() }
    }
}

import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t27, tester step. Written from design sections 2 and 7, spec S6 and S1.18 and the t27 entry only;
// no product source read. Every test runs against a throwaway HOME and a local test server (BSD sockets,
// 127.0.0.1, port chosen by the system) named by SESAME_MODEL_HOST, so nothing real is touched and nothing
// leaves this machine. A synthetic file has a small expected size and hash built here with CryptoKit, so the
// watcher, then the refetch, finish in a moment. One test uses the real cached model files (a copy in the
// throwaway `models/`); it is skipped, and reported as skipped, when the kit cache is empty.
//
// SUITE PLACEMENT. HOME and SESAME_MODEL_HOST are process-wide and ModelDownloadTests sets both, so the two
// suites must never run at the same time. Swift Testing runs suites in parallel unless a parent suite is
// `.serialized`, so this suite is nested inside `ModelDownloadTests` (an extension in this file) and runs one
// at a time with it. Side effect: `swift test --filter ModelDownloadTests` also runs these tests.
//
// API SHAPES these tests pin (the design names "the model watcher" and fixes no signatures; if a shape is
// wrong, ask for a test change rather than guessing).
//   1. `ModelWatcher` is in the `Sesame` target (`@testable import Sesame`). It is a final class marked
//      `@unchecked Sendable`, or an actor, and not main-actor-isolated, so every member below compiles from a
//      nonisolated async context under Swift 6. (Members are written as for a class; an actor would need
//      `await`, so a class is the pinned shape.)
//   2. `init(files: [ModelFile] = ModelFiles.all, onMessage: @escaping @Sendable (String) -> Void = { _ in })`.
//      `files` is the injection point for a small synthetic expected size and hash. The watcher reads and
//      deletes under `<Sesame folder>/models/` (the layout of ModelDownload) and fetches again with a
//      `ModelDownload(files: files)` it makes itself, so a refetch reaches the server named by
//      SESAME_MODEL_HOST. No second launch setting is needed.
//   3. `func start()` returns at once (it does not wait for the re-hash or the refetch). It starts the watch
//      and, in the background, hashes every file in `files` that exists under `models/` (the re-hash at
//      launch of design section 7). It also arms the design's watch of section 2: a vnode watch on
//      `models/` and a poll every 5 s of each file's size, modified time and inode; any change of the
//      three triggers the same re-hash of every file. `static let pollInterval: TimeInterval` is `5`.
//   4. The re-hash, per file: a file under its real name whose size and SHA-256 do not match is deleted
//      (the delete itself is `SesameFolder.delete`, proved by Run line 2's write-and-delete rule, not here),
//      `onMessage` gets exactly "The model file was damaged, so it was deleted. Downloading it again.", and a
//      fetch of that file starts. A file whose size and SHA-256 match is left alone: no message and no
//      request, even when its modified time or inode changed. A file that is absent is not "damaged" and
//      nothing here pins what the watcher does about it first time round (the app starts the first download
//      elsewhere), but it must not fetch while the watcher waits for Retry (point 6).
//   5. `onMessage` is called on any thread, once per damaged file found, with that text and no other text.
//   6. A second failure waits for Retry. The refetch of point 4 is a `ModelDownload.start()`; when it
//      returns false (here: the server keeps sending a file with one wrong byte, so ModelDownload's own
//      delete-and-fetch-once-more has also failed) the watcher stops fetching: no further request reaches
//      the server, however many polls pass and although the file is absent, until `func retry()` is called.
//      `var needsRetry: Bool { get }` is true from the moment the watcher gave up until `retry()` is called
//      and false at every other time (including at rest after a successful refetch). `retry()` returns at
//      once and starts a new fetch.
//   7. `func stop()` ends the watch and cancels a fetch it started; after it returns no more files are
//      written or deleted. The tests call it at the end of each test.
//   8. Not pinned, on purpose: whether `start()` makes `models/` when it is missing (the tests make it);
//      the second message of a second failure; what the vnode watch adds over the poll (the poll alone meets
//      the 15 s bound); how the app wires the watcher into AppDelegate (no test sees it); a `start()` called
//      twice.

private let mwMessage = "The model file was damaged, so it was deleted. Downloading it again."

// MARK: bytes, hashes, files

private func mwHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Deterministic, non-repeating bytes, so a flipped byte or a cut changes the hash for certain.
private func mwPattern(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(out)
}

private struct MWSynthetic: Sendable {
    let data: Data
    let file: ModelFile
    init(name: String, size: Int, seed: UInt64) {
        let data = mwPattern(size, seed: seed)
        self.data = data
        self.file = ModelFile(name: name, size: size, sha256: mwHex(data))
    }
}

private func mwBytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

private func mwExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func mwNames(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private enum MWTestError: Error { case socket, bind, read }

// One byte of the file turned upside down in place: same size, new modified time.
private func mwFlipByte(_ url: URL, at offset: Int) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    guard let old = try handle.read(upToCount: 1), let byte = old.first else { throw MWTestError.read }
    try handle.seek(toOffset: UInt64(offset))
    try handle.write(contentsOf: Data([byte ^ 0xFF]))
}

private func mwTruncate(_ url: URL, cutting count: Int) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    try handle.truncate(atOffset: size - UInt64(count))
}

// Same bytes, new inode: written beside the file, then renamed over it.
private func mwReplaceWithIdenticalCopy(_ url: URL, data: Data) throws {
    let beside = url.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID().uuidString).tmp")
    try data.write(to: beside)
    guard Darwin.rename(beside.path, url.path) == 0 else { throw MWTestError.read }
}

// MARK: the test server

private struct MWRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let at: Date
    var lastComponent: String {
        let noQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(noQuery.split(separator: "/").last ?? "")
    }
}

private final class MWConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func send(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
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

    @discardableResult
    func sendHead(_ status: Int, _ headers: [(String, String)]) -> Bool {
        let reasons = [200: "OK", 206: "Partial Content", 404: "Not Found", 416: "Range Not Satisfiable"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return send(Data(text.utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            Darwin.close(fd)
        }
    }
}

private final class MWServer: @unchecked Sendable {
    typealias Handler = @Sendable (MWRequest, MWConnection) -> Void

    let port: UInt16
    private let listenFD: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var seen: [MWRequest] = []
    private var stopping = false

    init(handler: @escaping Handler) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MWTestError.socket }
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
            throw MWTestError.bind
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

    var requests: [MWRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func requests(_ method: String) -> [MWRequest] { requests.filter { $0.method == method } }

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
        let connection = MWConnection(fd: fd)
        defer { connection.close() }
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
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let request = MWRequest(method: String(first[0]), path: String(first[1]), headers: headers, at: Date())
        lock.lock()
        seen.append(request)
        lock.unlock()
        handler(request, connection)
    }
}

// A gate the server waits on, to hold a refetch where it starts until the test lets it go on.
private final class MWGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
    func wait(timeout: TimeInterval) {
        condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !open && condition.wait(until: deadline) {}
        condition.unlock()
    }
}

private final class MWRecord<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    func add(_ item: Item) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    var all: [Item] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class MWFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }
}

// 200 for a plain GET, 206 for `Range: bytes=N-`. With a gate, the answer holds after its headers and
// before the first body byte until the gate is released (or 30 s pass).
private func mwServeFile(_ data: Data, _ request: MWRequest, _ connection: MWConnection, gate: MWGate? = nil) {
    var start = 0
    let ranged = request.headers["range"] != nil
    if let value = request.headers["range"], value.hasPrefix("bytes="),
       let from = Int(value.dropFirst(6).prefix { $0.isNumber }) { start = from }
    var headers: [(String, String)] = [("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes")]
    if start >= data.count && ranged {
        connection.sendHead(416, headers + [("Content-Range", "bytes */\(data.count)"), ("Content-Length", "0")])
        return
    }
    let length = data.count - start
    if ranged { headers.append(("Content-Range", "bytes \(start)-\(data.count - 1)/\(data.count)")) }
    headers.append(("Content-Length", String(length)))
    guard connection.sendHead(ranged ? 206 : 200, headers) else { return }
    if request.method == "HEAD" { return }
    gate?.wait(timeout: 30)
    var sent = 0
    while sent < length {
        let take = min(32_768, length - sent)
        guard connection.send(data.subdata(in: (start + sent)..<(start + sent + take))) else { return }
        sent += take
    }
}

private func mwNotFound(_ connection: MWConnection) {
    connection.sendHead(404, [("Content-Length", "0")])
}

// What the test learns when a GET arrives: the real name must already be gone at that moment, because the
// damaged file is deleted before it is fetched again.
private struct MWArrival: Sendable {
    let name: String
    let at: Date
    let realNameExistedAtArrival: Bool
}

// MARK: throwaway home, environment

private struct MWEnv: Sendable {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    func whole(_ name: String) -> URL { models.appendingPathComponent(name) }
    func partial(_ name: String) -> URL { models.appendingPathComponent(name + ".partial") }
}

// Sets HOME to a fresh folder and SESAME_MODEL_HOST to the server, makes the Sesame folder and `models/`,
// runs the body, restores both settings.
private func mwRun(
    handler: (MWEnv) -> MWServer.Handler,
    body: (MWEnv, MWServer) async throws -> Void
) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory
        .appendingPathComponent("sesame-watcher-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let env = MWEnv(home: home)
    let server = try MWServer(handler: handler(env))
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
    guard fm.fileExists(atPath: env.folder.path) else {
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before watching anything")
        return
    }
    try fm.createDirectory(at: env.models, withIntermediateDirectories: true)
    try await body(env, server)
}

private func mwWaitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func mwSleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// The watcher under test, with its messages collected. `stop()` is the caller's `defer`.
private func mwMakeWatcher(_ files: [ModelFile], _ messages: MWRecord<String>) -> ModelWatcher {
    ModelWatcher(files: files, onMessage: { messages.add($0) })
}

// The kit's model cache: `$KIT_ROOT/cache`, KIT_ROOT defaulting to `$TMPDIR/sesame-kit` (scripts/kit-lib/common.sh).
private let mwCacheFolder: URL? = {
    let env = ProcessInfo.processInfo.environment
    let root: String
    if let kit = env["KIT_ROOT"], !kit.isEmpty {
        root = kit
    } else if let tmp = env["TMPDIR"], !tmp.isEmpty {
        root = (tmp as NSString).appendingPathComponent("sesame-kit")
    } else {
        return nil
    }
    return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("cache", isDirectory: true)
}()

private let mwRealNames: [(name: String, size: Int)] = [
    ("embeddinggemma-2-Q8_0.gguf", 309_855_456),
    ("mmproj-embeddinggemma-2-Q8_0.gguf", 554_821_024),
]

private let mwCachePresent: Bool = {
    guard let cache = mwCacheFolder else { return false }
    for (name, size) in mwRealNames {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent(name).path),
              (attributes[.size] as? Int) == size else { return false }
    }
    return true
}()

// Internal (not private): the parameter types of a test method must be as visible as the method.
enum MWDamage: CaseIterable, Sendable, CustomTestStringConvertible {
    case oneFlippedByteSameSize, truncated
    var testDescription: String {
        switch self {
        case .oneFlippedByteSameSize: "one byte flipped, same size"
        case .truncated: "cut short by 1,000 bytes"
        }
    }
}

extension ModelDownloadTests {
    @Suite("ModelWatcherTests", .serialized)
    struct ModelWatcherTests {

        // MARK: a change made while the watcher runs: deleted and fetched again within 15 s

        @Test(arguments: MWDamage.allCases)
        func aFileDamagedWhileWatchedIsDeletedAndFetchedAgainWithin15Seconds(damage: MWDamage) async throws {
            let synthetic = MWSynthetic(name: "watch-live.gguf", size: 300_000, seed: 101)
            let arrivals = MWRecord<MWArrival>()
            let messages = MWRecord<String>()
            let gate = MWGate()
            defer { gate.release() }
            try await mwRun(handler: { env in { request, connection in
                guard request.lastComponent == synthetic.file.name else { return mwNotFound(connection) }
                if request.method == "GET" {
                    arrivals.add(MWArrival(name: synthetic.file.name, at: request.at,
                                           realNameExistedAtArrival: mwExists(env.whole(synthetic.file.name))))
                }
                mwServeFile(synthetic.data, request, connection, gate: gate)
            } }, body: { env, server in
                let whole = env.whole(synthetic.file.name)
                try synthetic.data.write(to: whole)
                let watcher = mwMakeWatcher([synthetic.file], messages)
                defer { watcher.stop() }
                watcher.start()
                await mwSleep(1.5)

                // a whole file at launch: nothing happens
                #expect(server.requests.isEmpty, "a whole file was fetched at launch: \(server.requests.map(\.path))")
                #expect(messages.all.isEmpty, "a message for a whole file: \(messages.all)")

                switch damage {
                case .oneFlippedByteSameSize: try mwFlipByte(whole, at: 123_456)
                case .truncated: try mwTruncate(whole, cutting: 1_000)
                }
                let changedAt = Date()

                let arrived = await mwWaitUntil(20) { !arrivals.all.isEmpty }
                #expect(arrived, "no request reached the server within 20 s of the change (\(damage.testDescription))")
                guard let arrival = arrivals.all.first else { return }
                let took = arrival.at.timeIntervalSince(changedAt)
                #expect(took <= 15, "the new request came \(took) s after the change; the bound is 15 s")
                #expect(!arrival.realNameExistedAtArrival,
                        "the damaged file was still under its real name when the new request arrived: it must be deleted first")
                #expect(!mwExists(whole), "the damaged file is still there while the refetch is held")
                #expect(messages.all == [mwMessage], "messages: \(messages.all)")

                gate.release()
                let healed = await mwWaitUntil(20) { mwBytes(whole) == synthetic.data }
                #expect(healed, "the file is not whole again after the refetch")
                #expect(mwNames(env.models) == [synthetic.file.name], "left in models/: \(mwNames(env.models))")

                // The refetched file is a change too (new inode, new time): it is hashed, found whole, left alone.
                if damage == .oneFlippedByteSameSize {
                    await mwSleep(6.5)
                    #expect(server.requests("GET").count == 1,
                            "GETs after the refetch finished: \(server.requests("GET").count); the whole file was fetched again")
                    #expect(messages.all == [mwMessage], "messages after the refetch: \(messages.all)")
                    #expect(mwBytes(whole) == synthetic.data)
                }
            })
        }

        // MARK: a bad file planted before the watcher starts is caught by the re-hash at launch

        @Test func aBadFilePlantedBeforeTheWatcherStartsIsCaughtAtStartAndTheWholeOneIsLeftAlone() async throws {
            let damaged = MWSynthetic(name: "launch-bad.gguf", size: 300_000, seed: 111)
            let good = MWSynthetic(name: "launch-good.gguf", size: 250_000, seed: 112)
            let arrivals = MWRecord<MWArrival>()
            let messages = MWRecord<String>()
            let gate = MWGate()
            defer { gate.release() }
            try await mwRun(handler: { env in { request, connection in
                let all = [damaged, good]
                guard let served = all.first(where: { $0.file.name == request.lastComponent }) else {
                    return mwNotFound(connection)
                }
                if request.method == "GET" {
                    arrivals.add(MWArrival(name: served.file.name, at: request.at,
                                           realNameExistedAtArrival: mwExists(env.whole(served.file.name))))
                }
                mwServeFile(served.data, request, connection, gate: gate)
            } }, body: { env, server in
                var planted = damaged.data
                planted[200_000] ^= 0xFF
                try planted.write(to: env.whole(damaged.file.name))
                try good.data.write(to: env.whole(good.file.name))
                let goodBefore = try FileManager.default.attributesOfItem(atPath: env.whole(good.file.name).path)

                let watcher = mwMakeWatcher([damaged.file, good.file], messages)
                defer { watcher.stop() }
                let startedAt = Date()
                watcher.start()

                let arrived = await mwWaitUntil(15) { !arrivals.all.isEmpty }
                #expect(arrived, "a file planted bad before start was not caught within 15 s")
                guard let arrival = arrivals.all.first else { return }
                #expect(arrival.name == damaged.file.name)
                let took = arrival.at.timeIntervalSince(startedAt)
                #expect(took < 4.5, "caught \(took) s after start(): the re-hash at launch must come before the first 5 s poll")
                #expect(!arrival.realNameExistedAtArrival, "the bad file was not deleted before the new request")
                #expect(!mwExists(env.whole(damaged.file.name)))
                #expect(messages.all == [mwMessage], "messages: \(messages.all)")

                #expect(mwBytes(env.whole(good.file.name)) == good.data, "the whole file next to it was touched")
                let goodAfter = try FileManager.default.attributesOfItem(atPath: env.whole(good.file.name).path)
                #expect(goodAfter[.modificationDate] as? Date == goodBefore[.modificationDate] as? Date)
                #expect(goodAfter[.systemFileNumber] as? Int == goodBefore[.systemFileNumber] as? Int)

                gate.release()
                let healed = await mwWaitUntil(20) { mwBytes(env.whole(damaged.file.name)) == damaged.data }
                #expect(healed, "the planted file was not replaced by a whole one")
                #expect(Set(server.requests("GET").map(\.lastComponent)) == [damaged.file.name],
                        "GETs: \(server.requests("GET").map(\.path))")
            })
        }

        // MARK: the exact message

        @Test func theMessageIsExactlyTheDesignsAndNothingElseIsSaid() async throws {
            let synthetic = MWSynthetic(name: "message-a.gguf", size: 200_000, seed: 121)
            let messages = MWRecord<String>()
            let gate = MWGate()
            defer { gate.release() }
            try await mwRun(handler: { _ in { request, connection in
                guard request.lastComponent == synthetic.file.name else { return mwNotFound(connection) }
                mwServeFile(synthetic.data, request, connection, gate: gate)
            } }, body: { env, server in
                try synthetic.data.prefix(synthetic.data.count - 500).write(to: env.whole(synthetic.file.name))
                let watcher = mwMakeWatcher([synthetic.file], messages)
                defer { watcher.stop() }
                watcher.start()

                let said = await mwWaitUntil(15) { !messages.all.isEmpty }
                #expect(said, "no message within 15 s of start() for a truncated file")
                gate.release()
                _ = await mwWaitUntil(15) { mwBytes(env.whole(synthetic.file.name)) == synthetic.data }
                await mwSleep(0.5)

                #expect(messages.all.count == 1, "one damaged file, one message: \(messages.all)")
                let text = try #require(messages.all.first)
                #expect(text == "The model file was damaged, so it was deleted. Downloading it again.")
                #expect(Array(text.utf8) == Array(mwMessage.utf8))
                #expect(!text.hasSuffix(" ") && !text.hasSuffix("\n"), "trailing space or newline in the message")
                #expect(server.requests("GET").count == 1)
            })
        }

        // MARK: a second failure waits for Retry

        @Test func aSecondFailureWaitsForRetryAndNoThirdFetchHappensUntilRetryIsCalled() async throws {
            let synthetic = MWSynthetic(name: "retry-a.gguf", size: 300_000, seed: 131)
            var wrong = synthetic.data
            wrong[150_000] ^= 0xFF
            let wrongBytes = wrong
            let serveWrong = MWFlag(true)
            let arrivals = MWRecord<MWArrival>()
            let messages = MWRecord<String>()
            try await mwRun(handler: { env in { request, connection in
                guard request.lastComponent == synthetic.file.name else { return mwNotFound(connection) }
                if request.method == "GET" {
                    arrivals.add(MWArrival(name: synthetic.file.name, at: request.at,
                                           realNameExistedAtArrival: mwExists(env.whole(synthetic.file.name))))
                }
                mwServeFile(serveWrong.value ? wrongBytes : synthetic.data, request, connection)
            } }, body: { env, server in
                let whole = env.whole(synthetic.file.name)
                try synthetic.data.prefix(synthetic.data.count - 1_000).write(to: whole)   // damaged at launch
                let watcher = mwMakeWatcher([synthetic.file], messages)
                defer { watcher.stop() }
                #expect(!watcher.needsRetry, "needsRetry is true before start()")
                watcher.start()

                // First failure: the fetch is wrong. ModelDownload fetches once more and that is wrong too.
                let gaveUp = await mwWaitUntil(30) { watcher.needsRetry }
                #expect(gaveUp, "after the fetch and its one refetch both came back wrong the watcher did not wait for Retry; GETs: \(arrivals.all.count)")
                #expect(arrivals.all.count == 2, "fetch, then one refetch from byte 0: \(arrivals.all.count) GETs")
                #expect(messages.all.first == mwMessage)

                // Several polls pass, the file is absent, and no request goes out.
                await mwSleep(2 * 5 + 1)
                #expect(server.requests("GET").count == 2,
                        "a third fetch happened with no Retry: \(server.requests("GET").count) GETs")
                #expect(watcher.needsRetry, "needsRetry dropped back to false with no Retry")
                #expect(!mwExists(whole) && !mwExists(env.partial(synthetic.file.name)),
                        "a file was left behind while waiting: \(mwNames(env.models))")

                // Retry, with a server that now sends the right bytes.
                serveWrong.value = false
                watcher.retry()
                let healed = await mwWaitUntil(20) { mwBytes(whole) == synthetic.data }
                #expect(healed, "Retry did not bring the whole file")
                #expect(server.requests("GET").count == 3, "Retry should make exactly one new fetch: \(server.requests("GET").count) GETs")
                let settled = await mwWaitUntil(5) { !watcher.needsRetry }
                #expect(settled, "needsRetry stayed true after a good fetch")
            })
        }

        // MARK: a whole file never triggers a refetch

        @Test func aWholeFileNeverTriggersARefetchEvenWhenItsTimeOrInodeChanges() async throws {
            let first = MWSynthetic(name: "whole-a.gguf", size: 300_000, seed: 141)
            let second = MWSynthetic(name: "whole-b.gguf", size: 280_000, seed: 142)
            let messages = MWRecord<String>()
            try await mwRun(handler: { _ in { request, connection in
                if request.lastComponent == first.file.name { return mwServeFile(first.data, request, connection) }
                if request.lastComponent == second.file.name { return mwServeFile(second.data, request, connection) }
                mwNotFound(connection)
            } }, body: { env, server in
                try first.data.write(to: env.whole(first.file.name))
                try second.data.write(to: env.whole(second.file.name))
                let watcher = mwMakeWatcher([first.file, second.file], messages)
                defer { watcher.stop() }
                watcher.start()
                await mwSleep(1.5)

                // three kinds of change, none of them to a byte: a new modified time, the same bytes written
                // in place, and the same bytes in a new file renamed over the old one (new inode)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)],
                                                      ofItemAtPath: env.whole(first.file.name).path)
                try second.data.write(to: env.whole(second.file.name))
                await mwSleep(0.3)
                try mwReplaceWithIdenticalCopy(env.whole(first.file.name), data: first.data)
                await mwSleep(0.3)
                try mwReplaceWithIdenticalCopy(env.whole(second.file.name), data: second.data)

                await mwSleep(2 * 5 + 1)    // two polls and a margin

                #expect(server.requests.isEmpty, "a whole file caused a request: \(server.requests.map(\.path))")
                #expect(messages.all.isEmpty, "a whole file caused a message: \(messages.all)")
                #expect(mwBytes(env.whole(first.file.name)) == first.data)
                #expect(mwBytes(env.whole(second.file.name)) == second.data)
                #expect(mwNames(env.models) == [first.file.name, second.file.name],
                        "models/ holds: \(mwNames(env.models))")
            })
        }

        // MARK: the real cached files (skipped when the kit cache is empty)

        @Test(.enabled(if: mwCachePresent, "the kit cache holds both whole model files"))
        func theRealCachedFilesAreLeftAloneAndOneFlippedByteIsCaughtWithin15Seconds() async throws {
            let cache = try #require(mwCacheFolder)
            let textName = mwRealNames[0].name
            let mmName = mwRealNames[1].name
            let arrivals = MWRecord<MWArrival>()
            let messages = MWRecord<String>()
            let gate = MWGate()
            defer { gate.release() }
            try await mwRun(handler: { env in { request, connection in
                if request.method == "GET" {
                    arrivals.add(MWArrival(name: request.lastComponent, at: request.at,
                                           realNameExistedAtArrival: mwExists(env.whole(request.lastComponent))))
                }
                gate.wait(timeout: 30)       // hold every request; the bytes are not needed here
                mwNotFound(connection)
            } }, body: { env, server in
                for (name, _) in mwRealNames {
                    try FileManager.default.copyItem(at: cache.appendingPathComponent(name), to: env.whole(name))
                }
                let mmBefore = try FileManager.default.attributesOfItem(atPath: env.whole(mmName).path)

                let watcher = mwMakeWatcher(ModelFiles.all, messages)
                defer { watcher.stop() }
                watcher.start()
                await mwSleep(7)     // the re-hash at launch of 865 MB, then one poll

                #expect(server.requests.isEmpty, "a whole real file was fetched: \(server.requests.map(\.path))")
                #expect(messages.all.isEmpty, "a message for whole real files: \(messages.all)")

                try mwFlipByte(env.whole(textName), at: 150_000_000)
                let changedAt = Date()
                let arrived = await mwWaitUntil(20) { !arrivals.all.isEmpty }
                #expect(arrived, "one flipped byte in the real text model was not caught within 20 s")
                guard let arrival = arrivals.all.first else { return }
                #expect(arrival.name == textName, "the request was for \(arrival.name)")
                #expect(arrival.at.timeIntervalSince(changedAt) <= 15,
                        "caught \(arrival.at.timeIntervalSince(changedAt)) s after the change; the bound is 15 s")
                #expect(!arrival.realNameExistedAtArrival, "the damaged real file was not deleted before the new request")
                #expect(messages.all == [mwMessage], "messages: \(messages.all)")
                #expect(Set(arrivals.all.map(\.name)) == [textName], "the other real file was fetched too")

                let mmAfter = try FileManager.default.attributesOfItem(atPath: env.whole(mmName).path)
                #expect(mmAfter[.systemFileNumber] as? Int == mmBefore[.systemFileNumber] as? Int)
                #expect(mmAfter[.size] as? Int == mwRealNames[1].size)
                gate.release()
            })

            // The test only ever changed its own copy.
            let intact = ModelFiles.all.allSatisfy { ModelFiles.isPresent($0, at: cache.appendingPathComponent($0.name)) }
            #expect(intact, "the kit cache was changed by this test")
        }
    }
}

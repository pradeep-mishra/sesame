import CryptoKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

// plan-1-t26, tester step. Written from design sections 1, 7 and 12 and the t26 entry only; no product
// source read. Every test runs against a throwaway HOME and a local test server (BSD sockets, 127.0.0.1,
// port chosen by the system) named by SESAME_MODEL_HOST, so nothing real is touched and nothing leaves
// this machine. A synthetic file has a small expected size and hash built here with CryptoKit.
//
// API SHAPES these tests pin (the design names `ModelDownload` and `start()` but fixes no signatures).
// ModelFile and ModelFiles are pinned in ModelFilesTests.swift. If a shape is wrong, ask for a test change.
//   1. `ModelDownload` is a `final class` marked `@unchecked Sendable`, or an `actor`; it is not tied to
//      the main actor, so `ModelDownload(files:)` and `await start()` compile from a nonisolated async
//      context. It lives in the `Sesame` target (`@testable import Sesame`).
//   2. `ModelDownload.init(files: [ModelFile] = ModelFiles.all)`. The design names no way to give the
//      downloader a small synthetic expected size and hash, so this is the injection point. The only
//      launch setting stays SESAME_MODEL_HOST, which these tests set to a base URL with no trailing
//      slash: `http://127.0.0.1:<port>`. The request URL is that base plus
//      `/ggml-org/embeddinggemma-2-GGUF/resolve/<revision>/<file name>` (design section 7); the test
//      server answers by the last path component and ignores the rest.
//   3. `func start() async -> Bool`. It downloads each file in `files` in turn into
//      `<Sesame folder>/models/<name>.partial` and returns when it is finished: true when every file is
//      whole under its real name, false when it stopped. It creates `models/` itself. A failure that is
//      worth retrying (a dropped connection, an HTTP error, a wrong size or hash) is retried on
//      `retryDelays`; a refused redirect is NOT retried (the policy would refuse again), so `start()`
//      returns false at once. A wrong size or hash deletes the `.partial` and fetches once more from byte
//      0 (no Range header); a second wrong result ends `start()` with false and leaves `models/` empty
//      (design section 7: "delete-and-refetch on a bad check; a second failure waits for Retry").
//   4. `static let retryDelays: [TimeInterval]` is `[2, 5, 15, 30]` and `static let noBytesTimeout:
//      TimeInterval` is `60`. The delays count consecutive failures, so the n-th failure in a row waits
//      `retryDelays[n - 1]` seconds before the next request.
//   5. `static func isAllowedRedirect(_ url: URL) -> Bool` is the redirect policy as a pure function of
//      the URL's host. Its allowlist is exactly `huggingface.co` and `us.aws.cdn.hf.co` (the hosts t6's
//      saved log shows), nothing wider. It also accepts the host (and port) named by SESAME_MODEL_HOST
//      while that variable is set, because a local test server can only be reached that way and a 302
//      back to itself is the only redirect these tests can make that must succeed. A refused hop ends the
//      download before any request goes to that host.
//   6. Not pinned, on purpose: whether the `.partial` bytes go through `SesameFolder.append` and the
//      rename through `SesameFolder.rename` (a test cannot see which API wrote a byte; the Run line
//      `scripts/kit-static.sh --quick` and its write-and-delete rule prove it); the HTTP method used for
//      a probe (HEAD or none); what happens to an old `.partial` left by an earlier run; and the scheme
//      of a redirect target.
//   7. `SesameFolder` must let ModelDownload write inside `models/` (the t26 Files line names
//      SesameFolder.swift). The t21 rule that a name with a path separator is refused for the top-level
//      API must stay, since SesameFolderTests pins it.
//   8. HOME is process-wide and `SesameFolderTests` and `SettingsFileTests` (EngineTests) take their own
//      in-module `homeLock`, which this module cannot share. This suite is `.serialized` and uses a
//      distinct throwaway HOME, but a whole-suite `swift test` can interleave them. If that ever shows as
//      flakiness, a tester moves the lock into one shared helper.

private let mdRevisionPath = "/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/"

// MARK: bytes, hashes, files

private func mdHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mdPattern(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(out)
}

private struct MDSynthetic: Sendable {
    let data: Data
    let file: ModelFile
    init(name: String, size: Int, seed: UInt64) {
        let data = mdPattern(size, seed: seed)
        self.data = data
        self.file = ModelFile(name: name, size: size, sha256: mdHex(data))
    }
}

private func mdBytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

private func mdSize(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
}

private func mdNames(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

// MARK: the test server

private struct MDRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let at: Date
    var lastComponent: String {
        let noQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(noQuery.split(separator: "/").last ?? "")
    }
}

private final class MDConnection: @unchecked Sendable {
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
        let reasons = [200: "OK", 206: "Partial Content", 302: "Found", 404: "Not Found",
                       416: "Range Not Satisfiable", 503: "Service Unavailable"]
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

private final class MDServer: @unchecked Sendable {
    typealias Handler = @Sendable (MDRequest, MDConnection) -> Void

    let port: UInt16
    private let listenFD: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var seen: [MDRequest] = []
    private var stopping = false

    init(handler: @escaping Handler) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MDServerError.socket }
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
            throw MDServerError.bind
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

    var requests: [MDRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func requests(_ method: String) -> [MDRequest] { requests.filter { $0.method == method } }

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
        let connection = MDConnection(fd: fd)
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
        let request = MDRequest(method: String(first[0]), path: String(first[1]), headers: headers, at: Date())
        lock.lock()
        seen.append(request)
        lock.unlock()
        handler(request, connection)
    }
}

private enum MDServerError: Error { case socket, bind }

// A gate the server waits on, to hold a transfer half-way until the test lets it go on.
private final class MDGate: @unchecked Sendable {
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

private final class MDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class MDRecord<Item: Sendable>: @unchecked Sendable {
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

private struct MDServe: Sendable {
    var chunk = 32_768
    var pace: TimeInterval = 0.005
    var dropAfter: Int?          // close the connection after this many body bytes
    var pauseAfter: Int?         // wait on `gate` after this many body bytes
    var gate: MDGate?
}

private func mdRangeStart(_ request: MDRequest) -> Int? {
    guard let value = request.headers["range"], value.hasPrefix("bytes=") else { return nil }
    return Int(value.dropFirst(6).prefix { $0.isNumber })
}

// 200 for a plain GET, 206 for `Range: bytes=N-`. Every file answer carries cache headers, so a
// session that is not ephemeral would be tempted to keep it in a URL cache.
private func mdServeFile(_ data: Data, _ request: MDRequest, _ connection: MDConnection, _ options: MDServe = MDServe()) {
    let ranged = request.headers["range"] != nil
    let start = mdRangeStart(request) ?? 0
    var headers: [(String, String)] = [
        ("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes"),
        ("Cache-Control", "max-age=3600"), ("ETag", "\"synthetic\""),
    ]
    if start >= data.count && ranged {
        connection.sendHead(416, headers + [("Content-Range", "bytes */\(data.count)"), ("Content-Length", "0")])
        return
    }
    let length = data.count - start
    if ranged {
        headers.append(("Content-Range", "bytes \(start)-\(data.count - 1)/\(data.count)"))
    }
    headers.append(("Content-Length", String(length)))
    guard connection.sendHead(ranged ? 206 : 200, headers) else { return }
    if request.method == "HEAD" { return }
    var sent = 0
    var paused = false
    while sent < length {
        if let drop = options.dropAfter, sent >= drop { return }
        if let pause = options.pauseAfter, !paused, sent >= pause {
            paused = true
            options.gate?.wait(timeout: 30)
        }
        var take = min(options.chunk, length - sent)
        if let drop = options.dropAfter { take = min(take, drop - sent) }
        if let pause = options.pauseAfter, !paused { take = min(take, pause - sent) }
        if take <= 0 { continue }
        let slice = data.subdata(in: (start + sent)..<(start + sent + take))
        guard connection.send(slice) else { return }
        sent += take
        if options.pace > 0 { Thread.sleep(forTimeInterval: options.pace) }
    }
}

private func mdNotFound(_ connection: MDConnection) {
    connection.sendHead(404, [("Content-Length", "0")])
}

// MARK: throwaway home, environment and the download itself

private struct MDEnv: Sendable {
    let home: URL
    var folder: URL { home.appendingPathComponent("Library/Application Support/Sesame", isDirectory: true) }
    var models: URL { folder.appendingPathComponent("models", isDirectory: true) }
    func partial(_ name: String) -> URL { models.appendingPathComponent(name + ".partial") }
    func whole(_ name: String) -> URL { models.appendingPathComponent(name) }
}

// Sets HOME to a fresh folder and SESAME_MODEL_HOST to the server, runs the body, restores both.
private func mdRun(
    handler: (MDEnv) -> MDServer.Handler,
    body: (MDEnv, MDServer) async throws -> Void
) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory
        .appendingPathComponent("sesame-download-test-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let env = MDEnv(home: home)
    let server = try MDServer(handler: handler(env))
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
        Issue.record("SesameFolder.create() did not use the HOME set for this test; stopped before downloading anything")
        return
    }
    try await body(env, server)
}

private final class MDOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ result: Bool) {
        lock.lock()
        value = result
        lock.unlock()
    }
    var result: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func mdStart(_ files: [ModelFile]) -> (MDOutcome, Task<Void, Never>) {
    let outcome = MDOutcome()
    let task = Task {
        let download = ModelDownload(files: files)
        outcome.set(await download.start())
    }
    return (outcome, task)
}

private func mdWaitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

// Waits for `start()` to return. When it does not, records an Issue, cancels the task and waits (up to
// 30 s) for it to end, so no download is still running when HOME and SESAME_MODEL_HOST are put back.
private func mdFinish(_ outcome: MDOutcome, _ task: Task<Void, Never>, within seconds: TimeInterval,
                      _ what: String) async -> Bool? {
    if await mdWaitUntil(seconds, { outcome.result != nil }) { return outcome.result }
    Issue.record("start() did not return within \(Int(seconds)) s: \(what)")
    task.cancel()
    if !(await mdWaitUntil(30, { outcome.result != nil })) {
        Issue.record("start() ignored cancellation and was still running 30 s later")
    }
    return nil
}

private func mdLocation(_ request: MDRequest, host: String, path: String) -> String {
    let authority = request.headers["host"] ?? "127.0.0.1"
    let port = authority.split(separator: ":").dropFirst().first.map { ":" + $0 } ?? ""
    return "http://\(host)\(port)\(path)"
}

// MARK: real-home snapshot, for the ephemeral-session test

private func mdRealHome() -> String {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
    return NSHomeDirectory()
}

// The URL cache, HTTP storage and cookie entries a non-ephemeral session of this very process would
// leave in the person's real Library (HOME is set after launch, so a session may ignore it).
private func mdCacheSnapshot() -> [String: String] {
    let fm = FileManager.default
    var prefixes: Set<String> = ["xctest", "swiftpm-testing-helper", "com.apple.dt.xctest.tool", "SesamePackageTests"]
    prefixes.insert(ProcessInfo.processInfo.processName)
    if let id = Bundle.main.bundleIdentifier { prefixes.insert(id) }
    if let exe = CommandLine.arguments.first { prefixes.insert((exe as NSString).lastPathComponent) }
    var snapshot: [String: String] = [:]
    func note(_ path: String) {
        guard let attributes = try? fm.attributesOfItem(atPath: path) else { return }
        let size = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        snapshot[path] = "\(size)@\(modified)"
    }
    for sub in ["Library/Caches", "Library/HTTPStorages", "Library/Cookies"] {
        let root = (mdRealHome() as NSString).appendingPathComponent(sub)
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for entry in entries where prefixes.contains(where: { entry.hasPrefix($0) }) {
            let path = (root as NSString).appendingPathComponent(entry)
            note(path)
            for child in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
                note((path as NSString).appendingPathComponent(child))
            }
        }
    }
    return snapshot
}

// Internal (not private): the parameter types of a test method must be as visible as the method.
enum MDRedirect: CaseIterable, Sendable, CustomTestStringConvertible {
    case otherNameForThisHost, hostThatCannotResolve, secondHopLeavesTheAllowlist
    var testDescription: String {
        switch self {
        case .otherNameForThisHost: "302 to localhost (same server, host not on the list)"
        case .hostThatCannotResolve: "302 to https://huggingface.co.evil.invalid"
        case .secondHopLeavesTheAllowlist: "302 to the model host, then 302 to localhost"
        }
    }
}

enum MDAllowedHop: CaseIterable, Sendable, CustomTestStringConvertible {
    case relativeLocation, absoluteLocation
    var testDescription: String {
        switch self {
        case .relativeLocation: "302 with a relative Location"
        case .absoluteLocation: "302 with an absolute Location to the same host"
        }
    }
}

@Suite("ModelDownloadTests", .serialized)
struct ModelDownloadTests {

    // MARK: numbers the design fixes

    @Test func retryScheduleAndNoBytesTimeoutAreTheDesignOnes() {
        #expect(ModelDownload.retryDelays == [2, 5, 15, 30])
        #expect(ModelDownload.noBytesTimeout == 60)
    }

    // MARK: the redirect policy

    @Test func everyHostInT6sSavedLogIsAcceptedByTheRedirectPolicy() throws {
        let previous = getenv("SESAME_MODEL_HOST").map { String(cString: $0) }
        unsetenv("SESAME_MODEL_HOST")
        defer { if let previous { setenv("SESAME_MODEL_HOST", previous, 1) } }

        // The two URLs t6's log shows: the request to huggingface.co and the 302 target on the CDN.
        let logged = [
            "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf",
            "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/mmproj-embeddinggemma-2-Q8_0.gguf",
            "https://us.aws.cdn.hf.co/xet-bridge-us/6ac51ce6533210a3e84f5d67/0ac803e56aa216306210fbb7fe88c19adf40ccd4ebd5ffdcb63be9526501abef?response-content-disposition=inline%3B+filename*%3DUTF-8%27%27embeddinggemma-2-Q8_0.gguf%3B+filename%3D%22embeddinggemma-2-Q8_0.gguf%22%3B&user_id=public&xip=LXm45AgC1ic&X-Xet-Cas-Uid=public&Expires=1792627766&Key-Pair-Id=01KXEF4KZ1B6FV465MAWR4M21F&Hash-Algorithm=SHA256",
            "https://us.aws.cdn.hf.co/xet-bridge-us/6ac51ce6533210a3e84f5d67/77668005a8759d172e07e340395044091d07890ca14ceec7414f02a6e8632b84?user_id=public",
        ]
        for text in logged {
            let url = try #require(URL(string: text))
            let allowed = ModelDownload.isAllowedRedirect(url)
            #expect(allowed, "\(url.host ?? text) is in t6's log")
        }
    }

    @Test func aHostOutsideTheLoggedTwoIsRefusedByTheRedirectPolicy() throws {
        let previous = getenv("SESAME_MODEL_HOST").map { String(cString: $0) }
        unsetenv("SESAME_MODEL_HOST")
        defer { if let previous { setenv("SESAME_MODEL_HOST", previous, 1) } }

        let refused = [
            "https://example.com/model.gguf",
            "https://evil.example/huggingface.co/model.gguf",
            "https://huggingface.co.evil.example/model.gguf",
            "https://evilhuggingface.co/model.gguf",
            "https://www.huggingface.co/model.gguf",
            "https://hf.co/model.gguf",
            "https://cdn.hf.co/model.gguf",
            "https://aws.cdn.hf.co/model.gguf",
            "https://eu.aws.cdn.hf.co/model.gguf",
            "https://us.aws.cdn.hf.co.evil.example/model.gguf",
            "https://evilus.aws.cdn.hf.co/model.gguf",
            "https://cas-server.xethub.hf.co/model.gguf",
            "https://huggingface.co@evil.example/model.gguf",
            "http://localhost:8080/model.gguf",
            "http://127.0.0.1:8080/model.gguf",
        ]
        for text in refused {
            let url = try #require(URL(string: text))
            let allowed = ModelDownload.isAllowedRedirect(url)
            #expect(!allowed, "\(text) must be refused")
        }
    }

    // MARK: .partial grows, and the final name appears only when whole

    @Test func thePartialFileGrowsWhileTheServerHoldsBackAndTheFinalNameAppearsOnlyWhole() async throws {
        let synthetic = MDSynthetic(name: "grow-a.gguf", size: 600_000, seed: 11)
        let gate = MDGate()
        defer { gate.release() }
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            mdServeFile(synthetic.data, request, connection,
                        MDServe(chunk: 25_000, pace: 0.02, pauseAfter: 100_000, gate: gate))
        } }, body: { env, server in
            let (outcome, task) = mdStart([synthetic.file])
            let partial = env.partial(synthetic.file.name)
            let whole = env.whole(synthetic.file.name)

            let appeared = await mdWaitUntil(15) { (mdSize(partial) ?? 0) > 0 }
            #expect(appeared, "no .partial bytes appeared while the server was holding the transfer half-way")
            #expect(!FileManager.default.fileExists(atPath: whole.path),
                    "the real name must not exist while the file is incomplete")
            _ = await mdWaitUntil(2) { (mdSize(partial) ?? 0) >= 100_000 }
            let heldSize = try #require(mdSize(partial))
            #expect(heldSize > 0 && heldSize < synthetic.data.count)
            #expect(mdBytes(partial)?.prefix(heldSize) == synthetic.data.prefix(heldSize),
                    ".partial must hold exactly the first bytes of the file")

            gate.release()
            var sizes: [Int] = []
            var wholeSeenWithWrongSize = false
            let deadline = Date().addingTimeInterval(30)
            while outcome.result == nil && Date() < deadline {
                if let size = mdSize(partial) { sizes.append(size) }
                if let size = mdSize(whole), size != synthetic.data.count { wholeSeenWithWrongSize = true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let result = await mdFinish(outcome, task, within: 30, "after the gate was released")

            #expect(result == true)
            #expect(sizes == sizes.sorted(), ".partial must only grow")
            #expect(Set(sizes + [heldSize]).count >= 2, "the .partial size never changed: bytes were not written as they arrived")
            #expect(!wholeSeenWithWrongSize, "the real name existed with the wrong size")
            #expect(mdBytes(whole) == synthetic.data)
            #expect(!FileManager.default.fileExists(atPath: partial.path), ".partial must be gone after the rename")
            #expect(mdNames(env.models) == [synthetic.file.name])
            #expect(server.requests("GET").count == 1)
        })
    }

    @Test func bothFilesOfTheListAreDownloadedAndRenamed() async throws {
        let first = MDSynthetic(name: "pair-text.gguf", size: 300_000, seed: 21)
        let second = MDSynthetic(name: "pair-mmproj.gguf", size: 400_000, seed: 22)
        try await mdRun(handler: { _ in { request, connection in
            switch request.lastComponent {
            case first.file.name: mdServeFile(first.data, request, connection)
            case second.file.name: mdServeFile(second.data, request, connection)
            default: mdNotFound(connection)
            }
        } }, body: { env, _ in
            let (outcome, task) = mdStart([first.file, second.file])
            let result = await mdFinish(outcome, task, within: 30, "two files")

            #expect(result == true)
            #expect(mdBytes(env.whole(first.file.name)) == first.data)
            #expect(mdBytes(env.whole(second.file.name)) == second.data)
            #expect(mdNames(env.models) == [second.file.name, first.file.name].sorted())
        })
    }

    // MARK: renamed only on an exact size and SHA-256

    @Test func rightSizeButOneWrongByteIsNeverRenamedAndIsFetchedAgainFromTheStartOnce() async throws {
        let synthetic = MDSynthetic(name: "badhash-a.gguf", size: 400_000, seed: 31)
        var wrong = synthetic.data
        wrong[123_456] ^= 0xFF
        let served = wrong
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            mdServeFile(served, request, connection)
        } }, body: { env, server in
            let whole = env.whole(synthetic.file.name)
            let (outcome, task) = mdStart([synthetic.file])
            var wholeEverSeen = false
            let deadline = Date().addingTimeInterval(60)
            while outcome.result == nil && Date() < deadline {
                if FileManager.default.fileExists(atPath: whole.path) { wholeEverSeen = true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let result = await mdFinish(outcome, task, within: 60, "wrong hash")

            #expect(result == false)
            #expect(!wholeEverSeen, "the real name appeared although the SHA-256 was wrong")
            #expect(!FileManager.default.fileExists(atPath: whole.path))
            #expect(mdNames(env.models) == [], "the bad bytes must be deleted: \(mdNames(env.models))")
            let gets = server.requests("GET")
            #expect(gets.count == 2, "design: delete and fetch once more, then wait for Retry; saw \(gets.count) GETs")
            if gets.count >= 2 {
                #expect(gets[1].headers["range"] == nil, "the refetch after a bad check starts from byte 0")
            }
        })
    }

    @Test(arguments: [1, -1])
    func aFileOneByteLongOrShortIsNeverRenamed(delta: Int) async throws {
        let synthetic = MDSynthetic(name: "badsize-a.gguf", size: 400_000, seed: 41)
        let served = delta > 0 ? synthetic.data + Data([0x00]) : synthetic.data.dropLast()
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            mdServeFile(Data(served), request, connection)
        } }, body: { env, _ in
            let whole = env.whole(synthetic.file.name)
            let (outcome, task) = mdStart([synthetic.file])
            var wholeEverSeen = false
            let deadline = Date().addingTimeInterval(60)
            while outcome.result == nil && Date() < deadline {
                if FileManager.default.fileExists(atPath: whole.path) { wholeEverSeen = true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let result = await mdFinish(outcome, task, within: 60, "wrong size \(delta)")

            #expect(result == false)
            #expect(!wholeEverSeen, "the real name appeared with the wrong size")
            #expect(!FileManager.default.fileExists(atPath: whole.path))
        })
    }

    // MARK: a dropped connection resumes with a Range request from the kept bytes

    @Test func aDroppedConnectionResumesWithARangeRequestFromTheKeptBytes() async throws {
        let synthetic = MDSynthetic(name: "drop-a.gguf", size: 600_000, seed: 51)
        struct Get: Sendable { let rangeStart: Int?; let partialAtArrival: Int }
        let record = MDRecord<Get>()
        try await mdRun(handler: { env in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            if request.method == "GET" {
                let number = record.all.count + 1
                record.add(Get(rangeStart: mdRangeStart(request),
                               partialAtArrival: mdSize(env.partial(synthetic.file.name)) ?? 0))
                if number == 1 {
                    mdServeFile(synthetic.data, request, connection,
                                MDServe(chunk: 50_000, pace: 0.05, dropAfter: 300_000))
                    return
                }
            }
            mdServeFile(synthetic.data, request, connection)
        } }, body: { env, _ in
            let (outcome, task) = mdStart([synthetic.file])
            let result = await mdFinish(outcome, task, within: 40, "one dropped connection")
            let gets = record.all

            #expect(result == true)
            #expect(gets.count == 2, "one drop, one resume: \(gets.count) GETs")
            guard gets.count >= 2 else { return }
            #expect(gets[0].rangeStart == nil)
            let resumeFrom = try #require(gets[1].rangeStart, "the second request carried no Range header")
            #expect(resumeFrom > 0, "bytes received before the drop were not kept")
            #expect(resumeFrom <= 300_000)
            #expect(resumeFrom == gets[1].partialAtArrival,
                    "Range starts at \(resumeFrom) but .partial held \(gets[1].partialAtArrival) bytes")
            #expect(mdBytes(env.whole(synthetic.file.name)) == synthetic.data,
                    "the resumed file is not the whole file")
        })
    }

    @Test func eachFailureInARowWaitsLongerBeforeTheNextRequest() async throws {
        let synthetic = MDSynthetic(name: "gaps-a.gguf", size: 200_000, seed: 61)
        let record = MDRecord<Date>()
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            if request.method == "GET" {
                record.add(request.at)
                if record.all.count <= 2 {
                    // headers promise 200,000 bytes, then the connection closes with none sent
                    mdServeFile(synthetic.data, request, connection, MDServe(dropAfter: 0))
                    return
                }
            }
            mdServeFile(synthetic.data, request, connection)
        } }, body: { env, _ in
            let (outcome, task) = mdStart([synthetic.file])
            let result = await mdFinish(outcome, task, within: 60, "two failures in a row")
            let times = record.all

            #expect(result == true)
            #expect(times.count == 3, "two failures, then success: \(times.count) GETs")
            guard times.count >= 3 else { return }
            let firstGap = times[1].timeIntervalSince(times[0])
            let secondGap = times[2].timeIntervalSince(times[1])
            #expect(firstGap >= 1.9 && firstGap <= 6, "first retry after \(firstGap) s, design says 2 s")
            #expect(secondGap >= 4.9 && secondGap <= 10, "second retry after \(secondGap) s, design says 5 s")
            #expect(mdBytes(env.whole(synthetic.file.name)) == synthetic.data)
        })
    }

    // MARK: redirects

    @Test(arguments: MDAllowedHop.allCases)
    func aRedirectBackToTheModelHostIsFollowedAndTheFileCompletes(hop: MDAllowedHop) async throws {
        let synthetic = MDSynthetic(name: "hop-a.gguf", size: 250_000, seed: 71)
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            if request.path.contains("/resolve/") {
                let target = "/blob/store/\(synthetic.file.name)?sig=abc123"
                let location = hop == .relativeLocation
                    ? target : mdLocation(request, host: "127.0.0.1", path: target)
                connection.sendHead(302, [("Location", location), ("Content-Length", "0"),
                                          ("Cache-Control", "no-store")])
                return
            }
            mdServeFile(synthetic.data, request, connection)
        } }, body: { env, server in
            let (outcome, task) = mdStart([synthetic.file])
            let result = await mdFinish(outcome, task, within: 30, "redirect to the model host")

            #expect(result == true)
            #expect(mdBytes(env.whole(synthetic.file.name)) == synthetic.data)
            #expect(server.requests("GET").contains { $0.path.hasPrefix("/blob/store/") })
        })
    }

    @Test(arguments: MDRedirect.allCases)
    func aRedirectToAHostOutsideTheAllowlistIsRefusedAndNoBytesAreKept(case redirect: MDRedirect) async throws {
        let synthetic = MDSynthetic(name: "evil-a.gguf", size: 250_000, seed: 81)
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            if request.path.hasPrefix("/evil/") {
                mdServeFile(synthetic.data, request, connection)   // would hand over every byte if followed
                return
            }
            let target: String
            switch redirect {
            case .otherNameForThisHost:
                target = mdLocation(request, host: "localhost", path: "/evil/\(synthetic.file.name)")
            case .hostThatCannotResolve:
                target = "https://huggingface.co.evil.invalid/evil/\(synthetic.file.name)"
            case .secondHopLeavesTheAllowlist:
                if request.path.hasPrefix("/blob/") {
                    target = mdLocation(request, host: "localhost", path: "/evil/\(synthetic.file.name)")
                } else {
                    target = "/blob/first-hop/\(synthetic.file.name)"
                }
            }
            connection.sendHead(302, [("Location", target), ("Content-Length", "0"), ("Cache-Control", "no-store")])
        } }, body: { env, server in
            let started = Date()
            let (outcome, task) = mdStart([synthetic.file])
            let result = await mdFinish(outcome, task, within: 20, "a refused redirect must end the download, not retry it")
            let took = Date().timeIntervalSince(started)

            #expect(result == false, "\(redirect.testDescription)")
            #expect(took < 15, "refusal took \(took) s: a refused redirect must not run the retry schedule")
            #expect(!server.requests.contains { $0.path.hasPrefix("/evil/") },
                    "a request reached the host outside the allowlist: \(server.requests.map(\.path))")
            #expect(mdNames(env.models) == [], "bytes were kept: \(mdNames(env.models))")
            #expect(!FileManager.default.fileExists(atPath: env.whole(synthetic.file.name).path))
            #expect(!FileManager.default.fileExists(atPath: env.partial(synthetic.file.name).path))
        })
    }

    // MARK: the session is ephemeral

    @Test func theSessionIsEphemeralSoNoUrlCacheOrStorageAppearsAnywhere() async throws {
        let synthetic = MDSynthetic(name: "cache-a.gguf", size: 200_000, seed: 91)
        let before = mdCacheSnapshot()
        try await mdRun(handler: { _ in { request, connection in
            guard request.lastComponent == synthetic.file.name else { return mdNotFound(connection) }
            mdServeFile(synthetic.data, request, connection)
        } }, body: { env, _ in
            let (outcome, task) = mdStart([synthetic.file])
            let result = await mdFinish(outcome, task, within: 30, "one small file")
            #expect(result == true)
            #expect(mdBytes(env.whole(synthetic.file.name)) == synthetic.data)

            let entries = (try? FileManager.default.subpathsOfDirectory(atPath: env.home.path)) ?? []
            let sesame = "Library/Application Support/Sesame"
            let stray = entries.filter {
                $0 != "Library" && $0 != "Library/Application Support" && !$0.hasPrefix(sesame)
            }
            #expect(stray.isEmpty, "files outside the Sesame folder in the throwaway home: \(stray)")
            let caches = entries.filter {
                let leaf = ($0 as NSString).lastPathComponent
                return leaf.hasPrefix("Cache.db") || leaf == "fsCachedData" || leaf.hasSuffix(".binarycookies")
            }
            #expect(caches.isEmpty, "a URL cache or cookie file appeared: \(caches)")
        })
        let after = mdCacheSnapshot()
        #expect(after == before, "the real Library gained or changed URL cache, HTTP storage or cookie entries: \(after.filter { before[$0.key] != $0.value }.keys.sorted())")
    }
}

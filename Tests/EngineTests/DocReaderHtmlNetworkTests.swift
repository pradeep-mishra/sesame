import Foundation
import Testing
import SesameEngine

// plan-4-t6, fix round step 1 (tester). The finding: the html reader must never open a network connection (S8.13: no connection
// beyond the model host). Reading an html document must neither fetch a subresource (image, stylesheet, script, frame, object,
// video, CSS import or background, redirect, base-relative file) nor reveal that the file was read.
//
// Written from the brief only; no product source is read. Names used are the ones DocReaderTests.swift and HelperDocTests.swift
// already use: `DocReader.text(from:extension:)`, `DocReader.read(path:expecting:fromChunk:)`, `DocStep.chunks`, `DocChunk.text`,
// `FileIdentity(size:mtimeNs:inode:)`, and the helper rig `AtWorld`, `atStartHelper`, `atFoldersLine`, `atWaitStatuses`,
// `atCleanStop`, `atPast`.
//
// The rig: a TCP listener in the test process on 127.0.0.1 at a random free port. It accepts every connection, counts it, answers
// an empty 200 and closes. Each html file points EVERY kind of subresource at that port, and holds visible text with a phrase of
// its own. The expected text is written by hand below (never taken from the code under test). The check: the visible text comes
// back, and after a 3 s settle wait the listener has accepted ZERO connections.
//
// The positive control: a plain `URLSession` request to the listener IS counted (and an idle listener counts nothing), so a zero
// from the html tests is trustworthy.
//
// `&nbsp;` is accepted as U+0020 or U+00A0: either is "a space" to a person and to the index's word splitter.

// MARK: the listener

struct NhError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class NhListener: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var lines: [String] = []
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    /// How many connections the listener has accepted so far.
    var count: Int { lock.lock(); defer { lock.unlock() }; return accepted }
    /// The first line of each request that arrived (empty for a connection that sent nothing).
    var requestLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NhError("socket() failed, errno \(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw NhError("bind() to 127.0.0.1 failed, errno \(errno)") }
        guard listen(fd, 128) == 0 else { close(fd); throw NhError("listen() failed, errno \(errno)") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); throw NhError("getsockname() failed, errno \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    private func serve() {
        defer { finished.signal() }
        while true {
            lock.lock(); let done = stopping; lock.unlock()
            if done { return }
            var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&watch, 1, 50) > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            lock.lock(); accepted += 1; lock.unlock()
            answer(client)
        }
    }

    private func answer(_ client: Int32) {
        // A socket from accept() inherits the listener's O_NONBLOCK; the read below must wait up to its timeout.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var wait = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2048)
        let got = recv(client, &buffer, buffer.count, 0)
        let first = got > 0 ? String(decoding: buffer[0..<got], as: UTF8.self).split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" : ""
        lock.lock(); lines.append(first); lock.unlock()
        let reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = reply.withCString { send(client, $0, strlen($0), 0) }
        close(client)
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        finished.wait()
        close(descriptor)
    }
}

/// 3 s: long enough for an asynchronous load to start after the call has returned.
private func nhSettle() { Thread.sleep(forTimeInterval: 3) }

// MARK: the documents

/// One kind of subresource, each pointing at the listener. `all` holds every one of them in one document.
enum NhKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case img, stylesheet, script, iframe, object, embed, videoPoster, videoSource, cssImport, cssBackground
    case metaRefresh, baseHref, anchorHref, all

    var description: String { rawValue }

    /// Lowercase letters only, so it is one word to the index and to `fts`.
    var anchor: String { "harbourlantern" + rawValue.lowercased() + "copperkettle" }

    /// The parts that go in `<head>` and in `<body>`, with `origin` like `http://127.0.0.1:50321`.
    fileprivate func parts(_ origin: String) -> (head: String, body: String) {
        switch self {
        case .img:
            return ("", "<img src=\"\(origin)/img.png\" alt=\"pic\"><img srcset=\"\(origin)/a.png 1x, \(origin)/b.png 2x\">")
        case .stylesheet:
            return ("<link rel=\"stylesheet\" href=\"\(origin)/sheet.css\">", "")
        case .script:
            return ("<script src=\"\(origin)/app.js\"></script>", "")
        case .iframe:
            return ("", "<iframe src=\"\(origin)/frame.html\"></iframe>")
        case .object:
            return ("", "<object data=\"\(origin)/thing.swf\" type=\"application/x-shockwave-flash\"></object>")
        case .embed:
            return ("", "<embed src=\"\(origin)/thing.swf\">")
        case .videoPoster:
            return ("", "<video poster=\"\(origin)/poster.jpg\" preload=\"auto\"></video>")
        case .videoSource:
            return ("", "<video preload=\"auto\"><source src=\"\(origin)/clip.mp4\" type=\"video/mp4\"></video><audio preload=\"auto\" src=\"\(origin)/clip.mp3\"></audio>")
        case .cssImport:
            return ("<style>@import url(\"\(origin)/import.css\");</style>", "")
        case .cssBackground:
            return ("<style>body { background: url(\(origin)/bg.png) } .zqbox { background-image: url('\(origin)/box.png') }</style>",
                    "<div class=\"zqbox\" style=\"background: url(\(origin)/inline.png)\">boxed words</div>")
        case .metaRefresh:
            return ("<meta http-equiv=\"refresh\" content=\"0;url=\(origin)/redirected.html\">", "")
        case .baseHref:
            return ("<base href=\"\(origin)/base/\"><link rel=\"stylesheet\" href=\"rel/style.css\">",
                    "<img src=\"rel/pic.png\"><img src=\"../up.png\"><img src=\"/root.png\">")
        case .anchorHref:
            return ("", "<a href=\"\(origin)/link.html\">linkwordsvisible</a>")
        case .all:
            var head = ""
            var body = ""
            for kind in NhKind.allCases where kind != .all {
                let piece = kind.parts(origin)
                head += piece.head + "\n"
                body += piece.body + "\n"
            }
            return (head, body)
        }
    }

    func html(origin: String) -> String {
        let piece = parts(origin)
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">
            <style>.zqstylemark { color: red }</style>
            <script>var zqscriptvar = 1 < 2 && 3 > 2;</script>
            \(piece.head)
            </head><body>
            <h1>Harbour notes</h1>
            <p>\(anchor)</p>
            <p>Tom &amp; Jerry met x &lt;b&gt; y, a&nbsp;b, num&#65;&#x42;end, copy&copy;right, euro&#8364;sign.</p>
            \(piece.body)
            </body></html>
            """
    }
}

/// What is wrong with an html text; empty when it is the visible text and nothing else (all expected values written by hand).
private func nhProblems(_ text: String, kind: NhKind) -> [String] {
    var problems: [String] = []
    if !text.contains(kind.anchor) { problems.append("lacks the anchor phrase \(kind.anchor)") }
    for wanted in ["Harbour notes", "Tom & Jerry", "x <b> y", "numABend", "copy\u{A9}right", "euro\u{20AC}sign"] where !text.contains(wanted) {
        problems.append("lacks \(wanted) (an entity not decoded?)")
    }
    if !(text.contains("a b") || text.contains("a\u{A0}b")) { problems.append("lacks \"a b\" for a&nbsp;b") }
    if text.contains("&amp;") || text.contains("&lt;") || text.contains("&nbsp;") || text.contains("&#") { problems.append("holds an entity that was not decoded") }
    for forbidden in ["<h1", "<p>", "</p>", "<html", "<body", "<head", "<style", "<script", "<img", "<link", "<iframe", "<object", "<embed",
                      "<video", "<audio", "<source", "<meta", "<base", "<a ", "<div", "DOCTYPE", "href=", "src=", "127.0.0.1", "http://",
                      "zqscriptvar", "zqstylemark", "color:", "background:", "url("] where text.contains(forbidden) {
        problems.append("holds \(forbidden) (tag, script or style text)")
    }
    if kind == .all || kind == .anchorHref, !text.contains("linkwordsvisible") { problems.append("lacks the link's visible words") }
    if kind == .all || kind == .cssBackground, !text.contains("boxed words") { problems.append("lacks the visible words boxed words") }
    return problems
}

// MARK: a temp folder

private final class NhDir {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-dochtml-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

private func nhWrite(_ kind: NhKind, origin: String, in dir: NhDir) throws -> String {
    let path = dir.path + "/page-" + kind.rawValue + ".html"
    try Data(kind.html(origin: origin).utf8).write(to: URL(fileURLWithPath: path))
    return path
}

private func nhIdentity(_ path: String) -> FileIdentity {
    var info = Darwin.stat()
    guard lstat(path, &info) == 0 else { return FileIdentity(size: 0, mtimeNs: 0, inode: 0) }
    return FileIdentity(size: Int64(info.st_size),
                        mtimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                        inode: UInt64(info.st_ino))
}

// MARK: the tests

@Suite("DocReaderHtmlNetworkTests", .serialized)
struct DocReaderHtmlNetworkTests {

    // MARK: the positive control

    @Test func anIdleListenerCountsNothing() async throws {
        let listener = try NhListener()
        defer { listener.stop() }
        try await Task.sleep(for: .seconds(1))
        #expect(listener.count == 0, "an idle listener counted \(listener.count) connection(s)")
    }

    @Test func aPlainURLSessionRequestToTheListenerIsCounted() async throws {
        let listener = try NhListener()
        defer { listener.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/control"))
        let (_, response) = try await session.data(from: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "the control request got no 200 from the listener")
        #expect(listener.count >= 1, "the control request was not counted: the listener cannot be trusted to see a connection")
        #expect(listener.requestLines.contains { $0.contains("GET /control") }, "the listener's request lines: \(listener.requestLines)")
    }

    // MARK: DocReader.text(from:extension:)

    @Test(arguments: NhKind.allCases)
    func theTextOfAnHtmlDocumentIsTheVisibleTextAndNoConnectionIsOpened(kind: NhKind) throws {
        let listener = try NhListener()
        defer { listener.stop() }
        let dir = try NhDir()
        defer { dir.remove() }
        let path = try nhWrite(kind, origin: "http://127.0.0.1:\(listener.port)", in: dir)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        var text: String?
        var failure = "nothing"
        do { text = try DocReader.text(from: bytes, extension: "html") } catch { failure = "\(error)" }
        nhSettle()
        #expect(listener.count == 0, "reading \(kind) html opened \(listener.count) connection(s) to the listener: \(listener.requestLines)")
        let got = try #require(text, "html (\(kind)) should read, it threw \(failure)")
        let problems = nhProblems(got, kind: kind)
        #expect(problems.isEmpty, "the text of the \(kind) html: \(problems); text was: \(got.prefix(400))")
    }

    // MARK: DocReader.read(path:expecting:fromChunk:)

    @Test(arguments: NhKind.allCases)
    func readingAnHtmlFileGivesTheVisibleTextInItsChunksAndNoConnectionIsOpened(kind: NhKind) throws {
        let listener = try NhListener()
        defer { listener.stop() }
        let dir = try NhDir()
        defer { dir.remove() }
        let path = try nhWrite(kind, origin: "http://127.0.0.1:\(listener.port)", in: dir)
        var joined: String?
        var failure = "nothing"
        do { joined = try DocReader.read(path: path, expecting: nhIdentity(path), fromChunk: 0).chunks.map(\.text).joined() } catch { failure = "\(error)" }
        nhSettle()
        #expect(listener.count == 0, "reading a \(kind) html file opened \(listener.count) connection(s) to the listener: \(listener.requestLines)")
        let got = try #require(joined, "the html file (\(kind)) should read, it threw \(failure)")
        let problems = nhProblems(got, kind: kind)
        #expect(problems.isEmpty, "the chunks of the \(kind) html file: \(problems); text was: \(got.prefix(400))")
    }
}

// MARK: through the bundled helper alone

extension EncodeHelperTests {
@Suite("DocReaderHtmlNetworkHelperTests", .serialized)
struct DocReaderHtmlNetworkHelperTests {

    @Test func anHtmlDocumentWithEverySubresourceIsIndexedDoneFoundByItsAnchorAndNoConnectionIsOpened() throws {
        let listener = try NhListener()
        defer { listener.stop() }
        let world = try AtWorld()
        defer { world.remove() }
        let kind = NhKind.all
        let path = world.photos.path + "/netpage.html"
        try Data(kind.html(origin: "http://127.0.0.1:\(listener.port)").utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: atPast - 5)], ofItemAtPath: path)

        let helper = try atStartHelper(world)
        defer { helper.stop() }
        helper.send(atFoldersLine([world.photos]))
        let wait = atWaitStatuses(world, helper, stall: 120, cap: 300, until: { ($0["done"] ?? 0) + ($0["could_not_read"] ?? 0) >= 1 })
        #expect(wait.statuses == ["done": 1], "netpage.html should be done: \(wait.statuses), stderr: \(helper.errors)")
        nhSettle()
        let seenByListener = listener.count
        #expect(atCleanStop(helper) == 0, "the helper did not exit 0 at stdin end; stderr: \(helper.errors)")
        #expect(seenByListener == 0 && listener.count == 0,
                "the helper opened \(max(seenByListener, listener.count)) connection(s) to the listener while indexing html: \(listener.requestLines)")

        let db = try #require(world.db(), "the index cannot be opened")
        let rows = try #require(db.rows("select kind, status from files where path like '%/netpage.html'"))
        #expect(rows.first?[0] == "doc" && rows.first?[1] == "done", "netpage.html row: \(rows)")
        let hits = try #require(db.rows("select count(*) from fts where fts match 'body:\"\(kind.anchor)\"'"), "the fts query could not run")
        #expect(hits.first?.first.flatMap { $0 }.flatMap { Int($0) } == 1, "a body MATCH for the anchor \(kind.anchor) found \(hits)")
        let jerry = try #require(db.rows("select count(*) from fts where fts match 'body:\"Jerry\"'"), "the fts query could not run")
        #expect(jerry.first?.first.flatMap { $0 }.flatMap { Int($0) } == 1, "a body MATCH for a visible word of the entities line found \(jerry)")
    }
}
}

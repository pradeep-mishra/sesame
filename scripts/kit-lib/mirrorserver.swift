// mirrorserver.swift: the small local HTTP server behind scripts/kit-mirror.sh and the selftests of
// scripts/kit-net.sh. Compiled by kit_tool (common.sh), never run by hand. Foundation and Darwin only.
//
//   mirrorserver mirror  --root <dir> --log <file> --rate-file <file> --offline-file <file>
//                        --pidfile <file> --portfile <file>
//     The model mirror. Serves a regular file of <dir> by the last component of the request path
//     (GET, HEAD, Range), 404 for anything else. The rate file holds `max` or bytes per second and
//     is read again while a body is sent; while the offline file exists every connection is reset.
//     One log line per finished request: <epoch> <METHOD> <path> range=<value|-> status=<n> bytes=<n> [note]
//
//   mirrorserver fixture --root <dir> --table <tsv> --log <file> --pidfile <file> --portfile <file>
//     The selftest host: <any>/resolve/<rev>/<name> answers 302 (with x-linked-etag and
//     x-linked-size from the table) to http://localhost:<port>/hop-a/<name>, which answers 302 to
//     http://cdn.localhost:<port>/blob/<name>, which serves <dir>/<name>. One log line per request:
//     <Host header> <METHOD> <path> <status> <bytes>
//
// Both listen on 127.0.0.1 only, on a free port written to --portfile after --pidfile. They exit
// when --pidfile is removed or no longer holds their pid (a kit reset that deleted run/ never leaves
// one behind).
import Foundation
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// ---- arguments -----------------------------------------------------------------------------------

var opts: [String: String] = [:]
let mode: String = {
    let a = CommandLine.arguments
    guard a.count >= 2 else { fail("usage: mirrorserver mirror|fixture --key value ...") }
    var i = 2
    while i + 1 < a.count {
        if a[i].hasPrefix("--") { opts[String(a[i].dropFirst(2))] = a[i + 1] }
        i += 2
    }
    return a[1]
}()

func opt(_ key: String) -> String {
    guard let v = opts[key], !v.isEmpty else { fail("mirrorserver: missing --\(key)") }
    return v
}

// ---- log ----------------------------------------------------------------------------------------

let logFd: Int32 = {
    let fd = open(opt("log"), O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd < 0 { fail("mirrorserver: cannot open the log \(opt("log"))") }
    return fd
}()

func now() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

func logLine(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(logFd, $0.baseAddress, $0.count) }
}

// ---- sockets ------------------------------------------------------------------------------------

func sendAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        if n == 0 { return false }
        offset += n
    }
    return true
}

func sendString(_ fd: Int32, _ s: String) -> Bool {
    Array(s.utf8).withUnsafeBytes { sendAll(fd, $0) }
}

// Closes with a reset, the way a dropped network looks to the client.
func abortConnection(_ fd: Int32) {
    var l = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
    close(fd)
}

struct Request {
    var method: String
    var path: String
    var headers: [String: String]
}

func readRequest(_ fd: Int32) -> Request? {
    var buf = [UInt8]()
    var tmp = [UInt8](repeating: 0, count: 4096)
    let end: [UInt8] = [13, 10, 13, 10]
    while buf.count < 16384 {
        let n = recv(fd, &tmp, tmp.count, 0)
        if n <= 0 { return nil }
        buf.append(contentsOf: tmp[0..<n])
        if buf.count >= 4, (0...(buf.count - 4)).contains(where: { Array(buf[$0..<($0 + 4)]) == end }) { break }
    }
    guard let text = String(bytes: buf, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
        guard let c = l.firstIndex(of: ":") else { continue }
        headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    return Request(method: String(first[0]), path: String(first[1]), headers: headers)
}

func sendHead(_ fd: Int32, _ status: Int, _ headers: [(String, String)]) -> Bool {
    let reasons = [200: "OK", 206: "Partial Content", 302: "Found", 404: "Not Found",
                   405: "Method Not Allowed", 416: "Range Not Satisfiable"]
    var s = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
    for (k, v) in headers { s += "\(k): \(v)\r\n" }
    s += "Connection: close\r\n\r\n"
    return sendString(fd, s)
}

// ---- shared state files ---------------------------------------------------------------------------

final class Cached {
    private var value = ""
    private var stamp = Date.distantPast
    private let lock = NSLock()
    let path: String
    init(_ path: String) { self.path = path }
    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(stamp) > 0.1 {
            stamp = Date()
            value = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\u{0}missing"
        }
        return value == "\u{0}missing" ? nil : value
    }
}

// ---- serving a file -------------------------------------------------------------------------------

struct Served { var status: Int; var bytes: Int; var note: String }

// rate: bytes per second, 0 = no limit (read again at every chunk); offline: true drops the transfer.
func serveFile(_ fd: Int32, _ req: Request, _ path: String, extra: [(String, String)] = [],
               rate: () -> Int, offline: () -> Bool) -> Served {
    var st = stat()
    guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
        let body = "not found\n"
        _ = sendHead(fd, 404, [("Content-Length", String(body.utf8.count))])
        if req.method != "HEAD" { _ = sendString(fd, body) }
        return Served(status: 404, bytes: req.method == "HEAD" ? 0 : body.utf8.count, note: "")
    }
    let size = Int(st.st_size)
    var from = 0
    var to = size - 1
    var status = 200
    if let r = req.headers["range"], r.hasPrefix("bytes=") {
        let parts = r.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let a = Int(parts[0]) {
            from = a
            if let b = Int(parts[1]) { to = min(b, size - 1) }
            if from >= size || from > to {
                _ = sendHead(fd, 416, [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")])
                return Served(status: 416, bytes: 0, note: "")
            }
            status = 206
        }
    }
    let length = to - from + 1
    var headers: [(String, String)] = [("Content-Length", String(length)), ("Accept-Ranges", "bytes"),
                                       ("Content-Type", "application/octet-stream")] + extra
    if status == 206 { headers.append(("Content-Range", "bytes \(from)-\(to)/\(size)")) }
    guard sendHead(fd, status, headers) else { return Served(status: status, bytes: 0, note: "client-closed") }
    if req.method == "HEAD" { return Served(status: status, bytes: 0, note: "") }

    guard let h = FileHandle(forReadingAtPath: path) else { return Served(status: status, bytes: 0, note: "unreadable") }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(from))
    var sent = 0
    var base = Date()
    var baseSent = 0
    var lastRate = -1
    while sent < length {
        if offline() { abortConnection(fd); return Served(status: status, bytes: sent, note: "aborted-offline") }
        let r = rate()
        if r != lastRate { base = Date(); baseSent = sent; lastRate = r }
        let chunk = min(length - sent, r == 0 ? 65536 : max(1, min(65536, r / 20)))
        guard let data = try? h.read(upToCount: chunk), !data.isEmpty else { break }
        if !data.withUnsafeBytes({ sendAll(fd, $0) }) { return Served(status: status, bytes: sent, note: "client-closed") }
        sent += data.count
        if r > 0 {
            let due = Double(sent - baseSent) / Double(r)
            let elapsed = Date().timeIntervalSince(base)
            if due > elapsed { usleep(UInt32((due - elapsed) * 1_000_000)) }
        }
    }
    return Served(status: status, bytes: sent, note: "")
}

func lastComponent(_ path: String) -> String {
    let noQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let name = String(noQuery.split(separator: "/").last ?? "")
    return name.removingPercentEncoding ?? name
}

// ---- the two modes --------------------------------------------------------------------------------

let root = opt("root")
var port: UInt16 = 0

let rateFile = Cached(opts["rate-file"] ?? "/nonexistent")
let offlineFile = Cached(opts["offline-file"] ?? "/nonexistent")
func currentRate() -> Int {
    guard let v = rateFile.read(), v != "max", let n = Int(v), n > 0 else { return 0 }
    return n
}
func isOffline() -> Bool { offlineFile.read() != nil }

func handleMirror(_ fd: Int32) {
    guard let req = readRequest(fd) else { close(fd); return }
    let range = req.headers["range"] ?? "-"
    if isOffline() {
        abortConnection(fd)
        logLine("\(now()) \(req.method) \(req.path) range=\(range) status=reset bytes=0 offline")
        return
    }
    var result: Served
    if req.method != "GET" && req.method != "HEAD" {
        _ = sendHead(fd, 405, [("Content-Length", "0")])
        result = Served(status: 405, bytes: 0, note: "")
    } else {
        let name = lastComponent(req.path)
        let ok = !name.isEmpty && !name.hasPrefix(".") && !name.hasSuffix(".partial") && !name.contains("/")
        result = serveFile(fd, req, ok ? root + "/" + name : "/nonexistent", rate: currentRate, offline: isOffline)
    }
    logLine("\(now()) \(req.method) \(req.path) range=\(range) status=\(result.status) bytes=\(result.bytes)"
            + (result.note.isEmpty ? "" : " " + result.note))
    if result.note != "aborted-offline" { close(fd) }
}

var table: [String: (size: String, sha: String)] = [:]
if mode == "fixture", let text = try? String(contentsOfFile: opt("table"), encoding: .utf8) {
    for l in text.split(separator: "\n") {
        let f = l.split(separator: "\t").map(String.init)
        if f.count >= 3 { table[f[0]] = (f[1], f[2]) }
    }
}

func handleFixture(_ fd: Int32) {
    guard let req = readRequest(fd) else { close(fd); return }
    let host = req.headers["host"] ?? "-"
    let name = lastComponent(req.path)
    var status = 404
    var bytes = 0
    if req.path.contains("/resolve/"), let entry = table[name] {
        status = 302
        _ = sendHead(fd, 302, [("Location", "http://localhost:\(port)/hop-a/\(name)"),
                               ("x-linked-etag", "\"\(entry.sha)\""), ("x-linked-size", entry.size),
                               ("Content-Length", "0")])
    } else if req.path.hasPrefix("/hop-a/"), table[name] != nil {
        status = 302
        _ = sendHead(fd, 302, [("Location", "http://cdn.localhost:\(port)/blob/\(name)"), ("Content-Length", "0")])
    } else if req.path.hasPrefix("/blob/"), table[name] != nil {
        let r = serveFile(fd, req, root + "/" + name, rate: { 0 }, offline: { false })
        status = r.status
        bytes = r.bytes
    } else {
        _ = sendHead(fd, 404, [("Content-Length", "0")])
    }
    logLine("\(host) \(req.method) \(req.path) \(status) \(bytes)")
    close(fd)
}

// ---- listen ---------------------------------------------------------------------------------------

guard mode == "mirror" || mode == "fixture" else { fail("mirrorserver: unknown mode \(mode)") }
signal(SIGPIPE, SIG_IGN)

let listener = socket(AF_INET, SOCK_STREAM, 0)
if listener < 0 { fail("mirrorserver: socket() failed, errno \(errno)") }
var yes: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = 0
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
if bound != 0 { fail("mirrorserver: bind() failed, errno \(errno)") }
if listen(listener, 64) != 0 { fail("mirrorserver: listen() failed, errno \(errno)") }
var bname = sockaddr_in()
var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &bname) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &blen) }
}
port = UInt16(bigEndian: bname.sin_port)

let myPid = String(getpid())
try? myPid.write(toFile: opt("pidfile"), atomically: true, encoding: .utf8)
try? String(port).write(toFile: opt("portfile"), atomically: true, encoding: .utf8)
print("listening 127.0.0.1:\(port)")

Thread.detachNewThread {
    while true {
        sleep(1)
        let current = (try? String(contentsOfFile: opt("pidfile"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current != myPid { exit(0) }
    }
}

while true {
    let fd = accept(listener, nil, nil)
    if fd < 0 { if errno == EINTR { continue }; fail("mirrorserver: accept() failed, errno \(errno)") }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    Thread.detachNewThread { mode == "mirror" ? handleMirror(fd) : handleFixture(fd) }
}

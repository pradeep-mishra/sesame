import Foundation
import Testing

// plan-3-t4, tester step: the network control tool and the merged connection summary of scripts/kit-net.sh
// (`control`, `summary`), the helper files scripts/kit-lib/netcontrol.swift and scripts/kit-lib/netsummary.awk, and the
// `git` change of the line filter of scripts/kit-trace.sh. Written from the plan entry, verify.md (Surfaces, Drive,
// Kit scripts, Not covered), the S8 feature map (S8.7 and its gotchas) and the existing kit scripts (the formats
// `kit-net.sh stop` saves and `kit-trace.sh net` reads); no product source is read, and no script here reads `Sources/`.
//
// Nothing here opens a port, runs `control` or `summary` against a real session, starts nettop or fs_usage, asks for a
// password or launches the app. What runs: `bash -n`, `swiftc -typecheck` (a compile check, the tool is never run), the
// scripts with no mode, an unknown mode and bad arguments (usage, exit 2, nothing written), `summary --from <dir>` over
// hand-written samples, the filter awk of kit-trace.sh over a hand-written fs_usage sample, and kit-trace.sh's readers
// over a hand-written `run/trace/<name>.fs`. Expected values are written here by hand from the entry; none is read from
// the code under test.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `control <name>` takes exactly one argument; the tool prints `PLANT <name> n=<k> pid=<pid> at=<epoch.ms>
//     addr=127.0.0.1:<port>` and the script appends that line to run/net/<name>.plants.
//   - `summary <name> [--mirror <host:port>] [--requests <file>] [--from <dir>]`. With --from the script reads
//     <dir>/<name>.scoped.csv (the nettop log as `kit-net.sh stop` leaves it in run/net), <dir>/<name>.net (the fs_usage
//     network trace as `kit-trace.sh` leaves it in run/trace) and <dir>/<name>.plants. --requests is the mirror's request
//     log (`<epoch> <METHOD> <path> ...`, one line per finished request); its first and last epoch are the window.
//   - Output: one line `PLANT <k> seen-by fs_usage|nettop|both|none` per plant; `PRODUCT <host:port> ...` for a product
//     destination other than the mirror; `OUTSIDE ...` and `AFTER-LAST ...` for a product connection outside the window
//     (first - 2 s to last + 2 s) or a new connection after the last request; `BYTES <n> ...` for 1,000,000 bytes or more;
//     `NOT VALID: ...` naming plant <k> for exit 4; `no connection after the last model request` on a clean run.
//   - Exit 4 before 1: an invalid run (a plant the fs_usage trace missed, dropped events at a plant, an input missing)
//     is never a pass and never a fail, even when the product also failed.
//   - A dropped-events line is any line of the network trace that holds the word `dropped`. With a time it counts at the
//     plants within 3 s of it, without a time at every plant (it cannot be told apart from them).
//   - The `fs_usage` trace names a process and a thread, not a pid, so a plant is told by the process name
//     `SesameNetControl` and its port; the `nettop` log has the pid, so a plant is told by pid and port there.
//   - The filter of kit-trace.sh stays the single-quoted awk program `KEEP_SESAME='...'`; it now keeps a line of a process
//     named exactly `git` (and a line that holds `dropped`, which is not a process line).

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitnet-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    var status: Int32
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        status = 124
    } else {
        status = p.terminationStatus
    }
    try? handle.synchronize()
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    return Ran(status: status, output: text)
}

private func scriptPath(_ name: String) -> String? {
    let url = projectRoot.appendingPathComponent("scripts").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("scripts/\(name) not found")
        return nil
    }
    return url.path
}

private func libPath(_ name: String) -> String? {
    let url = projectRoot.appendingPathComponent("scripts/kit-lib").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("scripts/kit-lib/\(name) not found")
        return nil
    }
    return url.path
}

/// The text of a file with its comment lines removed, so a comment can never satisfy a check. `//` lines too.
private func code(at path: String) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && !t.hasPrefix("//")
        }
        .joined(separator: "\n")
}

private func scriptCode(_ name: String) -> String? {
    guard let path = scriptPath(name) else { return nil }
    return code(at: path)
}

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

/// A fresh, empty KIT_ROOT (the kit requires a folder named sesame-kit*), removed afterwards.
private func withKitRoot<T>(_ body: (String) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-kit-netscripts-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url.resolvingSymlinksInPath().path)
}

private func filesUnder(_ root: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
    var found: [String] = []
    for case let rel as String in walker {
        var isDir: ObjCBool = false
        let full = root + "/" + rel
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) == nil { continue }
        found.append(rel)
    }
    return found
}

private func lines(_ ran: Ran) -> [String] {
    ran.output.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
}

private func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

/// Every SesameNetControl process that is running now ("<pid>"), to show a usage error started nothing.
private func controlProcesses() throws -> Set<String> {
    var found: Set<String> = []
    let names = try run("/bin/ps", ["-axo", "pid=,comm="])
    for line in names.output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { continue }
        let name = (parts[1].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        if name == "SesameNetControl" { found.insert(String(parts[0])) }
    }
    return found
}

// MARK: hand-written samples

/// 10:00:00 local time on a fixed day. Every time of a sample is this plus a number of seconds, so the clock strings of
/// the traces and the epochs of the plants and of the mirror log agree in whatever time zone the Mac is in.
private let baseEpoch: TimeInterval = {
    var c = DateComponents()
    c.year = 2026; c.month = 3; c.day = 10; c.hour = 10; c.minute = 0; c.second = 0
    return Calendar.current.date(from: c)!.timeIntervalSince1970
}()

/// "HH:MM:SS.ffffff" of 10:00:00 plus s seconds.
private func clock(_ s: Double) -> String {
    let total = 36000 + s
    let whole = Int(total)
    return String(format: "%02d:%02d:%02d.%06d", whole / 3600, (whole % 3600) / 60, whole % 60,
                  Int(((total - Double(whole)) * 1_000_000).rounded()))
}

private func epoch(_ s: Double) -> String { String(format: "%.3f", baseEpoch + s) }

private struct Plant {
    let n: Int
    let pid: Int
    let port: Int
    let at: Double
}

private let plants = [Plant(n: 1, pid: 5001, port: 41001, at: 5),
                      Plant(n: 2, pid: 5002, port: 41002, at: 30),
                      Plant(n: 3, pid: 5003, port: 41003, at: 70)]
private let mirror = "127.0.0.1:7000"

private func plantsFile(_ list: [Plant] = plants) -> String {
    list.map { "PLANT s8 n=\($0.n) pid=\($0.pid) at=\(epoch($0.at)) addr=127.0.0.1:\($0.port)" }
        .joined(separator: "\n") + "\n"
}

/// The mirror's request log: one line per finished request, at these offsets.
private func requestsFile(_ at: [Double] = [10, 25, 60]) -> String {
    at.map { "\(epoch($0)) GET /ggml-org/embeddinggemma-2-GGUF/resolve/rev/model.gguf range=- status=200 bytes=1000" }
        .joined(separator: "\n") + (at.isEmpty ? "" : "\n")
}

/// One line of an fs_usage network trace: time, call, details, the call's seconds, process.thread.
private func fs(_ t: Double, _ op: String, _ detail: String, _ proc: String) -> String {
    "\(clock(t))  \(op.padding(toLength: 12, withPad: " ", startingAt: 0))\(detail)  0.000040   \(proc)"
}

/// A connect line. `dot` writes the address as host.port, otherwise host:port (the real spelling is read at the accept
/// stage, so the summary must take both).
private func fsConnect(_ t: Double, _ addr: String, _ proc: String, dot: Bool = true) -> String {
    let shown: String
    if dot, let i = addr.lastIndex(of: ":") {
        shown = addr[addr.startIndex..<i] + "." + addr[addr.index(after: i)...]
    } else {
        shown = addr
    }
    return fs(t, "connect", "F=5  \(shown)", proc)
}

private func fsSend(_ t: Double, _ proc: String) -> String { fs(t, "sendto", "F=5  B=0x40", proc) }

/// The clean trace: the three plants (each a connect and a send by SesameNetControl), and a helper that connects to the
/// mirror twice, all inside the mirror's window (10 to 60).
private func cleanTrace(dot: Bool = true) -> [String] {
    var out: [String] = []
    for (i, p) in plants.enumerated() {
        out.append(fsConnect(p.at + 0.1, "127.0.0.1:\(p.port)", "SesameNetControl.\(9001 + i)", dot: dot))
        out.append(fsSend(p.at + 0.101, "SesameNetControl.\(9001 + i)"))
    }
    out.append(fsConnect(12, mirror, "SesameHelper.9101", dot: dot))
    out.append(fsSend(12.01, "SesameHelper.9101"))
    out.append(fsConnect(40, mirror, "SesameHelper.9102", dot: dot))
    out.append(fsSend(59.9, "SesameHelper.9102"))
    return out
}

private let nettopHeader = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,"

/// A nettop process row: the process, then its bytes.
private func ntProcess(_ t: Double, _ name: String, _ pid: Int, sent: Int) -> String {
    "\(clock(t)),\(name).\(pid),,,0,\(sent),0,0,0,,,,,,,,,,,,"
}

/// A nettop connection row under the process row above it.
private func ntConn(_ t: Double, local: String, peer: String, state: String = "Established") -> String {
    "\(clock(t)),tcp4 \(local)<->\(peer),lo0,\(state),0,64,0,0,0,0.10 ms,131072,131072,BE,-,cubic,-,-,-,-,so,"
}

/// The clean nettop log: two samples (the header is repeated), the control tool of plant 2 and a helper that holds the
/// mirror connection and a listening socket.
private func cleanNettop() -> [String] {
    [nettopHeader,
     ntProcess(30.1, "SesameNetControl", 5002, sent: 64),
     ntConn(30.1, local: "127.0.0.1:50999", peer: "127.0.0.1:41002"),
     ntConn(30.1, local: "127.0.0.1:41002", peer: "127.0.0.1:50999"),
     ntProcess(30.1, "SesameHelper", 6001, sent: 800),
     ntConn(30.1, local: "127.0.0.1:51000", peer: mirror),
     ntConn(30.1, local: "127.0.0.1:49442", peer: "*:*", state: "Listen"),
     nettopHeader,
     ntProcess(41.1, "SesameHelper", 6001, sent: 900),
     ntConn(41.1, local: "127.0.0.1:51000", peer: mirror)]
}

private struct Files {
    var plants: String? = plantsFile()
    var nettop: String? = cleanNettop().joined(separator: "\n") + "\n"
    var trace: String? = cleanTrace().joined(separator: "\n") + "\n"
    var requests: String = requestsFile()
}

/// Writes the files into a folder of a temp KIT_ROOT and runs `summary s8 ... --from <folder>`.
private func summary(_ files: Files) throws -> Ran {
    guard let script = scriptPath("kit-net.sh") else { return Ran(status: -1, output: "") }
    return try withKitRoot { root in
        let dir = root + "/sample"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let p = files.plants { try write(p, to: dir + "/s8.plants") }
        if let n = files.nettop { try write(n, to: dir + "/s8.scoped.csv") }
        if let t = files.trace { try write(t, to: dir + "/s8.net") }
        try write(files.requests, to: dir + "/requests.log")
        return try run(script, ["summary", "s8", "--mirror", mirror, "--requests", dir + "/requests.log", "--from", dir],
                       env: ["KIT_ROOT": root])
    }
}

/// The summary over the clean sample with one change to it.
private func summary(changing change: (inout Files) -> Void) throws -> Ran {
    var f = Files()
    change(&f)
    return try summary(f)
}

private func addTrace(_ files: inout Files, adding extra: [String]) {
    files.trace = (cleanTrace() + extra).joined(separator: "\n") + "\n"
}

private func addNettop(_ files: inout Files, adding extra: [String]) {
    files.nettop = (cleanNettop() + extra).joined(separator: "\n") + "\n"
}

private func has(_ ran: Ran, _ needle: String) -> Bool { ran.output.contains(needle) }

@Suite("KitNetScriptsTests")
struct KitNetScriptsTests {

    // MARK: the files, usage

    @Test("bash -n finds no syntax error in kit-net.sh and kit-trace.sh")
    func bashSyntax() throws {
        for name in ["kit-net.sh", "kit-trace.sh"] {
            guard let path = scriptPath(name) else { continue }
            let ran = try run("/bin/bash", ["-n", path])
            #expect(ran.status == 0, "bash -n scripts/\(name) exited \(ran.status): \(ran.output)")
            #expect(ran.output.isEmpty, "bash -n scripts/\(name) printed: \(ran.output)")
        }
    }

    @Test("no mode is usage: exit 2, the usage names control and summary besides the plan 2 modes, nothing is written")
    func noModeIsUsage() throws {
        guard let path = scriptPath("kit-net.sh") else { return }
        let before = try controlProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, [], env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        #expect(ran.status == 2, "kit-net.sh with no mode exited \(ran.status), wanted 2: \(ran.output)")
        for mode in ["start", "stop", "hosts", "ping", "control", "summary"] {
            #expect(has(ran.output, "kit-net.sh \(mode)"), "the usage does not name `kit-net.sh \(mode)`: \(ran.output)")
        }
        #expect(!has(ran.output, "not built yet: kit-net.sh control") && !has(ran.output, "not built yet: kit-net.sh summary"),
                "the usage still says control or summary are not built: \(ran.output)")
        #expect(try controlProcesses().subtracting(before).isEmpty, "a SesameNetControl process was left behind")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    // Amended in plan-5-t1 (it pinned `speech` as not built: exit 1 and `not built yet: slice 5`): `speech` is built now (S4.8, S8.8), so a
    // run with no connection log is not valid (exit 4), a missing name is usage (exit 2), and nothing says not built; the pure runs on
    // hand-written logs are in KitReadbackSlice5Tests. Not weakened: it still shows that nothing is started and nothing is written.
    @Test("speech is built: with no log it is exit 4, with no name exit 2, and it never says not built yet")
    func speechIsBuilt() throws {
        guard let path = scriptPath("kit-net.sh") else { return }
        let none = try withKitRoot { root in try run(path, ["speech", "s8"], env: ["KIT_ROOT": root]) }
        #expect(none.status == 4, "kit-net.sh speech with no log exited \(none.status), wanted 4: \(none.output)")
        #expect(!has(none, "not built yet"), "speech still says not built yet: \(none.output)")
        let bare = try withKitRoot { root in try run(path, ["speech"], env: ["KIT_ROOT": root]) }
        #expect(bare.status == 2, "kit-net.sh speech with no name exited \(bare.status), wanted 2: \(bare.output)")
    }

    @Test("control and summary with a missing or wrong argument are usage: exit 2, nothing started, nothing written",
          arguments: [["control"], ["control", "bad/name"], ["control", "s8", "extra"],
                      ["summary"], ["summary", "bad/name"], ["summary", "s8", "--bogus"], ["summary", "s8", "--mirror"],
                      ["summary", "s8", "--requests"], ["summary", "s8", "--from"]])
    func badArgumentsAreUsage(_ args: [String]) throws {
        guard let path = scriptPath("kit-net.sh") else { return }
        let before = try controlProcesses()
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, args, env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        #expect(ran.status == 2, "kit-net.sh \(args.joined(separator: " ")) exited \(ran.status), wanted 2: \(ran.output)")
        #expect(has(ran, "usage:"), "no usage text: \(ran.output)")
        #expect(try controlProcesses().subtracting(before).isEmpty, "a SesameNetControl process was left behind")
        #expect(files.isEmpty, "files were written under KIT_ROOT: \(files)")
    }

    // MARK: control (text contract; it is never run here)

    @Test("kit-net.sh control compiles netcontrol.swift to apps/SesameNetControl, runs it and appends its line to run/net/<name>.plants")
    func controlContract() throws {
        guard let text = scriptCode("kit-net.sh") else { return }
        ok(text.contains("netcontrol.swift"), "kit-net.sh never names scripts/kit-lib/netcontrol.swift")
        ok(has(text, "swiftc"), "the tool is never compiled")
        ok(has(text, "apps/SesameNetControl"), "the tool is not put at $KIT_ROOT/apps/SesameNetControl (the name prefix Sesame is what both observers scope on)")
        ok(has(text, "\\.plants"), "the PLANT line is never appended to run/net/<name>.plants")
        ok(text.contains("PLANT"), "no PLANT line is printed")
        ok(!has(text, "\\bsudo\\b"), "kit-net.sh uses sudo: it never asks for a password (the administrator session belongs to kit-trace.sh)")
        ok(!text.contains("Sources"), "kit-net.sh names Sources: the kit never reads the product's source")
        ok(has(text, "(-nt|newer)"), "the build is not cached by file age (the first control after a reset compiles it again, the next ones reuse it)")
    }

    @Test("netcontrol.swift holds the contract of the plant: 127.0.0.1 listener on a free port, 64 bytes, closed after 20 ms, the PLANT line")
    func controlSourceContract() throws {
        guard let path = libPath("netcontrol.swift"), let text = code(at: path) else { return }
        for needle in ["127.0.0.1", "listen", "connect", "accept", "getpid", "PLANT", "pid=", "at=", "addr=", "n="] {
            ok(text.contains(needle), "netcontrol.swift never holds `\(needle)`")
        }
        ok(has(text, "\\b64\\b"), "no 64-byte send")
        ok(has(text, "(usleep\\(\\s*20_?000\\s*\\)|0\\.02\\b|20_?000_?000|milliseconds:\\s*20\\b)"), "the connection is not held for 20 ms before it is closed")
        ok(has(text, "sin_port\\s*=\\s*0|port:\\s*0|in_port_t\\(0\\)|htons\\(0\\)"), "the listener does not ask the system for a free port (port 0)")
        ok(text.contains("--avoid") || text.contains("avoid"), "the listener cannot avoid the mirror's port (the script passes it)")
        ok(!text.contains("Sources"), "netcontrol.swift names Sources")
    }

    @Test("netcontrol.swift compiles (a type check; the tool is not run, no port is opened)")
    func controlTypechecks() throws {
        guard let path = libPath("netcontrol.swift") else { return }
        try withKitRoot { root in
            let ran = try run("/usr/bin/xcrun", ["swiftc", "-typecheck", "-module-cache-path", root + "/modcache", path],
                              env: ["CLANG_MODULE_CACHE_PATH": root + "/modcache"], limit: 300)
            #expect(ran.status == 0, "swiftc -typecheck scripts/kit-lib/netcontrol.swift exited \(ran.status): \(ran.output)")
        }
    }

    // MARK: summary, the clean runs

    @Test("a clean sample: three plants all in the fs_usage trace, one also in nettop, only the mirror, inside the window, under 1 MB: exit 0")
    func cleanSample() throws {
        let ran = try summary(Files())
        #expect(ran.status == 0, "summary exited \(ran.status), wanted 0: \(ran.output)")
        let l = lines(ran)
        #expect(l.contains("PLANT 1 seen-by fs_usage"), "plant 1 not reported as seen by fs_usage only: \(ran.output)")
        #expect(l.contains("PLANT 2 seen-by both"), "plant 2 not reported as seen by both: \(ran.output)")
        #expect(l.contains("PLANT 3 seen-by fs_usage"), "plant 3 not reported as seen by fs_usage only: \(ran.output)")
        #expect(has(ran, "no connection after the last model request"), "the clean run does not say so: \(ran.output)")
        #expect(!l.contains { $0.hasPrefix("PRODUCT") || $0.hasPrefix("OUTSIDE") || $0.hasPrefix("AFTER-LAST") || $0.hasPrefix("BYTES") },
                "a clean sample printed a failure line: \(ran.output)")
    }

    @Test("the address may be spelled host:port in the fs_usage trace too")
    func colonAddresses() throws {
        let ran = try summary(changing: { $0.trace = cleanTrace(dot: false).joined(separator: "\n") + "\n" })
        #expect(ran.status == 0, "summary exited \(ran.status), wanted 0: \(ran.output)")
        #expect(lines(ran).contains("PLANT 1 seen-by fs_usage"), "plant 1 not seen with host:port addresses: \(ran.output)")
    }

    @Test("a session with the model already present: no request logged and no product connection is a clean run")
    func noRequestsNoConnections() throws {
        let ran = try summary(changing: {
            $0.requests = ""
            $0.trace = cleanTrace().filter { !$0.contains("SesameHelper") }.joined(separator: "\n") + "\n"
            $0.nettop = cleanNettop().filter { !$0.contains("SesameHelper") && !$0.contains("51000") && !$0.contains("Listen") }
                .joined(separator: "\n") + "\n"
        })
        #expect(ran.status == 0, "summary exited \(ran.status), wanted 0: \(ran.output)")
        #expect(has(ran, "no connection after the last model request"), "not said: \(ran.output)")
    }

    // MARK: summary, a run that is not valid (exit 4)

    @Test("a plant missing from the fs_usage trace: exit 4 naming it, even when nettop saw it")
    func plantMissingFromTrace() throws {
        let ran = try summary(changing: { f in
            f.trace = cleanTrace().filter { !$0.contains("41003") && !$0.contains("SesameNetControl.9003") }
                .joined(separator: "\n") + "\n"
            addNettop(&f, adding: [nettopHeader,
                                ntProcess(70.2, "SesameNetControl", 5003, sent: 64),
                                ntConn(70.2, local: "127.0.0.1:50888", peer: "127.0.0.1:41003")])
        })
        #expect(ran.status == 4, "summary exited \(ran.status), wanted 4: \(ran.output)")
        #expect(lines(ran).contains("PLANT 3 seen-by nettop"), "plant 3 not reported as seen by nettop only: \(ran.output)")
        #expect(lines(ran).contains { $0.lowercased().contains("not valid") && $0.lowercased().contains("plant 3") },
                "no NOT VALID line names plant 3: \(ran.output)")
    }

    @Test("a plant that neither observer saw: exit 4 naming it")
    func plantMissingFromBoth() throws {
        let ran = try summary(changing: { f in
            f.trace = cleanTrace().filter { !$0.contains("41001") && !$0.contains("SesameNetControl.9001") }
                .joined(separator: "\n") + "\n"
        })
        #expect(ran.status == 4, "summary exited \(ran.status), wanted 4: \(ran.output)")
        #expect(lines(ran).contains("PLANT 1 seen-by none"), "plant 1 not reported as seen by none: \(ran.output)")
        #expect(lines(ran).contains { $0.lowercased().contains("not valid") && $0.lowercased().contains("plant 1") },
                "no NOT VALID line names plant 1: \(ran.output)")
    }

    @Test("a trace that reports dropped events during a plant is exit 4, with a time or without one",
          arguments: ["\(clock(30.5))  *** fs_usage: dropped 12 events ***", "*** fs_usage: dropped 12 events ***"])
    func droppedEventsAtAPlant(_ drop: String) throws {
        let ran = try summary(changing: { addTrace(&$0, adding: [drop]) })
        #expect(ran.status == 4, "summary exited \(ran.status), wanted 4: \(ran.output)")
        #expect(lines(ran).contains { $0.lowercased().contains("not valid") && $0.lowercased().contains("dropped") },
                "no NOT VALID line names the dropped events: \(ran.output)")
    }

    @Test("dropped events far from every plant are noted and do not make the run invalid")
    func droppedEventsElsewhere() throws {
        let ran = try summary(changing: { addTrace(&$0, adding: ["\(clock(50))  *** fs_usage: dropped 3 events ***"]) })
        #expect(ran.status == 0, "summary exited \(ran.status), wanted 0: \(ran.output)")
        #expect(lines(ran).contains { $0.lowercased().contains("dropped") }, "the drop is not mentioned at all: \(ran.output)")
    }

    @Test("an invalid run wins over a product failure: exit 4 and the failure is still printed")
    func invalidBeatsFailure() throws {
        let ran = try summary(changing: { f in
            f.trace = (cleanTrace().filter { !$0.contains("41002") && !$0.contains("SesameNetControl.9002") }
                       + [fsConnect(20, "93.184.216.34:443", "SesameHelper.9101")]).joined(separator: "\n") + "\n"
            f.nettop = cleanNettop().filter { !$0.contains("41002") && !$0.contains("5002") }.joined(separator: "\n") + "\n"
        })
        #expect(ran.status == 4, "summary exited \(ran.status), wanted 4: \(ran.output)")
        #expect(lines(ran).contains { $0.hasPrefix("PRODUCT 93.184.216.34:443") }, "the product destination was not printed: \(ran.output)")
    }

    @Test("an input that is missing is exit 4: no plants, no nettop log, no fs_usage trace, a trace with no Sesame line")
    func missingInputs() throws {
        let cases: [(String, (inout Files) -> Void)] = [
            ("no plants file", { $0.plants = nil }),
            ("an empty plants file", { $0.plants = "" }),
            ("no nettop log", { $0.nettop = nil }),
            ("no fs_usage trace", { $0.trace = nil }),
            ("a trace with no line of a process named Sesame*", { $0.trace = "" }),
        ]
        for (what, change) in cases {
            let ran = try summary(changing: change)
            #expect(ran.status == 4, "\(what): summary exited \(ran.status), wanted 4: \(ran.output)")
        }
    }

    // MARK: summary, a product failure (exit 1)

    @Test("a product connection to any other host:port, seen by fs_usage or by nettop: exit 1 and PRODUCT <addr>")
    func otherDestination() throws {
        let viaTrace = try summary(changing: { addTrace(&$0, adding: [fsConnect(20, "93.184.216.34:443", "SesameHelper.9101")]) })
        #expect(viaTrace.status == 1, "fs_usage: summary exited \(viaTrace.status), wanted 1: \(viaTrace.output)")
        #expect(lines(viaTrace).contains { $0.hasPrefix("PRODUCT 93.184.216.34:443") }, "fs_usage: no PRODUCT line: \(viaTrace.output)")
        let viaNettop = try summary(changing: { addNettop(&$0, adding: [
            nettopHeader, ntProcess(35.1, "SesameHelper", 6001, sent: 900),
            ntConn(35.1, local: "10.0.0.34:50000", peer: "93.184.216.34:443")]) })
        #expect(viaNettop.status == 1, "nettop: summary exited \(viaNettop.status), wanted 1: \(viaNettop.output)")
        #expect(lines(viaNettop).contains { $0.hasPrefix("PRODUCT 93.184.216.34:443") }, "nettop: no PRODUCT line: \(viaNettop.output)")
    }

    @Test("an IPv6 destination is a product connection too")
    func ipv6Destination() throws {
        let ran = try summary(changing: { addNettop(&$0, adding: [
            nettopHeader, ntProcess(35.1, "SesameHelper", 6001, sent: 900),
            "\(clock(35.1)),tcp6 2601:600:9000:156a::e3fb.54475<->2607:f8b0:400e:c0d::65.443,en0,Established,0,64,0,0,0,1.00 ms,131072,131072,BE,-,cubic,1,-,-,-,so,"]) })
        #expect(ran.status == 1, "summary exited \(ran.status), wanted 1: \(ran.output)")
        #expect(lines(ran).contains { $0.hasPrefix("PRODUCT") && $0.contains("2607:f8b0:400e:c0d::65") && $0.contains("443") },
                "no PRODUCT line names the IPv6 destination: \(ran.output)")
    }

    @Test("a connection of another process, not named Sesame*, is not a product connection")
    func otherProcessesAreNotProduct() throws {
        let ran = try summary(changing: { f in
            addTrace(&f, adding: [fsConnect(20, "93.184.216.34:443", "curl.9300")])
            addNettop(&f, adding: [nettopHeader, ntProcess(35.1, "Safari", 777, sent: 5_000_000),
                                ntConn(35.1, local: "10.0.0.34:50000", peer: "93.184.216.34:443")])
        })
        #expect(ran.status == 0, "summary exited \(ran.status), wanted 0: \(ran.output)")
    }

    @Test("a product connection outside the mirror's first-to-last window plus 2 s: exit 1")
    func outsideWindow() throws {
        let before = try summary(changing: { addTrace(&$0, adding: [fsConnect(2, mirror, "SesameHelper.9101")]) })
        #expect(before.status == 1, "before the first request: summary exited \(before.status), wanted 1: \(before.output)")
        #expect(lines(before).contains { $0.hasPrefix("OUTSIDE") }, "before the first request: no OUTSIDE line: \(before.output)")
        let after = try summary(changing: { addTrace(&$0, adding: [fsConnect(65, mirror, "SesameHelper.9101")]) })
        #expect(after.status == 1, "after the last request: summary exited \(after.status), wanted 1: \(after.output)")
        #expect(!has(after, "no connection after the last model request"), "it still says the run is clean: \(after.output)")
    }

    @Test("a connection by a product process after the last model request, to the mirror or to loopback: exit 1",
          arguments: [(61.0, "127.0.0.1:7000"), (65.0, "127.0.0.1:7000"), (65.0, "127.0.0.1:9999")])
    func afterLastRequest(_ at: Double, _ addr: String) throws {
        let viaTrace = try summary(changing: { addTrace(&$0, adding: [fsConnect(at, addr, "SesameHelper.9101")]) })
        #expect(viaTrace.status == 1, "fs_usage, \(addr) at +\(at): summary exited \(viaTrace.status), wanted 1: \(viaTrace.output)")
        #expect(lines(viaTrace).contains { $0.hasPrefix("AFTER-LAST") || $0.hasPrefix("PRODUCT") },
                "fs_usage, \(addr) at +\(at): no failure line: \(viaTrace.output)")
        if addr == mirror {
            #expect(lines(viaTrace).contains { $0.hasPrefix("AFTER-LAST") && $0.contains("after the last model request") },
                    "fs_usage, \(addr) at +\(at): no AFTER-LAST line: \(viaTrace.output)")
        }
        // nettop only reports a connection at the sample that first sees it (up to a second late), so its bar is last + 1 s
        let sampleAt = at + 1
        let viaNettop = try summary(changing: { addNettop(&$0, adding: [
            nettopHeader, ntProcess(sampleAt, "SesameHelper", 6002, sent: 900),
            ntConn(sampleAt, local: "127.0.0.1:52000", peer: addr)]) })
        #expect(viaNettop.status == 1, "nettop, \(addr) at +\(sampleAt): summary exited \(viaNettop.status), wanted 1: \(viaNettop.output)")
    }

    @Test("with no model request logged any product connection is after the last one: exit 1")
    func connectionWithNoRequest() throws {
        let ran = try summary(changing: { $0.requests = "" })
        #expect(ran.status == 1, "summary exited \(ran.status), wanted 1: \(ran.output)")
        #expect(lines(ran).contains { $0.hasPrefix("AFTER-LAST") }, "no AFTER-LAST line: \(ran.output)")
    }

    @Test("1,000,000 bytes sent by Sesame processes is a failure, 999,999 is not; the count is per process, not summed over samples")
    func bytesSent() throws {
        func withSent(_ a: Int, _ b: Int = 0) throws -> Ran {
            try summary(changing: { addNettop(&$0, adding: [
                nettopHeader, ntProcess(42.1, "SesameHelper", 6001, sent: a),
                ntProcess(42.1, "SesameHelper", 6003, sent: b)]) })
        }
        let under = try withSent(999_999)
        #expect(under.status == 0, "999,999 bytes: summary exited \(under.status), wanted 0: \(under.output)")
        let over = try withSent(1_000_000)
        #expect(over.status == 1, "1,000,000 bytes: summary exited \(over.status), wanted 1: \(over.output)")
        #expect(lines(over).contains { $0.hasPrefix("BYTES") }, "no BYTES line: \(over.output)")
        let split = try withSent(600_000, 400_000)
        #expect(split.status == 1, "two processes, 1,000,000 together: summary exited \(split.status), wanted 1: \(split.output)")
        let twoSamples = try summary(changing: { f in
            f.nettop = ([nettopHeader, ntProcess(30.1, "SesameHelper", 6001, sent: 500_000),
                         ntConn(30.1, local: "127.0.0.1:51000", peer: mirror),
                         nettopHeader, ntProcess(31.1, "SesameHelper", 6001, sent: 999_999),
                         ntConn(31.1, local: "127.0.0.1:51000", peer: mirror),
                         nettopHeader, ntProcess(30.1, "SesameNetControl", 5002, sent: 64),
                         ntConn(30.1, local: "127.0.0.1:50999", peer: "127.0.0.1:41002")]).joined(separator: "\n") + "\n"
        })
        #expect(twoSamples.status == 0, "one process, two samples (500,000 then 999,999): summary exited \(twoSamples.status), wanted 0: \(twoSamples.output)")
    }

    @Test("the plants are left out by pid and port only: a control process's own bytes and its plant connection are not the product's")
    func plantsAreLeftOut() throws {
        let ran = try summary(changing: { addNettop(&$0, adding: [
            nettopHeader, ntProcess(30.2, "SesameNetControl", 5002, sent: 2_000_000),
            ntConn(30.2, local: "127.0.0.1:50999", peer: "127.0.0.1:41002")]) })
        #expect(ran.status == 0, "summary exited \(ran.status), wanted 0: \(ran.output)")
    }

    @Test("a product connection to the control's port still fails, in either observer")
    func productToControlPort() throws {
        let viaTrace = try summary(changing: { addTrace(&$0, adding: [fsConnect(31, "127.0.0.1:41002", "SesameHelper.9101")]) })
        #expect(viaTrace.status == 1, "fs_usage: summary exited \(viaTrace.status), wanted 1: \(viaTrace.output)")
        #expect(lines(viaTrace).contains { $0.hasPrefix("PRODUCT 127.0.0.1:41002") }, "fs_usage: no PRODUCT line: \(viaTrace.output)")
        let viaNettop = try summary(changing: { addNettop(&$0, adding: [
            nettopHeader, ntProcess(31.1, "SesameHelper", 6001, sent: 900),
            ntConn(31.1, local: "127.0.0.1:50777", peer: "127.0.0.1:41002")]) })
        #expect(viaNettop.status == 1, "nettop: summary exited \(viaNettop.status), wanted 1: \(viaNettop.output)")
        #expect(lines(viaNettop).contains { $0.hasPrefix("PRODUCT 127.0.0.1:41002") }, "nettop: no PRODUCT line: \(viaNettop.output)")
    }

    @Test("the control's pid alone does not leave a connection out: another port of the control process still fails")
    func controlPidToAnotherPort() throws {
        let viaNettop = try summary(changing: { addNettop(&$0, adding: [
            nettopHeader, ntProcess(30.3, "SesameNetControl", 5002, sent: 64),
            ntConn(30.3, local: "10.0.0.34:50000", peer: "93.184.216.34:443")]) })
        #expect(viaNettop.status == 1, "nettop: summary exited \(viaNettop.status), wanted 1: \(viaNettop.output)")
        #expect(lines(viaNettop).contains { $0.hasPrefix("PRODUCT 93.184.216.34:443") }, "nettop: no PRODUCT line: \(viaNettop.output)")
        let viaTrace = try summary(changing: { addTrace(&$0, adding: [fsConnect(30.3, "93.184.216.34:443", "SesameNetControl.9002")]) })
        #expect(viaTrace.status == 1, "fs_usage: summary exited \(viaTrace.status), wanted 1: \(viaTrace.output)")
        #expect(lines(viaTrace).contains { $0.hasPrefix("PRODUCT 93.184.216.34:443") }, "fs_usage: no PRODUCT line: \(viaTrace.output)")
    }

    // MARK: the git lines of the trace

    /// The program of the filter in kit-trace.sh: the single-quoted text of `KEEP_SESAME='...'`.
    private func filterProgram() -> String? {
        guard let text = scriptCode("kit-trace.sh") else { return nil }
        guard let r = text.range(of: "KEEP_SESAME='[^']*'", options: .regularExpression) else {
            Issue.record("kit-trace.sh has no single-quoted KEEP_SESAME='...' filter")
            return nil
        }
        var s = String(text[r])
        s.removeFirst("KEEP_SESAME='".count)
        s.removeLast()
        return s
    }

    /// A raw fs_usage line, as the live stream holds it: time, call, details, seconds, process.thread.
    private func raw(_ t: Double, _ op: String, _ path: String, _ proc: String, flag: String = "") -> String {
        let seconds = flag.isEmpty ? "0.000100  " : "0.000100 \(flag)"
        return "\(clock(t))  \(op.padding(toLength: 12, withPad: " ", startingAt: 0))F=5  (R_____)  \(path)  \(seconds) \(proc)"
    }

    @Test("the line filter keeps the lines of Sesame* processes and of a process named exactly git; gitx, digit, git-remote and Git are dropped")
    func filterKeepsGit() throws {
        guard let program = filterProgram() else { return }
        // the stream in order, each line with what the filter must do to it (written by hand)
        let stream: [(line: String, kept: Bool)] = [
            (raw(1, "open", "/Users/x/pick/a.png", "Sesame.101"), true),
            (raw(2, "open", "/Users/x/pick/.git/config", "git.202"), true),
            (raw(3, "WrData", "/Users/x/pick/.git/index.lock", "git.202", flag: "W"), true),
            (raw(4, "open", "/Users/x/pick/d.png", "gitx.303"), false),
            (raw(5, "open", "/Users/x/pick/e.png", "digit.404"), false),
            (raw(6, "open", "/Users/x/pick/b.png", "SesameHelper.505"), true),
            (raw(7, "open", "/Users/x/pick/f.png", "git-remote-https.606"), false),
            (raw(8, "open", "/Users/x/pick/g.png", "Git.707"), false),
            (raw(9, "open", "/Users/x/pick/h.png", "bash.808"), false),
            (raw(10, "open", "/Users/x/pick/c.png", "SesameNetControl.909"), true),
            (raw(11, "open", "/Users/x/pick/i.png", "mdworker_shared.1"), false),
            ("*** fs_usage: dropped 12 events ***", true),
        ]
        try withKitRoot { root in
            let sample = root + "/raw.fs"
            try write(stream.map { $0.line }.joined(separator: "\n") + "\n", to: sample)
            let ran = try run("/bin/sh", ["-c", "/usr/bin/awk \"$1\" < \"$2\"", "sh", program, sample])
            #expect(ran.status == 0, "the filter exited \(ran.status): \(ran.output)")
            let kept = ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let wanted = stream.filter { $0.kept }.map { $0.line }
            #expect(kept == wanted, "the filter kept the wrong lines.\nkept:\n\(kept.joined(separator: "\n"))\nwanted:\n\(wanted.joined(separator: "\n"))")
        }
    }

    /// Runs a reader of kit-trace.sh over a hand-written run/trace/s.fs (what the filter leaves) in a temp KIT_ROOT.
    private func runTrace(_ lines: [String], _ args: [String], setup: (String) throws -> Void = { _ in }) throws -> Ran {
        guard let script = scriptPath("kit-trace.sh") else { return Ran(status: -1, output: "") }
        return try withKitRoot { root in
            try write(lines.joined(separator: "\n") + "\n", to: root + "/run/trace/s.fs")
            try setup(root)
            return try run(script, args, env: ["KIT_ROOT": root])
        }
    }

    /// A pick root with a file the helper opens and a .git folder with a config that git opens.
    private func pickRoot(_ root: String) throws -> String {
        let pick = root + "/pick"
        try write("png", to: pick + "/a.png")
        try write("png", to: pick + "/b.png")
        try write("[core]", to: pick + "/.git/config")
        return pick
    }

    private func gitSample(_ pick: String) -> [String] {
        [raw(1, "open", "\(pick)/a.png", "SesameHelper.505"),
         raw(2, "open", "\(pick)/b.png", "SesameHelper.505"),
         raw(3, "open", "\(pick)/.git/config", "git.202"),
         raw(4, "open", "\(pick)/.git/config", "git.202"),
         raw(5, "open", "\(pick)/.git", "git.202"),
         raw(6, "WrData", "\(pick)/.git/index.lock", "git.202", flag: "W"),
         raw(7, "WrData", "/Users/x/Library/Application Support/Sesame/index.sqlite", "SesameHelper.505", flag: "W"),
         raw(8, "open", "/Users/x/Library/Application Support/Sesame/settings.json", "Sesame.101")]
    }

    @Test("by-process prints a git row of its own and never counts a git line as Sesame or SesameHelper")
    func byProcessHasGit() throws {
        // by-process reads process names only, so the folder of the sample need not exist
        let ran = try runTrace(gitSample("/tmp/pick"), ["by-process", "s"])
        #expect(ran.status == 0, "by-process exited \(ran.status), wanted 0: \(ran.output)")
        var counts: [String: Int] = [:]
        for l in lines(ran) {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if f.count == 2, let n = Int(f[0]) { counts[f[1]] = n }
        }
        #expect(counts["git"] == 4, "the git row is not 4 (or is missing): \(ran.output)")
        #expect(counts["SesameHelper"] == 3, "SesameHelper is not 3 (a git line was counted as it, or lost): \(ran.output)")
        #expect(counts["Sesame"] == 1, "Sesame is not 1: \(ran.output)")
    }

    @Test("opens accepts --by git and lists git's opens apart from the helper's and from --by Sesame*")
    func opensByGit() throws {
        try withKitRoot { root in
            let pick = try pickRoot(root)
            let sample = gitSample(pick)
            guard let script = scriptPath("kit-trace.sh") else { return }
            try write(sample.joined(separator: "\n") + "\n", to: root + "/run/trace/s.fs")
            let env = ["KIT_ROOT": root]
            let git = try run(script, ["opens", "s", "--under", pick, "--by", "git"], env: env)
            #expect(git.status == 0, "opens --by git exited \(git.status): \(git.output)")
            #expect(git.output.contains("regular files: 2 opens (1 distinct)"), "git's regular-file opens are not 2 opens of 1 file: \(git.output)")
            #expect(git.output.contains("directories: 1 opens (1 distinct)"), "git's directory opens are not 1: \(git.output)")
            let helper = try run(script, ["opens", "s", "--under", pick, "--by", "SesameHelper"], env: env)
            #expect(helper.output.contains("regular files: 2 opens (2 distinct)"), "the helper's opens are not 2 of 2 files (git's were mixed in or lost): \(helper.output)")
            #expect(helper.output.contains("directories: 0 opens (0 distinct)"), "the helper has directory opens: \(helper.output)")
            let all = try run(script, ["opens", "s", "--under", pick, "--by", "Sesame*"], env: env)
            #expect(all.output.contains("regular files: 2 opens (2 distinct)"), "--by Sesame* counts git's opens: \(all.output)")
            #expect(all.output.contains("directories: 0 opens (0 distinct)"), "--by Sesame* counts git's directory open: \(all.output)")
        }
    }

    @Test("writes lists git's writes under their own name, and accepts --by git and --by SesameHelper")
    func writesByGit() throws {
        try withKitRoot { root in
            let pick = try pickRoot(root)
            guard let script = scriptPath("kit-trace.sh") else { return }
            try write(gitSample(pick).joined(separator: "\n") + "\n", to: root + "/run/trace/s.fs")
            let env = ["KIT_ROOT": root]
            let all = try run(script, ["writes", "s", "--under", pick], env: env)
            #expect(all.status == 0, "writes exited \(all.status): \(all.output)")
            #expect(lines(all).contains("WRITE git WrData \(pick)/.git/index.lock"), "git's write is not listed as `WRITE git ...`: \(all.output)")
            #expect(all.output.contains("(trace s): 1"), "the write count under the pick is not 1: \(all.output)")
            let git = try run(script, ["writes", "s", "--under", pick, "--by", "git"], env: env)
            #expect(git.status == 0, "writes --by git exited \(git.status): \(git.output)")
            #expect(lines(git).contains("WRITE git WrData \(pick)/.git/index.lock"), "--by git does not list git's write: \(git.output)")
            let helper = try run(script, ["writes", "s", "--under", pick, "--by", "SesameHelper"], env: env)
            #expect(helper.status == 0, "writes --by SesameHelper exited \(helper.status): \(helper.output)")
            #expect(!helper.output.contains("WRITE git"), "--by SesameHelper lists a git write: \(helper.output)")
            #expect(helper.output.contains("(trace s): 0"), "the helper made no write under the pick, the count is not 0: \(helper.output)")
        }
    }

    @Test("a trace of only git lines (or git lines and a drop line) is not valid: by-process, opens, writes and stop exit 4, saw nothing")
    func gitAloneIsNotATrace() throws {
        let onlyGit = [raw(1, "open", "/tmp/pick/.git/config", "git.202"),
                       raw(2, "WrData", "/tmp/pick/.git/index.lock", "git.202", flag: "W"),
                       "*** fs_usage: dropped 4 events ***"]
        let calls: [[String]] = [["by-process", "s"], ["opens", "s", "--under", "/tmp/pick", "--by", "git"],
                                 ["writes", "s", "--under", "/tmp/pick"], ["stop", "s"]]
        for args in calls {
            let ran = try runTrace(onlyGit, args, setup: { root in
                // stop reads a pid file; a pid nobody holds is dropped quietly, so it reaches the check of the lines
                try write("99999999\n", to: root + "/run/pids/trace-s.pid")
            })
            #expect(ran.status == 4, "\(args.joined(separator: " ")): exit \(ran.status), wanted 4: \(ran.output)")
            #expect(ran.output.contains("saw nothing"), "\(args.joined(separator: " ")): no `saw nothing`: \(ran.output)")
        }
    }

    @Test("stop of a trace with Sesame lines and git lines is valid: exit 0")
    func stopWithGitLines() throws {
        let ran = try runTrace(gitSample("/tmp/pick"), ["stop", "s"], setup: { root in
            try write("99999999\n", to: root + "/run/pids/trace-s.pid")
        })
        #expect(ran.status == 0, "stop exited \(ran.status), wanted 0: \(ran.output)")
    }
}

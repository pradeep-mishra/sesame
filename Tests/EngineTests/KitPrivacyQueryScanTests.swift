import Foundation
import SQLite3
import Testing

// plan-3-t6, tester step: `scripts/kit-privacy.sh query-scan` and `prompts` (S8.9 the query scan, S8.10 the prompts
// part, S8.13 logs hold only event names). Written from the plan-3-t6 entry, verify.md, the S8 feature map and the kit as
// it stands; no product source is read and neither mode reads `Sources/`.
//
// Nothing here launches an app, runs nettop, fs_usage, sudo or osascript, asks for a password, writes the real unified
// log or opens the real permission database. Every run is a child process of the script with a temp KIT_ROOT (a folder
// named sesame-kit under a temp folder), its own TMPDIR (so no real `$TMPDIR/Sesame-*` folder is ever scanned), hand-made
// trees and hand-written window dumps. `query-scan` runs with `--no-log`, except in the tests that put hand-made `log`
// and `logger` programs first on PATH (they never touch the real log). `prompts start` is never run. `prompts stop` is
// run only where there is nothing to end: no pid file at all, or a pid file naming a process that has already exited
// (a hand-made watcher that is gone), so the poller, `osascript` and `kill` are never reached. Expected values are written
// here by hand from the entry; none comes from the code under test.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - `query-scan <markers-file> [--no-log]`: one marker per line (blank lines and a trailing CR are ignored). A missing
//     markers file or one with no marker is exit 4 `not valid`. The eight places are the Sesame folder
//     (`home/Library/Application Support/Sesame`), `home/Library/{Preferences,Caches,HTTPStorages,Saved Application State,
//     Logs}`, the scratch folders `$TMPDIR/Sesame-*` and the mirror log `run/mirror-requests.log`; the ninth, the
//     unified log, is read unless `--no-log` (so the clean line says 8 places, or 9 with the log).
//   - Output: the controls first, one line per place that starts `CONTROL <place>` and has no `FAILED` when it passed
//     (labels: `Application Support/Sesame`, `Preferences`, `Caches`, `HTTPStorages`, `Saved Application State`, `Logs`,
//     `$TMPDIR/Sesame-control-<n>` as `TMPDIR/Sesame-`, and with the log `unified log`); a control that fails prints
//     `CONTROL <place> FAILED ...` and the run is exit 4 with `not valid`, and no marker line. Each passed control line
//     says a marker that was never planted was not found (the word `unplanted`). The control marker is
//     `qm-control-<random>`, named in `scan-controls.txt` (the controls' lines, saved in the evidence folder).
//   - Findings: `FOUND <marker> in <file>` with the absolute path of the file (`FOUND <marker> in unified log` for the log),
//     exit 1; none: exit 0 and `no marker found in <n> places`.
//   - `prompts`: a window dump is one window per line; a line names Sesame when it holds `sesame` in any case and fails
//     when it also holds `Full Disk Access`, `camera` or `microphone` in any case. `parse --sample <file>` prints the lines
//     naming Sesame (the text kept), then `no dialog named Sesame seen` when there is none, and a last line
//     `seen=<n> exit=<0|1>` (the same text `stop` saves). The watcher's own lines are kept in
//     `run/prompts/<name>.windows`; `stop` reads that file (a missing file is no dialog), saves `prompts.txt` in the
//     evidence folder and `run/prompts/<name>.result`, removes the pid file and exits as the result says.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitqs-out-" + UUID().uuidString)
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

private func scriptPath() -> String? {
    let url = projectRoot.appendingPathComponent("scripts/kit-privacy.sh")
    guard FileManager.default.fileExists(atPath: url.path) else {
        Issue.record("scripts/kit-privacy.sh not found")
        return nil
    }
    return url.path
}

/// The script's code: every line that is not a comment.
private func scriptCode() -> String? {
    guard let path = scriptPath(), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

// MARK: the rig: a temp KIT_ROOT, its own TMPDIR, hand-made files

private struct Rig {
    /// The temp folder that holds the kit root, the temp folder the script sees as TMPDIR and the markers file.
    let base: String
    var root: String { base + "/sesame-kit" }
    var tmp: String { base + "/tmp" }
    var evidence: String { root + "/evidence" }
    var lib: String { root + "/home/Library" }
    var sesame: String { lib + "/Application Support/Sesame" }
    var markersFile: String { base + "/markers.txt" }
    var env: [String: String] { ["KIT_ROOT": root, "TMPDIR": tmp] }
}

private func withRig<T>(_ body: (Rig) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qscan-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let rig = Rig(base: url.resolvingSymlinksInPath().path)
    for dir in [rig.root + "/run", rig.evidence, rig.tmp] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try (rig.evidence + "\n").write(toFile: rig.root + "/run/evidence-dir", atomically: true, encoding: .utf8)
    return try body(rig)
}

private func put(_ path: String, _ data: Data) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
}

private func put(_ path: String, _ text: String) throws {
    try put(path, Data(text.utf8))
}

/// Bytes that are no text: the marker between NULs and control bytes.
private func binary(_ marker: String) -> Data {
    Data([0, 1, 255, 0]) + Data(marker.utf8) + Data([0, 2, 10, 0])
}

/// Every path under the rig's base (files, links and folders), relative, sorted, without the kit's own `run/` and
/// `evidence/` folders (the script may write evidence; it must leave nothing else) and without the markers file the
/// test itself writes.
private func entries(_ rig: Rig) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: rig.base) else { return [] }
    var found: [String] = []
    for case let rel as String in walker {
        if rel == "markers.txt" { continue }
        if rel == "sesame-kit/run" || rel.hasPrefix("sesame-kit/run/") { continue }
        if rel == "sesame-kit/evidence" || rel.hasPrefix("sesame-kit/evidence/") { continue }
        found.append(rel)
    }
    return found.sorted()
}

/// Runs `query-scan` on the rig. A run without `--no-log` must come with hand-made `log` and `logger` programs first on
/// PATH: the real unified log is never written by a test.
private func scan(_ rig: Rig, markers: [String], noLog: Bool = true, extraEnv: [String: String] = [:], raw: String? = nil) throws -> Ran {
    guard let path = scriptPath() else { return Ran(status: -1, output: "") }
    if !noLog && extraEnv["PATH"] == nil {
        Issue.record("a query-scan run without --no-log needs the hand-made log and logger first on PATH")
        return Ran(status: -1, output: "")
    }
    try (raw ?? (markers.joined(separator: "\n") + "\n")).write(toFile: rig.markersFile, atomically: true, encoding: .utf8)
    var env = rig.env
    for (k, v) in extraEnv { env[k] = v }
    return try run(path, ["query-scan", rig.markersFile] + (noLog ? ["--no-log"] : []), env: env)
}

private let controlLabels = ["Application Support/Sesame", "Preferences", "Caches", "HTTPStorages", "Saved Application State", "Logs", "TMPDIR/Sesame-"]

private func passedControl(_ output: String, _ label: String) -> Bool {
    lines(output).contains { $0.hasPrefix("CONTROL ") && $0.contains(label) && !$0.contains("FAILED") }
}

private func failedControls(_ output: String) -> [String] {
    lines(output).filter { $0.contains("CONTROL") && $0.contains("FAILED") }
}

private func found(_ output: String) -> [String] {
    lines(output).filter { $0.hasPrefix("FOUND ") }
}

// MARK: hand-made log and logger (they never touch the real unified log)

private struct Shims {
    let bin: String
    let calls: String
    let fake: String
    var env: [String: String] {
        ["PATH": bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
    }
    var recorded: [String] {
        lines(read(calls) ?? "")
    }
}

/// `logger` appends its words to a fake log file; `log show` prints that file (a blind `log` prints nothing). Both
/// record every call, one line each.
private func withShims<T>(blind: Bool = false, _ body: (Shims) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qshim-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let dir = url.resolvingSymlinksInPath().path
    let shims = Shims(bin: dir + "/bin", calls: dir + "/calls.log", fake: dir + "/fake-log.txt")
    try FileManager.default.createDirectory(atPath: shims.bin, withIntermediateDirectories: true)
    let logger = "#!/bin/bash\nprintf 'logger %s\\n' \"$*\" >> '\(shims.calls)'\nprintf '%s\\n' \"$*\" >> '\(shims.fake)'\nexit 0\n"
    let show = blind ? "" : "if [ \"$1\" = show ]; then cat '\(shims.fake)' 2>/dev/null; fi\n"
    let log = "#!/bin/bash\nprintf 'log %s\\n' \"$*\" >> '\(shims.calls)'\n\(show)exit 0\n"
    for (name, text) in [("logger", logger), ("log", log)] {
        try text.write(toFile: shims.bin + "/" + name, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shims.bin + "/" + name)
    }
    return try body(shims)
}

// MARK: reading the script's text

private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\(\\) \\{$", options: .regularExpression) != nil {
                name = String(line.dropLast(4))
                body = []
            }
        } else if line == "}" {
            result[name!] = body.joined(separator: "\n")
            name = nil
        } else {
            body.append(line)
        }
    }
    return result
}

private func expanded(_ name: String, _ functions: [String: String], depth: Int = 0) -> String {
    guard depth < 5, let body = functions[name] else { return "" }
    var out: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        out.append(line)
        for other in functions.keys.sorted() where other != name {
            if has(line, "(^|[^A-Za-z0-9_.-])\(NSRegularExpression.escapedPattern(for: other))([^A-Za-z0-9_.-]|$)") {
                out.append(expanded(other, functions, depth: depth + 1))
            }
        }
    }
    return out.joined(separator: "\n")
}

private func dispatchTarget(_ mode: String, in text: String, functions: [String: String]) -> String? {
    let marker = "(^|[ \\t|(])\(NSRegularExpression.escapedPattern(for: mode))\\)"
    for line in text.split(separator: "\n").map(String.init) where has(line, marker) {
        let words = line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        if let target = words.last(where: { functions[$0] != nil }) { return target }
    }
    return nil
}

/// The code a mode runs, from its own dispatch line, with the functions it calls read in place.
private func modeCode(_ mode: String) -> String? {
    guard let text = scriptCode() else { return nil }
    let functions = shellFunctions(in: text)
    guard let handler = dispatchTarget(mode, in: text, functions: functions) else {
        Issue.record("the dispatch of kit-privacy.sh has no `\(mode))` line of its own calling a function (it is still `not built yet`)")
        return nil
    }
    return expanded(handler, functions)
}

// MARK: hand-made sqlite file (the system library)

private struct DBError: Error, CustomStringConvertible {
    let description: String
}

private func makeDB(_ path: String, _ statements: [String]) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw DBError(description: "cannot create \(path)")
    }
    defer { sqlite3_close(db) }
    for sql in statements {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DBError(description: "cannot run \(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}

// MARK: the hand-written tables

private struct PlaceCase: Sendable, CustomStringConvertible {
    let name: String
    /// Where the marker is put, relative to the rig's base.
    let path: String
    let asBinary: Bool
    var description: String { name }
}

private let placeCases: [PlaceCase] = [
    PlaceCase(name: "Sesame folder, a log", path: "sesame-kit/home/Library/Application Support/Sesame/logs/app.log", asBinary: false),
    PlaceCase(name: "Sesame folder, settings", path: "sesame-kit/home/Library/Application Support/Sesame/settings.json", asBinary: true),
    PlaceCase(name: "Preferences", path: "sesame-kit/home/Library/Preferences/app.test.Fake.plist", asBinary: true),
    PlaceCase(name: "Caches, nested", path: "sesame-kit/home/Library/Caches/app.test.Fake/fsCachedData/0A1B2C", asBinary: true),
    PlaceCase(name: "HTTPStorages", path: "sesame-kit/home/Library/HTTPStorages/app.test.Fake/httpstorages.sqlite", asBinary: true),
    PlaceCase(name: "Saved Application State", path: "sesame-kit/home/Library/Saved Application State/app.test.Fake.savedState/windows.plist", asBinary: true),
    PlaceCase(name: "Logs", path: "sesame-kit/home/Library/Logs/Sesame/app.log", asBinary: false),
    PlaceCase(name: "a scratch folder of $TMPDIR", path: "tmp/Sesame-4711/scratch.bin", asBinary: true),
    PlaceCase(name: "the mirror's request log", path: "sesame-kit/run/mirror-requests.log", asBinary: false),
]

private struct BadCall: Sendable, CustomStringConvertible {
    let args: [String]
    var description: String { args.isEmpty ? "(no arguments)" : args.joined(separator: " ") }
}

private let badCalls: [BadCall] = [
    BadCall(args: ["query-scan"]),
    BadCall(args: ["query-scan", "--no-log"]),
    BadCall(args: ["query-scan", "one", "two"]),
    BadCall(args: ["query-scan", "--sideways"]),
    BadCall(args: ["query-scan", "markers.txt", "--sideways"]),
    BadCall(args: ["prompts"]),
    BadCall(args: ["prompts", "frobnicate", "s8x"]),
    BadCall(args: ["prompts", "start"]),
    BadCall(args: ["prompts", "start", "a", "b"]),
    BadCall(args: ["prompts", "start", "a/b"]),
    BadCall(args: ["prompts", "stop"]),
    BadCall(args: ["prompts", "stop", "../x"]),
    BadCall(args: ["prompts", "result"]),
    BadCall(args: ["prompts", "result", "a", "b"]),
    BadCall(args: ["prompts", "parse"]),
    BadCall(args: ["prompts", "parse", "--sample"]),
    BadCall(args: ["prompts", "parse", "--sample", "a", "b"]),
    BadCall(args: ["prompts", "parse", "sample.txt"]),
]

private let dlgAuth = "SecurityAgent | Authentication | Enter your password to allow this change."
private let dlgFDA = "UserNotificationCenter | \"Sesame\" needs Full Disk Access | Sesame wants to read every file on this Mac. Turn on Full Disk Access for Sesame in System Settings."
private let dlgCamera = "UserNotificationCenter | \"Sesame\" Would Like to Access the Camera | Sesame wants to use the camera."
private let dlgMic = "UserNotificationCenter | \"Sesame\" Would Like to Access the Microphone | Sesame wants to use the microphone."
private let dlgFolder = "UserNotificationCenter | \"Sesame\" would like to access files in your Documents folder. | This app will be able to read files in your Documents folder."
private let dlgOtherCamera = "UserNotificationCenter | \"Terminal\" Would Like to Access the Camera | Terminal wants to use the camera."

private struct ParseCase: Sendable, CustomStringConvertible {
    let name: String
    let dump: [String]
    let exit: Int32
    let seen: Int
    /// A phrase of each dialog that names Sesame: it must be in the output (the text is kept).
    let kept: [String]
    var description: String { name }
}

private let parseCases: [ParseCase] = [
    ParseCase(name: "Sesame and Full Disk Access", dump: [dlgAuth, dlgFDA], exit: 1, seen: 1, kept: ["needs Full Disk Access"]),
    ParseCase(name: "Sesame and the camera", dump: [dlgCamera], exit: 1, seen: 1, kept: ["Access the Camera"]),
    ParseCase(name: "Sesame and the microphone", dump: [dlgMic], exit: 1, seen: 1, kept: ["Access the Microphone"]),
    ParseCase(name: "Sesame and a folder permission", dump: [dlgAuth, dlgFolder], exit: 0, seen: 1,
              kept: ["would like to access files in your Documents folder"]),
    ParseCase(name: "a folder permission and a camera dialog", dump: [dlgFolder, dlgCamera], exit: 1, seen: 2,
              kept: ["your Documents folder", "Access the Camera"]),
    ParseCase(name: "another app's camera dialog and an unrelated one", dump: [dlgOtherCamera, dlgAuth], exit: 0, seen: 0, kept: []),
    ParseCase(name: "an empty dump", dump: [], exit: 0, seen: 0, kept: []),
]

private struct ResultCase: Sendable, CustomStringConvertible {
    let name: String
    /// The saved file's text; nil when none is saved.
    let saved: String?
    let exit: Int32
    var description: String { name }
}

private let resultCases: [ResultCase] = [
    ResultCase(name: "exit=0", saved: "seen=0 exit=0\n", exit: 0),
    ResultCase(name: "exit=0 with dialogs seen", saved: "seen=2 exit=0\n", exit: 0),
    ResultCase(name: "exit=1", saved: "seen=1 exit=1\n", exit: 1),
    ResultCase(name: "no saved result", saved: nil, exit: 4),
    ResultCase(name: "a saved line that is no result", saved: "hello\n", exit: 4),
]

@Suite("KitPrivacyQueryScanTests")
struct KitPrivacyQueryScanTests {

    // MARK: the script, the usage, the dispatch

    @Test("bash -n finds no syntax error in kit-privacy.sh")
    func bashSyntax() throws {
        guard let path = scriptPath() else { return }
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n exited \(ran.status): \(ran.output)")
        #expect(ran.output.isEmpty, "bash -n printed: \(ran.output)")
    }

    @Test("the usage text names query-scan and prompts with their options")
    func usageNamesBoth() throws {
        guard let path = scriptPath() else { return }
        let ran = try withRig { rig in try run(path, [], env: rig.env) }
        #expect(ran.status == 2, "no mode exited \(ran.status), wanted 2: \(ran.output)")
        let usage = lines(ran.output).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in ["kit-privacy.sh query-scan <markers-file> [--no-log]",
                     "kit-privacy.sh prompts start <name> | stop <name> | result <name> | parse --sample <file>"] {
            #expect(usage.contains { $0.hasPrefix(line) }, "no usage line starts `\(line)`; the output was: \(ran.output)")
        }
    }

    @Test("each of the two modes has its own dispatch line and is no longer `not built yet`")
    func dispatchLines() throws {
        guard let text = scriptCode() else { return }
        let functions = shellFunctions(in: text)
        for mode in ["query-scan", "prompts"] {
            ok(dispatchTarget(mode, in: text, functions: functions) != nil,
               "the dispatch of kit-privacy.sh has no `\(mode))` line of its own calling a function")
        }
    }

    @Test("arguments that are missing or wrong are usage, exit 2, and nothing is written", arguments: badCalls)
    fileprivate func badArgumentsAreUsage(_ call: BadCall) throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            let before = entries(rig)
            let tmpBefore = try FileManager.default.contentsOfDirectory(atPath: rig.tmp)
            let ran = try run(path, call.args, env: rig.env)
            #expect(ran.status == 2, "kit-privacy.sh \(call) exited \(ran.status), wanted 2 (usage): \(ran.output)")
            #expect(ran.output.contains("usage: kit-privacy.sh "), "no usage text: \(ran.output)")
            #expect(entries(rig) == before, "files appeared under the kit root: \(Set(entries(rig)).subtracting(before).sorted())")
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.tmp) == tmpBefore, "files appeared in TMPDIR")
        }
    }

    @Test("neither mode asks for a password, watches the network or the files, or reads Sources/; query-scan scripts nothing")
    func modesStartNothing() throws {
        let observers = "(^|[^A-Za-z0-9_.-])(nettop|fs_usage)[ \\t]"
        let sudo = "(^|[^A-Za-z0-9_.-])sudo[ \\t]"
        if let body = modeCode("query-scan") {
            ok(!has(body, sudo), "query-scan uses sudo: it needs no administrator rights")
            ok(!has(body, observers), "query-scan starts an observer")
            ok(!has(body, "(^|[\\n;&|(])[ \\t]*(osascript|open)[ \\t]"), "query-scan starts an app or a script engine")
            ok(!body.contains("Sources"), "query-scan names Sources: the kit never reads the product's source")
        }
        if let body = modeCode("prompts") {
            ok(!has(body, sudo), "prompts uses sudo: it needs no administrator rights")
            ok(!has(body, observers), "prompts starts an observer")
            ok(!body.contains("Sources"), "prompts names Sources: the kit never reads the product's source")
        }
    }

    // MARK: query-scan, the controls

    @Test("the controls run first, one line per place, are saved to scan-controls.txt and leave nothing behind")
    func controlsFirstSavedAndRemoved() throws {
        try withRig { rig in
            try put(rig.sesame + "/settings.json", "{\"startPressed\":true}\n")
            try put(rig.sesame + "/logs/app.log", "event=started\n")
            try makeDB(rig.sesame + "/index.sqlite", ["CREATE TABLE files (id INTEGER)"])
            try put(rig.lib + "/Preferences/app.test.Other.plist", "plist\n")
            try put(rig.tmp + "/Sesame-9001/scratch.txt", "scratch\n")
            try put(rig.root + "/run/mirror-requests.log", "GET /model 200\n")
            let before = entries(rig)
            let tmpBefore = try FileManager.default.contentsOfDirectory(atPath: rig.tmp).sorted()
            let ran = try scan(rig, markers: ["qm-1-7", "qm-2-7"])
            #expect(ran.status == 0, "a clean tree exited \(ran.status), wanted 0: \(ran.output)")
            let all = lines(ran.output)
            for label in controlLabels {
                #expect(passedControl(ran.output, label), "no passed `CONTROL ... \(label)` line: \(ran.output)")
            }
            #expect(failedControls(ran.output).isEmpty, "a control failed: \(failedControls(ran.output))")
            let lastControl = all.lastIndex(where: { $0.hasPrefix("CONTROL ") })
            let verdict = all.firstIndex(where: { $0.contains("no marker found in") || $0.hasPrefix("FOUND ") })
            if let lastControl, let verdict {
                #expect(lastControl < verdict, "the verdict is printed before the controls are finished")
            } else {
                Issue.record("the output has no control line or no verdict line: \(ran.output)")
            }
            let controls = read(rig.evidence + "/scan-controls.txt")
            #expect(controls != nil, "no scan-controls.txt in the evidence folder")
            for label in controlLabels {
                #expect(passedControl(controls ?? "", label), "scan-controls.txt has no passed control line for \(label)")
            }
            #expect((controls ?? "").contains("qm-control-"), "scan-controls.txt never names the control marker `qm-control-<random>`")
            for line in lines(controls ?? "").filter({ $0.hasPrefix("CONTROL ") && !$0.contains("FAILED") }) {
                #expect(line.contains("unplanted"), "a passed control line does not say an unplanted marker was not found: \(line)")
            }
            #expect(!(try String(contentsOfFile: rig.markersFile, encoding: .utf8)).contains("qm-control-"), "the control marker is in the markers file")
            #expect(entries(rig) == before, "the scan left files or folders behind: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.tmp).sorted() == tmpBefore,
                    "the scan left something in TMPDIR (a control folder or a temporary file)")
            let layout = try run(scriptPath() ?? "", ["layout"], env: rig.env)
            #expect(layout.status == 0, "layout after the scan exited \(layout.status), wanted 0: \(layout.output)")
            #expect(layout.output.contains("LAYOUT OK"), "layout reports something unexpected after the scan: \(layout.output)")
            #expect(!layout.output.contains("UNEXPECTED"), "layout reports UNEXPECTED after the scan: \(layout.output)")
        }
    }

    @Test("with no home at all the controls make their folders and remove every one again")
    func controlsMakeAndRemoveFolders() throws {
        try withRig { rig in
            let before = entries(rig)
            #expect(!FileManager.default.fileExists(atPath: rig.root + "/home"), "the rig made a home")
            let ran = try scan(rig, markers: ["qm-1-7"])
            #expect(ran.status == 0, "exited \(ran.status), wanted 0: \(ran.output)")
            for label in controlLabels {
                #expect(passedControl(ran.output, label), "no passed `CONTROL ... \(label)` line: \(ran.output)")
            }
            #expect(entries(rig) == before, "the controls left files or folders behind: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.tmp).isEmpty, "the controls left something in TMPDIR")
        }
    }

    @Test("a place that cannot hold a control file is exit 4 naming it, with no marker line, and nothing is left behind")
    func controlFailsForAPlaceThatCannotBeWritten() throws {
        try withRig { rig in
            try put(rig.lib + "/Caches", "this is a regular file where the Caches folder should be\n")
            try put(rig.sesame + "/logs/app.log", "qm-1-7 is here but the scan must not run\n")
            let before = entries(rig)
            let ran = try scan(rig, markers: ["qm-1-7"])
            #expect(ran.status == 4, "an unwritable place exited \(ran.status), wanted 4: \(ran.output)")
            let failed = failedControls(ran.output)
            #expect(failed.count == 1 && failed[0].contains("Caches"), "wanted exactly one failed control, naming Caches: \(failed)")
            #expect(ran.output.contains("not valid"), "no `not valid` line: \(ran.output)")
            #expect(found(ran.output).isEmpty, "a marker was reported after a failed control: \(ran.output)")
            #expect(!ran.output.contains("no marker found in"), "a clean line was printed after a failed control: \(ran.output)")
            #expect(entries(rig) == before, "the controls left files behind: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            #expect(read(rig.evidence + "/scan-controls.txt") != nil, "a failed control is still saved to scan-controls.txt")
        }
    }

    @Test("a folder that cannot be written is a failed control too")
    func controlFailsForAReadOnlyFolder() throws {
        try withRig { rig in
            let prefs = rig.lib + "/Preferences"
            try put(prefs + "/app.test.Other.plist", "plist\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: prefs)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefs) }
            let before = entries(rig)
            let ran = try scan(rig, markers: ["qm-1-7"])
            #expect(ran.status == 4, "a read-only Preferences folder exited \(ran.status), wanted 4: \(ran.output)")
            let failed = failedControls(ran.output)
            #expect(failed.count == 1 && failed[0].contains("Preferences"), "wanted exactly one failed control, naming Preferences: \(failed)")
            #expect(entries(rig) == before, "the controls left files behind: \(Set(entries(rig)).symmetricDifference(before).sorted())")
        }
    }

    // MARK: query-scan, the scan

    @Test("a marker put in each place is found, with its file, and exit 1", arguments: placeCases)
    fileprivate func markerFoundInPlace(_ place: PlaceCase) throws {
        try withRig { rig in
            let marker = "qm-31-9137"
            let file = rig.base + "/" + place.path
            if place.asBinary {
                try put(file, binary(marker))
            } else {
                try put(file, "2026-10-26 10:00:00 event=searched text=\(marker) more\n")
            }
            try put(rig.sesame + "/logs/index.log", "event=walk files=12\n")
            let ran = try scan(rig, markers: ["qm-30-9137", marker, "qm-32-9137"])
            #expect(ran.status == 1, "a marker in \(place) exited \(ran.status), wanted 1: \(ran.output)")
            #expect(found(ran.output) == ["FOUND \(marker) in \(file)"], "wanted exactly `FOUND \(marker) in \(file)`, got: \(found(ran.output))")
            let all = lines(ran.output)
            if let lastControl = all.lastIndex(where: { $0.hasPrefix("CONTROL ") }), let firstFound = all.firstIndex(where: { $0.hasPrefix("FOUND ") }) {
                #expect(lastControl < firstFound, "a finding is printed before the controls are finished")
            }
            #expect(read(rig.evidence + "/scan-controls.txt") != nil, "no scan-controls.txt after a scan that found a marker")
        }
    }

    @Test("a marker inside the bytes of a real sqlite index is found")
    func markerFoundInSqliteBytes() throws {
        try withRig { rig in
            let marker = "qm-7-5521"
            try makeDB(rig.sesame + "/index.sqlite", [
                "CREATE TABLE files (id INTEGER PRIMARY KEY, name TEXT)",
                "INSERT INTO files (name) VALUES ('holiday.jpg')",
                "INSERT INTO files (name) VALUES ('notes \(marker) holiday')",
            ])
            let ran = try scan(rig, markers: [marker])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            #expect(found(ran.output) == ["FOUND \(marker) in \(rig.sesame)/index.sqlite"], "wanted the index named, got: \(found(ran.output))")
        }
    }

    @Test("two markers in one file and one marker in two files are each reported")
    func everyMarkerAndFileIsReported() throws {
        try withRig { rig in
            let a = rig.sesame + "/logs/app.log"
            let b = rig.lib + "/Logs/Sesame/crash.log"
            try put(a, "x qm-1-808 y qm-2-808 z\n")
            try put(b, binary("qm-1-808"))
            let ran = try scan(rig, markers: ["qm-1-808", "qm-2-808", "qm-3-808"])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            let got = Set(found(ran.output))
            #expect(got == ["FOUND qm-1-808 in \(a)", "FOUND qm-2-808 in \(a)", "FOUND qm-1-808 in \(b)"], "wrong findings: \(got.sorted())")
        }
    }

    @Test("a clean tree is exit 0 and `no marker found in 8 places`; near misses, other folders and file names with spaces change nothing")
    func cleanTree() throws {
        try withRig { rig in
            try put(rig.sesame + "/logs/app.log", "event=started\nevent=search_done count=12\nqm-51-4242 is not a marker of this run\n")
            try put(rig.sesame + "/models/note.txt", "model files live here\n")
            try put(rig.lib + "/Preferences/with space.plist", "qm-0-4242\n")
            try put(rig.lib + "/Caches/app.test.Fake/a b/c d.bin", binary("qm-0-4242"))
            try put(rig.tmp + "/Sesame-77/x y.txt", "nothing\n")
            // outside the places: the picked folders and other apps are not scanned
            try put(rig.root + "/home/Documents/picked/photo-notes.txt", "qm-3-4242\n")
            try put(rig.lib + "/Application Support/Other/state.json", "qm-3-4242\n")
            try put(rig.tmp + "/Other-1/scratch.txt", "qm-3-4242\n")
            let markers = (1...50).map { "qm-\($0)-4242" }
            // blank lines and CRLF line ends in the markers file
            let raw = markers.joined(separator: "\r\n") + "\r\n\r\n\n"
            let ran = try scan(rig, markers: markers, raw: raw)
            #expect(ran.status == 0, "a clean tree exited \(ran.status), wanted 0: \(ran.output)")
            #expect(ran.output.contains("no marker found in 8 places"), "no `no marker found in 8 places` line: \(ran.output)")
            #expect(found(ran.output).isEmpty, "a marker was reported: \(found(ran.output))")
        }
    }

    @Test("markers are fixed strings, not patterns")
    func markersAreFixedStrings() throws {
        try withRig { rig in
            try put(rig.sesame + "/logs/app.log", "qmX1X7 is a different word\n")
            let first = try scan(rig, markers: ["qm.1.7"])
            #expect(first.status == 0, "a marker with dots matched other text, exit \(first.status): \(first.output)")
            try put(rig.sesame + "/logs/app.log", "qmX1X7 and qm.1.7 together\n")
            let second = try scan(rig, markers: ["qm.1.7"])
            #expect(second.status == 1, "the literal marker was not found, exit \(second.status): \(second.output)")
            #expect(found(second.output) == ["FOUND qm.1.7 in \(rig.sesame)/logs/app.log"], "wrong findings: \(found(second.output))")
        }
    }

    @Test("a missing markers file, or one with no marker in it, is exit 4 not valid and runs no control")
    func markersFileErrors() throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            try put(rig.sesame + "/logs/app.log", "event=started\n")
            let before = entries(rig)
            let missing = try run(path, ["query-scan", rig.base + "/no-such-markers.txt", "--no-log"], env: rig.env)
            #expect(missing.status == 4, "a missing markers file exited \(missing.status), wanted 4: \(missing.output)")
            #expect(missing.output.contains("not valid"), "no `not valid` line: \(missing.output)")
            let empty = try scan(rig, markers: [], raw: "\n\r\n  \n")
            #expect(empty.status == 4, "a markers file with no marker exited \(empty.status), wanted 4: \(empty.output)")
            #expect(empty.output.contains("not valid"), "no `not valid` line: \(empty.output)")
            #expect(entries(rig) == before, "files appeared: \(Set(entries(rig)).symmetricDifference(before).sorted())")
        }
    }

    // MARK: query-scan, the unified log (hand-made log and logger; the real log is never touched)

    @Test("the unified log: a logger line is the control, `log show` is read with a Sesame predicate, a marker there is found")
    func unifiedLogScan() throws {
        try withRig { rig in
            try withShims { shims in
                try put(shims.fake, "2026-10-26 10:00:00.000 Df Sesame[4242:1a2b] [app.sesame] event=search_done n=3\n")
                let clean = try scan(rig, markers: ["qm-4-1"], noLog: false, extraEnv: shims.env)
                #expect(clean.status == 0, "a clean log exited \(clean.status), wanted 0: \(clean.output)")
                #expect(passedControl(clean.output, "unified log"), "no passed `CONTROL ... unified log` line: \(clean.output)")
                #expect(lines(clean.output).contains { $0.hasPrefix("CONTROL ") && $0.contains("unified log") && $0.contains("not prove") },
                        "the log control does not say it proves `log show` and the match, not the predicate: \(clean.output)")
                #expect(clean.output.contains("no marker found in 9 places"), "no `no marker found in 9 places` line: \(clean.output)")
                let calls = shims.recorded
                #expect(calls.contains { $0.hasPrefix("logger ") && $0.contains("qm-control-") }, "no logger call carries the control marker: \(calls)")
                #expect(calls.contains { $0.hasPrefix("log show") && $0.contains("Sesame") },
                        "no `log show` call names Sesame (a predicate on the process name prefix): \(calls)")
                try put(shims.fake, "2026-10-26 10:00:00.000 Df Sesame[4242:1a2b] [app.sesame] searched qm-4-1 for things\n")
                let hit = try scan(rig, markers: ["qm-4-1", "qm-5-1"], noLog: false, extraEnv: shims.env)
                #expect(hit.status == 1, "a marker in the log exited \(hit.status), wanted 1: \(hit.output)")
                #expect(found(hit.output) == ["FOUND qm-4-1 in unified log"], "wanted `FOUND qm-4-1 in unified log`, got: \(found(hit.output))")
            }
        }
    }

    @Test("--no-log never calls log or logger and says 8 places")
    func noLogCallsNothing() throws {
        try withRig { rig in
            try withShims { shims in
                let ran = try scan(rig, markers: ["qm-4-1"], noLog: true, extraEnv: shims.env)
                #expect(ran.status == 0, "exited \(ran.status), wanted 0: \(ran.output)")
                #expect(shims.recorded.isEmpty, "--no-log called log or logger: \(shims.recorded)")
                #expect(ran.output.contains("no marker found in 8 places"), "no `no marker found in 8 places` line: \(ran.output)")
            }
        }
    }

    @Test("a log that cannot show the control line is exit 4 naming the unified log, and nothing is left behind")
    func blindLogIsExit4() throws {
        try withRig { rig in
            try withShims(blind: true) { shims in
                try put(rig.sesame + "/logs/app.log", "event=started\n")
                let before = entries(rig)
                let ran = try scan(rig, markers: ["qm-4-1"], noLog: false, extraEnv: shims.env)
                #expect(ran.status == 4, "a blind log exited \(ran.status), wanted 4: \(ran.output)")
                let failed = failedControls(ran.output)
                #expect(failed.count == 1 && failed[0].contains("unified log"), "wanted exactly one failed control, naming the unified log: \(failed)")
                #expect(ran.output.contains("not valid"), "no `not valid` line: \(ran.output)")
                #expect(found(ran.output).isEmpty && !ran.output.contains("no marker found in"), "a verdict was printed after a failed control: \(ran.output)")
                #expect(entries(rig) == before, "the controls left files behind: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            }
        }
    }

    @Test("query-scan names the unified log programs, the Sesame predicate and --no-log in its code")
    func queryScanLogText() throws {
        guard let body = modeCode("query-scan") else { return }
        ok(has(body, "(^|[^A-Za-z0-9_.-])logger[ \\t]"), "query-scan never runs `logger`")
        ok(has(body, "(^|[^A-Za-z0-9_.-])log[ \\t]+show\\b"), "query-scan never runs `log show`")
        ok(has(body, "(?i)--predicate[^\\n]*beginswith[^\\n]*Sesame"), "query-scan has no `--predicate` on the process name prefix Sesame")
        ok(body.contains("--no-log"), "query-scan has no --no-log option")
    }

    // MARK: prompts, parse

    @Test("parse --sample: lines naming Sesame are kept, a Full Disk Access, camera or microphone dialog fails, the last line is the result",
          arguments: parseCases)
    fileprivate func parseSample(_ c: ParseCase) throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            let sample = rig.base + "/sample.txt"
            try put(sample, c.dump.isEmpty ? "" : c.dump.joined(separator: "\n") + "\n")
            let before = entries(rig)
            let ran = try run(path, ["prompts", "parse", "--sample", sample], env: rig.env)
            #expect(ran.status == c.exit, "\(c) exited \(ran.status), wanted \(c.exit): \(ran.output)")
            #expect(lines(ran.output).contains("seen=\(c.seen) exit=\(c.exit)"), "no `seen=\(c.seen) exit=\(c.exit)` line: \(ran.output)")
            for phrase in c.kept {
                #expect(ran.output.contains(phrase), "the text of the dialog was not kept (`\(phrase)`): \(ran.output)")
            }
            if c.seen == 0 {
                #expect(ran.output.contains("no dialog named Sesame seen"), "no `no dialog named Sesame seen` line: \(ran.output)")
                #expect(!ran.output.contains("Terminal"), "a dialog that does not name Sesame was kept: \(ran.output)")
            }
            #expect(entries(rig) == before, "parse wrote files: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            #expect(!FileManager.default.fileExists(atPath: rig.root + "/run/prompts"), "parse made run/prompts: it only reads the sample")
        }
    }

    @Test("parse --sample of a file that does not exist is exit 4 not valid")
    func parseMissingSample() throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            let ran = try run(path, ["prompts", "parse", "--sample", rig.base + "/no-such-dump.txt"], env: rig.env)
            #expect(ran.status == 4, "exited \(ran.status), wanted 4: \(ran.output)")
            #expect(ran.output.contains("not valid"), "no `not valid` line: \(ran.output)")
        }
    }

    // MARK: prompts, result

    @Test("result reads only the saved line: exit 0 or 1 from it, exit 4 when there is none", arguments: resultCases)
    fileprivate func resultReadsSavedLine(_ c: ResultCase) throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            let file = rig.root + "/run/prompts/s8x.result"
            if let saved = c.saved { try put(file, saved) }
            let before = entries(rig)
            let tmpBefore = try FileManager.default.contentsOfDirectory(atPath: rig.tmp)
            let ran = try run(path, ["prompts", "result", "s8x"], env: rig.env)
            #expect(ran.status == c.exit, "\(c) exited \(ran.status), wanted \(c.exit): \(ran.output)")
            if c.exit == 4 {
                if c.saved == nil {
                    #expect(ran.output.contains("not valid: no prompts result s8x"), "no `not valid: no prompts result s8x` line: \(ran.output)")
                } else {
                    #expect(ran.output.contains("not valid"), "no `not valid` line: \(ran.output)")
                }
            } else if let saved = c.saved {
                #expect(ran.output.contains(saved.trimmingCharacters(in: .whitespacesAndNewlines)), "the saved line is not shown: \(ran.output)")
            }
            #expect(entries(rig) == before, "result wrote files: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.tmp) == tmpBefore, "result left something in TMPDIR")
            if let saved = c.saved { #expect(read(file) == saved, "result changed the saved file") }
        }
    }

    // MARK: prompts, stop

    @Test("stop with no watcher is exit 4 `not valid: no prompts watcher <name> was running`, and starts and writes nothing")
    func stopWithoutStart() throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            let before = entries(rig)
            let ran = try run(path, ["prompts", "stop", "s8x"], env: rig.env)
            #expect(ran.status == 4, "exited \(ran.status), wanted 4: \(ran.output)")
            #expect(ran.output.contains("not valid: no prompts watcher s8x was running"), "no `not valid: no prompts watcher s8x was running` line: \(ran.output)")
            #expect(entries(rig) == before, "files appeared: \(Set(entries(rig)).symmetricDifference(before).sorted())")
            #expect(!FileManager.default.fileExists(atPath: rig.root + "/run/prompts/s8x.result"), "a result was saved for a watcher that never ran")
        }
    }

    private func deadPid() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    @Test("stop of a watcher that has already ended saves prompts.txt and the result, removes the pid file and exits as the result says",
          arguments: [
            ParseCase(name: "Full Disk Access", dump: [dlgAuth, dlgFDA], exit: 1, seen: 1, kept: ["needs Full Disk Access"]),
            ParseCase(name: "a folder permission", dump: [dlgFolder], exit: 0, seen: 1, kept: ["your Documents folder"]),
            ParseCase(name: "nothing seen", dump: [], exit: 0, seen: 0, kept: []),
          ])
    fileprivate func stopSavesResult(_ c: ParseCase) throws {
        guard let path = scriptPath() else { return }
        try withRig { rig in
            let pidFile = rig.root + "/run/pids/prompts-w1.pid"
            try put(pidFile, "\(try deadPid())\n")
            if !c.dump.isEmpty { try put(rig.root + "/run/prompts/w1.windows", c.dump.joined(separator: "\n") + "\n") }
            let ran = try run(path, ["prompts", "stop", "w1"], env: rig.env)
            #expect(ran.status == c.exit, "\(c) exited \(ran.status), wanted \(c.exit): \(ran.output)")
            #expect(!FileManager.default.fileExists(atPath: pidFile), "the pid file is still there: the poller would never end")
            let saved = (read(rig.root + "/run/prompts/w1.result") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(saved == "seen=\(c.seen) exit=\(c.exit)", "run/prompts/w1.result holds `\(saved)`, wanted `seen=\(c.seen) exit=\(c.exit)`")
            let kept = read(rig.evidence + "/prompts.txt")
            #expect(kept != nil, "no prompts.txt in the evidence folder")
            for phrase in c.kept { #expect((kept ?? "").contains(phrase), "prompts.txt does not hold the dialog text `\(phrase)`") }
            if c.seen == 0 { #expect(ran.output.contains("no dialog named Sesame seen"), "no `no dialog named Sesame seen` line: \(ran.output)") }
            let again = try run(path, ["prompts", "result", "w1"], env: rig.env)
            #expect(again.status == c.exit, "result after stop exited \(again.status), wanted \(c.exit): \(again.output)")
            let twice = try run(path, ["prompts", "stop", "w1"], env: rig.env)
            #expect(twice.status == 4, "a second stop exited \(twice.status), wanted 4 (no watcher is running): \(twice.output)")
            #expect((read(rig.root + "/run/prompts/w1.result") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == saved, "a second stop changed the saved result")
        }
    }

    // MARK: prompts, start and the running part of stop: text only (they use osascript)

    @Test("start: a poller that asks the system dialog processes for their windows once a second and ends when its pid file is gone")
    func startText() throws {
        guard let code = scriptCode(), let body = modeCode("prompts") else { return }
        ok(has(code, "run/pids"), "the kit's pid folder run/pids is named nowhere in kit-privacy.sh")
        ok(has(code, "prompts-[^\\n]*\\.pid"), "no pid file `prompts-<name>.pid` is named")
        ok(has(body, "(^|[^A-Za-z0-9_.-])osascript\\b"), "start never calls osascript (the window list of the dialog processes)")
        ok(has(body, "System Events"), "start never asks System Events for the windows")
        ok(["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent"].contains { body.contains($0) },
           "start names none of the system dialog processes (UserNotificationCenter, CoreServicesUIAgent, SecurityAgent)")
        ok(has(body, "\\bsleep[ \\t]+1\\b"), "the poller does not wait one second between polls")
        ok(has(body, "while[^\\n]*\\[[ \\t]+-[fe][ \\t]"), "the poller has no loop that runs only while its pid file exists")
        ok(has(body, "</dev/null"), "the background poller keeps the script's input (it would hold the caller's pipe open)")
        ok(has(body, "\\.windows"), "the poller keeps its lines in no `<name>.windows` file")
        ok(has(body, "(?i)sesame"), "the poller never looks for Sesame in the window text")
    }

    @Test("stop: removes the pid file, ends the poller only if ps shows it is ours, saves the result line")
    func stopText() throws {
        guard let body = modeCode("prompts") else { return }
        ok(has(body, "rm[ \\t]+-f[^\\n]*(pid|PID)"), "stop never removes the pid file")
        ok(has(body, "(^|[^A-Za-z0-9_.-])ps[ \\t]"), "stop kills a recorded pid without looking at it with ps first")
        ok(has(body, "(^|[^A-Za-z0-9_.-])kill[ \\t]"), "stop never ends a poller that does not leave by itself")
        ok(has(body, "seen=[^\\n]*exit="), "the result line `seen=<n> exit=<0|1>` is written nowhere")
        ok(has(body, "\\.result"), "the result is saved to no `<name>.result` file")
        ok(body.contains("not valid: no prompts watcher"), "stop has no `not valid: no prompts watcher <name> was running` line")
        ok(body.contains("not valid: no prompts result"), "result has no `not valid: no prompts result <name>` line")
        ok(has(body, "save_named[ \\t]+prompts\\b|prompts\\.txt"), "stop never saves prompts.txt")
    }
}

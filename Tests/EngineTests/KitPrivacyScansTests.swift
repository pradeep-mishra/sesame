import Foundation
import SQLite3
import Testing
import SesameEngine

// plan-3-t5, tester step: `scripts/kit-privacy.sh schema-scan` and `tcc` (S8.9 the schema part, S8.10 the tcc part).
// Written from the plan-3-t5 entry, verify.md, the S8 feature map and the kit as it stands; no product source is read
// and neither mode reads `Sources/`. The one product symbol used is `IndexStore`, to make a database with the real
// schema (the entry asks for it); every other database is made here by hand with the system SQLite library.
//
// Nothing here opens the real permission database, runs nettop or fs_usage, asks for a password or launches an app.
// Every run is a child process of the script with a temp KIT_ROOT (a folder named sesame-kit*), a hand-made sqlite file
// and `--db`. Expected values are written here by hand from the entry; none comes from the code under test.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - Output of `schema-scan`: first the control, as lines that start `CONTROL` and hold the five strings
//     `forbidden: search_count`, `forbidden: last_opened`, `forbidden: lastOpened`, `forbidden: history`,
//     `allowed: page_count`, and a line `CONTROL schema-scan OK`; then one line per table and column name of the target,
//     `forbidden: <name>` or `allowed: <name>` (the line starts with the verdict, so a clean target has no line that
//     starts `forbidden:`). The same lines of the target, and only those, are saved to `schema.txt` in the evidence folder
//     (the folder named by `run/evidence-dir`).
//   - `schema-scan` without `--db` reads `$KIT_ROOT/home/Library/Application Support/Sesame/index.sqlite`. A target that
//     does not exist is exit 4 `not valid`. A control that does not hold is exit 4 `not valid`, and then no target line
//     is printed.
//   - `tcc [--db <file>]... [--identifier <id>]`: `--db` may repeat (each file is one permission database; without
//     `--db` the user and the system databases are read); the identifier defaults to the one in
//     `$KIT_ROOT/apps/Sesame.app/Contents/Info.plist`. The control prints a line `CONTROL tcc OK` before the verdict.
//     A client matches the identifier exactly. Only rows with `auth_value` 2 are used here (what a granted permission
//     looks like); the denied value is not pinned by the entry and is not tested.
//   - Every call of `sqlite3` that touches a target file carries `-readonly` (and, for `tcc`, `-safe`); the test proves it
//     with a logging `sqlite3` placed first on PATH, which also proves that no path under `com.apple.TCC` is opened.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitscan-out-" + UUID().uuidString)
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

/// A fresh, empty KIT_ROOT (the kit requires a folder named sesame-kit*), removed afterwards.
private func withKitRoot<T>(_ body: (String) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-kit-privscans-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url.resolvingSymlinksInPath().path)
}

/// A KIT_ROOT with a recorded evidence folder (`run/evidence-dir`), so `schema.txt` can be read back.
private func withScanRoot<T>(_ body: (_ root: String, _ evidence: String) throws -> T) throws -> T {
    try withKitRoot { root in
        let evidence = root + "/evidence"
        try FileManager.default.createDirectory(atPath: root + "/run", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
        try (evidence + "\n").write(toFile: root + "/run/evidence-dir", atomically: true, encoding: .utf8)
        return try body(root, evidence)
    }
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
    return found.sorted()
}

private func anyHolds(_ list: [String], _ needle: String) -> Bool {
    list.contains(where: { $0.range(of: needle) != nil })
}

private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// The target verdict lines of an output: the lines that start `forbidden: ` or `allowed: `.
private func verdicts(_ text: String) -> (forbidden: Set<String>, allowed: Set<String>) {
    var forbidden = Set<String>()
    var allowed = Set<String>()
    for line in lines(text) {
        if line.hasPrefix("forbidden: ") {
            forbidden.insert(String(line.dropFirst("forbidden: ".count)).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("allowed: ") {
            allowed.insert(String(line.dropFirst("allowed: ".count)).trimmingCharacters(in: .whitespaces))
        }
    }
    return (forbidden, allowed)
}

// MARK: hand-made sqlite files (the system library, not the product)

private struct DBError: Error, CustomStringConvertible {
    let description: String
}

private func makeDB(_ path: String, _ statements: [String]) throws {
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

private func quoted(_ name: String) -> String { "\"" + name + "\"" }

/// One table holding the given column names (all INTEGER).
private func makeNamesDB(_ path: String, table: String, columns: [String]) throws {
    let cols = columns.map { quoted($0) + " INTEGER" }.joined(separator: ", ")
    try makeDB(path, ["CREATE TABLE \(quoted(table)) (\(cols))"])
}

/// A permission database with the four columns of the entry. Each row is (service, client).
private func makeTCC(_ path: String, rows: [(service: String, client: String)]) throws {
    var sql = ["CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, auth_value INTEGER NOT NULL, last_modified INTEGER NOT NULL)"]
    for row in rows {
        sql.append("INSERT INTO access VALUES ('\(row.service)', '\(row.client)', 2, 1700000000)")
    }
    try makeDB(path, sql)
}

// MARK: shims placed first on PATH

/// A folder holding a `sqlite3` that logs its arguments, one line per call, then runs the system one.
private func makeLoggingShim(in dir: String) throws -> (path: String, log: String) {
    let bin = dir + "/shim-logging"
    let log = dir + "/sqlite3-calls.log"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    let script = "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(log)'\nexec /usr/bin/sqlite3 \"$@\"\n"
    try script.write(toFile: bin + "/sqlite3", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/sqlite3")
    return (bin, log)
}

/// A folder holding a `sqlite3` that prints nothing and succeeds: a parser that cannot see anything.
private func makeBlindShim(in dir: String) throws -> String {
    let bin = dir + "/shim-blind"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try "#!/bin/bash\nexit 0\n".write(toFile: bin + "/sqlite3", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/sqlite3")
    return bin
}

private func pathEnv(prepending dir: String) -> [String: String] {
    ["PATH": dir + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
}

private func calls(_ log: String) -> [String] {
    ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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

// MARK: the hand-written tables of the entry

private struct NameCase: Sendable, CustomStringConvertible {
    let name: String
    let forbidden: Bool
    var description: String { name }
}

/// 22 names with their verdicts, written by hand from the entry: eighteen of the entry's and four more of the
/// tester's choosing (`query_text`, `boostFactor`, `line_count`, `countWindow`).
private let nameTable: [NameCase] = [
    NameCase(name: "count", forbidden: true),
    NameCase(name: "counts", forbidden: true),
    NameCase(name: "file_count", forbidden: true),
    NameCase(name: "page_count", forbidden: false),
    NameCase(name: "chunk_count", forbidden: false),
    NameCase(name: "frame_count", forbidden: false),
    NameCase(name: "lastOpened", forbidden: true),
    NameCase(name: "opened_at", forbidden: true),
    NameCase(name: "hit_rate", forbidden: true),
    NameCase(name: "recent_files", forbidden: true),
    NameCase(name: "openness", forbidden: false),
    NameCase(name: "mtime_ns", forbidden: false),
    NameCase(name: "tries", forbidden: false),
    NameCase(name: "vector_source", forbidden: false),
    NameCase(name: "walk_done_at", forbidden: false),
    NameCase(name: "read_to", forbidden: false),
    NameCase(name: "startPressed", forbidden: false),
    NameCase(name: "reason", forbidden: false),
    NameCase(name: "query_text", forbidden: true),
    NameCase(name: "boostFactor", forbidden: true),
    NameCase(name: "line_count", forbidden: false),
    NameCase(name: "countWindow", forbidden: false),
]

/// The words that make a name forbidden, from the entry.
private let forbiddenWords = ["query", "queries", "history", "recent", "open", "opens", "opened", "hit", "hits",
                              "visits", "usage", "popularity", "boost"]
/// The words that make `count` or `counts` harmless, from the entry.
private let exemptWords = ["page", "pages", "line", "lines", "chunk", "chunks", "passage", "passages", "frame", "frames", "window"]

private let privacyIdentifier = "app.test.Fake7421"

/// The hand-made Info.plist the `tcc` mode reads its identifier from.
private func writeBundle(_ root: String, identifier: String = privacyIdentifier) throws {
    let dir = root + "/apps/Sesame.app/Contents"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>\(identifier)</string></dict></plist>\n"
    try plist.write(toFile: dir + "/Info.plist", atomically: true, encoding: .utf8)
}

private struct BadCall: Sendable, CustomStringConvertible {
    let args: [String]
    var description: String { args.joined(separator: " ") }
}

private let badCalls: [BadCall] = [
    BadCall(args: ["schema-scan", "--sideways"]),
    BadCall(args: ["schema-scan", "--db"]),
    BadCall(args: ["schema-scan", "extra"]),
    BadCall(args: ["tcc", "--sideways"]),
    BadCall(args: ["tcc", "--db"]),
    BadCall(args: ["tcc", "--identifier"]),
    BadCall(args: ["tcc", "extra"]),
]

@Suite("KitPrivacyScansTests")
struct KitPrivacyScansTests {

    // MARK: the script, the usage, the dispatch

    @Test("bash -n finds no syntax error in kit-privacy.sh")
    func bashSyntax() throws {
        guard let path = scriptPath() else { return }
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n exited \(ran.status): \(ran.output)")
        #expect(ran.output.isEmpty, "bash -n printed: \(ran.output)")
    }

    @Test("the usage text names schema-scan and tcc with their options")
    func usageNamesBoth() throws {
        guard let path = scriptPath() else { return }
        let ran = try withKitRoot { root in try run(path, [], env: ["KIT_ROOT": root]) }
        #expect(ran.status == 2, "no mode exited \(ran.status), wanted 2: \(ran.output)")
        let usage = ran.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in ["kit-privacy.sh schema-scan [--db <file>]", "kit-privacy.sh tcc [--db <file>] [--identifier <id>]"] {
            #expect(usage.contains { $0.hasPrefix(line) }, "no usage line starts `\(line)`; the output was: \(ran.output)")
        }
    }

    @Test("each of the two modes has its own dispatch line and is no longer `not built yet`")
    func dispatchLines() throws {
        guard let text = scriptCode() else { return }
        let functions = shellFunctions(in: text)
        for mode in ["schema-scan", "tcc"] {
            ok(dispatchTarget(mode, in: text, functions: functions) != nil,
               "the dispatch of kit-privacy.sh has no `\(mode))` line of its own calling a function")
        }
    }

    @Test("arguments that are missing or wrong are usage, exit 2, and nothing is written", arguments: badCalls)
    fileprivate func badArgumentsAreUsage(_ call: BadCall) throws {
        guard let path = scriptPath() else { return }
        let (ran, files) = try withKitRoot { root -> (Ran, [String]) in
            let ran = try run(path, call.args, env: ["KIT_ROOT": root])
            return (ran, filesUnder(root))
        }
        #expect(ran.status == 2, "kit-privacy.sh \(call) exited \(ran.status), wanted 2 (usage): \(ran.output)")
        #expect(ran.output.contains("usage: kit-privacy.sh "), "no usage text: \(ran.output)")
        #expect(files.isEmpty, "files were written under KIT_ROOT before the arguments were checked: \(files)")
    }

    @Test("neither mode asks for a password, watches the system or starts an app")
    func modesStartNothing() throws {
        for mode in ["schema-scan", "tcc"] {
            guard let body = modeCode(mode) else { continue }
            ok(!has(body, "(^|[^A-Za-z0-9_.-])sudo[ \\t]"), "\(mode) uses sudo: it needs no administrator rights")
            ok(!has(body, "(^|[^A-Za-z0-9_.-])(nettop|fs_usage|osascript|open)[ \\t]"), "\(mode) starts an observer, an app or a script engine")
            ok(!body.contains("Sources"), "\(mode) names Sources: the kit never reads the product's source")
        }
    }

    // MARK: schema-scan, the control

    @Test("schema-scan prints its control first: the five hand-written names get their verdicts, then the target")
    func schemaControlFirst() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, _ in
            let db = root + "/target.sqlite"
            try makeNamesDB(db, table: "names_table", columns: ["history", "page_count"])
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root])
            let all = lines(ran.output)
            let control = all.filter { $0.hasPrefix("CONTROL") }
            for want in ["forbidden: search_count", "forbidden: last_opened", "forbidden: lastOpened", "forbidden: history", "allowed: page_count"] {
                #expect(anyHolds(control, want), "no CONTROL line holds `\(want)`; the output was: \(ran.output)")
            }
            #expect(anyHolds(control, "CONTROL schema-scan OK"), "no `CONTROL schema-scan OK` line: \(ran.output)")
            let lastControl = all.lastIndex(where: { $0.hasPrefix("CONTROL") })
            let firstTarget = all.firstIndex(where: { $0.hasPrefix("forbidden: ") || $0.hasPrefix("allowed: ") })
            if let lastControl, let firstTarget {
                #expect(lastControl < firstTarget, "a target line is printed before the control is finished")
            } else {
                Issue.record("the output has no control line or no target line: \(ran.output)")
            }
            #expect(ran.status == 1, "a target holding `history` exited \(ran.status), wanted 1: \(ran.output)")
        }
    }

    @Test("schema-scan with a parser that cannot see anything is exit 4 not valid, and scans no target")
    func schemaBlindControl() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, _ in
            let db = root + "/target.sqlite"
            try makeNamesDB(db, table: "names_table", columns: ["history", "page_count"])
            let shim = try makeBlindShim(in: root)
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root].merging(pathEnv(prepending: shim)) { a, _ in a })
            #expect(ran.status == 4, "a blind parser exited \(ran.status), wanted 4: \(ran.output)")
            #expect(ran.output.contains("not valid"), "no `not valid` line: \(ran.output)")
            let v = verdicts(ran.output)
            #expect(v.forbidden.isEmpty && v.allowed.isEmpty, "target lines were printed after a failed control: \(ran.output)")
            #expect(!ran.output.contains("CONTROL schema-scan OK"), "a failed control printed OK: \(ran.output)")
        }
    }

    @Test("schema-scan builds its control as a sqlite file under KIT_ROOT/run and reads the target read-only")
    func schemaCallsAndReadOnly() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, _ in
            let db = root + "/target.sqlite"
            try makeNamesDB(db, table: "names_table", columns: ["page_count", "reason"])
            let before = try Data(contentsOf: URL(fileURLWithPath: db))
            let listing = filesUnder(root + "/")
            let shim = try makeLoggingShim(in: root)
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root].merging(pathEnv(prepending: shim.path)) { a, _ in a })
            #expect(ran.status == 0, "a clean target exited \(ran.status), wanted 0: \(ran.output)")
            let seen = calls(shim.log)
            #expect(!seen.isEmpty, "the script never called sqlite3 (found on PATH)")
            #expect(anyHolds(seen, root + "/run/"),"no sqlite3 call names a control file under \(root)/run/: \(seen)")
            let onTarget = seen.filter { $0.contains(db) }
            #expect(!onTarget.isEmpty, "no sqlite3 call names the target \(db)")
            for call in onTarget {
                #expect(call.contains("-readonly"), "the target is opened without -readonly: sqlite3 \(call)")
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: db)) == before, "the target file changed")
            let after = filesUnder(root + "/").filter { !$0.hasPrefix("run/") && !$0.hasPrefix("evidence/") && !$0.hasPrefix("shim-logging/") && $0 != "sqlite3-calls.log" }
            let expected = listing.filter { !$0.hasPrefix("run/") && !$0.hasPrefix("evidence/") && !$0.hasPrefix("shim-logging/") && $0 != "sqlite3-calls.log" }
            #expect(after == expected, "files appeared next to the target: \(Set(after).subtracting(expected).sorted())")
        }
    }

    // MARK: schema-scan, the verdicts

    @Test("schema-scan gives the 22 hand-written names their verdicts, on the screen and in schema.txt")
    func schemaVerdictTable() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, evidence in
            let db = root + "/target.sqlite"
            try makeNamesDB(db, table: "names_table", columns: nameTable.map { $0.name })
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root])
            #expect(ran.status == 1, "a target with forbidden names exited \(ran.status), wanted 1: \(ran.output)")
            let shown = verdicts(ran.output)
            let saved = try? String(contentsOfFile: evidence + "/schema.txt", encoding: .utf8)
            #expect(saved != nil, "no schema.txt in the evidence folder; the folder holds \(filesUnder(evidence))")
            let kept = verdicts(saved ?? "")
            for entry in nameTable {
                if entry.forbidden {
                    #expect(shown.forbidden.contains(entry.name), "`\(entry.name)` is not printed as `forbidden: \(entry.name)`")
                    #expect(kept.forbidden.contains(entry.name), "schema.txt has no `forbidden: \(entry.name)` line")
                    #expect(!kept.allowed.contains(entry.name), "schema.txt calls `\(entry.name)` allowed")
                } else {
                    #expect(!shown.forbidden.contains(entry.name), "`\(entry.name)` is printed as forbidden, wanted allowed")
                    #expect(kept.allowed.contains(entry.name), "schema.txt has no `allowed: \(entry.name)` line")
                    #expect(!kept.forbidden.contains(entry.name), "schema.txt calls `\(entry.name)` forbidden")
                }
            }
            #expect(kept.allowed.contains("names_table"), "the table name `names_table` has no verdict in schema.txt")
        }
    }

    @Test("every forbidden word alone is forbidden, and `count` with each exempting word is allowed")
    func schemaWordLists() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, evidence in
            let db = root + "/words.sqlite"
            let exempt = exemptWords.map { "count_" + $0 } + ["counts_" + exemptWords[0], "chunk_counts"]
            let forbiddenNames = forbiddenWords + forbiddenWords.map { "x_" + $0 + "_y" } + ["count_other", "counts_of_things"]
            try makeNamesDB(db, table: "words_table", columns: forbiddenNames + exempt)
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            let kept = verdicts((try? String(contentsOfFile: evidence + "/schema.txt", encoding: .utf8)) ?? "")
            for name in forbiddenNames { #expect(kept.forbidden.contains(name), "`\(name)` is not forbidden") }
            for name in exempt { #expect(kept.allowed.contains(name), "`\(name)` is not allowed") }
        }
    }

    @Test("a table name is split and judged like a column name")
    func schemaTableName() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, evidence in
            let db = root + "/table.sqlite"
            try makeNamesDB(db, table: "recentSearches", columns: ["id", "reason"])
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root])
            #expect(ran.status == 1, "a table named recentSearches exited \(ran.status), wanted 1: \(ran.output)")
            #expect(verdicts(ran.output).forbidden.contains("recentSearches"), "no `forbidden: recentSearches` line: \(ran.output)")
            #expect(verdicts((try? String(contentsOfFile: evidence + "/schema.txt", encoding: .utf8)) ?? "").forbidden.contains("recentSearches"),
                    "schema.txt has no `forbidden: recentSearches` line")
        }
    }

    @Test("a target with only allowed names exits 0 and prints no forbidden line")
    func schemaCleanTarget() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, evidence in
            let db = root + "/clean.sqlite"
            try makeNamesDB(db, table: "files", columns: ["id", "page_count", "mtime_ns", "status"])
            let ran = try run(path, ["schema-scan", "--db", db], env: ["KIT_ROOT": root])
            #expect(ran.status == 0, "a clean target exited \(ran.status), wanted 0: \(ran.output)")
            #expect(verdicts(ran.output).forbidden.isEmpty, "a forbidden line was printed for a clean target: \(ran.output)")
            #expect(verdicts((try? String(contentsOfFile: evidence + "/schema.txt", encoding: .utf8)) ?? "").allowed.isSuperset(of: ["files", "id", "page_count", "mtime_ns", "status"]),
                    "schema.txt does not list every name as allowed")
        }
    }

    @Test("a database made with IndexStore, the real schema, prints no forbidden line, by --db and by the default place")
    func schemaRealSchemaIsClean() throws {
        guard let path = scriptPath() else { return }
        try withTempHome { t in
            guard try createFolder(t) else { return }
            let store = try IndexStore()
            store.close()
            let source = t.folder.appendingPathComponent("index.sqlite")
            guard FileManager.default.fileExists(atPath: source.path) else {
                Issue.record("IndexStore made no index.sqlite in \(t.folder.path)")
                return
            }
            try withScanRoot { root, evidence in
                let place = root + "/home/Library/Application Support/Sesame"
                try FileManager.default.createDirectory(atPath: place, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] {
                    let from = source.path + suffix
                    if FileManager.default.fileExists(atPath: from) {
                        try FileManager.default.copyItem(atPath: from, toPath: place + "/index.sqlite" + suffix)
                    }
                }
                let byDb = try run(path, ["schema-scan", "--db", place + "/index.sqlite"], env: ["KIT_ROOT": root])
                #expect(byDb.status == 0, "the real schema by --db exited \(byDb.status), wanted 0: \(byDb.output)")
                #expect(verdicts(byDb.output).forbidden.isEmpty, "the real schema has forbidden names: \(verdicts(byDb.output).forbidden.sorted())")
                let byDefault = try run(path, ["schema-scan"], env: ["KIT_ROOT": root])
                #expect(byDefault.status == 0, "the real schema at the default place exited \(byDefault.status), wanted 0: \(byDefault.output)")
                #expect(verdicts(byDefault.output).forbidden.isEmpty, "the real schema has forbidden names: \(verdicts(byDefault.output).forbidden.sorted())")
                let kept = verdicts((try? String(contentsOfFile: evidence + "/schema.txt", encoding: .utf8)) ?? "")
                for name in ["files", "passages", "mtime_ns", "read_to", "tries"] {
                    #expect(kept.allowed.contains(name), "schema.txt does not list `\(name)` of the real schema as allowed")
                }
            }
        }
    }

    @Test("without --db the target is the Sesame index of the throwaway home; a missing target is exit 4")
    func schemaDefaultTarget() throws {
        guard let path = scriptPath() else { return }
        try withScanRoot { root, _ in
            let missing = try run(path, ["schema-scan"], env: ["KIT_ROOT": root])
            #expect(missing.status == 4, "no index at all exited \(missing.status), wanted 4: \(missing.output)")
            #expect(missing.output.contains("not valid"), "no `not valid` line: \(missing.output)")
            let gone = try run(path, ["schema-scan", "--db", root + "/no-such-file.sqlite"], env: ["KIT_ROOT": root])
            #expect(gone.status == 4, "a --db that does not exist exited \(gone.status), wanted 4: \(gone.output)")

            let place = root + "/home/Library/Application Support/Sesame"
            try FileManager.default.createDirectory(atPath: place, withIntermediateDirectories: true)
            try makeNamesDB(place + "/index.sqlite", table: "files", columns: ["id", "lastOpened"])
            let ran = try run(path, ["schema-scan"], env: ["KIT_ROOT": root])
            #expect(ran.status == 1, "an index holding lastOpened exited \(ran.status), wanted 1: \(ran.output)")
            #expect(verdicts(ran.output).forbidden.contains("lastOpened"), "no `forbidden: lastOpened` line: \(ran.output)")
        }
    }

    // MARK: tcc

    private func tccRun(_ root: String, _ dbs: [String], identifier: String? = nil, env: [String: String] = [:]) throws -> Ran {
        guard let path = scriptPath() else { return Ran(status: -1, output: "") }
        var args = ["tcc"]
        for db in dbs { args += ["--db", db] }
        if let identifier { args += ["--identifier", identifier] }
        return try run(path, args, env: env.merging(["KIT_ROOT": root]) { a, _ in a })
    }

    @Test("tcc: no row for the identifier is exit 0 and says so; rows for other clients and other services are ignored")
    func tccNoRow() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let empty = root + "/empty.db"
            try makeTCC(empty, rows: [])
            let busy = root + "/busy.db"
            try makeTCC(busy, rows: [
                ("kTCCServiceCamera", "app.test.Other0001"),
                ("kTCCServiceSystemPolicyAllFiles", "app.test.Other0002"),
                ("kTCCServiceMicrophone", "app.test.Fake74210"),
                ("kTCCServiceAppleEvents", privacyIdentifier),
                ("kTCCServiceSystemPolicyDocumentsFolder", privacyIdentifier),
            ])
            for db in [empty, busy] {
                let ran = try tccRun(root, [db])
                #expect(ran.status == 0, "\(db) exited \(ran.status), wanted 0: \(ran.output)")
                #expect(ran.output.contains("no Full Disk Access, camera or microphone row for \(privacyIdentifier)"),
                        "no `no Full Disk Access, camera or microphone row for \(privacyIdentifier)` line: \(ran.output)")
                #expect(!ran.output.contains("TCC row:"), "a TCC row was reported: \(ran.output)")
            }
        }
    }

    @Test("tcc: a Full Disk Access, camera or microphone row for the identifier is exit 1 with its service named",
          arguments: ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceCamera", "kTCCServiceMicrophone"])
    func tccFailingService(_ service: String) throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let db = root + "/one.db"
            try makeTCC(db, rows: [(service, privacyIdentifier), ("kTCCServiceAppleEvents", privacyIdentifier)])
            let ran = try tccRun(root, [db])
            #expect(ran.status == 1, "a \(service) row exited \(ran.status), wanted 1: \(ran.output)")
            #expect(ran.output.contains("TCC row: \(service)"), "no `TCC row: \(service)` line: \(ran.output)")
            #expect(!ran.output.contains("no Full Disk Access, camera or microphone row"), "the clean line was printed too: \(ran.output)")
            #expect(!ran.output.contains("TCC row: kTCCServiceAppleEvents"), "a service that does not fail was reported: \(ran.output)")
        }
    }

    @Test("tcc: all three failing rows are named, each once")
    func tccAllThree() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let db = root + "/all.db"
            try makeTCC(db, rows: [
                ("kTCCServiceSystemPolicyAllFiles", privacyIdentifier),
                ("kTCCServiceCamera", privacyIdentifier),
                ("kTCCServiceMicrophone", privacyIdentifier),
            ])
            let ran = try tccRun(root, [db])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            for service in ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceCamera", "kTCCServiceMicrophone"] {
                let n = lines(ran.output).filter { $0.contains("TCC row: \(service)") }.count
                #expect(n == 1, "`TCC row: \(service)` is printed \(n) times, wanted 1: \(ran.output)")
            }
        }
    }

    @Test("tcc: --identifier overrides the identifier read from Info.plist; the client must match exactly")
    func tccIdentifierOption() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let db = root + "/other.db"
            try makeTCC(db, rows: [("kTCCServiceCamera", "app.test.Other9")])
            let plain = try tccRun(root, [db])
            #expect(plain.status == 0, "the plist identifier does not match the row, exited \(plain.status), wanted 0: \(plain.output)")
            let named = try tccRun(root, [db], identifier: "app.test.Other9")
            #expect(named.status == 1, "--identifier app.test.Other9 exited \(named.status), wanted 1: \(named.output)")
            #expect(named.output.contains("TCC row: kTCCServiceCamera"), "no `TCC row: kTCCServiceCamera` line: \(named.output)")
            let prefix = try tccRun(root, [db], identifier: "app.test.Other")
            #expect(prefix.status == 0, "a prefix of the client exited \(prefix.status), wanted 0: \(prefix.output)")
            #expect(prefix.output.contains("no Full Disk Access, camera or microphone row for app.test.Other"), "no clean line: \(prefix.output)")
        }
    }

    @Test("tcc: the identifier is read from the bundle's Info.plist")
    func tccIdentifierFromPlist() throws {
        try withScanRoot { root, _ in
            try writeBundle(root, identifier: "app.test.FromPlist5513")
            let db = root + "/plist.db"
            try makeTCC(db, rows: [("kTCCServiceSystemPolicyAllFiles", "app.test.FromPlist5513")])
            let ran = try tccRun(root, [db])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            #expect(ran.output.contains("TCC row: kTCCServiceSystemPolicyAllFiles"), "no TCC row line: \(ran.output)")
        }
    }

    @Test("tcc: every --db is read; a row in the second of two databases is found")
    func tccTwoDatabases() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let user = root + "/user.db"
            let system = root + "/system.db"
            try makeTCC(user, rows: [])
            try makeTCC(system, rows: [("kTCCServiceSystemPolicyAllFiles", privacyIdentifier)])
            let ran = try tccRun(root, [user, system])
            #expect(ran.status == 1, "exited \(ran.status), wanted 1: \(ran.output)")
            #expect(ran.output.contains("TCC row: kTCCServiceSystemPolicyAllFiles"), "no TCC row line: \(ran.output)")
            let both = try tccRun(root, [user, user])
            #expect(both.status == 0, "two clean databases exited \(both.status), wanted 0: \(both.output)")
        }
    }

    @Test("tcc: a database that cannot be read is exit 3 NEEDS A PERSON naming Full Disk Access for the terminal")
    func tccUnreadable() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let locked = root + "/locked.db"
            try makeTCC(locked, rows: [("kTCCServiceCamera", privacyIdentifier)])
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked) }
            let notSqlite = root + "/not-sqlite.db"
            try "this file is plain text and no database at all, so sqlite refuses it\n".write(toFile: notSqlite, atomically: true, encoding: .utf8)
            for db in [locked, notSqlite] {
                let ran = try tccRun(root, [db])
                #expect(ran.status == 3, "\(db) exited \(ran.status), wanted 3: \(ran.output)")
                #expect(ran.output.contains("NEEDS A PERSON: Full Disk Access for the terminal"), "no `NEEDS A PERSON: Full Disk Access for the terminal` line: \(ran.output)")
                #expect(ran.output.contains("CONTROL tcc OK"), "the control did not run before the unreadable database: \(ran.output)")
                #expect(!ran.output.contains("TCC row:"), "a row was reported for a database that cannot be read: \(ran.output)")
            }
        }
    }

    @Test("tcc: the control runs first on a hand-made database with a camera row for a made-up identifier, and a blind reader is exit 4")
    func tccControl() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let db = root + "/target.db"
            try makeTCC(db, rows: [("kTCCServiceCamera", privacyIdentifier)])
            let first = try tccRun(root, [db])
            let all = lines(first.output)
            let controlAt = all.firstIndex(where: { $0.contains("CONTROL tcc OK") })
            let verdictAt = all.firstIndex(where: { $0.contains("TCC row:") })
            #expect(controlAt != nil, "no `CONTROL tcc OK` line: \(first.output)")
            if let controlAt, let verdictAt { #expect(controlAt < verdictAt, "the verdict is printed before the control") }
            let shim = try makeBlindShim(in: root)
            let blind = try tccRun(root, [db], env: pathEnv(prepending: shim))
            #expect(blind.status == 4, "a blind reader exited \(blind.status), wanted 4: \(blind.output)")
            #expect(blind.output.contains("not valid"), "no `not valid` line: \(blind.output)")
            #expect(!blind.output.contains("TCC row:") && !blind.output.contains("no Full Disk Access, camera or microphone row"),
                    "a verdict was printed after a failed control: \(blind.output)")
            #expect(!blind.output.contains("CONTROL tcc OK"), "a failed control printed OK: \(blind.output)")
        }
    }

    @Test("tcc reads read-only and safe, never opens the real permission database and changes nothing")
    func tccReadOnlyAndNeverReal() throws {
        try withScanRoot { root, _ in
            try writeBundle(root)
            let db = root + "/target.db"
            try makeTCC(db, rows: [("kTCCServiceAppleEvents", privacyIdentifier)])
            let before = try Data(contentsOf: URL(fileURLWithPath: db))
            let listing = filesUnder(root + "/")
            let shim = try makeLoggingShim(in: root)
            let ran = try tccRun(root, [db], env: pathEnv(prepending: shim.path))
            #expect(ran.status == 0, "exited \(ran.status), wanted 0: \(ran.output)")
            let seen = calls(shim.log)
            #expect(!seen.isEmpty, "the script never called sqlite3 (found on PATH)")
            let onTarget = seen.filter { $0.contains(db) }
            #expect(!onTarget.isEmpty, "no sqlite3 call names the target \(db)")
            for call in onTarget {
                #expect(call.contains("-readonly") && call.contains("-safe"), "the target is not opened with -readonly -safe: sqlite3 \(call)")
            }
            for call in seen {
                #expect(!call.contains("com.apple.TCC"), "the real permission database is named in: sqlite3 \(call)")
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: db)) == before, "the target file changed")
            let keep: (String) -> Bool = { !$0.hasPrefix("run/") && !$0.hasPrefix("evidence/") && !$0.hasPrefix("shim-logging/") && $0 != "sqlite3-calls.log" }
            #expect(filesUnder(root + "/").filter(keep) == listing.filter(keep), "files appeared next to the target")
        }
    }

    @Test("tcc names both permission database paths, the user's and the system's, and opens them read-only")
    func tccDefaultPaths() throws {
        guard let body = modeCode("tcc") else { return }
        ok(has(body, "\\$\\{?(REAL_HOME|HOME)\\}?/Library/Application Support/com\\.apple\\.TCC/TCC\\.db"),
           "tcc never names the user's permission database ($REAL_HOME/Library/Application Support/com.apple.TCC/TCC.db)")
        ok(has(body, "(^|[\"' =(])/Library/Application Support/com\\.apple\\.TCC/TCC\\.db"),
           "tcc never names the system permission database (/Library/Application Support/com.apple.TCC/TCC.db)")
        ok(body.contains("-readonly") && body.contains("-safe"), "tcc does not open a database with `sqlite3 -readonly -safe`")
        for service in ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceCamera", "kTCCServiceMicrophone"] {
            ok(body.contains(service), "tcc never names the service \(service)")
        }
        ok(body.contains("NEEDS A PERSON: Full Disk Access for the terminal"), "tcc has no `NEEDS A PERSON: Full Disk Access for the terminal` line")
    }

    // MARK: plan-3 kit repair 1: the library scan counts only paths that appeared after the baseline

    /// A throwaway stand-in for the real home (KIT_REAL_HOME_SEAM) and an empty TMPDIR, so nothing of the person's is read or written.
    private func withScanHomes<T>(_ body: (_ root: String, _ realHome: String, _ tmp: String) throws -> T) throws -> T {
        try withScanRoot { root, _ in
            let fm = FileManager.default
            let realHome = root + "-realhome"
            let tmp = root + "-tmp"
            try fm.createDirectory(atPath: realHome + "/Library", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: realHome); try? fm.removeItem(atPath: tmp) }
            try writeBundle(root)
            return try body(root, realHome, tmp)
        }
    }

    private func plant(_ path: String, _ text: String = "x") throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("library-scan: a path named sesame that was in the real Library before the baseline is not a finding; a new one is, and only the new one is named")
    func libraryScanCountsOnlyNewPaths() throws {
        guard let path = scriptPath() else { return }
        try withScanHomes { root, realHome, tmp in
            let env = ["KIT_ROOT": root, "KIT_REAL_HOME_SEAM": realHome, "TMPDIR": tmp]
            let lib = realHome + "/Library"
            // leftovers of earlier runs, as the drift check found them: all present before the baseline
            try plant(lib + "/Application Support/Sesame/index.sqlite")
            try plant(lib + "/Caches/SesameHelper/old.bin")
            try plant(lib + "/Caches/app.sesame.Sesame/Cache.db")
            try plant(lib + "/Preferences/app.sesame.Sesame.plist", "<plist><dict><key>CFBundleIdentifier</key><string>\(privacyIdentifier)</string></dict></plist>")
            try plant(lib + "/Logs/DiagnosticReports/SesameHelper-2026-10-22-000000.ips")
            try plant(lib + "/Caches/com.example.Benign/ok.bin")

            let base = try run(path, ["baseline"], env: env)
            #expect(base.status == 0, "baseline exited \(base.status): \(base.output)")

            let clean = try run(path, ["library-scan"], env: env)
            #expect(clean.status == 0, "a scan with only pre-baseline leftovers exited \(clean.status), wanted 0: \(clean.output)")
            #expect(clean.output.contains("LIBRARY-SCAN CLEAN"), "no LIBRARY-SCAN CLEAN line: \(clean.output)")
            #expect(!clean.output.contains("FOUND "), "a pre-baseline path was reported as FOUND: \(clean.output)")

            // the same scan can still go red: something new appears after the baseline
            try plant(lib + "/Caches/SesameHelper-new/fresh.bin")
            try plant(lib + "/Preferences/zz-leak.plist", "<plist><dict><key>CFBundleIdentifier</key><string>\(privacyIdentifier)</string></dict></plist>")
            try plant(lib + "/Caches/com.example.Benign/also-ok.bin")
            let red = try run(path, ["library-scan"], env: env)
            #expect(red.status == 1, "a scan with new paths exited \(red.status), wanted 1: \(red.output)")
            #expect(red.output.contains("LIBRARY-SCAN FAILED"), "no LIBRARY-SCAN FAILED line: \(red.output)")
            let found = lines(red.output).filter { $0.hasPrefix("FOUND ") && $0.contains(lib) }
            #expect(found.contains { $0.contains("Caches/SesameHelper-new") }, "the new Sesame folder was not reported: \(found)")
            #expect(found.contains { $0.hasPrefix("FOUND content") && $0.contains("Preferences/zz-leak.plist") }, "the new plist holding the identifier was not reported: \(found)")
            #expect(!found.contains { $0.contains("Application Support/Sesame") || $0.contains("app.sesame.Sesame/") || $0.contains("DiagnosticReports") || $0.contains("SesameHelper/old.bin") || $0.contains("Benign") },
                    "an old path or a benign one was reported: \(found)")
        }
    }

    @Test("library-scan: a new file inside a Sesame folder that was there before the baseline is a finding")
    func libraryScanNewFileInOldFolder() throws {
        guard let path = scriptPath() else { return }
        try withScanHomes { root, realHome, tmp in
            let env = ["KIT_ROOT": root, "KIT_REAL_HOME_SEAM": realHome, "TMPDIR": tmp]
            let lib = realHome + "/Library"
            try plant(lib + "/Caches/SesameHelper/old.bin")
            #expect(try run(path, ["baseline"], env: env).status == 0)
            try plant(lib + "/Caches/SesameHelper/new.bin")
            let red = try run(path, ["library-scan"], env: env)
            #expect(red.status == 1, "exit \(red.status), wanted 1: \(red.output)")
            #expect(lines(red.output).contains { $0.hasPrefix("FOUND name") && $0.hasSuffix("Caches/SesameHelper/new.bin") }, "the new file was not reported: \(red.output)")
            #expect(!lines(red.output).contains { $0.hasSuffix("old.bin") }, "the old file was reported: \(red.output)")
        }
    }

    @Test("baseline names the real Library paths that already name sesame and says the scan does not count them")
    func baselineNamesOldPaths() throws {
        guard let path = scriptPath() else { return }
        try withScanHomes { root, realHome, tmp in
            try plant(realHome + "/Library/Caches/SesameHelper/old.bin")
            let base = try run(path, ["baseline"], env: ["KIT_ROOT": root, "KIT_REAL_HOME_SEAM": realHome, "TMPDIR": tmp])
            #expect(base.status == 0, "baseline exited \(base.status): \(base.output)")
            #expect(base.output.contains("Caches/SesameHelper"), "the baseline did not name the old path: \(base.output)")
            #expect(base.output.contains("does not count them"), "the baseline note still says the scan counts them: \(base.output)")
        }
    }

    // MARK: plan-3 kit repair 1: the Doctor's folder-picker ping reads the Go to sheet and the chosen folder back

    private var libDir: String { projectRoot.appendingPathComponent("scripts/kit-lib").path }

    /// Sources the recipes' picker driver with a stub `kq` standing in for kit-ax.sh. `mode` is nosheet (the Go to sheet never takes the
    /// path), wrong (Return adds a different folder than the typed one) or right (Return adds the folder). No app, no window, no key.
    private func driveStubbedPicker(_ mode: String, folder: String, state: String) throws -> Ran {
        let script = """
        . "\(libDir)/common.sh"
        . "\(libDir)/recipes.sh"
        S="\(state)"; MODE="\(mode)"; WANT="$(cd "\(folder)" && pwd -P)"
        PK_PAUSE=0; PK_SHEET=1
        : > "$S/rows"
        kq() {
          case "$2" in
            frontmost) echo Sesame ;;
            front-sesame|click) return 0 ;;
            gotofolder) [ "$MODE" = nosheet ] && return 1; echo "$3" > "$S/typed"; return 0 ;;
            key)
              if [ "$3" = enter ]; then
                n=$(( $(cat "$S/enters" 2>/dev/null || echo 0) + 1 )); echo $n > "$S/enters"
                if [ $((n % 2)) = 0 ]; then
                  if [ "$MODE" = right ]; then echo "$WANT" >> "$S/rows"; else echo "$WANT-other-$n" >> "$S/rows"; fi
                fi
              fi
              return 0 ;;
            dump)
              echo "window 560 x 600 at 0,0 title Set up Sesame"; echo 'AXWindow label="Set up Sesame"'
              while IFS= read -r r; do echo "  AXCheckBox label=\\"f\\" desc=\\"f, 1 photos, about 1 min\\" help=\\"$r\\" value=\\"1\\""; done < "$S/rows" 2>/dev/null
              return 0 ;;
          esac
          return 1
        }
        PICKER_WHY=""
        drive_picker "\(folder)"; echo "drive_picker status $?"
        echo "why: $PICKER_WHY"
        setup_lists "\(folder)" && echo "setup lists the folder" || echo "setup does not list the folder"
        """
        return try run("/bin/bash", ["-c", script], env: ["KIT_ROOT": state + "/sesame-kit-picker"], limit: 60)
    }

    private func withPickerState<T>(_ body: (_ folder: String, _ state: String) throws -> T) throws -> T {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("kit-picker-" + UUID().uuidString).path
        try fm.createDirectory(atPath: base + "/state", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/fixtures/empty", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        return try body(base + "/fixtures/empty", base + "/state")
    }

    @Test("the picker driver the Doctor uses: a Go to sheet that never takes the path is a failed ping, and nothing is added")
    func pickerSheetNeverTakesPath() throws {
        try withPickerState { folder, state in
            let ran = try driveStubbedPicker("nosheet", folder: folder, state: state)
            #expect(ran.output.contains("drive_picker status 1"), "a sheet that never took the path was not a failure: \(ran.output)")
            #expect(ran.output.contains("did not take the path"), "the failure does not say the sheet did not take the path: \(ran.output)")
            #expect(!FileManager.default.fileExists(atPath: state + "/enters"), "Return was pressed although the field never held the path")
        }
    }

    @Test("the picker driver the Doctor uses: a picker that adds another folder than the typed one is a failed ping, whatever the sheet said")
    func pickerChoosesWrongFolder() throws {
        try withPickerState { folder, state in
            let ran = try driveStubbedPicker("wrong", folder: folder, state: state)
            #expect(ran.output.contains("drive_picker status 1"), "a wrong chosen folder was not a failure: \(ran.output)")
            #expect(ran.output.contains("the picker added"), "the failure does not name the folder the picker added: \(ran.output)")
            #expect(ran.output.contains("setup does not list the folder"), "the setup window read-back says the folder is listed: \(ran.output)")
        }
    }

    @Test("the picker driver the Doctor uses: the right folder is read back from the setup window after the path was set in the sheet")
    func pickerChoosesRightFolder() throws {
        try withPickerState { folder, state in
            let ran = try driveStubbedPicker("right", folder: folder, state: state)
            #expect(ran.output.contains("drive_picker status 0"), "the right folder was not a pass: \(ran.output)")
            #expect(ran.output.contains("setup lists the folder"), "the setup window read-back does not list the folder: \(ran.output)")
            let typed = (try? String(contentsOfFile: state + "/typed", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(typed == folder, "the sheet's field was set to \(typed ?? "nothing"), wanted \(folder)")
        }
    }

    @Test("kit-doctor.sh drives the picker through drive_picker and the setup window read-back, never by typing keys, and still ends a failed ping with the NEEDS A PERSON line")
    func doctorUsesTheCheckedPicker() throws {
        let path = projectRoot.appendingPathComponent("scripts/kit-doctor.sh").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { Issue.record("scripts/kit-doctor.sh not found"); return }
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        ok(has(code, "drive_picker[ ]+\"\\$empty_dir\""), "the Doctor's picker ping does not go through drive_picker")
        ok(has(code, "setup_lists[ ]+\"\\$empty_dir\""), "the Doctor's picker ping does not read the chosen folder back from the setup window")
        ok(!has(code, "kit-ax\\.sh\"[ ]+(type|key)\\b"), "the Doctor still posts typed keys itself in the picker ping")
        ok(code.contains("folder picker cannot be driven (DOCTOR: NEEDS A PERSON (folder picker cannot be driven))"), "the Doctor lost its failed-ping line (verify.md, guess K33)")
        let ran = try run("/bin/bash", ["-n", path])
        #expect(ran.status == 0, "bash -n: \(ran.output)")
    }
}

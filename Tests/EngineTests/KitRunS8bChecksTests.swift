import Foundation
import Testing

// plan-3-t10, tester step: kit part 6 of 7, the checks S8.5 and S8.6 (a new scripts/kit-lib/checks-s8c.sh, sourced by
// scripts/kit-run.sh through its `checks-*.sh` glob; scripts/kit-lib/checks-s8.sh gets its header corrected). Written from
// verify.md, the feature map S8, the design and the plan-3-t10 entry only, with the names the sealed t1, t2, t8 and t9 reports give
// (`tree_need <id>`, `tree_pick_list`, `wait_menu_ready`, the tables gate-matrix.csv, read-kinds.txt, extensions.txt, tree.tsv, the
// modes `kit-index.sh has|under|reasons|wait`, `kit-fixtures.sh expect listing|counts`, `kit-ax.sh dump settings`); no product
// source is read, and no kit function may read it.
//
// Static proof only (plan-3-tasks.md, Conventions; the person's ruling "no app launch"): a check needs the app, the S8 session of
// t8 and the panel, so NOTHING here runs a check, the recipe, `kit-run.sh` or any kit script that starts the app or drives its UI.
// The only runs are `bash -n`. Every other test reads the text of the check files, with their comment lines removed (a comment never
// satisfies a test), as the function itself ("own": the lines of the check function), as the function with its own file's helpers
// written in ("mine": a call of an `s8c_` function replaced, in place, by that function's code) or as the shell would run it
// ("expanded": every call of a kit function replaced). Real behaviour is read at the accept stage only (block C, and block E for
// S8.5's key-name break).
//
// The contract read here (plan-3-t10, Tests, and the feature map S8):
//   - `check_S8_5` and `check_S8_6` exist, once each, in checks-s8c.sh; checks.tsv keeps them at slice 3, `auto`; each starts with
//     `tree_need <its id>`, then `kit-index.sh wait done 900`, then `wait_menu_ready 120` (so it runs from any state) and never
//     closes the window (no `s8_close_window`, no `s8_activity`, no observer, nothing written to run/window-ids);
//   - S8.5 starts by reading the Settings list (`kit-ax.sh dump settings`, Folders) and requires its roots under matrix/ to equal the
//     pick list of `tree_pick_list` exactly, else `RERUN S8.5 not valid: picked roots differ from the pick list` (exit 4); then for
//     every cell of gate-matrix.csv whose kind (from extensions.txt) is listed in read-kinds.txt: `kit-index.sh has <path>` equals
//     expected_in_index, searching the name stem and the content token (`kit-search.sh`) lists the file exactly expected_rows times;
//     the cells of the other kinds are `SKIPPED-KIND <cell> <kind>` in gate-matrix-result.tsv and are not counted (a type no reader
//     reads at all, the bare key extensions included, is not a kind: those cells are checked); the file has the columns
//     `cell,group,expected in index,expected rows,in index,rows listed,pass`; group `extra` prints `EXTRA <cell> excluded|read` and
//     never fails; an included cell that the same search does not find is `RERUN S8.5 not valid` (exit 4), never a pass;
//     `--plant S8.5` removes one expected cell from the index view and prints `FAIL planted`;
//   - S8.6: the unsupported files (no reader, not a kind) are not in `kit-index.sh has`, not in Settings, not in any result and not in
//     `kit-fixtures.sh expect counts`; the damaged picture is in `kit-index.sh reasons` with a reason and listed in Settings with its
//     path; every other picture of tree/damaged and tree/unsupported is `done` (their number equals `kit-fixtures.sh expect listing`
//     for the pictures of those two folders, less the damaged ones); indexing reached Ready.
// Red before the kit part: checks-s8c.sh does not exist and the two ids have no function.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s8c.sh")
private let oldCheckFile = libDir.appendingPathComponent("checks-s8.sh")

private let ids = ["S8.5", "S8.6"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs `/bin/bash -n` (the only program this suite starts).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun8b-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
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

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

/// An expectation on a script's text. It records only the message on failure, never the whole script.
private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func firstIndex(_ text: String, _ pattern: String) -> Int? {
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

private func lastIndex(_ text: String, _ pattern: String) -> Int? {
    var found: Int?
    var from = text.startIndex
    while from < text.endIndex, let r = text.range(of: pattern, options: .regularExpression, range: from..<text.endIndex) {
        found = text.distance(from: text.startIndex, to: r.lowerBound)
        from = r.upperBound > from ? r.upperBound : text.index(after: from)
    }
    return found
}

/// Every capture group of every match of the pattern.
private func groups(_ text: String, _ pattern: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (1..<max(m.numberOfRanges, 1)).map { i in
            m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : ""
        }
    }
}

private func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

/// The code of a text: every line that is not a comment (`#`, the shebang line included).
private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func kitLibShellNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []
    return names.filter { $0.hasSuffix(".sh") }.sorted()
}

private func checkFileNames() -> [String] {
    kitLibShellNames().filter { $0.hasPrefix("checks-") }
}

/// The code of the runner and of every shell file of scripts/kit-lib, as (name, code).
private func kitShellSources() -> [(name: String, code: String)] {
    var all: [(String, String)] = []
    if let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) { all.append(("kit-run.sh", stripComments(text))) }
    for name in kitLibShellNames() {
        if let text = read(libDir.appendingPathComponent(name)) { all.append(("kit-lib/" + name, stripComments(text))) }
    }
    return all
}

/// The shell functions of a text: name to body. A function is `name() {` to a line that is just `}`, or one line
/// `name() { ...; }`.
private func shellFunctions(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    var name: String?
    var body: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if name == nil {
            if let n = groups(line, "^([A-Za-z_][A-Za-z0-9_]*)\\(\\) \\{( #.*)?$").first?.first {
                name = n
                body = []
            } else if let g = groups(line, "^([A-Za-z_][A-Za-z0-9_]*)\\(\\) \\{ (.*) \\}$").first, g.count == 2 {
                result[g[0]] = g[1]
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

/// Every function of the runner and of the kit-lib shell files. A later file never replaces an earlier name.
private func allFunctions() -> [String: String] {
    var merged: [String: String] = [:]
    for (_, code) in kitShellSources() {
        for (k, v) in shellFunctions(in: code) where merged[k] == nil { merged[k] = v }
    }
    return merged
}

/// Simple top-level variables (NAME="value", NAME='value' on a line that starts in column 0).
private func topLevelValues() -> [String: String] {
    var values: [String: String] = [:]
    for (_, code) in kitShellSources() {
        for line in code.split(separator: "\n").map(String.init) {
            if let g = groups(line, "^([A-Z][A-Z0-9_]*)=\"([^\"]*)\"").first, g.count == 2, !g[1].contains("$("), !g[1].contains("`") {
                values[g[0]] = g[1]
            } else if let g = groups(line, "^([A-Z][A-Z0-9_]*)='([^']*)'").first, g.count == 2 {
                values[g[0]] = g[1]
            }
        }
    }
    return values
}

/// A word that can be a call: not part of a longer word, a path (`kit-ax.sh`, `--trace`) or a label (`usage:`).
private let callWord = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_.:-])")

/// `body` with every call to a function of `functions` replaced, in place, by that function's own code. Depth is capped.
private func expandShell(_ body: String, _ functions: [String: String], skipping: [String] = [], depth: Int = 0) -> String {
    guard depth < 6 else { return body }
    var out: [String] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        out.append(line)
        let ns = line as NSString
        var seen = Set<String>()
        for m in callWord.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            guard let function = functions[word], !skipping.contains(word), seen.insert(word).inserted else { continue }
            out.append(expandShell(function, functions, skipping: skipping + [word], depth: depth + 1))
        }
    }
    return out.joined(separator: "\n")
}

/// `text` with each top-level variable replaced by its value (two passes: a value may name another variable).
private func substitute(_ text: String, _ values: [String: String]) -> String {
    var result = text
    for _ in 0..<2 {
        for (name, value) in values where result.contains("$" + name) || result.contains("${" + name + "}") {
            let esc = NSRegularExpression.escapedPattern(for: name)
            guard let re = try? NSRegularExpression(pattern: "\\$\\{\(esc)\\}|\\$\(esc)(?![A-Za-z0-9_])") else { continue }
            result = re.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: value))
        }
    }
    return result
}

private func checkFunctionName(_ id: String) -> String {
    "check_" + id.replacingOccurrences(of: ".", with: "_")
}

/// The check as the shell would run it: every kit function and variable written in. Records the reason and returns nil when the
/// function does not exist.
private func expanded(_ id: String) -> String? {
    let functions = allFunctions()
    let name = checkFunctionName(id)
    guard let body = functions[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    return substitute(expandShell(body, functions, skipping: [name]), topLevelValues())
}

/// The check with only the helpers of checks-s8c.sh (functions named `s8c_...`) written in; a call of a function of another kit
/// file (tree_need, wait_menu_ready, settings_section) stays a call, so it never brings the recipe's code into the text.
private func mine(_ id: String) -> String? {
    let all = allFunctions()
    let name = checkFunctionName(id)
    guard let body = all[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    let own = all.filter { $0.key.hasPrefix("s8c_") }
    return substitute(expandShell(body, own, skipping: [name]), topLevelValues())
}

/// The lines of the check function alone (no called function written in), variables written in.
private func own(_ id: String) -> String? {
    let name = checkFunctionName(id)
    guard let body = allFunctions()[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    return substitute(body, topLevelValues())
}

private func before(_ text: String, _ a: String, _ b: String, _ message: String,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    guard let ia = firstIndex(text, a), let ib = firstIndex(text, b) else {
        ok(false, "\(message) (missing: \(firstIndex(text, a) == nil ? a : b))", sourceLocation: sourceLocation)
        return
    }
    ok(ia < ib, message, sourceLocation: sourceLocation)
}

private func escaped(_ id: String) -> String { NSRegularExpression.escapedPattern(for: id) }

/// Rows of checks.tsv: id, first slice, kind.
private func tsvRows() -> [(id: String, slice: String, kind: String)]? {
    guard let text = read(libDir.appendingPathComponent("checks.tsv")) else {
        Issue.record("scripts/kit-lib/checks.tsv not found")
        return nil
    }
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return f.count >= 3 ? (f[0], f[1], f[2]) : nil
    }
}

/// The cell ids of the hand-written gate matrix (the table is read, never its expected values).
private func matrixCellIds() -> [String] {
    guard let text = read(libDir.appendingPathComponent("gate-matrix.csv")) else { return [] }
    return text.split(separator: "\n").dropFirst().compactMap { line in
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return f.count >= 7 ? f[0] : nil
    }
}

// Patterns of a call of a kit script, as the check text holds it after the variables are written in.
private let indexWaitDone = #"kit-index\.sh"?[ ]+wait[ ]+done[ ]+900"#
private let menuReady = #"\bwait_menu_ready[ ]+120"#
private let indexHas = #"kit-index\.sh"?[ ]+has[ ]"#
private let indexUnder = #"kit-index\.sh"?[ ]+under[ ]"#
private let indexReasons = #"kit-index\.sh"?[ ]+reasons"#
private let searchCall = #"kit-search\.sh"?[ ]+"#
private let dumpSettings = #"kit-ax\.sh"?[ ]+dump[ ]+settings"#
private let expectListing = #"kit-fixtures\.sh"?[ ]+expect[ ]+listing"#
private let expectCounts = #"kit-fixtures\.sh"?[ ]+expect[ ]+counts"#

@Suite("KitRunS8bChecksTests")
struct KitRunS8bChecksTests {

    // MARK: syntax and wiring

    @Test("bash -n finds no syntax error in checks-s8c.sh, checks-s8.sh and the runner (none is run)")
    func bashSyntax() throws {
        for url in [checkFile, oldCheckFile, scriptsDir.appendingPathComponent("kit-run.sh")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(Comment(rawValue: "\(url.path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", url.path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(url.path) exited \(ran.status): \(ran.output)")
        }
    }

    @Test("the runner sources every scripts/kit-lib/checks-*.sh, so the new file needs no wiring; checks-s8c.sh holds no top-level command")
    func runnerSourcesTheFile() {
        let runner = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) ?? ""
        ok(has(runner, #"checks-\*\.sh"#), "kit-run.sh no longer sources every scripts/kit-lib/checks-*.sh")
        guard let text = read(checkFile) else {
            Issue.record("scripts/kit-lib/checks-s8c.sh not found")
            return
        }
        let lines = stripComments(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var depth = 0
        var strays: [String] = []
        for line in lines {
            if depth == 0, !line.trimmingCharacters(in: .whitespaces).isEmpty,
               !has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"^[A-Z][A-Z0-9_]*="#) {
                strays.append(line)
            }
            if has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"\}$"#) { depth += 1 }
            if line == "}" { depth = max(0, depth - 1) }
        }
        ok(strays.isEmpty, "checks-s8c.sh runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("checks.tsv keeps S8.5 and S8.6 once each, at slice 3, kind auto", arguments: ids)
    func registered(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == "3", "\(id) is registered at slice \(row.slice), expected 3")
            ok(row.kind == "auto", "\(id) has kind \(row.kind), expected auto")
        }
    }

    @Test("each of the two ids has exactly one check function, and it is in checks-s8c.sh", arguments: ids)
    func exactlyOneFunction(_ id: String) {
        let name = checkFunctionName(id)
        var total = 0
        var where_: [String] = []
        for file in checkFileNames() {
            guard let text = read(libDir.appendingPathComponent(file)) else { continue }
            let n = stripComments(text).split(separator: "\n").filter { $0.hasPrefix("\(name)() {") }.count
            total += n
            if n > 0 { where_.append(file) }
        }
        ok(total == 1, "\(name) is defined \(total) times in scripts/kit-lib/checks-*.sh (\(where_.joined(separator: ", "))), expected once")
        ok(where_ == ["checks-s8c.sh"], "\(name) is defined in \(where_), expected checks-s8c.sh only")
    }

    @Test("checks-s8c.sh defines no check function besides the two, only s8c_ helpers, and no function another kit file already defines")
    func nothingElseDefined() {
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s8c.sh not found"); return }
        let mineFunctions = shellFunctions(in: stripComments(text))
        ok(!mineFunctions.isEmpty, "checks-s8c.sh defines no function")
        let checks = Set(mineFunctions.keys.filter { $0.hasPrefix("check_") })
        ok(checks == Set(ids.map(checkFunctionName)), "checks-s8c.sh defines the check functions \(checks.sorted()), expected check_S8_5 and check_S8_6")
        var others: Set<String> = []
        for (name, code) in kitShellSources() where name != "kit-lib/checks-s8c.sh" {
            others.formUnion(shellFunctions(in: code).keys)
        }
        ok(others.isDisjoint(with: mineFunctions.keys), "checks-s8c.sh redefines \(others.intersection(mineFunctions.keys).sorted()), a name that another kit file defines")
        ok(mineFunctions.keys.allSatisfy { $0.hasPrefix("check_") || $0.hasPrefix("s8c_") }, "a helper of checks-s8c.sh is not named s8c_<name>: \(mineFunctions.keys.filter { !$0.hasPrefix("check_") && !$0.hasPrefix("s8c_") }.sorted())")
    }

    @Test("the header of checks-s8.sh no longer lists S8.5 and S8.6 among the ids with no check, and points at checks-s8c.sh")
    func oldHeaderMoved() {
        guard let raw = read(oldCheckFile) else { Issue.record("scripts/kit-lib/checks-s8.sh not found"); return }
        let header = raw.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n")
        ok(header.contains("checks-s8c.sh"), "the header of checks-s8.sh does not say that S8.5 and S8.6 are in checks-s8c.sh")
        ok(!has(header, #"S8\.5 to S8\.9"#), "the header of checks-s8.sh still says S8.5 to S8.9 have no check here yet")
        ok(!has(header, #"\(S8\.5[^)]*\) have no check"#), "the header of checks-s8.sh still lists S8.5 among the ids that have no check")
    }

    // MARK: both checks

    @Test("each check starts with tree_need <its id>, then `kit-index.sh wait done 900`, then `wait_menu_ready 120`, before it reads or searches anything", arguments: ids)
    func startsWithTheSession(_ id: String) {
        guard let t = own(id), let m = mine(id) else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) }
        ok(first.map { has($0, #"^tree_need[ ]+"?\#(escaped(id))"?([ ;]|$)"#) } ?? false,
           "the first command of \(checkFunctionName(id)) is \(first ?? "nothing"), expected `tree_need \(id)` (t8: it starts the S8 session when run/recipe holds none, and notes the id in run/window-ids while the window is open)")
        ok(has(t, indexWaitDone), "\(checkFunctionName(id)) never runs `kit-index.sh wait done 900`")
        ok(has(t, menuReady), "\(checkFunctionName(id)) never runs `wait_menu_ready 120`")
        before(t, #"\btree_need\b"#, indexWaitDone, "\(checkFunctionName(id)) waits for done before tree_need")
        before(t, indexWaitDone, menuReady, "\(checkFunctionName(id)) waits for the menu before it waited for done")
        for reader in [searchCall, indexHas, indexUnder, indexReasons, dumpSettings, #"\btree_pick_list\b"#, #"gate-matrix\.csv"#, #"kit-fixtures\.sh"#, #"settings_section"#] where has(m, reader) {
            before(m, menuReady, reader, "\(checkFunctionName(id)) reads or searches (\(reader)) before `wait_menu_ready 120`")
        }
    }

    @Test("a check never closes the window: no s8_close_window, no s8_activity, no observer, nothing in run/window-ids or the activity file", arguments: ids)
    func neverClosesTheWindow(_ id: String) {
        guard let m = mine(id) else { return }
        ok(!has(m, #"\bs8_close_window\b"#), "\(checkFunctionName(id)) calls s8_close_window: S8.5 and S8.6 run inside the observed window (t8)")
        ok(!has(m, #"\bs8_activity\b"#), "\(checkFunctionName(id)) calls s8_activity: the 50 searches and 20 opens are not its job")
        ok(!has(m, #"window-ids|observers-closed-at|s8-activity-done|tree_window_note"#), "\(checkFunctionName(id)) writes or reads the window files: tree_need notes the id, only s8_close_window closes the window")
        ok(!has(m, #"kit-trace\.sh"?[ ]+(start|stop)|kit-net\.sh"?[ ]+(start|stop|control)|kit-privacy\.sh"?[ ]+prompts"#), "\(checkFunctionName(id)) starts or stops an observer or the prompts watcher: s8_close_window owns them")
    }

    @Test("an exit 3 of the session or of the menu wait is NEEDS-A-PERSON, any other failure of them a RERUN that returns 4; the verdict lines name the id", arguments: ids)
    func sessionFailuresAreNeverAVerdict(_ id: String) {
        guard let t = own(id) else { return }
        let i = escaped(id)
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+NEEDS-A-PERSON"#), "\(checkFunctionName(id)) never prints `CHECK \(id) NEEDS-A-PERSON` (an exit 3 of the session or of the menu wait)")
        ok(has(t, #"RERUN[ ]+\#(i)[ ]+not valid"#), "\(checkFunctionName(id)) has no `RERUN \(id) not valid: <reason>` line")
        ok(has(t, #"return[ ]+4"#), "\(checkFunctionName(id)) never returns 4 for a precondition that did not hold")
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+PASS"#) && has(t, #"CHECK[ ]+\#(i)[ ]+FAIL"#), "\(checkFunctionName(id)) does not print both `CHECK \(id) PASS` and `CHECK \(id) FAIL`")
        ok(!has(t, #"CHECK[ ]+\#(i)[ ]+SKIPPED"#), "\(checkFunctionName(id)) prints SKIPPED: a check that cannot run is a RERUN or NEEDS-A-PERSON")
        ok(has(t, #"\$\{?(rc|status)\}?|\$\?"#) && has(t, #"\b3\)"#), "\(checkFunctionName(id)) does not branch on the exit status of tree_need (3 is a person step)")
        before(t, #"\btree_need\b"#, #"CHECK[ ]+\#(i)[ ]+PASS"#, "\(checkFunctionName(id)) prints PASS before tree_need")
    }

    @Test("a check only searches the panel: no Enter, no selection, no recipe, no launch, no keys, no typing delay; the only buttons it presses are Settings and its sections", arguments: ids)
    func onlySearchesAndReads(_ id: String) {
        guard let m = mine(id) else { return }
        ok(!has(m, #"--open|--select|--reveal|--copy|--keep-open|--wait-for|--expect-absent"#), "\(checkFunctionName(id)) opens, selects or reveals a result: the 20 Enter opens belong to s8_activity (t8)")
        ok(!has(m, #"kit-run\.sh|osascript|\brecipe_[a-z]+\b|\bpick_folders\b|\bpress_start\b|\bdrive_picker\b"#), "\(checkFunctionName(id)) runs a recipe or drives the picker")
        ok(!has(m, #"kit-launch\.sh"?[ ]+(start|relaunch|quit|stop)"#), "\(checkFunctionName(id)) starts or stops the app")
        ok(!has(m, #"kit-ax\.sh"?[ ]+(type|key|hotkey|paste|tab-walk|gotofolder|appearance|fullscreen)\b"#), "\(checkFunctionName(id)) posts keys or text itself: kit-search.sh does the typing")
        ok(!has(m, #"kit-ax\.sh"?[ ]+click[ ]+"(?!Settings…|\$name|\$1)"#), "\(checkFunctionName(id)) presses a button other than Settings… and a Settings section")
        ok(!has(m, #"keytool|cliclick|CGEvent|key code|keystroke|--delay-ms|KIT_TYPE_DELAY_MS"#), "\(checkFunctionName(id)) posts keys or touches the typing delay: the person's KIT_TYPE_DELAY_MS stands")
        ok(has(m, searchCall), "\(checkFunctionName(id)) never searches (`kit-search.sh \"<text>\"`): the results are read through the panel")
    }

    @Test("no check reads the product's source, every sudo is sudo -n, and checks-s8c.sh never edits a fixture, the index or a setting", arguments: ids)
    func staysClean(_ id: String) {
        guard let e = expanded(id) else { return }
        ok(!e.contains("Sources/") && !has(e, #"\bSources\b"#), "\(checkFunctionName(id)) names the product's source folder: the kit never reads it")
        ok(!has(e, #"\bsudo\b(?![ ]+-n\b)"#), "\(checkFunctionName(id)) calls sudo without -n: the one password prompt of the kit is kit-perms.sh ask-admin")
        guard let file = read(checkFile).map(stripComments) else { return }
        ok(!has(file, #"sqlite3|defaults[ ]+write|plutil[ ]+-(insert|replace|remove)"#), "checks-s8c.sh edits state with sqlite3, defaults or plutil")
        ok(!has(file, #"\brm[ ]+-[a-z]*r|\bmv[ ]|\bcp[ ][^\n]*fixtures|\btouch\b|\bdd[ ]|\bchmod\b|>[ ]*"?[^ "]*fixtures/"#), "checks-s8c.sh removes, moves, changes or writes under the fixtures: S8.5 and S8.6 only read")
    }

    @Test("a check hard-codes no cell of the gate matrix and no expected count: the cells, kinds and counts come from the tables")
    func noHardCodedExpectations() {
        guard let file = read(checkFile).map(stripComments) else { Issue.record("scripts/kit-lib/checks-s8c.sh not found"); return }
        let cells = matrixCellIds()
        ok(cells.count > 40, "gate-matrix.csv has only \(cells.count) cells: the table cannot be read")
        let named = cells.filter { file.contains($0) }
        ok(named.isEmpty, "checks-s8c.sh names the matrix cells \(named.prefix(5)): the cells must come from gate-matrix.csv")
        ok(!has(file, #"\.(png|jpe?g|heic|webp|tiff?|gif|pptx|xlsx|pages|dng|pem|p12|pfx|kdbx)\b"#), "checks-s8c.sh names a file extension: kinds come from extensions.txt and read-kinds.txt, never from a literal")
        ok(!has(file, #"\b(photo|document|pdf|audio|video)\b"#), "checks-s8c.sh names a kind (photo, document, pdf, audio, video): the kinds a reader reads come from read-kinds.txt, so a new reader needs no edit here")
    }

    // MARK: S8.5

    @Test("S8.5: reads the Settings list (`kit-ax.sh dump settings`, Folders) and requires its roots under matrix/ to equal the pick list exactly, before any cell is read")
    func s85Roots() {
        guard let t = own("S8.5"), let m = mine("S8.5") else { return }
        ok(has(m, dumpSettings), "S8.5 never reads the Settings list (`kit-ax.sh dump settings`)")
        ok(has(m, #"settings_section[ ]+"?Folders"?"#), "S8.5 does not put Settings on its Folders section before it reads the list (the rows are in no other section)")
        ok(has(m, #"\btree_pick_list\b[^\n]*gate-matrix\.csv"#), "S8.5 does not take the pick list from tree_pick_list over gate-matrix.csv (the recipe's own pick list)")
        ok(has(m, #"matrix/"#), "S8.5 does not compare the roots under matrix/")
        ok(has(m, #"\bcomm\b"#) || has(m, #"\bdiff\b"#), "S8.5 does not compare the two lists as sets (comm), so an extra or a missing root could pass")
        ok(has(m, #"extra"#) && has(m, #"missing"#), "S8.5 does not name the extra and the missing roots when the list differs")
        ok(t.contains("RERUN S8.5 not valid: picked roots differ from the pick list"), "S8.5 does not print `RERUN S8.5 not valid: picked roots differ from the pick list`")
        before(m, dumpSettings, #"RERUN[ ]+S8\.5[ ]+not valid:[ ]+picked roots differ"#, "S8.5 reports the roots before it read the Settings list")
        before(m, #"RERUN[ ]+S8\.5[ ]+not valid:[ ]+picked roots differ"#, indexHas, "S8.5 reads a cell in the index before it required the picked roots to equal the pick list")
        before(m, #"RERUN[ ]+S8\.5[ ]+not valid:[ ]+picked roots differ"#, searchCall, "S8.5 searches before it required the picked roots to equal the pick list")
        ok(has(t, #"return[ ]+4"#), "S8.5 does not return 4 when the roots differ")
    }

    @Test("S8.5: every cell of gate-matrix.csv of a kind listed in read-kinds.txt: `kit-index.sh has <path>` equals expected_in_index, the name stem and the content token listed exactly expected_rows times")
    func s85Cells() {
        guard let m = mine("S8.5") else { return }
        ok(has(m, #"gate-matrix\.csv"#), "S8.5 never reads scripts/kit-lib/gate-matrix.csv")
        ok(has(m, #"read-kinds\.txt"#), "S8.5 does not take the kinds that have a reader from scripts/kit-lib/read-kinds.txt")
        ok(has(m, #"extensions\.txt"#), "S8.5 does not take the kind of a cell from its extension in scripts/kit-lib/extensions.txt")
        ok(has(m, indexHas), "S8.5 never runs `kit-index.sh has <path>`")
        ok(has(m, searchCall), "S8.5 never searches for a cell (`kit-search.sh`)")
        ok(has(m, #"(?i)zq"#), "S8.5 does not search the unique content token of a picture (the zq token of its name, drawn into it)")
        ok(has(m, #"(?i)\bstem\b"#), "S8.5 does not search the file name stem")
        ok(has(m, #"\brows\b"#), "S8.5 does not count the rows that list the file (the `row <n> ...` lines of kit-search.sh)")
        ok(has(m, #"\bspec\b"#), "S8.5 does not decide on the cells of group spec only")
        ok(has(m, #"IFS=,"#) || has(m, #"-F,"#), "S8.5 does not read the table's comma separated columns")
        before(m, #"\bwait_menu_ready\b"#, #"gate-matrix\.csv"#, "S8.5 reads the table before the menu said Ready")
    }

    @Test("S8.5: cells of kinds with no reader are `SKIPPED-KIND <cell> <kind>` in gate-matrix-result.tsv and not counted; a type no reader reads at all (the bare key extensions) is checked, not skipped")
    func s85SkippedKinds() {
        guard let m = mine("S8.5") else { return }
        ok(has(m, #"SKIPPED-KIND[ ]+%s[ ]+%s|SKIPPED-KIND[ ]+\$"#), "S8.5 never writes `SKIPPED-KIND <cell> <kind>`")
        ok(has(m, #"gate-matrix-result\.tsv"#), "S8.5 never writes gate-matrix-result.tsv")
        ok(has(m, #"kit_evidence_dir"#), "S8.5 does not save gate-matrix-result.tsv under the evidence folder (kit_evidence_dir)")
        ok(has(m, #"\bunsupported\b"#), "S8.5 does not treat a file of no known kind (unsupported) apart: those cells are checked by their own columns, the .pem and the other bare key extensions stay green when the name rule is broken")
        ok(has(m, #"\bcontinue\b"#), "S8.5 does not leave a skipped cell out of the checked ones")
        ok(has(m, #"(?i)skipped"#), "S8.5 never says how many cells were skipped")
    }

    @Test("S8.5: gate-matrix-result.tsv has the columns cell, group, expected in index, expected rows, in index, rows listed, pass")
    func s85Columns() {
        guard let m = mine("S8.5") else { return }
        let columns = ["cell", "group", "expected in index", "expected rows", "in index", "rows listed", "pass"]
        let pattern = columns.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"(?:\\t|\t|,)"#)
        ok(has(m, pattern), "S8.5 writes no header line with the columns \(columns.joined(separator: ", ")) in this order")
        ok(has(m, #"\\t|\t"#), "S8.5 does not write the file tab separated")
    }

    @Test("S8.5: the extra group prints `EXTRA <cell> excluded|read` and never decides the verdict")
    func s85Extra() {
        guard let m = mine("S8.5"), let t = own("S8.5") else { return }
        ok(has(m, #"EXTRA[ ]+%s[ ]+%s|EXTRA[ ]+\$"#), "S8.5 never prints `EXTRA <cell> excluded|read`")
        ok(m.contains("excluded") && has(m, #"\bread\b"#), "S8.5 does not say whether an extra cell is excluded or read")
        ok(has(m, #"\bextra\b"#), "S8.5 does not look at the group column for `extra`")
        // the verdict reads the red cells of group spec only: the list of red cells is never fed by an extra cell
        ok(has(t, #"CHECK[ ]+S8\.5[ ]+FAIL"#), "S8.5 prints no FAIL line")
    }

    @Test("S8.5: every included cell is a positive control: one that the same search does not find is `RERUN S8.5 not valid` (exit 4), never a pass")
    func s85PositiveControl() {
        guard let t = own("S8.5"), let m = mine("S8.5") else { return }
        ok(has(t, #"RERUN[ ]+S8\.5[ ]+not valid:[^\n]*(not found|not listed|found by)"#), "S8.5 has no `RERUN S8.5 not valid: ... not found ...` for an included cell its search does not find")
        ok(has(t, #"return[ ]+4"#), "S8.5 does not return 4 for a broken search")
        ok(has(m, #"(?i)positive control|included"#), "S8.5 does not name the included cells as its positive control")
        guard let rerun = lastIndex(t, #"RERUN[ ]+S8\.5[ ]+not valid:[^\n]*(not found|not listed|found by)"#), let pass = lastIndex(t, #"CHECK[ ]+S8\.5[ ]+PASS"#), let fail = firstIndex(t, #"CHECK[ ]+S8\.5[ ]+FAIL"#) else {
            ok(false, "S8.5 has no RERUN, FAIL or PASS line to order")
            return
        }
        ok(rerun < pass, "S8.5 can print PASS before it checked that every included cell was found")
        ok(rerun < fail, "S8.5 can print FAIL before it checked that every included cell was found (a broken search makes every excluded cell look green)")
    }

    @Test("S8.5 --plant: one expected cell is removed from the index view, the search is left alone, and the check prints `FAIL planted`")
    func s85Plant() {
        guard let t = own("S8.5"), let m = mine("S8.5") else { return }
        ok(has(t, #"KIT_PLANT"#) || has(m, #"KIT_PLANT"#), "S8.5 never looks at KIT_PLANT")
        ok(has(t, #"CHECK[ ]+S8\.5[ ]+FAIL[ ]+planted"#), "S8.5 never prints `CHECK S8.5 FAIL planted: <what>`")
        ok(has(m, #"(?i)index view|removed from the index|planted"#), "S8.5 does not say what its plant removed")
        ok(has(m, #"\bKIT_PLANT\b"#) && has(m, #"inidx=no|in_index=no|=no\b"#), "S8.5's plant does not make one expected cell read as `not in the index`")
        // the plant changes what `has` says, never the index: no write to the index or the fixtures (staysClean) and the file is untouched
        ok(!has(m, #"kit-fixtures\.sh"?[ ]+(mutate|build)"#), "S8.5's plant changes a fixture: it must only change the kit's own reading of the index")
    }

    // MARK: S8.6

    @Test("S8.6: the unsupported files (no reader at all, no extension included) are not in `kit-index.sh has`, not in Settings, not in any result and not in the setup counts")
    func s86Unsupported() {
        guard let m = mine("S8.6"), let t = own("S8.6") else { return }
        ok(has(m, #"tree\.tsv"#), "S8.6 does not take the unsupported files of the tree from scripts/kit-lib/tree.tsv")
        ok(has(m, #"gate-matrix\.csv"#), "S8.6 does not take the unsupported files of the matrix from gate-matrix.csv")
        ok(has(m, #"extensions\.txt"#), "S8.6 does not tell an unsupported file by extensions.txt")
        ok(has(m, #"unsupported"#), "S8.6 does not name the unsupported files")
        ok(has(m, indexHas), "S8.6 never runs `kit-index.sh has <path>` for an unsupported file")
        ok(has(m, dumpSettings), "S8.6 never reads Settings (`kit-ax.sh dump settings`) for the unreadable list")
        ok(has(m, searchCall), "S8.6 never searches for an unsupported file: it must be in no result")
        ok(has(m, expectCounts), "S8.6 never runs `kit-fixtures.sh expect counts` for the folders of the unsupported files")
        ok(has(m, #"IGNORED"#), "S8.6 does not read the IGNORED line of `kit-fixtures.sh expect counts` (the files of unsupported types it leaves out)")
        ok(has(t, #"CHECK[ ]+S8\.6[ ]+FAIL"#), "S8.6 prints no FAIL line")
        for place in ["in the index", "in Settings", "in a result", "counts"] {
            ok(m.contains(place) || t.contains(place), "S8.6 never says \"\(place)\" in a failure: each of the four places must be named")
        }
    }

    @Test("S8.6: an unsupported file never passes by a broken search: a readable cell must be found first, else RERUN S8.6 not valid")
    func s86SearchControl() {
        guard let t = own("S8.6"), let m = mine("S8.6") else { return }
        ok(has(m, #"RERUN[ ]+S8\.6[ ]+not valid:[^\n]*(not found|not listed|found by|control)"#), "S8.6 has no `RERUN S8.6 not valid` for a search that cannot find a readable file (a broken search finds nothing, which would read as green)")
        ok(has(m, #"(?i)positive control|control"#), "S8.6 does not name its positive control")
        before(m, #"RERUN[ ]+S8\.6[ ]+not valid:[^\n]*(not found|not listed|found by|control)"#, #"CHECK[ ]+S8\.6[ ]+PASS"#, "S8.6 prints PASS before it required its control")
        ok(has(t, #"return[ ]+4"#), "S8.6 does not return 4 for a broken search")
    }

    @Test("S8.6: the damaged picture is `could_not_read` in `kit-index.sh reasons` with a reason and listed in Settings with its path")
    func s86Damaged() {
        guard let m = mine("S8.6") else { return }
        ok(has(m, indexReasons), "S8.6 never runs `kit-index.sh reasons`")
        ok(has(m, #"\(no reason\)"#), "S8.6 does not refuse a damaged file whose reason is empty (`kit-index.sh reasons` prints `(no reason)` for it)")
        ok(has(m, #"\bdamaged\b"#), "S8.6 does not name the damaged files")
        ok(has(m, #"broken"#), "S8.6 does not find the damaged files by the table's `broken` names (tree.tsv: damaged/broken.<ext>, gate-matrix.csv: reason could-not-read)")
        ok(has(m, #"could-not-read"#), "S8.6 does not take the damaged cells of the matrix from the table's `could-not-read` reason")
        ok(has(m, #"\breal_path\b|/private"#), "S8.6 does not look for the damaged file's path in Settings in both spellings (/var and /private/var)")
        ok(has(m, dumpSettings), "S8.6 does not read the Settings list for the damaged file's path")
        ok(has(m, #"read-kinds\.txt"#), "S8.6 does not take the damaged files of a kind that has a reader from read-kinds.txt")
        ok(has(m, #"(?i)with its path|its path"#), "S8.6 does not say that Settings must list the damaged file with its path")
    }

    @Test("S8.6: every other picture of tree/damaged and tree/unsupported is done: their number equals `kit-fixtures.sh expect listing` for those two folders (less the damaged ones), and indexing reached Ready")
    func s86Done() {
        guard let m = mine("S8.6"), let t = own("S8.6") else { return }
        ok(has(m, indexUnder), "S8.6 never runs `kit-index.sh under <folder>` to count the done rows")
        ok(has(m, expectListing), "S8.6 never runs `kit-fixtures.sh expect listing <folder>`")
        ok(has(m, #"\bdone\b"#), "S8.6 does not look for the status `done`")
        ok(has(m, #"tree/"#) && has(m, #"\bdamaged\b"#) && has(m, #"\bunsupported\b"#), "S8.6 does not scope the equality to tree/damaged and tree/unsupported (the listing knows only the tree: the index also holds the matrix cells, which S8.5 counts)")
        ok(!has(m, #"kit-index\.sh"?[ ]+under[ ]+"?(damaged|unsupported)\b"#), "S8.6 counts the done rows under damaged/ or unsupported/ of fixtures/, which are no folders: the tree folders are tree/damaged and tree/unsupported")
        ok(has(m, #"read-kinds\.txt"#), "S8.6 does not take the kinds that must be done from read-kinds.txt")
        ok(has(t, #"Ready"#), "S8.6's verdict does not say that indexing reached Ready")
        ok(has(t, #"CHECK[ ]+S8\.6[ ]+PASS"#), "S8.6 prints no PASS line")
        before(t, menuReady, #"CHECK[ ]+S8\.6[ ]+PASS"#, "S8.6 prints PASS before the menu said Ready")
    }

    // MARK: the pure helpers, run as a child shell on hand-written names (no check, no kit script, no app)

    /// Sources checks-s8c.sh in a child bash (only the function definitions run) and calls one helper on hand-written arguments.
    private func helper(_ call: String) throws -> Ran {
        let script = "export KIT_LIB='\(libDir.path)'; . '\(checkFile.path)'; \(call)"
        return try run("/bin/bash", ["-c", script])
    }

    @Test("s8c_kind_of: the kind of a name by the spec's extension lists; a name no list holds, a leading dot alone, or no extension is `unsupported`",
          arguments: [
              ("plain/photo_zq0001.png", "photo"), ("keys/.env.zq0025.png", "photo"), ("keys/id_rsa.zq0022.png", "photo"),
              ("ext/heic_zq0014.HEIC", "photo"), ("keys/id_rsa.zq0021.txt", "document"), ("keys/.env.local.zq0024.md", "document"),
              ("x/tool.PY", "code"), ("a/clip.mp4", "video"), ("a/hum.wav", "audio"), ("a/contract.pdf", "pdf"),
              ("keys/.env_zq0033", "unsupported"), ("keys/id_rsa_zq0032", "unsupported"), ("keys/server_zq0027.pem", "unsupported"),
              ("unsup/raw_zq0074.dng", "unsupported"), ("unsup/README_zq0075", "unsupported"), ("a/archive.tar.gz", "unsupported"),
              ("unsup/deck_zq0071.pptx", "unsupported"),
          ])
    func kindOf(_ name: String, _ kind: String) throws {
        guard FileManager.default.fileExists(atPath: checkFile.path) else { Issue.record("scripts/kit-lib/checks-s8c.sh not found"); return }
        let ran = try helper("s8c_kind_of '\(name)'")
        ok(ran.status == 0, "s8c_kind_of \(name) exited \(ran.status): \(ran.output)")
        ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == kind, "s8c_kind_of \(name) printed \(ran.output.debugDescription), expected \(kind)")
    }

    @Test("s8c_stem and s8c_token: the stem drops one extension and keeps a leading dot; the token is the zq name token, lower case, or nothing",
          arguments: [
              ("a/photo_zq0001.png", "photo_zq0001", "zq0001"), ("a/id_rsa.zq0022.png", "id_rsa.zq0022", "zq0022"),
              ("a/.env.local.zq0026.png", ".env.local.zq0026", "zq0026"), ("a/.env_zq0033", ".env_zq0033", "zq0033"),
              ("a/README_zq0075", "README_zq0075", "zq0075"), ("a/ZQ0042.JPG", "ZQ0042", "zq0042"), ("a/README", "README", ""),
          ])
    func stemAndToken(_ name: String, _ stem: String, _ token: String) throws {
        guard FileManager.default.fileExists(atPath: checkFile.path) else { Issue.record("scripts/kit-lib/checks-s8c.sh not found"); return }
        let s = try helper("s8c_stem '\(name)'")
        ok(s.output.trimmingCharacters(in: .newlines) == stem, "s8c_stem \(name) printed \(s.output.debugDescription), expected \(stem)")
        let t = try helper("s8c_token '\(name)'")
        ok(t.output.trimmingCharacters(in: .newlines) == token, "s8c_token \(name) printed \(t.output.debugDescription), expected \(token.debugDescription)")
    }

    @Test("s8c_lines_naming counts the lines that hold a name as a whole name: README is not README.md, deck.pptx is not old-deck.pptx")
    func linesNaming() throws {
        guard FileManager.default.fileExists(atPath: checkFile.path) else { Issue.record("scripts/kit-lib/checks-s8c.sh not found"); return }
        let rows = "row 1 - README.md | /x/README.md\\nrow 2 selected README | /y\\nrow 3 - old-deck.pptx | /z\\nrow 4 - a deck.pptx b\\nrow 5 - deck.pptx.bak"
        let cases: [(String, String)] = [("README", "1"), ("README.md", "1"), ("old-deck.pptx", "1"), ("deck.pptx", "1"), ("absent.png", "0")]
        for (name, count) in cases {
            let ran = try helper("printf '\(rows)\\n' | s8c_lines_naming '\(name)'")
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == count, "s8c_lines_naming \(name) printed \(ran.output.debugDescription), expected \(count)")
        }
    }

    @Test("S8.6 reads Settings through every section, so the unreadable list is found wherever Settings puts it (four sections: the About tab is removed by decision, guide 16.16)")
    func s86AllSections() {
        guard let m = mine("S8.6") else { return }
        ok(has(m, #"settings_section"#), "S8.6 does not put Settings on a section before it reads its list")
        for section in ["Folders", "File types", "Search", "Indexing"] {
            ok(m.contains(section), "S8.6 does not read the Settings section \(section): the unreadable list may be there")
        }
        ok(!has(m, #"\bAbout\b"#), "S8.6 still names the removed Settings section About: it would stop with \"the Settings section About could not be read\"")
    }

    @Test("checks-s8c.sh does not name About as a Settings section: a text scan of the whole file, comments included; no match is ignored")
    func noAboutSectionInTheFile() {
        let text = read(checkFile) ?? ""
        ok(!text.isEmpty, "scripts/kit-lib/checks-s8c.sh is empty or missing")
        let hits = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().filter { has(String($0.element), #"\bAbout\b"#) }
        ok(hits.isEmpty, "checks-s8c.sh names About on lines \(hits.map { $0.offset + 1 })")
    }

    private func s86Loop(_ settingsSectionBody: String) throws -> Ran {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun8b-s86-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = """
        export KIT_LIB='\(libDir.path)' KIT_SCRIPTS='\(scriptsDir.path)' KIT_ROOT='\(dir.path)'
        . '\(checkFile.path)'
        tree_need() { return 0; }
        kq() { case "$2" in wait) return 0 ;; dump) echo "AXWindow label=\\"Settings\\""; return 0 ;; esac; return 0; }
        wait_menu_ready() { return 0; }
        s8c_settings_open() { return 0; }
        settings_section() { \(settingsSectionBody) }
        s8c_search() { echo "SEARCHED $2"; return 3; }
        check_S8_6; echo "RC $?"
        """
        return try run("/bin/bash", ["-c", script])
    }

    @Test("S8.6 on a Settings window with four sections reads Folders, File types, Search and Indexing in order, then goes on to its positive control: no RERUN, no press of About")
    func s86FourSectionsNormalResult() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun8b-s86-log-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let r = try s86Loop(#"echo "$1" >> '\#(log)'; case "$1" in Folders|"File types"|Search|Indexing) return 0 ;; *) echo "settings_section: \"$1\" is not a Settings section"; return 2 ;; esac"#)
        let presses = (read(URL(fileURLWithPath: log)) ?? "").split(separator: "\n").map(String.init)
        ok(presses == ["Folders", "File types", "Search", "Indexing"], "S8.6 pressed \(presses) in a four-section window")
        ok(!r.output.contains("RERUN S8.6"), "S8.6 was a RERUN on a four-section window: \(r.output.suffix(400))")
        ok(r.output.contains("SEARCHED") && r.output.contains("CHECK S8.6 NEEDS-A-PERSON a search needs a person"), "S8.6 did not read past the Settings sections to its positive control: \(r.output.suffix(400))")
    }

    @Test("S8.6 on a four-section window still stops with RERUN naming the section when one of the four cannot be read (the loop is not loosened)", arguments: ["Folders", "File types", "Search", "Indexing"])
    func s86OneSectionUnreadable(_ broken: String) throws {
        let r = try s86Loop(#"[ "$1" = '\#(broken)' ] && { echo "cannot open"; return 1; }; return 0;"#)
        ok(r.output.contains("RERUN S8.6 not valid: the Settings section \(broken) could not be read") && r.output.contains("RC 4"), "S8.6 with \(broken) unreadable: \(r.output.suffix(400))")
        ok(!r.output.contains("SEARCHED"), "S8.6 went on to its search after \(broken) could not be read")
    }
}

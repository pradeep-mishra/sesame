import Foundation
import Testing

// plan-3-t9, tester step: kit part 5 of 7, the checks S8.1, S8.2 and S8.3 (a new scripts/kit-lib/checks-s8b.sh, sourced by
// scripts/kit-run.sh through its `checks-*.sh` glob). Written from verify.md, the feature map S8, the design and the plan-3-t9
// entry only, with the names the sealed t4 and t8 reports give (`s8_close_window <id>`, `tree_need <id>`, `tree_trace_name`,
// `tree_pick_list`, `run/s8-activity-done`, `run/window-ids`, `run/recipe`, `run/observers-closed-at`, the trace modes `writes`,
// `opens --by` and `by-process`); no product source is read, and no kit function may read `Sources/`.
//
// Static proof only (plan-3-tasks.md, Conventions; the person's ruling "no app launch"): a check needs the app, a trace and the
// session of t8, so NOTHING here runs a check, the recipe, `s8_activity`, `s8_close_window`, `kit-run.sh` or any kit script that
// starts the app or drives its UI. The only runs are `bash -n`. Every other test reads the text of the check files, with their
// comment lines removed (a comment never satisfies a test), either as the function itself ("own": the lines of the function)
// or as the shell would run it ("expanded": every call of a kit function replaced, in place, by that function's code).
// Real behaviour is read at the accept stage only (block C, and block E for S8.1 and S8.2).
//
// The contract read here (plan-3-t9, Tests, and the feature map S8):
//   - `check_S8_1`, `check_S8_2` and `check_S8_3` exist, once each, in checks-s8b.sh; checks.tsv keeps them at slice 3, `auto`;
//     each calls `s8_close_window <its id>` first (so it appends its id to run/window-ids only while the window is open: the
//     check never writes that file itself) and an exit 3 of it is NEEDS-A-PERSON, any other failure a RERUN (exit 4);
//   - S8.1: `kit-sums.sh compare sums-before` (the snapshot the recipe took before Start; the check takes none) prints
//     `UNCHANGED <n> files` and exits 0 for a PASS; any CHANGED, ADDED or REMOVED is a FAIL; a `.DS_Store` line is listed apart,
//     with the process the trace names when a trace ran and with a note when none did; `--plant S8.1` (KIT_PLANT) flips one
//     byte of a picked file keeping size and time, must see it as CHANGED (`FAIL planted`), and puts the byte back;
//   - S8.2: `kit-trace.sh writes <trace from run/recipe> --under <each picked folder>` finds zero writes by Sesame, SesameHelper
//     or git; the positive control is writes by SesameHelper to index.sqlite in Sesame's own folder, and a trace without it is
//     exit 4; `tree -` (no trace) is NEEDS-A-PERSON with the administrator sentence when `sudo -n true` fails and
//     `RERUN S8.2 not valid: prep tree --trace <name> first` when it holds;
//   - S8.3: `kit-trace.sh by-process` and `opens --by Sesame|SesameHelper|git` under each picked folder: zero regular-file opens
//     by the app, the helper's opens passing, the `git` row printed apart and passing, any other process failing; the app's own
//     opens (Sesame's folder, its bundle) listed; positive control `RERUN S8.3 not valid: no helper open of a picked file in the
//     trace`; `opens=0` in run/s8-activity-done is `RERUN S8.3 not valid: no Enter open happened inside the window`; the check
//     presses nothing;
//   - a check that needs the administrator session is NEEDS-A-PERSON when `kit-perms.sh check --for <id>` says so (the runner
//     calls it before each check), and never a PASS.
// Red before the kit part: checks-s8b.sh does not exist and the three ids have no function.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s8b.sh")

private let ids = ["S8.1", "S8.2", "S8.3"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs `/bin/bash -n` (the only program this suite starts).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun8a-out-" + UUID().uuidString)
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

/// `body` with every call to a function of the kit replaced, in place, by that function's own code. Depth is capped.
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

/// The check as the shell would run it: calls and variables written in. Records the reason and returns nil when the function
/// does not exist.
private func expanded(_ id: String) -> String? {
    let functions = allFunctions()
    let name = checkFunctionName(id)
    guard let body = functions[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    return substitute(expandShell(body, functions, skipping: [name]), topLevelValues())
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

// Patterns of a call of a kit script, as the check text holds it after the variables are written in.
private let sumsCompare = #"kit-sums\.sh"?[ ]+compare[ ]+sums-before"#
private let sumsSnapshot = #"kit-sums\.sh"?[ ]+snapshot"#
private let traceWrites = #"kit-trace\.sh"?[ ]+writes"#
private let traceOpens = #"kit-trace\.sh"?[ ]+opens"#
private let traceByProcess = #"kit-trace\.sh"?[ ]+by-process"#

@Suite("KitRunS8aChecksTests")
struct KitRunS8aChecksTests {

    // MARK: syntax and wiring

    @Test("bash -n finds no syntax error in checks-s8b.sh and the runner (neither is run)")
    func bashSyntax() throws {
        for url in [checkFile, scriptsDir.appendingPathComponent("kit-run.sh")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(Comment(rawValue: "\(url.path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", url.path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(url.path) exited \(ran.status): \(ran.output)")
        }
    }

    @Test("the runner sources every scripts/kit-lib/checks-*.sh, so the new file needs no wiring; checks-s8b.sh holds no top-level command")
    func runnerSourcesTheFile() {
        let runner = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) ?? ""
        ok(has(runner, #"checks-\*\.sh"#), "kit-run.sh no longer sources every scripts/kit-lib/checks-*.sh")
        guard let text = read(checkFile) else {
            Issue.record("scripts/kit-lib/checks-s8b.sh not found")
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
        ok(strays.isEmpty, "checks-s8b.sh runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("checks.tsv keeps S8.1, S8.2 and S8.3 once each, at slice 3, kind auto", arguments: ids)
    func registered(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == "3", "\(id) is registered at slice \(row.slice), expected 3")
            ok(row.kind == "auto", "\(id) has kind \(row.kind), expected auto")
        }
    }

    @Test("each of the three ids has exactly one check function, and it is in checks-s8b.sh", arguments: ids)
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
        ok(where_ == ["checks-s8b.sh"], "\(name) is defined in \(where_), expected checks-s8b.sh only")
    }

    @Test("checks-s8b.sh defines no check function besides the three, and no function another kit file already defines")
    func nothingElseDefined() {
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s8b.sh not found"); return }
        let mine = shellFunctions(in: stripComments(text))
        ok(!mine.isEmpty, "checks-s8b.sh defines no function")
        let checks = Set(mine.keys.filter { $0.hasPrefix("check_") })
        ok(checks == Set(ids.map(checkFunctionName)), "checks-s8b.sh defines the check functions \(checks.sorted()), expected check_S8_1, check_S8_2 and check_S8_3")
        var others: Set<String> = []
        for (name, code) in kitShellSources() where name != "kit-lib/checks-s8b.sh" {
            others.formUnion(shellFunctions(in: code).keys)
        }
        ok(others.isDisjoint(with: mine.keys), "checks-s8b.sh redefines \(others.intersection(mine.keys).sorted()), a name that another kit file defines")
        ok(mine.keys.allSatisfy { $0.hasPrefix("check_") || $0.hasPrefix("s8b_") }, "a helper of checks-s8b.sh is not named s8b_<name>: \(mine.keys.filter { !$0.hasPrefix("check_") && !$0.hasPrefix("s8b_") }.sorted())")
    }

    // MARK: every one of the three

    @Test("the first command of each check is `s8_close_window <its id>`; a reader never runs before the window closes", arguments: ids)
    func closesTheWindowFirst(_ id: String) {
        guard let t = own(id) else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) }
        ok(first.map { has($0, #"^s8_close_window[ ]+"?\#(escaped(id))"?([ ;]|$)"#) } ?? false,
           "the first command of \(checkFunctionName(id)) is \(first ?? "nothing"), expected `s8_close_window \(id)` (t8: it closes the observers and the prompts watcher, and notes the id in run/window-ids while they are open)")
        let readers = [sumsCompare, traceWrites, traceOpens, traceByProcess, #"s8-activity-done"#, #"tree_trace_name"#, #"tree_pick_list"#]
        for reader in readers where has(t, reader) {
            before(t, #"s8_close_window"#, reader, "\(checkFunctionName(id)) reads (\(reader)) before it called s8_close_window")
        }
    }

    @Test("an exit 3 of the session is NEEDS-A-PERSON, any other failure of it a RERUN that returns 4; the verdict lines name the id", arguments: ids)
    func sessionFailuresAreNeverAVerdict(_ id: String) {
        guard let t = own(id) else { return }
        let i = escaped(id)
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+NEEDS-A-PERSON"#), "\(checkFunctionName(id)) never prints `CHECK \(id) NEEDS-A-PERSON` (an exit 3 of the session, or no administrator session)")
        ok(has(t, #"RERUN[ ]+\#(i)[ ]+not valid"#), "\(checkFunctionName(id)) has no `RERUN \(id) not valid: <reason>` line")
        ok(has(t, #"return[ ]+4"#), "\(checkFunctionName(id)) never returns 4 for a precondition that did not hold")
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+PASS"#) && has(t, #"CHECK[ ]+\#(i)[ ]+FAIL"#), "\(checkFunctionName(id)) does not print both `CHECK \(id) PASS` and `CHECK \(id) FAIL`")
        ok(!has(t, #"CHECK[ ]+\#(i)[ ]+SKIPPED"#), "\(checkFunctionName(id)) prints SKIPPED: a check that cannot run is a RERUN or NEEDS-A-PERSON")
        ok(has(t, #"\$\{?(rc|status)\}?|\$\?"#) && has(t, #"\b3\)"#), "\(checkFunctionName(id)) does not branch on the exit status of s8_close_window (3 is a person step)")
    }

    @Test("a check never writes run/window-ids, run/observers-closed-at or the activity file itself: only s8_close_window does", arguments: ids)
    func windowIdsAreWrittenOnlyBySession(_ id: String) {
        guard let t = own(id) else { return }
        ok(!has(t, #"window-ids"#), "\(checkFunctionName(id)) names run/window-ids: the id is appended by s8_close_window (t8), only while the window is open")
        ok(!has(t, #"observers-closed-at"#), "\(checkFunctionName(id)) names run/observers-closed-at: only s8_close_window closes the window")
        ok(!has(t, #"tree_window_note|tree_need"#), "\(checkFunctionName(id)) calls tree_need or tree_window_note itself: s8_close_window does")
        ok(!has(t, #">>?[ ]*"?[^ "]*s8-activity-done"#), "\(checkFunctionName(id)) writes run/s8-activity-done")
    }

    @Test("a check presses nothing and starts nothing: no search, no click, no recipe, no launch, no activity of its own", arguments: ids)
    func doesNotDriveTheApp(_ id: String) {
        guard let t = own(id) else { return }
        ok(!has(t, #"kit-search\.sh|kit-ax\.sh|kit-run\.sh|osascript|\bs8_activity\b|\brecipe_[a-z]+\b|\bpick_folders\b|\bpress_start\b"#),
           "\(checkFunctionName(id)) drives the app itself (a search, a click, a recipe or the activity); the window and its 20 Enter opens belong to s8_activity (t8)")
        ok(!has(t, #"kit-launch\.sh"?[ ]+(start|relaunch|quit|stop)"#), "\(checkFunctionName(id)) starts or stops the app")
        ok(!has(t, #"kit-trace\.sh"?[ ]+(start|stop)|kit-net\.sh"?[ ]+(start|stop|control)"#), "\(checkFunctionName(id)) starts or stops an observer: s8_close_window owns them")
        ok(!has(t, #"keytool|cliclick|CGEvent|key code|keystroke|--delay-ms|KIT_TYPE_DELAY_MS"#), "\(checkFunctionName(id)) posts keys or touches the typing delay")
    }

    @Test("no check reads Sources/, every sudo is sudo -n, and a check never edits a picked file outside its plant", arguments: ids)
    func staysClean(_ id: String) {
        guard let t = expanded(id) else { return }
        ok(!t.contains("Sources/") && !has(t, #"\bSources\b"#), "\(checkFunctionName(id)) names Sources: the kit never reads the product's source")
        ok(!has(t, #"\bsudo\b(?![ ]+-n\b)"#), "\(checkFunctionName(id)) calls sudo without -n: the one password prompt of the kit is kit-perms.sh ask-admin")
        guard let file = read(checkFile).map(stripComments) else { return }
        ok(!has(file, #"sqlite3|defaults[ ]+write|plutil[ ]+-(insert|replace|remove)"#), "checks-s8b.sh edits state with sqlite3, defaults or plutil")
        ok(!has(file, #"\brm[ ]+-[a-z]*r|\bmv[ ]|\bcp[ ][^\n]*fixtures|>[ ]*"?[^ "]*fixtures/"#), "checks-s8b.sh removes, moves or writes under the fixtures (the S8.1 plant puts back the one byte it flipped, with dd)")
    }

    @Test("S8.2 and S8.3 need the administrator session: kit-perms.sh maps them to `admin`, and the runner calls it before each check", arguments: ["S8.2", "S8.3"])
    func administratorGate(_ id: String) {
        let perms = read(scriptsDir.appendingPathComponent("kit-perms.sh")).map(stripComments) ?? ""
        ok(has(perms, #"[A-Za-z0-9.|]*\#(escaped(id))[A-Za-z0-9.|]*\)[ ]+echo[ ]+"admin""#), "kit-perms.sh does not map \(id) to the `admin` step")
        let runner = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) ?? ""
        ok(has(runner, #"kit-perms\.sh"?[ ]+check[ ]+--for[ ]+"\$id""#), "kit-run.sh does not call kit-perms.sh check --for before each check")
        before(runner, #"kit-perms\.sh"?[ ]+check[ ]+--for"#, #""\$fn"[ ]+</dev/null"#, "kit-run.sh runs a check before it asked kit-perms.sh whether the person-steps are done")
    }

    // MARK: S8.1

    @Test("S8.1: `kit-sums.sh compare sums-before` after the window closes; the check takes no snapshot (the recipe took it before Start)")
    func s81Compare() {
        guard let t = own("S8.1"), let e = expanded("S8.1") else { return }
        ok(has(t, sumsCompare), "S8.1 never runs `kit-sums.sh compare sums-before`")
        ok(!has(t, sumsSnapshot), "S8.1 takes a snapshot itself: the snapshot is the recipe's, taken before Start indexing, so a snapshot taken here would hide what the session wrote")
        before(e, #"s8_close_window"#, sumsCompare, "S8.1 compares before the window closed (the 50 searches and the 20 opens are part of the session)")
        ok(!has(t, #"(kq|run|bash)[ ]+"?[^ ]*kit-sums\.sh"?[ ]+compare[ ]+(?!sums-before\b)[A-Za-z0-9._-]+"#), "S8.1 compares against a snapshot other than sums-before")
    }

    @Test("S8.1: PASS only on `UNCHANGED <n> files` and exit 0; any CHANGED, ADDED or REMOVED fails; exit 4 (no snapshot) is a RERUN")
    func s81Verdict() {
        guard let t = own("S8.1") else { return }
        for word in ["UNCHANGED", "CHANGED", "ADDED", "REMOVED"] {
            ok(t.contains(word), "S8.1 never names \(word) from kit-sums.sh compare")
        }
        ok(has(t, #"UNCHANGED[ ]+\[0-9\]\+[ ]+files|UNCHANGED [^\n]*files"#), "S8.1 does not look for the line `UNCHANGED <n> files`")
        before(t, #"UNCHANGED"#, #"CHECK[ ]+S8\.1[ ]+PASS"#, "S8.1 prints PASS before it looked for UNCHANGED")
        ok(has(t, #"\$\{?(rc|status)\}?|\$\?"#), "S8.1 does not read the exit status of compare")
        if let cmp = firstIndex(t, sumsCompare), let rerun = lastIndex(t, #"RERUN[ ]+S8\.1[ ]+not valid"#) {
            ok(rerun > cmp, "S8.1 does not turn compare's exit 4 (no snapshot named sums-before) into a RERUN after the comparison")
        } else {
            ok(false, "S8.1 has no RERUN line for compare's exit 4")
        }
        ok(has(t, #"CHECK[ ]+S8\.1[ ]+FAIL"#), "S8.1 prints no FAIL line")
    }

    @Test("S8.1: a .DS_Store is listed apart, with the process the trace names when a trace ran and with a note when none did")
    func s81DSStore() {
        guard let t = own("S8.1") else { return }
        ok(t.contains(".DS_Store"), "S8.1 does not treat a .DS_Store line apart")
        ok(has(t, #"(?i)apart"#), "S8.1 does not say that the .DS_Store lines are listed apart")
        ok(has(t, #"tree_trace_name"#), "S8.1 does not read the trace name from run/recipe (tree_trace_name)")
        ok(has(t, traceWrites), "S8.1 does not ask the trace which process wrote a .DS_Store (`kit-trace.sh writes <trace> --under <the file>`)")
        ok(has(t, #"(?i)\bnote\b[^\n]*no trace|no trace[^\n]*\bnote\b"#), "S8.1 prints no note for a .DS_Store when no trace ran")
        ok(has(t, #"(?i)Finder|Spotlight"#), "S8.1 does not say what else may write a .DS_Store")
        // the entry's words: any CHANGED, ADDED or REMOVED fails; a .DS_Store is listed apart, never dropped from the count
        ok(!has(t, #"(?i)(not counted|ignore[ds]?|skip(ped)?|exempt)[^\n]*DS_Store|DS_Store[^\n]*(not counted|ignored|skipped|exempt)"#), "S8.1 leaves a .DS_Store out of the verdict: any CHANGED, ADDED or REMOVED fails")
    }

    @Test("S8.1: the comparison is saved as sums-after.txt, and the snapshot as sums-before.txt, in the evidence folder")
    func s81Evidence() {
        guard let e = expanded("S8.1") else { return }
        ok(e.contains("sums-after.txt"), "S8.1 does not save the comparison as sums-after.txt (feature map S8, Evidence)")
        ok(e.contains("sums-before.txt"), "S8.1 does not save the snapshot as sums-before.txt")
        ok(has(e, #"kit_evidence_dir"#), "S8.1 does not save under the evidence folder (kit_evidence_dir)")
    }

    @Test("S8.1 --plant: one byte of a picked file is flipped with size and time kept, must be seen as CHANGED (FAIL planted), and is put back")
    func s81Plant() {
        guard let t = own("S8.1"), let e = expanded("S8.1") else { return }
        ok(has(t, #"KIT_PLANT"#), "S8.1 never looks at KIT_PLANT")
        ok(has(t, #"CHECK[ ]+S8\.1[ ]+FAIL[ ]+planted"#), "S8.1 never prints `CHECK S8.1 FAIL planted: <what>`")
        ok(has(e, #"conv=notrunc"#), "the plant does not flip one byte in place (dd conv=notrunc keeps the size)")
        ok(has(e, #"touch[ ]+-r"#), "the plant does not keep the modified time (touch -r), so only the checksum can show it")
        ok(has(e, #"tree_pick_list"#), "the plant does not choose its file among the picked folders (tree_pick_list)")
        if let flip = firstIndex(e, #"conv=notrunc"#), let cmp = firstIndex(e, sumsCompare), let back = lastIndex(e, #"conv=notrunc"#) {
            ok(flip < cmp, "the plant flips the byte after the comparison")
            ok(back > cmp, "the plant never puts the byte back after the comparison (a left-over change would fail the next run)")
        } else {
            ok(false, "the plant has no flip before and no restore after the comparison")
        }
    }

    // MARK: S8.2

    @Test("S8.2: `kit-trace.sh writes <trace> --under <picked folder>` for each picked folder, the trace name read from run/recipe, zero writes by Sesame, SesameHelper or git")
    func s82Writes() {
        guard let t = own("S8.2"), let e = expanded("S8.2") else { return }
        ok(has(t, traceWrites + #"[^\n]*--under"#), "S8.2 never runs `kit-trace.sh writes <trace> --under <folder>`")
        ok(has(e, #"tree_pick_list[^\n]*gate-matrix\.csv"#), "S8.2 does not take the picked folders from tree_pick_list over gate-matrix.csv (the recipe's own pick list)")
        ok(has(t, #"tree_trace_name"#) || has(t, #"run/recipe"#), "S8.2 does not read the trace name from run/recipe")
        ok(has(t, #"\bwhile\b|\bfor\b"#), "S8.2 does not loop over the picked folders")
        for who in ["Sesame", "SesameHelper", "git"] {
            ok(has(t, #"\b\#(who)\b"#), "S8.2 never names \(who) (a write by it under a picked folder fails)")
        }
        ok(has(t, #"\bWRITE\b"#), "S8.2 does not count the `WRITE <process> <op> <path>` lines of kit-trace.sh writes")
        ok(has(t, #"(?i)\.git/index\.lock|git ls-files"#), "S8.2 does not say that git must write nothing either (git ls-files, .git/index.lock)")
        before(e, #"s8_close_window"#, traceWrites, "S8.2 reads the trace before the window closed (the trace is stopped by s8_close_window)")
        ok(has(t, #"CHECK[ ]+S8\.2[ ]+FAIL"#) && has(t, #"CHECK[ ]+S8\.2[ ]+PASS"#), "S8.2 prints no PASS or no FAIL line")
        before(t, traceWrites, #"CHECK[ ]+S8\.2[ ]+PASS"#, "S8.2 prints PASS before it read the trace")
    }

    @Test("S8.2: the positive control is a write by SesameHelper to index.sqlite in Sesame's own folder; a trace without it is exit 4")
    func s82PositiveControl() {
        guard let t = own("S8.2"), let e = expanded("S8.2") else { return }
        ok(has(t, traceWrites + #"[^\n]*--by[ ]+SesameHelper"#), "S8.2 does not read the writes by SesameHelper (`kit-trace.sh writes <trace> --under <Sesame's folder> --by SesameHelper`)")
        ok(has(t, #"index\.sqlite"#), "S8.2 does not look for index.sqlite as its positive control")
        ok(has(e, #"kit-launch\.sh"?[ ]+where"#), "S8.2 does not find Sesame's own folder with `kit-launch.sh where`")
        ok(has(t, #"RERUN[ ]+S8\.2[ ]+not valid"#), "S8.2 has no RERUN for a trace that shows no write to the index")
        ok(has(t, #"(?i)positive control"#), "S8.2 does not name its positive control in its RERUN line")
        ok(has(t, #"return[ ]+4"#), "S8.2 does not return 4 for an invalid trace")
        // a control seen in the trace must not turn a found write into a pass, and a missing control must not turn silence into one
        guard let pass = lastIndex(t, #"CHECK[ ]+S8\.2[ ]+PASS"#), let control = firstIndex(t, #"index\.sqlite"#) else { return }
        ok(control < pass, "S8.2 can print PASS before it looked at the positive control")
    }

    @Test("S8.2: `tree -` (no trace) is NEEDS-A-PERSON with the administrator sentence when sudo -n true fails, and `RERUN S8.2 not valid: prep tree --trace <name> first` when it holds")
    func s82NoTrace() {
        guard let t = own("S8.2"), let e = expanded("S8.2") else { return }
        ok(has(t, #"-z[ ]+"\$[a-z_]+""#) || has(t, #"-n[ ]+"\$[a-z_]+"[ ]+\][ ]+\|\|"#), "S8.2 does not look at whether the trace name is empty (run/recipe `tree -` has none)")
        before(e, #"s8_close_window"#, #"(?s)sudo[ ]+-n[ ]+true.{0,400}?RERUN[ ]+(S8\.2|\$1)[ ]+not valid:[ ]+prep tree --trace"#, "S8.2 does not test the administrator session with `sudo -n true` (it never asks for a password) before it names the missing trace")
        ok(has(e, #"NEEDS A PERSON: administrator rights"#), "S8.2 does not print the administrator sentence (`NEEDS A PERSON: administrator rights ...`)")
        ok(has(e, #"CHECK[ ]+(S8\.2|\$1)[ ]+NEEDS-A-PERSON"#), "S8.2 does not print `CHECK S8.2 NEEDS-A-PERSON` when no administrator session is primed")
        ok(has(e, #"RERUN[ ]+(S8\.2|\$1)[ ]+not valid:[ ]+prep tree --trace"#), "S8.2 does not print `RERUN S8.2 not valid: prep tree --trace <name> first` when the session is primed but no trace ran")
        ok(has(e, #"run scripts/kit-perms\.sh ask-admin"#), "S8.2 does not tell the person to run kit-perms.sh ask-admin")
        ok(!has(t, #"kit-perms\.sh"?[ ]+ask-admin|admin_session"#) && !has(e, #"\bsudo\b(?![ ]+-n\b)"#), "S8.2 asks for the password itself: only the recipe and kit-perms.sh do")
    }

    // MARK: S8.3

    @Test("S8.3: by-process, then regular-file opens under each picked folder by Sesame (the app), SesameHelper and git, listed apart")
    func s83Processes() {
        guard let t = own("S8.3"), let e = expanded("S8.3") else { return }
        ok(has(t, traceByProcess), "S8.3 never runs `kit-trace.sh by-process <trace>`")
        ok(has(t, traceOpens + #"[^\n]*--under[^\n]*--by"#), "S8.3 never runs `kit-trace.sh opens <trace> --under <folder> --by <process>`")
        ok(has(e, #"tree_pick_list[^\n]*gate-matrix\.csv"#), "S8.3 does not take the picked folders from tree_pick_list over gate-matrix.csv")
        ok(has(t, #"tree_trace_name"#) || has(t, #"run/recipe"#), "S8.3 does not read the trace name from run/recipe")
        ok(has(t, #"\bfor[ ]+\w+[ ]+in\b[^\n]*\bSesame\b[^\n]*\bSesameHelper\b[^\n]*\bgit\b"#) || (has(t, #"--by[ ]+"?Sesame"?\b"#) && has(t, #"--by[ ]+"?SesameHelper"?"#) && has(t, #"--by[ ]+"?git"?"#)),
           "S8.3 does not read the opens of each of Sesame, SesameHelper and git")
        ok(has(t, #"regular[ ]+files"#), "S8.3 does not read the `regular files:` line of kit-trace.sh opens (directories are counted apart)")
        ok(has(t, #"(?i)\bgit\b[^\n]*(apart|never counted|listed)|(apart|listed)[^\n]*\bgit\b"#), "S8.3 does not print the git row apart")
        ok(has(t, #"(?i)other[^\n]*process|process[^\n]*other"#), "S8.3 does not fail any other process")
        before(e, #"s8_close_window"#, traceOpens, "S8.3 reads the opens before the window closed")
        before(t, traceOpens, #"CHECK[ ]+S8\.3[ ]+PASS"#, "S8.3 prints PASS before it read the opens")
        ok(has(t, #"CHECK[ ]+S8\.3[ ]+FAIL"#), "S8.3 prints no FAIL line")
    }

    @Test("S8.3: the app's opens of Sesame's folder (settings, models, the index) and of its bundle are listed")
    func s83AppOwnOpens() {
        guard let t = own("S8.3"), let e = expanded("S8.3") else { return }
        ok(has(e, #"kit-launch\.sh"?[ ]+where"#), "S8.3 does not find Sesame's own folder (`kit-launch.sh where`)")
        ok(has(e, #"s8_bundle"#), "S8.3 does not find the app bundle (s8_bundle)")
        ok(has(t, traceOpens + #"[^\n]*--by[ ]+"?Sesame"?([ ]|$)"#), "S8.3 does not list the opens by the app (`opens <trace> --under <folder> --by Sesame`)")
        ok(has(t, #"(?i)settings|models|its own|bundle"#), "S8.3 does not say what the listed opens are")
    }

    @Test("S8.3: positive control `RERUN S8.3 not valid: no helper open of a picked file in the trace` (exit 4); a git-only or helper-less trace never passes")
    func s83PositiveControl() {
        guard let t = own("S8.3") else { return }
        ok(t.contains("RERUN S8.3 not valid: no helper open of a picked file in the trace"), "S8.3 does not print `RERUN S8.3 not valid: no helper open of a picked file in the trace`")
        ok(has(t, #"return[ ]+4"#), "S8.3 does not return 4 when the helper's open is missing")
        guard let pass = lastIndex(t, #"CHECK[ ]+S8\.3[ ]+PASS"#), let control = firstIndex(t, #"no helper open of a picked file"#) else {
            ok(false, "S8.3 has no PASS or no positive control")
            return
        }
        ok(control < pass, "S8.3 can print PASS before it required a helper open of a picked file")
        ok(has(t, #"\bgit\b"#) && !has(t, #"(?i)git[^\n]*(counts? as|is|are) (the )?(helper|control)"#), "S8.3 lets git count as the helper's open")
    }

    @Test("S8.3: `opens=0` in run/s8-activity-done is `RERUN S8.3 not valid: no Enter open happened inside the window`; the check presses nothing")
    func s83EnterOpens() {
        guard let t = own("S8.3") else { return }
        ok(t.contains("s8-activity-done"), "S8.3 never reads run/s8-activity-done")
        ok(has(t, #"opens="#), "S8.3 does not read the opens= field of run/s8-activity-done")
        ok(t.contains("RERUN S8.3 not valid: no Enter open happened inside the window"), "S8.3 does not print `RERUN S8.3 not valid: no Enter open happened inside the window`")
        before(t, #"no Enter open happened inside the window"#, traceOpens, "S8.3 reads the opens in the trace before it checked that an Enter open happened")
        ok(!has(t, #"--open|--select|Command\+Return|Command-Return|key code 36"#), "S8.3 presses Enter or Command+Enter itself: the 20 opens are s8_activity's")
    }
}

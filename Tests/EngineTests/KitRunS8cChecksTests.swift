import Foundation
import Testing

// plan-3-t11, tester step: kit part 7 of 7, the checks S8.7, S8.9, S8.10 (the tcc and prompts parts) and S8.13 (a new
// scripts/kit-lib/checks-s8d.sh holds check_S8_7, check_S8_9 and the shell function s8_net_summary; check_S8_10 and check_S8_13 are
// edited where they stand, in scripts/kit-lib/checks-s8.sh). Written from verify.md, the feature map S8, the design and the plan-3-t11
// entry only, with the names the sealed t4, t5, t6, t8, t9 and t10 reports give (`kit-net.sh summary`, `kit-trace.sh net`,
// `kit-privacy.sh query-scan|schema-scan|tcc|prompts result`, `s8_close_window <id>`, `tree_trace_name`, `run/s8-activity-done`,
// `run/observers-closed-at`, `run/window-ids`, `run/net/<name>.plants`, `run/markers.txt`, `order-*.txt`); no product source is read, and
// no kit function may read it.
//
// Static proof only (plan-3-tasks.md, Conventions; the person's ruling "no app launch"): a check needs the app, the S8 session of t8, the
// two network observers and the administrator session, so NOTHING here runs a check, the recipe, `kit-run.sh`, `kit-net.sh`,
// `kit-trace.sh`, `kit-privacy.sh` or any kit script that starts the app. The runs are `bash -n` and the pure helpers of checks-s8d.sh,
// sourced in a child bash and called on hand-written files in a temp KIT_ROOT (the expected values are written in this file). Every other
// test reads the text of the check files with their comment lines removed (a comment never satisfies a test): as the function itself
// ("own"), as the function with its own file's helpers written in ("mine": a call of an `s8d_` function replaced, in place, by that
// function's code) or as the shell would run it ("expanded": every call of a kit function replaced). Real behaviour is read at the
// accept stage only (block C).
//
// The contract read here (plan-3-t11, Tests, and the feature map S8):
//   - `s8_net_summary [<id>]` is the body of S8.7 and the net part of S8.13 (t12's S6.13 calls it too): it calls `s8_close_window <id>`,
//     then `kit-net.sh summary <trace> --mirror <host:port> --requests <the mirror log>` and `kit-trace.sh net <trace> --except <mirror>`
//     on the closed window, saves both, once (a second call reads the saved result). It returns 0 clean, 1 a product failure, 3 a person
//     step, 4 not valid; it prints no `CHECK` line (the runner reads the first `CHECK <id>` line of a check);
//   - `check_S8_7`: one `s8_net_summary` call plus its validity rules: exit 4 (`RERUN S8.7 not valid`) when the plants file does not hold
//     exactly three plants, plant 2 is not earlier than `indexing-done-at`, plant 3 is not later than `last-open-at`, or
//     `run/observers-closed-at` is earlier than `last-open-at`; it prints `ids run in the window: <list>` and says the runs used the
//     mirror; it fails on a destination other than the mirror, a connection outside the mirror log's window plus 2 s, 1,000,000 bytes sent
//     or a connection after the last model request;
//   - `check_S8_9`: `s8_close_window` first, then `kit-privacy.sh query-scan markers.txt`, `schema-scan`, the empty `kit-index.sh diff
//     before-opens after-opens`, and the three order lists identical row for row, `order-before.txt` with at least 3 rows, else
//     `RERUN S8.9 not valid: the order test list is shorter than 3 rows`;
//   - `check_S8_10`: from slice 3, `s8_close_window` first, `kit-privacy.sh tcc` (exit 3 is NEEDS-A-PERSON naming the tcc part) and
//     `kit-privacy.sh prompts result s8` (exit 1 FAIL, exit 0 prints what was seen, exit 4 `RERUN S8.10 not valid: no prompts watcher ran
//     in this session`, never a pass); the plist and entitlements parts stay;
//   - `check_S8_13`: from slice 3 no `partial` note: the logs part reads S8.9's scan result, the net part reads S8.7's summary through
//     `s8_net_summary`, and PASS only when both ran in the same session, else `RERUN S8.13 not valid`.
// Red before the kit part: checks-s8d.sh does not exist, the two ids and `s8_net_summary` have no function, and S8.10 and S8.13 lack
// their parts.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s8d.sh")
private let oldCheckFile = libDir.appendingPathComponent("checks-s8.sh")

private let ids = ["S8.7", "S8.9", "S8.10", "S8.13"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs a program and collects its output (this suite starts only /bin/bash: `-n`, and `-c` on the pure helpers).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun8c-out-" + UUID().uuidString)
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

/// The code of the check (or of any other kit function) as it stands, variables written in; records the reason and returns nil
/// when the function does not exist.
private func own(_ name: String) -> String? {
    guard let body = allFunctions()[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    return substitute(body, topLevelValues())
}

private func ownCheck(_ id: String) -> String? { own(checkFunctionName(id)) }

/// The check as the shell would run it: every kit function and variable written in.
private func expanded(_ id: String) -> String? {
    let functions = allFunctions()
    let name = checkFunctionName(id)
    guard let body = functions[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    return substitute(expandShell(body, functions, skipping: [name]), topLevelValues())
}

/// The check with only the helpers of checks-s8d.sh (functions named `s8d_...`) written in; a call of a function of another kit file
/// (s8_close_window, s8_net_summary, tree_need) stays a call, so it never brings the session's or the summary's code into the text.
private func mine(_ id: String) -> String? {
    let all = allFunctions()
    let name = checkFunctionName(id)
    guard let body = all[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    let helpers = all.filter { $0.key.hasPrefix("s8d_") }
    return substitute(expandShell(body, helpers, skipping: [name]), topLevelValues())
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
private let privacyCall = #"kit-privacy\.sh"?[ ]+"#
private let netSummaryCall = #"kit-net\.sh"?[ ]+summary\b"#
private let traceNetCall = #"kit-trace\.sh"?[ ]+net\b"#
private let observerControl = #"kit-trace\.sh"?[ ]+(start|stop)\b|kit-net\.sh"?[ ]+(start|stop|control)\b|kit-privacy\.sh"?[ ]+prompts[ ]+(start|stop)\b"#

@Suite("KitRunS8cChecksTests")
struct KitRunS8cChecksTests {

    // MARK: syntax and wiring

    @Test("bash -n finds no syntax error in checks-s8d.sh, checks-s8.sh and the runner (none is run)")
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

    @Test("the runner sources every scripts/kit-lib/checks-*.sh, so the new file needs no wiring; checks-s8d.sh and checks-s8.sh hold no top-level command", arguments: ["checks-s8d.sh", "checks-s8.sh"])
    func runnerSourcesTheFile(_ file: String) {
        let runner = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) ?? ""
        ok(has(runner, #"checks-\*\.sh"#), "kit-run.sh no longer sources every scripts/kit-lib/checks-*.sh")
        guard let text = read(libDir.appendingPathComponent(file)) else {
            Issue.record(Comment(rawValue: "scripts/kit-lib/\(file) not found"))
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
        ok(strays.isEmpty, "\(file) runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("checks.tsv keeps S8.7 and S8.9 at slice 3 and S8.10 and S8.13 at slice 1, once each, all auto",
          arguments: [("S8.7", "3"), ("S8.9", "3"), ("S8.10", "1"), ("S8.13", "1")])
    func registered(_ id: String, _ slice: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == slice, "\(id) is registered at slice \(row.slice), expected \(slice)")
            ok(row.kind == "auto", "\(id) has kind \(row.kind), expected auto")
        }
    }

    @Test("each function is defined once in the kit: the two new checks and s8_net_summary in checks-s8d.sh, the two edited checks in checks-s8.sh",
          arguments: [("check_S8_7", "checks-s8d.sh"), ("check_S8_9", "checks-s8d.sh"), ("s8_net_summary", "checks-s8d.sh"),
                      ("check_S8_10", "checks-s8.sh"), ("check_S8_13", "checks-s8.sh")])
    func exactlyOneFunction(_ name: String, _ file: String) {
        var total = 0
        var where_: [String] = []
        for (source, code) in kitShellSources() {
            let n = code.split(separator: "\n").filter { $0.hasPrefix("\(name)() {") }.count
            total += n
            if n > 0 { where_.append(source) }
        }
        ok(total == 1, "\(name) is defined \(total) times in the kit (\(where_.joined(separator: ", "))), expected once")
        ok(where_ == ["kit-lib/\(file)"], "\(name) is defined in \(where_), expected kit-lib/\(file) only")
    }

    @Test("checks-s8d.sh defines the two checks, s8_net_summary and s8d_ helpers only, no function another kit file defines, and never an s8c_ name of t10")
    func nothingElseDefined() {
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s8d.sh not found"); return }
        let mineFunctions = shellFunctions(in: stripComments(text))
        ok(!mineFunctions.isEmpty, "checks-s8d.sh defines no function")
        let checks = Set(mineFunctions.keys.filter { $0.hasPrefix("check_") })
        ok(checks == ["check_S8_7", "check_S8_9"], "checks-s8d.sh defines the check functions \(checks.sorted()), expected check_S8_7 and check_S8_9")
        var others: Set<String> = []
        for (name, code) in kitShellSources() where name != "kit-lib/checks-s8d.sh" {
            others.formUnion(shellFunctions(in: code).keys)
        }
        ok(others.isDisjoint(with: mineFunctions.keys), "checks-s8d.sh redefines \(others.intersection(mineFunctions.keys).sorted()), a name that another kit file defines")
        ok(mineFunctions.keys.allSatisfy { $0.hasPrefix("check_") || $0.hasPrefix("s8d_") || $0 == "s8_net_summary" },
           "a function of checks-s8d.sh is not check_<id>, s8d_<name> or s8_net_summary: \(mineFunctions.keys.filter { !$0.hasPrefix("check_") && !$0.hasPrefix("s8d_") && $0 != "s8_net_summary" }.sorted())")
        let s8cNames = Set(shellFunctions(in: stripComments(read(libDir.appendingPathComponent("checks-s8c.sh")) ?? "")).keys.filter { $0.hasPrefix("s8c_") })
        ok(!s8cNames.isEmpty, "checks-s8c.sh defines no s8c_ helper (t10 is sealed and holds them)")
        let oldFunctions = Set(shellFunctions(in: stripComments(read(oldCheckFile) ?? "")).keys)
        ok(s8cNames.isDisjoint(with: mineFunctions.keys) && s8cNames.isDisjoint(with: oldFunctions), "checks-s8d.sh or checks-s8.sh redefines an s8c_ name of t10: \(s8cNames.intersection(mineFunctions.keys).union(s8cNames.intersection(oldFunctions)).sorted())")
    }

    @Test("the header of checks-s8.sh points S8.7 and S8.9 at checks-s8d.sh and no longer lists them among the ids with no check")
    func oldHeaderMoved() {
        guard let raw = read(oldCheckFile) else { Issue.record("scripts/kit-lib/checks-s8.sh not found"); return }
        let header = raw.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n")
        ok(header.contains("checks-s8d.sh"), "the header of checks-s8.sh does not say that S8.7 and S8.9 are in checks-s8d.sh")
        ok(header.contains("checks-s8c.sh"), "the header of checks-s8.sh lost its pointer to checks-s8c.sh (the t10 test pins it)")
        ok(!has(header, #"S8\.7, S8\.8, S8\.9"#), "the header of checks-s8.sh still lists S8.7, S8.8, S8.9 as ids with no check")
        ok(!has(header, #"\(S8\.7[^)]*S8\.9\) have no check"#), "the header of checks-s8.sh still says S8.7 and S8.9 have no check")
    }

    // MARK: s8_net_summary

    @Test("s8_net_summary [<id>] calls s8_close_window first, then a saved result is read once more, else kit-net.sh summary and kit-trace.sh net run on the closed window")
    func netSummaryOrder() {
        guard let t = own("s8_net_summary") else { return }
        ok(has(t, #"\bs8_close_window\b[ ]+"?\$"#), "s8_net_summary does not pass its id to s8_close_window (it takes <id>, the id of the check that calls it)")
        ok(has(t, netSummaryCall), "s8_net_summary never runs `kit-net.sh summary`")
        ok(has(t, traceNetCall), "s8_net_summary never runs `kit-trace.sh net`")
        before(t, #"\bs8_close_window\b"#, #"\bs8d_load\b"#, "s8_net_summary reads a saved result before it closed the window")
        before(t, #"\bs8d_load\b[ ]+s8-net-summary"#, netSummaryCall, "s8_net_summary runs `kit-net.sh summary` again although a saved result may exist (once: a second call reads the saved result)")
        before(t, #"\bs8d_load\b[ ]+s8-net-summary"#, traceNetCall, "s8_net_summary runs `kit-trace.sh net` again although a saved result may exist")
        before(t, #"\bs8_close_window\b"#, netSummaryCall, "s8_net_summary reads the summary before the window was closed")
        ok(has(t, #"\bs8d_save\b[ ]+s8-net-summary"#), "s8_net_summary never saves its result (the second call and S8.13 read it)")
        ok(has(t, #"S8_NET_TEXT"#), "s8_net_summary leaves its text in no variable for its callers (S8.7 and S8.13 name the failing lines from it)")
    }

    @Test("s8_net_summary runs the summary with the mirror's address and request log and the trace with --except the mirror; both are saved to the evidence folder")
    func netSummaryArguments() {
        guard let t = own("s8_net_summary") else { return }
        ok(has(t, #"kit-net\.sh"?[ ]+summary[^\n]*--mirror[ ]+"?\$\{?mirror[^\n]*--requests"#), "s8_net_summary does not run `kit-net.sh summary <name> --mirror <host:port> --requests <mirror log>`")
        ok(has(t, traceNetCall + #"[^\n]*--except[ ]+"?\$\{?mirror"#), "s8_net_summary does not run `kit-trace.sh net <name> --except <mirror>`")
        ok(has(t, #"mirror-host"#), "s8_net_summary does not read the mirror's address from run/mirror-host")
        ok(has(t, #"mirror-requests\.log"#), "s8_net_summary does not give the mirror's request log (run/mirror-requests.log)")
        ok(has(t, #"\btree_trace_name\b"#), "s8_net_summary does not take the trace name from run/recipe (tree_trace_name)")
        ok(has(t, #"kit_evidence_dir"#), "s8_net_summary does not save under the evidence folder (kit_evidence_dir)")
        ok(has(t, #"trace-net-"#), "s8_net_summary does not save the network trace as trace-net-<name>.txt (verify.md, Evidence)")
        ok(has(t, #"\bs8d_net_status\b"#), "s8_net_summary does not decide its exit status with s8d_net_status")
        ok(has(t, #"\bs8d_destinations\b"#), "s8_net_summary does not count the destinations `kit-trace.sh net` lists (a NET line is a destination other than the mirror)")
    }

    @Test("s8_net_summary: no trace (run/recipe holds `tree -`) is exit 3 with the administrator sentence when sudo -n true fails, else exit 4; it prints no CHECK line and starts or stops no observer")
    func netSummaryEdges() {
        guard let t = own("s8_net_summary") else { return }
        ok(has(t, #"sudo[ ]+-n[ ]+true"#), "s8_net_summary does not tell a missing administrator session (sudo -n true) from a trace that was never started")
        ok(has(t, #"NEEDS A PERSON: administrator rights"#), "s8_net_summary does not say plainly, with `NEEDS A PERSON: administrator rights`, what the person must do")
        ok(has(t, #"return[ ]+3"#), "s8_net_summary never returns 3 (a person step)")
        ok(has(t, #"return[ ]+4"#), "s8_net_summary never returns 4 (the run is not valid)")
        ok(has(t, #"RERUN[ ]+\$"#), "s8_net_summary does not print `RERUN <id> not valid` with the id it was given")
        ok(has(t, #"prep tree --trace s8"#), "s8_net_summary does not tell a run without a trace to `prep tree --trace s8`")
        ok(!has(t, #"\bCHECK[ ]"#), "s8_net_summary prints a CHECK line: it is not a check, the runner reads the first `CHECK <id>` line of each check")
        ok(!has(t, observerControl), "s8_net_summary starts or stops an observer or the prompts watcher: s8_close_window owns them")
        ok(!has(t, #"kit-search\.sh|kit-ax\.sh|osascript|\brecipe_[a-z]+\b|kit-launch\.sh"?[ ]+(start|relaunch|quit|stop)"#), "s8_net_summary drives the app")
    }

    // MARK: S8.7

    @Test("S8.7 is one s8_net_summary call plus its validity rules: s8_net_summary first, 3 is NEEDS-A-PERSON, 4 a RERUN that returns 4, 0 and 1 go on")
    func s87Starts() {
        guard let t = ownCheck("S8.7") else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) }
        ok(first.map { has($0, #"^s8_net_summary[ ]+"?S8\.7"?([ ;]|$)"#) } ?? false, "the first command of check_S8_7 is \(first ?? "nothing"), expected `s8_net_summary S8.7`")
        ok(has(t, #"CHECK[ ]+S8\.7[ ]+NEEDS-A-PERSON"#), "check_S8_7 never prints `CHECK S8.7 NEEDS-A-PERSON` (an exit 3 of s8_net_summary)")
        ok(has(t, #"RERUN[ ]+S8\.7[ ]+not valid"#), "check_S8_7 has no `RERUN S8.7 not valid: <reason>` line")
        ok(has(t, #"return[ ]+4"#), "check_S8_7 never returns 4")
        ok(has(t, #"CHECK[ ]+S8\.7[ ]+PASS"#) && has(t, #"CHECK[ ]+S8\.7[ ]+FAIL"#), "check_S8_7 does not print both `CHECK S8.7 PASS` and `CHECK S8.7 FAIL`")
        ok(!has(t, #"CHECK[ ]+S8\.7[ ]+SKIPPED"#), "check_S8_7 prints SKIPPED: a check that cannot run is a RERUN or NEEDS-A-PERSON")
        ok(has(t, #"\$\{?(rc|status)\}?|\$\?"#) && has(t, #"\b3\)"#), "check_S8_7 does not branch on the exit status of s8_net_summary (3 is a person step)")
        ok(has(t, #"\b0\|1\)|\b1\|0\)"#) || has(t, #"\b1\)"#), "check_S8_7 does not let a product failure (exit 1) through to its own verdict")
        before(t, #"\bs8_net_summary\b"#, #"CHECK[ ]+S8\.7[ ]+PASS"#, "check_S8_7 prints PASS before s8_net_summary")
    }

    @Test("S8.7 validity: not exactly three plants, plant 2 not earlier than indexing-done-at, plant 3 not later than last-open-at, observers-closed-at earlier than last-open-at: RERUN (exit 4), before any verdict")
    func s87Validity() {
        guard let t = ownCheck("S8.7"), let m = mine("S8.7") else { return }
        ok(has(m, #"run/net/\$\{?trace\}?\.plants|\.plants"#), "check_S8_7 does not read run/net/<name>.plants")
        ok(has(m, #"s8-activity-done"#), "check_S8_7 does not read run/s8-activity-done (indexing-done-at, last-open-at)")
        ok(has(m, #"observers-closed-at"#), "check_S8_7 does not read run/observers-closed-at")
        ok(has(m, #"indexing-done-at"#) && has(m, #"last-open-at"#), "check_S8_7 does not compare the plants with indexing-done-at and last-open-at")
        ok(has(t, #"\bs8d_window_order\b"#), "check_S8_7 does not apply the validity rules (s8d_window_order)")
        ok(has(t, #"RERUN[ ]+S8\.7[ ]+not valid:[ ]+\$"#), "check_S8_7 does not print the reason of a failed validity rule after `RERUN S8.7 not valid:`")
        before(t, #"\bs8d_window_order\b"#, #"CHECK[ ]+S8\.7[ ]+FAIL"#, "check_S8_7 can print FAIL before it applied the validity rules (a run that is not valid proves nothing, FAIL included)")
        before(t, #"\bs8d_window_order\b"#, #"CHECK[ ]+S8\.7[ ]+PASS"#, "check_S8_7 can print PASS before it applied the validity rules")
    }

    @Test("S8.7 prints `ids run in the window: <list>` from run/window-ids, and says the runs used the mirror (the one real-host run is a person-run, S8.N5)")
    func s87Evidence() {
        guard let t = ownCheck("S8.7") else { return }
        ok(t.contains("ids run in the window:"), "check_S8_7 never prints `ids run in the window: <list>`")
        ok(has(t, #"window-ids"#), "check_S8_7 does not read run/window-ids")
        ok(has(t, #"used the (model )?mirror"#), "check_S8_7 does not say that the runs used the mirror")
        ok(has(t, #"S8\.N5|real host"#), "check_S8_7 does not say that the real host is a person-run (S8.N5)")
        before(t, #"ids run in the window:"#, #"CHECK[ ]+S8\.7[ ]+(PASS|FAIL)"#, "check_S8_7 prints its verdict before `ids run in the window:`")
    }

    @Test("S8.7 fails on a destination other than the mirror, a connection outside the mirror log's window, 1,000,000 bytes sent and a connection after the last model request, naming the lines")
    func s87Fails() {
        guard let t = ownCheck("S8.7"), let m = mine("S8.7") else { return }
        ok(has(m, #"\bs8d_failure_lines\b|PRODUCT"#) && has(m, #"AFTER-LAST"#), "check_S8_7 does not take the failing lines (PRODUCT, OUTSIDE, AFTER-LAST, BYTES and the NET lines of the trace) from the summary")
        ok(has(m, #"OUTSIDE"#) && has(m, #"BYTES"#), "check_S8_7 does not name the OUTSIDE and BYTES failures of the summary")
        ok(has(t, #"S8_NET_TEXT"#), "check_S8_7 does not read the summary text s8_net_summary left")
        ok(has(t, #"CHECK[ ]+S8\.7[ ]+FAIL[^\n]*(destination|connection)"#), "check_S8_7's FAIL line does not say what failed (a destination, a connection)")
        ok(has(t, #"return[ ]+1"#), "check_S8_7 never returns 1 for a failure")
        ok(has(m, #"\bSENT\b"#), "check_S8_7 does not report the bytes sent (the `SENT <n>` line)")
        ok(has(m, #"seen-by|PLANT"#), "check_S8_7 does not report which observer saw each planted connection")
    }

    // MARK: S8.9

    @Test("S8.9 starts with s8_close_window, an exit 3 is NEEDS-A-PERSON, any other failure a RERUN that returns 4")
    func s89Starts() {
        guard let t = ownCheck("S8.9") else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) }
        ok(first.map { has($0, #"^s8_close_window[ ]+"?S8\.9"?([ ;]|$)"#) } ?? false, "the first command of check_S8_9 is \(first ?? "nothing"), expected `s8_close_window S8.9` (so the 50 searches and the 20 opens are in the window)")
        ok(has(t, #"CHECK[ ]+S8\.9[ ]+NEEDS-A-PERSON"#), "check_S8_9 never prints `CHECK S8.9 NEEDS-A-PERSON`")
        ok(has(t, #"RERUN[ ]+S8\.9[ ]+not valid"#), "check_S8_9 has no `RERUN S8.9 not valid: <reason>` line")
        ok(has(t, #"return[ ]+4"#), "check_S8_9 never returns 4")
        ok(has(t, #"CHECK[ ]+S8\.9[ ]+PASS"#) && has(t, #"CHECK[ ]+S8\.9[ ]+FAIL"#), "check_S8_9 does not print both PASS and FAIL")
        ok(!has(t, #"CHECK[ ]+S8\.9[ ]+SKIPPED"#), "check_S8_9 prints SKIPPED")
        ok(has(t, #"\$\{?(rc|status)\}?|\$\?"#) && has(t, #"\b3\)"#), "check_S8_9 does not branch on the exit status of s8_close_window (3 is a person step)")
        before(t, #"\bs8_close_window\b"#, #"CHECK[ ]+S8\.9[ ]+PASS"#, "check_S8_9 prints PASS before s8_close_window")
    }

    @Test("S8.9 runs `kit-privacy.sh query-scan` on markers.txt, `schema-scan`, and `kit-index.sh diff before-opens after-opens`; an exit 1 of each is a FAIL naming what was found, an exit 4 a RERUN")
    func s89Reads() {
        guard let t = ownCheck("S8.9"), let m = mine("S8.9") else { return }
        ok(has(m, privacyCall + #"query-scan[ ]+"?\$[^\n]*markers\.txt"#), "check_S8_9 does not run `kit-privacy.sh query-scan <run>/markers.txt`")
        ok(has(m, privacyCall + #"schema-scan"#), "check_S8_9 does not run `kit-privacy.sh schema-scan`")
        ok(has(m, #"kit-index\.sh"?[ ]+diff[ ]+before-opens[ ]+after-opens"#), "check_S8_9 does not run `kit-index.sh diff before-opens after-opens`")
        ok(has(t, #"\bs8d_query_scan\b[ ]+"?S8\.9"#), "check_S8_9 does not take the scan through s8d_query_scan (it saves the result once; S8.13 reads it)")
        ok(has(m, #"FOUND"#) || has(m, #"s8_findings"#), "check_S8_9 does not name the markers the scan found (`FOUND <marker> in <file>`)")
        ok(has(m, #"forbidden"#), "check_S8_9 does not name the forbidden schema names (`forbidden: <name>`)")
        ok(has(m, #"DIFFERENT|different"#), "check_S8_9 does not name the difference of the index snapshots")
        ok(has(t, #"CHECK[ ]+S8\.9[ ]+FAIL"#), "check_S8_9 prints no FAIL line")
        ok(!has(t, #"kq[ ]+"?[^\n"]*kit-privacy\.sh"?[ ]+schema-scan"#), "check_S8_9 runs schema-scan through kq, which switches off schema.txt in the evidence folder")
        let queryScan = allFunctions()["s8d_query_scan"].map { substitute($0, topLevelValues()) } ?? ""
        ok(!has(queryScan, #"kq[ ]+"?[^\n"]*kit-privacy\.sh"?[ ]+query-scan"#), "s8d_query_scan runs query-scan through kq, which switches off scan-controls.txt in the evidence folder")
        before(m, #"\bs8_close_window\b"#, privacyCall + #"query-scan"#, "check_S8_9 scans before the window was closed")
        for tool in [privacyCall + "query-scan", privacyCall + "schema-scan", #"kit-index\.sh"?[ ]+diff"#] {
            before(m, tool, #"CHECK[ ]+S8\.9[ ]+PASS"#, "check_S8_9 prints PASS before it ran \(tool)")
        }
    }

    @Test("S8.9 compares order-before.txt, order-mid.txt and order-after.txt row for row; fewer than 3 rows in order-before.txt is `RERUN S8.9 not valid: the order test list is shorter than 3 rows`, before any verdict")
    func s89Order() {
        guard let t = ownCheck("S8.9"), let m = mine("S8.9") else { return }
        for file in ["order-before.txt", "order-mid.txt", "order-after.txt"] {
            ok(m.contains(file), "check_S8_9 does not read \(file)")
        }
        ok(m.contains("the order test list is shorter than 3 rows"), "check_S8_9 does not say `the order test list is shorter than 3 rows`")
        ok(has(t, #"\bs8d_order_check\b"#), "check_S8_9 does not apply the order rules (s8d_order_check)")
        ok(has(t, #"RERUN[ ]+S8\.9[ ]+not valid:[ ]+\$"#), "check_S8_9 does not print the reason of a list that is not valid after `RERUN S8.9 not valid:`")
        before(t, #"\bs8d_order_check\b"#, #"CHECK[ ]+S8\.9[ ]+FAIL"#, "check_S8_9 can print FAIL before it checked that the order lists are long enough (identical empty lists prove nothing)")
        before(t, #"\bs8d_order_check\b"#, #"CHECK[ ]+S8\.9[ ]+PASS"#, "check_S8_9 can print PASS before it checked that the order lists are long enough")
        ok(has(m, #"\bcmp\b|\bdiff[ ]+-q|\bdiff[ ]"#), "check_S8_9 does not compare the lists row for row")
    }

    @Test("S8.9 needs real activity: markers.txt holds the 50 markers and an Enter open happened, else RERUN")
    func s89Activity() {
        guard let m = mine("S8.9") else { return }
        ok(has(m, #"markers\.txt"#), "check_S8_9 does not read run/markers.txt")
        ok(has(m, #"s8-activity-done"#) && has(m, #"opens"#), "check_S8_9 does not read the opens of run/s8-activity-done")
        ok(has(m, #"RERUN[ ]+S8\.9[ ]+not valid:[^\n]*(no Enter open|markers)"#), "check_S8_9 has no RERUN for a window with no Enter open or without its 50 markers")
        ok(has(m, #"\b50\b"#), "check_S8_9 does not hold the 50 searches")
    }

    // MARK: S8.10

    @Test("S8.10 (from slice 3): s8_close_window first, before the plist, the tcc read and the prompts result; the session is not run for the plant or below slice 3")
    func s810Session() {
        guard let t = ownCheck("S8.10") else { return }
        ok(has(t, #"\bs8_close_window\b[ ]+"?S8\.10"#), "check_S8_10 never calls `s8_close_window S8.10` (the prompts watcher the recipe started before the app is stopped there)")
        before(t, #"\bs8_close_window\b"#, privacyCall + #"plist"#, "check_S8_10 reads the plist before s8_close_window (it must call it first)")
        before(t, #"\bs8_close_window\b"#, privacyCall + #"tcc"#, "check_S8_10 reads tcc before s8_close_window")
        before(t, #"\bs8_close_window\b"#, privacyCall + #"prompts[ ]+result"#, "check_S8_10 reads the prompts result before s8_close_window")
        before(t, #"KIT_SLICE"#, #"\bs8_close_window\b"#, "check_S8_10 calls s8_close_window without looking at KIT_SLICE (slices 1 and 2 have no S8 session)")
        ok(has(t, #"KIT_SLICE[^\n]*-(ge|lt)[ ]+3"#), "check_S8_10 does not hold the session part to slice 3")
        ok(has(t, #"KIT_PLANT"#), "check_S8_10 lost its plant")
        ok(has(t, #"CHECK[ ]+S8\.10[ ]+FAIL[ ]+planted"#), "check_S8_10 lost `CHECK S8.10 FAIL planted: ...`")
        ok(has(t, #"CHECK[ ]+S8\.10[ ]+NEEDS-A-PERSON[^\n]*(session|person)"#), "check_S8_10 never prints NEEDS-A-PERSON for an exit 3 of s8_close_window")
        ok(!has(t, privacyCall + #"prompts[ ]+(start|stop)\b"#), "check_S8_10 starts or stops the prompts watcher: the recipe starts it before the app and s8_close_window stops it after the last open")
    }

    @Test("S8.10 reads `kit-privacy.sh prompts result s8`: exit 1 is FAIL naming the dialog, exit 0 prints what was seen, exit 4 is `RERUN S8.10 not valid: no prompts watcher ran in this session`, never a pass")
    func s810Prompts() {
        guard let t = ownCheck("S8.10") else { return }
        ok(has(t, privacyCall + #"prompts[ ]+result[ ]+s8\b"#), "check_S8_10 never runs `kit-privacy.sh prompts result s8`")
        ok(t.contains("RERUN S8.10 not valid: no prompts watcher ran in this session"), "check_S8_10 does not print `RERUN S8.10 not valid: no prompts watcher ran in this session`")
        ok(has(t, #"\b4\)"#), "check_S8_10 does not branch on exit 4 of the prompts result")
        ok(has(t, #"prompts[^\n]*(dialog|window)"#), "check_S8_10's FAIL does not name the dialog the watcher saw")
        ok(has(t, #"CHECK[ ]+S8\.10[ ]+PASS[^\n]*dialog"#), "check_S8_10's PASS line does not say that no dialog named Sesame was seen")
        ok(has(t, #"printf[ ]+'%s\\n'[ ]+"\$\{?pr[A-Za-z]*\}?""#) || has(t, #"echo[ ]+"\$\{?pr[A-Za-z]*\}?""#), "check_S8_10 does not print what the watcher saw (the list goes to the person, S8.N1)")
        guard let rerun = lastIndex(t, #"RERUN[ ]+S8\.10[ ]+not valid:[ ]+no prompts watcher"#), let pass = lastIndex(t, #"CHECK[ ]+S8\.10[ ]+PASS"#) else {
            ok(false, "check_S8_10 has no RERUN or PASS line to order")
            return
        }
        ok(rerun < pass, "check_S8_10 can print PASS before it required a prompts watcher result (an unanswered prompt leaves no TCC row, so tcc cannot stand in for it)")
        ok(!has(t, #"kit-privacy\.sh"?[ ]+prompts[ ]+(stop|start|parse)"#), "check_S8_10 starts, stops or parses a watcher: it only reads the saved result")
    }

    @Test("S8.10 keeps its plist and entitlements parts and its tcc part; a tcc exit 3 is NEEDS-A-PERSON naming the tcc part only; tcc is not run through kq (tcc.txt is saved)")
    func s810Parts() {
        guard let t = ownCheck("S8.10") else { return }
        ok(has(t, privacyCall + #"plist"#), "check_S8_10 lost its plist part")
        ok(has(t, privacyCall + #"entitlements"#), "check_S8_10 lost its entitlements part")
        ok(has(t, privacyCall + #"tcc"#), "check_S8_10 lost its tcc part")
        ok(has(t, #"CHECK[ ]+S8\.10[ ]+NEEDS-A-PERSON[^\n]*(tcc|permission database)"#), "check_S8_10's NEEDS-A-PERSON line does not name the tcc part")
        ok(has(t, #"\b3\)"#), "check_S8_10 does not branch on exit 3 of tcc")
        ok(!has(t, #"kq[ ]+"?[^\n"]*kit-privacy\.sh"?[ ]+tcc"#), "check_S8_10 runs tcc through kq, which switches off tcc.txt in the evidence folder")
        ok(!has(t, #"CHECK[ ]+S8\.10[ ]+SKIPPED"#), "check_S8_10 prints SKIPPED")
        ok(has(t, #"RERUN[ ]+S8\.10[ ]+not valid"#) && has(t, #"return[ ]+4"#), "check_S8_10 lost its RERUN")
    }

    // MARK: S8.13

    @Test("S8.13 has no partial note from slice 3: the note and the old PASS text belong to slices 1 and 2, the full PASS line says nothing is partial")
    func s813NoPartial() {
        guard let t = ownCheck("S8.13") else { return }
        ok(has(t, #"KIT_SLICE[^\n]*-(ge|lt)[ ]+3"#), "check_S8_13 does not look at the slice (the logs part and the net part start at slice 3)")
        before(t, #"KIT_SLICE"#, #"S8\.13 partial"#, "check_S8_13 prints `S8.13 partial` before it looked at the slice")
        ok(has(t, #"CHECK[ ]+S8\.13[ ]+PASS(?![^\n]*partial)[^\n]*"#), "check_S8_13 has no PASS line without a partial note (the verify.md wording: logs scan and net log are read from slice 3)")
        ok(has(t, #"CHECK[ ]+S8\.13[ ]+PASS[^\n]*partial"#), "check_S8_13 lost the slice 1 and 2 PASS line with its partial note (slices below 3 still print it)")
    }

    @Test("S8.13 reads S8.9's scan result (logs hold only event names) and S8.7's summary through s8_net_summary, before it prints PASS; the check itself starts no scan")
    func s813Reads() {
        guard let t = ownCheck("S8.13"), let m = mine("S8.13") else { return }
        ok(has(t, #"\bs8_net_summary\b[ ]+"?S8\.13"#), "check_S8_13 does not read the net log through `s8_net_summary S8.13`")
        ok(has(t, #"\bs8d_query_scan\b[ ]+"?S8\.13"#), "check_S8_13 does not read S8.9's scan result through s8d_query_scan")
        before(t, #"KIT_SLICE[^\n]*-(ge|lt)[ ]+3"#, #"\bs8_net_summary\b"#, "check_S8_13 reads the summary without holding it to slice 3")
        before(t, #"\bs8_net_summary\b"#, #"CHECK[ ]+S8\.13[ ]+PASS(?![^\n]*partial)"#, "check_S8_13 prints its full PASS before it read the summary")
        before(t, #"\bs8d_query_scan\b"#, #"CHECK[ ]+S8\.13[ ]+PASS(?![^\n]*partial)"#, "check_S8_13 prints its full PASS before it read the scan result")
        ok(has(m, #"logs/"#), "check_S8_13 does not name logs/ in a failure (a marker in the logs)")
        ok(has(m, #"/logs/|logs/"#) && has(m, #"FOUND"#), "check_S8_13 does not look for a FOUND line under logs/ in the scan result")
        ok(has(t, #"net log[^\n]*destination other than"#), "check_S8_13's net failure does not say that the net log shows a destination other than the model host")
        ok(!has(t, privacyCall + #"query-scan"#), "check_S8_13 runs query-scan itself: it reads S8.9's saved scan result through s8d_query_scan")
        ok(!has(t, netSummaryCall) && !has(t, traceNetCall), "check_S8_13 runs the net tools itself: it reads S8.7's summary through s8_net_summary")
    }

    @Test("S8.13 prints PASS only when the scan result and the net summary come from the same session (same run/recipe), else RERUN S8.13 not valid; an exit 3 is NEEDS-A-PERSON, an exit 1 of the net summary a FAIL")
    func s813Session() {
        guard let t = ownCheck("S8.13"), let m = mine("S8.13") else { return }
        ok(has(t, #"\bs8d_same_session\b"#), "check_S8_13 does not compare the sessions of the two results (s8d_same_session)")
        ok(has(m, #"run/recipe|recipe"#), "check_S8_13 does not compare run/recipe")
        ok(has(t, #"RERUN[ ]+S8\.13[ ]+not valid:[ ]+\$"#), "check_S8_13 does not print the reason after `RERUN S8.13 not valid:`")
        before(t, #"\bs8d_same_session\b"#, #"CHECK[ ]+S8\.13[ ]+PASS(?![^\n]*partial)"#, "check_S8_13 prints its full PASS before it compared the sessions")
        ok(has(t, #"CHECK[ ]+S8\.13[ ]+NEEDS-A-PERSON"#), "check_S8_13 never prints NEEDS-A-PERSON (an exit 3 of the session or the net summary: no administrator session)")
        ok(has(t, #"\b3\)"#) && has(t, #"\b1\)"#), "check_S8_13 does not branch on exits 1 and 3 of the net summary")
        ok(has(t, #"CHECK[ ]+S8\.13[ ]+FAIL"#), "check_S8_13 prints no FAIL line")
    }

    @Test("S8.13 keeps every part it had: layout, settings.json valid with startPressed, the mirror log, the Library part, and its plant")
    func s813KeepsParts() {
        guard let t = ownCheck("S8.13") else { return }
        ok(has(t, privacyCall + #"layout"#), "check_S8_13 lost the `kit-privacy.sh layout` part")
        ok(has(t, #"plutil"#) && has(t, #"startPressed"#), "check_S8_13 lost the settings.json validity and the Start-pressed flag")
        ok(has(t, #"kit-mirror\.sh"?[ ]+requests"#), "check_S8_13 lost the mirror request log part")
        ok(has(t, privacyCall + #"library-scan[ ]+--ignore-sesame-folder[ ]+--new-only"#), "check_S8_13 lost the Library part (S8.12's scan, new paths only)")
        ok(has(t, #"CHECK[ ]+S8\.13[ ]+FAIL[ ]+planted"#), "check_S8_13 lost `CHECK S8.13 FAIL planted: ...`")
        ok(has(t, #"KIT_PLANT"#), "check_S8_13 lost its plant")
    }

    // MARK: every one of the four

    @Test("a verdict line names its id: PASS, FAIL, NEEDS-A-PERSON and RERUN, and a check that cannot run returns 4, never a pass", arguments: ids)
    func verdictLines(_ id: String) {
        guard let t = ownCheck(id) else { return }
        let i = escaped(id)
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+PASS"#) && has(t, #"CHECK[ ]+\#(i)[ ]+FAIL"#), "\(checkFunctionName(id)) does not print both `CHECK \(id) PASS` and `CHECK \(id) FAIL`")
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+NEEDS-A-PERSON"#), "\(checkFunctionName(id)) never prints `CHECK \(id) NEEDS-A-PERSON`")
        ok(has(t, #"RERUN[ ]+\#(i)[ ]+not valid"#), "\(checkFunctionName(id)) has no `RERUN \(id) not valid: <reason>` line")
        ok(has(t, #"return[ ]+4"#), "\(checkFunctionName(id)) never returns 4 for a precondition that did not hold")
        ok(!has(t, #"CHECK[ ]+\#(i)[ ]+SKIPPED"#), "\(checkFunctionName(id)) prints SKIPPED: a check that cannot run is a RERUN or NEEDS-A-PERSON")
    }

    @Test("the four checks read the S8 session only: they never start or stop an observer or the watcher, search or drive the panel, run the recipe or start the app", arguments: ids)
    func neverDrives(_ id: String) {
        guard let m = mine(id) else { return }
        ok(!has(m, observerControl), "\(checkFunctionName(id)) starts or stops an observer or the prompts watcher: s8_close_window owns them")
        ok(!has(m, #"kit-search\.sh|kit-ax\.sh|osascript|\brecipe_[a-z]+\b|\bpick_folders\b|\bpress_start\b|kit-run\.sh"#), "\(checkFunctionName(id)) drives the panel, Settings or the picker, or runs the recipe: the 50 searches and the 20 opens are s8_activity's")
        ok(!has(m, #"kit-launch\.sh"?[ ]+(start|relaunch|quit|stop)"#), "\(checkFunctionName(id)) starts or stops the app")
        ok(!has(m, #"keytool|cliclick|CGEvent|key code|keystroke|KIT_TYPE_DELAY_MS"#), "\(checkFunctionName(id)) posts keys or touches the typing delay")
        ok(!has(m, #"window-ids"#) || id == "S8.7", "\(checkFunctionName(id)) writes or reads run/window-ids: tree_need notes the id; only S8.7 prints the list")
    }

    @Test("no check reads the product's source, every sudo is sudo -n, and checks-s8d.sh never edits a fixture, the index or a setting", arguments: ids)
    func staysClean(_ id: String) {
        guard let e = expanded(id) else { return }
        ok(!e.contains("Sources/") && !has(e, #"\bSources\b"#), "\(checkFunctionName(id)) names the product's source folder: the kit never reads it")
        ok(!has(e, #"\bsudo\b(?![ ]+-n\b)"#), "\(checkFunctionName(id)) calls sudo without -n: the one password prompt of the kit is kit-perms.sh ask-admin")
        guard let file = read(checkFile).map(stripComments) else { Issue.record("scripts/kit-lib/checks-s8d.sh not found"); return }
        ok(!has(file, #"sqlite3|defaults[ ]+write|plutil[ ]+-(insert|replace|remove)"#), "checks-s8d.sh edits state with sqlite3, defaults or plutil")
        ok(!has(file, #"\brm\b|\bmv[ ]|\btouch\b|\bdd[ ]|\bchmod\b|fixtures/"#), "checks-s8d.sh removes, moves, changes or writes a file other than its own results under run/ and the evidence folder")
        ok(!has(file, #"\bSources\b"#), "checks-s8d.sh names the product's source folder")
    }

    // MARK: the pure helpers, run as a child shell on hand-written files (no check, no kit script, no app)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun8c-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("run/net"), withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sources checks-s8d.sh in a child bash (only the function definitions run) with a temp KIT_ROOT and calls one helper.
    private func helper(_ call: String, root: URL) throws -> Ran {
        let script = "export KIT_LIB='\(libDir.path)' KIT_ROOT='\(root.path)'; . '\(checkFile.path)'; \(call)"
        return try run("/bin/bash", ["-c", script])
    }

    private func needFile() -> Bool {
        if FileManager.default.fileExists(atPath: checkFile.path) { return true }
        Issue.record("scripts/kit-lib/checks-s8d.sh not found")
        return false
    }

    @Test("s8d_field reads key=value out of a line of run/s8-activity-done and prints nothing for an absent key or a missing file; s8d_plant_at reads the at= of the plant n=<k>")
    func fieldAndPlantAt() throws {
        guard needFile() else { return }
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let act = root.appendingPathComponent("run/s8-activity-done")
        try write("searches=70 opens=20 indexing-done-at=1000.500 last-open-at=2000.250\n", act)
        let plants = root.appendingPathComponent("run/net/s8.plants")
        try write("PLANT s8 n=1 pid=11 at=900.100 addr=127.0.0.1:50001\nPLANT s8 n=2 pid=12 at=950.200 addr=127.0.0.1:50002\nPLANT s8 n=3 pid=13 at=2100.300 addr=127.0.0.1:50003\n", plants)
        let cases: [(String, String)] = [
            ("s8d_field '\(act.path)' opens", "20"), ("s8d_field '\(act.path)' indexing-done-at", "1000.500"),
            ("s8d_field '\(act.path)' last-open-at", "2000.250"), ("s8d_field '\(act.path)' searches", "70"),
            ("s8d_field '\(act.path)' nothing", ""), ("s8d_field '\(root.path)/run/absent' opens", ""),
            ("s8d_plant_at '\(plants.path)' 1", "900.100"), ("s8d_plant_at '\(plants.path)' 2", "950.200"),
            ("s8d_plant_at '\(plants.path)' 3", "2100.300"), ("s8d_plant_at '\(plants.path)' 4", ""),
        ]
        for (call, expected) in cases {
            let ran = try helper(call, root: root)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected, "\(call.replacingOccurrences(of: root.path, with: "<root>")) printed \(ran.output.debugDescription), expected \(expected.debugDescription)")
        }
    }

    /// One case of the window rules: the three files as the session leaves them.
    private struct WindowCase {
        let name: String
        let plants: [String]
        let activity: String?
        let closedAt: String?
        let status: Int32
        let phrase: String
    }

    private func plantLines(_ times: [String]) -> [String] {
        times.enumerated().map { "PLANT s8 n=\($0.offset + 1) pid=\(100 + $0.offset) at=\($0.element) addr=127.0.0.1:\(50000 + $0.offset)" }
    }

    @Test("s8d_window_order <plants> <activity> <closed-at>: exactly three plants, plant 2 earlier than indexing-done-at, plant 3 later than last-open-at, observers-closed-at not earlier than last-open-at; else exit 4 with the reason")
    func windowOrder() throws {
        guard needFile() else { return }
        let good = "searches=70 opens=20 indexing-done-at=600.000 last-open-at=800.000\n"
        let cases: [WindowCase] = [
            WindowCase(name: "a valid session", plants: plantLines(["100.000", "500.000", "900.000"]), activity: good, closedAt: "901.000\n", status: 0, phrase: ""),
            WindowCase(name: "the window closed at the very time of the last open", plants: plantLines(["100.000", "500.000", "900.000"]), activity: good, closedAt: "800.000\n", status: 0, phrase: ""),
            WindowCase(name: "only two plants", plants: plantLines(["100.000", "500.000"]), activity: good, closedAt: "901.000\n", status: 4, phrase: "three"),
            WindowCase(name: "four plants", plants: plantLines(["100.000", "500.000", "900.000", "950.000"]), activity: good, closedAt: "951.000\n", status: 4, phrase: "three"),
            WindowCase(name: "no plant", plants: [], activity: good, closedAt: "901.000\n", status: 4, phrase: "plant"),
            WindowCase(name: "plant 2 after indexing was done", plants: plantLines(["100.000", "700.000", "900.000"]), activity: good, closedAt: "901.000\n", status: 4, phrase: "mid-indexing"),
            WindowCase(name: "plant 2 at the very time indexing was done", plants: plantLines(["100.000", "600.000", "900.000"]), activity: good, closedAt: "901.000\n", status: 4, phrase: "mid-indexing"),
            WindowCase(name: "plant 3 before the last open", plants: plantLines(["100.000", "500.000", "750.000"]), activity: good, closedAt: "901.000\n", status: 4, phrase: "after the last open"),
            WindowCase(name: "plant 3 at the very time of the last open", plants: plantLines(["100.000", "500.000", "800.000"]), activity: good, closedAt: "901.000\n", status: 4, phrase: "after the last open"),
            WindowCase(name: "observers closed before the last open", plants: plantLines(["100.000", "500.000", "900.000"]), activity: good, closedAt: "790.000\n", status: 4, phrase: "early"),
            WindowCase(name: "no observers-closed-at", plants: plantLines(["100.000", "500.000", "900.000"]), activity: good, closedAt: nil, status: 4, phrase: "observers-closed-at"),
            WindowCase(name: "no s8-activity-done", plants: plantLines(["100.000", "500.000", "900.000"]), activity: nil, closedAt: "901.000\n", status: 4, phrase: "s8-activity-done"),
            WindowCase(name: "an activity file with no times", plants: plantLines(["100.000", "500.000", "900.000"]), activity: "searches=70 opens=20\n", closedAt: "901.000\n", status: 4, phrase: "indexing-done-at"),
        ]
        for c in cases {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            let plants = root.appendingPathComponent("run/net/s8.plants")
            let act = root.appendingPathComponent("run/s8-activity-done")
            let closed = root.appendingPathComponent("run/observers-closed-at")
            try write(c.plants.joined(separator: "\n") + (c.plants.isEmpty ? "" : "\n"), plants)
            if let a = c.activity { try write(a, act) }
            if let t = c.closedAt { try write(t, closed) }
            let ran = try helper("s8d_window_order '\(plants.path)' '\(act.path)' '\(closed.path)'", root: root)
            ok(ran.status == c.status, "s8d_window_order for \(c.name) exited \(ran.status), expected \(c.status): \(ran.output)")
            if c.status == 0 {
                ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s8d_window_order for \(c.name) printed \(ran.output.debugDescription), expected nothing")
            } else {
                ok(ran.output.contains(c.phrase), "s8d_window_order for \(c.name) printed \(ran.output.debugDescription), expected it to say \"\(c.phrase)\"")
            }
        }
    }

    @Test("s8d_rows counts the non-empty lines of a file (a missing file has none); s8d_order_check needs three identical lists of at least 3 rows: 0 identical, 1 they differ (naming the list), 4 not valid")
    func orderCheck() throws {
        guard needFile() else { return }
        let rows3 = "row 1 - alpha.png | /a/alpha.png\nrow 2 selected beta.png | /a/beta.png\nrow 3 - gamma.png | /a/gamma.png\n"
        let rows5 = rows3 + "row 4 - delta.png | /a/delta.png\nrow 5 - eps.png | /a/eps.png\n"
        let rows2 = "row 1 - alpha.png | /a/alpha.png\nrow 2 - beta.png | /a/beta.png\n"
        let swapped = "row 1 - alpha.png | /a/alpha.png\nrow 2 - gamma.png | /a/gamma.png\nrow 3 - beta.png | /a/beta.png\n"
        struct Case { let name: String; let lists: [String?]; let status: Int32; let phrase: String }
        let cases: [Case] = [
            Case(name: "three identical lists of 3 rows", lists: [rows3, rows3, rows3], status: 0, phrase: ""),
            Case(name: "three identical lists of 5 rows", lists: [rows5, rows5, rows5], status: 0, phrase: ""),
            Case(name: "identical lists of 2 rows", lists: [rows2, rows2, rows2], status: 4, phrase: "the order test list is shorter than 3 rows"),
            Case(name: "identical empty lists", lists: ["", "", ""], status: 4, phrase: "the order test list is shorter than 3 rows"),
            Case(name: "a different order after five opens", lists: [rows3, swapped, rows3], status: 1, phrase: "order-mid.txt"),
            Case(name: "a different order after the other open", lists: [rows3, rows3, swapped], status: 1, phrase: "order-after.txt"),
            Case(name: "a missing order-mid.txt", lists: [rows3, nil, rows3], status: 4, phrase: "order-mid.txt"),
            Case(name: "a missing order-before.txt", lists: [nil, rows3, rows3], status: 4, phrase: "order-before.txt"),
        ]
        for c in cases {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            let names = ["order-before.txt", "order-mid.txt", "order-after.txt"]
            for (i, list) in c.lists.enumerated() { if let list { try write(list, root.appendingPathComponent("run/\(names[i])")) } }
            let args = names.map { "'\(root.path)/run/\($0)'" }.joined(separator: " ")
            let ran = try helper("s8d_order_check \(args)", root: root)
            ok(ran.status == c.status, "s8d_order_check for \(c.name) exited \(ran.status), expected \(c.status): \(ran.output)")
            if c.status == 0 {
                ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s8d_order_check for \(c.name) printed \(ran.output.debugDescription), expected nothing")
            } else {
                ok(ran.output.contains(c.phrase), "s8d_order_check for \(c.name) printed \(ran.output.debugDescription), expected it to say \"\(c.phrase)\"")
            }
        }
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("run/rows.txt")
        try write("row 1 a\n\nrow 2 b\n   \nrow 3 c\n", file)
        let three = try helper("s8d_rows '\(file.path)'", root: root)
        ok(three.output.trimmingCharacters(in: .whitespacesAndNewlines) == "3", "s8d_rows printed \(three.output.debugDescription) for 3 rows and two blank lines, expected 3")
        let none = try helper("s8d_rows '\(root.path)/run/absent.txt'", root: root)
        ok(none.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "s8d_rows printed \(none.output.debugDescription) for a missing file, expected 0")
    }

    @Test("s8d_failure_lines keeps the failing lines of the summary and of the trace (PRODUCT, OUTSIDE, AFTER-LAST, BYTES and NET destinations) and nothing else; s8d_destinations counts the NET ones")
    func failureLines() throws {
        guard needFile() else { return }
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = """
        WINDOW the mirror's requests run from 36000.1 to 36100.2 (seconds of the day, 3 requests); mirror 127.0.0.1:50999
        PLANT 1 seen-by both
        PLANT 2 seen-by fs_usage
        PLANT 3 seen-by both
        NOTE fs_usage reported dropped events away from every plant (x): events lost there cannot be proven
        PRODUCT 93.184.216.34:443 by Sesame (fs_usage 10:00:01.5): a destination other than the mirror
        OUTSIDE SesameHelper (nettop 10:05:00) connect 127.0.0.1:50999: outside the mirror's first-to-last request window plus 2 s
        AFTER-LAST Sesame (fs_usage 10:06:00) connect 127.0.0.1:50999: a connection after the last model request
        BYTES 1200000 sent by processes named Sesame*, the limit is 1,000,000
        SENT 1200000 bytes sent by processes named Sesame* (nettop, plants left out by pid)
        NET 10:00:01.5 connect Sesame 93.184.216.34:443
        NET 10:00:02.5 sendto SesameHelper 10.0.0.9:8080
        NET CONNECTIONS (connect, sendto and sendmsg by processes named Sesame*): 2; left out as --except: 4; control tool lines: 6
        """
        let file = root.appendingPathComponent("run/sample.txt")
        try write(sample + "\n", file)
        let lines = try helper("s8d_failure_lines < '\(file.path)'", root: root)
        let kept = lines.output.split(separator: "\n").map(String.init)
        ok(kept.count == 6, "s8d_failure_lines kept \(kept.count) lines, expected the 6 failing ones (PRODUCT, OUTSIDE, AFTER-LAST, BYTES and the two NET destinations): \(kept)")
        for prefix in ["PRODUCT ", "OUTSIDE ", "AFTER-LAST ", "BYTES ", "NET 10:00:01.5", "NET 10:00:02.5"] {
            ok(kept.contains { $0.hasPrefix(prefix) }, "s8d_failure_lines dropped the line that starts \"\(prefix)\"")
        }
        ok(!kept.contains { $0.hasPrefix("NET CONNECTIONS") || $0.hasPrefix("PLANT") || $0.hasPrefix("SENT") || $0.hasPrefix("NOTE") || $0.hasPrefix("WINDOW") }, "s8d_failure_lines kept a line that is no failure: \(kept)")
        let n = try helper("s8d_destinations < '\(file.path)'", root: root)
        ok(n.output.trimmingCharacters(in: .whitespacesAndNewlines) == "2", "s8d_destinations printed \(n.output.debugDescription), expected 2 (the summary line `NET CONNECTIONS` is not a destination)")
        let clean = root.appendingPathComponent("run/clean.txt")
        try write("NET CONNECTIONS (connect, sendto and sendmsg by processes named Sesame*): 0; left out as --except: 9; control tool lines: 6\n", clean)
        let zero = try helper("s8d_destinations < '\(clean.path)'", root: root)
        ok(zero.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "s8d_destinations printed \(zero.output.debugDescription) for a clean trace, expected 0")
        let none = try helper("s8d_failure_lines < '\(clean.path)'", root: root)
        ok(none.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s8d_failure_lines printed \(none.output.debugDescription) for a clean trace, expected nothing")
    }

    @Test("s8d_net_status <summary exit> <trace exit> <destinations>: 0 clean; 1 a product failure of either; 4 whenever either tool says not valid or exits with a code it does not define",
          arguments: [
              ("0", "0", "0", Int32(0)), ("1", "0", "0", Int32(1)), ("0", "0", "2", Int32(1)), ("1", "0", "3", Int32(1)),
              ("4", "0", "0", Int32(4)), ("1", "4", "0", Int32(4)), ("0", "4", "5", Int32(4)), ("0", "3", "0", Int32(4)),
              ("2", "0", "0", Int32(4)), ("127", "0", "0", Int32(4)), ("0", "2", "0", Int32(4)), ("0", "0", "x", Int32(4)),
          ])
    func netStatus(_ summary: String, _ trace: String, _ dests: String, _ expected: Int32) throws {
        guard needFile() else { return }
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let ran = try helper("s8d_net_status '\(summary)' '\(trace)' '\(dests)'", root: root)
        ok(ran.status == expected, "s8d_net_status \(summary) \(trace) \(dests) exited \(ran.status), expected \(expected): \(ran.output)")
    }

    @Test("s8d_same_session: both saved results (run/s8-query-scan.rc, run/s8-net-summary.rc) carry the key of the session now running (run/recipe and run/s8-activity-done), else exit 4")
    func sameSession() throws {
        guard needFile() else { return }
        struct Case { let name: String; let scan: String?; let net: String?; let recipe: String; let status: Int32 }
        let key = "tree s8|searches=70 opens=20 indexing-done-at=600.000 last-open-at=800.000"
        let otherKey = "tree s8|searches=70 opens=20 indexing-done-at=111.000 last-open-at=222.000"
        let cases: [Case] = [
            Case(name: "both saved in this session", scan: "0 \(key)", net: "0 \(key)", recipe: "tree s8", status: 0),
            Case(name: "a failing result of this session is still a result of it", scan: "1 \(key)", net: "1 \(key)", recipe: "tree s8", status: 0),
            Case(name: "the scan saved in another session", scan: "0 \(otherKey)", net: "0 \(key)", recipe: "tree s8", status: 4),
            Case(name: "the net summary saved in another session", scan: "0 \(key)", net: "0 \(otherKey)", recipe: "tree s8", status: 4),
            Case(name: "the recipe changed since", scan: "0 \(key)", net: "0 \(key)", recipe: "tree s9", status: 4),
            Case(name: "no net summary saved", scan: "0 \(key)", net: nil, recipe: "tree s8", status: 4),
            Case(name: "no scan result saved", scan: nil, net: "0 \(key)", recipe: "tree s8", status: 4),
        ]
        for c in cases {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            try write(c.recipe + "\n", root.appendingPathComponent("run/recipe"))
            try write("searches=70 opens=20 indexing-done-at=600.000 last-open-at=800.000\n", root.appendingPathComponent("run/s8-activity-done"))
            if let s = c.scan { try write(s + "\n", root.appendingPathComponent("run/s8-query-scan.rc")) }
            if let n = c.net { try write(n + "\n", root.appendingPathComponent("run/s8-net-summary.rc")) }
            let ran = try helper("s8d_same_session", root: root)
            ok(ran.status == c.status, "s8d_same_session for \(c.name) exited \(ran.status), expected \(c.status): \(ran.output)")
            if c.status == 4 { ok(!ran.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s8d_same_session for \(c.name) said nothing") }
        }
    }

    // MARK: plan-3-t12, the S8.13 mirror-log fix
    //
    // A defect of this task's own sealed check, found by its tester: the mirror-log awk of check_S8_13 matched `$1 ~ /^[0-9]+ [A-Z]+ /`
    // (an integer time, then a space), but a real line of the mirror's log is `<fractional time> METHOD /path range=... status=... bytes=...`
    // (kit-lib/mirrorserver.swift writes the time with `%.3f`), so the pattern never matched and that part of S8.13 always passed. The
    // reading is now a sourced pure function of checks-s8.sh, `s8_mirror_strays <models.tsv>` (stdin: the output of `kit-mirror.sh
    // requests`; prints the path of every request whose last path segment is none of the model file names), with its companion
    // `s8_mirror_count` (prints how many request lines the text holds). check_S8_13 (and t12's check_S6_13) call them. The tests run the
    // functions in a child shell on hand-written logs (the model names and the table are hand-written here too) and read the text of the
    // check; none runs a check, so the failure the old pattern let through is shown by the sample: its second line is a request for
    // another path, and the old pattern reported nothing for it.

    private func mirrorHelper(_ call: String, root: URL) throws -> Ran {
        let script = "export KIT_LIB='\(libDir.path)' KIT_ROOT='\(root.path)'; . '\(oldCheckFile.path)'; \(call)"
        return try run("/bin/bash", ["-c", script])
    }

    private func needOldFile() -> Bool {
        if FileManager.default.fileExists(atPath: oldCheckFile.path) { return true }
        Issue.record("scripts/kit-lib/checks-s8.sh not found")
        return false
    }

    private let modelTable = "model-one-Q8_0.gguf\t111\taaa\nmmproj-model-one-Q8_0.gguf\t222\tbbb\n"
    private let modelRequest = "1730000000.123 GET /resolve/main/model-one-Q8_0.gguf range=- status=200 bytes=111"
    private let otherRequest = "1730000001.456 GET /somewhere/else.zip range=- status=200 bytes=5"

    private func mirrorRun(_ function: String, table: Bool, log: String) throws -> Ran {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tsv = root.appendingPathComponent("run/models.tsv")
        let file = root.appendingPathComponent("run/requests.txt")
        try write(modelTable, tsv)
        try write(log, file)
        return try mirrorHelper("\(function)\(table ? " '\(tsv.path)'" : "") < '\(file.path)'", root: root)
    }

    @Test("s8_mirror_strays reports the other path of the two-line sample (a fractional-time request for a model file name and one for another path), and nothing for the model request alone")
    func mirrorStraysTwoLineSample() throws {
        guard needOldFile() else { return }
        let both = try mirrorRun("s8_mirror_strays", table: true, log: modelRequest + "\n" + otherRequest + "\n")
        ok(both.output.trimmingCharacters(in: .whitespacesAndNewlines) == "/somewhere/else.zip", "s8_mirror_strays on the two-line sample printed \(both.output.debugDescription), expected /somewhere/else.zip (the old integer-time pattern printed nothing for it)")
        let alone = try mirrorRun("s8_mirror_strays", table: true, log: modelRequest + "\n")
        ok(alone.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s8_mirror_strays on the model request alone printed \(alone.output.debugDescription), expected nothing")
        ok(both.status == 0 && alone.status == 0, "s8_mirror_strays exited \(both.status) and \(alone.status), expected 0 both times (the verdict is the caller's, from what it prints)")
    }

    @Test("s8_mirror_strays reads a request the way the mirror logs it: any method, a query string and a directory before the file name are fine, a .partial name, a header, a count line and `no requests logged yet` are not requests")
    func mirrorStraysShapes() throws {
        guard needOldFile() else { return }
        let log = """
        time method path range status bytes
        1730000000.123 GET /resolve/main/model-one-Q8_0.gguf range=- status=200 bytes=111
        1730000000.456 HEAD /mmproj-model-one-Q8_0.gguf?download=true range=- status=200 bytes=0
        1730000001.001 GET /model-one-Q8_0.gguf range=bytes=100-199 status=206 bytes=100
        1730000002.250 GET /model-one-Q8_0.gguf range=- status=reset bytes=0 offline
        1730000003.999 GET /model-one-Q8_0.gguf.partial range=- status=404 bytes=0
        1730000004.000 POST /upload/data range=- status=200 bytes=9
        1730000005.5 GET /x/y.bin?token=1 range=- status=200 bytes=3
        6 requests in /var/k/run/mirror-requests.log

        """
        let ran = try mirrorRun("s8_mirror_strays", table: true, log: log)
        let printed = ran.output.split(separator: "\n").map(String.init)
        ok(printed == ["/model-one-Q8_0.gguf.partial", "/upload/data", "/x/y.bin?token=1"], "s8_mirror_strays printed \(printed), expected the .partial name, /upload/data and /x/y.bin?token=1 (in this order, the query string kept as logged)")
        let none = try mirrorRun("s8_mirror_strays", table: true, log: "no requests logged yet (/var/k/run/mirror-requests.log)\n")
        ok(none.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s8_mirror_strays printed \(none.output.debugDescription) for `no requests logged yet`, expected nothing")
        let order = try mirrorRun("s8_mirror_strays", table: true, log: modelRequest + "\n" + otherRequest + "\n1730000002.000 GET /third.bin range=- status=200 bytes=1\n")
        ok(order.output.split(separator: "\n").map(String.init) == ["/somewhere/else.zip", "/third.bin"], "s8_mirror_strays printed \(order.output.debugDescription), expected the other paths in log order")
    }

    @Test("s8_mirror_count prints how many request lines the text holds (a fractional time, a method, a path), 0 for `no requests logged yet`, the header and the count line left out")
    func mirrorCount() throws {
        guard needOldFile() else { return }
        let cases: [(String, String)] = [
            ("time method path range status bytes\n\(modelRequest)\n\(otherRequest)\n2 requests in /var/k/run/mirror-requests.log\n", "2"),
            (modelRequest + "\n", "1"),
            ("no requests logged yet (/var/k/run/mirror-requests.log)\n", "0"),
            ("", "0"),
            ("time method path range status bytes\n0 requests in /x\n", "0"),
        ]
        for (log, expected) in cases {
            let ran = try mirrorRun("s8_mirror_count", table: false, log: log)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected, "s8_mirror_count for \(log.debugDescription) printed \(ran.output.debugDescription), expected \(expected)")
        }
    }

    @Test("check_S8_13's mirror-log part calls s8_mirror_strays with models.tsv and fails on what it prints; the integer-time pattern is gone from checks-s8.sh; both functions are defined once, in checks-s8.sh, and no s8c_ or s8d_ name is redefined")
    func s813MirrorFixText() {
        guard let t = ownCheck("S8.13"), let raw = read(oldCheckFile).map(stripComments) else { return }
        ok(has(t, #"\bs8_mirror_strays\b[ ]+"[^"]*models\.tsv""#), "check_S8_13 does not call s8_mirror_strays with models.tsv")
        before(t, #"kit-mirror\.sh"?[ ]+requests"#, #"\bs8_mirror_strays\b"#, "check_S8_13 reads the strays before it ran `kit-mirror.sh requests`")
        ok(has(t, #"the mirror log shows a request for something other than the two model files"#), "check_S8_13 lost the wording of its mirror-log failure")
        ok(has(t, #"why=[^\n]*\$\{?(mbad|strays)"#) || has(t, #"\$\{?(mbad|strays)\}?[^\n]*\n[^\n]*why="#) || has(t, #"-z[ ]+"\$\{?(mbad|strays)"#), "check_S8_13 does not turn what s8_mirror_strays prints into a failure")
        ok(!has(raw, #"\^\[0-9\]\+ \[A-Z\]\+"#), "checks-s8.sh still holds the integer-time pattern /^[0-9]+ [A-Z]+ / that never matched a real log line")
        for name in ["s8_mirror_strays", "s8_mirror_count"] {
            var where_: [String] = []
            for (source, code) in kitShellSources() where code.split(separator: "\n").contains(where: { $0.hasPrefix("\(name)() {") }) { where_.append(source) }
            ok(where_ == ["kit-lib/checks-s8.sh"], "\(name) is defined in \(where_), expected kit-lib/checks-s8.sh only")
        }
        let names = Set(shellFunctions(in: raw).keys)
        ok(!names.contains { $0.hasPrefix("s8c_") || $0.hasPrefix("s8d_") }, "checks-s8.sh defines an s8c_ or s8d_ name of t10 or t11: \(names.filter { $0.hasPrefix("s8c_") || $0.hasPrefix("s8d_") }.sorted())")
    }
}

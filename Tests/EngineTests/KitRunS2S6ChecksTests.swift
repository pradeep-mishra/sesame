import Foundation
import Testing

// plan-3-t12, tester step: kit part 8, the checks S2.2, S2.3, S2.8, S2.17 and S6.13 (a new scripts/kit-lib/checks-s2c.sh holds
// check_S2_2, check_S2_3, check_S2_8, check_S2_17, check_S6_13 and their `s2c_` helpers; the S8.13 mirror-log fix is tested in
// KitRunS8cChecksTests). Written from verify.md, the feature maps S2 and S6, the design and the plan-3-t12 entry only, with the names the
// sealed reports of t1, t2, t3, t8, t10 and t11 give (`kit-golden.sh engine|panel --group b`, `kit-golden.sh merge`, `kit-fixtures.sh
// build unrelated <n>`, `expect listing`, `expect extensions --kinds`, `mutate delete`, `restore`, `kit-index.sh has|under|wait`,
// `kit-search.sh --expect-absent`, `tree_need <id>`, `s8_net_summary <id>`, `golden_rows`, `golden_key_rows`, `golden_read_kinds`);
// no product source is read, and no kit function may read it.
//
// Static proof only (plan-3-tasks.md, Conventions; the person's ruling "no app launch"): a check needs the app, the panel, the model, the
// S8 session or the administrator session, so NOTHING here runs a check, the recipe, `kit-run.sh`, `verify.sh`, `kit-golden.sh engine`,
// `panel` or `merge`, or any kit script that starts the app or drives its UI. The runs are `bash -n`, the pure helpers of checks-s2c.sh
// sourced in a child bash on hand-written files in a temp KIT_ROOT, KIT_PROJECT and KIT_LIB (the expected values are written in this
// file), and the text of the check files with their comment lines removed (a comment never satisfies a test): each check as the shell
// would run it with its own `s2c_` functions and the top-level variables written in. Real behaviour is read at the accept stage only
// (blocks B and C).
//
// The contract read here (plan-3-t12, Tests):
//   - S2.2: starts from the recipe `photos` (s1_need_photos); `kit-golden.sh engine --group b` and `panel --group b`, every readable
//     exact row first for both (t3 decides the bar, 19 of 20 only when every kind has a reader); the line says `readable <n> of <total>`;
//     the screenshot-only rows (at least 4) are confirmed by `kit-fixtures.sh expect listing golden` to be in no other file; none comes
//     from a code file; the decoys of every readable row are in the index (`kit-index.sh has`);
//   - S2.3: the `missing` row (one token) lists a non-empty set in the panel with no "No matches", no error text and no crash; strings of
//     two, three and four tokens made of words in no file each show "No matches";
//   - S2.8: (i) decoys and every readable exact row first, (ii) `kit-fixtures.sh build unrelated 1000` added through Settings and indexed
//     to Ready, the rows re-run and none moved from first, (iii) `mutate delete` of one exact file whose query is one token, then
//     `kit-search.sh "<string>" --expect-absent <path>` within 30 s and a non-empty closest list for the same string, then `restore`,
//     (iv) `kit-golden.sh merge` ranks with the odd and the even rows apart and `noted: overfitting risk` when the even rows hit 2 fewer,
//     (v) prints `SKIPPED slice 6`; the PASS line says `(i) to (iv); (v) waits for slice 6`; the index is polluted afterwards, so the
//     recipe mark is dropped (plan-6-t1: (v) is built, see `s28Skipped`);
//   - S2.17: starts with `tree_need` and `kit-index.sh wait done 900` and never closes the window; `kit-fixtures.sh expect extensions
//     --kinds <read-kinds.txt>`; for each extension of those kinds one `ext-` cell of the matrix is `done` in the index and its unique
//     name stem searched alone lists it first; an extension with no done file fails by name; no kind is written in the check;
//   - S6.13: `s8_net_summary S6.13` (3 is NEEDS-A-PERSON, 4 a RERUN), the mirror's log lists requests only for the two model file names
//     (read with the fractional-time function of checks-s8.sh), and the summary shows no other destination.
// Red before the kit part: checks-s2c.sh does not exist and the five ids have no function.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s2c.sh")
private let s8File = libDir.appendingPathComponent("checks-s8.sh")

private let ids = ["S2.2", "S2.3", "S2.8", "S2.17", "S6.13"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs a program and collects its output (this suite starts only /bin/bash: `-n`, and `-c` on the pure helpers).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun2s6-out-" + UUID().uuidString)
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

private func kitShellSources() -> [(name: String, code: String)] {
    var all: [(String, String)] = []
    if let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) { all.append(("kit-run.sh", stripComments(text))) }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []).filter { $0.hasSuffix(".sh") }.sorted()
    for name in names {
        if let text = read(libDir.appendingPathComponent(name)) { all.append(("kit-lib/" + name, stripComments(text))) }
    }
    return all
}

/// The shell functions of a text: name to body. A function is `name() {` to a line that is just `}`, or one line `name() { ...; }`.
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

private func escaped(_ id: String) -> String { NSRegularExpression.escapedPattern(for: id) }

/// The check as the shell would run it, with the functions of checks-s2c.sh written in (a call of a function of another kit file, a
/// recipe, s1_search, s8_net_summary or tree_need stays a call, so it never brings that file's code into the text). Records the reason
/// and returns nil when the check does not exist.
private func mine(_ id: String) -> String? {
    let all = allFunctions()
    let name = checkFunctionName(id)
    guard let body = all[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    let helpers = all.filter { $0.key.hasPrefix("s2c_") }
    return substitute(expandShell(body, helpers, skipping: [name]), topLevelValues())
}

/// The check's own body and the bodies of its `s2c_check_*`, `s2c_run_*` and `s2c_restore` functions only, never the pure helpers.
private func body(_ id: String) -> String? {
    let all = allFunctions()
    let name = checkFunctionName(id)
    guard let text = all[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    let bodies = all.filter { $0.key.hasPrefix("s2c_check_") || $0.key.hasPrefix("s2c_run_") || $0.key == "s2c_restore" }
    return substitute(expandShell(text, bodies, skipping: [name]), topLevelValues())
}

private func before(_ text: String, _ a: String, _ b: String, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let ia = firstIndex(text, a), let ib = firstIndex(text, b) else {
        ok(false, "\(message) (missing: \(firstIndex(text, a) == nil ? a : b))", sourceLocation: sourceLocation)
        return
    }
    ok(ia < ib, message, sourceLocation: sourceLocation)
}

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

private let goldenCall = #"kit-golden\.sh"?[ ]+"#
private let fixturesCall = #"kit-fixtures\.sh"?[ ]+"#
private let indexCall = #"kit-index\.sh"?[ ]+"#
private let appDriving = #"kit-launch\.sh"?[ ]+(start|relaunch|quit|stop)|kit-reset\.sh|kit-run\.sh|osascript|keytool|cliclick|CGEvent|key code|keystroke"#

@Suite("KitRunS2S6ChecksTests")
struct KitRunS2S6ChecksTests {

    // MARK: syntax and wiring

    @Test("bash -n finds no syntax error in checks-s2c.sh and checks-s8.sh (none is run)")
    func bashSyntax() throws {
        for url in [checkFile, s8File] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(Comment(rawValue: "\(url.path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", url.path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(url.path) exited \(ran.status): \(ran.output)")
        }
    }

    @Test("the runner sources every scripts/kit-lib/checks-*.sh, so the new file needs no wiring; checks-s2c.sh holds no top-level command except variables and the one `. golden.sh` line")
    func runnerSourcesTheFile() {
        let runner = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) ?? ""
        ok(has(runner, #"checks-\*\.sh"#), "kit-run.sh no longer sources every scripts/kit-lib/checks-*.sh")
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s2c.sh not found"); return }
        var depth = 0
        var strays: [String] = []
        for line in stripComments(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if depth == 0, !line.trimmingCharacters(in: .whitespaces).isEmpty,
               !has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"^[A-Z][A-Z0-9_]*="#), !has(line, #"^\. "\$KIT_LIB/golden\.sh"$"#) {
                strays.append(line)
            }
            if has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"\}$"#) { depth += 1 }
            if line == "}" { depth = max(0, depth - 1) }
        }
        ok(strays.isEmpty, "checks-s2c.sh runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("checks.tsv keeps the five ids at slice 3, once each, all auto", arguments: ids)
    func registered(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == "3", "\(id) is registered at slice \(row.slice), expected 3")
            ok(row.kind == "auto", "\(id) has kind \(row.kind), expected auto")
        }
    }

    @Test("each of the five checks is defined once in the kit, in checks-s2c.sh", arguments: ids)
    func exactlyOneFunction(_ id: String) {
        let name = checkFunctionName(id)
        var total = 0
        var where_: [String] = []
        for (source, code) in kitShellSources() {
            let n = code.split(separator: "\n").filter { $0.hasPrefix("\(name)() {") }.count
            total += n
            if n > 0 { where_.append(source) }
        }
        ok(total == 1, "\(name) is defined \(total) times in the kit (\(where_.joined(separator: ", "))), expected once")
        ok(where_ == ["kit-lib/checks-s2c.sh"], "\(name) is defined in \(where_), expected kit-lib/checks-s2c.sh only")
    }

    // Amended in plan-4-t3 (never weakened): check_S2_4 (slice 4, PDFs and documents) lives in checks-s2c.sh, as the entry plan-4-t3 names
    // that file for it, so the file now defines six checks: the five of t12 and check_S2_4. Every other pin of this test is unchanged.
    @Test("checks-s2c.sh defines the five checks of t12, check_S2_4 and s2c_ helpers only, no name another kit file defines, never an s8c_ or s8d_ name")
    func nothingElseDefined() {
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s2c.sh not found"); return }
        let defined = shellFunctions(in: stripComments(text))
        ok(!defined.isEmpty, "checks-s2c.sh defines no function")
        let checks = Set(defined.keys.filter { $0.hasPrefix("check_") })
        ok(checks == Set((ids + ["S2.4"]).map(checkFunctionName)), "checks-s2c.sh defines the check functions \(checks.sorted()), expected the five of t12 and check_S2_4 of plan-4-t3")
        let odd = defined.keys.filter { !$0.hasPrefix("check_") && !$0.hasPrefix("s2c_") }.sorted()
        ok(odd.isEmpty, "checks-s2c.sh defines functions that are neither check_<id> nor s2c_<name>: \(odd)")
        var others: Set<String> = []
        for (name, code) in kitShellSources() where name != "kit-lib/checks-s2c.sh" { others.formUnion(shellFunctions(in: code).keys) }
        ok(others.isDisjoint(with: defined.keys), "checks-s2c.sh redefines \(others.intersection(defined.keys).sorted()), a name that another kit file defines")
        ok(!defined.keys.contains { $0.hasPrefix("s8c_") || $0.hasPrefix("s8d_") }, "checks-s2c.sh defines an s8c_ or s8d_ name of t10 or t11")
    }

    @Test("a verdict line names its id: PASS, FAIL, NEEDS-A-PERSON and RERUN, and a check that cannot run returns 4, never a pass", arguments: ids)
    func verdictLines(_ id: String) {
        guard let t = body(id) else { return }
        let i = escaped(id)
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+PASS"#) && has(t, #"CHECK[ ]+\#(i)[ ]+FAIL"#), "\(checkFunctionName(id)) does not print both `CHECK \(id) PASS` and `CHECK \(id) FAIL`")
        // the helpers s1_need_photos and s1_search_ok print `CHECK <id> NEEDS-A-PERSON ...` themselves for an exit 3 (checks-s1.sh, checks-s1b.sh)
        ok(has(t, #"CHECK[ ]+\#(i)[ ]+NEEDS-A-PERSON"#) || has(t, #"\bs1_search_ok[ ]+"?\#(i)"?[ ]"#), "\(checkFunctionName(id)) never prints `CHECK \(id) NEEDS-A-PERSON` and gives an exit 3 to no helper that does")
        ok(has(t, #"RERUN[ ]+\#(i)[ ]+not valid"#), "\(checkFunctionName(id)) has no `RERUN \(id) not valid: <reason>` line")
        ok(has(t, #"return[ ]+4"#), "\(checkFunctionName(id)) never returns 4 for a precondition that did not hold")
        ok(!has(t, #"CHECK[ ]+\#(i)[ ]+SKIPPED"#), "\(checkFunctionName(id)) prints a CHECK SKIPPED line: a check that cannot run is a RERUN or NEEDS-A-PERSON")
        ok(!has(t, #"CHECK[ ]+\#(i)[ ]+PASS[^\n]*partial"#), "\(checkFunctionName(id)) prints a partial PASS")
    }

    @Test("the five checks never start or stop the app, reset, run the recipe or post keys, never call sudo without -n, never read the product's source, never edit the index or a setting", arguments: ids)
    func staysClean(_ id: String) {
        guard let m = mine(id) else { return }
        ok(!has(m, appDriving), "\(checkFunctionName(id)) starts, stops or resets the app, runs the recipe or posts keys itself")
        ok(!has(m, #"\bsudo\b(?![ ]+-n\b)"#), "\(checkFunctionName(id)) calls sudo without -n: the one password prompt of the kit is kit-perms.sh ask-admin")
        ok(!has(m, #"\bSources/|\bSources\b"#), "\(checkFunctionName(id)) names the product's source folder: the kit never reads it")
        ok(!has(m, #"sqlite3|defaults[ ]+write|plutil[ ]+-(insert|replace|remove)"#), "\(checkFunctionName(id)) edits state with sqlite3, defaults or plutil")
    }

    // Amended in plan-4-t3 (never weakened): S2.4 drops the recipe mark after its engine run, because the engine's whole-folder prepare
    // resets the kit (`rm -f "$KIT_ROOT/run/recipe"`, the mark of the recipe `golden`; S2.8's `rm -f "$S1_MARK"` is the mark of the
    // recipe `photos`). That second `rm -f` of a recipe mark is the only addition; any other removal, move or write is still refused.
    @Test("checks-s2c.sh removes, moves or writes nothing except the two `rm -f` of a recipe mark (S2.8's and S2.4's); fixtures change only through kit-fixtures.sh")
    func noDirectWrites() {
        guard let raw = read(checkFile).map(stripComments) else { Issue.record("scripts/kit-lib/checks-s2c.sh not found"); return }
        let file = raw.replacingOccurrences(of: #"rm -f "$S1_MARK""#, with: "").replacingOccurrences(of: #"rm -f "$KIT_ROOT/run/recipe""#, with: "")
        ok(!has(file, #"\brm\b|\bmv[ ]|\btouch\b|\bdd[ ]|\bchmod\b|\bcp[ ]|\bmkdir\b|\btruncate\b"#), "checks-s2c.sh removes, moves, copies or writes a file itself (only `rm -f \"$S1_MARK\"` and `rm -f \"$KIT_ROOT/run/recipe\"` are allowed): fixtures change through kit-fixtures.sh")
        ok(!has(file, #">[ ]*"?\$?\{?KIT_ROOT/fixtures|>[ ]*"?[^ "]*fixtures/"#), "checks-s2c.sh redirects into a fixture file")
    }

    // MARK: S2.2

    @Test("S2.2 starts from the recipe photos (s1_need_photos), before any golden run; an exit 3 of a golden run is NEEDS-A-PERSON, an exit 4 a RERUN")
    func s22Starts() {
        guard let t = body("S2.2") else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) && !has($0, #"^s1_run\b"#) && !has($0, #"^s2c_check_2\b"#) }
        ok(first.map { has($0, #"^s1_need_photos[ ]+"?S2\.2"?[ ]"#) } ?? false, "the first command of S2.2 is \(first ?? "nothing"), expected `s1_need_photos S2.2` (panel needs the 40 done golden photos)")
        before(t, #"\bs1_need_photos\b"#, goldenCall + "engine", "S2.2 runs the golden engine before the recipe photos")
        ok(has(t, #"rc_[a-z]+[ ]*=[ ]*3|\b3\)"#) || has(t, #"=[ ]*3[ ]*\]"#), "S2.2 does not branch on exit 3 of the golden runs")
        ok(has(t, #"CHECK[ ]+S2\.2[ ]+NEEDS-A-PERSON"#), "S2.2 never prints NEEDS-A-PERSON for a golden run that needs a person")
    }

    @Test("S2.2 runs `kit-golden.sh engine --group b` and `panel --group b`, reads golden-engine.tsv and golden-panel.tsv, and reports `readable <n> of <total>` with the total read from the key")
    func s22Golden() {
        guard let t = body("S2.2"), let m = mine("S2.2") else { return }
        ok(has(t, goldenCall + #"engine[ ]+--group[ ]+b\b"#), "S2.2 never runs `kit-golden.sh engine --group b`")
        ok(has(t, goldenCall + #"panel[ ]+--group[ ]+b\b"#), "S2.2 never runs `kit-golden.sh panel --group b`")
        ok(has(t, #"golden-engine\.tsv"#) && has(t, #"golden-panel\.tsv"#), "S2.2 does not read golden-engine.tsv and golden-panel.tsv")
        ok(has(m, #"\bgolden_counts\b"#) && has(m, #"\bgolden_dir\b"#), "S2.2 does not count the group b rows of the two files (golden_counts, golden_dir)")
        ok(has(m, #"\bs2c_not_first\b"#), "S2.2 does not name the rows that are not first (s2c_not_first)")
        ok(has(t, #"readable[ ]+\$\{?[A-Za-z_]+\}?[ ]+of[ ]+\$\{?[A-Za-z_]+"#), "S2.2 does not print `readable <n> of <total>`")
        ok(has(m, #"\bgolden_key_rows\b[ ]+b\b"#), "S2.2 does not read the total of the key (golden_key_rows b)")
        ok(!has(t, #"\b20\b"#) && !has(t, #"\b19\b"#), "S2.2 writes the figure 20 or 19: the total and the bar come from the key and from kit-golden.sh (t3)")
        ok(has(m, #"\bgolden_rows[ ]+b\b"#), "S2.2 does not count the readable rows (golden_rows b)")
        before(t, goldenCall + #"engine"#, #"CHECK[ ]+S2\.2[ ]+PASS"#, "S2.2 prints PASS before the engine run")
        before(t, goldenCall + #"panel"#, #"CHECK[ ]+S2\.2[ ]+PASS"#, "S2.2 prints PASS before the panel run")
        ok(has(t, #"CHECK[ ]+S2\.2[ ]+FAIL[ ]+readable"#), "S2.2's FAIL line does not start with the readable count")
        ok(has(t, #"CHECK[ ]+S2\.2[ ]+PASS[ ]+readable"#), "S2.2's PASS line does not start with the readable count")
    }

    @Test("S2.2 confirms each screenshot-only row with `kit-fixtures.sh expect listing golden`, needs at least 4 of them, and fails on a code file")
    func s22Screenshots() {
        guard let t = body("S2.2"), let m = mine("S2.2") else { return }
        ok(has(t, fixturesCall + #"expect[ ]+listing[ ]+golden\b"#), "S2.2 never runs `kit-fixtures.sh expect listing golden`")
        ok(has(m, #"\bs2c_screenshot_rows\b"#) && has(m, #"\bs2c_listing_clash\b"#), "S2.2 does not check each screenshot-only row against the listing (s2c_screenshot_rows, s2c_listing_clash)")
        ok(has(t, #"-ge[ ]+4\b"#), "S2.2 does not require at least 4 screenshot-only rows")
        ok(has(m, #"\bs2c_code_rows\b"#), "S2.2 does not check that no exact row comes from a code file (s2c_code_rows)")
        before(t, fixturesCall + #"expect[ ]+listing"#, #"CHECK[ ]+S2\.2[ ]+PASS"#, "S2.2 prints PASS before it read the listing")
    }

    @Test("S2.2 finds the decoys of every readable exact row in the key and in the index with `kit-index.sh has golden/<file>` (s2c_decoy_problems), and fails on one that is missing")
    func s22Decoys() {
        guard let t = body("S2.2"), let m = mine("S2.2") else { return }
        ok(has(t, #"\bs2c_decoy_problems\b"#), "S2.2 does not look for the decoys (s2c_decoy_problems)")
        ok(has(m, #"\bs2c_decoy_files\b"#), "S2.2 does not list the decoys of the readable rows (s2c_decoy_files)")
        ok(has(m, indexCall + #"has[ ]+"?golden/"#), "S2.2 does not run `kit-index.sh has golden/<decoy file>`")
        ok(has(m, #"has no decoy in the key"#) && has(m, #"is not in the index"#), "S2.2 does not say which decoy is missing, in the key or in the index")
        ok(has(t, #"decoys:"#), "S2.2's failure does not name the decoy problems")
        before(t, #"\bs2c_decoy_problems\b"#, #"CHECK[ ]+S2\.2[ ]+PASS"#, "S2.2 prints PASS before it looked for the decoys")
    }

    // MARK: S2.3

    @Test("S2.3 starts from the recipe photos, searches the missing row and three strings of two, three and four tokens through the panel, each with the panel kept open and read")
    func s23Searches() {
        guard let t = body("S2.3"), let m = mine("S2.3") else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) && !has($0, #"^s1_run\b"#) && !has($0, #"^s2c_check_3\b"#) }
        ok(first.map { has($0, #"^s1_need_photos[ ]+"?S2\.3"?[ ]"#) } ?? false, "the first command of S2.3 is \(first ?? "nothing"), expected `s1_need_photos S2.3`")
        ok(has(m, #"\bs2c_missing_query\b"#), "S2.3 does not take the one-token string from the key (s2c_missing_query: the `missing` row)")
        ok(has(m, #"\bs2c_missing_words\b"#), "S2.3 does not take the two-, three- and four-token strings from s2c_missing_words")
        ok(has(t, #"\bs1_search\b[^\n]*--keep-open"#), "S2.3 does not keep the panel open for the read (`s1_search <text> --keep-open`)")
        ok(has(t, #"\bpn_dump\b"#), "S2.3 does not read the panel (pn_dump) after a search")
        before(t, #"\bs1_need_photos\b"#, #"\bs1_search\b"#, "S2.3 searches before the recipe photos")
        before(t, #"\bs1_search\b"#, #"CHECK[ ]+S2\.3[ ]+PASS"#, "S2.3 prints PASS before it searched")
    }

    @Test("S2.3 holds the split: the one-token string lists at least one file with no `No matches` and no error text, the others list no row and show `No matches`, and Sesame is still running after each search")
    func s23Verdict() {
        guard let t = body("S2.3") else { return }
        ok(has(t, #"\bs1_rows_n\b"#), "S2.3 does not read the number of rows of a search (s1_rows_n)")
        ok(has(t, #"-ge[ ]+1\b"#), "S2.3 does not require a non-empty list for the one-token string")
        ok(has(t, #"nr_has[ ]+"No matches""#), "S2.3 does not look for `No matches`")
        ok(has(t, #"nr_has_ci[ ]+"error""#), "S2.3 does not look for error text")
        ok(has(t, #"=[ ]*0[ ]*\]"#), "S2.3 does not require that a multi-token string lists no row")
        ok(has(t, #"kit_pid_of[ ]+app"#), "S2.3 does not check that the app is still running after a search (no crash)")
        ok(has(t, #"crash|no longer running|not running"#), "S2.3's failure does not say the app stopped running")
        ok(has(t, #"CHECK[ ]+S2\.3[ ]+FAIL"#), "S2.3 prints no FAIL line")
        ok(has(t, #"CHECK[ ]+S2\.3[ ]+PASS[^\n]*(one token|one-token)[^\n]*(two|2)[^\n]*(three|3)[^\n]*(four|4)"#), "S2.3's PASS line does not say the one-token split and the 2-, 3- and 4-token strings")
    }

    // MARK: S2.8

    @Test("S2.8 starts from the recipe photos and runs its parts in order: (i) the readable rows first, (ii) build unrelated 1000, the picker, Start indexing, wait done and Ready, the rows again, (iii) delete, expect-absent, restore, (iv) merge")
    func s28Order() {
        guard let t = body("S2.8"), let m = mine("S2.8") else { return }
        ok(has(t, #"\bs1_need_photos[ ]+"?S2\.8"?"#), "S2.8 does not start from the recipe photos (s1_need_photos S2.8)")
        let rounds = (try? NSRegularExpression(pattern: #"\bs2c_all_first\b"#))?.numberOfMatches(in: m, range: NSRange(location: 0, length: (m as NSString).length)) ?? 0
        ok(rounds >= 2, "S2.8 runs the readable exact rows \(rounds) times through s2c_all_first, expected before and after the unrelated files")
        before(t, #"\bs1_need_photos\b"#, #"\bs2c_all_first\b"#, "S2.8 runs its first round before the recipe photos")
        ok(has(t, #"\bs2c_decoy_problems\b"#), "S2.8 (i) does not look for the decoys of the readable rows (s2c_decoy_problems)")
        before(t, #"\bs2c_decoy_problems\b"#, #"\bs2c_all_first\b"#, "S2.8 (i) runs the rows before it looked for their decoys")
        guard let firstRound = firstIndex(t, #"\bs2c_all_first\b"#), let lastRound = lastIndex(t, #"\bs2c_all_first\b"#),
              let build = firstIndex(t, fixturesCall + #"build[ ]+unrelated[ ]+1000\b"#),
              let picker = firstIndex(t, #"PK_WINDOW=settings[ ]+drive_picker"#),
              let start = firstIndex(t, #"Start indexing"#),
              let wait = firstIndex(t, indexCall + #"wait[ ]+done[ ]+3600\b"#),
              let ready = firstIndex(t, #"\bwait_menu_ready\b"#)
        else {
            ok(false, "S2.8 lacks one of: `build unrelated 1000`, `PK_WINDOW=settings drive_picker`, `Start indexing`, `kit-index.sh wait done 3600`, `wait_menu_ready`")
            return
        }
        ok(firstRound < build && build < picker && picker < start && start < wait && wait < ready && ready < lastRound,
           "S2.8 does not run (i), then build unrelated 1000, the picker, Start indexing, wait done 3600 and Ready, then the rows again")
        ok(has(t, #"drive_picker[ ]+"[^"]*fixtures/unrelated""#), "S2.8 does not add fixtures/unrelated through Settings")
        before(t, #"\bwait_menu_ready\b"#, fixturesCall + #"mutate[ ]+delete"#, "S2.8 deletes a file before the indexing reached Ready")
        before(t, fixturesCall + #"mutate[ ]+delete"#, #"--expect-absent"#, "S2.8 looks for the file's absence before it deleted it")
        before(t, #"--expect-absent"#, goldenCall + #"merge"#, "S2.8 runs merge before part (iii)")
        before(t, goldenCall + #"merge"#, #"CHECK[ ]+S2\.8[ ]+PASS"#, "S2.8 prints PASS before merge")
        ok(has(t, #"CHECK[ ]+S2\.8[ ]+NEEDS-A-PERSON"#), "S2.8 never prints NEEDS-A-PERSON (the picker, the panel, merge)")
    }

    @Test("S2.8 (iii): the first readable exact row whose query is one token, `mutate delete` of its file, `--expect-absent` within 30 s, a non-empty closest list for the same string")
    func s28Removal() {
        guard let t = body("S2.8"), let m = mine("S2.8") else { return }
        ok(has(m, #"\bs2c_pick_one_token\b"#), "S2.8 does not pick the row for (iii) with s2c_pick_one_token (a multi-token string gives No matches, never a closest list)")
        ok(has(t, fixturesCall + #"mutate[ ]+delete[ ]+"[^"]*fixtures/golden/"#), "S2.8 does not delete the exact file under fixtures/golden through `kit-fixtures.sh mutate delete`")
        ok(has(t, #"\bs1_search\b[^\n]*--expect-absent"#), "S2.8 does not run `kit-search.sh \"<string>\" --expect-absent <path>` (s1_search)")
        ok(has(t, #"-lt[ ]+30\b"#), "S2.8 does not wait at most 30 s for the removal")
        ok(has(t, #"\bs1_rows_n\b"#) && has(t, #"-ge[ ]+1\b"#), "S2.8 does not require a non-empty closest list for the same string")
        ok(has(t, #"closest"#), "S2.8's failure does not say the closest list")
    }

    @Test("S2.8 restores the fixtures and drops the recipe mark on every path: the check runs inside a wrapper that calls restore after the body, and the restore drops $S1_MARK")
    func s28Restore() {
        let all = allFunctions()
        guard let wrapper = all["check_S2_8"], let run = all["s2c_run_8"], let restore = all["s2c_restore"] else {
            ok(false, "check_S2_8, s2c_run_8 or s2c_restore is not defined")
            return
        }
        ok(has(wrapper, #"\bs1_run\b[ ]+s2c_run_8\b"#), "check_S2_8 does not run its body through s1_run s2c_run_8 (the panel and the kit window are closed on every path)")
        ok(has(run, #"\bs2c_check_8\b"#) && has(run, #"\bs2c_restore\b"#), "s2c_run_8 does not call the body and s2c_restore")
        before(run, #"\bs2c_check_8\b"#, #"\bs2c_restore\b"#, "s2c_run_8 restores before the body ran")
        ok(has(run, #"return[ ]+"?\$"#), "s2c_run_8 loses the body's status")
        ok(has(restore, fixturesCall + #"restore\b"#) || has(substitute(restore, topLevelValues()), fixturesCall + #"restore\b"#), "s2c_restore does not run `kit-fixtures.sh restore`")
        ok(has(restore, #"rm[ ]+-f[ ]+"\$S1_MARK""#), "s2c_restore does not drop $S1_MARK (the index is polluted, the next check must make its own starting state)")
    }

    @Test("S2.8 (iv) reads `kit-golden.sh merge` through s2c_rank_summary, fails when no odd or no even row was printed, and never lowers a bar for `noted: overfitting risk`")
    func s28Merge() {
        guard let t = body("S2.8"), let m = mine("S2.8") else { return }
        ok(has(t, goldenCall + #"merge\b"#), "S2.8 never runs `kit-golden.sh merge`")
        ok(has(m, #"\bs2c_rank_summary\b"#), "S2.8 does not score the odd and even rows apart (s2c_rank_summary)")
        ok(has(t, #"\b3\)"#) || has(t, #"=[ ]*3[ ]*\]"#), "S2.8 does not branch on exit 3 of merge")
        ok(has(t, #"odd"#) && has(t, #"even"#), "S2.8's failure does not name the odd and even rows")
        ok(!has(t, #"overfitting[^\n]*\n[^\n]*return[ ]+1"#), "S2.8 turns the overfitting note into a failure: the spec says it is noted")
    }

    @Test("S2.8 has no (v) step: no `SKIPPED slice 6`, the PASS line says (i) to (iv), and no language matrix is read from merge")
    func s28Skipped() {
        guard let t = body("S2.8") else { return }
        ok(!t.contains("SKIPPED slice 6"), "S2.8 still prints `SKIPPED slice 6`")
        ok(has(t, #"CHECK[ ]+S2\.8[ ]+PASS[^\n]*\(i\) to \(iv\)"#), "S2.8's PASS line does not say `(i) to (iv)`")
        ok(!has(t, #"waits for slice 6"#), "S2.8 still says (v) waits for slice 6")
        ok(!has(t, #"s2c_langs_line|\(v\)"#), "S2.8 still reads the language matrix line of merge or names (v)")
        ok(!has(t, #"CHECK[ ]+S2\.8[ ]+SKIPPED"#), "S2.8 prints CHECK S2.8 SKIPPED: the runner counts that line as a skip and the run fails")
    }

    // MARK: S2.17

    @Test("S2.17 starts with tree_need and kit-index.sh wait done 900, never closes the window, and takes its kinds from read-kinds.txt")
    func s217Starts() {
        guard let t = body("S2.17"), let m = mine("S2.17") else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) && !has($0, #"^s1_run\b"#) && !has($0, #"^s2c_check_17\b"#) && !has($0, #"^kinds="#) && !has($0, #"^\[ -n "\$kinds" \]"#) }
        ok(first.map { has($0, #"^tree_need[ ]+"?S2\.17"?([ ;]|$)"#) } ?? false, "the first command of S2.17 is \(first ?? "nothing"), expected `tree_need S2.17`")
        ok(has(t, indexCall + #"wait[ ]+done[ ]+900\b"#), "S2.17 does not run `kit-index.sh wait done 900`")
        before(t, #"\btree_need\b"#, indexCall + #"wait[ ]+done[ ]+900"#, "S2.17 waits for done before the session was made")
        before(t, indexCall + #"wait[ ]+done[ ]+900"#, fixturesCall + #"expect[ ]+extensions"#, "S2.17 reads the extensions before the index is done")
        ok(!has(m, #"\bs8_close_window\b|\bs8_activity\b|\bs8_net_summary\b|\bs8d_[a-z_]+\b|\bwindow-ids\b|observers-closed-at"#), "S2.17 closes the observed window or reads the S8 session: it runs inside it and never closes it")
        ok(has(m, #"\bgolden_read_kinds\b"#), "S2.17 does not take its kinds from read-kinds.txt (golden_read_kinds)")
        ok(has(t, fixturesCall + #"expect[ ]+extensions[ ]+--kinds[ ]+"\$\{?[A-Za-z_]+\}?""#), "S2.17 does not run `kit-fixtures.sh expect extensions --kinds <read-kinds>`")
        ok(!has(m, #"\bphoto\b|\bdocument\b|\baudio\b|\bvideo\b|\bpdf\b|\bjpe?g\b|\bpng\b|\bheic\b|\bwebp\b|\btiff?\b|\bgif\b"#), "S2.17 writes a kind or an extension: they come from read-kinds.txt and extensions.txt")
        ok(has(t, #"CHECK[ ]+S2\.17[ ]+NEEDS-A-PERSON"#), "S2.17 never prints NEEDS-A-PERSON (an exit 3 of tree_need)")
    }

    @Test("S2.17: for each extension, the ext- cell is done in the index (kit-index.sh under, s2c_row_status) and its name stem searched alone lists it first (s2c_first_row_holds); a failing extension is named")
    func s217PerExtension() {
        guard let t = body("S2.17"), let m = mine("S2.17") else { return }
        ok(has(m, #"\bs2c_ext_cells\b"#), "S2.17 does not take the cell of each extension from the gate matrix (s2c_ext_cells)")
        ok(has(t, indexCall + #"under[ ]+"?matrix/"#), "S2.17 does not read the index under matrix/ with `kit-index.sh under`")
        ok(has(m, #"\bs2c_row_status\b"#) && has(m, #"\bdone\b"#), "S2.17 does not require the status done (s2c_row_status)")
        ok(has(t, #"\bs1_search\b"#) && has(m, #"\bs2c_first_row_holds\b"#), "S2.17 does not search the stem and read row 1 (s1_search, s2c_first_row_holds)")
        ok(has(t, #"extension[ ]+\$\{?[A-Za-z_]+\}?"#), "S2.17's failure does not name the extension")
        ok(has(t, #"CHECK[ ]+S2\.17[ ]+FAIL"#), "S2.17 prints no FAIL line")
        before(t, indexCall + "under", #"CHECK[ ]+S2\.17[ ]+PASS"#, "S2.17 prints PASS before it read the index")
        before(t, #"\bs1_search\b"#, #"CHECK[ ]+S2\.17[ ]+PASS"#, "S2.17 prints PASS before it searched")
    }

    // MARK: S6.13

    @Test("S6.13 starts with s8_net_summary S6.13: 3 is NEEDS-A-PERSON, 4 and any other failure a RERUN that returns 4, 0 and 1 go on")
    func s613Starts() {
        guard let t = body("S6.13") else { return }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty && !has($0, #"^local\b"#) }
        ok(first.map { has($0, #"^s8_net_summary[ ]+"?S6\.13"?([ ;]|$)"#) } ?? false, "the first command of check_S6_13 is \(first ?? "nothing"), expected `s8_net_summary S6.13` (so it runs in any order)")
        ok(has(t, #"\b3\)"#), "check_S6_13 does not branch on exit 3 of s8_net_summary")
        ok(has(t, #"CHECK[ ]+S6\.13[ ]+NEEDS-A-PERSON"#), "check_S6_13 never prints NEEDS-A-PERSON")
        ok(has(t, #"\b0\|1\)|\b1\|0\)"#), "check_S6_13 does not let exits 0 and 1 of s8_net_summary through to its own verdict")
        ok(has(t, #"S8_NET_TEXT"#), "check_S6_13 does not read the summary text s8_net_summary left")
        before(t, #"\bs8_net_summary\b"#, #"CHECK[ ]+S6\.13[ ]+PASS"#, "check_S6_13 prints PASS before s8_net_summary")
    }

    @Test("S6.13 reads the mirror's request log with kit-mirror.sh requests through s8_mirror_strays (the fractional-time function of checks-s8.sh, with models.tsv), and the summary's failing lines with s8d_failure_lines; a log with no request is a RERUN, never a pass")
    func s613Reads() {
        guard let t = body("S6.13") else { return }
        ok(has(t, #"kit-mirror\.sh"?[ ]+requests\b"#), "check_S6_13 never runs `kit-mirror.sh requests`")
        ok(has(t, #"\bs8_mirror_strays\b[ ]+"[^"]*models\.tsv""#), "check_S6_13 does not call s8_mirror_strays with models.tsv: the old integer-time pattern never matched a real log line")
        ok(has(t, #"\bs8_mirror_count\b"#), "check_S6_13 does not count the requests (s8_mirror_count): a log with none proves nothing")
        ok(has(t, #"\bs8d_failure_lines\b"#), "check_S6_13 does not take the failing lines of the net summary (s8d_failure_lines)")
        ok(has(t, #"RERUN[ ]+S6\.13[ ]+not valid:[^\n]*(no request|holds no)"#), "check_S6_13 has no RERUN for a mirror log with no request")
        ok(has(t, #"CHECK[ ]+S6\.13[ ]+FAIL[^\n]*other than"#), "check_S6_13's FAIL line does not say a request or destination other than the model files and the mirror")
        ok(has(t, #"CHECK[ ]+S6\.13[ ]+PASS[^\n]*(two model file names|model file names)"#), "check_S6_13's PASS line does not say the log lists only the two model file names")
        ok(!has(t, #"\[0-9\]\+[ ]\[A-Z\]\+"#), "check_S6_13 holds the old integer-time pattern")
        before(t, #"kit-mirror\.sh"?[ ]+requests"#, #"CHECK[ ]+S6\.13[ ]+PASS"#, "check_S6_13 prints PASS before it read the mirror log")
    }

    @Test("S6.13 only reads: no observer start or stop, no mirror control, no net or trace tool of its own, no search, no recipe")
    func s613ReadsOnly() {
        guard let m = mine("S6.13") else { return }
        ok(!has(m, #"kit-trace\.sh|kit-net\.sh|kit-privacy\.sh"?[ ]+prompts"#), "check_S6_13 runs a net, trace or prompts tool itself: s8_net_summary owns them")
        ok(!has(m, #"kit-mirror\.sh"?[ ]+(start|stop|rate|offline|online|seed|status)\b"#), "check_S6_13 controls or starts the mirror")
        ok(!has(m, #"kit-search\.sh|kit-ax\.sh|\brecipe_[a-z]+\b|\btree_need\b|\bs1_need_photos\b|\bs8_close_window\b|\bs8_activity\b"#), "check_S6_13 drives the panel or makes a starting state: it reads what the session left")
    }

    // MARK: the pure helpers, run as a child shell on hand-written files (no check, no kit script, no app)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun2s6-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("project/fixtures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root/run"), withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sources checks-s2c.sh in a child bash (only the definitions and the golden.sh line run), then points KIT_LIB at the temp folder
    /// of hand-written tables and calls one helper.
    private func helper(_ call: String, in dir: URL) throws -> Ran {
        let script = "export KIT_LIB='\(libDir.path)' KIT_ROOT='\(dir.path)/root' KIT_PROJECT='\(dir.path)/project'; . '\(checkFile.path)'; KIT_LIB='\(dir.path)/lib'; \(call)"
        return try run("/bin/bash", ["-c", script])
    }

    private func needFile() -> Bool {
        if FileManager.default.fileExists(atPath: checkFile.path) { return true }
        Issue.record("scripts/kit-lib/checks-s2c.sh not found")
        return false
    }

    private func lines(_ ran: Ran) -> [String] {
        ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// A hand-written key: two screenshot rows (the first with a two-token query), a photo-format row, a code row, a pdf row, the missing
    /// row and decoys, one of which is for the pdf row.
    private let answers = """
    id,group,query,file,locator,window_s,note
    exact-01,exact,two word query,photos/screenshot-chat.png,,,screenshot-only
    exact-02,exact,ERR_CONNECTION_RESET,photos/screenshot-browser-error.png,,,screenshot-only
    exact-03,exact,DSC_0042.jpg,photos/DSC_0042.jpg,,,in the file name
    exact-04,exact,retryWithBackoff,api/retry.swift,,,in the text of a code file
    exact-05,exact,INV-1,pdfs/inv.pdf,1,,in the file name
    missing-01,missing,zzz-nowhere-1,,,,present in no file
    decoy-01,decoy,two word query,photos/server.png,,,decoy-for=exact-01; a server
    decoy-02,decoy,two word query,photos/server-two.png,,,decoy-for=exact-01; another server
    decoy-03,decoy,ERR_CONNECTION_RESET,photos/cable.gif,,,decoy-for=exact-02; a cable
    decoy-04,decoy,DSC_0042.jpg,photos/PXL_0001.png,,,decoy-for=exact-03; another camera name
    decoy-05,decoy,INV-1,pdfs/inv-two.pdf,,,decoy-for=exact-05; the next invoice

    """

    private func keyFolder(readKinds: String = "photo\n") throws -> URL {
        let dir = try scratch()
        try write(answers, dir.appendingPathComponent("project/fixtures/answers.csv"))
        try write("# six lists\nphoto: jpeg jpg png gif\ndocument: txt md\npdf: pdf\ncode: swift py\n", dir.appendingPathComponent("lib/extensions.txt"))
        try write(readKinds, dir.appendingPathComponent("lib/read-kinds.txt"))
        return dir
    }

    @Test("s2c_screenshot_rows prints id, query and file of every exact row whose note starts screenshot-only; s2c_code_rows the exact rows whose file has a code extension of extensions.txt; s2c_missing_query the query of the missing row")
    func keyReaders() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shots = try helper("s2c_screenshot_rows", in: dir)
        ok(lines(shots) == ["exact-01\ttwo word query\tphotos/screenshot-chat.png", "exact-02\tERR_CONNECTION_RESET\tphotos/screenshot-browser-error.png"],
           "s2c_screenshot_rows printed \(lines(shots)), expected the two screenshot-only rows with a tab between id, query and file")
        let code = try helper("s2c_code_rows", in: dir)
        ok(lines(code) == ["exact-04\tapi/retry.swift"], "s2c_code_rows printed \(lines(code)), expected exact-04 api/retry.swift")
        let missing = try helper("s2c_missing_query", in: dir)
        ok(missing.output.trimmingCharacters(in: .whitespacesAndNewlines) == "zzz-nowhere-1", "s2c_missing_query printed \(missing.output.debugDescription), expected zzz-nowhere-1")
    }

    // Amended in plan-4-t2 (the title said "the kinds of read-kinds.txt decide which rows are readable", and the test expected the
    // pdf row's decoy once `pdf` was listed and no pick with no kind listed): group b is a photo-only selection of its own from
    // plan 4 on, because the pdf and document exact rows are group c's, and read-kinds.txt now lists document and pdf. So the
    // readable rows of group b are the photo rows whatever read-kinds.txt lists. Not weakened: every row printed is still pinned.
    @Test("s2c_pick_one_token prints the first readable exact row whose query is one token and s2c_decoy_files the decoys of the readable rows only: the photo rows of group b, whatever read-kinds.txt lists")
    func readableRows() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pick = try helper("s2c_pick_one_token", in: dir)
        ok(lines(pick) == ["exact-02\tERR_CONNECTION_RESET\tphotos/screenshot-browser-error.png"], "s2c_pick_one_token printed \(lines(pick)), expected exact-02 (exact-01 holds three words)")
        let decoys = try helper("s2c_decoy_files", in: dir)
        ok(lines(decoys) == ["exact-01\tphotos/server.png", "exact-01\tphotos/server-two.png", "exact-02\tphotos/cable.gif", "exact-03\tphotos/PXL_0001.png"],
           "s2c_decoy_files printed \(lines(decoys)), expected the decoys of exact-01, 02 and 03 (exact-05 is a pdf, with no reader under `photo`)")
        let withPdf = try keyFolder(readKinds: "photo\npdf\n")
        defer { try? FileManager.default.removeItem(at: withPdf) }
        let more = try helper("s2c_decoy_files", in: withPdf)
        ok(lines(more) == lines(decoys), "s2c_decoy_files printed \(lines(more)) with pdf listed, expected the same decoys as with photo only \(lines(decoys)): the pdf row is group c's, not group b's")
        ok(!lines(more).contains("exact-05\tpdfs/inv-two.pdf"), "the pdf row's decoy is in group b's decoys (the pdf row is group c's)")
        let none = try keyFolder(readKinds: "")
        defer { try? FileManager.default.removeItem(at: none) }
        let nothing = try helper("s2c_pick_one_token", in: none)
        ok(lines(nothing) == lines(pick), "s2c_pick_one_token printed \(lines(nothing)) with no kind listed, expected \(lines(pick)): group b does not depend on read-kinds.txt")
    }

    @Test("s2c_listing_clash <query> prints every listed path whose file name holds the query (case ignored) and nothing for the LISTING line")
    func listingClash() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let listing = "photos/DSC_0042.jpg\nphotos/err_connection_reset-copy.png\nphotos/screenshot-chat.png\nphotos/server.png\nLISTING OK golden: 4 paths\n"
        let file = dir.appendingPathComponent("lib/listing.txt")
        try write(listing, file)
        let cases: [(String, [String])] = [
            ("ERR_CONNECTION_RESET", ["photos/err_connection_reset-copy.png"]),
            ("DSC_0042.jpg", ["photos/DSC_0042.jpg"]),
            ("two word query", []),
            ("kubectl rollout restart deploy/billing", []),
            ("paths", []),
        ]
        for (query, expected) in cases {
            let ran = try helper("s2c_listing_clash '\(query)' < '\(file.path)'", in: dir)
            ok(lines(ran) == expected, "s2c_listing_clash '\(query)' printed \(lines(ran)), expected \(expected)")
        }
    }

    @Test("s2c_not_first <tsv> names the group b rows of golden-engine.tsv or golden-panel.tsv whose rank is not 1, as id=rank, and prints nothing when every row is first")
    func notFirst() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = "id\tgroup\tquery\texpected\trank\tlocator\tpass\n"
        let rows = "photo-01\ta\ta dog\tphotos/a.jpg\t3\t\ttop3\nexact-01\tb\tq1\tphotos/x.png\t1\t\tfirst\nexact-02\tb\tq2\tphotos/y.png\t2\t\ttop3\nexact-03\tb\tq3\tphotos/z.png\tnone\t\tmiss\n"
        let bad = dir.appendingPathComponent("lib/bad.tsv")
        try write(header + rows, bad)
        let good = dir.appendingPathComponent("lib/good.tsv")
        try write(header + "photo-01\ta\tq\tf\t5\t\tmiss\nexact-01\tb\tq1\tphotos/x.png\t1\t\tfirst\n", good)
        let r1 = try helper("s2c_not_first '\(bad.path)'", in: dir)
        ok(r1.output.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } == ["exact-02=2", "exact-03=none"],
           "s2c_not_first printed \(r1.output.debugDescription), expected exact-02=2 exact-03=none (group a is not group b)")
        let r2 = try helper("s2c_not_first '\(good.path)'", in: dir)
        ok(r2.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s2c_not_first printed \(r2.output.debugDescription) when every group b row is first, expected nothing")
    }

    @Test("s2c_rank_summary reads RANK lines: the odd and the even rows apart, `noted: overfitting risk` when the even rows hit at least 2 fewer, and only well-formed RANK lines count")
    func rankSummary() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Case { let name: String; let text: String; let expected: [String] }
        let cases = [
            Case(name: "even rows hit 2 fewer", text: "RANK exact-01 1 odd\nRANK exact-02 2 even\nRANK exact-03 1 odd\nRANK exact-04 none even\nRANK exact-05 1 odd\nRANK exact-06 1 even\n",
                 expected: ["odd first 3 of 3, even first 1 of 3", "noted: overfitting risk"]),
            Case(name: "even rows hit 1 fewer", text: "RANK exact-01 1 odd\nRANK exact-02 2 even\nRANK exact-03 1 odd\nRANK exact-04 1 even\n",
                 expected: ["odd first 2 of 2, even first 1 of 2"]),
            Case(name: "the even rows are better", text: "RANK exact-01 2 odd\nRANK exact-02 1 even\n", expected: ["odd first 0 of 1, even first 1 of 1"]),
            Case(name: "no even row", text: "RANK exact-01 1 odd\nRANK exact-03 1 odd\n", expected: ["odd first 2 of 2, even first 0 of 0", "noted: overfitting risk"]),
            Case(name: "other lines and bad lines are left out", text: "GOLDEN exact-01 rank 1\nRANK exact-01 1 odd\nRANK exact-02 1\nnoise\nRANK exact-02 1 even\n", expected: ["odd first 1 of 1, even first 1 of 1"]),
        ]
        for c in cases {
            let file = dir.appendingPathComponent("lib/rank.txt")
            try write(c.text, file)
            let ran = try helper("s2c_rank_summary < '\(file.path)'", in: dir)
            ok(lines(ran) == c.expected, "s2c_rank_summary for \(c.name) printed \(lines(ran)), expected \(c.expected)")
        }
    }

    @Test("s2c_ext_cells <kinds> prints each extension of those kinds, in the order of extensions.txt, with the path of its ext- cell, and `-` when the matrix has no such cell")
    func extCells() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("cell,path,picks,expected_in_index,expected_rows,expected_reason,group\nplain-photo,plain/photo_zq0001.png,,yes,1,ok,spec\next-jpeg,ext/jpeg_zq0011.jpeg,,yes,1,ok,spec\next-jpg,ext/jpg_zq0012.jpg,,yes,1,ok,spec\next-png,ext/png_zq0013.png,,yes,1,ok,spec\next-gif,ext/gif_zq0018.gif,,yes,1,ok,spec\next-txt,ext/txt_zq0031.txt,,yes,1,ok,spec\n", dir.appendingPathComponent("lib/gate-matrix.csv"))
        let photo = try helper("s2c_ext_cells photo", in: dir)
        ok(lines(photo) == ["jpeg\text/jpeg_zq0011.jpeg", "jpg\text/jpg_zq0012.jpg", "png\text/png_zq0013.png", "gif\text/gif_zq0018.gif"], "s2c_ext_cells photo printed \(lines(photo))")
        let mixed = try helper("s2c_ext_cells photo,pdf,document", in: dir)
        ok(lines(mixed) == ["jpeg\text/jpeg_zq0011.jpeg", "jpg\text/jpg_zq0012.jpg", "png\text/png_zq0013.png", "gif\text/gif_zq0018.gif", "txt\text/txt_zq0031.txt", "md\t-", "pdf\t-"],
           "s2c_ext_cells photo,pdf,document printed \(lines(mixed)), expected the order of extensions.txt (photo, document, pdf) with `-` for md and pdf, which have no ext- cell")
        let code = try helper("s2c_ext_cells code", in: dir)
        ok(lines(code) == ["swift\t-", "py\t-"], "s2c_ext_cells code printed \(lines(code)), expected swift and py with no cell")
        let none = try helper("s2c_ext_cells nokind", in: dir)
        ok(none.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "s2c_ext_cells nokind printed \(none.output.debugDescription), expected nothing")
    }

    @Test("s2c_row_status <suffix> reads `kit-index.sh under` output (path, kind, status; the /var and /private/var spellings; the closing count line) and prints the status of the row whose path ends with the suffix")
    func rowStatus() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let under = "/private/var/k/fixtures/matrix/ext/jpeg_zq0011.jpeg\tphoto\tdone\n/private/var/k/fixtures/matrix/ext/jpg_zq0012.jpg\tphoto\tcould_not_read\n/var/k/fixtures/matrix/ext/gif_zq0018.gif\tphoto\tpending\n3 files under /var/k/fixtures/matrix/ext\n"
        let file = dir.appendingPathComponent("lib/under.txt")
        try write(under, file)
        let cases: [(String, String)] = [
            ("/fixtures/matrix/ext/jpeg_zq0011.jpeg", "done"), ("/fixtures/matrix/ext/jpg_zq0012.jpg", "could_not_read"),
            ("/fixtures/matrix/ext/gif_zq0018.gif", "pending"), ("/fixtures/matrix/ext/png_zq0013.png", ""),
            ("/fixtures/matrix/ext/jpeg_zq0011.jpe", ""), ("/fixtures/matrix/ext", ""),
        ]
        for (suffix, expected) in cases {
            let ran = try helper("s2c_row_status '\(suffix)' < '\(file.path)'", in: dir)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected, "s2c_row_status '\(suffix)' printed \(ran.output.debugDescription), expected \(expected.debugDescription)")
        }
    }

    @Test("s2c_first_row_holds <file> reads kit-search.sh output: status 0 only when row 1 holds the file name; s2c_rank_in_out <file> prints the first row that does, nothing when none does")
    func searchRows() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = "search box label=\"Search your files\" value=\"x\"\nrows 3\nrow 1 selected jpg_zq0012.jpg | /k/matrix/ext/jpg_zq0012.jpg\nrow 2 - jpeg_zq0011.jpeg | /k/matrix/ext/jpeg_zq0011.jpeg\nrow 3 - gif_zq0018.gif | /k/matrix/ext/gif_zq0018.gif\npane Preview\n"
        let file = dir.appendingPathComponent("lib/search.txt")
        try write(out, file)
        let first = try helper("s2c_first_row_holds 'jpg_zq0012.jpg' < '\(file.path)'", in: dir)
        ok(first.status == 0, "s2c_first_row_holds jpg_zq0012.jpg exited \(first.status), expected 0 (it is row 1)")
        let second = try helper("s2c_first_row_holds 'jpeg_zq0011.jpeg' < '\(file.path)'", in: dir)
        ok(second.status == 1, "s2c_first_row_holds jpeg_zq0011.jpeg exited \(second.status), expected 1 (it is row 2)")
        let absent = try helper("s2c_first_row_holds 'png_zq0013.png' < '\(file.path)'", in: dir)
        ok(absent.status == 1, "s2c_first_row_holds png_zq0013.png exited \(absent.status), expected 1 (no row)")
        let cases: [(String, String)] = [("jpg_zq0012.jpg", "1"), ("jpeg_zq0011.jpeg", "2"), ("/x/gif_zq0018.gif", "3"), ("png_zq0013.png", "")]
        for (name, expected) in cases {
            let ran = try helper("S1_OUT=\"$(cat '\(file.path)')\"; s2c_rank_in_out '\(name)'", in: dir)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected, "s2c_rank_in_out \(name) printed \(ran.output.debugDescription), expected \(expected.debugDescription)")
        }
    }

    @Test("s2c_missing_words prints three strings of two, three and four tokens, each word in no file name or text of the fixture tables, no word twice")
    func missingWords() throws {
        guard needFile() else { return }
        let dir = try keyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = try helper("s2c_missing_words", in: dir)
        let strings = lines(ran)
        ok(strings.map { $0.split(separator: " ").count } == [2, 3, 4], "s2c_missing_words printed \(strings), expected strings of 2, 3 and 4 tokens")
        let words = strings.flatMap { $0.split(separator: " ").map { String($0).lowercased() } }
        ok(Set(words).count == words.count && words.allSatisfy { $0.count >= 4 }, "s2c_missing_words repeats a word or holds a word of fewer than 4 letters: \(words)")
        var tables = ["fixtures/answers.csv": projectRoot.appendingPathComponent("fixtures/answers.csv")]
        for name in ["golden-photos.tsv", "tree.tsv", "gate-matrix.csv", "home.tsv", "overlap.tsv", "queries-distinct20.txt", "queries-distinct20b.txt"] {
            tables["kit-lib/\(name)"] = libDir.appendingPathComponent(name)
        }
        for (name, url) in tables {
            guard let text = read(url)?.lowercased() else { Issue.record(Comment(rawValue: "\(name) not found")); continue }
            for w in words where text.contains(w) {
                ok(false, "the word \"\(w)\" of s2c_missing_words is in \(name): it is not a word in no file")
            }
        }
    }
}

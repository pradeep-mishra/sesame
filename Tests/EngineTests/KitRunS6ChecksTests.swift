import Foundation
import Testing

// plan-2-t11, tester step: kit part 7, the S6 checks and the runner's selection (scripts/kit-run.sh, the check files
// scripts/kit-lib/checks-*.sh, scripts/kit-lib/recipes.sh, scripts/kit-lib/checks.tsv). Written from verify.md, the S6
// feature map, the design and the plan-2-t11 entry only; no product source is read, and no kit function may read
// `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions; the person's ruling "no app launch"): `kit-run.sh` drives the app,
// so NOTHING here executes it, not even with no mode. The runs are `bash -n` on the files, and one call of the shell
// function `kit_evidence_dir` of kit-lib/common.sh in a temp KIT_ROOT (it reads two small files and starts nothing).
// Every other check reads the text of the scripts, with their comment lines removed (a comment never satisfies a
// check), and reads a check function as the shell would run it: every call of a function of the kit is replaced, in
// place, by that function's own code, and every simple top-level variable (S6_AX="$KIT_SCRIPTS/kit-ax.sh") by its value.
// Real behaviour is driven against the live app at the accept stage only (blocks B, C and D).
//
// The contract read here (plan-2-t11, Tests, and the feature map S6):
//   - checks.tsv registers S6.1 to S6.4 and S6.8 to S6.11 at slice 2 (kind auto) and keeps S6.5 to S6.7 and S6.12 at
//     slice 1; each id has exactly one function check_S6_<n>; S6.11 says "partial";
//   - kit-run.sh: `<S> --ids <id,id,...>` refuses an id of another scenario with a usage error (exit 2, nothing runs);
//     `prep setup [--trace <name>]` and `prep minimix [--no-start]` are recipes (reset, fixtures built before the app
//     starts, throttled mirror, the trace started before the app when asked; the mini mix picked through the picker,
//     Start pressed only without --no-start); each id's evidence is saved under the scenario of the id (the variable
//     KIT_EVIDENCE_SCENARIO, which kit_evidence_dir of common.sh honours), not under the id given to kit-reset.sh;
//   - S6.1 to S6.4, S6.8 to S6.12: the contract of the feature map S6, each function one by one;
//   - typing goes through kit-ax.sh with KIT_TYPE_DELAY_MS honoured (no delay of its own, no other key tool).
// Red before the kit part: the ids have no function, the recipes `setup` and `minimix` do not exist, the usage lacks
// them, the runner sets no evidence scenario.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

private let newIds = ["S6.1", "S6.2", "S6.3", "S6.4", "S6.8", "S6.10", "S6.11"]
private let slice1Ids = ["S6.5", "S6.6", "S6.7", "S6.12"]
private let allIds = newIds + slice1Ids

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs a program that is not a kit script (`/bin/bash -n`, or `/bin/bash -c` that only sources common.sh).
private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
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

/// The code of scripts/<name>, or nil after recording the reason a missing file is red.
private func scriptCode(_ name: String) -> String? {
    let url = scriptsDir.appendingPathComponent(name)
    guard let text = read(url) else {
        Issue.record("scripts/\(name) not found")
        return nil
    }
    return stripComments(text)
}

/// The names of every shell file of scripts/kit-lib, sorted.
private func kitLibShellNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []
    return names.filter { $0.hasSuffix(".sh") }.sorted()
}

private func checkFileNames() -> [String] {
    kitLibShellNames().filter { $0.hasPrefix("checks-") }
}

/// The code of every shell file of the kit that the runner sources, and of the runner itself, as (name, code).
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

/// Simple top-level variables (NAME="value", NAME='value', NAME=value on a line that starts in column 0).
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

/// A function of the kit as the shell would run it: calls and variables written in. Records the reason and returns
/// nil when the function does not exist.
private func contract(of function: String) -> String? {
    let functions = allFunctions()
    guard let body = functions[function] else {
        Issue.record(Comment(rawValue: "\(function) is not defined in scripts/kit-run.sh or scripts/kit-lib/*.sh"))
        return nil
    }
    return substitute(expandShell(body, functions, skipping: [function]), topLevelValues())
}

private func checkFunctionName(_ id: String) -> String {
    "check_" + id.replacingOccurrences(of: ".", with: "_")
}

/// The check of an id, read as the shell would run it.
private func check(_ id: String) -> String? {
    contract(of: checkFunctionName(id))
}

/// The text of a `case` branch of a function body: from `<label>)` to the line with `;;`.
private func caseBranch(_ label: String, in body: String) -> String? {
    let open = "^[ \\t]*(([A-Za-z0-9_-]+\\|)*)\(NSRegularExpression.escapedPattern(for: label))(\\|[A-Za-z0-9_|-]+)?\\)"
    var found: [String] = []
    var inside = false
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if !inside, has(line, open) { inside = true }
        if inside {
            found.append(line)
            if line.contains(";;") { break }
        }
    }
    return inside ? found.joined(separator: "\n") : nil
}

private func before(_ text: String, _ a: String, _ b: String, _ message: String,
                    sourceLocation: SourceLocation = #_sourceLocation) {
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

@Suite("KitRunS6ChecksTests")
struct KitRunS6ChecksTests {

    // MARK: syntax

    @Test("bash -n finds no syntax error in the runner and the kit-lib shell files (none is run)")
    func bashSyntax() throws {
        var paths = [scriptsDir.appendingPathComponent("kit-run.sh").path]
        paths += kitLibShellNames().map { libDir.appendingPathComponent($0).path }
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                Issue.record(Comment(rawValue: "\(path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(path) exited \(ran.status): \(ran.output)")
        }
    }

    // MARK: checks.tsv and the functions

    @Test("checks.tsv registers S6.1 to S6.4, S6.8, S6.10 and S6.11 at slice 2, kind auto, and nothing twice", arguments: newIds)
    func registeredAtSlice2(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == "2", "\(id) is registered at slice \(row.slice), expected 2")
            ok(row.kind == "auto", "\(id) has kind \(row.kind), expected auto (verify.md: only S7.4 and S7.18 of slice 2 are auto-or-person)")
        }
    }

    @Test("checks.tsv keeps the plan-1 S6 ids at slice 1 (S6.12 is rerun at slice 2) and S6.13 at slice 3")
    func plan1IdsKept() {
        guard let rows = tsvRows() else { return }
        for id in ["S6.5", "S6.6", "S6.7", "S6.12"] {
            ok(rows.contains { $0.id == id && $0.slice == "1" && $0.kind == "auto" }, "checks.tsv lost the plan-1 row of \(id)")
        }
        ok(rows.contains { $0.id == "S6.13" && $0.slice == "3" }, "checks.tsv lost the row of S6.13")
        let ids = rows.map(\.id)
        ok(Set(ids).count == ids.count, "checks.tsv registers an id twice")
    }

    @Test("every S6 id has exactly one check function in the check files", arguments: allIds)
    func exactlyOneFunction(_ id: String) {
        let name = checkFunctionName(id)
        var count = 0
        var where_: [String] = []
        for file in checkFileNames() {
            guard let text = read(libDir.appendingPathComponent(file)) else { continue }
            let n = stripComments(text).split(separator: "\n").filter { $0.hasPrefix("\(name)() {") }.count
            count += n
            if n > 0 { where_.append(file) }
        }
        ok(count == 1, "\(name) is defined \(count) times in scripts/kit-lib/checks-*.sh (\(where_.joined(separator: ", "))), expected once")
    }

    // MARK: the runner

    @Test("kit-run.sh usage names --ids and the two new recipes, and keeps the plan-1 recipes")
    func runnerUsage() {
        guard let code = scriptCode("kit-run.sh") else { return }
        let usage = shellFunctions(in: code)["usage"] ?? ""
        ok(!usage.isEmpty, "kit-run.sh has no usage function")
        ok(usage.contains("kit-run.sh <S1..S4|S6..S10|all> [--slice N | --ids <id,id,...>]"), "usage does not show `<S> [--slice N | --ids <id,id,...>]` (plan-8-t9 amended: the usage lists S6..S10, was S6..S9)")
        ok(usage.contains("kit-run.sh prep setup [--trace <name>]"), "usage does not show `kit-run.sh prep setup [--trace <name>]`")
        ok(usage.contains("kit-run.sh prep minimix [--no-start]"), "usage does not show `kit-run.sh prep minimix [--no-start]`")
        for old in ["prep fresh-throttled", "prep photos [--no-wait] [--cache-dir <dir>]", "prep busy50k"] {
            ok(usage.contains(old), "usage lost the plan-1 line `\(old)`")
        }
    }

    @Test("kit-run.sh --ids refuses an id of another scenario with a usage error and runs nothing")
    func runnerIdsRefusal() {
        guard let code = scriptCode("kit-run.sh") else { return }
        let main = shellFunctions(in: code)["main"] ?? ""
        ok(!main.isEmpty, "kit-run.sh has no main function")
        guard let ids = caseBranch("--ids", in: main) else {
            ok(false, "main of kit-run.sh has no `--ids)` branch")
            return
        }
        ok(has(ids, "idlist=\"\\$2\""), "the `--ids)` branch does not keep its argument")
        // the loop over the list: each id must be an id of that scenario in checks.tsv
        ok(has(main, "for one in \\$\\(printf '%s' \"\\$idlist\" \\| tr ',' ' '\\)"), "main does not walk the comma list one id at a time")
        ok(has(main, "index\\(\\$1, scen \"\\.\"\\) == 1"), "an id is not tested against the scenario prefix of checks.tsv, so an id of another scenario is accepted")
        let refuse = firstIndex(main, "unknown check id for")
        ok(refuse != nil, "main does not print `unknown check id for <S>: <id>`")
        if let refuse {
            let tail = String(main[main.index(main.startIndex, offsetBy: refuse)...])
            let head = tail.split(separator: "\n").prefix(4).joined(separator: "\n")
            ok(has(head, "usage") && has(head, "return 2"), "the refusal is not followed by usage and return 2 within four lines")
        }
        // nothing runs before the whole list is checked: the call that runs the checks comes after the loop
        before(main, "unknown check id for", "run_checks \"\\$mode\"", "run_checks is called before every id of the list was checked")
        ok(has(main, "--ids cannot be combined with --slice or --plant"), "main lost the refusal of --ids with --slice or --plant")
    }

    @Test("recipe_main dispatches setup and minimix and keeps fresh-throttled, photos and busy50k")
    func recipeMainDispatch() {
        guard let text = read(libDir.appendingPathComponent("recipes.sh")).map(stripComments) else {
            Issue.record("scripts/kit-lib/recipes.sh not found")
            return
        }
        let main = shellFunctions(in: text)["recipe_main"] ?? ""
        ok(!main.isEmpty, "recipes.sh has no recipe_main")
        for r in ["fresh-throttled", "photos", "busy50k", "setup", "minimix"] {
            ok(has(main, "(^|\\n)[ \\t]*\(NSRegularExpression.escapedPattern(for: r))\\)"), "recipe_main has no `\(r))` branch")
        }
        // plan-3-t8: `tree` has its own branch now, so the not-built line is found by its first name, golden, alone (finding it by
        // `tree)` too would leave it empty and make the two checks below hold for nothing)
        // plan-4-t3 (amended by the tester, reason: the recipe `golden` is built and has its own branch): the not-built line now starts at
        // golden-code, so it is found by that name (still a name of that line alone, so the two checks below still hold for something)
        // plan-6-t1 (amended by the tester, never weakened; reason: golden-code and overlap have their own branches now, so the not-built line
        // starts at index50k and is found by that name; setup and minimix still must not be on it)
        let notBuilt = main.split(separator: "\n").first { $0.contains("index50k") }.map(String.init) ?? ""
        ok(!notBuilt.isEmpty, "recipe_main has no `not built yet` line for the recipes that are still to come")
        for r in ["setup", "minimix"] {
            ok(!has(notBuilt, "\\b\(r)\\b"), "recipe_main still lists `\(r)` as not built yet")
        }
        ok(main.contains("recipe_setup"), "recipe_main never calls recipe_setup")
        ok(main.contains("recipe_minimix"), "recipe_main never calls recipe_minimix")
    }

    @Test("prep setup: reset with the mirror model, the home folders, golden and extra built, the mirror throttled, then the app")
    func recipeSetup() {
        guard let text = contract(of: "recipe_setup") else { return }
        ok(has(text, "recipe_reset[ ]+mirror"), "recipe_setup does not reset with `recipe_reset mirror` (the model comes from the throttled mirror)")
        let start = firstIndex(text, "kit-launch\\.sh\"?[ ]+start")
        ok(start != nil, "recipe_setup never starts the app (`kit-launch.sh start`)")
        ok(has(text, "kit-launch\\.sh\"?[ ]+start[ ]+--mirror"), "the app is not started with --mirror")
        before(text, "kit-reset\\.sh", "build[ ]+homefolders", "the home folders are built before the reset, which deletes home/")
        for build in ["homefolders", "golden", "extra"] {
            before(text, "kit-fixtures\\.sh\"?[ ]+build[ ]+\(build)", "kit-launch\\.sh\"?[ ]+start",
                   "`kit-fixtures.sh build \(build)` is not before the app starts")
        }
        before(text, "kit-mirror\\.sh\"?[ ]+start", "kit-launch\\.sh\"?[ ]+start", "the mirror is not started before the app")
        before(text, "kit-mirror\\.sh\"?[ ]+rate[ ]+500000", "kit-launch\\.sh\"?[ ]+start", "the mirror is not throttled (rate 500000) before the app")
        ok(has(text, "wait_setup_window"), "recipe_setup does not wait for the setup window")
        ok(!has(text, "click[ ]+\"Start indexing\"") && !text.contains("press_start"), "prep setup presses Start indexing (nothing starts until it is pressed)")
    }

    @Test("prep setup --trace <name> starts kit-trace.sh before the app, and only when asked")
    func recipeSetupTrace() {
        guard let raw = read(libDir.appendingPathComponent("recipes.sh")).map(stripComments) else {
            Issue.record("scripts/kit-lib/recipes.sh not found")
            return
        }
        let own = shellFunctions(in: raw)["recipe_setup"] ?? ""
        ok(!own.isEmpty, "recipes.sh has no recipe_setup")
        guard let branch = caseBranch("--trace", in: own) else {
            ok(false, "recipe_setup has no `--trace)` option branch")
            return
        }
        ok(has(branch, "\\$2") && has(branch, "shift 2"), "the `--trace)` branch does not take a name argument")
        guard let variable = groups(branch, "([A-Za-z_][A-Za-z0-9_]*)=\"\\$2\"").first?.first else {
            ok(false, "the `--trace)` branch does not keep the name in a variable")
            return
        }
        guard let text = contract(of: "recipe_setup") else { return }
        let traceLine = text.split(separator: "\n").first { has(String($0), "kit-trace\\.sh\"?[ ]+start") }.map(String.init) ?? ""
        ok(!traceLine.isEmpty, "recipe_setup never runs `kit-trace.sh start`")
        let guarded = text.split(separator: "\n").map(String.init).enumerated().contains { _, line in
            has(line, "kit-trace\\.sh\"?[ ]+start") && has(line, "\\$\\{?\(variable)\\b")
        }
        ok(guarded, "`kit-trace.sh start` does not use the name given with --trace ($\(variable))")
        let lines = text.split(separator: "\n").map(String.init)
        if let i = lines.firstIndex(where: { has($0, "kit-trace\\.sh\"?[ ]+start") }) {
            let around = lines[max(0, i - 3)...i].joined(separator: "\n")
            ok(has(around, "\\[ -n \"\\$\\{?\(variable)\\}?\" \\]|-n \"\\$\\{?\(variable)\\}?\""), "the trace is started whether or not --trace was given (no `-n \"$\(variable)\"` test just before it)")
        }
        before(text, "kit-trace\\.sh\"?[ ]+start", "kit-launch\\.sh\"?[ ]+start", "the trace is started after the app: fs_usage must be running first (S6.8)")
        before(text, "kit-trace\\.sh\"?[ ]+start", "kit-launch\\.sh\"?[ ]+start[ ]+--mirror", "the trace is not started before the launch")
    }

    @Test("prep minimix [--no-start]: the mini mix built, picked through the picker, Start pressed only without --no-start")
    func recipeMinimix() {
        guard let raw = read(libDir.appendingPathComponent("recipes.sh")).map(stripComments) else {
            Issue.record("scripts/kit-lib/recipes.sh not found")
            return
        }
        let own = shellFunctions(in: raw)["recipe_minimix"] ?? ""
        ok(!own.isEmpty, "recipes.sh has no recipe_minimix")
        guard let branch = caseBranch("--no-start", in: own) else {
            ok(false, "recipe_minimix has no `--no-start)` option branch")
            return
        }
        guard let flag = groups(branch, "([A-Za-z_][A-Za-z0-9_]*)=1").first?.first else {
            ok(false, "the `--no-start)` branch does not set a flag variable")
            return
        }
        guard let text = contract(of: "recipe_minimix") else { return }
        ok(has(text, "kit-fixtures\\.sh\"?[ ]+build[ ]+minimix"), "recipe_minimix does not build the mini mix (`kit-fixtures.sh build minimix`)")
        ok(has(text, "pick_folders[ ]+minimix"), "the mini mix is not picked through the picker (`pick_folders minimix`)")
        ok(has(text, "wait_setup_window"), "recipe_minimix does not wait for the setup window before picking")
        ok(has(text, "recipe_reset[ ]+cache"), "the model does not come from the cache (`recipe_reset cache`)")
        before(text, "kit-fixtures\\.sh\"?[ ]+build[ ]+minimix", "kit-launch\\.sh\"?[ ]+start", "the mini mix is built after the app starts")
        before(text, "kit-launch\\.sh\"?[ ]+start", "pick_folders[ ]+minimix", "the folder is picked before the app started")
        let lines = own.split(separator: "\n").map(String.init)
        guard let i = lines.firstIndex(where: { has($0, "\\bpress_start\\b") }) else {
            ok(false, "recipe_minimix never presses Start indexing (`press_start`) when --no-start is not given")
            return
        }
        let around = lines[max(0, i - 2)...i].joined(separator: "\n")
        ok(has(around, "\\$\\{?\(flag)\\b"), "press_start is not guarded by the --no-start flag ($\(flag))")
        ok(i > (lines.firstIndex(where: { has($0, "pick_folders") }) ?? Int.max), "Start is pressed before the folder is picked")
    }

    @Test("every id's evidence is saved under the scenario of the id: kit-run.sh sets KIT_EVIDENCE_SCENARIO before each check")
    func runnerSetsEvidenceScenario() {
        guard let code = scriptCode("kit-run.sh") else { return }
        let runChecks = shellFunctions(in: code)["run_checks"] ?? ""
        ok(!runChecks.isEmpty, "kit-run.sh has no run_checks")
        let assign = firstIndex(runChecks, "KIT_EVIDENCE_SCENARIO=\"?\\$\\{id%%\\.\\*\\}\"?")
        ok(assign != nil, "run_checks does not set KIT_EVIDENCE_SCENARIO to the scenario of the id (`${id%%.*}`)")
        ok(has(runChecks, "export[^\\n]*\\bKIT_EVIDENCE_SCENARIO\\b"), "run_checks does not export KIT_EVIDENCE_SCENARIO, so the kit scripts a check calls never see it")
        if let assign, let call = firstIndex(runChecks, "\"\\$fn\"") {
            ok(assign < call, "KIT_EVIDENCE_SCENARIO is set after the check function is called")
        }
        before(runChecks, "KIT_EVIDENCE_SCENARIO=", "kit-perms\\.sh\"?[ ]+check", "the evidence scenario is set after kit-perms.sh check ran, whose output is evidence too")
    }

    @Test("kit_evidence_dir saves under the scenario of the check when KIT_EVIDENCE_SCENARIO is set, and as before when it is not")
    func evidenceDirHonoursScenario() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-kit-t11-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("run"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = projectRoot.appendingPathComponent(".ril/evidence")
        let given = evidence.appendingPathComponent("S1/vT11").path
        try (given + "\n").write(to: root.appendingPathComponent("run/evidence-dir"), atomically: true, encoding: .utf8)
        try "S1\n".write(to: root.appendingPathComponent("run/id"), atomically: true, encoding: .utf8)
        try "vT11\n".write(to: root.appendingPathComponent("run/version"), atomically: true, encoding: .utf8)
        let common = libDir.appendingPathComponent("common.sh").path
        func dir(_ scenario: String?) throws -> String {
            var env = ["KIT_ROOT": root.path, "KIT_EVIDENCE_SCENARIO": scenario ?? ""]
            if scenario == nil { env["KIT_EVIDENCE_SCENARIO"] = "" }
            let ran = try run("/bin/bash", ["-c", ". \"$0\"; kit_evidence_dir", common], env: env)
            return ran.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let plain = try dir(nil)
        ok(plain == given, "with no scenario kit_evidence_dir printed \"\(plain)\", expected the recorded \"\(given)\"")
        for scenario in ["S6", "S7", "S8"] {
            let want = evidence.appendingPathComponent("\(scenario)/vT11").path
            let got = try dir(scenario)
            ok(got == want, "with KIT_EVIDENCE_SCENARIO=\(scenario) kit_evidence_dir printed \"\(got)\", expected \"\(want)\"")
        }
        ok(!FileManager.default.fileExists(atPath: evidence.appendingPathComponent("S6/vT11").path), "kit_evidence_dir made the evidence folder itself (it only names it)")
    }

    // MARK: S6.1

    @Test("S6.1: Welcome, Folders, Permissions, Shortcut; Next and Back; Finish; no setup after Finish and a relaunch")
    func s61() {
        guard let t = check("S6.1") else { return }
        for step in ["Welcome", "Folders", "Permissions", "Shortcut"] {
            ok(t.contains("\"\(step)\"") || t.contains(step), "S6.1 never names the step \(step)")
        }
        for label in ["Next", "Back", "Finish"] {
            ok(has(t, "click[ ]+\"\(label)\""), "S6.1 never presses \"\(label)\" with `kit-ax.sh click`")
        }
        ok(has(t, "dump[ ]+setup"), "S6.1 never reads the setup window (`kit-ax.sh dump setup`)")
        ok(has(t, "kit-launch\\.sh\"?[ ]+relaunch"), "S6.1 does not relaunch the app after Finish (`kit-launch.sh relaunch`)")
        before(t, "click[ ]+\"Finish\"", "kit-launch\\.sh\"?[ ]+relaunch", "S6.1 relaunches before it presses Finish")
        if let r = firstIndex(t, "kit-launch\\.sh\"?[ ]+relaunch") {
            let after = String(t[t.index(t.startIndex, offsetBy: r)...])
            ok(has(after, "dump[ ]+setup"), "S6.1 does not read the setup window again after the relaunch, so \"no setup after Finish\" is never looked at")
        }
        ok(!has(t, "click[ ]+\"Start indexing\""), "S6.1 presses Start indexing (a setup check starts nothing)")
        ok(has(t, "recipe_setup"), "S6.1 does not start from the recipe `setup`")
    }

    @Test("S6.1 leaves the Folders step by Next or, with a whole model where the footer reads Start indexing, by Not now: it never presses Start indexing")
    func s61FoldersFooter() {
        guard let t = check("S6.1") else { return }
        ok(has(t, "\"Not now\""), "S6.1 has no way past a Folders step whose footer reads Start indexing (Not now)")
        before(t, "\"Not now\"", "click[ ]+\"Finish\"", "S6.1 reaches Finish before it knows how to leave Folders")
        ok(t.contains("Finish (Start indexing not pressed)"), "S6.1 lost its done text Finish (Start indexing not pressed)")
        ok(has(t, "KIT_PLANT[^\\n]*Wellcome Folders Permissions Shortcut"), "the S6.1 plant is gone")
    }

    // MARK: S6.2 and S6.3

    @Test("S6.2: the five folders ticked with counts per kind equal to kit-fixtures.sh expect counts, and a time estimate each")
    func s62() {
        guard let t = check("S6.2") else { return }
        for folder in ["Desktop", "Documents", "Downloads", "Pictures", "Movies"] {
            ok(t.contains(folder), "S6.2 never names the folder \(folder)")
        }
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+expect[ ]+counts"), "S6.2 does not take the expected counts from `kit-fixtures.sh expect counts`")
        for kind in ["photo", "pdf", "document", "audio", "video"] {
            ok(has(t.lowercased(), kind), "S6.2 never looks at the kind \(kind)")
        }
        ok(has(t.lowercased(), "estimate"), "S6.2 never looks for the time estimate of a folder")
        ok(has(t.lowercased(), "ticked"), "S6.2 never looks at whether the folders are ticked")
        ok(has(t, "dump[ ]+setup"), "S6.2 never reads the setup window")
        ok(!t.contains("kit-index.sh"), "S6.2 asks the index for a count (the expected counts come from kit-fixtures.sh only, never the product)")
        ok(!has(t, "click[ ]+\"Start indexing\""), "S6.2 presses Start indexing")
        ok(has(t, "recipe_setup"), "S6.2 does not start from the recipe `setup`")
    }

    @Test("S6.3: the overlap counts a file once, the repo with a .gitignore is counted whole")
    func s63() {
        guard let t = check("S6.3") else { return }
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+expect[ ]+counts"), "S6.3 does not take the expected counts from `kit-fixtures.sh expect counts`")
        ok(t.contains("Documents/Work"), "S6.3 never names the overlap folder Documents/Work")
        ok(has(t.lowercased(), "unique"), "S6.3 never speaks of the unique total")
        ok(has(t.lowercased(), "\\bsum\\b"), "S6.3 never compares the total with the sum of the two folders")
        ok(t.contains(".gitignore"), "S6.3 never names the .gitignore")
        ok(t.contains("atlas-notes"), "S6.3 never looks at the repo of the home fixtures (Developer/atlas-notes)")
        ok(has(t, "dump[ ]+setup"), "S6.3 never reads the setup window")
        ok(has(t, "Add folder…"), "S6.3 never adds the overlap folder through \"Add folder…\" (the picker)")
        ok(!t.contains("kit-index.sh"), "S6.3 asks the index for a count")
        ok(!has(t, "click[ ]+\"Start indexing\""), "S6.3 presses Start indexing")
    }

    // MARK: S6.4

    @Test("S6.4: exactly \"after the model download\" while the model is not whole, then numbers and a note on seconds per kind")
    func s64() {
        guard let t = check("S6.4") else { return }
        ok(t.contains("after the model download"), "S6.4 does not look for the exact text \"after the model download\"")
        ok(has(t, "kit-mirror\\.sh\"?[ ]+rate[ ]+500000"), "S6.4 does not run with the mirror throttled (rate 500000)")
        ok(has(t, "kit-mirror\\.sh\"?[ ]+rate[ ]+max"), "S6.4 never lets the download finish (`kit-mirror.sh rate max`), so the numbers are never looked at")
        before(t, "after the model download", "kit-mirror\\.sh\"?[ ]+rate[ ]+max", "S6.4 releases the mirror before it read the text of the throttled state")
        ok(t.contains("under a minute"), "S6.4 does not know the format \"under a minute\"")
        ok(has(t, "about"), "S6.4 does not know the formats \"about N min\" and \"about H h M min\"")
        ok(!t.contains("Photos: about"), "S6.4 still looks for the \"Photos: about\" speed line, which left the screen")
        ok(t.contains("S6.8"), "S6.4 does not say that the speeds are not read from a picked folder is S6.8's trace to show")
        ok(!has(t, "click[ ]+\"Start indexing\""), "S6.4 presses Start indexing")
        ok(has(t, "recipe_setup"), "S6.4 does not start from the recipe `setup`")
    }

    // MARK: S6.8

    @Test("S6.8: administrator rights, a trace running before the app, zero regular-file opens by Sesame and its helpers, an empty index, a positive control")
    func s68() {
        guard let t = check("S6.8") else { return }
        ok(has(t, "kit-perms\\.sh\"?[ ]+ask-admin"), "S6.8 does not call `kit-perms.sh ask-admin`")
        ok(has(t, "recipe_setup[^\\n]*--trace"), "S6.8 does not start from `recipe_setup --trace <name>` (the trace must run before the app)")
        before(t, "kit-perms\\.sh\"?[ ]+ask-admin", "recipe_setup", "S6.8 asks for administrator rights after the app was started")
        ok(t.contains("s6-setup"), "S6.8 does not name its trace s6-setup")
        ok(has(t, "kit-trace\\.sh\"?[ ]+stop"), "S6.8 never stops its trace")
        ok(has(t, "kit-trace\\.sh\"?[ ]+opens"), "S6.8 never asks the trace for the opens (`kit-trace.sh opens`)")
        ok(has(t, "--under"), "S6.8 does not ask for the opens under each picked folder (`--under`)")
        ok(has(t, "--by[ ]+\"?Sesame\\*") || (has(t, "--by[ ]+\"?Sesame\"?([ ;)]|$)") && has(t, "--by[ ]+\"?SesameHelper")),
           "S6.8 does not cover both the app process and every helper (`--by \"Sesame*\"`, or `--by Sesame` and `--by SesameHelper`)")
        ok(has(t.lowercased(), "regular files"), "S6.8 never reads the `regular files:` count of kit-trace.sh opens (directories are counted apart)")
        for folder in ["Desktop", "Documents", "Downloads", "Pictures", "Movies"] {
            ok(t.contains(folder), "S6.8 does not look under the picked folder \(folder)")
        }
        ok(has(t, "sleep[ ]+120"), "S6.8 does not wait 120 s after the last step (`sleep 120`)")
        ok(has(t, "click[ ]+\"Finish\""), "S6.8 never finishes the setup (`click \"Finish\"`)")
        ok(has(t, "kit-index\\.sh\"?[ ]+(status|rows)"), "S6.8 never reads the index (`kit-index.sh status` or `rows`)")
        ok(t.contains("startPressed"), "S6.8 never looks at startPressed in settings.json")
        ok(has(t, "kit-index\\.sh\"?[ ]+settings"), "S6.8 never reads `kit-index.sh settings`")
        // the positive control
        ok(t.contains("s6-after-start"), "S6.8 has no positive control (`s6-after-start`)")
        ok(has(t, "kit-trace\\.sh\"?[ ]+start[ ]+\"?s6-after-start"), "S6.8 does not start the second trace s6-after-start before it presses Start")
        ok(has(t, "kit-index\\.sh\"?[ ]+wait[ ]+started"), "S6.8 does not wait for the first file read (`kit-index.sh wait started`)")
        ok(has(t.lowercased(), "positive control"), "S6.8 never says `positive control`")
        ok(has(t, "RERUN S6\\.8") && has(t, "return 4"), "a trace that saw nothing after Start must be `RERUN S6.8 ...` and exit 4, never a pass")
        before(t, "sleep[ ]+120", "click[ ]+\"Start indexing\"", "S6.8 presses Start indexing before the 120 s of waiting are over")
        before(t, "kit-trace\\.sh\"?[ ]+start[ ]+\"?s6-after-start", "click[ ]+\"Start indexing\"", "the second trace starts after Start was pressed")
        before(t, "click[ ]+\"Start indexing\"", "kit-index\\.sh\"?[ ]+wait[ ]+started", "S6.8 waits for the first read before it pressed Start")
        // Start is pressed once, and only after the zero-opens reading of the setup
        let starts = (try? NSRegularExpression(pattern: "click[ ]+\"Start indexing\""))?
            .numberOfMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) ?? 0
        ok(starts >= 1, "S6.8 never presses Start indexing for its positive control")
        before(t, "kit-trace\\.sh\"?[ ]+opens", "click[ ]+\"Start indexing\"", "S6.8 presses Start before it read the opens of the setup trace")
    }

    @Test("S6.8 leaves the Folders step by Next or Not now (the footer reads Start indexing with a whole model), so Start is pressed only after the 120 s, in Settings")
    func s68FoldersFooter() {
        guard let t = check("S6.8") else { return }
        ok(has(t, "\"Not now\""), "S6.8 has no way past a Folders step whose footer reads Start indexing (Not now) once the model is whole")
        before(t, "\"Not now\"", "click[ ]+\"Finish\"", "S6.8 reaches Finish before it knows how to leave Folders")
        before(t, "s6_wait_whole", "\"Not now\"", "S6.8 leaves Folders before the model is whole, which is not the state the footer reads Start indexing in")
        before(t, "sleep[ ]+120", "click[ ]+\"Start indexing\"", "S6.8 presses Start indexing before the 120 s of waiting are over")
        ok(t.contains("startPressed is true before Start indexing was pressed"), "S6.8 lost its failure for startPressed true before Start")
        ok(t.contains("the index holds"), "S6.8 lost its failure for a non-empty index before Start")
        ok(has(t, "KIT_PLANT[^\\n]*S6_SKEW=1"), "the S6.8 plant is gone")
    }

    @Test("S6.7: the Start indexing control is disabled or absent while the download has failed (the spec's words), enabled fails; step 5 reads Start enabled once the download is whole")
    func s67() {
        guard let t = check("S6.7") else { return }
        ok(has(t, "kit-mirror\\.sh\"?[ ]+offline"), "S6.7 never takes the mirror offline")
        ok(has(t, "kit-mirror\\.sh\"?[ ]+online"), "S6.7 never brings the mirror back")
        ok(has(t, "disabled\\|absent"), "S6.7 does not accept disabled or absent")
        ok(has(t, "not disabled or absent"), "S6.7's failure for Start indexing does not say disabled or absent")
        ok(!has(t, "\\[ \"\\$st\" = disabled \\]"), "S6.7 still requires exactly disabled")
        ok(has(t, "st=unread"), "S6.7 reads a press of Next that failed as absent, which would pass")
        ok(has(t, "= enabled \\] && break"), "S6.7 step 5 no longer waits for Start indexing enabled")
        ok(has(t, "Start indexing is not available after the download finished"), "S6.7 lost its failure for Start not available after the download")
        ok(has(t, "Add folder…"), "S6.7 step 5 does not tell the Welcome step (press Next) from the Folders step (wait)")
        ok(!has(t, "click[ ]+\"Start indexing\""), "S6.7 presses Start indexing (it only reads it)")
        ok(has(t, "S6_SKEW=1"), "the S6.7 plant is gone")
    }

    // MARK: S6.10

    @Test("S6.10: (i) the picker adds extra with counts and a time, (ii) and (iii) the rows stay absent for 60 s, (iv) Start reads them")
    func s610() {
        guard let t = check("S6.10") else { return }
        ok(has(t, "Add folder…"), "S6.10 never uses \"Add folder…\" (the picker)")
        ok(has(t, "(drive_picker|pick_folders)[^\\n]*\\bextra\\b"), "S6.10 does not enter the folder extra through the picker (`drive_picker`/`pick_folders` with extra)")
        // Commit 080db8e: the bare `kit-ax.sh click "Settings…"` became `s6_press "$S6_AX" "Settings…"`, which is the same click
        // and prints kit-ax's output when it fails. The check text here has $S6_AX written in as the path of kit-ax.sh.
        ok(has(t, "s6_press[ ]+\"?[^ \"]*kit-ax\\.sh\"?[ ]+\"Settings…\""), "S6.10 never opens Settings (`s6_press \"$S6_AX\" \"Settings…\"`) for (ii) and (iii)")
        ok(has(t, "dump[ ]+settings"), "S6.10 never reads Settings (`kit-ax.sh dump settings`)")
        // the folder given to kit-index.sh under is relative to KIT_ROOT/fixtures: `extra`, never `fixtures/extra`
        ok(has(t, "kit-index\\.sh\"?[ ]+under[ ]+\"?extra\"?([ ;)|]|$)"), "S6.10 does not call `kit-index.sh under extra` (the folder is relative to KIT_ROOT/fixtures, so it must be `extra`)")
        ok(!has(t, "kit-index\\.sh\"?[ ]+under[ ]+\"?(\\$KIT_ROOT/)?fixtures/extra"), "S6.10 calls `kit-index.sh under fixtures/extra`, which reads a folder that does not exist and passes for nothing")
        ok(has(t, "[^0-9]60[^0-9]"), "S6.10 does not wait 60 s with the rows absent")
        ok(has(t.lowercased(), "untick"), "S6.10 never unticks an indexed folder for (iii)")
        ok(has(t, "click[ ]+\"Start indexing\""), "S6.10 never presses Start indexing for (iv)")
        ok(has(t, "kit-index\\.sh\"?[ ]+wait[ ]+done"), "S6.10 does not wait for the rows of (iv) (`kit-index.sh wait done`)")
        ok(has(t, "Ready"), "S6.10 does not wait for the first index to be Ready before (ii)")
        ok(has(t, "s1_need_photos|recipe_photos"), "S6.10 does not start (ii) from a Ready index (`recipe_photos`, as the kit's other checks)")
        ok(has(t, "recipe_setup"), "S6.10 does not start (i) from the recipe `setup`")
        let reads = (try? NSRegularExpression(pattern: "kit-index\\.sh\"?[ ]+under[ ]+\"?extra"))?
            .numberOfMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) ?? 0
        ok(reads >= 2, "S6.10 reads `kit-index.sh under extra` \(reads) time(s): it needs the empty reading of (ii) or (iii) and the rows of (iv)")
        if let firstUnder = firstIndex(t, "kit-index\\.sh\"?[ ]+under[ ]+\"?extra"), let lastStart = lastIndex(t, "click[ ]+\"Start indexing\"") {
            ok(firstUnder < lastStart, "S6.10 presses Start (iv) before it showed the rows of extra were absent")
        }
        if let lastUnder = lastIndex(t, "kit-index\\.sh\"?[ ]+under[ ]+\"?extra"), let lastStart = lastIndex(t, "click[ ]+\"Start indexing\"") {
            ok(lastUnder > lastStart, "S6.10 never reads the rows of extra after Start indexing was pressed (iv)")
        }
    }

    // MARK: S6.11

    // plan-5-t1b (amended by the tester, reason: the entry says "check_S6_11 runs on mix500 (recipe mix500 --no-start, replacing the \"partial\"
    // minimix reading) and prints both figures"): the hand count is `expect listing mix500`, the recipe is `recipe_mix500 --no-start`, and
    // the figures are no longer labelled `partial`. Every other pin is unchanged: the estimate-check, the size over the `files` line only, the
    // 50,000 byte bar, the -wal note, the order of Start before the estimate and of done before the size.
    @Test("S6.11: estimate-check, size over the files line only, cross-checked with expect listing mix500, run on the 500-file mix and not labelled partial")
    func s611() {
        guard let t = check("S6.11") else { return }
        ok(has(t, "kit-index\\.sh\"?[ ]+estimate-check"), "S6.11 does not call `kit-index.sh estimate-check`")
        ok(has(t, "kit-index\\.sh\"?[ ]+size"), "S6.11 does not call `kit-index.sh size`")
        ok(has(t, "kit-index\\.sh\"?[ ]+rows"), "S6.11 does not read `kit-index.sh rows`")
        ok(has(t, "\\$1 == \"files\""), "S6.11 does not take the divisor from the `files` line")
        ok(!has(t, "\\$1 == \"rows\"") && !has(t, "\\$1 == \"passages\""), "S6.11 reads the `rows` or `passages` line, which never is the divisor")
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+expect[ ]+listing[ ]+\"?mix500"), "S6.11 does not cross-check the divisor against `kit-fixtures.sh expect listing mix500`")
        ok(has(t.lowercased(), "hand count"), "S6.11 never says `hand count`, so a mismatch does not print both figures")
        ok(has(t, "50000"), "S6.11 does not hold the 50,000 byte bar")
        ok(!t.contains("partial"), "S6.11 still labels its figures \"partial\"")
        ok(has(t, "kit-index\\.sh\"?[ ]+wait[ ]+done"), "S6.11 does not wait for the index to finish (`kit-index.sh wait done`)")
        ok(t.contains("Ready"), "S6.11 does not wait for the menu bar to say Ready")
        ok(has(t, "date[ ]+\\+%s"), "S6.11 does not take the start epoch")
        ok(has(t, "recipe_mix500[ ]+--no-start"), "S6.11 does not start from the recipe `mix500 --no-start`")
        if let click = lastIndex(t, "click[ ]+\"Start indexing\""), let estimate = firstIndex(t, "kit-index\\.sh\"?[ ]+estimate-check") {
            ok(click < estimate, "S6.11 checks the estimate before Start was pressed")
        } else {
            ok(false, "S6.11 never presses Start indexing before `kit-index.sh estimate-check`")
        }
        ok(has(t, "under a minute") && has(t, "about"), "S6.11 does not parse the estimate formats of the setup summary (\"under a minute\", \"about N min\", \"about H h M min\")")
        before(t, "kit-index\\.sh\"?[ ]+wait[ ]+done", "kit-index\\.sh\"?[ ]+size", "S6.11 measures the size before the indexing is done")
        ok(t.contains("-wal"), "S6.11 does not say that the size includes the -wal file")
    }

    @Test("S6.11 presses Start indexing through press_start, which waits for Permissions or the start error and says which, and fails with that line")
    func s611PressStart() {
        guard let t = check("S6.11") else { return }
        ok(has(t, "press_start"), "S6.11 does not press Start through press_start")
        ok(t.contains("Step 3 of 4: Permissions"), "the press_start S6.11 uses does not wait for Step 3 of 4: Permissions")
        ok(t.contains("Could not save the settings"), "the press_start S6.11 uses does not know the start error")
        ok(has(t, "pressing \\\\\"Start indexing\\\\\" in the setup window failed: "), "S6.11 does not say why pressing Start failed")
    }

    // MARK: S6.12

    @Test("S6.12: the request count and the model's inode and time unchanged after relaunches, Delete index and a rebuilt index")
    func s612() {
        guard let t = check("S6.12") else { return }
        ok(has(t, "kit-mirror\\.sh\"?[ ]+requests"), "S6.12 does not read the mirror's request log")
        ok(has(t, "%i"), "S6.12 does not read the inode of the model files")
        ok(has(t, "kit-launch\\.sh\"?[ ]+relaunch"), "S6.12 never relaunches")
        ok(t.contains("Delete index"), "S6.12 does not Delete index (slice 2)")
        // Commit 080db8e: `click "Settings…"` is now `s6_press "$S6_AX" "Settings…"` (in s6b_delete_index), the same click with
        // kit-ax's failure output printed. Pinned as that.
        ok(has(t, "s6_press[ ]+\"?[^ \"]*kit-ax\\.sh\"?[ ]+\"Settings…\""), "S6.12 does not reach Delete index through Settings (`s6_press \"$S6_AX\" \"Settings…\"`)")
        ok(has(t, "click[ ]+\"Delete index…\""), "S6.12 does not press \"Delete index…\"")
        ok(has(t, "click[ ]+\"Start indexing\""), "S6.12 does not press Start indexing after Delete index")
        ok(has(t, "kit-index\\.sh\"?[ ]+wait[ ]+done"), "S6.12 does not wait for the rebuilt index (`kit-index.sh wait done`)")
        ok(has(t.lowercased(), "rebuilt"), "S6.12 never says `rebuilt`")
        if let d = firstIndex(t, "click[ ]+\"Delete index…\""), let s = lastIndex(t, "click[ ]+\"Start indexing\"") {
            ok(s > d, "S6.12 does not press Start indexing after Delete index")
        }
        if let d = firstIndex(t, "click[ ]+\"Delete index…\""), let w = lastIndex(t, "kit-index\\.sh\"?[ ]+wait[ ]+done") {
            ok(w > d, "S6.12 does not wait for the rebuilt index after Delete index")
        }
        if let d = firstIndex(t, "click[ ]+\"Delete index…\""), let r = lastIndex(t, "kit-launch\\.sh\"?[ ]+relaunch") {
            ok(r > d, "S6.12 does not relaunch again after Delete index and the rebuilt index")
        }
        if let d = firstIndex(t, "click[ ]+\"Delete index…\""), let c = lastIndex(t, "s6_reqs|kit-mirror\\.sh\"?[ ]+requests") {
            ok(c > d, "S6.12 does not read the request count again after the rebuilt index")
        }
        // plan 1's own clauses stay
        ok(has(t, "rate[ ]+max"), "S6.12 lost the download at full rate of plan 1")
        ok(has(t, "recipe_fresh_throttled") || has(t, "recipe_setup"), "S6.12 lost its starting recipe")
    }

    @Test("S6.12 presses Start indexing for the golden pick through press_start, which waits for Permissions or the start error, and fails with that line")
    func s612PressStart() {
        guard let t = check("S6.12") else { return }
        ok(has(t, "pick_folders[ ]+golden/photos"), "S6.12 does not pick golden/photos before Start")
        before(t, "pick_folders[ ]+golden/photos", "press_start", "S6.12 presses Start before it picked the folder")
        ok(t.contains("Step 3 of 4: Permissions"), "the press_start S6.12 uses does not wait for Step 3 of 4: Permissions")
        ok(has(t, "pressing \\\\\"Start indexing\\\\\" failed: "), "S6.12 does not say why pressing Start failed")
    }

    // MARK: all of them

    @Test("no S6 check, recipe or the runner reads Sources/", arguments: allIds)
    func neverReadsSources(_ id: String) {
        guard let t = check(id) else { return }
        ok(!t.contains("Sources/") && !has(t, "\\bSources\\b"), "\(checkFunctionName(id)) names Sources: the kit never reads the product's source")
    }

    @Test("the runner and the recipes never read Sources/")
    func runnerNeverReadsSources() {
        for (name, code) in kitShellSources() where name == "kit-run.sh" || name == "kit-lib/recipes.sh" {
            ok(!has(code, "\\bSources/"), "scripts/\(name) names Sources/")
        }
    }

    @Test("typing goes through kit-ax.sh and keeps KIT_TYPE_DELAY_MS: no delay of its own, no other key tool", arguments: newIds)
    func typingHonoursDelay(_ id: String) {
        guard let t = check(id) else { return }
        ok(!has(t, "--delay-ms"), "\(checkFunctionName(id)) passes --delay-ms, which overrides KIT_TYPE_DELAY_MS")
        ok(!has(t, "(^|[^A-Za-z0-9_])KIT_TYPE_DELAY_MS="), "\(checkFunctionName(id)) sets KIT_TYPE_DELAY_MS itself")
        ok(!has(t, "keytool|cliclick|CGEvent|key code|keystroke"), "\(checkFunctionName(id)) posts keys by a tool of its own, not through kit-ax.sh")
        ok(!has(t, "osascript"), "\(checkFunctionName(id)) calls osascript itself instead of kit-ax.sh")
    }

    @Test("every new S6 check prints its id on a CHECK line and can be planted", arguments: newIds)
    func printsAndPlants(_ id: String) {
        guard let t = check(id) else { return }
        ok(t.contains(id), "\(checkFunctionName(id)) never names \(id) on a CHECK line")
        ok(has(t, "S6_PLANTED=\"[^\"]+\""), "\(checkFunctionName(id)) names no planted input (S6_PLANTED=\"...\"), so `kit-run.sh --plant \(id)` could never show a FAIL planted line")
        ok(has(t, "\\bKIT_PLANT\\b"), "\(checkFunctionName(id)) never looks at KIT_PLANT")
    }
}

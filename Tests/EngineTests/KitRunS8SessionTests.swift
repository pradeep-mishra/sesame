import Foundation
import Testing

// plan-3-t8, tester step: the recipe `tree` and the S8 session (scripts/kit-run.sh usage and `prep` dispatch,
// scripts/kit-lib/recipes.sh, scripts/kit-lib/checks-s8session.sh). Written from the plan-3-t8 entry, verify.md, the
// design, the existing kit's text and plan 2's test style; no product source is read, and no kit function may read
// `Sources/`.
//
// Static proof only (plan-3-tasks.md, Conventions; the person's ruling "no app launch"): the recipe `tree`,
// `s8_activity` and `s8_close_window` drive the app, so NOTHING here runs them. What runs:
//   - `bash -n` on the runner, recipes.sh and checks-s8session.sh;
//   - the text of the functions, with comment lines removed, read as the shell would run them (every call of a kit
//     function replaced in place by that function's code), for order and for what each one calls;
//   - the pure function `tree_pick_list <gate-matrix.csv>` in a child shell that only sources common.sh and recipes.sh,
//     on hand-written csv files and on the real table;
//   - `tree_need` and `tree_roots_check` in the same kind of child shell, with `recipe_tree`, `sudo` and `setup_folders`
//     replaced by stubs in that shell (no script starts, no window is read).
// Real behaviour is driven against the live app at the accept stage only (blocks C and E).
//
// The contract read here (plan-3-t8, Tests):
//   - `recipe_tree [--trace <name>]` in this order: recipe_state; with --trace admin_session; recipe_reset mirror;
//     kit-mirror.sh start; kit-fixtures.sh build tree and build matrix; the pick list; kit-sums.sh snapshot sums-before of
//     every folder of the list; with --trace kit-trace.sh start <name> --net, kit-net.sh start <name> and plant 1
//     (kit-net.sh control <name>); in every tree recipe kit-privacy.sh prompts start s8 (a failed start is exit 1,
//     nothing launched); kit-launch.sh start --mirror; wait_setup_window; the picks; the exact comparison of the picked
//     roots under matrix/ (RERUN picked roots differ from the pick list, exit 4); press_start; kit-index.sh wait rising 60;
//     with --trace plant 2 and a kit-index.sh wait done 1 that must time out (RERUN second plant not mid-indexing, exit
//     4); run/recipe (`tree <name>` or `tree -`); the NOTE that code ticks are disabled until plan 6; the picker fallback
//     of plan 1 waits up to 10 minutes;
//   - `tree_pick_list <gate-matrix.csv>` (pure): every top-level folder of tree/ but never-picked, the own top folder of
//     every row whose picks is blank, every folder named in a non-blank picks, never the top folder of a row whose picks
//     is `-`; a folder named with two different ticks, or a `-` folder another row picks: exit 4. One folder a line, a path
//     under the fixture root (`tree/<name>`, `matrix/<folder>`), sorted, each once;
//   - `tree_need` (recipes.sh): nothing when run/recipe holds `tree`, else `recipe_tree --trace s8` when `sudo -n true`
//     holds and `recipe_tree` without a trace when it does not; it never asks for a password;
//   - `s8_activity` and `s8_close_window` (checks-s8session.sh): see the tests below.
// Red before the kit part: the recipe is `not built yet`, checks-s8session.sh does not exist, `tree_need`, `tree_pick_list`
// and the session functions do not exist, the usage lacks the line.
//
// My picks where the entry is silent (also in the report): `tree_pick_list` prints paths under the fixture root;
// `tree_need` and the two session functions take an optional check id (`tree_need S8.5`, `s8_close_window S8.1`) that is
// appended to run/window-ids while the observers are open; `tree_roots_check <list>` is the exact comparison of the
// picked roots (the recipe calls it); the markers, the order lists and the activity log are files of $KIT_ROOT/run.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], env: [String: String] = [:], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitt8-out-" + UUID().uuidString)
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
    return Ran(status: status, output: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
}

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func firstIndex(_ text: String, _ pattern: String, after: Int = 0) -> Int? {
    guard let start = text.index(text.startIndex, offsetBy: after, limitedBy: text.endIndex),
          let r = text.range(of: pattern, options: .regularExpression, range: start..<text.endIndex) else { return nil }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

private func groups(_ text: String, _ pattern: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (1..<max(m.numberOfRanges, 1)).map { i in
            m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : ""
        }
    }
}

/// Each pattern must be found, in this order, each after the start of the one before it.
private func inOrder(_ text: String, _ patterns: [String], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    var from = 0
    for p in patterns {
        guard let at = firstIndex(text, p, after: from) else {
            ok(false, "\(what): `\(p)` is missing, or comes before the pattern before it", sourceLocation: sourceLocation)
            return
        }
        from = at + 1
    }
}

private func kitLibShellNames() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []).filter { $0.hasSuffix(".sh") }.sorted()
}

private func kitShellSources() -> [(name: String, code: String)] {
    var all: [(String, String)] = []
    if let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) { all.append(("kit-run.sh", stripComments(text))) }
    for name in kitLibShellNames() {
        if let text = read(libDir.appendingPathComponent(name)) { all.append(("kit-lib/" + name, stripComments(text))) }
    }
    return all
}

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

private func allFunctions() -> [String: String] {
    var merged: [String: String] = [:]
    for (_, code) in kitShellSources() {
        for (k, v) in shellFunctions(in: code) where merged[k] == nil { merged[k] = v }
    }
    return merged
}

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

private let callWord = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_.:-])")

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

/// A function of the kit as the shell would run it: calls and variables written in. Records the reason and returns nil when
/// the function does not exist.
private func contract(of function: String) -> String? {
    let functions = allFunctions()
    guard let body = functions[function] else {
        Issue.record(Comment(rawValue: "\(function) is not defined in scripts/kit-run.sh or scripts/kit-lib/*.sh"))
        return nil
    }
    return substitute(expandShell(body, functions, skipping: [function]), topLevelValues())
}

/// The function's own code (no calls expanded), or nil after recording that it does not exist.
private func raw(_ function: String) -> String? {
    guard let body = allFunctions()[function] else {
        Issue.record(Comment(rawValue: "\(function) is not defined in scripts/kit-run.sh or scripts/kit-lib/*.sh"))
        return nil
    }
    return body
}

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

/// For each line of `body` that matches `pattern`: does it sit under a test of `-n "$variable"` (inside an `if` block that
/// tests it, or on a line that tests it itself)?
private func guarded(_ body: String, variable: String, matching pattern: String) -> [Bool] {
    var stack: [Bool] = []
    var result: [Bool] = []
    let test = "-n \"\\$\\{?\(variable)\\}?\""
    for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let oneLiner = has(line, "^if\\b") && has(line, "\\bfi$")
        if has(line, "^if\\b"), !oneLiner { stack.append(has(line, test)) }
        if has(line, pattern) { result.append(stack.contains(true) || has(line, test)) }
        if line == "fi" || has(line, "^fi\\b") { _ = stack.popLast() }
    }
    return result
}

// MARK: a throwaway kit root for the child shells

private struct Rig {
    let base: URL
    var kit: URL { base.appendingPathComponent("sesame-kit-t8test", isDirectory: true) }
    var runDir: URL { kit.appendingPathComponent("run", isDirectory: true) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("kitt8-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func write(_ text: String, to relative: String) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A child bash that sources common.sh and recipes.sh and then runs `script` (`$1` is the kit-lib folder, `$2...` the
    /// extra arguments). Nothing but function definitions is sourced; the scripts of the kit are never started.
    func shell(_ script: String, _ args: [String] = [], env: [String: String] = [:]) throws -> Ran {
        let prelude = ". \"$1/common.sh\"; . \"$1/recipes.sh\"; "
        var e = ["KIT_ROOT": kit.path, "TMPDIR": base.appendingPathComponent("tmp").path + "/",
                 "HOME": base.appendingPathComponent("home").path, "KIT_NO_EVIDENCE": "1"]
        for (k, v) in env { e[k] = v }
        return try run("/bin/bash", ["-c", prelude + script, "kitt8", libDir.path] + args, env: e)
    }
}

private func pickList(_ rig: Rig, csv: String) throws -> Ran {
    let file = try rig.write(csv, to: "table-" + UUID().uuidString + ".csv")
    return try rig.shell("tree_pick_list \"$2\"", [file.path])
}

private let header = "cell,path,picks,expected_in_index,expected_rows,expected_reason,group\n"

private let treeFolders: Set<String> = ["tree/plain", "tree/excluded", "tree/unsupported", "tree/damaged", "tree/repo"]

private func lines(_ output: String) -> [String] {
    output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

// MARK: the suite

@Suite("KitRunS8SessionTests")
struct KitRunS8SessionTests {

    // MARK: syntax and dispatch

    @Test("bash -n finds no syntax error in the runner, recipes.sh and checks-s8session.sh (none is run)")
    func bashSyntax() throws {
        let paths = [scriptsDir.appendingPathComponent("kit-run.sh"), libDir.appendingPathComponent("recipes.sh"),
                     libDir.appendingPathComponent("checks-s8session.sh")]
        for url in paths {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(Comment(rawValue: "\(url.path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", url.path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(url.path) exited \(ran.status): \(ran.output)")
        }
    }

    @Test("kit-run.sh usage names `prep tree [--trace <name>]` and keeps the older recipe lines")
    func usageNamesTree() {
        guard let text = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) else {
            Issue.record("scripts/kit-run.sh not found")
            return
        }
        let usage = shellFunctions(in: text)["usage"] ?? ""
        ok(!usage.isEmpty, "kit-run.sh has no usage function")
        ok(usage.contains("kit-run.sh prep tree [--trace <name>]"), "usage does not show `kit-run.sh prep tree [--trace <name>]`")
        for old in ["prep fresh-throttled", "prep photos [--no-wait] [--cache-dir <dir>]", "prep busy50k", "prep setup [--trace <name>]",
                    "prep minimix [--no-start]"] {
            ok(usage.contains(old), "usage lost the line `\(old)`")
        }
    }

    // Amended in plan-4-t3 (never weakened; reason: the recipe `golden` is built, recipe_main has a `golden)` branch that runs
    // recipe_golden and the not-built line starts at golden-code): the not-built line is found by `golden-code|`, and `golden` is no
    // longer one of its names; the other four still are, and `tree` and `golden` must not be.
    // Amended in plan-5-t1b (never weakened; reason: the entry says "The recipe `mix500` replaces `not built yet`", so mix500 leaves the
    // not-built line; golden-code, overlap and index50k stay on it and `mix500` must not be on it; KitRunS4ChecksTests pins that mix500 is run).
    // plan-6-t1 (amended by the tester, never weakened; reason: the entry says "the recipes `golden-code` and `overlap` replace `not built yet`"):
    // they have their own branches; only index50k stays on the not-built line, found by its name.
    @Test("recipe_main runs recipe_tree for `tree`, recipe_golden for `golden` and recipe_index50k for `index50k`; no recipe is left on a `not built yet` line")
    func recipeMainDispatch() {
        guard let text = read(libDir.appendingPathComponent("recipes.sh")).map(stripComments) else {
            Issue.record("scripts/kit-lib/recipes.sh not found")
            return
        }
        let main = shellFunctions(in: text)["recipe_main"] ?? ""
        ok(!main.isEmpty, "recipes.sh has no recipe_main")
        ok(shellFunctions(in: text)["recipe_tree"] != nil, "recipes.sh has no recipe_tree")
        ok(has(main, "(^|\\n)[ \\t]*tree\\)[^\\n]*recipe_tree"), "recipe_main has no `tree)` branch that runs recipe_tree")
        ok(has(main, "(^|\\n)[ \\t]*golden\\)[^\\n]*recipe_golden"), "recipe_main has no `golden)` branch that runs recipe_golden")
        // plan-6-t9 (amended by the tester, never weakened; reason: the entry says `index50k` "replaces `not built yet`"): index50k has its own
        // branch that runs recipe_index50k and no recipe is left on the not-built line, so the line itself is gone. The checks that no built
        // recipe is listed as not built hold for every name (a name on any `not built yet` line fails them).
        let notBuilt = main.split(separator: "\n").first { $0.contains("not built yet") }.map(String.init) ?? ""
        ok(has(main, "(^|\\n)[ \\t]*index50k\\)[^\\n]*recipe_index50k"), "recipe_main has no `index50k)` branch that runs recipe_index50k")
        for name in ["index50k", "golden-code", "overlap", "mix500", "golden", "tree"] {
            ok(!has(notBuilt, "(^|[ |])\(name)(\\||\\))"), "recipe_main still lists `\(name)` as not built yet: \(notBuilt)")
        }
        ok(!main.contains("not built yet"), "recipe_main still has a `not built yet` line although every recipe is built")
    }

    // MARK: the recipe

    @Test("recipe_tree takes --trace <name> and nothing else")
    func recipeOptions() {
        guard let own = raw("recipe_tree") else { return }
        guard let branch = caseBranch("--trace", in: own) else {
            ok(false, "recipe_tree has no `--trace)` option branch")
            return
        }
        ok(has(branch, "\\$2") && has(branch, "shift 2"), "the `--trace)` branch does not take a name argument")
        ok(groups(branch, "([A-Za-z_][A-Za-z0-9_]*)=\"\\$2\"").first?.first != nil, "the `--trace)` branch does not keep the name in a variable")
        ok(has(own, "\\*\\)[^\\n]*usage[^\\n]*return 2"), "recipe_tree does not refuse another option with usage and exit 2")
    }

    @Test("recipe_tree runs its steps in the entry's order, every one before the app where the entry says so")
    func recipeOrder() {
        guard let t = contract(of: "recipe_tree") else { return }
        inOrder(t, [
            "\\brecipe_state\\b",
            "\\badmin_session\\b",
            "recipe_reset[ ]+mirror",
            "kit-mirror\\.sh\"?[ ]+start",
            "kit-fixtures\\.sh\"?[ ]+build[ ]+tree",
            "kit-fixtures\\.sh\"?[ ]+build[ ]+matrix",
            "\\btree_pick_list\\b",
            "kit-sums\\.sh\"?[ ]+snapshot[ ]+sums-before",
            "kit-trace\\.sh\"?[ ]+start[^\\n]*--net",
            "kit-net\\.sh\"?[ ]+start",
            "kit-net\\.sh\"?[ ]+control",
            "kit-privacy\\.sh\"?[ ]+prompts[ ]+start[ ]+s8",
            "kit-launch\\.sh\"?[ ]+start[ ]+--mirror",
            "\\bwait_setup_window\\b",
            "\\bpick_folders\\b",
            "picked roots differ from the pick list",
            "\\bsetup_finish\\b",
            "\\bsettings_open\\b",
            "\\bsettings_start\\b",
            "kit-index\\.sh\"?[ ]+wait[ ]+rising[ ]+60",
            "kit-net\\.sh\"?[ ]+control",
            "kit-index\\.sh\"?[ ]+wait[ ]+done[ ]+1([^0-9]|$)",
            "second plant not mid-indexing",
            "run/recipe",
        ], "recipe_tree order")
    }

    @Test("recipe_tree finishes Setup and starts from Settings: it calls setup_finish and settings_start, and never press_start (Setup's Start would rewrite the ticks)")
    func recipeTreeStartsFromSettings() {
        guard let own = raw("recipe_tree"), let t = contract(of: "recipe_tree") else { return }
        ok(has(own, "\\bsetup_finish\\b"), "recipe_tree does not finish Setup (setup_finish)")
        ok(has(own, "\\bsettings_start\\b"), "recipe_tree does not start indexing from Settings (settings_start)")
        ok(!has(own, "\\bpress_start\\b"), "recipe_tree still presses Start in the Setup window (press_start)")
        ok(!has(t, "\\bpress_start\\b"), "recipe_tree reaches press_start through a function it calls")
        if let fin = firstIndex(t, "\\bsetup_finish\\b"), let open = firstIndex(t, "\\bsettings_open\\b"), let start = firstIndex(t, "\\bsettings_start\\b") {
            ok(fin < open, "Settings is opened before Setup is finished")
            ok(open < start, "Start is pressed before Settings is opened")
        } else {
            ok(false, "recipe_tree does not reach setup_finish, settings_open and settings_start")
        }
        ok(!has(t, "\\bsettings_code_tick\\b|\\bsettings_code_switch_on\\b|\\bcode_folders_open\\b|\\btree_code_ticks\\b"), "recipe_tree still reaches a code switch or code tick function")
    }

    @Test("recipe_tree: the sums are taken from the whole pick list, before the app; the trace, both observers and plant 1 are all before the app")
    func recipeBeforeTheApp() {
        guard let own = raw("recipe_tree"), let t = contract(of: "recipe_tree") else { return }
        ok(has(own, "kit-sums\\.sh\"?[ ]+snapshot[ ]+sums-before[ ]+\\S*\\$"), "kit-sums.sh snapshot sums-before is not given the pick list (a variable holding it)")
        ok(has(own, "\\btree_pick_list[ ]+\"?\\$KIT_LIB/gate-matrix\\.csv\"?|\\btree_pick_list[ ]+\"?\\$\\{?KIT_LIB\\}?/gate-matrix\\.csv"), "the pick list is not made from scripts/kit-lib/gate-matrix.csv")
        guard let launch = firstIndex(t, "kit-launch\\.sh\"?[ ]+start[ ]+--mirror") else {
            ok(false, "recipe_tree never starts the app with --mirror")
            return
        }
        for step in ["kit-sums\\.sh\"?[ ]+snapshot[ ]+sums-before", "kit-trace\\.sh\"?[ ]+start[^\\n]*--net", "kit-net\\.sh\"?[ ]+start",
                     "kit-net\\.sh\"?[ ]+control", "kit-privacy\\.sh\"?[ ]+prompts[ ]+start[ ]+s8", "kit-mirror\\.sh\"?[ ]+start",
                     "kit-fixtures\\.sh\"?[ ]+build[ ]+matrix"] {
            if let at = firstIndex(t, step) { ok(at < launch, "`\(step)` is after the app started") } else { ok(false, "recipe_tree never runs `\(step)`") }
        }
    }

    @Test("recipe_tree: administrator rights, the trace, both observers and the two plants only with --trace; the prompts watcher always")
    func recipeTraceGuards() {
        guard let own = raw("recipe_tree"), let branch = caseBranch("--trace", in: own),
              let variable = groups(branch, "([A-Za-z_][A-Za-z0-9_]*)=\"\\$2\"").first?.first else {
            ok(false, "recipe_tree has no `--trace)` branch that keeps its name")
            return
        }
        for (what, pattern) in [("admin_session", "\\badmin_session\\b"), ("kit-trace.sh start", "kit-trace\\.sh\"?[ ]+start"),
                                ("kit-net.sh start", "kit-net\\.sh\"?[ ]+start"), ("kit-net.sh control", "kit-net\\.sh\"?[ ]+control"),
                                ("the wait done 1 that must time out", "kit-index\\.sh\"?[ ]+wait[ ]+done[ ]+1([^0-9]|$)")] {
            let g = guarded(own, variable: variable, matching: pattern)
            ok(!g.isEmpty, "recipe_tree never runs \(what)")
            ok(g.allSatisfy { $0 }, "recipe_tree runs \(what) without a trace too: it is not under `-n \"$\(variable)\"`")
        }
        ok(guarded(own, variable: variable, matching: "kit-net\\.sh\"?[ ]+control").count == 2, "recipe_tree must plant twice itself (plant 1 before the app, plant 2 mid-indexing), found \(guarded(own, variable: variable, matching: "kit-net\\.sh\"?[ ]+control").count) kit-net.sh control calls")
        let watcher = guarded(own, variable: variable, matching: "kit-privacy\\.sh\"?[ ]+prompts[ ]+start[ ]+s8")
        ok(watcher.count == 1, "recipe_tree must start the prompts watcher `s8` exactly once, found \(watcher.count)")
        ok(watcher.allSatisfy { !$0 }, "the prompts watcher is started only with --trace: it must run in every tree recipe (it needs no administrator rights)")
        ok(has(own, "kit-trace\\.sh\"?[ ]+start[ ]+\"?\\$\\{?\(variable)\\}?\"?[ ]+--net"), "the trace is not started as `kit-trace.sh start <name> --net`")
    }

    @Test("recipe_tree: a prompts watcher that does not start is exit 1 and nothing is launched")
    func recipePromptsFailure() {
        guard let own = raw("recipe_tree") else { return }
        let ls = own.split(separator: "\n").map(String.init)
        guard let i = ls.firstIndex(where: { has($0, "prompts[ ]+start[ ]+s8") }) else {
            ok(false, "recipe_tree never runs `kit-privacy.sh prompts start s8`")
            return
        }
        let window = ls[i...min(i + 2, ls.count - 1)].joined(separator: "\n")
        ok(has(window, "\\|\\|") && has(window, "return 1"), "a failed `prompts start s8` is not followed by `return 1` within two lines")
        if let launch = ls.firstIndex(where: { has($0, "kit-launch\\.sh\"?[ ]+start") }) { ok(launch > i, "the app is launched before the prompts watcher") }
    }

    @Test("recipe_tree: the picks go through pick_folders with a ten-minute fallback, the roots are compared exactly, Settings is opened and no code switch or tick is pressed")
    func recipePicks() {
        guard let t = contract(of: "recipe_tree"), let own = raw("recipe_tree") else { return }
        ok(has(own, "PK_WAIT=[^\\n]*600|KIT_PICK_WAIT:-600"), "the picker fallback does not wait up to 10 minutes (PK_WAIT 600)")
        ok(t.contains("NEEDS A PERSON: pick these folders"), "the picker fallback line `NEEDS A PERSON: pick these folders ...` is not part of the recipe (pick_folders)")
        ok(!own.contains("NOTE code ticks are disabled until plan 6"), "recipe_tree still prints `NOTE code ticks are disabled until plan 6`")
        ok(!has(t, "click[ ]+--help") && !has(t, "PK_TICKS|code folder") && !has(t, "click[ ]+\"Search my code\""), "recipe_tree still presses the code switch or a tick, or names ticks")
        ok(has(t, "\\bsettings_open\\b"), "recipe_tree does not open Settings before it starts indexing there")
        ok(has(t, "\\breal_path\\b") && has(t, "\\bsetup_folders\\b"), "the picked roots are not read from the setup window (setup_folders) and compared with real paths")
        ok(t.contains("RERUN picked roots differ from the pick list:"), "the message `RERUN picked roots differ from the pick list: <the difference>` is missing")
        ok(has(t, "return 4"), "recipe_tree has no exit 4")
        ok(has(own, "\\bpick_folders[ ]+\\S*\\$"), "pick_folders is not given the pick list (a variable holding it)")
    }

    @Test("recipe_tree writes run/recipe as `tree <name>` or `tree -`, last, after the wait done 1 check")
    func recipeWritesRecipeFile() {
        guard let own = raw("recipe_tree") else { return }
        let l = own.split(separator: "\n").map(String.init).filter { $0.contains("run/recipe") }
        ok(l.count == 1, "recipe_tree must write run/recipe once, found \(l.count) lines naming it")
        ok(l.allSatisfy { has($0, "tree") && has($0, "(:-[ ]*-|[ ]-[\"']?|tree -)") }, "run/recipe is not written as `tree <name>` or `tree -`: \(l)")
        if let w = firstIndex(own, "wait[ ]+done[ ]+1([^0-9]|$)"), let r = firstIndex(own, "run/recipe") {
            ok(w < r, "run/recipe is written before the mid-indexing check, so a recipe that failed it would look ready")
        }
    }

    @Test("recipe_tree calls only kit script modes that exist")
    func recipeModesExist() {
        guard let own = raw("recipe_tree") else { return }
        let allowed: [String: Set<String>] = [
            "kit-fixtures": ["build"], "kit-sums": ["snapshot"], "kit-trace": ["start"], "kit-net": ["start", "control", "stop"],
            "kit-privacy": ["prompts"], "kit-index": ["wait"], "kit-mirror": ["start"], "kit-launch": ["start"],
        ]
        for g in groups(own, "kit-([a-z]+)\\.sh\"?[ ]+([a-z][a-z-]*)") {
            guard g.count == 2 else { continue }
            let script = "kit-" + g[0]
            ok(allowed[script]?.contains(g[1]) == true, "recipe_tree calls `\(script).sh \(g[1])`, which the entry does not list")
        }
        ok(has(own, "build[ ]+tree") && has(own, "build[ ]+matrix"), "recipe_tree does not build both `tree` and `matrix`")
    }

    // MARK: tree_pick_list, pure

    @Test("tree_pick_list on a hand-written 8-row table: the tree folders but never-picked, the own folder of blank picks, every named folder, never a `-` folder, each once")
    func pickListEightRows() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let csv = header + """
        a-photo,alpha/a_zq9001.png,,yes,1,ok,spec
        a-doc,alpha/a_zq9002.txt,,yes,1,ok,spec
        b-code,bravo/b_zq9003.py,bravo,yes,1,ok,spec
        c-in,charlie/outer/inner/c_zq9004.png,charlie/outer|charlie/outer/inner,yes,1,ok,spec
        c-out,charlie/outer/o_zq9005.png,charlie/outer|charlie/outer/inner,yes,1,ok,spec
        d-never,delta/secret_zq9006.png,-,no,0,never-picked,spec
        a-link,alpha/link_zq9007.png,,no,0,link,spec
        e-hidden,echo/.ssh/e_zq9008.png,,no,0,hidden-folder,spec

        """
        let ran = try pickList(rig, csv: csv)
        #expect(ran.status == 0, "tree_pick_list exited \(ran.status): \(ran.output)")
        let got = lines(ran.output)
        let want = treeFolders.union(["matrix/alpha", "matrix/bravo", "matrix/charlie/outer", "matrix/charlie/outer/inner", "matrix/echo"])
        #expect(Set(got) == want, "pick list is \(got.sorted()), expected \(want.sorted())")
        #expect(got.count == Set(got).count, "a folder is listed twice: \(got)")
        #expect(!ran.output.contains("never-picked") && !ran.output.contains("delta"), "a never-picked or `-` folder is in the list: \(ran.output)")
    }

    @Test("tree_pick_list: every line is a path under the fixture root, sorted, one folder each")
    func pickListShape() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let ran = try pickList(rig, csv: header + "x,zeta/z_zq9101.png,,yes,1,ok,spec\ny,beta/b_zq9102.png,,yes,1,ok,spec\n")
        #expect(ran.status == 0, "tree_pick_list exited \(ran.status): \(ran.output)")
        let got = lines(ran.output)
        #expect(got.allSatisfy { $0.hasPrefix("tree/") || $0.hasPrefix("matrix/") }, "a line is not under tree/ or matrix/: \(got)")
        #expect(got == got.sorted(), "the list is not sorted: \(got)")
        #expect(got.contains("matrix/zeta") && got.contains("matrix/beta"), "the blank-picks folders are missing: \(got)")
    }

    @Test("tree_pick_list: a folder named by two rows, or by a blank row and a named pick, is listed once and is exit 0")
    func pickListSameFolderTwice() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let named = try pickList(rig, csv: header + "p,bravo/p_zq9201.py,bravo,yes,1,ok,spec\nq,bravo/q_zq9202.py,bravo,yes,1,ok,spec\n")
        #expect(named.status == 0 && lines(named.output).filter { $0 == "matrix/bravo" }.count == 1, "two rows naming bravo: exit \(named.status), \(named.output)")
        let blank = try pickList(rig, csv: header + "p,bravo/p_zq9301.png,,yes,1,ok,spec\nq,bravo/q_zq9302.py,bravo,yes,1,ok,spec\n")
        #expect(blank.status == 0 && lines(blank.output).filter { $0 == "matrix/bravo" }.count == 1, "a blank row and a named pick of bravo: exit \(blank.status), \(blank.output)")
    }

    @Test("tree_pick_list: a `-` folder that another row picks, by a blank or by a named pick, is exit 4")
    func pickListDashFolderPickedElsewhere() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let named = try pickList(rig, csv: header + "n,delta/n_zq9401.png,-,no,0,never-picked,spec\nm,other/m_zq9402.png,delta,yes,1,ok,spec\n")
        #expect(named.status == 4, "a `-` folder named in another row's picks exited \(named.status), expected 4: \(named.output)")
        #expect(named.output.contains("delta"), "the `-` folder is not named: \(named.output)")
        let blank = try pickList(rig, csv: header + "n,delta/n_zq9403.png,-,no,0,never-picked,spec\nm,delta/m_zq9404.png,,yes,1,ok,spec\n")
        #expect(blank.status == 4, "a `-` folder that a blank-picks row picks exited \(blank.status), expected 4: \(blank.output)")
    }

    @Test("tree_pick_list: a pick that still carries a tick suffix (:on, :off or any other) is exit 4 and names the pick, and a missing table is not exit 0")
    func pickListBadInput() throws {
        let rig = try Rig()
        defer { rig.remove() }
        for pick in ["bravo:on", "bravo:off", "bravo:maybe"] {
            let bad = try pickList(rig, csv: header + "p,bravo/p_zq9501.py,\(pick),yes,1,ok,spec\n")
            #expect(bad.status == 4 && bad.output.contains(pick), "the pick \(pick) exited \(bad.status), expected 4 naming it: \(bad.output)")
        }
        let none = try rig.shell("tree_pick_list \"$2\"", [rig.base.appendingPathComponent("no-such.csv").path])
        #expect(none.status != 0, "a missing table exited 0: \(none.output)")
    }

    @Test("tree_pick_list on the real gate-matrix.csv: the hand-named folders are in, never-picked is out, pairs are listed outer then inner, no folder twice")
    func pickListRealTable() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let ran = try rig.shell("tree_pick_list \"$1/gate-matrix.csv\"")
        #expect(ran.status == 0, "tree_pick_list on the real table exited \(ran.status): \(ran.output)")
        let got = lines(ran.output)
        #expect(got.count == Set(got).count, "a folder is listed twice")
        #expect(treeFolders.isSubset(of: Set(got)), "the tree folders are not all in the list: \(got.filter { $0.hasPrefix("tree/") })")
        // Amended in plan-4-t2: `extdoc` is a new top folder of the matrix (the seven extdoc-* cells, one per document and pdf
        // extension), and the S8 session picks every top folder of the matrix that the table names, so it is in the list; the
        // count below grows by that one folder. Nothing else changed, no pin weakened.
        // Amended again in plan-5-t1: `extav` is a new top folder of the matrix (the eight extav-* cells, one per audio and video
        // extension), picked the same way, so it is in the list and the count grows by that one folder. No pin weakened.
        // Amended again in plan-6-t1 (reason: part B of the entry adds the cells ext-<code ext> under `extcode/`, key-code-id_rsa-py and
        // key-code-env-py under `keys-code/`, and damaged-swift and good-swift under `damaged-code/`): `extcode`, `keys-code` and `damaged-code`
        // are three new top folders of the matrix, each with an `on` pick, so they are in the list and the count grows by those three.
        // Nothing else changed, no pin weakened.
        let matrixHand = ["plain", "plain-code-on", "ext", "extdoc", "extav", "extcode", "keys", "keys-extra", "keys-code", "hidden-ssh", "hidden-config", "caches-png", "app-png",
                          "app-txt", "cloud-sparse-jpg", "unsup", "damaged", "damaged-code", "repo-off", "ignored-off", "ignored-on", "vend-in", "vend-out",
                          "ov-a/outer", "ov-a/outer/inner", "ov-b/outer", "ov-b/outer/inner", "ov-c/outer", "ov-c/outer/inner",
                          "ov-d/outer", "ov-d/outer/inner"].map { "matrix/" + $0 }
        for m in matrixHand { #expect(got.contains(m), "\(m) is not in the pick list") }
        #expect(!got.contains { $0.contains("never-picked") }, "a never-picked folder is in the list: \(got.filter { $0.contains("never-picked") })")
        #expect(got.allSatisfy { $0.hasPrefix("tree/") || $0.hasPrefix("matrix/") })
        #expect(got.count == treeFolders.count + matrixHand.count, "the list holds \(got.count) folders, expected \(treeFolders.count + matrixHand.count): \(got)")
    }

    // MARK: tree_need

    @Test("tree_need does nothing when run/recipe holds `tree` (with a trace or without), and calls no recipe")
    func treeNeedNothing() throws {
        let rig = try Rig()
        defer { rig.remove() }
        for content in ["tree s8\n", "tree -\n"] {
            _ = try rig.write(content, to: "sesame-kit-t8test/run/recipe")
            let ran = try rig.shell("recipe_tree() { echo RECIPE_TREE \"$@\"; return 0; }; sudo() { return 0; }; tree_need; echo \"rc=$?\"")
            #expect(ran.output.contains("rc=0") && !ran.output.contains("RECIPE_TREE"), "run/recipe `\(content.trimmingCharacters(in: .whitespacesAndNewlines))`: tree_need printed \(ran.output)")
        }
    }

    @Test("tree_need runs `recipe_tree --trace s8` when sudo -n true holds, and `recipe_tree` with no trace when it does not")
    func treeNeedRuns() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let withSession = try rig.shell("recipe_tree() { echo \"RECIPE_TREE[$*]\"; return 0; }; sudo() { return 0; }; tree_need; echo \"rc=$?\"")
        #expect(withSession.output.contains("RECIPE_TREE[--trace s8]") && withSession.output.contains("rc=0"), "with an administrator session: \(withSession.output)")
        let without = try rig.shell("recipe_tree() { echo \"RECIPE_TREE[$*]\"; return 0; }; sudo() { return 1; }; tree_need; echo \"rc=$?\"")
        #expect(without.output.contains("RECIPE_TREE[]") && without.output.contains("rc=0"), "with no administrator session: \(without.output)")
        _ = try rig.write("golden\n", to: "sesame-kit-t8test/run/recipe")
        let wrongRecipe = try rig.shell("recipe_tree() { echo \"RECIPE_TREE[$*]\"; return 0; }; sudo() { return 1; }; tree_need; echo \"rc=$?\"")
        #expect(wrongRecipe.output.contains("RECIPE_TREE[]"), "run/recipe holding another recipe must start the tree recipe: \(wrongRecipe.output)")
    }

    @Test("tree_need returns the exit code of a recipe that did not finish, and asks for nothing itself")
    func treeNeedFailureAndNeverAsks() throws {
        let rig = try Rig()
        defer { rig.remove() }
        for code in [1, 3, 4] {
            let ran = try rig.shell("recipe_tree() { return \(code); }; sudo() { return 1; }; tree_need; echo \"rc=$?\"")
            #expect(ran.output.contains("rc=\(code)"), "recipe_tree exiting \(code): tree_need printed \(ran.output)")
        }
        guard let own = raw("tree_need") else { return }
        ok(!own.contains("ask-admin") && !has(own, "\\badmin_session\\b"), "tree_need asks for administrator rights itself: it must only test `sudo -n true`")
        ok(has(own, "sudo -n true"), "tree_need does not test `sudo -n true`")
    }

    @Test("the check id given to tree_need is appended to run/window-ids only while the observers are open")
    func windowIds() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let stub = "recipe_tree() { return 0; }; sudo() { return 1; }; "
        let ids = rig.runDir.appendingPathComponent("window-ids")
        func current() -> [String] { lines(read(ids) ?? "") }
        _ = try rig.write("tree s8\n", to: "sesame-kit-t8test/run/recipe")
        _ = try rig.shell(stub + "tree_need S8.5; tree_need S2.17; tree_need")
        #expect(current() == ["S8.5", "S2.17"], "ids while the window is open: \(current())")
        _ = try rig.write("1700000000.000\n", to: "sesame-kit-t8test/run/observers-closed-at")
        _ = try rig.shell(stub + "tree_need S8.6")
        #expect(current() == ["S8.5", "S2.17"], "an id was appended after the observers were closed: \(current())")
        try? FileManager.default.removeItem(at: rig.runDir.appendingPathComponent("observers-closed-at"))
        try? FileManager.default.removeItem(at: ids)
        _ = try rig.write("tree -\n", to: "sesame-kit-t8test/run/recipe")
        _ = try rig.shell(stub + "tree_need S8.5")
        #expect(current().isEmpty, "a recipe with no trace has no window, but ids were appended: \(current())")
    }

    // MARK: the exact comparison of the picked roots

    @Test("the picked roots under matrix/ are compared exactly with the pick list: equal is exit 0; an extra, a missing and a child spelling are exit 4 with the difference")
    func rootsCheck() throws {
        let rig = try Rig()
        defer { rig.remove() }
        for d in ["a", "b/c", "z"] {
            try FileManager.default.createDirectory(at: rig.kit.appendingPathComponent("fixtures/matrix/" + d), withIntermediateDirectories: true)
        }
        // realpath(3): Foundation's resolvingSymlinksInPath drops the /private of /private/var, the shell's `pwd -P` keeps it
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let matrixPath = rig.kit.appendingPathComponent("fixtures/matrix").path
        let realMatrix = realpath(matrixPath, &buffer) != nil
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : matrixPath
        let list = "matrix/a\nmatrix/b/c\ntree/plain\n"
        func check(_ rows: [String]) throws -> Ran {
            let rowText = rows.map { $0.hasPrefix("/") ? $0 : realMatrix + "/" + $0 }.joined(separator: "\\n")
            return try rig.shell("setup_folders() { printf '\(rowText)\\n'; }; tree_roots_check \"$2\"; echo \"rc=$?\"", [list])
        }
        let equal = try check(["a", "b/c", "/somewhere/else/tree/plain"])
        #expect(equal.output.contains("rc=0") && !equal.output.contains("RERUN"), "equal roots: \(equal.output)")
        let extra = try check(["a", "b/c", "z"])
        #expect(extra.output.contains("rc=4") && extra.output.contains("RERUN picked roots differ from the pick list:") && extra.output.contains("z"), "an extra root: \(extra.output)")
        let missing = try check(["a"])
        #expect(missing.output.contains("rc=4") && missing.output.contains("RERUN picked roots differ from the pick list:") && missing.output.contains("b/c"), "a missing root: \(missing.output)")
        let child = try check(["a/sub", "b/c"])
        #expect(child.output.contains("rc=4") && child.output.contains("a/sub"), "a child spelling (the picker's lone-subfolder quirk): \(child.output)")
        let none = try check([])
        #expect(none.output.contains("rc=4"), "no picked root at all: \(none.output)")
    }

    // MARK: the session functions

    @Test("s8_activity: tree_need, the waits, the before snapshot, the searches, the after snapshot, then the done line; nothing runs twice")
    func activityOrder() {
        guard let t = contract(of: "s8_activity"), let own = raw("s8_activity") else { return }
        inOrder(t, [
            "\\btree_need\\b",
            "kit-index\\.sh\"?[ ]+wait[ ]+done[ ]+900",
            "\\bwait_menu_ready[ ]+120\\b",
            "kit-index\\.sh\"?[ ]+snapshot[ ]+before-opens",
            "kit-search\\.sh",
            "kit-index\\.sh\"?[ ]+snapshot[ ]+after-opens",
            "s8-activity-done",
        ], "s8_activity order")
        let ls = own.split(separator: "\n").map(String.init)
        if let guardLine = ls.firstIndex(where: { has($0, "-f[^\\n]*(s8-activity-done|\\$\\{?[a-z_]*done[a-z_]*\\}?)") && has($0, "return 0") }) {
            if let search = ls.firstIndex(where: { has($0, "kit-search\\.sh") }) { ok(guardLine < search, "the `already done` guard comes after the first search") }
            if let first = ls.firstIndex(where: { has($0, "\\btree_need\\b") }) { ok(guardLine < first, "the `already done` guard comes after tree_need") }
        } else {
            ok(false, "s8_activity has no `[ -f <done file> ] && return 0` line: a second call would run the session again")
        }
        for field in ["searches=", "opens=", "indexing-done-at=", "last-open-at="] {
            ok(own.contains(field), "the done line does not hold `\(field)`")
        }
        ok(own.contains("s8-activity-done"), "s8_activity never names run/s8-activity-done")
    }

    @Test("s8_activity: 50 marker searches `qm-<n>-<seed>` written first to markers.txt, 20 real fixture name stems opened with plain Enter")
    func activityMarkersAndStems() {
        guard let t = contract(of: "s8_activity"), let own = raw("s8_activity") else { return }
        ok(own.contains("markers.txt") && own.contains("qm-"), "s8_activity does not write the markers `qm-<n>-<seed>` to markers.txt")
        ok(has(own, "\\b50\\b"), "s8_activity never names 50 (the marker searches)")
        ok(has(own, "\\b14\\b"), "s8_activity never names 14 (the stem searches that are opened: with the six opens of the order test they are the 20 opens)")
        ok(has(t, "tree\\.tsv"), "the fixture name stems do not come from tree.tsv")
        ok(has(t, "kit-search\\.sh") && has(own, "--open"), "no search is followed by an open (`kit-search.sh ... --open`, plain Enter)")
        ok(has(t, "\"\\$KIT_SCRIPTS/kit-search\\.sh\""), "the searches are not made through $KIT_SCRIPTS/kit-search.sh")
        ok(!has(t, "--reveal|--copy|cmd\\+enter|command\\+enter"), "an open uses Command+Enter, reveal or copy: only plain Enter, the default app opens")
        if let m = firstIndex(own, "markers\\.txt"), let s = firstIndex(own, "kit-search\\.sh") {
            ok(m < s, "markers.txt is written after the first search, not first")
        }
    }

    @Test("s8_activity: the order test lists search A, opens result 3 five times, lists again, opens a different result, lists again")
    func activityOrderTest() {
        guard let own = raw("s8_activity") else { return }
        inOrder(own, ["order-before", "--select[ ]+3[^\\n]*--open|--open[^\\n]*--select[ ]+3", "order-mid", "--select[ ]+[124-9][^\\n]*--open|--open[^\\n]*--select[ ]+[124-9]", "order-after"],
                "the order test")
        ok(has(own, "\\b5\\b"), "the five opens of result 3 are not counted in the loop")
        ok(own.contains("order-before.txt") && own.contains("order-mid.txt") && own.contains("order-after.txt"), "the three listings are not saved as order-before.txt, order-mid.txt and order-after.txt")
    }

    @Test("s8_activity tolerates empty results and holds none of the readers' guards; only a real precondition is exit 4")
    func activityTolerant() {
        guard let own = raw("s8_activity") else { return }
        ok(!has(own, "RERUN S8\\.[0-9]+"), "s8_activity prints a reader's RERUN (S8.3, S8.7 and S8.9 guard their own readings, not this function)")
        ok(!has(own, "opens[ ]*(=|-eq|-lt)[ ]*0[^\\n]*(return 4|RERUN)") && !has(own, "(return 4|RERUN)[^\\n]*opens[ ]*=[ ]*0"), "s8_activity ends with exit 4 when no open happened")
        ok(has(own, "wait[ ]+done[ ]+900[^\\n]*(\\|\\||\\n[^\\n]*return 4)") || has(own, "wait[ ]+done[ ]+900[^\\n]*\\n[^\\n]*(RERUN|return)"), "a `wait done 900` that times out does not end the function with exit 4")
        ok(has(own, "wait_menu_ready[ ]+120[^\\n]*(\\|\\||\\n[^\\n]*return)") , "a `wait_menu_ready 120` that fails does not end the function")
        ok(has(own, "return 4"), "s8_activity has no exit 4 at all, so a wait that times out cannot be reported")
    }

    @Test("s8_close_window: tree_need, s8_activity, then the prompts watcher once, then administrator rights, plant 3, net stop, trace stop, the closing time")
    func closeWindowOrder() {
        guard let t = contract(of: "s8_close_window"), let own = raw("s8_close_window") else { return }
        inOrder(t, [
            "\\btree_need\\b",
            "\\bs8_activity\\b",
            "kit-privacy\\.sh\"?[ ]+prompts[ ]+stop[ ]+s8",
            "\\badmin_session\\b",
            "kit-net\\.sh\"?[ ]+control",
            "kit-net\\.sh\"?[ ]+stop",
            "kit-trace\\.sh\"?[ ]+stop",
            "observers-closed-at",
        ], "s8_close_window order")
        let ls = own.split(separator: "\n").map(String.init)
        if let stop = ls.firstIndex(where: { has($0, "prompts[ ]+stop[ ]+s8") }) {
            ok(ls[0..<stop].contains { has($0, "s8\\.result") && has($0, "-f") }, "the watcher is stopped without looking at run/prompts/s8.result first: a second call would stop it again")
        }
        let closedAt = ls.enumerated().filter { $0.element.contains("observers-closed-at") }.map(\.offset)
        ok(closedAt.count >= 2, "run/observers-closed-at must be tested before the observers are closed and written after, found \(closedAt.count) mentions")
        if let c = ls.firstIndex(where: { has($0, "kit-net\\.sh\"?[ ]+control") }), let first = closedAt.first, let last = closedAt.last {
            ok(first < c && c < last, "run/observers-closed-at is not both the guard before plant 3 and the line written after the traces stopped")
        }
        ok(has(own, "run/recipe|\\btree_trace_name\\b"), "s8_close_window does not read the trace name from run/recipe, so a `tree -` recipe cannot skip the observers")
        ok(has(own, "(\\$\\{?[a-z_]+\\}?|\")[^\\n]*kit-net\\.sh\"?[ ]+control[ ]+\"?\\$"), "plant 3 is not made with the trace name")
    }

    @Test("run/window-ids is written by the code that notes the check ids while the observers are open")
    func windowIdsAreWritten() {
        let recipes = read(libDir.appendingPathComponent("recipes.sh")).map(stripComments) ?? ""
        let session = read(libDir.appendingPathComponent("checks-s8session.sh")).map(stripComments) ?? ""
        ok((recipes + session).contains("window-ids"), "no code appends the check ids to run/window-ids")
        ok(has(recipes + session, "observers-closed-at"), "the window is not closed by run/observers-closed-at")
    }

    // MARK: everything

    @Test("no function of the tree recipe or the S8 session reads Sources/, and typing goes through kit-search.sh and kit-ax.sh only", arguments: ["recipe_tree", "tree_pick_list", "tree_need", "tree_roots_check", "s8_activity", "s8_close_window"])
    func cleanFunctions(_ function: String) {
        guard let t = contract(of: function) else { return }
        ok(!t.contains("Sources/") && !has(t, "\\bSources\\b"), "\(function) names Sources: the kit never reads the product's source")
        ok(!has(t, "--delay-ms"), "\(function) passes --delay-ms, which overrides KIT_TYPE_DELAY_MS")
        ok(!has(t, "(^|[^A-Za-z0-9_])KIT_TYPE_DELAY_MS="), "\(function) sets KIT_TYPE_DELAY_MS itself")
        ok(!has(t, "keytool|cliclick|CGEvent|key code|keystroke"), "\(function) posts keys by a tool of its own")
        ok(!has(t, "\\bosascript\\b[^\\n]*\\bkeystroke"), "\(function) types by osascript")
        ok(!has(t, "\\bsudo[ ]+(?!-n\\b)"), "\(function) calls sudo without -n: the one password prompt of the kit is kit-perms.sh ask-admin")
    }

    @Test("the S8 session lives in a new file the runner sources: checks-s8session.sh, with no check function in it")
    func sessionFile() {
        let url = libDir.appendingPathComponent("checks-s8session.sh")
        guard let text = read(url) else {
            Issue.record("scripts/kit-lib/checks-s8session.sh not found")
            return
        }
        let fns = shellFunctions(in: stripComments(text))
        ok(fns["s8_activity"] != nil && fns["s8_close_window"] != nil, "checks-s8session.sh does not define s8_activity and s8_close_window")
        ok(!fns.keys.contains { $0.hasPrefix("check_") }, "checks-s8session.sh defines a check function \(fns.keys.filter { $0.hasPrefix("check_") }): the checks are t9 to t11")
        let run = read(scriptsDir.appendingPathComponent("kit-run.sh")) ?? ""
        ok(has(run, "checks-\\*\\.sh"), "kit-run.sh no longer sources every scripts/kit-lib/checks-*.sh")
    }
}

import Foundation
import Testing

// plan-4-t3, tester step: kit part 2, the recipe `golden`, the checks S3.1 to S3.10 and S2.4 (a new scripts/kit-lib/checks-s3.sh holds
// check_S3_1 to check_S3_10 and their `s3_` helpers; check_S2_4 lives in checks-s2c.sh; recipes.sh gets recipe_golden, golden_need,
// golden_release, golden_pick_list, golden_roots_diff and golden_roots_check, scripts/kit-lib/golden-roots.tsv is the hand-written table of
// what each golden folder holds, kit-run.sh gets `prep golden [--hold-start]` in its usage). Written from the entry plan-4-t3 of
// plan-4-tasks.md, verify.md, the feature maps S2 and S3, the t2 report and the kit as it stands; no product source is read, and no
// kit function may read it.
//
// Static proof only (plan-4-tasks.md, Conventions: no app launch in any task): a check needs the app, the panel, Preview, the model and
// the index, so NOTHING here runs a check, the recipe, `kit-run.sh`, `verify.sh`, `kit-golden.sh engine|panel`, `kit-search.sh`,
// `kit-ax.sh`, `kit-readback.sh ping|frontmost` or any script that starts or drives an app. The runs are `bash -n`, the pure helpers of
// recipes.sh and checks-s3.sh sourced in a child bash on hand-written tables, keys and outputs (the expected values are written in this
// file, never read from the kit), and the text of the check files with their comment lines removed (a comment never satisfies a test).
// Real behaviour is read at the accept stage only (blocks A and B).
//
// The contract read here (plan-4-t3, Tests, and the picks of the tester, listed in the report):
//   - `kit-run.sh prep golden [--hold-start]` is in the usage; recipe_main has a `golden)` branch running recipe_golden and no longer says
//     `not built yet` for golden (golden-code, overlap, mix500 and index50k still do);
//   - recipe_golden: recipe_state, models_check, recipe_reset cache, `kit-fixtures.sh build golden`, `build golden-docs`, `build boundary`,
//     pick_folders of golden_pick_list (the table is scripts/kit-lib/golden-roots.tsv: `<folder><TAB><subfolders, comma separated>`;
//     golden has the one subfolder photos, so the picker adds it as it does for the recipe `photos`, golden-docs has two and boundary none,
//     so each adds itself), golden_roots_check against that list as `tree_roots_check` does, then with --hold-start it writes
//     `golden hold` to run/recipe and stops before press_start; without it press_start, `kit-index.sh wait done`, wait_menu_ready, and
//     `golden` in run/recipe;
//   - golden_need [--hold]: nothing when run/recipe holds exactly `golden` (and with --hold when it holds `golden hold`); `golden hold`
//     without --hold runs golden_release (press Start, wait for done and Ready, write `golden`); anything else runs recipe_golden
//     (--hold-start with --hold). It returns the recipe's status. Never `kit-golden.sh prepare`;
//   - the recipe `photos` is unchanged: `pick_folders golden golden/photos` stays, so the S1 and S2 photo checks stay photo-only;
//   - each of check_S3_1 to check_S3_10 and check_S2_4 starts with golden_need and holds the contract of its feature-map line;
//   - checks.tsv keeps the 11 ids at slice 4 (S3.4 and S3.9 auto-or-person, the others auto); `slice` holds 4; `checks.floor` is the
//     recount of the `auto` ids of slices 1 to 4 that need no administrator rights: 70 + S2.4 + S3.1, S3.2, S3.3, S3.5, S3.6, S3.7, S3.8,
//     S3.10 = 79 (the entry's 81 is a guess that counted S3.4 and S3.9, which are auto-or-person and never count);
//   - verify.sh --quick keeps the S3 ids and S2.4 out (they are in no quick step, only in the full `kit-run.sh all --slice N`).

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s3.sh")
private let s2cFile = libDir.appendingPathComponent("checks-s2c.sh")
private let recipesFile = libDir.appendingPathComponent("recipes.sh")
private let rootsTable = libDir.appendingPathComponent("golden-roots.tsv")

private let s3Ids = ["S3.1", "S3.2", "S3.3", "S3.4", "S3.5", "S3.6", "S3.7", "S3.8", "S3.9", "S3.10"]
private let allIds = s3Ids + ["S2.4"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun3-out-" + UUID().uuidString)
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

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func firstIndex(_ text: String, _ pattern: String) -> Int? {
    guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
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

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func stripComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
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

private func kitShellSources() -> [(name: String, code: String)] {
    var all: [(String, String)] = []
    if let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) { all.append(("kit-run.sh", stripComments(text))) }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: libDir.path)) ?? []).filter { $0.hasSuffix(".sh") }.sorted()
    for name in names {
        if let text = read(libDir.appendingPathComponent(name)) { all.append(("kit-lib/" + name, stripComments(text))) }
    }
    return all
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
            }
        }
    }
    return values
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

private func checkFunctionName(_ id: String) -> String { "check_" + id.replacingOccurrences(of: ".", with: "_") }

/// The body of the function that holds the check's logic: `s3_check_<n>` (checks-s3.sh) or `s2c_check_4` (checks-s2c.sh), with the
/// top-level variables written in. Records the reason and returns nil when it does not exist.
private func logic(_ id: String) -> String? {
    let all = allFunctions()
    let name = id == "S2.4" ? "s2c_check_4" : "s3_check_" + String(id.dropFirst(3))
    guard let text = all[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    // the driving helpers a check calls are part of what it does; the pure readers stay calls
    var full = text
    for helper in ["s3_open_pdf", "s3_select_pane", "s3_choose_pdf_app"] where text.contains(helper) {
        if let h = all[helper] { full += "\n" + h }
    }
    return substitute(full, topLevelValues())
}

private func before(_ text: String, _ a: String, _ b: String, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let ia = firstIndex(text, a), let ib = firstIndex(text, b) else {
        ok(false, "\(message) (missing: \(firstIndex(text, a) == nil ? a : b))", sourceLocation: sourceLocation)
        return
    }
    ok(ia < ib, message, sourceLocation: sourceLocation)
}

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

private func lines(_ ran: Ran) -> [String] { ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

/// A scratch folder with root/run (the kit root, a folder named sesame-kit*), lib/ (hand-written tables) and files.
private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun3-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sesame-kit-t/run"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
    return dir
}

private func put(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// Sources common.sh, recipes.sh and checks-s3.sh in a child bash (only definitions and the files they source run), points
/// GOLDEN_ANSWERS and KIT_LIB at the scratch folder's hand-written key and tables, then runs `call` with `stdin` (a file) as its input.
private func pure(_ call: String, in dir: URL, stdin: String? = nil, extra: String = "") throws -> Ran {
    var input = ""
    if let stdin {
        let f = dir.appendingPathComponent("stdin.txt")
        try put(stdin, f)
        input = " < '\(f.path)'"
    }
    let script = """
    export KIT_ROOT='\(dir.path)/sesame-kit-t'; . '\(libDir.path)/common.sh' && . '\(recipesFile.path)' && . '\(checkFile.path)'
    GOLDEN_ANSWERS='\(dir.path)/answers.csv'; KIT_LIB='\(dir.path)/lib'; \(extra)
    { \(call); }\(input)
    """
    return try run("/bin/bash", ["-c", script])
}

@Suite("KitRunS3ChecksTests")
struct KitRunS3ChecksTests {

    // MARK: syntax and wiring

    @Test("bash -n finds no syntax error in kit-run.sh, verify.sh, kit-readback.sh, recipes.sh, checks-s3.sh and checks-s2c.sh (none is run)")
    func bashSyntax() throws {
        for url in [scriptsDir.appendingPathComponent("kit-run.sh"), scriptsDir.appendingPathComponent("verify.sh"), scriptsDir.appendingPathComponent("kit-readback.sh"),
                    recipesFile, checkFile, s2cFile, libDir.appendingPathComponent("golden.sh")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record(Comment(rawValue: "\(url.path) not found"))
                continue
            }
            let ran = try run("/bin/bash", ["-n", url.path])
            ok(ran.status == 0 && ran.output.isEmpty, "bash -n \(url.path) exited \(ran.status): \(ran.output)")
        }
    }

    @Test("checks-s3.sh holds no top-level command when it is sourced: only variables, `. \"$KIT_LIB/<file>.sh\"` lines and function definitions")
    func noTopLevelCommands() {
        guard let text = read(checkFile) else { Issue.record("scripts/kit-lib/checks-s3.sh not found"); return }
        var depth = 0
        var strays: [String] = []
        for line in stripComments(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if depth == 0, !line.trimmingCharacters(in: .whitespaces).isEmpty,
               !has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"^[A-Z][A-Z0-9_]*="#), !has(line, #"^\. "\$KIT_LIB/[a-z0-9-]+\.sh"$"#) {
                strays.append(line)
            }
            if has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"\}$"#) { depth += 1 }
            if line == "}" { depth = max(0, depth - 1) }
        }
        ok(strays.isEmpty, "checks-s3.sh runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("the runner sources every checks-*.sh, so the new file needs no wiring; no kit file touched here names product source")
    func runnerAndSources() {
        let runner = read(scriptsDir.appendingPathComponent("kit-run.sh")).map(stripComments) ?? ""
        ok(has(runner, #"checks-\*\.sh"#), "kit-run.sh no longer sources every scripts/kit-lib/checks-*.sh")
        for (name, code) in kitShellSources() where ["kit-lib/checks-s3.sh", "kit-lib/recipes.sh", "kit-lib/checks-s2c.sh"].contains(name) {
            ok(!has(code, "Sources/"), "\(name) names product source (Sources/): no kit function may read it")
        }
        let rb = read(scriptsDir.appendingPathComponent("kit-readback.sh")).map(stripComments) ?? ""
        ok(!has(rb, "Sources/"), "kit-readback.sh names product source")
    }

    // MARK: the registry, the slice and the floor

    @Test("checks.tsv keeps the 11 ids at slice 4 once each: S3.4 and S3.9 auto-or-person, every other one auto", arguments: allIds)
    func registered(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            ok(row.slice == "4", "\(id) is registered at slice \(row.slice), expected 4")
            let want = (id == "S3.4" || id == "S3.9") ? "auto-or-person" : "auto"
            ok(row.kind == want, "\(id) has kind \(row.kind), expected \(want) (feature map: S3.4 and S3.9 may print NEEDS-A-PERSON)")
        }
    }

    @Test("each of the 11 checks is defined once in the kit: S3.1 to S3.10 in checks-s3.sh, S2.4 in checks-s2c.sh", arguments: allIds)
    func exactlyOneFunction(_ id: String) {
        let name = checkFunctionName(id)
        var where_: [String] = []
        for (file, code) in kitShellSources() where shellFunctions(in: code)[name] != nil { where_.append(file) }
        ok(where_ == [id == "S2.4" ? "kit-lib/checks-s2c.sh" : "kit-lib/checks-s3.sh"], "\(name) is defined in \(where_), expected exactly the one file for \(id)")
    }

    @Test("slice holds 8 and checks.floor is the recount: the 85 auto ids of slices 1 to 5 without administrator rights (78 of slices 1 to 4 plus the seven of slice 5) plus S2.15 plus the five S9 auto ids plus the two S10 auto ids = 93 (plan-8-t9 amended: S10.5 and S10.8 added, slice 7 to 8; was 91 and 7)")
    func sliceAndFloor() {
        let slice = read(libDir.appendingPathComponent("slice"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        ok(slice == "8", "scripts/kit-lib/slice holds \(slice ?? "nothing"), expected 8")
        guard let rows = tsvRows() else { return }
        // the five administrator ids of slices 1 to 3 (S6.8, S8.2, S8.3, S8.7, S6.13); none of the ids of slices 4 and 5 primes or reads the trace as an auto id
        let admin: Set<String> = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]
        let upTo4 = rows.filter { $0.kind == "auto" && (Int($0.slice) ?? 99) <= 4 && !admin.contains($0.id) }
        // hand recount: plan 3's 70 plus S2.4, S3.1, S3.2, S3.3, S3.5, S3.6, S3.7, S3.8 and S3.10 (S3.4 and S3.9 are auto-or-person), less S6.9
        ok(upTo4.count == 78, "the recount of slices 1 to 4 from checks.tsv is \(upTo4.count) auto ids, the hand recount is 78")
        let counted = rows.filter { $0.kind == "auto" && (Int($0.slice) ?? 99) <= 5 && !admin.contains($0.id) }
        ok(counted.count == 85, "the recount from checks.tsv is \(counted.count) auto ids, the hand recount is 85")
        ok(!rows.contains { $0.id.hasPrefix("S5.") }, "checks.tsv still holds an S5 id")
        let floor = Int((read(libDir.appendingPathComponent("checks.floor")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let second = ["S2.15"].filter { id in rows.contains { $0.id == id && $0.slice == "6" && $0.kind == "auto" } }
        ok(second.count == 1, "checks.tsv does not hold S2.15 as an auto id of slice 6")
        let s9 = ["S9.1", "S9.2", "S9.3", "S9.4", "S9.5"].filter { id in rows.contains { $0.id == id && $0.slice == "7" && $0.kind == "auto" } }
        ok(s9.count == 5, "checks.tsv does not hold S9.1 to S9.5 as auto ids of slice 7")
        let s10 = ["S10.5", "S10.8"].filter { id in rows.contains { $0.id == id && $0.slice == "8" && $0.kind == "auto" } }
        ok(s10.count == 2, "checks.tsv does not hold S10.5 and S10.8 as auto ids of slice 8")
        ok(floor == counted.count + second.count + s9.count + s10.count && floor == 93, "checks.floor reads \(floor.map(String.init) ?? "nothing"), the recount is 85 + 1 + 5 + 2 = 93")
    }

    @Test("verify.sh --quick keeps the S3 ids and S2.4 out: no quick step runs one, and the guard on S8.10 is unchanged")
    func quickRunKeepsS3Out() {
        guard let code = read(scriptsDir.appendingPathComponent("verify.sh")).map(stripComments) else { Issue.record("scripts/verify.sh not found"); return }
        guard let main = shellFunctions(in: code)["main"] else { Issue.record("verify.sh defines no main"); return }
        ok(!has(main, "run_check[ ]+S3\\.|check_S3_|run_check[ ]+S2\\.4|check_S2_4"), "verify.sh main runs a check of S3 or S2.4 by itself: they belong to the full run (kit-run.sh all --slice N)")
        ok(has(code, "QUICK_FLOOR=3"), "QUICK_FLOOR changed")
        ok(has(main, "\"\\$KIT_SLICE\"[ ]+-ge[ ]+3"), "the guard on KIT_SLICE for S8.10 is gone")
        ok(has(code, #"kit-run\.sh"?[ ]+all[ ]+--slice"#), "the full run no longer runs kit-run.sh all --slice")
    }

    // MARK: the recipe `golden` in the runner

    @Test("kit-run.sh shows `prep golden [--hold-start]` in its usage and keeps every other prep line")
    func usageLines() {
        guard let text = read(scriptsDir.appendingPathComponent("kit-run.sh")) else { Issue.record("scripts/kit-run.sh not found"); return }
        let usage = shellFunctions(in: stripComments(text))["usage"] ?? ""
        ok(usage.contains("kit-run.sh prep golden [--hold-start]"), "the usage lacks `kit-run.sh prep golden [--hold-start]`")
        ok(usage.contains("--hold-start"), "the usage does not explain --hold-start")
        for old in ["prep fresh-throttled", "prep photos [--no-wait] [--cache-dir <dir>]", "prep busy50k", "prep setup [--trace <name>]", "prep minimix [--no-start]", "prep tree [--trace <name>]"] {
            ok(usage.contains(old), "the usage lost `\(old)`")
        }
    }

    // plan-5-t1b (amended by the tester, reason: the entry says "The recipe `mix500` replaces `not built yet`"): mix500 leaves the list of the
    // recipes that are not built; golden-code, overlap and index50k stay on it and are still pinned. The test that mix500 is dispatched is in
    // KitRunS4ChecksTests.
    // plan-6-t1 (amended by the tester, never weakened; reason: the entry says "the recipes `golden-code` and `overlap` replace `not built yet`"):
    // golden-code and overlap have their own branches now; only index50k stays on the not-built line, which is found by its name.
    @Test("recipe_main runs recipe_golden for `golden` and no longer says `not built yet` for it; no recipe is left on a `not built yet` line (golden-code, overlap and index50k run their recipes)")
    func recipeMainDispatch() {
        guard let text = read(recipesFile).map(stripComments) else { Issue.record("scripts/kit-lib/recipes.sh not found"); return }
        let main = shellFunctions(in: text)["recipe_main"] ?? ""
        ok(!main.isEmpty, "recipes.sh has no recipe_main")
        ok(has(main, "(^|\\n)[ \\t]*golden\\)[^\\n]*recipe_golden"), "recipe_main has no `golden)` branch that runs recipe_golden")
        // plan-6-t9 (amended by the tester, never weakened; reason: the entry says `index50k` "replaces `not built yet`"): index50k has its own branch that
        // runs recipe_index50k and no recipe is left on a not-built line, so the line is gone; no built recipe may be listed on any `not built yet` line.
        let notBuilt = main.split(separator: "\n").first { $0.contains("not built yet") }.map(String.init) ?? ""
        ok(has(main, "(^|\\n)[ \\t]*index50k\\)[^\\n]*recipe_index50k"), "recipe_main has no `index50k)` branch that runs recipe_index50k")
        ok(!has(main, "golden-code") && !main.contains("recipe_golden_code"), "recipe_main still has a `golden-code)` branch or runs recipe_golden_code")
        ok(has(main, "(^|\\n)[ \\t]*overlap\\)[^\\n]*recipe_overlap"), "recipe_main has no `overlap)` branch that runs recipe_overlap")
        ok(!has(notBuilt, "golden-code") && !has(notBuilt, "overlap"), "recipe_main still lists golden-code or overlap as not built yet: \(notBuilt)")
        ok(!has(notBuilt, "(^|[ |])golden(\\||\\))"), "recipe_main still lists `golden` as not built yet: \(notBuilt)")
        ok(!has(notBuilt, "(^|[ |])mix500(\\||\\))"), "recipe_main still lists `mix500` as not built yet: \(notBuilt)")
        ok(!has(notBuilt, "(^|[ |])index50k(\\||\\))"), "recipe_main still lists `index50k` as not built yet: \(notBuilt)")
        ok(!main.contains("not built yet"), "recipe_main still has a `not built yet` line although every recipe is built")
        ok(has(main, "(^|\\n)[ \\t]*photos\\)[^\\n]*recipe_photos"), "recipe_main lost the `photos)` branch")
    }

    @Test("recipe_golden: state, models, a reset with the cached model, the three builds, the pick list, the roots check, then (hold) stop before press_start or (no hold) press_start, wait for done and Ready and mark `golden`")
    func recipeGoldenText() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["recipe_golden"] else { Issue.record("recipes.sh has no recipe_golden"); return }
        let t = substitute(fn, topLevelValues())
        before(t, "recipe_state", "recipe_reset[ ]+cache", "recipe_golden must read the starting state before it resets")
        before(t, "recipe_reset[ ]+cache", "kit-fixtures\\.sh\"?[ ]+build[ ]+golden\\b", "recipe_golden must reset before the builds")
        before(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+golden\\b", "kit-fixtures\\.sh\"?[ ]+build[ ]+golden-docs", "recipe_golden: golden before golden-docs")
        before(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+golden-docs", "kit-fixtures\\.sh\"?[ ]+build[ ]+boundary", "recipe_golden: golden-docs before boundary")
        before(t, "kit-fixtures\\.sh\"?[ ]+build[ ]+boundary", "pick_folders", "recipe_golden must build before it picks")
        ok(has(t, "models_check"), "recipe_golden does not check the model files (the recipe photos does)")
        ok(has(t, "golden_pick_list"), "recipe_golden does not take its folders from golden_pick_list")
        ok(has(t, "pick_folders[^\\n]*\\$"), "recipe_golden does not pick the list with pick_folders")
        before(t, "pick_folders", "golden_roots_check", "recipe_golden must check the picked roots after it picks")
        before(t, "golden_roots_check", "press_start", "recipe_golden must check the roots before press_start")
        ok(has(t, "--hold-start"), "recipe_golden does not read --hold-start")
        ok(has(t, "golden hold"), "recipe_golden never writes `golden hold` to run/recipe")
        ok(has(t, "run/recipe"), "recipe_golden never writes run/recipe")
        ok(!has(t, "kit-golden\\.sh"), "recipe_golden calls kit-golden.sh: the state of the S3 checks is the whole-folder state, never prepare's")
        // the hold branch leaves before press_start: the `golden hold` write sits before the press_start line, in a branch that returns
        let hold = firstIndex(t, "golden hold"), press = firstIndex(t, "press_start")
        ok(hold != nil && press != nil && hold! < press!, "the `golden hold` write is not before press_start")
        if let h = hold, let p = press {
            let between = String(t[t.index(t.startIndex, offsetBy: h)..<t.index(t.startIndex, offsetBy: p)])
            ok(has(between, "return[ ]+0"), "the hold branch does not return before press_start")
        }
        before(t, "press_start", "kit-index\\.sh\"?[ ]+wait[ ]+done", "recipe_golden: press Start before waiting for done")
        before(t, "kit-index\\.sh\"?[ ]+wait[ ]+done", "wait_menu_ready", "recipe_golden: done before the menu's Ready")
        ok(has(t, "wait_setup_window"), "recipe_golden does not wait for the setup window before it picks")
    }

    @Test("the recipe `photos` is unchanged: it still builds only golden and picks `golden golden/photos`")
    func recipePhotosUnchanged() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["recipe_photos"] else { Issue.record("recipes.sh has no recipe_photos"); return }
        ok(has(fn, #"pick_folders[ ]+golden[ ]+golden/photos"#), "recipe_photos no longer picks `golden golden/photos`")
        ok(has(fn, #"kit-fixtures\.sh"?[ ]+build[ ]+golden\b"#) && !has(fn, "golden-docs|boundary"), "recipe_photos builds more than golden")
    }

    // MARK: golden_pick_list, golden_roots_diff, golden_need (pure runs)

    private let handTable = "# folder\tsubfolders\ngolden\tphotos\ngolden-docs\tpdfs,docs\nboundary\t\n"

    @Test("golden_pick_list takes one subfolder as a second entry (golden), and adds a folder with two or none by itself (golden-docs, boundary), in table order")
    func pickList() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(handTable, dir.appendingPathComponent("hand.tsv"))
        let ran = try pure("golden_pick_list '\(dir.path)/hand.tsv'", in: dir)
        ok(ran.status == 0 && lines(ran) == ["golden", "golden/photos", "golden-docs", "boundary"], "golden_pick_list printed \(lines(ran)) (exit \(ran.status)), expected golden, golden/photos, golden-docs, boundary")
        try put("# x\nsolo\tinner\nbare\t\nthree\ta,b,c\n", dir.appendingPathComponent("other.tsv"))
        let other = try pure("golden_pick_list '\(dir.path)/other.tsv'", in: dir)
        ok(lines(other) == ["solo", "solo/inner", "bare", "three"], "golden_pick_list printed \(lines(other)) for another table, expected solo, solo/inner, bare, three")
        let missing = try pure("golden_pick_list '\(dir.path)/none.tsv'", in: dir)
        ok(missing.status != 0, "golden_pick_list of a missing table exited 0")
    }

    // plan-5-t1b (amended by the tester, reason: the recipe `golden` now also picks golden-av, the sibling folder of the 12 audio clips, the 12
    // video clips and the two damaged clips, built by `kit-fixtures.sh build golden-av`; the entry says "four roots"). The three old rows and
    // the three old pick-list entries are unchanged; one row and one entry are added. golden-av has three subfolders, so it is picked once.
    @Test("scripts/kit-lib/golden-roots.tsv is the hand-written table of the four golden folders: golden holds photos, golden-docs holds pdfs and docs, boundary holds nothing, golden-av holds audio, video and damaged")
    func realRootsTable() throws {
        guard let text = read(rootsTable) else { Issue.record("scripts/kit-lib/golden-roots.tsv not found"); return }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let want: [[String]] = [["golden", "photos"], ["golden-docs", "pdfs,docs"], ["boundary", ""], ["golden-av", "audio,video,damaged"]]
        let got = rows.map { r in [r.first ?? "", r.count > 1 ? r[1] : ""] }
        ok(got == want, "golden-roots.tsv holds \(got), expected \(want) (t2: golden has photos/, golden-docs has pdfs/ and docs/, boundary has only files; plan 5: golden-av has audio/, video/ and damaged/)")
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = try pure("golden_pick_list '\(rootsTable.path)'", in: dir)
        ok(lines(ran) == ["golden", "golden/photos", "golden-docs", "boundary", "golden-av"], "golden_pick_list of the real table printed \(lines(ran))")
    }

    @Test("golden_roots_diff compares the folders the setup window lists under the fixtures root with the pick list: nothing when equal, extra and missing named otherwise")
    func rootsDiff() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = "golden\ngolden/photos\ngolden-docs\nboundary"
        let r = "/private/var/x/fixtures"
        func diff(_ rows: [String]) throws -> Ran {
            try put(rows.joined(separator: "\n") + "\n", dir.appendingPathComponent("rows.txt"))
            try put(list + "\n", dir.appendingPathComponent("list.txt"))
            return try pure("golden_roots_diff '\(r)' \"$(cat '\(dir.path)/list.txt')\" \"$(cat '\(dir.path)/rows.txt')\"", in: dir)
        }
        let equal = try diff([r + "/golden/photos", r + "/golden-docs", r + "/boundary"])
        ok(equal.status == 0 && equal.output.isEmpty, "equal rows: exit \(equal.status), printed \(equal.output.debugDescription), expected nothing")
        let extra = try diff([r + "/golden/photos", r + "/golden-docs", r + "/golden-docs/pdfs", r + "/boundary", "/somewhere/else"])
        ok(extra.status != 0 && extra.output.contains("extra:") && extra.output.contains("golden-docs/pdfs") && !extra.output.contains("somewhere"), "an extra row: exit \(extra.status), printed \(extra.output.debugDescription), expected `extra:` naming golden-docs/pdfs and not the folder outside the fixtures root")
        let missing = try diff([r + "/golden/photos", r + "/golden-docs"])
        ok(missing.status != 0 && missing.output.contains("missing:") && missing.output.contains("boundary"), "a missing row: exit \(missing.status), printed \(missing.output.debugDescription), expected `missing:` naming boundary")
    }

    @Test("golden_roots_check reads the setup window, spells the fixtures root as the window does, and ends in exit 4 with `RERUN picked roots differ` when the list differs")
    func rootsCheckText() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["golden_roots_check"] else { Issue.record("recipes.sh has no golden_roots_check"); return }
        ok(has(fn, "setup_folders") && has(fn, "real_path") && has(fn, "golden_roots_diff"), "golden_roots_check does not read the setup window's folders (setup_folders), the real fixtures path (real_path) and compare with golden_roots_diff")
        ok(has(fn, "RERUN picked roots differ from the pick list") && has(fn, "return 4"), "golden_roots_check does not end in `RERUN picked roots differ from the pick list` and exit 4 (as tree_roots_check does)")
    }

    private func needRun(_ dir: URL, recipe: String?, args: String = "", rc: Int = 0) throws -> Ran {
        let runDir = dir.appendingPathComponent("sesame-kit-t/run")
        let f = runDir.appendingPathComponent("recipe")
        try? FileManager.default.removeItem(at: f)
        if let recipe { try put(recipe, f) }
        return try pure("golden_need \(args); echo \"rc=$?\"", in: dir,
                        extra: "recipe_golden() { echo \"RECIPE $*\"; return \(rc); }; golden_release() { echo RELEASE; return 0; }; press_start() { echo PRESS; }; kit_need_ps() { return 0; }")
    }

    @Test("golden_need does nothing when run/recipe holds `golden`; runs the recipe otherwise; releases a held start; --hold asks for a fresh held state; the recipe's status comes back")
    func needBehaviour() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let done = try needRun(dir, recipe: "golden\n")
        ok(lines(done) == ["rc=0"], "run/recipe `golden`: printed \(lines(done)), expected only rc=0 (nothing runs)")
        for (label, recipe) in [("no recipe", String?.none), ("another recipe", "tree s8\n"), ("tree with no trace", "tree -\n"), ("photos", "photos\n")] {
            let ran = try needRun(dir, recipe: recipe)
            ok(lines(ran) == ["RECIPE ", "rc=0"], "\(label): printed \(lines(ran)), expected the recipe to run with no arguments, then rc=0")
        }
        let held = try needRun(dir, recipe: "golden hold\n")
        ok(lines(held) == ["RELEASE", "rc=0"], "`golden hold` with no --hold: printed \(lines(held)), expected golden_release")
        let holdOk = try needRun(dir, recipe: "golden hold\n", args: "--hold")
        ok(lines(holdOk) == ["rc=0"], "`golden hold` with --hold: printed \(lines(holdOk)), expected nothing to run")
        for (label, recipe) in [("`golden`", String?.some("golden\n")), ("no recipe", nil)] {
            let ran = try needRun(dir, recipe: recipe, args: "--hold")
            ok(lines(ran) == ["RECIPE --hold-start", "rc=0"], "--hold with \(label): printed \(lines(ran)), expected the recipe run with --hold-start (S3.6 needs a state that stops before Start)")
        }
        let failed = try needRun(dir, recipe: nil, rc: 3)
        ok(lines(failed) == ["RECIPE ", "rc=3"], "a recipe that needs a person: printed \(lines(failed)), expected its status 3 back")
        let bad = try needRun(dir, recipe: nil, args: "--nope")
        ok(bad.output.contains("rc=2"), "an unknown option: printed \(bad.output.debugDescription), expected status 2")
    }

    @Test("golden_release presses Start, waits for done and for the menu's Ready, and only then writes `golden` to run/recipe")
    func releaseText() {
        guard let fn = shellFunctions(in: read(recipesFile).map(stripComments) ?? "")["golden_release"] else { Issue.record("recipes.sh has no golden_release"); return }
        before(fn, "press_start", "kit-index\\.sh\"?[ ]+wait[ ]+done", "golden_release: Start before done")
        before(fn, "kit-index\\.sh\"?[ ]+wait[ ]+done", "wait_menu_ready", "golden_release: done before Ready")
        before(fn, "wait_menu_ready", "run/recipe", "golden_release writes `golden` before the state is ready")
    }

    // MARK: the pure helpers of checks-s3.sh

    private let key = """
    id,group,query,file,locator,window_s,note
    pdf-01,pdf,the clause about pets in the lease,pdfs/lease-2024.pdf,7,,box=72:430:468:60; anchor=pets are allowed only with consent
    pdf-02,pdf,the policy on working from home,pdfs/employee-handbook.pdf,5,,box=72:420:468:60; anchor=employees may work from home
    doc-01,doc,my notes about when the ferry leaves the island,docs/field-notes.txt,,,anchor=the ferry leaves from pier nine at dawn
    doc-02,doc,where the tent poles are kept,docs/field-notes.md,,,anchor=the tent poles are stored under the stairs
    scanned-01,scanned,the receipt for the bicycle repair,pdfs/scanned-receipt.pdf,2,,anchor=Bicycle repair receipt
    long60-01,long60,saffron windmill ledger,pdfs/annual-report-60p.pdf,12,,unique string on page 12
    boundary-03,boundary,juniper cascade ferrule,boundary/thirty-one-pages.pdf,31,,last page of a 31 page pdf

    """

    private func keyed() throws -> URL {
        let dir = try scratch()
        try put(key, dir.appendingPathComponent("answers.csv"))
        return dir
    }

    @Test("s3_field prints one field of a key row: group, query, file, locator, and the anchor and the box of the note; nothing for a field the row lacks")
    func fieldReader() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, String, String)] = [
            ("pdf-01", "query", "the clause about pets in the lease"), ("pdf-01", "file", "pdfs/lease-2024.pdf"), ("pdf-01", "locator", "7"),
            ("pdf-01", "group", "pdf"), ("pdf-01", "anchor", "pets are allowed only with consent"), ("pdf-01", "box", "72:430:468:60"),
            ("doc-01", "anchor", "the ferry leaves from pier nine at dawn"), ("long60-01", "locator", "12"), ("boundary-03", "locator", "31"),
            ("long60-01", "anchor", ""), ("doc-01", "locator", ""), ("pdf-99", "file", ""),
        ]
        for (id, field, want) in cases {
            let ran = try pure("s3_field \(id) \(field)", in: dir)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == want, "s3_field \(id) \(field) printed \(ran.output.debugDescription), expected \(want.debugDescription)")
        }
    }

    @Test("s3_rows prints id, query, file and locator, tab separated, of every row of a key group, in key order")
    func rowsReader() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = try pure("s3_rows doc", in: dir)
        ok(lines(docs) == ["doc-01\tmy notes about when the ferry leaves the island\tdocs/field-notes.txt\t", "doc-02\twhere the tent poles are kept\tdocs/field-notes.md\t"],
           "s3_rows doc printed \(lines(docs))")
        let pdf = try pure("s3_rows pdf", in: dir)
        ok(lines(pdf) == ["pdf-01\tthe clause about pets in the lease\tpdfs/lease-2024.pdf\t7", "pdf-02\tthe policy on working from home\tpdfs/employee-handbook.pdf\t5"], "s3_rows pdf printed \(lines(pdf))")
        let none = try pure("s3_rows nothing", in: dir)
        ok(none.output.isEmpty, "s3_rows of a group with no row printed \(none.output.debugDescription)")
    }

    private let searchOut = """
    search box label="Search" value="the clause about pets in the lease"
    rows 3
    row 1 selected lease-2024.pdf | ~/Documents/Home | PDF
    row 2 - tax-return-2024.pdf | ~/Documents/Money | PDF
    row 3 - tax-return-2025-draft.pdf | ~/Documents/Money | PDF
    pane Page 7 of 12
    pane pets are allowed only with the written consent of the landlord

    """

    @Test("s3_rank_of prints the place of the first row that names a file, and nothing when none does")
    func rankOf() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (file, want) in [("lease-2024.pdf", "1"), ("tax-return-2024.pdf", "2"), ("tax-return-2025-draft.pdf", "3"), ("nothing.pdf", "")] {
            let ran = try pure("s3_rank_of \(file)", in: dir, stdin: searchOut)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == want, "s3_rank_of \(file) printed \(ran.output.debugDescription), expected \(want.debugDescription)")
        }
    }

    @Test("s3_distinct_rows prints the text of a row that appears twice, and nothing when every row is its own path")
    func distinctRows() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clean = try pure("s3_distinct_rows", in: dir, stdin: searchOut)
        ok(clean.output.isEmpty, "distinct rows printed \(clean.output.debugDescription), expected nothing")
        let twice = searchOut.replacingOccurrences(of: "row 3 - tax-return-2025-draft.pdf | ~/Documents/Money | PDF", with: "row 3 - lease-2024.pdf | ~/Documents/Home | PDF")
        let dup = try pure("s3_distinct_rows", in: dir, stdin: twice)
        ok(dup.output.contains("lease-2024.pdf"), "a row listed twice printed \(dup.output.debugDescription), expected the row text")
    }

    @Test("s3_pane_page prints `N M` from the pane's `Page N of M` and nothing when the pane has no page; s3_row_page does the same for the row that names a file")
    func pageReaders() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = try pure("s3_pane_page", in: dir, stdin: searchOut)
        ok(pane.output.trimmingCharacters(in: .whitespacesAndNewlines) == "7 12", "s3_pane_page printed \(pane.output.debugDescription), expected `7 12`")
        let longer = try pure("s3_pane_page", in: dir, stdin: "pane lease-2024.pdf · Page 7 of 12 · Documents\n")
        ok(longer.output.trimmingCharacters(in: .whitespacesAndNewlines) == "7 12", "a pane line with more text printed \(longer.output.debugDescription), expected `7 12`")
        let none = try pure("s3_pane_page", in: dir, stdin: "rows 1\nrow 1 selected a.pdf\npane nothing here\n")
        ok(none.output.isEmpty, "a pane with no page printed \(none.output.debugDescription)")
        let rows = """
        rows 2
        row 1 selected other.pdf | Page 3 of 9
        row 2 - annual-report-60p.pdf | ~/golden-docs | Page 12 of 60

        """
        let row = try pure("s3_row_page annual-report-60p.pdf", in: dir, stdin: rows)
        ok(row.output.trimmingCharacters(in: .whitespacesAndNewlines) == "12 60", "s3_row_page printed \(row.output.debugDescription), expected `12 60`")
        let absent = try pure("s3_row_page nothing.pdf", in: dir, stdin: rows)
        ok(absent.output.isEmpty, "s3_row_page of a file no row names printed \(absent.output.debugDescription)")
        let noPage = try pure("s3_row_page annual-report-60p.pdf", in: dir, stdin: "rows 1\nrow 1 selected annual-report-60p.pdf | ~/golden-docs\n")
        ok(noPage.output.isEmpty, "a row with no page printed \(noPage.output.debugDescription)")
    }

    @Test("s3_menu_state reads the status item's text: indexing, ready or unknown")
    func menuState() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (text, want) in [("status item: Sesame, Indexing 52 percent", "indexing"), ("status item: Sesame – Ready", "ready"), ("status item: Sesame", "unknown"),
                             ("status item: indexing paused", "indexing"), ("", "unknown")] {
            let ran = try pure("s3_menu_state", in: dir, stdin: text + "\n")
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == want, "s3_menu_state of \(text.debugDescription) printed \(ran.output.debugDescription), expected \(want)")
        }
    }

    @Test("s3_title_holds and s3_app_matches: the window title holds the file name (or its stem when the app hides the extension); the front app is the one Launch Services names")
    func titleAndApp() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (title, file, want) in [("window: field-notes.txt", "field-notes.txt", 0), ("window: field-notes — Edited", "field-notes.txt", 0), ("window: budget-2026.odt", "budget-2026.odt", 0),
                                    ("window: other.txt", "field-notes.txt", 1), ("window: ", "field-notes.txt", 1), ("window: field-notes-two.txt", "field-notes.txt", 1)] {
            let ran = try pure("s3_title_holds '\(title)' '\(file)'; echo $?", in: dir)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(want), "s3_title_holds \(title.debugDescription) \(file) returned \(ran.output.debugDescription), expected \(want)")
        }
        for (front, def, want) in [("TextEdit", "TextEdit", 0), ("textedit", "TextEdit", 0), ("Preview", "TextEdit", 1), ("", "TextEdit", 1), ("TextEdit", "", 1)] {
            let ran = try pure("s3_app_matches '\(front)' '\(def)'; echo $?", in: dir)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(want), "s3_app_matches \(front.debugDescription) \(def.debugDescription) returned \(ran.output.debugDescription), expected \(want)")
        }
    }

    @Test("s3_around prints the three words before and after an anchor, whatever the line breaks and the case; nothing when the anchor is not in the text")
    func around() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "alpha beta gamma The tent poles\nare stored under the stairs delta epsilon zeta eta\n"
        let ran = try pure("s3_around 'the tent poles are stored under the stairs'", in: dir, stdin: text)
        ok(lines(ran) == ["before: alpha beta gamma", "after: delta epsilon zeta"], "s3_around printed \(lines(ran)), expected before: alpha beta gamma / after: delta epsilon zeta")
        let missing = try pure("s3_around 'not in the text'; echo $?", in: dir, stdin: text)
        ok(missing.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "an anchor that is not in the text printed \(missing.output.debugDescription), expected only status 1")
        let start = try pure("s3_around 'alpha beta'", in: dir, stdin: text)
        ok(lines(start).first == "before:" || lines(start).first == "before: ", "an anchor at the start printed \(lines(start)), expected an empty before line first")
    }

    @Test("s3_source_text prints a text file as it is and converts a document with textutil; s3_words_found prints the query words of four letters or more that the pane holds")
    func sourceAndWords() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        try put("alpha beta\nthe ferry leaves from pier nine at dawn\n", dir.appendingPathComponent("docs/field-notes.txt"))
        try put("<html><body><p>The parcel was left with a neighbour</p></body></html>", dir.appendingPathComponent("docs/shipping.html"))
        let txt = try pure("s3_source_text '\(dir.path)/docs/field-notes.txt'", in: dir)
        ok(txt.output.contains("the ferry leaves from pier nine at dawn"), "s3_source_text of a txt printed \(txt.output.debugDescription)")
        let html = try pure("s3_source_text '\(dir.path)/docs/shipping.html'", in: dir)
        ok(html.status == 0 && html.output.contains("parcel was left with a neighbour") && !html.output.contains("<p>"), "s3_source_text of an html printed \(html.output.debugDescription), expected the converted text")
        let found = try pure("s3_words_found 'my notes about when the ferry leaves the island'", in: dir, stdin: "pane The Ferry leaves from pier nine at dawn\npane more\n")
        ok(lines(found) == ["ferry", "leaves"], "s3_words_found printed \(lines(found)), expected ferry and leaves (the words of four letters or more, in query order, that the pane holds)")
        let none = try pure("s3_words_found 'my notes about when'", in: dir, stdin: "pane nothing in common\n")
        ok(none.output.isEmpty, "s3_words_found printed \(none.output.debugDescription) for a pane with none of the words")
    }

    @Test("s3_unreadable lists the locked and the damaged PDF of golden-docs.tsv with the reason Settings and the index show: password-protected and damaged")
    func unreadable() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        try put("# pdf lines\npdf\tpdfs/ok.pdf\ttext\t1\tT\t-\npdf\tpdfs/locked-file.pdf\tlocked\t2\tTitle\tkit-locked-7\nvoid\tx\ny\npdf\tpdfs/cut-file.pdf\tdamaged\t1\tT\t-\npdf\tpdfs/scan.pdf\tpicture\t3\tT\t-\n", dir.appendingPathComponent("lib/golden-docs.tsv"))
        let ran = try pure("s3_unreadable", in: dir)
        ok(lines(ran) == ["pdfs/locked-file.pdf\tpassword-protected", "pdfs/cut-file.pdf\tdamaged"], "s3_unreadable printed \(lines(ran)), expected the locked and the damaged file with their reasons, in table order")
        let real = try pure("KIT_LIB='\(libDir.path)'; s3_unreadable", in: dir)
        ok(lines(real).count == 2 && lines(real).allSatisfy { $0.hasPrefix("pdfs/") } && Set(lines(real).map { $0.components(separatedBy: "\t").last ?? "" }) == ["password-protected", "damaged"],
           "s3_unreadable of the real golden-docs.tsv printed \(lines(real)), expected exactly two pdfs, one password-protected and one damaged")
    }

    @Test("s3_in_dump finds a file name and its reason together in a Settings dump (same line or within three lines); s3_reasons_hold reads `kit-index.sh reasons`")
    func settingsAndReasons() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dump = """
        AXWindow label="Sesame Settings"
          AXGroup label="Could not read"
            AXStaticText label="locked-file.pdf"
            AXStaticText label="password-protected"
            AXStaticText label="cut-file.pdf"
            AXStaticText label="somewhere"
            AXStaticText label="elsewhere"
            AXStaticText label="more"
            AXStaticText label="damaged"
          AXRow label="scan.pdf, password-protected"

        """
        for (name, reason, want) in [("locked-file.pdf", "password-protected", 0), ("scan.pdf", "password-protected", 0), ("locked-file.pdf", "damaged", 1),
                                     ("cut-file.pdf", "damaged", 1), ("absent.pdf", "damaged", 1)] {
            let ran = try pure("s3_in_dump '\(name)' '\(reason)'; echo $?", in: dir, stdin: dump)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(want), "s3_in_dump \(name) \(reason) returned \(ran.output.debugDescription), expected \(want)")
        }
        let reasons = "/var/x/fixtures/golden-docs/pdfs/locked-file.pdf\tpassword-protected\n/var/x/fixtures/golden-docs/pdfs/cut-file.pdf\tdamaged\ncould_not_read 2\n"
        for (name, reason, want) in [("locked-file.pdf", "password-protected", 0), ("cut-file.pdf", "damaged", 0), ("locked-file.pdf", "damaged", 1), ("file.pdf", "damaged", 1), ("nothing.pdf", "damaged", 1)] {
            let ran = try pure("s3_reasons_hold '\(name)' '\(reason)'; echo $?", in: dir, stdin: reasons)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == String(want), "s3_reasons_hold \(name) \(reason) returned \(ran.output.debugDescription), expected \(want)")
        }
    }

    @Test("s3_done_count sums the done files of `kit-index.sh status`, s3_listing_n reads the path count of `expect listing`, s3_not_done names every file of `kit-index.sh under` that is neither done nor exempt")
    func counts() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let status = "index: /x/index.sqlite (123 bytes)\npdf done 18\npdf could_not_read 2\nphoto done 40\ndocument done 6\nfiles 66\nwalk_done_at 123\n"
        let done = try pure("s3_done_count", in: dir, stdin: status)
        ok(done.output.trimmingCharacters(in: .whitespacesAndNewlines) == "64", "s3_done_count printed \(done.output.debugDescription), expected 64")
        let empty = try pure("s3_done_count", in: dir, stdin: "no index: /x/index.sqlite does not exist\n")
        ok(empty.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "s3_done_count of a missing index printed \(empty.output.debugDescription), expected 0")
        let listing = "pdfs/a.pdf\ndocs/b.txt\nFORMATS jpeg 1\nLISTING OK golden-docs: 26 paths\n"
        let n = try pure("s3_listing_n", in: dir, stdin: listing)
        ok(n.output.trimmingCharacters(in: .whitespacesAndNewlines) == "26", "s3_listing_n printed \(n.output.debugDescription), expected 26")
        let failed = try pure("s3_listing_n", in: dir, stdin: "LISTING FAILED golden: 2 problems\n")
        ok(failed.output.isEmpty, "s3_listing_n of a failed listing printed \(failed.output.debugDescription), expected nothing")
        let under = "/x/golden-docs/pdfs/a.pdf\tpdf\tdone\n/x/golden-docs/pdfs/locked-file.pdf\tpdf\tcould_not_read\n/x/golden-docs/pdfs/b.pdf\tpdf\tqueued\n/x/golden-docs/pdfs/c.pdf\tpdf\tpartial\n4 files under /x/golden-docs\n"
        let rest = try pure("s3_not_done locked-file.pdf", in: dir, stdin: under)
        ok(lines(rest) == ["/x/golden-docs/pdfs/b.pdf\tqueued", "/x/golden-docs/pdfs/c.pdf\tpartial"], "s3_not_done printed \(lines(rest)), expected the queued and the partial file, not the exempt one and not the footer")
    }

    @Test("s3_text_chars counts the characters that are not spaces after the `pages <n>` line of `fixturegen pdf-read`")
    func textChars() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (text, want) in [("pages 2\n\n  \n", "0"), ("pages 1\nhello world\n", "10"), ("pages 3\n", "0"), ("pages 1\nab\n\tcd  \n", "4")] {
            let ran = try pure("s3_text_chars", in: dir, stdin: text)
            ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines) == want, "s3_text_chars of \(text.debugDescription) printed \(ran.output.debugDescription), expected \(want)")
        }
    }

    @Test("s3_moved_answers writes a copy of the key with every box moved 300 points down (up when it is too low to), and changes nothing else; the key itself is never written")
    func movedAnswers() throws {
        let dir = try keyed()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = try pure("s3_moved_answers '\(dir.path)/answers.csv' '\(dir.path)/moved.csv'; echo $?", in: dir)
        ok(ran.output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("0"), "s3_moved_answers exited \(ran.output.debugDescription)")
        let moved = read(dir.appendingPathComponent("moved.csv")) ?? ""
        ok(moved.contains("box=72:130:468:60; anchor=pets are allowed only with consent"), "the lease box was not moved to y 130 with its anchor kept: \(moved.debugDescription)")
        ok(moved.contains("box=72:120:468:60; anchor=employees may work from home"), "the handbook box was not moved to y 120: \(moved.debugDescription)")
        let a = key.split(separator: "\n").map(String.init).filter { !$0.contains("box=") }
        let b = moved.split(separator: "\n").map(String.init).filter { !$0.contains("box=") }
        ok(a == b, "a row without a box changed in the moved copy")
        ok(read(dir.appendingPathComponent("answers.csv")) == key, "the key was written")
        try put("id,group,query,file,locator,window_s,note\npdf-09,pdf,q,pdfs/low.pdf,1,,box=72:100:468:60; anchor=a\n", dir.appendingPathComponent("low.csv"))
        _ = try pure("s3_moved_answers '\(dir.path)/low.csv' '\(dir.path)/low-moved.csv'", in: dir)
        ok((read(dir.appendingPathComponent("low-moved.csv")) ?? "").contains("box=72:400:468:60"), "a low box was not moved up to y 400")
    }

    // MARK: each check, as text (a check is never run here)

    @Test("every check starts with golden_need: it comes before the first kit script, search or readback of the body", arguments: allIds)
    func startsWithGoldenNeed(_ id: String) {
        guard let t = logic(id) else { return }
        guard let g = firstIndex(t, "\\bgolden_need\\b") else { ok(false, "\(id) never calls golden_need"); return }
        for other in ["kit-[a-z]+\\.sh", "\\bs1_search\\b", "\\bs1_kq\\b", "\\bkq[ ]", "\\bpick_folders\\b", "\\brecipe_golden\\b", "\\brecipe_photos\\b", "\\bs1_need_photos\\b"] {
            if let o = firstIndex(t, other) { ok(g < o, "\(id) calls `\(other)` before golden_need") }
        }
        ok(!has(t, "kit-golden\\.sh\"?[ ]+prepare|\\bs1_need_photos\\b|\\brecipe_photos\\b"), "\(id) makes the photo-only state (prepare, photos): the S3 checks start from the whole-folder state")
        if id == "S3.6" {
            ok(has(t, "golden_need[ ]+--hold"), "S3.6 must call `golden_need --hold` (it presses Start itself while the menu says Indexing)")
        } else {
            ok(!has(t, "golden_need[ ]+--hold"), "\(id) asks for a held state: only S3.6 does")
        }
    }

    @Test("each check is the wrapper `check_<id>() { s1_run <logic>; }`, so the panel and the kit window are closed on every path")
    func wrappers() {
        let all = allFunctions()
        for id in allIds {
            let name = checkFunctionName(id)
            let logicName = id == "S2.4" ? "s2c_check_4" : "s3_check_" + String(id.dropFirst(3))
            guard let body = all[name] else { Issue.record(Comment(rawValue: "\(name) not defined")); continue }
            ok(has(body, "^[ ]*s1_run[ ]+\(logicName)[ ]*;?[ ]*$"), "\(name) is `\(body)`, expected `s1_run \(logicName)`")
        }
    }

    @Test("S3.1: the lease query lists the PDF in the first 3 rows and every row is its own path; the query and the file come from the key row pdf-01")
    func s31() {
        guard let t = logic("S3.1") else { return }
        ok(has(t, "pdf-01") && has(t, "s3_field[^\\n]*(query|file)"), "S3.1 does not take the query and the file of the key row pdf-01")
        before(t, "golden_need", "s1_search", "S3.1 searches before it has a state")
        ok(has(t, "s3_rank_of") && has(t, "-le[ ]+3"), "S3.1 does not require the file in the first 3 rows")
        ok(has(t, "s3_distinct_rows"), "S3.1 does not check that every row is a distinct path")
        ok(has(t, "CHECK S3\\.1 PASS") && has(t, "CHECK S3\\.1 FAIL|s1_fail[ ]+S3\\.1"), "S3.1 lacks a PASS line or a FAIL line")
    }

    @Test("S3.2: Page 7 of M with M from pdf-pages, a pane screenshot, mark-check against the key's box; a mark-check that cannot see the page is RERUN, never a pass; --plant S3.2 moves the box and prints FAIL planted")
    func s32() {
        guard let t = logic("S3.2") else { return }
        ok(has(t, "pdf-01") && has(t, "s3_field[^\\n]*locator"), "S3.2 does not take the page from the locator of pdf-01")
        before(t, "kit-readback\\.sh\"?[ ]+pdf-pages", "mark-check", "S3.2 must count the pages before it checks the mark")
        before(t, "kit-ax\\.sh\"?[ ]+shot[^\\n]*--panel", "kit-readback\\.sh\"?[ ]+mark-check", "S3.2 must take the pane screenshot before mark-check")
        ok(has(t, "s3_pane_page"), "S3.2 does not read `Page N of M` from the pane with s3_pane_page")
        ok(has(t, "mark-check[^\\n]*\\$"), "S3.2 does not pass the shot and the pdf to mark-check")
        ok(has(t, "RERUN S3\\.2 not valid") && has(t, "return 4"), "S3.2 does not turn a mark-check that cannot see the page (exit 4) into RERUN S3.2 not valid and status 4")
        ok(has(t, "KIT_PLANT") && has(t, "s3_moved_answers") && has(t, "--answers") && has(t, "FAIL planted"), "S3.2 has no plant: with KIT_PLANT it must run mark-check against a key whose box is moved (s3_moved_answers, --answers) and print `FAIL planted`")
        ok(has(t, "CHECK S3\\.2 PASS"), "S3.2 has no PASS line")
        ok(!has(t, "(rm|mv|cp|>)[ ]+[^\\n]*fixtures/answers\\.csv"), "S3.2 writes the key")
    }

    @Test("S3.3: for each of the six doc rows the file is in the first 3, the pane holds the anchor and a query word, and the words around the anchor in the source file")
    func s33() {
        guard let t = logic("S3.3") else { return }
        ok(has(t, "s3_rows[ ]+doc"), "S3.3 does not take the six doc rows of the key (s3_rows doc)")
        ok(has(t, "s3_rank_of") && has(t, "-le[ ]+3"), "S3.3 does not require the document in the first 3 rows")
        ok(has(t, "anchor") && has(t, "s3_words_found"), "S3.3 does not check the anchor and the query's words in the pane")
        ok(has(t, "s3_source_text") && has(t, "s3_around"), "S3.3 does not read the source passage (s3_source_text, s3_around) for the text before and after the anchor")
        ok(has(t, "--select|s3_select_pane"), "S3.3 cannot read the pane of a document that is second or third")
        ok(has(t, "CHECK S3\\.3 PASS") && has(t, "CHECK S3\\.3 FAIL|s1_fail[ ]+S3\\.3"), "S3.3 lacks a PASS or a FAIL line")
    }

    @Test("S3.4: the negative control first (a plain `open -a Preview` reads page 1 by the window title, else RERUN S3.4 not valid), then Enter, Preview frontmost on the lease, the tree first and the picture second, NEEDS-A-PERSON only when neither reads")
    func s34() {
        guard let t = logic("S3.4") else { return }
        ok(has(t, "pdf-01") && has(t, "s3_field[^\\n]*(file|locator)"), "S3.4 does not take the file and the page from the key row pdf-01")
        before(t, "s3_close_preview", "open[ ]+-a[ ]+Preview", "S3.4 must close every Preview window before it opens one")
        before(t, "open[ ]+-a[ ]+Preview", "--open", "S3.4: the negative control (`open -a Preview` at page 1) must come before the real open")
        // amended in plan-4-kit-repair-1: the control used to be read by picture only. Live, the picture reading cannot tell the near-identical
        // lease pages apart (page 1 0.950, pages 3 and 11 0.980) and Preview's title already says `Page 1 of 12`, so the control is read by the
        // title (preview-page with no flag, the same call the real open uses) first; the picture is only the fallback when the tree lacks the page.
        let controlPart = t.components(separatedBy: "--open").first ?? ""
        let controlCalls = controlPart.components(separatedBy: "open -a Preview").dropFirst().joined(separator: "\n").split(separator: "\n").map(String.init).filter { $0.contains("preview-page") }
        ok(controlCalls.first.map { !$0.contains("--by-picture") } ?? false, "S3.4: the control (Preview opened at page 1) must be read first by preview-page with no flag (the window title), not by picture: \(controlCalls)")
        ok(has(controlPart, "page 1 via tree"), "S3.4: the control must accept `page 1 via tree` (the title reading)")
        let afterOpen = t.components(separatedBy: "--open").dropFirst().joined(separator: "--open")
        let calls = afterOpen.split(separator: "\n").map(String.init).filter { $0.contains("preview-page") }
        ok(calls.count >= 2, "S3.4 calls preview-page \(calls.count) times after the Enter, expected the tree reading and the picture reading")
        if calls.count >= 2 {
            ok(!calls[0].contains("--by-picture") && calls.dropFirst().contains { $0.contains("--by-picture") }, "S3.4 reads the tree first (preview-page with no flag) and the picture second (--by-picture): \(calls)")
        }
        ok(has(t, "kit-readback\\.sh\"?[ ]+frontmost|s1_wait_front[ ]+Preview"), "S3.4 does not read that Preview is frontmost")
        ok(has(t, "RERUN S3\\.4 not valid") && has(t, "return 4"), "S3.4 has no `RERUN S3.4 not valid` for a control that does not read page 1")
        ok(has(t, "NEEDS-A-PERSON") && has(t, "S3\\.N2|where Preview"), "S3.4 has no NEEDS-A-PERSON line (S3.N2) for the case that neither reading works")
        ok(has(t, "CHECK S3\\.4 PASS") && has(t, "CHECK S3\\.4 FAIL|s1_fail[ ]+S3\\.4"), "S3.4 lacks a PASS or a FAIL line")
        ok(has(t, "\\blease|window:|s3_title_holds"), "S3.4 does not read the file name in Preview's front window")
    }

    @Test("S3.5: for each of the six documents Enter puts the app that Launch Services names for the extension in front, with the file name in the window title")
    func s35() {
        guard let t = logic("S3.5") else { return }
        ok(has(t, "s3_rows[ ]+doc"), "S3.5 does not take the six doc rows of the key")
        ok(has(t, "--open"), "S3.5 does not press Enter on the result")
        ok(has(t, "kit-readback\\.sh\"?[ ]+default-app") && has(t, "kit-readback\\.sh\"?[ ]+frontmost|s1_wait_front|s1_rbp"), "S3.5 does not compare the frontmost app with default-app <ext>")
        ok(has(t, "s3_app_matches") && has(t, "s3_title_holds"), "S3.5 does not compare with s3_app_matches and s3_title_holds")
        ok(has(t, "s3_rank_of") && has(t, "--select"), "S3.5 does not find the right row of each document (--select N)")
        before(t, "--open", "s3_title_holds", "S3.5 reads the title before it opens")
        ok(has(t, "CHECK S3\\.5 PASS") && has(t, "CHECK S3\\.5 FAIL|s1_fail[ ]+S3\\.5"), "S3.5 lacks a PASS or a FAIL line")
    }

    @Test("S3.6: golden_need --hold, a positive control (page 12 found by --wait-for within 1800 s) while the menu says Indexing read before and after, no row for page 55 at that moment, then done, Ready and page 55; a missed window is RERUN; the steps are timed")
    func s36() {
        guard let t = logic("S3.6") else { return }
        ok(has(t, "long60-01") && has(t, "long60-02") && has(t, "s3_field"), "S3.6 does not take the page 12 and page 55 strings from the key rows long60-01 and long60-02")
        before(t, "golden_need[ ]+--hold", "press_start", "S3.6 must hold the state before it presses Start")
        before(t, "press_start", "--wait-for", "S3.6 must press Start before it waits for the page 12 string")
        ok(has(t, "--within[ ]+1800"), "S3.6 does not wait up to 1800 s for the page 12 string")
        ok(has(t, "kit-ax\\.sh\"?[ ]+read[ ]+menubar") && has(t, "s3_menu_state"), "S3.6 does not read the menu bar status (kit-ax.sh read menubar, s3_menu_state)")
        // the menu is read before and after the search
        let menus = t.components(separatedBy: "read menubar").count - 1
        ok(menus >= 2, "S3.6 reads the menu bar \(menus) times, expected before and after the page 12 search")
        before(t, "--within[ ]+1800", "s3_row_page", "S3.6 reads the page of the row after the page 12 find")
        ok(has(t, "RERUN S3\\.6 not valid") && has(t, "return 4"), "S3.6 does not make a window that was missed (the menu already says Ready) a RERUN")
        before(t, "--within[ ]+1800", "kit-index\\.sh\"?[ ]+wait[ ]+done[ ]+7200", "S3.6: the page 55 absence is read before done")
        before(t, "kit-index\\.sh\"?[ ]+wait[ ]+done[ ]+7200", "--within[ ]+60", "S3.6: page 55 is searched after done")
        ok(has(t, "wait_menu_ready"), "S3.6 does not wait for the menu to say Ready before page 55")
        ok(has(t, "run/recipe"), "S3.6 does not write run/recipe `golden` once indexing is done, so the next check does not rebuild")
        ok(has(t, "timeline|date \\+%s|SECONDS"), "S3.6 saves no timestamps of its steps")
        ok(has(t, "Page[ ]+\\$|55|s3_row_page"), "S3.6 does not read the page of a row")
        ok(has(t, "CHECK S3\\.6 PASS") && has(t, "CHECK S3\\.6 FAIL|s1_fail[ ]+S3\\.6"), "S3.6 lacks a PASS or a FAIL line")
    }

    @Test("S3.7: the scanned row's query lists the scanned PDF in the first 3 with the key's page in the pane, and the file has no text layer")
    func s37() {
        guard let t = logic("S3.7") else { return }
        ok(has(t, "scanned-01") && has(t, "s3_field"), "S3.7 does not take the row scanned-01 of the key")
        ok(has(t, "s3_rank_of") && has(t, "-le[ ]+3"), "S3.7 does not require the scanned PDF in the first 3 rows")
        ok(has(t, "s3_pane_page") && has(t, "locator"), "S3.7 does not compare the pane's page with the key's locator")
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+expect[ ]+listing") , "S3.7 does not confirm the file with `kit-fixtures.sh expect listing`")
        ok(has(t, "pdf-read") && has(t, "s3_text_chars"), "S3.7 does not confirm that the file has no text layer (fixturegen pdf-read, s3_text_chars)")
        ok(has(t, "CHECK S3\\.7 PASS") && has(t, "CHECK S3\\.7 FAIL|s1_fail[ ]+S3\\.7"), "S3.7 lacks a PASS or a FAIL line")
    }

    @Test("S3.8: Settings lists both unreadable PDFs with their reasons, kit-index.sh reasons says the same, every other golden file is done, the done count equals the readable files of the three listings, and the menu says Ready")
    func s38() {
        guard let t = logic("S3.8") else { return }
        ok(has(t, "s3_unreadable"), "S3.8 does not take the two unreadable files from golden-docs.tsv (s3_unreadable)")
        ok(has(t, "s8c_settings_open") && has(t, "s8c_section_dump") && has(t, "s3_in_dump"), "S3.8 does not read the Settings list in every section (s8c_settings_open, s8c_section_dump, s3_in_dump)")
        ok(has(t, "kit-index\\.sh\"?[ ]+reasons") && has(t, "s3_reasons_hold"), "S3.8 does not read `kit-index.sh reasons`")
        ok(has(t, "kit-index\\.sh\"?[ ]+status") && has(t, "s3_done_count"), "S3.8 does not read `kit-index.sh status`")
        ok(has(t, "kit-fixtures\\.sh\"?[ ]+expect[ ]+listing") && has(t, "s3_listing_n"), "S3.8 does not count the readable files with `kit-fixtures.sh expect listing`")
        ok(has(t, "s3_not_done") && has(t, "kit-index\\.sh\"?[ ]+under"), "S3.8 does not name a golden file that is not done (kit-index.sh under, s3_not_done)")
        ok(has(t, "golden-docs") && has(t, "boundary") && has(t, "\\bgolden\\b"), "S3.8 does not count the three roots golden, golden-docs and boundary")
        ok(has(t, "wait_menu_ready|read[ ]+menubar"), "S3.8 does not read that the menu says Ready")
        ok(has(t, "CHECK S3\\.8 PASS") && has(t, "CHECK S3\\.8 FAIL|s1_fail[ ]+S3\\.8"), "S3.8 lacks a PASS or a FAIL line")
    }

    @Test("S3.9: both listed PDF apps are asked for (Acrobat, Skim); (a) an absent one chosen shows `not installed` and Enter opens the default PDF app, (b) an installed one chosen shows none; `S3.9 (b) NOT RUN` when none is installed; both installed makes (a) NEEDS-A-PERSON")
    func s39() {
        guard let t = logic("S3.9") else { return }
        ok(has(t, "kit-readback\\.sh\"?[ ]+app-installed[^\\n]*(com\\.adobe\\.Reader|\\$)") && t.contains("com.adobe.Reader") && t.contains("net.sourceforge.skim-app.skim"), "S3.9 does not ask app-installed for com.adobe.Reader and net.sourceforge.skim-app.skim")
        ok(t.contains("S3.9 (b) NOT RUN: no listed PDF app other than Preview is installed"), "S3.9 lacks the exact line `S3.9 (b) NOT RUN: no listed PDF app other than Preview is installed`")
        ok(has(t, "not installed"), "S3.9 does not read Settings' `not installed` message")
        ok(has(t, "kit-readback\\.sh\"?[ ]+default-app[ ]+pdf") && has(t, "kit-readback\\.sh\"?[ ]+frontmost|s1_wait_front"), "S3.9 does not compare the frontmost app with `default-app pdf`")
        ok(has(t, "--open"), "S3.9 does not press Enter on a PDF result")
        ok(has(t, "NEEDS-A-PERSON"), "S3.9 has no NEEDS-A-PERSON line (both apps installed, or the Settings choice cannot be driven)")
        ok(has(t, "dump[ ]+settings|s8c_section_dump|settings_section"), "S3.9 does not read Settings")
        ok(has(t, "CHECK S3\\.9 PASS") && has(t, "CHECK S3\\.9 FAIL|s1_fail[ ]+S3\\.9"), "S3.9 lacks a PASS or a FAIL line")
    }

    @Test("S3.10: for the three boundary rows each string finds its PDF and names its last page (1, 30, 31), including the 31-page file")
    func s310() {
        guard let t = logic("S3.10") else { return }
        ok(has(t, "s3_rows[ ]+boundary"), "S3.10 does not take the three boundary rows of the key")
        ok(has(t, "s3_rank_of") && has(t, "s3_pane_page|s3_row_page"), "S3.10 does not find the PDF and read its page")
        ok(has(t, "locator|\\$last|\\$loc"), "S3.10 does not compare the page with the key's locator")
        ok(has(t, "CHECK S3\\.10 PASS") && has(t, "CHECK S3\\.10 FAIL|s1_fail[ ]+S3\\.10"), "S3.10 lacks a PASS or a FAIL line")
    }

    @Test("S2.4: the panel run of group c first, the engine run last, the recipe mark dropped after the engine (its whole-folder prepare resets the kit), never prepare of group a and b")
    func s24() {
        guard let t = logic("S2.4") else { return }
        before(t, "kit-golden\\.sh\"?[ ]+panel[ ]+--group[ ]+c", "kit-golden\\.sh\"?[ ]+engine[ ]+--group[ ]+c", "S2.4: the panel run must come before the engine run (the engine's prepare --whole resets the kit)")
        let enginePos = firstIndex(t, "kit-golden\\.sh\"?[ ]+engine[ ]+--group[ ]+c"), dropPos = firstIndex(t, "rm[ ]+-f[ ]+[^\\n]*run/recipe")
        ok(enginePos != nil && dropPos != nil && dropPos! > enginePos!, "S2.4 does not drop run/recipe after the engine run: the next S3 check would trust a reset kit")
        ok(!has(t, "kit-golden\\.sh\"?[ ]+prepare"), "S2.4 calls kit-golden.sh prepare itself")
        ok(has(t, "golden_score_c|golden_line_c_summary"), "S2.4 does not score group c with golden_score_c or golden_line_c_summary")
        ok(has(t, "RERUN S2\\.4 not valid"), "S2.4 has no `RERUN S2.4 not valid`")
        ok(has(t, "CHECK S2\\.4 PASS") && has(t, "CHECK S2\\.4 FAIL"), "S2.4 lacks a PASS or a FAIL line")
        ok(has(t, "golden-panel\\.tsv") && has(t, "golden-engine\\.tsv"), "S2.4 does not read golden-panel.tsv and golden-engine.tsv")
    }

    // MARK: the recipe photos' state and the golden tests are not reached by anything here

    @Test("no new check function starts the app itself: only the recipe does; no check writes the key or a fixture")
    func noDirectLaunch() {
        let all = allFunctions()
        for id in allIds {
            guard let t = logic(id) else { continue }
            ok(!has(t, "kit-launch\\.sh\"?[ ]+(start|relaunch|quit|stop)|kit-reset\\.sh|killall|pkill|\\bsudo\\b|ask-admin"), "\(id) starts, stops or resets the app, or asks for an administrator session")
            ok(!has(t, "kit-trace\\.sh|kit-net\\.sh|s8_net_summary"), "\(id) reads a trace: it would be an administrator id")
        }
        ok(all["s3_close_preview"] != nil, "checks-s3.sh has no s3_close_preview (S3.4 closes Preview's windows before each open: feature map, Gotchas)")
        if let c = all["s3_close_preview"] {
            ok(has(c, "osascript") && c.contains("com.apple.Preview") && has(c, "close"), "s3_close_preview does not close Preview's windows by an Apple Event to com.apple.Preview")
            ok(!has(c, "quit|killall|keystroke"), "s3_close_preview quits Preview or posts keys")
        }
    }
}

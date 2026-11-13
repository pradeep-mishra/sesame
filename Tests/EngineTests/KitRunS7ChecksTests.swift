import Foundation
import Testing

// plan-2-t12, tester step: kit part 8, the S7 checks (scripts/kit-lib/checks-*.sh, scripts/kit-lib/checks.tsv,
// scripts/kit-run.sh). Written from verify.md, the S7 feature map, the design and the plan-2-t12 entry only; no
// product source is read, and no kit function may read `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions; the person's ruling "no app launch"): `kit-run.sh` drives the app,
// so NOTHING here executes it, not even with no mode. The runs are `bash -n` on the files. Every other check reads the
// text of the scripts, with their comment lines removed (a comment never satisfies a check), and reads a check function
// as the shell would run it: every call of a function of the kit is replaced, in place, by that function's own code, and
// every simple top-level variable (S7_AX="$KIT_SCRIPTS/kit-ax.sh") by its value. Real behaviour is driven against the
// live app at the accept stage only (blocks C and D).
//
// The contract read here (plan-2-t12, Tests, and the feature map S7):
//   - checks.tsv registers S7.1 to S7.18 at slice 2, S7.4 and S7.18 `auto-or-person`, the rest `auto`; each id has
//     exactly one function check_S7_<n>;
//   - each function holds the contract of the feature map S7 (see the tests below, one per id);
//   - a check that needs indexing in progress re-arms it through steps a person has (Delete index, Start indexing),
//     and the kit never edits settings.json or the index to reach a state;
//   - the battery pause and "Resume anyway, on battery" print `NEEDS A PERSON` lines and are never passed;
//   - typing goes through kit-ax.sh with KIT_TYPE_DELAY_MS honoured; every sudo is `sudo -n`; no function reads `Sources/`.
// Red before the kit part: the ids S7.1 to S7.18 have no function.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

private let allIds = (1...18).map { "S7.\($0)" }
private let personIds: Set<String> = ["S7.4", "S7.18"]
/// The checks that need indexing in progress (the map: S7.2, S7.3, S7.4, S7.5, S7.10, S7.12, S7.17, and S7.1's Indexing state).
private let inProgressIds = ["S7.1", "S7.2", "S7.3", "S7.4", "S7.5", "S7.10", "S7.12", "S7.17"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs a program that is not a kit script (`/bin/bash -n`).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun7-out-" + UUID().uuidString)
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

/// How many times the pattern matches.
private func count(_ text: String, _ pattern: String) -> Int {
    (try? NSRegularExpression(pattern: pattern))?
        .numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
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

/// The check as the wrapper runs it: `check_S7_n() { s7_run s7_check_n; }` runs the function it names last, so this is that
/// function's code with the helpers written in and no wrapper or cleanup text in front of it. Orders of calls are read here,
/// because the cleanup of the wrapper names `kit-load.sh stop`, `kit-power.sh restore` and the like before the body does.
private func inner(_ id: String) -> String? {
    guard let body = allFunctions()[checkFunctionName(id)] else {
        Issue.record(Comment(rawValue: "\(checkFunctionName(id)) is not defined in scripts/kit-run.sh or scripts/kit-lib/*.sh"))
        return nil
    }
    guard let name = body.split(whereSeparator: { " ;".contains($0) }).last.map(String.init), !name.isEmpty else {
        Issue.record(Comment(rawValue: "\(checkFunctionName(id)) calls no function that holds the check"))
        return nil
    }
    return contract(of: name)
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

// Patterns of a call of a kit script, as the check text holds it after the variables are written in.
private func ax(_ args: String) -> String { "kit-ax\\.sh\"?[ ]+\(args)" }
// Commit 080db8e: most presses are now `s6_press "$S7_AX" "<label>"`, which is the same click with kit-ax's failure output
// printed; the rest stay a bare `kit-ax.sh click "<label>"`. A press is either spelling, so every pin, positive or negative, follows both.
private func click(_ label: String) -> String {
    let l = NSRegularExpression.escapedPattern(for: label)
    return "(?:" + ax("click[ ]+\"\(l)\"") + "|s6_press[ ]+\"?[^ \"]*kit-ax\\.sh\"?[ ]+\"\(l)\")"
}
private func index(_ args: String) -> String { "kit-index\\.sh\"?[ ]+\(args)" }
private func fixtures(_ args: String) -> String { "kit-fixtures\\.sh\"?[ ]+\(args)" }
private func launch(_ args: String) -> String { "kit-launch\\.sh\"?[ ]+\(args)" }
private func load(_ args: String) -> String { "kit-load\\.sh\"?[ ]+\(args)" }
private func power(_ args: String) -> String { "kit-power\\.sh\"?[ ]+\(args)" }
private func volume(_ args: String) -> String { "kit-volume\\.sh\"?[ ]+\(args)" }
private func privacy(_ args: String) -> String { "kit-privacy\\.sh\"?[ ]+\(args)" }
private func search(_ args: String) -> String { "kit-search\\.sh\"?[ ]+\(args)" }

@Suite("KitRunS7ChecksTests")
struct KitRunS7ChecksTests {

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

    @Test("checks.tsv registers S7.1 to S7.18 at slice 2: S7.4 and S7.18 auto-or-person, the rest auto, nothing twice", arguments: allIds)
    func registeredAtSlice2(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            let kind = personIds.contains(id) ? "auto-or-person" : "auto"
            ok(row.slice == "2", "\(id) is registered at slice \(row.slice), expected 2")
            ok(row.kind == kind, "\(id) has kind \(row.kind), expected \(kind) (verify.md: only S7.4 and S7.18 of slice 2 are auto-or-person)")
        }
    }

    @Test("checks.tsv holds no S7 id beyond S7.18 and no id twice")
    func noStrayRows() {
        guard let rows = tsvRows() else { return }
        let s7 = rows.map(\.id).filter { $0.hasPrefix("S7.") }
        ok(Set(s7) == Set(allIds), "checks.tsv registers \(s7.sorted()) for S7, expected exactly S7.1 to S7.18")
        let ids = rows.map(\.id)
        ok(Set(ids).count == ids.count, "checks.tsv registers an id twice")
    }

    @Test("every S7 id has exactly one check function in the check files", arguments: allIds)
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
    }

    // MARK: S7.1

    @Test("S7.1: the label names Downloading, Indexing, Paused by you and Ready; the menu's first lines, Pause or Resume, per-kind counts, percent, and no \"Last indexed\" line (the person removed it, guide 19); and Ready reads no Pause item at all, absent and not disabled, because the person chose the tidy menu (guide 14.1) and a Pause that cannot be used is no longer drawn")
    func s71() {
        guard let t = check("S7.1") else { return }
        let l = t.lowercased()
        ok(has(t, ax("read[ ]+menubar")), "S7.1 never reads the status item's label (`kit-ax.sh read menubar`)")
        ok(has(t, ax("dump[ ]+menu")), "S7.1 never reads the open menu (`kit-ax.sh dump menu`)")
        for label in ["sesame: ready", "sesame: indexing", "sesame: paused", "sesame: downloading"] {
            ok(l.contains(label), "S7.1 does not know the mockup label \"\(label)\"")
        }
        ok(l.contains("empty"), "S7.1 does not say that an empty label is a failure")
        ok(l.contains("noted"), "S7.1 does not say that a different wording is `noted`, not a failure")
        ok(has(t, "recipe_fresh_throttled"), "S7.1 does not reach Downloading from the throttled model (`recipe_fresh_throttled`)")
        ok(has(t, click("Pause indexing")), "S7.1 never presses \"Pause indexing\" (the counts are read while paused so they are stable)")
        ok(has(t, click("Resume indexing")), "S7.1 never presses \"Resume indexing\" (the Paused by you state, then back)")
        ok(has(t, "\\[ \"\\$item\" = absent \\] \\|\\| s7_why \"Ready: the Pause item is"), "S7.1 never requires the Pause item of the Ready menu to read absent: the tidy menu draws no Pause when there is nothing to pause (guide 14.1)")
        ok(!has(t, "\\[ \"\\$item\" = disabled \\]"), "S7.1 still requires a disabled Pause when Ready (mockup F2): a greyed item is gone from the tidy menu")
        ok(t.contains("no Pause item when Ready"), "the PASS text of S7.1 does not say \"no Pause item when Ready\"")
        ok(!t.contains("a disabled Pause"), "the PASS text of S7.1 still names a disabled Pause")
        ok(has(t, index("status")), "S7.1 never reads the done count per kind (`kit-index.sh status`)")
        ok(has(t, fixtures("expect[ ]+counts")), "S7.1 does not take the files known and the per-kind counts from `kit-fixtures.sh expect counts`")
        ok(l.contains("ready") && has(l, "expect[ ]+counts"), "S7.1 does not compare the menu's counts with expect counts at Ready")
        ok(t.contains("s7_check_no_last \"Paused by you\""), "S7.1 does not read the Paused by you menu for a \"Last indexed\" line with s7_check_no_last")
        ok(t.contains("s7_check_no_last \"Ready\""), "S7.1 does not read the Ready menu for a \"Last indexed\" line with s7_check_no_last")
        ok(!t.contains("s7_check_last"), "S7.1 still calls s7_check_last, which required a \"Last indexed\" line the person removed (guide 19)")
        ok(!has(t, index("has")), "S7.1 still looks up the last file read with `kit-index.sh has`; the menu has no such line (guide 19)")
        ok(!has(t, "s7_paths_under[ ]+minimix[ ]+done"), "S7.1 still looks for the last file among the done rows of the index; the menu has no such line (guide 19)")
        ok(!t.contains("the menu has no \"Last indexed\" line"), "S7.1 still fails a menu that has no \"Last indexed\" line (guide 19)")
        ok(!t.contains("Last indexed named a done row"), "the PASS text of S7.1 still says \"Last indexed named a done row\"")
        ok(l.contains("percent"), "S7.1 never looks at the percent")
        ok(l.contains("left"), "S7.1 never looks at the line with files left and time left")
        ok(has(t, "within 1 point|within 1 "), "S7.1 does not hold the percent to within 1 point of files done over the expect counts total")
        ok(t.contains("Open Sesame"), "S7.1 never looks at the item \"Open Sesame\"")
        ok(has(t, click("Open Sesame")), "S7.1 never presses \"Open Sesame\" when the menu has it")
        ok(has(t, ax("dump[ ]+panel")), "S7.1 does not read the panel after \"Open Sesame\" (`kit-ax.sh dump panel`)")
        for shot in ["s7-menu-indexing", "s7-menu-paused", "s7-menu-ready"] {
            ok(t.contains(shot), "S7.1 saves no screenshot \(shot) for the person")
        }
        ok(has(t, ax("shot")), "S7.1 takes no screenshot (`kit-ax.sh shot`)")
        ok(has(t, "printf '%s' \"(?:\\$S7_MENU)?\" \\| tr 'A-Z' 'a-z'\\)\" in \\*left\\*"), "S7.1 does not read the files-left line from the whole dump text of the menu, where the header group's label holds it")
        ok(has(t, "s7_percent \"(?:\\$S7_MENU)?\""), "S7.1 does not read the percent from the whole dump text of the menu, where the header group's label holds it")
    }

    @Test("S7.1 reads the percent, the files-left line, the per-kind counts and the Pause, Resume and absent reads from the dump text of the tidy menu, where the percent and the files-left line are only in the label of the header group (guide 14.5), and a Ready menu with no Pause reads absent while the old greyed Pause reads disabled")
    func s71ReadsTheTidyMenuDump() throws {
        let indexing = """
        AXMenu
          AXMenuItem label="Indexing" [disabled]
            AXGroup label="Indexing 62%, 4,520 files left · about 12 min left"
          AXMenuItem [disabled]
          AXMenuItem label="Pause indexing"
          AXMenuItem [disabled]
          AXMenuItem label="Photos: 42" [disabled]
          AXMenuItem label="PDFs: 21" [disabled]
          AXMenuItem label="Documents: 7" [disabled]
          AXMenuItem label="Audio: 12" [disabled]
          AXMenuItem label="Video: 12" [disabled]
          AXMenuItem [disabled]
          AXMenuItem label="Open Sesame"
          AXMenuItem label="Settings…"
          AXMenuItem [disabled]
          AXMenuItem label="Quit Sesame"

        """
        let paused = indexing.replacingOccurrences(of: "Indexing 62%, 4,520 files left · about 12 min left", with: "Paused, By you").replacingOccurrences(of: "label=\"Pause indexing\"", with: "label=\"Resume indexing\"")
        let ready = indexing.replacingOccurrences(of: "Indexing 62%, 4,520 files left · about 12 min left", with: "Ready").replacingOccurrences(of: "  AXMenuItem label=\"Pause indexing\"\n  AXMenuItem [disabled]\n", with: "")
        let greyed = ready.replacingOccurrences(of: "  AXMenuItem label=\"Photos: 42\"", with: "  AXMenuItem label=\"Pause indexing\" [disabled]\n  AXMenuItem [disabled]\n  AXMenuItem label=\"Photos: 42\"")
        let dir = try KC.tempDir("kit-s71-")
        for (name, text) in [("indexing", indexing), ("paused", paused), ("ready", ready), ("greyed", greyed)] { try KC.write(dir + "/\(name).txt", text) }
        let kit = try KC.kitRoot()
        let r = try KC.bash("""
        for w in indexing paused ready greyed; do
          S7_MENU="$(cat "\(dir)/$w.txt")"
          echo "$w pct=$(s7_percent "$S7_MENU") left=$(printf '%s' "$S7_MENU" | tr 'A-Z' 'a-z' | grep -c 'files left') pause=$(s7_item "Pause indexing") resume=$(s7_item "Resume indexing") counts=$(s7_menu_counts | tr '\\n' ',') last=$(s7_last_indexed)"
        done
        """, kit: kit)
        let counts = "audio 12,document 7,pdf 21,photo 42,video 12,"
        var got: [String: String] = [:]
        for l in KC.lines(r.output) {
            guard let sp = l.firstIndex(of: " ") else { continue }
            got[String(l[..<sp])] = String(l[l.index(after: sp)...])
        }
        ok(got["indexing"] == "pct=62 left=1 pause=enabled resume=absent counts=\(counts) last=", "the Indexing menu reads \(got["indexing"] ?? r.output)")
        ok(got["paused"] == "pct= left=0 pause=absent resume=enabled counts=\(counts) last=", "the Paused by you menu reads \(got["paused"] ?? r.output)")
        ok(got["ready"] == "pct= left=0 pause=absent resume=absent counts=\(counts) last=", "the Ready menu reads \(got["ready"] ?? r.output)")
        ok(got["greyed"] == "pct= left=0 pause=disabled resume=absent counts=\(counts) last=", "the old greyed Pause reads \(got["greyed"] ?? r.output): S7.1 must tell it from the absent one")
    }

    private static func s71MenuWorlds(lastLine: String?) -> [(name: String, text: String)] {
        func menu(_ header: String, _ action: String?) -> String {
            var lines = ["AXMenu", "  AXMenuItem label=\"\(header)\" [disabled]", "  AXMenuItem [disabled]"]
            if let action { lines.append("  AXMenuItem label=\"\(action)\"") }
            lines += ["  AXMenuItem [disabled]", "  AXMenuItem label=\"Photos: 42\" [disabled]", "  AXMenuItem label=\"PDFs: 21\" [disabled]",
                      "  AXMenuItem label=\"Documents: 7\" [disabled]", "  AXMenuItem label=\"Audio: 12\" [disabled]", "  AXMenuItem label=\"Video: 12\" [disabled]"]
            if let lastLine { lines.append("  AXMenuItem label=\"\(lastLine)\" [disabled]") }
            lines += ["  AXMenuItem [disabled]", "  AXMenuItem label=\"Open Sesame\"", "  AXMenuItem label=\"Settings…\"", "  AXMenuItem [disabled]", "  AXMenuItem label=\"Quit Sesame\"", ""]
            return lines.joined(separator: "\n")
        }
        return [("paused", menu("Paused, By you", "Resume indexing")), ("ready", menu("Ready", nil))]
    }

    private func s71NoLastRun(lastLine: String?) throws -> [String: String] {
        let dir = try KC.tempDir("kit-s71-nolast-")
        let worlds = Self.s71MenuWorlds(lastLine: lastLine)
        for (name, text) in worlds { try KC.write(dir + "/\(name).txt", text) }
        let kit = try KC.kitRoot()
        let r = try KC.bash("""
        for w in paused ready; do
          what="Paused by you"; [ "$w" = ready ] && what="Ready"
          S7_WHY=""; S7_MENU="$(cat "\(dir)/$w.txt")"
          s7_check_no_last "$what"; rc=$?
          verdict="$(s7_done S7.1 "pass text")"; vrc=$?
          echo "$w rc=$rc vrc=$vrc why=$S7_WHY verdict=$verdict"
        done
        """, kit: kit)
        var got: [String: String] = [:]
        for l in KC.lines(r.output) {
            guard let sp = l.firstIndex(of: " ") else { continue }
            got[String(l[..<sp])] = String(l[l.index(after: sp)...])
        }
        return got
    }

    @Test("S7.1 passes the Paused by you and Ready menus that have no \"Last indexed\" line: the person removed the row (guide 19), so its absence is not a defect")
    func s71PassesAMenuWithoutLastIndexed() throws {
        let got = try s71NoLastRun(lastLine: nil)
        for name in ["paused", "ready"] {
            ok(got[name] == "rc=0 vrc=0 why= verdict=CHECK S7.1 PASS pass text", "the \(name) menu with no Last indexed line reads \(got[name] ?? "nothing")")
        }
    }

    @Test("S7.1 fails a Paused by you menu and a Ready menu that still hold \"Last indexed: annual-report-60p.pdf\", naming \"Last indexed\" and guide 19: the row was removed because a long file name widens the menu")
    func s71FailsAMenuThatHasLastIndexed() throws {
        let got = try s71NoLastRun(lastLine: "Last indexed: annual-report-60p.pdf")
        let reasons = [
            "paused": "Paused by you: the menu has a \"Last indexed\" line (annual-report-60p.pdf); the person removed it because a long file name widens the menu (guide 19)",
            "ready": "Ready: the menu has a \"Last indexed\" line (annual-report-60p.pdf); the person removed it because a long file name widens the menu (guide 19)",
        ]
        for name in ["paused", "ready"] {
            let reason = reasons[name]!
            ok(got[name] == "rc=1 vrc=1 why=\(reason) verdict=CHECK S7.1 FAIL \(reason)", "the \(name) menu with a Last indexed line reads \(got[name] ?? "nothing")")
        }
    }

    @Test("S7.1 fails a menu whose \"Last indexed\" line has no file name, and one whose line is in other letters, because the row is gone for good (guide 19)")
    func s71FailsABareOrOtherCaseLastIndexedLine() throws {
        for line in ["Last indexed", "LAST INDEXED: none yet"] {
            let got = try s71NoLastRun(lastLine: line)
            for name in ["paused", "ready"] {
                ok(got[name]?.contains("rc=1 vrc=1") == true && got[name]?.contains("the menu has a \"Last indexed\" line") == true && got[name]?.contains("(guide 19)") == true,
                   "the \(name) menu with the line \"\(line)\" reads \(got[name] ?? "nothing")")
            }
        }
    }

    @Test("S7.1 still does not read a stray \"Last indexed\" line as a count, so a planted line cannot move a per-kind count")
    func s71StrayLastIndexedLineIsNoCount() throws {
        let dir = try KC.tempDir("kit-s71-stray-")
        try KC.write(dir + "/m.txt", Self.s71MenuWorlds(lastLine: "Last indexed: photos-7.pdf").first!.text)
        let kit = try KC.kitRoot()
        let r = try KC.bash("S7_MENU=\"$(cat \"\(dir)/m.txt\")\"; echo \"counts=$(s7_menu_counts | tr '\\n' ',')\"", kit: kit)
        ok(r.output.contains("counts=audio 12,document 7,pdf 21,photo 42,video 12,"), "the counts of a menu with a stray Last indexed line read \(r.output)")
    }

    // MARK: S7.2

    @Test("S7.2: Pause at T0, done count and passages stop by T0 plus 5 s and stay constant 20 s, Resume continues, files-only snapshot equal")
    func s72() {
        guard let t = inner("S7.2") else { return }
        ok(has(t, click("Pause indexing")), "S7.2 never presses \"Pause indexing\"")
        ok(has(t, click("Resume indexing")), "S7.2 never presses \"Resume indexing\"")
        ok(has(t, "date[ ]+\\+%s"), "S7.2 does not print the epoch of the Pause (T0)")
        ok(has(t, index("rows")) && has(t, "\\$1 == \"passages\""), "S7.2 does not read the `passages` line of `kit-index.sh rows`")
        ok(has(t, index("status")), "S7.2 never reads the done count (`kit-index.sh status`)")
        ok(has(t, "sleep[ ]+0\\.25"), "S7.2 does not poll every 250 ms")
        ok(has(t, "[^0-9]5[^0-9]") && has(t, "[^0-9]20[^0-9]"), "S7.2 does not hold the 5 s and the 20 s of the map")
        ok(has(t, "Paused"), "S7.2 never reads that the menu says Paused")
        ok(has(t, index("wait[ ]+rising[ ]+10")), "S7.2 does not wait for the count to rise within 10 s after Resume (`kit-index.sh wait rising 10`)")
        ok(has(t, index("snapshot[ ]+\"?before-pause\"?[ ]+--files-only")), "S7.2 takes no `snapshot before-pause --files-only`")
        ok(has(t, index("snapshot[ ]+\"?after-resume\"?[ ]+--files-only")), "S7.2 takes no `snapshot after-resume --files-only`")
        ok(has(t, index("diff[ ]+\"?before-pause\"?[ ]+\"?after-resume")), "S7.2 does not compare the two snapshots (`kit-index.sh diff before-pause after-resume`)")
        before(t, click("Pause indexing"), click("Resume indexing"), "S7.2 presses Resume before Pause")
        before(t, click("Resume indexing"), index("wait[ ]+rising[ ]+10"), "S7.2 waits for the rise before it pressed Resume")
        before(t, index("snapshot[ ]+\"?before-pause"), click("Resume indexing"), "S7.2 takes the before-pause snapshot after Resume")
        before(t, click("Resume indexing"), index("snapshot[ ]+\"?after-resume"), "S7.2 takes the after-resume snapshot before Resume")
        ok(has(t, "recipe_minimix"), "S7.2 does not run on the 400-photo mini mix (`recipe_minimix`)")
    }

    // MARK: S7.3 and S7.17

    @Test("S7.3: kit-load.sh start 90 measured above 70 percent, Paused 10 to 14 s after the load starts, resumes 30 to 36 s after it ends")
    func s73() {
        guard let t = inner("S7.3") else { return }
        ok(has(t, load("start[ ]+90")), "S7.3 never starts the busy stand-in at 90 percent (`kit-load.sh start 90`)")
        ok(has(t, load("measure")), "S7.3 never proves the load (`kit-load.sh measure`)")
        ok(has(t, load("stop")), "S7.3 never stops the busy stand-in")
        ok(has(t, "[^0-9]70[^0-9]"), "S7.3 does not hold the 70 percent the load must stay above")
        for n in ["10", "14", "30", "36"] {
            ok(has(t, "[^0-9]\(n)[^0-9]"), "S7.3 does not hold the \(n) s bound of the CPU rule")
        }
        ok(has(t, ax("read[ ]+menubar")), "S7.3 never reads the status item for Paused and Indexing")
        ok(has(t, index("wait[ ]+paused")), "S7.3 does not cross-check the pause with `kit-index.sh wait paused`")
        ok(has(t, index("wait[ ]+resumed")), "S7.3 does not cross-check the resume with `kit-index.sh wait resumed`")
        ok(has(t, "date[ ]+\\+%s"), "S7.3 counts no time from a printed epoch")
        ok(t.contains("status-timeline-cpu"), "S7.3 saves no status-timeline-cpu.tsv")
        ok(has(t, "RERUN S7\\.3") && has(t, "return 4"), "a load that fell short must be `RERUN S7.3 ...` and exit 4, never a pass or a fail")
        before(t, load("start[ ]+90"), load("stop"), "S7.3 stops the load before it started it")
        before(t, load("stop"), index("wait[ ]+resumed"), "S7.3 waits for the resume before the load was stopped")
    }

    @Test("S7.17: a 5 s and an 8 s burst and a steady 60 percent never pause; 60 percent after a pause leaves it Paused; resumes 30 to 36 s after the load ends")
    func s717() {
        guard let t = inner("S7.17") else { return }
        ok(has(t, load("start[ ]+100")), "S7.17 never runs a 100 percent burst (`kit-load.sh start 100`)")
        ok(has(t, load("start[ ]+60")), "S7.17 never runs a steady 60 percent (`kit-load.sh start 60`)")
        ok(has(t, load("start[ ]+90")), "S7.17 never pauses the indexing with a 90 percent load first")
        ok(has(t, load("stop")), "S7.17 never stops the busy stand-in")
        ok(has(t, load("measure")), "S7.17 never proves its loads (`kit-load.sh measure`)")
        ok(has(t, "sleep[ ]+5\\b") && has(t, "sleep[ ]+8\\b"), "S7.17 does not hold a 5 s and an 8 s burst")
        ok(has(t, "[^0-9]60[^0-9]"), "S7.17 does not hold the 60 s of the steady load")
        ok(has(t, "[^0-9]30[^0-9]") && has(t, "[^0-9]36[^0-9]"), "S7.17 does not hold the 30 to 36 s of the resume")
        ok(has(t, ax("read[ ]+menubar")), "S7.17 never reads the status item")
        ok(has(t, "Paused") && has(t, "Indexing"), "S7.17 does not read both Paused and Indexing")
        ok(has(t, "RERUN S7\\.17") && has(t, "return 4"), "a load that fell short must be `RERUN S7.17 ...` and exit 4")
        ok(count(t, load("start[ ]+")) >= 4, "S7.17 starts fewer than four loads (burst 5 s, burst 8 s, steady 60, then 90 followed by 60)")
    }

    // MARK: S7.4

    @Test("S7.4: kit-power.sh lowpower on|off under the administrator session, Paused within 5 s and held, resumes by itself, a pause by you stays; NEEDS-A-PERSON without the setting or rights")
    func s74() {
        guard let t = inner("S7.4"), let full = check("S7.4") else { return }
        ok(has(t, power("ping")), "S7.4 never asks whether this Mac has Low Power Mode (`kit-power.sh ping`)")
        ok(has(t, "kit-perms\\.sh\"?[ ]+ask-admin"), "S7.4 does not prime the administrator session (`kit-perms.sh ask-admin`)")
        ok(has(t, power("lowpower[ ]+on")), "S7.4 never turns Low Power Mode on")
        ok(has(t, power("lowpower[ ]+off")), "S7.4 never turns Low Power Mode off")
        ok(has(t, ax("read[ ]+menubar")), "S7.4 never reads the status item")
        ok(has(t, index("wait[ ]+paused[ ]+10")), "S7.4 does not wait for the pause (`kit-index.sh wait paused 10`)")
        ok(has(t, index("wait[ ]+stable[ ]+20")), "S7.4 does not hold the count constant for 20 s (`kit-index.sh wait stable 20`)")
        ok(has(t, index("wait[ ]+resumed[ ]+15")), "S7.4 does not wait for the resume (`kit-index.sh wait resumed 15`)")
        ok(has(t, index("wait[ ]+rising[ ]+10")), "S7.4 does not wait for the count to rise within 10 s (`kit-index.sh wait rising 10`)")
        ok(has(t, click("Pause indexing")) && has(t, click("Resume indexing")), "S7.4 does not run the pause-by-you case (\"Pause indexing\", Low Power Mode on and off, still Paused, \"Resume indexing\")")
        ok(has(t, "date[ ]+\\+%s"), "S7.4 does not print T0 and T1 as epochs")
        ok(t.contains("lowpower-"), "S7.4 saves no lowpower-*.txt")
        ok(t.contains("NEEDS-A-PERSON"), "S7.4 never prints NEEDS-A-PERSON (no setting on this Mac, or administrator rights refused)")
        ok(has(full, power("restore")), "S7.4 does not put the recorded Low Power Mode back (`kit-power.sh restore`) on every path")
        before(t, "kit-perms\\.sh\"?[ ]+ask-admin", power("lowpower[ ]+on"), "S7.4 turns Low Power Mode on before it asked for administrator rights")
        before(t, power("lowpower[ ]+on"), power("lowpower[ ]+off"), "S7.4 turns Low Power Mode off before it turned it on")
        ok(has(t, "NEEDS A PERSON") && t.contains("Resume anyway, on battery"), "S7.4 does not print the NEEDS A PERSON line for the battery pause and \"Resume anyway, on battery\"")
    }

    @Test("the battery pause and \"Resume anyway, on battery\" print NEEDS A PERSON lines and are never passed or pressed")
    func batteryNeverPassed() {
        for id in ["S7.3", "S7.4", "S7.17"] {
            guard let t = check(id) else { continue }
            ok(has(t, "NEEDS A PERSON:[^\\n]*battery"), "\(checkFunctionName(id)) prints no `NEEDS A PERSON: ... battery` line")
            ok(!has(t, "click[ ]+\"Resume anyway"), "\(checkFunctionName(id)) presses \"Resume anyway, on battery\"")
        }
    }

    // MARK: S7.5

    @Test("S7.5: paused part way the panel shows Still indexing (N%) within 1 point, a banner naming the missing kinds, a done file found by name, an unread file not listed; the same while indexing runs")
    func s75() {
        guard let t = check("S7.5") else { return }
        ok(has(t, click("Pause indexing")), "S7.5 does not pause indexing first (the state is held)")
        ok(has(t, click("Resume indexing")), "S7.5 does not repeat the reads with indexing running (`click \"Resume indexing\"`)")
        ok(has(t, "pn_open_panel|hotkey"), "S7.5 never opens the panel with the shortcut")
        ok(has(t, ax("dump[ ]+panel")), "S7.5 never reads the panel (`kit-ax.sh dump panel`)")
        ok(t.contains("Still indexing"), "S7.5 never looks for \"Still indexing\"")
        ok(has(t, fixtures("expect[ ]+counts")), "S7.5 takes files known from somewhere other than `kit-fixtures.sh expect counts`")
        ok(has(t, index("status")), "S7.5 never reads the done count (`kit-index.sh status`)")
        ok(has(t, index("under")), "S7.5 does not pick a done and an unread file from `kit-index.sh under`")
        ok(t.contains("done") && t.contains("pending"), "S7.5 does not tell the done files from the unread ones")
        ok(has(t, "within 1"), "S7.5 does not hold N to within 1 of done over files known")
        ok(has(t.lowercased(), "kinds"), "S7.5 never looks for the banner naming the kinds that may be missing")
        ok(has(t, search("[^\\n]*")), "S7.5 finds no file by its exact name (`kit-search.sh \"<name>\"`)")
        ok(has(t, "--expect-absent"), "S7.5 does not check that an unread file is not listed (`--expect-absent`)")
    }

    // MARK: S7.6 and S7.7

    @Test("S7.6: a new file, a new photo copied from a golden photo, a new PDF and an edited file are found within 30 s; the old phrase no longer lists the file")
    func s76() {
        guard let t = inner("S7.6") else { return }
        ok(has(t, index("wait[ ]+done")), "S7.6 does not wait for indexing to catch up (`kit-index.sh wait done`)")
        ok(t.contains("Ready"), "S7.6 does not wait for the menu to say Ready")
        ok(has(t, index("status")), "S7.6 does not check that nothing is pending (`kit-index.sh status`)")
        ok(has(t, fixtures("mutate[ ]+create")), "S7.6 never creates a file (`kit-fixtures.sh mutate create`)")
        ok(has(t, fixtures("mutate[ ]+edit")), "S7.6 never edits a file (`kit-fixtures.sh mutate edit`)")
        ok(t.contains("PHRASE"), "S7.6 does not read the unique phrase `mutate` prints (PHRASE)")
        ok(t.contains("golden/photos"), "S7.6 does not copy a new photo from a golden photo")
        ok(has(t, "\\bcp\\b[^\\n]*golden/photos"), "S7.6 does not copy the new photo with `cp` from golden/photos under a new name")
        ok(t.lowercased().contains("pdf"), "S7.6 never speaks of the new PDF")
        ok(has(t, search("[^\\n]*--wait-for")) && has(t, "--within[ ]+30"), "S7.6 does not search with `--wait-for <path> --within 30`")
        ok(has(t, "--expect-absent"), "S7.6 does not check that the old phrase no longer lists the edited file (`--expect-absent`)")
        before(t, index("wait[ ]+done"), fixtures("mutate[ ]+create"), "S7.6 creates the file before indexing caught up")
        before(t, fixtures("mutate[ ]+create"), fixtures("mutate[ ]+edit"), "S7.6 edits before it created")
    }

    @Test("S7.7: a deleted, moved or renamed file leaves the index and the results within 30 s and shows under its new path, one row only")
    func s77() {
        guard let t = check("S7.7") else { return }
        ok(has(t, fixtures("mutate[ ]+delete")), "S7.7 never deletes a file")
        ok(has(t, fixtures("mutate[ ]+rename")), "S7.7 never renames a file")
        ok(has(t, fixtures("mutate[ ]+move")), "S7.7 never moves a file")
        ok(has(t, index("has")), "S7.7 never asks `kit-index.sh has` for the old and the new path")
        ok(has(t, "--expect-absent"), "S7.7 does not check the old path is absent from the results (`--expect-absent`)")
        ok(has(t, "--wait-for") && has(t, "--within[ ]+30"), "S7.7 does not wait for the new path (`--wait-for <path> --within 30`)")
        ok(has(t, index("under")), "S7.7 does not count the rows under the folder (`kit-index.sh under`), so \"one row only\" is never looked at")
        ok(t.lowercased().contains("one row"), "S7.7 never says `one row`")
        ok(has(t, index("wait[ ]+done")), "S7.7 does not start from a caught-up index (`kit-index.sh wait done`)")
    }

    // MARK: S7.8

    @Test("S7.8: a disk image detached empties the index under it within 30 s; attached again with no click its files are read and found within 300 s, startPressed still true")
    func s78() {
        guard let t = inner("S7.8"), let full = check("S7.8") else { return }
        ok(has(t, volume("make")), "S7.8 never makes the disk image (`kit-volume.sh make`)")
        ok(has(t, volume("detach")), "S7.8 never detaches the volume")
        ok(has(t, volume("attach")), "S7.8 never attaches it again")
        ok(has(full, volume("destroy")), "S7.8 does not destroy the image on every path (`kit-volume.sh destroy`)")
        ok(has(t, "drive_picker|pick_folders"), "S7.8 does not add the mount folder with the picker")
        ok(has(t, index("wait[ ]+done")), "S7.8 does not wait for the volume to be indexed (`kit-index.sh wait done`)")
        ok(has(t, index("under")), "S7.8 never reads the rows under the mount (`kit-index.sh under`)")
        ok(has(t, "--expect-absent"), "S7.8 does not check that no result lists a file of the volume after the detach")
        ok(has(t, "--wait-for") && has(t, "--within[ ]+300"), "S7.8 does not wait up to 300 s for the files after the attach")
        ok(has(t, index("settings")) && t.contains("startPressed"), "S7.8 does not read that startPressed is still true after the attach")
        ok(has(t, "date[ ]+\\+%s"), "S7.8 counts no time from a printed epoch (T0 of the detach)")
        ok(has(t, "[^0-9]30[^0-9]"), "S7.8 does not hold the 30 s of the detach")
        before(t, volume("detach"), volume("attach"), "S7.8 attaches before it detached")
        // no click by the kit after the attach
        if let a = firstIndex(t, volume("attach")) {
            let after = String(t[t.index(t.startIndex, offsetBy: a)...])
            ok(!has(after, ax("click")), "S7.8 clicks something after the attach: the files must be read again with no click")
        }
    }

    // MARK: S7.9

    @Test("S7.9: a folder removed in Settings is absent within 2 s and out of the index within 30 s; unticked the same; ticked again it waits 60 s for Start indexing")
    func s79() {
        guard let t = check("S7.9") else { return }
        ok(has(t, click("Settings…")), "S7.9 never opens Settings")
        ok(has(t, ax("dump[ ]+settings")), "S7.9 never reads Settings")
        ok(t.contains("Remove"), "S7.9 never presses a Remove control of the Folders list")
        ok(has(t, click("More actions for extra")), "S7.9 never presses the more button of the row of extra (\"More actions for extra\"): Re-index and Remove are menu items of that button (guide 16.4)")
        ok(has(t, click("Remove")), "S7.9 never presses the Remove item of the open menu")
        ok(has(t, click("Remove folder")), "S7.9 never presses the confirmation \"Remove folder\"")
        ok(!has(t, "click[ ]+--help"), "S7.9 still presses with --help: the row's Remove is no longer a button carrying the folder's name as help")
        before(t, click("More actions for extra"), click("Remove"), "S7.9 presses Remove before the more button")
        before(t, click("Remove"), click("Remove folder"), "S7.9 confirms before it pressed Remove")
        ok(has(t, "pressing the more button of the row of extra failed"), "S7.9 has no failure message for the more button press")
        ok(has(t, "the Remove item of the open menu could not be pressed \\(the menu did not open, or kit-ax does not reach an open menu's items\\)"), "S7.9 has no failure message for the Remove item press")
        ok(has(t.lowercased(), "confirm"), "S7.9 never confirms the removal")
        ok(has(t, "--expect-absent"), "S7.9 does not check that a removed folder's file is absent from the results")
        ok(has(t, "[^0-9]2[^0-9]") && has(t, "[^0-9]30[^0-9]") && has(t, "[^0-9]60[^0-9]"), "S7.9 does not hold the 2 s, 30 s and 60 s of the map")
        ok(has(t, index("under")), "S7.9 never reads the rows under the folder (`kit-index.sh under`)")
        ok(has(t.lowercased(), "untick"), "S7.9 never unticks a folder")
        ok(has(t, click("Start indexing")), "S7.9 never presses Start indexing after ticking again")
        ok(has(t, index("wait[ ]+done")), "S7.9 does not wait for Start indexing to read the files again (`kit-index.sh wait done`)")
        if let s = lastIndex(t, click("Start indexing")), let u = lastIndex(t, index("under")) {
            ok(u < s || has(t, "absent"), "S7.9 never shows the rows stayed absent before Start indexing")
        }
    }

    private struct S7_9World {
        let more: Bool
        let item: Bool
        let plant: Bool
    }

    private static let s79Harness = """
    KIT_SCRIPTS="$W/scripts"
    KIT_ROOT="$W/root"
    KIT_PLANT="$PLANT"
    . "$CHECKS"
    kq() { "$@"; }
    sleep() { echo "sleep $1" >> "$W/log"; }
    date() { n=$(cat "$W/clock"); n=$((n + 10)); echo "$n" > "$W/clock"; echo "$n"; }
    s7_arm() { return 0; }
    s6_press() { kq "$1" click "$2"; }
    s6b_settings() { return 0; }
    drive_picker() { return 0; }
    settings_section() { echo "section $1" >> "$W/log"; return 0; }
    s6b_block() { echo "row $1"; }
    s6b_tick_label() { echo "Tick minimix"; }
    s7_paths_under() { echo "/fx/$1/a.jpg"; }
    s7_total_expected() { echo 5; }
    s7_rows_under() {
      case "$1" in
        extra) if [ -e "$W/removed" ]; then echo 0; else echo 3; fi ;;
        *) cat "$W/mm" ;;
      esac
    }
    s7_wait_has() {
      case "$1" in
        */extra/*) [ -e "$W/removed" ] ;;
        *) [ "$(cat "$W/mm")" = 0 ] ;;
      esac
    }
    s7_check_9
    echo "exit $?"
    """

    private static let s79Ax = """
    #!/bin/bash
    echo "ax $*" >> "$W/log"
    [ "$1" = click ] || exit 0
    shift
    [ $# = 1 ] || { echo "usage"; exit 2; }
    case "$1" in
      "More actions for extra")
        [ -n "$FAKE_MORE" ] || { echo "no element labelled"; exit 1; }
        : > "$W/menu"; exit 0 ;;
      "Remove")
        [ -e "$W/menu" ] && [ -n "$FAKE_ITEM" ] || { echo "no element labelled"; exit 1; }
        : > "$W/removed"; exit 0 ;;
      "Remove folder")
        [ -e "$W/removed" ] || { echo "no element labelled"; exit 1; }
        exit 0 ;;
      "Tick minimix")
        if [ -e "$W/unticked" ]; then rm -f "$W/unticked"; else : > "$W/unticked"; echo 0 > "$W/mm"; fi
        exit 0 ;;
      "Start indexing")
        [ -e "$W/unticked" ] || echo 5 > "$W/mm"
        exit 0 ;;
      *) exit 0 ;;
    esac
    """

    private func runS79(_ world: S7_9World) throws -> (output: String, clicks: [String], log: [String]) {
        let w = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun7-s79-" + UUID().uuidString)
        let scripts = w.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: w.appendingPathComponent("root"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: w) }
        try "1000\n".write(to: w.appendingPathComponent("clock"), atomically: true, encoding: .utf8)
        try "5\n".write(to: w.appendingPathComponent("mm"), atomically: true, encoding: .utf8)
        for name in ["kit-ax.sh", "kit-index.sh", "kit-fixtures.sh", "kit-search.sh"] {
            let url = scripts.appendingPathComponent(name)
            try (name == "kit-ax.sh" ? Self.s79Ax : "#!/bin/bash\nexit 0\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let harness = w.appendingPathComponent("harness.sh")
        try Self.s79Harness.write(to: harness, atomically: true, encoding: .utf8)
        let ran = try run("/usr/bin/env", [
            "W=\(w.path)", "CHECKS=\(libDir.appendingPathComponent("checks-s7.sh").path)",
            "PLANT=\(world.plant ? "1" : "")", "FAKE_MORE=\(world.more ? "1" : "")", "FAKE_ITEM=\(world.item ? "1" : "")",
            "/bin/bash", harness.path,
        ])
        let log = ((try? String(contentsOf: w.appendingPathComponent("log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let clicks = log.filter { $0.hasPrefix("ax click ") }.map { String($0.dropFirst("ax click ".count)) }
        return (ran.output, clicks, log)
    }

    private let s79MoreMessage = "pressing the more button of the row of extra failed"
    private let s79ItemMessage = "the Remove item of the open menu could not be pressed (the menu did not open, or kit-ax does not reach an open menu's items)"

    @Test("S7.9 through the more button: a world where the more button of the row of extra exists and its open menu holds Remove passes, pressing More actions for extra, waiting, Remove, then Remove folder, and never --help, because Re-index and Remove are menu items of a per-row more button, not buttons of the row (guide 16.4)")
    func s79MoreButtonWorldPasses() throws {
        let r = try runS79(S7_9World(more: true, item: true, plant: false))
        ok(r.output.contains("CHECK S7.9 PASS"), "S7.9 does not pass a world with the more button and a Remove item: \(r.output.suffix(600))")
        let wanted = ["More actions for extra", "Remove", "Remove folder"]
        ok(r.clicks.filter { wanted.contains($0) } == wanted, "S7.9 pressed \(r.clicks) instead of More actions for extra, Remove, Remove folder in that order")
        ok(!r.log.contains { $0.contains("--help") }, "S7.9 still presses with --help: \(r.log)")
        if let m = r.log.firstIndex(of: "ax click More actions for extra"), let d = r.log.firstIndex(of: "ax click Remove") {
            ok(r.log[m..<d].contains("sleep 1"), "S7.9 does not wait one second between the more button and Remove: \(r.log)")
            ok(m < d, "S7.9 presses Remove before the more button")
        } else {
            ok(false, "S7.9 never pressed both the more button and Remove: \(r.log)")
        }
        let folder = r.log.firstIndex(of: "ax click Remove folder") ?? -1
        let section = r.log.firstIndex(of: "section Folders") ?? Int.max
        ok(section < (r.log.firstIndex(of: "ax click More actions for extra") ?? -1), "S7.9 presses the more button before it selects the Folders section")
        ok(folder > (r.log.firstIndex(of: "ax click Remove") ?? Int.max), "S7.9 confirms before Remove")
    }

    @Test("S7.9 FAILs with \"pressing the more button of the row of extra failed\" when the dump has no more button, never a pass, because the row's Remove is only reached through that button (guide 16.4)")
    func s79NoMoreButtonFails() throws {
        let r = try runS79(S7_9World(more: false, item: true, plant: false))
        ok(r.output.contains("CHECK S7.9 FAIL"), "S7.9 does not fail a world with no more button: \(r.output.suffix(600))")
        ok(!r.output.contains("CHECK S7.9 PASS"), "S7.9 passes a world with no more button")
        ok(r.output.contains(s79MoreMessage), "S7.9 does not say \"\(s79MoreMessage)\": \(r.output.suffix(600))")
    }

    @Test("S7.9 FAILs with the Remove item message when pressing the more button leaves no Remove item, never a pass and never the more button message, because the menu did not open or kit-ax does not reach an open menu's items")
    func s79NoRemoveItemFails() throws {
        let r = try runS79(S7_9World(more: true, item: false, plant: false))
        ok(r.output.contains("CHECK S7.9 FAIL"), "S7.9 does not fail a world where the press leaves no Remove item: \(r.output.suffix(600))")
        ok(!r.output.contains("CHECK S7.9 PASS"), "S7.9 passes a world with no Remove item")
        ok(r.output.contains(s79ItemMessage), "S7.9 does not say \"\(s79ItemMessage)\": \(r.output.suffix(600))")
        ok(!r.output.contains(s79MoreMessage), "S7.9 blames the more button when it was pressed: \(r.output.suffix(600))")
        ok(!r.clicks.contains("Remove folder") || r.output.contains("CHECK S7.9 FAIL"), "S7.9 reached a pass after a Remove that could not be pressed")
    }

    @Test("S7.9 with --plant still FAILs on a world that passes unplanted, as \"CHECK S7.9 FAIL planted: the rows expected under a removed folder read as 1 instead of 0\", because removal is still proved by the same index reads (rows under extra 0 within 30 s)")
    func s79PlantStillFails() throws {
        let r = try runS79(S7_9World(more: true, item: true, plant: true))
        ok(r.output.contains("CHECK S7.9 FAIL planted: the rows expected under a removed folder read as 1 instead of 0"), "S7.9 --plant is not a planted FAIL line: \(r.output.suffix(600))")
        ok(!r.output.contains("CHECK S7.9 PASS"), "S7.9 passes with its plant")
    }

    @Test("S7.9 still FAILs when the folder is not removed by the Remove press: the file stays in the index and its rows stay, with the more button and the Remove item both pressed")
    func s79RowsStayFails() throws {
        let r = try runS79(S7_9World(more: true, item: false, plant: false))
        ok(r.output.contains("rows under extra are in the index 30 s after the folder was removed"), "S7.9 does not read the rows under extra after a failed removal: \(r.output.suffix(600))")
    }

    // MARK: S7.10 and S7.11

    @Test("S7.10: Quit leaves no process within 5 s, the count is constant 30 s, integrity ok; the relaunch resumes with no click and the done files are unchanged")
    func s710() {
        guard let t = inner("S7.10") else { return }
        ok(has(t, launch("quit")), "S7.10 never quits the app (`kit-launch.sh quit`)")
        ok(has(t, launch("pids")), "S7.10 never lists the processes (`kit-launch.sh pids`)")
        ok(has(t, "[^0-9]5[^0-9]"), "S7.10 does not hold the 5 s")
        ok(has(t, index("wait[ ]+stable[ ]+30")), "S7.10 does not hold the done count constant for 30 s (`kit-index.sh wait stable 30`)")
        ok(has(t, index("integrity")), "S7.10 never runs the integrity check (`kit-index.sh integrity`)")
        ok(has(t, launch("start[ ]+--mirror-full")), "S7.10 does not relaunch (`kit-launch.sh start --mirror-full`)")
        ok(has(t, index("wait[ ]+rising[ ]+60")), "S7.10 does not wait for the count to rise within 60 s (`kit-index.sh wait rising 60`)")
        ok(has(t, index("snapshot[ ]+\"?before-quit\"?[ ]+--files-only")), "S7.10 takes no `snapshot before-quit --files-only`")
        ok(has(t, index("diff[ ]+\"?before-quit\"?[ ]+\"?after-relaunch")), "S7.10 does not compare the files before the quit and after the relaunch")
        ok(has(t, index("settings")) && t.contains("startPressed"), "S7.10 does not read that the start flag is still set (`kit-index.sh settings`)")
        before(t, launch("quit"), launch("start[ ]+--mirror-full"), "S7.10 relaunches before it quit")
        if let r = lastIndex(t, launch("start[ ]+--mirror-full")) {
            let after = String(t[t.index(t.startIndex, offsetBy: r)...])
            ok(!has(after, click("Start indexing")), "S7.10 presses Start indexing after the relaunch: indexing must resume by itself")
        }
    }

    @Test("S7.11: Delete index, relaunch, 90 s later no rows and no index helper, the menu not Indexing; Start indexing then runs to Ready")
    func s711() {
        guard let t = inner("S7.11") else { return }
        ok(has(t, click("Settings…")), "S7.11 never opens Settings")
        ok(has(t, click("Delete index…")), "S7.11 never presses \"Delete index…\"")
        ok(has(t, launch("relaunch")), "S7.11 never relaunches (`kit-launch.sh relaunch`)")
        ok(has(t, index("wait[ ]+stable[ ]+90")), "S7.11 does not wait 90 s (`kit-index.sh wait stable 90`)")
        ok(has(t, index("rows")), "S7.11 never reads `kit-index.sh rows`")
        ok(has(t, "\\$1 == \"files\"") && has(t, "\\$1 == \"passages\""), "S7.11 does not read both the `files` and the `passages` line (both must be 0)")
        ok(has(t, launch("pids")) && t.contains("index"), "S7.11 never looks for an index helper (`kit-launch.sh pids`)")
        ok(has(t, ax("read[ ]+menubar")), "S7.11 never reads that the menu is not Indexing")
        ok(has(t, click("Start indexing")), "S7.11 never presses Start indexing after the Delete index")
        ok(has(t, index("wait[ ]+done")), "S7.11 does not run the rebuilt index to Ready (`kit-index.sh wait done`)")
        ok(t.contains("Ready"), "S7.11 does not read Ready at the end")
        before(t, click("Delete index…"), launch("relaunch"), "S7.11 relaunches before Delete index")
        before(t, launch("relaunch"), index("wait[ ]+stable[ ]+90"), "S7.11 waits before the relaunch")
        if let d = firstIndex(t, click("Delete index…")), let s = lastIndex(t, click("Start indexing")) {
            ok(s > d, "S7.11 presses Start indexing before Delete index")
        }
    }

    // MARK: S7.12

    @Test("S7.12: ten kills, five of the index helper and five of the app, integrity ok after each, indexing finishes by itself, final per-file state equals the clean run")
    func s712() {
        guard let t = inner("S7.12") else { return }
        ok(has(t, launch("kill9[ ]+index")), "S7.12 never kills the index helper (`kit-launch.sh kill9 index`)")
        ok(has(t, launch("kill9[ ]+app")), "S7.12 never kills the app (`kit-launch.sh kill9 app`)")
        ok(has(t, index("integrity")), "S7.12 does not run the integrity check after each kill")
        ok(has(t, launch("start[ ]+--mirror-full")), "S7.12 does not start the app again after an app kill (`kit-launch.sh start --mirror-full`)")
        ok(has(t, index("wait[ ]+done")), "S7.12 does not wait for indexing to finish on its own (`kit-index.sh wait done`)")
        ok(has(t, index("snapshot[ ]+\"?clean-ref\"?[ ]+--files-only")), "S7.12 takes no `snapshot clean-ref --files-only` of an uninterrupted run")
        ok(has(t, index("snapshot[ ]+\"?after-kills\"?[ ]+--files-only")), "S7.12 takes no `snapshot after-kills --files-only`")
        ok(has(t, index("diff[ ]+\"?clean-ref\"?[ ]+\"?after-kills")), "S7.12 does not compare the two (`kit-index.sh diff clean-ref after-kills`)")
        let full = t.split(separator: "\n").map(String.init).filter { has($0, index("snapshot")) && !$0.contains("--files-only") }
        ok(full.isEmpty, "S7.12 takes a full-row snapshot, which a correctly re-read file may legitimately change: \(full.first ?? "")")
        ok(t.lowercased().contains("seed"), "S7.12 does not print the seed of its random moments")
        ok(t.contains("index-snaps"), "S7.12 does not read the per-file state to check that every done file has its passages and no other file has any")
        ok(t.contains("kill-"), "S7.12 saves no kill-*.txt")
        ok(has(t, "\\$RANDOM|srand|awk[^\\n]*seed"), "S7.12 does not draw its random moments from the printed seed")
        ok(count(t, "1 2 3 4 5") >= 1, "S7.12 does not count five kills of each kind")
        before(t, index("snapshot[ ]+\"?clean-ref"), launch("kill9[ ]+index"), "S7.12 kills before it took the clean reference")
        before(t, launch("kill9[ ]+index"), index("snapshot[ ]+\"?after-kills"), "S7.12 takes the after-kills snapshot before the kills")
    }

    // MARK: S7.13

    @Test("S7.13: after the last work or search a helper may be listed at 45 s and none at 80 s; the encode and the index helper each")
    func s713() {
        guard let t = check("S7.13") else { return }
        ok(has(t, launch("pids[ ]+--names")), "S7.13 never lists the helpers by name (`kit-launch.sh pids --names`)")
        ok(has(t, "[^0-9]45[^0-9]") && has(t, "[^0-9]80[^0-9]"), "S7.13 does not read at 45 s and at 80 s")
        ok(t.contains("encode") && t.contains("index"), "S7.13 does not check both the encode and the index helper")
        ok(has(t, search("[^\\n]*")), "S7.13 does not start the encode helper with a search (`kit-search.sh`)")
        ok(has(t, "sleep[ ]+(45|80|35)"), "S7.13 does not wait for the idle seconds")
        ok(has(t, index("wait[ ]+done")), "S7.13 does not let an indexing batch end first (`kit-index.sh wait done`)")
    }

    // MARK: S7.14

    @Test("S7.14: Settings shows Launch at login on at a fresh start with the exact note, and pressing it flips the switch each time")
    func s714() {
        guard let t = check("S7.14") else { return }
        ok(t.contains("The shortcut works only while Sesame is running."), "S7.14 does not look for the exact note \"The shortcut works only while Sesame is running.\"")
        ok(t.contains("Launch at login"), "S7.14 never names the switch \"Launch at login\"")
        ok(has(t, ax("dump[ ]+settings")), "S7.14 never reads Settings (`kit-ax.sh dump settings`)")
        ok(has(t, click("Settings…")), "S7.14 never opens Settings from the menu")
        ok(count(t, click("Launch at login")) >= 2, "S7.14 does not press the switch twice (off, then on)")
        ok(has(t, "recipe_setup|recipe_fresh_throttled"), "S7.14 does not start from a fresh state")
        ok(count(t, ax("dump[ ]+settings")) >= 3, "S7.14 does not read Settings at the start and after each press")
    }

    // MARK: S7.15

    @Test("S7.15: three rounds of 15 random operations with seeds 11, 12 and 13, each followed by 35 s, then the index equals the kit's listing; phrases found and old phrases gone; no path twice")
    func s715() {
        guard let t = check("S7.15") else { return }
        ok(has(t, fixtures("mutate[ ]+random[ ]+15[ ]+--seed")), "S7.15 never runs `kit-fixtures.sh mutate random 15 --seed <n> <folder>`")
        for seed in ["11", "12", "13"] {
            ok(has(t, "[^0-9]\(seed)[^0-9]"), "S7.15 does not use the seed \(seed)")
        }
        ok(has(t, "sleep[ ]+35"), "S7.15 does not wait 35 s after each round")
        ok(has(t, index("under")), "S7.15 never reads `kit-index.sh under`")
        ok(has(t, fixtures("expect[ ]+listing")), "S7.15 does not compare with `kit-fixtures.sh expect listing`")
        ok(has(t.lowercased(), "twice") || has(t.lowercased(), "uniq"), "S7.15 does not check that no path appears twice")
        ok(has(t, "PHRASE"), "S7.15 does not follow the unique phrases of the created and edited files")
        ok(has(t, "--expect-absent"), "S7.15 does not check that a previous phrase no longer lists the file")
        ok(has(t, "Ready"), "S7.15 does not start from an index at Ready")
        ok(has(t, "recipe_minimix"), "S7.15 does not run on a folder it may change (the mini mix)")
    }

    // MARK: S7.16

    @Test("S7.16: the status item has a non-empty accessibility label in each state")
    func s716() {
        guard let t = check("S7.16") else { return }
        let l = t.lowercased()
        ok(has(t, ax("read[ ]+menubar")), "S7.16 never reads the status item's label (`kit-ax.sh read menubar`)")
        for state in ["downloading", "indexing", "paused", "ready"] {
            ok(l.contains(state), "S7.16 never looks at the state \(state)")
        }
        ok(l.contains("empty"), "S7.16 does not say that an empty label is a failure")
        ok(l.contains("voiceover"), "S7.16 does not say the label is the VoiceOver label")
        ok(has(t, "recipe_fresh_throttled"), "S7.16 does not reach Downloading")
    }

    // MARK: S7.18

    @Test("S7.18: three kit-privacy.sh login-item readings (on, off, on again); the control reads absent; NEEDS-A-PERSON on absent or unreadable")
    func s718() {
        guard let t = inner("S7.18") else { return }
        ok(has(t, "kit-perms\\.sh\"?[ ]+ask-admin"), "S7.18 does not prime the administrator session (`kit-perms.sh ask-admin`)")
        ok(count(t, privacy("login-item")) >= 3, "S7.18 reads `kit-privacy.sh login-item` \(count(t, privacy("login-item"))) time(s), expected three (switch on, off, on again)")
        ok(count(t, click("Launch at login")) >= 2, "S7.18 does not press the switch off and on again (`click \"Launch at login\"`)")
        ok(t.contains("login-item-on") && t.contains("login-item-off"), "S7.18 saves no login-item-on.txt and login-item-off.txt")
        ok(t.contains("CONTROL login-item OK"), "S7.18 does not require the control (an absent identifier reads absent)")
        ok(t.contains("present and enabled") && t.contains("present and disabled") && t.contains("absent") && t.contains("unreadable"),
           "S7.18 does not know the four answers of `kit-privacy.sh login-item`")
        ok(t.contains("NEEDS-A-PERSON"), "S7.18 never prints NEEDS-A-PERSON (absent or unreadable with the switch on, or administrator rights refused)")
        ok(has(t, click("Settings…")), "S7.18 never opens Settings")
        before(t, "kit-perms\\.sh\"?[ ]+ask-admin", privacy("login-item"), "S7.18 reads the login item before it asked for administrator rights")
    }

    // MARK: all of them

    @Test("every S7 check that needs indexing in progress re-arms it through steps a person has: Delete index and Start indexing; the kit edits no state", arguments: inProgressIds)
    func rearm(_ id: String) {
        guard let t = check(id) else { return }
        ok(has(t, click("Delete index…")), "\(checkFunctionName(id)) does not re-arm through \"Delete index…\"")
        ok(has(t, click("Start indexing")), "\(checkFunctionName(id)) does not re-arm through \"Start indexing\"")
        ok(has(t, "recipe_minimix"), "\(checkFunctionName(id)) does not start from the 400-photo mini mix (`recipe_minimix`)")
    }

    @Test("no S7 check edits settings.json, the index or a preference, and every sudo is sudo -n", arguments: allIds)
    func readsOnlyAndSudoN(_ id: String) {
        guard let t = check(id) else { return }
        ok(!has(t, "sqlite3") && !has(t, "plutil") && !has(t, "defaults[ ]+write"), "\(checkFunctionName(id)) edits state with sqlite3, plutil or defaults instead of steps a person has")
        ok(!has(t, ">>?[ ]*\"?[^ \"]*settings\\.json") && !has(t, "(rm|mv|cp)[ ][^\\n]*(settings\\.json|index\\.sqlite)"), "\(checkFunctionName(id)) writes or removes settings.json or the index")
        ok(!has(t, "\\bsudo\\b(?![ ]+-n\\b)"), "\(checkFunctionName(id)) calls sudo without -n")
    }

    @Test("no S7 check, nor the runner, reads Sources/", arguments: allIds)
    func neverReadsSources(_ id: String) {
        guard let t = check(id) else { return }
        ok(!t.contains("Sources/") && !has(t, "\\bSources\\b"), "\(checkFunctionName(id)) names Sources: the kit never reads the product's source")
    }

    @Test("typing goes through kit-ax.sh and keeps KIT_TYPE_DELAY_MS: no delay of its own, no other key tool", arguments: allIds)
    func typingHonoursDelay(_ id: String) {
        guard let t = check(id) else { return }
        ok(!has(t, "--delay-ms"), "\(checkFunctionName(id)) passes --delay-ms, which overrides KIT_TYPE_DELAY_MS")
        ok(!has(t, "(^|[^A-Za-z0-9_])KIT_TYPE_DELAY_MS="), "\(checkFunctionName(id)) sets KIT_TYPE_DELAY_MS itself")
        ok(!has(t, "keytool|cliclick|CGEvent|key code|keystroke"), "\(checkFunctionName(id)) posts keys by a tool of its own, not through kit-ax.sh")
        ok(!has(t, "osascript"), "\(checkFunctionName(id)) calls osascript itself instead of kit-ax.sh")
    }

    @Test("every S7 check prints its id on a CHECK line and can be planted", arguments: allIds)
    func printsAndPlants(_ id: String) {
        guard let t = check(id) else { return }
        ok(t.contains(id), "\(checkFunctionName(id)) never names \(id) on a CHECK line")
        ok(has(t, "S7_PLANTED=\"[^\"]+\""), "\(checkFunctionName(id)) names no planted input (S7_PLANTED=\"...\"), so `kit-run.sh --plant \(id)` could never show a FAIL planted line")
        ok(has(t, "\\bKIT_PLANT\\b"), "\(checkFunctionName(id)) never looks at KIT_PLANT")
    }

    @Test("an exit 4 is a rerun, never a pass or a fail: each check names RERUN <id> and returns 4 when a precondition did not hold", arguments: allIds)
    func rerunOnInvalid(_ id: String) {
        guard let t = check(id) else { return }
        ok(has(t, "RERUN[ ]+(\\$id|\(NSRegularExpression.escapedPattern(for: id)))") && has(t, "return[ ]+4|\\$S7_RC|S7_RC="), "\(checkFunctionName(id)) has no `RERUN \(id) not valid: <reason>` path that returns 4")
    }
}

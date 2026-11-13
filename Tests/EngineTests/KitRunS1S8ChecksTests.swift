import Foundation
import Testing

// plan-2-t13, tester step: kit part 9, the S1 and S8 checks of slice 2, the recipe `photos` waiting for Ready, the status
// item smoke of `verify.sh --quick`, the Doctor and the floor (scripts/kit-lib/checks-*.sh, scripts/kit-lib/checks.tsv,
// checks.floor, slice, scripts/kit-run.sh, scripts/verify.sh, scripts/kit-doctor.sh). Written from verify.md, the S1 and S8
// feature maps, the design and the plan-2-t13 entry only; no product source is read, and no kit function may read `Sources/`.
//
// Static proof only (plan-2-tasks.md, Conventions; the person's ruling "no app launch"): `kit-run.sh`, `verify.sh` and
// `kit-doctor.sh` start the app, so NOTHING here executes them, not even with no mode. The runs are `bash -n` on the files.
// Every other check reads the text of the scripts, with their comment lines removed (a comment never satisfies a check),
// and reads a check function as the shell would run it: every call of a function of the kit is replaced, in place, by that
// function's own code, and every simple top-level variable by its value. Real behaviour is driven against the live app at
// the accept stage only (blocks A, B, C, D and F).
//
// The contract read here (plan-2-t13, Tests, and the feature maps S1 and S8):
//   - checks.tsv registers S1.6, S1.30 and S8.11 at slice 2 (`auto`), keeps S1.21, S1.22 and S1.29 once, and each of the
//     six ids has exactly one function; S1.21, S1.22 and S1.29 now hold their slice 2 parts;
//   - S1.6: both golden/ and golden/photos/ picked (read from Settings), no path twice in any list, one `files` row per path
//     under golden/photos, the menu's photo count equal to `kit-fixtures.sh expect counts`;
//   - S1.21 (b) and S8.11: after Delete index and its confirmation `kit-privacy.sh layout` shows no `index.sqlite`, `-wal` or
//     `-shm` within 10 s, `startPressed` false, the panel shows "Not ready yet" and "Nothing is indexed yet" for any text and
//     for none, and a relaunch keeps it (S8.11 then presses Start indexing and the index is back, at Ready);
//   - S1.22 (iii): paused part way, a damaged model planted, text 1 wins over text 3 and text 3 returns after the
//     re-download; (iv): Delete index with the model whole shows text 4, not text 2;
//   - S1.29: `tab-walk` over every Settings section, the menu and the setup windows, every enabled element focused and focus
//     returning to the first; S1.30: non-empty labels, not a bare role word, for the search box, the list and the status item;
//   - the recipe `photos` waits for `kit-index.sh wait done` and then for the menu to say Ready, the picker fallback unchanged;
//   - `verify.sh --quick` includes the status item check (`kit-ax.sh read menubar` non-empty) from slice 2;
//   - the Doctor lists the pings of kit-load, kit-volume, kit-power, kit-trace and kit-privacy, prints no `not built yet` for
//     them, reads the status item from slice 2 and counts a missing administrator session as a person-step from slice 2;
//   - `checks.floor` is the number of `auto` ids of slices 1 and 2 that need no administrator rights (63 `auto` ids of
//     slices 1 and 2 minus S6.8, which primes the administrator session and starts the file trace = 62, recounted from
//     checks.tsv below), counts PASS only and is never lowered; `slice` holds 2.
// Red before the kit part: S1.6, S1.30 and S8.11 have no function, the floor is 7 and the slice is 1.
//
// plan-3-t12b (edited by hand, never weakened): the slice and the floor moved. `slice` holds 3 and `checks.floor` is the number of
// `auto` ids of slices 1 to 3 that need no administrator rights, 70 (see `recountedFloor` and `floorIsTheCount` for the recount);
// `verify.sh --quick` runs S8.10 only below slice 3 (see `verifyQuickS810Guard`); the check-id table of kit-perms.sh is pinned in
// `permsTableAtSlice3`. Reason: plan 3 adds twelve `auto` ids at slice 3 and a floor that stayed at 62 would let eight of them fail.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")

private let newIds = ["S1.6", "S1.30", "S8.11"]
private let extendedIds = ["S1.21", "S1.22", "S1.29"]
private let allIds = newIds + extendedIds
/// The ids of slices 1 to 3 whose check needs an administrator session (S6.8 primes it with `kit-perms.sh ask-admin` and starts the
/// file trace; S7.4 and S7.18 also do, but they are `auto-or-person`, not `auto`). plan-3-t12b, reason for this edit: slice 3 adds
/// S8.2, S8.3 (the file trace), S8.7 and S6.13 (the network summary, which reads a trace); a hand-written list, not found by text,
/// because S8.1 and S8.9 reach `s8_close_window`, which asks for the administrator session only when a trace ran, and are counted.
private let adminIds: Set<String> = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]
/// The figure of the entry, recounted by hand from checks.tsv (plan-3-t12b): 75 `auto` ids of slices 1 to 3 (the 63 of slices 1 and 2,
/// plus the twelve of slice 3: S2.2, S2.3, S2.8, S2.17, S6.13, S8.1, S8.2, S8.3, S8.5, S8.6, S8.7, S8.9), minus the five administrator ids
/// above = 70. Equivalently plan 2's 62 plus S2.2, S2.3, S2.8, S2.17, S8.1, S8.5, S8.6, S8.9. The entry's count (70) and this recount agree.
/// S8.10 and S8.13 stay counted (plan-3 D15): their session parts need Full Disk Access or the S8 session, and the floor counts PASS only.
/// plan-4-t3 (amended by the tester, never lowered): slice 4 adds nine `auto` ids that need no administrator rights (S2.4, S3.1, S3.2, S3.3,
/// S3.5, S3.6, S3.7, S3.8, S3.10; S3.4 and S3.9 are `auto-or-person` and never count), so the hand recount is 70 + 9 = 79.
/// plan-5-t1b (amended by the tester, never lowered): slice 5 adds seven `auto` ids that need no administrator rights (S2.5, S4.1, S4.3, S4.4,
/// S4.6, S4.9, S4.10; S4.2, S4.5, S4.7, S4.8 and S8.8 are `auto-or-person` and never count), so the hand recount is 79 + 7 = 86.
private let recountedFloorAtSlice5 = 85
private let slice6NewIds = ["S2.15"]
private let slice7NewIds = ["S9.1", "S9.2", "S9.3", "S9.4", "S9.5"]
private let slice8NewIds = ["S10.5", "S10.8"]
private let recountedFloor = 93

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

/// Runs a program that is not a kit script (`/bin/bash -n`).
private func run(_ exe: String, _ args: [String], limit: TimeInterval = 60) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun18-out-" + UUID().uuidString)
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

/// The code of the scripts the runner sources, the runner itself, and verify.sh and the Doctor, as (name, code).
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

/// The S8 session wrappers of plan 3 (t8, t11). From slice 3 S8.10 and S8.13 call them; they reach `sudo -n true` only to choose a
/// traced or an untraced session (it never asks for a password), so a call through them is not a use of the administrator session
/// (plan-3-t11, reason for this edit; plan-3 D15 keeps S8.10 and S8.13 counted, and t12 says the same of tree_need, s8_activity and
/// s8_close_window).
private let s8SessionWrappers = ["tree_need", "s8_activity", "s8_close_window", "s8_net_summary"]

/// The check of an id as the shell would run it, with the S8 session wrappers left as calls (see `s8SessionWrappers`). Nothing else
/// is left out: `ask-admin`, `sudo`, `kit-power.sh lowpower` and `login-item` anywhere else in the check still count.
private func checkLeavingSessionCalls(_ id: String) -> String? {
    let functions = allFunctions()
    let name = checkFunctionName(id)
    guard let body = functions[name] else {
        Issue.record(Comment(rawValue: "\(name) is not defined in scripts/kit-run.sh or scripts/kit-lib/*.sh"))
        return nil
    }
    return substitute(expandShell(body, functions, skipping: [name] + s8SessionWrappers), topLevelValues())
}

/// The check as the wrapper runs it: `check_S1_6() { nr_run s1_check_6; }` runs the function it names last, so this is that
/// function's code with the helpers written in and no wrapper or cleanup text in front of it.
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

/// The code of a script of scripts/ (comments removed).
private func scriptCode(_ name: String) -> String? {
    read(scriptsDir.appendingPathComponent(name)).map(stripComments)
}

// Patterns of a call of a kit script, as the check text holds it after the variables are written in.
private func ax(_ args: String) -> String { "kit-ax\\.sh\"?[ ]+\(args)" }
private func click(_ label: String) -> String { ax("click[ ]+\"\(NSRegularExpression.escapedPattern(for: label))\"") }
private func index(_ args: String) -> String { "kit-index\\.sh\"?[ ]+\(args)" }
private func fixtures(_ args: String) -> String { "kit-fixtures\\.sh\"?[ ]+\(args)" }
private func launch(_ args: String) -> String { "kit-launch\\.sh\"?[ ]+\(args)" }
private func privacy(_ args: String) -> String { "kit-privacy\\.sh\"?[ ]+\(args)" }
private func mirror(_ args: String) -> String { "kit-mirror\\.sh\"?[ ]+\(args)" }

@Suite("KitRunS1S8ChecksTests")
struct KitRunS1S8ChecksTests {

    // MARK: syntax

    @Test("bash -n finds no syntax error in the runner, verify.sh, the Doctor and the kit-lib shell files (none is run)")
    func bashSyntax() throws {
        var paths = ["kit-run.sh", "verify.sh", "kit-doctor.sh"].map { scriptsDir.appendingPathComponent($0).path }
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

    @Test("checks.tsv registers S1.6, S1.30 and S8.11 at slice 2 as auto, and keeps S1.21, S1.22 and S1.29 once", arguments: allIds)
    func registered(_ id: String) {
        guard let rows = tsvRows() else { return }
        let mine = rows.filter { $0.id == id }
        ok(mine.count == 1, "checks.tsv holds \(mine.count) rows for \(id), expected exactly one")
        if let row = mine.first {
            let slice = newIds.contains(id) ? "2" : "1"
            ok(row.slice == slice, "\(id) is registered at slice \(row.slice), expected \(slice) (verify.md, Build slices)")
            ok(row.kind == "auto", "\(id) has kind \(row.kind), expected auto")
        }
    }

    @Test("checks.tsv registers no id twice")
    func noDuplicateRows() {
        guard let rows = tsvRows() else { return }
        let ids = rows.map(\.id)
        ok(Set(ids).count == ids.count, "checks.tsv registers an id twice")
    }

    @Test("each of the six ids has exactly one check function in the check files", arguments: allIds)
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

    // MARK: S1.6

    @Test("S1.6: golden/ and golden/photos/ both picked (read in Settings), no path twice in any list, one files row per path under golden/photos, the menu's photo count equal to expect counts")
    func s16() {
        guard let t = inner("S1.6"), let full = check("S1.6") else { return }
        let l = t.lowercased()
        ok(has(full, "recipe_photos|s1_need_photos|s1_begin[ ]+S1\\.6[ ]+1"), "S1.6 does not start from the recipe `photos`")
        ok(has(t, click("Settings…")), "S1.6 never opens Settings from the menu")
        ok(has(t, ax("dump[ ]+settings")), "S1.6 never reads the picked list in Settings (`kit-ax.sh dump settings`)")
        ok(t.contains("golden/photos") || has(t, "golden[^\\n]*photos"), "S1.6 does not name golden/photos")
        ok(has(t, "golden"), "S1.6 does not name golden/")
        ok(t.contains("NEEDS-A-PERSON"), "S1.6 never prints NEEDS-A-PERSON (the overlap not picked: the check would be vacuous and must not pass)")
        ok(has(t, "answers\\.csv") && has(t, "[^A-Za-z]photo[^A-Za-z]"), "S1.6 does not run the photo queries of fixtures/answers.csv")
        ok(has(l, "twice|duplicate|uniq|seen\\["), "S1.6 does not look for a path that appears twice in a list")
        ok(has(t, index("under[ ]+\"?golden/photos")), "S1.6 never reads `kit-index.sh under golden/photos`")
        ok(has(t, fixtures("expect[ ]+listing")), "S1.6 does not compare the rows under golden/photos with `kit-fixtures.sh expect listing`")
        ok(has(t, ax("dump[ ]+menu")), "S1.6 never reads the status item's menu (`kit-ax.sh dump menu`)")
        ok(has(t, fixtures("expect[ ]+counts")), "S1.6 takes the photo count from somewhere other than `kit-fixtures.sh expect counts`")
        ok(has(l, "photo"), "S1.6 never looks at the menu's photo count")
        ok(has(t, "dump[ ]+panel|kit-search|s1_search"), "S1.6 reads no list")
        before(t, ax("dump[ ]+settings"), index("under[ ]+\"?golden/photos"), "S1.6 reads `under` before it read the picked list in Settings")
        before(t, ax("dump[ ]+settings"), ax("dump[ ]+menu"), "S1.6 reads the menu before it read the picked list in Settings")
    }

    // MARK: S1.30

    @Test("S1.30: the search box, the list and the status item each have a non-empty label that is not a bare role word; a mockup difference is noted")
    func s130() {
        guard let t = inner("S1.30") else { return }
        let l = t.lowercased()
        ok(has(t, ax("read[ ]+menubar")), "S1.30 never reads the status item's label (`kit-ax.sh read menubar`)")
        ok(has(t, "dump[ ]+panel"), "S1.30 never reads the panel (`kit-ax.sh dump panel`)")
        ok(has(t, "pn_searchbox"), "S1.30 does not read the search box's label from the panel tree")
        ok(has(t, "AXList|AXTable|AXOutline"), "S1.30 does not read the result list's label from the panel tree")
        for mockup in ["Search your files", "Results", "Sesame: ready"] {
            ok(t.contains(mockup) || l.contains(mockup.lowercased()), "S1.30 does not know the mockup label \"\(mockup)\"")
        }
        ok(l.contains("noted"), "S1.30 does not say that a different wording is `noted`, not a failure")
        ok(l.contains("empty"), "S1.30 does not say that an empty label is a failure")
        ok(has(l, "bare role|role word"), "S1.30 does not refuse a bare role word as a label")
        ok(has(l, "text field") && has(l, "\\blist\\b"), "S1.30 does not list the role words it refuses (text field, list ...)")
        ok(has(t, "recipe_photos|s1_need_photos|s1_begin[ ]+S1\\.30[ ]+1"), "S1.30 does not start from the recipe `photos`, so the list may not exist")
    }

    // MARK: S1.21 (b) and S8.11

    @Test("S1.21 (b): Delete index and its confirmation, then layout shows no index.sqlite, -wal or -shm within 10 s, startPressed false, text 4 for any text and for none, a relaunch keeps it")
    func s121b() {
        guard let t = inner("S1.21") else { return }
        ok(has(t, click("Settings…")), "S1.21 (b) never opens Settings")
        ok(has(t, click("Delete index…")), "S1.21 (b) never presses \"Delete index…\"")
        ok(has(t, click("Delete index")) || has(t, click("Delete")), "S1.21 (b) never presses the confirmation")
        ok(has(t, privacy("layout")), "S1.21 (b) never reads `kit-privacy.sh layout`")
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] {
            ok(t.contains(name), "S1.21 (b) does not look for \(name) in Sesame's folder")
        }
        ok(has(t, "[^0-9]10[^0-9]"), "S1.21 (b) does not hold the 10 s")
        ok(has(t, index("settings")) && t.contains("startPressed"), "S1.21 (b) does not read that startPressed is false (`kit-index.sh settings`)")
        ok(has(t, "=[ ]*\"?false\\b"), "S1.21 (b) does not require startPressed to read false")
        ok(t.contains("Not ready yet") && t.contains("Nothing is indexed yet"), "S1.21 (b) does not look for \"Not ready yet\" and \"Nothing is indexed yet\"")
        ok(has(t, "pn_ax[ ]+type|\(ax("type"))"), "S1.21 (b) never types a text into the panel (the text 4 must show for any text)")
        ok(has(t, launch("relaunch")), "S1.21 (b) never relaunches (`kit-launch.sh relaunch`)")
        before(t, index("wait[ ]+done[ ]+120"), click("Delete index…"), "S1.21 (b) deletes the index before part (a) finished")
        before(t, click("Delete index…"), launch("relaunch"), "S1.21 (b) relaunches before Delete index")
        if let r = lastIndex(t, launch("relaunch")), let n = lastIndex(t, "Nothing is indexed yet") {
            ok(n > r, "S1.21 (b) does not read the panel again after the relaunch (a relaunch keeps text 4)")
        }
        if let d = firstIndex(t, click("Delete index…")), let p = lastIndex(t, privacy("layout")) {
            ok(p > d, "S1.21 (b) reads `kit-privacy.sh layout` only before it pressed Delete index")
        }
        if let d = firstIndex(t, click("Delete index…")), let c = lastIndex(t, "startPressed") {
            ok(c > d, "S1.21 (b) reads startPressed only before it pressed Delete index")
        }
    }

    @Test("S8.11: after Ready, Delete index and its confirmation, layout shows no index files within 10 s, text 4 for any text and none, a relaunch keeps it; Start indexing brings the index back, at Ready")
    func s811() {
        guard let t = inner("S8.11") else { return }
        ok(has(t, "recipe_photos|s1_need_photos|s1_begin[ ]+S8\\.11[ ]+1"), "S8.11 does not start from the recipe `photos` (after Ready)")
        ok(has(t, ax("read[ ]+menubar")) && t.contains("ready"), "S8.11 never reads that the menu says Ready")
        ok(has(t, click("Settings…")), "S8.11 never opens Settings")
        ok(has(t, click("Delete index…")), "S8.11 never presses \"Delete index…\"")
        ok(has(t, click("Delete index")) || has(t, click("Delete")), "S8.11 never presses the confirmation")
        ok(has(t, privacy("layout")), "S8.11 never reads `kit-privacy.sh layout`")
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] {
            ok(t.contains(name), "S8.11 does not look for \(name) in Sesame's folder")
        }
        ok(has(t, "[^0-9]10[^0-9]"), "S8.11 does not hold the 10 s")
        ok(t.contains("Not ready yet") && t.contains("Nothing is indexed yet"), "S8.11 does not look for \"Not ready yet\" and \"Nothing is indexed yet\"")
        ok(has(t, "pn_ax[ ]+type|\(ax("type"))"), "S8.11 never types a text into the panel (any text must show text 4)")
        ok(has(t, launch("relaunch")), "S8.11 never relaunches (`kit-launch.sh relaunch`)")
        ok(has(t, click("Start indexing")), "S8.11 never presses Start indexing after the relaunch")
        ok(has(t, index("wait[ ]+done")), "S8.11 does not run the index to done again (`kit-index.sh wait done`)")
        before(t, ax("read[ ]+menubar"), click("Delete index…"), "S8.11 deletes the index before it read that the menu says Ready")
        before(t, click("Delete index…"), launch("relaunch"), "S8.11 relaunches before Delete index")
        if let r = firstIndex(t, launch("relaunch")), let s = lastIndex(t, click("Start indexing")) {
            ok(s > r, "S8.11 presses Start indexing only before the relaunch (the recipe's press does not count): indexing must start again after Delete index and a relaunch")
        }
        if let s = lastIndex(t, click("Start indexing")) {
            let after = String(t[t.index(t.startIndex, offsetBy: s)...])
            ok(has(after, index("wait[ ]+done")), "S8.11 does not wait for done after the last Start indexing")
            ok(has(after, "index\\.sqlite"), "S8.11 does not look for index.sqlite coming back after Start indexing")
            ok(has(after, ax("read[ ]+menubar")) && has(after, "[Rr]eady"), "S8.11 does not read Ready after the run")
        }
    }

    // MARK: S1.22 (iii) and (iv)

    @Test("S1.22 (iii): Pause part way, a damaged model planted, text 1 wins over text 3, text 3 returns after the re-download; (iv): Delete index with the model whole shows text 4, not text 2")
    func s122() {
        guard let t = inner("S1.22") else { return }
        ok(has(t, click("Pause indexing")), "S1.22 (iii) never presses \"Pause indexing\" in the status item's menu")
        ok(has(t, fixtures("plant-model[ ]+truncated")), "S1.22 (iii) never plants a damaged model (`kit-fixtures.sh plant-model truncated`)")
        ok(t.contains("The model file was damaged and is downloading again"), "S1.22 (iii) does not look for the damaged-model sentence of text 1")
        ok(has(t, "nr_must_lack[ ]+\"Still indexing\""), "S1.22 (iii) does not require that text 3 (Still indexing) is absent while text 1 shows")
        ok(has(t, launch("start[ ]+--mirror-full")), "S1.22 (iii) does not start the app with the mirror, so the planted file is downloaded again from it")
        ok(has(t, mirror("rate")), "S1.22 (iii) does not set the mirror's rate (slow, so text 1 stays on screen; full, so the download ends)")
        ok(has(t, "nr_models_whole"), "S1.22 (iii) does not wait for the model files to be whole again")
        ok(has(t, click("Delete index…")), "S1.22 (iv) never presses \"Delete index…\"")
        ok(has(t, click("Delete index")) || has(t, click("Delete")), "S1.22 (iv) never presses the confirmation")
        ok(has(t, "nr_must_lack[ ]+\"Indexing has not been started\""), "S1.22 (iv) does not require that text 2 is absent after Delete index")
        before(t, click("Pause indexing"), fixtures("plant-model[ ]+truncated"), "S1.22 (iii) plants the model before the Pause")
        before(t, fixtures("plant-model[ ]+truncated"), click("Delete index…"), "S1.22 (iv) deletes the index before (iii) planted the model")
        if let d = lastIndex(t, click("Delete index…")), let m = lastIndex(t, "nr_must_lack[ ]+\"Indexing has not been started\"") {
            ok(m > d, "S1.22 (iv) requires that text 2 is absent only before Delete index (that is part (i))")
        }
        if let p = lastIndex(t, fixtures("plant-model[ ]+truncated")) {
            let after = String(t[t.index(t.startIndex, offsetBy: p)...])
            ok(has(after, "nr_must_lack[ ]+\"Still indexing\""), "S1.22 (iii) does not require that text 3 is absent after the damaged model was planted (text 1 wins)")
            ok(has(after, "nr_models_whole"), "S1.22 (iii) never waits for the re-download after the plant")
            if let w = firstIndex(after, "nr_models_whole"), let s = lastIndex(after, "Still indexing") {
                ok(s > w, "S1.22 (iii) does not read text 3 (Still indexing) again after the re-download")
            } else {
                ok(false, "S1.22 (iii) does not read text 3 (Still indexing) after the re-download")
            }
        }
        if let d = lastIndex(t, click("Delete index…")), let n = lastIndex(t, "Nothing is indexed yet") {
            ok(n > d, "S1.22 (iv) does not look for \"Nothing is indexed yet\" after Delete index")
        }
        ok(has(t, "Still indexing") && t.contains("The model is still downloading"), "S1.22 lost its slice 1 parts (i) and (ii)")
    }

    // MARK: S1.29

    @Test("S1.29: tab-walk over the panel, every Settings section, the menu and the setup windows; every enabled control reached and focus back at the first")
    func s129() {
        guard let t = inner("S1.29"), let full = check("S1.29") else { return }
        for win in ["panel", "settings", "menu", "setup"] {
            ok(has(t, "nr_walk[ ]+\(win)\\b"), "S1.29 never walks the \(win) with tab-walk (`nr_walk \(win)`)")
        }
        ok(has(full, "tab-walk"), "S1.29 never runs `kit-ax.sh tab-walk`")
        ok(has(t.lowercased(), "section"), "S1.29 does not walk the Settings sections one by one")
        ok(count(t, "nr_walk[ ]+settings") >= 1 && has(t, "click[ ]+\"\\$"), "S1.29 does not press each Settings section's own label before it walks it")
        ok(has(t, "recipe_setup"), "S1.29 does not start the setup windows from the recipe `setup`")
        ok(has(t, click("Next")), "S1.29 does not press Next to walk each setup step")
        ok(has(full, "not reached"), "S1.29 does not report the controls that Tab never reached")
        ok(has(full, "focus did not return to the first control"), "S1.29 does not hold that focus returns to the first control after a cycle")
        ok(has(t, "front-sesame|picker_front|pn_wait_sesame_front|nr_settings_open"), "S1.29 does not bring Sesame to the front before it presses Tab")
        before(t, "nr_walk[ ]+panel", "nr_walk[ ]+menu", "S1.29 walks the menu before the panel")
        before(t, "nr_walk[ ]+menu", "nr_walk[ ]+setup", "S1.29 walks the setup windows before the menu (the setup state replaces the app)")
        if let walk = allFunctions()["nr_walk"] {
            let w = substitute(walk, topLevelValues())
            if let m = firstIndex(w, "=[ ]*menu"), let s = firstIndex(w, "shift\\+tab") {
                ok(m < s, "nr_walk posts Shift+Tab in a menu, which Tab and Shift+Tab do not move through")
            } else {
                ok(false, "nr_walk does not leave the Shift+Tab pass out for the menu")
            }
        }
    }

    // MARK: the recipe photos

    @Test("the recipe photos waits for kit-index.sh wait done and then for the menu to say Ready (from slice 2); the picker fallback is unchanged")
    func recipePhotos() {
        guard let t = contract(of: "recipe_photos") else { return }
        ok(has(t, index("wait[ ]+done[ ]+900")), "recipe photos no longer waits for `kit-index.sh wait done`")
        ok(has(t, ax("read[ ]+menubar")), "recipe photos does not read the status item (`kit-ax.sh read menubar`)")
        ok(has(t.lowercased(), "ready"), "recipe photos never waits for the menu to say Ready")
        before(t, index("wait[ ]+done[ ]+900"), ax("read[ ]+menubar"), "recipe photos waits for the menu before the index is done")
        ok(has(t, "KIT_SLICE[^ ]*[ ]+-ge[ ]+2"), "recipe photos waits for the menu in slice 1 too, where there is no menu bar (verify.md, Starting state, Recipes)")
        ok(has(t, "pick_folders[ ]+golden[ ]+golden/photos"), "recipe photos does not pick golden and golden/photos through the picker")
        ok(has(t, "NEEDS A PERSON: pick these folders"), "recipe photos lost the fallback that asks the person to pick the folders")
        ok(has(t, "nowait"), "recipe photos lost --no-wait")
        if let n = firstIndex(t, "\\(--no-wait\\)"), let w = firstIndex(t, index("wait[ ]+done[ ]+900")) {
            ok(n < w, "--no-wait no longer returns before the waits")
        } else {
            ok(false, "recipe photos no longer says `(--no-wait)` before it waits")
        }
    }

    // MARK: verify.sh --quick

    @Test("verify.sh --quick runs the status item check (kit-ax.sh read menubar, non-empty) from slice 2, before the Library scan")
    func verifyQuickStatusItem() {
        guard let code = scriptCode("verify.sh") else { Issue.record("scripts/verify.sh not found"); return }
        let functions = shellFunctions(in: code)
        guard let fn = functions["check_status_item"] else {
            Issue.record("verify.sh defines no check_status_item")
            return
        }
        ok(has(fn, ax("read[ ]+menubar")), "check_status_item never reads the status item (`kit-ax.sh read menubar`)")
        ok(has(fn, "-n[ ]+\"\\$[A-Za-z_]+\""), "check_status_item does not require the label to be non-empty")
        ok(fn.contains("CHECK status-item PASS") && fn.contains("CHECK status-item FAIL"), "check_status_item does not print PASS and FAIL for the id status-item")
        ok(has(fn, "NEEDS-A-PERSON"), "check_status_item does not print NEEDS-A-PERSON when Accessibility is missing")
        guard let main = functions["main"] else { Issue.record("verify.sh defines no main"); return }
        let lines = main.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let i = lines.firstIndex(where: { $0.contains("check_status_item") }) else {
            Issue.record("verify.sh main never runs check_status_item")
            return
        }
        ok(lines[max(0, i - 1)...i].contains(where: { has($0, "\"\\$SLICE\"[ ]+-ge[ ]+2") }), "check_status_item runs in slice 1, where there is no menu bar")
        let quick = lines[...i].reversed().first(where: { $0.contains("quick = 1") })
        ok(quick != nil, "check_status_item is not in the --quick branch of verify.sh")
        before(main, "check_status_item", "run_check[ ]+S8\\.12", "check_status_item runs after S8.12, which quits the app and deletes its folder")
        if let smoke = lastIndex(main, "check_smoke"), let status = firstIndex(main, "check_status_item") {
            ok(smoke < status, "check_status_item runs before the smoke")
        }
        ok(has(code, "QUICK_FLOOR=3"), "the --quick floor changed")
    }

    // MARK: the Doctor

    @Test("the Doctor pings kit-load, kit-volume, kit-power, kit-trace and kit-privacy, prints no `not built yet` for them, reads the status item and counts a missing administrator session from slice 2")
    func doctor() {
        guard let code = scriptCode("kit-doctor.sh") else { Issue.record("scripts/kit-doctor.sh not found"); return }
        let scripts = ["kit-load.sh", "kit-volume.sh", "kit-power.sh", "kit-trace.sh", "kit-privacy.sh"]
        for s in scripts {
            ok(has(code, "ping_driver[ ]+[01][ ]+\(NSRegularExpression.escapedPattern(for: s))[ ]+ping"), "the Doctor does not ping \(s)")
            let path = scriptsDir.appendingPathComponent(s).path
            ok(FileManager.default.isExecutableFile(atPath: path), "scripts/\(s) is not an executable file, so the Doctor would print `not built yet` for it")
            let named = code.split(separator: "\n").filter { $0.contains("not built yet") && $0.contains(s) }
            ok(named.isEmpty, "the Doctor prints `not built yet` for \(s)")
        }
        ok(has(code, "ping_driver[ ]+1[ ]+kit-trace\\.sh") && has(code, "ping_driver[ ]+1[ ]+kit-privacy\\.sh") && has(code, "ping_driver[ ]+1[ ]+kit-power\\.sh"),
           "the Doctor does not mark the trace, privacy and power pings as needing administrator rights")
        let functions = shellFunctions(in: code)
        guard let ping = functions["ping_driver"] else { Issue.record("the Doctor defines no ping_driver"); return }
        ok(has(ping, "first needed in slice 2"), "ping_driver lost the slice 1 report `administrator rights, first needed in slice 2`")
        ok(has(ping, "KIT_SLICE[^ ]*[ ]+-lt[ ]+2"), "ping_driver still excuses a missing administrator session from slice 2 on, where the checks need it (verify.md, Doctor, step 1)")
        guard let start = functions["step_start"] else { Issue.record("the Doctor defines no step_start"); return }
        let withStatus = substitute(expandShell(start, functions, skipping: ["step_start"]), topLevelValues())
        ok(has(withStatus, ax("read[ ]+menubar")), "the Doctor never reads the status item (`kit-ax.sh read menubar`) after the app starts")
        ok(has(withStatus, "KIT_SLICE[^ ]*[ ]+-ge[ ]+2"), "the Doctor reads the status item in slice 1, which has no menu bar")
        before(withStatus, "kit-launch\\.sh[ ]+start[ ]+--mirror-full", ax("read[ ]+menubar"), "the Doctor reads the status item before it started the app")
    }

    // MARK: the floor and the slice

    // plan-4-t3 (amended by the tester, reason: slice 4 is built): `<= 4`, was `<= 3`, and the recount 79 (see `recountedFloor`); the
    // administrator list and every other pin are unchanged.
    @Test("checks.floor is the number of auto ids of slices 1 to 4 that need no administrator rights, every one of them has a defined function, and the floor counts PASS only")
    func floorIsTheCount() {
        guard let rows = tsvRows() else { return }
        guard let floorText = read(libDir.appendingPathComponent("checks.floor")) else { Issue.record("checks.floor not found"); return }
        let floor = Int(floorText.trimmingCharacters(in: .whitespacesAndNewlines))
        ok(floor != nil && floorText.split(separator: "\n").count == 1, "checks.floor is not one number: \(floorText.debugDescription)")
        // plan-3-t12b: `<= 3`, was `<= 2` (slice 3 adds twelve auto ids; see `recountedFloor`); plan-4-t3: `<= 4`
        // plan-5-t1b (amended by the tester, reason: slice 5 is built): `<= 5`, was `<= 4`, and the recount 86 (see `recountedFloor`)
        let auto = rows.filter { $0.kind == "auto" && (Int($0.slice) ?? 99) <= 5 }.map(\.id)
        ok(Set(auto).count == auto.count, "checks.tsv holds an auto id of slices 1 to 5 twice")
        // the ids whose check, as the shell runs it, primes or uses the administrator session. plan-3-t12b adds the file trace and the
        // network summary (which reads a trace) to the signs; a call through `tree_need`, `s8_activity` or `s8_close_window` is not one
        // (`checkLeavingSessionCalls`), because they ask for the administrator session only when a trace ran (plan-3 D15).
        // A reading of the trace is the sign, not a `kit-trace.sh start`: every recipe has a `--trace` branch that starts one, and a recipe
        // without that flag starts none, so the word `kit-trace.sh` alone would list every check that begins from a recipe.
        let traceReads = "kit-trace\\.sh\"?[ ]+(opens|writes|by-process|net)\\b"
        let primes = "ask-admin|\\bsudo\\b|kit-power\\.sh\"?[ ]+lowpower|kit-privacy\\.sh\"?[ ]+login-item"
        let summary = "\\bs8_net_summary\\b"
        // Two ids carry one sign each and stay counted, by the plan's own decision (plan-3 D15; the entry counts both in the 70):
        //  - S8.1 reads `kit-trace.sh writes` only to name who wrote a `.DS_Store` difference, and only when a trace ran (`[ -z "$trace" ]`
        //    skips it); with no administrator session no trace ran, and the sums comparison, which is the verdict, needs none.
        //  - S8.13 calls `s8_net_summary` for its net-log part from slice 3 (plan-3-t11's stand-in leaves that call alone for the same
        //    reason); its layout, plist, Start flag, mirror-log and Library parts pass with no administrator session.
        // Any other sign in either, or either sign in any other id, makes the id an administrator id and fails the comparison below.
        let carriesTraceReadOnly: Set<String> = ["S8.1"]
        let carriesSummaryOnly: Set<String> = ["S8.13"]
        var admin: Set<String> = []
        for id in auto {
            guard let t = checkLeavingSessionCalls(id) else { continue }
            if has(t, primes)
                || (has(t, traceReads) && !carriesTraceReadOnly.contains(id))
                || (has(t, summary) && !carriesSummaryOnly.contains(id)) { admin.insert(id) }
        }
        ok(admin == adminIds, "the auto ids of slices 1 to 3 that need administrator rights are \(admin.sorted()), the test expects \(adminIds.sorted())")
        for id in ["S8.2", "S8.3", "S8.7", "S6.13"] {
            guard let t = checkLeavingSessionCalls(id) else { continue }
            ok(has(t, "\(traceReads)|\\bs8_net_summary\\b"), "\(id) is on the administrator list but reads neither the trace (kit-trace.sh opens, writes, by-process or net) nor s8_net_summary")
        }
        let autoCounted = auto.filter { !adminIds.contains($0) }
        ok(autoCounted.count == recountedFloorAtSlice5, "the auto ids of slices 1 to 5 without administrator rights are \(autoCounted.count), the hand recount is \(recountedFloorAtSlice5)")
        ok(!rows.contains { $0.id.hasPrefix("S5.") }, "checks.tsv still holds an S5 id")
        let counted = autoCounted + slice6NewIds + slice7NewIds + slice8NewIds
        ok(rows.filter { $0.slice == "7" && $0.kind == "auto" }.map(\.id) == slice7NewIds, "the auto rows of slice 7 are not S9.1 to S9.5")
        ok(rows.filter { $0.slice == "8" && $0.kind == "auto" }.map(\.id) == slice8NewIds, "the auto rows of slice 8 are not S10.5 and S10.8 (plan-8-t9 amended: floor 91 + 2 = 93)")
        ok(counted.count == recountedFloor, "the recount from checks.tsv is \(counted.count) auto ids without administrator rights, the test recounted \(recountedFloor) by hand")
        ok(floor == counted.count, "checks.floor reads \(floor.map(String.init) ?? "nothing"), the number of auto ids of slices 1 to 4 that need no administrator rights is \(counted.count)")
        let functions = allFunctions()
        for id in counted {
            ok(functions[checkFunctionName(id)] != nil, "\(id) is counted by the floor but has no function \(checkFunctionName(id))")
        }
        ok((floor ?? 0) >= 7, "checks.floor was lowered below the 7 of slice 1")
        guard let runner = scriptCode("kit-run.sh") else { Issue.record("kit-run.sh not found"); return }
        ok(has(runner, "\\[[ ]+\"\\$p\"[ ]+-ge[ ]+\"\\$floor\"[ ]+\\]"), "the runner does not compare the passes (not passes plus needs-a-person) with the floor")
        ok(has(runner, "needs-a-person does not count"), "the runner no longer says that needs-a-person does not count toward the floor")
    }

    // plan-3-t12b: was `sliceIsTwo` expecting 2. Plan 3 builds slice 3, so the kit now runs the ids of slices 1 to 3.
    // plan-4-t3 (amended by the tester, reason: plan 4 builds slice 4, so the kit now runs the ids of slices 1 to 4): `slice` holds 4, was 3.
    // The quick-run guard test below is not amended: its pins (S8.10 runs only below KIT_SLICE 3, QUICK_FLOOR 3) hold at slice 4.
    // plan-5-t1b (amended by the tester, reason: plan 5 builds slice 5, so the kit now runs the ids of slices 1 to 5): `slice` holds 5, was 4.
    // The quick-run guard test below is not amended: its pins (S8.10 runs only below KIT_SLICE 3, QUICK_FLOOR 3) hold at slice 5.
    // plan-6-t1 part F, second half (amended by the tester, reason: plan 6 builds slice 6, so the kit now runs the ids of slices 1 to 6): `slice`
    // holds 6, was 5. The quick-run guard test below is not amended: its pins (S8.10 runs only below KIT_SLICE 3, QUICK_FLOOR 3) hold at slice 6.
    @Test("slice holds 8")
    func sliceIsSeven() {
        let text = read(libDir.appendingPathComponent("slice"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        ok(text == "8", "scripts/kit-lib/slice holds \(text.map { "\"\($0)\"" } ?? "nothing"), expected 8")
    }

    // MARK: verify.sh --quick at slice 3 (plan-3-t12b)

    @Test("verify.sh --quick runs S8.10 only while KIT_SLICE is below 3; at slice 3 and above it prints one plain line that the S8.10 session parts (tcc and prompts) are read in the full run; QUICK_FLOOR stays 3")
    func verifyQuickS810Guard() {
        guard let code = scriptCode("verify.sh") else { Issue.record("scripts/verify.sh not found"); return }
        guard let main = shellFunctions(in: code)["main"] else { Issue.record("verify.sh defines no main"); return }
        let lines = main.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let runs = lines.indices.filter { has(lines[$0], "run_check[ ]+S8\\.10[ ]+check_S8_10\\b") }
        ok(runs.count == 1, "verify.sh main runs `run_check S8.10 check_S8_10` \(runs.count) times, expected once")
        guard let i = runs.first else { return }
        // the nearest guard above the run is on KIT_SLICE (the slice the check itself reads), not on the --slice argument
        guard let g = lines[..<i].lastIndex(where: { has($0, "KIT_SLICE") }) else {
            ok(false, "the S8.10 run in the --quick branch has no guard on KIT_SLICE: at slice 3 it would print RERUN (no session functions run in --quick)")
            return
        }
        let guardLine = lines[g]
        let between = Array(lines[(g + 1)..<i])
        if has(guardLine, "\\[[ ]+\"\\$KIT_SLICE\"[ ]+-ge[ ]+3[ ]+\\]") {
            guard let e = between.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "else" }) else {
                ok(false, "the S8.10 run is not in the else of `[ \"$KIT_SLICE\" -ge 3 ]`, so it runs at slice 3")
                return
            }
            let plain = between[..<e].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ok(plain.count == 1, "the slice 3 branch holds \(plain.count) lines, expected one plain line")
            if let line = plain.first {
                ok(has(line, "^[ ]*echo[ ]") && !has(line, "run_check|skip[ ]|FAIL|RERUN"), "the slice 3 line is not a plain echo (a skip would fail the quick run): \(line)")
                ok(line.contains("S8.10") && line.contains("tcc") && line.contains("prompts") && has(line, "full run"),
                   "the slice 3 line does not say that the S8.10 session parts (tcc and prompts) are read in the full run: \(line)")
            }
        } else if has(guardLine, "\\[[ ]+\"\\$KIT_SLICE\"[ ]+-lt[ ]+3[ ]+\\]") {
            ok(!between.contains { has($0, "^[ ]*(else|fi)\\b") }, "the S8.10 run is outside the `[ \"$KIT_SLICE\" -lt 3 ]` guard")
            let after = lines[(i + 1)...]
            let say = after.first(where: { has($0, "^[ ]*echo[ ]") && $0.contains("S8.10") && $0.contains("tcc") && $0.contains("prompts") && has($0, "full run") })
            ok(say != nil, "no plain echo after the guard says that the S8.10 session parts (tcc and prompts) are read in the full run")
        } else {
            ok(false, "the nearest KIT_SLICE line above the S8.10 run is not the guard `[ \"$KIT_SLICE\" -ge 3 ]` or `-lt 3`: \(guardLine)")
        }
        ok(has(code, "QUICK_FLOOR=3"), "QUICK_FLOOR changed: build, bundle, plus S8.4 or the smoke is still 3")
    }

    // MARK: kit-perms.sh check-id table (plan-3-t12b)

    /// What `keys_for` of kit-perms.sh says for an id, read as text only (the script is never run): the first case line whose
    /// pattern matches, the words of its `echo`.
    private func permKeys(_ id: String) -> Set<String>? {
        guard let text = scriptCode("kit-perms.sh"), let body = shellFunctions(in: text)["keys_for"] else {
            Issue.record("kit-perms.sh has no keys_for function")
            return nil
        }
        for line in body.split(separator: "\n").map(String.init) {
            guard let g = groups(line, "^[ ]*([^ ()]+)\\)[ ]+echo[ ]+\"([^\"]*)\"").first, g.count == 2 else { continue }
            let patterns = g[0].split(separator: "|").map { p -> String in
                p.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "*", with: ".*")
            }
            if patterns.contains(where: { has(id, "^" + $0 + "$") }) {
                return Set(g[1].split(separator: " ").map(String.init))
            }
        }
        Issue.record("kit-perms.sh keys_for has no line for \(id)")
        return nil
    }

    @Test("kit-perms.sh check-id table at slice 3: S8.1, S8.5, S8.6, S8.9 need accessibility, screen recording and System Events; S8.10 needs fda; S6.13, S8.2, S8.3, S8.7 need admin; S2.2, S2.3, S2.8, S2.17 need those three and the model")
    func permsTableAtSlice3() {
        let three: Set<String> = ["accessibility", "screen", "sysevents"]
        for id in ["S8.1", "S8.5", "S8.6", "S8.9"] {
            if let k = permKeys(id) { ok(k == three, "kit-perms.sh `check --for \(id)` names \(k.sorted()), expected accessibility, screen, sysevents") }
        }
        if let k = permKeys("S8.10") { ok(k == ["fda"], "kit-perms.sh `check --for S8.10` names \(k.sorted()), expected fda (the tcc part reads the permission database)") }
        for id in ["S6.13", "S8.2", "S8.3", "S8.7"] {
            if let k = permKeys(id) { ok(k == ["admin"], "kit-perms.sh `check --for \(id)` names \(k.sorted()), expected admin") }
        }
        for id in ["S2.2", "S2.3", "S2.8", "S2.17"] {
            if let k = permKeys(id) { ok(k == three.union(["model"]), "kit-perms.sh `check --for \(id)` names \(k.sorted()), expected accessibility, screen, sysevents, model") }
        }
    }

    // MARK: all of the six

    @Test("no check of the six edits settings.json, the index or a preference, and every sudo is sudo -n", arguments: allIds)
    func readsOnlyAndSudoN(_ id: String) {
        guard let t = check(id) else { return }
        ok(!has(t, "sqlite3") && !has(t, "plutil") && !has(t, "defaults[ ]+write"), "\(checkFunctionName(id)) edits state with sqlite3, plutil or defaults instead of steps a person has")
        ok(!has(t, ">>?[ ]*\"?[^ \"]*settings\\.json") && !has(t, "(rm|mv|cp)[ ][^\\n]*(settings\\.json|index\\.sqlite)"), "\(checkFunctionName(id)) writes or removes settings.json or the index")
        ok(!has(t, "\\bsudo\\b(?![ ]+-n\\b)"), "\(checkFunctionName(id)) calls sudo without -n")
    }

    @Test("no check of the six, nor the runner, reads Sources/", arguments: allIds)
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

    @Test("each check prints its id on a CHECK line and can be planted (a wrong shortcut posted, so it must print FAIL planted)", arguments: allIds)
    func printsAndPlants(_ id: String) {
        guard let t = check(id) else { return }
        ok(t.contains(id), "\(checkFunctionName(id)) never names \(id) on a CHECK line")
        ok(has(t, "CHECK[ ]+(\\$id|\(NSRegularExpression.escapedPattern(for: id)))[ ]+(PASS|\\$1)|CHECK \\$1 FAIL"), "\(checkFunctionName(id)) prints no CHECK \(id) PASS line")
        ok(has(t, "S1_WHAT=\"[^\"]+\""), "\(checkFunctionName(id)) names no planted input (S1_WHAT=\"...\"), so `kit-run.sh --plant \(id)` could never show a FAIL planted line")
        ok(has(t, "\\bKIT_PLANT\\b"), "\(checkFunctionName(id)) never looks at KIT_PLANT")
    }

    @Test("an exit 4 is a rerun, never a pass or a fail: each check names RERUN <id> and returns 4 when a precondition did not hold", arguments: allIds)
    func rerunOnInvalid(_ id: String) {
        guard let t = check(id) else { return }
        ok(has(t, "RERUN[ ]+(\\$id|\\$1|\(NSRegularExpression.escapedPattern(for: id)))") && has(t, "return[ ]+4|S1_RC=4"), "\(checkFunctionName(id)) has no `RERUN \(id) not valid: <reason>` path that returns 4")
    }

    @Test("the checks that press Delete index do it as a person does (Settings, the label, the confirmation) and never press Quit or the battery override", arguments: ["S1.21", "S1.22", "S8.11"])
    func deleteLikeAPerson(_ id: String) {
        guard let t = check(id) else { return }
        ok(!has(t, "click[ ]+\"(Quit Sesame|Resume anyway)"), "\(checkFunctionName(id)) presses Quit Sesame or the battery override")
        ok(has(t, click("Settings…")), "\(checkFunctionName(id)) does not reach Delete index through the menu's \"Settings…\"")
    }
}

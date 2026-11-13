import Foundation
import Testing

// plan-6-t1 part F, second half, as amended by plan-7-t7: `check_S2_15` (scripts/kit-lib/checks-s2e.sh), the S2.8 and S2.17 pins of
// checks-s2c.sh, the code cells of `check_S8_5` / `check_S8_6` (checks-s8c.sh), the saver that keeps the GOLDEN lines of a run past the
// next reset (`golden_save_lines`, kit-lib/golden.sh), the floor 86 and slice 6. Static and child-process proof only: nothing here runs
// kit-run.sh, verify.sh, kit-search.sh, kit-ax.sh, kit-golden.sh or any script that drives an app. S2.15 reads the copies that
// golden_save_lines keeps in $KIT_ROOT/golden-kept/<mode>-<group>.txt, groups a to d, window 3.

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let scriptsDir = projectRoot.appendingPathComponent("scripts")
private let libDir = scriptsDir.appendingPathComponent("kit-lib")
private let checkFile = libDir.appendingPathComponent("checks-s2e.sh")
private let newIds = ["S2.15"]

// MARK: helpers

private struct Ran {
    let status: Int32
    let output: String
}

private func run(_ exe: String, _ args: [String], limit: TimeInterval = 120) throws -> Ran {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun2e-out-" + UUID().uuidString)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: out) }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment
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

private func groups(_ text: String, _ pattern: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (1..<max(m.numberOfRanges, 1)).map { i in
            m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : ""
        }
    }
}

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

private func checkFunctionName(_ id: String) -> String { "check_" + id.replacingOccurrences(of: ".", with: "_") }
private func logicName(_ id: String) -> String { "s2e_check_" + String(id.dropFirst(3)) }

private func logic(_ id: String) -> String? {
    guard let text = allFunctions()[logicName(id)] else {
        Issue.record(Comment(rawValue: "\(logicName(id)) is not defined in scripts/kit-lib/checks-*.sh"))
        return nil
    }
    return text
}

private func tsvRows() -> [(id: String, slice: String, kind: String)] {
    guard let text = read(libDir.appendingPathComponent("checks.tsv")) else { Issue.record("checks.tsv not found"); return [] }
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return f.count >= 3 ? (f[0], f[1], f[2]) : nil
    }
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitrun2e-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sesame-kit-t/run"), withIntermediateDirectories: true)
    return dir
}

private func put(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func one(_ ran: Ran) -> String { ran.output.trimmingCharacters(in: .whitespacesAndNewlines) }
private func lines(_ ran: Ran) -> [String] { ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

/// What kit-run.sh does: common.sh, recipes.sh, then every checks-*.sh.
private let prelude = """
. '\(libDir.path)/common.sh' && . '\(libDir.path)/recipes.sh'
for f in '\(libDir.path)'/checks-*.sh; do [ -f "$f" ] && . "$f"; done
"""

private func pure(_ call: String, in dir: URL, stdin: String? = nil, extra: String = "") throws -> Ran {
    var input = ""
    if let stdin {
        let f = dir.appendingPathComponent("stdin.txt")
        try put(stdin, f)
        input = " < '\(f.path)'"
    }
    let script = """
    export KIT_ROOT='\(dir.path)/sesame-kit-t'; \(prelude)
    \(extra)
    { \(call); }\(input)
    """
    return try run("/bin/bash", ["-c", script])
}

/// Runs a check in a child bash with the driving layer replaced by `stubs`; prints the check's lines, then `RC=<status>`.
private func check(_ id: String, in dir: URL, stubs: String, plant: Bool = false, then: String = "") throws -> (lines: [String], rc: Int?) {
    let script = """
    export KIT_ROOT='\(dir.path)/sesame-kit-t'; \(prelude)
    \(plant ? "KIT_PLANT=1" : "KIT_PLANT=")
    golden_need() { return 0; }; s1_cleanup() { :; }; nr_cleanup() { :; }; sleep() { :; }
    \(stubs)
    \(checkFunctionName(id)); echo "RC=$?"
    \(then)
    """
    let ran = try run("/bin/bash", ["-c", script])
    let all = ran.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let rcLine = all.last { $0.hasPrefix("RC=") }
    return (all, rcLine.flatMap { Int($0.dropFirst(3)) })
}

private func verdict(_ lines: [String], _ id: String) -> String? {
    for l in lines {
        let f = l.split(separator: " ", maxSplits: 3).map(String.init)
        if f.count >= 3, f[0] == "CHECK", f[1] == id { return f[2] }
    }
    return nil
}

private func joined(_ lines: [String]) -> String { lines.joined(separator: "\n") }

// MARK: shape of the files, the table, the floor and the slice

@Suite("KitRunS2eChecksTests", .serialized)
struct KitRunS2eChecksTests {
    @Test("checks-s2e.sh exists, parses with bash -n, defines check_S2_15 once in no other kit file, defines none of the removed S2.6, S2.7 and S2.16, and holds no top-level command")
    func oneFunction() throws {
        guard FileManager.default.fileExists(atPath: checkFile.path) else { Issue.record("scripts/kit-lib/checks-s2e.sh does not exist"); return }
        let syntax = try run("/bin/bash", ["-n", checkFile.path])
        ok(syntax.status == 0, "bash -n checks-s2e.sh: \(syntax.output)")
        for id in newIds {
            let name = checkFunctionName(id)
            var where_: [String] = []
            for (file, code) in kitShellSources() where shellFunctions(in: code)[name] != nil { where_.append(file) }
            ok(where_ == ["kit-lib/checks-s2e.sh"], "\(name) is defined in \(where_), expected exactly kit-lib/checks-s2e.sh")
        }
        for id in ["S2.6", "S2.7", "S2.16"] {
            ok(allFunctions()[checkFunctionName(id)] == nil, "\(checkFunctionName(id)) is still defined")
        }
        guard let text = read(checkFile) else { return }
        var depth = 0
        var strays: [String] = []
        for line in stripComments(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if depth == 0, !line.trimmingCharacters(in: .whitespaces).isEmpty,
               !has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#) {
                strays.append(line)
            }
            if has(line, #"^[A-Za-z_][A-Za-z0-9_]*\(\) \{"#), !has(line, #"\}$"#) { depth += 1 }
            if line == "}" { depth = max(0, depth - 1) }
        }
        ok(strays.isEmpty, "checks-s2e.sh runs code when it is sourced: \(strays.prefix(3))")
    }

    @Test("checks.tsv holds S2.15 once, at slice 6, kind auto, and none of S1.25, S2.6, S2.7, S2.16 or S5.1 to S5.15")
    func registered() {
        let rows = tsvRows()
        let mine = rows.filter { $0.id == "S2.15" }
        ok(mine.count == 1, "S2.15 has \(mine.count) rows in checks.tsv")
        ok(mine.first?.slice == "6", "S2.15 is slice \(mine.first?.slice ?? "none"), expected 6")
        ok(mine.first?.kind == "auto", "S2.15 kind is \(mine.first?.kind ?? "none")")
        for id in ["S1.25", "S2.6", "S2.7", "S2.16"] + (1...15).map({ "S5.\($0)" }) {
            ok(!rows.contains { $0.id == id }, "\(id) is still in checks.tsv")
        }
    }

    @Test("slice holds 8 and checks.floor is 93: the 85 auto ids of slices 1 to 5 without administrator rights, S2.15, the one id of slice 6, the five auto S9 ids of slice 7 and the two auto S10 ids of slice 8, counted by name (plan-8-t9 amended: S10.5 and S10.8 added, floor 91 + 2, slice 7 to 8)")
    func floorAndSlice() {
        ok(read(libDir.appendingPathComponent("slice"))?.trimmingCharacters(in: .whitespacesAndNewlines) == "8", "scripts/kit-lib/slice does not hold 8")
        let floor = Int((read(libDir.appendingPathComponent("checks.floor")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        ok(floor == 93, "checks.floor reads \(floor.map(String.init) ?? "nothing"), the recount is 85 + 1 + 5 + 2 = 93")
        let rows = tsvRows()
        let slice6 = Set(rows.filter { $0.slice == "6" }.map(\.id))
        ok(slice6 == ["S2.15"], "the slice 6 rows are \(slice6.sorted()), the one id counted by name is S2.15")
        let admin: Set<String> = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]
        let counted = rows.filter { $0.kind == "auto" && (Int($0.slice) ?? 99) <= 5 && !admin.contains($0.id) }
        ok(counted.count == 85, "the auto ids of slices 1 to 5 without administrator rights are \(counted.count), expected 85")
        ok(!counted.contains { $0.id == "S6.9" }, "S6.9 is still counted")
    }

    // MARK: where S2.15 starts

    @Test("S2.15 reads files only: no golden_need, no kit script, no search, no group e")
    func starts() {
        guard let t = logic("S2.15") else { return }
        ok(!has(t, #"golden_need|\bkq\b|s1_kq|s1_search|s5_search|kit-[a-z]+\.sh"#), "S2.15 starts the app or a kit script: it reads the saved files only (a golden_need would reset the kit and delete them)")
        ok(has(t, #"for g in a b c d; do"#) && !has(t, #"for g in a b c d e"#), "S2.15 does not loop over groups a to d only")
    }

    // MARK: pure readers

    @Test("s2e_hits <file> <window> counts the ranks inside the window (the last line of an id counts; none, a word or a rank beyond the window is no hit; page and second columns are ignored): `<hits> <rows>`")
    func hits() throws {
        let dir = try scratch()
        let f = dir.appendingPathComponent("lines.txt")
        try put("VERSION v1\nGOLDEN a1 rank 1\nGOLDEN a2 rank 3 page 4\nGOLDEN a3 rank 4\nGOLDEN a4 rank none\nGOLDEN a5 rank 2 second 30\nGOLDEN a5 rank 9\nGOLDEN refreshAccessToken defined first yes\nGOLDEN plain no-code 10 of 10\nGOLDEN langs swift definition 1 callers 20\n", f)
        let w3 = try pure("s2e_hits '\(f.path)' 3", in: dir)
        ok(one(w3) == "2 5", "window 3 printed \(one(w3)), expected `2 5` (a1 and a2 hit; a3 rank 4, a4 none, a5 last line rank 9 do not)")
        let w5 = try pure("s2e_hits '\(f.path)' 5", in: dir)
        ok(one(w5) == "3 5", "window 5 printed \(one(w5)), expected `3 5`")
        let missing = try pure("s2e_hits '\(dir.path)/nope.txt' 3", in: dir)
        ok(one(missing) == "0 0", "a missing file printed \(one(missing)), expected `0 0`")
    }

    @Test("s2e_diff_rows <engine> <panel> <window> prints `<id> engine=<rank> panel=<rank>` for each id that is a hit on one side only, rank none when a side has no line")
    func diffRows() throws {
        let dir = try scratch()
        let e = dir.appendingPathComponent("e.txt"), p = dir.appendingPathComponent("p.txt")
        try put("VERSION v\nGOLDEN r1 rank 1\nGOLDEN r2 rank 2\nGOLDEN r3 rank none\nGOLDEN r4 rank 1\n", e)
        try put("VERSION v\nGOLDEN r1 rank 1\nGOLDEN r2 rank 7\nGOLDEN r3 rank 3\nGOLDEN r5 rank 1\n", p)
        let r = try pure("s2e_diff_rows '\(e.path)' '\(p.path)' 3", in: dir)
        ok(lines(r) == ["r2 engine=2 panel=7", "r3 engine=none panel=3", "r4 engine=1 panel=none", "r5 engine=none panel=1"], "s2e_diff_rows printed \(lines(r))")
    }

    @Test("s2e_saved_file <mode> <group> is $KIT_ROOT/golden-kept/<mode>-<group>.txt and s2e_saved_version reads its VERSION line")
    func savedFile() throws {
        let dir = try scratch()
        let r = try pure("s2e_saved_file panel c; echo; s2e_saved_version '\(dir.path)/v.txt'", in: dir, extra: "printf 'VERSION 1.2.3\\nGOLDEN x rank 1\\n' > '\(dir.path)/v.txt'")
        ok(r.output.hasPrefix("\(dir.path)/sesame-kit-t/golden-kept/panel-c.txt\n"), "s2e_saved_file printed \(r.output.debugDescription)")
        ok(r.output.hasSuffix("1.2.3\n"), "s2e_saved_version printed \(r.output.debugDescription)")
    }

    // MARK: golden_save_lines keeps a copy past the next reset

    @Test("golden_save_lines keeps run/golden-lines-<mode>-<group>.txt as before (GOLDEN lines only) and a copy in golden-kept/<mode>-<group>.txt that starts with `VERSION <run/version>`; a later run replaces both; no run/version gives `VERSION none`; a reset of run/ leaves the copy")
    func saverKeeps() throws {
        let dir = try scratch()
        let kit = dir.appendingPathComponent("sesame-kit-t")
        try put("2.0.1\n", kit.appendingPathComponent("run/version"))
        let r = try pure("golden_save_lines engine e \"$(printf 'noise\\nGOLDEN code-01 rank 2\\nFAIL x\\nGOLDEN code-02 rank none')\"; golden_save_lines panel e 'GOLDEN code-01 rank 1'", in: dir)
        ok(r.status == 0, "golden_save_lines failed: \(r.output)")
        ok(read(kit.appendingPathComponent("run/golden-lines-engine-e.txt")) == "GOLDEN code-01 rank 2\nGOLDEN code-02 rank none\n", "the run/ file changed: \(String(describing: read(kit.appendingPathComponent("run/golden-lines-engine-e.txt"))))")
        ok(read(kit.appendingPathComponent("golden-kept/engine-e.txt")) == "VERSION 2.0.1\nGOLDEN code-01 rank 2\nGOLDEN code-02 rank none\n", "the kept copy is \(String(describing: read(kit.appendingPathComponent("golden-kept/engine-e.txt"))))")
        try FileManager.default.removeItem(at: kit.appendingPathComponent("run"))
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("run"), withIntermediateDirectories: true)
        ok(read(kit.appendingPathComponent("golden-kept/panel-e.txt")) == "VERSION 2.0.1\nGOLDEN code-01 rank 1\n", "the kept panel copy did not survive a reset of run/")
        let again = try pure("golden_save_lines panel e 'GOLDEN code-01 rank 4'", in: dir)
        ok(again.status == 0, "a second save failed: \(again.output)")
        ok(read(kit.appendingPathComponent("golden-kept/panel-e.txt")) == "VERSION none\nGOLDEN code-01 rank 4\n", "a later run did not replace the copy, or the missing run/version was not `none`: \(String(describing: read(kit.appendingPathComponent("golden-kept/panel-e.txt"))))")
    }

    // MARK: S2.15

    private func saved(_ dir: URL, _ mode: String, _ group: String, _ ranks: [Int?], version: String = "v1") throws {
        var t = "VERSION \(version)\n"
        for (i, r) in ranks.enumerated() { t += "GOLDEN \(group)\(i + 1) rank \(r.map(String.init) ?? "none")\n" }
        try put(t, dir.appendingPathComponent("sesame-kit-t/golden-kept/\(mode)-\(group).txt"))
    }

    private func allGroups(_ dir: URL, panel: [String: [Int?]] = [:], engine: [String: [Int?]] = [:], leftoverGroupE: Bool = false) throws {
        let base: [Int?] = [1, 1, 2, 3, 1, 2, 1, 3, 1, 1]
        for g in ["a", "b", "c", "d"] {
            try saved(dir, "engine", g, engine[g] ?? base)
            try saved(dir, "panel", g, panel[g] ?? base)
        }
        if leftoverGroupE {
            try saved(dir, "engine", "e", base)
            try saved(dir, "panel", "e", Array(repeating: nil, count: 10))
        }
        try put("v1\n", dir.appendingPathComponent("sesame-kit-t/run/version"))
    }

    @Test("S2.15: a gap of at most 1 hit in every group a to d passes with no note; a gap of 2 or more in a group prints `noted: engine and app diverge` with the rows that differ and still passes as noted; the figures of groups a to d are printed and no group e is read")
    func s215Gap() throws {
        let dir = try scratch()
        try allGroups(dir, panel: ["b": [1, 1, 2, 3, 1, 2, 1, 3, 1, nil]])
        let ok1 = try check("S2.15", in: dir, stubs: "")
        ok(verdict(ok1.lines, "S2.15") == "PASS" && ok1.rc == 0, "a gap of 1 in group b: \(ok1.lines)")
        ok(!joined(ok1.lines).contains("noted"), "a gap of 1 must print no note: \(ok1.lines)")
        for g in ["a", "b", "c", "d"] { ok(joined(ok1.lines).contains("group \(g)"), "the figures of group \(g) are not printed: \(ok1.lines)") }
        ok(!joined(ok1.lines).contains("group e"), "group e is named with no group e saved: \(ok1.lines)")
        let dir2 = try scratch()
        try allGroups(dir2, panel: ["c": [1, 1, 2, nil, nil, 9, 1, 3, 1, 1]])
        let r = try check("S2.15", in: dir2, stubs: "")
        let text = joined(r.lines)
        ok(verdict(r.lines, "S2.15") == "PASS" && r.rc == 0, "a gap of 3 is noted, never a failure: \(r.lines)")
        ok(text.contains("noted: engine and app diverge"), "the note is missing: \(r.lines)")
        ok(text.contains("c4 engine=3 panel=none") && text.contains("c5 engine=1 panel=none") && text.contains("c6 engine=2 panel=9"), "the rows that differ are not printed: \(r.lines)")
        ok(!text.contains("c1 engine"), "a row that agrees was printed as a difference: \(r.lines)")
        let dir3 = try scratch()
        try allGroups(dir3, leftoverGroupE: true)
        let e = try check("S2.15", in: dir3, stubs: "")
        ok(verdict(e.lines, "S2.15") == "PASS" && !joined(e.lines).contains("noted") && !joined(e.lines).contains("group e"), "a group e left in golden-kept/ with a gap of 10 must be ignored: \(e.lines)")
        let dir4 = try scratch()
        try allGroups(dir4, panel: ["a": [1, 1, 5, 5, 1, 1, 1, 1, 1, 1]])
        let w = try check("S2.15", in: dir4, stubs: "")
        ok(joined(w.lines).contains("noted: engine and app diverge") && joined(w.lines).contains("group a"), "ranks 4 and 5 are no hit in group a (window 3): \(w.lines)")
    }

    @Test("S2.15: a group with no saved run on either side, a file with no GOLDEN rank line, or a side saved under another version than the other (or than run/version) is exit 4 with no verdict, never a pass")
    func s215Missing() throws {
        for (what, mutate): (String, (URL) throws -> Void) in [
            ("no panel file for group c", { dir in try FileManager.default.removeItem(at: dir.appendingPathComponent("sesame-kit-t/golden-kept/panel-c.txt")) }),
            ("no engine file for group a", { dir in try FileManager.default.removeItem(at: dir.appendingPathComponent("sesame-kit-t/golden-kept/engine-a.txt")) }),
            ("a panel file with no rank line", { dir in try put("VERSION v1\nGOLDEN plain no-code 10 of 10\n", dir.appendingPathComponent("sesame-kit-t/golden-kept/panel-d.txt")) }),
            ("an empty engine file", { dir in try put("", dir.appendingPathComponent("sesame-kit-t/golden-kept/engine-b.txt")) }),
            ("the two sides under two versions", { dir in try saved(dir, "panel", "b", [1, 1, 2, 3, 1, 2, 1, 3, 1, 1], version: "v0") }),
            ("both sides under an older version than run/version", { dir in
                try saved(dir, "panel", "b", [1, 1, 2, 3, 1, 2, 1, 3, 1, 1], version: "v0")
                try saved(dir, "engine", "b", [1, 1, 2, 3, 1, 2, 1, 3, 1, 1], version: "v0")
            }),
        ] {
            let dir = try scratch()
            try allGroups(dir)
            try mutate(dir)
            let r = try check("S2.15", in: dir, stubs: "")
            ok(r.rc == 4 && verdict(r.lines, "S2.15") == nil && r.lines.contains { $0.hasPrefix("RERUN S2.15 not valid:") }, "\(what): expected exit 4 and a RERUN line, got \(r.lines)")
        }
        let none = try scratch()
        try put("v1\n", none.appendingPathComponent("sesame-kit-t/run/version"))
        let r = try check("S2.15", in: none, stubs: "")
        ok(r.rc == 4 && verdict(r.lines, "S2.15") == nil, "no saved run at all must be exit 4: \(r.lines)")
        for g in ["a", "b", "c", "d"] { ok(joined(r.lines).contains("group \(g)"), "the RERUN line does not name group \(g): \(r.lines)") }
        ok(!joined(r.lines).contains("group e"), "the RERUN line names group e: \(r.lines)")
    }

    @Test("S2.15's gap rule is `-gt 1`: a mutation to `-gt 2` or `-ge 1` makes the gap tests red (the rule is read from the kit, never copied into the test)")
    func s215RuleText() {
        guard let t = allFunctions()["s2e_check_15"] else { Issue.record("s2e_check_15 is not defined"); return }
        ok(has(t, #"-gt[ ]+1\b"#) || has(allFunctions()["s2e_compare_group"] ?? "", #"-gt[ ]+1\b"#), "the gap rule `-gt 1` is not in s2e_check_15 or s2e_compare_group")
    }

    @Test("S2.17 searches the bare stem of every extension, never `code: <stem>`, and its failure still names the extension")
    func s217NoCode() {
        guard let t = allFunctions()["s2c_check_17"] else { Issue.record("s2c_check_17 is not defined"); return }
        ok(!has(t, #"s2c_search_text|code: "#), "S2.17 still types a code: search")
        ok(has(t, #"s1_search[ ]+"\$name""#), "S2.17 does not search the bare stem for every extension")
        ok(has(t, #"extension[ ]+\$\{?[A-Za-z_]+\}?"#), "S2.17's failure does not name the extension")
    }

    // MARK: S8.5 and S8.6 code cells

    @Test("s8c_query <kind> <text> prints the text itself for every kind, the kind code included: no `code: ` prefix (plan-7-t10 amended: code: is plain text now)")
    func s8Query() throws {
        let dir = try scratch()
        for (kind, expected) in [("code", "code_zq0007"), ("photo", "code_zq0007"), ("document", "code_zq0007"), ("pdf", "code_zq0007"), ("audio", "code_zq0007"), ("unsupported", "code_zq0007")] {
            let r = try pure("s8c_query \(kind) code_zq0007", in: dir)
            ok(one(r) == expected, "s8c_query \(kind) printed \(one(r)), expected \(expected)")
        }
    }

    @Test("S8.5 searches the stem and the token of a code cell with the `code: ` prefix (s8c_query), S8.6 does the same for its positive control, and neither writes a kind")
    func s8Text() {
        let all = allFunctions()
        guard let m = all["s8c_matrix"], let c = all["check_S8_6"] else { Issue.record("s8c_matrix or check_S8_6 is not defined"); return }
        ok(has(m, #"s8c_query[ ]+"\$kind"[ ]+"\$stem""#), "s8c_matrix does not search the stem with s8c_query")
        ok(has(m, #"s8c_query[ ]+"\$kind"[ ]+"\$tok""#), "s8c_matrix does not search the token with s8c_query")
        ok(has(c, #"s8c_query"#), "check_S8_6 does not search its positive control with s8c_query")
    }
}

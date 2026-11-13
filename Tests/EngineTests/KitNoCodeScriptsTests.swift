import Foundation
import Testing

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private func scriptText(_ name: String) -> String { KC.read(KC.scripts + "/" + name) ?? "" }
private func libText(_ name: String) -> String { KC.read(KC.lib + "/" + name) ?? "" }

private func noCommentLines(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private struct Kit {
    let root: String
    let tmp: String
    var env: [String: String] { ["KIT_ROOT": root, "TMPDIR": tmp + "/", "HOME": tmp + "/decoy-home"] }
}

private func makeKit() throws -> Kit {
    let base = try KC.tempDir("kit-nocode-")
    let kit = Kit(root: base + "/sesame-kit", tmp: base + "/tmp")
    for dir in [kit.root + "/run", kit.tmp, kit.tmp + "/decoy-home"] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    return kit
}

private func script(_ name: String, _ args: [String], in kit: Kit) throws -> KC.Ran {
    try KC.run("/bin/bash", [KC.scripts + "/" + name] + args, env: kit.env, limit: 60)
}

private func textFilesUnderScripts() -> [(path: String, text: String)] {
    var found: [(String, String)] = []
    guard let walker = FileManager.default.enumerator(atPath: KC.scripts) else { return found }
    for case let rel as String in walker {
        let full = KC.scripts + "/" + rel
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
        if let text = KC.read(full) { found.append((rel, text)) }
    }
    return found
}

private let goldenUsageHand = [
    "usage: kit-golden.sh engine [--group a|b|c|d] [--min-first N] [--from <file>]",
    "       kit-golden.sh panel [--group a|b|c|d] [--min-first N] [--from <file>]",
    "       kit-golden.sh prepare [--whole]",
    "       kit-golden.sh prepare [--all]",
    "       kit-golden.sh index-state [--whole]",
    "       kit-golden.sh index-state [--all]",
    "       kit-golden.sh merge [--from <file>] | extensions",
]

@Suite("plan-7-t9: no kit script can still read, ping, list or build code")
struct KitNoCodeScriptsTests {
    @Test("kit-golden.sh has no --code, no group e, no code-only, no golden_indexed_code and no language matrix, in code or in its header")
    func goldenText() {
        let text = scriptText("kit-golden.sh")
        ok(!text.isEmpty, "kit-golden.sh not found")
        for pattern in ["--code\\b", "code-only", "code_only", "golden_indexed_code", "golden_code_", "index_state_code", "prepare_code_run", "GOLDEN_MARK_CODE",
                        "panel_has_code", "GroupETests", "group e", "group_e", "report_e", "langs", "golden-code", "golden-index-code", "--code-folders"] {
            ok(!KC.has(text, pattern), "kit-golden.sh still matches /\(pattern)/")
        }
        for name in ["prepare_run", "prepare_whole_run", "prepare_all_run", "golden_indexed_whole", "golden_indexed_all", "merge_run", "extensions_run", "engine_group_c", "engine_group_d", "panel_group_c", "panel_group_d"] {
            ok(KC.has(text, "(^|\\n)" + name + "\\(\\)"), "kit-golden.sh lost \(name)")
        }
    }

    @Test("golden.sh has no group e lines, no language scoring and no code group")
    func goldenLibText() {
        let text = libText("golden.sh")
        for pattern in ["golden_langs_score", "golden_line_e", "golden_score_e", "langs", "group e"] {
            ok(!KC.has(text, pattern), "golden.sh still matches /\(pattern)/")
        }
        ok(!KC.has(text, "e\\) echo \"code\""), "golden_kinds still maps a group e to the code rows")
        ok(KC.has(text, "golden_built\\(\\) \\{ \\[ \"\\$1\" = a \\] \\|\\| \\[ \"\\$1\" = b \\] \\|\\| \\[ \"\\$1\" = c \\] \\|\\| \\[ \"\\$1\" = d \\]; \\}"), "golden_built is not exactly groups a, b, c and d")
    }

    @Test("kit-golden.sh refuses prepare --code, index-state --code, code-only and any group e with exit 2 and the usage, and starts nothing")
    func goldenRefuses() throws {
        let kit = try makeKit()
        let from = kit.tmp + "/lines.txt"
        try KC.write(from, "GOLDEN audio-01 rank 1 second 130\n")
        let calls: [[String]] = [["prepare", "--code"], ["index-state", "--code"], ["code-only"], ["code-only", "--from", from],
                                 ["engine", "--group", "e"], ["panel", "--group", "e"], ["engine", "--group", "e", "--from", from]]
        for args in calls {
            let ran = try script("kit-golden.sh", args, in: kit)
            ok(ran.status == 2, "kit-golden.sh \(args.joined(separator: " ")): exit \(ran.status), expected 2:\n\(ran.output)")
            ok(KC.lines(ran.output) == goldenUsageHand, "kit-golden.sh \(args.joined(separator: " ")) printed:\n\(ran.output)")
        }
    }

    @Test("merge prints the RANK lines and exits with the test's status: a language line in the output is ignored and no language verdict is printed")
    func mergeHasNoLanguageLine() throws {
        let kit = try makeKit()
        let ranks = ["RANK exact-01 1 odd", "RANK exact-02 3 even", "RANK photo-01 none odd"]
        let plain = kit.tmp + "/plain.txt"
        try KC.write(plain, ranks.joined(separator: "\n") + "\n")
        let a = try script("kit-golden.sh", ["merge", "--from", plain], in: kit)
        ok(a.status == 0 && KC.lines(a.output) == ranks, "merge on RANK lines: exit \(a.status):\n\(a.output)")
        let withLangs = kit.tmp + "/with-langs.txt"
        try KC.write(withLangs, (ranks + ["GOLDEN langs py definition 1 callers none", "GOLDEN langs sh definition 2 callers 40"]).joined(separator: "\n") + "\n")
        let b = try script("kit-golden.sh", ["merge", "--from", withLangs], in: kit)
        ok(b.status == 0 && KC.lines(b.output) == ranks, "merge with language lines in the output: exit \(b.status):\n\(b.output)")
        let none = kit.tmp + "/none.txt"
        try KC.write(none, "GOLDEN langs py definition 1 callers none\n")
        let c = try script("kit-golden.sh", ["merge", "--from", none], in: kit)
        ok(c.status == 1 && c.output.contains("MergeTests printed no RANK line") && !c.output.contains("langs"), "merge with no RANK line: exit \(c.status):\n\(c.output)")
    }

    @Test("langs.tsv is deleted and no file under scripts names it, the langs folder, build langs or the language matrix")
    func noLangsAnywhere() {
        ok(!FileManager.default.fileExists(atPath: KC.lib + "/langs.tsv"), "scripts/kit-lib/langs.tsv still exists")
        let files = textFilesUnderScripts()
        ok(files.count > 50, "the scan read only \(files.count) files under scripts")
        for (path, text) in files {
            for word in ["langs.tsv", "fixtures/langs", "build langs", "golden_langs_score", "LANGS_EXTS", "lang_def_text", "lang_caller"] {
                ok(!text.contains(word), "scripts/\(path) still says \(word)")
            }
        }
        ok(!noCommentLines(libText("checks-s2c.sh")).contains("langs"), "checks-s2c.sh still reads the languages")
    }

    @Test("kit-fixtures.sh build langs exits 2 with the usage, which lists no langs build; the other builds stay listed")
    func fixturesBuildLangs() throws {
        let kit = try makeKit()
        let ran = try script("kit-fixtures.sh", ["build", "langs"], in: kit)
        ok(ran.status == 2, "build langs: exit \(ran.status):\n\(ran.output)")
        ok(ran.output.contains("usage: kit-fixtures.sh ping"), "build langs did not print the usage:\n\(ran.output)")
        ok(!ran.output.replacingOccurrences(of: "build langs:", with: "").contains("langs"), "the usage or the message for build langs still lists langs:\n\(ran.output)")
        for build in ["golden", "golden-docs", "boundary", "golden-av", "tree", "matrix", "repos", "unrelated <n>"] {
            ok(ran.output.contains("kit-fixtures.sh build \(build)"), "the usage lost build \(build)")
        }
        ok(!FileManager.default.fileExists(atPath: kit.root + "/fixtures/langs"), "build langs made fixtures/langs")
    }

    @Test("expect extensions no longer reads fixtures/langs: a stale langs folder is not a FOUND file")
    func expectExtensionsIgnoresLangs() throws {
        let kit = try makeKit()
        try KC.write(kit.root + "/fixtures/langs/py/checksum.py", "def computeChecksum(data):\n    return 0\n")
        let ran = try script("kit-fixtures.sh", ["expect", "extensions", "--kinds", "code"], in: kit)
        ok(!ran.output.contains("langs/py/checksum.py") && ran.output.contains("MISSING code py"), "expect extensions read a code file in fixtures/langs:\n\(ran.output)")
    }

    @Test("kit-readback.sh has no vscode-line, no ping vscode, no VS Code and no editor half; ping takes finder, preview and quicktime only")
    func readbackHasNoEditor() throws {
        let text = scriptText("kit-readback.sh")
        for word in ["vscode", "VS Code", "VSCode", "vs_live", "vs_reading", "com.microsoft", "code command", "AXManualAccessibility"] {
            ok(!text.contains(word), "kit-readback.sh still says \(word)")
        }
        let kit = try makeKit()
        for args in [["ping", "vscode"], ["vscode-line", "retry.swift"], ["vscode-line", "retry.swift", "--from", kit.tmp + "/none"]] {
            let ran = try script("kit-readback.sh", args, in: kit)
            ok(ran.status == 2, "kit-readback.sh \(args.joined(separator: " ")): exit \(ran.status), expected 2:\n\(ran.output)")
            ok(ran.output.hasPrefix("usage: kit-readback.sh ping finder|preview|quicktime\n"), "kit-readback.sh \(args.joined(separator: " ")) printed:\n\(ran.output)")
            ok(!ran.output.contains("vscode"), "the usage still says vscode:\n\(ran.output)")
        }
    }

    @Test("kit-doctor.sh pings finder, preview and quicktime through kit-readback.sh and no VS Code, and checks no editor")
    func doctorPingsNoEditor() {
        let text = scriptText("kit-doctor.sh")
        for word in ["vscode", "VS Code", "VSCode", "Visual Studio"] { ok(!text.contains(word), "kit-doctor.sh still says \(word)") }
        let pings = KC.lines(text).compactMap { line -> String? in
            guard let r = line.range(of: "ping_driver [01] kit-readback.sh ping ", options: .regularExpression) else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        ok(pings == ["finder", "preview", "quicktime"], "kit-doctor.sh pings through kit-readback.sh: \(pings)")
        ok(KC.has(text, "ping_driver 0 kit-ax.sh ping") && KC.has(text, "ping_driver 0 kit-probe.sh ping"), "kit-doctor.sh lost another ping")
    }

    @Test("kit-perms.sh has no vscode step, no vscode key and no S5 mapping, and the other steps stay")
    func permsHasNoEditor() {
        let text = scriptText("kit-perms.sh")
        for word in ["vscode", "VS Code", "VSCode", "Visual Studio", "code command", "S5."] { ok(!text.contains(word), "kit-perms.sh still says \(word)") }
        for step in ["step_accessibility", "step_screen", "step_model", "step_sqlite", "step_tool \"ffmpeg\""] { ok(text.contains(step), "kit-perms.sh lost \(step)") }
    }

    @Test("kit-launch.sh helper rejects --code-folders with exit 2 and the usage, which no longer lists it; --read-folders is still taken")
    func launchHelperFolders() throws {
        let kit = try makeKit()
        let ran = try script("kit-launch.sh", ["helper", "index", "--code-folders", "home/Developer/api-client"], in: kit)
        ok(ran.status == 2, "helper --code-folders: exit \(ran.status), expected 2:\n\(ran.output)")
        let usageLine = "       kit-launch.sh helper [<mode>] [--folders <fixture-dir>...] [--read-folders <path under the kit root>...] [--stdin <file>] [--no-model] [--fake-embedder]"
        ok(KC.lines(ran.output).contains(usageLine), "the usage line of helper is not the hand line:\n\(ran.output)")
        ok(!ran.output.contains("code-folders"), "the usage still lists --code-folders:\n\(ran.output)")
        let read = try script("kit-launch.sh", ["helper", "index", "--read-folders", "home/Developer/api-client"], in: kit)
        ok(read.status == 1 && !read.output.contains("usage:"), "helper --read-folders: exit \(read.status):\n\(read.output)")
        let text = scriptText("kit-launch.sh")
        for word in ["--code-folders", "@code:", "codeflag=true"] { ok(!text.contains(word), "kit-launch.sh still says \(word)") }
    }

    private static let distinct20 = [
        "a dog on the beach", "the clause about pets in the lease", "where they talk about sleep", "zebra in a video", "a snow covered mountain",
        "a birthday cake with candles", "a city skyline at night", "a sailboat at sunset",
        "ERR_CONNECTION_RESET", "INV-2026-04417", "Q3-board-deck.pdf", "zq-lantern-4471", "PNR-XJ29KD", "DSC_20260311_0042.jpg", "tax-return-2025-draft.pdf",
        "a red sports car", "a field of sunflowers", "tacos on a street food stand", "an elephant in the grassland", "a steam train",
    ]
    private static let distinct20b = [
        "a race car on a grey road", "a locomotive under clouds", "three sunflowers on green grass", "an elephant on grass with a tree",
        "tacos with chili and avocado", "a cake with lit candles and balloons", "tall buildings under a night sky", "a dog walking on sand",
        "BX-204-RETURN", "trk-9921-WQ", "HR-POLICY-2025-REV3", "WARRANTY-MS-4410", "db-replica-lag-17s", "PO-7781-ZETA", "sleep-interview.m4a",
        "waves and a sun on sand", "pine trees on a snowy mountain", "a grey road with a race car", "balloons and a cake", "a moon over buildings",
    ]

    @Test("queries-distinct20 and distinct20b hold no code: line and no tab: each former code: line is its plain stand-in, in the same place")
    func queryFiles() {
        for (name, want) in [("queries-distinct20.txt", Self.distinct20), ("queries-distinct20b.txt", Self.distinct20b)] {
            let text = libText(name)
            ok(!text.contains("code:") && !text.contains("\t"), "\(name) still holds a code: text or a tab")
            ok(!KC.has(text, "slice 6|partial"), "\(name) still talks of slice 6 or partial")
            let entries = KC.lines(text).filter { !$0.hasPrefix("#") }
            ok(entries == want, "\(name) holds \(entries)")
        }
    }

    @Test("load_queries gives the twenty plain queries of each set at slice 5 and 6 alike and holds no partial note")
    func loadQueries() throws {
        let probe = scriptText("kit-probe.sh")
        for word in ["QPARTIAL", "note: partial", "before slice 6", "KIT_SLICE\" -ge 6"] { ok(!probe.contains(word), "kit-probe.sh still says \(word)") }
        let body = KC.shellFunction("load_queries", in: probe) ?? ""
        ok(!body.isEmpty, "kit-probe.sh has no load_queries")
        let kit = try makeKit()
        for slice in ["5", "6"] {
            for (set, want) in [("distinct20", Self.distinct20), ("distinct20b", Self.distinct20b)] {
                let ran = try KC.bash("""
                \(body)
                KIT_SLICE=\(slice)
                load_queries \(set) 20; echo "RC $?"
                for q in "${QUERIES[@]}"; do printf '%s\\n' "$q"; done
                """, kit: kit.root)
                ok(KC.lines(ran.output) == ["RC 0"] + want, "load_queries \(set) at slice \(slice):\n\(ran.output)")
            }
        }
    }

    @Test("S2.10 has no branch for a probe that says partial: the probe never says it")
    func noPartialBranch() {
        let text = libText("checks-s2.sh")
        ok(!text.contains("note: partial"), "checks-s2.sh still reads a probe's `note: partial`")
        ok(text.contains("s2_unread()"), "checks-s2.sh lost s2_unread, which counts pending or partial files")
    }
}

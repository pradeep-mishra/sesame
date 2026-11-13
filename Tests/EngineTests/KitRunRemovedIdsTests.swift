import Foundation
import Testing

private let removedIds = (1...15).map { "S5.\($0)" } + ["S1.25", "S2.6", "S2.7", "S2.16", "S6.9"]

private let removedFunctions = (1...15).flatMap { ["check_S5_\($0)", "s5_check_\($0)"] }
    + ["check_S1_25", "s1_check_25", "check_S2_6", "check_S2_7", "check_S2_16", "s2e_check_6", "s2e_check_7", "s2e_check_16", "check_S6_9", "s6_check_9"]

private let onlyTheRemovedChecksUsed = ["s2e_group_e", "s2e_figs", "s2e_figures", "s2e_summary_line", "s2e_distinct_codes", "s6b_code_problems", "s2c_langs_line", "s2c_search_text"]

private let adminIds = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]

private let awk = "/usr/bin/awk"

private func tsv() -> String { KC.read(KC.lib + "/checks.tsv") ?? "" }

private func awkOut(_ program: String, _ file: String) throws -> String {
    try KC.run(awk, ["-F", "\t", program, file]).output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func kitScripts() -> [(name: String, text: String)] {
    var names = ["kit-run.sh", "kit-perms.sh", "verify.sh"].map { KC.scripts + "/" + $0 }
    let lib = ((try? FileManager.default.contentsOfDirectory(atPath: KC.lib)) ?? []).filter { $0.hasSuffix(".sh") }.sorted()
    names += lib.map { KC.lib + "/" + $0 }
    return names.compactMap { path in KC.read(path).map { (path, $0) } }
}

private func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
}

@Suite("KitRunRemovedIdsTests")
struct KitRunRemovedIdsTests {
    @Test("checks.tsv holds none of the 20 removed ids, and its own awk recount is 121 rows: 98 auto, 17 auto-or-person, 6 reading (plan-8-t9 amended: S10.1 to S10.9 added, two auto and seven person ids; was 112 96 10 6)")
    func tableLosesTheTwentyIds() throws {
        let ids = Set(KC.checksTSV().map(\.id))
        #expect(removedIds.count == 20 && Set(removedIds).count == 20, "the hand list does not hold 20 distinct ids")
        #expect(ids.intersection(removedIds).isEmpty, "checks.tsv still holds \(ids.intersection(removedIds).sorted())")
        let counts = try awkOut(#"{ n++; k[$3]++ } END { printf "%d %d %d %d\n", n, k["auto"], k["auto-or-person"], k["reading"] }"#, KC.lib + "/checks.tsv")
        #expect(counts == "121 98 17 6", "rows, auto, auto-or-person, reading are \(counts), the hand count is 121 98 17 6")
        let twice = try awkOut(#"seen[$1]++ { d++ } END { print d + 0 }"#, KC.lib + "/checks.tsv")
        #expect(twice == "0", "checks.tsv holds an id twice")
    }

    @Test("the ids of each scenario are counted by hand: S1 29, S2 14, S3 10, S4 10, S5 0, S6 12, S7 18, S8 13, S9 6, S10 9 (plan-8-t9 amended: S10 added)")
    func idsPerScenario() throws {
        let out = try awkOut(#"{ split($1, a, "."); s[a[1]]++ } END { for (x in s) print x, s[x] }"#, KC.lib + "/checks.tsv")
        let got = Dictionary(uniqueKeysWithValues: out.split(separator: "\n").map { l -> (String, Int) in
            let f = l.split(separator: " ")
            return (String(f[0]), Int(f[1]) ?? -1)
        })
        #expect(got == ["S1": 29, "S2": 14, "S3": 10, "S4": 10, "S6": 12, "S7": 18, "S8": 13, "S9": 6, "S10": 9], "ids per scenario: \(got)")
    }

    @Test("checks.floor is 93 (the 98 auto rows less the five administrator ids), at most the number of auto rows, and slice is 8 (plan-8-t9 amended: the two auto ids S10.5 and S10.8 are added, so 91 + 2; was 91 and slice 7)")
    func floorIsNinetyOne() throws {
        let floor = Int((KC.read(KC.lib + "/checks.floor") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let notAdmin = adminIds.map { "$1 != \"\($0)\"" }.joined(separator: " && ")
        let counted = try awkOut("$3 == \"auto\" && \(notAdmin) { n++ } END { print n + 0 }", KC.lib + "/checks.tsv")
        let autos = try awkOut(#"$3 == "auto" { n++ } END { print n + 0 }"#, KC.lib + "/checks.tsv")
        #expect(floor == 93, "checks.floor reads \(floor.map(String.init) ?? "nothing"), the floor is 91 plus the two S10 auto ids = 93")
        #expect(counted == "93", "auto rows without administrator rights are \(counted), the hand count is 93")
        #expect(Int(autos) == 98 && (floor ?? 999) <= (Int(autos) ?? 0), "the floor \(floor.map(String.init) ?? "nothing") is above the \(autos) auto rows")
        #expect((KC.read(KC.lib + "/slice") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "8", "slice does not hold 8")
    }

    @Test("checks-s5.sh is gone and no kit script defines or calls a function of a removed id or a helper only those checks used")
    func noFunctionOfARemovedId() {
        #expect(!FileManager.default.fileExists(atPath: KC.lib + "/checks-s5.sh"), "scripts/kit-lib/checks-s5.sh still exists")
        for (name, text) in kitScripts() {
            let body = code(text)
            for fn in removedFunctions + onlyTheRemovedChecksUsed {
                let named = KC.has(body, "\\b" + fn + "\\b")
                #expect(!named, "\(name) still names \(fn)")
            }
            let s5 = KC.has(body, "\\bs5_[a-z_]+\\b|\\bS5_[A-Z_]+\\b")
            #expect(!s5, "\(name) still names an s5_ function or S5_ variable")
        }
    }

    @Test("kit-run.sh no longer dispatches S5, and every removed id is an unknown id: exit 2 with the usage line, nothing started")
    func dispatchRefusesTheRemovedIds() throws {
        let cases: [[String]] = [["S5", "--ids", "S5.1"], ["S5"], ["S5", "--plant", "S5.5"], ["S1", "--ids", "S1.25"], ["S2", "--ids", "S2.6"], ["S2", "--ids", "S2.7,S2.8"], ["S2", "--ids", "S2.16"], ["S6", "--ids", "S6.9"], ["S2", "--plant", "S2.16"]]
        for args in cases {
            let kit = try KC.kitRoot()
            let r = try KC.run(KC.scripts + "/kit-run.sh", args, env: ["KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1"])
            #expect(r.status == 2, "kit-run.sh \(args.joined(separator: " ")) exited \(r.status): \(r.output)")
            #expect(r.output.contains("usage: kit-run.sh <S1..S4|S6..S10|all>"), "kit-run.sh \(args.joined(separator: " ")) printed no usage line without S5: \(r.output)")
            #expect(!r.output.contains("CHECK ") && !r.output.contains("app was not running"), "kit-run.sh \(args.joined(separator: " ")) started a check: \(r.output)")
        }
    }

    @Test("kit-perms.sh has no S5.* mapping and its other mappings are as they were")
    func permsHasNoS5() {
        let text = code(KC.read(KC.scripts + "/kit-perms.sh") ?? "")
        let keys = KC.shellFunction("keys_for", in: text) ?? ""
        #expect(!keys.isEmpty, "kit-perms.sh has no keys_for")
        #expect(!KC.has(keys, "S5"), "keys_for still maps S5: \(keys)")
        for line in ["S1.9|S1.10|S1.15) echo \"accessibility screen sysevents finder\"", "S3.*) echo \"accessibility screen sysevents finder preview\"", "S4.8) echo \"accessibility screen sysevents quicktime speech admin\"", "S6.8) echo \"accessibility screen sysevents admin\"", "S8.10) echo \"fda\""] {
            #expect(keys.contains(line), "keys_for lost `\(line)`")
        }
    }

    @Test("S2.15 reads groups a to d only")
    func s215() {
        let e = code(KC.read(KC.lib + "/checks-s2e.sh") ?? "")
        let s215 = KC.shellFunction("s2e_check_15", in: e) ?? ""
        #expect(s215.contains("for g in a b c d; do") && !KC.has(s215, #"for g in a b c d e"#), "S2.15 does not loop over groups a to d: \(s215.prefix(200))")
        #expect(!e.contains("e) echo 5"), "s2e_window still has a group e")
    }

    @Test("S2.17 lists no code extension: it types the bare stem for every extension and takes its extensions of the five read kinds")
    func s217ListsNoCode() throws {
        let c = code(KC.read(KC.lib + "/checks-s2c.sh") ?? "")
        let s217 = KC.shellFunction("s2c_check_17", in: c) ?? ""
        #expect(!s217.isEmpty, "s2c_check_17 is not defined")
        #expect(!s217.contains("code: ") && !s217.contains("s2c_search_text") && !s217.contains("code extensions"), "S2.17 still searches a code extension as code:")
        #expect(KC.has(s217, #"s1_search[ ]+"\$name""#), "S2.17 does not search the bare stem")
        let kit = try KC.kitRoot()
        let r = try KC.bash(#"s2c_ext_cells "$(golden_read_kinds)" | awk -F'\t' '{ print $1 }'"#, kit: kit)
        let photo = ["jpeg", "jpg", "png", "heic", "webp", "tiff", "tif", "gif"], document = ["txt", "md", "rtf", "docx", "html", "odt"], audio = ["mp3", "m4a", "wav", "aac", "flac"], video = ["mp4", "mov", "m4v"]
        let want = Set(photo + document + audio + video + ["pdf"])
        #expect(Set(KC.lines(r.output)) == want && KC.lines(r.output).count == 23, "the extensions S2.17 walks are \(KC.lines(r.output).sorted()), the 23 of the five kinds are \(want.sorted())")
    }

    @Test("S6.8 never presses the code switch: its driver and its verdict say nothing of code")
    func s68PressesNoSwitch() {
        let s = code(KC.read(KC.lib + "/checks-s6b.sh") ?? "")
        let body = KC.shellFunction("s6_check_8", in: s) ?? ""
        #expect(!body.isEmpty, "s6_check_8 is not defined")
        #expect(!body.lowercased().contains("code"), "S6.8 still names code: \(body.lowercased().components(separatedBy: "code").count - 1) times")
        #expect(body.contains("click \"Next\"") && body.contains("click \"Finish\"") && body.contains("pick_folders extra"), "S6.8 lost a setup step")
    }

    @Test("the verify.md slice 6 line says S5 is set aside and names no removed id as run; the slice 2 line no longer runs S6.9")
    func verifyMdLines() {
        let md = KC.read(KC.root.path + "/.ril/docs/verification/verify.md") ?? ""
        let lines = md.components(separatedBy: "\n")
        let six = lines.first { $0.hasPrefix("- Slice 6 ") } ?? ""
        let two = lines.first { $0.hasPrefix("- Slice 2 ") } ?? ""
        #expect(!six.isEmpty && !two.isEmpty, "verify.md has no slice 6 or slice 2 line")
        #expect(six.contains("S5 is set aside"), "the slice 6 line does not say S5 is set aside: \(six)")
        #expect(!KC.has(six, #"S5\.[0-9]|S1\.25|S2\.6\b|S2\.7\b|S2\.16\b|S6\.9\b"#), "the slice 6 line still names a removed id: \(six)")
        #expect(!KC.has(two, #"S6\.9\b|S6\.8 to S6\.10"#), "the slice 2 line still runs S6.9: \(two)")
    }
}

import Foundation
import Testing

// plan-6-t9, tester step, part E: `kit-run.sh batches` and `kit-run.sh batch <letter> [--unattended]`. Written from the entry plan-6-t9
// (part E, review 2) of plan-6-tasks.md.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - The table is scripts/kit-lib/batches.tsv (hand-written; kinds `batch <letter> <name> <launches> <real app>`, `run <letter> <command>`,
//     `say <letter> <text>`); the code is scripts/kit-lib/batches.sh, sourced by kit-run.sh.
//   - `kit-run.sh batches` prints, per batch: `BATCH <letter> <name>: launches <n|many>: <ids, comma separated, or none>`, then its lines
//     (`  run: <command>`, `  say: <text>`), for a real-app batch `  run it as: caffeinate -dimsu env KIT_TYPE_DELAY_MS=80 KIT_PICK_WAIT=30
//     scripts/kit-run.sh batch <letter> [--unattended]`, then `  last took <h:mm:ss>` or `  not run yet`. It starts nothing.
//   - `kit-run.sh batch <letter>` prints the same BATCH line first (so the launch count is read before anything runs), then `RUN <command>` per
//     line and the command's output, and ends `BATCH <letter> took <h:mm:ss>` (the script's own clock), appending `<letter> TAB <h:mm:ss> TAB <date>`
//     to run/batch-times.tsv and to batch-kept/batch-times.tsv (a reset deletes run/, and the listing reads the kept copy).
//   - Exit 3 (a person is needed) stops a batch in both modes; exit 4 (not valid: rerun) stops it only with --unattended; both print
//     `STOPPED <id> exit <n> after <h:mm:ss>` and no `took` line and append nothing. An attended run goes on after exit 4 and says
//     `NOTE <id> exit 4`. Exit 1 (a check failed) never stops a batch. The status is the stop's, else 1 after any exit 1 or skipped rerun, else 0.
//   - The seam: KIT_BATCH_BIN is the folder the run lines call their scripts from (a stub script that logs its arguments and exits as a test says).
//   - The id of a stop is the first `NOT PRINTED (rerun): <id>` or `RERUN <id> ...` in the command's output, else the first id of the line.
// Red before the kit part: `batches` and `batch` are unknown modes (usage, exit 2).

private let kitRun = KC.scripts + "/kit-run.sh"

private struct Rig {
    let bin: String
    let log: String
    let kit: String
    func env(at: Int = 0, rc: Int = 0, say: String = "", sleep: Int = 0) -> [String: String] {
        ["KIT_BATCH_BIN": bin, "KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1", "STUB_LOG": log, "STUB_AT": String(at), "STUB_RC": String(rc), "STUB_SAY": say, "STUB_SLEEP": String(sleep)]
    }
}

private func makeRig() throws -> Rig {
    let dir = try KC.tempDir()
    let bin = dir + "/bin"
    let stub = """
    #!/bin/bash
    n=$(( $(wc -l < "$STUB_LOG" 2>/dev/null || echo 0) + 1 ))
    echo "$(basename "$0") $*" >> "$STUB_LOG"
    [ "${STUB_SLEEP:-0}" != 0 ] && sleep "$STUB_SLEEP"
    if [ "$n" = "$STUB_AT" ]; then
      [ -n "$STUB_SAY" ] && echo "$STUB_SAY"
      exit "${STUB_RC:-0}"
    fi
    exit 0
    """
    for name in ["kit-reset.sh", "kit-run.sh", "kit-doctor.sh", "verify.sh", "kit-selfrun.sh"] {
        try KC.write(bin + "/" + name, stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/" + name)
    }
    try KC.write(dir + "/log", "")
    return Rig(bin: bin, log: dir + "/log", kit: try KC.kitRoot())
}

private func calls(_ rig: Rig) -> [String] { KC.lines(KC.read(rig.log) ?? "") }

private struct Listed {
    let letter: String
    let name: String
    let launches: String
    let ids: [String]
    let lines: [String]
    let text: String
}

private func parseListing(_ out: String) -> [Listed] {
    var result: [Listed] = []
    var cur: (String, String, String, [String], [String], [String])?
    func flush() {
        if let c = cur { result.append(Listed(letter: c.0, name: c.1, launches: c.2, ids: c.3, lines: c.4, text: c.5.joined(separator: "\n"))) }
    }
    for l in out.components(separatedBy: "\n") {
        if l.hasPrefix("BATCH ") {
            flush()
            let rest = String(l.dropFirst(6))
            guard let sp = rest.firstIndex(of: " "), let colon = rest.range(of: ": launches ") else { cur = nil; continue }
            let letter = String(rest[..<sp])
            let name = String(rest[rest.index(after: sp)..<colon.lowerBound])
            let after = String(rest[colon.upperBound...])
            let parts = after.components(separatedBy: ": ")
            let launches = parts[0]
            let ids = parts.count > 1 && parts[1] != "none" ? parts[1].split(separator: ",").map(String.init) : []
            cur = (letter, name, launches, ids, [], [l])
        } else if cur != nil {
            if l.hasPrefix("  run: ") || l.hasPrefix("  say: ") { cur!.4.append(String(l.dropFirst(7))) }
            cur!.5.append(l)
        }
    }
    flush()
    return result
}

private func listing() throws -> (Rig, [Listed], String) {
    let rig = try makeRig()
    let r = try KC.run(kitRun, ["batches"], env: rig.env())
    return (rig, parseListing(r.output), r.output)
}

private func ids(_ prefix: String, _ a: Int, _ b: Int) -> [String] { (a...b).map { "\(prefix).\($0)" } }

@Suite("KitRunBatchesTests")
struct KitRunBatchesTests {
    @Test("batches prints every batch and starts nothing: no stub script is called")
    func startsNothing() throws {
        let (rig, listed, out) = try listing()
        #expect(!listed.isEmpty, "no BATCH line: \(out)")
        #expect(calls(rig).isEmpty, "the listing called \(calls(rig))")
        #expect(!FileManager.default.fileExists(atPath: rig.kit + "/run"), "the listing made a run/ folder in the kit root")
    }

    @Test("the batches come in this order: H0, A, C to G, then H1 to H3 (batch B is gone), then S9, then S10, and none is empty (plan-7-t10 amended: batch S9 added last; plan-8-t9 amended: batch S10 added after it)")
    func orderAndNotEmpty() throws {
        let (_, listed, _) = try listing()
        #expect(listed.map(\.letter) == ["H0", "A", "C", "D", "E", "F", "G", "H1", "H2", "H3", "S9", "S10"], "letters: \(listed.map(\.letter))")
        for b in listed { #expect(!b.lines.isEmpty, "batch \(b.letter) has no line") }
    }

    @Test("every batch line states its launch count, a number or many; H0 and H3 launch 0 and H0 holds no id")
    func launchCounts() throws {
        let (_, listed, _) = try listing()
        for b in listed { #expect(b.launches == "many" || Int(b.launches) != nil, "batch \(b.letter) says launches \(b.launches.debugDescription)") }
        #expect(listed.first { $0.letter == "H0" }?.launches == "0")
        #expect(listed.first { $0.letter == "H0" }?.ids.isEmpty == true, "H0 holds ids")
        #expect(listed.first { $0.letter == "H3" }?.launches == "0")
        #expect(listed.first { $0.letter == "H3" }?.ids.isEmpty == true, "H3 holds ids")
    }

    @Test("every id of checks.tsv appears in at least one batch")
    func everyIdIsPlanned() throws {
        let (_, listed, _) = try listing()
        let planned = Set(listed.flatMap(\.ids))
        let missing = KC.checksTSV().map(\.id).filter { !planned.contains($0) }
        #expect(missing.isEmpty, "ids in no batch: \(missing)")
        #expect(KC.checksTSV().count == 121, "checks.tsv holds \(KC.checksTSV().count) ids, the hand count is 121 (plan-8-t9 amended: S10.1 to S10.9 added to the 112)")
        let unknown = planned.subtracting(Set(KC.checksTSV().map(\.id)))
        #expect(unknown.isEmpty, "batches name ids that checks.tsv does not hold: \(unknown.sorted())")
    }

    @Test("batch B is gone, and no batch names an S5 id, a removed id, the golden-code or overlap start, a code-only or group e golden run, or VS Code")
    func batchBIsGone() throws {
        let (_, listed, _) = try listing()
        #expect(!listed.contains { $0.letter == "B" }, "the listing still holds batch B")
        let table = KC.read(KC.lib + "/batches.tsv") ?? ""
        let rowOfB = KC.has(table, "(^|\t)B\t|\tB\t")
        #expect(!rowOfB, "batches.tsv still holds a row of batch B")
        for pattern in ["\\bS5\\b", "S5\\.[0-9]", "\\bS1\\.25\\b", "\\bS2\\.6\\b", "\\bS2\\.7\\b", "\\bS2\\.16\\b", "\\bS6\\.9\\b", "prep overlap", "code-only", "--group e", "VS Code"] {
            let found = KC.has(table, pattern)
            #expect(!found, "batches.tsv still matches \(pattern)")
        }
        let goldenCode = table.components(separatedBy: "\n").filter { $0.contains("golden-code") }
        #expect(goldenCode.count == 1 && goldenCode[0].hasPrefix("say\tS9\t"), "golden-code is named outside the one `say` line of batch S9 (the controller runs it with the old kit, plan-7-t10 amended): \(goldenCode)")
        let h0 = try #require(listed.first { $0.letter == "H0" })
        #expect(h0.text.contains("kit-mirror.sh seed --real is the one download)"), "the H0 model line lost its ending: \(h0.text)")
        #expect(!h0.text.contains("installed for"), "the H0 model line still asks for an app to be installed: \(h0.text)")
    }

    @Test("check_S2_1 and check_S2_2 run kit-golden.sh panel before engine: an engine run's prepare stops the app, so the panel run after it finds no Sesame")
    func panelBeforeEngine() throws {
        for (file, panel, engine) in [("checks-s2-golden.sh", "kit-golden.sh\" panel --group a", "kit-golden.sh\" engine --group a"), ("checks-s2c.sh", "S2C_GOLDEN\" panel --group b", "S2C_GOLDEN\" engine --group b")] {
            let text = try #require(KC.read(KC.lib + "/" + file), "\(file) is unreadable")
            let ls = KC.lines(text)
            let p = ls.firstIndex { $0.contains(panel) }, e = ls.firstIndex { $0.contains(engine) }
            #expect(p != nil && e != nil, "\(file) has no panel and engine run line")
            if let p, let e { #expect(p < e, "\(file) runs the engine (line \(e + 1)) before the panel (line \(p + 1))") }
        }
    }

    @Test("batch C: the reset with --baseline, prep tree, S2.17, then S8 (check_S8_12 deletes the Sesame folder and stops the app)")
    func orderOfC() throws {
        let (_, listed, _) = try listing()
        let c = try #require(listed.first { $0.letter == "C" })
        let runs = c.lines.filter { !$0.hasPrefix("grant") }
        func at(_ pattern: String) -> Int? { runs.firstIndex { KC.has($0, pattern) } }
        let reset = at("^kit-reset\\.sh .*--baseline"), tree = at("^kit-run\\.sh prep tree"), s217 = at("^kit-run\\.sh S2 --ids S2\\.17$"), s8 = at("^kit-run\\.sh S8$")
        #expect(reset != nil && tree != nil && s217 != nil && s8 != nil, "batch C lines: \(runs)")
        if let reset, let tree, let s217, let s8 {
            #expect(reset < tree && tree < s217 && s217 < s8, "batch C runs its lines in the order reset \(reset), prep tree \(tree), S2.17 \(s217), S8 \(s8)")
        }
        let i217 = c.ids.firstIndex(of: "S2.17"), i812 = c.ids.firstIndex(of: "S8.12")
        #expect(i217 != nil && i812 != nil && i217! < i812!, "S2.17 is not before S8.12 in batch C: \(c.ids)")
        #expect(c.ids.last == "S8.12", "S8.12 is not the last id of batch C: \(c.ids)")
    }

    @Test("batch D: S2.1 to S2.5 and S2.8, then prep index50k, then S2.9 to S2.14, then S2.15 last")
    func orderOfD() throws {
        let (_, listed, _) = try listing()
        let d = try #require(listed.first { $0.letter == "D" })
        #expect(d.ids == ids("S2", 1, 5) + ["S2.8"] + ids("S2", 9, 14) + ["S2.15"], "batch D ids: \(d.ids)")
        #expect(d.lines.first { KC.has($0, "^kit-run\\.sh S2 --ids S2\\.1,") } == "kit-run.sh S2 --ids S2.1,S2.2,S2.3,S2.4,S2.5,S2.8", "batch D's first S2 line: \(d.lines)")
        let prep = d.lines.firstIndex { KC.has($0, "^kit-run\\.sh prep index50k$") }
        let nine = d.lines.firstIndex { KC.has($0, "^kit-run\\.sh S2 --ids S2\\.9,") }
        let one = d.lines.firstIndex { KC.has($0, "^kit-run\\.sh S2 --ids S2\\.1,") }
        #expect(prep != nil && nine != nil && one != nil && one! < prep! && prep! < nine!, "batch D lines: \(d.lines)")
    }

    @Test("batch E is S6 whole, batch F is the one verify.sh with no separate library-scan, batch G is the self-runs")
    func eFG() throws {
        let (_, listed, _) = try listing()
        let e = try #require(listed.first { $0.letter == "E" })
        #expect(e.ids == ids("S6", 1, 8) + ids("S6", 10, 13), "batch E ids: \(e.ids)")
        let f = try #require(listed.first { $0.letter == "F" })
        #expect(f.lines.contains("verify.sh"), "batch F lines: \(f.lines)")
        #expect(!f.text.contains("library-scan"), "batch F holds a library-scan line (verify.sh resets with --baseline itself)")
        #expect(Set(f.ids) == Set(KC.checksTSV().map(\.id)), "batch F does not cover every id")
        let g = try #require(listed.first { $0.letter == "G" })
        #expect(g.text.contains("self-run"), "batch G does not say it holds the self-runs: \(g.text)")
    }

    @Test("H1 holds the 38 ids that failed and H2 the 33 grant ids, exactly the entry's lists")
    func leftovers() throws {
        let (_, listed, _) = try listing()
        let h1 = Set(["S1.6", "S1.7", "S1.10", "S1.11", "S1.13", "S1.15", "S1.20", "S1.21", "S1.22", "S1.26", "S1.29", "S2.1", "S2.2", "S2.4", "S2.5", "S2.8"]
            + ids("S2", 10, 14) + ["S6.1", "S6.10", "S6.12", "S7.1", "S7.2", "S7.3", "S7.5", "S7.7", "S7.9", "S7.11", "S7.12", "S7.13", "S8.5", "S8.6", "S8.9", "S8.11", "S8.13"])
        let h2 = Set(["S1.6", "S2.9", "S2.17"] + ids("S3", 1, 10) + ids("S4", 1, 10) + ["S6.8", "S6.13", "S7.4", "S7.18", "S8.1", "S8.2", "S8.3", "S8.7", "S8.8", "S8.10"])
        #expect(h1.count == 38 && h2.count == 33, "the hand lists hold \(h1.count) and \(h2.count) ids")
        #expect(Set(listed.first { $0.letter == "H1" }?.ids ?? []) == h1, "H1 ids differ: \(Set(listed.first { $0.letter == "H1" }?.ids ?? []).symmetricDifference(h1).sorted())")
        #expect(Set(listed.first { $0.letter == "H2" }?.ids ?? []) == h2, "H2 ids differ: \(Set(listed.first { $0.letter == "H2" }?.ids ?? []).symmetricDifference(h2).sorted())")
    }

    @Test("a real-app batch prints the caffeinate -dimsu, KIT_TYPE_DELAY_MS=80 and KIT_PICK_WAIT=30 the controller must use; H0 and H3 do not")
    func controllerLines() throws {
        let (_, listed, _) = try listing()
        #expect(listed.count == 12, "the listing holds \(listed.count) batches, expected 12 (plan-8-t9 amended: batch S10 added to the 11)")
        for b in listed {
            let real = !["H0", "H3"].contains(b.letter)
            let ok = b.text.contains("caffeinate -dimsu") && b.text.contains("KIT_TYPE_DELAY_MS=80") && b.text.contains("KIT_PICK_WAIT=30")
            if real { #expect(ok, "batch \(b.letter) does not print the controller lines: \(b.text)") }
            else { #expect(!b.text.contains("run it as:"), "batch \(b.letter) launches nothing but prints how to run it") }
        }
    }

    @Test("a batch that has not run says `not run yet`, one that has says `last took`, from the kept copy after a reset deleted run/")
    func lastTook() throws {
        let rig = try makeRig()
        var out = try KC.run(kitRun, ["batches"], env: rig.env()).output
        #expect(!out.contains("last took"), "a batch has a duration before any ran: \(out)")
        #expect(out.components(separatedBy: "not run yet").count - 1 == 12, "not every batch says `not run yet` (plan-8-t9 amended: 12 batches with S10)")
        let r = try KC.run(kitRun, ["batch", "E"], env: rig.env())
        #expect(r.status == 0, "batch E exited \(r.status): \(r.output)")
        try? FileManager.default.removeItem(atPath: rig.kit + "/run")
        out = try KC.run(kitRun, ["batches"], env: rig.env()).output
        let parsed = out.components(separatedBy: "\nBATCH ").first { $0.hasPrefix("E ") } ?? ""
        #expect(KC.has(parsed, "last took \\d+:\\d{2}:\\d{2}"), "batch E has no `last took` after it ran: \(parsed)")
        #expect(out.components(separatedBy: "last took").count - 1 == 1, "more than the batch that ran has a duration")
    }

    // MARK: running a batch

    @Test("batch C prints its BATCH line first, runs its lines in order with the saved version, and ends with the duration in h:mm:ss")
    func runsInOrder() throws {
        let rig = try makeRig()
        try KC.write(rig.kit + "/run/version", "v7\n")
        let r = try KC.run(kitRun, ["batch", "C"], env: rig.env())
        #expect(r.status == 0, "batch C exited \(r.status): \(r.output)")
        let ls = KC.lines(r.output)
        #expect(ls.first?.hasPrefix("BATCH C ") == true && ls.first?.contains(": launches many: ") == true, "the first line is \(ls.first ?? "none")")
        #expect(ls.firstIndex { $0.hasPrefix("RUN ") } ?? 0 > 0, "a RUN line came before the BATCH line")
        #expect(calls(rig) == [
            "kit-reset.sh --id S8 --version v7 --model mirror --baseline",
            "kit-run.sh prep tree --trace s8",
            "kit-run.sh S2 --ids S2.17",
            "kit-run.sh S8",
        ], "the stubs were called as \(calls(rig))")
        let took = ls.last ?? ""
        #expect(KC.has(took, "^BATCH C took \\d+:\\d{2}:\\d{2}$"), "the last line is \(took)")
        for f in [rig.kit + "/run/batch-times.tsv", rig.kit + "/batch-kept/batch-times.tsv"] {
            let rows = KC.lines(KC.read(f) ?? "")
            #expect(rows.count == 1, "\(f) holds \(rows)")
            let cols = rows.first?.components(separatedBy: "\t") ?? []
            #expect(cols.count == 3 && cols[0] == "C" && KC.has(cols[1], "^\\d+:\\d{2}:\\d{2}$") && KC.has(cols[2], "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$"), "the row is \(cols)")
        }
    }

    @Test("the version is `accept` when no reset has recorded one")
    func defaultVersion() throws {
        let rig = try makeRig()
        _ = try KC.run(kitRun, ["batch", "C"], env: rig.env())
        #expect(calls(rig).first == "kit-reset.sh --id S8 --version accept --model mirror --baseline", "first call: \(calls(rig).first ?? "none")")
    }

    @Test("the duration is the script's own clock: a stub that sleeps 2 s per call shows at least 0:00:06 over three calls")
    func clockIsMeasured() throws {
        let rig = try makeRig()
        var env = rig.env(sleep: 2)
        env["STUB_AT"] = "0"
        let r = try KC.run(kitRun, ["batch", "D"], env: env, limit: 120)
        let took = r.output.components(separatedBy: "\n").first { $0.hasPrefix("BATCH D took ") } ?? ""
        let hms = took.replacingOccurrences(of: "BATCH D took ", with: "").split(separator: ":").compactMap { Int($0) }
        #expect(hms.count == 3 && hms[0] * 3600 + hms[1] * 60 + hms[2] >= 8, "took line: \(took) (4 calls of 2 s)")
    }

    @Test("--unattended stops at the first exit 4 with `STOPPED <id> exit 4 after <h:mm:ss>`, runs nothing after it, and records no duration")
    func unattendedStopsAtFour() throws {
        let rig = try makeRig()
        let r = try KC.run(kitRun, ["batch", "C", "--unattended"], env: rig.env(at: 3, rc: 4, say: "RERUN S2.17 not valid: stub"))
        #expect(r.status == 4, "exit \(r.status): \(r.output)")
        #expect(KC.has(r.output, "STOPPED S2\\.17 exit 4 after \\d+:\\d{2}:\\d{2}"), "no STOPPED line: \(r.output)")
        #expect(calls(rig).count == 3, "calls after the stop: \(calls(rig))")
        #expect(!r.output.contains("took"), "a stopped batch printed a duration")
        #expect(KC.read(rig.kit + "/run/batch-times.tsv") == nil && KC.read(rig.kit + "/batch-kept/batch-times.tsv") == nil, "a stopped batch recorded a duration")
    }

    @Test("without --unattended exit 4 does not stop the batch: it says the id is to be rerun, goes on and exits 1")
    func attendedGoesOnAtFour() throws {
        let rig = try makeRig()
        let r = try KC.run(kitRun, ["batch", "C"], env: rig.env(at: 3, rc: 4, say: "RERUN S2.17 not valid: stub"))
        #expect(r.status == 1, "exit \(r.status): \(r.output)")
        #expect(!r.output.contains("STOPPED"), "an attended batch stopped at exit 4: \(r.output)")
        #expect(r.output.contains("NOTE S2.17 exit 4"), "no NOTE line: \(r.output)")
        #expect(calls(rig).count == 4, "the batch did not go on: \(calls(rig))")
    }

    @Test("exit 3 stops the batch with or without --unattended, after the check's own NEEDS A PERSON line")
    func threeStopsBoth() throws {
        for flag in [[], ["--unattended"]] {
            let rig = try makeRig()
            let r = try KC.run(kitRun, ["batch", "C"] + flag, env: rig.env(at: 2, rc: 3, say: "NEEDS A PERSON: the administrator session"))
            #expect(r.status == 3, "\(flag): exit \(r.status): \(r.output)")
            let ls = KC.lines(r.output)
            let need = ls.firstIndex { $0.hasPrefix("NEEDS A PERSON") }, stop = ls.firstIndex { $0.hasPrefix("STOPPED ") }
            #expect(need != nil && stop != nil && need! < stop!, "\(flag): the NEEDS A PERSON line must be printed before the STOPPED line: \(r.output)")
            #expect(KC.has(r.output, "STOPPED .* exit 3 after \\d+:\\d{2}:\\d{2}"), "\(flag): \(r.output)")
            #expect(calls(rig).count == 2, "\(flag): calls after the stop: \(calls(rig))")
        }
    }

    @Test("exit 1 (a check failed) never stops a batch; the batch ends with its duration and exits 1")
    func oneDoesNotStop() throws {
        let rig = try makeRig()
        let r = try KC.run(kitRun, ["batch", "C", "--unattended"], env: rig.env(at: 3, rc: 1))
        #expect(r.status == 1, "exit \(r.status): \(r.output)")
        #expect(calls(rig).count == 4 && r.output.contains("BATCH C took "), "calls \(calls(rig)); output \(r.output)")
    }

    @Test("an unknown batch, no batch, or an unknown option is usage (exit 2) and nothing runs")
    func usageErrors() throws {
        for args in [["batch"], ["batch", "Z"], ["batch", "C", "--bogus"], ["batch", "C", "--unattended", "x"], ["batches", "x"]] {
            let rig = try makeRig()
            let r = try KC.run(kitRun, args, env: rig.env())
            #expect(r.status == 2, "\(args): exit \(r.status): \(r.output)")
            #expect(calls(rig).isEmpty, "\(args): something ran: \(calls(rig))")
        }
    }

    @Test("--version needs a real value: `--version --unattended`, an empty value and a leading dash are usage (exit 2), nothing runs and run/version is not written")
    func versionValueIsChecked() throws {
        for args in [["batch", "A", "--version", "--unattended"], ["batch", "A", "--version", ""], ["batch", "A", "--version", "-x"], ["batch", "A", "--version"]] {
            let rig = try makeRig()
            let r = try KC.run(kitRun, args, env: rig.env())
            #expect(r.status == 2, "\(args): exit \(r.status): \(r.output)")
            #expect(calls(rig).isEmpty, "\(args): something ran: \(calls(rig))")
            #expect(KC.read(rig.kit + "/run/version") == nil, "\(args): run/version was written: \(KC.read(rig.kit + "/run/version") ?? "")")
        }
    }

    @Test("an unknown batch letter with --version exits 2 and does not write run/version")
    func unknownLetterWritesNoVersion() throws {
        let rig = try makeRig()
        try KC.write(rig.kit + "/run/version", "keep\n")
        let r = try KC.run(kitRun, ["batch", "Z", "--version", "foo"], env: rig.env())
        #expect(r.status == 2, "exit \(r.status): \(r.output)")
        #expect(calls(rig).isEmpty, "something ran: \(calls(rig))")
        #expect(KC.read(rig.kit + "/run/version")?.trimmingCharacters(in: .whitespacesAndNewlines) == "keep", "run/version is now \(KC.read(rig.kit + "/run/version") ?? "missing")")
        let fresh = try makeRig()
        _ = try KC.run(kitRun, ["batch", "Z", "--version", "foo"], env: fresh.env())
        #expect(KC.read(fresh.kit + "/run/version") == nil, "run/version was created for an unknown batch")
    }

    @Test("a valid --version is written to run/version and reaches the batch lines")
    func validVersionIsWritten() throws {
        let rig = try makeRig()
        let r = try KC.run(kitRun, ["batch", "A", "--version", "v9"], env: rig.env())
        #expect(r.status == 0, "exit \(r.status): \(r.output)")
        #expect(KC.read(rig.kit + "/run/version")?.trimmingCharacters(in: .whitespacesAndNewlines) == "v9", "run/version is \(KC.read(rig.kit + "/run/version") ?? "missing")")
        #expect(calls(rig) == ["kit-doctor.sh --version v9"], "the stubs were called as \(calls(rig))")
    }

    @Test("a say line is printed, never run: batch H0 calls nothing and exits 0")
    func sayLines() throws {
        let rig = try makeRig()
        let r = try KC.run(kitRun, ["batch", "H0"], env: rig.env())
        #expect(r.status == 0, "exit \(r.status): \(r.output)")
        #expect(r.output.contains("SAY "), "no SAY line: \(r.output)")
        #expect(calls(rig).isEmpty, "H0 ran \(calls(rig))")
    }

    @Test("batch_hms formats seconds as h:mm:ss: 59 is 0:00:59, 3725 is 1:02:05, 36000 is 10:00:00")
    func hms() throws {
        let kit = try KC.kitRoot()
        let script = try KC.bash(". \"\(KC.lib)/batches.sh\"; for s in 59 3725 36000; do batch_hms $s; echo; done", kit: kit)
        #expect(KC.lines(script.output) == ["0:00:59", "1:02:05", "10:00:00"], "batch_hms printed \(script.output)")
    }

    @Test("the usage text of kit-run.sh names batches and batch")
    func usageNames() throws {
        let rig = try makeRig()
        let r = try KC.run(kitRun, ["nonsense"], env: rig.env())
        #expect(r.status == 2 && r.output.contains("kit-run.sh batches") && r.output.contains("kit-run.sh batch <letter> [--unattended]"), "usage: \(r.output)")
    }
}

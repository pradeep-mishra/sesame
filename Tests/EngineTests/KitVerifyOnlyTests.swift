import Foundation
import Testing

// plan-6-t9, tester step, part F: `scripts/verify.sh --only <S>` (S1 to S8). Written from the entry plan-6-t9 (part F) of plan-6-tasks.md.
//
// The seam (the tester's pick, named in the report): the environment variable KIT_VERIFY_BIN is a folder that holds the two scripts verify.sh
// hands work to, kit-reset.sh (step_reset) and kit-run.sh (the checks); unset, it is scripts/ itself. A test points it at a folder of stub
// scripts that log their arguments and print CHECK lines for the ids of checks.tsv, so nothing is built, reset or launched. KIT_NO_EVIDENCE=1
// keeps the wrapper from saving the output under the repo.
//
// Pinned: `--only <S>` prints `ONLY <S>: build, static and swift test are the cited full run's (verify-output.txt)`, runs no build, bundle,
// static or swift test step and no prerequisite probe (kit-run.sh asks kit-perms.sh per id), makes the starting state with step_reset (with
// --baseline for S8 only), runs `kit-run.sh <S> --slice <slice>` once, prints that run's CHECKS line (the ids of that scenario in checks.tsv
// only) and exits nonzero on a failed id. An unknown scenario, a missing one, `--only` with --quick and `--only` with --plant are exit 2 with
// the usage, and nothing runs. The full verify.sh keeps every step in order.
// Red before the kit part: `--only` is an unknown option (exit 2 with no ONLY line for S1 to S8).

private let verify = KC.scripts + "/verify.sh"

private struct Rig {
    let bin: String
    let log: String
    let kit: String
    var env: [String: String] {
        ["KIT_VERIFY_BIN": bin, "KIT_ROOT": kit, "KIT_NO_EVIDENCE": "1", "STUB_LOG": log, "STUB_LIB": KC.lib]
    }
}

private func makeRig() throws -> Rig {
    let dir = try KC.tempDir()
    let bin = dir + "/bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try KC.write(bin + "/kit-reset.sh", """
    #!/bin/bash
    echo "reset $*" >> "$STUB_LOG"
    exit 0
    """)
    try KC.write(bin + "/kit-run.sh", """
    #!/bin/bash
    echo "run $*" >> "$STUB_LOG"
    scen="$1"; slice=6
    [ "$2" = --slice ] && slice="$3"
    n=0; bad=0
    while IFS=$'\\t' read -r id first kind; do
      [ -n "$id" ] || continue
      [ "${id%%.*}" = "$scen" ] || continue
      [ "$first" -le "$slice" ] || continue
      if [ "$id" = "$STUB_FAIL_ID" ]; then echo "CHECK $id FAIL stub"; bad=$((bad + 1)); else echo "CHECK $id PASS stub"; n=$((n + 1)); fi
    done < "$STUB_LIB/checks.tsv"
    echo "CHECKS: $n passed, $bad failed, 0 skipped, 0 needs-a-person"
    [ "$bad" = 0 ]
    """)
    for f in ["kit-reset.sh", "kit-run.sh"] {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/" + f)
    }
    return Rig(bin: bin, log: dir + "/log", kit: try KC.kitRoot())
}

private func calls(_ rig: Rig) -> [String] { KC.lines(KC.read(rig.log) ?? "") }

@Suite("KitVerifyOnlyTests")
struct KitVerifyOnlyTests {
    /// Hand-counted from checks.tsv (112 ids): the ids of each scenario, every one of them first drivable at slice 7 or earlier.
    static let idsPerScenario: [(String, Int)] = [("S1", 29), ("S2", 14), ("S3", 10), ("S4", 10), ("S6", 12), ("S7", 18), ("S8", 13), ("S9", 6), ("S10", 9)]

    @Test("--only <S> prints the ONLY line, runs kit-run.sh <S> once and prints the CHECKS line of that scenario's ids only", arguments: idsPerScenario)
    func onlyRuns(_ scenario: String, _ count: Int) throws {
        let rig = try makeRig()
        let r = try KC.run(verify, ["--only", scenario], env: rig.env)
        #expect(r.status == 0, "--only \(scenario) exited \(r.status): \(r.output)")
        #expect(r.output.contains("ONLY \(scenario): build, static and swift test are the cited full run's (verify-output.txt)"), "no ONLY line: \(r.output)")
        let c = calls(rig)
        #expect(c.filter { $0.hasPrefix("run ") } == ["run \(scenario) --slice 8"], "kit-run.sh was called as \(c)")
        #expect(r.output.contains("CHECKS: \(count) passed, 0 failed, 0 skipped, 0 needs-a-person"), "the CHECKS line does not hold exactly the \(count) ids of \(scenario): \(r.output)")
        let other = r.output.components(separatedBy: "\n").filter { $0.hasPrefix("CHECK ") && !$0.hasPrefix("CHECK \(scenario).") && !$0.hasPrefix("CHECKS") }
        #expect(other.isEmpty, "ids of another scenario were run: \(other.prefix(3))")
    }

    @Test("--only runs no build, bundle, static or swift test step and no prerequisite probe")
    func runsNothingElse() throws {
        let rig = try makeRig()
        let r = try KC.run(verify, ["--only", "S3"], env: rig.env)
        #expect(r.status == 0 && r.output.contains("ONLY S3:"), "--only S3 did not run (exit \(r.status)): \(r.output)")
        for word in ["== build and bundle", "== static and tests", "== prerequisites", "CHECK build", "CHECK bundle", "CHECK static", "CHECK swift-test", "xcodebuild"] {
            #expect(!r.output.contains(word), "--only S3 printed \(word.debugDescription): \(r.output)")
        }
    }

    @Test("the starting state is made once, with --baseline for S8 only")
    func baselineOnlyForS8() throws {
        for (scenario, _) in Self.idsPerScenario {
            let rig = try makeRig()
            _ = try KC.run(verify, ["--only", scenario], env: rig.env)
            let resets = calls(rig).filter { $0.hasPrefix("reset ") }
            #expect(resets.count == 1, "--only \(scenario) made \(resets.count) starting states")
            let has = resets.first?.contains("--baseline") ?? false
            #expect(has == (scenario == "S8"), "--only \(scenario): the reset was `\(resets.first ?? "none")`, --baseline belongs to S8 only")
            #expect(resets.first?.contains("--model cache") == true, "--only \(scenario): the reset lost --model cache: \(resets)")
        }
    }

    @Test("a failed id makes --only exit 1 and shows in the CHECKS line")
    func failedId() throws {
        let rig = try makeRig()
        var env = rig.env
        env["STUB_FAIL_ID"] = "S4.3"
        let r = try KC.run(verify, ["--only", "S4"], env: env)
        #expect(r.status == 1, "--only S4 with a failed id exited \(r.status), wanted 1: \(r.output)")
        #expect(r.output.contains("CHECKS: 9 passed, 1 failed"), "the CHECKS line does not count the failed id: \(r.output)")
    }

    @Test("an unknown or missing scenario, --only with --quick and --only with --plant are exit 2 with the usage, and nothing runs")
    func usageErrors() throws {
        let cases: [[String]] = [["--only"], ["--only", "S11"], ["--only", "S0"], ["--only", "all"], ["--only", "s1"], ["--only", "S1", "--quick"], ["--quick", "--only", "S1"], ["--only", "S1", "--plant", "smoke"]]
        for args in cases {
            let rig = try makeRig()
            let r = try KC.run(verify, args, env: rig.env)
            #expect(r.status == 2, "verify.sh \(args.joined(separator: " ")) exited \(r.status), wanted 2: \(r.output)")
            #expect(r.output.contains("usage: scripts/verify.sh") && r.output.contains("--only"), "\(args): the usage does not name --only: \(r.output)")
            #expect(calls(rig).isEmpty, "\(args): something ran: \(calls(rig))")
        }
    }

    @Test("the unknown-scenario message names the scenario that was given")
    func unknownIsNamed() throws {
        let rig = try makeRig()
        let r = try KC.run(verify, ["--only", "S11"], env: rig.env)
        #expect(r.status == 2 && r.output.contains("S11"), "the message does not name S11 (exit \(r.status)): \(r.output)")
    }

    @Test("the full verify.sh keeps every step in order: build, bundle, static, swift test, the reset with --baseline, kit-run.sh all")
    func fullRunUnchanged() {
        let text = KC.read(verify) ?? ""
        let main = KC.shellFunction("main", in: text) ?? ""
        let order = ["run_check build check_build", "run_check bundle check_bundle", "run_check static check_static_full", "run_check swift-test check_swift_test", "step_reset --baseline", "run_kit_run"]
        var at = main.startIndex
        for needle in order {
            guard let found = main.range(of: needle, range: at..<main.endIndex) else {
                Issue.record("main has no `\(needle)` after the previous step")
                return
            }
            at = found.upperBound
        }
        #expect(main.contains("prerequisites ||"), "the full run lost its prerequisites step")
        #expect(KC.has(text, "usage: scripts/verify.sh \\[--quick\\] \\[--slice N\\] \\[--only S1\\.\\.S10\\] \\[--plant smoke\\]") || KC.has(text, "--only <S1\\.\\.S10>"), "the usage line does not show --only S1..S10 (plan-8-t9 amended: the usage lists S10, was S1..S9)")
    }
}

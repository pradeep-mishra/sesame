import Foundation
import Testing

// plan-6-t9, tester step, part G: the lazy Library baseline. Written from the entry plan-6-t9 (part G, review 2) of plan-6-tasks.md and
// verify.md; the scripts are read only to find where the baseline is taken, which checks read it and where verify.sh resets.
//
// What is pinned, and how (nothing here runs a real reset: kit-reset.sh stops Sesame and Low Power Mode state, so its baseline step is a
// function the test runs alone, with a stub kit-privacy.sh):
//   - kit-reset.sh takes the Library baseline only with `--baseline` (a plain reset prints that it took none); `--baseline` belongs to a
//     reset, so it with --cleanup, --wipe-cache or --bundle-only is usage (exit 2); the usage text names it.
//   - `recipe_reset <model> [--baseline]` hands the flag on. `recipe_tree` passes it: the recipe's own reset deletes run/ (and the baseline in
//     run/privacy), so a baseline taken before `prep tree` would be gone when S8.12 and S8.13 run. This is a finding of this tester: review 2
//     put the flag on the block C reset and on verify.sh's reset only.
//   - verify.sh `step_reset [--baseline]`: the full run, the --quick run and `--only S8` pass it; the planted smoke does not.
//   - S8.12 and S8.13 are the only checks that read the baseline (kit-privacy.sh library-scan); with none they are exit 4 with
//     `no Library baseline: reset with --baseline`, and with one they carry on.
// Red before the kit part: kit-reset.sh takes the baseline at every reset and has no flag, step_reset takes no argument, recipe_reset takes
// none, S8.12 and S8.13 go to library-scan whatever is there.

private let reset = KC.scripts + "/kit-reset.sh"
private let verify = KC.scripts + "/verify.sh"

private func resetText() -> String { KC.read(reset) ?? "" }
private func verifyText() -> String { KC.read(verify) ?? "" }

@Suite("KitResetBaselineTests")
struct KitResetBaselineTests {
    @Test("kit-reset.sh names --baseline in its usage and refuses it with --cleanup, --wipe-cache and --bundle-only (exit 2, nothing runs)")
    func flagIsAResetOption() throws {
        let kit = try KC.kitRoot()
        let env = ["KIT_ROOT": kit]
        let usage = try KC.run(reset, ["--cleanup", "--bogus"], env: env)
        #expect(usage.status == 2, "an unknown option exited \(usage.status)")
        #expect(usage.output.contains("--baseline"), "the usage text does not name --baseline: \(usage.output)")
        for args in [["--cleanup", "--baseline"], ["--wipe-cache", "--baseline"], ["--bundle-only", "--id", "kit", "--baseline"]] {
            let r = try KC.run(reset, args, env: env)
            #expect(r.status == 2, "kit-reset.sh \(args.joined(separator: " ")) exited \(r.status), wanted usage (2): \(r.output)")
            #expect(r.output.contains("--baseline"), "\(args): the usage line does not name --baseline: \(r.output)")
        }
    }

    /// The baseline step of kit-reset.sh as a function, run alone with a stub kit-privacy.sh that records its argument.
    private func baselineStep(flag: String) throws -> (log: String, out: String, status: Int32) {
        let text = resetText()
        let fn = KC.shellFunction("reset_baseline", in: text)
        #expect(fn != nil, "kit-reset.sh has no function reset_baseline (the step the flag guards)")
        let dir = try KC.tempDir()
        let stub = dir + "/scripts"
        try KC.write(stub + "/kit-privacy.sh", "#!/bin/bash\necho \"stub-privacy $*\" >> \"$STUB_LOG\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub + "/kit-privacy.sh")
        // do_reset's own guard, copied from the real text: the lines of do_reset that mention reset_baseline
        let doReset = KC.shellFunction("do_reset", in: text) ?? ""
        let guardLine = doReset.components(separatedBy: "\n").first { $0.contains("reset_baseline") && !$0.contains("baseline started") } ?? "MISSING"
        let harness = """
        #!/bin/bash
        KIT_SCRIPTS="\(stub)"
        baseline="\(flag)"
        \(fn ?? "reset_baseline() { echo MISSING; }")
        \(guardLine)
        """
        let path = dir + "/h.sh"
        try KC.write(path, harness)
        let log = dir + "/log"
        let r = try KC.run("/bin/bash", [path], env: ["STUB_LOG": log])
        return (KC.read(log) ?? "", r.output, r.status)
    }

    @Test("a plain reset takes no Library baseline and says so")
    func plainResetTakesNone() throws {
        let r = try baselineStep(flag: "0")
        #expect(r.log.isEmpty, "a reset without --baseline still ran kit-privacy.sh: \(r.log)")
        let doReset = KC.shellFunction("do_reset", in: resetText()) ?? ""
        #expect(KC.has(doReset, "no Library baseline|baseline not taken|took no .*baseline"), "do_reset does not print that no baseline was taken")
    }

    @Test("--baseline takes the Library baseline once, through kit-privacy.sh baseline")
    func flagTakesIt() throws {
        let r = try baselineStep(flag: "1")
        #expect(KC.lines(r.log) == ["stub-privacy baseline"], "kit-privacy.sh was called as \(r.log.debugDescription), wanted one `baseline`")
    }

    @Test("do_reset takes a fourth argument for the flag and main reads --baseline into it")
    func plumbing() {
        let text = resetText()
        let doReset = KC.shellFunction("do_reset", in: text) ?? ""
        #expect(KC.has(doReset, "local id=\"\\$1\" version=\"\\$2\" model=\"\\$3\" baseline=\"\\$4\""), "do_reset does not take the flag as its fourth argument")
        let main = KC.shellFunction("main", in: text) ?? ""
        #expect(KC.has(main, "--baseline\\) +baseline=1"), "main does not read --baseline")
        #expect(KC.has(main, "do_reset \"\\$id\" \"\\$version\" \"\\$model\" \"\\$baseline\""), "main does not pass the flag on to do_reset")
        #expect(!KC.has(doReset, "kit-privacy.sh\" baseline"), "do_reset still calls kit-privacy.sh baseline itself, outside reset_baseline")
    }

    // MARK: recipe_reset and the tree recipe

    private func recipeResetCalls(_ body: String) throws -> String {
        let kit = try KC.kitRoot()
        let r = try KC.bash("""
        kq() { shift 0; echo "kq $(basename "$1") ${*:2}"; }
        \(body)
        """, kit: kit)
        return r.output
    }

    @Test("recipe_reset passes --baseline only when asked, and keeps --model")
    func recipeResetFlag() throws {
        let plain = try recipeResetCalls("recipe_reset cache")
        #expect(plain.contains("kq kit-reset.sh --id") && plain.contains("--model cache"), "plain recipe_reset printed \(plain)")
        #expect(!plain.contains("--baseline"), "a plain recipe_reset passes --baseline: \(plain)")
        let with = try recipeResetCalls("recipe_reset mirror --baseline")
        #expect(with.contains("--model mirror") && with.contains("--baseline"), "recipe_reset mirror --baseline printed \(with)")
        let none = try recipeResetCalls("recipe_reset none --baseline")
        #expect(!none.contains("--model") && none.contains("--baseline"), "recipe_reset none --baseline printed \(none)")
    }

    @Test("the recipe tree resets with --baseline (its reset would delete a baseline taken before it); no other recipe does")
    func onlyTreeAsksForIt() {
        let text = KC.read(KC.lib + "/recipes.sh") ?? ""
        let tree = KC.shellFunction("recipe_tree", in: text) ?? ""
        #expect(KC.has(tree, "recipe_reset mirror --baseline"), "recipe_tree does not reset with --baseline")
        let all = text.components(separatedBy: "\n").filter { $0.contains("recipe_reset") && $0.contains("--baseline") && !$0.hasPrefix("#") }
        #expect(all.count == 1, "recipe_reset ... --baseline appears \(all.count) times in recipes.sh, only recipe_tree needs it: \(all)")
    }

    // MARK: verify.sh

    private func stepResetCalls(_ arg: String) throws -> String {
        let fn = KC.shellFunction("step_reset", in: verifyText())
        #expect(fn != nil, "verify.sh has no step_reset")
        let dir = try KC.tempDir()
        let harness = """
        #!/bin/bash
        ID=S8; VERSION=v9; F=0
        KIT_SCRIPTS=/stub
        kq() { echo "kq $(basename "$1") ${*:2}" >> "\(dir)/log"; }
        \(fn ?? "step_reset() { echo MISSING; }")
        step_reset \(arg)
        """
        try KC.write(dir + "/h.sh", harness)
        _ = try KC.run("/bin/bash", [dir + "/h.sh"])
        return KC.read(dir + "/log") ?? ""
    }

    @Test("step_reset passes --baseline to kit-reset.sh only when given it")
    func stepResetFlag() throws {
        let plain = try stepResetCalls("")
        #expect(plain.contains("kq kit-reset.sh --id S8 --version v9 --model cache"), "step_reset printed \(plain)")
        #expect(!plain.contains("--baseline"), "step_reset with no argument passes --baseline: \(plain)")
        let with = try stepResetCalls("--baseline")
        #expect(with.contains("--model cache") && with.contains("--baseline"), "step_reset --baseline printed \(with)")
    }

    @Test("verify.sh: the full run and the --quick run reset with --baseline, the planted smoke resets without it")
    func verifyCallSites() {
        let text = verifyText()
        let calls = text.components(separatedBy: "\n").enumerated().filter { $0.element.contains("step_reset") && !$0.element.contains("step_reset() {") && !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let planted = text.range(of: "== the smoke, planted").map { text[$0.upperBound...].prefix(120) } ?? ""
        #expect(KC.has(String(planted), "step_reset \\|\\|"), "the planted smoke's reset is not a plain step_reset: \(planted)")
        #expect(!String(planted).contains("--baseline"), "the planted smoke resets with --baseline")
        let quick = text.range(of: "== static, plist and entitlements, smoke, Library scan").map { text[$0.upperBound...].prefix(300) } ?? ""
        #expect(String(quick).contains("step_reset --baseline"), "the --quick run does not reset with --baseline (it runs S8.12): \(quick)")
        #expect(KC.has(text, "step_reset --baseline\\n\\s*run_kit_run"), "the full run does not reset with --baseline right before kit-run.sh all")
        #expect(calls.count >= 3, "verify.sh has only \(calls.count) step_reset calls")
    }

    // MARK: who reads the baseline

    @Test("only check_S8_12 and check_S8_13 call library-scan, the one kit-privacy.sh mode that reads the baseline")
    func readers() throws {
        let fm = FileManager.default
        var users: [String] = []
        for f in try fm.contentsOfDirectory(atPath: KC.lib).sorted() where f.hasPrefix("checks-") && f.hasSuffix(".sh") {
            let text = KC.read(KC.lib + "/" + f) ?? ""
            var current = ""
            for l in text.components(separatedBy: "\n") {
                if let m = l.range(of: #"^[A-Za-z0-9_]+\(\) \{"#, options: .regularExpression) { current = String(l[m]).replacingOccurrences(of: "() {", with: "") }
                if l.contains("library-scan"), !l.trimmingCharacters(in: .whitespaces).hasPrefix("#") { users.append("\(f):\(current)") }
            }
        }
        #expect(users == ["checks-s8.sh:check_S8_13", "checks-s8.sh:check_S8_12"], "the checks that call library-scan are \(users)")
    }

    private func s8Check(_ fn: String, baseline: Bool) throws -> KC.Ran {
        let kit = try KC.kitRoot()
        if baseline {
            try KC.write(kit + "/run/privacy/baseline.time", "2026-01-01T00:00:00\n")
            try KC.write(kit + "/run/privacy/baseline-home.txt", "x\n")
            try KC.write(kit + "/run/privacy/baseline-real.txt", "y\n")
        } else {
            try FileManager.default.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
        }
        let log = try KC.tempDir() + "/log"
        let r = try KC.bash("""
        KIT_SLICE=3
        KIT_PLANT=
        kq() { echo "kq $(basename "$1") ${*:2}" >> "\(log)"; case "$(basename "$1")" in kit-privacy.sh) echo "library-scan clean"; return 0;; esac; return 0; }
        \(fn); echo "RC $?"
        """, kit: kit)
        return KC.Ran(status: r.status, output: r.output + "\nLOG\n" + (KC.read(log) ?? ""))
    }

    @Test("check_S8_12 with no baseline is exit 4 `no Library baseline: reset with --baseline` and never runs library-scan")
    func s812NoBaseline() throws {
        let r = try s8Check("check_S8_12", baseline: false)
        #expect(r.output.contains("RERUN S8.12 not valid: no Library baseline: reset with --baseline"), "no RERUN line: \(r.output)")
        #expect(r.output.contains("RC 4"), "check_S8_12 did not return 4: \(r.output)")
        #expect(!r.output.contains("library-scan"), "library-scan ran without a baseline: \(r.output)")
    }

    @Test("check_S8_12 with a baseline goes on to library-scan --delete-first and passes when it is clean")
    func s812WithBaseline() throws {
        let r = try s8Check("check_S8_12", baseline: true)
        #expect(r.output.contains("kq kit-privacy.sh library-scan --delete-first"), "library-scan --delete-first was not run: \(r.output)")
        #expect(r.output.contains("CHECK S8.12 PASS") && r.output.contains("RC 0"), "S8.12 did not pass with a clean scan: \(r.output)")
    }

    @Test("check_S8_13 with no baseline is exit 4 `no Library baseline: reset with --baseline` before it reads anything else")
    func s813NoBaseline() throws {
        let r = try s8Check("check_S8_13", baseline: false)
        #expect(r.output.contains("RERUN S8.13 not valid: no Library baseline: reset with --baseline"), "no RERUN line: \(r.output)")
        #expect(r.output.contains("RC 4"), "check_S8_13 did not return 4: \(r.output)")
        let logPart = r.output.components(separatedBy: "\nLOG\n").last ?? ""
        #expect(logPart.isEmpty, "check_S8_13 ran a kit script before it found the baseline missing: \(logPart)")
    }

    @Test("the planted S8.12 and S8.13 still need the baseline only where they scan: S8.13's plant never reaches library-scan")
    func s813PlantNeedsNone() throws {
        let text = KC.read(KC.lib + "/checks-s8.sh") ?? ""
        let fn = KC.shellFunction("check_S8_13", in: text) ?? ""
        let plantEnd = fn.range(of: "layout accepted a planted stray")?.upperBound
        let guardAt = fn.range(of: "s8_need_baseline S8.13")?.lowerBound
        #expect(plantEnd != nil && guardAt != nil && plantEnd! < guardAt!, "the baseline guard of S8.13 is not after its plant block")
    }
}

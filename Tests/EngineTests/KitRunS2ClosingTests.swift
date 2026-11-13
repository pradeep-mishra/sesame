import Foundation
import Testing

// plan-6-t9, tester step part 2, part (B): the complete S2 checks. S2.9 to S2.14 run on the real 50,000-row index (`index50k`) instead of the
// busy50k stand-in; S2.11 puts the 500-file mix on top of it and says which work was being indexed; S2.14 holds the three peak runs of (g); the
// per-id table says which recipe and index each of S2.1 to S2.8 and S2.15 to S2.17 uses. Written from the entry plan-6-t9 (part B), the feature
// map S2 and the controller's decision (the mix500 start-on-top of S2.11 is also what makes the indexer busy for S2.10 and S2.14 (ii) and (iii):
// a finished index50k is idle). No product source is read.
//
// Nothing is launched. The checks run in a bash harness that sources the real common.sh, recipes.sh and every checks-*.sh, then replaces the
// recipe-level calls (`index50k_need`, `index50k_launch`, the picker, Settings) with logging functions and points `S2_PROBE`, `S2_MEM`, `S2_LD`,
// `S2_IDX` and `KIT_SCRIPTS` at a folder of stub scripts. A stub prints what the real script prints (formats read from the kit's own header text) and
// appends its call to a log; a test reads the log for order and the output for the figures. The figures a stub prints are set by the test.
//
// Interface the test fixes (the tester's picks, listed in the report):
//   - recipes.sh: `index50k_launch` (restore, then the app: a fresh launch on the restored index) and `index50k_need` (nothing when run/recipe holds
//     `index50k` and the app is running, else `recipe_index50k --restore-only`; a check never builds the hours-long cache).
//   - checks-s2.sh: every check starts with `s2_need_prep` (index50k_need, then `kit-index.sh rows` at least 50,000 else exit 4); the quiet launch
//     (peak (i), the quiet figures, S2.13, S2.12) runs on that state; launches a (S2.10), m (the mix alone, peak (ii)), b and c (S2.11, peak (iii)
//     around c) each restore with `index50k_launch` and add the mix with `s2_mix_on_top`, which drops run/recipe and writes the work note.
//   - the reading line of S2.9 to S2.14 ends `on the real 50,000-row index NOTE within bar|over bar`, with no "stand-in".
// Red before the kit part: the checks call recipe_busy50k and busy50k_launch, S2.9 makes a plain launch, S2.14 has one peak, no function above exists.

private let stubScript = #"""
#!/bin/bash
n="$(basename "$0")"
echo "$n $*" >> "$FAKE/calls.log"
pop() {
  local f="$FAKE/$1" v
  v="$(head -1 "$f" 2>/dev/null)"
  if [ -z "$v" ]; then echo "$2"; return; fi
  tail -n +2 "$f" > "$f.t"; mv "$f.t" "$f"
  echo "$v"
}
has_arg() { local w="$1" a; shift; for a in "$@"; do [ "$a" = "$w" ] && return 0; done; return 1; }
bar_of() {
  local d="$1"; shift
  while [ $# -gt 0 ]; do case "$1" in --bar-ms|--bar-bytes) echo "$2"; return ;; esac; shift; done
  echo "$d"
}
case "$n" in
  kit-index.sh)
    case "$1" in
      rows) echo "files ${FAKE_FILES:-30000}"; echo "passages ${FAKE_PASSAGES:-22000}"; echo "rows ${FAKE_ROWS:-52000}" ;;
      status)
        v="$(pop unread 0)"
        if [ "$v" -gt 0 ]; then echo "photo pending $v"; fi
        echo "photo done 100"; echo "files 100" ;;
      wait)
        case "$2" in
          rising) [ "${FAKE_RISING_RC:-0}" = 0 ] || echo "the rows did not rise"; exit ${FAKE_RISING_RC:-0} ;;
          done) [ "${FAKE_DONE_RC:-0}" = 0 ] || echo "not done in time"; exit ${FAKE_DONE_RC:-0} ;;
        esac ;;
    esac ;;
  kit-probe.sh)
    kind="$1"; ARGS_COPY="$*"
    if [ "${FAKE_BUSY_RERUN:-0}" = 1 ] && has_arg --busy "$@"; then echo "RERUN not valid: indexer was not busy after the last action (no file pending or partial)"; exit 4; fi
    fig="$(awk -F'\t' -v c="$*" '$1 != "" && index(c, $1) { print $2, $3; exit }' "$FAKE/figs.tsv" 2>/dev/null)"
    [ -n "$fig" ] || fig="20 60"
    set -- $fig
    med="$1"; max="$2"
    if [ "$kind" = opens ]; then def=200; else def=500; fi
    if has_arg --cold $ARGS_COPY 2>/dev/null; then def=2000; fi
    bar="$(bar_of "$def" $ARGS_COPY)"
    if [ "$max" -gt "$bar" ]; then v=OVER; else v=WITHIN; fi
    echo "$kind median $med ms max $max ms bar $bar ms $v BAR" ;;
  kit-mem.sh)
    case "$1" in
      peak)
        case "$2" in
          start) ;;
          stop)
            ctx="$(awk '/^kit-mem.sh peak start/ { buf = ""; next } { buf = buf "\n" $0 } END { print buf }' "$FAKE/calls.log")"
            case "$ctx" in
              *"build mix500"*) k=ii ;;
              *"--busy"*) k=iii ;;
              *"searches 20 --set distinct20"*) k=i ;;
              *) k=x ;;
            esac
            eval "val=\${FAKE_PEAK_$k:-900000000}"
            bar="$(bar_of 1500000000 "$@")"
            if [ "$val" -gt "$bar" ]; then v=OVER; else v=WITHIN; fi
            echo "READING peak_bytes=$val bar $bar $v BAR" ;;
        esac ;;
      idle)
        val="${FAKE_IDLE:-50000000}"
        bar="$(bar_of 100000000 "$@")"
        if [ "$val" -gt "$bar" ]; then v=OVER; else v=WITHIN; fi
        echo "READING idle_bytes=$val after 90 s bar $bar $v BAR" ;;
    esac ;;
  kit-ax.sh)
    case "$1" in
      read) echo "status item: Sesame ${FAKE_MENU:-Indexing}" ;;
    esac ;;
  kit-fixtures.sh)
    case "$1 $2" in
      "expect listing") echo "LISTING OK mix500: ${FAKE_MIX_PATHS:-500} paths" ;;
    esac ;;
esac
exit 0
"""#

private let stubNames = ["kit-index.sh", "kit-probe.sh", "kit-mem.sh", "kit-launch.sh", "kit-ax.sh", "kit-fixtures.sh"]

private struct S2Out {
    let out: String
    let calls: [String]
    let kit: String
}

/// Runs bash `body` (check calls) in the harness. `seq` writes the named sequence files (unread rows polled one per `kit-index.sh status`),
/// `figs` the probe's figures (substring of "<kind> <args>", median, max; first match wins).
private func s2Run(_ body: String, env: [String: String] = [:], seq: [String: [String]] = [:], figs: [(String, Int, Int)] = []) throws -> S2Out {
    let kit = try KC.kitRoot()
    let stubs = try KC.tempDir() + "/stubs"
    for name in stubNames {
        try KC.write(stubs + "/" + name, stubScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubs + "/" + name)
    }
    for (name, values) in seq { try KC.write(kit + "/fake/" + name, values.joined(separator: "\n") + "\n") }
    if !figs.isEmpty { try KC.write(kit + "/fake/figs.tsv", figs.map { "\($0.0)\t\($0.1)\t\($0.2)" }.joined(separator: "\n") + "\n") }
    let r = try KC.bash(#"""
    export FAKE="\#(kit)/fake"
    mkdir -p "$FAKE" "$KIT_ROOT/run"
    : > "$FAKE/calls.log"
    KIT_SCRIPTS="\#(stubs)"
    S2_PROBE="\#(stubs)/kit-probe.sh"; S2_MEM="\#(stubs)/kit-mem.sh"; S2_LD="\#(stubs)/kit-launch.sh"; S2_IDX="\#(stubs)/kit-index.sh"
    sleep() { :; }
    log() { printf '%s\n' "$*" >> "$FAKE/calls.log"; }
    index50k_need() {
      log "recipe need"
      if [ "${FAKE_NEED_RC:-0}" != 0 ]; then echo "${FAKE_NEED_MSG:-the recipe failed}"; return "$FAKE_NEED_RC"; fi
      printf 'index50k\n' > "$KIT_ROOT/run/recipe"; echo "index50k ready"
    }
    index50k_launch() {
      log "recipe launch"
      if [ "${FAKE_LAUNCH_RC:-0}" != 0 ]; then echo "${FAKE_LAUNCH_MSG:-the launch failed}"; return "$FAKE_LAUNCH_RC"; fi
      printf 'index50k\n' > "$KIT_ROOT/run/recipe"; echo "index50k ready"
    }
    recipe_index50k() { log "recipe_index50k $*"; return 1; }
    recipe_busy50k() { log "STAND-IN recipe_busy50k"; return 1; }
    busy50k_launch() { log "STAND-IN busy50k_launch"; return 1; }
    s8c_settings_open() { log "settings open"; return "${FAKE_SETTINGS_RC:-0}"; }
    drive_picker() { log "picker $1"; return "${FAKE_PICKER_RC:-0}"; }
    settings_section() { log "section $1"; }
    \#(body)
    """#, kit: kit, env: env.merging(["KIT_PLANT": env["KIT_PLANT"] ?? ""]) { a, _ in a }, limit: 120)
    let calls = KC.lines(KC.read(kit + "/fake/calls.log") ?? "")
    return S2Out(out: r.output, calls: calls, kit: kit)
}

private func idx(_ calls: [String], _ prefix: String, after: Int = -1) -> Int? {
    calls.indices.first { $0 > after && calls[$0].hasPrefix(prefix) }
}

private func count(_ calls: [String], _ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }

private func checkLines(_ out: String, _ id: String) -> [String] {
    KC.lines(out).filter { $0.hasPrefix("CHECK \(id) ") }
}

// MARK: kit text helpers

private func kitFunctionText(_ name: String) -> String? {
    var files = ["recipes.sh"]
    files += ((try? FileManager.default.contentsOfDirectory(atPath: KC.lib)) ?? []).filter { $0.hasPrefix("checks-") && $0.hasSuffix(".sh") }.sorted()
    for f in files {
        guard let text = KC.read(KC.lib + "/" + f) else { continue }
        if let body = KC.shellFunction(name, in: text) {
            return body.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        }
    }
    return nil
}

private func code(_ file: String) -> String {
    (KC.read(file) ?? "").split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
}

/// The per-id table of the entry: for each of S2.1 to S2.8 and S2.15 to S2.17, the functions that hold its starting call, the call that must be
/// there, the only starting calls it may hold, and the recipe and index it stands for (written by hand from the feature map and the kit's names).
struct S2Row {
    let id: String
    let fns: [String]
    let requires: [String]
    let allowed: Set<String>
    let recipeAndIndex: String
}

private let starters = ["s1_need_photos", "golden_need", "tree_need", "index50k", "busy50k", "recipe_photos", "recipe_golden", "recipe_tree", "recipe_mix500", "recipe_overlap"]

let perIdTable: [S2Row] = [
    S2Row(id: "S2.1", fns: ["check_S2_1"], requires: [#"s1_need_photos S2\.1 \|\| return"#, #"kit-golden\.sh"? engine --group a"#], allowed: ["s1_need_photos"], recipeAndIndex: "recipe photos, the photo-scoped index of the 40 golden photos (kit-golden.sh prepare)"),
    S2Row(id: "S2.2", fns: ["s2c_check_2"], requires: [#"s1_need_photos S2\.2 \|\| return"#, "engine --group b"], allowed: ["s1_need_photos"], recipeAndIndex: "recipe photos, the photo index"),
    S2Row(id: "S2.3", fns: ["s2c_check_3"], requires: [#"s1_need_photos S2\.3 \|\| return"#], allowed: ["s1_need_photos"], recipeAndIndex: "recipe photos, the photo index"),
    S2Row(id: "S2.4", fns: ["s2c_check_4"], requires: [#"golden_need; s3_need S2\.4 \$\? \|\| return"#, "engine --group c"], allowed: ["golden_need"], recipeAndIndex: "recipe golden, the whole index of golden photos, documents and clips (prepare --all)"),
    S2Row(id: "S2.5", fns: ["s4_check_s2_5"], requires: [#"golden_need; s3_need S2\.5 \$\? \|\| return"#, "engine --group d"], allowed: ["golden_need"], recipeAndIndex: "recipe golden, the whole index (prepare --all)"),
    S2Row(id: "S2.8", fns: ["s2c_check_8"], requires: [#"s1_need_photos S2\.8 \|\| return"#, #"unrelated[ ]+1000"#], allowed: ["s1_need_photos"], recipeAndIndex: "recipe photos plus 1,000 unrelated photos added through Settings (the mark is dropped afterwards)"),
    S2Row(id: "S2.15", fns: ["s2e_check_15", "s2e_saved_file"], requires: [#"for g in a b c d; do"#, #"golden-kept"#], allowed: [], recipeAndIndex: "no recipe and no index: reads the saved engine and panel runs of groups a to d in golden-kept/"),
    S2Row(id: "S2.17", fns: ["s2c_check_17"], requires: [#"tree_need S2\.17;"#, #"wait[ ]+done[ ]+900"#], allowed: ["tree_need"], recipeAndIndex: "recipe tree, the index of the full tree plus the golden repos (the ext- cells of the matrix)"),
]

@Suite("KitRunS2ClosingTests")
struct KitRunS2ClosingTests {

    // MARK: the per-id table

    @Test("the per-id table covers exactly S2.1 to S2.5, S2.8, S2.15 and S2.17: every id of checks.tsv in S2 that is not S2.9 to S2.14")
    func tableIsComplete() {
        let tsv = KC.checksTSV().map(\.id).filter { $0.hasPrefix("S2.") }
        let expected = tsv.filter { id in !(9...14).contains(Int(id.dropFirst(3)) ?? 0) }
        #expect(expected.count == 8, "checks.tsv holds \(tsv.count) S2 ids: \(tsv)")
        #expect(perIdTable.map(\.id) == expected, "the table lists \(perIdTable.map(\.id)), checks.tsv holds \(expected)")
    }

    @Test("each of S2.1 to S2.5, S2.8, S2.15 and S2.17 starts from its own recipe and index, holds no other starting call, and never touches index50k or busy50k", arguments: perIdTable)
    func perIdPin(_ row: S2Row) {
        var texts: [String] = []
        for fn in row.fns {
            guard let t = kitFunctionText(fn) else { Issue.record("\(fn) is not defined in the kit (\(row.id))"); return }
            texts.append(t)
        }
        let all = texts.joined(separator: "\n")
        for pattern in row.requires { #expect(KC.has(all, pattern), "\(row.id) (\(row.recipeAndIndex)): no `\(pattern)` in \(row.fns)") }
        for word in starters where !row.allowed.contains(word) {
            #expect(!all.contains(word), "\(row.id) (\(row.recipeAndIndex)): holds `\(word)`, a starting call it must not have")
        }
    }

    // MARK: the swap, as text

    @Test("checks-s2.sh has no busy50k name left and never calls recipe_index50k itself: a check restores the cache, it never builds it")
    func noStandInInTheChecks() {
        let text = code(KC.lib + "/checks-s2.sh")
        #expect(!text.contains("busy50k"), "checks-s2.sh still names busy50k")
        #expect(!KC.has(text, #"recipe_index50k"#), "checks-s2.sh calls recipe_index50k: only index50k_need (restore-only) may start the app on the cache")
        let need = kitFunctionText("index50k_need") ?? ""
        #expect(need.contains("recipe_index50k --restore-only"), "index50k_need does not call `recipe_index50k --restore-only`: \(need)")
        #expect(need.contains("index50k") && need.contains("kit_pid_of app"), "index50k_need does not read the recipe mark and the app's pid")
        #expect(!need.contains("--fake-embedder") && !need.contains("cache/index50k-$R_VERSION"), "index50k_need touches the stand-in")
    }

    @Test("index50k_launch is the restore and then the app, in that order, and never the stand-in")
    func launchFunction() {
        let launch = kitFunctionText("index50k_launch") ?? ""
        let r = launch.range(of: "index50k_restore"), a = launch.range(of: "index50k_app")
        #expect(r != nil && a != nil && r!.lowerBound < a!.lowerBound, "index50k_launch: \(launch)")
        #expect(!launch.contains("busy50k") && !launch.contains("--fake-embedder"), "index50k_launch names the stand-in")
    }

    @Test("every busy launch of S2 restores with index50k_launch first and adds the mix with s2_mix_on_top after it; s2_prep asks index50k_need")
    func launchesAreFresh() {
        for fn in ["s2_launch_a", "s2_launch_m", "s2_launch_bc"] {
            let t = kitFunctionText(fn) ?? ""
            let l = t.range(of: "index50k_launch"), m = t.range(of: "s2_mix_on_top")
            #expect(l != nil && m != nil && l!.lowerBound < m!.lowerBound, "\(fn) does not restore, then add the mix: \(t.prefix(300))")
            #expect(!t.contains("index50k_need") && !t.contains("recipe_index50k"), "\(fn) reuses a state instead of restoring a fresh index")
        }
        let prep = kitFunctionText("s2_prep") ?? ""
        #expect(prep.contains("index50k_need") && prep.contains("rows"), "s2_prep does not ask index50k_need and read the rows: \(prep)")
    }

    @Test("S2.10's set is distinct20: twenty plain queries with no code: line, and the probe has no partial note; the slice is 8 (plan-8-t9 amended: slice 7 to 8)")
    func noPartialLabel() {
        let queries = KC.read(KC.lib + "/queries-distinct20.txt") ?? ""
        let entries = KC.lines(queries).filter { !$0.hasPrefix("#") }
        #expect(entries.count == 20 && !queries.contains("code:") && !queries.contains("\t"), "distinct20 holds \(entries.count) queries, with a code: text or a tab")
        let probe = KC.read(KC.scripts + "/kit-probe.sh") ?? ""
        #expect(!probe.contains("QPARTIAL") && !probe.contains("note: partial"), "kit-probe.sh still has a partial note")
        #expect((KC.read(KC.lib + "/slice") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "8", "slice is not 8")
        let s10 = kitFunctionText("s2_launch_a") ?? ""
        #expect(KC.has(s10, #"searches 20 --set distinct20 --busy"#), "launch a does not run the 20 distinct20 searches busy")
    }

    // MARK: index50k_need and index50k_launch, as behaviour

    private func needRun(mark: String?, app: Bool, restoreRC: Int = 0) throws -> (String, [String]) {
        let kit = try KC.kitRoot()
        let r = try KC.bash(#"""
        FAKE="$KIT_ROOT/fake"; mkdir -p "$FAKE" "$KIT_ROOT/run"; : > "$FAKE/calls.log"
        \#(mark.map { "printf '\($0)\\n' > \"$KIT_ROOT/run/recipe\"" } ?? "rm -f \"$KIT_ROOT/run/recipe\"")
        kit_need_ps() { return 0; }
        kit_pid_of() { \#(app ? "echo 4242" : "true"); }
        recipe_index50k() { echo "recipe_index50k $*" >> "$FAKE/calls.log"; return \#(restoreRC); }
        index50k_need; echo "RC $?"
        """#, kit: kit)
        return (r.output, KC.lines(KC.read(kit + "/fake/calls.log") ?? ""))
    }

    @Test("index50k_need keeps a running app on the index50k mark and calls `recipe_index50k --restore-only` for every other state; its status comes through")
    func needBehaviour() throws {
        let kept = try needRun(mark: "index50k", app: true)
        #expect(kept.0.contains("RC 0") && kept.1.isEmpty, "mark and app: \(kept.0) \(kept.1)")
        for (mark, app) in [(String?.none, true), ("index50k", false), ("golden", true), ("golden-code", true), ("tree -", true)] {
            let r = try needRun(mark: mark, app: app)
            #expect(r.1 == ["recipe_index50k --restore-only"] && r.0.contains("RC 0"), "mark \(mark ?? "none") app \(app): \(r.1) \(r.0)")
        }
        let failed = try needRun(mark: nil, app: false, restoreRC: 4)
        #expect(failed.0.contains("RC 4"), "the recipe's exit 4 did not come through: \(failed.0)")
    }

    @Test("index50k_launch reads the run's id and version itself (a check calls it inside $(...)), then runs the restore, then the app; a restore that fails stops it with the same status")
    func launchBehaviour() throws {
        let text = kitFunctionText("index50k_launch") ?? ""
        #expect(KC.has(text, #"recipe_state \|\| return"#), "index50k_launch does not call recipe_state: R_ID and R_VERSION are empty in the subshell of a check")
        let bare = try KC.bash(#"""
        FAKE="$KIT_ROOT/fake"; mkdir -p "$FAKE"; : > "$FAKE/calls.log"
        index50k_restore() { echo restore >> "$FAKE/calls.log"; return 0; }
        index50k_app() { echo app >> "$FAKE/calls.log"; return 0; }
        index50k_launch; echo "RC $?"
        """#, kit: try KC.kitRoot())
        #expect(bare.output.contains("RC 4") && bare.output.contains("no starting state"), "with no run id it must stop: \(bare.output)")
        for rc in [0, 4] {
            let kit = try KC.kitRoot()
            let r = try KC.bash(#"""
            FAKE="$KIT_ROOT/fake"; mkdir -p "$FAKE" "$KIT_ROOT/run"; : > "$FAKE/calls.log"
            printf 'S2\n' > "$KIT_ROOT/run/id"; printf 'v1\n' > "$KIT_ROOT/run/version"
            index50k_restore() { echo restore >> "$FAKE/calls.log"; return \#(rc); }
            index50k_app() { echo app >> "$FAKE/calls.log"; return 0; }
            index50k_launch; echo "RC $?"
            """#, kit: kit)
            let calls = KC.lines(KC.read(kit + "/fake/calls.log") ?? "")
            #expect(calls == (rc == 0 ? ["restore", "app"] : ["restore"]) && r.output.contains("RC \(rc)"), "restore rc \(rc): \(calls) \(r.output)")
        }
    }

    // MARK: S2.9

    @Test("S2.9 asks the prepared state, reads the rows, then opens the panel 20 times with the app idle: no plain launch, no reset, and no `stand-in` in the line")
    func s29Reading() throws {
        let r = try s2Run("check_S2_9; echo \"RC $?\"", figs: [("opens 20", 31, 77)])
        #expect(r.out.contains("RC 0"), "exit: \(r.out.suffix(300))")
        #expect(checkLines(r.out, "S2.9") == ["CHECK S2.9 NEEDS-A-PERSON reading median 31 ms max 77 ms bar 200 ms on the real 50,000-row index NOTE within bar"], "lines: \(checkLines(r.out, "S2.9"))")
        let need = idx(r.calls, "recipe need"), rows = idx(r.calls, "kit-index.sh rows"), probe = idx(r.calls, "kit-probe.sh opens 20")
        #expect(need != nil && rows != nil && probe != nil && need! < rows! && rows! < probe!, "order: \(r.calls)")
        #expect(count(r.calls, "recipe launch") == 0 && count(r.calls, "kit-launch.sh") == 0 && count(r.calls, "STAND-IN") == 0, "S2.9 launched or reset: \(r.calls)")
        #expect(!r.out.contains("stand-in"), "the stand-in label is still printed")
    }

    @Test("S2.9 over its bar says `NOTE over bar`")
    func s29Over() throws {
        let r = try s2Run("check_S2_9; echo \"RC $?\"", figs: [("opens 20", 90, 260)])
        #expect(checkLines(r.out, "S2.9") == ["CHECK S2.9 NEEDS-A-PERSON reading median 90 ms max 260 ms bar 200 ms on the real 50,000-row index NOTE over bar"], "lines: \(checkLines(r.out, "S2.9"))")
    }

    @Test("an index under 50,000 rows is exit 4 `RERUN` that names the count, and the probe never runs (S2.9 to S2.14 all start so)")
    func rowsGuard() throws {
        for id in ["S2.9", "S2.10", "S2.11", "S2.12", "S2.13", "S2.14"] {
            let n = id.replacingOccurrences(of: ".", with: "_")
            let r = try s2Run("check_\(n); echo \"RC $?\"", env: ["FAKE_ROWS": "49999"])
            #expect(r.out.contains("RC 4") && r.out.contains("RERUN \(id) not valid:") && r.out.contains("49999"), "\(id): \(r.out.suffix(300))")
            #expect(checkLines(r.out, id).isEmpty, "\(id) printed a CHECK line for a short index")
            #expect(count(r.calls, "kit-probe.sh") == 0 && count(r.calls, "kit-mem.sh") == 0 && count(r.calls, "recipe launch") == 0, "\(id) measured on a short index: \(r.calls)")
        }
    }

    @Test("a missing or stale cache is exit 4 `RERUN` that says to run `prep index50k` (hours) first, for every id; nothing is measured")
    func noCache() throws {
        for id in ["S2.9", "S2.10", "S2.11", "S2.14"] {
            let n = id.replacingOccurrences(of: ".", with: "_")
            let r = try s2Run("check_\(n); echo \"RC $?\"", env: ["FAKE_NEED_RC": "4", "FAKE_NEED_MSG": "no cache for saved version v1 in /x/cache/index50k-real-v1"])
            #expect(r.out.contains("RC 4") && r.out.contains("RERUN \(id) not valid:") && r.out.contains("no cache for saved version v1"), "\(id): \(r.out.suffix(300))")
            #expect(r.out.contains("prep index50k"), "\(id): the reason does not say to run kit-run.sh prep index50k: \(r.out.suffix(300))")
            #expect(count(r.calls, "kit-probe.sh") == 0, "\(id) measured with no index")
        }
    }

    @Test("a person step of the recipe (exit 3) is `CHECK ... NEEDS-A-PERSON`, never a failure")
    func needsPerson() throws {
        let r = try s2Run("check_S2_9; echo \"RC $?\"", env: ["FAKE_NEED_RC": "3", "FAKE_NEED_MSG": "NEEDS A PERSON: Accessibility is not granted"])
        #expect(r.out.contains("CHECK S2.9 NEEDS-A-PERSON Accessibility is not granted") && r.out.contains("RC 0"), "output: \(r.out.suffix(300))")
    }

    // MARK: S2.10

    private func busyOrder(_ calls: [String], probe: String) -> Bool {
        guard let l = idx(calls, "recipe launch"), let b = idx(calls, "kit-fixtures.sh build mix500", after: l), let p = idx(calls, "picker ", after: b),
              let s = idx(calls, "kit-ax.sh click Start indexing", after: p), let w = idx(calls, "kit-index.sh wait rising", after: s),
              let m = idx(calls, probe, after: w) else { return false }
        return l < b && b < p && p < s && s < w && w < m
    }

    @Test("S2.10 restores a fresh index50k, puts mix500 on top (build, picker, Start indexing, rows rising), then runs the 20 distinct20 searches with --busy; the line names mix500 and its file count")
    func s210Flow() throws {
        let r = try s2Run("check_S2_10; echo \"RC $?\"", figs: [("--set distinct20 --busy", 95, 210), ("--set distinct20b", 40, 90)])
        #expect(r.out.contains("RC 0"), "exit: \(r.out.suffix(400))")
        #expect(busyOrder(r.calls, probe: "kit-probe.sh searches 20 --set distinct20 --busy"), "launch, mix and probe are out of order: \(r.calls)")
        #expect(checkLines(r.out, "S2.10") == ["CHECK S2.10 NEEDS-A-PERSON reading median 95 ms max 210 ms while indexing mix500 (500 files) bar 500 ms on the real 50,000-row index NOTE within bar"], "lines: \(checkLines(r.out, "S2.10"))")
        #expect(r.out.contains("the quiet total (nothing busy, set distinct20b): median 40 ms max 90 ms"), "the quiet total is not printed: \(r.out.suffix(500))")
        #expect(count(r.calls, "STAND-IN") == 0, "the stand-in was called")
    }

    @Test("S2.10 takes its quiet figures first, on the prepared state, before the busy launch replaces the app")
    func s210QuietFirst() throws {
        let r = try s2Run("check_S2_10; echo \"RC $?\"")
        let quiet = idx(r.calls, "kit-probe.sh searches 20 --set distinct20b"), launch = idx(r.calls, "recipe launch")
        #expect(quiet != nil && launch != nil && quiet! < launch!, "the quiet figures come after the busy launch: \(r.calls)")
        let busy = r.calls.first { $0.hasPrefix("kit-probe.sh searches 20 --set distinct20 --busy") }
        #expect(busy != nil, "no busy search call")
        #expect(r.calls.filter { $0.hasPrefix("kit-probe.sh") && !$0.contains("--busy") && !$0.contains("--cold") && $0.contains("opens") == false }.count >= 2, "the quiet searches were not run: \(r.calls)")
    }

    @Test("S2.10 over 500 ms prints STOP-ASK U18 and `NOTE over bar` (the bar is not lowered)")
    func s210Over() throws {
        let r = try s2Run("check_S2_10; echo \"RC $?\"", figs: [("--set distinct20 --busy", 300, 700)])
        #expect(r.out.contains("NOTE over bar") && r.out.contains("STOP-ASK U18"), "output: \(r.out.suffix(500))")
    }

    @Test("S2.10 whose indexer was not busy (the probe's own busy check, exit 4) is RERUN; a mix that never starts to rise is RERUN naming the launch")
    func s210Reruns() throws {
        let notBusy = try s2Run("check_S2_10; echo \"RC $?\"", env: ["FAKE_BUSY_RERUN": "1"])
        #expect(notBusy.out.contains("RC 4") && notBusy.out.contains("RERUN S2.10 not valid:") && notBusy.out.contains("not busy"), "output: \(notBusy.out.suffix(400))")
        #expect(checkLines(notBusy.out, "S2.10").isEmpty, "a reading was printed for an idle indexer")
        let noRise = try s2Run("check_S2_10; echo \"RC $?\"", env: ["FAKE_RISING_RC": "4"])
        #expect(noRise.out.contains("RC 4") && noRise.out.contains("RERUN S2.10 not valid: launch a:") && noRise.out.contains("rows did not rise"), "output: \(noRise.out.suffix(400))")
        #expect(count(noRise.calls, "kit-probe.sh searches 20 --set distinct20 --busy") == 0, "the busy searches ran with no mix indexing")
        let noLaunch = try s2Run("check_S2_10; echo \"RC $?\"", env: ["FAKE_LAUNCH_RC": "1", "FAKE_LAUNCH_MSG": "the app did not start"])
        #expect(noLaunch.out.contains("RC 1") && noLaunch.out.contains("CHECK S2.10 FAIL no reading: launch a: the app did not start"), "output: \(noLaunch.out.suffix(400))")
    }

    // MARK: S2.11

    @Test("S2.11: two fresh launches, each with a `stop` first and the mix on top, then 20 busy opens (b) and 20 distinct20b busy searches (c); the line names mix500 and its file count beside the figures")
    func s211Flow() throws {
        let r = try s2Run("check_S2_11; echo \"RC $?\"", seq: ["unread": ["480", "300", "300", "120"]],
                          figs: [("opens 20 --busy", 31, 77), ("--set distinct20b --busy", 121, 301)])
        #expect(r.out.contains("RC 0"), "exit: \(r.out.suffix(400))")
        #expect(checkLines(r.out, "S2.11") == ["CHECK S2.11 NEEDS-A-PERSON reading busy opens max 77 ms, busy searches median 121 ms max 301 ms while indexing mix500 (500 files) bar 200 ms for opens, 500 ms for searches on the real 50,000-row index NOTE within bar"], "lines: \(checkLines(r.out, "S2.11"))")
        #expect(count(r.calls, "recipe launch") == 2 && count(r.calls, "kit-launch.sh stop") == 2, "launches: \(r.calls)")
        #expect(busyOrder(r.calls, probe: "kit-probe.sh opens 20 --busy"), "launch b out of order: \(r.calls)")
        let launches = r.calls.indices.filter { r.calls[$0] == "recipe launch" }
        let stops = r.calls.indices.filter { r.calls[$0].hasPrefix("kit-launch.sh stop") }
        #expect(zip(stops, launches).allSatisfy { $0 < $1 }, "a launch came before its stop: \(r.calls)")
        #expect(launches.count == 2 && busyOrder(Array(r.calls[launches[launches.count - 1]...]), probe: "kit-probe.sh searches 20 --set distinct20b --busy"), "launch c out of order: \(r.calls)")
        #expect(count(r.calls, "STAND-IN") == 0, "the stand-in was called")
    }

    @Test("S2.11 reads the unread rows before the first and after the last measurement of each launch, and the menu bar after it")
    func s211Reads() throws {
        let r = try s2Run("check_S2_11; echo \"RC $?\"", seq: ["unread": ["480", "300", "300", "120"]])
        let status = r.calls.indices.filter { r.calls[$0] == "kit-index.sh status" }
        let probeB = idx(r.calls, "kit-probe.sh opens 20 --busy"), probeC = idx(r.calls, "kit-probe.sh searches 20 --set distinct20b --busy")
        #expect(status.count == 4 && probeB != nil && probeC != nil && status[0] < probeB! && probeB! < status[1] && status[2] < probeC! && probeC! < status[3], "status calls around the probes: \(r.calls)")
        #expect(count(r.calls, "kit-ax.sh read menubar") == 2, "the menu bar was read \(count(r.calls, "kit-ax.sh read menubar")) times, expected once per launch")
    }

    @Test("S2.11: indexing that ended before the readings did, never started, or a menu bar that does not say Indexing is exit 4 `RERUN`, never a pass")
    func s211Guard() throws {
        let cases: [(String, [String], [String: String], String)] = [
            ("ended before the last measurement of c", ["480", "300", "300", "0"], [:], "launch c:"),
            ("ended before the last measurement of b", ["480", "0", "300", "120"], [:], "launch b:"),
            ("nothing unread before b", ["0", "0", "300", "120"], [:], "launch b:"),
            ("the menu bar says Ready", ["480", "300", "300", "120"], ["FAKE_MENU": "Ready"], "menu bar did not say Indexing"),
            ("the rows never rise", ["480", "300", "300", "120"], ["FAKE_RISING_RC": "4"], "rows did not rise"),
        ]
        for (name, unread, env, why) in cases {
            let r = try s2Run("check_S2_11; echo \"RC $?\"", env: env, seq: ["unread": unread])
            #expect(r.out.contains("RC 4") && r.out.contains("RERUN S2.11 not valid:") && r.out.contains(why), "\(name): \(r.out.suffix(400))")
            #expect(checkLines(r.out, "S2.11").isEmpty, "\(name): a CHECK line was printed")
        }
    }

    @Test("S2.11's verdict is `over bar` when one busy open is over 200 ms or one busy search is over 500 ms")
    func s211Over() throws {
        let opens = try s2Run("check_S2_11; echo \"RC $?\"", seq: ["unread": ["480", "300", "300", "120"]], figs: [("opens 20 --busy", 100, 260)])
        #expect(checkLines(opens.out, "S2.11").first?.hasSuffix("NOTE over bar") == true, "opens: \(checkLines(opens.out, "S2.11"))")
        let searches = try s2Run("check_S2_11; echo \"RC $?\"", seq: ["unread": ["480", "300", "300", "120"]], figs: [("--set distinct20b --busy", 200, 640)])
        #expect(checkLines(searches.out, "S2.11").first?.hasSuffix("NOTE over bar") == true, "searches: \(checkLines(searches.out, "S2.11"))")
    }

    @Test("the work note counts the files with `kit-fixtures.sh expect listing mix500`, and says so when the count is not read")
    func mixNote() throws {
        let r = try s2Run("check_S2_11; echo \"RC $?\"", env: ["FAKE_MIX_PATHS": "497"], seq: ["unread": ["480", "300", "300", "120"]])
        #expect(checkLines(r.out, "S2.11").first?.contains("while indexing mix500 (497 files)") == true, "lines: \(checkLines(r.out, "S2.11"))")
        #expect(count(r.calls, "kit-fixtures.sh expect listing mix500") >= 1, "the hand count was not asked: \(r.calls)")
    }

    @Test("a launch that adds the mix drops the recipe mark, so no later check takes the busy app for the plain index50k state")
    func markDropped() throws {
        let r = try s2Run("check_S2_10 >/dev/null; echo \"MARK [$(cat \"$KIT_ROOT/run/recipe\" 2>/dev/null)]\"")
        #expect(r.out.contains("MARK []"), "run/recipe is still set after a busy launch: \(r.out.suffix(200))")
    }

    // MARK: S2.12 and S2.13

    @Test("S2.12 and S2.13 run on the prepared state with nothing busy: 90 s idle first, then the cold search; no restore, no mix")
    func s212s213() throws {
        let r = try s2Run("check_S2_12; check_S2_13; echo \"RC $?\"", figs: [("--cold", 800, 800)])
        #expect(checkLines(r.out, "S2.12") == ["CHECK S2.12 NEEDS-A-PERSON reading first search after idle 800 ms bar 2000 ms on the real 50,000-row index NOTE within bar"], "S2.12: \(checkLines(r.out, "S2.12"))")
        #expect(checkLines(r.out, "S2.13") == ["CHECK S2.13 NEEDS-A-PERSON reading idle_bytes 50000000 90 s after the last search bar 100000000 bytes on the real 50,000-row index NOTE within bar"], "S2.13: \(checkLines(r.out, "S2.13"))")
        let idle = idx(r.calls, "kit-mem.sh idle 90"), cold = idx(r.calls, "kit-probe.sh searches 1 --set distinct20 --cold")
        #expect(idle != nil && cold != nil && idle! < cold!, "the cold search must follow the idle wait: \(r.calls)")
        #expect(count(r.calls, "recipe launch") == 0 && count(r.calls, "picker ") == 0, "S2.12 or S2.13 started a busy launch: \(r.calls)")
        #expect(count(r.calls, "kit-mem.sh idle 90") == 1, "the quiet launch ran twice")
    }

    // MARK: S2.14

    private func s214() throws -> S2Out {
        try s2Run("check_S2_14; echo \"RC $?\"", env: ["FAKE_PEAK_i": "700000000", "FAKE_PEAK_ii": "800000000", "FAKE_PEAK_iii": "900000000"], seq: ["unread": ["480", "300", "300", "120"]])
    }

    @Test("S2.14 reports the three peaks of (g): (i) 20 distinct searches with the index idle, (ii) the mix indexed with no search, (iii) the S2.11 run; each one's figure sits in its own place")
    func s214Three() throws {
        let r = try s214()
        #expect(r.out.contains("RC 0"), "exit: \(r.out.suffix(300))")
        #expect(checkLines(r.out, "S2.14") == ["CHECK S2.14 NEEDS-A-PERSON reading peaks (i) 700000000 bytes with 20 searches and the index idle, (ii) 800000000 bytes indexing mix500 (500 files) with no search, (iii) 900000000 bytes with 20 searches while indexing, summed over every Sesame process bar 1500000000 bytes on the real 50,000-row index NOTE within bar"], "lines: \(checkLines(r.out, "S2.14"))")
        #expect(count(r.calls, "kit-mem.sh peak start") == 3 && count(r.calls, "kit-mem.sh peak stop") == 3, "peak calls: \(r.calls.filter { $0.hasPrefix("kit-mem") })")
    }

    @Test("peak (i) wraps the 20 quiet searches only, peak (ii) wraps the mix being added and indexed to done (no search inside), peak (iii) wraps the busy searches of launch c only")
    func s214Placement() throws {
        let r = try s214()
        let starts = r.calls.indices.filter { r.calls[$0] == "kit-mem.sh peak start" }
        let stops = r.calls.indices.filter { r.calls[$0].hasPrefix("kit-mem.sh peak stop") }
        #expect(starts.count == 3 && stops.count == 3, "calls: \(r.calls)")
        guard starts.count == 3, stops.count == 3 else { return }
        let inside = { (k: Int) in Array(r.calls[starts[k]..<stops[k]]) }
        #expect(inside(0).contains("kit-probe.sh searches 20 --set distinct20") && !inside(0).contains { $0.contains("--busy") || $0.hasPrefix("picker ") || $0.contains("build mix500") }, "(i): \(inside(0))")
        #expect(inside(1).contains { $0.contains("build mix500") } && inside(1).contains { $0.hasPrefix("kit-index.sh wait done") } && !inside(1).contains { $0.hasPrefix("kit-probe.sh") }, "(ii): \(inside(1))")
        #expect(inside(2).contains("kit-probe.sh searches 20 --set distinct20b --busy") && !inside(2).contains { $0.hasPrefix("picker ") || $0.hasPrefix("recipe launch") }, "(iii): \(inside(2))")
        #expect(starts[0] < starts[1] && starts[1] < starts[2], "peak order: \(starts)")
    }

    @Test("peak (ii) waits for the mix to be done (kit-index.sh wait done, 14400 s as S6.11 allows) before it stops; a mix that is not done in time is RERUN")
    func s214MixDone() throws {
        let ok = try s214()
        #expect(count(ok.calls, "kit-index.sh wait done 14400") == 1, "calls: \(ok.calls.filter { $0.hasPrefix("kit-index.sh wait") })")
        let r = try s2Run("check_S2_14; echo \"RC $?\"", env: ["FAKE_DONE_RC": "1"], seq: ["unread": ["480", "300", "300", "120"]])
        #expect(r.out.contains("RC 4") && r.out.contains("RERUN S2.14 not valid:") && r.out.contains("not done"), "output: \(r.out.suffix(400))")
        #expect(checkLines(r.out, "S2.14").isEmpty, "a reading was printed for a mix that never finished")
        #expect(count(r.calls, "kit-mem.sh peak stop") == 3, "a peak sampler was left running: \(r.calls.filter { $0.hasPrefix("kit-mem") })")
    }

    @Test("S2.14 is over its bar when any one peak is, and prints MEMORY STOP when any one is above 1.30 GB")
    func s214Over() throws {
        for (key, label) in [("FAKE_PEAK_i", "(i)"), ("FAKE_PEAK_ii", "(ii)"), ("FAKE_PEAK_iii", "(iii)")] {
            var env = ["FAKE_PEAK_i": "700000000", "FAKE_PEAK_ii": "800000000", "FAKE_PEAK_iii": "900000000"]
            env[key] = "1400000000"
            let r = try s2Run("check_S2_14; echo \"RC $?\"", env: env, seq: ["unread": ["480", "300", "300", "120"]])
            #expect(checkLines(r.out, "S2.14").first?.hasSuffix("NOTE within bar") == true, "\(label) at 1.4 GB is still under 1.5 GB: \(checkLines(r.out, "S2.14"))")
            #expect(r.out.contains("MEMORY STOP") && r.out.contains("1400000000"), "\(label): no MEMORY STOP: \(r.out.suffix(300))")
            env[key] = "1600000000"
            let over = try s2Run("check_S2_14; echo \"RC $?\"", env: env, seq: ["unread": ["480", "300", "300", "120"]])
            #expect(checkLines(over.out, "S2.14").first?.hasSuffix("NOTE over bar") == true, "\(label) at 1.6 GB: \(checkLines(over.out, "S2.14"))")
        }
    }

    @Test("peak (iii) is a reading only while the mix is still being indexed: launch c ending before its last measurement, or its busy searches being invalid, is RERUN for S2.14 too")
    func s214PeakThreeGuard() throws {
        let ended = try s2Run("check_S2_14; echo \"RC $?\"", seq: ["unread": ["480", "300", "300", "0"]])
        #expect(ended.out.contains("RC 4") && ended.out.contains("RERUN S2.14 not valid: peak (iii):") && ended.out.contains("ended before the readings did"), "output: \(ended.out.suffix(400))")
        #expect(checkLines(ended.out, "S2.14").isEmpty, "a reading was printed with the mix already read")
        let notBusy = try s2Run("check_S2_14; echo \"RC $?\"", env: ["FAKE_BUSY_RERUN": "1"], seq: ["unread": ["480", "300", "300", "120"]])
        #expect(notBusy.out.contains("RC 4") && notBusy.out.contains("RERUN S2.14 not valid:") && notBusy.out.contains("not busy"), "output: \(notBusy.out.suffix(400))")
        #expect(checkLines(notBusy.out, "S2.14").isEmpty, "a reading was printed for an idle indexer")
    }

    @Test("planted (KIT_PLANT=1): every peak stop, the idle reading and every probe carry the 1-byte or 1 ms bar, and S2.14 prints FAIL planted")
    func s214Plant() throws {
        let r = try s2Run("check_S2_14; echo \"RC $?\"", env: ["KIT_PLANT": "1", "FAKE_PEAK_i": "700000000", "FAKE_PEAK_ii": "800000000", "FAKE_PEAK_iii": "900000000"], seq: ["unread": ["480", "300", "300", "120"]])
        let stops = r.calls.filter { $0.hasPrefix("kit-mem.sh peak stop") }
        #expect(stops.count == 3 && stops.allSatisfy { $0.contains("--bar-bytes 1") }, "peak stops: \(stops)")
        #expect(checkLines(r.out, "S2.14").first?.hasPrefix("CHECK S2.14 FAIL planted:") == true, "lines: \(checkLines(r.out, "S2.14"))")
        let probes = r.calls.filter { $0.hasPrefix("kit-probe.sh") }
        #expect(!probes.isEmpty && probes.allSatisfy { $0.contains("--bar-ms 1") }, "probes: \(probes)")
    }

    // MARK: the whole S2.9 to S2.14 run

    @Test("S2.9 to S2.14 in one run print exactly one CHECK line each, restore four fresh indexes (a, m, b, c), add the mix four times and take three peaks")
    func wholeRun() throws {
        let r = try s2Run("for i in 9 10 11 12 13 14; do check_S2_$i; done; echo \"RC $?\"", seq: ["unread": ["480", "300", "300", "120"]])
        let lines = KC.lines(r.out).filter { $0.hasPrefix("CHECK S2.") }
        #expect(lines.map { $0.components(separatedBy: " ")[1] } == ["S2.9", "S2.10", "S2.11", "S2.12", "S2.13", "S2.14"], "lines: \(lines)")
        #expect(lines.allSatisfy { $0.contains("NEEDS-A-PERSON reading") && $0.contains("on the real 50,000-row index") }, "lines: \(lines)")
        #expect(count(r.calls, "recipe launch") == 4, "fresh launches: \(count(r.calls, "recipe launch")), expected 4 (a, m, b, c): \(r.calls)")
        #expect(count(r.calls, "picker ") == 4 && count(r.calls, "kit-fixtures.sh build mix500") == 4, "the mix was added \(count(r.calls, "picker ")) times, expected 4")
        #expect(count(r.calls, "kit-mem.sh peak start") == 3, "peaks: \(count(r.calls, "kit-mem.sh peak start"))")
        #expect(count(r.calls, "recipe need") == 2, "the plain state was asked \(count(r.calls, "recipe need")) times, expected 2 (S2.9 and S2.10: once the quiet launch has run, the busy checks ask nothing): \(r.calls)")
        #expect(count(r.calls, "kit-mem.sh idle 90") == 1 && count(r.calls, "kit-probe.sh searches 1 --set distinct20 --cold") == 1, "the quiet launch ran \(count(r.calls, "kit-mem.sh idle 90")) times")
        #expect(r.out.contains("RC 0"), "exit: \(r.out.suffix(200))")
    }

    @Test("a check run alone in a later session still works: S2.14 on its own runs the quiet launch, the mix alone and launch c, in that order")
    func s214Alone() throws {
        let r = try s214()
        let q = idx(r.calls, "kit-mem.sh idle 90"), m = idx(r.calls, "kit-index.sh wait done 14400"), c = idx(r.calls, "kit-probe.sh searches 20 --set distinct20b --busy")
        #expect(q != nil && m != nil && c != nil && q! < m! && m! < c!, "order of the launches: \(r.calls)")
    }
}

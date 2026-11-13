import Foundation
import Testing


private let kitRunText = KC.read(KC.scripts + "/kit-run.sh") ?? ""

// MARK: the fake app for recipe_tree

private let treeHarness = #"""
FAKE="$KIT_ROOT/fake"
mkdir -p "$FAKE" "$KIT_ROOT/run" "$KIT_ROOT/fixtures" "$KIT_ROOT/home"
printf 'S8\n' > "$KIT_ROOT/run/id"
printf 'v1\n' > "$KIT_ROOT/run/version"
real_path "$KIT_ROOT" > "$FAKE/real-root"
LOG="$FAKE/calls.log"; : > "$LOG"
sleep() { :; }
models_check() { return 0; }
usage() { echo "usage: kit-run.sh prep ..." >&2; }
log() { printf '%s\n' "$*" >> "$LOG"; }
fake_clear() {
  : > "$FAKE/picked"; : > "$FAKE/store"; : > "$FAKE/starts"
  echo Folders > "$FAKE/section"; echo open > "$FAKE/setup-state"; echo 2 > "$FAKE/step"
  rm -f "$FAKE/settings-open" "$FAKE/started"
}
fake_clear
store_put() {
  awk -F'|' -v p="$1" -v r="$2" 'BEGIN { OFS = "|" }
    $1 == p { $2 = r; f = 1 }
    { print }
    END { if (!f) print p, r }' "$FAKE/store" > "$FAKE/store.new"
  mv "$FAKE/store.new" "$FAKE/store"
}
start_enabled() {
  [ ! -f "$FAKE/started" ] && return 0
  awk -F'|' '$2 == 0 { f = 1 } END { exit f ? 0 : 1 }' "$FAKE/store"
}
do_start() {
  : > "$FAKE/started"
  awk -F'|' 'BEGIN { OFS = "|" } NF { $2 = 1 } { print }' "$FAKE/store" > "$FAKE/store.new"
  mv "$FAKE/store.new" "$FAKE/store"
}
fake_setup_rewrite() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    store_put "$p" 0
  done < "$FAKE/picked"
}
drive_picker() {
  local r
  log "drive_picker $1"
  [ "${FAKE_NO_PICK:-0}" = 1 ] && return 0
  r="$(real_path "$1")" || return 1
  grep -qx "$r" "$FAKE/picked" || printf '%s\n' "$r" >> "$FAKE/picked"
}
fake_build() {
  local p
  case "$2" in
    tree) while IFS= read -r p; do case "$p" in tree/*) mkdir -p "$KIT_ROOT/fixtures/$p" ;; esac; done < <(tree_pick_list "$KIT_LIB/gate-matrix.csv") ;;
    matrix) while IFS= read -r p; do case "$p" in matrix/*) mkdir -p "$KIT_ROOT/fixtures/$p" ;; esac; done < <(tree_pick_list "$KIT_LIB/gate-matrix.csv") ;;
    repos) mkdir -p "$KIT_ROOT/home/Developer/api-client" "$KIT_ROOT/home/Developer/legacy-sync" "$KIT_ROOT/home/Developer/scratch-lab" ;;
  esac
}
render_setup() {
  local n p name
  if [ "$(cat "$FAKE/setup-state")" != open ]; then echo "no Sesame window"; return 1; fi
  n="$(cat "$FAKE/step")"
  echo 'AXWindow label="Sesame"'
  case "$n" in
    2)
      echo '  AXStaticText label="Step 2 of 4: Folders"'
      echo '  AXButton label="Add folder…"'
      while IFS= read -r p; do [ -n "$p" ] || continue
        name="${p##*/}"
        echo "  AXCheckBox label=\"$name\" desc=\"$name, 19 files\" help=\"$p\" value=\"1\""
      done < "$FAKE/picked"
      echo '  AXButton label="Start indexing"'
      echo '  AXButton label="Next"' ;;
    3)
      echo '  AXStaticText label="Step 3 of 4: Permissions"'
      echo '  AXButton label="Back"'
      echo '  AXButton label="Next"' ;;
    4)
      echo '  AXStaticText label="Step 4 of 4: Shortcut"'
      echo '  AXButton label="Back"'
      echo '  AXButton label="Finish"' ;;
  esac
}
render_settings() {
  local section p r name
  [ -f "$FAKE/settings-open" ] || { echo "no Settings window"; return 1; }
  section="$(cat "$FAKE/section")"
  echo 'AXWindow label="Settings"'
  case "$section" in
    Folders)
      echo '  AXButton label="Add folder…"'
      while IFS='|' read -r p r; do [ -n "$p" ] || continue
        name="${p##*/}"
        if [ "$r" = 1 ]; then echo "  AXCheckBox label=\"$name\" desc=\"$name, 3 photos, about 1 min\" help=\"$p\" value=\"1\""
        else echo "  AXCheckBox label=\"$name\" desc=\"$name, 3 photos, Waiting for Start indexing\" help=\"$p\" value=\"1\""; fi
      done < "$FAKE/store" ;;
    Indexing)
      if start_enabled; then echo '  AXButton label="Start indexing"'; else echo '  AXButton label="Start indexing" [disabled]'; fi ;;
  esac
}
fake_start_press() {
  if [ "$(cat "$FAKE/setup-state")" = open ] && [ "$(cat "$FAKE/step")" = 2 ]; then
    fake_setup_rewrite
    do_start
    echo "setup effective" >> "$FAKE/starts"
    return 0
  fi
  if [ -f "$FAKE/settings-open" ] && [ "$(cat "$FAKE/section")" = Indexing ]; then
    if start_enabled; then do_start; echo "settings effective" >> "$FAKE/starts"; else echo "settings ignored" >> "$FAKE/starts"; fi
    return 0
  fi
  return 1
}
press_button() {
  local n
  case "$1" in
    "Settings…") echo open > "$FAKE/settings-open"; return 0 ;;
    "File types"|Folders|Indexing|Search|About)
      [ -f "$FAKE/settings-open" ] || return 1
      echo "$1" > "$FAKE/section"
      return 0 ;;
    Next)
      [ "$(cat "$FAKE/setup-state")" = open ] || return 1
      n="$(cat "$FAKE/step")"
      [ "$n" -lt 4 ] && echo $((n + 1)) > "$FAKE/step"
      return 0 ;;
    Finish)
      [ "$(cat "$FAKE/setup-state")" = open ] && [ "$(cat "$FAKE/step")" = 4 ] || return 1
      fake_setup_rewrite
      echo closed > "$FAKE/setup-state"
      return 0 ;;
    "Start indexing") fake_start_press ;;
    *) return 0 ;;
  esac
}
fake_ax() {
  case "$1" in
    frontmost) echo Sesame ;;
    front-sesame|key|gotofolder) log "ax $*" ;;
    read) echo "status item: Sesame Ready" ;;
    dump) log "ax dump $2"; case "$2" in setup) render_setup ;; settings) render_settings ;; *) return 1 ;; esac ;;
    click) log "ax click $2"; press_button "$2" && echo clicked ;;
    *) log "ax $*" ;;
  esac
}
fake_index() {
  case "$1" in
    wait)
      case "$2" in
        started) [ -f "$FAKE/started" ] ;;
        *) return 0 ;;
      esac ;;
    *) return 0 ;;
  esac
}
kq() {
  local script; script="$(basename "$1")"; shift
  case "$script" in
    kit-ax.sh) fake_ax "$@" ;;
    kit-reset.sh) log "reset $*"; rm -f "$KIT_ROOT/run/recipe"; fake_clear ;;
    kit-launch.sh) log "launch $*" ;;
    kit-fixtures.sh) log "build $2"; fake_build "$@" ;;
    kit-mirror.sh) log "mirror $*" ;;
    kit-sums.sh) log "sums $*" ;;
    kit-privacy.sh) log "privacy $*" ;;
    kit-index.sh) log "index $*"; fake_index "$@" ;;
    *) log "unexpected $script $*"; return 99 ;;
  esac
}
"""#

private func treeRun(_ extra: String = "", env: [String: String] = [:]) throws -> (KC.Ran, String, [String], String) {
    let kit = try KC.kitRoot()
    let r = try KC.bash(treeHarness + "\nrecipe_state\nrecipe_tree\(extra); echo \"RC $?\"", kit: kit, env: env, limit: 300)
    let calls = KC.lines(KC.read(kit + "/fake/calls.log") ?? "")
    let real = (KC.read(kit + "/fake/real-root") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return (r, kit, calls, real)
}

private func appSpelling(_ path: String) -> String {
    for root in ["/var", "/tmp", "/etc"] where path.hasPrefix("/private" + root + "/") { return String(path.dropFirst("/private".count)) }
    return path
}

private let treePicked = ["tree/plain", "tree/excluded", "tree/unsupported", "tree/damaged", "tree/repo"]

private let matrixPicked = ["app-png", "app-txt", "caches-png", "cloud-sparse-jpg", "damaged", "damaged-code", "ext", "extav", "extcode", "extdoc", "hidden-config", "hidden-ssh",
                            "ignored-off", "ignored-on", "keys", "keys-code", "keys-extra", "ov-a/outer", "ov-a/outer/inner", "ov-b/outer", "ov-b/outer/inner", "ov-c/outer",
                            "ov-c/outer/inner", "ov-d/outer", "ov-d/outer/inner", "plain", "plain-code-on", "repo-off", "unsup", "vend-in", "vend-out"].map { "matrix/" + $0 }

@Suite("KitRunClosingChecksTests")
struct KitRunClosingChecksTests {
    private func pure(_ body: String) throws -> String {
        try KC.bash(body, kit: try KC.kitRoot()).output
    }

    @Test("tree_pick_list on the real table is exactly the five tree folders and the thirty-one matrix folders its plain picks and blank rows name: no tick suffix, no repo, no never-picked")
    func pickListPlain() throws {
        let out = KC.lines(try pure("tree_pick_list \"\(KC.lib)/gate-matrix.csv\""))
        #expect(Set(out) == Set(treePicked + matrixPicked), "extra \(Set(out).subtracting(treePicked + matrixPicked).sorted()), missing \(Set(treePicked + matrixPicked).subtracting(out).sorted())")
        #expect(out.count == Set(out).count && out == out.sorted(), "the list has a repeat or is not sorted")
        #expect(!out.contains { $0.contains(":") || $0.contains("never-picked") || $0.contains("Developer") || $0.contains("api-client") || $0.contains("legacy-sync") }, "a tick, never-picked or repo path is in the list: \(out)")
    }

    @Test("the tick lists and the code tick functions are gone: tree_tick_list, repo_tick_list and tree_code_ticks are not defined, repo_pick_list stays")
    func tickListsGone() throws {
        let out = try pure("for f in tree_tick_list repo_tick_list tree_code_ticks repo_pick_list; do if declare -F $f >/dev/null; then echo \"defined $f\"; else echo \"gone $f\"; fi; done")
        #expect(KC.lines(out) == ["gone tree_tick_list", "gone repo_tick_list", "gone tree_code_ticks", "defined repo_pick_list"], "functions: \(out)")
    }

    @Test("repo_pick_list returns the two repo folders, api-client and legacy-sync, and a missing table is exit 1")
    func repoLists() throws {
        #expect(KC.lines(try pure("repo_pick_list")) == ["home/Developer/api-client", "home/Developer/legacy-sync"])
        let none = try pure("repo_pick_list /nonexistent/repo-cells.tsv; echo \"RC $?\"")
        #expect(none.contains("RC 1"), "a missing table is exit 1: \(none)")
    }

    // MARK: part C: the recipe

    @Test("recipe_tree resets with --model mirror --baseline, builds the repos after the matrix, and prints no NOTE about code ticks")
    func treeResetAndBuilds() throws {
        let (r, _, calls, _) = try treeRun()
        #expect(r.output.contains("RC 0"), "recipe_tree did not finish: \(r.output.suffix(600))")
        #expect(calls.first { $0.hasPrefix("reset ") }?.contains("--model mirror --baseline") == true, "the reset: \(calls.first { $0.hasPrefix("reset ") } ?? "none")")
        let m = calls.firstIndex(of: "build matrix"), rp = calls.firstIndex(of: "build repos")
        #expect(m != nil && rp != nil && m! < rp!, "build matrix then build repos expected: \(calls.filter { $0.hasPrefix("build") })")
        #expect(!r.output.contains("NOTE code ticks are disabled"), "the NOTE is still printed")
    }

    @Test("recipe_tree picks the tree and matrix folders and both repos (never scratch-lab) and presses no tick: no code switch, no File types section, no click by help")
    func treePicks() throws {
        let (r, kit, calls, real) = try treeRun()
        #expect(r.output.contains("RC 0"), "recipe_tree did not finish: \(r.output.suffix(600))")
        let picked = Set(KC.lines(KC.read(kit + "/fake/picked") ?? ""))
        let want = Set((treePicked + matrixPicked).map { real + "/fixtures/" + $0 } + [real + "/home/Developer/api-client", real + "/home/Developer/legacy-sync"])
        #expect(picked == want, "picked: extra \(picked.subtracting(want).sorted()), missing \(want.subtracting(picked).sorted())")
        #expect(!picked.contains { $0.hasSuffix("scratch-lab") }, "scratch-lab was picked")
        let clicks = calls.filter { $0.hasPrefix("ax click") }
        #expect(clicks == ["ax click Next", "ax click Next", "ax click Finish", "ax click Settings…", "ax click Indexing", "ax click Start indexing"], "every click of the recipe: \(clicks)")
        #expect(!calls.contains { $0.contains("Search my code") || $0.contains("File types") || $0.contains("--help") }, "a code switch, File types or tick call was made: \(calls.filter { $0.contains("code") || $0.contains("File types") || $0.contains("--help") })")
    }

    @Test("recipe_tree: Setup is finished before Settings is opened, and the one Start is the Indexing section's, with `index wait started 120` after it and the rows rising after that")
    func treeOrder() throws {
        let (r, kit, calls, _) = try treeRun()
        #expect(r.output.contains("RC 0"), "recipe_tree did not finish: \(r.output.suffix(600))")
        let finish = calls.firstIndex(of: "ax click Finish"), settings = calls.firstIndex(of: "ax click Settings…")
        let starts = calls.indices.filter { calls[$0] == "ax click Start indexing" }
        #expect(calls.filter { $0 == "ax click Finish" }.count == 1, "Setup's Finish was pressed \(calls.filter { $0 == "ax click Finish" }.count) times")
        #expect(finish != nil && settings != nil && finish! < settings!, "Settings (call \(settings ?? -1)) was not opened after Setup's Finish (call \(finish ?? -1))")
        #expect(starts.count == 1, "Start indexing was pressed \(starts.count) times")
        let startsFile = KC.lines(KC.read(kit + "/fake/starts") ?? "")
        #expect(startsFile == ["settings effective"], "the Start presses were \(startsFile): `setup` is Start pressed while the Setup window was open")
        guard let start = starts.first else { Issue.record("no Start indexing in \(calls)"); return }
        #expect(settings != nil && settings! < start, "Start indexing (call \(start)) came before Settings was opened")
        let sectionClicks = ["ax click Indexing", "ax click Folders", "ax click File types", "ax click Search", "ax click About"]
        #expect(calls[..<start].last(where: { sectionClicks.contains($0) }) == "ax click Indexing", "Start was not pressed in the Indexing section")
        let started = calls.indices.first { $0 > start && calls[$0] == "index wait started 120" }
        let rising = calls.indices.first { $0 > start && calls[$0] == "index wait rising 60" }
        #expect(started != nil && rising != nil && started! < rising!, "`index wait started 120` then `index wait rising 60` were not both after Start: \(calls.suffix(5))")
    }

    @Test("recipe_tree: the picks are still there when indexing starts: the app lists exactly the pick list and both repos, one entry each, and every one is waiting at Start")
    func treePicksSurvive() throws {
        let (r, kit, _, real) = try treeRun()
        #expect(r.output.contains("RC 0"), "recipe_tree did not finish: \(r.output.suffix(600))")
        let want = Set((treePicked + matrixPicked).map { real + "/fixtures/" + $0 } + [real + "/home/Developer/api-client", real + "/home/Developer/legacy-sync"])
        let picked = KC.lines(KC.read(kit + "/fake/picked") ?? "")
        let store = KC.lines(KC.read(kit + "/fake/store") ?? "").map { $0.components(separatedBy: "|")[0] }
        #expect(Set(picked) == want && picked.count == want.count, "the folders listed at the end: extra \(Set(picked).subtracting(want).sorted()), missing \(want.subtracting(picked).sorted())")
        #expect(Set(store) == want && store.count == Set(store).count, "the store: extra \(Set(store).subtracting(want).sorted()), missing \(want.subtracting(store).sorted()), or an entry twice")
    }

    @Test("a pick that does not show in the Setup window is exit 4 `picked roots differ` with the difference, never a pass, and no Start is pressed")
    func treePickNotShown() throws {
        let (r, kit, calls, _) = try treeRun(env: ["FAKE_NO_PICK": "1"])
        #expect(r.output.contains("RC 4"), "exit: \(r.output.suffix(400))")
        #expect(r.output.contains("RERUN picked roots differ from the pick list") && r.output.contains("missing: matrix/"), "no reason: \(r.output.suffix(400))")
        #expect(!calls.contains("ax click Start indexing") && (KC.read(kit + "/fake/starts") ?? "").isEmpty, "a Start was pressed after a pick that did not show: \(KC.read(kit + "/fake/starts") ?? "")")
        #expect(!calls.contains { $0.hasPrefix("index wait started") }, "the recipe waited for a start it never made")
    }

    @Test("the recipe leaves `tree -` in run/recipe once everything is picked and started")
    func treeMark() throws {
        let (_, kit, _, _) = try treeRun()
        #expect((KC.read(kit + "/run/recipe") ?? "") == "tree -\n", "run/recipe: \(KC.read(kit + "/run/recipe") ?? "none")")
    }

    // MARK: part C: the golden repo cells in S8.5

    private static let apiIn = ["docs/retry-notes.md", "docs/retry-diagram.png"]

    private func indexed(_ kit: String, extra: [String] = [], without: [String] = []) -> [String] {
        let api = Self.apiIn.filter { !without.contains($0) }.map { kit + "/home/Developer/api-client/" + $0 }
        return api + [kit + "/home/Developer/legacy-sync/docs/diagram.png"] + extra
    }

    private func s85(extra: [String] = [], without: [String] = [], hasExit: Int = 0) throws -> KC.Ran {
        let kit = try KC.kitRoot()
        let listed = indexed(kit, extra: extra.map { kit + "/home/Developer/" + $0 }, without: without).joined(separator: "\n")
        return try KC.bash("""
        cat > "\(kit)/in-index.txt" <<'LIST'
        \(listed)
        LIST
        kq() {
          local script; script="$(basename "$1")"; shift
          if [ "$script" = kit-index.sh ] && [ "$1" = has ]; then
            [ "\(hasExit)" != 0 ] && { echo "boom"; return "\(hasExit)"; }
            grep -qxF -- "$2" "\(kit)/in-index.txt"
            return $?
          fi
          return 0
        }
        s8c_repo_cells S8.5; echo "RC $? REPOS $S8C_REPOS RED [$S8C_RED]"
        """, kit: kit)
    }

    @Test("the repo cells are green when api-client's two decoy documents and legacy-sync's picture are in the index and api-client's twelve code files and fourteen excluded files and merge.swift are not")
    func repoCellsGreen() throws {
        let r = try s85()
        #expect(r.output.contains("RC 0 REPOS 2 RED []"), "output: \(r.output)")
        #expect(r.output.contains("green golden-repo-api-client: 2 files in the index, 26 files not in it"), "api-client line: \(r.output)")
        #expect(r.output.contains("green golden-repo-legacy-sync: 1 files in the index, 1 files not in it"), "legacy-sync line: \(r.output)")
    }

    @Test("a decoy document missing from the index, an api-client code file or excluded file in it, and legacy-sync's code in it each turn the cell red")
    func repoCellsRed() throws {
        let missing = try s85(without: ["docs/retry-notes.md"])
        #expect(missing.output.contains("red golden-repo-api-client") && missing.output.contains("docs/retry-notes.md (listed as in the index, is not)") && missing.output.contains("RED [golden-repo-api-client]"), "missing: \(missing.output)")
        let code = try s85(extra: ["api-client/auth.swift"])
        #expect(code.output.contains("auth.swift (listed as not in the index, is)") && code.output.contains("RED [golden-repo-api-client]"), "code: \(code.output)")
        let excluded = try s85(extra: ["api-client/certs/server.pem"])
        #expect(excluded.output.contains("certs/server.pem (listed as not in the index, is)") && excluded.output.contains("RED [golden-repo-api-client]"), "excluded: \(excluded.output)")
        let legacy = try s85(extra: ["legacy-sync/merge.swift"])
        #expect(legacy.output.contains("merge.swift (listed as not in the index, is)") && legacy.output.contains("RED [golden-repo-legacy-sync]"), "legacy: \(legacy.output)")
    }

    @Test("a lookup that cannot answer is exit 4 `RERUN ... not valid`, never red")
    func repoCellsRerun() throws {
        let r = try s85(hasExit: 5)
        #expect(r.output.contains("RERUN S8.5 not valid: kit-index.sh has") && r.output.contains("RC 4"), "output: \(r.output)")
    }

    @Test("check_S8_5 reads repo-cells.tsv beside tree_pick_list over gate-matrix.csv, and its PASS line names the repo cells")
    func s85ReadsBoth() {
        let text = KC.read(KC.lib + "/checks-s8c.sh") ?? ""
        let fn = KC.shellFunction("check_S8_5", in: text) ?? ""
        #expect(fn.contains("tree_pick_list \"$KIT_LIB/gate-matrix.csv\""), "check_S8_5 no longer takes its folders from tree_pick_list over gate-matrix.csv")
        #expect(fn.contains("s8c_repo_cells S8.5"), "check_S8_5 does not read the repo cells")
        #expect(fn.contains("golden repo cells"), "the PASS line does not name the repo cells")
        let cells = KC.shellFunction("s8c_repo_cells", in: text) ?? ""
        #expect(cells.contains("repo-cells.tsv"), "s8c_repo_cells does not read repo-cells.tsv")
    }

    @Test("repo-cells.tsv agrees with repos.tsv, the hand table of the repo builder: its in-index files are the decoy and picture rows, its out files every code file and the excluded rows")
    func repoCellsMatchRepos() throws {
        let repos = (KC.read(KC.lib + "/repos.tsv") ?? "").components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
        func files(_ repo: String, _ types: [String]) -> Set<String> { Set(repos.filter { $0[0].isEmpty ? false : types.contains($0[0]) && $0[1] == repo }.map { $0[2] }) }
        let cells = (KC.read(KC.lib + "/repo-cells.tsv") ?? "").components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
        #expect(cells.count == 2 && cells.map { $0[0] } == ["golden-repo-api-client", "golden-repo-legacy-sync"], "cells: \(cells.map { $0[0] })")
        #expect(cells.allSatisfy { $0.count == 4 }, "a repo cell has no code tick column: \(cells.map(\.count))")
        let api = try #require(cells.first { $0[1] == "api-client" }), legacy = try #require(cells.first { $0[1] == "legacy-sync" })
        #expect(Set(api[2].components(separatedBy: ",")) == files("api-client", ["decoy"]), "api-client in-index files differ from repos.tsv")
        #expect(Set(api[3].components(separatedBy: ",")) == files("api-client", ["def", "call", "excluded"]), "api-client files not in the index differ from repos.tsv")
        #expect(Set(legacy[2].components(separatedBy: ",")) == files("legacy-sync", ["picture"]), "legacy-sync in-index files differ from repos.tsv")
        #expect(Set(legacy[3].components(separatedBy: ",")) == files("legacy-sync", ["def"]), "legacy-sync out files differ from repos.tsv")
        #expect(api[2].components(separatedBy: ",").count == 2 && api[3].components(separatedBy: ",").count == 26, "api-client holds 2 in and 26 out files (12 sources and 14 excluded)")
    }

    // MARK: part D: the id set, the floor, the slice

    /// `run_checks` of kit-run.sh as a function, over a stub for every id: `verdicts` maps an id to PASS, FAIL or NEEDS (needs-a-person); the rest PASS.
    private func closingRun(_ args: String, verdict: (String, Int, String) -> String, undefine: [String] = []) throws -> KC.Ran {
        let kit = try KC.kitRoot()
        let dir = try KC.tempDir()
        let fn = KC.shellFunction("run_checks", in: kitRunText) ?? "run_checks() { echo MISSING; }"
        try KC.write(dir + "/run_checks.sh", fn)
        var stubs = ""
        for row in KC.checksTSV() {
            let name = "check_" + row.id.replacingOccurrences(of: ".", with: "_")
            switch verdict(row.id, row.slice, row.kind) {
            case "FAIL": stubs += "\(name)() { echo \"CHECK \(row.id) FAIL stub\"; return 1; }\n"
            case "NEEDS": stubs += "\(name)() { echo \"CHECK \(row.id) NEEDS-A-PERSON stub\"; return 0; }\n"
            default: stubs += "\(name)() { echo \"CHECK \(row.id) PASS stub\"; return 0; }\n"
            }
        }
        for id in undefine { stubs += "unset -f check_\(id.replacingOccurrences(of: ".", with: "_"))\n" }
        return try KC.bash("""
        . "\(dir)/run_checks.sh"
        kq() { return 0; }
        \(stubs)
        run_checks \(args); echo "RC $?"
        """, kit: kit)
    }

    private let admin: Set<String> = ["S6.8", "S8.2", "S8.3", "S8.7", "S6.13"]

    @Test("all --slice 6 prints a CHECK line for every one of the 106 ids of slices 1 to 6, in checks.tsv order, and exits 0 when none fails; all --slice 7 prints the 112 with S9.1 to S9.6 last (plan-7-t10 amended: the table now holds 112 ids, the six S9 ids are slice 7)")
    func everyIdPrinted() throws {
        let r = try closingRun("all 6 \"\" \"\"", verdict: { _, _, _ in "PASS" })
        let printed = KC.lines(r.output).filter { $0.hasPrefix("CHECK ") }.map { $0.components(separatedBy: " ")[1] }
        let all = KC.checksTSV().filter { $0.slice <= 6 }.map(\.id)
        #expect(all.count == 106 && printed == all, "printed \(printed.count) ids, checks.tsv holds \(all.count) of slices 1 to 6")
        #expect(r.output.contains("CHECKS: 106 passed, 0 failed, 0 skipped, 0 needs-a-person") && r.output.contains("RC 0"), "tail: \(r.output.suffix(300))")
        let seven = try closingRun("all 7 \"\" \"\"", verdict: { _, _, _ in "PASS" })
        let printedSeven = KC.lines(seven.output).filter { $0.hasPrefix("CHECK ") }.map { $0.components(separatedBy: " ")[1] }
        #expect(printedSeven.count == 112 && Array(printedSeven.suffix(6)) == ["S9.1", "S9.2", "S9.3", "S9.4", "S9.5", "S9.6"], "slice 7 printed \(printedSeven.count) ids, ending \(printedSeven.suffix(6))")
        #expect(seven.output.contains("CHECKS: 112 passed, 0 failed, 0 skipped, 0 needs-a-person") && seven.output.contains("RC 0"), "tail: \(seven.output.suffix(300))")
        let eight = try closingRun("all 8 \"\" \"\"", verdict: { _, _, _ in "PASS" })
        let printedEight = KC.lines(eight.output).filter { $0.hasPrefix("CHECK ") }.map { $0.components(separatedBy: " ")[1] }
        #expect(printedEight.count == 121 && Array(printedEight.suffix(9)) == (1...9).map { "S10.\($0)" }, "slice 8 printed \(printedEight.count) ids, ending \(printedEight.suffix(9)) (plan-8-t9 added: the nine S10 ids are slice 8)")
        #expect(eight.output.contains("CHECKS: 121 passed, 0 failed, 0 skipped, 0 needs-a-person") && eight.output.contains("RC 0"), "tail: \(eight.output.suffix(300))")
    }

    @Test("an id of S2, S6 or S8 whose check is missing is a failed run that names it: `CHECK <id> FAIL no check written`, exit 1")
    func missingIdFails() throws {
        for id in ["S2.9", "S2.17", "S6.11", "S8.12"] {
            let scen = String(id.prefix(2))
            let r = try closingRun("\(scen) 6 \"\" \"\"", verdict: { _, _, _ in "PASS" }, undefine: [id])
            #expect(r.output.contains("CHECK \(id) FAIL no check written"), "\(id): \(r.output.suffix(300))")
            #expect(r.output.contains("RC 1") && r.output.contains("1 failed"), "\(id): the run did not fail: \(r.output.suffix(200))")
        }
    }

    @Test("the scenario runs of S2, S6 and S8 print exactly their ids: 14, 12 and 13")
    func scenarioRunsPrintAllIds() throws {
        for (scen, count) in [("S2", 14), ("S6", 12), ("S8", 13)] {
            let r = try closingRun("\(scen) 6 \"\" \"\"", verdict: { _, _, _ in "PASS" })
            let printed = KC.lines(r.output).filter { $0.hasPrefix("CHECK ") }
            #expect(printed.count == count, "\(scen) printed \(printed.count) ids, expected \(count)")
            #expect(printed.allSatisfy { $0.hasPrefix("CHECK \(scen).") }, "\(scen) printed another scenario's id")
        }
    }

    @Test("checks.floor is the closing recount: the 93 auto ids of slices 1 to 8 that need no administrator rights (98 auto rows less the five administrator ids), no auto-or-person id counted; slice is 8 (plan-8-t9 amended: the two auto ids S10.5 and S10.8 added to the 91, 93 = 91 + 2; was 91 and slice 7)")
    func floorIsTheClosingRecount() {
        let all = KC.checksTSV()
        let autos = all.filter { $0.kind == "auto" && $0.slice <= 8 && !admin.contains($0.id) }
        #expect(autos.count == 93, "the recount of auto ids without administrator rights is \(autos.count), the hand count is 93")
        #expect(all.filter { $0.kind == "auto" }.count == 98 && all.filter { $0.kind == "auto-or-person" }.count == 17, "checks.tsv does not hold 98 auto and 17 auto-or-person rows")
        let floor = Int((KC.read(KC.lib + "/checks.floor") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(floor == 93 && floor == autos.count, "checks.floor reads \(floor.map(String.init) ?? "nothing"), the closing recount is \(autos.count)")
        #expect((KC.read(KC.lib + "/slice") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "8", "slice does not hold 8")
    }

    /// Passes of a full run when the readings, the administrator ids and every auto-or-person id need a person, `short` needs one too, and everything else passes.
    private func floorRun(short: String? = nil) throws -> KC.Ran {
        try closingRun("all 8 \"\" \"\"", verdict: { id, _, kind in
            if kind == "reading" || kind == "auto-or-person" || admin.contains(id) || id == short { return "NEEDS" }
            return "PASS"
        })
    }

    @Test("the floor counts auto ids only: a full run with every other id needing a person has 93 passes and exits 0; with one auto id needing a person it has 92, is below checks.floor and exits 1 (plan-8-t9 amended: slice 8, the two S10 auto ids; was 91 and 90)")
    func floorCountsAutoIdsOnly() throws {
        let ok = try floorRun()
        #expect(ok.output.contains("CHECKS: 93 passed, 0 failed") && ok.output.contains("RC 0") && !ok.output.contains("below checks.floor"), "every auto id passes: \(ok.output.suffix(300))")
        for id in ["S1.1", "S2.15", "S8.12", "S9.3", "S10.5"] {
            let short = try floorRun(short: id)
            #expect(short.output.contains("CHECKS: 92 passed, 0 failed"), "\(id) needing a person: \(short.output.suffix(300))")
            #expect(short.output.contains("note: 92 passed, below checks.floor (93 passes; needs-a-person does not count)") && short.output.contains("RC 1"), "\(id): the run is not below the floor: \(short.output.suffix(300))")
        }
    }

    @Test("verify.sh at slice 6 runs `kit-run.sh all --slice $SLICE` with SLICE from the slice file, so its CHECKS line holds every id")
    func verifyRunsSlice6() throws {
        let text = KC.read(KC.scripts + "/verify.sh") ?? ""
        #expect(text.contains("local quick=0 plant=\"\" only=\"\" SLICE=\"$KIT_SLICE\""), "verify.sh no longer defaults SLICE to KIT_SLICE")
        let fn = KC.shellFunction("run_kit_run", in: text) ?? ""
        #expect(fn.contains("\"$VERIFY_BIN/kit-run.sh\" \"$scen\" --slice \"$SLICE\""), "run_kit_run does not pass --slice \"$SLICE\"")
        #expect(fn.contains("scen=\"${1:-all}\""), "run_kit_run does not default to all")
        let r = try KC.bash("echo \"$KIT_SLICE\"", kit: try KC.kitRoot())
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "8", "KIT_SLICE is \(r.output)")
        #expect(KC.checksTSV().allSatisfy { $0.slice <= 8 }, "an id of checks.tsv is first drivable after slice 8")
    }
}

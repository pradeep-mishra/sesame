import Foundation
import Testing

private let kitRun = KC.scripts + "/kit-run.sh"

private let harness = #"""
#!/bin/bash
export KIT_ROOT="@KIT@"
. "@LIB@/common.sh"
. "@LIB@/recipes.sh"
KIT_SCRIPTS=/nonexistent-kit-scripts
FAKE="$KIT_ROOT/fake"
mkdir -p "$FAKE" "$KIT_ROOT/run" "$KIT_ROOT/fixtures" "$KIT_ROOT/home"
printf 'S5\n' > "$KIT_ROOT/run/id"
printf 'v1\n' > "$KIT_ROOT/run/version"
real_path "$KIT_ROOT" > "$FAKE/real-root"
LOG="$FAKE/calls.log"
: > "$LOG"
sleep() { :; }
models_check() { return 0; }
usage() { echo "usage: kit-run.sh prep ..." >&2; }
log() { printf '%s\n' "$*" >> "$LOG"; }
fake_clear() {
  : > "$FAKE/picked"; : > "$FAKE/store"; : > "$FAKE/starts"
  echo Folders > "$FAKE/section"
  echo 0 > "$FAKE/presses"
  echo open > "$FAKE/setup-state"
  echo "${FAKE_SETUP_STEP:-2}" > "$FAKE/step"
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
fake_prime() {
  local r="$1" p
  shift
  for p in "$@"; do
    grep -qxF -- "$p" "$FAKE/picked" || printf '%s\n' "$p" >> "$FAKE/picked"
    store_put "$p" "$r"
  done
  echo closed > "$FAKE/setup-state"
  echo open > "$FAKE/settings-open"
  [ "$r" = 1 ] && : > "$FAKE/started"
  return 0
}
drive_picker() {
  local r
  log "drive_picker $1"
  if [ "${FAKE_PICKER_FAIL:-0}" = 1 ]; then PICKER_WHY="the fake picker refuses"; return 1; fi
  r="$(real_path "$1")" || return 1
  grep -qx "$r" "$FAKE/picked" || printf '%s\n' "$r" >> "$FAKE/picked"
  return 0
}
fake_build() {
  local p d
  case "$2" in
    golden|golden-docs|boundary|golden-av)
      while IFS= read -r p; do mkdir -p "$KIT_ROOT/fixtures/$p"; done < <(golden_pick_list "$KIT_LIB/golden-roots.tsv") ;;
    repos) mkdir -p "$KIT_ROOT/home/Developer/api-client" "$KIT_ROOT/home/Developer/legacy-sync" "$KIT_ROOT/home/Developer/scratch-lab" ;;
    matrix) for d in ov-a ov-b ov-c ov-d; do mkdir -p "$KIT_ROOT/fixtures/matrix/$d/outer/inner"; done ;;
  esac
  return 0
}
render_setup() {
  local n p name
  if [ "$(cat "$FAKE/setup-state")" != open ]; then
    if [ "${FAKE_SETUP_RC3_AFTER_FINISH:-0}" = 1 ]; then echo "Accessibility is not granted"; return 3; fi
    echo "no Sesame window"
    return 1
  fi
  n="$(cat "$FAKE/step")"
  echo 'AXWindow label="Sesame"'
  case "$n" in
    2)
      echo '  AXStaticText label="Step 2 of 4: Folders"'
      echo '  AXButton label="Add folder…"'
      while IFS= read -r p; do
        [ -n "$p" ] || continue
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
      while IFS='|' read -r p r; do
        [ -n "$p" ] || continue
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
    echo 3 > "$FAKE/step"
    echo "setup effective" >> "$FAKE/starts"
    return 0
  fi
  if [ -f "$FAKE/settings-open" ] && [ "$(cat "$FAKE/section")" = Indexing ]; then
    if start_enabled && [ "${FAKE_START_DEAD:-0}" != 1 ]; then
      do_start
      echo "settings effective" >> "$FAKE/starts"
    else
      echo "settings ignored" >> "$FAKE/starts"
    fi
    return 0
  fi
  return 1
}
press_button() {
  local n
  case "$1" in
    "Settings…")
      n=$(( $(cat "$FAKE/presses") + 1 )); echo "$n" > "$FAKE/presses"
      [ "$n" -ge "${FAKE_SETTINGS_PRESSES:-1}" ] && echo open > "$FAKE/settings-open"
      return 0 ;;
    "File types"|Folders|Indexing|Search|About)
      [ -f "$FAKE/settings-open" ] || return 1
      echo "$1" > "$FAKE/section"
      return 0 ;;
    Next)
      [ "$(cat "$FAKE/setup-state")" = open ] || return 1
      n="$(cat "$FAKE/step")"
      if [ "$n" -lt 4 ] && ! { [ "${FAKE_NO_STEP3:-0}" = 1 ] && [ "$n" = 2 ]; }; then echo $((n + 1)) > "$FAKE/step"; fi
      return 0 ;;
    Finish)
      [ "$(cat "$FAKE/setup-state")" = open ] && [ "$(cat "$FAKE/step")" = 4 ] || return 1
      if [ "${FAKE_FINISH_STAYS:-0}" != 1 ]; then
        fake_setup_rewrite
        echo closed > "$FAKE/setup-state"
      fi
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
    dump)
      log "ax dump $2"
      case "$2" in
        setup) render_setup ;;
        settings) render_settings ;;
        *) return 1 ;;
      esac ;;
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
  local script
  script="$(basename "$1")"; shift
  case "$script" in
    kit-ax.sh) fake_ax "$@" ;;
    kit-reset.sh) log "reset $*"; rm -f "$KIT_ROOT/run/recipe"; fake_clear ;;
    kit-launch.sh) log "launch $*" ;;
    kit-fixtures.sh) log "build $2"; fake_build "$@" ;;
    kit-index.sh) log "index $*"; fake_index "$@" ;;
    *) log "unexpected $script $*"; return 99 ;;
  esac
}
"""#

private struct Scene {
    let ran: KC.Ran
    let kit: String
    let real: String
    let calls: [String]
    var rc: Int? {
        guard let l = KC.lines(ran.output).last(where: { $0.hasPrefix("RC=") }) else { return nil }
        return Int(l.dropFirst(3))
    }
    var starts: [String] { KC.lines(file("fake/starts") ?? "") }
    var picked: [String] { KC.lines(file("fake/picked") ?? "") }
    var store: [String] { KC.lines(file("fake/store") ?? "") }
    var clicks: [String] { calls.filter { $0.hasPrefix("ax click") } }
    func file(_ relative: String) -> String? { KC.read(kit + "/" + relative) }
    func index(of call: String, after: Int = -1) -> Int? { calls.indices.first { $0 > after && calls[$0] == call } }
}

private func scene(_ body: String, env: [String: String] = [:]) throws -> Scene {
    let base = try KC.tempDir("kit-rp-")
    let kit = base + "/sesame-kit-rp"
    try FileManager.default.createDirectory(atPath: kit + "/run", withIntermediateDirectories: true)
    let script = base + "/scenario.sh"
    try (harness.replacingOccurrences(of: "@KIT@", with: kit).replacingOccurrences(of: "@LIB@", with: KC.lib) + "\n" + body + "\n").write(toFile: script, atomically: true, encoding: .utf8)
    var e = ["TMPDIR": base + "/", "HOME": base + "/decoy-home"]
    for (k, v) in env { e[k] = v }
    let ran = try KC.run("/bin/bash", [script], env: e, limit: 300)
    let real = (KC.read(kit + "/fake/real-root") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return Scene(ran: ran, kit: kit, real: real, calls: KC.lines(KC.read(kit + "/fake/calls.log") ?? ""))
}

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private let sectionClicks = ["ax click Indexing", "ax click Folders", "ax click File types", "ax click Search", "ax click About"]

private let startClicks = ["ax click Next", "ax click Next", "ax click Finish", "ax click Settings…", "ax click Indexing", "ax click Start indexing"]

private let handOverlapPicks = ["ov-a/outer", "ov-a/outer/inner", "ov-b/outer", "ov-b/outer/inner", "ov-c/outer", "ov-c/outer/inner", "ov-d/outer", "ov-d/outer/inner"]

private let handGoldenPicks = ["golden", "golden/photos", "golden-docs", "boundary", "golden-av"]

private func checkPlainStart(_ s: Scene) {
    ok(s.clicks == startClicks, "every click of the recipe: \(s.clicks)")
    ok(!s.calls.contains { $0.contains("Search my code") || $0.contains("File types") || $0.contains("--help") }, "a code switch, File types or tick call was made: \(s.calls)")
    ok(s.starts == ["settings effective"], "the Start presses were \(s.starts): `setup` is Start pressed while the Setup window was open, `ignored` is a press that did nothing")
    guard let start = s.index(of: "ax click Start indexing") else { ok(false, "Start indexing was not pressed: \(s.calls)"); return }
    ok(s.calls[..<start].last(where: { sectionClicks.contains($0) }) == "ax click Indexing", "Start indexing was not pressed in the Indexing section")
    if let finish = s.index(of: "ax click Finish"), let settings = s.index(of: "ax click Settings…") { ok(finish < settings && settings < start, "order: Finish \(finish), Settings \(settings), Start \(start)") }
    if let started = s.index(of: "index wait started 120", after: start), let done = s.index(of: "index wait done 7200", after: start) { ok(started < done, "`index wait done 7200` came before `index wait started 120`") } else { ok(false, "no `index wait started 120` then `index wait done 7200` after Start: \(s.calls)") }
}

@Suite("plan-7-t8: the recipes overlap, golden and index50k pick folders and press no tick", .serialized)
struct KitRecipesPickTests {
    @Test("kit-run.sh prep overlap is a recipe: with no starting state it is exit 4 `no starting state`, an argument is exit 2; prep golden-code is gone: exit 2 with the usage line; index50k keeps its refusal")
    func dispatch() throws {
        let base = try KC.tempDir("kit-rp-")
        let env = ["KIT_ROOT": base + "/sesame-kit-d", "TMPDIR": base + "/", "HOME": base + "/decoy-home"]
        let none = try KC.run("/bin/bash", [kitRun, "prep", "overlap"], env: env)
        ok(none.status == 4 && none.output.contains("no starting state"), "prep overlap with no state: exit \(none.status):\n\(none.output)")
        let extra = try KC.run("/bin/bash", [kitRun, "prep", "overlap", "--now"], env: env)
        ok(extra.status == 2, "prep overlap --now: exit \(extra.status):\n\(extra.output)")
        let gone = try KC.run("/bin/bash", [kitRun, "prep", "golden-code"], env: env)
        ok(gone.status == 2 && gone.output.contains("usage: kit-run.sh"), "prep golden-code: exit \(gone.status):\n\(gone.output)")
        let still = try KC.run("/bin/bash", [kitRun, "prep", "index50k"], env: env)
        ok(still.status == 4 && still.output.contains("no starting state") && still.output.contains("LONG: this build takes hours"), "prep index50k with no state: exit \(still.status):\n\(still.output)")
    }

    @Test("the usage of kit-run.sh lists prep overlap, says it picks folders, and no longer lists prep golden-code or any code tick")
    func usageLists() throws {
        let base = try KC.tempDir("kit-rp-")
        let ran = try KC.run("/bin/bash", [kitRun], env: ["KIT_ROOT": base + "/sesame-kit-u", "TMPDIR": base + "/", "HOME": base + "/decoy-home"])
        ok(ran.status == 2, "kit-run.sh with no argument: exit \(ran.status)")
        ok(ran.output.contains("prep overlap"), "the usage does not list `prep overlap`:\n\(ran.output)")
        ok(!ran.output.contains("golden-code") && !ran.output.contains("ticked for code") && !ran.output.contains("code switch") && !ran.output.contains("code time"), "the usage still names golden-code or a code tick:\n\(ran.output)")
    }

    private func pickList(_ csv: String?) throws -> KC.Ran {
        let base = try KC.tempDir("kit-rp-")
        var path = base + "/none.csv"
        if let csv { path = base + "/m.csv"; try csv.write(toFile: path, atomically: true, encoding: .utf8) }
        return try KC.bash("overlap_pick_list \"\(path)\"; echo \"RC=$?\"", kit: try KC.kitRoot())
    }

    @Test("overlap_pick_list on a hand table: only the rows whose path starts ov-, each folder once, no tick, sorted so a folder comes before the folder inside it")
    func overlapPickListHand() throws {
        let csv = """
        cell,path,picks,expected_in_index,expected_rows,expected_reason,group
        ov-y-out,ov-y/outer/b_zq2.py,ov-y/outer|ov-y/outer/inner,no,0,unsupported,spec
        plain-photo,plain/photo_zq0001.png,,yes,1,ok,spec
        ov-x-in,ov-x/outer/inner/a_zq1.png,ov-x/outer|ov-x/outer/inner,yes,1,ok,spec
        ov-x-out,ov-x/outer/c_zq3.png,ov-x/outer|ov-x/outer/inner,yes,1,ok,spec
        vend-in-Pods-txt,vend-in/Pods/code_zq1511.txt,vend-in,no,0,vendored,spec

        """
        let ran = try pickList(csv)
        ok(KC.lines(ran.output) == ["matrix/ov-x/outer", "matrix/ov-x/outer/inner", "matrix/ov-y/outer", "matrix/ov-y/outer/inner", "RC=0"], "overlap_pick_list on the hand table gave:\n\(ran.output)")
    }

    @Test("overlap_pick_list on the real gate-matrix.csv is exactly the eight folders of the four pairs, outer before inner, with no tick")
    func overlapPickListReal() throws {
        let ran = try pickList(KC.read(KC.lib + "/gate-matrix.csv"))
        let want = handOverlapPicks.map { "matrix/\($0)" } + ["RC=0"]
        ok(KC.lines(ran.output) == want, "overlap_pick_list on gate-matrix.csv gave:\n\(ran.output)\nwanted:\n\(want.joined(separator: "\n"))")
    }

    @Test("overlap_pick_list: a pick that still carries a tick suffix is exit 4 and is named; a missing table is exit 1")
    func overlapPickListErrors() throws {
        let header = "cell,path,picks,expected_in_index,expected_rows,expected_reason,group\n"
        for pick in ["ov-x/outer:on", "ov-x/outer:off", "ov-x/outer:maybe"] {
            let a = try pickList(header + "ov-x-in,ov-x/outer/a_zq1.png,\(pick),yes,1,ok,spec\n")
            ok(a.output.contains("RC=4") && a.output.contains(pick), "the pick \(pick):\n\(a.output)")
        }
        let missing = try pickList(nil)
        ok(missing.output.contains("RC=1"), "a missing table:\n\(missing.output)")
    }

    @Test("settings_open presses the status item's Settings… at the first and again at the fifth try: a window that opens only on the second press is reached, with exactly two presses")
    func settingsOpenSecondPress() throws {
        let s = try scene("settings_open; echo \"RC=$?\"", env: ["FAKE_SETTINGS_PRESSES": "2"])
        ok(s.rc == 0, "settings_open with a window that opens on the second press: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.calls.filter { $0 == "ax click Settings…" }.count == 2, "Settings… was pressed \(s.calls.filter { $0 == "ax click Settings…" }.count) times, wanted 2: \(s.calls)")
    }

    @Test("settings_open on a window that never opens fails loudly: status 1, a line that says no Settings window, and exactly two presses of Settings…")
    func settingsOpenNeverOpens() throws {
        let s = try scene("settings_open; echo \"RC=$?\"", env: ["FAKE_SETTINGS_PRESSES": "999"])
        ok(s.rc == 1, "settings_open with no window: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("no Settings window"), "no line says there is no Settings window:\n\(s.ran.output)")
        ok(s.calls.filter { $0 == "ax click Settings…" }.count == 2, "Settings… was pressed \(s.calls.filter { $0 == "ax click Settings…" }.count) times, wanted 2: \(s.calls)")
    }

    @Test("setup_finish from the Folders step: Next, Next, Finish in that order, waits for the window to go, prints `setup finished`; the Setup window is closed and the picked folders are in the store waiting; Start indexing is not pressed")
    func setupFinishHappy() throws {
        let s = try scene("mkdir -p \"$KIT_ROOT/fixtures/a\"; drive_picker \"$KIT_ROOT/fixtures/a\"; setup_finish; echo \"RC=$?\"")
        ok(s.rc == 0, "setup_finish: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("setup finished"), "no `setup finished` line:\n\(s.ran.output)")
        let presses = s.calls.filter { $0 == "ax click Next" || $0 == "ax click Finish" || $0 == "ax click Start indexing" }
        ok(presses == ["ax click Next", "ax click Next", "ax click Finish"], "presses: \(presses)")
        ok(s.file("fake/setup-state").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "closed" } ?? false, "the Setup window is still open: \(String(describing: s.file("fake/setup-state")))")
        ok(s.store == ["\(s.real)/fixtures/a|0"], "the store after Finish: \(s.store)")
        ok(!s.calls.contains("ax click Settings…"), "setup_finish opened Settings")
    }

    @Test("setup_finish when Finish does not close the window: exit 4 with the Setup window's tree in the output, and Settings is never opened")
    func setupFinishWindowStays() throws {
        let s = try scene("mkdir -p \"$KIT_ROOT/fixtures/a\"; drive_picker \"$KIT_ROOT/fixtures/a\"; setup_finish; echo \"RC=$?\"", env: ["FAKE_FINISH_STAYS": "1"])
        ok(s.rc == 4, "setup_finish with a window that stays: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("Step 4 of 4: Shortcut"), "the output does not carry the Setup window's tree:\n\(s.ran.output)")
        ok(!s.calls.contains("ax click Settings…") && !s.calls.contains("ax click Start indexing"), "the recipe went on after a Finish that did not close the window: \(s.calls)")
    }

    @Test("setup_finish when Next does not reach step 3: exit 4, Finish is never pressed")
    func setupFinishNoStepThree() throws {
        let s = try scene("mkdir -p \"$KIT_ROOT/fixtures/a\"; drive_picker \"$KIT_ROOT/fixtures/a\"; setup_finish; echo \"RC=$?\"", env: ["FAKE_NO_STEP3": "1"])
        ok(s.rc == 4, "setup_finish with no step 3: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(!s.calls.contains("ax click Finish") && !s.calls.contains("ax click Settings…"), "the recipe went on without step 3: \(s.calls)")
    }

    @Test("setup_finish started on a step that is not Folders: exit 4 with the dump, nothing pressed")
    func setupFinishWrongStep() throws {
        let s = try scene("setup_finish; echo \"RC=$?\"", env: ["FAKE_SETUP_STEP": "3"])
        ok(s.rc == 4, "setup_finish on step 3: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("Step 3 of 4: Permissions"), "the output does not carry the Setup window's tree:\n\(s.ran.output)")
        ok(!s.calls.contains { $0.hasPrefix("ax click") }, "something was pressed: \(s.calls)")
    }

    @Test("setup_finish passes status 3 of `dump setup` (a person step) up as it is")
    func setupFinishPersonStep() throws {
        let s = try scene("mkdir -p \"$KIT_ROOT/fixtures/a\"; drive_picker \"$KIT_ROOT/fixtures/a\"; setup_finish; echo \"RC=$?\"", env: ["FAKE_SETUP_RC3_AFTER_FINISH": "1"])
        ok(s.rc == 3, "setup_finish with `dump setup` status 3 after Finish: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(!s.calls.contains("ax click Settings…"), "the recipe went on after a person step")
    }

    @Test("settings_start: the Indexing section, an enabled Start indexing pressed once, `index wait started 120` after it, `Settings Start indexing pressed`; the press reaches the Settings window, never a Setup window")
    func settingsStartHappy() throws {
        let s = try scene("""
        mkdir -p "$KIT_ROOT/home/Developer/api-client"
        fake_prime 0 "$(real_path "$KIT_ROOT/home/Developer/api-client")"
        settings_start; echo "RC=$?"
        """)
        ok(s.rc == 0, "settings_start: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("Settings Start indexing pressed"), "no `Settings Start indexing pressed` line:\n\(s.ran.output)")
        ok(s.starts == ["settings effective"], "starts: \(s.starts)")
        if let press = s.index(of: "ax click Start indexing") {
            ok(s.calls[..<press].last(where: { sectionClicks.contains($0) }) == "ax click Indexing", "Start was not pressed in the Indexing section")
            ok(s.index(of: "index wait started 120", after: press) != nil, "no `index wait started 120` after the press: \(s.calls)")
        } else { ok(false, "Start indexing was not pressed: \(s.calls)") }
    }

    @Test("settings_start with a Start indexing that is disabled (nothing waiting): exit 4 with the Settings window's tree, and it is never pressed")
    func settingsStartDisabled() throws {
        let s = try scene("""
        mkdir -p "$KIT_ROOT/home/Developer/api-client"
        fake_prime 1 "$(real_path "$KIT_ROOT/home/Developer/api-client")"
        settings_start; echo "RC=$?"
        """)
        ok(s.rc == 4, "settings_start on a disabled Start: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("[disabled]"), "the output does not carry the Settings window's tree:\n\(s.ran.output)")
        ok(!s.calls.contains("ax click Start indexing"), "a disabled Start indexing was pressed")
        ok(!s.calls.contains { $0.hasPrefix("index wait started") }, "it waited for a start that was never made")
    }

    @Test("settings_start when an enabled Start does nothing (`index wait started` fails): exit 4 and a line that says so, never a pass")
    func settingsStartNoEffect() throws {
        let s = try scene("""
        mkdir -p "$KIT_ROOT/home/Developer/api-client"
        fake_prime 0 "$(real_path "$KIT_ROOT/home/Developer/api-client")"
        settings_start; echo "RC=$?"
        """, env: ["FAKE_START_DEAD": "1"])
        ok(s.rc == 4, "settings_start with a dead Start: exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(!s.ran.output.contains("Settings Start indexing pressed"), "it printed `Settings Start indexing pressed` for a Start that did nothing:\n\(s.ran.output)")
        ok(s.calls.contains("index wait started 120"), "it did not wait for the start: \(s.calls)")
    }

    @Test("overlap: reset, launch, build matrix only, the eight folders picked outer before inner, Setup finished, Settings opened, and no switch, no tick and no File types section; then the Indexing section's Start, done, Ready, run/recipe overlap")
    func overlapHappy() throws {
        let s = try scene("recipe_main overlap; echo \"RC=$?\"")
        ok(s.rc == 0, "exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(!s.calls.contains { $0.hasPrefix("unexpected") }, "an unexpected script call: \(s.calls.filter { $0.hasPrefix("unexpected") })")
        ok(s.index(of: "reset --id S5 --version v1 --model cache") != nil, "no reset with the model from the cache")
        ok(s.calls.filter { $0.hasPrefix("launch") }.count == 1, "launches: \(s.calls.filter { $0.hasPrefix("launch") })")
        ok(s.calls.filter { $0.hasPrefix("build ") } == ["build matrix"], "builds: \(s.calls.filter { $0.hasPrefix("build ") })")
        let picked = s.calls.filter { $0.hasPrefix("drive_picker ") }.map { String($0.dropFirst("drive_picker ".count)) }
        let want = handOverlapPicks.map { s.kit + "/fixtures/matrix/" + $0 }
        ok(picked == want, "picked folders:\n\(picked.joined(separator: "\n"))\nwanted:\n\(want.joined(separator: "\n"))")
        checkPlainStart(s)
        ok(s.store.count == handOverlapPicks.count, "entries: \(s.store.count), wanted \(handOverlapPicks.count): \(s.store)")
        ok(s.file("run/recipe").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "overlap" } ?? false, "run/recipe: \(String(describing: s.file("run/recipe")))")
    }

    @Test("overlap with a picker that cannot be driven: NEEDS A PERSON lists the eight folders and says nothing of ticks, exit 3")
    func overlapPickerFails() throws {
        let s = try scene("recipe_main overlap; echo \"RC=$?\"", env: ["FAKE_PICKER_FAIL": "1", "KIT_PICK_WAIT": "0"])
        ok(s.rc == 3, "exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("NEEDS A PERSON: pick these folders with \"Add folder…\""), "the K33 line:\n\(s.ran.output)")
        ok(!s.ran.output.contains("tick these for code"), "the line still names code ticks:\n\(s.ran.output)")
        for p in handOverlapPicks { ok(s.ran.output.contains("\(s.kit)/fixtures/matrix/\(p)"), "\(p) is not listed:\n\(s.ran.output)") }
        ok(!s.calls.contains("ax click Start indexing") && s.file("run/recipe") == nil, "the recipe went on")
    }

    private let index50kBody = """
    fake_build build golden; fake_build build golden-docs; fake_build build boundary; fake_build build golden-av; fake_build build repos
    mkdir -p "$KIT_ROOT/fixtures/filler"
    index50k_app; echo "RC=$?"
    """

    @Test("index50k_app: picks the golden roots, filler and api-client, Setup finished, Settings opened, then the Indexing section's Start, done, Ready, run/recipe index50k; no switch, no tick, no code time")
    func index50kApp() throws {
        let s = try scene(index50kBody)
        ok(s.rc == 0, "exit \(String(describing: s.rc)):\n\(s.ran.output)")
        let picked = s.calls.filter { $0.hasPrefix("drive_picker ") }.map { String($0.dropFirst("drive_picker ".count)) }
        let want = handGoldenPicks.map { s.kit + "/fixtures/" + $0 } + [s.kit + "/fixtures/filler", s.kit + "/home/Developer/api-client"]
        ok(picked == want, "picked folders:\n\(picked.joined(separator: "\n"))\nwanted:\n\(want.joined(separator: "\n"))")
        checkPlainStart(s)
        ok(s.file("run/recipe").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "index50k" } ?? false, "run/recipe: \(String(describing: s.file("run/recipe")))")
        ok(s.file("run/golden-code-time") == nil, "index50k_app read a code time")
    }

    @Test("a recipe that ticks nothing keeps its failed-picker line: `pick these folders with \"Add folder…\" (code stays off)`")
    func otherRecipesKeepTheirLine() throws {
        let s = try scene("recipe_main golden; echo \"RC=$?\"", env: ["FAKE_PICKER_FAIL": "1", "KIT_PICK_WAIT": "0"])
        ok(s.rc == 3, "exit \(String(describing: s.rc)):\n\(s.ran.output)")
        ok(s.ran.output.contains("NEEDS A PERSON: pick these folders with \"Add folder…\" (code stays off):"), "the line changed:\n\(s.ran.output)")
        ok(!s.ran.output.contains("tick these for code"), "the golden recipe mentions code ticks:\n\(s.ran.output)")
    }

    @Test("golden_need keeps `golden` and `--hold`, makes the golden state from any other, including an old golden-code mark; --code is a usage error, exit 2, and starts nothing")
    func goldenNeed() throws {
        let same = try scene("printf 'golden\\n' > \"$KIT_ROOT/run/recipe\"; golden_need; echo \"RC=$?\"")
        ok(same.rc == 0 && same.calls.isEmpty, "plain golden_need on a golden state is not unchanged: \(same.calls)")
        for state in ["golden-code", "tree -", "overlap", ""] {
            let s = try scene("printf '\(state)\\n' > \"$KIT_ROOT/run/recipe\"; golden_need; echo \"RC=$?\"")
            ok(s.rc == 0 && s.calls.contains("reset --id S5 --version v1 --model cache") && s.file("run/recipe").map { $0 == "golden\n" } ?? false,
               "golden_need on state `\(state)`: rc \(String(describing: s.rc)), recipe file \(String(describing: s.file("run/recipe"))), calls \(s.calls.prefix(3))")
        }
        let held = try scene("printf 'golden hold\\n' > \"$KIT_ROOT/run/recipe\"; golden_need --hold; echo \"RC=$?\"")
        ok(held.rc == 0 && held.calls.isEmpty, "golden_need --hold on a held state is not unchanged: \(held.calls)")
        for args in ["--code", "--code --hold"] {
            let s = try scene("golden_need \(args); echo \"RC=$?\"")
            ok(s.rc == 2 && s.calls.isEmpty, "golden_need \(args): rc \(String(describing: s.rc)), calls \(s.calls)")
        }
    }
}

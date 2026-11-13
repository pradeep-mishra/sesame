import Foundation
import Testing

private func stripped(_ name: String) -> String {
    (KC.read(KC.lib + "/" + name) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

private func defines(_ text: String, _ name: String) -> Bool { KC.has(text, "(^|\\n)" + NSRegularExpression.escapedPattern(for: name) + "\\(\\)") }

private func ok(_ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
}

private let settingsDump = """
window 700 x 480 at 100,100 title Settings
AXWindow/AXStandardWindow label="Settings"
  AXGroup
    AXButton label="Folders" value="1"
    AXButton label="File types" value="0"
    AXGroup
      AXStaticText label="Folders"
      AXScrollArea
        AXGroup
          AXGroup
            AXCheckBox label="Trips" desc="Trips, 40 photos, about 2 min" help="/Users/x/Trips" value="1"
            AXButton label="Re-index" help="Trips"
            AXButton label="Remove" help="Trips"
          AXGroup
            AXCheckBox label="Notes" desc="Notes, 7 PDFs, Waiting for Start indexing" help="/Users/x/Notes" value="1"
            AXButton label="Re-index" help="Notes"
            AXButton label="Remove" help="Notes"
          AXGroup
            AXCheckBox label="Extra" desc="Extra, not read" help="/Users/x/Extra" value="0"
            AXButton label="Re-index" help="Extra"
            AXButton label="Remove" help="Extra"
      AXButton label="Add folder…"

"""

private func axdump(_ call: String, stdin: String) throws -> KC.Ran {
    let dir = try KC.tempDir("kit-nc-")
    try KC.write(dir + "/dump.txt", stdin)
    try KC.write(dir + "/run.sh", ". \"\(KC.lib)/axdump.sh\"\n\(call) < \"\(dir)/dump.txt\"; echo \"RC=$?\"\n")
    return try KC.run("/bin/bash", [dir + "/run.sh"], env: ["TMPDIR": dir + "/"])
}

private let footerWorld = #"""
FAKE="$KIT_ROOT/fake"
mkdir -p "$FAKE"
LOG="$FAKE/calls.log"
: > "$LOG"
echo "${WORLD_STEP:-2}" > "$FAKE/step"
echo open > "$FAKE/state"
if [ "$WORLD" = started ]; then : > "$FAKE/started"; fi
KIT_SCRIPTS=/nonexistent-kit-scripts
S6_AX=/nonexistent-kit-scripts/kit-ax.sh
sleep() { :; }
log() { printf '%s\n' "$*" >> "$LOG"; }
render() {
  if [ "$(cat "$FAKE/state")" != open ]; then echo "no Sesame window"; return 1; fi
  echo 'AXWindow label="Sesame"'
  case "$(cat "$FAKE/step")" in
    2)
      echo '  AXStaticText label="Step 2 of 4: Folders"'
      echo '  AXButton label="Back"'
      echo '  AXButton label="Add folder…"'
      echo '  AXCheckBox label="a" desc="a, 19 files" help="/Users/x/a" value="1"'
      case "$WORLD" in
        whole) echo '  AXButton label="Start indexing"'; echo '  AXButton label="Not now"' ;;
        notwhole|started) echo '  AXButton label="Next"' ;;
      esac
      if [ -f "$FAKE/error" ]; then echo '  AXStaticText label="Could not save the settings, so indexing did not start."'; fi ;;
    3)
      echo '  AXStaticText label="Step 3 of 4: Permissions"'
      echo '  AXButton label="Back"'
      echo '  AXButton label="Next"' ;;
    4)
      echo '  AXStaticText label="Step 4 of 4: Shortcut"'
      echo '  AXButton label="Back"'
      echo '  AXButton label="Finish"' ;;
  esac
  return 0
}
press() {
  local n
  n="$(cat "$FAKE/step")"
  case "$1" in
    Next)
      case "$n:$WORLD" in
        2:notwhole|2:started|3:*) echo $((n + 1)) > "$FAKE/step"; return 0 ;;
        *) return 1 ;;
      esac ;;
    "Not now")
      case "$n:$WORLD" in
        2:whole) echo 3 > "$FAKE/step"; return 0 ;;
        *) return 1 ;;
      esac ;;
    "Start indexing")
      case "$n:$WORLD" in
        2:whole)
          case "$START" in
            error) : > "$FAKE/error" ;;
            stuck) ;;
            *) : > "$FAKE/started"; echo 3 > "$FAKE/step" ;;
          esac
          return 0 ;;
        *) return 1 ;;
      esac ;;
    Finish)
      [ "$n" = 4 ] || return 1
      echo closed > "$FAKE/state"
      return 0 ;;
    *) return 1 ;;
  esac
}
kq() {
  local script
  script="$(basename "$1")"; shift
  case "$script" in
    kit-ax.sh)
      case "$1" in
        dump) log "ax dump $2"; render ;;
        click) log "ax click $2"; press "$2" && echo clicked ;;
        *) log "ax $*" ;;
      esac ;;
    kit-index.sh)
      case "$1" in
        settings) if [ -f "$FAKE/started" ]; then echo '  "startPressed" => true'; else echo '  "startPressed" => false'; fi ;;
        *) return 0 ;;
      esac ;;
    *) log "unexpected $script $*"; return 99 ;;
  esac
}
"""#

private struct FooterRun {
    let ran: KC.Ran
    let kit: String
    var rc: Int? {
        guard let l = KC.lines(ran.output).last(where: { $0.hasPrefix("RC=") }) else { return nil }
        return Int(l.dropFirst(3))
    }
    var clicks: [String] {
        KC.lines(KC.read(kit + "/fake/calls.log") ?? "").filter { $0.hasPrefix("ax click ") }.map { String($0.dropFirst("ax click ".count)) }
    }
    var started: Bool { FileManager.default.fileExists(atPath: kit + "/fake/started") }
}

private func footerRun(_ world: String, step: Int = 2, start: String = "ok", _ call: String) throws -> FooterRun {
    let kit = try KC.kitRoot()
    let ran = try KC.bash(footerWorld + "\n" + call + "\necho \"RC=$?\"", kit: kit, env: ["WORLD": world, "WORLD_STEP": String(step), "START": start], limit: 60)
    return FooterRun(ran: ran, kit: kit)
}

@Suite("plan-9-t18: on Folders with a whole model the footer is Start indexing and Not now is the only way on without starting; with the model not whole it is Next")
struct KitRunFoldersFooterRecipesTests {
    @Test("setup_finish on a whole-model Folders step (Start indexing, Not now, no Next) presses Not now, Next, Finish and never Start indexing; startPressed stays false")
    func setupFinishWholeModelPressesNotNow() throws {
        let r = try footerRun("whole", "setup_finish")
        ok(r.rc == 0, "setup_finish on a whole-model Folders step: \(r.ran.output)")
        ok(r.clicks == ["Not now", "Next", "Finish"], "presses: \(r.clicks)")
        ok(!r.started, "Start indexing was pressed: startPressed is true in the world")
        ok(r.ran.output.contains("setup finished"), "no `setup finished` line: \(r.ran.output)")
    }

    @Test("setup_finish on a Folders step whose model is not whole (Next, no Start indexing, no Not now) presses Next, Next, Finish")
    func setupFinishNotWholePressesNext() throws {
        let r = try footerRun("notwhole", "setup_finish")
        ok(r.rc == 0, "setup_finish on a not-whole Folders step: \(r.ran.output)")
        ok(r.clicks == ["Next", "Next", "Finish"], "presses: \(r.clicks)")
    }

    @Test("setup_finish on a Folders step after a Start (Next, no Start indexing, no Not now) presses Next, Next, Finish")
    func setupFinishAfterStartOnFolders() throws {
        let r = try footerRun("started", "setup_finish")
        ok(r.rc == 0, "setup_finish on a post-start Folders step: \(r.ran.output)")
        ok(r.clicks == ["Next", "Next", "Finish"], "presses: \(r.clicks)")
    }

    @Test("a Start pressed first leaves Folders for Permissions, and setup_finish then goes Next, Finish from Permissions")
    func setupFinishFromPermissionsAfterStart() throws {
        let r = try footerRun("whole", "press_start; setup_finish")
        ok(r.rc == 0, "press_start then setup_finish: \(r.ran.output)")
        ok(r.clicks == ["Start indexing", "Next", "Finish"], "presses: \(r.clicks)")
        ok(r.started, "the world never recorded the start")
    }

    @Test("setup_finish on Permissions when Start indexing was never pressed is exit 4 with the window's tree, and presses nothing")
    func setupFinishPermissionsWithoutStartIsExit4() throws {
        let r = try footerRun("notwhole", step: 3, "setup_finish")
        ok(r.rc == 4, "setup_finish on Permissions with no start: \(r.ran.output)")
        ok(r.ran.output.contains("Step 3 of 4: Permissions") && r.ran.output.contains("after Start indexing was pressed"), "the message or the tree is missing: \(r.ran.output)")
        ok(r.clicks.isEmpty, "something was pressed: \(r.clicks)")
    }

    @Test("a planted Folders dump with neither Next nor Not now is exit 4 with a message naming both, and presses nothing", arguments: ["bare"])
    func setupFinishNeitherButton(world: String) throws {
        let r = try footerRun(world, "setup_finish")
        ok(r.rc == 4, "setup_finish with neither button: \(r.ran.output)")
        ok(r.ran.output.contains("\"Next\"") && r.ran.output.contains("\"Not now\""), "the message does not name both: \(r.ran.output)")
        ok(r.clicks.isEmpty, "something was pressed: \(r.clicks)")
    }

    @Test("press_start clicks Start indexing, waits until the dump shows Step 3 of 4: Permissions, and says so")
    func pressStartReachesPermissions() throws {
        let r = try footerRun("whole", "press_start")
        ok(r.rc == 0, "press_start: \(r.ran.output)")
        ok(r.clicks == ["Start indexing"], "presses: \(r.clicks)")
        ok(r.ran.output.contains("Step 3 of 4: Permissions"), "the output does not say the window is on Permissions: \(r.ran.output)")
        ok(r.started, "the world never recorded the start")
    }

    @Test("press_start on a window that stays on Folders and shows the start error fails with that text")
    func pressStartStartError() throws {
        let r = try footerRun("whole", start: "error", "press_start")
        ok(r.rc == 1, "press_start with a start error: \(r.ran.output)")
        ok(r.ran.output.contains("Could not save the settings, so indexing did not start."), "the start error text is not in the output: \(r.ran.output)")
    }

    @Test("press_start on a window that stays on Folders with no start error fails with a timeout message naming both states and the tree")
    func pressStartTimeout() throws {
        let r = try footerRun("whole", start: "stuck", "press_start")
        ok(r.rc == 1, "press_start with a stuck window: \(r.ran.output)")
        ok(r.ran.output.contains("neither \"Step 3 of 4: Permissions\" nor a start error within 10 s"), "no timeout message: \(r.ran.output)")
        ok(r.ran.output.contains("Step 2 of 4: Folders"), "the tree is not printed: \(r.ran.output)")
    }

    @Test("press_start where the footer reads Next (the model is not whole) cannot press Start indexing and fails at once")
    func pressStartNotWhole() throws {
        let r = try footerRun("notwhole", "press_start")
        ok(r.rc == 1 && r.ran.output.contains("could not press Start indexing"), "press_start on a not-whole model: \(r.ran.output)")
    }

    @Test("S1.19's setup walk presses Not now on a whole-model Folders step and Next elsewhere, never Start indexing, and says so", arguments: [("whole", ["Not now", "Next"]), ("notwhole", ["Next", "Next"])])
    func s119WalkNeverStarts(world: String, expected: [String]) throws {
        let r = try footerRun(world, "nr_walk_setup")
        ok(r.clicks == expected, "\(world): presses \(r.clicks)")
        ok(!r.started, "\(world): Start indexing was pressed")
        ok(r.ran.output.contains("Start indexing never pressed"), "\(world): the echo does not say so: \(r.ran.output)")
    }

    @Test("S9.1's s9_next presses Not now on a whole-model Folders dump, Next on a not-whole one, never Start indexing", arguments: [("whole", "Not now"), ("notwhole", "Next")])
    func s91NextPressesTheWayOn(world: String, expected: String) throws {
        let r = try footerRun(world, "S6_DUMP=\"$(render)\"; s9_next S9.1")
        ok(r.clicks == [expected], "\(world): presses \(r.clicks)")
        ok(!r.started, "\(world): Start indexing was pressed")
    }

    @Test("the kit text: no walk or finish presses Start indexing; press_start is the only recipe press of it and reads Permissions; the callers of press_start read Permissions or nothing, never Folders")
    func kitTextNeverStartsInAWalk() {
        let recipes = stripped("recipes.sh")
        for (name, text) in [("setup_finish", recipes), ("picker_attempt", recipes), ("nr_walk_setup", stripped("checks-s1b.sh")), ("s1c_29_setup", stripped("checks-s1c.sh")), ("s9_next", stripped("checks-s9.sh"))] {
            let body = KC.shellFunction(name, in: text) ?? ""
            ok(!body.isEmpty, "\(name) is not defined")
            ok(!body.contains("click \"Start indexing\""), "\(name) presses Start indexing")
        }
        let press = KC.shellFunction("press_start", in: recipes) ?? ""
        ok(press.contains("click \"Start indexing\"") && press.contains("Step 3 of 4: Permissions"), "press_start does not press Start indexing and read Permissions")
        let picker = KC.shellFunction("picker_attempt", in: recipes) ?? ""
        ok(picker.components(separatedBy: "click \"Next\"").count == 2 && !picker.contains("Not now"), "picker_attempt presses Next on Welcome only: \(picker)")
        for caller in ["recipe_photos", "busy50k_launch", "recipe_minimix", "recipe_mix500", "recipe_pauselong", "recipe_golden", "golden_release"] {
            let body = KC.shellFunction(caller, in: recipes) ?? ""
            ok(body.contains("press_start"), "\(caller) no longer calls press_start")
            let after = body.components(separatedBy: "press_start").dropFirst().joined(separator: "\n")
            ok(!after.contains("Folders") && !after.contains("setup_folders") && !after.contains("setup_lists") && !after.contains("pick_folders"), "\(caller) reads Folders after press_start: \(after)")
        }
    }
}

@Suite("plan-7-t8: no recipe or AX parser of the kit ticks, times or lists code")
struct KitRunNoCodeRecipesTests {
    @Test("recipes.sh defines none of the code recipes and readers, and has no golden-code recipe, no tick wording and no --code-folders")
    func recipesHaveNoCode() {
        let text = stripped("recipes.sh")
        for name in ["settings_code_switch_on", "settings_code_tick", "code_time_read", "code_folders_open", "tree_code_ticks", "code_indexed", "repo_tick_list", "tree_tick_list", "recipe_golden_code"] {
            ok(!defines(text, name), "recipes.sh still defines \(name)")
        }
        for word in ["golden-code", "golden_code", "PK_TICKS", "--code-folders", "ax_code_tick", "ax_code_time", "golden-code-time", "click --help"] {
            ok(!text.contains(word), "recipes.sh still says \(word)")
        }
        for name in ["settings_open", "settings_start", "setup_finish", "pick_folders", "tree_pick_list", "overlap_pick_list", "repo_pick_list", "golden_need", "overlap_need", "recipe_overlap", "recipe_tree", "index50k_app"] {
            ok(defines(text, name), "recipes.sh lost \(name)")
        }
    }

    @Test("overlap_pick_list, index50k_app, recipe_overlap and recipe_tree hold no tick: no on/off, no switch, no code tick call")
    func recipeBodiesHaveNoTick() {
        let text = stripped("recipes.sh")
        for name in ["overlap_pick_list", "index50k_app", "recipe_overlap", "recipe_tree", "tree_pick_list", "pick_folders"] {
            let body = KC.shellFunction(name, in: text) ?? ""
            ok(!body.isEmpty, "recipes.sh has no \(name)")
            ok(!KC.has(body, "\\b(on|off)\\b[^\\n]*tick|tick[^\\n]*\\b(on|off)\\b|ticks|settings_code|code_folders|code_time|code_indexed"), "\(name) still names a tick: \(body.split(separator: "\n").filter { KC.has(String($0), "tick|settings_code|code_") })")
        }
    }

    @Test("recipe_main has no golden-code branch, and kit-run.sh no longer names golden-code in its usage or its header")
    func dispatchHasNoGoldenCode() {
        let main = KC.shellFunction("recipe_main", in: stripped("recipes.sh")) ?? ""
        ok(!main.isEmpty && !main.contains("golden-code") && !main.contains("recipe_golden_code"), "recipe_main still dispatches golden-code: \(main)")
        ok(main.contains("overlap)") && main.contains("tree)") && main.contains("index50k)"), "recipe_main lost a branch: \(main)")
        let run = KC.read(KC.scripts + "/kit-run.sh") ?? ""
        ok(!run.contains("golden-code"), "kit-run.sh still names golden-code")
    }

    @Test("axdump.sh defines none of the code parsers, has no code row kind and no code folder text; ax_switch and the row readers stay")
    func axdumpHasNoCode() throws {
        let text = stripped("axdump.sh")
        for name in ["ax_code_tick", "ax_code_tick_help", "ax_code_time"] { ok(!defines(text, name), "axdump.sh still defines \(name)") }
        for word in ["code folder", "\"code\"", "ax_norm_awk", "[folder|code]"] { ok(!text.contains(word), "axdump.sh still says \(word)") }
        for name in ["ax_elements", "ax_rows", "ax_folders", "ax_row", "ax_row_detail", "ax_row_estimate", "ax_row_block", "ax_switch", "ax_has_label", "ax_has_label_prefix", "ax_total_seconds", "ax_speed_note"] {
            ok(defines(text, name), "axdump.sh lost \(name)")
        }
        let ran = try axdump("declare -F ax_code_tick ax_code_tick_help ax_code_time", stdin: "")
        ok(ran.output == "RC=1\n", "a code parser is still a function: \(ran.output)")
    }

    @Test("a Settings dump with no code lines parses to the same folder rows as before: the three rows, their state, detail and estimate, by name and by path")
    func settingsRowsUnchanged() throws {
        let rows = try axdump("ax_rows", stdin: settingsDump)
        ok(KC.lines(rows.output) == [
            "/Users/x/Trips\tTrips\ton\tenabled\t40 photos, about 2 min\tfolder",
            "/Users/x/Notes\tNotes\ton\tenabled\t7 PDFs, Waiting for Start indexing\tfolder",
            "/Users/x/Extra\tExtra\toff\tenabled\tnot read\tfolder",
            "RC=0",
        ], "rows: \(rows.output)")
        let folders = try axdump("ax_folders", stdin: settingsDump)
        ok(KC.lines(folders.output) == ["/Users/x/Trips", "/Users/x/Notes", "/Users/x/Extra", "RC=0"], "folders: \(folders.output)")
        for (call, want) in [("ax_row_detail Notes", "7 PDFs, Waiting for Start indexing"), ("ax_row_estimate Trips", "about 2 min"), ("ax_row_detail /Users/x/Extra", "not read")] {
            let ran = try axdump(call, stdin: settingsDump)
            ok(KC.lines(ran.output) == [want, "RC=0"], "\(call): \(ran.output)")
        }
        let block = try axdump("ax_row_block Trips", stdin: settingsDump)
        ok(KC.lines(block.output).count == 4 && KC.lines(block.output).last == "RC=0", "block: \(block.output)")
        let sw = try axdump("ax_switch 'Search my code'", stdin: settingsDump)
        ok(KC.lines(sw.output) == ["absent", "RC=0"], "switch: \(sw.output)")
    }

    @Test("a row whose detail reads `code folder` is no longer a kind of its own: it is a folder row like any other")
    func noCodeKind() throws {
        let dump = "AXWindow label=\"Setup\"\n  AXCheckBox label=\"atlas\" desc=\"atlas, code folder\" help=\"/Users/x/atlas\" value=\"0\" [disabled]\n"
        let rows = try axdump("ax_rows", stdin: dump)
        ok(KC.lines(rows.output) == ["/Users/x/atlas\tatlas\toff\tdisabled\tcode folder\tfolder", "RC=0"], "rows: \(rows.output)")
    }
}

#!/bin/bash
# The slice 2 checks of S1 and S8 that need the menu bar, Settings or Delete index (feature maps S1 and S8: S1.6, S1.30,
# S8.11, and the slice 2 parts of S1.21 (b), S1.22 (iii) and (iv) and S1.29, whose functions sit in checks-s1b.sh and call the
# helpers below). Sourced by kit-run.sh after common.sh, recipes.sh, checks-s1.sh, checks-s1b.sh, checks-s6.sh, checks-s6b.sh
# and checks-s7.sh (whose plumbing it uses: s1_*, nr_*, pn_*, s6b_settings, s6b_menu_ready, s6b_expected, s7_menu,
# s7_menu_counts, s7_label, s7_wait_state), never run. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a
# failure lists every reason, on one line) and uses the exit codes of every kit script: 0 for a pass or a needs-a-person,
# 1 for a fail, 4 for `RERUN <id> not valid: <reason>`. With KIT_PLANT=1 (kit-run.sh --plant <id>) the shortcut posts of the
# check are replaced by a chord the app does not own (Shift+Command+K, see s1_begin), so the check must print
# `CHECK <id> FAIL planted: <what>`; a plant is judged before anything is pressed that changes the state.
#
# Starting state. S1.6, S1.30 and S8.11 start from the recipe `photos` (waiting for Ready, see s1_need_photos). S1.21 (b) goes on
# from the empty folder of (a); S1.22 (iii) and (iv) make a state of their own (a cached model, the app launched with the
# mirror, the filler folder). Delete index is pressed as a person presses it: the status item's "Settings…", the button
# "Delete index…" and its confirmation. The kit never edits settings.json or the index to reach a state.
#
# What the checks read, and where: the status item's label and menu through `kit-ax.sh read menubar` and `dump menu`; Settings
# and the panel through `kit-ax.sh dump`; the index through `kit-index.sh`; the expected counts and listing only from
# `kit-fixtures.sh expect counts` and `expect listing`, the hand-written tables, never the product; the Sesame folder through
# `kit-privacy.sh layout` and `stat`-free existence tests of the three index files.
#
# What a check cannot tell apart, said where it matters: the recipe `photos` picks golden/ and then golden/photos/, and the
# folder picker adds golden/photos for golden (its only subfolder), so the overlap of S1.6 may not be in the picked list; the
# check then says NEEDS-A-PERSON (pick golden/ by hand), never a pass on a list that has no overlap in it.

S1C_AX="$KIT_SCRIPTS/kit-ax.sh"
S1C_IX="$KIT_SCRIPTS/kit-index.sh"
S1C_PRIV="$KIT_SCRIPTS/kit-privacy.sh"
S1C_MR="$KIT_SCRIPTS/kit-mirror.sh"
S1C_TEXT="anything"
S1C_T0=0

# ---- the Sesame folder and the index files ------------------------------------------------------------------

# s1c_present : the names of index.sqlite, index.sqlite-wal and index.sqlite-shm that exist in Sesame's folder.
s1c_present() {
  local f out=""
  for f in index.sqlite index.sqlite-wal index.sqlite-shm; do
    [ -e "$NR_SUP/$f" ] && out="${out:+$out }$f"
  done
  printf '%s' "$out"
}

# s1c_wait_gone <seconds> : status 0 once none of the three index files is in Sesame's folder, 1 when one still is.
s1c_wait_gone() {
  local end=$((SECONDS + $1))
  while :; do
    [ -z "$(s1c_present)" ] && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.5
  done
}

# s1c_wait_models <seconds> : status 0 once both model files are whole in models/, 1 when they are not in time.
s1c_wait_models() {
  local end=$((SECONDS + $1))
  until nr_models_whole; do
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 2
  done
  return 0
}

# ---- Delete index, as a person presses it ---------------------------------------------------------------------

# s1c_delete_index : the status item's "Settings…", "Delete index…" in Settings, and its confirmation. S1C_T0 is the
# second the confirmation was pressed. Status 0 pressed; 1 a step failed (the reason is in NR_WHY).
s1c_delete_index() {
  kq "$S1C_AX" click "Settings…" >/dev/null 2>&1 || { nr_why "pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings || { nr_why "Settings did not open"; return 1; }
  settings_section Indexing || { nr_why "the Settings window cannot be put on its Indexing section, so Delete index… cannot be pressed"; return 1; }
  kq "$S1C_AX" click "Delete index…" >/dev/null 2>&1 || { nr_why "pressing \"Delete index…\" in Settings failed"; return 1; }
  sleep 1
  S1C_T0=$SECONDS
  kq "$S1C_AX" click "Delete index" >/dev/null 2>&1 || kq "$S1C_AX" click "Delete" >/dev/null 2>&1 || { nr_why "the confirmation of Delete index could not be pressed (no button \"Delete index\" or \"Delete\")"; return 1; }
  return 0
}

# s1c_read_text4 <id> <when> : the panel with no text shows "Not ready yet" and "Nothing is indexed yet" (text 4), never
# text 2 (Indexing has not been started), text 3 (Still indexing) or text 1. Reasons go to NR_WHY. Status 0 judged; 1 a CHECK
# line was printed (S1_RC is set).
s1c_read_text4() {
  local rc
  nr_read_panel 20 "Not ready yet" "Nothing is indexed yet"; rc=$?
  nr_panel_rc "$1" $rc || return 1
  nr_save "s1c-text4-$1"
  nr_has "Not ready yet" || nr_why "$2 the panel shows no 'Not ready yet' heading"
  nr_has "Nothing is indexed yet" || nr_why "$2 the panel shows no 'Nothing is indexed yet' text (text 4)"
  nr_must_lack "Indexing has not been started" "$2 (text 4 must win over text 2)"
  nr_must_lack "Still indexing" "$2 (nothing is being indexed)"
  nr_must_lack "The model is still downloading" "$2 (the model files are whole)"
  return 0
}

# s1c_text4_typed : the same with a text typed into the box (any text shows text 4). Reasons go to NR_WHY.
s1c_text4_typed() {
  if ! nr_ensure_panel; then nr_why "with a text typed: no panel could be opened ($PN_OUT)"; return 0; fi
  if ! pn_wait_sesame_front 3; then nr_why "with a text typed: $PN_OUT, so no key was posted"; return 0; fi
  if ! pn_ax type "$S1C_TEXT" >/dev/null 2>&1; then nr_why "with a text typed: kit-ax.sh type was refused"; return 0; fi
  sleep 1
  pn_dump
  nr_has "Not ready yet" || nr_why "with a text typed the panel shows no 'Not ready yet' heading"
  nr_has "Nothing is indexed yet" || nr_why "with a text typed the panel shows no 'Nothing is indexed yet' text"
  nr_must_lack "No matches" "with a text typed (text 4 must show for any text)"
  return 0
}

# s1c_delete_flow <id> <tag> : Delete index and everything the maps read after it: the three index files gone within 10 s
# (a cheap existence test, then `kit-privacy.sh layout` for the record), startPressed false, no files, text 4 with no text and
# with a typed text, and the same after a relaunch. Reasons go to NR_WHY. Status 0 judged (read NR_WHY); 1 a CHECK or RERUN
# line was printed (S1_RC is set).
s1c_delete_flow() {
  local id="$1" tag="$2" rc out left pressed files
  if [ -z "$(s1c_present)" ]; then
    echo "RERUN $id not valid: ${tag:+$tag }there is no index.sqlite in Sesame's folder before Delete index, so its absence afterwards proves nothing"
    S1_RC=4
    return 1
  fi
  s1c_delete_index || return 0
  if s1c_wait_gone 10; then
    echo "  | ${tag:+$tag }index.sqlite, -wal and -shm are gone $((SECONDS - S1C_T0)) s after the confirmation"
  else
    nr_why "index.sqlite, -wal or -shm are still in Sesame's folder 10 s after the confirmation: $(s1c_present)"
  fi
  out="$(kq "$S1C_PRIV" layout 2>&1)"
  printf '%s\n' "$out" | sed 's/^/  | layout: /'
  left="$(printf '%s\n' "$out" | awk '$1 == "ENTRY" && ($2 == "index.sqlite" || $2 == "index.sqlite-wal" || $2 == "index.sqlite-shm") { printf "%s ", $2 }')"
  [ -z "$left" ] || nr_why "kit-privacy.sh layout still lists $left after Delete index"
  pressed="$(nr_start_pressed)"
  [ "$pressed" = false ] || nr_why "settings.json says startPressed $pressed after Delete index, expected false"
  files="$(nr_files_n)"
  [ "${files:-0}" = 0 ] || nr_why "the index holds $files files after Delete index"
  s1c_read_text4 "$id" "after Delete index" || return 1
  s1c_text4_typed
  kq "$S1_LD" quit >/dev/null 2>&1
  out="$(kq "$S1_LD" relaunch 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then nr_why "kit-launch.sh relaunch exited $rc: $(s1_last "$out")"; return 0; fi
  sleep 10
  s1c_read_text4 "$id" "after the relaunch" || return 1
  pressed="$(nr_start_pressed)"
  [ "$pressed" = false ] || nr_why "settings.json says startPressed $pressed after the relaunch, expected false"
  files="$(nr_files_n)"
  [ "${files:-0}" = 0 ] || nr_why "the index holds $files files after the relaunch, with Start indexing not pressed"
  return 0
}

# ---- S1.22 (iii) and (iv) -----------------------------------------------------------------------------------

# s1c_fresh_cache_mirror : a fresh cached-model state whose app is launched with the mirror (at full rate), so a planted
# model file is downloaded again from it. Status 0, else NR_RC and NR_MSG say why.
s1c_fresh_cache_mirror() {
  local out rc
  out="$({ recipe_state && recipe_reset cache && kq "$KIT_SCRIPTS/kit-launch.sh" start --mirror-full; } 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/fresh cached-model state with the mirror: /'
  if [ $rc != 0 ]; then
    NR_RC=$rc; NR_MSG="the fresh state cannot be made: $(nr_pick_msg "$out")"
    return 1
  fi
  sleep 1
  return 0
}

# s1c_22_iii : indexing paused part way, a damaged model planted: text 1 wins over text 3, and text 3 returns after the
# re-download. Reasons go to NR_WHY. Status 0 judged; 1 a CHECK or RERUN line was printed (S1_RC is set).
s1c_22_iii() {
  local rc i
  NR_WHY=""
  s1c_fresh_cache_mirror || { nr_state_rc S1.22 "$NR_RC" "(iii) $NR_MSG"; return 1; }
  nr_do S1.22 "(iii) the setup window cannot be driven" wait_setup_window 8 || return 1
  nr_do S1.22 "(iii) the filler folder cannot be built" kq "$S1_FX" build filler "$NR_FILLER_ROWS" || return 1
  nr_do S1.22 "(iii) the filler folder cannot be picked" pick_folders filler || return 1
  nr_do S1.22 "(iii) Start indexing cannot be pressed" press_start || return 1
  for ((i = 0; i < 360; i++)); do
    nr_status_counts
    [ "$NR_DONE" -ge 3 ] && break
    sleep 0.5
  done
  if [ "$NR_DONE" -lt 3 ]; then
    nr_state_rc S1.22 4 "(iii) indexing made no progress within 180 s of Start indexing, so there is nothing to pause part way"
    return 1
  fi
  nr_do S1.22 "(iii) \"Pause indexing\" cannot be pressed in the status item's menu" kq "$S1C_AX" click "Pause indexing" || return 1
  s7_wait_state paused 30 || nr_why "the status item never said Paused after \"Pause indexing\" (it reads \"$S7_LABEL\")"
  nr_status_counts
  if [ "$NR_OPEN" = 0 ]; then
    nr_state_rc S1.22 4 "(iii) indexing had finished ($NR_DONE of $NR_KNOWN done) before it was paused: a larger filler (NR_FILLER_ROWS) is needed"
    return 1
  fi
  # a slow mirror, so text 1 stays on screen while the planted file is downloaded again
  nr_do S1.22 "(iii) the mirror cannot be slowed" kq "$S1C_MR" rate 2000000 || return 1
  nr_do S1.22 "(iii) the damaged model cannot be planted" kq "$S1_FX" plant-model truncated || return 1
  nr_read_panel 30 "Not ready yet" "The model file was damaged and is downloading again"; rc=$?
  nr_panel_rc S1.22 $rc || return 1
  nr_save s1-22-iii-text1
  nr_shot s1-22-iii-text1
  nr_has "Not ready yet" || nr_why "with indexing paused and the model damaged the panel shows no 'Not ready yet' heading"
  nr_has "The model file was damaged and is downloading again" || nr_why "with indexing paused and the model damaged the panel shows no 'The model file was damaged and is downloading again' (text 1)"
  nr_must_lack "Still indexing" "while the model is damaged (text 1 must win over text 3)"
  # the re-download finishes: the mirror at full rate
  nr_do S1.22 "(iii) the mirror cannot be sped up" kq "$S1C_MR" rate max || return 1
  s1c_wait_models 300 || nr_why "the model files were not whole 300 s after the mirror went to full rate"
  nr_read_panel 40 "Still indexing"; rc=$?
  nr_panel_rc S1.22 $rc || return 1
  nr_save s1-22-iii-text3
  nr_shot s1-22-iii-text3
  nr_has "Still indexing" || nr_why "after the re-download the panel does not show text 3 again (no 'Still indexing')"
  nr_must_lack "Not ready yet" "after the re-download (text 1 must be gone)"
  nr_must_lack "Nothing is indexed yet" "with indexing paused and rows unread"
  return 0
}

# s1c_22_iv : Delete index with the model whole and Start not pressed: text 4, not text 2. Reasons go to NR_WHY. Status 0
# judged; 1 a CHECK line was printed (S1_RC is set).
s1c_22_iv() {
  NR_WHY=""
  s1c_delete_index || return 0
  s1c_wait_gone 10 || nr_why "index.sqlite, -wal or -shm are still in Sesame's folder 10 s after Delete index: $(s1c_present)"
  nr_models_whole || nr_why "the model files are not whole, so text 4 and text 2 cannot be told apart"
  [ "$(nr_start_pressed)" = false ] || nr_why "settings.json does not say startPressed false after Delete index"
  s1c_read_text4 S1.22 "after Delete index with the model whole" || return 1
  return 0
}

# ---- S1.29, the rest ------------------------------------------------------------------------------------------

# s1c_29_sections : each of the four sections of Settings (the sidebar buttons Folders, File types, Search, Indexing), one
# by one: its sidebar button is pressed (settings_section), then the page is walked with Tab. The sidebar is four buttons, not
# a list of rows, so the four names are fixed here and the product is held to them: a button that cannot be found, or a section
# that does not open, is a reason (NR_WHY, so the check FAILs) and that page is not walked; a Settings window that cannot be put
# in front is a reason for the section it was wanted for. Never a pass on one page.
s1c_29_sections() {
  local sec n=0 rc
  nr_set_dump
  for sec in "Folders" "File types" "Search" "Indexing"; do
    nr_settings_open; rc=$?
    if [ $rc != 0 ]; then nr_why "Settings section $sec: the Settings window could not be put in front again ($PN_OUT)"; continue; fi
    if ! settings_section "$sec"; then nr_why "Settings section $sec: its sidebar button could not be pressed, or the section did not open"; continue; fi
    echo "Settings section: $sec"
    nr_walk settings
    n=$((n + 1))
  done
  echo "Settings sections walked with Tab: $n of 4"
  [ "$n" = 4 ] || nr_why "only $n of the 4 Settings sections were walked with Tab"
}

# s1c_29_setup : the four setup steps (Welcome, Folders, Permissions, Shortcut), each walked with Tab, Next pressed between
# them, Finish and Start indexing never pressed. The state is the recipe `setup`: a fresh app with the setup window. Reasons go
# to NR_WHY. Status 0 judged; 1 a CHECK or RERUN line was printed (S1_RC is set).
s1c_29_setup() {
  local out rc steps=0 i
  out="$(recipe_setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  if [ $rc != 0 ]; then nr_state_rc S1.29 "$rc" "(setup) recipe setup: $(nr_pick_msg "$out")"; return 1; fi
  if ! picker_front; then nr_why "setup: $PICKER_WHY, so Tab cannot be posted to the setup window"; return 0; fi
  for ((i = 1; i <= 4; i++)); do
    wait_setup_window 5 >/dev/null 2>&1 || { nr_why "setup step $i: no setup window"; break; }
    nr_walk setup
    steps=$((steps + 1))
    echo "setup step $i controls reached forward: $(printf '%s' "$NR_WALK" | tr '\n' '|')"
    [ "$i" -lt 4 ] || break
    if setup_has "Next"; then
      kq "$KIT_SCRIPTS/kit-ax.sh" click "Next" >/dev/null 2>&1 || { nr_why "setup step $i: pressing \"Next\" failed"; break; }
    else
      kq "$KIT_SCRIPTS/kit-ax.sh" click "Not now" >/dev/null 2>&1 || { nr_why "setup step $i: pressing \"Not now\" failed"; break; }
    fi
    sleep 1
  done
  [ "$steps" = 4 ] || nr_why "only $steps of the 4 setup steps were walked with Tab"
  return 0
}

# ---- S1.6: a file appears once even when picked folders overlap ---------------------------------------------

# s1c_settings : the status item's "Settings…", then the Settings window's tree in S6_DUMP. Status 0 read; 3 a person-step
# (S6_ERR says which); 1 not read.
s1c_settings() {
  kq "$S1C_AX" click "Settings…" >/dev/null 2>&1 || { S6_ERR="pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings
}

# s1c_folders : stdin the Settings dump, stdout the folders it lists, once each. A folder row is a tick whose accessibility help
# is the folder's full path (ax_folders); the Re-index and Remove buttons and the code folders are no folder of the list.
s1c_folders() { ax_folders; }

s1_check_6() {
  local rc folders ov ovp q lists=0 dups rows under_n under_dups want_n shown exp exp_g exp_o gp_n gp_dups gp_want pick_why="" out
  s1_begin S1.6 1 || return $S1_RC
  if [ -n "$KIT_PLANT" ]; then s1_open S1.6 || return $S1_RC; fi
  NR_WHY=""
  # 1. the overlap the kit builds: a parent folder (fixtures/overlap) that holds a photos/ subfolder and two loose photos, copied
  #    from the golden photos. Both are picked in Settings through the picker; the list must then hold both, else there is no
  #    overlap to test and the check would prove nothing.
  kq "$S1_FX" build overlap >/dev/null 2>&1 || { echo "RERUN S1.6 not valid: kit-fixtures.sh build overlap failed (fixtures/golden must be built first; the recipe photos builds it)"; return 4; }
  ov="$(real_path "$KIT_ROOT/fixtures/overlap")"
  ovp="$(real_path "$KIT_ROOT/fixtures/overlap/photos")"
  if [ -z "$ov" ] || [ -z "$ovp" ]; then echo "RERUN S1.6 not valid: kit-fixtures.sh build overlap left no fixtures/overlap/photos"; return 4; fi
  s1c_settings; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S1.6 NEEDS-A-PERSON $S6_ERR"; return 0 ;;
    *) s1_fail S1.6 "Settings did not open: $S6_ERR"; return 1 ;;
  esac
  settings_section Folders || { s1_fail S1.6 "the Settings window cannot be put on its Folders section, so no folder can be added"; return 1; }
  PK_WINDOW=settings drive_picker "$KIT_ROOT/fixtures/overlap"; rc=$?
  [ $rc = 0 ] || pick_why="the parent: $PICKER_WHY"
  PK_WINDOW=settings drive_picker "$KIT_ROOT/fixtures/overlap/photos"; rc=$?
  [ $rc = 0 ] || pick_why="${pick_why:+$pick_why; }the subfolder: $PICKER_WHY"
  settings_section Folders >/dev/null || nr_why "the Settings window cannot be put on its Folders section to read the picked list"
  s6b_settings >/dev/null
  folders="$(printf '%s\n' "$S6_DUMP" | s1c_folders)"
  echo "picked folders: $(printf '%s' "$folders" | tr '\n' '|')"
  if ! printf '%s\n' "$folders" | awk -v a="$ov" -v b="$ovp" '$0 == a { x = 1 } $0 == b { y = 1 } END { exit (x && y) ? 0 : 1 }'; then
    echo "CHECK S1.6 NEEDS-A-PERSON overlap and overlap/photos must both be picked, or the overlap is not there to test and the check would prove nothing${pick_why:+ (the picker said: $pick_why)}: in Settings press \"Add folder…\" and pick $ov and then $ovp by hand, wait for Ready, then run scripts/kit-run.sh S1 --ids S1.6 again (picked now: $(printf '%s' "$folders" | tr '\n' ' '))"
    return 0
  fi
  # both are picked and wait for Start indexing (Indexing section); the library now holds the overlap, so the next check that
  # needs the photos starts the recipe again
  settings_section Indexing || nr_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
  kq "$S1C_AX" click "Start indexing" >/dev/null 2>&1 || nr_why "pressing \"Start indexing\" in Settings failed"
  rm -f "$S1_MARK"
  out="$(kq "$S1C_IX" wait done 900 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || nr_why "the overlap was not indexed within 900 s of Start indexing (kit-index.sh wait done exited $rc)"
  # 2. no path twice in any list, across every query of the photo group
  while IFS= read -r q <&3; do
    [ -n "$q" ] || continue
    s1_search "$q"; rc=$?
    s1_search_ok S1.6 $rc || return $S1_RC
    lists=$((lists + 1))
    dups="$(printf '%s\n' "$S1_OUT" | awk '$1 == "row" { n = $0; sub(/^row [0-9]+ (selected|-) ?/, "", n); seen[n]++ } END { for (k in seen) if (seen[k] > 1) print k }')"
    [ -z "$dups" ] || nr_why "the list for \"$q\" holds the same row twice: $dups"
  done 3< <(s1_queries photo)
  [ "$lists" -gt 0 ] || { echo "RERUN S1.6 not valid: fixtures/answers.csv holds no query of the photo group, so no list was read"; return 4; }
  # 3. one files row per path under overlap (the folder picked twice, once as the parent and once as its subfolder) and under golden/photos
  rows="$(kq "$S1C_IX" under overlap 2>&1)"
  under_n="$(printf '%s\n' "$rows" | awk -F'\t' 'NF == 3 { n++ } END { print n + 0 }')"
  under_dups="$(printf '%s\n' "$rows" | awk -F'\t' 'NF == 3 { seen[$1]++ } END { for (k in seen) if (seen[k] > 1) print k }')"
  want_n="$(kq "$S1_FX" expect listing overlap 2>&1 | awk 'NF && !/^(LISTING|MISSING|EXTRA|WRONG)/ { n++ } END { print n + 0 }')"
  if [ "$want_n" = 0 ]; then echo "RERUN S1.6 not valid: kit-fixtures.sh expect listing overlap names no path"; return 4; fi
  [ -z "$under_dups" ] || nr_why "kit-index.sh under overlap shows a path in more than one files row: $under_dups"
  [ "$under_n" = "$want_n" ] || nr_why "kit-index.sh under overlap shows $under_n files rows, kit-fixtures.sh expect listing overlap names $want_n paths"
  rows="$(kq "$S1C_IX" under golden/photos 2>&1)"
  gp_n="$(printf '%s\n' "$rows" | awk -F'\t' 'NF == 3 { n++ } END { print n + 0 }')"
  gp_dups="$(printf '%s\n' "$rows" | awk -F'\t' 'NF == 3 { seen[$1]++ } END { for (k in seen) if (seen[k] > 1) print k }')"
  gp_want="$(kq "$S1_FX" expect listing golden 2>&1 | awk '/^photos\// { n++ } END { print n + 0 }')"
  if [ "$gp_want" = 0 ]; then echo "RERUN S1.6 not valid: kit-fixtures.sh expect listing golden names no path under photos/"; return 4; fi
  [ -z "$gp_dups" ] || nr_why "kit-index.sh under golden/photos shows a path in more than one files row: $gp_dups"
  [ "$gp_n" = "$gp_want" ] || nr_why "kit-index.sh under golden/photos shows $gp_n files rows, kit-fixtures.sh expect listing golden names $gp_want paths under photos/"
  # 4. the menu's photo count is golden's plus overlap's from expect counts, each photo counted once
  s6b_menu_ready 120 || nr_why "the menu bar never said Ready, so its photo count is not final"
  s7_menu; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S1.6 NEEDS-A-PERSON $S7_ERR"; return 0 ;;
    *) nr_why "the status item's menu could not be read: $S7_ERR" ;;
  esac
  shown="$(s7_menu_counts | awk '$1 == "photo" { print $2; exit }')"
  exp_g="$(s6b_expected "$KIT_ROOT/fixtures/golden" | awk '$1 == "photo" { print $2; exit }')"
  exp_o="$(s6b_expected "$KIT_ROOT/fixtures/overlap" | awk '$1 == "photo" { print $2; exit }')"
  if [ -z "$exp_g" ] || [ -z "$exp_o" ]; then echo "RERUN S1.6 not valid: kit-fixtures.sh expect counts printed no photo count for golden ($exp_g) or overlap ($exp_o)"; return 4; fi
  exp=$((exp_g + exp_o))
  [ "$shown" = "$exp" ] || nr_why "the menu says ${shown:-no} photos, kit-fixtures.sh expect counts says $exp (golden $exp_g plus overlap $exp_o, each photo counted once although overlap and overlap/photos are both picked)"
  if [ -n "$NR_WHY" ]; then s1_fail S1.6 "$NR_WHY"; return 1; fi
  echo "CHECK S1.6 PASS with overlap/ and its subfolder overlap/photos/ both picked, none of the $lists lists (every photo query) held a row twice, kit-index.sh under overlap shows $under_n files rows for the $want_n paths kit-fixtures.sh expect listing names and under golden/photos $gp_n for $gp_want, one per path, and the menu says $shown photos, as expect counts does (golden $exp_g plus overlap $exp_o)"
}
check_S1_6() { nr_run s1_check_6; }

# ---- S1.30: the search box, the list and the status item have VoiceOver labels ----------------------------------

# s1c_label_ok <what> <label> <mockup label> : an empty label, a bare role word or a label that could not be read is a failure
# (NR_WHY); another wording than the mockup's is noted, never a failure.
s1c_label_ok() {
  local lc
  lc="$(printf '%s' "$2" | tr 'A-Z' 'a-z' | sed 's/^[ ]*//; s/[ ]*$//')"
  case "$lc" in
    "") nr_why "$1 has an empty accessibility label"; return 1 ;;
    error:*) nr_why "$1: its label could not be read ($2)"; return 1 ;;
    "text field"|"search field"|"text"|"static text"|"list"|"table"|"outline"|"group"|"button"|"image"|"menu bar item"|"menu item"|"status item"|"scroll area"|ax*)
      nr_why "$1 has a bare role word as its label (\"$2\")"; return 1 ;;
  esac
  case "$lc" in
    "$(printf '%s' "$3" | tr 'A-Z' 'a-z')"*) echo "  | $1: label \"$2\"" ;;
    *) echo "  | noted: $1: label \"$2\", the mockup says \"$3\"" ;;
  esac
  return 0
}

s1_check_30() {
  local rc el lbl lst status
  s1_begin S1.30 1 || return $S1_RC
  if [ -n "$KIT_PLANT" ]; then s1_open S1.30 || return $S1_RC; fi
  NR_WHY=""
  s1_search "$S1_QUERY" --keep-open; rc=$?
  s1_search_ok S1.30 $rc || return $S1_RC
  pn_dump
  nr_save s1-30-panel
  el="$(printf '%s\n' "$PN_DUMP" | pn_elements)"
  lbl="$(pn_searchbox | cut -f1)"
  lst="$(printf '%s\n' "$el" | awk -F'\t' '{ r = $2; sub(/\/.*/, "", r) } r == "AXList" || r == "AXTable" || r == "AXOutline" { print $3; exit }')"
  status="$(s7_label)"
  s1c_label_ok "the search box" "$lbl" "Search your files"
  s1c_label_ok "the result list" "$lst" "Results"
  s1c_label_ok "the status item" "$status" "Sesame: ready"
  if [ -n "$NR_WHY" ]; then s1_fail S1.30 "$NR_WHY"; return 1; fi
  echo "CHECK S1.30 PASS the search box (\"$lbl\"), the result list (\"$lst\") and the status item (\"$status\") each expose a non-empty accessibility label that is not a bare role word"
}
check_S1_30() { nr_run s1_check_30; }

# ---- S8.11: Delete index removes the index file, and the panel says so until Start indexing ------------------------

s8_check_11() {
  local out rc
  s1_begin S8.11 1 || return $S1_RC
  if [ -n "$KIT_PLANT" ]; then s1_open S8.11 || return $S1_RC; fi
  NR_WHY=""
  if ! s6b_menu_ready 120; then
    echo "RERUN S8.11 not valid: the menu bar does not say Ready, and Delete index is pressed after Ready"
    return 4
  fi
  s1c_delete_flow S8.11 "" || return $S1_RC
  if [ -z "$NR_WHY" ]; then
    # indexing runs again only after "Start indexing": the file comes back and the menu says Ready after the run
    kq "$S1C_AX" click "Settings…" >/dev/null 2>&1 || nr_why "pressing \"Settings…\" in the status item's menu failed"
    s6b_settings || nr_why "Settings did not open"
    settings_section Indexing || nr_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
    kq "$S1C_AX" click "Start indexing" >/dev/null 2>&1 || nr_why "pressing \"Start indexing\" in Settings failed"
    out="$(kq "$S1C_IX" wait done 900 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $rc = 0 ] || nr_why "indexing was not done within 900 s of Start indexing: $(s1_last "$out")"
    s6b_menu_ready 120 || nr_why "the menu bar never said Ready after Start indexing"
    [ -n "$(s1c_present)" ] || nr_why "index.sqlite did not come back after Start indexing"
  fi
  if [ -n "$NR_WHY" ]; then s1_fail S8.11 "$NR_WHY"; return 1; fi
  echo "CHECK S8.11 PASS after Ready, Delete index and its confirmation left no index.sqlite, -wal or -shm in Sesame's folder within 10 s, startPressed read false, the panel showed \"Not ready yet\" and \"Nothing is indexed yet\" with no text and with a typed text, a relaunch kept it, and Start indexing brought the index back and the menu said Ready"
}
check_S8_11() { nr_run s8_check_11; }

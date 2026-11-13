#!/bin/bash
# kit-golden.sh engine  [--group a|b|c|d] [--min-first N] [--from <file>]
# kit-golden.sh panel   [--group a|b|c|d] [--min-first N] [--from <file>]
# kit-golden.sh prepare [--whole|--all]
# kit-golden.sh index-state [--whole|--all]
#
# Group d (plan 5, spec S2(d), S4.10): the 8 audio and the 8 video rows of the key and the videospeech row. engine runs `swift test --filter
# GroupDTests` (after the builds of golden, golden-docs and golden-av; GroupDTests makes its own whole index with `prepare --all`), panel
# searches each row in the real panel (the pane's "Opens at mm:ss", reached with Down, is the stated moment; needs `prepare --all` first).
# Lines: `GOLDEN <id> rank <n|none> second <s|none>` per row, one for the videospeech row, and `GOLDEN v12 above <no|yes>` (yes when
# clip-v12.mp4 is above clip-v11.mp4 in the videospeech query's list). Each prints `PASS|FAIL <id> query="<q>" expected=<file> rank=<n|none>
# second=<s|none>` per row, then `GOLDEN <mode> group d: audio first-3 <x> of 8, moment right <y> of 8; video first-3 <z> of 8, moment right
# <w> of 8; videospeech first-3 <yes|no>, v12 above <no|yes>: PASS|FAIL` (PASS at x, y, z and w each 7 or more, the videospeech row in
# the first 3 and v12 not above it; a moment is right when the second is inside [locator, locator + window_s]), then the odd and even rows
# apart. No v12 line is `FAIL no v12 line`. `--from <file>` (a test-only option, groups c and d) reads those lines from the file.
#
# prepare --all (plan 5) is the whole index of golden/photos, golden-docs and golden-av (its own marker run/golden-index-all; the damaged clips
# of golden-av/damaged are could_not_read, as the locked and the damaged pdf are); golden_indexed_all is the gate of panel --group d, and
# index-state --all is its read-only reading: `INDEX GOLDEN ALL DONE: yes|no` and `INDEX GOLDEN ALL ONLY: yes|no`, exit 0 only when both are
# yes. `prepare` and `prepare --whole` are unchanged (photo-scoped and photos-plus-documents) and each re-makes the shared index when
# another's is there.
# kit-golden.sh merge [--from <file>] | extensions
#
# Every engine or panel run of a group a to d saves its GOLDEN lines to run/golden-lines-<mode>-<group>.txt (check_S2_15 compares them).
#
# Group c (plan 4, spec S2(c)): the 10 pdf rows, the 6 doc rows and the scanned row of the key. engine runs `swift test --filter
# GroupCTests` (after `kit-fixtures.sh build golden-docs`) and panel searches each row in the real panel (the pane's "Page N of M",
# reached with Down, names the page); each prints one line per row, `PASS|FAIL <id> query="<q>" expected=<file> rank=<n|none>
# page=<p|none>`, then `GOLDEN <mode> group c: pdf first-3 <x> of 10, page right <y> of 10; doc first-3 <z> of 6; scanned
# first-3 <yes|no>: PASS|FAIL` (PASS at x >= 9, y >= 9, z >= 5 and the scanned row in the first 3), then the odd and even rows
# scored apart. GroupCTests prints `GOLDEN <id> rank <n|none> page <p|none>` per row. `--from <file>` (a test-only option, group c
# only, exit 2 otherwise) reads those lines from the file instead of running the tests or the panel: a pure run on hand-written
# lines. A row with no line is rank none (`no group c test yet` while GroupCTests does not exist).
#
# index-state is read-only: `INDEX GOLDEN PHOTOS ONLY: yes` (exit 0) when the index holds the 40 golden photos under golden/photos,
# all done, and no other file, else `no ...` (exit 1); prepare's "already made" shortcut is this reading, so an index that also
# holds PDFs or documents (the recipe `golden`, a whole-folder index of a later task) is re-made, never reused.
#
# The golden evaluation of S2 (verify.md, Kit scripts; spec S2(a)): the right photo is first for at least 6 of the 10
# photo rows of fixtures/answers.csv and within the first 3 for at least 9 (`--min-first N` replaces the 6, to show the
# verdict can go red). One line per row, `PASS|FAIL <id> query="<q>" expected=<file> rank=<n|none>[: <why>]`, then one
# summary line. Rows are written to golden-engine.tsv or golden-panel.tsv in the evidence folder (kit-lib/golden.sh).
# Groups a (photos), b (exact words, plan 3), c and d are built; with no --group group a runs. Group b scores only the exact rows whose file has a reader (kit-lib/read-kinds.txt: with
# `photo` that is six of the 20) and its bar is every readable row first (the spec's 19 of 20 when all 20 are readable);
# its summary line is `GOLDEN <mode> group b: first <f> of <n> readable (<total> rows in the key), need ...: PASS|FAIL`,
# followed by the odd and even rows scored apart (`odd first <x> of <n>, even first <y> of <m>`, and `noted: overfitting
# risk` when the even rows hit at least 2 fewer).
#
#   engine   runs `swift test --filter GroupATests` (group b: GroupBTests) from the project root, with KIT_ROOT in its
#            environment, after `kit-fixtures.sh build golden` (nothing is rewritten when the folder is right). The tests
#            are Tests/GoldenTests/GroupATests.swift (plan-1-t32) and GroupBTests (plan-3-t18); each prints one line per
#            row of its group in answers.csv (group b: the readable rows):
#                GOLDEN <row id> rank <n|none>
#            where n is the 1-based place of the row's expected file in the engine's ranked list. The last line for an id
#            counts. With no matching test the runner prints `no group <letter> test yet` for every row; with a test that
#            did not build or run, the last error line; with a test that left a row out, `Group<LETTER>Tests printed no
#            GOLDEN line for this row` (kit-lib/golden.sh golden_none_why). Every row is then a FAIL with rank none.
#   merge    runs `swift test --filter MergeTests` (the ranking-merge checks of S2.8: decoys, 1,000 unrelated files,
#            removal, odd and even split) and prints every `RANK <id> <n|none> odd|even` line it printed; exit status is
#            the test's; with no matching test it prints `no merge test yet` and exits 1.
#   extensions  runs `kit-fixtures.sh expect extensions --kinds <read-kinds>` (a missing fixture file stops here, exit 4),
#            then `swift test --filter ExtensionsTests` (S2.17: each extension of the kinds with a reader is in the index
#            and found by its name); with no matching test it prints `no extensions test yet` and exits 1.
#   panel    replays every row through the real panel: for each row the shortcut opens the panel, the query is typed into
#            Sesame, the settled list is read from the accessibility tree and the place of the expected file's name is the
#            rank. The shortcut is posted only inside this script's own kit window (`kitwindow open` before the first
#            post, `kitwindow close` after the last, closed on every path); typing goes to Sesame only; no capture of the
#            screen is taken. With no panel (the app not running, no panel after the shortcut, no search box) every row
#            is `FAIL ... rank=none: no panel to search: <why>`. The app is not started here (kit-launch.sh start) and the
#            golden photos must already be indexed in home/ (kit-golden.sh prepare, or kit-run.sh prep photos).
#   prepare  makes sure home/ holds an index of the 40 golden photos made by the current bundle's helper and prints the
#            index path. Idempotent: when a marker of this starting state names the current helper and the index holds 40
#            done photo files under golden/photos and no other file (index-state), it prints the path and does nothing.
#            Otherwise: the cheap preconditions first (starting state, bundle, a helper with an index mode, the whole model
#            files in cache/), then kit-reset.sh with the cached model, kit-fixtures.sh build golden, and the bundled helper
#            over the photos (kit-launch.sh helper index --folders golden/photos: photo-scoped, never golden-docs). The helper is
#            run again while a photo is not done (a run closed early, as by a sleeping Mac, drops its step in flight): two runs in
#            a row with no photo more done end it with `the helper made no progress in 2 runs`, and at most 10 runs are made. A
#            helper with no index mode: exit 1 with `helper has no index mode`.
#   prepare --whole  (plan 4, group c) the same for the whole-folder index: the helper indexes golden/photos and golden-docs (the
#            60-page scanned pdf included: minutes, so the helper is run again while work is left), with its own marker
#            run/golden-index-whole. The shortcut: the marker names the current helper, golden_indexed_whole (every file with a
#            reader under golden/photos and golden-docs is `done`, the locked and the damaged pdf `could_not_read`; files of other
#            roots such as boundary do not count) and the index holds no file outside those two folders. The photo-scoped
#            prepare and this one each re-make the shared home/ index when the other's is there, so run them one after another.
#            golden_indexed_whole is also the gate of panel --group c. index-state --whole is the read-only reading:
#            `INDEX GOLDEN WHOLE DONE: yes|no` (golden_indexed_whole alone) and `INDEX GOLDEN WHOLE ONLY: yes|no` (no file outside
#            the two folders), exit 0 when both are yes.
# Exit codes: 0 the group passed (prepare: ready); 1 a row failed, no reading could be taken, or something is not built; 2
# usage; 3 a person-step is missing (NEEDS A PERSON: ...); 4 not valid (the list did not settle, no starting state): rerun.
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/panel.sh"
. "$KIT_LIB/recipes.sh"
. "$KIT_LIB/golden.sh"

usage() {
  cat >&2 <<'EOF'
usage: kit-golden.sh engine [--group a|b|c|d] [--min-first N] [--from <file>]
       kit-golden.sh panel [--group a|b|c|d] [--min-first N] [--from <file>]
       kit-golden.sh prepare [--whole]
       kit-golden.sh prepare [--all]
       kit-golden.sh index-state [--whole]
       kit-golden.sh index-state [--all]
       kit-golden.sh merge [--from <file>] | extensions
EOF
}

G_GROUP=""
G_MINFIRST="$GOLDEN_MIN_FIRST"
G_FROM=""

# parse_opts <args...> : --group a-d and --min-first N (a positive whole number). Status 2 on a bad option.
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --group)
        [ $# -ge 2 ] || return 2
        case "$2" in a|b|c|d) G_GROUP="$2" ;; *) return 2 ;; esac
        shift 2 ;;
      --min-first)
        [ $# -ge 2 ] || return 2
        case "$2" in ""|*[!0-9]*|0) return 2 ;; esac
        G_MINFIRST="$2"
        shift 2 ;;
      --from)
        [ $# -ge 2 ] && [ -f "$2" ] && [ -r "$2" ] || return 2
        G_FROM="$2"
        shift 2 ;;
      *) return 2 ;;
    esac
  done
  # --from is for the pure runs of groups c and d only
  [ -z "$G_FROM" ] || [ "$G_GROUP" = c ] || [ "$G_GROUP" = d ] || return 2
  return 0
}

# groups_to_run : the letters to run, one per line (no --group: group a; group b only when asked for).
groups_to_run() {
  if [ -n "$G_GROUP" ]; then echo "$G_GROUP"; else echo a; fi
}

# summary <mode> <letter> <rows> <first> <top3> : the one closing line; status 0 PASS, 1 FAIL. Group b has its own bar.
summary() {
  local v
  if [ "$2" = b ]; then
    golden_line_b "$1" "$3" "$4" "$(golden_key_rows b)"
    return $?
  fi
  v="$(golden_verdict "$3" "$4" "$5" "$G_MINFIRST")"
  echo "GOLDEN $1 group $2: first $4 of $3 (need $G_MINFIRST), top-3 $5 of $3 (need $GOLDEN_MIN_TOP3): $v"
  [ "$v" = PASS ]
}

# oddeven_note <tsv> <letter> : groups b and c, the odd and even rows scored apart after the summary line.
oddeven_note() {
  { [ "$2" = b ] || [ "$2" = c ] || [ "$2" = d ]; } && golden_oddeven "$1" "$2"
  return 0
}

# ---- engine -----------------------------------------------------------------------------------------

# engine_group <letter> : status 0 passed, 1 failed.
engine_group() {
  local g="$1" rows out rc build why rowwhy ranks tsv new id q f l rank n first top3 filter
  rows="$(golden_rows "$g")"
  if [ -z "$rows" ]; then echo "no rows for group $g in $GOLDEN_ANSWERS"; return 1; fi
  case "$g" in a) filter=GroupATests ;; b) filter=GroupBTests ;; esac
  if ! command -v swift >/dev/null 2>&1; then
    echo "NEEDS A PERSON: swift is not on the path: install Xcode 26 (verify.md, Verify command)"
    return 3
  fi
  build="$(kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$build"
    echo "the golden fixtures could not be built: nothing was evaluated"
    return 1
  fi
  out="$( ( cd "$KIT_PROJECT" && swift test --filter "$filter" ) 2>&1 )"; rc=$?
  ranks="$(printf '%s\n' "$out" | awk '$1 == "GOLDEN" && $3 == "rank" { r[$2] = $4 } END { for (i in r) print i "\t" r[i] }')"
  why=""
  if [ -z "$ranks" ]; then
    why="$(printf '%s\n' "$out" | golden_none_why "$g")"
  fi
  new="$KIT_TMP/kit-golden-rows.$$"
  : > "$new"
  while IFS=$'\t' read -r id q f l <&3; do
    rank="$(printf '%s\n' "$ranks" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')"
    case "$rank" in ""|*[!0-9]*) rank=none ;; esac
    rowwhy=""
    if [ "$rank" = none ]; then
      rowwhy="${why:-$filter printed no GOLDEN line for this row}"
    fi
    golden_line "$id" "$q" "$f" "$rank" "$rowwhy"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$g" "$q" "$f" "$rank" "$l" "$(golden_pass "$rank")" >> "$new"
  done 3<<EOF
$rows
EOF
  tsv="$(golden_dir)/golden-engine.tsv"
  golden_write_tsv "$tsv" "$g" "$new"
  golden_save_lines engine "$g" "$(awk -F'\t' '{ print "GOLDEN " $1 " rank " $5 }' "$new")"
  rm -f "$new"
  set -- $(golden_counts "$tsv" "$g")
  n="$1"; first="$2"; top3="$3"
  summary engine "$g" "$n" "$first" "$top3"
  rc=$?
  oddeven_note "$tsv" "$g"
  echo "wrote $tsv"
  return $rc
}

# ---- group c (PDFs and documents, plan 4) ------------------------------------------------------------

# report_c <mode> <filter name> <readings> : the rows of group c from <readings> (the `GOLDEN <id> rank <n|none> page <p|none>`
# lines of GroupCTests, the panel loop or the --from file; the last line for an id counts), one printed line each, the rows
# written to golden-engine.tsv or golden-panel.tsv (an 8th column, page, for group c), the summary line and the odd and even
# rows. A row with no line is rank none. Status 0 PASS, 1 FAIL.
report_c() {
  local mode="$1" filter="$2" out="$3" rows ranks why="" new tsv id q f l rank page rowwhy rc
  rows="$(golden_rows c)"
  ranks="$(printf '%s\n' "$out" | awk '$1 == "GOLDEN" && $3 == "rank" && $5 == "page" && NF == 6 { r[$2] = $4 "\t" $6 } END { for (i in r) print i "\t" r[i] }')"
  if [ -z "$ranks" ]; then
    why="$(printf '%s\n' "$out" | golden_none_why c)"
  fi
  new="$KIT_TMP/kit-golden-rows.$$"
  : > "$new"
  while IFS=$'\t' read -r id q f l <&3; do
    rank="$(printf '%s\n' "$ranks" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')"
    page="$(printf '%s\n' "$ranks" | awk -F'\t' -v id="$id" '$1 == id { print $3; exit }')"
    case "$rank" in ""|*[!0-9]*) rank=none ;; esac
    case "$page" in ""|*[!0-9]*) page=none ;; esac
    rowwhy=""
    if [ "$rank" = none ]; then
      rowwhy="${why:-$filter printed no GOLDEN line for this row}"
      page=none
    fi
    golden_line_c "$id" "$q" "$f" "$rank" "$page" "$rowwhy"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" c "$q" "$f" "$rank" "$l" "$(golden_pass "$rank")" "$page" >> "$new"
  done 3<<EOF
$rows
EOF
  tsv="$(golden_dir)/golden-$mode.tsv"
  golden_write_tsv "$tsv" c "$new"
  golden_save_lines "$mode" c "$out"
  rm -f "$new"
  set -- $(golden_score_c "$tsv")
  golden_line_c_summary "$mode" "$1" "$2" "$3" "$4" "$5" "$6"
  rc=$?
  oddeven_note "$tsv" c
  echo "wrote $tsv"
  return $rc
}

# engine_group_c : status 0 passed, 1 failed, 3 a person-step. Without --from: `swift test --filter GroupCTests` after the
# golden-docs build (nothing is rewritten when the folder is right).
engine_group_c() {
  local rows out rc build
  rows="$(golden_rows c)"
  if [ -z "$rows" ]; then echo "no rows for group c in $GOLDEN_ANSWERS"; return 1; fi
  if [ -n "$G_FROM" ]; then
    out="$(cat "$G_FROM")"
  else
    need_swift || return 3
    build="$(kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-docs 2>&1)"; rc=$?
    if [ $rc != 0 ]; then
      printf '%s\n' "$build"
      echo "the golden-docs fixtures could not be built: nothing was evaluated"
      return 1
    fi
    out="$( ( cd "$KIT_PROJECT" && swift test --filter GroupCTests ) 2>&1 )"
  fi
  report_c engine GroupCTests "$out"
}

# ---- group d (audio and video, plan 5) ----------------------------------------------------------------

# report_d <mode> <filter name> <readings> : the rows of group d from <readings> (the `GOLDEN <id> rank <n|none> second <s|none>` lines of
# GroupDTests, the panel loop or the --from file, the videospeech row's own line, and `GOLDEN v12 above <no|yes>`; the last line for an
# id counts), one printed line each, the 16 rows written to golden-engine.tsv or golden-panel.tsv (an 8th column, the stated second), the
# summary line and the odd and even rows. A row with no line is rank none; no v12 line is `FAIL no v12 line`. Status 0 PASS, 1 FAIL.
report_d() {
  local mode="$1" filter="$2" out="$3" rows ranks why="" new tsv id q f l rank sec rowwhy rc v12 vs vsrow vsid
  rows="$(golden_rows d)"
  ranks="$(printf '%s\n' "$out" | awk '$1 == "GOLDEN" && $3 == "rank" && $5 == "second" && NF == 6 { r[$2] = $4 "\t" $6 } END { for (i in r) print i "\t" r[i] }')"
  v12="$(printf '%s\n' "$out" | awk '$1 == "GOLDEN" && $2 == "v12" && $3 == "above" && NF == 4 && ($4 == "yes" || $4 == "no") { v = $4 } END { print v }')"
  if [ -z "$ranks" ]; then
    why="$(printf '%s\n' "$out" | golden_none_why d)"
  fi
  new="$KIT_TMP/kit-golden-rows.$$"
  : > "$new"
  while IFS=$'\t' read -r id q f l <&3; do
    rank="$(printf '%s\n' "$ranks" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')"
    sec="$(printf '%s\n' "$ranks" | awk -F'\t' -v id="$id" '$1 == id { print $3; exit }')"
    case "$rank" in ""|*[!0-9]*) rank=none ;; esac
    case "$sec" in ""|*[!0-9]*) sec=none ;; esac
    rowwhy=""
    if [ "$rank" = none ]; then
      rowwhy="${why:-$filter printed no GOLDEN line for this row}"
      sec=none
    fi
    golden_line_d "$id" "$q" "$f" "$rank" "$sec" "$rowwhy"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" d "$q" "$f" "$rank" "$l" "$(golden_pass "$rank")" "$sec" >> "$new"
  done 3<<EOF
$rows
EOF
  tsv="$(golden_dir)/golden-$mode.tsv"
  golden_write_tsv "$tsv" d "$new"
  golden_save_lines "$mode" d "$out"
  rm -f "$new"
  vsrow="$(golden_videospeech_row)"
  vsid="${vsrow%%$'\t'*}"
  rank="$(printf '%s\n' "$ranks" | awk -F'\t' -v id="$vsid" '$1 == id { print $2; exit }')"
  vs=no
  case "$rank" in 1|2|3) vs=yes ;; esac
  if [ -z "$v12" ]; then
    echo "FAIL no v12 line: GroupDTests must print GOLDEN v12 above <no|yes> (the negative control of S4.10)"
  fi
  set -- $(golden_score_d "$tsv")
  golden_line_d_summary "$mode" "$1" "$2" "$3" "$4" "$5" "$6" "$vs" "${v12:-none}"
  rc=$?
  oddeven_note "$tsv" d
  echo "wrote $tsv"
  return $rc
}

# engine_group_d : status 0 passed, 1 failed, 3 a person-step. Without --from: the three golden folders built (nothing is rewritten when
# one is right), then `swift test --filter GroupDTests` (which makes its own whole index with `prepare --all`).
engine_group_d() {
  local rows out rc build
  rows="$(golden_rows d)"
  if [ -z "$rows" ]; then echo "no rows for group d in $GOLDEN_ANSWERS"; return 1; fi
  if [ -n "$G_FROM" ]; then
    out="$(cat "$G_FROM")"
  else
    need_swift || return 3
    build="$(kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden 2>&1 && kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-docs 2>&1 && kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-av 2>&1)"; rc=$?
    if [ $rc != 0 ]; then
      printf '%s\n' "$build"
      echo "the golden fixtures could not be built: nothing was evaluated"
      return 1
    fi
    out="$( ( cd "$KIT_PROJECT" && swift test --filter GroupDTests ) 2>&1 )"
  fi
  report_d engine GroupDTests "$out"
}

# ---- merge and extensions (S2.8, S2.17) -------------------------------------------------------------

# no_matching_test <swift output> : status 0 when `swift test --filter` found no test to run.
no_matching_test() {
  case "$1" in
    *"No matching test cases"*|*"Test run with 0 tests"*|*"Executed 0 tests"*) return 0 ;;
  esac
  return 1
}

# need_swift : status 0 when swift is on the path, else the person-step line (status 3 for the caller to return).
need_swift() {
  command -v swift >/dev/null 2>&1 && return 0
  echo "NEEDS A PERSON: swift is not on the path: install Xcode 26 (verify.md, Verify command)"
  return 3
}

# merge_run [--from <file>] : `swift test --filter MergeTests` (--from, test-only, reads its lines from the file instead); every
# `RANK <id> <n|none> odd|even` line it printed, then the status: the test's.
merge_run() {
  local out rc ranks
  if [ $# = 2 ]; then
    out="$(cat "$2")"; rc=0
  else
    need_swift || return 3
    out="$( ( cd "$KIT_PROJECT" && swift test --filter MergeTests ) 2>&1 )"; rc=$?
  fi
  ranks="$(printf '%s\n' "$out" | golden_rank_lines)"
  [ -z "$ranks" ] || printf '%s\n' "$ranks"
  if no_matching_test "$out"; then
    echo "no merge test yet"
    return 1
  fi
  if [ -z "$ranks" ]; then
    echo "MergeTests printed no RANK line (swift test exit $rc)"
    printf '%s\n' "$out" | awk '/error:/ { l = $0 } END { if (l != "") print l }'
    return 1
  fi
  return $rc
}

# extensions_run : the fixture check for the kinds that have a reader, then `swift test --filter ExtensionsTests`.
extensions_run() {
  local kinds out rc
  kinds="$(golden_read_kinds)"
  if [ -z "$kinds" ]; then echo "scripts/kit-lib/read-kinds.txt lists no kind"; return 1; fi
  kq "$KIT_SCRIPTS/kit-fixtures.sh" expect extensions --kinds "$kinds"; rc=$?
  [ $rc = 0 ] || return $rc
  need_swift || return 3
  out="$( ( cd "$KIT_PROJECT" && swift test --filter ExtensionsTests ) 2>&1 )"; rc=$?
  if no_matching_test "$out"; then
    echo "no extensions test yet"
    return 1
  fi
  if [ $rc = 0 ]; then
    echo "EXTENSIONS ExtensionsTests ($kinds): PASS"
  else
    printf '%s\n' "$out" | tail -n 15
    echo "EXTENSIONS ExtensionsTests ($kinds): FAIL (swift test exit $rc)"
  fi
  return $rc
}

# ---- panel ------------------------------------------------------------------------------------------

PS_WHY=""
PS_ROWS=""

# panel_search <query> : opens the panel with the shortcut (inside the kit window), types the query into Sesame and reads the
# settled list into PS_ROWS. Status 0 a list was read; 1 there is no panel to search (PS_WHY says why); 3 a person-step
# (PS_WHY holds its line); 4 the list did not settle.
panel_search() {
  local rc box val out
  PS_WHY=""; PS_ROWS=""
  if [ -z "$(kit_pid_of app)" ]; then
    PS_WHY="Sesame is not running (scripts/kit-launch.sh start starts it)"
    return 1
  fi
  pn_open_panel; rc=$?
  if [ $rc != 0 ]; then
    PS_WHY="$PN_OUT"
    [ $rc = 3 ] && return 3
    return 1
  fi
  pn_dump
  box="$(pn_searchbox)" || { PS_WHY="the Sesame panel has no search box in its accessibility tree"; return 1; }
  pn_wait_sesame_front 3 || { PS_WHY="$PN_OUT, so nothing was typed"; return 1; }
  val="$(printf '%s' "$box" | cut -f2)"
  if [ -n "$val" ]; then
    PS_WHY="the search box holds \"$val\" after a fresh open, so nothing was typed"
    return 1
  fi
  out="$(pn_ax type "$1" 2>&1)" || { PS_WHY="typing into Sesame was refused: $out"; return 1; }
  pn_wait_list 20 || return 4
  PS_ROWS="$(pn_rows)"
  return 0
}

# panel_rank <file> : the 1-based place of the file's name in PS_ROWS, or none.
panel_rank() {
  local r
  r="$(printf '%s\n' "$PS_ROWS" | awk -F'\t' -v b="${1##*/}" 'NF && index($3, b) { print $1; exit }')"
  printf '%s\n' "${r:-none}"
}

panel_cleanup() {
  pn_close_panel >/dev/null 2>&1
  pn_kit_close
}

# panel_group <letter> : status 0 passed, 1 failed, 3 a person-step, 4 not valid.
panel_group() {
  local g="$1" rows id q f l rank why="" prc=0 new tsv n first top3 gone="" rerun=0 rc
  rows="$(golden_rows "$g")"
  if [ -z "$rows" ]; then echo "no rows for group $g in $GOLDEN_ANSWERS"; return 1; fi
  kit_need_ps || return 1
  # Fail fast: with no index every row would read rank none and the run would print 0 of 10 as if it were a result.
  if ! golden_indexed; then
    echo "NEEDS: no index; run scripts/kit-run.sh prep photos first"
    echo "(the index under golden/photos holds $(golden_done_count) of 40 done photo files; nothing was searched)"
    return 4
  fi
  new="$KIT_TMP/kit-golden-rows.$$"
  : > "$new"
  trap 'panel_cleanup; rm -f "$new"; exit 130' INT TERM HUP
  while IFS=$'\t' read -r id q f l <&3; do
    if [ -n "$gone" ]; then
      rank=none; why="no panel to search: $gone"
    else
      panel_search "$q"; prc=$?
      case $prc in
        0) rank="$(panel_rank "$f")"; why=""; [ "$rank" = none ] && why="not in the list of $(printf '%s\n' "$PS_ROWS" | awk 'NF { n++ } END { print n + 0 }') rows" ;;
        1) rank=none; gone="$PS_WHY"; why="no panel to search: $gone" ;;
        3) panel_cleanup; trap - INT TERM HUP; rm -f "$new"; printf '%s\n' "$PS_WHY"; return 3 ;;
        *) rank=none; rerun=1; why="the list did not settle within 20 s: not valid" ;;
      esac
    fi
    if [ "$rerun" = 1 ] && [ "$prc" = 4 ]; then
      echo "RERUN $id not valid: the list did not settle within 20 s"
    else
      golden_line "$id" "$q" "$f" "$rank" "$why"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$g" "$q" "$f" "$rank" "$l" "$(golden_pass "$rank")" >> "$new"
  done 3<<EOF
$rows
EOF
  panel_cleanup
  trap - INT TERM HUP
  if [ "$rerun" = 1 ]; then rm -f "$new"; return 4; fi
  tsv="$(golden_dir)/golden-panel.tsv"
  golden_write_tsv "$tsv" "$g" "$new"
  golden_save_lines panel "$g" "$(awk -F'\t' '{ print "GOLDEN " $1 " rank " $5 }' "$new")"
  rm -f "$new"
  set -- $(golden_counts "$tsv" "$g")
  n="$1"; first="$2"; top3="$3"
  summary panel "$g" "$n" "$first" "$top3"
  rc=$?
  oddeven_note "$tsv" "$g"
  echo "wrote $tsv"
  return $rc
}

# panel_page_at <rank> : the page the pane shows for the result at that place: Down to it, then the pane's "Page N of M" (N), or
# none. The first result is selected when the list settles.
panel_page_at() {
  local n="$1" i=1 page
  while [ "$i" -lt "$n" ]; do
    pn_ax key down >/dev/null 2>&1 || break
    i=$((i + 1))
  done
  pn_dump
  page="$(pn_pane | awk 'match($0, /Page [0-9]+ of [0-9]+/) { split(substr($0, RSTART, RLENGTH), a, " "); print a[2]; exit }')"
  printf '%s\n' "${page:-none}"
}

# panel_group_c : status 0 passed, 1 failed, 3 a person-step, 4 not valid. Every row of group c through the real panel: the rank is
# the place of the expected file's name, the page the pane's "Page N of M" for that result (the live path, proved only at the
# accept stage: S2.4). With --from the lines come from the file and no panel is used.
panel_group_c() {
  local rows id q f l rank page prc gone="" rerun=0 out=""
  rows="$(golden_rows c)"
  if [ -z "$rows" ]; then echo "no rows for group c in $GOLDEN_ANSWERS"; return 1; fi
  if [ -n "$G_FROM" ]; then
    report_c panel GroupCTests "$(cat "$G_FROM")"
    return $?
  fi
  kit_need_ps || return 1
  # Fail fast, as group b does: with no whole-folder index every row would read rank none and print 0 of 10 as if it were a result.
  if ! golden_indexed_whole; then
    echo "NEEDS: no whole-folder index; run scripts/kit-golden.sh prepare --whole (or scripts/kit-run.sh prep golden) first"
    echo "(a file with a reader under golden/photos or golden-docs is not done in the index; nothing was searched)"
    return 4
  fi
  trap 'panel_cleanup; exit 130' INT TERM HUP
  while IFS=$'\t' read -r id q f l <&3; do
    if [ -n "$gone" ]; then
      rank=none; page=none
    else
      panel_search "$q"; prc=$?
      case $prc in
        0) rank="$(panel_rank "$f")"; page=none
           [ "$rank" = none ] || page="$(panel_page_at "$rank")" ;;
        1) rank=none; page=none; gone="$PS_WHY" ;;
        3) panel_cleanup; trap - INT TERM HUP; printf '%s\n' "$PS_WHY"; return 3 ;;
        *) rank=none; page=none; rerun=1; echo "RERUN $id not valid: the list did not settle within 20 s" ;;
      esac
    fi
    out="$out
GOLDEN $id rank $rank page $page"
  done 3<<EOF
$rows
EOF
  panel_cleanup
  trap - INT TERM HUP
  [ "$rerun" = 0 ] || return 4
  [ -z "$gone" ] || echo "no panel to search: $gone"
  report_c panel GroupCTests "$out"
}

# panel_opens_at <rank> : the second the pane states ("Opens at mm:ss", minutes unbounded) for the result at that place: Down to it, then the
# pane's line; none when the pane states none. The first result is selected when the list settles.
panel_opens_at() {
  local n="$1" i=1 sec
  while [ "$i" -lt "$n" ]; do
    pn_ax key down >/dev/null 2>&1 || break
    i=$((i + 1))
  done
  pn_dump
  sec="$(pn_pane | awk 'match($0, /Opens at [0-9]+:[0-9][0-9]/) { split(substr($0, RSTART + 9, RLENGTH - 9), a, ":"); print a[1] * 60 + a[2]; exit }')"
  printf '%s\n' "${sec:-none}"
}

# panel_group_d : status 0 passed, 1 failed, 3 a person-step, 4 not valid. Every row of group d through the real panel: the rank is the place
# of the expected file's name, the second the pane's "Opens at mm:ss" for that result (the live path, proved only at the accept stage), then
# the videospeech query, whose list also says whether clip-v12.mp4 is above clip-v11.mp4. With --from the lines come from the file.
panel_group_d() {
  local rows id q f l rank sec prc gone="" rerun=0 out="" vsrow r11 r12 v12
  rows="$(golden_rows d)"
  if [ -z "$rows" ]; then echo "no rows for group d in $GOLDEN_ANSWERS"; return 1; fi
  if [ -n "$G_FROM" ]; then
    report_d panel GroupDTests "$(cat "$G_FROM")"
    return $?
  fi
  kit_need_ps || return 1
  if ! golden_indexed_all; then
    echo "NEEDS: no whole index of the golden folders; run scripts/kit-golden.sh prepare --all (or scripts/kit-run.sh prep golden) first"
    echo "(a file with a reader under golden/photos, golden-docs or golden-av is not done in the index; nothing was searched)"
    return 4
  fi
  vsrow="$(golden_videospeech_row)"
  trap 'panel_cleanup; exit 130' INT TERM HUP
  while IFS=$'\t' read -r id q f l <&3; do
    if [ -n "$gone" ]; then
      rank=none; sec=none
    else
      panel_search "$q"; prc=$?
      case $prc in
        0) rank="$(panel_rank "$f")"; sec=none
           [ "$rank" = none ] || sec="$(panel_opens_at "$rank")" ;;
        1) rank=none; sec=none; gone="$PS_WHY" ;;
        3) panel_cleanup; trap - INT TERM HUP; printf '%s\n' "$PS_WHY"; return 3 ;;
        *) rank=none; sec=none; rerun=1; echo "RERUN $id not valid: the list did not settle within 20 s" ;;
      esac
    fi
    out="$out
GOLDEN $id rank $rank second $sec"
  done 3<<EOF
$rows
$vsrow
EOF
  if [ -z "$gone" ]; then
    IFS=$'\t' read -r id q f l <<EOF
$vsrow
EOF
    panel_search "$q"; prc=$?
    if [ $prc = 0 ]; then
      r11="$(panel_rank "video/clip-v11.mp4")"; r12="$(panel_rank "video/clip-v12.mp4")"
      v12=no
      case "$r12" in none) ;; *) if [ "$r11" = none ] || [ "$r12" -lt "$r11" ]; then v12=yes; fi ;; esac
      out="$out
GOLDEN v12 above $v12"
    fi
  fi
  panel_cleanup
  trap - INT TERM HUP
  [ "$rerun" = 0 ] || return 4
  [ -z "$gone" ] || echo "no panel to search: $gone"
  report_d panel GroupDTests "$out"
}

# ---- prepare ----------------------------------------------------------------------------------------

GOLDEN_MARK="$KIT_ROOT/run/golden-index"

bundle_helper_sha() { shasum -a 256 "$KIT_PROJECT/dist/Sesame.app/Contents/MacOS/SesameHelper" 2>/dev/null | awk '{ print $1 }'; }

# golden_indexed : status 0 when the index under home/ holds 40 photo files, all done, under golden/photos.
golden_indexed() {
  local out
  out="$(kq "$KIT_SCRIPTS/kit-index.sh" under golden/photos 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk -F'\t' '
    NF == 3 { total++; if ($3 == "done") done++ }
    END { exit (total == 40 && done == 40) ? 0 : 1 }'
}

# golden_done_count : how many photo files under golden/photos the index holds as done (0 when there is no index).
golden_done_count() {
  kq "$KIT_SCRIPTS/kit-index.sh" under golden/photos 2>/dev/null | awk -F'\t' 'NF == 3 && $3 == "done" { done++ } END { print done + 0 }'
}

# golden_total_files : how many files rows the index holds, whatever they are (0 when there is no index).
golden_total_files() {
  kq "$KIT_SCRIPTS/kit-index.sh" rows 2>/dev/null | awk '$1 == "files" { n = $2 } END { print n + 0 }'
}

# golden_index_only_photos : status 0 when the index holds the 40 golden photos, all done, and no other file.
golden_index_only_photos() {
  golden_indexed && [ "$(golden_total_files)" = 40 ]
}

# index_state : the reading prepare's shortcut uses, read-only (status 0 only for `INDEX GOLDEN PHOTOS ONLY: yes`).
index_state() {
  local done total
  done="$(golden_done_count)"
  total="$(golden_total_files)"
  echo "golden photos done $done of 40"
  echo "index files total $total"
  if golden_index_only_photos; then
    echo "INDEX GOLDEN PHOTOS ONLY: yes"
    return 0
  fi
  echo "INDEX GOLDEN PHOTOS ONLY: no ($done of 40 golden photos done, $total files in the index)"
  return 1
}

index_path() { echo "$KIT_ROOT/home/Library/Application Support/Sesame/index.sqlite"; }

# ---- the whole-folder index of group c (golden/photos and golden-docs) -------------------------------

GOLDEN_MARK_WHOLE="$KIT_ROOT/run/golden-index-whole"

# golden_whole_index : the files rows under golden/photos and golden-docs, `path<TAB>kind<TAB>status` each.
golden_whole_index() {
  kq "$KIT_SCRIPTS/kit-index.sh" under golden/photos 2>/dev/null | awk -F'\t' 'NF == 3'
  kq "$KIT_SCRIPTS/kit-index.sh" under golden-docs 2>/dev/null | awk -F'\t' 'NF == 3'
}

# golden_whole_reading : "<golden files with a reader> <of them done as the key says>" (golden_whole_expect in golden.sh is the
# list from disk, the index is read through kit-index.sh).
golden_whole_reading() {
  {
    golden_whole_expect | awk -F'\t' '{ print "E\t" $1 "\t" $2 }'
    golden_whole_index | awk -F'\t' '{ print "I\t" $1 "\t" $3 }'
  } | awk -F'\t' '
    $1 == "E" { want[$2] = $3; n++ }
    $1 == "I" { i = index($2, "/golden-docs/"); if (!i) i = index($2, "/golden/photos/"); if (i) seen[substr($2, i + 1)] = $3 }
    END { for (r in want) if (seen[r] == want[r]) ok++; printf "%d %d\n", n, ok }'
}

# golden_indexed_whole : status 0 when every file with a reader under golden/photos and golden-docs is in the index as the key
# says (done; the locked and the damaged pdf could_not_read). Files of other roots, such as boundary, do not count.
golden_indexed_whole() {
  set -- $(golden_whole_reading)
  [ "${1:-0}" -gt 0 ] && [ "$1" = "${2:-0}" ]
}

# golden_whole_only : status 0 when the index holds no file but those with a reader under golden/photos and golden-docs.
golden_whole_only() {
  set -- $(golden_whole_reading)
  [ "${1:-0}" -gt 0 ] && [ "$(golden_total_files)" = "$1" ]
}

# index_state_whole : the read-only reading of the whole-folder shortcut (status 0 only when both lines say yes).
index_state_whole() {
  local n ok total rc=0
  set -- $(golden_whole_reading)
  n="${1:-0}"; ok="${2:-0}"
  total="$(golden_total_files)"
  echo "golden files with a reader $n, done as the key says $ok"
  echo "index files total $total"
  if [ "$n" -gt 0 ] && [ "$n" = "$ok" ]; then
    echo "INDEX GOLDEN WHOLE DONE: yes"
  else
    echo "INDEX GOLDEN WHOLE DONE: no ($ok of $n golden files with a reader are done as the key says)"
    rc=1
  fi
  if [ "$n" -gt 0 ] && [ "$total" = "$n" ]; then
    echo "INDEX GOLDEN WHOLE ONLY: yes"
  else
    echo "INDEX GOLDEN WHOLE ONLY: no ($total files in the index, $n golden files with a reader)"
    rc=1
  fi
  return $rc
}

# prepare_whole_run : the index of golden/photos and golden-docs by the current bundle's helper in home/; prints the index path.
# The helper is run again while work is left (kit-launch.sh ends a run when the index is idle: 10 s of stable counts with no file
# pending or partial, or, with work left, 90 s of stable counts); three runs with no file more done end it.
prepare_whole_run() {
  local sha out rc run=0 done_now done_before=-1 stuck=0 total
  recipe_state || return $?
  kit_need_bundle || return 1
  sha="$(bundle_helper_sha)"
  if [ -n "$sha" ] && [ "$(cat "$GOLDEN_MARK_WHOLE" 2>/dev/null)" = "$sha" ] && golden_indexed_whole && golden_whole_only; then
    echo "golden whole-folder index already made by this bundle: every golden file with a reader is done"
    index_path
    return 0
  fi
  if [ ! -x "$KIT_HELPER_EXE" ]; then
    echo "no SesameHelper in the bundle copy $KIT_HELPER_EXE: run scripts/kit-reset.sh after scripts/bundle.sh"
    return 4
  fi
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  if ! helper_has_index_mode; then
    echo "helper has no index mode"
    return 1
  fi
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-docs || return $?
  while [ "$run" -lt 30 ]; do
    run=$((run + 1))
    out="$(kq "$KIT_SCRIPTS/kit-launch.sh" helper index --folders golden/photos golden-docs 2>&1)"; rc=$?
    printf '%s\n' "$out" | tail -n 5
    [ $rc = 0 ] || { echo "the helper did not finish the golden folders (exit $rc, run $run)"; return 1; }
    golden_indexed_whole && break
    set -- $(golden_whole_reading)
    total="${1:-0}"; done_now="${2:-0}"
    if [ "$done_now" -le "$done_before" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    done_before="$done_now"
    if [ "$stuck" -ge 2 ]; then
      echo "the helper made no progress in 3 runs: $done_now of $total golden files with a reader are done"
      return 1
    fi
    echo "run $run left work ($done_now of $total golden files with a reader are done): running the helper again"
  done
  if ! golden_indexed_whole; then
    echo "the helper finished but not every golden file with a reader is done as the key says"
    return 1
  fi
  if ! golden_whole_only; then
    echo "the helper finished but the index holds a file outside golden/photos and golden-docs"
    return 1
  fi
  printf '%s\n' "$sha" > "$GOLDEN_MARK_WHOLE"
  index_path
}

# ---- the whole index of group d (golden/photos, golden-docs and golden-av; plan 5) ---------------------------------

GOLDEN_MARK_ALL="$KIT_ROOT/run/golden-index-all"

# golden_all_index : the files rows under golden/photos, golden-docs and golden-av, `path<TAB>kind<TAB>status` each.
golden_all_index() {
  kq "$KIT_SCRIPTS/kit-index.sh" under golden/photos 2>/dev/null | awk -F'\t' 'NF == 3'
  kq "$KIT_SCRIPTS/kit-index.sh" under golden-docs 2>/dev/null | awk -F'\t' 'NF == 3'
  kq "$KIT_SCRIPTS/kit-index.sh" under golden-av 2>/dev/null | awk -F'\t' 'NF == 3'
}

# golden_all_reading : "<golden files with a reader> <of them done as the key says>" (golden_whole_expect all in golden.sh is the list from
# disk: the locked and the damaged pdf and the two damaged clips are could_not_read, every other file is done).
golden_all_reading() {
  {
    golden_whole_expect all | awk -F'\t' '{ print "E\t" $1 "\t" $2 }'
    golden_all_index | awk -F'\t' '{ print "I\t" $1 "\t" $3 }'
  } | awk -F'\t' '
    $1 == "E" { want[$2] = $3; n++ }
    $1 == "I" { i = index($2, "/golden-docs/"); if (!i) i = index($2, "/golden-av/"); if (!i) i = index($2, "/golden/photos/"); if (i) seen[substr($2, i + 1)] = $3 }
    END { for (r in want) if (seen[r] == want[r]) ok++; printf "%d %d\n", n, ok }'
}

# golden_indexed_all : status 0 when every file with a reader under the three golden folders is in the index as the key says. Files of other
# roots, such as boundary, do not count. It is the gate of panel --group d.
golden_indexed_all() {
  set -- $(golden_all_reading)
  [ "${1:-0}" -gt 0 ] && [ "$1" = "${2:-0}" ]
}

# golden_all_only : status 0 when the index holds no file but those with a reader under the three golden folders.
golden_all_only() {
  set -- $(golden_all_reading)
  [ "${1:-0}" -gt 0 ] && [ "$(golden_total_files)" = "$1" ]
}

# index_state_all : the read-only reading of the whole-index shortcut (status 0 only when both lines say yes).
index_state_all() {
  local n ok total rc=0
  set -- $(golden_all_reading)
  n="${1:-0}"; ok="${2:-0}"
  total="$(golden_total_files)"
  echo "golden files with a reader $n, done as the key says $ok"
  echo "index files total $total"
  if [ "$n" -gt 0 ] && [ "$n" = "$ok" ]; then
    echo "INDEX GOLDEN ALL DONE: yes"
  else
    echo "INDEX GOLDEN ALL DONE: no ($ok of $n golden files with a reader are done as the key says)"
    rc=1
  fi
  if [ "$n" -gt 0 ] && [ "$total" = "$n" ]; then
    echo "INDEX GOLDEN ALL ONLY: yes"
  else
    echo "INDEX GOLDEN ALL ONLY: no ($total files in the index, $n golden files with a reader)"
    rc=1
  fi
  return $rc
}

# prepare_all_run : the index of golden/photos, golden-docs and golden-av by the current bundle's helper in home/; prints the index path.
# Like prepare --whole (its own marker, the helper run again while work is left), with the audio and video clips too: minutes more.
prepare_all_run() {
  local sha out rc run=0 done_now done_before=-1 stuck=0 total
  recipe_state || return $?
  kit_need_bundle || return 1
  sha="$(bundle_helper_sha)"
  if [ -n "$sha" ] && [ "$(cat "$GOLDEN_MARK_ALL" 2>/dev/null)" = "$sha" ] && golden_indexed_all && golden_all_only; then
    echo "golden whole index already made by this bundle: every golden file with a reader is done as the key says"
    index_path
    return 0
  fi
  if [ ! -x "$KIT_HELPER_EXE" ]; then
    echo "no SesameHelper in the bundle copy $KIT_HELPER_EXE: run scripts/kit-reset.sh after scripts/bundle.sh"
    return 4
  fi
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  if ! helper_has_index_mode; then
    echo "helper has no index mode"
    return 1
  fi
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-docs || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-av || return $?
  while [ "$run" -lt 40 ]; do
    run=$((run + 1))
    out="$(kq "$KIT_SCRIPTS/kit-launch.sh" helper index --folders golden/photos golden-docs golden-av 2>&1)"; rc=$?
    printf '%s\n' "$out" | tail -n 5
    [ $rc = 0 ] || { echo "the helper did not finish the golden folders (exit $rc, run $run)"; return 1; }
    golden_indexed_all && break
    set -- $(golden_all_reading)
    total="${1:-0}"; done_now="${2:-0}"
    if [ "$done_now" -le "$done_before" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    done_before="$done_now"
    if [ "$stuck" -ge 2 ]; then
      echo "the helper made no progress in 3 runs: $done_now of $total golden files with a reader are done"
      return 1
    fi
    echo "run $run left work ($done_now of $total golden files with a reader are done): running the helper again"
  done
  if ! golden_indexed_all; then
    echo "the helper finished but not every golden file with a reader is done as the key says"
    return 1
  fi
  if ! golden_all_only; then
    echo "the helper finished but the index holds a file outside golden/photos, golden-docs and golden-av"
    return 1
  fi
  printf '%s\n' "$sha" > "$GOLDEN_MARK_ALL"
  index_path
}

prepare_run() {
  local sha out rc run=0 done_now done_before=-1 stuck=0
  recipe_state || return $?
  kit_need_bundle || return 1
  sha="$(bundle_helper_sha)"
  if [ -n "$sha" ] && [ "$(cat "$GOLDEN_MARK" 2>/dev/null)" = "$sha" ] && golden_index_only_photos; then
    echo "golden index already made by this bundle: 40 photo files done"
    index_path
    return 0
  fi
  if [ ! -x "$KIT_HELPER_EXE" ]; then
    echo "no SesameHelper in the bundle copy $KIT_HELPER_EXE: run scripts/kit-reset.sh after scripts/bundle.sh"
    return 4
  fi
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  if ! helper_has_index_mode; then
    echo "helper has no index mode"
    return 1
  fi
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  while [ "$run" -lt 10 ]; do
    run=$((run + 1))
    out="$(kq "$KIT_SCRIPTS/kit-launch.sh" helper index --folders golden/photos 2>&1)"; rc=$?
    printf '%s\n' "$out" | tail -n 5
    [ $rc = 0 ] || { echo "the helper did not finish the golden photos (exit $rc, run $run)"; return 1; }
    golden_indexed && break
    done_now="$(golden_done_count)"
    if [ "$done_now" -le "$done_before" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    done_before="$done_now"
    if [ "$stuck" -ge 2 ]; then
      echo "the helper made no progress in 2 runs: $done_now of 40 golden photos are done"
      return 1
    fi
    echo "run $run left work ($done_now of 40 golden photos are done): running the helper again"
  done
  if ! golden_index_only_photos; then
    echo "the helper finished but the index does not hold 40 done photo files under golden/photos and no other file"
    return 1
  fi
  printf '%s\n' "$sha" > "$GOLDEN_MARK"
  index_path
}

# ---- main -------------------------------------------------------------------------------------------

run_mode() { # run_mode engine|panel <args...>
  local mode="$1" g rc=0 one
  shift
  parse_opts "$@" || { usage; return 2; }
  for g in $(groups_to_run); do
    if ! golden_built "$g"; then
      echo "not built yet: group $g of the golden evaluation lands in a later plan"
      rc=1
      continue
    fi
    if [ "$g" = c ]; then "${mode}_group_c"; one=$?
    elif [ "$g" = d ]; then "${mode}_group_d"; one=$?
    else "${mode}_group" "$g"; one=$?; fi
    [ $one -gt $rc ] && rc=$one
  done
  return $rc
}

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    engine|panel) run_mode "$mode" "$@" ;;
    prepare)
      case "$#:${1:-}" in
        0:) prepare_run ;;
        1:--whole) prepare_whole_run ;;
        1:--all) prepare_all_run ;;
        *) usage; return 2 ;;
      esac ;;
    index-state)
      case "$#:${1:-}" in
        0:) index_state ;;
        1:--whole) index_state_whole ;;
        1:--all) index_state_all ;;
        *) usage; return 2 ;;
      esac ;;
    merge)
      [ $# -eq 0 ] || { [ $# -eq 2 ] && [ "$1" = --from ] && [ -f "$2" ]; } || { usage; return 2; }
      merge_run "$@" ;;
    extensions) [ $# -eq 0 ] || { usage; return 2; }; extensions_run ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-golden "$@")" main "$@"
exit $?

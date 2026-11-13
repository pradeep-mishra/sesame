#!/bin/bash
# The slice 2 checks of S6 for the first-run setup (feature map S6: S6.1 to S6.4, S6.8, S6.10 and S6.11). Sourced by kit-run.sh
# after common.sh, recipes.sh and checks-s6.sh (whose plumbing it uses: s6_run, s6_dump, s6_wait_window, s6_save,
# s6_why, s6_done, s6_fail, s6_pick, s6_last, s6_wait_whole), never run. Each check prints one
# `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a failure lists every reason, on one line) and uses the exit codes of
# every kit script: 0 for a pass or a needs-a-person, 1 for a fail, 4 for `RERUN <id> not valid: <reason>`. With
# KIT_PLANT=1 (kit-run.sh --plant <id>) each check changes one input of its own comparison and must print
# `CHECK <id> FAIL planted: <what>`.
#
# Starting state. S6.1 to S6.4 and S6.8 start from `kit-run.sh prep setup` (recipe_setup: a fresh state, the home
# folders built, the model coming from the mirror at 500,000 bytes a second, the app started, nothing picked), S6.8 with
# the file trace started before the app. S6.10 runs (ii) to (iv) on the Ready index of the recipe `photos` and (i) last,
# on a fresh setup. S6.11 starts from `kit-run.sh prep minimix --no-start`. Each check makes its own state, so a list
# gives the same verdict per id as a full run.
#
# What the checks read, and where: the setup window and Settings through `kit-ax.sh dump setup|settings` and
# `kit-ax.sh click "<label>"`; the expected counts only from `kit-fixtures.sh expect counts` and `expect listing`, the
# hand-written tables, never the product; the index through `kit-index.sh`; the file trace through `kit-trace.sh`. They
# type no text (the picker takes its path through `kit-ax.sh gotofolder`), post no key of their own and read no
# product source.
#
# What a check cannot tell apart, said where it matters: the accessibility tree of the setup window is read as lines of
# `<role> label="..." desc="..." help="..." value="..." [disabled]`; a folder's row is its tick (an AXCheckBox whose help is the
# folder's full path), and its counts and estimate are the description "<name>, <counts>, <estimate>" without the name
# (scripts/kit-lib/axdump.sh reads them; the dump format is a guess until the accept stage drives it). The Settings sections
# that are not selected are not in the tree, so a step that needs one selects it first (settings_section, recipes.sh).

S6B_PERMS="$KIT_SCRIPTS/kit-perms.sh"
S6B_TR="$KIT_SCRIPTS/kit-trace.sh"
S6B_IX="$KIT_SCRIPTS/kit-index.sh"
S6B_PW="$KIT_SCRIPTS/kit-power.sh"
S6B_FOLDERS="Desktop Documents Downloads Pictures Movies"
S6B_EXTRA="extra"
S6B_TIMES="under a minute|about [0-9]+ min|about [0-9]+ h( [0-9]+ min)?"
S6B_OPENS=""

# ---- the state and the window --------------------------------------------------------------------------

# s6b_state_done <id> <status> <output> : status 0 when the recipe was ready; else the CHECK or RERUN line is printed,
# S6_RC is set and the status is 1.
s6b_state_done() {
  local id="$1" rc="$2" out="$3"
  [ "$rc" = 0 ] && return 0
  case $rc in
    3) echo "CHECK $id NEEDS-A-PERSON $(s6_pick "$out")"; S6_RC=0 ;;
    4) echo "RERUN $id not valid: the starting recipe: $(s6_pick "$out")"; S6_RC=4 ;;
    *) s6_fail "$id" "the starting recipe cannot finish: $(s6_pick "$out")"; S6_RC=1 ;;
  esac
  return 1
}

# s6b_state <id> : the recipe setup (a fresh state, nothing picked, nothing pressed).
s6b_state() {
  local out rc
  out="$(recipe_setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  s6b_state_done "$1" "$rc" "$out"
}

# s6b_window <id> : status 0 once the setup window answers (S6_DUMP holds its tree); else the CHECK line, S6_RC, status 1.
s6b_window() {
  local rc
  s6_wait_window 10; rc=$?
  case $rc in
    0) return 0 ;;
    3) echo "CHECK $1 NEEDS-A-PERSON $S6_ERR"; S6_RC=0 ;;
    *) s6_fail "$1" "no setup window: $S6_ERR"; S6_RC=1 ;;
  esac
  return 1
}

# s6b_folders_step : status 0 once the dump holds "Add folder…" (the Folders step), pressing Next up to three times.
s6b_folders_step() {
  local i rc
  for i in 1 2 3 4; do
    s6_dump; rc=$?
    [ $rc = 0 ] || return $rc
    s6_has "Add folder…" && return 0
    kq "$S6_AX" click "Next" >/dev/null 2>&1 || return 1
    sleep 1
  done
  return 1
}

s6b_forward() {
  local b="Next"
  s6_dump >/dev/null
  printf '%s\n' "$S6_DUMP" | ax_has_label "Next" || b="Not now"
  s6_press "$S6_AX" "$b"
}

# s6b_at_folders <id> : the setup window is up and on the Folders step; else the CHECK line, S6_RC, status 1.
s6b_at_folders() {
  local rc
  s6b_window "$1" || return 1
  s6b_folders_step; rc=$?
  case $rc in
    0) return 0 ;;
    3) echo "CHECK $1 NEEDS-A-PERSON $S6_ERR"; S6_RC=0 ;;
    *) s6_fail "$1" "the Folders step cannot be reached: no \"Add folder…\" within three presses of Next"; S6_RC=1 ;;
  esac
  return 1
}

# s6b_settings : status 0 once the Settings window answers (S6_DUMP holds its tree), 3 a person-step, 1 never.
s6b_settings() {
  local out rc i
  for i in 1 2 3 4 5 6 7 8; do
    out="$(KIT_NO_EVIDENCE=1 kit_timeout "$S6_DUMP_LIMIT" "$S6_AX" dump settings 2>&1)"; rc=$?
    if [ $rc = 0 ]; then S6_DUMP="$out"; return 0; fi
    if [ $rc = 3 ]; then S6_ERR="$(s6_pick "$out")"; return 3; fi
    sleep 1
  done
  S6_ERR="kit-ax.sh dump settings said \"$(s6_last "$out")\""
  return 1
}

# s6b_menu_ready <seconds> : status 0 once the status item reads Ready.
s6b_menu_ready() {
  local end=$((SECONDS + $1)) out
  while :; do
    out="$(kq "$S6_AX" read menubar 2>&1)"
    case "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" in *ready*) return 0 ;; esac
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 2
  done
}

# s6b_pick <absolute folder> : the folder through the picker (kit-ax.sh gotofolder). Status 0 listed; 2 the window grew
# by more than the one folder; 3 the picker cannot be driven (S6_PERSON says what to do by hand).
s6b_pick() {
  local rc
  drive_picker "$1"; rc=$?
  [ $rc = 0 ] && return 0
  if [ $rc = 2 ]; then s6_why "the picker added more folders than the one asked for ($PICKER_WHY)"; return 2; fi
  S6_PERSON="the folder picker could not be driven ($PICKER_WHY): pick $1 with \"Add folder…\" and run this check again"
  return 3
}

# ---- reading a folder's row ----------------------------------------------------------------------------

# s6b_block <folder name or path> : the lines of S6_DUMP of the folder's row (its tick, whose help is the folder's full path),
# and what is under it in the tree (a Settings row's Re-index and Remove), up to the next row. Nothing when the window
# lists no such folder; the code folders listed apart are not folders of the list.
s6b_block() {
  printf '%s\n' "$S6_DUMP" | ax_row_block "$1"
}

# s6b_detail <folder name or path> : what the row of that folder says after its name ("5 photos, about 1 min"); nothing when none.
s6b_detail() {
  printf '%s\n' "$S6_DUMP" | ax_row_detail "$1"
}

# s6b_shown <block> : "<kind> <count>" for the kinds the block names ("3 photos", "1 PDF", "2 documents", "2 audio files",
# "4 videos"); the largest figure per kind when a line and its child both say it; a kind that is not named is not printed.
s6b_shown() {
  printf '%s\n' "$1" | tr 'A-Z' 'a-z' | awk '
    function add(k, re,   s, t, n) {
      s = $0
      while (match(s, re)) {
        t = substr(s, RSTART, RLENGTH); n = t; sub(/[^0-9,].*/, "", n); gsub(/,/, "", n)
        if (n + 0 > c[k] + 0) c[k] = n + 0
        s = substr(s, RSTART + RLENGTH)
      }
    }
    {
      add("photo", "[0-9][0-9,]* (photos?|pictures?|images?)")
      add("pdf", "[0-9][0-9,]* pdfs?")
      add("document", "[0-9][0-9,]* (documents?|docs?)")
      add("audio", "[0-9][0-9,]* audio( files?)?")
      add("video", "[0-9][0-9,]* videos?")
    }
    END { split("photo document audio video pdf", o, " "); for (i = 1; i <= 5; i++) if (c[o[i]] > 0) print o[i], c[o[i]] }'
}

# s6b_expected <absolute folder> [<added to the photo count>] : "<kind> <count>" from `kit-fixtures.sh expect counts`, the
# hand-written extension table (never the product's number). The code kind is not a setup count.
s6b_expected() {
  local keyed
  keyed="$(awk -F'\t' -v f="${1##*/}" '$1 == f { print $2, $3 }' "$KIT_LIB/key-named-files.tsv" 2>/dev/null)"
  kq "$S6_FX" expect counts "$1" 2>/dev/null | awk -v s="${2:-0}" -v keyed="$keyed" '
    BEGIN { n = split(keyed, l, "\n"); for (i = 1; i <= n; i++) { split(l[i], p, " "); if (p[1] != "") k[p[1]] = p[2] } }
    $1 ~ /^(photo|document|audio|video|pdf)$/ && NF == 2 { n = $2 - k[$1]; if ($1 == "photo") n += s; if (n > 0) print $1, n }'
}

# s6b_total <"<kind> <count>" lines> : the files they add up to.
s6b_total() { printf '%s\n' "$1" | awk 'NF == 2 { n += $2 } END { print n + 0 }'; }

# s6b_compare <label> <expected lines> <shown lines> : nothing when equal, else one line naming each difference.
s6b_compare() {
  {
    printf '%s\n' "$2" | awk 'NF { print "E", $0 }'
    printf '%s\n' "$3" | awk 'NF { print "S", $0 }'
  } | awk -v label="$1" '
    $1 == "E" { w[$2] = $3 }
    $1 == "S" { g[$2] = $3 }
    END {
      for (k in w) if (g[k] + 0 != w[k] + 0) bad = bad (bad == "" ? "" : ", ") k " shows " g[k] + 0 ", expected " w[k]
      for (k in g) if (!(k in w) && g[k] + 0 != 0) bad = bad (bad == "" ? "" : ", ") k " shows " g[k] ", expected 0"
      if (bad != "") print label ": " bad
    }'
}

# s6b_ticked <block> : status 0 when the first line of the block, the row's own tick, is on.
s6b_ticked() {
  printf '%s\n' "$1" | awk 'NR == 1 && /AXCheckBox/ && /value="(1|true|on)"/ { f = 1 } END { exit f ? 0 : 1 }'
}

# s6b_waiting_in <text> : status 0 when the text says the folder waits for Start indexing (the Settings row of a folder that is
# ticked but not yet read: "4 photos, Waiting for Start indexing" in place of an estimate).
s6b_waiting_in() {
  case "$1" in *"Waiting for Start indexing"*) return 0 ;; esac
  return 1
}

# s6b_time_in <text> : status 0 when the text holds an estimate: "after the model download", a time in numbers, or "nothing to
# read" (the product's words for a folder with no photo in it: this build reads photos only, so a folder of audio or video has
# no time to spend).
s6b_time_in() {
  printf '%s\n' "$1" | tr 'A-Z' 'a-z' | awk -v re="after the model download|nothing to read|$S6B_TIMES" '$0 ~ re { f = 1 } END { exit f ? 0 : 1 }'
}

# s6b_time_number <text> : status 0 when the text holds a time in numbers ("under a minute", "about N min", "about H h M min").
s6b_time_number() {
  printf '%s\n' "$1" | tr 'A-Z' 'a-z' | awk -v re="$S6B_TIMES" '$0 ~ re { f = 1 } END { exit f ? 0 : 1 }'
}

# s6b_total_shown : the last "N files" figure of S6_DUMP (the summary under the list); nothing when there is none.
s6b_total_shown() {
  printf '%s\n' "$S6_DUMP" | tr 'A-Z' 'a-z' | awk '
    match($0, /[0-9][0-9,]* files?/) { s = substr($0, RSTART, RLENGTH); sub(/[^0-9,].*/, "", s); gsub(/,/, "", s); n = s }
    END { if (n != "") print n }'
}

# s6b_tick_label <block> : the label of the first tick box of the block.
s6b_tick_label() {
  printf '%s\n' "$1" | awk '/AXCheckBox/ && /label="/ { i = index($0, "label=\""); s = substr($0, i + 7); j = index(s, "\""); print substr(s, 1, j - 1); exit }'
}

# s6b_row_counts <id> <label> <folder name> <absolute folder> [<added to the photo count>] : the row of that folder in S6_DUMP
# shows the counts of `kit-fixtures.sh expect counts` and an estimate; each difference goes to S6_WHY. The counts are read from
# what the row says after the folder's name ("Desktop, 5 photos, about 1 min" -> "5 photos, about 1 min"), so the digits of a name
# are never a count.
s6b_row_counts() {
  local block exp shown diff detail
  block="$(s6b_block "$3")"
  if [ -z "$block" ]; then s6_why "$2: the window lists no row for $3"; return 1; fi
  detail="$(s6b_detail "$3")"
  exp="$(s6b_expected "$4" "${5:-0}")"
  if [ -z "$exp" ]; then s6_why "$2: kit-fixtures.sh expect counts printed no counts for $4"; return 1; fi
  shown="$(s6b_shown "$detail")"
  diff="$(s6b_compare "$2 $3" "$exp" "$shown")"
  [ -z "$diff" ] || s6_why "$diff"
  s6b_time_in "$detail" || s6_why "$2: $3 shows no time estimate"
  echo "  | $2 $3: expected $(printf '%s' "$exp" | tr '\n' ',') shown $(printf '%s' "$shown" | tr '\n' ',')"
  return 0
}

# s6b_counting <folder name>... : status 0 when the row of one of them still says it is counting.
s6b_counting() {
  local f
  for f in "$@"; do
    case "$(s6b_detail "$f")" in counting*) return 0 ;; esac
  done
  return 1
}

# ---- S6.1: four steps, Next and Back, Finish, no setup again --------------------------------------------

# s6b_pending_row <folder name> : the status item's "Settings…", the Folders section, and the row of that folder ticked and
# waiting for Start indexing ("Waiting for Start indexing" in place of an estimate) within 30 s. Finish without Start keeps the
# picked folders as pending ticks. Reasons go to S6_WHY; status 0 found, 1 not, 3 a person-step (S6_ERR says which).
s6b_pending_row() {
  local rc end=$((SECONDS + 30)) detail="" row=""
  s6_press "$S6_AX" "Settings…" || { s6_why "pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings; rc=$?
  if [ $rc = 3 ]; then return 3; fi
  if [ $rc != 0 ]; then s6_why "Settings did not open: $S6_ERR"; return 1; fi
  settings_section Folders >/dev/null || { s6_why "the Settings window cannot be put on its Folders section"; return 1; }
  while :; do
    s6b_settings >/dev/null
    row="$(printf '%s\n' "$S6_DUMP" | ax_row "$1")"
    detail="$(printf '%s\n' "$S6_DUMP" | ax_row_detail "$1")"
    if [ -n "$row" ] && [ "$(printf '%s' "$row" | cut -f3)" = on ] && s6b_waiting_in "$detail"; then
      echo "  | Settings lists $1 ticked: \"$detail\""
      return 0
    fi
    [ "$SECONDS" -ge "$end" ] && break
    sleep 2
  done
  s6_why "Settings does not list $1 as a ticked folder that says \"Waiting for Start indexing\" within 30 s of the relaunch (its row: ${row:-none}, it says \"$detail\")"
  return 1
}

s6_check_1() {
  local steps="Welcome Folders Permissions Shortcut" step i=0 rc prev="" out picked="" want
  [ -n "$KIT_PLANT" ] && { steps="Wellcome Folders Permissions Shortcut"; S6_PLANTED="the first step expected under the name Wellcome"; }
  s6b_state S6.1 || return $S6_RC
  s6b_window S6.1 || return $S6_RC
  for step in $steps; do
    s6_dump; rc=$?
    if [ $rc = 3 ]; then echo "CHECK S6.1 NEEDS-A-PERSON $S6_ERR"; return 0; fi
    if [ $rc != 0 ]; then s6_why "step $((i + 1)), $step: no setup window ($S6_ERR)"; break; fi
    s6_save "s6-1-$step"
    printf '%s\n' "$S6_DUMP" | ax_has_label "Step $((i + 1)) of 4: $step" || s6_why "step $((i + 1)) of 4 does not show the header \"Step $((i + 1)) of 4: $step\" (the step names Welcome, Folders, Permissions, Shortcut are drawn there)"
    [ "$i" = 0 ] || s6_has "Back" || s6_why "step $step offers no Back"
    if [ "$i" = 1 ]; then
      # a pick on the Folders step: Finish without Start must keep it as a pending tick
      out="$(pick_folders extra 2>&1)"; rc=$?
      printf '%s\n' "$out" | sed 's/^/  | /'
      case $rc in
        0) picked=extra ;;
        3) S6_PERSON="$(s6_pick "$out")" ;;
        4) echo "RERUN S6.1 not valid: the picker: $(s6_last "$out")"; return 4 ;;
        *) s6_why "pick_folders extra exited $rc: $(s6_last "$out")" ;;
      esac
    fi
    [ "$i" = 0 ] || [ "$S6_DUMP" != "$prev" ] || s6_why "Next did not move on: the window after Next reads the same as before it"
    prev="$S6_DUMP"
    if [ "$i" -lt 3 ]; then
      s6b_forward || { s6_why "pressing \"Next\" (or \"Not now\" on Folders with a whole model) on $step failed"; break; }
      sleep 1
    fi
    i=$((i + 1))
  done
  if [ "$i" = 4 ]; then
    s6_has "Finish" || s6_why "the last step, Shortcut, offers no Finish"
    # Back and Next move between steps
    kq "$S6_AX" click "Back" >/dev/null 2>&1 || s6_why "pressing \"Back\" on Shortcut failed"
    sleep 1
    s6_dump
    printf '%s\n' "$S6_DUMP" | ax_has_label "Step 3 of 4: Permissions" || s6_why "Back from Shortcut does not show the step \"Step 3 of 4: Permissions\""
    kq "$S6_AX" click "Next" >/dev/null 2>&1 || s6_why "pressing \"Next\" on Permissions failed"
    sleep 1
    s6_dump
    s6_has "Finish" || s6_why "Next from Permissions does not show Shortcut with Finish"
    # Finish without Start indexing: no setup window now, none after a relaunch, and the pick still ticked in Settings
    kq "$S6_AX" click "Finish" >/dev/null 2>&1 || s6_why "pressing \"Finish\" failed"
    sleep 2
    if s6_dump; then s6_why "the setup window is still shown after Finish"; fi
    kq "$S6_LD" quit >/dev/null 2>&1
    out="$(kq "$S6_LD" relaunch 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc != 0 ]; then
      s6_why "kit-launch.sh relaunch exited $rc: $(s6_last "$out")"
    else
      sleep 8
      for i in 1 2 3 4 5; do
        if s6_dump; then s6_save s6-1-after-relaunch; s6_why "the setup is shown again after Finish and a relaunch (no setup after Finish, Start or not)"; break; fi
        sleep 2
      done
      kit_need_ps >/dev/null && [ -n "$(kit_pid_of app)" ] || s6_why "the app is not running after the relaunch, so a missing setup window proves nothing"
      # the folders picked in the setup are pending ticks: Settings lists the pick ticked, waiting for Start indexing
      want="${picked:-Desktop}"
      s6b_pending_row "$want"; rc=$?
      if [ $rc = 3 ]; then echo "CHECK S6.1 NEEDS-A-PERSON $S6_ERR"; return 0; fi
    fi
  fi
  s6_done S6.1 "the setup showed the steps Welcome, Folders, Permissions and Shortcut as \"Step n of 4: <name>\" in order, Next and Back moved between them, the last step offered Finish, and after Finish (Start indexing not pressed) and a relaunch no setup window was shown while Settings listed ${picked:-Desktop} ticked and waiting for Start indexing"
}
check_S6_1() { s6_run s6_check_1; }

# ---- S6.2: the five folders with their counts and a time ------------------------------------------------

s6_check_2() {
  local f
  [ -n "$KIT_PLANT" ] && { S6_SKEW=1; S6_PLANTED="the expected photo count of Desktop read as one more than expect counts says"; }
  s6b_state S6.2 || return $S6_RC
  s6b_at_folders S6.2 || return $S6_RC
  s6_save s6-2-folders
  for f in $S6B_FOLDERS; do
    s6b_row_counts S6.2 "folder" "$f" "$KIT_ROOT/home/$f" "$( [ "$f" = Desktop ] && echo "$S6_SKEW" || echo 0 )"
    s6b_ticked "$(s6b_block "$f")" || s6_why "$f is not ticked (no tick box that is on in its row)"
  done
  s6_done S6.2 "the Folders step lists Desktop, Documents, Downloads, Pictures and Movies, each ticked, each with a time estimate, and the shown counts of photos, PDFs, documents, audio files and videos equal kit-fixtures.sh expect counts for every folder"
}
check_S6_2() { s6_run s6_check_2; }

# ---- S6.3: the overlap counts once, the .gitignore does not hide files ----------------------------------

s6_check_3() {
  local f base=0 work repo shown n sum
  [ -n "$KIT_PLANT" ] && { S6_SKEW=1; S6_PLANTED="the expected unique total read as one more than the hand-written tables add up to"; }
  s6b_state S6.3 || return $S6_RC
  s6b_at_folders S6.3 || return $S6_RC
  for f in $S6B_FOLDERS; do
    n="$(s6b_total "$(s6b_expected "$KIT_ROOT/home/$f")")"
    base=$((base + n))
  done
  work="$(s6b_total "$(s6b_expected "$KIT_ROOT/home/Documents/Work")")"
  repo="$(s6b_total "$(s6b_expected "$KIT_ROOT/home/Developer/atlas-notes")")"
  base=$((base + S6_SKEW))
  sum=$((base + work))
  echo "  | hand-written tables: five folders $base files (Documents holds Work), Documents/Work $work, Developer/atlas-notes $repo"
  # (i) the overlap: Documents/Work picked as well as Documents; the summary counts each file once
  s6b_pick "$KIT_ROOT/home/Documents/Work"
  if [ -z "$S6_PERSON" ]; then
    s6_dump
    s6_save s6-3-overlap
    shown="$(s6b_total_shown)"
    if [ -z "$shown" ]; then
      s6_why "(i) the summary shows no total file count (no \"N files\")"
    elif [ "$shown" = "$sum" ] && [ "$work" -gt 0 ]; then
      s6_why "(i) the summary counts the overlap twice: it shows $shown files, the sum of the folders; the unique total is $base"
    elif [ "$shown" != "$base" ]; then
      s6_why "(i) the summary shows $shown files, the expected unique total is $base (the sum would be $sum)"
    else
      echo "  | (i) the summary shows $shown files: the unique total, not the sum $sum"
    fi
  fi
  # (ii) a repo whose .gitignore excludes supported files is counted whole
  if [ -z "$S6_PERSON" ]; then
    s6b_pick "$KIT_ROOT/home/Developer"
  fi
  if [ -z "$S6_PERSON" ]; then
    s6_dump
    s6_save s6-3-repo
    if [ -n "$(s6b_block atlas-notes)" ]; then
      s6b_row_counts S6.3 "(ii) repo" atlas-notes "$KIT_ROOT/home/Developer/atlas-notes"
    else
      s6b_row_counts S6.3 "(ii) repo" Developer "$KIT_ROOT/home/Developer/atlas-notes"
    fi
    shown="$(s6b_total_shown)"
    [ "$shown" = "$((base + repo))" ] || s6_why "(ii) the summary shows ${shown:-no total} files, expected $((base + repo)) with every supported file of the repo counted, ignored or not"
  fi
  s6_done S6.3 "with Documents/Work picked as well as Documents the summary showed the unique total of $base files, not the sum $sum, and the repo Developer/atlas-notes, whose .gitignore excludes supported files, showed the counts of every supported file present; the read-free part (iii) is S6.8's trace"
}
check_S6_3() { s6_run s6_check_3; }

# ---- S6.4: the estimate waits for the model, then speaks in numbers -------------------------------------

# s6b_final_time <folder name> <counted file count> : status 0 when the row's estimate is final: a time in numbers for a folder
# that holds a counted kind (photo, pdf, document, audio, video), "nothing to read" for one that holds none.
# "measuring speed" and "counting" are not final.
s6b_final_time() {
  local est
  est="$(printf '%s\n' "$S6_DUMP" | ax_row_estimate "$1")"
  if [ "${2:-0}" = 0 ]; then [ "$est" = "nothing to read" ]; else s6b_time_number "$est"; fi
}

s6_check_4() {
  local want="after the model download" f est i ok_all rc total p
  [ -n "$KIT_PLANT" ] && { want="after the model downloads"; S6_PLANTED="the exact text expected with an s: \"after the model downloads\""; }
  s6b_state S6.4 || return $S6_RC
  s6b_at_folders S6.4 || return $S6_RC
  # the rows may still be counting when the window opens: read again until none is
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    s6_dump; rc=$?
    if [ $rc = 3 ]; then echo "CHECK S6.4 NEEDS-A-PERSON $S6_ERR"; return 0; fi
    [ $rc = 0 ] && ! s6b_counting $S6B_FOLDERS && break
    sleep 2
  done
  s6_save s6-4-throttled
  for f in $S6B_FOLDERS; do
    if [ -z "$(s6b_block "$f")" ]; then s6_why "the window lists no row for $f"; continue; fi
    est="$(printf '%s\n' "$S6_DUMP" | ax_row_estimate "$f")"
    [ "$est" = "$want" ] || s6_why "$f: the estimate text is \"$est\", not exactly \"$want\" while the model is not whole"
    s6b_time_number "$(s6b_detail "$f")" && s6_why "$f: shows a time in numbers while the model is not whole"
  done
  [ -z "$(s6b_estimate_seconds)" ] || s6_why "the Folders step shows an \"About <time> in total\" line while the model is not whole"
  # the model becomes whole: numbers appear
  kq "$S6_MR" rate max >/dev/null 2>&1
  if ! s6_wait_whole 600 30; then
    s6_why "the model was not downloaded: $S6_DL"
  else
    ok_all=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
      s6_dump; rc=$?
      if [ $rc = 3 ]; then echo "CHECK S6.4 NEEDS-A-PERSON $S6_ERR"; return 0; fi
      if [ $rc = 0 ]; then
        ok_all=1
        for f in $S6B_FOLDERS; do
          p="$(s6b_total "$(s6b_expected "$KIT_ROOT/home/$f")")"
          s6b_final_time "$f" "$p" || ok_all=0
        done
        [ -n "$(s6b_estimate_seconds)" ] || ok_all=0
        [ $ok_all = 1 ] && break
      fi
      sleep 3
    done
    s6_save s6-4-whole
    if [ $ok_all != 1 ]; then
      s6_why "120 s after the model was whole the Folders step does not show every folder's time (\"under a minute\", \"about N min\", \"about H h M min\"; \"nothing to read\" for a folder with no photo) and the line \"About <time> in total\""
    fi
    for f in $S6B_FOLDERS; do
      est="$(printf '%s\n' "$S6_DUMP" | ax_row_estimate "$f")"
      [ "$est" != "$want" ] || s6_why "$f: still reads \"$want\" after the model is whole"
    done
    total="$(s6b_estimate_seconds)"
    [ -n "$total" ] || s6_why "no line \"About <time> in total\" once the model is whole"
    echo "  | once the model is whole: the total line reads $total s"
  fi
  s6_done S6.4 "while the model was not whole every folder's estimate read exactly \"$want\" and showed no number and no total; once the model was whole every folder showed its time (a number, or \"nothing to read\" for a folder with no photo) and the line \"About <time> in total\" was there; that the speeds are not read from a picked folder is S6.8's trace to show"
}
check_S6_4() { s6_run s6_check_4; }

# ---- S6.8: nothing is read until Start indexing ---------------------------------------------------------

s6_check_8() {
  local out rc f d n opens=0 started=1 helper=0 step
  [ -n "$KIT_PLANT" ] && { S6_SKEW=1; S6_PLANTED="the regular files opened under the picked folders read as one more than the trace counted"; }
  # administrator rights, said plainly (the sentence reaches the terminal before the password is asked) and asked once;
  # every later step that needs them tests the session again first, because it can run out during the waits
  admin_session || { echo "CHECK S6.8 NEEDS-A-PERSON administrator rights were not given (kit-perms.sh ask-admin was refused)"; return 0; }
  # the trace is running before the app starts (recipe setup --trace)
  out="$(recipe_setup --trace s6-setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  s6b_state_done S6.8 "$rc" "$out" || return $S6_RC
  s6b_window S6.8 || return $S6_RC
  # every setup step: Welcome, Folders (a pick through the picker), the model, Permissions, Shortcut, Finish
  kq "$S6_AX" click "Next" >/dev/null 2>&1 || s6_why "pressing \"Next\" on Welcome failed"
  sleep 1
  out="$(pick_folders extra 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  case $rc in
    0) ;;
    3) S6_PERSON="$(s6_pick "$out")" ;;
    4) echo "RERUN S6.8 not valid: the picker: $(s6_last "$out")"; return 4 ;;
    *) s6_why "pick_folders extra exited $rc: $(s6_last "$out")" ;;
  esac
  kq "$S6_MR" rate max >/dev/null 2>&1
  if ! s6_wait_whole 600 30; then s6_why "the model was not downloaded: $S6_DL"; fi
  sleep 10      # the counts and the speed measuring run once the model is whole
  for step in Permissions Shortcut; do
    s6b_forward || s6_why "pressing \"Next\" (or \"Not now\" on Folders with a whole model) before $step failed"
    sleep 1
  done
  kq "$S6_AX" click "Finish" >/dev/null 2>&1 || s6_why "pressing \"Finish\" failed"
  echo "  | setup finished at $(date +%s); Start indexing was not pressed; waiting 120 s"
  sleep 120
  admin_session || { echo "CHECK S6.8 NEEDS-A-PERSON administrator rights ran out during the wait and were not given again: the trace s6-setup is still running as administrator; run scripts/kit-perms.sh ask-admin and then scripts/kit-trace.sh stop s6-setup"; return 0; }
  out="$(kq "$S6B_TR" stop s6-setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc = 4 ]; then echo "RERUN S6.8 not valid: the setup trace saw nothing: $(s6_last "$out")"; return 4; fi
  if [ $rc = 3 ]; then echo "CHECK S6.8 NEEDS-A-PERSON $(s6_pick "$out")"; return 0; fi
  # zero opens of regular files by the app and by every helper under every picked folder
  for f in $S6B_FOLDERS extra; do
    d="$KIT_ROOT/home/$f"; [ "$f" = extra ] && d="$KIT_ROOT/fixtures/extra"
    out="$(kq "$S6B_TR" opens s6-setup --under "$d" --by "Sesame*" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc = 4 ]; then echo "RERUN S6.8 not valid: $(s6_last "$out")"; return 4; fi
    n="$(printf '%s\n' "$out" | awk '/^regular files:/ { print $3; exit }')"
    if [ -z "$n" ]; then s6_why "kit-trace.sh opens for $f printed no \`regular files:\` line (exit $rc)"; continue; fi
    opens=$((opens + n))
  done
  opens=$((opens + S6_SKEW))
  [ "$opens" = 0 ] || s6_why "$opens regular-file opens by Sesame or its helpers under the picked folders during the setup and the 120 s after it (directories and stat calls are allowed and counted apart)"
  kq "$S6B_TR" by-process s6-setup 2>&1 | sed 's/^/  | by process: /'
  # the index is empty and Start was never pressed
  out="$(kq "$S6B_IX" rows 2>&1)"
  printf '%s\n' "$out" | sed 's/^/  | /'
  n="$(printf '%s\n' "$out" | awk '$1 == "files" { print $2; exit }')"
  [ "$n" = 0 ] || s6_why "the index holds ${n:-an unreadable number of} files before Start indexing was pressed (kit-index.sh rows)"
  out="$(kq "$S6B_IX" settings 2>&1)"
  printf '%s\n' "$out" | sed 's/^/  | /'
  case "$out" in *'"startPressed" => 1'*|*'"startPressed" => true'*) s6_why "startPressed is true before Start indexing was pressed" ;; esac
  # the positive control: after Start the index helper must be seen reading
  admin_session || { echo "CHECK S6.8 NEEDS-A-PERSON administrator rights ran out and were not given again, so the positive control cannot start its trace (kit-perms.sh ask-admin was refused)"; return 0; }
  out="$(kq "$S6B_TR" start s6-after-start 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc = 3 ]; then echo "CHECK S6.8 NEEDS-A-PERSON $(s6_pick "$out")"; return 0; fi
  if [ $rc != 0 ]; then echo "RERUN S6.8 not valid: the trace s6-after-start did not start: $(s6_last "$out")"; return 4; fi
  # Finish kept the picks as pending ticks; Start indexing lives in the Indexing section of Settings only
  s6_press "$S6_AX" "Settings…" || s6_why "pressing \"Settings…\" in the status item's menu failed"
  sleep 2
  settings_section Indexing || s6_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
  kq "$S6_AX" click "Start indexing" >/dev/null 2>&1 || s6_why "pressing \"Start indexing\" in Settings failed"
  out="$(kq "$S6B_IX" wait started 120 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then started=0; s6_why "no file was read within 120 s of Start indexing (kit-index.sh wait started exited $rc)"; fi
  sleep 5
  admin_session || { echo "CHECK S6.8 NEEDS-A-PERSON administrator rights ran out and were not given again: the trace s6-after-start is still running as administrator; run scripts/kit-perms.sh ask-admin and then scripts/kit-trace.sh stop s6-after-start"; return 0; }
  out="$(kq "$S6B_TR" stop s6-after-start 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  for f in $S6B_FOLDERS extra; do
    d="$KIT_ROOT/home/$f"; [ "$f" = extra ] && d="$KIT_ROOT/fixtures/extra"
    out="$(kq "$S6B_TR" opens s6-after-start --under "$d" --by "SesameHelper" 2>&1)"
    n="$(printf '%s\n' "$out" | awk '/^regular files:/ { print $3; exit }')"
    helper=$((helper + ${n:-0}))
  done
  echo "  | positive control: $helper regular-file opens by SesameHelper under the picked folders after Start indexing"
  if [ "$started" = 1 ] && [ "$helper" -le 0 ]; then
    echo "RERUN S6.8 not valid: the positive control failed: the trace saw no regular-file open by the index helper after Start indexing, so the zero above proves nothing"
    return 4
  fi
  s6_done S6.8 "over the launch, every setup step, a pick through the picker, the model download and 120 s of waiting the trace saw 0 regular-file opens by Sesame or SesameHelper under the picked folders, the index held 0 files and startPressed was not true; the positive control saw $helper opens by the index helper after Start indexing"
}
check_S6_8() { s6_run s6_check_8; }

# ---- S6.10: a folder added with the picker or later is counted, timed, and waits for Start --------------

# s6b_extra_rows : how many files rows are under extra (kit-index.sh reads the folder under KIT_ROOT/fixtures, so `extra`).
s6b_extra_rows() {
  kq "$S6B_IX" under "$S6B_EXTRA" 2>/dev/null | awk '/ files under / { n = $1 } END { print n + 0 }'
}

# s6b_extra_absent <seconds> <what> : the rows of extra stay absent that long, read every 5 s and at the end.
s6b_extra_absent() {
  local end=$((SECONDS + $1)) n
  while :; do
    n="$(s6b_extra_rows)"
    if [ "$n" != 0 ]; then s6_why "$2: $n rows of extra appeared before Start indexing was pressed"; return 1; fi
    [ "$SECONDS" -ge "$end" ] && return 0
    sleep 5
  done
}

# s6b_golden_absent <seconds> <what> : the rows of golden/photos stay absent that long.
s6b_golden_absent() {
  local end=$((SECONDS + $1)) n
  while :; do
    n="$(kq "$S6B_IX" under golden/photos 2>/dev/null | awk '/ files under / { k = $1 } END { print k + 0 }')"
    if [ "$n" != 0 ]; then s6_why "$2: $n rows of golden/photos are back before Start indexing was pressed"; return 1; fi
    [ "$SECONDS" -ge "$end" ] && return 0
    sleep 5
  done
}

# s6b_row_within <seconds> <id> <label> <folder name> <absolute folder> <window: setup|settings> [<skew>] : within that
# long the folder's row shows the counts of expect counts and an estimate (S6_WHY says what is missing otherwise). In Settings
# a folder that is ticked but not yet read says "Waiting for Start indexing" in place of the estimate, and that is accepted
# there. The Settings window is put on its Folders section first (the rows are in no other section).
s6b_row_within() {
  local end=$((SECONDS + $1)) block exp shown rc detail=""
  if [ "$6" = settings ]; then
    settings_section Folders >/dev/null || { s6_why "$3: the Settings window cannot be put on its Folders section"; return 1; }
  fi
  while :; do
    if [ "$6" = settings ]; then s6b_settings; rc=$?; else s6_dump; rc=$?; fi
    if [ $rc = 0 ]; then
      block="$(s6b_block "$4")"
      detail="$(s6b_detail "$4")"
      exp="$(s6b_expected "$5" "${7:-0}")"
      shown="$(s6b_shown "$detail")"
      if [ -n "$block" ] && [ -z "$(s6b_compare "$3" "$exp" "$shown")" ] && { s6b_time_in "$detail" || { [ "$6" = settings ] && s6b_waiting_in "$detail"; }; }; then
        echo "  | $3: $4 shows the counts of expect counts and an estimate (\"$detail\")"
        return 0
      fi
    fi
    [ "$SECONDS" -ge "$end" ] && break
    sleep 1
  done
  s6_why "$3: within $1 s the row of $4 does not show the counts $(printf '%s' "$exp" | tr '\n' ',') and an estimate (shown: $(printf '%s' "$shown" | tr '\n' ',') $( [ -z "$block" ] && echo "no row"))"
  return 1
}

s6_check_10() {
  local out rc want got label
  [ -n "$KIT_PLANT" ] && { S6_SKEW=1; S6_PLANTED="the expected photo count of extra read as one more than expect counts says"; }
  # (ii) and (iii) and (iv) start from a Ready index of the golden photos, as the recipe photos leaves it
  s1_need_photos S6.10 || return $S1_RC
  kq "$S6_FX" build extra >/dev/null 2>&1 || { s6_why "kit-fixtures.sh build extra failed"; }
  s6b_menu_ready 120 || s6_why "the menu bar never said Ready before (ii): the first index is not Ready"
  s6_press "$S6_AX" "Settings…" || s6_why "(ii) pressing \"Settings…\" in the status item's menu failed"
  s6b_settings; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S6.10 NEEDS-A-PERSON $S6_ERR"; return 0; fi
  [ $rc = 0 ] || s6_why "(ii) Settings did not open: $S6_ERR"
  s6_save s6-10-settings
  # (ii) extra added in Settings: counts and time shown, rows absent for 60 s
  PK_WINDOW=settings drive_picker "$KIT_ROOT/fixtures/extra"; rc=$?
  if [ $rc != 0 ]; then
    S6_PERSON="the folder picker could not be driven ($PICKER_WHY): add $KIT_ROOT/fixtures/extra with \"Add folder…\" in Settings and run this check again"
  else
    s6b_row_within 10 S6.10 "(ii)" extra "$KIT_ROOT/fixtures/extra" settings "$S6_SKEW"
    s6_save s6-10-settings-extra
    s6b_extra_absent 60 "(ii)"
    # (iii) an indexed folder unticked and ticked again: counts and time shown, rows absent for 60 s
    s6b_settings
    label="$(s6b_tick_label "$(s6b_block photos)")"
    if [ -z "$label" ]; then
      s6_why "(iii) no tick box in the Settings row of golden/photos"
    else
      kq "$S6_AX" click "$label" >/dev/null 2>&1 || s6_why "(iii) unticking \"$label\" failed"
      sleep 2
      s6b_settings
      s6b_ticked "$(s6b_block photos)" && s6_why "(iii) golden/photos is still ticked after it was unticked"
      kq "$S6_AX" click "$label" >/dev/null 2>&1 || s6_why "(iii) ticking \"$label\" again failed"
      s6b_row_within 10 S6.10 "(iii)" photos "$KIT_ROOT/fixtures/golden" settings
      s6b_golden_absent 60 "(iii)"
    fi
    s6b_extra_absent 5 "(iii)"
    # (iv) Start indexing reads both: it lives in the Indexing section
    settings_section Indexing || s6_why "(iv) the Settings window cannot be put on its Indexing section"
    kq "$S6_AX" click "Start indexing" >/dev/null 2>&1 || s6_why "(iv) pressing \"Start indexing\" in Settings failed"
    out="$(kq "$S6B_IX" wait done 900 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $rc = 0 ] || s6_why "(iv) the index was not done within 900 s of Start indexing (kit-index.sh wait done exited $rc)"
    want="$(s6b_total "$(s6b_expected "$KIT_ROOT/fixtures/extra")")"
    got="$(s6b_extra_rows)"
    [ "$got" = "$want" ] || s6_why "(iv) $got rows of extra after Start indexing, expected $want from kit-fixtures.sh expect counts"
    want="$(s6b_total "$(s6b_expected "$KIT_ROOT/fixtures/golden")")"
    got="$(kq "$S6B_IX" under golden/photos 2>/dev/null | awk '/ files under / { k = $1 } END { print k + 0 }')"
    [ "$got" = "$want" ] || s6_why "(iv) $got rows of golden/photos after Start indexing, expected $want from kit-fixtures.sh expect counts"
  fi
  # (i) the picker in the first-run setup: extra appears with counts and a time within 10 s
  if [ -z "$S6_PERSON" ]; then
    s6b_state S6.10 || return $S6_RC
    s6b_at_folders S6.10 || return $S6_RC
    drive_picker "$KIT_ROOT/fixtures/extra"; rc=$?
    if [ $rc != 0 ]; then
      S6_PERSON="the folder picker could not be driven ($PICKER_WHY): add $KIT_ROOT/fixtures/extra with \"Add folder…\" in the setup and run this check again"
    else
      s6b_row_within 10 S6.10 "(i)" extra "$KIT_ROOT/fixtures/extra" setup "$S6_SKEW"
      s6_save s6-10-setup-extra
    fi
  fi
  s6_done S6.10 "(i) the picker added fixtures/extra in the setup with its counts and a time within 10 s; (ii) added later in Settings it showed its counts and time and kit-index.sh under extra stayed empty for 60 s; (iii) unticking and ticking an indexed folder showed counts and time with its rows absent for 60 s; (iv) Start indexing then read both"
}
check_S6_10() { s6_run s6_check_10; }

# ---- S6.11: the estimate against the real time, the size per file (the 500-file mix, plan 5) -------

# s6b_need_mix500 <id> : the recipe mix500 --no-start, reused while the app and its setup window of that recipe stand.
s6b_need_mix500() {
  local mark="$KIT_ROOT/run/s6-mix500" out rc
  if [ -f "$mark" ] && kit_need_ps >/dev/null && [ -n "$(kit_pid_of app)" ] && s6_dump; then
    return 0
  fi
  out="$(recipe_mix500 --no-start 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe mix500: /'
  [ $rc = 0 ] && { mkdir -p "$KIT_ROOT/run"; echo ready > "$mark"; }
  s6b_state_done "$1" "$rc" "$out"
}

# s6b_estimate_seconds : the estimate total of the Folders step, in seconds, from the line "About <time> in total" of S6_DUMP
# ("Under a minute in total" counts as 30 s, the middle of what it promises); nothing when there is none. A folder's own
# estimate is never the total.
s6b_estimate_seconds() {
  printf '%s\n' "$S6_DUMP" | ax_total_seconds
}

# s6b_speed_note : the seconds a photo takes, from the note "Photos: about <n> s each" of S6_DUMP; nothing when there is none.
s6b_speed_note() {
  printf '%s\n' "$S6_DUMP" | ax_speed_note
}

s6_check_11() {
  local est start out rc files size hand
  [ -n "$KIT_PLANT" ] && { S6_SKEW=3; S6_PLANTED="the setup's estimate read three times too long"; }
  s6b_need_mix500 S6.11 || return $S6_RC
  s6b_at_folders S6.11 || return $S6_RC
  s6_save s6-11-setup
  est="$(s6b_estimate_seconds)"
  if [ -z "$est" ]; then
    s6_fail S6.11 "the Folders step shows no total (\"About <time> in total\"), so the estimate cannot be compared with the real time"
    return 1
  fi
  [ "$S6_SKEW" = 0 ] || est=$((est * S6_SKEW))
  echo "  | the setup's total estimate: $est s ($(kq "$S6B_PW" get 2>&1 | awk 'NF { l = $0 } END { print l }'))"
  start="$(date +%s)"
  rm -f "$KIT_ROOT/run/s6-mix500"
  out="$(press_start 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s6_fail S6.11 "pressing \"Start indexing\" in the setup window failed: $(printf '%s\n' "$out" | awk 'NR == 1')"; return 1; }
  echo "  | Start indexing pressed at $start"
  out="$(kq "$S6B_IX" wait done 14400 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s6_why "the index was not done within 14400 s (kit-index.sh wait done exited $rc)"
  s6b_menu_ready 120 || s6_why "the menu bar never said Ready after the index was done"
  # the helper exits after its idle minute; the size is read after that
  for rc in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    kit_need_ps >/dev/null && [ -z "$(kit_pid_of index)" ] && break
    sleep 5
  done
  out="$(kq "$S6B_IX" estimate-check "$est" "$start" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  case "$out" in *PASS*) ;; *) s6_why "estimate-check: $(s6_last "$out")" ;; esac
  size="$(kq "$S6B_IX" size 2>&1 | awk '$1 == "size" { print $2 }')"
  files="$(kq "$S6B_IX" rows 2>&1 | awk '$1 == "files" { print $2; exit }')"
  out="$(kq "$S6_FX" expect listing mix500 2>&1)"
  hand="$(printf '%s\n' "$out" | awk '/^LISTING OK/ { for (i = 1; i <= NF; i++) if ($i == "paths") print $(i - 1) }')"
  echo "  | size $size bytes (index.sqlite plus its -wal file), files line $files, hand count $hand"
  if [ -z "$files" ] || [ -z "$hand" ] || [ "$files" != "$hand" ]; then
    s6_why "the files line says ${files:-nothing} and the hand count (kit-fixtures.sh expect listing mix500) says ${hand:-nothing}: a file is missing from the index or a row is extra, so the figure is not used"
  elif [ -z "$size" ] || ! awk -v s="$size" -v f="$files" 'BEGIN { exit (f > 0 && s / f <= 50000) ? 0 : 1 }'; then
    s6_why "the index takes ${size:-an unreadable number of} bytes for $files files: more than 50000 bytes a file"
  fi
  s6_done S6.11 "on the 500-file mix: the setup estimated $est s and kit-index.sh estimate-check passed against the real time to Ready (within 30 percent); index.sqlite plus its -wal file is $size bytes over $files files (the files line, equal to the hand count of $hand), at most 50000 bytes a file"
}
check_S6_11() { s6_run s6_check_11; }

# ---- S6.12, slice 2: Delete index and a rebuilt index download nothing --------------------------------

# s6b_delete_index : Settings, "Delete index…", and its confirmation (a button named like the action, by its label).
s6b_delete_index() {
  s6_press "$S6_AX" "Settings…" || { s6_why "pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings || { s6_why "Settings did not open"; return 1; }
  settings_section Indexing || { s6_why "the Settings window cannot be put on its Indexing section, so Delete index… cannot be pressed"; return 1; }
  kq "$S6_AX" click "Delete index…" >/dev/null 2>&1 || { s6_why "pressing \"Delete index…\" in Settings failed"; return 1; }
  sleep 1
  kq "$S6_AX" click "Delete index" >/dev/null 2>&1 || kq "$S6_AX" click "Delete" >/dev/null 2>&1 || { s6_why "the confirmation of Delete index could not be pressed (no button \"Delete index\" or \"Delete\")"; return 1; }
  sleep 2
  return 0
}

# s6b_rebuild <requests before> <stats before> : the index is built, deleted and rebuilt, the app relaunched; the mirror
# has the same number of requests and the model files the same inode and time as before.
s6b_rebuild() {
  local r0="$1" s0="$2" out rc r s
  kq "$S6_FX" build golden >/dev/null 2>&1 || { s6_why "kit-fixtures.sh build golden failed, so no index could be built"; return 1; }
  out="$(pick_folders golden/photos 2>&1)"; rc=$?
  if [ $rc = 3 ]; then S6_PERSON="$(s6_pick "$out")"; return 3; fi
  [ $rc = 0 ] || { s6_why "pick_folders golden/photos exited $rc: $(s6_last "$out")"; return 1; }
  out="$(press_start 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s6_why "pressing \"Start indexing\" failed: $(printf '%s\n' "$out" | awk 'NR == 1')"; return 1; }
  kq "$S6B_IX" wait done 900 >/dev/null 2>&1 || { s6_why "the first index was not done within 900 s"; return 1; }
  s6b_delete_index || return 1
  settings_section Indexing || { s6_why "the Settings window cannot be put on its Indexing section after Delete index"; return 1; }
  kq "$S6_AX" click "Start indexing" >/dev/null 2>&1 || { s6_why "pressing \"Start indexing\" in Settings after Delete index failed"; return 1; }
  kq "$S6B_IX" wait done 900 >/dev/null 2>&1 || { s6_why "the rebuilt index was not done within 900 s of Start indexing"; return 1; }
  kq "$S6_LD" quit >/dev/null 2>&1
  out="$(kq "$S6_LD" relaunch 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s6_why "relaunch after the rebuilt index exited $rc: $(s6_last "$out")"; return 1; }
  sleep 15
  r="$(s6_reqs)"
  s="$(s6_stats)"
  echo "  | after Delete index, the rebuilt index and a relaunch: $r requests for the two model files"
  [ "$r" = "$((r0 + S6_SKEW))" ] || s6_why "after Delete index and the rebuilt index the mirror has $r requests for the two model files, $r0 before"
  [ "$s" = "$s0" ] || s6_why "after Delete index and the rebuilt index the inode or modified time of a model file changed (before: $(printf '%s' "$s0" | tr '\n' ',')  after: $(printf '%s' "$s" | tr '\n' ','))"
  return 0
}

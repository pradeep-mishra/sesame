#!/bin/bash
# The slice 2 checks of S7 for background indexing (feature map S7: S7.1 to S7.18). Sourced by kit-run.sh after common.sh,
# recipes.sh, checks-s1.sh, checks-s6.sh and checks-s6b.sh (whose plumbing it uses: kq, recipe_*, drive_picker, pn_*,
# s1_panel_facts, s6_pick, s6_last, s6b_settings, s6b_block, s6b_tick_label, s6b_menu_ready, s6b_expected, s6b_total),
# never run. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a failure lists every reason, on one
# line) and uses the exit codes of every kit script: 0 for a pass or a needs-a-person, 1 for a fail, 4 for
# `RERUN <id> not valid: <reason>`. With KIT_PLANT=1 (kit-run.sh --plant <id>) each check changes one input of its own
# comparison and must print `CHECK <id> FAIL planted: <what>`.
#
# Starting state. The checks that need indexing in progress start from `kit-run.sh prep minimix` (400 photos picked
# through the picker, Start pressed) once, then re-arm it through steps a person has: Settings, "Delete index…", its
# confirmation, "Start indexing". The kit never edits settings.json or the index to reach a state (s7_arm). A check
# that changes the folders or the files (S7.6 to S7.9, S7.14, S7.15, S7.18) puts them back with `kit-fixtures.sh
# restore` and drops the mark in $KIT_ROOT/run/s7-minimix, so the next check starts from the recipe again.
#
# What the checks read, and where: the status item's label and menu through `kit-ax.sh read menubar` and `dump menu`;
# the setup, Settings and the panel through `kit-ax.sh dump` and `click "<label>"`; the index through `kit-index.sh`;
# the expected counts and the expected listing only from `kit-fixtures.sh expect counts` and `expect listing`, the
# hand-written tables, never the product; processes through `kit-launch.sh pids`; the load through `kit-load.sh`; Low
# Power Mode through `kit-power.sh`; the login item through `kit-privacy.sh login-item`. They type no text (the search
# is `kit-search.sh`, which types through `kit-ax.sh` and honours KIT_TYPE_DELAY_MS), post no key of their own, edit no
# state and read no product source.
#
# What a check cannot tell apart, said where it matters: this build indexes photos only (plan 2), so a new text file or
# a PDF has no phrase to find and is not looked for (the kinds that the index shows are the kinds that are checked);
# a time read by polling is judged only where it is certainly wrong (the interval the event fell in is printed); the
# menu's wording is read as text (the first number on a line that names a kind is that kind's count).

S7_AX="$KIT_SCRIPTS/kit-ax.sh"
S7_LD="$KIT_SCRIPTS/kit-launch.sh"
S7_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S7_IX="$KIT_SCRIPTS/kit-index.sh"
S7_LOAD="$KIT_SCRIPTS/kit-load.sh"
S7_PW="$KIT_SCRIPTS/kit-power.sh"
S7_VOL="$KIT_SCRIPTS/kit-volume.sh"
S7_PRIV="$KIT_SCRIPTS/kit-privacy.sh"
S7_SEARCH="$KIT_SCRIPTS/kit-search.sh"
S7_PERMS="$KIT_SCRIPTS/kit-perms.sh"
S7_MR="$KIT_SCRIPTS/kit-mirror.sh"
S7_MARK="$KIT_ROOT/run/s7-minimix"
S7_MIX="$KIT_ROOT/fixtures/minimix"
S7_MNT="$KIT_ROOT/run/volume/mnt"
S7_SNAPS="$KIT_ROOT/run/index-snaps"
S7_WHY=""
S7_RC=0
S7_PERSON=""
S7_PLANTED=""
S7_SKEW=0
S7_ERR=""
S7_MENU=""
S7_LABEL=""
S7_OUT=""
S7_USED_POWER=""
S7_USED_VOL=""
S7_MUTATED=""
S7_DIRTY=""
S7_TMPFILES=""
S7_PHRASE=""

# ---- plumbing ---------------------------------------------------------------------------------------

s7_why() { S7_WHY="${S7_WHY:+$S7_WHY; }$1"; }

# s7_fail <id> <reason> : the CHECK FAIL line (a plant says what was planted).
s7_fail() {
  if [ -n "$KIT_PLANT" ]; then echo "CHECK $1 FAIL planted: $S7_PLANTED: $2"; else echo "CHECK $1 FAIL $2"; fi
}

# s7_done <id> <pass text> : the verdict. A person-step found on the way, else FAIL with every reason, else PASS.
s7_done() {
  if [ -n "$S7_PERSON" ]; then echo "CHECK $1 NEEDS-A-PERSON $S7_PERSON"; return 0; fi
  if [ -n "$S7_WHY" ]; then s7_fail "$1" "$S7_WHY"; return 1; fi
  echo "CHECK $1 PASS $2"
  return 0
}

# s7_cleanup : the load stopped, the mirror online, Low Power Mode and the volume put back, mutated files restored.
s7_cleanup() {
  local out
  kq "$S7_LOAD" stop >/dev/null 2>&1
  kq "$S7_MR" online >/dev/null 2>&1
  # what kit-power.sh restore says is shown, never thrown away: a restore that failed leaves Low Power Mode on, and its
  # NEEDS A PERSON line gives the command to run
  if [ -n "$S7_USED_POWER" ]; then
    out="$(kq "$S7_PW" restore 2>&1)"
    printf '%s\n' "$out" | sed 's/^/  | /'
  fi
  [ -z "$S7_USED_VOL" ] || kq "$S7_VOL" destroy >/dev/null 2>&1
  [ -z "$S7_MUTATED" ] || kq "$S7_FX" restore >/dev/null 2>&1
  [ -z "$S7_TMPFILES" ] || rm -f $S7_TMPFILES
  [ -z "$S7_MUTATED$S7_DIRTY" ] || rm -f "$S7_MARK"
  s1_cleanup
  return 0
}

# s7_run <function> : the check body with its variables reset, everything it changed put back on every path.
s7_run() {
  local rc
  S7_WHY=""; S7_RC=0; S7_PERSON=""; S7_PLANTED=""; S7_SKEW=0; S7_ERR=""; S7_USED_POWER=""; S7_USED_VOL=""
  S7_MUTATED=""; S7_DIRTY=""; S7_TMPFILES=""
  trap 's7_cleanup; exit 130' INT TERM HUP
  "$@"; rc=$?
  s7_cleanup
  trap 's1_cleanup; exit 130' INT TERM HUP
  return $rc
}

# s7_battery_note : the battery rule and "Resume anyway, on battery" need a laptop on battery: said, never passed.
s7_battery_note() {
  echo "NEEDS A PERSON: the battery rule, its resume and \"Resume anyway, on battery\" need a laptop on battery; they are not run and not counted as proven (S7.N1)"
}

# s7_save <name> <text> : the text in the evidence folder as <name>.txt (never over an older one).
s7_save() {
  local dir f n=1
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/$1.txt"
  while [ -e "$f" ]; do n=$((n + 1)); f="$dir/$1-$n.txt"; done
  printf '%s\n' "$2" > "$f" 2>/dev/null && echo "  | saved $f"
}

# s7_epoch <output> : the epoch a kit script printed (a line that is only digits), else now.
s7_epoch() {
  local e
  e="$(printf '%s\n' "$1" | awk '/^[0-9]+$/ { e = $1 } END { print e }')"
  [ -n "$e" ] && printf '%s' "$e" || date +%s
}

# ---- the starting state -----------------------------------------------------------------------------

# s7_recipe_done <id> <status> <output> : status 0 when the recipe was ready; else the CHECK or RERUN line is printed,
# S7_RC is set and the status is 1.
s7_recipe_done() {
  local id="$1" rc="$2" out="$3"
  [ "$rc" = 0 ] && return 0
  case $rc in
    3) echo "CHECK $id NEEDS-A-PERSON $(s6_pick "$out")"; S7_RC=0 ;;
    4) echo "RERUN $id not valid: the starting recipe: $(s6_pick "$out")"; S7_RC=4 ;;
    *) s7_fail "$id" "the starting recipe cannot finish: $(s6_pick "$out")"; S7_RC=1 ;;
  esac
  return 1
}

# s7_delete_index : Settings, "Delete index…", and its confirmation, as a person does it.
s7_delete_index() {
  s6_press "$S7_AX" "Settings…" || { s7_why "pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings || { s7_why "Settings did not open"; return 1; }
  settings_section Indexing || { s7_why "the Settings window cannot be put on its Indexing section, so Delete index… cannot be pressed"; return 1; }
  s6_press "$S7_AX" "Delete index…" || { s7_why "pressing \"Delete index…\" in Settings failed"; return 1; }
  sleep 1
  kq "$S7_AX" click "Delete index" >/dev/null 2>&1 || kq "$S7_AX" click "Delete" >/dev/null 2>&1 || { s7_why "the confirmation of Delete index could not be pressed (no button \"Delete index\" or \"Delete\")"; return 1; }
  sleep 2
  return 0
}

# s7_rearm <id> : indexing in progress again from an empty index, through the steps a person has (Delete index, then
# Start indexing). Status 0 ready; else the CHECK or RERUN line is printed, S7_RC is set and the status is 1.
s7_rearm() {
  local id="$1" out rc
  if ! s7_delete_index; then s7_fail "$id" "re-arming indexing: $S7_WHY"; S7_RC=1; return 1; fi
  if ! settings_section Indexing; then s7_fail "$id" "re-arming indexing: the Settings window cannot be put on its Indexing section"; S7_RC=1; return 1; fi
  if ! s6_press "$S7_AX" "Start indexing"; then s7_fail "$id" "re-arming indexing: pressing \"Start indexing\" in Settings failed"; S7_RC=1; return 1; fi
  out="$(kq "$S7_IX" wait rising 120 2>&1)"; rc=$?
  if [ $rc != 0 ]; then echo "RERUN $id not valid: after Delete index and Start indexing the rows did not rise: $(s6_last "$out")"; S7_RC=4; return 1; fi
  return 0
}

# s7_arm <id> : the mini mix indexing in progress. The recipe `minimix` the first time (the app and its folders stand
# afterwards), the steps of s7_rearm every later time. Status 0 ready; else the CHECK or RERUN line, S7_RC, status 1.
s7_arm() {
  local id="$1" out rc
  if [ -f "$S7_MARK" ] && kit_need_ps >/dev/null && [ -n "$(kit_pid_of app)" ]; then
    s7_rearm "$id"; return $?
  fi
  rm -f "$S7_MARK"
  out="$(recipe_minimix 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe minimix: /'
  s7_recipe_done "$id" "$rc" "$out" || return 1
  mkdir -p "$KIT_ROOT/run" && echo ready > "$S7_MARK"
  return 0
}

# ---- the status item and its menu -------------------------------------------------------------------

# s7_label : the status item's accessibility label (`kit-ax.sh read menubar`); "ERROR: ..." when it cannot be read.
s7_label() {
  local out label
  out="$(KIT_NO_EVIDENCE=1 kit_timeout 20 "$S7_AX" read menubar 2>&1)"
  label="$(printf '%s\n' "$out" | sed -n 's/^status item: *//p' | head -1)"
  if printf '%s\n' "$out" | awk '/^status item:/ { f = 1 } END { exit f ? 0 : 1 }'; then printf '%s' "$label"; else printf 'ERROR: %s' "$(s6_last "$out")"; fi
}

# s7_state_of <label> : empty, downloading, paused, indexing, ready or other.
s7_state_of() {
  local l
  l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$l" in
    "") echo empty ;;
    error:*) echo other ;;
    *download*) echo downloading ;;
    *paused*) echo paused ;;
    *index*) echo indexing ;;
    *ready*) echo ready ;;
    *) echo other ;;
  esac
}

# s7_wait_state <state> <seconds> : status 0 once the label is in that state (S7_LABEL holds it), else 1.
s7_wait_state() {
  local want="$1" end=$((SECONDS + $2))
  while :; do
    S7_LABEL="$(s7_label)"
    [ "$(s7_state_of "$S7_LABEL")" = "$want" ] && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 1
  done
}

# s7_menu : the open menu's items into S7_MENU (`kit-ax.sh dump menu`). Status 0 read; 3 a person-step; 1 not read.
s7_menu() {
  local out rc
  out="$(KIT_NO_EVIDENCE=1 kit_timeout 30 "$S7_AX" dump menu 2>&1)"; rc=$?
  case $rc in
    0) S7_MENU="$out"; return 0 ;;
    3) S7_MENU=""; S7_ERR="$(s6_pick "$out")"; return 3 ;;
    *) S7_MENU=""; S7_ERR="kit-ax.sh dump menu said \"$(s6_last "$out")\""; return 1 ;;
  esac
}

# s7_item <label> : enabled, disabled or absent, for the menu item with that label in S7_MENU.
s7_item() {
  printf '%s\n' "$S7_MENU" | awk -v want="$1" '
    index($0, "label=\"" want "\"") { f = 1; if (index($0, "[disabled]")) d = 1 }
    END { if (!f) print "absent"; else if (d) print "disabled"; else print "enabled" }'
}

# s7_percent <text> : the first percent in the text ("42%" or "42 percent"); nothing when there is none.
s7_percent() {
  printf '%s\n' "$1" | tr 'A-Z' 'a-z' | awk 'match($0, /[0-9]+ ?(%|percent)/) { s = substr($0, RSTART, RLENGTH); sub(/[^0-9].*/, "", s); print s; exit }'
}

# s7_menu_counts : "<kind> <count>" for the kinds the menu names: the first number on a line that names a kind; a "Last
# indexed" line is never a count.
s7_menu_counts() {
  printf '%s\n' "$S7_MENU" | tr 'A-Z' 'a-z' | awk '
    /last indexed/ { next }
    {
      if (match($0, /photos?|pictures?|images?/)) k = "photo"
      else if (match($0, /pdfs?/)) k = "pdf"
      else if (match($0, /documents?/)) k = "document"
      else if (match($0, /audio/)) k = "audio"
      else if (match($0, /videos?/)) k = "video"
      else next
      if (match($0, /[0-9][0-9,]*/)) { n = substr($0, RSTART, RLENGTH); gsub(/,/, "", n); if (!(k in c)) c[k] = n + 0 }
    }
    END { for (k in c) print k, c[k] }' | sort
}

# s7_last_indexed : the file name after "Last indexed" in S7_MENU; nothing when the menu has none.
s7_last_indexed() {
  printf '%s\n' "$S7_MENU" | awk '
    { i = index(tolower($0), "last indexed"); if (i == 0) next
      rest = substr($0, i + 12); sub(/^[ :\t-]+/, "", rest); sub(/".*$/, "", rest); sub(/[ \t]+$/, "", rest)
      if (rest != "") { print rest; exit } }'
}

# s7_label_ok <id> <state> <mockup label> : the label is not empty, is in the state, and its wording is the mockup's
# (a different wording is noted, never a failure). Status 1 and a reason in S7_WHY when it is not.
s7_label_ok() {
  local id="$1" state="$2" mockup="$3" got
  S7_LABEL="$(s7_label)"
  got="$(s7_state_of "$S7_LABEL")"
  if [ "$got" = empty ]; then s7_why "$state: the status item's accessibility label is empty"; return 1; fi
  if [ "$got" != "$state" ]; then s7_why "$state: the status item's label reads \"$S7_LABEL\", which is not the state $state"; return 1; fi
  case "$(printf '%s' "$S7_LABEL" | tr 'A-Z' 'a-z')" in
    "$mockup"*) echo "  | $state: label \"$S7_LABEL\"" ;;
    *) echo "  | noted: $state: label \"$S7_LABEL\", the mockup says \"$mockup\"" ;;
  esac
  return 0
}

# ---- the index --------------------------------------------------------------------------------------

# s7_done_counts : "<kind> <done files>" from `kit-index.sh status`.
s7_done_counts() {
  kq "$S7_IX" status 2>/dev/null | awk 'NF == 3 && $2 == "done" && $3 ~ /^[0-9]+$/ { c[$1] += $3 } END { for (k in c) print k, c[k] }' | sort
}

# s7_done_total : the done files of every kind.
s7_done_total() { kq "$S7_IX" status 2>/dev/null | awk 'NF == 3 && $2 == "done" && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }'; }

# s7_open_rows : the files still pending or partial.
s7_open_rows() { kq "$S7_IX" status 2>/dev/null | awk 'NF == 3 && ($2 == "pending" || $2 == "partial") && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }'; }

# s7_open_kinds : the kinds that still have pending or partial files, one per line.
s7_open_kinds() { kq "$S7_IX" status 2>/dev/null | awk 'NF == 3 && ($2 == "pending" || $2 == "partial") && $3 ~ /^[0-9]+$/ && $3 > 0 { print $1 }' | sort -u; }

# s7_passages : the `passages` line of `kit-index.sh rows`.
s7_passages() { kq "$S7_IX" rows 2>/dev/null | awk '$1 == "passages" { print $2; exit }'; }

# s7_files_n : the `files` line of `kit-index.sh rows`.
s7_files_n() { kq "$S7_IX" rows 2>/dev/null | awk '$1 == "files" { print $2; exit }'; }

# s7_kind_indexed <kind> : status 0 when the index holds a done file of that kind (a build that indexes the kind).
s7_kind_indexed() { s7_done_counts | awk -v k="$1" '$1 == k { f = 1 } END { exit f ? 0 : 1 }'; }

# s7_rows_under <folder> : the number of `files` rows under the folder.
s7_rows_under() { kq "$S7_IX" under "$1" 2>/dev/null | awk '/ files under / { n = $1 } END { print n + 0 }'; }

# s7_paths_under <folder> <status> : the paths under the folder with that status (nothing for an empty status: all).
s7_paths_under() { kq "$S7_IX" under "$1" 2>/dev/null | awk -F'\t' -v s="$2" 'NF == 3 && (s == "" || $3 == s) { print $1 }'; }

# s7_has <path> : status 0 when the index holds the path.
s7_has() { kq "$S7_IX" has "$1" >/dev/null 2>&1; }

# s7_wait_has <path> present|absent <seconds> : status 0 once the index shows that; S7_SKEW is not used here.
s7_wait_has() {
  local end=$((SECONDS + $3))
  while :; do
    if s7_has "$1"; then [ "$2" = present ] && return 0; else [ "$2" = absent ] && return 0; fi
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.25
  done
}

# s7_total_expected <folder> : the files known for the folder from `kit-fixtures.sh expect counts`, the hand-written table.
s7_total_expected() { s6b_total "$(s6b_expected "$1")"; }

# s7_sig : the done count and the passages together, the pair a pause must hold still.
s7_sig() { printf '%s %s' "$(s7_done_total)" "$(s7_passages)"; }

# Snapshots are always the per-file-state kind (`snapshot <name> --files-only`), never the full-row one: a file that was
# read again may legitimately change its row ids and vectors.

s7_check_no_last() {
  local what="$1" last
  last="$(s7_last_indexed)"
  if [ -z "$last" ] && printf '%s\n' "$S7_MENU" | grep -qi 'last indexed'; then last="no file name"; fi
  [ -z "$last" ] || { s7_why "$what: the menu has a \"Last indexed\" line ($last); the person removed it because a long file name widens the menu (guide 19)"; return 1; }
  return 0
}

# s7_lost_done <diff output> : the done files a diff says changed or went missing.
s7_lost_done() { printf '%s\n' "$1" | awk -F'\t' '/^- / && $2 == "done" { n++ } END { print n + 0 }'; }

# s7_ready <seconds> : indexing is done and the menu says Ready.
s7_ready() {
  local out rc
  out="$(kq "$S7_IX" wait done "$1" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s7_why "the index was not done within $1 s (kit-index.sh wait done exited $rc)"; return 1; }
  s6b_menu_ready 120 || { s7_why "the menu bar never said Ready after the index was done"; return 1; }
  return 0
}

# s7_in_progress <id> : indexing is running now (rows are open); else a RERUN line and S7_RC 4, status 1.
s7_in_progress() {
  local id="$1"
  if [ "$(s7_open_rows)" -gt 0 ]; then return 0; fi
  echo "RERUN $id not valid: no file is pending or partial, so indexing is not in progress"
  S7_RC=4
  return 1
}

# ---- S7.1: the status item and its menu ------------------------------------------------------------

s7_check_1() {
  local out rc exp shown diff pct total done_n item
  [ -n "$KIT_PLANT" ] && { S7_SKEW=3; S7_PLANTED="the expected done count of every kind read as 3 more than the index says"; }
  rm -f "$S7_MARK"
  # Downloading: the model is throttled and not whole
  out="$(recipe_fresh_throttled 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe fresh-throttled: /'
  s7_recipe_done S7.1 "$rc" "$out" || return $S7_RC
  if s7_wait_state downloading 60; then
    s7_label_ok S7.1 downloading "sesame: downloading"
    s7_menu && printf '%s\n' "$S7_MENU" | sed 's/^/  | downloading menu: /'
    kq "$S7_AX" shot s7-menu-downloading >/dev/null 2>&1
  else
    s7_why "Downloading: the status item's label never named the download within 60 s of the start (it read \"$S7_LABEL\")"
  fi
  # Indexing
  rm -f "$S7_MARK"
  s7_arm S7.1 || return $S7_RC
  if ! s7_wait_state indexing 120; then
    s7_why "Indexing: the status item's label never named indexing (it read \"$S7_LABEL\")"
  else
    s7_label_ok S7.1 indexing "sesame: indexing"
    if s7_menu; then
      kq "$S7_AX" shot s7-menu-indexing >/dev/null 2>&1
      pct="$(s7_percent "$S7_MENU")"
      [ -n "$pct" ] || s7_why "Indexing: the menu's first lines show no percent"
      case "$(printf '%s' "$S7_MENU" | tr 'A-Z' 'a-z')" in *left*) ;; *) s7_why "Indexing: the menu shows no line with files left and time left" ;; esac
      item="$(s7_item "Pause indexing")"
      [ "$item" = enabled ] || s7_why "Indexing: the first action \"Pause indexing\" is $item"
      printf '%s\n' "$S7_MENU" | sed 's/^/  | indexing menu: /'
    else
      s7_why "Indexing: the menu could not be read: $S7_ERR"
    fi
  fi
  # Paused by you: counts are read while paused so they are stable
  s6_press "$S7_AX" "Pause indexing" || s7_why "pressing \"Pause indexing\" failed"
  sleep 6
  s7_label_ok S7.1 paused "sesame: paused"
  if s7_menu; then
    kq "$S7_AX" shot s7-menu-paused >/dev/null 2>&1
    item="$(s7_item "Resume indexing")"
    [ "$item" = enabled ] || s7_why "Paused by you: the first action \"Resume indexing\" is $item"
    exp="$(s7_done_counts | awk -v s="$S7_SKEW" '{ print $1, $2 + s }')"
    shown="$(s7_menu_counts)"
    diff="$(s6b_compare "Paused by you: menu counts against kit-index.sh status" "$exp" "$shown")"
    [ -z "$diff" ] || s7_why "$diff"
    s7_check_no_last "Paused by you"
    total="$(s7_total_expected "$S7_MIX")"
    done_n="$(s7_done_total)"
    pct="$(s7_percent "$S7_MENU")"
    if [ -n "$pct" ] && [ "$total" -gt 0 ]; then
      awk -v p="$pct" -v d="$done_n" -v t="$total" 'BEGIN { x = 100 * d / t; e = (p > x) ? p - x : x - p; exit (e <= 1) ? 0 : 1 }' || s7_why "Paused by you: the menu says $pct percent, files done over files known is $done_n of $total (expect counts), not within 1 point"
    fi
    echo "  | paused menu counts: $(printf '%s' "$shown" | tr '\n' ','); index $(printf '%s' "$exp" | tr '\n' ','); $done_n of $total"
  else
    s7_why "Paused by you: the menu could not be read: $S7_ERR"
  fi
  s6_press "$S7_AX" "Resume indexing" || s7_why "pressing \"Resume indexing\" failed"
  if s7_ready 3600; then
    s7_label_ok S7.1 ready "sesame: ready"
    if s7_menu; then
      kq "$S7_AX" shot s7-menu-ready >/dev/null 2>&1
      item="$(s7_item "Pause indexing")"
      [ "$item" = absent ] || s7_why "Ready: the Pause item is $item, expected no Pause item (the tidy menu draws none when there is nothing to pause)"
      exp="$(s6b_expected "$S7_MIX" "$S7_SKEW")"
      shown="$(s7_menu_counts)"
      diff="$(s6b_compare "Ready: menu counts against kit-fixtures.sh expect counts" "$exp" "$shown")"
      [ -z "$diff" ] || s7_why "$diff"
      s7_check_no_last "Ready"
      pct="$(s7_percent "$S7_MENU")"
      total="$(s7_total_expected "$S7_MIX")"
      if [ -n "$pct" ] && [ "$total" -gt 0 ]; then
        awk -v p="$pct" -v d="$(s7_done_total)" -v t="$total" 'BEGIN { x = 100 * d / t; e = (p > x) ? p - x : x - p; exit (e <= 1) ? 0 : 1 }' || s7_why "Ready: the menu says $pct percent, not within 1 point of files done over the $total files of expect counts"
      fi
      echo "  | ready menu counts: $(printf '%s' "$shown" | tr '\n' ','); expect counts $(printf '%s' "$exp" | tr '\n' ',')"
      # the menu's other route to the panel: an "Open Sesame" item, when the menu has one
      if [ "$(s7_item "Open Sesame")" = absent ]; then
        echo "  | noted: the menu has no \"Open Sesame\" item (the spec does not require one)"
      else
        kq "$S7_AX" click "Open Sesame" >/dev/null 2>&1 || s7_why "pressing \"Open Sesame\" failed"
        sleep 2
        s1_panel_facts
        out="$(s1_open_why)"
        [ -z "$out" ] || s7_why "Open Sesame: $out"
        kq "$S7_AX" dump panel >/dev/null 2>&1
        pn_close_panel >/dev/null 2>&1
      fi
    else
      s7_why "Ready: the menu could not be read: $S7_ERR"
    fi
  fi
  s7_done S7.1 "the status item's label named Downloading, Indexing, Paused by you and Ready and was never empty; the menu led with the state, a percent and a line with files left, its first action was Pause indexing, Resume indexing and no Pause item when Ready; the per-kind counts equalled kit-index.sh status while paused and kit-fixtures.sh expect counts at Ready, the Paused by you and Ready menus had no Last indexed line and the percent was within 1 point of files done over the expect counts total"
}
check_S7_1() { s7_run s7_check_1; }

# ---- S7.2: Pause holds everything still, Resume continues ------------------------------------------

# s7_pause_unit <pdf|audio|video> : the pause measurement of S7.2 on one long unit (the 60-page PDF, the 60-minute audio clip, the 2-minute video),
# the only unit in flight (the recipe pauselong picks that one folder; kit-index.sh status must show exactly one file pending or partial). The
# unit is then let finish, so the next unit starts from its own fresh state. Status 0 (a failed reading is in S7_WHY); 1 with the CHECK or RERUN
# line printed and S7_RC set.
s7_pause_unit() {
  local unit="$1" t0 now sig last base="" changed_at=0 diff lost out rc d5 d25 i n=0 rwait
  out="$(recipe_pauselong "$unit" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed "s/^/recipe pauselong $unit: /"
  s7_recipe_done S7.2 "$rc" "$out" || return 1
  for ((i = 0; i < 90; i++)); do
    n="$(s7_open_rows)"
    [ "$n" = 1 ] && break
    sleep 1
  done
  if [ "$n" != 1 ]; then
    echo "RERUN S7.2 not valid: the $unit unit is not the only one in flight (kit-index.sh status shows $n files pending or partial, expected exactly 1)"
    S7_RC=4
    return 1
  fi
  kq "$S7_IX" snapshot before-pause --files-only >/dev/null 2>&1
  t0="$(date +%s)"
  echo "  | $unit: Pause indexing pressed at $t0 (T0)"
  s6_press "$S7_AX" "Pause indexing" || { s7_fail S7.2 "$unit: pressing \"Pause indexing\" failed"; S7_RC=1; return 1; }
  last="$(s7_sig)"
  while :; do
    now="$(date +%s)"
    [ $((now - t0)) -ge 25 ] && break
    sleep 0.25
    sig="$(s7_sig)"
    if [ "$sig" != "$last" ]; then last="$sig"; changed_at=$((now - t0)); fi
    if [ -z "$base" ] && [ $((now - t0)) -ge 5 ]; then base="$sig"; fi
  done
  d5="${base%% *}"
  d25="${last%% *}"
  [ "$changed_at" -gt 5 ] && s7_why "$unit: the done count or the passages line were still changing $changed_at s after T0 (must stop by T0 plus 5 s and stay constant for the next 20 s)"
  [ "$d25" = "$d5" ] || s7_why "$unit: the done count was $d5 at T0 plus 5 s and $d25 at T0 plus 25 s, it must stay constant"
  S7_LABEL="$(s7_label)"
  [ "$(s7_state_of "$S7_LABEL")" = paused ] || s7_why "$unit: the menu does not say Paused after the pause (the label reads \"$S7_LABEL\")"
  echo "  | $unit after the pause: done $(s7_done_total), passages $(s7_passages), last change $changed_at s after T0, label \"$S7_LABEL\""
  s6_press "$S7_AX" "Resume indexing" || s7_why "$unit: pressing \"Resume indexing\" failed"
  rwait=10
  [ "$unit" = pdf ] && rwait=30
  out="$(kq "$S7_IX" wait rising "$rwait" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "$unit: the count did not rise within $rwait s of Resume indexing (kit-index.sh wait rising $rwait exited $rc)"
  kq "$S7_IX" snapshot after-resume --files-only >/dev/null 2>&1
  diff="$(kq "$S7_IX" diff before-pause after-resume 2>&1)"
  lost="$(s7_lost_done "$diff")"
  [ "$lost" = 0 ] || s7_why "$unit: $lost files that were done before the pause are changed or missing after the resume (kit-index.sh diff before-pause after-resume)"
  s7_ready 7200 || return 0
  return 0
}

s7_check_2() {
  local t0 now sig last base="" changed_at=0 diff lost out rc d5 d25 unit
  [ -n "$KIT_PLANT" ] && { S7_SKEW=1; S7_PLANTED="the done count at the end of the 20 s window read one higher than at T0 plus 5 s"; }
  s7_arm S7.2 || return $S7_RC
  s7_in_progress S7.2 || return $S7_RC
  kq "$S7_IX" snapshot before-pause --files-only >/dev/null 2>&1
  t0="$(date +%s)"
  echo "  | Pause indexing pressed at $t0 (T0)"
  s6_press "$S7_AX" "Pause indexing" || { s7_fail S7.2 "pressing \"Pause indexing\" failed"; return 1; }
  # the done count and the passages line, every 250 ms for 25 s: they stop rising by T0 plus 5 s and stay constant
  last="$(s7_sig)"
  while :; do
    now="$(date +%s)"
    [ $((now - t0)) -ge 25 ] && break
    sleep 0.25
    sig="$(s7_sig)"
    if [ "$sig" != "$last" ]; then last="$sig"; changed_at=$((now - t0)); fi
    if [ -z "$base" ] && [ $((now - t0)) -ge 5 ]; then base="$sig"; fi
  done
  d5="${base%% *}"
  d25="${last%% *}"
  if [ "$changed_at" -gt 5 ]; then
    s7_why "the done count or the passages line were still changing $changed_at s after T0 (must stop by T0 plus 5 s and stay constant for the next 20 s)"
  fi
  if [ "$((d25 + S7_SKEW))" != "$d5" ]; then s7_why "the done count was $d5 at T0 plus 5 s and $((d25 + S7_SKEW)) at T0 plus 25 s, it must stay constant"; fi
  S7_LABEL="$(s7_label)"
  [ "$(s7_state_of "$S7_LABEL")" = paused ] || s7_why "the menu does not say Paused after the pause (the label reads \"$S7_LABEL\")"
  echo "  | after the pause: done $(s7_done_total), passages $(s7_passages), last change $changed_at s after T0, label \"$S7_LABEL\""
  # Resume continues from where it stopped
  s6_press "$S7_AX" "Resume indexing" || s7_why "pressing \"Resume indexing\" failed"
  out="$(kq "$S7_IX" wait rising 10 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "the count did not rise within 10 s of Resume indexing (kit-index.sh wait rising 10 exited $rc)"
  kq "$S7_IX" snapshot after-resume --files-only >/dev/null 2>&1
  diff="$(kq "$S7_IX" diff before-pause after-resume 2>&1)"
  lost="$(s7_lost_done "$diff")"
  [ "$lost" = 0 ] || s7_why "$lost files that were done before the pause are changed or missing after the resume (kit-index.sh diff before-pause after-resume)"
  echo "  | files done before the pause that changed: $lost"
  # slice 5: the same measurement for each long unit, each alone in flight (the recipe pauselong picks that one folder)
  # (a planted run reads the mini mix only: the plant is a skew of that reading, and the long units take hours)
  if [ -z "$KIT_PLANT" ]; then
    for unit in pdf audio video; do
      s7_pause_unit "$unit" || return $S7_RC
    done
    rm -f "$S7_MARK"
  fi
  s7_done S7.2 "Pause indexing at T0 stopped the done count and the passages line by T0 plus 5 s and they stayed constant for 20 s with the menu saying Paused; Resume indexing made the count rise within 10 s and none of the files that were done before the pause changed (per-file snapshots before-pause and after-resume); the same held for each long unit alone in flight: the 60-page PDF, the 60-minute audio clip and the 2-minute video"
}
check_S7_2() { s7_run s7_check_2; }

# ---- S7.3 and S7.17: the CPU rule -----------------------------------------------------------------

# s7_first_state <state> <epoch0> <seconds> : polls the label until it is in that state. Sets S7_PREV (the second, from
# epoch0, at which the last read that was not in the state ended; 0 when there was none) and S7_FIRST (the second at
# which the first read in the state ended). Status 0 reached, 1 not within the seconds.
S7_PREV=0
S7_FIRST=0
s7_first_state() {
  local want="$1" e0="$2" end=$((SECONDS + $3)) got now
  S7_PREV=0; S7_FIRST=0
  while :; do
    S7_LABEL="$(s7_label)"
    got="$(s7_state_of "$S7_LABEL")"
    now=$(( $(date +%s) - e0 ))
    if [ "$got" = "$want" ]; then S7_FIRST="$now"; return 0; fi
    S7_PREV="$now"
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.5
  done
}

# s7_never <state> <seconds> <what> : the label never reads that state for that long; a read that does is a reason.
s7_never() {
  local end=$((SECONDS + $2))
  while :; do
    S7_LABEL="$(s7_label)"
    if [ "$(s7_state_of "$S7_LABEL")" = "$1" ]; then s7_why "$3: the status item read \"$S7_LABEL\""; return 1; fi
    [ "$SECONDS" -ge "$end" ] && return 0
    sleep 1
  done
}

# s7_always <state> <seconds> <what> : the label reads that state at every read for that long.
s7_always() {
  local end=$((SECONDS + $2))
  while :; do
    S7_LABEL="$(s7_label)"
    if [ "$(s7_state_of "$S7_LABEL")" != "$1" ]; then s7_why "$3: the status item read \"$S7_LABEL\", not $1"; return 1; fi
    [ "$SECONDS" -ge "$end" ] && return 0
    sleep 1
  done
}

# s7_load_ok <measure file> : status 0 when the load stayed where it was asked; 4 and the RERUN reason when it did not.
s7_load_ok() {
  local f="$1" rc
  rc="$(cat "$f.rc" 2>/dev/null)"
  [ "$rc" = 4 ] && return 4
  return 0
}

# s7_measure_bg <seconds> <file> : kit-load.sh measure in the background, its output and status in the file.
s7_measure_bg() {
  ( kq "$S7_LOAD" measure "$1" > "$2" 2>&1; echo $? > "$2.rc" ) &
}

s7_check_3() {
  local lo=10 hi=14 rlo=30 rhi=36 out t0 t1 rc f="$KIT_ROOT/run/s7-load-cpu.txt" tl="" mrc
  [ -n "$KIT_PLANT" ] && { hi=3; S7_PLANTED="the latest allowed pause time read as 3 s instead of 14 s"; }
  s7_arm S7.3 || return $S7_RC
  s7_in_progress S7.3 || return $S7_RC
  s7_battery_note
  rm -f "$f" "$f.rc"
  out="$(kq "$S7_LOAD" start 90 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { echo "RERUN S7.3 not valid: kit-load.sh start 90 exited $rc: $(s6_last "$out")"; return 4; }
  t0="$(s7_epoch "$out")"
  s7_measure_bg 40 "$f"
  # Paused no earlier than 10 s and no later than 14 s after the load starts
  if s7_first_state paused "$t0" 40; then
    echo "  | the label first read Paused between $S7_PREV s and $S7_FIRST s after the load started (allowed $lo to $hi s)"
    tl="paused-between $S7_PREV $S7_FIRST"
    [ "$S7_FIRST" -ge "$lo" ] || s7_why "paused at $S7_FIRST s, before the allowed $lo s: the CPU rule must wait out a dwell of 10 s"
    [ "$S7_PREV" -le "$hi" ] || s7_why "still not paused at $S7_PREV s, later than the allowed $hi s"
    sleep 4
    out="$(kq "$S7_IX" wait paused 15 2>&1)"; mrc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $mrc = 0 ] || s7_why "the label says Paused but the done count kept moving (kit-index.sh wait paused exited $mrc)"
  else
    s7_why "indexing was not Paused 40 s after the load started (the label reads \"$S7_LABEL\")"
  fi
  wait
  s7_load_ok "$f"; mrc=$?
  cat "$f" 2>/dev/null | sed 's/^/  | load: /'
  if [ "$mrc" = 4 ]; then echo "RERUN S7.3 not valid: the load fell short of 70 percent apart from Sesame: $(s6_last "$(cat "$f" 2>/dev/null)")"; return 4; fi
  # the load ends; it resumes by itself no earlier than 30 s and no later than 36 s after that
  kq "$S7_LOAD" stop >/dev/null 2>&1
  t1="$(date +%s)"
  echo "  | load stopped at $t1"
  if s7_first_state indexing "$t1" 90; then
    echo "  | the label first read Indexing between $S7_PREV s and $S7_FIRST s after the load ended (allowed $rlo to $rhi s)"
    tl="$tl; indexing-between $S7_PREV $S7_FIRST"
    [ "$S7_FIRST" -ge "$rlo" ] || s7_why "resumed at $S7_FIRST s after the load ended, before the allowed $rlo s"
    [ "$S7_PREV" -le "$rhi" ] || s7_why "still Paused at $S7_PREV s after the load ended, later than the allowed $rhi s"
    out="$(kq "$S7_IX" wait resumed 30 2>&1)"; mrc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $mrc = 0 ] || s7_why "the label says Indexing but the done count did not move (kit-index.sh wait resumed exited $mrc)"
  else
    s7_why "indexing did not resume within 90 s of the load ending (the label reads \"$S7_LABEL\")"
  fi
  s7_save status-timeline-cpu "t0 $t0 load-ended $t1 $tl"
  s7_done S7.3 "with kit-load.sh start 90 held above 70 percent apart from Sesame (kit-load.sh measure) indexing was Paused no earlier than 10 s and no later than 14 s after the load started and resumed by itself no earlier than 30 s and no later than 36 s after the load ended; the battery rule is S7.N1"
}
check_S7_3() { s7_run s7_check_3; }

s7_check_17() {
  local f="$KIT_ROOT/run/s7-load-edge.txt" out rc t1 mrc
  [ -n "$KIT_PLANT" ] && { S7_PLANTED="the 5 s burst run for 20 s, which must pause indexing"; }
  s7_arm S7.17 || return $S7_RC
  s7_in_progress S7.17 || return $S7_RC
  s7_battery_note
  rm -f "$f" "$f.rc"
  # a 5 s burst and an 8 s burst at 100 percent never pause
  out="$(kq "$S7_LOAD" start 100 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S7.17 not valid: kit-load.sh start 100 exited $rc: $(s6_last "$out")"; return 4; }
  s7_measure_bg 5 "$f"
  sleep 5
  [ -z "$KIT_PLANT" ] || sleep 15
  kq "$S7_LOAD" stop >/dev/null 2>&1
  s7_never paused 20 "a 5 s burst at 100 percent paused indexing"
  wait
  out="$(kq "$S7_LOAD" start 100 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S7.17 not valid: kit-load.sh start 100 exited $rc: $(s6_last "$out")"; return 4; }
  sleep 8
  kq "$S7_LOAD" stop >/dev/null 2>&1
  s7_never paused 20 "an 8 s burst at 100 percent paused indexing"
  # a steady 60 percent for 60 s never pauses
  rm -f "$f" "$f.rc"
  out="$(kq "$S7_LOAD" start 60 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S7.17 not valid: kit-load.sh start 60 exited $rc: $(s6_last "$out")"; return 4; }
  s7_measure_bg 60 "$f"
  s7_never paused 60 "a steady 60 percent for 60 s paused indexing"
  wait
  s7_load_ok "$f"; mrc=$?
  if [ "$mrc" = 4 ]; then echo "RERUN S7.17 not valid: the steady 60 percent load fell short: $(s6_last "$(cat "$f" 2>/dev/null)")"; return 4; fi
  kq "$S7_LOAD" stop >/dev/null 2>&1
  # after a pause by a 90 percent load, 60 percent for 60 s leaves it Paused; below 50 percent it resumes 30 to 36 s after the load ends
  s7_arm S7.17 || return $S7_RC
  out="$(kq "$S7_LOAD" start 90 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S7.17 not valid: kit-load.sh start 90 exited $rc: $(s6_last "$out")"; return 4; }
  if s7_wait_state paused 40; then
    out="$(kq "$S7_LOAD" start 60 2>&1)"; rc=$?
    [ $rc = 0 ] || { echo "RERUN S7.17 not valid: kit-load.sh start 60 exited $rc: $(s6_last "$out")"; return 4; }
    s7_always paused 60 "indexing resumed while the load stood at 60 percent (resume needs below 50 percent for 30 s)"
    kq "$S7_LOAD" stop >/dev/null 2>&1
    t1="$(date +%s)"
    if s7_first_state indexing "$t1" 90; then
      echo "  | after the 60 percent load ended the label first read Indexing between $S7_PREV s and $S7_FIRST s (allowed 30 to 36 s)"
      [ "$S7_FIRST" -ge 30 ] || s7_why "resumed at $S7_FIRST s after the load ended, before the allowed 30 s"
      [ "$S7_PREV" -le 36 ] || s7_why "still Paused at $S7_PREV s after the load ended, later than the allowed 36 s"
    else
      s7_why "indexing did not resume within 90 s of the load ending (the label reads \"$S7_LABEL\")"
    fi
  else
    s7_why "a 90 percent load did not pause indexing within 40 s, so the edge after a pause cannot be read"
  fi
  s7_done S7.17 "a 5 s and an 8 s burst at 100 percent and a steady 60 percent for 60 s never paused indexing (every read Indexing); after a pause by a 90 percent load, 60 percent for 60 s left it Paused, and it resumed 30 to 36 s after the load ended; the loads were measured by kit-load.sh measure"
}
check_S7_17() { s7_run s7_check_17; }

# ---- S7.4: Low Power Mode ---------------------------------------------------------------------------

s7_check_4() {
  local out rc t0 t1 l0 l1 pausedby evidence="" wait_s=5
  [ -n "$KIT_PLANT" ] && { wait_s=0; S7_PLANTED="indexing required to be Paused at T0 plus 0 s instead of T0 plus 5 s"; }
  s7_battery_note
  out="$(kq "$S7_PW" lowpower get 2>&1)"
  case "$out" in
    *unsupported*) echo "CHECK S7.4 NEEDS-A-PERSON this Mac has no Low Power Mode setting (kit-power.sh lowpower get says unsupported); the Low Power Mode rule is not proven (S7.N1)"; return 0 ;;
  esac
  out="$(kq "$S7_PW" ping 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc = 3 ]; then echo "CHECK S7.4 NEEDS-A-PERSON $(s6_pick "$out")"; return 0; fi
  admin_session || { echo "CHECK S7.4 NEEDS-A-PERSON administrator rights were not given (kit-perms.sh ask-admin was refused)"; return 0; }
  s7_arm S7.4 || return $S7_RC
  s7_in_progress S7.4 || return $S7_RC
  S7_USED_POWER=1
  # arming takes minutes: the administrator session may have run out since it was asked for
  admin_session || { echo "CHECK S7.4 NEEDS-A-PERSON administrator rights were not given again after the arming (kit-perms.sh ask-admin was refused)"; return 0; }
  out="$(kq "$S7_PW" lowpower on 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc = 3 ]; then echo "CHECK S7.4 NEEDS-A-PERSON $(s6_pick "$out")"; return 0; fi
  [ $rc = 0 ] || { s7_fail S7.4 "kit-power.sh lowpower on exited $rc: $(s6_last "$out")"; return 1; }
  t0="$(s7_epoch "$out")"
  sleep "$wait_s"
  l0="$(s7_label)"
  [ "$(s7_state_of "$l0")" = paused ] || s7_why "T0 plus $wait_s s: the status item reads \"$l0\", not Paused"
  out="$(kq "$S7_IX" wait paused 10 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "the done count did not stop after Low Power Mode went on (kit-index.sh wait paused exited $rc)"
  out="$(kq "$S7_IX" wait stable 20 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "the done count did not stay constant for 20 s (kit-index.sh wait stable exited $rc)"
  admin_session || { echo "CHECK S7.4 NEEDS-A-PERSON administrator rights ran out while Low Power Mode was on and were not given again: the cleanup tries kit-power.sh restore and says what to run if that fails"; return 0; }
  out="$(kq "$S7_PW" lowpower off 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s7_fail S7.4 "kit-power.sh lowpower off exited $rc: $(s6_last "$out")"; return 1; }
  t1="$(s7_epoch "$out")"
  out="$(kq "$S7_IX" wait resumed 15 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "indexing did not resume by itself within 15 s of Low Power Mode going off (kit-index.sh wait resumed exited $rc)"
  out="$(kq "$S7_IX" wait rising 10 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "the done count did not rise within 10 s of T1 (kit-index.sh wait rising exited $rc)"
  sleep 3
  l1="$(s7_label)"
  [ "$(s7_state_of "$l1")" = indexing ] || s7_why "after T1 the status item reads \"$l1\", not Indexing"
  s7_save lowpower-s7-4 "T0 $t0 label at T0+$wait_s: $l0; T1 $t1 label after resume: $l1"
  # a pause by you stays: Low Power Mode on then off leaves it Paused, and Resume indexing then resumes it
  s6_press "$S7_AX" "Pause indexing" || s7_why "pressing \"Pause indexing\" failed"
  admin_session || { echo "CHECK S7.4 NEEDS-A-PERSON administrator rights were not given again for the pause-by-you case (kit-perms.sh ask-admin was refused)"; return 0; }
  kq "$S7_PW" lowpower on >/dev/null 2>&1 || s7_why "kit-power.sh lowpower on failed in the pause-by-you case"
  sleep 6
  admin_session || { echo "CHECK S7.4 NEEDS-A-PERSON administrator rights ran out while Low Power Mode was on and were not given again: the cleanup tries kit-power.sh restore and says what to run if that fails"; return 0; }
  kq "$S7_PW" lowpower off >/dev/null 2>&1 || s7_why "kit-power.sh lowpower off failed in the pause-by-you case"
  sleep 12
  pausedby="$(s7_label)"
  [ "$(s7_state_of "$pausedby")" = paused ] || s7_why "a pause by you was lifted by Low Power Mode going on and off (the status item reads \"$pausedby\")"
  out="$(kq "$S7_IX" wait stable 10 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "the done count moved while the pause by you stood"
  s6_press "$S7_AX" "Resume indexing" || s7_why "pressing \"Resume indexing\" failed"
  out="$(kq "$S7_IX" wait resumed 30 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "indexing did not resume after Resume indexing (kit-index.sh wait resumed exited $rc)"
  s7_done S7.4 "kit-power.sh lowpower on made the menu and the status item say Paused and the done count stopped and stayed constant for 20 s; lowpower off made indexing resume by itself with no click; a pause by you stayed Paused through Low Power Mode on and off and Resume indexing resumed it; the value at reset is put back by kit-power.sh restore"
}
check_S7_4() { s7_run s7_check_4; }

# ---- S7.5: the panel is usable while indexing -------------------------------------------------------

# s7_panel_still <what> <files known> : the panel opened with the shortcut shows "Still indexing (N%)" with N within 1 of
# files done over files known, and a banner that names every kind that still has unread rows.
s7_panel_still() {
  local what="$1" total="$2" d0 d1 n text k rx
  d0="$(s7_done_total)"
  if ! pn_open_panel; then s7_why "$what: the panel did not open: $PN_OUT"; return 1; fi
  sleep 1
  PN_DUMP="$(KIT_NO_EVIDENCE=1 kit_timeout 30 "$S7_AX" dump panel 2>&1)"
  d1="$(s7_done_total)"
  text="$PN_DUMP"
  n="$(printf '%s\n' "$text" | sed -n 's/.*[Ss]till indexing[^0-9]*\([0-9][0-9]*\) *\(%\|percent\).*/\1/p' | head -1)"
  if [ -z "$n" ]; then
    s7_why "$what: the panel shows no \"Still indexing (N%)\""
  elif ! awk -v n="$n" -v a="$d0" -v b="$d1" -v t="$total" 'BEGIN { lo = 100 * a / t - 1; hi = 100 * b / t + 1; exit (n >= lo && n <= hi) ? 0 : 1 }'; then
    s7_why "$what: the panel says $n percent, files done over files known is $d0 to $d1 of $total (expect counts), not within 1 point"
  fi
  for k in $(s7_open_kinds); do
    case "$k" in photo) rx="photo|picture|image" ;; *) rx="$k" ;; esac
    printf '%s\n' "$text" | tr 'A-Z' 'a-z' | awk -v rx="$rx" '/still indexing|may be missing|not.*yet|missing/ && $0 ~ rx { f = 1 } END { exit f ? 0 : 1 }' || s7_why "$what: the banner does not name the kind $k, which still has unread rows (kinds that may be missing)"
  done
  echo "  | $what: panel says ${n:-nothing} percent, done $d0 to $d1 of $total"
  pn_close_panel >/dev/null 2>&1
  return 0
}

# s7_found_by_name <what> : a done file is found by its exact name within the first rows; a file still unread is not listed.
s7_found_by_name() {
  local what="$1" dpath upath dname uname out rc
  dpath="$(s7_paths_under minimix done | sed -n 1p)"
  upath="$(s7_paths_under minimix pending | sed -n 1p)"
  if [ -z "$dpath" ]; then s7_why "$what: the index holds no done file to look for"; return 1; fi
  dname="${dpath##*/}"
  out="$(kq "$S7_SEARCH" "$dname" --wait-for "$dpath" --within 20 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    s7_why "$what: the done file $dname is not found by its exact name (kit-search.sh exited $rc)"
  elif ! printf '%s\n' "$out" | awk -v n="$dname" '$1 == "row" && $2 <= 5 && index($0, n) { f = 1 } END { exit f ? 0 : 1 }'; then
    s7_why "$what: the done file $dname is not among the first five rows"
  fi
  if [ -z "$upath" ]; then
    echo "  | $what: no file is pending right now, so no unread file is looked for"
  else
    uname="${upath##*/}"
    out="$(kq "$S7_SEARCH" "$uname" --expect-absent "$upath" 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "$what: the unread file $uname is listed (kit-search.sh --expect-absent exited $rc)"
  fi
  return 0
}

s7_check_5() {
  local total d tries=0
  [ -n "$KIT_PLANT" ] && { S7_SKEW=5; S7_PLANTED="files known read as 5 more than kit-fixtures.sh expect counts says"; }
  s7_arm S7.5 || return $S7_RC
  total="$(( $(s7_total_expected "$S7_MIX") + S7_SKEW ))"
  # indexing is part way: some files done, some not
  while [ "$tries" -lt 240 ]; do
    d="$(s7_done_total)"
    [ "$d" -gt 0 ] && break
    tries=$((tries + 1)); sleep 1
  done
  s7_in_progress S7.5 || return $S7_RC
  s6_press "$S7_AX" "Pause indexing" || s7_why "pressing \"Pause indexing\" failed"
  sleep 4
  s7_panel_still "paused" "$total"
  s7_found_by_name "paused"
  s6_press "$S7_AX" "Resume indexing" || s7_why "pressing \"Resume indexing\" failed"
  sleep 3
  s7_panel_still "indexing running" "$total"
  s7_found_by_name "indexing running"
  s7_done S7.5 "paused part way and again with indexing running, the panel opened with the shortcut showed Still indexing (N%) with N within 1 point of files done over the expect counts total, a banner naming the kinds that still had unread rows, a done file was found by its exact name within the first rows and an unread file was not listed"
}
check_S7_5() { s7_run s7_check_5; }

# ---- S7.6 and S7.7: new, changed, deleted, moved and renamed files ---------------------------------

# s7_to_ready <id> : a caught-up index at Ready on the mini mix with nothing pending; the state is S7_MUTATED so the
# next check starts clean. Status 0 ready; else the CHECK or RERUN line, S7_RC, status 1.
s7_to_ready() {
  local id="$1"
  s7_arm "$id" || return 1
  S7_MUTATED=1
  if ! s7_ready 3600; then s7_fail "$id" "$S7_WHY"; S7_RC=1; return 1; fi
  if [ "$(s7_open_rows)" != 0 ]; then echo "RERUN $id not valid: files are still pending at Ready"; S7_RC=4; return 1; fi
  return 0
}

s7_check_6() {
  local within=30 out rc newtxt oldp newp photo gold phrase1 phrase2 name
  [ -n "$KIT_PLANT" ] && { within=1; S7_PLANTED="the new file searched for 1 s instead of 30 s"; }
  s7_to_ready S7.6 || return $S7_RC
  kq "$S7_FX" build golden >/dev/null 2>&1
  gold="$(ls "$KIT_ROOT/fixtures/golden/photos" 2>/dev/null | sed -n 1p)"
  # a new photo, copied from a golden photo under a new name
  if [ -z "$gold" ]; then
    s7_why "no golden photo to copy (kit-fixtures.sh build golden left golden/photos empty)"
  else
    name="s7-new-photo-$$.jpg"
    photo="$S7_MIX/$name"
    cp "$KIT_ROOT/fixtures/golden/photos/$gold" "$photo" && S7_TMPFILES="$S7_TMPFILES $photo"
    out="$(kq "$S7_SEARCH" "$name" --wait-for "$photo" --within "$within" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed -n '/elapsed/p' | sed 's/^/  | new photo: /'
    [ $rc = 0 ] || s7_why "the new photo $name was not found within $within s of being copied in (kit-search.sh --wait-for exited $rc)"
  fi
  # a new text file with a unique phrase, and an edit with a different size: looked for only where the build indexes the kind
  newtxt="$S7_MIX/s7-new-$$.txt"
  out="$(kq "$S7_FX" mutate create "$newtxt" 2>&1)"
  phrase1="$(printf '%s\n' "$out" | awk '$1 == "PHRASE" { sub(/^PHRASE /, ""); print; exit }')"
  if s7_kind_indexed document; then
    out="$(kq "$S7_SEARCH" "$phrase1" --wait-for "$newtxt" --within "$within" 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "the new text file was not found by its phrase within $within s (kit-search.sh --wait-for exited $rc)"
    out="$(kq "$S7_FX" mutate edit "$newtxt" 2>&1)"
    phrase2="$(printf '%s\n' "$out" | awk '$1 == "PHRASE" { sub(/^PHRASE /, ""); print; exit }')"
    out="$(kq "$S7_SEARCH" "$phrase2" --wait-for "$newtxt" --within 30 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "the edited text file was not found by its new phrase within $within s (kit-search.sh --wait-for exited $rc)"
    out="$(kq "$S7_SEARCH" "$phrase1" --expect-absent "$newtxt" 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "the old phrase still lists the edited text file (kit-search.sh --expect-absent exited $rc)"
  else
    echo "  | noted: the index holds no document files, so this build does not index text: the new text file ($phrase1) and its edit are not looked for (slice 4)"
  fi
  echo "  | noted: a new PDF is not made at slice 2: this build indexes photos only, the PDF kind and its fixture arrive with slice 4"
  s7_done S7.6 "a new photo copied from a golden photo was found by its name within $within s of indexing having caught up (the new text file, the edit and the new PDF are looked for only for the kinds this build indexes, photos at slice 2)"
}
check_S7_6() { s7_run s7_check_6; }

s7_check_7() {
  local wait_s=30 out rc files f1 f2 f3 dir n1 n2 n3 old new rows unsettled=""
  [ -n "$KIT_PLANT" ] && { wait_s=0; S7_PLANTED="the files required gone from the index at once instead of within 30 s"; }
  s7_to_ready S7.7 || return $S7_RC
  files="$(s7_paths_under minimix done)"
  f1="$(printf '%s\n' "$files" | sed -n 1p)"
  f2="$(printf '%s\n' "$files" | sed -n 2p)"
  f3="$(printf '%s\n' "$files" | sed -n 3p)"
  if [ -z "$f3" ]; then s7_why "the index holds fewer than three done files to delete, rename and move"; s7_done S7.7 ""; return $?; fi
  # a deleted file
  n1="${f1##*/}"
  kq "$S7_FX" mutate delete "$f1" >/dev/null 2>&1 || s7_why "kit-fixtures.sh mutate delete failed"
  s7_wait_has "$f1" absent "$wait_s" || s7_why "the deleted file $n1 is still in the index $wait_s s later (kit-index.sh has)"
  out="$(kq "$S7_SEARCH" "$n1" --expect-absent "$f1" 2>&1)"; rc=$?
  if [ $rc = 4 ]; then unsettled="the results list did not settle after the delete"
  elif [ $rc != 0 ]; then s7_why "the deleted file $n1 is still listed in the results (kit-search.sh --expect-absent exited $rc)"; fi
  # a renamed file: the old path absent and the new path present, one row only
  dir="${f2%/*}"
  old="$f2"; new="$dir/s7-renamed-$$.jpg"
  kq "$S7_FX" mutate rename "$f2" "s7-renamed-$$.jpg" >/dev/null 2>&1 || s7_why "kit-fixtures.sh mutate rename failed"
  s7_wait_has "$new" present "$wait_s" || s7_why "the renamed file is not in the index under its new path $wait_s s later"
  s7_wait_has "$old" absent "$wait_s" || s7_why "the renamed file is still in the index under its old path $wait_s s later"
  rows="$(s7_paths_under minimix | awk -v a="${old##*/}" -v b="${new##*/}" 'n = split($0, p, "/") { if (p[n] == a || p[n] == b) k++ } END { print k + 0 }')"
  [ "$rows" = 1 ] || s7_why "the renamed file has $rows rows under its old and new names, expected one row only"
  out="$(kq "$S7_SEARCH" "${new##*/}" --wait-for "$new" --within 30 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "the renamed file is not found under its new name within 30 s (kit-search.sh --wait-for exited $rc)"
  out="$(kq "$S7_SEARCH" "${old##*/}" --expect-absent "$old" 2>&1)"; rc=$?
  if [ $rc = 4 ]; then unsettled="${unsettled:+$unsettled; }the results list did not settle after the rename"
  elif [ $rc != 0 ]; then s7_why "the old name of the renamed file is still listed (kit-search.sh --expect-absent exited $rc)"; fi
  # a moved file: to another folder under the picked one
  mkdir -p "$S7_MIX/moved"
  old="$f3"; new="$S7_MIX/moved/${f3##*/}"
  kq "$S7_FX" mutate move "$f3" "$S7_MIX/moved" >/dev/null 2>&1 || s7_why "kit-fixtures.sh mutate move failed"
  s7_wait_has "$new" present "$wait_s" || s7_why "the moved file is not in the index under its new path $wait_s s later"
  s7_wait_has "$old" absent "$wait_s" || s7_why "the moved file is still in the index under its old path $wait_s s later"
  rows="$(s7_paths_under minimix | awk -v a="${f3##*/}" 'n = split($0, p, "/") { if (p[n] == a) k++ } END { print k + 0 }')"
  [ "$rows" = 1 ] || s7_why "the moved file has $rows rows under its name, expected one row only"
  out="$(kq "$S7_SEARCH" "${new##*/}" --wait-for "$new" --within 30 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "the moved file is not found under its new path within 30 s (kit-search.sh --wait-for exited $rc)"
  rmdir "$S7_MIX/moved" 2>/dev/null
  if [ -n "$unsettled" ] && [ -z "$S7_WHY" ]; then
    echo "RERUN S7.7 not valid: $unsettled (kit-search.sh --expect-absent exited 4)"
    S7_RC=4
    return 4
  fi
  s7_done S7.7 "a deleted file left the index and the results within $wait_s s; a renamed file and a moved file were gone under the old path and present under the new one in the index and in the results within $wait_s s, one row only"
}
check_S7_7() { s7_run s7_check_7; }

# ---- S7.8: an unplugged drive -------------------------------------------------------------------------

s7_check_8() {
  local out rc t0 n gone=0 file name settings
  [ -n "$KIT_PLANT" ] && { S7_PLANTED="the files after the attach searched for 5 s instead of 300 s"; }
  s7_arm S7.8 || return $S7_RC
  S7_DIRTY=1
  S7_USED_VOL=1
  out="$(kq "$S7_VOL" make 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { echo "RERUN S7.8 not valid: kit-volume.sh make exited $rc: $(s6_last "$out")"; return 4; }
  s6_press "$S7_AX" "Settings…" || s7_why "pressing \"Settings…\" in the status item's menu failed"
  s6b_settings || s7_why "Settings did not open"
  PK_WINDOW=settings drive_picker "$S7_MNT"; rc=$?
  if [ $rc != 0 ]; then
    S7_PERSON="the folder picker could not be driven ($PICKER_WHY): add $S7_MNT with \"Add folder…\" in Settings and run this check again"
    s7_done S7.8 ""; return 0
  fi
  settings_section Indexing || s7_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
  kq "$S7_AX" click "Start indexing" >/dev/null 2>&1 || s7_why "pressing \"Start indexing\" in Settings failed"
  out="$(kq "$S7_IX" wait done 900 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "the volume was not indexed within 900 s (kit-index.sh wait done exited $rc)"
  file="$(s7_paths_under "$S7_MNT" done | sed -n 1p)"
  n="$(s7_rows_under "$S7_MNT")"
  if [ -z "$file" ]; then s7_why "the index holds no done file under the mount $S7_MNT before the detach"; s7_done S7.8 ""; return $?; fi
  name="${file##*/}"
  echo "  | before the detach: $n rows under $S7_MNT"
  # the unplug: every file of the drive disappears within 30 s
  t0="$(date +%s)"
  out="$(kq "$S7_VOL" detach 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { echo "RERUN S7.8 not valid: kit-volume.sh detach exited $rc: $(s6_last "$out")"; return 4; }
  while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
    [ "$(s7_rows_under "$S7_MNT")" = 0 ] && { gone=$(( $(date +%s) - t0 )); break; }
    sleep 1
  done
  [ "$(s7_rows_under "$S7_MNT")" = 0 ] || s7_why "$(s7_rows_under "$S7_MNT") rows under the mount are still in the index 30 s after the detach"
  out="$(kq "$S7_SEARCH" "$name" --expect-absent "$file" 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "a file of the detached drive is still listed in the results (kit-search.sh --expect-absent exited $rc)"
  echo "  | the rows under the mount were gone $gone s after the detach"
  # the plug-in: with no click by the kit the files are read again and found
  out="$(kq "$S7_VOL" attach 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { echo "RERUN S7.8 not valid: kit-volume.sh attach exited $rc: $(s6_last "$out")"; return 4; }
  t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt 300 ]; do
    [ "$(s7_rows_under "$S7_MNT")" -gt 0 ] && break
    if [ -n "$KIT_PLANT" ] && [ $(( $(date +%s) - t0 )) -ge 5 ]; then break; fi
    sleep 2
  done
  [ "$(s7_rows_under "$S7_MNT")" -gt 0 ] || s7_why "no row of the drive came back within 300 s of the attach, with no click"
  if [ -n "$KIT_PLANT" ]; then
    out="$(kq "$S7_SEARCH" "$name" --wait-for "$file" --within 5 2>&1)"; rc=$?
  else
    out="$(kq "$S7_SEARCH" "$name" --wait-for "$file" --within 300 2>&1)"; rc=$?
  fi
  [ $rc = 0 ] || s7_why "the file $name is not found within 300 s of the attach (kit-search.sh --wait-for exited $rc)"
  settings="$(kq "$S7_IX" settings 2>&1)"
  case "$settings" in *'"startPressed" => 1'*|*'"startPressed" => true'*) ;; *) s7_why "startPressed is not true after the drive came back" ;; esac
  s7_done S7.8 "a detached disk image emptied the index under it within $gone s (30 s allowed) and no result listed its files; attached again with no click by the kit its rows came back and its files were found, and startPressed was still true"
}
check_S7_8() { s7_run s7_check_8; }

# ---- S7.9: removing, unticking and ticking a folder ----------------------------------------------------

s7_check_9() {
  local out rc t0 first name n tick before want within=2
  [ -n "$KIT_PLANT" ] && { S7_SKEW=1; S7_PLANTED="the rows expected under a removed folder read as 1 instead of 0"; }
  s7_arm S7.9 || return $S7_RC
  S7_DIRTY=1
  kq "$S7_FX" build extra >/dev/null 2>&1
  # a second folder, indexed: extra
  s6_press "$S7_AX" "Settings…" || s7_why "pressing \"Settings…\" in the status item's menu failed"
  s6b_settings || s7_why "Settings did not open"
  PK_WINDOW=settings drive_picker "$KIT_ROOT/fixtures/extra"; rc=$?
  if [ $rc != 0 ]; then
    S7_PERSON="the folder picker could not be driven ($PICKER_WHY): add $KIT_ROOT/fixtures/extra with \"Add folder…\" in Settings and run this check again"
    s7_done S7.9 ""; return 0
  fi
  settings_section Indexing || s7_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
  kq "$S7_AX" click "Start indexing" >/dev/null 2>&1 || s7_why "pressing \"Start indexing\" in Settings failed"
  out="$(kq "$S7_IX" wait done 3600 2>&1)"; rc=$?
  [ $rc = 0 ] || s7_why "the folders were not indexed within 3600 s (kit-index.sh wait done exited $rc)"
  first="$(s7_paths_under extra done | sed -n 1p)"
  if [ -z "$first" ]; then s7_why "the index holds no done file under extra before the removal"; s7_done S7.9 ""; return $?; fi
  name="${first##*/}"
  # removing extra in Settings (the confirm question): its file is absent at once and its rows removed within 30 s. Every row has a
  # Remove, a menu item of the row's more button, so the more button of the row of extra is pressed first and the Remove pressed is the open menu's.
  settings_section Folders || s7_why "the Settings window cannot be put on its Folders section, so no Remove can be pressed"
  s6b_settings
  if [ -z "$(s6b_block extra)" ]; then
    s7_why "the Settings window lists no row for extra"
  else
    t0="$(date +%s)"
    kq "$S7_AX" click "More actions for extra" >/dev/null 2>&1 || s7_why "pressing the more button of the row of extra failed"
    sleep 1
    kq "$S7_AX" click "Remove" >/dev/null 2>&1 || s7_why "the Remove item of the open menu could not be pressed (the menu did not open, or kit-ax does not reach an open menu's items)"
    sleep 1
    kq "$S7_AX" click "Remove folder" >/dev/null 2>&1 || s7_why "the confirmation \"Remove folder\" could not be pressed"
    if s7_wait_has "$first" absent "$within"; then echo "  | removing extra: its file was gone from the index $(( $(date +%s) - t0 )) s later"; else s7_why "$name of the removed folder is still in the index $within s after the removal"; fi
    n=0
    while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
      n="$(s7_rows_under extra)"; [ "$n" = 0 ] && break; sleep 2
    done
    [ "$n" = "$S7_SKEW" ] || s7_why "$n rows under extra are in the index 30 s after the folder was removed"
    out="$(kq "$S7_SEARCH" "$name" --expect-absent "$first" 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "the removed folder's file $name is still listed (kit-search.sh --expect-absent exited $rc)"
  fi
  # unticking an indexed folder removes its files at once; ticking it again waits for Start indexing
  s6b_settings
  tick="$(s6b_tick_label "$(s6b_block minimix)")"
  if [ -z "$tick" ]; then
    s7_why "no tick box in the Settings row of the mini mix"
  else
    first="$(s7_paths_under minimix done | sed -n 1p)"
    name="${first##*/}"
    before="$(s7_rows_under minimix)"
    t0="$(date +%s)"
    kq "$S7_AX" click "$tick" >/dev/null 2>&1 || s7_why "unticking \"$tick\" failed"
    if s7_wait_has "$first" absent "$within"; then echo "  | unticking the mini mix: its file was gone from the index $(( $(date +%s) - t0 )) s later"; else s7_why "$name of the unticked folder is still in the index $within s after the untick"; fi
    n="$before"
    while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
      n="$(s7_rows_under minimix)"; [ "$n" = 0 ] && break; sleep 2
    done
    [ "$n" = 0 ] || s7_why "$n rows of the unticked folder are in the index 30 s after the untick"
    out="$(kq "$S7_SEARCH" "$name" --expect-absent "$first" 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "the unticked folder's file $name is still listed (kit-search.sh --expect-absent exited $rc)"
    kq "$S7_AX" click "$tick" >/dev/null 2>&1 || s7_why "ticking \"$tick\" again failed"
    t0="$(date +%s)"
    while [ $(( $(date +%s) - t0 )) -lt 60 ]; do
      n="$(s7_rows_under minimix)"
      [ "$n" = 0 ] || { s7_why "$n rows of the folder came back before Start indexing was pressed (absent for 60 s required)"; break; }
      sleep 5
    done
    settings_section Indexing || s7_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
    kq "$S7_AX" click "Start indexing" >/dev/null 2>&1 || s7_why "pressing \"Start indexing\" after ticking again failed"
    out="$(kq "$S7_IX" wait done 3600 2>&1)"; rc=$?
    [ $rc = 0 ] || s7_why "Start indexing did not read the ticked folder again within 3600 s (kit-index.sh wait done exited $rc)"
    want="$(s7_total_expected "$S7_MIX")"
    n="$(s7_rows_under minimix)"
    [ "$n" -gt 0 ] || s7_why "after Start indexing no row of the ticked folder is in the index (expected the $want files of expect counts)"
  fi
  s7_done S7.9 "removing a folder in Settings took its file out of the index at once and its rows within 30 s and out of the results; unticking an indexed folder did the same; ticking it again left its rows absent for 60 s and Start indexing then read them"
}
check_S7_9() { s7_run s7_check_9; }

# ---- S7.10 and S7.11: Quit, relaunch, Delete index ---------------------------------------------------

# s7_procs : the number of processes of the app's tree (`kit-launch.sh pids`).
s7_procs() { kq "$S7_LD" pids 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { n++ } END { print n + 0 }'; }

s7_check_10() {
  local out rc t0 n=1 diff lost settings
  [ -n "$KIT_PLANT" ] && { S7_SKEW=1; S7_PLANTED="one process read as left after Quit"; }
  s7_arm S7.10 || return $S7_RC
  s7_in_progress S7.10 || return $S7_RC
  sleep 5
  kq "$S7_IX" snapshot before-quit --files-only >/dev/null 2>&1
  t0="$(date +%s)"
  out="$(kq "$S7_LD" quit 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s7_fail S7.10 "kit-launch.sh quit exited $rc: $(s6_last "$out")"; return 1; }
  while [ $(( $(date +%s) - t0 )) -lt 5 ]; do
    n="$(s7_procs)"; [ "$n" = 0 ] && break; sleep 0.5
  done
  n=$((n + S7_SKEW))
  [ "$n" = 0 ] || s7_why "$n Sesame or helper processes were left 5 s after Quit (kit-launch.sh pids)"
  out="$(kq "$S7_IX" wait stable 30 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "the done count was not constant for 30 s after Quit (kit-index.sh wait stable exited $rc)"
  out="$(kq "$S7_IX" integrity 2>&1)"
  [ "$out" = ok ] || s7_why "the integrity check after Quit printed: $(s6_last "$out")"
  # the relaunch: no click on Start indexing, the count rises by itself
  out="$(kq "$S7_LD" start --mirror-full 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s7_fail S7.10 "kit-launch.sh start --mirror-full exited $rc: $(s6_last "$out")"; return 1; }
  out="$(kq "$S7_IX" wait rising 60 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "indexing did not resume by itself within 60 s of the relaunch (kit-index.sh wait rising exited $rc)"
  kq "$S7_IX" snapshot after-relaunch --files-only >/dev/null 2>&1
  diff="$(kq "$S7_IX" diff before-quit after-relaunch 2>&1)"
  lost="$(s7_lost_done "$diff")"
  [ "$lost" = 0 ] || s7_why "$lost files that were done before Quit are changed or missing after the relaunch (kit-index.sh diff before-quit after-relaunch)"
  settings="$(kq "$S7_IX" settings 2>&1)"
  case "$settings" in *'"startPressed" => 1'*|*'"startPressed" => true'*) ;; *) s7_why "startPressed is not true after the relaunch" ;; esac
  s7_done S7.10 "Quit left no Sesame or helper process within 5 s, the done count was constant for 30 s and the integrity check printed ok; the relaunch resumed indexing with no click on Start indexing, the files done before were unchanged and startPressed was still true"
}
check_S7_10() { s7_run s7_check_10; }

s7_check_11() {
  local out rc files passages helpers label want=0
  [ -n "$KIT_PLANT" ] && { want=1; S7_PLANTED="the files line expected to read 1 after Delete index"; }
  s7_arm S7.11 || return $S7_RC
  sleep 10
  s7_delete_index || { s7_fail S7.11 "$S7_WHY"; return 1; }
  kq "$S7_LD" quit >/dev/null 2>&1
  out="$(kq "$S7_LD" relaunch 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || { s7_fail S7.11 "kit-launch.sh relaunch exited $rc: $(s6_last "$out")"; return 1; }
  out="$(kq "$S7_IX" wait stable 90 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  files="$(s7_files_n)"
  passages="$(s7_passages)"
  [ "$files" = "$want" ] || s7_why "the files line reads ${files:-nothing} 90 s after Delete index and the relaunch, expected $want"
  [ "$passages" = 0 ] || s7_why "the passages line reads ${passages:-nothing} 90 s after Delete index and the relaunch, expected 0"
  helpers="$(kq "$S7_LD" pids --names 2>/dev/null | awk '/index/ { n++ } END { print n + 0 }')"
  [ "$helpers" = 0 ] || s7_why "an index helper is running 90 s after Delete index and the relaunch (kit-launch.sh pids)"
  label="$(s7_label)"
  [ "$(s7_state_of "$label")" != indexing ] || s7_why "the status item says Indexing 90 s after Delete index and the relaunch (\"$label\")"
  # Start indexing then runs it to Ready
  s6_press "$S7_AX" "Settings…" || s7_why "pressing \"Settings…\" in the status item's menu failed"
  s6b_settings || s7_why "Settings did not open"
  settings_section Indexing || s7_why "the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"
  kq "$S7_AX" click "Start indexing" >/dev/null 2>&1 || s7_why "pressing \"Start indexing\" failed"
  s7_ready 3600
  s7_done S7.11 "after Delete index and a relaunch the index held 0 files and 0 passages and no index helper ran after 90 s and the menu was not Indexing; Start indexing then ran the index to Ready"
}
check_S7_11() { s7_run s7_check_11; }

# ---- S7.12: ten kills ----------------------------------------------------------------------------

# s7_kill <app|index> <n> <seed> : one kill at a random moment of indexing, then the integrity check; each result line is
# kept for kill-s7-12.txt in S7_OUT.
s7_kill() {
  local what="$1" n="$2" seed="$3" delay out rc i ok
  delay="$(awk -v s="$seed" -v n="$n" 'BEGIN { srand(s + n); print int(3 + rand() * 20) }')"
  if [ "$(s7_open_rows)" = 0 ]; then
    s7_rearm S7.12 || return 1
  fi
  sleep "$delay"
  ok=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$what" = index ]; then out="$(kq "$S7_LD" kill9 index 2>&1)"; rc=$?; else out="$(kq "$S7_LD" kill9 app 2>&1)"; rc=$?; fi
    [ $rc = 0 ] && { ok=1; break; }
    sleep 1
  done
  S7_OUT="$S7_OUT"$'\n'"kill $n: $what after $delay s (seed $seed): $(s6_last "$out")"
  if [ "$ok" != 1 ]; then s7_why "kill $n: kit-launch.sh kill9 $what exited $rc: $(s6_last "$out")"; return 1; fi
  if [ "$what" = app ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ -z "$(kq "$S7_LD" pids 2>/dev/null | awk '$1 ~ /^[0-9]+$/')" ] && break
      sleep 1
    done
    kq "$S7_LD" start --mirror-full >/dev/null 2>&1 || s7_why "kill $n: kit-launch.sh start --mirror-full after the app kill failed"
    sleep 5
  else
    sleep 3
  fi
  out="$(kq "$S7_IX" integrity 2>&1)"
  [ "$out" = ok ] || s7_why "kill $n ($what): the integrity check printed $(s6_last "$out")"
  S7_OUT="$S7_OUT; integrity $(s6_last "$out")"
  return 0
}

s7_check_12() {
  local out rc seed n what bad
  [ -n "$KIT_PLANT" ] && { S7_PLANTED="the after-kills snapshot taken right after the last kill, before indexing finished"; }
  s7_arm S7.12 || return $S7_RC
  # the clean reference: one uninterrupted run of the same fixture
  if ! s7_ready 3600; then s7_fail S7.12 "the clean reference run: $S7_WHY"; return 1; fi
  out="$(kq "$S7_IX" snapshot clean-ref --files-only 2>&1)"
  echo "  | clean reference: $(s6_last "$out")"
  # ten kills, five of the index helper and five of the app, each at a random moment (the seed is printed)
  seed="$(date +%s)"
  echo "  | seed $seed (the moments are int(3 + rand() * 20) seconds into indexing, srand(seed + kill number))"
  s7_rearm S7.12 || return $S7_RC
  S7_OUT="seed $seed"
  for n in 1 2 3 4 5; do
    s7_kill index "$n" "$seed" || break
    s7_kill app "$((n + 5))" "$seed" || break
  done
  s7_save kill-s7-12 "$S7_OUT"
  # indexing finishes on its own; the per-file state equals the clean run
  if [ -z "$KIT_PLANT" ]; then
    out="$(kq "$S7_IX" wait done 7200 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $rc = 0 ] || s7_why "indexing did not finish on its own after the kills (kit-index.sh wait done exited $rc)"
  fi
  kq "$S7_IX" snapshot after-kills --files-only >/dev/null 2>&1
  out="$(kq "$S7_IX" diff clean-ref after-kills 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed -n '1,20p' | sed 's/^/  | /'
  [ $rc = 0 ] || s7_why "the per-file state after the kills differs from the clean run (kit-index.sh diff clean-ref after-kills exited $rc)"
  bad="$(awk -F'\t' '!/^#/ && $2 != "done" && $3 + 0 > 0 { n++ } END { print n + 0 }' "$S7_SNAPS/after-kills.tsv" 2>/dev/null)"
  [ "$bad" = 0 ] || s7_why "$bad files that are not done hold passages (a half-read file)"
  s7_done S7.12 "ten kills at random moments of indexing the mini mix, five of the index helper and five of the app (seed $seed), left the index passing the integrity check after each; indexing finished on its own and the final per-file state (path, status, passage count) equalled the uninterrupted run, with no passage on a file that is not done"
}
check_S7_12() { s7_run s7_check_12; }

# ---- S7.13: the model helpers quit when idle ------------------------------------------------------

# s7_helper_modes : the modes (encode, index) of the helpers listed by `kit-launch.sh pids --names`.
s7_helper_modes() { kq "$S7_LD" pids --names 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "encode" || $i == "index") print $i }' | sort -u | tr '\n' ' '; }

s7_check_13() {
  local m45 m80 e0 e45 e80 file name late=80 out rc
  [ -n "$KIT_PLANT" ] && { late=30; S7_PLANTED="the idle helper required gone at 30 s instead of 80 s"; }
  s7_arm S7.13 || return $S7_RC
  # the index helper: after the last indexing work
  if ! s7_ready 3600; then s7_fail S7.13 "$S7_WHY"; return 1; fi
  echo "  | indexing ended; helpers now: $(s7_helper_modes)"
  sleep 45
  m45="$(s7_helper_modes)"
  sleep $((late - 45 > 0 ? late - 45 : 0))
  m80="$(s7_helper_modes)"
  [ "${m80#*index}" = "$m80" ] || s7_why "an index helper is still listed ${late} s after the last indexing work (kit-launch.sh pids --names)"
  echo "  | index helper: listed at 45 s: $( [ "${m45#*index}" != "$m45" ] && echo yes || echo no ), at $late s: $( [ "${m80#*index}" != "$m80" ] && echo yes || echo no )"
  # the encode helper: after a search
  file="$(s7_paths_under minimix done | sed -n 1p)"
  name="${file##*/}"
  out="$(kq "$S7_SEARCH" "$name" --wait-for "$file" --within 30 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  | kit-search: /'
    s7_why "the search that starts the encode helper failed (kit-search.sh exited $rc: $(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }'))"
  fi
  e0="$(s7_helper_modes)"
  sleep 45
  e45="$(s7_helper_modes)"
  sleep $((late - 45 > 0 ? late - 45 : 0))
  e80="$(s7_helper_modes)"
  [ "${e80#*encode}" = "$e80" ] || s7_why "an encode helper is still listed ${late} s after the last search (kit-launch.sh pids --names)"
  echo "  | encode helper: listed right after the search: $( [ "${e0#*encode}" != "$e0" ] && echo yes || echo no ), at 45 s: $( [ "${e45#*encode}" != "$e45" ] && echo yes || echo no ), at $late s: $( [ "${e80#*encode}" != "$e80" ] && echo yes || echo no )"
  s7_done S7.13 "the index helper and the encode helper were each gone at 80 s of idleness after the last indexing work and the last search (the readings at 45 s are printed: a helper may still be listed then)"
}
check_S7_13() { s7_run s7_check_13; }

# ---- S7.14: Launch at login in Settings -------------------------------------------------------------

# s7_switch : on, off or absent for the switch "Launch at login" in the Settings dump S6_DUMP.
s7_switch() {
  printf '%s\n' "$S6_DUMP" | awk '/label="Launch at login"/ { f = 1; if ($0 ~ /value="(1|true|on)"/) on = 1 } END { if (!f) print "absent"; else if (on) print "on"; else print "off" }'
}

s7_check_14() {
  local note="The shortcut works only while Sesame is running." out rc s
  [ -n "$KIT_PLANT" ] && { note="The shortcut works only while Sesame runs."; S7_PLANTED="the note expected as \"The shortcut works only while Sesame runs.\""; }
  rm -f "$S7_MARK"
  out="$(recipe_setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  s7_recipe_done S7.14 "$rc" "$out" || return $S7_RC
  s6_press "$S7_AX" "Settings…" || { s7_fail S7.14 "pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S7.14 NEEDS-A-PERSON $S6_ERR"; return 0; fi
  [ $rc = 0 ] || { s7_fail S7.14 "Settings did not open"; return 1; }
  # Launch at login and its note are in the Indexing section only
  settings_section Indexing || { s7_fail S7.14 "the Settings window cannot be put on its Indexing section, so the switch Launch at login cannot be read"; return 1; }
  s6b_settings
  s6_save s7-14-fresh
  s="$(s7_switch)"
  [ "$s" = on ] || s7_why "on a fresh start the switch \"Launch at login\" is $s, it must be on"
  case "$S6_DUMP" in *"$note"*) ;; *) s7_why "Settings does not show the exact note \"$note\"" ;; esac
  kq "$S7_AX" click "Launch at login" >/dev/null 2>&1 || s7_why "pressing \"Launch at login\" failed"
  sleep 2
  s6b_settings
  s="$(s7_switch)"
  [ "$s" = off ] || s7_why "the switch is $s after the first press, expected off"
  kq "$S7_AX" click "Launch at login" >/dev/null 2>&1 || s7_why "pressing \"Launch at login\" a second time failed"
  sleep 2
  s6b_settings
  s="$(s7_switch)"
  [ "$s" = on ] || s7_why "the switch is $s after the second press, expected on"
  S7_DIRTY=1
  s7_done S7.14 "on a fresh start Settings showed Launch at login on with the exact note \"The shortcut works only while Sesame is running.\", and pressing the switch turned it off and on again; the registration macOS holds is S7.18"
}
check_S7_14() { s7_run s7_check_14; }

# ---- S7.15: random operations against the kit's own listing ----------------------------------------

# s7_rel <folder name> : stdin the paths, stdout the paths relative to that folder, sorted; a build that indexes photos
# only keeps the photo extensions (the kit's listing counts every supported extension).
s7_rel() {
  local keep="$2"
  sed "s|^.*/$1/||" | { if [ "$keep" = photos ]; then awk 'tolower($0) ~ /\.(jpe?g|png|heic|webp|tiff?|gif)$/'; else cat; fi; } | LC_ALL=C sort
}

s7_check_15() {
  local seed out rc keep=all want got dup round=0 bogus="" ops="" path phrase old
  [ -n "$KIT_PLANT" ] && { bogus="s7-planted-path.jpg"; S7_PLANTED="a path that does not exist added to the kit's expected listing"; }
  s7_to_ready S7.15 || return $S7_RC
  if ! s7_kind_indexed document && ! s7_kind_indexed pdf; then keep=photos; fi
  for seed in 11 12 13; do
    round=$((round + 1))
    out="$(kq "$S7_FX" mutate random 15 --seed "$seed" "$S7_MIX" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $rc = 0 ] || { s7_fail S7.15 "kit-fixtures.sh mutate random 15 --seed $seed exited $rc: $(s6_last "$out")"; return 1; }
    ops="$ops"$'\n'"$out"
    sleep 35
    got="$(s7_paths_under minimix | s7_rel minimix "$keep")"
    want="$(kq "$S7_FX" expect listing minimix 2>&1 | awk '!/^(LISTING|MISSING|EXTRA|WRONG|FORMATS|TARGETS|SCREENSHOTS)/ && NF' | s7_rel minimix "$keep")"
    [ -z "$bogus" ] || want="$want"$'\n'"$bogus"
    dup="$(printf '%s\n' "$got" | uniq -d | sed -n 1p)"
    [ -z "$dup" ] || s7_why "round $round (seed $seed): the path $dup appears twice in the index"
    if [ "$(printf '%s\n' "$got" | LC_ALL=C sort -u)" != "$(printf '%s\n' "$want" | LC_ALL=C sort -u)" ]; then
      s7_why "round $round (seed $seed): kit-index.sh under differs from kit-fixtures.sh expect listing: $(LC_ALL=C comm -3 <(printf '%s\n' "$got" | LC_ALL=C sort -u) <(printf '%s\n' "$want" | LC_ALL=C sort -u) | head -5 | tr '\n' ' ')"
    fi
    echo "  | round $round (seed $seed): $(printf '%s\n' "$got" | awk 'NF { n++ } END { print n + 0 }') paths in the index, $(printf '%s\n' "$want" | awk 'NF { n++ } END { print n + 0 }') in the listing"
  done
  # the phrase of every created or edited text file finds it, the previous phrase no longer does (the kinds this build indexes)
  if s7_kind_indexed document; then
    printf '%s\n' "$ops" | awk '
      $1 == "CREATED" || $1 == "EDITED" { p = $2 }
      $1 == "PHRASE" && p != "" { sub(/^PHRASE /, ""); prev[p] = cur[p]; cur[p] = $0 }
      END { for (k in cur) print k "\t" cur[k] "\t" prev[k] }' > "$KIT_ROOT/run/s7-phrases.tsv"
    while IFS=$'\t' read -r path phrase old; do
      [ -f "$path" ] || continue
      kq "$S7_SEARCH" "$phrase" --wait-for "$path" --within 30 >/dev/null 2>&1 || s7_why "the current phrase of $path does not find it within 30 s"
      [ -z "$old" ] || kq "$S7_SEARCH" "$old" --expect-absent "$path" >/dev/null 2>&1 || s7_why "the previous phrase of $path still lists it"
    done < "$KIT_ROOT/run/s7-phrases.tsv"
  else
    echo "  | noted: the index holds no document files (photos only at slice 2), so the unique phrases of created and edited text files are not looked for (slice 4)"
  fi
  s7_done S7.15 "after three rounds of 15 random operations (seeds 11, 12 and 13), each followed by 35 s, kit-index.sh under equalled kit-fixtures.sh expect listing as a set of paths and no path appeared twice"
}
check_S7_15() { s7_run s7_check_15; }

# ---- S7.16: the status item's label in each state --------------------------------------------------

s7_check_16() {
  local out rc
  [ -n "$KIT_PLANT" ] && { S7_PLANTED="the Ready label expected under the state name Readyy"; }
  rm -f "$S7_MARK"
  out="$(recipe_fresh_throttled 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe fresh-throttled: /'
  s7_recipe_done S7.16 "$rc" "$out" || return $S7_RC
  s7_wait_state downloading 60 || s7_why "downloading: the status item never named the download (it reads \"$S7_LABEL\")"
  [ "$(s7_state_of "$S7_LABEL")" != empty ] || s7_why "downloading: the status item's accessibility label is empty (the VoiceOver label)"
  echo "  | downloading: label \"$S7_LABEL\""
  rm -f "$S7_MARK"
  s7_arm S7.16 || return $S7_RC
  s7_wait_state indexing 120 || s7_why "indexing: the status item never named indexing (it reads \"$S7_LABEL\")"
  [ "$(s7_state_of "$S7_LABEL")" != empty ] || s7_why "indexing: the status item's accessibility label is empty (the VoiceOver label)"
  echo "  | indexing: label \"$S7_LABEL\""
  s6_press "$S7_AX" "Pause indexing" || s7_why "pressing \"Pause indexing\" failed"
  s7_wait_state paused 20 || s7_why "paused: the status item never named the pause (it reads \"$S7_LABEL\")"
  [ "$(s7_state_of "$S7_LABEL")" != empty ] || s7_why "paused: the status item's accessibility label is empty (the VoiceOver label)"
  echo "  | paused: label \"$S7_LABEL\""
  s6_press "$S7_AX" "Resume indexing" || s7_why "pressing \"Resume indexing\" failed"
  s7_ready 3600
  if [ -n "$KIT_PLANT" ]; then
    s7_why "ready: the label is expected under the state name Readyy"
  else
    s7_wait_state ready 60 || s7_why "ready: the status item never named Ready (it reads \"$S7_LABEL\")"
  fi
  [ "$(s7_state_of "$S7_LABEL")" != empty ] || s7_why "ready: the status item's accessibility label is empty (the VoiceOver label)"
  echo "  | ready: label \"$S7_LABEL\""
  s7_done S7.16 "the status item had a non-empty accessibility label naming the state in Downloading, Indexing, Paused and Ready (the VoiceOver label)"
}
check_S7_16() { s7_run s7_check_16; }

# ---- S7.18: Launch at login really registers with macOS ---------------------------------------------

# s7_login_item <name> : `kit-privacy.sh login-item` once; S7_OUT holds the answer (present and enabled, present and
# disabled, absent or unreadable), the output is saved as login-item-<name>.txt. Status 0 read; 3 a person-step; 4 not valid.
s7_login_item() {
  local out rc
  S7_OUT=""
  admin_session || { S7_ERR="administrator rights were not given (kit-perms.sh ask-admin was refused)"; return 3; }
  out="$(kq "$S7_PRIV" login-item 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  s7_save "login-item-$1" "$out"
  S7_OUT=""
  [ $rc = 0 ] || { S7_ERR="$(s6_pick "$out")"; return $rc; }
  case "$out" in *"CONTROL login-item OK"*) ;; *) S7_ERR="the control (an absent identifier reads absent) did not hold: $(s6_last "$out")"; return 4 ;; esac
  S7_OUT="$(printf '%s\n' "$out" | awk '$0 == "present and enabled" || $0 == "present and disabled" || $0 == "absent" || $0 == "unreadable" { a = $0 } END { print a }')"
  return 0
}

s7_check_18() {
  local out rc want_on="present and enabled"
  [ -n "$KIT_PLANT" ] && { want_on="present and disabled"; S7_PLANTED="the switch on read as present and disabled"; }
  admin_session || { echo "CHECK S7.18 NEEDS-A-PERSON administrator rights were not given (kit-perms.sh ask-admin was refused)"; return 0; }
  rm -f "$S7_MARK"
  out="$(recipe_setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  s7_recipe_done S7.18 "$rc" "$out" || return $S7_RC
  S7_DIRTY=1
  s6_press "$S7_AX" "Settings…" || { s7_fail S7.18 "pressing \"Settings…\" in the status item's menu failed"; return 1; }
  s6b_settings || { s7_fail S7.18 "Settings did not open"; return 1; }
  # the switch Launch at login is in the Indexing section only
  settings_section Indexing || { s7_fail S7.18 "the Settings window cannot be put on its Indexing section, so the switch Launch at login cannot be pressed"; return 1; }
  # the switch is on (the default)
  s7_login_item on; rc=$?
  [ $rc = 3 ] && { echo "CHECK S7.18 NEEDS-A-PERSON $S7_ERR"; return 0; }
  [ $rc = 4 ] && { echo "RERUN S7.18 not valid: $S7_ERR"; return 4; }
  [ $rc = 0 ] || { s7_fail S7.18 "kit-privacy.sh login-item exited $rc: $S7_ERR"; return 1; }
  case "$S7_OUT" in
    "present and enabled"|"present and disabled")
      [ "$S7_OUT" = "$want_on" ] || s7_why "with the switch on the login item reads \"$S7_OUT\", expected an entry for Sesame that is enabled" ;;
    *) echo "CHECK S7.18 NEEDS-A-PERSON with the switch on, sfltool dumpbtm shows ${S7_OUT:-nothing} for Sesame's identifier in this ad hoc signed bundle (design U6): whether Launch at login registers with macOS is for the person to check (S7.N3)"; return 0 ;;
  esac
  # the switch is turned off in Settings: the entry is absent or disabled
  kq "$S7_AX" click "Launch at login" >/dev/null 2>&1 || s7_why "pressing \"Launch at login\" (off) failed"
  sleep 4
  s7_login_item off; rc=$?
  [ $rc = 3 ] && { echo "CHECK S7.18 NEEDS-A-PERSON $S7_ERR"; return 0; }
  [ $rc = 4 ] && { echo "RERUN S7.18 not valid: $S7_ERR"; return 4; }
  case "$S7_OUT" in
    absent|"present and disabled") ;;
    *) s7_why "with the switch off the login item reads \"${S7_OUT:-nothing}\", expected absent or disabled" ;;
  esac
  # turned on again: enabled again
  kq "$S7_AX" click "Launch at login" >/dev/null 2>&1 || s7_why "pressing \"Launch at login\" (on again) failed"
  sleep 4
  s7_login_item on-again; rc=$?
  [ $rc = 3 ] && { echo "CHECK S7.18 NEEDS-A-PERSON $S7_ERR"; return 0; }
  [ $rc = 4 ] && { echo "RERUN S7.18 not valid: $S7_ERR"; return 4; }
  [ "$S7_OUT" = "present and enabled" ] || s7_why "with the switch on again the login item reads \"${S7_OUT:-nothing}\", expected enabled"
  # the kit's copy of the app registered the login item on its first run (and macOS keeps the record after the run is
  # deleted): turn the switch off again through the app, so this run leaves none behind
  kq "$S7_AX" click "Launch at login" >/dev/null 2>&1 || s7_why "pressing \"Launch at login\" (off again, to unregister at the end) failed"
  sleep 4
  s7_login_item final; rc=$?
  [ $rc = 3 ] && { echo "CHECK S7.18 NEEDS-A-PERSON $S7_ERR"; return 0; }
  [ $rc = 4 ] && { echo "RERUN S7.18 not valid: $S7_ERR"; return 4; }
  case "$S7_OUT" in
    absent|"present and disabled") ;;
    *) s7_why "after the switch was turned off again at the end the login item still reads \"${S7_OUT:-nothing}\": the run left a login item behind (System Settings, General, Login Items)" ;;
  esac
  s7_done S7.18 "with the switch on kit-privacy.sh login-item showed an enabled entry for Sesame's identifier, with the switch off it was absent or disabled, and on again it was enabled again, and turned off once more at the end it was absent or disabled, so the run leaves no login item behind; the control (an absent identifier reads absent) held each time; the readings are saved as login-item-on.txt, login-item-off.txt, login-item-on-again.txt and login-item-final.txt"
}
check_S7_18() { s7_run s7_check_18; }

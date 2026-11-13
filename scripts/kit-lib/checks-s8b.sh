#!/bin/bash
# The slice 3 checks S8.1, S8.2 and S8.3 of S8 (feature map S8, (a) Files are only read; plan-3-tasks t9). Sourced by kit-run.sh
# after common.sh and recipes.sh (its checks-*.sh glob), never run. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...`
# line and uses the exit codes of every kit script; a precondition that does not hold prints `RERUN <id> not valid: <reason>` and
# returns 4. All three read what the one observed session of the tree recipe left (checks-s8session.sh, t8): each calls
# `s8_close_window <its id>` first, which runs the session once, stops the prompts watcher and the observers, and notes the id in
# run/window-ids only while the window is open. An exit 3 of it is a person step (NEEDS-A-PERSON), any other failure a RERUN.
# With KIT_PLANT=1 (kit-run.sh --plant S8.1) S8.1 flips one byte of a picked file and must print `CHECK S8.1 FAIL planted: ...`.
# S8.2 and S8.3 are planted at product level by the self-runs (verify.md, Self-run), not here.

# s8b_no_trace <id> : the recipe ran without a trace (run/recipe holds `tree -`). A missing administrator session is a person
# step (the plain sentence, never a password prompt: kit-perms.sh ask-admin is the one place that asks); with the session in hand
# the run is simply not valid, because no trace was started before the app. Returns what the check returns.
s8b_no_trace() {
  if sudo -n true 2>/dev/null; then
    echo "RERUN $1 not valid: prep tree --trace s8 first (run/recipe holds tree -, so no file trace ran before the app)"
    return 4
  fi
  echo "NEEDS A PERSON: administrator rights: macOS only lets an administrator watch which files Sesame uses; run scripts/kit-perms.sh ask-admin from a Terminal window you can type in, then prep tree --trace s8"
  echo "CHECK $1 NEEDS-A-PERSON administrator rights for the file trace (said plainly first, asked once): run scripts/kit-perms.sh ask-admin, then prep tree --trace s8"
  return 0
}

# s8b_save_sums <compare output> : the comparison as sums-after.txt and the recipe's snapshot as sums-before.txt in the evidence
# folder (feature map S8, Evidence). Never an error: the evidence is a copy, the verdict does not depend on it.
s8b_save_sums() {
  local dir
  dir="$(kit_evidence_dir)"
  { [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; } || return 0
  printf '%s\n' "$1" > "$dir/sums-after.txt"
  [ -f "$KIT_ROOT/run/sums/sums-before.tsv" ] && cp "$KIT_ROOT/run/sums/sums-before.tsv" "$dir/sums-before.txt"
  return 0
}

# s8b_flip_one_byte : the plant of S8.1. Flips the first byte of the first non-empty file of the picked folders in place and puts
# the old size and modified time back, so only the checksum can show it. Prints the file. The old byte, the path and the time are
# kept under run/ for s8b_restore_byte. Status 1 when there is no file to change.
s8b_flip_one_byte() {
  local list entry f="" orig new=58
  list="$(tree_pick_list "$KIT_LIB/gate-matrix.csv")" || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    f="$(find "$KIT_ROOT/fixtures/$entry" -type f -size +0c ! -name .DS_Store 2>/dev/null | LC_ALL=C sort | sed -n 1p)"
    [ -z "$f" ] || break
  done <<EOF
$list
EOF
  [ -n "$f" ] || return 1
  orig="$(dd if="$f" bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ -n "$orig" ] || return 1
  [ "$orig" != 58 ] || new=59
  touch -r "$f" "$KIT_ROOT/run/s8b-plant.ref" || return 1
  printf '%s\n' "$f" > "$KIT_ROOT/run/s8b-plant.path"
  printf '%s\n' "$orig" > "$KIT_ROOT/run/s8b-plant.byte"
  printf "\\x$new" | dd of="$f" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null || return 1
  touch -r "$KIT_ROOT/run/s8b-plant.ref" "$f"
  printf '%s\n' "$f"
}

# s8b_restore_byte : puts back the byte s8b_flip_one_byte changed, and the modified time, and removes its notes.
s8b_restore_byte() {
  local f orig
  f="$(cat "$KIT_ROOT/run/s8b-plant.path" 2>/dev/null)"
  orig="$(cat "$KIT_ROOT/run/s8b-plant.byte" 2>/dev/null)"
  [ -n "$f" ] && [ -n "$orig" ] || return 1
  printf "\\x$orig" | dd of="$f" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null
  touch -r "$KIT_ROOT/run/s8b-plant.ref" "$f"
  rm -f "$KIT_ROOT/run/s8b-plant.path" "$KIT_ROOT/run/s8b-plant.byte" "$KIT_ROOT/run/s8b-plant.ref"
  return 0
}

# ---- S8.1: every file in the picked folders is as before ---------------------------------------

check_S8_1() {
  local rc out ds unch n why trace line path w who planted=""
  s8_close_window S8.1; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.1 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.1 not valid: the S8 session could not be run (s8_close_window exited $rc)"; return 4 ;;
  esac
  if [ -n "$KIT_PLANT" ]; then
    planted="$(s8b_flip_one_byte)" || { echo "RERUN S8.1 not valid: there is no picked file to plant a changed byte in"; return 4; }
  fi
  out="$(kq "$KIT_SCRIPTS/kit-sums.sh" compare sums-before 2>&1 </dev/null)"; rc=$?
  [ -z "$planted" ] || s8b_restore_byte
  printf '%s\n' "$out"
  s8b_save_sums "$out"
  n="$(printf '%s\n' "$out" | awk '/^(CHANGED|ADDED|REMOVED) / { n++ } END { print n + 0 }')"
  case $rc in
    0|1) ;;
    *) echo "RERUN S8.1 not valid: $(printf '%s\n' "$out" | tail -1)"; return 4 ;;
  esac
  ds="$(printf '%s\n' "$out" | awk '/^(CHANGED|ADDED|REMOVED) / && /\.DS_Store( (checksum|size|mtime))*$/')"
  if [ -n "$ds" ]; then
    trace="$(tree_trace_name)"
    echo ".DS_Store lines, listed apart (Finder and Spotlight write them too, so the process matters; they still count as differences):"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ -z "$trace" ]; then
        echo "  $line (NOTE no trace ran for this session, so the process that wrote it cannot be named)"
        continue
      fi
      path="$(printf '%s\n' "$line" | sed -E 's/^(CHANGED|ADDED|REMOVED) //; s/( (checksum|size|mtime))+$//')"
      w="$(kq "$KIT_SCRIPTS/kit-trace.sh" writes "$trace" --under "$KIT_ROOT/fixtures/$path" 2>&1 </dev/null)"
      who="$(printf '%s\n' "$w" | awk '$1 == "WRITE" { print $2 }' | sort -u | tr '\n' ' ')"
      if [ -n "$who" ]; then
        echo "  $line (the trace shows a write to it by: $who)"
      else
        echo "  $line (the trace shows no write to it by a process named Sesame* or git: likely Finder or Spotlight)"
      fi
    done <<EOF
$ds
EOF
  fi
  if [ $rc = 0 ]; then
    unch="$(printf '%s\n' "$out" | awk '/^UNCHANGED [0-9]+ files$/ { print; exit }')"
    if [ -n "$unch" ]; then
      echo "CHECK S8.1 PASS $unch in the picked folders (hidden files and .git included; sums-before was taken by the recipe before Start indexing and the window closed first)"
      return 0
    fi
    echo "RERUN S8.1 not valid: kit-sums.sh compare exited 0 without an UNCHANGED <n> files line"
    return 4
  fi
  if [ "$n" = 0 ]; then
    echo "RERUN S8.1 not valid: kit-sums.sh compare exited 1 with no CHANGED, ADDED or REMOVED line: $(printf '%s\n' "$out" | tail -1)"
    return 4
  fi
  why="$(printf '%s\n' "$out" | awk '/^(CHANGED|ADDED|REMOVED) / { print; k++ } k >= 5 { exit }' | tr '\n' ';')"
  if [ -n "$planted" ]; then
    echo "CHECK S8.1 FAIL planted: one byte of $planted was flipped, size and modified time kept: $why"
  else
    echo "CHECK S8.1 FAIL $n difference(s) in the picked folders after the session: $why"
  fi
  return 1
}

# ---- S8.2: the trace shows no write under a picked folder ------------------------------------------

check_S8_2() {
  local rc wrc trace list entry out found="" n who sdir control=0
  s8_close_window S8.2; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.2 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.2 not valid: the S8 session could not be run (s8_close_window exited $rc)"; return 4 ;;
  esac
  trace="$(tree_trace_name)"
  if [ -z "$trace" ]; then s8b_no_trace S8.2; return $?; fi
  list="$(tree_pick_list "$KIT_LIB/gate-matrix.csv" 2>&1)" || { echo "RERUN S8.2 not valid: the pick list could not be made: $(printf '%s\n' "$list" | tail -1)"; return 4; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    out="$(kq "$KIT_SCRIPTS/kit-trace.sh" writes "$trace" --under "$KIT_ROOT/fixtures/$entry" 2>&1 </dev/null)"; wrc=$?
    [ $wrc = 0 ] || { echo "RERUN S8.2 not valid: $(printf '%s\n' "$out" | tail -1)"; return 4; }
    found="$found$(printf '%s\n' "$out" | awk '$1 == "WRITE"')"$'\n'
  done <<EOF
$list
EOF
  n="$(printf '%s' "$found" | awk 'NF { c++ } END { print c + 0 }')"
  who="$(printf '%s' "$found" | awk '$1 == "WRITE" { c[$2]++ } END { for (p in c) printf "%s %d; ", p, c[p] }')"
  # the positive control: the trace can see writes, because SesameHelper writes index.sqlite in Sesame's own folder
  sdir="$(kq "$KIT_SCRIPTS/kit-launch.sh" where 2>&1 </dev/null | sed -n 1p)"
  if [ -n "$sdir" ]; then
    out="$(kq "$KIT_SCRIPTS/kit-trace.sh" writes "$trace" --under "$sdir" --by SesameHelper 2>&1 </dev/null)"; wrc=$?
    [ $wrc = 0 ] || { echo "RERUN S8.2 not valid: $(printf '%s\n' "$out" | tail -1)"; return 4; }
    control="$(printf '%s\n' "$out" | awk '$1 == "WRITE" && /\/index\.sqlite/ { c++ } END { print c + 0 }')"
  fi
  echo "writes by SesameHelper to index.sqlite in Sesame's folder (positive control): $control"
  if [ "$n" != 0 ]; then
    printf '%s' "$found" | awk 'NF' | head -12
    echo "CHECK S8.2 FAIL $n write(s) under the picked folders, by: $who(a write, unlink, rename, setattr or xattr write by Sesame, SesameHelper or git; git ls-files must write nothing, .git/index.lock included)"
    return 1
  fi
  if [ "$control" = 0 ]; then
    echo "RERUN S8.2 not valid: the trace shows no write by SesameHelper to index.sqlite in Sesame's folder (positive control), so its silence under the picked folders proves nothing"
    return 4
  fi
  echo "CHECK S8.2 PASS no write, unlink, rename, setattr or xattr write by Sesame, SesameHelper or git under any picked folder (trace $trace; positive control: $control writes by SesameHelper to index.sqlite)"
  return 0
}

# ---- S8.3: only the helper's reader opens a picked file --------------------------------------------

check_S8_3() {
  local rc trace list entry who out n done_opens app=0 helper=0 star=0 gitn=0 other seen="" sdir bundle
  s8_close_window S8.3; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.3 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.3 not valid: the S8 session could not be run (s8_close_window exited $rc)"; return 4 ;;
  esac
  trace="$(tree_trace_name)"
  if [ -z "$trace" ]; then s8b_no_trace S8.3; return $?; fi
  done_opens="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^opens=/) { sub(/^opens=/, "", $i); print $i; exit } }' "$KIT_ROOT/run/s8-activity-done" 2>/dev/null)"
  [ -n "$done_opens" ] || { echo "RERUN S8.3 not valid: run/s8-activity-done is missing or has no opens= field"; return 4; }
  [ "$done_opens" != 0 ] || { echo "RERUN S8.3 not valid: no Enter open happened inside the window"; return 4; }
  list="$(tree_pick_list "$KIT_LIB/gate-matrix.csv" 2>&1)" || { echo "RERUN S8.3 not valid: the pick list could not be made: $(printf '%s\n' "$list" | tail -1)"; return 4; }
  out="$(kq "$KIT_SCRIPTS/kit-trace.sh" by-process "$trace" 2>&1 </dev/null)"; rc=$?
  echo "events by process (trace $trace):"
  printf '%s\n' "$out"
  [ $rc = 0 ] || { echo "RERUN S8.3 not valid: $(printf '%s\n' "$out" | tail -1)"; return 4; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    for who in Sesame SesameHelper 'Sesame*' git; do
      out="$(kq "$KIT_SCRIPTS/kit-trace.sh" opens "$trace" --under "$KIT_ROOT/fixtures/$entry" --by "$who" 2>&1 </dev/null)"; rc=$?
      [ $rc = 0 ] || { echo "RERUN S8.3 not valid: $(printf '%s\n' "$out" | tail -1)"; return 4; }
      n="$(printf '%s\n' "$out" | awk '$1 == "regular" && $2 == "files:" { print $3; exit }')"
      case "$n" in
        ""|*[!0-9]*) echo "RERUN S8.3 not valid: kit-trace.sh opens printed no count of regular files for $who under $entry"; return 4 ;;
      esac
      case "$who" in
        Sesame) app=$((app + n)) ;;
        SesameHelper) helper=$((helper + n)) ;;
        'Sesame*') star=$((star + n)) ;;
        git) gitn=$((gitn + n)) ;;
      esac
      if [ "$who" = Sesame ] && [ "$n" != 0 ]; then
        seen="$seen$(printf '%s\n' "$out" | awk -v e="$entry" '/^  regular file opened / { print "  " e ":" $0 }')"$'\n'
      fi
    done
  done <<EOF
$list
EOF
  other=$((star - helper - app))
  [ "$other" -ge 0 ] || other=0
  echo "regular files opened under the picked folders: Sesame (the app) $app, SesameHelper $helper, git $gitn (git is listed apart, never counted as Sesame: it reads .git/* and .gitignore of picked repos), any other process $other"
  # the opens the app is allowed to make, listed: its settings, models and index, and its own bundle
  sdir="$(kq "$KIT_SCRIPTS/kit-launch.sh" where 2>&1 </dev/null | sed -n 1p)"
  bundle="$(s8_bundle)"
  if [ -n "$sdir" ]; then
    echo "opens by the app of its own settings, models and index under $sdir:"
    out="$(kq "$KIT_SCRIPTS/kit-trace.sh" opens "$trace" --under "$sdir" --by Sesame 2>&1 </dev/null)"
    printf '%s\n' "$out"
  fi
  echo "opens by the app of its own bundle under $bundle:"
  out="$(kq "$KIT_SCRIPTS/kit-trace.sh" opens "$trace" --under "$bundle" --by Sesame 2>&1 </dev/null)"
  printf '%s\n' "$out"
  if [ "$app" != 0 ] || [ "$other" != 0 ]; then
    printf '%s' "$seen" | awk 'NF' | head -20
    echo "CHECK S8.3 FAIL the app (Sesame) opened $app regular file(s) and any other process $other under the picked folders; only SesameHelper, and git listed apart, may open a picked file"
    return 1
  fi
  if [ "$helper" = 0 ]; then
    echo "RERUN S8.3 not valid: no helper open of a picked file in the trace"
    return 4
  fi
  echo "CHECK S8.3 PASS the app (Sesame) opened no regular file under any picked folder; SesameHelper opened $helper, git (listed apart) $gitn, no other process (trace $trace, $done_opens Enter opens in the window)"
  return 0
}

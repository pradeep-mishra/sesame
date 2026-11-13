#!/bin/bash
# The slice 3 checks S8.7 and S8.9 of S8 (feature map S8, (c) Nothing leaves the Mac and (d) Nothing records what was searched or
# opened; plan-3-tasks t11). Sourced by kit-run.sh after common.sh and recipes.sh (its checks-*.sh glob), never run. Each check prints
# one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line and uses the exit codes of every kit script; a precondition that does not hold
# prints `RERUN <id> not valid: <reason>` and returns 4. Both read what the one observed session of the tree recipe left
# (checks-s8session.sh, t8): the check calls `s8_close_window <id>` first, directly or through s8_net_summary, which runs the session
# once, stops the prompts watcher and the observers and notes the id in run/window-ids only while the window is open. An exit 3 of it
# is a person step (NEEDS-A-PERSON), any other failure a RERUN.
# s8_net_summary [<id>] is the body of S8.7, and S8.13 (checks-s8.sh) and S6.13 (t12) call it too. s8d_query_scan <id> is the scan
# of S8.9, which S8.13 reads. Each runs once and saves its result under run/ (s8-net-summary.txt/.rc, s8-query-scan.txt/.rc; the
# .rc line is `<exit> <session key>`, the key says which session made it), so a second call reads the result and S8.13 can tell that the
# two results belong to one session. The evidence goes to the scripts' own names (net-control-<name>.txt, trace-net-<name>.txt,
# scan-controls.txt, schema.txt); the scans of S8.9 are called without kq, so the script saves its own evidence file.
# With KIT_PLANT=1 (kit-run.sh --plant S8.7) the runner turns a PASS into FAIL planted: these two checks have no plant of their own.

# s8d_session_key : which session the saved results belong to: the recipe line and the activity line of the session (the times in it
# differ for every session). Prints nothing but the two lines joined by `|`.
s8d_session_key() {
  printf '%s|%s\n' "$(cat "$KIT_ROOT/run/recipe" 2>/dev/null)" "$(cat "$KIT_ROOT/run/s8-activity-done" 2>/dev/null)"
}

# s8d_field <file> <key> : the value of `<key>=` in the file (the first one), nothing when there is none.
s8d_field() {
  awk -v k="$2" '{ for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }' "$1" 2>/dev/null
}

# s8d_plant_at <plants file> <k> : the at=<epoch.ms> of the plant `n=<k>`, nothing when there is none.
s8d_plant_at() {
  awk -v k="$2" '$1 == "PLANT" {
    n = ""; at = ""
    for (i = 1; i <= NF; i++) { if ($i ~ /^n=/) n = substr($i, 3); if ($i ~ /^at=/) at = substr($i, 4) }
    if (n == k) { print at; exit }
  }' "$1" 2>/dev/null
}

# s8d_num <text> : status 0 when it is a plain number (digits, one optional fraction).
s8d_num() { printf '%s\n' "$1" | awk '/^[0-9]+(\.[0-9]+)?$/ { ok = 1 } END { exit ok ? 0 : 1 }'; }

# s8d_earlier <a> <b> : status 0 when a is earlier than b (both numbers, a < b).
s8d_earlier() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 < b + 0) ? 0 : 1 }'; }

# s8d_window_order <plants file> <s8-activity-done> <observers-closed-at> : the rules that make an S8.7 run valid. Prints the reason
# and returns 4 when one fails: the plants file does not hold exactly three plants, plant 2 is not earlier than indexing-done-at (it
# was not planted mid-indexing), plant 3 is not later than last-open-at (it was not planted after the last of the 50 searches and 20
# opens), or observers-closed-at is earlier than last-open-at (something closed the window early). Prints nothing and returns 0 when
# every rule holds.
s8d_window_order() {
  local plants="$1" act="$2" closed="$3" n p2 p3 done_at last_open closed_at
  [ -s "$plants" ] || { echo "there is no plants file ($plants): no planted connection was made, three are needed"; return 4; }
  n="$(awk '$1 == "PLANT" { c++ } END { print c + 0 }' "$plants")"
  [ "$n" = 3 ] || { echo "$plants holds $n planted connection(s), not exactly three (before the app, mid-indexing, after the last open)"; return 4; }
  [ -s "$act" ] || { echo "there is no run/s8-activity-done ($act): the session's activity did not finish"; return 4; }
  [ -s "$closed" ] || { echo "there is no run/observers-closed-at ($closed): the observers were not closed by s8_close_window"; return 4; }
  p2="$(s8d_plant_at "$plants" 2)"; p3="$(s8d_plant_at "$plants" 3)"
  done_at="$(s8d_field "$act" indexing-done-at)"; last_open="$(s8d_field "$act" last-open-at)"
  closed_at="$(awk 'NF { print $1; exit }' "$closed")"
  for n in "$p2" "$p3" "$done_at" "$last_open" "$closed_at"; do
    s8d_num "$n" || { echo "a time is missing or is not a number (plant 2 '$p2', plant 3 '$p3', indexing-done-at '$done_at', last-open-at '$last_open', observers-closed-at '$closed_at')"; return 4; }
  done
  s8d_earlier "$p2" "$done_at" || { echo "plant 2 (at $p2) was not made before indexing was done (indexing-done-at $done_at): it was not planted mid-indexing"; return 4; }
  s8d_earlier "$last_open" "$p3" || { echo "plant 3 (at $p3) was not made after the last open (last-open-at $last_open): it was not planted after the last of the searches and opens"; return 4; }
  if s8d_earlier "$closed_at" "$last_open"; then
    echo "run/observers-closed-at ($closed_at) is earlier than last-open-at ($last_open): something closed the window early"
    return 4
  fi
  return 0
}

# s8d_failure_lines : stdin the text of s8_net_summary; the lines that are a failure: PRODUCT (a destination other than the mirror),
# OUTSIDE (outside the mirror log's window plus 2 s), AFTER-LAST (after the last model request), BYTES (1,000,000 or more sent) and
# every NET line of `kit-trace.sh net --except <mirror>` (a connection to anything but the mirror), not its closing summary line.
s8d_failure_lines() {
  awk '/^(PRODUCT|OUTSIDE|AFTER-LAST|BYTES) / { print; next } $1 == "NET" && $2 != "CONNECTIONS" { print }'
}

# s8d_destinations : stdin the output of `kit-trace.sh net`; how many NET lines name a connection (the `NET CONNECTIONS (...)` line
# that closes the output is a summary, not a connection).
s8d_destinations() {
  awk '$1 == "NET" && $2 != "CONNECTIONS" { n++ } END { print n + 0 }'
}

# s8d_net_status <exit of kit-net.sh summary> <exit of kit-trace.sh net> <destination lines> : the status of s8_net_summary. 4 when
# either tool says the run is not valid or ends with a code it does not define; 1 when the summary found a product failure or the
# trace lists a destination; else 0.
s8d_net_status() {
  if [ "$1" = 4 ] || [ "$2" = 4 ]; then return 4; fi
  case "$1" in 0|1) ;; *) return 4 ;; esac
  [ "$2" = 0 ] || return 4
  case "$3" in ""|*[!0-9]*) return 4 ;; esac
  if [ "$1" = 1 ] || [ "$3" -gt 0 ]; then return 1; fi
  return 0
}

# s8d_rows <file> : how many non-blank lines the file holds (0 for a missing file).
s8d_rows() { awk 'NF { n++ } END { print n + 0 }' "$1" 2>/dev/null || echo 0; }

# s8d_order_check <order-before.txt> <order-mid.txt> <order-after.txt> : the order test of S8.9 (iv). Prints the reason and returns 4
# when a list is missing or order-before.txt holds fewer than 3 rows (identical empty lists prove nothing: a broken index gives the
# same); returns 1 and names the list when it is not identical, row for row, to order-before.txt; returns 0 when all three are.
s8d_order_check() {
  local b="$1" m="$2" a="$3" f n
  for f in "$b" "$m" "$a"; do
    [ -f "$f" ] || { echo "the order list $(basename "$f") is missing"; return 4; }
  done
  n="$(s8d_rows "$b")"
  [ "$n" -ge 3 ] || { echo "the order test list is shorter than 3 rows ($(basename "$b") holds $n)"; return 4; }
  for f in "$m" "$a"; do
    cmp -s "$b" "$f" || { echo "$(basename "$f") is not identical, row for row, to $(basename "$b")"; return 1; }
  done
  return 0
}

# s8d_save <name> <exit> <text> : the result under run/ for a second call and for S8.13: run/<name>.txt holds the text, run/<name>.rc
# `<exit> <session key>`.
s8d_save() {
  printf '%s\n' "$3" > "$KIT_ROOT/run/$1.txt" || return 1
  printf '%s %s\n' "$2" "$(s8d_session_key)" > "$KIT_ROOT/run/$1.rc"
}

# s8d_load <name> : status 0 and the saved exit in S8D_RC, the saved text in S8D_TEXT; status 1 when none is saved.
s8d_load() {
  local line
  [ -f "$KIT_ROOT/run/$1.rc" ] && [ -f "$KIT_ROOT/run/$1.txt" ] || return 1
  line="$(cat "$KIT_ROOT/run/$1.rc")"
  S8D_RC="${line%% *}"
  S8D_TEXT="$(cat "$KIT_ROOT/run/$1.txt")"
}

# s8d_same_session : status 0 when both saved results (run/s8-query-scan.rc and run/s8-net-summary.rc) carry the key of the session
# that is running now (run/recipe and the activity line), else the reason and status 4.
s8d_same_session() {
  local now scan net
  now="$(s8d_session_key)"
  scan="$(cut -s -d' ' -f2- "$KIT_ROOT/run/s8-query-scan.rc" 2>/dev/null)"
  net="$(cut -s -d' ' -f2- "$KIT_ROOT/run/s8-net-summary.rc" 2>/dev/null)"
  case "$now" in tree*) ;; *) echo "run/recipe does not hold a tree session"; return 4 ;; esac
  if [ -z "$scan" ] || [ -z "$net" ]; then
    echo "the scan result or the net summary was not saved in this session (run/s8-query-scan.rc, run/s8-net-summary.rc)"
    return 4
  fi
  if [ "$scan" != "$now" ] || [ "$net" != "$now" ]; then
    echo "the query scan and the net summary were not made in the same session (run/recipe and the session's activity differ)"
    return 4
  fi
  return 0
}

# ---- the network summary of the closed window (S8.7, S8.13, S6.13) -----------------------------

# s8_net_summary [<id>] : s8_close_window <id>, then (once; a second call reads the saved result) `kit-net.sh summary <name> --mirror
# <host:port> --requests <the mirror log>` and `kit-trace.sh net <name> --except <host:port>` on the closed window. Prints both and
# saves them (run/s8-net-summary.txt and, in the evidence folder, net-summary-<name>.txt and trace-net-<name>.txt); the text is also in
# S8_NET_TEXT. Status 0 clean; 1 a product failure (a destination other than the mirror, a connection outside the mirror log's window
# plus 2 s, 1,000,000 bytes or more sent, a connection after the last model request); 3 a person step (the line says which); 4 the run
# is not valid (the fs_usage trace missed a plant or dropped events, an input is missing; a RERUN or `not valid` line says why). It
# prints no CHECK line: the caller owns the verdict.
s8_net_summary() {
  local id="${1:-S8.7}" run="$KIT_ROOT/run" rc trace mirror sout src tout trc dests status text dir
  S8_NET_TEXT=""
  s8_close_window "$id"; rc=$?
  [ $rc = 0 ] || return $rc
  if s8d_load s8-net-summary; then
    S8_NET_TEXT="$S8D_TEXT"
    printf '%s\n' "$S8_NET_TEXT"
    return "$S8D_RC"
  fi
  trace="$(tree_trace_name)"
  if [ -z "$trace" ]; then
    if sudo -n true 2>/dev/null; then
      echo "RERUN $id not valid: prep tree --trace s8 first (run/recipe holds tree -, so no network observer ran before the app)"
      return 4
    fi
    echo "NEEDS A PERSON: administrator rights: macOS only lets an administrator watch which connections Sesame makes; run scripts/kit-perms.sh ask-admin from a Terminal window you can type in, then prep tree --trace s8"
    return 3
  fi
  if [ ! -f "$run/mirror-host" ]; then
    echo "RERUN $id not valid: there is no run/mirror-host, so the model mirror's address is not known (the session did not use the mirror)"
    return 4
  fi
  mirror="$(sed -e 's#^[A-Za-z]*://##' -e 's#/.*$##' "$run/mirror-host")"
  sout="$(kq "$KIT_SCRIPTS/kit-net.sh" summary "$trace" --mirror "$mirror" --requests "$run/mirror-requests.log" 2>&1 </dev/null)"; src=$?
  tout="$(kq "$KIT_SCRIPTS/kit-trace.sh" net "$trace" --except "$mirror" 2>&1 </dev/null)"; trc=$?
  dests="$(printf '%s\n' "$tout" | s8d_destinations)"
  s8d_net_status "$src" "$trc" "$dests"; status=$?
  text="$(printf '== kit-net.sh summary %s --mirror %s --requests <the mirror log> (exit %s)\n%s\n== kit-trace.sh net %s --except %s (exit %s)\n%s' "$trace" "$mirror" "$src" "$sout" "$trace" "$mirror" "$trc" "$tout")"
  s8d_save s8-net-summary "$status" "$text"
  dir="$(kit_evidence_dir)"
  if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
    printf '%s\n' "$sout" > "$dir/net-summary-$trace.txt"
    printf '%s\n' "$tout" > "$dir/trace-net-$trace.txt"
  fi
  S8_NET_TEXT="$text"
  printf '%s\n' "$text"
  return $status
}

# ---- the query scan of the closed window (S8.9, S8.13) ----------------------------------------

# s8d_query_scan <id> : s8_close_window <id>, then (once; a second call reads the saved result) `kit-privacy.sh query-scan
# run/markers.txt` over the 50 markers s8_activity wrote. Status 0 and the scan's own exit in S8D_SCAN_RC and its output in
# S8D_SCAN_OUT; 3 a person step (printed); 4 not valid (a RERUN line says why). The script is called without kq so that it saves its
# own scan-controls.txt.
s8d_query_scan() {
  local id="${1:-S8.9}" run="$KIT_ROOT/run" rc
  S8D_SCAN_OUT=""
  S8D_SCAN_RC=""
  s8_close_window "$id"; rc=$?
  [ $rc = 0 ] || return $rc
  if s8d_load s8-query-scan; then
    S8D_SCAN_OUT="$S8D_TEXT"
    S8D_SCAN_RC="$S8D_RC"
    return 0
  fi
  if [ ! -s "$run/markers.txt" ]; then
    echo "RERUN $id not valid: run/markers.txt is missing or empty (s8_activity writes the 50 markers before the searches)"
    return 4
  fi
  S8D_SCAN_OUT="$("$KIT_SCRIPTS/kit-privacy.sh" query-scan "$run/markers.txt" 2>&1 </dev/null)"; S8D_SCAN_RC=$?
  s8d_save s8-query-scan "$S8D_SCAN_RC" "$S8D_SCAN_OUT"
  return 0
}

# ---- S8.7: the product's network use is the mirror's, inside its window -----------------------

check_S8_7() {
  local rc trace reason ids fails n sent seen
  s8_net_summary S8.7; rc=$?
  case $rc in
    0|1) ;;
    3) echo "CHECK S8.7 NEEDS-A-PERSON the network observers need a person (see the lines above): administrator rights for the file and network trace, said plainly first and asked once by kit-perms.sh ask-admin"; return 0 ;;
    *)
      reason="$(printf '%s\n' "$S8_NET_TEXT" | awk '/^(NOT VALID|not valid): / { sub(/^(NOT VALID|not valid): /, ""); print; exit }')"
      echo "RERUN S8.7 not valid: ${reason:-the network summary could not be made (s8_net_summary exited $rc; see the lines above)}"
      return 4 ;;
  esac
  trace="$(tree_trace_name)"
  reason="$(s8d_window_order "$KIT_ROOT/run/net/$trace.plants" "$KIT_ROOT/run/s8-activity-done" "$KIT_ROOT/run/observers-closed-at")" || {
    echo "RERUN S8.7 not valid: $reason"
    return 4
  }
  ids="$(awk 'NF { printf "%s ", $1 }' "$KIT_ROOT/run/window-ids" 2>/dev/null)"
  echo "ids run in the window: ${ids:-none}"
  echo "the session used the model mirror $(sed -e 's#^[A-Za-z]*://##' -e 's#/.*$##' "$KIT_ROOT/run/mirror-host" 2>/dev/null), not the real host (the one real-host run is a person-run, S8.N5)"
  sent="$(printf '%s\n' "$S8_NET_TEXT" | awk '$1 == "SENT" { print $2; exit }')"
  seen="$(printf '%s\n' "$S8_NET_TEXT" | awk '$1 == "PLANT" && $3 == "seen-by" { printf "%s:%s ", $2, $4 }')"
  fails="$(printf '%s\n' "$S8_NET_TEXT" | s8d_failure_lines | head -12)"
  if [ $rc = 1 ] || [ -n "$fails" ]; then
    n="$(printf '%s\n' "$fails" | awk 'NF { c++ } END { print c + 0 }')"
    echo "CHECK S8.7 FAIL $n network failure(s), a destination other than the mirror, a connection outside the mirror log's window plus 2 s, 1,000,000 bytes or more sent, or a connection after the last model request: $(printf '%s\n' "$fails" | tr '\n' ';')"
    return 1
  fi
  echo "CHECK S8.7 PASS every connection of the product is to the mirror and inside its request window, ${sent:-0} bytes sent (under 1,000,000), none after the last model request; the three planted connections were seen by fs_usage (seen-by ${seen:-none}); trace $trace"
  return 0
}

# ---- S8.9: nothing records what was searched or opened ----------------------------------------

check_S8_9() {
  local rc run="$KIT_ROOT/run" opens n oout orc qrc qout src sout drc dout why="" places
  s8_close_window S8.9; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.9 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.9 not valid: the S8 session could not be run (s8_close_window exited $rc)"; return 4 ;;
  esac
  opens="$(s8d_field "$run/s8-activity-done" opens)"
  if [ -z "$opens" ] || [ "$opens" = 0 ]; then
    echo "RERUN S8.9 not valid: no Enter open happened inside the window (run/s8-activity-done says opens=${opens:-nothing})"
    return 4
  fi
  n="$(s8d_rows "$run/markers.txt")"
  if [ "$n" -lt 50 ]; then
    echo "RERUN S8.9 not valid: run/markers.txt holds $n markers, the 50 searches of s8_activity write 50"
    return 4
  fi
  oout="$(s8d_order_check "$run/order-before.txt" "$run/order-mid.txt" "$run/order-after.txt")"; orc=$?
  if [ $orc = 4 ]; then
    echo "RERUN S8.9 not valid: $oout"
    return 4
  fi
  s8d_query_scan S8.9; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.9 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.9 not valid: the query scan could not be made (s8d_query_scan exited $rc)"; return 4 ;;
  esac
  qrc="$S8D_SCAN_RC"; qout="$S8D_SCAN_OUT"
  printf '%s\n' "$qout"
  case $qrc in 0|1) ;; *) echo "RERUN S8.9 not valid: query-scan exited $qrc: $(printf '%s\n' "$qout" | tail -1)"; return 4 ;; esac
  sout="$("$KIT_SCRIPTS/kit-privacy.sh" schema-scan 2>&1 </dev/null)"; src=$?
  printf '%s\n' "$sout"
  case $src in 0|1) ;; *) echo "RERUN S8.9 not valid: schema-scan exited $src: $(printf '%s\n' "$sout" | tail -1)"; return 4 ;; esac
  dout="$(kq "$KIT_SCRIPTS/kit-index.sh" diff before-opens after-opens 2>&1 </dev/null)"; drc=$?
  printf '%s\n' "$dout"
  case $drc in 0|1) ;; *) echo "RERUN S8.9 not valid: kit-index.sh diff exited $drc: $(printf '%s\n' "$dout" | tail -1)"; return 4 ;; esac
  [ $qrc = 0 ] || why="a query marker was found: $(s8_findings "$qout" | tr '\n' ' ')"
  [ $src = 0 ] || why="${why:+$why; }a forbidden name in the schema: $(printf '%s\n' "$sout" | awk '/^forbidden: / { print; k++ } k >= 12 { exit }' | tr '\n' ' ')"
  [ $drc = 0 ] || why="${why:+$why; }the index changed because of the opens (kit-index.sh diff before-opens after-opens is different): $(printf '%s\n' "$dout" | tail -3 | tr '\n' ' ')"
  [ $orc = 0 ] || why="${why:+$why; }the order changed with the opens: $oout"
  if [ -n "$why" ]; then
    echo "CHECK S8.9 FAIL $why"
    return 1
  fi
  places="$(printf '%s\n' "$qout" | awk '/^no marker found in [0-9]+ places/ { print $5; exit }')"
  echo "CHECK S8.9 PASS $n searches with unique markers and $opens Enter opens: no marker in ${places:-the} places the scan covers, no forbidden name in the schema, the index snapshots before and after the opens are identical, and the order list ($(s8d_rows "$run/order-before.txt") rows) is identical after five opens of result 3 and after one open of another result"
  return 0
}

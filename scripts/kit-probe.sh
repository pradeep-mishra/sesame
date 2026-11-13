#!/bin/bash
# kit-probe.sh opens <n> [--busy] [--bar-ms N]
# kit-probe.sh searches <n> --set <distinct20|distinct20b> [--cold] [--busy] [--bar-ms N]
# kit-probe.sh ping
#
# Timing runs against the bars of S2 (verify.md, Kit scripts; guesses K3, K18, K27): the panel opens in under 200 ms
# (hotkey to shown), a warm search returns its first ranked list in under 500 ms (last key to ranked), the first search
# after idle in under 2 s. The numbers come from the app's probe file ($KIT_ROOT/run/probe.jsonl, one JSON line per
# event, `ns` the monotonic uptime in nanoseconds); every open and every search is cross-checked by the kit's own poll,
# which does not use the accessibility tree and stamps the same clock (kit-lib/pixelpoll.swift):
#   opens     a poll of the window list for Sesame's windows at least 900 points wide (watch-windows);
#   searches  a ScreenCaptureKit stream of the one Sesame panel window, by window id, never the screen (watch-list):
#             the list area is the left 45 percent of the panel below its top 18 percent; "rows" are three or more
#             bands of ink there. The poll stamps the LAST change of the list area after the last key that is followed
#             by 700 ms of stillness (the ranked list replaces keyword rows in place, so the settled list is the ranked
#             one) [guess G45].
# `--bar-ms N` replaces the bar, to show the verdict can go over.
#
# Verdict: the probe's figure at or over the bar is OVER BAR; else a gap between the probe and the poll over 50 ms is
# not valid (exit 4, never a pass); else a poll figure over the bar is OVER BAR; else WITHIN BAR. The closing line is
#   opens|searches median <ms> max <ms> bar <ms> ms WITHIN BAR|OVER BAR       (the probe's figures)
# Every shortcut post sits inside the kit window this script opens and closes (Kit safety: pn_kit_open and
# pn_kit_close in kit-lib/panel.sh, closed on every path); typing goes to Sesame only, once it is frontmost.
# --busy checks before the first action and after the last that `kit-index.sh status` shows pending or partial files,
# else exit 4 `not valid: indexer was not busy`. --cold needs no SesameHelper process alive and the last probe event
# at least 70 s old, else exit 4.
# Exit codes: 0 within the bar; 1 over the bar, or no reading could be taken (the line says which part is missing);
# 2 usage; 3 a person-step is missing (NEEDS A PERSON: ...); 4 the run is not valid: rerun.
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/panel.sh"

PROBE="$KIT_ROOT/run/probe.jsonl"
POLL_PID="$KIT_ROOT/run/pids/probe-poll.pid"
POLL_LOG="$KIT_ROOT/run/probe-poll.log"
BAR_OPEN=200
BAR_SEARCH=500
BAR_COLD=2000
MAX_GAP=50
PP=""
WORK=""

usage() {
  cat >&2 <<'EOF'
usage: kit-probe.sh opens <n> [--busy] [--bar-ms N]
       kit-probe.sh searches <n> --set <distinct20|distinct20b> [--cold] [--busy] [--bar-ms N]
       kit-probe.sh ping
EOF
}

# ---- the processes and files this script starts, and what it leaves behind ----------------------------

poll_stop() {
  local pid
  pid="$(cat "$POLL_PID" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    sleep 0.2
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$POLL_PID"
  return 0
}

# probe_cleanup : the poll stopped, the panel and the kit window closed, the work folder removed; every path ends here.
probe_cleanup() {
  poll_stop
  pn_close_panel >/dev/null 2>&1
  pn_kit_close
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}

# poll_start <log> <command...> : the poll in the background, its pid in run/pids/probe-poll.pid.
poll_start() {
  local log="$1"
  shift
  poll_stop
  mkdir -p "$KIT_ROOT/run/pids" || return 1
  : > "$log"
  "$@" > "$log" 2>/dev/null </dev/null &
  echo "$!" > "$POLL_PID"
}

# ---- the probe file ------------------------------------------------------------------------------------

probe_count() {
  if [ -f "$PROBE" ]; then wc -l < "$PROBE" | tr -d ' '; else echo 0; fi
}

# probe_events <lines to skip> : "<event> <ticket> <ns>" per probe line after the first <skip> lines.
probe_events() {
  [ -f "$PROBE" ] || return 0
  tail -n +"$(($1 + 1))" "$PROBE" | awk '
    {
      e = ""; t = ""; n = ""
      if (match($0, /"event" *: *"[a-z]+"/)) { e = substr($0, RSTART, RLENGTH); sub(/.*: *"/, "", e); sub(/"$/, "", e) }
      if (match($0, /"ticket" *: *-?[0-9]+/)) { t = substr($0, RSTART, RLENGTH); sub(/.*: */, "", t) }
      if (match($0, /"ns" *: *[0-9]+/)) { n = substr($0, RSTART, RLENGTH); sub(/.*: */, "", n) }
      if (e != "" && n != "") print e, (t == "" ? 0 : t), n
    }'
}

# ---- preconditions ---------------------------------------------------------------------------------------

# preflight <needs screen 0|1> : status 0 when the app runs and the tools compile. Else one line and 1, 3 or 4.
preflight() {
  local out rc
  kit_need_ps || return 1
  if [ -z "$(kit_pid_of app)" ]; then
    echo "RERUN not valid: Sesame is not running (scripts/kit-launch.sh start), so there is nothing to time"
    return 4
  fi
  PP="$(kit_tool pixelpoll)" || { echo "the kit's Swift tool pixelpoll did not compile; see $KIT_ROOT/run/bin/pixelpoll.log"; return 1; }
  kit_tool keytool >/dev/null || { echo "the kit's Swift tool keytool did not compile; see $KIT_ROOT/run/bin/keytool.log"; return 1; }
  if [ "$1" = 1 ]; then
    out="$("$PP" screen-trusted 2>&1)"; rc=$?
    if [ $rc != 0 ]; then
      echo "NEEDS A PERSON: Screen Recording for this terminal"
      echo "how: System Settings, Privacy and Security, Screen Recording, turn on ${TERM_PROGRAM:-the terminal app that runs the checks}"
      return 3
    fi
  fi
  return 0
}

# pending_files : files rows still pending or partial (what a busy indexer has left), from kit-index.sh status.
pending_files() {
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-index.sh" status 2>&1 | awk '($2 == "pending" || $2 == "partial") && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }'
}

# busy_check <when> : status 0 when files are pending or partial; else one line and 4.
busy_check() {
  local n
  n="$(pending_files)"
  if [ "$n" -gt 0 ]; then echo "indexer busy $1: $n files pending or partial"; return 0; fi
  echo "RERUN not valid: indexer was not busy $1 (no file pending or partial in kit-index.sh status)"
  return 4
}

# ---- the figures ---------------------------------------------------------------------------------------

# summarize <rows file> : "probe_median probe_max poll_median poll_max gap_max" from lines "probe_ms poll_ms gap_ms".
summarize() {
  awk '
    function med(arr, n,   i, j, t) {
      for (i = 2; i <= n; i++) { t = arr[i]; for (j = i - 1; j >= 1 && arr[j] > t; j--) arr[j + 1] = arr[j]; arr[j + 1] = t }
      return (n % 2) ? arr[(n + 1) / 2] : (arr[n / 2] + arr[n / 2 + 1]) / 2
    }
    { n++; p[n] = $1; q[n] = $2; if ($1 > pm) pm = $1; if ($2 > qm) qm = $2; if ($3 > gm) gm = $3 }
    END { if (n == 0) exit 1; printf "%.1f %.1f %.1f %.1f %.1f\n", med(p, n), pm, med(q, n), qm, gm }' "$1"
}

# save_jsonl <name> <file> : the file kept in the evidence folder as <name>.jsonl (never over an older one).
save_jsonl() {
  local dir f n=1
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/$1.jsonl"
  while [ -e "$f" ]; do n=$((n + 1)); f="$dir/$1-$n.jsonl"; done
  cp "$2" "$f" 2>/dev/null && echo "saved $f"
}

# finish <label> <bar ms> <rows file> <jsonl file> <evidence name> : the figures, the verdict, the exit code.
finish() {
  local label="$1" bar="$2" rows="$3" jsonl="$4" ename="$5" sum pmed pmax qmed qmax gmax verdict
  sum="$(summarize "$rows")" || { echo "RERUN not valid: no reading was taken"; return 4; }
  set -- $sum
  pmed="$1"; pmax="$2"; qmed="$3"; qmax="$4"; gmax="$5"
  save_jsonl "$ename" "$jsonl"
  echo "poll median $qmed ms max $qmax ms; largest gap between the probe and the poll $gmax ms (limit $MAX_GAP ms)"
  if awk -v v="$pmax" -v b="$bar" 'BEGIN { exit (v >= b) ? 0 : 1 }'; then
    verdict="OVER BAR"
  elif awk -v v="$gmax" -v b="$MAX_GAP" 'BEGIN { exit (v > b) ? 0 : 1 }'; then
    echo "RERUN not valid: the poll and the probe differ by $gmax ms, more than $MAX_GAP ms: the run is not a reading (guess K18)"
    return 4
  elif awk -v v="$qmax" -v b="$bar" 'BEGIN { exit (v >= b) ? 0 : 1 }'; then
    echo "NOTE the probe read under the bar but the poll read $qmax ms, over it: a poll over the bar fails the run (guess K18)"
    verdict="OVER BAR"
  else
    verdict="WITHIN BAR"
  fi
  echo "$label median $pmed ms max $pmax ms bar $bar ms $verdict"
  [ "$verdict" = "WITHIN BAR" ]
}

# ---- opens -----------------------------------------------------------------------------------------------

cmd_opens() {
  [ $# -ge 1 ] || { usage; return 2; }
  local n="$1" busy=0 bar="$BAR_OPEN" rc i base rows jsonl ev name
  shift
  case "$n" in ""|*[!0-9]*|0) usage; return 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --busy) busy=1; shift ;;
      --bar-ms) [ $# -ge 2 ] || { usage; return 2; }; case "$2" in ""|*[!0-9]*) usage; return 2 ;; esac; bar="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  preflight 0 || return $?
  WORK="$(mktemp -d "$KIT_TMP/kit-probe.XXXXXX")" || return 1
  trap 'probe_cleanup; exit 130' INT TERM HUP
  if [ "$busy" = 1 ]; then busy_check "before the first open" || { probe_cleanup; return 4; }; else sleep 5; fi
  poll_start "$POLL_LOG" "$PP" watch-windows Sesame --min-w 900
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -s "$POLL_LOG" ] && break
    sleep 0.2
  done
  base="$(probe_count)"
  for ((i = 1; i <= n; i++)); do
    pn_open_panel; rc=$?
    if [ $rc != 0 ]; then
      printf '%s\n' "$PN_OUT" | sed -n '1,2p'
      probe_cleanup
      if [ $rc = 3 ]; then return 3; fi
      echo "no reading: open $i of $n: the panel did not open"
      return 1
    fi
    sleep 0.4
    pn_close_panel
    sleep 0.4
  done
  poll_stop
  if [ "$busy" = 1 ]; then busy_check "after the last open" || { probe_cleanup; return 4; }; fi
  if [ ! -f "$PROBE" ]; then
    probe_cleanup
    echo "RERUN not valid: the probe file is missing: $PROBE (the app writes it when it is started by scripts/kit-launch.sh start)"
    return 4
  fi
  ev="$WORK/events"
  probe_events "$base" > "$ev"
  # per open: hotkey to the next shown (a hotkey that is not followed by shown closed the panel); the poll's first
  # "appeared" at or after that hotkey (20 ms of slack either way) is the cross-check
  awk -v want="$n" '
    FNR == NR {
      if ($1 == "hotkey") { h = $3 + 0; have = 1 }
      else if ($1 == "shown" && have) { c++; H[c] = h; S[c] = $3 + 0; have = 0 }
      next
    }
    $1 == "appeared" { split($2, a, "="); m++; A[m] = a[2] + 0 }
    END {
      if (c != want) { printf "ERR the probe file holds %d open times (hotkey then shown) for %d opens\n", c, want; exit 1 }
      j = 1
      for (i = 1; i <= c; i++) {
        while (j <= m && A[j] < H[i] - 20000000) j++
        if (j > m) { printf "ERR the window poll saw no window appear for open %d\n", i; exit 1 }
        printf "OPEN %d %.3f %.3f %.3f %.0f %.0f %.0f\n", i, (S[i] - H[i]) / 1e6, (A[j] - H[i]) / 1e6, (A[j] > S[i] ? A[j] - S[i] : S[i] - A[j]) / 1e6, H[i], S[i], A[j]
        j++
      }
    }' "$ev" "$POLL_LOG" > "$WORK/opens.out"; rc=$?
  if [ $rc != 0 ]; then
    probe_cleanup
    echo "RERUN not valid: $(sed 's/^ERR //' "$WORK/opens.out" | sed -n 1p)"
    return 4
  fi
  rows="$WORK/rows"; jsonl="$WORK/jsonl"
  awk '{ print $3, $4, $5 }' "$WORK/opens.out" > "$rows"
  awk '{ printf "{\"open\":%d,\"probe_ms\":%s,\"poll_ms\":%s,\"gap_ms\":%s,\"hotkey_ns\":%s,\"shown_ns\":%s,\"appeared_ns\":%s}\n", $2, $3, $4, $5, $6, $7, $8 }' "$WORK/opens.out" > "$jsonl"
  awk '{ printf "open %d: probe %s ms, poll %s ms, gap %s ms\n", $2, $3, $4, $5 }' "$WORK/opens.out"
  name="probe-opens-$n"; [ "$busy" = 1 ] && name="$name-busy"
  finish opens "$bar" "$rows" "$jsonl" "$name"; rc=$?
  probe_cleanup
  return $rc
}

# ---- searches --------------------------------------------------------------------------------------------

# load_queries <set> <n> : QUERIES (one per element). Status 2 on a bad set.
QUERIES=()
load_queries() {
  local file="$KIT_LIB/queries-$1.txt" line total=0
  QUERIES=()
  [ -f "$file" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ""|"#"*) continue ;; esac
    QUERIES+=("$line")
    total=$((total + 1))
  done < "$file"
  [ "$2" -le "$total" ]
}

# ready_wait <log> : status 0 once the list poll has printed its "ready" line (its first frame).
ready_wait() {
  local i
  for ((i = 0; i < 60; i++)); do
    awk '$1 == "ready" { f = 1 } END { exit f ? 0 : 1 }' "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# ranked_wait <skip lines> : status 0 once a ranked event is in the probe file after the last key event, within 10 s.
ranked_wait() {
  local i
  for ((i = 0; i < 100; i++)); do
    if probe_events "$1" | awk '$1 == "key" { got = 1; f = 0 } $1 == "ranked" && got { f = 1 } END { exit f ? 0 : 1 }'; then return 0; fi
    sleep 0.1
  done
  return 1
}

# analyze_search <events file> <list poll log> : "<probe ms> <poll ms> <gap ms> <keyword ms or -1>", else "ERR <why>" and 1.
# The probe's figure: the first ranked list after the last key, minus that key (the keyword line is an extra reading).
# The poll's figure: the last change of the list area after the last key that is followed by 700 ms of stillness,
# minus the same key; it must hold three or more bands (rows). The gap is between the two stamps.
analyze_search() {
  awk '
    FNR == NR {
      if ($1 == "key") { k = $3 + 0; r = 0; w = 0 }
      else if ($1 == "ranked" && k > 0 && !r) r = $3 + 0
      else if ($1 == "keyword" && k > 0 && !w) w = $3 + 0
      next
    }
    $1 == "frame" && k > 0 && !stopped {
      split($2, a, "="); ns = a[2] + 0
      b = -1
      for (x = 3; x <= NF; x++) if ($x ~ /^bands=/) { split($x, c, "="); b = c[2] + 0 }
      if (ns >= k) {
        if (last == 0 || ns - last < 700000000) { last = ns; lastb = b } else stopped = 1
      }
    }
    END {
      if (!r) { print "ERR no ranked event after the last key"; exit 1 }
      if (!last) { print "ERR the list poll saw no change of the list area after the last key"; exit 1 }
      if (lastb < 3) { printf "ERR the list area held %d bands, not rows, when it settled\n", lastb; exit 1 }
      d = (last > r ? last - r : r - last) / 1e6
      printf "%.3f %.3f %.3f %.3f\n", (r - k) / 1e6, (last - k) / 1e6, d, (w > 0 ? (w - k) / 1e6 : -1)
    }' "$1" "$2"
}

# search_once <query> <index> : in the open panel (the earlier text selected with Command+A, so typing replaces it), types
# the query, reads the probe and the list poll. Appends "probe poll gap" to $WORK/rows and a JSON line to $WORK/jsonl.
# Status 0 done; 1 no reading (a line says which part is missing); 3; 4. All 20 searches of a run share one open panel
# and one list poll, so the whole run fits the busy window of the indexer (the embedding of 40 photos).
search_once() {
  local q="$1" i="$2" rc base ev list out
  list="$WORK/list.log"
  if [ "$i" -gt 1 ]; then
    out="$(KIT_NO_EVIDENCE=1 "$PN_AX" key cmd+a 2>&1)"; rc=$?
    if [ $rc != 0 ]; then
      printf '%s\n' "$out" | sed -n '1,2p'
      [ $rc = 3 ] && return 3
      echo "no reading: search $i: the earlier text could not be selected"
      return 1
    fi
  fi
  base="$(probe_count)"
  out="$(KIT_NO_EVIDENCE=1 "$PN_AX" type "$q" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed -n '1,2p'
    [ $rc = 3 ] && return 3
    echo "no reading: search $i: typing the query was refused"
    return 1
  fi
  if ! ranked_wait "$base"; then
    if [ "$(probe_events "$base" | awk '$1 == "key" { n++ } END { print n + 0 }')" = 0 ]; then
      echo "no reading: search $i: the probe file shows no key event for the typed query: the search path does not write the probe yet"
    else
      echo "no reading: search $i: no ranked event within 10 s of the last key"
    fi
    return 1
  fi
  sleep 1
  ev="$WORK/events-$i"
  probe_events "$base" > "$ev"
  out="$(analyze_search "$ev" "$list")"; rc=$?
  if [ $rc != 0 ]; then
    echo "RERUN not valid: search $i: ${out#ERR }"
    return 4
  fi
  set -- $out
  echo "$1 $2 $3" >> "$WORK/rows"
  printf '{"search":%d,"query":"%s","probe_ms":%s,"poll_ms":%s,"gap_ms":%s,"keyword_ms":%s}\n' "$i" "${q//\"/\\\"}" "$1" "$2" "$3" "$4" >> "$WORK/jsonl"
  echo "search $i \"$q\": probe $1 ms, poll $2 ms, gap $3 ms$([ "$4" != -1 ] && echo ", keyword $4 ms")"
  return 0
}

cmd_searches() {
  [ $# -ge 1 ] || { usage; return 2; }
  local n="$1" set="" cold=0 busy=0 bar="" rc i name age ns last helpers
  shift
  case "$n" in ""|*[!0-9]*|0) usage; return 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) [ $# -ge 2 ] || { usage; return 2; }; set="$2"; shift 2 ;;
      --cold) cold=1; shift ;;
      --busy) busy=1; shift ;;
      --bar-ms) [ $# -ge 2 ] || { usage; return 2; }; case "$2" in ""|*[!0-9]*) usage; return 2 ;; esac; bar="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$set" in distinct20|distinct20b) ;; *) usage; return 2 ;; esac
  load_queries "$set" "$n" || { echo "the set $set holds fewer than $n queries"; usage; return 2; }
  if [ -z "$bar" ]; then if [ "$cold" = 1 ]; then bar="$BAR_COLD"; else bar="$BAR_SEARCH"; fi; fi
  preflight 1 || return $?
  if [ "$cold" = 1 ]; then
    helpers="$(kit_tree | awk '$3 != "app" { printf "%s(%s) ", $1, $3 }')"
    if [ -n "$helpers" ]; then
      echo "RERUN not valid: a helper is alive ($helpers); a cold search starts with no SesameHelper process"
      return 4
    fi
    last="$(probe_events 0 | awk 'END { print $3 }')"
    if [ -z "$last" ]; then
      echo "RERUN not valid: the probe file has no event to date the idle from"
      return 4
    fi
    ns="$("$PP" now)"
    age="$(awk -v a="$ns" -v b="$last" 'BEGIN { printf "%d", (a - b) / 1e9 }')"
    if [ "$age" -lt 70 ]; then
      echo "RERUN not valid: the last probe event is $age s old; a cold search needs at least 70 s of idle"
      return 4
    fi
    echo "cold: no helper alive and $age s since the last probe event"
  fi
  WORK="$(mktemp -d "$KIT_TMP/kit-probe.XXXXXX")" || return 1
  : > "$WORK/rows"; : > "$WORK/jsonl"
  trap 'probe_cleanup; exit 130' INT TERM HUP
  if [ "$busy" = 1 ]; then busy_check "before the first search" || { probe_cleanup; return 4; }; fi
  pn_open_panel; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$PN_OUT" | sed -n '1,2p'
    probe_cleanup
    if [ $rc = 3 ]; then return 3; fi
    echo "no reading: the panel did not open"
    return 1
  fi
  if ! pn_wait_sesame_front 3; then echo "no reading: $PN_OUT"; probe_cleanup; return 1; fi
  poll_start "$WORK/list.log" "$PP" watch-list --owner Sesame --min-w 900
  if ! ready_wait "$WORK/list.log"; then
    echo "RERUN not valid: the list poll read no frame of the panel within 12 s ($(sed -n 1p "$WORK/list.log"))"
    probe_cleanup
    return 4
  fi
  sleep 0.3
  for ((i = 1; i <= n; i++)); do
    search_once "${QUERIES[$((i - 1))]}" "$i"; rc=$?
    if [ $rc != 0 ]; then probe_cleanup; return $rc; fi
  done
  poll_stop
  if [ "$busy" = 1 ]; then busy_check "after the last search" || { probe_cleanup; return 4; }; fi
  name="probe-searches-$set"; [ "$cold" = 1 ] && name="$name-cold"; [ "$busy" = 1 ] && name="$name-busy"
  finish searches "$bar" "$WORK/rows" "$WORK/jsonl" "$name"; rc=$?
  probe_cleanup
  return $rc
}

# ---- ping ------------------------------------------------------------------------------------------------

cmd_ping() {
  [ $# = 0 ] || { usage; return 2; }
  local dir probe key pp out
  dir="$(dirname "$PROBE")"
  mkdir -p "$dir" || { echo "the probe file's folder cannot be made: $dir"; return 1; }
  probe="$PROBE.ping.$$"
  if ! : > "$probe" 2>/dev/null; then echo "the probe file path is not writable: $PROBE"; return 1; fi
  rm -f "$probe"
  echo "probe file path $PROBE is writable"
  key="$(kit_tool keytool)" || { echo "the kit's Swift tool keytool did not compile; see $KIT_ROOT/run/bin/keytool.log"; return 1; }
  echo "key tool compiles"
  pp="$(kit_tool pixelpoll)" || { echo "the kit's Swift tool pixelpoll did not compile; see $KIT_ROOT/run/bin/pixelpoll.log"; return 1; }
  echo "pixel-poll tool compiles"
  out="$("$pp" bands-selftest 2>&1)" || { echo "the pixel-poll band counter is wrong: $out"; return 1; }
  echo "$out"
  analyze_selftest || return 1
  return 0
}

# analyze_selftest : analyze_search on drawn probe and poll lines whose figures were worked out by hand (a last key at +100 ms,
# a keyword line at +150 ms, the ranked list at +400 ms, the settled list change at +420 ms, a later change after 2 s of
# stillness that must be ignored): it must read 300, 320, a gap of 20 and a keyword time of 50, and must refuse a run with
# no ranked line and a run whose settled list holds fewer than three bands.
analyze_selftest() {
  local dir ev list got b=5000000000000
  dir="$(mktemp -d "$KIT_TMP/kit-probe-self.XXXXXX")" || return 1
  ev="$dir/events"; list="$dir/list"
  printf 'key 1 %s\nkey 1 %s\nkeyword 1 %s\nranked 1 %s\n' "$b" "$((b + 100000000))" "$((b + 150000000))" "$((b + 400000000))" > "$ev"
  printf 'ready ns=%s width=960 height=704 bands=3 hash=1\nframe ns=%s bands=1 hash=2\nframe ns=%s bands=4 hash=3\nframe ns=%s bands=6 hash=4\nframe ns=%s bands=2 hash=5\n' \
    "$b" "$((b + 120000000))" "$((b + 180000000))" "$((b + 420000000))" "$((b + 2500000000))" > "$list"
  got="$(analyze_search "$ev" "$list")"
  if [ "$got" != "300.000 320.000 20.000 50.000" ]; then rm -rf "$dir"; echo "the search analysis is wrong: it read \"$got\" for 300 320 20 50"; return 1; fi
  printf 'key 1 %s\nkey 1 %s\n' "$b" "$((b + 100000000))" > "$ev"
  got="$(analyze_search "$ev" "$list")"
  case "$got" in "ERR no ranked event"*) ;; *) rm -rf "$dir"; echo "the search analysis took a reading with no ranked line: \"$got\""; return 1 ;; esac
  printf 'key 1 %s\nkey 1 %s\nranked 1 %s\n' "$b" "$((b + 100000000))" "$((b + 400000000))" > "$ev"
  printf 'frame ns=%s bands=5 hash=3\nframe ns=%s bands=2 hash=4\n' "$((b + 180000000))" "$((b + 420000000))" > "$list"
  got="$(analyze_search "$ev" "$list")"
  case "$got" in "ERR the list area held 2 bands"*) ;; *) rm -rf "$dir"; echo "the search analysis took a reading from a list of 2 bands: \"$got\""; return 1 ;; esac
  rm -rf "$dir"
  echo "search analysis selftest: 300/320/20/50 ms read right, a missing ranked line and a settled list under 3 bands refused"
}

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    opens) cmd_opens "$@" ;;
    searches) cmd_searches "$@" ;;
    ping) cmd_ping "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-probe "$@")" main "$@"
exit $?

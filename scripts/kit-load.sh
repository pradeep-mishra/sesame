#!/bin/bash
# kit-load.sh start <percent> | stop | measure <seconds> | ping
#
# The busy stand-in of the CPU rule (verify.md, Kit scripts and Not covered; S7.3, S7.17): a program that
# loads every core to about <percent> of the whole machine, and the CPU measured apart from Sesame.
#   start <percent>   stops any earlier stand-in, then starts one: one `yes` per core, all running while the
#                     duty cycle is on (every 0.2 s, <percent> percent of it busy; 100 is plain full load).
#                     Prints the epoch of the start (the time every S7 check counts from). The stand-in ends
#                     by itself after one hour. Exit 2 for a percent that is not 1 to 100.
#   stop              ends the stand-in and every process it started (nothing left over, every time; also
#                     the call `kit-reset.sh --cleanup` makes). Exit 0 whether one was running or not.
#   measure <seconds> once a second prints the whole-system CPU apart from Sesame's processes (one `top`
#                     sample over each second: the system figure minus the processes named Sesame*). The
#                     first two seconds after the start are the ramp-up and are printed, not judged. Exit 4
#                     (the run is invalid, never a pass) when no stand-in is running, or when any judged
#                     second is more than 20 points below the percent asked (start 90 must stay above 70,
#                     the figure of S7.3).
#   ping              starts a 100 percent stand-in for three seconds, measures it (the mean must be above
#                     50 percent), stops it and checks nothing is left; refuses (exit 4) when a stand-in is
#                     already running.
# Files under $KIT_ROOT/run: pids/kit-load.pid (the controller; kit-reset.sh --cleanup stops every
# pids/*.pid), load.yes (the pids of the current `yes` processes), load.percent, load.started (epoch).
# Exit codes: 0 done; 1 failed; 2 usage; 4 not valid (a precondition did not hold).
. "$(dirname "$0")/kit-lib/common.sh"

LOAD_PID="$KIT_ROOT/run/pids/kit-load.pid"
LOAD_YES="$KIT_ROOT/run/load.yes"
LOAD_PERCENT="$KIT_ROOT/run/load.percent"
LOAD_STARTED="$KIT_ROOT/run/load.started"
LOAD_OUT="$KIT_ROOT/run/load.out"
LOAD_LIMIT=3600
SKIP_NAME="Sesame"

usage() {
  cat >&2 <<'EOF'
usage: kit-load.sh start <percent> | stop | measure <seconds> | ping
       start <percent>     load every core to about <percent> of the machine (1 to 100); prints the epoch
       stop                end the stand-in and everything it started
       measure <seconds>   whole-system CPU apart from Sesame's processes, each second; exit 4 if short
       ping                a three-second busy run must measure above 50 percent
EOF
}

cores() {
  local n
  n="$(sysctl -n hw.logicalcpu 2>/dev/null)"
  case "$n" in ""|*[!0-9]*|0) n=1 ;; esac
  echo "$n"
}

load_alive() {
  local pid
  pid="$(cat "$LOAD_PID" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# is_yes <pid> : status 0 when the pid is a `yes` process (a reused pid is never killed by mistake).
is_yes() {
  case "$(ps -p "$1" -o comm= 2>/dev/null)" in
    yes|*/yes) return 0 ;;
  esac
  return 1
}

# ---- the stand-in -----------------------------------------------------------------------------------

# load_controller <percent> <cores> : runs in the background. Starts one `yes` per core and, below 100
# percent, ends them and starts them again so that <percent> of every 0.2 s is busy. The pids of the
# current `yes` processes are written to load.yes; a TERM ends them and the controller.
load_controller() {
  local pct="$1" n="$2" ys="" sp="" i busy idle
  load_kill_yes() {
    local p
    for p in $ys $sp; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    ys=""
    sp=""
    : > "$LOAD_YES"
  }
  # load_nap <seconds> : a sleep a TERM can cut short.
  load_nap() {
    sleep "$1" &
    sp=$!
    wait "$sp" 2>/dev/null
    sp=""
  }
  load_spawn() {
    ys=""
    i=0
    while [ "$i" -lt "$n" ]; do
      yes >/dev/null 2>&1 &
      ys="$ys $!"
      i=$((i + 1))
    done
    printf '%s\n' $ys > "$LOAD_YES.tmp" && mv -f "$LOAD_YES.tmp" "$LOAD_YES"
  }
  trap 'load_kill_yes; exit 0' TERM INT HUP
  if [ "$pct" -ge 100 ]; then
    load_spawn
    while [ "$SECONDS" -lt "$LOAD_LIMIT" ]; do
      load_nap 1
    done
  else
    busy="$(awk -v p="$pct" 'BEGIN { printf "%.3f", p * 0.002 }')"
    idle="$(awk -v p="$pct" 'BEGIN { printf "%.3f", (100 - p) * 0.002 }')"
    while [ "$SECONDS" -lt "$LOAD_LIMIT" ]; do
      load_spawn
      load_nap "$busy"
      load_kill_yes
      load_nap "$idle"
    done
  fi
  load_kill_yes
  exit 0
}

cmd_stop() {
  local pid kids p running=0 i
  pid="$(cat "$LOAD_PID" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    running=1
    kids="$(kit_descendants "$pid")"
    kill -TERM "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    for p in $kids; do
      is_yes "$p" && kill -9 "$p" 2>/dev/null
    done
  fi
  # A controller that was killed without its trap leaves its `yes` processes: the file names them.
  if [ -f "$LOAD_YES" ]; then
    for p in $(cat "$LOAD_YES" 2>/dev/null); do
      if is_yes "$p"; then
        running=1
        kill -9 "$p" 2>/dev/null
      fi
    done
  fi
  rm -f "$LOAD_PID" "$LOAD_YES" "$LOAD_YES.tmp" "$LOAD_PERCENT" "$LOAD_STARTED"
  if [ "$running" = 1 ]; then
    echo "busy stand-in stopped"
  else
    echo "no busy stand-in was running"
  fi
  return 0
}

cmd_start() {
  local pct="$1" n pid i
  [ $# = 1 ] || { usage; return 2; }
  case "$pct" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ "$pct" -ge 1 ] && [ "$pct" -le 100 ] || { usage; return 2; }
  if load_alive; then
    echo "an earlier busy stand-in ran: replacing it"
  fi
  cmd_stop >/dev/null
  n="$(cores)"
  mkdir -p "$KIT_ROOT/run/pids" || return 1
  printf '%s\n' "$pct" > "$LOAD_PERCENT"
  ( load_controller "$pct" "$n" ) >"$LOAD_OUT" 2>&1 </dev/null &
  pid=$!
  disown 2>/dev/null
  printf '%s\n' "$pid" > "$LOAD_PID"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$LOAD_YES" ] && break
    sleep 0.1
  done
  if [ ! -s "$LOAD_YES" ] || ! load_alive; then
    echo "the busy stand-in did not start: $(cat "$LOAD_OUT" 2>/dev/null)"
    cmd_stop >/dev/null
    return 1
  fi
  date +%s > "$LOAD_STARTED"
  echo "busy stand-in started: $pct percent on $n cores (controller pid $pid), ends by itself after $LOAD_LIMIT s"
  echo "epoch $(cat "$LOAD_STARTED")"
  return 0
}

# ---- measure ----------------------------------------------------------------------------------------

# sample_one : one second of the whole machine. Prints "<apart> <system> <Sesame>": the whole-system CPU
# apart from Sesame's processes, the whole-system CPU, and Sesame's share of it (all percent of the machine).
# Status 1 and a reason when top gives nothing readable.
sample_one() {
  local out stat n
  out="$(top -l 2 -s 1 -n 30 -o cpu -stats pid,command,cpu 2>&1)" || {
    echo "top failed: $out"
    return 1
  }
  stat="$(printf '%s\n' "$out" | awk -v skip="$SKIP_NAME" -f "$KIT_LIB/loadstat.awk")" || {
    echo "top printed no CPU usage line: $out"
    return 1
  }
  n="$(cores)"
  printf '%s\n' "$stat" | awk -v n="$n" '{ sk = $2 / n; a = $1 - sk; if (a < 0) a = 0; printf "%.1f %.1f %.1f\n", a, $1, sk }'
}

cmd_measure() {
  local secs="$1" pct floor started i line apart sys ses now judged=0 low=0 min="" sum=0 mark
  [ $# = 1 ] || { usage; return 2; }
  case "$secs" in ""|*[!0-9]*|0*) usage; return 2 ;; esac
  [ "$secs" -le 3600 ] || { usage; return 2; }
  if ! load_alive; then
    echo "not valid: no busy stand-in is running (scripts/kit-load.sh start <percent> first)"
    return 4
  fi
  pct="$(cat "$LOAD_PERCENT" 2>/dev/null)"
  started="$(cat "$LOAD_STARTED" 2>/dev/null)"
  case "$pct" in ""|*[!0-9]*) echo "not valid: the stand-in's percent is unknown ($LOAD_PERCENT)"; return 4 ;; esac
  case "$started" in ""|*[!0-9]*) started=0 ;; esac
  floor=$((pct - 20))
  [ "$floor" -lt 0 ] && floor=0
  echo "measure: $secs s, stand-in asked for $pct percent (every judged second must reach $floor), whole-system CPU apart from Sesame's processes"
  i=1
  while [ "$i" -le "$secs" ]; do
    line="$(sample_one)" || { echo "not valid: $line"; return 4; }
    set -- $line
    apart="$1"; sys="$2"; ses="$3"
    now="$(date +%s)"
    mark=""
    if [ $((now - started)) -lt 2 ]; then
      mark=" (ramp-up, not judged)"
    else
      judged=$((judged + 1))
      sum="$(awk -v s="$sum" -v a="$apart" 'BEGIN { printf "%.1f", s + a }')"
      if [ -z "$min" ] || awk -v a="$apart" -v m="$min" 'BEGIN { exit !(a < m) }'; then min="$apart"; fi
      if awk -v a="$apart" -v f="$floor" 'BEGIN { exit !(a < f) }'; then
        low=$((low + 1))
        mark=" (SHORT of $floor)"
      fi
    fi
    echo "second $i epoch $now cpu apart from Sesame $apart percent (system $sys, Sesame $ses)$mark"
    i=$((i + 1))
  done
  if [ "$judged" = 0 ]; then
    echo "not valid: every second fell in the ramp-up, nothing was judged; measure longer"
    return 4
  fi
  if [ "$low" -gt 0 ]; then
    echo "not valid: the load fell short of the $pct percent asked in $low of $judged seconds (lowest $min percent, floor $floor); rerun"
    return 4
  fi
  echo "LOAD MEASURED: $judged s judged, lowest $min percent, mean $(awk -v s="$sum" -v n="$judged" 'BEGIN { printf "%.1f", s / n }') percent, asked $pct"
  return 0
}

# ---- ping -------------------------------------------------------------------------------------------

cmd_ping() {
  local i line sum=0 mean ok=1 p left="" yes_pids
  if load_alive; then
    echo "not valid: a busy stand-in is already running; kit-load.sh stop first"
    return 4
  fi
  cmd_start 100 || { echo "KIT-LOAD PING FAILED: the stand-in did not start"; return 1; }
  i=1
  while [ "$i" -le 3 ]; do
    if line="$(sample_one)"; then
      set -- $line
      echo "ping second $i: cpu apart from Sesame $1 percent"
      sum="$(awk -v s="$sum" -v a="$1" 'BEGIN { printf "%.1f", s + a }')"
    else
      echo "ping second $i: $line"
      ok=0
    fi
    i=$((i + 1))
  done
  yes_pids="$(cat "$LOAD_YES" 2>/dev/null)"
  cmd_stop
  for p in $yes_pids; do is_yes "$p" && left="$left $p"; done
  if [ -n "$left" ]; then
    echo "KIT-LOAD PING FAILED: yes processes left after stop:$left"
    return 1
  fi
  [ "$ok" = 1 ] || { echo "KIT-LOAD PING FAILED: no CPU reading"; return 1; }
  mean="$(awk -v s="$sum" 'BEGIN { printf "%.1f", s / 3 }')"
  if awk -v m="$mean" 'BEGIN { exit !(m > 50) }'; then
    echo "KIT-LOAD PING OK: a three-second busy run measured $mean percent (above 50), stopped, nothing left"
    return 0
  fi
  echo "KIT-LOAD PING FAILED: a three-second busy run measured $mean percent, not above 50"
  return 1
}

main() {
  case "$1" in
    start) shift; cmd_start "$@" ;;
    stop) [ $# = 1 ] || { usage; return 2; }; cmd_stop ;;
    measure) shift; cmd_measure "$@" ;;
    ping) [ $# = 1 ] || { usage; return 2; }; cmd_ping ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-load "$@")" main "$@"
exit $?

#!/bin/bash
# kit-mem.sh <mode>: the memory of every Sesame process together (verify.md, Kit scripts; S2.13 and S2.14).
#
#   sample <label> [--secs N]     the summed footprint now; with --secs N the highest of the readings taken back
#                                 to back (about every 250 ms: footprint's own time) for N seconds. Prints
#                                 "MEM <label> bytes=<n> processes=<list>"
#   idle <secs> [--bar-bytes N]   waits <secs> with the panel closed, then reads once: "READING idle_bytes=<n> after
#                                 <secs> s bar <bar> WITHIN BAR|OVER BAR" (bar 100,000,000 bytes, the stricter
#                                 reading of 100 MB). A helper process still alive is listed and counts as OVER BAR:
#                                 the spec's idle state has the model helper quit.
#   peak start                    starts a sampler in the background (readings back to back, about every 250 ms)
#   peak stop [--bar-bytes N]     stops it and prints "PEAK bytes=<max> ..." with the process that held the maximum,
#                                 then "READING peak_bytes=<n> bar <bar> WITHIN BAR|OVER BAR" (bar 1,500,000,000)
#   ping                          `footprint` reports for the kit's own process
#
# A process is "Sesame" when its executable lies inside the kit's own Sesame.app (the app, and every mode of
# SesameHelper): kit_tree in kit-lib/common.sh. The figure is `footprint`'s own total for each process, in bytes,
# added up; a process that is alive but that footprint gave no figure for is an error, never a smaller total.
# Exit codes: 0 done and within the bar; 1 over the bar or an error; 2 usage; 4 the run is not valid (no Sesame
# process to read, no sampler to stop, the panel was open): rerun, never a pass.
. "$(dirname "$0")/kit-lib/common.sh"

BAR_IDLE=100000000
BAR_PEAK=1500000000
MEM_PEAK_FILE="$KIT_ROOT/run/mem-peak.tsv"
MEM_PEAK_PID="$KIT_ROOT/run/pids/mem-peak.pid"
MEM_TOTAL=0
MEM_ROWS=""
MEM_ERR=""

usage() {
  cat >&2 <<'EOF'
usage: kit-mem.sh sample <label> [--secs N]
       kit-mem.sh idle <secs> [--bar-bytes N]
       kit-mem.sh peak start
       kit-mem.sh peak stop [--bar-bytes N]
       kit-mem.sh ping
EOF
}

# mem_footprints <pid>... : "<pid> <bytes>" for each of those pids that `footprint` reported on. Only the pids
# asked for are read out of the output (footprint treats an unknown number as a name to match).
mem_footprints() {
  local args=() p
  for p in "$@"; do args+=(-p "$p"); done
  footprint "${args[@]}" --noCategories -f bytes 2>/dev/null | awk -v want=" $* " '
    match($0, /\[[0-9]+\]: /) {
      pid = substr($0, RSTART + 1, RLENGTH - 4)
      k = index($0, "Footprint: ")
      if (k == 0) next
      split(substr($0, k + 11), a, " ")
      if (index(want, " " pid " ") > 0 && a[1] ~ /^[0-9]+$/) print pid, a[1]
    }'
}

# mem_snapshot : MEM_ROWS holds "<pid> <name> <mode> <bytes>" per Sesame process and MEM_TOTAL their sum. Status 0;
# 1 when no Sesame process runs; 2 when a live one got no figure (MEM_ERR says which).
mem_snapshot() {
  local tree pids fp pid
  MEM_TOTAL=0; MEM_ROWS=""; MEM_ERR=""
  tree="$(kit_tree)"
  [ -n "$tree" ] || return 1
  pids="$(printf '%s\n' "$tree" | awk '{ print $1 }' | tr '\n' ' ')"
  fp="$(mem_footprints $pids)"
  for pid in $pids; do
    if ! printf '%s\n' "$fp" | awk -v p="$pid" '$1 == p { f = 1 } END { exit f ? 0 : 1 }'; then
      if kill -0 "$pid" 2>/dev/null; then MEM_ERR="footprint gave no figure for the live process $pid"; return 2; fi
    fi
  done
  MEM_ROWS="$(awk 'NR == FNR { b[$1] = $2; next } ($1 in b) { print $1, $2, $3, b[$1] }' <(printf '%s\n' "$fp") <(printf '%s\n' "$tree"))"
  MEM_TOTAL="$(printf '%s\n' "$MEM_ROWS" | awk 'NF { t += $4 } END { print t + 0 }')"
  return 0
}

# mem_need_app <what> : status 0 when a Sesame process runs; else one line and status 4 (or 1).
mem_need_app() {
  kit_need_ps || return 1
  mem_snapshot; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) echo "RERUN not valid: no Sesame process is running, so there is nothing to read ($1)"; return 4 ;;
    *) echo "$MEM_ERR"; return 1 ;;
  esac
}

# mem_names <rows> : "<name> (<mode>) <bytes> bytes" per process, joined by ", ".
mem_names() { printf '%s\n' "$1" | awk 'NF { printf "%s%s (%s) %s bytes", (n++ ? ", " : ""), $2, $3, $4 }'; }

# mem_evidence <name> <file> : a copy of the file in the evidence folder as <name>.tsv (never over an older one).
mem_evidence() {
  local dir f n=1
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/$1.tsv"
  while [ -e "$f" ]; do n=$((n + 1)); f="$dir/$1-$n.tsv"; done
  cp "$2" "$f" 2>/dev/null && echo "saved $f"
}

# mem_verdict <bytes> <bar> : WITHIN BAR or OVER BAR (below the bar is within it).
mem_verdict() { if [ "$1" -lt "$2" ]; then echo "WITHIN BAR"; else echo "OVER BAR"; fi; }

# mem_bar_arg <default> <args...> : the --bar-bytes value, else the default; status 2 on a bad argument.
mem_bar_arg() {
  local def="$1"
  shift
  case "$#" in
    0) echo "$def" ;;
    2) [ "$1" = --bar-bytes ] && case "$2" in ""|*[!0-9]*) return 2 ;; esac || return 2; echo "$2" ;;
    *) return 2 ;;
  esac
}

# ---- sample ----------------------------------------------------------------------------------------

cmd_sample() {
  [ $# -ge 1 ] || { usage; return 2; }
  local label="$1" secs=0 tmp max=0 best="" end first=1 now
  shift
  case "$label" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  if [ $# -gt 0 ]; then
    [ $# = 2 ] && [ "$1" = --secs ] && case "$2" in ""|*[!0-9]*) false ;; *) true ;; esac || { usage; return 2; }
    secs="$2"
  fi
  mem_need_app "sample $label" || return $?
  tmp="$KIT_TMP/kit-mem-sample.$$"
  : > "$tmp"
  end=$((SECONDS + secs))
  while :; do
    [ "$first" = 1 ] || { mem_snapshot || true; }
    first=0
    now="$(date +%s)"
    printf '%s\n' "$MEM_ROWS" | awk -v t="$now" 'NF { print t "\t" $1 "\t" $2 "\t" $3 "\t" $4 }' >> "$tmp"
    if [ "$MEM_TOTAL" -gt "$max" ]; then max="$MEM_TOTAL"; best="$MEM_ROWS"; fi
    [ "$SECONDS" -ge "$end" ] && break
  done
  echo "MEM $label bytes=$max processes=$(mem_names "$best")"
  mem_evidence "mem-$label" "$tmp"
  rm -f "$tmp"
  return 0
}

# ---- idle ------------------------------------------------------------------------------------------

# The panel is a window of Sesame at least 900 points wide: an open panel is not the idle state.
panel_open() {
  local bin
  bin="$(kit_tool pixelpoll)" || return 1
  "$bin" windows Sesame | awk '$3 >= 900 { f = 1 } END { exit f ? 0 : 1 }'
}

cmd_idle() {
  [ $# -ge 1 ] || { usage; return 2; }
  local secs="$1" bar tmp verdict helpers now
  shift
  case "$secs" in ""|*[!0-9]*) usage; return 2 ;; esac
  bar="$(mem_bar_arg "$BAR_IDLE" "$@")" || { usage; return 2; }
  mem_need_app "idle $secs" || return $?
  if panel_open; then
    echo "RERUN not valid: the panel is open, and the idle state has it closed"
    return 4
  fi
  sleep "$secs"
  if panel_open; then
    echo "RERUN not valid: the panel was opened while waiting, so the app was not idle"
    return 4
  fi
  mem_snapshot; rc=$?
  case "$rc" in
    0) ;;
    1) echo "RERUN not valid: Sesame was no longer running after $secs s"; return 4 ;;
    *) echo "$MEM_ERR"; return 1 ;;
  esac
  now="$(date +%s)"
  tmp="$KIT_TMP/kit-mem-idle.$$"
  printf '%s\n' "$MEM_ROWS" | awk -v t="$now" 'NF { print t "\t" $1 "\t" $2 "\t" $3 "\t" $4 }' > "$tmp"
  mem_evidence "mem-idle-$secs" "$tmp"
  rm -f "$tmp"
  echo "processes: $(mem_names "$MEM_ROWS")"
  helpers="$(printf '%s\n' "$MEM_ROWS" | awk '$3 != "app" && NF { printf "%s%s (%s) pid %s", (n++ ? ", " : ""), $2, $3, $1 }')"
  verdict="$(mem_verdict "$MEM_TOTAL" "$bar")"
  if [ -n "$helpers" ]; then
    echo "helper alive: $helpers (the idle state has the model helper quit)"
    verdict="OVER BAR"
  fi
  echo "READING idle_bytes=$MEM_TOTAL after $secs s bar $bar $verdict"
  [ "$verdict" = "WITHIN BAR" ]
}

# ---- peak ------------------------------------------------------------------------------------------

# peak_loop : one reading after another (about every 250 ms), as "S<TAB>epoch<TAB>total" and one "R<TAB>epoch<TAB>pid<TAB>name<TAB>mode<TAB>bytes"
# per process, until it is killed.
peak_loop() {
  local now
  while :; do
    if mem_snapshot; then
      now="$(date +%s)"
      {
        printf 'S\t%s\t%s\n' "$now" "$MEM_TOTAL"
        printf '%s\n' "$MEM_ROWS" | awk -v t="$now" 'NF { print "R\t" t "\t" $1 "\t" $2 "\t" $3 "\t" $4 }'
      } >> "$MEM_PEAK_FILE"
    fi
  done
}

peak_kill() {
  local pid
  pid="$(cat "$MEM_PEAK_PID" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    sleep 0.3
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$MEM_PEAK_PID"
  return 0
}

cmd_peak_start() {
  [ $# = 0 ] || { usage; return 2; }
  mem_need_app "peak start" || return $?
  mkdir -p "$KIT_ROOT/run/pids" || return 1
  peak_kill
  : > "$MEM_PEAK_FILE"
  ( peak_loop ) >/dev/null 2>&1 </dev/null &
  echo "$!" > "$MEM_PEAK_PID"
  echo "peak sampler started (pid $!), a reading every 250 ms"
}

cmd_peak_stop() {
  local bar samples max best tmp verdict
  bar="$(mem_bar_arg "$BAR_PEAK" "$@")" || { usage; return 2; }
  if ! peak_kill; then
    echo "RERUN not valid: no peak sampler is running (kit-mem.sh peak start first)"
    return 4
  fi
  samples="$(awk -F'\t' '$1 == "S" { n++ } END { print n + 0 }' "$MEM_PEAK_FILE")"
  if [ "$samples" = 0 ]; then
    echo "RERUN not valid: the peak sampler took no reading"
    return 4
  fi
  max="$(awk -F'\t' '$1 == "S" && $3 + 0 > m { m = $3 + 0 } END { print m + 0 }' "$MEM_PEAK_FILE")"
  # the processes of the first reading that reached the maximum, and which of them was the biggest
  best="$(awk -F'\t' -v m="$max" '
    $1 == "S" { cur = ($3 + 0 == m && !got); if (cur) got = 1; next }
    $1 == "R" && cur { print $3, $4, $5, $6 }' "$MEM_PEAK_FILE")"
  echo "PEAK bytes=$max samples=$samples every about 250 ms; at the maximum: $(mem_names "$best")"
  printf '%s\n' "$best" | sort -k4 -n -r | awk 'NR == 1 { printf "maximum held mostly by %s (%s, pid %s) at %s bytes\n", $2, $3, $1, $4 }'
  mem_evidence "mem-peak" "$MEM_PEAK_FILE"
  verdict="$(mem_verdict "$max" "$bar")"
  echo "READING peak_bytes=$max bar $bar $verdict"
  [ "$verdict" = "WITHIN BAR" ]
}

cmd_peak() {
  local what="${1:-}"
  [ $# -gt 0 ] && shift
  case "$what" in
    start) cmd_peak_start "$@" ;;
    stop) cmd_peak_stop "$@" ;;
    *) usage; return 2 ;;
  esac
}

# ---- ping ------------------------------------------------------------------------------------------

cmd_ping() {
  [ $# = 0 ] || { usage; return 2; }
  local got
  if ! command -v footprint >/dev/null 2>&1; then
    echo "footprint is missing: it is part of macOS (/usr/bin/footprint)"
    return 1
  fi
  got="$(mem_footprints $$)"
  case "$got" in
    "$$ "[0-9]*) echo "footprint reports for the kit's own process: pid $$ holds ${got#* } bytes" ;;
    *) echo "footprint gave no figure for the kit's own process (pid $$)"; return 1 ;;
  esac
}

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    sample) cmd_sample "$@" ;;
    idle) cmd_idle "$@" ;;
    peak) cmd_peak "$@" ;;
    ping) cmd_ping "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-mem "$@")" main "$@"
exit $?

#!/bin/bash
# Shared helpers of the scripts/kit-*.sh kit. Sourced by the scripts, never run.
# bash 3.2 compatible (the /bin/bash of macOS): no associative arrays, no mapfile.
#
# Exit codes of every kit script (verify.md, Drive): 0 done or pass; 1 a check failed or the
# driver errored; 2 usage; 3 a person-step is missing (NEEDS A PERSON: ...); 4 the run is invalid
# because a precondition did not hold (never a pass, never a fail: rerun).
#
# Background processes a kit script starts write their pid to $KIT_ROOT/run/pids/<name>.pid;
# `kit-reset.sh --cleanup` stops every one of them.

KIT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_SCRIPTS="$(dirname "$KIT_LIB")"
KIT_PROJECT="$(dirname "$KIT_SCRIPTS")"
KIT_TMP="${TMPDIR:-/tmp}"
KIT_TMP="${KIT_TMP%/}"
KIT_ROOT="${KIT_ROOT:-$KIT_TMP/sesame-kit}"
KIT_ROOT="${KIT_ROOT%/}"
export KIT_ROOT

# KIT_ROOT is deleted from (cleanup), so it must be unmistakably the kit's own folder.
case "$KIT_ROOT" in
  /*) ;;
  *) echo "KIT_ROOT must be an absolute path: $KIT_ROOT" >&2; exit 1 ;;
esac
case "$KIT_ROOT" in
  *" "*) echo "KIT_ROOT must not contain a space: $KIT_ROOT" >&2; exit 1 ;;
esac
case "${KIT_ROOT##*/}" in
  sesame-kit*) ;;
  *) echo "KIT_ROOT must end in a folder named sesame-kit*: $KIT_ROOT" >&2; exit 1 ;;
esac

# Launch Services reports an app's real path (/private/var/... for a /var/... folder), so the app's
# processes are matched under both spellings.
KIT_ROOT_REAL="$(cd "$KIT_ROOT" 2>/dev/null && pwd -P)"
KIT_ROOT_REAL="${KIT_ROOT_REAL:-$KIT_ROOT}"
export KIT_ROOT_REAL

KIT_APP="$KIT_ROOT/apps/Sesame.app"
KIT_APP_REAL="$KIT_ROOT_REAL/apps/Sesame.app"
KIT_APP_EXE="$KIT_APP/Contents/MacOS/Sesame"
KIT_HELPER_EXE="$KIT_APP/Contents/MacOS/SesameHelper"
KIT_SLICE="$(cat "$KIT_LIB/slice" 2>/dev/null)"
KIT_SLICE="${KIT_SLICE:-1}"
# The hard limit, in seconds, of every Apple Event or accessibility probe (kit_timeout).
KIT_PROBE_TIMEOUT="${KIT_PROBE_TIMEOUT:-10}"
# The idle rule (kit-index.sh wait idle): an index with a file still pending or partial is idle only after this many
# seconds with no change in its counts (a helper that is stuck); an end of stdin drops the step in flight, so a step
# that is merely quiet must not be cut. The override is for the tests.
KIT_IDLE_LONG_QUIET_S="${KIT_IDLE_LONG_QUIET_S:-90}"

# ---- hard timeouts ---------------------------------------------------------------------------

# kit_descendants <pid> : the pids of everything that process started, one per line.
kit_descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    echo "$c"
    kit_descendants "$c"
  done
}

# kit_timeout <seconds> <command...> : runs the command (a program or script, not a shell function) and
# returns its own status; when it is still running after that long, it and everything it started are
# killed and the status is 124. A hung app that never answers an Apple Event can never block a run.
kit_timeout() {
  local secs="$1" pid ticks=0 max kids
  shift
  max=$((secs * 20))
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max" ]; then
      kids="$(kit_descendants "$pid")"
      kill -TERM $kids "$pid" 2>/dev/null
      sleep 0.5
      kill -KILL $kids "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.05
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# ---- evidence ------------------------------------------------------------------------------

# The evidence folder of the current starting state ("" when kit-reset.sh has not run). kit-run.sh sets
# KIT_EVIDENCE_SCENARIO to the scenario of the id it is checking (S6 for S6.10), so the evidence of an id is saved
# under its own scenario and not under the id given to kit-reset.sh (block C of the accept stage resets with S1 and
# also runs S6.10); the version is the one the last reset recorded. Without the variable the folder is the recorded one.
kit_evidence_dir() {
  local dir ver
  dir="$(cat "$KIT_ROOT/run/evidence-dir" 2>/dev/null)"
  if [ -n "${KIT_EVIDENCE_SCENARIO:-}" ] && [ -n "$dir" ]; then
    ver="$(cat "$KIT_ROOT/run/version" 2>/dev/null)"
    if [ -n "$ver" ]; then
      printf '%s\n' "$KIT_PROJECT/.ril/evidence/$KIT_EVIDENCE_SCENARIO/$ver"
      return 0
    fi
  fi
  [ -n "$dir" ] && printf '%s\n' "$dir"
  return 0
}

# kit_slug <script name> [args...] : a file-name-safe name made from the command.
kit_slug() {
  local s="$1"; shift
  local a
  for a in "$@"; do s="$s-$a"; done
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._\n-' '_' | tr -s '_-')"
  printf '%s' "${s:0:90}"
}

# kit_wrap <slug> <command...> : runs the command, shows its output as it comes and saves the
# complete output to the evidence folder as <slug>.txt (-2, -3 ... when the name is taken).
kit_wrap() {
  local slug="$1"; shift
  local before after dir tmp rc f n
  before="$(kit_evidence_dir)"
  tmp="$(mktemp "$KIT_TMP/kit-out.XXXXXX")" || { "$@"; return $?; }
  "$@" 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  after="$(kit_evidence_dir)"
  dir="${after:-$before}"
  # KIT_NO_EVIDENCE=1: a kit script calling another one for its side effect saves nothing twice.
  if [ -z "$KIT_NO_EVIDENCE" ] && [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
    f="$dir/$slug.txt"; n=1
    while [ -e "$f" ]; do n=$((n + 1)); f="$dir/$slug-$n.txt"; done
    cp "$tmp" "$f" 2>/dev/null
  fi
  rm -f "$tmp"
  return $rc
}

# ---- the app's process tree ----------------------------------------------------------------

# kit_ps_ok : can this shell list processes? A sandbox may refuse it ("Operation not permitted").
kit_ps_ok() { ps -axo pid= >/dev/null 2>&1; }

# kit_need_ps : status 1 and one line when processes cannot be listed. Every mode that has to find
# the app's processes starts with it, so a refused ps never reads as "nothing is running".
kit_need_ps() {
  if ! kit_ps_ok; then
    echo "blocked: ps is refused here (Operation not permitted), so the app's processes cannot be listed; run this from a shell that may list processes"
    return 1
  fi
  return 0
}

kit_screen_locked() {
  local reading
  if [ -n "${KIT_SCREEN_LOCK_READING+x}" ]; then
    reading="$KIT_SCREEN_LOCK_READING"
  else
    reading="$(ioreg -n Root -d1 -a -r 2>/dev/null)"
  fi
  printf '%s\n' "$reading" | awk '
    /<key>(IOConsoleLocked|CGSSessionScreenIsLocked)<\/key>/ { want = 1; next }
    want { if ($0 ~ /<true\/>/) found = 1; want = 0 }
    END { exit found ? 0 : 1 }'
}

kit_say_locked() { echo "NEEDS A PERSON: the screen is locked, unlock it and keep it awake"; }

# kit_tree : one line per process whose executable lies inside the kit's Sesame.app:
# "<pid> <name> <mode>" with mode app, encode, index or helper (a SesameHelper with no mode).
kit_tree() {
  local pid exe rest name mode w
  ps -axo pid=,args= 2>/dev/null | while read -r pid exe rest; do
    case "$exe" in
      "$KIT_APP"/*|"$KIT_APP_REAL"/*) ;;
      *) continue ;;
    esac
    name="${exe##*/}"
    mode="helper"
    case "$name" in Sesame) mode="app" ;; esac
    if [ "$mode" = "helper" ]; then
      for w in $rest; do
        case "$w" in encode) mode="encode"; break ;; index) mode="index"; break ;; esac
      done
    fi
    echo "$pid $name $mode"
  done
}

# kit_pid_of <app|encode|index> : the pids of that part, one per line.
kit_pid_of() {
  kit_tree | while read -r pid name mode; do
    [ "$mode" = "$1" ] && echo "$pid"
  done
}

# kit_kill_tree : SIGKILL every process of the kit's app tree (thawed first). Prints one line each.
kit_kill_tree() {
  local pid name mode
  kit_tree | while read -r pid name mode; do
    kill -CONT "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null && echo "killed leftover $name ($mode) pid $pid"
  done
  return 0
}

# kit_need_bundle : exit status 1 and one line when the product has not been bundled.
kit_need_bundle() {
  if [ ! -d "$KIT_PROJECT/dist/Sesame.app" ]; then
    echo "no bundle: dist/Sesame.app is missing ($KIT_PROJECT/dist/Sesame.app); scripts/bundle.sh makes it (first in task plan-1-t10)"
    return 1
  fi
  return 0
}

# ---- the Swift tools -----------------------------------------------------------------------

# kit_tool <name> : compiles scripts/kit-lib/<name>.swift once per starting state and prints the
# path of the binary. Status 1 (log in $KIT_ROOT/run/bin/<name>.log) when it does not compile.
kit_tool() {
  local name="$1" src="$KIT_LIB/$1.swift" bin="$KIT_ROOT/run/bin/$1"
  [ -f "$src" ] || return 1
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    mkdir -p "$KIT_ROOT/run/bin" "$KIT_ROOT/run/modcache" || return 1
    CLANG_MODULE_CACHE_PATH="$KIT_ROOT/run/modcache" \
      swiftc -O -module-cache-path "$KIT_ROOT/run/modcache" -o "$bin" "$src" \
      >"$KIT_ROOT/run/bin/$name.log" 2>&1 || { rm -f "$bin"; return 1; }
  fi
  echo "$bin"
}

# ---- the model files -----------------------------------------------------------------------

# kit_models : "<name> <bytes> <sha256>" per model file (hand-written from design section 7).
kit_models() {
  local name size sha
  while IFS=$'\t' read -r name size sha; do
    [ -n "$name" ] && echo "$name $size $sha"
  done < "$KIT_LIB/models.tsv"
}

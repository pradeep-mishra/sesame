#!/bin/bash
# kit-launch.sh <mode>: start and stop the app and its helpers the way a person's launch does.
#
# The app is never started from inside the project and never from .build: kit-reset.sh copies
# dist/Sesame.app to $KIT_ROOT/apps/Sesame.app and everything here runs that copy, from $KIT_ROOT.
# The launch settings of the test kit only (design section 14) are environment values, set here and
# nowhere else: HOME (the throwaway $KIT_ROOT/home, so no kit launch writes to the person's real
# ~/Library), SESAME_PROBE_FILE, SESAME_MODEL_HOST, SESAME_FAKE_EMBEDDER. `start --plain` keeps
# the throwaway HOME and sets none of the three SESAME_* names.
# Exit codes: 0 done; 1 error or no bundle; 2 usage; 3 a person-step is missing; 4 a precondition
# did not hold (nothing to act on): never a pass, never a fail, rerun.
. "$(dirname "$0")/kit-lib/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: kit-launch.sh start [--mirror|--mirror-full|--plain] [--fake-embedder]
       kit-launch.sh stop
       kit-launch.sh quit
       kit-launch.sh kill9 <app|encode|index>
       kit-launch.sh freeze index [--wait <seconds>]
       kit-launch.sh thaw index
       kit-launch.sh pids [--names]
       kit-launch.sh helper [<mode>] [--folders <fixture-dir>...] [--read-folders <path under the kit root>...] [--stdin <file>] [--no-model] [--fake-embedder]
       kit-launch.sh probe
       kit-launch.sh where
       kit-launch.sh relaunch
  start      the app through Launch Services (open -n) from $KIT_ROOT; HOME is the throwaway home
             and SESAME_PROBE_FILE the probe file. --mirror and --mirror-full add SESAME_MODEL_HOST
             (the local mirror; --mirror-full at full rate), --fake-embedder adds SESAME_FAKE_EMBEDDER=1,
             --plain sets none of the three SESAME_* names.
  stop       quit, then kill what is left of the app's tree
  quit       a clean quit (not running: "not running")
  kill9      SIGKILL the app or one of its helpers (exit 4 when it is not running)
  freeze     kill -STOP on the index helper; thaw: kill -CONT (exit 4 when it is not running).
             freeze index --wait N: arm first, then press Start indexing; stops the first index helper that
             appears (a helper already running is left alone) within 20 ms of its pid showing, up to N s (exit 4
             when none appeared). A freeze after Start was pressed can lose the race against the helper's walk.
  pids       every process of the app's tree; --names adds each process name and mode
  helper     runs the bundled SesameHelper the way the app would and prints its stdout
  probe      the probe file path, then one "<event> <ticket> <ns>" line per probe line
  where      the Sesame folder in use, then mode=<octal> or missing
  relaunch   starts the app again with the flags of the last start
EOF
}

# ---- start, quit, kill -----------------------------------------------------------------------

app_pid() { kit_pid_of app | head -1; }

# Does `open` of this macOS know --env? (verify.md, guess K19.)
open_has_env() { open --help 2>&1 | grep -q -- '--env'; }

launch_app() { # launch_app <route: mirror|mirror-full|plain|""> <fake 0|1>
  local route="$1" fake="$2" host="" pid i
  local envs=("HOME=$KIT_ROOT/home")
  if [ "$route" != plain ]; then
    envs+=("SESAME_PROBE_FILE=$KIT_ROOT/run/probe.jsonl")
    case "$route" in
      mirror|mirror-full)
        if [ "$route" = mirror-full ]; then
          if [ ! -x "$KIT_SCRIPTS/kit-mirror.sh" ]; then
            echo "not built yet: scripts/kit-mirror.sh (the mirror the --mirror-full launch points the app at)"
            return 1
          fi
          [ -f "$KIT_ROOT/run/mirror-host" ] || "$KIT_SCRIPTS/kit-mirror.sh" start || return 1
          "$KIT_SCRIPTS/kit-mirror.sh" rate max || return 1
        fi
        host="$(cat "$KIT_ROOT/run/mirror-host" 2>/dev/null)"
        if [ -z "$host" ]; then
          echo "no mirror running: start it with scripts/kit-mirror.sh start"
          return 4
        fi
        envs+=("SESAME_MODEL_HOST=$host")
        ;;
    esac
    [ "$fake" = 1 ] && envs+=("SESAME_FAKE_EMBEDDER=1")
  fi
  cd "$KIT_ROOT" || return 1
  if open_has_env; then
    local args=(-n)
    for i in "${envs[@]}"; do args+=(--env "$i"); done
    open "${args[@]}" "$KIT_APP" || { echo "open failed"; return 1; }
  else
    echo "note: this macOS has no open --env; started the executable directly"
    ( env "${envs[@]}" "$KIT_APP_EXE" >/dev/null 2>&1 & )
  fi
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    pid="$(app_pid)"
    [ -n "$pid" ] && break
    sleep 0.25
  done
  if [ -z "$pid" ]; then
    echo "the app did not start within 10 s"
    return 1
  fi
  printf '%s\n' "$route|$fake" > "$KIT_ROOT/run/start-flags"
  echo "started Sesame pid $pid"
  return 0
}

# A bundle and a starting state must exist before anything is started.
need_start() {
  kit_need_bundle || return 1
  if [ ! -f "$KIT_ROOT/run/evidence-dir" ]; then
    echo "no starting state: run scripts/kit-reset.sh first"
    return 1
  fi
  if [ ! -d "$KIT_APP" ]; then
    echo "no copy of the bundle in $KIT_ROOT/apps/: run scripts/kit-reset.sh again"
    return 1
  fi
  return 0
}

cmd_start() {
  local route="" fake=0 a
  for a in "$@"; do
    case "$a" in
      --mirror|--mirror-full|--plain)
        [ -z "$route" ] || { usage; return 2; }
        route="${a#--}" ;;
      --fake-embedder) fake=1 ;;
      *) usage; return 2 ;;
    esac
  done
  [ "$route" = plain ] && [ "$fake" = 1 ] && { usage; return 2; }
  need_start || return 1
  kit_need_ps || return 1
  local pid
  pid="$(app_pid)"
  if [ -n "$pid" ]; then
    echo "already running (pid $pid): quit it first"
    return 1
  fi
  launch_app "$route" "$fake"
}

cmd_relaunch() {
  [ $# -eq 0 ] || { usage; return 2; }
  need_start || return 1
  kit_need_ps || return 1
  local pid flags
  pid="$(app_pid)"
  if [ -n "$pid" ]; then
    echo "the app is still running (pid $pid): quit or kill9 it first"
    return 4
  fi
  flags="$(cat "$KIT_ROOT/run/start-flags" 2>/dev/null)"
  if [ -z "$flags" ]; then
    echo "no earlier start to repeat"
    return 4
  fi
  launch_app "${flags%|*}" "${flags#*|}"
}

# Waits up to $2 seconds for the app tree (or just the app, when $1 is app) to be gone.
wait_gone() {
  local what="$1" secs="$2" i n=$(( $2 * 4 ))
  for ((i = 0; i < n; i++)); do
    if [ "$what" = app ]; then
      [ -z "$(app_pid)" ] && return 0
    else
      [ -z "$(kit_tree)" ] && return 0
    fi
    sleep 0.25
  done
  return 1
}

cmd_quit() {
  [ $# -eq 0 ] || { usage; return 2; }
  kit_need_ps || return 1
  local pid left
  pid="$(app_pid)"
  if [ -z "$pid" ]; then echo "not running"; return 0; fi
  # Slice 1 has no menu bar (design section 13), so the quit is the standard Quit Apple Event,
  # which AppKit handles as Quit; if scripting is refused, a plain SIGTERM.
  if ! osascript -e "tell application \"$KIT_APP\" to quit" >/dev/null 2>&1; then
    echo "note: the quit Apple Event was refused; sent SIGTERM"
    kill "$pid" 2>/dev/null
  fi
  if ! wait_gone app 10; then
    echo "the app did not quit within 10 s (pid $pid)"
    return 1
  fi
  if ! wait_gone tree 15; then
    left="$(kit_tree | awk '{printf "%s(%s,%s) ", $1, $2, $3}')"
    echo "the app quit but a helper is still running: $left"
    return 1
  fi
  echo "quit"
  return 0
}

cmd_stop() {
  [ $# -eq 0 ] || { usage; return 2; }
  kit_need_ps || return 1
  if [ -z "$(kit_tree)" ]; then echo "not running"; return 0; fi
  cmd_quit >/dev/null
  kit_kill_tree
  echo "stopped"
  return 0
}

cmd_kill9() {
  [ $# -eq 1 ] || { usage; return 2; }
  local part="$1" label pids pid
  case "$part" in
    app) label="app" ;;
    encode|index) label="$part helper" ;;
    *) usage; return 2 ;;
  esac
  kit_need_ps || return 1
  pids="$(kit_pid_of "$part")"
  if [ -z "$pids" ]; then echo "no $label running"; return 4; fi
  for pid in $pids; do
    kill -CONT "$pid" 2>/dev/null
    kill -9 "$pid" && echo "killed $label pid $pid"
  done
  return 0
}

# freeze_new_index <seconds> : SIGSTOP the first index helper of the kit's app tree that was not running when this
# call started, the moment its pid appears (polled with pgrep, 5 ms apart, not with the slow whole-tree listing).
# Meant to be armed (in the background) BEFORE Start indexing is pressed, so the freeze cannot lose the race
# against the helper's walk. Status 0 frozen (one line), 4 no new index helper appeared in time.
freeze_new_index() {
  local secs="$1" end old="" pid p args w seen
  kit_need_ps || return 1
  old="$(kit_pid_of index | tr '\n' ' ')"
  echo "armed: waiting for a new index helper (already running: ${old:-none})"
  end=$((SECONDS + secs))
  while :; do
    for p in $(pgrep -f "SesameHelper" 2>/dev/null); do
      case " $old " in *" $p "*) continue ;; esac
      args="$(ps -p "$p" -o args= 2>/dev/null)"
      case "$args" in "$KIT_APP"/*|"$KIT_APP_REAL"/*) ;; *) continue ;; esac
      seen=0
      for w in ${args#* }; do [ "$w" = index ] && seen=1; done
      [ "$seen" = 1 ] || continue
      if kill -STOP "$p" 2>/dev/null; then
        echo "freeze index helper pid $p (the moment it appeared)"
        return 0
      fi
    done
    [ "$SECONDS" -ge "$end" ] && break
    sleep 0.005
  done
  echo "no new index helper appeared within $secs s"
  return 4
}

cmd_signal() { # cmd_signal freeze|thaw <index> [--wait <seconds>]
  local verb="$1" sig pids pid
  shift
  if [ "$verb" = freeze ] && [ $# -eq 3 ] && [ "$1" = index ] && [ "$2" = --wait ]; then
    case "$3" in ""|*[!0-9]*) usage; return 2 ;; esac
    freeze_new_index "$3"
    return $?
  fi
  [ $# -eq 1 ] && [ "$1" = index ] || { usage; return 2; }
  kit_need_ps || return 1
  pids="$(kit_pid_of index)"
  if [ -z "$pids" ]; then echo "no index helper running"; return 4; fi
  [ "$verb" = freeze ] && sig=STOP || sig=CONT
  for pid in $pids; do
    kill -"$sig" "$pid" && echo "$verb index helper pid $pid"
  done
  return 0
}

cmd_pids() {
  local names=0
  case "${1:-}" in
    "") ;;
    --names) names=1; [ $# -eq 1 ] || { usage; return 2; } ;;
    *) usage; return 2 ;;
  esac
  kit_need_ps || return 1
  local pid name mode
  kit_tree | while read -r pid name mode; do
    if [ "$names" = 1 ]; then echo "$pid $name $mode"; else echo "$pid"; fi
  done
  return 0
}

cmd_where() {
  [ $# -eq 0 ] || { usage; return 2; }
  local dir="$KIT_ROOT/home/Library/Application Support/Sesame"
  echo "$dir"
  if [ -d "$dir" ]; then
    echo "mode=0$(stat -f %Lp "$dir")"
  else
    echo "missing"
  fi
  return 0
}

cmd_probe() {
  [ $# -eq 0 ] || { usage; return 2; }
  local file="$KIT_ROOT/run/probe.jsonl"
  if [ ! -f "$file" ]; then echo "no probe file"; return 4; fi
  if [ ! -s "$file" ]; then echo "probe file is empty: $file"; return 4; fi
  echo "$file"
  # One JSON object per line: {"event":"hotkey","ticket":0,"ns":123} (verify.md, guess K3).
  awk '
    {
      if (match($0, /"event" *: *"[a-z]+"/)) { e = substr($0, RSTART, RLENGTH); sub(/.*: *"/, "", e); sub(/"$/, "", e) } else e = ""
      if (match($0, /"ticket" *: *-?[0-9]+/)) { t = substr($0, RSTART, RLENGTH); sub(/.*: */, "", t) } else t = ""
      if (match($0, /"ns" *: *[0-9]+/)) { n = substr($0, RSTART, RLENGTH); sub(/.*: */, "", n) } else n = ""
      if (e == "" || t == "" || n == "") { print "unreadable probe line: " $0; bad = 1 } else print e, t, n
    }
    END { exit bad }
  ' "$file"
}

# ---- helper ----------------------------------------------------------------------------------

# Waits until the file holds <count> lines matching <pattern>; status 1 on timeout or helper exit.
wait_lines() { # wait_lines <file> <pattern> <count> <pid> <timeout s>
  local file="$1" pattern="$2" count="$3" pid="$4" secs="$5" i n=$(( $5 * 10 )) found
  for ((i = 0; i < n; i++)); do
    found="$(grep -E -c -- "$pattern" "$file" 2>/dev/null)"
    [ "${found:-0}" -ge "$count" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

# Waits until the file has not grown for <quiet> seconds, or the helper has exited.
wait_quiet() { # wait_quiet <file> <pid> <quiet s> <timeout s>
  local file="$1" pid="$2" quiet="$3" secs="$4" i n=$(( $4 * 10 )) size last=-1 still=0
  for ((i = 0; i < n; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    size="$(stat -f %z "$file" 2>/dev/null)"
    if [ "$size" = "$last" ]; then still=$((still + 1)); else still=0; last="$size"; fi
    [ "$still" -ge $((quiet * 10)) ] && return 0
    sleep 0.1
  done
  return 1
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

cmd_helper() {
  local hmode="" nomodel=0 fake=0 stdinf="" folders=() n0 path
  case "${1:-}" in encode|index) hmode="$1"; shift ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-model) nomodel=1; shift ;;
      --fake-embedder) fake=1; shift ;;
      --stdin) [ $# -ge 2 ] || { usage; return 2; }; stdinf="$2"; shift 2 ;;
      --folders)
        shift
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do folders+=("$1"); shift; done
        [ ${#folders[@]} -gt 0 ] || { usage; return 2; } ;;
      --read-folders)
        shift
        n0=${#folders[@]}
        while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do folders+=("@read:$1"); shift; done
        [ ${#folders[@]} -gt "$n0" ] || { usage; return 2; } ;;
      *) usage; return 2 ;;
    esac
  done
  [ ${#folders[@]} -eq 0 ] || [ "$hmode" = index ] || { echo "--folders needs the index mode"; usage; return 2; }
  [ -z "$stdinf" ] || [ -n "$hmode" ] || { echo "--stdin needs a mode"; usage; return 2; }

  need_start || return 1
  if [ ! -x "$KIT_HELPER_EXE" ]; then
    echo "no SesameHelper in the bundle copy: $KIT_HELPER_EXE"
    return 1
  fi

  # The helper gets HOME (the throwaway home) and nothing else; SESAME_FAKE_EMBEDDER only on request.
  local envs=("HOME=$KIT_ROOT/home") hargs=()
  [ "$fake" = 1 ] && envs+=("SESAME_FAKE_EMBEDDER=1")
  if [ -z "$hmode" ]; then
    env "${envs[@]}" "$KIT_HELPER_EXE"
    return $?
  fi
  hargs+=("$hmode")
  if [ "$nomodel" = 0 ] && [ "$fake" = 0 ]; then
    local text="$KIT_ROOT/cache/embeddinggemma-2-Q8_0.gguf" mm="$KIT_ROOT/cache/mmproj-embeddinggemma-2-Q8_0.gguf"
    if [ ! -f "$text" ] || [ ! -f "$mm" ]; then
      echo "NEEDS A PERSON: the model files are not in $KIT_ROOT/cache/ (scripts/kit-mirror.sh seed --real makes the one download); use --no-model or --fake-embedder to run without them"
      return 3
    fi
    hargs+=(--text-model "$text" --mm-model "$mm")
  fi

  # The lines: one folders line (every --folders directory under $KIT_ROOT/fixtures), then the
  # lines of the --stdin file with $FIXTURES replaced.
  local lines="$KIT_ROOT/run/helper-lines.$$" line f list="" sep=""
  : > "$lines"
  if [ ${#folders[@]} -gt 0 ]; then
    for f in "${folders[@]}"; do
      case "$f" in
        @read:*) path="$KIT_ROOT/${f#@read:}" ;;
        *) path="$KIT_ROOT/fixtures/$f" ;;
      esac
      if [ ! -d "$path" ]; then
        echo "no such fixture folder: $path (scripts/kit-fixtures.sh builds it)"
        rm -f "$lines"
        return 1
      fi
      list="$list$sep{\"path\":\"$(json_escape "$path")\",\"code\":false}"
      sep=","
    done
    printf '{"cmd":"folders","folders":[%s]}\n' "$list" >> "$lines"
  fi
  if [ -n "$stdinf" ]; then
    [ -f "$stdinf" ] || stdinf="$KIT_LIB/helper-lines/$stdinf"
    if [ ! -f "$stdinf" ]; then
      echo "no such line file: $stdinf"
      rm -f "$lines"
      return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "${line//\$FIXTURES/$KIT_ROOT/fixtures}" >> "$lines"
    done < "$stdinf"
  fi
  if [ "$hmode" = index ] && [ ${#folders[@]} -gt 0 ] && [ ! -x "$KIT_SCRIPTS/kit-index.sh" ]; then
    echo "not built yet: scripts/kit-index.sh (index mode waits for it: wait idle 10)"
    rm -f "$lines"
    return 1
  fi

  # Run it with stdin held open from a pipe the script writes to.
  local fifo="$KIT_ROOT/run/helper-in.$$" out="$KIT_ROOT/run/helper-out.$$" err="$KIT_ROOT/run/helper-err.$$"
  rm -f "$fifo"
  mkfifo "$fifo" || { rm -f "$lines"; return 1; }
  exec 7<>"$fifo"
  env "${envs[@]}" "$KIT_HELPER_EXE" "${hargs[@]}" < "$fifo" > "$out" 2> "$err" &
  local hpid=$! rc=0 timeout=900 embeds
  while IFS= read -r line; do printf '%s\n' "$line" >&7; done < "$lines"

  if [ "$hmode" = encode ]; then
    # Close stdin after the last line is answered (a vector or a refusal per embed line).
    embeds="$(grep -c '"cmd" *: *"embed"' "$lines")"
    if [ "${embeds:-0}" -gt 0 ]; then
      wait_lines "$out" '"event" *: *"(vector|refused)"' "$embeds" "$hpid" "$timeout" || rc=1
    fi
  else
    if [ ${#folders[@]} -gt 0 ]; then
      # Keep stdin open until the helper has sent walked and the index is idle (10 s of stable counts and no file pending
      # or partial; with work left only the long quiet window ends it: an end of stdin drops the step in flight).
      if wait_lines "$out" '"event" *: *"walked"' 1 "$hpid" "$timeout"; then
        "$KIT_SCRIPTS/kit-index.sh" wait idle 10 >/dev/null || rc=1
      else
        rc=1
      fi
    else
      wait_quiet "$out" "$hpid" 3 "$timeout" || rc=1
    fi
  fi
  exec 7>&-
  # The helper exits at stdin EOF after its current unit.
  local i
  for ((i = 0; i < 1200; i++)); do kill -0 "$hpid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$hpid" 2>/dev/null; then
    kill -9 "$hpid" 2>/dev/null
    echo "the helper did not exit within 120 s of stdin EOF"
    rc=1
  fi
  wait "$hpid" 2>/dev/null
  local hrc=$?
  [ "$rc" = 0 ] && [ "$hrc" != 0 ] && rc="$hrc"

  cat "$out"
  if [ "$hmode" = encode ]; then
    # READING warm_embed_ms=<min>/<median>/<max> over every vector reply but the first.
    grep '"event" *: *"vector"' "$out" | sed -n 's/.*"ms": *\([0-9][0-9]*\).*/\1/p' | tail -n +2 | sort -n | awk '
      { v[NR] = $1 }
      END {
        if (NR == 0) exit
        m = (NR % 2) ? v[(NR + 1) / 2] : int((v[NR / 2] + v[NR / 2 + 1]) / 2)
        printf "READING warm_embed_ms=%d/%d/%d\n", v[1], m, v[NR]
      }'
  fi
  if [ "$rc" != 0 ] && [ -s "$err" ]; then
    echo "helper stderr:"
    cat "$err"
  fi
  [ "$rc" = 0 ] || echo "the helper run did not finish cleanly (exit $rc)"
  rm -f "$fifo" "$out" "$err" "$lines"
  return "$rc"
}

# ---- main ------------------------------------------------------------------------------------

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    quit) cmd_quit "$@" ;;
    kill9) cmd_kill9 "$@" ;;
    freeze|thaw) cmd_signal "$mode" "$@" ;;
    pids) cmd_pids "$@" ;;
    helper) cmd_helper "$@" ;;
    probe) cmd_probe "$@" ;;
    where) cmd_where "$@" ;;
    relaunch) cmd_relaunch "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-launch "$@")" main "$@"
exit $?

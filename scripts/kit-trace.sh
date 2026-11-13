#!/bin/bash
# kit-trace.sh start <name> [--net] | stop <name> | opens <name> --under <dir> --by <process> | writes <name> --under <dir> | by-process <name> | net <name> [--except <host:port>...] | ping
#
# The file-access and network trace of Sesame and its helpers (verify.md, Surfaces and Kit scripts; S6.8, S8.2,
# S8.3, S8.7; guesses K25 and K26): `fs_usage` under the administrator session, split by process name.
#   start <name>      starts `fs_usage -w -f filesys`; with --net a second `fs_usage -w -f network` runs in the
#                     same administrator session. Only the lines of processes named Sesame* are kept (the app
#                     `Sesame`, the helper `SesameHelper` in both its modes, the control tool SesameNetControl)
#                     are kept, and so are the lines of a process named exactly `git` (the helper's child that lists a
#                     repo's files; listed apart under that name, never counted as Sesame) and fs_usage's own report of
#                     lost events; live, in run/trace/<name>.fs (and .net). Start it before the app.
#   stop <name>       ends both, saves the lines to the evidence folder as trace-<name>.txt (and
#                     trace-net-<name>.txt) and prints how many there are. Exit 4 when the trace saw nothing.
#   opens <name> --under <dir> --by <process>
#                     the opens by that process of paths under the folder, told apart by a `stat` of each path:
#                     opens of directories are counted apart from opens of regular files. --by Sesame*
#                     means every process whose name starts with Sesame.
#   writes <name> --under <dir> [--by <process>]
#                     every write, create, rename, delete or open for writing under the folder, each line with the
#                     name of the process (a `git` write is listed as `WRITE git ...`); --by keeps one process.
#   by-process <name> how many events each process of the trace made (git has a row of its own).
#   net <name> [--except <host:port>...]
#                     every connect, sendto and sendmsg by a process named Sesame*, with what it went to,
#                     leaving out the lines that name an --except destination (the mirror) and the lines of
#                     the control tool SesameNetControl (counted apart).
#   ping              runs both traces for a moment and must see the kit's own file open and its own connect.
# The administrator session is the one `kit-perms.sh ask-admin` primed. This script never asks for a
# password: every administrator call is non-interactive, and a missing session is exit 3.
# Positive control: a trace that was meant to run and saw nothing is exit 4 (never a pass, never a fail).
# Exit codes: 0 done; 1 failed; 2 usage; 3 a person-step is missing; 4 the run is not valid.
. "$(dirname "$0")/kit-lib/common.sh"

TR="$KIT_ROOT/run/trace"
PIDS="$KIT_ROOT/run/pids"

usage() {
  cat >&2 <<'EOF'
usage: kit-trace.sh start <name> [--net] | stop <name> | opens <name> --under <dir> --by <process> | writes <name> --under <dir> | by-process <name> | net <name> [--except <host:port>...] | ping
       start <name> [--net]     start the fs_usage trace (and with --net the network trace) before the app
       stop <name>              end it and save trace-<name>.txt; exit 4 when it saw nothing
       opens <name> ...         opens by one process under a folder: directories apart from regular files
       writes <name> ...        writes, creates, renames and deletes under a folder (--by <process> keeps one process, e.g. git)
       by-process <name>        events per process
       net <name> ...           connect, sendto and sendmsg by processes named Sesame*, leaving out --except
       ping                     the trace must see the kit's own open and connect
EOF
}

valid_name() {
  case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# need_admin : status 3 when the administrator session is not primed (it never prompts).
need_admin() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo "NEEDS A PERSON: administrator rights: macOS only lets an administrator watch which files and connections Sesame uses; run scripts/kit-perms.sh ask-admin from a Terminal window you can type in, then run this again"
  return 3
}

pid_alive() { ps -p "$1" -o pid= >/dev/null 2>&1; }

# our_fs_usage <pid> : status 0 when the process at that pid is an fs_usage this script started. fs_run starts
# `/usr/bin/fs_usage -w -f filesys` or `-f network` (the shell that wrote the pid becomes it), so a pid that something else
# holds now, or an fs_usage someone else started with other flags, is not ours. GUESS (settled at the accept stage):
# `ps -p <pid> -o command=` shows the command line as it was started; if macOS hides the arguments of a process that
# runs as administrator, the bare name `fs_usage` is accepted, since the pid is one this script wrote to its own file.
our_fs_usage() {
  case "$(ps -p "$1" -o command= 2>/dev/null)" in
    *"fs_usage -w -f filesys"|*"fs_usage -w -f network") return 0 ;;
    "fs_usage"|*"/fs_usage") return 0 ;;
  esac
  return 1
}

# fs_run <filesys|network> <out file> <pid file> <awk program> : starts one fs_usage in the administrator
# session in the background. Its own pid is appended to the pid file by the shell that becomes it; the lines
# the awk program keeps go to the out file as they come.
fs_run() {
  ( sudo -n /bin/sh -c 'echo $$ >> "$1"; shift; exec "$@"' sh "$3" /usr/bin/fs_usage -w -f "$1" 2>/dev/null \
      | awk "$4" > "$2" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
}

# wait_running <pid file> <count> : waits up to 6 s until that many fs_usage processes run.
wait_running() {
  local pidf="$1" want="$2" i p n
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    n=0
    for p in $(cat "$pidf" 2>/dev/null); do pid_alive "$p" && n=$((n + 1)); done
    [ "$n" -ge "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

# stop_pids <pid file> : ends every fs_usage of ours that the file names (a break, then a stop, then a kill), removes the
# file. A pid that is gone is dropped quietly; a pid that a process other than our fs_usage holds now is dropped with one
# line and never killed (the pid was reused, or the file is stale).
stop_pids() {
  local pidf="$1" alive="" p sig i still
  for p in $(cat "$pidf" 2>/dev/null); do
    if our_fs_usage "$p"; then
      alive="$alive $p"
    elif pid_alive "$p"; then
      echo "pid $p is alive but is not an fs_usage of ours ($(ps -p "$p" -o command= 2>/dev/null)): not killed"
    fi
  done
  if [ -n "$alive" ]; then
    need_admin || { echo "the fs_usage processes keep running (pids:$alive)"; return 3; }
    for sig in INT TERM KILL; do
      for p in $alive; do our_fs_usage "$p" && sudo -n kill -"$sig" "$p" 2>/dev/null; done
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        still=""
        for p in $alive; do our_fs_usage "$p" && still="$still $p"; done
        [ -z "$still" ] && break
        sleep 0.2
      done
      alive="$still"
      [ -z "$alive" ] && break
    done
    [ -z "$alive" ] || { echo "the fs_usage processes did not end (pids:$alive)"; return 1; }
  fi
  rm -f "$pidf"
  sleep 0.5
  return 0
}

# lines_of <file> : how many lines the file holds.
lines_of() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# sesame_lines <file> : how many lines belong to a process named Sesame* (a git line or a drop line is not one).
sesame_lines() { awk '$NF ~ /^Sesame/ { n++ } END { print n + 0 }' "$1" 2>/dev/null; }

# git_lines <file> : how many lines belong to a process named exactly git.
git_lines() { awk '$NF ~ /^git(\.[0-9]+)?$/ { n++ } END { print n + 0 }' "$1" 2>/dev/null; }

# need_events <name> <fs|net> : status 4 and the reason when the trace was never made or saw nothing.
need_events() {
  local f="$TR/$1.$2"
  if [ ! -f "$f" ]; then
    if [ "$2" = net ]; then
      echo "not valid: trace $1 has no network part (start it with --net)"
    else
      echo "not valid: no trace named $1 ($f): kit-trace.sh start $1 first"
    fi
    return 4
  fi
  if [ "$(sesame_lines "$f")" = 0 ]; then
    echo "not valid: trace $1 saw nothing (no event of a process named Sesame*, so the positive control failed; git lines alone do not count); rerun"
    return 4
  fi
  return 0
}

# The live line filter: the lines of processes named Sesame*, the lines of a process named exactly `git` (the helper's
# child that lists a repo's files; it is listed apart under that name, never as Sesame) and fs_usage's own report of lost
# events (a line that holds `dropped`, which kit-net.sh summary reads; it is not a process line and never counts as an event).
KEEP_SESAME='$NF ~ /^Sesame/ || $NF ~ /^git(\.[0-9]+)?$/ || tolower($0) ~ /dropped/ { print; fflush() }'
KEEP_ALL='{ print; fflush() }'

# ---- start and stop -------------------------------------------------------------------------------

cmd_start() {
  local name="$1" net=0 pidf want=1
  shift
  valid_name "$name" || { usage; return 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --net) net=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  kit_need_ps || return 1
  need_admin || return 3
  mkdir -p "$TR" "$PIDS" || return 1
  pidf="$KIT_ROOT/run/pids/trace-$name.pid"
  if [ -f "$pidf" ]; then
    echo "trace $name is already running (kit-trace.sh stop $name first)"
    return 4
  fi
  rm -f "$TR/$name.fs" "$TR/$name.net"
  : > "$pidf"
  fs_run filesys "$TR/$name.fs" "$pidf" "$KEEP_SESAME"
  if [ "$net" = 1 ]; then
    fs_run network "$TR/$name.net" "$pidf" "$KEEP_SESAME"
    want=2
  fi
  if ! wait_running "$pidf" "$want"; then
    echo "the trace did not start: fs_usage is not running"
    stop_pids "$pidf" >/dev/null
    return 1
  fi
  echo "trace $name started: fs_usage -w -f filesys$( [ "$net" = 1 ] && echo ' and -f network'), lines of processes named Sesame* kept"
  echo "epoch $(date +%s)"
  return 0
}

cmd_stop() {
  local name="$1" pidf dir n g m
  valid_name "$name" || { usage; return 2; }
  kit_need_ps || return 1
  pidf="$KIT_ROOT/run/pids/trace-$name.pid"
  if [ ! -f "$pidf" ]; then
    echo "no trace $name is running"
    return 4
  fi
  stop_pids "$pidf" || return $?
  n="$(sesame_lines "$TR/$name.fs")"
  g="$(git_lines "$TR/$name.fs")"
  dir="$(kit_evidence_dir)"
  if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null && [ -f "$TR/$name.fs" ]; then
    { echo "# fs_usage -w -f filesys, trace $name, lines of processes named Sesame*"; cat "$TR/$name.fs"; } > "$dir/trace-$name.txt"
    echo "trace saved: $dir/trace-$name.txt"
    if [ -f "$TR/$name.net" ]; then
      { echo "# fs_usage -w -f network, trace $name, lines of processes named Sesame*"; cat "$TR/$name.net"; } > "$dir/trace-net-$name.txt"
      echo "trace saved: $dir/trace-net-$name.txt"
    fi
  fi
  echo "trace $name stopped: ${n:-0} lines from processes named Sesame*, ${g:-0} from git"
  if [ -f "$TR/$name.net" ]; then
    m="$(sesame_lines "$TR/$name.net")"
    echo "network trace $name: ${m:-0} lines from processes named Sesame*"
  fi
  need_events "$name" fs || return 4
  return 0
}

# ---- the readers ----------------------------------------------------------------------------------

# real_of <dir> : the real path of a folder (fs_usage prints /private/var for /var), or the folder itself.
real_of() {
  local r
  r="$(cd "$1" 2>/dev/null && pwd -P)"
  echo "${r:-$1}"
}

cmd_opens() {
  local name="$1" dir="" by="" real rows tmp count path kind
  local d_open=0 d_dist=0 f_open=0 f_dist=0 o_open=0 o_dist=0 shown=0
  shift
  valid_name "$name" || { usage; return 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --under) [ $# -ge 2 ] || { usage; return 2; }; dir="${2%/}"; shift 2 ;;
      --by) [ $# -ge 2 ] || { usage; return 2; }; by="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  [ -n "$dir" ] && [ -n "$by" ] || { usage; return 2; }
  need_events "$name" fs || return 4
  real="$(real_of "$dir")"
  tmp="$TR/$name.opens"
  awk -v mode=opens -v by="$by" -v under="$dir" -v under2="$real" -f "$KIT_LIB/tracefilter.awk" "$TR/$name.fs" > "$tmp"
  echo "opens by $by under $dir (trace $name):"
  while read -r count path; do
    kind="$(stat -f %HT "$path" 2>/dev/null)"
    case "$kind" in
      Directory) d_open=$((d_open + count)); d_dist=$((d_dist + 1)) ;;
      "Regular File")
        f_open=$((f_open + count)); f_dist=$((f_dist + 1))
        if [ "$shown" -lt 20 ]; then echo "  regular file opened $count times: $path"; shown=$((shown + 1)); fi ;;
      *) o_open=$((o_open + count)); o_dist=$((o_dist + 1)) ;;
    esac
  done < <(cut -f3 "$tmp" | sort | uniq -c | sed 's/^ *//')
  echo "directories: $d_open opens ($d_dist distinct)"
  echo "regular files: $f_open opens ($f_dist distinct)"
  echo "other or gone: $o_open opens ($o_dist distinct)"
  rm -f "$tmp"
  return 0
}

cmd_writes() {
  local name="$1" dir="" by="" real tmp n
  shift
  valid_name "$name" || { usage; return 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --under) [ $# -ge 2 ] || { usage; return 2; }; dir="${2%/}"; shift 2 ;;
      --by) [ $# -ge 2 ] || { usage; return 2; }; by="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  [ -n "$dir" ] || { usage; return 2; }
  need_events "$name" fs || return 4
  real="$(real_of "$dir")"
  tmp="$TR/$name.writes"
  awk -v mode=writes -v by="$by" -v under="$dir" -v under2="$real" -f "$KIT_LIB/tracefilter.awk" "$TR/$name.fs" > "$tmp"
  n="$(lines_of "$tmp")"
  while IFS=$'\t' read -r proc op path; do
    echo "WRITE $proc $op $path"
  done < "$tmp"
  echo "WRITES under $dir (trace $name): ${n:-0}"
  rm -f "$tmp"
  return 0
}

cmd_by_process() {
  local name="$1"
  [ $# = 1 ] && valid_name "$name" || { usage; return 2; }
  need_events "$name" fs || return 4
  awk -v mode=procs -f "$KIT_LIB/tracefilter.awk" "$TR/$name.fs" | sort | uniq -c | sort -rn | sed 's/^ */  /'
  return 0
}

cmd_net() {
  local name="$1" excepts="" tmp n=0 left=0 ctl=0 t op proc rest ex skip
  shift
  valid_name "$name" || { usage; return 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --except)
        shift
        case "${1:-}" in ""|--*) usage; return 2 ;; esac
        while [ $# -gt 0 ]; do
          case "$1" in --*) break ;; esac
          excepts="$excepts $1"
          shift
        done ;;
      *) usage; return 2 ;;
    esac
  done
  need_events "$name" net || return 4
  tmp="$TR/$name.netrows"
  awk -v mode=net -v by='Sesame*' -f "$KIT_LIB/tracefilter.awk" "$TR/$name.net" > "$tmp"
  while IFS=$'\t' read -r t op proc rest; do
    if [ "$proc" = SesameNetControl ]; then
      ctl=$((ctl + 1))
      continue
    fi
    skip=0
    for ex in $excepts; do
      case "$rest" in *"$ex"*) skip=1 ;; esac
    done
    if [ "$skip" = 1 ]; then
      left=$((left + 1))
      continue
    fi
    echo "NET $t $op $proc $rest"
    n=$((n + 1))
  done < "$tmp"
  echo "NET CONNECTIONS (connect, sendto and sendmsg by processes named Sesame*): $n; left out as --except: $left; control tool lines: $ctl"
  rm -f "$tmp"
  return 0
}

# ---- ping -----------------------------------------------------------------------------------------

cmd_ping() {
  local dir="$TR/ping" pidf="$KIT_ROOT/run/pids/trace-ping.pid" marker real opened="" connected=""
  kit_need_ps || return 1
  if ! sudo -n true 2>/dev/null; then
    echo "NEEDS A PERSON (administrator rights, first needed in slice 2): the file and network trace is not tried; run scripts/kit-perms.sh ask-admin first"
    return 3
  fi
  rm -rf "$dir"
  mkdir -p "$dir" "$PIDS" || return 1
  [ -f "$pidf" ] && { echo "not valid: a trace named ping is already running"; return 4; }
  marker="$dir/control-$$.txt"
  echo control > "$marker"
  : > "$pidf"
  fs_run filesys "$dir/ping.fs" "$pidf" "$KEEP_ALL"
  fs_run network "$dir/ping.net" "$pidf" "$KEEP_ALL"
  if ! wait_running "$pidf" 2; then
    stop_pids "$pidf" >/dev/null
    echo "KIT-TRACE PING FAILED: fs_usage did not start"
    return 1
  fi
  sleep 1
  cat "$marker" >/dev/null
  nc -z -w 1 127.0.0.1 9 >/dev/null 2>&1
  sleep 1
  stop_pids "$pidf" >/dev/null || { echo "KIT-TRACE PING FAILED: fs_usage did not stop"; return 1; }
  real="$(real_of "$dir")"
  opened="$(awk -v mode=opens -v by=cat -v under="$dir" -v under2="$real" -f "$KIT_LIB/tracefilter.awk" "$dir/ping.fs" | cut -f3 | sort -u | grep -c "control-")"
  connected="$(awk -v mode=net -v by=nc -f "$KIT_LIB/tracefilter.awk" "$dir/ping.net" | grep -c "connect")"
  rm -rf "$dir"
  if [ "${opened:-0}" -lt 1 ]; then
    echo "not valid: the trace did not see the kit's own file open (positive control); rerun"
    return 4
  fi
  if [ "${connected:-0}" -lt 1 ]; then
    echo "not valid: the network trace did not see the kit's own connect (positive control); rerun"
    return 4
  fi
  echo "KIT-TRACE PING OK: fs_usage saw the kit's own file open and its own connect"
  return 0
}

main() {
  case "$1" in
    start) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_start "$@" ;;
    stop) [ $# = 2 ] || { usage; return 2; }; cmd_stop "$2" ;;
    opens) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_opens "$@" ;;
    writes) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_writes "$@" ;;
    by-process) [ $# = 2 ] || { usage; return 2; }; cmd_by_process "$2" ;;
    net) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_net "$@" ;;
    ping) [ $# = 1 ] || { usage; return 2; }; cmd_ping ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-trace "$@")" main "$@"
exit $?

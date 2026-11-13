#!/bin/bash
# kit-net.sh start <name> [--process <prefix>...] | stop <name> | hosts [<name>] | hosts --selftest | control <name> | summary <name> [--mirror <host:port>] [--requests <file>] [--from <dir>] | ping
#
# The connection observer (verify.md, Surfaces and Kit scripts). Plan 1 builds what the real
# download needs: a nettop log between `start` and `stop`, the list of hosts a download contacted
# (`hosts`), their selftest, and the Doctor's ping. Plan 3 adds `control` (the planted 20 ms connection,
# the positive control of both observers) and `summary` (the two observers merged). Plan 5 adds `speech` (S4.8, S8.8; see cmd_speech).
#
#   start <name>   logs every TCP connection nettop sees, a sample every second (nettop takes whole seconds only), to
#                  run/net/<name>.nettop.csv (in chunks of 3 samples, so a stop never loses the buffer).
#                  Default scope for `stop`: process names starting with Sesame or curl.
#   stop <name>    ends the log, keeps only the scoped rows, saves it to the evidence folder as
#                  net-<name>.txt and prints each distinct peer address.
#   hosts [<name>] every host named in the connection log of run/net/<name>.curl.log (default
#                  name seed-real, written by `kit-mirror.sh seed --real`): the start host and each
#                  redirect hop, in the order contacted, then each peer address nettop saw.
#   hosts --selftest  a local two-hop redirect of the kit's own (127.0.0.1, then localhost, then
#                  cdn.localhost) is followed by curl; the hosts printed are compared with the
#                  fixture server's own record of the Host headers it received, and one nettop
#                  sample line of the fixture server process is printed.
#   control <name> plants one short connection (verify.md S8.7, guesses K25 and K26): compiles
#                  scripts/kit-lib/netcontrol.swift once to $KIT_ROOT/apps/SesameNetControl (the name prefix Sesame that
#                  both observers scope on covers it; a reset deletes apps/, so the first control after a reset compiles
#                  it again), which opens a local listener on a free port that is never the mirror's, connects, sends
#                  64 bytes and closes 20 ms later. Prints `PLANT <name> n=<k> pid=<pid> at=<epoch.ms>
#                  addr=127.0.0.1:<port>` and appends that line to run/net/<name>.plants. Needs no administrator rights.
#   summary <name> [--mirror <host:port>] [--requests <file>] [--from <dir>]
#                  merges the nettop log (run/net/<name>.scoped.csv, written by `stop`), the fs_usage network trace
#                  (run/trace/<name>.net, written by `kit-trace.sh start <name> --net`) and the plants. Prints
#                  `PLANT <k> seen-by fs_usage|nettop|both|none` for each plant and the product failures
#                  (scripts/kit-lib/netsummary.awk lists them). The mirror defaults to the host:port of run/mirror-host,
#                  the request log to run/mirror-requests.log. --from <dir> reads the three files from <dir> instead
#                  of run/net and run/trace (a test-only seam for hand-written samples). It starts nothing.
#                  Exit 0 clean, 1 a product failure, 4 the run is not valid (a plant the fs_usage trace missed,
#                  dropped events at a plant, an input missing).
#
# Exit codes (verify.md, Drive): 0 done; 1 error or blocked; 2 usage; 3 a person-step is missing;
# 4 a precondition did not hold (no connection log to read).
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/mirrorlib.sh"

RUN="$KIT_ROOT/run"
NET="$RUN/net"
TR="$RUN/trace"

usage() {
  cat >&2 <<'EOF'
usage: kit-net.sh start <name> [--process <prefix>...]
       kit-net.sh stop <name>
       kit-net.sh hosts [<name>]             hosts of the connection log of a download (default seed-real)
       kit-net.sh hosts --selftest           follow a local two-hop redirect and list its hosts
       kit-net.sh control <name>             plant one 20 ms connection to a local listener (the positive control)
       kit-net.sh summary <name> [--mirror <host:port>] [--requests <file>] [--from <dir>]
                                             both observers merged: each plant and who saw it, the product's connections
       kit-net.sh ping
       kit-net.sh speech <name> [--from <dir>]
                                             the speech daemon's connections in the full nettop log of a run (S4.8, S8.8)
EOF
}

# ---- start and stop -------------------------------------------------------------------------------

cmd_start() {
  local name="$1" scope="" pid
  shift
  case "$name" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --process) [ $# -ge 2 ] || { usage; return 2; }; scope="$scope $2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  [ -n "$scope" ] || scope=" Sesame curl"
  ml_need_nettop || return 1
  mkdir -p "$NET" "$RUN/pids" || return 1
  pid="$RUN/pids/net-$name.pid"
  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" 2>/dev/null; then
    echo "net log $name is already running"
    return 0
  fi
  rm -f "$NET/$name.nettop.csv" "$NET/$name.stop"
  printf '%s\n' "${scope# }" > "$NET/$name.scope"
  (
    while [ ! -e "$NET/$name.stop" ]; do
      nettop -x -n -m tcp -L 3 -s 1 >> "$NET/$name.nettop.csv" 2>> "$NET/$name.nettop.err" || break
    done
  ) >/dev/null 2>&1 </dev/null &
  echo $! > "$pid"
  disown 2>/dev/null
  echo "net log $name started: nettop every 1 s (its shortest delay), scope: ${scope# }"
}

# scoped_rows <csv> <prefixes...> : the header once, then the process rows and connection rows of
# the processes whose name starts with a prefix. A nettop process row is `<time>,<name>.<pid>,...`;
# its connection rows follow it as `<time>,tcp4 <local><-><peer>,...`.
scoped_rows() {
  local csv="$1"
  shift
  tr -d '\r' < "$csv" | awk -F, -v prefixes="$*" '
    BEGIN { n = split(prefixes, p, " ") }
    $1 == "time" { if (!header) { print; header = 1 } ; next }
    NF < 2 { next }
    $2 ~ /^(tcp|udp)/ { if (keep) print; next }
    { keep = 0; for (i = 1; i <= n; i++) if (index($2, p[i]) == 1) keep = 1; if (keep) print }
  '
}

# peers <scoped csv> : each distinct peer address of the connection rows.
peers() {
  awk -F, '$2 ~ /^(tcp|udp)/ { s = $2; sub(/^[^ ]+ /, "", s); sub(/^.*<->/, "", s); if (!(s in seen)) { seen[s] = 1; print s } }' "$1"
}

cmd_stop() {
  local name="$1" pidf="$RUN/pids/net-$1.pid" pid i scope dir out rows
  case "$name" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  if [ ! -f "$pidf" ]; then
    echo "no net log $name is running"
    return 4
  fi
  pid="$(cat "$pidf")"
  : > "$NET/$name.stop"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
  fi
  rm -f "$pidf"
  scope="$(cat "$NET/$name.scope" 2>/dev/null)"
  if [ ! -s "$NET/$name.nettop.csv" ]; then
    echo "net log $name stopped, but nettop wrote nothing ($(cat "$NET/$name.nettop.err" 2>/dev/null))"
    return 1
  fi
  # shellcheck disable=SC2086
  scoped_rows "$NET/$name.nettop.csv" $scope > "$NET/$name.scoped.csv"
  rows=$(( $(wc -l < "$NET/$name.scoped.csv") - 1 ))
  [ "$rows" -ge 0 ] || rows=0
  dir="$(kit_evidence_dir)"
  if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
    { echo "# nettop log $name, scope: $scope"; cat "$NET/$name.scoped.csv"; } > "$dir/net-$name.txt"
    echo "net log saved: $dir/net-$name.txt"
  fi
  echo "net log $name stopped: $rows rows for $scope"
  peers "$NET/$name.scoped.csv" | while read -r out; do echo "PEER $out"; done
  return 0
}

# ---- hosts ----------------------------------------------------------------------------------------

print_hosts() { # print_hosts <name>
  local name="$1" log="$NET/$1.curl.log" h n=0
  while read -r h; do
    [ -n "$h" ] || continue
    echo "HOST $h"
    n=$((n + 1))
  done < <(ml_hosts "$log")
  echo "HOSTS $n contacted (from $log)"
  if [ -s "$NET/$name.scoped.csv" ]; then
    peers "$NET/$name.scoped.csv" | while read -r h; do echo "PEER $h"; done
  fi
}

cmd_hosts() {
  local name="${1:-seed-real}"
  if [ ! -s "$NET/$name.curl.log" ]; then
    echo "no connection log for $name ($NET/$name.curl.log): scripts/kit-mirror.sh seed --real writes it"
    return 4
  fi
  print_hosts "$name"
}

# One nettop sample line of one process (its summary row), or `blocked:` and status 1.
nettop_sample() { # nettop_sample <pid>
  local out line
  ml_need_nettop || return 1
  out="$(nettop -P -x -L 1 -s 1 -p "$1" 2>&1)"
  line="$(printf '%s\n' "$out" | tr -d '\r' | awk 'NR == 2 && NF { print; exit }')"
  if [ -z "$line" ]; then
    echo "nettop printed no row for pid $1: $out"
    return 1
  fi
  echo "NETTOP $line"
}

cmd_hosts_selftest() {
  local dir="$NET/hosts-selftest" n="embeddinggemma-2-Q8_0.gguf" base size sha mine seen pid netok=0 rc=0
  rm -rf "$dir"
  mkdir -p "$dir/served" || return 1
  head -c 20000 /dev/urandom > "$dir/served/$n"
  size="$(stat -f %z "$dir/served/$n")"
  sha="$(shasum -a 256 "$dir/served/$n" | awk '{ print $1 }')"
  printf '%s\t%s\t%s\n' "$n" "$size" "$sha" > "$dir/table.tsv"
  ml_start fixture hostsfixture --root "$dir/served" --table "$dir/table.tsv" --log "$dir/fixture.log" || return 1
  pid="$(cat "$RUN/pids/hostsfixture.pid")"
  base="http://127.0.0.1:$ML_PORT$ML_PATH/selftest"

  # nettop is refused in some sandboxes; the redirect part below does not need it.
  if ml_need_nettop >/dev/null 2>&1; then
    cmd_start hosts-selftest-net >/dev/null && netok=1
  fi
  curl -sS -L --noproxy '*' -v --max-time 30 -o "$dir/got.bin" "$base/$n" 2> "$dir/selftest.curl.log" </dev/null
  if [ $? != 0 ]; then
    echo "curl did not follow the redirect (log: $dir/selftest.curl.log)"
    ml_stop hostsfixture
    return 1
  fi
  [ "$netok" = 1 ] && cmd_stop hosts-selftest-net >/dev/null

  mine="$(ml_hosts "$dir/selftest.curl.log" | sort | tr '\n' ' ')"
  seen="$(awk '{ h = $1; sub(/:[0-9]+$/, "", h); print h }' "$dir/fixture.log" | sort -u | tr '\n' ' ')"
  while read -r h; do echo "HOST $h"; done < <(ml_hosts "$dir/selftest.curl.log")
  echo "HOSTS $(ml_hosts "$dir/selftest.curl.log" | wc -l | tr -d ' ') contacted"
  if [ "$mine" != "$seen" ]; then
    echo "HOSTS SELFTEST FAILED: curl's log names [$mine] but the fixture server received requests for [$seen]"
    ml_stop hostsfixture
    return 1
  fi
  [ "$(cmp -s "$dir/got.bin" "$dir/served/$n" && echo same)" = same ] || {
    echo "HOSTS SELFTEST FAILED: the followed download is not the served file"
    ml_stop hostsfixture
    return 1
  }
  nettop_sample "$pid" || rc=1
  ml_stop hostsfixture
  [ $rc = 0 ] && echo "HOSTS SELFTEST OK"
  return $rc
}

# ---- control: the planted short connection ---------------------------------------------------------

cmd_control() {
  local name="$1" src="$KIT_LIB/netcontrol.swift" bin="$KIT_ROOT/apps/SesameNetControl" n=1 mirror_port line
  local args
  case "$name" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  [ -f "$src" ] || { echo "scripts/kit-lib/netcontrol.swift is missing ($src)"; return 1; }
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    mkdir -p "$KIT_ROOT/apps" "$RUN/modcache" || return 1
    rm -f "$bin"
    if ! CLANG_MODULE_CACHE_PATH="$RUN/modcache" swiftc -O -module-cache-path "$RUN/modcache" -o "$bin" "$src" \
        >"$RUN/netcontrol-build.log" 2>&1; then
      rm -f "$bin"
      echo "could not compile scripts/kit-lib/netcontrol.swift (compiler output: $RUN/netcontrol-build.log)"
      return 1
    fi
  fi
  mkdir -p "$NET" || return 1
  [ -f "$NET/$name.plants" ] && n=$(( $(wc -l < "$NET/$name.plants" | tr -d ' ') + 1 ))
  args=(--name "$name" --n "$n")
  mirror_port="$(cat "$RUN/mirror.port" 2>/dev/null)"
  [ -n "$mirror_port" ] && args+=(--avoid "$mirror_port")
  if ! line="$("$bin" "${args[@]}" 2>&1)"; then
    echo "SesameNetControl failed: $line"
    return 1
  fi
  case "$line" in
    "PLANT "*) ;;
    *) echo "SesameNetControl printed no PLANT line: $line"; return 1 ;;
  esac
  printf '%s\n' "$line" >> "$NET/$name.plants"
  printf '%s\n' "$line"
}

# ---- summary: both observers merged ------------------------------------------------------------------

cmd_summary() {
  local name="$1" mirror="" requests="" from="" netdir="$NET" trdir="$TR"
  local csv plants trace first z sign off out rc dir
  shift
  case "$name" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --mirror) [ $# -ge 2 ] || { usage; return 2; }; mirror="$2"; shift 2 ;;
      --requests) [ $# -ge 2 ] || { usage; return 2; }; requests="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || { usage; return 2; }; from="${2%/}"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [ -n "$from" ]; then
    netdir="$from"
    trdir="$from"
  fi
  [ -n "$requests" ] || requests="$RUN/mirror-requests.log"
  if [ -z "$mirror" ] && [ -f "$RUN/mirror-host" ]; then
    mirror="$(sed -e 's#^[A-Za-z]*://##' -e 's#/.*$##' "$RUN/mirror-host")"
  fi
  csv="$netdir/$name.scoped.csv"
  plants="$netdir/$name.plants"
  trace="$trdir/$name.net"
  if [ ! -s "$plants" ]; then
    echo "not valid: no planted connection for $name ($plants): kit-net.sh control $name plants one; rerun"
    return 4
  fi
  if [ ! -s "$csv" ]; then
    echo "not valid: no nettop log for $name ($csv): kit-net.sh start $name before the app and kit-net.sh stop $name after it; rerun"
    return 4
  fi
  if [ ! -f "$trace" ]; then
    echo "not valid: no network trace for $name ($trace): kit-trace.sh start $name --net before the app; rerun"
    return 4
  fi
  first="$(awk '/^PLANT / { for (i = 1; i <= NF; i++) if ($i ~ /^at=/) { print substr($i, 4); exit } }' "$plants")"
  first="${first%%.*}"
  if [ -z "$first" ]; then
    echo "not valid: $plants holds no PLANT line with a time (at=<epoch>); rerun"
    return 4
  fi
  # both traces print the local time of day, so the plants' and the mirror log's epochs are read in the local zone
  z="$(date -r "$first" +%z)"
  sign=1
  [ "${z:0:1}" = "-" ] && sign=-1
  off=$(( sign * (10#${z:1:2} * 3600 + 10#${z:3:2} * 60) ))
  [ -f "$requests" ] || echo "NOTE no mirror request log ($requests): every product connection is then after the last model request"
  [ -n "$mirror" ] || echo "NOTE no mirror address (--mirror, or run/mirror-host): every product connection then counts as another destination"
  out="$(awk -v nettop="$csv" -v trace="$trace" -v plants="$plants" -v requests="$requests" -v mirror="$mirror" -v off="$off" \
    -f "$KIT_LIB/netsummary.awk")"
  rc=$?
  printf '%s\n' "$out"
  if [ -z "$from" ]; then
    dir="$(kit_evidence_dir)"
    if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
      { echo "# kit-net.sh summary $name: each planted 20 ms connection and which observer saw it"; printf '%s\n' "$out" | awk '/^PLANT |^NOT VALID|^NOTE /'; } > "$dir/net-control-$name.txt"
      echo "plants saved: $dir/net-control-$name.txt"
    fi
  fi
  return $rc
}

# ---- speech (plan 5, S4.8, S8.8) -----------------------------------------------------------------

# cmd_speech <name> [--from <dir>] : the connections of the speech daemon in the full nettop log of the run (run/net/<name>.nettop.csv,
# written by `start`, which keeps every process: the Sesame-scoped copy drops the daemon). Every process whose name holds `speech` counts
# (speechrecognitiond, localspeechrecognition, corespeechd). One line a distinct connection, `SPEECH <process> <local> -> <peer>
# local|REMOTE`; a peer is local when it is 127.x, ::1 or localhost. Exit 1 when one is REMOTE; exit 0 when the daemon is in the log and
# none is; exit 3 NEEDS-A-PERSON when no process of that name is in the log (the daemon's connections cannot be attributed to the run:
# design U7); exit 4 when there is no log. --from <dir> reads <dir>/<name>.nettop.csv (a test-only seam for hand-written logs).
cmd_speech() {
  local name="$1" dir="$NET" csv out rc
  shift
  case "$name" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] && [ -n "$2" ] || { usage; return 2; }; dir="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  csv="$dir/$name.nettop.csv"
  if [ ! -s "$csv" ]; then
    echo "not valid: no connection log for $name ($csv): kit-net.sh start $name before the app, and stop it after"
    return 4
  fi
  out="$(tr -d '\r' < "$csv" | awk -F, '
    $1 == "time" || NF < 2 { next }
    $2 ~ /^(tcp|udp)[46]? / {
      if (!keep) next
      s = $2; sub(/^[^ ]+ /, "", s); split(s, a, "<->")
      remote = (a[2] ~ /^(127\.|localhost[:.]|\[?::1\]?[:.])/) ? "local" : "REMOTE"
      key = proc "\t" a[1] "\t" a[2]
      if (!(key in seen)) { seen[key] = 1; printf "SPEECH %s %s -> %s %s\n", proc, a[1], a[2], remote; n++; if (remote == "REMOTE") bad++ }
      next
    }
    { proc = $2; sub(/\.[0-9]+$/, "", proc); keep = (index(tolower(proc), "speech") > 0); if (keep) found++ }
    END { printf "TOTAL %d %d %d\n", found + 0, n + 0, bad + 0 }')"
  printf '%s\n' "$out" | grep -v '^TOTAL '
  set -- $(printf '%s\n' "$out" | awk '$1 == "TOTAL" { print $2, $3, $4 }')
  if [ "${1:-0}" = 0 ]; then
    echo "NEEDS-A-PERSON: cannot attribute the speech daemon's connections to this run (no process named speech... in $csv)"
    return 3
  fi
  if [ "${3:-0}" != 0 ]; then
    echo "SPEECH FAIL: $3 of $2 connections of the speech daemon go to a non-local host"
    return 1
  fi
  echo "SPEECH OK: the speech daemon is in the log with ${2:-0} connections, all to a local address"
  return 0
}

# ---- ping -----------------------------------------------------------------------------------------

cmd_ping() {
  ml_need_nettop || return 1
  echo "OK nettop answers for the kit's own process (pid $$): a sample was taken and read"
  # The fs_usage network trace (the second observer) needs administrator rights, which slice 1 never asks for.
  echo "NEEDS A PERSON (administrator rights, first needed in slice 2): fs_usage network trace and the planted 20 ms control"
  return 3
}

main() {
  case "$1" in
    start) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_start "$@" ;;
    stop) [ $# = 2 ] || { usage; return 2; }; cmd_stop "$2" ;;
    hosts)
      case "$2" in
        --selftest) [ $# = 2 ] || { usage; return 2; }; cmd_hosts_selftest ;;
        *) [ $# -le 2 ] || { usage; return 2; }; cmd_hosts "$2" ;;
      esac ;;
    ping) cmd_ping ;;
    control) [ $# = 2 ] || { usage; return 2; }; cmd_control "$2" ;;
    summary) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_summary "$@" ;;
    speech) [ $# -ge 2 ] || { usage; return 2; }; shift; cmd_speech "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-net "$@")" main "$@"
exit $?

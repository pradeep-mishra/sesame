#!/bin/bash
# Shared by scripts/kit-mirror.sh and scripts/kit-net.sh. Sourced after common.sh, never run.
# bash 3.2 compatible.
#
# Files under $KIT_ROOT/run (a kit reset deletes the folder; the servers notice and exit):
#   pids/<name>.pid  the server's own pid (kit-reset.sh --cleanup stops every pids/*.pid)
#   <name>.port      the port it listens on (127.0.0.1)
#   mirror-host      the model mirror's base URL, read by kit-launch.sh for SESAME_MODEL_HOST
#   mirror-rate      `max` or bytes per second; mirror-offline exists while the mirror is "offline"
#   mirror-requests.log   one line per finished request (see scripts/kit-lib/mirrorserver.swift)
#   net/<name>.*     connection logs (kit-net.sh)

# The model host, from design section 7: repository and pinned revision.
ML_REVISION="bfcd298762cc34d0357ece5ebdd31791a3a374d8"
ML_REAL_BASE="https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/$ML_REVISION"
ML_PATH="/ggml-org/embeddinggemma-2-GGUF/resolve/$ML_REVISION"

# ml_start <mirror|fixture> <name> <server args...> : starts scripts/kit-lib/mirrorserver.swift in the
# background; sets ML_PORT. Its output goes to run/<name>.out so a caller's pipe is never held open.
ml_start() {
  local mode="$1" name="$2" bin pidf portf i
  shift 2
  bin="$(kit_tool mirrorserver)" || {
    echo "could not compile scripts/kit-lib/mirrorserver.swift (compiler output: $KIT_ROOT/run/bin/mirrorserver.log)"
    return 1
  }
  mkdir -p "$KIT_ROOT/run/pids" || return 1
  pidf="$KIT_ROOT/run/pids/$name.pid"
  portf="$KIT_ROOT/run/$name.port"
  rm -f "$pidf" "$portf"
  "$bin" "$mode" --pidfile "$pidf" --portfile "$portf" "$@" >"$KIT_ROOT/run/$name.out" 2>&1 </dev/null &
  disown 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
    [ -s "$portf" ] && break
    sleep 0.1
  done
  if [ ! -s "$portf" ]; then
    echo "the $name server did not start: $(cat "$KIT_ROOT/run/$name.out" 2>/dev/null)"
    return 1
  fi
  ML_PORT="$(cat "$portf")"
  return 0
}

# ml_alive <name> : status 0 when the server's pid file names a live process.
ml_alive() {
  local pid
  pid="$(cat "$KIT_ROOT/run/pids/$1.pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ml_stop <name> : stops the server and removes its pid and port files. Always status 0.
ml_stop() {
  local name="$1" pid i
  pid="$(cat "$KIT_ROOT/run/pids/$name.pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$KIT_ROOT/run/pids/$name.pid" "$KIT_ROOT/run/$name.port"
  return 0
}

# ml_hosts <curl -v log> : every host curl contacted, one per line, in the order first contacted,
# without ports. Read from curl's own request lines (`> Host: <host>[:port]`) and its connect lines
# (`* Connected to <host> (<ip>) port <n>`), so a hop that only redirected is still listed.
ml_hosts() {
  tr -d '\r' < "$1" | awk '
    /^> [Hh]ost: / { h = $3; sub(/:[0-9]+$/, "", h); if (!(h in seen)) { seen[h] = 1; print h } }
    /^\* Connected to / { h = $4; if (!(h in seen)) { seen[h] = 1; print h } }
  '
}

# ml_need_nettop : status 1 and one `blocked:` line when nettop is refused (the sandbox refuses it
# with `NStatManagerCreate failed`), so a refused nettop never reads as "no connections".
ml_need_nettop() {
  local out rc
  out="$(nettop -P -x -L 1 -s 1 -p $$ 2>&1)"
  rc=$?
  case "$out" in
    *"NStatManagerCreate failed"*|*"Operation not permitted"*)
      echo "blocked: nettop is refused here (NStatManagerCreate failed, the sandbox's \"Operation not permitted\"), so no connection sample can be taken; run this from a shell that may run nettop"
      return 1 ;;
  esac
  if [ "$rc" != 0 ] || [ -z "$out" ]; then
    echo "nettop did not answer (exit $rc): $out"
    return 1
  fi
  return 0
}

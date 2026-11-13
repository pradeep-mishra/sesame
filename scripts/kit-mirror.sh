#!/bin/bash
# kit-mirror.sh start | stop | status | rate <bytes-per-second|max> | offline | online | requests
#               seed --real | seed --selftest
#
# The local model host (verify.md, Starting state, Model: mirror): serves the two model files from
# $KIT_ROOT/cache/ on 127.0.0.1 with a request log, at a throttled or full rate, and can be switched
# offline (every connection is reset) and online again. The app is pointed at it by
# kit-launch.sh start --mirror|--mirror-full, which reads $KIT_ROOT/run/mirror-host.
#
# seed makes the cache: `seed --real` is the one real download from the model host with the size and
# SHA-256 of design section 7 compared (scripts/kit-lib/models.tsv); `seed --selftest` runs the same
# comparison code against a local fixture server of the kit's own, into run/seed-selftest/ only.
#
# Exit codes (verify.md, Drive): 0 done; 1 error or a file that differs; 2 usage; 4 the mirror is not
# running (a precondition that did not hold).
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/mirrorlib.sh"

RUN="$KIT_ROOT/run"

usage() {
  cat >&2 <<'EOF'
usage: kit-mirror.sh start                   start the mirror on a free local port, rate max
       kit-mirror.sh stop                    stop it (the request log is copied to the evidence folder)
       kit-mirror.sh status                  a HEAD request for each model file name, with its status
       kit-mirror.sh rate <bytes/s|max>      throttle (or release) the download rate
       kit-mirror.sh offline | online        reset every connection | serve again
       kit-mirror.sh requests                the request log: time, method, path, range, status, bytes
       kit-mirror.sh seed --real             the one real download into cache/, size and SHA-256 checked
       kit-mirror.sh seed --selftest         the same check against a local fixture server (run/seed-selftest/)
EOF
}

mirror_url() { cat "$RUN/mirror-host" 2>/dev/null; }

need_running() {
  if ! ml_alive mirror || [ ! -f "$RUN/mirror-host" ]; then
    echo "no mirror running: start it with scripts/kit-mirror.sh start"
    return 4
  fi
  return 0
}

# ---- start, stop, rate, offline ------------------------------------------------------------------

cmd_start() {
  if ml_alive mirror && [ -f "$RUN/mirror-host" ]; then
    echo "mirror already running at $(mirror_url) (listening on 127.0.0.1:$(cat "$RUN/mirror.port" 2>/dev/null))"
    return 0
  fi
  mkdir -p "$RUN" "$KIT_ROOT/cache" || return 1
  rm -f "$RUN/mirror-host" "$RUN/mirror-offline"
  echo max > "$RUN/mirror-rate"
  ml_start mirror mirror --root "$KIT_ROOT/cache" --log "$RUN/mirror-requests.log" \
    --rate-file "$RUN/mirror-rate" --offline-file "$RUN/mirror-offline" || return 1
  printf 'http://127.0.0.1:%s\n' "$ML_PORT" > "$RUN/mirror-host"
  echo "mirror listening on 127.0.0.1:$ML_PORT ($(mirror_url)), serving $KIT_ROOT/cache, rate max"
}

cmd_stop() {
  local dir
  if ml_alive mirror; then
    ml_stop mirror
    echo "mirror stopped"
  else
    ml_stop mirror
    echo "mirror not running"
  fi
  rm -f "$RUN/mirror-host" "$RUN/mirror-rate" "$RUN/mirror-offline"
  dir="$(kit_evidence_dir)"
  if [ -n "$dir" ] && [ -s "$RUN/mirror-requests.log" ] && mkdir -p "$dir" 2>/dev/null; then
    cp "$RUN/mirror-requests.log" "$dir/mirror-requests.log" && echo "request log saved: $dir/mirror-requests.log"
  fi
  return 0
}

cmd_rate() {
  case "$1" in
    max) ;;
    ""|*[!0-9]*|0*) usage; return 2 ;;
  esac
  need_running || return $?
  echo "$1" > "$RUN/mirror-rate"
  echo "rate $1"
}

cmd_offline() {
  need_running || return $?
  : > "$RUN/mirror-offline"
  echo "mirror offline: every connection is reset until scripts/kit-mirror.sh online"
}

cmd_online() {
  need_running || return $?
  rm -f "$RUN/mirror-offline"
  echo "mirror online"
}

# ---- status, requests ----------------------------------------------------------------------------

cmd_status() {
  local name size sha out rc code len bad=0 rate offline
  if ! ml_alive mirror || [ ! -f "$RUN/mirror-host" ]; then
    echo "note: no mirror was running, so status started it (scripts/kit-mirror.sh stop ends it)"
    cmd_start || return 1
  fi
  rate="$(cat "$RUN/mirror-rate" 2>/dev/null)"
  offline=no; [ -e "$RUN/mirror-offline" ] && offline=yes
  echo "mirror running at $(mirror_url) rate ${rate:-max} offline $offline"
  while read -r name size sha; do
    out="$(curl -sSI --noproxy '*' --max-time 10 "$(mirror_url)$ML_PATH/$name" 2>&1)"
    rc=$?
    if [ $rc != 0 ]; then
      if [ "$offline" = yes ]; then
        echo "HEAD $name no answer (the mirror is offline: connection reset)"
      else
        echo "HEAD $name no answer (curl exit $rc: $out)"; bad=1
      fi
      continue
    fi
    code="$(printf '%s\n' "$out" | tr -d '\r' | awk 'NR == 1 { print $2 }')"
    len="$(printf '%s\n' "$out" | tr -d '\r' | awk 'tolower($1) == "content-length:" { print $2 }' | tail -1)"
    echo "HEAD $name $code content-length ${len:-none}"
  done < <(kit_models)
  return $bad
}

cmd_requests() {
  local log="$RUN/mirror-requests.log"
  if [ ! -s "$log" ]; then
    echo "no requests logged yet ($log)"
    return 0
  fi
  echo "time method path range status bytes"
  tr -d '\r' < "$log"
  echo "$(wc -l < "$log" | tr -d ' ') requests in $log"
}

# ---- seed: the download and its comparison -------------------------------------------------------

# seed_cached <file> <size> <sha256> : status 0 when the file exists and has exactly that size and SHA-256.
seed_cached() {
  [ -f "$1" ] || return 1
  [ "$(stat -f %z "$1")" = "$2" ] || return 1
  [ "$(shasum -a 256 "$1" | awk '{ print $1 }')" = "$3" ]
}

# seed_run <table.tsv: name TAB size TAB sha256> <base url> <dest dir> <curl -v log>
# For each name in the table: a file already in <dest> with the table's size and SHA-256 is left alone and nothing is
# requested (`U1 CACHED <name>`). Otherwise HEAD (Content-Length, x-linked-etag), download to <dest>/<name>.partial and
# compare size and SHA-256 with the table: `U1 OK <name>` (the .partial is moved over any old file, in one step) or
# `U1 DIFFERS <name>`. Whatever fails, only the .partial is deleted: a file that was in <dest> before is never removed or
# changed except by a download that was checked. Status 0 when every file is OK or CACHED, else 1.
# The same code serves `seed --real` and `seed --selftest`.
seed_run() {
  local table="$1" base="$2" dest="$3" clog="$4" name size sha url head hops rc part len lsize etag got gsha bad=0
  mkdir -p "$dest" || return 1
  : > "$clog"
  while IFS=$'\t' read -r name size sha; do
    [ -n "$name" ] || continue
    if seed_cached "$dest/$name" "$size" "$sha"; then
      echo "U1 CACHED $name (size $size and SHA-256 match the table; nothing downloaded)"
      continue
    fi
    url="$base/$name"
    head="$(curl -sSIL -v --max-time 120 "$url" 2>>"$clog" </dev/null)"
    rc=$?
    if [ $rc != 0 ]; then
      echo "HEAD $name failed (curl exit $rc)"; bad=1; continue
    fi
    # Content-Length is the final hop's, when it answered 2xx (a CDN link signed for GET may refuse HEAD).
    hops="$(printf '%s\n' "$head" | tr -d '\r' | awk '/^HTTP\// { printf "%s%s", (n++ ? " -> " : ""), $2 }')"
    len="$(printf '%s\n' "$head" | tr -d '\r' | awk '/^HTTP\// { ok = ($2 ~ /^2/); v = "" } ok && tolower($1) == "content-length:" { v = $2 } END { print v }')"
    etag="$(printf '%s\n' "$head" | tr -d '\r' | awk 'tolower($1) == "x-linked-etag:" { print $2; exit }')"
    lsize="$(printf '%s\n' "$head" | tr -d '\r' | awk 'tolower($1) == "x-linked-size:" { print $2; exit }')"
    echo "HEAD $name status: $hops"
    echo "HEAD $name Content-Length: ${len:-none}"
    echo "HEAD $name x-linked-etag: ${etag:-none}"
    [ -z "$lsize" ] || echo "HEAD $name x-linked-size: $lsize"
    [ "${len:-$lsize}" = "$size" ] || echo "NOTE $name HEAD size ${len:-${lsize:-none}} is not the expected $size"
    if [ -n "$etag" ] && [ "$(printf '%s' "$etag" | tr -d '"')" != "$sha" ]; then
      echo "NOTE $name x-linked-etag is not the expected SHA-256"
    fi

    part="$dest/$name.partial"
    rm -f "$part"
    echo "downloading $name"
    curl -sS -L --fail -v --connect-timeout 30 --speed-limit 1000 --speed-time 60 -o "$part" "$url" 2>>"$clog" </dev/null
    rc=$?
    if [ $rc != 0 ]; then
      echo "download of $name failed (curl exit $rc; connection log: $clog); any file already cached is kept"; rm -f "$part"; bad=1; continue
    fi
    got="$(stat -f %z "$part")"
    gsha="$(shasum -a 256 "$part" | awk '{ print $1 }')"
    if [ "$got" = "$size" ] && [ "$gsha" = "$sha" ]; then
      mv "$part" "$dest/$name"
      echo "U1 OK $name"
    else
      rm -f "$part"
      echo "U1 DIFFERS $name"
      echo "  the download is discarded; any file already cached is kept"
      bad=1
    fi
    echo "  size $got (expected $size) sha256 $gsha (expected $sha)"
  done < "$table"
  return $bad
}

cmd_seed_real() {
  local log="$RUN/net/seed-real.curl.log" rc dir netrc
  mkdir -p "$KIT_ROOT/cache" "$RUN/net" || return 1
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-net.sh" start seed-real
  netrc=$?
  [ $netrc = 0 ] || echo "note: the nettop log was not started (exit $netrc); the connection log is curl's own: $log"
  seed_run "$KIT_LIB/models.tsv" "$ML_REAL_BASE" "$KIT_ROOT/cache" "$log"
  rc=$?
  [ $netrc = 0 ] && KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-net.sh" stop seed-real
  dir="$(kit_evidence_dir)"
  if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
    cp "$log" "$dir/net-seed-real-curl.txt" && echo "connection log saved: $dir/net-seed-real-curl.txt"
  fi
  echo "connection log: $log"
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-net.sh" hosts
  return $rc
}

selftest_fail() {
  echo "SEED SELFTEST FAILED: $1"
  ml_stop seedfixture
  return 1
}

cmd_seed_selftest() {
  local dir="$RUN/seed-selftest" n1 n2 n3 name size sha out="$RUN/seed-selftest/seed.out" rc before after base byte new lines
  n1="embeddinggemma-2-Q8_0.gguf"
  n2="mmproj-embeddinggemma-2-Q8_0.gguf"
  n3="embeddinggemma-selftest-wrongsize.gguf"
  rm -rf "$dir"
  mkdir -p "$dir/served" "$dir/got" "$dir/previous" "$KIT_ROOT/cache" || return 1
  # The two small files; the table is made from their intended bytes. The second is then served with
  # one byte changed, which is what a corrupt download looks like.
  head -c 30000 /dev/urandom > "$dir/served/$n1"
  head -c 50000 /dev/urandom > "$dir/served/$n2"
  head -c 20000 /dev/urandom > "$dir/served/$n3"
  : > "$dir/table.tsv"
  for name in "$n1" "$n2"; do
    printf '%s\t%s\t%s\n' "$name" "$(stat -f %z "$dir/served/$name")" \
      "$(shasum -a 256 "$dir/served/$name" | awk '{ print $1 }')" >> "$dir/table.tsv"
  done
  # The fixture server knows all three files as they are served; the third is asked for later with a table that
  # claims one byte more than it is (a download of the wrong size).
  cp "$dir/table.tsv" "$dir/fixture-table.tsv"
  sha="$(shasum -a 256 "$dir/served/$n3" | awk '{ print $1 }')"
  printf '%s\t%s\t%s\n' "$n3" "$(stat -f %z "$dir/served/$n3")" "$sha" >> "$dir/fixture-table.tsv"
  printf '%s\t%s\t%s\n' "$n3" "$(( $(stat -f %z "$dir/served/$n3") + 1 ))" "$sha" > "$dir/table3.tsv"
  byte="$(dd if="$dir/served/$n2" bs=1 skip=777 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
  new=$(( (byte + 1) % 256 ))
  printf "\\$(printf '%03o' "$new")" | dd of="$dir/served/$n2" bs=1 seek=777 conv=notrunc 2>/dev/null

  ml_start fixture seedfixture --root "$dir/served" --table "$dir/fixture-table.tsv" --log "$dir/fixture.log" || return 1
  base="http://127.0.0.1:$ML_PORT$ML_PATH"
  before="$(ls -A "$KIT_ROOT/cache" | tr '\n' ' ')"

  # --noproxy: the fixture is on this machine, never behind a proxy.
  seed_run_local "$dir/table.tsv" "$base" "$dir/got" "$dir/curl.log" | tee "$out"
  rc=${PIPESTATUS[0]}

  [ "$rc" = 1 ] || { selftest_fail "seed_run exited $rc, expected 1 (one file differs)"; return 1; }
  grep -qx "U1 OK $n1" "$out" || { selftest_fail "no line 'U1 OK $n1'"; return 1; }
  grep -qx "U1 DIFFERS $n2" "$out" || { selftest_fail "no line 'U1 DIFFERS $n2'"; return 1; }
  for name in "$n1" "$n2"; do
    grep -q "^HEAD $name Content-Length: [0-9]" "$out" || { selftest_fail "no HEAD Content-Length line for $name"; return 1; }
    grep -q "^HEAD $name x-linked-etag: \"" "$out" || { selftest_fail "no HEAD x-linked-etag line for $name"; return 1; }
  done
  [ -f "$dir/got/$n1" ] || { selftest_fail "the matching file was not kept as $dir/got/$n1"; return 1; }
  [ ! -e "$dir/got/$n2" ] || { selftest_fail "the differing file was kept under its real name"; return 1; }
  # The fixture's own record of what was asked, host by host: two hops before the bytes.
  grep -q "^localhost:$ML_PORT GET /hop-a/$n1 302" "$dir/fixture.log" \
    && grep -q "^cdn.localhost:$ML_PORT GET /blob/$n1 200" "$dir/fixture.log" \
    || { selftest_fail "the fixture log does not show the two-hop redirect for $n1"; return 1; }
  after="$(ls -A "$KIT_ROOT/cache" | tr '\n' ' ')"
  [ "$before" = "$after" ] || { selftest_fail "cache/ changed ($before -> $after)"; return 1; }

  # A good cache downloads nothing: $n1 is in got/ and matches the table, so a second run must not ask the fixture
  # server for it (its request log is the measure); $n2 is still served corrupted and is asked for again.
  lines="$(wc -l < "$dir/fixture.log" | tr -d ' ')"
  seed_run_local "$dir/table.tsv" "$base" "$dir/got" "$dir/curl2.log" | tee "$dir/seed2.out"
  rc=${PIPESTATUS[0]}
  [ "$rc" = 1 ] || { selftest_fail "the second seed_run exited $rc, expected 1 (one file still differs)"; return 1; }
  grep -q "^U1 CACHED $n1 " "$dir/seed2.out" || { selftest_fail "the second run did not say 'U1 CACHED $n1'"; return 1; }
  [ "$(tail -n +$((lines + 1)) "$dir/fixture.log" | grep -c "/$n1 ")" = 0 ] \
    || { selftest_fail "the second run asked the fixture server for $n1 although the cached file matched the table"; return 1; }
  tail -n +$((lines + 1)) "$dir/fixture.log" | grep -q "/$n2 " \
    || { selftest_fail "the second run did not ask for $n2, which was not cached"; return 1; }
  echo "SEED SELFTEST good cache: no request for $n1 in the second run (fixture log), $n2 asked for again"

  # A failed download keeps the previous file: $n2 (a differing download) and $n3 (a download of the wrong size)
  # each start from a previous file that the table does not describe; both must be there, byte for byte, afterwards.
  printf 'previous model, not what the table describes\n' > "$dir/got/$n2"
  printf 'previous model of another size\n' > "$dir/got/$n3"
  cp "$dir/got/$n2" "$dir/previous/$n2"
  cp "$dir/got/$n3" "$dir/previous/$n3"
  seed_run_local "$dir/table.tsv" "$base" "$dir/got" "$dir/curl3.log" | tee "$dir/seed3.out"
  seed_run_local "$dir/table3.tsv" "$base" "$dir/got" "$dir/curl4.log" | tee "$dir/seed4.out"
  grep -qx "U1 DIFFERS $n2" "$dir/seed3.out" || { selftest_fail "no line 'U1 DIFFERS $n2' for the differing download"; return 1; }
  grep -qx "U1 DIFFERS $n3" "$dir/seed4.out" || { selftest_fail "no line 'U1 DIFFERS $n3' for the download of the wrong size"; return 1; }
  for name in "$n2" "$n3"; do
    cmp -s "$dir/previous/$name" "$dir/got/$name" || { selftest_fail "the previous file $name was lost or changed by a failed download"; return 1; }
  done
  [ -z "$(ls "$dir/got" | grep '\.partial$')" ] || { selftest_fail "a .partial is left in $dir/got"; return 1; }
  cmp -s "$dir/served/$n1" "$dir/got/$n1" || { selftest_fail "the good cached file $n1 changed"; return 1; }
  echo "SEED SELFTEST kept: the previous files of $n2 and $n3 are unchanged after a differing and a wrong-size download, no .partial is left"
  ml_stop seedfixture
  echo "SEED SELFTEST OK"
  return 0
}

# The selftest's fixture is local: the same seed_run, with curl told to bypass any proxy.
seed_run_local() { NO_PROXY='*' no_proxy='*' seed_run "$@"; }

main() {
  case "$1" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    rate) [ $# = 2 ] || { usage; return 2; }; cmd_rate "$2" ;;
    offline) cmd_offline ;;
    online) cmd_online ;;
    requests) cmd_requests ;;
    seed)
      case "$2" in
        --real) [ $# = 2 ] || { usage; return 2; }; cmd_seed_real ;;
        --selftest) [ $# = 2 ] || { usage; return 2; }; cmd_seed_selftest ;;
        *) usage; return 2 ;;
      esac ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-mirror "$@")" main "$@"
exit $?

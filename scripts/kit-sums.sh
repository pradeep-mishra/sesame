#!/bin/bash
# kit-sums.sh snapshot <name> <dir...> | compare <name> | ping
#
# Size, modified time and SHA-256 of every file under a folder, and the comparison (verify.md, Kit
# scripts; the S8(a) read-only check and the kit self-run). A folder name is read under the fixture
# root $KIT_ROOT/fixtures (so "golden" or "tree"), an absolute path as given; the path printed for a
# file is the folder name as given, a slash, and the file's path inside it.
#   snapshot <name> <dir...>  saves the figures of every file under each folder (exit 4 when there is
#                             no file at all: a snapshot of nothing proves nothing)
#   compare <name>            takes the figures again for the same folders and prints one line for each
#                             difference: CHANGED <path> <what changed: checksum size mtime>,
#                             ADDED <path>, REMOVED <path>; exit 1 when there is any, else prints
#                             UNCHANGED <n> files and exits 0 (exit 4 when there is no such snapshot)
#   ping                      shows by a throwaway folder that the comparison goes red on a flipped
#                             byte with size and time kept, on a size change, on an added and on a
#                             removed file, and goes green again when the files are put back
# Exit codes: 0 done; 1 differences or an error; 2 usage; 4 not valid (a precondition did not hold).
. "$(dirname "$0")/kit-lib/common.sh"

FIX="$KIT_ROOT/fixtures"
SUMS="$KIT_ROOT/run/sums"

usage() {
  cat >&2 <<'EOF'
usage: kit-sums.sh snapshot <name> <dir...>
       kit-sums.sh compare <name>
       kit-sums.sh ping
EOF
}

valid_name() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

resolve_dir() {
  case "$1" in
    ""|*..*) return 1 ;;
    /*) printf '%s\n' "${1%/}" ;;
    *) printf '%s\n' "$FIX/${1%/}" ;;
  esac
}

# snap_lines <label> <absolute dir> : "<label>/<path inside>", size, modified time (epoch seconds), SHA-256.
snap_lines() {
  local label="$1" dir="$2" t rc
  t="$(mktemp -d "$KIT_TMP/kit-sums.XXXXXX")" || return 1
  find "$dir" -type f -exec stat -f '%N%t%z%t%m' {} + > "$t/stat" || { rm -rf "$t"; return 1; }
  find "$dir" -type f -exec shasum -a 256 {} + 2> "$t/err" | sed 's/^\([0-9a-f]\{64\}\)  /\1\t/' > "$t/sha"
  rc=${PIPESTATUS[0]}
  if [ "$rc" != 0 ] || [ -s "$t/err" ]; then
    echo "could not read every file under $dir:" >&2
    head -3 "$t/err" >&2
    rm -rf "$t"
    return 1
  fi
  awk -F'\t' -v OFS='\t' -v d="$dir/" -v l="$label" '
    NR == FNR { sz[$1] = $2; mt[$1] = $3; next }
    { p = $2; rel = p; if (index(p, d) == 1) rel = substr(p, length(d) + 1); print l "/" rel, sz[p], mt[p], $1 }
  ' "$t/stat" "$t/sha" | LC_ALL=C sort -t$'\t' -k1,1
  rm -rf "$t"
  return 0
}

# take_snapshot <file> <label=dir...> : writes the figures of every folder to the file.
take_snapshot() {
  local out="$1" pair label dir
  shift
  : > "$out"
  for pair in "$@"; do
    label="${pair%%$'\t'*}"
    dir="${pair#*$'\t'}"
    printf '#dir\t%s\t%s\n' "$label" "$dir" >> "$out"
    snap_lines "$label" "$dir" >> "$out" || return 1
  done
  return 0
}

count_files() { awk '!/^#/ && NF > 0 { n++ } END { print n + 0 }' "$1"; }

cmd_snapshot() {
  local name="$1" arg dir label pairs=() total
  shift
  valid_name "$name" && [ $# -ge 1 ] || { usage; return 2; }
  for arg in "$@"; do
    dir="$(resolve_dir "$arg")" || { usage; return 2; }
    if [ ! -d "$dir" ]; then
      echo "no such folder: $arg ($dir)"
      return 1
    fi
    pairs+=("${arg%/}"$'\t'"$dir")
  done
  mkdir -p "$SUMS" || return 1
  take_snapshot "$SUMS/$name.new" "${pairs[@]}" || { rm -f "$SUMS/$name.new"; return 1; }
  total="$(count_files "$SUMS/$name.new")"
  if [ "$total" = 0 ]; then
    rm -f "$SUMS/$name.new"
    echo "not valid: no files under $*, a snapshot of nothing proves nothing"
    return 4
  fi
  mv -f "$SUMS/$name.new" "$SUMS/$name.tsv"
  echo "SNAPSHOT $name: $total files under $*"
  return 0
}

cmd_compare() {
  local name="$1" file pairs=() tag label dir n diffs k
  valid_name "$name" && [ $# = 1 ] || { usage; return 2; }
  file="$SUMS/$name.tsv"
  if [ ! -f "$file" ]; then
    echo "not valid: no snapshot named $name (kit-sums.sh snapshot $name <dir...> first)"
    return 4
  fi
  while IFS=$'\t' read -r tag label dir; do
    [ "$tag" = "#dir" ] && pairs+=("$label"$'\t'"$dir")
  done < "$file"
  if [ ${#pairs[@]} = 0 ]; then
    echo "snapshot $name is damaged: it names no folder"
    return 1
  fi
  take_snapshot "$SUMS/$name.now" "${pairs[@]}" || { rm -f "$SUMS/$name.now"; return 1; }
  n="$(count_files "$file")"
  diffs="$(awk -F'\t' '
    /^#/ { next }
    NR == FNR { osz[$1] = $2; omt[$1] = $3; osh[$1] = $4; seen[$1] = 1; next }
    { nsz[$1] = $2; nmt[$1] = $3; nsh[$1] = $4; nseen[$1] = 1 }
    END {
      for (p in seen) {
        if (!(p in nseen)) { print "REMOVED " p; continue }
        c = ""
        if (osh[p] != nsh[p]) c = c " checksum"
        if (osz[p] != nsz[p]) c = c " size"
        if (omt[p] != nmt[p]) c = c " mtime"
        if (c != "") print "CHANGED " p c
      }
      for (p in nseen) if (!(p in seen)) print "ADDED " p
    }' "$file" "$SUMS/$name.now" | LC_ALL=C sort)"
  rm -f "$SUMS/$name.now"
  if [ -z "$diffs" ]; then
    echo "UNCHANGED $n files"
    return 0
  fi
  printf '%s\n' "$diffs"
  k="$(printf '%s\n' "$diffs" | wc -l | tr -d ' ')"
  echo "DIFFERENT $k of $n files"
  return 1
}

# ---- ping ------------------------------------------------------------------------------------

cmd_ping() {
  local d="$KIT_ROOT/run/sums-ping" fail=0 out rc f
  local t0="202601151030.00"
  rm -rf "$d"
  mkdir -p "$d/a/sub" "$d/empty" || return 1
  printf 'one\n' > "$d/a/one.txt"
  printf 'two two\n' > "$d/a/sub/two.txt"
  printf 'three three three\n' > "$d/a/three.txt"
  for f in "$d/a/one.txt" "$d/a/sub/two.txt" "$d/a/three.txt"; do TZ=UTC touch -t "$t0" "$f"; done
  touch -r "$d/a/one.txt" "$d/ref"

  expect_rc() { # <what> <wanted rc> <wanted line or ""> : checks the last compare
    if [ "$rc" = "$2" ] && { [ -z "$3" ] || printf '%s\n' "$out" | awk -v w="$3" '$0 == w { f = 1 } END { exit !f }'; }; then
      echo "OK sums: $1 (exit $rc${3:+, line '$3'})"
    else
      echo "FAILED sums: $1: wanted exit $2${3:+ and the line '$3'}, got exit $rc:"
      printf '%s\n' "$out" | sed 's/^/    /'
      fail=1
    fi
  }

  out="$(cmd_snapshot ping-sums "$d/a")"; rc=$?
  expect_rc "snapshot of 3 files" 0 "SNAPSHOT ping-sums: 3 files under $d/a"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "untouched files compare equal" 0 "UNCHANGED 3 files"

  printf 'X' | dd of="$d/a/one.txt" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null
  touch -r "$d/ref" "$d/a/one.txt"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "a flipped byte with size and time kept goes red" 1 "CHANGED $d/a/one.txt checksum"
  printf 'one\n' > "$d/a/one.txt"
  touch -r "$d/ref" "$d/a/one.txt"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "the file put back compares equal" 0 "UNCHANGED 3 files"

  printf 'more' >> "$d/a/sub/two.txt"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "a longer file goes red" 1 ""
  case "$out" in *"CHANGED $d/a/sub/two.txt checksum size"*) ;; *) echo "FAILED sums: the longer file's line does not say checksum and size"; fail=1 ;; esac
  printf 'two two\n' > "$d/a/sub/two.txt"
  TZ=UTC touch -t "$t0" "$d/a/sub/two.txt"

  printf 'new\n' > "$d/a/new.txt"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "an added file goes red" 1 "ADDED $d/a/new.txt"
  rm -f "$d/a/new.txt" "$d/a/three.txt"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "a removed file goes red" 1 "REMOVED $d/a/three.txt"
  printf 'three three three\n' > "$d/a/three.txt"
  TZ=UTC touch -t "$t0" "$d/a/three.txt"
  out="$(cmd_compare ping-sums)"; rc=$?
  expect_rc "everything put back compares equal" 0 "UNCHANGED 3 files"

  out="$(cmd_snapshot ping-empty "$d/empty")"; rc=$?
  expect_rc "a snapshot of an empty folder is not valid" 4 ""
  out="$(cmd_compare no-such-snapshot)"; rc=$?
  expect_rc "a comparison with no snapshot is not valid" 4 ""

  rm -rf "$d" "$SUMS/ping-sums.tsv" "$SUMS/ping-empty.tsv"
  if [ $fail = 0 ]; then
    echo "SUMS PING OK"
    return 0
  fi
  echo "SUMS PING FAILED"
  return 1
}

main() {
  case "$1" in
    snapshot) shift; cmd_snapshot "$@" ;;
    compare) shift; cmd_compare "$@" ;;
    ping) [ $# = 1 ] || { usage; return 2; }; cmd_ping ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-sums "$@")" main "$@"
exit $?

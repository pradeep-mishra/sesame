#!/bin/bash
# kit-index.sh <mode>: read-only facts from index.sqlite and settings.json (verify.md, Kit scripts).
#
# The index is read with `sqlite3 -readonly -safe` and settings.json with plutil; nothing is ever
# written to either. The index is read only for facts the spec states about the index (what is in
# it, "could not read", size, integrity), never to decide what a search should show. Three counts are
# named and never mixed up: files (rows of the files table), passages (rows of the passages table) and
# rows (files plus passages).
#   ping                     an in-memory FTS5 table can be made (U3) and the index file opens read-only
#   status                   files per kind and status, the walk time; "no index" when there is no file
#   rows                     three lines: "files <n>", "passages <m>", "rows <n+m>"
#   has <path>               exit 0 when a files row holds the path, else 1
#   under <folder>           the files rows under a folder, then "<n> files under <folder>"
#   reasons                  every could_not_read row with its reason
#   integrity                PRAGMA integrity_check: "ok", else the lines it gave (exit 1)
#   schema                   every table with its columns, the fts definition, meta, the journal mode
#   size [<folder>]          bytes of index.sqlite plus its -wal file; with a folder the internal
#                            consistency reading only: 1,536 bytes times the vectors plus the keyword
#                            text bytes under it
#   walk-done                "walk_done_at <value>" (exit 0), or "walk not done" (exit 1)
#   meta <name>              the value of one fact of the meta table (either shape), exit 1 when it is not there
#   wait <started|walked|done|paused|resumed|stable|idle|rising> <seconds>
#                            exit 0 when the mode is reached; paused, resumed and rising exit 4 (not
#                            valid: rerun) when it is not reached within the seconds; started, walked and
#                            done exit 1; stable takes the quiet seconds and ends 4 after 3600 s of change;
#                            idle takes the quiet seconds too and is reached when the counts have not changed
#                            for more than that long and no file is pending or partial, or, with work left,
#                            when they have not changed for more than KIT_IDLE_LONG_QUIET_S (90) seconds
#   snapshot <name> [--files-only] | diff <a> <b>
#   estimate-check <estimate-seconds> <start-epoch>
#                            prints PASS (exit 0) when the estimate is within 30 percent of the real time
#                            (start to the last write to the index), else FAIL (exit 1)
#   settings                 settings.json as plutil prints it
# Time in `wait` is a running total, immune to sleep: a look that took more than 5 s longer than the half-second pause adds 1 s.
# Test-only: when KIT_TEST_CLOCK_JUMP names a file that exists, `wait` reads the whole number of seconds in it, adds them to its
# clock as a jump (a sleeping Mac), and removes the file; unset, nothing reads it.
# A <path> or <folder> that is not absolute is read under $KIT_ROOT/fixtures. The index may name a
# path through /private (the physical form of a /var path); both forms are matched.
# Exit codes: 0 done; 1 a check failed or the read failed; 2 usage; 3 a person-step is missing
# (NEEDS A PERSON: ...); 4 not valid (a precondition did not hold: rerun, never a pass).
. "$(dirname "$0")/kit-lib/common.sh"

SESAME_DIR="$KIT_ROOT/home/Library/Application Support/Sesame"
DB="$SESAME_DIR/index.sqlite"
SETTINGS="$SESAME_DIR/settings.json"
SNAPS="$KIT_ROOT/run/index-snaps"
TAB=$'\t'

usage() {
  cat >&2 <<'EOF'
usage: kit-index.sh ping | status | rows | reasons | integrity | schema | walk-done | settings
       kit-index.sh has <path>
       kit-index.sh under <folder>
       kit-index.sh meta <name>
       kit-index.sh size [<folder>]
       kit-index.sh wait <started|walked|done|paused|resumed|stable|idle|rising> <seconds>
       kit-index.sh snapshot <name> [--files-only]
       kit-index.sh diff <a> <b>
       kit-index.sh estimate-check <estimate-seconds> <start-epoch>
EOF
}

# ---- reading ---------------------------------------------------------------------------------

have_index() { [ -f "$DB" ]; }

SQL_OUT=""
SQL_ERR=""
# sql <statement>: read-only, tab separated. Status 0 and SQL_OUT, or 1 and SQL_ERR.
sql() {
  local errf rc
  errf="$(mktemp "$KIT_TMP/kit-index-err.XXXXXX")" || return 1
  SQL_OUT="$(sqlite3 -readonly -safe -separator "$TAB" -cmd '.timeout 5000' "$DB" "$1" 2>"$errf")"
  rc=$?
  SQL_ERR="$(cat "$errf")"
  rm -f "$errf"
  return "$rc"
}

need_sqlite() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "NEEDS A PERSON: sqlite3 is missing: it comes with macOS (/usr/bin/sqlite3); install the Command Line Tools"
    return 3
  fi
  return 0
}

has_table() { # has_table <name>: status 0 when the index holds the table
  sql "select count(*) from sqlite_master where name='$1';" || return 2
  [ "$SQL_OUT" = 1 ]
}

# counts: sets N_FILES, N_PASSAGES, N_OPEN (pending or partial files) and N_DONE. A missing index or
# a table that is not made yet counts as zero. Status 1 when the index cannot be read.
N_FILES=0; N_PASSAGES=0; N_OPEN=0; N_DONE=0
counts() {
  N_FILES=0; N_PASSAGES=0; N_OPEN=0; N_DONE=0
  have_index || return 0
  local f p
  has_table files; f=$?
  [ "$f" = 2 ] && return 1
  has_table passages; p=$?
  [ "$p" = 2 ] && return 1
  if [ "$f" = 0 ]; then
    sql "select count(*), coalesce(sum(status in ('pending','partial')),0), coalesce(sum(status='done'),0) from files;" || return 1
    N_FILES="${SQL_OUT%%$TAB*}"
    N_OPEN="${SQL_OUT#*$TAB}"; N_DONE="${N_OPEN#*$TAB}"; N_OPEN="${N_OPEN%%$TAB*}"
  fi
  if [ "$p" = 0 ]; then
    sql "select count(*) from passages;" || return 1
    N_PASSAGES="$SQL_OUT"
  fi
  return 0
}

fail_read() { echo "could not read the index: ${SQL_ERR:-no answer} ($DB)"; return 1; }

# cmd_meta <name> : prints the value of a meta fact; exit 1 when there is none (no index, no table or no such fact).
cmd_meta() {
  local v
  [ $# = 1 ] || { usage; return 2; }
  v="$(meta_get "$1")" || { fail_read; return 1; }
  [ -n "$v" ] || { echo "no meta fact $1 in $DB"; return 1; }
  printf '%s\n' "$v"
}

# meta_get <name>: the value of a meta fact, "" when absent. The shape of the meta table is not
# fixed by the design (one row of named columns, or key and value rows), so both are read.
meta_get() {
  local k v
  have_index || return 0
  has_table meta
  case $? in 1) return 0 ;; 2) return 1 ;; esac
  sql "select count(*) from pragma_table_info('meta') where name='$1';" || return 1
  if [ "$SQL_OUT" = 1 ]; then
    sql "select \"$1\" from meta limit 1;" || return 1
  else
    sql "select name from pragma_table_info('meta') order by cid limit 2;" || return 1
    k="${SQL_OUT%%$'\n'*}"; v="${SQL_OUT#*$'\n'}"
    [ -n "$k" ] && [ -n "$v" ] && [ "$k" != "$v" ] || return 0
    sql "select \"$v\" from meta where \"$k\"='$1' limit 1;" || return 1
  fi
  printf '%s' "$SQL_OUT"
  return 0
}

has_index_table() { have_index && has_table "$1"; }

# abs_path <path or folder>: absolute, under the fixture root when not absolute.
abs_path() {
  case "$1" in
    /*) printf '%s\n' "${1%/}" ;;
    *) printf '%s\n' "$KIT_ROOT/fixtures/${1%/}" ;;
  esac
}

# physical_path <absolute path>: the same path with symbolic links resolved, as far as it exists.
physical_path() {
  local d b
  if [ -d "$1" ]; then (cd "$1" && pwd -P); return; fi
  d="$(dirname "$1")"; b="$(basename "$1")"
  if [ -d "$d" ]; then printf '%s/%s\n' "$(cd "$d" && pwd -P)" "$b"; else printf '%s\n' "$1"; fi
}

sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }
glob_escape() { printf '%s' "$1" | sed -e 's/\[/[[]/g' -e 's/\*/[*]/g' -e 's/?/[?]/g'; }

# path_in <absolute path>: an SQL list of the path's forms ('a','b').
path_in() {
  local a p
  a="$1"; p="$(physical_path "$a")"
  if [ "$a" = "$p" ]; then printf "'%s'" "$(sql_quote "$a")"; else printf "'%s','%s'" "$(sql_quote "$a")" "$(sql_quote "$p")"; fi
}

# under_pred <column> <absolute folder>: an SQL test that the column's path is under the folder.
under_pred() {
  local a p
  a="$2"; p="$(physical_path "$a")"
  if [ "$a" = "$p" ]; then
    printf "%s glob '%s/*'" "$1" "$(sql_quote "$(glob_escape "$a")")"
  else
    printf "(%s glob '%s/*' or %s glob '%s/*')" "$1" "$(sql_quote "$(glob_escape "$a")")" "$1" "$(sql_quote "$(glob_escape "$p")")"
  fi
}

# ---- ping, status, rows ----------------------------------------------------------------------

cmd_ping() {
  local out rc ver n
  need_sqlite || return 3
  ver="$(sqlite3 -version | awk '{ print $1 }')"
  # U3: an FTS5 table with the tokenizer of the design can be made in memory and matched (porter
  # stemming: "beaches" finds "beach").
  out="$(sqlite3 :memory: "create virtual table t using fts5(name, body, tokenize='porter unicode61 remove_diacritics 2'); insert into t(rowid, name, body) values (1, 'beach-dog.jpg', 'a dog on the beach'); select count(*) from t where t match 'beaches';" 2>&1)"
  rc=$?
  if [ "$rc" != 0 ] && printf '%s' "$out" | awk '/no such module: fts5/ { f = 1 } END { exit !f }'; then
    echo "NEEDS A PERSON: sqlite3 with FTS5 is missing (sqlite3 $ver): the first build step makes an FTS5 table and a Mac where that fails goes to the person first"
    return 3
  fi
  if [ "$rc" != 0 ]; then
    echo "FAILED: the in-memory FTS5 table could not be made (sqlite3 $ver): $out"
    return 1
  fi
  if [ "$out" != 1 ]; then
    echo "FAILED: the in-memory FTS5 table was made (sqlite3 $ver) but a MATCH for 'beaches' found $out rows, expected 1"
    return 1
  fi
  echo "OK an in-memory FTS5 table was made (sqlite3 $ver, tokenizer porter unicode61 remove_diacritics 2) and a MATCH found its row: FTS5 is present (U3)"
  if have_index; then
    if sql "select count(*) from sqlite_master;"; then
      n="$SQL_OUT"
      echo "OK the index file opens read-only ($DB, $n schema entries)"
    else
      echo "FAILED: the index file does not open read-only: $SQL_ERR ($DB)"
      return 1
    fi
  else
    echo "no index file yet ($DB): nothing to open read-only, not a failure"
  fi
  return 0
}

cmd_status() {
  [ $# = 0 ] || { usage; return 2; }
  need_sqlite || return 3
  if ! have_index; then
    echo "no index: $DB does not exist"
    return 0
  fi
  echo "index: $DB ($(stat -f %z "$DB") bytes)"
  if ! has_index_table files; then
    echo "the index file has no files table yet"
    return 0
  fi
  sql "select kind, status, count(*) from files group by kind, status order by kind, status;" || { fail_read; return 1; }
  if [ -n "$SQL_OUT" ]; then
    printf '%s\n' "$SQL_OUT" | tr '\t' ' '
  else
    echo "no files in the index"
  fi
  counts || { fail_read; return 1; }
  echo "files $N_FILES"
  local w
  w="$(meta_get walk_done_at)" || { fail_read; return 1; }
  echo "walk_done_at ${w:-none}"
  return 0
}

cmd_rows() {
  [ $# = 0 ] || { usage; return 2; }
  need_sqlite || return 3
  have_index || echo "no index: $DB does not exist"
  counts || { fail_read; return 1; }
  echo "files $N_FILES"
  echo "passages $N_PASSAGES"
  echo "rows $((N_FILES + N_PASSAGES))"
}

# ---- one file, one folder --------------------------------------------------------------------

cmd_has() {
  [ $# = 1 ] || { usage; return 2; }
  need_sqlite || return 3
  local p
  p="$(abs_path "$1")"
  if ! have_index || ! has_index_table files; then echo "not in the index: $p (there is no index yet)"; return 1; fi
  sql "select count(*) from files where path in ($(path_in "$p"));" || { fail_read; return 1; }
  if [ "$SQL_OUT" -gt 0 ] 2>/dev/null; then
    echo "in the index: $p"
    return 0
  fi
  echo "not in the index: $p"
  return 1
}

cmd_under() {
  [ $# = 1 ] || { usage; return 2; }
  need_sqlite || return 3
  local d
  d="$(abs_path "$1")"
  if ! have_index || ! has_index_table files; then echo "0 files under $d (there is no index yet)"; return 0; fi
  sql "select path, kind, status from files where $(under_pred path "$d") order by path;" || { fail_read; return 1; }
  [ -n "$SQL_OUT" ] && printf '%s\n' "$SQL_OUT"
  sql "select count(*) from files where $(under_pred path "$d");" || { fail_read; return 1; }
  echo "$SQL_OUT files under $d"
}

cmd_reasons() {
  [ $# = 0 ] || { usage; return 2; }
  need_sqlite || return 3
  if ! have_index || ! has_index_table files; then echo "could_not_read 0 (there is no index yet)"; return 0; fi
  sql "select path, coalesce(reason, '(no reason)') from files where status='could_not_read' order by path;" || { fail_read; return 1; }
  [ -n "$SQL_OUT" ] && printf '%s\n' "$SQL_OUT"
  sql "select count(*) from files where status='could_not_read';" || { fail_read; return 1; }
  echo "could_not_read $SQL_OUT"
}

# ---- integrity, schema, size, walk, settings -------------------------------------------------

cmd_integrity() {
  [ $# = 0 ] || { usage; return 2; }
  need_sqlite || return 3
  if ! have_index; then echo "no index: $DB does not exist"; return 1; fi
  sql "pragma integrity_check;" || { fail_read; return 1; }
  if [ "$SQL_OUT" = ok ]; then echo ok; return 0; fi
  printf '%s\n' "$SQL_OUT"
  return 1
}

cmd_schema() {
  [ $# = 0 ] || { usage; return 2; }
  need_sqlite || return 3
  if ! have_index; then echo "no index: $DB does not exist"; return 1; fi
  sql "select m.name, group_concat(p.name, ' ') from sqlite_master m, pragma_table_info(m.name) p where m.type='table' group by m.name order by m.name;" || { fail_read; return 1; }
  printf '%s\n' "$SQL_OUT" | awk -F'\t' '{ print "table " $1 ": " $2 }'
  sql "select sql from sqlite_master where name='fts';" || { fail_read; return 1; }
  [ -n "$SQL_OUT" ] && echo "fts definition: $SQL_OUT"
  sql "pragma journal_mode;" || { fail_read; return 1; }
  echo "journal_mode $SQL_OUT"
  if has_index_table meta; then
    sql "select * from meta;" || { fail_read; return 1; }
    printf '%s\n' "$SQL_OUT" | sed 's/^/meta row: /'
  fi
}

cmd_size() {
  [ $# -le 1 ] || { usage; return 2; }
  local total=0 f b d v k pred
  if [ $# = 0 ]; then
    if ! have_index; then echo "no index: $DB does not exist"; echo "size 0"; return 0; fi
    for f in "$DB" "$DB-wal"; do
      [ -f "$f" ] || continue
      b="$(stat -f %z "$f")"
      echo "$f $b bytes"
      total=$((total + b))
    done
    echo "size $total"
    return 0
  fi
  need_sqlite || return 3
  d="$(abs_path "$1")"
  if ! have_index || ! has_index_table passages; then echo "size under $d: 0 bytes (there is no index yet)"; return 0; fi
  pred="$(under_pred f.path "$d")"
  sql "select count(*) from passages p join files f on f.id = p.file_id where p.vec is not null and $pred;" || { fail_read; return 1; }
  v="$SQL_OUT"
  sql "select coalesce(sum(coalesce(length(cast(x.name as blob)),0) + coalesce(length(cast(x.body as blob)),0)),0) from fts x where x.rowid in (select p.id from passages p join files f on f.id = p.file_id where $pred);" || { fail_read; return 1; }
  k="$SQL_OUT"
  echo "size under $d: $((v * 1536 + k)) bytes ($v vectors x 1536 + $k keyword text bytes)"
}

cmd_walk_done() {
  [ $# = 0 ] || { usage; return 2; }
  need_sqlite || return 3
  local w
  if ! have_index; then echo "walk not done: there is no index file yet"; return 1; fi
  w="$(meta_get walk_done_at)" || { fail_read; return 1; }
  if [ -z "$w" ]; then echo "walk not done: meta.walk_done_at is absent"; return 1; fi
  echo "walk_done_at $w"
}

cmd_settings() {
  [ $# = 0 ] || { usage; return 2; }
  if [ ! -f "$SETTINGS" ]; then echo "no settings.json: $SETTINGS does not exist"; return 0; fi
  local out
  # plutil -p reads JSON and fails on a file that is not valid (plutil -lint reads property lists only).
  if ! out="$(plutil -p "$SETTINGS" 2>&1)"; then
    echo "settings.json is not valid JSON: $SETTINGS"
    printf '%s\n' "$out"
    return 1
  fi
  echo "settings.json: $SETTINGS"
  printf '%s\n' "$out"
}

settings_get() { # settings_get <key>: the value of a top-level key, "" when absent or no file
  [ -f "$SETTINGS" ] || return 0
  plutil -extract "$1" raw -o - "$SETTINGS" 2>/dev/null
  return 0
}

# ---- wait ------------------------------------------------------------------------------------

sig() { printf '%s %s %s' "$N_FILES" "$N_PASSAGES" "$N_DONE"; }
state_line() { printf 'files %s, passages %s, pending or partial %s' "$N_FILES" "$N_PASSAGES" "$N_OPEN"; }

CLOCK_OFFSET=0
clock_now() {
  local n
  if [ -n "${KIT_TEST_CLOCK_JUMP:-}" ] && [ -f "$KIT_TEST_CLOCK_JUMP" ]; then
    n="$(cat "$KIT_TEST_CLOCK_JUMP" 2>/dev/null)"
    rm -f "$KIT_TEST_CLOCK_JUMP"
    case "$n" in ""|*[!0-9]*) n=0 ;; esac
    CLOCK_OFFSET=$((CLOCK_OFFSET + n))
  fi
  CLK=$((SECONDS + CLOCK_OFFSET))
}

# The wait counts time as a running total, never as a difference of the clock: a look that took more than 5 s longer than its
# half-second pause (the Mac slept, or the process stalled) adds 1 s, so a sleep is never counted as quiet.
cmd_wait() {
  [ $# = 2 ] || { usage; return 2; }
  local mode="$1" arg="$2" base_sig base_rows last now=0 walked quiet=0 long tick step
  case "$mode" in started|walked|done|paused|resumed|stable|idle|rising) ;; *) usage; return 2 ;; esac
  case "$arg" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ "$arg" -gt 0 ] || { usage; return 2; }
  long="$KIT_IDLE_LONG_QUIET_S"
  case "$long" in ""|*[!0-9]*) long=90 ;; esac
  [ "$long" -ge "$arg" ] || long="$arg"
  need_sqlite || return 3
  counts || { fail_read; return 1; }
  base_sig="$(sig)"; base_rows=$((N_FILES + N_PASSAGES))
  last="$base_sig"; tick=$SECONDS
  while :; do
    clock_now
    step=$((CLK - tick)); tick=$CLK
    [ "$step" -gt 5 ] && step=1
    now=$((now + step)); quiet=$((quiet + step))
    # A read that fails (the helper holds the file for a moment) skips this look, never ends the wait.
    if counts; then
      case "$mode" in
        started)
          if [ "$(settings_get startPressed)" = true ]; then echo "started after ${now} s (settings.json startPressed true)"; return 0; fi ;;
        walked)
          walked="$(meta_get walk_done_at)"
          if [ -n "$walked" ]; then echo "walked after ${now} s (walk_done_at $walked; $(state_line))"; return 0; fi ;;
        done)
          walked="$(meta_get walk_done_at)"
          if [ -n "$walked" ] && [ "$N_OPEN" = 0 ]; then echo "done after ${now} s ($(state_line))"; return 0; fi ;;
        rising)
          if [ $((N_FILES + N_PASSAGES)) -gt "$base_rows" ]; then
            echo "rising after ${now} s (rows from $base_rows to $((N_FILES + N_PASSAGES)))"; return 0
          fi ;;
        resumed)
          if [ "$(sig)" != "$base_sig" ]; then echo "resumed after ${now} s (the counts moved: $(state_line))"; return 0; fi ;;
        paused)
          if [ "$(sig)" != "$last" ]; then last="$(sig)"; quiet=0; fi
          if [ "$N_OPEN" -gt 0 ] && [ "$quiet" -ge 3 ]; then
            echo "paused after ${now} s (work is left and the counts have not moved for 3 s: $(state_line))"; return 0
          fi ;;
        stable)
          if [ "$(sig)" != "$last" ]; then last="$(sig)"; quiet=0; fi
          if [ "$quiet" -ge "$arg" ]; then echo "stable after ${now} s (the counts did not change for $arg s: $(state_line))"; return 0; fi ;;
        idle)
          if [ "$(sig)" != "$last" ]; then last="$(sig)"; quiet=0; fi
          if [ "$N_OPEN" = 0 ] && [ "$quiet" -gt "$arg" ]; then
            echo "idle after ${now} s (the counts did not change for $arg s and no work is left: $(state_line))"; return 0
          fi
          if [ "$quiet" -gt "$long" ]; then
            echo "idle after ${now} s (work is left but the counts did not change for $long s: $(state_line))"; return 0
          fi ;;
      esac
    fi
    if { [ "$mode" = stable ] || [ "$mode" = idle ]; } && [ "$now" -ge 3600 ]; then
      echo "not valid: the counts were still changing after 3600 s ($(state_line))"
      return 4
    fi
    if [ "$mode" != stable ] && [ "$mode" != idle ] && [ "$now" -ge "$arg" ]; then
      case "$mode" in
        rising)
          echo "not valid: the rows did not rise within $arg s (stuck at $base_rows; the golden photos may be done already, or Start was not pressed): rerun"
          return 4 ;;
        paused|resumed)
          echo "not valid: $mode was not reached within $arg s ($(state_line)): rerun, never a pass or a fail"
          return 4 ;;
      esac
      echo "timeout: $mode was not reached within $arg s ($(state_line))"
      return 1
    fi
    sleep 0.5
  done
}

# ---- snapshots -------------------------------------------------------------------------------

valid_name() {
  case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# dump_table <table> <label> <tool>: "<label> <rowid> <SHA-256 of the row>" for every row, vectors
# included. Every value goes through hex(), so a line is plain text whatever the row holds.
dump_table() {
  local t="$1" label="$2" tool="$3" cols
  if ! has_table "$t"; then echo "#absent $t"; return 0; fi
  sql "select group_concat('case when \"' || name || '\" is null then ''~'' else hex(\"' || name || '\") end', ' || char(9) || ') from pragma_table_info('$t');" || return 1
  cols="$SQL_OUT"
  [ -n "$cols" ] || { echo "#absent $t"; return 0; }
  sqlite3 -readonly -safe -separator "$TAB" -cmd '.timeout 5000' "$DB" "select rowid || char(9) || $cols from $t order by rowid;" | "$tool" "$label"
  [ "${PIPESTATUS[0]}" = 0 ]
}

cmd_snapshot() {
  [ $# -ge 1 ] || { usage; return 2; }
  local name="$1" files_only=0 tool tmp t n_files n_pass n_fts sums
  shift
  valid_name "$name" || { usage; return 2; }
  case "${1:-}" in "") ;; --files-only) files_only=1; [ $# = 1 ] || { usage; return 2; } ;; *) usage; return 2 ;; esac
  need_sqlite || return 3
  if ! have_index; then
    echo "not valid: there is no index to snapshot ($DB does not exist)"
    return 4
  fi
  mkdir -p "$SNAPS" || return 1
  tmp="$SNAPS/$name.new"
  if [ "$files_only" = 1 ]; then
    if ! has_table files; then rm -f "$tmp"; echo "not valid: the index has no files table"; return 4; fi
    {
      echo "#mode files-only"
      sql "select f.path || char(9) || f.status || char(9) || (select count(*) from passages p where p.file_id = f.id) from files f order by f.path;" || { fail_read; rm -f "$tmp"; return 1; }
      [ -n "$SQL_OUT" ] && printf '%s\n' "$SQL_OUT"
    } > "$tmp" || return 1
    n_files="$(awk '!/^#/ { n++ } END { print n + 0 }' "$tmp")"
    mv -f "$tmp" "$SNAPS/$name.tsv"
    echo "SNAPSHOT $name (files-only): $n_files files, each as path, status, passage count"
    return 0
  fi
  tool="$(kit_tool rowhash)" || { echo "the kit's Swift tool rowhash did not compile; see $KIT_ROOT/run/bin/rowhash.log"; return 1; }
  {
    echo "#mode full"
    for t in files passages fts; do
      dump_table "$t" "$t" "$tool" || { echo "#error $t"; }
    done
    if [ -f "$SETTINGS" ]; then
      sums="$(shasum -a 256 "$SETTINGS" | cut -d' ' -f1)"
      printf 'settings\t-\t%s\n' "$sums"
    else
      printf 'settings\t-\tabsent\n'
    fi
  } > "$tmp" || return 1
  if awk '/^#error/ { f = 1 } END { exit !f }' "$tmp"; then
    echo "could not read every table of the index: $SQL_ERR"
    rm -f "$tmp"
    return 1
  fi
  n_files="$(awk -F'\t' '$1 == "files" { n++ } END { print n + 0 }' "$tmp")"
  n_pass="$(awk -F'\t' '$1 == "passages" { n++ } END { print n + 0 }' "$tmp")"
  n_fts="$(awk -F'\t' '$1 == "fts" { n++ } END { print n + 0 }' "$tmp")"
  mv -f "$tmp" "$SNAPS/$name.tsv"
  echo "SNAPSHOT $name (full): $n_files files rows, $n_pass passages rows, $n_fts fts rows, settings.json $(awk -F'\t' '$1 == "settings" { print ($3 == "absent") ? "absent" : "hashed" }' "$SNAPS/$name.tsv")"
  return 0
}

snap_mode() { awk '/^#mode / { print $2; exit }' "$1"; }

cmd_diff() {
  [ $# = 2 ] || { usage; return 2; }
  local a="$SNAPS/$1.tsv" b="$SNAPS/$2.tsv" ma mb out k
  valid_name "$1" && valid_name "$2" || { usage; return 2; }
  for f in "$a" "$b"; do
    if [ ! -f "$f" ]; then echo "not valid: no snapshot named $(basename "$f" .tsv) (kit-index.sh snapshot <name> first)"; return 4; fi
  done
  ma="$(snap_mode "$a")"; mb="$(snap_mode "$b")"
  if [ "$ma" != "$mb" ]; then
    echo "not valid: $1 is a $ma snapshot and $2 is a $mb snapshot; a diff needs two of the same kind"
    return 4
  fi
  if [ "$ma" = files-only ]; then
    out="$(awk '
      /^#/ { next }
      NR == FNR { if (!/^#/) a[$0] = 1; next }
      { b[$0] = 1 }
      END {
        for (l in a) if (!(l in b)) print "- " l
        for (l in b) if (!(l in a)) print "+ " l
      }' "$a" "$b" | LC_ALL=C sort -k2)"
  else
    out="$(awk -F'\t' '
      /^#/ { next }
      NR == FNR { key = $1 "\t" $2; oa[key] = $3; next }
      { key = $1 "\t" $2; ob[key] = $3 }
      END {
        for (k in oa) {
          if (!(k in ob)) { split(k, p, "\t"); print "REMOVED " p[1] " " p[2]; continue }
          if (oa[k] != ob[k]) { split(k, p, "\t"); print "CHANGED " p[1] " " p[2] }
        }
        for (k in ob) if (!(k in oa)) { split(k, p, "\t"); print "ADDED " p[1] " " p[2] }
      }' "$a" "$b" | LC_ALL=C sort)"
  fi
  if [ -z "$out" ]; then
    echo "IDENTICAL ($ma snapshots $1 and $2)"
    return 0
  fi
  printf '%s\n' "$out"
  k="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  echo "DIFFERENT $k lines ($ma snapshots $1 and $2)"
  return 1
}

# ---- the S6 estimate -------------------------------------------------------------------------

cmd_estimate_check() {
  [ $# = 2 ] || { usage; return 2; }
  local est="$1" start="$2" end f m walked real
  case "$est" in ""|*[!0-9]*) usage; return 2 ;; esac
  case "$start" in ""|*[!0-9]*) usage; return 2 ;; esac
  need_sqlite || return 3
  counts || { fail_read; return 1; }
  walked="$(meta_get walk_done_at)"
  if ! have_index || [ -z "$walked" ] || [ "$N_OPEN" != 0 ]; then
    echo "not valid: indexing is not finished, so there is no real time to compare ($(state_line))"
    return 4
  fi
  end=0
  for f in "$DB" "$DB-wal"; do
    [ -f "$f" ] || continue
    m="$(stat -f %m "$f")"
    [ "$m" -gt "$end" ] && end="$m"
  done
  real=$((end - start))
  if [ "$real" -le 0 ] || [ "$est" -le 0 ]; then
    echo "not valid: the last write to the index ($end) is not after the start ($start), or the estimate is zero"
    return 4
  fi
  # The real time is Start pressed to the last write the index took; within 30 percent of the real time.
  awk -v e="$est" -v r="$real" 'BEGIN {
    d = (e > r) ? e - r : r - e
    pct = 100 * d / r
    verdict = (pct <= 30) ? "PASS" : "FAIL"
    printf "estimate %d s, real %d s (start to the last write to the index), difference %.1f percent of the real time (at most 30 passes): %s\n", e, r, pct, verdict
    exit (pct <= 30) ? 0 : 1
  }'
}

# ---- main ------------------------------------------------------------------------------------

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    ping) [ $# = 0 ] || { usage; return 2; }; cmd_ping ;;
    status) cmd_status "$@" ;;
    rows) cmd_rows "$@" ;;
    has) cmd_has "$@" ;;
    under) cmd_under "$@" ;;
    reasons) cmd_reasons "$@" ;;
    integrity) cmd_integrity "$@" ;;
    schema) cmd_schema "$@" ;;
    size) cmd_size "$@" ;;
    walk-done) cmd_walk_done "$@" ;;
    meta) cmd_meta "$@" ;;
    wait) cmd_wait "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    diff) cmd_diff "$@" ;;
    estimate-check) cmd_estimate_check "$@" ;;
    settings) cmd_settings "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-index "$@")" main "$@"
exit $?

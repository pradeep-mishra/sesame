#!/bin/bash
# The batches of the Accept stage (plan 6, t9): `kit-run.sh batches` prints them, `kit-run.sh batch <letter> [--unattended]` runs one.
# Sourced by kit-run.sh, never run. The table is scripts/kit-lib/batches.tsv, written by hand, tab separated:
#   batch <letter> <name> <launches: a number or many> <real app: yes|no>
#   run   <letter> <command>   a script of scripts/ and its arguments, run in order (@VERSION@ is the saved version, else `accept`)
#   say   <letter> <text>      a line for the person or the controller, printed, never run
# The ids of a batch are the ids of its run lines: `kit-run.sh <S> --ids a,b`, `kit-run.sh <S>` (every id of that scenario), `verify.sh` and
# `kit-run.sh all` (every id of checks.tsv). KIT_BATCH_BIN (a test seam) is the folder the run lines call their scripts from; unset, scripts/.
# Durations: the script's own clock. Every reset deletes run/, so a duration is also kept in $KIT_ROOT/batch-kept/, which no reset touches
# (the entry names run/batch-times.tsv; a reset in a later batch would otherwise wipe the earlier rows the listing reads).

BATCH_TSV="$KIT_LIB/batches.tsv"

batch_hms() { printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

# batch_exists <letter> : status 0 when the table has that batch.
batch_exists() { awk -F'\t' -v l="$1" '$1 == "batch" && $2 == l { f = 1 } END { exit !f }' "$BATCH_TSV"; }

# batch_line_ids <command> : the ids one run line covers, one a line.
batch_line_ids() {
  local scen
  case "$1" in
    "kit-run.sh all"*|"verify.sh"*) awk -F'\t' '$1 ~ /^S([1-9]|10)\./ { print $1 }' "$KIT_LIB/checks.tsv" ;;
    "kit-run.sh S"[1-9]" --ids "*|"kit-run.sh S10 --ids "*) set -- $1; printf '%s\n' "$4" | tr ',' '\n' ;;
    "kit-run.sh S"[1-9]|"kit-run.sh S10")
      scen="${1##* }"
      awk -F'\t' -v s="$scen" 'index($1, s ".") == 1 { print $1 }' "$KIT_LIB/checks.tsv" ;;
  esac
}

# batch_ids <letter> : the ids of the batch, in the order its lines run them (a line's ids in checks.tsv order, as kit-run.sh runs them).
batch_ids() {
  local kind letter text list
  while IFS=$'\t' read -r kind letter text; do
    [ "$kind" = run ] && [ "$letter" = "$1" ] || continue
    list="$(batch_line_ids "$text")"
    [ -n "$list" ] || continue
    awk -F'\t' 'NR == FNR { want[$1] = 1; next } ($1 in want) { print $1 }' <(printf '%s\n' "$list") "$KIT_LIB/checks.tsv"
  done < "$BATCH_TSV"
}

batch_last_took() {
  local f row
  for f in "$KIT_ROOT/batch-kept/batch-times.tsv" "$KIT_ROOT/run/batch-times.tsv"; do
    [ -f "$f" ] || continue
    row="$(awk -F'\t' -v l="$1" '$1 == l { t = $2 } END { if (t != "") print t }' "$f")"
    [ -z "$row" ] || { echo "$row"; return 0; }
  done
  return 1
}

# batch_header <letter> : the line that says what the batch is and how many times it launches the app, printed before anything runs.
batch_header() {
  local name launches ids
  name="$(awk -F'\t' -v l="$1" '$1 == "batch" && $2 == l { print $3 }' "$BATCH_TSV")"
  launches="$(awk -F'\t' -v l="$1" '$1 == "batch" && $2 == l { print $4 }' "$BATCH_TSV")"
  ids="$(batch_ids "$1" | paste -sd, -)"
  echo "BATCH $1 $name: launches $launches: ${ids:-none}"
}

# batches_list : every batch in the order of the table, its lines, how to run it, and how long it last took. Starts nothing.
batches_list() {
  local l real kind letter text t
  while IFS=$'\t' read -r kind l _ _ real; do
    [ "$kind" = batch ] || continue
    batch_header "$l"
    while IFS=$'\t' read -r kind letter text; do
      [ "$letter" = "$l" ] || continue
      case "$kind" in run) echo "  run: $text" ;; say) echo "  say: $text" ;; esac
    done < "$BATCH_TSV"
    if [ "$real" = yes ]; then
      echo "  run it as: caffeinate -dimsu env KIT_TYPE_DELAY_MS=80 KIT_PICK_WAIT=30 scripts/kit-run.sh batch $l [--unattended]"
    fi
    if t="$(batch_last_took "$l")"; then echo "  last took $t"; else echo "  not run yet"; fi
  done < "$BATCH_TSV"
}

# batch_stopped_id <command> <output file> : the id a stop is about: the first id kit-run.sh did not print, else the first id of the line,
# else the command.
batch_stopped_id() {
  local id
  id="$(sed -n 's/^NOT PRINTED (rerun): *\([^ ]*\).*/\1/p; s/^RERUN \([^ ]*\) .*/\1/p' "$2" | head -1)"
  [ -n "$id" ] || id="$(batch_line_ids "$1" | head -1)"
  echo "${id:-$1}"
}

# batch_run <letter> [--unattended] : runs the lines of one batch in order. Exit 3 (a person is needed) stops it, exit 4 (a run that was not
# valid: rerun) stops it only with --unattended (an attended run goes on and says the id is to be rerun), exit 1 (a check failed) never stops it.
# 0 when every line was 0, 1 when a check failed or an attended run skipped a rerun.
batch_run() {
  local letter="${1:-}" unattended=0 bin="${KIT_BATCH_BIN:-$KIT_SCRIPTS}" version start kind l text out rc worst=0 id took row
  [ $# -ge 1 ] || { usage; return 2; }
  shift
  case "${1:-}" in "") ;; --unattended) unattended=1; shift ;; *) usage; return 2 ;; esac
  [ $# -eq 0 ] || { usage; return 2; }
  batch_exists "$letter" || { echo "unknown batch: $letter"; usage; return 2; }
  version="$(cat "$KIT_ROOT/run/version" 2>/dev/null)"
  version="${version:-accept}"
  start=$SECONDS
  batch_header "$letter"
  out="$KIT_TMP/kit-batch.$$"
  while IFS=$'\t' read -r kind l text <&3; do
    [ "$l" = "$letter" ] || continue
    case "$kind" in
      say) echo "SAY $text"; continue ;;
      run) ;;
      *) continue ;;
    esac
    text="${text//@VERSION@/$version}"
    echo "RUN $text"
    set -- $text
    "$bin/$1" "${@:2}" </dev/null 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    case $rc in
      0) ;;
      1) [ "$worst" -ge 1 ] || worst=1 ;;
      3|4)
        id="$(batch_stopped_id "$text" "$out")"
        if [ "$rc" = 3 ] || [ "$unattended" = 1 ]; then
          echo "STOPPED $id exit $rc after $(batch_hms $((SECONDS - start)))"
          rm -f "$out"
          return $rc
        fi
        echo "NOTE $id exit $rc: rerun it (an attended batch goes on)"
        worst=1 ;;
      *) echo "NOTE $text exited $rc"; worst=1 ;;
    esac
  done 3< "$BATCH_TSV"
  rm -f "$out"
  took="$(batch_hms $((SECONDS - start)))"
  echo "BATCH $letter took $took"
  mkdir -p "$KIT_ROOT/run" "$KIT_ROOT/batch-kept" 2>/dev/null
  row="$(printf '%s\t%s\t%s' "$letter" "$took" "$(date '+%Y-%m-%d %H:%M:%S')")"
  printf '%s\n' "$row" >> "$KIT_ROOT/run/batch-times.tsv"
  printf '%s\n' "$row" >> "$KIT_ROOT/batch-kept/batch-times.tsv"
  return $worst
}

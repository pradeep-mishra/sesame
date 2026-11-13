#!/bin/bash
# kit-run.sh <S1..S4|S6..S9|all> [--slice N | --ids <id,id,...>] [--plant <id>]
# kit-run.sh batches | batch <letter> [--unattended]
# kit-run.sh prep <fresh-throttled|photos [--no-wait] [--cache-dir <dir>]|busy50k|index50k [--restore-only]|setup [--trace <name>]|minimix [--no-start]|tree [--trace <name>]|golden [--hold-start]|mix500 [--no-start]|pauselong <pdf|audio|video>|overlap|upgrade>
#
# The runner of the feature maps (verify.md, Drive) and the starting recipes (scripts/kit-lib/recipes.sh).
#
# A run prints one line per sub-feature, `CHECK <id> PASS|FAIL|NEEDS-A-PERSON <name>`, then
# `CHECKS: <passed> passed, <failed> failed, <skipped> skipped, <needs-a-person> needs-a-person` and, when
# the last number is above zero, `NOT PROVEN, NEEDS A PERSON: <id>, <id>`. The ids come from
# scripts/kit-lib/checks.tsv (id, first slice, kind auto|auto-or-person|reading); a run covers the ids whose
# first slice is at most --slice (default: scripts/kit-lib/slice). An id with no check written prints
# `CHECK <id> FAIL no check written`, so a check cannot be dropped by deleting its code. A run that finds the
# app not running starts it (`kit-launch.sh start`).
#
# A check is a bash function check_<id with dots as underscores> (check_S1_5) in a file
# scripts/kit-lib/checks-<name>.sh, which this script sources. It prints one `CHECK <id> ...` line (extra
# lines are allowed) and uses the exit codes of every kit script; a reading that was taken prints
# `CHECK <id> NEEDS-A-PERSON reading <figure> bar <bar> on the real 50,000-row index NOTE within|over bar` and never PASS or FAIL. A check that
# cannot be valid (indexer not busy, probe file missing ...) prints `RERUN <id> not valid: <reason>` and no
# CHECK line, and returns 4: the run then exits 4 and names the ids that did not print. With --plant <id>
# only that check runs, with KIT_PLANT=1: it must change one input and print `FAIL planted: <what>`; a check
# that still passes is turned into a FAIL by this script, so a plant that goes unseen is never green.
# kit-perms.sh check --for <id> runs just before each written check; a missing grant is NEEDS-A-PERSON.
# The evidence of each id is saved under the scenario of the id (S6 for S6.10), whatever id the last kit-reset.sh was
# given: this script exports KIT_EVIDENCE_SCENARIO for each check (scripts/kit-lib/common.sh, kit_evidence_dir).
# The recipe `photos` is ready when the index is done and, from slice 2 on, when the menu bar says Ready too. checks.floor
# (62) is the number of `auto` ids of slices 1 and 2 that need no administrator rights (every one but S6.8); it counts
# PASS only, so a check that needed a person does not make up for one that failed, and it is never lowered.
#
# With --ids S1.7,S1.10 (a comma list of ids of that scenario, any slice) only those checks run, in the order of
# checks.tsv, so a re-check of the ids that failed does not run the whole slice (a full S1 slice took 80 minutes).
# Each check still makes its own starting state exactly as in a slice run (a check that needs the photos indexed
# runs the recipe `photos` once for the ids of the list, and the checks that start from a fresh state reset it
# themselves), so a list gives the same verdict per id as the full run. An unknown id is a usage error (exit 2) and
# nothing runs; --ids cannot be combined with --slice or --plant. The default (no --ids) is unchanged.
#
# Exit codes: 0 every id printed and none failed; 1 a check failed or was skipped, an id did not print,
# or, for a full `all` run, the passes are below scripts/kit-lib/checks.floor (needs-a-person does not count; a
# scenario, --ids or --plant run needs one pass or reading); 2 usage; 3 a recipe needs a person;
# 4 a run or a recipe precondition did not hold (never a pass, never a fail: rerun).
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/recipes.sh"
. "$KIT_LIB/batches.sh"

for f in "$KIT_LIB"/checks-*.sh; do [ -f "$f" ] && . "$f"; done

usage() {
  cat >&2 <<'EOF'
usage: kit-run.sh <S1..S4|S6..S10|all> [--slice N | --ids <id,id,...>] [--plant <id>]
       kit-run.sh batches
       kit-run.sh batch <letter> [--unattended] [--version <V>]
       kit-run.sh prep fresh-throttled
       kit-run.sh prep photos [--no-wait] [--cache-dir <dir>]
       kit-run.sh prep busy50k
       kit-run.sh prep index50k [--restore-only]
       kit-run.sh prep setup [--trace <name>]
       kit-run.sh prep minimix [--no-start]
       kit-run.sh prep tree [--trace <name>]
       kit-run.sh prep golden [--hold-start]
       kit-run.sh prep mix500 [--no-start]
       kit-run.sh prep pauselong <pdf|audio|video>
       kit-run.sh prep overlap
       kit-run.sh prep upgrade
  batches     prints the batches of the Accept stage (scripts/kit-lib/batches.tsv): per batch its launch count, ids, lines, how to run it and
               how long it last took; it starts nothing
  batch <L>    runs the lines of batch L in order and prints `BATCH <L> took <h:mm:ss>`; exit 3 (a person is needed) stops it, with
               --unattended exit 4 (not valid: rerun) stops it too (`STOPPED <id> exit <n> after <h:mm:ss>`)
               --version V sets the saved version the batch's @VERSION@ lines use (else the last reset's, else `accept`)
  --slice N    only the ids whose first slice is at most N (default: scripts/kit-lib/slice)
  --ids a,b,c   only these ids of the scenario (any slice), e.g. --ids S1.7,S1.10; each makes its own starting state
  --plant <id>  run that one check with one input deliberately wrong; it must print FAIL planted: <what>
  --cache-dir   where the model files are read from (relative to the kit root)
  --trace name  prep setup: starts the file trace <name> (kit-trace.sh) before the app; needs the administrator session
                prep tree: the same, plus the network trace, the connection log and two planted connections (S8.2, S8.3, S8.7)
  index50k      prep index50k: LONG, the build takes hours. The golden fixture, api-client and generated filler indexed by the real helper with
                the real model until the index holds at least 50,000 rows (a smaller count is exit 4), kept in cache/index50k-real-<V>/ with a
                meta record of the saved version and vector_source; a second call for the same saved version restores it ("restored from cache");
                a cache of another saved version or vector_source is refused ("stale") and rebuilt, with --restore-only it is exit 4 instead
  --hold-start  prep golden: builds golden, golden-docs and boundary, picks all three and stops before Start indexing
                (run/recipe says `golden hold`; S3.6 presses Start itself while it watches the menu say Indexing)
  --no-start    prep minimix: picks the mini mix and leaves Start indexing unpressed
                prep mix500: the same for the 500-file mix (S6.11 reads the setup estimate first)
  pauselong     prep pauselong: picks one long unit alone (the 60-page PDF, the 60-minute audio clip or the 2-minute video) and starts
                indexing, so it is the only unit in flight (S7.2)
  overlap       prep overlap: the four overlap pairs of gate-matrix.csv picked, nothing ticked, indexed to Ready
  upgrade       prep upgrade: keeps the throwaway home another build made (kit-reset.sh --keep-home), replaces apps/Sesame.app with
                the current dist/Sesame.app, launches it and waits for Ready; exit 4 when the home holds no old index with code rows
EOF
}

# The app is started when none runs; a start that fails is a note, the checks then say what they lack.
ensure_app() {
  local out rc
  kit_need_ps || { echo "note: the app was not looked for"; return 0; }
  [ -n "$(kit_pid_of app)" ] && return 0
  out="$(kq "$KIT_SCRIPTS/kit-launch.sh" start 2>&1)"; rc=$?
  if [ $rc = 0 ]; then echo "app was not running: $out"; else echo "note: the app could not be started: $out"; fi
  return 0
}

# run_checks <S1..S4|S6..S8|all> <slice> <plant id or empty> [<ids, space separated, or empty>]
run_checks() {
  local scen="$1" slice="$2" plant="$3" ids="${4:-}"
  local id first kind fn tmp pout prc reason verdict rc floor ok_floor
  local p=0 f=0 s=0 n=0 nl="" rerun="" sep=""
  floor="$(cat "$KIT_LIB/checks.floor" 2>/dev/null)"; floor="${floor:-1}"
  tmp="$KIT_TMP/kit-run-check.$$"
  while IFS=$'\t' read -r id first kind <&3; do
    [ -n "$id" ] || continue
    if [ -n "$plant" ]; then
      [ "$id" = "$plant" ] || continue
    elif [ -n "$ids" ]; then
      case " $ids " in *" $id "*) ;; *) continue ;; esac
    else
      [ "$scen" = all ] || [ "${id%%.*}" = "$scen" ] || continue
      [ "$first" -le "$slice" ] || continue
    fi
    fn="check_${id//./_}"
    # the evidence of this id (its own output and every kit script it calls) goes under the scenario of the id,
    # not under the id the last kit-reset.sh was given (common.sh, kit_evidence_dir)
    KIT_EVIDENCE_SCENARIO="${id%%.*}"
    export KIT_EVIDENCE_SCENARIO
    if ! declare -F "$fn" >/dev/null; then
      echo "CHECK $id FAIL no check written"
      f=$((f + 1))
      continue
    fi
    if [ -x "$KIT_SCRIPTS/kit-perms.sh" ]; then
      pout="$(kq "$KIT_SCRIPTS/kit-perms.sh" check --for "$id" 2>&1)"; prc=$?
      if [ $prc = 3 ]; then
        reason="$(printf '%s\n' "$pout" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
        echo "CHECK $id NEEDS-A-PERSON $reason"
        n=$((n + 1)); nl="$nl$sep$id"; sep=", "
        continue
      fi
    fi
    echo "  | $id started $(date '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$plant" ]; then
      KIT_PLANT=1; export KIT_PLANT
      "$fn" </dev/null >"$tmp" 2>&1; rc=$?
      # a planted check that passed is rewritten before anything is shown
      awk -v id="$id" '$1 == "CHECK" && $2 == id && $3 == "PASS" && !done { print "CHECK " id " FAIL planted: the check passed with one input deliberately wrong"; done = 1; next } { print }' "$tmp" >"$tmp.out"
      cat "$tmp.out"; mv "$tmp.out" "$tmp"
    else
      KIT_PLANT=; export KIT_PLANT
      "$fn" </dev/null 2>&1 | tee "$tmp"
      rc=${PIPESTATUS[0]}
    fi
    if [ $rc = 4 ]; then
      grep -q "^RERUN $id " "$tmp" || echo "RERUN $id not valid: the check exited 4 without saying why"
      rerun="$rerun$id "
      continue
    fi
    verdict="$(awk -v id="$id" '$1 == "CHECK" && $2 == id { print $3; exit }' "$tmp")"
    case "$verdict" in
      PASS) p=$((p + 1)) ;;
      FAIL) f=$((f + 1)) ;;
      NEEDS-A-PERSON) n=$((n + 1)); nl="$nl$sep$id"; sep=", " ;;
      SKIPPED) s=$((s + 1)) ;;
      *) echo "CHECK $id FAIL the check printed no result line"; f=$((f + 1)) ;;
    esac
  done 3< "$KIT_LIB/checks.tsv"
  rm -f "$tmp"

  [ $((p + f + s + n)) -gt 0 ] || [ -n "$rerun" ] || echo "note: no check of $scen is first drivable in slice $slice"
  # Round C, N5: a full run (`all`, no --ids, no --plant) must have at least checks.floor PASSES; needs-a-person
  # does not count. A scenario, --ids or --plant run keeps the small floor of one (a pass or a reading).
  if [ "$scen" = all ] && [ -z "$plant" ] && [ -z "$ids" ]; then
    [ "$p" -ge "$floor" ] || echo "note: $p passed, below checks.floor ($floor passes; needs-a-person does not count)"
    ok_floor=$([ "$p" -ge "$floor" ] && echo 1 || echo 0)
  else
    [ $((p + n)) -ge 1 ] || echo "note: passed plus needs-a-person is below 1"
    ok_floor=$([ $((p + n)) -ge 1 ] && echo 1 || echo 0)
  fi
  if [ -n "$rerun" ]; then
    echo "NOT PRINTED (rerun): $rerun"
  fi
  echo "CHECKS: $p passed, $f failed, $s skipped, $n needs-a-person"
  [ "$n" -gt 0 ] && echo "NOT PROVEN, NEEDS A PERSON: $nl"
  [ -z "$rerun" ] || return 4
  [ "$f" = 0 ] && [ "$s" = 0 ] && [ "$ok_floor" = 1 ] && return 0
  return 1
}

main() {
  local mode="${1:-}" slice="$KIT_SLICE" plant="" in_plant="" ids="" idlist="" one slice_given=""
  export KIT_TYPE_DELAY_MS="${KIT_TYPE_DELAY_MS:-80}"
  case "$mode" in
    prep) shift; if kit_screen_locked; then kit_say_locked; return 3; fi; recipe_main "$@"; return $? ;;
    batches) shift; [ $# -eq 0 ] || { usage; return 2; }; batches_list; return 0 ;;
    batch)
      shift
      local bv="" bv_set="" rest=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --version) [ $# -ge 2 ] || { usage; return 2; }; bv="$2"; bv_set=1; shift 2 ;;
          *) rest+=("$1"); shift ;;
        esac
      done
      if [ -n "$bv_set" ]; then
        case "$bv" in ""|-*|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
        case "${rest[*]:1}" in ""|--unattended) ;; *) usage; return 2 ;; esac
        if batch_exists "${rest[0]:-}"; then
          mkdir -p "$KIT_ROOT/run" && printf '%s\n' "$bv" > "$KIT_ROOT/run/version" || return 1
        fi
      fi
      if batch_exists "${rest[0]:-}" && kit_screen_locked; then kit_say_locked; return 3; fi
      batch_run ${rest[@]+"${rest[@]}"}
      return $? ;;
    S[1-46-9]|S10|all) shift ;;
    *) usage; return 2 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --slice) [ $# -ge 2 ] || { usage; return 2; }; slice="$2"; slice_given=1; shift 2 ;;
      --plant) [ $# -ge 2 ] || { usage; return 2; }; plant="$2"; shift 2 ;;
      --ids) [ $# -ge 2 ] || { usage; return 2; }; idlist="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$slice" in [1-9]) ;; *) usage; return 2 ;; esac
  if [ -n "$idlist" ]; then
    if [ -n "$plant" ] || [ -n "$slice_given" ]; then
      echo "--ids cannot be combined with --slice or --plant"
      usage
      return 2
    fi
    # every id must be an id of the scenario in checks.tsv, else nothing runs
    for one in $(printf '%s' "$idlist" | tr ',' ' '); do
      if [ -z "$(awk -F'\t' -v id="$one" -v scen="$mode" '$1 == id && (scen == "all" || index($1, scen ".") == 1) { print $1 }' "$KIT_LIB/checks.tsv")" ]; then
        echo "unknown check id for $mode: $one"
        usage
        return 2
      fi
      ids="$ids$one "
    done
    [ -n "$ids" ] || { usage; return 2; }
  fi
  if [ -n "$plant" ]; then
    in_plant="$(awk -F'\t' -v id="$plant" -v scen="$mode" '$1 == id && (scen == "all" || index($1, scen ".") == 1) { print $1 }' "$KIT_LIB/checks.tsv")"
    if [ -z "$in_plant" ]; then
      echo "unknown check id for $mode: $plant"
      usage
      return 2
    fi
  fi
  if kit_screen_locked; then kit_say_locked; return 3; fi
  ensure_app
  run_checks "$mode" "$slice" "$plant" "$ids"
}

kit_wrap "$(kit_slug kit-run "$@")" main "$@"
exit $?

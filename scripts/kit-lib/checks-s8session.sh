#!/bin/bash
# The one observed S8 session of the tree recipe (plan-3-tasks t8, D17, D19): the activity every S8 reader shares
# and the closing of the observers. Sourced by kit-run.sh after common.sh and recipes.sh, never run. It holds no check:
# the checks of t9 to t12 call these two functions (and tree_need of recipes.sh).
#
#   s8_activity [<id>]      runs once (run/s8-activity-done: `searches=<n> opens=<n> indexing-done-at=<epoch.ms>
#                           last-open-at=<epoch.ms>`; a second call does nothing): tree_need, indexing done, the menu bar
#                           Ready, the index snapshot before-opens, 50 marker searches `qm-<n>-<seed>` (written first to
#                           run/markers.txt), 20 searches ending in a plain Enter on a result (14 real fixture name
#                           stems, then the order test: search A listed to run/order-before.txt, five Enter opens of
#                           result 3, listed again to run/order-mid.txt, one Enter open of another result, listed again
#                           to run/order-after.txt), the index snapshot after-opens. Every search goes through
#                           kit-search.sh, so KIT_TYPE_DELAY_MS is the person's. The output of the searches is in
#                           run/s8-activity.log. An empty result, a search with fewer than three results, a search with
#                           no result to open, empty order files and opens=0 are recorded and are never exit 4: the
#                           readers (S8.3, S8.7, S8.9) guard those. Only a real precondition is exit 4 (a wait that
#                           times out, a panel that cannot be driven, a list that does not settle).
#   s8_close_window [<id>]  tree_need, s8_activity, then (a) the prompts watcher: when run/prompts/s8.result is absent,
#                           `kit-privacy.sh prompts stop s8` saves it; (b) the observers: when the recipe has a trace and
#                           run/observers-closed-at is absent, administrator rights, plant 3, `kit-net.sh stop`,
#                           `kit-trace.sh stop` and the closing time in run/observers-closed-at. Each part runs once.
# <id> is the check that calls (it goes to run/window-ids while the observers are open and into a RERUN line).

# s8_now : the epoch with milliseconds (the form the plants print).
s8_now() { perl -MTime::HiRes=time -e 'printf("%.3f\n", time)' 2>/dev/null || printf '%s.000\n' "$(date +%s)"; }

# s8_search <text> [kit-search.sh options...] : one search through the panel. The output is kept in S8_OUT (and appended to
# run/s8-activity.log), the searches counted in S8_SEARCHES. Status 0 done; 1 the selection had no row to go to (an empty
# or short result: recorded, not an error); 3 NEEDS A PERSON (printed); 4 the panel could not be driven or the list did not
# settle (RERUN printed).
S8_OUT=""
S8_SEARCHES=0
s8_search() {
  local rc
  S8_OUT="$(kq "$KIT_SCRIPTS/kit-search.sh" "$@" 2>&1 </dev/null)"; rc=$?
  S8_SEARCHES=$((S8_SEARCHES + 1))
  { printf '== kit-search.sh %s (exit %s)\n' "$*" "$rc"; printf '%s\n' "$S8_OUT"; } >> "$KIT_ROOT/run/s8-activity.log"
  case $rc in
    0) return 0 ;;
    1)
      case "$S8_OUT" in
        *"the selection is on row"*) return 1 ;;
      esac
      echo "RERUN ${S8_ID:-S8} not valid: the search \"$1\" could not be made: $(printf '%s\n' "$S8_OUT" | tail -1)"
      return 4 ;;
    3) printf '%s\n' "$S8_OUT"; return 3 ;;
    *) echo "RERUN ${S8_ID:-S8} not valid: the search \"$1\" ended with exit $rc: $(printf '%s\n' "$S8_OUT" | tail -1)"; return 4 ;;
  esac
}

# s8_rows : the number of result rows of the last search (the `rows <n>` line of kit-search.sh).
s8_rows() { printf '%s\n' "$S8_OUT" | awk '$1 == "rows" { print $2; found = 1; exit } END { if (!found) print 0 }'; }

# s8_stems : twenty names, one a line: the stems of the plain/photos pictures of tree.tsv, then the stems of the picture
# cells of gate-matrix.csv that are in the index (the names of real fixture files, without an extension).
s8_stems() {
  {
    awk -F'\t' '$1 ~ /^plain\/photos\// { n = split($1, a, "/"); s = a[n]; sub(/\.[^.]*$/, "", s); print s }' "$KIT_LIB/tree.tsv"
    awk -F, 'NR > 1 && $4 == "yes" && $2 ~ /\.(png|jpe?g|heic|webp|tiff?|gif)$/ { n = split($2, a, "/"); s = a[n]; sub(/\.[^.]*$/, "", s); print s }' "$KIT_LIB/gate-matrix.csv"
  } | awk '!seen[$0]++' | head -20
}

# s8_search_a : search A of the order test, the folder name that most picture rows of tree.tsv share (several cells share it,
# so the list should hold at least three results; S8.9 fails it as RERUN when it does not).
s8_search_a() {
  local a
  a="$(awk -F'\t' '$2 == "jpeg" || $2 == "png" { n = split($1, p, "/"); if (n > 1) c[p[n - 1]]++ } END { for (k in c) print c[k], k }' "$KIT_LIB/tree.tsv" | sort -rn | awk 'NR == 1 { print $2 }')"
  printf '%s\n' "${a:-photos}"
}

s8_activity() {
  local run="$KIT_ROOT/run" S8_ID="${1:-S8}" rc seed n opens=0 indexing_done_at last_open_at stem a
  [ -f "$run/s8-activity-done" ] && return 0
  tree_need "$S8_ID" || return $?
  : > "$run/s8-activity.log"
  S8_SEARCHES=0
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 900 || { echo "RERUN $S8_ID not valid: indexing was not done within 900 s"; return 4; }
  wait_menu_ready 120; rc=$?
  [ $rc = 0 ] || { [ $rc = 3 ] && return 3; echo "RERUN $S8_ID not valid: the menu bar did not say Ready within 120 s after indexing was done"; return 4; }
  indexing_done_at="$(s8_now)"
  kq "$KIT_SCRIPTS/kit-index.sh" snapshot before-opens || { echo "RERUN $S8_ID not valid: the index could not be read for the snapshot before the opens"; return 4; }

  # 50 marker searches, one per search; the markers are written first, so a scan can look for exactly these
  seed="$(date +%s)"
  : > "$run/markers.txt"
  for ((n = 1; n <= 50; n++)); do printf 'qm-%s-%s\n' "$n" "$seed" >> "$run/markers.txt"; done
  for ((n = 1; n <= 50; n++)); do
    s8_search "qm-$n-$seed"; rc=$?
    [ $rc -le 1 ] || return $rc
  done

  # 14 searches of real fixture name stems, each followed by a plain Enter on the first result (the default app opens)
  n=0
  while IFS= read -r stem <&3; do
    [ -n "$stem" ] || continue
    [ $n -lt 14 ] || break
    n=$((n + 1))
    s8_search "$stem" --open; rc=$?
    [ $rc -le 1 ] || return $rc
    last_open_at="$(s8_now)"
    if [ $rc = 0 ] && [ "$(s8_rows)" -gt 0 ]; then opens=$((opens + 1)); fi
  done 3<<EOF
$(s8_stems)
EOF

  # the order test: six of the 20 opens
  a="$(s8_search_a)"
  s8_search "$a"; rc=$?
  [ $rc -le 1 ] || return $rc
  printf '%s\n' "$S8_OUT" | awk '$1 == "row"' > "$run/order-before.txt"
  for ((n = 1; n <= 5; n++)); do
    s8_search "$a" --select 3 --open; rc=$?
    [ $rc -le 1 ] || return $rc
    last_open_at="$(s8_now)"
    if [ $rc = 0 ] && [ "$(s8_rows)" -ge 3 ]; then opens=$((opens + 1)); fi
  done
  s8_search "$a"; rc=$?
  [ $rc -le 1 ] || return $rc
  printf '%s\n' "$S8_OUT" | awk '$1 == "row"' > "$run/order-mid.txt"
  s8_search "$a" --select 2 --open; rc=$?
  [ $rc -le 1 ] || return $rc
  last_open_at="$(s8_now)"
  if [ $rc = 0 ] && [ "$(s8_rows)" -ge 2 ]; then opens=$((opens + 1)); fi
  s8_search "$a"; rc=$?
  [ $rc -le 1 ] || return $rc
  printf '%s\n' "$S8_OUT" | awk '$1 == "row"' > "$run/order-after.txt"

  kq "$KIT_SCRIPTS/kit-index.sh" snapshot after-opens || { echo "RERUN $S8_ID not valid: the index could not be read for the snapshot after the opens"; return 4; }
  printf 'searches=%s opens=%s indexing-done-at=%s last-open-at=%s\n' "$S8_SEARCHES" "$opens" "$indexing_done_at" "${last_open_at:-$(s8_now)}" > "$run/s8-activity-done"
  echo "s8 activity done: $(cat "$run/s8-activity-done") (the searches are in $run/s8-activity.log, the markers in $run/markers.txt)"
}

s8_close_window() {
  local run="$KIT_ROOT/run" S8_ID="${1:-S8}" trace plant_rc
  tree_need "$S8_ID" || return $?
  s8_activity "$S8_ID" || return $?
  if [ ! -f "$run/prompts/s8.result" ]; then
    kq "$KIT_SCRIPTS/kit-privacy.sh" prompts stop s8
  fi
  trace="$(tree_trace_name)"
  if [ -n "$trace" ] && [ ! -f "$run/observers-closed-at" ]; then
    admin_session || return $?
    kq "$KIT_SCRIPTS/kit-net.sh" control "$trace"; plant_rc=$?
    kq "$KIT_SCRIPTS/kit-net.sh" stop "$trace"
    kq "$KIT_SCRIPTS/kit-trace.sh" stop "$trace"
    s8_now > "$run/observers-closed-at"
    [ $plant_rc = 0 ] || { echo "RERUN $S8_ID not valid: plant 3 could not be made (kit-net.sh control exited $plant_rc); the observers are stopped"; return 4; }
  fi
  return 0
}

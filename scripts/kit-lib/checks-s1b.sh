#!/bin/bash
# The slice 1 checks of S1 for the Not ready texts, the error variants, the shortcut, the keyboard and the look
# (feature map S1: S1.17 to S1.24, S1.26 to S1.29, S1.31). S1.21, S1.22 and S1.29 also carry their slice 2 parts (Delete
# index, the Pause, the rest of Settings, the menu and the setup windows), whose helpers sit in checks-s1c.sh.
# Sourced by kit-run.sh after common.sh and recipes.sh,
# never run. It uses the helpers of checks-s1.sh (s1_*) and panel.sh (pn_*), which kit-run.sh also sources, and only
# at call time. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a failure says why, on one
# line), extra lines before it, and uses the exit codes of every kit script: 0 for a pass or a needs-a-person, 1 for
# a fail, 4 for `RERUN <id> not valid: <reason>` (a run whose precondition did not hold is never a pass or a fail).
# With KIT_PLANT=1 (kit-run.sh --plant <id>) the shortcut posts of the check are replaced by a chord the app does
# not own (Shift+Command+K, see s1_begin), so the check must print `CHECK <id> FAIL planted: <what>`.
#
# Starting states. S1.17 to S1.19 and S1.22 (i) start from the recipe `fresh-throttled` (reset, mirror at 500,000
# bytes a second, app started, no setup done) and do their own steps from there, because the checks before them in
# a run (S1.5 on) have already reset the state. S1.20, S1.21 and S1.22 (ii) start from a fresh cached-model state,
# drive the setup window by the recipe helpers (the picker, the Start press), and read the panel. S1.27, S1.28 and
# S1.31 need no index, so they start from a fresh cached-model state with the app running and nothing picked
# (S1.31 reads the look of the panel whatever it shows). S1.23, S1.24, S1.26 and S1.29 need the photos indexed
# (recipe `photos`, once per starting state: see s1_need_photos in checks-s1.sh).
#
# Kit safety (verify.md, Kit safety): every shortcut post sits between `kitwindow open` and `kitwindow close` made
# by pn_open_panel and pn_hotkey and closed on every path (nr_run); typing and keys go to Sesame only, once
# `kit-ax.sh frontmost` reads Sesame; Command+H and Control+Command+Q are never posted; Command+Space, Command+Tab
# and Command+Q are not posted either, because the key tool cannot tell whether macOS would take them before the
# recorder (they print `not deliverable`, covered by the refusal table in `swift test` and by a person, S1.N5).
# The look is set with `kit-ax.sh appearance light|dark --keep`, only the panel window is photographed, and
# `appearance restore` runs on every path.

NR_SUP="$KIT_ROOT/home/Library/Application Support/Sesame"
NR_MODELS="$NR_SUP/models"
NR_TEXT_MODEL="embeddinggemma-2-Q8_0.gguf"
NR_FILLER_ROWS=1500          # 1500 index rows = 500 small photos: a longer walk to freeze, and indexing still ends inside the 900 s Ready wait
NR_MSG=""
NR_RC=0
NR_OUT=""
NR_WHY=""
NR_DL=""
NR_DONE=0
NR_OPEN=0
NR_KNOWN=0
NR_KINDS=""
NR_SAMPLES="a dog on the beach|the clause about pets in the lease|where they talk about sleep"

# ---- plumbing -------------------------------------------------------------------------------------

nr_why() { NR_WHY="${NR_WHY:+$NR_WHY; }$1"; }

# nr_pick_msg <output> : the first NEEDS A PERSON line without its label, else the last non-empty line.
nr_pick_msg() {
  local p
  p="$(printf '%s\n' "$1" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
  if [ -n "$p" ]; then printf '%s' "$p"; else s1_last "$1"; fi
}

# nr_cleanup : the system look put back, a frozen helper thawed, the panel, full screen and kit window closed.
nr_cleanup() {
  pn_ax appearance restore >/dev/null 2>&1
  KIT_NO_EVIDENCE=1 "$S1_LD" thaw index >/dev/null 2>&1
  s1_cleanup
}

# nr_run <function> : the check body, then the cleanup on every path (a signal included).
nr_run() {
  local rc
  PN_CHORD=""
  trap 'nr_cleanup; exit 130' INT TERM HUP
  "$@"; rc=$?
  nr_cleanup
  trap 's1_cleanup; exit 130' INT TERM HUP
  return $rc
}

# nr_state_rc <id> <rc> <message> : the CHECK line for a starting state or a recipe step that did not finish; sets S1_RC.
# With NR_DEFER=1 nothing is printed: NR_FAILRC and NR_FAILMSG keep what would have been (S1.22 joins it to (i)).
NR_DEFER=""
NR_FAILRC=0
NR_FAILMSG=""
nr_state_rc() {
  if [ -n "$NR_DEFER" ]; then
    NR_FAILRC="$2"; NR_FAILMSG="$3"
    case "$2" in 3) S1_RC=0 ;; 4) S1_RC=4 ;; *) S1_RC=1 ;; esac
    return 0
  fi
  case "$2" in
    3) echo "CHECK $1 NEEDS-A-PERSON $3"; S1_RC=0 ;;
    4) echo "RERUN $1 not valid: $3"; S1_RC=4 ;;
    *) s1_fail "$1" "$3"; S1_RC=1 ;;
  esac
}

# nr_do <id> <what> <command...> : one recipe step. Status 0 done; else the CHECK line is printed, S1_RC is set and
# the status is 1. NR_OUT holds the output.
nr_do() {
  local id="$1" what="$2" rc
  shift 2
  NR_OUT="$("$@" 2>&1)"; rc=$?
  [ -z "$NR_OUT" ] || printf '%s\n' "$NR_OUT" | sed 's/^/  | /'
  [ $rc = 0 ] && return 0
  nr_state_rc "$id" "$rc" "$what: $(nr_pick_msg "$NR_OUT")"
  return 1
}

# nr_fresh_throttled / nr_fresh_cache : the starting state; status 0, else NR_RC and NR_MSG say why.
nr_fresh_throttled() {
  local out rc
  out="$(recipe_fresh_throttled 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe fresh-throttled: /'
  [ $rc = 0 ] && return 0
  NR_RC=$rc; NR_MSG="recipe fresh-throttled cannot finish: $(nr_pick_msg "$out")"
  return 1
}

nr_fresh_cache() {
  local out rc
  out="$({ recipe_state && recipe_reset cache && kq "$KIT_SCRIPTS/kit-launch.sh" start; } 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/fresh cached-model state: /'
  if [ $rc != 0 ]; then
    NR_RC=$rc; NR_MSG="the fresh state cannot be made: $(nr_pick_msg "$out")"
    return 1
  fi
  sleep 1
  return 0
}

# nr_save <name> : the last panel dump in the evidence folder as ax-<name>.txt (never over an older one).
nr_save() {
  local dir f n=1
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/ax-$1.txt"
  while [ -e "$f" ]; do n=$((n + 1)); f="$dir/ax-$1-$n.txt"; done
  printf '%s\n' "$PN_DUMP" > "$f" 2>/dev/null && echo "saved $f"
}

# nr_shot <name> : a picture of the panel window alone (kit-ax.sh shot --panel), kept as evidence for the person; a
# picture that cannot be taken is not a failure of the check.
nr_shot() {
  local out
  out="$(pn_ax shot "$1" --panel 2>&1)"
  printf '%s\n' "$out" | sed -n '1p' | sed 's/^/  | /'
  return 0
}

# ---- reading the panel ----------------------------------------------------------------------------

# nr_has <text> : the last dump holds the text. nr_has_ci : the same, ignoring case.
nr_has() { case "$PN_DUMP" in *"$1"*) return 0 ;; esac; return 1; }
nr_has_ci() {
  local d w
  d="$(printf '%s' "$PN_DUMP" | tr 'A-Z' 'a-z')"
  w="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$d" in *"$w"*) return 0 ;; esac
  return 1
}
nr_need_heading() { nr_has "Not ready yet" || nr_why "panel shows no 'Not ready yet' heading"; }
nr_need_text() { nr_has "$1" || nr_why "panel shows no '$1' text"; }
nr_must_lack() { if nr_has "$1"; then nr_why "panel shows '$1' $2"; fi; return 0; }
nr_rows_n() { pn_rows | awk 'NF { n++ } END { print n + 0 }'; }

# nr_read_panel <seconds> <text>... : opens the panel with the shortcut and polls its dump until every text is in
# it. Status 0 all there; 1 not all within the time (PN_DUMP is the last dump); 2 no panel could be opened (PN_OUT
# says why); 3 a person-step (PN_OUT says which).
nr_read_panel() {
  local secs="$1" t ok rc end
  shift
  pn_open_panel; rc=$?
  [ $rc = 0 ] || { [ $rc = 3 ] && return 3; return 2; }
  end=$((SECONDS + secs))
  while :; do
    if ! pn_panel_exists; then
      pn_open_panel; rc=$?
      [ $rc = 0 ] || { [ $rc = 3 ] && return 3; return 2; }
    fi
    pn_dump
    ok=1
    for t in "$@"; do nr_has "$t" || ok=0; done
    [ $ok = 1 ] && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.5
  done
}

# nr_ensure_panel : the panel is open (opened with the shortcut when it is not); PN_DUMP holds a fresh dump.
nr_ensure_panel() {
  local rc
  if ! pn_panel_exists; then pn_open_panel; rc=$?; [ $rc = 0 ] || return $rc; fi
  pn_dump
}

# nr_panel_rc <id> <rc of nr_read_panel> : status 0 when the dump can be judged; else the CHECK line is printed,
# S1_RC is set and the status is 1.
nr_panel_rc() {
  case "$2" in
    0|1) return 0 ;;
    3) echo "CHECK $1 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; S1_RC=0 ;;
    *) s1_fail "$1" "$PN_OUT"; S1_RC=1 ;;
  esac
  return 1
}

# ---- the download and the index, as the files and the logs show them -------------------------------

# nr_bytes : the bytes of every file in models/ (whole files and .partial files).
nr_bytes() {
  local f t=0 b
  for f in "$NR_MODELS"/*; do
    [ -f "$f" ] || continue
    b="$(stat -f %z "$f" 2>/dev/null)"
    t=$((t + ${b:-0}))
  done
  echo "$t"
}

# nr_partial_bytes : the bytes of the text model's .partial file in models/ (0 when there is none).
nr_partial_bytes() { stat -f %z "$NR_MODELS/$NR_TEXT_MODEL.partial" 2>/dev/null || echo 0; }

# nr_wait_rising <seconds> : status 0 once the text model's .partial holds bytes and holds more of them 2 s later;
# NR_DL says what was seen. The mirror logs a request only when it finishes (at 500,000 bytes a second that is
# minutes), so a re-download in flight is judged by the new bytes in models/, as checks-s6.sh reads it.
nr_wait_rising() {
  local end=$((SECONDS + $1)) p1 p2
  while :; do
    p1="$(nr_partial_bytes)"
    if [ "$p1" -gt 0 ]; then
      sleep 2
      p2="$(nr_partial_bytes)"
      if [ "$p2" -gt "$p1" ]; then NR_DL="$NR_TEXT_MODEL.partial grew from $p1 to $p2 bytes in 2 s"; return 0; fi
      NR_DL="$NR_TEXT_MODEL.partial held $p1 bytes and $p2 bytes 2 s later"
    else
      NR_DL="models/ holds no $NR_TEXT_MODEL.partial"
    fi
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.5
  done
}

# nr_wait_bytes <seconds> : status 0 once models/ holds bytes; NR_DL says what was seen. The mirror logs a request
# only when it finishes, so a download in flight shows in models/ and not yet in the log (as checks-s6.sh reads it).
nr_wait_bytes() {
  local end=$((SECONDS + $1)) b
  while :; do
    b="$(nr_bytes)"
    if [ "$b" -gt 0 ]; then NR_DL="models/ holds $b bytes"; return 0; fi
    [ "$SECONDS" -ge "$end" ] && break
    sleep 0.5
  done
  NR_DL="models/ holds $b bytes (after $1 s)"
  return 1
}

nr_models_whole() { models_check "$NR_MODELS" >/dev/null 2>&1; }

# nr_start_pressed : true, false or absent, as settings.json reads (kit-index.sh settings).
nr_start_pressed() {
  kq "$KIT_SCRIPTS/kit-index.sh" settings 2>&1 | awk '/"startPressed" *=>/ { print ($3 == "true" || $3 == "1") ? "true" : "false"; f = 1 } END { if (!f) print "absent" }'
}

nr_files_n() { kq "$KIT_SCRIPTS/kit-index.sh" rows 2>&1 | awk '$1 == "files" { print $2; exit }'; }

# nr_status_counts : NR_DONE (files done), NR_OPEN (pending or partial), NR_KNOWN (the files rows), NR_KINDS ("<kind> <n>" lines).
nr_status_counts() {
  local out
  out="$(kq "$KIT_SCRIPTS/kit-index.sh" status 2>&1)"
  NR_DONE="$(printf '%s\n' "$out" | awk '$2 == "done" && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }')"
  NR_OPEN="$(printf '%s\n' "$out" | awk '($2 == "pending" || $2 == "partial") && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }')"
  NR_KNOWN="$(printf '%s\n' "$out" | awk '$1 == "files" { print $2; exit }')"
  NR_KNOWN="${NR_KNOWN:-0}"
  NR_KINDS="$(printf '%s\n' "$out" | awk 'NF == 3 && $3 ~ /^[0-9]+$/ && ($2 == "done" || $2 == "pending" || $2 == "partial" || $2 == "could_not_read") { k[$1] += $3 } END { for (x in k) print x, k[x] }' | sort)"
}

# nr_pct : N of "Still indexing (N%)" in the last dump ("" when it is not there).
nr_pct() { printf '%s\n' "$PN_DUMP" | sed -n 's/.*Still indexing (\([0-9][0-9]*\)%).*/\1/p' | sed -n 1p; }

# nr_start_frozen <id> : a fresh cached-model state, the setup window driven, the filler picked, Start indexing
# pressed and the `index` helper frozen at once (kit-launch.sh freeze index), with the walk not done. Status 0 held;
# else the CHECK line (FAIL, NEEDS-A-PERSON or RERUN) is printed, S1_RC is set and the status is 1.
nr_start_frozen() {
  local id="$1" out rc=1 ftmp fpid i
  nr_fresh_cache || { nr_state_rc "$id" "$NR_RC" "$NR_MSG"; return 1; }
  nr_do "$id" "the setup window cannot be driven" wait_setup_window 8 || return 1
  nr_do "$id" "the filler folder cannot be built" kq "$S1_FX" build filler "$NR_FILLER_ROWS" || return 1
  nr_do "$id" "the filler folder cannot be picked" pick_folders filler || return 1
  # The freeze is armed BEFORE Start indexing is pressed: `freeze index --wait` stops the first new index helper
  # within 20 ms of its pid showing. A freeze started after the press lost the race against the helper's walk
  # (S1.22 "had already finished its walk when it was frozen").
  ftmp="$KIT_TMP/kit-freeze.$$"
  : > "$ftmp"
  kq "$S1_LD" freeze index --wait 30 > "$ftmp" 2>&1 &
  fpid=$!
  for ((i = 0; i < 40; i++)); do [ -s "$ftmp" ] && break; sleep 0.1; done
  if ! nr_do "$id" "Start indexing cannot be pressed" press_start; then
    kill "$fpid" 2>/dev/null
    wait "$fpid" 2>/dev/null
    rm -f "$ftmp"
    return 1
  fi
  wait "$fpid"; rc=$?
  out="$(cat "$ftmp" 2>/dev/null)"
  rm -f "$ftmp"
  if [ $rc != 0 ]; then
    nr_state_rc "$id" 4 "no index helper could be frozen within 30 s of Start indexing ($(s1_last "$out"))"
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/  | /'
  out="$(kq "$KIT_SCRIPTS/kit-index.sh" walk-done 2>&1)"; rc=$?
  if [ $rc = 0 ]; then
    nr_state_rc "$id" 4 "the index helper had already finished its walk when it was frozen ($out): rerun"
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/  | /'
  return 0
}

# ---- S1.17: Not ready, text 1: the model is still downloading ------------------------------------------------

s1_check_17() {
  local rc rows
  s1_begin S1.17 0 || return $S1_RC
  nr_fresh_throttled || { nr_state_rc S1.17 "$NR_RC" "$NR_MSG"; return $S1_RC; }
  nr_read_panel 6 "Not ready yet" "The model is still downloading"; rc=$?
  nr_panel_rc S1.17 $rc || return $S1_RC
  nr_save s1-17-panel
  nr_shot s1-text1
  NR_WHY=""
  nr_need_heading
  nr_need_text "The model is still downloading"
  rows="$(nr_rows_n)"
  [ "$rows" = 0 ] || nr_why "$rows result rows are listed in place of the not-ready text"
  nr_wait_bytes 1 || nr_why "the download is not running: $NR_DL"
  if [ -n "$NR_WHY" ]; then s1_fail S1.17 "$NR_WHY"; return 1; fi
  echo "CHECK S1.17 PASS with the mirror at 500,000 bytes a second and the download running ($NR_DL) the panel shows the heading \"Not ready yet\" and \"The model is still downloading\" in place of results"
}
check_S1_17() { nr_run s1_check_17; }

# ---- S1.18: Not ready, text 1: the model file was damaged ----------------------------------------------------

s1_check_18() {
  local rc planted size path why_pre=""
  s1_begin S1.18 0 || return $S1_RC
  nr_fresh_throttled || { nr_state_rc S1.18 "$NR_RC" "$NR_MSG"; return $S1_RC; }
  nr_wait_bytes 15 || why_pre="no model bytes had arrived (${NR_DL}) before the file was planted, so the damaged-model case was not reached the way a person reaches it"
  planted="$(kq "$S1_FX" plant-model truncated 2>&1)"; rc=$?
  printf '%s\n' "$planted" | sed 's/^/  | /'
  if [ $rc != 0 ]; then s1_fail S1.18 "kit-fixtures.sh plant-model truncated exited $rc: $(s1_last "$planted")"; return 1; fi
  # "PLANTED <path> <size> bytes": the path holds a space (Application Support), so it is cut out by its two ends
  path="$(printf '%s\n' "$planted" | sed -n 's/^PLANTED \(.*\) [0-9][0-9]* bytes.*$/\1/p' | sed -n 1p)"
  size="$(printf '%s\n' "$planted" | sed -n 's/^PLANTED .* \([0-9][0-9]*\) bytes.*$/\1/p' | sed -n 1p)"
  nr_read_panel 15 "Not ready yet" "The model file was damaged and is downloading again"; rc=$?
  nr_panel_rc S1.18 $rc || return $S1_RC
  nr_save s1-18-panel
  nr_shot s1-text1-damaged
  NR_WHY=""
  nr_need_heading
  nr_need_text "The model file was damaged and is downloading again"
  nr_wait_rising 10 || nr_why "no new bytes reached models/ for $NR_TEXT_MODEL after the file was planted ($NR_DL)"
  if [ -n "$path" ] && [ -e "$path" ] && [ "$(stat -f %z "$path" 2>/dev/null)" = "$size" ]; then
    nr_why "the planted file is still in models/ ($path, $size bytes): it was neither deleted nor replaced by a .partial"
  fi
  [ -z "$why_pre" ] || nr_why "$why_pre"
  if [ -n "$NR_WHY" ]; then s1_fail S1.18 "$NR_WHY"; return 1; fi
  echo "CHECK S1.18 PASS after a truncated $NR_TEXT_MODEL ($size bytes) was planted, within 15 s the panel shows \"Not ready yet\" and \"The model file was damaged and is downloading again\"; new bytes reached models/ ($NR_DL) and the planted file is gone from models/"
}
check_S1_18() { nr_run s1_check_18; }

# ---- S1.19: Not ready, text 2: indexing has not been started -------------------------------------------------

nr_walk_setup() {
  local i n=0 b
  for ((i = 0; i < 4; i++)); do
    if setup_has "Next"; then b="Next"
    elif setup_has "Not now"; then b="Not now"
    else break
    fi
    kq "$KIT_SCRIPTS/kit-ax.sh" click "$b" >/dev/null 2>&1 || break
    n=$((n + 1))
    sleep 0.5
  done
  echo "setup walked: Next or Not now pressed $n times, Start indexing never pressed"
}

s1_check_19() {
  local rc why_pre="" last now=0 stall=0 b start pressed files
  s1_begin S1.19 0 || return $S1_RC
  nr_fresh_throttled || { nr_state_rc S1.19 "$NR_RC" "$NR_MSG"; return $S1_RC; }
  if ! nr_wait_bytes 15; then
    why_pre="the model never started downloading ($NR_DL), so the model cannot be whole"
  else
    kq "$KIT_SCRIPTS/kit-mirror.sh" rate max >/dev/null 2>&1
    start=$SECONDS; last="$(nr_bytes)"; stall=$SECONDS
    until nr_models_whole; do
      b="$(nr_bytes)"
      if [ "$b" != "$last" ]; then last="$b"; stall=$SECONDS; fi
      if [ $((SECONDS - stall)) -ge 90 ]; then why_pre="the download stalled at $b bytes for 90 s with the mirror at full rate"; break; fi
      if [ $((SECONDS - start)) -ge 600 ]; then why_pre="the model files were not whole 600 s after the mirror went to full rate ($b bytes)"; break; fi
      sleep 2
    done
    if [ -z "$why_pre" ]; then echo "model files whole after $((SECONDS - start)) s at full rate"; fi
  fi
  if wait_setup_window 3 >/dev/null 2>&1; then
    nr_walk_setup
  else
    why_pre="${why_pre:+$why_pre; }there is no setup window to walk through"
  fi
  nr_read_panel 10 "Not ready yet" "Indexing has not been started"; rc=$?
  nr_panel_rc S1.19 $rc || return $S1_RC
  nr_save s1-19-panel
  nr_shot s1-text2
  NR_WHY=""
  nr_need_heading
  nr_need_text "Indexing has not been started"
  nr_must_lack "The model is still downloading" "although the model files are whole"
  pressed="$(nr_start_pressed)"
  files="$(nr_files_n)"
  [ "$pressed" != true ] || nr_why "settings.json says startPressed true although Start indexing was not pressed"
  [ "${files:-0}" = 0 ] || nr_why "the index holds $files files although Start indexing was not pressed"
  [ -z "$why_pre" ] || nr_why "$why_pre"
  if [ -n "$NR_WHY" ]; then s1_fail S1.19 "$NR_WHY"; return 1; fi
  echo "CHECK S1.19 PASS with the model files whole and the setup walked through without Start indexing, the panel shows \"Not ready yet\" and \"Indexing has not been started\"; the index holds ${files:-0} files and startPressed reads $pressed"
}
check_S1_19() { nr_run s1_check_19; }

# ---- S1.20: Not ready, text 3: Still indexing (0%), then part way, then Ready ----------------------------------

s1_check_20() {
  local rc out exp exp_total i pct b a lo hi known banner done_path name kind n expn idx_n bad thawed=0
  s1_begin S1.20 0 || return $S1_RC
  nr_start_frozen S1.20 || return $S1_RC
  NR_WHY=""
  # 1. frozen right after Start: nothing read, nothing listed
  s1_search "$S1_QUERY" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.20 $rc || return $S1_RC
  pn_dump
  nr_save s1-20-frozen
  nr_shot s1-text3-frozen
  [ "$(s1_rows_n)" = 0 ] || nr_why "the list holds $(s1_rows_n) result rows for \"$S1_QUERY\" while the index helper is frozen"
  nr_has "Still indexing (0%)" || nr_why "panel shows no 'Still indexing (0%)'"
  nr_must_lack "Nothing is indexed yet" "although Start indexing was pressed"
  nr_must_lack "Not ready yet" "(a heading) although Start indexing was pressed"
  # 2. thaw, part way
  out="$(kq "$S1_LD" thaw index 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then nr_why "the index helper could not be thawed: $(s1_last "$out")"; s1_fail S1.20 "$NR_WHY"; return 1; fi
  exp="$(kq "$S1_FX" expect counts filler 2>&1)"
  exp_total="$(printf '%s\n' "$exp" | awk 'NF == 2 && $2 ~ /^[0-9]+$/ { n += $2 } END { print n + 0 }')"
  for ((i = 0; i < 360; i++)); do
    nr_status_counts
    [ "$NR_DONE" -ge 3 ] && break
    sleep 0.5
  done
  if [ "$NR_DONE" -lt 3 ]; then
    nr_why "indexing made no progress within 180 s of the thaw (done $NR_DONE of $NR_KNOWN known), so the part-way panel and Ready cannot be read"
    s1_fail S1.20 "$NR_WHY"
    return 1
  fi
  nr_ensure_panel
  nr_status_counts; b="$NR_DONE"; known="$NR_KNOWN"
  pn_dump
  nr_status_counts; a="$NR_DONE"
  if [ "$a" -ge "$known" ] || [ "$NR_OPEN" = 0 ]; then
    echo "RERUN S1.20 not valid: indexing had finished ($a of $known done) before the panel was read part way: a larger filler (NR_FILLER_ROWS) is needed"
    return 4
  fi
  nr_save s1-20-part-way
  nr_shot s1-text3-part-way
  [ "$known" = "$exp_total" ] || nr_why "files known differs: the index reports $known, kit-fixtures.sh expect counts filler totals $exp_total"
  pct="$(nr_pct)"
  if [ -z "$pct" ]; then
    nr_why "panel shows no 'Still indexing (N%)' with indexing part way (done $b to $a of $known)"
  else
    lo="$b"; hi="$a"; [ "$lo" -le "$hi" ] || { lo="$a"; hi="$b"; }
    if [ "$(awk -v p="$pct" -v lo="$lo" -v hi="$hi" -v k="$known" 'BEGIN { print (p >= lo * 100 / k - 1 && p <= hi * 100 / k + 1) ? 1 : 0 }')" != 1 ]; then
      nr_why "the panel says Still indexing ($pct%) but $lo to $hi of $known files are done ($(awk -v lo="$lo" -v hi="$hi" -v k="$known" 'BEGIN { printf "%.1f to %.1f", lo * 100 / k, hi * 100 / k }')%)"
    fi
  fi
  banner="$(printf '%s\n' "$PN_DUMP" | pn_elements | awk -F'\t' '{ t = ($3 != "" ? $3 : $4) } tolower(t) ~ /may be missing/ { print t; exit }')"
  if [ -z "$banner" ]; then
    nr_why "panel shows no banner naming the kinds that may be missing"
  else
    case "$(printf '%s' "$banner" | tr 'A-Z' 'a-z')" in *photo*) ;; *) nr_why "the banner does not name photos, the kind with unread rows" ;; esac
  fi
  nr_must_lack "Nothing is indexed yet" "while indexing runs"
  done_path="$(kq "$KIT_SCRIPTS/kit-index.sh" under filler 2>&1 | awk -F'\t' '$3 == "done" { print $1; exit }')"
  if [ -z "$done_path" ]; then
    nr_why "the index lists no done file under filler to search for"
  else
    name="${done_path##*/}"
    s1_search "$name" --keep-open; rc=$?
    s1_show
    if [ $rc != 0 ]; then
      nr_why "searching for the already read file $name failed: $(s1_last "$S1_OUT")"
    elif ! printf '%s\n' "$S1_OUT" | awk -v b="$name" '$1 == "row" && index($0, b) { f = 1 } END { exit f ? 0 : 1 }'; then
      nr_why "the file already read ($name) is not listed while indexing runs"
    fi
  fi
  # 3. Ready: the counts of the index equal the fixture's, kind by kind
  out="$(kq "$KIT_SCRIPTS/kit-index.sh" wait done 900 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then
    nr_why "indexing did not finish within 900 s: $(s1_last "$out")"
  else
    nr_status_counts
    bad=""
    while read -r kind n; do
      [ -n "$kind" ] || continue
      case "$kind" in COUNTS|FILLER|BUILT) continue ;; esac
      [ "$n" -ge 0 ] 2>/dev/null || continue
      idx_n="$(printf '%s\n' "$NR_KINDS" | awk -v k="$kind" '$1 == k { print $2; exit }')"
      [ "${idx_n:-0}" = "$n" ] || bad="${bad:+$bad, }$kind: index ${idx_n:-0}, folder $n"
    done < <(printf '%s\n' "$exp" | awk 'NF == 2 && $2 ~ /^[0-9]+$/')
    for kind in $(printf '%s\n' "$NR_KINDS" | awk '{ print $1 }'); do
      printf '%s\n' "$exp" | awk -v k="$kind" '$1 == k { f = 1 } END { exit f ? 0 : 1 }' || bad="${bad:+$bad, }$kind is in the index but not in the folder"
    done
    [ -z "$bad" ] || nr_why "after Ready the per-kind counts differ from kit-fixtures.sh expect counts filler ($bad)"
    [ "$NR_KNOWN" = "$exp_total" ] || nr_why "after Ready the index holds $NR_KNOWN files, the folder holds $exp_total"
  fi
  if [ -n "$NR_WHY" ]; then s1_fail S1.20 "$NR_WHY"; return 1; fi
  echo "CHECK S1.20 PASS with Start indexing pressed on $exp_total filler files and the index helper frozen, the panel showed Still indexing (0%) with no rows, no 'Not ready yet' and no 'Nothing is indexed yet'; after the thaw it showed Still indexing ($pct%) with $lo to $hi of $known done, the banner \"$banner\" and the file already read listed; after Ready the per-kind counts equal the folder's"
}
check_S1_20() { nr_run s1_check_20; }

# ---- S1.21 (a): Not ready, text 4: nothing is indexed yet, by an empty folder -------------------------------------

s1_check_21() {
  local rc files
  s1_begin S1.21 0 || return $S1_RC
  nr_fresh_cache || { nr_state_rc S1.21 "$NR_RC" "(a) $NR_MSG"; return $S1_RC; }
  nr_do S1.21 "(a) the setup window cannot be driven" wait_setup_window 8 || return $S1_RC
  nr_do S1.21 "(a) the empty folder cannot be made" kq "$S1_FX" build empty || return $S1_RC
  nr_do S1.21 "(a) the empty folder cannot be picked" pick_folders empty || return $S1_RC
  nr_do S1.21 "(a) Start indexing cannot be pressed" press_start || return $S1_RC
  nr_do S1.21 "(a) indexing did not finish on the empty folder" kq "$KIT_SCRIPTS/kit-index.sh" wait done 120 || return $S1_RC
  nr_read_panel 10 "Not ready yet" "Nothing is indexed yet"; rc=$?
  nr_panel_rc S1.21 $rc || return $S1_RC
  nr_save s1-21-panel
  nr_shot s1-text4
  NR_WHY=""
  nr_need_heading
  nr_need_text "Nothing is indexed yet"
  nr_must_lack "Still indexing" "after indexing finished on an empty folder"
  files="$(nr_files_n)"
  [ "${files:-0}" = 0 ] || nr_why "the index holds $files files after an empty folder"
  if [ -n "$NR_WHY" ]; then
    echo "S1.21 (a) fixtures/empty: $NR_WHY"
    s1_fail S1.21 "(a) $NR_WHY"
    return 1
  fi
  echo "S1.21 (a) fixtures/empty: the panel shows Not ready yet and Nothing is indexed yet, not Still indexing; the index holds ${files:-0} files"
  # (b) [slice 2] Delete index in Settings, confirmed, as a person does it (checks-s1c.sh)
  NR_WHY=""
  s1c_delete_flow S1.21 "(b)" || return $S1_RC
  if [ -n "$NR_WHY" ]; then
    echo "S1.21 (b) Delete index: $NR_WHY"
    s1_fail S1.21 "(b) $NR_WHY"
    return 1
  fi
  echo "CHECK S1.21 PASS (a) an empty folder was picked, Start indexing pressed and indexing finished: the panel shows \"Not ready yet\" and \"Nothing is indexed yet\" and no \"Still indexing\"; (b) after Delete index and its confirmation the Sesame folder held no index.sqlite, -wal or -shm within 10 s, startPressed read false, the panel showed \"Not ready yet\" and \"Nothing is indexed yet\" with no text and with a typed text, and a relaunch kept it"
}
check_S1_21() { nr_run s1_check_21; }

# ---- S1.22: the first applicable text wins, (i) and (ii) ---------------------------------------------------------

# nr_sample_indexing <seconds> : reads the open panel once a second while rows are still unread. NR_N counts the
# valid reads; NR_BAD names the first read that showed the wrong text.
NR_N=0
NR_BAD=""
nr_sample_indexing() {
  local end=$((SECONDS + $1)) open0 open1
  NR_N=0; NR_BAD=""
  while [ "$SECONDS" -lt "$end" ]; do
    nr_status_counts; open0="$NR_OPEN"
    [ "$open0" -gt 0 ] || break
    nr_ensure_panel >/dev/null 2>&1
    nr_status_counts; open1="$NR_OPEN"
    if [ "$open1" -gt 0 ]; then
      NR_N=$((NR_N + 1))
      if nr_has "Nothing is indexed yet"; then NR_BAD="${NR_BAD:-read $NR_N: the panel showed 'Nothing is indexed yet' with $open1 files unread}"; fi
      nr_has "Still indexing" || NR_BAD="${NR_BAD:-read $NR_N: the panel did not show 'Still indexing' with $open1 files unread}"
    fi
    sleep 1
  done
}

s1_check_22() {
  local rc whyi="" whyii="" whyiii="" whyiv="" all="" out
  s1_begin S1.22 0 || return $S1_RC
  # (i) fresh start, model not whole, Start never pressed: text 1, not text 2
  nr_fresh_throttled || { nr_state_rc S1.22 "$NR_RC" "(i) $NR_MSG"; return $S1_RC; }
  nr_read_panel 8 "The model is still downloading"; rc=$?
  nr_panel_rc S1.22 $rc || return $S1_RC
  nr_save s1-22-i-panel
  nr_shot s1-22-i
  NR_WHY=""
  nr_need_text "The model is still downloading"
  nr_need_heading
  nr_must_lack "Indexing has not been started" "while the model is not whole and Start indexing was never pressed (text 1 must win over text 2)"
  whyi="$NR_WHY"
  if [ -n "$whyi" ]; then echo "S1.22 (i): $whyi"; else echo "S1.22 (i): the panel shows text 1 (The model is still downloading) and not text 2"; fi
  # (ii) Start pressed, indexing running with rows unread: text 3, never text 4
  NR_DEFER=1; NR_FAILRC=0; NR_FAILMSG=""
  nr_start_frozen S1.22; rc=$?
  NR_DEFER=""
  if [ $rc != 0 ]; then
    # a person-step or a rerun ends the check; a failure of the state joins the reason of (i)
    case "$NR_FAILRC" in
      3) echo "CHECK S1.22 NEEDS-A-PERSON $NR_FAILMSG"; return 0 ;;
      4) echo "RERUN S1.22 not valid: $NR_FAILMSG"; return 4 ;;
    esac
    NR_WHY="$NR_FAILMSG"
    NR_N=0
  elif ! nr_ensure_panel; then
    NR_WHY="no panel to read: ${PN_OUT:-the shortcut opened none}"
  else
    nr_save s1-22-ii-frozen
    nr_shot s1-22-ii
    NR_WHY=""
    nr_need_text "Still indexing"
    nr_must_lack "Nothing is indexed yet" "with Start indexing pressed and nothing read yet (text 3 must win over text 4)"
    out="$(kq "$S1_LD" thaw index 2>&1)"; rc=$?
    if [ $rc != 0 ]; then nr_why "the index helper could not be thawed: $(s1_last "$out")"; fi
    nr_sample_indexing 25
    [ -z "$NR_BAD" ] || nr_why "$NR_BAD"
    if [ "$NR_N" -lt 3 ] && [ -z "$NR_WHY" ]; then
      echo "RERUN S1.22 not valid: only $NR_N reads were taken while rows were unread (indexing finished or never progressed): rerun"
      return 4
    fi
  fi
  whyii="$NR_WHY"
  if [ -n "$whyii" ]; then echo "S1.22 (ii): $whyii"; else echo "S1.22 (ii): $NR_N reads while rows were unread, each showed Still indexing and none showed Nothing is indexed yet"; fi
  # (iii) [slice 2] paused part way, a damaged model planted: text 1 wins over text 3, text 3 returns after the re-download
  s1c_22_iii || return $S1_RC
  whyiii="$NR_WHY"
  if [ -n "$whyiii" ]; then echo "S1.22 (iii): $whyiii"; else echo "S1.22 (iii): indexing paused part way, the damaged model planted: the panel showed text 1 and not text 3, and text 3 again after the re-download"; fi
  # (iv) [slice 2] Delete index with the model whole: text 4, not text 2
  s1c_22_iv || return $S1_RC
  whyiv="$NR_WHY"
  if [ -n "$whyiv" ]; then echo "S1.22 (iv): $whyiv"; else echo "S1.22 (iv): after Delete index with the model whole the panel shows text 4 and not text 2"; fi
  [ -z "$whyi" ] || all="(i) $whyi"
  [ -z "$whyii" ] || all="${all:+$all; }(ii) $whyii"
  [ -z "$whyiii" ] || all="${all:+$all; }(iii) $whyiii"
  [ -z "$whyiv" ] || all="${all:+$all; }(iv) $whyiv"
  if [ -n "$all" ]; then
    s1_fail S1.22 "$all"
    return 1
  fi
  echo "CHECK S1.22 PASS (i) with the model not whole and Start never pressed the panel shows text 1, not text 2; (ii) with Start pressed and rows unread (frozen at 0 files, then $NR_N reads while it ran) it shows Still indexing and never Nothing is indexed yet; (iii) with indexing paused part way and a damaged model planted the panel shows text 1 and not text 3, and text 3 again after the re-download; (iv) after Delete index with the model whole it shows text 4, not text 2"
}
check_S1_22() { nr_run s1_check_22; }

# ---- S1.23: a description nothing matches shows No matches ------------------------------------------------------

s1_check_23() {
  local rc q n why="" lc
  s1_begin S1.23 1 || return $S1_RC
  s1_search "qwv" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.23 $rc || return $S1_RC
  pn_dump
  nr_save s1-23-one-token
  n="$(s1_rows_n)"
  [ "${n:-0}" -ge 1 ] 2>/dev/null || why="the one-token search \"qwv\" lists no file (the closest files by meaning are expected)"
  nr_has "No matches" && why="${why:+$why; }\"qwv\" shows No matches"
  nr_has_ci "error" && why="${why:+$why; }\"qwv\" shows an error"
  for q in "qwv zzkx" "qwv zzkx lorp" "qwv zzkx lorp mnb"; do
    s1_search "$q" --keep-open; rc=$?
    s1_show
    s1_search_ok S1.23 $rc || return $S1_RC
    pn_dump
    nr_save "s1-23-$(printf '%s' "$q" | wc -w | tr -d ' ')-tokens"
    n="$(s1_rows_n)"
    [ "${n:-0}" = 0 ] || why="${why:+$why; }\"$q\" lists $n rows instead of No matches"
    nr_has "No matches" || why="${why:+$why; }\"$q\" shows no 'No matches'"
    nr_has_ci "describe what is in the file" || why="${why:+$why; }the hint for \"$q\" does not say to describe what is in the file"
    nr_has_ci "type part of its exact name or text" || why="${why:+$why; }the hint for \"$q\" does not say to type part of its exact name or text"
  done
  s1_search "INV-2026-99999" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.23 $rc || return $S1_RC
  pn_dump
  n="$(s1_rows_n)"
  [ "${n:-0}" -ge 1 ] 2>/dev/null || why="${why:+$why; }the hyphenated id INV-2026-99999 (one token) lists no file"
  nr_has "No matches" && why="${why:+$why; }the hyphenated id INV-2026-99999 (one token) shows No matches"
  if [ -n "$why" ]; then s1_fail S1.23 "$why"; return 1; fi
  echo "CHECK S1.23 PASS one token (qwv, INV-2026-99999) lists the closest files; two, three and four tokens each show \"No matches\" with the hint to describe what is in the file or type part of its exact name or text (the rule is the controller's ruling Q2, to be confirmed by the person, S1.N6)"
}
check_S1_23() { nr_run s1_check_23; }

# ---- S1.24: before any text, only a quiet hint and a few samples --------------------------------------------------

# nr_group_texts <group label> : the static texts inside the AXGroup with that label (last dump), one per line.
# The hint is the AXGroup "Search hint" (EmptyHintPanel: its text, then its sample searches); the picture of the
# last result is the AXGroup "Preview". Measured on the dumps of the t36-39 batch (.ril/evidence/S1/t3639a and
# t3639b, ax-s1-24-empty-box.txt): pn_pane also holds the image labels "Search" and "Preview picture", both group
# labels, and every line of a stale preview, so counting pane lines gave 7 and 11 for the 3 real samples.
nr_group_texts() {
  printf '%s\n' "$PN_DUMP" | pn_elements | awk -F'\t' -v g="$1" '
    { d = $1 + 0; r = $2; sub(/\/.*/, "", r) }
    ingrp && d <= gd { ingrp = 0 }
    !ingrp && r == "AXGroup" && $3 == g { ingrp = 1; gd = d; next }
    ingrp && r == "AXStaticText" { t = ($3 != "" ? $3 : $4); if (t != "") print t }'
}

# nr_hint_why <label> : the reasons the last dump (PN_DUMP, taken by the caller) does not meet S1.24 (empty when it
# does), after two `extra:` lines (the pane lines, and the number of sample searches counted).
nr_hint_why() {
  local lines hint samples n rows why="" grp stale got
  lines="$(pn_pane)"
  grp="$(nr_group_texts "Search hint")"
  hint="$(printf '%s\n' "$grp" | awk 'tolower($0) ~ /describe|type part/ { print; exit }')"
  samples="$(printf '%s\n' "$grp" | awk -v h="$hint" 'NF && $0 != h { print }')"
  n="$(printf '%s\n' "$samples" | awk 'NF { k++ } END { print k + 0 }')"
  rows="$(nr_rows_n)"
  stale="$(nr_group_texts "Preview" | sed -n 1p)"
  echo "extra: pane lines with $1: $(printf '%s' "$lines" | tr '\n' '|')"
  echo "extra: sample searches counted with $1 (the static texts of the Search hint group after its hint): $n"
  [ -n "$hint" ] || why="the panel shows no hint text with $1 (in the Search hint group)"
  if [ "$n" -lt 2 ] || [ "$n" -gt 5 ]; then why="${why:+$why; }the pane shows $n sample searches with $1, not 2 to 5"; fi
  got="$(printf '%s\n' "$samples" | awk 'NF' | paste -sd'|' -)"
  [ "$got" = "$NR_SAMPLES" ] || why="${why:+$why; }the sample searches with $1 are \"$got\", not \"$NR_SAMPLES\""
  [ -z "$stale" ] || why="${why:+$why; }the preview pane still shows \"$stale\" with $1 (a stale preview)"
  [ "$rows" = 0 ] || why="${why:+$why; }$rows result rows are listed with $1"
  if nr_has "No matches"; then why="${why:+$why; }the panel says No matches with $1"; fi
  printf '%s' "$why"
}

s1_check_24() {
  local why="" w
  s1_begin S1.24 1 || return $S1_RC
  s1_open S1.24 || return $S1_RC
  pn_dump
  w="$(nr_hint_why "an empty box")"
  printf '%s\n' "$w" | sed -n '/^extra:/p'
  w="$(printf '%s\n' "$w" | sed '/^extra:/d')"
  [ -z "$w" ] || why="$w"
  nr_save s1-24-empty-box
  if [ -z "$(pn_searchbox)" ]; then
    s1_fail S1.24 "${why:+$why; }no search box: five spaces cannot be typed"
    return 1
  fi
  if ! pn_wait_sesame_front 3; then
    s1_fail S1.24 "${why:+$why; }Sesame is not frontmost after the shortcut ($PN_OUT): five spaces were not typed"
    return 1
  fi
  pn_ax type "     " >/dev/null 2>&1 || { s1_fail S1.24 "${why:+$why; }typing five spaces was refused"; return 1; }
  sleep 1
  pn_dump
  w="$(nr_hint_why "five spaces")"
  printf '%s\n' "$w" | sed -n '/^extra:/p'
  w="$(printf '%s\n' "$w" | sed '/^extra:/d')"
  [ -z "$w" ] || why="${why:+$why; }$w"
  nr_save s1-24-five-spaces
  if [ -n "$why" ]; then s1_fail S1.24 "$why"; return 1; fi
  echo "CHECK S1.24 PASS with an empty box and with five spaces the panel shows a quiet hint and the three sample searches (a dog on the beach, the clause about pets in the lease, where they talk about sleep), with no result rows and no \"No matches\""
}
check_S1_24() { nr_run s1_check_24; }

# ---- S1.26: text longer than 500 characters is cut to its first 500 ------------------------------------------------

# nr_text700 : 700 characters, the 500th of which is a letter (so a trimmed end cannot hide a cut at 501).
nr_text700() {
  local u="dogs on the beach " s=""
  while [ "${#s}" -lt 700 ]; do s="$s$u"; done
  printf '%s' "${s:0:700}"
}

# nr_box_checks <how> <first 500> <expected first file> : the box value and the first result after typing or pasting.
nr_box_checks() {
  local how="$1" first500="$2" want="$3" box val got
  pn_wait_list 15
  pn_dump
  box="$(pn_searchbox)"
  val="$(printf '%s' "$box" | cut -f2)"
  if [ "${#val}" != 500 ]; then nr_why "after $how 700 characters the box holds ${#val} characters, not 500"
  elif [ "$val" != "$first500" ]; then nr_why "after $how 700 characters the box holds 500 characters that are not the first 500 of the text"; fi
  got="$(pn_row_name "$(pn_rows | awk -F'\t' 'NR == 1 { print $3 }')")"
  [ "$got" = "$want" ] || nr_why "after $how the first result is \"${got:-none}\", not \"$want\" (the first result of kit-search.sh for the 500-character text)"
}

s1_check_26() {
  local t700 first500 rc want
  s1_begin S1.26 1 || return $S1_RC
  t700="$(nr_text700)"
  first500="${t700:0:500}"
  s1_search "$first500"; rc=$?
  s1_search_ok S1.26 $rc || return $S1_RC
  want="$(s1_name_of_row 1)"
  NR_WHY=""
  [ -n "$want" ] || nr_why "kit-search.sh with the 500-character text lists no file to compare with"
  # typed
  s1_open S1.26 || return $S1_RC
  pn_wait_sesame_front 3 || { s1_fail S1.26 "Sesame is not frontmost after the shortcut ($PN_OUT): nothing was typed"; return 1; }
  pn_dump
  [ -n "$(pn_searchbox)" ] || { s1_fail S1.26 "no search box: 700 characters cannot be typed"; return 1; }
  pn_ax type "$t700" >/dev/null 2>&1 || { s1_fail S1.26 "typing 700 characters was refused"; return 1; }
  nr_box_checks "typing" "$first500" "$want"
  nr_save s1-26-typed
  # pasted
  s1_open S1.26 || return $S1_RC
  pn_wait_sesame_front 3 || { s1_fail S1.26 "Sesame is not frontmost after the second open ($PN_OUT): nothing was pasted"; return 1; }
  pn_ax paste "$t700" >/dev/null 2>&1 || { s1_fail S1.26 "pasting 700 characters was refused"; return 1; }
  nr_box_checks "pasting" "$first500" "$want"
  nr_save s1-26-pasted
  if [ -n "$NR_WHY" ]; then s1_fail S1.26 "$NR_WHY"; return 1; fi
  echo "CHECK S1.26 PASS 700 characters typed and, separately, pasted: the box holds exactly the first 500 and the first result is $want, as for the 500-character text"
}
check_S1_26() { nr_run s1_check_26; }

# ---- Settings: opened with Command+comma, once the shortcut has brought Sesame to the front -----------------------

# nr_settings_search : Settings opens on Folders; the shortcut control is in the Search section. Status 1 with PN_OUT set when it does not open.
nr_settings_search() {
  local why
  why="$(settings_section Search)" && return 0
  PN_OUT="Settings is open but its Search section is not: $why"
  return 1
}

# nr_settings_open : status 0 once a Settings window is on screen and Sesame is frontmost. Else PN_OUT says why:
# status 1 a refusal or no window, 3 a person-step. The panel is opened with the shortcut (inside the kit window),
# Command+comma is posted only while Sesame is frontmost.
nr_settings_open() {
  local i rc
  if pn_probe Sesame dump settings >/dev/null 2>&1 && [ "$(pn_front)" = Sesame ]; then
    nr_settings_search || return 1
    return 0
  fi
  pn_open_panel; rc=$?
  [ $rc = 0 ] || return $rc
  if ! pn_wait_sesame_front 3; then
    PN_OUT="no Settings window: Sesame is not frontmost after the shortcut ($PN_OUT), so Command+comma cannot be posted"
    return 1
  fi
  pn_ax key "cmd+," >/dev/null 2>&1 || { PN_OUT="no Settings window: Command+comma was refused"; return 1; }
  for ((i = 0; i < 20; i++)); do
    if pn_probe Sesame dump settings >/dev/null 2>&1; then
      sleep 0.5
      nr_settings_search || return 1
      return 0
    fi
    sleep 0.25
  done
  PN_OUT="no Settings window within 5 s of Command+comma"
  return 1
}

# nr_settings_rc <id> <rc of nr_settings_open> : status 0 to go on; else the CHECK line is printed, S1_RC is set, status 1.
nr_settings_rc() {
  case "$2" in
    0) return 0 ;;
    3) echo "CHECK $1 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; S1_RC=0 ;;
    *) s1_fail "$1" "$PN_OUT"; S1_RC=1 ;;
  esac
  return 1
}

nr_set_dump() { NR_SET="$(pn_probe Sesame dump settings)"; }
NR_SET=""

# nr_texts <dump> : every label or value of the dump once, sorted.
nr_texts() { printf '%s\n' "$1" | pn_elements | awk -F'\t' '{ t = ($3 != "" ? $3 : $4); if (t != "") print t }' | sort -u; }

# ---- S1.27: the closed list of shortcuts is refused, the old shortcut stays -------------------------------------

NR_DEFAULT_READ="Control Option Space"
NR_BASE=""

# nr_try_refused <combo> : the recorder is given a shortcut of the closed list; sets NR_WHY. Prints one extra line.
nr_try_refused() {
  local combo="$1" after msg rc w=""
  nr_settings_open; rc=$?
  if [ $rc != 0 ]; then nr_why "$combo: $PN_OUT"; return 1; fi
  if ! pn_ax click "Record new shortcut" >/dev/null 2>&1; then nr_why "$combo: Settings has no 'Record new shortcut' control"; return 1; fi
  sleep 0.5
  pn_ax key "$combo" >/dev/null 2>&1 || { nr_why "$combo: the key post was refused (Sesame is not frontmost)"; return 1; }
  sleep 1
  nr_set_dump; after="$(nr_texts "$NR_SET")"
  # the message is any text that was not in Settings before the first recorder press (a message left by the
  # combination before this one counts, so it is not mistaken for a missing one)
  msg="$(comm -13 <(printf '%s\n' "$NR_BASE") <(printf '%s\n' "$after") | tr '\n' '|')"
  [ -n "$msg" ] || w="no message appeared in the control's status area"
  case "$NR_SET" in *"$NR_DEFAULT_READ"*) ;; *) w="${w:+$w, }the control no longer reads \"$NR_DEFAULT_READ\"" ;; esac
  # the default shortcut still opens the panel
  pn_open_panel; rc=$?
  if [ $rc != 0 ]; then w="${w:+$w, }the default shortcut no longer opens the panel ($PN_OUT)"; else pn_close_panel >/dev/null 2>&1; fi
  # the refused combination opens nothing (posted into the kit's own window, never into another app)
  pn_hotkey "$combo" >/dev/null 2>&1
  sleep 1.5
  if pn_panel_exists; then w="${w:+$w, }the refused combination $combo opened the panel"; pn_close_panel >/dev/null 2>&1; fi
  pn_kit_close
  echo "S1.27 $combo: new text in the control after the key: ${msg:-none}${w:+; $w}"
  [ -z "$w" ] || nr_why "$combo: $w"
  return 0
}

s1_check_27() {
  local combo rc opened closed old
  s1_begin S1.27 0 || return $S1_RC
  # the macOS-owned combinations are never posted, so what is said of them does not wait for Settings
  for combo in cmd+space cmd+tab cmd+q cmd+h ctrl+cmd+q; do
    case "$combo" in
      cmd+h|ctrl+cmd+q) echo "S1.27 $combo: not deliverable: never posted (it hides the frontmost app or locks the screen); covered by the refusal table in swift test and by a person, S1.N5" ;;
      *) echo "S1.27 $combo: not deliverable: macOS takes it before the recorder sees it and the key tool cannot confirm delivery, so it was not posted; covered by the refusal table in swift test and by a person, S1.N5" ;;
    esac
  done
  nr_fresh_cache || { nr_state_rc S1.27 "$NR_RC" "$NR_MSG"; return $S1_RC; }
  nr_settings_open; rc=$?
  nr_settings_rc S1.27 $rc || return $S1_RC
  nr_set_dump; NR_BASE="$(nr_texts "$NR_SET")"
  NR_WHY=""
  for combo in cmd+w a shift+a; do
    nr_try_refused "$combo" || break
  done
  if [ -z "$NR_WHY" ]; then
    # a combination outside the list is accepted: Option+Command+K
    nr_settings_open; rc=$?
    if [ $rc != 0 ]; then nr_why "alt+cmd+k: $PN_OUT"
    elif ! pn_ax click "Record new shortcut" >/dev/null 2>&1; then nr_why "alt+cmd+k: Settings has no 'Record new shortcut' control"
    else
      sleep 0.5
      pn_ax key "alt+cmd+k" >/dev/null 2>&1 || nr_why "alt+cmd+k: the key post was refused"
      sleep 1
      # The panel is closed with the chord in force (pn_close_panel posts PN_CHORD). It used to post the OLD default,
      # which no longer works once alt+cmd+k is accepted: the panel stayed open and the next read took that
      # still-open panel for "the old default opens it". The old default is posted only once the panel is closed.
      PN_CHORD="alt+cmd+k"
      opened=0; closed=0; old=""
      pn_open_panel; rc=$?
      if [ $rc != 0 ]; then
        nr_why "alt+cmd+k was not accepted: it does not open the panel ($PN_OUT)"
      else
        opened=1
        pn_close_panel >/dev/null 2>&1
        if pn_panel_exists; then
          nr_why "alt+cmd+k opened the panel but did not close it again, so whether the old default still opens the panel cannot be told"
        else
          closed=1
        fi
      fi
      PN_CHORD=""
      if [ "$closed" = 1 ]; then
        pn_hotkey >/dev/null 2>&1
        sleep 1.5
        if pn_panel_exists; then
          old=still
          nr_why "after alt+cmd+k was accepted the old default still opens the panel"
          pn_close_panel >/dev/null 2>&1
        else
          old=no
        fi
      fi
      pn_kit_close
      case "$old" in
        no) echo "S1.27 alt+cmd+k: accepted, opens the panel and closes it; the old default no longer opens it" ;;
        still) echo "S1.27 alt+cmd+k: accepted, opens the panel and closes it; the old default still opens the panel" ;;
        *) echo "S1.27 alt+cmd+k: the old default was not tried (opened $opened, closed again $closed)" ;;
      esac
      # back to the default
      PN_CHORD="alt+cmd+k"
      nr_settings_open; rc=$?
      PN_CHORD=""
      if [ $rc != 0 ]; then nr_why "back to default: $PN_OUT"
      elif ! pn_ax click "Back to default" >/dev/null 2>&1; then nr_why "Settings has no 'Back to default' control"
      else
        sleep 1
        pn_open_panel; rc=$?
        if [ $rc != 0 ]; then nr_why "after Back to default the default shortcut does not open the panel ($PN_OUT)"; else pn_close_panel >/dev/null 2>&1; fi
        echo "S1.27 back to default: the default shortcut opens the panel again"
      fi
    fi
  fi
  if [ -n "$NR_WHY" ]; then s1_fail S1.27 "$NR_WHY"; return 1; fi
  echo "CHECK S1.27 PASS Command+W, a bare key and Shift plus a key were each refused with a message in the control's status area, the old shortcut stayed (it still reads \"$NR_DEFAULT_READ\" and opens the panel) and the refused combination opened nothing; Option+Command+K was accepted and the old default stopped; Back to default restored it; Command+Space, Command+Tab, Command+Q, Command+H and Control+Command+Q are not deliverable (not posted)"
}
check_S1_27() { nr_run s1_check_27; }

# ---- S1.28: the default is Control+Option+Space ----------------------------------------------------------------

s1_check_28() {
  local rc lines
  s1_begin S1.28 0 || return $S1_RC
  nr_fresh_cache || { nr_state_rc S1.28 "$NR_RC" "$NR_MSG"; return $S1_RC; }
  nr_settings_open; rc=$?
  nr_settings_rc S1.28 $rc || return $S1_RC
  nr_set_dump
  PN_DUMP="$NR_SET"
  nr_save s1-28-settings
  echo "note: slice 1 has no setup shortcut step, so only Settings is read (guess G11)"
  case "$NR_SET" in
    *"$NR_DEFAULT_READ"*) ;;
    *)
      lines="$(printf '%s\n' "$NR_SET" | pn_elements | awk -F'\t' '{ t = ($3 != "" ? $3 : $4); if (t != "") print t }' | tr '\n' '|')"
      s1_fail S1.28 "Settings does not read \"$NR_DEFAULT_READ\" on a fresh start (its texts: $lines)"
      return 1 ;;
  esac
  echo "CHECK S1.28 PASS on a fresh start Settings reads \"$NR_DEFAULT_READ\" (slice 1 has no setup shortcut step)"
}
check_S1_28() { nr_run s1_check_28; }

# ---- S1.29: every control is reachable by keyboard -------------------------------------------------------------

# nr_walk <panel|settings> : tab-walk the window, then a Shift+Tab pass. Sets NR_WHY; prints the lines. NR_WALK is the
# list of controls reached forward, one per line ("role "label"").
NR_WALK=""
NR_BLIND=""
nr_walk() {
  local win="$1" out rc fwd n total reached i cur rev miss
  out="$(KIT_NO_EVIDENCE=1 kit_timeout 180 "$PN_AX" tab-walk "$win" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed "s/^/tab-walk $win: /"
  fwd="$(printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ && $2 !~ /^\(/ { sub(/^[0-9]+ /, ""); print }')"
  NR_WALK="$fwd"
  # a menu whose highlight cannot be read (every stop reads "nothing focused") proves nothing either way: not a fail
  if [ "$win" = menu ] && [ -z "$fwd" ] && printf '%s\n' "$out" | grep -q '(nothing focused)'; then
    NR_BLIND=1
    return 0
  fi
  total="$(printf '%s\n' "$out" | sed -n 's/^tab-walk: [0-9]* controls reached by Tab, \([0-9]*\) controls in the window$/\1/p')"
  if [ "$rc" = 124 ]; then nr_why "$win: the tab walk did not end within 180 s"; return 1; fi
  if [ -z "$total" ]; then nr_why "$win: $(s1_last "$out")"; return 1; fi
  [ "$rc" = 0 ] || nr_why "$win: $(printf '%s\n' "$out" | awk '/^not reached:/ { n++ } END { print n + 0 }') of $total controls were not reached by Tab ($(printf '%s\n' "$out" | sed -n 's/^not reached: //p' | tr '\n' ',' | sed 's/,$//'))"
  n="$(printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ { k++ } END { print k + 0 }')"
  [ "$n" -le $((total + 1)) ] || nr_why "$win: focus did not return to the first control after a full cycle ($n stops for $total controls)"
  # a menu is walked with the Down key (kit-ax.sh tab-walk menu): neither Tab nor Shift+Tab moves through it
  [ "$win" = menu ] && return 0
  # Shift+Tab: the same controls, backwards
  rev=""
  for ((i = 0; i < total + 1; i++)); do
    pn_ax key "shift+tab" >/dev/null 2>&1 || { nr_why "$win: Shift+Tab was refused (Sesame is not frontmost)"; break; }
    sleep 0.2
    cur="$(pn_ax read focus 2>&1 | sed 's/^focused //')"
    rev="$rev$cur"$'\n'
  done
  miss=""
  while IFS= read -r cur; do
    [ -n "$cur" ] || continue
    case "$rev" in *"$cur"*) ;; *) miss="${miss:+$miss, }$cur" ;; esac
  done < <(printf '%s\n' "$fwd")
  [ -z "$miss" ] || nr_why "$win: Shift+Tab never reached $miss"
  return 0
}

s1_check_29() {
  local rc el lst lbl lstl
  s1_begin S1.29 1 || return $S1_RC
  s1_open S1.29 || return $S1_RC
  pn_wait_sesame_front 3 || { s1_fail S1.29 "Sesame is not frontmost after the shortcut ($PN_OUT): Tab cannot be posted to the panel"; return 1; }
  pn_dump
  el="$(printf '%s\n' "$PN_DUMP" | pn_elements)"
  lbl="$(pn_searchbox | cut -f1)"
  lstl="$(printf '%s\n' "$el" | awk -F'\t' '{ r = $2; sub(/\/.*/, "", r) } r == "AXList" || r == "AXTable" || r == "AXOutline" { print $3; exit }')"
  echo "extra (not S1.30): panel search field label \"${lbl:-none}\", result list label \"${lstl:-none}\""
  NR_WHY=""
  NR_BLIND=""
  nr_walk panel
  lst="$NR_WALK"
  echo "panel controls reached forward: $(printf '%s' "$lst" | tr '\n' '|')"
  # the first Settings window, opened with Command+comma
  nr_settings_open; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S1.29 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; return 0; fi
  if [ $rc != 0 ]; then
    nr_why "$PN_OUT"
  else
    nr_walk settings
    echo "Settings controls reached forward: $(printf '%s' "$NR_WALK" | tr '\n' '|')"
    # [slice 2] the rest of Settings: every section, one by one
    s1c_29_sections
  fi
  # [slice 2] the status item's menu, then the setup windows (the setup state replaces the app, so it comes last)
  nr_walk menu
  echo "menu items reached: $(printf '%s' "$NR_WALK" | tr '\n' '|')"
  s1c_29_setup || return $S1_RC
  if [ -n "$NR_WHY" ]; then
    [ -z "$NR_BLIND" ] || NR_WHY="$NR_WHY; the menu keyboard part could not be read (needs a person)"
    s1_fail S1.29 "$NR_WHY"
    return 1
  fi
  if [ -n "$NR_BLIND" ]; then
    echo "CHECK S1.29 NEEDS-A-PERSON the highlight of the status item's menu cannot be read through accessibility (every Down stop read nothing selected): press Down in the open menu and see each item take the highlight and the top one again after the last; the panel, every Settings section and the four setup steps passed"
    return 0
  fi
  echo "CHECK S1.29 PASS Tab reached every enabled control of the panel, of every Settings section, of the setup windows (four steps) and, with the Down key, of the status item's menu; focus returned to the first control after a full cycle, and Shift+Tab reached them backwards"
}
check_S1_29() { nr_run s1_check_29; }

# ---- S1.31: the panel follows the system Light and Dark look -------------------------------------------------------

# The search-box row is the top 58 of the panel's 560 points (mockup E1); the reading is taken inside it, clear of the
# separator line below it and of the window's edge.
NR_ROW="0.04 0.015 0.96 0.085"

s1_check_31() {
  local lbin base look out rc png val luma_light="" luma_dark="" now why="" diff blank
  s1_begin S1.31 0 || return $S1_RC
  nr_fresh_cache || { nr_state_rc S1.31 "$NR_RC" "$NR_MSG"; return $S1_RC; }
  lbin="$(kit_tool lumastat)" || { s1_fail S1.31 "the kit's lumastat tool did not compile (see $KIT_ROOT/run/bin/lumastat.log)"; return 1; }
  base="$(cat "$KIT_ROOT/run/appearance" 2>/dev/null)"
  for look in light dark; do
    out="$(pn_ax appearance "$look" --keep 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc = 3 ]; then echo "CHECK S1.31 NEEDS-A-PERSON $(nr_pick_msg "$out")"; return 0; fi
    if [ $rc != 0 ]; then s1_fail S1.31 "the system look could not be set to $look: $(s1_last "$out")"; return 1; fi
    sleep 2
    pn_open_panel; rc=$?
    if [ $rc = 3 ]; then echo "CHECK S1.31 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; return 0; fi
    if [ $rc != 0 ]; then s1_fail S1.31 "no panel to read in the $look look: $PN_OUT"; return 1; fi
    sleep 1
    out="$(pn_ax shot "s1-$look" --panel 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc = 3 ]; then echo "CHECK S1.31 NEEDS-A-PERSON $(nr_pick_msg "$out")"; return 0; fi
    if [ $rc != 0 ]; then
      blank="$(printf '%s\n' "$out" | sed -n 's/^BLANK: //p' | sed -n 1p)"
      if [ -n "$blank" ]; then
        s1_fail S1.31 "the picture of the panel in the $look look is blank ($blank): the panel draws no search row to read"
      else
        s1_fail S1.31 "no picture of the panel in the $look look: $(s1_last "$out")"
      fi
      return 1
    fi
    png="$(printf '%s\n' "$out" | sed -n 's/^saved \(.*\) (Sesame window [0-9]*)$/\1/p' | sed -n 1p)"
    [ -f "$png" ] || { s1_fail S1.31 "the picture of the panel in the $look look was not saved ($out)"; return 1; }
    val="$("$lbin" "$png" $NR_ROW 2>&1)" || { s1_fail S1.31 "the luminance of the search-box row could not be read in the $look look: $val"; return 1; }
    echo "$look: $val ($png)"
    now="$(printf '%s\n' "$val" | awk '{ print $2 }')"
    if [ "$look" = light ]; then luma_light="$now"; else luma_dark="$now"; fi
    pn_close_panel >/dev/null 2>&1
  done
  out="$(pn_ax appearance restore 2>&1)"; printf '%s\n' "$out" | sed 's/^/  | /'
  now="$(pn_ax appearance get 2>&1 | sed -n 1p)"
  [ "$now" = "$base" ] || why="the system look reads $now after the check, not $base as recorded at reset"
  diff="$(awk -v l="$luma_light" -v d="$luma_dark" 'BEGIN { printf "%.1f", l - d }')"
  if [ "$(awk -v l="$luma_light" -v d="$luma_dark" 'BEGIN { print (l - d >= 30) ? 1 : 0 }')" != 1 ]; then
    why="${why:+$why; }the search-box row reads $luma_light in Light and $luma_dark in Dark: the difference is $diff of 255, Dark must be darker by at least 30"
  fi
  if [ -n "$why" ]; then s1_fail S1.31 "$why"; return 1; fi
  echo "CHECK S1.31 PASS the search-box row of the panel reads $luma_light in Light and $luma_dark in Dark (Dark darker by $diff of 255, at least 30 needed); the look is restored to $base; the pictures (shot-s1-light, shot-s1-dark) go to the person"
}
check_S1_31() { nr_run s1_check_31; }

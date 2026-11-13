#!/bin/bash
# The readings of S2 (feature map S2: S2.9 to S2.14) on the real 50,000-row index of the recipe `index50k`. Sourced by kit-run.sh
# after common.sh and recipes.sh, never run. bash 3.2 compatible.
#
# A reading that was taken prints exactly `CHECK <id> NEEDS-A-PERSON reading <figure> bar <bar> on the real 50,000-row index NOTE
# within bar` or `... NOTE over bar`, whatever the figure: it never prints PASS or FAIL and the bar is never lowered, so a
# green verify.sh is possible and its `0 failed` holds. A reading that could not be taken because a product part is
# missing prints `CHECK <id> FAIL no reading: <reason>` (red until the part exists). A run that is not valid (index under 50,000
# rows, no cache, indexer not busy, probe file missing, poll and probe more than 50 ms apart) prints no CHECK line, prints `RERUN <id> not
# valid: <reason>` and returns 4. A person-step that is missing prints `CHECK <id> NEEDS-A-PERSON <reason>`.
#
# The state (recipes.sh: index50k_need, index50k_launch): the cached index restored and the app started on it, nothing indexing. A check
# never builds the cache (hours: kit-run.sh prep index50k does); a missing or stale one is a RERUN that says so. A finished index is idle,
# so every reading that needs a busy indexer puts the 500-file mix on top of a fresh restore (s2_mix_on_top: built, picked in Settings,
# Start indexing pressed, the rows rising) and says which work was being indexed. The results are kept in $KIT_ROOT/s2-run/, so the
# second check of a run does not repeat a launch:
#   prep      index50k_need, then the rows line of kit-index.sh rows is at least 50,000 (S2.9 opens the panel 20 times on it, app idle);
#   launch q  (the prepared state) kit-mem.sh peak (i) around kit-probe.sh searches 20 --set distinct20 (indexing idle); kit-probe.sh
#             opens 20 and searches 20 --set distinct20b (the quiet figures); kit-mem.sh idle 90 (S2.13); kit-probe.sh searches 1
#             --set distinct20 --cold (S2.12, the first search after idle, bar 2 s [guess G35]);
#   launch a  a fresh restore with the mix on top, kit-probe.sh searches 20 --set distinct20 --busy (S2.10);
#   launch m  a fresh restore, kit-mem.sh peak (ii) around the mix added and indexed to done with no search (kit-index.sh wait done 14400,
#             the bar S6.11 allows for the same mix);
#   launch b  a fresh restore with the mix on top, kit-probe.sh opens 20 --busy;
#   launch c  the same, kit-probe.sh searches 20 --set distinct20b --busy with kit-mem.sh peak (iii) around it. S2.11 is one line from b
#             and c, S2.14 one line from the three peaks.
# With KIT_PLANT=1 (kit-run.sh --plant <id>) every bar is planted at 1 (1 ms, 1 byte), so the reading must go over it and
# the check prints `CHECK <id> FAIL planted: <what>`.
#
# Stops. When S2.10's line ends `NOTE over bar` the worker replies STATUS: blocked, RESULT STOP-ASK U18 (the 500 ms bar is not
# lowered); this file prints a STOP-ASK U18 line then. S2.14 above 1.30 GB in any peak is the memory stop of design section 8; this file
# prints a MEMORY STOP line then. Every other NOTE over bar stops nothing.

S2_PROBE="$KIT_SCRIPTS/kit-probe.sh"
S2_MEM="$KIT_SCRIPTS/kit-mem.sh"
S2_LD="$KIT_SCRIPTS/kit-launch.sh"
S2_IDX="$KIT_SCRIPTS/kit-index.sh"
S2_RUN="$KIT_ROOT/s2-run"   # outside run/, which every reset removes; a token holds the pid of the kit-run that owns it
S2_RC=0
S2_BARP=()
S2_BARM=()
S2_WHAT=""

# ---- plumbing ---------------------------------------------------------------------------------------

# s2_begin : the plant, if any. KIT_PLANT=1 plants every bar at its smallest.
s2_begin() {
  S2_RC=0; S2_BARP=(); S2_BARM=(); S2_WHAT=""
  if [ "$(cat "$S2_RUN/token" 2>/dev/null)" != "$$" ]; then
    rm -rf "$S2_RUN"
    mkdir -p "$S2_RUN" 2>/dev/null
    printf '%s\n' "$$" > "$S2_RUN/token"
  fi
  if [ -n "$KIT_PLANT" ]; then
    S2_BARP=(--bar-ms 1); S2_BARM=(--bar-bytes 1)
    S2_WHAT="the bar was planted at 1 (1 ms, 1 byte)"
  fi
}

# s2_last <text> : the last non-empty line.
s2_last() { printf '%s\n' "$1" | awk 'NF { l = $0 } END { print l }'; }

# s2_msg <output> : the line that says why: the first NEEDS A PERSON line (without its label), else a RERUN line (without
# its label), else the last non-empty line.
s2_msg() {
  local p
  p="$(printf '%s\n' "$1" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
  [ -n "$p" ] || p="$(printf '%s\n' "$1" | awk '/^RERUN / { sub(/^RERUN not valid: /, ""); sub(/^RERUN /, ""); print; exit }')"
  if [ -n "$p" ]; then printf '%s' "$p"; else s2_last "$1"; fi
}

# s2_state <id> <rc> <message> : the CHECK or RERUN line for a step that did not give a reading; sets S2_RC.
s2_state() {
  case "$2" in
    3) echo "CHECK $1 NEEDS-A-PERSON $3"; S2_RC=0 ;;
    4) echo "RERUN $1 not valid: $3"; S2_RC=4 ;;
    *)
      if [ -n "$KIT_PLANT" ]; then echo "CHECK $1 FAIL planted: $S2_WHAT: no reading: $3"; else echo "CHECK $1 FAIL no reading: $3"; fi
      S2_RC=1 ;;
  esac
}

# s2_reading <id> <figure> <bar> <WITHIN|OVER> : the one line of a reading that was taken (or, planted, its FAIL line).
s2_reading() {
  local word
  word="$(printf '%s' "$4" | tr 'A-Z' 'a-z')"
  if [ -n "$KIT_PLANT" ]; then
    if [ "$4" = OVER ]; then
      echo "CHECK $1 FAIL planted: $S2_WHAT and the reading went over it ($2)"
    else
      echo "CHECK $1 FAIL planted: $S2_WHAT but the reading stayed within it ($2): the verdict cannot go over"
    fi
    S2_RC=1
    return 1
  fi
  echo "CHECK $1 NEEDS-A-PERSON reading $2 bar $3 on the real 50,000-row index NOTE $word bar"
  S2_RC=0
}

# s2_probe_line <file> <opens|searches> : "<median> <max> <bar> <WITHIN|OVER>" from kit-probe.sh's closing line.
s2_probe_line() {
  awk -v w="$2" '$1 == w && $2 == "median" { print $3, $6, $9, $11; exit }' "$1" 2>/dev/null
}

# s2_step <name> <command...> : one kit command; its output is kept in $S2_RUN/<name>.out, its status in <name>.rc.
s2_step() {
  local name="$1" out rc
  shift
  out="$(KIT_NO_EVIDENCE=1 "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$S2_RUN/$name.out"
  printf '%s\n' "$rc" > "$S2_RUN/$name.rc"
  printf '%s\n' "$out" | sed "s/^/  | $name: /"
  return $rc
}

s2_rc_of() { sed -n 1p "$S2_RUN/$1.rc" 2>/dev/null; }

# s2_taken <step name> <opens|searches> <id> : status 0 with P_MED P_MAX P_BAR P_VERDICT set when the step took a reading;
# else the CHECK or RERUN line is printed, S2_RC is set and the status is 1.
P_MED=""; P_MAX=""; P_BAR=""; P_VERDICT=""
s2_taken() {
  local rc line out
  rc="$(s2_rc_of "$1")"
  if [ -z "$rc" ]; then s2_state "$3" 4 "step $1 did not run"; return 1; fi
  out="$(cat "$S2_RUN/$1.out")"
  line="$(s2_probe_line "$S2_RUN/$1.out" "$2")"
  if [ -n "$line" ]; then set -- $line; P_MED="$1"; P_MAX="$2"; P_BAR="$3"; P_VERDICT="$4"; return 0; fi
  s2_state "$3" "$rc" "$(s2_msg "$out")"
  return 1
}

# ---- the state, once per run ---------------------------------------------------------------------------

# s2_prep : index50k_need (the cached index restored, the app on it) and the rows line at least 50,000. A failure is kept in $S2_RUN/prep.rc and
# prep.msg for the rest of the run; a success is asked again by every check (cheap when the state still holds, a fresh restore when a busy
# launch has replaced it).
s2_prep() {
  local out rc n rows msg
  if [ -f "$S2_RUN/prep.rc" ] && [ "$(s2_rc_of prep)" != 0 ]; then return 0; fi
  out="$(index50k_need 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe index50k: /'
  msg="$(s2_msg "$out")"
  if [ $rc = 0 ]; then
    rows="$(KIT_NO_EVIDENCE=1 "$S2_IDX" rows 2>&1)"
    n="$(printf '%s\n' "$rows" | awk '$1 == "rows" { print $2; exit }')"
    case "$n" in
      ""|*[!0-9]*) rc=4; msg="the rows line of kit-index.sh rows is unreadable: $(s2_last "$rows")" ;;
      *)
        echo "  | the index holds $n rows before the run"
        if [ "$n" -lt 50000 ]; then rc=4; msg="the index holds $n rows, fewer than 50,000: the readings are not valid on it"; fi ;;
    esac
  fi
  case "$msg" in
    *"no cache"*|*stale*) [ $rc = 0 ] || msg="$msg (the 50,000-row index is made by scripts/kit-run.sh prep index50k, which takes hours, never inside a check)" ;;
  esac
  printf '%s\n' "$rc" > "$S2_RUN/prep.rc"
  printf '%s\n' "$msg" > "$S2_RUN/prep.msg"
  return 0
}

# s2_need_prep <id> [--state] : status 0 when the state is ready; else the line for this id is printed and the status is 1. Once the quiet launch
# has run, a check that reads only the busy launches (each restores its own index) asks nothing again; S2.9, which reads the plain state, always asks.
s2_need_prep() {
  local rc
  if [ "${2:-}" != --state ] && [ -f "$S2_RUN/q.done" ] && [ "$(s2_rc_of prep)" = 0 ]; then return 0; fi
  s2_prep
  rc="$(s2_rc_of prep)"
  [ "$rc" = 0 ] && return 0
  s2_state "$1" "$rc" "$(cat "$S2_RUN/prep.msg")"
  return 1
}

# s2_launch_ok <id> <launch> : status 0 when that launch was made (or has not been tried); else the line for this id is printed and the status is 1.
s2_launch_ok() {
  local rc
  rc="$(s2_rc_of "$2-launch")"
  if [ -n "$rc" ] && [ "$rc" != 0 ]; then s2_state "$1" "$rc" "launch $2: $(cat "$S2_RUN/$2-launch.msg")"; return 1; fi
  return 0
}

# s2_launched <launch> <status> <output> : the launch's output, status and reason kept.
s2_launched() {
  printf '%s\n' "$3" | sed "s/^/launch $1: /"
  printf '%s\n' "$2" > "$S2_RUN/$1-launch.rc"
  s2_msg "$3" > "$S2_RUN/$1-launch.msg"
}

# s2_unread : the number of files the index holds that are pending or partial (kit-index.sh status), 0 when it is all read.
s2_unread() { KIT_NO_EVIDENCE=1 "$S2_IDX" status 2>/dev/null | awk 'NF == 3 && ($2 == "pending" || $2 == "partial") && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }'; }

# s2_mix_on_top : the 500-file mix (plan 5) added on top of the restored 50,000-row index, as a person adds a folder: built, picked in Settings,
# Start indexing pressed, the rows rising. The recipe `mix500` resets the state, so it cannot be run on top of the index; it is the same
# folder and the same picker. The recipe mark is dropped (the state is no longer the plain index50k) and the work is noted in $S2_RUN/mix.note
# (the hand count of kit-fixtures.sh expect listing mix500). Status 0 when indexing of the mix is running; else one line says why.
s2_mix_on_top() {
  local out rc n
  out="$(KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-fixtures.sh" build mix500 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "kit-fixtures.sh build mix500 exited $rc: $(s2_last "$out")"; return 1; }
  rm -f "$KIT_ROOT/run/recipe"
  out="$(KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-fixtures.sh" expect listing mix500 2>&1)"
  n="$(printf '%s\n' "$out" | awk '/^LISTING OK/ { for (i = 1; i <= NF; i++) if ($i == "paths") print $(i - 1) }')"
  if [ -n "$n" ]; then printf 'mix500 (%s files)\n' "$n" > "$S2_RUN/mix.note"; else printf 'mix500 (file count not read)\n' > "$S2_RUN/mix.note"; fi
  out="$(s8c_settings_open 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "the Settings window cannot be opened, so the mix cannot be added: $(s2_last "$out")"; return $rc; }
  PK_WINDOW=settings drive_picker "$KIT_ROOT/fixtures/mix500" || { echo "the picker could not add the mix: $PICKER_WHY"; return 3; }
  settings_section Indexing >/dev/null 2>&1 || { echo "the Settings window cannot be put on its Indexing section"; return 1; }
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" click "Start indexing" >/dev/null 2>&1 || { echo "pressing Start indexing in Settings failed"; return 1; }
  out="$(KIT_NO_EVIDENCE=1 "$S2_IDX" wait rising 60 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "the rows did not rise after the mix was added (kit-index.sh wait rising 60 exited $rc)"; return 4; }
  return 0
}

# s2_mix_note : the work that was being indexed, "mix500 (<n> files)".
s2_mix_note() { cat "$S2_RUN/mix.note" 2>/dev/null || echo "an unknown mix"; }

# s2_still_indexing <launch b|c> : status 0 when unread rows stood before the first and after the last measurement of that launch and the menu bar
# said Indexing after it; else one line says which did not hold (a mix that was already read proves nothing about reading while it runs).
s2_still_indexing() {
  local l="$1" before after
  before="$(cat "$S2_RUN/$l-unread-before" 2>/dev/null)"; after="$(cat "$S2_RUN/$l-unread-after" 2>/dev/null)"
  if [ "${before:-0}" -le 0 ] 2>/dev/null; then echo "launch $l: kit-index.sh status shows no unread rows before the first measurement, so nothing was indexing"; return 1; fi
  if [ "${after:-0}" -le 0 ] 2>/dev/null; then echo "launch $l: kit-index.sh status shows no unread rows after the last measurement: indexing of the mix ended before the readings did"; return 1; fi
  case "$(tr 'A-Z' 'a-z' < "$S2_RUN/$l-menu-after" 2>/dev/null)" in
    *indexing*) return 0 ;;
  esac
  echo "launch $l: the menu bar did not say Indexing after the last measurement"
  return 1
}

# ---- the launches, once per run ------------------------------------------------------------------------

# s2_launch_q : the prepared state, nothing busy: peak (i) around 20 distinct searches, the quiet figures, the idle memory, the cold search.
s2_launch_q() {
  [ -f "$S2_RUN/q.done" ] && return 0
  s2_step peak-i-start "$S2_MEM" peak start
  s2_step quiet20 "$S2_PROBE" searches 20 --set distinct20 "${S2_BARP[@]}"
  s2_step peak-i "$S2_MEM" peak stop "${S2_BARM[@]}"
  s2_step quiet-opens "$S2_PROBE" opens 20 "${S2_BARP[@]}"
  s2_step quiet "$S2_PROBE" searches 20 --set distinct20b "${S2_BARP[@]}"
  s2_step s13 "$S2_MEM" idle 90 "${S2_BARM[@]}"
  s2_step s12 "$S2_PROBE" searches 1 --set distinct20 --cold "${S2_BARP[@]}"
  : > "$S2_RUN/q.done"
}

# s2_launch_a : a fresh restore, the mix on top, then S2.10's 20 warm searches with the indexer busy.
s2_launch_a() {
  local out rc
  [ -f "$S2_RUN/a.done" ] && return 0
  s2_step a-stop "$S2_LD" stop
  out="$(index50k_launch 2>&1)"; rc=$?
  if [ $rc = 0 ]; then out="$out"$'\n'"$(s2_mix_on_top 2>&1)"; rc=$?; fi
  s2_launched a "$rc" "$out"
  [ $rc = 0 ] && s2_step s10 "$S2_PROBE" searches 20 --set distinct20 --busy "${S2_BARP[@]}"
  : > "$S2_RUN/a.done"
}

# s2_launch_m : a fresh restore, then peak (ii): the mix added and indexed to done with no search. The sampler is always stopped.
s2_launch_m() {
  local out rc
  [ -f "$S2_RUN/m.done" ] && return 0
  s2_step m-stop "$S2_LD" stop
  out="$(index50k_launch 2>&1)"; rc=$?
  if [ $rc = 0 ]; then
    s2_step peak-ii-start "$S2_MEM" peak start
    out="$out"$'\n'"$(s2_mix_on_top 2>&1)"; rc=$?
    if [ $rc = 0 ]; then
      s2_step m-done "$S2_IDX" wait done 14400 || { out="$out"$'\n'"indexing of the mix was not done within 14400 s (kit-index.sh wait done said: $(s2_last "$(cat "$S2_RUN/m-done.out")"))"; rc=4; }
    fi
    s2_step peak-ii "$S2_MEM" peak stop "${S2_BARM[@]}"
  fi
  s2_launched m "$rc" "$out"
  : > "$S2_RUN/m.done"
}

# s2_launch_bc : launches B and C, once per run: a fresh restore each, the mix added on top (indexing must still be running before the
# first reading and after the last one: S2.11), then one busy run; peak (iii) is taken around launch C's searches.
s2_launch_bc() {
  local out rc l
  [ -f "$S2_RUN/bc.done" ] && return 0
  for l in b c; do
    s2_step "$l-stop" "$S2_LD" stop
    out="$(index50k_launch 2>&1)"; rc=$?
    if [ $rc = 0 ]; then
      out="$out"$'\n'"$(s2_mix_on_top 2>&1)"; rc=$?
    fi
    s2_launched "$l" "$rc" "$out"
    if [ $rc != 0 ]; then continue; fi
    s2_unread > "$S2_RUN/$l-unread-before"
    if [ "$l" = b ]; then
      s2_step b "$S2_PROBE" opens 20 --busy "${S2_BARP[@]}"
    else
      s2_step peak-iii-start "$S2_MEM" peak start
      s2_step c "$S2_PROBE" searches 20 --set distinct20b --busy "${S2_BARP[@]}"
      s2_step peak-iii "$S2_MEM" peak stop "${S2_BARM[@]}"
    fi
    s2_unread > "$S2_RUN/$l-unread-after"
    KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" read menubar > "$S2_RUN/$l-menu-after" 2>&1
  done
  : > "$S2_RUN/bc.done"
}

# ---- S2.9: the panel opens in under 200 ms, with the app idle on the 50,000-row index --------------------

s2_check_9() {
  local out rc line med max bar verdict
  s2_begin
  s2_need_prep S2.9 --state || return $S2_RC
  sleep 1
  out="$(KIT_NO_EVIDENCE=1 "$S2_PROBE" opens 20 "${S2_BARP[@]}" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  echo "$out" > "$S2_RUN/9.out"
  line="$(s2_probe_line "$S2_RUN/9.out" opens)"
  if [ -z "$line" ]; then s2_state S2.9 "$rc" "$(s2_msg "$out")"; return $S2_RC; fi
  set -- $line
  med="$1"; max="$2"; bar="$3"; verdict="$4"
  s2_reading S2.9 "median $med ms max $max ms" "$bar ms" "$verdict"
  return $S2_RC
}
check_S2_9() { s2_check_9; }

# ---- S2.10: 20 warm searches on the 50,000-row index with the indexer busy ----------------------------

s2_check_10() {
  local quiet
  s2_begin
  s2_need_prep S2.10 || return $S2_RC
  s2_launch_q
  s2_launch_a
  s2_launch_ok S2.10 a || return $S2_RC
  s2_taken s10 searches S2.10 || return $S2_RC
  quiet="$(s2_probe_line "$S2_RUN/quiet.out" searches)"
  if [ -n "$quiet" ]; then
    set -- $quiet
    echo "  | the quiet total (nothing busy, set distinct20b): median $1 ms max $2 ms bar $3 ms $4 BAR"
  else
    echo "  | the quiet total (nothing busy, set distinct20b) was not taken: $(s2_msg "$(cat "$S2_RUN/quiet.out" 2>/dev/null)")"
  fi
  s2_reading S2.10 "median $P_MED ms max $P_MAX ms while indexing $(s2_mix_note)" "$P_BAR ms" "$P_VERDICT"
  if [ "$P_VERDICT" = OVER ] && [ -z "$KIT_PLANT" ]; then
    echo "STOP-ASK U18: S2.10 first reading is over the 500 ms bar (median $P_MED ms, max $P_MAX ms; the 50,000-row index, indexing $(s2_mix_note), 20 warm ranked lists); the bar is not lowered; the worker replies STATUS: blocked, RESULT STOP-ASK U18"
  fi
  return $S2_RC
}
check_S2_10() { s2_check_10; }

# ---- S2.11: opens and searches while the mix is being indexed on top of the 50,000-row index ----------------

s2_check_11() {
  local o_max s_med s_max verdict=WITHIN l rc
  s2_begin
  s2_need_prep S2.11 || return $S2_RC
  s2_launch_bc
  for l in b c; do
    s2_launch_ok S2.11 "$l" || return $S2_RC
  done
  for l in b c; do
    rc="$(s2_still_indexing "$l")" || { s2_state S2.11 4 "$rc"; return $S2_RC; }
  done
  s2_taken b opens S2.11 || return $S2_RC
  o_max="$P_MAX"; [ "$P_VERDICT" = OVER ] && verdict=OVER
  s2_taken c searches S2.11 || return $S2_RC
  s_med="$P_MED"; s_max="$P_MAX"; [ "$P_VERDICT" = OVER ] && verdict=OVER
  s2_reading S2.11 "busy opens max $o_max ms, busy searches median $s_med ms max $s_max ms while indexing $(s2_mix_note)" "200 ms for opens, 500 ms for searches" "$verdict"
  return $S2_RC
}
check_S2_11() { s2_check_11; }

# ---- S2.12: the first search after idle ----------------------------------------------------------------

s2_check_12() {
  s2_begin
  s2_need_prep S2.12 || return $S2_RC
  s2_launch_q
  s2_taken s12 searches S2.12 || return $S2_RC
  s2_reading S2.12 "first search after idle $P_MAX ms" "$P_BAR ms" "$P_VERDICT"
  return $S2_RC
}
check_S2_12() { s2_check_12; }

# ---- S2.13: idle memory, 90 s after the last search ----------------------------------------------------

s2_check_13() {
  local rc out line n bar verdict
  s2_begin
  s2_need_prep S2.13 || return $S2_RC
  s2_launch_q
  rc="$(s2_rc_of s13)"
  out="$(cat "$S2_RUN/s13.out" 2>/dev/null)"
  line="$(printf '%s\n' "$out" | awk '$1 == "READING" && $2 ~ /^idle_bytes=/ { print substr($2, 12), $7, $8; exit }')"
  if [ -z "$line" ]; then s2_state S2.13 "${rc:-4}" "$(s2_msg "$out")"; return $S2_RC; fi
  set -- $line
  n="$1"; bar="$2"; verdict="$3"
  s2_reading S2.13 "idle_bytes $n 90 s after the last search" "$bar bytes" "$verdict"
  return $S2_RC
}
check_S2_13() { s2_check_13; }

# ---- S2.14: the three peaks of (g) ---------------------------------------------------------------------

# s2_peak_line <step> : "<bytes> <bar> <WITHIN|OVER>" from the step's READING line.
s2_peak_line() { awk '$1 == "READING" && $2 ~ /^peak_bytes=/ { print substr($2, 12), $4, $5; exit }' "$S2_RUN/$1.out" 2>/dev/null; }

s2_check_14() {
  local step line rc n1 n2 n3 bar verdict=WITHIN n
  s2_begin
  s2_need_prep S2.14 || return $S2_RC
  s2_launch_q
  s2_launch_m
  s2_launch_bc
  s2_launch_ok S2.14 m || return $S2_RC
  s2_launch_ok S2.14 c || return $S2_RC
  rc="$(s2_still_indexing c)" || { s2_state S2.14 4 "peak (iii): $rc"; return $S2_RC; }
  rc="$(s2_rc_of c)"
  if [ "${rc:-4}" != 0 ]; then s2_state S2.14 "${rc:-4}" "peak (iii): the busy searches were not valid: $(s2_msg "$(cat "$S2_RUN/c.out" 2>/dev/null)")"; return $S2_RC; fi
  for step in peak-i peak-ii peak-iii; do
    line="$(s2_peak_line "$step")"
    if [ -z "$line" ]; then rc="$(s2_rc_of "$step")"; s2_state S2.14 "${rc:-4}" "$step: $(s2_msg "$(cat "$S2_RUN/$step.out" 2>/dev/null)")"; return $S2_RC; fi
    set -- $line
    n="$1"; bar="$2"; [ "$3" = OVER ] && verdict=OVER
    case "$step" in peak-i) n1="$n" ;; peak-ii) n2="$n" ;; *) n3="$n" ;; esac
  done
  s2_reading S2.14 "peaks (i) $n1 bytes with 20 searches and the index idle, (ii) $n2 bytes indexing $(s2_mix_note) with no search, (iii) $n3 bytes with 20 searches while indexing, summed over every Sesame process" "$bar bytes" "$verdict"
  for n in "$n1" "$n2" "$n3"; do
    if [ "$n" -gt 1300000000 ] && [ -z "$KIT_PLANT" ]; then
      echo "MEMORY STOP: S2.14 peak is $n bytes, above 1.30 GB: the memory stop of design section 8; the worker replies STATUS: blocked and names the figure"
    fi
  done
  return $S2_RC
}
check_S2_14() { s2_check_14; }

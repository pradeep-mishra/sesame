#!/bin/bash
# scripts/verify.sh [--quick] [--slice N] [--only S1..S9] [--plant smoke]
#
# The verify command (verify.md, Drive). It checks, up front, only the prerequisites without which nothing
# can run and, when one is missing, prints `NEEDS A PERSON: <what, and how to grant it>` and exits 3, so a
# missing grant never reads as a product failure. Then, in order:
#   full:   build, bundle, check-static.sh, swift test, kit-run.sh all --slice <N>
#   --quick: build, bundle, check-static.sh --quick (S8.4), S8(e) (S8.10, below slice 3 only: from slice 3 its tcc and prompts
#            parts need the S8 session and are read in the full run), the start-and-open-the-panel smoke,
#            from slice 2 the status item check (`kit-ax.sh read menubar` names a status item with a non-empty label,
#            read from the app the smoke left running), S8(g) (S8.12). S8.12 is last: it quits the app and deletes
#            the Sesame folder and the app copy.
# Every step prints `CHECK <id> PASS|FAIL|NEEDS-A-PERSON|SKIPPED <what>`; the run ends with
#   CHECKS: <passed> passed, <failed> failed, <skipped> skipped, <needs-a-person> needs-a-person
# and, when the last number is above zero, `NOT PROVEN, NEEDS A PERSON: <id>, <id>, ...`.
# A reading that kit-run.sh took counts as a needs-a-person line, never as passed or failed.
# Flags: --slice N (default: scripts/kit-lib/slice; the checks first drivable in slice N or earlier),
#        --only S1..S9 (the ids of that scenario alone, for a re-check of one scenario after a full run: no build, bundle, static, swift
#        test or prerequisite step, which are the cited full run's; it prints `ONLY <S>: ...`, makes the starting state (with --baseline
#        for S8 only), runs `kit-run.sh <S> --slice N` and prints that run's CHECKS line; not with --quick or --plant),
#        KIT_VERIFY_BIN (test seam: the folder that holds the kit-reset.sh and kit-run.sh verify.sh calls; default scripts/),
#        --quick (what the Doctor runs), --plant smoke (runs only the smoke with the shortcut replaced by a chord
#        the app does not own, Shift+Command+K, posted to the kit's own window: it must print `FAIL planted: ...`).
# Exit codes: 0 every step printed and none failed; 1 a check failed or was skipped, an id did not print, or
# the PASSES (needs-a-person never counts) are below the floor: for a full run the kit-run.sh checks that passed
# against scripts/kit-lib/checks.floor, for --quick the passes against QUICK_FLOOR; 2 usage; 3 a prerequisite is missing.
# The starting state is made with the id and version of the last kit-reset.sh (else `kit` and `verify`), so
# the evidence lands in the same folder; the full output is saved there as verify-output.txt, and the build,
# bundle and swift test logs as verify-<step>.txt. The smoke takes no picture of the screen; the shortcut is
# posted only inside `kit-ax.sh kitwindow open` and `kitwindow close`.
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/recipes.sh"
. "$KIT_LIB/checks-s8.sh"

usage() {
  cat >&2 <<'EOF'
usage: scripts/verify.sh [--quick] [--slice N] [--only S1..S10] [--plant smoke]
EOF
}

P=0; F=0; S=0; N=0; NL=""; SEP=""; RERUN=""
KP=0              # the passes reported by kit-run.sh (the floor of a full run counts these)
FLOOR_MODE=full   # full | quick | only | plant, set by main
VERIFY_BIN="${KIT_VERIFY_BIN:-$KIT_SCRIPTS}"   # where kit-reset.sh and kit-run.sh are called from (a test points it at stubs)
QUICK_FLOOR=3     # --quick: build and bundle, plus at least one of S8.4, S8.10 and the smoke, must PASS
SMOKE_KEEP=""     # set by main: the smoke leaves the app running when it passed, for the status item check
BUNDLE_OK=0
EVDIR=""
ID="kit"
VERSION="verify"

# ---- counting ------------------------------------------------------------------------------------

tally() { # tally <id> <verdict>
  case "$2" in
    PASS) P=$((P + 1)) ;;
    FAIL) F=$((F + 1)) ;;
    NEEDS-A-PERSON) N=$((N + 1)); NL="$NL$SEP$1"; SEP=", " ;;
    SKIPPED) S=$((S + 1)) ;;
  esac
}

# run_check <id> <function> : the function prints one `CHECK <id> ...` line and returns 4 when the run is not valid.
run_check() {
  local id="$1" fn="$2" tmp rc verdict
  tmp="$(mktemp "$KIT_TMP/verify-check.XXXXXX")" || { echo "CHECK $id FAIL no temp file"; F=$((F + 1)); return; }
  "$fn" </dev/null 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  if [ $rc = 4 ]; then
    grep -q "^RERUN $id " "$tmp" || echo "RERUN $id not valid: the check exited 4 without saying why"
    RERUN="$RERUN$id "
    rm -f "$tmp"
    return
  fi
  verdict="$(awk -v id="$id" '$1 == "CHECK" && $2 == id { print $3; exit }' "$tmp")"
  case "$verdict" in
    PASS|FAIL|NEEDS-A-PERSON|SKIPPED) tally "$id" "$verdict" ;;
    *) echo "CHECK $id FAIL the check printed no result line"; F=$((F + 1)) ;;
  esac
  rm -f "$tmp"
}

skip() { # skip <id> <reason>
  echo "CHECK $1 SKIPPED $2"
  S=$((S + 1))
}

# ---- prerequisites -------------------------------------------------------------------------------

MISSING=0
pre_ok() { echo "OK $1"; }
pre_need() { echo "NEEDS A PERSON: $1"; MISSING=$((MISSING + 1)); }

pre_tool() { # pre_tool <label> <how to install> <command...>
  local label="$1" how="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then pre_ok "$label"; else pre_need "$label is missing or does not run: $how"; fi
}

pre_swift() {
  local line major minor
  line="$(swift --version 2>&1 | head -1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  if [ -z "$line" ]; then
    pre_need "swift is missing or does not run: install the full Xcode"
    return
  fi
  major="${line% *}"; minor="${line#* }"
  if [ "$major" -gt 6 ] || { [ "$major" = 6 ] && [ "$minor" -ge 2 ]; }; then
    pre_ok "swift $major.$minor"
  else
    pre_need "Swift $major.$minor is too old: Sesame needs Swift 6.2 or newer, so update Xcode"
  fi
}

pre_sqlite() {
  local out
  out="$(sqlite3 :memory: "create virtual table t using fts5(a); select 'fts5 ok';" 2>&1)"
  if [ "$out" = "fts5 ok" ]; then pre_ok "sqlite3 with FTS5"
  else pre_need "sqlite3 with FTS5 is missing: the system sqlite3 cannot make an FTS5 table ($out)"
  fi
}

# pre_perms <check id whose person-steps are wanted> : kit-perms.sh's lines, forwarded as they are.
pre_perms() {
  local out rc
  out="$(kq "$KIT_SCRIPTS/kit-perms.sh" check --for "$1" 2>&1)"; rc=$?
  case $rc in
    0|3)
      printf '%s\n' "$out"
      MISSING=$((MISSING + $(printf '%s\n' "$out" | grep -c '^NEEDS A PERSON:')))
      ;;
    *)
      printf '%s\n' "$out"
      pre_need "scripts/kit-perms.sh check --for $1 did not run (exit $rc): see its output above"
      ;;
  esac
}

prerequisites() {
  echo "== prerequisites"
  pre_tool "full Xcode (xcodebuild)" "install Xcode from the Mac App Store, open it once and accept the license" xcodebuild -version
  pre_swift
  pre_tool "cmake" "brew install cmake" cmake --version
  pre_tool "ffmpeg" "brew install ffmpeg" ffmpeg -version
  pre_tool "git" "brew install git" git --version
  pre_sqlite
  # The person-steps every slice 1 ui check needs: Accessibility, Screen Recording, Automation for System Events
  # (the key list of kit-perms.sh for a setup check, which holds those three and nothing else) and the model
  # files (the key list of an S2 check, which holds only the model).
  # System Events is not always running, and macOS cannot say whether Automation is granted for an app that is
  # not: kit-ax.sh ping starts it (its own answer is not used here; the person-step lines below are).
  kq "$KIT_SCRIPTS/kit-ax.sh" ping >/dev/null 2>&1
  pre_perms S6.1
  pre_perms S2.1
  [ "$MISSING" = 0 ]
}

# ---- the steps -----------------------------------------------------------------------------------

# save_log <name> <file> : the complete output of a step goes to the evidence folder as verify-<name>.txt.
save_log() {
  local dest="$EVDIR/verify-$1.txt" n=1
  mkdir -p "$EVDIR" 2>/dev/null || return 0
  while [ -e "$dest" ]; do n=$((n + 1)); dest="$EVDIR/verify-$1-$n.txt"; done
  cp "$2" "$dest" 2>/dev/null
}

# step_cmd <id> <name> <what> <command...> : runs the command, shows the last lines, prints the CHECK line.
step_cmd() {
  local id="$1" name="$2" what="$3" tmp rc
  shift 3
  tmp="$(mktemp "$KIT_TMP/verify-step.XXXXXX")" || { echo "CHECK $id FAIL no temp file"; return 1; }
  "$@" >"$tmp" 2>&1 </dev/null; rc=$?
  save_log "$name" "$tmp"
  if [ $rc = 0 ]; then
    tail -3 "$tmp"
    echo "CHECK $id PASS $what exited 0"
  else
    tail -15 "$tmp"
    echo "CHECK $id FAIL $what exited $rc (the complete output is in verify-$name.txt in the evidence folder)"
  fi
  rm -f "$tmp"
  return $rc
}

check_build() { step_cmd build build "swift build -c release -Xswiftc -warnings-as-errors" swift build -c release -Xswiftc -warnings-as-errors; }

check_bundle() {
  local rc
  step_cmd bundle bundle "scripts/bundle.sh" "$KIT_SCRIPTS/bundle.sh"; rc=$?
  [ $rc = 0 ] && [ ! -d "$KIT_PROJECT/dist/Sesame.app" ] && { echo "CHECK bundle FAIL scripts/bundle.sh exited 0 but dist/Sesame.app is missing"; return 1; }
  return $rc
}

check_swift_test() { step_cmd swift-test swift-test "swift test --no-parallel" swift test --no-parallel; }

# The full static run fails on a PENDING rule (the rule's file does not exist yet); a quick run does not.
check_static_full() {
  local out rc pend
  out="$(kq "$KIT_SCRIPTS/check-static.sh" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  pend="$(printf '%s\n' "$out" | awk '$1 == "STATIC" && $3 == "PENDING" { printf "%s ", $2 }')"
  if [ $rc = 0 ]; then
    echo "CHECK static PASS scripts/check-static.sh exited 0"
  elif [ -n "$pend" ]; then
    echo "CHECK static FAIL scripts/check-static.sh exited $rc: rules still PENDING: $pend"
  else
    echo "CHECK static FAIL scripts/check-static.sh exited $rc"
  fi
  [ $rc = 0 ]
}

# The starting state: the id and version of the last reset (else kit and verify), the model from cache/, the
# fresh bundle copied to apps/. Silent when it works.
step_reset() {
  local out rc flag="${1:-}"
  out="$(kq "$VERIFY_BIN/kit-reset.sh" --id "$ID" --version "$VERSION" --model cache $flag 2>&1)"; rc=$?
  if [ $rc = 0 ]; then
    echo "starting state made: id $ID, version $VERSION"
    return 0
  fi
  printf '%s\n' "$out" | tail -8
  echo "CHECK reset FAIL scripts/kit-reset.sh --id $ID --version $VERSION --model cache${flag:+ $flag} exited $rc"
  F=$((F + 1))
  return $rc
}

# Extracts "<w> <h>" from the first "<number> x <number>" in a panel dump.
panel_size() { awk 'match($0, /[0-9.]+ *x *[0-9.]+/) { s = substr($0, RSTART, RLENGTH); split(s, a, / *x */); print a[1], a[2]; exit }'; }
within_one() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1) }'; }

# The start-and-open-the-panel smoke. The shortcut is posted to the real Sesame while the kit's own window is
# in front (Sesame is not frontmost until its panel opens); the window is closed on every path. No picture.
# With KIT_PLANT=1 the shortcut is replaced by Shift+Command+K, which the app does not own.
check_smoke() {
  local out rc size w h why="" ok=0 combo="" planted=""
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  out="$(kq "$KIT_SCRIPTS/kit-launch.sh" start 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | tail -3
    echo "CHECK smoke FAIL the app did not start (scripts/kit-launch.sh start exited $rc)"
    return 1
  fi
  out="$(kq "$KIT_SCRIPTS/kit-ax.sh" kitwindow open 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    kq "$KIT_SCRIPTS/kit-ax.sh" kitwindow close >/dev/null 2>&1
    kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
    if [ $rc = 3 ]; then
      echo "CHECK smoke NEEDS-A-PERSON $(printf '%s\n' "$out" | sed -n 's/^NEEDS A PERSON: //p' | head -1)"
      return 0
    fi
    printf '%s\n' "$out" | tail -3
    echo "CHECK smoke FAIL scripts/kit-ax.sh kitwindow open exited $rc"
    return 1
  fi
  echo "$out" | tail -1
  if [ -n "$KIT_PLANT" ]; then
    combo="shift+cmd+k"
    planted="Shift+Command+K posted to the kit window instead of the shortcut"
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" hotkey "$combo" 2>&1)"; rc=$?
  else
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" hotkey 2>&1)"; rc=$?
  fi
  echo "$out" | tail -2
  if [ $rc != 0 ]; then
    why="the shortcut was refused or failed (scripts/kit-ax.sh hotkey exited $rc)"
  else
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump panel 2>&1)"; rc=$?
    printf '%s\n' "$out" | head -4
    size="$(printf '%s\n' "$out" | panel_size)"
    w="${size% *}"; h="${size#* }"
    if [ $rc = 0 ] && [ -n "$size" ] && within_one "$w" 960 && within_one "$h" 560; then
      ok=1
      kq "$KIT_SCRIPTS/kit-ax.sh" hotkey >/dev/null 2>&1
    else
      why="no panel of 960 x 560 points after the shortcut (dump panel exit $rc, read: ${size:-no size in the dump})"
    fi
  fi
  out="$(kq "$KIT_SCRIPTS/kit-ax.sh" kitwindow close 2>&1)"; echo "$out" | tail -1
  [ -n "$SMOKE_KEEP" ] && [ $ok = 1 ] || kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  if [ $ok = 1 ]; then
    echo "CHECK smoke PASS the app started, the shortcut (Control+Option+Space, posted inside kitwindow open and close) opened a panel of $w x $h points, read with dump panel"
    return 0
  fi
  if [ -n "$planted" ]; then echo "CHECK smoke FAIL planted: $planted: $why"
  else echo "CHECK smoke FAIL $why"
  fi
  return 1
}

# The status item check (slice 2 on): the status item is in the menu bar and its accessibility label is not empty
# (`kit-ax.sh read menubar`). It reads the app the smoke left running, or starts one, and stops the app afterwards.
check_status_item() {
  local out rc label="" i
  if ! { kit_need_ps >/dev/null 2>&1 && [ -n "$(kit_pid_of app)" ]; }; then
    out="$(kq "$KIT_SCRIPTS/kit-launch.sh" start 2>&1)"; rc=$?
    if [ $rc != 0 ]; then
      printf '%s\n' "$out" | tail -3
      echo "CHECK status-item FAIL the app did not start (scripts/kit-launch.sh start exited $rc)"
      return 1
    fi
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" read menubar 2>&1)"; rc=$?
    [ $rc = 3 ] && break
    label="$(printf '%s\n' "$out" | sed -n 's/^status item: *//p' | head -1)"
    [ -n "$label" ] && break
    sleep 1
  done
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  if [ $rc = 3 ]; then
    echo "CHECK status-item NEEDS-A-PERSON $(printf '%s\n' "$out" | sed -n 's/^NEEDS A PERSON: //p' | head -1)"
    return 0
  fi
  if [ -n "$label" ]; then
    echo "CHECK status-item PASS the status item is in the menu bar and its accessibility label reads \"$label\" (kit-ax.sh read menubar)"
    return 0
  fi
  printf '%s\n' "$out" | tail -2
  echo "CHECK status-item FAIL the status item has no accessibility label (kit-ax.sh read menubar said: $(printf '%s\n' "$out" | tail -1))"
  return 1
}

# kit-run.sh <all|S1..S9> --slice N (all unless given a scenario), its CHECK lines shown as they come, its counts added to this run's.
run_kit_run() {
  local tmp rc line c_p c_f c_s c_n ids scen="${1:-all}"
  tmp="$(mktemp "$KIT_TMP/verify-kitrun.XXXXXX")" || { echo "CHECK kit-run FAIL no temp file"; F=$((F + 1)); return; }
  "$VERIFY_BIN/kit-run.sh" "$scen" --slice "$SLICE" </dev/null 2>&1 | tee "$tmp" \
    | sed -l -e 's/^CHECKS: /(kit-run.sh) CHECKS: /' -e 's/^NOT PROVEN, /(kit-run.sh) NOT PROVEN, /'
  rc=${PIPESTATUS[0]}
  line="$(grep '^CHECKS: ' "$tmp" | tail -1)"
  if [ -n "$line" ]; then
    c_p="$(printf '%s' "$line" | sed -n 's/^CHECKS: \([0-9]*\) passed.*/\1/p')"
    c_f="$(printf '%s' "$line" | sed -n 's/.* \([0-9]*\) failed.*/\1/p')"
    c_s="$(printf '%s' "$line" | sed -n 's/.* \([0-9]*\) skipped.*/\1/p')"
    c_n="$(printf '%s' "$line" | sed -n 's/.* \([0-9]*\) needs-a-person.*/\1/p')"
    P=$((P + ${c_p:-0})); F=$((F + ${c_f:-0})); S=$((S + ${c_s:-0})); N=$((N + ${c_n:-0}))
    KP=$((KP + ${c_p:-0}))
    ids="$(sed -n 's/^NOT PROVEN, NEEDS A PERSON: //p' "$tmp" | tail -1)"
    if [ -n "$ids" ]; then NL="$NL$SEP$ids"; SEP=", "; fi
    ids="$(sed -n 's/^NOT PRINTED (rerun): //p' "$tmp" | tail -1)"
    [ -z "$ids" ] || RERUN="$RERUN$ids "
  else
    echo "CHECK kit-run FAIL scripts/kit-run.sh $scen --slice $SLICE printed no CHECKS line (exit $rc)"
    F=$((F + 1))
  fi
  rm -f "$tmp"
}

# ---- the run -------------------------------------------------------------------------------------

summary() {
  local floor rc=0 real need what
  # The floor counts PASS results only; a NEEDS-A-PERSON line never counts toward it (round C, N5).
  #   full run: the passes of the kit-run.sh checks ($KP, not the build, bundle, static and test steps) against
  #             scripts/kit-lib/checks.floor (7: the slice 1 checks that passed in the real-app batches)
  #   --quick:  P against QUICK_FLOOR (the build and the bundle, plus at least one of S8.4, S8.10 and the smoke)
  #   --plant:  no floor (the planted check must fail, which is what this run asserts)
  floor="$(cat "$KIT_LIB/checks.floor" 2>/dev/null)"; floor="${floor:-1}"
  case "$FLOOR_MODE" in
    full)  need="$floor"; real="$KP"; what="kit-run.sh checks passed" ;;
    only)  need=0; real=0; what="" ;;
    quick) need="$QUICK_FLOOR"; real="$P"; what="checks passed" ;;
    *)     need=0; real=0; what="" ;;
  esac
  [ "$real" -ge "$need" ] || echo "note: $real $what, below the floor of $need passes (needs-a-person does not count)"
  [ -z "$RERUN" ] || echo "NOT PRINTED (rerun): $RERUN"
  echo "CHECKS: $P passed, $F failed, $S skipped, $N needs-a-person"
  [ "$N" -gt 0 ] && echo "NOT PROVEN, NEEDS A PERSON: $NL"
  [ "$F" = 0 ] || rc=1
  [ "$S" = 0 ] || rc=1
  [ -z "$RERUN" ] || rc=1
  [ "$real" -ge "$need" ] || rc=1
  return $rc
}

# On an interrupt the kit window is closed and the app stopped, so no key is left to land on the person's app.
interrupted() {
  kq "$KIT_SCRIPTS/kit-ax.sh" kitwindow close >/dev/null 2>&1
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  echo "interrupted: the kit window was closed and the app stopped"
  exit 130
}

main() {
  local quick=0 plant="" only="" SLICE="$KIT_SLICE" prior
  while [ $# -gt 0 ]; do
    case "$1" in
      --quick) quick=1; shift ;;
      --slice) [ $# -ge 2 ] || { usage; return 2; }; SLICE="$2"; shift 2 ;;
      --plant) [ $# -ge 2 ] || { usage; return 2; }; plant="$2"; shift 2 ;;
      --only) [ $# -ge 2 ] || { usage; return 2; }; only="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$SLICE" in [1-9]) ;; *) usage; return 2 ;; esac
  case "$only" in
    "") ;;
    S[1-9]|S10) if [ $quick = 1 ] || [ -n "$plant" ]; then echo "--only cannot be combined with --quick or --plant"; usage; return 2; fi ;;
    *) echo "unknown scenario for --only: $only"; usage; return 2 ;;
  esac
  case "$plant" in ""|smoke) ;; *) echo "unknown plant: $plant"; usage; return 2 ;; esac
  trap interrupted INT TERM HUP
  cd "$KIT_PROJECT" || return 1

  if [ -n "$only" ]; then echo "verify.sh --only $only (slice $SLICE)"; FLOOR_MODE=only
  elif [ -n "$plant" ]; then echo "verify.sh --plant $plant (slice $SLICE)"; FLOOR_MODE=plant
  elif [ $quick = 1 ]; then echo "verify.sh --quick (slice $SLICE)"; FLOOR_MODE=quick
  else echo "verify.sh (slice $SLICE)"; FLOOR_MODE=full
  fi

  [ -n "$only" ] || prerequisites || { echo "a prerequisite is missing: nothing was built or run"; return 3; }

  prior="$(cat "$KIT_ROOT/run/id" 2>/dev/null)"
  case "$prior" in S[1-9]|S10|kit) ID="$prior" ;; esac
  prior="$(cat "$KIT_ROOT/run/version" 2>/dev/null)"
  case "$prior" in ""|*[!A-Za-z0-9._-]*) ;; *) VERSION="$prior" ;; esac
  EVDIR="$KIT_PROJECT/.ril/evidence/$ID/$VERSION"
  KIT_PLANT=; export KIT_PLANT

  if [ -n "$only" ]; then
    echo "ONLY $only: build, static and swift test are the cited full run's (verify-output.txt)"
    if [ "$only" = S8 ]; then step_reset --baseline || { summary; return 1; }; else step_reset || { summary; return 1; }; fi
    run_kit_run "$only"
    summary
    return $?
  fi

  if [ -n "$plant" ]; then
    echo "== the smoke, planted"
    step_reset || { summary; return 1; }
    KIT_PLANT=1
    run_check smoke check_smoke
    summary
    return $?
  fi

  echo "== build and bundle"
  run_check build check_build
  if [ "$F" = 0 ]; then
    run_check bundle check_bundle
    [ "$F" = 0 ] && BUNDLE_OK=1
  else
    skip bundle "not run: the build failed"
  fi

  if [ $quick = 1 ]; then
    echo "== static, plist and entitlements, smoke, Library scan"
    if [ $BUNDLE_OK = 1 ]; then
      step_reset --baseline
    else
      echo "the starting state is not made: the build or the bundle failed, so the app copy would be stale"
    fi
    run_check S8.4 check_S8_4
    if [ $BUNDLE_OK = 1 ]; then
      # From slice 3 S8.10 holds its tcc and prompts parts, which read the S8 session (no session functions run in --quick, so it
      # would print RERUN): the full run reads them.
      if [ "$KIT_SLICE" -ge 3 ]; then
        echo "S8.10: the session parts (tcc and prompts) are read in the full run, not in --quick"
      else
        run_check S8.10 check_S8_10
      fi
      [ "$SLICE" -ge 2 ] && SMOKE_KEEP=1
      run_check smoke check_smoke
      SMOKE_KEEP=""
      [ "$SLICE" -ge 2 ] && run_check status-item check_status_item
      run_check S8.12 check_S8_12
    else
      skip S8.10 "not run: no fresh bundle"
      skip smoke "not run: no fresh bundle"
      skip S8.12 "not run: no starting state"
    fi
  else
    echo "== static and tests"
    run_check static check_static_full
    run_check swift-test check_swift_test
    echo "== the checks of slice $SLICE"
    if [ $BUNDLE_OK = 1 ]; then
      step_reset --baseline
      run_kit_run
    else
      skip kit-run "not run: no fresh bundle, so scripts/kit-run.sh all --slice $SLICE would drive a stale app"
    fi
  fi

  echo "== result"
  summary
}

kit_wrap "verify-output" main "$@"
exit $?

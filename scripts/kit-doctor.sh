#!/bin/bash
# kit-doctor.sh [--version <V>]: the Doctor (verify.md, Doctor). Run after any stop and before any
# scenario. It does, in order, and keeps going after a failure so one run shows everything:
#   0. the kit's Swift tools compile
#   1. kit-perms.sh check, and the swift format line
#   2. build and start: build-llama.sh (once), swift build, bundle.sh, kit-reset.sh, the app starts,
#      the shortcut opens a 960 x 560 window, from slice 2 the status item is in the menu bar, the app
#      honored HOME, the folder-picker ping, and every process of the app's tree is named Sesame*
#   3. verify.sh --quick
#   4. each driver answers its ping
# A part whose script or product part does not exist yet prints "not built yet: <what>" and is
# counted; it is not a failure. The last line is one of
#   DOCTOR OK partial (<n> not built yet)     (DOCTOR OK when n is 0)
#   DOCTOR: NEEDS A PERSON (<n>)
#   DOCTOR FAILED: <driver>
# Exit codes: 0 OK; 1 failed; 3 needs a person; 4 a product process is not named Sesame*.
. "$(dirname "$0")/kit-lib/common.sh"
# The recipes' picker driver (drive_picker, setup_lists): the Doctor's folder-picker ping drives the picker the same way.
. "$KIT_LIB/recipes.sh"

usage() { echo "usage: kit-doctor.sh [--version <V>]" >&2; }

FAILED=""
FAILED_RC=1
NBY=0
NEEDS=0
NEEDLIST=""

fail() { [ -n "$FAILED" ] || FAILED="$1"; echo "FAILED $1: $2"; }
nby() { NBY=$((NBY + 1)); echo "not built yet: $1"; }
need() { NEEDS=$((NEEDS + 1)); NEEDLIST="$NEEDLIST  - $1"$'\n'; echo "NEEDS A PERSON: $1"; }
ok() { echo "OK $1"; }
indent() { sed 's/^/    /'; }

# sub <script> <args...>: runs a kit script, sets SUB_OUT and SUB_RC.
sub() {
  local script="$1"; shift
  SUB_OUT="$("$KIT_SCRIPTS/$script" "$@" 2>&1)"
  SUB_RC=$?
}

# ---- 0 and 1 ---------------------------------------------------------------------------------

step_tools_compile() {
  local t bad=""
  for t in keytool pixelpoll; do
    kit_tool "$t" >/dev/null || bad="$bad $t"
  done
  if [ -z "$bad" ]; then
    ok "the kit's Swift tools compile (key-event tool, pixel-poll tool)"
  else
    fail kit-lib "the Swift tool(s)$bad did not compile; see $KIT_ROOT/run/bin/<name>.log"
    for t in $bad; do tail -5 "$KIT_ROOT/run/bin/$t.log" 2>/dev/null | indent; done
  fi
}

step_screen() {
  if kit_screen_locked; then
    need "the screen is locked, unlock it and keep it awake"
  else
    ok "the screen is unlocked"
  fi
}

step_perms() {
  local n
  sub kit-perms.sh check
  printf '%s\n' "$SUB_OUT"
  case $SUB_RC in
    0) ;;
    3)
      n="$(printf '%s\n' "$SUB_OUT" | grep -c '^NEEDS A PERSON:')"
      NEEDS=$((NEEDS + n))
      NEEDLIST="$NEEDLIST$(printf '%s\n' "$SUB_OUT" | sed -n 's/^NEEDS A PERSON: /  - /p')"$'\n'
      ;;
    *) fail kit-perms "exit $SUB_RC" ;;
  esac
  local out
  if out="$(swift format --version 2>&1)"; then
    echo "OK swift format: $out"
  else
    echo "swift format: absent (optional, not a failure)"
  fi
}

# ---- 2 ---------------------------------------------------------------------------------------

step_build() {
  local out rc
  if [ -x "$KIT_PROJECT/scripts/build-llama.sh" ]; then
    if [ -f "$KIT_PROJECT/third_party/llama.cpp/build/src/libllama.a" ]; then
      ok "llama.cpp already built"
    else
      out="$("$KIT_PROJECT/scripts/build-llama.sh" 2>&1)"; rc=$?
      if [ $rc = 0 ]; then ok "scripts/build-llama.sh"; else fail build "scripts/build-llama.sh exited $rc"; printf '%s\n' "$out" | tail -5 | indent; fi
    fi
  else
    nby "scripts/build-llama.sh (builds llama.cpp, task plan-1-t8)"
  fi
  out="$(swift build -c release -Xswiftc -warnings-as-errors 2>&1)"; rc=$?
  if [ $rc = 0 ]; then
    ok "swift build -c release"
  elif printf '%s\n' "$out" | grep -q 'sandbox_apply: Operation not permitted'; then
    # SwiftPM compiles the manifest inside its own sandbox, which cannot nest in another one.
    need "blocked: swift build -c release was refused by the sandbox this Doctor runs in (sandbox-exec: Operation not permitted); run the Doctor from your own Terminal"
  else
    fail build "swift build -c release exited $rc (expected before task plan-1-t10 makes a whole product)"
    printf '%s\n' "$out" | tail -5 | indent
  fi
  if [ -x "$KIT_PROJECT/scripts/bundle.sh" ]; then
    out="$("$KIT_PROJECT/scripts/bundle.sh" 2>&1)"; rc=$?
    if [ $rc = 0 ]; then ok "scripts/bundle.sh"; else fail build "scripts/bundle.sh exited $rc"; printf '%s\n' "$out" | tail -5 | indent; fi
  else
    nby "scripts/bundle.sh (makes dist/Sesame.app, task plan-1-t10)"
  fi
}

# Extracts "<w> <h>" from the first "<number> x <number>" in a panel dump.
panel_size() { awk 'match($0, /[0-9.]+ *x *[0-9.]+/) { s = substr($0, RSTART, RLENGTH); split(s, a, / *x */); print a[1], a[2]; exit }'; }

within_one() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1) }'; }

# The protocol-level probes for the helper's two modes (the shapes of the Helper protocol table).
encode_mode_exists() {
  local f="$KIT_ROOT/run/doctor-encode.lines"
  printf '%s\n' '{"cmd":"embed","id":1,"text":"probe","role":"query"}' > "$f"
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-launch.sh" helper encode --no-model --stdin "$f" 2>&1 | grep -q '"event" *: *"refused"'
}
index_mode_exists() {
  local f="$KIT_ROOT/run/doctor-index.lines"
  printf '%s\n' '{"cmd":"panel","open":false}' > "$f"
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-launch.sh" helper index --fake-embedder --stdin "$f" 2>&1 | grep -q '"event" *: *"unit"'
}

# The shortcut check. kit-ax.sh posts a key only while Sesame or a window the kit made is frontmost, so
# the Doctor puts the kit's own window in front first and closes it afterwards, on every path: a key is
# never sent to the person's own app. The window is closed even when a step in between fails.
# The shortcut is the product's default, Control+Option+Space (kit-ax.sh hotkey's default, ctrl+opt+space).
shortcut_check() {
  local size w h
  sub kit-ax.sh kitwindow open
  if [ $SUB_RC = 3 ]; then
    need "shortcut check: $(printf '%s\n' "$SUB_OUT" | sed -n 's/^NEEDS A PERSON: //p' | head -1)"
    return
  elif [ $SUB_RC != 0 ]; then
    fail kit-ax "kitwindow open exited $SUB_RC"; printf '%s\n' "$SUB_OUT" | tail -3 | indent
    return
  fi
  sub kit-ax.sh hotkey
  if [ $SUB_RC != 0 ]; then
    fail kit-ax "hotkey exited $SUB_RC"; printf '%s\n' "$SUB_OUT" | tail -3 | indent
  else
    sub kit-ax.sh dump panel
    size="$(printf '%s\n' "$SUB_OUT" | panel_size)"
    w="${size% *}"; h="${size#* }"
    if [ -n "$size" ] && within_one "$w" 960 && within_one "$h" 560; then
      ok "the shortcut (Control+Option+Space) opens a window of $w x $h points"
    else
      fail kit-ax "the panel is not 960 x 560 within 1 point (read: ${size:-no size in the dump})"
    fi
    KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" hotkey >/dev/null 2>&1
  fi
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" kitwindow close >/dev/null 2>&1
}

# The status item (verify.md, Doctor, step 2): from slice 2 on the app has a menu bar (slice 1 has none), so the status item
# must appear there, read through its accessibility label. It posts no key.
status_item_check() {
  local i label=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sub kit-ax.sh read menubar
    [ $SUB_RC = 3 ] && break
    label="$(printf '%s\n' "$SUB_OUT" | sed -n 's/^status item: *//p' | head -1)"
    [ -n "$label" ] && break
    sleep 1
  done
  if [ $SUB_RC = 3 ]; then
    need "status item check: $(printf '%s\n' "$SUB_OUT" | sed -n 's/^NEEDS A PERSON: //p' | head -1)"
  elif [ -n "$label" ]; then
    ok "the status item appears in the menu bar (kit-ax.sh read menubar: \"$label\")"
  else
    fail kit-ax "the status item is not in the menu bar (kit-ax.sh read menubar said: $(printf '%s\n' "$SUB_OUT" | tail -1))"
  fi
}

step_start() {
  local started=0 seen_enc=0 seen_idx=0 names bad i picker=0 empty_dir
  sub kit-reset.sh --id kit --version "$VERSION"
  if [ $SUB_RC = 0 ]; then ok "kit-reset.sh --id kit --version $VERSION"; else fail kit-reset "exit $SUB_RC"; printf '%s\n' "$SUB_OUT" | tail -5 | indent; return; fi

  if [ ! -d "$KIT_PROJECT/dist/Sesame.app" ]; then
    nby "app start with --mirror-full (needs dist/Sesame.app, task plan-1-t10)"
    nby "shortcut check: the panel opens at 960 x 560 (needs the app and scripts/kit-ax.sh)"
    nby "HOME check: the Sesame folder appears under the throwaway home (needs the app)"
    nby "folder-picker ping (needs the setup window, task plan-1-t28)"
    nby "encode and index process seen (needs the helper's two modes, tasks plan-1-t30 and plan-1-t31)"
    return
  fi

  sub kit-launch.sh start --mirror-full
  if [ $SUB_RC = 0 ]; then
    started=1; ok "kit-launch.sh start --mirror-full"
  else
    fail kit-launch "start --mirror-full exited $SUB_RC"; printf '%s\n' "$SUB_OUT" | tail -3 | indent
    return
  fi

  if [ -x "$KIT_SCRIPTS/kit-ax.sh" ]; then
    shortcut_check
    [ "$KIT_SLICE" -ge 2 ] && status_item_check
  else
    nby "shortcut check: the panel opens at 960 x 560 (scripts/kit-ax.sh, task plan-1-t7)"
  fi

  sub kit-launch.sh where
  if printf '%s\n' "$SUB_OUT" | grep -q '^mode='; then
    ok "the app honored HOME (its Sesame folder is under $KIT_ROOT/home)"
  else
    echo "NOTE the app ignored HOME: no Sesame folder under $KIT_ROOT/home (verify.md, guess K1: the kit would have to fall back to the real home)"
  fi

  # The folder-picker ping: only when the setup window can be read.
  empty_dir="$KIT_ROOT/fixtures/empty"
  if [ -x "$KIT_SCRIPTS/kit-ax.sh" ] && [ -x "$KIT_SCRIPTS/kit-fixtures.sh" ] && [ -x "$KIT_SCRIPTS/kit-index.sh" ] \
     && KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" dump setup >/dev/null 2>&1; then
    # drive_picker (kit-lib/recipes.sh, the same driver every recipe uses): fronts Sesame, presses "Add folder…", posts
    # Command+Shift+G, then retries `kit-ax.sh gotofolder` until the Go to the folder sheet exists and its field reads back
    # as the path (typed keys never reach that field), presses Enter twice, and reads the setup window back: the row it
    # added must be the folder asked for. Any other folder, or a sheet that never took the path, is a failed ping and
    # Start indexing is not pressed. setup_lists then reads the window once more, so the verdict is the window's own.
    PICKER_WHY=""
    if sub kit-fixtures.sh build empty && [ $SUB_RC = 0 ] \
       && drive_picker "$empty_dir" \
       && setup_lists "$empty_dir" \
       && "$KIT_SCRIPTS/kit-ax.sh" click "Start indexing" >/dev/null 2>&1; then
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        names="$("$KIT_SCRIPTS/kit-launch.sh" pids --names 2>/dev/null)"
        printf '%s\n' "$names" | grep -q ' encode$' && seen_enc=1
        printf '%s\n' "$names" | grep -q ' index$' && seen_idx=1
        [ $seen_enc = 1 ] && [ $seen_idx = 1 ] && break
        sleep 0.25
      done
      bad="$(printf '%s\n' "$names" | awk 'NF && $2 !~ /^Sesame/ { printf "%s ", $2 }')"
      if "$KIT_SCRIPTS/kit-index.sh" wait done 60 >/dev/null 2>&1; then
        picker=1; ok "the folder-picker ping: Add folder, Go to the folder sheet read back as $empty_dir, the setup window lists it, Start indexing, wait done"
      else
        need "folder picker cannot be driven (DOCTOR: NEEDS A PERSON (folder picker cannot be driven)); the recipes print the folders to pick by hand (verify.md, guess K33)"
      fi
    else
      echo "note: the folder-picker ping stopped before Start indexing: ${PICKER_WHY:-a step before the picker (fixture, Add folder…, the setup window read-back or Start indexing) failed}"
      need "folder picker cannot be driven (DOCTOR: NEEDS A PERSON (folder picker cannot be driven)); the recipes print the folders to pick by hand (verify.md, guess K33)"
    fi
  else
    nby "folder-picker ping (needs the setup window, task plan-1-t28)"
  fi

  if [ $picker = 1 ] && encode_mode_exists && index_mode_exists; then
    if [ -n "$bad" ] || [ $seen_enc = 0 ] || [ $seen_idx = 0 ]; then
      fail kit-launch "a product process is not named Sesame*, or no encode or index process was seen, so the network and file traces scoped by that name would miss it"
      FAILED_RC=4
    else
      ok "every process of the app's tree is named Sesame*, and an encode and an index process were seen"
    fi
  else
    nby "encode and index process seen (needs the helper's two modes, tasks plan-1-t30 and plan-1-t31)"
  fi

  [ $started = 1 ] && KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
}

# ---- 3 and 4 ---------------------------------------------------------------------------------

step_verify_quick() {
  local line
  if [ -x "$KIT_PROJECT/scripts/verify.sh" ]; then
    sub verify.sh --quick
    line="$(printf '%s\n' "$SUB_OUT" | grep '^CHECKS:' | tail -1)"
    if [ -n "$line" ] && [ "$(printf '%s' "$line" | sed -n 's/^CHECKS: \([0-9]*\) passed.*/\1/p')" -gt 0 ] 2>/dev/null; then
      ok "scripts/verify.sh --quick ($line)"
    elif [ $SUB_RC = 3 ]; then
      need "scripts/verify.sh --quick needs a person-step (see its NEEDS A PERSON line)"
      printf '%s\n' "$SUB_OUT" | grep '^NEEDS A PERSON' | indent
    else
      fail verify "scripts/verify.sh --quick: no CHECKS line with a passed count above zero (exit $SUB_RC)"
      printf '%s\n' "$SUB_OUT" | tail -3 | indent
    fi
  else
    nby "scripts/verify.sh --quick (task plan-1-t14)"
  fi
}

# ping <admin: 0|1> <script> <args...>
ping_driver() {
  local admin="$1" script="$2" driver tries
  shift 2
  driver="${script%.sh}"
  if [ ! -x "$KIT_SCRIPTS/$script" ]; then
    nby "scripts/$script $*"
    return
  fi
  sub "$script" "$@"
  # Right after the app starts, System Events briefly reports no frontmost process, so the one ping that
  # reads it is tried up to 3 times, 1 s apart; only exit 1 (an error) is retried, never a person-step.
  if [ "$script" = kit-ax.sh ] && [ "$1" = ping ]; then
    tries=1
    while [ "$SUB_RC" = 1 ] && [ "$tries" -lt 3 ]; do
      tries=$((tries + 1))
      echo "retry: $script ping failed ($(printf '%s\n' "$SUB_OUT" | tail -1)); try $tries of 3 after 1 s"
      sleep 1
      sub "$script" "$@"
    done
  fi
  case $SUB_RC in
    0) ok "$script $*" ;;
    3)
      # Administrator rights are first needed in slice 2: a slice 1 Doctor reports the four administrator pings without
      # failing; from slice 2 on a missing session is a person-step (verify.md, Doctor, step 1).
      if [ "$admin" = 1 ] && [ "$KIT_SLICE" -lt 2 ] && printf '%s\n' "$SUB_OUT" | grep -q 'administrator rights, first needed in slice 2'; then
        echo "NEEDS A PERSON (administrator rights, first needed in slice 2): $script $*"
      else
        need "$script $*: $(printf '%s\n' "$SUB_OUT" | sed -n 's/^NEEDS A PERSON[^:]*: //p' | head -1)"
      fi
      ;;
    *)
      if printf '%s\n' "$SUB_OUT" | grep -q -e 'Operation not permitted' -e 'LSOpenURLsWithRole' -e 'Apple Events'; then
        need "blocked: $script $* was refused by the sandbox it runs in; run the Doctor from your own Terminal"
      else
        fail "$driver" "$script $* exited $SUB_RC"
        printf '%s\n' "$SUB_OUT" | tail -3 | indent
      fi
      ;;
  esac
}

step_pings() {
  ping_driver 0 kit-ax.sh ping
  ping_driver 0 kit-ax.sh shot doctor --selftest
  ping_driver 0 kit-readback.sh ping finder
  ping_driver 0 kit-readback.sh ping preview
  ping_driver 0 kit-readback.sh ping quicktime
  ping_driver 0 kit-index.sh ping
  ping_driver 0 kit-mirror.sh status
  ping_driver 0 kit-fixtures.sh ping
  ping_driver 0 kit-mem.sh ping
  ping_driver 1 kit-net.sh ping
  ping_driver 1 kit-trace.sh ping
  ping_driver 0 kit-sums.sh ping
  ping_driver 0 kit-load.sh ping
  ping_driver 0 kit-volume.sh ping
  ping_driver 1 kit-privacy.sh ping
  ping_driver 0 kit-probe.sh ping
  ping_driver 1 kit-power.sh ping
}

main() {
  local version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || { usage; return 2; }; version="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  VERSION="${version:-$(cat "$KIT_ROOT/run/version" 2>/dev/null)}"
  VERSION="${VERSION:-doctor}"
  case "$VERSION" in *[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  cd "$KIT_PROJECT" || return 1
  mkdir -p "$KIT_ROOT"

  echo "== 0. the screen"
  step_screen
  echo "== 0. the kit's Swift tools"
  step_tools_compile
  echo "== 1. person-steps and tools (kit-perms.sh check)"
  step_perms
  echo "== 2. build and start"
  step_build
  step_start
  echo "== 3. verify.sh --quick"
  step_verify_quick
  echo "== 4. the drivers answer"
  step_pings
  echo "== result"

  if [ -n "$FAILED" ]; then
    echo "DOCTOR FAILED: $FAILED"
    return "$FAILED_RC"
  fi
  if [ "$NEEDS" -gt 0 ]; then
    printf '%s' "$NEEDLIST"
    echo "DOCTOR: NEEDS A PERSON ($NEEDS)"
    return 3
  fi
  if [ "$NBY" -gt 0 ]; then
    echo "DOCTOR OK partial ($NBY not built yet)"
  else
    echo "DOCTOR OK"
  fi
  return 0
}

kit_wrap "$(kit_slug kit-doctor "$@")" main "$@"
exit $?

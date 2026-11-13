#!/bin/bash
# kit-reset.sh --id <S1..S9|kit> --version <V> [--model mirror|cache] [--baseline]
# kit-reset.sh --cleanup [--wipe-cache]
#
# The starting state of a run (verify.md, Starting state) and its cleanup. Never touches the
# person's own data: everything lives under $KIT_ROOT (default $TMPDIR/sesame-kit).
#   reset:    first puts back and stops what the last run's stand-ins changed (Low Power Mode, the traces,
#             the disk image, the busy stand-in), then recreates home/, apps/ and run/, leaves fixtures/,
#             mirror/ and cache/ as they are, copies dist/Sesame.app to apps/ (reset_bundle: under id kit, with the
#             self-run marker $KIT_ROOT/break/selfrun-app, the self-run copy's app instead), records the evidence folder
#             every later script uses and the Low Power Mode value of this run.
#   --bundle-only --id <id>: test-only, runs only that bundle step.
#   cleanup:  first turns Launch at login off in the running app (the kit's copy of the app registers a login item on
#             its first run in a fresh HOME, and only the app's own switch or System Settings removes it), then quits
#             Sesame, kills any leftover process, stops what the kit started (the same stand-ins as a reset, the mirror
#             too), restores the system settings it recorded, deletes $KIT_ROOT except cache/ and keep/. keep/ holds the
#             Low Power Mode value to go back to (kit-power.sh); it stays until a restore has put it back, and a cleanup
#             that could not restore it says so (NEEDS A PERSON, with the command to run) and exits 3.
#   --baseline takes the Library baseline S8.12 and S8.13 compare against (kit-privacy.sh baseline, which lists the real ~/Library and
#             takes a while); a reset without it takes none, and S8.12 and S8.13 are then exit 4. It belongs to a reset only.
#   --wipe-cache also empties cache/ (the model files, the cached 50,000-row index); keep/ is never emptied.
# Exit codes: 0 done; 1 error; 2 usage; 3 a person-step is missing.
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/recipes.sh"

usage() {
  cat >&2 <<'EOF'
usage: kit-reset.sh --id <S1..S9|kit> --version <V> [--model mirror|cache] [--baseline]
       kit-reset.sh --cleanup [--wipe-cache]
       kit-reset.sh --keep-home
       kit-reset.sh --bundle-only --id <S1..S9|kit>      (test-only: runs just the bundle step)
EOF
}

# Puts back what the driver may have changed: the kit's own test window is closed and a system look that
# `kit-ax.sh appearance light|dark --keep` left is restored (nothing else changes the look for good).
# Both live in run/, so this runs before run/ is deleted.
restore_kit_state() {
  local out rc
  [ -x "$KIT_SCRIPTS/kit-ax.sh" ] || return 0
  out="$(KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" kitwindow close 2>&1)"; rc=$?
  [ $rc = 0 ] || out="cleanup: could not close the kit window: $out"
  case "$out" in "no kit window open") ;; *) echo "$out" ;; esac
  out="$(KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" appearance restore 2>&1)"; rc=$?
  [ $rc = 0 ] || out="cleanup: could not restore the system appearance: $out"
  case "$out" in "nothing to restore:"*) ;; *) echo "$out" ;; esac
}

# Puts back and stops what the power, trace, volume and load scripts changed or started: Low Power Mode is
# restored to the recorded value, every file and network trace is stopped, the disk image is detached and
# deleted, the busy stand-in is ended. They read what they saved under run/, so this runs before run/ is
# deleted, at cleanup and at every reset.
stop_stand_ins() {
  local item script args f name
  for item in "kit-power.sh restore" "kit-volume.sh destroy" "kit-load.sh stop"; do
    script="${item%% *}"; args="${item#* }"
    if [ -x "$KIT_SCRIPTS/$script" ]; then
      KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/$script" $args || echo "note: $script $args exited $?"
    else
      echo "note: $script not built yet, nothing to stop"
    fi
  done
  # Each trace left a run/pids/trace-<name>.pid; its fs_usage runs as administrator, so only the script ends it.
  if [ -x "$KIT_SCRIPTS/kit-trace.sh" ]; then
    for f in "$KIT_ROOT"/run/pids/trace-*.pid; do
      [ -f "$f" ] || continue
      name="$(basename "$f" .pid)"
      name="${name#trace-}"
      KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-trace.sh" stop "$name" || echo "note: kit-trace.sh stop $name exited $?"
    done
  else
    echo "note: kit-trace.sh not built yet, nothing to stop"
  fi
}

# The kit's copy of the app registers itself as a login item on its first run in a fresh HOME, and macOS keeps that
# record after the run is deleted. While the app still runs, the cleanup opens Settings, selects the Indexing section and
# presses Launch at login when it reads on (never when it reads off or is absent: that would register it). The first
# argument is the driver, kit-ax.sh by default. Never an error: a step that cannot be done is a note.
unregister_login_item() {
  local ax="${1:-$KIT_SCRIPTS/kit-ax.sh}" dump
  kit_ps_ok && [ -n "$(kit_pid_of app)" ] || return 0
  [ -x "$ax" ] || return 0
  kq "$ax" click "Settings…" >/dev/null 2>&1 || { echo "cleanup: note: Settings could not be opened, so Launch at login was not turned off; if Sesame is listed in System Settings, General, Login Items, remove it there"; return 0; }
  sleep 1
  settings_section Indexing >/dev/null || { echo "cleanup: note: the Indexing section of Settings could not be opened, so Launch at login was not turned off; if Sesame is listed in System Settings, General, Login Items, remove it there"; return 0; }
  dump="$(kq "$ax" dump settings 2>&1)"
  case "$(printf '%s\n' "$dump" | ax_switch "Launch at login")" in
    on) ;;
    off) echo "cleanup: Launch at login is already off"; return 0 ;;
    *) echo "cleanup: note: Settings shows no Launch at login switch, so nothing was pressed"; return 0 ;;
  esac
  kq "$ax" click "Launch at login" >/dev/null 2>&1 || { echo "cleanup: note: pressing Launch at login failed; if Sesame is listed in System Settings, General, Login Items, remove it there"; return 0; }
  sleep 2
  dump="$(kq "$ax" dump settings 2>&1)"
  if [ "$(printf '%s\n' "$dump" | ax_switch "Launch at login")" = off ]; then
    echo "cleanup: turned Launch at login off in Settings, so the kit's copy of the app leaves no login item behind"
  else
    echo "cleanup: note: Launch at login still reads on after it was pressed; if Sesame is listed in System Settings, General, Login Items, remove it there"
  fi
  return 0
}

# lowpower_pending : status 0, and one NEEDS A PERSON line, while the Low Power Mode value recorded at the start is still
# saved (kit-power.sh restore removes it only once the value is back).
lowpower_pending() {
  local f="$KIT_ROOT/keep/lowpower.saved" v
  [ -f "$f" ] || return 1
  v="$(cat "$f")"
  echo "NEEDS A PERSON: Low Power Mode was not put back; run \`sudo pmset -a lowpowermode $v\` (the recorded value stays in $f until kit-power.sh restore succeeds)"
  return 0
}

# Stops everything a kit script left running, then removes what the run made.
do_cleanup() {
  local wipe="$1" f pid
  unregister_login_item
  echo "cleanup: quitting Sesame"
  KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-launch.sh" stop
  restore_kit_state
  # Every background process a kit script started writes its pid to run/pids/<name>.pid.
  if [ -d "$KIT_ROOT/run/pids" ]; then
    for f in "$KIT_ROOT"/run/pids/*.pid; do
      [ -f "$f" ] || continue
      pid="$(cat "$f")"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 1
        kill -9 "$pid" 2>/dev/null
        echo "cleanup: stopped $(basename "$f" .pid) (pid $pid)"
      fi
    done
  fi
  # The mirror, then the stand-ins and the settings the kit changed (each only once its script exists).
  if [ -x "$KIT_SCRIPTS/kit-mirror.sh" ]; then
    "$KIT_SCRIPTS/kit-mirror.sh" stop || echo "cleanup: kit-mirror.sh stop exited $?"
  else
    echo "cleanup: kit-mirror.sh not built yet, nothing to stop"
  fi
  stop_stand_ins
  if [ -d "$KIT_ROOT" ]; then
    find "$KIT_ROOT" -mindepth 1 -maxdepth 1 ! -name cache ! -name keep -exec rm -rf {} +
    echo "cleanup: deleted everything under $KIT_ROOT except cache/ and keep/"
  fi
  mkdir -p "$KIT_ROOT/cache"
  if [ "$wipe" = 1 ]; then
    find "$KIT_ROOT/cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    echo "cleanup: emptied cache/ (--wipe-cache)"
  else
    echo "cleanup: kept cache/"
  fi
  if lowpower_pending; then return 3; fi
  return 0
}

# made_or_kept <path> : "made <path>/" when it did not exist yet, else "kept <path>/".
made_or_kept() {
  if [ -d "$1" ]; then echo "kept $1/"; else mkdir -p "$1" && echo "made $1/"; fi
}

# reset_bundle <id> : the bundle step of a reset. The app is run from a copy outside the project, never from dist/ or
# .build. A self-run (kit-selfrun.sh build) keeps its broken app at $KIT_ROOT/break/Sesame.app and writes the marker
# $KIT_ROOT/break/selfrun-app; under id kit that app is copied to apps/ instead of dist/Sesame.app, so a recipe's reset
# does not put the good app back. The marker lives under break/ because every reset deletes apps/. Under any other id the
# marker is stale: it is removed, so a left-over one cannot break a later block. Without a marker the step is plan 1's.
reset_bundle() {
  local id="$1" marker="$KIT_ROOT/break/selfrun-app"
  if [ -f "$marker" ]; then
    if [ "$id" = kit ]; then
      if [ -d "$KIT_ROOT/break/Sesame.app" ]; then
        mkdir -p "$KIT_ROOT/apps"
        ditto "$KIT_ROOT/break/Sesame.app" "$KIT_APP" || return 1
        echo "bundle copied from the self-run copy"
        return 0
      fi
      echo "self-run app missing: $KIT_ROOT/break/Sesame.app (the marker is there; kit-selfrun.sh build makes the app)"
      return 1
    fi
    rm -f "$marker"
    echo "note: stale self-run marker removed, the project bundle is used"
  fi
  if [ -d "$KIT_PROJECT/dist/Sesame.app" ]; then
    mkdir -p "$KIT_ROOT/apps"
    ditto "$KIT_PROJECT/dist/Sesame.app" "$KIT_APP" && echo "bundle copied to $KIT_APP"
  else
    echo "no bundle yet (dist/Sesame.app is made by scripts/bundle.sh)"
  fi
  return 0
}

# The Library baseline S8.12 and S8.13 compare against, taken only when the reset is asked for it (verify.md, Starting state).
reset_baseline() {
  if [ -x "$KIT_SCRIPTS/kit-privacy.sh" ]; then
    echo "baseline started $(date '+%Y-%m-%d %H:%M:%S')"
    KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-privacy.sh" baseline || echo "note: kit-privacy.sh baseline exited $?"
    echo "baseline ended $(date '+%Y-%m-%d %H:%M:%S')"
  fi
}

do_reset() {
  local id="$1" version="$2" model="$3" baseline="$4" f name size
  # Nothing else runs: a leftover Sesame process of an earlier run is stopped first.
  if kit_ps_ok; then
    KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
    kit_kill_tree
    restore_kit_state
  else
    echo "note: ps is refused here, so no leftover Sesame process was looked for"
  fi

  # What the last run's stand-ins changed is put back while run/ still holds what they saved.
  stop_stand_ins

  rm -rf "$KIT_ROOT/home" "$KIT_ROOT/apps" "$KIT_ROOT/run"
  mkdir -p "$KIT_ROOT/home" "$KIT_ROOT/apps" "$KIT_ROOT/run" || { echo "could not make $KIT_ROOT"; return 1; }
  echo "made $KIT_ROOT/home/"
  echo "made $KIT_ROOT/apps/"
  made_or_kept "$KIT_ROOT/fixtures"
  made_or_kept "$KIT_ROOT/mirror"
  echo "made $KIT_ROOT/run/"
  made_or_kept "$KIT_ROOT/cache"

  # The evidence folder every later kit script saves its output to (never touched by cleanup).
  local evidence="$KIT_PROJECT/.ril/evidence/$id/$version"
  mkdir -p "$evidence" || { echo "could not make the evidence folder $evidence"; return 1; }
  printf '%s\n' "$evidence" > "$KIT_ROOT/run/evidence-dir"
  printf '%s\n' "$id" > "$KIT_ROOT/run/id"
  printf '%s\n' "$version" > "$KIT_ROOT/run/version"
  mkdir -p "$KIT_ROOT/run/pids"
  echo "state: id $id, version $version, slice $KIT_SLICE"
  echo "evidence: $evidence"

  # The system appearance is recorded now and restored at cleanup.
  if defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then
    echo dark > "$KIT_ROOT/run/appearance"
  else
    echo light > "$KIT_ROOT/run/appearance"
  fi
  if [ -x "$KIT_SCRIPTS/kit-power.sh" ]; then
    "$KIT_SCRIPTS/kit-power.sh" record || echo "note: kit-power.sh record exited $?"
  fi
  if [ "$baseline" = 1 ]; then reset_baseline; else echo "no Library baseline taken (kit-reset.sh --baseline takes it; S8.12 and S8.13 need it)"; fi

  reset_bundle "$id" || return 1

  case "$model" in
    cache)
      local copied=0 dest="$KIT_ROOT/home/Library/Application Support/Sesame/models"
      while read -r name size _; do
        f="$KIT_ROOT/cache/$name"
        [ -f "$f" ] || continue
        if [ "$(stat -f %z "$f")" != "$size" ]; then
          echo "cache/$name is $(stat -f %z "$f") bytes, expected $size: run scripts/kit-mirror.sh seed --real again"
          return 1
        fi
        if [ "$copied" = 0 ]; then
          mkdir -p -m 700 "$KIT_ROOT/home/Library/Application Support/Sesame"
          mkdir -p "$dest"
        fi
        cp -c "$f" "$dest/$name" 2>/dev/null || cp "$f" "$dest/$name" || return 1
        copied=$((copied + 1))
        echo "model copied: $name"
      done < <(kit_models)
      [ "$copied" = 0 ] && echo "cache empty: no model files copied"
      ;;
    mirror) echo "model: mirror (kit-mirror.sh serves the files from cache/)" ;;
    *) echo "model: none" ;;
  esac

  # The kit's own support files must be there.
  local missing=0 part
  for part in "kit-lib/slice" "kit-lib/keytool.swift" "kit-lib/pixelpoll.swift"; do
    if [ -f "$KIT_SCRIPTS/$part" ]; then
      echo "ok scripts/$part"
    else
      echo "missing scripts/$part"; missing=1
    fi
  done
  [ "$missing" = 0 ] || return 1
  return 0
}

keep_home() {
  [ -d "$KIT_ROOT/home" ] || { echo "no home to keep: $KIT_ROOT/home does not exist"; return 1; }
  [ -d "$KIT_PROJECT/dist/Sesame.app" ] || { echo "no bundle: dist/Sesame.app is missing ($KIT_PROJECT/dist/Sesame.app)"; return 1; }
  rm -rf "$KIT_ROOT/apps"
  mkdir -p "$KIT_ROOT/apps" || return 1
  reset_bundle keep-home || return 1
  echo "kept $KIT_ROOT/home/"
}

main() {
  local id="" version="" model="" cleanup=0 wipe=0 bundle_only=0 baseline=0 keep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-home) keep=1; shift ;;
      --bundle-only) bundle_only=1; shift ;;
      --id) [ $# -ge 2 ] || { usage; return 2; }; id="$2"; shift 2 ;;
      --version) [ $# -ge 2 ] || { usage; return 2; }; version="$2"; shift 2 ;;
      --model) [ $# -ge 2 ] || { usage; return 2; }; model="$2"; shift 2 ;;
      --cleanup) cleanup=1; shift ;;
      --wipe-cache) wipe=1; shift ;;
      --baseline) baseline=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  if [ "$keep" = 1 ]; then
    [ "$bundle_only" = 0 ] && [ "$cleanup" = 0 ] && [ "$wipe" = 0 ] && [ "$baseline" = 0 ] && [ -z "$id$version$model" ] || { usage; return 2; }
    keep_home
    return $?
  fi
  if [ "$bundle_only" = 1 ]; then
    [ "$cleanup" = 0 ] && [ "$wipe" = 0 ] && [ "$baseline" = 0 ] && [ -z "$version$model" ] || { usage; return 2; }
    case "$id" in S[1-9]|S10|kit) ;; *) usage; return 2 ;; esac
    reset_bundle "$id"
    return $?
  fi
  if [ "$cleanup" = 1 ] || [ "$wipe" = 1 ]; then
    [ -z "$id$version$model" ] && [ "$baseline" = 0 ] || { usage; return 2; }
    do_cleanup "$wipe"
    return $?
  fi
  case "$id" in S[1-9]|S10|kit) ;; *) usage; return 2 ;; esac
  case "$version" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  case "$model" in ""|mirror|cache) ;; *) usage; return 2 ;; esac
  do_reset "$id" "$version" "$model" "$baseline"
}

kit_wrap "$(kit_slug kit-reset "$@")" main "$@"
exit $?

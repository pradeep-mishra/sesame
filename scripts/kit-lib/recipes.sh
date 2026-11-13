#!/bin/bash
# The starting recipes of `kit-run.sh prep <recipe>` (verify.md, Starting state, Recipes). Sourced by
# kit-run.sh after common.sh, never run. bash 3.2 compatible.
#
# Every recipe starts from the id and version that the last kit-reset.sh recorded, resets to a fresh state
# itself (so it can be run again and again inside one scenario) and returns the exit code of the script:
# 0 ready, 1 failed or a product part is missing, 3 NEEDS A PERSON, 4 a precondition did not hold.
# A recipe checks its cheap preconditions first and says at once which one is missing: never a long wait
# on a window or a helper that does not exist. Every key it posts goes through kit-ax.sh, which refuses
# any post that is not aimed at Sesame (or the kit's own window); a refusal is reported, never worked around.

# The pure readers of the accessibility dump (folder rows, the estimate total, the Launch at login switch): every check reads through them.
. "$KIT_LIB/axdump.sh"

# kq <command...> : a kit script called for its side effect; its output is part of this run's output.
kq() { KIT_NO_EVIDENCE=1 "$@"; }

# admin_session : status 0 when administrator rights are in hand. `sudo -n true` is tried first; when the session was never
# primed or has run out, kit-perms.sh ask-admin runs: it says its plain sentence to the person's terminal and then asks once
# (the one password prompt of the kit). The call is never captured, so the sentence is seen before the prompt. Every step
# that needs administrator rights calls this first, because the session lapses during a long check.
admin_session() {
  sudo -n true 2>/dev/null && return 0
  kq "$KIT_SCRIPTS/kit-perms.sh" ask-admin
}

R_ID=""
R_VERSION=""

recipe_state() {
  R_ID="$(cat "$KIT_ROOT/run/id" 2>/dev/null)"
  R_VERSION="$(cat "$KIT_ROOT/run/version" 2>/dev/null)"
  if [ -z "$R_ID" ] || [ -z "$R_VERSION" ]; then
    echo "no starting state: run scripts/kit-reset.sh --id <S1..S9|kit> --version <V> first"
    return 4
  fi
  return 0
}

# recipe_reset <cache|mirror|none> [--baseline] : a fresh starting state (a mirror left running is stopped first, so
# the reset cannot orphan it).
recipe_reset() {
  local args=(--id "$R_ID" --version "$R_VERSION")
  [ "$1" = none ] || args+=(--model "$1")
  [ "${2:-}" != --baseline ] || args+=(--baseline)
  [ -f "$KIT_ROOT/run/mirror-host" ] && kq "$KIT_SCRIPTS/kit-mirror.sh" stop
  kq "$KIT_SCRIPTS/kit-reset.sh" "${args[@]}"
}

# models_check <dir> : both model files whole (name and size from design section 7) or NEEDS A PERSON.
models_check() {
  local name size sha f bad=""
  while read -r name size sha; do
    f="$1/$name"
    if [ ! -f "$f" ]; then
      bad="$bad $name (missing)"
    elif [ "$(stat -f %z "$f")" != "$size" ]; then
      bad="$bad $name (is $(stat -f %z "$f") bytes, expected $size)"
    fi
  done < <(kit_models)
  [ -z "$bad" ] && return 0
  echo "NEEDS A PERSON: the model files are not whole in $1:$bad; scripts/kit-mirror.sh seed --real makes the one download"
  return 3
}

# copy_models <dir> : the model files into the throwaway home's models/ (what --model cache does for cache/).
copy_models() {
  local dest="$KIT_ROOT/home/Library/Application Support/Sesame/models" name size sha
  mkdir -p -m 700 "$KIT_ROOT/home/Library/Application Support/Sesame" && mkdir -p "$dest" || return 1
  while read -r name size sha; do
    cp -c "$1/$name" "$dest/$name" 2>/dev/null || cp "$1/$name" "$dest/$name" || return 1
    echo "model copied: $name"
  done < <(kit_models)
}

# ---- driving the setup window -------------------------------------------------------------------

# wait_setup_window <seconds> : status 0 when the setup window answers, 1 and one line naming it when it
# never shows, 3 when Accessibility is missing.
wait_setup_window() {
  local i out="" rc
  for ((i = 0; i < $1; i++)); do
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump setup 2>&1)"; rc=$?
    [ $rc = 0 ] && return 0
    if [ $rc = 3 ]; then echo "$out"; return 3; fi
    sleep 1
  done
  if kit_screen_locked; then kit_say_locked; return 3; fi
  echo "no setup window: Sesame shows none $1 s after it started, at $(date '+%Y-%m-%d %H:%M:%S') (kit-ax.sh dump setup said: ${out:-nothing})"
  return 1
}

# setup_has <text> : does the setup window's tree hold the text?
setup_has() {
  local out
  out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump setup 2>&1)"
  case "$out" in *"$1"*) return 0 ;; esac
  return 1
}

# setup_folders : the folders the setup window (PK_WINDOW=settings: the Settings window, on its Folders section) lists, one
# real path per line (the window shows /private/var/... spellings). A folder row is a tick whose accessibility help is the
# folder's full path (ax_folders). Status 1 when the window cannot
# be read; no folder gives no output ("No folders yet.").
setup_folders() {
  local out win="${PK_WINDOW:-setup}"
  out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump "$win" 2>&1)" || return 1
  printf '%s\n' "$out" | ax_folders
  return 0
}

# ---- driving the Settings window ----------------------------------------------------------------

# settings_section_marker <Folders|File types|Search|Indexing> : the control that only that section has. A section that is
# not selected is not in the accessibility tree (the window hides it), so this is how the kit knows its press worked: Folders
# "Add folder…", File types "PDFs" (the kind checkbox no other section shows), Search "Record new shortcut", Indexing "Start indexing".
# Status 2 for a name that is not a section.
settings_section_marker() {
  case "$1" in
    Folders) echo "Add folder…" ;;
    "File types") echo "PDFs" ;;
    Search) echo "Record new shortcut" ;;
    Indexing) echo "Start indexing" ;;
    *) return 2 ;;
  esac
}

# settings_section_has <section> : stdin the Settings dump; status 0 when it holds that section's marker, whole.
settings_section_has() {
  local marker
  marker="$(settings_section_marker "$1")" || return 2
  ax_has_label "$marker"
}

# settings_section <Folders|File types|Search|Indexing> : presses that sidebar button of the open Settings window and waits
# (6 s) until the section's own control is in its tree. Start indexing, Delete index… and Launch at login live only in Indexing,
# Add folder… and the folder rows only in Folders, and every other section is hidden from the tree, so every step that clicks
# or reads one of them selects its section first. Status 0 the section is open; 1 no sidebar button of that name, or the section
# did not open (one line says which); 2 a name that is not a section (nothing is pressed).
settings_section() {
  local name="$1" marker i out
  marker="$(settings_section_marker "$name")" || { echo "settings_section: \"$name\" is not a Settings section (Folders, File types, Search, Indexing)"; return 2; }
  kq "$KIT_SCRIPTS/kit-ax.sh" click "$name" >/dev/null 2>&1 || { echo "no sidebar button \"$name\" in the Settings window"; return 1; }
  for ((i = 0; i < 6; i++)); do
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump settings 2>&1)"
    if printf '%s\n' "$out" | settings_section_has "$name"; then return 0; fi
    sleep 1
  done
  echo "the Settings window shows no \"$marker\" after \"$name\" was pressed: the section did not open"
  return 1
}

# real_path <folder> : the folder with symlinks resolved, as the setup window spells it.
real_path() { (cd "$1" 2>/dev/null && pwd -P); }

# folders_hold <real folder> <list of rows> : status 0 when a row IS the folder or a direct subfolder of it.
# Which row the picker adds: with the folder typed into Go to folder, the first Enter opens the folder and the
# second presses Open. NSOpenPanel then has the folder's only subfolder selected, so `golden` (whose only
# visible entry is `photos`) adds golden/photos (measured: t35 report, and the setup window dump of the t36-39
# batch), while a folder with no subfolder (`empty`) or only files (`golden/photos`) adds itself. The recipe
# therefore expects the folder or its direct subfolder, never anything else.
folders_hold() {
  local want="$1" rows="$2" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$r" = "$want" ] && return 0
    [ "${r%/*}" = "$want" ] && return 0
  done <<EOF
$rows
EOF
  return 1
}

# setup_lists <absolute folder> : the setup window lists that folder (or the subfolder the picker selected in it).
setup_lists() {
  local real rows
  real="$(real_path "$1")"
  [ -n "$real" ] || return 1
  rows="$(setup_folders)" || return 1
  folders_hold "$real" "$rows"
}

# The picker is driven the way a person does, with Sesame the only app that is fronted or given keys.
# PK_PAUSE is the pause between steps, PK_SHEET how long the Go to sheet is waited for (seconds).
PK_PAUSE="${KIT_PICKER_PAUSE:-1}"
PK_SHEET="${KIT_PICKER_SHEET:-5}"
PICKER_WHY=""

# picker_front : status 0 once `kit-ax.sh frontmost` reads Sesame; Sesame is raised (the kit's own, by its pid,
# `kit-ax.sh front-sesame`) when it does not, once. Sesame is never frontmost after a kit launch.
picker_front() {
  local ax="$KIT_SCRIPTS/kit-ax.sh" name i
  for i in 1 2; do
    name="$(kq "$ax" frontmost 2>/dev/null)"
    [ "$name" = Sesame ] && return 0
    kq "$ax" front-sesame >/dev/null 2>&1
  done
  name="$(kq "$ax" frontmost 2>/dev/null)"
  [ "$name" = Sesame ] && return 0
  PICKER_WHY="Sesame is not the frontmost app (it is ${name:-unknown}), so no key was posted"
  return 1
}

# picker_key <combo> : one key to Sesame, only after `frontmost` reads Sesame (kit-ax.sh key refuses it too otherwise).
picker_key() {
  picker_front || return 1
  kq "$KIT_SCRIPTS/kit-ax.sh" key "$1" >/dev/null 2>&1 || { PICKER_WHY="the key $1 was refused"; return 1; }
}

# picker_cancel : a picker left open after a failed attempt is cancelled (an accessibility press on its own
# Cancel button; no key, no other app).
picker_cancel() { kq "$KIT_SCRIPTS/kit-ax.sh" click "Cancel" >/dev/null 2>&1; return 0; }

# picker_attempt <absolute folder> <real folder> : one try. Status 0 the folder is listed; 1 a step failed (PICKER_WHY
# says which; the picker may be left open); 2 the setup window grew by more than the one folder asked for (nothing
# more is tried).
picker_attempt() {
  local ax="$KIT_SCRIPTS/kit-ax.sh" dir="$1" real="$2" before after new n i ok
  # "Add folder…" and the folder rows are in the Folders section only; a Settings window left on Indexing has neither.
  if [ "${PK_WINDOW:-setup}" = settings ]; then
    settings_section Folders >/dev/null || { PICKER_WHY="the Settings window cannot be put on its Folders section"; return 1; }
  fi
  # Welcome has no folder rows and no "Add folder…": step to Folders before the snapshot, so it already holds the suggested folders.
  if ! kq "$ax" dump "${PK_WINDOW:-setup}" 2>/dev/null | ax_has_label "Add folder…"; then
    kq "$ax" click "Next" >/dev/null 2>&1 || { PICKER_WHY="no \"Add folder…\" button in the setup window"; return 1; }
    sleep "$PK_PAUSE"
  fi
  before="$(setup_folders)" || { PICKER_WHY="the setup window cannot be read"; return 1; }
  picker_front || return 1
  kq "$ax" click "Add folder…" >/dev/null 2>&1 || { PICKER_WHY="no \"Add folder…\" button in the setup window"; return 1; }
  sleep "$PK_PAUSE"
  picker_key "shift+cmd+g" || return 1
  ok=0
  for ((i = 0; i < PK_SHEET * 2; i++)); do
    # the path goes into the Go to sheet through the accessibility value; typed keys never reach that field
    if kq "$ax" gotofolder "$dir" >/dev/null 2>&1; then ok=1; break; fi
    sleep 0.5
  done
  [ "$ok" = 1 ] || { PICKER_WHY="the Go to the folder sheet did not take the path within $PK_SHEET s"; return 1; }
  picker_key "enter" || return 1
  sleep "$PK_PAUSE"
  picker_key "enter" || return 1
  for ((i = 0; i < 10; i++)); do
    after="$(setup_folders)" || after=""
    new="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort))"
    n="$(printf '%s\n' "$new" | awk 'NF { k++ } END { print k + 0 }')"
    if [ "$n" -gt 1 ]; then
      PICKER_WHY="the setup window gained $n folders for one pick: $(printf '%s' "$new" | tr '\n' ' ')"
      return 2
    fi
    if [ "$n" = 1 ]; then
      if folders_hold "$real" "$new"; then return 0; fi
      PICKER_WHY="the picker added $(printf '%s' "$new") for $real"
      return 1
    fi
    # no new row after 3 s: fine only when the folder (or its subfolder) was listed before this pick
    if [ "$i" -ge 3 ] && folders_hold "$real" "$before"; then return 0; fi
    sleep 1
  done
  PICKER_WHY="the setup window does not list $real after the picker closed"
  return 1
}

# drive_picker <absolute folder> : front Sesame, "Add folder…", Command+Shift+G, the path set in the Go to field,
# Enter, Enter (see folders_hold for the row the picker adds). Two attempts at most; a picker left open after a
# failed one is cancelled. Status 0 the folder is listed, 1 it could not be driven (PICKER_WHY says why).
drive_picker() {
  local real attempt rc
  real="$(real_path "$1")"
  [ -n "$real" ] || { PICKER_WHY="no such folder: $1"; return 1; }
  for attempt in 1 2; do
    picker_attempt "$1" "$real"; rc=$?
    [ $rc = 0 ] && return 0
    picker_cancel
    [ $rc = 2 ] && return 2
    sleep "$PK_PAUSE"
  done
  return 1
}

# pick_folders <folder under fixtures/ or absolute path>... : the picker drives it; a folder the setup window already lists (the
# picker adds the one subfolder of `golden`, so `golden` then `golden/photos` is one row) is not picked twice.
# When the picker cannot be driven the person is asked once (verify.md, guess K33) and the list is polled for
# at most PK_WAIT seconds (default 90), then NEEDS A PERSON.
PK_WAIT="${KIT_PICK_WAIT:-90}"
PK_POLL="${KIT_PICK_POLL:-5}"

# pick_path <folder> : an absolute path as it is, else a folder under the fixture root.
pick_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$KIT_ROOT/fixtures/$1" ;;
  esac
}

pick_folders() {
  local f p paths="" all end rc
  for f in "$@"; do paths="$paths $(pick_path "$f")"; done
  for f in "$@"; do
    p="$(pick_path "$f")"
    if setup_lists "$p"; then echo "folder already listed: $p"; continue; fi
    drive_picker "$p"; rc=$?
    [ $rc = 0 ] && continue
    if [ $rc = 2 ]; then
      echo "$PICKER_WHY"
      echo "the setup window lists more folders than were asked for: the starting state is not valid, reset and rerun"
      return 4
    fi
    echo "note: the picker could not be driven: $PICKER_WHY"
    echo "NEEDS A PERSON: pick these folders with \"Add folder…\" (code stays off):$paths"
    end=$((SECONDS + PK_WAIT))
    while :; do
      all=1
      for f in "$@"; do setup_lists "$(pick_path "$f")" || all=0; done
      [ "$all" = 1 ] && return 0
      [ "$SECONDS" -ge "$end" ] && break
      sleep "$PK_POLL"
    done
    echo "NEEDS A PERSON: the folders were not picked within $PK_WAIT seconds:$paths"
    return 3
  done
  return 0
}

press_start() {
  local out dump rc i err="Could not save the settings"
  out="$(kq "$KIT_SCRIPTS/kit-ax.sh" click "Start indexing" 2>&1)" || { echo "could not press Start indexing: $out"; return 1; }
  for ((i = 0; i < 10; i++)); do
    dump="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump setup 2>&1 </dev/null)"; rc=$?
    [ $rc != 3 ] || { printf '%s\n' "$dump"; return 3; }
    if [ $rc = 0 ] && printf '%s\n' "$dump" | ax_has_label "Step 3 of 4: Permissions"; then
      echo "Start indexing pressed, the Setup window is on \"Step 3 of 4: Permissions\""
      return 0
    fi
    if [ $rc = 0 ] && printf '%s\n' "$dump" | ax_has_label_prefix "$err"; then
      echo "Start indexing pressed, the Setup window stays on Folders and shows the start error \"$(printf '%s\n' "$dump" | ax_elements | awk -F'\t' -v w="$err" 'index($3, w) == 1 { print $3; exit }')\""
      return 1
    fi
    sleep 1
  done
  echo "Start indexing pressed, but the Setup window shows neither \"Step 3 of 4: Permissions\" nor a start error within 10 s (it reads:)"
  printf '%s\n' "$dump"
  return 1
}

setup_started() {
  kq "$KIT_SCRIPTS/kit-index.sh" settings 2>&1 | awk '/"startPressed" *=>/ { f = ($3 == "true" || $3 == "1") } END { exit f ? 0 : 1 }'
}

setup_finish() {
  local ax="$KIT_SCRIPTS/kit-ax.sh" out rc i step steps first pressed
  out="$(kq "$ax" dump setup 2>&1 </dev/null)"; rc=$?
  [ $rc != 3 ] || { printf '%s\n' "$out"; return 3; }
  if [ $rc = 0 ] && printf '%s\n' "$out" | ax_has_label "Step 2 of 4: Folders"; then
    if printf '%s\n' "$out" | ax_has_label "Next"; then
      first="Next"
    elif printf '%s\n' "$out" | ax_has_label "Not now"; then
      first="Not now"
    else
      echo "the Setup window on \"Step 2 of 4: Folders\" has neither a \"Next\" nor a \"Not now\" button (it reads:)"
      printf '%s\n' "$out"
      return 4
    fi
    steps=("Step 3 of 4: Permissions" "Step 4 of 4: Shortcut")
  elif [ $rc = 0 ] && printf '%s\n' "$out" | ax_has_label "Step 3 of 4: Permissions" && setup_started; then
    first="Next"
    steps=("Step 4 of 4: Shortcut")
  else
    echo "the Setup window is not on \"Step 2 of 4: Folders\", nor on \"Step 3 of 4: Permissions\" after Start indexing was pressed (it reads:)"
    printf '%s\n' "$out"
    return 4
  fi
  for step in "${steps[@]}"; do
    kq "$ax" click "$first" >/dev/null 2>&1 || { echo "no \"$first\" button in the Setup window"; return 1; }
    pressed="$first"
    first="Next"
    for ((i = 0; i < 6; i++)); do
      out="$(kq "$ax" dump setup 2>&1 </dev/null)"; rc=$?
      [ $rc != 3 ] || { printf '%s\n' "$out"; return 3; }
      if [ $rc = 0 ] && printf '%s\n' "$out" | ax_has_label "$step"; then break; fi
      sleep 1
    done
    if [ $rc != 0 ] || ! printf '%s\n' "$out" | ax_has_label "$step"; then
      echo "the Setup window shows no \"$step\" after $pressed was pressed (it reads:)"
      printf '%s\n' "$out"
      return 4
    fi
  done
  if ! printf '%s\n' "$out" | ax_elements | awk -F'\t' '$2 ~ /^AXButton/ && $3 == "Finish" && $7 !~ /D/ { f = 1 } END { exit f ? 0 : 1 }'; then
    echo "the Setup window has no enabled \"Finish\" on \"Step 4 of 4: Shortcut\" (it reads:)"
    printf '%s\n' "$out"
    return 4
  fi
  kq "$ax" click "Finish" >/dev/null 2>&1 || { echo "no \"Finish\" button in the Setup window"; return 1; }
  for ((i = 0; i < 8; i++)); do
    out="$(kq "$ax" dump setup 2>&1 </dev/null)"; rc=$?
    [ $rc != 3 ] || { printf '%s\n' "$out"; return 3; }
    [ $rc != 1 ] || break
    sleep 1
  done
  if [ $rc != 1 ]; then
    echo "the Setup window is still there 8 s after Finish was pressed (it reads:)"
    printf '%s\n' "$out"
    return 4
  fi
  sleep 2
  echo "setup finished"
}

settings_start() {
  local ax="$KIT_SCRIPTS/kit-ax.sh" msg out
  msg="$(settings_section Indexing)" || { echo "$msg"; return 1; }
  out="$(kq "$ax" dump settings 2>&1 </dev/null)" || { echo "kit-ax.sh dump settings said \"$(printf '%s\n' "$out" | tail -1)\""; return 4; }
  if ! printf '%s\n' "$out" | ax_elements | awk -F'\t' '$2 ~ /^AXButton/ && $3 == "Start indexing" && $7 !~ /D/ { f = 1 } END { exit f ? 0 : 1 }'; then
    echo "Start indexing is disabled or missing in the Indexing section (the Settings window reads:)"
    printf '%s\n' "$out"
    return 4
  fi
  kq "$ax" click "Start indexing" >/dev/null 2>&1 || { echo "could not press Start indexing in the Settings window"; return 1; }
  kq "$KIT_SCRIPTS/kit-index.sh" wait started 120 || { echo "Start indexing was pressed in Settings but indexing did not start within 120 s"; return 4; }
  echo "Settings Start indexing pressed"
}

# ---- fresh-throttled ----------------------------------------------------------------------------

recipe_fresh_throttled() {
  recipe_state || return $?
  recipe_reset mirror || return $?
  kq "$KIT_SCRIPTS/kit-mirror.sh" start || return $?
  kq "$KIT_SCRIPTS/kit-mirror.sh" rate 500000 || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start --mirror || return $?
  echo "fresh-throttled ready: mirror at 500000 bytes a second, app started, no setup done"
}

# ---- photos -------------------------------------------------------------------------------------

# photos [--no-wait] [--cache-dir <dir>] : the model from the cache (or from <dir>, relative to the kit
# root), golden/ and golden/photos/ picked, code off, Start indexing pressed once, then wait for done and, from slice 2
# on, until the menu bar says Ready too. The picker and its fallback (pick_folders) are as plan 1 built them.
recipe_photos() {
  local nowait=0 dir="$KIT_ROOT/cache"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-wait) nowait=1; shift ;;
      --cache-dir)
        [ $# -ge 2 ] || { usage; return 2; }
        case "$2" in /*) dir="$2" ;; *) dir="$KIT_ROOT/$2" ;; esac
        mkdir -p "$dir" || return 1
        shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  recipe_state || return $?
  models_check "$dir" || return $?
  if [ "$dir" = "$KIT_ROOT/cache" ]; then
    recipe_reset cache || return $?
  else
    recipe_reset none || return $?
    copy_models "$dir" || return 1
  fi
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  pick_folders golden golden/photos || return $?
  press_start || return $?
  if [ "$nowait" = 1 ]; then
    echo "photos started, not waiting for done (--no-wait)"
    return 0
  fi
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 900 || return $?
  # From slice 2 on the menu bar exists, and the recipe is ready only when it says Ready too (slice 1 has no menu bar).
  [ "$KIT_SLICE" -ge 2 ] || return 0
  wait_menu_ready 120
}

# wait_menu_ready <seconds> : status 0 once the status item reads Ready; 1 when it never does, 3 when Accessibility is
# missing (the NEEDS A PERSON line is printed).
wait_menu_ready() {
  local end=$((SECONDS + $1)) out rc
  while :; do
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" read menubar 2>&1)"; rc=$?
    if [ $rc = 3 ]; then printf '%s\n' "$out"; return 3; fi
    case "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" in *ready*) echo "the menu bar says Ready"; return 0 ;; esac
    [ "$SECONDS" -ge "$end" ] && break
    sleep 2
  done
  echo "the menu bar never said Ready within $1 s (kit-ax.sh read menubar said: $(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }'))"
  return 1
}

# ---- busy50k ------------------------------------------------------------------------------------

# Does the bundled helper speak index mode? A real one answers a panel line with a unit event (the Helper
# protocol table); the helper that has no index mode refuses the mode and prints nothing on stdout.
helper_has_index_mode() {
  local lines="$KIT_ROOT/run/index-probe.jsonl" out
  printf '{"cmd":"panel","open":true}\n' > "$lines"
  out="$(kq "$KIT_SCRIPTS/kit-launch.sh" helper index --fake-embedder --stdin "$lines" 2>/dev/null)"
  rm -f "$lines"
  case "$out" in *'"event"'*'"unit"'*) return 0 ;; esac
  return 1
}

# The seed (Conventions, busy recipe step 3), made once per saved version: the helper reconciles the filler
# with the fake embedder, no app running, and the index is copied to cache/index50k-<V>/.
busy50k_seed() {
  local dir="$KIT_ROOT/cache/index50k-$R_VERSION" out n
  if [ -f "$dir/index.sqlite" ]; then
    echo "index50k seed: cached copy found in $dir"
    return 0
  fi
  recipe_reset none || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" helper index --fake-embedder --folders filler || return $?
  out="$(kq "$KIT_SCRIPTS/kit-index.sh" rows 2>&1)"
  n="$(printf '%s\n' "$out" | awk '$1 == "rows" { print $2 }')"
  case "$n" in
    ""|*[!0-9]*) echo "index rows unreadable: $out"; return 4 ;;
  esac
  if [ "$n" -lt 50000 ]; then
    echo "filler too small: rows $n"
    return 4
  fi
  mkdir -p "$dir" || return 1
  cp "$KIT_ROOT/home/Library/Application Support/Sesame"/index.sqlite* "$dir"/ || return 1
  echo "index50k seed: rows $n, copied to $dir"
}

# One launch of the busy state (steps 3 restore, 4 and 5): the cached index restored after a reset, one real
# first launch with the model from cache/, setup picks the filler and the golden photos, Start pressed
# once, then the rows must rise within 120 s (kit-index.sh exits 4 when they do not: rerun). Golden is picked first, so
# the walk reaches its 40 photos before the 50,000 filler files.
busy50k_launch() {
  local dir="$KIT_ROOT/cache/index50k-$R_VERSION" sesame="$KIT_ROOT/home/Library/Application Support/Sesame"
  recipe_reset cache || return $?
  mkdir -p -m 700 "$sesame" || return 1
  cp "$dir"/index.sqlite* "$sesame"/ || return 1
  echo "index restored from $dir"
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  pick_folders golden filler || return $?
  press_start || return $?
  kq "$KIT_SCRIPTS/kit-index.sh" wait rising 120
}

recipe_busy50k() {
  local rc
  recipe_state || return $?
  if [ ! -x "$KIT_HELPER_EXE" ]; then
    echo "no SesameHelper in the bundle copy $KIT_HELPER_EXE: run scripts/kit-reset.sh after scripts/bundle.sh"
    return 4
  fi
  # 1. the cheap preconditions, each exits at once with its reason
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  if ! helper_has_index_mode; then
    echo "helper has no index mode yet"
    return 1
  fi
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8; rc=$?
  kq "$KIT_SCRIPTS/kit-launch.sh" quit >/dev/null 2>&1
  [ $rc = 0 ] || return $rc
  models_check "$KIT_ROOT/cache" || return $?
  # 2. the filler, 3. the seed, 4 and 5. the launch
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build filler 50000 || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  busy50k_seed || return $?
  busy50k_launch
}

# ---- index50k (the real 50,000-row index of the closing pass) ----------------------------------

# The real-indexer counterpart of busy50k: the golden fixture, api-client and generated filler indexed by the real helper with the real
# model until the index holds at least 50,000 rows (files plus passages), then kept in cache/index50k-real-<V>/. Its name never matches
# the stand-in's cache/index50k-<V>/ (busy50k_seed), so the two cannot be mixed up, and the stand-in's cache is never read here. A cache is
# reused only for the saved version it was built for and the vector_source recorded in its `meta` file; the kit cannot know the product's
# revision and vector version, so it checks that the recorded vector_source names both model files of models.tsv (a variant change shows),
# and S2.9's first reading says whether the app accepts the restored index ("Nothing is indexed yet" means it did not).
index50k_dir() { echo "$KIT_ROOT/cache/index50k-real-$R_VERSION"; }

# index50k_meta <dir> <name> : the value of a `<name> <value>` line of the cache's meta file.
index50k_meta() { awk -v n="$2" '$1 == n { sub(/^[^ ]+ +/, ""); print; exit }' "$1/meta" 2>/dev/null; }

# index50k_cache_state <dir> : prints `fresh`, `stale: <why>` or `none`; status 0, 1, 2.
index50k_cache_state() {
  local dir="$1" ver src name size sha
  [ -f "$dir/index.sqlite" ] || { echo none; return 2; }
  ver="$(index50k_meta "$dir" saved_version)"
  src="$(index50k_meta "$dir" vector_source)"
  if [ "$ver" != "$R_VERSION" ]; then echo "stale: the cache was built for saved version ${ver:-unknown}, this run is $R_VERSION"; return 1; fi
  if [ -z "$src" ]; then echo "stale: the cache records no vector_source"; return 1; fi
  while read -r name size sha; do
    case "$src" in *"$name"*) ;; *) echo "stale: the cache's vector_source \"$src\" does not name the model file $name"; return 1 ;; esac
  done < <(kit_models)
  echo fresh
  return 0
}

# index50k_restore : a reset, the fixtures the picks need, and the cached index copied into the throwaway home.
index50k_restore() {
  local dir sesame="$KIT_ROOT/home/Library/Application Support/Sesame"
  dir="$(index50k_dir)"
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build repos || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build filler 50000 || return $?
  mkdir -p -m 700 "$sesame" || return 1
  cp "$dir"/index.sqlite* "$sesame"/ || return 1
  echo "restored from cache $dir"
}

index50k_app() {
  local list PK_WAIT="${KIT_PICK_WAIT:-600}"
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  list="$(golden_pick_list "$KIT_LIB/golden-roots.tsv")" || { printf '%s\n' "$list"; return 4; }
  pick_folders $list filler "$KIT_ROOT/home/Developer/api-client" || return $?
  setup_finish || return $?
  settings_open || return $?
  settings_start || return $?
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 7200 || return $?
  wait_menu_ready 120 || return $?
  printf 'index50k\n' > "$KIT_ROOT/run/recipe" || return 1
  echo "index50k ready: the real index is restored, indexing is done and the menu bar says Ready"
}

# index50k_launch : a fresh launch on the restored index (the S2 readings that need a mix on top start each one from here). It reads the run's id and
# version itself: a check calls it inside $(...), where a recipe_state of the caller is not seen.
index50k_launch() {
  recipe_state || return $?
  index50k_restore || return $?
  index50k_app
}

# index50k_need : status 0 when the app is running in the plain state `index50k`; else the cache is restored and the app started
# (`recipe_index50k --restore-only`: a check never builds the hours-long cache, a missing or stale one is exit 4).
index50k_need() {
  local state
  state="$(head -1 "$KIT_ROOT/run/recipe" 2>/dev/null)"
  if [ "$state" = index50k ] && kit_need_ps >/dev/null 2>&1 && [ -n "$(kit_pid_of app)" ]; then return 0; fi
  recipe_index50k --restore-only
}

# index50k_build : the long part. After a reset the real helper (no --fake-embedder, the real model) indexes the golden fixture, api-client
# and the filler, run again until nothing is pending or three runs in a row add no row. Fewer than 50,000 rows is
# exit 4. The finished index goes to cache/index50k-real-<V>.new/ with its meta file and replaces the old cache only when it is whole.
index50k_build() {
  local dir out n vsrc run=0 before=-1 stuck=0 rc new
  dir="$(index50k_dir)"; new="$dir.new"
  if [ ! -x "$KIT_HELPER_EXE" ]; then
    echo "no SesameHelper in the bundle copy $KIT_HELPER_EXE: run scripts/kit-reset.sh after scripts/bundle.sh"
    return 4
  fi
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  helper_has_index_mode || { echo "helper has no index mode yet"; return 1; }
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build repos || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build filler 50000 || return $?
  while [ "$run" -lt 200 ]; do
    run=$((run + 1))
    kq "$KIT_SCRIPTS/kit-launch.sh" helper index --folders golden filler --read-folders home/Developer/api-client || { echo "the helper did not finish (run $run)"; return 1; }
    out="$(kq "$KIT_SCRIPTS/kit-index.sh" rows 2>&1)"
    n="$(printf '%s\n' "$out" | awk '$1 == "rows" { print $2 }')"
    case "$n" in ""|*[!0-9]*) echo "index rows unreadable: $out"; return 4 ;; esac
    echo "index50k run $run: rows $n"
    kq "$KIT_SCRIPTS/kit-index.sh" wait done 30 >/dev/null 2>&1 && break
    if [ "$n" -le "$before" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    before="$n"
    [ "$stuck" -lt 3 ] || { echo "the helper added no row in 3 runs (rows $n)"; return 4; }
  done
  if [ "$n" -lt 50000 ]; then
    echo "the index holds $n rows, fewer than 50,000: not a pass, rerun with more filler"
    return 4
  fi
  vsrc="$(kq "$KIT_SCRIPTS/kit-index.sh" meta vector_source 2>&1)"; rc=$?
  if [ $rc != 0 ] || [ -z "$vsrc" ]; then echo "the index has no readable vector_source: $vsrc"; return 4; fi
  rm -rf "$new"
  mkdir -p "$new" || return 1
  cp "$KIT_ROOT/home/Library/Application Support/Sesame"/index.sqlite* "$new"/ || return 1
  printf 'saved_version %s\nvector_source %s\nrows %s\nbuilt %s\n' "$R_VERSION" "$vsrc" "$n" "$(date '+%Y-%m-%d %H:%M:%S')" > "$new/meta" || return 1
  rm -rf "$dir"
  mv "$new" "$dir" || return 1
  echo "index50k built: rows $n, vector_source $vsrc, kept in $dir"
}

# index50k [--restore-only] : the closing pass's 50,000-row index. A cache that is fresh for this saved version and vector_source is restored
# without indexing ("restored from cache"); a stale one is refused ("stale: <why>"), never reused, and rebuilt (--restore-only: exit 4
# instead); none at all is built (--restore-only: exit 4). The first line says it is long.
recipe_index50k() {
  local only=0 dir st rc
  case "${1:-}" in "") ;; --restore-only) only=1 ;; *) usage; return 2 ;; esac
  [ $# -le 1 ] || { usage; return 2; }
  [ "$only" = 1 ] || echo "LONG: this build takes hours"
  recipe_state || return $?
  dir="$(index50k_dir)"
  st="$(index50k_cache_state "$dir")"; rc=$?
  case $rc in
    0) ;;
    1) echo "$st"
       [ "$only" = 0 ] || return 4
       echo "the stale cache is refused and rebuilt"
       index50k_build || return $?
       ;;
    *) if [ "$only" = 1 ]; then echo "no cache for saved version $R_VERSION in $dir"; return 4; fi
       index50k_build || return $?
       ;;
  esac
  index50k_restore || return $?
  index50k_app
}

# ---- setup --------------------------------------------------------------------------------------

# setup [--trace <name>] : the first run of S6. A fresh state with the model coming from the mirror at 500,000 bytes a
# second, the throwaway home's five folders, the repo and the golden and extra folders built (after the reset, which
# empties home/, and before the app starts), the file trace <name> started before the app when --trace is given
# (kit-trace.sh needs the administrator session; a missing one is NEEDS A PERSON, exit 3), then the app. Nothing is
# picked and Start indexing is not pressed: the setup window is the state.
recipe_setup() {
  local trace=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --trace) [ $# -ge 2 ] || { usage; return 2; }; trace="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  recipe_state || return $?
  recipe_reset mirror || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build homefolders || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build extra || return $?
  kq "$KIT_SCRIPTS/kit-mirror.sh" start || return $?
  kq "$KIT_SCRIPTS/kit-mirror.sh" rate 500000 || return $?
  [ -n "$trace" ] && { kq "$KIT_SCRIPTS/kit-trace.sh" start "$trace" || return $?; }
  kq "$KIT_SCRIPTS/kit-launch.sh" start --mirror || return $?
  wait_setup_window 8 || return $?
  echo "setup ready: mirror at 500000 bytes a second, home folders built, app started, nothing picked, Start indexing not pressed${trace:+, trace $trace running}"
}

# ---- minimix ------------------------------------------------------------------------------------

# minimix [--no-start] : the photos-only mini mix (400 generated photos, fixtures/minimix) picked through the picker
# with the model from the cache, so the setup window shows its counts and estimate. Start indexing is pressed unless
# --no-start is given (a check that reads the estimate first presses it itself). Mirrors the `photos` recipe up to the pick.
recipe_minimix() {
  local nostart=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-start) nostart=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  recipe_state || return $?
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build minimix || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  pick_folders minimix || return $?
  [ "$nostart" = 1 ] || press_start || return $?
  [ "$nostart" = 1 ] && echo "minimix picked, Start indexing not pressed (--no-start)"
  return 0
}

# ---- mix500 and pauselong (plan 5) --------------------------------------------------------------

# mix500 [--no-start] : the 500-file mix (fixtures/mix500: photos, documents, PDFs, audio and video, no code) picked through the picker with
# the model from the cache, so the setup window shows its counts and estimate (S6.11). Start indexing is pressed unless --no-start is given.
# Mirrors the recipe `minimix`; the mix has five subfolders, so the picker adds the folder itself.
recipe_mix500() {
  local nostart=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-start) nostart=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  recipe_state || return $?
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build mix500 || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  pick_folders mix500 || return $?
  [ "$nostart" = 1 ] || press_start || return $?
  [ "$nostart" = 1 ] && echo "mix500 picked, Start indexing not pressed (--no-start)"
  return 0
}

# pauselong_folder <pdf|audio|video> : the folder under the fixture root that holds that long unit alone (S7.2); status 2 for another name.
pauselong_folder() {
  case "$1" in
    pdf|audio|video) printf 'pauselong/%s\n' "$1" ;;
    *) return 2 ;;
  esac
}

# pauselong <pdf|audio|video> : one long unit (the 60-page PDF, the 60-minute audio clip, the 2-minute video) picked alone through the picker
# with the model from the cache and Start indexing pressed, so that unit is the only one in flight (S7.2).
recipe_pauselong() {
  local folder
  folder="$(pauselong_folder "${1:-}")" || { usage; return 2; }
  [ $# -eq 1 ] || { usage; return 2; }
  recipe_state || return $?
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build pauselong || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  pick_folders "$folder" || return $?
  press_start || return $?
  echo "pauselong $1: $folder picked and indexing started, the only unit in flight"
}

# ---- tree ---------------------------------------------------------------------------------------

tree_pick_list() {
  local csv="${1:-}" tsv="$KIT_LIB/tree.tsv" out rc
  [ -f "$csv" ] || { echo "tree_pick_list: no table: $csv"; return 1; }
  [ -f "$tsv" ] || { echo "tree_pick_list: no tree.tsv: $tsv"; return 1; }
  out="$(awk -F, -v tsv="$tsv" '
    function note(folder) { if (folder != "") picked[folder] = 1 }
    BEGIN {
      while ((getline line < tsv) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, fld, "\t"); split(fld[1], p, "/")
        if (p[1] != "" && p[1] != "never-picked") tree[p[1]] = 1
      }
    }
    NR == 1 { next }
    NF == 0 { next }
    {
      n = split($2, a, "/"); top = a[1]
      if ($3 == "-") { dash[top] = 1; next }
      if ($3 == "") { note(top); next }
      m = split($3, pick, "|")
      for (i = 1; i <= m; i++) {
        if (pick[i] == "" || index(pick[i], ":") > 0) {
          print "tree_pick_list: \"" pick[i] "\" is not a plain folder, a pick carries no tick" > "/dev/stderr"; bad = 1; continue
        }
        note(pick[i])
      }
    }
    END {
      for (d in dash) for (f in picked) if (f == d || index(f, d "/") == 1) {
        print "tree_pick_list: " d " is in no pick (picks -) but another row picks " f > "/dev/stderr"; bad = 1
      }
      if (bad) exit 4
      for (t in tree) print "tree/" t
      for (f in picked) print "matrix/" f
    }' "$csv" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then printf '%s\n' "$out"; return 4; fi
  printf '%s\n' "$out" | sort -u
}

# tree_roots_check <pick list> : the picked roots under fixtures/matrix/ that the setup window lists (setup_folders, real
# paths) equal the matrix/ entries of the pick list, exactly. An extra, a missing or a child spelling (the picker's
# lone-subfolder quirk of folders_hold) is exit 4 and `RERUN picked roots differ from the pick list: <the difference>`.
# The tree/ folders keep plan 1's rule (the folder or its direct subfolder) and are not compared here.
tree_roots_check() {
  local list="$1" mroot want got extra missing diff=""
  mroot="$(real_path "$KIT_ROOT/fixtures/matrix")"
  if [ -z "$mroot" ]; then echo "RERUN picked roots differ from the pick list: there is no matrix folder under $KIT_ROOT/fixtures"; return 4; fi
  want="$(printf '%s\n' "$list" | awk -v r="$mroot" 'index($0, "matrix/") == 1 { print r "/" substr($0, 8) }' | sort -u)"
  got="$(setup_folders)" || { echo "RERUN picked roots differ from the pick list: the setup window cannot be read"; return 4; }
  got="$(printf '%s\n' "$got" | awk -v r="$mroot/" 'index($0, r) == 1' | sort -u)"
  extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed "s|^$mroot/|matrix/|")"
  missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed "s|^$mroot/|matrix/|")"
  [ -z "$extra" ] || diff="extra: $(printf '%s' "$extra" | tr '\n' ' ')"
  [ -z "$missing" ] || diff="${diff:+$diff; }missing: $(printf '%s' "$missing" | tr '\n' ' ')"
  if [ -n "$diff" ]; then
    echo "RERUN picked roots differ from the pick list: $diff"
    return 4
  fi
  echo "the picked roots under matrix/ equal the pick list ($(printf '%s\n' "$want" | awk 'NF { n++ } END { print n + 0 }') folders)"
  return 0
}

# repo_pick_list [<repo-cells.tsv>] : the folders of the two golden repo cells, one path under the kit root a line (home/Developer/<folder>), in
# table order. A pure function. Exit 1 when the table is missing. The cells live in repo-cells.tsv and not in gate-matrix.csv or tree.tsv.
repo_pick_list() {
  local tsv="${1:-$KIT_LIB/repo-cells.tsv}"
  [ -f "$tsv" ] || { echo "repo_pick_list: no table: $tsv"; return 1; }
  awk -F'\t' '/^#/ || NF == 0 { next } { print "home/Developer/" $2 }' "$tsv"
}

recipe_tree() {
  local trace="" list entries rc repos repo_abs f PK_WAIT="${KIT_PICK_WAIT:-600}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --trace) [ $# -ge 2 ] || { usage; return 2; }; trace="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  recipe_state || return $?
  if [ -n "$trace" ]; then
    admin_session || return $?
  fi
  recipe_reset mirror --baseline || return $?
  kq "$KIT_SCRIPTS/kit-mirror.sh" start || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build tree || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build matrix || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build repos || return $?
  list="$(tree_pick_list "$KIT_LIB/gate-matrix.csv" 2>&1)" || { printf '%s\n' "$list"; return 4; }
  entries="$(printf '%s\n' "$list" | tr '\n' ' ')"
  kq "$KIT_SCRIPTS/kit-sums.sh" snapshot sums-before $entries || return $?
  if [ -n "$trace" ]; then
    kq "$KIT_SCRIPTS/kit-trace.sh" start "$trace" --net || return $?
    kq "$KIT_SCRIPTS/kit-net.sh" start "$trace" || return $?
    kq "$KIT_SCRIPTS/kit-net.sh" control "$trace" || return $?
  fi
  kq "$KIT_SCRIPTS/kit-privacy.sh" prompts start s8 || { echo "the prompts watcher did not start: nothing was launched"; return 1; }
  kq "$KIT_SCRIPTS/kit-launch.sh" start --mirror || return $?
  wait_setup_window 8 || return $?
  repos="$(repo_pick_list)" || { printf '%s\n' "$repos"; return 4; }
  repo_abs=""
  for f in $repos; do repo_abs="$repo_abs $KIT_ROOT/$f"; done
  pick_folders $entries $repo_abs || return $?
  tree_roots_check "$list" || return $?
  setup_finish || return $?
  settings_open || return $?
  settings_start || return $?
  kq "$KIT_SCRIPTS/kit-index.sh" wait rising 60 || return $?
  if [ -n "$trace" ]; then
    kq "$KIT_SCRIPTS/kit-net.sh" control "$trace" || return $?
    kq "$KIT_SCRIPTS/kit-index.sh" wait done 1; rc=$?
    if [ $rc = 0 ]; then
      echo "RERUN second plant not mid-indexing: indexing was already done when plant 2 was made"
      return 4
    fi
    [ $rc = 1 ] || return $rc
  fi
  printf 'tree %s\n' "${trace:--}" > "$KIT_ROOT/run/recipe" || return 1
  echo "tree ready: ${trace:+trace $trace and both observers running, }prompts watcher s8 running, pick list picked, indexing started"
}

# tree_trace_name : the trace name `run/recipe` holds (`tree <name>`), nothing for `tree -` or no recipe.
tree_trace_name() { awk 'NR == 1 && $1 == "tree" && $2 != "-" { print $2 }' "$KIT_ROOT/run/recipe" 2>/dev/null; }

# tree_window_note <check id> : appends the id to run/window-ids while the observers are open (a recipe with a trace, and
# run/observers-closed-at not written yet): S8.7 prints which ids ran inside the observed window.
tree_window_note() {
  [ -n "${1:-}" ] || return 0
  [ -n "$(tree_trace_name)" ] || return 0
  [ -f "$KIT_ROOT/run/observers-closed-at" ] && return 0
  printf '%s\n' "$1" >> "$KIT_ROOT/run/window-ids"
}

# tree_need [<check id>] : does nothing when run/recipe holds `tree`; else runs `recipe_tree --trace s8` when `sudo -n true`
# holds (it never asks for a password) and `recipe_tree` with no trace when it does not, so `kit-run.sh S8 --ids ...` and `all`
# work with no manual prep. A check passes its id so the window note is kept (S8.5, S8.6 and S2.17 run inside the window when
# called before the first reader).
tree_need() {
  if [ "$(awk 'NR == 1 { print $1 }' "$KIT_ROOT/run/recipe" 2>/dev/null)" != tree ]; then
    if sudo -n true 2>/dev/null; then recipe_tree --trace s8 || return $?; else recipe_tree || return $?; fi
  fi
  tree_window_note "${1:-}"
}

overlap_pick_list() {
  local csv="${1:-}" out rc
  [ -f "$csv" ] || { echo "overlap_pick_list: no table: $csv"; return 1; }
  out="$(awk -F, '
    NR == 1 || NF == 0 { next }
    $2 !~ /^ov-/ { next }
    {
      m = split($3, pick, "|")
      for (i = 1; i <= m; i++) {
        if (pick[i] == "" || index(pick[i], ":") > 0) {
          print "overlap_pick_list: \"" pick[i] "\" is not a plain folder, a pick carries no tick" > "/dev/stderr"; bad = 1; continue
        }
        folder[pick[i]] = 1
      }
    }
    END {
      if (bad) exit 4
      for (f in folder) print "matrix/" f
    }' "$csv" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then printf '%s\n' "$out"; return 4; fi
  printf '%s\n' "$out" | LC_ALL=C sort -u
}

# settings_open : status 0 once the Settings window answers (kit-ax.sh dump settings), opened from the status item's menu when it does
# not (pressed at tries 1 and 5); 3 a person step (printed); 1 it never did (one line says why).
settings_open() {
  local out rc i
  for ((i = 1; i <= 8; i++)); do
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump settings 2>&1 </dev/null)"; rc=$?
    [ $rc = 0 ] && return 0
    if [ $rc = 3 ]; then printf '%s\n' "$out"; return 3; fi
    [ $i != 1 ] && [ $i != 5 ] || kq "$KIT_SCRIPTS/kit-ax.sh" click "Settings…" >/dev/null 2>&1
    sleep 1
  done
  if kit_screen_locked; then kit_say_locked; return 3; fi
  echo "no Settings window: kit-ax.sh dump settings said \"$(printf '%s\n' "$out" | tail -1)\""
  return 1
}

# ---- golden -------------------------------------------------------------------------------------

# golden_pick_list <table> : the folders the recipe `golden` picks, one path under the fixture root a line, in table order. The table
# (scripts/kit-lib/golden-roots.tsv, written by hand) is `<folder><TAB><its subfolders, comma separated>`: a folder with exactly one
# subfolder is listed twice, the folder and then `<folder>/<subfolder>`, because the picker adds that lone subfolder when the folder is
# typed into Go to folder (see folders_hold; this is how `golden golden/photos` is picked by the recipe `photos`); a folder with two
# subfolders or none is added as itself, so it is listed once. A pure function. Status 1 when the table is missing.
golden_pick_list() {
  local table="${1:-}"
  [ -f "$table" ] || { echo "golden_pick_list: no table: $table"; return 1; }
  awk -F'\t' '
    /^#/ || NF == 0 || $1 == "" { next }
    { print $1; n = ($2 == "") ? 0 : split($2, s, ","); if (n == 1) print $1 "/" s[1] }' "$table"
}

# golden_roots_diff <real fixtures root> <pick list> <rows> : the rows of the setup window (real paths) under the fixtures root compared
# with the pick list. An extra row is one that no entry of the list names; a missing entry is one that no row equals or sits under (the
# picker's lone-subfolder spelling of `golden` is `golden/photos`, which is an entry of its own). Prints `extra: <paths>; missing:
# <paths>` (relative to the root) and returns 1 when they differ, prints nothing and returns 0 when they agree. Rows outside the root
# are not looked at. A pure function.
golden_roots_diff() {
  local root="${1%/}" list="$2" rows="$3"
  { printf '%s\n' "$list" | sed 's/^/L /'; printf '%s\n' "$rows" | sed 's/^/R /'; } | awk -v r="$root/" '
    $1 == "L" { sub(/^L /, ""); if ($0 != "") { want[$0] = 1; order[++n] = $0 }; next }
    $1 == "R" { sub(/^R /, ""); if (index($0, r) == 1) rows[++m] = substr($0, length(r) + 1) }
    END {
      for (i = 1; i <= m; i++) if (!(rows[i] in want)) extra = extra (extra == "" ? "" : " ") rows[i]
      for (i = 1; i <= n; i++) {
        e = order[i]; found = 0
        for (j = 1; j <= m; j++) if (rows[j] == e || index(rows[j], e "/") == 1) found = 1
        if (!found) missing = missing (missing == "" ? "" : " ") e
      }
      if (extra != "") out = "extra: " extra
      if (missing != "") out = out (out == "" ? "" : "; ") "missing: " missing
      if (out != "") { print out; exit 1 }
    }'
}

# golden_roots_check <pick list> : the folders the setup window lists under the fixtures root equal the pick list (golden_roots_diff),
# as tree_roots_check does for the matrix. A difference is exit 4 and `RERUN picked roots differ from the pick list: <the difference>`.
golden_roots_check() {
  local list="$1" froot rows diff
  froot="$(real_path "$KIT_ROOT/fixtures")"
  if [ -z "$froot" ]; then echo "RERUN picked roots differ from the pick list: there is no fixtures folder under $KIT_ROOT"; return 4; fi
  rows="$(setup_folders)" || { echo "RERUN picked roots differ from the pick list: the setup window cannot be read"; return 4; }
  diff="$(golden_roots_diff "$froot" "$list" "$rows")"
  if [ -n "$diff" ]; then echo "RERUN picked roots differ from the pick list: $diff"; return 4; fi
  echo "the picked roots equal the pick list ($(printf '%s\n' "$list" | awk 'NF { n++ } END { print n + 0 }') folders)"
  return 0
}

# golden [--hold-start] : the state of the S3 checks (feature map S3, verify.md Recipes: `photos` with every golden kind present). A fresh
# state with the model from the cache, the photos (golden/), the PDFs and documents (golden-docs/) and the three boundary PDFs
# (boundary/) built and picked through the picker with code off, Start indexing pressed, then the wait for done and for the menu's Ready;
# run/recipe says `golden`. With --hold-start it stops before Start indexing and run/recipe says `golden hold` (S3.6 presses Start
# itself while it watches the menu say Indexing). It is the whole-folder state, never kit-golden.sh prepare's photo-only one, and the
# recipe `photos` is not changed.
recipe_golden() {
  local hold=0 list
  while [ $# -gt 0 ]; do
    case "$1" in
      --hold-start) hold=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  recipe_state || return $?
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-docs || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build boundary || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build golden-av || return $?
  list="$(golden_pick_list "$KIT_LIB/golden-roots.tsv")" || { printf '%s\n' "$list"; return 4; }
  pick_folders $list || return $?
  golden_roots_check "$list" || return $?
  if [ "$hold" = 1 ]; then
    printf 'golden hold\n' > "$KIT_ROOT/run/recipe" || return 1
    echo "golden held: the roots are picked, Start indexing is not pressed (--hold-start)"
    return 0
  fi
  press_start || return $?
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 7200 || return $?
  wait_menu_ready 120 || return $?
  printf 'golden\n' > "$KIT_ROOT/run/recipe" || return 1
  echo "golden ready: the four roots are indexed and the menu bar says Ready"
}

# golden_release : a held `golden` state goes on: Start indexing pressed, done, Ready, run/recipe `golden`.
golden_release() {
  press_start || return $?
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 7200 || return $?
  wait_menu_ready 120 || return $?
  printf 'golden\n' > "$KIT_ROOT/run/recipe" || return 1
  echo "golden ready: Start indexing was pressed, indexing is done and the menu bar says Ready"
}

golden_need() {
  local hold=0 state
  case "${1:-}" in
    "") ;;
    --hold) hold=1 ;;
    *) usage; return 2 ;;
  esac
  [ $# -le 1 ] || { usage; return 2; }
  state="$(head -1 "$KIT_ROOT/run/recipe" 2>/dev/null)"
  if [ "$hold" = 1 ]; then
    [ "$state" = "golden hold" ] && return 0
    recipe_golden --hold-start
    return $?
  fi
  [ "$state" = golden ] && return 0
  if [ "$state" = "golden hold" ]; then golden_release; return $?; fi
  recipe_golden
}

recipe_overlap() {
  local list PK_WAIT="${KIT_PICK_WAIT:-600}"
  [ $# -eq 0 ] || { usage; return 2; }
  recipe_state || return $?
  models_check "$KIT_ROOT/cache" || return $?
  recipe_reset cache || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_setup_window 8 || return $?
  kq "$KIT_SCRIPTS/kit-fixtures.sh" build matrix || return $?
  list="$(overlap_pick_list "$KIT_LIB/gate-matrix.csv")" || { printf '%s\n' "$list"; return 4; }
  pick_folders $list || return $?
  setup_finish || return $?
  settings_open || return $?
  settings_start || return $?
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 7200 || return $?
  wait_menu_ready 120 || return $?
  printf 'overlap\n' > "$KIT_ROOT/run/recipe" || return 1
  echo "overlap ready: the four pairs are picked, indexing is done and the menu bar says Ready"
}

# overlap_need : the starting state of S5.15. Nothing when run/recipe holds exactly `overlap`; any other state runs recipe_overlap. The
# recipe's status comes back (3 NEEDS A PERSON, 4 not valid, ...).
overlap_need() {
  [ "$(head -1 "$KIT_ROOT/run/recipe" 2>/dev/null)" = overlap ] && return 0
  recipe_overlap
}

CODE_EXTS="swift py js ts tsx jsx go rs java kt c h cpp rb sh"

code_ext_rows() {
  awk -v exts="$CODE_EXTS" 'BEGIN { n = split(exts, e, " ") } { for (i = 1; i <= n; i++) if (tolower($0) ~ ("\\." e[i] "($|[^a-z0-9])")) { print; next } }'
}

recipe_upgrade() {
  local sup="$KIT_ROOT/home/Library/Application Support/Sesame" rows
  [ $# -eq 0 ] || { usage; return 2; }
  recipe_state || return $?
  if [ ! -f "$sup/index.sqlite" ] || [ ! -f "$sup/settings.json" ]; then
    echo "no old state: $KIT_ROOT/home holds no index.sqlite and settings.json made by another build; the old kit makes them with the kept bundle (batch S9, first line)"
    return 4
  fi
  kit_need_bundle || return 4
  rows="$(kq "$KIT_SCRIPTS/kit-index.sh" under "$KIT_ROOT/home/Developer/api-client" | code_ext_rows | awk 'END { print NR + 0 }')"
  if [ "$rows" -lt 1 ]; then
    echo "the old index holds no code row under home/Developer/api-client: the state was not made by the old build with code on (batch S9, first line)"
    return 4
  fi
  mkdir -p "$KIT_ROOT/run" || return 1
  printf '%s\n' "$rows" > "$KIT_ROOT/run/upgrade-code-rows" || return 1
  kq "$KIT_SCRIPTS/kit-index.sh" settings > "$KIT_ROOT/run/upgrade-old-settings" || return 1
  kq "$KIT_SCRIPTS/kit-launch.sh" stop >/dev/null 2>&1
  kq "$KIT_SCRIPTS/kit-reset.sh" --keep-home || return $?
  kq "$KIT_SCRIPTS/kit-launch.sh" start || return $?
  wait_menu_ready 120 || return $?
  printf 'upgrade\n' > "$KIT_ROOT/run/recipe" || return 1
  echo "upgrade ready: the old home is kept with $rows code rows, the current bundle is in apps/, the app started and the menu bar says Ready"
}

recipe_main() {
  local r="${1:-}"
  [ $# -gt 0 ] && shift
  case "$r" in
    fresh-throttled) [ $# -eq 0 ] || { usage; return 2; }; recipe_fresh_throttled ;;
    photos) recipe_photos "$@" ;;
    busy50k) [ $# -eq 0 ] || { usage; return 2; }; recipe_busy50k ;;
    setup) recipe_setup "$@" ;;
    minimix) recipe_minimix "$@" ;;
    tree) recipe_tree "$@" ;;
    golden) recipe_golden "$@" ;;
    mix500) recipe_mix500 "$@" ;;
    pauselong) recipe_pauselong "$@" ;;
    overlap) recipe_overlap "$@" ;;
    upgrade) recipe_upgrade "$@" ;;
    index50k) recipe_index50k "$@" ;;
    *) usage; return 2 ;;
  esac
}

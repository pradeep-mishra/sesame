#!/bin/bash
# kit-ax.sh <mode>: the accessibility driver (verify.md, Surfaces and drivers).
#
# It drives and reads the app the way a person does: System Events (osascript, kit-lib/ax.applescript)
# for the accessibility tree, the Swift key-event tool (kit-lib/keytool.swift, CGEvent) for typing and
# shortcuts at real speed, and screencapture for pictures. It never reads or writes the app's memory,
# its settings or its index. The app is the process named Sesame that the kit started.
#
# What it never does to the person's own machine (the person's rules for this driver):
#   - a picture is of ONE window (Sesame's, or with an explicit --app the named app's front window),
#     never the whole screen; with no such window it prints "no Sesame window" and exits 1;
#   - `key` posts only while the kit's Sesame is the frontmost app; `hotkey` only while that or a window
#     the kit made (`kitwindow open`) is frontmost; `type`, `paste` and `tab-walk` only while their
#     target (Sesame, or with --kit-window the kit's window) is frontmost; otherwise "refused: ..." exit 1;
#     `type` also re-checks that every 8 characters and before its --then key, and stops with exit 4 if the focus moved;
#     the one thing done about a lost focus: `hotkey` and `kitwindow open` raise the kit's OWN window by its pid
#     (up to 3 raises, 1 s apart, printed) when another app has the focus and a kit window exists; no other
#     app is ever raised, and a key is never posted to an app other than Sesame or the kit window; the one other
#     raise is `front-sesame`, which raises the kit's own Sesame by its pid so the folder picker can be driven;
#   - nothing changes the system appearance for good (`appearance light|dark` puts the old look back in
#     the same call unless --keep) and nothing quits an app the kit did not start;
#   - `fullscreen` drives only Sesame and the kit's own window.
# `--kit-window` before the mode points type, paste, click, read, dump, tab-walk, hotkey and shot at the
# kit's own window (`kitwindow open`) instead of Sesame, so the driver can be tried with no Sesame at all.
#
#   ping                       the frontmost app's name (so Accessibility and Automation work)
#   frontmost                  the same name
#   appearance light|dark [--keep]
#                              sets the system look, reads it back, then puts the previous look back in the
#                              same call; --keep leaves it set (appearance restore puts it back)
#   appearance get|restore     prints light or dark | restores a look that --keep left
#   shot <name> [--panel] [--app <name>]
#                              a PNG of one window in the evidence folder (shot-<name>.png, never
#                              overwriting an older one) with a not-blank check
#   shot <name> --selftest     the same on a window the kit makes itself, plus a flat one that must read blank
#   kitwindow open [--flat]|close|status
#                              the kit's own test window (process kitwindow; closes by itself after 15 min)
#   hotkey ["<combo>"]         posts the shortcut (default ctrl+opt+space), says if the panel appeared
#   key "<combo>"              posts the chord: "posted <combo>"
#   type "<text>" [--delay-ms N] [--then <combo>]
#                              types the text key by key: "typed <n> characters"; the per-key delay is
#                              --delay-ms N, else the environment KIT_TYPE_DELAY_MS (whole ms, 0 to 500;
#                              an invalid value is ignored with one warning on stderr), else 10 ms.
#                              The target must stay frontmost: it is re-checked, by pid, every 8 characters and
#                              before the --then combination; if it is not, nothing more is posted, "refused: ..."
#                              is printed and the exit code is 4 (round C, F20)
#   paste "<text>"             saves the pasteboard (every item and type, in memory), puts the text on it, posts
#                              Command+V (the focus is read again right before it), then puts the saved pasteboard
#                              back, also when a step fails or the call is interrupted: "pasted <n> characters".
#                              Not restored, with a line saying so, when something else was copied meanwhile; a
#                              pasteboard over 16 MB is not touched and nothing is pasted, exit 4 (round C, F21)
#   front-sesame               brings the kit's own Sesame (its pid, from the kit's process tree) to the front: up
#                              to 3 raises, 1 s apart, until `frontmost` reads Sesame; no other app is raised
#   gotofolder "<path>"        sets the field of the folder picker's Go to the folder sheet (a Sesame window's
#                              sheet) to the path through the accessibility value and reads it back, only while
#                              Sesame is frontmost; the sheet takes no typed keys. Posts no key.
#   click "<label>"            presses the element with that visible label: a control of a window (setup, Settings,
#                              the panel) or an item of the status item's menu ("Pause indexing", "Resume indexing",
#                              "Open Sesame", "Settings…", "Quit Sesame", or in Settings "Launch at login", "Delete
#                              index…", in setup "Add folder…", "Next", "Back", "Finish", "Start indexing"). The
#                              status item is pressed to open its menu; a screen position is never used
#   click --help "<help>" "<label>"
#                              presses the control with that label whose accessibility help is exactly <help>
#                              and nothing else (the status item's menu is not tried). A folder row's Re-index and
#                              Remove carry the folder's name as help, so `click --help "extra" "Remove"` presses the
#                              Remove of the row of the folder extra, never the first Remove of the window
#   read panel|windows|focus|menubar
#                              menubar: the status item's accessibility label ("status item: <label>")
#   dump panel|setup|settings|menu|window "<title>"|menubar
#                              the window's element tree (role, label, value, focus, selection); menu: the open
#                              status item menu's items with [disabled] where an item is greyed out. The menu is
#                              opened for the read and put away again afterwards (accessibility cancel, then Esc
#                              through the key guard if it is still open)
#   tab-walk <window>          presses Tab, one line per control reached; <window> as for dump (setup, settings,
#                              panel, window "<title>"), or `menu`: opens the status item menu and walks its
#                              enabled items with the Down key, then puts the menu away
#   fullscreen <app> on|off    Sesame or kitwindow only: sets the full-screen state of its window, then waits up
#                              to 6 s until `frontmost` reads that app again (the Space switch shows Finder for
#                              a moment) and prints how long it waited; exit 1 if it never does
#   (shot --panel on a blank picture: a control picture of a kit window of known colour says EMPTY PANEL,
#    exit 0, when pictures work, or SCREEN RECORDING NOT GRANTED, exit 3, when they do not)
# Exit codes: 0 done; 1 a check failed, a refusal, or the driver errored; 2 usage; 3 a person-step is
# missing (NEEDS A PERSON: ...); 4 a precondition did not hold.
. "$(dirname "$0")/kit-lib/common.sh"

AX_APP="Sesame"
AX_KIT=0
KITWIN="kitwindow"

usage() {
  cat >&2 <<'EOF'
usage: kit-ax.sh [--kit-window] <mode>
       kit-ax.sh ping
       kit-ax.sh frontmost
       kit-ax.sh appearance light|dark [--keep]
       kit-ax.sh appearance get|restore
       kit-ax.sh shot <name> [--panel] [--app <name>]
       kit-ax.sh shot <name> --selftest
       kit-ax.sh kitwindow open [--flat]|close|status
       kit-ax.sh hotkey ["<combo>"]
       kit-ax.sh key "<combo>"
       kit-ax.sh type "<text>" [--delay-ms N] [--then <combo>]
       (type delay: --delay-ms N, else env KIT_TYPE_DELAY_MS=0..500 ms, else 10 ms)
       kit-ax.sh paste "<text>"
       kit-ax.sh front-sesame
       kit-ax.sh gotofolder "<path>"
       kit-ax.sh click "<label>"
       kit-ax.sh click --help "<help>" "<label>"
       kit-ax.sh read panel|windows|focus|menubar
       kit-ax.sh dump panel|setup|settings|menu|window "<title>"|menubar
       kit-ax.sh tab-walk panel|setup|settings|menu|window "<title>"
       kit-ax.sh fullscreen Sesame|kitwindow on|off
EOF
}

TERMINAL="${TERM_PROGRAM:-the terminal app that runs the checks}"

# ---- permissions and the two drivers ---------------------------------------------------------

needs_accessibility() {
  echo "NEEDS A PERSON: Accessibility for this terminal"
  echo "how: System Settings, Privacy and Security, Accessibility, turn on $TERMINAL"
}

needs_automation() {
  echo "NEEDS A PERSON: Automation for System Events"
  echo "how: System Settings, Privacy and Security, Automation, allow $TERMINAL to control System Events"
}

needs_screen() {
  echo "NEEDS A PERSON: Screen Recording for this terminal"
  echo "how: System Settings, Privacy and Security, Screen Recording, turn on $TERMINAL"
}

tool_missing() { echo "the kit's Swift tool $1 did not compile; see $KIT_ROOT/run/bin/$1.log"; }

# need_ax: status 0 when Accessibility is granted to this terminal, else 3 (or 1 when the tool is not there).
need_ax() {
  local bin
  bin="$(kit_tool keytool)" || { tool_missing keytool; return 1; }
  if ! "$bin" trusted >/dev/null 2>&1; then
    needs_accessibility
    return 3
  fi
  return 0
}

# osa <command> [args...]: runs kit-lib/ax.applescript for the app. OSA_OUT holds its output, OSA_ERR
# the message of an AppleScript error. Status 0 done, 3 a person-step is missing (already printed),
# 1 an error (OSA_ERR says which).
OSA_OUT=""
OSA_ERR=""
osa() {
  local errf rc
  errf="$(mktemp "$KIT_TMP/kit-ax-err.XXXXXX")" || return 1
  OSA_OUT="$(osascript "$KIT_LIB/ax.applescript" "$AX_APP" "$@" 2>"$errf")"
  rc=$?
  OSA_ERR="$(cat "$errf")"
  rm -f "$errf"
  [ "$rc" = 0 ] && return 0
  case "$OSA_ERR" in
    *"-1743"*|*"Not authorized to send Apple events"*) needs_automation; return 3 ;;
    *"-25211"*|*"-25204"*|*"assistive access"*) needs_accessibility; return 3 ;;
    *"Operation not permitted"*|*"sandbox"*)
      echo "blocked: osascript is refused here (${OSA_ERR##*: }); run this from a shell that may script System Events"
      return 1 ;;
  esac
  # "<file>:<n>:<n>: execution error: <message> (<number>)" -> "<message>"
  OSA_ERR="$(printf '%s' "$OSA_ERR" | sed -e 's/^.*execution error: //' -e 's/ ([-0-9]*)$//')"
  return 1
}

# onscreen_windows: "x y w h layer title" of the app's windows that are big enough to be a panel.
onscreen_windows() {
  local bin
  bin="$(kit_tool pixelpoll)" || return 1
  "$bin" windows "$AX_APP" | awk '$3 >= 200 && $4 >= 100'
}

window_count() { onscreen_windows | awk 'END { print NR + 0 }'; }

need_window() {
  if [ -z "$(onscreen_windows)" ]; then
    echo "no $AX_APP window"
    return 1
  fi
  return 0
}

# ---- the kit's own window, and the guards that keep keys away from the person's apps ----------

KITWIN_APP="$KIT_ROOT/run/bin/KitWindow.app"
KITWIN_EXE="$KITWIN_APP/Contents/MacOS/$KITWIN"

# kit_is_kitwindow <pid>: the process is the kit's own kitwindow binary (never just a name match). Launch
# Services reports the real path (/private/var/... for a /var/... folder), so both spellings count.
kit_is_kitwindow() {
  local exe
  [ -n "$1" ] || return 1
  exe="$(ps -p "$1" -o args= 2>/dev/null)"
  exe="${exe%% --*}"
  [ "$exe" = "$KITWIN_EXE" ] || [ "$exe" = "$KIT_ROOT_REAL/run/bin/KitWindow.app/Contents/MacOS/$KITWIN" ]
}

# kitwin_bundle: the kit window as a small app bundle under $KIT_ROOT/run/bin, because macOS only lets an
# app that Launch Services started come to the front. Built from kit-lib/kitwindow.swift when out of date.
kitwin_bundle() {
  local bin
  bin="$(kit_tool "$KITWIN")" || { tool_missing "$KITWIN"; return 1; }
  if [ ! -x "$KITWIN_EXE" ] || [ "$bin" -nt "$KITWIN_EXE" ]; then
    rm -rf "$KITWIN_APP"
    mkdir -p "$KITWIN_APP/Contents/MacOS" || return 1
    cp "$bin" "$KITWIN_EXE" || return 1
    cat > "$KITWIN_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>kitwindow</string>
  <key>CFBundleDisplayName</key><string>kitwindow</string>
  <key>CFBundleExecutable</key><string>kitwindow</string>
  <key>CFBundleIdentifier</key><string>kit.test.window</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign - "$KITWIN_APP" >/dev/null 2>&1 || { echo "could not sign the kit window bundle"; return 1; }
  fi
  return 0
}

kitwin_pidfile() { echo "$KIT_ROOT/run/pids/$KITWIN-$1.pid"; }

# kitwin_pids: one pid per live kit window process (pid files $KIT_ROOT/run/pids/kitwindow-<label>.pid).
kitwin_pids() {
  local f pid
  for f in "$KIT_ROOT"/run/pids/$KITWIN-*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f")"
    kit_is_kitwindow "$pid" && echo "$pid"
  done
  return 0
}

# kitwin_start <label> <flat 0|1|swatch>: starts one kit window; KITWIN_PID and KITWIN_ID say which.
KITWIN_PID=""
KITWIN_ID=""
kitwin_start() {
  local label="$1" flat="$2" pbin pid id i pf
  kitwin_bundle || return 1
  pbin="$(kit_tool pixelpoll)" || { tool_missing pixelpoll; return 1; }
  mkdir -p "$KIT_ROOT/run/pids" || return 1
  pf="$(kitwin_pidfile "$label")"
  rm -f "$pf"
  # The window process writes its own pid to the pid file (open gives none back).
  if [ "$flat" = 1 ]; then
    open -n "$KITWIN_APP" --args --flat --title "Kit flat window" --pidfile "$pf" || { echo "could not start the kit window"; return 1; }
  elif [ "$flat" = swatch ]; then
    open -n "$KITWIN_APP" --args --swatch --pidfile "$pf" || { echo "could not start the kit window"; return 1; }
  else
    open -n "$KITWIN_APP" --args --pidfile "$pf" || { echo "could not start the kit window"; return 1; }
  fi
  pid=""
  for i in $(seq 1 50); do
    [ -s "$pf" ] && { pid="$(cat "$pf")"; break; }
    sleep 0.2
  done
  if [ -z "$pid" ] || ! kit_is_kitwindow "$pid"; then
    echo "the kit window did not start within 10 s"
    rm -f "$pf"
    return 1
  fi
  id=""
  for i in $(seq 1 50); do
    id="$("$pbin" window-id --pid "$pid" --min-w 200 --min-h 100)" && break
    id=""
    sleep 0.2
  done
  if [ -z "$id" ]; then
    kill "$pid" 2>/dev/null
    rm -f "$pf"
    echo "the kit window did not appear within 10 s"
    return 1
  fi
  KITWIN_PID="$pid"
  KITWIN_ID="$id"
  return 0
}

# kitwin_stop <label>: ends that kit window, only if its pid is still the kit's own binary.
kitwin_stop() {
  local pf pid i
  pf="$(kitwin_pidfile "$1")"
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf")"
  if kit_is_kitwindow "$pid"; then
    kill "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kit_is_kitwindow "$pid" || break
      sleep 0.2
    done
    kit_is_kitwindow "$pid" && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$pf"
  return 0
}

# read_front: FRONT_NAME and FRONT_PID of the frontmost app. Status 0, 3 (printed) or 1 (printed).
FRONT_NAME=""
FRONT_PID=""
read_front() {
  local rc
  osa frontinfo; rc=$?
  if [ "$rc" != 0 ]; then
    [ "$rc" = 1 ] && echo "could not read the frontmost app: ${OSA_ERR:-no answer}"
    return "$rc"
  fi
  FRONT_NAME="${OSA_OUT%%$'\t'*}"
  FRONT_PID="${OSA_OUT#*$'\t'}"
  if [ -z "$FRONT_NAME" ]; then echo "could not read the frontmost app: System Events named none"; return 1; fi
  return 0
}

# front_is_sesame: the frontmost app is the Sesame the kit started (name and pid, not the name alone).
front_is_sesame() {
  local pids
  [ "$FRONT_NAME" = Sesame ] || return 1
  pids="$(kit_pid_of app)"
  case $'\n'"$pids"$'\n' in *$'\n'"$FRONT_PID"$'\n'*) return 0 ;; esac
  return 1
}

# front_is_kitwindow: the frontmost app is a window process the kit started.
front_is_kitwindow() {
  local pids
  pids="$(kitwin_pids)"
  case $'\n'"$pids"$'\n' in *$'\n'"$FRONT_PID"$'\n'*) return 0 ;; esac
  return 1
}

# guard_key: `key` posts only while the kit's Sesame is frontmost. Prints the refusal and returns 1.
guard_key() {
  local rc
  kit_need_ps || return 1
  read_front; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  front_is_sesame && return 0
  if [ "$FRONT_NAME" = Sesame ]; then
    echo "refused: the frontmost Sesame (pid $FRONT_PID) is not the copy the kit started ($KIT_APP); no key was posted"
  else
    echo "refused: Sesame is not the frontmost app (the frontmost app is $FRONT_NAME); no key was posted"
  fi
  return 1
}

# raise_kit_front <pid>: brings the kit's own window (by its own pid, the same raise the fullscreen wait uses)
# to the front. Up to 3 raises, 1 s apart; after each one it polls `frontmost` four times (0.25 s) and stops as
# soon as the kit window reads frontmost. Prints what it did. Status 0 frontmost, 1 it never was (FRONT_NAME says
# who is), 3 a person-step is missing. It raises nothing but the kit window and posts no key.
raise_kit_front() {
  local pid="$1" i j rc
  for i in 1 2 3; do
    osa raise "$pid" >/dev/null; rc=$?
    [ "$rc" = 3 ] && return 3
    for j in 1 2 3 4; do
      sleep 0.25
      read_front; rc=$?
      [ "$rc" = 0 ] || return "$rc"
      if front_is_kitwindow; then
        echo "raised the kit window (pid $pid), raise $i of 3: it is frontmost"
        return 0
      fi
    done
    echo "raised the kit window (pid $pid), raise $i of 3: the frontmost app is still $FRONT_NAME"
  done
  return 1
}

# guard_hotkey: `hotkey` posts only while the kit's Sesame or a window the kit made is frontmost. When another
# app (the person's own) has taken the focus and a kit window exists, the kit window is raised first (by its own
# pid, see raise_kit_front); no other app is ever raised and no key is posted to another app.
guard_hotkey() {
  local rc pid was
  kit_need_ps || return 1
  read_front; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  front_is_sesame && return 0
  front_is_kitwindow && return 0
  pid="$(kitwin_pids | head -1)"
  if [ -n "$pid" ]; then
    was="$FRONT_NAME"
    echo "the frontmost app is $was; raising the kit window (pid $pid) before the key is posted"
    raise_kit_front "$pid"; rc=$?
    [ "$rc" = 0 ] && return 0
    [ "$rc" = 3 ] && return 3
    echo "refused: the kit window could not be brought to the front after 3 raises (the frontmost app is $FRONT_NAME); no key was posted"
    return 1
  fi
  echo "refused: the frontmost app is $FRONT_NAME, which is neither Sesame nor a window the kit made; no key was posted"
  echo "hint: scripts/kit-ax.sh kitwindow open puts a window the kit made in front first"
  return 1
}

# need_frontmost_window: typed text and keys go to the frontmost app, so a window of the target is not
# enough: the target (Sesame, or with --kit-window the kit's window) must be the one that receives them.
need_frontmost_window() {
  local rc
  need_window || return 1
  kit_need_ps || return 1
  read_front; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if [ "$AX_KIT" = 1 ]; then front_is_kitwindow && return 0; else front_is_sesame && return 0; fi
  echo "no $AX_APP window"
  echo "(a $AX_APP window is on screen, but the frontmost app is $FRONT_NAME, so the keys would reach it; nothing was posted)"
  return 1
}

# ---- ping, frontmost, appearance -------------------------------------------------------------

cmd_frontmost() {
  local rc
  osa front; rc=$?
  if [ "$rc" != 0 ]; then
    [ "$rc" = 1 ] && [ -n "$OSA_ERR" ] && echo "could not read the frontmost app: $OSA_ERR"
    return "$rc"
  fi
  if [ -z "$OSA_OUT" ]; then echo "could not read the frontmost app: System Events named none"; return 1; fi
  printf '%s\n' "$OSA_OUT"
}

cmd_ping() {
  need_ax || return $?
  cmd_frontmost
}

appearance_from_defaults() {
  if defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then echo dark; else echo light; fi
}

# appearance_now: light or dark. Status 0 with the look in APPEARANCE_NOW, 3 (printed) or 1 (printed).
APPEARANCE_NOW=""
appearance_now() {
  local rc
  osa appearance get; rc=$?
  if [ "$rc" = 0 ]; then APPEARANCE_NOW="$OSA_OUT"; return 0; fi
  [ "$rc" = 3 ] && return 3
  [ -n "$OSA_ERR" ] && echo "could not read the appearance: $OSA_ERR"
  return 1
}

# appearance_put <light|dark>: sets the look and checks it by reading it back. Status 0, 3 or 1 (printed).
appearance_put() {
  local rc
  osa appearance "$1"; rc=$?
  if [ "$rc" != 0 ]; then
    [ "$rc" = 1 ] && [ -n "$OSA_ERR" ] && echo "could not set the appearance: $OSA_ERR"
    return "$rc"
  fi
  if [ "$OSA_OUT" != "$1" ]; then
    echo "asked for $1 but the system look reads $OSA_OUT"
    return 1
  fi
  return 0
}

# appearance light|dark [--keep] sets the look and, in the same call, puts the old look back unless --keep.
# appearance restore puts back the look a --keep call replaced. Setting the look that kit-reset.sh recorded
# at the start is the cleanup's restore, so that one stays set.
cmd_appearance() {
  [ $# -ge 1 ] || { usage; return 2; }
  local what="$1" keep=0 rc prev base before="$KIT_ROOT/run/appearance-before"
  shift
  case "$what" in
    get)
      [ $# = 0 ] || { usage; return 2; }
      osa appearance get; rc=$?
      if [ "$rc" = 0 ]; then printf '%s\n' "$OSA_OUT"; return 0; fi
      # Reading the look needs no permission: the same global preference System Events reads.
      echo "note: System Events was not available, so this is read from the global preference" >&2
      appearance_from_defaults
      return 0 ;;
    restore)
      [ $# = 0 ] || { usage; return 2; }
      if [ ! -f "$before" ]; then echo "nothing to restore: no appearance was kept"; return 0; fi
      prev="$(cat "$before")"
      appearance_put "$prev"; rc=$?
      [ "$rc" = 0 ] || return "$rc"
      rm -f "$before"
      echo "appearance restored to $prev"
      return 0 ;;
    light|dark) ;;
    *) usage; return 2 ;;
  esac
  case "${1:-}" in
    "") ;;
    --keep) keep=1; [ $# = 1 ] || { usage; return 2; } ;;
    *) usage; return 2 ;;
  esac
  appearance_now; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  prev="$APPEARANCE_NOW"
  if [ "$prev" = "$what" ]; then
    echo "appearance is already $what: left as it is"
    return 0
  fi
  base="$(cat "$KIT_ROOT/run/appearance" 2>/dev/null)"
  appearance_put "$what"; rc=$?
  if [ "$rc" != 0 ]; then
    appearance_put "$prev" >/dev/null 2>&1
    return "$rc"
  fi
  if [ "$keep" = 1 ]; then
    [ -f "$before" ] || printf '%s\n' "$prev" > "$before"
    echo "appearance set to $what and kept (was $prev; scripts/kit-ax.sh appearance restore puts it back)"
    return 0
  fi
  if [ "$what" = "$base" ]; then
    rm -f "$before"
    echo "appearance set to $what, the look recorded at the start of the run"
    return 0
  fi
  appearance_put "$prev"; rc=$?
  if [ "$rc" != 0 ]; then
    echo "the previous look ($prev) could not be put back; set it by hand in System Settings, Appearance"
    return "$rc"
  fi
  echo "appearance set to $what, read back $what, then restored to $prev"
  return 0
}

# ---- the kit's own window ---------------------------------------------------------------------

cmd_kitwindow() {
  [ $# -ge 1 ] || { usage; return 2; }
  local what="$1" flat=0 pids pid n rc f label
  shift
  case "$what" in
    open)
      case "${1:-}" in "") ;; --flat) flat=1; [ $# = 1 ] || { usage; return 2; } ;; *) usage; return 2 ;; esac
      kit_need_ps || return 1
      AX_APP="$KITWIN"; AX_KIT=1
      pids="$(kitwin_pids)"
      if [ -n "$pids" ]; then
        pid="$(printf '%s\n' "$pids" | head -1)"
        echo "kit window already open (pid $pid)"
      else
        kitwin_start main "$flat" || return 1
        pid="$KITWIN_PID"
        echo "kit window open (pid $pid, window $KITWIN_ID)"
      fi
      # Keys posted for it go to the frontmost app, so it is brought to the front (it is the kit's own). A freshly
      # started window gets three short looks to come forward by itself; the person's own apps (Finder, a
      # browser, a terminal) may take the focus at any time, so after that it is raised by its own pid, up to
      # 3 raises 1 s apart (raise_kit_front), and the call exits 0 only once it reads frontmost.
      for n in 1 2 3; do
        read_front; rc=$?
        [ "$rc" = 0 ] || return "$rc"
        front_is_kitwindow && break
        sleep 0.3
      done
      if ! front_is_kitwindow; then
        echo "the frontmost app is $FRONT_NAME; raising the kit window (pid $pid)"
        raise_kit_front "$pid"; rc=$?
        [ "$rc" = 3 ] && return 3
        if [ "$rc" != 0 ]; then
          echo "the kit window is open but not frontmost after 3 raises (the frontmost app is $FRONT_NAME)"
          return 1
        fi
      fi
      # Frontmost is reported a moment before the window takes keys: wait for its field to have focus.
      for n in 1 2 3 4 5 6 7 8 9 10; do
        osa focused >/dev/null; [ -n "$OSA_OUT" ] && break
        sleep 0.3
      done
      sleep 0.5
      echo "kit window is frontmost"
      return 0 ;;
    close)
      [ $# = 0 ] || { usage; return 2; }
      kit_need_ps || return 1
      n=0
      for f in "$KIT_ROOT"/run/pids/$KITWIN-*.pid; do
        [ -f "$f" ] || continue
        label="${f##*/$KITWIN-}"; label="${label%.pid}"
        pid="$(cat "$f")"
        if kit_is_kitwindow "$pid"; then echo "closed kit window (pid $pid)"; n=$((n + 1)); fi
        kitwin_stop "$label"
      done
      [ "$n" = 0 ] && echo "no kit window open"
      return 0 ;;
    status)
      [ $# = 0 ] || { usage; return 2; }
      kit_need_ps || return 1
      pids="$(kitwin_pids)"
      if [ -z "$pids" ]; then echo "no kit window open"; return 1; fi
      printf '%s\n' "$pids" | while read -r pid; do echo "kit window open (pid $pid)"; done
      return 0 ;;
    *) usage; return 2 ;;
  esac
}

# ---- pictures --------------------------------------------------------------------------------

# unique_png <dir> <name>: shot-<name>.png, or shot-<name>-2.png and so on; an older picture is never replaced.
unique_png() {
  local f n=1
  f="$1/shot-$2.png"
  while [ -e "$f" ]; do n=$((n + 1)); f="$1/shot-$2-$n.png"; done
  echo "$f"
}

shot_dir() {
  local dir
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] || dir="$KIT_ROOT/run/shots"
  mkdir -p "$dir" || return 1
  echo "$dir"
}

# shot_selftest <name>: the not-blank check on windows the kit made itself, never the person's screen or apps.
# A busy kit window must read "not blank" and a flat one must read BLANK, so the check can go red.
shot_selftest() {
  local name="$1" dir out flat_out sbin stat prc pid1 id1 pid2 id2 pbin
  pbin="$(kit_tool pixelpoll)" || { tool_missing pixelpoll; return 1; }
  sbin="$(kit_tool pixelstat)" || { tool_missing pixelstat; return 1; }
  if ! "$pbin" screen-trusted >/dev/null 2>&1; then needs_screen; return 3; fi
  kit_need_ps || return 1
  dir="$(shot_dir)" || { echo "could not make the evidence folder"; return 1; }

  kitwin_start shotcontent 0 || return 1
  pid1="$KITWIN_PID"; id1="$KITWIN_ID"
  out="$(unique_png "$dir" "$name")"
  screencapture -x -o -l "$id1" "$out" 2>/dev/null
  kitwin_stop shotcontent
  if [ ! -s "$out" ]; then echo "screencapture wrote no picture of the kit window to $out"; return 1; fi
  stat="$("$sbin" "$out" 2>&1)"; prc=$?
  echo "saved $out (the kit's own window: pid $pid1, window $id1)"
  if [ "$prc" != 0 ]; then
    echo "BLANK: $stat"
    echo "a flat picture of a busy window means Screen Recording is not really granted to $TERMINAL"
    return 1
  fi
  echo "not blank: $stat"

  kitwin_start shotflat 1 || return 1
  pid2="$KITWIN_PID"; id2="$KITWIN_ID"
  flat_out="$(unique_png "$dir" "$name-flat")"
  screencapture -x -o -l "$id2" "$flat_out" 2>/dev/null
  kitwin_stop shotflat
  if [ ! -s "$flat_out" ]; then echo "screencapture wrote no picture of the flat kit window to $flat_out"; return 1; fi
  stat="$("$sbin" "$flat_out" 2>&1)"; prc=$?
  echo "saved $flat_out (the kit's own flat window: pid $pid2, window $id2)"
  if [ "$prc" = 0 ]; then
    echo "SELFTEST not-blank FAIL: a flat kit window did not read blank ($stat), so the check cannot go red"
    return 1
  fi
  echo "control: the flat window reads BLANK ($stat), so the not-blank check can go red"
  echo "SELFTEST not-blank OK"
  return 0
}

# shot <name> [--panel] [--app <name>] | shot <name> --selftest
# One window only: Sesame's front-most window (--panel: its largest), or with --app that app's front-most
# window. screencapture -l takes that window's own pixels, so nothing else on the screen is in the picture.
cmd_shot() {
  [ $# -ge 1 ] || { usage; return 2; }
  local name="$1" panel=0 app="" selftest=0 owner dir out pbin sbin stat rc id
  shift
  case "$name" in ""|*[!A-Za-z0-9._-]*) usage; return 2 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --panel) panel=1; shift ;;
      --selftest) selftest=1; shift ;;
      --app) { [ $# -ge 2 ] && [ -n "$2" ]; } || { usage; return 2; }; app="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [ "$selftest" = 1 ]; then
    { [ "$panel" = 0 ] && [ -z "$app" ]; } || { usage; return 2; }
    shot_selftest "$name"
    return $?
  fi
  owner="${app:-$AX_APP}"
  pbin="$(kit_tool pixelpoll)" || { tool_missing pixelpoll; return 1; }
  if [ "$panel" = 1 ]; then
    id="$("$pbin" window-id --owner "$owner" --largest)"
  else
    id="$("$pbin" window-id --owner "$owner")"
  fi
  if [ -z "$id" ]; then echo "no $owner window"; return 1; fi
  if ! "$pbin" screen-trusted >/dev/null 2>&1; then
    needs_screen
    return 3
  fi
  dir="$(shot_dir)" || { echo "could not make the evidence folder"; return 1; }
  out="$(unique_png "$dir" "$name")"
  screencapture -x -o -l "$id" "$out" || { echo "screencapture failed"; return 1; }
  if [ ! -s "$out" ]; then
    echo "screencapture wrote no picture to $out"
    return 1
  fi
  sbin="$(kit_tool pixelstat)" || { tool_missing pixelstat; return 1; }
  stat="$("$sbin" "$out" 2>&1)"; rc=$?
  echo "saved $out ($owner window $id)"
  if [ "$rc" = 0 ]; then
    echo "not blank: $stat"
    return 0
  fi
  echo "BLANK: $stat"
  if [ "$panel" = 1 ] && [ -z "$app" ]; then
    blank_panel_cause
    return $?
  fi
  echo "a flat picture usually means Screen Recording is not really granted to $TERMINAL"
  return 1
}

# blank_panel_cause: a blank picture of Sesame's panel has two causes that look the same: the panel draws
# nothing (the scaffold panel is empty), or Screen Recording is not really granted. The control tells them
# apart: a picture of a small kit window of a known colour (kitwindow --swatch, #3399CC), taken the same way.
# That picture matching means pictures work, so the blank panel is an empty panel: status 0. Not matching
# means Screen Recording is not granted: status 3. No control picture at all: status 1.
blank_panel_cause() {
  local sbin dir out ctl rc
  sbin="$(kit_tool pixelstat)" || { tool_missing pixelstat; return 1; }
  dir="$(shot_dir)" || { echo "could not make the evidence folder"; return 1; }
  kitwin_start shotswatch swatch || { echo "CONTROL FAILED: the kit's colour window could not be made, so the cause of the blank panel picture is not known"; return 1; }
  out="$(unique_png "$dir" "panel-control")"
  screencapture -x -o -l "$KITWIN_ID" "$out" 2>/dev/null
  kitwin_stop shotswatch
  if [ ! -s "$out" ]; then
    echo "CONTROL FAILED: screencapture wrote no picture of the kit's colour window, so the cause of the blank panel picture is not known"
    return 1
  fi
  ctl="$("$sbin" "$out" --colour 3399CC 2>&1)"; rc=$?
  echo "control picture $out (the kit's own colour window): $ctl"
  if [ "$rc" = 0 ]; then
    echo "EMPTY PANEL: the panel picture is flat because the panel draws nothing (the scaffold panel is empty); Screen Recording is granted, the control picture of the kit's window shows its known colour"
    return 0
  fi
  echo "SCREEN RECORDING NOT GRANTED: the control picture of the kit's own window did not show its known colour, so the blank panel picture proves nothing"
  needs_screen
  return 3
}

# ---- keys ------------------------------------------------------------------------------------

# key posts only while the kit's Sesame is the frontmost app (guard_key), whatever the target flag says.
cmd_key() {
  [ $# = 1 ] || { usage; return 2; }
  local bin
  need_ax || return $?
  guard_key || return $?
  bin="$(kit_tool keytool)" || { tool_missing keytool; return 1; }
  "$bin" key "$1"
}

# hotkey posts only while the kit's Sesame or a window the kit made is the frontmost app (guard_hotkey).
cmd_hotkey() {
  local combo="ctrl+opt+space" bin before after i
  [ $# -le 1 ] || { usage; return 2; }
  [ $# = 1 ] && combo="$1"
  need_ax || return $?
  guard_hotkey || return $?
  bin="$(kit_tool keytool)" || { tool_missing keytool; return 1; }
  before="$(window_count)"
  "$bin" key "$combo" || return $?
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 0.1
    after="$(window_count)"
    [ "$after" != "$before" ] && break
  done
  if [ "$after" -gt "$before" ]; then
    echo "$AX_APP window shown ($after on screen)"
  elif [ "$after" -lt "$before" ]; then
    echo "$AX_APP window hidden ($after on screen)"
  else
    echo "no change in the $AX_APP windows within 1.5 s ($after on screen)"
  fi
  return 0
}

# type: the frontmost check above runs once, before the first key. The tool then re-checks, by pid, every 8
# characters and again before the --then combination (kit-lib/keytool.swift, F20): if the target app is no longer
# frontmost it posts nothing more, prints "refused: ..." and exits 4 (this mode returns 4 too).
cmd_type() {
  [ $# -ge 1 ] || { usage; return 2; }
  local bin a explicit=0 delay=10 v="${KIT_TYPE_DELAY_MS:-}" pids rc
  need_ax || return $?
  need_frontmost_window || return 1
  bin="$(kit_tool keytool)" || { tool_missing keytool; return 1; }
  if [ "$AX_KIT" = 1 ]; then pids="$(kitwin_pids)"; else pids="$(kit_pid_of app)"; fi
  pids="$(printf '%s\n' "$pids" | awk 'NF { printf "%s%s", sep, $1; sep = "," }')"
  if [ -z "$pids" ]; then echo "refused: no pid of the $AX_APP target to re-check while typing; nothing was posted"; return 1; fi
  # Per-key delay: an explicit --delay-ms wins, then KIT_TYPE_DELAY_MS (0 to 500), else 10 ms.
  for a in "${@:2}"; do [ "$a" = --delay-ms ] && explicit=1; done
  if [ "$explicit" = 0 ]; then
    if [ -n "$v" ]; then
      case "$v" in
        *[!0-9]*) echo "warning: KIT_TYPE_DELAY_MS=\"$v\" is not a whole number of ms from 0 to 500; ignored, typing at 10 ms" >&2 ;;
        *) if [ "${#v}" -le 3 ] && [ "$((10#$v))" -le 500 ]; then delay="$((10#$v))"
           else echo "warning: KIT_TYPE_DELAY_MS=\"$v\" is not a whole number of ms from 0 to 500; ignored, typing at 10 ms" >&2; fi ;;
      esac
    fi
    set -- "$@" --delay-ms "$delay"
  fi
  "$bin" type "$@" --front-pids "$pids"
  rc=$?
  [ "$rc" = 4 ] && echo "type stopped: the target was no longer the frontmost app, so no more keys were posted"
  return $rc
}

# paste: the person's pasteboard is theirs. Before pbcopy the general pasteboard is saved whole (every item and
# every type, held in memory only: keytool pb-save), and it is put back after the chord is posted, on every path:
# a failed pbcopy, a failed key and an interrupt included (F21). The restore is skipped, with a line saying so, when
# something else was copied meanwhile (the change count moved on). A pasteboard over 16 MB is not touched at all.
PASTE_BIN=""
PASTE_SAVED=""
PASTE_COUNT=""
PASTE_ARMED=0

# paste_restore: puts the saved pasteboard back once; prints one line. Safe to call twice.
paste_restore() {
  local out
  [ "$PASTE_ARMED" = 1 ] || return 0
  PASTE_ARMED=0
  if [ -n "$PASTE_COUNT" ]; then
    out="$(printf '%s' "$PASTE_SAVED" | "$PASTE_BIN" pb-restore --only-if-change-count "$PASTE_COUNT" 2>&1)"
  else
    out="$(printf '%s' "$PASTE_SAVED" | "$PASTE_BIN" pb-restore 2>&1)"
  fi
  echo "pasteboard: ${out:-restore printed nothing}"
  PASTE_SAVED=""
}

cmd_paste() {
  [ $# = 1 ] || { usage; return 2; }
  local bin n out rc=0
  need_ax || return $?
  need_frontmost_window || return 1
  bin="$(kit_tool keytool)" || { tool_missing keytool; return 1; }
  n="$(printf '%s' "$1" | wc -m | tr -d ' ')"
  out="$("$bin" pb-save 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    echo "refused: the pasteboard could not be saved, so it was not touched and nothing was pasted (${out%%$'\n'*})"
    return 4
  fi
  PASTE_BIN="$bin"; PASTE_SAVED="${out#*$'\n'}"; PASTE_COUNT=""; PASTE_ARMED=1
  trap 'paste_restore; exit 130' INT TERM HUP
  if ! printf '%s' "$1" | pbcopy; then
    echo "could not set the pasteboard"
    paste_restore; trap - INT TERM HUP
    return 1
  fi
  PASTE_COUNT="$("$bin" pb-count 2>/dev/null)"
  sleep 0.2   # the target app reads the pasteboard when it gets the chord; let the new text settle first
  # The focus is read again right before the chord: Command+V in another app would paste the kit's text there.
  if need_frontmost_window; then
    "$bin" key "cmd+v" >/dev/null; rc=$?
  else
    rc=1
    echo "paste stopped: the target was no longer the frontmost app, so Command+V was not posted"
  fi
  # key waits 1 s after posting (the receiving app has read the pasteboard by then); a little more, then put it back.
  sleep 0.2
  paste_restore
  trap - INT TERM HUP
  [ "$rc" = 0 ] || return "$rc"
  echo "pasted $n characters"
}

# ---- reading and pressing --------------------------------------------------------------------

# window_args <what...>: sets WIN_KIND and WIN_TITLE from "panel|setup|settings" or "window <title>".
WIN_KIND=""
WIN_TITLE=""
window_args() {
  WIN_KIND="$1"; WIN_TITLE=""
  case "$1" in
    panel|setup|settings|menu) [ $# = 1 ] || return 1 ;;
    window) [ $# = 2 ] && [ -n "$2" ] || return 1; WIN_TITLE="$2" ;;
    *) return 1 ;;
  esac
  return 0
}

# osa_window_error: turns an AppleScript "no <kind> window" into the driver's line.
osa_window_error() {
  case "$OSA_ERR" in
    "no panel window") echo "no $AX_APP window" ;;
    "no "*" window") echo "$OSA_ERR" ;;
    *) echo "could not read the window: $OSA_ERR" ;;
  esac
}

# front-sesame: Sesame is never frontmost after a kit launch (macOS gives the front to the app that was opened
# by a person's key event), so the folder picker could not be driven. This raises the kit's own Sesame, by the
# pid of the kit's process tree and nothing else, the same raise the kit window gets (raise_kit_front).
cmd_front_sesame() {
  [ $# = 0 ] || { usage; return 2; }
  local pid i j rc
  need_ax || return $?
  kit_need_ps || return 1
  pid="$(kit_pid_of app | head -1)"
  if [ -z "$pid" ]; then echo "no Sesame running: scripts/kit-launch.sh start starts it"; return 1; fi
  for i in 1 2 3; do
    osa raise "$pid" >/dev/null; rc=$?
    [ "$rc" = 3 ] && return 3
    for j in 1 2 3 4; do
      sleep 0.25
      read_front; rc=$?
      [ "$rc" = 0 ] || return "$rc"
      if front_is_sesame; then
        echo "raised Sesame (pid $pid), raise $i of 3: it is frontmost"
        return 0
      fi
    done
    echo "raised Sesame (pid $pid), raise $i of 3: the frontmost app is still $FRONT_NAME"
  done
  return 1
}

# gotofolder: the picker's Go to the folder sheet ignores typed keys, so its field is set through the
# accessibility value. Only while the kit's Sesame is frontmost; no key is posted.
cmd_gotofolder() {
  [ $# = 1 ] && [ -n "$1" ] || { usage; return 2; }
  local rc
  need_ax || return $?
  kit_need_ps || return 1
  read_front; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if ! front_is_sesame; then
    echo "refused: Sesame is not the frontmost app (the frontmost app is $FRONT_NAME); the Go to field was not set"
    return 1
  fi
  osa setgoto "$1"; rc=$?
  if [ "$rc" = 0 ]; then printf '%s\n' "$OSA_OUT"; return 0; fi
  [ "$rc" = 3 ] && return 3
  echo "could not set the Go to field: $OSA_ERR"
  return 1
}

# cmd_click: a control of a window, else an item of the status item's menu. The menu bar holds no window, so no
# window is needed to start: the driver itself says "no element labelled" when neither has the label.
cmd_click() {
  local rc help=""
  if [ "${1:-}" = --help ]; then
    [ $# = 3 ] && [ -n "$2" ] || { usage; return 2; }
    help="$2"
    shift 2
  fi
  [ $# = 1 ] || { usage; return 2; }
  need_ax || return $?
  if [ -n "$help" ]; then osa click "$1" "$help"; rc=$?; else osa click "$1"; rc=$?; fi
  if [ "$rc" = 0 ]; then printf '%s\n' "$OSA_OUT"; return 0; fi
  [ "$rc" = 3 ] && return 3
  case "$OSA_ERR" in
    "no window") echo "no $AX_APP window" ;;
    "no element labelled"*) if [ -n "$help" ]; then echo "no element labelled \"$1\" with help \"$help\""; else echo "no element labelled \"$1\""; fi ;;
    *) echo "could not press \"$1\": $OSA_ERR" ;;
  esac
  return 1
}

cmd_read() {
  [ $# -ge 1 ] || { usage; return 2; }
  local what="$1" rc role label
  shift
  need_ax || return $?
  case "$what" in
    panel)
      [ $# = 0 ] || { usage; return 2; }
      need_window || return 1
      osa window panel; rc=$?
      if [ "$rc" = 0 ]; then printf 'panel %s\n' "$OSA_OUT"; return 0; fi
      [ "$rc" = 3 ] && return 3
      osa_window_error; return 1 ;;
    windows)
      [ $# = 0 ] || { usage; return 2; }
      osa windows; rc=$?
      [ "$rc" = 3 ] && return 3
      [ "$rc" = 0 ] || { echo "could not list the windows: $OSA_ERR"; return 1; }
      if [ -z "$OSA_OUT" ]; then echo "no $AX_APP window"; return 1; fi
      printf '%s\n' "$OSA_OUT"; return 0 ;;
    focus)
      [ $# = 0 ] || { usage; return 2; }
      osa focused; rc=$?
      [ "$rc" = 3 ] && return 3
      [ "$rc" = 0 ] || { echo "could not read the focus: $OSA_ERR"; return 1; }
      if [ -z "$OSA_OUT" ]; then echo "nothing focused"; return 1; fi
      role="${OSA_OUT%%$'\t'*}"; label="${OSA_OUT#*$'\t'}"
      echo "focused $role \"$label\""; return 0 ;;
    menubar)
      [ $# = 0 ] || { usage; return 2; }
      osa statusitems; rc=$?
      [ "$rc" = 3 ] && return 3
      if [ "$rc" != 0 ]; then echo "no status item"; return 1; fi
      printf '%s\n' "$OSA_OUT" | sed 's/^/status item: /'; return 0 ;;
    *) usage; return 2 ;;
  esac
}

# close_menu: puts the status item's menu away after a read, and never leaves it open. The accessibility cancel
# (the driver's menuclose, an Esc on the menu) does it; if the menu is still open, Esc is posted as well. An open
# status menu takes the key whichever app is frontmost, so this Esc does not wait for Sesame to be frontmost (the
# menu is the kit's own Sesame's, found open by menuopen just above). A note says if it is open after that.
close_menu() {
  local bin
  osa menuclose >/dev/null
  osa menuopen
  [ "$OSA_OUT" = 1 ] || return 0
  bin="$(kit_tool keytool)" || return 0
  "$bin" key esc >/dev/null
  sleep 0.3
  osa menuopen
  [ "$OSA_OUT" = 1 ] && echo "note: the status item menu is still open after a posted Esc"
  return 0
}

cmd_dump() {
  [ $# -ge 1 ] || { usage; return 2; }
  local rc n
  need_ax || return $?
  case "$1" in
    menubar)
      [ $# = 1 ] || { usage; return 2; }
      osa dumpmenubar; rc=$?
      [ "$rc" = 3 ] && return 3
      if [ "$rc" != 0 ]; then echo "no status item"; return 1; fi
      printf '%s\n' "$OSA_OUT"; return 0 ;;
    menu)
      [ $# = 1 ] || { usage; return 2; }
      osa dumpmenu; rc=$?
      [ "$rc" = 3 ] && return 3
      if [ "$rc" != 0 ]; then
        case "$OSA_ERR" in
          "no status item") echo "no status item" ;;
          *) echo "could not read the status item menu: $OSA_ERR" ;;
        esac
        return 1
      fi
      printf '%s\n' "$OSA_OUT"
      close_menu
      return 0 ;;
  esac
  window_args "$@" || { usage; return 2; }
  if [ "$WIN_KIND" = panel ]; then need_window || return 1; fi
  osa dump "$WIN_KIND" "$WIN_TITLE"; rc=$?
  [ "$rc" = 3 ] && return 3
  if [ "$rc" != 0 ]; then osa_window_error; return 1; fi
  if [ "$WIN_KIND" = panel ]; then
    n="$(window_count)"
    echo "windows $n"
  fi
  printf '%s\n' "$OSA_OUT"
}

cmd_tab_walk() {
  [ $# -ge 1 ] || { usage; return 2; }
  window_args "$@" || { usage; return 2; }
  local bin rc controls n i cur first="" visited="" max line role label seen=0 missing=0
  need_ax || return $?
  if [ "$WIN_KIND" = panel ]; then need_window || return 1; fi
  bin="$(kit_tool keytool)" || { tool_missing keytool; return 1; }
  # `menu` walks the status item's menu: it is opened (the status item pressed), the walk moves with the Down key
  # (Tab does not move through a menu) and reads the highlighted item, and the menu is put away at the end.
  if [ "$WIN_KIND" = menu ]; then
    osa menuitems; rc=$?
    if [ "$rc" != 0 ]; then
      [ "$rc" = 3 ] && return 3
      case "$OSA_ERR" in "no status item") echo "no status item" ;; *) echo "could not open the status item menu: $OSA_ERR" ;; esac
      return 1
    fi
  else
    osa controls "$WIN_KIND" "$WIN_TITLE"; rc=$?
    [ "$rc" = 3 ] && return 3
    if [ "$rc" != 0 ]; then osa_window_error; return 1; fi
  fi
  controls="$OSA_OUT"
  n="$(printf '%s' "$controls" | awk 'NF { n++ } END { print n + 0 }')"
  if [ "$n" = 0 ]; then
    echo "tab-walk: 0 controls"
    [ "$WIN_KIND" = menu ] && close_menu
    return 1
  fi
  # Tab goes to the frontmost app, so the walk starts only when that is the app being walked, and
  # stops the moment it is not (checked before every Tab). A menu has no window: its walk is checked
  # against Sesame being frontmost before every Down, the first one included.
  if [ "$WIN_KIND" != menu ]; then need_frontmost_window || return 1; fi
  max=$((n + 2))
  for ((i = 1; i <= max; i++)); do
    if [ "$i" -gt 1 ] || [ "$WIN_KIND" = menu ]; then
      read_front; rc=$?
      [ "$rc" = 0 ] || return "$rc"
      if { [ "$AX_KIT" = 1 ] && ! front_is_kitwindow; } || { [ "$AX_KIT" = 0 ] && ! front_is_sesame; }; then
        if [ "$WIN_KIND" = menu ]; then
          echo "refused: the frontmost app became $FRONT_NAME, so the menu walk stopped before posting Down"
          close_menu
        else
          echo "refused: the frontmost app became $FRONT_NAME, so the walk stopped before posting Tab"
        fi
        return 1
      fi
    fi
    if [ "$WIN_KIND" = menu ]; then osa menuselected; rc=$?; else osa focused; rc=$?; fi
    [ "$rc" = 3 ] && return 3
    cur="$OSA_OUT"
    if [ -n "$cur" ]; then
      if [ -n "$first" ] && [ "$cur" = "$first" ]; then break; fi
      [ -n "$first" ] || first="$cur"
      role="${cur%%$'\t'*}"; label="${cur#*$'\t'}"
      echo "$i $role \"$label\""
      visited="$visited$cur"$'\n'
      seen=$((seen + 1))
    else
      echo "$i (nothing focused)"
    fi
    if [ "$WIN_KIND" = menu ]; then
      "$bin" key down >/dev/null || { close_menu; return 1; }
    else
      "$bin" key tab >/dev/null || return 1
    fi
    sleep 0.2
  done
  [ "$WIN_KIND" = menu ] && close_menu
  # Every control of the window must have been reached by Tab.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$visited" in
      *"$line"*) ;;
      *)
        role="${line%%$'\t'*}"; label="${line#*$'\t'}"
        echo "not reached: $role \"$label\""
        missing=$((missing + 1)) ;;
    esac
  done < <(printf '%s\n' "$controls" | sort -u)
  echo "tab-walk: $seen controls reached by Tab, $n controls in the window"
  [ "$missing" = 0 ] && return 0
  return 1
}

# ---- full screen -----------------------------------------------------------------------------

# fullscreen drives only apps the kit started: Sesame (started by kit-launch.sh) and the kit's own window
# (started here if it is not open). Any other app is refused: the kit neither starts nor quits it.
cmd_fullscreen() {
  [ $# = 2 ] || { usage; return 2; }
  local app="$1" state="$2" rc i out
  case "$state" in on|off) ;; *) usage; return 2 ;; esac
  case "$app" in
    Sesame)
      kit_need_ps || return 1
      if [ -z "$(kit_pid_of app)" ]; then
        echo "no Sesame running: scripts/kit-launch.sh start starts it"
        return 1
      fi ;;
    "$KITWIN"|kit-window)
      kit_need_ps || return 1 ;;
    *)
      echo "refused: $app was not started by the kit; full screen is driven only for Sesame and the kit's own window ($KITWIN)"
      return 1 ;;
  esac
  need_ax || return $?
  if [ "$app" = Sesame ]; then
    AX_APP="Sesame"
  else
    AX_APP="$KITWIN"; AX_KIT=1
    if [ -z "$(kitwin_pids)" ]; then
      kitwin_start main 0 || return 1
      echo "kit window open (pid $KITWIN_PID, window $KITWIN_ID)"
    fi
    app="$KITWIN"
  fi
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    osa fscapable; rc=$?
    [ "$rc" = 3 ] && return 3
    [ "$rc" = 0 ] && [ "$OSA_OUT" != 0 ] && break
    sleep 0.5
  done
  if [ "$rc" != 0 ] || [ "$OSA_OUT" = 0 ]; then echo "$app has no window to put in full screen"; return 1; fi
  osa fullscreen "$state"; rc=$?
  [ "$rc" = 3 ] && return 3
  if [ "$rc" != 0 ]; then echo "could not set full screen $state for $app: $OSA_ERR"; return 1; fi
  out="$OSA_OUT"
  if [ "$out" != "$state" ]; then
    echo "asked for full screen $state but $app reads $out"
    return 1
  fi
  echo "$app full screen $state"
  # Entering or leaving full screen is a Space switch, and for a moment System Events names Finder as the
  # frontmost app, so a hotkey posted at once would be refused. Wait until the app is frontmost again.
  wait_frontmost_again "$app"
  return $?
}

# wait_frontmost_again <Sesame|kitwindow>: waits up to 6 s until `frontmost` reads that app again; prints how
# long it waited. Status 1 with one plain line when it never does, 3 when a person-step is missing.
wait_frontmost_again() {
  local who="$1" pbin t0 now ms rc raised=0 pid
  pbin="$(kit_tool pixelpoll)" || { tool_missing pixelpoll; return 1; }
  t0="$("$pbin" now)"
  while :; do
    osa frontinfo; rc=$?
    [ "$rc" = 3 ] && return 3
    if [ "$rc" = 0 ]; then
      FRONT_NAME="${OSA_OUT%%$'\t'*}"
      FRONT_PID="${OSA_OUT#*$'\t'}"
      if [ "$who" = Sesame ]; then front_is_sesame && break; else front_is_kitwindow && break; fi
    fi
    now="$("$pbin" now)"
    ms=$(((now - t0) / 1000000))
    # Measured: after the Space switch macOS can keep naming Finder as frontmost for good, not just for a
    # moment. The kit's own window is then brought to the front once (the kit's own pid, never another app).
    if [ "$who" != Sesame ] && [ "$raised" = 0 ] && [ "$ms" -ge 1500 ]; then
      raised=1
      pid="$(kitwin_pids | head -1)"
      if [ -n "$pid" ]; then osa raise "$pid" >/dev/null; echo "raised $who (the frontmost app was ${FRONT_NAME:-unknown} after 1.5 s)"; fi
    fi
    if [ "$ms" -ge 6000 ]; then
      echo "$who did not become the frontmost app again within 6 s after full screen (the frontmost app is ${FRONT_NAME:-unknown}); no key should be posted yet"
      return 1
    fi
    sleep 0.25
  done
  now="$("$pbin" now)"
  ms=$(((now - t0) / 1000000))
  echo "waited $((ms / 1000)).$(((ms % 1000) / 100)) s until $who was frontmost again"
  return 0
}

# ---- main ------------------------------------------------------------------------------------

main() {
  local mode="${1:-}"
  if [ "$mode" = --kit-window ]; then
    AX_APP="$KITWIN"; AX_KIT=1
    shift
    mode="${1:-}"
  fi
  [ $# -gt 0 ] && shift
  case "$mode" in
    ping) [ $# = 0 ] || { usage; return 2; }; cmd_ping ;;
    frontmost) [ $# = 0 ] || { usage; return 2; }; cmd_frontmost ;;
    appearance) cmd_appearance "$@" ;;
    shot) cmd_shot "$@" ;;
    kitwindow) cmd_kitwindow "$@" ;;
    hotkey) cmd_hotkey "$@" ;;
    key) cmd_key "$@" ;;
    type) cmd_type "$@" ;;
    paste) cmd_paste "$@" ;;
    click) cmd_click "$@" ;;
    front-sesame) cmd_front_sesame "$@" ;;
    gotofolder) cmd_gotofolder "$@" ;;
    read) cmd_read "$@" ;;
    dump) cmd_dump "$@" ;;
    tab-walk) cmd_tab_walk "$@" ;;
    fullscreen) cmd_fullscreen "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-ax "$@")" main "$@"
exit $?

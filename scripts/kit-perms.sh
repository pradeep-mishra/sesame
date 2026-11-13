#!/bin/bash
# kit-perms.sh check [--for <check id>] | ask-admin
#
# check: every person-step and every installed-tool the kit needs, one line each:
#   OK <step>                      it holds
#   NEEDS A PERSON: <step>: <how to grant it>
# A missing grant is never a product failure. Exit 0 when every line is OK, 3 when any is
# NEEDS A PERSON. --for <check id> checks only the steps that check needs (kit-run.sh calls it just
# before each check). The permissions are read for the terminal this runs from.
# Every Apple Event or accessibility probe has a hard limit of 10 s (KIT_PROBE_TIMEOUT): an app that does not
# answer prints `NEEDS A PERSON: <app> did not answer Apple Events within 10 s, restart it` and the exit is 3.
# ask-admin: says in plain words why administrator rights are needed, then asks once (sudo -v). The sentence goes to the
# person's terminal (/dev/tty; KIT_TTY names another file for a test), or to standard error when there is no terminal,
# so a caller that captures the output still shows it before the password prompt.
# Administrator rights are first needed in slice 2 (verify.md, Drive): a slice 1 check never asks.
. "$(dirname "$0")/kit-lib/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: kit-perms.sh check [--for <check id>]
       kit-perms.sh ask-admin
EOF
}

NEEDS=0
FOR_KEYS=""
TERMINAL="${TERM_PROGRAM:-the terminal app that runs the checks}"

ok() { echo "OK $1"; }
need() { echo "NEEDS A PERSON: $1"; NEEDS=$((NEEDS + 1)); }

want() {
  [ -z "$FOR_KEYS" ] && return 0
  case " $FOR_KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# The steps a check id needs. Unknown ids are a usage error, so a typo never means "needs nothing".
keys_for() {
  case "$1" in
    # Each S1 id needs only what it uses: Finder Automation where a check reads Finder (S1.9, S1.10, S1.15),
    # keyboard navigation only for S1.29, everything else Accessibility, Screen Recording and System Events.
    S1.9|S1.10|S1.15) echo "accessibility screen sysevents finder" ;;
    S1.29) echo "accessibility screen sysevents keyboard" ;;
    S1.*) echo "accessibility screen sysevents" ;;
    S2.9|S2.1[0-4]) echo "accessibility screen sysevents power model" ;;
    S2.2|S2.3|S2.8|S2.17) echo "accessibility screen sysevents model" ;;
    S2.*) echo "model" ;;
    S3.*) echo "accessibility screen sysevents finder preview" ;;
    S4.8) echo "accessibility screen sysevents quicktime speech admin" ;;
    S4.*) echo "accessibility screen sysevents finder quicktime speech" ;;
    S6.8) echo "accessibility screen sysevents admin" ;;
    S6.13|S8.2|S8.3|S8.7|S8.8) echo "admin" ;;
    S6.11) echo "accessibility screen sysevents power" ;;
    S6.*) echo "accessibility screen sysevents" ;;
    S7.4|S7.18) echo "accessibility screen sysevents admin" ;;
    S7.*) echo "accessibility screen sysevents" ;;
    S8.1|S8.5|S8.6|S8.9) echo "accessibility screen sysevents" ;;
    S9.*|S10.*) echo "accessibility screen sysevents" ;;
    # S8.10 reads the permission (TCC) database from slice 3 (its tcc part), so Full Disk Access gates it.
    S8.10) echo "fda" ;;
    S8.*) echo "" ;;
    *) return 1 ;;
  esac
}

# A kit Swift tool answering a permission question, under the hard limit of every probe (kit_timeout):
# prints the answer, status of the tool; 99 = did not compile, 124 = no answer within the limit.
ask_tool() { # ask_tool <tool> <args...>
  local tool bin
  tool="$1"; shift
  bin="$(kit_tool "$tool")" || return 99
  kit_timeout "$KIT_PROBE_TIMEOUT" "$bin" "$@" 2>&1
}

# A probe that never answered: the app is hung, so a person restarts it. Never a pass, never a hang.
need_hung() { # need_hung <app>
  need "$1 did not answer Apple Events within $KIT_PROBE_TIMEOUT s, restart it (if a macOS permission prompt is showing, allow it and run this again)"
}

step_accessibility() {
  local out rc
  out="$(ask_tool keytool trusted)"; rc=$?
  if [ $rc = 0 ]; then ok "Accessibility for this terminal"
  elif [ $rc = 99 ]; then need "Accessibility for this terminal (not checked: scripts/kit-lib/keytool.swift did not compile, see $KIT_ROOT/run/bin/keytool.log)"
  elif [ $rc = 124 ]; then need_hung "the Accessibility check of $TERMINAL"
  else need "Accessibility for this terminal: System Settings, Privacy and Security, Accessibility, turn on $TERMINAL"
  fi
}

step_screen() {
  local out rc
  out="$(ask_tool pixelpoll screen-trusted)"; rc=$?
  if [ $rc = 0 ]; then ok "Screen Recording for this terminal"
  elif [ $rc = 99 ]; then need "Screen Recording for this terminal (not checked: scripts/kit-lib/pixelpoll.swift did not compile, see $KIT_ROOT/run/bin/pixelpoll.log)"
  elif [ $rc = 124 ]; then need_hung "the Screen Recording check of $TERMINAL"
  else need "Screen Recording for this terminal: System Settings, Privacy and Security, Screen Recording, turn on $TERMINAL"
  fi
}

step_automation() { # step_automation <label> <bundle id> <how>
  local out rc
  out="$(ask_tool keytool automation "$2")"; rc=$?
  case $rc in
    99) need "Automation for $1 (not checked: scripts/kit-lib/keytool.swift did not compile, see $KIT_ROOT/run/bin/keytool.log)" ;;
    124) need_hung "$1" ;;
    4) need "Automation for $1 (macOS gave no answer: $out; $3)" ;;
    *) step_automation_event "$1" "tell application id \"$2\" to get name" "$3" ;;
  esac
}

# Automation for an app that always runs (Finder, System Events): the check sends the Apple Event itself,
# the one a later check sends, with the hard limit, and trusts its result. A permission question put by
# another process can read differently from the terminal's own, so the compiled tool is not asked.
step_automation_event() { # step_automation_event <label> <AppleScript line> <how>
  local out rc
  out="$(kit_timeout "$KIT_PROBE_TIMEOUT" osascript -e "$2" 2>&1)"; rc=$?
  out="$(printf '%s' "$out" | tr '\n' ' ')"
  case $rc in
    0) ok "Automation for $1" ;;
    124) need_hung "$1" ;;
    *)
      case "$out" in
        *-1743*|*"Not authorized"*) need "Automation for $1: macOS refused the Apple Event; System Settings, Privacy and Security, Automation, allow $TERMINAL to control $1" ;;
        *) need "Automation for $1 (macOS gave no answer: ${out##*execution error: }; $3)" ;;
      esac ;;
  esac
}

tcc_probe() {
  local err
  if err="$(LC_ALL=C head -c 1 "$1" 2>&1 >/dev/null)"; then echo open
  else
    case "$err" in
      *"No such file or directory"*) echo missing ;;
      *) echo refused ;;
    esac
  fi
}

step_fda() {
  local db state present=0 unreadable=0
  for db in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
    state="$(tcc_probe "$db")"
    [ "$state" = missing ] && continue
    present=1
    if [ "$state" != open ] || ! sqlite3 -readonly -safe "$db" 'select count(*) from access' >/dev/null 2>&1; then unreadable=1; fi
  done
  if [ $present = 0 ]; then
    need "no permission database exists in the user's or the system's Library, so Full Disk Access cannot be checked (not a permission to grant)"
  elif [ $unreadable = 1 ]; then
    need "Full Disk Access for this terminal: System Settings, Privacy and Security, Full Disk Access, turn on $TERMINAL (used only to read the permission database)"
  else
    ok "Full Disk Access for this terminal (the permission-database read)"
  fi
}

step_admin() {
  if [ "$KIT_SLICE" -lt 2 ]; then
    ok "administrator rights: not asked in slice 1 (first needed in slice 2: S6.8, S7.4, S7.18, S8.2, S8.3, S8.7, S8.8, S4.8)"
  elif sudo -n true 2>/dev/null; then
    ok "administrator rights"
  else
    need "administrator rights: macOS only lets an administrator watch which files and connections Sesame uses, and read the login item record; run scripts/kit-perms.sh ask-admin and type your password once"
  fi
}

step_keyboard() {
  local v
  v="$(defaults read -g AppleKeyboardUIMode 2>/dev/null)"
  if [ "${v:-0}" -ge 2 ] 2>/dev/null; then ok "keyboard navigation is on"
  else need "keyboard navigation: System Settings, Keyboard, Keyboard navigation, turn on"
  fi
}

step_power() {
  if pmset -g ps 2>/dev/null | grep -q "AC Power"; then ok "the Mac is on power"
  else need "power: plug the Mac into power and keep it plugged in (the speed, memory and 500-file checks are only meaningful on power)"
  fi
}

step_speech() {
  if [ "$KIT_SLICE" -lt 5 ]; then
    ok "on-device speech assets: not needed until slice 5 (scripts/kit-readback.sh speech-assets checks them then)"
  elif [ -x "$KIT_SCRIPTS/kit-readback.sh" ] && KIT_NO_EVIDENCE=1 kit_timeout "$KIT_PROBE_TIMEOUT" "$KIT_SCRIPTS/kit-readback.sh" speech-assets >/dev/null 2>&1; then
    ok "on-device speech assets for the system language"
  else
    need "on-device speech assets: System Settings, Keyboard, Dictation, turn on on-device dictation for the system language and let it download"
  fi
}

# step_tool <label> <how to install> <command...> : OK when the command exits 0.
step_tool() {
  local label="$1" how="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    need "$label is missing or does not run: $how"
  fi
}

step_swift() {
  local line major minor
  line="$(swift --version 2>&1 | head -1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  if [ -n "$line" ]; then
    major="${line% *}"; minor="${line#* }"
    if [ "$major" -gt 6 ] || { [ "$major" = 6 ] && [ "$minor" -ge 2 ]; }; then
      ok "swift $major.$minor"
      return
    fi
    need "Swift $major.$minor is too old: Sesame needs Swift 6.2 or newer, so update Xcode"
  else
    need "swift is missing or does not run: install the full Xcode"
  fi
}

step_sqlite() {
  local out
  out="$(sqlite3 :memory: "create virtual table t using fts5(a); select 'fts5 ok';" 2>&1)"
  if [ "$out" = "fts5 ok" ]; then ok "sqlite3 with FTS5"
  else need "sqlite3 with FTS5 is missing: the first build step makes an FTS5 table and a Mac where that fails goes to the person first ($out)"
  fi
}

step_model() {
  local name size sha f missing="" bad="" actual
  while read -r name size sha; do
    f="$KIT_ROOT/cache/$name"
    if [ ! -f "$f" ]; then missing="$missing $name"; continue; fi
    actual="$(stat -f %z "$f")"
    if [ "$actual" != "$size" ]; then bad="$bad $name(size $actual, expected $size)"; continue; fi
    if [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$sha" ]; then bad="$bad $name(SHA-256 differs)"; fi
  done < <(kit_models)
  if [ -z "$missing$bad" ]; then ok "model files in cache/ (size and SHA-256 match design section 7)"
  elif [ -n "$bad" ]; then need "model files in cache/ are wrong:$bad; run scripts/kit-mirror.sh seed --real again"
  else need "model files missing from cache/:$missing; the one download is made by scripts/kit-mirror.sh seed --real, or by a person-run download"
  fi
}

do_check() {
  want accessibility && step_accessibility
  want screen && step_screen
  want sysevents && step_automation_event "System Events" 'tell application "System Events" to count of application processes' "it always runs, so a sandbox may be refusing Apple Events: run this from your own Terminal"
  want finder && step_automation_event "Finder" 'tell application "Finder" to count of windows' "it always runs, so a sandbox may be refusing Apple Events: run this from your own Terminal"
  want preview && step_automation "Preview" com.apple.Preview "macOS only answers while Preview runs: run scripts/kit-readback.sh ping preview, which opens it, then allow the prompt"
  want quicktime && step_automation "QuickTime Player" com.apple.QuickTimePlayerX "macOS only answers while QuickTime Player runs: run scripts/kit-readback.sh ping quicktime, which opens it, then allow the prompt"
  want fda && step_fda
  want admin && step_admin
  want keyboard && step_keyboard
  want power && step_power
  want speech && step_speech
  if [ -z "$FOR_KEYS" ]; then
    step_tool "full Xcode (xcodebuild)" "install Xcode from the Mac App Store, open it once and accept the license" xcodebuild -version
    step_swift
    step_tool "cmake" "brew install cmake" cmake --version
    step_tool "ffmpeg" "brew install ffmpeg" ffmpeg -version
    step_tool "git" "brew install git" git --version
    step_sqlite
    step_tool "shasum" "it comes with macOS" shasum --version
    step_tool "footprint" "it comes with macOS: update macOS" footprint --help
    step_tool "nettop" "it comes with macOS" test -x /usr/bin/nettop
    step_tool "fs_usage" "it comes with macOS" test -x /usr/bin/fs_usage
    step_tool "say" "it comes with macOS" test -x /usr/bin/say
    step_tool "osascript" "it comes with macOS" test -x /usr/bin/osascript
  fi
  want model && step_model
  return 0
}

ask_admin() {
  local tty="${KIT_TTY:-/dev/tty}"
  # The sentence goes to the person's terminal (KIT_TTY, /dev/tty by default), or to standard error when there is none,
  # before the password is asked and never to a standard output a caller can capture.
  exec 3>&2
  { : >"$tty"; } 2>/dev/null && exec 3>"$tty"
  echo "macOS only lets an administrator watch which files and connections Sesame uses, and read the login item record; you will be asked for your password once." >&3
  exec 3>&-
  if sudo -v; then
    echo "OK administrator rights"
    return 0
  fi
  echo "NEEDS A PERSON: administrator rights: type your password when macOS asks, from a Terminal window you can type in"
  return 3
}

main() {
  case "${1:-}" in
    check)
      shift
      case "${1:-}" in
        "") ;;
        --for)
          [ $# -eq 2 ] || { usage; return 2; }
          FOR_KEYS="$(keys_for "$2")" || { echo "unknown check id: $2"; usage; return 2; }
          if [ -z "$FOR_KEYS" ]; then
            echo "OK $2 needs no person-step"
            return 0
          fi
          ;;
        *) usage; return 2 ;;
      esac
      do_check
      [ "$NEEDS" = 0 ] && return 0
      return 3
      ;;
    ask-admin) shift; [ $# -eq 0 ] || { usage; return 2; }; ask_admin ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-perms "$@")" main "$@"
exit $?

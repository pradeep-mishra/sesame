#!/bin/bash
# kit-power.sh ping | lowpower on|off|get | record | restore
#
# Low Power Mode, driven for S7.4 (verify.md, Kit scripts, Not covered; guess K31).
#   lowpower on|off  turns Low Power Mode on or off with `sudo pmset -a lowpowermode 1|0`, reads it back from
#                    `pmset -g` and prints the epoch of the change (S7.4 counts its 5 s and 10 s from it).
#   lowpower get     prints the current value from `pmset -g` (`lowpowermode on|off`, or `unsupported`).
#   record           saves the current value under $KIT_ROOT/keep (called by kit-reset.sh at reset). A value that is
#                    already saved is never overwritten: it stays until a restore has put it back.
#   restore          puts the recorded value back (called by kit-reset.sh, at cleanup and at the next reset).
#                    Nothing recorded, or already that value: nothing is written. When it cannot put the value back
#                    (the administrator session ran out, or pmset refused) it says so on one clear line, exit 3, and the
#                    saved value stays where it is.
#   The saved value lives in keep/, not run/: a reset deletes run/ and a cleanup deletes everything but cache/ and keep/,
#   so a restore that failed never loses the value Low Power Mode has to go back to. (An earlier kit kept it in run/;
#   record and restore move such a file to keep/ first.)
#   ping             `pmset -g` is read and says whether this Mac has the setting (supported or unsupported);
#                    with the administrator session the setting is written back to its current value to prove
#                    the write works.
# The administrator session is the one `kit-perms.sh ask-admin` primed. This script never asks for a
# password: every administrator call is non-interactive, and a missing session is exit 3.
# A Mac whose `pmset -g` has no `lowpowermode` line makes every call but ping and `lowpower get` exit 3 with
# `NEEDS A PERSON: this Mac has no Low Power Mode setting`.
# Exit codes: 0 done; 1 failed; 2 usage; 3 a person-step is missing.
. "$(dirname "$0")/kit-lib/common.sh"

SAVED="$KIT_ROOT/keep/lowpower.saved"
LEGACY_SAVED="$KIT_ROOT/run/lowpower.saved"

usage() {
  cat >&2 <<'EOF'
usage: kit-power.sh ping | lowpower on|off|get | record | restore
       ping            say whether this Mac has Low Power Mode; with administrator rights write the value back
       lowpower on     turn Low Power Mode on and print the epoch
       lowpower off    turn Low Power Mode off and print the epoch
       lowpower get    print the current value
       record          save the current value under KIT_ROOT/keep (never over a value that is already saved)
       restore         put the recorded value back; a failed restore is a NEEDS A PERSON line with the command to run
EOF
}

# current_value : prints 0 or 1 from `pmset -g`; status 1 when this Mac has no lowpowermode line.
current_value() {
  local v
  v="$(pmset -g 2>/dev/null | awk '$1 == "lowpowermode" { print $2; exit }')"
  case "$v" in
    0|1) echo "$v"; return 0 ;;
  esac
  return 1
}

# need_setting : status 3 and the one sentence when this Mac has no Low Power Mode setting.
need_setting() {
  if ! current_value >/dev/null; then
    echo "NEEDS A PERSON: this Mac has no Low Power Mode setting"
    return 3
  fi
  return 0
}

# need_admin : status 3 when the administrator session is not primed (it never prompts).
need_admin() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo "NEEDS A PERSON: administrator rights: run scripts/kit-perms.sh ask-admin from a Terminal window you can type in, then run this again"
  return 3
}

# write_value <0|1> : writes the setting and reads it back. Status 1 when it did not take.
write_value() {
  local want="$1" got
  sudo -n pmset -a lowpowermode "$want" || { echo "pmset did not accept lowpowermode $want"; return 1; }
  got="$(current_value)"
  if [ "$got" != "$want" ]; then
    echo "pmset -g reads lowpowermode ${got:-nothing} after writing $want"
    return 1
  fi
  return 0
}

word_of() { if [ "$1" = 1 ]; then echo on; else echo off; fi; }

cmd_lowpower() {
  local mode="$1" v
  case "$mode" in
    on) v=1 ;;
    off) v=0 ;;
    get)
      [ $# = 1 ] || { usage; return 2; }
      if v="$(current_value)"; then
        echo "lowpowermode $(word_of "$v")"
      else
        echo "lowpowermode unsupported (pmset -g has no lowpowermode line)"
      fi
      return 0 ;;
    *) usage; return 2 ;;
  esac
  [ $# = 1 ] || { usage; return 2; }
  need_setting || return 3
  need_admin || return 3
  write_value "$v" || return 1
  echo "lowpowermode $mode epoch $(date +%s)"
  return 0
}

# adopt_legacy : a value an earlier kit saved under run/ is moved to keep/ (a reset deletes run/, so it would be lost).
adopt_legacy() {
  if [ -f "$LEGACY_SAVED" ] && [ ! -f "$SAVED" ]; then
    mkdir -p "$KIT_ROOT/keep" && mv "$LEGACY_SAVED" "$SAVED"
  fi
  rm -f "$LEGACY_SAVED"
}

cmd_record() {
  local v
  need_setting || return 3
  adopt_legacy
  if [ -f "$SAVED" ]; then
    echo "kept the recorded lowpowermode $(word_of "$(cat "$SAVED")"): an earlier restore has not put it back, so it is not overwritten"
    return 0
  fi
  v="$(current_value)"
  mkdir -p "$KIT_ROOT/keep" || return 1
  printf '%s\n' "$v" > "$SAVED" || return 1
  echo "recorded lowpowermode $(word_of "$v")"
  return 0
}

# not_restored <saved> <now> : the loud line a failed restore ends with. Status 3.
not_restored() {
  echo "NEEDS A PERSON: Low Power Mode is still $(word_of "$2"), run \`sudo pmset -a lowpowermode $1\`"
  echo "the saved value ($(word_of "$1")) stays in $SAVED until a restore has put it back"
  return 3
}

cmd_restore() {
  local want now
  need_setting || return 3
  adopt_legacy
  if [ ! -f "$SAVED" ]; then
    echo "no recorded Low Power Mode value, nothing to restore"
    return 0
  fi
  want="$(cat "$SAVED")"
  now="$(current_value)"
  if [ "$want" = "$now" ]; then
    rm -f "$SAVED"
    echo "lowpowermode is already $(word_of "$want"), nothing to restore"
    return 0
  fi
  need_admin >/dev/null || { not_restored "$want" "$now"; return 3; }
  write_value "$want" || { not_restored "$want" "$now"; return 3; }
  rm -f "$SAVED"
  echo "lowpowermode restored to $(word_of "$want") epoch $(date +%s)"
  return 0
}

cmd_ping() {
  local v
  if ! v="$(current_value)"; then
    echo "KIT-POWER PING OK: pmset -g read, this Mac has no lowpowermode setting (unsupported)"
    return 0
  fi
  echo "pmset -g read: lowpowermode $(word_of "$v") (supported)"
  if ! sudo -n true 2>/dev/null; then
    echo "NEEDS A PERSON (administrator rights, first needed in slice 2): the write-back of Low Power Mode is not tried"
    return 3
  fi
  write_value "$v" || { echo "KIT-POWER PING FAILED: the setting could not be written back"; return 1; }
  echo "KIT-POWER PING OK: lowpowermode written back to its current value ($(word_of "$v"))"
  return 0
}

main() {
  case "$1" in
    ping) [ $# = 1 ] || { usage; return 2; }; cmd_ping ;;
    lowpower) shift; cmd_lowpower "$@" ;;
    record) [ $# = 1 ] || { usage; return 2; }; cmd_record ;;
    restore) [ $# = 1 ] || { usage; return 2; }; cmd_restore ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-power "$@")" main "$@"
exit $?

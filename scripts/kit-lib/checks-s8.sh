#!/bin/bash
# The slice 1 checks of S8 (feature map S8: S8.4, S8.10, S8.12, S8.13). Sourced by kit-run.sh after
# common.sh and recipes.sh, never run. Each check prints one `CHECK <id> PASS|FAIL ...` line (a failure says
# why) and uses the exit codes of every kit script; a precondition that does not hold prints
# `RERUN <id> not valid: <reason>` and returns 4. With KIT_PLANT=1 (kit-run.sh --plant <id>) a check changes one
# input and prints `CHECK <id> FAIL planted: <what>` when it sees the fault.
# S8.1 to S8.3 are in checks-s8b.sh, S8.5 and S8.6 in checks-s8c.sh, S8.7 and S8.9 (and s8_net_summary) in checks-s8d.sh. S8.8 (slice 5)
# has no check yet, so kit-run.sh prints `FAIL no check written` for it when a run reaches its slice.
# From slice 3 S8.10 also reads the S8 session (s8_close_window, the permission database, the prompts watcher's result) and S8.13 its
# logs and net parts (S8.9's scan result, s8_net_summary); below slice 3 both keep the slice 1 parts only.
# S8.12 is the last check of the scenario in checks.tsv: it quits the app and deletes the Sesame folder and the
# app copy, which every check before it still needs.

S8_KP="$KIT_SCRIPTS/kit-privacy.sh"

# The bundle the checks read: the kit's copy of the app, else the one in dist/.
s8_bundle() {
  if [ -d "$KIT_APP" ]; then printf '%s' "$KIT_APP"; else printf '%s' "$KIT_PROJECT/dist/Sesame.app"; fi
}

# The first lines of a scan output that name a finding (twelve, so a pre-existing leftover list is not cut short).
# s8_need_baseline <id> : the Library baseline of this run's last reset (kit-reset.sh --baseline) is there, else exit 4.
s8_need_baseline() {
  local d="$KIT_ROOT/run/privacy"
  [ -s "$d/baseline.time" ] && [ -f "$d/baseline-home.txt" ] && [ -f "$d/baseline-real.txt" ] && return 0
  echo "RERUN $1 not valid: no Library baseline: reset with --baseline"
  return 4
}

s8_findings() { printf '%s\n' "$1" | awk '/^FOUND / { print; n++ } n >= 12 { exit }'; }

# The mirror's request log (kit-mirror.sh requests prints it between a header line and a count line). A request line is
# `<fractional time> METHOD /path range=... status=... bytes=...` (mirrorserver.swift writes the time with %.3f), so the time is
# digits, a dot, digits: the first reading of this log matched an integer time followed by a space, never matched a real line and
# let S8.13 pass whatever was requested. S8.13 and S6.13 (checks-s2c.sh) read the log with these two functions.
# s8_mirror_strays <models.tsv> : stdin the text of the log; prints, in log order, the path as logged (a query string kept) of every
# request whose last path segment, the query string left out, is none of the file names in the first column of the table.
s8_mirror_strays() {
  awk -F'\t' 'NR == FNR { ok[$1] = 1; next }
    { split($0, f, " ") }
    f[1] ~ /^[0-9]+\.[0-9]+$/ && f[2] ~ /^[A-Z]+$/ && f[3] != "" {
      p = f[3]; sub(/\?.*/, "", p); n = split(p, seg, "/")
      if (!(seg[n] in ok)) print f[3]
    }' "$1" -
}

# s8_mirror_count : stdin the text of the log; prints how many request lines it holds (the header, the count line and `no requests
# logged yet` are not requests).
s8_mirror_count() {
  awk '{ split($0, f, " ") } f[1] ~ /^[0-9]+\.[0-9]+$/ && f[2] ~ /^[A-Z]+$/ && f[3] != "" { n++ } END { print n + 0 }'
}

# ---- S8.4: the static check holds -------------------------------------------------------------

check_S8_4() {
  local cs rc al arc td pend why="" planted=""
  cs="$(kq "$KIT_SCRIPTS/check-static.sh" --quick 2>&1)"; rc=$?
  printf '%s\n' "$cs"
  if [ -n "$KIT_PLANT" ]; then
    td="$(mktemp -d "$KIT_TMP/kit-s8-plant.XXXXXX")" || { echo "RERUN S8.4 not valid: no temp folder for the plant"; return 4; }
    cp "$KIT_LIB/static-allowlist.txt" "$td/list.txt"
    echo "write-delete PlantedModule" >> "$td/list.txt"
    planted="an extra module in a copy of the kit's allowlist"
    al="$(KIT_ALLOWLIST_FILE="$td/list.txt" kq "$S8_KP" static-allowlist 2>&1)"; arc=$?
    rm -rf "$td"
  else
    al="$(kq "$S8_KP" static-allowlist 2>&1)"; arc=$?
  fi
  printf '%s\n' "$al"
  pend="$(printf '%s\n' "$cs" | awk '$1 == "STATIC" && $3 == "PENDING" { n++ } END { print n + 0 }')"
  [ $rc = 0 ] || why="scripts/check-static.sh --quick exited $rc"
  [ $arc = 0 ] || why="${why:+$why; }$(printf '%s\n' "$al" | tail -1)"
  if [ -z "$why" ]; then
    echo "CHECK S8.4 PASS scripts/check-static.sh --quick exits 0 ($pend rules PENDING until their files exist; a full run fails on a PENDING one) and its allowlist equals scripts/kit-lib/static-allowlist.txt"
    return 0
  fi
  if [ -n "$KIT_PLANT" ]; then echo "CHECK S8.4 FAIL planted: $planted: $why"; else echo "CHECK S8.4 FAIL $why"; fi
  return 1
}

# ---- S8.10: no camera, microphone or Full Disk Access ------------------------------------------

check_S8_10() {
  local pout prc eout erc tout trc prout prrc rc td src why="" planted="" needs="" tccwhat="the permission database has no Full Disk Access, camera or microphone row for the app"
  # From slice 3 the session comes first: s8_close_window stops the prompts watcher the recipe started before the app, after the
  # last open. The plant needs only a copy of the plist and entitlements, so it runs no session.
  if [ "$KIT_SLICE" -ge 3 ] && [ -z "$KIT_PLANT" ]; then
    if ! declare -F s8_close_window >/dev/null; then
      echo "RERUN S8.10 not valid: the S8 session functions are not loaded (scripts/verify.sh --quick sources checks-s8.sh only); run the id through the kit's runner (S8 --ids S8.10)"
      return 4
    fi
    s8_close_window S8.10; rc=$?
    case $rc in
      0) ;;
      3) echo "CHECK S8.10 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
      *) echo "RERUN S8.10 not valid: the S8 session could not be run (s8_close_window exited $rc)"; return 4 ;;
    esac
  fi
  if [ -n "$KIT_PLANT" ]; then
    td="$(mktemp -d "$KIT_TMP/kit-s8-plant.XXXXXX")" || { echo "RERUN S8.10 not valid: no temp folder for the plant"; return 4; }
    src="$(s8_bundle)/Contents/Info.plist"
    if [ ! -f "$src" ]; then rm -rf "$td"; echo "RERUN S8.10 not valid: no Info.plist at $src"; return 4; fi
    cp "$src" "$td/Info.plist"
    plutil -insert NSCameraUsageDescription -string "planted camera string" "$td/Info.plist"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/><key>com.apple.security.device.camera</key><true/><key>com.apple.security.device.audio-input</key><true/></dict></plist>\n' > "$td/ent.xml"
    planted="NSCameraUsageDescription added to a copy of Info.plist, and camera and audio-input entitlements in a planted entitlements file"
    pout="$(kq "$S8_KP" plist --file "$td/Info.plist" 2>&1)"; prc=$?
    eout="$(kq "$S8_KP" entitlements --from "$td/ent.xml" 2>&1)"; erc=$?
    rm -rf "$td"
  else
    pout="$(kq "$S8_KP" plist 2>&1)"; prc=$?
    eout="$(kq "$S8_KP" entitlements 2>&1)"; erc=$?
  fi
  printf '%s\n' "$pout"
  printf '%s\n' "$eout"
  if [ $prc = 4 ] || [ $erc = 4 ]; then
    echo "RERUN S8.10 not valid: $(printf '%s\n%s\n' "$pout" "$eout" | awk '/^no / { print; exit }')"
    return 4
  fi
  [ $prc = 0 ] || why="plist: $(printf '%s\n' "$pout" | tail -1)"
  [ $erc = 0 ] || why="${why:+$why; }entitlements: $(printf '%s\n' "$eout" | tail -1)"
  if [ "$KIT_SLICE" -lt 3 ]; then
    echo "tcc: not run until slice 3"
  else
    # not through kq: the script saves its own tcc.txt in the evidence folder
    tout="$("$S8_KP" tcc 2>&1 </dev/null)"; trc=$?
    printf '%s\n' "$tout"
    case "$tout" in
      *"WARNING: no user-scope permission database was read"*) tccwhat="the system permission database has no Full Disk Access row for the app (no user database was read, so camera and microphone rows were not checked)" ;;
    esac
    case $trc in
      0) ;;
      3) needs="$(printf '%s\n' "$tout" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')" ;;
      *) why="${why:+$why; }tcc: $(printf '%s\n' "$tout" | tail -1)" ;;
    esac
  fi
  # What the watcher saw through the whole session (the plant has no session). Exit 4 is never a pass: an unanswered prompt leaves
  # no TCC row, so the tcc part cannot stand in for the watcher.
  if [ "$KIT_SLICE" -ge 3 ] && [ -z "$KIT_PLANT" ]; then
    prout="$(kq "$S8_KP" prompts result s8 2>&1 </dev/null)"; prrc=$?
    printf '%s\n' "$prout"
    case $prrc in
      0) ;;
      1) why="${why:+$why; }prompts: a dialog named Sesame asked for Full Disk Access, camera or microphone: $(printf '%s\n' "$prout" | tail -1)" ;;
      4) echo "RERUN S8.10 not valid: no prompts watcher ran in this session (the recipe tree starts it before the app; an unanswered prompt leaves no permission row, so tcc cannot stand in for it)"; return 4 ;;
      *) why="${why:+$why; }prompts: $(printf '%s\n' "$prout" | tail -1)" ;;
    esac
  elif [ "$KIT_SLICE" -lt 3 ]; then
    echo "prompts: not read until slice 3"
  fi
  if [ -n "$why" ]; then
    if [ -n "$KIT_PLANT" ]; then echo "CHECK S8.10 FAIL planted: $planted: $why"; else echo "CHECK S8.10 FAIL $why"; fi
    return 1
  fi
  if [ -n "$needs" ]; then
    echo "CHECK S8.10 NEEDS-A-PERSON the plist, entitlements and prompts hold, only the tcc part (the permission database) could not be read: $needs"
    return 0
  fi
  if [ "$KIT_SLICE" -ge 3 ]; then
    echo "CHECK S8.10 PASS the plist has no camera or microphone usage string, the entitlements hold none of the camera, audio-input and all-files entitlements (only com.apple.security.automation.apple-events), $tccwhat, and the watcher that ran through the session saw no dialog naming them (what it did see is printed above, for the person, S8.N1)"
    return 0
  fi
  echo "CHECK S8.10 PASS the plist has no camera or microphone usage string and the entitlements hold none of the camera, audio-input and all-files entitlements (only com.apple.security.automation.apple-events)"
  return 0
}

# ---- S8.13: models, index and settings live in the Sesame folder; no other download -------------

check_S8_13() {
  local where dir mode out rc td mout mbad lout lrc why="" v needs="" nrc qrc qlogs nets="" reason
  if [ "$KIT_SLICE" -lt 3 ]; then echo "S8.13 partial: logs scan and net log wait for slice 3"; fi
  if [ -n "$KIT_PLANT" ]; then
    td="$(mktemp -d "$KIT_TMP/kit-s8-plant.XXXXXX")" || { echo "RERUN S8.13 not valid: no temp folder for the plant"; return 4; }
    mkdir -p "$td/Sesame/models" && : > "$td/Sesame/models/stray.partial"
    printf '{"startPressed": false}\n' > "$td/Sesame/settings.json"
    out="$(kq "$S8_KP" layout --dir "$td/Sesame" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    rm -rf "$td"
    if [ $rc != 0 ]; then
      echo "CHECK S8.13 FAIL planted: a stray models/stray.partial file was refused by layout: $(printf '%s\n' "$out" | tail -1)"
      return 1
    fi
    echo "CHECK S8.13 PASS layout accepted a planted stray models/stray.partial file"
    return 0
  fi

  s8_need_baseline S8.13 || return 4

  # From slice 3 the two parts that wait for the S8 session: the net log (S8.7's summary, through s8_net_summary, which closes the
  # window first) and "logs/ holds only event names" (S8.9's scan result). Both are read here, once each; the same session made both.
  if [ "$KIT_SLICE" -ge 3 ]; then
    if ! declare -F s8_net_summary >/dev/null || ! declare -F s8d_query_scan >/dev/null; then
      echo "RERUN S8.13 not valid: the S8 session functions are not loaded (run the id through the kit's runner: S8 --ids S8.13)"
      return 4
    fi
    s8_net_summary S8.13; nrc=$?
    case $nrc in
      0) ;;
      1) why="the net log shows a destination other than the model host (or a connection outside the mirror's window, 1,000,000 bytes sent, or a connection after the last model request): $(printf '%s\n' "$S8_NET_TEXT" | s8d_failure_lines | head -3 | tr '\n' ';')" ;;
      3) needs="the net log part needs the administrator session or a person step of the S8 session (the NEEDS A PERSON line above says which)" ;;
      *) echo "RERUN S8.13 not valid: the net summary could not be made (s8_net_summary exited $nrc)"; return 4 ;;
    esac
    s8d_query_scan S8.13; qrc=$?
    case $qrc in
      0) ;;
      3) needs="${needs:+$needs; }the S8 session needs a person (see the lines above)" ;;
      *) echo "RERUN S8.13 not valid: the query scan result could not be read (s8d_query_scan exited $qrc)"; return 4 ;;
    esac
    if [ $qrc = 0 ]; then
      case "$S8D_SCAN_RC" in
        0) echo "logs/: the S8.9 scan found no query marker in the Sesame folder, logs/ included" ;;
        1)
          qlogs="$(printf '%s\n' "$S8D_SCAN_OUT" | awk '/^FOUND / && /\/logs\// { print; k++ } k >= 3 { exit }' | tr '\n' ' ')"
          if [ -n "$qlogs" ]; then why="${why:+$why; }logs/ holds a query marker: $qlogs"
          else echo "logs/: no marker in logs/ (the scan found markers elsewhere, S8.9 fails on those)"; fi ;;
        *) echo "RERUN S8.13 not valid: the S8.9 scan did not run (query-scan exited $S8D_SCAN_RC)"; return 4 ;;
      esac
    fi
    if [ $nrc != 3 ] && [ $qrc = 0 ]; then
      reason="$(s8d_same_session)" || { echo "RERUN S8.13 not valid: $reason"; return 4; }
    fi
  fi

  where="$(kq "$KIT_SCRIPTS/kit-launch.sh" where 2>&1)"
  dir="$(printf '%s\n' "$where" | sed -n 1p)"
  mode="$(printf '%s\n' "$where" | sed -n 2p)"
  case "$mode" in
    mode=*)
      echo "Sesame folder: $dir ($mode)"
      out="$(kq "$S8_KP" layout 2>&1)"; rc=$?
      printf '%s\n' "$out"
      [ $rc = 0 ] || why="layout: $(printf '%s\n' "$out" | tail -1)"
      if [ ! -f "$dir/settings.json" ]; then
        why="${why:+$why; }no settings.json in $dir (the app writes it when Start indexing is pressed; red until task plan-1-t28)"
      elif ! plutil -p "$dir/settings.json" >/dev/null 2>&1; then
        why="${why:+$why; }settings.json is not valid JSON"
      else
        v="$(plutil -extract startPressed raw -o - "$dir/settings.json" 2>/dev/null)"
        case "$v" in
          true|false) echo "settings.json: valid JSON, startPressed $v" ;;
          *) why="${why:+$why; }settings.json has no startPressed flag" ;;
        esac
      fi ;;
    *)
      echo "no Sesame folder at $dir"
      why="no Sesame folder at $dir, so no settings.json (the app writes it when Start indexing is pressed; red until task plan-1-t28)" ;;
  esac

  # No other download: the mirror's log lists requests only for the two model file names.
  mout="$(kq "$KIT_SCRIPTS/kit-mirror.sh" requests 2>&1)"
  printf '%s\n' "$mout"
  mbad="$(printf '%s\n' "$mout" | s8_mirror_strays "$KIT_LIB/models.tsv" | head -3)"
  [ -z "$mbad" ] || why="${why:+$why; }the mirror log shows a request for something other than the two model files: $(printf '%s' "$mbad" | tr '\n' ' ')"

  # Nothing else new under Library (S8.12's scan, leaving the Sesame folder itself out). --new-only: this check is
  # about what this run added, so a leftover from an earlier run is not counted here; S8.12 counts it.
  lout="$(kq "$S8_KP" library-scan --ignore-sesame-folder --new-only 2>&1)"; lrc=$?
  printf '%s\n' "$lout"
  case $lrc in
    0) ;;
    4) echo "RERUN S8.13 not valid: $(printf '%s\n' "$lout" | awk '/^not valid: / { sub(/^not valid: /, ""); print; exit }')"; return 4 ;;
    *) why="${why:+$why; }something new under Library: $(s8_findings "$lout" | tr '\n' ' ')" ;;
  esac

  if [ -n "$why" ]; then echo "CHECK S8.13 FAIL $why"; return 1; fi
  if [ -n "$needs" ]; then
    echo "CHECK S8.13 NEEDS-A-PERSON the Sesame folder, settings.json, the mirror log and the Library part hold, the rest is not read: $needs"
    return 0
  fi
  if [ "$KIT_SLICE" -ge 3 ]; then
    echo "CHECK S8.13 PASS the Sesame folder holds only what the design allows, settings.json is valid with its startPressed flag, the mirror log shows only the two model files, nothing else is new under Library, logs/ holds no query marker (S8.9's scan) and the net log shows no destination other than the mirror (S8.7's summary), both from the same session"
    return 0
  fi
  echo "CHECK S8.13 PASS the Sesame folder holds only what the design allows, settings.json is valid with its startPressed flag, the mirror log shows only the two model files, nothing else is new under Library (partial: logs scan and net log wait for slice 3)"
  return 0
}

# ---- S8.12: uninstall leaves nothing -----------------------------------------------------------

check_S8_12() {
  local out rc pref id made=0 planted="" why
  s8_need_baseline S8.12 || return 4
  kq "$KIT_SCRIPTS/kit-launch.sh" stop
  if [ -n "$KIT_PLANT" ]; then
    id="$(plutil -extract CFBundleIdentifier raw -o - "$(s8_bundle)/Contents/Info.plist" 2>/dev/null)"
    if [ -z "$id" ]; then echo "RERUN S8.12 not valid: no Info.plist to read the app's identifier from"; return 4; fi
    pref="$KIT_ROOT/home/Library/Preferences"
    [ -d "$pref" ] || { mkdir -p "$pref" && made=1; }
    printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>NSNavLastRootDirectory</key><string>~/Desktop</string></dict></plist>\n' > "$pref/$id.plist"
    planted="a leftover $id.plist in the throwaway home's Library/Preferences, like the one AppKit's folder picker may leave"
  fi
  # library-scan counts only paths named sesame that appeared in the real ~/Library after the kit's baseline
  # (kit-privacy.sh baseline), the same as the throwaway home; --new-only means the same as the default.
  out="$(kq "$S8_KP" library-scan --delete-first 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ -n "$planted" ]; then
    rm -f "$pref/$id.plist"
    [ $made = 1 ] && rmdir "$pref" 2>/dev/null
  fi
  case $rc in
    0)
      echo "CHECK S8.12 PASS the app was quit, the Sesame folder and the app copy were deleted, and no new path named sesame appeared in the real ~/Library after the baseline (only Caches/claude-cli-nodejs is left out), no new plist or text file holds the app identifier and no \$TMPDIR/Sesame-* folder appeared"
      return 0 ;;
    4)
      echo "RERUN S8.12 not valid: $(printf '%s\n' "$out" | awk '/^not valid: / { sub(/^not valid: /, ""); print; exit }')"
      return 4 ;;
    *)
      why="$(s8_findings "$out" | tr '\n' ' ')"
      [ -n "$why" ] || why="$(printf '%s\n' "$out" | tail -1)"
      if [ -n "$planted" ]; then echo "CHECK S8.12 FAIL planted: $planted: $why"
      else echo "CHECK S8.12 FAIL $why"; fi
      return 1 ;;
  esac
}

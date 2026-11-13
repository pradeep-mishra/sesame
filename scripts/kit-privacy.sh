#!/bin/bash
# kit-privacy.sh <mode> ...: the S8 file-on-disk checks, and the S7.18 login-item reader (verify.md,
# Kit scripts). Built so far: ping | baseline | plist | entitlements | static-allowlist |
# library-scan | layout | login-item | schema-scan | tcc | query-scan | prompts. Every sudo here is `sudo -n`:
# the one password prompt is `kit-perms.sh ask-admin`, never this script.
#
#   schema-scan [--db <file>]    every table and column name of the index (default: the Sesame index of the
#                                throwaway home) is split into words (scripts/kit-lib/schemawords.awk) and judged:
#                                `forbidden: <name>` for a tracking word (query, history, recent, open, hit, usage,
#                                boost ... or a bare count), else `allowed: <name>`. The verdicts are saved to
#                                schema.txt. The control runs first on a throwaway sqlite file under run/ holding
#                                search_count, last_opened, lastOpened, history and page_count, and must give the
#                                first four forbidden and the last allowed, else exit 4. Exit 1 when a name is
#                                forbidden. The target is opened `sqlite3 -readonly`.
#   tcc [--db <file>]... [--identifier <id>]
#                                the permission database (`sqlite3 -readonly -safe`; default: the user's and the
#                                system's TCC.db, each when present) has no Full Disk Access, camera or microphone
#                                row for the app's identifier (read from the bundle's Info.plist, or --identifier):
#                                else `TCC row: <service>` and exit 1. A database that cannot be read is exit 3
#                                NEEDS A PERSON: Full Disk Access for the terminal. The control runs first on a
#                                throwaway database with a camera row for a made-up identifier and must find it,
#                                else exit 4. The real database is only ever read by a person's run, never a test.
#   query-scan <markers-file> [--no-log]
#                                no marker (one per line) is in the Sesame folder (every file, binary safe), the
#                                throwaway home's Library/Preferences, Caches, HTTPStorages, Saved Application State
#                                and Logs, the scratch folders $TMPDIR/Sesame-*, the mirror's request log, or the
#                                unified log lines of the Sesame processes (`log show`, a predicate on the process
#                                name prefix Sesame; --no-log leaves it out). `FOUND <marker> in <file>` and exit 1,
#                                else `no marker found in <n> places` (8, or 9 with the log). The controls run first
#                                and are saved to scan-controls.txt: a control marker qm-control-<random> (never in the
#                                markers file) is planted in a throwaway file in each place that lies in the home or
#                                $TMPDIR (and a `logger` line for the log), must be found in every one, a marker that
#                                was never planted must not be, and every control file (and folder the control made) is
#                                removed before the script returns. A control not found is exit 4 naming the place.
#   prompts start <name>         the watcher: once a second the window list of the system dialog processes is read
#                                (osascript, System Events) and each window naming Sesame is kept in
#                                run/prompts/<name>.windows; its pid is in run/pids/prompts-<name>.pid and it ends by
#                                itself when that file is gone (a reset that deletes run/ cannot leave one behind)
#   prompts stop <name>          ends it, saves prompts.txt and the one-line result run/prompts/<name>.result
#                                (`seen=<n> exit=<0|1>`); exit 1 when a dialog names Full Disk Access, camera or
#                                microphone for Sesame, else 0; exit 4 `not valid: no prompts watcher <name> was running`
#                                when start never ran
#   prompts result <name>        only reads the saved result, same exit codes (4 when none is saved)
#   prompts parse --sample <file>
#                                the parser alone, on a hand-written window dump (one window per line)
#
#   login-item                  `sudo -n sfltool dumpbtm` (under the administrator session; no session is exit 3
#                                NEEDS A PERSON naming ask-admin), parsed for Sesame's identifier (read from the
#                                bundle's Info.plist): prints exactly one of `present and enabled`, `present and
#                                disabled`, `absent` or `unreadable`, then the last `login status=` line of the
#                                app's logs/app.log (what SMAppService said, U6). Its control reads the same
#                                text for an identifier that cannot exist and must read `absent`, else exit 4.
#
#   ping                         every tool answers; the plist, entitlement and library scans are shown to go
#                                red on a planted fault; the permission database opens read-only (else
#                                NEEDS A PERSON: Full Disk Access for the terminal); the administrator part
#                                is reported as first needed in slice 2
#   baseline                     records every path under the Library places of the throwaway home and of the
#                                real ~/Library (the scan reports only what appeared after it); run it right
#                                after kit-reset.sh
#   plist [--file <Info.plist>]  Sesame.app's Info.plist (`plutil -p`): no camera or microphone usage string
#   entitlements [--app <Sesame.app> | --from <entitlements.xml>]
#                                `codesign -d --entitlements :-`: no camera, audio-input or all-files
#                                entitlement; any other entry is NOTED (the design rule is apple-events only)
#   static-allowlist             the allowlist of check-static.sh equals scripts/kit-lib/static-allowlist.txt
#   library-scan [--delete-first] [--ignore-sesame-folder] [--new-only]
#                                no path named sesame (any case), no plist or text file holding the app's
#                                identifier, under the Library places of the throwaway home and of the real
#                                ~/Library, counting only what appeared after the baseline in both (a path that
#                                was there at the baseline is not a finding; the baseline note names it; the only
#                                other exclusion is Caches/claude-cli-nodejs/, Claude Code's own cache), no
#                                $TMPDIR/Sesame-* folder. --new-only is kept for S8.13 and means the same as the
#                                default now. --delete-first first deletes the Sesame folder and the app copy in
#                                the throwaway home (the app must be quit). --ignore-sesame-folder leaves
#                                the Sesame folder itself out (the "nothing else new under Library" part of
#                                S8.13, while the app is still in use). Controls run first: a path, a file
#                                and a benign file are planted in every place and must be found, or not, as
#                                they should; a control that fails is exit 4.
#   layout [--dir <folder>]      the Sesame folder with mode, sizes and inodes, the model files' SHA-256, and
#                                every entry that is not one of models/, index.sqlite (-wal, -shm),
#                                settings.json, logs/ as UNEXPECTED
# Seams for the kit's own plants (never used by a person): KIT_ALLOWLIST_FILE replaces the kit's allowlist
# file; --file, --from and --dir point a mode at a throwaway input.
# Exit codes: 0 pass; 1 a check failed; 2 usage; 3 a person-step is missing (NEEDS A PERSON: ...); 4 not valid
# (a precondition did not hold: rerun, never a pass).
. "$(dirname "$0")/kit-lib/common.sh"

PRIV="$KIT_ROOT/run/privacy"
SESAME_DIR="$KIT_ROOT/home/Library/Application Support/Sesame"
HOME_LIB="$KIT_ROOT/home/Library"
REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')"
REAL_HOME="${REAL_HOME:-$HOME}"
# Seam for the kit's own tests (never used by a person): a throwaway folder stands in for the real home.
REAL_HOME="${KIT_REAL_HOME_SEAM:-$REAL_HOME}"
REAL_LIB="$REAL_HOME/Library"
# The places of the S8(g) scan (feature map S8.12), under each Library.
LIB_PLACES=("Application Support" "Preferences" "Caches" "HTTPStorages" "Saved Application State" "Logs" "Containers" "Group Containers" "WebKit" "Cookies" "LaunchAgents")
# Sesame's own two Caches folders (the app's and the helper's), named in the scan list so each is checked by name.
SESAME_CACHES=("Caches/app.sesame.Sesame" "Caches/SesameHelper")

usage() {
  cat >&2 <<'EOF'
usage: kit-privacy.sh ping | baseline | static-allowlist
       kit-privacy.sh plist [--file <Info.plist>]
       kit-privacy.sh entitlements [--app <Sesame.app> | --from <entitlements.xml>]
       kit-privacy.sh library-scan [--delete-first] [--ignore-sesame-folder] [--new-only]
       kit-privacy.sh layout [--dir <folder>]
       kit-privacy.sh login-item
       kit-privacy.sh schema-scan [--db <file>]
       kit-privacy.sh tcc [--db <file>] [--identifier <id>]
       kit-privacy.sh query-scan <markers-file> [--no-log]
       kit-privacy.sh prompts start <name> | stop <name> | result <name> | parse --sample <file>
EOF
}

# ---- small helpers ---------------------------------------------------------------------------

# save_named <name> <text>: a named copy in the evidence folder (plist.txt, entitlements.txt ...).
save_named() {
  local dir
  [ -z "$KIT_NO_EVIDENCE" ] || return 0
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$2" > "$dir/$1.txt"
  return 0
}

need_state() {
  if [ ! -d "$KIT_ROOT/run" ] || [ ! -f "$KIT_ROOT/run/evidence-dir" ]; then
    echo "no starting state: run scripts/kit-reset.sh --id <S1..S9|kit> --version <V> first"
    return 1
  fi
  return 0
}

# The bundle that is checked: the kit's copy of the app, else the bundle in dist/.
bundle_path() {
  if [ -d "$KIT_APP" ]; then printf '%s' "$KIT_APP"
  elif [ -d "$KIT_PROJECT/dist/Sesame.app" ]; then printf '%s' "$KIT_PROJECT/dist/Sesame.app"
  else return 1
  fi
}

# The app's identifier, from Info.plist (the copy first, then dist/, so it still reads after the copy is deleted).
app_identifier() {
  local p id
  for p in "$KIT_APP/Contents/Info.plist" "$KIT_PROJECT/dist/Sesame.app/Contents/Info.plist"; do
    [ -f "$p" ] || continue
    id="$(plutil -extract CFBundleIdentifier raw -o - "$p" 2>/dev/null)"
    if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
  done
  return 1
}

# top_keys <plist file>: the top-level keys, one per line (plutil -p prints them with two spaces of indent).
top_keys() {
  plutil -p "$1" 2>/dev/null | awk '/^  "/ { k = $0; sub(/^  "/, "", k); sub(/" =>.*/, "", k); print k }'
}

# The spec's camera and microphone usage strings (S8.10): any Info.plist key naming one.
forbidden_plist_keys() {
  top_keys "$1" | awk 'tolower($0) ~ /camera|microphone|audiocapture/ { print }'
}

# The entitlements that must never appear (S8.10): camera, audio input, all files (hand-written).
forbidden_entitlements() {
  top_keys "$1" | awk 'tolower($0) ~ /device\.camera|device\.audio-input|device\.microphone|files\.all|temporary-exception\.files|tcc\.allow|systempolicyallfiles|storage-exempt/ { print }'
}

mktd() { mktemp -d "$KIT_TMP/kit-privacy.XXXXXX"; }

# ---- plist, entitlements ---------------------------------------------------------------------

plist_report() { # plist_report <Info.plist> : the listing and the verdict; status 0 pass, 1 fail
  local f="$1" bad k
  echo "PLIST $f"
  if ! plutil -lint "$f" >/dev/null 2>&1; then
    echo "PLIST FAILED: plutil -lint refuses $f"
    return 1
  fi
  echo "OK plutil -lint"
  plutil -p "$f"
  bad="$(forbidden_plist_keys "$f")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | while IFS= read -r k; do echo "FORBIDDEN camera or microphone usage string: $k"; done
    echo "PLIST FAILED: a camera or microphone usage string is present"
    return 1
  fi
  echo "PLIST OK: no camera or microphone usage string"
  return 0
}

cmd_plist() {
  local f="" b out rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) [ $# -ge 2 ] || { usage; return 2; }; f="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [ -z "$f" ]; then
    b="$(bundle_path)" || { echo "no bundle: neither $KIT_APP nor dist/Sesame.app exists (scripts/bundle.sh makes it)"; return 4; }
    f="$b/Contents/Info.plist"
  fi
  [ -f "$f" ] || { echo "no Info.plist at $f"; return 4; }
  out="$(plist_report "$f")"; rc=$?
  printf '%s\n' "$out"
  save_named plist "$out"
  return $rc
}

ent_report() { # ent_report <entitlements xml file> <label>
  local xml="$1" keys k bad
  echo "ENTITLEMENTS $2"
  if ! plutil -p "$xml" >/dev/null 2>&1; then
    echo "ENTITLEMENTS FAILED: the entitlements could not be read as a property list"
    return 1
  fi
  keys="$(top_keys "$xml")"
  if [ -z "$keys" ]; then
    echo "NOTED no entitlements at all (the design lists com.apple.security.automation.apple-events)"
  else
    printf '%s\n' "$keys" | while IFS= read -r k; do echo "ENTITLEMENT $k"; done
  fi
  bad="$(forbidden_entitlements "$xml")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | while IFS= read -r k; do echo "FORBIDDEN camera, audio-input or all-files entitlement: $k"; done
    echo "ENTITLEMENTS FAILED: a camera, audio-input or all-files entitlement is present"
    return 1
  fi
  printf '%s\n' "$keys" | while IFS= read -r k; do
    [ -n "$k" ] && [ "$k" != com.apple.security.automation.apple-events ] && echo "NOTED extra entitlement: $k (the design rule is apple-events only)"
  done
  if [ "$keys" = com.apple.security.automation.apple-events ]; then
    echo "ENTITLEMENTS OK: only com.apple.security.automation.apple-events"
  else
    echo "ENTITLEMENTS OK: none of the camera, audio-input and all-files entitlements"
  fi
  return 0
}

cmd_entitlements() {
  local app="" from="" td xml out rc label
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) [ $# -ge 2 ] || { usage; return 2; }; app="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || { usage; return 2; }; from="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  [ -z "$app" ] || [ -z "$from" ] || { usage; return 2; }
  td="$(mktd)" || return 1
  if [ -n "$from" ]; then
    [ -f "$from" ] || { echo "no such file: $from"; rm -rf "$td"; return 4; }
    cp "$from" "$td/ent.xml"; label="$from"
  else
    [ -n "$app" ] || app="$(bundle_path)" || { echo "no bundle: neither $KIT_APP nor dist/Sesame.app exists (scripts/bundle.sh makes it)"; rm -rf "$td"; return 4; }
    if ! codesign -d --entitlements :- "$app" > "$td/ent.xml" 2> "$td/err"; then
      echo "codesign could not read $app: $(tail -1 "$td/err")"
      rm -rf "$td"
      return 1
    fi
    label="codesign -d --entitlements :- $app"
  fi
  out="$(ent_report "$td/ent.xml" "$label")"; rc=$?
  rm -rf "$td"
  printf '%s\n' "$out"
  save_named entitlements "$out"
  return $rc
}

# ---- static-allowlist ------------------------------------------------------------------------

cmd_static_allowlist() {
  local ours="${KIT_ALLOWLIST_FILE:-$KIT_LIB/static-allowlist.txt}" td rc only_theirs only_ours n
  [ $# -eq 0 ] || { usage; return 2; }
  [ -f "$ours" ] || { echo "no allowlist file: $ours"; return 4; }
  td="$(mktd)" || return 1
  "$KIT_SCRIPTS/check-static.sh" --allowlist > "$td/theirs.raw" 2> "$td/err"; rc=$?
  if [ $rc != 0 ]; then
    echo "scripts/check-static.sh --allowlist exited $rc: $(tail -1 "$td/err")"
    rm -rf "$td"
    return 1
  fi
  awk '{ sub(/#.*/, "") } NF { $1 = $1; print }' "$td/theirs.raw" | LC_ALL=C sort > "$td/theirs"
  awk '{ sub(/#.*/, "") } NF { $1 = $1; print }' "$ours" | LC_ALL=C sort > "$td/ours"
  if [ ! -s "$td/theirs" ]; then
    echo "ALLOWLIST FAILED: check-static.sh --allowlist printed no entries"
    rm -rf "$td"
    return 1
  fi
  only_theirs="$(LC_ALL=C comm -23 "$td/theirs" "$td/ours")"
  only_ours="$(LC_ALL=C comm -13 "$td/theirs" "$td/ours")"
  n="$(wc -l < "$td/ours" | tr -d ' ')"
  rm -rf "$td"
  if [ -z "$only_theirs" ] && [ -z "$only_ours" ]; then
    echo "ALLOWLIST OK: the allowlist of check-static.sh equals $ours ($n entries)"
    return 0
  fi
  printf '%s\n' "$only_theirs" | while IFS= read -r l; do [ -n "$l" ] && echo "only in check-static.sh: $l"; done
  printf '%s\n' "$only_ours" | while IFS= read -r l; do [ -n "$l" ] && echo "only in $ours: $l"; done
  echo "ALLOWLIST FAILED: the two lists differ (a new entry is a design change)"
  return 1
}

# ---- the Library scan ------------------------------------------------------------------------

# list_paths <Library root> : every path under the scan places, relative to the root, sorted, on stdout.
# What find cannot read is counted in $LIST_ERR when the caller set it.
list_paths() {
  local root="$1" p
  for p in "${LIB_PLACES[@]}"; do
    [ -d "$root/$p" ] && find "$root/$p" 2>>"${LIST_ERR:-/dev/null}"
  done | awk -v n="${#root}" '{ print substr($0, n + 2) }' | LC_ALL=C sort
}

cmd_baseline() {
  local err n_home n_real t
  [ $# -eq 0 ] || { usage; return 2; }
  need_state || return 4
  mkdir -p "$PRIV" || return 1
  err="$PRIV/baseline.err"; : > "$err"
  LIST_ERR="$err" list_paths "$HOME_LIB" > "$PRIV/baseline-home.txt"
  LIST_ERR="$err" list_paths "$REAL_LIB" > "$PRIV/baseline-real.txt"
  n_home="$(wc -l < "$PRIV/baseline-home.txt" | tr -d ' ')"
  n_real="$(wc -l < "$PRIV/baseline-real.txt" | tr -d ' ')"
  t="$(date +%Y-%m-%dT%H:%M:%S)"
  printf '%s\n' "$t" > "$PRIV/baseline.time"
  echo "BASELINE $t: $n_home paths under $HOME_LIB, $n_real paths under $REAL_LIB"
  if [ -s "$err" ]; then
    echo "note: $(wc -l < "$err" | tr -d ' ') places could not be read (macOS keeps some folders from a terminal without Full Disk Access); the scan skips the same ones"
  fi
  rm -f "$err"
  local old foreign
  old="$(awk 'tolower($0) ~ /sesame/ && index($0, "Caches/claude-cli-nodejs/") != 1' "$PRIV/baseline-real.txt" | head -5)"
  if [ -n "$old" ]; then
    echo "note: these paths in the real Library already name sesame at the baseline (leftovers of earlier runs); library-scan does not count them, it counts only paths that appear after this baseline. The kit never removes anything from your own Library; remove them yourself if you want a clean Library:"
    printf '%s\n' "$old" | sed 's/^/  /'
  fi
  foreign="$(awk 'tolower($0) ~ /sesame/ && index($0, "Caches/claude-cli-nodejs/") == 1' "$PRIV/baseline-real.txt" | wc -l | tr -d ' ')"
  [ "$foreign" = 0 ] || echo "note: $foreign more are under Caches/claude-cli-nodejs, Claude Code's own cache, which is named after the project folder; the scan leaves that cache out"
  return 0
}

# scan_root <root> <baseline file> <hits file> : appends `name <rel>` and `content <rel>` lines for every path
# that appeared after the baseline; sets SCAN_NEW to the number of new paths. Needs APP_ID.
scan_root() {
  local root="$1" base="$2" out="$3" td rel f sz
  td="$(mktd)" || return 1
  list_paths "$root" > "$td/cur"
  LC_ALL=C comm -13 "$base" "$td/cur" > "$td/new"
  SCAN_NEW="$(wc -l < "$td/new" | tr -d ' ')"
  awk 'tolower($0) ~ /sesame/ { print "name " $0 }' "$td/new" >> "$out"
  awk 'tolower($0) ~ /\.(plist|txt|log|json|xml|cfg|ini|conf|yaml|yml|md)$/' "$td/new" > "$td/cand"
  while IFS= read -r rel; do
    f="$root/$rel"
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    sz="$(stat -f %z "$f" 2>/dev/null)"
    [ "${sz:-0}" -le 5242880 ] || continue
    grep -a -F -q -- "$APP_ID" "$f" 2>/dev/null && echo "content $rel" >> "$out"
  done < "$td/cand"
  rm -rf "$td"
  return 0
}

# named_caches_check <label> <Library root> <hits file> : each of Sesame's two Caches folders (SESAME_CACHES) is looked
# at by name; one that exists and is not already a finding is added to the hits.
named_caches_check() {
  local label="$1" root="$2" hits="$3" c
  for c in "${SESAME_CACHES[@]}"; do
    if [ -e "$root/$c" ]; then
      grep -F -x -q -- "name $c" "$hits" || echo "name $c" >> "$hits"
      echo "named Sesame Caches folder exists in the $label Library: $root/$c"
    else
      echo "checked $root/$c: not there"
    fi
  done
}

# plant_set <root> <random> <created-dirs file> : in every place, a file whose NAME holds sesame, a plist whose
# CONTENT holds the app's identifier, and a benign plist that must never be reported.
plant_set() {
  local root="$1" r="$2" created="$3" p d
  [ -d "$root" ] || { mkdir -p "$root" && echo "$root" >> "$created"; }
  for p in "${LIB_PLACES[@]}"; do
    d="$root/$p"
    [ -d "$d" ] || { mkdir -p "$d" && echo "$d" >> "$created"; }
    : > "$d/zz-sesame-name-$r"
    printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$APP_ID" > "$d/zz-content-$r.plist"
    printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.other.Benign</string></dict></plist>\n' > "$d/zz-benign-$r.plist"
  done
}

unplant_set() { # unplant_set <root> <random> <created-dirs file>
  local root="$1" r="$2" created="$3" p d
  for p in "${LIB_PLACES[@]}"; do
    d="$root/$p"
    rm -f "$d/zz-sesame-name-$r" "$d/zz-content-$r.plist" "$d/zz-benign-$r.plist"
  done
  [ -f "$created" ] && LC_ALL=C sort -r "$created" | while IFS= read -r d; do rmdir "$d" 2>/dev/null; done
  rm -f "$created"
}

# control_root <label> <root> <baseline file> : plants, scans, checks, removes. Status 0 when every place is right.
control_root() {
  local label="$1" root="$2" base="$3" r created hits p bad=0
  r="$$-$RANDOM"
  created="$PRIV/created.$r"; : > "$created"
  hits="$PRIV/control-hits.$r"; : > "$hits"
  plant_set "$root" "$r" "$created"
  scan_root "$root" "$base" "$hits"
  for p in "${LIB_PLACES[@]}"; do
    if ! grep -F -x -q -- "name $p/zz-sesame-name-$r" "$hits"; then
      echo "CONTROL $label FAILED $p: the planted file named sesame was not found"; bad=1; continue
    fi
    if ! grep -F -x -q -- "content $p/zz-content-$r.plist" "$hits"; then
      echo "CONTROL $label FAILED $p: the planted file holding $APP_ID was not found"; bad=1; continue
    fi
    if grep -F -q -- "zz-benign-$r" "$hits"; then
      echo "CONTROL $label FAILED $p: a benign plist was reported"; bad=1; continue
    fi
    echo "CONTROL $label $p: planted name found, planted content found, benign file not reported"
  done
  unplant_set "$root" "$r" "$created"
  rm -f "$hits"
  [ $bad = 0 ] && echo "CONTROL $label OK: ${#LIB_PLACES[@]} places"
  return $bad
}

# The $TMPDIR/Sesame-* folders (the helper's scratch folders); the control plants one and must see it.
tmp_sesame_dirs() { # tmp_sesame_dirs : one path per line
  local g
  for g in "$KIT_TMP"/Sesame-*; do
    [ -e "$g" ] && printf '%s\n' "$g"
  done
  return 0
}

control_tmp() {
  local r d found
  r="$$-$RANDOM"
  d="$KIT_TMP/Sesame-control-$r"
  mkdir "$d" || { echo "CONTROL tmp FAILED: could not make $d"; return 1; }
  found="$(tmp_sesame_dirs | grep -F -x -c -- "$d")"
  rmdir "$d"
  if [ "$found" = 1 ]; then
    echo "CONTROL tmp OK: the planted $KIT_TMP/Sesame-control-<n> folder was found and removed"
    return 0
  fi
  echo "CONTROL tmp FAILED: the planted Sesame-control folder was not found"
  return 1
}

# The Sesame folder's listing is saved just before --delete-first removes it, so `layout` can still show it.
save_layout_before_delete() {
  [ -d "$SESAME_DIR" ] || return 0
  mkdir -p "$PRIV" || return 0
  { echo "taken $(date +%Y-%m-%dT%H:%M:%S) by library-scan --delete-first, just before it deleted $SESAME_DIR"; layout_listing "$SESAME_DIR"; } > "$PRIV/layout-before-delete.txt"
}

cmd_library_scan() {
  local delete=0 ignore=0 newonly=0 out="" ctl="" rc=0 hits found=0 line e
  while [ $# -gt 0 ]; do
    case "$1" in
      --delete-first) delete=1; shift ;;
      --ignore-sesame-folder) ignore=1; shift ;;
      --new-only) newonly=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  need_state || return 4
  if [ ! -s "$PRIV/baseline.time" ] || [ ! -f "$PRIV/baseline-home.txt" ] || [ ! -f "$PRIV/baseline-real.txt" ]; then
    echo "not valid: no baseline of the Library paths for this starting state; run scripts/kit-privacy.sh baseline right after scripts/kit-reset.sh"
    return 4
  fi
  APP_ID="$(app_identifier)" || { echo "not valid: no Info.plist to read the app's identifier from (neither $KIT_APP nor dist/Sesame.app)"; return 4; }
  echo "app identifier: $APP_ID; baseline taken $(cat "$PRIV/baseline.time")"

  if [ $delete = 1 ]; then
    kit_need_ps || return 4
    if [ -n "$(kit_tree)" ]; then
      echo "not valid: the app is still running; scripts/kit-launch.sh quit first"
      return 4
    fi
    save_layout_before_delete
    for e in "$SESAME_DIR" "$KIT_APP"; do
      case "$e" in
        "$KIT_ROOT"/home/Library/Application\ Support/Sesame|"$KIT_ROOT"/apps/Sesame.app) ;;
        *) echo "refusing to delete $e"; return 1 ;;
      esac
      if [ -e "$e" ]; then rm -rf "$e" && echo "deleted $e"; else echo "nothing to delete: $e"; fi
    done
  fi

  mkdir -p "$PRIV" || return 1
  # Controls first: a scan that cannot see must not pass.
  ctl="$(
    bad=0
    control_root home "$HOME_LIB" "$PRIV/baseline-home.txt" || bad=1
    mkdir -p "$PRIV/ctl-real" && : > "$PRIV/ctl-real/empty-baseline.txt"
    control_root "real-shaped" "$PRIV/ctl-real/Library" "$PRIV/ctl-real/empty-baseline.txt" || bad=1
    rm -rf "$PRIV/ctl-real"
    control_tmp || bad=1
    echo "plants in the real ~/Library: none (the real-Library control runs on a Library-shaped folder under $KIT_ROOT, so the kit never writes to your own Library)"
    exit $bad
  )"; rc=$?
  printf '%s\n' "$ctl"
  save_named scan-controls "$ctl"
  if [ $rc != 0 ]; then
    echo "not valid: a scan control failed, so a clean scan would prove nothing"
    return 4
  fi

  # The scan.
  hits="$PRIV/hits.$$"
  : > "$hits.home"; : > "$hits.real"
  scan_root "$HOME_LIB" "$PRIV/baseline-home.txt" "$hits.home"; echo "scanned $HOME_LIB: $SCAN_NEW new paths since the baseline"
  scan_root "$REAL_LIB" "$PRIV/baseline-real.txt" "$hits.real"; echo "scanned $REAL_LIB: $SCAN_NEW new paths since the baseline"
  # S8(g) counts only what appeared after the baseline, in the real Library too (verify.md, Starting state). A path
  # named sesame that was already there at the baseline is a leftover of an earlier run: the baseline note names it
  # and it is not a finding. $newonly is kept for S8.13's call and has the same effect as the default.
  echo "scanned $REAL_LIB: only paths that appeared after the baseline count"
  if [ $ignore = 1 ]; then
    awk '{ rel = $0; sub(/^[a-z]+ /, "", rel) } rel == "Application Support/Sesame" || index(rel, "Application Support/Sesame/") == 1 { next } { print }' "$hits.home" > "$hits.home.2" && mv "$hits.home.2" "$hits.home"
    echo "left out: the Sesame folder itself (Application Support/Sesame) in the throwaway home"
  fi
  # Claude Code keeps its own cache under Caches/claude-cli-nodejs/, named after the project folder (this project
  # is called sesame), so a new path there is not Sesame's.
  awk '{ rel = $0; sub(/^[a-z]+ /, "", rel) } index(rel, "Caches/claude-cli-nodejs/") == 1 { next } { print }' "$hits.real" > "$hits.real.2" && mv "$hits.real.2" "$hits.real"
  echo "left out: Caches/claude-cli-nodejs/ in the real Library (Claude Code's own cache, named after the project folder)"
  named_caches_check home "$HOME_LIB" "$hits.home"
  while IFS= read -r line; do echo "FOUND ${line%% *} in $HOME_LIB: ${line#* }"; found=$((found + 1)); done < "$hits.home"
  while IFS= read -r line; do echo "FOUND ${line%% *} in $REAL_LIB: ${line#* }"; found=$((found + 1)); done < "$hits.real"
  rm -f "$hits.home" "$hits.real"
  while IFS= read -r line; do
    [ -n "$line" ] && { echo "FOUND tmp folder: $line"; found=$((found + 1)); }
  done < <(tmp_sesame_dirs)
  if [ $found = 0 ]; then
    echo "LIBRARY-SCAN CLEAN: no path named sesame, no plist or text file holding $APP_ID, no $KIT_TMP/Sesame-* folder"
    out="clean"
  else
    echo "LIBRARY-SCAN FAILED: $found finding(s); nothing is removed from the real Library, report the paths to the person"
    out="found"
  fi
  save_named library-scan "scan of $(date +%Y-%m-%dT%H:%M:%S): $out ($found findings), controls in scan-controls.txt"
  [ "$out" = clean ]
}

# ---- layout ----------------------------------------------------------------------------------

# layout_listing <folder> : the listing lines, then the verdict line; status 1 when an entry is UNEXPECTED.
layout_listing() {
  local dir="$1" rel type mode size inode name msize msha want_size want_sha unexpected=0 n=0 top base
  echo "SESAME FOLDER $dir mode=0$(stat -f %Lp "$dir")"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    n=$((n + 1))
    if [ -L "$dir/$rel" ]; then type=l; elif [ -d "$dir/$rel" ]; then type=d; else type=f; fi
    mode="$(stat -f %Lp "$dir/$rel")"; size="$(stat -f %z "$dir/$rel")"; inode="$(stat -f %i "$dir/$rel")"
    echo "ENTRY $rel $type mode=0$mode size=$size inode=$inode"
    top="${rel%%/*}"; base="${rel##*/}"
    case "$rel" in
      models|logs|settings.json|index.sqlite|index.sqlite-wal|index.sqlite-shm) ;;
      models/*)
        if [ "$top" = models ] && [ "$rel" = "models/$base" ] && awk -F'\t' -v b="$base" '$1 == b { f = 1 } END { exit !f }' "$KIT_LIB/models.tsv"; then :
        else echo "LAYOUT UNEXPECTED $rel: not one of the two model files (a .partial file means the download did not finish)"; unexpected=$((unexpected + 1)); fi ;;
      logs/app.log|logs/index.log|logs/encode.log) ;;
      logs/*) echo "LAYOUT UNEXPECTED $rel: not one of app.log, index.log, encode.log"; unexpected=$((unexpected + 1)) ;;
      *) echo "LAYOUT UNEXPECTED $rel: the Sesame folder holds only models/, index.sqlite (-wal, -shm), settings.json and logs/"; unexpected=$((unexpected + 1)) ;;
    esac
  done < <(cd "$dir" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)
  while IFS=$'\t' read -r name want_size want_sha; do
    [ -f "$dir/models/$name" ] || continue
    msize="$(stat -f %z "$dir/models/$name")"
    msha="$(shasum -a 256 "$dir/models/$name" | awk '{ print $1 }')"
    if [ "$msize" = "$want_size" ] && [ "$msha" = "$want_sha" ]; then
      echo "MODEL $name $msize bytes sha256 $msha matches design section 7"
    else
      echo "MODEL $name $msize bytes sha256 $msha DIFFERS from design section 7 ($want_size bytes, $want_sha)"
      unexpected=$((unexpected + 1))
    fi
  done < "$KIT_LIB/models.tsv"
  if [ $unexpected = 0 ]; then
    echo "LAYOUT OK: $n entries, all expected"
    return 0
  fi
  echo "LAYOUT UNEXPECTED: $unexpected finding(s)"
  return 1
}

cmd_layout() {
  local dir="$SESAME_DIR" out rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || { usage; return 2; }; dir="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [ -d "$dir" ]; then
    out="$(layout_listing "$dir")"; rc=$?
    printf '%s\n' "$out"
    save_named layout "$out"
    return $rc
  fi
  echo "SESAME FOLDER $dir missing"
  if [ "$dir" = "$SESAME_DIR" ] && [ -s "$PRIV/layout-before-delete.txt" ]; then
    echo "LAST LISTING (the folder is gone; this is the listing library-scan --delete-first took from disk before it deleted it):"
    cat "$PRIV/layout-before-delete.txt"
    return 0
  fi
  echo "LAYOUT FAILED: there is no Sesame folder to list"
  return 1
}

# ---- login-item ------------------------------------------------------------------------------

# btm_state <dumpbtm text file> <identifier> [<app path>...] : what the text says about that identifier, one word:
# enabled, disabled, none (the text lists records and none is that identifier) or unparsed (no record with a
# Disposition line, or a matching record whose Disposition names neither state). A record starts at `#<n>:`; its
# own `Identifier:` line may carry a number and a dot before the identifier (`2.app.sesame.Sesame`).
# With app paths (the kit's copy of the app, both spellings of its folder) a record of the identifier counts only when
# its `Executable Path:` or `URL:` lies inside one of them: a record of the same identifier from another build (an
# earlier kit run, dist/Sesame.app) is not the kit's and reads none. A record of the identifier that names no path at
# all cannot be told from a stale one and reads unparsed. Without app paths the identifier alone decides (the control,
# which asks for an identifier that cannot exist). GUESS (K24, settled at the accept stage): the path is on a
# `URL:` and/or `Executable Path:` line of the record, spelled /private/var or /var, as a path or a file:// URL.
btm_state() {
  local file="$1" id="$2" apps="" p
  shift 2
  for p in "$@"; do apps="$apps${apps:+|}$p"; done
  awk -v id="$id" -v apps="$apps" '
    function norm(s) {
      sub(/^file:\/\//, "", s); sub(/[ \t]+$/, "", s); sub(/^\/private\//, "/", s); sub(/\/+$/, "", s)
      return s
    }
    function inside(p,   i) {
      p = norm(p)
      if (p == "") return 0
      for (i = 1; i <= nA; i++) if (p == app[i] || index(p, app[i] "/") == 1) return 1
      return 0
    }
    function flush(   v) {
      if (ident != "") {
        v = ident; sub(/^[0-9]+\./, "", v)
        if (ident == id || v == id) {
          if (nA > 0 && exe == "" && url == "") nopath = 1
          else if (nA > 0 && !inside(exe) && !inside(url)) stale = 1
          else if (disp ~ /enabled/) en = 1
          else if (disp ~ /disabled/) dis = 1
          else bad = 1
        }
      }
      ident = ""; disp = ""; exe = ""; url = ""
    }
    BEGIN { nA = (apps == "") ? 0 : split(apps, app, "|"); for (i = 1; i <= nA; i++) app[i] = norm(app[i]) }
    /^[ \t]*#[0-9]+:/ { flush(); next }
    /^[ \t]*Identifier:/ { ident = $0; sub(/^[ \t]*Identifier:[ \t]*/, "", ident); sub(/[ \t]+$/, "", ident); next }
    /^[ \t]*Disposition:/ { disp = $0; sawdisp = 1; next }
    /^[ \t]*Executable Path:/ { exe = $0; sub(/^[ \t]*Executable Path:[ \t]*/, "", exe); next }
    /^[ \t]*URL:/ { url = $0; sub(/^[ \t]*URL:[ \t]*/, "", url); next }
    END {
      flush()
      if (!sawdisp) print "unparsed"
      else if (en) print "enabled"
      else if (dis) print "disabled"
      else if (bad || nopath) print "unparsed"
      else print "none"
    }' "$file"
}

cmd_login_item() {
  local id td state ctl cid
  [ $# -eq 0 ] || { usage; return 2; }
  id="$(app_identifier)" || { echo "not valid: no Info.plist to read the app's identifier from (neither $KIT_APP nor dist/Sesame.app)"; return 4; }
  if ! sudo -n true 2>/dev/null; then
    echo "NEEDS A PERSON: administrator rights: run scripts/kit-perms.sh ask-admin and type your password once, then run this again"
    return 3
  fi
  td="$(mktd)" || return 1
  echo "app identifier: $id"
  if ! sudo -n sfltool dumpbtm > "$td/btm.txt" 2> "$td/err" || [ ! -s "$td/btm.txt" ]; then
    echo "sfltool dumpbtm gave no text: $(tail -1 "$td/err")"
    rm -rf "$td"
    echo "unreadable"
    login_status_line
    return 0
  fi
  # Only the record of the kit's own copy of the app counts: a stale record of the same identifier from another build is ignored.
  state="$(btm_state "$td/btm.txt" "$id" "$KIT_APP" "$KIT_APP_REAL")"
  if [ "$state" = none ] && [ "$(btm_state "$td/btm.txt" "$id")" != none ]; then
    echo "note: macOS holds a login item record for $id that is not the kit's copy of the app ($KIT_APP): a stale record from another build, ignored"
  fi
  # The control: the same text read for an identifier that cannot exist must say none, or the parser cannot say no.
  cid="app.sesame.Absent-$$-$RANDOM"
  ctl="$(btm_state "$td/btm.txt" "$cid")"
  if [ "$ctl" = unparsed ]; then
    state=unparsed
  elif [ "$ctl" != none ]; then
    echo "CONTROL login-item FAILED: the absent identifier $cid read as $ctl"
    echo "not valid: the login-item control failed, so an answer would prove nothing"
    rm -rf "$td"
    return 4
  else
    echo "CONTROL login-item OK: the absent identifier $cid reads absent"
  fi
  rm -rf "$td"
  case "$state" in
    enabled) echo "present and enabled" ;;
    disabled) echo "present and disabled" ;;
    none) echo "absent" ;;
    *) echo "unreadable" ;;
  esac
  login_status_line
  return 0
}

# The app's own record of what SMAppService said: the last `login status=` line of logs/app.log (U6).
login_status_line() {
  local logf="$SESAME_DIR/logs/app.log" last
  last=""
  [ -f "$logf" ] && last="$(grep -a -F 'login status=' "$logf" | tail -1)"
  if [ -n "$last" ]; then echo "app.log: $last"; else echo "app.log: no login status= line in $logf"; fi
}

# ---- schema-scan -----------------------------------------------------------------------------

# schema_names <db> : every table and column name, one per line, each once; status 1 when sqlite3 cannot read the file.
schema_names() {
  local out
  out="$(sqlite3 -readonly "$1" "select name from sqlite_master where type in ('table','view') union select p.name from sqlite_master m, pragma_table_info(m.name) p where m.type in ('table','view')" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk 'NF && !seen[$0]++'
}

# schema_verdicts <db> : `forbidden: <name>` or `allowed: <name>` per name; status 1 when the file cannot be read.
schema_verdicts() {
  local names
  names="$(schema_names "$1")" || return 1
  printf '%s\n' "$names" | LC_ALL=C awk -f "$KIT_LIB/schemawords.awk"
}

cmd_schema_scan() {
  local db="" ctl ctlout want out n
  while [ $# -gt 0 ]; do
    case "$1" in
      --db) [ $# -ge 2 ] || { usage; return 2; }; db="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  [ -n "$db" ] || db="$SESAME_DIR/index.sqlite"
  mkdir -p "$KIT_ROOT/run" || return 1
  # The control first: the same parser on a throwaway file of five names must tell them apart, or it proves nothing.
  ctl="$KIT_ROOT/run/schema-control.sqlite"
  rm -f "$ctl"
  sqlite3 "$ctl" 'create table control_probe (search_count integer, last_opened integer, "lastOpened" integer, history integer, page_count integer)' >/dev/null 2>&1
  ctlout="$(schema_verdicts "$ctl")"
  rm -f "$ctl"
  for want in "forbidden: search_count" "forbidden: last_opened" "forbidden: lastOpened" "forbidden: history" "allowed: page_count"; do
    if ! printf '%s\n' "$ctlout" | grep -F -x -q -- "$want"; then
      echo "CONTROL schema-scan FAILED: the throwaway file did not give \`$want\`"
      echo "not valid: the schema-scan control failed, so a clean scan would prove nothing"
      return 4
    fi
  done
  printf '%s\n' "$ctlout" | while IFS= read -r want; do echo "CONTROL $want"; done
  echo "CONTROL schema-scan OK: search_count, last_opened, lastOpened and history forbidden, page_count allowed"
  [ -f "$db" ] || { echo "not valid: no database at $db"; return 4; }
  out="$(schema_verdicts "$db")" || { echo "not valid: sqlite3 could not read $db"; return 4; }
  [ -n "$out" ] || { echo "not valid: $db holds no table"; return 4; }
  printf '%s\n' "$out"
  save_named schema "$out"
  n="$(printf '%s\n' "$out" | grep -c '^forbidden: ')"
  if [ "$n" != 0 ]; then
    echo "SCHEMA-SCAN FAILED: $n forbidden name(s) in $db"
    return 1
  fi
  echo "SCHEMA-SCAN OK: no forbidden table or column name in $db"
  return 0
}

# ---- tcc -------------------------------------------------------------------------------------

# tcc_rows <db> <identifier> : the failing services that client has in that database, one per line (Full Disk Access,
# camera, microphone); status 1 when sqlite3 cannot read the file. Read-only and safe: the database is never written.
tcc_rows() {
  sqlite3 -readonly -safe "$1" "select distinct service from access where client = '$2' and service in ('kTCCServiceSystemPolicyAllFiles', 'kTCCServiceCamera', 'kTCCServiceMicrophone') order by service" 2>/dev/null
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

cmd_tcc() {
  local dbs=() id="" db ctl cid found other out rc rows unreadable=0 nread=0 line user_db readnames="" userread=0
  user_db="$REAL_HOME/Library/Application Support/com.apple.TCC/TCC.db"
  while [ $# -gt 0 ]; do
    case "$1" in
      --db) [ $# -ge 2 ] || { usage; return 2; }; dbs+=("$2"); shift 2 ;;
      --identifier) [ $# -ge 2 ] || { usage; return 2; }; id="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$id" in
    *[!A-Za-z0-9._-]*) echo "the identifier may hold only letters, digits, dots, dashes and underscores: $id"; return 2 ;;
  esac
  if [ -z "$id" ]; then
    id="$(app_identifier)" || { echo "not valid: no Info.plist to read the app's identifier from (neither $KIT_APP nor dist/Sesame.app)"; return 4; }
  fi
  if [ ${#dbs[@]} -eq 0 ]; then
    for db in "$user_db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
      [ "$(tcc_probe "$db")" = missing ] || dbs+=("$db")
    done
    [ ${#dbs[@]} -gt 0 ] || { echo "not valid: no permission database found in the user's or the system's Library"; return 4; }
  fi
  mkdir -p "$KIT_ROOT/run" || return 1
  # The control first: a camera row for a made-up identifier must be found, and another identifier must find nothing.
  cid="app.sesame.Control-$$-$RANDOM"
  ctl="$KIT_ROOT/run/tcc-control.db"
  rm -f "$ctl"
  sqlite3 "$ctl" "create table access (service text, client text, auth_value integer, last_modified integer); insert into access values ('kTCCServiceCamera', '$cid', 2, 0);" >/dev/null 2>&1
  found="$(tcc_rows "$ctl" "$cid")"
  other="$(tcc_rows "$ctl" "app.sesame.Absent-$$")"
  rm -f "$ctl"
  if [ "$found" != kTCCServiceCamera ] || [ -n "$other" ]; then
    echo "CONTROL tcc FAILED: the throwaway database did not give the camera service for $cid and nothing for another client"
    echo "not valid: the tcc control failed, so a clean answer would prove nothing"
    return 4
  fi
  echo "CONTROL tcc OK: a camera service for a made-up identifier is found, another client finds nothing"
  rows=""
  for db in "${dbs[@]}"; do
    out="$(tcc_rows "$db" "$id")"; rc=$?
    if [ $rc != 0 ]; then
      unreadable=1
      echo "could not read $db"
      continue
    fi
    nread=$((nread + 1))
    readnames="$readnames${readnames:+, }$db"
    [ "$db" = "$user_db" ] && userread=1
    if [ -n "$out" ]; then
      rows="$rows${rows:+
}$out"
    fi
  done
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows" | LC_ALL=C sort -u | while IFS= read -r line; do echo "TCC row: $line (client $id)"; done
    echo "TCC FAILED: the permission database holds a Full Disk Access, camera or microphone row for $id"
    return 1
  fi
  if [ $unreadable = 1 ]; then
    echo "NEEDS A PERSON: Full Disk Access for the terminal: System Settings, Privacy and Security, Full Disk Access, turn on ${TERM_PROGRAM:-the terminal app that runs the checks} (used only to read the permission database)"
    return 3
  fi
  echo "read $nread database(s): $readnames"
  if [ $userread = 0 ]; then
    echo "WARNING: no user-scope permission database was read, and camera and microphone rows are kept only there; they were not checked"
  fi
  echo "no Full Disk Access, camera or microphone row for $id in the database(s) read"
  return 0
}

# ---- query-scan ------------------------------------------------------------------------------

# The places of the scan inside the throwaway home: index 0 is the Sesame folder, the others are folders of its Library.
QS_LABELS=("Application Support/Sesame" "Preferences" "Caches" "HTTPStorages" "Saved Application State" "Logs")

qs_dir() { # qs_dir <index> : the folder of that place
  case "$1" in
    0) printf '%s' "$SESAME_DIR" ;;
    *) printf '%s' "$HOME_LIB/${QS_LABELS[$1]}" ;;
  esac
}

# qs_scan_path <path> <markers file> : `<marker><TAB><file>` for every marker found in every file under the path
# (a file or a folder; a path that does not exist holds nothing). Fixed strings, bytewise, binary safe.
qs_scan_path() {
  local place="$1" mf="$2" f m
  [ -e "$place" ] || return 0
  LC_ALL=C grep -r -a -F -l -f "$mf" -- "$place" 2>/dev/null | while IFS= read -r f; do
    while IFS= read -r m; do
      LC_ALL=C grep -a -F -q -e "$m" -- "$f" 2>/dev/null && printf '%s\t%s\n' "$m" "$f"
    done < "$mf"
  done
  return 0
}

qs_scan_tmp() { # qs_scan_tmp <markers file> : the scratch folders $TMPDIR/Sesame-*
  local g
  for g in "$KIT_TMP"/Sesame-*; do
    [ -e "$g" ] && qs_scan_path "$g" "$1"
  done
  return 0
}

qs_scan_place() { # qs_scan_place <0..5|tmp|mirror> <markers file>
  case "$1" in
    tmp) qs_scan_tmp "$2" ;;
    mirror) qs_scan_path "$KIT_ROOT/run/mirror-requests.log" "$2" ;;
    *) qs_scan_path "$(qs_dir "$1")" "$2" ;;
  esac
}

# qs_plant <folder> <marker> <created file> <planted file> : makes the folder (every folder that did not exist is
# written to the created file first, so a failed make is still cleaned up), puts a control file holding the marker
# between NUL bytes in it, writes the control file's path to the planted file and prints it. Status 1 when it cannot.
qs_plant() {
  local dir="$1" marker="$2" created="$3" planted="$4" up="$1" miss="" f
  while [ ! -e "$up" ] && [ ! -L "$up" ] && [ "$up" != "/" ]; do
    miss="$miss$up"$'\n'
    up="$(dirname "$up")"
  done
  printf '%s' "$miss" >> "$created"
  mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/zz-$marker"
  { printf '\0\1\377\0%s\0\2\n\0' "$marker" > "$f"; } 2>/dev/null || return 1
  printf '%s\n' "$f" >> "$planted"
  printf '%s\n' "$f"
}

qs_unplant() { # qs_unplant <planted file> <created file> : removes every control file, then the folders the controls made
  local f d
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f"
  done < "$1"
  LC_ALL=C sort -r "$2" | while IFS= read -r d; do
    [ -n "$d" ] && rmdir "$d" 2>/dev/null
  done
  return 0
}

# qs_log_control <td> <control marker> <absent marker> : the control of the unified-log scan; a logger line carrying the
# marker must be shown by `log show` and found by the same match, a marker never planted must not; status 1 when not.
qs_log_control() {
  local td="$1" cm="$2" am="$3" i
  if ! logger -t kit-privacy "$cm" 2>/dev/null; then
    echo "CONTROL unified log FAILED: logger could not write the control line"
    return 1
  fi
  for i in 1 2 3 4 5; do
    log show --style compact --last 2m --predicate "eventMessage CONTAINS \"$cm\"" > "$td/logtext" 2>/dev/null
    if [ -n "$(qs_scan_path "$td/logtext" "$td/cmf")" ]; then
      if [ -n "$(qs_scan_path "$td/logtext" "$td/amf")" ]; then
        echo "CONTROL unified log FAILED: a marker that was never planted was found in the log text"
        return 1
      fi
      echo "CONTROL unified log: the logger line carrying $cm was found by log show, an unplanted marker was not found; this proves log show and the match work, it does not prove that the predicate (process BEGINSWITH \"Sesame\") selects Sesame's processes"
      return 0
    fi
    sleep 1
  done
  echo "CONTROL unified log FAILED: log show did not show the logger line carrying $cm after 5 tries"
  return 1
}

# qs_controls <td> <control marker> <absent marker> <nolog> : one CONTROL line per place; status 1 when one failed.
qs_controls() {
  local td="$1" cm="$2" am="$3" nolog="$4" bad=0 i label dir f
  : > "$td/planted"; : > "$td/created"
  for i in 0 1 2 3 4 5 tmp; do
    if [ "$i" = tmp ]; then
      label='$TMPDIR/Sesame-control-<n>'
      dir="$KIT_TMP/Sesame-control-$$-$RANDOM"
    else
      label="${QS_LABELS[$i]}"
      dir="$(qs_dir "$i")"
    fi
    f="$(qs_plant "$dir" "$cm" "$td/created" "$td/planted")" || { echo "CONTROL $label FAILED: could not put a control file in $dir"; bad=1; continue; }
    if ! qs_scan_place "$i" "$td/cmf" | grep -F -x -q -- "$cm"$'\t'"$f"; then
      echo "CONTROL $label FAILED: the planted marker was not found in $f"; bad=1; continue
    fi
    if [ -n "$(qs_scan_place "$i" "$td/amf")" ]; then
      echo "CONTROL $label FAILED: a marker that was never planted was found"; bad=1; continue
    fi
    echo "CONTROL $label: the planted marker $cm was found, an unplanted marker was not found"
  done
  if [ "$nolog" = 0 ]; then
    qs_log_control "$td" "$cm" "$am" || bad=1
  else
    echo "NOTE the unified log is not read (--no-log)"
  fi
  qs_unplant "$td/planted" "$td/created"
  return $bad
}

cmd_query_scan() {
  local mf="" nolog=0 td r cm am ctl rc i m f found=0 places=0 base text
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-log) nolog=1; shift ;;
      -*) usage; return 2 ;;
      *) [ -z "$mf" ] || { usage; return 2; }; mf="$1"; shift ;;
    esac
  done
  [ -n "$mf" ] || { usage; return 2; }
  [ -f "$mf" ] || { echo "not valid: no markers file at $mf"; return 4; }
  td="$(mktd)" || return 1
  tr -d '\r' < "$mf" | awk 'NF' > "$td/markers"
  if [ ! -s "$td/markers" ]; then
    echo "not valid: $mf holds no marker, so a clean scan would prove nothing"
    rm -rf "$td"
    return 4
  fi
  r="$$-$RANDOM"
  cm="qm-control-$r"
  am="qm-absent-$r"
  printf '%s\n' "$cm" > "$td/cmf"
  printf '%s\n' "$am" > "$td/amf"
  # Controls first: a scan that cannot see must not pass.
  ctl="$(qs_controls "$td" "$cm" "$am" "$nolog")"; rc=$?
  printf '%s\n' "$ctl"
  save_named scan-controls "$ctl"
  if [ $rc != 0 ]; then
    echo "not valid: a scan control failed, so a clean scan would prove nothing"
    rm -rf "$td"
    return 4
  fi
  # The scan.
  for i in 0 1 2 3 4 5 tmp mirror; do
    places=$((places + 1))
    while IFS=$'\t' read -r m f; do
      [ -n "$m" ] || continue
      echo "FOUND $m in $f"
      found=$((found + 1))
    done < <(qs_scan_place "$i" "$td/markers")
  done
  if [ $nolog = 0 ]; then
    places=$((places + 1))
    base="$(cat "$PRIV/baseline.time" 2>/dev/null)"
    if [ -n "$base" ]; then
      text="$(log show --style compact --start "$(printf '%s' "$base" | tr 'T' ' ')" --predicate 'process BEGINSWITH "Sesame"' 2>/dev/null)"
    else
      text="$(log show --style compact --last 1d --predicate 'process BEGINSWITH "Sesame"' 2>/dev/null)"
    fi
    printf '%s\n' "$text" > "$td/logtext"
    while IFS=$'\t' read -r m f; do
      [ -n "$m" ] || continue
      echo "FOUND $m in unified log"
      found=$((found + 1))
    done < <(qs_scan_path "$td/logtext" "$td/markers")
    echo "NOTE the unified log lines of the Sesame processes were read; private values may show as <private>, the scan still runs"
  fi
  rm -rf "$td"
  if [ $found = 0 ]; then
    echo "QUERY-SCAN OK: no marker found in $places places"
    return 0
  fi
  echo "QUERY-SCAN FAILED: $found finding(s)"
  return 1
}

# ---- prompts ---------------------------------------------------------------------------------

PROMPTS_PIDS="$KIT_ROOT/run/pids"
PROMPTS_DIR="$KIT_ROOT/run/prompts"

# The AppleScript that lists the windows of the system dialog processes, one line per window:
# <process> | <title> | <the window's static texts>. [guess: which process shows a permission dialog; settled at the
# accept stage, block C, where the watcher first runs for real]
prompts_script() {
  cat <<'EOF'
on oneline(x)
  set AppleScript's text item delimiters to {linefeed, return}
  set parts to text items of (x as text)
  set AppleScript's text item delimiters to " "
  set r to parts as text
  set AppleScript's text item delimiters to ""
  return r
end oneline

set procs to {"UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn"}
set out to ""
tell application "System Events"
  repeat with pn in procs
    set pname to contents of pn
    if exists (process pname) then
      repeat with w in (windows of process pname)
        set t to ""
        try
          set t to name of w
        end try
        set s to ""
        try
          repeat with e in (entire contents of w)
            try
              if class of e is static text then set s to s & " " & (value of e as text)
            end try
          end repeat
        end try
        set out to out & pname & " | " & my oneline(t) & " | " & my oneline(s) & linefeed
      end repeat
    end if
  end repeat
end tell
return out
EOF
}

# prompts_windows : the window lines of the system dialog processes now; status 1 when osascript cannot read them.
prompts_windows() {
  local out rc errf
  errf="$(mktemp "$KIT_TMP/prompts-err.XXXXXX")" || return 1
  out="$(kit_timeout 30 osascript -e "$(prompts_script)" 2>"$errf")"; rc=$?
  PROMPTS_ERR="$(cat "$errf" 2>/dev/null)"
  rm -f "$errf"
  [ -z "$out" ] || printf '%s\n' "$out" | tr -d '\r'
  return $rc
}

# prompts_poll <name> : the background watcher. Once a second it keeps each window line that names Sesame (once) in
# run/prompts/<name>.windows, and it ends when run/pids/prompts-<name>.pid is gone.
prompts_poll() {
  local pidf="$PROMPTS_PIDS/prompts-$1.pid" wf="$PROMPTS_DIR/$1.windows" line
  while [ -f "$pidf" ]; do
    prompts_windows | grep -a -i sesame | while IFS= read -r line; do
      LC_ALL=C grep -a -F -x -q -- "$line" "$wf" 2>/dev/null || printf '%s\n' "$line" >> "$wf"
    done
    sleep 1
  done
}

prompts_start() {
  local name="$1" pidf="$PROMPTS_PIDS/prompts-$1.pid" old tries
  mkdir -p "$PROMPTS_PIDS" "$PROMPTS_DIR" || return 1
  old="$(cat "$pidf" 2>/dev/null)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "not valid: a prompts watcher $name is already running (pid $old); stop it first"
    return 4
  fi
  tries=0
  until prompts_windows >/dev/null; do
    tries=$((tries + 1))
    case "$PROMPTS_ERR" in
      *-1743*|*-25211*|*-25204*)
        echo "NEEDS A PERSON: Accessibility and Automation for System Events for the terminal: the prompts watcher could not read the dialog windows (System Settings, Privacy and Security): $(printf '%s' "$PROMPTS_ERR" | tail -1)"
        return 3 ;;
    esac
    if [ $tries -ge 3 ]; then
      echo "RERUN the prompts watcher could not read the dialog windows after $tries tries: $(printf '%s' "${PROMPTS_ERR:-no error text, the probe timed out}" | tail -1)"
      return 4
    fi
    sleep 1
  done
  : > "$PROMPTS_DIR/$name.windows"
  rm -f "$PROMPTS_DIR/$name.result"
  # The pid file exists before the loop starts (the loop ends when it is gone) and the poller holds none of the
  # caller's pipes, so the caller can finish while it runs.
  echo starting > "$pidf"
  ( prompts_poll "$name" ) >/dev/null 2>&1 </dev/null &
  echo "$!" > "$pidf"
  disown 2>/dev/null
  echo "PROMPTS watcher $name started (pid $!), reading the dialog windows once a second"
  return 0
}

# prompts_parse <file> : the lines of a window dump that name Sesame (the text is kept), a verdict, and the last line
# `seen=<n> exit=<0|1>`. A dialog that names Sesame and Full Disk Access, camera or microphone is exit 1.
prompts_parse() {
  local f="$1" n=0 bad=0 low line
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      low="$(printf '%s' "$line" | tr 'A-Z' 'a-z')"
      case "$low" in
        *sesame*)
          n=$((n + 1))
          echo "SEEN $line"
          case "$low" in
            *"full disk access"*|*camera*|*microphone*) bad=$((bad + 1)) ;;
          esac ;;
      esac
    done < "$f"
  fi
  if [ $n = 0 ]; then
    echo "no dialog named Sesame seen"
  elif [ $bad != 0 ]; then
    echo "PROMPTS FAILED: $bad dialog(s) naming Sesame also name Full Disk Access, camera or microphone"
  else
    echo "$n dialog(s) named Sesame, none about Full Disk Access, camera or microphone (their wording goes to the person, S8.N1)"
  fi
  if [ $bad != 0 ]; then
    printf 'seen=%s exit=1\n' "$n"
    return 1
  fi
  printf 'seen=%s exit=0\n' "$n"
  return 0
}

prompts_stop() {
  local name="$1" pidf="$PROMPTS_PIDS/prompts-$1.pid" pid i out rc kids
  if [ ! -f "$pidf" ]; then
    echo "not valid: no prompts watcher $name was running (prompts start $name first)"
    return 4
  fi
  pid="$(cat "$pidf" 2>/dev/null)"
  rm -f "$pidf"
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # The poller sees the pid file gone and leaves within one poll; one that does not is ended, but only a process
    # that is ours (its command line holds this script's name).
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" 2>/dev/null | grep -q 'kit-privacy.sh'; then
      kids="$(kit_descendants "$pid")"
      kill -TERM $kids "$pid" 2>/dev/null
    fi
  fi
  mkdir -p "$PROMPTS_DIR" || return 1
  out="$(prompts_parse "$PROMPTS_DIR/$name.windows")"; rc=$?
  printf '%s\n' "$out"
  save_named prompts "$out"
  printf '%s\n' "$out" | tail -1 > "$PROMPTS_DIR/$name.result"
  return $rc
}

prompts_result() {
  local name="$1" rf="$PROMPTS_DIR/$1.result" line
  [ -f "$rf" ] || { echo "not valid: no prompts result $name (prompts stop $name saves it)"; return 4; }
  line="$(head -1 "$rf")"
  if ! printf '%s\n' "$line" | grep -E -q '^seen=[0-9]+ exit=[01]$'; then
    echo "not valid: the saved prompts result $name is not a result line: $line"
    return 4
  fi
  echo "$line"
  if [ "${line##*exit=}" = 1 ]; then
    echo "PROMPTS FAILED: a dialog naming Sesame also named Full Disk Access, camera or microphone (see prompts.txt)"
    return 1
  fi
  echo "no Full Disk Access, camera or microphone dialog named Sesame was seen"
  return 0
}

cmd_prompts() {
  local sub="${1:-}" name
  [ $# -gt 0 ] && shift
  case "$sub" in
    start|stop|result)
      [ $# -eq 1 ] || { usage; return 2; }
      name="$1"
      case "$name" in
        ''|.*|*[!A-Za-z0-9._-]*) usage; return 2 ;;
      esac
      case "$sub" in
        start) prompts_start "$name" ;;
        stop) prompts_stop "$name" ;;
        result) prompts_result "$name" ;;
      esac ;;
    parse)
      { [ $# -eq 2 ] && [ "$1" = --sample ]; } || { usage; return 2; }
      [ -f "$2" ] || { echo "not valid: no such sample file: $2"; return 4; }
      prompts_parse "$2" ;;
    *) usage; return 2 ;;
  esac
}

# ---- ping ------------------------------------------------------------------------------------

cmd_ping() {
  local td fail=0 need=0 t out rc db r present=0 unreadable=0 notvalid=0 state
  [ $# -eq 0 ] || { usage; return 2; }
  for t in plutil codesign sqlite3 shasum find comm awk; do
    if command -v "$t" >/dev/null 2>&1; then echo "OK $t answers"; else echo "FAILED privacy: $t is missing"; fail=1; fi
  done
  mkdir -p "$KIT_ROOT/run" || return 1
  td="$(mktd)" || return 1
  APP_ID="app.sesame.Ping"

  # The plist and entitlement readers go red on a planted fault and stay green on a clean file.
  printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>CFBundleName</key><string>x</string></dict></plist>\n' > "$td/clean.plist"
  printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>CFBundleName</key><string>x</string><key>NSMicrophoneUsageDescription</key><string>y</string></dict></plist>\n' > "$td/bad.plist"
  printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/></dict></plist>\n' > "$td/clean.ent"
  printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/><key>com.apple.security.device.camera</key><true/></dict></plist>\n' > "$td/bad.ent"
  if [ -z "$(forbidden_plist_keys "$td/clean.plist")" ] && [ "$(forbidden_plist_keys "$td/bad.plist")" = NSMicrophoneUsageDescription ]; then
    echo "OK plist reader: a planted NSMicrophoneUsageDescription is found, a clean plist is not flagged"
  else echo "FAILED privacy: the plist reader did not go red on a planted microphone string"; fail=1; fi
  if [ -z "$(forbidden_entitlements "$td/clean.ent")" ] && [ "$(forbidden_entitlements "$td/bad.ent")" = com.apple.security.device.camera ]; then
    echo "OK entitlement reader: a planted camera entitlement is found, apple-events alone is not flagged"
  else echo "FAILED privacy: the entitlement reader did not go red on a planted camera entitlement"; fail=1; fi

  # The Library scan finds a planted name and content in every place of a Library-shaped throwaway folder.
  mkdir -p "$PRIV/ping" && : > "$PRIV/ping/empty-baseline.txt"
  if out="$(control_root ping "$PRIV/ping/Library" "$PRIV/ping/empty-baseline.txt")"; then
    echo "OK library scan: $(printf '%s\n' "$out" | tail -1)"
  else
    printf '%s\n' "$out"; echo "FAILED privacy: the library scan control failed"; fail=1
  fi
  rm -rf "$PRIV/ping"
  rm -rf "$td"

  # The permission database opens read-only, or the terminal needs Full Disk Access.
  for db in "$REAL_HOME/Library/Application Support/com.apple.TCC/TCC.db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
    state="$(tcc_probe "$db")"
    [ "$state" = missing ] && continue
    present=1
    if [ "$state" = open ] && r="$(sqlite3 -readonly -safe "$db" 'select count(*) from access' 2>&1)"; then
      echo "OK the permission database opens read-only ($r rows, $db)"
    else
      unreadable=1
      echo "could not open $db"
    fi
  done
  if [ $present = 0 ]; then
    echo "not valid: no permission database found in the user's or the system's Library"
    notvalid=1
  elif [ $unreadable = 1 ]; then
    echo "NEEDS A PERSON: Full Disk Access for the terminal: System Settings, Privacy and Security, Full Disk Access, turn on ${TERM_PROGRAM:-the terminal app that runs the checks} (used only to read the permission database)"
    need=1
  fi

  # The login-item read needs administrator rights, first needed in slice 2.
  if [ "$KIT_SLICE" -lt 2 ]; then
    # Printed only when nothing else is missing, so the Doctor (which treats this wording as deferred) never
    # swallows a missing Full Disk Access.
    if [ $need = 0 ]; then
      echo "NEEDS A PERSON (administrator rights, first needed in slice 2): sfltool dumpbtm"
      need=1
    fi
  elif sudo -n true 2>/dev/null; then
    if sudo -n sfltool dumpbtm 2>&1 | head -3 | grep -q .; then echo "OK sfltool dumpbtm prints text"; else echo "FAILED privacy: sfltool dumpbtm printed nothing"; fail=1; fi
  else
    echo "NEEDS A PERSON: administrator rights: run scripts/kit-perms.sh ask-admin and type your password once"
    need=1
  fi

  if [ $fail != 0 ]; then echo "PRIVACY PING FAILED"; return 1; fi
  if [ $notvalid != 0 ]; then return 4; fi
  if [ $need != 0 ]; then return 3; fi
  echo "PRIVACY PING OK"
  return 0
}

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    ping) cmd_ping "$@" ;;
    baseline) cmd_baseline "$@" ;;
    plist) cmd_plist "$@" ;;
    entitlements) cmd_entitlements "$@" ;;
    static-allowlist) cmd_static_allowlist "$@" ;;
    library-scan) cmd_library_scan "$@" ;;
    layout) cmd_layout "$@" ;;
    login-item) cmd_login_item "$@" ;;
    schema-scan) cmd_schema_scan "$@" ;;
    tcc) cmd_tcc "$@" ;;
    query-scan) cmd_query_scan "$@" ;;
    prompts) cmd_prompts "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-privacy "$@")" main "$@"
exit $?

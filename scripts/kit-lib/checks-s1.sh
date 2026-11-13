#!/bin/bash
# The slice 1 checks of S1 that drive the open panel (feature map S1: S1.1 to S1.5 and S1.7 to S1.15). Sourced by
# kit-run.sh after common.sh and recipes.sh, never run. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...`
# line (a failure says why, on one line) and uses the exit codes of every kit script: 0 for a pass or a
# needs-a-person, 1 for a fail, 4 for `RERUN <id> not valid: <reason>`. With KIT_PLANT=1 (kit-run.sh --plant <id>)
# each check posts a chord the app does not own (Shift+Command+K) to the kit window instead of the shortcut under
# test, so no panel opens and the check must print `CHECK <id> FAIL planted: <what>`.
#
# Kit safety (verify.md, Kit safety): every shortcut post sits between `kitwindow open` and `kitwindow close`
# made by the check itself, on every path (s1_run); typing and keys go to Sesame only, once `kit-ax.sh frontmost`
# reads Sesame; Enter and Command+Enter hand the front to the image app or Finder, so a check that needs the panel
# again reopens it with the shortcut inside the kit window, never with a key to that other app. Nothing here
# closes a window of another app, and nothing posts a key to one.
#
# The checks from S1.5 on need photos indexed: they run the recipe `photos` once per starting state (the result is
# kept in $KIT_ROOT/run/s1-photos), so on the t10 scaffold, which has no setup window, each prints a `FAIL` that
# names the missing part. S1.1 to S1.4 need no index and run on any panel.
# What the kit cannot drive, said in the PASS lines: Finder, Preview and TextEdit as the app in front when the
# shortcut is pressed (the shortcut is posted only while Sesame or a kit window is frontmost), and Preview in full
# screen (kit-ax.sh drives full screen only for Sesame and the kit window); the kit window stands in for both.

. "$KIT_LIB/panel.sh"

S1_SEARCH="$KIT_SCRIPTS/kit-search.sh"
S1_RB="$KIT_SCRIPTS/kit-readback.sh"
S1_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S1_LD="$KIT_SCRIPTS/kit-launch.sh"
S1_QUERY="a dog on the beach"
S1_MARK="$KIT_ROOT/run/s1-photos"
S1_WHAT=""
S1_RC=0
S1_FS=0
S1_OUT=""

# ---- plumbing ------------------------------------------------------------------------------------

s1_kq() { KIT_NO_EVIDENCE=1 "$@"; }

# s1_rbp <app> <kit-readback.sh args...> : a readback that asks an app through an Apple Event (frontmost, Finder's
# selection), under the hard limit of every probe (kit_timeout, 10 s). An app that does not answer prints
# `NEEDS A PERSON: <app> did not answer Apple Events within 10 s, restart it` and the status is 3: never a hang.
s1_rbp() {
  local app="$1" out rc
  shift
  out="$(KIT_NO_EVIDENCE=1 kit_timeout "$KIT_PROBE_TIMEOUT" "$S1_RB" "$@" 2>&1)"; rc=$?
  if [ $rc = 124 ]; then
    echo "NEEDS A PERSON: $app did not answer Apple Events within $KIT_PROBE_TIMEOUT s, restart it"
    return 3
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return $rc
}

# s1_person_line <id> <output of s1_rbp or pn_probe> : the CHECK line for a probe that needs a person.
s1_person_line() { echo "CHECK $1 NEEDS-A-PERSON $(printf '%s\n' "$2" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; }

s1_cleanup() {
  pn_close_panel >/dev/null 2>&1
  if [ "$S1_FS" = 1 ]; then pn_ax fullscreen kitwindow off >/dev/null 2>&1; S1_FS=0; fi
  pn_kit_close
}
# A signal closes the kit window before the run ends (the run still ends).
trap 's1_cleanup; exit 130' INT TERM HUP

# s1_run <function> : the check body, then the panel, the full screen and the kit window closed on every path.
s1_run() {
  local rc
  "$@"; rc=$?
  s1_cleanup
  return $rc
}

s1_fail() { # <id> <reason>
  if [ -n "$KIT_PLANT" ]; then echo "CHECK $1 FAIL planted: $S1_WHAT: $2"; else echo "CHECK $1 FAIL $2"; fi
  return 1
}

# s1_last <text> : the last non-empty line.
s1_last() { printf '%s\n' "$1" | awk 'NF { l = $0 } END { print l }'; }

# s1_need_photos <id> : status 0 when the recipe `photos` is ready; else it prints the CHECK line, sets S1_RC and returns 1.
s1_need_photos() {
  local id="$1" out rc msg
  if [ -f "$S1_MARK" ]; then
    rc="$(sed -n 1p "$S1_MARK")"
    msg="$(sed -n 2p "$S1_MARK")"
    if [ "$rc" = 0 ]; then
      kit_need_ps && [ -n "$(kit_pid_of app)" ] && return 0
    fi
  else
    out="$(recipe_photos 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/recipe photos: /'
    msg="$(s1_last "$out")"
    mkdir -p "$KIT_ROOT/run"
    printf '%s\n%s\n' "$rc" "$msg" > "$S1_MARK"
    [ "$rc" = 0 ] && return 0
  fi
  case "$rc" in
    0) echo "CHECK $id FAIL recipe photos left no Sesame running"; S1_RC=1 ;;
    3) echo "CHECK $id NEEDS-A-PERSON $msg"; S1_RC=0 ;;
    4) echo "RERUN $id not valid: recipe photos: $msg"; S1_RC=4 ;;
    *) echo "CHECK $id FAIL recipe photos cannot finish: $msg"; S1_RC=1 ;;
  esac
  return 1
}

# s1_begin <id> <needs photos 0|1> : sets the plant (the wrong chord) or, for the checks that need an index, the
# recipe. Returns 1 with S1_RC set when the check is already answered.
s1_begin() {
  S1_WHAT=""
  S1_RC=0
  if [ -n "$KIT_PLANT" ]; then
    KIT_PANEL_CHORD="shift+cmd+k"; export KIT_PANEL_CHORD
    S1_WHAT="Shift+Command+K posted to the kit window instead of the shortcut"
    return 0
  fi
  unset KIT_PANEL_CHORD
  [ "$2" = 1 ] || return 0
  s1_need_photos "$1"
}

# s1_open <id> : opens the panel; status 0 on success. Else prints the CHECK line, sets S1_RC and returns 1.
s1_open() {
  local id="$1" rc
  pn_open_panel; rc=$?
  [ $rc = 0 ] && return 0
  if [ $rc = 3 ]; then
    echo "CHECK $id NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; S1_RC=0
  else
    s1_fail "$id" "$PN_OUT"; S1_RC=1
  fi
  return 1
}

# s1_search <text> [kit-search args] : runs kit-search.sh; S1_OUT holds its output. Status is its status.
S1_LASTQ=""
s1_search() {
  S1_LASTQ="$1"
  S1_OUT="$(s1_kq "$S1_SEARCH" "$@" 2>&1)"
  return $?
}

s1_show() { printf '%s\n' "$S1_OUT" | sed 's/^/  | /'; }

# s1_search_verdict <id> <status> : status 0 when kit-search.sh worked; else prints the CHECK line, sets S1_RC, returns 1.
s1_search_ok() {
  local id="$1" rc="$2"
  [ "$rc" = 0 ] && return 0
  s1_show
  case "$rc" in
    3) echo "CHECK $id NEEDS-A-PERSON $(printf '%s\n' "$S1_OUT" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; S1_RC=0 ;;
    4) echo "RERUN $id not valid: $(s1_last "$S1_OUT")"; S1_RC=4 ;;
    *) s1_fail "$id" "kit-search.sh \"$S1_LASTQ\" exited $rc: $(printf '%s\n' "$S1_OUT" | sed -n 1p)"; S1_RC=1 ;;
  esac
  return 1
}

# Readers of S1_OUT (the output of kit-search.sh).
s1_rows_n() { printf '%s\n' "$S1_OUT" | awk '$1 == "rows" { print $2; exit }'; }
s1_row_sel() { printf '%s\n' "$S1_OUT" | awk -v n="$1" '$1 == "row" && $2 == n { print $3; exit }'; }
s1_row_text() { printf '%s\n' "$S1_OUT" | awk -v n="$1" '$1 == "row" && $2 == n { sub(/^row [0-9]+ (selected|-) ?/, ""); print; exit }'; }
s1_pane() { printf '%s\n' "$S1_OUT" | awk '$1 == "pane" { sub(/^pane /, ""); print }'; }
s1_selected_n() { printf '%s\n' "$S1_OUT" | awk '$1 == "row" && $3 == "selected" { print $2; exit }'; }

# s1_name_of_row <n> : the photo file name in row n of S1_OUT.
s1_name_of_row() { pn_row_name "$(s1_row_text "$1")"; }

# s1_reread : waits for the panel to settle and puts it into S1_OUT in the shape kit-search.sh prints.
s1_reread() {
  local rows
  pn_wait_list 10
  rows="$(pn_rows)"
  S1_OUT="rows $(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n + 0 }')"$'\n'"$(printf '%s\n' "$rows" | awk -F'\t' 'NF { printf "row %s %s %s\n", $1, $2, $3 }')"$'\n'"$(pn_pane | awk '{ print "pane " $0 }')"
}

# s1_golden_path <file name> : the on-disk path of a golden photo.
s1_golden_path() { echo "$KIT_ROOT/fixtures/golden/photos/$1"; }

# s1_wait_front <app name> [seconds] : status 0 once that app is frontmost; READBACK holds the readback lines.
READBACK=""
s1_wait_front() {
  local want="$1" n="${2:-10}" i rc
  for ((i = 0; i < n * 2; i++)); do
    READBACK="$(s1_rbp "System Events" frontmost)"; rc=$?
    [ $rc = 3 ] && return 1
    [ "$(printf '%s\n' "$READBACK" | sed -n 1p)" = "$want" ] && return 0
    sleep 0.5
  done
  return 1
}

# s1_queries <group> : the query column of the rows of that group in fixtures/answers.csv (the hand-written key).
s1_queries() { awk -F, -v g="$1" '$2 == g { print $3 }' "$KIT_PROJECT/fixtures/answers.csv"; }

# ---- the panel facts S1.1 and S1.2 read ----------------------------------------------------------------

S1_W=""; S1_H=""; S1_HAS_BOX=0; S1_LABEL=""; S1_VALUE=""; S1_FOCUS=0

s1_panel_facts() {
  local size box
  pn_dump
  size="$(pn_size)"
  S1_W=""; S1_H=""
  if [ -n "$size" ]; then S1_W="${size% *}"; S1_H="${size#* }"; fi
  box="$(pn_searchbox)"
  if [ -n "$box" ]; then
    S1_HAS_BOX=1
    S1_LABEL="$(printf '%s' "$box" | cut -f1)"
    S1_VALUE="$(printf '%s' "$box" | cut -f2)"
    S1_FOCUS="$(printf '%s' "$box" | cut -f3)"
  else
    S1_HAS_BOX=0; S1_LABEL=""; S1_VALUE=""; S1_FOCUS=0
  fi
}

# s1_open_why : the reasons the open panel does not meet S1.1 (empty when it does).
s1_open_why() {
  local why="" lc
  case "$S1_W$S1_H" in
    ""|*[!0-9]*) why="the panel size could not be read" ;;
    *)
      if [ "$S1_W" -lt 959 ] || [ "$S1_W" -gt 961 ] || [ "$S1_H" -lt 559 ] || [ "$S1_H" -gt 561 ]; then
        why="the panel is $S1_W x $S1_H points, not 960 x 560"
      fi ;;
  esac
  if [ "$S1_HAS_BOX" = 0 ]; then
    why="${why:+$why; }no search box: the panel ($S1_W x $S1_H) holds no text field in its accessibility tree, so the cursor, the search label and the empty value cannot be read"
  else
    lc="$(printf '%s' "$S1_LABEL" | tr 'A-Z' 'a-z')"
    case "$lc" in *search*) ;; *) why="${why:+$why; }the text field is labelled \"$S1_LABEL\", not for search" ;; esac
    [ "$S1_FOCUS" = 1 ] || why="${why:+$why; }the search box does not have the focus"
    [ -z "$S1_VALUE" ] || why="${why:+$why; }the search box holds \"$S1_VALUE\" after a fresh open"
  fi
  printf '%s' "$why"
}

# ---- S1.1: the shortcut opens the 960 x 560 panel with the cursor in an empty search box ---------------

s1_check_1() {
  local why
  s1_begin S1.1 0 || return $S1_RC
  s1_open S1.1 || return $S1_RC
  s1_panel_facts
  why="$(s1_open_why)"
  if [ -n "$why" ]; then s1_fail S1.1 "$why"; return 1; fi
  echo "CHECK S1.1 PASS the shortcut opens a panel of $S1_W x $S1_H points with the focus in an empty search box labelled \"$S1_LABEL\" (posted from the kit's own window: the shortcut is never posted over Finder, Preview or TextEdit, so those three starting points are not driven)"
}
check_S1_1() { s1_run s1_check_1; }

# ---- S1.2: it opens over a full-screen app -------------------------------------------------------------

s1_check_2() {
  local out rc why panel_line kit_line pl kl
  s1_begin S1.2 0 || return $S1_RC
  pn_kit_open; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S1.2 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; return 0; fi
  if [ $rc != 0 ]; then s1_fail S1.2 "the kit window did not open: $PN_OUT"; return 1; fi
  out="$(pn_ax fullscreen kitwindow on 2>&1)"; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S1.2 NEEDS-A-PERSON $(printf '%s\n' "$out" | sed -n 1p)"; return 0; fi
  if [ $rc != 0 ]; then s1_fail S1.2 "the kit window could not be put in full screen: $(s1_last "$out")"; return 1; fi
  S1_FS=1
  sleep 1
  s1_open S1.2 || return $S1_RC
  s1_panel_facts
  why="$(s1_open_why)"
  panel_line="$("$(kit_tool pixelpoll)" windows Sesame | awk '$3 >= 900 { print; exit }')"
  kit_line="$("$(kit_tool pixelpoll)" windows kitwindow | awk '$3 >= 200 { print; exit }')"
  if [ -z "$panel_line" ]; then
    why="${why:+$why; }the panel is not on screen in the window list while the kit window is in full screen"
  else
    pl="$(printf '%s\n' "$panel_line" | awk '{ print $5 }')"
    kl="$(printf '%s\n' "$kit_line" | awk '{ print $5 }')"
    if [ -z "$kl" ]; then
      why="${why:+$why; }the full-screen kit window is not in the window list, so the panel's layer cannot be compared"
    elif [ "$pl" -le "$kl" ]; then
      why="${why:+$why; }the panel's layer ($pl) is not above the full-screen window's ($kl)"
    fi
  fi
  echo "window list while the kit window is in full screen: panel layer ${pl:-none}, kit window layer ${kl:-none}"
  if [ -n "$why" ]; then s1_fail S1.2 "$why"; return 1; fi
  echo "CHECK S1.2 PASS with the kit's own window in full screen (layer $kl; Preview in full screen cannot be driven, kit-ax.sh drives full screen only for Sesame and the kit window) the shortcut shows a panel on screen above it (layer $pl), $S1_W x $S1_H points, the focus in an empty search box"
}
check_S1_2() { s1_run s1_check_2; }

# ---- S1.3: reopening never shows the previous text -----------------------------------------------------

# s1_reopened_why <what> : the panel was just reopened; the reasons it is not clean (empty when it is).
s1_reopened_why() {
  local what="$1" why="" rows pane
  s1_panel_facts
  if [ "$S1_HAS_BOX" = 0 ]; then why="no search box after $what"
  else
    [ -z "$S1_VALUE" ] || why="the search box still holds \"$S1_VALUE\" after $what"
  fi
  rows="$(pn_rows | awk 'NF { n++ } END { print n + 0 }')"
  [ "$rows" = 0 ] || why="${why:+$why; }$rows result rows are listed after $what"
  pane="$(pn_pane)"
  [ -n "$pane" ] || why="${why:+$why; }the panel shows no hint after $what"
  case "$pane" in *"No matches"*) why="${why:+$why; }the pane says No matches after $what" ;; esac
  printf '%s' "$why"
}

s1_check_3() {
  local rc why="" w
  s1_begin S1.3 0 || return $S1_RC
  s1_open S1.3 || return $S1_RC
  s1_panel_facts
  if [ "$S1_HAS_BOX" = 0 ]; then
    s1_fail S1.3 "no search box: the panel holds no text field to type \"$S1_QUERY\" into, so reopening cannot be shown to clear it"
    return 1
  fi
  pn_wait_sesame_front 3 || { s1_fail S1.3 "Sesame is not frontmost after the shortcut ($PN_OUT): nothing was typed"; return 1; }

  # (a) close with the shortcut, reopen
  pn_ax type "$S1_QUERY" >/dev/null 2>&1 || { s1_fail S1.3 "typing was refused"; return 1; }
  sleep 1
  pn_ax hotkey >/dev/null 2>&1
  pn_wait_panel gone 8 || why="the shortcut did not close the panel"
  s1_open S1.3 || return $S1_RC
  w="$(s1_reopened_why "closing with the shortcut")"
  [ -z "$w" ] || why="${why:+$why; }$w"

  # (b) Esc, Esc, reopen
  pn_wait_sesame_front 3 && {
    pn_ax type "$S1_QUERY" >/dev/null 2>&1
    sleep 1
    pn_ax key esc >/dev/null 2>&1
    pn_ax key esc >/dev/null 2>&1
    pn_wait_panel gone 8 || why="${why:+$why; }two Esc presses did not close the panel"
  }
  s1_open S1.3 || return $S1_RC
  w="$(s1_reopened_why "Esc Esc")"
  [ -z "$w" ] || why="${why:+$why; }$w"

  # (c) the app lost focus (the kit window comes to the front), then the panel is reopened
  if pn_wait_sesame_front 3; then
    pn_ax type "$S1_QUERY" >/dev/null 2>&1
    sleep 1
    pn_kit_open >/dev/null 2>&1
    sleep 1
    s1_open S1.3 || return $S1_RC
    w="$(s1_reopened_why "the app lost focus")"
    [ -z "$w" ] || why="${why:+$why; }$w"
  else
    why="${why:+$why; }Sesame was not frontmost after the second reopen: $PN_OUT"
  fi
  if [ -n "$why" ]; then s1_fail S1.3 "$why"; return 1; fi
  echo "CHECK S1.3 PASS \"$S1_QUERY\" typed, then after the shortcut, after Esc Esc and after the app lost focus the reopened panel had an empty box, no result rows and the quiet hint"
}
check_S1_3() { s1_run s1_check_3; }

# ---- S1.4: the shortcut while the panel is open closes it ------------------------------------------------

s1_check_4() {
  local rc before after i out
  s1_begin S1.4 0 || return $S1_RC
  pn_kit_open; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S1.4 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; return 0; fi
  if [ $rc != 0 ]; then s1_fail S1.4 "the kit window did not open: $PN_OUT"; return 1; fi
  before="$(pn_front)"
  s1_open S1.4 || return $S1_RC
  # The second press goes to whichever of Sesame and the kit window is frontmost: both are allowed to receive it.
  out="$(pn_ax hotkey 2>&1)"; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S1.4 NEEDS-A-PERSON $(printf '%s\n' "$out" | sed -n 1p)"; return 0; fi
  if [ $rc != 0 ]; then s1_fail S1.4 "the second shortcut press was refused: $(s1_last "$out")"; return 1; fi
  if ! pn_wait_panel gone 12; then s1_fail S1.4 "the panel is still on screen after the second press of the shortcut"; return 1; fi
  after=""
  for ((i = 0; i < 8; i++)); do
    after="$(pn_front)"
    [ "$after" = "$before" ] && break
    sleep 0.25
  done
  if [ "$after" != "$before" ]; then s1_fail S1.4 "the frontmost app is $after, not $before as before the shortcut"; return 1; fi
  echo "CHECK S1.4 PASS the shortcut opened the panel and the second press closed it; the app in front before ($before) is in front again"
}
check_S1_4() { s1_run s1_check_4; }

# ---- S1.5: typing lists matching files, the first selected and shown large on the right ----------------

# s1_size_ok <text> <bytes> : status 0 when the text holds a size within 5 percent of the file's (units of 1,000
# or of 1,024: both are in use).
s1_size_ok() {
  printf '%s\n' "$1" | awk -v want="$2" '
  function near(v, m) { d = v * m - want; if (d < 0) d = -d; return d <= want * 0.05 }
  {
    s = $0
    while (match(s, /[0-9][0-9.,]*[ ]?(bytes|byte|KB|kB|MB|GB)/)) {
      tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      num = tok; gsub(/[^0-9.]/, "", num)
      v = num + 0
      if (tok ~ /GB/) { if (near(v, 1000000000) || near(v, 1073741824)) ok = 1 }
      else if (tok ~ /MB/) { if (near(v, 1000000) || near(v, 1048576)) ok = 1 }
      else if (tok ~ /[kK]B/) { if (near(v, 1000) || near(v, 1024)) ok = 1 }
      else { if (near(v, 1)) ok = 1 }
    }
  }
  END { exit ok ? 0 : 1 }'
}

# s1_date_ok <text> <yyyy-mm-dd> : status 0 when the text shows that day in one of the usual local spellings.
s1_date_ok() {
  local f cand
  for f in '%Y-%m-%d' '%b %-d, %Y' '%B %-d, %Y' '%-d %b %Y' '%-d %B %Y' '%-m/%-d/%y' '%-m/%-d/%Y' '%d/%m/%Y' '%d.%m.%Y' '%-d/%-m/%Y' '%b %d, %Y' '%d %b %Y' '%d %B %Y' '%B %d, %Y'; do
    cand="$(date -j -f %Y-%m-%d "$2" "+$f" 2>/dev/null)"
    [ -n "$cand" ] || continue
    case "$1" in *"$cand"*) return 0 ;; esac
  done
  return 1
}

s1_check_5() {
  local rc facts path size date app name pane why="" p ok dup
  s1_begin S1.5 1 || return $S1_RC
  s1_search "$S1_QUERY" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.5 $rc || return $S1_RC
  facts="$(s1_kq "$S1_RB" file-facts golden/photos/beach-dog.jpg 2>&1)"
  path="$(printf '%s\n' "$facts" | awk '$1 == "path" { print $2; exit }')"
  size="$(printf '%s\n' "$facts" | awk '$1 == "size" { print $2; exit }')"
  date="$(printf '%s\n' "$facts" | awk '$1 == "date" { print $2; exit }')"
  app="$(s1_kq "$S1_RB" default-app jpg 2>&1)"
  if [ -z "$path" ] || [ -z "$app" ]; then
    echo "RERUN S1.5 not valid: the expected values could not be read (file-facts: $(s1_last "$facts"); default-app jpg: $app)"
    return 4
  fi
  [ "$(s1_rows_n)" -ge 1 ] 2>/dev/null || why="the list has no row for \"$S1_QUERY\""
  if [ -z "$why" ]; then
    [ "$(s1_row_sel 1)" = selected ] || why="row 1 is not selected"
    name="$(s1_name_of_row 1)"
    [ "$name" = beach-dog.jpg ] || why="${why:+$why; }row 1 is \"$(s1_row_text 1)\", not photos/beach-dog.jpg"
  fi
  pane="$(s1_pane)"
  case "$pane" in *beach-dog.jpg*) ;; *) why="${why:+$why; }the pane does not show the file name beach-dog.jpg" ;; esac
  ok=0
  for p in "$path" "$(pn_norm_path "$path")" "/private$(pn_norm_path "$path")"; do
    case "$pane" in *"$p"*) ok=1 ;; esac
  done
  [ "$ok" = 1 ] || why="${why:+$why; }the pane does not show the full path $path"
  case "$(printf '%s' "$pane" | tr 'A-Z' 'a-z')" in *photo*) ;; *) why="${why:+$why; }the pane does not show the kind photo" ;; esac
  s1_size_ok "$pane" "$size" || why="${why:+$why; }the pane shows no size within 5 percent of $size bytes"
  s1_date_ok "$pane" "$date" || why="${why:+$why; }the pane shows no date equal to $date (local time)"
  case "$pane" in *"Opens in $app"*) ;; *) why="${why:+$why; }the pane does not say \"Opens in $app\" (Launch Services names $app for jpg)" ;; esac
  # Extra lines (not S1.6): no file twice in the list.
  dup="$(printf '%s\n' "$S1_OUT" | awk '$1 == "row" { n = $0; sub(/^row [0-9]+ (selected|-) ?/, "", n); seen[n]++ } END { for (k in seen) if (seen[k] > 1) print k }')"
  if [ -n "$dup" ]; then echo "extra: the same row twice in the list: $dup"; else echo "extra: no row appears twice in the list"; fi
  if [ -n "$why" ]; then s1_fail S1.5 "$why"; return 1; fi
  echo "CHECK S1.5 PASS \"$S1_QUERY\" lists beach-dog.jpg first and selected; the pane shows its name, full path, kind photo, size, date and \"Opens in $app\""
}
check_S1_5() { s1_run s1_check_5; }

# ---- S1.7: Up and Down move the selection ----------------------------------------------------------------

s1_check_7() {
  local rc n pid0 pid1 sel name2 name1 pane i why=""
  s1_begin S1.7 1 || return $S1_RC
  pid0="$(kit_pid_of app)"
  s1_search "$S1_QUERY" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.7 $rc || return $S1_RC
  n="$(s1_rows_n)"
  if ! [ "$n" -ge 2 ] 2>/dev/null; then s1_fail S1.7 "the list has $n rows for \"$S1_QUERY\", Down and Up need at least 2"; return 1; fi
  name1="$(s1_name_of_row 1)"
  name2="$(s1_name_of_row 2)"
  [ "$(s1_row_sel 1)" = selected ] || why="row 1 is not selected at the start"
  pn_ax key down >/dev/null 2>&1 || { s1_fail S1.7 "Down was refused"; return 1; }
  s1_reread
  sel="$(s1_selected_n)"
  [ "$sel" = 2 ] || why="${why:+$why; }Down moved the selection to row ${sel:-none}, not row 2"
  pane="$(s1_pane)"
  case "$pane" in *"$name2"*) ;; *) why="${why:+$why; }after Down the pane does not show row 2's file ($name2)" ;; esac
  pn_ax key up >/dev/null 2>&1 || { s1_fail S1.7 "Up was refused"; return 1; }
  s1_reread
  sel="$(s1_selected_n)"
  [ "$sel" = 1 ] || why="${why:+$why; }Up moved the selection to row ${sel:-none}, not back to row 1"
  case "$(s1_pane)" in *"$name1"*) ;; *) why="${why:+$why; }after Up the pane does not show row 1's file ($name1)" ;; esac
  pn_ax key up >/dev/null 2>&1
  s1_reread
  sel="$(s1_selected_n)"
  [ "$sel" = 1 ] || why="${why:+$why; }Up on row 1 moved the selection to row ${sel:-none} (it wraps)"
  # Down to the last row and past it.
  for ((i = 1; i <= n; i++)); do pn_ax key down >/dev/null 2>&1; done
  s1_reread
  sel="$(s1_selected_n)"
  [ "$sel" = "$n" ] || why="${why:+$why; }Down past the last row left the selection on row ${sel:-none}, not on the last row ($n)"
  pid1="$(kit_pid_of app)"
  [ "$pid0" = "$pid1" ] || why="${why:+$why; }the app's process changed (was $pid0, is $pid1)"
  if [ -n "$why" ]; then s1_fail S1.7 "$why"; return 1; fi
  echo "CHECK S1.7 PASS Down moved the selection to row 2 and the pane to $name2, Up moved it back; Up on row 1 and Down on the last row ($n) stayed put; the app kept running"
}
check_S1_7() { s1_run s1_check_7; }

# ---- S1.8 to S1.11: Enter, Command+Enter, Command+C ------------------------------------------------------

s1_check_8() {
  local rc app name title i
  s1_begin S1.8 1 || return $S1_RC
  app="$(s1_kq "$S1_RB" default-app jpg 2>&1)"
  s1_search "$S1_QUERY" --open; rc=$?
  s1_show
  s1_search_ok S1.8 $rc || return $S1_RC
  name="$(s1_name_of_row 1)"
  [ -n "$name" ] || name=beach-dog.jpg
  if ! s1_wait_front "$app" 10; then
    s1_fail S1.8 "after Enter the frontmost app is $(printf '%s\n' "$READBACK" | sed -n 1p), not $app (the default for jpg)"
    return 1
  fi
  for ((i = 0; i < 10; i++)); do
    title="$(printf '%s\n' "$READBACK" | sed -n 2p)"
    case "$title" in *"$name"*) break ;; esac
    sleep 0.5
    READBACK="$(s1_kq "$S1_RB" frontmost 2>&1)"
  done
  case "$title" in
    *"$name"*) echo "CHECK S1.8 PASS Enter opened $name in $app (front window: ${title#window: })" ;;
    *) s1_fail S1.8 "$app is frontmost but its front window is \"${title#window: }\", which does not name $name"; return 1 ;;
  esac
}
check_S1_8() { s1_run s1_check_8; }

# s1_same_path <a> <b> : the two paths are the same file (a /private prefix does not matter).
s1_same_path() { [ "$(pn_norm_path "$1")" = "$(pn_norm_path "$2")" ]; }

s1_check_9() {
  local rc name sel want n i
  s1_begin S1.9 1 || return $S1_RC
  s1_search "$S1_QUERY" --reveal; rc=$?
  s1_show
  s1_search_ok S1.9 $rc || return $S1_RC
  name="$(s1_name_of_row 1)"
  [ -n "$name" ] || name=beach-dog.jpg
  want="$(s1_golden_path "$name")"
  if ! s1_wait_front Finder 10; then
    s1_fail S1.9 "after Command+Enter the frontmost app is $(printf '%s\n' "$READBACK" | sed -n 1p), not Finder"
    return 1
  fi
  sel="$(s1_rbp Finder finder-selection)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.9 "$sel"; return 0; fi
  n="$(printf '%s\n' "$sel" | awk 'NF { n++ } END { print n + 0 }')"
  if [ "$n" != 1 ] || ! s1_same_path "$sel" "$want"; then
    s1_fail S1.9 "Finder's selection is \"$(printf '%s' "$sel" | tr '\n' ' ')\", not exactly $want"
    return 1
  fi
  echo "CHECK S1.9 PASS Command+Enter brought Finder to the front with exactly $want selected"
}
check_S1_9() { s1_run s1_check_9; }

s1_check_10() {
  local rc name want pb nfile box why=""
  s1_begin S1.10 1 || return $S1_RC
  s1_kq "$S1_RB" pasteboard --set SENTINEL >/dev/null
  s1_search "$S1_QUERY" --keep-open --copy; rc=$?
  s1_show
  s1_search_ok S1.10 $rc || return $S1_RC
  name="$(s1_name_of_row 1)"
  [ -n "$name" ] || name=beach-dog.jpg
  want="$(s1_golden_path "$name")"
  sleep 0.5
  pb="$(s1_kq "$S1_RB" pasteboard 2>&1)"
  nfile="$(printf '%s\n' "$pb" | awk '$1 == "file" { n++ } END { print n + 0 }')"
  if [ "$nfile" != 1 ]; then why="the pasteboard holds $nfile file URLs, not one (it reads: $(printf '%s' "$pb" | tr '\n' ' '))"
  elif ! s1_same_path "$(printf '%s\n' "$pb" | awk '$1 == "file" { sub(/^file /, ""); print; exit }')" "$want"; then
    why="the pasteboard's file is $(printf '%s\n' "$pb" | awk '$1 == "file" { sub(/^file /, ""); print; exit }'), not $want"
  fi
  pn_dump
  box="$(pn_searchbox)"
  [ "$(printf '%s' "$box" | cut -f2)" = "$S1_QUERY" ] || why="${why:+$why; }the typed text changed: the box now holds \"$(printf '%s' "$box" | cut -f2)\""
  if [ -n "$why" ]; then s1_fail S1.10 "$why"; return 1; fi
  echo "CHECK S1.10 PASS Command+C with no text selected put the file $want on the pasteboard as one file URL and left the typed text alone"
}
check_S1_10() { s1_run s1_check_10; }

s1_check_11() {
  local rc pb
  s1_begin S1.11 1 || return $S1_RC
  s1_search "$S1_QUERY" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.11 $rc || return $S1_RC
  s1_kq "$S1_RB" pasteboard --set SENTINEL >/dev/null
  pn_ax key "cmd+a" >/dev/null 2>&1 || { s1_fail S1.11 "Command+A was refused"; return 1; }
  pn_ax key "cmd+c" >/dev/null 2>&1 || { s1_fail S1.11 "Command+C was refused"; return 1; }
  sleep 0.5
  pb="$(s1_kq "$S1_RB" pasteboard 2>&1)"
  if [ "$pb" != "$S1_QUERY" ]; then
    s1_fail S1.11 "the pasteboard reads \"$(printf '%s' "$pb" | tr '\n' ' ')\", not exactly the typed text \"$S1_QUERY\" with no file URL"
    return 1
  fi
  echo "CHECK S1.11 PASS with the typed text selected Command+C put exactly \"$S1_QUERY\" on the pasteboard, with no file URL"
}
check_S1_11() { s1_run s1_check_11; }

# ---- S1.12: Esc takes two presses with text, one with none ---------------------------------------------------

s1_check_12() {
  local why="" box
  s1_begin S1.12 1 || return $S1_RC
  s1_open S1.12 || return $S1_RC
  pn_dump
  box="$(pn_searchbox)" || { s1_fail S1.12 "no search box: there is no text to clear with Esc"; return 1; }
  pn_wait_sesame_front 3 || { s1_fail S1.12 "Sesame is not frontmost after the shortcut ($PN_OUT): nothing was typed"; return 1; }
  pn_ax type "a dog" >/dev/null 2>&1 || { s1_fail S1.12 "typing was refused"; return 1; }
  sleep 1
  pn_ax key esc >/dev/null 2>&1 || { s1_fail S1.12 "Esc was refused"; return 1; }
  sleep 0.5
  if ! pn_panel_exists; then why="the first Esc closed the panel instead of clearing the text"
  else
    pn_dump
    box="$(pn_searchbox)"
    [ -z "$(printf '%s' "$box" | cut -f2)" ] || why="after one Esc the box still holds \"$(printf '%s' "$box" | cut -f2)\""
    pn_ax key esc >/dev/null 2>&1
    pn_wait_panel gone 8 || why="${why:+$why; }the second Esc did not close the panel"
  fi
  # An empty box: one Esc closes.
  s1_open S1.12 || return $S1_RC
  pn_wait_sesame_front 3 || { s1_fail S1.12 "Sesame is not frontmost after the second open ($PN_OUT)"; return 1; }
  pn_ax key esc >/dev/null 2>&1
  pn_wait_panel gone 8 || why="${why:+$why; }with an empty box one Esc did not close the panel"
  if [ -n "$why" ]; then s1_fail S1.12 "$why"; return 1; fi
  echo "CHECK S1.12 PASS with text the first Esc cleared it and kept the panel open, the second closed it; with an empty box one Esc closed it"
}
check_S1_12() { s1_run s1_check_12; }

# ---- S1.13: fast typing then Enter opens the first result for the text in the box --------------------------

# One try: the panel opened fresh, the text typed at 5 ms a key and Enter 10 ms after the last key. S1_TITLE is the
# title of the window the default app opened ("" when nothing opened); S1_STILL is 1 when the panel then shows
# "Still ranking". Status 0 when a window opened.
S1_TITLE=""
S1_STILL=0
S1_GARBLED=""
s1_race_once() {
  local q="$1" app="$2" rc box
  S1_TITLE=""; S1_STILL=0; S1_GARBLED=""
  pn_open_panel; rc=$?
  [ $rc = 0 ] || { S1_TITLE="(the panel did not open: $PN_OUT)"; return 1; }
  pn_wait_sesame_front 3 || { S1_TITLE="(Sesame is not frontmost: $PN_OUT)"; return 1; }
  pn_ax type "$q" --delay-ms 5 --then enter --then-delay-ms 10 >/dev/null 2>&1
  if s1_wait_front "$app" 8; then
    S1_TITLE="$(printf '%s\n' "$READBACK" | sed -n 2p)"
    S1_TITLE="${S1_TITLE#window: }"
    pn_dump
    box="$(pn_searchbox 2>/dev/null | awk -F'\t' '{ print $2; exit }')"
    [ -z "$box" ] || [ "$box" = "$q" ] || S1_GARBLED="$box"
    return 0
  fi
  pn_dump
  box="$(pn_searchbox 2>/dev/null | awk -F'\t' '{ print $2; exit }')"
  [ -z "$box" ] || [ "$box" = "$q" ] || S1_GARBLED="$box"
  case "$PN_DUMP" in *"Still ranking"*) S1_STILL=1 ;; esac
  return 1
}

s1_check_13() {
  local app q expected prefix pfirst words half try rc opened diff=0 total=0 why="" lines="" title garbled=""
  s1_begin S1.13 1 || return $S1_RC
  app="$(s1_kq "$S1_RB" default-app jpg 2>&1)"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    total=$((total + 1))
    # the settled first result of the whole text, typed slowly
    s1_search "$q"; rc=$?
    s1_search_ok S1.13 $rc || return $S1_RC
    expected="$(s1_name_of_row 1)"
    # the first result of an earlier prefix (the first half of the words), typed slowly
    words="$(printf '%s\n' "$q" | awk '{ print NF }')"
    half=$((words / 2)); [ "$half" -ge 1 ] || half=1
    prefix="$(printf '%s\n' "$q" | awk -v h="$half" '{ s = $1; for (i = 2; i <= h; i++) s = s " " $i; print s }')"
    s1_search "$prefix"; rc=$?
    s1_search_ok S1.13 $rc || return $S1_RC
    pfirst="$(s1_name_of_row 1)"
    # the race, at most three tries while the panel says "Still ranking"
    opened=0
    for try in 1 2 3; do
      s1_race_once "$q" "$app" && opened=1
      [ -z "$S1_GARBLED" ] || garbled="${garbled:+$garbled; }\"$q\" read back as \"$S1_GARBLED\""
      [ "$opened" = 1 ] && break
      [ "$S1_STILL" = 1 ] || break
      lines="$lines
  | \"$q\" try $try: the panel shows Still ranking"
    done
    if [ "$opened" = 0 ]; then
      why="${why:+$why; }\"$q\": nothing was opened (${S1_TITLE:-no window}$([ "$S1_STILL" = 1 ] && echo ', Still ranking after 3 tries'))"
      continue
    fi
    title="$S1_TITLE"
    case "$title" in
      *"$expected"*)
        [ "$expected" != "$pfirst" ] && diff=$((diff + 1)) ;;
      *) why="${why:+$why; }\"$q\": opened \"$title\", the settled first result is $expected" ;;
    esac
    lines="$lines
  | \"$q\": opened $title, settled first $expected, first for \"$prefix\" $pfirst"
  done < <(s1_queries photo)
  printf '%s\n' "$lines" | sed '/^$/d'
  if [ -n "$garbled" ]; then
    echo "RERUN S1.13 not valid: the keys did not all reach the box ($garbled)"
    return 4
  fi
  [ "$total" = 10 ] || why="${why:+$why; }fixtures/answers.csv holds $total photo queries, not 10"
  [ "$diff" -ge 3 ] || why="${why:+$why; }the race was not real: the opened file differed from an earlier prefix's first result in $diff of $total queries, not 3"
  if [ -n "$why" ]; then s1_fail S1.13 "$why"; return 1; fi
  echo "CHECK S1.13 PASS for all $total photo queries typed at 5 ms with Enter 10 ms after the last key, the file opened was the settled first result for the full text ($diff of $total differed from an earlier prefix's first result)"
}
check_S1_13() { s1_run s1_check_13; }

# ---- S1.14: Enter, Command+Enter and Command+C do nothing with no results -----------------------------------

s1_check_14() {
  local rc pid0 pid1 front0 front1 sel0 sel1 pb0 pb1 win0 win1 why="" k
  s1_begin S1.14 1 || return $S1_RC
  S1_QUERY_NONE="zzqx vvkw jjpl"
  s1_search "$S1_QUERY_NONE" --keep-open; rc=$?
  s1_show
  s1_search_ok S1.14 $rc || return $S1_RC
  [ "$(s1_rows_n)" = 0 ] || why="the list holds $(s1_rows_n) rows for \"$S1_QUERY_NONE\" (the check needs none)"
  s1_kq "$S1_RB" pasteboard --set SENTINEL >/dev/null
  pid0="$(kit_pid_of app)"
  front0="$(s1_rbp "System Events" frontmost)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.14 "$front0"; return 0; fi
  front0="$(printf '%s\n' "$front0" | sed -n 1p)"
  sel0="$(s1_rbp Finder finder-selection)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.14 "$sel0"; return 0; fi
  pb0="$(s1_kq "$S1_RB" pasteboard 2>&1)"
  win0="$(pn_probe Sesame read windows)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.14 "$win0"; return 0; fi
  for k in enter cmd+enter cmd+c; do
    pn_ax key "$k" >/dev/null 2>&1 || why="${why:+$why; }$k was refused"
  done
  sleep 1
  pid1="$(kit_pid_of app)"
  front1="$(s1_rbp "System Events" frontmost)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.14 "$front1"; return 0; fi
  front1="$(printf '%s\n' "$front1" | sed -n 1p)"
  sel1="$(s1_rbp Finder finder-selection)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.14 "$sel1"; return 0; fi
  pb1="$(s1_kq "$S1_RB" pasteboard 2>&1)"
  win1="$(pn_probe Sesame read windows)"; rc=$?
  if [ $rc = 3 ]; then s1_person_line S1.14 "$win1"; return 0; fi
  [ "$pid0" = "$pid1" ] || why="${why:+$why; }the app's process changed (was $pid0, is $pid1)"
  [ "$front0" = "$front1" ] || why="${why:+$why; }the frontmost app changed from $front0 to $front1"
  [ "$sel0" = "$sel1" ] || why="${why:+$why; }Finder's selection changed"
  [ "$pb0" = "$pb1" ] || why="${why:+$why; }the pasteboard changed from \"$pb0\" to \"$pb1\""
  [ "$win0" = "$win1" ] || why="${why:+$why; }a window was opened or closed"
  if [ -n "$why" ]; then s1_fail S1.14 "$why"; return 1; fi
  echo "CHECK S1.14 PASS with no results Enter, Command+Enter and Command+C left the frontmost app ($front0), Finder's selection, the pasteboard and the windows as they were, and the app (pid $pid0) kept running"
}
check_S1_14() { s1_run s1_check_14; }

# ---- S1.15: a file that has gone: "That file is no longer there" -------------------------------------------

s1_check_15() {
  local keys q n i k rc name1 name2 path1 pane t0 t1 pid0 pid1 front0 front1 pb1 sel_n sel_text why="" marker crash lines=""
  s1_begin S1.15 1 || return $S1_RC
  marker="$KIT_ROOT/run/s1-15-start"
  mkdir -p "$KIT_ROOT/run"
  : > "$marker"
  keys="enter cmd+enter cmd+c"
  i=0
  for k in $keys; do
    i=$((i + 1))
    q="$(s1_queries photo | sed -n "${i}p")"
    s1_search "$q" --keep-open; rc=$?
    s1_search_ok S1.15 $rc || { s1_kq "$S1_FX" restore >/dev/null 2>&1; return $S1_RC; }
    name1="$(s1_name_of_row 1)"
    name2="$(s1_name_of_row 2)"
    [ -n "$name1" ] && [ -n "$name2" ] || { s1_fail S1.15 "\"$q\" lists fewer than two photos, so there is no next row to select"; s1_kq "$S1_FX" restore >/dev/null 2>&1; return 1; }
    path1="$(s1_golden_path "$name1")"
    s1_kq "$S1_RB" pasteboard --set SENTINEL >/dev/null
    pid0="$(kit_pid_of app)"
    front0="$(pn_front)"
    t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    s1_kq "$S1_FX" mutate delete "$path1" >/dev/null 2>&1 || { s1_fail S1.15 "the kit could not delete $path1"; s1_kq "$S1_FX" restore >/dev/null 2>&1; return 1; }
    pn_ax key "$k" >/dev/null 2>&1 || why="${why:+$why; }$k was refused"
    t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    if [ "$(perl -e "print(($t1 - $t0) > 2.0 ? 1 : 0)")" = 1 ]; then
      s1_kq "$S1_FX" restore >/dev/null 2>&1
      echo "RERUN S1.15 not valid: the key came $(perl -e "printf '%.1f', $t1 - $t0") s after the delete, over the 2 s the row needs to still be there"
      return 4
    fi
    pn_wait_list 10
    pane="$(pn_pane)"
    case "$PN_DUMP" in *"That file is no longer there"*) ;; *) why="${why:+$why; }$k on $name1 (deleted): the panel does not say \"That file is no longer there\"" ;; esac
    if pn_listed "$name1"; then why="${why:+$why; }$k: the deleted row ($name1) is still listed"; fi
    sel_n="$(pn_rows | awk -F'\t' '$2 == "selected" { print $3; exit }')"
    case "$sel_n" in *"$name2"*) ;; *) why="${why:+$why; }$k: the selected row is \"$sel_n\", not the next one ($name2)" ;; esac
    pid1="$(kit_pid_of app)"
    [ "$pid0" = "$pid1" ] || why="${why:+$why; }$k: the app's process changed (was $pid0, is $pid1)"
    front1="$(pn_front)"
    case "$k" in
      enter|cmd+enter) [ "$front0" = "$front1" ] || why="${why:+$why; }$k: the frontmost app changed from $front0 to $front1 (something was opened or revealed)" ;;
      cmd+c)
        pb1="$(s1_kq "$S1_RB" pasteboard 2>&1)"
        [ "$pb1" = SENTINEL ] || why="${why:+$why; }cmd+c: the pasteboard changed to \"$pb1\"" ;;
    esac
    lines="$lines
  | $k on $name1: message $(case "$PN_DUMP" in *"That file is no longer there"*) echo shown ;; *) echo missing ;; esac), selected row now \"$sel_n\""
    s1_kq "$S1_FX" restore >/dev/null 2>&1
    pn_close_panel >/dev/null 2>&1
  done
  crash="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Sesame*' -newer "$marker" 2>/dev/null | head -1)"
  [ -z "$crash" ] || why="${why:+$why; }a crash report appeared: $crash"
  rm -f "$marker"
  printf '%s\n' "$lines" | sed '/^$/d'
  if [ -n "$why" ]; then s1_fail S1.15 "$why"; return 1; fi
  echo "CHECK S1.15 PASS with the selected file deleted, Enter, Command+Enter and Command+C each showed \"That file is no longer there\", dropped the row, selected the next, opened or revealed nothing, left the pasteboard alone, and the app kept running with no crash report"
}
check_S1_15() { s1_run s1_check_15; }

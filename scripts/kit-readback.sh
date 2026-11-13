#!/bin/bash
# kit-readback.sh <mode>: what happened outside Sesame (verify.md, Surfaces and drivers).
#
# It only reads: the frontmost app and its front window's title, Finder's selection, the pasteboard (and
# sets it to a sentinel text, the one thing it writes, so a "nothing changed" check has something to compare),
# Launch Services' default app for an extension, whether an app is installed, and `stat` facts of a file.
# It never posts a key, never opens, moves or changes a file and never closes a window. A picture, when a
# later mode takes one, is of one window by id through `kit-ax.sh shot --app <name>`, never the screen.
#
#   ping finder|preview|quicktime
#                              Automation granted for that app; for Preview
#                              and QuickTime Player the app is opened in the background first, because macOS
#                              only answers while the app runs; the first use may show macOS's own prompt
#   frontmost                  line 1 the frontmost app's name, line 2 `window: <title of its front window>`
#   finder-selection           one POSIX path per line, or `no Finder selection`
#   pasteboard [--set <text>]  prints the pasteboard (`file <path>` for each file URL, `string <text>`); a
#                              pasteboard holding only text prints the text itself. --set puts a text there
#   default-app <ext>          the app Launch Services names for that extension (read the way "Opens in" is)
#   app-installed <bundle id>  the app's path, or `not installed` (exit 1)
#   file-facts <path>          path, size in bytes, local date, modified time and mode from `stat`; a path
#                              that is not absolute is read under the kit's fixtures folder
#   pdf-pages <pdf>            the page count alone (exit 1 for a missing, damaged, locked or empty file)
#   render-pdf-page <pdf> <n> [--out <png>]
#                              a PNG of page n at the fixed scale (the output says `scale <s>`; the PNG is the page size in
#                              points times that scale); with no --out the file is under $KIT_ROOT/run/render; n out of
#                              range is exit 1
#   mark-check <shot> <pdf> <page> [--answers <csv>]
#                              finds the page's picture inside the shot (a pane or window picture: any scale, any offset),
#                              takes the contiguous coloured region that the unmarked render does not hold and compares it
#                              with the `box=x:y:w:h` (points, origin bottom left) of the key's row for that file and page
#                              (default key: the project's fixtures/answers.csv). Prints box, match, pixels, region, inside
#                              and overlap and writes compare-s3-mark.txt; exit 0 the mark is on the passage, 1 no mark (fewer
#                              than 200 coloured pixels) or a mark that misses it, 4 the shot holds no picture of that page
#   preview-page [--tree-sample <file>] [--by-picture --from <png> --pdf <file>]
#                              the page Preview shows. The tree reading (default, and the preferred one) reads through System
#                              Events, first the name of every Preview window (`lease-2024.pdf – Page 7 of 12`, also
#                              `(Page 7 of 12)`) and, only when no window name holds a page, Preview's accessibility tree (a page
#                              field `7 of 12`, a selected thumbnail `Page 7`); it prints `page 7 via tree`; exit 4 `tree lacks the
#                              page` when it names none or two (two windows with different pages is never a guess). A page in a
#                              window name decides over the tree. --tree-sample reads a hand-written dump instead of Preview
#                              (test-only). --by-picture
#                              takes a picture of Preview's front window (kit-ax.sh shot --app Preview; --from reads a given
#                              picture instead, test-only) and matches it against every page of --pdf: `page <n> via picture`,
#                              or exit 3 NEEDS A PERSON for a tie or a match below the bar. readback-preview.txt says which
#                              reading decided.
#   waveform-check <pane-shot> <audio> <start-s>
#                              (plan 5, S4.2) the bars drawn in the pane's picture against the 30 s blocks (5 s steps) of the known clip's own
#                              loudness, a value a second: passes when the best block starts within 2 s of <start-s>, its correlation is at
#                              least 0.70 and it beats the blocks 30 s earlier and later; prints best, earlier and later and writes
#                              compare-s4-waveform.txt; exit 1 a blank, flat or wrong picture, 4 no readable picture
#   quicktime-time [--from <file>]
#                              (plan 5, S4.5) pauses QuickTime Player's front document and prints `document <name>` and `time <seconds>`;
#                              --from reads a hand-written reply instead (test-only); exit 3 when macOS refuses the Apple Event, 1 no document
#   speech-assets [--from <file>]
#                              (plan 5, S4.2, S4.8) `speech-assets true <locale>` when the system language has on-device recognition, else
#                              NEEDS A PERSON (exit 3); --from reads a hand-written answer (test-only)
# Exit codes: 0 done; 1 nothing found or the driver errored; 2 usage; 3 NEEDS A PERSON; 4 not valid (rerun, never a pass).
. "$(dirname "$0")/kit-lib/common.sh"

usage() {
  cat >&2 <<'EOF'
usage: kit-readback.sh ping finder|preview|quicktime
       kit-readback.sh frontmost
       kit-readback.sh finder-selection
       kit-readback.sh pasteboard [--set <text>]
       kit-readback.sh default-app <ext>
       kit-readback.sh app-installed <bundle id>
       kit-readback.sh file-facts <path>
       kit-readback.sh pdf-pages <pdf>
       kit-readback.sh render-pdf-page <pdf> <n> [--out <png>]
       kit-readback.sh mark-check <shot> <pdf> <page> [--answers <csv>]
       kit-readback.sh preview-page [--tree-sample <file>] [--by-picture --from <png> --pdf <file>]
       kit-readback.sh waveform-check <pane-shot> <audio> <start-s>
       kit-readback.sh quicktime-time [--from <file>]
       kit-readback.sh speech-assets [--from <file>]
       kit-readback.sh frame-check <pane-shot> <video> <second>
EOF
}

TERMINAL="${TERM_PROGRAM:-the terminal app that runs the checks}"

rb_tool() {
  local bin
  bin="$(kit_tool readback)" || { echo "the kit's Swift tool readback did not compile; see $KIT_ROOT/run/bin/readback.log"; return 1; }
  printf '%s' "$bin"
}

# ---- ping ------------------------------------------------------------------------------------

# ping_automation <label> <bundle id> <app name to open, or empty when the app always runs>
# The answer is a real Apple Event (what a later check sends): the first one makes macOS ask the person, and
# waits up to 30 s for the answer. A permission question put by another process (a compiled tool) can read
# differently from the terminal's own, so it is not used here.
ping_automation() {
  local label="$1" bid="$2" opener="$3" errf err rc i
  [ -z "$opener" ] || open -g -a "$opener" >/dev/null 2>&1
  errf="$(mktemp "$KIT_TMP/kit-rb-err.XXXXXX")" || return 1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    osascript -e 'with timeout of 30 seconds' -e "tell application id \"$bid\" to get name" -e 'end timeout' >/dev/null 2>"$errf"; rc=$?
    err="$(cat "$errf")"
    # -600: the app is not running yet (it was just opened)
    case "$err" in *"-600"*) sleep 1; continue ;; esac
    break
  done
  rm -f "$errf"
  if [ "$rc" = 0 ]; then
    echo "OK ping $label: Automation for $label granted"
    return 0
  fi
  case "$err" in
    *"-1743"*|*"Not authorized"*)
      echo "NEEDS A PERSON: Automation for $label (macOS refused the Apple Event)"
      echo "how: System Settings, Privacy and Security, Automation, allow $TERMINAL to control $label"
      return 3 ;;
    *"-1712"*|*"timed out"*)
      echo "NEEDS A PERSON: Automation for $label (the macOS Allow prompt was not answered within 30 s)"
      echo "how: run this again and press Allow, or System Settings, Privacy and Security, Automation, allow $TERMINAL to control $label"
      return 3 ;;
  esac
  echo "ping $label: no answer (${err##*execution error: })"
  return 1
}

cmd_ping() {
  [ $# = 1 ] || { usage; return 2; }
  case "$1" in
    finder) ping_automation Finder com.apple.finder "" ;;
    preview) ping_automation Preview com.apple.Preview Preview ;;
    quicktime) ping_automation "QuickTime Player" com.apple.QuickTimePlayerX "QuickTime Player" ;;
    *) usage; return 2 ;;
  esac
}

# ---- frontmost, Finder, pasteboard -------------------------------------------------------------

# osa_rb <script lines...>: runs AppleScript lines; OSA_OUT holds the output. Status 0, 3 (printed) or 1 (printed).
OSA_OUT=""
osa_rb() {
  local args=() l errf rc err
  for l in "$@"; do args+=(-e "$l"); done
  errf="$(mktemp "$KIT_TMP/kit-rb-err.XXXXXX")" || return 1
  OSA_OUT="$(osascript "${args[@]}" 2>"$errf")"; rc=$?
  err="$(cat "$errf")"; rm -f "$errf"
  [ "$rc" = 0 ] && return 0
  case "$err" in
    *"-1743"*|*"Not authorized to send Apple events"*)
      echo "NEEDS A PERSON: Automation for ${OSA_APP:-the app}"
      echo "how: System Settings, Privacy and Security, Automation, allow $TERMINAL to control ${OSA_APP:-the app}"
      return 3 ;;
    *"-25211"*|*"-25204"*|*"assistive access"*)
      echo "NEEDS A PERSON: Accessibility for this terminal"
      echo "how: System Settings, Privacy and Security, Accessibility, turn on $TERMINAL"
      return 3 ;;
  esac
  case "$err" in
    *"-1712"*) echo "could not read: ${OSA_APP:-the app} did not answer within 15 s (AppleEvent timed out)"; return 1 ;;
  esac
  echo "could not read: ${err##*execution error: }"
  return 1
}

cmd_frontmost() {
  [ $# = 0 ] || { usage; return 2; }
  local rc name title
  OSA_APP="System Events"
  osa_rb 'tell application "System Events"' \
    'set p to first application process whose frontmost is true' \
    'set t to ""' \
    'try' \
    'set t to name of window 1 of p' \
    'end try' \
    'if t is missing value then set t to ""' \
    'return (name of p) & linefeed & t' \
    'end tell'; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  name="$(printf '%s\n' "$OSA_OUT" | sed -n 1p)"
  title="$(printf '%s\n' "$OSA_OUT" | sed -n 2p)"
  printf '%s\n' "$name"
  printf 'window: %s\n' "$title"
}

cmd_finder_selection() {
  [ $# = 0 ] || { usage; return 2; }
  local rc
  OSA_APP="Finder"
  osa_rb 'with timeout of 15 seconds' \
    'tell application "Finder"' \
    'set out to ""' \
    'repeat with i in (get selection)' \
    'set out to out & POSIX path of (i as alias) & linefeed' \
    'end repeat' \
    'return out' \
    'end tell' \
    'end timeout'; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if [ -z "$OSA_OUT" ]; then echo "no Finder selection"; return 0; fi
  printf '%s\n' "$OSA_OUT"
}

cmd_pasteboard() {
  local bin
  case "${1:-}" in
    --set)
      [ $# = 2 ] || { usage; return 2; }
      printf '%s' "$2" | pbcopy || { echo "could not set the pasteboard"; return 1; }
      echo "pasteboard set: $(printf '%s' "$2" | wc -m | tr -d ' ') characters"
      return 0 ;;
    "") ;;
    *) usage; return 2 ;;
  esac
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  "$bin" pasteboard
}

# ---- Launch Services, installed apps, stat ------------------------------------------------------

cmd_default_app() {
  [ $# = 1 ] && [ -n "$1" ] || { usage; return 2; }
  local bin
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  "$bin" default-app "$1"
}

cmd_app_installed() {
  [ $# = 1 ] && [ -n "$1" ] || { usage; return 2; }
  local bin out
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  out="$("$bin" app-installed "$1" 2>/dev/null)" || { echo "not installed"; return 1; }
  printf '%s\n' "$out"
}

cmd_file_facts() {
  [ $# = 1 ] && [ -n "$1" ] || { usage; return 2; }
  local p="$1"
  case "$p" in
    /*) ;;
    *) p="$KIT_ROOT/fixtures/$p" ;;
  esac
  if [ ! -f "$p" ]; then echo "no such file: $p"; return 1; fi
  echo "path $p"
  echo "size $(stat -f %z "$p")"
  echo "date $(stat -f %Sm -t %Y-%m-%d "$p")"
  echo "time $(stat -f %Sm -t '%Y-%m-%d %H:%M:%S' "$p")"
  echo "mode 0$(stat -f %Lp "$p")"
}

# ---- PDF pages, pictures and Preview's page ----------------------------------------------------

# rb_path <file> : an absolute path as it is; any other is read under the kit's fixtures folder (as file-facts does).
rb_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s' "$KIT_ROOT/fixtures/$1" ;;
  esac
}

# rb_outdir : where compare-s3-mark.txt and readback-preview.txt go: the evidence folder, else the run folder.
rb_outdir() {
  local d
  d="$(kit_evidence_dir)"
  [ -n "$d" ] || d="$KIT_ROOT/run"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

cmd_pdf_pages() {
  [ $# = 1 ] && [ -n "$1" ] || { usage; return 2; }
  local bin
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  "$bin" pdf-pages "$(rb_path "$1")"
}

cmd_render_pdf_page() {
  [ $# -ge 2 ] || { usage; return 2; }
  local pdf="$1" n="$2" out="" bin stem
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] && [ -n "$2" ] || { usage; return 2; }; out="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$n" in ""|*[!0-9]*) usage; return 2 ;; esac
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  if [ -z "$out" ]; then
    stem="${pdf##*/}"; stem="${stem%.*}"
    mkdir -p "$KIT_ROOT/run/render" || return 1
    out="$KIT_ROOT/run/render/$stem-p$n.png"
  fi
  "$bin" render-pdf-page "$(rb_path "$pdf")" "$n" "$out"
}

# rb_box <answers csv> <pdf path> <page> : `<row id> <x:y:w:h>` of the row of the key whose file ends the pdf's path (on a folder
# boundary) and whose locator is the page, from the `box=` of its note; nothing when there is none.
rb_box() {
  awk -F, -v want="$2" -v page="$3" '
    NR > 1 && NF == 7 && $4 != "" && $5 == page {
      n = length(want) - length($4)
      if (n >= 0 && substr(want, n + 1) == $4 && (n == 0 || substr(want, n, 1) == "/")) {
        m = split($7, parts, "; ")
        for (i = 1; i <= m; i++) if (substr(parts[i], 1, 4) == "box=") { print $1, substr(parts[i], 5); exit }
      }
    }' "$1"
}

cmd_mark_check() {
  [ $# -ge 3 ] || { usage; return 2; }
  local shot="$1" pdf="$2" page="$3" answers="$KIT_PROJECT/fixtures/answers.csv" bin p row id box out rc dir
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --answers) [ $# -ge 2 ] && [ -n "$2" ] || { usage; return 2; }; answers="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  case "$page" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ -f "$shot" ] || { echo "no such picture: $shot"; return 1; }
  [ -f "$answers" ] || { echo "no such key: $answers"; return 1; }
  p="$(rb_path "$pdf")"
  row="$(rb_box "$answers" "$p" "$page")"
  if [ -z "$row" ]; then
    echo "no box in the key for $pdf page $page ($answers: a row of that file and page with box=x:y:w:h in its note)"
    return 1
  fi
  id="${row%% *}"; box="${row#* }"
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  out="$("$bin" mark-check "$shot" "$p" "$page" "$box" 2>&1)"; rc=$?
  dir="$(rb_outdir)"
  { echo "key row $id"; echo "box ${box//:/ }"; printf '%s\n' "$out"; echo "exit $rc"; } > "$dir/compare-s3-mark.txt"
  echo "box ${box//:/ }"
  printf '%s\n' "$out"
  return $rc
}

# pp_tree_pages : stdin a dump of Preview's tree (the line shape of `kit-ax.sh dump`: `<indent><AXRole> label="..." value="..." [selected]`,
# and `window "<title>"` lines, one per window; a bare window name on a line of its own counts as one too); prints `title <n>` for a
# window name that says `Page n of m` (also `(Page n of m)`), `field <n>` for a page field or an element label that does and `thumb <n>`
# for a selected element labelled `Page n`.
pp_tree_pages() {
  awk '
    function firstnum(t) { if (match(t, /[0-9]+/)) return substr(t, RSTART, RLENGTH); return "" }
    {
      line = $0
      if (line ~ /^window "/ || line ~ /^[^ \t]/) {
        if (match(line, /[Pp]age [0-9]+ of [0-9]+/)) {
          seg = substr(line, RSTART + 5, RLENGTH - 5); print "title " firstnum(seg)
        }
      } else if (match(line, /[Pp]age [0-9]+ of [0-9]+/)) {
        seg = substr(line, RSTART + 5, RLENGTH - 5); print "field " firstnum(seg)
      } else if (match(line, /(value|label)="[0-9]+ of [0-9]+"/)) {
        seg = substr(line, RSTART, RLENGTH); sub(/^[a-z]+="/, "", seg); print "field " firstnum(seg)
      }
      if (index(line, "[selected]") && match(line, /label="Page [0-9]+"/)) {
        seg = substr(line, RSTART, RLENGTH); sub(/^label="Page /, "", seg); print "thumb " firstnum(seg)
      }
    }'
}

# pp_live_titles : the name of every Preview window, one `window "<name>"` line each, through System Events (Preview prints the page
# in its window name: `lease-2024.pdf – Page 1 of 12`). Every property read is inside a try. Status 0 and the lines on stdout;
# 3 NEEDS A PERSON (printed); 1 and one line.
pp_live_titles() {
  local rc
  OSA_APP="System Events"
  osa_rb 'with timeout of 20 seconds' \
    'tell application "System Events"' \
    'if not (exists process "Preview") then return "no Preview process"' \
    'tell process "Preview"' \
    'set out to ""' \
    'repeat with w in windows' \
    'try' \
    'set t to name of w' \
    'if t is not missing value then set out to out & "window \"" & (t as text) & "\"" & linefeed' \
    'end try' \
    'end repeat' \
    'if out is "" then return "no Preview window"' \
    'return out' \
    'end tell' \
    'end tell' \
    'end timeout'; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$OSA_OUT"
}

# pp_live_tree : Preview's front window as text, through System Events (the first use may show macOS's own Automation prompt).
# Every property read of an element is inside a try: an element with no text role made `role of e` fail with -1700 live.
# Status 0 and the dump on stdout; 3 NEEDS A PERSON (printed); 1 and one line.
pp_live_tree() {
  local rc
  OSA_APP="System Events"
  osa_rb 'with timeout of 20 seconds' \
    'tell application "System Events"' \
    'if not (exists process "Preview") then return "no Preview process"' \
    'tell process "Preview"' \
    'if (count of windows) is 0 then return "no Preview window"' \
    'set w to window 1' \
    'set wn to ""' \
    'try' \
    'set t to name of w' \
    'if t is not missing value then set wn to t as text' \
    'end try' \
    'set out to "window \"" & wn & "\"" & linefeed' \
    'repeat with e in (entire contents of w)' \
    'set ln to "  "' \
    'try' \
    'set r to role of e' \
    'if r is not missing value then set ln to "  " & (r as text)' \
    'end try' \
    'set lab to ""' \
    'try' \
    'set t to title of e' \
    'if t is not missing value then set lab to t as text' \
    'end try' \
    'if lab is "" then' \
    'try' \
    'set t to description of e' \
    'if t is not missing value then set lab to t as text' \
    'end try' \
    'end if' \
    'if lab is not "" then set ln to ln & " label=\"" & lab & "\""' \
    'try' \
    'set v to value of e' \
    'if v is not missing value then set ln to ln & " value=\"" & (v as text) & "\""' \
    'end try' \
    'try' \
    'if (selected of e) is true then set ln to ln & " [selected]"' \
    'end try' \
    'set out to out & ln & linefeed' \
    'end repeat' \
    'return out' \
    'end tell' \
    'end tell' \
    'end timeout'; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$OSA_OUT"
}

# pp_live_shot : a picture of Preview's front window (one window by id, never the screen); prints its path.
pp_live_shot() {
  local out rc path
  out="$(KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-ax.sh" shot preview-page --app Preview 2>&1)"; rc=$?
  if [ $rc = 3 ]; then printf '%s\n' "$out"; return 3; fi
  if [ $rc != 0 ]; then printf '%s\n' "$out"; return 1; fi
  path="$(printf '%s\n' "$out" | sed -n 's/^saved \(.*\) (Preview window [0-9]*)$/\1/p' | head -1)"
  [ -n "$path" ] && [ -f "$path" ] || { echo "kit-ax.sh shot said no picture of Preview's window: $(printf '%s\n' "$out" | tail -1)"; return 1; }
  printf '%s\n' "$path"
}

cmd_preview_page() {
  local sample="" bypic=0 from="" pdf="" dump tree rc pages titles how n out dir bin p shot
  while [ $# -gt 0 ]; do
    case "$1" in
      --tree-sample) [ $# -ge 2 ] && [ -f "$2" ] || { usage; return 2; }; sample="$2"; shift 2 ;;
      --by-picture) bypic=1; shift ;;
      --from) [ $# -ge 2 ] && [ -f "$2" ] || { usage; return 2; }; from="$2"; shift 2 ;;
      --pdf) [ $# -ge 2 ] && [ -n "$2" ] || { usage; return 2; }; pdf="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  dir="$(rb_outdir)"
  if [ "$bypic" = 1 ]; then
    [ -n "$pdf" ] || { usage; return 2; }
    [ -z "$sample" ] || { usage; return 2; }
    bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
    p="$(rb_path "$pdf")"
    shot="$from"
    if [ -z "$shot" ]; then
      shot="$(pp_live_shot)"; rc=$?
      if [ $rc != 0 ]; then printf '%s\n' "$shot"; return $rc; fi
    fi
    out="$("$bin" page-scores "$shot" "$p" 2>&1)"; rc=$?
    { echo "reading: picture"; echo "picture: $shot"; echo "pdf: $p"; printf '%s\n' "$out"; echo "exit $rc"; } > "$dir/readback-preview.txt"
    printf '%s\n' "$out"
    return $rc
  fi
  [ -z "$from" ] && [ -z "$pdf" ] || { usage; return 2; }
  # the evidence, in this order: the page in a window name (Preview prints `<file> – Page 7 of 12`), then, only when no window name holds
  # a page, the accessibility tree (a page field, a selected thumbnail)
  if [ -n "$sample" ]; then
    dump="$(cat "$sample")"
  else
    dump="$(pp_live_titles)"; rc=$?
    if [ $rc != 0 ]; then printf '%s\n' "$dump"; return $rc; fi
    case "$dump" in
      *"Page "*" of "*|"no Preview"*) ;;
      *)
        tree="$(pp_live_tree)"; rc=$?
        if [ $rc != 0 ]; then printf '%s\n' "$tree"; return $rc; fi
        dump="$dump"$'\n'"$tree" ;;
    esac
  fi
  pages="$(printf '%s\n' "$dump" | pp_tree_pages)"
  titles="$(printf '%s\n' "$pages" | awk 'NF == 2 && $1 == "title" && $2 != "" { print $2 }' | sort -u)"
  n="$(printf '%s\n' "$titles" | awk 'NF { c++ } END { print c + 0 }')"
  how="window title"
  if [ "$n" = 0 ]; then
    titles="$(printf '%s\n' "$pages" | awk 'NF == 2 && $1 != "title" && $2 != "" { print $2 }' | sort -u)"
    n="$(printf '%s\n' "$titles" | awk 'NF { c++ } END { print c + 0 }')"
    how="accessibility tree"
  fi
  if [ "$n" = 1 ]; then
    out="page $titles via tree"
    { echo "reading: tree ($how)"; echo "$out"; } > "$dir/readback-preview.txt"
    echo "$out"
    return 0
  fi
  if [ "$n" = 0 ]; then
    out="tree lacks the page: Preview's accessibility tree names no page (no page in a window title, no page field, no selected thumbnail)"
  else
    out="tree lacks the page: the $how names more than one page ($(printf '%s' "$titles" | tr '\n' ' '))"
  fi
  { echo "reading: tree ($how)"; echo "$out"; } > "$dir/readback-preview.txt"
  echo "$out"
  return 4
}

# ---- waveform-check, quicktime-time, speech-assets (plan 5) -------------------------------------

cmd_waveform_check() {
  [ $# = 3 ] || { usage; return 2; }
  local shot="$1" audio="$2" start="$3" bin out rc dir
  case "$start" in ""|*[!0-9.]*|.*|*.*.*) usage; return 2 ;; esac
  [ -f "$shot" ] || { echo "no readable picture: $shot"; return 4; }
  audio="$(rb_path "$audio")"
  [ -f "$audio" ] || { echo "no such audio file: $audio"; return 1; }
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  out="$("$bin" waveform-check "$shot" "$audio" "$start" 2>&1)"; rc=$?
  dir="$(rb_outdir)"
  { echo "audio $audio"; echo "stated start $start"; printf '%s\n' "$out"; echo "exit $rc"; } > "$dir/compare-s4-waveform.txt"
  printf '%s\n' "$out"
  return $rc
}

cmd_frame_check() {
  [ $# = 3 ] || { usage; return 2; }
  local shot="$1" video="$2" second="$3" bin out rc dir
  case "$second" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ -f "$shot" ] || { echo "no readable picture: $shot"; return 4; }
  video="$(rb_path "$video")"
  [ -f "$video" ] || { echo "no such video file: $video"; return 1; }
  bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
  out="$("$bin" frame-check "$shot" "$video" "$second" 2>&1)"; rc=$?
  dir="$(rb_outdir)"
  { echo "video $video"; echo "stated second $second"; printf '%s\n' "$out"; echo "exit $rc"; } > "$dir/compare-s4-frame.txt"
  printf '%s\n' "$out"
  return $rc
}

# qt_reading <reply> : the reply of the scripting call (`document <name>` and `time <seconds>` lines, or an error); prints the reading.
qt_reading() {
  local doc time
  case "$1" in
    *"-1743"*|*"Not authorized"*|*"not authorized"*)
      echo "NEEDS A PERSON: Automation for QuickTime Player (macOS refused the Apple Event)"
      echo "how: System Settings, Privacy and Security, Automation, allow $TERMINAL to control QuickTime Player"
      return 3 ;;
  esac
  doc="$(printf '%s\n' "$1" | sed -n 's/^document //p' | head -1)"
  time="$(printf '%s\n' "$1" | sed -n 's/^time //p' | head -1)"
  time="${time//,/.}"
  if [ -z "$doc" ] && [ -z "$time" ]; then echo "QuickTime Player has no document open (${1:-no reply})"; return 1; fi
  case "$time" in ""|*[!0-9.]*|.*|*.*.*) echo "the reply holds no time: $1"; return 1 ;; esac
  echo "document $doc"
  printf 'time %.1f\n' "$time"
}

cmd_quicktime_time() {
  local from="" rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] && [ -n "$2" ] || { usage; return 2; }; from="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [ -n "$from" ]; then
    [ -f "$from" ] || { echo "no such reply: $from"; return 1; }
    qt_reading "$(cat "$from")"
    return $?
  fi
  OSA_APP="QuickTime Player"
  osa_rb 'tell application "QuickTime Player"' \
    'if (count of documents) is 0 then return "no document"' \
    'pause front document' \
    'return "document " & (name of front document) & linefeed & "time " & (current time of front document)' \
    'end tell'; rc=$?
  [ $rc = 0 ] || return $rc
  qt_reading "$OSA_OUT"
}

cmd_speech_assets() {
  local from="" line bin
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] && [ -n "$2" ] || { usage; return 2; }; from="$2"; shift 2 ;;
      *) usage; return 2 ;;
    esac
  done
  if [ -n "$from" ]; then
    [ -f "$from" ] || { echo "no such answer: $from"; return 1; }
    line="$(head -1 "$from")"
  else
    bin="$(rb_tool)" || { printf '%s\n' "$bin"; return 1; }
    line="$("$bin" speech-assets 2>&1)"
  fi
  case "$line" in
    "true "*) echo "speech-assets $line"; return 0 ;;
    "false "*)
      echo "NEEDS A PERSON: install that language's on-device dictation (System Settings, Keyboard, Dictation: turn it on for ${line#false } and let it download)"
      return 3 ;;
    *) echo "speech-assets: no answer (${line:-nothing})"; return 1 ;;
  esac
}

# ---- main --------------------------------------------------------------------------------------

main() {
  local mode="${1:-}"
  [ $# -gt 0 ] && shift
  case "$mode" in
    ping) cmd_ping "$@" ;;
    frontmost) cmd_frontmost "$@" ;;
    finder-selection) cmd_finder_selection "$@" ;;
    pasteboard) cmd_pasteboard "$@" ;;
    default-app) cmd_default_app "$@" ;;
    app-installed) cmd_app_installed "$@" ;;
    file-facts) cmd_file_facts "$@" ;;
    pdf-pages) cmd_pdf_pages "$@" ;;
    render-pdf-page) cmd_render_pdf_page "$@" ;;
    mark-check) cmd_mark_check "$@" ;;
    preview-page) cmd_preview_page "$@" ;;
    waveform-check) cmd_waveform_check "$@" ;;
    frame-check) cmd_frame_check "$@" ;;
    quicktime-time) cmd_quicktime_time "$@" ;;
    speech-assets) cmd_speech_assets "$@" ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-readback "$@")" main "$@"
exit $?

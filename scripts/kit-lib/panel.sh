#!/bin/bash
# The panel helpers shared by scripts/kit-search.sh and scripts/kit-lib/checks-s1.sh. Sourced after common.sh,
# never run. bash 3.2 compatible.
#
# Everything here goes through scripts/kit-ax.sh (Kit safety): the shortcut is posted with `hotkey` only
# inside a kit window that this library opens first and closes last (pn_kit_open, pn_kit_close); typing and
# keys go to Sesame only, and only once `kit-ax.sh frontmost` reads Sesame. The panel is read from the
# accessibility tree of the real window: the search box, the result rows and the right pane's texts. No
# product identifier is assumed beyond the roles a list, a text field and static text have (verify.md, guess K4):
# a text field (AXTextField, AXSearchField, AXTextArea or AXComboBox) is the search box; the list is the first
# AXList, AXTable or AXOutline; a row is an AXRow (else a direct child of that list); the pane is every other text.

PN_AX="$KIT_SCRIPTS/kit-ax.sh"
PN_KIT_OPENED=0
PN_OUT=""
PN_DUMP=""
PN_CHORD=""        # a chord to post instead of the shortcut (the planted wrong input of a check); KIT_PANEL_CHORD does the same

pn_ax() { KIT_NO_EVIDENCE=1 "$PN_AX" "$@"; }

# pn_probe <app> <kit-ax.sh args...> : a read through System Events (frontmost, read, dump) under the hard limit
# of every Apple Event or accessibility probe (kit_timeout, 10 s). An app that does not answer prints
# `NEEDS A PERSON: <app> did not answer Apple Events within 10 s, restart it` and the status is 3: never a hang.
# PN_TIMEOUT_MSG holds that line after a timeout seen outside a subshell.
PN_TIMEOUT_MSG=""
pn_probe() {
  local app="$1" out rc
  shift
  out="$(KIT_NO_EVIDENCE=1 kit_timeout "$KIT_PROBE_TIMEOUT" "$PN_AX" "$@" 2>&1)"; rc=$?
  if [ $rc = 124 ]; then
    echo "NEEDS A PERSON: $app did not answer Apple Events within $KIT_PROBE_TIMEOUT s, restart it"
    return 3
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return $rc
}

# ---- the kit window that every shortcut post sits inside ------------------------------------------

# pn_kit_open : the kit window open and frontmost (it is raised when already open). Status of kit-ax.sh;
# the output is in PN_OUT.
pn_kit_open() {
  local rc
  PN_KIT_OPENED=1
  PN_OUT="$(pn_ax kitwindow open 2>&1)"; rc=$?
  return $rc
}

# pn_kit_close : closes the kit window; prints nothing. It always runs the close (a window opened inside a
# subshell is not known to this shell), and a close with no window open does nothing.
pn_kit_close() {
  pn_ax kitwindow close >/dev/null 2>&1
  PN_KIT_OPENED=0
  return 0
}

# ---- opening and closing the panel -----------------------------------------------------------------

# pn_panel_exists : status 0 when `read panel` answers. A probe that times out is not "no panel": its line is kept
# in PN_TIMEOUT_MSG and the status is 1.
pn_panel_exists() {
  local out rc
  PN_TIMEOUT_MSG=""
  out="$(pn_probe Sesame read panel)"; rc=$?
  [ $rc = 3 ] && PN_TIMEOUT_MSG="$out"
  [ $rc = 0 ]
}

pn_wait_panel() { # pn_wait_panel present|gone [tries] : polls `read panel` every 0.25 s
  local want="$1" n="${2:-12}" i
  for ((i = 0; i < n; i++)); do
    if pn_panel_exists; then [ "$want" = present ] && return 0; else
      [ -n "$PN_TIMEOUT_MSG" ] && return 1
      [ "$want" = gone ] && return 0
    fi
    sleep 0.25
  done
  return 1
}

# pn_hotkey [combo] : posts the shortcut (or the combo) with the kit window frontmost. PN_OUT holds the output.
pn_hotkey() {
  local rc
  pn_kit_open; rc=$?
  [ $rc = 0 ] || { return $rc; }
  if [ -n "$1" ]; then PN_OUT="$(pn_ax hotkey "$1" 2>&1)"; rc=$?; else PN_OUT="$(pn_ax hotkey 2>&1)"; rc=$?; fi
  return $rc
}

# pn_open_panel : a fresh open of the panel with the shortcut. A panel left open is closed first. With
# PN_CHORD set that chord is posted instead of the shortcut. Status 0 the panel is on screen; 3 a person-step;
# 1 no panel (PN_OUT says why).
pn_open_panel() {
  local rc chord="${PN_CHORD:-$KIT_PANEL_CHORD}"
  pn_kit_open; rc=$?
  if [ $rc != 0 ]; then printf '%s\n' "$PN_OUT"; PN_OUT="the kit window did not open: $PN_OUT"; return $rc; fi
  if pn_panel_exists; then
    pn_close_panel >/dev/null 2>&1
  fi
  PN_TIMEOUT_MSG=""
  pn_hotkey "$chord"; rc=$?
  if [ $rc != 0 ]; then return $rc; fi
  if ! pn_wait_panel present 12; then
    if [ -n "$PN_TIMEOUT_MSG" ]; then PN_OUT="$PN_TIMEOUT_MSG"; return 3; fi
    PN_OUT="no Sesame panel after the shortcut${chord:+ ($chord was posted instead)}: $(printf '%s' "$PN_OUT" | tr '\n' ' ')"
    return 1
  fi
  return 0
}

# pn_close_panel : closes an open panel with the shortcut, the kit window being frontmost. A panel that went by
# itself when the kit window took the front is left closed (a second shortcut would open it again).
pn_close_panel() {
  local rc
  pn_panel_exists || return 0
  pn_kit_open; rc=$?
  [ $rc = 0 ] || return $rc
  sleep 0.3
  pn_panel_exists || return 0
  # With PN_CHORD set (S1.27: the shortcut was changed) the panel is closed with that chord, the one in force.
  if [ -n "$PN_CHORD" ]; then pn_ax hotkey "$PN_CHORD" >/dev/null 2>&1; else pn_ax hotkey >/dev/null 2>&1; fi
  pn_wait_panel gone 12
}

# pn_front : the frontmost app's name.
pn_front() { pn_probe "System Events" frontmost | sed -n 1p; }

# pn_wait_sesame_front [seconds] : status 0 once Sesame is frontmost.
pn_wait_sesame_front() {
  local n="${1:-3}" i name=""
  for ((i = 0; i < n * 4; i++)); do
    name="$(pn_front)"
    [ "$name" = Sesame ] && return 0
    sleep 0.25
  done
  PN_OUT="the frontmost app is $name, not Sesame"
  return 1
}

# ---- reading the panel ---------------------------------------------------------------------------------

# pn_dump : PN_DUMP holds `kit-ax.sh dump panel`. Status of kit-ax.sh.
pn_dump() {
  PN_DUMP="$(pn_probe Sesame dump panel)"
  return $?
}

# pn_elements : stdin the dump, stdout "depth<TAB>role<TAB>label<TAB>value<TAB>flags" per element (flags: F focused,
# S selected, D disabled).
pn_elements() {
  awk '
  function grab(s, key,    i, rest, n, ch, j) {
    i = index(s, " " key "=\"")
    if (i == 0) return ""
    rest = substr(s, i + length(key) + 3)
    n = length(rest)
    for (j = 1; j <= n; j++) {
      if (substr(rest, j, 1) == "\"") {
        ch = substr(rest, j + 1, 1)
        if (ch == "" || ch == " ") return substr(rest, 1, j - 1)
      }
    }
    return rest
  }
  /^ *AX[A-Za-z]/ {
    line = $0
    ind = match(line, /[^ ]/) - 1
    body = substr(line, ind + 1)
    sp = index(body, " ")
    role = (sp ? substr(body, 1, sp - 1) : body)
    rest = (sp ? substr(body, sp) : "")
    label = grab(rest, "label")
    tail = rest
    k = 0
    for (j = length(rest); j >= 1; j--) if (substr(rest, j, 1) == "\"") { k = j; break }
    if (k > 0) tail = substr(rest, k + 1)
    vi = index(rest, " value=\"")
    if (vi > 0 && k > vi + 8) val = substr(rest, vi + 8, k - (vi + 8))
    else val = grab(rest, "value")
    gsub(/\t/, "\035", val)
    fl = ""
    if (index(tail, "[focused]")) fl = fl "F"
    if (index(tail, "[selected]")) fl = fl "S"
    if (index(tail, "[disabled]")) fl = fl "D"
    printf "%d\t%s\t%s\t%s\t%s\n", ind / 2, role, label, val, fl
  }'
}

# pn_size : "<w> <h>" of the panel window from the dump header; nothing when there is none.
pn_size() {
  printf '%s\n' "$PN_DUMP" | awk '/^window [0-9]+ x [0-9]+ at / { print $2, $4; exit }'
}

# pn_searchbox : "label<TAB>value<TAB>focused 0|1" of the search box; status 1 and no output when there is none.
pn_searchbox() {
  local out
  out="$(printf '%s\n' "$PN_DUMP" | pn_elements | awk -F'\t' '
    { r = $2; sub(/\/.*/, "", r) }
    r == "AXTextField" || r == "AXSearchField" || r == "AXTextArea" || r == "AXComboBox" {
      printf "%s\t%s\t%d\n", $3, $4, (index($5, "F") ? 1 : 0); found = 1; exit }
    END { exit found ? 0 : 1 }')" || return 1
  printf '%s\n' "$out"
}

# pn_rows : one line per result row, "<n><TAB>selected|-<TAB><texts joined by ' | '>".
pn_rows() {
  local elements fb
  elements="$(printf '%s\n' "$PN_DUMP" | pn_elements)"
  fb="$(printf '%s\n' "$elements" | awk -F'\t' '$2 ~ /^AXRow/ { n++ } END { print n + 0 }')"
  printf '%s\n' "$elements" | awk -F'\t' -v fb="$fb" '
  function flush() {
    if (inrow) { n++; printf "%d\t%s\t%s\n", n, (sel ? "selected" : "-"), txt; inrow = 0 }
  }
  BEGIN { n = 0; inrow = 0; listd = -1 }
  {
    d = $1 + 0; r = $2; sub(/\/.*/, "", r)
    if (inrow && d <= rowd) flush()
    if (listd < 0 && (r == "AXList" || r == "AXTable" || r == "AXOutline")) { listd = d; next }
    start = 0
    if (fb > 0) { if (r == "AXRow") start = 1 }
    else if (listd >= 0 && d == listd + 1 && r != "AXScrollBar" && r != "AXColumn") start = 1
    if (start) {
      inrow = 1; rowd = d; sel = (index($5, "S") ? 1 : 0); txt = ""
    }
    if (inrow) {
      t = ($3 != "" ? $3 : $4)
      if (t != "" && t != last) { txt = (txt == "" ? t : txt " | " t); last = t }
      if (index($5, "S")) sel = 1
    }
  }
  END { flush() }'
}

# pn_pane : the texts that are neither in the result list nor the search box, one per line. A text area of the pane (the code
# passage, its "Line numbers" gutter, a document passage) is its label, then one line for each line of its value (blank lines kept).
pn_pane() {
  printf '%s\n' "$PN_DUMP" | pn_elements | awk -F'\t' '
  BEGIN { inlist = 0; listd = -1; box = 0 }
  {
    d = $1 + 0; r = $2; sub(/\/.*/, "", r)
    if (inlist && d <= listd) inlist = 0
    if (!inlist && listd < 0 && (r == "AXList" || r == "AXTable" || r == "AXOutline")) { inlist = 1; listd = d; next }
    if (inlist) next
    if (r == "AXTextField" || r == "AXSearchField" || r == "AXTextArea" || r == "AXComboBox") {
      if (!box) { box = 1; next }
      if (r != "AXTextArea") next
      if ($3 != "") print $3
      n = split($4, piece, "\037")
      for (i = 1; i <= n; i++) { gsub(/\035/, "\t", piece[i]); print piece[i] }
      last = ""
      next
    }
    if (r == "AXWindow" || r == "AXScrollArea" || r == "AXSplitGroup") next
    t = ($3 != "" ? $3 : $4)
    if (t != "" && t != last) { print t; last = t }
  }'
}

# pn_row_name <row text> : the file name in a row's text (a word that ends in a photo extension), or nothing.
pn_row_name() {
  printf '%s\n' "$1" | tr ' |' '\n\n' | awk 'tolower($0) ~ /\.(jpe?g|png|heic|webp|tiff?|gif)$/ { print; exit }'
}

# pn_wait_list [seconds] : polls the dump until the rows and the pane have not changed for three reads in a row
# (about a second) and no "Searching" line shows; the list is then the ranked one. PN_DUMP holds the settled dump.
# Status 0 settled, 4 it did not settle (a run that is not valid).
pn_wait_list() {
  local max="${1:-20}" start now sig last="" same=0 first="" budget
  start="$(date +%s)"
  while :; do
    pn_dump
    now="$(date +%s)"
    if [ -z "$first" ]; then first=$((now - start)); budget=$((max + 4 * first)); fi
    sig="$(pn_rows | cksum)$(pn_pane | cksum)"
    case "$PN_DUMP" in
      *"NEEDS A PERSON"*|*[Ss]earching*) same=0 ;;
      *) if [ "$sig" = "$last" ]; then same=$((same + 1)); else same=0; fi ;;
    esac
    last="$sig"
    [ "$same" -ge 2 ] && return 0
    if [ $((now - start)) -ge "$budget" ]; then
      case "$PN_DUMP" in *[Ss]earching*) sig="a Searching line shows" ;; *) sig="no Searching line" ;; esac
      echo "  | unsettled after $budget s, last dump ($sig):"
      pn_rows | head -15 | sed 's/^/  | unsettled row: /'
      pn_pane | head -12 | sed 's/^/  | unsettled pane: /'
      return 4
    fi
    sleep 0.2
  done
}

# pn_listed <name or path> : status 0 when a row's text holds that file name.
pn_listed() {
  local base="${1##*/}"
  pn_rows | awk -F'\t' -v b="$base" 'index($3, b) { found = 1 } END { exit found ? 0 : 1 }'
}

# pn_norm_path <path> : the path without the /private prefix of a /private/var, so both spellings compare equal.
pn_norm_path() {
  case "$1" in
    /private/var/*|/private/tmp/*|/private/etc/*) printf '%s\n' "${1#/private}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

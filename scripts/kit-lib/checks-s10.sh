S10_AX="$KIT_SCRIPTS/kit-ax.sh"
S10_LD="$KIT_SCRIPTS/kit-launch.sh"
S10_MR="$KIT_SCRIPTS/kit-mirror.sh"
S10_SR="$KIT_SCRIPTS/kit-search.sh"
S10_IX="$KIT_SCRIPTS/kit-index.sh"
S10_CS="$KIT_SCRIPTS/check-static.sh"
S10_SECTIONS="Folders|File types|Search|Indexing"
S10_KINDS="Photos|PDFs|Documents|Audio|Video"
S10_FOLDERS_TITLE="Folders Sesame reads"
S10_FOLDERS_NOTE="Tick a folder to read it. Use the more button on a row to re-index or remove it."
S10_ID=""
S10_DIR=""
S10_OUT=""
S10_CUT=""
S10_PNG=""
S10_PERSON=""
S10_PLANT_FN=""
S10_COMBO=""
S10_LOCKED=""
S10_LONGDIR=""
S10_PLACES=""
S10_STARTED=""
S10_HINT_START="Indexing starts when you press Start indexing, and runs in the background."
S10_HINT_TICK="Tick at least one folder to start."
S10_RUNNING="Indexing is running. Watch it from the magnifier in the menu bar."

s10_ua_state() {
  local ic rt
  ic="$(defaults read com.apple.universalaccess increaseContrast 2>/dev/null)"
  rt="$(defaults read com.apple.universalaccess reduceTransparency 2>/dev/null)"
  echo "${ic:-0} ${rt:-0}"
}

s10_luma() {
  local lbin val
  lbin="$(kit_tool lumastat)" || return 1
  val="$("$lbin" "$1" $NR_ROW 2>&1)" || return 1
  printf '%s\n' "$val" | awk '{ print $2 }'
}

s10_rerun() {
  echo "RERUN $1 not valid: $2"
  S6_RC=4
  return 1
}

s10_person() { S10_PERSON="${S10_PERSON:+$S10_PERSON; }$1"; }

s10_done() {
  if [ -n "$S6_WHY" ]; then s6_fail "$1" "$S6_WHY"; return 1; fi
  if [ -n "$S10_PERSON" ]; then echo "CHECK $1 NEEDS-A-PERSON $S10_PERSON"; return 0; fi
  echo "CHECK $1 PASS $2"
  return 0
}

s10_undo() {
  [ -z "$S10_LOCKED" ] || chmod u+w "$S10_LOCKED" 2>/dev/null
  S10_LOCKED=""
  return 0
}

s10_run() {
  local rc
  S10_ID=""; S10_CUT=""; S10_PERSON=""; S10_PLANT_FN=""; S10_COMBO=""; S10_LOCKED=""; S10_PLACES=""; S10_STARTED=""
  S10_DIR="$(mktemp -d "$KIT_TMP/s10.XXXXXX")"
  s6_run nr_run "$@"; rc=$?
  s10_undo
  rm -rf "$S10_DIR"
  return $rc
}

s10_q() {
  local out rc
  out="$(kq "$@" 2>&1 </dev/null)"; rc=$?
  S10_OUT="$out"
  [ $rc = 0 ] && return 0
  printf '%s\n' "$out" | awk -v p="  | ${1##*/} ${2:-} exited $rc: " '{ print p $0 }'
  return $rc
}

s10_plant_overlap() {
  awk '{ print } !done && /^ *AXStaticText label="/ && / frame=/ { l = $0; sub(/label="[^"]*"/, "label=\"Planted overlap\"", l); print l; done = 1 }'
}

s10_plant_switch() {
  cat
  echo '  AXCheckBox/AXSwitch label="Planted switch" value="1"'
}

s10_plant_extra() {
  cat
  echo '  AXStaticText label="Planted extra label"'
}

s10_plant_nowarning() {
  grep -v 'AXImage label="Warning"'
}

s10_plant_drop() {
  if [ "$S10_COMBO" = "0 0" ] || [ -z "$S10_COMBO" ]; then cat; return 0; fi
  awk '!done && /^ *AXStaticText label="/ { done = 1; next } { print }'
}

s10_dump() {
  local out rc
  out="$(kq kit_timeout 30 "$S10_AX" dump "$2" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | awk -v p="  | kit-ax.sh dump $2 exited $rc: " '{ print p $0 }'
    s10_rerun "$1" "kit-ax.sh dump $2 exited $rc"
    return 1
  fi
  S6_DUMP="$out"
  if [ -n "$KIT_PLANT" ] && [ -n "$S10_PLANT_FN" ]; then S6_DUMP="$(printf '%s\n' "$S6_DUMP" | "$S10_PLANT_FN")"; fi
  S10_CUT="$(printf '%s\n' "$S6_DUMP" | grep -m1 '^(tree cut at ')"
  if [ -n "$S10_CUT" ] && [ "$S10_ID" != S10.9 ]; then
    s10_rerun "$1" "the $2 dump was cut ($S10_CUT): the frames it holds are incomplete"
    return 1
  fi
  return 0
}

s10_read() {
  s10_dump "$1" "$2" || return 1
  if ! printf '%s\n' "$S6_DUMP" | ax_boxes | awk -F'\t' '$5 != "" { f = 1 } END { exit f ? 0 : 1 }'; then
    s10_rerun "$1" "the $2 dump holds no frame field: the kit-ax.sh that was run is not the new one"
    return 1
  fi
  return 0
}

s10_layout() {
  local bad
  bad="$(printf '%s\n' "$S6_DUMP" | ax_overlaps | head -2 | paste -sd';' -)"
  [ -z "$bad" ] || s6_why "$1: frames overlap: $bad"
  bad="$(printf '%s\n' "$S6_DUMP" | ax_outside | head -2 | paste -sd';' -)"
  [ -z "$bad" ] || s6_why "$1: an element is outside its parent: $bad"
  return 0
}

s10_header_size() {
  printf '%s\n' "$S6_DUMP" | awk '/^window [0-9]+ x [0-9]+ at / { print $2 " x " $4; exit }'
}

s10_look() {
  local out rc
  out="$(kq "$S10_AX" appearance "$2" --keep 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc = 3 ]; then echo "CHECK $1 NEEDS-A-PERSON $(s6_pick "$out")"; S6_RC=0; return 1; fi
  if [ $rc != 0 ]; then s10_rerun "$1" "the system look could not be set to $2: $(s6_last "$out")"; return 1; fi
  sleep "${S10_SETTLE:-1}"
  return 0
}

s10_shot() {
  local out rc
  out="$(kq "$S10_AX" shot "$2" ${3:+"$3"} 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc = 3 ]; then echo "CHECK $1 NEEDS-A-PERSON $(s6_pick "$out")"; S6_RC=0; return 1; fi
  if [ $rc != 0 ]; then s10_rerun "$1" "no picture ($2): $(s6_last "$out")"; return 1; fi
  S10_PNG="$(printf '%s\n' "$out" | sed -n 's/^saved \(.*\) (Sesame window [0-9]*)$/\1/p' | sed -n 1p)"
  return 0
}

s10_panel() {
  local rc
  pn_open_panel; rc=$?
  if [ $rc = 3 ]; then echo "CHECK $1 NEEDS-A-PERSON $(printf '%s\n' "$PN_OUT" | sed -n 1p)"; S6_RC=0; return 1; fi
  if [ $rc != 0 ]; then
    printf '%s\n' "$PN_OUT" | sed 's/^/  | /'
    s10_rerun "$1" "the panel did not open: $(printf '%s' "$PN_OUT" | sed -n 1p)"
    return 1
  fi
  return 0
}

s10_search() {
  s10_q "$S10_SR" "$2" --keep-open || { s10_rerun "$1" "kit-search.sh \"$2\" failed: $(s6_last "$S10_OUT")"; return 1; }
  return 0
}

s10_press() {
  s6_press "$S10_AX" "$2" && return 0
  s10_rerun "$1" "pressing $2 failed"
  return 1
}

s10_forward() {
  local b=Next
  if [ "$2" = 2 ]; then
    s10_dump "$1" setup || return 1
    printf '%s\n' "$S6_DUMP" | ax_has_label Next || b="Not now"
  fi
  s10_press "$1" "$b"
}

s10_golden_state() {
  local out rc
  out="$(golden_need 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe golden: /'
  [ $rc = 0 ] || { s10_rerun "$1" "recipe golden: $(s6_pick "$out")"; return 1; }
  return 0
}

s10_setup_state() {
  local out rc
  out="$(recipe_setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  [ $rc = 0 ] || { s10_rerun "$1" "recipe setup: $(s6_pick "$out")"; return 1; }
  return 0
}

s10_settings_open() {
  local out rc
  out="$(settings_open 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc = 3 ]; then echo "CHECK $1 NEEDS-A-PERSON $(s6_pick "$out")"; S6_RC=0; else s10_rerun "$1" "the Settings window did not open: $(s6_last "$out")"; fi
    return 1
  fi
  return 0
}

s10_section() {
  local msg
  msg="$(settings_section "$2")" || {
    printf '%s\n' "$msg" | sed 's/^/  | /'
    s10_rerun "$1" "the $2 section of Settings did not open"
    return 1
  }
  return 0
}

s10_step_name() {
  case "$1" in 1) echo Welcome ;; 2) echo Folders ;; 3) echo Permissions ;; *) echo Shortcut ;; esac
}

s10_step() {
  local id="$1" n="$2" mode="$3" name i found primary
  name="$(s10_step_name "$n")"
  for ((i = 0; i < 4; i++)); do
    "s10_$mode" "$id" setup || return 1
    if printf '%s\n' "$S6_DUMP" | ax_has_label "Step $n of 4: $name"; then return 0; fi
    sleep "${S10_SETTLE:-1}"
  done
  found="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' -v w="Step $n of 4" 'index($3, w) == 1 { print $3; exit }')"
  if [ -n "$found" ]; then
    s6_why "W4 (step $n): the progress dots are titled \"$found\", not \"Step $n of 4: $name\""
    return 0
  fi
  primary=Next; [ "$n" = 4 ] && primary=Finish
  if [ "$n" = 2 ] && ! printf '%s\n' "$S6_DUMP" | ax_frame "$primary" >/dev/null; then primary="Start indexing"; fi
  if ! printf '%s\n' "$S6_DUMP" | ax_has_label_prefix "Step " && printf '%s\n' "$S6_DUMP" | ax_frame "$primary" >/dev/null; then
    s6_why "W4 (step $n): the Setup window holds no progress dots group titled \"Step $n of 4: $name\""
    return 0
  fi
  s10_rerun "$id" "the Setup window shows no \"Step $n of 4: $name\""
  return 1
}

s10_centre() {
  local off rc
  off="$(printf '%s\n' "$S6_DUMP" | ax_centred "$2" "$3" "$4" 8)"; rc=$?
  case $rc in
    0) ;;
    1) s6_why "P2 ($1): \"${2%\*}\" is not centred in its region: $off pt off, at most 8 allowed" ;;
    *) s6_why "P2 ($1): the dump holds no \"${2%\*}\" with a frame" ;;
  esac
  return 0
}

s10_footer_words() {
  local t
  t="$(printf '%s\n' "$S6_DUMP" | ax_boxes | awk -F'\t' '$3 ~ /^AXStaticText/ && $6 != "" && $6 + 0 >= 528 { print $4 }' | grep -iE 'searching|no matches' | head -1)"
  [ -z "$t" ] || s6_why "P10 ($1): the footer holds \"$t\""
  return 0
}

s10_need_rows() {
  local n
  n="$(printf '%s\n' "$S10_OUT" | awk '$1 == "rows" { print $2; exit }')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -ge 1 ] && return 0
  s10_rerun "$1" "the search listed no result row (rows $n): a divider check on an empty list proves nothing"
  return 1
}

s10_need_name() {
  printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' -v w="$2" 'index($3, w) > 0 { f = 1 } END { exit f ? 0 : 1 }' && return 0
  s10_rerun "$1" "the panel dump holds no \"$2\" name: the overlap and ellipsis checks would read nothing"
  return 1
}

s10_panel_states() {
  local look="$1" c
  s10_read S10.1 panel || return 1
  s10_layout "the empty panel ($look)"
  s10_centre "$look empty box" "Describe what you want*" 0 960
  s10_centre "$look empty box" "a dog on the beach" 0 960
  s10_footer_words "$look empty box"
  s10_search S10.1 "a dog on the beach" || return 1
  s10_need_rows S10.1 || return 1
  s10_read S10.1 panel || return 1
  s10_layout "the panel with results ($look)"
  c="$(printf '%s\n' "$S6_DUMP" | ax_crosses 384 58 528 | head -2 | paste -sd';' -)"
  [ -z "$c" ] || s6_why "P1 ($look): text crosses the divider at x = 384: $c"
  s10_footer_words "$look results"
  s10_search S10.1 "qwv zzkx lorp mnb" || return 1
  s10_read S10.1 panel || return 1
  s10_layout "the panel with no match ($look)"
  s10_centre "$look no matches" "No matches" 0 384
  s10_centre "$look no matches" "Describe what is in the file*" 0 384
  if ! printf '%s\n' "$S6_DUMP" | ax_wide "Describe what is in the file*" 320 >/dev/null; then
    s6_why "P3 ($look): the No matches body is wider than 320 pt"
  fi
  s10_footer_words "$look no matches"
  return 0
}

s10_check_1() {
  local look out rc s luma_l="" luma_d="" now
  S10_ID=S10.1
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_overlap
    S6_PLANTED="a text added on top of the first text of every panel dump"
  fi
  out="$(kq "$S10_CS" --quick 2>&1)"; rc=$?
  s="$(printf '%s\n' "$out" | awk '$1 == "STATIC" && $2 == "literal-colours" { print $3; exit }')"
  if [ -z "$s" ]; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    s10_rerun S10.1 "check-static.sh printed no literal-colours rule: $(s6_last "$out")"
    return $S6_RC
  fi
  [ "$s" = PASS ] || s6_why "P7: check-static.sh reports literal colours outside UI/Design.swift: $(printf '%s\n' "$out" | awk 'index($0, "Sources") > 0 { sub(/^ +/, ""); print; exit }')"
  s10_golden_state S10.1 || return $S6_RC
  for look in light dark; do
    s10_look S10.1 "$look" || return $S6_RC
    s10_panel S10.1 || return $S6_RC
    s10_panel_states "$look" || return $S6_RC
    s10_shot S10.1 "s10-1-$look" --panel || return $S6_RC
    now="$(s10_luma "$S10_PNG")" || { s10_rerun S10.1 "the luma of $S10_PNG could not be read"; return $S6_RC; }
    if [ "$look" = light ]; then luma_l="$now"; else luma_d="$now"; fi
    pn_close_panel >/dev/null 2>&1
  done
  if [ "$(awk -v l="$luma_l" -v d="$luma_d" 'BEGIN { print (l - d >= 30) ? 1 : 0 }')" != 1 ]; then
    s6_why "P8: the search-box row reads $luma_l luma in Light and $luma_d in Dark: Dark must be darker by at least 30"
  fi
  s10_person "P3 type size and weight, P4 the search row (icon, field and placeholder on one baseline), P5 the selected row pill, P6 icons at one x and long names, P9 the preview frame and left alignment, and the top edge of each state block at 30 to 45 percent of its region (P2); the states Not ready yet, Searching, search failed (S10.8 reads it) and the indexing banner were not reached here; read the shots shot-s10-1-light and shot-s10-1-dark"
  s10_done S10.1 ""
}
check_S10_1() { s10_run s10_check_1; }

s10_permissions_rules() {
  local look="$1" size="$2" w off rc i f intro note top bottom d missing=""
  local names=(Desktop Documents Downloads "Removable volumes")
  local reasons=("Files on your Desktop" "Files in your Documents folder" "Files in your Downloads folder" "USB drives and external disks")
  local ny=(0 0 0 0) ry=(0 0 0 0) rh=(0 0 0 0)
  intro="$(printf '%s\n' "$S6_DUMP" | ax_frame "macOS asks once*")" || intro=""
  note="$(printf '%s\n' "$S6_DUMP" | ax_frame "Sesame never asks for Full Disk Access*")" || note=""
  [ -n "$intro" ] || missing="the intro line"
  [ -n "$note" ] || missing="${missing:+$missing, }the read note"
  for i in 0 1 2 3; do
    f="$(printf '%s\n' "$S6_DUMP" | ax_frame "${names[$i]}")" || f=""
    if [ -z "$f" ]; then missing="${missing:+$missing, }${names[$i]}"; else set -- $f; ny[$i]=$2; fi
    f="$(printf '%s\n' "$S6_DUMP" | ax_frame "${reasons[$i]}")" || f=""
    if [ -z "$f" ]; then missing="${missing:+$missing, }${reasons[$i]}"; else set -- $f; ry[$i]=$2; rh[$i]=$4; fi
  done
  if [ -n "$missing" ]; then
    s6_why "W13 ($look): the Permissions dump holds no frame for $missing"
  else
    for i in 0 1 2 3; do
      [ "${ry[$i]}" -gt "${ny[$i]}" ] || s6_why "W13 ($look): the name \"${names[$i]}\" is not above its reason"
      [ "$i" = 0 ] || [ "${ny[$i]}" -gt "${ny[$((i - 1))]}" ] || s6_why "W13 ($look): \"${names[$i]}\" is not below \"${names[$((i - 1))]}\""
    done
    set -- $intro
    top=$(( $2 + $4 + 8 ))
    set -- $note
    bottom=$(( $2 - 12 ))
    d=$(( ny[0] - top ))
    [ "$d" -le 24 ] || s6_why "W13 ($look): the first name sits $d pt below the top of the card, at most 24 allowed (no blank block)"
    d=$(( bottom - ry[3] - rh[3] ))
    [ "$d" -le 24 ] || s6_why "W13 ($look): the last reason ends $d pt above the bottom of the card, at most 24 allowed (no blank block)"
  fi
  w="${size%% *}"
  case "$w" in ''|*[!0-9]*) w=560 ;; esac
  off="$(printf '%s\n' "$S6_DUMP" | ax_centred "Sesame never asks for Full Disk Access*" 0 "$w" 8)"; rc=$?
  [ "$rc" != 1 ] || s6_why "W13 ($look): the read note is not centred in the window: $off pt off, at most 8 allowed"
  ! printf '%s\n' "$S6_DUMP" | ax_has_label "Search model ready" || s6_why "W14 ($look): the Permissions step shows \"Search model ready\"; Permissions shows no status line with a whole model"
  return 0
}

s10_shortcut_rules() {
  local look="$1" size="$2" w off rc heading lead note gline gid gf gkids gbad gy gww gh lb nt d rl vt=W15
  local keys="Control Option Space"
  [ "$S10_STARTED" != 1 ] || vt=W26
  w="${size%% *}"
  case "$w" in ''|*[!0-9]*) w=560 ;; esac
  heading="$(printf '%s\n' "$S6_DUMP" | ax_frame "Open Sesame from anywhere")" || heading=""
  lead="$(printf '%s\n' "$S6_DUMP" | ax_frame "Press these keys together.")" || lead=""
  note="$(printf '%s\n' "$S6_DUMP" | ax_frame "You can change the shortcut later in Settings.")" || note=""
  gline="$(printf '%s\n' "$S6_DUMP" | ax_boxes | awk -F'\t' -v k="$keys" '
    $4 == k { if ($3 ~ /^AXGroup/ && !g) { g = $1; gf = $5 " " $6 " " $7 " " $8 } else if ($3 !~ /^AXGroup/) { bad = bad (bad ? ", " : "") $3 } }
    { par[$1] = $2 }
    END { kids = 0; if (g) for (i in par) if (par[i] == g) kids++; printf "%d|%s|%d|%s\n", g, gf, kids, bad }')"
  IFS='|' read -r gid gf gkids gbad <<< "$gline"
  [ -n "$heading" ] || s6_why "W15 ($look): the Shortcut dump holds no frame for the heading \"Open Sesame from anywhere\""
  [ -n "$lead" ] || s6_why "W15 ($look): the Shortcut dump holds no frame for the lead \"Press these keys together.\""
  [ -n "$note" ] || s6_why "W15 ($look): the Shortcut dump holds no frame for the note \"You can change the shortcut later in Settings.\""
  if [ -n "$heading" ]; then
    off="$(printf '%s\n' "$S6_DUMP" | ax_centred "Open Sesame from anywhere" 0 "$w" 8)"; rc=$?
    [ "$rc" != 1 ] || s6_why "W15 ($look): the heading is not centred in the window: $off pt off, at most 8 allowed"
  fi
  if [ -n "$lead" ]; then
    off="$(printf '%s\n' "$S6_DUMP" | ax_centred "Press these keys together." 0 "$w" 8)"; rc=$?
    [ "$rc" != 1 ] || s6_why "W15 ($look): the lead is not centred in the window: $off pt off, at most 8 allowed"
  fi
  if [ -n "$note" ]; then
    off="$(printf '%s\n' "$S6_DUMP" | ax_centred "You can change the shortcut later in Settings." 0 "$w" 8)"; rc=$?
    [ "$rc" != 1 ] || s6_why "W15 ($look): the note is not centred in the window: $off pt off, at most 8 allowed"
  fi
  if [ -n "$heading" ] && [ -n "$lead" ]; then
    set -- $heading
    d=$(( $2 + $4 ))
    set -- $lead
    [ "$2" -ge $(( d - 1 )) ] || s6_why "W15 ($look): the lead is not under the heading (it starts $(( d - $2 )) pt above the heading's bottom)"
  fi
  if [ -n "$gbad" ]; then
    s6_why "W16 ($look): the shortcut \"$keys\" is a plain $gbad, not one AXGroup (the keycaps are one accessibility group labelled with the shortcut)"
  elif [ "$gid" = 0 ]; then
    s6_why "W16 ($look): the Shortcut dump holds no AXGroup labelled \"$keys\""
  elif [ "$gkids" -gt 0 ]; then
    s6_why "W16 ($look): the keycaps group holds $gkids children; the keys and captions are not accessibility elements"
  fi
  if [ -z "$gbad" ] && [ "$gid" != 0 ] && [ "$gkids" = 0 ]; then
    set -- $gf
    if [ -z "${4:-}" ]; then
      s6_why "W15 ($look): the keycaps group \"$keys\" has no frame"
    else
      gy="$2"; gww="$3"; gh="$4"
      [ "$gww" -le 520 ] || s6_why "W16 ($look): the keycaps group is $gww pt wide, at most 520 allowed"
      off="$(printf '%s\n' "$S6_DUMP" | ax_centred "$keys" 0 "$w" 8)"; rc=$?
      [ "$rc" != 1 ] || s6_why "W15 ($look): the keycaps group is not centred in the window: $off pt off, at most 8 allowed"
      if [ -n "$lead" ] && [ -n "$note" ]; then
        set -- $lead
        lb=$(( $2 + $4 ))
        set -- $note
        nt="$2"
        if [ "$gy" -lt $(( lb - 1 )) ] || [ $(( gy + gh )) -gt $(( nt + 1 )) ]; then
          s6_why "W15 ($look): the keycaps group is not between the lead and the note"
        else
          d=$(( 2 * gy + gh - lb - nt ))
          [ "$d" -ge 0 ] || d=$(( -d ))
          [ "$d" -le 16 ] || s6_why "$vt ($look): the keycaps group is not vertically centred between the lead and the note: $(( d / 2 )) pt off, at most 8 allowed"
        fi
      fi
    fi
  fi
  rl="$(printf '%s\n' "$S6_DUMP" | ax_frame "$S10_RUNNING")" || rl=""
  if [ "$S10_STARTED" = 1 ]; then
    if ! printf '%s\n' "$S6_DUMP" | ax_has_label "$S10_RUNNING"; then
      s6_why "W25 ($look): Start was pressed (Folders reads Next with a whole model) but the Shortcut step has no running line \"$S10_RUNNING\""
    elif [ -z "$rl" ]; then
      s6_why "W25 ($look): the running line has no frame"
    else
      off="$(printf '%s\n' "$S6_DUMP" | ax_centred "$S10_RUNNING" 0 "$w" 8)"; rc=$?
      [ "$rc" != 1 ] || s6_why "W25 ($look): the running line is not centred in the window: $off pt off, at most 8 allowed"
      if [ -n "$note" ]; then
        set -- $note $rl
        [ "$6" -ge $(( $2 + $4 - 1 )) ] || s6_why "W25 ($look): the running line sits above the note, it belongs under it"
      fi
    fi
  elif printf '%s\n' "$S6_DUMP" | ax_has_label "$S10_RUNNING"; then
    s6_why "W25 ($look): the Shortcut step shows the running line though Start was not pressed"
  fi
  ! printf '%s\n' "$S6_DUMP" | ax_has_label "Search model ready" || s6_why "W17 ($look): the Shortcut step shows \"Search model ready\"; Shortcut shows no status line with a whole model"
  return 0
}

s10_folders_rules() {
  local look="$1" size="$2" w block="" start="" bf nf hf nn ticks sinfo srole sstate want other off rc hint
  w="${size%% *}"
  case "$w" in ''|*[!0-9]*) w=560 ;; esac
  ! printf '%s\n' "$S6_DUMP" | ax_has_label "Model download" || block=1
  ! printf '%s\n' "$S6_DUMP" | ax_has_label "Start indexing" || start=1
  ticks="$(printf '%s\n' "$S6_DUMP" | ax_rows | awk -F'\t' '$3 == "on" { n++ } END { print n + 0 }')"
  bf="$(printf '%s\n' "$S6_DUMP" | ax_frame "Add folder…")" || bf=""
  nf="$(printf '%s\n' "$S6_DUMP" | ax_frame "Photos, PDFs, documents*")" || nf=""
  if [ -z "$bf" ] || [ -z "$nf" ]; then
    s6_why "S4 (W12, $look): the Folders dump holds no frame for one of Add folder and the read note"
  else
    set -- $bf $nf
    [ $(( $2 + $4 )) -le "$6" ] || s6_why "S4 (W12, $look): Add folder is not above the read note"
  fi
  if [ -z "$block" ] && [ -n "$start" ]; then
    S10_STARTED=0
    sinfo="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$3 == "Start indexing" { print $2 "|" (index($7, "D") ? "disabled" : "enabled"); exit }')"
    srole="${sinfo%%|*}"
    sstate="${sinfo##*|}"
    case "$srole" in AXButton*) ;; *) s6_why "W22 ($look): \"Start indexing\" is an $srole, not a button" ;; esac
    ! printf '%s\n' "$S6_DUMP" | ax_has_label Next || s6_why "W22 ($look): Folders with a whole model shows a Next button; the footer's right button is Start indexing and Next is absent"
    if [ "$ticks" -ge 1 ]; then
      [ "$sstate" = enabled ] || s6_why "W22 ($look): Start indexing is disabled with $ticks ticked folder(s)"
      want="$S10_HINT_START"; other="$S10_HINT_TICK"
    else
      [ "$sstate" = disabled ] || s6_why "W23 ($look): no folder is ticked but Start indexing is enabled"
      want="$S10_HINT_TICK"; other="$S10_HINT_START"
    fi
    if ! printf '%s\n' "$S6_DUMP" | ax_has_label "$want"; then
      if printf '%s\n' "$S6_DUMP" | ax_has_label "$other"; then
        s6_why "W23 ($look): the hint reads \"$other\" with $ticks ticked folder(s), not \"$want\""
      else
        s6_why "W23 ($look): the Folders dump holds no hint line \"$want\""
      fi
    else
      hf="$(printf '%s\n' "$S6_DUMP" | ax_frame "$want")" || hf=""
      if [ -z "$hf" ]; then
        s6_why "W23 ($look): the hint line has no frame"
      else
        off="$(printf '%s\n' "$S6_DUMP" | ax_centred "$want" 0 "$w" 8)"; rc=$?
        [ "$rc" != 1 ] || s6_why "W23 ($look): the hint is not centred in the window: $off pt off, at most 8 allowed"
        if [ -n "$bf" ] && [ -n "$nf" ]; then
          set -- $bf $hf $nf
          [ "$6" -ge $(( $2 + $4 - 1 )) ] || s6_why "W23 ($look): the hint is not below Add folder"
          [ $(( $6 + $8 )) -le $(( ${10} + 1 )) ] || s6_why "W23 ($look): the hint is not above the read note"
        fi
      fi
    fi
    if ! printf '%s\n' "$S6_DUMP" | ax_has_label "Not now"; then
      s6_why "W24 ($look): Folders with a whole model has no Not now button, the quiet way on without starting"
    else
      nn="$(printf '%s\n' "$S6_DUMP" | ax_frame "Not now")" || nn=""
      if [ -z "$nn" ]; then
        s6_why "W24 ($look): the Not now button has no frame"
      else
        off="$(printf '%s\n' "$S6_DUMP" | ax_centred "Not now" 0 "$w" 8)"; rc=$?
        [ "$rc" != 1 ] || s6_why "W24 ($look): Not now is not centred in the window: $off pt off, at most 8 allowed"
        if [ -n "$nf" ]; then
          set -- $nf $nn
          [ "$6" -ge $(( $2 + $4 - 1 )) ] || s6_why "W24 ($look): Not now is not below the read note"
        fi
      fi
    fi
  else
    S10_STARTED=0
    [ -n "$block" ] || S10_STARTED=1
    [ -z "$start" ] || s6_why "W22 ($look): the model is not whole but Folders shows a Start indexing button; the footer reads Next"
    for hint in "$S10_HINT_START" "$S10_HINT_TICK"; do
      ! printf '%s\n' "$S6_DUMP" | ax_has_label "$hint" || s6_why "W22 ($look): Folders shows the hint \"$hint\" beside Next; the hint belongs to Start indexing only"
    done
    ! printf '%s\n' "$S6_DUMP" | ax_has_label "Not now" || s6_why "W22 ($look): Folders shows Not now beside Next; Not now belongs to Start indexing only"
  fi
  return 0
}

s10_setup_rules() {
  local look="$1" n="$2" size primary fn bx rest g d title w off rc wt=""
  size="$(s10_header_size)"
  [ "$size" = "560 x 628" ] || s6_why "S1 ($look step $n): the window is ${size:-unknown}, not 560 x 628"
  primary=Next; [ "$n" = 4 ] && primary=Finish
  if [ "$n" = 2 ] && ! printf '%s\n' "$S6_DUMP" | ax_has_label "Model download" && printf '%s\n' "$S6_DUMP" | ax_has_label "Start indexing"; then
    primary="Start indexing"; wt=" W22"
  fi
  fn="$(printf '%s\n' "$S6_DUMP" | ax_frame "$primary")" || fn=""
  if [ -z "$fn" ]; then
    s6_why "S2 footer$wt ($look step $n): the dump holds no $primary with a frame"
  else
    set -- $fn
    [ $(( $1 + $3 )) -ge 538 ] && [ $(( $1 + $3 )) -le 542 ] || s6_why "S2 footer$wt ($look step $n): $primary ends at $(( $1 + $3 )), not 20 pt from the right edge (540)"
    if [ "$n" -gt 1 ]; then
      bx="$(printf '%s\n' "$S6_DUMP" | ax_frame Back)" || bx=""
      if [ -z "$bx" ]; then
        s6_why "S2 footer$wt ($look step $n): the dump holds no Back with a frame"
      elif [ -n "$wt" ]; then
        set -- $fn $bx
        d=$(( 2 * $2 + $4 - 2 * $6 - $8 ))
        [ "$d" -ge 0 ] || d=$(( -d ))
        if [ "$5" -lt 18 ] || [ "$5" -gt 22 ] || [ "$5" -ge "$1" ] || [ "$d" -gt 8 ]; then
          s6_why "S2 footer$wt ($look step $n): Back and $primary are not one row with Back at the left edge and $primary at the right, centred within 4 pt of Back"
        fi
      else
        rest="$(set -- $bx; echo "$1 $2")"
        set -- $fn $rest
        if [ "$5" -lt 18 ] || [ "$5" -gt 22 ] || [ "$5" -ge "$1" ] || [ $(( $6 - $2 )) -gt 2 ] || [ $(( $2 - $6 )) -gt 2 ]; then
          s6_why "S2 footer ($look step $n): Back and $primary are not one row with Back at the left edge and $primary at the right"
        fi
      fi
    fi
    if [ "$n" = 1 ] || [ "$n" = 4 ]; then
      g="$(printf '%s\n' "$S6_DUMP" | ax_gap_above "$primary")"
      [ -z "$g" ] || [ "$g" -le 24 ] || s6_why "S1 ($look step $n): $g pt blank between the content and the footer, at most 24 allowed"
    fi
  fi
  if [ "$n" = 1 ]; then
    printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$2 ~ /^AXScrollBar/ { f = 1 } END { exit f ? 0 : 1 }' && s6_why "S6 ($look): the Welcome step has a scroller"
    printf '%s\n' "$S6_DUMP" | ax_has_label Back && s6_why "W3 ($look): the Welcome step lists Back, which is hidden on step 1"
  fi
  title="Step $n of 4: $(s10_step_name "$n")"
  if printf '%s\n' "$S6_DUMP" | ax_has_label "$title"; then
    if ! printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' -v w="$title" '$2 ~ /^AXGroup/ && $3 == w { f = 1 } END { exit f ? 0 : 1 }'; then
      s6_why "W4 ($look step $n): \"$title\" is not an accessibility group, so the progress dots are not one group with that title"
    else
      w="${size%% *}"
      case "$w" in ''|*[!0-9]*) w=560 ;; esac
      off="$(printf '%s\n' "$S6_DUMP" | ax_centred "$title" 0 "$w" 8)"; rc=$?
      case $rc in
        0) ;;
        1) s6_why "W3 ($look step $n): the progress dots are not centred in the window: $off pt off, at most 8 allowed" ;;
        *) s6_why "W3 ($look step $n): the dots group \"$title\" has no frame" ;;
      esac
    fi
  fi
  if [ "$n" = 2 ]; then
    d="$(printf '%s\n' "$S6_DUMP" | ax_first_row_gap)" || d=""
    if [ -z "$d" ]; then
      s10_rerun S10.2 "the Folders step lists no folder row with a frame"
      return 1
    fi
    [ "$d" -le 24 ] || s6_why "S3 ($look): the first folder row sits $d pt below the top of its list"
    s10_folders_rules "$look" "$size"
    printf '%s\n' "$S6_DUMP" | ax_has_label "Search model ready" && s6_why "W11 ($look): the Folders step shows \"Search model ready\"; Folders shows no status line"
  fi
  [ "$n" != 3 ] || s10_permissions_rules "$look" "$size"
  [ "$n" != 4 ] || s10_shortcut_rules "$look" "$size"
  s10_layout "Setup step $n ($look)"
  return 0
}

s10_check_2() {
  local look n
  S10_ID=S10.2
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_overlap
    S6_PLANTED="a text added on top of the first text of every Setup dump"
  fi
  s10_setup_state S10.2 || return $S6_RC
  s10_look S10.2 light || return $S6_RC
  for n in 1 2 3 4; do
    [ "$n" = 1 ] || { s10_forward S10.2 $(( n - 1 )) || return $S6_RC; }
    s10_step S10.2 "$n" read || return $S6_RC
    s10_setup_rules light "$n" || return $S6_RC
    s10_shot S10.2 "s10-2-light-$n" || return $S6_RC
  done
  s10_look S10.2 dark || return $S6_RC
  for n in 4 3 2 1; do
    [ "$n" = 4 ] || { s10_press S10.2 Back || return $S6_RC; }
    s10_step S10.2 "$n" read || return $S6_RC
    s10_setup_rules dark "$n" || return $S6_RC
    s10_shot S10.2 "s10-2-dark-$n" || return $S6_RC
  done
  s10_person "only the footer's right button and the current dot carry the accent (W5); the model block, every checkbox name fully visible and the 4.5 to 1 contrast on the window and card surfaces over glass in both looks are read from the shots shot-s10-2-light-N and shot-s10-2-dark-N"
  s10_person "the footer's Start indexing is the only accent button and is easy to see, the hint line and Not now read quietly, and the Shortcut running line fits are read from the shots shot-s10-2-light-2, shot-s10-2-dark-2, shot-s10-2-light-4 and shot-s10-2-dark-4"
  s10_person "the Permissions card, its hairlines and the note are read from the shots shot-s10-2-light-3 and shot-s10-2-dark-3"
  s10_person "the keycaps (neutral fill, hairline border, lower edge, symbol and caption, Light and Dark repaint) are read from the shots shot-s10-2-light-4 and shot-s10-2-dark-4"
  s10_done S10.2 ""
}
check_S10_2() { s10_run s10_check_2; }

s10_shell_rules() {
  local look="$1" sec="$2" wh="$3" hit name
  hit="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$3 == "About" { printf "%s \"%s\"", $2, $3; exit }')"
  [ -z "$hit" ] || s6_why "T1 ($look $sec): the dump holds $hit; the About tab is removed (guide 16.16), Settings has four tabs"
  hit="$(printf '%s\n' "$S6_DUMP" | ax_boxes | LC_ALL=C awk -F'\t' -v wh="$wh" -v names="$S10_SECTIONS" '
    function base(r) { sub(/\/.*/, "", r); return r }
    BEGIN { k = split(names, nm, "|"); for (i = 1; i <= k; i++) want[nm[i]] = 1; minx = 1e9; miny = 1e9; maxx = -1e9 }
    { N++; role[N] = base($3); lab[N] = $4; X[N] = $5; Y[N] = $6; W[N] = $7; H[N] = $8; has[N] = ($5 != "") }
    END {
      for (i = 1; i <= N; i++) if (has[i] && role[i] == "AXCheckBox" && (lab[i] in want)) {
        if (X[i] < minx) minx = X[i]
        if (X[i] + W[i] > maxx) maxx = X[i] + W[i]
        if (Y[i] < miny) miny = Y[i]
      }
      if (minx == 1e9) exit
      for (i = 1; i <= N; i++) {
        if (!has[i] || role[i] == "AXWindow" || role[i] == "AXCheckBox" || role[i] == "AXButton" || role[i] == "AXScrollArea") continue
        if (X[i] >= -1 && X[i] + W[i] <= 189 && X[i] <= minx + 1 && X[i] + W[i] >= maxx - 1 && Y[i] <= miny + 1 && Y[i] + H[i] >= wh - 20) {
          printf "%s \"%s\"", role[i], lab[i]
          exit
        }
      }
    }')"
  [ -z "$hit" ] || s6_why "W27 T7 ($look $sec): the sidebar panel is exposed as an element ($hit) holding the sidebar buttons inside x 0 to 188 and ending within 20 pt of the window bottom; the panel is not an accessibility element"
  hit="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '($2 ~ /^(AXTextField|AXSearchField|AXSearchTextField|AXComboBox)/ && $3 == "Search") || $2 ~ /^AXSearchField/ || ($2 ~ /^AXButton/ && tolower($3) ~ /^(back|forward|go back|go forward)$/) { printf "%s \"%s\"", $2, $3; exit }')"
  [ -z "$hit" ] || s6_why "W29 ($look $sec): the dump holds $hit; the toolbar strip has the tab title only, no Search field and no back or forward arrows"
  hit="$(printf '%s\n' "$S6_DUMP" | ax_boxes | LC_ALL=C awk -F'\t' '
    function base(r) { sub(/\/.*/, "", r); return r }
    { role[$1] = base($3); par[$1] = $2; lab[$1] = $4; N = $1 }
    END {
      for (i = 1; i <= N; i++) {
        if ((lab[i] != "Re-index" && lab[i] != "Remove") || role[i] == "AXMenuItem") continue
        inmenu = 0
        for (p = par[i]; p > 0; p = par[p]) if (role[p] == "AXMenu") inmenu = 1
        if (!inmenu) { printf "%s \"%s\"", role[i], lab[i]; exit }
      }
    }')"
  [ -z "$hit" ] || s6_why "W32 ($look $sec): the dump holds $hit outside an open menu; Re-index and Remove are items of a row's more menu (guide 16.4)"
  [ "$sec" = Folders ] || return 0
  printf '%s\n' "$S6_DUMP" | ax_has_label "$S10_FOLDERS_TITLE" || s6_why "W33 ($look): the Folders dump holds no text \"$S10_FOLDERS_TITLE\""
  printf '%s\n' "$S6_DUMP" | ax_has_label "$S10_FOLDERS_NOTE" || s6_why "W33 ($look): the Folders dump holds no note \"$S10_FOLDERS_NOTE\""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' -v w="More actions for $name" '$2 ~ /^(AXPopUpButton|AXMenuButton)/ && $3 == w { f = 1 } END { exit f ? 0 : 1 }' || s6_why "W31 ($look): the Folders row $name has no \"More actions for $name\" control (an AXPopUpButton or an AXMenuButton)"
  done < <(printf '%s\n' "$S6_DUMP" | ax_rows | awk -F'\t' '{ print $2 }')
  return 0
}

s10_search_rules() {
  local look="$1" keys="Control Option Space" hit gline gid gf gkids gbad rf bf gx gy gw gh rx ry rw rh bx by bw bh d
  hit="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$3 == "Keyboard shortcut" { printf "%s \"%s\"", $2, $3; exit }')"
  [ -z "$hit" ] || s6_why "W39 ($look): the Search dump holds $hit; the old shortcut text is gone and the keycaps are one group labelled \"$keys\" (guide 16.14)"
  gline="$(printf '%s\n' "$S6_DUMP" | ax_boxes | awk -F'\t' -v k="$keys" '
    $4 == k { if ($3 ~ /^AXGroup/ && !g) { g = $1; gf = $5 " " $6 " " $7 " " $8 } else if ($3 !~ /^AXGroup/) { bad = bad (bad ? ", " : "") $3 } }
    { par[$1] = $2 }
    END { kids = 0; if (g) for (i in par) if (par[i] == g) kids++; printf "%d|%s|%d|%s\n", g, gf, kids, bad }')"
  IFS='|' read -r gid gf gkids gbad <<< "$gline"
  rf="$(printf '%s\n' "$S6_DUMP" | ax_frame "Record new shortcut")" || rf=""
  bf="$(printf '%s\n' "$S6_DUMP" | ax_frame "Back to default")" || bf=""
  if [ -n "$gbad" ]; then
    s6_why "W39 ($look): the Search shortcut \"$keys\" is a plain $gbad, not one AXGroup (the keycaps are one accessibility group labelled with the shortcut)"
  elif [ "$gid" = 0 ]; then
    s6_why "W39 ($look): the Search dump holds no AXGroup labelled \"$keys\""
  elif [ "$gkids" -gt 0 ]; then
    s6_why "W39 ($look): the keycaps group holds $gkids children; the keys are not accessibility elements"
  fi
  [ -n "$rf" ] || s6_why "W38 ($look): the Search dump holds no frame for \"Record new shortcut\""
  if [ -z "$gbad" ] && [ "$gid" != 0 ] && [ "$gkids" = 0 ]; then
    set -- $gf
    if [ -z "${4:-}" ]; then
      s6_why "W39 ($look): the keycaps group \"$keys\" has no frame"
    else
      gx="$1"; gy="$2"; gw="$3"; gh="$4"
      if [ "$gh" -gt 30 ] || [ "$gh" -lt 22 ]; then
        s6_why "W39 ($look): the keycaps group is $gh pt tall, between 22 and 30 allowed (compact keys are 26)"
      fi
      if [ -n "$rf" ]; then
        set -- $rf
        rx="$1"; ry="$2"; rw="$3"; rh="$4"
        if [ $(( gx + gw )) -gt $(( rx + 1 )) ] && [ $(( rx + rw )) -gt $(( gx + 1 )) ] && [ $(( gy + gh )) -gt $(( ry + 1 )) ] && [ $(( ry + rh )) -gt $(( gy + 1 )) ]; then
          s6_why "W38 ($look): the keycaps group overlaps the Record new shortcut button"
        fi
        d=$(( rx - gx - gw ))
        { [ "$d" -ge 6 ] && [ "$d" -le 20 ]; } || s6_why "W38 ($look): the keycaps group ends $d pt left of the Record new shortcut button, 6 to 20 allowed (12 expected)"
        d=$(( 2 * gy + gh - 2 * ry - rh ))
        [ "$d" -ge 0 ] || d=$(( -d ))
        [ "$d" -le 8 ] || s6_why "W38 ($look): the keycaps group is not vertically centred with the Record new shortcut button: $(( d / 2 )) pt off, at most 4 allowed"
      fi
    fi
  fi
  if [ -n "$rf" ] && [ -n "$bf" ]; then
    set -- $rf $bf
    rx="$1"; ry="$2"; rw="$3"; rh="$4"; bx="$5"; by="$6"; bw="$7"; bh="$8"
    { [ "$by" -ge $(( ry + rh )) ] && [ "$bx" -lt "$rx" ]; } || s6_why "W40 ($look): Back to default is not below the Record new shortcut button and left of it"
    if [ $(( bx + bw )) -gt $(( rx + 1 )) ] && [ $(( rx + rw )) -gt $(( bx + 1 )) ] && [ $(( by + bh )) -gt $(( ry + 1 )) ] && [ $(( ry + rh )) -gt $(( by + 1 )) ]; then
      s6_why "W40 ($look): Back to default overlaps the Record new shortcut button"
    fi
  fi
  return 0
}

s10_indexing_rules() {
  local look="$1" caption="The shortcut works only while Sesame is running." login lf plain sf df cf sx sy sw sh dx dy cx cy cw ch d
  login="$(printf '%s\n' "$S6_DUMP" | ax_boxes | LC_ALL=C awk -F'\t' '
    $4 == "Launch at login" && $3 == "AXCheckBox/AXSwitch" && $5 != "" && !s { s = $5 " " $6 " " $7 " " $8 }
    $4 == "Launch at login" && $3 == "AXCheckBox" { p = 1 }
    END { printf "%s|%d\n", s, p }')"
  IFS='|' read -r lf plain <<< "$login"
  sf="$(printf '%s\n' "$S6_DUMP" | ax_frame "Start indexing")" || sf=""
  df="$(printf '%s\n' "$S6_DUMP" | ax_frame "Delete index…")" || df=""
  cf="$(printf '%s\n' "$S6_DUMP" | ax_frame "$caption")" || cf=""
  if [ "$plain" = 1 ]; then
    s6_why "W42 ($look): the Indexing dump holds a plain AXCheckBox labelled \"Launch at login\"; Launch at login is a system switch by decision (guide 16.15), read as AXCheckBox/AXSwitch"
  elif [ -z "$lf" ]; then
    s6_why "W42 ($look): the Indexing dump holds no AXCheckBox/AXSwitch labelled \"Launch at login\" with a frame (the golden state has the login item on)"
  fi
  [ -n "$sf" ] || s6_why "W43 ($look): the Indexing dump holds no frame for \"Start indexing\""
  [ -n "$df" ] || s6_why "W43 ($look): the Indexing dump holds no frame for \"Delete index…\""
  if [ -n "$sf" ]; then
    set -- $sf
    sx="$1"; sy="$2"; sw="$3"; sh="$4"
    [ "$sw" -le 220 ] || s6_why "W43 ($look): Start indexing is $sw pt wide, 220 allowed: it is a normal-size button, never the card width"
    if [ -n "$lf" ]; then
      set -- $lf
      [ "$2" -lt "$sy" ] || s6_why "W42 W43 ($look): Launch at login (top $2) is not above Start indexing (top $sy); the switch row comes first"
    fi
    if [ -n "$df" ]; then
      set -- $df
      dx="$1"; dy="$2"
      [ "$sy" -lt "$dy" ] || s6_why "W43 ($look): Start indexing (top $sy) is not above Delete index… (top $dy); Delete index… is the second row"
      d=$(( sx - dx )); [ "$d" -ge 0 ] || d=$(( -d ))
      [ "$d" -le 6 ] || s6_why "W43 ($look): the left edges of Start indexing and Delete index… are $d pt apart, 6 allowed: the two rows share one left edge"
    fi
  fi
  if [ -n "$lf" ] && [ -n "$cf" ]; then
    set -- $lf $cf
    sx="$1"; sy="$2"; sw="$3"; sh="$4"; cx="$5"; cy="$6"; cw="$7"; ch="$8"
    if [ $(( sx + sw )) -gt $(( cx + 1 )) ] && [ $(( cx + cw )) -gt $(( sx + 1 )) ] && [ $(( sy + sh )) -gt $(( cy + 1 )) ] && [ $(( cy + ch )) -gt $(( sy + 1 )) ]; then
      s6_why "W42 ($look): the Launch at login switch overlaps its caption; the caption is at the left and the switch at the right"
    fi
  fi
  return 0
}

s10_settings_rules() {
  local look="$1" sec="$2" size names prev="" x0="" w0="" f x y w h py ph pd bad title name pf mf pane tx sx sw
  size="$(s10_header_size)"
  [ -n "$size" ] || { s10_rerun S10.3 "the $sec dump ($look) has no window size header: the bottom check has no height to read"; return 1; }
  [ "$size" = "720 x 548" ] || s6_why "$sec ($look): the window is $size, not 720 x 548"
  title="$(printf '%s\n' "$S6_DUMP" | awk '/^window [0-9]+ x [0-9]+ at / { i = index($0, " title "); print substr($0, i + 7); exit }')"
  [ "$title" = Settings ] || s6_why "T2 ($look $sec): the window title is \"$title\", not Settings"
  printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' -v s="$sec" '$2 ~ /^AXStaticText/ && $3 == s { f = 1 } END { exit f ? 0 : 1 }' || s6_why "T2 W29 ($look $sec): no pane title equal to the section name"
  IFS='|' read -r -a names <<< "$S10_SECTIONS"
  for name in "${names[@]}"; do
    f="$(printf '%s\n' "$S6_DUMP" | ax_frame "$name")" || { s6_why "T1 ($look $sec): the sidebar button $name has no frame"; continue; }
    set -- $f
    x="$1"; y="$2"; w="$3"; h="$4"
    [ -z "$x0" ] && { x0="$x"; w0="$w"; }
    [ $(( x - x0 )) -ge -1 ] && [ $(( x - x0 )) -le 1 ] || s6_why "T1 ($look $sec): the sidebar item $name is not at the x of the first item"
    [ "$h" -ge 27 ] && [ "$h" -le 29 ] || s6_why "T1 ($look $sec): the sidebar item $name is $h pt tall, not 28"
    if [ -n "$prev" ]; then
      pd=$(( y - prev ))
      [ "$pd" -ge 1 ] && [ "$pd" -le 3 ] || s6_why "T1 ($look $sec): the sidebar item $name is $pd pt below the one above, not 2 pt"
    fi
    prev=$(( y + h ))
  done
  if [ -n "$x0" ]; then
    if [ "$x0" -lt 7 ] || [ "$x0" -gt 9 ]; then
      s6_why "W54 ($look $sec): the sidebar item starts at x $x0, not 8: the sidebar must be a flat full-height column, not a floating panel (guide 18)"
    elif [ "$w0" -lt 162 ] || [ "$w0" -gt 166 ]; then
      s6_why "W54 ($look $sec): the first sidebar item is $w0 pt wide, not 164: the sidebar must be a flat full-height column with rows inset 8 (guide 18)"
    fi
  fi
  pane="$(printf '%s\n' "$S6_DUMP" | ax_boxes | LC_ALL=C awk -F'\t' -v s="$sec" '
    function base(r) { sub(/\/.*/, "", r); return r }
    { r = base($3) }
    r == "AXStaticText" && $4 == s && $5 != "" && !t { t = 1; tx = $5 }
    r == "AXScrollArea" && $5 != "" && $7 * $8 > best { best = $7 * $8; sx = $5; sw = $7 }
    END { printf "%s|%s|%s\n", (t ? tx : ""), (best ? sx : ""), (best ? sw : "") }')"
  IFS='|' read -r tx sx sw <<< "$pane"
  if [ -n "$tx" ] && { [ "$tx" -lt 196 ] || [ "$tx" -gt 198 ]; }; then
    s6_why "W55 ($look $sec): the pane title starts at x $tx, expected 197: the pane starts at x 181, not a floating panel's 188 (guide 18)"
  fi
  if [ -n "$sx" ]; then
    if [ "$sx" -lt 180 ] || [ "$sx" -gt 182 ]; then
      s6_why "W55 ($look $sec): the pane starts at x $sx, expected 181 (title at 197)"
    elif [ "$sw" -lt 538 ] || [ "$sw" -gt 540 ]; then
      s6_why "W55 ($look $sec): the pane is $sw pt wide, expected 539 (from x 181 to the window's right edge)"
    fi
  fi
  if [ "$sec" = Search ]; then
    pf="$(printf '%s\n' "$S6_DUMP" | ax_frame "PDF app")" || pf=""
    mf="$(printf '%s\n' "$S6_DUMP" | ax_frame "Media app")" || mf=""
    if [ -z "$pf" ] || [ -z "$mf" ]; then
      s6_why "T4 ($look): the Search section holds no pop-up with a frame"
    else
      set -- $pf $mf
      pd=$(( $1 - $5 )); [ $pd -lt 0 ] && pd=$(( -pd ))
      [ $pd -le 1 ] && [ "$3" -ge 198 ] && [ "$3" -le 202 ] && [ "$7" -ge 198 ] && [ "$7" -le 202 ] || s6_why "T4 ($look): the two pop-ups are not in one column of 200 pt"
    fi
    s10_search_rules "$look"
  fi
  if [ "$sec" = Indexing ]; then s10_indexing_rules "$look"; fi
  bad="$(printf '%s\n' "$S6_DUMP" | ax_near_bottom "${size##* }" 20 | head -2 | paste -sd';' -)"
  [ -z "$bad" ] || s6_why "T7 ($look $sec): $bad sits within 20 pt of the window bottom outside the pane's scroll area"
  s10_shell_rules "$look" "$sec" "${size##* }"
  s10_layout "Settings $sec ($look)"
  return 0
}

s10_confirm_rules() {
  local look="$1" cf df
  cf="$(printf '%s\n' "$S6_DUMP" | ax_frame Cancel)" || cf=""
  if [ -z "$cf" ]; then
    s10_rerun S10.3 "pressing Delete index… opened no confirm with a Cancel button"
    return 1
  fi
  df="$(printf '%s\n' "$S6_DUMP" | ax_frame "Delete index")" || df="$(printf '%s\n' "$S6_DUMP" | ax_frame Delete)" || df=""
  if [ -z "$df" ]; then
    s10_rerun S10.3 "the confirm shows no Delete index button"
    return 1
  fi
  set -- $cf $df
  if [ "$1" -ge "$5" ] || [ $(( $2 - $6 )) -gt 2 ] || [ $(( $6 - $2 )) -gt 2 ]; then
    s6_why "T6 ($look): Cancel is not at the left of the confirm button in one row"
  fi
  s10_layout "the Delete index confirm ($look)"
  return 0
}

s10_check_3() {
  local look sec
  S10_ID=S10.3
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_overlap
    S6_PLANTED="a text added on top of the first text of every Settings dump"
  fi
  s10_golden_state S10.3 || return $S6_RC
  s10_settings_open S10.3 || return $S6_RC
  for look in light dark; do
    s10_look S10.3 "$look" || return $S6_RC
    IFS='|' read -r -a SECS <<< "$S10_SECTIONS"
    for sec in "${SECS[@]}"; do
      s10_section S10.3 "$sec" || return $S6_RC
      s10_read S10.3 settings || return $S6_RC
      s10_settings_rules "$look" "$sec" || return $S6_RC
      s10_shot S10.3 "s10-3-$look-$(printf '%s' "$sec" | tr 'A-Z ' 'a-z-')" || return $S6_RC
    done
    s10_section S10.3 Indexing || return $S6_RC
    s10_press S10.3 "Delete index…" || return $S6_RC
    sleep "${S10_SETTLE:-1}"
    s10_read S10.3 settings || return $S6_RC
    s10_confirm_rules "$look" || { s6_press "$S10_AX" Cancel >/dev/null 2>&1; return $S6_RC; }
    s10_shot S10.3 "s10-3-$look-confirm" || return $S6_RC
    s6_press "$S10_AX" Cancel >/dev/null 2>&1
  done
  s10_person "T1 the sidebar is a flat full-height column flush with the window's left, top and bottom edges with no rounded corner and no outline of its own, a thin line on its right edge, the traffic lights over its top and the accent pill on the selected row, T3 cards with 12 pt radius, an outline, inset hairlines and no bezel scroll box, T4 the label column at 140 pt, T5 the more button opens Re-index and Remove with Remove in red, T6 no red fill on the confirm, T8 the 4.5 to 1 contrast on the cards and on the sidebar column in both looks, T9 the four sidebar icons are plain outlines in the label colour (white on the selected row) and none is coloured (the Folders icon in particular), the four sidebar labels start at one x with a wider gap after each icon, and the selected Folders icon is a plain white outline with no lighter fill inside, and the five File types switches sit right-aligned in one card with the accent when on, T10 the Search shortcut is one card row: the name, small neutral keycaps and Record new shortcut at the right, with Back to default as a quiet line under the card and a message under that; read the shots shot-s10-3-light-search and shot-s10-3-dark-search, T11 Indexing is a Launch at login card with its caption at the left and a switch at the right, then a card with Start indexing at normal size and Delete index... under a hairline in red text, and each file Sesame could not read as a name over its reason; read the shots shot-s10-3-light-indexing, shot-s10-3-dark-indexing and shot-s10-3-light-confirm; read the shots shot-s10-3-light-* and shot-s10-3-dark-*"
  s10_done S10.3 ""
}
check_S10_3() { s10_run s10_check_3; }

s10_menu_problems() {
  ax_elements | LC_ALL=C awk -F'\t' '
    function st(s,   l) {
      l = tolower(s)
      if (l ~ /^indexing has not been started/) return "ready"
      if (l ~ /^ready/) return "ready"
      if (l ~ /^indexing/) return "indexing"
      if (l ~ /^paused/) return "paused"
      if (l ~ /^downloading/) return "downloading"
      if (l ~ /^(model|failed)/) return "failed"
      if (l ~ /^not ready/) return "notready"
      return "other"
    }
    gfound && !gdone { if ($1 > gdepth) kids++; else gdone = 1 }
    $2 ~ /^AXMenuItem/ {
      n++
      lab[n] = $3
      dis[n] = (index($7, "D") > 0)
      inhdr = 0
      if (!hdr && $3 != "") { hdr = n; inhdr = 1 }
    }
    $2 ~ /^AXGroup/ && inhdr && !gfound { gfound = 1; glabel = $3; gdepth = $1 }
    END {
      if (!hdr) exit
      t = lab[hdr]
      ts = st(t)
      if (ts == "other") print "the first item of the menu is \"" t "\", not the status line (W18)"
      if (!gfound) print "W18: the header item \"" t "\" holds no AXGroup labelled \"<title>, <detail>\""
      else {
        if (glabel == "") print "W18: the header group has no label, expected \"<title>, <detail>\""
        else if (st(glabel) != ts) print "W18: the header group is labelled \"" glabel "\", which does not start with the state word of the item \"" t "\""
        if (glabel ~ /^,/ || glabel ~ /,[ ]*$/) print "W18: the header group label \"" glabel "\" is not \"<title>, <detail>\""
        if (kids > 0) print "W18: the header group holds " kids " child element(s), expected none"
      }
      for (i = 1; i <= n; i++) {
        if (i != hdr && lab[i] ~ /^(Pause indexing|Resume|Retry)/) {
          na++
          if (!firstact) firstact = i
          if (!firstname) firstname = lab[i]
          if (dis[i]) print "W19: the action item \"" lab[i] "\" is [disabled], a Pause, Resume or Retry item is drawn only when it can be used"
        }
        if (lab[i] == "Open Sesame" && !open) open = i
        if (tolower(lab[i]) ~ /nothing indexed yet/) print "W19: the menu holds \"" lab[i] "\""
        if (index(tolower(lab[i]), "last indexed")) print "W60: the menu holds the item \"" lab[i] "\"; the person removed the Last indexed row because a long file name widens the menu (guide 19)"
        if (lab[i] == "" && !dis[i]) print "W19: item " i " has an empty title and is not a separator (it is not [disabled])"
      }
      need = (ts == "indexing" || ts == "failed" || (ts == "paused" && tolower(t " " glabel) ~ /by you|indexing stopped/))
      forbid = (ts == "ready" || ts == "downloading")
      if (need && (!firstact || (open && firstact > open))) print "W19: the header says \"" t "\" but there is no Pause, Resume or Retry item before Open Sesame"
      if (forbid && na > 0) print "W19: the header says \"" t "\" but the menu holds the action item \"" firstname "\" (a Ready or Downloading menu has none)"
      for (i = 1; i <= n; i++) {
        sep = (lab[i] == "" && dis[i])
        if (sep && i == 1) print "W20: the menu starts with a separator"
        if (sep && i == n) print "W20: the menu ends with a separator"
        if (sep && prev) print "W20: two separators in a row at items " (i - 1) " and " i
        prev = sep
      }
    }'
}

s10_check_4() {
  local items last3 icons line
  S10_ID=S10.4
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_menu
    S6_PLANTED="Quit Sesame taken out of the menu dump"
  fi
  s10_golden_state S10.4 || return $S6_RC
  s10_dump S10.4 menu || return $S6_RC
  s6_save s10-4-menu
  items="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$2 ~ /^AXMenuItem/ && $3 != "" { print $3 }')"
  [ -n "$items" ] || { s10_rerun S10.4 "the menu dump holds no item"; return $S6_RC; }
  while IFS= read -r line; do
    [ -z "$line" ] || s6_why "$line"
  done < <(printf '%s\n' "$S6_DUMP" | s10_menu_problems)
  last3="$(printf '%s\n' "$items" | tail -3 | paste -sd'|' -)"
  [ "$last3" = "Open Sesame|Settings…|Quit Sesame" ] || s6_why "the last three items are $(printf '%s' "$last3" | sed 's/|/, /g'), not Open Sesame, Settings… and Quit Sesame in this order"
  icons="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$2 ~ /^AXImage/ { n++ } END { print n + 0 }')"
  s10_person "the status icon at real size and the look of each item's symbol are the person's (S10.N1); the dump shows $icons image elements under the menu; W21 the status icon shows the magnifier and no text beside it, in every state, is the person's too, because the dump of the status item prints its title or else its description and cannot tell an empty title from one equal to the accessibility label"
  s10_done S10.4 ""
}
check_S10_4() { s10_run s10_check_4; }

s10_plant_menu() {
  grep -v 'Quit Sesame'
}

s10_collect() {
  local id="$1" n sec file
  s10_setup_state "$id" || return 1
  for n in 1 2 3 4; do
    [ "$n" = 1 ] || { s10_forward "$id" $(( n - 1 )) || return 1; }
    s10_step "$id" "$n" dump || return 1
    printf '%s\n' "$S6_DUMP" > "$S10_DIR/new-dump-setup-$n.txt"
  done
  s10_golden_state "$id" || return 1
  s10_panel "$id" || return 1
  s10_dump "$id" panel || return 1
  printf '%s\n' "$S6_DUMP" > "$S10_DIR/new-dump-panel-empty.txt"
  s10_search "$id" "qwv zzkx lorp mnb" || return 1
  s10_dump "$id" panel || return 1
  printf '%s\n' "$S6_DUMP" > "$S10_DIR/new-dump-panel-nomatches.txt"
  pn_close_panel >/dev/null 2>&1
  s10_settings_open "$id" || return 1
  IFS='|' read -r -a SECS <<< "$S10_SECTIONS"
  for sec in "${SECS[@]}"; do
    s10_section "$id" "$sec" || return 1
    s10_dump "$id" settings || return 1
    file="new-dump-settings-$(printf '%s' "$sec" | tr 'A-Z ' 'a-z-').txt"
    printf '%s\n' "$S6_DUMP" > "$S10_DIR/$file"
  done
  s10_dump "$id" menu || return 1
  printf '%s\n' "$S6_DUMP" > "$S10_DIR/new-dump-menu.txt"
  return 0
}

s10_check_5() {
  local f hit boxes
  S10_ID=S10.5
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_switch
    S6_PLANTED="an AXSwitch checkbox added to every dump"
  fi
  s10_collect S10.5 || return $S6_RC
  for f in "$S10_DIR"/new-dump-*.txt; do
    hit="$(ax_elements < "$f" | LC_ALL=C awk -F'\t' -v nm="${f##*/new-}" -v kinds="$S10_KINDS" '
      BEGIN { k = split(kinds, a, "|"); for (i = 1; i <= k; i++) kind[a[i]] = 1 }
      $2 ~ /AXSwitch/ {
        if (nm == "dump-settings-file-types.txt" && $2 == "AXCheckBox/AXSwitch" && ($3 in kind) && !seen[$3]++ && ($6 == "1" || $6 == "0")) next
        if (nm == "dump-settings-indexing.txt" && $2 == "AXCheckBox/AXSwitch" && $3 == "Launch at login" && !login++ && ($6 == "1" || $6 == "0")) next
        printf "%s \"%s\"", $2, $3
        exit
      }')"
    [ -z "$hit" ] || s6_why "${f##*/new-} holds a switch: $hit"
  done
  boxes="$(ax_elements < "$S10_DIR/new-dump-setup-2.txt" | awk -F'\t' '$2 ~ /^AXCheckBox/ && $2 !~ /AXSwitch/ { n++ } END { print n + 0 }')"
  [ "$boxes" -ge 1 ] || { s10_rerun S10.5 "the Folders step of Setup holds no checkbox: the positive control does not hold"; return $S6_RC; }
  boxes="$(ax_elements < "$S10_DIR/new-dump-settings-folders.txt" | awk -F'\t' '$2 ~ /^AXCheckBox/ && $2 !~ /AXSwitch/ { n++ } END { print n + 0 }')"
  [ "$boxes" -ge 1 ] || { s10_rerun S10.5 "the folders section of Settings holds no checkbox: the positive control does not hold"; return $S6_RC; }
  IFS='|' read -r -a SECS <<< "$S10_KINDS"
  for f in "${SECS[@]}"; do
    case "$(ax_elements < "$S10_DIR/new-dump-settings-file-types.txt" | awk -F'\t' -v w="$f" '$2 ~ /^AXCheckBox/ && $3 == w { if ($2 ~ /AXSwitch/) s = 1; else p = 1 } END { print (s ? "switch" : (p ? "plain" : "absent")) }')" in
      switch) ;;
      plain) s6_why "new-dump-settings-file-types.txt holds the kind $f as a plain AXCheckBox: the five kinds are system switches by decision (guide 16.12)" ;;
      *) s10_rerun S10.5 "the File types section holds no $f kind: the positive control does not hold"; return $S6_RC ;;
    esac
  done
  case "$(ax_elements < "$S10_DIR/new-dump-settings-indexing.txt" | awk -F'\t' '$2 ~ /^AXCheckBox/ && $3 == "Launch at login" { if ($2 ~ /AXSwitch/) s = 1; else p = 1 } END { print (p ? "plain" : (s ? "switch" : "absent")) }')" in
    switch) ;;
    plain) s6_why "new-dump-settings-indexing.txt holds Launch at login as a plain AXCheckBox: Launch at login is a system switch by decision (guide 16.15)" ;;
    *) s10_rerun S10.5 "the Indexing section holds no Launch at login checkbox: the positive control does not hold"; return $S6_RC ;;
  esac
  s10_done S10.5 "no dump of Setup (four steps), the panel, Settings (four sections) or the menu holds a switch role except the five File types kinds (Photos, PDFs, Documents, Audio and Video, as AXCheckBox/AXSwitch in the File types dump only) and Launch at login (as AXCheckBox/AXSwitch in the Indexing dump only), and the Folders step and the Folders section hold checkboxes"
}
check_S10_5() { s10_run s10_check_5; }

s10_labels() {
  ax_elements | awk -F'\t' '$3 != "" { print $2 "|" $3 }' | LC_ALL=C sort -u
}

s10_wait_flip() {
  local t0=$SECONDS st want="$2" ic rt
  ic=off; [ "${want%% *}" = 1 ] && ic=on
  rt=off; [ "${want##* }" = 1 ] && rt=on
  while :; do
    st="$(s10_ua_state)"
    [ "$st" = "$want" ] && return 0
    [ $((SECONDS - t0)) -ge "${S10_FLIP_WAIT:-600}" ] && break
    sleep 3
  done
  echo "CHECK $1 NEEDS-A-PERSON in System Settings, Accessibility, Display, set Increase Contrast $ic and Reduce Transparency $rt, then run this id again (they read \"$st\" now); the kit shoots and reads each of the four combinations in Light and Dark once they are set"
  S6_RC=0
  return 1
}

s10_check_6() {
  local combo look tag lost kept cur
  S10_ID=S10.6
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_drop
    S6_PLANTED="the first text taken out of every dump read under a setting"
  fi
  s10_golden_state S10.6 || return $S6_RC
  for combo in "0 0" "1 0" "0 1" "1 1"; do
    s10_wait_flip S10.6 "$combo" || return $S6_RC
    S10_COMBO="$combo"
    tag="$(printf '%s' "$combo" | tr -d ' ')"
    for look in light dark; do
      s10_look S10.6 "$look" || return $S6_RC
      s10_panel S10.6 || return $S6_RC
      s10_search S10.6 "a dog on the beach" || return $S6_RC
      s10_dump S10.6 panel || return $S6_RC
      cur="$(printf '%s\n' "$S6_DUMP" | s10_labels)"
      if [ "$combo" = "0 0" ]; then
        printf '%s\n' "$cur" > "$S10_DIR/ref-panel-$look"
      else
        lost="$(LC_ALL=C comm -23 "$S10_DIR/ref-panel-$look" <(printf '%s\n' "$cur") | head -2 | paste -sd';' -)"
        [ -z "$lost" ] || s6_why "an element of the panel is lost with Increase Contrast/Reduce Transparency at $combo ($look): $lost"
      fi
      s10_shot S10.6 "s10-6-$tag-$look" --panel || return $S6_RC
      pn_close_panel >/dev/null 2>&1
      s10_settings_open S10.6 || return $S6_RC
      s10_section S10.6 Folders || return $S6_RC
      s10_dump S10.6 settings || return $S6_RC
      cur="$(printf '%s\n' "$S6_DUMP" | s10_labels)"
      if [ "$combo" = "0 0" ]; then
        printf '%s\n' "$cur" > "$S10_DIR/ref-settings-$look"
      else
        lost="$(LC_ALL=C comm -23 "$S10_DIR/ref-settings-$look" <(printf '%s\n' "$cur") | head -2 | paste -sd';' -)"
        [ -z "$lost" ] || s6_why "an element of Settings is lost with Increase Contrast/Reduce Transparency at $combo ($look): $lost"
      fi
      s10_shot S10.6 "s10-6-$tag-$look-settings" || return $S6_RC
    done
  done
  s10_person "the 4.5 to 1 contrast of every text on its own surface in the shots shot-s10-6-* (panel with results and Settings, each combination, both looks) is the person's, and Setup step 2 under the two settings is read from the S10.2 shots after flipping them again"
  s10_done S10.6 ""
}
check_S10_6() { s10_run s10_check_6; }

s10_plant_names() {
  local d="$KIT_ROOT/fixtures/long-names" folder file
  folder="zqlongfolder$(printf '%0108d' 0 | tr 0 d)"
  file="zqlongfile$(printf '%0110d' 0 | tr 0 f)"
  [ -f "$KIT_ROOT/fixtures/golden/photos/beach-dog.jpg" ] || return 1
  mkdir -p "$d/$folder" && cp "$KIT_ROOT/fixtures/golden/photos/beach-dog.jpg" "$d/$folder/$file.jpg" || return 1
  S10_LONGDIR="$d/$folder"
  return 0
}

s10_ellipsis_place() {
  local needle="$1" place="$2" kind="${3:-any}" hit
  hit="$(printf '%s\n' "$S6_DUMP" | ax_ellipsis "$needle" | awk -F'\t' -v k="$kind" 'k == "any" || (k == "row" && $1 != "-" && $1 + 0 < 384) || (k == "pane" && $1 != "-" && $1 + 0 >= 384) { print; exit }')"
  [ -n "$hit" ] || S10_PLACES="${S10_PLACES:+$S10_PLACES, }$place"
  return 0
}

s10_check_7() {
  local out rc
  S10_ID=S10.7
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_overlap
    S6_PLANTED="a text added on top of the first text of every dump of the long-name places"
  fi
  s10_setup_state S10.7 || return $S6_RC
  s10_press S10.7 Next || return $S6_RC
  s10_plant_names || { s10_rerun S10.7 "the golden photo to copy under the 120-character names is missing"; return $S6_RC; }
  out="$(pick_folders "$S10_LONGDIR" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    s10_rerun S10.7 "the picker could not add the planted folder: $(s6_pick "$out")"
    return $S6_RC
  fi
  s10_step S10.7 2 read || return $S6_RC
  s10_layout "the Setup Folders row"
  s10_ellipsis_place zqlongfolder "the Setup Folders row"
  s10_golden_state S10.7 || return $S6_RC
  s10_plant_names || { s10_rerun S10.7 "the golden photo to copy under the 120-character names is missing"; return $S6_RC; }
  s10_settings_open S10.7 || return $S6_RC
  s10_section S10.7 Folders || return $S6_RC
  out="$(PK_WINDOW=settings pick_folders "$S10_LONGDIR" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    s10_rerun S10.7 "the picker could not add the planted folder in Settings: $(s6_pick "$out")"
    return $S6_RC
  fi
  s10_q "$S10_IX" wait done 7200 || { s10_rerun S10.7 "indexing did not reach done: $(s6_last "$S10_OUT")"; return $S6_RC; }
  s10_read S10.7 settings || return $S6_RC
  s10_layout "the Settings Folders row"
  s10_ellipsis_place zqlongfolder "the Settings Folders row"
  s10_panel S10.7 || return $S6_RC
  s10_search S10.7 zqlongfile || return $S6_RC
  s10_read S10.7 panel || return $S6_RC
  s10_need_name S10.7 zqlongfile || return $S6_RC
  s10_layout "the panel row and the preview"
  s10_ellipsis_place zqlongfile "the panel row" row
  s10_ellipsis_place zqlongfile "the preview" pane
  pn_close_panel >/dev/null 2>&1
  [ -z "$S10_PLACES" ] || s10_person "no dumped value ends in the ellipsis for $S10_PLACES: read it from the shot (a truncating text field reports its full string); no frame overlaps and none leaves its parent"
  s10_done S10.7 "a 120-character folder and file name overlap nothing and stay inside their parents in the Setup and Settings Folders rows, the panel row and the preview, and each ends in the ellipsis"
}
check_S10_7() { s10_run s10_check_7; }

s10_failure() {
  local w
  w="$(printf '%s\n' "$S6_DUMP" | ax_warnings)"
  if [ -z "$w" ]; then
    s6_why "$1 shows no Warning image next to a text (red text alone is not enough)"
  elif [ -n "$3" ] && ! printf '%s\n' "$w" | tr 'A-Z' 'a-z' | grep -qF "$(printf '%s' "$3" | tr 'A-Z' 'a-z')"; then
    s6_why "$1: the Warning image is not next to \"$3\""
  fi
  printf '%s\n' "$S6_DUMP" | ax_has_label "$2" || s6_why "$1 shows no next step line \"$2\""
  return 0
}

s10_check_8() {
  local support="$KIT_ROOT/home/Library/Application Support/Sesame" i t0 seen out rc
  S10_ID=S10.8
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_nowarning
    S6_PLANTED="the Warning image taken out of every dump"
  fi
  s10_golden_state S10.8 || return $S6_RC
  s10_panel S10.8 || return $S6_RC
  s10_q "$S10_LD" kill9 index || { s10_rerun S10.8 "the index helper could not be killed: $(s6_last "$S10_OUT")"; return $S6_RC; }
  kq "$S10_SR" "a dog on the beach" --keep-open >/dev/null 2>&1 </dev/null
  for ((i = 0; i < 6; i++)); do
    s10_dump S10.8 panel || return $S6_RC
    [ -z "$(printf '%s\n' "$S6_DUMP" | ax_warnings)" ] || break
    sleep "${S10_SETTLE:-1}"
  done
  s6_save s10-8-search
  s10_failure "the failed search" "Try typing again in a moment."
  pn_close_panel >/dev/null 2>&1
  [ -d "$support" ] || { s10_rerun S10.8 "the Sesame folder is missing: $support"; return $S6_RC; }
  s10_settings_open S10.8 || return $S6_RC
  s10_section S10.8 "File types" || return $S6_RC
  chmod a-w "$support" || { s10_rerun S10.8 "the Sesame folder could not be made read-only"; return $S6_RC; }
  S10_LOCKED="$support"
  s10_press S10.8 PDFs || return $S6_RC
  sleep "${S10_SETTLE:-1}"
  s10_dump S10.8 settings || return $S6_RC
  s6_save s10-8-save
  s10_undo
  s10_failure "the failed Settings save" "Try again in a moment."
  out="$(recipe_fresh_throttled 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe fresh-throttled: /'
  [ $rc = 0 ] || { s10_rerun S10.8 "recipe fresh-throttled: $(s6_pick "$out")"; return $S6_RC; }
  s10_q "$S10_MR" offline || { s10_rerun S10.8 "the mirror could not go offline: $(s6_last "$S10_OUT")"; return $S6_RC; }
  t0=$SECONDS; seen=""
  while :; do
    s10_dump S10.8 setup || return $S6_RC
    if printf '%s\n' "$S6_DUMP" | tr 'A-Z' 'a-z' | grep -qF "could not download the model"; then seen=1; break; fi
    [ $((SECONDS - t0)) -ge "${S10_DL_WAIT:-90}" ] && break
    sleep 2
  done
  [ -n "$seen" ] || { s10_rerun S10.8 "the Setup window shows no \"could not download the model\" within ${S10_DL_WAIT:-90} s of the mirror going offline"; return $S6_RC; }
  s6_save s10-8-download
  kq "$S10_MR" online >/dev/null 2>&1
  s10_failure "the failed model download" "Try again in a moment." "could not download the model"
  s10_done S10.8 "a failed search, a failed Settings save and a failed model download each show the Warning image next to a text and a next step line; the folder and the mirror are put back"
}
check_S10_8() { s10_run s10_check_8; }

s10_norm() {
  ax_elements | awk -F'\t' '$3 != "" || $4 != "" || $5 != "" { printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, (index($7, "D") ? "D" : "") }' | LC_ALL=C sort
}

s10_removal_allowed() {
  LC_ALL=C awk -F'\t' -v nm="$1" '
    function lo(s) { return tolower(s) }
    BEGIN { setup = (nm ~ /^dump-setup-[1-4]\.txt$/); welcome = (nm == "dump-setup-1.txt"); folders = (nm == "dump-setup-2.txt"); shortcut = (nm == "dump-setup-4.txt"); menu = (nm == "dump-menu.txt"); settings = (nm ~ /^dump-settings-(folders|file-types|search|indexing)\.txt$/); sfolders = (nm == "dump-settings-folders.txt"); sftypes = (nm == "dump-settings-file-types.txt"); ssearch = (nm == "dump-settings-search.txt"); sindexing = (nm == "dump-settings-indexing.txt") }
    settings && $1 == "AXCheckBox/AXToggle" && $2 == "About" && $5 == "0" { next }
    sindexing && $1 == "AXCheckBox" && $2 == "Launch at login" && $3 == "" && $4 == "" && ($5 == "1" || $5 == "0") && $6 == "" { next }
    ssearch && $1 == "AXStaticText" && $2 == "Keyboard shortcut" && $3 == "" && $4 == "" && $5 == "Control Option Space" && $6 == "" { next }
    sfolders && $1 == "AXButton" && ($2 == "Re-index" || $2 == "Remove") && $3 == "" && $4 != "" && $5 == "" && $6 == "" { next }
    sftypes && $1 == "AXCheckBox" && $2 ~ /^(Photos|PDFs|Documents|Audio|Video)$/ && $3 == "" && $4 == "" && ($5 == "1" || $5 == "0") && $6 == "" { next }
    menu && $1 ~ /^AXMenuItem/ && $6 == "D" && ($2 == "Ready" || $2 == "Pause indexing") { next }
    menu && $1 ~ /^AXMenuItem/ && $6 == "D" && $2 ~ /^Code: [0-9]+$/ { next }
    menu && $1 ~ /^AXMenuItem/ && $6 == "D" && index($2, "Last indexed: ") == 1 { next }
    folders && $1 ~ /^AXStaticText/ && ($2 ~ /^[0-9]+ files? in the ticked folders\.$/ || $2 ~ /^Photos: about [0-9]+(\.[0-9]+)? s each$/) { next }
    folders && $1 ~ /^AXButton/ && $2 == "Next" && $6 == "" { next }
    folders && $1 ~ /^AXButton/ && $2 == "Start indexing" && $6 == "D" { next }
    setup && $1 ~ /^AXStaticText/ && ($2 == "Step 1 of 4: Welcome" || $2 == "Step 2 of 4: Folders" || $2 == "Step 3 of 4: Permissions" || $2 == "Step 4 of 4: Shortcut") { next }
    setup && $1 ~ /^AXStaticText/ && ($2 == "The search model" || $2 == "The model is ready.") { next }
    setup && $1 ~ /^AXGroup/ && $2 == "Model download" { next }
    shortcut && $1 ~ /^AXStaticText/ && ($2 == "Open Sesame with" || $2 == "Control Option Space") { next }
    welcome && $1 ~ /^AXTextArea/ && $2 == "Welcome to Sesame" { next }
    welcome && $1 ~ /^AXScrollBar/ && $2 == "" && $6 == "D" { next }
    welcome && $1 ~ /^AXButton/ && $2 == "Back" && $6 == "D" { next }
    welcome && $1 ~ /^AXStaticText/ && ($2 == "Sesame finds files by what is inside them. Everything stays on this Mac." || $2 == "Nothing is read until you press Start indexing.") { next }
    lo($2) ~ /search my code|code folders|code editor|code search|no code folders|turn it on in settings/ { next }
    $3 ~ /code folder/ || $4 ~ /code folder/ { next }
    $1 ~ /^AXCheckBox/ && $2 == "Code" { next }
    $2 ~ /^Code [0-9]/ { next }
    $2 ~ /^code: / { next }
    $1 ~ /^AXStaticText/ && $2 ~ /•/ { next }
    $2 ~ /^Photos, PDFs, documents, code/ { next }
    $4 ~ /\/Developer\// { next }
    { print }'
}

s10_addition_allowed() {
  LC_ALL=C awk -F'\t' -v nm="$1" '
    BEGIN { setup = (nm ~ /^dump-setup-[1-4]\.txt$/); welcome = (nm == "dump-setup-1.txt"); folders = (nm == "dump-setup-2.txt"); shortcut = (nm == "dump-setup-4.txt"); menu = (nm == "dump-menu.txt"); sfolders = (nm == "dump-settings-folders.txt"); sftypes = (nm == "dump-settings-file-types.txt"); ssearch = (nm == "dump-settings-search.txt"); sindexing = (nm == "dump-settings-indexing.txt"); num ="([0-9]|[0-9][0-9]|[0-9][0-9][0-9])(,[0-9][0-9][0-9])*" }
    sindexing && $1 == "AXCheckBox/AXSwitch" && $2 == "Launch at login" && ($5 == "1" || $5 == "0") { next }
    sfolders && $1 ~ /^AXStaticText/ && ($2 == "Folders Sesame reads" || $2 == "Tick a folder to read it. Use the more button on a row to re-index or remove it.") { next }
    sfolders && $1 ~ /^(AXPopUpButton|AXMenuButton)/ && $2 ~ /^More actions for ./ { next }
    sftypes && $1 == "AXCheckBox/AXSwitch" && $2 ~ /^(Photos|PDFs|Documents|Audio|Video)$/ && ($5 == "1" || $5 == "0") { next }
    sftypes && $1 ~ /^AXStaticText/ && $2 == "File types Sesame reads" { next }
    ssearch && $1 == "AXGroup" && $2 == "Control Option Space" { next }
    menu && $1 ~ /^AXGroup/ && $2 ~ /^(Ready|Indexing( [0-9]+%)?|Paused|Downloading the model(, [0-9]+%)?|Model download failed)(, .+)?$/ { next }
    folders && $1 ~ /^AXStaticText/ && $2 ~ ("^" num " files? in " num " folders?$") { next }
    setup && $1 ~ /^AXGroup/ && ($2 == "Step 1 of 4: Welcome" || $2 == "Step 2 of 4: Folders" || $2 == "Step 3 of 4: Permissions" || $2 == "Step 4 of 4: Shortcut") { next }
    setup && $1 ~ /^AXStaticText/ && $2 == "Search model ready" { next }
    folders && $1 ~ /^AXButton/ && $2 == "Not now" { next }
    folders && $1 ~ /^AXButton/ && $2 == "Start indexing" && $6 == "" { next }
    folders && $1 ~ /^AXStaticText/ && ($2 == "Indexing starts when you press Start indexing, and runs in the background." || $2 == "Tick at least one folder to start.") { next }
    shortcut && $1 ~ /^AXStaticText/ && $2 == "Indexing is running. Watch it from the magnifier in the menu bar." { next }
    shortcut && $1 ~ /^AXStaticText/ && ($2 == "Open Sesame from anywhere" || $2 == "Press these keys together.") { next }
    shortcut && $1 ~ /^AXGroup/ && $2 == "Control Option Space" { next }
    welcome && $1 ~ /^AXStaticText/ && ($2 == "Welcome to Sesame" || $2 == "Search your files by what is inside them." || $2 == "Search by meaning" || $2 == "Type what a photo shows or what a document says." || $2 == "Private by design" || $2 == "Everything stays on this Mac." || $2 == "You choose when" || $2 == "Nothing is read until you press Start indexing.") { next }
    $2 == "↩ Open  ⌘↩ Reveal  ⌘C Copy  esc Close" { next }
    $1 ~ /^AXImage/ && $2 == "Warning" { next }
    $2 == "Try typing again in a moment." || $2 == "Try again in a moment." { next }
    $2 == "Open files with" { next }
    $2 == "where they talk about sleep" { next }
    $2 == "Photos, PDFs, documents, audio and video are read." { next }
    $1 ~ /^AXStaticText/ && ($2 == "Folders" || $2 == "File types" || $2 == "Search" || $2 == "Indexing") { next }
    $1 ~ /^AXStaticText/ && ($2 == "Desktop" || $2 == "Documents" || $2 == "Downloads" || $2 == "Removable volumes") { next }
    $1 ~ /^AXStaticText/ && ($2 == "Files on your Desktop" || $2 == "Files in your Documents folder" || $2 == "Files in your Downloads folder" || $2 == "USB drives and external disks") { next }
    $4 ~ /\/Developer\// { next }
    { print }'
}

s10_diff() {
  local name="$1" old="$2" new="$3" gone added stale
  gone="$(LC_ALL=C comm -23 <(s10_norm < "$old") <(s10_norm < "$new") | s10_removal_allowed "$name" | head -3 | awk -F'\t' '{ printf "%s- %s \"%s\"", (NR > 1 ? ", " : ""), $1, $2 }')"
  added="$(LC_ALL=C comm -13 <(s10_norm < "$old") <(s10_norm < "$new") | s10_addition_allowed "$name" | head -3 | awk -F'\t' '{ printf "%s+ %s \"%s\"", (NR > 1 ? ", " : ""), $1, $2 }')"
  [ -z "$gone" ] || s6_why "$name: the new dump lacks what the old one has: $gone"
  [ -z "$added" ] || s6_why "$name: the new dump has what the old one lacks: $added"
  if [ "$name" = dump-setup-4.txt ]; then
    stale="$(s10_norm < "$new" | awk -F'\t' '$1 ~ /^AXStaticText/ && ($2 == "Open Sesame with" || $2 == "Control Option Space") { printf "%s%s \"%s\"", (n++ ? ", " : ""), $1, $2 }')"
    [ -z "$stale" ] || s6_why "$name: the new dump still holds the old Shortcut text the keycaps replace: $stale"
  fi
  if [ "$name" = dump-setup-2.txt ]; then
    stale="$(s10_norm < "$new" | awk -F'\t' '$1 ~ /^AXButton/ && $2 == "Next" { n = 1 } $1 ~ /^AXButton/ && $2 == "Start indexing" { s = 1 } END { if (n && s) print "an AXButton \"Next\" beside the AXButton \"Start indexing\"" }')"
    [ -z "$stale" ] || s6_why "$name: the new dump holds $stale; the footer's right button is one view with one title (W22)"
  fi
  if [ "$name" = dump-settings-folders.txt ]; then
    stale="$(s10_norm < "$new" | awk -F'\t' '$1 ~ /^AXButton/ && ($2 == "Re-index" || $2 == "Remove") { printf "%s%s \"%s\"", (n++ ? ", " : ""), $1, $2 }')"
    [ -z "$stale" ] || s6_why "$name: the new dump still holds a row button the more menu replaces (W32): $stale"
  fi
  if [ "$name" = dump-settings-file-types.txt ]; then
    stale="$(s10_norm < "$new" | LC_ALL=C awk -F'\t' -v kinds="$S10_KINDS" '
      BEGIN { k = split(kinds, a, "|"); for (i = 1; i <= k; i++) { kind[a[i]] = 1; order[i] = a[i] } }
      ($2 in kind) && $1 == "AXCheckBox" { plain = plain (plain ? ", " : "") "AXCheckBox \"" $2 "\"" }
      ($2 in kind) && $1 == "AXCheckBox/AXSwitch" { sw[$2] = 1 }
      END {
        for (i = 1; i <= k; i++) if (!sw[order[i]]) miss = miss (miss ? ", " : "") order[i]
        if (plain) printf "a kind left as a plain checkbox (%s); ", plain
        if (miss) printf "no AXCheckBox/AXSwitch for %s; ", miss
      }')"
    [ -z "$stale" ] || s6_why "$name: the new dump holds ${stale}the five kinds are system switches by decision (guide 16.12)"
  fi
  if [ "$name" = dump-settings-indexing.txt ]; then
    stale="$(s10_norm < "$new" | awk -F'\t' '
      $2 == "Launch at login" && $1 == "AXCheckBox" { p++ }
      $2 == "Launch at login" && $1 == "AXCheckBox/AXSwitch" { s++ }
      END {
        if (p) printf "a plain AXCheckBox \"Launch at login\"; "
        if (s != 1) printf "%d AXCheckBox/AXSwitch lines \"Launch at login\" (one expected); ", s + 0
      }')"
    [ -z "$stale" ] || s6_why "$name: the new dump holds ${stale}Launch at login is a system switch by decision (guide 16.15)"
  fi
  if [ "$name" = dump-settings-search.txt ]; then
    stale="$(s10_norm < "$new" | awk -F'\t' '$2 == "Keyboard shortcut" || ($1 ~ /^AXStaticText/ && $2 == "Control Option Space") { printf "%s%s \"%s\"", (n++ ? ", " : ""), $1, $2 }')"
    [ -z "$stale" ] || s6_why "$name: the new dump still holds the old shortcut text the keycaps replace (W39): $stale"
    stale="$(ax_boxes < "$new" | awk -F'\t' '$3 ~ /^AXGroup/ && $4 == "Control Option Space" { g[$1] = 1 } ($2 in g) { k++ } END { if (k) printf "%d children inside the keycaps group", k }')"
    [ -z "$stale" ] || s6_why "$name: the new dump holds $stale; the keys are not accessibility elements (W39)"
  fi
  if [ "$name" = dump-menu.txt ]; then
    stale="$(s10_norm < "$new" | awk -F'\t' '$1 ~ /^AXMenuItem/ && $2 ~ /^(Pause indexing|Resume|Retry)/ && $6 == "D" { printf "%s%s \"%s\"", (n++ ? ", " : ""), $1, $2 }')"
    [ -z "$stale" ] || s6_why "$name: the new dump still holds a disabled action the tidy menu no longer draws (W19): $stale"
    stale="$(s10_norm < "$new" | awk -F'\t' '$1 ~ /^AXMenuItem/ && index(tolower($2), "last indexed") { printf "%s%s \"%s\"", (n++ ? ", " : ""), $1, $2 }')"
    [ -z "$stale" ] || s6_why "$name: the new dump still holds the Last indexed row the person removed because a long file name widens the menu (W60, guide 19): $stale"
  fi
  return 0
}

s10_check_9() {
  local before="${S10_BEFORE:-$KIT_PROJECT/.ril/evidence/ui/before}" f name old missing="" cut="" line
  S10_ID=S10.9
  if [ -n "$KIT_PLANT" ]; then
    S10_PLANT_FN=s10_plant_extra
    S6_PLANTED="a label added to every new dump"
  fi
  s10_collect S10.9 || return $S6_RC
  for f in "$S10_DIR"/new-dump-*.txt; do
    name="${f##*/new-}"
    line="$(grep -m1 '^(tree cut at ' "$f")"
    [ -z "$line" ] || s6_why "$name: the new dump holds \"$line\""
    old="$before/$name"
    if [ ! -f "$old" ]; then missing="${missing:+$missing, }$name"; continue; fi
    if grep -q '^(tree cut at ' "$old"; then cut="${cut:+$cut, }$name"; continue; fi
    s10_diff "$name" "$old" "$f"
  done
  [ -z "$missing" ] || s10_person "the old dumps are missing under $before: $missing; the controller takes them from the kept old bundle with the old kit (plan 8 t10, P2)"
  [ -z "$cut" ] || s10_person "the old dumps were cut at their own limit and cannot be compared: $cut"
  s10_done S10.9 "the new dumps of Setup, the panel, Settings and the menu equal the old ones after the frame filter except the allowed removals and additions, and none was cut"
}
check_S10_9() { s10_run s10_check_9; }

S9_IX="$KIT_SCRIPTS/kit-index.sh"
S9_SR="$KIT_SCRIPTS/kit-search.sh"
S9_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S9_REPOS="api-client legacy-sync scratch-lab"
S9_DEFS="api-client|retry.swift api-client|auth.swift legacy-sync|merge.swift scratch-lab|dates.swift"
S9_KINDS="Audio Documents PDFs Photos Video"
S9_OUT=""
S9_TAINT=""

s9_rerun() {
  echo "RERUN $1 not valid: $2"
  S6_RC=4
  return 1
}

s9_q() {
  local out rc
  out="$(kq "$@" 2>&1 </dev/null)"; rc=$?
  S9_OUT="$out"
  [ $rc = 0 ] && return 0
  printf '%s\n' "$out" | awk -v p="  | ${1##*/} ${2:-} exited $rc: " '{ print p $0 }'
  return $rc
}

s9_dump() {
  local out rc
  out="$(KIT_NO_EVIDENCE=1 kit_timeout 30 "$S6_AX" dump "$2" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | awk -v p="  | kit-ax.sh dump $2 exited $rc: " '{ print p $0 }'
    s9_rerun "$1" "kit-ax.sh dump $2 exited $rc"
    return 1
  fi
  S6_DUMP="$out"
  if [ -n "$S9_TAINT" ] && [ -n "$KIT_PLANT" ]; then
    S6_DUMP="$S6_DUMP"$'\n''  AXStaticText label="Search my code"'
  fi
  return 0
}

s9_code_hits() {
  ax_elements | awk -F'\t' '
    {
      n++; role[n] = $2; f[n, 1] = $3; f[n, 2] = $4; f[n, 3] = $5; f[n, 4] = $6
      if ($2 ~ /^AXCheckBox/ && substr($5, 1, 1) == "/") {
        p = $5; sub(/\/+$/, "", p)
        m = split(p, seg, "/")
        ownpath[tolower(p)] = 1
        if (seg[m] != "") ownname[tolower(seg[m])] = 1
      }
    }
    END {
      for (i = 1; i <= n; i++) for (k = 1; k <= 4; k++) {
        t = tolower(f[i, k])
        for (o in ownpath) while ((j = index(t, o)) > 0) t = substr(t, 1, j - 1) substr(t, j + length(o))
        for (o in ownname) while ((j = index(t, o)) > 0) t = substr(t, 1, j - 1) substr(t, j + length(o))
        if (index(t, "code") > 0) printf "%s\t%s\t%s\n", role[i], (k == 1 ? "label" : (k == 2 ? "desc" : (k == 3 ? "help" : "value"))), f[i, k]
      }
    }'
}

s9_hits() {
  local hits
  hits="$(printf '%s\n' "$S6_DUMP" | s9_code_hits | head -3 | awk -F'\t' '{ printf "%s%s %s \"%s\"", (NR > 1 ? ", " : ""), $1, $2, $3 }')"
  [ -z "$hits" ] || s6_why "$1 shows code wording: $hits"
  return 0
}

s9_errors() {
  local w
  if [ "${2:-}" = panel ]; then
    for w in "Could not search just now" "Try typing again in a moment."; do
      if printf '%s\n' "$S6_DUMP" | ax_has_label "$w"; then
        s6_why "$1 shows error text (\"$w\")"
        return 0
      fi
    done
    return 0
  fi
  for w in "error" "may be missing" "went wrong"; do
    if s6_has_ci "$w"; then
      s6_why "$1 shows error text (\"$w\")"
      return 0
    fi
  done
  return 0
}

s9_sections() {
  local id="$1" hook="$2" sec msg out rc
  out="$(settings_open 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    s9_rerun "$id" "the Settings window did not open: $(s6_last "$out")"
    return 1
  fi
  for sec in Folders "File types" Search Indexing; do
    msg="$(settings_section "$sec")" || {
      printf '%s\n' "$msg" | sed 's/^/  | /'
      s9_rerun "$id" "the $sec section of Settings did not open"
      return 1
    }
    s9_dump "$id" settings || return 1
    s6_save "s9-settings-$(printf '%s' "$sec" | tr ' ' '-')"
    s9_hits "Settings $sec"
    "$hook" "$sec" || return 1
  done
  return 0
}

s9_setup_state() {
  local out rc
  out="$(recipe_setup 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe setup: /'
  [ $rc = 0 ] || { s9_rerun "$1" "recipe setup: $(s6_pick "$out")"; return 1; }
  s9_q "$S9_FX" build repos || { s9_rerun "$1" "kit-fixtures.sh build repos exited $?"; return 1; }
  return 0
}

s9_tree_state() {
  local out rc tmp tick
  tmp="$(mktemp "${TMPDIR:-/tmp}/s9-tree.XXXXXX")" || { s9_rerun "$1" "no scratch file for the recipe tree output"; return 1; }
  ( n=0; while :; do sleep 1; n=$((n + 1)); [ $((n % ${S9_TICK:-60})) = 0 ] && echo "recipe tree: still running after $n s"; done ) &
  tick=$!
  tree_need "$1" >"$tmp" 2>&1; rc=$?
  kill "$tick" 2>/dev/null
  wait "$tick" 2>/dev/null
  out="$(cat "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$out" | sed 's/^/recipe tree: /'
  [ $rc = 0 ] || { s9_rerun "$1" "recipe tree: $(s6_pick "$out")"; return 1; }
  s9_q "$S9_IX" wait done 7200 || { s9_rerun "$1" "indexing did not reach done: $(s6_last "$S9_OUT")"; return 1; }
  out="$(wait_menu_ready 120 2>&1)"; rc=$?
  [ $rc = 0 ] || { printf '%s\n' "$out" | sed 's/^/  | /'; s9_rerun "$1" "the menu bar never said Ready"; return 1; }
  return 0
}

s9_golden_state() {
  local out rc
  out="$(golden_need 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe golden: /'
  [ $rc = 0 ] || { s9_rerun "$1" "recipe golden: $(s6_pick "$out")"; return 1; }
  return 0
}

s9_step() {
  local id="$1" n="$2" name="$3" i
  for ((i = 0; i < 4; i++)); do
    s9_dump "$id" setup || return 1
    if printf '%s\n' "$S6_DUMP" | ax_has_label "Step $n of 4: $name"; then
      s6_save "s9-1-step-$n"
      s9_hits "Setup step $n ($name)"
      return 0
    fi
    sleep 1
  done
  s9_rerun "$id" "the Setup window shows no \"Step $n of 4: $name\""
  return 1
}

s9_next() {
  local b="Next"
  printf '%s\n' "$S6_DUMP" | ax_has_label "Next" || b="Not now"
  s6_press "$S6_AX" "$b" && return 0
  s9_rerun "$1" "pressing $b in the Setup window failed"
  return 1
}

s9_check_1() {
  local f out rc
  if [ -n "$KIT_PLANT" ]; then
    S9_TAINT=1
    S6_PLANTED="a label \"Search my code\" added to every Setup dump"
  fi
  s9_setup_state S9.1 || return $S6_RC
  s9_step S9.1 1 Welcome || return $S6_RC
  s9_next S9.1 || return $S6_RC
  out="$(pick_folders "$KIT_ROOT/home/Developer/api-client" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    s9_rerun S9.1 "the picker could not add api-client: $(s6_pick "$out")"
    return $S6_RC
  fi
  s9_step S9.1 2 Folders || return $S6_RC
  printf '%s\n' "$S6_DUMP" | ax_has_label "Start indexing" || { s9_rerun S9.1 "the Folders step shows no Start indexing footer button (a whole model shows it; a model that is not whole shows Next)"; return $S6_RC; }
  [ -n "$(printf '%s\n' "$S6_DUMP" | ax_folders)" ] || { s9_rerun S9.1 "the Folders step lists no folder row"; return $S6_RC; }
  printf '%s\n' "$S6_DUMP" | ax_row api-client >/dev/null || { s9_rerun S9.1 "the Folders step lists no row for api-client after the picker added it"; return $S6_RC; }
  for f in legacy-sync scratch-lab; do
    if printf '%s\n' "$S6_DUMP" | ax_row "$f" >/dev/null; then s6_why "the Folders step lists a row for $f: no repo is suggested"; fi
  done
  for f in $S6B_FOLDERS; do
    s6b_row_counts S9.1 "folder" "$f" "$KIT_ROOT/home/$f"
  done
  s6b_row_counts S9.1 "picked repo" api-client "$KIT_ROOT/home/Developer/api-client"
  s9_next S9.1 || return $S6_RC
  s9_step S9.1 3 Permissions || return $S6_RC
  s9_next S9.1 || return $S6_RC
  s9_step S9.1 4 Shortcut || return $S6_RC
  s6_done S9.1 "the four Setup steps show no code wording, the Folders step lists Desktop, Documents, Downloads, Pictures and Movies with their counts and api-client with its documents and picture and no code, and Start indexing is there as the footer button of the Folders step and was never pressed"
}
check_S9_1() { s6_run s9_check_1; }

s9_section_2() {
  local detail n got
  case "$1" in
    Folders)
      printf '%s\n' "$S6_DUMP" | ax_row api-client >/dev/null || { s9_rerun S9.2 "Settings lists no row for api-client (the recipe tree picks the golden repos)"; return 1; }
      s6b_row_counts S9.2 "Folders row" api-client "$KIT_ROOT/home/Developer/api-client"
      detail="$(s6b_detail api-client)"
      case "$(printf '%s' "$detail" | tr 'A-Z' 'a-z')" in *"not read yet"*) s6_why "the api-client row says \"not read yet\"" ;; esac
      if printf '%s' "$detail" | grep -Eiq '[0-9][0-9.,]* ?(bytes?|kb|mb|gb|tb)([^a-z]|$)'; then s6_why "the api-client row shows a size (\"$detail\")"; fi ;;
    "File types")
      got="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$2 ~ /^AXCheckBox/ && !($2 == "AXCheckBox/AXToggle" && $3 ~ /^(Folders|File types|Search|Indexing)$/) { print $3 }' | LC_ALL=C sort | paste -sd' ' -)"
      [ "$got" = "$S9_KINDS" ] || s6_why "File types lists \"$got\", not exactly Audio, Documents, PDFs, Photos and Video" ;;
    Search)
      n="$(printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$2 ~ /^AXPopUpButton/ { n++ } END { print n + 0 }')"
      [ "$n" = 2 ] || s6_why "Search has $n open-with pop-ups, not 2" ;;
  esac
  return 0
}

s9_check_2() {
  if [ -n "$KIT_PLANT" ]; then
    S9_TAINT=1
    S6_PLANTED="a label \"Search my code\" added to every Settings dump"
  fi
  s9_tree_state S9.2 || return $S6_RC
  s9_sections S9.2 s9_section_2 || return $S6_RC
  s6_done S9.2 "the four Settings sections show no code wording, File types lists exactly Photos, PDFs, Documents, Audio and Video, Search has two open-with pop-ups, and the api-client row shows counts and a time with no size and no \"not read yet\""
}
check_S9_2() { s6_run s9_check_2; }

s9_check_3() {
  local counts
  if [ -n "$KIT_PLANT" ]; then
    S9_TAINT=1
    S6_PLANTED="a label \"Search my code\" added to the menu dump"
  fi
  s9_tree_state S9.3 || return $S6_RC
  s9_dump S9.3 menu || return $S6_RC
  s6_save s9-3-menu
  printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' 'tolower($3) ~ /^(ready|indexing|paused|downloading|not ready)/ { f = 1 } END { exit f ? 0 : 1 }' || { s9_rerun S9.3 "the menu dump holds no status line"; return $S6_RC; }
  counts="$(S7_MENU="$S6_DUMP" s7_menu_counts | awk 'END { print NR + 0 }')"
  [ "$counts" -ge 2 ] || { s9_rerun S9.3 "the menu dump holds $counts counts lines, the control needs at least 2"; return $S6_RC; }
  s9_hits "The menu"
  s6_done S9.3 "the menu holds its status line and $counts counts lines and no item with code in it"
}
check_S9_3() { s6_run s9_check_3; }

s9_search() {
  s9_q "$S9_SR" "$2" --keep-open || { s9_rerun "$1" "kit-search.sh \"$2\" failed: $(s6_last "$S9_OUT")"; return 1; }
  return 0
}

s9_box() {
  printf '%s\n' "$S9_OUT" | awk '/^search box / { i = index($0, "value=\""); v = substr($0, i + 7); sub(/"$/, "", v); print v; exit }'
}

s9_rows_n() { printf '%s\n' "$S9_OUT" | awk '$1 == "rows" { print $2; exit }'; }

s9_rows_why() {
  local bad
  bad="$(printf '%s\n' "$S9_OUT" | awk '$1 == "row"' | code_ext_rows | head -2 | tr '\n' ';')"
  [ -z "$bad" ] || s6_why "$1 lists a code file: $bad"
  return 0
}

s9_banned() {
  local w
  for w in "code search" "no code folders" "turn it on in settings"; do
    if s6_has_ci "$w"; then s6_why "$1: the panel shows \"$w\""; fi
  done
  return 0
}

s9_check_4() {
  local qa="code: retry a failed call" qb="code: qwv zzkx lorp mnb" qc="code:" qd="code: a dog on the beach" v n s w save rc
  if [ -n "$KIT_PLANT" ]; then
    qa="code: Code search is off"
    qd="code: zzkx lorp qwv"
    S6_PLANTED="the text typed for the first search holds the words Code search, and the code: control types text that names no photo"
  fi
  s9_golden_state S9.4 || return $S6_RC
  s9_search S9.4 "a dog on the beach" || return $S6_RC
  case "$S9_OUT" in *beach-dog.jpg*) ;; *) s9_rerun S9.4 "the plain search \"a dog on the beach\" lists no photos/beach-dog.jpg: the method is broken"; return $S6_RC ;; esac
  s9_search S9.4 "$qd" || return $S6_RC
  case "$S9_OUT" in *beach-dog.jpg*) ;; *) s6_why "typing \"$qd\" lists no photos/beach-dog.jpg: the text after code: is not searched like any other text" ;; esac
  s9_search S9.4 "$qa" || return $S6_RC
  s9_dump S9.4 panel || return $S6_RC
  s6_save s9-4-code-prefix
  s9_banned "typing \"$qa\""
  s9_rows_why "typing \"$qa\""
  v="$(s9_box)"
  [ "$v" = "$qa" ] || s6_why "typing \"$qa\" left \"$v\" in the box"
  s9_search S9.4 "$qb" || return $S6_RC
  s9_dump S9.4 panel || return $S6_RC
  s6_save s9-4-no-match
  s9_banned "typing \"$qb\""
  n="$(s9_rows_n)"
  [ "${n:-x}" = 0 ] || s6_why "typing \"$qb\" lists ${n:-no} rows instead of none"
  s6_has "No matches" || s6_why "typing \"$qb\" shows no \"No matches\""
  s6_has_ci "describe what is in the file" || s6_why "the hint for \"$qb\" does not say to describe what is in the file"
  s6_has_ci "type part of its exact name or text" || s6_why "the hint for \"$qb\" does not say to type part of its exact name or text"
  s9_search S9.4 "$qc" || return $S6_RC
  s9_dump S9.4 panel || return $S6_RC
  s6_save s9-4-prefix-alone
  v="$(s9_box)"
  [ "$v" = "$qc" ] || s6_why "typing \"$qc\" left \"$v\" in the box"
  if printf '%s\n' "$S6_DUMP" | ax_elements | awk -F'\t' '$2 ~ /^AXGroup/ && $3 == "Search hint" { f = 1 } END { exit f ? 0 : 1 }'; then
    s6_why "typing \"$qc\" shows the Search hint group"
  fi
  save="$IFS"; IFS='|'
  for s in $NR_SAMPLES; do
    if s6_has "$s"; then s6_why "typing \"$qc\" shows the sample \"$s\""; fi
  done
  IFS="$save"
  pn_open_panel; rc=$?
  if [ $rc != 0 ]; then
    printf '%s\n' "$PN_OUT" | sed 's/^/  | /'
    s9_rerun S9.4 "the panel did not open for the empty box: $(printf '%s' "$PN_OUT" | sed -n 1p)"
    return $S6_RC
  fi
  s9_dump S9.4 panel || return $S6_RC
  s6_save s9-4-empty-box
  PN_DUMP="$S6_DUMP"
  w="$(nr_hint_why "an empty box" | sed '/^extra:/d')"
  [ -z "$w" ] || s6_why "$w"
  s6_done S9.4 "code: text is plain text: no code notice, a no-match shows No matches with its hint, code: alone leaves its value and shows no hint, and the empty box shows the three samples"
}
check_S9_4() { s6_run nr_run s9_check_4; }

s9_names() {
  local pair
  for pair in $S9_DEFS; do
    awk -F'\t' -v r="${pair%%|*}" -v f="${pair#*|}" '$1 == "def" && $2 == r && $3 == f { print $4; exit }' "$KIT_LIB/repos.tsv"
  done
}

s9_check_5() {
  local CODE_EXTS="$CODE_EXTS" f rows word q d
  if [ -n "$KIT_PLANT" ]; then
    CODE_EXTS="$CODE_EXTS md png"
    S6_PLANTED="md and png counted as code extensions, so the picked repos' documents and pictures read as code files"
  fi
  s9_tree_state S9.5 || return $S6_RC
  for f in api-client/docs/retry-notes.md api-client/docs/retry-diagram.png legacy-sync/docs/diagram.png; do
    s9_q "$S9_IX" has "$KIT_ROOT/home/Developer/$f" || { s9_rerun S9.5 "$f is not in the index: the method is broken"; return $S6_RC; }
  done
  q="$(awk -F, '$2 == "repodoc" { print $3; exit }' "$KIT_PROJECT/fixtures/answers.csv")"
  s9_search S9.5 "$q" || return $S6_RC
  for f in retry-notes.md retry-diagram.png; do
    case "$S9_OUT" in *"$f"*) ;; *) s9_rerun S9.5 "the search \"$q\" does not list $f: the method is broken"; return $S6_RC ;; esac
  done
  d="$(awk -F'\t' '$1 == "picture" && $2 == "legacy-sync" { print $4; exit }' "$KIT_LIB/repos.tsv")"
  s9_search S9.5 "$d" || return $S6_RC
  case "$S9_OUT" in *diagram.png*) ;; *) s9_rerun S9.5 "the search \"$d\" does not list diagram.png: the method is broken"; return $S6_RC ;; esac
  for f in $S9_REPOS; do
    s9_q "$S9_IX" under "$KIT_ROOT/home/Developer/$f" || { s9_rerun S9.5 "kit-index.sh under $f exited $?"; return $S6_RC; }
    rows="$(printf '%s\n' "$S9_OUT" | code_ext_rows | head -3 | tr '\n' ';')"
    [ -z "$rows" ] || s6_why "kit-index.sh lists a code file under $f: $rows"
  done
  s9_q "$S9_IX" under "$KIT_ROOT/fixtures/matrix" || { s9_rerun S9.5 "kit-index.sh under the matrix exited $?"; return $S6_RC; }
  case "$S9_OUT" in *extdoc/txt_zq1201.txt*) ;; *) s9_rerun S9.5 "kit-index.sh under the matrix lists no extdoc/txt_zq1201.txt: the index holds no extension cell, the method is broken"; return $S6_RC ;; esac
  rows="$(printf '%s\n' "$S9_OUT" | code_ext_rows | head -3 | tr '\n' ';')"
  [ -z "$rows" ] || s6_why "kit-index.sh lists a code file under the extension cells: $rows"
  for word in $(s9_names); do
    for q in "$word" "code: $word"; do
      s9_search S9.5 "$q" || return $S6_RC
      s9_rows_why "the search \"$q\""
    done
  done
  s6_done S9.5 "no row of the three picked repos or the extension cells has a code extension, no search for a function name returns a code path, and docs/retry-notes.md, docs/retry-diagram.png and docs/diagram.png are in the index and found by their description"
}
check_S9_5() { s6_run nr_run s9_check_5; }

s9_section_6() {
  s9_errors "Settings $1"
  return 0
}

s9_check_6() {
  local sup="$KIT_ROOT/home/Library/Application Support/Sesame" before f word rows
  if [ -n "$KIT_PLANT" ]; then
    S9_TAINT=1
    S6_PLANTED="a label \"Search my code\" added to every Settings dump"
  fi
  if [ ! -f "$sup/index.sqlite" ] || [ ! -f "$sup/settings.json" ]; then
    echo "CHECK S9.6 NEEDS-A-PERSON the old build left no index and settings.json in the kit home: the controller makes them with the old kit and the kept bundle (batch S9, first line), then runs kit-run.sh prep upgrade"
    return 0
  fi
  [ "$(head -1 "$KIT_ROOT/run/recipe" 2>/dev/null)" = upgrade ] || { s9_rerun S9.6 "the state is not the recipe upgrade: run kit-run.sh prep upgrade first"; return $S6_RC; }
  before="$(cat "$KIT_ROOT/run/upgrade-code-rows" 2>/dev/null)"
  case "$before" in
    ""|*[!0-9]*) s9_rerun S9.6 "run/upgrade-code-rows holds no number: prep upgrade writes it"; return $S6_RC ;;
  esac
  [ "$before" -gt 0 ] || { s9_rerun S9.6 "the old index held no code row before the new build opened it, so a clean index now proves nothing"; return $S6_RC; }
  case "$(cat "$KIT_ROOT/run/upgrade-old-settings" 2>/dev/null)" in
    *codeSearchOn*) ;;
    *) s9_rerun S9.6 "the old settings.json held no codeSearchOn: it was not made by the old build"; return $S6_RC ;;
  esac
  s9_q "$S9_IX" wait walked 600 || { s9_rerun S9.6 "the first walk did not finish: $(s6_last "$S9_OUT")"; return $S6_RC; }
  s9_sections S9.6 s9_section_6 || return $S6_RC
  s9_dump S9.6 menu || return $S6_RC
  s6_save s9-6-menu
  s9_hits "The menu"
  s9_errors "The menu"
  word="$(s9_names | sed -n 1p)"
  s9_search S9.6 "$word" || return $S6_RC
  s9_rows_why "the search \"$word\""
  s9_dump S9.6 panel || return $S6_RC
  s6_save s9-6-panel
  s9_errors "The panel" panel
  for f in $S9_REPOS; do
    s9_q "$S9_IX" under "$KIT_ROOT/home/Developer/$f" || { s9_rerun S9.6 "kit-index.sh under $f exited $?"; return $S6_RC; }
    rows="$(printf '%s\n' "$S9_OUT" | code_ext_rows | head -3 | tr '\n' ';')"
    [ -z "$rows" ] || s6_why "kit-index.sh still lists a code row under $f: $rows"
  done
  echo "  | the Setup window is not shown after Finish: S9.1 reads Setup; here Settings, the menu and the panel were read"
  s6_done S9.6 "the old index (with $before code rows) and the old settings opened in the new build with no reset: Settings, the menu and the panel show no code and no error, no result row is code, and after the first walk the index holds no code row"
}
check_S9_6() { s6_run nr_run s9_check_6; }

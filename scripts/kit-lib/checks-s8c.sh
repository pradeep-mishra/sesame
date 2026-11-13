#!/bin/bash
# The slice 3 checks S8.5 and S8.6 of S8 (feature map S8, (b) Only the right ones; plan-3-tasks t10). Sourced by kit-run.sh after
# common.sh and recipes.sh (its checks-*.sh glob), never run. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line
# and uses the exit codes of every kit script; a precondition that does not hold prints `RERUN <id> not valid: <reason>` and returns 4.
# Both start the same way (t8, t9): `tree_need <id>` (the S8 session of the recipe `tree`, started when none ran), `kit-index.sh
# wait done 900` and `wait_menu_ready 120`. Neither closes the window: they call tree_need only, never s8_close_window, so they run
# inside the observed window when they are called before the first reader (S8.1, S8.2, S8.3 close it). They search the panel through
# kit-search.sh and read the index with kit-index.sh; they press nothing else, open no result and write nothing but their result file.
# Every expected value comes from the hand-written tables of scripts/kit-lib: gate-matrix.csv, tree.tsv, extensions.txt (the kind of
# an extension), read-kinds.txt (the kinds a reader reads at this slice) and `kit-fixtures.sh expect`. A file of an extension no list
# names is of the kind `unsupported`: no reader reads it at any slice, so it is checked, never skipped.
# With KIT_PLANT=1 (kit-run.sh --plant S8.5) S8.5 hides one expected cell from its reading of the index (kit-index.sh is not
# changed) and must print `CHECK S8.5 FAIL planted: ...`.

# s8c_kind_of <path> : the kind of a file by its extension, as extensions.txt lists it, else `unsupported` (a leading dot is no
# extension: a name such as .env_zq0033 has none). The file itself is never read.
s8c_kind_of() {
  awk -v p="$1" -v ext="$KIT_LIB/extensions.txt" 'BEGIN {
    while ((getline line < ext) > 0) {
      if (line ~ /^#/ || line == "") continue
      split(line, a, ": ")
      n = split(a[2], e, " ")
      for (i = 1; i <= n; i++) kind[e[i]] = a[1]
    }
    base = p; sub(/.*\//, "", base)
    x = ""
    if (match(base, /.\.[^.]+$/)) x = tolower(substr(base, RSTART + 2))
    print ((x in kind) ? kind[x] : "unsupported")
  }'
}

s8c_query() { printf '%s\n' "$2"; }

# s8c_read_kind <kind> : status 0 when read-kinds.txt lists the kind (a reader reads it at this slice).
s8c_read_kind() { awk -v k="$1" '$1 == k { f = 1 } END { exit f ? 0 : 1 }' "$KIT_LIB/read-kinds.txt"; }

# s8c_stem <path> : the file name without its extension (the unique name token the panel's name passage holds).
s8c_stem() { printf '%s\n' "${1##*/}" | awk '{ s = $0; if (match(s, /.\.[^.]+$/)) s = substr(s, 1, RSTART); print s }'; }

# s8c_token <path> : the unique zq token of the file name, lower case (written in a text, or drawn into a picture for text
# recognition); nothing when the name has none.
s8c_token() { printf '%s\n' "${1##*/}" | awk '{ s = tolower($0); if (match(s, /zq[0-9][0-9][0-9][0-9]/)) print substr(s, RSTART, RLENGTH) }'; }

# s8c_lines_naming <name> : stdin lines; prints how many hold the name as a whole name (no letter, digit, _ or - before it, and no
# letter, digit, _, . or - after it), so that README never matches README.md.
s8c_lines_naming() {
  awk -v b="$1" '{
    t = $0; s = 1
    while ((i = index(substr(t, s), b)) > 0) {
      p = s + i - 1
      pre = (p > 1) ? substr(t, p - 1, 1) : " "
      post = substr(t, p + length(b), 1)
      if (pre !~ /[A-Za-z0-9_-]/ && post !~ /[A-Za-z0-9_.-]/) { n++; break }
      s = p + 1
    }
  }
  END { print n + 0 }'
}

S8C_OUT=""

# s8c_search <id> <text> : one search through the panel (kit-search.sh types it as a person does and prints the list). The output
# is kept in S8C_OUT. Status 0 done; 3 a person step (printed); 4 the search could not be made (the RERUN line is printed).
s8c_search() {
  local rc
  S8C_OUT="$(kq "$KIT_SCRIPTS/kit-search.sh" "$2" 2>&1 </dev/null)"; rc=$?
  case $rc in
    0) return 0 ;;
    3) printf '%s\n' "$S8C_OUT"; return 3 ;;
    *) echo "RERUN $1 not valid: the search \"$2\" could not be made (kit-search.sh exited $rc): $(printf '%s\n' "$S8C_OUT" | tail -1)"; return 4 ;;
  esac
}

# s8c_rows_named <file name> : how many result rows of the last search hold that file name as a whole name.
s8c_rows_named() { printf '%s\n' "$S8C_OUT" | awk '$1 == "row"' | s8c_lines_naming "$1"; }

# s8c_settings_open : status 0 once the Settings window answers (kit-ax.sh dump settings), opened from the status item's menu when
# it does not; 3 a person step (printed); 1 it never did (one line says why).
s8c_settings_open() {
  local out rc i
  for ((i = 1; i <= 8; i++)); do
    out="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump settings 2>&1 </dev/null)"; rc=$?
    [ $rc = 0 ] && return 0
    if [ $rc = 3 ]; then printf '%s\n' "$out"; return 3; fi
    [ $i != 1 ] || kq "$KIT_SCRIPTS/kit-ax.sh" click "Settings…" >/dev/null 2>&1
    sleep 1
  done
  echo "no Settings window: kit-ax.sh dump settings said \"$(printf '%s\n' "$out" | tail -1)\""
  return 1
}

# s8c_section_dump <section> : stdout the Settings window's tree with that section selected (a section that is not selected is not
# in the tree). Status 0; 1 and one line when the section cannot be opened or the tree cannot be read.
s8c_section_dump() {
  local msg
  msg="$(settings_section "$1")" || { echo "$msg"; return 1; }
  kq "$KIT_SCRIPTS/kit-ax.sh" dump settings 2>&1 </dev/null
}

# s8c_roots <pick list> : the folders the Settings window lists under fixtures/matrix equal the matrix/ entries of the pick list,
# exactly (an extra, a missing or a child spelling of a root is a difference). Prints the difference, or one line when equal.
# Status 0 equal; 1 they differ; 3 a person step; 4 the list could not be read (one line says why).
s8c_roots() {
  local list="$1" rc mroot want got extra missing dump msg diff=""
  s8c_settings_open; rc=$?
  if [ $rc != 0 ]; then [ $rc = 3 ] && return 3; return 4; fi
  msg="$(settings_section Folders)" || { echo "the Settings window cannot be put on its Folders section: $msg"; return 4; }
  dump="$(kq "$KIT_SCRIPTS/kit-ax.sh" dump settings 2>&1 </dev/null)" || { echo "kit-ax.sh dump settings said \"$(printf '%s\n' "$dump" | tail -1)\""; return 4; }
  mroot="$(real_path "$KIT_ROOT/fixtures/matrix")"
  [ -n "$mroot" ] || { echo "there is no matrix folder under $KIT_ROOT/fixtures"; return 4; }
  want="$(printf '%s\n' "$list" | awk -v r="$mroot" 'index($0, "matrix/") == 1 { print r "/" substr($0, 8) }' | sort -u)"
  got="$(printf '%s\n' "$dump" | ax_folders | awk -v r="$mroot/" 'index($0, r) == 1' | sort -u)"
  extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed "s|^$mroot/|matrix/|")"
  missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed "s|^$mroot/|matrix/|")"
  [ -z "$extra" ] || diff="extra: $(printf '%s' "$extra" | tr '\n' ' ')"
  [ -z "$missing" ] || diff="${diff:+$diff; }missing: $(printf '%s' "$missing" | tr '\n' ' ')"
  if [ -n "$diff" ]; then echo "$diff"; return 1; fi
  echo "the Settings list holds exactly the $(printf '%s\n' "$want" | awk 'NF { n++ } END { print n + 0 }') matrix/ roots of the pick list"
  return 0
}

# s8c_repo_cells <id> : the golden repo cells of repo-cells.tsv (the two repos of home/Developer, picked by the recipe tree): each file the table lists
# as in the index is in the index, each one it lists as not in the index is not (kit-index.sh has, the absolute path). One line a cell. A wrong file
# adds the cell to S8C_RED; S8C_REPOS counts the cells read. Status 0; 3 a person is needed; 4 not valid.
S8C_REPOS=0
s8c_repo_cells() {
  local id="$1" tsv="$KIT_LIB/repo-cells.tsv" cell folder ins outs f hrc hout bad nin nout
  S8C_REPOS=0
  [ -f "$tsv" ] || { echo "RERUN $id not valid: no table: $tsv"; return 4; }
  while IFS=$'\t' read -r cell folder ins outs <&3; do
    case "$cell" in ""|"#"*) continue ;; esac
    bad=""; nin=0; nout=0
    for f in $(printf '%s' "$ins" | tr ',' ' '); do
      hout="$(kq "$KIT_SCRIPTS/kit-index.sh" has "$KIT_ROOT/home/Developer/$folder/$f" 2>&1 </dev/null)"; hrc=$?
      case $hrc in
        0) nin=$((nin + 1)) ;;
        1) bad="$bad $f (listed as in the index, is not)" ;;
        3) printf '%s\n' "$hout"; return 3 ;;
        *) echo "RERUN $id not valid: kit-index.sh has $folder/$f exited $hrc: $(printf '%s\n' "$hout" | tail -1)"; return 4 ;;
      esac
    done
    for f in $(printf '%s' "$outs" | tr ',' ' '); do
      hout="$(kq "$KIT_SCRIPTS/kit-index.sh" has "$KIT_ROOT/home/Developer/$folder/$f" 2>&1 </dev/null)"; hrc=$?
      case $hrc in
        0) bad="$bad $f (listed as not in the index, is)" ;;
        1) nout=$((nout + 1)) ;;
        3) printf '%s\n' "$hout"; return 3 ;;
        *) echo "RERUN $id not valid: kit-index.sh has $folder/$f exited $hrc: $(printf '%s\n' "$hout" | tail -1)"; return 4 ;;
      esac
    done
    S8C_REPOS=$((S8C_REPOS + 1))
    if [ -n "$bad" ]; then
      S8C_RED="${S8C_RED:+$S8C_RED, }$cell"
      echo "red $cell:$bad"
    else
      echo "green $cell: $nin files in the index, $nout files not in it"
    fi
  done 3< "$tsv"
  return 0
}

S8C_CHECKED=0
S8C_SKIPPED=0
S8C_RED=""
S8C_NOTFOUND=""
S8C_PLANTED=""

# s8c_matrix <id> <result file> : every cell of gate-matrix.csv of a kind a reader reads (read-kinds.txt) or of no known kind
# (unsupported): `kit-index.sh has` against expected_in_index, the name stem searched, and for a kind with a reader the content
# token searched too, the rows that list the file counted against expected_rows. A cell of any other kind is
# `SKIPPED-KIND <cell> <kind>` and not counted. The result file gets the columns of the feature map, tab separated. Group `extra`
# prints `EXTRA <cell> excluded|read` and never turns a cell red. Sets S8C_CHECKED, S8C_SKIPPED, S8C_RED (red cells of group spec),
# S8C_NOTFOUND (included cells a search did not find: the positive control of the method) and S8C_PLANTED. Status 0 read through;
# 3 a person step; 4 not valid (the RERUN line is printed).
s8c_matrix() {
  local id="$1" out="$2" csv="$KIT_LIB/gate-matrix.csv" cell path picks ein erows ereason group kind base stem tok
  local inidx hrc hout rc counts n pass state listed zeros
  [ -f "$csv" ] || { echo "RERUN $id not valid: no table: $csv"; return 4; }
  S8C_CHECKED=0; S8C_SKIPPED=0; S8C_RED=""; S8C_NOTFOUND=""; S8C_PLANTED=""
  printf 'cell\tgroup\texpected in index\texpected rows\tin index\trows listed\tpass\n' > "$out"
  while IFS=, read -r cell path picks ein erows ereason group <&3; do
    [ -n "$cell" ] && [ "$cell" != cell ] || continue
    kind="$(s8c_kind_of "$path")"
    if [ "$kind" != unsupported ] && ! s8c_read_kind "$kind"; then
      printf 'SKIPPED-KIND %s %s\n' "$cell" "$kind" | tee -a "$out"
      S8C_SKIPPED=$((S8C_SKIPPED + 1))
      continue
    fi
    base="${path##*/}"
    stem="$(s8c_stem "$path")"
    hout="$(kq "$KIT_SCRIPTS/kit-index.sh" has "matrix/$path" 2>&1 </dev/null)"; hrc=$?
    case $hrc in
      0) inidx=yes ;;
      1) inidx=no ;;
      3) printf '%s\n' "$hout"; return 3 ;;
      *) echo "RERUN $id not valid: kit-index.sh has matrix/$path exited $hrc: $(printf '%s\n' "$hout" | tail -1)"; return 4 ;;
    esac
    if [ -n "$KIT_PLANT" ] && [ -z "$S8C_PLANTED" ] && [ "$group" = spec ] && [ "$ein" = yes ] && [ "$erows" -ge 1 ] 2>/dev/null && [ "$inidx" = yes ]; then
      inidx=no
      S8C_PLANTED="$cell"
    fi
    s8c_search "$id" "$(s8c_query "$kind" "$stem")"; rc=$?
    [ $rc = 0 ] || return $rc
    counts="$(s8c_rows_named "$base")"
    if [ "$kind" != unsupported ]; then
      tok="$(s8c_token "$path")"
      if [ -n "$tok" ]; then
        s8c_search "$id" "$(s8c_query "$kind" "$tok")"; rc=$?
        [ $rc = 0 ] || return $rc
        counts="$counts/$(s8c_rows_named "$base")"
      fi
    fi
    pass=yes
    [ "$inidx" = "$ein" ] || pass=no
    listed=0; zeros=0
    for n in $(printf '%s' "$counts" | tr '/' ' '); do
      [ "$n" = "$erows" ] || pass=no
      if [ "$n" = 0 ]; then zeros=$((zeros + 1)); else listed=1; fi
    done
    if [ "$group" = extra ]; then
      pass=extra
      state=excluded
      if [ "$inidx" = yes ] || [ $listed = 1 ]; then state=read; fi
    else
      if [ "$ein" = yes ] && [ "$erows" -ge 1 ] 2>/dev/null && [ $zeros != 0 ]; then
        S8C_NOTFOUND="${S8C_NOTFOUND:+$S8C_NOTFOUND, }$cell (in the index: $inidx)"
      fi
      if [ "$pass" = no ]; then S8C_RED="${S8C_RED:+$S8C_RED, }$cell"; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cell" "$group" "$ein" "$erows" "$inidx" "$counts" "$pass" >> "$out"
    if [ "$group" = extra ]; then
      printf 'EXTRA %s %s\n' "$cell" "$state" | tee -a "$out"
    elif [ "$pass" = yes ]; then
      echo "green $cell: expected in index $ein, expected rows $erows, in index $inidx, rows listed $counts"
    else
      echo "red $cell: expected in index $ein, expected rows $erows, in index $inidx, rows listed $counts"
    fi
    S8C_CHECKED=$((S8C_CHECKED + 1))
  done 3< "$csv"
  return 0
}

# ---- S8.5: none of the excluded files is in the index or in any result; the allowed ones are ------------

check_S8_5() {
  local rc list diff tsv dir
  tree_need S8.5; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.5 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.5 not valid: the S8 session could not be started (tree_need exited $rc)"; return 4 ;;
  esac
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 900 || { echo "RERUN S8.5 not valid: indexing was not done within 900 s"; return 4; }
  wait_menu_ready 120; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.5 NEEDS-A-PERSON Accessibility is missing, so the menu bar cannot be read (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.5 not valid: the menu bar did not say Ready within 120 s after indexing was done"; return 4 ;;
  esac
  list="$(tree_pick_list "$KIT_LIB/gate-matrix.csv" 2>&1)" || { echo "RERUN S8.5 not valid: the pick list could not be made: $(printf '%s\n' "$list" | tail -1)"; return 4; }
  diff="$(s8c_roots "$list")"; rc=$?
  case $rc in
    0) printf '%s\n' "$diff" ;;
    1) echo "RERUN S8.5 not valid: picked roots differ from the pick list: $diff"; return 4 ;;
    3) printf '%s\n' "$diff"; echo "CHECK S8.5 NEEDS-A-PERSON the Settings window needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.5 not valid: the Settings list could not be read: $diff"; return 4 ;;
  esac
  tsv="$KIT_ROOT/run/gate-matrix-result.tsv"
  s8c_matrix S8.5 "$tsv"; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.5 NEEDS-A-PERSON a search needs a person (see the lines above)"; return 0 ;;
    *) return $rc ;;
  esac
  dir="$(kit_evidence_dir)"
  if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
    cp "$tsv" "$dir/gate-matrix-result.tsv" && echo "gate-matrix-result.tsv saved in $dir"
  fi
  echo "S8.5 matrix: $S8C_CHECKED cells checked, $S8C_SKIPPED skipped (SKIPPED-KIND: no reader for their kind at this slice)"
  s8c_repo_cells S8.5; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.5 NEEDS-A-PERSON a lookup needs a person (see the lines above)"; return 0 ;;
    *) return $rc ;;
  esac
  if [ -n "$S8C_NOTFOUND" ]; then
    echo "RERUN S8.5 not valid: an included cell was not found by the same search, so the search method is broken and no excluded cell's silence proves anything (positive control): $S8C_NOTFOUND"
    return 4
  fi
  if [ -n "$KIT_PLANT" ] && [ -z "$S8C_PLANTED" ]; then
    echo "RERUN S8.5 not valid: the plant found no included cell to remove from the index view"
    return 4
  fi
  if [ -n "$S8C_RED" ]; then
    if [ -n "$KIT_PLANT" ]; then
      echo "CHECK S8.5 FAIL planted: $S8C_PLANTED was removed from the index view (kit-index.sh was read as saying it is not indexed), and the check saw it: red cells: $S8C_RED"
    else
      echo "CHECK S8.5 FAIL red cells of group spec (expected in index or rows listed differ from gate-matrix.csv): $S8C_RED"
    fi
    return 1
  fi
  echo "CHECK S8.5 PASS $S8C_CHECKED cells of gate-matrix.csv match their expected_in_index and expected_rows, in the index and in the results (name stem and content token); every included cell was found by its search (positive control); $S8C_SKIPPED cells of kinds with no reader were skipped; the picked roots equal the pick list; the $S8C_REPOS golden repo cells of repo-cells.tsv hold (api-client: its two docs in the index, its code files and excluded files not; legacy-sync: its picture in, its code out)"
  return 0
}

# ---- S8.6: unsupported types are ignored, damaged files are listed, everything else is done ------------

# s8c_unsupported_files : the files no reader reads at any slice (an extension no list names, or none), one path under fixtures/ a
# line: those of tree/unsupported from tree.tsv and those of matrix/unsup from gate-matrix.csv.
s8c_unsupported_files() {
  local p cell path picks ein erows ereason group
  while IFS=$'\t' read -r p _; do
    case "$p" in unsupported/*) ;; *) continue ;; esac
    [ "$(s8c_kind_of "$p")" = unsupported ] && printf 'tree/%s\n' "$p"
  done < "$KIT_LIB/tree.tsv"
  while IFS=, read -r cell path picks ein erows ereason group; do
    case "$path" in unsup/*) ;; *) continue ;; esac
    [ "$(s8c_kind_of "$path")" = unsupported ] && printf 'matrix/%s\n' "$path"
  done < "$KIT_LIB/gate-matrix.csv"
  return 0
}

# s8c_damaged_files : the damaged files of a kind a reader reads (read-kinds.txt), one path under fixtures/ a line: the
# damaged/broken.* rows of tree.tsv and the cells of gate-matrix.csv whose expected_reason is could-not-read.
s8c_damaged_files() {
  local p cell path picks ein erows ereason group
  while IFS=$'\t' read -r p _; do
    case "$p" in damaged/broken.*) ;; *) continue ;; esac
    s8c_read_kind "$(s8c_kind_of "$p")" && printf 'tree/%s\n' "$p"
  done < "$KIT_LIB/tree.tsv"
  while IFS=, read -r cell path picks ein erows ereason group; do
    [ "$ereason" = could-not-read ] || continue
    s8c_read_kind "$(s8c_kind_of "$path")" && printf 'matrix/%s\n' "$path"
  done < "$KIT_LIB/gate-matrix.csv"
  return 0
}

# s8c_control_path : the path (under matrix/) of the first cell of group spec that must be indexed and listed once and is of a
# kind a reader reads: the file whose search must succeed before an unsupported file's silence means anything.
s8c_control_path() {
  local cell path picks ein erows ereason group
  while IFS=, read -r cell path picks ein erows ereason group; do
    [ "$group" = spec ] && [ "$ein" = yes ] || continue
    [ "${erows:-0}" -ge 1 ] 2>/dev/null || continue
    if s8c_read_kind "$(s8c_kind_of "$path")"; then printf '%s\n' "$path"; return 0; fi
  done < "$KIT_LIB/gate-matrix.csv"
  return 1
}

check_S8_6() {
  local rc settings sec out ctl unsup damaged rel base folder hrc n want got undone st bad="" reasons line p p1 p2 ignored expected under listing nu nd
  tree_need S8.6; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.6 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.6 not valid: the S8 session could not be started (tree_need exited $rc)"; return 4 ;;
  esac
  kq "$KIT_SCRIPTS/kit-index.sh" wait done 900 || { echo "RERUN S8.6 not valid: indexing was not done within 900 s"; return 4; }
  wait_menu_ready 120; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.6 NEEDS-A-PERSON Accessibility is missing, so the menu bar cannot be read (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.6 not valid: the menu bar did not say Ready within 120 s after indexing was done"; return 4 ;;
  esac

  # Settings, every section: the unreadable list is read wherever Settings puts it
  s8c_settings_open; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.6 NEEDS-A-PERSON the Settings window needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S8.6 not valid: the Settings window could not be read"; return 4 ;;
  esac
  settings=""
  for sec in Folders "File types" Search Indexing; do
    out="$(s8c_section_dump "$sec")" || { echo "RERUN S8.6 not valid: the Settings section $sec could not be read: $(printf '%s\n' "$out" | tail -1)"; return 4; }
    settings="$settings$out"$'\n'
  done

  # the positive control: a readable file that the same kind of search must find, else a silence below proves nothing
  ctl="$(s8c_control_path)" || { echo "RERUN S8.6 not valid: gate-matrix.csv names no included cell to use as the search's positive control"; return 4; }
  s8c_search S8.6 "$(s8c_query "$(s8c_kind_of "$ctl")" "$(s8c_stem "$ctl")")"; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S8.6 NEEDS-A-PERSON a search needs a person (see the lines above)"; return 0 ;;
    *) return $rc ;;
  esac
  if [ "$(s8c_rows_named "${ctl##*/}")" = 0 ]; then
    echo "RERUN S8.6 not valid: the positive control ${ctl##*/} was not found by its search, so the search method is broken and an unsupported file's absence proves nothing"
    return 4
  fi

  # the unsupported files: in no index row, no Settings list, no result and no setup count
  unsup="$(s8c_unsupported_files)"
  [ -n "$unsup" ] || { echo "RERUN S8.6 not valid: tree.tsv and gate-matrix.csv name no unsupported file"; return 4; }
  nu=0
  while IFS= read -r rel <&3; do
    [ -n "$rel" ] || continue
    nu=$((nu + 1))
    base="${rel##*/}"
    out="$(kq "$KIT_SCRIPTS/kit-index.sh" has "$rel" 2>&1 </dev/null)"; hrc=$?
    case $hrc in
      0) bad="${bad:+$bad; }$rel is in the index" ;;
      1) ;;
      3) printf '%s\n' "$out"; echo "CHECK S8.6 NEEDS-A-PERSON the index cannot be read (see the line above)"; return 0 ;;
      *) echo "RERUN S8.6 not valid: kit-index.sh has $rel exited $hrc: $(printf '%s\n' "$out" | tail -1)"; return 4 ;;
    esac
    if [ "$(printf '%s\n' "$settings" | s8c_lines_naming "$base")" != 0 ]; then bad="${bad:+$bad; }$rel is in Settings (the unreadable list or any other)"; fi
    s8c_search S8.6 "$(s8c_stem "$rel")"; rc=$?
    case $rc in
      0) ;;
      3) echo "CHECK S8.6 NEEDS-A-PERSON a search needs a person (see the lines above)"; return 0 ;;
      *) return $rc ;;
    esac
    if [ "$(s8c_rows_named "$base")" != 0 ]; then bad="${bad:+$bad; }$rel is in a result"; fi
  done 3<<EOF
$unsup
EOF
  for folder in $(printf '%s\n' "$unsup" | sed 's|/[^/]*$||' | sort -u); do
    expected="$(printf '%s\n' "$unsup" | awk -v f="$folder/" 'index($0, f) == 1 { n++ } END { print n + 0 }')"
    out="$(kq "$KIT_SCRIPTS/kit-fixtures.sh" expect counts "$folder" 2>&1 </dev/null)"; rc=$?
    ignored="$(printf '%s\n' "$out" | awk '$1 == "IGNORED" { print $2; exit }')"
    echo "kit-fixtures.sh expect counts $folder: IGNORED ${ignored:-0} (the table names $expected unsupported files)"
    [ $rc = 0 ] || bad="${bad:+$bad; }$folder: expect counts exited $rc: $(printf '%s\n' "$out" | tail -1)"
    [ "${ignored:-0}" = "$expected" ] || bad="${bad:+$bad; }$folder holds $expected unsupported files but the setup counts leave out ${ignored:-0}: they are in the setup counts"
  done

  # the damaged files: could_not_read with a reason in the index, listed in Settings with their path
  damaged="$(s8c_damaged_files)"
  [ -n "$damaged" ] || { echo "RERUN S8.6 not valid: tree.tsv and gate-matrix.csv name no damaged file of a kind a reader reads"; return 4; }
  reasons="$(kq "$KIT_SCRIPTS/kit-index.sh" reasons 2>&1 </dev/null)" || { echo "RERUN S8.6 not valid: kit-index.sh reasons failed: $(printf '%s\n' "$reasons" | tail -1)"; return 4; }
  nd=0
  while IFS= read -r rel <&3; do
    [ -n "$rel" ] || continue
    nd=$((nd + 1))
    line="$(printf '%s\n' "$reasons" | awk -F'\t' -v s="/$rel" 'NF >= 2 && length($1) >= length(s) && substr($1, length($1) - length(s) + 1) == s { print $2; exit }')"
    if [ -z "$line" ]; then
      bad="${bad:+$bad; }$rel is not could_not_read in kit-index.sh reasons"
    elif [ "$line" = "(no reason)" ]; then
      bad="${bad:+$bad; }$rel is could_not_read with no reason"
    else
      echo "damaged $rel: could_not_read, reason: $line"
    fi
    p1="$(real_path "$KIT_ROOT/fixtures/${rel%/*}")/${rel##*/}"
    p2="${p1#/private}"
    n=$(( $(printf '%s\n' "$settings" | s8c_lines_naming "$p1") + $(printf '%s\n' "$settings" | s8c_lines_naming "$p2") ))
    [ "$n" != 0 ] || bad="${bad:+$bad; }$rel is not listed in Settings with its path ($p1)"
  done 3<<EOF
$damaged
EOF

  # every other file of a kind a reader reads in tree/damaged and tree/unsupported is done
  for folder in damaged unsupported; do
    under="$(kq "$KIT_SCRIPTS/kit-index.sh" under "tree/$folder" 2>&1 </dev/null)" || { echo "RERUN S8.6 not valid: kit-index.sh under tree/$folder failed: $(printf '%s\n' "$under" | tail -1)"; return 4; }
    listing="$(kq "$KIT_SCRIPTS/kit-fixtures.sh" expect listing "tree/$folder" 2>&1 </dev/null)" || { echo "RERUN S8.6 not valid: kit-fixtures.sh expect listing tree/$folder failed: $(printf '%s\n' "$listing" | tail -1)"; return 4; }
    want=0; undone=""
    while IFS= read -r rel <&3; do
      case "$rel" in ""|LISTING*|MISSING*|EXTRA*|WRONG*) continue ;; esac
      s8c_read_kind "$(s8c_kind_of "$rel")" || continue
      if printf '%s\n' "$damaged" | awk -v l="tree/$folder/$rel" '$0 == l { f = 1 } END { exit f ? 0 : 1 }'; then continue; fi
      want=$((want + 1))
      st="$(printf '%s\n' "$under" | awk -F'\t' -v s="/tree/$folder/$rel" 'NF == 3 && length($1) >= length(s) && substr($1, length($1) - length(s) + 1) == s { print $3; exit }')"
      [ "$st" = done ] || undone="$undone $rel(${st:-not in the index})"
    done 3<<EOF
$listing
EOF
    got=0
    while IFS=$'\t' read -r p _ st; do
      [ "$st" = done ] || continue
      if s8c_read_kind "$(s8c_kind_of "$p")"; then got=$((got + 1)); fi
    done <<EOF
$(printf '%s\n' "$under" | awk -F'\t' 'NF == 3')
EOF
    echo "tree/$folder: $got done rows, kit-fixtures.sh expect listing names $want files of a kind with a reader (less the damaged ones)"
    [ "$got" = "$want" ] || bad="${bad:+$bad; }tree/$folder holds $got done rows, expect listing says $want${undone:+ (not done:$undone)}"
    [ -z "$undone" ] || bad="${bad:+$bad; }tree/$folder has files that are not done:$undone"
  done

  if [ -n "$bad" ]; then echo "CHECK S8.6 FAIL $bad"; return 1; fi
  echo "CHECK S8.6 PASS $nu unsupported files are in no index row, no Settings list, no result and no setup count; $nd damaged file(s) are could_not_read with a reason and listed in Settings with their path; every other file of a kind with a reader in tree/damaged and tree/unsupported is done, as kit-fixtures.sh expect listing says; indexing reached Ready (the menu bar said Ready; the positive control ${ctl##*/} was found by its search)"
  return 0
}

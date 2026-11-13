#!/bin/bash
# The slice 3 checks S2.2, S2.3, S2.8, S2.17 and S6.13 (feature maps S2 and S6; plan-3-tasks t12). Sourced by kit-run.sh after
# common.sh and recipes.sh (its checks-*.sh glob), never run. bash 3.2 compatible. Each check prints one `CHECK <id> PASS|FAIL|
# NEEDS-A-PERSON ...` line (a failure says why) and uses the exit codes of every kit script; a precondition that does not hold
# prints `RERUN <id> not valid: <reason>` and returns 4. These checks have no plant of their own: with KIT_PLANT=1 (kit-run.sh
# --plant <id>) the runner turns a PASS into `FAIL planted`, as it does for S8.6, S8.7 and S8.9.
#
# Where each starts: S2.2, S2.3 and S2.8 from the recipe `photos` (s1_need_photos: golden and golden/photos picked, because the
# panel run of kit-golden.sh needs the 40 done golden photos); S2.17 from the S8 tree session (tree_need, which it never closes:
# s8_close_window belongs to the checks that read the window); S6.13 reads what the S8 session left (s8_net_summary), so it runs in
# any order. S2.8 ends with the index polluted (1,000 unrelated photos, a deleted file put back), so it drops the recipe mark and
# the next check makes its own starting state.
#
# What a golden group b reads is decided by scripts/kit-lib/read-kinds.txt (t3): the readable exact rows, never a kind written
# here. The bar of group b is kit-golden.sh's (every readable row first; 19 of 20 only when every kind has a reader).
# The functions of this file are the five checks and `s2c_` helpers; the helpers that only print (s2c_screenshot_rows,
# s2c_code_rows, s2c_missing_query, s2c_pick_one_token, s2c_decoy_files, s2c_listing_clash, s2c_not_first, s2c_rank_summary,
# s2c_ext_cells, s2c_row_status, s2c_first_row_holds, s2c_rank_in_out, s2c_missing_words) run no kit script, so a test sources this
# file in a child shell and calls them on hand-written files.

. "$KIT_LIB/golden.sh"

S2C_GOLDEN="$KIT_SCRIPTS/kit-golden.sh"
S2C_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S2C_INDEX="$KIT_SCRIPTS/kit-index.sh"
S2C_AX="$KIT_SCRIPTS/kit-ax.sh"
S2C_MUTATED=0
S2C_MOVED=""

# ---- readers of the key and of the tables (they print, they run no kit script) ----------------------------------

# s2c_screenshot_rows : `id TAB query TAB file` of every exact row of the key whose note starts screenshot-only.
s2c_screenshot_rows() {
  awk -F, 'NR > 1 && $2 == "exact" && $7 ~ /^screenshot-only/ { print $1 "\t" $3 "\t" $4 }' "$GOLDEN_ANSWERS"
}

# s2c_code_rows : `id TAB file` of every exact row whose file has an extension of the code list of extensions.txt.
s2c_code_rows() {
  awk -F, -v ext="$KIT_LIB/extensions.txt" '
    BEGIN {
      while ((getline line < ext) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, ": ")
        if (a[1] == "code") { n = split(a[2], e, " "); for (i = 1; i <= n; i++) code[e[i]] = 1 }
      }
    }
    NR > 1 && $2 == "exact" {
      f = $4; x = ""
      if (f ~ /\./) { x = f; sub(/.*\./, "", x); x = tolower(x) }
      if (x in code) print $1 "\t" $4
    }' "$GOLDEN_ANSWERS"
}

# s2c_missing_query : the query of the first `missing` row of the key (one token, present in no file).
s2c_missing_query() { awk -F, 'NR > 1 && $2 == "missing" { print $3; exit }' "$GOLDEN_ANSWERS"; }

# s2c_missing_words : three strings of two, three and four tokens, none of whose words is in a file name or text of the fixtures
# (the gate shows No matches for each). No word repeats, so one string cannot lean on another.
s2c_missing_words() { printf '%s\n' "zqvx plork" "wuvm tnzd hrcb" "jlxo ypfk vduz bnqe"; }

# s2c_pick_one_token : `id TAB query TAB file` of the first readable exact row (golden_rows b) whose query is one token.
s2c_pick_one_token() { golden_rows b | awk -F'\t' 'NF >= 3 && $2 !~ /[ \t]/ { print $1 "\t" $2 "\t" $3; exit }'; }

# s2c_decoy_files : `exact id TAB decoy file` of every decoy row (note `decoy-for=<id>; ...`) of a readable exact row.
s2c_decoy_files() {
  awk -F, -v ids="$(golden_rows b | awk -F'\t' '{ printf "%s ", $1 }')" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    NR > 1 && $2 == "decoy" {
      t = $7
      if (sub(/^decoy-for=/, "", t)) { sub(/;.*/, "", t); if (t in want) print t "\t" $4 }
    }' "$GOLDEN_ANSWERS"
}

# s2c_listing_clash <query> : stdin the output of `kit-fixtures.sh expect listing <folder>`; prints every listed path whose file name
# holds the query (case ignored). A screenshot-only string is in no file name.
s2c_listing_clash() {
  awk -v q="$1" 'BEGIN { q = tolower(q) } $0 !~ /^LISTING / { b = $0; sub(/.*\//, "", b); if (q != "" && index(tolower(b), q)) print }'
}

# s2c_not_first <golden-engine.tsv|golden-panel.tsv> : the group b rows whose rank is not 1, as `id=rank ` (rank none when absent).
s2c_not_first() { awk -F'\t' 'NR > 1 && $2 == "b" && $5 != 1 { printf "%s=%s ", $1, $5 }' "$1"; }

# s2c_rank_summary : stdin the output of kit-golden.sh merge; the RANK lines (`RANK <id> <n|none> odd|even`) scored apart,
# `odd first <x> of <n>, even first <y> of <m>`, and `noted: overfitting risk` when the even rows hit at least 2 fewer (spec S2.8 iv).
s2c_rank_summary() {
  awk '
    $1 == "RANK" && NF == 4 {
      if ($4 == "odd") { on++; if ($3 == 1) of++ }
      else if ($4 == "even") { en++; if ($3 == 1) ef++ }
    }
    END {
      printf "odd first %d of %d, even first %d of %d\n", of, on, ef, en
      if (of - ef >= 2) print "noted: overfitting risk"
    }'
}

# s2c_ext_cells <kinds, comma separated> : `ext TAB path` for every extension of those kinds, in the order of extensions.txt, with the
# path (under matrix/) of its `ext-<ext>` cell in gate-matrix.csv, or `-` when the table has no such cell.
s2c_ext_cells() {
  awk -v kinds="$1" -v ext="$KIT_LIB/extensions.txt" -v table="$KIT_LIB/gate-matrix.csv" '
    BEGIN {
      nk = split(kinds, kk, ","); for (i = 1; i <= nk; i++) want[kk[i]] = 1
      while ((getline line < table) > 0) { split(line, f, ","); if (f[1] ~ /^ext-/) cell[substr(f[1], 5)] = f[2] }
      while ((getline line < ext) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, ": ")
        if (!(a[1] in want)) continue
        m = split(a[2], e, " ")
        for (i = 1; i <= m; i++) print e[i] "\t" ((e[i] in cell) ? cell[e[i]] : "-")
      }
    }'
}

# s2c_row_status <path suffix> : stdin the output of `kit-index.sh under <folder>` (path TAB kind TAB status; the path may be spelled
# /var or /private/var); prints the status of the row whose path ends with the suffix, nothing when none does.
s2c_row_status() {
  awk -F'\t' -v s="$1" 'NF == 3 { n = length($1) - length(s) + 1; if (n >= 1 && substr($1, n) == s) { print $3; exit } }'
}

# s2c_first_row_holds <file name> : stdin the output of kit-search.sh; status 0 when row 1 holds the file name.
s2c_first_row_holds() { awk -v n="$1" '$1 == "row" && $2 == 1 && index($0, n) { ok = 1 } END { exit ok ? 0 : 1 }'; }

# s2c_rank_in_out <file> : the number of the first row of the last search (S1_OUT) that holds the file's name; nothing when none does.
s2c_rank_in_out() { printf '%s\n' "$S1_OUT" | awk -v b="${1##*/}" '$1 == "row" && index($0, b) { print $2; exit }'; }

# ---- the pieces S2.2 and S2.8 share ------------------------------------------------------------------------------

# s2c_decoy_problems : one line for every readable exact row that has no decoy in the key and for every decoy file that is not in the
# index (`kit-index.sh has golden/<file>`); nothing when every readable row has its decoys indexed.
s2c_decoy_problems() {
  local decoys id rest f n
  decoys="$(s2c_decoy_files)"
  while IFS=$'\t' read -r id f <&3; do
    [ -n "$id" ] || continue
    s1_kq "$S2C_INDEX" has "golden/$f" >/dev/null 2>&1 || echo "the decoy $f of $id is not in the index (kit-index.sh has)"
  done 3<<EOF
$decoys
EOF
  while IFS=$'\t' read -r id rest <&3; do
    [ -n "$id" ] || continue
    n="$(printf '%s\n' "$decoys" | awk -F'\t' -v i="$id" '$1 == i { c++ } END { print c + 0 }')"
    [ "$n" -ge 1 ] || echo "$id has no decoy in the key"
  done 3<<EOF
$(golden_rows b)
EOF
}

# s2c_all_first <label> : every readable exact row searched through the panel (kit-search.sh); S2C_MOVED holds `id=rank ` for each
# whose expected file is not row 1 (rank none when it is not listed). Status 0; status 1 when a search could not be made (the CHECK or
# RERUN line is printed and S1_RC is set).
s2c_all_first() {
  local id q f rc rank n=0
  S2C_MOVED=""
  while IFS=$'\t' read -r id q f <&3; do
    [ -n "$id" ] || continue
    f="${f%%$'\t'*}"
    s1_search "$q"; rc=$?
    s1_search_ok S2.8 $rc || return 1
    n=$((n + 1))
    rank="$(s2c_rank_in_out "$f")"
    [ "$rank" = 1 ] || S2C_MOVED="$S2C_MOVED$id=${rank:-none} "
  done 3<<EOF
$(golden_rows b)
EOF
  echo "  | $1: $n readable exact rows searched, not first: ${S2C_MOVED:-none}"
  return 0
}

# ---- S2.2: an exact string puts its file first, decoys or not ----------------------------------------------------

check_S2_2() { s1_run s2c_check_2; }
s2c_check_2() {
  local out_e out_p rc_e rc_p dir tsv_e tsv_p ne nf pn pf total readable bar lst rc ns id q f n why=""
  s1_need_photos S2.2 || return $S1_RC
  out_p="$(kq "$S2C_GOLDEN" panel --group b 2>&1)"; rc_p=$?
  printf '%s\n' "$out_p" | sed 's/^/  | panel: /'
  out_e="$(kq "$S2C_GOLDEN" engine --group b 2>&1)"; rc_e=$?
  printf '%s\n' "$out_e" | sed 's/^/  | engine: /'
  if [ $rc_e = 3 ] || [ $rc_p = 3 ]; then
    echo "CHECK S2.2 NEEDS-A-PERSON $(printf '%s\n%s\n' "$out_e" "$out_p" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
    return 0
  fi
  if [ $rc_e = 4 ]; then echo "RERUN S2.2 not valid: the engine run of group b was not valid: $(s1_last "$out_e")"; return 4; fi
  if [ $rc_p = 4 ]; then echo "RERUN S2.2 not valid: the panel run of group b was not valid: $(s1_last "$out_p")"; return 4; fi
  dir="$(golden_dir)"
  tsv_e="$dir/golden-engine.tsv"; tsv_p="$dir/golden-panel.tsv"
  if [ ! -f "$tsv_e" ] || [ ! -f "$tsv_p" ]; then
    echo "CHECK S2.2 FAIL no reading: $([ -f "$tsv_e" ] || printf 'golden-engine.tsv ')$([ -f "$tsv_p" ] || printf 'golden-panel.tsv ')was not written"
    return 1
  fi
  set -- $(golden_counts "$tsv_e" b); ne="$1"; nf="$2"
  set -- $(golden_counts "$tsv_p" b); pn="$1"; pf="$2"
  total="$(golden_key_rows b)"
  readable="$(golden_rows b | awk 'NF { n++ } END { print n + 0 }')"
  bar="$(printf '%s\n' "$out_e" | awk '/^GOLDEN / { sub(/^GOLDEN [a-z]+ group b: /, ""); print; exit }')"
  echo "  | readable $readable of $total: engine first $nf of $ne, panel first $pf of $pn ($bar)"
  [ $rc_e = 0 ] || why="engine: group b is under its bar, rows not first: $(s2c_not_first "$tsv_e")"
  [ $rc_p = 0 ] || why="${why:+$why; }panel: group b is under its bar, rows not first: $(s2c_not_first "$tsv_p")"
  # the screenshot-only rows: their string is in no file name and no other file (the listing is checked against the scene table)
  lst="$(s1_kq "$S2C_FX" expect listing golden 2>&1)"; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }kit-fixtures.sh expect listing golden exited $rc: $(s1_last "$lst")"
  ns=0
  while IFS=$'\t' read -r id q f <&3; do
    [ -n "$id" ] || continue
    ns=$((ns + 1))
    printf '%s\n' "$lst" | awk -v f="$f" '$0 == f { k = 1 } END { exit k ? 0 : 1 }' || why="${why:+$why; }$id: the screenshot $f is not in the listing of golden"
    n="$(printf '%s\n' "$lst" | s2c_listing_clash "$q")"
    [ -z "$n" ] || why="${why:+$why; }$id: the string \"$q\" is in the name of $(printf '%s' "$n" | tr '\n' ' '), so it is not screenshot-only"
  done 3<<EOF
$(s2c_screenshot_rows)
EOF
  [ "$ns" -ge 4 ] || why="${why:+$why; }the key holds $ns screenshot-only rows, at least 4 are required"
  n="$(s2c_code_rows)"
  [ -z "$n" ] || why="${why:+$why; }an exact row comes from a code file: $(printf '%s' "$n" | tr '\t\n' ' ,')"
  n="$(s2c_decoy_problems)"
  [ -z "$n" ] || why="${why:+$why; }decoys: $(printf '%s' "$n" | tr '\n' ';')"
  if [ -n "$why" ]; then echo "CHECK S2.2 FAIL readable $readable of $total: $why"; return 1; fi
  echo "CHECK S2.2 PASS readable $readable of $total: every readable exact row is first through the engine and through the panel ($bar), $ns rows are screenshot-only and the listing of golden shows the string in no file name, none comes from a code file, every readable row has a decoy in the index"
  return 0
}

# ---- S2.3: a string in no file lists the closest files, never an error -------------------------------------------

check_S2_3() { s1_run s2c_check_3; }
s2c_check_3() {
  local rc q n why="" miss
  s1_need_photos S2.3 || return $S1_RC
  kit_need_ps || { echo "RERUN S2.3 not valid: ps cannot list processes, so a crash of the app cannot be told"; return 4; }
  miss="$(s2c_missing_query)"
  [ -n "$miss" ] || { echo "RERUN S2.3 not valid: fixtures/answers.csv holds no missing row"; return 4; }
  s1_search "$miss" --keep-open; rc=$?
  s1_show
  s1_search_ok S2.3 $rc || return $S1_RC
  pn_dump
  n="$(s1_rows_n)"
  [ "${n:-0}" -ge 1 ] 2>/dev/null || why="the one-token string \"$miss\" lists no file (the closest files by meaning are expected)"
  nr_has "No matches" && why="${why:+$why; }\"$miss\" shows No matches"
  nr_has_ci "error" && why="${why:+$why; }\"$miss\" shows error text"
  [ -n "$(kit_pid_of app)" ] || why="${why:+$why; }Sesame is no longer running after \"$miss\" was searched (a crash)"
  while IFS= read -r q <&3; do
    [ -n "$q" ] || continue
    s1_search "$q" --keep-open; rc=$?
    s1_show
    s1_search_ok S2.3 $rc || return $S1_RC
    pn_dump
    n="$(s1_rows_n)"
    [ "${n:-0}" = 0 ] || why="${why:+$why; }\"$q\" lists $n rows instead of No matches"
    nr_has "No matches" || why="${why:+$why; }\"$q\" shows no No matches"
    [ -n "$(kit_pid_of app)" ] || why="${why:+$why; }Sesame is no longer running after \"$q\" was searched (a crash)"
  done 3<<EOF
$(s2c_missing_words)
EOF
  if [ -n "$why" ]; then echo "CHECK S2.3 FAIL $why"; return 1; fi
  echo "CHECK S2.3 PASS the one-token string \"$miss\" lists the closest files by meaning (no No matches, no error text, Sesame still running); strings of two, three and four tokens made of words in no file each show No matches (the lone-token gate relaxes, the gate holds for the others; the ruling is the controller's Q2)"
  return 0
}

# ---- S2.8: the ranking merge under generated input ---------------------------------------------------------------

check_S2_8() { s1_run s2c_run_8; }
s2c_run_8() {
  local rc
  s2c_check_8; rc=$?
  s2c_restore
  return $rc
}

# s2c_restore : the deleted exact file put back and the recipe mark dropped (the index holds 1,000 unrelated photos and has seen a
# file removed, so the next check that needs the photos makes its own starting state).
s2c_restore() {
  if [ "$S2C_MUTATED" = 1 ]; then
    s1_kq "$S2C_FX" restore >/dev/null 2>&1
    S2C_MUTATED=0
  fi
  rm -f "$S1_MARK"
}

s2c_check_8() {
  local rc out why="" pick id q f t0 absent n summary note count=0
  S2C_MUTATED=0
  s1_need_photos S2.8 || return $S1_RC
  # (i) decoys: every readable exact row has its decoys in the key and in the index, and its file is still first
  n="$(s2c_decoy_problems)"
  [ -z "$n" ] || why="(i) decoys: $(printf '%s' "$n" | tr '\n' ';')"
  s2c_all_first "(i)" || return $S1_RC
  [ -z "$S2C_MOVED" ] || why="${why:+$why; }(i) the expected file is not first for: $S2C_MOVED"
  # (ii) 1,000 unrelated photos added through Settings and indexed to Ready: the same rows, none moved from first
  out="$(s1_kq "$S2C_FX" build unrelated 1000 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then echo "RERUN S2.8 not valid: kit-fixtures.sh build unrelated 1000 exited $rc: $(s1_last "$out")"; return 4; fi
  out="$(s8c_settings_open 2>&1)"; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S2.8 NEEDS-A-PERSON $(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; return 0 ;;
    *) echo "RERUN S2.8 not valid: the Settings window cannot be opened, so the unrelated folder cannot be added: $(s1_last "$out")"; return 4 ;;
  esac
  PK_WINDOW=settings drive_picker "$KIT_ROOT/fixtures/unrelated"; rc=$?
  if [ $rc != 0 ]; then
    echo "CHECK S2.8 NEEDS-A-PERSON the folder picker could not be driven ($PICKER_WHY): add $KIT_ROOT/fixtures/unrelated with \"Add folder…\" in Settings, press Start indexing, wait for Ready and run this check again"
    return 0
  fi
  settings_section Indexing >/dev/null 2>&1 || { echo "RERUN S2.8 not valid: the Settings window cannot be put on its Indexing section, so Start indexing cannot be pressed"; return 4; }
  s1_kq "$S2C_AX" click "Start indexing" >/dev/null 2>&1 || { echo "RERUN S2.8 not valid: pressing Start indexing in Settings failed"; return 4; }
  # `done` can still be true for a moment before the new folder is queued: wait until all 1,000 unrelated photos are done, then for done and Ready
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 3600 ]; do
    count="$(s1_kq "$S2C_INDEX" under unrelated 2>/dev/null | awk -F'\t' 'NF == 3 && $3 == "done" { n++ } END { print n + 0 }')"
    [ "$count" -ge 1000 ] && break
    sleep 10
  done
  [ "$count" -ge 1000 ] || { echo "RERUN S2.8 not valid: $count of the 1,000 unrelated photos were done in the index 3600 s after Start indexing was pressed"; return 4; }
  out="$(s1_kq "$S2C_INDEX" wait done 3600 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S2.8 not valid: indexing was not done within 3600 s (kit-index.sh wait done 3600 exited $rc)"; return 4; }
  out="$(wait_menu_ready 120 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S2.8 not valid: after the unrelated photos were indexed, $(s1_last "$out")"; return 4; }
  s2c_all_first "(ii)" || return $S1_RC
  [ -z "$S2C_MOVED" ] || why="${why:+$why; }(ii) after 1,000 unrelated photos were indexed the expected file moved from first for: $S2C_MOVED"
  # (iii) one exact file removed: it leaves the results within 30 s and the same string still lists the closest files
  pick="$(s2c_pick_one_token)"
  if [ -z "$pick" ]; then echo "RERUN S2.8 not valid: no readable exact row has a query of one token, so (iii) has no string that lists a closest set"; return 4; fi
  id="$(printf '%s' "$pick" | cut -f1)"; q="$(printf '%s' "$pick" | cut -f2)"; f="$(printf '%s' "$pick" | cut -f3)"
  S2C_MUTATED=1
  out="$(s1_kq "$S2C_FX" mutate delete "$KIT_ROOT/fixtures/golden/$f" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then echo "RERUN S2.8 not valid: kit-fixtures.sh mutate delete exited $rc: $(s1_last "$out")"; return 4; fi
  t0=$SECONDS; absent=0
  while [ $((SECONDS - t0)) -lt 30 ]; do
    s1_search "$q" --expect-absent "$KIT_ROOT/fixtures/golden/$f"; rc=$?
    if [ $rc = 0 ]; then absent=1; break; fi
    if [ $rc = 3 ]; then s1_search_ok S2.8 3; return $S1_RC; fi
    sleep 1
  done
  if [ $absent = 1 ]; then
    echo "  | $id: $f was gone from the results $((SECONDS - t0)) s after the deletion"
    n="$(s1_rows_n)"
    [ "${n:-0}" -ge 1 ] 2>/dev/null || why="${why:+$why; }(iii) after $f was deleted the string \"$q\" lists no file: a non-empty closest list is expected"
  else
    why="${why:+$why; }(iii) $f is still listed for \"$q\" 30 s after it was deleted"
  fi
  # (iv) the ranking merge checks of the engine: every rank printed, the odd rows and the even rows scored apart
  out="$(kq "$S2C_GOLDEN" merge 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | merge: /'
  case $rc in
    0) ;;
    3) echo "CHECK S2.8 NEEDS-A-PERSON $(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; return 0 ;;
    *) why="${why:+$why; }(iv) kit-golden.sh merge exited $rc: $(s1_last "$out")" ;;
  esac
  summary="$(printf '%s\n' "$out" | s2c_rank_summary)"
  printf '%s\n' "$summary" | sed 's/^/  | (iv) /'
  printf '%s\n' "$summary" | awk 'BEGIN { s = 1 } /^odd first/ { if ($5 + 0 > 0 && $10 + 0 > 0) s = 0 } END { exit s }' || why="${why:+$why; }(iv) kit-golden.sh merge printed no RANK line for the odd rows or none for the even rows: $(printf '%s' "$summary" | sed -n 1p)"
  note="$(printf '%s\n' "$summary" | awk '/^noted:/ { print; exit }')"
  if [ -n "$why" ]; then echo "CHECK S2.8 FAIL $why"; return 1; fi
  echo "CHECK S2.8 PASS every readable exact row has its decoys in the index and stays first, also with 1,000 unrelated photos indexed; the deleted exact file left the results within 30 s and the same string still lists the closest files; merge printed the odd and the even rows apart${note:+ ($note)}: (i) to (iv)"
  return 0
}

# ---- S2.17: every listed extension is in the fixtures and is read ------------------------------------------------

check_S2_17() { s1_run s2c_check_17; }
s2c_check_17() {
  local rc out kinds ext path file name st dir why="" ok_list=""
  tree_need S2.17; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S2.17 NEEDS-A-PERSON the S8 session needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S2.17 not valid: the S8 session could not be made (tree_need exited $rc)"; return 4 ;;
  esac
  kinds="$(golden_read_kinds)"
  [ -n "$kinds" ] || { echo "RERUN S2.17 not valid: scripts/kit-lib/read-kinds.txt lists no kind"; return 4; }
  out="$(s1_kq "$S2C_INDEX" wait done 900 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S2.17 not valid: the tree was not indexed within 900 s (kit-index.sh wait done 900 exited $rc)"; return 4; }
  out="$(wait_menu_ready 120 2>&1)"; rc=$?
  [ $rc = 0 ] || { echo "RERUN S2.17 not valid: $(s1_last "$out")"; return 4; }
  out="$(s1_kq "$S2C_FX" expect extensions --kinds "$kinds" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] || why="a fixture file is missing for: $(printf '%s\n' "$out" | awk '$1 == "MISSING" { printf "%s ", $3 }')"
  while IFS=$'\t' read -r ext path <&3; do
    [ -n "$ext" ] || continue
    if [ "$path" = - ]; then
      why="${why:+$why; }extension $ext has no ext- cell in the gate matrix, so no file of it is looked up"
      continue
    fi
    file="${path##*/}"; name="${file%.*}"
    out="$(s1_kq "$S2C_INDEX" under "matrix/${path%/*}" 2>&1)"
    st="$(printf '%s\n' "$out" | s2c_row_status "/fixtures/matrix/$path")"
    if [ "$st" != done ]; then
      why="${why:+$why; }extension $ext: $file is ${st:-not in the index}, not done"
      continue
    fi
    s1_search "$name"; rc=$?
    s1_search_ok S2.17 $rc || return $S1_RC
    if printf '%s\n' "$S1_OUT" | s2c_first_row_holds "$file"; then
      ok_list="$ok_list$ext "
    else
      why="${why:+$why; }extension $ext: searching \"$name\" does not list $file first"
    fi
  done 3<<EOF
$(s2c_ext_cells "$kinds")
EOF
  if [ -n "$why" ]; then echo "CHECK S2.17 FAIL $why"; return 1; fi
  echo "CHECK S2.17 PASS every extension of the kinds with a reader ($kinds) has a fixture file; for each, the ext- cell of the matrix is done in the index and its name stem searched alone lists it first: ${ok_list}"
  return 0
}

# ---- S6.13: no other download ------------------------------------------------------------------------------------

check_S6_13() {
  local rc mout n bad fails why="" reason
  s8_net_summary S6.13; rc=$?
  case $rc in
    0|1) ;;
    3) echo "CHECK S6.13 NEEDS-A-PERSON the network observers need a person (see the lines above): administrator rights for the network trace, said plainly first and asked once by kit-perms.sh ask-admin"; return 0 ;;
    *)
      reason="$(printf '%s\n' "$S8_NET_TEXT" | awk '/^(NOT VALID|not valid): / { sub(/^(NOT VALID|not valid): /, ""); print; exit }')"
      echo "RERUN S6.13 not valid: ${reason:-the network summary could not be made (s8_net_summary exited $rc; see the lines above)}"
      return 4 ;;
  esac
  mout="$(kq "$KIT_SCRIPTS/kit-mirror.sh" requests 2>&1)"
  printf '%s\n' "$mout"
  n="$(printf '%s\n' "$mout" | s8_mirror_count)"
  bad="$(printf '%s\n' "$mout" | s8_mirror_strays "$KIT_LIB/models.tsv" | head -3)"
  [ -z "$bad" ] || why="the mirror log shows a request for something other than the two model files: $(printf '%s' "$bad" | tr '\n' ' ')"
  fails="$(printf '%s\n' "$S8_NET_TEXT" | s8d_failure_lines | head -3)"
  if [ $rc = 1 ] || [ -n "$fails" ]; then
    why="${why:+$why; }the net log shows a destination other than the model host mirror (or a connection outside the mirror's window, 1,000,000 bytes sent, or a connection after the last model request): $(printf '%s' "$fails" | tr '\n' ';')"
  fi
  if [ -n "$why" ]; then echo "CHECK S6.13 FAIL a request or a destination other than the two model files and the mirror: $why"; return 1; fi
  if [ "${n:-0}" = 0 ]; then
    echo "RERUN S6.13 not valid: the mirror's request log holds no request, so no download was made through the mirror in this session and the log proves nothing"
    return 4
  fi
  echo "CHECK S6.13 PASS the mirror's log lists $n requests, all for the two model file names, and the net summary shows no destination other than the mirror (the real model host is a person-run, S8.N5)"
  return 0
}

# ---- S2.4: PDFs and documents found by describing a passage (slice 4; plan-4-t3) ------------------------------------------

# Starts from the state of the recipe `golden` (golden_need: the whole folders indexed, never kit-golden.sh prepare's photo-only
# state). The panel run of group c comes first and the engine run last: the engine's whole-folder prepare resets the kit, so the recipe
# mark is dropped after it and the next check makes its own state. Both runs score the same bars (kit-golden.sh: the right PDF in the
# first 3 for at least 9 of 10 and its page right for at least 9 of 10, the right document in the first 3 for at least 5 of 6, the
# scanned PDF in the first 3); the page is read in the panel from the pane's `Page N of M` with Down to the right PDF, and in the engine
# from the result's locator.
check_S2_4() { s1_run s2c_check_4; }
s2c_check_4() {
  local out_e out_p rc_e rc_p dir tsv_e tsv_p line_e line_p v_e v_p
  golden_need; s3_need S2.4 $? || return $S1_RC
  out_p="$(kq "$S2C_GOLDEN" panel --group c 2>&1)"; rc_p=$?
  printf '%s\n' "$out_p" | sed 's/^/  | panel: /'
  out_e="$(kq "$S2C_GOLDEN" engine --group c 2>&1)"; rc_e=$?
  printf '%s\n' "$out_e" | sed 's/^/  | engine: /'
  rm -f "$KIT_ROOT/run/recipe"
  if [ $rc_p = 3 ] || [ $rc_e = 3 ]; then
    echo "CHECK S2.4 NEEDS-A-PERSON $(printf '%s\n%s\n' "$out_p" "$out_e" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
    return 0
  fi
  if [ $rc_p = 4 ]; then echo "RERUN S2.4 not valid: the panel run of group c was not valid: $(s1_last "$out_p")"; return 4; fi
  if [ $rc_e = 4 ]; then echo "RERUN S2.4 not valid: the engine run of group c was not valid: $(s1_last "$out_e")"; return 4; fi
  dir="$(golden_dir)"
  tsv_p="$dir/golden-panel.tsv"; tsv_e="$dir/golden-engine.tsv"
  if [ ! -f "$tsv_p" ] || [ ! -f "$tsv_e" ]; then
    echo "CHECK S2.4 FAIL no reading: $([ -f "$tsv_p" ] || printf 'golden-panel.tsv ')$([ -f "$tsv_e" ] || printf 'golden-engine.tsv ')was not written"
    return 1
  fi
  line_p="$(golden_line_c_summary panel $(golden_score_c "$tsv_p"))"; v_p=$?
  line_e="$(golden_line_c_summary engine $(golden_score_c "$tsv_e"))"; v_e=$?
  printf '%s\n' "$line_p" "$line_e" | sed 's/^/  | /'
  if [ $rc_p = 0 ] && [ $rc_e = 0 ] && [ $v_p = 0 ] && [ $v_e = 0 ]; then
    echo "CHECK S2.4 PASS $(printf '%s' "$line_p" | sed 's/^GOLDEN //') | $(printf '%s' "$line_e" | sed 's/^GOLDEN //')"
    return 0
  fi
  echo "CHECK S2.4 FAIL panel (exit $rc_p): ${line_p#GOLDEN }; engine (exit $rc_e): ${line_e#GOLDEN }"
  return 1
}

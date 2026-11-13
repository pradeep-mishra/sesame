#!/bin/bash
# The slice 4 checks S3.1 to S3.10 (feature map S3: PDFs and documents open at the match; plan-4-tasks t3). check_S2_4 lives in
# checks-s2c.sh. Sourced by kit-run.sh after common.sh and recipes.sh (its checks-*.sh glob), never run. bash 3.2 compatible. Each
# check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a failure says why) and uses the exit codes of every kit script; a
# precondition that does not hold prints `RERUN <id> not valid: <reason>` and returns 4. With KIT_PLANT=1 (kit-run.sh --plant <id>) S3.2
# runs mark-check against a copy of the key whose boxes are moved and prints `FAIL planted`; every other check has no plant of its own:
# the runner turns a PASS into `FAIL planted`.
#
# Where each starts: from the state of the recipe `golden` (recipes.sh: golden_need; the photos, the PDFs and documents and the boundary
# PDFs picked and indexed to Ready; run/recipe says `golden`), never from kit-golden.sh prepare's photo-only state. S3.6 starts from the
# held state (`golden_need --hold`: picked, Start not pressed) because it presses Start itself and watches the menu say Indexing.
# The query, the file, the page and the anchor of every check come from the key (fixtures/answers.csv: pdf-01, doc-01..06, scanned-01,
# long60-01/02, boundary-01..03); the box of the passage comes from the same row's note (mark-check reads it). The files are under
# $KIT_ROOT/fixtures: pdfs/ and docs/ in golden-docs/, boundary/ in boundary/.
#
# The panel is driven as S1 does it (s1_search, kit-search.sh): the shortcut is posted only inside the kit window and typing and keys go
# to Sesame only. Enter hands the front to Preview or to the document's app, so a check that needs the panel again opens it afresh.
# The one thing done to another app: s3_close_preview closes Preview's windows before S3.4 opens one (feature map S3, Gotchas: a window
# left open from an earlier step would answer for the next). Preview's page is read by kit-readback.sh preview-page (tree first, then
# the picture); the pages and the mark by kit-readback.sh pdf-pages and mark-check. Nothing here reads product source.
# The functions without a verb of their own (s3_field, s3_rows, s3_rank_of, s3_distinct_rows, s3_pane_page, s3_row_page, s3_menu_state,
# s3_title_holds, s3_app_matches, s3_around, s3_source_text, s3_words_found, s3_unreadable, s3_in_dump, s3_reasons_hold, s3_done_count,
# s3_listing_n, s3_not_done, s3_text_chars, s3_moved_answers, s3_fixture_path) only read or print, run no kit script, and are tested on
# hand-written files by KitRunS3ChecksTests.

. "$KIT_LIB/golden.sh"

S3_RB="$KIT_SCRIPTS/kit-readback.sh"
S3_AX="$KIT_SCRIPTS/kit-ax.sh"
S3_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S3_INDEX="$KIT_SCRIPTS/kit-index.sh"

# ---- pure readers (they print, they run no kit script) -------------------------------------------------------------

# s3_field <row id> <group|query|file|locator|anchor|box> : one field of a row of the key (anchor and box are `anchor=` and `box=` of the
# note); nothing when the row or the field is not there.
s3_field() {
  awk -F, -v id="$1" -v f="$2" '
    NR > 1 && NF == 7 && $1 == id {
      if (f == "group") print $2
      else if (f == "query") print $3
      else if (f == "file") print $4
      else if (f == "locator") print $5
      else { n = split($7, p, "; "); for (i = 1; i <= n; i++) if (index(p[i], f "=") == 1) { print substr(p[i], length(f) + 2); break } }
      exit
    }' "$GOLDEN_ANSWERS"
}

# s3_rows <group> : `id TAB query TAB file TAB locator` of every row of that group of the key, in key order.
s3_rows() { awk -F, -v g="$1" 'NR > 1 && NF == 7 && $2 == g { print $1 "\t" $3 "\t" $4 "\t" $5 }' "$GOLDEN_ANSWERS"; }

# s3_fixture_path <file of the key> : where the file is under the kit's fixtures (pdfs/ and docs/ in golden-docs, photos/ in golden, boundary/ in
# boundary).
s3_fixture_path() {
  case "$1" in
    pdfs/*|docs/*) printf '%s\n' "$KIT_ROOT/fixtures/golden-docs/$1" ;;
    photos/*) printf '%s\n' "$KIT_ROOT/fixtures/golden/$1" ;;
    *) printf '%s\n' "$KIT_ROOT/fixtures/$1" ;;
  esac
}

# s3_rank_of <file> : stdin the output of kit-search.sh; the number of the first row whose text holds the file's name, nothing when none does.
s3_rank_of() { awk -v b="${1##*/}" '$1 == "row" && index($0, b) { print $2; exit }'; }

# s3_distinct_rows : stdin the output of kit-search.sh; the text of every row that is listed twice (every row is its own path when it prints nothing).
s3_distinct_rows() {
  awk '$1 == "row" { t = $0; sub(/^row [0-9]+ (selected|-) ?/, "", t); if (t in seen) { if (!(t in said)) { print t; said[t] = 1 } } else seen[t] = 1 }'
}

# s3_pane_page : stdin the output of kit-search.sh; `N M` of the first pane line that holds `Page N of M`, nothing when none does.
s3_pane_page() {
  awk '$1 == "pane" && match($0, /Page [0-9]+ of [0-9]+/) { s = substr($0, RSTART + 5, RLENGTH - 5); split(s, a, " of "); print a[1], a[2]; exit }'
}

# s3_row_page <file> : stdin the output of kit-search.sh; `N M` named for the first row that names the file: the `Page N of M` in the row's
# text, else (when that row is the selected one) the pane's. Nothing when the row names no page.
s3_row_page() {
  awk -v b="${1##*/}" '
    $1 == "pane" && pp == "" && match($0, /Page [0-9]+ of [0-9]+/) { s = substr($0, RSTART + 5, RLENGTH - 5); split(s, a, " of "); pp = a[1] " " a[2] }
    $1 == "row" && !found && index($0, b) {
      found = 1; sel = ($3 == "selected")
      if (match($0, /Page [0-9]+ of [0-9]+/)) { s = substr($0, RSTART + 5, RLENGTH - 5); split(s, a, " of "); rp = a[1] " " a[2] }
    }
    END { if (rp != "") print rp; else if (found && sel && pp != "") print pp }'
}

# s3_menu_state : stdin the output of `kit-ax.sh read menubar`; indexing, ready or unknown (indexing wins when the text says both).
s3_menu_state() {
  awk '{ t = tolower($0); if (index(t, "indexing")) s = "indexing"; else if (index(t, "ready") && s == "") s = "ready" } END { print (s == "" ? "unknown" : s) }'
}

# s3_title_holds <window title line> <file name> : status 0 when the title holds the file name, or its stem as a word of its own (an app
# that hides the extension), never the stem inside a longer name.
s3_title_holds() {
  local title="$1" file="$2" stem
  [ -n "$file" ] || return 1
  case "$title" in *"$file"*) return 0 ;; esac
  stem="${file%.*}"
  printf '%s\n' "$title" | awk -v s="$stem" '
    {
      pos = 1; line = $0
      while ((i = index(substr(line, pos), s)) > 0) {
        start = pos + i - 1
        b = (start == 1) ? "" : substr(line, start - 1, 1)
        a = substr(line, start + length(s), 1)
        if (b !~ /[A-Za-z0-9_-]/ && a !~ /[A-Za-z0-9_-]/) { found = 1; break }
        pos = start + 1
      }
    }
    END { exit found ? 0 : 1 }'
}

# s3_app_matches <frontmost app> <the app Launch Services names> : status 0 when they are the same name (case ignored), never for an empty one.
s3_app_matches() {
  [ -n "$1" ] && [ -n "$2" ] && [ "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" ]
}

# s3_around <anchor> : stdin a document's text; `before: <the three words before the anchor>` and `after: <the three words after it>`
# (spaces, line breaks and case ignored); nothing and status 1 when the anchor is not in the text.
s3_around() {
  awk -v anchor="$1" '
    { text = text " " $0 }
    END {
      gsub(/[ \t\r\n]+/, " ", text); sub(/^ /, "", text); sub(/ $/, "", text)
      a = tolower(anchor); gsub(/[ \t\r\n]+/, " ", a)
      i = index(tolower(text), a)
      if (i == 0) exit 1
      pre = substr(text, 1, i - 1); post = substr(text, i + length(a))
      n = split(pre, p, " "); b = ""
      for (k = (n > 3 ? n - 2 : 1); k <= n; k++) b = b (b == "" ? "" : " ") p[k]
      m = split(post, q, " "); e = ""
      for (k = 1; k <= (m < 3 ? m : 3); k++) e = e (e == "" ? "" : " ") q[k]
      print "before:" (b == "" ? "" : " " b)
      print "after:" (e == "" ? "" : " " e)
    }'
}

# s3_source_text <document> : the text of a source file (txt and md as they are, rtf, docx, html and odt through textutil).
s3_source_text() {
  case "${1##*.}" in
    txt|md) cat "$1" ;;
    *) textutil -convert txt -stdout "$1" ;;
  esac
}

# s3_words_found <query> : stdin the pane's text; the words of four letters or more of the query (lower case, in query order) that the pane holds.
s3_words_found() {
  local pane w lw
  pane="$(tr 'A-Z' 'a-z')"
  for w in $1; do
    [ "${#w}" -ge 4 ] || continue
    lw="$(printf '%s' "$w" | tr 'A-Z' 'a-z')"
    case "$pane" in *"$lw"*) printf '%s\n' "$lw" ;; esac
  done
}

# s3_unreadable : `path TAB reason` of the locked and the damaged PDF of golden-docs.tsv, in table order; the reasons are the ones Settings and
# the index show (design section 1): password-protected and damaged.
s3_unreadable() {
  awk -F'\t' '
    /^#/ || NF < 3 { next }
    $1 == "pdf" && $3 == "locked" { print $2 "\tpassword-protected" }
    $1 == "pdf" && $3 == "damaged" { print $2 "\tdamaged" }' "$KIT_LIB/golden-docs.tsv"
}

# s3_in_dump <file name> <reason> : stdin a dump of the Settings window; status 0 when a line holds the name and the same line or one of the
# next three holds the reason.
s3_in_dump() {
  awk -v n="$1" -v r="$2" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (index(line[i], n)) {
        if (index(line[i], r)) exit 0
        for (j = i + 1; j <= i + 3 && j <= NR; j++) if (index(line[j], r)) exit 0
      }
      exit 1
    }'
}

# s3_reasons_hold <file name> <reason> : stdin the output of `kit-index.sh reasons`; status 0 when a path that ends in /<name> has that reason.
s3_reasons_hold() {
  awk -F'\t' -v n="$1" -v r="$2" '
    NF == 2 { k = length($1) - length(n); if (k >= 0 && substr($1, k + 1) == n && (k == 0 || substr($1, k, 1) == "/") && $2 == r) f = 1 }
    END { exit f ? 0 : 1 }'
}

# s3_done_count : stdin the output of `kit-index.sh status`; the number of files with status done (0 when there is no index).
s3_done_count() { awk 'NF == 3 && $2 == "done" && $3 ~ /^[0-9]+$/ { n += $3 } END { print n + 0 }'; }

# s3_listing_n : stdin the output of `kit-fixtures.sh expect listing <folder>`; the number of paths of its `LISTING OK` line, nothing for a failed one.
s3_listing_n() { sed -n 's/^LISTING OK [^:]*: \([0-9][0-9]*\) paths$/\1/p' | head -1; }

# s3_not_done <file name>... : stdin the output of `kit-index.sh under <folder>`; `path TAB status` of every file whose status is not done and
# whose name is not one of the arguments.
s3_not_done() {
  awk -F'\t' -v ex=" $* " '
    NF == 3 && $3 != "done" { b = $1; sub(/.*\//, "", b); if (index(ex, " " b " ") == 0) print $1 "\t" $3 }'
}

# s3_text_chars : stdin the output of `fixturegen pdf-read` (a `pages <n>` line, then the text); the characters that are not spaces.
s3_text_chars() { awk 'NR > 1 { gsub(/[[:space:]]/, ""); n += length($0) } END { print n + 0 }'; }

# s3_moved_answers <key> <copy> : writes a copy of the key in which every `box=x:y:w:h` is moved 300 points down (up when it is too low to);
# the key itself is never written. S3.2's plant: the mark of the product does not move, so the box does.
s3_moved_answers() {
  awk -F, -v OFS=, '
    NR > 1 && NF == 7 && index($7, "box=") {
      n = split($7, p, "; ")
      for (i = 1; i <= n; i++) if (substr(p[i], 1, 4) == "box=") {
        split(substr(p[i], 5), b, ":")
        y = b[2] + 0
        y = (y >= 300) ? y - 300 : y + 300
        p[i] = "box=" b[1] ":" y ":" b[3] ":" b[4]
      }
      s = p[1]
      for (i = 2; i <= n; i++) s = s "; " p[i]
      $7 = s
    }
    { print }' "$1" > "$2"
}

# ---- driving ---------------------------------------------------------------------------------------------------

# s3_need <id> <status of golden_need> : status 0 when the state is made; else prints the CHECK or RERUN line, sets S1_RC and returns 1.
s3_need() {
  local id="$1" rc="$2"
  [ "$rc" = 0 ] && return 0
  case "$rc" in
    3) echo "CHECK $id NEEDS-A-PERSON the state of the recipe golden needs a person (see the lines above)"; S1_RC=0 ;;
    4) echo "RERUN $id not valid: the recipe golden could not make its state (see the lines above)"; S1_RC=4 ;;
    *) echo "CHECK $id FAIL the recipe golden cannot finish (exit $rc, see the lines above)"; S1_RC=1 ;;
  esac
  return 1
}

# s3_select_pane <id> <query> <rank> : the same search again with the selection moved to row <rank> (Down), the panel left open, and the
# settled panel (rows and the pane of that row) put into S1_OUT. Status 0; 1 with the CHECK or RERUN line printed and S1_RC set.
s3_select_pane() {
  local rc
  s1_search "$2" --select "$3" --keep-open; rc=$?
  s1_search_ok "$1" $rc || return 1
  s1_reread
  return 0
}

# s3_close_preview : closes Preview's windows (an Apple Event to Preview, only when it runs): a window left open from an earlier step
# would answer for the next one (feature map S3, Gotchas). Never quits Preview, never posts a key.
s3_close_preview() {
  osascript -e 'if application id "com.apple.Preview" is running then tell application id "com.apple.Preview" to close every window' >/dev/null 2>&1
  return 0
}

# ---- S3.1: describing a clause lists the PDF --------------------------------------------------------------------------

check_S3_1() { s1_run s3_check_1; }
s3_check_1() {
  local q f rc rank dup why=""
  golden_need; s3_need S3.1 $? || return $S1_RC
  q="$(s3_field pdf-01 query)"; f="$(s3_field pdf-01 file)"
  if [ -z "$q" ] || [ -z "$f" ]; then echo "RERUN S3.1 not valid: fixtures/answers.csv holds no row pdf-01"; return 4; fi
  s1_search "$q"; rc=$?
  s1_search_ok S3.1 $rc || return $S1_RC
  s1_show
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  dup="$(printf '%s\n' "$S1_OUT" | s3_distinct_rows)"
  if [ -z "$rank" ]; then why="${f##*/} is not listed for \"$q\""
  elif [ "$rank" -le 3 ]; then :
  else why="${f##*/} is row $rank for \"$q\", expected one of the first 3"
  fi
  [ -z "$dup" ] || why="${why:+$why; }a row is listed twice: $(printf '%s' "$dup" | tr '\n' ';')"
  if [ -n "$why" ]; then s1_fail S3.1 "$why"; return 1; fi
  echo "CHECK S3.1 PASS \"$q\" lists ${f##*/} as row $rank of the first 3 and every row is its own path"
  return 0
}

# ---- S3.2: the pane shows the page with the mark on the passage -----------------------------------------------------------

check_S3_2() { s1_run s3_check_2; }
s3_check_2() {
  local q f page pdf total rc rank pp shot out args=() why="" plant_key=""
  golden_need; s3_need S3.2 $? || return $S1_RC
  q="$(s3_field pdf-01 query)"; f="$(s3_field pdf-01 file)"; page="$(s3_field pdf-01 locator)"
  if [ -z "$q" ] || [ -z "$f" ] || [ -z "$page" ]; then echo "RERUN S3.2 not valid: fixtures/answers.csv holds no complete row pdf-01"; return 4; fi
  pdf="$(s3_fixture_path "$f")"
  total="$(s1_kq "$S3_RB" pdf-pages "$pdf" 2>&1)"; rc=$?
  case "$total" in ""|*[!0-9]*) echo "RERUN S3.2 not valid: kit-readback.sh pdf-pages $pdf said \"$total\" (exit $rc)"; return 4 ;; esac
  s1_search "$q" --keep-open; rc=$?
  s1_search_ok S3.2 $rc || return $S1_RC
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  if [ -z "$rank" ]; then s1_fail S3.2 "${f##*/} is not listed for \"$q\""; return 1; fi
  if [ "$rank" -gt 1 ]; then s3_select_pane S3.2 "$q" "$rank" || return $S1_RC; fi
  s1_show
  pp="$(printf '%s\n' "$S1_OUT" | s3_pane_page)"
  if [ "$pp" != "$page $total" ]; then why="the pane says ${pp:+Page ${pp% *} of ${pp#* }}${pp:-no page}, expected Page $page of $total (pdf-pages)"; fi
  out="$(s1_kq "$S3_AX" shot s3-pane --panel 2>&1)"; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S3.2 NEEDS-A-PERSON $(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; return 0; fi
  if [ $rc != 0 ]; then echo "RERUN S3.2 not valid: kit-ax.sh shot s3-pane --panel exited $rc: $(s1_last "$out")"; return 4; fi
  shot="$(printf '%s\n' "$out" | sed -n 's/^saved \(.*\) (Sesame window [0-9]*)$/\1/p' | head -1)"
  [ -n "$shot" ] && [ -f "$shot" ] || { echo "RERUN S3.2 not valid: kit-ax.sh shot said no picture: $(s1_last "$out")"; return 4; }
  if [ -n "$KIT_PLANT" ]; then
    plant_key="$KIT_ROOT/run/s3-plant-answers.csv"
    s3_moved_answers "$GOLDEN_ANSWERS" "$plant_key" || { echo "RERUN S3.2 not valid: the copy of the key for the plant could not be written"; return 4; }
    args=(--answers "$plant_key")
  fi
  out="$(s1_kq "$S3_RB" mark-check "$shot" "$pdf" "$page" "${args[@]}" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | mark-check: /'
  case $rc in
    0) ;;
    4) echo "RERUN S3.2 not valid: mark-check found no picture of page $page in the pane shot (never a pass): $(s1_last "$out")"; return 4 ;;
    *) why="${why:+$why; }mark-check exited $rc: $(printf '%s\n' "$out" | awk '/^(no mark|the mark is not)/ { print; exit }')" ;;
  esac
  if [ -n "$KIT_PLANT" ]; then
    echo "CHECK S3.2 FAIL planted: the passage box was moved in a copy of the key and the mark is no longer on it${why:+ ($why)}${why:-, yet the check passed: it cannot go red}"
    return 1
  fi
  if [ -n "$why" ]; then s1_fail S3.2 "$why"; return 1; fi
  echo "CHECK S3.2 PASS the pane shows Page $page of $total ($pdf has $total pages) and the mark lies on the passage: $(printf '%s\n' "$out" | awk '$1 == "inside" || $1 == "overlap" { printf "%s %s ", $1, $2 }')"
  return 0
}

# ---- S3.3: a document shows the passage in context ----------------------------------------------------------------------

check_S3_3() { s1_run s3_check_3; }
s3_check_3() {
  local id q f loc rc rank anchor pane panel_n anchor_n words src around part word why="" n=0 good=0
  golden_need; s3_need S3.3 $? || return $S1_RC
  while IFS=$'\t' read -r id q f loc <&3; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    anchor="$(s3_field "$id" anchor)"
    s1_search "$q" --keep-open; rc=$?
    s1_search_ok S3.3 $rc || return $S1_RC
    rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
    if [ -z "$rank" ] || ! [ "$rank" -le 3 ]; then why="${why:+$why; }$id: ${f##*/} is ${rank:+row $rank}${rank:-not listed} for \"$q\", expected one of the first 3"; continue; fi
    if [ "$rank" -gt 1 ]; then s3_select_pane S3.3 "$q" "$rank" || return $S1_RC; fi
    pane="$(s1_pane)"
    panel_n="$(printf '%s ' "$pane" | tr -s ' \t\n' ' ' | tr 'A-Z' 'a-z')"
    anchor_n="$(printf '%s' "$anchor" | tr 'A-Z' 'a-z')"
    case "$panel_n" in
      *"$anchor_n"*) ;;
      *) why="${why:+$why; }$id: the pane of ${f##*/} lacks the anchor \"$anchor\""; continue ;;
    esac
    words="$(printf '%s\n' "$pane" | s3_words_found "$q")"
    [ -n "$words" ] || { why="${why:+$why; }$id: the pane holds none of the query's words (\"$q\")"; continue; }
    # the text before and after the anchor in the source file also shows (about 600 characters of context)
    src="$(s3_fixture_path "$f")"
    around="$(s3_source_text "$src" 2>/dev/null | s3_around "$anchor")"
    if [ -z "$around" ]; then why="${why:+$why; }$id: the anchor is not in the text of $src (kit-fixtures.sh build golden-docs)"; continue; fi
    for part in before after; do
      for word in $(printf '%s\n' "$around" | sed -n "s/^$part: *//p" | tr 'A-Z' 'a-z'); do
        case "$panel_n" in *"$word"*) ;; *) why="${why:+$why; }$id: the $part word \"$word\" of the source is not in the pane"; break ;; esac
      done
    done
    good=$((good + 1))
  done 3<<EOF
$(s3_rows doc)
EOF
  [ "$n" -gt 0 ] || { echo "RERUN S3.3 not valid: fixtures/answers.csv holds no doc row"; return 4; }
  if [ -n "$why" ]; then s1_fail S3.3 "$why"; return 1; fi
  echo "CHECK S3.3 PASS for each of the $n documents the file is in the first 3 rows and the pane holds its anchor, a word of the query and the words before and after the anchor in the source"
  return 0
}

# ---- S3.4: Enter opens the PDF in Preview on that page ----------------------------------------------------------------------

check_S3_4() { s1_run s3_check_4; }
s3_check_4() {
  local q f page pdf rc rank out got via why="" front title i
  golden_need; s3_need S3.4 $? || return $S1_RC
  q="$(s3_field pdf-01 query)"; f="$(s3_field pdf-01 file)"; page="$(s3_field pdf-01 locator)"
  if [ -z "$q" ] || [ -z "$f" ] || [ -z "$page" ]; then echo "RERUN S3.4 not valid: fixtures/answers.csv holds no complete row pdf-01"; return 4; fi
  pdf="$(s3_fixture_path "$f")"
  # the negative control: Preview opened by hand at page 1 must read 1 the way the real open is read (window title first), or the reading proves nothing.
  # The picture is not the control: it cannot tell the near-identical lease pages apart (measured live: pages 3 and 11 tie at 0.980, page 1 0.950).
  s3_close_preview
  open -a Preview "$pdf" >/dev/null 2>&1
  s1_wait_front Preview 20 || { echo "RERUN S3.4 not valid: Preview did not come to the front for the control"; return 4; }
  sleep 3
  out="$(s1_kq "$S3_RB" preview-page 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | control: /'
  case "$out" in
    *"page 1 via tree"*) ;;
    *) echo "RERUN S3.4 not valid: the control (Preview opened at page 1) did not read page 1 by the window title or tree (exit $rc): $(s1_last "$out")"; return 4 ;;
  esac
  s3_close_preview
  sleep 1
  # the real open: Enter on the PDF's row
  s1_search "$q"; rc=$?
  s1_search_ok S3.4 $rc || return $S1_RC
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  if [ -z "$rank" ]; then s1_fail S3.4 "${f##*/} is not listed for \"$q\""; return 1; fi
  if [ "$rank" -gt 1 ]; then s1_search "$q" --select "$rank" --open; rc=$?; else s1_search "$q" --open; rc=$?; fi
  s1_search_ok S3.4 $rc || return $S1_RC
  if ! s1_wait_front Preview 20; then s1_fail S3.4 "Enter did not put Preview in front (the front app is $(printf '%s\n' "$READBACK" | sed -n 1p))"; return 1; fi
  for i in 1 2 3 4 5 6 7 8; do
    title="$(printf '%s\n' "$READBACK" | sed -n 2p)"
    s3_title_holds "$title" "${f##*/}" && break
    sleep 1
    READBACK="$(s1_rbp "System Events" frontmost)"
  done
  s3_title_holds "$title" "${f##*/}" || why="Preview's front window is not ${f##*/} ($title)"
  sleep 2
  # the reading of the page: the accessibility tree first, the picture when the tree lacks it
  got="$(s1_kq "$S3_RB" preview-page 2>&1)"; rc=$?
  if [ $rc = 0 ]; then
    via=tree
  elif [ $rc = 4 ]; then
    out="$(s1_kq "$S3_RB" preview-page --by-picture --pdf "$pdf" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | picture: /'
    if [ $rc = 3 ]; then
      echo "CHECK S3.4 NEEDS-A-PERSON neither Preview's tree nor its picture names the page (S3.N2): open the result and say which page shows; $(s1_last "$out")"
      return 0
    fi
    [ $rc = 0 ] || { s1_fail S3.4 "kit-readback.sh preview-page --by-picture exited $rc: $(s1_last "$out")"; return 1; }
    got="$out"; via=picture
  else
    printf '%s\n' "$got" | sed 's/^/  | tree: /'
    echo "RERUN S3.4 not valid: kit-readback.sh preview-page exited $rc: $(s1_last "$got")"
    return 4
  fi
  got="$(printf '%s\n' "$got" | sed -n 's/^page \([0-9][0-9]*\) via .*/\1/p' | tail -1)"
  [ "$got" = "$page" ] || why="${why:+$why; }Preview shows page ${got:-unknown} (read by $via), expected page $page"
  if [ -n "$why" ]; then s1_fail S3.4 "$why"; return 1; fi
  echo "CHECK S3.4 PASS Enter put Preview in front on ${f##*/} at page $page (read by $via; the control read page 1 by the title/tree reading)"
  return 0
}

# ---- S3.5: Enter opens a document in its default app -------------------------------------------------------------------------

check_S3_5() { s1_run s3_check_5; }
s3_check_5() {
  local id q f loc rc rank ext name want front title i why="" n=0
  golden_need; s3_need S3.5 $? || return $S1_RC
  while IFS=$'\t' read -r id q f loc <&3; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    ext="${f##*.}"; name="${f##*/}"
    want="$(s1_kq "$S3_RB" default-app "$ext" 2>&1)" || { why="${why:+$why; }$id: no default app is named for .$ext ($want)"; continue; }
    s1_search "$q"; rc=$?
    s1_search_ok S3.5 $rc || return $S1_RC
    rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$name")"
    if [ -z "$rank" ] || ! [ "$rank" -le 3 ]; then why="${why:+$why; }$id: $name is ${rank:+row $rank}${rank:-not listed} for \"$q\", expected one of the first 3"; continue; fi
    if [ "$rank" -gt 1 ]; then s1_search "$q" --select "$rank" --open; rc=$?; else s1_search "$q" --open; rc=$?; fi
    s1_search_ok S3.5 $rc || return $S1_RC
    s1_wait_front "$want" 25
    front="$(printf '%s\n' "$READBACK" | sed -n 1p)"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      title="$(printf '%s\n' "$READBACK" | sed -n 2p)"
      s3_title_holds "$title" "$name" && break
      sleep 1
      READBACK="$(s1_rbp "System Events" frontmost)"
    done
    front="$(printf '%s\n' "$READBACK" | sed -n 1p)"
    s3_app_matches "$front" "$want" || { why="${why:+$why; }$id: after Enter the front app is \"$front\", Launch Services names \"$want\" for .$ext"; continue; }
    s3_title_holds "$title" "$name" || why="${why:+$why; }$id: the front window of $front is \"$title\", expected it to hold $name"
  done 3<<EOF
$(s3_rows doc)
EOF
  [ "$n" -gt 0 ] || { echo "RERUN S3.5 not valid: fixtures/answers.csv holds no doc row"; return 4; }
  if [ -n "$why" ]; then s1_fail S3.5 "$why"; return 1; fi
  echo "CHECK S3.5 PASS Enter opened each of the $n documents in the app Launch Services names for its extension, with the file name in the window title"
  return 0
}

# ---- S3.6: a long PDF returns results from its first 30 pages before the rest are done ------------------------------------

check_S3_6() { s1_run s3_check_6; }
s3_check_6() {
  local q12 q55 f p12 p55 path total rc out tl before_state after_state row12 row55 row55b why="" t0
  golden_need --hold; s3_need S3.6 $? || return $S1_RC
  q12="$(s3_field long60-01 query)"; q55="$(s3_field long60-02 query)"; f="$(s3_field long60-01 file)"
  p12="$(s3_field long60-01 locator)"; p55="$(s3_field long60-02 locator)"
  if [ -z "$q12" ] || [ -z "$q55" ] || [ -z "$f" ] || [ -z "$p12" ] || [ -z "$p55" ]; then echo "RERUN S3.6 not valid: fixtures/answers.csv holds no complete rows long60-01 and long60-02"; return 4; fi
  path="$(s3_fixture_path "$f")"
  total="$(s1_kq "$S3_RB" pdf-pages "$path" 2>&1)"
  case "$total" in ""|*[!0-9]*) echo "RERUN S3.6 not valid: kit-readback.sh pdf-pages $path said \"$total\""; return 4 ;; esac
  tl="$(golden_dir)/s3-6-timeline.txt"
  : > "$tl"
  # Start indexing is pressed here, with the menu bar about to say Indexing; every step is timed
  press_start || { echo "RERUN S3.6 not valid: Start indexing could not be pressed in the held state"; return 4; }
  t0=$(date +%s)
  echo "start-pressed $t0" >> "$tl"
  # the positive control and the window: the page 12 string is found while the menu still says Indexing (read before and after the search)
  before_state="$(s1_kq "$S3_AX" read menubar 2>&1 | s3_menu_state)"
  echo "menu-before-page12 $before_state $(date +%s)" >> "$tl"
  s1_search "$q12" --wait-for "$path" --within 1800; rc=$?
  echo "page12-search-ended $(date +%s) exit $rc" >> "$tl"
  after_state="$(s1_kq "$S3_AX" read menubar 2>&1 | s3_menu_state)"
  echo "menu-after-page12 $after_state $(date +%s)" >> "$tl"
  if [ $rc != 0 ]; then
    s1_show
    case $rc in
      3|4) s1_search_ok S3.6 $rc; return $S1_RC ;;
    esac
    s1_fail S3.6 "the page 12 string \"$q12\" did not find ${path##*/} within 1800 s of Start indexing (the positive control of the method failed)"
    return 1
  fi
  if [ "$before_state" != indexing ] || [ "$after_state" != indexing ]; then
    echo "RERUN S3.6 not valid: the menu said $before_state before and $after_state after the page 12 find, not Indexing at both: the window between the first 30 pages and the rest was missed (the timeline is $tl); queue more files ahead of the PDF's second step and run again"
    return 4
  fi
  row12="$(printf '%s\n' "$S1_OUT" | s3_row_page "$path")"
  [ "$row12" = "$p12 $total" ] || why="the row of ${path##*/} says ${row12:+Page ${row12% *} of ${row12#* }}${row12:-no page} for the page 12 string, expected Page $p12 of $total"
  # at that moment no row names page 55 of that PDF (other rows for the string are allowed: the row's page is read, not the list)
  s1_search "$q55"; rc=$?
  echo "page55-absent-search $(date +%s) exit $rc" >> "$tl"
  s1_search_ok S3.6 $rc || return $S1_RC
  row55="$(printf '%s\n' "$S1_OUT" | s3_row_page "$path")"
  case "$row55" in
    "$p55 "*) why="${why:+$why; }a row names Page $p55 of ${path##*/} while the menu still said Indexing: the pages after the first 30 were searchable before they were read" ;;
  esac
  # indexing ends, the menu says Ready, and page 55 is found
  out="$(s1_kq "$S3_INDEX" wait done 7200 2>&1)"; rc=$?
  echo "index-done $(date +%s) exit $rc" >> "$tl"
  if [ $rc != 0 ]; then echo "RERUN S3.6 not valid: indexing was not done within 7200 s (kit-index.sh wait done 7200 exited $rc)"; return 4; fi
  out="$(wait_menu_ready 120 2>&1)"; rc=$?
  echo "menu-ready $(date +%s) exit $rc" >> "$tl"
  if [ $rc != 0 ]; then echo "RERUN S3.6 not valid: $(s1_last "$out")"; return 4; fi
  printf 'golden\n' > "$KIT_ROOT/run/recipe"
  s1_search "$q55" --wait-for "$path" --within 60; rc=$?
  echo "page55-found $(date +%s) exit $rc" >> "$tl"
  s1_search_ok S3.6 $rc || return $S1_RC
  row55b="$(printf '%s\n' "$S1_OUT" | s3_row_page "$path")"
  [ "$row55b" = "$p55 $total" ] || why="${why:+$why; }after Ready the row of ${path##*/} says ${row55b:+Page ${row55b% *} of ${row55b#* }}${row55b:-no page} for the page 55 string, expected Page $p55 of $total"
  if [ -n "$why" ]; then s1_fail S3.6 "$why"; return 1; fi
  echo "CHECK S3.6 PASS the page $p12 string found ${path##*/} as Page $p12 of $total while the menu said Indexing (read before and after), no row named Page $p55 at that moment, and after Ready the page $p55 string found it as Page $p55 of $total (timeline: $tl)"
  return 0
}

# ---- S3.7: a scanned PDF is found by its page picture --------------------------------------------------------------------

check_S3_7() { s1_run s3_check_7; }
s3_check_7() {
  local q f loc pdf rc rank pp tool chars out listing why=""
  golden_need; s3_need S3.7 $? || return $S1_RC
  q="$(s3_field scanned-01 query)"; f="$(s3_field scanned-01 file)"; loc="$(s3_field scanned-01 locator)"
  if [ -z "$q" ] || [ -z "$f" ] || [ -z "$loc" ]; then echo "RERUN S3.7 not valid: fixtures/answers.csv holds no complete row scanned-01"; return 4; fi
  pdf="$(s3_fixture_path "$f")"
  s1_search "$q" --keep-open; rc=$?
  s1_search_ok S3.7 $rc || return $S1_RC
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  if [ -z "$rank" ]; then why="${f##*/} is not listed for \"$q\""
  elif [ "$rank" -le 3 ]; then
    if [ "$rank" -gt 1 ]; then s3_select_pane S3.7 "$q" "$rank" || return $S1_RC; fi
    pp="$(printf '%s\n' "$S1_OUT" | s3_pane_page)"
    [ "${pp%% *}" = "$loc" ] || why="the pane says ${pp:+Page ${pp% *} of ${pp#* }}${pp:-no page}, expected Page $loc"
  else
    why="${f##*/} is row $rank for \"$q\", expected one of the first 3"
  fi
  # the file has no text layer (so it was found by its picture), and the build is whole
  listing="$(s1_kq "$S3_FX" expect listing golden-docs 2>&1)"; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }kit-fixtures.sh expect listing golden-docs exited $rc"
  printf '%s\n' "$listing" | awk -v f="$f" '$0 == f { k = 1 } END { exit k ? 0 : 1 }' || why="${why:+$why; }the listing of golden-docs does not hold $f"
  tool="$(kit_tool fixturegen)" || { echo "RERUN S3.7 not valid: the kit's fixture tool did not compile"; return 4; }
  chars="$("$tool" pdf-read "$pdf" 2>&1 | s3_text_chars)"
  [ "$chars" = 0 ] || why="${why:+$why; }$f has $chars characters of text layer, expected none (a scanned PDF)"
  if [ -n "$why" ]; then s1_fail S3.7 "$why"; return 1; fi
  echo "CHECK S3.7 PASS the scanned PDF ${f##*/} is row $rank of the first 3 for \"$q\", the pane says Page $loc, and the file has no text layer"
  return 0
}

# ---- S3.8: a locked and a damaged PDF are skipped and listed, indexing goes on -------------------------------------------------

check_S3_8() { s1_run s3_check_8; }
s3_check_8() {
  local path reason name rc out settings="" sec reasons status done_n listed root n total=0 readable names="" rows left why="" bad
  golden_need; s3_need S3.8 $? || return $S1_RC
  rows="$(s3_unreadable)"
  [ -n "$rows" ] || { echo "RERUN S3.8 not valid: scripts/kit-lib/golden-docs.tsv names no locked or damaged pdf"; return 4; }
  # plan 5: the recipe golden also picks golden-av, whose two damaged clips are unreadable too (s4_unreadable, checks-s4.sh)
  rows="$rows"$'\n'"$(s4_unreadable)"
  # Settings: the unreadable list is read wherever Settings puts it (every section)
  s8c_settings_open; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S3.8 NEEDS-A-PERSON the Settings window needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S3.8 not valid: the Settings window could not be read"; return 4 ;;
  esac
  for sec in Folders "File types" Search Indexing; do
    out="$(s8c_section_dump "$sec")" || { echo "RERUN S3.8 not valid: the Settings section $sec could not be read: $(printf '%s\n' "$out" | tail -1)"; return 4; }
    settings="$settings$out"$'\n'
  done
  reasons="$(s1_kq "$S3_INDEX" reasons 2>&1)"
  while IFS=$'\t' read -r path reason <&3; do
    [ -n "$path" ] || continue
    name="${path##*/}"
    names="$names $name"
    printf '%s\n' "$settings" | s3_in_dump "$name" "$reason" || why="${why:+$why; }Settings does not list $name with the reason \"$reason\""
    printf '%s\n' "$reasons" | s3_reasons_hold "$name" "$reason" || why="${why:+$why; }kit-index.sh reasons does not hold $name with the reason \"$reason\""
  done 3<<EOF
$rows
EOF
  # every other golden file is done, and the number of done files is the number of readable files on disk
  status="$(s1_kq "$S3_INDEX" status 2>&1)"
  done_n="$(printf '%s\n' "$status" | s3_done_count)"
  for root in golden golden-docs boundary golden-av; do
    out="$(s1_kq "$S3_FX" expect listing "$root" 2>&1)"; rc=$?
    n="$(printf '%s\n' "$out" | s3_listing_n)"
    if [ $rc != 0 ] || [ -z "$n" ]; then why="${why:+$why; }kit-fixtures.sh expect listing $root exited $rc: $(s1_last "$out")"; continue; fi
    total=$((total + n))
    bad="$(s1_kq "$S3_INDEX" under "$root" 2>&1 | s3_not_done $names)"
    [ -z "$bad" ] || why="${why:+$why; }files of $root that are not done: $(printf '%s' "$bad" | tr '\t\n' ' ;')"
  done
  left="$(printf '%s\n' "$rows" | awk 'NF { c++ } END { print c + 0 }')"
  readable=$((total - left))
  [ "$done_n" = "$readable" ] || why="${why:+$why; }kit-index.sh status counts $done_n done files, the listings of the three roots hold $total files, $left unreadable, so $readable are readable"
  out="$(wait_menu_ready 60 2>&1)"; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }the menu bar does not say Ready ($(s1_last "$out"))"
  if [ -n "$why" ]; then s1_fail S3.8 "$why"; return 1; fi
  echo "CHECK S3.8 PASS Settings and the index list the locked PDF (password-protected) and the damaged PDF (damaged); the other $done_n readable files of the three roots are done and the menu says Ready"
  return 0
}

# ---- S3.9: a PDF app that is not installed ------------------------------------------------------------------------------------

# s3_choose_pdf_app <label>... : puts the PDF app choice of Settings on the first label that a section of Settings has (the names follow
# mockup F3, a guess K20, so several are tried) and leaves that section selected; status 0 and S3_SECTION says which; 1 when none is found,
# 3 the Settings window needs a person.
S3_SECTION=""
s3_choose_pdf_app() {
  local label sec rc
  s8c_settings_open >/dev/null 2>&1; rc=$?
  [ $rc = 0 ] || return $rc
  for sec in "File types" Folders Search Indexing; do
    settings_section "$sec" >/dev/null 2>&1 || continue
    for label in "$@"; do
      if s1_kq "$S3_AX" click "$label" >/dev/null 2>&1; then S3_SECTION="$sec"; return 0; fi
    done
  done
  return 1
}

# s3_open_pdf <id> <query> <file> <default app> : Enter on the PDF's row; status 0 and READBACK holds the front app and window when the front
# app is the default PDF app with the file name in its window title; else one line in S3_WHY.
S3_WHY=""
s3_open_pdf() {
  local id="$1" q="$2" f="$3" want="$4" rc rank title i
  s1_search "$q"; rc=$?
  s1_search_ok "$id" $rc || return 2
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  [ -n "$rank" ] || { S3_WHY="${f##*/} is not listed for \"$q\""; return 1; }
  if [ "$rank" -gt 1 ]; then s1_search "$q" --select "$rank" --open; rc=$?; else s1_search "$q" --open; rc=$?; fi
  s1_search_ok "$id" $rc || return 2
  s1_wait_front "$want" 25
  for i in 1 2 3 4 5 6 7 8; do
    title="$(printf '%s\n' "$READBACK" | sed -n 2p)"
    s3_title_holds "$title" "${f##*/}" && break
    sleep 1
    READBACK="$(s1_rbp "System Events" frontmost)"
  done
  s3_app_matches "$(printf '%s\n' "$READBACK" | sed -n 1p)" "$want" || { S3_WHY="after Enter the front app is \"$(printf '%s\n' "$READBACK" | sed -n 1p)\", Launch Services names \"$want\" for pdf"; return 1; }
  s3_title_holds "$title" "${f##*/}" || { S3_WHY="the front window is \"$title\", expected it to hold ${f##*/}"; return 1; }
  return 0
}

check_S3_9() { s1_run s3_check_9; }
s3_check_9() {
  local q f acro skim absent_label="" absent_name="" present_label="" present_name="" dpdf rc msg dump a="" b="" why="" note=""
  golden_need; s3_need S3.9 $? || return $S1_RC
  q="$(s3_field pdf-01 query)"; f="$(s3_field pdf-01 file)"
  if [ -z "$q" ] || [ -z "$f" ]; then echo "RERUN S3.9 not valid: fixtures/answers.csv holds no row pdf-01"; return 4; fi
  s1_kq "$S3_RB" app-installed com.adobe.Reader >/dev/null 2>&1 && acro=1 || acro=0
  s1_kq "$S3_RB" app-installed net.sourceforge.skim-app.skim >/dev/null 2>&1 && skim=1 || skim=0
  if [ $acro = 0 ]; then absent_label="Adobe Acrobat"; absent_name="Acrobat"; else present_label="Adobe Acrobat"; present_name="Acrobat"; fi
  if [ $skim = 0 ] && [ -z "$absent_label" ]; then absent_label="Skim"; absent_name="Skim"; fi
  if [ $skim = 1 ] && [ -z "$present_label" ]; then present_label="Skim"; present_name="Skim"; fi
  dpdf="$(s1_kq "$S3_RB" default-app pdf 2>&1)" || { echo "RERUN S3.9 not valid: no default PDF app is named ($dpdf)"; return 4; }
  # (a) a listed app that is not installed: Settings says so, Enter opens the default PDF app
  if [ -z "$absent_label" ]; then
    a=person
    note="both Acrobat and Skim are installed, so no listed app is absent"
  else
    s3_choose_pdf_app "$absent_label" "$absent_name"; rc=$?
    case $rc in
      0) dump="$(s1_kq "$S3_AX" dump settings 2>&1)"
         case "$(printf '%s' "$dump" | tr 'A-Z' 'a-z')" in
           *"not installed"*) ;;
           *) why="${why:+$why; }(a) Settings shows no \"not installed\" message after $absent_name was chosen" ;;
         esac
         if s3_open_pdf S3.9 "$q" "$f" "$dpdf"; then a=pass; else rc=$?; [ $rc = 2 ] && return $S1_RC; a=fail; why="${why:+$why; }(a) $S3_WHY"; fi ;;
      3) a=person; note="the Settings window needs a person" ;;
      *) a=person; note="the PDF app choice of Settings could not be driven (no control named $absent_label or $absent_name in any section)" ;;
    esac
  fi
  # (b) an installed listed app other than Preview: no message, and Enter still opens the default PDF app
  if [ -z "$present_label" ]; then
    echo "S3.9 (b) NOT RUN: no listed PDF app other than Preview is installed"
    b=notrun
  else
    s3_choose_pdf_app "$present_label" "$present_name"; rc=$?
    case $rc in
      0) dump="$(s1_kq "$S3_AX" dump settings 2>&1)"
         case "$(printf '%s' "$dump" | tr 'A-Z' 'a-z')" in
           *"not installed"*) why="${why:+$why; }(b) Settings shows a \"not installed\" message for the installed $present_name" ;;
         esac
         if s3_open_pdf S3.9 "$q" "$f" "$dpdf"; then
           b=pass
           if ! s3_app_matches "$present_name" "$dpdf" && s3_app_matches "$(printf '%s\n' "$READBACK" | sed -n 1p)" "$present_name"; then
             b=fail; why="${why:+$why; }(b) the chosen app $present_name is frontmost although the default PDF app is $dpdf"
           fi
         else rc=$?; [ $rc = 2 ] && return $S1_RC; b=fail; why="${why:+$why; }(b) $S3_WHY"; fi ;;
      3) b=person; note="${note:+$note; }the Settings window needs a person" ;;
      *) b=person; note="${note:+$note; }the PDF app choice of Settings could not be driven for $present_name" ;;
    esac
  fi
  # the Settings choice goes back to Preview, so the next check starts from the default
  s3_choose_pdf_app Preview >/dev/null 2>&1
  if [ -n "$why" ] || [ "$a" = fail ] || [ "$b" = fail ]; then s1_fail S3.9 "${why:-a part failed}"; return 1; fi
  if [ "$a" = person ] || [ "$b" = person ]; then
    echo "CHECK S3.9 NEEDS-A-PERSON ${note:-a part needs a person}: (a) is $a, (b) is $b"
    return 0
  fi
  echo "CHECK S3.9 PASS (a) with ${absent_name:-no app} chosen Settings says it is not installed and Enter opened $dpdf, the default PDF app; (b) $b${present_name:+ with $present_name chosen}"
  return 0
}

# ---- S3.10: page boundaries do not lose text -------------------------------------------------------------------------------------

check_S3_10() { s1_run s3_check_10; }
s3_check_10() {
  local id q f loc rc rank pp why="" n=0
  golden_need; s3_need S3.10 $? || return $S1_RC
  while IFS=$'\t' read -r id q f loc <&3; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    s1_search "$q" --keep-open; rc=$?
    s1_search_ok S3.10 $rc || return $S1_RC
    rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
    if [ -z "$rank" ] || ! [ "$rank" -le 3 ]; then why="${why:+$why; }$id: ${f##*/} is ${rank:+row $rank}${rank:-not listed} for \"$q\", expected one of the first 3"; continue; fi
    if [ "$rank" -gt 1 ]; then s3_select_pane S3.10 "$q" "$rank" || return $S1_RC; fi
    pp="$(printf '%s\n' "$S1_OUT" | s3_pane_page)"
    [ "${pp%% *}" = "$loc" ] || why="${why:+$why; }$id: the pane of ${f##*/} says ${pp:+Page ${pp% *} of ${pp#* }}${pp:-no page}, expected the last page, Page $loc"
  done 3<<EOF
$(s3_rows boundary)
EOF
  [ "$n" -gt 0 ] || { echo "RERUN S3.10 not valid: fixtures/answers.csv holds no boundary row"; return 4; }
  if [ -n "$why" ]; then s1_fail S3.10 "$why"; return 1; fi
  echo "CHECK S3.10 PASS each of the $n boundary strings finds its PDF in the first 3 and names its last page (the 31-page file included, after Ready)"
  return 0
}

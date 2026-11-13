#!/bin/bash
# The golden evaluation's shared helpers (scripts/kit-golden.sh and scripts/kit-lib/checks-s2-golden.sh). Sourced after
# common.sh, never run. bash 3.2 compatible.
#
# The answer key is fixtures/answers.csv (verify.md, Fixture key): `id,group,query,file,locator,window_s,note`, no comma
# inside a field. A golden group is a letter of spec S2 (a photos, b exact words, c PDFs and documents, d audio and
# video); groups a (plan 1), b (plan 3), c (plan 4) and d (plan 5) are built. Group b scores the exact rows whose file is a photo
# (a selection of its own: read-kinds.txt lists the kinds that have a reader, which from plan 4 on are photo, document and pdf,
# and the pdf and document rows are group c's); group c is the pdf, doc and scanned rows of the key.
#
# golden-engine.tsv and golden-panel.tsv live in the evidence folder of the current starting state (the run folder when
# kit-reset.sh has not run). One header line, then one row per answer:
#   id <TAB> group <TAB> query <TAB> expected <TAB> rank <TAB> locator <TAB> pass [<TAB> page]
# `rank` is the 1-based place of the expected file in the list, or `none`; `pass` is first, top3 or miss; `page` (group c rows
# only) is the page the reading named for the expected file, or none. Later plans
# add their groups to the same files: a run of one group replaces that group's rows and keeps the others.

GOLDEN_ANSWERS="$KIT_PROJECT/fixtures/answers.csv"
GOLDEN_MIN_FIRST=6      # spec S2(a): the right photo first for at least 6 of 10 ...
GOLDEN_MIN_TOP3=9       # ... and within the first 3 for at least 9

# golden_kinds <letter> : the answers.csv groups that make up the golden group.
golden_kinds() {
  case "$1" in
    a) echo "photo" ;;
    b) echo "exact" ;;
    c) echo "pdf doc scanned" ;;
    d) echo "audio video" ;;
  esac
}

# golden_built <letter> : status 0 when the kit builds the group (a photos, b exact words, c PDFs and documents, d audio and video).
golden_built() { [ "$1" = a ] || [ "$1" = b ] || [ "$1" = c ] || [ "$1" = d ]; }

# golden_save_lines <engine|panel> <group letter> <text> : the GOLDEN lines of <text> (every line whose first word is GOLDEN, in order)
# saved to run/golden-lines-<mode>-<group>.txt, so that check_S2_15 can compare the panel run with the engine run. A later run of the
# same mode and group replaces the file. Always under $KIT_ROOT/run, whatever evidence folder is set. Every reset deletes run/, so a copy
# with a first line `VERSION <run/version>` is kept in $KIT_ROOT/golden-kept/.
golden_save_lines() {
  local v
  mkdir -p "$KIT_ROOT/run" "$KIT_ROOT/golden-kept" 2>/dev/null
  printf '%s\n' "$3" | awk '$1 == "GOLDEN"' > "$KIT_ROOT/run/golden-lines-$1-$2.txt"
  v="$(cat "$KIT_ROOT/run/version" 2>/dev/null)"
  { printf 'VERSION %s\n' "${v:-none}"; cat "$KIT_ROOT/run/golden-lines-$1-$2.txt"; } > "$KIT_ROOT/golden-kept/$1-$2.txt"
}

# golden_read_kinds : the kinds Sesame has a reader for, from $KIT_LIB/read-kinds.txt (one kind a line), comma separated.
# KIT_LIB is read when the function is called, so a test can point it at a folder of its own.
golden_read_kinds() {
  awk 'NF > 0 && $1 !~ /^#/ { printf "%s%s", sep, $1; sep = "," } END { if (sep != "") print "" }' "$KIT_LIB/read-kinds.txt" 2>/dev/null
}

# golden_rows <letter> : "id<TAB>query<TAB>file<TAB>locator" per answers.csv row of the golden group. Group b keeps only the
# exact rows whose expected file is a photo (an extension of the `photo` list of extensions.txt): a photo-only selection of its
# own, not read-kinds.txt, so that the pdf and document rows (which have readers from plan 4 on) go to group c and group b stays
# the six photo rows. Group c is the pdf, doc and scanned rows of the key (long60 and boundary rows belong to the S3 checks).
golden_rows() {
  awk -F, -v kinds="$(golden_kinds "$1")" -v filter="$([ "$1" = b ] && echo 1)" \
    -v ext="$KIT_LIB/extensions.txt" '
    BEGIN {
      n = split(kinds, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1
      if (filter != "") {
        while ((getline line < ext) > 0) {
          if (line ~ /^#/ || line == "") continue
          split(line, a, ": ")
          if (a[1] == "photo") { m = split(a[2], e, " "); for (i = 1; i <= m; i++) okext[e[i]] = 1 }
        }
      }
    }
    NR > 1 && ($2 in want) {
      if (filter != "") {
        f = $4; sub(/.*\//, "", f); x = ""
        if (f ~ /\./) { x = f; sub(/.*\./, "", x); x = tolower(x) }
        if (!(x in okext)) next
      }
      print $1 "\t" $3 "\t" $4 "\t" $5
    }' "$GOLDEN_ANSWERS"
}

# golden_key_rows <letter> : how many rows the key holds for the group, readable or not.
golden_key_rows() {
  awk -F, -v kinds="$(golden_kinds "$1")" '
    BEGIN { n = split(kinds, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
    NR > 1 && ($2 in want) { c++ }
    END { print c + 0 }' "$GOLDEN_ANSWERS"
}

# golden_whole_expect : the whole-folder index of group c (plan 4, kit-golden.sh prepare --whole): "<path under fixtures><TAB><status>"
# per file on disk under golden/photos and golden-docs whose extension belongs to a kind of read-kinds.txt (extensions.txt names
# the extensions). The status is `done`, except the password-protected and the damaged pdf (the `locked` and `damaged` lines of
# golden-docs.tsv, S3.8), which are `could_not_read`. Files of other roots (boundary) and files with no reader are not listed.
golden_whole_expect() {
  local fx="$KIT_ROOT/fixtures" folders all=""
  folders=("$fx/golden/photos" "$fx/golden-docs")
  # plan 5: `golden_whole_expect all` is the whole index of group d (kit-golden.sh prepare --all): golden-av too, and its damaged clips
  # (golden-av/damaged/) are could_not_read as the locked and the damaged pdf are
  if [ "${1:-}" = all ]; then folders+=("$fx/golden-av"); all=all; fi
  find "${folders[@]}" -type f 2>/dev/null | awk -v fx="$fx" -v ext="$KIT_LIB/extensions.txt" -v all="$all" \
    -v kinds="$(golden_read_kinds)" -v table="$KIT_LIB/golden-docs.tsv" '
    BEGIN {
      n = split(kinds, k, ","); for (i = 1; i <= n; i++) want[k[i]] = 1
      while ((getline line < ext) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, ": ")
        if (a[1] in want) { m = split(a[2], e, " "); for (i = 1; i <= m; i++) readable[e[i]] = 1 }
      }
      while ((getline line < table) > 0) {
        split(line, t, "\t")
        if (t[1] == "pdf" && (t[3] == "locked" || t[3] == "damaged")) unreadable["golden-docs/" t[2]] = 1
      }
    }
    {
      rel = $0
      if (index(rel, fx "/") == 1) rel = substr(rel, length(fx) + 2)
      f = rel; sub(/.*\//, "", f)
      if (f !~ /\./) next
      x = f; sub(/.*\./, "", x); x = tolower(x)
      if (!(x in readable)) next
      if (all == "all" && index(rel, "golden-av/damaged/") == 1) unreadable[rel] = 1
      print rel "\t" ((rel in unreadable) ? "could_not_read" : "done")
    }'
}

# golden_videospeech_row : "id<TAB>query<TAB>file<TAB>locator" of the videospeech row of the key (group d's own row, outside the 8 and 8).
golden_videospeech_row() {
  awk -F, 'NR > 1 && $2 == "videospeech" { print $1 "\t" $3 "\t" $4 "\t" $5; exit }' "$GOLDEN_ANSWERS"
}

# golden_line_d <id> <query> <file> <rank> <second> <why> : the printed line of a group d row: PASS when the expected file is in the first 3
# and its stated second is inside the true moment (golden_moment_right), else FAIL with the reason.
golden_line_d() {
  local word=FAIL why="$6"
  case "$(golden_pass "$4")" in first|top3) word=PASS ;; esac
  if [ "$word" = PASS ] && [ "$(golden_moment_right "$1" "$5")" != yes ]; then
    word=FAIL
    why="the stated moment $5 is outside the true one"
  fi
  if [ -n "$why" ]; then
    printf '%s %s query="%s" expected=%s rank=%s second=%s: %s\n' "$word" "$1" "$2" "$3" "$4" "$5" "$why"
  else
    printf '%s %s query="%s" expected=%s rank=%s second=%s\n' "$word" "$1" "$2" "$3" "$4" "$5"
  fi
}

# golden_moment_right <row id> <second> : yes when the second is inside [locator, locator + window_s] of the row of the key (window 30 for
# audio, 10 for video; both ends count), else no.
golden_moment_right() {
  awk -F, -v id="$1" -v sec="$2" '
    function mmss(s,    a) { split(s, a, ":"); return a[1] * 60 + a[2] }
    NR > 1 && $1 == id {
      loc = mmss($5)
      print (sec ~ /^[0-9]+$/ && sec + 0 >= loc && sec + 0 <= loc + $6) ? "yes" : "no"
      found = 1; exit
    }
    END { if (!found) print "no" }' "$GOLDEN_ANSWERS"
}

# golden_score_d <tsv> : "<audio rows> <audio first-3> <audio moment right> <video rows> <video first-3> <video moment right>" of the group d
# rows of golden-engine.tsv or golden-panel.tsv (`id group query expected rank locator pass second`); a row with no reading is a miss.
golden_score_d() {
  awk -F'\t' -v answers="$GOLDEN_ANSWERS" '
    function mmss(s,    a) { split(s, a, ":"); return a[1] * 60 + a[2] }
    BEGIN {
      while ((getline line < answers) > 0) { n = split(line, a, ","); if (n == 7) { grp[a[1]] = a[2]; loc[a[1]] = mmss(a[5]); win[a[1]] = a[6] + 0 } }
    }
    NR > 1 && $2 == "d" {
      g = grp[$1]
      hit = ($5 ~ /^[0-9]+$/ && $5 + 0 >= 1 && $5 + 0 <= 3)
      right = ($8 ~ /^[0-9]+$/ && $8 + 0 >= loc[$1] && $8 + 0 <= loc[$1] + win[$1])
      if (g == "audio") { na++; if (hit) af++; if (right) ar++ }
      else if (g == "video") { nv++; if (hit) vf++; if (right) vr++ }
    }
    END { printf "%d %d %d %d %d %d\n", na, af, ar, nv, vf, vr }' "$1"
}

# golden_line_d_summary <mode> <audio rows> <audio first-3> <audio moment> <video rows> <video first-3> <video moment> <videospeech yes|no>
# <v12 yes|no|none> : the verdict line of group d (spec S2(d): at least 7 of 8 audio and 7 of 8 video descriptions with the right file in the
# first 3 and at least 7 of 8 of each with the stated moment inside the true moment; S4.10: the videospeech row in the first 3 and clip-v12.mp4
# not above clip-v11.mp4); status 0 PASS, 1 FAIL. The rows of the key count, not the rows read.
golden_line_d_summary() {
  local mode="$1" v=FAIL
  if [ "$2" -gt 0 ] && [ "$5" -gt 0 ] && [ "$3" -ge 7 ] && [ "$4" -ge 7 ] && [ "$6" -ge 7 ] && [ "$7" -ge 7 ] && [ "$8" = yes ] && [ "$9" = no ]; then v=PASS; fi
  echo "GOLDEN $mode group d: audio first-3 $3 of $2, moment right $4 of $2; video first-3 $6 of $5, moment right $7 of $5; videospeech first-3 $8, v12 above $9: $v"
  [ "$v" = PASS ]
}

# golden_dir : where the two tsv files are written and read.
golden_dir() {
  local d
  d="$(kit_evidence_dir)"
  [ -n "$d" ] || d="$KIT_ROOT/run"
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$d"
}

# golden_pass <rank> : first, top3 or miss.
golden_pass() {
  case "$1" in
    1) echo first ;;
    2|3) echo top3 ;;
    *) echo miss ;;
  esac
}

# golden_line <id> <query> <file> <rank> <why> : the one printed line of a row.
golden_line() {
  local word=FAIL
  case "$(golden_pass "$4")" in first|top3) word=PASS ;; esac
  if [ -n "$5" ]; then
    printf '%s %s query="%s" expected=%s rank=%s: %s\n' "$word" "$1" "$2" "$3" "$4" "$5"
  else
    printf '%s %s query="%s" expected=%s rank=%s\n' "$word" "$1" "$2" "$3" "$4"
  fi
}

# golden_line_c <id> <query> <file> <rank> <page> <why> : the printed line of a group c row (PASS when the expected file is
# in the first 3); the page is the one the reading named for the expected file, or none.
golden_line_c() {
  local word=FAIL
  case "$(golden_pass "$4")" in first|top3) word=PASS ;; esac
  if [ -n "$6" ]; then
    printf '%s %s query="%s" expected=%s rank=%s page=%s: %s\n' "$word" "$1" "$2" "$3" "$4" "$5" "$6"
  else
    printf '%s %s query="%s" expected=%s rank=%s page=%s\n' "$word" "$1" "$2" "$3" "$4" "$5"
  fi
}

# golden_score_c <tsv> : "<pdf rows> <pdf first-3> <pdf page right> <doc rows> <doc first-3> <scanned first-3 yes|no>" of the group c
# rows of golden-engine.tsv or golden-panel.tsv (`id group query expected rank locator pass page`: the page the reading
# named). A pdf row is page right when its page is the key's locator; the groups of the rows come from the key.
golden_score_c() {
  awk -F'\t' -v answers="$GOLDEN_ANSWERS" '
    BEGIN {
      while ((getline line < answers) > 0) { n = split(line, a, ","); if (n == 7) grp[a[1]] = a[2] }
      scanned = "no"
    }
    NR > 1 && $2 == "c" {
      g = grp[$1]
      hit = ($5 ~ /^[0-9]+$/ && $5 + 0 >= 1 && $5 + 0 <= 3)
      if (g == "pdf") { np++; if (hit) pf++; if ($8 ~ /^[0-9]+$/ && $8 == $6) pr++ }
      else if (g == "doc") { nd++; if (hit) df++ }
      else if (g == "scanned" && hit) scanned = "yes"
    }
    END { printf "%d %d %d %d %d %s\n", np, pf, pr, nd, df, scanned }' "$1"
}

# golden_line_c_summary <mode> <pdf rows> <pdf first-3> <page right> <doc rows> <doc first-3> <scanned yes|no> : the verdict line of
# group c (spec S2(c): the right PDF in the first 3 for at least 9 of 10, its page right for at least 9 of 10, the right
# document in the first 3 for at least 5 of 6, and the scanned PDF in the first 3); status 0 PASS, 1 FAIL. The rows of the
# key count, not the rows read: a row with no reading is a miss.
golden_line_c_summary() {
  local mode="$1" np="$2" pf="$3" pr="$4" nd="$5" df="$6" sc="$7" v=FAIL
  if [ "$np" -gt 0 ] && [ "$pf" -ge 9 ] && [ "$pr" -ge 9 ] && [ "$df" -ge 5 ] && [ "$sc" = yes ]; then v=PASS; fi
  echo "GOLDEN $mode group c: pdf first-3 $pf of $np, page right $pr of $np; doc first-3 $df of $nd; scanned first-3 $sc: $v"
  [ "$v" = PASS ]
}

# golden_write_tsv <file> <letter> <rows file> : the group's rows replace the file's rows of that group.
golden_write_tsv() {
  local f="$1" g="$2" new="$3" tmp="$1.tmp.$$"
  {
    printf 'id\tgroup\tquery\texpected\trank\tlocator\tpass\tpage\n'
    [ -f "$f" ] && awk -F'\t' -v g="$g" 'NR > 1 && $2 != g' "$f"
    cat "$new"
  } > "$tmp" && mv "$tmp" "$f"
}

# golden_counts <file> <letter> : "<rows> <first> <top3>" of the group in the file; "0 0 0" when there is none.
golden_counts() {
  awk -F'\t' -v g="$2" '
    NR > 1 && $2 == g { n++; if ($5 ~ /^[0-9]+$/) { if ($5 + 0 == 1) first++; if ($5 + 0 <= 3) top++ } }
    END { printf "%d %d %d\n", n, first, top }' "$1" 2>/dev/null || echo "0 0 0"
}

# golden_verdict <rows> <first> <top3> <min first> : PASS or FAIL (at least one row, both counts reached).
golden_verdict() {
  if [ "$1" -gt 0 ] && [ "$2" -ge "$4" ] && [ "$3" -ge "$GOLDEN_MIN_TOP3" ]; then echo PASS; else echo FAIL; fi
}

# golden_line_b <mode> <readable> <first> <total> : the verdict line of group b (exact words); status 0 PASS, 1 FAIL.
# The bar is every readable row first. When every row of the key is readable the spec's bar applies, 19 of 20 first; with
# fewer readable rows the bar is every readable row, which is stricter and is never lowered. Nothing readable is FAIL.
golden_line_b() {
  local mode="$1" readable="$2" first="$3" total="$4" need text v=FAIL
  need="$readable"
  text="need every readable row first"
  if [ "$readable" -gt 0 ] && [ "$readable" -eq "$total" ]; then
    need=$((total - 1))
    text="need $need first"
  fi
  if [ "$readable" -gt 0 ] && [ "$first" -ge "$need" ]; then v=PASS; fi
  echo "GOLDEN $mode group b: first $first of $readable readable ($total rows in the key), $text: $v"
  [ "$v" = PASS ]
}

# golden_oddeven <tsv> <letter> : the odd-numbered and even-numbered rows of the group in golden-engine.tsv or
# golden-panel.tsv scored apart (the number is the one in the row id; a hit is rank 1): `odd first <x> of <n>, even first
# <y> of <m>`, and `noted: overfitting risk` when the even rows hit at least 2 fewer than the odd rows (spec S2.8 iv).
golden_oddeven() {
  awk -F'\t' -v g="$2" '
    NR > 1 && $2 == g {
      num = $1; sub(/.*[^0-9]/, "", num)
      if (num == "") next
      if (num % 2 == 1) { on++; if ($5 == 1) of++ } else { en++; if ($5 == 1) ef++ }
    }
    END {
      printf "odd first %d of %d, even first %d of %d\n", of, on, ef, en
      if (of - ef >= 2) print "noted: overfitting risk"
    }' "$1"
}

# golden_none_why <letter> : (the output of `swift test` on stdin) why a row of the group has no rank.
golden_none_why() {
  local g="$1" out up
  out="$(cat)"
  up="$(printf '%s' "$g" | tr 'a-z' 'A-Z')"
  case "$out" in
    *"No matching test cases"*|*"Test run with 0 tests"*|*"Executed 0 tests"*) echo "no group $g test yet" ;;
    *"error:"*) echo "Group${up}Tests did not build or run: $(printf '%s\n' "$out" | awk '/error:/ { l = $0 } END { print l }')" ;;
    *) echo "Group${up}Tests printed no GOLDEN line for this row" ;;
  esac
}

# golden_rank_lines : (the output of `swift test` on stdin) every `RANK <id> <n|none> odd|even` line of it, as printed.
golden_rank_lines() {
  awk '$1 == "RANK" && NF == 4 && ($3 ~ /^[0-9]+$/ || $3 == "none") && ($4 == "odd" || $4 == "even")'
}

#!/bin/bash
# kit-fixtures.sh ping | build golden|tree|empty|filler <rows>|homefolders|minimix|extra|overlap | expect listing <folder>
#                 | build matrix | build unrelated <n> | expect matrix | expect extensions [--kinds <list>]
#                 | expect counts <folder> | plant-model truncated|flipped | mutate <op> <path> ...
#                 | mutate random <n> --seed <s> <folder> | restore
#
# The fixture builder (verify.md, Kit scripts). Fixtures live under $KIT_ROOT/fixtures (outside the
# project, never a person's files); a folder name is read under that root, an absolute path as given.
# Part A: the golden photos, and the two expect checks. Part B: the fixture tree, the empty folder, the
# filler, the planted model and the mutations. Part C (plan 2): the home folders, the mini mix, the extra
# folder, and the unique-phrase mutations. Later tasks add the other builds.
#   ping                  makes one tiny ffmpeg clip, one say clip, one textutil document, one PDF and
#                         one git repo under $KIT_ROOT/run/ping and reads each back
#   build golden          draws the 40 golden photos from fixtures/answers.csv and the scene table
#                         scripts/kit-lib/golden-photos.tsv: fixed drawing, fixed file times, so two
#                         builds make the same bytes; a folder that is already right is left alone
#                         (the build is made in a temporary folder and compared byte for byte)
#   build golden-docs     (plan 4) fixtures/golden-docs, a sibling of golden (golden stays the 40 photos): pdfs/ holds the 20 golden
#                         pdfs (every pdfs/ path of fixtures/answers.csv, the 60-page pdf of page pictures with no text layer, the
#                         scanned pdf, a password-protected one and a damaged one; password kit-locked-7) and docs/ the six
#                         documents (txt, md, rtf, docx, html, odt), from scripts/kit-lib/golden-docs.tsv and the key; every file
#                         is written by this kit with no clock and no random byte, so two builds make the same bytes; same rule
#                         as the tree (nothing already right is rewritten, a stray file is removed); prints BUILT golden-docs
#                         or UNCHANGED golden-docs
#   build boundary        (plan 4, S3.10) fixtures/boundary: the pdfs of 1, 30 and 31 pages, the key's string on the last page of
#                         each; same rule; prints BUILT boundary or UNCHANGED boundary
#   build tree            the S8 fixture tree from scripts/kit-lib/tree.tsv (every excluded case of the
#                         spec once at least, one git repo); same rule: a tree that is already right
#                         is left alone, only a file that differs is written, a file not in the table
#                         is removed
#   build empty           the empty folder (S1.20, S1.21 a, the Doctor's picker ping)
#   build filler <rows>   ceil(rows / 3) small generated photos (three index rows a photo, guess G4) under
#                         filler/; a filler that is already right is not touched (no file rewritten, inodes
#                         and times kept) and prints FILLER UNCHANGED filler <rows> rows
#   build homefolders     the throwaway home's Desktop, Documents (with Documents/Work inside it, the overlap),
#                         Downloads, Pictures and Movies, and the git repo Developer/atlas-notes whose
#                         .gitignore excludes supported files, under $KIT_ROOT/home/, from scripts/kit-lib/home.tsv
#                         (different counts per kind per folder); only these folders are written, the rest of
#                         home/ is left alone; same rule as the tree: nothing already right is rewritten
#   build minimix         400 small generated photos under fixtures/minimix (the photos-only mini mix of the
#                         pause runs); nothing already right is rewritten
#   build extra           fixtures/extra (4 photos, 2 documents, 1 pdf: the folder S6.10 adds later), from home.tsv
#   build overlap         fixtures/overlap (S1.6): a parent folder that holds a photos/ subfolder and two loose
#                         photos, copied from fixtures/golden with their times kept, from scripts/kit-lib/overlap.tsv;
#                         a file that is already right is left alone, anything else under overlap/ is removed. Needs
#                         `build golden` first (it does not build golden itself)
#   build matrix          (plan 3) fixtures/matrix from scripts/kit-lib/gate-matrix.csv alone: pictures of every photo
#                         extension with their token drawn as text, text, code, pdf, audio and video cells, one sparse
#                         cell, one symbolic link, one damaged PNG, the repos (git init, no commit) and the .gitignore
#                         of the ignored cells; same rule as the tree: nothing already right is rewritten, a stray
#                         file is removed; prints BUILT matrix or UNCHANGED matrix
#   build unrelated <n>   (plan 3, S2.8 ii) fixtures/unrelated: exactly n small generated photos (1 to 9999) directly in the
#                         folder, unrel0001.jpg to unrel<n>.jpg, picture only (the pieces of the filler: file k has the
#                         same bytes whatever n is, every file its own bytes), none of whose names holds a word of the
#                         golden key; same rule as the tree: a photo that is already right is not rewritten, any other
#                         file or folder is removed; prints BUILT unrelated or UNCHANGED unrelated; a bad n is exit 2
#   expect matrix         MATRIX OK <n> cells, or exit 1 naming every cell whose file is missing
#   expect extensions [--kinds <list>]
#                         every extension of the kinds (all six without a list; the lists of extensions.txt) must have
#                         a fixture file under fixtures/golden, tree or matrix: FOUND <kind> <ext> <path> or
#                         MISSING <kind> <ext> per extension, exit 0 when none is missing, exit 4 when some are; the
#                         code extensions are never read: they are listed after a NEVER READ line as NEVER-READ <ext> <path>
#   expect listing <dir> prints the folder's files (relative paths) and checks the folder against the
#                         hand-written table (golden: the scene table; tree: tree.tsv; empty: nothing at all);
#                         any other folder prints only its supported files (the spec's extension lists), sorted,
#                         then LISTING OK <folder>: <n> paths
#   expect counts <dir>   prints the per-kind file counts from the hand-written extension table and
#                         checks them against scripts/kit-lib/expected-counts.tsv
#   plant-model truncated|flipped
#                         puts a bad copy of the text model file into the app's models/ folder under its
#                         real name: truncated is half the right size, flipped is the right size with one
#                         byte changed (from cache/ when the whole file is there, else made up); prints
#                         PLANTED <path> <size> bytes
#   mutate <op> <path>    one change to a file under $KIT_ROOT (never under cache/, never outside it), the
#                         original remembered for restore. Ops: create <path> [<text>] (a text file; prints
#                         CREATED <path> then PHRASE <unique phrase>, the phrase the file holds); edit <path>
#                         [<text>] [--same-size] (a .txt, .md or .html file is rewritten with a new unique
#                         phrase, printed as PHRASE, and a size that differs from before, or the same size with
#                         --same-size; any other file gets a line appended, or one byte changed with
#                         --same-size; the modified time is always new; prints EDITED <path> (size <a> to <b>
#                         bytes)); flip-byte <path> [<offset>] (one byte changed, size and modified time
#                         kept); touch <path> (modified time one hour later); rename <path> <new name>
#                         (RENAMED <path> to <name>); move <path> <folder> (MOVED <path> to <folder>);
#                         delete <path> (DELETED <path>)
#   mutate random <n> --seed <s> <folder>
#                         n changes (edit, same-size edit, rename, move, delete, create) to n different files of
#                         the folder, picked by the seed, each printed as the single op above: the same seed on
#                         the same folder does the same, with the same phrases
#   restore               puts every file changed by mutate back, last change first (bytes, size, time, name)
# Exit codes: 0 done; 1 failed; 2 usage; 3 a part is blocked here (ping: say in a sandbox).
. "$(dirname "$0")/kit-lib/common.sh"

FIX="$KIT_ROOT/fixtures"
ANSWERS="$KIT_PROJECT/fixtures/answers.csv"
SCENES="$KIT_LIB/golden-photos.tsv"
TREE="$KIT_LIB/tree.tsv"
PHOTO_TIME="202601151030.00"   # every generated photo and tree file: 2026-01-15 10:30:00 UTC
MUT="$KIT_ROOT/run/mutate"     # the journal of mutate, emptied by restore (kit-reset.sh wipes run/)

usage() {
  cat >&2 <<'EOF'
usage: kit-fixtures.sh ping
       kit-fixtures.sh build golden
       kit-fixtures.sh build golden-docs
       kit-fixtures.sh build boundary
       kit-fixtures.sh build golden-av
       kit-fixtures.sh build pauselong
       kit-fixtures.sh build mix500
       kit-fixtures.sh build tree
       kit-fixtures.sh build empty
       kit-fixtures.sh build filler <rows>
       kit-fixtures.sh build homefolders
       kit-fixtures.sh build minimix
       kit-fixtures.sh build extra
       kit-fixtures.sh build overlap
       kit-fixtures.sh build matrix
       kit-fixtures.sh build repos
       kit-fixtures.sh build unrelated <n>
       kit-fixtures.sh expect listing <folder>
       kit-fixtures.sh expect counts <folder>
       kit-fixtures.sh expect matrix
       kit-fixtures.sh expect extensions [--kinds <photo,document,audio,video,pdf,code>]
       kit-fixtures.sh plant-model truncated|flipped
       kit-fixtures.sh mutate create <path> [<text>]
       kit-fixtures.sh mutate edit <path> [<text>] [--same-size]
       kit-fixtures.sh mutate flip-byte <path> [<offset>]
       kit-fixtures.sh mutate touch <path>
       kit-fixtures.sh mutate rename <path> <new name>
       kit-fixtures.sh mutate move <path> <folder>
       kit-fixtures.sh mutate delete <path>
       kit-fixtures.sh mutate random <n> --seed <s> <folder>
       kit-fixtures.sh restore
EOF
}

# fx_dir <name> : the absolute folder for a fixture name or an absolute path.
fx_dir() {
  case "$1" in
    ""|*..*) return 1 ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$FIX/$1" ;;
  esac
}

# ---- fixtures/answers.csv and the scene table ------------------------------------------------

check_answers() {
  if [ ! -f "$ANSWERS" ]; then
    echo "fixtures/answers.csv is missing ($ANSWERS)"
    return 1
  fi
  if [ "$(head -1 "$ANSWERS")" != "id,group,query,file,locator,window_s,note" ]; then
    echo "fixtures/answers.csv: line 1 is not the header id,group,query,file,locator,window_s,note"
    return 1
  fi
  local bad
  bad="$(awk -F, 'NR > 1 && NF != 7 { print "fixtures/answers.csv line " NR " has " NF " fields, expected 7 (a comma inside a field is not allowed)" }' "$ANSWERS")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# answers_files <group> [<note>] : the file column of the rows of a group (with that exact note).
answers_files() {
  awk -F, -v g="$1" -v n="$2" 'NR > 1 && $2 == g && (n == "" || $7 == n) { print $4 }' "$ANSWERS"
}

# scene_rows : the data rows of the scene table.
scene_rows() {
  awk '!/^#/ && NF > 0' "$SCENES"
}

# validate_scenes : the table must have 40 well-formed rows whose targets and screenshots are exactly
# the files named by answers.csv (so the key and the files cannot drift).
validate_scenes() {
  if [ ! -f "$SCENES" ]; then
    echo "scripts/kit-lib/golden-photos.tsv is missing"
    return 1
  fi
  local bad
  bad="$(scene_rows | awk -F'\t' '
    NF != 8 { print "golden-photos.tsv: a row has " NF " fields, expected 8: " $1; next }
    $2 !~ /^(jpeg|png|heic|webp|tiff|gif)$/ { print "golden-photos.tsv: unknown format " $2 " for " $1 }
    $3 !~ /^(target|other|screenshot)$/ { print "golden-photos.tsv: unknown role " $3 " for " $1 }
    seen[$1]++ { print "golden-photos.tsv: " $1 " twice" }')"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  local n
  n="$(scene_rows | wc -l | tr -d ' ')"
  if [ "$n" != 40 ]; then
    echo "golden-photos.tsv has $n rows, the spec says 40 photos"
    return 1
  fi
  local want got
  want="$(answers_files photo | LC_ALL=C sort)"
  got="$(scene_rows | awk -F'\t' '$3 == "target" { print $1 }' | LC_ALL=C sort)"
  if [ "$want" != "$got" ]; then
    echo "the targets of golden-photos.tsv differ from the photo rows of fixtures/answers.csv"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got")
    return 1
  fi
  want="$(answers_files exact screenshot-only | LC_ALL=C sort -u)"
  got="$(scene_rows | awk -F'\t' '$3 == "screenshot" { print $1 }' | LC_ALL=C sort)"
  if [ "$want" != "$got" ]; then
    echo "the screenshots of golden-photos.tsv differ from the screenshot-only rows of fixtures/answers.csv"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got")
    return 1
  fi
  return 0
}

# ---- build golden ----------------------------------------------------------------------------

# build_photos_into <tmp> : draws the 40 photos under <tmp>/out with their fixed times.
build_photos_into() {
  local tmp="$1" tool path fmt role c1 c2 c3 objs text exact
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    return 1
  }
  : > "$tmp/jobs.tsv"
  while IFS=$'\t' read -r path fmt role c1 c2 c3 objs text; do
    if [ "$role" = screenshot ]; then
      exact="$(awk -F, -v p="$path" '$2 == "exact" && $4 == p && $7 == "screenshot-only" { printf "%s%s", sep, $3; sep = "|" }' "$ANSWERS")"
      text="${text//\{EXACT\}/$exact}"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$fmt" "$role" "$c1" "$c2" "$c3" "$objs" "$text" >> "$tmp/jobs.tsv"
  done < <(scene_rows)
  "$tool" photos "$tmp/jobs.tsv" "$tmp/out" || return 1
  while IFS=$'\t' read -r path _; do
    TZ=UTC touch -t "$PHOTO_TIME" "$tmp/out/$path" || return 1
  done < <(scene_rows)
  return 0
}

build_golden() {
  check_answers || return 1
  validate_scenes || return 1
  mkdir -p "$FIX" || return 1
  [ -f "$FIX/.metadata_never_index" ] || : > "$FIX/.metadata_never_index"
  local tmp rc
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  build_photos_into "$tmp"
  rc=$?
  if [ $rc != 0 ]; then
    rm -rf "$tmp"
    return $rc
  fi
  local dest="$FIX/golden" path new old written=0 same=0 removed=0 stray
  while IFS=$'\t' read -r path _; do
    new="$tmp/out/$path"
    old="$dest/$path"
    if [ -f "$old" ] && [ ! -L "$old" ] \
      && [ "$(shasum -a 256 < "$new")" = "$(shasum -a 256 < "$old")" ] \
      && [ "$(stat -f %m "$new")" = "$(stat -f %m "$old")" ]; then
      same=$((same + 1))
    else
      mkdir -p "$(dirname "$old")" && mv -f "$new" "$old" || { rm -rf "$tmp"; return 1; }
      written=$((written + 1))
    fi
  done < <(scene_rows)
  # A photo that is not in the table does not belong to the golden fixture.
  if [ -d "$dest/photos" ]; then
    while IFS= read -r stray; do
      if ! scene_rows | awk -F'\t' -v p="${stray#"$dest"/}" '$1 == p { found = 1 } END { exit !found }'; then
        rm -f "$stray"
        echo "REMOVED ${stray#"$dest"/}"
        removed=$((removed + 1))
      fi
    done < <(find "$dest/photos" -type f)
  fi
  rm -rf "$tmp"
  if [ $written = 0 ] && [ $removed = 0 ]; then
    echo "UNCHANGED golden photos: $same files already right, nothing written"
  else
    echo "BUILT golden photos: $written files written, $same left as they were, $removed removed"
  fi
  return 0
}

# ---- build golden-docs, build boundary (plan 4) -----------------------------------------------

DOCS_TABLE="$KIT_LIB/golden-docs.tsv"

# validate_docs : golden-docs.tsv and fixtures/answers.csv say the same thing: every pdf of the key has a pdf line (the two
# pdfs the key does not name are the locked and the damaged one), every pdf row has its passage (holding its anchor), every
# doc row its document (holding {ANCHOR}), the pages named by the key exist, and every line has its fields.
validate_docs() {
  if [ ! -f "$DOCS_TABLE" ]; then
    echo "scripts/kit-lib/golden-docs.tsv is missing"
    return 1
  fi
  local bad
  bad="$(awk -F'\t' -v answers="$ANSWERS" '
    function fail(m) { print "golden-docs.tsv: " m }
    function box_ok(s,    a) { return split(s, a, ":") == 4 }
    BEGIN {
      while ((getline line < answers) > 0) {
        if (++ln == 1) continue
        n = split(line, a, ",")
        if (n != 7) continue
        id = a[1]; grp[id] = a[2]; file[id] = a[4]; loc[id] = a[5]; ids[++nid] = id
        if (a[4] ~ /^(pdfs|boundary)\/.*\.pdf$/) keypdf[a[4]] = 1
        if (a[4] ~ /^docs\//) keydoc[a[4]] = 1
        np = split(a[7], parts, "; ")
        for (i = 1; i <= np; i++) {
          if (parts[i] ~ /^anchor=/) anchor[id] = substr(parts[i], 8)
          if (parts[i] ~ /^box=/) box[id] = substr(parts[i], 5)
        }
      }
    }
    /^#/ || NF == 0 { next }
    $1 == "pdf" {
      if (NF != 6) { fail("a pdf line has " NF " fields, expected 6: " $2); next }
      if ($3 !~ /^(text|picture|locked|damaged)$/) fail("unknown pdf kind " $3 " for " $2)
      if ($4 !~ /^[0-9]+$/ || $4 < 1) fail("bad page count for " $2)
      if (($2 in kind)) fail($2 " twice")
      kind[$2] = $3; pages[$2] = $4
      if ($3 == "locked" && $6 == "-") fail($2 " is locked and has no password")
      next
    }
    $1 == "page" {
      if (NF != 4) { fail("a page line has " NF " fields, expected 4"); next }
      pg[++npg] = $2 SUBSEP $3
      next
    }
    $1 == "passage" {
      if (NF != 3) { fail("a passage line has " NF " fields, expected 3"); next }
      passage[$2] = $3
      next
    }
    $1 == "doc" {
      if (NF != 3) { fail("a doc line has " NF " fields, expected 3"); next }
      if (($2 in doc)) fail($2 " twice")
      doc[$2] = $3
      next
    }
    { fail("unknown line type " $1) }
    END {
      for (p in keypdf) if (!(p in kind)) fail("the key names " p ", which has no pdf line")
      for (p in kind) {
        if (!(p in keypdf) && kind[p] != "locked" && kind[p] != "damaged") fail(p " is not named by the key and is neither locked nor damaged")
        if ((p in keypdf) && (kind[p] == "locked" || kind[p] == "damaged")) fail(p " is named by the key and is " kind[p])
        if (p !~ /^(pdfs|boundary)\/[^\/]+\.pdf$/) fail("bad pdf path " p)
      }
      for (p in keydoc) if (!(p in doc)) fail("the key names " p ", which has no doc line")
      for (p in doc) {
        if (!(p in keydoc)) fail(p " has a doc line and the key does not name it")
        if (index(doc[p], "{ANCHOR}") == 0) fail(p " does not hold {ANCHOR}")
        if (p !~ /^docs\/[^\/]+\.(txt|md|rtf|docx|html|odt)$/) fail("bad document path " p)
      }
      for (i = 1; i <= npg; i++) {
        split(pg[i], q, SUBSEP)
        if (!(q[1] in kind)) fail("a page line for " q[1] ", which has no pdf line")
        else if (kind[q[1]] == "picture") fail("a page line for " q[1] ", a picture pdf has no text")
        else if (q[2] + 0 > pages[q[1]] + 0) fail("a page line for page " q[2] " of " q[1] ", which has " pages[q[1]] " pages")
      }
      for (i = 1; i <= nid; i++) {
        id = ids[i]; g = grp[id]
        if (g == "pdf") {
          if (!(id in passage)) fail("no passage line for " id)
          else if (index(tolower(passage[id]), tolower(anchor[id])) == 0 || anchor[id] == "") fail("the passage of " id " does not hold its anchor")
          if (!box_ok(box[id])) fail(id " has no box=x:y:w:h of four numbers")
          if (kind[file[id]] != "text") fail(id ": " file[id] " is not a text pdf")
          else if (loc[id] + 0 > pages[file[id]] + 0) fail(id ": page " loc[id] " of " file[id] ", which has " pages[file[id]] " pages")
        } else if (g == "doc") {
          if (anchor[id] == "") fail(id " has no anchor=")
        } else if (g == "scanned" || g == "long60") {
          if (kind[file[id]] != "picture") fail(id ": " file[id] " is not a picture pdf")
          else if (loc[id] + 0 > pages[file[id]] + 0) fail(id ": page " loc[id] " of " file[id] ", which has " pages[file[id]] " pages")
          if (g == "scanned" && anchor[id] == "") fail(id " has no anchor=")
        } else if (g == "boundary") {
          if (kind[file[id]] != "text") fail(id ": " file[id] " is not a text pdf")
          else if (loc[id] + 0 != pages[file[id]] + 0) fail(id ": the string is on page " loc[id] ", the last page of " file[id] " is " pages[file[id]])
        }
      }
      for (id in passage) if (grp[id] != "pdf") fail("a passage line for " id ", which is not a pdf row of the key")
    }' "$DOCS_TABLE")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# docs_jobs <prefix> : the jobs file of `fixturegen pdfs` for the pdf lines of the table whose path starts with the prefix:
# the page lines, the passages of the pdf rows (inside the row's box), and the strings the key puts in the picture and
# boundary pdfs (the long60 strings on their pages, the scanned words, the last page string of each boundary pdf).
docs_jobs() {
  awk -F'\t' -v prefix="$1" -v answers="$ANSWERS" '
    function txt(path, page, x, y, w, h, size, text) {
      lines[path] = lines[path] sprintf("TXT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", page, x, y, w, h, size, text)
    }
    BEGIN {
      while ((getline line < answers) > 0) {
        if (++ln == 1) continue
        n = split(line, a, ",")
        if (n != 7) continue
        id = a[1]; grp[id] = a[2]; qry[id] = a[3]; file[id] = a[4]; loc[id] = a[5]; ids[++nid] = id
        if (a[2] == "exact" && !(a[4] in exactq)) exactq[a[4]] = a[3]
        np = split(a[7], parts, "; ")
        for (i = 1; i <= np; i++) {
          if (parts[i] ~ /^anchor=/) anchor[id] = substr(parts[i], 8)
          if (parts[i] ~ /^box=/) box[id] = substr(parts[i], 5)
        }
      }
    }
    /^#/ || NF == 0 { next }
    $1 == "pdf" && index($2, prefix) == 1 { order[++no] = $2; kind[$2] = $3; pages[$2] = $4; title[$2] = $5; pw[$2] = $6; next }
    $1 == "page" { pl[++npl] = $2 "\t" $3 "\t" $4; next }
    $1 == "passage" { passage[$2] = $3; next }
    END {
      for (i = 1; i <= npl; i++) {
        split(pl[i], q, "\t")
        if (!(q[1] in kind)) continue
        t = q[3]
        gsub(/\{EXACT\}/, exactq[q[1]], t)
        txt(q[1], q[2], 72, 620, 468, 40, 12, t)
      }
      for (i = 1; i <= nid; i++) {
        id = ids[i]; f = file[id]
        if (!(f in kind)) continue
        if (grp[id] == "pdf") { split(box[id], b, ":"); txt(f, loc[id], b[1], b[2], b[3], b[4], 12, passage[id]) }
        else if (grp[id] == "long60") txt(f, loc[id], 72, 420, 468, 120, 40, qry[id])
        else if (grp[id] == "scanned") txt(f, loc[id], 72, 450, 468, 200, 26, anchor[id])
        else if (grp[id] == "boundary") txt(f, loc[id], 72, 500, 468, 40, 18, qry[id])
      }
      for (i = 1; i <= no; i++) {
        p = order[i]
        printf "PDF\t%s\t%s\t%s\t%s\t%s\n", p, kind[p], pages[p], title[p], pw[p]
        printf "%s", lines[p]
      }
    }' "$DOCS_TABLE"
}

# docs_pdfs_into <prefix> <out> : the pdfs of the table under the prefix, written into <out>/<path> by fixturegen.
docs_pdfs_into() {
  local tool jobs rc
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    return 1
  }
  jobs="$(mktemp "$KIT_TMP/kit-docs-jobs.XXXXXX")" || return 1
  docs_jobs "$1" > "$jobs"
  "$tool" pdfs "$jobs" "$2" > /dev/null < /dev/null
  rc=$?
  rm -f "$jobs"
  return $rc
}

# make_document <dest> <path under golden-docs> <template text> : one document of the format of its extension. {ANCHOR} is the
# anchor= phrase of the doc row of the key for the file, {EXACT} the query of the first exact row whose file it is; \n is a
# line break. The text holds no & < > (the docx and the odt are written by hand: textutil stamps the clock).
make_document() {
  local dest="$1" path="$2" text="$3" anchor exact ext nl=$'\n' rtf html
  anchor="$(awk -F, -v p="$path" '$2 == "doc" && $4 == p { n = split($7, a, "; "); for (i = 1; i <= n; i++) if (a[i] ~ /^anchor=/) { print substr(a[i], 8); exit } }' "$ANSWERS")"
  exact="$(awk -F, -v p="$path" '$2 == "exact" && $4 == p { print $3; exit }' "$ANSWERS")"
  text="${text//\{ANCHOR\}/$anchor}"
  text="${text//\{EXACT\}/$exact}"
  text="${text//\\n/$nl}"
  ext="$(printf '%s' "${path##*.}" | tr 'A-Z' 'a-z')"
  mkdir -p "$(dirname "$dest")" || return 1
  case "$ext" in
    txt|md) printf '%s\n' "$text" > "$dest" ;;
    rtf)
      rtf="${text//$nl/\\par }"
      printf '%s\n' "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 $rtf\\par}" > "$dest" ;;
    html)
      html="${text//$nl$nl/</p><p>}"
      printf '<html><head><meta charset="utf-8"><title>%s</title></head><body><p>%s</p></body></html>\n' "${path##*/}" "$html" > "$dest" ;;
    docx) mk_docx "$dest" "${text//$nl/ }" ;;
    odt) mk_odt "$dest" "${text//$nl/ }" ;;
    *) echo "golden-docs.tsv: no format for .$ext ($path)"; return 1 ;;
  esac
}

# docs_sync <out> <dest> <label> : the built folder becomes the fixture folder (same rule as the tree: only a file that differs is
# written, a file that is not built is removed) and says BUILT or UNCHANGED.
docs_sync() {
  local res w k r
  find "$1" -exec env TZ=UTC touch -h -t "$PHOTO_TIME" {} + || return 1
  res="$(sync_into "$1" "$2")" || { echo "could not put $3 in place"; return 1; }
  read -r w k r <<< "$res"
  if [ "$w" = 0 ] && [ "$r" = 0 ]; then
    echo "UNCHANGED $3: $k files already right, nothing written"
  else
    echo "BUILT $3: $w files written, $k left as they were, $r removed"
  fi
}

# build_golden_docs : fixtures/golden-docs/pdfs (20 pdfs) and fixtures/golden-docs/docs (the six documents), a sibling of
# golden (which stays photo-only), from scripts/kit-lib/golden-docs.tsv and fixtures/answers.csv. Two builds make the same
# bytes (every file is written by this kit, the locked pdf with a fixed file id and fixed passwords).
build_golden_docs() {
  check_answers || return 1
  validate_docs || return 1
  fx_marker || return 1
  local tmp out path text rc
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out/pdfs" "$out/docs"
  docs_pdfs_into pdfs/ "$out" || { echo "could not make the golden pdfs"; rm -rf "$tmp"; return 1; }
  while IFS=$'\t' read -r _ path text; do
    make_document "$out/$path" "$path" "$text" || { echo "could not make golden-docs/$path"; rm -rf "$tmp"; return 1; }
  done < <(awk -F'\t' '$1 == "doc"' "$DOCS_TABLE")
  docs_sync "$out" "$FIX/golden-docs" golden-docs
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# build_boundary : fixtures/boundary with the pdfs of 1, 30 and 31 pages (S3.10), the key's string on the last page of each.
build_boundary() {
  check_answers || return 1
  validate_docs || return 1
  fx_marker || return 1
  local tmp out rc
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out/boundary"
  docs_pdfs_into boundary/ "$out" || { echo "could not make the boundary pdfs"; rm -rf "$tmp"; return 1; }
  docs_sync "$out/boundary" "$FIX/boundary" boundary
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# ---- build golden-av (plan 5) -----------------------------------------------------------------

AV_TABLE="$KIT_LIB/golden-av.tsv"
AV_VOICE="Samantha"          # the one fixed voice of every spoken line
AV_RATE=16000                # every clip is mono at this rate

# av_lines : the data lines of golden-av.tsv.
av_lines() { awk -F'\t' '!/^#/ && NF >= 2' "$AV_TABLE"; }

# av_segments <path> : "<start s><TAB><gain><TAB><text>" for every spoken line of the clip: its say lines, the sentence of its key row (the
# note, spoken from the row's locator) and its filler (counting, one line every 5 s, the gain by the slot).
av_segments() {
  awk -F'\t' -v p="$1" -v answers="$ANSWERS" '
    function mmss(s,    a) { split(s, a, ":"); return a[1] * 60 + a[2] }
    BEGIN {
      split("one two three four five six seven|eight nine ten eleven twelve|thirteen fourteen fifteen sixteen seventeen|alpha bravo charlie delta echo|nine eight seven six five four|twenty twenty one twenty two twenty three", ph, "|")
      while ((getline line < answers) > 0) {
        n = split(line, a, ",")
        if (n == 7 && (a[2] == "audio" || a[2] == "videospeech")) { loc[a[4]] = mmss(a[5]); note[a[4]] = a[7] }
      }
    }
    /^#/ { next }
    $1 == "say" && $2 == p { printf "%s\t%s\t%s\n", $3, $4, $5 }
    $1 == "sentence" && $2 == p { if (!($2 in loc)) exit 1; printf "%s\t%s\t%s\n", loc[$2], $3, note[$2] }
    $1 == "filler" && $2 == p {
      ng = split($5, g, ",")
      for (t = $3; t + 5 <= $4; t += 5) { k = t / 5; printf "%s\t%s\t%s\n", t + (k * 2 % 3) * 0.5, g[k % ng + 1], ph[k % 6 + 1] }
    }' "$AV_TABLE"
}

# validate_av : golden-av.tsv and fixtures/answers.csv say the same thing: every audio row and the videospeech row has its clip and its
# sentence line in the table, and every audio/ or video/ file the key names has a clip line.
validate_av() {
  if [ ! -f "$AV_TABLE" ]; then
    echo "scripts/kit-lib/golden-av.tsv is missing"
    return 1
  fi
  local bad
  bad="$(awk -F'\t' -v answers="$ANSWERS" '
    function mmss(s,    a) { split(s, a, ":"); return a[1] * 60 + a[2] }
    BEGIN {
      while ((getline line < answers) > 0) {
        n = split(line, a, ",")
        if (n != 7) continue
        if (a[4] ~ /^(audio|video)\//) want[a[4]] = 1
        if (a[2] == "audio" || a[2] == "videospeech") sent[a[4]] = a[1]
        if (a[2] == "video") vrow[a[4]] = mmss(a[5])
      }
    }
    /^#/ || NF < 2 { next }
    $1 == "aclip" { have[$2] = 1; next }
    $1 == "vclip" { have[$2] = 1; secs[$2] = $3; next }
    $1 == "sentence" { said[$2] = 1; next }
    $1 == "shot" {
      if (!($2 in pos)) pos[$2] = 0
      if ($3 + 0 != pos[$2]) print "golden-av.tsv: a shot of " $2 " starts at " $3 " where the one before ends at " pos[$2]
      pos[$2] = $3 + $4; dur[$2, $3 + 0] = $4 + 0
      next
    }
    END {
      for (f in want) if (!(f in have)) print "golden-av.tsv: no clip line for " f ", which the key names"
      for (f in sent) if (!(f in said)) print "golden-av.tsv: no sentence line for " f " (row " sent[f] ")"
      for (f in said) if (!(f in sent)) print "golden-av.tsv: a sentence line for " f ", which no audio or videospeech row names"
      for (f in secs) if (pos[f] != secs[f] + 0) print "golden-av.tsv: the shots of " f " end at " pos[f] ", the clip is " secs[f] " s"
      for (f in vrow) if (dur[f, vrow[f]] != 10) print "golden-av.tsv: " f " has no 10 s shot starting at its row" "s locator (" vrow[f] " s)"
    }' "$AV_TABLE")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# av_say <text> <cache dir> : the path of the spoken text as an aiff (made once a text; say writes a tiny empty file when the speech
# service is refused, which is NEEDS A PERSON, never a clip of silence).
av_say() {
  local key f
  key="$(printf '%s' "$AV_VOICE|$1" | shasum -a 256 | cut -c1-16)"
  f="$2/$key.aiff"
  if [ ! -s "$f" ]; then
    say -v "$AV_VOICE" -o "$f" "$1" < /dev/null > /dev/null 2>&1
    if [ ! -s "$f" ] || [ "$(stat -f %z "$f")" -le 4096 ]; then
      rm -f "$f"
      echo "NEEDS A PERSON: say made no speech here (the speech service is refused or the voice $AV_VOICE is not installed); run it from your own Terminal"
      return 3
    fi
  fi
  printf '%s\n' "$f"
}

# av_mix <clip path> <seconds> <out wav> <say cache> : the clip's spoken lines placed in digital silence of its length (a line after a line, never
# over it), mono at 16 kHz.
av_mix() {
  local path="$1" secs="$2" out="$3" cache="$4" segsrc="${5:-}" args graph="" labels="" n=0 start gain text f ms rc
  args=(-nostdin -v error -y -f lavfi -i "anullsrc=r=$AV_RATE:cl=mono:d=$secs")
  while IFS=$'\t' read -r start gain text; do
    f="$(av_say "$text" "$cache")"; rc=$?
    [ $rc = 0 ] || { printf '%s\n' "$f"; return $rc; }
    n=$((n + 1))
    ms="$(awk -v s="$start" 'BEGIN { printf "%d", s * 1000 }')"
    args+=(-i "$f")
    graph="$graph[$n:a]aresample=$AV_RATE,aformat=channel_layouts=mono,volume=$gain,adelay=$ms:all=1[s$n];"
    labels="$labels[s$n]"
  done < <(if [ -n "$segsrc" ]; then cat "$segsrc"; else av_segments "$path"; fi)
  if [ $n = 0 ]; then
    args+=(-ac 1 -ar "$AV_RATE" -c:a pcm_s16le -f wav)
  else
    graph="${graph}[0:a]${labels}amix=inputs=$((n + 1)):normalize=0:duration=first[m]"
    args+=(-filter_complex "$graph" -map "[m]" -ac 1 -ar "$AV_RATE" -c:a pcm_s16le -f wav)
  fi
  ffmpeg "${args[@]}" -fflags +bitexact -flags:a +bitexact -map_metadata -1 "$out" < /dev/null
}

# av_encode <in wav> <out file> : the codec of the extension (wav, mp3, m4a, aac, flac), no tag and no clock.
av_encode() {
  local codec
  case "${2##*.}" in
    wav) codec=(-c:a pcm_s16le -f wav) ;;
    mp3) codec=(-c:a libmp3lame -b:a 48k -f mp3) ;;
    m4a) codec=(-c:a aac -b:a 48k -f ipod) ;;
    aac) codec=(-c:a aac -b:a 48k -f adts) ;;
    flac) codec=(-c:a flac -f flac) ;;
    *) echo "golden-av.tsv: no codec for .${2##*.} ($2)"; return 1 ;;
  esac
  ffmpeg -nostdin -v error -y -i "$1" -ac 1 -ar "$AV_RATE" "${codec[@]}" -fflags +bitexact -flags:a +bitexact -map_metadata -1 "$2" < /dev/null
}

# av_audio_into <out> <say cache> : every audio clip of the table, written under <out>/<path>.
av_audio_into() {
  local out="$1" cache="$2" path secs wav rc
  wav="$out/.mix.wav"
  while IFS=$'\t' read -r _ path secs; do
    mkdir -p "$(dirname "$out/$path")" || return 1
    av_mix "$path" "$secs" "$wav" "$cache"; rc=$?
    [ $rc = 0 ] || { [ $rc = 3 ] || echo "could not mix golden-av/$path"; return $rc; }
    av_encode "$wav" "$out/$path" || { echo "could not encode golden-av/$path"; return 1; }
  done < <(awk -F'\t' '$1 == "aclip"' "$AV_TABLE")
  rm -f "$wav"
}

# av_video_mux <video-only mp4> <audio m4a or -> <seconds> <out> : the clip in the container of its extension (mp4, mov, m4v), no tag
# and no clock; the moov box stays at the end, as ffmpeg writes it by default (the damaged clip is cut from such a file).
av_video_mux() {
  local fmt maps=(-map 0:v) inputs=(-i "$1")
  case "$4" in *.mov) fmt=mov ;; *.m4v) fmt=ipod ;; *) fmt=mp4 ;; esac
  if [ "$2" != - ]; then inputs+=(-i "$2"); maps+=(-map 1:a); fi
  ffmpeg -nostdin -v error -y "${inputs[@]}" "${maps[@]}" -c copy -t "$3" -f "$fmt" -fflags +bitexact -flags +bitexact -map_metadata -1 "$4" < /dev/null
}

# av_video_into <out> <say cache> : every video clip of the table under <out>/<path>: its shots drawn like the golden photos (the
# `photos` command of fixturegen, one picture a shot), shown for their length at 5 frames a second, scaled to 320 x 240 and encoded as
# h264 on one thread (the same bytes twice); a soundtrack is the clip's spoken lines (`speech`) or digital silence (`silent`).
av_video_into() {
  local out="$1" cache="$2" tool path secs audio d rc soundtrack
  tool="$(kit_tool fixturegen)" || { echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"; return 1; }
  d="$out/.v"
  while IFS=$'\t' read -r _ path secs audio; do
    rm -rf "$d"; mkdir -p "$d" "$(dirname "$out/$path")" || return 1
    awk -F'\t' -v p="$path" '$1 == "shot" && $2 == p { n++; o = $8; if (o == "-") o = ""; t = ($5 == $6 && o == "") ? "-" : ($3 + 1) * 31 + length(p) * 7; printf "scene-%d.png\tpng\tother\t%s\t%s\t%s\t%s\t%s\n", n, $5, $6, $7, o, t }' "$AV_TABLE" > "$d/jobs.tsv"
    "$tool" photos "$d/jobs.tsv" "$d" > /dev/null < /dev/null || { echo "could not draw the shots of golden-av/$path"; return 1; }
    awk -F'\t' -v p="$path" '$1 == "shot" && $2 == p { n++; printf "file scene-%d.png\nduration %s\n", n, $4 } END { printf "file scene-%d.png\n", n }' "$AV_TABLE" > "$d/list.txt"
    ffmpeg -nostdin -v error -y -f concat -safe 0 -i "$d/list.txt" -vf "fps=5,scale=320:240:flags=bicubic,format=yuv420p" \
      -c:v libx264 -preset medium -crf 28 -g 25 -bf 0 -threads 1 -x264-params threads=1:lookahead-threads=1 -an -t "$secs" \
      -fflags +bitexact -flags:v +bitexact -map_metadata -1 -f mp4 "$d/video.mp4" < /dev/null || { echo "could not encode golden-av/$path"; return 1; }
    soundtrack=-
    if [ "$audio" != none ]; then
      av_mix "$path" "$secs" "$d/audio.wav" "$cache"; rc=$?
      [ $rc = 0 ] || { [ $rc = 3 ] || echo "could not mix the soundtrack of golden-av/$path"; return $rc; }
      av_encode "$d/audio.wav" "$d/audio.m4a" || return 1
      soundtrack="$d/audio.m4a"
    fi
    av_video_mux "$d/video.mp4" "$soundtrack" "$secs" "$out/$path" || { echo "could not write golden-av/$path"; return 1; }
  done < <(awk -F'\t' '$1 == "vclip"' "$AV_TABLE")
  rm -rf "$d"
}

# build_golden_av : fixtures/golden-av/{audio,video,damaged}, a sibling of golden (which stays the 40 photos), from scripts/kit-lib/golden-av.tsv
# and fixtures/answers.csv. Two builds make the same bytes (say is repeatable for one voice and one text, ffmpeg writes no tag and no clock).
build_golden_av() {
  check_answers || return 1
  validate_av || return 1
  fx_marker || return 1
  command -v ffmpeg > /dev/null 2>&1 || { echo "NEEDS A PERSON: ffmpeg is not on the path (brew install ffmpeg)"; return 3; }
  local tmp out rc tool
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out/audio" "$out/video" "$out/damaged" "$tmp/say"
  av_audio_into "$out" "$tmp/say"; rc=$?
  if [ $rc != 0 ]; then rm -rf "$tmp"; return $rc; fi
  tool="$(kit_tool fixturegen)" || { echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"; rm -rf "$tmp"; return 1; }
  av_video_into "$out" "$tmp/say"; rc=$?
  if [ $rc != 0 ]; then rm -rf "$tmp"; return $rc; fi
  "$tool" noise "$out/damaged/broken.m4a" 6000 7 || { rm -rf "$tmp"; return 1; }
  # a real mp4 cut in half: its moov box is at the end, so no reader can open what is left
  head -c "$(($(stat -f %z "$out/video/safari-giraffe.mp4") / 2))" "$out/video/safari-giraffe.mp4" > "$out/damaged/broken.mp4" || { rm -rf "$tmp"; return 1; }
  docs_sync "$out" "$FIX/golden-av" golden-av
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# ---- build pauselong, build mix500 (plan 5) ---------------------------------------------------

# av_concat_video <dir holding scene-N.png and list.txt> <seconds> <out mp4> : the shots of list.txt as h264 at 5 frames a second, 320 x 240.
av_concat_video() {
  ffmpeg -nostdin -v error -y -f concat -safe 0 -i "$1/list.txt" -vf "fps=5,scale=320:240:flags=bicubic,format=yuv420p" \
    -c:v libx264 -preset medium -crf 28 -g 15 -bf 0 -threads 1 -x264-params threads=1:lookahead-threads=1 -an -t "$2" \
    -fflags +bitexact -flags:v +bitexact -map_metadata -1 -f mp4 "$3" < /dev/null
}

# build_pauselong : fixtures/pauselong/audio/long-60min.m4a (60 minutes, never silent: a quiet 330 Hz tone whose loudness steps every 30 s
# through six levels), fixtures/pauselong/video/long-2min.mp4 (2 minutes, a new scene every 3 s, each with its own faint pattern, so no
# frame is dropped as a repeat of the one before) and fixtures/pauselong/pdf/annual-report-60p.pdf (the 60-page PDF of golden-docs.tsv).
# Same rule as the other builds.
build_pauselong() {
  fx_marker || return 1
  command -v ffmpeg > /dev/null 2>&1 || { echo "NEEDS A PERSON: ffmpeg is not on the path (brew install ffmpeg)"; return 3; }
  local tmp out tool d i rc
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"; d="$tmp/shots"
  mkdir -p "$out/audio" "$out/video" "$d"
  tool="$(kit_tool fixturegen)" || { echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"; rm -rf "$tmp"; return 1; }
  ffmpeg -nostdin -v error -y -f lavfi -i "sine=frequency=330:sample_rate=$AV_RATE:duration=3600" \
    -af "volume='0.03+0.05*mod(floor(t/30),6)':eval=frame" -ac 1 -c:a aac -b:a 24k -f ipod \
    -fflags +bitexact -flags:a +bitexact -map_metadata -1 "$out/audio/long-60min.m4a" < /dev/null || { echo "could not make long-60min.m4a"; rm -rf "$tmp"; return 1; }
  : > "$d/jobs.tsv"; : > "$d/list.txt"
  for ((i = 1; i <= 40; i++)); do
    printf 'scene-%d.png\tpng\tother\t#ffffff\t#ffffff\t-\t\t%d\n' "$i" $((i * 37 + 11)) >> "$d/jobs.tsv"
    printf 'file scene-%d.png\nduration 3\n' "$i" >> "$d/list.txt"
  done
  printf 'file scene-40.png\n' >> "$d/list.txt"
  "$tool" photos "$d/jobs.tsv" "$d" > /dev/null < /dev/null || { echo "could not draw the scenes of long-2min.mp4"; rm -rf "$tmp"; return 1; }
  av_concat_video "$d" 120 "$out/video/long-2min.mp4" || { echo "could not make long-2min.mp4"; rm -rf "$tmp"; return 1; }
  # the pdf unit of S7.2: the 60-page PDF of golden-docs.tsv, alone in a folder of its own (the recipe pauselong picks one folder a unit)
  check_answers && validate_docs || { rm -rf "$tmp"; return 1; }
  mkdir -p "$out/pdf" "$tmp/pdfwork/pdfs"
  docs_pdfs_into pdfs/annual-report-60p.pdf "$tmp/pdfwork" && cp "$tmp/pdfwork/pdfs/annual-report-60p.pdf" "$out/pdf/annual-report-60p.pdf" || { echo "could not make annual-report-60p.pdf"; rm -rf "$tmp"; return 1; }
  docs_sync "$out" "$FIX/pauselong" pauselong
  rc=$?
  rm -rf "$tmp"
  return $rc
}

MIX_TABLE="$KIT_LIB/mix500.tsv"

# mix_text <seed> <characters> : ASCII sentences of the vocabulary of mix500.tsv, at least that many characters, the same text for the same seed.
mix_text() {
  awk -v seed="$1" -v want="$2" -v table="$MIX_TABLE" '
    BEGIN {
      while ((getline line < table) > 0) { split(line, f, "\t"); if (f[1] == "words") nw = split(f[2], w, " ") }
      s = (seed * 131 + 7) % 65537; text = ""; count = 0
      while (length(text) < want) {
        s = (s * 75 + 74) % 65537
        word = w[s % nw + 1]
        if (count % 9 == 0) word = toupper(substr(word, 1, 1)) substr(word, 2)
        text = text (count == 0 ? "" : " ") word
        count++
        if (count % 9 == 0) text = text "."
      }
      if (substr(text, length(text)) != ".") text = text "."
      print text
    }'
}

# mix_docs_into <out> : 120 documents, 20 of each of txt, md, rtf, docx, html and odt, of about 1,000 characters.
mix_docs_into() {
  local i ext text path
  mkdir -p "$1/docs" || return 1
  for ((i = 0; i < 120; i++)); do
    case $((i % 6)) in 0) ext=txt ;; 1) ext=md ;; 2) ext=rtf ;; 3) ext=docx ;; 4) ext=html ;; *) ext=odt ;; esac
    path="$1/docs/note-$(printf '%03d' "$i").$ext"
    text="$(mix_text $((i + 1)) 1000)"
    case "$ext" in
      txt|md) printf '%s\n' "$text" > "$path" ;;
      rtf) printf '%s\n' "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 $text\\par}" > "$path" ;;
      html) printf '<html><head><meta charset="utf-8"><title>note %s</title></head><body><p>%s</p></body></html>\n' "$i" "$text" > "$path" ;;
      docx) mk_docx "$path" "$text" ;;
      odt) mk_odt "$path" "$text" ;;
    esac || return 1
  done
}

# mix_pdfs_into <out> <tool> : 100 PDFs of 5 to 12 pages, a paragraph of about 600 characters on every page.
mix_pdfs_into() {
  local i p pages jobs
  mkdir -p "$1/pdfs" || return 1
  jobs="$1/.pdfjobs.tsv"
  : > "$jobs"
  for ((i = 0; i < 100; i++)); do
    pages=$((5 + i % 8))
    printf 'PDF\tpdfs/report-%03d.pdf\ttext\t%d\tReport %d\t-\n' "$i" "$pages" "$i" >> "$jobs"
    for ((p = 1; p <= pages; p++)); do
      printf 'TXT\t%d\t72\t300\t468\t360\t11\t%s\n' "$p" "$(mix_text $((i * 13 + p + 500)) 600)" >> "$jobs"
    done
  done
  "$2" pdfs "$jobs" "$1" > /dev/null < /dev/null || return 1
  rm -f "$jobs"
}

# mix_audio_into <out> <say cache> : 40 audio files of 60 s (m4a and mp3 by turns): four spoken lines 15 s apart, silence between them.
mix_audio_into() {
  local i ext path rc
  mkdir -p "$1/audio" || return 1
  for ((i = 0; i < 40; i++)); do
    ext=m4a; [ $((i % 2)) = 1 ] && ext=mp3
    path="audio/rec-$(printf '%02d' "$i").$ext"
    awk -v i="$i" -v table="$MIX_TABLE" 'BEGIN {
      while ((getline line < table) > 0) { split(line, f, "\t"); if (f[1] == "sentence") s[++n] = f[2] }
      for (k = 0; k < 4; k++) printf "%d\t1.0\t%s\n", 2 + 15 * k + i % 3, s[(i + k * 7 + int(i / 24) * 3) % n + 1]
    }' > "$1/.segs"
    av_mix "$path" 60 "$1/.mix.wav" "$2" "$1/.segs"; rc=$?
    [ $rc = 0 ] || { [ $rc = 3 ] || echo "could not mix mix500/$path"; return $rc; }
    av_encode "$1/.mix.wav" "$1/$path" || { echo "could not encode mix500/$path"; return 1; }
  done
  rm -f "$1/.segs" "$1/.mix.wav"
}

# mix_video_into <out> <tool> : 20 videos of 30 s (mp4, mov and m4v by turns), three shots each from the ten scenes of mix500.tsv.
mix_video_into() {
  local out="$1" tool="$2" d="$1/.mv" i a b c d1 ext
  mkdir -p "$d" "$out/video" || return 1
  awk -F'\t' '$1 == "scene" { n++; printf "scene-%d.png\tpng\tother\t%s\t%s\t%s\t%s\t%d\n", n, $2, $3, $4, $5, n * 53 + 5 }' "$MIX_TABLE" > "$d/jobs.tsv"
  "$tool" photos "$d/jobs.tsv" "$d" > /dev/null < /dev/null || return 1
  for ((i = 0; i < 20; i++)); do
    a=$((i % 10 + 1)); b=$(((i * 3 + 1) % 10 + 1)); c=$(((i * 7 + 2) % 10 + 1)); d1=$((8 + i % 7))
    printf 'file scene-%d.png\nduration %d\nfile scene-%d.png\nduration 10\nfile scene-%d.png\nduration %d\nfile scene-%d.png\n' "$a" "$d1" "$b" "$c" $((20 - d1)) "$c" > "$d/list.txt"
    case $((i % 3)) in 0) ext=mp4 ;; 1) ext=mov ;; *) ext=m4v ;; esac
    av_concat_video "$d" 30 "$d/v.mp4" || return 1
    av_video_mux "$d/v.mp4" - 30 "$out/video/clip-$(printf '%02d' "$i").$ext" || return 1
  done
  rm -rf "$d"
}

# build_mix500 : fixtures/mix500, the 500-file mix of the spec (S6.11): photos/ 220, docs/ 120, pdfs/ 100, audio/ 40, video/ 20, no code.
build_mix500() {
  fx_marker || return 1
  command -v ffmpeg > /dev/null 2>&1 || { echo "NEEDS A PERSON: ffmpeg is not on the path (brew install ffmpeg)"; return 3; }
  [ -f "$MIX_TABLE" ] || { echo "scripts/kit-lib/mix500.tsv is missing"; return 1; }
  local tmp out tool epoch rc
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out" "$tmp/say"
  tool="$(kit_tool fixturegen)" || { echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"; rm -rf "$tmp"; return 1; }
  epoch="$(TZ=UTC date -j -f '%Y%m%d%H%M.%S' "$PHOTO_TIME" +%s)" || { rm -rf "$tmp"; return 1; }
  "$tool" filler-write "$out/photos" 220 "$epoch" > /dev/null || { echo "could not make the mix500 photos"; rm -rf "$tmp"; return 1; }
  mix_docs_into "$out" || { echo "could not make the mix500 documents"; rm -rf "$tmp"; return 1; }
  mix_pdfs_into "$out" "$tool" || { echo "could not make the mix500 pdfs"; rm -rf "$tmp"; return 1; }
  mix_audio_into "$out" "$tmp/say"; rc=$?
  if [ $rc != 0 ]; then rm -rf "$tmp"; return $rc; fi
  mix_video_into "$out" "$tool" || { echo "could not make the mix500 videos"; rm -rf "$tmp"; return 1; }
  docs_sync "$out" "$FIX/mix500" mix500
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# make_av_assets <dir> : eight real clips of about 1 s for the extav cells of the matrix: avx.<ext> for mp3 m4a wav aac flac (a 440 Hz tone) and
# mp4 mov m4v (h264 with an aac track), written the way golden-av writes its clips.
make_av_assets() {
  local base="$1" ext
  ffmpeg -nostdin -v error -y -f lavfi -i "sine=frequency=440:sample_rate=$AV_RATE:duration=1" -ac 1 -c:a pcm_s16le -f wav \
    -fflags +bitexact -flags:a +bitexact -map_metadata -1 "$base/avx.wav" < /dev/null || return 1
  for ext in mp3 m4a aac flac; do av_encode "$base/avx.wav" "$base/avx.$ext" || return 1; done
  ffmpeg -nostdin -v error -y -f lavfi -i "testsrc=size=64x64:rate=5:duration=1" -c:v libx264 -pix_fmt yuv420p -preset medium -crf 28 -threads 1 \
    -x264-params threads=1:lookahead-threads=1 -an -fflags +bitexact -flags:v +bitexact -map_metadata -1 -f mp4 "$base/avx.v.mp4" < /dev/null || return 1
  for ext in mp4 mov m4v; do av_video_mux "$base/avx.v.mp4" "$base/avx.m4a" 1 "$base/avx.$ext" || return 1; done
}

# ---- expect ----------------------------------------------------------------------------------

# golden_expected : the paths the golden folder must hold, one per line (the scene table is the
# photo part; a later task adds the other kinds here).
golden_expected() {
  scene_rows | awk -F'\t' '{ print $1 }'
}

# fmt_of <file> : the picture format read from the bytes, not the name.
fmt_of() {
  local mime
  mime="$(file --mime-type -b "$1")"
  case "$mime" in
    image/jpeg) echo jpeg ;;
    image/png) echo png ;;
    image/heic|image/heif) echo heic ;;
    image/webp) echo webp ;;
    image/tiff) echo tiff ;;
    image/gif) echo gif ;;
    *) echo "other($mime)" ;;
  esac
}

# listing_tree <dir> <listing> : the tree holds exactly the files of tree.tsv, plus the inside of repo/.git.
listing_tree() {
  local dir="$1" listing="$2" p want problems=0 n
  [ -f "$TREE" ] || { echo "scripts/kit-lib/tree.tsv is missing"; return 1; }
  want="$(tree_rows | awk -F'\t' '{ print $1 }' | LC_ALL=C sort)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "MISSING $p"
    problems=$((problems + 1))
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$listing" | awk '!/^repo\/\.git\//') <(printf '%s\n' "$want"))
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "EXTRA $p"
    problems=$((problems + 1))
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$listing" | awk '!/^repo\/\.git\//') <(printf '%s\n' "$want"))
  if [ ! -f "$dir/repo/.git/HEAD" ]; then
    echo "MISSING repo/.git/HEAD (repo/ is not a git repo)"
    problems=$((problems + 1))
  fi
  n="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
  if [ $problems = 0 ]; then
    echo "LISTING OK tree: $n paths"
    return 0
  fi
  echo "LISTING FAILED tree: $problems problems"
  return 1
}

# listing_empty <dir> : the empty folder holds nothing at all, not even a folder or a hidden file.
listing_empty() {
  local dir="$1" p problems=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "EXTRA ${p#"$dir"/}"
    problems=$((problems + 1))
  done < <(find "$dir" -mindepth 1 ! -name '.DS_Store' | LC_ALL=C sort)
  if [ $problems = 0 ]; then
    echo "LISTING OK empty: 0 paths"
    return 0
  fi
  echo "LISTING FAILED empty: $problems entries"
  return 1
}

# listing_supported <dir> : the supported files of any other folder (the spec's extension lists), relative, sorted.
listing_supported() {
  local dir="${1%/}" listing n
  listing="$(find "$dir" -type f ! -name '.DS_Store' | awk -v ext="$KIT_LIB/extensions.txt" -v d="$dir/" '
    BEGIN {
      while ((getline line < ext) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, ": ")
        n = split(a[2], e, " ")
        for (i = 1; i <= n; i++) kind[e[i]] = a[1]
      }
    }
    {
      f = $0
      rel = f
      if (index(f, d) == 1) rel = substr(f, length(d) + 1)
      base = f; sub(/.*\//, "", base)
      x = ""
      if (base ~ /\./) { x = base; sub(/.*\./, "", x); x = tolower(x) }
      if ((x in kind) && kind[x] != "code") print rel
    }' | LC_ALL=C sort)"
  [ -z "$listing" ] || printf '%s\n' "$listing"
  n="$(printf '%s\n' "$listing" | awk 'NF > 0 { c++ } END { print c + 0 }')"
  echo "LISTING OK ${dir##*/}: $n paths"
  return 0
}

expect_listing() {
  local dir name
  dir="$(fx_dir "$1")" || { usage; return 2; }
  name="${dir##*/}"
  if [ ! -d "$dir" ]; then
    echo "no such folder: $dir (build it first)"
    return 1
  fi
  case "$name" in
    golden|tree|empty) ;;
    *) listing_supported "$dir"; return $? ;;
  esac
  local listing
  listing="$(cd "$dir" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort)"
  [ -z "$listing" ] || printf '%s\n' "$listing"
  case "$name" in
    golden) ;;
    tree) listing_tree "$dir" "$listing"; return $? ;;
    empty) listing_empty "$dir"; return $? ;;
  esac
  check_answers || return 1
  validate_scenes || return 1
  local problems=0 p fmt got
  local want
  want="$(golden_expected | LC_ALL=C sort)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "MISSING $p"
    problems=$((problems + 1))
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$listing") <(printf '%s\n' "$want"))
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "EXTRA $p"
    problems=$((problems + 1))
  done < <(LC_ALL=C comm -23 <(printf '%s\n' "$listing") <(printf '%s\n' "$want"))
  local counts="" f
  for f in jpeg png heic webp tiff gif; do eval "n_$f=0"; done
  while IFS=$'\t' read -r p fmt _; do
    [ -f "$dir/$p" ] || continue
    got="$(fmt_of "$dir/$p")"
    if [ "$got" != "$fmt" ]; then
      echo "WRONG-FORMAT $p expected $fmt got $got"
      problems=$((problems + 1))
    else
      eval "n_$got=\$((n_$got + 1))"
    fi
  done < <(scene_rows)
  for f in jpeg png heic webp tiff gif; do
    eval "counts=\"\$counts \$f \$n_$f\""
  done
  echo "FORMATS$counts"
  local targets=0 shots=0
  while IFS= read -r p; do
    [ -f "$dir/$p" ] && targets=$((targets + 1))
  done < <(answers_files photo)
  while IFS= read -r p; do
    [ -f "$dir/$p" ] && shots=$((shots + 1))
  done < <(answers_files exact screenshot-only | LC_ALL=C sort -u)
  echo "TARGETS $targets"
  echo "SCREENSHOTS $shots"
  [ "$targets" = 10 ] || { echo "WRONG-COUNT targets: expected 10 got $targets"; problems=$((problems + 1)); }
  [ "$shots" = 4 ] || { echo "WRONG-COUNT screenshots: expected 4 got $shots"; problems=$((problems + 1)); }
  if [ $problems = 0 ]; then
    echo "LISTING OK $name: $(printf '%s\n' "$listing" | wc -l | tr -d ' ') paths"
    return 0
  fi
  echo "LISTING FAILED $name: $problems problems"
  return 1
}

# counts_lines <dir> : "<kind> <n>" for every kind present, in a fixed order, by extension. A file of any other
# extension is not a kind and is not counted (spec Goals); expect_counts prints how many there were.
counts_lines() {
  find "$1" -type f ! -name '.DS_Store' | awk -v ext="$KIT_LIB/extensions.txt" '
    BEGIN {
      while ((getline line < ext) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, ": ")
        n = split(a[2], e, " ")
        for (i = 1; i <= n; i++) kind[e[i]] = a[1]
      }
    }
    {
      f = $0; sub(/.*\//, "", f)
      x = ""
      if (f ~ /\./) { x = f; sub(/.*\./, "", x); x = tolower(x) }
      k = ((x in kind) && kind[x] != "code") ? kind[x] : "unsupported"
      c[k]++
    }
    END {
      split("photo document audio video pdf", o, " ")
      for (i = 1; i <= 5; i++) if (c[o[i]] > 0) print o[i], c[o[i]]
      if (c["unsupported"] > 0) print "ignored", c["unsupported"]
    }'
}

expect_counts() {
  local dir name
  dir="$(fx_dir "$1")" || { usage; return 2; }
  name="${dir##*/}"
  if [ ! -d "$dir" ]; then
    echo "no such folder: $dir (build it first)"
    return 1
  fi
  local got want mism ignored
  got="$(counts_lines "$dir")"
  ignored="$(printf '%s\n' "$got" | awk '$1 == "ignored" { print $2 }')"
  got="$(printf '%s\n' "$got" | awk 'NF > 0 && $1 != "ignored"')"
  [ -z "$got" ] || printf '%s\n' "$got"
  [ -z "$ignored" ] || echo "IGNORED $ignored files of unsupported types (not a kind, not counted)"
  want="$(awk -F'\t' -v f="$name" '!/^#/ && $1 == f { print $2, $3 }' "$KIT_LIB/expected-counts.tsv")"
  if [ -z "$want" ]; then
    echo "COUNTS $name: no hand-written row in expected-counts.tsv, counts printed only"
    return 0
  fi
  mism="$(awk '
    NR == FNR { w[$1] = $2; next }
    { g[$1] = $2 }
    END {
      for (k in w) if (g[k] != w[k]) print "MISMATCH " k " expected " w[k] " got " ((k in g) ? g[k] : 0)
      for (k in g) if (!(k in w)) print "MISMATCH " k " expected 0 got " g[k]
    }' <(printf '%s\n' "$want") <(printf '%s\n' "$got") | LC_ALL=C sort)"
  if [ -n "$mism" ]; then
    printf '%s\n' "$mism"
    echo "COUNTS FAILED $name"
    return 1
  fi
  echo "COUNTS OK $name"
  return 0
}

# ---- build tree, empty, filler ---------------------------------------------------------------

# tree_rows : the data rows of the tree table.
tree_rows() { awk -F'\t' '!/^#/ && NF >= 2' "$TREE"; }

# fx_marker : the fixture root holds a .metadata_never_index file, one level above every picked folder,
# so Spotlight does not read the fixtures (nothing is added inside a picked folder).
fx_marker() {
  mkdir -p "$FIX" || return 1
  [ -f "$FIX/.metadata_never_index" ] || : > "$FIX/.metadata_never_index"
}

# mk_pdf <out> <text> : a one-page pdf written by hand, so two builds make the same bytes (CoreGraphics
# writes the clock into a pdf). The text holds no parenthesis, backslash or non-ASCII character.
mk_pdf() {
  local LC_ALL=C
  local out="$1" text="$2" stream h o1 o2 o3 o4 o5 p1 p2 p3 p4 p5 xref
  stream="BT /F1 18 Tf 72 700 Td ($text) Tj ET"
  h='%PDF-1.4'
  o1=$'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj'
  o2=$'2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj'
  o3=$'3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj'
  o4="4 0 obj"$'\n'"<< /Length ${#stream} >>"$'\n'"stream"$'\n'"$stream"$'\n'"endstream"$'\n'"endobj"
  o5=$'5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj'
  p1=$((${#h} + 1))
  p2=$((p1 + ${#o1} + 1))
  p3=$((p2 + ${#o2} + 1))
  p4=$((p3 + ${#o3} + 1))
  p5=$((p4 + ${#o4} + 1))
  xref=$((p5 + ${#o5} + 1))
  {
    printf '%s\n' "$h" "$o1" "$o2" "$o3" "$o4" "$o5"
    printf 'xref\n0 6\n0000000000 65535 f \n'
    printf '%010d 00000 n \n' "$p1" "$p2" "$p3" "$p4" "$p5"
    printf 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' "$xref"
  } > "$out"
}

# mk_docx <out> <text> and mk_odt <out> <text> : a word-processor file written by hand (zip with fixed order and
# fixed times: textutil puts the clock into its zip, so two builds would differ). The text holds no & < >.
mk_docx() {
  local out="$1" text="$2" d rc
  d="$(mktemp -d "$KIT_TMP/kit-docx.XXXXXX")" || return 1
  mkdir -p "$d/_rels" "$d/word"
  printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>' > "$d/[Content_Types].xml"
  printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>' > "$d/_rels/.rels"
  printf '%s%s%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>' "$text" '</w:t></w:r></w:p></w:body></w:document>' > "$d/word/document.xml"
  find "$d" -exec env TZ=UTC touch -t "$PHOTO_TIME" {} +
  rm -f "$out"
  (cd "$d" && TZ=UTC zip -X -D -q -nw "$out" '[Content_Types].xml' _rels/.rels word/document.xml)
  rc=$?
  rm -rf "$d"
  return $rc
}

mk_odt() {
  local out="$1" text="$2" d rc
  d="$(mktemp -d "$KIT_TMP/kit-odt.XXXXXX")" || return 1
  mkdir -p "$d/META-INF"
  printf '%s' 'application/vnd.oasis.opendocument.text' > "$d/mimetype"
  printf '%s' '<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>' > "$d/META-INF/manifest.xml"
  printf '%s%s%s' '<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:text><text:p>' "$text" '</text:p></office:text></office:body></office:document-content>' > "$d/content.xml"
  find "$d" -exec env TZ=UTC touch -t "$PHOTO_TIME" {} +
  rm -f "$out"
  (cd "$d" && TZ=UTC zip -X -D -q -0 "$out" mimetype && TZ=UTC zip -X -D -q "$out" META-INF/manifest.xml content.xml)
  rc=$?
  rm -rf "$d"
  return $rc
}

# make_assets <dir> : the generated pieces the tree copies from: six pictures, a tone, a clip, a pdf.
make_assets() {
  local base="$1" tool jobs
  mkdir -p "$base" || return 1
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    return 1
  }
  jobs="$base/jobs.tsv"
  {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' j1.jpg jpeg other '#8fd3ff' '#e6f6ff' '#7bbf6a' '🌳:0.5,0.7,0.4;☁️:0.2,0.2,0.14' -
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' j2.jpg jpeg other '#ff9a5c' '#ffe0b3' '#8a5a44' '🏠:0.5,0.68,0.45;🌞:0.8,0.2,0.16' -
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' j3.jpg jpeg other '#0b1030' '#2b3a7a' '#1a1a1a' '🌙:0.7,0.2,0.2;⭐:0.2,0.15,0.07' -
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' j4.jpg jpeg other '#bfe3ff' '#eaf6ff' '#6fae5a' '🚲:0.5,0.72,0.4' -
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' p1.png png other '#ffd1e8' '#fff0f7' '#9ccc65' '🌸:0.5,0.66,0.45' -
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' p2.png png other '#d7ccc8' '#efebe9' '#8d6e63' '☕:0.5,0.66,0.5' -
  } > "$jobs"
  "$tool" photos "$jobs" "$base" > /dev/null < /dev/null || return 1
  ffmpeg -nostdin -v error -y -f lavfi -i sine=frequency=440:duration=1 \
    -fflags +bitexact -flags:a +bitexact -map_metadata -1 "$base/hum.wav" < /dev/null || return 1
  ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=64x64:rate=5:duration=1 -f lavfi -i sine=frequency=440:duration=1 \
    -shortest -c:v mpeg4 -c:a aac -threads 1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact -map_metadata -1 \
    "$base/clip.mp4" < /dev/null || return 1
  mk_pdf "$base/doc.pdf" "Base pdf that the damaged pdf is cut from, with a few more words to make it longer"
}

# make_file <assets dir> <dest> <kind> <argument> : one row of the tree table.
make_file() {
  local base="$1" dest="$2" kind="$3" arg="$4" tool n seed file lines
  mkdir -p "$(dirname "$dest")" || return 1
  case "$kind" in
    jpeg) cp "$base/j$arg.jpg" "$dest" ;;
    png) cp "$base/p$arg.png" "$dest" ;;
    text) printf '%s\n' "$arg" > "$dest" ;;
    lines) IFS='|' read -r -a lines <<< "$arg"; printf '%s\n' "${lines[@]}" > "$dest" ;;
    rtf) printf '%s\n' "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 $arg\\par}" > "$dest" ;;
    html) printf '<html><head><meta charset="utf-8"><title>%s</title></head><body><p>%s</p></body></html>\n' "$arg" "$arg" > "$dest" ;;
    docx) mk_docx "$dest" "$arg" ;;
    odt) mk_odt "$dest" "$arg" ;;
    pdf) mk_pdf "$dest" "$arg" ;;
    wav) cp "$base/hum.wav" "$dest" ;;
    mp4) cp "$base/clip.mp4" "$dest" ;;
    sparse)
      case "$arg" in ""|*[!0-9]*) return 1 ;; esac
      truncate -s "$arg" "$dest" ;;
    noise)
      n="${arg%%:*}"; seed="${arg##*:}"
      tool="$(kit_tool fixturegen)" || return 1
      "$tool" noise "$dest" "$n" "$seed" ;;
    filler)
      case "$arg" in ""|*[!0-9]*) return 1 ;; esac
      cp "$base/ph/d000/$(printf 'f%06d.jpg' "$arg")" "$dest" ;;
    trunc)
      n="${arg##*:}"
      case "${arg%%:*}" in
        png1) file="$base/p1.png" ;;
        png2) file="$base/p2.png" ;;
        pdf) file="$base/doc.pdf" ;;
        mp4) file="$base/clip.mp4" ;;
        *) return 1 ;;
      esac
      [ "$(stat -f %z "$file")" -gt "$n" ] || return 1
      head -c "$n" "$file" > "$dest" ;;
    badbytes) printf '\377\376\375func broken\200\201\202(\n' > "$dest" ;;
    *) echo "tree.tsv: unknown kind '$kind' for ${dest##*/}"; return 1 ;;
  esac
}

# make_repo <dir> : turns the folder into a real git repo (a .git folder), with no commit and no index,
# so that nothing in it depends on the clock or on inode numbers (two builds make the same bytes).
make_repo() {
  local r="$1" tpl rc
  tpl="$(mktemp -d "$KIT_TMP/kit-gittpl.XXXXXX")" || return 1
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git init -q --template="$tpl" -b main "$r" < /dev/null
  rc=$?
  rm -rf "$tpl"
  return $rc
}

# manifest_of <dir> : "<path inside>", mode, size, modified time, SHA-256 of every regular file, sorted.
manifest_of() {
  local dir="$1" t
  t="$(mktemp -d "$KIT_TMP/kit-man.XXXXXX")" || return 1
  find "$dir" -type f -exec stat -f '%N%t%Lp%t%z%t%m' {} + > "$t/stat" || { rm -rf "$t"; return 1; }
  find "$dir" -type f -exec shasum -a 256 {} + 2> "$t/err" | sed 's/^\([0-9a-f]\{64\}\)  /\1\t/' > "$t/sha"
  if [ -s "$t/err" ]; then
    head -3 "$t/err" >&2
    rm -rf "$t"
    return 1
  fi
  {
    awk -F'\t' -v OFS='\t' -v d="$dir/" '
      NR == FNR { mode[$1] = $2; size[$1] = $3; mt[$1] = $4; next }
      { p = $2; rel = p; if (index(p, d) == 1) rel = substr(p, length(d) + 1); print rel, mode[p], size[p], mt[p], $1 }
    ' "$t/stat" "$t/sha"
    # a symbolic link is one row too: its own mode and time, and its target in place of a digest
    find "$dir" -type l | while IFS= read -r l; do
      printf '%s\t%s\t0\t%s\tlink:%s\n' "${l#"$dir"/}" "$(stat -f %Lp "$l")" "$(stat -f %m "$l")" "$(readlink "$l")"
    done
  } | LC_ALL=C sort -t$'\t' -k1,1
  rm -rf "$t"
}

# sync_into <built folder> <dest> : makes dest equal to the built folder, writing only the files that differ
# (a file that is already right keeps its inode and time) and removing every file that is not in the built
# folder. Prints "<written> <kept> <removed>". The built folder is used up.
sync_into() {
  local src="$1" dest="$2" t plan op rel w=0 k=0 r=0 d
  if [ ! -d "$dest" ]; then
    mkdir -p "$(dirname "$dest")" && mv "$src" "$dest" || return 1
    w="$(find "$dest" -type f | wc -l | tr -d ' ')"
    echo "$w 0 0"
    return 0
  fi
  t="$(mktemp -d "$KIT_TMP/kit-sync.XXXXXX")" || return 1
  manifest_of "$src" > "$t/new" && manifest_of "$dest" > "$t/old" || { rm -rf "$t"; return 1; }
  # the old listing is told apart by file name, not by NR == FNR: an empty old listing would make the new rows read as old
  plan="$(awk -F'\t' '
    FILENAME == ARGV[1] { old[$1] = $0; next }
    { seen[$1] = 1; if (!($1 in old) || old[$1] != $0) print "W\t" $1; else print "K\t" $1 }
    END { for (p in old) if (!(p in seen)) print "R\t" p }
  ' "$t/old" "$t/new")"
  while IFS= read -r d; do
    mkdir -p "$dest/${d#"$src"}" || { rm -rf "$t"; return 1; }
  done < <(find "$src" -type d)
  while IFS=$'\t' read -r op rel; do
    case "$op" in
      W) mv -f "$src/$rel" "$dest/$rel" || { rm -rf "$t"; return 1; }; w=$((w + 1)) ;;
      K) k=$((k + 1)) ;;
      R) rm -f "$dest/$rel"; r=$((r + 1)) ;;
    esac
  done <<< "$plan"
  # a folder that is not in the built folder and is empty now goes too
  while IFS= read -r d; do
    [ -d "$src/${d#"$dest"/}" ] || rmdir "$d" 2> /dev/null
  done < <(find "$dest" -mindepth 1 -depth -type d -empty)
  rm -rf "$t"
  echo "$w $k $r"
}

build_tree() {
  [ -f "$TREE" ] || { echo "scripts/kit-lib/tree.tsv is missing"; return 1; }
  fx_marker || return 1
  local tmp out path kind arg res w k r
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out"
  make_assets "$tmp/base" || { rm -rf "$tmp"; return 1; }
  while IFS=$'\t' read -r path kind arg; do
    case "$path" in ""|/*|*..*) echo "tree.tsv: bad path '$path'"; rm -rf "$tmp"; return 1 ;; esac
    make_file "$tmp/base" "$out/$path" "$kind" "$arg" < /dev/null || { echo "could not make tree/$path ($kind)"; rm -rf "$tmp"; return 1; }
  done < <(tree_rows)
  make_repo "$out/repo" || { echo "git init failed for tree/repo"; rm -rf "$tmp"; return 1; }
  find "$out" -exec env TZ=UTC touch -h -t "$PHOTO_TIME" {} + || { rm -rf "$tmp"; return 1; }
  res="$(sync_into "$out" "$FIX/tree")" || { echo "could not put the tree in place"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  read -r w k r <<< "$res"
  if [ "$w" = 0 ] && [ "$r" = 0 ]; then
    echo "UNCHANGED tree: $k files already right, nothing written"
  else
    echo "BUILT tree: $w files written, $k left as they were, $r removed"
  fi
  return 0
}

build_empty() {
  local d="$FIX/empty" n
  fx_marker || return 1
  if [ ! -d "$d" ]; then
    mkdir -p "$d" || return 1
    echo "BUILT empty: made the empty folder"
    return 0
  fi
  n="$(find "$d" -mindepth 1 | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then
    echo "UNCHANGED empty: already empty, nothing written"
    return 0
  fi
  find "$d" -mindepth 1 -delete || return 1
  echo "BUILT empty: removed $n entries"
  return 0
}

# build_filler <rows> : ceil(rows / 3) small generated photos, assuming three index rows a photo (a files row, a
# name passage and an image passage: guess G4; t32 checks it against the real index). Slice 1 reads only photos.
build_filler() {
  local rows="$1" photos tool epoch out
  case "$rows" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ "$rows" -ge 1 ] || { usage; return 2; }
  photos=$(((rows + 2) / 3))
  fx_marker || return 1
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    return 1
  }
  epoch="$(TZ=UTC date -j -f '%Y%m%d%H%M.%S' "$PHOTO_TIME" +%s)" || return 1
  if "$tool" filler-check "$FIX/filler" "$photos" "$epoch" > /dev/null 2>&1; then
    echo "FILLER UNCHANGED filler $rows rows"
    echo "$photos photos already right, nothing written"
    return 0
  fi
  out="$("$tool" filler-write "$FIX/filler" "$photos" "$epoch")" || { echo "could not write the filler"; return 1; }
  echo "FILLER BUILT filler $rows rows"
  echo "$photos photos: $out"
  return 0
}

# ---- build homefolders, minimix, extra -------------------------------------------------------

HOME_TABLE="$KIT_LIB/home.tsv"

# home_rows <prefix> : the data rows of home.tsv whose path starts with the prefix (home/ or extra/).
home_rows() { awk -F'\t' -v p="$1" '!/^#/ && NF >= 2 && index($1, p) == 1' "$HOME_TABLE"; }

# fill_from_table <prefix> <out> <assets dir> : makes every row of home.tsv with that prefix under <out>, the prefix removed.
# The small generated photos some rows copy (kind filler) are made once, with as many as the highest index asks for.
fill_from_table() {
  local prefix="$1" out="$2" base="$3" path kind arg nfill tool epoch
  [ -f "$HOME_TABLE" ] || { echo "scripts/kit-lib/home.tsv is missing"; return 1; }
  make_assets "$base" || return 1
  nfill="$(home_rows "$prefix" | awk -F'\t' '$2 == "filler" && $3 + 1 > n { n = $3 + 1 } END { print n + 0 }')"
  if [ "$nfill" -gt 0 ]; then
    tool="$(kit_tool fixturegen)" || {
      echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
      return 1
    }
    epoch="$(TZ=UTC date -j -f '%Y%m%d%H%M.%S' "$PHOTO_TIME" +%s)" || return 1
    "$tool" filler-write "$base/ph" "$nfill" "$epoch" > /dev/null || { echo "could not make the small photos"; return 1; }
  fi
  while IFS=$'\t' read -r path kind arg; do
    path="${path#"$prefix"}"
    case "$path" in ""|/*|*..*) echo "home.tsv: bad path '$path'"; return 1 ;; esac
    make_file "$base" "$out/$path" "$kind" "$arg" < /dev/null || { echo "could not make $path ($kind)"; return 1; }
  done < <(home_rows "$prefix")
}

build_homefolders() {
  local tmp out d res w k r tw=0 tk=0 tr=0
  mkdir -p "$KIT_ROOT/home" || return 1
  [ -f "$KIT_ROOT/home/.metadata_never_index" ] || : > "$KIT_ROOT/home/.metadata_never_index"
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out"
  fill_from_table "home/" "$out" "$tmp/base" || { rm -rf "$tmp"; return 1; }
  make_repo "$out/Developer/atlas-notes" || { echo "git init failed for Developer/atlas-notes"; rm -rf "$tmp"; return 1; }
  find "$out" -exec env TZ=UTC touch -h -t "$PHOTO_TIME" {} + || { rm -rf "$tmp"; return 1; }
  while IFS= read -r d; do
    res="$(sync_into "$d" "$KIT_ROOT/home/${d##*/}")" || { echo "could not put ${d##*/} in place"; rm -rf "$tmp"; return 1; }
    read -r w k r <<< "$res"
    tw=$((tw + w)); tk=$((tk + k)); tr=$((tr + r))
  done < <(find "$out" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  rm -rf "$tmp"
  if [ "$tw" = 0 ] && [ "$tr" = 0 ]; then
    echo "UNCHANGED homefolders: $tk files already right, nothing written"
  else
    echo "BUILT homefolders: $tw files written, $tk left as they were, $tr removed"
  fi
  return 0
}

build_extra() {
  local tmp out res w k r
  fx_marker || return 1
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out"
  fill_from_table "extra/" "$out" "$tmp/base" || { rm -rf "$tmp"; return 1; }
  find "$out" -exec env TZ=UTC touch -h -t "$PHOTO_TIME" {} + || { rm -rf "$tmp"; return 1; }
  res="$(sync_into "$out" "$FIX/extra")" || { echo "could not put extra in place"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  read -r w k r <<< "$res"
  if [ "$w" = 0 ] && [ "$r" = 0 ]; then
    echo "UNCHANGED extra: $k files already right, nothing written"
  else
    echo "BUILT extra: $w files written, $k left as they were, $r removed"
  fi
  return 0
}

OVERLAP_TABLE="$KIT_LIB/overlap.tsv"

# overlap_rows : the data rows of overlap.tsv (source under golden/, place under overlap/).
overlap_rows() { awk -F'\t' '!/^#/ && NF >= 2' "$OVERLAP_TABLE"; }

# build_overlap : fixtures/overlap from the golden photos (S1.6), by overlap.tsv: each photo copied with its time kept (cp -p), a
# file that is already the same bytes with the same time left alone, anything else under overlap/ removed. Everything written and
# removed lies inside $FIX/overlap. golden must be built first: this does not build it (and so never compiles the picture tool).
build_overlap() {
  local src dest w=0 k=0 r=0 stray rel
  [ -f "$OVERLAP_TABLE" ] || { echo "scripts/kit-lib/overlap.tsv is missing"; return 1; }
  fx_marker || return 1
  while IFS=$'\t' read -r src dest; do
    case "$src$dest" in *..*) echo "overlap.tsv: bad path '$src' '$dest'"; return 1 ;; esac
    case "$dest" in ""|/*) echo "overlap.tsv: bad place '$dest'"; return 1 ;; esac
    [ -f "$FIX/golden/$src" ] || { echo "no $FIX/golden/$src: build golden first (scripts/kit-fixtures.sh build golden)"; return 1; }
  done < <(overlap_rows)
  while IFS=$'\t' read -r src dest; do
    if [ -f "$FIX/overlap/$dest" ] && [ ! -L "$FIX/overlap/$dest" ] \
      && cmp -s "$FIX/golden/$src" "$FIX/overlap/$dest" \
      && [ "$(stat -f %m "$FIX/golden/$src")" = "$(stat -f %m "$FIX/overlap/$dest")" ]; then
      k=$((k + 1))
    else
      mkdir -p "$(dirname "$FIX/overlap/$dest")" && cp -p "$FIX/golden/$src" "$FIX/overlap/$dest" || return 1
      w=$((w + 1))
    fi
  done < <(overlap_rows)
  if [ -d "$FIX/overlap" ]; then
    while IFS= read -r stray; do
      rel="${stray#"$FIX/overlap"/}"
      if ! overlap_rows | awk -F'\t' -v p="$rel" '$2 == p { found = 1 } END { exit !found }'; then
        rm -f "$stray"
        echo "REMOVED $rel"
        r=$((r + 1))
      fi
    done < <(find "$FIX/overlap" -type f)
  fi
  if [ "$w" = 0 ] && [ "$r" = 0 ]; then
    echo "UNCHANGED overlap: $k files already right, nothing written"
  else
    echo "BUILT overlap: $w files written, $k left as they were, $r removed"
  fi
  return 0
}

# build_minimix : 400 small generated photos (each its own bytes, as the filler), photos only, long enough for a pause test.
build_minimix() {
  local tool epoch out
  fx_marker || return 1
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    return 1
  }
  epoch="$(TZ=UTC date -j -f '%Y%m%d%H%M.%S' "$PHOTO_TIME" +%s)" || return 1
  if "$tool" filler-check "$FIX/minimix" 400 "$epoch" > /dev/null 2>&1; then
    echo "UNCHANGED minimix: 400 photos already right, nothing written"
    return 0
  fi
  out="$("$tool" filler-write "$FIX/minimix" 400 "$epoch")" || { echo "could not write the mini mix"; return 1; }
  echo "BUILT minimix: 400 photos ($out)"
  return 0
}

# ---- build unrelated (plan 3) ----------------------------------------------------------------

# build_unrelated <n> : fixtures/unrelated holds exactly n photos, unrel0001.jpg to unrel<n>.jpg, made from the filler (small
# 32 x 32 pictures with a gradient and no drawn text, each with its own bytes: the one comment inside is "kit filler <i>").
# Photo k is filler photo k - 1, so its bytes do not depend on n and two builds make the same bytes. A photo that already has the
# right bytes and time is left alone; every other entry of the folder, a folder included, is removed.
build_unrelated() {
  local n="$1" tool epoch tmp k i src dest w=0 kept=0 r=0 entry base num
  case "$n" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ "${#n}" -le 5 ] || { usage; return 2; }
  n=$((10#$n))
  { [ "$n" -ge 1 ] && [ "$n" -le 9999 ]; } || { usage; return 2; }
  fx_marker || return 1
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    return 1
  }
  epoch="$(TZ=UTC date -j -f '%Y%m%d%H%M.%S' "$PHOTO_TIME" +%s)" || return 1
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  "$tool" filler-write "$tmp/f" "$n" "$epoch" > /dev/null || { echo "could not make the unrelated photos"; rm -rf "$tmp"; return 1; }
  mkdir -p "$FIX/unrelated" || { rm -rf "$tmp"; return 1; }
  for ((k = 1; k <= n; k++)); do
    i=$((k - 1))
    printf -v src '%s/f/d%03d/f%06d.jpg' "$tmp" $((i / 500)) "$i"
    printf -v dest '%s/unrelated/unrel%04d.jpg' "$FIX" "$k"
    if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" \
      && [ "$(stat -f %m "$src")" = "$(stat -f %m "$dest")" ]; then
      kept=$((kept + 1))
    else
      { [ -L "$dest" ] || [ -d "$dest" ]; } && rm -rf "$dest"
      mv -f "$src" "$dest" || { rm -rf "$tmp"; return 1; }
      w=$((w + 1))
    fi
  done
  rm -rf "$tmp"
  while IFS= read -r entry; do
    base="${entry##*/}"
    case "$base" in
      unrel[0-9][0-9][0-9][0-9].jpg)
        num=$((10#${base:5:4}))
        if [ "$num" -ge 1 ] && [ "$num" -le "$n" ] && [ -f "$entry" ] && [ ! -L "$entry" ]; then continue; fi ;;
    esac
    rm -rf "$entry"
    r=$((r + 1))
  done < <(find "$FIX/unrelated" -mindepth 1 -maxdepth 1)
  if [ "$w" = 0 ] && [ "$r" = 0 ]; then
    echo "UNCHANGED unrelated: $kept photos already right, nothing written"
  else
    echo "BUILT unrelated: $w photos written, $kept left as they were, $r removed"
  fi
  return 0
}

# ---- build matrix, expect matrix, expect extensions (plan 3) ---------------------------------

MATRIX_TABLE="$KIT_LIB/gate-matrix.csv"
# The folders of matrix/ that are git repos (plan-3 t1 report): a repo holding one note, the two whose one file is
# git-ignored, and the repo that holds the six vendored names.
MATRIX_REPOS="repo-off ignored-off ignored-on vend-in"
MATRIX_SPARSE_BYTES=4194304   # the cloud-only stand-in: this size, no blocks
MATRIX_DAMAGED_BYTES=100      # the damaged picture: a PNG cut after its header

# matrix_rows : "<cell> <TAB> <path>" for every data row of gate-matrix.csv (the table is the only source).
matrix_rows() { awk -F, 'NR > 1 && NF == 7 { print $1 "\t" $2 }' "$MATRIX_TABLE"; }

# matrix_check_table : the table is there, with its header and seven fields on every row.
matrix_check_table() {
  if [ ! -f "$MATRIX_TABLE" ]; then
    echo "scripts/kit-lib/gate-matrix.csv is missing"
    return 1
  fi
  if [ "$(head -1 "$MATRIX_TABLE")" != "cell,path,picks,expected_in_index,expected_rows,expected_reason,group" ]; then
    echo "gate-matrix.csv: line 1 is not the header cell,path,picks,expected_in_index,expected_rows,expected_reason,group"
    return 1
  fi
  local bad
  bad="$(awk -F, 'NR > 1 && NF != 7 { print "gate-matrix.csv line " NR " has " NF " fields, expected 7" }' "$MATRIX_TABLE")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

# build_matrix : fixtures/matrix, every file of gate-matrix.csv (S8.5, S8.6, S2.17), made from the table alone: the
# picture cells are real pictures of their extension with the cell's token drawn as text, the text and code cells
# hold their token, the sparse cell has a size and no blocks, the link cell links to the plain-photo file, the
# repo folders are git repos (no commit, so nothing depends on the clock) and the .gitignore of an ignored cell's
# repo lists that cell's file. Same rule as the tree: a matrix that is already right is left alone, only a file that
# differs is written, a file that is not in the table is removed.
build_matrix() {
  matrix_check_table || return 1
  fx_marker || return 1
  local tmp out tool cell path base ext tok up fmt tpath top rel repo res w k r
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  mkdir -p "$out"
  make_assets "$tmp/base" || { rm -rf "$tmp"; return 1; }
  make_av_assets "$tmp/base" || { echo "could not make the audio and video clips of the extav cells"; rm -rf "$tmp"; return 1; }
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    rm -rf "$tmp"
    return 1
  }
  : > "$tmp/jobs.tsv"
  tpath="$(matrix_rows | awk -F'\t' '$1 == "plain-photo" { print $2 }')"
  while IFS=$'\t' read -r cell path; do
    case "$path" in ""|/*|*..*) echo "gate-matrix.csv: bad path '$path'"; rm -rf "$tmp"; return 1 ;; esac
    [[ "$path" =~ zq[0-9][0-9][0-9][0-9] ]] || { echo "gate-matrix.csv: no zq token in '$path'"; rm -rf "$tmp"; return 1; }
    tok="${BASH_REMATCH[0]}"
    base="${path##*/}"
    ext=""
    case "${base#.}" in *.*) ext="$(printf '%s' "${base##*.}" | tr 'A-Z' 'a-z')" ;; esac
    mkdir -p "$(dirname "$out/$path")" || { rm -rf "$tmp"; return 1; }
    case "$cell" in
      link-png)
        # the table has no link-target column: the link cell links to the plain-photo cell's file (same folder)
        [ -n "$tpath" ] && [ "$(dirname "$tpath")" = "$(dirname "$path")" ] || { echo "gate-matrix.csv: link-png and plain-photo are not in one folder"; rm -rf "$tmp"; return 1; }
        ln -s "${tpath##*/}" "$out/$path" || { rm -rf "$tmp"; return 1; }
        continue ;;
      cloud-sparse-jpg)
        truncate -s "$MATRIX_SPARSE_BYTES" "$out/$path" || { rm -rf "$tmp"; return 1; }
        continue ;;
      extav-*)
        # plan 5: a real clip of the cell's own extension (h264 and aac inside the video ones), never the text of the other cells
        cp "$tmp/base/avx.$ext" "$out/$path" || { rm -rf "$tmp"; return 1; }
        continue ;;
      damaged-swift)
        # plan 6: a .swift whose bytes are not UTF-8, which the code reader must call damaged
        printf '\377\376\375func broken\200\201\202(\n' > "$out/$path" || { rm -rf "$tmp"; return 1; }
        continue ;;
    esac
    case "$ext" in
      jpeg|jpg|png|heic|webp|tiff|tif|gif)
        fmt="$ext"
        [ "$fmt" = jpg ] && fmt=jpeg
        [ "$fmt" = tif ] && fmt=tiff
        # the token is drawn in capitals: text recognition misreads the q of a lower-case zq token
        up="$(printf '%s' "$tok" | tr 'a-z' 'A-Z')"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$fmt" token '#ffffff' '#ffffff' '#000000' - "$up|$up|$up" >> "$tmp/jobs.tsv" ;;
      pdf) mk_pdf "$out/$path" "matrix cell $cell token $tok" || { rm -rf "$tmp"; return 1; } ;;
      rtf) printf '%s\n' "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 matrix cell $cell token $tok\\par}" > "$out/$path" || { rm -rf "$tmp"; return 1; } ;;
      html) printf '<html><head><meta charset="utf-8"><title>%s</title></head><body><p>%s</p></body></html>\n' "$cell" "matrix cell $cell token $tok" > "$out/$path" || { rm -rf "$tmp"; return 1; } ;;
      docx) mk_docx "$out/$path" "matrix cell $cell token $tok" || { rm -rf "$tmp"; return 1; } ;;
      odt) mk_odt "$out/$path" "matrix cell $cell token $tok" || { rm -rf "$tmp"; return 1; } ;;
      wav) cp "$tmp/base/hum.wav" "$out/$path" || { rm -rf "$tmp"; return 1; } ;;
      mp4) cp "$tmp/base/clip.mp4" "$out/$path" || { rm -rf "$tmp"; return 1; } ;;
      *) printf '%s\n' "matrix cell $cell token $tok" > "$out/$path" || { rm -rf "$tmp"; return 1; } ;;
    esac
  done < <(matrix_rows)
  if [ -s "$tmp/jobs.tsv" ]; then
    "$tool" photos "$tmp/jobs.tsv" "$out" > /dev/null < /dev/null || { echo "could not draw the matrix pictures"; rm -rf "$tmp"; return 1; }
  fi
  # the damaged cell: a real PNG cut after its header
  path="$(matrix_rows | awk -F'\t' '$1 == "damaged-png" { print $2 }')"
  if [ -n "$path" ]; then
    head -c "$MATRIX_DAMAGED_BYTES" "$out/$path" > "$tmp/damaged.part" && mv -f "$tmp/damaged.part" "$out/$path" || { rm -rf "$tmp"; return 1; }
  fi
  # the ignored cells: their repo's .gitignore lists the file
  while IFS=$'\t' read -r cell path; do
    top="${path%%/*}"
    rel="${path#*/}"
    # plan 6: a cell named ...-folder-... is ignored as a folder (its first folder under the repo), not as a file
    case "$cell" in *-folder-*) rel="${rel%%/*}/" ;; esac
    printf '%s\n' "$rel" >> "$out/$top/.gitignore" || { rm -rf "$tmp"; return 1; }
  done < <(awk -F, 'NR > 1 && NF == 7 && ($6 == "git-ignored" || $1 ~ /^ignored-/) { print $1 "\t" $2 }' "$MATRIX_TABLE")
  for repo in $MATRIX_REPOS; do
    [ -d "$out/$repo" ] || { echo "gate-matrix.csv has no folder $repo, which is a repo"; rm -rf "$tmp"; return 1; }
    make_repo "$out/$repo" || { echo "git init failed for matrix/$repo"; rm -rf "$tmp"; return 1; }
  done
  find "$out" -exec env TZ=UTC touch -h -t "$PHOTO_TIME" {} + || { rm -rf "$tmp"; return 1; }
  res="$(sync_into "$out" "$FIX/matrix")" || { echo "could not put the matrix in place"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  read -r w k r <<< "$res"
  if [ "$w" = 0 ] && [ "$r" = 0 ]; then
    echo "UNCHANGED matrix: $k files already right, nothing written"
  else
    echo "BUILT matrix: $w files written, $k left as they were, $r removed"
  fi
  return 0
}

# ---- build repos (plan 6) ---------------------------------------------------------------------------

REPOS_TABLE="$KIT_LIB/repos.tsv"
REPO_SRC="$KIT_LIB/repo-src"

# repos_pictures : the two pictures of the golden repos, `<repo>/<path> TAB <lines drawn as text>`; the lines are in capitals
# because text recognition misreads lower-case letters of a small drawing.
repos_pictures() {
  printf '%s\t%s\n' 'api-client/docs/retry-diagram.png' 'RETRY THE FAILED CALL|WAIT LONGER EACH TIME|CALL AGAIN'
  printf '%s\t%s\n' 'legacy-sync/docs/diagram.png' 'LEGACY SYNC DIAGRAM|OLD STORE TO NEW STORE'
}

# repo_excluded_file <dest> <string> : an excluded file of api-client (S5.8): code of the file's own language when the name
# says one, else a plain line, always holding the file's unique string and nothing that looks like a real secret.
repo_excluded_file() {
  local dest="$1" str="$2"
  mkdir -p "$(dirname "$dest")" || return 1
  case "${dest##*.}" in
    swift) printf 'let marker = "%s"\n' "$str" > "$dest" ;;
    js) printf 'const marker = "%s";\n' "$str" > "$dest" ;;
    go) printf 'package vendor\n\nconst marker = "%s"\n' "$str" > "$dest" ;;
    *) printf '%s is the marker of this file\n' "$str" > "$dest" ;;
  esac
}

# build_repos : the three golden repos in the throwaway home's Developer folder (S5): the sources are the hand-written files of
# scripts/kit-lib/repo-src, the excluded files, the two non-code decoys and the pictures are made here from scripts/kit-lib/repos.tsv
# and the key. Each is a real git repo (no commit, so nothing depends on the clock). Same rule as the tree: a repo that is already
# right is left alone, only a file that differs is written, a file that is not in the build is removed. Only the three repo folders
# are written; the rest of home/ is left alone.
build_repos() {
  [ -f "$REPOS_TABLE" ] && [ -d "$REPO_SRC" ] || { echo "scripts/kit-lib/repos.tsv or scripts/kit-lib/repo-src is missing"; return 1; }
  local tmp out tool repo type file name kind picpath lines res w k r tw=0 tk=0 tr=0 dev="$KIT_ROOT/home/Developer"
  tmp="$(mktemp -d "$KIT_TMP/kit-fixtures.XXXXXX")" || return 1
  out="$tmp/out"
  tool="$(kit_tool fixturegen)" || {
    echo "the fixture tool did not compile; see $KIT_ROOT/run/bin/fixturegen.log"
    rm -rf "$tmp"
    return 1
  }
  for repo in api-client legacy-sync scratch-lab; do
    mkdir -p "$out/$repo" && cp -R "$REPO_SRC/$repo/." "$out/$repo/" || { rm -rf "$tmp"; return 1; }
  done
  while IFS=$'\t' read -r type repo file name kind; do
    [ "$type" = excluded ] || continue
    repo_excluded_file "$out/$repo/$file" "$name" || { rm -rf "$tmp"; return 1; }
    [ "$kind" = ignored ] && printf '%s\n' "$file" >> "$out/$repo/.gitignore"
  done < <(awk -F'\t' '!/^#/ && NF >= 5' "$REPOS_TABLE")
  mkdir -p "$out/api-client/docs"
  printf '%s\n' '# Retrying a failed call' '' 'When a call fails, wait a little and try the call again. Each retry waits longer than the one before, which is called backoff. Stop after a few attempts and report the last error.' > "$out/api-client/docs/retry-notes.md" || { rm -rf "$tmp"; return 1; }
  : > "$tmp/jobs.tsv"
  while IFS=$'\t' read -r picpath lines; do
    mkdir -p "$(dirname "$out/$picpath")" || { rm -rf "$tmp"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$picpath" png token '#ffffff' '#ffffff' '#000000' - "$lines" >> "$tmp/jobs.tsv"
  done < <(repos_pictures)
  "$tool" photos "$tmp/jobs.tsv" "$out" > /dev/null < /dev/null || { echo "could not draw the pictures of the repos"; rm -rf "$tmp"; return 1; }
  for repo in api-client legacy-sync scratch-lab; do
    make_repo "$out/$repo" || { echo "git init failed for $repo"; rm -rf "$tmp"; return 1; }
  done
  find "$out" -exec env TZ=UTC touch -h -t "$PHOTO_TIME" {} + || { rm -rf "$tmp"; return 1; }
  mkdir -p "$dev" || { rm -rf "$tmp"; return 1; }
  for repo in api-client legacy-sync scratch-lab; do
    res="$(sync_into "$out/$repo" "$dev/$repo")" || { echo "could not put $repo in place"; rm -rf "$tmp"; return 1; }
    read -r w k r <<< "$res"
    tw=$((tw + w)); tk=$((tk + k)); tr=$((tr + r))
  done
  rm -rf "$tmp"
  if [ "$tw" = 0 ] && [ "$tr" = 0 ]; then
    echo "UNCHANGED repos: $tk files already right, nothing written"
  else
    echo "BUILT repos: $tw files written, $tk left as they were, $tr removed"
  fi
  return 0
}

# expect_matrix : every cell of the table has its file (the link cell its link) under fixtures/matrix.
expect_matrix() {
  local dir="$FIX/matrix" cell path n=0 bad=0
  matrix_check_table || return 1
  if [ ! -d "$dir" ]; then
    echo "no such folder: $dir (build it first)"
    return 1
  fi
  while IFS=$'\t' read -r cell path; do
    n=$((n + 1))
    if [ ! -e "$dir/$path" ] && [ ! -L "$dir/$path" ]; then
      echo "MISSING $cell $path"
      bad=$((bad + 1))
    elif [ "$cell" = link-png ] && [ ! -L "$dir/$path" ]; then
      echo "MISSING $cell $path (it is not a symbolic link)"
      bad=$((bad + 1))
    fi
  done < <(matrix_rows)
  if [ $bad = 0 ]; then
    echo "MATRIX OK $n cells"
    return 0
  fi
  echo "MATRIX FAILED $bad of $n cells"
  return 1
}

# expect_extensions [<kind,kind>] : for every extension of the kinds (all six without a list) a fixture file of that
# extension must exist under fixtures/golden, fixtures/tree or fixtures/matrix. Prints FOUND <kind> <ext> <path> or
# MISSING <kind> <ext> for each; exit 0 when none is missing, exit 4 (the run is not valid) when some are.
expect_extensions() {
  local kinds="$1" k known files rc klist
  known="$(awk '!/^#/ && NF > 0 { sub(/:.*/, ""); print }' "$KIT_LIB/extensions.txt")"
  if [ -n "$kinds" ]; then
    IFS=',' read -r -a klist <<< "$kinds"
    for k in "${klist[@]}"; do
      printf '%s\n' "$known" | grep -qx -- "$k" || { echo "expect extensions: '$k' is not a kind ($(printf '%s' "$known" | tr '\n' ' '))"; usage; return 2; }
    done
  fi
  files="$({
    for k in golden tree matrix; do
      [ -d "$FIX/$k" ] && find "$FIX/$k" -type f ! -name '.DS_Store' ! -path '*/.git/*'
    done
    [ -d "$KIT_ROOT/home/Developer" ] && find "$KIT_ROOT/home/Developer" -type f ! -name '.DS_Store' ! -path '*/.git/*'
  } | LC_ALL=C sort)"
  printf '%s\n' "$files" | awk -v ext="$KIT_LIB/extensions.txt" -v want="$kinds" -v fix="$FIX/" '
    BEGIN {
      nw = split(want, w, ",")
      for (i = 1; i <= nw; i++) wantk[w[i]] = 1
      while ((getline line < ext) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, a, ": ")
        if (nw > 0 && !(a[1] in wantk)) continue
        order[++no] = a[1]
        cnt[a[1]] = split(a[2], e, " ")
        for (i = 1; i <= cnt[a[1]]; i++) exts[a[1], i] = e[i]
      }
    }
    {
      f = $0
      base = f; sub(/.*\//, "", base)
      b2 = base; sub(/^\./, "", b2)
      if (b2 !~ /\./) next
      x = b2; sub(/.*\./, "", x); x = tolower(x)
      rel = f
      if (index(f, fix) == 1) rel = substr(f, length(fix) + 1)
      if (!(x in first)) first[x] = rel
    }
    END {
      total = 0; lost = 0
      for (j = 1; j <= no; j++) {
        k = order[j]
        names = names (names == "" ? "" : ",") k
        for (i = 1; i <= cnt[k]; i++) {
          x = exts[k, i]; total++
          if (k == "code" && i == 1) print "NEVER READ"
          if (x in first) print (k == "code" ? "NEVER-READ" : "FOUND " k), x, first[x]
          else { print "MISSING", k, x; lost++ }
        }
      }
      if (lost == 0) { print "EXTENSIONS OK " names ": " total " extensions, each with a fixture file"; exit 0 }
      print "EXTENSIONS FAILED " names ": " lost " of " total " extensions have no fixture file"
      exit 4
    }'
  rc=${PIPESTATUS[1]}
  return "$rc"
}

# ---- plant-model -----------------------------------------------------------------------------

# flip_at <file> <offset> : one byte changed (xor 255), size and everything else kept.
flip_at() {
  local f="$1" off="$2" b nb
  b="$(od -An -tu1 -j "$off" -N 1 "$f" | tr -d ' \n')"
  [ -n "$b" ] || return 1
  nb=$((b ^ 255))
  printf "\\$(printf '%03o' "$nb")" | dd of="$f" bs=1 seek="$off" count=1 conv=notrunc 2> /dev/null
}

# plant_model truncated|flipped : a bad copy of the text model file, under its real name, in the Sesame folder of the
# throwaway home (S1.18 damaged-model text, S6.6 re-download after a failed check) [guess G5].
plant_model() {
  local how="$1" name size sha dir dest src have=0 n cut origin
  read -r name size sha < <(kit_models | awk 'NR == 1')
  dir="$KIT_ROOT/home/Library/Application Support/Sesame"
  dest="$dir/models/$name"
  src="$KIT_ROOT/cache/$name"
  mkdir -p -m 700 "$dir" && mkdir -p "$dir/models" || return 1
  rm -f "$dest"
  [ -f "$src" ] && [ "$(stat -f %z "$src")" = "$size" ] && have=1
  origin="the whole file in cache/"
  [ "$have" = 1 ] || origin="made up (cache/ holds no whole $name yet)"
  case "$how" in
    truncated)
      cut=$((size / 2))
      if [ "$have" = 1 ]; then
        head -c "$cut" "$src" > "$dest" || return 1
      else
        printf 'GGUF' > "$dest" && truncate -s "$cut" "$dest" || return 1
      fi ;;
    flipped)
      if [ "$have" = 1 ]; then
        { cp -c "$src" "$dest" 2> /dev/null || cp "$src" "$dest"; } || return 1
      else
        printf 'GGUF' > "$dest" && truncate -s "$size" "$dest" || return 1
      fi
      flip_at "$dest" $((size / 2)) || return 1 ;;
    *) usage; return 2 ;;
  esac
  n="$(stat -f %z "$dest")"
  echo "PLANTED $dest $n bytes"
  echo "source: $origin"
  case "$how" in
    truncated)
      if [ "$n" = "$size" ]; then echo "check FAILED: the planted file has the right size $size"; return 1; fi
      echo "check: $n bytes, not the $size bytes of design section 7" ;;
    flipped)
      if [ "$n" != "$size" ]; then echo "check FAILED: the planted file is $n bytes, expected $size"; return 1; fi
      if [ "$(shasum -a 256 < "$dest" | awk '{ print $1 }')" = "$sha" ]; then echo "check FAILED: the planted file has the right SHA-256"; return 1; fi
      echo "check: $n bytes, SHA-256 differs from design section 7" ;;
  esac
  return 0
}

# ---- mutate and restore ----------------------------------------------------------------------

# mut_resolve <path> : the absolute path of a file or folder under $KIT_ROOT (a name is read under the fixture
# root). The kit changes only its own fixtures: a path outside $KIT_ROOT, under cache/ or with .. is refused.
mut_resolve() {
  local arg="$1" p dir real root
  case "$arg" in
    ""|*..*) echo "refused: bad path '$arg'"; return 1 ;;
    /*) p="${arg%/}" ;;
    *) p="$FIX/${arg%/}" ;;
  esac
  dir="$(dirname "$p")"
  real="$(cd -P "$dir" 2> /dev/null && pwd -P)" || { echo "no such folder: $dir"; return 1; }
  root="$(cd -P "$KIT_ROOT" 2> /dev/null && pwd -P)" || { echo "no kit root: $KIT_ROOT"; return 1; }
  case "$real/" in
    "$root"/cache/*) echo "refused: $arg is under cache/ (the model files are never changed)"; return 1 ;;
    "$root"/*) ;;
    *) echo "refused: $arg is outside $KIT_ROOT (the kit changes only its own fixtures)"; return 1 ;;
  esac
  printf '%s\n' "$real/$(basename "$p")"
}

mut_begin() {
  local n=1
  mkdir -p "$MUT" || return 1
  [ -f "$MUT/next" ] && n=$(($(cat "$MUT/next") + 1))
  echo "$n" > "$MUT/next"
  MUT_N=$n
}

# mut_log <op> <path> <extra> <shown> : one line of the journal (tab separated, "-" for nothing).
mut_log() { printf '%s\t%s\t%s\t%s\t%s\n' "$MUT_N" "$1" "$2" "$3" "$4" >> "$MUT/journal.tsv"; }

# mut_save <file> : the original, with its mode and time, kept for restore.
mut_save() { cp -pc "$1" "$MUT/$MUT_N.orig" 2> /dev/null || cp -p "$1" "$MUT/$MUT_N.orig"; }

mut_is_file() { [ -f "$1" ] && [ ! -L "$1" ] || { echo "no such file: $2"; return 1; }; }

op_flip() { # <abs> <shown> [<offset>]
  local p="$1" d="$2" off="$3" size ref
  mut_is_file "$p" "$d" || return 1
  size="$(stat -f %z "$p")"
  [ "$size" -gt 0 ] || { echo "cannot flip a byte of an empty file: $d"; return 1; }
  [ -n "$off" ] || off=$((size / 2))
  case "$off" in *[!0-9]*) echo "the offset must be a whole number"; return 2 ;; esac
  [ "$off" -lt "$size" ] || { echo "the offset $off is past the end of $d ($size bytes)"; return 1; }
  mut_begin || return 1
  mut_save "$p"
  mut_log flip-byte "$p" - "$d"
  ref="$MUT/$MUT_N.ref"
  touch -r "$p" "$ref"
  flip_at "$p" "$off" || { echo "could not flip a byte of $d"; return 1; }
  touch -r "$ref" "$p"
  rm -f "$ref"
  echo "FLIPPED $d offset $off (size $size bytes and modified time kept)"
}

# mut_peek : the number mut_begin will give the next change.
mut_peek() {
  local n=0
  [ -f "$MUT/next" ] && n="$(cat "$MUT/next")"
  echo $((n + 1))
}

PHRASE_WORDS=(amber basil cedar dune ember fjord glade harbor iris juniper kelp lotus meadow nectar orchid pebble quartz reed sable thistle umber violet willow yarrow zinc)

# phrase_for <n> : two words and a token made from n ("kelp lotus zq4001"): the same n makes the same phrase, two
# different n make two different phrases (the token), so a phrase finds exactly the file that holds it.
phrase_for() {
  local n="$1"
  printf '%s %s zq%s' "${PHRASE_WORDS[$((n % 24))]}" "${PHRASE_WORDS[$(((n / 24 + 7) % 24))]}" "$n"
}

# fit_phrase <n> <bytes> : a phrase that fits in <bytes> with its newline (the shorter form when the full one is too long).
fit_phrase() {
  local n="$1" size="$2" full short
  full="$(phrase_for "$n")"
  short="${full%% *} zq$n"
  if [ $((${#full} + 1)) -le "$size" ]; then
    printf '%s' "$full"
  elif [ $((${#short} + 1)) -le "$size" ]; then
    printf '%s' "$short"
  else
    return 1
  fi
}

# is_text_name <path> : a file kit-fixtures rewrites as plain text (the three types whose bytes are plain text).
is_text_name() {
  case "$(printf '%s' "${1##*.}" | tr 'A-Z' 'a-z')" in
    txt|md|html) return 0 ;;
  esac
  return 1
}

# op_edit <abs> <shown> <text> <same 0|1> [<n>] : a text file is rewritten with a new unique phrase and a size that
# differs (or the same size); another file gets a line appended (or one byte changed, same size). The modified time is new.
op_edit() {
  local p="$1" d="$2" text="$3" same="$4" n="$5" before after phrase="" mode note="" len
  mut_is_file "$p" "$d" || return 1
  before="$(stat -f %z "$p")"
  [ -n "$n" ] || n=$(($(mut_peek) + 4000))
  if is_text_name "$p"; then
    mode=text
    if [ "$same" = 1 ]; then
      phrase="$(fit_phrase "$n" "$before")" || { echo "cannot rewrite $d to the same size: it holds only $before bytes"; return 1; }
    else
      phrase="${text:-$(phrase_for "$n")}"
      len="$(printf '%s\n' "$phrase" | wc -c | tr -d ' ')"
      [ "$len" != "$before" ] || phrase="$phrase more"
    fi
  elif [ "$same" = 1 ]; then
    [ "$before" -gt 0 ] || { echo "cannot flip a byte of an empty file: $d"; return 1; }
    mode=flip
  else
    mode=append
  fi
  mut_begin || return 1
  mut_save "$p"
  mut_log edit "$p" - "$d"
  case "$mode" in
    text)
      if [ "$same" = 1 ]; then
        printf '%-*s\n' $((before - 1)) "$phrase" > "$p"
      else
        printf '%s\n' "$phrase" > "$p"
      fi ;;
    flip) flip_at "$p" $((before / 2)) && touch "$p" ;;
    append) printf '%s\n' "${text:-edited by kit-fixtures $n}" >> "$p" ;;
  esac || return 1
  after="$(stat -f %z "$p")"
  [ "$same" != 1 ] || note=", same size"
  echo "EDITED $d (size $before to $after bytes$note)"
  [ "$mode" != text ] || echo "PHRASE $phrase"
}

op_touch() { # <abs> <shown>
  local p="$1" d="$2"
  mut_is_file "$p" "$d" || return 1
  mut_begin || return 1
  mut_save "$p"
  mut_log touch "$p" - "$d"
  touch -r "$p" -A 010000 "$p" || return 1
  echo "TOUCHED $d (modified time one hour later)"
}

op_rename() { # <abs> <shown> <new name>
  local p="$1" d="$2" new="$3" target
  mut_is_file "$p" "$d" || return 1
  case "$new" in ""|*/*|*..*) echo "the new name must be a plain file name"; return 2 ;; esac
  target="$(dirname "$p")/$new"
  [ ! -e "$target" ] || { echo "already there: $new"; return 1; }
  mut_begin || return 1
  mut_log rename "$target" "$p" "$d"
  mv "$p" "$target" || return 1
  echo "RENAMED $d to $new"
}

op_move() { # <abs> <shown> <abs folder> <shown folder>
  local p="$1" d="$2" folder="$3" fshown="$4" target
  mut_is_file "$p" "$d" || return 1
  [ -d "$folder" ] || { echo "no such folder: $fshown"; return 1; }
  target="$folder/$(basename "$p")"
  [ ! -e "$target" ] || { echo "already there: $fshown/$(basename "$p")"; return 1; }
  mut_begin || return 1
  mut_log move "$target" "$p" "$d"
  mv "$p" "$target" || return 1
  echo "MOVED $d to $fshown"
}

op_delete() { # <abs> <shown>
  local p="$1" d="$2"
  mut_is_file "$p" "$d" || return 1
  mut_begin || return 1
  mut_save "$p"
  mut_log delete "$p" - "$d"
  rm -f "$p" || return 1
  echo "DELETED $d"
}

op_create() { # <abs> <shown> [<text>] [<n>] : a text file that holds a unique phrase (or the text given), printed
  local p="$1" d="$2" text="$3" n="$4" phrase
  [ ! -e "$p" ] || { echo "already there: $d"; return 1; }
  [ -n "$n" ] || n=$(($(mut_peek) + 4000))
  phrase="${text:-$(phrase_for "$n")}"
  mut_begin || return 1
  mut_log create "$p" - "$d"
  printf '%s\n' "$phrase" > "$p" || return 1
  echo "CREATED $d"
  echo "PHRASE $phrase"
}

cmd_mutate() {
  local op="$1" p d f fshown same=0 text="" a
  shift
  case "$op" in
    create|edit|flip-byte|touch|rename|move|delete) ;;
    *) usage; return 2 ;;
  esac
  [ $# -ge 1 ] || { usage; return 2; }
  d="$1"
  p="$(mut_resolve "$d")" || { printf '%s\n' "$p"; return 1; }
  case "$op" in
    create) [ $# -le 2 ] || { usage; return 2; }; op_create "$p" "$d" "$2" ;;
    edit)
      shift
      for a in "$@"; do
        case "$a" in
          --same-size) same=1 ;;
          *) [ -z "$text" ] || { usage; return 2; }; text="$a" ;;
        esac
      done
      op_edit "$p" "$d" "$text" "$same" "" ;;
    flip-byte) [ $# -le 2 ] || { usage; return 2; }; op_flip "$p" "$d" "$2" ;;
    touch) [ $# = 1 ] || { usage; return 2; }; op_touch "$p" "$d" ;;
    delete) [ $# = 1 ] || { usage; return 2; }; op_delete "$p" "$d" ;;
    rename) [ $# = 2 ] || { usage; return 2; }; op_rename "$p" "$d" "$2" ;;
    move)
      [ $# = 2 ] || { usage; return 2; }
      fshown="$2"
      f="$(mut_resolve "$2")" || { printf '%s\n' "$f"; return 1; }
      op_move "$p" "$d" "$f" "$fshown" ;;
  esac
}

# move_target <picked folder> <the file's own folder> : the first folder (sorted, the picked one first) that is not the file's own;
# empty when there is none (the picked folder holds no subfolder and the file lies in it).
move_target() { find "$1" -type d | LC_ALL=C sort | awk -v own="$2" '$0 != own { print; exit }'; }

# cmd_random <n> <seed> <folder> : n changes to n different files, chosen and shuffled by the seed. The phrases of the
# created and edited text files come from the seed and the position, so the same seed makes the same files.
cmd_random() {
  local n="$1" seed="$2" folder="$3" dirabs files count plan op f rel shown k=0 rc=0 num tgt tshown
  case "$n" in ""|*[!0-9]*) usage; return 2 ;; esac
  case "$seed" in ""|*[!0-9]*) usage; return 2 ;; esac
  [ "$n" -ge 1 ] || { usage; return 2; }
  dirabs="$(mut_resolve "$folder")" || { printf '%s\n' "$dirabs"; return 1; }
  [ -d "$dirabs" ] || { echo "no such folder: $folder"; return 1; }
  files="$(find "$dirabs" -type f ! -name '.DS_Store' | LC_ALL=C sort)"
  count="$(printf '%s\n' "$files" | awk 'NF > 0 { c++ } END { print c + 0 }')"
  if [ "$n" -gt "$count" ]; then
    echo "the folder holds $count files, fewer than the $n changes asked for"
    return 1
  fi
  plan="$(printf '%s\n' "$files" | awk -v n="$n" -v seed="$seed" '
    BEGIN { srand(seed); split("edit edit-same rename move delete create", ops, " ") }
    { a[NR] = $0 }
    END {
      for (i = NR; i > 1; i--) { j = int(rand() * i) + 1; t = a[i]; a[i] = a[j]; a[j] = t }
      for (k = 1; k <= n; k++) print ops[int(rand() * 6) + 1] "\t" a[k]
    }')"
  echo "RANDOM seed $seed: $n changes in $folder"
  while IFS=$'\t' read -r op f; do
    k=$((k + 1))
    num=$((1000000 + seed * 1000 + k))
    rel="${f#"$dirabs"/}"
    shown="${folder%/}/$rel"
    # a same-size edit needs a file that is not empty, and a text file with room for a phrase
    if [ "$op" = edit-same ] && { [ ! -s "$f" ] || { is_text_name "$f" && [ "$(stat -f %z "$f")" -lt 40 ]; }; }; then op=edit; fi
    case "$op" in
      edit) op_edit "$f" "$shown" "" 0 "$num" < /dev/null || rc=1 ;;
      edit-same) op_edit "$f" "$shown" "" 1 "$num" < /dev/null || rc=1 ;;
      rename) op_rename "$f" "$shown" "renamed-$(basename "$f")" < /dev/null || rc=1 ;;
      delete) op_delete "$f" "$shown" < /dev/null || rc=1 ;;
      move)
        tgt="$(move_target "$dirabs" "$(dirname "$f")")"
        if [ -z "$tgt" ]; then
          mkdir -p "$dirabs/moved" || { rc=1; continue; }
          tgt="$dirabs/moved"
        fi
        tshown="${folder%/}"
        [ "$tgt" = "$dirabs" ] || tshown="${folder%/}/${tgt#"$dirabs"/}"
        op_move "$f" "$shown" "$tgt" "$tshown" < /dev/null || rc=1 ;;
      create) op_create "$(dirname "$f")/kit-created-$seed-$k.txt" "$(dirname "$shown")/kit-created-$seed-$k.txt" "" "$num" < /dev/null || rc=1 ;;
    esac
  done <<< "$plan"
  return $rc
}

cmd_restore() {
  [ $# = 0 ] || { usage; return 2; }
  local n op path extra shown count=0 rc=0
  if [ ! -f "$MUT/journal.tsv" ]; then
    echo "nothing to restore"
    return 0
  fi
  while IFS=$'\t' read -r n op path extra shown; do
    case "$op" in
      flip-byte|edit|touch|delete)
        rm -f "$path"
        { cp -pc "$MUT/$n.orig" "$path" 2> /dev/null || cp -p "$MUT/$n.orig" "$path"; } < /dev/null || { echo "could not restore $shown"; rc=1; continue; } ;;
      rename|move) mv "$path" "$extra" < /dev/null || { echo "could not restore $shown"; rc=1; continue; } ;;
      create) rm -f "$path" ;;
    esac
    echo "RESTORED $shown ($op)"
    count=$((count + 1))
  done < <(tail -r "$MUT/journal.tsv")
  [ $rc = 0 ] && rm -rf "$MUT"
  echo "RESTORED $count changes"
  return $rc
}

# ---- ping ------------------------------------------------------------------------------------

# duration_of <media file> : seconds, read by ffmpeg from the file.
duration_of() {
  ffmpeg -nostdin -hide_banner -i "$1" 2>&1 | sed -n 's/^ *Duration: \([0-9][0-9]\):\([0-9][0-9]\):\([0-9.]*\),.*/\1 \2 \3/p' | awk '{ printf "%.2f", $1 * 3600 + $2 * 60 + $3 }'
}

ping_all() {
  local d="$KIT_ROOT/run/ping" fail=0 blocked=0 dur out tool
  rm -rf "$d"
  mkdir -p "$d" || return 1

  if ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=64x64:rate=5:duration=1 -f lavfi -i sine=frequency=440:duration=1 \
    -shortest -c:v mpeg4 -c:a aac "$d/tone.mp4" \
    && ffmpeg -nostdin -v error -i "$d/tone.mp4" -f null - ; then
    dur="$(duration_of "$d/tone.mp4")"
    if awk -v x="$dur" 'BEGIN { exit !(x >= 0.5 && x <= 2) }'; then
      echo "OK clip (ffmpeg): made tone.mp4 and read it back, $dur s"
    else
      echo "FAILED clip (ffmpeg): tone.mp4 reads back as '$dur' s, expected about 1"; fail=1
    fi
  else
    echo "FAILED clip (ffmpeg): ffmpeg could not make or decode a one second clip"; fail=1
  fi

  # say writes an empty 4 KB file when the speech service is refused (a sandbox does that), so the
  # clip is only good when ffmpeg reads speech of a plausible length back from it.
  out="$(say -o "$d/say.aiff" "kit check" 2>&1)"
  dur="$(duration_of "$d/say.aiff")"
  if [ -s "$d/say.aiff" ] && awk -v x="${dur:-0}" 'BEGIN { exit !(x >= 0.3 && x <= 10) }'; then
    echo "OK clip (say): made say.aiff and read it back, $dur s"
  elif [[ "$out" == *"Operation not permitted"* ]]; then
    echo "NEEDS A PERSON: blocked: say made no speech here (Operation not permitted: the speech service is refused by the sandbox this runs in); run it from your own Terminal"
    blocked=1
  else
    echo "FAILED clip (say): say.aiff reads back as '${dur:-nothing}' s: $out"; fail=1
  fi

  # textutil cannot write a file here (its own temporary folder is refused by a sandbox), so its
  # output goes to stdout and the shell makes the file.
  printf 'kit document 7731\n' > "$d/doc.txt"
  if textutil -convert docx -stdout "$d/doc.txt" > "$d/doc.docx" \
    && out="$(textutil -convert txt -stdout "$d/doc.docx")" && [ "${out%$'\n'}" = "kit document 7731" ]; then
    echo "OK document (textutil): made doc.docx and read back its text"
  else
    echo "FAILED document (textutil): doc.docx did not read back as 'kit document 7731'"; fail=1
  fi

  if tool="$(kit_tool fixturegen)" && "$tool" pdf-make "$d/doc.pdf" "kit pdf 4482" \
    && out="$("$tool" pdf-read "$d/doc.pdf")" && [ "${out%%$'\n'*}" = "pages 1" ] && [[ "$out" == *"kit pdf 4482"* ]]; then
    echo "OK pdf: made doc.pdf (1 page) and read back its text"
  else
    echo "FAILED pdf: doc.pdf did not read back as one page holding 'kit pdf 4482'"; fail=1
  fi

  mkdir -p "$d/repo"
  printf 'kit repo 9051\n' > "$d/repo/file.txt"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  if git -C "$d/repo" init -q \
    && git -C "$d/repo" add file.txt \
    && git -C "$d/repo" -c user.name=kit -c user.email=kit@example.invalid -c commit.gpgsign=false commit -q -m "kit commit" \
    && [ "$(git -C "$d/repo" log --format=%s)" = "kit commit" ] \
    && [ -d "$d/repo/.git" ] && [ -z "$(git -C "$d/repo" status --porcelain)" ]; then
    echo "OK repo (git): made a repo with one commit and read it back"
  else
    echo "FAILED repo (git): the repo did not read back with one commit"; fail=1
  fi

  rm -rf "$d"
  if [ $fail != 0 ]; then
    echo "FIXTURES PING FAILED"
    return 1
  fi
  if [ $blocked != 0 ]; then
    echo "FIXTURES PING NOT COMPLETE: a part was blocked, it is not counted as passed"
    return 3
  fi
  echo "FIXTURES PING OK"
  return 0
}

main() {
  case "$1" in
    ping) [ $# = 1 ] || { usage; return 2; }; ping_all ;;
    build)
      case "$2" in
        golden) [ $# = 2 ] || { usage; return 2; }; build_golden ;;
        golden-docs) [ $# = 2 ] || { usage; return 2; }; build_golden_docs ;;
        boundary) [ $# = 2 ] || { usage; return 2; }; build_boundary ;;
        golden-av) [ $# = 2 ] || { usage; return 2; }; build_golden_av ;;
        pauselong) [ $# = 2 ] || { usage; return 2; }; build_pauselong ;;
        mix500) [ $# = 2 ] || { usage; return 2; }; build_mix500 ;;
        tree) [ $# = 2 ] || { usage; return 2; }; build_tree ;;
        empty) [ $# = 2 ] || { usage; return 2; }; build_empty ;;
        filler) [ $# = 3 ] || { usage; return 2; }; build_filler "$3" ;;
        homefolders) [ $# = 2 ] || { usage; return 2; }; build_homefolders ;;
        minimix) [ $# = 2 ] || { usage; return 2; }; build_minimix ;;
        extra) [ $# = 2 ] || { usage; return 2; }; build_extra ;;
        overlap) [ $# = 2 ] || { usage; return 2; }; build_overlap ;;
        matrix) [ $# = 2 ] || { usage; return 2; }; build_matrix ;;
        repos) [ $# = 2 ] || { usage; return 2; }; build_repos ;;
        unrelated) [ $# = 3 ] || { usage; return 2; }; build_unrelated "$3" ;;
        *) echo "build ${2:-<nothing>}: not built yet (golden, golden-docs, boundary, tree, empty, filler, homefolders, minimix, extra, overlap, matrix, repos and unrelated are written so far)"; usage; return 2 ;;
      esac ;;
    plant-model) [ $# = 2 ] || { usage; return 2; }; plant_model "$2" ;;
    mutate)
      shift
      [ $# -ge 1 ] || { usage; return 2; }
      if [ "$1" = random ]; then
        [ $# = 5 ] && [ "$3" = --seed ] || { usage; return 2; }
        cmd_random "$2" "$4" "$5"
      else
        cmd_mutate "$@"
      fi ;;
    restore) shift; cmd_restore "$@" ;;
    expect)
      case "$2" in
        listing) [ $# = 3 ] || { usage; return 2; }; expect_listing "$3" ;;
        counts) [ $# = 3 ] || { usage; return 2; }; expect_counts "$3" ;;
        matrix) [ $# = 2 ] || { usage; return 2; }; expect_matrix ;;
        extensions)
          if [ $# = 2 ]; then
            expect_extensions ""
          elif [ $# = 4 ] && [ "$3" = --kinds ] && [ -n "$4" ]; then
            expect_extensions "$4"
          else
            usage; return 2
          fi ;;
        *) usage; return 2 ;;
      esac ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-fixtures "$@")" main "$@"
exit $?

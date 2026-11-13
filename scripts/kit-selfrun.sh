#!/bin/bash
# kit-selfrun.sh copy-project | break key-names|write-picked | build | restore | clean
#
# The product-level self-runs 2 and 3 of verify.md (Self-run): a throwaway copy of the project is broken in one named
# place, built, and run through the S8 checks, which must go red; then the copy is restored and the same checks must go
# green. Written from the design alone: it never reads the product to find a place to break, it searches the copy
# mechanically for the two anchors the design names and changes only them.
#   the anchors  the `Rules` table and the key names written in it (design section 1: .pem, id_rsa, .env ...), and
#                `FileGate` with the open flags `O_RDONLY | O_NOFOLLOW` (design section 9, item 2), which appears in
#                exactly that spelling once, in the one source file that declares `FileGate`.
#   copy-project copies the source ($KIT_SELFRUN_SOURCE, else the project) to $KIT_ROOT/break/project, without .build,
#                dist, .git and .ril/evidence; third_party is linked, not copied.
#   break key-names    replaces the literals ".pem", "id_rsa" and ".env" of the copy's Rules table by literals that
#                      cannot match (".key", ".p12", ".pfx" and ".kdbx" stay); prints each changed line.
#   break write-picked rewrites the one `O_RDONLY | O_NOFOLLOW` of the copy's FileGate to
#                      `O_RDWR | O_NOFOLLOW | O_TRUNC`, so every picked file the helper opens is opened for writing.
#                      Both breaks check every anchor before any byte changes: an anchor found zero times or more than
#                      once is `design-anchor mismatch: <anchor>`, exit 4 (a design-anchor mismatch goes back to an
#                      implementer, who exposes the named symbol; nobody looks for another place to break).
#   build        runs `swift build -c release` and scripts/bundle.sh inside the copy, keeps the copy's Sesame.app at
#                $KIT_ROOT/break/Sesame.app, writes the keep-app marker $KIT_ROOT/break/selfrun-app (one line, the app's
#                path; kit-reset.sh with id kit copies that app instead of dist/Sesame.app) and replaces
#                $KIT_ROOT/apps/Sesame.app with it.
#   restore      puts back the files `break` changed and proves the copy equals the source byte for byte; the copy's
#                .build and dist stay, so the next build is incremental.
#   clean        removes $KIT_ROOT/break/ (the copy, the kept app and the marker).
# Only $KIT_ROOT/break/ and $KIT_ROOT/apps/Sesame.app are ever written; the source is only read; nothing is started.
# Exit codes: 0 done; 1 error; 2 usage; 4 a precondition does not hold (no copy, a copy already broken, a design-anchor
# mismatch, a copy that differs from the source after restore).
. "$(dirname "$0")/kit-lib/common.sh"

BREAK="$KIT_ROOT/break"
COPY="$BREAK/project"
MARKER="$BREAK/selfrun-app"
SOURCE="${KIT_SELFRUN_SOURCE:-$KIT_PROJECT}"
SOURCE="${SOURCE%/}"

usage() {
  cat >&2 <<'EOF'
usage: kit-selfrun.sh copy-project
       kit-selfrun.sh break key-names|write-picked
       kit-selfrun.sh build
       kit-selfrun.sh restore
       kit-selfrun.sh clean
EOF
}

need_copy() {
  [ -d "$COPY" ] && return 0
  echo "not valid: there is no copy at $COPY; run kit-selfrun.sh copy-project first"
  return 1
}

# tree_sums <root> : "<sha256>  <path>" of every file a copy holds, sorted by path.
tree_sums() {
  ( cd "$1" && find . \( -path ./.build -o -path ./dist -o -path ./.git -o -path ./.ril/evidence -o -path ./third_party \) -prune -o -type f -print0 | sort -z | xargs -0 shasum -a 256 )
}

# same_as_source : status 0 when the copy holds the source's files byte for byte; else prints what differs.
same_as_source() {
  local diffs
  diffs="$(diff <(tree_sums "$SOURCE") <(tree_sums "$COPY"))" && return 0
  echo "not valid: the copy differs from the source:"
  printf '%s\n' "$diffs" | head -n 10
  return 1
}

cmd_copy_project() {
  local entry name sub
  [ -d "$SOURCE" ] || { echo "no source folder: $SOURCE"; return 1; }
  rm -rf "$COPY"
  rm -f "$BREAK/broken" "$BREAK/changed"
  mkdir -p "$COPY" || { echo "could not make $COPY"; return 1; }
  for entry in "$SOURCE"/* "$SOURCE"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    case "$name" in
      .build|dist|.git) ;;
      third_party) ln -s "$SOURCE/third_party" "$COPY/third_party" || return 1 ;;
      .ril)
        mkdir -p "$COPY/.ril"
        for sub in "$entry"/* "$entry"/.[!.]*; do
          [ -e "$sub" ] || [ -L "$sub" ] || continue
          [ "${sub##*/}" = evidence ] && continue
          cp -Rp "$sub" "$COPY/.ril/" || return 1
        done ;;
      *) cp -Rp "$entry" "$COPY/" || return 1 ;;
    esac
  done
  same_as_source || return 1
  echo "copied $SOURCE to $COPY (without .build, dist, .git and .ril/evidence; third_party is linked)"
}

# decl_files <Symbol> : the Swift files of the copy's Sources that declare an enum, struct, class or actor of that name.
decl_files() {
  [ -d "$COPY/Sources" ] || return 0
  find "$COPY/Sources" -type f -name '*.swift' -print0 | xargs -0 perl -e '
    my $sym = shift;
    for my $f (@ARGV) {
      open my $h, "<", $f or next;
      local $/;
      my $t = <$h>;
      print "$f\n" if $t =~ /\b(?:enum|struct|class|actor)\s+\Q$sym\E\b/;
    }' "$1"
}

# count_fixed <file> <text> : how many times the exact text occurs in the file.
count_fixed() {
  perl -e 'local $/; open my $h, "<", $ARGV[0] or exit 3; my $t = <$h>; my $n = () = $t =~ /\Q$ARGV[1]\E/g; print "$n\n"' "$1" "$2"
}

# one_decl <Symbol> : sets DECL to the one file that declares the symbol; else prints a mismatch and returns 1.
one_decl() {
  local files count
  files="$(decl_files "$1")"
  count="$(printf '%s' "$files" | grep -c .)"
  if [ "$count" != 1 ]; then
    echo "design-anchor mismatch: $1 is declared in $count files under Sources, not one"
    return 1
  fi
  DECL="$files"
  return 0
}

# replace_in <file> <old> <new> : replaces the text on its line and prints `changed <path>:<line>: <new line>`.
replace_in() {
  local file="$1" old="$2" new="$3" rel="${1#"$COPY"/}"
  perl -i -pe 'BEGIN { $old = shift; $new = shift; $rel = shift; }
    if (s/\Q$old\E/$new/) { ($t = $_) =~ s/^\s+|\s+$//g; print STDOUT "changed $rel:$.: $t\n"; }' "$old" "$new" "$rel" "$file"
}

cmd_break() {
  local mode="$1" rules gate n name bad=0 i=0 new
  need_copy || return 4
  if [ -f "$BREAK/broken" ]; then
    echo "not valid: the copy is already broken ($(cat "$BREAK/broken")); run kit-selfrun.sh restore first"
    return 4
  fi
  case "$mode" in
    key-names)
      one_decl Rules || return 4
      rules="$DECL"
      for name in .pem id_rsa .env; do
        n="$(count_fixed "$rules" "\"$name\"")"
        if [ "$n" != 1 ]; then
          echo "design-anchor mismatch: \"$name\" found $n times in ${rules#"$COPY"/}, not once"
          bad=1
        fi
      done
      [ "$bad" = 0 ] || return 4
      for name in .pem id_rsa .env; do
        i=$((i + 1))
        new="\"~selfrun-broken-$i~\""
        replace_in "$rules" "\"$name\"" "$new" || return 1
      done
      echo "${rules#"$COPY"/}" > "$BREAK/changed"
      ;;
    write-picked)
      one_decl FileGate || return 4
      gate="$DECL"
      n="$(count_fixed "$gate" 'O_RDONLY | O_NOFOLLOW')"
      if [ "$n" != 1 ]; then
        echo "design-anchor mismatch: O_RDONLY | O_NOFOLLOW found $n times in ${gate#"$COPY"/}, not once"
        return 4
      fi
      replace_in "$gate" 'O_RDONLY | O_NOFOLLOW' 'O_RDWR | O_NOFOLLOW | O_TRUNC' || return 1
      echo "${gate#"$COPY"/}" > "$BREAK/changed"
      ;;
  esac
  echo "$mode" > "$BREAK/broken"
  echo "the copy is broken: $mode"
}

cmd_restore() {
  local rel
  need_copy || return 4
  if [ -f "$BREAK/changed" ]; then
    while read -r rel; do
      [ -n "$rel" ] || continue
      cp "$SOURCE/$rel" "$COPY/$rel" || { echo "could not put back $rel"; return 1; }
      echo "put back $rel"
    done < "$BREAK/changed"
  fi
  rm -f "$BREAK/broken" "$BREAK/changed"
  same_as_source || return 4
  echo "the copy equals the source, byte for byte"
}

cmd_build() {
  need_copy || return 4
  # A marker of an earlier build must not point at an app this build may not replace.
  rm -f "$BREAK/selfrun-app"
  ( cd "$COPY" && swift build -c release ) || { echo "swift build -c release failed in the copy"; return 1; }
  "$COPY/scripts/bundle.sh" || { echo "scripts/bundle.sh failed in the copy"; return 1; }
  [ -d "$COPY/dist/Sesame.app" ] || { echo "scripts/bundle.sh made no dist/Sesame.app in the copy"; return 1; }
  rm -rf "$BREAK/Sesame.app"
  ditto "$COPY/dist/Sesame.app" "$BREAK/Sesame.app" || { echo "could not keep the copy's app"; return 1; }
  printf '%s\n' "$BREAK/Sesame.app" > "$MARKER" || return 1
  mkdir -p "$KIT_ROOT/apps"
  rm -rf "$KIT_APP"
  ditto "$BREAK/Sesame.app" "$KIT_APP" || { echo "could not put the copy's app at $KIT_APP"; return 1; }
  echo "built the copy: app kept at $BREAK/Sesame.app, marker $MARKER written, $KIT_APP replaced"
}

cmd_clean() {
  rm -rf "$BREAK"
  echo "removed $BREAK (the copy, the kept app and the marker)"
}

main() {
  case "${1:-}" in
    copy-project) [ $# = 1 ] || { usage; return 2; }; cmd_copy_project ;;
    break) { [ $# = 2 ] && { [ "$2" = key-names ] || [ "$2" = write-picked ]; }; } || { usage; return 2; }; cmd_break "$2" ;;
    build) [ $# = 1 ] || { usage; return 2; }; cmd_build ;;
    restore) [ $# = 1 ] || { usage; return 2; }; cmd_restore ;;
    clean) [ $# = 1 ] || { usage; return 2; }; cmd_clean ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-selfrun "$@")" main "$@"
exit $?

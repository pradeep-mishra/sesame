#!/bin/bash
# The slice 1 checks of S6 for the model download (feature map S6: S6.5, S6.6, S6.7, S6.12). Sourced by kit-run.sh
# after common.sh and recipes.sh, never run. Each check prints one `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a
# failure lists every reason, on one line) and uses the exit codes of every kit script: 0 for a pass or a
# needs-a-person, 1 for a fail, 4 for `RERUN <id> not valid: <reason>` (a kit fault, never a pass or a fail).
# With KIT_PLANT=1 (kit-run.sh --plant <id>) each check changes one input of its own comparison and must print
# `CHECK <id> FAIL planted: <what>`.
#
# Starting state. Every check starts from the recipe `fresh-throttled` (reset, mirror at 500,000 bytes a second, app
# started, no setup done) and then does its own steps, because the checks before it have already planted files,
# switched the mirror offline or quit the app. Rates: S6.5 and S6.7 keep the recipe's 500,000 bytes a second while
# they look at a running download; S6.6 and S6.12 switch the mirror to full rate to let the download finish, and S6.6
# throttles it again (2,000,000 bytes a second) around each planted file so the message stays on screen for 150 s
# while the re-download runs.
#
# What the checks read, and where: the setup window through `kit-ax.sh dump setup` and one `kit-ax.sh click "<label>"`
# (the Retry button of S6.7, the label read from the dump); files in models/ with `stat` and `shasum`; the mirror's
# request log through `kit-mirror.sh requests`. They post no key, type no text, open no kit window and capture no
# picture (verify.md, Kit safety: none of it is needed). `kit-launch.sh quit` and `relaunch` are not kit-ax.sh modes.
#
# What a check cannot tell apart, said in the lines it prints: the mirror logs a request when it is finished, so a
# download in flight shows in models/ and not yet in the log; the figures the pinned files add up to are
# kit_models' (scripts/kit-lib/models.tsv, written from design section 7), never the product's.

S6_AX="$KIT_SCRIPTS/kit-ax.sh"
S6_LD="$KIT_SCRIPTS/kit-launch.sh"
S6_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S6_MR="$KIT_SCRIPTS/kit-mirror.sh"
S6_MODELS="$KIT_ROOT/home/Library/Application Support/Sesame/models"
S6_TEXT="embeddinggemma-2-Q8_0.gguf"
S6_MM="mmproj-embeddinggemma-2-Q8_0.gguf"
S6_MSG="The model file was damaged, so it was deleted. Downloading it again."
S6_ERRTEXT="could not download the model"
S6_DUMP_LIMIT=20             # seconds a read of the setup window may take (a long tree is slow to walk)
S6_WHY=""
S6_RC=0
S6_PERSON=""
S6_PLANTED=""
S6_SKEW=0
S6_VPLANT=""
S6_DUMP=""
S6_ERR=""
S6_DL=""
S6_AT=0
S6_FIG=""
S6_VERDICT=""
S6_RC2=0
S6_B0=0
S6_B1=0
S6_PPATH=""
S6_PSIZE=""
S6_VMSG=""

# ---- plumbing -------------------------------------------------------------------------------------

s6_why() { S6_WHY="${S6_WHY:+$S6_WHY; }$1"; }

# s6_last <text> : the last non-empty line.
s6_last() { printf '%s\n' "$1" | awk 'NF { l = $0 } END { print l }'; }

# s6_press <kit-ax.sh> <label> : presses the control or the status item's menu item with that label; status 0 when it was
# pressed. On a failure kit-ax.sh's output is printed, so the log says why.
s6_press() {
  local out rc
  out="$(kq "$1" click "$2" 2>&1)"; rc=$?
  [ $rc = 0 ] && return 0
  printf '%s\n' "$out" | sed "s/^/  | kit-ax click \"$2\" exited $rc: /"
  return $rc
}

# s6_pick <output> : the first NEEDS A PERSON line without its label, else the last non-empty line.
s6_pick() {
  local p
  p="$(printf '%s\n' "$1" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
  if [ -n "$p" ]; then printf '%s' "$p"; else s6_last "$1"; fi
}

# s6_fail <id> <reason> : the CHECK FAIL line (a plant says what was planted).
s6_fail() {
  if [ -n "$KIT_PLANT" ]; then echo "CHECK $1 FAIL planted: $S6_PLANTED: $2"; else echo "CHECK $1 FAIL $2"; fi
}

# s6_cleanup : the mirror back online on every path (a check that switched it off must not leave it so).
s6_cleanup() { kq "$S6_MR" online >/dev/null 2>&1; return 0; }

# s6_run <function> : the check body with its variables reset, the mirror put back online after it on every path.
s6_run() {
  local rc
  S6_WHY=""; S6_RC=0; S6_PERSON=""; S6_PLANTED=""; S6_SKEW=0; S6_VPLANT=""
  trap 's6_cleanup; exit 130' INT TERM HUP
  "$@"; rc=$?
  s6_cleanup
  trap 's1_cleanup; exit 130' INT TERM HUP
  return $rc
}

# s6_state <id> : the recipe fresh-throttled. Status 0 ready; else the CHECK or RERUN line is printed, S6_RC is set
# and the status is 1.
s6_state() {
  local out rc
  out="$(recipe_fresh_throttled 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/recipe fresh-throttled: /'
  [ $rc = 0 ] && return 0
  case $rc in
    3) echo "CHECK $1 NEEDS-A-PERSON $(s6_pick "$out")"; S6_RC=0 ;;
    4) echo "RERUN $1 not valid: recipe fresh-throttled: $(s6_pick "$out")"; S6_RC=4 ;;
    *) s6_fail "$1" "recipe fresh-throttled cannot finish: $(s6_pick "$out")"; S6_RC=1 ;;
  esac
  return 1
}

# s6_total : the bytes of the two pinned model files together (models.tsv).
s6_total() { kit_models | awk '{ n += $2 } END { print n + 0 }'; }

# s6_done <id> : the verdict. A person-step found on the way, else FAIL with every reason, else the PASS line (argument 2).
s6_done() {
  if [ -n "$S6_PERSON" ]; then echo "CHECK $1 NEEDS-A-PERSON $S6_PERSON"; return 0; fi
  if [ -n "$S6_WHY" ]; then s6_fail "$1" "$S6_WHY"; return 1; fi
  echo "CHECK $1 PASS $2"
  return 0
}

# ---- the setup window, as the accessibility tree shows it ------------------------------------------------

# s6_dump : the setup window's tree into S6_DUMP. Status 0 read; 1 no setup window (S6_ERR says what the driver
# said); 3 a person-step (Accessibility, or Sesame did not answer within the limit; S6_ERR says which).
s6_dump() {
  local out rc
  S6_ERR=""
  out="$(KIT_NO_EVIDENCE=1 kit_timeout "$S6_DUMP_LIMIT" "$S6_AX" dump setup 2>&1)"; rc=$?
  case $rc in
    0) S6_DUMP="$out"; return 0 ;;
    3) S6_DUMP=""; S6_ERR="$(s6_pick "$out")"; return 3 ;;
    124) S6_DUMP=""; S6_ERR="Sesame did not answer an accessibility read within $S6_DUMP_LIMIT s: restart it, and allow the terminal to control System Events if macOS asks"; return 3 ;;
    *) S6_DUMP=""; S6_ERR="kit-ax.sh dump setup said \"$(s6_last "$out")\""; return 1 ;;
  esac
}

# s6_wait_window <seconds> : status 0 once the setup window answers (S6_DUMP set), 1 never, 3 a person-step.
s6_wait_window() {
  local end=$((SECONDS + $1)) rc
  while :; do
    s6_dump; rc=$?
    [ $rc = 0 ] && return 0
    [ $rc = 3 ] && return 3
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 1
  done
}

# s6_save <name> : the last dump in the evidence folder as ax-<name>.txt (never over an older one).
s6_save() {
  local dir f n=1
  dir="$(kit_evidence_dir)"
  [ -n "$dir" ] && [ -n "$S6_DUMP" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/ax-$1.txt"
  while [ -e "$f" ]; do n=$((n + 1)); f="$dir/ax-$1-$n.txt"; done
  printf '%s\n' "$S6_DUMP" > "$f" 2>/dev/null && echo "  | saved $f"
}

s6_has() { case "$S6_DUMP" in *"$1"*) return 0 ;; esac; return 1; }
s6_has_ci() {
  local d w
  d="$(printf '%s' "$S6_DUMP" | tr 'A-Z' 'a-z')"
  w="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$d" in *"$w"*) return 0 ;; esac
  return 1
}

# s6_figure : the progress figure the dump shows, "mb <N> <total>" for "N of 865 MB" or "pct <N>" for a percent;
# nothing when the dump shows neither. The MB form wins when both are there.
s6_figure() {
  printf '%s\n' "$S6_DUMP" | awk '
    !mb && match($0, /[0-9][0-9,.]* of [0-9][0-9,.]* MB/) { s = substr($0, RSTART, RLENGTH); gsub(/,/, "", s); split(s, a, " "); mb = "mb " a[1] " " a[3] }
    !pc && match($0, /[0-9][0-9.]*%/) { s = substr($0, RSTART, RLENGTH - 1); pc = "pct " s }
    END { if (mb != "") print mb; else if (pc != "") print pc }'
}

# s6_judge <figure> <low bytes> <high bytes> : "ok <detail>" or "bad <detail>". The figure must lie within 3 MB
# (decimal, as "865 MB" is: the two files add up to 864.68 million bytes) of the bytes in models/ at the time of the
# read, which fell between <low> and <high> (the bytes just before and just after the dump). A percent is shown
# whole, so it may also be off by the half point its rounding hides.
s6_judge() {
  awk -v fig="$1" -v lo="$2" -v hi="$3" -v tot="$(s6_total)" 'BEGIN {
    split(fig, a, " ")
    if (a[1] == "mb") {
      if (a[3] * 1000000 < tot - 500000 || a[3] * 1000000 > tot + 500000) {
        printf "bad the total reads %s MB, the pinned files add up to %.1f MB\n", a[3], tot / 1000000; exit
      }
      f = a[2] * 1000000
      d = (f < lo) ? lo - f : ((f > hi) ? f - hi : 0)
      if (d <= 3000000) printf "ok \"%s of %s MB\" is %.2f MB from the %.2f to %.2f MB in models/\n", a[2], a[3], d / 1000000, lo / 1000000, hi / 1000000
      else printf "bad \"%s of %s MB\" is %.2f MB from the %.2f to %.2f MB in models/ (limit 3 MB)\n", a[2], a[3], d / 1000000, lo / 1000000, hi / 1000000
    } else {
      plo = lo * 100 / tot; phi = hi * 100 / tot; p = a[2]
      d = (p < plo) ? plo - p : ((p > phi) ? p - phi : 0)
      lim = 0.5 + 3000000 * 100 / tot
      if (d <= lim) printf "ok \"%s%%\" is %.2f points from the %.2f to %.2f %% in models/\n", p, d, plo, phi
      else printf "bad \"%s%%\" is %.2f points from the %.2f to %.2f %% in models/ (limit %.2f: 3 MB and the rounding)\n", p, d, plo, phi, lim
    }
  }'
}

# s6_gt <a> <b> : status 0 when a is greater than b (as numbers).
s6_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a > b) ? 0 : 1 }'; }

# s6_read : one read of the progress figure with the bytes in models/ taken just before and just after it (a read
# that took long enough for more than 2 MB to arrive is taken again, up to 3 times). S6_FIG, S6_VERDICT, S6_B0 and
# S6_B1 hold the result; S6_RC2 is the status of the dump (0, 1 or 3). S6_SKEW is the plant's change to the bytes.
s6_read() {
  local b0 b1 try rc
  for try in 1 2 3; do
    b0="$(s6_bytes)"; s6_dump; rc=$?; b1="$(s6_bytes)"
    [ $rc = 0 ] || break
    [ $((b1 - b0)) -le 2000000 ] && break
  done
  S6_RC2=$rc
  S6_B0=$((b0 + S6_SKEW)); S6_B1=$((b1 + S6_SKEW))
  S6_FIG=""; S6_VERDICT=""
  [ $rc = 0 ] || return $rc
  S6_FIG="$(s6_figure)"
  [ -n "$S6_FIG" ] || return 0
  S6_VERDICT="$(s6_judge "$S6_FIG" "$S6_B0" "$S6_B1")"
  return 0
}

# s6_retry_label : the label of the Retry button in the dump ("Try again" in the mockup, or "Retry"); nothing if none.
s6_retry_label() {
  printf '%s\n' "$S6_DUMP" | awk '/label="/ && /AXButton|AXLink/ && tolower($0) ~ /try again|retry/ { i = index($0, "label=\""); s = substr($0, i + 7); j = index(s, "\""); print substr(s, 1, j - 1); exit }'
}

# s6_start_state : absent, disabled or enabled, for the control labelled "Start indexing" in the dump.
s6_start_state() {
  printf '%s\n' "$S6_DUMP" | awk '/label="Start indexing"/ { f = 1; if ($0 ~ /\[disabled\]/) d = 1 } END { if (!f) print "absent"; else if (d) print "disabled"; else print "enabled" }'
}

s6_start_read() {
  s6_has "Add folder…" || { echo unread; return 0; }
  s6_start_state
}

s6_start_failed_ok() {
  case "$1" in disabled|absent) return 0 ;; esac
  return 1
}

s6_ticked_rows() {
  printf '%s\n' "$S6_DUMP" | awk '/AXCheckBox/ && /value="(1|true|on)"/ { n++ } END { print n + 0 }'
}

# ---- models/, the mirror's log, the pinned figures -------------------------------------------------------

# s6_bytes : the bytes of every file in models/ (whole files and .partial files): the downloaded total the setup's
# "N of 865 MB" counts.
s6_bytes() {
  local f t=0 b
  for f in "$S6_MODELS"/*; do
    [ -f "$f" ] || continue
    b="$(stat -f %z "$f" 2>/dev/null)"
    t=$((t + ${b:-0}))
  done
  echo "$t"
}

# s6_partials : "<model file name> <bytes>" for each .partial file in models/.
s6_partials() {
  local f b
  for f in "$S6_MODELS"/*.partial; do
    [ -f "$f" ] || continue
    b="$(stat -f %z "$f" 2>/dev/null)"
    echo "$(basename "$f" .partial) ${b:-0}"
  done
}

# s6_wait_bytes <seconds> : status 0 once models/ holds bytes.
s6_wait_bytes() {
  local end=$((SECONDS + $1)) b
  while :; do
    b="$(s6_bytes)"
    [ "$b" -gt 0 ] && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.5
  done
}

# s6_wait_min <bytes> <seconds> : status 0 once models/ holds at least that many bytes.
s6_wait_min() {
  local end=$((SECONDS + $2)) b
  while :; do
    b="$(s6_bytes)"
    [ "$b" -ge "$1" ] && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.5
  done
}

s6_whole() { models_check "$S6_MODELS" >/dev/null 2>&1; }

# s6_wait_whole <max seconds> <stall seconds> : status 0 once both model files are in models/ at their pinned size;
# 1 when the bytes stop growing for the stall time or the maximum runs out (S6_DL says which).
s6_wait_whole() {
  local end=$((SECONDS + $1)) stall="$2" last cur at=$SECONDS
  last="$(s6_bytes)"
  while ! s6_whole; do
    cur="$(s6_bytes)"
    if [ "$cur" != "$last" ]; then last="$cur"; at=$SECONDS; fi
    if [ $((SECONDS - at)) -ge "$stall" ]; then S6_DL="the download stalled at $cur bytes for $stall s"; return 1; fi
    if [ "$SECONDS" -ge "$end" ]; then S6_DL="the model files were not whole $1 s later ($cur bytes)"; return 1; fi
    sleep 1
  done
  return 0
}

# s6_verify : each model file's size and SHA-256 against the pinned figures (models.tsv). Status 0 all right; else 1
# and S6_VMSG says which is wrong. The plant changes the first digit of the text model's pinned SHA-256.
s6_verify() {
  local name size sha f got gsha bad=""
  while read -r name size sha; do
    [ -n "$S6_VPLANT" ] && [ "$name" = "$S6_TEXT" ] && sha="f${sha#?}"
    f="$S6_MODELS/$name"
    if [ ! -f "$f" ]; then bad="$bad $name is missing."; continue; fi
    got="$(stat -f %z "$f")"
    if [ "$got" != "$size" ]; then bad="$bad $name is $got bytes, pinned $size."; continue; fi
    gsha="$(shasum -a 256 "$f" | awk '{ print $1 }')"
    [ "$gsha" = "$sha" ] || bad="$bad $name has SHA-256 $gsha, pinned $sha."
  done < <(kit_models)
  S6_VMSG="${bad# }"
  [ -z "$bad" ]
}

# s6_gets <file name> : the GET requests the mirror logged for that model file.
s6_gets() {
  kq "$S6_MR" requests 2>/dev/null | awk -v n="$1" '$2 == "GET" { p = $3; sub(/\?.*/, "", p); c = split(p, s, "/"); if (s[c] == n) k++ } END { print k + 0 }'
}

# s6_reqs : the requests of any method the mirror logged for either model file.
s6_reqs() {
  kq "$S6_MR" requests 2>/dev/null | awk -v a="$S6_TEXT" -v b="$S6_MM" '$2 ~ /^[A-Z]+$/ && $3 ~ /^\// { p = $3; sub(/\?.*/, "", p); c = split(p, s, "/"); if (s[c] == a || s[c] == b) k++ } END { print k + 0 }'
}

# s6_ranged <file name> <bytes> : status 0 when the mirror logged a GET for that file with a Range that starts at
# exactly <bytes>, answered 206.
s6_ranged() {
  kq "$S6_MR" requests 2>/dev/null | awk -v n="$1" -v from="$2" '
    $2 == "GET" { p = $3; sub(/\?.*/, "", p); c = split(p, s, "/"); if (s[c] != n) next
      if ($4 ~ ("^range=bytes=" from "-[0-9]*$") && $5 == "status=206") f = 1 }
    END { exit f ? 0 : 1 }'
}

# s6_get_lines <file name> : the mirror's GET lines for that file, shown as evidence.
s6_get_lines() {
  kq "$S6_MR" requests 2>/dev/null | awk -v n="$1" '$2 == "GET" { p = $3; sub(/\?.*/, "", p); c = split(p, s, "/"); if (s[c] == n) print "  | " $0 }'
}

# s6_stats : "<name> <inode> <modified time to the nanosecond>" for each model file, or "<name> missing".
s6_stats() {
  local name size sha f
  while read -r name size sha; do
    f="$S6_MODELS/$name"
    if [ -f "$f" ]; then echo "$name $(stat -f '%i %Fm' "$f")"; else echo "$name missing"; fi
  done < <(kit_models)
}

# ---- S6.5: the download shows progress ------------------------------------------------------------------

s6_check_5() {
  local rc haswin=0 first prev v i tries rose=0 bytes_first fig_kind
  [ -n "$KIT_PLANT" ] && { S6_SKEW=10000000; S6_PLANTED="the bytes in models/ read as 10 MB more than they are"; }
  s6_state S6.5 || return $S6_RC
  s6_wait_window 8; rc=$?
  case $rc in
    0) haswin=1 ;;
    3) echo "CHECK S6.5 NEEDS-A-PERSON $S6_ERR"; return 0 ;;
    *) s6_why "no setup window: $S6_ERR (8 s after the app started)" ;;
  esac
  if ! s6_wait_bytes 15; then
    s6_why "nothing downloaded: models/ holds 0 bytes 15 s after the app started with the mirror at 500,000 bytes a second"
  fi
  if [ $haswin = 1 ]; then
    s6_read; rc=$S6_RC2
    if [ $rc = 3 ]; then echo "CHECK S6.5 NEEDS-A-PERSON $S6_ERR"; return 0; fi
    s6_save s6-5-setup
    if [ $rc != 0 ]; then
      s6_why "no setup window: $S6_ERR"
    elif [ -z "$S6_FIG" ]; then
      s6_why "no progress figure: the setup window shows neither \"N of 865 MB\" nor a percent"
    else
      fig_kind="${S6_FIG%% *}"
      echo "  | read 1: $S6_FIG; $S6_VERDICT; models/ held $S6_B0 to $S6_B1 bytes"
      case "$S6_VERDICT" in bad*) s6_why "read 1: ${S6_VERDICT#bad }" ;; esac
      first="${S6_FIG#* }"; first="${first%% *}"
      prev="$first"; bytes_first="$S6_B0"
      tries=1; [ "$fig_kind" = pct ] && tries=4     # a whole percent needs up to 8.65 MB, 17 s at this rate
      for ((i = 0; i < tries; i++)); do
        sleep 10
        s6_read; rc=$S6_RC2
        if [ $rc = 3 ]; then echo "CHECK S6.5 NEEDS-A-PERSON $S6_ERR"; return 0; fi
        if [ $rc != 0 ] || [ -z "$S6_FIG" ]; then s6_why "no progress figure at read $((i + 2)), 10 s after the one before"; break; fi
        echo "  | read $((i + 2)): $S6_FIG; $S6_VERDICT; models/ held $S6_B0 to $S6_B1 bytes"
        case "$S6_VERDICT" in bad*) s6_why "read $((i + 2)): ${S6_VERDICT#bad }" ;; esac
        v="${S6_FIG#* }"; v="${v%% *}"
        if s6_gt "$v" "$prev"; then rose=1; break; fi
        prev="$v"
      done
      s6_save s6-5-setup-later
      [ $rose = 1 ] || s6_why "the figure did not rise between reads 10 s apart ($first, then $prev)"
      [ "$S6_B1" -gt "$bytes_first" ] || s6_why "models/ did not grow while the figure was read ($bytes_first, then $S6_B1 bytes)"
    fi
  else
    s6_why "no progress figure to read: there is no setup window"
  fi
  s6_done S6.5 "with the mirror at 500,000 bytes a second the setup shows a progress figure within 3 MB of the bytes in models/ at the time of each read (last read: ${S6_VERDICT#ok }) and it rose from $first to $v over reads 10 s apart; the Next and Back clause is not checked in slice 1: the setup window is bare (guess G12)"
}
check_S6_5() { s6_run s6_check_5; }

# ---- S6.6: a model file that fails its check is deleted and fetched again --------------------------------

# s6_variant <label> <plant kind> <quit 0|1> : one planted text model file. The mirror is held at 2,000,000 bytes a
# second while the file is planted (after the app was quit, when quit is 1), so the message stays on screen for the
# 150 s the re-download takes; the setup must show the message within 15 s, the planted file must be gone from
# models/, and, once the mirror is at full rate again, the download must end with both files at their pinned size
# and SHA-256 and the mirror must have logged a new GET for the text model. Reasons go to S6_WHY; a person-step to
# S6_PERSON.
s6_variant() {
  local label="$1" kind="$2" quit="$3" before after planted out rc seen=0 t0 path="$S6_MODELS/$S6_TEXT"
  before="$(s6_gets "$S6_TEXT")"
  kq "$S6_MR" rate 2000000 >/dev/null 2>&1
  if [ "$quit" = 1 ]; then
    out="$(kq "$S6_LD" quit 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc != 0 ]; then s6_why "$label: kit-launch.sh quit exited $rc: $(s6_last "$out")"; return 1; fi
  fi
  planted="$(kq "$S6_FX" plant-model "$kind" 2>&1)"; rc=$?
  printf '%s\n' "$planted" | sed 's/^/  | /'
  if [ $rc != 0 ]; then s6_why "$label: kit-fixtures.sh plant-model $kind exited $rc: $(s6_last "$planted")"; return 1; fi
  if [ "$quit" = 1 ]; then
    out="$(kq "$S6_LD" start --mirror 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc != 0 ]; then s6_why "$label: the app could not be started after the file was planted: $(s6_last "$out")"; return 1; fi
  fi
  t0=$SECONDS
  while :; do
    s6_dump; rc=$?
    if [ $rc = 3 ]; then S6_PERSON="$S6_ERR"; return 3; fi
    S6_AT=$((SECONDS - t0))
    if [ $rc = 0 ] && s6_has "$S6_MSG"; then seen=1; break; fi
    [ "$S6_AT" -ge 15 ] && break
    sleep 1
  done
  s6_save "s6-6-$label"
  if [ $seen = 1 ] && [ "$S6_AT" -le 15 ]; then
    echo "  | $label: the setup showed the message after $S6_AT s"
  elif [ $seen = 1 ]; then
    s6_why "$label: the setup showed the message only after $S6_AT s, not within 15 s"
  elif [ -z "$S6_DUMP" ]; then
    s6_why "$label: no setup window to show \"$S6_MSG\" within 15 s ($S6_ERR)"
  else
    s6_why "$label: the setup window shows no \"$S6_MSG\" within 15 s"
  fi
  if [ -e "$path" ]; then
    s6_why "$label: the planted file is still in models/ ($S6_TEXT, $(stat -f %z "$path" 2>/dev/null) bytes after $S6_AT s)"
  fi
  kq "$S6_MR" rate max >/dev/null 2>&1
  if [ $seen = 1 ]; then
    if ! s6_wait_whole 600 30; then
      s6_why "$label: the model was not downloaded again: $S6_DL"
    else
      sleep 2
      s6_verify || s6_why "$label: after the download ended, $S6_VMSG"
    fi
    for rc in 1 2 3 4 5 6 7 8 9 10; do
      after="$(s6_gets "$S6_TEXT")"
      [ "$after" -gt "$before" ] && break
      sleep 1
    done
  else
    after="$(s6_gets "$S6_TEXT")"
  fi
  if [ "$after" -gt "$before" ]; then
    echo "  | $label: the mirror logged a new GET for $S6_TEXT ($before to $after)"
  else
    s6_why "$label: the mirror logged no new GET for $S6_TEXT after the file was planted (GETs before $before, after $after)"
  fi
  return 0
}

s6_check_6() {
  local rc k
  [ -n "$KIT_PLANT" ] && { S6_VPLANT=1; S6_PLANTED="the text model's pinned SHA-256 read with its first digit changed"; }
  s6_state S6.6 || return $S6_RC
  kq "$S6_MR" rate max >/dev/null 2>&1
  if ! s6_wait_bytes 20; then
    s6_why "nothing downloaded: models/ holds 0 bytes 20 s after the app started with the mirror at full rate, so the planted files meet no finished download"
  elif ! s6_wait_whole 600 30; then
    s6_why "the first download did not finish: $S6_DL"
  else
    sleep 3
    s6_verify && echo "  | the first download finished: both model files whole in models/" || s6_why "the first download is not the pinned one: $S6_VMSG"
  fi
  for k in "flipped flipped 0" "truncated truncated 0" "planted-while-quit flipped 1"; do
    set -- $k
    s6_variant "$1" "$2" "$3"; rc=$?
    [ $rc = 3 ] && break
  done
  s6_done S6.6 "a flipped file, a truncated file and a flipped file planted while the app was quit were each caught: the setup showed \"$S6_MSG\" within 15 s, the planted file was gone from models/, the mirror logged a new GET for $S6_TEXT and the file ended at its pinned size and SHA-256"
}
check_S6_6() { s6_run s6_check_6; }

# ---- S6.7: the network goes away, the bytes are kept, Retry finishes the download ------------------------

s6_check_7() {
  local rc haswin=0 poff p1 p2 parts name bytes seen=0 lbl st out t0 i
  [ -n "$KIT_PLANT" ] && { S6_SKEW=1; S6_PLANTED="the Range start expected one byte beyond the bytes kept"; }
  s6b_state S6.7 || return $S6_RC
  s6_wait_window 8; rc=$?
  case $rc in
    0) haswin=1 ;;
    3) echo "CHECK S6.7 NEEDS-A-PERSON $S6_ERR"; return 0 ;;
    *) s6_why "no setup window: $S6_ERR (8 s after the app started)" ;;
  esac
  if [ $haswin = 1 ]; then
    s6_wait_min 2000000 25 || s6_why "nothing downloaded: models/ holds $(s6_bytes) bytes 25 s after the app started with the mirror at 500,000 bytes a second"
  else
    s6_wait_bytes 15 || s6_why "nothing downloaded: models/ holds 0 bytes 15 s after the app started with the mirror at 500,000 bytes a second"
  fi
  poff="$(s6_bytes)"
  out="$(kq "$S6_MR" offline 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ $rc != 0 ]; then echo "RERUN S6.7 not valid: the mirror could not go offline: $(s6_last "$out")"; return 4; fi
  if [ $haswin = 1 ]; then
    # 1. within 90 s the setup says so
    t0=$SECONDS
    while :; do
      s6_dump; rc=$?
      if [ $rc = 3 ]; then echo "CHECK S6.7 NEEDS-A-PERSON $S6_ERR"; return 0; fi
      if [ $rc = 0 ] && s6_has_ci "$S6_ERRTEXT"; then seen=1; break; fi
      [ $((SECONDS - t0)) -ge 90 ] && break
      sleep 2
    done
    s6_save s6-7-offline
    if [ $seen = 0 ]; then
      s6_why "the setup shows no \"Could not download the model\" within 90 s of the mirror going offline"
    else
      echo "  | the setup showed the error after $((SECONDS - t0)) s"
      # 2. the bytes are kept: the same 30 s later, and not fewer than before the network went
      p1="$(s6_bytes)"; parts="$(s6_partials)"
      lbl="$(s6_retry_label)"
      if kq "$S6_AX" click "Next" >/dev/null 2>&1; then
        sleep 1
        s6_dump
        st="$(s6_start_read)"
        kq "$S6_AX" click "Back" >/dev/null 2>&1 || s6_why "pressing \"Back\" from the Folders step failed"
        sleep 1
      else
        st=unread
      fi
      echo "  | at the error: models/ holds $p1 bytes ($(printf '%s' "$parts" | tr '\n' ' ')), Retry label \"${lbl:-none}\", Start indexing $st"
      [ "$p1" -gt 0 ] || s6_why "no bytes were kept: models/ holds 0 bytes when the error shows"
      [ "$p1" -ge "$poff" ] || s6_why "bytes were thrown away: models/ held $poff bytes when the mirror went offline and $p1 when the error showed"
      [ -n "$lbl" ] || s6_why "the setup offers no Retry button (an AXButton labelled \"Try again\" or \"Retry\")"
      s6_start_failed_ok "$st" || s6_why "Start indexing reads \"$st\" on the Folders step while the model download has failed, not disabled or absent"
      sleep 30
      p2="$(s6_bytes)"
      [ "$p2" = "$p1" ] || s6_why "models/ held $p1 bytes when the error showed and $p2 bytes 30 s later"
    fi
  else
    s6_why "so no error text, no Retry button and no Start indexing control could be read"
  fi
  # 3. online, Retry, the download ends
  kq "$S6_MR" online >/dev/null 2>&1
  kq "$S6_MR" rate max >/dev/null 2>&1
  if [ $haswin = 1 ] && [ -n "$lbl" ]; then
    out="$(kq "$S6_AX" click "$lbl" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    [ $rc = 0 ] || s6_why "pressing \"$lbl\" failed: $(s6_last "$out")"
  fi
  if [ -n "$parts" ] || [ "$(s6_bytes)" -gt 0 ]; then
    if ! s6_wait_whole 600 30; then
      s6_why "the download did not finish after the mirror came back and Retry was pressed: $S6_DL"
    else
      sleep 2
      s6_verify || s6_why "after the download ended, $S6_VMSG"
      echo "  | the download finished: both model files whole in models/"
    fi
    # 4. the resumed request starts at the kept byte count
    while read -r name bytes; do
      [ -n "$name" ] || continue
      if s6_ranged "$name" "$((bytes + S6_SKEW))"; then
        echo "  | the mirror logged a GET for $name with a Range starting at $bytes, answered 206"
      else
        s6_get_lines "$name"
        s6_why "the mirror logged no GET for $name with a Range starting at the $bytes bytes kept (answered 206)"
      fi
    done <<EOF
$parts
EOF
    # 5. Start indexing becomes available
    for i in 1 2 3 4 5 6 7 8; do
      s6_dump; rc=$?
      if [ $rc = 0 ] && [ "$(s6_start_state)" = absent ] && ! s6_has "Add folder…"; then
        kq "$S6_AX" click "Next" >/dev/null 2>&1
        sleep 1
        s6_dump; rc=$?
      fi
      [ $rc = 0 ] && [ "$(s6_start_state)" = enabled ] && break
      sleep 2
    done
    [ $rc = 0 ] && [ "$(s6_start_state)" = enabled ] || s6_why "Start indexing is not available after the download finished ($( [ $rc = 0 ] && s6_start_state || echo "$S6_ERR"), $(s6_ticked_rows) ticked rows)"
    s6_save s6-7-online
  fi
  s6_done S6.7 "with the mirror offline the setup showed \"Could not download the model\" within 90 s, kept the $p1 bytes (the same 30 s later), offered \"$lbl\" and had Start indexing $st; after the mirror came back and \"$lbl\" was pressed the mirror logged a Range request starting at the kept bytes and answered 206, the download finished at the pinned size and SHA-256, and Start indexing became available"
}
check_S6_7() { s6_run s6_check_7; }

# ---- S6.12: the model is never downloaded again after a restart -----------------------------------------

s6_check_12() {
  local r0 r s0 s k out rc
  [ -n "$KIT_PLANT" ] && { S6_SKEW=1; S6_PLANTED="the expected request count read as one more than the mirror logged"; }
  s6_state S6.12 || return $S6_RC
  kq "$S6_MR" rate max >/dev/null 2>&1
  if ! s6_wait_bytes 20; then
    s6_why "nothing downloaded: models/ holds 0 bytes 20 s after the app started with the mirror at full rate, so there is no download to be never repeated"
  elif ! s6_wait_whole 600 30; then
    s6_why "the download did not finish: $S6_DL"
  else
    sleep 3
    s6_verify || s6_why "the download is not the pinned one: $S6_VMSG"
  fi
  r0="$(s6_reqs)"
  s0="$(s6_stats)"
  echo "  | after the first download: $r0 requests for the two model files"
  printf '%s\n' "$s0" | sed 's/^/  | /'
  for k in 1 2; do
    out="$(kq "$S6_LD" quit 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc != 0 ]; then s6_why "cycle $k: kit-launch.sh quit exited $rc: $(s6_last "$out")"; continue; fi
    out="$(kq "$S6_LD" relaunch 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/  | /'
    if [ $rc != 0 ]; then s6_why "cycle $k: kit-launch.sh relaunch exited $rc: $(s6_last "$out")"; continue; fi
    sleep 15      # the app hashes both files at launch (about a second) and would fetch again within seconds
    r="$(s6_reqs)"
    s="$(s6_stats)"
    echo "  | after relaunch $k: $r requests for the two model files"
    if [ "$r" != "$((r0 + S6_SKEW))" ]; then
      kq "$S6_MR" requests 2>/dev/null | tail -n 4 | sed 's/^/  | /'
      s6_why "cycle $k: the mirror has $r requests for the two model files after the relaunch, $r0 before"
    fi
    if [ "$s" != "$s0" ]; then
      printf '%s\n' "$s" | sed 's/^/  | /'
      s6_why "cycle $k: the inode or modified time of a model file changed (before: $(printf '%s' "$s0" | tr '\n' ',')  after: $(printf '%s' "$s" | tr '\n' ','))"
    fi
  done
  # From slice 2 (the Settings window and Delete index exist): an index is built, deleted and rebuilt (s6b_rebuild in
  # checks-s6b.sh), the app relaunched, and the count and the files are still the same.
  [ "${KIT_SLICE:-1}" -ge 2 ] && s6b_rebuild "$r0" "$s0"
  if [ "${KIT_SLICE:-1}" -ge 2 ]; then
    s6_done S6.12 "after the first download ($r0 requests for the two model files) two quit and relaunch cycles, then Delete index, Start indexing, the rebuilt index and a relaunch left the request count at $r0 and the inode and modified time of both model files unchanged"
  else
    s6_done S6.12 "after the first download ($r0 requests for the two model files) two quit and relaunch cycles left the request count at $r0 and the inode and modified time of both model files unchanged; the Delete index part runs from slice 2"
  fi
}
check_S6_12() { s6_run s6_check_12; }

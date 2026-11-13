#!/bin/bash
# The slice 5 checks S4.1 to S4.10, S2.5 and S8.8 (feature maps S4, S2 and S8: audio and video open at the moment; plan-5-tasks t1).
# Sourced by kit-run.sh after common.sh and recipes.sh (its checks-*.sh glob), never run. bash 3.2 compatible. Each check prints one
# `CHECK <id> PASS|FAIL|NEEDS-A-PERSON ...` line (a failure says why) and uses the exit codes of every kit script; a precondition that does
# not hold prints `RERUN <id> not valid: <reason>` and returns 4. With KIT_PLANT=1 (kit-run.sh --plant <id>) S4.2 asks waveform-check for a
# block 60 s away from the stated one (as if the pane had drawn another block) and prints `FAIL planted`; every other check has no plant of
# its own: the runner turns a PASS into `FAIL planted`.
#
# Where each starts: from the state of the recipe `golden` (recipes.sh: golden_need; the photos, the PDFs and documents, the boundary PDFs and
# golden-av picked and indexed to Ready; run/recipe says `golden`), never from kit-golden.sh prepare's photo-only state. The query, the file,
# the moment and the spoken sentence of every check come from the key (fixtures/answers.csv: audio-01..08, video-01, videospeech-01); the
# files are under $KIT_ROOT/fixtures/golden-av. S2.5 runs the panel run of group d first and the engine run last: the engine's `prepare --all`
# resets the kit, so the recipe mark is dropped after it and the next check makes its own state.
#
# S4.8 and S8.8 are the same measurement from two sides: an administrator session (looked for with `sudo -n true`, never asked for), the
# fs_usage network trace and nettop started before the ten audio selections, a plant before and one after them, then both read as S8.7 reads
# them (the fs_usage trace that misses a plant is RERUN, never a pass) and the speech daemon's own connections (kit-net.sh speech).
#
# The functions without a verb of their own (s4_secs, s4_opens_at, s4_span, s4_time_ok, s4_words_overlap, s4_words_ok, s4_field,
# s4_ten_queries, s4_unreadable, s4_changed_done) only read or print, run no kit script, and are tested on hand-written input by
# KitRunS4ChecksTests. Nothing here reads product source.

. "$KIT_LIB/golden.sh"
. "$KIT_LIB/checks-s3.sh"

S4_RB="$KIT_SCRIPTS/kit-readback.sh"
S4_AX="$KIT_SCRIPTS/kit-ax.sh"
S4_FX="$KIT_SCRIPTS/kit-fixtures.sh"
S4_INDEX="$KIT_SCRIPTS/kit-index.sh"
S4_NET="$KIT_SCRIPTS/kit-net.sh"
S4_TRACE="$KIT_SCRIPTS/kit-trace.sh"
S4_GOLDEN="$KIT_SCRIPTS/kit-golden.sh"
S4_WHY=""
S4_RANK=""
S4_LIST=""

# ---- pure readers (they print, they run no kit script) -------------------------------------------------------------

# s4_secs <mm:ss or h:mm:ss> : the seconds.
s4_secs() { awk -v t="$1" 'BEGIN { n = split(t, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]; print s }'; }

# s4_opens_at : stdin a pane's text; the seconds of the first `Opens at mm:ss` (or h:mm:ss), nothing when there is none.
s4_opens_at() {
  awk 'match($0, /Opens at [0-9]+:[0-9][0-9](:[0-9][0-9])?/) {
    t = substr($0, RSTART + 9, RLENGTH - 9); n = split(t, a, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + a[i]
    print s; exit
  }'
}

# s4_span : stdin a pane's text; `<start> <end>` in seconds of the first two times joined by a dash, an en dash, an em dash or `to`.
s4_span() {
  awk '
    function secs(t,    n, a, i, s) { n = split(t, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]; return s }
    match($0, /[0-9]+:[0-9][0-9][ ]*(–|—|-|to)[ ]*[0-9]+:[0-9][0-9]/) {
      m = substr($0, RSTART, RLENGTH)
      match(m, /[0-9]+:[0-9][0-9]/); a = substr(m, RSTART, RLENGTH); rest = substr(m, RSTART + RLENGTH)
      match(rest, /[0-9]+:[0-9][0-9]/); b = substr(rest, RSTART, RLENGTH)
      print secs(a), secs(b); exit
    }'
}

# s4_time_ok <stated seconds> <QuickTime's time> : status 0 when the time is within 2 s of the stated time, allowing up to 1.5 s of play
# between the open and the pause (stated minus 2 to stated plus 3.5).
s4_time_ok() { awk -v s="$1" -v t="$2" 'BEGIN { exit (t ~ /^[0-9]+(\.[0-9]+)?$/ && t + 0 >= s - 2 && t + 0 <= s + 3.5) ? 0 : 1 }'; }

# s4_words_overlap <spoken sentence> : stdin the pane's text; `<found> <total>`: the distinct words of the sentence, and how many of them the
# pane holds as whole words (case ignored).
s4_words_overlap() {
  awk -v note="$1" '
    { pane = pane " " tolower($0) }
    END {
      gsub(/[^a-z0-9]+/, " ", pane); pane = " " pane " "
      n = split(tolower(note), w, /[^a-z0-9]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] == "" || (w[i] in seen)) continue
        seen[w[i]] = 1; total++
        if (index(pane, " " w[i] " ")) found++
      }
      printf "%d %d\n", found, total
    }'
}

# s4_words_ok <found> <total> : status 0 when at least half of the spoken words are in the pane (never for no words).
s4_words_ok() { awk -v k="$1" -v n="$2" 'BEGIN { exit (n > 0 && 2 * k >= n) ? 0 : 1 }'; }

# s4_field <row id> <query|file|locator|window|note> : one field of a row of the key; nothing when the row or the field is not there.
s4_field() {
  awk -F, -v id="$1" -v f="$2" '
    NR > 1 && NF == 7 && $1 == id {
      if (f == "query") print $3
      else if (f == "file") print $4
      else if (f == "locator") print $5
      else if (f == "window") print $6
      else if (f == "note") print $7
      exit
    }' "$GOLDEN_ANSWERS"
}

# s4_ten_queries : `id TAB query TAB file TAB locator` of the ten audio selections of S4.8 and S8.8: the eight audio rows in key order, then
# the first two again.
s4_ten_queries() {
  awk -F, 'NR > 1 && NF == 7 && $2 == "audio" { r[++n] = $1 "\t" $3 "\t" $4 "\t" $5 }
    END { for (i = 1; i <= n; i++) print r[i]; for (i = 1; i <= 2 && i <= n; i++) print r[i] }' "$GOLDEN_ANSWERS"
}

# s4_unreadable : `path TAB reason` of the two damaged golden-av clips (made by the builder: random bytes and a cut mp4); the reason Settings
# and the index show is `damaged`.
s4_unreadable() { printf 'golden-av/damaged/broken.m4a\tdamaged\ngolden-av/damaged/broken.mp4\tdamaged\n'; }

# s4_changed_done : stdin `kit-index.sh diff`; the number of done files it says changed or went missing.
s4_changed_done() { awk -F'\t' '/^- / && $2 == "done" { n++ } END { print n + 0 }'; }

# ---- driving ---------------------------------------------------------------------------------------------------

# s4_row <check id> <row id> : S4_Q, S4_F, S4_LOC, S4_WIN, S4_NOTE and S4_PATH of a row of the key; else a RERUN line, S1_RC=4, status 1.
S4_Q=""; S4_F=""; S4_LOC=""; S4_WIN=""; S4_NOTE=""; S4_PATH=""
s4_row() {
  S4_Q="$(s4_field "$2" query)"; S4_F="$(s4_field "$2" file)"; S4_LOC="$(s4_field "$2" locator)"
  S4_WIN="$(s4_field "$2" window)"; S4_NOTE="$(s4_field "$2" note)"
  if [ -z "$S4_Q" ] || [ -z "$S4_F" ]; then echo "RERUN $1 not valid: fixtures/answers.csv holds no complete row $2"; S1_RC=4; return 1; fi
  S4_PATH="$KIT_ROOT/fixtures/golden-av/$S4_F"
  return 0
}

# s4_open_pane <id> <query> <file> : the search with the panel left open, the file in the first 3 rows, the pane of its row selected. S4_RANK is
# its place and S4_LIST the list of the first search (the rows). Status 0; else the CHECK or RERUN line is printed, S1_RC is set, status 1.
s4_open_pane() {
  local id="$1" q="$2" f="$3" rc
  s1_search "$q" --keep-open; rc=$?
  s1_search_ok "$id" $rc || return 1
  S4_LIST="$S1_OUT"
  S4_RANK="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  if [ -z "$S4_RANK" ]; then s1_fail "$id" "${f##*/} is not listed for \"$q\""; S1_RC=1; return 1; fi
  if ! [ "$S4_RANK" -le 3 ]; then s1_fail "$id" "${f##*/} is row $S4_RANK for \"$q\", expected one of the first 3"; S1_RC=1; return 1; fi
  if [ "$S4_RANK" -gt 1 ]; then s3_select_pane "$id" "$q" "$S4_RANK" || return 1; fi
  return 0
}

# ---- S4.1: describing something said lists the recording ---------------------------------------------------------

check_S4_1() { s1_run s4_check_1; }
s4_check_1() {
  local rc rank
  golden_need; s3_need S4.1 $? || return $S1_RC
  s4_row S4.1 audio-01 || return $S1_RC
  s1_search "$S4_Q"; rc=$?
  s1_search_ok S4.1 $rc || return $S1_RC
  s1_show
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$S4_F")"
  if [ -z "$rank" ]; then s1_fail S4.1 "${S4_F##*/} is not listed for \"$S4_Q\""; return 1; fi
  if ! [ "$rank" -le 3 ]; then s1_fail S4.1 "${S4_F##*/} is row $rank for \"$S4_Q\", expected one of the first 3"; return 1; fi
  echo "CHECK S4.1 PASS \"$S4_Q\" lists ${S4_F##*/} as row $rank of the first 3"
  return 0
}

# ---- S4.2: the pane shows the waveform, the window and its words, and Opens at mm:ss ---------------------------------------

check_S4_2() { s1_run s4_check_2; }
s4_check_2() {
  local sec lo hi span rc out shot start k n why="" words=""
  golden_need; s3_need S4.2 $? || return $S1_RC
  s4_row S4.2 audio-01 || return $S1_RC
  s4_open_pane S4.2 "$S4_Q" "$S4_F" || return $S1_RC
  s1_show
  lo="$(s4_secs "$S4_LOC")"; hi=$((lo + S4_WIN))
  sec="$(s1_pane | s4_opens_at)"
  if [ -z "$sec" ]; then why="the pane holds no \"Opens at mm:ss\""
  elif [ "$sec" -lt "$lo" ] || [ "$sec" -gt "$hi" ]; then why="the pane says Opens at $sec s, expected inside [$lo, $hi] s (the key's moment and its 30 s window)"; fi
  span="$(s1_pane | s4_span)"
  [ -n "$span" ] || why="${why:+$why; }the pane shows no span for the matched 30 s window"
  out="$(s1_kq "$S4_AX" shot s4-audio --panel 2>&1)"; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S4.2 NEEDS-A-PERSON $(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; return 0; fi
  if [ $rc != 0 ]; then echo "RERUN S4.2 not valid: kit-ax.sh shot s4-audio --panel exited $rc: $(s1_last "$out")"; return 4; fi
  shot="$(printf '%s\n' "$out" | sed -n 's/^saved \(.*\) (Sesame window [0-9]*)$/\1/p' | head -1)"
  [ -n "$shot" ] && [ -f "$shot" ] || { echo "RERUN S4.2 not valid: kit-ax.sh shot said no picture: $(s1_last "$out")"; return 4; }
  start="$lo"
  [ -n "$KIT_PLANT" ] && start=$((lo + 60))
  out="$(s1_kq "$S4_RB" waveform-check "$shot" "$S4_PATH" "$start" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | waveform-check: /'
  echo "  | the readings are in compare-s4-waveform.txt"
  case $rc in
    0) ;;
    4) echo "RERUN S4.2 not valid: waveform-check found no picture in the pane shot (never a pass): $(s1_last "$out")"; return 4 ;;
    *) why="${why:+$why; }waveform-check exited $rc: $(printf '%s\n' "$out" | awk '/^the drawn waveform|^the picture|^no waveform/ { print; exit }')" ;;
  esac
  if [ -n "$KIT_PLANT" ]; then
    echo "CHECK S4.2 FAIL planted: the drawn waveform was taken for the wrong block (the block at $start s instead of $lo s)${why:+ ($why)}${why:-, yet the check passed: it cannot go red}"
    return 1
  fi
  out="$(s1_kq "$S4_RB" speech-assets 2>&1)"; rc=$?
  if [ $rc = 0 ]; then
    set -- $(s1_pane | s4_words_overlap "$S4_NOTE"); k="$1"; n="$2"
    s4_words_ok "$k" "$n" || why="${why:+$why; }the pane holds $k of the $n spoken words of \"$S4_NOTE\", at least half are expected"
  elif [ $rc = 3 ]; then
    words=person
  else
    why="${why:+$why; }kit-readback.sh speech-assets exited $rc: $(s1_last "$out")"
  fi
  if [ -n "$why" ]; then s1_fail S4.2 "$why"; return 1; fi
  if [ -n "$words" ]; then
    echo "CHECK S4.2 NEEDS-A-PERSON the waveform is the block at $lo s and Opens at $sec s is inside [$lo, $hi], but the words need on-device speech recognition for the system language: $(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
    return 0
  fi
  echo "CHECK S4.2 PASS the pane says Opens at $sec s inside [$lo, $hi] s, shows the span $span, the drawn waveform is the block at $lo s and the pane holds $k of the $n spoken words"
  return 0
}

# ---- S4.3: describing something shown lists the video ------------------------------------------------------------------

check_S4_3() { s1_run s4_check_3; }
s4_check_3() {
  local rc rank
  golden_need; s3_need S4.3 $? || return $S1_RC
  s4_row S4.3 video-01 || return $S1_RC
  s1_search "$S4_Q"; rc=$?
  s1_search_ok S4.3 $rc || return $S1_RC
  s1_show
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$S4_F")"
  if [ -z "$rank" ]; then s1_fail S4.3 "${S4_F##*/} is not listed for \"$S4_Q\""; return 1; fi
  if ! [ "$rank" -le 3 ]; then s1_fail S4.3 "${S4_F##*/} is row $rank for \"$S4_Q\", expected one of the first 3"; return 1; fi
  echo "CHECK S4.3 PASS \"$S4_Q\" lists ${S4_F##*/} as row $rank of the first 3"
  return 0
}

# ---- S4.4: the pane shows the matching frame on a timeline, and Opens at mm:ss -------------------------------------------

check_S4_4() { s1_run s4_check_4; }
s4_check_4() {
  local sec lo hi rc out shot why="" at
  golden_need; s3_need S4.4 $? || return $S1_RC
  s4_row S4.4 video-01 || return $S1_RC
  s4_open_pane S4.4 "$S4_Q" "$S4_F" || return $S1_RC
  s1_show
  lo="$(s4_secs "$S4_LOC")"; hi=$((lo + S4_WIN))
  sec="$(s1_pane | s4_opens_at)"
  if [ -z "$sec" ]; then why="the pane holds no \"Opens at mm:ss\""
  elif [ "$sec" -lt "$lo" ] || [ "$sec" -gt "$hi" ]; then why="the pane says Opens at $sec s, expected inside [$lo, $hi] s (the key's moment and its 10 s window)"; fi
  out="$(s1_kq "$S4_AX" shot s4-video --panel 2>&1)"; rc=$?
  if [ $rc = 3 ]; then echo "CHECK S4.4 NEEDS-A-PERSON $(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; return 0; fi
  if [ $rc != 0 ]; then echo "RERUN S4.4 not valid: kit-ax.sh shot s4-video --panel exited $rc: $(s1_last "$out")"; return 4; fi
  shot="$(printf '%s\n' "$out" | sed -n 's/^saved \(.*\) (Sesame window [0-9]*)$/\1/p' | head -1)"
  [ -n "$shot" ] && [ -f "$shot" ] || { echo "RERUN S4.4 not valid: kit-ax.sh shot said no picture: $(s1_last "$out")"; return 4; }
  at=$((lo + 3))
  out="$(s1_kq "$S4_RB" frame-check "$shot" "$S4_PATH" "$at" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/  | frame-check: /'
  echo "  | the readings are in compare-s4-frame.txt"
  case $rc in
    0) ;;
    4) echo "RERUN S4.4 not valid: frame-check found no picture in the pane shot (never a pass): $(s1_last "$out")"; return 4 ;;
    *) why="${why:+$why; }frame-check exited $rc: $(printf '%s\n' "$out" | awk '/^the pane|^no frame|^cannot/ { print; exit }')" ;;
  esac
  if [ -n "$why" ]; then s1_fail S4.4 "$why"; return 1; fi
  echo "CHECK S4.4 PASS the pane says Opens at $sec s inside [$lo, $hi] and its picture is the builder's frame at $at s, closer than the frame 20 s earlier (the look goes to the person, S4.N1)"
  return 0
}

# ---- S4.5: Enter opens the file in QuickTime Player at that moment ----------------------------------------------------------

# s4_close_quicktime : closes QuickTime Player's documents (an Apple Event, only when it runs): a window left open from an earlier step would
# answer for the next one. Never quits it, never posts a key.
s4_close_quicktime() {
  osascript -e 'if application id "com.apple.QuickTimePlayerX" is running then tell application id "com.apple.QuickTimePlayerX" to close every document' >/dev/null 2>&1
  return 0
}

# s4_quicktime_open <id> <row id> : the row's search, the pane's stated time, QuickTime's documents closed, Enter, QuickTime Player in front with
# the file's name, its time read after it pauses. Status 0 it holds; 1 it does not (S4_WHY says why); 2 the CHECK or RERUN line is printed and
# S1_RC is set; 3 scripting is refused (S4_WHY holds the line).
S4_SEC=""; S4_TIME=""
s4_quicktime_open() {
  local id="$1" row="$2" rc out i title
  S4_WHY=""
  s4_row "$id" "$row" || return 2
  s4_open_pane "$id" "$S4_Q" "$S4_F" || return 2
  S4_SEC="$(s1_pane | s4_opens_at)"
  if [ -z "$S4_SEC" ]; then S4_WHY="${S4_F##*/}: the pane holds no \"Opens at mm:ss\""; return 1; fi
  s4_close_quicktime
  if [ "$S4_RANK" -gt 1 ]; then s1_search "$S4_Q" --select "$S4_RANK" --open; rc=$?; else s1_search "$S4_Q" --open; rc=$?; fi
  s1_search_ok "$id" $rc || return 2
  if ! s1_wait_front "QuickTime Player" 20; then S4_WHY="${S4_F##*/}: Enter did not put QuickTime Player in front (the front app is $(printf '%s\n' "$READBACK" | sed -n 1p))"; return 1; fi
  for i in 1 2 3 4 5 6 7 8; do
    title="$(printf '%s\n' "$READBACK" | sed -n 2p)"
    s3_title_holds "$title" "${S4_F##*/}" && break
    sleep 1
    READBACK="$(s1_rbp "System Events" frontmost)"
  done
  s3_title_holds "$title" "${S4_F##*/}" || { S4_WHY="QuickTime Player's front window is \"$title\", expected it to hold ${S4_F##*/}"; return 1; }
  out="$(s1_kq "$S4_RB" quicktime-time 2>&1)"; rc=$?
  if [ $rc = 3 ]; then S4_WHY="$(printf '%s\n' "$out" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"; return 3; fi
  if [ $rc != 0 ]; then S4_WHY="${S4_F##*/}: kit-readback.sh quicktime-time exited $rc: $(s1_last "$out")"; return 1; fi
  S4_TIME="$(printf '%s\n' "$out" | sed -n 's/^time //p' | head -1)"
  if ! s4_time_ok "$S4_SEC" "$S4_TIME"; then S4_WHY="${S4_F##*/}: QuickTime Player is at $S4_TIME s, the pane said Opens at $S4_SEC s (within 2 s, with 1.5 s of play allowed)"; return 1; fi
  return 0
}

check_S4_5() { s1_run s4_check_5; }
s4_check_5() {
  local row rc why="" done=""
  golden_need; s3_need S4.5 $? || return $S1_RC
  for row in audio-01 video-01; do
    s4_quicktime_open S4.5 "$row"; rc=$?
    case $rc in
      0) done="$done$S4_F at $S4_TIME s for $S4_SEC s; " ;;
      1) why="${why:+$why; }$S4_WHY" ;;
      3) echo "CHECK S4.5 NEEDS-A-PERSON $S4_WHY"; return 0 ;;
      *) return $S1_RC ;;
    esac
  done
  if [ -n "$why" ]; then s1_fail S4.5 "$why"; return 1; fi
  echo "CHECK S4.5 PASS Enter opened each file in QuickTime Player with its name in the window: ${done}each time was within 2 s of the pane's stated time"
  return 0
}

# ---- S4.6: the Audio and Video switches --------------------------------------------------------------------------------

# s4_switch <label> : presses the switch of Settings, File types (the Audio or the Video switch); status 0 pressed.
s4_switch() {
  local label="$1"
  s1_kq "$S4_AX" click "$label" >/dev/null 2>&1
}

check_S4_6() { s1_run s4_check_6; }
s4_check_6() {
  local aq af vq vf apath vpath rc t0 why="" diff lost new
  golden_need; s3_need S4.6 $? || return $S1_RC
  s4_row S4.6 audio-01 || return $S1_RC
  aq="$S4_Q"; af="$S4_F"; apath="$S4_PATH"
  s4_row S4.6 video-01 || return $S1_RC
  vq="$S4_Q"; vf="$S4_F"; vpath="$S4_PATH"
  s8c_settings_open; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S4.6 NEEDS-A-PERSON the Settings window needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S4.6 not valid: the Settings window could not be opened"; return 4 ;;
  esac
  settings_section "File types" >/dev/null 2>&1 || { echo "RERUN S4.6 not valid: the Settings window cannot be put on its File types section"; return 4; }
  s1_kq "$S4_INDEX" snapshot s4-before --files-only >/dev/null 2>&1
  # Audio off: the audio row is gone and the video row stays, with nothing read
  s4_switch Audio || { echo "RERUN S4.6 not valid: no switch named Audio in File types"; return 4; }
  t0=$SECONDS
  s1_search "$aq" --expect-absent "$apath"; rc=$?
  s1_search_ok S4.6 $rc || return $S1_RC
  echo "  | Audio off: the audio row was absent $((SECONDS - t0)) s after the switch"
  s1_search "$vq"; rc=$?
  s1_search_ok S4.6 $rc || return $S1_RC
  printf '%s\n' "$S1_OUT" | s3_rank_of "$vf" | grep -q . || why="Audio off: ${vf##*/} is no longer listed for \"$vq\" (only Audio was switched off)"
  # a new audio file added while Audio is off is not read: absent from the index 60 s later
  new="$KIT_ROOT/fixtures/golden-av/audio/zq-s4-new-clip.m4a"
  s1_kq "$S4_FX" mutate create "$new" "not an audio recording" >/dev/null 2>&1 || { echo "RERUN S4.6 not valid: kit-fixtures.sh mutate create could not add the file"; return 4; }
  sleep 60
  if s1_kq "$S4_INDEX" has "$new" >/dev/null 2>&1; then why="${why:+$why; }a new audio file added while Audio was off is in the index 60 s later"; fi
  s1_kq "$S4_FX" restore >/dev/null 2>&1
  # Audio on again: the row returns within 2 s
  s4_switch Audio
  s1_search "$aq" --wait-for "$apath" --within 2; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }Audio back on: ${af##*/} is not listed again within 2 s (kit-search.sh exited $rc)"
  # Video off: the video row is gone and the audio row stays
  s4_switch Video
  s1_search "$vq" --expect-absent "$vpath"; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }Video off: ${vf##*/} is still listed for \"$vq\""
  s1_search "$aq"; rc=$?
  s1_search_ok S4.6 $rc || return $S1_RC
  printf '%s\n' "$S1_OUT" | s3_rank_of "$af" | grep -q . || why="${why:+$why; }Video off: ${af##*/} is no longer listed (only Video was switched off)"
  # both off: neither is listed
  s4_switch Audio
  s1_search "$aq" --expect-absent "$apath"; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }both off: ${af##*/} is still listed"
  s1_search "$vq" --expect-absent "$vpath"; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }both off: ${vf##*/} is still listed"
  # both back on: both return within 2 s
  s4_switch Audio; s4_switch Video
  s1_search "$aq" --wait-for "$apath" --within 2; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }both back on: ${af##*/} is not listed within 2 s"
  s1_search "$vq" --wait-for "$vpath" --within 2; rc=$?
  [ $rc = 0 ] || why="${why:+$why; }both back on: ${vf##*/} is not listed within 2 s"
  # hiding is not re-indexing: no file that was done was read again
  s1_kq "$S4_INDEX" snapshot s4-after --files-only >/dev/null 2>&1
  diff="$(s1_kq "$S4_INDEX" diff s4-before s4-after 2>&1)"
  lost="$(printf '%s\n' "$diff" | s4_changed_done)"
  [ "$lost" = 0 ] || why="${why:+$why; }$lost done files were changed or read again by the switches (kit-index.sh diff s4-before s4-after)"
  if [ -n "$why" ]; then s1_fail S4.6 "$why"; return 1; fi
  echo "CHECK S4.6 PASS Audio off hid the audio row and left the video, Video off hid the video, both off hid both, each back on listed them within 2 s, nothing was re-read, and an audio file added while Audio was off was not in the index after 60 s"
  return 0
}

# ---- S4.7: a media app that is not installed ------------------------------------------------------------------------------

# s4_pick_media_app <label>... : puts the media app choice of Settings on the first label that a section of Settings has; the same drive as the
# PDF app choice of S3.9 (the names follow mockup F3, a guess K20). Status 0, 1 none found, 3 the Settings window needs a person.
s4_pick_media_app() { s3_choose_pdf_app "$@"; }

# s4_media_open <id> <query> <file> <default app> : Enter on the audio result; status 0 and READBACK holds the front app when the front app is the
# default app of m4a; else one line in S3_WHY.
s4_media_open() {
  local id="$1" q="$2" f="$3" want="$4" rc rank
  s1_search "$q"; rc=$?
  s1_search_ok "$id" $rc || return 2
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$f")"
  [ -n "$rank" ] || { S3_WHY="${f##*/} is not listed for \"$q\""; return 1; }
  if [ "$rank" -gt 1 ]; then s1_search "$q" --select "$rank" --open; rc=$?; else s1_search "$q" --open; rc=$?; fi
  s1_search_ok "$id" $rc || return 2
  s1_wait_front "$want" 25
  s3_app_matches "$(printf '%s\n' "$READBACK" | sed -n 1p)" "$want" || { S3_WHY="after Enter the front app is \"$(printf '%s\n' "$READBACK" | sed -n 1p)\", Launch Services names \"$want\" for m4a"; return 1; }
  return 0
}

check_S4_7() { s1_run s4_check_7; }
s4_check_7() {
  local iina vlc absent_label="" absent_name="" present_label="" present_name="" dm4a rc dump a="" b="" why="" note=""
  golden_need; s3_need S4.7 $? || return $S1_RC
  s4_row S4.7 audio-01 || return $S1_RC
  s1_kq "$S4_RB" app-installed com.colliderli.iina >/dev/null 2>&1 && iina=1 || iina=0
  s1_kq "$S4_RB" app-installed org.videolan.vlc >/dev/null 2>&1 && vlc=1 || vlc=0
  if [ $iina = 0 ]; then absent_label="IINA"; absent_name="IINA"; else present_label="IINA"; present_name="IINA"; fi
  if [ $vlc = 0 ] && [ -z "$absent_label" ]; then absent_label="VLC"; absent_name="VLC"; fi
  if [ $vlc = 1 ] && [ -z "$present_label" ]; then present_label="VLC"; present_name="VLC"; fi
  dm4a="$(s1_kq "$S4_RB" default-app m4a 2>&1)" || { echo "RERUN S4.7 not valid: no default app is named for m4a ($dm4a)"; return 4; }
  # (a) a listed app that is not installed: Settings says so, Enter opens the default m4a app
  if [ -z "$absent_label" ]; then
    a=person
    note="both IINA and VLC are installed, so no listed app is absent"
  else
    s4_pick_media_app "$absent_label" "$absent_name"; rc=$?
    case $rc in
      0) dump="$(s1_kq "$S4_AX" dump settings 2>&1)"
         case "$(printf '%s' "$dump" | tr 'A-Z' 'a-z')" in
           *"not installed"*) ;;
           *) why="${why:+$why; }(a) Settings shows no \"not installed\" message after $absent_name was chosen" ;;
         esac
         if s4_media_open S4.7 "$S4_Q" "$S4_F" "$dm4a"; then a=pass; else rc=$?; [ $rc = 2 ] && return $S1_RC; a=fail; why="${why:+$why; }(a) $S3_WHY"; fi ;;
      3) a=person; note="the Settings window needs a person" ;;
      *) a=person; note="the media app choice of Settings could not be driven (no control named $absent_label in any section)" ;;
    esac
  fi
  # (b) an installed listed app other than QuickTime Player: no message, and Enter still opens the default m4a app
  if [ -z "$present_label" ]; then
    echo "S4.7 (b) NOT RUN: no listed media app other than QuickTime Player is installed"
    b=notrun
  else
    s4_pick_media_app "$present_label" "$present_name"; rc=$?
    case $rc in
      0) dump="$(s1_kq "$S4_AX" dump settings 2>&1)"
         case "$(printf '%s' "$dump" | tr 'A-Z' 'a-z')" in
           *"not installed"*) why="${why:+$why; }(b) Settings shows a \"not installed\" message for the installed $present_name" ;;
         esac
         if s4_media_open S4.7 "$S4_Q" "$S4_F" "$dm4a"; then
           b=pass
           if ! s3_app_matches "$present_name" "$dm4a" && s3_app_matches "$(printf '%s\n' "$READBACK" | sed -n 1p)" "$present_name"; then
             b=fail; why="${why:+$why; }(b) the chosen app $present_name is frontmost although the default m4a app is $dm4a"
           fi
         else rc=$?; [ $rc = 2 ] && return $S1_RC; b=fail; why="${why:+$why; }(b) $S3_WHY"; fi ;;
      3) b=person; note="${note:+$note; }the Settings window needs a person" ;;
      *) b=person; note="${note:+$note; }the media app choice of Settings could not be driven for $present_name" ;;
    esac
  fi
  # the choice goes back to QuickTime Player, so the next check starts from the default
  s4_pick_media_app "QuickTime Player" >/dev/null 2>&1
  if [ -n "$why" ] || [ "$a" = fail ] || [ "$b" = fail ]; then s1_fail S4.7 "${why:-a part failed}"; return 1; fi
  if [ "$a" = person ] || [ "$b" = person ]; then
    echo "CHECK S4.7 NEEDS-A-PERSON ${note:-a part needs a person}: (a) is $a, (b) is $b"
    return 0
  fi
  echo "CHECK S4.7 PASS (a) with ${absent_name:-no app} chosen Settings says it is not installed and Enter opened $dm4a, the default m4a app; (b) $b${present_name:+ with $present_name chosen}"
  return 0
}

# ---- S4.8 and S8.8: the spoken-words preview and the speech daemon send nothing -----------------------------------------------

# s4_stop_observers <name> : both observers stopped (on a path that gives up early); never an error.
s4_stop_observers() {
  s1_kq "$S4_NET" stop "$1" >/dev/null 2>&1
  s1_kq "$S4_TRACE" stop "$1" >/dev/null 2>&1
  return 0
}

# s4_speech_run <id> <name> : the observers named <name> around ten audio selections, read as S8.7 reads them and with the speech daemon's own
# connections. Prints the CHECK or RERUN line and returns the check's status.
s4_speech_run() {
  local id="$1" name="$2" qid q f loc rc out n=0 sout src tout trc dests status spout sprc why="" seen
  out="$(s1_kq "$S4_TRACE" start "$name" --net 2>&1)"; rc=$?
  if [ $rc != 0 ]; then echo "RERUN $id not valid: kit-trace.sh start $name --net exited $rc: $(s1_last "$out")"; return 4; fi
  out="$(s1_kq "$S4_NET" start "$name" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then s4_stop_observers "$name"; echo "RERUN $id not valid: kit-net.sh start $name exited $rc: $(s1_last "$out")"; return 4; fi
  out="$(s1_kq "$S4_NET" control "$name" 2>&1)"; rc=$?
  [ $rc = 0 ] || { s4_stop_observers "$name"; echo "RERUN $id not valid: the first plant (kit-net.sh control $name) exited $rc: $(s1_last "$out")"; return 4; }
  while IFS=$'\t' read -r qid q f loc <&3; do
    [ -n "$qid" ] || continue
    n=$((n + 1))
    s4_open_pane "$id" "$q" "$f"; rc=$?
    if [ $rc != 0 ]; then s4_stop_observers "$name"; return $S1_RC; fi
    sleep 3
  done 3<<EOF
$(s4_ten_queries)
EOF
  out="$(s1_kq "$S4_NET" control "$name" 2>&1)"; rc=$?
  [ $rc = 0 ] || why="the second plant (kit-net.sh control $name) exited $rc"
  s1_kq "$S4_NET" stop "$name" >/dev/null 2>&1
  s1_kq "$S4_TRACE" stop "$name" >/dev/null 2>&1
  spout="$(s1_kq "$S4_NET" speech "$name" 2>&1 </dev/null)"; sprc=$?
  printf '%s\n' "$spout" | sed 's/^/  | speech: /'
  sout="$(s1_kq "$S4_NET" summary "$name" 2>&1 </dev/null)"; src=$?
  tout="$(s1_kq "$S4_TRACE" net "$name" 2>&1 </dev/null)"; trc=$?
  printf '%s\n' "$sout" | sed 's/^/  | summary: /'
  printf '%s\n' "$tout" | sed 's/^/  | trace: /'
  dests="$(printf '%s\n' "$tout" | s8d_destinations)"
  s8d_net_status "$src" "$trc" "$dests"; status=$?
  seen="$(printf '%s\n' "$sout" | awk '$1 == "PLANT" && $3 == "seen-by" { printf "%s:%s ", $2, $4 }')"
  if [ $status = 4 ]; then
    echo "RERUN $id not valid: the fs_usage trace missed a plant or dropped events, or an input is missing (kit-net.sh summary exit $src, kit-trace.sh net exit $trc): $(printf '%s\n' "$sout" | awk '/^NOT VALID|^not valid/ { print; exit }')"
    return 4
  fi
  [ $status = 0 ] || why="${why:+$why; }a connection from a Sesame process: $(printf '%s\n' "$sout$tout" | s8d_failure_lines | head -5 | tr '\n' ';')"
  [ "$sprc" != 1 ] || why="${why:+$why; }the speech daemon connected to a non-local host: $(printf '%s\n' "$spout" | awk '$1 == "SPEECH" && $NF == "REMOTE"' | head -3 | tr '\n' ';')"
  [ "$sprc" != 4 ] || { echo "RERUN $id not valid: kit-net.sh speech $name found no connection log"; return 4; }
  if [ -n "$why" ]; then s1_fail "$id" "$why"; return 1; fi
  if [ "$sprc" = 3 ]; then
    echo "CHECK $id NEEDS-A-PERSON cannot attribute: the speech daemon's connections are not in the nettop log of this run (design U7); no Sesame process made a connection, and the plants were seen by ${seen:-none}"
    return 0
  fi
  echo "CHECK $id PASS across $n audio selections neither observer showed a connection from a Sesame process and the speech daemon made none to a non-local host; both plants were seen (${seen})"
  return 0
}

check_S4_8() { s1_run s4_check_8; }
s4_check_8() {
  sudo -n true 2>/dev/null || { echo "CHECK S4.8 NEEDS-A-PERSON administrator rights: macOS only lets an administrator watch which connections Sesame makes; ask for them once from a Terminal window you can type in (the kit's permissions script), then run this check again"; return 0; }
  golden_need; s3_need S4.8 $? || return $S1_RC
  s4_speech_run S4.8 s4-speech
  return $?
}

check_S8_8() { s1_run s4_check_s8_8; }
s4_check_s8_8() {
  sudo -n true 2>/dev/null || { echo "CHECK S8.8 NEEDS-A-PERSON administrator rights: macOS only lets an administrator watch which connections Sesame makes; ask for them once from a Terminal window you can type in (the kit's permissions script), then run this check again"; return 0; }
  golden_need; s3_need S8.8 $? || return $S1_RC
  s4_speech_run S8.8 s8-speech
  return $?
}

# ---- S4.9: a damaged audio or video file is listed as could not read --------------------------------------------------------

check_S4_9() { s1_run s4_check_9; }
s4_check_9() {
  local path reason name rc out settings="" sec reasons rows names="" bad why=""
  golden_need; s3_need S4.9 $? || return $S1_RC
  rows="$(s4_unreadable)"
  s8c_settings_open; rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK S4.9 NEEDS-A-PERSON the Settings window needs a person (see the lines above)"; return 0 ;;
    *) echo "RERUN S4.9 not valid: the Settings window could not be read"; return 4 ;;
  esac
  for sec in Folders "File types" Search Indexing; do
    out="$(s8c_section_dump "$sec")" || { echo "RERUN S4.9 not valid: the Settings section $sec could not be read: $(printf '%s\n' "$out" | tail -1)"; return 4; }
    settings="$settings$out"$'\n'
  done
  reasons="$(s1_kq "$S4_INDEX" reasons 2>&1)"
  while IFS=$'\t' read -r path reason <&3; do
    [ -n "$path" ] || continue
    name="${path##*/}"
    names="$names $name"
    printf '%s\n' "$settings" | s3_in_dump "$name" "$reason" || why="${why:+$why; }Settings does not list $name with the reason \"$reason\""
    printf '%s\n' "$reasons" | s3_reasons_hold "$name" "$reason" || why="${why:+$why; }kit-index.sh reasons does not hold $name with the reason \"$reason\""
  done 3<<EOF
$rows
EOF
  bad="$(s1_kq "$S4_INDEX" under golden-av 2>&1 | s3_not_done $names)"
  [ -z "$bad" ] || why="${why:+$why; }files of golden-av that are not done: $(printf '%s' "$bad" | tr '\t\n' ' ;')"
  if [ -n "$why" ]; then s1_fail S4.9 "$why"; return 1; fi
  echo "CHECK S4.9 PASS Settings and the index list the damaged clips (broken.m4a, broken.mp4) as damaged and every other file of golden-av is done"
  return 0
}

# ---- S4.10: a video is found by the words spoken in its soundtrack ----------------------------------------------------------

check_S4_10() { s1_run s4_check_10; }
s4_check_10() {
  local lo hi sec r12 rc rank why="" v12="video/clip-v12.mp4" other="a red double decker bus on a snowy street"
  golden_need; s3_need S4.10 $? || return $S1_RC
  s4_row S4.10 videospeech-01 || return $S1_RC
  s4_open_pane S4.10 "$S4_Q" "$S4_F" || return $S1_RC
  s1_show
  lo="$(s4_secs "$S4_LOC")"; hi=$((lo + S4_WIN))
  sec="$(s1_pane | s4_opens_at)"
  if [ -z "$sec" ]; then why="the pane holds no \"Opens at mm:ss\""
  elif [ "$sec" -lt "$lo" ] || [ "$sec" -gt "$hi" ]; then why="the pane says Opens at $sec s, expected inside [$lo, $hi] s"; fi
  # control: the same frames with a silent soundtrack are not above the clip that is spoken in
  r12="$(printf '%s\n' "$S4_LIST" | s3_rank_of "$v12")"
  if [ -n "$r12" ] && [ "$r12" -lt "$S4_RANK" ]; then why="${why:+$why; }${v12##*/} (row $r12) is above ${S4_F##*/} (row $S4_RANK) for \"$S4_Q\": the find did not come from the soundtrack"; fi
  # control: a query that names a picture the frames do not hold does not list the clip in the first 3
  s1_search "$other"; rc=$?
  s1_search_ok S4.10 $rc || return $S1_RC
  rank="$(printf '%s\n' "$S1_OUT" | s3_rank_of "$S4_F")"
  if [ -n "$rank" ] && [ "$rank" -le 3 ]; then why="${why:+$why; }\"$other\", a picture the frames do not hold, lists ${S4_F##*/} as row $rank: the clip is answered by something other than its soundtrack"; fi
  if [ -n "$why" ]; then s1_fail S4.10 "$why"; return 1; fi
  echo "CHECK S4.10 PASS \"$S4_Q\" lists ${S4_F##*/} as row $S4_RANK of the first 3 with Opens at $sec s inside [$lo, $hi]; ${v12##*/} is not above it${r12:+ (row $r12)} and \"$other\" does not list it in the first 3"
  return 0
}

# ---- S2.5: audio and video found by describing them, at the right moment ----------------------------------------------------

check_S2_5() { s1_run s4_check_s2_5; }
s4_check_s2_5() {
  local out_e out_p rc_e rc_p dir tsv_p tsv_e line_p line_e
  golden_need; s3_need S2.5 $? || return $S1_RC
  out_p="$(kq "$S4_GOLDEN" panel --group d 2>&1)"; rc_p=$?
  printf '%s\n' "$out_p" | sed 's/^/  | panel: /'
  out_e="$(kq "$S4_GOLDEN" engine --group d 2>&1)"; rc_e=$?
  printf '%s\n' "$out_e" | sed 's/^/  | engine: /'
  rm -f "$KIT_ROOT/run/recipe"
  if [ $rc_p = 3 ] || [ $rc_e = 3 ]; then
    echo "CHECK S2.5 NEEDS-A-PERSON $(printf '%s\n%s\n' "$out_p" "$out_e" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
    return 0
  fi
  if [ $rc_p = 4 ]; then echo "RERUN S2.5 not valid: the panel run of group d was not valid: $(s1_last "$out_p")"; return 4; fi
  if [ $rc_e = 4 ]; then echo "RERUN S2.5 not valid: the engine run of group d was not valid: $(s1_last "$out_e")"; return 4; fi
  dir="$(golden_dir)"
  tsv_p="$dir/golden-panel.tsv"; tsv_e="$dir/golden-engine.tsv"
  if [ ! -f "$tsv_p" ] || [ ! -f "$tsv_e" ]; then
    echo "CHECK S2.5 FAIL no reading: $([ -f "$tsv_p" ] || printf 'golden-panel.tsv ')$([ -f "$tsv_e" ] || printf 'golden-engine.tsv ')was not written"
    return 1
  fi
  line_p="$(printf '%s\n' "$out_p" | awk '/^GOLDEN [a-z]+ group d: / { l = $0 } END { print l }')"
  line_e="$(printf '%s\n' "$out_e" | awk '/^GOLDEN [a-z]+ group d: / { l = $0 } END { print l }')"
  if [ $rc_p = 0 ] && [ $rc_e = 0 ] && case "$line_p$line_e" in *": PASS"*": PASS") true ;; *) false ;; esac; then
    echo "CHECK S2.5 PASS ${line_p#GOLDEN } | ${line_e#GOLDEN }"
    return 0
  fi
  echo "CHECK S2.5 FAIL panel (exit $rc_p): ${line_p#GOLDEN }; engine (exit $rc_e): ${line_e#GOLDEN }"
  return 1
}

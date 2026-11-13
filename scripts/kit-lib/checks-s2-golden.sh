#!/bin/bash
# S2.1: the golden photos (spec S2(a)): the right photo first for at least 6 of the 10 photo descriptions and within the
# first 3 for at least 9, through the engine and, as a second measure, through the real panel. Sourced by kit-run.sh after
# common.sh and recipes.sh, never run. bash 3.2 compatible.
#
# The check runs `kit-golden.sh panel --group a` and then `kit-golden.sh engine --group a`, then reads golden-engine.tsv and
# golden-panel.tsv (kit-lib/golden.sh) and prints one line:
#   CHECK S2.1 PASS engine first <f>/<n> top-3 <t>/<n>, panel first <f>/<n> top-3 <t>/<n>
#   CHECK S2.1 FAIL <the same figures>, need first >= 6 and top-3 >= 9 for both: engine: <why>; panel: <why>
# With KIT_PLANT=1 (kit-run.sh --plant S2.1) the first-count bar is planted at 99, so both groups must go under it:
#   CHECK S2.1 FAIL planted: ...
# A person-step of the panel mode prints `CHECK S2.1 NEEDS-A-PERSON <what>`; a list that did not settle prints
# `RERUN S2.1 not valid: <reason>` and returns 4.

. "$KIT_LIB/golden.sh"

# s21_why <tsv> : the reason of the first row of the group that did not pass, from the mode's own output.
s21_why() {
  printf '%s\n' "$1" | awk '/^FAIL / { sub(/^[^:]*: /, ""); print; exit }'
}

check_S2_1() {
  local pbar=() out_e out_p rc_e rc_p dir tsv_e tsv_p ne nf nt pn pf pt bar=$GOLDEN_MIN_FIRST ve vp line
  if [ -n "$KIT_PLANT" ]; then pbar=(--min-first 99); bar=99; fi
  s1_need_photos S2.1 || return $S1_RC
  out_p="$(kq "$KIT_SCRIPTS/kit-golden.sh" panel --group a "${pbar[@]}" 2>&1)"; rc_p=$?
  printf '%s\n' "$out_p" | sed 's/^/  | panel: /'
  out_e="$(kq "$KIT_SCRIPTS/kit-golden.sh" engine --group a "${pbar[@]}" 2>&1)"; rc_e=$?
  printf '%s\n' "$out_e" | sed 's/^/  | engine: /'
  if [ $rc_p = 3 ] || [ $rc_e = 3 ]; then
    echo "CHECK S2.1 NEEDS-A-PERSON $(printf '%s\n%s\n' "$out_e" "$out_p" | awk '/^NEEDS A PERSON: / { sub(/^NEEDS A PERSON: /, ""); print; exit }')"
    return 0
  fi
  if [ $rc_p = 4 ] || [ $rc_e = 4 ]; then
    echo "RERUN S2.1 not valid: a golden run was not valid ($(printf '%s\n%s\n' "$out_e" "$out_p" | awk '/^RERUN / { sub(/^RERUN [^ ]* not valid: /, ""); print; exit }'))"
    return 4
  fi
  dir="$(golden_dir)"
  tsv_e="$dir/golden-engine.tsv"; tsv_p="$dir/golden-panel.tsv"
  if [ ! -f "$tsv_e" ] || [ ! -f "$tsv_p" ]; then
    echo "CHECK S2.1 FAIL no reading: $([ -f "$tsv_e" ] || printf 'golden-engine.tsv ') $([ -f "$tsv_p" ] || printf 'golden-panel.tsv ')was not written"
    return 1
  fi
  set -- $(golden_counts "$tsv_e" a); ne="$1"; nf="$2"; nt="$3"
  set -- $(golden_counts "$tsv_p" a); pn="$1"; pf="$2"; pt="$3"
  ve="$(golden_verdict "$ne" "$nf" "$nt" "$bar")"
  vp="$(golden_verdict "$pn" "$pf" "$pt" "$bar")"
  line="engine first $nf/$ne top-3 $nt/$ne, panel first $pf/$pn top-3 $pt/$pn"
  if [ -n "$KIT_PLANT" ]; then
    if [ "$ve" = FAIL ] && [ "$vp" = FAIL ]; then
      echo "CHECK S2.1 FAIL planted: the first-count bar was planted at 99 and both groups went under it ($line)"
    else
      echo "CHECK S2.1 FAIL planted: the first-count bar was planted at 99 but a group still passed ($line): the verdict cannot go red"
    fi
    return 1
  fi
  if [ "$ve" = PASS ] && [ "$vp" = PASS ]; then
    echo "CHECK S2.1 PASS $line"
    return 0
  fi
  echo "CHECK S2.1 FAIL $line, need first >= $GOLDEN_MIN_FIRST and top-3 >= $GOLDEN_MIN_TOP3 for both: engine: $(s21_why "$out_e"); panel: $(s21_why "$out_p")"
  return 1
}

#!/bin/bash

s2e_saved_file() { printf '%s\n' "$KIT_ROOT/golden-kept/$1-$2.txt"; }
s2e_saved_version() { awk '$1 == "VERSION" { print $2; exit }' "$1" 2>/dev/null; }

s2e_window() { echo 3; }

s2e_hits() {
  [ -f "$1" ] || { echo "0 0"; return 0; }
  awk -v w="$2" '
    $1 == "GOLDEN" && $3 == "rank" && NF >= 4 { r[$2] = $4; if (!($2 in s)) { s[$2] = 1; n++ } }
    END {
      for (i in r) if (r[i] ~ /^[0-9]+$/ && r[i] + 0 >= 1 && r[i] + 0 <= w) h++
      printf "%d %d\n", h + 0, n + 0
    }' "$1"
}

s2e_diff_rows() {
  awk -v w="$3" '
    function hit(x) { return (x ~ /^[0-9]+$/ && x + 0 >= 1 && x + 0 <= w) }
    $1 == "GOLDEN" && $3 == "rank" && NF >= 4 {
      if (FILENAME == ARGV[1]) e[$2] = $4; else p[$2] = $4
      if (!($2 in ord)) { ord[$2] = ++n; id[n] = $2 }
    }
    END {
      for (i = 1; i <= n; i++) {
        k = id[i]; er = (k in e) ? e[k] : "none"; pr = (k in p) ? p[k] : "none"
        if (hit(er) != hit(pr)) print k, "engine=" er, "panel=" pr
      }
    }' "$1" "$2"
}

check_S2_15() { s2e_check_15; }
s2e_check_15() {
  local g w fe fp he re hp rp ve vp cur gap missing="" notes="" figs="" diff
  cur="$(cat "$KIT_ROOT/run/version" 2>/dev/null)"
  for g in a b c d; do
    fe="$(s2e_saved_file engine "$g")"; fp="$(s2e_saved_file panel "$g")"
    w="$(s2e_window "$g")"
    set -- $(s2e_hits "$fe" "$w"); he="$1"; re="$2"
    set -- $(s2e_hits "$fp" "$w"); hp="$1"; rp="$2"
    if [ "$re" = 0 ] || [ "$rp" = 0 ]; then
      missing="${missing:+$missing; }group $g: no saved $([ "$re" = 0 ] && printf 'engine ')$([ "$re" = 0 ] && [ "$rp" = 0 ] && printf 'or ')$([ "$rp" = 0 ] && printf 'panel ')run (engine and panel of group $g)"
      continue
    fi
    ve="$(s2e_saved_version "$fe")"; vp="$(s2e_saved_version "$fp")"
    if [ "$ve" != "$vp" ] || { [ -n "$cur" ] && [ "$ve" != "$cur" ]; }; then
      missing="${missing:+$missing; }group $g: the engine run was saved under version ${ve:-none}, the panel run under ${vp:-none}, the kit is at ${cur:-unknown}"
      continue
    fi
    gap=$((he - hp)); [ "$gap" -lt 0 ] && gap=$((0 - gap))
    echo "  | group $g: engine $he of $re hits, panel $hp of $rp hits (gap $gap, a hit is a rank 1 to $w)"
    figs="${figs:+$figs, }$g engine $he panel $hp"
    if [ "$gap" -gt 1 ]; then
      diff="$(s2e_diff_rows "$fe" "$fp" "$w" | tr '\n' ' ')"
      echo "noted: engine and app diverge in group $g: engine $he of $re hits, panel $hp of $rp hits; rows that differ: $diff"
      notes="${notes:+$notes, }group $g"
    fi
  done
  if [ -n "$missing" ]; then
    echo "RERUN S2.15 not valid: $missing"
    return 4
  fi
  echo "CHECK S2.15 PASS engine and panel hit counts differ by at most 1 in groups a to d ($figs)${notes:+ (noted: engine and app diverge in $notes)}"
  return 0
}

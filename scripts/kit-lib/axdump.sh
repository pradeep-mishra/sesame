#!/bin/bash
# Pure readers of the accessibility dump that `kit-ax.sh dump <setup|settings|panel|...>` prints (the dumpTree of
# scripts/kit-lib/ax.applescript). Sourced by recipes.sh (and so by every check), never run. Each function reads a dump on
# stdin and prints; none of them calls a kit script or touches a file, so a test can run them on hand-written text.
# bash 3.2 and the macOS awk.
#
# A dump line is
#   <indent><AXRole>[/<subrole>] label="<title, else description, else placeholder, else value>" [desc="<description>"]
#   [help="<AXHelp>"] [value="<AXValue, when it differs from the label>"] [focused] [selected] [disabled]
# two spaces of indent for each level. `desc` is printed only when the description is not the label already, `help` only
# when there is one. The product writes a folder row as one tick (an AXCheckBox) whose title is the folder's name, whose
# description is "<name>, <counts>, <estimate>" and whose help is the folder's full path; its Re-index and Remove buttons
# (Settings) carry the folder's name as their help. Which AX attribute each of these is read from is a guess until the
# accept stage drives it for real (design U-notes): a dump with no `desc` falls back to the label for the detail.

# ax_elements : "depth<TAB>role<TAB>label<TAB>desc<TAB>help<TAB>value<TAB>flags" for every element line of the dump
# (flags: F focused, S selected, D disabled). Lines that are not element lines (the header, "(tree cut ...)") are skipped.
ax_elements() {
  awk '
  function grab(s, key,    i, rest, n, ch, j) {
    i = index(s, " " key "=\"")
    if (i == 0) return ""
    rest = substr(s, i + length(key) + 3)
    n = length(rest)
    for (j = 1; j <= n; j++) {
      if (substr(rest, j, 1) == "\"") {
        ch = substr(rest, j + 1, 1)
        if (ch == "" || ch == " ") return substr(rest, 1, j - 1)
      }
    }
    return rest
  }
  /^ *AX[A-Za-z]/ {
    ind = match($0, /[^ ]/) - 1
    body = substr($0, ind + 1)
    sp = index(body, " ")
    role = (sp ? substr(body, 1, sp - 1) : body)
    rest = (sp ? substr(body, sp) : "")
    tail = rest
    k = 0
    for (j = length(rest); j >= 1; j--) if (substr(rest, j, 1) == "\"") { k = j; break }
    if (k > 0) tail = substr(rest, k + 1)
    fl = ""
    if (index(tail, "[focused]")) fl = fl "F"
    if (index(tail, "[selected]")) fl = fl "S"
    if (index(tail, "[disabled]")) fl = fl "D"
    printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", ind / 2, role, grab(rest, "label"), grab(rest, "desc"), grab(rest, "help"), grab(rest, "value"), fl
  }'
}

ax_rows_awk='
  function grab(s, key,    i, rest, n, ch, j) {
    i = index(s, " " key "=\"")
    if (i == 0) return ""
    rest = substr(s, i + length(key) + 3)
    n = length(rest)
    for (j = 1; j <= n; j++) {
      if (substr(rest, j, 1) == "\"") {
        ch = substr(rest, j + 1, 1)
        if (ch == "" || ch == " ") return substr(rest, 1, j - 1)
      }
    }
    return rest
  }
  /^ *AX[A-Za-z]/ {
    ind = match($0, /[^ ]/) - 1
    body = substr($0, ind + 1)
    sp = index(body, " ")
    role = (sp ? substr(body, 1, sp - 1) : body)
    rest = (sp ? substr(body, sp) : "")
    help = grab(rest, "help")
    isrow = (role ~ /^AXCheckBox/ && substr(help, 1, 1) == "/")
    if (on && (isrow || ind < rowind)) exit
    if (isrow) {
      p = help; sub(/\/+$/, "", p); n = split(p, seg, "/"); name = seg[n]
      label = grab(rest, "label"); desc = grab(rest, "desc")
      detail = (desc != "" ? desc : label)
      if (index(detail, name ", ") == 1) detail = substr(detail, length(name) + 3)
      else if (detail == name) detail = ""
      value = grab(rest, "value")
      tail = rest; k = 0
      for (j = length(rest); j >= 1; j--) if (substr(rest, j, 1) == "\"") { k = j; break }
      if (k > 0) tail = substr(rest, k + 1)
      if (mode == "rows") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", help, name, (value ~ /^(1|true|on)$/ ? "on" : "off"), (index(tail, "[disabled]") ? "disabled" : "enabled"), detail, "folder"
        next
      }
      if (!on && (name == sel || help == sel)) { on = 1; rowind = ind; found = 1; print; next }
      next
    }
    if (on) print
  }
  END { if (mode == "block" && !found) exit 1 }'

# ax_rows : every folder row of the dump, one TSV line each (see ax_rows_awk).
ax_rows() {
  awk -v mode=rows "$ax_rows_awk"
}

ax_folders() {
  ax_rows | awk -F'\t' '!seen[$1]++ { print $1 }'
}

ax_row() {
  ax_rows | awk -F'\t' -v s="$1" '($2 == s || $1 == s) { print; f = 1; exit } END { exit f ? 0 : 1 }'
}

ax_row_detail() {
  local line
  line="$(ax_row "$1")" || return 1
  printf '%s\n' "$line" | awk -F'\t' '{ print $5 }'
}

# ax_row_estimate <name or path> : the last part of the row's detail, after its final ", " ("about 1 min", "after the model
# download", "Waiting for Start indexing", "counting"); the whole detail when it has no comma. Status 1 when no row.
ax_row_estimate() {
  local d
  d="$(ax_row_detail "$1")" || return 1
  printf '%s\n' "$d" | awk '{ i = 0; s = $0; while ((j = index(s, ", ")) > 0) { i += j + 1; s = substr(s, j + 2) } print s }'
}

ax_row_block() {
  awk -v mode=block -v sel="$1" "$ax_rows_awk"
}

# ax_has_label <text> : status 0 when an element's label is exactly the text.
ax_has_label() {
  ax_elements | awk -F'\t' -v w="$1" '$3 == w { f = 1 } END { exit f ? 0 : 1 }'
}

# ax_has_label_prefix <text> : status 0 when an element's label starts with the text.
ax_has_label_prefix() {
  ax_elements | awk -F'\t' -v w="$1" 'index($3, w) == 1 { f = 1 } END { exit f ? 0 : 1 }'
}

# ax_switch <label> : on, off or absent, for the tick or switch (an AXCheckBox) with exactly that label.
ax_switch() {
  ax_elements | awk -F'\t' -v w="$1" '$2 ~ /^AXCheckBox/ && $3 == w { f = 1; if ($6 ~ /^(1|true|on)$/) on = 1 } END { print (!f ? "absent" : (on ? "on" : "off")) }'
}

# ax_total_seconds : the estimate total of the Folders step, in seconds, read from the one line that ends in " in total"
# ("About 5 min in total", "About 2 h 10 min in total", "Under a minute in total": 30 s, the middle of what it promises).
# Nothing is printed when no such line is there; a row's own estimate is never taken for the total.
ax_total_seconds() {
  ax_elements | awk -F'\t' '
    { t = tolower($3) }
    t ~ / in total$/ {
      sub(/ in total$/, "", t)
      if (t == "under a minute") { s = 30; got = 1 }
      else if (t ~ /^about [0-9]+ h( [0-9]+ min)?$/ || t ~ /^about [0-9]+ min$/) {
        s = 0
        if (match(t, /[0-9]+ h/)) s += substr(t, RSTART, RLENGTH - 2) * 3600
        if (match(t, /[0-9]+ min/)) s += substr(t, RSTART, RLENGTH - 4) * 60
        got = 1
      }
    }
    END { if (got) print s }'
}

# ax_speed_note : the seconds a photo takes, from the note "Photos: about <n> s each" ("3", "1.5"); nothing when there is none.
ax_speed_note() {
  ax_elements | awk -F'\t' '
    $3 ~ /^Photos: about [0-9]+(\.[0-9]+)? s each$/ { t = $3; sub(/^Photos: about /, "", t); sub(/ s each$/, "", t); print t; exit }'
}

ax_strip_frames() {
  sed -E 's/ frame=-?[0-9]+,-?[0-9]+,-?[0-9]+,-?[0-9]+[[:space:]]*$//'
}

ax_boxes() {
  awk '
  function grab(s, key,    i, rest, n, ch, j) {
    i = index(s, " " key "=\"")
    if (i == 0) return ""
    rest = substr(s, i + length(key) + 3)
    n = length(rest)
    for (j = 1; j <= n; j++) {
      if (substr(rest, j, 1) == "\"") {
        ch = substr(rest, j + 1, 1)
        if (ch == "" || ch == " ") return substr(rest, 1, j - 1)
      }
    }
    return rest
  }
  /^ *AX[A-Za-z]/ {
    n++
    ind = match($0, /[^ ]/) - 1
    d = ind / 2
    body = substr($0, ind + 1)
    sp = index(body, " ")
    role = (sp ? substr(body, 1, sp - 1) : body)
    rest = (sp ? substr(body, sp) : "")
    base = role
    sub(/\/.*/, "", base)
    last[d] = n
    rl[n] = base
    par = (d > 0 ? last[d - 1] + 0 : 0)
    x = ""; y = ""; w = ""; h = ""
    if (match($0, / frame=-?[0-9]+,-?[0-9]+,-?[0-9]+,-?[0-9]+[ ]*$/)) {
      f = substr($0, RSTART + 7, RLENGTH - 7)
      sub(/ +$/, "", f)
      split(f, a, ",")
      x = a[1] + 0; y = a[2] + 0; w = a[3] + 0; h = a[4] + 0
      if (base == "AXWindow" && !haveo) { ox = x; oy = y; haveo = 1 }
      x = x - ox; y = y - oy
    }
    printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, par, role, grab(rest, "label"), x, y, w, h, (par ? rl[par] : ""), grab(rest, "help")
  }'
}

ax_load_awk='
function base(r) { sub(/\/.*/, "", r); return r }
function isbutton(r) { r = base(r); return (r == "AXButton" || r == "AXCheckBox" || r == "AXPopUpButton" || r == "AXRadioButton" || r == "AXMenuButton") }
function content(i,  r) {
  r = base(role[i])
  return (has[i] && W[i] > 0 && H[i] > 0 && (r == "AXStaticText" || r == "AXTextField" || r == "AXTextArea" || r == "AXButton" || r == "AXCheckBox" || r == "AXPopUpButton" || r == "AXRadioButton" || r == "AXComboBox"))
}
function inner(i) { return (par[i] > 0 && isbutton(role[par[i]])) }
function scrolled(i,  p, r) {
  p = par[i]
  while (p > 0) {
    r = base(role[p])
    if (r == "AXScrollArea" || r == "AXList" || r == "AXTable" || r == "AXOutline") return 1
    p = par[p]
  }
  return 0
}
function find(want,  i, star, pre) {
  star = (substr(want, length(want), 1) == "*")
  pre = (star ? substr(want, 1, length(want) - 1) : want)
  for (i = 1; i <= N; i++) {
    if (!has[i]) continue
    if (star ? index(lab[i], pre) == 1 : lab[i] == want) return i
  }
  return 0
}
function min(a, b) { return (a < b ? a : b) }
function max(a, b) { return (a > b ? a : b) }
function rnd(v) { return (v < 0 ? v - 0.5 : v + 0.5) }
{
  n = $1 + 0; N = n
  par[n] = $2 + 0; role[n] = $3; lab[n] = $4; prl[n] = $9; hlp[n] = $10
  if ($5 != "") { has[n] = 1; X[n] = $5 + 0; Y[n] = $6 + 0; W[n] = $7 + 0; H[n] = $8 + 0 }
}
'

ax_overlaps() {
  ax_boxes | LC_ALL=C awk -F'\t' "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      if (!content(i) || inner(i)) continue
      for (j = i + 1; j <= N; j++) {
        if (par[j] != par[i] || !content(j) || inner(j)) continue
        if (min(X[i] + W[i], X[j] + W[j]) - max(X[i], X[j]) > 1 && min(Y[i] + H[i], Y[j] + H[j]) - max(Y[i], Y[j]) > 1)
          printf "%s \"%s\" overlaps %s \"%s\"\n", base(role[i]), lab[i], base(role[j]), lab[j]
      }
    }
  }'
}

ax_outside() {
  ax_boxes | LC_ALL=C awk -F'\t' "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      p = par[i]
      if (p == 0 || !has[i] || !has[p] || W[i] <= 0 || H[i] <= 0 || W[p] <= 0 || H[p] <= 0 || inner(i)) continue
      side = (X[i] < X[p] - 2 || X[i] + W[i] > X[p] + W[p] + 2)
      vert = 0
      if (!scrolled(i)) vert = (Y[i] < Y[p] - 2 || Y[i] + H[i] > Y[p] + H[p] + 2)
      if (side || vert) printf "%s \"%s\" is outside %s \"%s\"\n", base(role[i]), lab[i], base(role[p]), lab[p]
    }
  }'
}

ax_centred() {
  ax_boxes | LC_ALL=C awk -F'\t' -v want="$1" -v x0="$2" -v x1="$3" -v tol="$4" "$ax_load_awk"'
  END {
    i = find(want)
    if (i == 0) exit 2
    off = (X[i] + W[i] / 2) - (x0 + x1) / 2
    printf "%d\n", rnd(off)
    exit ((off < 0 ? -off : off) <= tol ? 0 : 1)
  }'
}

ax_wide() {
  ax_boxes | LC_ALL=C awk -F'\t' -v want="$1" -v lim="$2" "$ax_load_awk"'
  END {
    i = find(want)
    if (i == 0) exit 2
    printf "%d\n", W[i]
    exit (W[i] <= lim ? 0 : 1)
  }'
}

ax_crosses() {
  ax_boxes | LC_ALL=C awk -F'\t' -v cx="$1" -v y0="$2" -v y1="$3" "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      r = base(role[i])
      if (!has[i] || (r != "AXStaticText" && r != "AXTextArea") || W[i] <= 0) continue
      if (Y[i] < y0 || Y[i] >= y1) continue
      if (X[i] + 1 < cx && X[i] + W[i] - 1 > cx) printf "%s \"%s\"\n", r, lab[i]
    }
  }'
}

ax_frame() {
  ax_boxes | LC_ALL=C awk -F'\t' -v want="$1" -v skip="${2:-0}" "$ax_load_awk"'
  END {
    star = (substr(want, length(want), 1) == "*")
    pre = (star ? substr(want, 1, length(want) - 1) : want)
    for (i = 1; i <= N; i++) {
      if (!has[i]) continue
      if (star ? index(lab[i], pre) != 1 : lab[i] != want) continue
      if (skip-- > 0) continue
      printf "%d %d %d %d\n", X[i], Y[i], W[i], H[i]
      exit 0
    }
    exit 2
  }'
}

ax_gap_above() {
  ax_boxes | LC_ALL=C awk -F'\t' -v want="$1" "$ax_load_awk"'
  END {
    t = find(want)
    if (t == 0) exit 2
    top = Y[t]
    low = 0
    for (i = 1; i <= N; i++) {
      if (i == t || !content(i) || inner(i)) continue
      if (Y[i] + H[i] <= top + 1 && Y[i] + H[i] > low) low = Y[i] + H[i]
    }
    printf "%d\n", top - low
  }'
}

ax_near_bottom() {
  ax_boxes | LC_ALL=C awk -F'\t' -v wh="$1" -v lim="$2" "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      if (!content(i) || inner(i) || scrolled(i)) continue
      if (Y[i] + H[i] > wh - lim) printf "%s \"%s\"\n", base(role[i]), lab[i]
    }
  }'
}

ax_first_row_gap() {
  ax_boxes | LC_ALL=C awk -F'\t' "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      if (base(role[i]) != "AXCheckBox" || substr(hlp[i], 1, 1) != "/" || !has[i]) continue
      p = par[i]
      if (p == 0 || !has[p]) exit 2
      printf "%d\n", Y[i] - Y[p]
      exit 0
    }
    exit 2
  }'
}

ax_warnings() {
  ax_boxes | LC_ALL=C awk -F'\t' "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      if (!has[i] || base(role[i]) != "AXImage" || lab[i] != "Warning") continue
      for (j = 1; j <= N; j++) {
        if (!has[j] || base(role[j]) != "AXStaticText" || lab[j] == "") continue
        dx = X[j] - (X[i] + W[i])
        dy = (Y[j] + H[j] / 2) - (Y[i] + H[i] / 2)
        gap = Y[j] - (Y[i] + H[i])
        cx = (X[j] + W[j] / 2) - (X[i] + W[i] / 2)
        beside = (dx >= -2 && dx <= 24 && dy >= -12 && dy <= 12)
        above = (gap >= -2 && gap <= 24 && cx >= -12 && cx <= 12)
        if ((beside || above) && !seen[lab[j]]++) print lab[j]
      }
    }
  }'
}

ax_ellipsis() {
  ax_boxes | LC_ALL=C awk -F'\t' -v needle="$1" "$ax_load_awk"'
  END {
    for (i = 1; i <= N; i++) {
      l = lab[i]
      if (l == "" || index(l, needle) == 0) continue
      if (l ~ /…$/ || l ~ /\.\.\.$/) printf "%s\t%s\n", (has[i] ? X[i] : "-"), l
    }
  }'
}

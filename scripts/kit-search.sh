#!/bin/bash
# kit-search.sh "<text>" [--select N] [--open|--reveal|--copy] [--wait-for <path> --within <seconds>]
#                        [--expect-absent <path>] [--keep-open]
#
# Opens the panel with the shortcut, types the text key by key, waits for the ranked list, prints every row
# and the right pane, then acts, then closes (verify.md, Kit scripts).
#
# Kit safety: the shortcut is posted with `kit-ax.sh hotkey` only inside this script's own `kitwindow open` and
# `kitwindow close` (Sesame is not frontmost while the panel is closed), on every path including a failure.
# Typing and keys go to Sesame only, and only once `kit-ax.sh frontmost` reads Sesame; with no Sesame panel,
# or a panel with no search box, nothing is posted but the shortcut, to the kit window.
#
#   --select N                  moves the selection to row N with Down, one key at a time
#   --open | --reveal | --copy  Enter | Command+Enter | Command+C on the selected row
#   --wait-for <path> --within <s>
#                               retypes the text every 2 s until a row holds that file's name or the time runs
#                               out; prints the elapsed time
#   --expect-absent <path>      exit 1 when a row holds that file's name
#   --keep-open                 leaves the panel open (Sesame frontmost) for the next kit-ax.sh call
# Output: `search box label="..." value="..."`, `rows <n>`, one `row <n> selected|- <texts>` per row (the list as
# the accessibility tree gives it, scrolled to its end by the tree itself), one `pane <text>` per pane text.
# Exit codes: 0 done; 1 no panel, no search box, a refusal, or a failed expectation; 2 usage; 3 NEEDS A PERSON;
# 4 the list did not settle (not valid: rerun).
. "$(dirname "$0")/kit-lib/common.sh"
. "$KIT_LIB/panel.sh"

usage() {
  cat >&2 <<'EOF'
usage: kit-search.sh "<text>" [--select N] [--open|--reveal|--copy] [--wait-for <path> --within <seconds>]
                              [--expect-absent <path>] [--keep-open]
EOF
}

S_TEXT=""
S_SELECT=""
S_ACT=""
S_WAIT_FOR=""
S_WITHIN=""
S_ABSENT=""
S_KEEP=0

# print_panel : the settled panel as lines.
print_panel() {
  local box rows n
  box="$(pn_searchbox)"
  printf 'search box label="%s" value="%s"\n' "$(printf '%s' "$box" | cut -f1)" "$(printf '%s' "$box" | cut -f2)"
  rows="$(pn_rows)"
  n="$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n + 0 }')"
  echo "rows $n"
  printf '%s\n' "$rows" | awk -F'\t' 'NF { printf "row %s %s %s\n", $1, $2, $3 }'
  pn_pane | awk '{ print "pane " $0 }'
}

# type_text : the box is emptied first when it holds something (a wait-for retry), then the text is typed.
type_text() {
  local box val out rc
  box="$(pn_searchbox)"
  val="$(printf '%s' "$box" | cut -f2)"
  if [ -n "$val" ]; then
    out="$(pn_ax key "cmd+a" 2>&1)" || { printf '%s\n' "$out"; return 1; }
  fi
  out="$(pn_ax type "$S_TEXT" 2>&1)"; rc=$?
  if [ $rc != 0 ]; then printf '%s\n' "$out"; return $rc; fi
  return 0
}

search_run() {
  local rc box size sel_n i k start now elapsed
  pn_open_panel; rc=$?
  if [ $rc != 0 ]; then
    [ $rc = 3 ] && { printf '%s\n' "$PN_OUT"; return 3; }
    echo "no Sesame panel: $PN_OUT"
    return 1
  fi
  pn_dump
  size="$(pn_size)"
  box="$(pn_searchbox)" || {
    echo "no search box: the Sesame panel (${size:-no size}) has no text field in its accessibility tree"
    return 1
  }
  if ! pn_wait_sesame_front 3; then
    echo "Sesame is not frontmost after the shortcut ($PN_OUT): nothing was typed"
    return 1
  fi
  if [ -n "$(printf '%s' "$box" | cut -f2)" ]; then
    echo "the search box holds \"$(printf '%s' "$box" | cut -f2)\" after a fresh open (S1.3's subject): nothing was typed"
    return 1
  fi
  type_text || return $?
  pn_wait_list 20 || { echo "not valid: the list did not settle within 20 s"; return 4; }
  print_panel

  if [ -n "$S_WAIT_FOR" ]; then
    start="$(date +%s)"
    while ! pn_listed "$S_WAIT_FOR"; do
      now="$(date +%s)"; elapsed=$((now - start))
      if [ "$elapsed" -ge "$S_WITHIN" ]; then
        echo "not listed within $S_WITHIN s: $S_WAIT_FOR"
        return 1
      fi
      sleep 2
      type_text || return $?
      pn_wait_list 20 || { echo "not valid: the list did not settle within 20 s"; return 4; }
    done
    now="$(date +%s)"
    echo "found $S_WAIT_FOR after $((now - start)) s"
    print_panel
  fi

  if [ -n "$S_ABSENT" ]; then
    if pn_listed "$S_ABSENT"; then
      echo "listed but expected absent: $S_ABSENT"
      return 1
    fi
    echo "absent as expected: $S_ABSENT"
  fi

  if [ -n "$S_SELECT" ]; then
    for ((i = 1; i < S_SELECT; i++)); do
      pn_ax key down >/dev/null 2>&1 || { echo "could not post Down"; return 1; }
    done
    pn_wait_list 10 || { echo "not valid: the list did not settle after moving the selection"; return 4; }
    sel_n="$(pn_rows | awk -F'\t' '$2 == "selected" { print $1; exit }')"
    echo "selected row ${sel_n:-none}"
    if [ "$sel_n" != "$S_SELECT" ]; then
      echo "the selection is on row ${sel_n:-none}, not row $S_SELECT"
      return 1
    fi
  fi

  case "$S_ACT" in
    open) pn_ax key enter || return $? ;;
    reveal) pn_ax key "cmd+enter" || return $? ;;
    copy) pn_ax key "cmd+c" || return $? ;;
  esac
  return 0
}

is_posint() { case "$1" in ""|*[!0-9]*|0) return 1 ;; esac; return 0; }

main() {
  [ $# -ge 1 ] || { usage; return 2; }
  S_TEXT="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --select) [ $# -ge 2 ] && is_posint "$2" || { usage; return 2; }; S_SELECT="$2"; shift 2 ;;
      --open) S_ACT=open; shift ;;
      --reveal) S_ACT=reveal; shift ;;
      --copy) S_ACT=copy; shift ;;
      --wait-for) [ $# -ge 2 ] || { usage; return 2; }; S_WAIT_FOR="$2"; shift 2 ;;
      --within) [ $# -ge 2 ] && is_posint "$2" || { usage; return 2; }; S_WITHIN="$2"; shift 2 ;;
      --expect-absent) [ $# -ge 2 ] || { usage; return 2; }; S_ABSENT="$2"; shift 2 ;;
      --keep-open) S_KEEP=1; shift ;;
      *) usage; return 2 ;;
    esac
  done
  if [ -n "$S_WAIT_FOR" ] && [ -z "$S_WITHIN" ]; then usage; return 2; fi
  [ -z "$S_WITHIN" ] || [ -n "$S_WAIT_FOR" ] || { usage; return 2; }
  kit_need_ps || return 1
  if [ -z "$(kit_pid_of app)" ]; then
    echo "no Sesame panel: Sesame is not running (scripts/kit-launch.sh start starts it)"
    return 1
  fi
  # The kit window is closed on every path, including a signal.
  trap 'pn_kit_close; exit 130' INT TERM HUP
  search_run; rc=$?
  # After Enter or Command+Enter the front belongs to the image app or Finder: nothing more is posted.
  if [ "$S_KEEP" = 0 ] && [ "$S_ACT" != open ] && [ "$S_ACT" != reveal ]; then
    pn_close_panel >/dev/null 2>&1
  fi
  pn_kit_close
  trap - INT TERM HUP
  return $rc
}

kit_wrap "$(kit_slug kit-search "$@")" main "$@"
exit $?

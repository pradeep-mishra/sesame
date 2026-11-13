#!/bin/bash
# scripts/kit-static.sh [--quick | --selftest]
# The worker's way to run scripts/check-static.sh (tools.json allows that script only bare).
# Passes --quick, --selftest or no argument straight through and nothing else, prints the result
# and saves the complete output to the evidence folder.
# Exit codes: those of check-static.sh (0 pass, 1 a rule failed or is PENDING in a full run); 2 usage.

KIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-lib/common.sh
. "$KIT_SCRIPT_DIR/kit-lib/common.sh"

usage() {
  echo "usage: scripts/kit-static.sh [--quick | --selftest]" >&2
  exit 2
}

case "$#" in
  0) ;;
  1) case "$1" in --quick|--selftest) ;; *) usage ;; esac ;;
  *) usage ;;
esac

kit_wrap "$(kit_slug kit-static "$@")" "$KIT_SCRIPT_DIR/check-static.sh" "$@"
exit $?

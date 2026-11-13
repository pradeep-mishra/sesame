#!/bin/bash
# scripts/kit-llama.sh patched|unpatched
# The worker's way to run scripts/build-llama.sh with its one setting (tools.json allows that script
# only bare). `patched` runs it with SESAME_LLAMA_PATCH=1, `unpatched` with SESAME_LLAMA_PATCH=0.
# SESAME_LLAMA_PATCH is a build-script setting, read only in scripts/build-llama.sh; it is not a
# launch setting of the product. Prints the build's output and saves it to the evidence folder.
# Exit codes: those of build-llama.sh; 2 usage.

KIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-lib/common.sh
. "$KIT_SCRIPT_DIR/kit-lib/common.sh"

usage() {
  echo "usage: scripts/kit-llama.sh patched|unpatched" >&2
  echo "  patched    runs scripts/build-llama.sh with SESAME_LLAMA_PATCH=1" >&2
  echo "  unpatched  runs scripts/build-llama.sh with SESAME_LLAMA_PATCH=0" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
  patched)   value=1 ;;
  unpatched) value=0 ;;
  *) usage ;;
esac

kit_wrap "$(kit_slug kit-llama "$1")" env "SESAME_LLAMA_PATCH=$value" "$KIT_SCRIPT_DIR/build-llama.sh"
exit $?

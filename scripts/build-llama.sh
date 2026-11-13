#!/bin/bash
# build-llama.sh
#
# Fetches llama.cpp tag b11461 (commit 4d756bc72bf00a4aacf410ae15a2d315f3db400d) into
# third_party/llama.cpp the first time, and builds it static with Metal and mtmd into
# third_party/llama.cpp/build. The libraries it writes are the ones Package.swift links.
#
# Two patches (scripts/):
#   llama.cpp-vision-only.patch  always applied: the mtmd_context_params.vision_only switch that
#                                Sources/SesameEngine/PhotoReader.swift sets (exit 1 if the file is absent)
#   llama.cpp-no-logits.patch    the Sesame helper's: no vocabulary-sized logits for a non-causal embedding context
# Environment: SESAME_LLAMA_PATCH (a build setting, not a launch setting of the product) governs the second one
#   1      apply no-logits (exit 1 "patch file missing" if it is absent)
#   0      build without no-logits (the vision-only patch is still applied)
#   unset  apply no-logits only if the file exists
# Exit codes: 0 built; 1 error (wrong commit, missing patch, build failure, missing library).
set -euo pipefail

TAG="b11461"
COMMIT="4d756bc72bf00a4aacf410ae15a2d315f3db400d"
URL="https://github.com/ggml-org/llama.cpp"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/llama.cpp"
BUILD="$SRC/build"
PATCH="$ROOT/scripts/llama.cpp-no-logits.patch"
VISION_PATCH="$ROOT/scripts/llama.cpp-vision-only.patch"
[ -f "$VISION_PATCH" ] || { echo "patch file missing: $VISION_PATCH" >&2; exit 1; }

# What the patch setting says, checked before anything is fetched.
case "${SESAME_LLAMA_PATCH:-}" in
  1) [ -f "$PATCH" ] || { echo "patch file missing: $PATCH" >&2; exit 1; }; use_patch=1 ;;
  0) use_patch=0 ;;
  "") if [ -f "$PATCH" ]; then use_patch=1; else use_patch=0; fi ;;
  *) echo "SESAME_LLAMA_PATCH must be 0 or 1, not '${SESAME_LLAMA_PATCH}'" >&2; exit 2 ;;
esac

# The one-time fetch; an existing folder is never fetched again.
if [ ! -e "$SRC/.git" ]; then
  echo "fetch: $URL at tag $TAG"
  mkdir -p "$ROOT/third_party"
  git clone --quiet --depth 1 --branch "$TAG" "$URL" "$SRC"
fi

# Any other commit is refused.
have="$(git -C "$SRC" rev-parse HEAD)"
if [ "$have" != "$COMMIT" ]; then
  echo "refused: third_party/llama.cpp is at $have, not $COMMIT (tag $TAG)" >&2
  exit 1
fi

# Start from the pinned source, then add the patches.
git -C "$SRC" checkout --quiet -- .
git -C "$SRC" apply "$VISION_PATCH"
echo "llama vision-only patch: on"
if [ "$use_patch" = 1 ]; then
  git -C "$SRC" apply "$PATCH"
  echo "llama patch: on"
else
  echo "llama patch: off"
fi
echo "commit: $COMMIT (tag $TAG)"

CONFIGURE=(cmake -S "$SRC" -B "$BUILD"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS=ON
  -DLLAMA_BUILD_TOOLS=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DLLAMA_CURL=OFF
  -DLLAMA_OPENSSL=OFF)
BUILD_CMD=(cmake --build "$BUILD" --config Release --target mtmd llama ggml -j 8)

echo "cmake configure: ${CONFIGURE[*]}"
"${CONFIGURE[@]}"
echo "cmake build: ${BUILD_CMD[*]}"
"${BUILD_CMD[@]}"

# The libraries Package.swift names, in the folders its -L flags name.
LIBS=(
  "$BUILD/tools/mtmd/libmtmd.a"
  "$BUILD/src/libllama.a"
  "$BUILD/ggml/src/libggml.a"
  "$BUILD/ggml/src/ggml-metal/libggml-metal.a"
  "$BUILD/ggml/src/ggml-blas/libggml-blas.a"
  "$BUILD/ggml/src/libggml-cpu.a"
  "$BUILD/ggml/src/libggml-base.a"
)
missing=0
for lib in "${LIBS[@]}"; do
  if [ -f "$lib" ]; then
    echo "library: $lib"
  else
    echo "library missing: $lib" >&2
    missing=1
  fi
done
[ "$missing" = 0 ] || exit 1
echo "built $COMMIT"

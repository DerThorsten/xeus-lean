#!/usr/bin/env bash
# build-lite-from-prefix.sh - Build a JupyterLite site from an emscripten-wasm64
# prefix that has xeus-lean installed (e.g. from the emscripten-forge package).
#
# Usage: build-lite-from-prefix.sh <prefix> <output-dir> [contents-dir]
#
# Requires jupyterlite-core and jupyterlite-xeus on PATH, e.g.
#   pixi exec --spec jupyterlite-core --spec jupyterlite-xeus --spec notebook \
#     bash scripts/build-lite-from-prefix.sh <prefix> _output
#
# jupyterlite-xeus copies the kernel binaries to xeus/<env>/bin/, but not the
# olean tarballs; src/post.js fetches them from xeus/<env>/olean/
# (relative to xlean.js), so they are copied there explicitly.
set -euo pipefail

PREFIX="$(cd "${1:?usage: $0 <prefix> <output-dir> [contents-dir]}" && pwd)"
OUT="${2:?usage: $0 <prefix> <output-dir> [contents-dir]}"
CONTENTS="${3:-$(dirname "$0")/../notebooks}"
ENV_NAME="$(basename "$PREFIX")"

jupyter lite build \
    --XeusAddon.prefix="$PREFIX" \
    --contents "$CONTENTS" \
    --output-dir "$OUT"

mkdir -p "$OUT/xeus/$ENV_NAME/olean"
cp "$PREFIX"/share/jupyter/olean/*-olean.tar.zst \
   "$PREFIX"/share/jupyter/olean/manifest-v2.json \
   "$OUT/xeus/$ENV_NAME/olean/"

echo "kernels: $(cat "$OUT/xeus/kernels.json")"
ls -lh "$OUT/xeus/$ENV_NAME/bin" "$OUT/xeus/$ENV_NAME/olean"

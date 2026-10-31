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
# This is a plain jupyterlite-xeus build: the olean tarballs (xeus-lean-data)
# are mounted into the kernel FS like any other package, and the kernel
# unpacks them from /share/jupyter/olean at startup.
set -euo pipefail

PREFIX="$(cd "${1:?usage: $0 <prefix> <output-dir> [contents-dir]}" && pwd)"
OUT="${2:?usage: $0 <prefix> <output-dir> [contents-dir]}"
CONTENTS="${3:-$(dirname "$0")/../notebooks}"

jupyter lite build \
    --XeusAddon.prefix="$PREFIX" \
    --contents "$CONTENTS" \
    --output-dir "$OUT"

echo "kernels: $(cat "$OUT/xeus/kernels.json")"

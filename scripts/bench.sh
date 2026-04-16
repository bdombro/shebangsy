#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# BIN="${ROOT_DIR}/dist/shebangsy"
BIN_DIR="${ROOT_DIR}/dist"

cd "${ROOT_DIR}"
./scripts/build.sh

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "bench.sh: hyperfine not found. Install it first (brew install hyperfine)." >&2
  exit 1
fi

PATH="${BIN_DIR}:$PATH" hyperfine --warmup 2 --runs 20  --shell=none \
    $SCRIPT_DIR/bench-assets/go/* \
    $SCRIPT_DIR/bench-assets/mojo/mojo_* \
    $SCRIPT_DIR/bench-assets/nim/* \
    | tee "${ROOT_DIR}/bench-results.txt"

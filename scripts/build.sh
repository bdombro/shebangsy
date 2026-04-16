#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

cd "${ROOT_DIR}"
./scripts/gen-registry.sh
nim c -d:release --hints:off --verbosity:0 -o:dist/shebangsy shebangsy.nim

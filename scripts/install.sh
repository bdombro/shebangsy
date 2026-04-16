#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

cd "${ROOT_DIR}"
./scripts/build.sh

DIST_BIN="${ROOT_DIR}/dist/shebangsy"
LOCAL_BIN="${HOME}/.local/bin"

mkdir -p "${LOCAL_BIN}"
cp -f "${DIST_BIN}" "${LOCAL_BIN}/shebangsy"
chmod +x "${LOCAL_BIN}/shebangsy"

echo "install.sh: installed ${LOCAL_BIN}/shebangsy"

mkdir -p "${HOME}/.zsh/completions"
"${DIST_BIN}" completion zsh > "${HOME}/.zsh/completions/_shebangsy"
"${DIST_BIN}" cache-clear
# rm -rf ~/.cache/shebangsy/* 2>/dev/null || true

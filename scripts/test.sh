#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BIN="${ROOT_DIR}/dist/shebangsy"

cd "${ROOT_DIR}"
./scripts/build.sh

fail() {
  echo "test.sh: $1" >&2
  exit 1
}

cache_bin_count() {
  local lang="$1"
  find "${HOME}/.cache/shebangsy/${lang}" -type f -name 's_*_t_*' 2>/dev/null | wc -l | tr -d ' '
}

run_lang_test() {
  local lang="$1" script="$2"

  echo "==> ${lang}: cold run"
  "${BIN}" "${lang}" "${script}" >/dev/null

  echo "==> ${lang}: warm run"
  local before after
  before="$(cache_bin_count "${lang}")"
  "${BIN}" "${lang}" "${script}" >/dev/null
  after="$(cache_bin_count "${lang}")"

  [[ "${before}" == "${after}" ]] || fail "warm ${lang} run created a new binary (${before} -> ${after})"
}

"${BIN}" cache-clear

if command -v nim >/dev/null 2>&1 && nim --version >/dev/null 2>&1; then
  run_lang_test nim ./examples/nim/hello.nim
else
  echo "==> nim tool missing; skipping Nim smoke test"
fi

if command -v go >/dev/null 2>&1 && go version >/dev/null 2>&1; then
  run_lang_test go ./examples/go/hello.go
else
  echo "==> go tool missing; skipping Go smoke test"
fi

if command -v mojo >/dev/null 2>&1 && mojo --version >/dev/null 2>&1; then
  run_lang_test mojo ./examples/mojo/hello.mojo
else
  echo "==> mojo tool missing; skipping Mojo smoke test"
fi

echo "test.sh: all enabled smoke tests passed"

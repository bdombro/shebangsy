#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BIN="${ROOT_DIR}/dist/shebangsy"

cd "${ROOT_DIR}"
./scripts/build.sh

# SHEBANGSY_TEST_MODE: all (default) | no-swift | swift-only — used by CI (Linux vs macOS).
RUN_NON_SWIFT=true
RUN_SWIFT=true
case "${SHEBANGSY_TEST_MODE:-all}" in
  all) ;;
  no-swift) RUN_SWIFT=false ;;
  swift-only) RUN_NON_SWIFT=false ;;
  *)
    echo "test.sh: unknown SHEBANGSY_TEST_MODE=${SHEBANGSY_TEST_MODE:-}" >&2
    exit 1
    ;;
esac

fail() {
  echo "test.sh: $1" >&2
  exit 1
}

cache_bin_count() {
  find "${HOME}/.cache/shebangsy" -type f -name 's_*_t_*' 2>/dev/null | wc -l | tr -d ' '
}

run_lang_test() {
  local lang="$1" script="$2"

  echo "==> ${lang}: cold run"
  "${BIN}" "${lang}" "${script}" >/dev/null

  echo "==> ${lang}: warm run"
  local before after
  before="$(cache_bin_count)"
  "${BIN}" "${lang}" "${script}" >/dev/null
  after="$(cache_bin_count)"

  [[ "${before}" == "${after}" ]] || fail "warm ${lang} run created a new binary (${before} -> ${after})"
}

rm -rf "${HOME}/.cache/shebangsy"

if [[ "${RUN_NON_SWIFT}" == true ]]; then
if command -v nim >/dev/null 2>&1 && nim --version >/dev/null 2>&1; then
  run_lang_test nim ./examples/nim/hello.nim
else
  echo "==> nim tool missing; skipping Nim smoke test"
fi

if command -v go >/dev/null 2>&1 && go version >/dev/null 2>&1; then
  run_lang_test go ./examples/go/hello.go
  echo "==> go: Cobra sample (cobra.go)"
  out="$("${BIN}" go ./examples/go/cobra.go World 2>/dev/null | tail -n 1)"
  out="${out%$'\r'}"
  out="${out%$'\n'}"
  [[ "${out}" == "Hello, World!" ]] || fail "go cobra.go expected 'Hello, World!', got '${out}'"
else
  echo "==> go tool missing; skipping Go smoke test"
fi

if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
  run_lang_test python3 ./examples/python/hello.py
else
  echo "==> python3 missing; skipping Python3 smoke test"
fi

if command -v mojo >/dev/null 2>&1 && mojo --version >/dev/null 2>&1; then
  run_lang_test mojo ./examples/mojo/hello.mojo
else
  echo "==> mojo tool missing; skipping Mojo smoke test"
fi

if command -v cmake >/dev/null 2>&1 && cmake --version >/dev/null 2>&1; then
  run_lang_test cpp ./examples/cpp/hello.cpp
  echo "==> cpp: cli11 sample"
  # First run may print CMake build lines to stdout; program output is the last line.
  out="$("${BIN}" cpp ./examples/cpp/cli11.cpp hello World 2>/dev/null | tail -n 1)"
  out="${out%$'\r'}"
  out="${out%$'\n'}"
  [[ "${out}" == "hello, World" ]] || fail "cpp cli expected 'hello, World', got '${out}'"
else
  echo "==> cmake missing; skipping cpp smoke tests"
fi

if command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1; then
  run_lang_test rust ./examples/rust/hello.rs
else
  echo "==> cargo missing; skipping Rust smoke test"
fi
fi

if [[ "${RUN_SWIFT}" == true ]]; then
if command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1 &&
  command -v swiftc >/dev/null 2>&1 && swiftc --version >/dev/null 2>&1; then
  run_lang_test swift ./examples/swift/hello.swift
  echo "==> swift: ArgumentParser sample (cli-sap.swift)"
  # First run may print SwiftPM lines to stdout; program output is the last line.
  out="$("${BIN}" swift ./examples/swift/cli-sap.swift World 2>/dev/null | tail -n 1)"
  out="${out%$'\r'}"
  out="${out%$'\n'}"
  [[ "${out}" == "Hello, World!" ]] || fail "swift cli-sap.swift expected 'Hello, World!', got '${out}'"
  echo "==> swift: @main sample (promise.swift)"
  if ! "${BIN}" swift ./examples/swift/promise.swift >/dev/null 2>&1; then
    fail "swift promise.swift exited non-zero"
  fi
else
  echo "==> swift or swiftc missing; skipping Swift smoke tests"
fi
fi

echo "test.sh: all enabled smoke tests passed"

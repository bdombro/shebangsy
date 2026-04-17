#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BIN="${ROOT_DIR}/dist/shebangsy"

cd "${ROOT_DIR}"
./scripts/build.sh

ext_ready() {
  case "$1" in
    nim)
      command -v nim >/dev/null 2>&1 && nim --version >/dev/null 2>&1
      ;;
    go)
      command -v go >/dev/null 2>&1 && go version >/dev/null 2>&1
      ;;
    mojo)
      command -v mojo >/dev/null 2>&1 && mojo --version >/dev/null 2>&1
      ;;
    cpp)
      command -v cmake >/dev/null 2>&1 && cmake --version >/dev/null 2>&1
      ;;
    rs)
      command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1
      ;;
    swift)
      command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1 &&
        command -v swiftc >/dev/null 2>&1 && swiftc --version >/dev/null 2>&1
      ;;
    py)
      command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

lang_for_ext() {
  case "$1" in
    nim) echo nim ;;
    go) echo go ;;
    mojo) echo mojo ;;
    cpp) echo cpp ;;
    rs) echo rs ;;
    swift) echo swift ;;
    py) echo py ;;
    *) return 1 ;;
  esac
}

while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  rel="${path#"${ROOT_DIR}"/}"
  ext="${path##*.}"
  lang="$(lang_for_ext "${ext}")" || {
    echo "test-smoke.sh: unsupported example extension .${ext}: ${rel}" >&2
    exit 1
  }

  if ! ext_ready "${lang}"; then
    echo "==> skip ${rel} (${lang} unavailable)"
    continue
  fi

  echo "==> ${rel}"
  case "${rel}" in
    examples/cpp/cli11.cpp)
      "${BIN}" "${path}" hello World >/dev/null
      ;;
    *)
      "${BIN}" "${path}" >/dev/null
      ;;
  esac

# C++ examples share one CMake workspace under ~/.cache/shebangsy/cpp-workspace.
# Run examples/cpp/hello.cpp before other .cpp files so a prior CLI11 build does
# not leave the wrong binary as the executable for a minimal hello (shebangsy cpp backend).
done < <(
  find "${ROOT_DIR}/examples" \( -path "${ROOT_DIR}/examples/cpp" -prune \) -o \
    -type f \( \
      -name '*.nim' -o -name '*.go' -o -name '*.mojo' -o \
      -name '*.rs' -o -name '*.swift' -o -name '*.py' \
    \) -print | LC_ALL=C sort
  if [[ -f "${ROOT_DIR}/examples/cpp/hello.cpp" ]]; then
    printf '%s\n' "${ROOT_DIR}/examples/cpp/hello.cpp"
  fi
  if [[ -d "${ROOT_DIR}/examples/cpp" ]]; then
    find "${ROOT_DIR}/examples/cpp" -type f -name '*.cpp' ! -name 'hello.cpp' -print |
      LC_ALL=C sort
  fi
)

echo "test-smoke.sh: all runnable examples passed"

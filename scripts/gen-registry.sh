#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
LANG_DIR="${ROOT_DIR}/languages"
OUT_FILE="${LANG_DIR}/generated_registry.nim"

mapfile -t BACKEND_FILES < <(find "${LANG_DIR}" -maxdepth 1 -type f -name '*_backend.nim' -print | sort)

if [[ ${#BACKEND_FILES[@]} -eq 0 ]]; then
  echo "gen-registry.sh: no backend modules found in ${LANG_DIR}" >&2
  exit 1
fi

{
  echo 'import std/[tables, strutils]'
  echo 'import ./common'
  echo ''

  for file in "${BACKEND_FILES[@]}"; do
    mod="$(basename "${file}" .nim)"
    echo "import ./${mod}"
  done

  echo ''
  echo 'proc registryLoad*(): Table[string, LanguageRunner] ='
  echo '  result = initTable[string, LanguageRunner]()'

  for file in "${BACKEND_FILES[@]}"; do
    mod="$(basename "${file}" .nim)"
    echo "  block:"
    echo "    let runner = ${mod}.createRunner()"
    echo "    result[runner.key.toLowerAscii] = runner"
    echo "    for alias in runner.aliases:"
    echo "      result[alias.toLowerAscii] = runner"
  done
} > "${OUT_FILE}"

echo "gen-registry.sh: wrote ${OUT_FILE}" >&2

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly RELEASE_PACKAGE_NAME="shebangsy"
readonly RELEASE_ASSET_PREFIX="shebangsy"
readonly RELEASE_TARGETS=(
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

die() {
  echo "build-cross.sh: $1" >&2
  exit 1
}

require_nim() {
  command -v nim >/dev/null 2>&1 || die "nim not found on PATH"
}

require_zig() {
  command -v zig >/dev/null 2>&1 || die "zig not found on PATH"
}

zig_cc_wrapper_path() {
  local tmp_dir="$1" zig_target="$2" wrapper
  wrapper="${tmp_dir}/zig-cc-${zig_target//[^a-zA-Z0-9_-]/_}"
  cat >"${wrapper}" <<EOF
#!/usr/bin/env sh
exec zig cc -target ${zig_target} "$@"
EOF
  chmod +x "${wrapper}"
  printf '%s' "${wrapper}"
}

host_macos_target() {
  case "$(uname -m)" in
    arm64) printf '%s' "aarch64-apple-darwin" ;;
    x86_64) printf '%s' "x86_64-apple-darwin" ;;
    *) die "unsupported macOS architecture '$(uname -m)'" ;;
  esac
}

build_host() {
  local source_file="$1" output_binary="$2"
  nim c -d:release --hints:off --verbosity:0 -o:"${output_binary}" "${source_file}"
}

build_linux() {
  local source_file="$1" output_binary="$2" tmp_dir="$3" zig_target="$4" cpu="$5"
  local wrapper
  wrapper="$(zig_cc_wrapper_path "${tmp_dir}" "${zig_target}")"

  nim c -d:release --hints:off --verbosity:0 --passL:-s \
    --os:Linux --cpu:"${cpu}" \
    --cc:clang \
    --clang.exe:"${wrapper}" \
    --clang.linkerexe:"${wrapper}" \
    -o:"${output_binary}" \
    "${source_file}"
}

main() {
  local version="${1:-dev}"
  local source_file="${ROOT_DIR}/shebangsy.nim"
  local dist_dir="${ROOT_DIR}/dist"

  require_nim
  require_zig

  [[ -f "${source_file}" ]] || die "missing source file ${source_file}"

  mkdir -p "${dist_dir}"
  cd "${ROOT_DIR}"
  ./scripts/gen-registry.sh

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${tmp_dir}"' EXIT

  local target binary_name built_binary asset_name asset_path staging_dir zig_target cpu
  binary_name="${RELEASE_PACKAGE_NAME}"

  target="$(host_macos_target)"
  built_binary="${tmp_dir}/build-${target}/${binary_name}"
  mkdir -p "$(dirname "${built_binary}")"
  build_host "${source_file}" "${built_binary}"
  asset_name="${RELEASE_ASSET_PREFIX}-${version}-${target}.zip"
  asset_path="${dist_dir}/${asset_name}"
  staging_dir="${tmp_dir}/stage-${target}"
  mkdir -p "${staging_dir}"
  cp "${built_binary}" "${staging_dir}/${binary_name}"
  (cd "${staging_dir}" && zip -qr "${asset_path}" "${binary_name}")

  for target in "${RELEASE_TARGETS[@]}"; do
    case "${target}" in
      aarch64-unknown-linux-gnu)
        zig_target="aarch64-linux-gnu"
        cpu="arm64"
        ;;
      x86_64-unknown-linux-gnu)
        zig_target="x86_64-linux-gnu"
        cpu="amd64"
        ;;
      *) die "unsupported Linux target ${target}" ;;
    esac

    built_binary="${tmp_dir}/build-${target}/${binary_name}"
    mkdir -p "$(dirname "${built_binary}")"
    build_linux "${source_file}" "${built_binary}" "${tmp_dir}" "${zig_target}" "${cpu}"

    asset_name="${RELEASE_ASSET_PREFIX}-${version}-${target}.zip"
    asset_path="${dist_dir}/${asset_name}"
    staging_dir="${tmp_dir}/stage-${target}"
    mkdir -p "${staging_dir}"
    cp "${built_binary}" "${staging_dir}/${binary_name}"
    (cd "${staging_dir}" && zip -qr "${asset_path}" "${binary_name}")
  done

  echo "build-cross.sh: done. Artifacts in ${dist_dir}/"
}

main "$@"

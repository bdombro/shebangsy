#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly RELEASE_ASSET_PREFIX="shebangsy"

repo_root() {
  cd "${SCRIPT_DIR}" && git rev-parse --show-toplevel
}

die() {
  echo "release.sh: $1" >&2
  exit 1
}

configure_github_repo() {
  local branch remote url rest

  branch="$(git branch --show-current 2>/dev/null || true)"
  [[ -n "${branch}" ]] || die "detached HEAD; checkout a branch first"

  remote="$(git config --get "branch.${branch}.remote" || true)"
  [[ -n "${remote}" ]] || remote="origin"

  url="$(git remote get-url "${remote}" 2>/dev/null)" || die "could not read URL for remote '${remote}'"
  url="${url%.git}"

  if [[ "${url}" =~ ^git@([^:]+):(.+)$ ]]; then
    GH_HOST="${BASH_REMATCH[1]}"
    GH_REPO="${BASH_REMATCH[2]}"
  elif [[ "${url}" =~ ^https?:// ]]; then
    rest="${url#*://}"
    rest="${rest#*@}"
    GH_HOST="${rest%%/*}"
    GH_REPO="${rest#*/}"
    GH_REPO="${GH_REPO%%\?*}"
  fi

  [[ -n "${GH_REPO:-}" ]] || die "cannot parse GitHub owner/repo from remote '${remote}': ${url}"

  if [[ "${GH_HOST:-}" == "github.com" || "${GH_HOST:-}" == "ssh.github.com" ]]; then
    unset GH_HOST
    export GH_REPO
  else
    export GH_HOST GH_REPO
  fi
}

resolve_version() {
  local ver_raw="$1" bump latest t major minor patch prefix ver

  case "${ver_raw}" in
    patch|minor|major)
      bump="${ver_raw}"
      latest="$(gh api "repos/${GH_REPO}/releases/latest" --jq .tag_name 2>/dev/null || true)"
      if [[ -z "${latest:-}" ]]; then
        case "${bump}" in
          patch) ver="0.0.1" ;;
          minor) ver="0.1.0" ;;
          major) ver="1.0.0" ;;
        esac
      else
        prefix=""
        [[ "${latest}" == v* ]] && prefix="v"
        t="${latest#v}"
        if [[ "${t}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
          major="${BASH_REMATCH[1]}"
          minor="${BASH_REMATCH[2]}"
          patch="${BASH_REMATCH[3]}"
          case "${bump}" in
            patch) ver="${prefix}${major}.${minor}.$((10#${patch} + 1))" ;;
            minor) ver="${prefix}${major}.$((10#${minor} + 1)).0" ;;
            major) ver="${prefix}$((10#${major} + 1)).0.0" ;;
          esac
        else
          die "latest release tag '${latest}' is not semver"
        fi
      fi
      ;;
    *)
      ver="${ver_raw}"
      ;;
  esac

  printf '%s' "${ver}"
}

git_annotated_release_tag_add() {
  local tag="$1"
  git tag -af "${tag}" -m "shebangsy ${tag}"
  git push --force origin "${tag}"
}

print_help() {
  cat <<'EOF'
Usage: release.sh <version | patch | minor | major>
       release.sh --print-version <version | patch | minor | major>
EOF
}

main() {
  local version dist_dir

  if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_help
    return 0
  fi

  cd "$(repo_root)"
  configure_github_repo

  if [[ "${1:-}" == "--print-version" ]]; then
    [[ $# -ge 2 ]] || die "usage: release.sh --print-version <version | patch | minor | major>"
    resolve_version "${2}"
    return 0
  fi

  version="$(resolve_version "${1}")"

  dist_dir="${ROOT_DIR}/dist"
  [[ -d "${dist_dir}" ]] || die "missing dist dir ${dist_dir}; run scripts/build-cross.sh ${version} first"

  ASSETS=()
  shopt -s nullglob
  ASSETS=("${dist_dir}/${RELEASE_ASSET_PREFIX}-${version}"-*.zip)
  shopt -u nullglob
  [[ ${#ASSETS[@]} -ge 1 ]] || die "no zips matching ${dist_dir}/${RELEASE_ASSET_PREFIX}-${version}-*.zip"

  git_annotated_release_tag_add "${version}"
  gh release create "${version}" "${ASSETS[@]}" --generate-notes
}

main "$@"

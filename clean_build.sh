#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

info() {
  printf '[clean-build] %s\n' "$1"
}

remove_path() {
  local target="$1"
  if [[ -e "${target}" ]]; then
    info "removing ${target#${REPO_ROOT}/}"
    rm -rf -- "${target}"
  fi
}

# primary build output directories
remove_path "${REPO_ROOT}/target"
remove_path "${REPO_ROOT}/build"
remove_path "${REPO_ROOT}/artifacts"
remove_path "${REPO_ROOT}/.cache/StarryOS"

# per-case build caches and artifacts
while IFS= read -r -d '' dir; do
  remove_path "${dir}"
done < <(find "${REPO_ROOT}/tests" -type d \( -name target -o -name artifacts \) -print0)

info "build artifacts cleaned"

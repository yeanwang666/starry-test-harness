#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUITE=${1:-ci-test}
ARCH=${ARCH:-aarch64}
STARRYOS_REMOTE=${STARRYOS_REMOTE:-https://github.com/yeanwang666/StarryOS.git}
STARRYOS_REF=${STARRYOS_REF:-main}
STARRYOS_ROOT=${STARRYOS_ROOT:-${REPO_ROOT}/.cache/StarryOS}
STARRYOS_DEPTH=${STARRYOS_DEPTH:-0}
ARTIFACT_DIR="${REPO_ROOT}/artifacts/${SUITE}"
LOG_FILE="${ARTIFACT_DIR}/build.log"

if [[ "${STARRYOS_ROOT}" != /* ]]; then
  STARRYOS_ROOT="${REPO_ROOT}/${STARRYOS_ROOT}"
fi

mkdir -p "${ARTIFACT_DIR}" "$(dirname "${STARRYOS_ROOT}")"
: >"${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
  echo "[build:starry] $*"
}

clone_or_update_repo() {
  if [[ ! -d "${STARRYOS_ROOT}/.git" ]]; then
    log "Cloning StarryOS from ${STARRYOS_REMOTE}"
    depth_args=()
    if [[ "${STARRYOS_DEPTH}" != "0" ]]; then
      depth_args=(--depth "${STARRYOS_DEPTH}")
    fi
    git clone "${depth_args[@]}" --recursive --single-branch --branch "${STARRYOS_REF}" "${STARRYOS_REMOTE}" "${STARRYOS_ROOT}"
  else
    log "Updating existing StarryOS repo at ${STARRYOS_ROOT}"
    git -C "${STARRYOS_ROOT}" fetch origin --tags --prune
    git -C "${STARRYOS_ROOT}" checkout "${STARRYOS_REF}"
    git -C "${STARRYOS_ROOT}" pull --ff-only origin "${STARRYOS_REF}"
    git -C "${STARRYOS_ROOT}" submodule sync --recursive
    git -C "${STARRYOS_ROOT}" submodule update --init --recursive
  fi
}

clone_or_update_repo

STARRYOS_COMMIT=$(git -C "${STARRYOS_ROOT}" rev-parse HEAD)
log "StarryOS commit: ${STARRYOS_COMMIT}"

pushd "${STARRYOS_ROOT}" >/dev/null
log "Building StarryOS (ARCH=${ARCH})"
make ARCH="${ARCH}" build
log "Preparing rootfs image"
make ARCH="${ARCH}" img
popd >/dev/null

log "Copying build artifacts"
shopt -s nullglob
for artifact in "${STARRYOS_ROOT}"/StarryOS_"${ARCH}"*-qemu-virt.*; do
  cp "${artifact}" "${ARTIFACT_DIR}/"
  log "  -> $(basename "${artifact}")"
done
shopt -u nullglob

cat >"${ARTIFACT_DIR}/build.info" <<META
suite=${SUITE}
arch=${ARCH}
stamp=$(date -u +%Y%m%d-%H%M%S)
starryos_remote=${STARRYOS_REMOTE}
starryos_ref=${STARRYOS_REF}
starryos_root=${STARRYOS_ROOT}
starryos_commit=${STARRYOS_COMMIT}
META

log "StarryOS 构建完成，产物位于 ${ARTIFACT_DIR}"

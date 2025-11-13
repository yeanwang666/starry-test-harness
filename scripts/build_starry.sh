#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUITE=${1:-ci-test}
ARCH=${ARCH:-aarch64}

STARRYOS_REMOTE="${STARRYOS_REMOTE:-https://github.com/kylin-x-kernel/StarryOS.git}"
STARRYOS_COMMIT="${STARRYOS_REF:-${STARRYOS_COMMIT:-main}}"
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
    git clone --recursive "${STARRYOS_REMOTE}" "${STARRYOS_ROOT}"
  else
    log "Updating existing StarryOS repo at ${STARRYOS_ROOT}"
    git -C "${STARRYOS_ROOT}" fetch origin --tags --prune
  fi
  git -C "${STARRYOS_ROOT}" checkout "${STARRYOS_COMMIT}"
  git -C "${STARRYOS_ROOT}" submodule sync --recursive
  git -C "${STARRYOS_ROOT}" submodule update --init --recursive
}

clone_or_update_repo

STARRYOS_COMMIT=$(git -C "${STARRYOS_ROOT}" rev-parse HEAD)
log "StarryOS commit: ${STARRYOS_COMMIT}"

if ! command -v rustup >/dev/null 2>&1; then
  log "rustup not found, please install Rust toolchains before running build"
  exit 1
fi
if [[ -n "${STARRYOS_TOOLCHAIN:-}" ]]; then
  export RUSTUP_TOOLCHAIN="${STARRYOS_TOOLCHAIN}"
  log "Using override toolchain ${RUSTUP_TOOLCHAIN}"
fi
log "Rust toolchain will follow ${STARRYOS_ROOT}/rust-toolchain.toml (auto-managed by rustup)"
ACTIVE_TOOLCHAIN="$(rustup show active-toolchain 2>/dev/null | tr -d '\r')"
if [[ -n "${ACTIVE_TOOLCHAIN}" ]]; then
  log "Active toolchain: ${ACTIVE_TOOLCHAIN}"
fi

pushd "${STARRYOS_ROOT}" >/dev/null
log "Building StarryOS (ARCH=${ARCH})"
make ARCH="${ARCH}" build

# Download rootfs template with cache directory support
ROOTFS_CACHE_DIR="${ROOTFS_CACHE_DIR:-${REPO_ROOT}/.cache/rootfs}"
mkdir -p "${ROOTFS_CACHE_DIR}"
log "Ensuring rootfs template is available in ${ROOTFS_CACHE_DIR}"
IMG_VERSION="${ROOTFS_VERSION:-20250917}"
IMG_URL="https://github.com/Starry-OS/rootfs/releases/download/${IMG_VERSION}"
IMG="rootfs-${ARCH}.img"
IMG_PATH="${ROOTFS_CACHE_DIR}/${IMG}"
if [[ ! -f "${IMG_PATH}" ]]; then
  log "Downloading rootfs template ${IMG} (version ${IMG_VERSION})"
  curl -f -L "${IMG_URL}/${IMG}.xz" -o "${IMG_PATH}.xz"
  xz -d "${IMG_PATH}.xz"
fi
log "Rootfs template ready: ${IMG_PATH}"

# Copy rootfs template to StarryOS root for test scripts
STARRYOS_IMG="${STARRYOS_ROOT}/${IMG}"
if [[ ! -f "${STARRYOS_IMG}" ]] || [[ "${IMG_PATH}" -nt "${STARRYOS_IMG}" ]]; then
  log "Copying rootfs template to ${STARRYOS_IMG}"
  cp "${IMG_PATH}" "${STARRYOS_IMG}"
fi
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
starryos_ref=${STARRYOS_REF:-}
starryos_root=${STARRYOS_ROOT}
starryos_commit=${STARRYOS_COMMIT}
META

log "StarryOS 构建完成，产物位于 ${ARTIFACT_DIR}"

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

HOST_TRIPLE="$(rustc -Vv 2>/dev/null | awk '/^host:/ {print $2}')"
if [[ -z "${HOST_TRIPLE}" ]]; then
  HOST_TRIPLE="x86_64-unknown-linux-gnu"
fi
if [[ -n "${STARRYOS_TOOLCHAIN:-}" ]]; then
  DEFAULT_TOOLCHAIN="${STARRYOS_TOOLCHAIN}"
else
  TOOLCHAIN_DATE_DEFAULT="2025-05-05"
  if [[ "${HOST_TRIPLE}" == "x86_64-unknown-linux-gnu" ]]; then
    TOOLCHAIN_DATE_DEFAULT="2024-10-15"
  fi
  TOOLCHAIN_DATE="${STARRYOS_TOOLCHAIN_DATE:-${TOOLCHAIN_DATE_DEFAULT}}"
  DEFAULT_TOOLCHAIN="nightly-${TOOLCHAIN_DATE}-${HOST_TRIPLE}"
fi
if ! command -v rustup >/dev/null 2>&1; then
  log "rustup not found, please install Rust toolchains before running build"
  exit 1
fi
if ! rustup toolchain list | grep -q "${DEFAULT_TOOLCHAIN}"; then
  log "Installing Rust toolchain ${DEFAULT_TOOLCHAIN}"
  rustup toolchain install "${DEFAULT_TOOLCHAIN}"
fi
if [[ -z "${RUSTUP_TOOLCHAIN:-}" ]]; then
  export RUSTUP_TOOLCHAIN="${DEFAULT_TOOLCHAIN}"
  log "Using Rust toolchain ${RUSTUP_TOOLCHAIN}"
elif [[ "${RUSTUP_TOOLCHAIN}" != nightly* ]]; then
  log "Toolchain ${RUSTUP_TOOLCHAIN} is not nightly; switching to ${DEFAULT_TOOLCHAIN}"
  export RUSTUP_TOOLCHAIN="${DEFAULT_TOOLCHAIN}"
else
  log "Using pre-set Rust toolchain ${RUSTUP_TOOLCHAIN}"
fi

if ! rustup target list --toolchain "${RUSTUP_TOOLCHAIN}" --installed | grep -q "aarch64-unknown-none-softfloat"; then
  log "Installing target aarch64-unknown-none-softfloat for ${RUSTUP_TOOLCHAIN}"
  rustup target add --toolchain "${RUSTUP_TOOLCHAIN}" aarch64-unknown-none-softfloat
fi
if ! rustup component list --toolchain "${RUSTUP_TOOLCHAIN}" --installed | grep -q "llvm-tools-preview"; then
  log "Installing llvm-tools-preview for ${RUSTUP_TOOLCHAIN}"
  rustup component add --toolchain "${RUSTUP_TOOLCHAIN}" llvm-tools-preview
fi

pushd "${STARRYOS_ROOT}" >/dev/null
log "Building StarryOS (ARCH=${ARCH})"
make ARCH="${ARCH}" build

# Download rootfs template if not exists (but don't copy to arceos/disk.img yet)
log "Ensuring rootfs template is available"
IMG_URL="https://github.com/Starry-OS/rootfs/releases/download/20250917"
IMG="rootfs-${ARCH}.img"
if [[ ! -f "${IMG}" ]]; then
  log "Downloading rootfs template for ${ARCH}"
  curl -f -L "${IMG_URL}/${IMG}.xz" -O
  xz -d "${IMG}.xz"
fi
log "Rootfs template ready: ${IMG}"
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

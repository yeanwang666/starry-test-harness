#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ARCH=${ARCH:-aarch64}
STARRYOS_ROOT=${STARRYOS_ROOT:-${REPO_ROOT}/.cache/StarryOS}
VM_RUNNER=${STARRY_VM_RUNNER:-${CI_TEST_RUNNER:-${REPO_ROOT}/scripts/starry_vm_runner.py}}

if [[ "${STARRYOS_ROOT}" != /* ]]; then
  STARRYOS_ROOT="${REPO_ROOT}/${STARRYOS_ROOT}"
fi

ROOTFS_CACHE_DIR="${ROOTFS_CACHE_DIR:-${REPO_ROOT}/.cache/rootfs}"
ROOTFS_TEMPLATE="${ROOTFS_CACHE_DIR}/rootfs-${ARCH}.img"
CLEANUP_DISK=0

if [[ ! -f "${ROOTFS_TEMPLATE}" ]]; then
  echo "[starry-boot] rootfs template missing: ${ROOTFS_TEMPLATE}" >&2
  exit 1
fi

TMP_DISK="$(mktemp /tmp/starry-boot-disk-XXXXXX.img)"
CLEANUP_DISK=1
trap 'if (( CLEANUP_DISK )); then rm -f "'"${TMP_DISK}"'" || true; fi' EXIT
if ! cp "${ROOTFS_TEMPLATE}" "${TMP_DISK}"; then
  if ! sudo cp "${ROOTFS_TEMPLATE}" "${TMP_DISK}"; then
    echo "[starry-boot] 无法复制 rootfs 模板到 ${TMP_DISK}" >&2
    exit 1
  fi
fi

if ! chmod 666 "${TMP_DISK}"; then
  if ! sudo chmod 666 "${TMP_DISK}"; then
    echo "[starry-boot] 无法修改临时磁盘权限：${TMP_DISK}" >&2
    exit 1
  fi
fi

export DISK_IMG="${TMP_DISK}"

echo "[starry-boot] 使用 StarryOS 路径: ${STARRYOS_ROOT}"

if [[ ! -d "${STARRYOS_ROOT}" ]]; then
  echo "[starry-boot] 未找到 StarryOS 仓库：${STARRYOS_ROOT}" >&2
  exit 1
fi

if [[ ! -x "${VM_RUNNER}" ]]; then
  echo "[starry-boot] 未找到 starry_vm_runner：${VM_RUNNER}" >&2
  exit 1
fi

python3 "${VM_RUNNER}" --root "${STARRYOS_ROOT}" --arch "${ARCH}"

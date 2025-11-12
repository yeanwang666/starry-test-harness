#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "用法: $0 <binary-name> [dest-path]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CRATE_DIR="${WORKSPACE}/tests/ci/cases"
TARGET_DIR="${WORKSPACE}/target/ci-cases"

BINARY_NAME="$1"
DEST_PATH="${2:-/usr/tests/${BINARY_NAME}}"
CASE_LABEL="${STARRY_CASE_NAME:-${BINARY_NAME}}"

RUN_ID="${STARRY_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${STARRY_RUN_DIR:-${WORKSPACE}/logs/ci/${RUN_ID}}"
CASE_ARTIFACT_DIR="${STARRY_CASE_ARTIFACT_DIR:-${RUN_DIR}/artifacts/${BINARY_NAME}}"

TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-unknown-linux-musl}"

# Remote change: Check for cross-compiler before proceeding
if [[ "${TARGET_TRIPLE}" == "aarch64-unknown-linux-musl" ]]; then
  REQUIRED_LINKER="aarch64-linux-musl-gcc"
  LINKER_ENV="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER:-}"
  if [[ -n "${LINKER_ENV}" ]]; then
    LINKER_BIN="${LINKER_ENV%% *}"
    if ! command -v "${LINKER_BIN}" >/dev/null 2>&1; then
      echo "[${CASE_LABEL}] CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=${LINKER_ENV} 但未找到可执行文件" >&2
      exit 1
    fi
  elif [[ -n "${CC_aarch64_unknown_linux_musl:-}" ]]; then
    if ! command -v "${CC_aarch64_unknown_linux_musl}" >/dev/null 2>&1; then
      echo "[${CASE_LABEL}] CC_aarch64_unknown_linux_musl=${CC_aarch64_unknown_linux_musl} 但未找到可执行文件" >&2
      exit 1
    fi
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${CC_aarch64_unknown_linux_musl}"
  elif command -v "${REQUIRED_LINKER}" >/dev/null 2>&1; then
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${REQUIRED_LINKER}"
  else
    cat >&2 <<MSG
[${CASE_LABEL}] 未检测到 aarch64 musl 交叉编译器。
请安装 ${REQUIRED_LINKER} 或设置 CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER/CC_aarch64_unknown_linux_musl 后重试。
MSG
    exit 1
  fi
fi

mkdir -p "${CASE_ARTIFACT_DIR}"
export CARGO_TARGET_DIR="${TARGET_DIR}"

HOST_BIN="${TARGET_DIR}/release/${BINARY_NAME}"
TARGET_BIN="${TARGET_DIR}/${TARGET_TRIPLE}/release/${BINARY_NAME}"
HOST_LOG="${CASE_ARTIFACT_DIR}/host-${RUN_ID}.log"

if [[ ! -f "${CRATE_DIR}/Cargo.toml" ]]; then
  echo "[${CASE_LABEL}] 未找到 Rust 测试工程：${CRATE_DIR}" >&2
  exit 1
fi

echo "[${CASE_LABEL}] 构建 host 版本" >&2
cargo build --manifest-path "${CRATE_DIR}/Cargo.toml" --release --bin "${BINARY_NAME}"

if [[ ! -x "${HOST_BIN}" ]]; then
  echo "[${CASE_LABEL}] 构建后未找到主机可执行文件 ${HOST_BIN}" >&2
  exit 1
fi

echo "[${CASE_LABEL}] 运行 host 版本 -> ${HOST_LOG}" >&2
if ! "${HOST_BIN}" | tee "${HOST_LOG}"; then
  echo "[${CASE_LABEL}] 主机版执行失败，详见 ${HOST_LOG}" >&2
  exit 1
fi

if [[ "${SKIP_DISK_IMAGE:-0}" == "1" ]]; then
  echo "[${CASE_LABEL}] SKIP_DISK_IMAGE=1，跳过写入磁盘镜像" >&2
  exit 0
fi

# Your change: Create fresh disk image from template
STARRYOS_ROOT="${STARRYOS_ROOT:-${SCRIPT_DIR}/../../.cache/StarryOS}"
ARCH="${ARCH:-aarch64}"
ROOTFS_TEMPLATE="${STARRYOS_ROOT}/rootfs-${ARCH}.img"
CLEANUP_DISK=0

if [[ ! -f "${ROOTFS_TEMPLATE}" ]]; then
  echo "[${CASE_LABEL}] rootfs template not found: ${ROOTFS_TEMPLATE}" >&2
  echo "[${CASE_LABEL}] run the build script first to download it" >&2
  exit 1
fi

if [[ -n "${STARRYOS_DISK_IMAGE:-}" ]]; then
  DISK_IMAGE="${STARRYOS_DISK_IMAGE}"
  if [[ "${DISK_IMAGE}" != /* ]]; then
    DISK_IMAGE="${WORKSPACE}/${STARRYOS_DISK_IMAGE}"
  fi
  mkdir -p "$(dirname "${DISK_IMAGE}")"
else
  DISK_IMAGE="$(mktemp /tmp/starry-disk-XXXXXX.img)"
  CLEANUP_DISK=1
  trap 'if (( CLEANUP_DISK )); then rm -f "${DISK_IMAGE}"; fi' EXIT
fi
export DISK_IMG="${DISK_IMAGE}"

echo "[${CASE_LABEL}] creating fresh disk image from template" >&2
mkdir -p "$(dirname "${DISK_IMAGE}")"
if ! cp "${ROOTFS_TEMPLATE}" "${DISK_IMAGE}"; then
  if ! sudo cp "${ROOTFS_TEMPLATE}" "${DISK_IMAGE}"; then
    echo "[${CASE_LABEL}] failed to copy rootfs template into ${DISK_IMAGE}" >&2
    exit 1
  fi
fi
if ! chmod 666 "${DISK_IMAGE}"; then
  if ! sudo chmod 666 "${DISK_IMAGE}"; then
    echo "[${CASE_LABEL}] failed to adjust permissions on ${DISK_IMAGE}" >&2
    exit 1
  fi
fi

if [[ ! -f "${DISK_IMAGE}" ]]; then
  echo "[${CASE_LABEL}] failed to create disk image: ${DISK_IMAGE}" >&2
  exit 1
fi

if ! command -v debugfs >/dev/null 2>&1; then
  echo "[${CASE_LABEL}] 未检测到 debugfs，请安装 e2fsprogs" >&2
  exit 1
fi

if ! rustup target list --installed | grep -q "^${TARGET_TRIPLE}$"; then
  echo "[${CASE_LABEL}] 安装 Rust 目标 ${TARGET_TRIPLE}" >&2
  rustup target add "${TARGET_TRIPLE}"
fi

echo "[${CASE_LABEL}] 构建 ${TARGET_TRIPLE} 版本" >&2
cargo build \
  --manifest-path "${CRATE_DIR}/Cargo.toml" \
  --release \
  --bin "${BINARY_NAME}" \
  --target "${TARGET_TRIPLE}"

if [[ ! -f "${TARGET_BIN}" ]]; then
  echo "[${CASE_LABEL}] 未找到交叉编译产物 ${TARGET_BIN}" >&2
  exit 1
fi

echo "[${CASE_LABEL}] 写入磁盘镜像 -> ${DEST_PATH}" >&2

# Your change: Use sudo for debugfs if needed and use cd + write
DEBUGFS_CMD="debugfs"
if [[ ! -w "${DISK_IMAGE}" ]]; then
  echo "[${CASE_LABEL}] disk image not writable, using sudo for debugfs" >&2
  DEBUGFS_CMD="sudo debugfs"
fi

${DEBUGFS_CMD} -w "${DISK_IMAGE}" -R "mkdir /usr" >/dev/null 2>&1 || true
${DEBUGFS_CMD} -w "${DISK_IMAGE}" -R "mkdir /usr/tests" >/dev/null 2>&1 || true

# debugfs write command requires cd to target directory first
DEST_FILENAME=$(basename "${DEST_PATH}")
if ! ${DEBUGFS_CMD} -w "${DISK_IMAGE}" << EOF
cd /usr/tests
rm ${DEST_FILENAME}
write ${TARGET_BIN} ${DEST_FILENAME}
quit
EOF
then
  echo "[${CASE_LABEL}] failed to write binary to disk image" >&2
  exit 1
fi

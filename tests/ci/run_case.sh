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
DEST_PATH_RAW="${2:-/usr/tests/${BINARY_NAME}}"
if [[ "${DEST_PATH_RAW}" != /* ]]; then
  DEST_PATH="/usr/tests/${DEST_PATH_RAW}"
else
  DEST_PATH="${DEST_PATH_RAW}"
fi
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

if [[ ! -f "${CRATE_DIR}/Cargo.toml" ]]; then
  echo "[${CASE_LABEL}] 未找到 Rust 测试工程：${CRATE_DIR}" >&2
  exit 1
fi

if [[ "${SKIP_DISK_IMAGE:-0}" == "1" ]]; then
  echo "[${CASE_LABEL}] SKIP_DISK_IMAGE=1，跳过写入磁盘镜像" >&2
  exit 0
fi

# Your change: Create fresh disk image from template
STARRYOS_ROOT="${STARRYOS_ROOT:-${SCRIPT_DIR}/../../.cache/StarryOS}"
if [[ "${STARRYOS_ROOT}" != /* ]]; then
  STARRYOS_ROOT="${WORKSPACE}/${STARRYOS_ROOT}"
fi
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

echo "[${CASE_LABEL}] 构建 ${TARGET_TRIPLE} 测试二进制" >&2
cargo test \
  --manifest-path "${CRATE_DIR}/Cargo.toml" \
  --release \
  --no-run \
  --test "${BINARY_NAME}" \
  --target "${TARGET_TRIPLE}"

TARGET_DEPS_DIR="${TARGET_DIR}/${TARGET_TRIPLE}/release/deps"
TARGET_TEST_BIN="$(find "${TARGET_DEPS_DIR}" -maxdepth 1 -type f -perm -111 -name "${BINARY_NAME}-*" | sort | head -n 1 || true)"

if [[ -z "${TARGET_TEST_BIN}" ]]; then
  echo "[${CASE_LABEL}] 未找到交叉编译测试产物 ${TARGET_DEPS_DIR}/${BINARY_NAME}-*" >&2
  exit 1
fi

cp "${TARGET_TEST_BIN}" "${CASE_ARTIFACT_DIR}/${BINARY_NAME}" 2>/dev/null || true
TARGET_TEST_BIN="${TARGET_TEST_BIN}"

echo "[${CASE_LABEL}] 写入磁盘镜像 -> ${DEST_PATH}" >&2

# Your change: Use sudo for debugfs if needed and use cd + write
DEBUGFS_CMD="debugfs"
if [[ ! -w "${DISK_IMAGE}" ]]; then
  echo "[${CASE_LABEL}] disk image not writable, using sudo for debugfs" >&2
  DEBUGFS_CMD="sudo debugfs"
fi

DEST_DIR=$(dirname "${DEST_PATH}")
DEST_FILENAME=$(basename "${DEST_PATH}")

IFS='/' read -ra DEST_SEGMENTS <<< "${DEST_DIR}"
CURRENT=""
for SEGMENT in "${DEST_SEGMENTS[@]}"; do
  [[ -z "${SEGMENT}" ]] && continue
  CURRENT+="/${SEGMENT}"
  ${DEBUGFS_CMD} -w "${DISK_IMAGE}" -R "mkdir ${CURRENT}" >/dev/null 2>&1 || true
done

# debugfs write command requires cd to target directory first
if ! ${DEBUGFS_CMD} -w "${DISK_IMAGE}" << EOF
cd ${DEST_DIR}
rm ${DEST_FILENAME}
write ${TARGET_TEST_BIN} ${DEST_FILENAME}
quit
EOF
then
  echo "[${CASE_LABEL}] failed to write binary to disk image" >&2
  exit 1
fi

VM_RUNNER="${STARRY_VM_RUNNER:-${CI_TEST_RUNNER:-${WORKSPACE}/scripts/starry_vm_runner.py}}"
if [[ ! -x "${VM_RUNNER}" ]]; then
  echo "[${CASE_LABEL}] 未找到 starry_vm_runner：${VM_RUNNER}" >&2
  exit 1
fi

COMMAND_TIMEOUT="${STARRY_CASE_TIMEOUT_SECS:-600}"
VM_STDOUT="${CASE_ARTIFACT_DIR}/vm-${RUN_ID}.log"
VM_STDERR="${CASE_ARTIFACT_DIR}/vm-${RUN_ID}.err"

echo "[${CASE_LABEL}] 启动 StarryOS 执行 ${DEST_PATH}" >&2
if ! python3 "${VM_RUNNER}" \
  --root "${STARRYOS_ROOT}" \
  --arch "${ARCH}" \
  --command "${DEST_PATH}" \
  --command-timeout "${COMMAND_TIMEOUT}" \
  2> >(tee "${VM_STDERR}" >&2) | tee "${VM_STDOUT}"; then
  echo "[${CASE_LABEL}] 虚拟机执行失败，详见 ${VM_STDERR}" >&2
  # Your change: find the exact error case
  FAILED_TESTS=$(grep -E '^test .* \.\.\. FAILED$' "${VM_STDOUT}" || true)
  if [[ -n "${FAILED_TESTS}" ]]; then
    echo "[${CASE_LABEL}] 发现以下失败的测试用例：" >&2
    echo "${FAILED_TESTS}" >&2
  fi
  exit 1
fi

echo "[${CASE_LABEL}] StarryOS 执行完成，日志已写入 ${VM_STDOUT}" >&2

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
DISK_IMAGE="${STARRYOS_DISK_IMAGE:-${WORKSPACE}/.cache/StarryOS/arceos/disk.img}"

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

if [[ ! -f "${DISK_IMAGE}" ]]; then
  echo "[${CASE_LABEL}] 未找到磁盘镜像：${DISK_IMAGE}" >&2
  exit 1
fi

if [[ ! -w "${DISK_IMAGE}" ]]; then
  echo "[${CASE_LABEL}] 当前用户无权写入磁盘镜像 ${DISK_IMAGE}" >&2
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
debugfs -w "${DISK_IMAGE}" -R "mkdir /usr" >/dev/null 2>&1 || true
debugfs -w "${DISK_IMAGE}" -R "mkdir /usr/tests" >/dev/null 2>&1 || true
debugfs -w "${DISK_IMAGE}" -R "unlink ${DEST_PATH}" >/dev/null 2>&1 || true
debugfs -w "${DISK_IMAGE}" -R "write ${TARGET_BIN} ${DEST_PATH}" >/dev/null


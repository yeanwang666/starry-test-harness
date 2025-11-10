#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ARCH=${ARCH:-aarch64}
STARRYOS_ROOT=${STARRYOS_ROOT:-${REPO_ROOT}/.cache/StarryOS}
CI_TEST_RUNNER=${CI_TEST_RUNNER:-${REPO_ROOT}/scripts/starry_ci_runner.py}

if [[ "${STARRYOS_ROOT}" != /* ]]; then
  STARRYOS_ROOT="${REPO_ROOT}/${STARRYOS_ROOT}"
fi

echo "[starry-boot] 使用 StarryOS 路径: ${STARRYOS_ROOT}"

if [[ ! -d "${STARRYOS_ROOT}" ]]; then
  echo "[starry-boot] 未找到 StarryOS 仓库：${STARRYOS_ROOT}" >&2
  exit 1
fi

if [[ ! -x "${CI_TEST_RUNNER}" ]]; then
  echo "[starry-boot] 未找到 starry_ci_runner：${CI_TEST_RUNNER}" >&2
  exit 1
fi

python3 "${CI_TEST_RUNNER}" --root "${STARRYOS_ROOT}" --arch "${ARCH}"

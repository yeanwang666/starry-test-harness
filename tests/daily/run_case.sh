#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <case-id> [args...]" >&2
  exit 1
fi

CASE_ID="$1"
shift || true
CASE_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${STARRY_WORKSPACE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CASE_DIR="${SCRIPT_DIR}/cases/${CASE_ID}"

if [[ ! -d "${CASE_DIR}" ]]; then
  echo "[daily] case directory not found: ${CASE_DIR}" >&2
  exit 1
fi

MANIFEST_PATH="${CASE_DIR}/Cargo.toml"
if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "[daily] missing Cargo.toml in ${CASE_DIR}" >&2
  exit 1
fi

PACKAGE_NAME="$(
  cargo metadata \
    --manifest-path "${MANIFEST_PATH}" \
    --format-version 1 \
    --no-deps \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["packages"][0]["name"])'
)"

TARGET_DIR="${WORKSPACE_ROOT}/target/daily-cases"
ARTIFACT_DIR="${STARRY_CASE_ARTIFACT_DIR:-${CASE_DIR}/artifacts}"
mkdir -p "${TARGET_DIR}" "${ARTIFACT_DIR}"

TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
if ! rustup target list --installed | grep -q "^${TARGET_TRIPLE}$"; then
  echo "[daily] installing Rust target ${TARGET_TRIPLE}" >&2
  rustup target add "${TARGET_TRIPLE}"
fi

echo "[daily] building ${PACKAGE_NAME} for ${TARGET_TRIPLE}" >&2
CARGO_TARGET_DIR="${TARGET_DIR}" \
  cargo build --manifest-path "${MANIFEST_PATH}" --release --target "${TARGET_TRIPLE}"

TARGET_BIN="${TARGET_DIR}/${TARGET_TRIPLE}/release/${PACKAGE_NAME}"
if [[ ! -f "${TARGET_BIN}" ]]; then
  echo "[daily] expected target binary not found: ${TARGET_BIN}" >&2
  exit 1
fi

STARRYOS_ROOT="${STARRYOS_ROOT:-${WORKSPACE_ROOT}/.cache/StarryOS}"
if [[ "${STARRYOS_ROOT}" != /* ]]; then
  STARRYOS_ROOT="${WORKSPACE_ROOT}/${STARRYOS_ROOT}"
fi

# Create fresh disk image from template for each test run
ARCH="${ARCH:-aarch64}"
ROOTFS_TEMPLATE="${STARRYOS_ROOT}/rootfs-${ARCH}.img"
CLEANUP_DISK=0

if [[ ! -f "${ROOTFS_TEMPLATE}" ]]; then
  echo "[daily] rootfs template not found: ${ROOTFS_TEMPLATE}" >&2
  echo "[daily] run the build script first to download it" >&2
  exit 1
fi

if [[ -n "${STARRYOS_DISK_IMAGE:-}" ]]; then
  DISK_IMAGE="${STARRYOS_DISK_IMAGE}"
  if [[ "${DISK_IMAGE}" != /* ]]; then
    DISK_IMAGE="${WORKSPACE_ROOT}/${DISK_IMAGE}"
  fi
  mkdir -p "$(dirname "${DISK_IMAGE}")"
else
  DISK_IMAGE="$(mktemp /tmp/starry-disk-XXXXXX.img)"
  CLEANUP_DISK=1
  trap 'if (( CLEANUP_DISK )); then rm -f "${DISK_IMAGE}"; fi' EXIT
fi
export DISK_IMG="${DISK_IMAGE}"

echo "[daily] creating fresh disk image from template" >&2
mkdir -p "$(dirname "${DISK_IMAGE}")"
if ! cp "${ROOTFS_TEMPLATE}" "${DISK_IMAGE}"; then
  if ! sudo cp "${ROOTFS_TEMPLATE}" "${DISK_IMAGE}"; then
    echo "[daily] failed to copy rootfs template into ${DISK_IMAGE}" >&2
    exit 1
  fi
fi
if ! chmod 666 "${DISK_IMAGE}"; then
  if ! sudo chmod 666 "${DISK_IMAGE}"; then
    echo "[daily] failed to adjust permissions on ${DISK_IMAGE}" >&2
    exit 1
  fi
fi

if [[ ! -f "${DISK_IMAGE}" ]]; then
  echo "[daily] failed to create disk image: ${DISK_IMAGE}" >&2
  exit 1
fi
if ! command -v debugfs >/dev/null 2>&1; then
  echo "[daily] debugfs is required to inject binaries" >&2
  exit 1
fi

REMOTE_ROOT="${STARRYOS_TEST_PATH:-/usr/tests}"
if [[ "${REMOTE_ROOT}" != /* ]]; then
  REMOTE_ROOT="/${REMOTE_ROOT}"
fi
REMOTE_ROOT="${REMOTE_ROOT%/}"
REMOTE_PATH="${REMOTE_ROOT}/${CASE_ID}"

DEBUGFS_CMD="debugfs"
if [[ ! -w "${DISK_IMAGE}" ]]; then
  echo "[daily] disk image not writable, using sudo for debugfs" >&2
  DEBUGFS_CMD="sudo debugfs"
fi

IFS='/' read -ra __segments <<< "${REMOTE_ROOT}"
__current=""
for __segment in "${__segments[@]}"; do
  [[ -z "${__segment}" ]] && continue
  __current+="/${__segment}"
  ${DEBUGFS_CMD} -w "${DISK_IMAGE}" -R "mkdir ${__current}" >/dev/null 2>&1 || true
done

# debugfs write command requires cd to target directory first
REMOTE_FILENAME=$(basename "${REMOTE_PATH}")
if ! ${DEBUGFS_CMD} -w "${DISK_IMAGE}" << EOF
cd ${REMOTE_ROOT}
rm ${REMOTE_FILENAME}
write ${TARGET_BIN} ${REMOTE_FILENAME}
quit
EOF
then
  echo "[daily] failed to write binary to disk image" >&2
  exit 1
fi
echo "[daily] deployed binary to ${REMOTE_PATH}" >&2

VM_RUNNER="${STARRY_VM_RUNNER:-${CI_TEST_RUNNER:-${WORKSPACE_ROOT}/scripts/starry_vm_runner.py}}"
if [[ ! -x "${VM_RUNNER}" ]]; then
  echo "[daily] starry_vm_runner not found at ${VM_RUNNER}" >&2
  exit 1
fi

REMOTE_CMD="${REMOTE_PATH}"
if (( ${#CASE_ARGS[@]} > 0 )); then
  for arg in "${CASE_ARGS[@]}"; do
    REMOTE_CMD+=" $(printf '%q' "${arg}")"
  done
fi

RUN_STDOUT="${ARTIFACT_DIR}/stdout.json"
RAW_STDOUT="${ARTIFACT_DIR}/stdout_raw.log"
RUN_STDERR="${ARTIFACT_DIR}/stderr.log"
RESULT_PATH="${ARTIFACT_DIR}/result.json"
COMMAND_TIMEOUT="${STARRY_CASE_TIMEOUT_SECS:-600}"

echo "[daily] running inside StarryOS: ${REMOTE_CMD}" >&2
if ! VM_OUTPUT="$(
  python3 "${VM_RUNNER}" \
    --root "${STARRYOS_ROOT}" \
    --arch "${ARCH}" \
    --command "${REMOTE_CMD}" \
    --command-timeout "${COMMAND_TIMEOUT}" \
    2> >(tee "${RUN_STDERR}" >&2)
)"; then
  echo "[daily] StarryOS command failed" >&2
  exit 1
fi

VM_OUTPUT="${VM_OUTPUT//$'\r'/}"
printf "%s\n" "${VM_OUTPUT}" | tee "${RAW_STDOUT}" >/dev/null

if ! PAYLOAD="$(python3 - "${RAW_STDOUT}" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
candidates = re.findall(r"\{.*?\}", text, flags=re.S)
for candidate in reversed(candidates):
    try:
        json.loads(candidate)
    except json.JSONDecodeError:
        continue
    print(candidate.strip())
    break
else:
    print("[daily] JSON payload not found in VM output", file=sys.stderr)
    sys.exit(1)
PY
)"; then
  echo "[daily] failed to extract JSON payload from VM output" >&2
  exit 1
fi

printf "%s\n" "${PAYLOAD}" | tee "${RUN_STDOUT}" >/dev/null

if [[ ! -s "${RUN_STDOUT}" ]]; then
  echo "[daily] run log empty - expected structured output" >&2
  exit 1
fi

python3 - "$RUN_STDOUT" "$RESULT_PATH" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])

payload = log_path.read_text().strip()
if not payload:
    print("[daily] empty payload received from guest", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(payload)
except json.JSONDecodeError as exc:
    print(f"[daily] invalid JSON output: {exc}", file=sys.stderr)
    sys.exit(1)

status = data.get("status")
if status not in {"pass", "fail"}:
    print("[daily] missing 'status' field (pass|fail) in output", file=sys.stderr)
    sys.exit(1)

result_path.write_text(json.dumps(data, indent=2))
print(f"[daily] stored result -> {result_path}")

if status != "pass":
    sys.exit(2)
PY

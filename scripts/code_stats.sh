#!/usr/bin/env bash
set -euo pipefail

COMMENT_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --whitelist)
      WHITELIST="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --comment-output)
      COMMENT_OUTPUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${WORKSPACE:-}" || -z "${WHITELIST:-}" ]]; then
  echo "Usage: code_stats.sh --workspace <dir> --whitelist <file> --output <dir> [--comment-output file]"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
# 将白名单仓库同步到 workspace/local_crates，方便与主仓一起统计
CLONE_DIR="${WORKSPACE}/local_crates"
mkdir -p "${CLONE_DIR}"

echo "[code-stats] workspace: ${WORKSPACE}"
echo "[code-stats] whitelist: ${WHITELIST}"
echo "[code-stats] clone-dir: ${CLONE_DIR}"
echo "[code-stats] output-dir: ${OUTPUT_DIR}"

bash "$(dirname "$0")/clone_repos.sh" \
  --whitelist "${WHITELIST}" \
  --dest "${CLONE_DIR}"

CMD=(
  python3 "$(dirname "$0")/generate_loc_report.py"
  --workspace "${WORKSPACE}"
  --clone-dir "${CLONE_DIR}"
  --output "${OUTPUT_DIR}"
)

if [[ -n "$COMMENT_OUTPUT" ]]; then
  CMD+=( --comment-output "${COMMENT_OUTPUT}" )
fi

"${CMD[@]}"

echo "[code-stats] Done. Results:"
ls -al "${OUTPUT_DIR}"

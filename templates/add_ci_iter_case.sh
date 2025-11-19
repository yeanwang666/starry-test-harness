#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/ci_case.rs"
TARGET_TEST_DIR="${REPO_ROOT}/tests/ci-test-iter/cases/tests"

usage() {
  cat <<'EOU' >&2
用法: templates/add_ci_iter_case.sh <case_name> [display_name]

示例:
  templates/add_ci_iter_case.sh ptrace_smoke
  templates/add_ci_iter_case.sh ptrace_smoke "ptrace-smoke"

说明:
  - <case_name> 将作为 tests/<name>.rs 的文件名（建议 snake_case）。
  - display_name 可选；默认会把 binary_name 中的下划线替换为连字符，用于日志展示。
EOU
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

CASE_NAME="$1"
if [[ ! "${CASE_NAME}" =~ ^[a-z0-9_]+$ ]]; then
  echo "错误: case_name 仅支持小写字母、数字和下划线。" >&2
  exit 1
fi

DISPLAY_NAME="${2:-${CASE_NAME//_/-}}"
TARGET_FILE="${TARGET_TEST_DIR}/${CASE_NAME}.rs"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "错误: 未找到模板 ${TEMPLATE_FILE}" >&2
  exit 1
fi

if [[ -e "${TARGET_FILE}" ]]; then
  echo "错误: 目标文件已存在 ${TARGET_FILE}" >&2
  exit 1
fi

python3 - <<'PY' "${TEMPLATE_FILE}" "${TARGET_FILE}" "${CASE_NAME}" "${DISPLAY_NAME}"
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
case_name = sys.argv[3]
display_name = sys.argv[4]

content = template_path.read_text(encoding="utf-8")
content = content.replace("__CASE_NAME__", case_name)
content = content.replace("__CASE_DISPLAY__", display_name)
target_path.parent.mkdir(parents=True, exist_ok=True)
target_path.write_text(content, encoding="utf-8")
PY

cat <<EOF
已生成: ${TARGET_FILE}

下一步:
1. 根据测试需求编辑上述文件中的 TODO，编写具体逻辑。
2. 在 tests/ci-test-iter/suite.toml 中追加如下条目以注册用例:

[[cases]]
name = "${DISPLAY_NAME}"
description = "TODO: 用例描述"
path = "tests/ci-test-iter/run_case.sh"
args = ["${CASE_NAME}"]

3. 如果需要写入镜像的自定义路径，可在 args 中追加第二个参数，如:
  args = ["${CASE_NAME}", "/usr/tests/${CASE_NAME}"]

完成后可执行 `make ci-test-iter run` 验证用例。

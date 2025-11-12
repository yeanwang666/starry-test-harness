#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROOT="${SCRIPT_DIR}/logs"

if [[ ! -d "${LOG_ROOT}" ]]; then
  printf '[clean-logs] nothing to clean (logs directory missing)\n'
  exit 0
fi

find "${LOG_ROOT}" -mindepth 1 \
  ! -name '.gitkeep' \
  -exec rm -rf -- {} +

printf '[clean-logs] log directories cleaned\n'

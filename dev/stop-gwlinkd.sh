#!/usr/bin/env bash
# 停止 ./dev/start-gwlinkd.sh 拉起的 wist-gwlinkd。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ -f "${GWLINKD_PID_FILE}" ]]; then
  pid="$(cat "${GWLINKD_PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    echo "已停止 wist-gwlinkd（pid=${pid}）"
  else
    echo "wist-gwlinkd 未在运行（清理 pid 文件）"
  fi
  rm -f "${GWLINKD_PID_FILE}"
else
  echo "wist-gwlinkd 未在运行"
fi

#!/usr/bin/env bash
# 停止中心后端（配合 ./dev/start-center.sh）。
#
# 用法：
#   ./dev/stop-center.sh
#
# 查找顺序：
#   1. `.run/center.pid`（start-center.sh 写入；会校验 pid 确实指向 wist-center，防 pid 复用误杀）
#   2. 监听 CENTER_PORT（默认 3100）的进程
#
# 前台跑的 start-center.sh 直接 Ctrl+C 也可以；本脚本用于它跑在后台、或那个终端已关闭时。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd lsof
stop_service "wist-center" "${CENTER_PID_FILE}" "${CENTER_PORT}" "wist-center"

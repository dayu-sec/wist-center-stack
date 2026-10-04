#!/usr/bin/env bash
# 停止管理前端（配合 ./dev/start-web.sh）。
#
# 用法：
#   ./dev/stop-web.sh
#
# 查找顺序：
#   1. `.run/web.pid`（start-web.sh 写入；会校验 pid 确实指向 npm，防 pid 复用误杀）
#   2. 监听 WEB_PORT（默认 5173）的进程 —— 这一层同时兜住 `npm run dev` 派生的
#      node/vite/esbuild 子孙进程（父进程退出后它们可能仍占着端口）
#
# 可覆盖 env：WEB_URL（端口由它解析）
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd lsof
require_cmd python3
stop_service "wist-center-web" "${WEB_PID_FILE}" "$(web_port)" "npm"

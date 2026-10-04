#!/usr/bin/env bash
# 启动管理前端 wist-center-web（vite dev，默认 http://127.0.0.1:5173），开发态。
#
# 只起前端。中心后端用 ./dev/start-center.sh；vite 的 /api 会反代到中心
# （目标 = http://CENTER_ADDR）。
#
# 用法：
#   ./dev/start-web.sh
#
# 停止：Ctrl+C，或另开终端 ./dev/stop-web.sh。
#
# 可覆盖 env：
#   WEB_URL                     前端地址（默认 http://127.0.0.1:5173，端口跟随它）
#   WARP_INSIGHT_CENTER_LISTEN  中心监听地址（决定 /api 反代目标，默认 127.0.0.1:3100）
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

trap cleanup_started_processes EXIT

require_cmd python3
require_cmd curl
require_cmd npm

if [[ ! -d "${WEB_DIR}/node_modules" ]]; then
  echo "wist-center-web 依赖缺失：${WEB_DIR}/node_modules（先 cd 到该目录执行 npm install）" >&2
  exit 1
fi

# 中心没起也允许：前端会回退到内置的 example 数据（source: "example"）。
if ! center_ready; then
  echo "提示：中心后端（http://${CENTER_ADDR}）未在运行 —— 前端会回退到 example 数据；"
  echo "      需要真实数据请另开一个终端执行 ./dev/start-center.sh。"
fi

start_web
print_access_info

# 阻塞等待子进程：Ctrl+C 或 ./dev/stop-web.sh 停掉后，这里会返回并走 EXIT trap 收尾。
wait

#!/usr/bin/env bash
# 一键启动中心两件套：wist-center（后端）+ wist-center-web（管理前端），开发态。
#
# 第三方依赖（PostgreSQL / VictoriaMetrics）不在这里起 —— 先用 ./dev/start-deps.sh。
# 只想起其中一个（各自独立、可单独重启/停止）：
#   ./dev/start-center.sh / stop-center.sh    只用后端
#   ./dev/start-web.sh    / stop-web.sh       只用前端
#
# 用法：
#   ./dev/start-deps.sh      # 1. 依赖（可跳过：中心会退回文件存储且不推时序）
#   ./dev/start.sh           # 2. 两件套
#
# 可覆盖 env：见 start-center.sh / start-web.sh 的头部（WEB_URL、WARP_INSIGHT_CENTER_* 等）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

trap cleanup_started_processes EXIT

require_cmd python3
require_cmd curl

echo "启动 wist-center + wist-center-web（开发态）"
echo "  前置：PostgreSQL + VictoriaMetrics（./dev/start-deps.sh）"
resolve_dependencies
echo

build_center
ensure_center_config
start_center
start_web
print_access_info

# 阻塞等待子进程：Ctrl+C 或 ./dev/stop-{center,web}.sh 停掉后，这里会返回并走 EXIT trap 收尾。
wait

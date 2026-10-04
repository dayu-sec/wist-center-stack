#!/usr/bin/env bash
# 启动 wist-center（中心后端，默认 http://127.0.0.1:3100），开发态。
#
# 只起后端。前端用 ./dev/start-web.sh，第三方依赖用 ./dev/start-deps.sh。
#
# 用法：
#   ./dev/start-center.sh
#
# 停止：Ctrl+C，或另开终端 ./dev/stop-center.sh。
#
# 配置来源（三层，后者覆盖前者；详见 wist-center 的配置文件机制）：
#   1. 配置文件：${CENTER_CONFIG}，默认 ~/.wist-center/wist-center.toml；
#   2. 环境变量 WARP_INSIGHT_CENTER_*（本脚本用它覆盖运行态项，见下）；
#   3. 内置默认值。
#
# 凭据：
#   - 首次运行自动调 `wist-center init-config` 生成配置文件，随机 admin token / hmac secret
#     都落在里面；之后每次启动复用同一份 → 管理页面填一次 token 就长期有效。
#   - 换一套凭据：删掉该文件后重跑（旧 token 立即失效）。
#   - 想手工维护配置：
#       mkdir -p ~/.wist-center && cp ../wist-center/examples/local-dev.toml ~/.wist-center/wist-center.toml
#
# 可覆盖 env：
#   WIST_CENTER_CONFIG                      中心配置文件路径（默认 ~/.wist-center/wist-center.toml）
#   WARP_INSIGHT_CENTER_LISTEN              监听地址（默认 127.0.0.1:3100）
#   WARP_INSIGHT_CENTER_ADMIN_TOKEN         管理面 token（默认取配置文件里的值；设了就覆盖它）
#   WARP_INSIGHT_CENTER_HMAC_SECRET         RegistToken 派生密钥（默认取配置文件里的值）
#   WARP_INSIGHT_CENTER_DATABASE_URL        PostgreSQL DSN（默认探测 PG_PORT；显式置空 → 文件存储）
#   WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL 时序库地址（默认探测 VM_PORT；显式置空 → 不推送）
#   PG_PORT / VM_PORT                       依赖服务宿主端口（默认 55432 / 28429）
#
# 注意：DATABASE_URL / VICTORIAMETRICS_URL 这两项**本脚本按探测结果覆盖**（探测不到就显式置空），
# 所以配置文件里写的这两个值不生效；要固定它们，就用 env 显式给值（显式值优先于探测）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

trap cleanup_started_processes EXIT

require_cmd python3
require_cmd curl

echo "启动 wist-center（开发态）"
resolve_dependencies
echo

build_center
ensure_center_config
start_center
print_access_info

# 阻塞等待子进程：Ctrl+C 或 ./dev/stop-center.sh 停掉后，这里会返回并走 EXIT trap 收尾。
wait

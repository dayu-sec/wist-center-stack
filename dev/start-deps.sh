#!/usr/bin/env bash
# 开发态：启动第三方依赖（PostgreSQL + VictoriaMetrics，用 Docker 起）。
#
# 编排与发布态**共用同一份** sys/docker-compose.yml（gops run 也是这么调用的），
# 这里只起 postgres / victoria-metrics，不起 center / web。
#
# 用法：
#   ./dev/start-deps.sh                    # 两个都起
#   ./dev/start-deps.sh postgres           # 只起 PostgreSQL（默认宿主 55432）
#   ./dev/start-deps.sh victoria-metrics   # 只起 VictoriaMetrics（默认宿主 28429）
#
# 不起也能跑 ./dev/start.sh：中心会退回本地 JSON 文件存储，且不推送时序历史。
# 变量（宿主端口、镜像 tag、DSN 组成等）来自 gops 渲染的栈根 .env —— 缺了就自动跑一次
# `gops sys localize`（也会顺带备料 configs/）。
# PostgreSQL 首次启动会用 sys/db/initdb/01_schema.sql 建表（数据卷为空时）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 未指定则默认两个都起。
SERVICES=("$@")
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(postgres victoria-metrics)
fi

cd "${STACK_ROOT}"

# 变量来源：gops 在栈根写的 .env。缺了就先 localize 一次（幂等）。
if [[ ! -f .env ]]; then
  echo "栈根没有 .env（gops 渲染的变量文件），先跑一次 gops sys localize …"
  gops sys localize
fi

# 与 gops run 同一调用口径：-f sys/docker-compose.yml + --project-directory <栈根>
# （否则 -f 会把项目目录定到 sys/，相对挂载与 .env 都会错位）。
docker compose -f sys/docker-compose.yml --project-directory . up -d "${SERVICES[@]}"
echo
docker compose -f sys/docker-compose.yml --project-directory . ps "${SERVICES[@]}"

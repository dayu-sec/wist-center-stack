#!/usr/bin/env bash
# 开发态：仅启动 PostgreSQL（中心的存储后端）。
# 端口与 compose 对齐：宿主 55432 -> 容器 5432。
#
# 用法：
#   ./sysrun/start-pg.sh
#
# 仅拉起 postgres 一个服务，不影响 center / web / victoria-metrics。
# 首次启动会用 ../wist-center/docker/initdb/01_schema.sql 建表（数据卷为空时）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${STACK_ROOT}"
docker compose up -d postgres
echo
docker compose ps postgres

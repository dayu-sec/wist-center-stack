#!/usr/bin/env bash
# 开发态：停止 PostgreSQL（配合 start-pg.sh）。
# 只 stop，不 down —— 数据卷保留，下次 start-pg.sh 直接复用。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${STACK_ROOT}"
docker compose stop postgres

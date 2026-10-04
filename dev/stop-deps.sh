#!/usr/bin/env bash
# 开发态：停止第三方依赖（配合 start-deps.sh）。
# 只 stop 不 down —— 数据卷保留，下次 start-deps.sh 直接复用。
#
# 用法：
#   ./dev/stop-deps.sh                     # 两个都停
#   ./dev/stop-deps.sh postgres            # 只停 PostgreSQL
#   ./dev/stop-deps.sh victoria-metrics    # 只停 VictoriaMetrics
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 未指定则默认两个都停。
SERVICES=("$@")
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(postgres victoria-metrics)
fi

cd "${STACK_ROOT}"

# 与 gops run / start-deps.sh 同一调用口径（见 start-deps.sh）。
docker compose -f sys/docker-compose.yml --project-directory . stop "${SERVICES[@]}"

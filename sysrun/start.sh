#!/usr/bin/env bash
# 启动 wist-center（中心后端，127.0.0.1:3100）+ wist-center-web（管理前端，5173），开发态。
#
# 只负责中心两件套；网关与 agent 的状态上报来自 wist-gateway-stack / wist-agentd 侧。
# PostgreSQL（55432）与 VictoriaMetrics（18429）是第三方依赖，用 ./sysrun/start-pg.sh、
# ./sysrun/start-vm.sh 单独起。两者不起也能跑：中心会退回本地 JSON 文件存储，且不推送时序历史。
#
# 用法：
#   ./sysrun/start.sh
#
# 可覆盖 env：
#   WEB_URL                                 前端地址（默认 http://127.0.0.1:5173，端口跟随它）
#   SKIP_WEB=1                              只起中心后端
#   WARP_INSIGHT_CENTER_LISTEN              中心监听地址（默认 127.0.0.1:3100）
#   WARP_INSIGHT_CENTER_ADMIN_TOKEN         管理面 token（默认随机生成并打印）
#   WARP_INSIGHT_CENTER_HMAC_SECRET         RegistToken 派生密钥（默认随机生成）
#   WARP_INSIGHT_CENTER_DATABASE_URL        PostgreSQL DSN（默认探测 55432，探不到 → 文件存储）
#   WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL 时序库地址（默认探测 18429，探不到 → 不推送）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 本脚本位于 wist-center-stack/sysrun/：
#   STACK_ROOT = wist-center-stack
#   ROOT_DIR   = 各 crate 的父目录（x-topology）
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${STACK_ROOT}/.." && pwd)"
CENTER_CRATE="${ROOT_DIR}/wist-center"
WEB_DIR="${ROOT_DIR}/wist-center-web"

# 中心本地数据（文件存储 / 制品镜像）落这里；与 .run（运行期临时产物）同处。
RUN_DIR="${STACK_ROOT}/.run/center"
CENTER_ADDR="${WARP_INSIGHT_CENTER_LISTEN:-127.0.0.1:3100}"
CENTER_PORT="${CENTER_ADDR##*:}"
WEB_URL="${WEB_URL:-http://127.0.0.1:5173}"
SKIP_WEB="${SKIP_WEB:-0}"
PG_PORT="${PG_PORT:-55432}"
VM_PORT="${VM_PORT:-18429}"

CENTER_PID=""
WEB_PID=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${WEB_PID}" ]] && kill -0 "${WEB_PID}" 2>/dev/null; then
    kill "${WEB_PID}" 2>/dev/null || true
    wait "${WEB_PID}" 2>/dev/null || true
  fi
  if [[ -n "${CENTER_PID}" ]] && kill -0 "${CENTER_PID}" 2>/dev/null; then
    kill "${CENTER_PID}" 2>/dev/null || true
    wait "${CENTER_PID}" 2>/dev/null || true
  fi
  echo
  echo "已停止 center / web 进程。"
}
trap cleanup EXIT

# TCP 探测：端口可连即 0。
port_open() {
  python3 - "$1" <<'PY'
import socket, sys
sock = socket.socket()
sock.settimeout(0.5)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

center_ready() {
  port_open "${CENTER_PORT}"
}

web_status() {
  curl -s -o /dev/null -w "%{http_code}" "${WEB_URL%/}/" || true
}

wait_until() {
  # wait_until <描述> <cmd...>
  local desc="$1"
  shift
  echo "等待 ${desc} 就绪..."
  for _ in {1..100}; do
    if "$@" >/dev/null 2>&1; then
      echo "  ${desc} 就绪"
      return 0
    fi
    sleep 0.2
  done
  echo "  ${desc} 未就绪。" >&2
  return 1
}

build_center() {
  local center_bin="${CENTER_CRATE}/target/debug/wist-center"
  if [[ ! -x "${center_bin}" ]]; then
    require_cmd cargo
    echo "== 构建 wist-center =="
    cargo build --manifest-path "${CENTER_CRATE}/Cargo.toml"
  fi
}

start_center() {
  echo "== 启动 wist-center（http://${CENTER_ADDR}）=="
  local center_bin="${CENTER_CRATE}/target/debug/wist-center"
  mkdir -p "${RUN_DIR}/artifacts"
  # DATABASE_URL / VICTORIAMETRICS_URL 置空即"关闭"（配置读取时空值等价于未配置）。
  env \
    WARP_INSIGHT_CENTER_LISTEN="${CENTER_ADDR}" \
    WARP_INSIGHT_CENTER_ADMIN_TOKEN="${ADMIN_TOKEN}" \
    WARP_INSIGHT_CENTER_HMAC_SECRET="${HMAC_SECRET}" \
    WARP_INSIGHT_CENTER_STORE_PATH="${RUN_DIR}/store.json" \
    WARP_INSIGHT_CENTER_ARTIFACT_DIR="${RUN_DIR}/artifacts" \
    WARP_INSIGHT_CENTER_DATABASE_URL="${DATABASE_URL}" \
    WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL="${VM_URL}" \
    "${center_bin}" >/tmp/wist-center.log 2>&1 &
  CENTER_PID=$!
  if wait_until "wist-center" center_ready; then
    return 0
  fi
  echo "  wist-center 未就绪，日志：/tmp/wist-center.log" >&2
  return 1
}

start_web() {
  echo "== 启动管理前端 wist-center-web（${WEB_URL}）=="
  if [[ "${SKIP_WEB}" == "1" ]]; then
    echo "  已跳过（SKIP_WEB=1）"
    return 0
  fi
  if [[ "$(web_status)" == "200" ]]; then
    echo "  wist-center-web 已在运行（${WEB_URL}），复用。"
    return 0
  fi
  require_cmd npm
  if [[ ! -d "${WEB_DIR}/node_modules" ]]; then
    echo "  wist-center-web 依赖缺失：${WEB_DIR}/node_modules（先 cd 到该目录执行 npm install）" >&2
    exit 1
  fi
  local host port
  host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').hostname or '127.0.0.1')")"
  port="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)")"
  (
    cd "${WEB_DIR}"
    # vite 的 /api 反代目标（wist-center-web/vite.config.ts 读取该变量，默认即 127.0.0.1:3100）。
    export WARP_INSIGHT_WEB_PROXY_TARGET="http://${CENTER_ADDR}"
    exec nohup npm run dev -- --host "${host}" --port "${port}" --strictPort \
      >/tmp/wist-center-web.log 2>&1
  ) &
  WEB_PID=$!
  echo "  启动 wist-center-web：${WEB_URL} (pid=$!)"
  if wait_until "wist-center-web" web_status; then
    return 0
  fi
  echo "  wist-center-web 未就绪（日志 /tmp/wist-center-web.log）" >&2
  return 1
}

# ── 主流程 ──

require_cmd python3
require_cmd curl

echo "启动 wist-center + wist-center-web（开发态）"
echo "  center: http://${CENTER_ADDR}"
echo "  web:    ${WEB_URL}（SKIP_WEB=1 可跳过）"
echo "  前置：PostgreSQL（./sysrun/start-pg.sh）、VictoriaMetrics（./sysrun/start-vm.sh）"
echo

# 1. 管理面凭据：未显式提供则随机生成（每次启动都会打印，便于填入前端）。
ADMIN_TOKEN="${WARP_INSIGHT_CENTER_ADMIN_TOKEN:-$(python3 -c 'import secrets; print(secrets.token_hex(32))')}"
HMAC_SECRET="${WARP_INSIGHT_CENTER_HMAC_SECRET:-$(python3 -c 'import secrets; print(secrets.token_hex(32))')}"

# 2. 存储后端：未设置 → 探测 PostgreSQL（可达用 PgStore，否则退回文件存储）；
#    显式给值 → 直接用；显式置空 → 明确走文件存储。
if [[ -n "${WARP_INSIGHT_CENTER_DATABASE_URL+set}" ]]; then
  DATABASE_URL="${WARP_INSIGHT_CENTER_DATABASE_URL}"
  if [[ -z "${DATABASE_URL}" ]]; then
    echo "PostgreSQL 已显式关闭（DATABASE_URL 置空）→ 本地 JSON 文件存储"
  else
    echo "PostgreSQL 使用显式 DSN → PgStore"
  fi
elif port_open "${PG_PORT}"; then
  DATABASE_URL="postgres://demo:demo@127.0.0.1:${PG_PORT}/insight_demo"
  echo "PostgreSQL 可达（127.0.0.1:${PG_PORT}）→ PgStore"
else
  DATABASE_URL=""
  echo "PostgreSQL 不可达（127.0.0.1:${PG_PORT}）→ 本地 JSON 文件存储（如需 PG：./sysrun/start-pg.sh）"
fi

# 3. 时序历史：同上的三态处理。
if [[ -n "${WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL+set}" ]]; then
  VM_URL="${WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL}"
  if [[ -z "${VM_URL}" ]]; then
    echo "时序推送已显式关闭（VICTORIAMETRICS_URL 置空）"
  else
    echo "时序推送使用显式地址：${VM_URL}"
  fi
elif port_open "${VM_PORT}"; then
  VM_URL="http://127.0.0.1:${VM_PORT}"
  echo "VictoriaMetrics 可达（127.0.0.1:${VM_PORT}）→ 上报同时推送时序"
else
  VM_URL=""
  echo "VictoriaMetrics 不可达（127.0.0.1:${VM_PORT}）→ 不推送时序（如需：./sysrun/start-vm.sh）"
fi
echo

build_center
start_center
start_web

echo
echo "中心控制台已启动，按 Ctrl+C 停止。"
echo "  管理页面：${WEB_URL}"
echo "  中心 API：http://${CENTER_ADDR}"
echo "  管理 token：${ADMIN_TOKEN}"
echo "    （在管理页面填入该 token 后开启 5s 轮询刷新）"
echo "  日志：/tmp/wist-center.log、/tmp/wist-center-web.log"
echo
while :; do sleep 60; done

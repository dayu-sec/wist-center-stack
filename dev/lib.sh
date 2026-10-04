#!/usr/bin/env bash
# wist-center-stack 开发态公共函数 / 路径 / 默认端口。
#
# 由 dev/*.sh **source** 使用，不单独执行。
# 依赖 python3（TCP 探测 / 解析 URL / 生成随机凭据）与 lsof（停服时按端口兜底）。
#
# 约定：入口脚本各自 `set -euo pipefail` 后再 source 本文件，并注册
# `trap cleanup_started_processes EXIT`。

# ── 路径 ──
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
# 本仓位于 wist-center-stack/，与各 crate 平级：ROOT_DIR 是它们的父目录。
ROOT_DIR="$(cd "${STACK_ROOT}/.." && pwd)"
CENTER_CRATE="${ROOT_DIR}/wist-center"
WEB_DIR="${ROOT_DIR}/wist-center-web"

# 中心本地数据（JSON 文件存储 / 制品镜像）落这里。
RUN_DIR="${STACK_ROOT}/.run/center"
CENTER_LOG="/tmp/wist-center.log"
WEB_LOG="/tmp/wist-center-web.log"

# 停服依据：start-* 写入，stop-* 读取。
CENTER_PID_FILE="${STACK_ROOT}/.run/center.pid"
WEB_PID_FILE="${STACK_ROOT}/.run/web.pid"

# 中心配置文件（持有持久化的 admin token / hmac secret，形状见 wist-center/wist-center.toml）。
# 默认 ~/.wist-center/ —— 刻意不放在 .run/ 下：.run 是可随手清掉的运行目录，
# 而这两项是长期凭据，跟着 .run 一起没了就得重新粘贴 token / 重新注册。
# 可用 WIST_CENTER_CONFIG 指向别处。
CENTER_CONFIG="${WIST_CENTER_CONFIG:-${HOME}/.wist-center/wist-center.toml}"

# 中心服务端 TLS（可选，默认关）：WIST_CENTER_TLS=1 时用自签服务器证书起 HTTPS，
# 并让网关用同一张证书当信任锚（dev 自签：锚 = 叶证书本身）。
# 证书落 ~/.wist-center/tls/（与长期凭据同处，不入 .run）。
CENTER_TLS="${WIST_CENTER_TLS:-0}"
CENTER_TLS_DIR="${WIST_CENTER_TLS_DIR:-${HOME}/.wist-center/tls}"
CENTER_TLS_CA_CERT="${CENTER_TLS_DIR}/ca.crt.pem"
CENTER_TLS_CA_KEY="${CENTER_TLS_DIR}/ca.key.pem"
CENTER_TLS_CERT="${CENTER_TLS_DIR}/server.crt.pem"
CENTER_TLS_KEY="${CENTER_TLS_DIR}/server.key.pem"

# ── gwlinkd（宿主侧常驻，把本机网关栈接到 center）──
# 它是对中心做 mTLS 的客户端：首跑 link-upstream/register，之后周期 status/renew。
GWLINKD_CRATE="${ROOT_DIR}/wist-gwlinkd"
GWLINKD_DIR="${STACK_ROOT}/.run/gwlinkd"
GWLINKD_CONFIG="${GWLINKD_DIR}/gwlinkd.toml"
GWLINKD_LOG="${GWLINKD_DIR}/gwlinkd.log"
GWLINKD_PID_FILE="${STACK_ROOT}/.run/gwlinkd.pid"
GWLINKD_BOOTSTRAP=""

# ── 端口 / 地址（覆盖用同名 env；PG_PORT、VM_PORT 与 docker-compose.yml 同名同值）──
CENTER_ADDR="${WARP_INSIGHT_CENTER_LISTEN:-127.0.0.1:3100}"
CENTER_PORT="${CENTER_ADDR##*:}"
WEB_URL="${WEB_URL:-http://127.0.0.1:5173}"
PG_PORT="${PG_PORT:-55432}"
VM_PORT="${VM_PORT:-28429}"

# 由 start_center / start_web 填充。
# ADMIN_TOKEN：从中心配置读出的管理 token，仅用于启动后提示。
ADMIN_TOKEN=""
CENTER_PID=""
WEB_PID=""
# 中心对外协议（http / https）；start_center 按 WIST_CENTER_TLS 设定，start_web 据此设代理目标。
CENTER_SCHEME="http"
# 前端地址解析出的端口（start_web 与 stop-web.sh 共用）。
WEB_PORT=""
# 前端可用（本脚本拉起或复用了已在运行的实例）。
WEB_ACTIVE=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

web_port() {
  python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)"
}

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

# 是否启用中心服务端 TLS（WIST_CENTER_TLS 取 1/true/yes/on）。
center_tls_enabled() {
  [[ "$(printf '%s' "${CENTER_TLS}" | tr '[:upper:]' '[:lower:]')" =~ ^(1|true|yes|on)$ ]]
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

write_pidfile() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

remove_pidfile() {
  [[ -f "$1" ]] && rm -f "$1"
  return 0
}

# 清理端口的**监听**进程。npm run dev 会派生 node/vite/esbuild 子孙进程，父进程退出后
# 它们可能仍占着端口，所以停服/收尾都要按端口兜一次底。
# 注意：必须带 -sTCP:LISTEN —— 否则 lsof 会把与端口的普通连接（例如浏览器的页面连接）
# 也列出来，那就可能误杀无关进程。
kill_port_holder() {
  local port="$1"
  local label="${2:-端口}"
  local holders
  holders="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "${holders}" ]] && return 0
  echo "  端口 ${port} 仍被占用（${label}），清理：${holders}"
  kill ${holders} 2>/dev/null || true
  sleep 0.5
}

# 停止本脚本拉起的进程（入口脚本注册为 EXIT trap）。
cleanup_started_processes() {
  local pid
  for pid in "${WEB_PID}" "${CENTER_PID}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  # 只清理"本脚本确实拉起过"的服务端口，避免误伤别人的实例。
  [[ -n "${WEB_PID}" ]] && kill_port_holder "${WEB_PORT:-$(web_port)}" "wist-center-web"
  [[ -n "${CENTER_PID}" ]] && kill_port_holder "${CENTER_PORT}" "wist-center"
  remove_pidfile "${CENTER_PID_FILE}"
  remove_pidfile "${WEB_PID_FILE}"
  echo
  echo "已停止本脚本拉起的进程。"
}

# 停服：优先 pidfile（并校验 pid 确实是目标进程，防 pid 复用），退化到端口占用者。
# stop_service <显示名> <pidfile> <端口> <进程命令行特征>
stop_service() {
  local label="$1"
  local pidfile="$2"
  local port="$3"
  local pattern="$4"
  local pid=""

  [[ -f "${pidfile}" ]] && pid="$(cat "${pidfile}" 2>/dev/null || true)"

  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    if ps -p "${pid}" -o command= 2>/dev/null | grep -q "${pattern}"; then
      echo "停止 ${label}（pid=${pid}，来自 ${pidfile}）"
      kill "${pid}" 2>/dev/null || true
      local _
      for _ in {1..50}; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "${pid}" 2>/dev/null; then
        echo "  未在 10s 内退出，强制结束"
        kill -9 "${pid}" 2>/dev/null || true
      fi
      remove_pidfile "${pidfile}"
      kill_port_holder "${port}" "${label}"
      return 0
    fi
    echo "${label} 的 ${pidfile} 记的是 pid=${pid}，但该进程不含 \"${pattern}\"（pid 可能已被复用），忽略 pidfile。"
  fi

  local holders
  holders="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -z "${holders}" ]]; then
    echo "${label} 未在运行（端口 ${port} 无监听）"
    remove_pidfile "${pidfile}"
    return 0
  fi
  echo "按端口 ${port} 停止 ${label}（pid=${holders}）"
  kill ${holders} 2>/dev/null || true
  sleep 0.5
  remove_pidfile "${pidfile}"
}

# ── 依赖探测 ──
# 三态：未设置 → 探测端口；显式给值 → 直接用；显式置空 → 明确关闭。
# 结论写入全局 DATABASE_URL / VM_URL（空值即关闭，中心把空值当未配置）。
resolve_dependencies() {
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
    echo "PostgreSQL 不可达（127.0.0.1:${PG_PORT}）→ 本地 JSON 文件存储（如需 PG：./dev/start-deps.sh postgres）"
  fi

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
    echo "VictoriaMetrics 不可达（127.0.0.1:${VM_PORT}）→ 不推送时序（如需：./dev/start-deps.sh victoria-metrics）"
  fi
}

# 构建 wist-center。
#
# 每次都搭——不是「没有二进制才搭」：脚本依赖二进制的**新特性**（`init-config` 子命令、
# `WIST_CENTER_CONFIG` 读取）。旧二进制不认 `init-config`，会把它当普通参数忽略、直接起服务
# 并带端口**挂住**，脚本就卡在那儿了。增量构建很快（无变化约 0.1s）。
build_center() {
  local center_bin="${CENTER_CRATE}/target/debug/wist-center"
  if command -v cargo >/dev/null 2>&1; then
    echo "== 构建 wist-center（增量，确保脚本用的是当前源码）=="
    cargo build --manifest-path "${CENTER_CRATE}/Cargo.toml"
    return 0
  fi
  if [[ -x "${center_bin}" ]]; then
    echo "提示：没装 cargo，沿用现有二进制 ${center_bin}（可能落后于源码）"
    return 0
  fi
  echo "既没装 cargo，也没有 ${center_bin}：请先装 Rust 工具链，或在 wist-center 里 cargo build" >&2
  exit 1
}

# 首次运行用二进制自带的 init-config 生成中心配置（随机 admin token / hmac secret），
# 之后复用同一份 → token 不再每次启动都变。需先 build_center。
ensure_center_config() {
  if [[ -f "${CENTER_CONFIG}" ]]; then
    echo "中心配置：${CENTER_CONFIG}（复用已有凭据）"
    return 0
  fi
  echo "== 生成中心配置 =="
  "${CENTER_CRATE}/target/debug/wist-center" init-config "${CENTER_CONFIG}"
}

# 读中心配置里的 `admin_token = "..."`（提示用；只匹配单行，够我们自己生成的配置）。
center_admin_token() {
  python3 - "${CENTER_CONFIG}" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
match = re.search(r'^\s*admin_token\s*=\s*"(.*)"\s*$', text, re.M)
print(match.group(1) if match else "")
PY
}

# 确保开发态 TLS 材料存在：自签 **CA-S** + 由它签出的服务器叶证书（SAN 覆盖 127.0.0.1/localhost）。
# 只在 WIST_CENTER_TLS 开启时用。**不能**用「自签证书既当信任锚又当叶」—— rustls 会拒（curl 未必），
# 所以走「CA 签叶」这条与生产同形的路。
ensure_center_tls() {
  center_tls_enabled || return 0
  if [[ -f "${CENTER_TLS_CERT}" && -f "${CENTER_TLS_KEY}" && -f "${CENTER_TLS_CA_CERT}" ]]; then
    echo "中心 TLS 材料：${CENTER_TLS_DIR}（复用）"
    return 0
  fi
  require_cmd openssl
  echo "== 生成中心 TLS 材料（dev：自签 CA-S + 服务器证书）=="
  mkdir -p "${CENTER_TLS_DIR}"
  # CA-S：自签根，可当信任锚。
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${CENTER_TLS_CA_KEY}" -out "${CENTER_TLS_CA_CERT}" \
    -days 825 -subj "/CN=wist-center-dev-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  # 服务器叶证书（CA-S 签）。
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${CENTER_TLS_KEY}" -out "${CENTER_TLS_DIR}/server.csr.pem" \
    -subj "/CN=wist-center-dev" >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n' \
    >"${CENTER_TLS_DIR}/server.ext"
  openssl x509 -req -in "${CENTER_TLS_DIR}/server.csr.pem" \
    -CA "${CENTER_TLS_CA_CERT}" -CAkey "${CENTER_TLS_CA_KEY}" -CAcreateserial \
    -out "${CENTER_TLS_CERT}" -days 825 -extfile "${CENTER_TLS_DIR}/server.ext" >/dev/null 2>&1
  chmod 600 "${CENTER_TLS_CA_KEY}" "${CENTER_TLS_KEY}"
  echo "  信任根（CA-S）：${CENTER_TLS_CA_CERT}"
  echo "  服务器证书：${CENTER_TLS_CERT}"
}

# 构建 wist-gwlinkd（增量）。
build_gwlinkd() {
  echo "== 构建 wist-gwlinkd（增量）=="
  cargo build --manifest-path "${GWLINKD_CRATE}/Cargo.toml"
}

# 通过 admin API 建一个网关实例，拿到 gateway_id + 一次性置备引导 Token；
# 写 gwlinkd.toml（endpoint=https、trust_bundle=CA-S、state_dir、gateway_id）。
# 前提：center 以 WIST_CENTER_TLS=1 起（提供 https + CA-S）。
ensure_gwlinkd_config() {
  center_tls_enabled || {
    echo "需要 WIST_CENTER_TLS=1（gwlinkd 走 mTLS，trust_bundle 用 CA-S）" >&2
    return 1
  }
  ensure_center_tls
  local token
  token="$(center_admin_token)"
  if [[ -z "${token}" ]]; then
    echo "读不到 admin token（${CENTER_CONFIG}）" >&2
    return 1
  fi
  mkdir -p "${GWLINKD_DIR}/state"
  echo "== 通过 admin API 创建网关实例 =="
  local resp gw boot
  resp="$(curl -sk -X POST "https://${CENTER_ADDR}/api/v1/admin/gateways/instances" \
    -H "authorization: Bearer ${token}" -H "content-type: application/json" \
    -d '{"gateway_name":"gw-local","requested_by":"dev"}')"
  gw="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['instance']['gateway_id'])" "${resp}" 2>/dev/null || true)"
  boot="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['install']['setup_token'])" "${resp}" 2>/dev/null || true)"
  if [[ -z "${gw}" || -z "${boot}" ]]; then
    echo "创建网关实例失败：${resp}" >&2
    return 1
  fi
  cat >"${GWLINKD_CONFIG}" <<EOF
control_center_endpoint = "https://${CENTER_ADDR}"
trust_bundle = "${CENTER_TLS_CA_CERT}"
state_dir = "${GWLINKD_DIR}/state"
gateway_id = "${gw}"
EOF
  GWLINKD_BOOTSTRAP="${boot}"
  echo "  网关实例：${gw}"
  echo "  gwlinkd 配置：${GWLINKD_CONFIG}"
}

# 启动 gwlinkd（后台）。首次带 bootstrap token；之后有凭据则免。
start_gwlinkd() {
  local bin="${GWLINKD_CRATE}/target/debug/wist-gwlinkd"
  [[ -x "${bin}" ]] || {
    echo "缺 gwlinkd 二进制：${bin}（先 build_gwlinkd）" >&2
    return 1
  }
  echo "== 启动 wist-gwlinkd（连 https://${CENTER_ADDR}）=="
  WIST_GWLINKD_CONFIG="${GWLINKD_CONFIG}" \
    WIST_GWLINKD_BOOTSTRAP_TOKEN="${GWLINKD_BOOTSTRAP}" \
    "${bin}" run >"${GWLINKD_LOG}" 2>&1 &
  GWLINKD_PID=$!
  write_pidfile "${GWLINKD_PID_FILE}" "${GWLINKD_PID}"
  echo "  pid=${GWLINKD_PID}；日志：${GWLINKD_LOG}"
}

# 启动中心后端（后台）；需先 resolve_dependencies + build_center + ensure_center_config。
start_center() {
  local center_bin="${CENTER_CRATE}/target/debug/wist-center"
  mkdir -p "${RUN_DIR}/artifacts"
  # 凭据来自配置文件（首次由 ensure_center_config 生成并持久化），这里只读出来提示。
  ADMIN_TOKEN="$(center_admin_token)"

  # TLS 关闭时这四项传空：中心把空值当未配置（明文 HTTP，public_url/ca_cert 保留配置文件值）。
  local tls_cert="" tls_key="" public_url="" ca_cert=""
  CENTER_SCHEME="http"
  if center_tls_enabled; then
    ensure_center_tls
    CENTER_SCHEME="https"
    tls_cert="${CENTER_TLS_CERT}"
    tls_key="${CENTER_TLS_KEY}"
    # 信任根（CA-S）分发给网关：既作中心的信任锚，也作 gateway 的 trust_bundle。
    public_url="https://${CENTER_ADDR}"
    ca_cert="${CENTER_TLS_CA_CERT}"
  fi

  echo "== 启动 wist-center（${CENTER_SCHEME}://${CENTER_ADDR}）=="
  # 配置文件提供凭据与默认值；env 覆盖运行态：监听地址、存储/制品目录、依赖地址、TLS。
  env \
    WIST_CENTER_CONFIG="${CENTER_CONFIG}" \
    WARP_INSIGHT_CENTER_LISTEN="${CENTER_ADDR}" \
    WARP_INSIGHT_CENTER_STORE_PATH="${RUN_DIR}/store.json" \
    WARP_INSIGHT_CENTER_ARTIFACT_DIR="${RUN_DIR}/artifacts" \
    WARP_INSIGHT_CENTER_DATABASE_URL="${DATABASE_URL:-}" \
    WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL="${VM_URL:-}" \
    WARP_INSIGHT_CENTER_SERVER_CERT_PATH="${tls_cert}" \
    WARP_INSIGHT_CENTER_SERVER_KEY_PATH="${tls_key}" \
    WARP_INSIGHT_CENTER_PUBLIC_URL="${public_url}" \
    WARP_INSIGHT_CENTER_CA_CERT_PATH="${ca_cert}" \
    "${center_bin}" >"${CENTER_LOG}" 2>&1 &
  CENTER_PID=$!
  write_pidfile "${CENTER_PID_FILE}" "${CENTER_PID}"
  if wait_until "wist-center" center_ready; then
    return 0
  fi
  echo "  wist-center 未就绪，日志：${CENTER_LOG}" >&2
  return 1
}

# 启动管理前端（后台）。vite 的 /api 反代到中心，目标取 CENTER_ADDR。
start_web() {
  require_cmd npm
  if [[ ! -d "${WEB_DIR}/node_modules" ]]; then
    echo "wist-center-web 依赖缺失：${WEB_DIR}/node_modules（先 cd 到该目录执行 npm install）" >&2
    exit 1
  fi
  WEB_PORT="$(web_port)"
  if [[ "$(web_status)" == "200" ]]; then
    echo "wist-center-web 已在运行（${WEB_URL}），复用。"
    WEB_ACTIVE=1
    return 0
  fi
  local host
  host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').hostname or '127.0.0.1')")"

  echo "== 启动 wist-center-web（${WEB_URL}）=="
  (
    cd "${WEB_DIR}"
    export WARP_INSIGHT_WEB_PROXY_TARGET="${CENTER_SCHEME}://${CENTER_ADDR}"
    exec nohup npm run dev -- --host "${host}" --port "${WEB_PORT}" --strictPort >"${WEB_LOG}" 2>&1
  ) &
  WEB_PID=$!
  write_pidfile "${WEB_PID_FILE}" "${WEB_PID}"
  echo "  启动 wist-center-web：${WEB_URL} (pid=${WEB_PID})"
  if wait_until "wist-center-web" web_status; then
    WEB_ACTIVE=1
    return 0
  fi
  echo "  wist-center-web 未就绪（日志 ${WEB_LOG}）" >&2
  return 1
}

# 打印访问信息（只打印本脚本确实拉起/复用的部分）。
print_access_info() {
  echo
  echo "开发态已就绪，按 Ctrl+C 停止（也可另开终端 ./dev/stop-{center,web}.sh）。"
  if [[ -n "${CENTER_PID}" ]]; then
    echo "  中心 API：${CENTER_SCHEME}://${CENTER_ADDR}"
    if [[ -n "${WARP_INSIGHT_CENTER_ADMIN_TOKEN:-}" ]]; then
      echo "  管理 token：来自环境变量 WARP_INSIGHT_CENTER_ADMIN_TOKEN（覆盖配置文件里的值）"
    else
      echo "  管理 token：${ADMIN_TOKEN}（来自 ${CENTER_CONFIG}，长期有效）"
    fi
    echo "    （在管理页面填入该 token 后开启 5s 轮询刷新）"
    echo "    换一套凭据：删掉 ${CENTER_CONFIG} 后重跑本脚本（旧 token 立即失效）"
  fi
  if [[ -n "${WEB_ACTIVE}" ]]; then
    echo "  管理页面：${WEB_URL}"
  fi
  [[ -n "${CENTER_PID}" ]] && echo "  中心日志：${CENTER_LOG}"
  [[ -n "${WEB_PID}" ]] && echo "  前端日志：${WEB_LOG}"
  echo
}

#!/usr/bin/env bash
# wist-center-stack 开发态公共函数 / 路径 / 默认端口。
#
# 由 dev/*.sh **source** 使用，不单独执行。
# 依赖 python3（TCP 探测 / 解析 URL / 读 token）与 lsof（停服时按端口兜底）。
#
# 约定：入口脚本 svc.sh 先 `set -euo pipefail` 再 source 本文件；各组件在**子 shell** 里起
# （见 svc.sh），所以别在组件函数里设“给外面看”的全局量 —— 出了子 shell 就没了。

# ── 路径 ──
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
# 本仓位于 wist-center-stack/，与各 crate 平级：ROOT_DIR 是它们的父目录。
ROOT_DIR="$(cd "${STACK_ROOT}/.." && pwd)"
# 2026-10 目录重组：crate / 前端收拢进 `wist/` 仓组。脚本还在旧栈位置
# （wist-stack/wist-center-stack/dev）时上一级是 x-topology，wist 组是其下的 `wist/`；
# 脚本随栈迁到 wist/wist-center-stack/dev 后上一级本身就是 wist 组 —— 两种位置都能解析。
# （与 wist-gateway-stack/dev/svc.sh 同口径。）
if [[ -d "${ROOT_DIR}/wist/wist-center" ]]; then
  ROOT_DIR="${ROOT_DIR}/wist"
elif [[ -d "${ROOT_DIR}/../wist/wist-center" ]]; then
  ROOT_DIR="$(cd "${ROOT_DIR}/../wist" && pwd)"
fi
CENTER_CRATE="${ROOT_DIR}/wist-center"
WEB_DIR="${ROOT_DIR}/wist-center-web"

# 中心本地数据（JSON 文件存储 / pid）落这里（可随手清掉）。
RUN_DIR="${STACK_ROOT}/.run/center"
# 制品镜像目录：与发布态同一个位置（`<栈根>/artifacts`，compose 挂到 /wist-center/artifacts）。
# **不放 .run/**：发布时下载/镜像下来的安装包是数据，不该跟着运行目录一起被清掉。
ARTIFACT_DIR="${STACK_ROOT}/artifacts"
CENTER_LOG="/tmp/wist-center.log"
WEB_LOG="/tmp/wist-center-web.log"

# 停服依据：start-* 写入，stop-* 读取。
CENTER_PID_FILE="${STACK_ROOT}/.run/center.pid"
WEB_PID_FILE="${STACK_ROOT}/.run/web.pid"

# 中心配置文件（形状见 wist-center/wist-center.toml）。
# 落**栈内** `<栈>/dev/configs/center/`（不再用 `~/.wist-center/`）—— 刻意不放在 .run/ 下：
# .run 是可随手清掉的运行目录，而 dev/configs 在 sys-prj.yml 的 ignore/protect 里（受保护、不入库）。
# 可用 WIST_CENTER_CONFIG 指向别处。凭据（admin token / hmac secret）已迁到下面的密钥文件，
# 本文件里只留 `${SEC_*}` 占位。
CENTER_CONFIG="${WIST_CENTER_CONFIG:-${STACK_ROOT}/dev/configs/center/wist-center.toml}"

# 中心凭据的密钥文件（与发布态同一机制）：配置里写 `${SEC_CENTER_*}`，值放这里；
# 启动时用 WIST_CENTER_SEC_FILE 指过去解析。落栈根 .wist/（与 compose 只读挂载同一目录）。
CENTER_SEC_FILE="${WIST_CENTER_SEC_FILE:-${STACK_ROOT}/.wist/sec-value.yml}"

# 中心服务端 TLS（**默认开**）：用**共享站点 CA**（发布态 `identity/center/`，dev 与发布态同一把）签的
# **本地叶证书**起 HTTPS；网关用同一把 CA 当信任锚 —— 即 dev 与发布态**共用 `identity/center/`**（同一站、
# 同一信任根）。CA 不在 dev 生成（它是站点身份，由发布态建）；dev 只签自己的叶。关掉：`WIST_CENTER_TLS=0`。
CENTER_TLS="${WIST_CENTER_TLS:-1}"
# 共享站点身份目录（与发布态同一份）：CA（信任根）+ CA-G 都在这里。
CENTER_IDENTITY_DIR="${WIST_CENTER_IDENTITY_DIR:-${STACK_ROOT}/identity/center}"
CENTER_TLS_CA_CERT="${CENTER_IDENTITY_DIR}/control-center.pem"
CENTER_TLS_CA_KEY="${CENTER_IDENTITY_DIR}/control-center-ca.key"
# dev 自己的叶证书（每态一份，**非**站点身份，故不落 identity）：落栈内 dev 目录。
CENTER_TLS_DIR="${WIST_CENTER_TLS_DIR:-${STACK_ROOT}/dev/configs/center/tls}"
CENTER_TLS_CERT="${CENTER_TLS_DIR}/server.crt.pem"
CENTER_TLS_KEY="${CENTER_TLS_DIR}/server.key.pem"
# 共享的网关客户端 CA（CA-G，与发布态同一把）—— 经 env 显式指给中心（dev 的配置目录不在 identity 下）。
CENTER_GATEWAY_CLIENT_CA_CERT="${CENTER_IDENTITY_DIR}/gateway-client-ca.pem"
CENTER_GATEWAY_CLIENT_CA_KEY="${CENTER_IDENTITY_DIR}/gateway-client-ca.key.pem"

# 本机默认网卡 IP（非回环）。VM / 跨机访问中心时用它作对外地址。
detect_lan_ip() {
  local iface ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  if [[ -n "${iface}" ]]; then
    ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
  fi
  if [[ -z "${ip:-}" ]]; then
    ip="$(ifconfig 2>/dev/null | awk '/inet /{ if ($2 != "127.0.0.1") { print $2; exit } }')"
  fi
  printf '%s' "${ip}"
}

# ── 端口 / 地址（覆盖用同名 env；`*_HOST_PORT` 与 sys/setting/vars.yml 同名同值）──
# 开发态默认**放开监听**（0.0.0.0）+ 对外用**域名**（hosts 解析）—— 让 VM / 跨机也能访问中心；
# **不要用 127.0.0.1**（那只有本机能连）。域名需在 Mac 与 VM 的 /etc/hosts 指向中心主机，例如：
#   127.0.0.1        center.dev.wist.lab     # Mac（本机回环）
#   <Mac 的局域网IP>  center.dev.wist.lab     # VM（指向中心主机）
CENTER_ADDR="${WARP_INSIGHT_CENTER_LISTEN:-0.0.0.0:3100}"
CENTER_PORT="${CENTER_ADDR##*:}"
# 对外域名（默认 center.dev.wist.lab）；置空则回落到本机网卡 IP。
CENTER_PUBLIC_DOMAIN="${WARP_INSIGHT_CENTER_PUBLIC_DOMAIN:-center.dev.wist.lab}"
# 对外地址（网关 / 虚拟机访问中心用的 host[:port]）。显式覆盖 > 域名 > 本机网卡 IP。
# 对外主机名会自动追加进服务器证书 SAN（换值会重签叶证书，CA 不变）。
CENTER_PUBLIC_HOST="${WARP_INSIGHT_CENTER_PUBLIC_HOST:-}"
if [[ -z "${CENTER_PUBLIC_HOST}" ]]; then
  if [[ -n "${CENTER_PUBLIC_DOMAIN}" ]]; then
    CENTER_PUBLIC_HOST="${CENTER_PUBLIC_DOMAIN}:${CENTER_PORT}"
  else
    _center_lan_ip="$(detect_lan_ip)"
    if [[ -n "${_center_lan_ip}" ]]; then
      CENTER_PUBLIC_HOST="${_center_lan_ip}:${CENTER_PORT}"
    else
      CENTER_PUBLIC_HOST="127.0.0.1:${CENTER_PORT}"
    fi
  fi
fi
WEB_URL="${WEB_URL:-http://127.0.0.1:5173}"
PG_PORT="${PG_HOST_PORT:-${PG_PORT:-55432}}"
VM_PORT="${VM_HOST_PORT:-${VM_PORT:-28429}}"

# 中心对外协议（http / https）；start_center / start_web 各自按 TLS 开关设定。
CENTER_SCHEME="http"
# 前端地址解析出的端口（start_web 与 svc.sh stop 共用）。
WEB_PORT=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

web_port() {
  python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').port or 80)"
}

# 本机可达的 loopback host（listen 为 0.0.0.0/:: 时换成 127.0.0.1，供前端代理用）。
center_loopback_host() {
  local h="${CENTER_ADDR%:*}"
  [[ -z "${h}" || "${h}" == "0.0.0.0" || "${h}" == "::" ]] && h="127.0.0.1"
  printf '%s' "${h}"
}

# 对外 host（去掉端口）。
center_public_hostname() {
  printf '%s' "${CENTER_PUBLIC_HOST%:*}"
}

# 服务器证书 SAN：恒含 localhost/127.0.0.1；再按对外主机追加（IP 走 IP:，其余走 DNS:）。
center_san() {
  local san="DNS:localhost,IP:127.0.0.1" pub
  pub="$(center_public_hostname)"
  if [[ -n "${pub}" && "${pub}" != "localhost" && "${pub}" != "127.0.0.1" ]]; then
    if [[ "${pub}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      san="${san},IP:${pub}"
    else
      san="${san},DNS:${pub}"
    fi
  fi
  printf '%s' "${san}"
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
# 注意：
#   · 必须带 -sTCP:LISTEN —— 否则 lsof 会把与端口的普通连接（例如浏览器的页面连接）
#     也列出来，那就可能误杀无关进程。
#   · 必须校验进程命令行匹配 `pattern` —— 端口可能被容器端口转发（macOS 上是 OrbStack /
#     Docker Desktop 的 helper）占用，无边界的 `kill $(lsof -ti :port)` 会把它们一起杀掉，
#     导致 Docker API 断连。
kill_port_holder() {
  local port="$1"
  local label="${2:-端口}"
  local pattern="${3:-}"
  local holders pid matched=()
  holders="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "${holders}" ]] && return 0
  for pid in ${holders}; do
    if [[ -z "${pattern}" ]] || ps -p "${pid}" -o command= 2>/dev/null | grep -Eq "${pattern}"; then
      matched+=("${pid}")
    else
      echo "  端口 ${port} 的监听者 pid=${pid} 不匹配 \"${pattern}\"，跳过（可能是容器/端口转发）"
    fi
  done
  [[ ${#matched[@]} -eq 0 ]] && return 0
  echo "  端口 ${port} 仍被占用（${label}），清理：${matched[*]}"
  kill "${matched[@]}" 2>/dev/null || true
  sleep 0.5
}

# 停服：优先 pidfile（并校验 pid 确实是目标进程，防 pid 复用），退化到端口占用者。
# stop_service <显示名> <pidfile> <端口> <pidfile 进程特征> [端口监听者特征]
#   · 端口特征缺省同 pidfile 特征；web 的子孙进程是 node/vite，需要单独传。
#   · 端口兜底**同样校验特征**：否则会把容器端口转发（OrbStack / Docker Desktop helper）
#     当成 dev 进程杀掉，连带 Docker API 断连。
stop_service() {
  local label="$1"
  local pidfile="$2"
  local port="$3"
  local pattern="$4"
  local port_pattern="${5:-$4}"
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
      kill_port_holder "${port}" "${label}" "${port_pattern}"
      return 0
    fi
    echo "${label} 的 ${pidfile} 记的是 pid=${pid}，但该进程不含 \"${pattern}\"（pid 可能已被复用），忽略 pidfile。"
  fi

  local holders holder matched=()
  holders="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -z "${holders}" ]]; then
    echo "${label} 未在运行（端口 ${port} 无监听）"
    remove_pidfile "${pidfile}"
    return 0
  fi
  for holder in ${holders}; do
    if ps -p "${holder}" -o command= 2>/dev/null | grep -Eq "${port_pattern}"; then
      matched+=("${holder}")
    else
      echo "端口 ${port} 被非目标进程占用（pid=${holder}），不杀：$(ps -p "${holder}" -o command= 2>/dev/null | cut -c1-120)"
    fi
  done
  if [[ ${#matched[@]} -eq 0 ]]; then
    echo "${label} 未在运行（端口 ${port} 的监听者不是 ${port_pattern}）"
    remove_pidfile "${pidfile}"
    return 0
  fi
  echo "按端口 ${port} 停止 ${label}（pid=${matched[*]}）"
  kill "${matched[@]}" 2>/dev/null || true
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
    echo "PostgreSQL 不可达（127.0.0.1:${PG_PORT}）→ 本地 JSON 文件存储（如需 PG：./dev/svc.sh start deps）"
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
    echo "VictoriaMetrics 不可达（127.0.0.1:${VM_PORT}）→ 不推送时序（如需：./dev/svc.sh start deps）"
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
# 之后复用同一份 → token 不再每次启动都变；再把凭据迁到密钥文件（持久化）。需先 build_center。
ensure_center_config() {
  if [[ -f "${CENTER_CONFIG}" ]]; then
    echo "中心配置：${CENTER_CONFIG}（复用已有凭据）"
  else
    echo "== 生成中心配置 =="
    "${CENTER_CRATE}/target/debug/wist-center" init-config "${CENTER_CONFIG}"
  fi
  # 凭据迁到密钥文件（`.wist/sec-value.yml`），配置里只留 ${SEC_*}。
  ensure_center_secret "${CENTER_CONFIG}"
}

# 读配置里 `key = "..."` 的字面值（只匹配单行，够我们自己生成的配置）。
config_literal() {
  python3 - "$1" "$2" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
match = re.search(rf'^\s*{re.escape(sys.argv[2])}\s*=\s*"(.*)"\s*$', text, re.M)
print(match.group(1) if match else "")
PY
}

# 中心凭据（admin_token / hmac_secret）的**密钥文件**化：值落 `<栈根>/.wist/sec-value.yml`
# （键 center_admin_token / center_hmac_secret），配置里只留 `${SEC_CENTER_*}`；中心启动时用
# `WIST_CENTER_SEC_FILE` 指过去解析（见 config.rs 的 secret_dict）。
ensure_center_secret() {
  local config="$1"
  mkdir -p "$(dirname "${CENTER_SEC_FILE}")"

  # 现有**字面**值（老配置 / init-config 生成的）优先迁入；否则随机。
  local lit_admin lit_hmac
  lit_admin="$(config_literal "${config}" admin_token)"
  lit_hmac="$(config_literal "${config}" hmac_secret)"
  [[ -f "${CENTER_SEC_FILE}" ]] || : >"${CENTER_SEC_FILE}"
  python3 - "${CENTER_SEC_FILE}" "${lit_admin}" "${lit_hmac}" <<'PY'
import re, secrets, sys
path, lit_admin, lit_hmac = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as handle:
    text = handle.read()

def value_for(literal, nbytes):
    # 已是占位符（如 ${SEC_CENTER_ADMIN_TOKEN}）不算值，重新生成。
    return literal if literal and not literal.startswith("${") else secrets.token_hex(nbytes)

for key, literal in (("center_admin_token", lit_admin), ("center_hmac_secret", lit_hmac)):
    if re.search(rf"(?m)^\s*{key}\s*:", text):
        print(f"  复用已有 {key}：{path}")
        continue
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"{key}: {value_for(literal, 24)}\n"
    print(f"  已在密钥文件写入 {key}：{path}")
with open(path, "w") as handle:
    handle.write(text)
PY
  chmod 600 "${CENTER_SEC_FILE}"

  # 配置统一改写为 `${SEC_CENTER_*}`（无论原来是字面还是已占位）。
  python3 - "${config}" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as handle:
    text = handle.read()

def set_key(text, key, setting, section):
    if re.search(rf"(?m)^\s*{key}\s*=", text):
        return re.sub(rf"(?m)^\s*{key}\s*=.*$", setting, text, count=1)
    text, n = re.subn(rf"(?m)^(\[{section}\]\s*)$", lambda m: m.group(1) + "\n" + setting, text, count=1)
    if n != 1:
        sys.exit(f"配置里找不到 [{section}] 段，无法写入 {key}")
    return text

text = set_key(text, "admin_token", 'admin_token = "${SEC_CENTER_ADMIN_TOKEN}"', "server")
text = set_key(text, "hmac_secret", 'hmac_secret = "${SEC_CENTER_HMAC_SECRET}"', "security")
with open(path, "w") as handle:
    handle.write(text)
print("  admin_token / hmac_secret 改写为 ${SEC_CENTER_*}（值在密钥文件）")
PY
}

# 读中心 admin token（提示 / 注入 vite 代理用）：优先密钥文件（键 center_admin_token），
# 回落配置里的值；但**占位符（含 `${`）不是可用 token**，这时返回空。
center_admin_token() {
  if [[ -f "${CENTER_SEC_FILE}" ]]; then
    python3 - "${CENTER_SEC_FILE}" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
match = re.search(r'^\s*center_admin_token\s*:\s*(.*?)\s*$', text, re.M)
print(match.group(1).strip().strip('"\'') if match else "")
PY
    return
  fi
  local fallback
  fallback="$(config_literal "${CENTER_CONFIG}" admin_token)"
  [[ "${fallback}" == *'${'* ]] && fallback=""
  printf '%s' "${fallback}"
}

# 确保开发态 TLS 材料存在：用**共享站点 CA**（`identity/center/control-center.pem`，与发布态同一把）
# 签一张**本地叶证书**（SAN 覆盖 localhost/127.0.0.1 与对外主机 CENTER_PUBLIC_HOST）。只在 TLS 开启时用。
# **不能**用「自签证书既当信任锚又当叶」—— rustls 会拒（curl 未必），所以走「CA 签叶」这条路。
# CA **不在 dev 生成**（它是站点身份，发布态 `scripts/gen-center-ca.sh` 建的）—— 缺就报错并给出处置。
# 对外主机/域名变了（SAN 记录不一致）→ 只重签本地叶证书，CA 不动（已分发的信任根仍有效）。
ensure_center_tls() {
  center_tls_enabled || return 0
  local san
  san="$(center_san)"
  if [[ -f "${CENTER_TLS_CERT}" && -f "${CENTER_TLS_KEY}" \
        && -f "${CENTER_TLS_DIR}/server.san" && "$(cat "${CENTER_TLS_DIR}/server.san")" == "${san}" ]]; then
    echo "中心 TLS 材料：本地叶 ${CENTER_TLS_CERT}（复用，SAN=${san}；CA=${CENTER_TLS_CA_CERT}）"
    return 0
  fi
  require_cmd openssl
  if [[ ! -f "${CENTER_TLS_CA_CERT}" || ! -f "${CENTER_TLS_CA_KEY}" ]]; then
    echo "缺共享站点 CA：${CENTER_TLS_CA_CERT} / ${CENTER_TLS_CA_KEY}" >&2
    echo "  先让发布态建它（在栈根跑 \`gops sys localize\`，或 \`scripts/gen-center-ca.sh ${CENTER_IDENTITY_DIR} <对外域名>\`）；" >&2
    echo "  只想本地明文跑就设 WIST_CENTER_TLS=0。" >&2
    exit 1
  fi
  mkdir -p "${CENTER_TLS_DIR}"
  # 本地叶证书：用**共享 CA** 签（CA 不重生成）；序列号落 dev 本地（不碰 identity/center/）。
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${CENTER_TLS_KEY}" -out "${CENTER_TLS_DIR}/server.csr.pem" \
    -subj "/CN=wist-center-dev" >/dev/null 2>&1
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n' "${san}" \
    >"${CENTER_TLS_DIR}/server.ext"
  openssl x509 -req -in "${CENTER_TLS_DIR}/server.csr.pem" \
    -CA "${CENTER_TLS_CA_CERT}" -CAkey "${CENTER_TLS_CA_KEY}" \
    -CAserial "${CENTER_TLS_DIR}/control-center.srl" -CAcreateserial \
    -out "${CENTER_TLS_CERT}" -days 397 -extfile "${CENTER_TLS_DIR}/server.ext" >/dev/null 2>&1
  chmod 600 "${CENTER_TLS_KEY}"
  printf '%s' "${san}" >"${CENTER_TLS_DIR}/server.san"
  echo "  共享站点 CA（锚）：${CENTER_TLS_CA_CERT}"
  echo "  本地叶证书：${CENTER_TLS_CERT}（SAN=${san}）"
}

# 启动中心后端（后台）；需先 resolve_dependencies + build_center + ensure_center_config。
start_center() {
  local center_bin="${CENTER_CRATE}/target/debug/wist-center"
  mkdir -p "${ARTIFACT_DIR}"

  # TLS 关闭时这四项传空：中心把空值当未配置（明文 HTTP，public_url/ca_cert 保留配置文件值）。
  local tls_cert="" tls_key="" public_url="" ca_cert=""
  CENTER_SCHEME="http"
  if center_tls_enabled; then
    ensure_center_tls
    CENTER_SCHEME="https"
    tls_cert="${CENTER_TLS_CERT}"
    tls_key="${CENTER_TLS_KEY}"
    # 信任根（CA-S）分发给网关：既作中心的信任锚，也作 gateway 的 trust_bundle。
    public_url="https://${CENTER_PUBLIC_HOST}"
    ca_cert="${CENTER_TLS_CA_CERT}"
  fi

  echo "== 启动 wist-center（${CENTER_SCHEME}://${CENTER_ADDR}）=="
  # 配置文件提供默认值；env 覆盖运行态：监听地址、存储/制品目录、依赖地址、TLS；
  # 凭据（${SEC_CENTER_*}）由 WIST_CENTER_SEC_FILE 指向的密钥文件解析。
  # COS 解析的 region（下载 host 里那段）：**钉住**，免得自动试时回落到陈旧的其他区域桶；
  # 换区域 / 回到自动试：改这里的默认值，或导出 WIST_CENTER_COS_REGION=（置空即自动试）。
  env \
    WIST_CENTER_CONFIG="${CENTER_CONFIG}" \
    WIST_CENTER_SEC_FILE="${CENTER_SEC_FILE}" \
    WARP_INSIGHT_CENTER_GATEWAY_CLIENT_CA_CERT_PATH="${CENTER_GATEWAY_CLIENT_CA_CERT}" \
    WARP_INSIGHT_CENTER_GATEWAY_CLIENT_CA_KEY_PATH="${CENTER_GATEWAY_CLIENT_CA_KEY}" \
    WARP_INSIGHT_CENTER_LISTEN="${CENTER_ADDR}" \
    WARP_INSIGHT_CENTER_STORE_PATH="${RUN_DIR}/store.json" \
    WARP_INSIGHT_CENTER_ARTIFACT_DIR="${ARTIFACT_DIR}" \
    WARP_INSIGHT_CENTER_DATABASE_URL="${DATABASE_URL:-}" \
    WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL="${VM_URL:-}" \
    WARP_INSIGHT_CENTER_SERVER_CERT_PATH="${tls_cert}" \
    WARP_INSIGHT_CENTER_SERVER_KEY_PATH="${tls_key}" \
    WARP_INSIGHT_CENTER_PUBLIC_URL="${public_url}" \
    WARP_INSIGHT_CENTER_CA_CERT_PATH="${ca_cert}" \
    WIST_CENTER_COS_REGION="${WIST_CENTER_COS_REGION:-ap-hongkong}" \
    nohup "${center_bin}" >"${CENTER_LOG}" 2>&1 &
  local center_pid=$!
  write_pidfile "${CENTER_PID_FILE}" "${center_pid}"
  if wait_until "wist-center" center_ready; then
    return 0
  fi
  echo "  wist-center 未就绪，日志：${CENTER_LOG}" >&2
  return 1
}

# 启动管理前端（后台）。vite 的 /api 反代到中心，目标取 CENTER_ADDR。
start_web() {
  require_cmd npm
  # 代理目标协议随 TLS 开关 —— 只起 web（不跑 start_center）时它没设过，这里补上。
  if center_tls_enabled; then CENTER_SCHEME="https"; else CENTER_SCHEME="http"; fi
  if [[ ! -d "${WEB_DIR}/node_modules" ]]; then
    echo "wist-center-web 依赖缺失：${WEB_DIR}/node_modules（先 cd 到该目录执行 npm install）" >&2
    exit 1
  fi
  WEB_PORT="$(web_port)"
  if [[ "$(web_status)" == "200" ]]; then
    echo "wist-center-web 已在运行（${WEB_URL}），复用。"
    return 0
  fi
  local host
  host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${WEB_URL}').hostname or '127.0.0.1')")"

  echo "== 启动 wist-center-web（${WEB_URL}）=="
  (
    cd "${WEB_DIR}"
    export WARP_INSIGHT_WEB_PROXY_TARGET="${CENTER_SCHEME}://$(center_loopback_host):${CENTER_PORT}"
    # 中心 admin token 的**已解析**值（密钥文件里那份）：交给 vite 代理补 Authorization，
    # 免得它去读配置里剩下的 `${SEC_CENTER_ADMIN_TOKEN}` 占位符、把占位符当 token 发出去。
    # 若拿不到真值（回落到占位符/空）→ 不注入，让页面手填。
    local dev_token
    dev_token="$(center_admin_token)"
    [[ "${dev_token}" == *'${'* ]] && dev_token=""
    export WIST_CENTER_DEV_ADMIN_TOKEN="${dev_token}"
    exec nohup npm run dev -- --host "${host}" --port "${WEB_PORT}" --strictPort >"${WEB_LOG}" 2>&1
  ) &
  local web_pid=$!
  write_pidfile "${WEB_PID_FILE}" "${web_pid}"
  echo "  启动 wist-center-web：${WEB_URL} (pid=${web_pid})"
  if wait_until "wist-center-web" web_status; then
    return 0
  fi
  echo "  wist-center-web 未就绪（日志 ${WEB_LOG}）" >&2
  return 1
}

# 打印访问信息。
#
# 参数 = 本次 start 选中的组件（deps|center|web）。**按实际可达状态**（端口/HTTP）判定，
# 而不是读 start_center/start_web 设的全局量 —— 各组件在子 shell 里起（见 svc.sh），
# 那些全局量出了子 shell 就是空，照它打印会「起了却什么都不显示」。
print_access_info() {
  local scheme token want
  local do_center=0 do_web=0
  for want in "$@"; do
    [[ "${want}" == "center" ]] && do_center=1
    [[ "${want}" == "web" ]] && do_web=1
  done

  echo
  echo "开发态已就绪，后台常驻。停止：./dev/svc.sh stop"

  if [[ "${do_center}" == "1" ]] && port_open "${CENTER_PORT}"; then
    if center_tls_enabled; then scheme="https"; else scheme="http"; fi
    echo "  中心 API：${scheme}://${CENTER_PUBLIC_HOST}（监听 ${CENTER_ADDR}）"
    token="$(center_admin_token)"
    [[ -n "${token}" ]] && echo "  管理 token：${token}（来自 ${CENTER_SEC_FILE}，长期有效）"
    echo "    （在管理页面填入该 token 后开启 5s 轮询刷新）"
    echo "    换一套凭据：删掉 ${CENTER_SEC_FILE} 后重跑本脚本（旧 token 立即失效）"
    echo "  中心日志：${CENTER_LOG}"
  fi

  if [[ "${do_web}" == "1" ]] && [[ "$(web_status)" == "200" ]]; then
    echo "  管理页面：${WEB_URL}"
    echo "  前端日志：${WEB_LOG}"
  fi
  echo
}

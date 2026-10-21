#!/usr/bin/env bash
# 备料控制中心配置的**渲染值** <配置目录>/wist-center.value.json（localize 里 gx.tpl 的输入），
# 并在缺失时生成控制中心 CA（信任根 + 服务器证书）、**网关客户端 CA（CA-G）**。
#
# 用法：
#   scripts/init-center.sh <配置目录> <对外域名>
#     scripts/init-center.sh configs/center center.example.com
#
# 落点（对齐 foundation/config-and-state-layout）：
#   站点身份（CA / 服务器证书 / 私钥）→ 栈根 `identity/center/`（dev/prod 共用、整体作对外契约）；
#     可用 env CENTER_IDENTITY_DIR 覆盖。它**不在**资源树（configs/）里，容器只读挂到 /wist-center/ca。
#   渲染值 wist-center.value.json + store/logs → <配置目录>（configs/center，按语义拆挂到容器 /wist-center）。
#   现场态（站点事实 public_url）分「声明 / 值」：**声明** `identity/center/wist-center-pub.toml`
#     （只写 `${VAR}`）由 tpl 机制渲染（可重渲）；**值**在同目录 `.env`，由
#     scripts/init-center-pub.sh 按缺补齐（升级 / 重渲永不覆盖）。
#   凭据密钥文件（栈根 `.wist/sec-value.yml`）：**运维提供**，本脚本只校验（缺失/为空直接报错）。
#
# 环境（gops 把合并后的系统变量以**环境变量**注入 localize 流程）：
#   WEB_WGC_DOMAIN          对外域名（第 2 参数缺省时用它）；也决定 public_url 与证书 SAN
#   API_WGC_DOMAIN / WEB_WGS_DOMAIN   覆盖派生的 `api.<域名>` / `station.<域名>`（也进证书 SAN）
#   PG_SUPERUSER / PG_SUPERUSER_PASSWORD / PG_DB   中心存储 DSN 的组成（容器网络内服务名 postgres）
#   VICTORIA_METRICS_URL   时序库地址（容器网络内服务名 victoria-metrics）
#   GATEWAY_IMAGE          生成网关安装命令用的镜像（写进 [artifacts] gateway_image）
#
# 幂等：CA 已存在即跳过（换公章会让所有已分发出去的信任根失效，须显式轮换）；
#       value.json 内容与当前一致即不碰 mtime；密钥文件**只读不写**。
set -euo pipefail

CONFIG_DIR="${1:-configs/center}"
DOMAIN="${2:-${WEB_WGC_DOMAIN:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 站点身份（dev/prod 共用）：控制中心 CA / 服务器证书 / 私钥放栈根 `identity/center/`，
# **不进资源树**（configs/）、整体作对外契约（sys-prj.yml 的 `contract: - identity`）。
# 容器只读挂它到 /wist-center/ca（模板 ca_cert_path 指向 /wist-center/ca/control-center.pem）。
IDENTITY_DIR="${CENTER_IDENTITY_DIR:-${STACK_ROOT}/identity/center}"

# 中心凭据的密钥文件：wist-center 配置里写 `${SEC_CENTER_ADMIN_TOKEN}` / `${SEC_CENTER_HMAC_SECRET}`，
# 启动时由 `WIST_CENTER_SEC_FILE` 指向本文件解析（compose 只读挂 <栈根>/.wist → /secrets）。
SEC_FILE="${STACK_ROOT}/.wist/sec-value.yml"

# 密钥读取统一走 gops（路径/权限/格式校验都在那里）；见 scripts/lib/sec.sh。
# shellcheck source=lib/sec.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/sec.sh"

PG_SUPERUSER="${PG_SUPERUSER:-demo}"
PG_SUPERUSER_PASSWORD="${PG_SUPERUSER_PASSWORD:-demo}"
PG_DB="${PG_DB:-insight_demo}"
VICTORIA_METRICS_URL="${VICTORIA_METRICS_URL:-}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-wist-gateway:latest}"

note() { echo "  $*"; }

if [[ -z "${DOMAIN}" ]]; then
  echo "用法: $0 <配置目录> <对外域名>  （或设 WEB_WGC_DOMAIN）" >&2
  exit 2
fi

case "${DOMAIN}" in
  *[!A-Za-z0-9.-]* | .* | *.)
    echo "域名不合法：'${DOMAIN}'（只允许 [A-Za-z0-9.-]，且不以点开头/结尾）" >&2
    exit 1
    ;;
esac

mkdir -p "${IDENTITY_DIR}" "${CONFIG_DIR}/state" "${CONFIG_DIR}/logs" "${STACK_ROOT}/artifacts"

# 服务器证书 SAN 要同时覆盖：管理面/UI 域名、**公网网关面域名**、WarpStation 域名。
# 后两者留空 = 派生 `api.<WEB_WGC_DOMAIN>` / `station.<WEB_WGC_DOMAIN>`，可用
# API_WGC_DOMAIN / WEB_WGS_DOMAIN 覆盖。
API_WGC_DOMAIN="${API_WGC_DOMAIN:-api.${DOMAIN}}"
WEB_WGS_DOMAIN="${WEB_WGS_DOMAIN:-station.${DOMAIN}}"
EXTRA_SANS="${API_WGC_DOMAIN},${WEB_WGS_DOMAIN}"

# ── 1) 控制中心 CA（信任根 + 服务器证书）：缺失才生成，落站点身份目录 ──
# control-center.pem 是分发给所有网关的信任根（control_center.trust_bundle）；
# 换它 = 换公章，已分发的信任根全部失效 → 非缺失一律不碰，轮换要显式 FORCE=1。
if [[ -f "${IDENTITY_DIR}/control-center.pem" ]]; then
  note "CA 已存在（${IDENTITY_DIR}/control-center.pem），跳过生成"
else
  note "生成控制中心 CA / 服务器证书（SAN: ${DOMAIN}）→ ${IDENTITY_DIR}"
  "${SCRIPT_DIR}/gen-center-ca.sh" "${IDENTITY_DIR}" "${DOMAIN}" "${EXTRA_SANS}"
fi

# ── 1b) 服务器证书（叶）：SAN 必须覆盖对外域名（+ localhost/127.0.0.1）──
#   前端反代（web 容器，见 sys/docker-compose.yml）用它终止 HTTPS；网关校 init_url 主机名也用它。
#   **CA 不变** —— 换域名 / 加 SAN 只重签这张叶；幂等（已覆盖就不重签）。
"${SCRIPT_DIR}/ensure-center-server-cert.sh" "${IDENTITY_DIR}" "${DOMAIN}" "${EXTRA_SANS}"

# ── 1c) 网关客户端 CA（CA-G）：缺失才生成 ──
#   中心用它给「注册入网」的网关签发**客户端证书**（mTLS）。路径不另配：中心默认取同目录的
#   `gateway-client-ca.{pem,key.pem}`（= 站点身份 `identity/center/`，容器**只读**挂到 /wist-center/ca）。
#   **必须宿主侧备料**：该目录是**只读挂载**，缺 CA-G 时中心会尝试现生成，直接以
#   `failed to write /wist-center/ca/gateway-client-ca.tmp: Read-only file system` 崩溃重启
#   （全新现场、以及从旧版本升上来但没搬过 CA-G 的现场，都会踩）。
#   幂等：已存在即跳过 —— 换 CA-G = 已入网网关的客户端证书全部失效（须重入网），非缺失一律不碰。
#   密钥用 EC P-256 / PKCS#8（与中心自身生成的一致）；证书自签、basicConstraints=CA:TRUE。
GW_CLIENT_CA_KEY="${IDENTITY_DIR}/gateway-client-ca.key.pem"
GW_CLIENT_CA_CRT="${IDENTITY_DIR}/gateway-client-ca.pem"
if [[ -f "${GW_CLIENT_CA_KEY}" && -f "${GW_CLIENT_CA_CRT}" ]]; then
  note "网关客户端 CA 已存在，跳过生成：${GW_CLIENT_CA_CRT}"
else
  command -v openssl >/dev/null 2>&1 || { echo "错误：缺少 openssl，无法生成网关客户端 CA" >&2; exit 1; }
  note "生成网关客户端 CA（CA-G）→ ${IDENTITY_DIR}"
  GW_CLIENT_CA_CSR="${IDENTITY_DIR}/gateway-client-ca.csr"
  GW_CLIENT_CA_EXT="${IDENTITY_DIR}/gateway-client-ca.ext"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${GW_CLIENT_CA_KEY}"
  openssl req -new -key "${GW_CLIENT_CA_KEY}" -subj "/CN=WarpInsight Gateway Client CA" -out "${GW_CLIENT_CA_CSR}"
  cat > "${GW_CLIENT_CA_EXT}" <<EOF
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
EOF
  openssl x509 -req -in "${GW_CLIENT_CA_CSR}" -signkey "${GW_CLIENT_CA_KEY}" \
    -days "${GW_CLIENT_CA_DAYS:-3650}" -sha256 -extfile "${GW_CLIENT_CA_EXT}" \
    -out "${GW_CLIENT_CA_CRT}"
  rm -f "${GW_CLIENT_CA_CSR}" "${GW_CLIENT_CA_EXT}"
fi

# 注：**现场态（站点事实 `public_url`）不在本脚本里** —— **声明** `${IDENTITY_DIR}/wist-center-pub.toml`
#   （只写 `${VAR}`、可重渲）由 tpl 渲染；**值** `${IDENTITY_DIR}/.env` 由 scripts/init-center-pub.sh
#   按缺补齐（升级 / 重渲永不覆盖；compose 用 WIST_CENTER_PUB_CONFIG 指过去）。

# ── 2) 中心凭据：**只校验**，不生成 / 不补键（密钥是运维输入）──
#   配置里只写 `${SEC_CENTER_ADMIN_TOKEN}` / `${SEC_CENTER_HMAC_SECRET}`，中心启动时用
#   `WIST_CENTER_SEC_FILE` 从密钥文件解析（键 center_admin_token / center_hmac_secret
#   → orion-sec 规范成 SEC_CENTER_ADMIN_TOKEN / SEC_CENTER_HMAC_SECRET）。
#   center_db_password 供 center_app 使用（db-init 与中心 DSN 共用）。
required_center_secrets_hint() {
  cat >&2 <<'EOF'
请在 <栈根>/.wist/sec-value.yml（0640：属主=部署账号、属组=999）里提供：
  center_admin_token: "..."
  center_hmac_secret: "..."
  center_db_password: "..."
EOF
}

[[ -f "${SEC_FILE}" ]] || {
  echo "错误：缺少密钥文件 ${SEC_FILE}" >&2
  required_center_secrets_hint
  exit 1
}

# 前两个仅用于校验：运行时由容器自己从密钥文件解析。
CENTER_ADMIN_TOKEN="$(sec_get_optional "${STACK_ROOT}" center_admin_token)"
CENTER_HMAC_SECRET="$(sec_get_optional "${STACK_ROOT}" center_hmac_secret)"
CENTER_DB_PASSWORD="$(sec_get_optional "${STACK_ROOT}" center_db_password)"

missing_secrets=()
[[ -n "${CENTER_ADMIN_TOKEN}" ]] || missing_secrets+=("center_admin_token")
[[ -n "${CENTER_HMAC_SECRET}" ]] || missing_secrets+=("center_hmac_secret")
[[ -n "${CENTER_DB_PASSWORD}" ]] || missing_secrets+=("center_db_password")
if [[ ${#missing_secrets[@]} -gt 0 ]]; then
  echo "错误：${SEC_FILE} 缺少（或为空）：${missing_secrets[*]}" >&2
  required_center_secrets_hint
  exit 1
fi

# 纯数字密码会被 WarpStation 的 config crate（try_parsing）当成整数；中心侧虽不走 config crate，
# 但统一约束，避免运维把同一类密码复制到 station。
case "${CENTER_DB_PASSWORD}" in
  *[!0-9]*) ;;
  *)
    echo "错误：center_db_password 是纯数字；请改成含字母的值（.wist/sec-value.yml）" >&2
    exit 1
    ;;
esac

# db-schema / 中心连接使用的 app 账号（db-init 创建并收紧权限）。
CENTER_ENV="${CONFIG_DIR}/center.env"
tmp_env="$(mktemp "${CONFIG_DIR}/.center.env.XXXXXX")"
cat >"${tmp_env}" <<EOF
PGUSER=center_app
PGPASSWORD=${CENTER_DB_PASSWORD}
PGDATABASE=${PG_DB}
EOF
chmod 600 "${tmp_env}"
if [[ -f "${CENTER_ENV}" ]] && cmp -s "${tmp_env}" "${CENTER_ENV}"; then
  rm -f "${tmp_env}"
  note "center.env 无变化：${CENTER_ENV}"
else
  mv -f "${tmp_env}" "${CENTER_ENV}"
  note "已写 center.env（600）：${CENTER_ENV}"
fi

# ── 3) 渲染值 value.json（gx.tpl 的输入）──
# 必须落在脚本里，不能在 operators.gxl 里 printf：GXL 字符串不做转义还原，且 /bin/sh 可能是 dash
# （与 init-web-conf.sh 同一原因）。值本身都经过上面的域名校验 / 由环境变量给定，不含特殊字符。
VALUE_JSON="${CONFIG_DIR}/wist-center.value.json"
tmp="$(mktemp "${CONFIG_DIR}/.wist-center.value.XXXXXX")"
cat >"${tmp}" <<EOF
{
  "database_url": "postgres://center_app:${CENTER_DB_PASSWORD}@postgres:5432/${PG_DB}",
  "store_path": "state/warp-insight-center-store.json",
  "victoriametrics_url": "${VICTORIA_METRICS_URL}",
  "ca_cert_path": "/wist-center/ca/control-center.pem",
  "artifact_dir": "artifacts",
  "gateway_image": "${GATEWAY_IMAGE}"
}
EOF
chmod 644 "${tmp}"

if [[ -f "${VALUE_JSON}" ]] && cmp -s "${tmp}" "${VALUE_JSON}"; then
  rm -f "${tmp}"
  note "渲染值与当前一致，跳过：${VALUE_JSON}"
else
  mv -f "${tmp}" "${VALUE_JSON}"
  note "已写渲染值：${VALUE_JSON}（由 localize 渲染 wist-center.toml）"
fi

note "控制中心备料完成：配置 ${CONFIG_DIR} + 身份 ${IDENTITY_DIR}（CA、渲染值就绪；localize 随后渲染 wist-center.toml）"
note "中心凭据密钥文件：${SEC_FILE}（键 center_admin_token / center_hmac_secret）"

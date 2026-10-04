#!/usr/bin/env bash
# 备料控制中心配置的**渲染值** <配置目录>/wist-center.value.json（localize 里 gx.tpl 的输入），
# 并在缺失时生成控制中心 CA（信任根 + 服务器证书）。
#
# 用法：
#   scripts/init-center.sh <配置目录> <对外域名>
#     scripts/init-center.sh configs/center center.example.com
#
# 环境（gops 把合并后的系统变量以**环境变量**注入 localize 流程）：
#   CENTER_DOMAIN          对外域名（第 2 参数缺省时用它）；也决定 public_url 与证书 SAN
#   CENTER_EXTRA_SANS      附加 SAN（逗号分隔的域名/IP，备用入口）
#   PG_USER / PG_PASSWORD / PG_DB   中心存储 DSN 的组成（容器网络内服务名 postgres）
#   VICTORIA_METRICS_URL   时序库地址（容器网络内服务名 victoria-metrics）
#   GATEWAY_IMAGE          生成网关安装命令用的镜像（写进 [artifacts] gateway_image）
#
# 幂等：CA 已存在即跳过（换公章会让所有已分发出去的信任根失效，须显式轮换）；
#       value.json 内容与当前一致即不碰 mtime。
set -euo pipefail

CONFIG_DIR="${1:-configs/center}"
DOMAIN="${2:-${CENTER_DOMAIN:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PG_USER="${PG_USER:-demo}"
PG_PASSWORD="${PG_PASSWORD:-demo}"
PG_DB="${PG_DB:-insight_demo}"
VICTORIA_METRICS_URL="${VICTORIA_METRICS_URL:-}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-wist-gateway:latest}"

note() { echo "  $*"; }

if [[ -z "${DOMAIN}" ]]; then
  echo "用法: $0 <配置目录> <对外域名>  （或设 CENTER_DOMAIN）" >&2
  exit 2
fi

case "${DOMAIN}" in
  *[!A-Za-z0-9.-]* | .* | *.)
    echo "域名不合法：'${DOMAIN}'（只允许 [A-Za-z0-9.-]，且不以点开头/结尾）" >&2
    exit 1
    ;;
esac

mkdir -p "${CONFIG_DIR}/ca" "${CONFIG_DIR}/state" "${CONFIG_DIR}/artifacts"

# ── 1) 控制中心 CA（信任根 + 服务器证书）：缺失才生成 ──
# control-center.pem 是分发给所有网关的信任根（control_center.trust_bundle）；
# 换它 = 换公章，已分发的信任根全部失效 → 非缺失一律不碰，轮换要显式 FORCE=1。
if [[ -f "${CONFIG_DIR}/ca/control-center.pem" ]]; then
  note "CA 已存在（${CONFIG_DIR}/ca/control-center.pem），跳过生成"
else
  note "生成控制中心 CA / 服务器证书（SAN: ${DOMAIN}）"
  CENTER_EXTRA_SANS="${CENTER_EXTRA_SANS:-}"
  "${SCRIPT_DIR}/gen-center-ca.sh" "${CONFIG_DIR}/ca" "${DOMAIN}" "${CENTER_EXTRA_SANS}"
fi

# ── 2) 渲染值 value.json（gx.tpl 的输入）──
# 必须落在脚本里，不能在 operators.gxl 里 printf：GXL 字符串不做转义还原，且 /bin/sh 可能是 dash
# （与 init-web-conf.sh 同一原因）。值本身都经过上面的域名校验 / 由环境变量给定，不含特殊字符。
VALUE_JSON="${CONFIG_DIR}/wist-center.value.json"
tmp="$(mktemp "${CONFIG_DIR}/.wist-center.value.XXXXXX")"
cat >"${tmp}" <<EOF
{
  "public_url": "https://${DOMAIN}",
  "database_url": "postgres://${PG_USER}:${PG_PASSWORD}@postgres:5432/${PG_DB}",
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
  note "已写渲染值：${VALUE_JSON}（public_url=https://${DOMAIN}）"
fi

note "控制中心备料完成：${CONFIG_DIR}（CA、渲染值就绪；localize 随后渲染 wist-center.toml）"

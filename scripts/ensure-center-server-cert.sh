#!/usr/bin/env bash
# 确保「控制中心服务器证书」存在，且 SAN 覆盖对外域名（+ localhost/127.0.0.1）。
#
# 用**已有站点 CA**（control-center-ca.key）签 —— **不替换 CA**；换域名 / 加 SAN 只重签这一张**叶证书**
# （已分发的信任根 control-center.pem 不变，网关无感）。前端反代（= web 容器，见 sys/docker-compose.yml）
# 用它终止 HTTPS。
#
# 幂等：现有证书 + SAN 记录与所需一致时**什么都不做**（不重签、不换叶、不碰 mtime）。
#
# 用法：
#   scripts/ensure-center-server-cert.sh [身份目录] [对外域名] [附加 SAN（逗号分隔的域名/IP）]
#     scripts/ensure-center-server-cert.sh identity/center center.example.com 10.0.0.8
#
# 环境：DAYS（有效期天数，默认 3650）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIR="${1:-identity/center}"
DOMAIN="${2:-}"
EXTRA="${3:-}"
CA_CRT="${DIR}/control-center.pem"
CA_KEY="${DIR}/control-center-ca.key"
CRT="${DIR}/control-center-server.crt"
KEY="${DIR}/control-center-server.key"
SAN_FILE="${DIR}/control-center-server.san"
DAYS="${DAYS:-3650}"

note() { echo "  $*"; }

if [[ -z "${DOMAIN}" ]]; then
  echo "用法: $0 <身份目录> <对外域名> [附加 SAN]" >&2
  exit 2
fi
if [[ ! -f "${CA_CRT}" || ! -f "${CA_KEY}" ]]; then
  echo "缺站点 CA：${CA_CRT} / ${CA_KEY}（先跑 scripts/gen-center-ca.sh）" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "错误: 需要 openssl" >&2; exit 1; }

# 所需 SAN：域名 + 附加（形如 1.2.3.4 → IP:，其余 → DNS:）+ localhost/127.0.0.1（本机直连测试）。
WANT="DNS:${DOMAIN}"
if [[ -n "${EXTRA}" ]]; then
  IFS=',' read -r -a extra <<< "${EXTRA}"
  for entry in "${extra[@]}"; do
    entry="$(echo "${entry}" | xargs)"
    [[ -z "${entry}" ]] && continue
    if echo "${entry}" | grep -Eq '^[0-9]+(\.[0-9]+){0,3}$'; then
      WANT="${WANT},IP:${entry}"
    else
      WANT="${WANT},DNS:${entry}"
    fi
  done
fi
WANT="${WANT},DNS:localhost,IP:127.0.0.1"

# 幂等：SAN 记录一致 → 跳过。
if [[ -f "${CRT}" && -f "${KEY}" && -f "${SAN_FILE}" && "$(cat "${SAN_FILE}")" == "${WANT}" ]]; then
  note "服务器证书已覆盖所需 SAN，跳过：${CRT}"
  exit 0
fi

mkdir -p "${DIR}"
openssl genrsa -out "${KEY}" 4096 >/dev/null 2>&1
openssl req -new -key "${KEY}" -subj "/CN=${DOMAIN}" -out "${DIR}/.center-server.csr" >/dev/null 2>&1
printf 'subjectAltName = %s\n' "${WANT}" >"${DIR}/.center-server.ext"
openssl x509 -req -in "${DIR}/.center-server.csr" \
  -CA "${CA_CRT}" -CAkey "${CA_KEY}" \
  -CAserial "${DIR}/control-center.srl" -CAcreateserial \
  -days "${DAYS}" -sha256 \
  -extfile "${DIR}/.center-server.ext" \
  -out "${CRT}" >/dev/null 2>&1
rm -f "${DIR}/.center-server.csr" "${DIR}/.center-server.ext"
chmod 600 "${KEY}"
printf '%s' "${WANT}" >"${SAN_FILE}"
note "已（重）签中心服务器证书：${CRT}（SAN=${WANT}）"

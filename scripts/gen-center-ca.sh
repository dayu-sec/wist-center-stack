#!/usr/bin/env bash
# 生成 WarpInsightCenter 控制面 CA 与服务器证书
#
# 产物：
#   control-center.pem        信任根（CA 证书，公开）→ 作为 Gateway 的
#                             control_center.trust_bundle 分发（config.toml）
#   control-center-server.key 中心服务器私钥（机密，留在控制中心）
#   control-center-server.crt 中心 TLS 服务器证书（由 CA 签发，含 SAN）
#
# 用法：
#   scripts/gen-center-ca.sh [输出目录] [服务端主机名] [附加 SAN]
#
# 附加 SAN 用逗号分隔（备用域名 / IP），按形如 1.2.3.4 自动判别 IP:，其余 DNS:：
#   scripts/gen-center-ca.sh configs/center/ca center.warpinsight.example 10.0.0.8
#
# 可覆盖环境变量：
#   CA_CN / DAYS   CA 主题名 / 有效期天数（默认 WarpInsight Control Center CA / 3650）
#   FORCE=1        已存在 CA 时强制重新生成（会换掉公章，已分发的信任根全部失效）
#
# 关键：服务器证书 SAN 必须覆盖 center 的 WARP_INSIGHT_CENTER_PUBLIC_URL 主机名/IP。
# 现代 TLS 客户端（rustls/reqwest）只按 SAN 校验主机名，无 SAN 或主机名不在 SAN 内时，
# server_tls_required=true 下网关访问 init_url 的 TLS 握手会失败。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认输出到 ~/.wist-center/ca（本地开发）；服务器部署可用绝对路径覆盖
OUT_DIR="${1:-${HOME}/.wist-center/ca}"
# 默认与 WARP_INSIGHT_CENTER_PUBLIC_URL 默认值（https://center.warpinsight.example）对齐
SERVER_CN="${2:-center.warpinsight.example}"
# 附加 SAN：逗号分隔的域名/IP，追加到 DNS:${SERVER_CN}
EXTRA_SANS="${3:-}"
CA_CN="${CA_CN:-WarpInsight Control Center CA}"
DAYS="${DAYS:-3650}"

command -v openssl >/dev/null 2>&1 || { echo "错误: 需要 openssl" >&2; exit 1; }

mkdir -p "${OUT_DIR}"
# 展示用绝对路径（支持相对/绝对 OUT_DIR）
DISPLAY_DIR="$(cd "${OUT_DIR}" && pwd)"

# 已有 CA 就不覆盖：重跑会换掉公章，所有已分发出去的信任根（control-center.pem）随之失效，
# 每个网关都要重发一遍。确认要轮换时用 FORCE=1 显式开启。
if [[ -f "${OUT_DIR}/control-center-ca.key" && "${FORCE:-0}" != "1" ]]; then
  echo "已存在 CA 私钥：${OUT_DIR}/control-center-ca.key，拒绝覆盖。" >&2
  echo "重新生成会换掉公章，已分发的 control-center.pem 全部失效（网关需重发信任根）。" >&2
  echo "确认要轮换：FORCE=1 $0 ${OUT_DIR}" >&2
  exit 1
fi

echo "==> [1/4] 生成 CA 私钥 + 自签信任根（control-center.pem）"
openssl genrsa -out "${OUT_DIR}/control-center-ca.key" 4096
openssl req -x509 -new -key "${OUT_DIR}/control-center-ca.key" \
  -sha256 -days "${DAYS}" \
  -subj "/CN=${CA_CN}" \
  -out "${OUT_DIR}/control-center.pem"

echo "==> [2/4] 生成控制中心服务器私钥 + CSR"
openssl genrsa -out "${OUT_DIR}/control-center-server.key" 4096
openssl req -new -key "${OUT_DIR}/control-center-server.key" \
  -subj "/CN=${SERVER_CN}" \
  -out "${OUT_DIR}/control-center-server.csr"

# 组装 SAN 列表：DNS:主机名 + 附加（形如 1.2.3.4 → IP:，其余 → DNS:）
san_list="DNS:${SERVER_CN}"
# 必须判空再进循环：bash 3.2（macOS 自带）在 set -u 下，空串经 `read -a` 后数组是
# "未赋值"而非"空数组"，直接展开 "${extra[@]}" 会报 unbound variable。
if [[ -n "${EXTRA_SANS}" ]]; then
  IFS=',' read -r -a extra <<< "${EXTRA_SANS}"
  for entry in "${extra[@]}"; do
    entry="$(echo "${entry}" | xargs)"   # 去空白
    [ -z "${entry}" ] && continue
    if echo "${entry}" | grep -Eq '^[0-9]+(\.[0-9]+){0,3}$'; then
      san_list="${san_list},IP:${entry}"
    else
      san_list="${san_list},DNS:${entry}"
    fi
  done
fi

# 用 SAN 配置签证书（现代 TLS 客户端只认 SAN，不认 CN）
cat > "${OUT_DIR}/control-center-server.ext" <<EOF
subjectAltName = ${san_list}
EOF

echo "==> [3/4] 用 CA 签发中心服务器证书（SAN: ${san_list}）"
openssl x509 -req -in "${OUT_DIR}/control-center-server.csr" \
  -CA "${OUT_DIR}/control-center.pem" \
  -CAkey "${OUT_DIR}/control-center-ca.key" \
  -CAcreateserial -days "${DAYS}" -sha256 \
  -extfile "${OUT_DIR}/control-center-server.ext" \
  -out "${OUT_DIR}/control-center-server.crt"

rm -f "${OUT_DIR}/control-center-server.csr" "${OUT_DIR}/control-center-server.ext"

echo
echo "生成完成："
echo "  信任根（分发给所有 Gateway，作为 control_center.trust_bundle）:"
echo "    ${DISPLAY_DIR}/control-center.pem"
echo "  控制中心 TLS 服务器证书（SAN: ${san_list}）:"
echo "    ${DISPLAY_DIR}/control-center-server.crt"
echo "  控制中心服务器私钥（机密，只留在中心，勿分发）:"
echo "    ${DISPLAY_DIR}/control-center-server.key"
echo
echo "部署提示："
echo "  - init_url / config.toml 的 control_center.endpoint 使用配置的主机名或 IP，"
echo "    且必须落在服务器证书 SAN 内（本脚本默认覆盖主机名；附加 IP/域名用第 3 个参数）"
echo "  - control-center.pem 由部署时预置到各 Gateway（config.toml trust_bundle 路径）"
echo "  - 服务器证书+私钥配置到控制中心 HTTPS 服务"
echo "  - 如需 mTLS，可用本 CA 为每个 Gateway 签发客户端证书"

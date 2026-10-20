#!/usr/bin/env bash
# 为 WarpStation 设备绑定 Center wparse-proxy token（幂等；默认不轮换）。
#
# 为什么需要它：proxy token 的明文只在 Center 签发接口的响应里出现一次；
# WarpStation 上游没有“生成 token”的能力，只能由部署方把 token 写进设备记录。
# 本脚本把「签发 + 写设备」合成一步，避免人工复制粘贴；默认只在设备缺失/不可用时签发，
# `--rotate` 才强制轮换。
#
# 用法：
#   scripts/provision-station-device.sh            # 幂等：设备在线就不动
#   scripts/provision-station-device.sh --rotate   # 强制签发新 token 并更新设备
#
# 可覆盖环境变量：
#   CENTER_ADMIN_TOKEN  Center 管理面 token（缺省读 .wist/sec-value.yml 的 center_admin_token）
#   GATEWAY_ID          Center 的网关 id（默认 X4）
#   DEVICE_NAME         WarpStation 设备名（默认 gw-X4）
#   DEVICE_IP           设备地址（默认 API_WGC_DOMAIN：wparse-proxy 在 center 容器上的网络别名）
#   DEVICE_PORT         设备端口（默认 .env 的 WPARSE_PROXY_HOST_PORT）
#   STATION_API         Station API（默认 http://127.0.0.1:${STATION_HOST_PORT}）
#   CENTER_API          Center 主 API（默认 https://127.0.0.1:${CENTER_HOST_PORT}）
#   SYSTEM_NAME         系统名（默认 wparse）
#
# 安全：脚本不打印 token；token 只在内存/请求体里流转。
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${STACK_ROOT}"

ROTATE=0
case "${1:-}" in
  --rotate) ROTATE=1 ;;
  "") ;;
  *) echo "未知参数：$1（只支持 --rotate）" >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "缺少 curl" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "缺少 python3" >&2; exit 1; }

[[ -f .env ]] || { echo "找不到 .env：先执行 gops sys localize" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sec.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/sec.sh"

: "${CENTER_HOST_PORT:?}" "${CENTER_ADMIN_HOST_PORT:?}" "${STATION_HOST_PORT:?}" "${WPARSE_PROXY_HOST_PORT:?}"
API_WGC_DOMAIN="${API_WGC_DOMAIN:-127.0.0.1}"

ADMIN_TOKEN="${CENTER_ADMIN_TOKEN:-}"
if [[ -z "${ADMIN_TOKEN}" ]]; then
  ADMIN_TOKEN="$(sec_get "${STACK_ROOT}" center_admin_token)"
fi
[[ -n "${ADMIN_TOKEN}" ]] || {
  echo "缺少 center_admin_token（.wist/sec-value.yml 或 CENTER_ADMIN_TOKEN）" >&2
  exit 1
}

GATEWAY_ID="${GATEWAY_ID:-X4}"
DEVICE_NAME="${DEVICE_NAME:-gw-X4}"
DEVICE_IP="${DEVICE_IP:-${API_WGC_DOMAIN}}"
DEVICE_PORT="${DEVICE_PORT:-${WPARSE_PROXY_HOST_PORT}}"
SYSTEM_NAME="${SYSTEM_NAME:-wparse}"
REMARK="${REMARK:-center wparse-proxy}"
STATION_API="${STATION_API:-http://127.0.0.1:${STATION_HOST_PORT}}"
CENTER_API="${CENTER_API:-https://127.0.0.1:${CENTER_ADMIN_HOST_PORT}}"
CA="${STACK_ROOT}/identity/center/control-center.pem"

[[ -f "${CA}" ]] || { echo "找不到 Center CA：${CA}" >&2; exit 1; }

json_field() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("" if v is None else v)' "$1"
}

is_online() {
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("is_online") else 1)'
}

find_device() {
  curl -fsS "${STATION_API}/api/devices?system=${SYSTEM_NAME}" \
    | python3 -c '
import json,sys
name=sys.argv[1]
for d in json.load(sys.stdin).get("items", []):
    if d.get("name")==name:
        print(json.dumps(d))
        break
' "${DEVICE_NAME}"
}

issue_token() {
  curl -fsS --cacert "${CA}" -X POST \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${CENTER_API}/api/v1/admin/gateways/${GATEWAY_ID}/wparse-proxy-token" \
    | json_field token
}

station_put() { # $1=token $2=id(optional)
  local token="$1" id="${2:-}" body
  body="$(python3 -c '
import json,sys
system,name,ip,port,remark,token,id_ = sys.argv[1:8]
d={"system":system,"name":name,"ip":ip,"port":int(port),"remark":remark,"status":"active","token":token}
if id_:
    d["id"]=int(id_)
print(json.dumps(d))
' "${SYSTEM_NAME}" "${DEVICE_NAME}" "${DEVICE_IP}" "${DEVICE_PORT}" "${REMARK}" "${token}" "${id}")"
  if [[ -n "${id}" ]]; then
    curl -fsS -X PUT -H 'content-type: application/json' -d "${body}" "${STATION_API}/api/devices"
  else
    curl -fsS -X POST -H 'content-type: application/json' -d "${body}" "${STATION_API}/api/devices"
  fi
}

print_result() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
print("device=%s online=%s message=%s" % (sys.argv[1], d.get("is_online"), d.get("message","")))
' "${DEVICE_NAME}"
}

# Station 必须先可达，否则不要把“查不到设备”误判成“设备不存在”。
curl -fsS "${STATION_API}/api/devices?system=${SYSTEM_NAME}" >/dev/null || {
  echo "Station API 不可达：${STATION_API}" >&2
  exit 1
}

existing="$(find_device || true)"
if [[ -n "${existing}" ]]; then
  dev_id="$(printf '%s' "${existing}" | json_field id)"
  dev_token="$(printf '%s' "${existing}" | json_field token)"
  dev_ip="$(printf '%s' "${existing}" | json_field ip)"
  dev_port="$(printf '%s' "${existing}" | json_field port)"
  dev_status="$(printf '%s' "${existing}" | json_field status)"

  if [[ "${ROTATE}" -eq 0 && "${dev_status}" == "active" \
        && "${dev_ip}" == "${DEVICE_IP}" && "${dev_port}" == "${DEVICE_PORT}" ]]; then
    echo "设备 ${DEVICE_NAME} 已存在且在线（${dev_ip}:${dev_port}），不轮换。"
    exit 0
  fi

  if [[ "${ROTATE}" -eq 0 && -n "${dev_token}" ]]; then
    echo "更新设备 ${DEVICE_NAME} 的地址/端口（${DEVICE_IP}:${DEVICE_PORT}），复用现有 token…"
    resp="$(station_put "${dev_token}" "${dev_id}")"
    if printf '%s' "${resp}" | is_online; then
      printf '%s' "${resp}" | print_result
      exit 0
    fi
    echo "现有 token 不可用，改为签发新 token。"
  fi

  echo "为 ${DEVICE_NAME} 签发新 proxy token（gateway_id=${GATEWAY_ID}）…"
  token="$(issue_token)"
  [[ -n "${token}" ]] || {
    echo "签发失败（检查 Center admin token / CENTER_API / CA）" >&2
    exit 1
  }
  station_put "${token}" "${dev_id}" | print_result
else
  echo "设备 ${DEVICE_NAME} 不存在，签发 proxy token 并创建…"
  token="$(issue_token)"
  [[ -n "${token}" ]] || {
    echo "签发失败（检查 Center admin token / CENTER_API / CA）" >&2
    exit 1
  }
  station_put "${token}" | print_result
fi

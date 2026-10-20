#!/usr/bin/env bash
# 生成前端站点模板的渲染值 configs/web/nginx.value.json（localize 里 gx.tpl 的输入），
# 并生成 WarpStation 虚拟主机的 basic auth 密码文件 configs/web/htpasswd。
#
# 用法：
#   scripts/init-web-conf.sh <center_domain> [station_domain] [输出目录]
#     scripts/init-web-conf.sh c-dev01.test.gw.jingang.cloud station.c-dev01.test.gw.jingang.cloud
#
# station_domain 留空时派生 `station.<center_domain>`；也可用环境变量 STATION_DOMAIN 覆盖。
#
# 为什么必须落在脚本里，而不是在 operators.gxl 里 printf 直接写：
#   GXL 字符串字面量**不做转义还原** —— `\"` 会原样留下反斜杠；命令最终由 `/bin/sh -c`
#   执行，而 Debian/Ubuntu 的 /bin/sh 是 dash，printf 不认 `\"` → 非法 JSON → localize 中断。
#
# 密码来源：**只**取栈根 `.wist/sec-value.yml` 的 `station_web_password`（权限 600）；
# 缺失或为空直接报错 —— 脚本不生成、也不写密钥文件。
#
# 幂等：JSON / htpasswd 内容不变就不碰 mtime；密码未变时复用同一 salt 校验，不反复重写。
set -euo pipefail

DOMAIN="${1:-}"
STATION_DOMAIN="${2:-${STATION_DOMAIN:-}}"
OUT_DIR="${3:-configs/web}"
STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUE_JSON="${OUT_DIR}/nginx.value.json"
HTPASSWD="${OUT_DIR}/htpasswd"
SEC_FILE="${STACK_ROOT}/.wist/sec-value.yml"
STATION_WEB_USER="${STATION_WEB_USER:-admin}"

# 密钥读取统一走 gops（路径/权限/格式校验都在那里）；见 scripts/lib/sec.sh。
# shellcheck source=lib/sec.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/sec.sh"

note() { echo "  $*"; }

usage() {
  echo "用法: $0 <center_domain> [station_domain] [输出目录]" >&2
  exit 2
}

[[ -n "${DOMAIN}" ]] || usage
[[ -n "${STATION_DOMAIN}" ]] || STATION_DOMAIN="station.${DOMAIN}"

validate_domain() {
  local value="$1" label="$2"
  case "${value}" in
    *[!A-Za-z0-9.-]* | .* | *.)
      echo "${label}不合法：'${value}'（只允许 [A-Za-z0-9.-]，且不以点开头/结尾）" >&2
      exit 1
      ;;
  esac
}
validate_domain "${DOMAIN}" "域名"
validate_domain "${STATION_DOMAIN}" "Station 域名"

command -v openssl >/dev/null 2>&1 || { echo "缺少 openssl" >&2; exit 1; }

mkdir -p "${OUT_DIR}"

# ── 1) 渲染值（center + station 两个 server_name）──
tmp="$(mktemp "${OUT_DIR}/.nginx.value.XXXXXX")"
printf '{\n  "web_domain": "%s",\n  "station_domain": "%s"\n}\n' "${DOMAIN}" "${STATION_DOMAIN}" >"${tmp}"
chmod 644 "${tmp}"

if [[ -f "${VALUE_JSON}" ]] && cmp -s "${tmp}" "${VALUE_JSON}"; then
  rm -f "${tmp}"
  note "渲染值与当前一致（web_domain=${DOMAIN}, station_domain=${STATION_DOMAIN}），跳过：${VALUE_JSON}"
else
  mv -f "${tmp}" "${VALUE_JSON}"
  note "已写渲染值：${VALUE_JSON}（web_domain=${DOMAIN}, station_domain=${STATION_DOMAIN}）"
fi

# ── 2) basic auth 密码：**只读**密钥文件，不生成、不写 ──
[[ -f "${SEC_FILE}" ]] || {
  echo "错误：缺少密钥文件 ${SEC_FILE}（需要键 station_web_password）" >&2
  exit 1
}
password="$(sec_get_optional "${STACK_ROOT}" station_web_password)"
[[ -n "${password}" ]] || {
  echo "错误：${SEC_FILE} 的 station_web_password 为空或缺失；请在文件里提供（权限 600）" >&2
  exit 1
}

# ── 3) htpasswd（nginx 的 auth_basic_user_file 由 worker 读取，用 644）──
write_htpasswd() {
  local hash
  hash="$(openssl passwd -apr1 "${password}")"
  printf '%s:%s\n' "${STATION_WEB_USER}" "${hash}" >"${HTPASSWD}.tmp"
  chmod 644 "${HTPASSWD}.tmp"
  mv -f "${HTPASSWD}.tmp" "${HTPASSWD}"
}

if [[ -f "${HTPASSWD}" ]] && [[ "$(cut -d: -f1 "${HTPASSWD}" | head -1)" == "${STATION_WEB_USER}" ]]; then
  existing_hash="$(cut -d: -f2- "${HTPASSWD}" | head -1)"
  salt="$(printf '%s' "${existing_hash}" | cut -d'$' -f3)"
  if [[ -n "${salt}" ]] && [[ "$(openssl passwd -apr1 -salt "${salt}" "${password}")" == "${existing_hash}" ]]; then
    note "htpasswd 未变化，跳过：${HTPASSWD}"
    exit 0
  fi
fi
write_htpasswd
note "已写 basic auth 密码文件：${HTPASSWD}（user=${STATION_WEB_USER}）"

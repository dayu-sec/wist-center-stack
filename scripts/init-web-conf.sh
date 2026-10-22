#!/usr/bin/env bash
# 生成前端站点模板的渲染值 configs/web/nginx.value.json（localize 里 gx.tpl 的输入）。
#
# 用法：
#   scripts/init-web-conf.sh <center_domain> [输出目录]
#
# 为什么必须落在脚本里，而不是在 operators.gxl 里 printf 直接写：
#   GXL 字符串字面量**不做转义还原** —— `\"` 会原样留下反斜杠；命令最终由 `/bin/sh -c`
#   执行，而 Debian/Ubuntu 的 /bin/sh 是 dash，printf 不认 `\"` → 非法 JSON → localize 中断。
#
# 幂等：JSON 内容不变就不碰 mtime。
set -euo pipefail

DOMAIN="${1:-}"
OUT_DIR="${2:-configs/web}"
VALUE_JSON="${OUT_DIR}/nginx.value.json"

note() { echo "  $*"; }

usage() {
  echo "用法: $0 <center_domain> [输出目录]" >&2
  exit 2
}

[[ -n "${DOMAIN}" ]] || usage

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

mkdir -p "${OUT_DIR}"

# 渲染值：只含 web 虚拟主机的 server_name。
tmp="$(mktemp "${OUT_DIR}/.nginx.value.XXXXXX")"
printf '{\n  "web_domain": "%s"\n}\n' "${DOMAIN}" >"${tmp}"
chmod 644 "${tmp}"

if [[ -f "${VALUE_JSON}" ]] && cmp -s "${tmp}" "${VALUE_JSON}"; then
  rm -f "${tmp}"
  note "渲染值与当前一致（web_domain=${DOMAIN}），跳过：${VALUE_JSON}"
else
  mv -f "${tmp}" "${VALUE_JSON}"
  note "已写渲染值：${VALUE_JSON}（web_domain=${DOMAIN}）"
fi

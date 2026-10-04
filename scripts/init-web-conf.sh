#!/usr/bin/env bash
# 生成前端站点模板的**渲染值** configs/web/nginx.value.json（localize 里 gx.tpl 的输入）。
#
# 为什么必须落在脚本里，而不是在 operators.gxl 里 printf 直接写：
#   GXL 字符串字面量**不做转义还原** —— `\"` 会原样留下反斜杠（orion_parse::define::take_string
#   用 winnow 的 take_escaped，取的是原始切片）。命令最终由 `/bin/sh -c` 执行，而 Debian/Ubuntu 的
#   /bin/sh 是 **dash**：dash 的 printf 不认 `\"`，把反斜杠一起写进文件 → 非法 JSON → gx.tpl 报
#   `parse json data file`，localize 中断。同一行在 macOS 上（sh = bash）却是对的 —— 典型
#   「本机好好的、上云就炸」。写成脚本文件就没有这一层。
#
# 用法：
#   scripts/init-web-conf.sh <域名> [输出目录]
#     scripts/init-web-conf.sh c-dev01.test.gw.jingang.cloud
#
# 幂等：内容与当前一致就跳过（不碰 mtime）。域名只允许主机名字符 —— 既是校验，也保证它进 JSON
# 不需要任何转义（空白 / 引号 / 反斜杠一律拒掉，而不是写出一个「看着成了」的坏值）。
set -euo pipefail

DOMAIN="${1:-}"
OUT_DIR="${2:-configs/web}"
VALUE_JSON="${OUT_DIR}/nginx.value.json"

note() { echo "  $*"; }

if [[ -z "$DOMAIN" ]]; then
  echo "用法: $0 <域名> [输出目录]" >&2
  exit 2
fi

case "$DOMAIN" in
  *[!A-Za-z0-9.-]* | .* | *.)
    echo "域名不合法：'${DOMAIN}'（只允许 [A-Za-z0-9.-]，且不以点开头/结尾）" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"
tmp="$(mktemp "${OUT_DIR}/.nginx.value.XXXXXX")"
printf '{\n  "web_domain": "%s"\n}\n' "$DOMAIN" >"$tmp"
chmod 644 "$tmp"

if [[ -f "$VALUE_JSON" ]] && cmp -s "$tmp" "$VALUE_JSON"; then
  rm -f "$tmp"
  note "渲染值与当前一致（web_domain=${DOMAIN}），跳过：${VALUE_JSON}"
else
  mv -f "$tmp" "$VALUE_JSON"
  note "已写渲染值：${VALUE_JSON}（web_domain=${DOMAIN}）"
fi

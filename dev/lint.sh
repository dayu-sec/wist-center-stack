#!/usr/bin/env bash
# 脚本静态检查：**CI 与本地跑的是同一条命令**（`.github/workflows/scripts.yml` 直接执行它）。
#
# 两道，缺一不可：
#   1. `-S warning`：错误 + 警告（解析不了的条件、引用了没赋值的变量、单次循环……）——
#      这些会直接让脚本行为错。个别**误报**用行级 `# shellcheck disable=` 说明原因，
#      不做全局屏蔽（SC2154 在别处仍然是真 bug）。
#   2. `-S style --include=SC2006`：**反引号**。单独留一道是因为裸反引号会被当命令替换**执行**，
#      而 SC2006 属于 style 级，`-S warning` 会把它过滤掉。
#
# 与 `wist-gateway-stack/dev/lint.sh` 保持同一条命令：两栈的脚本经常是从一边抄到另一边，
# 检查口径不一致时"这边过了那边挂"就变成噪音。
#
# 只扫本仓自己维护的 shell：`scripts/`（随包发布）、`dev/`。
# 用法：`./dev/lint.sh`（退出码 0 = 干净）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "缺少 shellcheck：macOS 用 \`brew install shellcheck\`，Debian/Ubuntu 用 \`apt-get install -y shellcheck\`" >&2
  exit 1
fi

files=(scripts/*.sh scripts/lib/*.sh dev/*.sh dev/tests/*.sh)

echo "== shellcheck -S warning（错误 / 警告）：${#files[@]} 个脚本"
shellcheck -S warning -f gcc "${files[@]}"

echo "== shellcheck -S style --include=SC2006（反引号必须写成 \$()）"
shellcheck -S style --include=SC2006 -f gcc "${files[@]}"

echo "脚本静态检查通过（shellcheck $(shellcheck --version | awk '/^version:/ {print $2}')）"

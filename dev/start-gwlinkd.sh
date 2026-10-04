#!/usr/bin/env bash
# 在**宿主侧**跑 wist-gwlinkd，把本机网关栈接到正在运行的 wist-center（mTLS）。
#
# 前提：center 已以 WIST_CENTER_TLS=1 起（https + CA-S）。见 ./dev/start-center.sh。
#
# 本脚本做三件事：
#   1. 建一个网关实例（admin API），拿一次性置备引导 Token；
#   2. 写 gwlinkd.toml（endpoint=https、trust_bundle=CA-S、state_dir、gateway_id）；
#   3. 后台跑 gwlinkd：首跑 link-upstream → register（换客户端证书）→ 周期 status。
#
# 用法（两个终端）：
#   WIST_CENTER_TLS=1 ./dev/start-center.sh    # 先起 center
#   WIST_CENTER_TLS=1 ./dev/start-gwlinkd.sh   # 再起 gwlinkd
#
# 停止：./dev/stop-gwlinkd.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! center_tls_enabled; then
  echo "需要 WIST_CENTER_TLS=1（gwlinkd 走 mTLS，trust_bundle 用 CA-S）" >&2
  exit 1
fi
require_cmd curl
require_cmd python3

echo "启动 wist-gwlinkd（宿主侧常驻 → 连 https://${CENTER_ADDR}）"
build_gwlinkd
ensure_gwlinkd_config
start_gwlinkd

sleep 2
if kill -0 "${GWLINKD_PID}" 2>/dev/null; then
  echo "  gwlinkd 在跑。最近日志："
  tail -n 6 "${GWLINKD_LOG}" || true
else
  echo "  gwlinkd 未存活，日志：${GWLINKD_LOG}" >&2
  tail -n 20 "${GWLINKD_LOG}" >&2 || true
  exit 1
fi

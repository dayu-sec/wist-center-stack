#!/usr/bin/env bash
# 栈级配置检查（薄壳）：挑本机 triple 的预编译件；没有就回落到源码现编（开发态）。
#
# 为什么不是一段 shell 判据：判据要真解析 TOML/JSON、比路径、看权限位 —— shell 只能靠
# sed 正则，抓空还不报错（这正是它要防的那类故障）。
#
# 用法：
#   scripts/check-stack.sh [--format text|json] [--result <文件>]
#
# 退出码：0 全好 / 1 有 WARN / 2 有 FAIL。
# 例外：`--gate` 只按「阻断类 FAIL」判定（见 `sys/workflows/operators.gxl` 的 localize 末尾）；
#       由 `gops run diagnose` 调用（设置了 GOPS_DIAGNOSE_RESULT）时始终 0 ——
#       结论写在结果文件的 checks[] 里，不该让流程中断。
#
# **找不到预编译件必须失败**：静默跳过等于检查没做，比不检查更危险。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ── 变量改名守卫 ───────────────────────────────────────────────────────
# `CENTER_BIND_IP` / `CENTER_HOST_PORT` 已改名为 `CENTER_API_BIND_IP` / `CENTER_API_HOST_PORT`
# （center 有两个 listener：网关面 API 与管理面；旧名看不出是哪一面，改名后与 `CENTER_ADMIN_*` 对称）。
#
# 为什么必须在这里拦：gops 对 values 里的**未知键是静默接受的**（旧键照样进 .env、localize 不报错），
# 于是「现场还写着旧键」会静默回落到默认值 —— `BIND_IP` 回落到 0.0.0.0 是安全相关的降级，
# 而 `HOST_PORT` 回落到 3100 会让网关直接连不上中心。所以发现旧键就硬失败（退出码 2 = FAIL），
# localize 末尾的 `--gate` 会因此阻断启动。
for legacy in CENTER_BIND_IP CENTER_HOST_PORT; do
  if [ -n "${!legacy:-}" ]; then
    echo "错误：${legacy} 已改名为 ${legacy/CENTER_/CENTER_API_}" >&2
    echo "  请把 values/<系统名>/sys_value.yml 里的旧键改名，再重跑 gops sys localize。" >&2
    echo "  （gops 不会因为未知键报错；旧键会被静默忽略，绑定回落到默认值）" >&2
    exit 2
  fi
done

case "$(uname -s)-$(uname -m)" in
  Linux-aarch64 | Linux-arm64) triple="aarch64-unknown-linux-musl" ;;
  Linux-x86_64 | Linux-amd64) triple="x86_64-unknown-linux-musl" ;;
  Darwin-arm64) triple="aarch64-apple-darwin" ;;
  *)
    echo "没有 $(uname -s)-$(uname -m) 的 stackcheck 预编译件；已支持：Linux-aarch64 / Linux-x86_64 / Darwin-arm64" >&2
    exit 2
    ;;
esac

BIN="${ROOT}/bin/${triple}/wist-stackcheck"

# 离线站点：`STACKCHECK_OFFLINE=1` 跳过镜像可达（否则每次体检都会报「镜像源不可达」）。
#
# 不用数组（`EXTRA+=(--offline)` + `"${EXTRA[@]}"`）：macOS 自带的 bash 3.2 在 `set -u` 下
# 展开空数组会报 `unbound variable`——而这正是部署机最常见的 shell。
offline=0
[ "${STACKCHECK_OFFLINE:-}" = "1" ] && offline=1

if [ -x "$BIN" ]; then
  # 预编译件可能是别的架构（手工拷错 / 平台包拿错）：先自报版本，
  # 失败就明确说架构问题，而不是让 `exec` 报 126/127 让人去猜。
  if "$BIN" --version >/dev/null 2>&1; then
    if [ "$offline" = 1 ]; then
      exec "$BIN" --root "$ROOT" --offline "$@"
    fi
    exec "$BIN" --root "$ROOT" "$@"
  fi
  echo "预编译件无法执行：${BIN}" >&2
  echo "  （本机 triple=${triple}；多半是包里的二进制属于别的平台）" >&2
  echo "  处置：换对应平台的包，或删掉该文件改走下面的 cargo 回落" >&2
  exit 2
fi

# 开发态回落：仓里带源码就现编现跑（发布包里一定带预编译件，不会走到这里）。
if [ -f "${ROOT}/tools/stackcheck/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
  echo "（bin/${triple}/wist-stackcheck 不存在，回落到 cargo run）" >&2
  if [ "$offline" = 1 ]; then
    exec cargo run --quiet --manifest-path "${ROOT}/tools/stackcheck/Cargo.toml" -- --root "$ROOT" --offline "$@"
  fi
  exec cargo run --quiet --manifest-path "${ROOT}/tools/stackcheck/Cargo.toml" -- --root "$ROOT" "$@"
fi

echo "缺少 stackcheck 预编译件：${BIN}" >&2
echo "包内 bin/ 现有：$(ls "${ROOT}/bin" 2>/dev/null || echo '<空>')" >&2
exit 2

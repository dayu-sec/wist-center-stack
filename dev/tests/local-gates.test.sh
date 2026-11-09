#!/usr/bin/env bash
# 回归测试：栈级本地门禁的**职责边界**与 `--only <前缀>` 过滤。
#
# 背景（2026-11-08，网关栈那边一次升级导致整栈回滚）：
#   0.10.12 的 compose 新增了以 **root** 运行的卷初始化服务（`user: "0:0"`），并且它排在
#   所有业务服务之前。当时（本仓是同一份拷贝）`gate_secrets` 用 `grep 'user:' | head -1`
#   自己推导“容器 gid”，于是把 `0640 / :999` 这个**正确**的密钥状态判成 `secrets.group` FAIL；
#   而这道门禁是在 localize 的 ⓿（`--gate --only prereq`）跑的 —— 那一刻
#   `gops sys perms --apply`（权限状态的唯一生产者）还没执行。
#
# 钉住的行为：
#   1. 门禁**不再自己推导容器身份**：compose 里 root 服务排在前面也不影响结论；
#   2. `secrets.mode` / 属组**不由门禁评判**（归 `gops sec fix` 与 `gops sys perms --apply`）；
#   3. `--only prereq` 只上报 `prereq.*`，`secrets.declared` 这类检查不上报；
#   4. 不带 `--only` 时 `secrets.declared` 仍然 FAIL（过滤不能把检查本身关掉）。
#
#   dev/tests/local-gates.test.sh
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STACK_ROOT="$(cd "$(dirname "${SELF}")/../.." && pwd)"
LIB="${STACK_ROOT}/scripts/lib/local-gates.sh"
[[ -f "${LIB}" ]] || { echo "找不到 ${LIB}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

fail() { echo "FAIL：$*" >&2; exit 1; }

# shellcheck source=../../scripts/lib/local-gates.sh
. "${LIB}"

# $1=目录 $2=declared|undeclared
mk_root() {
  local d="$1" shape="${2:-declared}"
  mkdir -p "$d/sys" "$d/.wist"
  printf 'center_admin_token: "0123456789abcdef"\n' >"$d/.wist/sec-value.yml"
  chmod 640 "$d/.wist/sec-value.yml"

  if [ "$shape" = declared ]; then
    cat >"$d/sys-prj.yml" <<'YAML'
secrets:
  file: .wist/sec-value.yml
  format: yaml
  mode: "0640"
YAML
  else
    cat >"$d/sys-prj.yml" <<'YAML'
test_envs:
  dep_root: ''
  deps: []
YAML
  fi

  # 复刻事故现场：root 一次性初始化服务**排在前面**，业务服务仍以 999:999 挂 .wist。
  cat >"$d/sys/docker-compose.yml" <<'YAML'
services:
  db-volume-init:
    image: postgres:test
    user: "0:0"
    volumes:
      - ./data/db:/var/lib/postgresql/data
  center:
    image: wist-center:test
    user: "999:999"
    volumes:
      - ./.wist:/secrets:ro
YAML
}

# 在当前 shell 里跑（GATE_FAIL 是全局量，不能用命令替换吞掉）
run_gates() { # $1=root $2=only
  GATE_FAIL=0
  GATE_OUT=""
  run_local_gates "$1" "${2:-}" >"${TMP}/gate.out" 2>&1 || true
  GATE_OUT="$(cat "${TMP}/gate.out")"
}

# 1) 声明齐全、compose 里 root 服务在前：不应有任何阻断类 FAIL
root="${TMP}/ok"
mk_root "${root}" declared
run_gates "${root}" ""
[ "${GATE_FAIL}" -eq 0 ] || fail "root 初始化服务不该让密钥门禁失败：${GATE_OUT}"
grep -q 'secrets\.group' <<<"${GATE_OUT}" && fail "门禁仍在判属组：${GATE_OUT}"

# 2) 模式与声明不一致（0640 声明 / 0600 现状）：也不由门禁判（gops sec fix 负责）
chmod 600 "${root}/.wist/sec-value.yml"
run_gates "${root}" ""
[ "${GATE_FAIL}" -eq 0 ] || fail "mode 不该由本地门禁评判：${GATE_OUT}"

# 3) 未声明 secrets: → `--only prereq` 不上报（⓿ 那一刻只管“这台机器能不能跑 localize”）
root="${TMP}/undeclared"
mk_root "${root}" undeclared
run_gates "${root}" "prereq"
[ "${GATE_FAIL}" -eq 0 ] || fail "--only prereq 不该上报 secrets.*：${GATE_OUT}"
grep -q 'secrets\.declared' <<<"${GATE_OUT}" && fail "--only prereq 仍然上报了 secrets.declared：${GATE_OUT}"

# 4) 同一现场，不带 `--only`（localize 第 ⑦ 步）→ 仍要 FAIL 并说清怎么补
run_gates "${root}" ""
[ "${GATE_FAIL}" -eq 1 ] || fail "未声明 secrets 时全量门禁必须 FAIL：${GATE_OUT}"
grep -q 'secrets\.declared' <<<"${GATE_OUT}" || fail "没有报出 secrets.declared：${GATE_OUT}"

echo "PASS：本地门禁职责边界 + --only 过滤"

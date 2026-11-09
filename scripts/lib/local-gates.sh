#!/usr/bin/env bash
# 栈级**本地门禁**：由 `scripts/check-stack.sh --gate` 在 stackcheck（Rust）之后追加执行。
#
# 为什么这些判据放在 shell、而不放进 `wist-stackcheck-core`：
#   它们读的是**部署事实** —— 容器的启动时间、端口归属（docker）、密钥文件的属组、
#   交付态文件 `ops-prj.yml` 的形状 —— 不是"配置语法"。放进 core 意味着每调一次判据
#   就要发一次 crates.io 版本、两个栈各升一次锁、再各发一次栈版本
#   （2026-11-05 为一个端口解析修复横跨 3 个仓，就是这个代价）。
#
# 约定：
#   · FAIL  → 阻断 `--gate`（localize 末尾会失败，`gops prj upgrade` 回滚）；
#   · WARN  → 只打印（不影响退出码）；
#   · NOTE/INFO → 事实展示。
#   · 只读、幂等：不写盘、不重启、不 chmod。
#
# 调用方约定（在 check-stack.sh 里设置）：
#   GATE_RENDER_FILES  渲染产物清单（相对栈根），用于 `render.applied`
#   GATE_EXTRA_GATES   可选的额外函数名，跑完通用门禁后调用（如 `gate_ops_prj_addr`）
#   `run_local_gates <root> <only>`：`<only>` 只让该**前缀**的门禁生效（对应 `check-stack.sh
#   --only <前缀>`）。`flow localize` 在⓿ 用 `--gate --only prereq`：那一刻包刚换完、还没重渲，
#   也还没跑 `gops sys perms --apply`——任何读部署事实的门禁都会误报。
#
# 职责边界：**容器身份（gid）只能由 gops 推导**。`gops sys perms` 按服务从
#   `docker compose config` 派生，会跳过以 root 运行的服务；这里再写一份
#   （典型写法：`grep 'user:' | head -1`）必然会在 compose 新增 root 初始化服务时分叉。
#   所以本文件只留“gops 推不出来的事实”（渲染时间 / 端口归属 / ops-prj 地址形态），
#   以及**配置形状**（`secrets.declared`）——后者的诊断价值不在权限，而在
#   `gops sec` 会静默回退到 `.galaxy` 报“未加载到任何密钥”。

# 这两个标志由 check-stack.sh source 之后读取（本文件只写不读）
# shellcheck disable=SC2034
GATE_FAIL=0
# shellcheck disable=SC2034
GATE_WARN=0

gate_fail() {
  gate_selected "$1" || return 0
  printf '\033[31m[FAIL]\033[0m %-18s %s\n        → %s\n' "$1" "$2" "$3"
  GATE_FAIL=1
}
gate_warn() {
  gate_selected "$1" || return 0
  printf '\033[33m[WARN]\033[0m %-18s %s\n        → %s\n' "$1" "$2" "$3"
  GATE_WARN=1
}
gate_info() { printf '  [INFO] %s\n' "$*"; }

# `--only <前缀>` 的过滤：只影响**上报**（门禁本身只读，算一遍不花钱）。
# 前缀按 `.` 边界匹配：`--only prereq` 不会放行 `prereq_xxx`。
gate_selected() {
  [ -z "${GATE_ONLY:-}" ] && return 0
  [ "$1" = "${GATE_ONLY}" ] && return 0
  case "$1" in "${GATE_ONLY}".*) return 0 ;; esac
  return 1
}

# 文件 mtime（epoch 秒）
gate_stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }

# RFC3339(Nano) → epoch 秒；解析不了就输出空（调用方据此跳过，不误报）
gate_iso_epoch() {
  local trimmed
  trimmed=$(printf '%s' "$1" | cut -c1-19)
  [ -n "$trimmed" ] || return 0
  date -u -d "${trimmed}Z" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$trimmed" +%s 2>/dev/null \
    || true
}

# 与 stackcheck 同口径：COMPOSE_PROJECT_NAME → compose 顶层 name: → 栈目录名
gate_project_name() {
  local compose="$1" root="$2" name=""
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    printf '%s' "$COMPOSE_PROJECT_NAME"
    return 0
  fi
  name=$(grep -m1 -E '^name:' "$compose" 2>/dev/null \
    | sed -E 's/^name:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')
  [ -n "$name" ] || name=$(basename "$root")
  printf '%s' "$name"
}

# ① 密钥文件 ↔ sys-prj.yml 声明（这就是 2026-11-05「gops sec 找不到密钥」的结构性根因：
#    横切配置和功能挤在一个提交里，revert 把它带走了，而没有任何检查发现）
#
#    **只查“声明形状”，不查 mode / 属组**：那是 `gops sec fix`（secrets.mode）和
#    `gops sys perms --apply`（容器 gid）的职责，二者都以 compose 为唯一来源。
#    2026-11-08 网关栈升级回滚就是个教训：那份门禁用 `grep 'user:' | head -1` 自己推导
#    容器 gid，而 compose 把 `user: "0:0"` 的卷初始化服务排在了业务服务前面——推导出 0，
#    于是 0640/:999 的正确状态被判成不一致。**同一事实的第二个实现就是 bug。**
gate_secrets() {
  local root="$1"
  local prj="$root/sys-prj.yml" sec="$root/.wist/sec-value.yml"
  [ -f "$sec" ] || return 0
  if ! grep -qE '^secrets:' "$prj" 2>/dev/null; then
    gate_fail "secrets.declared" \
      "有 .wist/sec-value.yml，但 sys-prj.yml 没声明 secrets:" \
      "补 secrets: {file: .wist/sec-value.yml, mode: \"0640\"}；否则 gops sec list/get 会回退旧路径（.galaxy/sec_value.yml）报「未加载到任何密钥」"
  fi
}

# ② 渲染产物比容器启动时间新 ⇒ 配置改了但进程没重载（nginx/tomcat 只认启动时的配置）
gate_render_applied() {
  local root="$1"; shift
  command -v docker >/dev/null 2>&1 || return 0
  local compose="$root/sys/docker-compose.yml"
  [ -f "$compose" ] || return 0
  [ "$#" -gt 0 ] || return 0

  local proj started="" c t
  proj=$(gate_project_name "$compose" "$root")
  for c in $(docker ps --filter "label=com.docker.compose.project=$proj" -q 2>/dev/null); do
    t=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null) || continue
    t=$(gate_iso_epoch "$t")
    [ -n "$t" ] || continue
    if [ -z "$started" ] || [ "$t" -lt "$started" ]; then started=$t; fi
  done
  [ -n "$started" ] || return 0

  local f m
  for f in "$@"; do
    [ -f "$root/$f" ] || continue
    m=$(gate_stat_mtime "$root/$f")
    [ -n "$m" ] || continue
    if [ "$m" -gt "$started" ]; then
      gate_warn "render.applied" \
        "${f} 比容器启动时间新 —— 配置已渲染但这几个进程没重载" \
        "gops run start（或 docker compose restart 对应服务）"
    fi
  done
}

# ③ 端口归属：**只在 stackcheck 真的报了 port.available 失败时**才展开
#    （否则在开发机上会刷出一堆无关容器的端口，把真正的问题埋掉）
gate_port_owners() {
  local root="$1"
  command -v docker >/dev/null 2>&1 || return 0
  local compose="$root/sys/docker-compose.yml" proj
  [ -f "$compose" ] || return 0
  if [ -n "${GATE_STACKCHECK_OUT:-}" ] && [ -f "$GATE_STACKCHECK_OUT" ]; then
    grep -qE '^\[FAIL\][[:space:]]*port\.available' "$GATE_STACKCHECK_OUT" 2>/dev/null || return 0
  else
    return 0
  fi
  proj=$(gate_project_name "$compose" "$root")
  printf '  [INFO] 占用者（非本栈容器）：\n'
  docker ps --format '{{.Label "com.docker.compose.project"}}|{{.Names}}|{{.Ports}}' 2>/dev/null \
    | awk -F'|' -v ours="$proj" '$1 != ours && $3 ~ /->/ { print "         " $2 "：" $3 }'
  return 0
}

# 汇总：调用方按 GATE_FAIL/GATE_WARN 决定退出码
run_local_gates() {
  local root="$1"
  # 第二个参数是 `--only <前缀>` 的产物：只影响上报，不影响判据计算。
  GATE_ONLY="${2:-}"
  gate_secrets "$root"
  # shellcheck disable=SC2086  # 清单里有空格分隔的多个路径，故意的
  gate_render_applied "$root" ${GATE_RENDER_FILES:-}
  gate_port_owners "$root"
  if [ -n "${GATE_EXTRA_GATES:-}" ]; then
    local fn
    for fn in $GATE_EXTRA_GATES; do "$fn" "$root"; done
  fi
}

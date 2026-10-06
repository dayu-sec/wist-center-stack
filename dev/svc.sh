#!/usr/bin/env bash
# 开发态统一入口：把本地「起 / 停 / 看」收在一处（对齐 wist-gateway-stack 的 dev/svc.sh）。
#
# 组件（不给 = 默认全部：deps center web；也可写 all）：
#   deps    PostgreSQL + VictoriaMetrics（docker，用发布态同一份 compose，只起这两个）
#   center  中心后端（默认 https://127.0.0.1:3100；TLS 默认开，WIST_CENTER_TLS=0 关）
#   web     管理前端（vite dev，/api 反代到中心）
#
# 用法：
#   ./dev/svc.sh start [组件…] [--no-build]   默认全部
#   ./dev/svc.sh stop  [组件…]                默认全部（逆序停）
#   ./dev/svc.sh status
#   ./dev/svc.sh token                        打印中心 admin token 与出处
#
# 例：
#   ./dev/svc.sh start                 # 全起（deps + center + web）
#   ./dev/svc.sh start center web      # 只起中心 + 前端
#   ./dev/svc.sh start deps            # 只起依赖（PG/VM）
#   ./dev/svc.sh start center --no-build
#   ./dev/svc.sh stop                  # 停全部
#
# 同一口径：start 后台常驻（不随本脚本退出/关终端而停）；已在跑则复用；停用 stop。
# 可覆盖 env：见 lib.sh 头部（WIST_CENTER_TLS / WIST_CENTER_CONFIG / WARP_INSIGHT_CENTER_* …）。
# 注：gwlinkd（网关宿主侧常驻，随网关走）在 gateway-stack/dev —— `./dev/link_local_center.sh`。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "错误：$*" >&2
  exit 1
}

# ── 各组件：起 ──────────────────────────────────────────────────────────────
start_deps() {
  require_cmd docker
  (
    cd "${STACK_ROOT}"
    if [[ ! -f .env ]]; then
      echo "栈根没有 .env（gops 渲染的变量文件），先跑一次 gops sys localize …"
      gops sys localize
    fi
    # 与 gops run 同一调用口径（-f + --project-directory，否则相对挂载/.env 会错位）。
    docker compose -f sys/docker-compose.yml --project-directory . up -d postgres victoria-metrics
    # 等就绪：up -d 不等 healthcheck，紧接着起 center 时 resolve_dependencies 会探空。
    local i
    for i in {1..40}; do
      port_open "${PG_PORT}" && port_open "${VM_PORT}" && break
      sleep 0.5
    done
    # schema **幂等套一遍**：文件全是 CREATE/ALTER … IF NOT EXISTS。
    # 为什么要每次跑：docker-entrypoint-initdb.d **只在空 data 卷首次初始化时**执行，
    # 之后 `01_schema.sql` 的改动（新增列）根本到不了已有库 —— 中心会因写不出的列报 SQL 错。
    # 失败即报错（ON_ERROR_STOP），别让中心带着旧表结构起来。
    echo "应用数据库 schema（幂等）：sys/db/initdb/01_schema.sql"
    docker compose -f sys/docker-compose.yml --project-directory . exec -T postgres \
      sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q' \
      <sys/db/initdb/01_schema.sql
    echo
    docker compose -f sys/docker-compose.yml --project-directory . ps postgres victoria-metrics
  )
}

up_center() {
  if center_ready; then
    echo "wist-center 已在运行（${CENTER_ADDR}），复用。"
    # 修正 pidfile（可能被上次失败的启动覆盖）；取不到就保持原样。
    local holder
    holder="$(lsof -ti "tcp:${CENTER_PORT}" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    [[ -n "${holder}" ]] && write_pidfile "${CENTER_PID_FILE}" "${holder}"
    return 0
  fi
  resolve_dependencies
  if [[ "${NO_BUILD}" != "1" ]]; then build_center; fi
  ensure_center_config
  start_center
}

up_web() {
  start_web
}

# ── 各组件：停 ──────────────────────────────────────────────────────────────
stop_deps() {
  require_cmd docker
  (
    cd "${STACK_ROOT}"
    # 只 stop 不 down —— 数据卷保留，下次 start 直接复用。
    docker compose -f sys/docker-compose.yml --project-directory . stop postgres victoria-metrics
  )
}

down_center() {
  require_cmd lsof
  stop_service "wist-center" "${CENTER_PID_FILE}" "${CENTER_PORT}" "wist-center"
}

down_web() {
  require_cmd lsof
  require_cmd python3
  stop_service "wist-center-web" "${WEB_PID_FILE}" "$(web_port)" "npm"
}

# ── status / token ──────────────────────────────────────────────────────────
cmd_status() {
  echo "开发态组件状态："
  local pg vm scheme
  port_open "${PG_PORT}" && pg=up || pg=down
  port_open "${VM_PORT}" && vm=up || vm=down
  printf '  %-8s postgres=%s (:%s) victoria-metrics=%s (:%s)\n' "deps" "${pg}" "${PG_PORT}" "${vm}" "${VM_PORT}"

  if center_tls_enabled; then scheme="https"; else scheme="http"; fi
  if port_open "${CENTER_PORT}"; then
    printf '  %-8s up   %s://%s\n' "center" "${scheme}" "${CENTER_ADDR}"
  else
    printf '  %-8s down\n' "center"
  fi
  if [[ "$(web_status)" == "200" ]]; then
    printf '  %-8s up   %s\n' "web" "${WEB_URL}"
  else
    printf '  %-8s down\n' "web"
  fi
}

cmd_token() {
  require_cmd python3
  local token scheme
  token="$(center_admin_token)"
  [[ -n "${token}" ]] || die "读不到 admin token（${CENTER_CONFIG}）"
  if center_tls_enabled; then scheme="https"; else scheme="http"; fi
  cat <<EOF
中心 admin Bearer token（登录「${WEB_URL}」/ 打中心管理 API 都用它）：

  ${token}

  读取自：${CENTER_CONFIG}
  中心：  ${scheme}://${CENTER_ADDR}
  页面：  ${WEB_URL}
EOF
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
[[ -n "${cmd}" ]] || { usage >&2; exit 2; }

NO_BUILD=0
requested=()
for arg in "$@"; do
  case "${arg}" in
    --no-build) NO_BUILD=1 ;;
    deps | center | web | all) requested+=("${arg}") ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "未知参数：${arg}" ;;
  esac
done

# 组件按固定顺序收集（起点序）；不给 = 默认全部（start / stop 都如此）。
COMPONENTS=(deps center web)
selected=()
if [[ ${#requested[@]} -eq 0 ]]; then
  selected=("${COMPONENTS[@]}")
else
  for c in "${COMPONENTS[@]}"; do
    for r in "${requested[@]}"; do
      if [[ "${r}" == "${c}" || "${r}" == "all" ]]; then
        selected+=("${c}")
        break
      fi
    done
  done
fi

case "${cmd}" in
  start)
    require_cmd python3
    require_cmd curl
    echo "启动开发态组件：${selected[*]}"
    [[ "${NO_BUILD}" == "1" ]] && echo "  （--no-build：跳过 cargo build）"
    echo
    failed=()
    for c in "${selected[@]}"; do
      # 子 shell：组件里的 die/exit 只结束子 shell，不掀翻整次 start。
      if ( case "${c}" in
             deps) start_deps ;;
             center) up_center ;;
             web) up_web ;;
           esac ); then
        :
      else
        failed+=("${c}")
        echo "  [warn] ${c} 未成功，继续。" >&2
      fi
      echo
    done
    print_access_info "${selected[@]}"
    [[ ${#failed[@]} -eq 0 ]] || { echo "未就绪：${failed[*]}" >&2; exit 1; }
    ;;
  stop)
    echo "停止开发态组件（逆序）：$(
      printf '%s ' "${selected[@]}" | awk '{for (i=NF; i>0; i--) printf "%s%s", $i, (i>1?" ":"\n")}'
    )"
    echo
    for ((i = ${#selected[@]} - 1; i >= 0; i--)); do
      case "${selected[$i]}" in
        deps) stop_deps ;;
        center) down_center ;;
        web) down_web ;;
      esac
      echo
    done
    ;;
  status)
    cmd_status
    ;;
  token)
    cmd_token
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令：${cmd}（可用：start | stop | status | token）"
    ;;
esac

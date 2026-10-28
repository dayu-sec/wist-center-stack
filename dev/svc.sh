#!/usr/bin/env bash
# 开发态统一入口：把本地「起 / 停 / 看」收在一处（对齐 wist-gateway-stack 的 dev/svc.sh）。
#
# 组件（不给 = 默认全部：deps proxy center web；也可写 all）：
#   deps    PostgreSQL + VictoriaMetrics（docker，用发布态同一份 compose，只起这两个）
#   proxy   Git Proxy（docker nginx，:18082）—— 发布 wparse-rules / wparse-infra 必需：
#           dev 的中心只负责读 tag，网关的 wparse 仍然要从这里拉 wp-rules / wp-infra
#   center  中心后端（默认 https://center.dev.wist.lab:3100，监听 0.0.0.0:3100；TLS 默认开，WIST_CENTER_TLS=0 关）
#   web     管理前端（vite dev，/api 反代到中心）
#
# 用法：
#   ./dev/svc.sh start   [组件…] [--no-build] [--dry-run]   默认全部
#   ./dev/svc.sh stop    [组件…]                            默认全部（逆序停）
#   ./dev/svc.sh restart [组件…] [--no-build] [--dry-run]   停所选（逆序）再起回（正序）
#   ./dev/svc.sh status
#   ./dev/svc.sh token                        打印中心 admin token 与出处
#
# 例：
#   ./dev/svc.sh start                 # 全起（deps + proxy + center + web）
#   ./dev/svc.sh start center web      # 只起中心 + 前端
#   ./dev/svc.sh start deps            # 只起依赖（PG/VM）
#   ./dev/svc.sh start proxy           # 只起 Git Proxy（没有它规则发布必报 fetch remote tags failed）
#   ./dev/svc.sh start center --no-build
#   ./dev/svc.sh restart center        # 改了中心配置/代码后重启中心
#   ./dev/svc.sh stop                  # 停全部
#
# 同一口径：start 后台常驻（不随本脚本退出/关终端而停）；已在跑则复用；停用 stop；重启用 restart（= 停 + 起）。
# 可覆盖 env：见 lib.sh 头部（WIST_CENTER_TLS / WIST_CENTER_CONFIG / WARP_INSIGHT_CENTER_* …）。
# 注：deps / proxy 刻意**复用发布态的 docker 容器**（两栈目录同名 → 同一个 compose 项目
#     `wist-center-stack`），不为 dev 另开一套实例：所以两边共用 postgres / victoria-metrics /
#     git-proxy 的容器与数据卷（省资源，但**清库即两边都清**）。
# 注：gwlinkd（网关宿主侧常驻，随网关走）在 gateway-stack/dev —— 由那边的 `./dev/svc.sh start` 带起。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  # 打印文件头的**注释块**（第 2 行起，到首个非注释行为止）：加/删注释行都不用改行号。
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
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

start_proxy() {
  require_cmd docker
  (
    cd "${STACK_ROOT}"
    if [[ ! -f .env ]]; then
      echo "栈根没有 .env（gops 渲染的变量文件），先跑一次 gops sys localize …"
      gops sys localize
    fi
    # Git Proxy 只吃两份**发布态渲染物**：nginx.conf（放行哪两个仓库 + 注入读 token）
    # 与站点证书。缺就报错，别在 dev 里另造一套 —— 否则放行路径/token/域名会与网关侧漂移。
    local missing=0 f
    for f in \
      "${STACK_ROOT}/configs/git-proxy/nginx.conf" \
      "${STACK_ROOT}/identity/center/control-center-server.crt" \
      "${STACK_ROOT}/identity/center/control-center-server.key" \
      "${STACK_ROOT}/identity/center/gateway-client-ca.pem"; do
      [[ -f "${f}" ]] || {
        echo "缺少 ${f}" >&2
        missing=1
      }
    done
    [[ "${missing}" == "1" ]] &&
      die "Git Proxy 需要发布态渲染物（nginx.conf + 站点证书）：发布态先 gops sys localize，证书缺失再跑 scripts/gen-center-ca.sh"

    # 与 gops run 同一调用口径（-f + --project-directory）。
    docker compose -f sys/docker-compose.yml --project-directory . up -d git-proxy
    local i
    for i in {1..40}; do
      port_open "${GIT_PROXY_PORT}" && break
      sleep 0.5
    done
    docker compose -f sys/docker-compose.yml --project-directory . ps git-proxy
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

stop_proxy() {
  require_cmd docker
  (
    cd "${STACK_ROOT}"
    # 只 stop 不 down：容器与渲染物都留着，下次 start 直接复用。
    docker compose -f sys/docker-compose.yml --project-directory . stop git-proxy
  )
}

down_center() {
  require_cmd lsof
  stop_service "wist-center" "${CENTER_PID_FILE}" "${CENTER_PORT}" "wist-center"
}

down_web() {
  require_cmd lsof
  require_cmd python3
  stop_service "wist-center-web" "${WEB_PID_FILE}" "$(web_port)" "npm" "npm|node|vite|esbuild"
}

# ── status / token ──────────────────────────────────────────────────────────
cmd_status() {
  echo "开发态组件状态："
  local pg vm gp scheme
  port_open "${PG_PORT}" && pg=up || pg=down
  port_open "${VM_PORT}" && vm=up || vm=down
  port_open "${GIT_PROXY_PORT}" && gp=up || gp=down
  printf '  %-8s postgres=%s (:%s) victoria-metrics=%s (:%s)\n' "deps" "${pg}" "${PG_PORT}" "${vm}" "${VM_PORT}"
  printf '  %-8s git-proxy=%s (:%s)\n' "proxy" "${gp}" "${GIT_PROXY_PORT}"

  if center_tls_enabled; then scheme="https"; else scheme="http"; fi
  if port_open "${CENTER_PORT}"; then
    printf '  %-8s up   %s://%s\n' "center" "${scheme}" "${CENTER_PUBLIC_HOST}"
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
  [[ -n "${token}" ]] || die "读不到 admin token（${CENTER_SEC_FILE}；还没起过中心？先 ./dev/svc.sh start）"
  if center_tls_enabled; then scheme="https"; else scheme="http"; fi
  cat <<EOF
中心 admin Bearer token（登录「${WEB_URL}」/ 打中心管理 API 都用它）：

  ${token}

  读取自：${CENTER_SEC_FILE}（密钥文件，键 center_admin_token）
           ← 配置里只写 \${SEC_CENTER_ADMIN_TOKEN}
  中心：  ${scheme}://${CENTER_PUBLIC_HOST}
  页面：  ${WEB_URL}
EOF
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
[[ -n "${cmd}" ]] || { usage >&2; exit 2; }

NO_BUILD=0
DRY_RUN=0
requested=()
for arg in "$@"; do
  case "${arg}" in
    --no-build) NO_BUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    deps | proxy | center | web | all) requested+=("${arg}") ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "未知参数：${arg}" ;;
  esac
done

# 组件按固定顺序收集（起点序）；不给 = 默认全部（start / stop 都如此）。
COMPONENTS=(deps proxy center web)
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

# 起所选组件（正序）。start 与 restart 共用。
cmd_start_selected() {
  require_cmd python3
  require_cmd curl
  echo "启动开发态组件：${selected[*]}"
  [[ "${NO_BUILD}" == "1" ]] && echo "  （--no-build：跳过 cargo build）"
  [[ "${DRY_RUN}" == "1" ]] && echo "  [dry-run] 只打印计划，不实际启动"
  echo
  if [[ "${DRY_RUN}" == "1" ]]; then
    for c in "${selected[@]}"; do
      echo "  将要启动：${c}"
    done
    return 0
  fi
  failed=()
  for c in "${selected[@]}"; do
    # 子 shell：组件里的 die/exit 只结束子 shell，不掀翻整次 start。
    if ( case "${c}" in
           deps) start_deps ;;
           proxy) start_proxy ;;
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
}

# 停所选组件（逆序）。stop 与 restart 共用。
cmd_stop_selected() {
  echo "停止开发态组件（逆序）：$(
    printf '%s ' "${selected[@]}" | awk '{for (i=NF; i>0; i--) printf "%s%s", $i, (i>1?" ":"\n")}'
  )"
  echo
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] 只打印计划，不实际停止"
    return 0
  fi
  for ((i = ${#selected[@]} - 1; i >= 0; i--)); do
    case "${selected[$i]}" in
      deps) stop_deps ;;
      proxy) stop_proxy ;;
      center) down_center ;;
      web) down_web ;;
    esac
    echo
  done
}

case "${cmd}" in
  start)
    cmd_start_selected
    ;;
  stop)
    cmd_stop_selected
    ;;
  restart)
    echo "重启开发态组件（停 → 起）：${selected[*]}"
    echo
    cmd_stop_selected
    cmd_start_selected
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
    die "未知子命令：${cmd}（可用：start | stop | restart | status | token）"
    ;;
esac

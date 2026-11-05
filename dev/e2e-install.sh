#!/usr/bin/env bash
# 安装链路的端到端检查。
#
# 为什么需要它：2026-11-05 一天里 6 次"装不上"事故，5 次是**状态不一致**（CA 没进对信任库、
# 模板仓不在代理白名单、ops-prj 的 addr 被写成 /tmp、浏览器缺 admin token），而单测全绿 ——
# 因为单测只断言"脚本字符串里有什么"，不断言"这条链路真的能跑通"。
#
# 这个脚本做两件事，按风险从低到高：
#   --contract（默认）只读：向中心要 prepare / install 脚本，做 `bash -n` + 关键断言，
#     验证栈包地址真的能取到，并验证 Git Proxy 真的能 `ls-remote` 中心下发的模板仓。CI 可用。
#   --run          真装：把 install 命令交给目标机执行（需要 --ssh），
#     装完在目标机上断言（gops sec 非空 / ops-prj 地址可跟版 / gwlinkd 已接入）。
#
# 副作用：默认**零副作用** —— 不给 --gateway 时临时建一台 `e2e-<时间戳>` 网关拿安装材料，
# 结束时归档。只有显式 `--gateway <id>` 才会轮换现场那台的接入券（旧券立即失效）。
#
# 用法：
#   dev/e2e-install.sh --center https://center.example:3100 \
#       --admin https://wgc.example:8443 --token-from-gops /root/wcenter-alpha/wist-center-stack
#   dev/e2e-install.sh ... --gateway dysec-hk            # 用现成网关（会轮换它的接入券）
#   dev/e2e-install.sh ... --ssh root@10.0.0.5 --run      # 真装
#
# 令牌来源：中心栈的密钥文件 —— `gops sec get center_admin_token --show`（在中心机上）。
# 令牌**只放环境变量/参数**，不落盘。
set -euo pipefail

CENTER=""
ADMIN=""
TOKEN=""
TOKEN_STACK=""
GATEWAY=""
SSH_TARGET=""
RUN=0

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺 $1" >&2; exit 1; }; }
log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '   \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '   \033[31m✗\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

# 子串断言。**不要**写 `printf '%s' "$big" | grep -q "$needle"`：
# `grep -q` 命中后立刻退出 → 上游 printf 收到 SIGPIPE(141) → `set -o pipefail` 让整条管道
# 判失败 → `if` 走进 else。表现是"脚本里明明有这行却报缺"，而且**时好时坏**（取决于
# 哪边先退出）—— 2026-11-05 这个 e2e 自己就是这么误报的。`case` 是纯内建，没有管道。
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# 从文本里取第一处 URL。用 herestring（临时文件）而不是管道，同样为了避开 SIGPIPE。
first_url() { grep -m1 -oE "https?://[^'\"[:space:]]+" <<<"$1" || true; }

# 管理面错误体 → "code - message"。python3 读满 stdin 才退出，管道在这里是安全的；
# 仍统一用 herestring，少一处要推理的地方。
json_err() {
  python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("非 JSON 响应")
    raise SystemExit
err = doc.get("error") or {}
print(err.get("code", "?"), "-", err.get("message", ""))
'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --center) CENTER="$2"; shift 2 ;;
    # 管理面地址：面分离部署时是 web 域名（`WEB_WGC_DOMAIN`），不是网关面 `CENTER_API`。
    # `/api/v1/admin/**` 只在管理面 listener（3102，经 web 反代）上。
    --admin) ADMIN="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    # 在**中心机上**跑自查时用：直接从中心栈的密钥文件取 admin token（不把密文传到命令行历史/进程表）。
    --token-from-gops) TOKEN_STACK="$2"; shift 2 ;;
    # 用现成网关（会轮换它的接入券）。不给则在管理面建一台临时 e2e 网关，结束时归档。
    --gateway) GATEWAY="$2"; shift 2 ;;
    --ssh) SSH_TARGET="$2"; shift 2 ;;
    --run) RUN=1; shift ;;
    -h | --help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[ -n "$CENTER" ] || { echo "需要 --center" >&2; exit 2; }
CENTER="${CENTER%/}"
ADMIN="${ADMIN:-$CENTER}"
ADMIN="${ADMIN%/}"
need curl
need python3

if [ -n "$TOKEN_STACK" ]; then
  gops_path="/root/bin:/usr/local/bin:/usr/bin:/bin"
  TOKEN=$(cd "$TOKEN_STACK" && PATH="$gops_path" gops sec get center_admin_token --show 2>/dev/null | tail -1)
  [ -n "$TOKEN" ] || { echo "从 ${TOKEN_STACK} 取不到 center_admin_token（gops sec 不可用？）" >&2; exit 1; }
fi

# ── 0. 拿到"安装材料"：一次性的接入券 + 渲染好的两条命令 ────────────────────
# 临时网关用完即归档：不给现场任何一台动接入券。
EPHEMERAL_ID=""
cleanup() {
  [ -n "$EPHEMERAL_ID" ] || return 0
  [ -n "${TOKEN:-}" ] || return 0
  if curl -skS -o /dev/null -X POST \
    -H "Authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
    -d '{"archived":true}' \
    "${ADMIN}/api/v1/admin/gateways/${EPHEMERAL_ID}/archive" 2>/dev/null; then
    log "已归档临时网关 ${EPHEMERAL_ID}"
  else
    printf '   \033[33m!\033[0m 临时网关 %s 归档失败，请手工归档\n' "$EPHEMERAL_ID"
  fi
}
trap cleanup EXIT

materials=""
if [ -n "$TOKEN" ]; then
  if [ -z "$GATEWAY" ]; then
    # 归档不删行 → id 必须全局唯一：秒级时间戳 + pid + 随机数，并容忍并发撞车重试。
    attempt=0
    while :; do
      EPHEMERAL_ID="e2e-$(date +%Y%m%d%H%M%S)-$$${RANDOM}"
      log "建临时网关 ${EPHEMERAL_ID}（不碰现场接入券，结束时归档）"
      created=$(curl -skS -X POST \
        -H "Authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
        -d "{\"gateway_name\":\"${EPHEMERAL_ID}\",\"requested_by\":\"e2e\"}" \
        "${ADMIN}/api/v1/admin/gateways/instances") || true
      contains "$created" '"error"' || break
      attempt=$((attempt + 1))
      if ! contains "$created" 'gateway_already_exists' || [ "$attempt" -ge 3 ]; then
        bad "建临时网关失败：$(json_err <<<"$created")（--admin 指对了吗？面分离时是 web 域名）"
        EPHEMERAL_ID=""
        exit 1
      fi
    done
    GATEWAY="$EPHEMERAL_ID"
  else
    log "注意：--gateway ${GATEWAY} 会被轮换接入券（旧券立即失效）；只读检查请省略 --gateway"
  fi

  log "取安装材料（gateway_id=${GATEWAY}）"
  materials=$(curl -skS -X POST \
    -H "Authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
    -d '{"requested_by":"e2e"}' \
    "${ADMIN}/api/v1/admin/gateways/${GATEWAY}/link-token") || true
  # 管理面返回错误时也是 200/404 + {"error":{...}}，不能只看"非空"。
  if contains "$materials" '"error"'; then
    bad "管理面拒绝了请求：$(json_err <<<"$materials")（--admin 指对了吗？面分离时是 web 域名）"
    exit 1
  fi
  ok "已拿到 install_all_command"
else
  log "跳过材料获取（没给 --token）：只检查公开端点"
fi

# ── 1. prepare 脚本：语法 + 关键行为 ────────────────────────────────────
log "检查 prepare-script"
prepare=$(curl -skS "${CENTER}/api/v1/gateway/prepare-script")
if bash -n <<<"$prepare" 2>/dev/null; then ok "bash -n"; else bad "prepare 脚本语法错误"; fi
if contains "$prepare" 'WIST_TRUST_CENTER_CA'; then
  ok "中心 CA 会被装进系统信任库（可用 WIST_TRUST_CENTER_CA=0 关）"
else
  bad "prepare 脚本没有安装中心 CA 的逻辑（域名/证书类失败会一路带到安装）"
fi

# ── 2. install 脚本：语法 + 关键断言 ────────────────────────────────────
if [ -n "$materials" ]; then
  cmd=$(python3 -c '
import json, sys

def find(node):
    if isinstance(node, dict):
        if "install_all_command" in node:
            return node["install_all_command"]
        for value in node.values():
            hit = find(value)
            if hit:
                return hit
    elif isinstance(node, list):
        for value in node:
            hit = find(value)
            if hit:
                return hit
    return None

value = find(json.load(sys.stdin))
print(value or "")
' <<<"$materials")
  url=$(first_url "$cmd")
  [ -n "$url" ] || { bad "install 命令里找不到 URL：${cmd}"; exit 1; }
  # 抽错 URL 是这套断言最隐蔽的失效模式（抽到 prepare-script 也能过 bash -n 和前几条断言）。
  if contains "$url" '/api/v1/gateway/install-all?'; then
    ok "install 命令指向 install-all 端点"
  else
    bad "install 命令的 URL 不是 install-all 端点：${url}"
  fi
  log "拉取 install 脚本"
  script=$(curl -skS "$url") || { bad "拉不到 install 脚本（接入券过期/已被用过？）"; exit 1; }
  if bash -n <<<"$script" 2>/dev/null; then ok "bash -n"; else bad "install 脚本语法错误"; fi

  # 包必须**回源**取：本地临时包会污染 ops-prj.yml 的 addr（升级会去死目录找包）
  if contains "$script" "gops prj import --path 'http"; then
    ok "gops 直接回源取栈包"
  else
    bad "gops 没有回源取包（是不是又改回下到本地再 import）"
  fi
  if contains "$script" 'export GIT_SSL_CAINFO'; then
    ok "git clone 有显式 CA（GnuTLS 不认 SSL_CERT_FILE）"
  else
    bad "缺 GIT_SSL_CAINFO：Debian/Ubuntu 的 git 会报 CAfile: none"
  fi
  if contains "$script" 'update-ca-certificates' ||
    contains "$script" 'update-ca-trust' ||
    contains "$script" 'security add-trusted-cert'; then
    ok "宿主系统信任库/钥匙串会被写入"
  else
    bad "没有系统信任库落地（运维手敲的 git/curl/docker 会不信任中心）"
  fi

  # ── 2.1 栈包地址：中心下发的版本真的取得到 ─────────────────────────────
  # 2026-11-05 的"装不上"里有几次是包 404 或版本号对不上；这条断言把它提前到 CI。
  stack_url=$(grep -m1 -oE "gops prj import --path '[^']+'" <<<"$script" || true)
  stack_url="${stack_url#gops prj import --path \'}"
  stack_url="${stack_url%\'}"
  if [ -n "$stack_url" ]; then
    code=$(curl -skS -o /dev/null -w '%{http_code}' -r 0-0 "$stack_url" || echo 000)
    if [ "$code" = 200 ] || [ "$code" = 206 ]; then
      ok "栈包可取：${stack_url##*/}"
    else
      bad "栈包取不到（HTTP ${code}）：${stack_url}（中心没这个版本？发布没推完？）"
    fi
  else
    bad "install 脚本里找不到栈包地址（gops prj import --path '<url>'）"
  fi

  # ── 3. 模板仓：Git Proxy 白名单是否真的覆盖它 ──────────────────────────
  repo=$(grep -m1 -E "^PROJECT_REPO=" <<<"$script" || true)
  repo="${repo#PROJECT_REPO=}"
  repo="${repo//\'/}"
  if [ -n "$repo" ]; then
    log "验证模板仓可达：${repo}"
    # 这里验的是**白名单/路径映射**（不是信任）：用 -c http.sslVerify=false 去掉 TLS 噪声。
    if GIT_TERMINAL_PROMPT=0 git -c http.sslVerify=false ls-remote "$repo" >/dev/null 2>&1; then
      ok "git ls-remote 通过"
    else
      bad "拉不到模板仓（代理白名单没覆盖？见 GIT_PROXY_REPO_PREFIX / WP_TPL_REPO_URL）"
    fi
  else
    bad "install 脚本里找不到 PROJECT_REPO"
  fi
fi

# ── 4. 真装（显式 --run）──────────────────────────────────────────────
if [ "$RUN" = 1 ]; then
  [ -n "$SSH_TARGET" ] || { echo "--run 需要 --ssh <user@host>" >&2; exit 2; }
  [ -n "${cmd:-}" ] || { echo "--run 需要 --token 与 --gateway" >&2; exit 2; }
  log "在 ${SSH_TARGET} 上执行安装（会真的装网关）"
  # shellcheck disable=SC2029  # 命令里含变量，故意在远端展开
  ssh -o BatchMode=yes "$SSH_TARGET" "$cmd"

  log "装完自检（远端）"
  ssh -o BatchMode=yes "$SSH_TARGET" 'bash -s' <<'REMOTE'
set -u
fail=0
stack=$(ls -d /root/*/wist-gateway-stack 2>/dev/null | head -1)
[ -n "$stack" ] && cd "$stack" || { echo "  ✗ 找不到网关栈目录"; exit 1; }

if PATH=/root/bin:/usr/local/bin:/usr/bin:/bin gops sec list >/dev/null 2>&1; then
  echo "  ✓ gops sec 可用（密钥声明 + 权限一致）"
else
  echo "  ✗ gops sec 不可用（sys-prj.yml 的 secrets: / 文件权限）"; fail=1
fi

if grep -qE '^[[:space:]]*path:' ../ops-prj.yml 2>/dev/null; then
  echo "  ✗ ops-prj.yml 的 addr 是本地路径（升级会去死目录）"; fail=1
else
  echo "  ✓ ops-prj.yml 的 addr 可跟版"
fi

if command -v wist-gwlinkd >/dev/null 2>&1 && wist-gwlinkd diagnose >/dev/null 2>&1; then
  echo "  ✓ gwlinkd diagnose 通过"
else
  echo "  ! gwlinkd 还没接入（链接上级未完成）"
fi
exit $fail
REMOTE
fi

log "完成"
[ "$FAILED" = 0 ] || { echo "有失败项（见上面的 ✗）" >&2; exit 1; }
echo "全部检查通过。"

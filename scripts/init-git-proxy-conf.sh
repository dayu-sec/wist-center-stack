#!/usr/bin/env bash
# 生成 Git Proxy 的**渲染值** `configs/git-proxy/git-proxy.value.json`
# （localize 里 `gx.tpl` 渲染 `nginx.conf.tpl` 的输入；两份产物都是 600，含 CNB 读凭据）。
#
# 用法：
#   scripts/init-git-proxy-conf.sh [输出目录]      # 默认 configs/git-proxy
#
# 为什么必须落在脚本里，而不是在 operators.gxl 里 printf：
#   与 init-web-conf.sh 同因 —— GXL 字符串不还原 `\"`，而 Debian/Ubuntu 的 /bin/sh 是 dash，
#   `printf` 会把反斜杠原样写进 JSON → 非法 JSON → localize 在 gx.tpl 处中断。
#
# 环境（gops 把合并后的系统变量以**环境变量**注入 localize 流程）：
#   GIT_PROXY_DOMAIN                Git Proxy 对外域名；**留空 = 沿用 API_WGC_DOMAIN**
#   API_WGC_DOMAIN                  网关面域名（上者的默认值）
#   WP_RULES_REPO_URL               上游规则仓库（与 infra 必须同主机）
#   WP_INFRA_REPO_URL               上游配置仓库
#   WP_GIT_BASE_URL                 上游基址；留空 = 从仓库 URL 推导 `scheme://host[:port]`
#   WP_GIT_AUTH_HEADER              鉴权头名（默认 Authorization；Basic 口径）
#   WP_GIT_PUB_USER                 读账号（可被 .wist 的 wp_git_pub_user 覆盖）
#   GIT_PROXY_SHORT_PREFIX          短路径别名要补上的上游目录前缀：留空 = 自动取两个仓库的
#                                   公共上级目录（`.../dy-sec/jingang-cust/wist/wp-*` →
#                                   `dy-sec/jingang-cust/wist`，于是 Gateway 侧可以只写 `/wp-infra`）；
#                                   `off` = 不生成别名；也可显式写一个前缀（必须同时是两个仓库的前缀）。
#   GIT_PROXY_ALLOW_CIDR            可选来源 IP allowlist（逗号分隔；空 = 不限）
#   GIT_PROXY_CLIENT_CERT_VERIFY   双向证书：off | optional | on（默认 off）
#   密钥 wp_git_pub_token / wp_git_pub_user：来自 `.wist/sec-value.yml`（只读，不生成不补键）
#
# 降级（不阻断 localize，与 init-center.sh「只配一个 repo 就关掉发布」同口径）：
#   · 两个仓库都没配 → 渲染出「白名单永不命中」的 nginx：进程照常起，但拒绝一切 git 请求；
#   · 只配了一个      → 白名单只收它；
#   · 缺读 token      → 上游鉴权头留注释，私有仓库会返回 401。
#
# 幂等：JSON 内容不变就不碰 mtime。
set -euo pipefail

OUT_DIR="${1:-configs/git-proxy}"
VALUE_JSON="${OUT_DIR}/git-proxy.value.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SEC_FILE="${STACK_ROOT}/.wist/sec-value.yml"

# 密钥读取统一走 gops（路径/权限/格式校验都在那里）；见 scripts/lib/sec.sh。
# shellcheck source=lib/sec.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/sec.sh"

note() { echo "  $*"; }
warn() { echo "  ⚠ $*" >&2; }

# ── 入参（环境）──
GIT_PROXY_DOMAIN="${GIT_PROXY_DOMAIN:-}"
API_WGC_DOMAIN="${API_WGC_DOMAIN:-}"
SERVER_NAME="${GIT_PROXY_DOMAIN:-${API_WGC_DOMAIN}}"
WP_GIT_BASE_URL="${WP_GIT_BASE_URL:-}"
WP_GIT_AUTH_HEADER="${WP_GIT_AUTH_HEADER:-Authorization}"
WP_GIT_PUB_USER="${WP_GIT_PUB_USER:-}"
GIT_PROXY_SHORT_PREFIX="${GIT_PROXY_SHORT_PREFIX:-}"
GIT_PROXY_ALLOW_CIDR="${GIT_PROXY_ALLOW_CIDR:-}"
GIT_PROXY_CLIENT_CERT_VERIFY="${GIT_PROXY_CLIENT_CERT_VERIFY:-off}"

if [[ -z "${SERVER_NAME}" ]]; then
  echo "错误：GIT_PROXY_DOMAIN 与 API_WGC_DOMAIN 都为空，无法确定 Git Proxy 的 server_name" >&2
  exit 2
fi

# ── 双 IP 守卫 ──
# 两个 IP 就是既有变量：`CENTER_API_BIND_IP`（主私网 IP）与 `GIT_PROXY_BIND_IP`（第二/辅助私网 IP）。
# 同一 IP:端口只能有一个监听者：两个服务用**相同端口**、且绑定地址重叠（相同，或任一为 0.0.0.0）时，
# `docker compose up` 会在外部连通性阶段报 EADDRINUSE —— 那时看起来像 docker 毛病，离根因很远。
# 这里在 localize 阶段（up 之前）就拦住，并直接给出两种出路。
GIT_PROXY_BIND_IP="${GIT_PROXY_BIND_IP:-0.0.0.0}"
GIT_PROXY_HOST_PORT="${GIT_PROXY_HOST_PORT:-18082}"
CENTER_API_BIND_IP="${CENTER_API_BIND_IP:-0.0.0.0}"
CENTER_API_HOST_PORT="${CENTER_API_HOST_PORT:-3100}"
if [[ "${GIT_PROXY_HOST_PORT}" == "${CENTER_API_HOST_PORT}" ]] && {
  [[ "${GIT_PROXY_BIND_IP}" == "${CENTER_API_BIND_IP}" ]] ||
    [[ "${GIT_PROXY_BIND_IP}" == "0.0.0.0" ]] ||
    [[ "${CENTER_API_BIND_IP}" == "0.0.0.0" ]]
}; then
  cat >&2 <<EOF
错误：Git Proxy 与 Center 的绑定地址冲突（都是 ${GIT_PROXY_HOST_PORT} 端口）。
  GIT_PROXY_BIND_IP=${GIT_PROXY_BIND_IP}  GIT_PROXY_HOST_PORT=${GIT_PROXY_HOST_PORT}
  CENTER_API_BIND_IP=${CENTER_API_BIND_IP}        CENTER_API_HOST_PORT=${CENTER_API_HOST_PORT}
一个 IP 的一个端口只能有一个监听者。二选一：
  · 双 IP（推荐）：给本机加第二个私网 IP，GIT_PROXY_BIND_IP=<第二私网IP>、CENTER_API_BIND_IP=<主私网IP>
    （云上公网 IP 是 NAT：要绑**私网** IP，不能绑 EIP）；或
  · 继续用独立端口：GIT_PROXY_HOST_PORT 保留 18082（网关侧地址就带端口）。
EOF
  exit 1
fi

# 密钥：缺失只降级（该头留注释、私有仓库会 401），不阻断渲染 ——
# 与 init-center.sh 的 fail-fast 不同：中心缺 token 起不来，Git Proxy 缺 token 仍是一台能跑的 nginx，
# 而且只配了一个 repo / 没配 repo 的现场本来就不会用到它。
GIT_PUB_TOKEN=""
GIT_PUB_USER_FROM_SEC=""
if [[ -f "${SEC_FILE}" ]]; then
  GIT_PUB_TOKEN="$(sec_get_optional "${STACK_ROOT}" wp_git_pub_token || true)"
  GIT_PUB_USER_FROM_SEC="$(sec_get_optional "${STACK_ROOT}" wp_git_pub_user || true)"
fi
[[ -n "${GIT_PUB_USER_FROM_SEC}" ]] && WP_GIT_PUB_USER="${GIT_PUB_USER_FROM_SEC}"
if [[ -z "${GIT_PUB_TOKEN}" ]]; then
  warn "未读到 wp_git_pub_token（.wist/sec-value.yml），渲染出的 nginx 不带上游鉴权头 —— 私有仓库会返回 401"
fi

mkdir -p "${OUT_DIR}"

tmp="$(mktemp "${OUT_DIR}/.git-proxy.value.XXXXXX")"
python3 - "${tmp}" "${SERVER_NAME}" "${WP_GIT_BASE_URL}" "${WP_GIT_AUTH_HEADER}" \
  "${WP_GIT_PUB_USER}" "${GIT_PUB_TOKEN}" \
  "${WP_RULES_REPO_URL:-}" "${WP_INFRA_REPO_URL:-}" \
  "${GIT_PROXY_SHORT_PREFIX}" \
  "${GIT_PROXY_ALLOW_CIDR}" "${GIT_PROXY_CLIENT_CERT_VERIFY}" <<'PY'
import base64
import json
import re
import sys
from urllib.parse import urlparse

(
    path,
    server_name,
    git_base,
    header_name,
    git_user,
    git_token,
    models_url,
    infra_url,
    short_prefix,
    allow_cidr,
    client_cert_mode,
) = sys.argv[1:12]

# 从未命中的占位路径：两个仓库都没配时用它，保证 nginx 语法合法且拒绝一切请求。
DISABLED_PATH = "/__git_proxy_disabled__"
# 短路径别名未启用时用另一条永不命中的占位（与上者同口径）。
DISABLED_ALIAS_REGEX = re.escape(DISABLED_PATH)
DISABLED_ALIAS_REWRITE = "^/(.*)$ " + DISABLED_PATH + "/$1 last;"
# 路径类渲染值只允许这些字符：它们会进 nginx 的 rewrite / 注释，不能带空白、引号或 `;`。
PATH_SAFE = re.compile(r"^/[A-Za-z0-9._~/-]*$")


def repo_paths(parsed):
    """同一个仓库的两种路径：带 .git 与不带 .git。

    Git 客户端按配置的 URL 原样请求；发布侧与网关侧可能写任一种，白名单必须都收。
    """
    base = parsed.path.rstrip("/")
    if base.endswith(".git"):
        base = base[:-4]
    return [base + ".git", base]


def common_dir_prefix(paths):
    """多个仓库路径的**公共上级目录**（不会含仓库名本身）。

    两个仓库不同名，所以公共段到这里就会停；只有一个仓库时无「公共目录」可言。
    """
    if len(paths) < 2:
        return ""
    segments = [p.strip("/").split("/") for p in paths]
    common = []
    for parts in zip(*segments):
        if len(set(parts)) != 1:
            break
        common.append(parts[0])
    return "/" + "/".join(common) if common else ""


configured = []
for label, url in (("WP_RULES_REPO_URL", models_url), ("WP_INFRA_REPO_URL", infra_url)):
    if not url:
        continue
    parsed = urlparse(url)
    if not parsed.hostname:
        raise SystemExit(f"{label} 不合法：{url!r}")
    configured.append((label, parsed))

if not configured:
    # 没配仓库：保留一台「拒一切」的 nginx（不阻断 localize —— 中心单独部署是合法形态）。
    # 上游写成回环回退地址：nginx 在**加载时**就会解析 upstream 主机名，
    # 用不可解析的域名会让 `nginx -t` 直接 emerg；这些 location 永不命中，所以不会真的连上去。
    repo_regex = re.escape(DISABLED_PATH)
    models_path = infra_path = ""
    git_host = "127.0.0.1"
    git_authority = "127.0.0.1:1"
    short_regex = DISABLED_ALIAS_REGEX
    short_rewrite = DISABLED_ALIAS_REWRITE
    short_note = "短路径别名未启用（未配置仓库）"
else:
    # 基址留空时从第一个仓库 URL 推导（与旧 init-station.sh 同口径）。
    base = urlparse(git_base) if git_base else configured[0][1]
    if not base.hostname:
        raise SystemExit(f"WP_GIT_BASE_URL 不合法：{git_base!r}")
    host_names = {p.hostname for _, p in configured} | {base.hostname}
    if len(host_names) > 1:
        raise SystemExit("两个仓库与 WP_GIT_BASE_URL 必须同主机（Git Proxy 只反代一个上游）")
    git_host = base.hostname
    git_authority = git_host if not base.port else f"{git_host}:{base.port}"

    all_paths = []
    for _, parsed in configured:
        all_paths.extend(repo_paths(parsed))
    repo_regex = "(?:" + "|".join(re.escape(p) for p in all_paths) + ")"
    models_path = next(
        (repo_paths(p)[0] for label, p in configured if label == "WP_RULES_REPO_URL"), ""
    )
    infra_path = next(
        (repo_paths(p)[0] for label, p in configured if label == "WP_INFRA_REPO_URL"), ""
    )

    # ── 短路径别名：客户端可以只写 `/wp-infra`，代理把上游公共上级目录补回去。──
    # 只对**已配置的仓库**生成；命中后 `rewrite ... last` 回到上面的全路径白名单，
    # 所以鉴权 / 端点限制 / 限流 / 上游凭据只有一份 —— 别名不是第二条通路（仍不是通用反代）。
    short_regex = DISABLED_ALIAS_REGEX
    short_rewrite = DISABLED_ALIAS_REWRITE
    short_note = "短路径别名未启用"
    base_paths = [repo_paths(p)[1] for _, p in configured]  # 不带 .git 的仓库路径
    raw_prefix = short_prefix.strip()
    if raw_prefix.lower() in ("off", "none", "disable"):
        short_note = "短路径别名已关闭（GIT_PROXY_SHORT_PREFIX=off）"
    else:
        prefix = raw_prefix or common_dir_prefix(base_paths)
        if prefix and not prefix.startswith("/"):
            prefix = "/" + prefix
        prefix = prefix.rstrip("/")
        if not prefix:
            if len(configured) == 1:
                short_note = (
                    "短路径别名未启用（只配了一个仓库；设 GIT_PROXY_SHORT_PREFIX 可显式开启）"
                )
            else:
                short_note = (
                    "短路径别名未启用（两个仓库没有公共上级目录；可设 GIT_PROXY_SHORT_PREFIX）"
                )
        elif not PATH_SAFE.fullmatch(prefix):
            print(
                f"  ⚠ GIT_PROXY_SHORT_PREFIX 含不安全字符，短路径别名已关闭：{prefix!r}",
                file=sys.stderr,
            )
            short_note = "短路径别名已关闭（前缀含不安全字符）"
        elif not all(p.startswith(prefix + "/") for p in base_paths):
            print(
                f"  ⚠ GIT_PROXY_SHORT_PREFIX={prefix!r} 不是所有仓库的公共前缀，短路径别名已关闭",
                file=sys.stderr,
            )
            short_note = "短路径别名已关闭（前缀不是两个仓库的公共前缀）"
        else:
            aliases = [p[len(prefix):] for p in base_paths]
            if (
                any(not PATH_SAFE.fullmatch(a) or a == "/" for a in aliases)
                or len(set(aliases)) != len(aliases)
            ):
                print(
                    "  ⚠ 短路径别名会重复或为空，已关闭（两个仓库同名 / 路径互相包含？）",
                    file=sys.stderr,
                )
                short_note = "短路径别名已关闭（别名重复或为空）"
            else:
                alias_paths = []
                for alias in aliases:
                    alias_paths.extend([alias + ".git", alias])
                short_regex = "(?:" + "|".join(re.escape(p) for p in alias_paths) + ")"
                short_rewrite = "^/(.*)$ " + prefix + "/$1 last;"
                short_note = (
                    "短路径别名（补上前缀 " + prefix + "）：" + "、".join(aliases)
                )
                print("  · " + short_note)

if configured and len(configured) == 1:
    missing = "WP_INFRA_REPO_URL" if configured[0][0] == "WP_RULES_REPO_URL" else "WP_RULES_REPO_URL"
    print(f"  ⚠ 只配置了一个仓库（缺 {missing}）：白名单只收已配置的那个", file=sys.stderr)

# ── 上游鉴权头 ──
if not re.fullmatch(r"[A-Za-z0-9-]{1,64}", header_name):
    raise SystemExit(f"WP_GIT_AUTH_HEADER 不合法：{header_name!r}")

auth_lines = ["            # 读 token 未配置：私有仓库会返回 401"]
if git_token and configured:
    if header_name.lower() == "authorization":
        value = "Basic " + base64.b64encode(f"{git_user}:{git_token}".encode()).decode()
    else:
        value = git_token
    if any(ch in value for ch in ('"', "\\", "\n", "\r")):
        raise SystemExit("Git 读 token 含非法字符（引号/反斜杠/换行）")
    auth_lines = [f'            proxy_set_header {header_name} "{value}";']
auth_line = "\n".join(auth_lines)

# ── 来源 IP allowlist ──
allow_lines = []
for item in allow_cidr.split(","):
    cidr = item.strip()
    if not cidr:
        continue
    if not re.fullmatch(r"[0-9A-Fa-f:./]+", cidr):
        raise SystemExit(f"GIT_PROXY_ALLOW_CIDR 项不合法：{cidr!r}")
    allow_lines.append(f"        allow {cidr};")
if allow_lines:
    allow_lines.append("        deny all;")
allow_block = "\n".join(allow_lines) or (
    "        # GIT_PROXY_ALLOW_CIDR 为空：不限制来源 IP"
    "（客户端认证见 GIT_PROXY_CLIENT_CERT_VERIFY）"
)

# ── 双向证书（mTLS）──
mode = client_cert_mode.strip().lower() or "off"
if mode not in ("off", "optional", "on"):
    raise SystemExit(
        f"GIT_PROXY_CLIENT_CERT_VERIFY 只接受 off | optional | on，收到：{client_cert_mode!r}"
    )
if mode == "off":
    client_ca_block = "\n".join([
        "        # off：只验服务端证书（与旧行为一致）。灰度先设 optional 观测一轮日志里的",
        "        # `verify=SUCCESS` 覆盖率，再切 on（客户端必须持 CA-G 签发的证书）。",
    ])
else:
    client_ca_block = "\n".join([
        f"        # mode={mode}：客户端必须持 CA-G（identity/center/gateway-client-ca.pem）签发的证书；",
        "        # 与中心网关面 :3100 是**同一套** per-gateway 身份（URI SAN = gateway_id）。",
        "        ssl_client_certificate /certs/gateway-client-ca.pem;",
        f"        ssl_verify_client {mode};",
        "        ssl_verify_depth 2;",
    ])

values = {
    "git_proxy_server_name": server_name,
    "git_host": git_host,
    "git_authority": git_authority,
    "git_auth_header_line": auth_line,
    "git_proxy_allow": allow_block,
    "git_proxy_repo_regex": repo_regex,
    "git_proxy_models_path": models_path,
    "git_proxy_infra_path": infra_path,
    "git_proxy_short_regex": short_regex,
    "git_proxy_short_rewrite": short_rewrite,
    "git_proxy_short_note": short_note,
    "git_proxy_client_ca": client_ca_block,
    "git_proxy_client_mode": mode,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(values, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

# 含上游读凭据，不能对其他用户可读。
chmod 600 "${tmp}"

if [[ -f "${VALUE_JSON}" ]] && cmp -s "${tmp}" "${VALUE_JSON}"; then
  rm -f "${tmp}"
  note "渲染值与当前一致（server_name=${SERVER_NAME}，client_verify=${GIT_PROXY_CLIENT_CERT_VERIFY}），跳过：${VALUE_JSON}"
else
  mv -f "${tmp}" "${VALUE_JSON}"
  note "已写渲染值：${VALUE_JSON}（server_name=${SERVER_NAME}，client_verify=${GIT_PROXY_CLIENT_CERT_VERIFY}）"
fi

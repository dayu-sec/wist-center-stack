#!/usr/bin/env bash
# WarpStation 发布态**备料脚本**（由 localize 阶段流程调用，幂等）。
#
# 用法：
#   scripts/init-station.sh [配置目录]        # 默认 configs/station
#
# 做的事（设计文档 §9.3）：
#   1) 建运行期目录：gitea/{wparse,wfusion}__{models,infra} / configs / git-proxy / 身份目录；
#   2) 确保 `.wist/sec-value.yml` 有 station_db_password（缺失则生成）；
#      wp_git_push_token / wp_git_pub_token 由运维通过环境注入或直接写 .wist（缺失则留空并告警）；
#   3) 写 configs/station/station.env（compose env_file）：Git 写账号/token、DB 密码；
#   4) 写 configs/station/station.value.json（gx.tpl 渲染输入，含 DB 密码）；
#   5) 写 configs/git-proxy/git-proxy.value.json（含 Git 读凭据；600）；
#   6) 预克隆两个外部 Git 私有仓库到 gitea/wparse__models、gitea/wparse__infra（已存在则复用）；
#   7) 确保 identity/station/warparse-ca.pem 存在（默认复制中心 CA；已存在不覆盖）；
#   8) 生成 configs/station/gateway-wparse-snippet.toml（Gateway 对接片段）。
#
# 环境（gops 把合并后的系统变量以环境变量注入 localize 流程）：
#   STATION_DB_NAME / STATION_MODELS_REPO_URL / STATION_INFRA_REPO_URL / STATION_LOG_LEVEL
#   GIT_PROXY_PUBLIC_BASE / GIT_PROXY_ALLOW_CIDR / CENTER_DOMAIN / GIT_PROXY_PORT
#   WP_GIT_BASE_URL / WP_GIT_PUSH_USER / WP_GIT_PUB_USER / WP_GIT_AUTH_HEADER
#   WP_GIT_PUSH_TOKEN / WP_GIT_PUB_TOKEN（密钥，也可写 .wist 同名键）
#   STATION_SKIP_REPO_CHECK 1 = 跳过分支/目录结构校验（只用于排障）
#
# 幂等：DB 密码只生成一次；token 有环境值才覆盖；value.json / env / 片段内容不变就不碰 mtime；
#       已有 git 工作副本一律复用（只校正 origin URL），不覆盖现场改动。
set -euo pipefail

CONFIG_DIR="${1:-configs/station}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATION_DB_NAME="${STATION_DB_NAME:-wp-station}"
STATION_MODELS_REPO_URL="${STATION_MODELS_REPO_URL:-}"
STATION_INFRA_REPO_URL="${STATION_INFRA_REPO_URL:-}"
STATION_LOG_LEVEL="${STATION_LOG_LEVEL:-info}"
CENTER_DOMAIN="${CENTER_DOMAIN:-center.example.com}"
GIT_PROXY_PUBLIC_BASE="${GIT_PROXY_PUBLIC_BASE:-}"
GIT_PROXY_ALLOW_CIDR="${GIT_PROXY_ALLOW_CIDR:-}"
GIT_PROXY_PORT="${GIT_PROXY_PORT:-18082}"
WP_GIT_BASE_URL="${WP_GIT_BASE_URL:-}"
WP_GIT_PUSH_USER="${WP_GIT_PUSH_USER:-}"
WP_GIT_PUB_USER="${WP_GIT_PUB_USER:-}"
WP_GIT_AUTH_HEADER="${WP_GIT_AUTH_HEADER:-Authorization}"
STATION_SKIP_REPO_CHECK="${STATION_SKIP_REPO_CHECK:-0}"

SEC_DIR="${STACK_ROOT}/.wist"
SEC_FILE="${SEC_DIR}/sec-value.yml"
CENTER_IDENTITY_DIR="${STACK_ROOT}/identity/center"
STATION_IDENTITY_DIR="${STACK_ROOT}/identity/station"
GIT_PROXY_CONFIG_DIR="${STACK_ROOT}/configs/git-proxy"
# v0.2.14 固定布局：gitea/<system>__<area>。
STATION_GITEA_ROOT="${CONFIG_DIR}/gitea"
MODELS_DIR="${STATION_GITEA_ROOT}/wparse__models"
INFRA_DIR="${STATION_GITEA_ROOT}/wparse__infra"

note() { echo "  $*"; }
warn() { echo "  ⚠ $*" >&2; }

# 去掉末尾斜杠，避免拼出 //...
GIT_PROXY_PUBLIC_BASE="${GIT_PROXY_PUBLIC_BASE%/}"
WP_GIT_BASE_URL="${WP_GIT_BASE_URL%/}"
if [[ -z "${GIT_PROXY_PUBLIC_BASE}" ]]; then
  GIT_PROXY_PUBLIC_BASE="https://${CENTER_DOMAIN}:${GIT_PROXY_PORT}"
fi

mkdir -p \
  "${CONFIG_DIR}" \
  "${STATION_GITEA_ROOT}/wparse__models" \
  "${STATION_GITEA_ROOT}/wparse__infra" \
  "${STATION_GITEA_ROOT}/wfusion__models" \
  "${STATION_GITEA_ROOT}/wfusion__infra" \
  "${SEC_DIR}" \
  "${STATION_IDENTITY_DIR}" \
  "${GIT_PROXY_CONFIG_DIR}"

# 迁移旧布局：v0.2.14 之前用 configs/station/project_{models,infra}。
for pair in "project_models:wparse__models" "project_infra:wparse__infra"; do
  old="${CONFIG_DIR}/${pair%%:*}"
  new="${STATION_GITEA_ROOT}/${pair##*:}"
  if [[ -e "${old}" && ! -e "${new}/.git" && -z "$(ls -A "${new}" 2>/dev/null || true)" ]]; then
    note "迁移旧工作副本：${old} → ${new}"
    rmdir "${new}" 2>/dev/null || true
    mv "${old}" "${new}"
  fi
done

# ── 1) 密钥文件：DB 密码自动生成；Git 读写 token 由运维注入 ──
[[ -f "${SEC_FILE}" ]] || : >"${SEC_FILE}"
python3 - "${SEC_FILE}" "${WP_GIT_PUSH_TOKEN:-}" "${WP_GIT_PUB_TOKEN:-}" <<'PY'
import re, secrets, sys

path, write_token, read_token = sys.argv[1:4]


def read_text():
    with open(path) as handle:
        return handle.read()


def get_value(text, key):
    match = re.search(rf"(?m)^\s*{key}\s*:\s*(.*)$", text)
    if not match:
        return ""
    value = match.group(1).strip()
    if value in ('""', "''"):
        return ""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    return value


def ensure_generated(text, key, prefix):
    if re.search(rf"(?m)^\s*{key}\s*:", text):
        print(f"  复用已有 {key}")
        return text
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"{key}: {prefix}{secrets.token_hex(24)}\n"
    print(f"  已生成 {key}")
    return text


def set_value(text, key, value):
    pattern = re.compile(rf"(?m)^(\s*{key}\s*:\s*)(.*)$")
    match = pattern.search(text)
    if match:
        return text[: match.start(2)] + value + text[match.end(2) :]
    if text and not text.endswith("\n"):
        text += "\n"
    return text + f"{key}: {value}\n"


def ensure_provided(text, key, value):
    if re.search(rf"(?m)^\s*{key}\s*:", text):
        if value:
            text = set_value(text, key, value)
            print(f"  已更新 {key}（来自环境）")
        else:
            print(f"  复用已有 {key}")
        return text
    if value:
        text = set_value(text, key, value)
        print(f"  已写入 {key}（来自环境）")
    else:
        text = set_value(text, key, "")
        print(f"  ⚠ {key} 未提供（环境变量为空）；相关链路会失败，见脚本头部说明")
    return text


text = read_text()
text = ensure_generated(text, "station_db_password", "s")

# 旧键迁移：station_git_password / cnb_git_read_token → 通用名。
legacy_push = get_value(text, "station_git_password")
if legacy_push and not get_value(text, "wp_git_push_token"):
    text = set_value(text, "wp_git_push_token", legacy_push)
    print("  已迁移 station_git_password → wp_git_push_token")
legacy_pub = get_value(text, "cnb_git_read_token")
if legacy_pub and not get_value(text, "wp_git_pub_token"):
    text = set_value(text, "wp_git_pub_token", legacy_pub)
    print("  已迁移 cnb_git_read_token → wp_git_pub_token")

# 用户名不是密钥，但放在同一文件便于现场维护；缺失时留空，回退到 vars。
for key in ("wp_git_push_user", "wp_git_pub_user"):
    if not re.search(rf"(?m)^\s*{key}\s*:", text):
        text = set_value(text, key, "")

text = ensure_provided(text, "wp_git_push_token", write_token.strip())
text = ensure_provided(text, "wp_git_pub_token", read_token.strip())
with open(path, "w") as handle:
    handle.write(text)
PY
chmod 600 "${SEC_FILE}"

get_secret() {
  local value
  value="$(sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "${SEC_FILE}" | head -n1 | tr -d '\r')"
  case "${value}" in
    '""' | "''") value="" ;;
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "${value}"
}

STATION_DB_PASSWORD="$(get_secret station_db_password)"
GIT_PUSH_TOKEN="$(get_secret wp_git_push_token)"
GIT_PUB_TOKEN="$(get_secret wp_git_pub_token)"
GIT_PUSH_USER="$(get_secret wp_git_push_user)"
GIT_PUB_USER="$(get_secret wp_git_pub_user)"
[[ -n "${GIT_PUSH_USER}" ]] || GIT_PUSH_USER="${WP_GIT_PUSH_USER:-}"
[[ -n "${GIT_PUB_USER}" ]] || GIT_PUB_USER="${WP_GIT_PUB_USER:-}"

[[ -n "${STATION_DB_PASSWORD}" ]] || {
  echo "错误：${SEC_FILE} 缺少 station_db_password" >&2
  exit 1
}

# 纯数字密码会被 WarpStation 的 config crate（try_parsing）当成整数，反序列化到 String 会失败。
case "${STATION_DB_PASSWORD}" in
  *[!0-9]*) ;;
  *)
    echo "错误：station_db_password 是纯数字；请改成含字母的值（.wist/sec-value.yml）" >&2
    exit 1
    ;;
esac

[[ -n "${GIT_PUSH_TOKEN}" ]] || warn "wp_git_push_token 为空：WarpStation 无法 push（请写 .wist 或 WP_GIT_PUSH_TOKEN）"
[[ -n "${GIT_PUB_TOKEN}" ]] || warn "wp_git_pub_token 为空：Git Proxy 无法拉取私有仓库（请写 .wist 或 WP_GIT_PUB_TOKEN）"
[[ -n "${GIT_PUSH_USER}" ]] || warn "wp_git_push_user 为空：预克隆/push 的用户名为空"
[[ -z "${GIT_PUB_USER}" && -n "${GIT_PUB_TOKEN}" ]] && warn "wp_git_pub_user 为空：Git Proxy Basic Auth 用户名为空"
case "${GIT_PUSH_TOKEN}${GIT_PUB_TOKEN}" in
  *$'\n'* | *$'\r'*)
    echo "错误：Git token 含换行，无法写入 env 文件" >&2
    exit 1
    ;;
esac

# WarpStation 的 [gitea].base_url：留空则从仓库 URL 推导（scheme://host）。
if [[ -z "${WP_GIT_BASE_URL}" ]]; then
  WP_GIT_BASE_URL="$(python3 -c 'import sys;from urllib.parse import urlparse;p=urlparse(sys.argv[1]);print(f"{p.scheme}://{p.netloc}")' "${STATION_MODELS_REPO_URL}")"
fi
[[ -n "${WP_GIT_BASE_URL}" ]] || {
  echo "错误：无法推导 WP_GIT_BASE_URL（STATION_MODELS_REPO_URL 为空或不合法）" >&2
  exit 1
}

# ── 2) 预克隆外部 Git 仓库（git-only；不依赖任何 Git 服务 API）──
# 网络凭据：预克隆/拉取只需读权限，优先用读 token（push token 可能只有写作用域）；
# 推送到远端由 WarpStation 用 station.env 里的写 token 完成。
CLONE_USER="${GIT_PUB_USER:-${GIT_PUSH_USER}}"
CLONE_TOKEN="${GIT_PUB_TOKEN:-${GIT_PUSH_TOKEN}}"

# git_net <工作目录> <git 参数...>：带 askpass 凭据执行 git（不回显到进程列表/history）。
git_net() {
  local dir="$1" rc
  shift
  if [[ -z "${CLONE_TOKEN}" ]]; then
    git -C "${dir}" "$@"
    return $?
  fi
  local askpass
  askpass="$(mktemp "${SEC_DIR}/.askpass.XXXXXX")"
  cat >"${askpass}" <<'ASK'
#!/bin/sh
case "$1" in
  *[Uu]sername*) printf '%s\n' "${WIST_GIT_USERNAME}" ;;
  *) printf '%s\n' "${WIST_GIT_PASSWORD}" ;;
esac
ASK
  chmod 700 "${askpass}"
  GIT_ASKPASS="${askpass}" WIST_GIT_USERNAME="${CLONE_USER}" \
    WIST_GIT_PASSWORD="${CLONE_TOKEN}" GIT_TERMINAL_PROMPT=0 \
    git -C "${dir}" "$@"
  rc=$?
  rm -f "${askpass}"
  return ${rc}
}

clone_or_update() {
  local url="$1" dest="$2" label="$3"
  [[ -n "${url}" ]] || {
    echo "错误：${label} 的仓库地址为空（STATION_MODELS_REPO_URL / STATION_INFRA_REPO_URL）" >&2
    exit 1
  }

  if [[ -d "${dest}/.git" ]]; then
    note "${label}：复用已有工作副本 ${dest}"
    local current_origin
    current_origin="$(git -C "${dest}" remote get-url origin 2>/dev/null || true)"
    if [[ -z "${current_origin}" ]]; then
      git -C "${dest}" remote add origin "${url}"
    elif [[ "${current_origin}" != "${url}" ]]; then
      # 远端变更时**不能**只改 origin：旧历史会被下一次 push 带到新仓库。
      note "${label}：仓库地址变更 ${current_origin} → ${url}"
      # 只拦**已跟踪文件**的改动：未跟踪文件（WarpStation 生成的默认目录）不会被 reset 破坏。
      if [[ -n "$(git -C "${dest}" status --porcelain --untracked-files=no)" ]]; then
        echo "错误：${dest} 有已跟踪文件的未提交改动，拒绝自动切换远端；请先提交/备份后重跑" >&2
        exit 1
      fi
      git -C "${dest}" remote set-url origin "${url}"
      if ! git_net "${dest}" fetch --prune origin; then
        echo "错误：${label} 切换远端后拉取失败（检查读 token 权限）" >&2
        exit 1
      fi
      if git -C "${dest}" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
        git -C "${dest}" checkout -q -B main origin/main
        note "${label}：已重置到新远端 main"
      fi
    fi
  else
    if [[ -d "${dest}" ]] && [[ -n "$(ls -A "${dest}" 2>/dev/null || true)" ]]; then
      echo "错误：${dest} 非空且不是 git 仓库；请清空/迁移后重跑" >&2
      exit 1
    fi
    if [[ -z "${CLONE_TOKEN}" ]]; then
      warn "${label}：没有读 token，跳过预克隆（首次 clone 需要凭据）"
      return 0
    fi
    note "${label}：克隆 ${url} → ${dest}"
    if ! git_net "${dest%/*}" clone --origin origin "${url}" "${dest}"; then
      echo "错误：${label} 克隆失败（检查读 token 权限与网络）" >&2
      exit 1
    fi
  fi

  # 工作区硬化：禁用 hooks、禁止 file:// 协议；origin 保持干净 URL（不带 token）。
  git -C "${dest}" config credential.helper ""
  git -C "${dest}" config core.hooksPath /dev/null
  git -C "${dest}" config protocol.file.allow never
}

clone_or_update "${STATION_MODELS_REPO_URL}" "${MODELS_DIR}" "wp-rules(wparse__models)"
clone_or_update "${STATION_INFRA_REPO_URL}" "${INFRA_DIR}" "wp-infra(wparse__infra)"

check_repo() {
  local dest="$1" dir="$2" label="$3"
  [[ -d "${dest}/.git" ]] || return 0
  local branch
  branch="$(git -C "${dest}" branch --show-current 2>/dev/null || true)"
  if [[ "${branch}" != "main" ]]; then
    if [[ "${STATION_SKIP_REPO_CHECK}" == "1" ]]; then
      warn "${label}：当前分支 '${branch}'（期望 main），已按 STATION_SKIP_REPO_CHECK=1 跳过"
    else
      echo "错误：${label} 当前分支 '${branch}'，设计约定默认分支为 main；请对齐后重跑" >&2
      exit 1
    fi
  fi
  if [[ ! -d "${dest}/${dir}" ]]; then
    # 新仓库可能只有一个 README（内容由 WarpStation 首次发布时创建）；
    # 只有“已有实际内容但结构不对”才 fail-closed。
    local extra
    extra="$(find "${dest}" -mindepth 1 -maxdepth 1 \
      ! -name .git ! -name .gitignore ! -name README.md | wc -l | tr -d ' ')"
    if [[ "${extra}" == "0" ]]; then
      note "${label}：空仓库（仅 README），目录 ${dir}/ 由 WarpStation 首次发布时创建"
      return 0
    fi
    if [[ "${STATION_SKIP_REPO_CHECK}" == "1" ]]; then
      warn "${label}：缺少目录 ${dir}/（已跳过校验）"
    else
      echo "错误：${label} 缺少目录 ${dir}/；请确认仓库结构（可临时 STATION_SKIP_REPO_CHECK=1）" >&2
      exit 1
    fi
  fi
}

check_repo "${MODELS_DIR}" "models" "wp-rules(wparse__models)"
check_repo "${INFRA_DIR}" "conf" "wp-infra(wparse__infra)"

# ── 3) station.env（compose env_file；600）──
ENV_FILE="${CONFIG_DIR}/station.env"
tmp_env="$(mktemp "${CONFIG_DIR}/.station.env.XXXXXX")"
{
  echo "WP_STATION__GITEA__USERNAME=${GIT_PUSH_USER}"
  echo "WP_STATION__GITEA__PASSWORD=${GIT_PUSH_TOKEN}"
  echo "WP_STATION__DATABASE__PASSWORD=${STATION_DB_PASSWORD}"
} >"${tmp_env}"
chmod 600 "${tmp_env}"

# ── 4) 渲染值：WarpStation config.toml ──
VALUE_JSON="${CONFIG_DIR}/station.value.json"
tmp_json="$(mktemp "${CONFIG_DIR}/.station.value.XXXXXX")"
python3 - "${tmp_json}" "${STATION_LOG_LEVEL}" "${STATION_DB_NAME}" \
  "${STATION_DB_PASSWORD}" "${WP_GIT_BASE_URL}" "${GIT_PUSH_USER}" <<'PY'
import json, sys

path, log_level, db_name, db_password, git_base, git_user = sys.argv[1:7]
data = {
    "log_level": log_level,
    "station_db_name": db_name,
    "pg_user": "station_app",
    "pg_password": db_password,
    "gitea_base_url": git_base,
    "gitea_username": git_user,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
chmod 600 "${tmp_json}"

# ── 5) 渲染值 + 路径推导：Git Proxy / Gateway 片段 ──
PROXY_VALUES="${GIT_PROXY_CONFIG_DIR}/git-proxy.value.json"
tmp_proxy="$(mktemp "${GIT_PROXY_CONFIG_DIR}/.git-proxy.value.XXXXXX")"
python3 - "${tmp_proxy}" "${CENTER_DOMAIN}" "${WP_GIT_BASE_URL}" \
  "${WP_GIT_AUTH_HEADER}" "${GIT_PUB_USER}" "${GIT_PUB_TOKEN}" \
  "${STATION_MODELS_REPO_URL}" "${STATION_INFRA_REPO_URL}" "${GIT_PROXY_ALLOW_CIDR}" <<'PY'
import base64, json, re, sys
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
    allow_cidr,
) = sys.argv[1:10]

models = urlparse(models_url)
infra = urlparse(infra_url)
git = urlparse(git_base)

if not git.hostname:
    raise SystemExit(f"WP_GIT_BASE_URL 不合法：{git_base!r}")
if not models.hostname or not infra.hostname:
    raise SystemExit("STATION_MODELS_REPO_URL / STATION_INFRA_REPO_URL 不合法")
if models.hostname != git.hostname or infra.hostname != git.hostname:
    raise SystemExit("两个仓库与 WP_GIT_BASE_URL 必须同主机（Git Proxy 只反代一个上游）")


def repo_paths(parsed):
    """返回同一个仓库的两种路径：带 .git 与不带 .git。

    Git 客户端会按配置的 URL 原样请求；WarpStation/Gateway 里可能写任一种。
    """
    base = parsed.path.rstrip("/")
    if base.endswith(".git"):
        base = base[:-4]
    return [base + ".git", base]


models_paths = repo_paths(models)
infra_paths = repo_paths(infra)
models_path = models_paths[0]
infra_path = infra_paths[0]
repo_regex = "(?:" + "|".join(
    re.escape(p) for p in [*models_paths, *infra_paths]
) + ")"

if not re.fullmatch(r"[A-Za-z0-9-]{1,64}", header_name):
    raise SystemExit(f"WP_GIT_AUTH_HEADER 不合法：{header_name!r}")

auth_line = "            # 读 token 未配置：私有仓库会返回 401"
if git_token:
    if header_name.lower() == "authorization":
        value = "Basic " + base64.b64encode(f"{git_user}:{git_token}".encode()).decode()
    else:
        value = git_token
    if any(ch in value for ch in ('"', "\\", "\n", "\r")):
        raise SystemExit("Git 读 token 含非法字符（引号/反斜杠/换行）")
    auth_line = f'            proxy_set_header {header_name} "{value}";'

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
allow_block = "\n".join(allow_lines) or "        # GIT_PROXY_ALLOW_CIDR 为空：对管理网放开（客户端认证为 TODO）"

authority = git.hostname if not git.port else f"{git.hostname}:{git.port}"

values = {
    "git_proxy_server_name": server_name,
    "git_host": git.hostname,
    "git_authority": authority,
    "git_auth_header_line": auth_line,
    "git_proxy_allow": allow_block,
    "git_proxy_repo_regex": repo_regex,
    "git_proxy_models_path": models_path,
    "git_proxy_infra_path": infra_path,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(values, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
chmod 600 "${tmp_proxy}"

MODELS_REPO_PATH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["git_proxy_models_path"])' "${tmp_proxy}")"
INFRA_REPO_PATH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["git_proxy_infra_path"])' "${tmp_proxy}")"

# station.env 里的两个代理地址现在可以落定（用 sed 替换占位符，不重复解析）。
sed -i.bak \
  -e "s#__MODELS_PATH__#${MODELS_REPO_PATH}#g" \
  -e "s#__INFRA_PATH__#${INFRA_REPO_PATH}#g" \
  "${tmp_env}"
rm -f "${tmp_env}.bak"

install_if_changed() {
  local tmp="$1" dst="$2" label="$3"
  if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    note "${label} 无变化：${dst}"
  else
    mv -f "${tmp}" "${dst}"
    note "已写 ${label}：${dst}"
  fi
}

install_if_changed "${tmp_env}" "${ENV_FILE}" "station.env（600）"
install_if_changed "${tmp_json}" "${VALUE_JSON}" "渲染值（600）"
install_if_changed "${tmp_proxy}" "${PROXY_VALUES}" "Git Proxy 渲染值（600）"

# ── 6) WarpStation 预加载的 WarpParse CA：默认用中心 CA，已存在不覆盖 ──
WPARSE_CA="${STATION_IDENTITY_DIR}/warparse-ca.pem"
if [[ -f "${WPARSE_CA}" ]]; then
  note "WarpParse CA 已存在，跳过：${WPARSE_CA}"
else
  if [[ ! -f "${CENTER_IDENTITY_DIR}/control-center.pem" ]]; then
    echo "错误：找不到中心 CA ${CENTER_IDENTITY_DIR}/control-center.pem；请先完成中心初始化（scripts/init-center.sh）" >&2
    exit 1
  fi
  cp -f "${CENTER_IDENTITY_DIR}/control-center.pem" "${WPARSE_CA}"
  chmod 644 "${WPARSE_CA}"
  note "已复制中心 CA 作为 WarpParse 信任根：${WPARSE_CA}"
fi

# ── 7) Gateway 对接片段（可直接粘贴到 wp-infra/conf/wparse.toml）──
SNIPPET="${CONFIG_DIR}/gateway-wparse-snippet.toml"
tmp_snippet="$(mktemp "${CONFIG_DIR}/.gateway-wparse.XXXXXX")"
cat >"${tmp_snippet}" <<EOF
# 由 scripts/init-station.sh 生成。
# 用途：把下面两段合并进 wp-infra/conf/wparse.toml，保存并发布一次 infra；
# 否则 Gateway 拉到 infra 后 project_remote 会指回 localhost、admin_api 也会绑回 127.0.0.1。
#
# 仓库地址用 \${VAR} 占位，由 Gateway 容器环境注入（orion_variate）：
#   WPARSE_PROJECT_MODELS_REPO=${GIT_PROXY_PUBLIC_BASE}${MODELS_REPO_PATH}
#   WPARSE_PROJECT_INFRA_REPO=${GIT_PROXY_PUBLIC_BASE}${INFRA_REPO_PATH}
#
# Gateway 不持有 CNB 凭据；它只信任 Center CA（Git Proxy 的 TLS 证书由中心 CA 签发）。

[project_remote]
enabled = true
repo = ""

[project_remote.models]
repo = "\${WPARSE_PROJECT_MODELS_REPO}"
init_version = ""

[project_remote.infra]
repo = "\${WPARSE_PROJECT_INFRA_REPO}"
init_version = ""

# 管理面：容器内绑 0.0.0.0 + TLS（非回环绑定必须 TLS），宿主只发布 127.0.0.1:19090。
# gwlinkd 从 Center 命令队列取任务后，用本机 admin token 调 https://127.0.0.1:19090。
[admin_api]
enabled = true
bind = "0.0.0.0:19090"
request_timeout_ms = 15000
max_body_bytes = 4096

[admin_api.tls]
enabled = true
cert_file = "/data/identity/admin-tls.crt.pem"
key_file = "/data/identity/admin-tls.key.pem"

[admin_api.auth]
mode = "bearer_token"
token_file = ".run/admin_api.token"
EOF
chmod 644 "${tmp_snippet}"
install_if_changed "${tmp_snippet}" "${SNIPPET}" "Gateway 对接片段"

note "WarpStation 备料完成：配置 ${CONFIG_DIR}；密钥 ${SEC_FILE}（station_db_password / wp_git_push_token / wp_git_pub_token）"
note "控制台默认账号：admin / 123456（首次登录后请立即修改）"

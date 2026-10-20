#!/usr/bin/env bash
# 准备中心的**现场态值**（`identity/center/.env`）。
#
# 现场态**声明**（`identity/center/wist-center-pub.toml`）**不在这里** —— 它只写 `${VAR}` 引用、
# 不含现场值，由 `sys/workflows/operators.gxl` 用 **tpl** 机制渲染
# （`sys/configs/center/wist-center-pub.toml.tpl` → `identity/center/wist-center-pub.toml`），
# 与其它交付物同一套渲染；重渲动不到现场（值不在这里）。
#
# 本脚本只做一件事：把 `CENTER_PUBLIC_URL`（= `https://<API_WGC_DOMAIN>:<CENTER_HOST_PORT>`，
# 端口为 443 时省略）按缺（**键不存在或值为空**）写进 `.env`，**非空一律保留**（现场改过 / 迁移搬来的）。
#
# 为什么值与声明分开（docker-compose 口径）：声明里只出现 `${VAR}`，真值在 `.env` ——
#   声明可随版本覆盖（重渲），`.env` 是现场唯一写者。中心加载时用「进程环境 > 同目录 `.env`」
#   插值；变量名必须与声明 tpl 里的 `${VAR}` 一一对应。
#
# 落点为什么在 `identity/`：它随 `sys-prj.yml: contract` 自动获得「不进包 / 不重渲 / 必进备份」。
#
# 用法：
#   scripts/init-center-pub.sh [现场态目录]     # 默认 identity/center（可用 CENTER_IDENTITY_DIR 覆盖）
#
# 读合并后的系统变量（gops 以环境变量注入本子进程；见 sys/setting/vars.yml）：
#   WEB_WGC_DOMAIN   管理面 / Web 域名
#   API_WGC_DOMAIN 网关面域名（留空 = api.<WEB_WGC_DOMAIN>）；public_url 用它
#   CENTER_HOST_PORT     中心后端**宿主**端口（默认 3100）→ `CENTER_PUBLIC_URL = https://<域>:<CENTER_HOST_PORT>`
#   端口必须带上：网关按 public_url **直连**中心后端（mTLS；见 docker-compose「网关直连 3100」）；
#   443 那个口是 web 前端（终止 TLS、不透传客户端证书）。端口为 443 时省略。
#
# 幂等：内容没变就不碰文件（不改 mtime）⇒ **可以每次 localize 都跑**。
set -euo pipefail

DIR="${1:-${CENTER_IDENTITY_DIR:-identity/center}}"
ENV_FILE="${DIR}/.env"

# public_url 指向**网关面域名**（网关按它直连中心 3100），不是 Web 域名。
# 留空 = 派生 `api.<WEB_WGC_DOMAIN>`（与 init-center.sh 的 SAN 派生规则一致）。
PUBLIC_API_URL_DOMAIN="${API_WGC_DOMAIN:-api.${WEB_WGC_DOMAIN:-}}"

command -v python3 >/dev/null 2>&1 || { echo "缺少 python3，无法生成现场态值" >&2; exit 1; }
mkdir -p "${DIR}"

# 值：按缺补齐（键不存在或值为空才写；非空一律保留）。
python3 - "${ENV_FILE}" "${PUBLIC_API_URL_DOMAIN}" "${CENTER_HOST_PORT:-3100}" <<'PY'
import os, sys, tempfile

target, domain, port = sys.argv[1:4]
if not domain:
    url = ""
elif not port or port == "443":
    url = f"https://{domain}"
else:
    url = f"https://{domain}:{port}"

HEADER = "\n".join(
    [
        "# wist-center 现场态**值** —— 与同目录 wist-center-pub.toml 里的 ${VAR} 一一对应。",
        "# 由 scripts/init-center-pub.sh 按缺写入（键不存在或值为空才写，非空一律保留）；升级 / 重渲不动它。",
    ]
)
DESIRED = [("CENTER_PUBLIC_URL", url)]


def unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse(text):
    """现有 `KEY=VALUE` → {键: 值}（注释/空行跳过；去可选引号）。"""
    found = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        found[key.strip()] = unquote(value.strip())
    return found


if os.path.exists(target):
    original = open(target, encoding="utf-8").read()
    existing = parse(original)
    lines = original.splitlines()
    changed = False
    for key, value in DESIRED:
        current = existing.get(key)
        if current is None:
            if value == "":
                continue  # 没有域名时不写空串 → 让声明里的 :-默认值生效
            lines.append(f"{key}={value}")
            changed = True
        elif current == "" and value != "":
            for idx, raw in enumerate(lines):
                head, sep, _ = raw.partition("=")
                if sep and head.strip() == key:
                    lines[idx] = f"{key}={value}"
                    break
            changed = True
    text = "\n".join(lines) + "\n"
    if not changed or text == original:
        print(f"  现场态值与当前一致，跳过：{target}")
        sys.exit(0)
    message = f"  已补齐现场态值：{target}"
else:
    written = [f"{key}={value}" for key, value in DESIRED if value]
    text = HEADER + "\n\n" + "\n".join(written) + ("\n" if written else "")
    message = f"  已生成现场态值：{target}"

directory = os.path.dirname(os.path.abspath(target))
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".center-env-", suffix=".env")
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, target)
print(message)
PY

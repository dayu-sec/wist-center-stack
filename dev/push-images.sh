#!/usr/bin/env bash
# 把发布态 compose（sys/docker-compose.yml）里**非 wist\*** 的第三方镜像同步到腾讯云 TCR。
#
# 为什么需要它：wist* 镜像由发布流水线**双推** —— `ghcr.io/dayu-sec/*`（境外）与
# `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快），TCR 里本来就有；但
# **postgres / victoria-metrics / nginx 是上游镜像**
# （`docker.io/library/postgres`、`quay.io/victoriametrics/victoria-metrics`、
# `docker.io/library/nginx`），
# TCR 里**没有**。内网 / 客户环境只方便拉 TCR 时，用本脚本把它们也推进同一个 `cloud` 命名空间，
# 再按末尾提示把 compose 的镜像源指过来即可（本栈源前缀都是变量：
# `PG_SPC` / `VM_SPC` / `WIST_SPC` / `NGINX_SPC`）。
#
# 注意：`nginx` 用官方镜像；推之前先 `docker login ghcr.io` / 相应 registry。
#
# 取镜像的**唯一源**是 `docker compose config --images` —— 让 Compose 自己解析 compose 里的
# `${VAR}`（值来自 `sys/merged_vars.yml` 产品默认 + 栈根 `.env` 现场值），不在这里重造一份解析规则。
#
# 用法：
#   ./dev/push-images.sh [--registry <ref>] [--exclude <glob>] [--keep-path]
#                        [--method auto|buildx|pull] [--dry-run] [--force]
#     ./dev/push-images.sh --dry-run                     # 只列出「会推哪些、推到哪」，不推
#     ./dev/push-images.sh                               # 推非 wist* 镜像到默认 TCR 命名空间
#     ./dev/push-images.sh --registry reg.example.com/ns # 换目标仓库（registry + namespace）
#     ./dev/push-images.sh --method pull                 # 强制 docker pull/tag/push（默认优先 buildx）
#     ./dev/push-images.sh --force                        # 云上已有也覆盖推（默认已有就跳过）
#
# **云上已存在怎么办**：默认**先探目标仓库**——命中且与源 digest 一致就**跳过**（幂等，重复跑不白推）；
#   命中但 digest 不同（上游 tag 被重指等）默认**只告警不覆盖**；确实要覆盖加 `--force`。
# **推完自检**：每推完一个就再 inspect 一遗目标地址、比对 digest 是否落地；不符则报错并以非零码退出
#   （不看 `push` 命令的退出码就算成功）。
#
# 目标仓库（可覆盖 env）：
#   TARGET_REGISTRY   目标 registry + namespace，默认 `dy-sec.tencentcloudcr.com/cloud`
#   EXCLUDE_GLOB      排除的仓库名 glob（按镜像**末段仓库名**匹配），默认 `wist*`
#   METHOD            auto | buildx | pull，默认 auto（有 buildx 用 buildx，否则 pull/tag/push）
#   DRY_RUN           1 等价 --dry-run
#   FORCE             1 等价 --force（不查存在性，直接覆盖推）
#
# 前提：
#   - 已 `docker login dy-sec.tencentcloudcr.com`（推目标仓库要有权限；源镜像都在公开仓库，登录即可拉）。
#   - 目标仓库名默认取源镜像的**末段**（如 `victoriametrics/victoria-metrics` → `victoria-metrics`），
#     与 `cloud/wist-gateway` 的扁平命名一致；要保留源路径（`cloud/victoriametrics/victoria-metrics`）
#     加 `--keep-path`。
#   - 默认走 `docker buildx imagetools create`：**不落本地**、**保留多架构 manifest**（pull/tag/push
#     只会推当前宿主那一种架构）；没有 buildx 时自动回落到 pull/tag/push。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE="${STACK_ROOT}/sys/docker-compose.yml"
MERGED_VARS="${STACK_ROOT}/sys/merged_vars.yml"
LOCAL_ENV="${STACK_ROOT}/.env"

TARGET_REGISTRY="${TARGET_REGISTRY:-dy-sec.tencentcloudcr.com/cloud}"
TARGET_HOST="${TARGET_REGISTRY%%/*}" # registry host（docker login / 鉴权用；TARGET_REGISTRY 是 host + namespace）
EXCLUDE_GLOB="${EXCLUDE_GLOB:-wist*}"
METHOD="${METHOD:-auto}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
SKIP_AUTH_CHECK="${SKIP_AUTH_CHECK:-0}"
KEEP_PATH=0

usage() {
  cat <<'EOF'
用法：./dev/push-images.sh [--registry <ref>] [--exclude <glob>] [--keep-path]
                          [--method auto|buildx|pull] [--dry-run] [--force]
      ./dev/push-images.sh --dry-run                     # 只列出「会推哪些、推到哪」
      ./dev/push-images.sh                               # 推非 wist* 镜像到默认 TCR 命名空间
      ./dev/push-images.sh --registry reg.example.com/ns # 换目标仓库（registry + namespace）
      ./dev/push-images.sh --keep-path                   # 保留源仓库路径（默认只取末段名）
      ./dev/push-images.sh --method pull                 # 强制 docker pull/tag/push
      ./dev/push-images.sh --force                        # 云上已有也覆盖推（默认已有就跳过）
默认先做**登录预检**：目标 registry 无凭据就报错（不撞 401）；SKIP_AUTH_CHECK=1 跳过。
默认再探目标仓库：已有且与源 digest 一致 → 跳过；已有但 digest 不同 → 告警不覆盖（--force 覆盖）。
推完**自动**再 inspect 一遍确认 digest 落地；不符则整趟以非零码退出。
可覆盖 env：TARGET_REGISTRY（默认 dy-sec.tencentcloudcr.com/cloud）  EXCLUDE_GLOB（默认 wist*）
            METHOD（auto|buildx|pull）  DRY_RUN=1（等价 --dry-run）  FORCE=1（等价 --force）
            SKIP_AUTH_CHECK=1（跳过登录预检）
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

note() {
  echo "  $*"
}

# 打印并（非 dry-run 时）执行；dry-run 只打印，不落任何动作。
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# 推送失败提示：按报错分类（源限流 429 / 目标鉴权 401|403 / 其它）。
push_failed() {
  local dest="$1" err="${2:-}"
  note "推送失败：${dest}"
  if printf '%s' "${err}" | grep -qiE 'too many requests|429'; then
    note "  → 源仓库限流（429）：docker.io 匿名拉取有额度 —— \`docker login docker.io\` 提高额度，或稍后重试。"
  elif printf '%s' "${err}" | grep -qiE 'unauthorized|denied|401|403|no basic auth'; then
    note "  → 目标鉴权失败：先 \`docker login ${TARGET_HOST}\`（账号须有 ${TARGET_REGISTRY} 的 push 权限）。"
  else
    note "  → 见上面报错；常见为源限流（docker login docker.io）或目标鉴权（docker login ${TARGET_HOST}）。"
  fi
  failed=$((failed + 1))
}

# 判断 Docker 是否已为某 registry host 存了登录凭据（与 docker 自身同一套解析）：
#   credHelpers[host] → credsStore（调 `docker-credential-<helper> get`）→ 内联 auths[host]。
# 返回 0=有凭据，1=没找到。
# 注意：只判「有没有存凭据」，判不了「凭据是否有 push 权限 / 是否过期」（那只有真推才知道）。
# 另：osxkeychain 的 `list` 不靠谱（返回 {}），所以这里用 `get <host>` 探。
is_logged_in() {
  local host="$1" cfg="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
  [[ -f "${cfg}" ]] || return 1
  python3 - "${cfg}" "${host}" <<'PY'
import json, subprocess, sys
cfg_path, host = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(cfg_path))
except Exception:
    sys.exit(1)
helper = (cfg.get("credHelpers") or {}).get(host) or cfg.get("credsStore")
if helper:
    try:
        p = subprocess.run(["docker-credential-" + helper, "get"],
                           input=host, text=True, capture_output=True)
        if p.returncode == 0:
            sys.exit(0)
    except FileNotFoundError:
        pass
sys.exit(0 if host in (cfg.get("auths") or {}) else 1)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --registry)
      [[ $# -ge 2 ]] || die "--registry 缺参数"
      TARGET_REGISTRY="$2"
      shift 2
      ;;
    --registry=*)
      TARGET_REGISTRY="${1#--registry=}"
      shift
      ;;
    --exclude)
      [[ $# -ge 2 ]] || die "--exclude 缺参数"
      EXCLUDE_GLOB="$2"
      shift 2
      ;;
    --exclude=*)
      EXCLUDE_GLOB="${1#--exclude=}"
      shift
      ;;
    --method)
      [[ $# -ge 2 ]] || die "--method 缺参数"
      METHOD="$2"
      shift 2
      ;;
    --method=*)
      METHOD="${1#--method=}"
      shift
      ;;
    --keep-path)
      KEEP_PATH=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -*)
      usage >&2
      die "未知参数 $1"
      ;;
    *)
      usage >&2
      die "不接受位置参数：$1（目标仓库用 --registry 指定）"
      ;;
  esac
done

[[ -f "${COMPOSE}" ]] || die "找不到 compose：${COMPOSE}"
command -v docker >/dev/null 2>&1 || die "找不到 docker"

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  die "需要 docker compose（v2 的 \`docker compose\` 或 v1 的 \`docker-compose\`）"
fi

HAVE_BUILDX=0
if docker buildx version >/dev/null 2>&1; then HAVE_BUILDX=1; fi

# 探测目标仓库里是否已有该镜像；**只读**（不 pull、不下载）。
# 输出三态，用 `|` 分隔状态与 digest：
#   present|<digest>   已在（有 buildx 时有 digest）
#   present|           已在（无 buildx，只能判存在）
#   absent|            确认不在
#   unknown|           没法判断（网络不通 / 未登录 / 无权限…）—— 不假装「不存在」
# 只有明确的「not found / no such manifest」才判 absent；其它报错一律 unknown。
probe_remote() {
  local ref="$1" out rc
  if [[ "${HAVE_BUILDX}" == "1" ]]; then
    out="$(docker buildx imagetools inspect "${ref}" --format '{{.Manifest.Digest}}' 2>&1)"
    rc=$?
    if [[ "${rc}" -eq 0 && -n "${out}" ]]; then
      printf 'present|%s\n' "${out}"
      return 0
    fi
    case "${out}" in
      *"not found"* | *"manifest unknown"* | *"no such"* | *404* | *NOT_FOUND* | *"name unknown"*)
        printf 'absent|\n'
        ;;
      *) printf 'unknown|\n' ;;
    esac
    return 0
  fi
  out="$(docker manifest inspect "${ref}" 2>&1 >/dev/null)"
  rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    printf 'present|\n'
    return 0
  fi
  case "${out}" in
    *"no such manifest"* | *"not found"* | *"manifest unknown"* | *404*) printf 'absent|\n' ;;
    *) printf 'unknown|\n' ;;
  esac
}

# ── 1) 拼出 compose 变量环境（产品默认 + 现场覆盖）───────────────────────────
# 只喂给 `docker compose config` 解析 ${VAR}，不落盘到栈根、不改任何东西。
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

RAW_DEFAULTS="${TMP}/defaults.env"
ENV_FILE="${TMP}/compose.env"

if [[ -f "${MERGED_VARS}" ]]; then
  # sys/merged_vars.yml → KEY=VALUE（`- name: X` / `value: Y`；去成对引号，\047 是单引号）
  awk '
    /^[[:space:]]*-[[:space:]]*name:/ {
      n = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", n)
      sub(/[[:space:]]+$/, "", n)
      name = n
      next
    }
    /^[[:space:]]*value:/ {
      v = $0
      sub(/^[[:space:]]*value:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v)
      if (name != "") print name "=" v
      next
    }
  ' "${MERGED_VARS}" > "${RAW_DEFAULTS}"
else
  : > "${RAW_DEFAULTS}"
fi

# 现场覆盖（gops sys localize 产出的栈根 .env）排在产品默认之后 —— 合并时同键后者胜。
if [[ -f "${LOCAL_ENV}" ]]; then
  cat "${RAW_DEFAULTS}" "${LOCAL_ENV}" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      key = $0
      sub(/=.*/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == "") next
      val[key] = $0
    }
    END { for (k in val) print val[k] }
  ' > "${ENV_FILE}"
else
  cp "${RAW_DEFAULTS}" "${ENV_FILE}"
fi

# ── 2) 让 Compose 解析镜像（唯一源，别在这里重造 ${VAR} 规则）────────────────
IMAGES_RAW="$(cd "${STACK_ROOT}" && "${DC[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE}" --project-directory "${STACK_ROOT}" config --images)"
# `config --images` 的返回顺序不保证稳定 —— 去重 + 排序，让计划输出可复现。
IMAGES="$(printf '%s\n' "${IMAGES_RAW}" | awk 'NF && !seen[$0]++' | sort)"
[[ -n "${IMAGES}" ]] || die "compose 没解析出任何镜像（检查 ${COMPOSE} 的 image: 段）"

# ── 3) 过滤出非 wist* 镜像并算出目标地址 ─────────────────────────────────────
CANDIDATES="${TMP}/candidates" # 每行：<源>|<目标>|<仓库名>
: > "${CANDIDATES}"

printf '%s\n' "${IMAGES}" | while IFS= read -r img; do
  [[ -n "${img}" ]] || continue

  # 本 compose 用 tag 而非 digest；digest 形式在 pull/tag/push 下没法原样转推，宁可明确报错。
  [[ "${img}" != *@* ]] || die "暂不支持 digest 形式的镜像引用：${img}（改用 tag，或手工转推）"

  # 拆出 <仓库>:<tag>（按「最后一段里的冒号」切 tag）
  ref="${img}"
  name="${ref}"
  tag="latest"
  if [[ "${ref}" == *:* && "${ref##*/}" == *:* ]]; then
    tag="${ref##*:}"
    name="${ref%:*}"
  fi

  # 空仓库 = compose 变量没解析出来，直接报出来（别推出个荒唐地址）
  [[ -n "${name}" && "${name}" != :* ]] || die "镜像解析异常：'${img}'（compose 变量没解析出来？）"
  [[ -n "${tag}" ]] || tag="latest"

  # 去掉 registry host（首段含 '.' / ':' 或就是 localhost）——只留 <path>
  first="${name%%/*}"
  if [[ "${name}" == */* && ( "${first}" == *.* || "${first}" == *:* || "${first}" == "localhost" ) ]]; then
    name="${name#*/}"
  fi
  base="${name##*/}"

  # 排除 wist*（未加引号 = 让 glob 生效）
  case "${base}" in
    ${EXCLUDE_GLOB}) continue ;;
  esac

  # 已经在目标仓库里的跳过
  case "${ref}" in
    "${TARGET_REGISTRY}"/*)
      note "已是目标仓库，跳过：${img}"
      continue
      ;;
  esac

  dest_repo="${base}"
  [[ "${KEEP_PATH}" == "1" ]] && dest_repo="${name}"
  printf '%s|%s|%s\n' "${img}" "${TARGET_REGISTRY}/${dest_repo}:${tag}" "${base}" >> "${CANDIDATES}"
done

COUNT="$(wc -l < "${CANDIDATES}" | tr -d ' ')"
[[ "${COUNT}" != "0" ]] || {
  echo "compose 里的镜像除 ${EXCLUDE_GLOB} 之外没有需要同步的（都已在目标仓库或本就是被排除项）。"
  exit 0
}

# ── 4) 选方法（buildx 保留多架构；缺则回落 pull/tag/push）────────────────────
case "${METHOD}" in
  auto)
    if [[ "${HAVE_BUILDX}" == "1" ]]; then METHOD="buildx"; else METHOD="pull"; fi
    ;;
  buildx)
    docker buildx version >/dev/null 2>&1 || die "指定 --method buildx，但本机没有 buildx"
    ;;
  pull) ;;
  *) die "未知 --method：${METHOD}（可选 auto|buildx|pull）" ;;
esac

# ── 5) 打印计划并执行 ───────────────────────────────────────────────────────
echo "把 compose 里的**非 ${EXCLUDE_GLOB}** 镜像同步到：${TARGET_REGISTRY}"
note "compose : ${COMPOSE}"
if [[ -f "${LOCAL_ENV}" ]]; then
  note "变量源 : sys/merged_vars.yml（产品默认）+ .env（现场覆盖）"
else
  note "变量源 : sys/merged_vars.yml（产品默认；未见 .env）"
fi
if [[ "${METHOD}" == "buildx" ]]; then
  note "方法   : buildx（docker buildx imagetools create —— 不落本地、保留多架构）"
else
  note "方法   : pull（docker pull/tag/push —— 仅当前架构）"
fi
# 登录预检：没存凭据就别去撞 401（dry-run 只告警，实推直接报错）。
if [[ "${SKIP_AUTH_CHECK}" == "1" ]]; then
  note "鉴权   : 跳过登录预检（SKIP_AUTH_CHECK=1）"
elif ! command -v python3 >/dev/null 2>&1; then
  note "鉴权   : 预检跳过（本机无 python3）—— 推送失败会提示登录"
elif is_logged_in "${TARGET_HOST}"; then
  note "鉴权   : 已登录 ${TARGET_HOST}"
elif [[ "${DRY_RUN}" == "1" ]]; then
  note "鉴权   : ⚠ 未见 ${TARGET_HOST} 登录凭据（dry-run 继续；实推前先 docker login）"
else
  die "未登录 ${TARGET_HOST}：推送会 401。先 \`docker login ${TARGET_HOST}\` 再重跑（或 SKIP_AUTH_CHECK=1 跳过预检）。"
fi
[[ "${DRY_RUN}" == "1" ]] && note "模式   : DRY-RUN（只打印，不推；仍会只读探一下目标仓库的现状）"
[[ "${FORCE}" == "1" ]] && note "策略   : --force（已有也覆盖推）"
echo

pushed=0
skipped=0
failed=0

while IFS='|' read -r src dest base; do
  echo "== ${base} =="
  note "源  : ${src}"
  note "目标: ${dest}"

  if [[ "${FORCE}" == "1" ]]; then
    note "状态: --force（不查存在性，直接覆盖推）"
  else
    probe="$(probe_remote "${dest}")"
    status="${probe%%|*}"
    dest_digest="${probe#*|}"
    case "${status}" in
      present)
        # 能拿到 digest 就比一下（拿不到 = 无 buildx，只判存在），避免上游 tag 被重指却不自知
        if [[ -n "${dest_digest}" ]]; then
          src_probe="$(probe_remote "${src}")"
          src_digest="${src_probe#*|}"
          if [[ "${src_probe%%|*}" == "present" && -n "${src_digest}" && "${src_digest}" != "${dest_digest}" ]]; then
            note "状态: 云上已存在，但 digest 与源**不同**（源 ${src_digest} / 云 ${dest_digest}）"
            note "      —— 上游 tag 可能被重指；默认**不覆盖**，确实要覆盖加 --force"
            skipped=$((skipped + 1))
            echo
            continue
          fi
        fi
        note "状态: 云上已存在且一致 → 跳过（要覆盖加 --force）"
        skipped=$((skipped + 1))
        echo
        continue
        ;;
      absent)
        note "状态: 云上不存在 → 推送"
        ;;
      *)
        note "状态: 存在性无法确认（网络/未登录/无权限？）→ 仍尝试推送"
        ;;
    esac
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    # 干跑：只打印将执行的命令（不推送、不自检）。
    if [[ "${METHOD}" == "buildx" ]]; then
      run docker buildx imagetools create --tag "${dest}" "${src}"
    else
      run docker pull "${src}"
      run docker tag "${src}" "${dest}"
      run docker push "${dest}"
    fi
    pushed=$((pushed + 1))
    echo
    continue
  fi

  # ── 推送（捕获输出：既取「期望落地」的 digest，也用于分类报错）──
  expected=""
  push_err=""

  if [[ "${METHOD}" == "buildx" ]]; then
    # imagetools create 逐字节保留源 manifest —— 期望值就是源 index digest。
    probe="$(probe_remote "${src}")"
    expected="${probe#*|}"
    if ! push_out="$(docker buildx imagetools create --tag "${dest}" "${src}" 2>&1)"; then
      printf '%s\n' "${push_out}" | tail -n 6
      push_err="${push_out}"
    fi
  else
    # pull/tag/push 只推**当前架格**的单平台镜像：落地的是**平台 manifest digest**，
    # 与源 index digest 天然不同 —— 期望值只能从 `docker push` 的输出里取。
    if ! push_out="$(docker pull "${src}" 2>&1)"; then
      printf '%s\n' "${push_out}" | tail -n 6
      push_err="${push_out}"
    elif ! push_out="$(docker tag "${src}" "${dest}" 2>&1)"; then
      push_err="${push_out}"
    elif ! push_out="$(docker push "${dest}" 2>&1)"; then
      printf '%s\n' "${push_out}" | tail -n 6
      push_err="${push_out}"
    else
      printf '%s\n' "${push_out}" | sed -n '/digest:/p'
      expected="$(printf '%s\n' "${push_out}" | sed -n 's/.*digest: \(sha256:[0-9a-f]\{1,\}\).*/\1/p' | head -n1)"
    fi
  fi

  if [[ -n "${push_err}" ]]; then
    push_failed "${dest}" "${push_err}"
    echo
    continue
  fi
  pushed=$((pushed + 1))

  # 推完**自动自检**：重新 inspect 目标地址，确认期望 digest 真的落地（不只看命令退出码）。
  actual="$(probe_remote "${dest}")"
  actual="${actual#*|}"
  if [[ -n "${expected}" && -n "${actual}" && "${actual}" == "${expected}" ]]; then
    note "自检: ✅ digest 已落地（${actual}）"
  elif [[ -z "${expected}" || -z "${actual}" ]]; then
    note "自检: ⚠ 无法比对 digest（期望 ${expected:-?} / 实际 ${actual:-?}）—— 请人工确认"
  else
    note "自检: ❌ digest 未落地（期望 ${expected} / 实际 ${actual}）"
    failed=$((failed + 1))
  fi
  echo
done < "${CANDIDATES}"

echo "── 小结：推送 ${pushed} 个 / 跳过 ${skipped} 个 / 失败 ${failed} 个 ──"
echo
if [[ "${failed}" != "0" ]]; then
  echo "‼ 有 ${failed} 个镜像失败（推送不通或推完自检没过）—— 看上面每个的分类提示对症处理后再重跑。" >&2
  exit 1
fi

# ── 6) 收尾：把 compose 指过来的提示 ────────────────────────────────────────
cat <<EOF
── 下一步：把 compose 的镜像源指过来 ──────────────────────────────
  compose 里三个源前缀都是变量（默认值见 sys/setting/vars.yml）：
    WIST_SPC（wist-center / wist-center-web，默认 ghcr.io/dayu-sec）
    PG_SPC  （postgres，默认 docker.io/library）
    VM_SPC  （victoria-metrics，默认 quay.io/victoriametrics）
  要让它们拉 ${TARGET_REGISTRY} 的镜像，在 ops-prj 的 values/<系统名>/sys_value.yml 覆盖后 \`gops sys localize\`（tag 不变）：
    WIST_SPC: ${TARGET_REGISTRY}
    PG_SPC:   ${TARGET_REGISTRY}
    VM_SPC:   ${TARGET_REGISTRY}

  目标仓库里实际推成的镜像（可直接 pull 校验）——已存在的会标注跳过：
EOF
while IFS='|' read -r src dest base; do
  note "${dest}"
done < "${CANDIDATES}"

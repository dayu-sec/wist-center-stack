#!/usr/bin/env bash
# 把宿主侧目录/文件的**属主、属组、权限**对齐到容器内运行身份 —— 让「容器要读写」与「部署账号要
# 维护（改配置 / 跑备份恢复）」两种需求同时成立，且**不依赖这些目录是谁创建的**。
#
# 为什么需要它：
#   center 容器**固定以 uid:gid 999:999 运行**（镜像里 `useradd -r wist`，compose 里也显式钉死）。
#   bind 挂载在 Linux 上**不改变属主**（宿主是谁，容器里就是谁），于是两种稳定故障：
#     · configs/center/state 属主是 root/部署账号且 755 → 容器写不出 JSON store / 制品
#       （Permission denied）→ center 启动报存储不可写；
#     · configs/center/ca/*.key 是 600 且属主不是 999 → 容器读不到 CA 私钥。
#   更麻烦的是：Docker 在 `up` 时会**自行**把缺失的 bind 源目录建成 root:root 755 ——
#   所以「属主取决于谁先创建」，只能在 `up` **之前**显式对齐。
#
# 模型（一处定义，改这里就够）：
#   · 属主 = 执行部署的那个账号（取 SUDO_UID/SUDO_GID，未提权时取 id）—— 它负责改配置、跑备份/恢复；
#   · 属组 = 容器 gid（默认 999）—— 容器进程天然在这个组里；
#   · **需要容器写**的目录 2770（组可写 + **setgid**：目录里新建的文件/目录自动继承该组）；
#     **容器只读**的目录 2755（组可读可进入）；
#   · 私钥与含密钥的配置 640（属组可读）。
#
# 用法：
#   ./scripts/align-host-perms.sh [系统根]      # 缺权限时给出一行命令（免密 sudo 可用时自动提权重跑）
#   sudo ./scripts/align-host-perms.sh          # 等价，但会保留属主为调用账号（读 SUDO_UID/SUDO_GID）
#
# 幂等：已是目标状态就**什么都不做、也不需要任何权限**。
#
# 环境：CONTAINER_GID（默认 999）、CONTAINER_UID（默认 999；与 compose 里 center 的 user: 一致）
set -euo pipefail

ROOT="${1:-.}"
CONTAINER_GID="${CONTAINER_GID:-999}"
CONTAINER_UID="${CONTAINER_UID:-999}"

cd "${ROOT}"
ROOT="$(pwd)"

note() { echo "  $*"; }
die() { echo "错误：$*" >&2; exit 1; }

# 非 Linux 直接跳过：OrbStack / Docker Desktop 的 bind 挂载不校验属主，属主对齐在这里没有意义
# （这也是「macOS 上一直好好的、上 Linux 才炸」的原因）。
if [[ "$(uname -s)" != "Linux" ]]; then
  note "跳过宿主属主对齐（非 Linux：bind 挂载不校验属主，容器照样读写）"
  exit 0
fi

OWNER_UID="${SUDO_UID:-$(id -u)}"
OWNER_GID="${SUDO_GID:-$(id -g)}"
[[ "${CONTAINER_GID}" =~ ^[0-9]+$ ]] ||
  die "CONTAINER_GID 必须是数字 gid（收到 '${CONTAINER_GID}'）；它要与 compose 里 center 的 user: 一致"

# 目标目录：<相对路径>:<权限>（组统一为 CONTAINER_GID）。
#   configs/center/*：中心配置与密钥（容器读写 store/制品、读 CA；部署账号维护）——全部归部署账号，
#     免得 Docker 先建出 root 属主的目录后部署账号自己都写不动。
#   需要容器写的目录 2770（组可写 + setgid）；容器只读的 2755。
TARGET_DIRS=(
  "configs:2755"
  "configs/center:2770"
  "configs/center/ca:2755"
  "configs/center/state:2770"
  "configs/center/artifacts:2770"
  "configs/web:2755"
)
# 目标文件（**存在才处理**，不新建）：
#   ca/*.key            —— 容器要读（CA 私钥 / 服务器私钥）；600 会让容器读不到，故 640。
#   ca/*.srl            —— CA 序列号文件：宿主 openssl 重新签证书时会写它，必须归部署账号。
#   wist-center.toml    —— 容器要读；含运行配置，故 640（不是 644）。
TARGET_FILES=(configs/center/ca/*.key configs/center/ca/*.srl configs/center/wist-center.toml)
TARGET_FILE_MODE=640

# 另一类：**容器要读写、但属主可能不是容器自己**的文件 —— 目前只有 JSON store（未用 PG 时）。
#   容器建的库是 999:999（属主权限就够）→ **不能碰**，一碰就要提权；恢复/搬过来的文件属主是
#   部署账号 → 容器只剩属组这条路，必须属组=容器 gid 且属组可写。所以判「容器身份实际能否读写」。
TARGET_DBS=(configs/center/state/*.json)
DB_FILE_MODE=660

dir_mode_of() {
  local rel="$1" spec
  for spec in "${TARGET_DIRS[@]}"; do
    if [[ "${spec%%:*}" == "${rel}" ]]; then
      printf '%s' "${spec##*:}"
      return 0
    fi
  done
  printf '755'
}

state_of() {
  if [[ -e "$1" ]]; then
    stat -c '%u:%g:%a' "$1"
  else
    printf '缺失'
  fi
}

# ── 1) 先探测（只 stat，不写盘）──
dirs_todo=()
for spec in "${TARGET_DIRS[@]}"; do
  rel="${spec%%:*}"; mode="${spec##*:}"
  [[ "$(state_of "${rel}")" == "${OWNER_UID}:${CONTAINER_GID}:${mode}" ]] || dirs_todo+=("${rel}")
done

files_todo=()
for f in "${TARGET_FILES[@]}"; do
  [[ -e "${f}" ]] || continue # glob 不匹配时是字面量，跳过
  [[ -f "${f}" ]] || { echo "  跳过 ${f}（存在但不是普通文件）" >&2; continue; }
  [[ "$(state_of "${f}")" == "${OWNER_UID}:${CONTAINER_GID}:${TARGET_FILE_MODE}" ]] || files_todo+=("${f}")
done

dbs_todo=()
for f in "${TARGET_DBS[@]}"; do
  [[ -f "${f}" ]] || continue
  read -r f_uid f_gid f_mode <<<"$(stat -c '%u %g %a' "${f}")"
  if [[ "${f_uid}" == "${CONTAINER_UID}" ]]; then
    (( (8#${f_mode} & 0600) == 0600 )) || dbs_todo+=("${f}")
  elif [[ "${f_gid}" == "${CONTAINER_GID}" ]] && (( (8#${f_mode} & 0060) == 0060 )); then
    : # 落进容器的组且属组可读写
  else
    dbs_todo+=("${f}")
  fi
done

if [[ ${#dirs_todo[@]} -eq 0 && ${#files_todo[@]} -eq 0 && ${#dbs_todo[@]} -eq 0 ]]; then
  note "宿主属主/权限已对齐（属主 ${OWNER_UID}、属组 ${CONTAINER_GID}、目录 2770/2755、私钥 ${TARGET_FILE_MODE}），无需改动"
  exit 0
fi

# ── 2) 要改：确认有权限，否则自动提权重跑（仅当免密 sudo 可用），再否则给出那一行命令 ──
can_align=1
if [[ "$(id -u)" -ne 0 ]]; then
  can_align=0
  if [[ "${OWNER_UID}" == "$(id -u)" ]]; then
    case " $(id -G) " in
      *" ${CONTAINER_GID} "*) can_align=1 ;;
    esac
  fi
fi

if [[ "${can_align}" != "1" ]]; then
  if [[ -z "${ALIGN_NO_SUDO:-}" ]] && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    note "需要提权（改属主/属组），检测到免密 sudo → 以 sudo 重跑（属主仍保持为 ${OWNER_UID}:${OWNER_GID}）"
    sudo -E "$0" "$@" && exit 0
    echo "  （sudo 重跑未成功，继续给出可执行命令）" >&2
  fi
  todo_show=()
  [[ ${#dirs_todo[@]} -gt 0 ]] && todo_show+=("${dirs_todo[@]}")
  [[ ${#files_todo[@]} -gt 0 ]] && todo_show+=("${files_todo[@]}")
  [[ ${#dbs_todo[@]} -gt 0 ]] && todo_show+=("${dbs_todo[@]}")
  echo "需要修正但权限不足（目标：属主 ${OWNER_UID}、属组 ${CONTAINER_GID}）：" >&2
  for p in "${todo_show[@]}"; do
    printf '  - %s（现为 %s）\n' "${p}" "$(state_of "${p}")" >&2
  done
  echo "请执行（只做这一步，属主仍是当前账号）：" >&2
  echo "  sudo $0 ${ROOT}" >&2
  exit 1
fi

# ── 3) 应用 ──
if [[ "${OWNER_UID}" == "0" ]]; then
  echo "  警告：以 root 身份部署 —— 栈内文件会变成 root 属主，之后用普通账号跑 localize / 备份会写不动。" >&2
  echo "        建议改用普通账号（已加入 docker 组）执行部署。" >&2
fi

for rel in "${dirs_todo[@]}"; do
  mode="$(dir_mode_of "${rel}")"
  before="$(state_of "${rel}")"
  [[ -e "${rel}" && ! -d "${rel}" ]] &&
    die "${rel} 已存在但不是目录（是文件/符号链接？）—— 删掉它再跑，别让容器挂载点落在文件上"
  mkdir -p "${rel}"
  chown "${OWNER_UID}:${CONTAINER_GID}" "${rel}"
  chmod "${mode}" "${rel}"
  printf '  目录 %s：%s → %s:%s:%s\n' "${rel}" "${before}" "${OWNER_UID}" "${CONTAINER_GID}" "${mode}"
done

for f in "${files_todo[@]}"; do
  before="$(state_of "${f}")"
  chown "${OWNER_UID}:${CONTAINER_GID}" "${f}"
  chmod "${TARGET_FILE_MODE}" "${f}"
  printf '  文件 %s：%s → %s:%s:%s\n' "${f}" "${before}" "${OWNER_UID}" "${CONTAINER_GID}" "${TARGET_FILE_MODE}"
done

for f in "${dbs_todo[@]}"; do
  before="$(stat -c '%u:%g:%a' "${f}")"
  chown "${OWNER_UID}:${CONTAINER_GID}" "${f}"
  chmod "${DB_FILE_MODE}" "${f}"
  printf '  store 文件 %s：%s → %s:%s:%s（容器要读写）\n' "${f}" "${before}" "${OWNER_UID}" "${CONTAINER_GID}" "${DB_FILE_MODE}"
done

note "宿主属主/权限对齐完成：属主 ${OWNER_UID}、属组 ${CONTAINER_GID}（容器内 center 的运行身份）"

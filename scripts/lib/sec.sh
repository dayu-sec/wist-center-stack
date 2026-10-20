#!/usr/bin/env bash
# 栈根密钥读取的唯一入口（**宿主机侧**脚本共用）。
#
# 为什么不各自解析 YAML：密钥文件的解析、路径解析（`sys-prj.yml: secrets.file`）、
# 权限/属主/硬链接校验、值类型校验都在 gops 的 `system::sec` 里，脚本重复实现一遍只会漂移。
# 这里统一转调 `gops sec get`，让“脚本读到的密钥”和“gops 注入的密钥”是同一套规则。
#
# 用法：
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/lib/sec.sh"
#
#   pw="$(sec_get "${STACK_ROOT}" center_db_password)"        # 缺失/文件不合格 → 报错退出
#   maybe="$(sec_get_optional "${STACK_ROOT}" some_key)"      # 键缺失 → 空串；文件本身有问题 → 报错
#
# 约束：
#   · `gops sec` 以**当前目录**的系统清单为准，所以这里显式 `cd` 到栈根；
#   · **不做**“没有 gops 就退回手写解析”的降级：这些脚本本来就由 gops 调起，
#     静默降级会让权限/格式校验形同虚设（安全基线要求 fail-closed）；
#   · **不要**在容器里用（容器内没有 gops，且挂载文件属主与容器 uid 不同）——
#     容器内的密钥解析见 `scripts/db-init.sh`。

# 读取一个**必须存在**的密钥。失败时把 gops 的报错原样透出（含路径与原因）。
#
# 成功时屏蔽 stderr：gops 每次调用会打一行版本横幅 `gops: x.y.z`，
# 在 localize 里每个键一行会很吵。失败时重跑一次让错误信息漏出来。
sec_get() {
  local root="$1" key="$2" out
  if ! command -v gops >/dev/null 2>&1; then
    echo "错误：读取密钥 \`${key}\` 需要 gops（>= 2.8）；请确认 gops 在 PATH 上" >&2
    return 1
  fi
  if out="$( cd "${root}" && gops sec get --show "${key}" 2>/dev/null )"; then
    printf '%s' "${out}"
    return 0
  fi
  ( cd "${root}" && gops sec get --show "${key}" >/dev/null ) || true
  return 1
}

# 读取一个**可能不存在**的密钥：键缺失返回空串，但文件本身不合格仍然报错。
#
# 先 `gops sec list` 做一次文件级校验（路径/权限/格式），再取单值：
# 否则无法区分“键不存在”和“密钥文件不可用”，会把配置错误当成“没配”。
sec_get_optional() {
  local root="$1" key="$2"
  if ! command -v gops >/dev/null 2>&1; then
    echo "错误：读取密钥 \`${key}\` 需要 gops（>= 2.8）；请确认 gops 在 PATH 上" >&2
    return 1
  fi
  # `--json` 同时让 gops 进入 Machine 模式（不打版本横幅），保持 localize 输出干净。
  ( cd "${root}" && gops sec list --json >/dev/null ) || return 1
  ( cd "${root}" && gops sec get --show "${key}" 2>/dev/null ) || true
}

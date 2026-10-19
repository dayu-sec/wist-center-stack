#!/usr/bin/env bash
# 一次性 PG 角色/库初始化（幂等）—— 由 compose 的 db-init 服务在 postgres 容器里执行。
#
# 职责（设计文档 §9.7）：
#   · center_app  ：只连 insight_demo（owner）
#   · station_app ：只连 wp-station（owner）
#   · 两个角色都**不是** superuser；db_admin（PG_USER）只用于 bootstrap / 备份
#   · 既有现场把 db_admin 名下的对象改归属，并收紧 CONNECT/TEMPORARY
#
# 输入：
#   PGHOST / PGUSER / PGPASSWORD / PGDATABASE（db_admin 连接）
#   CENTER_DB_NAME（= PG_DB）、STATION_DB_NAME
#   SEC_FILE（默认 /secrets/sec-value.yml，只读挂载）
#
# 幂等：角色/库存在即跳过；密码每次都对齐到密钥文件；ALTER OWNER / REVOKE 可重复执行。
set -euo pipefail

SEC_FILE="${SEC_FILE:-/secrets/sec-value.yml}"
CENTER_DB_NAME="${CENTER_DB_NAME:?CENTER_DB_NAME required}"
STATION_DB_NAME="${STATION_DB_NAME:?STATION_DB_NAME required}"
ADMIN_ROLE="${PGUSER:?PGUSER required}"

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

CENTER_DB_PASSWORD="$(get_secret center_db_password)"
STATION_DB_PASSWORD="$(get_secret station_db_password)"
[[ -n "${CENTER_DB_PASSWORD}" ]] || {
  echo "错误：${SEC_FILE} 缺少 center_db_password；请先运行 scripts/init-center.sh" >&2
  exit 1
}
[[ -n "${STATION_DB_PASSWORD}" ]] || {
  echo "错误：${SEC_FILE} 缺少 station_db_password；请先运行 scripts/init-station.sh" >&2
  exit 1
}

echo "db-init: 角色 center_app / station_app；库 ${CENTER_DB_NAME} / ${STATION_DB_NAME}"

# psql 变量用 :'name' 做字面量引用；%I / %L 负责标识符与字符串转义。
psql -v ON_ERROR_STOP=1 -d postgres \
  -v center_pw="${CENTER_DB_PASSWORD}" \
  -v station_pw="${STATION_DB_PASSWORD}" \
  -v center_db="${CENTER_DB_NAME}" \
  -v station_db="${STATION_DB_NAME}" <<'SQL'
SELECT format('CREATE ROLE center_app LOGIN')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'center_app')
\gexec

ALTER ROLE center_app LOGIN PASSWORD :'center_pw';

SELECT format('CREATE ROLE station_app LOGIN')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'station_app')
\gexec

ALTER ROLE station_app LOGIN PASSWORD :'station_pw';

SELECT format('CREATE DATABASE %I OWNER station_app', :'station_db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'station_db')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO center_app', :'center_db')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO station_app', :'station_db')
\gexec

SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', :'center_db')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO center_app', :'center_db')
\gexec

SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', :'station_db')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO station_app', :'station_db')
\gexec
SQL

# 既有现场：把 **public schema 里属于 db_admin 的应用对象**改归属。
# 不能用 `REASSIGN OWNED BY db_admin`：bootstrap 超级用户同时拥有 information_schema
# 等“系统必需对象”，REASSIGN 会直接报错。这里只动应用对象（表/序列/视图/函数/类型）。
migrate_public_objects() {
  local db="$1" app_role="$2"
  echo "db-init: 迁移 ${db}.public 中属于 ${ADMIN_ROLE} 的对象 → ${app_role}"
  psql -v ON_ERROR_STOP=1 -d "${db}" \
    -v admin_role="${ADMIN_ROLE}" -v app_role="${app_role}" <<'SQL'
SELECT format('ALTER %s %I.%I OWNER TO %I',
              CASE c.relkind
                WHEN 'r' THEN 'TABLE'
                WHEN 'p' THEN 'TABLE'
                WHEN 'v' THEN 'VIEW'
                WHEN 'm' THEN 'MATERIALIZED VIEW'
                WHEN 'f' THEN 'FOREIGN TABLE'
              END,
              n.nspname, c.relname, :'app_role')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = :'admin_role')
\gexec

-- 独立序列；serial/identity 序列由上面的 ALTER TABLE 自动带过去（不能单独改）。
SELECT format('ALTER SEQUENCE %I.%I OWNER TO %I', n.nspname, c.relname, :'app_role')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'S'
  AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = :'admin_role')
  AND NOT EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.classid = 'pg_class'::regclass
      AND d.objid = c.oid
      AND d.deptype IN ('a', 'i')
  )
\gexec

SELECT format('ALTER FUNCTION %I.%I(%s) OWNER TO %I',
              n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), :'app_role')
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proowner = (SELECT oid FROM pg_roles WHERE rolname = :'admin_role')
\gexec

SELECT format('ALTER TYPE %I.%I OWNER TO %I', n.nspname, t.typname, :'app_role')
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'public'
  AND t.typtype IN ('c', 'd', 'e')
  AND t.typowner = (SELECT oid FROM pg_roles WHERE rolname = :'admin_role')
\gexec
SQL
}

migrate_public_objects "${CENTER_DB_NAME}" center_app
migrate_public_objects "${STATION_DB_NAME}" station_app

# 自检：交叉连接必须失败（用 PGPASSWORD 覆盖管理员口令）。
if PGUSER=station_app PGPASSWORD="${STATION_DB_PASSWORD}" psql -v ON_ERROR_STOP=1 \
  -d "${CENTER_DB_NAME}" -c 'SELECT 1' >/dev/null 2>&1; then
  echo "错误：station_app 仍能连接 ${CENTER_DB_NAME}（隔离失败）" >&2
  exit 1
fi
if PGUSER=center_app PGPASSWORD="${CENTER_DB_PASSWORD}" psql -v ON_ERROR_STOP=1 \
  -d "${STATION_DB_NAME}" -c 'SELECT 1' >/dev/null 2>&1; then
  echo "错误：center_app 仍能连接 ${STATION_DB_NAME}（隔离失败）" >&2
  exit 1
fi

echo "db-init: 完成（center_app → ${CENTER_DB_NAME}；station_app → ${STATION_DB_NAME}）"

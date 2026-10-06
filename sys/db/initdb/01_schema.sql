-- wist-center 网关存储 schema（docker-entrypoint-initdb.d）
-- 由 docker-compose.yml 的 postgres 服务首次启动时执行。

CREATE TABLE IF NOT EXISTS gateways (
  gateway_id TEXT PRIMARY KEY,
  instance_id TEXT NOT NULL DEFAULT '',
  credential_token_hash TEXT NOT NULL DEFAULT '',
  credential_status TEXT NOT NULL DEFAULT 'active',
  credential_expires_at TIMESTAMPTZ,
  link_token_hash TEXT NOT NULL DEFAULT '',
  link_token_expires_at TIMESTAMPTZ,
  version TEXT,
  status TEXT,
  health TEXT,
  memory_bytes BIGINT,
  cpu_percent DOUBLE PRECISION,
  public_base_url TEXT,
  uptime_seconds BIGINT,
  agent_count BIGINT,
  online_agents BIGINT,
  offline_agents BIGINT,
  last_seen_lag_seconds BIGINT,
  store_bytes BIGINT,
  ingest_accepted_total BIGINT,
  ingest_rejected_total BIGINT,
  last_ingest_at TIMESTAMPTZ,
  memory_total_bytes BIGINT,
  load_1m DOUBLE PRECISION,
  load_5m DOUBLE PRECISION,
  load_15m DOUBLE PRECISION,
  disk_usage_percent DOUBLE PRECISION,
  disk_total_bytes BIGINT,
  disk_available_bytes BIGINT,
  lifecycle_state TEXT,
  initialized_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ
);

-- 幂等补列（既有库）：新建库的 CREATE 已含该列，老库靠这条补上（网关对外域名）。
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS public_base_url TEXT;

-- 网关注册 Token（映射模型 GatewayEnrollmentToken）：只存 hash，限量/状态/有效期，
-- 携带环境绑定与控制中心信任根。
CREATE TABLE IF NOT EXISTS enrollment_tokens (
  token_id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL,
  gateway_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL DEFAULT 'tenant-default',
  environment_id TEXT NOT NULL DEFAULT 'env-default',
  issued_by TEXT NOT NULL DEFAULT '',
  control_center_trust_bundle TEXT,
  max_uses BIGINT NOT NULL DEFAULT 1,
  used_count BIGINT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'Active',
  issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
);

-- Gateway 上报的其下 Agent 状态（快照，agent_id 幂等 upsert）。
CREATE TABLE IF NOT EXISTS agent_status (
  agent_id TEXT PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  instance_id TEXT NOT NULL DEFAULT '',
  version TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'online',
  health TEXT NOT NULL DEFAULT 'healthy',
  memory_bytes BIGINT,
  cpu_percent DOUBLE PRECISION,
  admin_latency_ms BIGINT,
  last_seen_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_status_gateway ON agent_status (gateway_id);

-- 网关生命周期转变历史（append-only 过程记录）。
CREATE TABLE IF NOT EXISTS gateway_lifecycle_events (
  id BIGSERIAL PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  from_state TEXT,
  to_state TEXT NOT NULL,
  at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lifecycle_events_gateway ON gateway_lifecycle_events (gateway_id);

-- 版本发布记录（component = wist-agentd / wist-gateway）。
CREATE TABLE IF NOT EXISTS release_records (
  id BIGSERIAL PRIMARY KEY,
  component TEXT NOT NULL,
  version TEXT NOT NULL,
  artifact_url TEXT NOT NULL,
  package_sha256 TEXT,
  status TEXT NOT NULL,
  published_at TIMESTAMPTZ NOT NULL
);

-- 幂等补列（既有库）：制品内容的 sha256（录入时算出 / 校验）。
ALTER TABLE release_records ADD COLUMN IF NOT EXISTS package_sha256 TEXT;

-- 升级计划（payload 为 JSON，含多目标/网关范围/多步执行）。
CREATE TABLE IF NOT EXISTS upgrade_plans (
  plan_id TEXT PRIMARY KEY,
  payload JSONB NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
  gops_version TEXT,
  gx_version TEXT,
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
  last_seen_at TIMESTAMPTZ,
  archived_at TIMESTAMPTZ
);

-- 幂等补列（既有库）：新建库的 CREATE 已含该列，老库靠这条补上（网关对外域名）。
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS public_base_url TEXT;

-- 幂等补列（既有库）：网关宿主侧依赖工具版本（gops / gx，装在 `$HOME/bin`，由 gwlinkd 探测上报）。
-- 老网关 / 老 gwlinkd 不带这两个键 → 保持 NULL（页面显示「—」，不冒充已安装）。
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS gops_version TEXT;
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS gx_version TEXT;

-- 幂等补列（既有库）：归档时刻（NULL = 未归档）。归档是**标记**：默认视图不再显示这台网关，
-- 状态/历史全留；只归档离线网关，重新上线（换证注册或重新上报 online）时自动清空。
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

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
  platform TEXT,
  status TEXT NOT NULL,
  published_at TIMESTAMPTZ NOT NULL
);

-- 幂等补列（既有库）：制品内容的 sha256（录入时算出 / 校验）。
ALTER TABLE release_records ADD COLUMN IF NOT EXISTS package_sha256 TEXT;

-- 幂等补列（既有库）：目标平台（target-triple；部署栈类包为空）。
ALTER TABLE release_records ADD COLUMN IF NOT EXISTS platform TEXT;

-- 升级计划（payload 为 JSON，含多目标/网关范围/多步执行）。
CREATE TABLE IF NOT EXISTS upgrade_plans (
  plan_id TEXT PRIMARY KEY,
  payload JSONB NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 规则发布命令队列（WarpStation → Center wparse-proxy → gwlinkd → 本机 wparse）。
CREATE TABLE IF NOT EXISTS gateway_commands (
  command_id TEXT PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  body TEXT,
  state TEXT NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  lease_expires_at TIMESTAMPTZ,
  response_status INT,
  response_body TEXT,
  error TEXT,
  -- 任务执行记录（失败时才带）：网关本机目录 + 有界摘要（写入时已脱敏）。
  log_dir TEXT,
  log_excerpt TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_gateway_commands_pending
  ON gateway_commands (gateway_id, state, created_at);
-- 老库补列（0.19.3 新增）：gwlinkd 失败时把任务日志目录 + 摘要一并回传。
ALTER TABLE gateway_commands ADD COLUMN IF NOT EXISTS log_dir TEXT;
ALTER TABLE gateway_commands ADD COLUMN IF NOT EXISTS log_excerpt TEXT;

-- 每网关的 wparse-proxy Bearer token（只存 sha256；明文只发一次）。
CREATE TABLE IF NOT EXISTS gateway_wparse_tokens (
  gateway_id TEXT PRIMARY KEY,
  token_sha256 TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  rotated_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_gateway_wparse_tokens_hash
  ON gateway_wparse_tokens (token_sha256);

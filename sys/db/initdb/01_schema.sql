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
  gwlinkd_version TEXT,
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

-- 幂等补列（既有库）：gwlinkd（宿主侧常驻）**自身**版本（网关容器版本在上面 `version`）。
-- 老 gwlinkd 不带这个键 → 保持 NULL（页面显示「—」）。
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS gwlinkd_version TEXT;

-- 幂等补列（既有库）：归档时刻（NULL = 未归档）。归档是**标记**：默认视图不再显示这台网关，
-- 状态/历史全留；只归档离线网关，重新上线（换证注册或重新上报 online）时自动清空。
ALTER TABLE gateways ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

-- 网关-客户绑定（映射模型 GatewayCustomerBinding）：
--   customer_id 是**权威值**；revision 在换绑时递增；applied_* 由网关状态上报回填。
CREATE TABLE IF NOT EXISTS gateway_customer_bindings (
  gateway_id TEXT PRIMARY KEY,
  customer_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'bound',
  bound_at TIMESTAMPTZ NOT NULL,
  revision BIGINT NOT NULL DEFAULT 1,
  applied_revision BIGINT,
  applied_at TIMESTAMPTZ,
  reported_tenant_id TEXT,
  last_error TEXT
);

-- 幂等补列（既有库；老版本可能只建了前四列，甚至整张表都没建）。
ALTER TABLE gateway_customer_bindings ADD COLUMN IF NOT EXISTS revision BIGINT NOT NULL DEFAULT 1;
ALTER TABLE gateway_customer_bindings ADD COLUMN IF NOT EXISTS applied_revision BIGINT;
ALTER TABLE gateway_customer_bindings ADD COLUMN IF NOT EXISTS applied_at TIMESTAMPTZ;
ALTER TABLE gateway_customer_bindings ADD COLUMN IF NOT EXISTS reported_tenant_id TEXT;
ALTER TABLE gateway_customer_bindings ADD COLUMN IF NOT EXISTS last_error TEXT;

-- 换绑审计（append-only）：绑定表只保留最新值，历史在这里（管理面展示 + 追责）。
CREATE TABLE IF NOT EXISTS gateway_binding_audit (
  id BIGSERIAL PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  customer_id TEXT NOT NULL,
  previous_customer_id TEXT,
  revision BIGINT NOT NULL DEFAULT 1,
  requested_by TEXT NOT NULL DEFAULT '',
  at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_binding_audit_gateway ON gateway_binding_audit (gateway_id);

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

-- 通用后台任务（中心本地作业：入队 → 串行 worker 执行 → 查询）。
-- payload 存整条 JobRecord（含业务载荷 / 结果 / 进度 / 失败原因）；
-- kind / queue / state / priority 单独成列，供认领、过滤与索引。
CREATE TABLE IF NOT EXISTS jobs (
  job_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  queue TEXT NOT NULL,
  -- 业务主体（如 release 的 component），供通用读面按主体过滤。
  subject TEXT,
  state TEXT NOT NULL,
  priority INT NOT NULL DEFAULT 0,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_jobs_claim
  ON jobs (queue, state, priority DESC, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_recent
  ON jobs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_subject
  ON jobs (queue, subject, created_at DESC);
-- 保留期清理：终态任务按 finished_at 删除。
CREATE INDEX IF NOT EXISTS idx_jobs_cleanup
  ON jobs (queue, state, finished_at);
-- 老库补列（终态时间 / 业务主体）。
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS finished_at TIMESTAMPTZ;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS subject TEXT;
-- 补列后回填历史终态任务的结束时间。
UPDATE jobs SET finished_at = (payload->>'finished_at')::timestamptz
  WHERE finished_at IS NULL AND payload->>'finished_at' IS NOT NULL;
-- 回填 release 任务的主体（老行没有 subject 列）。
UPDATE jobs SET subject = payload->'payload'->>'component'
  WHERE subject IS NULL AND queue = 'release-download'
    AND payload->'payload'->>'component' IS NOT NULL;

-- 规则发布命令队列（WarpStation → Center wparse-proxy → gwlinkd → 本机 wparse）。
CREATE TABLE IF NOT EXISTS gateway_commands (
  command_id TEXT PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  -- 命令类型：`proxy`（wparse 管理面转发，缺省）/ `diagnose`（本机体检）。
  kind TEXT NOT NULL DEFAULT 'proxy',
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  body TEXT,
  state TEXT NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  lease_expires_at TIMESTAMPTZ,
  response_status INT,
  response_body TEXT,
  error TEXT,
  -- 任务执行记录（失败时才带）：任务 ID + 网关本机目录 + 有界摘要（写入时已脱敏）。
  task_id TEXT,
  log_dir TEXT,
  log_excerpt TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_gateway_commands_pending
  ON gateway_commands (gateway_id, state, created_at);
-- 老库补列（0.19.3 新增；0.19.4 补 task_id）：gwlinkd 失败时把任务日志
-- 「任务 ID + 目录 + 摘要」一并回传。
ALTER TABLE gateway_commands ADD COLUMN IF NOT EXISTS task_id TEXT;
ALTER TABLE gateway_commands ADD COLUMN IF NOT EXISTS log_dir TEXT;
ALTER TABLE gateway_commands ADD COLUMN IF NOT EXISTS log_excerpt TEXT;
-- 老库补列（0.19.6 新增）：控制类命令 kind（`proxy` / `diagnose`）。
ALTER TABLE gateway_commands ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'proxy';

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

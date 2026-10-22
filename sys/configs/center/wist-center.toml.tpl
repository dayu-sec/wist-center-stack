# wist-center 运行配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/center/wist-center.toml.tpl）
# dst: configs/center/wist-center.toml（sys/docker-compose.yml 只把这个文件只读挂到容器 /wist-center）
# 渲染值：configs/center/wist-center.value.json（scripts/init-center.sh 生成）
#
# **两份配置**（对齐 foundation/config-and-state-layout §5）：
#   本模板渲染出**主配置**（R，可重渲的交付物）—— 只放「随部署环境渲染」的项；
#   **站点现场事实**（`[server] public_url`）在**现场态**（S），且按「声明 / 值」分开：
#   声明 `identity/center/wist-center-pub.toml` 只写 `${VAR}`（由 **tpl 渲染**，重渲也动不到现场），
#   值在同目录 `.env`（`scripts/init-center-pub.sh` 按缺补齐，**永不重渲**）；compose 用
#   `WIST_CENTER_PUB_CONFIG` 指过去。中心启动时读**两份**并合并：
#   段可重合，**叶子键不许重复**（重复即拒启）—— 所以这里**不写** public_url。
#
# 键与 `wist-center/wist-center.toml`（init-config 模板）保持一致（同样不含 public_url）。
# 两处与容器强相关：
#   - listen_addr 必须是 0.0.0.0:3100（代码默认 127.0.0.1:3100，端口映射不进来）；
#   - admin_token / hmac_secret 写 `${SEC_*}` 占位：由中心加载时从**密钥文件**解析
#     （`WIST_CENTER_SEC_FILE` 指向的 `<栈根>/.wist/sec-value.yml`，键 center_admin_token /
#     center_hmac_secret），明文不落盘、不入库。
[server]
listen_addr = "0.0.0.0:3100"
# 管理面**独立 listener**（容器内 3102，宿主只绑回环，浏览器经 web 反代）：
#   · 只挂 `/api/v1/admin/**` + `/api/v1/version`；
#   · 网关面（上面的 `listen_addr`）只挂 `/api/v1/gateway/**` + `/api/v1/version`；
#   · 两侧路由**互斥** —— 管理面永远不在公网 listener 上，即使 admin token 泄露也打不到。
# 删掉本项 = 回退到旧行为（两者共用 `listen_addr`）。
admin_addr = "0.0.0.0:3102"
# 中心对外地址（public_url）**不在这里**：它是**站点现场事实**（现场态），声明写在栈根
# `identity/center/wist-center-pub.toml`（只写 `${VAR}`、由 **tpl 渲染**，可随版本重渲），
# 值在同目录 `.env`（scripts/init-center-pub.sh 按缺补齐，取 **API_WGC_DOMAIN**，**永不重渲**）；
# compose 用 WIST_CENTER_PUB_CONFIG 指过去。必须落在控制中心服务器证书的 SAN 内。
# 网关 ↔ 中心 wire 协议版本（写入网关 config.toml 的 [protocol] version）。
protocol_version = "1.0"
# 管理面 token：由密钥文件提供（`${SEC_CENTER_ADMIN_TOKEN}` ← .wist/sec-value.yml 的 center_admin_token）。
admin_token = "${SEC_CENTER_ADMIN_TOKEN}"

[store]
# 有值 → PostgreSQL（PgStore）；留空 → 本地 JSON 文件存储（store_path）。
database_url = "{{database_url}}"
# JSON 文件存储路径（database_url 有值时不用）；相对路径按本文件所在目录（容器 /wist-center）解析。
store_path = "{{store_path}}"

[telemetry]
# 有值 → 每次状态上报额外推送指标到 VictoriaMetrics；留空 → 不推送（仅存快照）。
victoriametrics_url = "{{victoriametrics_url}}"

[security]
# RegistToken 派生密钥（HMAC-SHA256）：由密钥文件提供（`${SEC_CENTER_HMAC_SECRET}` ← .wist/sec-value.yml 的 center_hmac_secret）。
# 轮换该密钥不影响既有凭据：中心只存派生结果，不重算。
hmac_secret = "${SEC_CENTER_HMAC_SECRET}"
# 运行期凭据（RUNTIME_TOKEN）有效期秒数，默认 30 天。
credential_ttl_seconds = 2592000
# 控制中心 CA 证书（分发给网关作 control_center.trust_bundle）。
# 由 scripts/init-center.sh 现场生成；文件不存在 → 不提供信任根。
ca_cert_path = "{{ca_cert_path}}"

[artifacts]
# 版本发布制品落盘目录（未启用对象存储时）；相对路径按本文件所在目录（容器 /wist-center）解析。
dir = "{{artifact_dir}}"
# 生成网关安装命令时使用的镜像名。
gateway_image = "{{gateway_image}}"
# 云对象存储（S3 兼容，可选）：四项齐全才启用，否则用上面的 dir 落本地。
object_storage_endpoint = ""
object_storage_bucket = ""
object_storage_access_key = ""
object_storage_secret_key = ""

# 安装包来源：录入页按**版本号**拼 GitHub Release 地址 / COS 路径，再做 URL 探活。
# GitHub 与 COS 可同时配；只配一个时另一个仍可手工粘贴地址。只写位置，不写凭据。
[packages]

[[packages.sources]]
component = "wist-agentd"
github_repo = "dayu-sec/wist-agentd"
cos_bucket = "github-1347593047"
cos_prefix = "wist-agentd"
cos_region = "ap-hongkong"

[[packages.sources]]
component = "wist-gateway-stack"
github_repo = "dayu-sec/wist-gateway-stack"
cos_bucket = "github-1347593047"
cos_prefix = "wist-gateway-stack"
cos_region = "ap-hongkong"

[[packages.sources]]
component = "wist-gwlinkd"
github_repo = "dayu-sec/wist-gwlinkd"
cos_bucket = "github-1347593047"
cos_prefix = "wist-gwlinkd"
cos_region = "ap-hongkong"

[[packages.sources]]
component = "galaxy-ops"
github_repo = "galaxio-labs/galaxy-ops"

[[packages.sources]]
component = "galaxy-flow"
github_repo = "galaxio-labs/galaxy-flow"

[[packages.sources]]
component = "wist-knowledge"
github_repo = "dayu-sec/wist-knowledge"
cos_bucket = "github-1347593047"
cos_prefix = "wist-knowledge"
cos_region = "ap-hongkong"

# 规则 / 配置发布入口（wparse-rules / wparse-infra）。
# tag 列表只读；发布复用 [wparse_proxy] 的命令队列（gwlinkd relay 原样执行）。
# 两个 repo 的 URL 来自 vars 的 WP_RULES_REPO_URL / WP_INFRA_REPO_URL；
# 只配了一个 / 都没配时 `enabled = false`，不渲染 repo 段，也不要求 SEC token。
[wparse_release]
{{#if wparse_release_enabled}}
enabled = true
{{else}}
enabled = false
{{/if}}
tag_cache_seconds = 60
allow_manual_tag = false
max_targets = 20

{{#if wparse_release_enabled}}
[[wparse_release.repos]]
name = "wparse-rules"
group = "models"
provider = "cnb"
repo = "{{wp_rules_repo}}"
# 复用 Git 读 token；CNB 访问令牌需 repo-release:r（缺该 scope 时 tag 列表会 401/403）。
token = "${SEC_WP_GIT_PUB_TOKEN}"
tags_limit = 100

[[wparse_release.repos]]
name = "wparse-infra"
group = "infra"
provider = "cnb"
repo = "{{wp_infra_repo}}"
token = "${SEC_WP_GIT_PUB_TOKEN}"
tags_limit = 100
{{/if}}

[enrollment]
# 启动时写入 store（仅缺失时写入）的网关种子凭据，每项 `gateway_id:token`。
gateway_credentials = []

# 规则发布兼容入口（设备面）：独立 HTTPS listener + 命令队列。
# TLS 复用上面的 server cert/key（WARP_INSIGHT_CENTER_SERVER_{CERT,KEY}_PATH）；
# 设备 Token 是 Center 签发的 proxy token（管理面
# `POST /api/v1/admin/gateways/{gateway_id}/wparse-proxy-token`），不是网关 mTLS 证书。
# 需要 `[store].database_url`；FileStore 模式下自动禁用。
[wparse_proxy]
enabled = true
listen_addr = "0.0.0.0:3101"

# 本进程自己的运行日志（env_logger，走 log facade）。
# 落文件（相对本配置目录解析 → 已挂载的 /wist-center/logs/，自动建父目录），写满自轮转。
# 注意：给了 `file` 就**不再**写 stderr（`docker logs` 看不到中心自身日志；打开失败会回落 stderr）。
# `RUST_LOG` 环境变量仍优先于 `level`。
[log]
level  = "info"   # 或 "wist_center=debug,hyper=warn"
format = "text"   # 或 "json"（结构化行，便于日志采集）
file            = "logs/wist-center.log"
max_bytes       = 67108864   # 单文件上限（字节，写满轮转成 .1/.2/…；缺省 64 MiB）
keep_files      = 4          # 保留分卷数（0 = 不留历史；缺省 4）
max_seconds     = 604800     # 分卷保留时长（秒，0 = 不按时间清；缺省 7 天）

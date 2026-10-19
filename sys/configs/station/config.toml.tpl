# WarpStation 运行配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/station/config.toml.tpl）
# dst: configs/station/config.toml（compose 只把这个文件只读挂到容器 /app/config/config.toml）
# 渲染值：configs/station/station.value.json（scripts/init-station.sh 生成）
#
# 版本化策略（设计文档 §9.2）：
#   · **git-only**：WarpStation 用本地 git 命令 commit/push/tag 到外部 Git 私有仓库；
#     不调用任何 Git 服务 API。`[gitea]` 段只是上游配置项，作为 git 凭据的载体保留：
#     base_url 填 Git 服务基址，username/password 用于 HTTPS push。
#   · 两个工作区由 scripts/init-station.sh 预克隆（.git 已存在时 WarpStation 跳过 init_gitea_repo）。
#   · Gateway 拉取走 Center Git Proxy（见 configs/git-proxy/nginx.conf），不直接访问上游 Git。
#
# 密钥策略：
#   · PostgreSQL 密码由渲染值写入本文件（运行时才生成，随 configs/ 备份；文件权限 640）；
#   · Git 写 token 走 compose env_file（configs/station/station.env，
#     WP_STATION__GITEA__PASSWORD），生成时带字母前缀，避免 config crate 的 try_parsing
#     把纯数字字符串当整数。
#
# v0.2.14 的仓库布局是固定约定（相对工作目录）：
#   gitea/wparse__models、gitea/wparse__infra
#   gitea/wfusion__models、gitea/wfusion__infra
# 不再通过 project_models / project_infra 配置项指定。

[log]
# Console → docker logs；需要落文件时改成 File 并把 output_path 指到持久化目录。
level = "{{log_level}}"
output = "Console"
output_path = "./logs/"

[web]
# 容器内端口是应用契约（compose 固定映射 ${STATION_PORT}:8081）。
host = "0.0.0.0"
port = 8081

# 与 wist-center 共用同一个 PostgreSQL 实例，但使用独立库/独立账号：
# station_app 只对 wp-station 有 CONNECT（scripts/db-init.sh 创建并收紧权限）。
[database]
host = "postgres"
port = 5432
name = "{{station_db_name}}"
username = "{{pg_user}}"
password = "{{pg_password}}"
max_connections = 10
min_connections = 2
connect_timeout = 30
idle_timeout = 600
ssl_mode = "disable"

# 上游配置项（git 凭据载体）。base_url 只是占位，WarpStation 不调用它的 API。
# repo_startup_strategy = "local"：预克隆的本地工作副本优先，避免启动时被远端覆盖。
# password 由 env_file 覆盖（WP_STATION__GITEA__PASSWORD = Git 写 token）。
[gitea]
base_url = "{{gitea_base_url}}"
username = "{{gitea_username}}"
password = ""
repo_startup_strategy = "local"

# AI/人工辅助任务（可选）。留空 = 不启用。
[assist]
base_url = ""

# 设备管理接口（v0.2.14 起为必填字段）。
# WarpStation 发布时调 Center wparse-proxy（HTTPS），信任根 = 中心 CA。
# 设备 Token / 轮询节奏由 WarpStation 设备记录驱动；这里只给默认值。
[admin_api]
enabled = true
ca_file = "/app/tls/CA.crt"
poll_interval_seconds = 5
poll_timeout_seconds = 300
max_retries = 60

# 数据采集/监控跳转地址（可选）。留空 = 不显示相关入口。
[features]
data_collect_url = ""

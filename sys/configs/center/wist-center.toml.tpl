# wist-center 运行配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/center/wist-center.toml.tpl）
# dst: configs/center/wist-center.toml（sys/docker-compose.yml 把 configs/center 挂到容器 /wist-center）
# 渲染值：configs/center/wist-center.value.json（scripts/init-center.sh 生成）
#
# 与 `wist-center/wist-center.toml`（init-config 模板）键名完全一致。
# 两处与容器强相关：
#   - listen_addr 必须是 0.0.0.0:3100（代码默认 127.0.0.1:3100，端口映射不进来）；
#   - admin_token / hmac_secret 引用**容器环境变量**，由 compose 从 gops 密钥（${SEC_xxx}）注入，
#     明文不落盘、不入库。
[server]
listen_addr = "0.0.0.0:3100"
# 中心对外地址：用于生成网关初始化 URL，必须落在控制中心服务器证书的 SAN 内。
public_url = "{{public_url}}"
# 网关 ↔ 中心 wire 协议版本（写入网关 config.toml 的 [protocol] version）。
protocol_version = "1.0"
# 管理面 token：由容器环境变量提供（compose 从 ${SEC_CENTER_ADMIN_TOKEN} 注入）。
admin_token = "${WIST_CENTER_ADMIN_TOKEN}"

[store]
# 有值 → PostgreSQL（PgStore）；留空 → 本地 JSON 文件存储（store_path）。
database_url = "{{database_url}}"
# JSON 文件存储路径（database_url 有值时不用）；相对路径按本文件所在目录（容器 /wist-center）解析。
store_path = "{{store_path}}"

[telemetry]
# 有值 → 每次状态上报额外推送指标到 VictoriaMetrics；留空 → 不推送（仅存快照）。
victoriametrics_url = "{{victoriametrics_url}}"

[security]
# RegistToken 派生密钥（HMAC-SHA256）：由容器环境变量提供（compose 从 ${SEC_CENTER_HMAC_SECRET} 注入）。
# 轮换该密钥不影响既有凭据：中心只存派生结果，不重算。
hmac_secret = "${WIST_CENTER_HMAC_SECRET}"
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

[enrollment]
# 启动时写入 store（仅缺失时写入）的网关种子凭据，每项 `gateway_id:token`。
gateway_credentials = []

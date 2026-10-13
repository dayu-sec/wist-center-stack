# Changelog

本仓是 `wist-center`（中心后端）+ `wist-center-web`（管理前端）的一站式编排。
版本以仓库根 `version.txt` 为权威，标签 `v<version>-<channel>`。

## [0.1.4-alpha] - 2026-10-13

### 变更

- **发布时可选把制品推送到腾讯云 COS**：打 tag 时新增 `upload-cos` job，把
  `wist-center-stack-<tag>.tar.gz` 上传到 `cos://<桶>/wist-center-stack/<tag>/` 与
  `.../latest/`（未配置 `COS_BUCKET` 时自动跳过，不影响发布）。

## [0.1.3-alpha] - 2026-10-13

### 变更

- **内部依赖包跟进：`GATEWAY_IMAGE` → `ghcr.io/dayu-sec/wist-gateway:v0.9.1-alpha`**
  （生成网关安装命令时写进中心 `[artifacts] gateway_image` 的镜像）。

## [0.1.2-alpha] - 2026-10-13

### Changed

- **`wist-center` 配置分层（三文件 recipe，对齐 `foundation/layered-config-recipe.md`）**：站点事实
  `[server] public_url` 从主配置搬到**现场态**，按「声明 / 值」分开：
  - **声明** `wist-center-pub.toml`（只写 `${VAR}` 引用、**不含值**）—— 由
    `sys/configs/center/wist-center-pub.toml.tpl` 经 `gx.tpl` 渲染到 `identity/center/wist-center-pub.toml`
    （交付物，随版本重渲；值不在这里，所以重渲动不到现场）；
  - **值** `identity/center/.env` —— 由 `scripts/init-center-pub.sh` 按缺补齐（`CENTER_PUBLIC_URL`）、永不重渲。
  加载走共享 crate **`wist-config`**（`LayerSpec` + `load_layered_toml`）：「进程环境 > 同目录 `.env`」插值
  `${VAR}` → 与主配置**无重复叶子**合并；未定义且无默认 → 拒启。`wist-center.toml` 模板与
  `examples/local-dev.toml` 去掉 `public_url`；`init-config` 一并写出声明 + `.env` 骨架；compose 用
  `WIST_CENTER_PUB_CONFIG=/wist-center/ca/wist-center-pub.toml` 指过去。env `WARP_INSIGHT_CENTER_PUBLIC_URL`
  （含 dev 态）仍可覆盖。迁移：旧现场主配置里若仍有 `public_url`，与声明撞键会拒启 → `gops sys localize`
  重渲一次主配置即可。

- **文件组织对齐 `foundation/config-and-state-layout`**：站点身份（CA 证书 / CA 私钥 / 服务器证书 /
  服务器私钥 / CA 序列号）从 `configs/center/ca/` **物理拆出**到栈根 **`identity/center/`**，并在
  `sys-prj.yml` 整体声明为**对外契约**（`contract: - identity`）。`contract` 自足即「不覆盖 + 必收 +
  不进包」，于是身份不再落 `backup`（旧形态是 `backup: configs/center/ca`）—— 契约归档因此可**独立
  复原站点身份**（换机不必换锚 / 换 ID）；`configs/` 里只剩可重渲 / 可重建的渲染物、store、logs。
  同步：compose 增加 `./identity/center → /wist-center/ca`（只读）挂载（模板 `ca_cert_path` 容器路径不变）；
  `scripts/{init-center,gen-center-ca,align-host-perms}.sh` 的落点 / 权限改为 `identity/center`；`.gitignore`
  新增忽略 `/identity/`；README「目录 / 数据目录 / localize 流程 / 挂载文件 / 权限」同步更新。

  > 既有现场迁移（CA 不变 ⇒ 网关无感，只是文件位置搬动）：
  > `mkdir -p identity/center && mv configs/center/ca/* identity/center/ && rmdir configs/center/ca`，
  > 然后 `gops sys localize` —— 它①补权限对齐、②重渲主配置（去掉 `public_url`）、③渲现场态声明
  > `identity/center/wist-center-pub.toml` 并按缺补齐 `identity/center/.env`。**必须重渲**：旧渲染的
  > 主配置仍带 `public_url`，与新的现场态同键会让中心**拒启**（fail-closed，属主唯一）。

- **镜像 tag 跟进**：中心 `v0.12.0-alpha`（去掉 `~/.wist-center/` 默认，修容器 `$HOME` 不可写的启动崩溃；
  含此前的配置分层：站点事实 `public_url` 归现场态，升级需重渲主配置；另有公开 `GET /api/v1/version`）；
  前端 `v0.4.0-alpha`（左下角新增前后端版本块：前端版本 = 发布 tag 注入，
  后端版本读公开 `GET /api/v1/version`）；`GATEWAY_IMAGE` 默认值同步到 `v0.9.0-alpha`（与
  `wist-gateway-stack` 当前钉的网关版本对齐 —— 这是中心生成「网关安装命令」时写进
  `wist-center.toml` 的 `[artifacts] gateway_image` 默认值，现场仍可按实际网关栈镜像覆盖）。
- **前端 `web` 容器自己终止 TLS**：nginx 从容器内 **80 明文** 改为 **443 HTTPS**（宿主仍发布到 `${WEB_PORT}`，默认 18080），
  证书 = 站点身份 `identity/center/control-center-server.{crt,key}`（由站点 CA 签、SAN 覆盖 `CENTER_DOMAIN`）；
  新增 `scripts/ensure-center-server-cert.sh`（幂等：SAN 覆盖就不重签，换域名/加 SAN 只重签**叶**、CA 不动）。
  于是**不再需要**外部反代即可 `https://<CENTER_DOMAIN>:${WEB_PORT}`。
- **`sys-prj.yml` 跟进 gops 2.3.0**：`preserve:` 更名为 `protect:`；`backup:` 由分级 `{restore, rebuild}`
  改为**扁平列表**（旧形态在 2.3 下已无法加载，`gops sys localize` 直接报错）。`artifacts/`
  属可重投的“可重建”，不再入表。路径与语义不变。
- **中心凭据从配置里拆出，走密钥文件**：模板 `sys/configs/center/wist-center.toml.tpl` 的
  `admin_token` / `hmac_secret` 不再走容器环境变量注入，改写 `${SEC_CENTER_ADMIN_TOKEN}` /
  `${SEC_CENTER_HMAC_SECRET}`；值落**栈根 `.wist/sec-value.yml`**（键 `center_admin_token` /
  `center_hmac_secret`，`scripts/init-center.sh` 缺则生成、键级补齐），compose 把 `.wist/` 只读挂进
  center 容器并 `WIST_CENTER_SEC_FILE=/secrets/sec-value.yml`，中心加载时用 orion-sec 解析。
  `.wist/` 已 `.gitignore`。（中心侧见 `wist-center` 的 orion-sec 接入。）
- dev 态同步：`dev/svc.sh` / `dev/lib.sh` 把 `init-config` 生成的**字面** token/secret 迁到
  `<栈根>/.wist/sec-value.yml`，配置改写为 `${SEC_CENTER_*}`，启动时导出 `WIST_CENTER_SEC_FILE`；
  `./dev/svc.sh token` 改从密钥文件读。
- **开发态不再用 `~/.wist-center/`，且与发布态共用 `identity/center/`**：dev 的配置/本地叶证书落
  **栈内** `<栈>/dev/configs/center/`；**站点身份**（CA 信任根 + CA-G）改用发布态的 `identity/center/`
  （dev 用共享 CA 签**自己的**叶证书、CA-G 也是同一把）—— 同一站、同一信任根。旧 `~/.wist-center/` 可删。
- **需 `wist-center >= 0.12.0-alpha`**（配套）：中心去掉 `~/.wist-center/` 默认、CA 路径改以**配置目录**
  为基准（见 wist-center CHANGELOG）。发布态 **CA-G** 落 `identity/center/` 并由容器**只读加载**
  （`load_or_create` 存在即读、不写），修掉「容器 `$HOME` 不可写 → `failed to create
  /home/wist/.wist-center/ca`」的启动崩溃。**旧现场升级**：把已生成的 `gateway-client-ca.{pem,key.pem}`
  先搬进 `identity/center/` —— 缺失会被重新生成，但那会**换 CA**、使已签发的网关客户端证书全部失效
  （只能换 `gateway_id` 重入网）。

### Added

- **中心后端开服务端 TLS + 校网关客户端证书（mTLS）**：compose 给 `center` 服务配
  `WARP_INSIGHT_CENTER_SERVER_CERT_PATH` / `WARP_INSIGHT_CENTER_SERVER_KEY_PATH`（挂在只读的
  `/wist-center/ca` = 站点身份 `identity/center/`）→ 中心在容器 3100 上起 **HTTPS**，客户端证书
  **可选**（首注册网关还没有证书；无证书不等于未鉴权，应用层再判）。网关**直连 3100** 走 mTLS；
  `web` 容器 `/api` 上游随之由 `http://center:3100` 改为 `https://center:3100`（`proxy_ssl_verify off`
  —— 容器内同一份只读挂载身份）。**之前**中心自身不做 TLS，网关的 mTLS 客户端证书**无处可验**。

### Fixed

- **中心服务器叶证书缺扩展 + 有效期过长（Apple 平台校验器直接拒）**：`scripts/ensure-center-server-cert.sh`
  与 `scripts/gen-center-ca.sh` 签叶时**只写 `subjectAltName`**，缺 `extendedKeyUsage=serverAuth` /
  `basicConstraints` / `keyUsage`，且有效期默认 3650 天。macOS 上的网关（rustls/reqwest →
  `rustls_platform_verifier` / Apple Security）会拒：缺 EKU → `Invalid Extended Key Usage for policy`；
  > 398 天 → `CSSMERR_TP_CERT_SUSPENDED`。现补齐三扩展，并把**叶证书**有效期默认收到 **397 天**
  （CA/根不受此限，仍 3650；`dev/lib.sh` 的本地叶证书同步 `825 → 397`）。

## [0.1.2-alpha] - 2026-10-06

### Changed

- **制品镜像独立目录**：版本发布下载/镜像下来的安装包从 `configs/center/artifacts/` 挪到**栈根 `artifacts/`**
  —— 发布态由 compose 挂到容器 `/wist-center/artifacts`（模板里 `[artifacts] dir = "artifacts"` 不变）；
  开发态也落 `<栈根>/artifacts`（不再跟着可随手清掉的 `.run/`）。新变量 `CENTER_ARTIFACT_DIR`（默认 `./artifacts`）。
  `configs/` 于是只剩配置与密钥。
- **备份分级**：`sys-prj.yml` 把 `artifacts` 列入 `ignore` / `preserve`，并在 `backup` 的 **`rebuild`** 档收
  —— 制品是「从来源地址镜像来的、可重新录入」的数据，与不可再生的身份材料（`restore` 档）分开；
  要纳入默认备份就把它挪到 `restore` 档。
- `scripts/{init-center,align-host-perms}.sh`、`.gitignore`、README「数据目录」同步（权限对齐现在也覆盖 `artifacts/`）。
- **修复 schema 不同源**：`sys/db/initdb/01_schema.sql` 落后于 `wist-center/docker/initdb/01_schema.sql`，
  缺 `gateways.public_base_url` 与 `release_records.package_sha256`（版本发布落库直接 `SQL` 错）。已同步两份。
- **dev 起 deps 时幂等套一遍 schema**：`dev/svc.sh start deps` 在 PG 就绪后把 `01_schema.sql`
  重新应用一次（文件全是 `CREATE/ALTER … IF NOT EXISTS`）—— 因为 `docker-entrypoint-initdb.d`
  **只在空 data 卷首次初始化时跑**，之后 schema 新增列到不了已有库。
- **发布态同样补上**：compose 加一个一次性 `db-schema` 服务（`postgres` 镜像跑 `psql -f 01_schema.sql`），
  `center` 依赖它 `service_completed_successfully` —— `gops run start`（`docker compose up -d`）
  每次都会先幂等套一遍 schema，应用失败则中心不起。

## [0.1.1-alpha] - 2026-10-05

### Changed

- **镜像 tag 跟进**：中心 `v0.5.0-alpha`、前端 `v0.1.5-alpha`；网关安装镜像 `v0.1.19-alpha`。
- 同步 `sys/db/initdb/01_schema.sql`：`gateways` 表补网关状态**富化列**（机队 / 存储 / 数据面 /
  主机资源），与 `wist-center` 0.5.0-alpha 同源。

## [0.1.0] - 2026-10-04

### Changed

- **转为 gops 系统项目**，目录结构对齐 `wist-gateway-stack`：
  - 发布态编排移入 `sys/docker-compose.yml`（`sys/sys_model.yml` 标 `kind: docker-compose`），
    起停走 `gops run`；
  - 变量定义 `sys/setting/vars.yml`，现场覆盖 `values/value.yml`，`gops sys localize` 生效；
  - 开发态脚本移入 `dev/`（原 `sysrun/`）。
- `sys/configs/{center,web}` 放渲染模板，`scripts/` 放幂等初始化脚本（localize 阶段执行）。

### Added

- 发布态 `center` / `web` 服务（镜像 `ghcr.io/dayu-sec/wist-center`、
  `ghcr.io/dayu-sec/wist-center-web`），与 `postgres` / `victoria-metrics` 同栈编排。
  `center`/`web` 的镜像此前未就绪，本版起可用于发布态。

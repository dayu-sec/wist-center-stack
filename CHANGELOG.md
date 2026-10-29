# Changelog

本仓是 `wist-center`（中心后端）+ `wist-center-web`（管理前端）的一站式编排。
版本以仓库根 `version.txt` 为权威，标签 `v<version>-<channel>`。

## [0.8.1-alpha] - 2026-10-30

### 变更（组件跟版：安装流程走新中心）

| 变量 | 旧 | 新 |
|---|---|---|
| `CENTER_IMAGE_TAG` | `v0.24.1-alpha` | **`v0.25.0-alpha`** |

带来的能力：网关「全量安装」改为 clone 部署工程（不再是 `gops prj new`），
`GATEWAY_PRJ_TPL_REPO` 真正生效；安装材料不全时 503 会点名缺哪个组件。

> 现场升级：`gops prj upgrade`（或栈目录 `git pull` + `gops sys localize`）拉本栈后重建
> `center`；若现场在 `.env` / `sys_value.yml` 里覆盖了 `CENTER_IMAGE_TAG`，需同步改掉（覆盖值优先）。

## [0.8.0-alpha] - 2026-10-30

### 新增

- **`GATEWAY_PRJ_TPL_REPO`**：网关部署工程（ops-prj）模板仓库。中心生成的「网关全量安装」命令
  clone 它来落工程（替代 `gops prj new`），默认
  `https://wgc-git.beta.jingang.cloud/gateway-tx.git`；渲染进 `wist-center.toml` 的
  `[artifacts] gateway_project_repo`。现场换仓库：在 ops-prj 的
  `values/<系统名>/sys_value.yml` 覆盖本项，`gops sys localize` 即生效。
- 网关安装的前置依赖多了 `git`（「环境准备」脚本会自动补装）。

### 升级注意

- 该变量需 **`wist-center >= 0.25.0-alpha`** 才生效：旧版中心不认识 `[artifacts] gateway_project_repo`，
  仍用内置默认地址（当前两者相同，所以**不冲突**）。中心镜像已在 `0.8.1-alpha` 抬到
  `v0.25.0-alpha`。

## [0.7.1-alpha] - 2026-10-29

### 变更（组件跟版：兼容性检查与展示）

三个镜像 tag 跟到对应仓库当前发布版（`sys/setting/vars.yml` 改，`gops sys update` 重新生成
`sys/merged_vars.yml`）：

| 变量 | 旧 | 新 |
|---|---|---|
| `CENTER_IMAGE_TAG` | `v0.23.0-alpha` | **`v0.24.1-alpha`** |
| `CENTER_WEB_IMAGE_TAG` | `v0.20.0-alpha` | **`v0.21.0-alpha`** |
| `GATEWAY_IMAGE` | `…/wist-gateway:v0.17.0-alpha` | **`v0.27.0-alpha`** |

带来的能力：中心发布 / 建计划 / 批准计划按包内 `compat.json` 做升级兼容检查（`409 release_incompatible` /
`rollout_target_incompatible`），包管理页展示「兼容范围 + 检查结果」；中心生成的网关安装命令指向当前网关版。

> 现场升级：`gops prj upgrade` 拉本栈后重建 `center` / `center-web`；现场若在 `.env` 里覆盖了上述
> 变量，需同步改掉（覆盖值优先于产品默认）。

## [0.7.0-alpha] - 2026-10-29

### 变更（需检查现场 values）

- **产品默认值不再绑定客户仓库地址**：`WP_RULES_REPO_URL` / `WP_INFRA_REPO_URL` 的默认值改为**空**
  （此前写死 `https://cnb.cool/dy-sec/jingang-cust/wist/wp-rules|wp-infra`）。模板从此不含任何
  客户 / 仓库路径，换客户不必改本仓。
  - 两项都留空时中心**照常启动**：`[wparse_release] enabled = false`（发布页没有 ④/⑤），
    Git Proxy 白名单为空（拒绝一切 git 请求，网关 `project_remote` 拉不到规则）；
  - `scripts/init-center.sh` / `scripts/init-git-proxy-conf.sh` 会打印一行提示（不阻断 localize）；
  - **升级注意**：老现场若一直靠默认值（values 里没写这两项），升级后会被置空 ——
    升级前先在 `values/<系统名>/sys_value.yml` 里显式写上两个 URL。

## [0.6.0-alpha] - 2026-10-28

### 新增

- **Git Proxy 支持双向证书（mTLS）**：`GIT_PROXY_CLIENT_CERT_VERIFY=off|optional|on`（默认 `off`）。
  网关的客户端证书直接复用 CA-G（与中心网关面同一套 per-gateway 身份），中心侧只挂 CA-G 的
  **公钥证书**；access log 新增 `verify=`，建议先 `optional` 观测覆盖率再切 `on`。
  注：网关侧要让 wparse 把证书交出去需上游支持（wp-labs/warp-parse#371），在此之前停在
  `optional` 是安全的（不拦流量）。
- **Git Proxy 可用独立域名**：`GIT_PROXY_DOMAIN`（默认空 = 沿用 `API_WGC_DOMAIN`），并**自动加入
  服务器证书 SAN** —— 网关可改用 `https://wp-git.<zone>/...` 拉取；配合主机第二个 IP 与 443
  即可去掉端口（证书复用同一张叶，CA 不动，网关无需重入网）。
- **Git Proxy 短路径**：`GIT_PROXY_SHORT_PREFIX`（留空 = 自动取两个仓库 URL 的公共上级目录，
  `off` 关闭）让 `https://<wp-git>:<端口>/wp-infra` 等价于长路径。
  别名命中后 `rewrite ... last` 回到同一组全路径白名单 —— 端点限制 / 限流 / 上游凭据只有一份，
  白名单没有变宽（仍不是通用反代）。
  网关侧改用短地址的顺序：**先升 Center，再改 `WPARSE_PROJECT_*_REPO`**。
- **dev 也能起 Git Proxy**：`./dev/svc.sh start proxy`，复用发布态已渲染好的 `nginx.conf` 与站点证书。
- **补齐缺失的渲染脚本** `scripts/init-git-proxy-conf.sh`：此前 `git-proxy.value.json` 没有生成者
  （README 说“由脚本写入”但仓里没有），**全新的现场会在渲染阶段失败**。

### 变更（**破坏性**：需改现场 values）

- **两个变量改名**：`CENTER_BIND_IP` → **`CENTER_API_BIND_IP`**、`CENTER_HOST_PORT` →
  **`CENTER_API_HOST_PORT`**。center 有两个 listener（网关面 API / 管理面），旧名看不出是哪一面；
  改名后与既有的 `CENTER_ADMIN_BIND_IP` / `CENTER_ADMIN_HOST_PORT` 成对。
  - **升级必做**：把 `values/<系统名>/sys_value.yml` 里的旧键改名。
    **gops 对 values 里的未知键不报错**（只进 `.env`），不改会被静默忽略 →
    `BIND_IP` 回落到 `0.0.0.0`（扩大暴露面）、`HOST_PORT` 回落到 `3100`（alpha 上网关连不上中心）。
  - **已加守卫**：`scripts/check-stack.sh` 发现旧键仍在环境里 → 退出码 2（FAIL），
    localize 末尾的 `--gate` 会阻断启动并打印改名指引。

## [0.5.6-alpha] - 2026-10-28

### 变更

- **中心后端跟版 `v0.23.0-alpha`**：从远程下载安装包不再挂在一次请求里 —— 发布端点只落一条
  持久化任务，worker 串行执行「取包 → 核对 sha256 → 镜像 → 落库」，带 `Prefer: respond-async`
  直接回 `202`。新增通用任务读面（`GET /api/v1/admin/jobs`）、仅排队中可取消、终态任务按
  `WIST_CENTER_JOB_RETENTION_DAYS`（默认 7 天）清理。中心重启时残留的「执行中」任务会自动
  排回队列。`/releases/*` 与 `/release-jobs/*` 的路径与回执形状不变。
- **管理前端跟版 `v0.20.0-alpha`**：
  - 新增「任务队列」页（`/jobs`）：能看到中心在忙什么、进度、失败原因，**排队中可取消**，
    有在飞任务时自动刷新。以前只在录入页按组件看得到下载任务。
  - 发布目标可以**逐台勾选**（升级安装 / Agent 包 / 知识库）：默认全选在线，可取消 / 加回，
    **选中的范围就是灰度切分的范围**（目标 0 台时禁止提交）。
- **`sys/db/initdb/01_schema.sql` 同步到中心 0.23.0**：补上之前落下的
  `gwlinkd_version`、`gateway_customer_bindings`、`gateway_binding_audit`，以及本次的 `jobs` 表
  （含 `subject` 列、认领 / 清理 / 主体索引与历史行回填）。

### 升级注意

- 两个镜像都换：`CENTER_IMAGE_TAG=v0.23.0-alpha`、`CENTER_WEB_IMAGE_TAG=v0.20.0-alpha`，
  然后 `gops run start`。
- 中心启动时会自己对库做一次幂等迁移（建表 / 补列 / 回填 `subject`）；**生产库若不给应用
  DDL 权限**，请先按 `sys/db/initdb/01_schema.sql` 手工跑一遍，否则 `jobs` 表不存在时
  发布与任务队列会直接报错。
- 任务保留期是环境变量：默认 7 天；`0` 或负数表示不清理（脏值也按不清理，不会回退默认）。

## [0.5.5-alpha] - 2026-10-27

### 变更

- **管理前端跟版 `v0.17.0-alpha`**（两个前端口径一起发，后端不动，仍是 `v0.22.2-alpha`）：
  - **发布执行记录支持归档 / 取消归档**：终结态（完成 / 失败 / 取消）的计划卡可收起进「已归档」分区，
    两个分区都带计数；执行中（draft / rolling）的计划不提供归档（避免把未批/未推完的计划藏起来）。
  - **安装包管理页新增组件快捷筛选**：「在用 / 已过期」之外再按组件收窄（胶囊带当前状态下的包数），
    选中的组件在当前状态下无包时给明确空态。

### 升级注意

- 只换前端镜像：站点 `.env` 的 `CENTER_WEB_IMAGE_TAG` 跟到 `v0.17.0-alpha` 后 `gops run start`。
- 归档是**标记**：中心只对终结态做归档，计划与逐目标条目全留；旧中心不提供 `archived_at` 时
  前端按“未归档”处理，不会报错。

## [0.5.4-alpha] - 2026-10-26

### 变更

- **管理前端跟版 `v0.15.0-alpha`**：与网关控制台统一视觉 —— 深色底改用深海军蓝 `#0a1220`、
  主色从靛蓝换为紫罗兰 `#8b5cf6`（favicon / 品牌蜂巢 / `theme-color` 同步）；
  右上角状态胶囊把“吃了示例数据”从“未设置 token”里拆出来，不再看起来像鉴权出错。

## [0.5.3-alpha] - 2026-10-25

### 变更

- **中心后端跟版 `v0.22.2-alpha`**，**管理前端跟版 `v0.14.1-alpha`**：
  - 绑定在数据面没生效时（网关回执 `wparse_applied=false`），把网关给的原因写进绑定记录，
    页面不再只显示「已下发」。
  - 网关详情页分四个分区 —— 概览 / 绑定客户 / **运行时控制** / 升级；
    每个分区是独立路由（`/gateways/:id/binding|runtime|upgrade`），刷新与分享都能回到同一分区。
  - 绑定客户页新增「**下发记录**」：命令 ID、队列状态（排队中 / 执行中 / 已完成 / 失败 / 过期）、
    回执状态、数据面是否真的生效、未生效原因，在飞时自动刷新。

### 升级注意

- 「重启 gwlinkd」需要 **`wist-gwlinkd ≥ 0.17.1-alpha`**：旧版在 macOS system 域下
  会静默失败（回执说已重启，进程其实是旧的）。

## [0.5.2-alpha] - 2026-10-25

### 变更

- **管理前端跟版 `v0.13.1-alpha`**：修复运行中的网关看不到「绑定客户」入口的问题 ——
  从网关列表点进来的详情页（`/gateways/:id`）现在同样展示绑定面板与当前绑定，
  不再只能从「接入材料」页操作。

## [0.5.1-alpha] - 2026-10-25

### 变更

- **中心后端跟版 `v0.22.0-alpha`**：网关可以绑定客户（业务身份），绑定状态（已下发 / 已生效 /
  漂移 / 失败）可见，并支持换绑审计；中心启动时自动补建相关表。
- **管理前端跟版 `v0.13.0-alpha`**：详情页展示当前绑定与换绑审计，漂移时有明确告警；
  绑定失败不再被当成成功。

### 升级注意

- 绑定能力需要 `wist-gwlinkd ≥ 0.17.0-alpha` 才能落到数据面；旧版会明确拒绝，页面显示未生效。
- 中心库会自动补表（`gateway_customer_bindings` / `gateway_binding_audit`）；若生产库不给应用 DDL 权限，
  请手工执行包内 `docker/initdb/01_schema.sql`。

## [Unreleased]

### 新增

- **栈级配置检查 `wist-stackcheck`**（`tools/stackcheck`，Rust lib + bin）：15 项只读判据，覆盖
  渲染新鲜度、占位值、两个域名、密钥/私钥权限、站点身份文件、证书 SAN、compose 挂载与 localize
  落点、现场态 `public_url`、PG 建表脚本、宿主端口、镜像可达。
  - `scripts/check-stack.sh`：按本机 triple 选预编译件；开发态回落 `cargo run`；找不到就退出 2。
  - `flow localize` 末尾加 `--gate` 守门（只拦阻断类 FAIL），新增 `flow diagnose` 把 `checks[]`
    追加到 `GOPS_DIAGNOSE_RESULT`。
  - 发布包按 triple 追加三份二进制（`bin/<triple>/wist-stackcheck`），仍是单包单地址。
- 判据按 `StackProfile` 参数化（路径/变量/挂载对都在 `tools/stackcheck/src/profile.rs`），
  与 `wist-gateway-stack` 的栈级检查方案同一套输出契约。

### 工程

- **通用引擎抽到公共仓 `wist-stack-tools/stackcheck-core`**（tag 固定）：Flow Result / CLI /
  渲染/密钥/挂载/端口/镜像/compose/x509 只有一份实现；本仓只保留 center profile、TLS 策略与薄 main。
  `tools/stackcheck/src/checks.rs` 从 2934 行降到 1311 行。

### 修复

- `scripts/init-center.sh` 把 `wist-center.value.json` 收紧到 **600**（含 DB 应用账号口令）；
  内容无变化的幂等分支也会修正既有 644 权限。
- 端口占用检查按 compose 的 `*_BIND_IP` 探测，并正确解析 `docker ps` 的**多行**输出
  （此前每行第一个映射会被静默漏掉，导致把本栈自己的端口误报成冲突）。
- 检查器边界收紧：长语法 compose 挂载只在**本条目**内找 `target`（不再把上一个的 target 配给下一个）；
  端口支持 `[::1]:…` 与行内 `ports: […]`；`.env` 存在但读不了时不再静默回落默认值；
  只有渲染产物、找不到值文件/模板时报 WARN（不报假绿）。

## [0.5.0-alpha] - 2026-10-22

### 组件

- **中心后端 `CENTER_IMAGE_TAG` → `v0.21.0-alpha`**：规则/配置发布纳入统一审批——
  `publish` 只建 `draft` 发布计划，批准后由中心经 wparse-proxy 入队，并把命令结果回填到计划条目。
- **中心前端 `CENTER_WEB_IMAGE_TAG` → `v0.12.0-alpha`**：④/⑤ `wparse-rules` / `wparse-infra` 改走计划审批；
  发布页按「运行时 / 内容与配置」分组；逐台执行反馈拆分「消息 / 日志路径」，详情与日志路径支持点击复制。
- 两个组件必须**成对升级**：`center-web 0.12` 依赖 `center ≥ 0.21`（旧中心返回 `targets` / `errors`，页面会报契约漂移）。

### 移除

- **取消对 WarpStation 的集成**：删除 `warp-station` / `warp-toolchain` 服务、`station-toolchain` 卷、
  `STATION_*` / `WARPPARSE_*` / `WEB_WGS_DOMAIN` 变量，以及 `scripts/init-station.sh`、
  `scripts/provision-station-device.sh`、`sys/configs/station/`、`sys/sandbox/`、`sys/station/default_configs/`。
- `db-init` 不再创建 `station_app` 角色与 `wp-station` 库；`web` 不再提供 `station.*` 虚拟主机与 basic auth。
- `sys-prj.yml` 移除 `knowledge/station` 的 ignore/protect/backup 与 `SEC_STATION_*` 注入。

### 保留

- Center 的 `[wparse_release]`（tag 列表）、`wparse-proxy`（`:3101`）、`git-proxy`（`:8443`）保持不变：
  规则/配置发布通道仍可独立使用，不依赖 WarpStation。

### 升级提示（手动清理，脚本不会自动删数据）

- 目录：`configs/station/`、`identity/station/`；`knowledge/station/`（含两个 Git 工作副本）按需保留或自行备份后删除。
- 容器/卷：`docker volume rm wp-station-toolchain`（容器由 `up -d --remove-orphans` 清理）。
- 数据库（如不再需要）：`DROP DATABASE "wp-station"; DROP ROLE station_app;`。
- `.wist/sec-value.yml` 中的 `station_db_password` / `station_web_password` / `wp_git_push_*` 可删除；
  `wp_git_pub_*` 仍被 Git Proxy 与 `[wparse_release]` 使用。

## [0.4.1-alpha] - 2026-10-22

### 修复

- **中心后端 `CENTER_IMAGE_TAG` → `v0.20.1-alpha`**：修复规则 / 配置发布时 tag 带 `v` 前缀导致的 500
  （wparse 的 `version` 字段期望版本号，Center 现在统一去掉前导 `v`）。

## [0.4.0-alpha] - 2026-10-22

### 变更

- **中心后端 `CENTER_IMAGE_TAG` → `v0.20.0-alpha`**：规则 / 配置发布入口（`wparse-rules` / `wparse-infra`）。
- **中心前端 `CENTER_WEB_IMAGE_TAG` → `v0.11.0-alpha`**：发布页新增两个入口，选 tag 后直接发布。

### 新增

- **Center 规则 / 配置发布入口**：`[wparse_release]` 由 `WP_RULES_REPO_URL` / `WP_INFRA_REPO_URL`
  渲染；两个都配了才 `enabled = true`，只配一个时保持关闭并告警。
- tag 读取复用 `.wist/sec-value.yml` 的 `wp_git_pub_token`（`${SEC_WP_GIT_PUB_TOKEN}`）；
  CNB 访问令牌需补 `repo-release:r`（`repo-code:r` 只够 Git clone/fetch）。

### 兼容

- 未配置两个 repo 的现场不受影响；Center 不会因缺少 token 占位而拒启（repo 段整段不渲染）。

## [0.3.9-alpha] - 2026-10-21

### 变更

- **中心后端 `CENTER_IMAGE_TAG` → `v0.19.7-alpha`**：升级计划一律带 `artifact_sha256`（与 `artifact_url` 同源）。
  宿主工具（`galaxy-ops` / `galaxy-flow`）是 gwlinkd 就地把二进制覆盖掉，制品名不是内容寻址 ——
  没有摘要就没有内容校验，而 gops 又是后续升级的执行者。

### 升级注意

- 网关侧配合 `wist-gwlinkd 0.16.3+` 才能把摘要用到 gops 路径的取件校验；不升也能跑（摘要“有才核”）。
- 发布记录有摘要但与制品字节不符时，升级会在取件阶段失败（fail-closed）。

## [0.3.8-alpha] - 2026-10-21

### 变更

- **中心后端 `CENTER_IMAGE_TAG` → `v0.19.6-alpha`**：网关控制命令（体检 / 重启 gateway / 重启 gwlinkd）
  的管理面（`POST/GET …/diagnose`、`POST …/restart`、`GET …/commands/{id}`）。
- **中心前端 `CENTER_WEB_IMAGE_TAG` → `v0.10.9-alpha`**：网关详情页「运行时操作」面板
  （三个按钮 + 体检报告 + 重启进度）。

### 升级注意

- 控制命令的**执行侧**是 gwlinkd：栈升级后还需要中心侧升级到 `wist-gwlinkd 0.16.2+`，否则命令会停在
  `pending` 直到 60s 后变 `expired`。
- `gateway_commands` 新增 `kind` 列：中心启动时随 schema 幂等补列，无需手工 DDL。

## [0.3.7-alpha] - 2026-10-21

### 变更

- **中心前端跟随上游**：`CENTER_WEB_IMAGE_TAG` → `v0.10.8-alpha`（中心后端不变，仍 `v0.19.5-alpha`）。
  该版本修复**网关态势页整页白屏**：CPU / 内存的历史序列整列为空时，趋势行把空数组当成有值、
  直接取 `points[0].x` 抛 `TypeError`，React 卸载整棵组件树 —— 表现为页面闪一下变空白。

## [0.3.6-alpha] - 2026-10-21

### 变更

- **中心组件跟随上游**：`CENTER_IMAGE_TAG` → `v0.19.5-alpha`、`CENTER_WEB_IMAGE_TAG` → `v0.10.7-alpha`。
  网关详情页与接口新增 **gwlinkd 自身版本**（与网关容器版本、gops / gx 并列），自更新进度能在页面与
  `gateway_gwlinkd_info` 指标上直接核对；中心落库新增 `gwlinkd_version` 列（重启自动补列）。

### 修复

- **镜像同步脚本可用了**：`dev/push-images.sh` 改用 `--project-directory`，让 compose 的相对路径按
  栈根解析（此前会去找 `sys/configs/...`，缺 station.env 就直接报错）。
- **WarpStation 沙盒 / 工具链**：随栈交付 `sys/station/default_configs` 并挂进容器
  （`/app/default_configs`）；工具链复制补上 `wpadm / wfadm / wprescue`；去掉从未生效的
  `WARP_STATION_SKIP_SANDBOX`。

### 移除

- **`CENTER_EXTRA_SANS` 配置项**：证书 SAN 只从 `CENTER_DOMAIN` / `API_WGC_DOMAIN` / `WEB_WGS_DOMAIN`
  （+ localhost / 127.0.0.1）派生。现场若用其它名字访问中心，应让那个名字成为上述域名之一，
  而不是再加一个补充列表。

  ⚠️ **升级注意**：本项删除后，下一次 `init-center.sh` 会按新的 SAN 集合**重签叶证书**（CA 不变）。
  若现场正用额外域名访问中心，请先把网关侧地址改成证书内已有的域名，再执行。

## [0.3.5-alpha] - 2026-10-21

### 变更

- **WarpStation 工具链基镜像 `WARPPARSE_IMAGE_TAG` `0.30.0-alpha` → `0.31.1-alpha`**，
  与 `wist-gateway-stack 0.1.52` 对齐。两边必须同版本：规则在网关上跑（`WPARSE_TAG`），
  在 WarpStation 里校验 / 生成（本变量）；错版本会让「校验通过但发布后跑不起来」。

## [0.3.4-alpha] - 2026-10-20

### 变更

- **镜像钉子抬到 `wist-center v0.19.4-alpha` + `wist-center-web v0.10.6-alpha`**：失败任务的
  日志摘要除目录外还带 **任务 ID**，管理面在「任务日志」标题上直接显示 —— 同一份计划重试
  会换 `task_id`，只有目录路径容易看串。
- `sys/db/initdb/01_schema.sql`：`gateway_commands` 补 `task_id` 列（`IF NOT EXISTS`）。

> 网关侧需 `wist-gwlinkd ≥ 0.15.7`。

## [0.3.3-alpha] - 2026-10-20

### 变更

- **镜像钉子抬到 `wist-center v0.19.3-alpha` + `wist-center-web v0.10.5-alpha`**：失败任务
  （升级 / Agent 包 / 知识包 / 规则发布）的日志摘要现在随回执上中心并入库，管理面计划
  条目下多一个「任务日志」折叠块，展开就是现场。网关侧需 `wist-gwlinkd ≥ 0.15.6`。
- `sys/db/initdb/01_schema.sql`：`gateway_commands` 加 `log_dir` / `log_excerpt` 两列
  （`CREATE TABLE IF NOT EXISTS` + `ALTER TABLE ... IF NOT EXISTS`，老库自动补）。

> 现场迁移：`values/<系统名>/sys_value.yml` 里显式钉的 `CENTER_IMAGE_TAG` /
> `CENTER_WEB_IMAGE_TAG` 需同步到 `v0.19.3-alpha` / `v0.10.5-alpha`。

## [0.3.2-alpha] - 2026-10-20

### 变更

- **镜像钉子抬到 `wist-center v0.19.2-alpha` + `wist-center-web v0.10.4-alpha`**：
  0.19.2 把 gwlinkd 回执里的任务日志目录规范化成 `entries[].log_dir`（不再是只能从
  `detail` 里正则捞），0.10.4 的前端据此直接展示日志目录。
  两端的任务日志也补齐了：gwlinkd `0.15.3` 修了脱敏漏项（`Authorization: Basic/Digest`、
  `x-api-key`、JSON 形态的 `"token":"..."`）、目录名消毒与保留策略。

> 现场迁移：`values/<系统名>/sys_value.yml` 里显式钉的 `CENTER_IMAGE_TAG` /
> `CENTER_WEB_IMAGE_TAG` 需同步到 `v0.19.2-alpha` / `v0.10.4-alpha`，否则覆盖优先生效。

## [0.3.1-alpha] - 2026-10-20

### 修复

- **`CENTER_IMAGE_TAG` 默认值提升到 `v0.19.1-alpha`**。0.19.0 的面分离把公网 listener 收窄成
  `/api/v1/gateway/**` + `/api/v1/version`，漏掉了 `/api/v1/releases/artifact/**` ——
  结果是 **gwlinkd / 网关侧任何制品下载都 404**（文件在 `artifacts/` 里，但两个 listener
  都不放行）。升级到这个栈版本前，现场若钉的是 `v0.19.0-alpha`，网关升级、agent 包下发都会失败。
  0.19.1 已把该前缀纳入网关面白名单；本栈默认值同步，并加了防回归测试：
  **注册的每一条 `/api/...` 路由都必须被某个 listener 面放行**。

> 现场迁移：`values/<系统名>/sys_value.yml` 里若显式钉了 `CENTER_IMAGE_TAG: v0.19.0-alpha`，
> 需一并改为 `v0.19.1-alpha`（否则覆盖优先生效，仍会跑旧镜像）。

## [0.3.0-alpha] - 2026-10-20

### 新增

- **管理面 / 网关面分离（需 `wist-center` ≥ 0.19.0）**：中心的 `[server] admin_addr` 由模板渲染
  （容器内 `3102`），两侧 listener 的路由**互斥**：
  - 网关面 `listen_addr`（宿主 `CENTER_HOST_PORT`，**公网**，mTLS）：只挂 `/api/v1/gateway/**` + `/api/v1/version`；
  - 管理面 `admin_addr`（宿主 `CENTER_ADMIN_HOST_PORT`，默认只绑回环）：只挂 `/api/v1/admin/**` + `/api/v1/version`；
  - 白名单外统一 404 —— admin token 泄露也打不到公网 listener 上的管理 API。
- **`*_BIND_IP` 按面绑定**：`CENTER_BIND_IP` / `GIT_PROXY_BIND_IP` 对外（`0.0.0.0`），
  `CENTER_ADMIN_BIND_IP` / `WEB_BIND_IP` / `PG_BIND_IP` / `VM_BIND_IP` / `WPARSE_PROXY_BIND_IP`
  默认 `127.0.0.1`。内网开放时改成内网网卡 IP，**不要**把管理面 / 数据库改成 `0.0.0.0`。
- **域名三分**：`CENTER_DOMAIN` → `WEB_WGC_DOMAIN`（管理面 / Web UI）；新增 `API_WGC_DOMAIN`
  （网关面：`public_url`、gwlinkd 直连 `3100`、Git Proxy）与 `WEB_WGS_DOMAIN`（原 `STATION_DOMAIN`，
  WarpStation Web）。服务器证书 SAN 同时包含三者；留空时分别派生 `api.` / `station.` 前缀。
- **`scripts/provision-station-device.sh`** 入库（README 已引用）：设备地址默认 `API_WGC_DOMAIN`，
  Center API 指管理面端口，设备 token 走 `gops sec`。

### 变更

- `web` 的 `/api/` 反代从 `center:3100` 改为 **`center:3102`（管理面）**；前端宿主端口改由
  `${WEB_BIND_IP}:${WEB_HOST_PORT}` 控制（默认仍只绑 `127.0.0.1`）。
- `CENTER_IMAGE_TAG` 默认值提升到 **`v0.19.0-alpha`**（`admin_addr` 需要该版本才生效）。

### 变量改名（现场 `values/<sys>/sys_value.yml` 需同步）

本次把系统变量按「镜像 / 宿主端口 / 域名」重新命名（只改名字，语义不变）：

| 旧名 | 新名 |
|---|---|
| `WIST_SPC` / `NGINX_SPC` / `WARP_SPC` | `CENTER_REGISTRY` / `GIT_PROXY_REGISTRY` / `WARPPARSE_REGISTRY` |
| `CENTER_TAG` / `WEB_TAG` | `CENTER_IMAGE_TAG` / `CENTER_WEB_IMAGE_TAG` |
| `VM_TAG` / `STATION_TAG` / `WARPPARSE_TAG` / `NGINX_TAG` / `PG_TAG` | `VM_IMAGE_TAG` / `STATION_IMAGE_TAG` / `WARPPARSE_IMAGE_TAG` / `GIT_PROXY_IMAGE_TAG` / `PG_IMAGE_TAG` |
| `CENTER_PORT` / `CENTER_ADMIN_PORT` / `WEB_PORT` / `PG_PORT` | `CENTER_HOST_PORT` / `CENTER_ADMIN_HOST_PORT` / `WEB_HOST_PORT` / `PG_HOST_PORT` |
| `VM_PORT` / `STATION_PORT` / `GIT_PROXY_PORT` / `WPARSE_PROXY_PORT` | `VM_HOST_PORT` / `STATION_HOST_PORT` / `GIT_PROXY_HOST_PORT` / `WPARSE_PROXY_HOST_PORT` |
| `RETENTION_PERIOD` | `VM_RETENTION_MONTHS` |
| `PG_USER` / `PG_PASSWORD` | `PG_SUPERUSER` / `PG_SUPERUSER_PASSWORD` |
| `STATION_MODELS_REPO_URL` / `STATION_INFRA_REPO_URL` | `WP_RULES_REPO_URL` / `WP_INFRA_REPO_URL` |
| `STATION_PROJECT_MODELS_DIR` / `STATION_PROJECT_INFRA_DIR` | `STATION_MODELS_DIR` / `STATION_INFRA_DIR` |
| `CENTER_DOMAIN` / `PUBLIC_API_DOMAIN` / `STATION_DOMAIN` | `WEB_WGC_DOMAIN` / `API_WGC_DOMAIN` / `WEB_WGS_DOMAIN` |

旧名不会被识别（不会报错，但覆盖会静默失效）。升级时按上表改现场值文件。

## [0.2.3-alpha] - 2026-10-20

### 变更

- **`sys localize` 的 gops 版本门禁提升到 2.9**：`secrets.mode` / `perms.services` 需要 gops ≥ 2.9；
  旧版（2.8）会在解析 `sys-prj.yml` 时因未知字段 `mode` 失败。门禁现在直接检查 `gops --version`，
  并提示 `gops self update --channel alpha`。
- 与 0.2.2 的密钥组共享模型配套；无配置/行为变化。

## [0.2.2-alpha] - 2026-10-20

### 变更

- **密钥改为“组共享”模型（需要 gops ≥ 2.9）**：`.wist/sec-value.yml` 不再要求属主为 root/999，
  而是 **属主 = 部署账号、属组 = 容器 gid(999)、`secrets.mode: "0640"`**。部署账号按 owner 读、
  center 按 group 读；`gops sys perms --apply` 只做 chmod/chgrp，**不需要 root、不 chown 到容器 uid**。
- **`sys-prj.yml: perms.services.postgres { uid: 999, gid: 999 }`**：官方 postgres 以 root 启动、
  `gosu` 到 999 后才读 `/docker-entrypoint-initdb.d`；该声明让 `sys/db/initdb` 按 999 对齐，
  避免它被当作 root 服务跳过。
- `sys localize` 的 gops 版本门禁提升到 **2.9**（2.8 的 `secrets` 节是 `deny_unknown_fields`，
  会拒绝 `secrets.mode`）。

### 文档

- README 与初始化脚本（`init-center.sh` / `init-station.sh` / `init-web-conf.sh`）的密钥说明从
  `600` 改为 `0640`（属主=部署账号、属组=999），并补充一次性前置 `usermod -aG 999 <deploy>`
  与“不 chown 给容器 uid、不提权”的说明。

## [0.2.1-alpha] - 2026-10-20

### 新增

- **统一 Web 入口**：中心与 WarpStation 共用一个 nginx、一个端口（`WEB_PORT=2443`），
  按 `server_name` 分流；WarpStation 虚拟主机带 basic auth。证书 SAN 自动包含两个域名。
- **`sys-prj.yml: secrets` 声明密钥文件**，`gops run` / `gops sec` 共用一套加载与校验；
  `secrets.expose` 按消费方（`run` / `localize` / `sec`）限定注入范围。
- **`scripts/lib/sec.sh`**：宿主机侧脚本读取密钥的唯一入口（转调 `gops sec get`），
  删掉 4 份手写 YAML 解析。

### 变更

- **WarpStation 工作区独立挂载**：`knowledge/station/`（原 `configs/station/gitea/`），
  不再落在 `configs/` 下；首次为空时由 `init-station.sh` 从外部 Git 克隆。
- **密钥是运维输入**：`center_admin_token` / `center_hmac_secret` / `center_db_password` /
  `station_db_password` / `station_web_password` 与 Git 读写 token 必须在
  `.wist/sec-value.yml`（600）预先提供；`gops sys localize` 只校验，缺失/为空直接报错，
  不再生成、补键、迁移或改写文件。
- `STATION_GITEA_ROOT_DIR` → **`STATION_KNOWLEDGE_DIR`**（默认 `./knowledge/station`）。


## [0.2.0-alpha] - 2026-10-19

### 新增

- **WarpStation 规则管理 / 发布控制台**：`warp-station`（v0.2.14-alpha）+ 真实 WarpParse
  工具链命名卷 + WarpStation Web（仅绑 `127.0.0.1:18081`）。`wparse__models` / `wparse__infra`
  两个工作副本随 `configs/station` 落盘，版本化仍走外部私有 Git（git-only，不调 API）。
- **Center Git Proxy**：nginx 只读反代 CNB 私有仓库的 smart HTTP 端点，CNB 读 token 只存在
  Center；Gateway 不持有任何 CNB 凭据。默认端口 `18082`。
- **Center wparse-proxy**：`[wparse_proxy]` 独立 HTTPS listener（容器 `3101` / 宿主 `18083`）+
  PostgreSQL 命令队列。WarpStation 发布时经 Center → gwlinkd 短轮询 → 本机 wparse 管理面，
  Gateway 仍然不开放任何入站控制端口。
- **PG 分账号**：`center_app` 只连 `insight_demo`、`station_app` 只连 `wp-station`；
  `scripts/db-init.sh` 幂等建库/建号，并做跨库连接自检（隔离失败直接报错）。
- **`scripts/init-station.sh`**：生成 DB/Station 密钥、预克隆两个工作区、渲染 `station.env`
  与 Git Proxy 配置，并产出 Gateway 对接片段。

### 变更（组件版本）

- `CENTER_TAG → v0.18.0-alpha`：新增规则发布兼容入口（wparse-proxy）、proxy token
  签发/轮换/撤销、mTLS 命令通道、发布请求校验与队列保护。
- 新增端口：`STATION_PORT=18081`、`GIT_PROXY_PORT=18082`、`WPARSE_PROXY_PORT=18083`
  （均可在 `values/value.yml` 覆盖）。

### 修复

- **WarpStation 校验/发布临时目录**：给 `/app/tmp` 挂 tmpfs（1777），修复
  `Permission denied (os error 13)`。
- **容器解析 Center 域名**：`warp-station` 加 `extra_hosts`，避免宿主 hosts 把域名指到
  `127.0.0.1` 时容器 clone 到自己。
- **`dev/svc.sh` 端口兜底误杀**：端口清理现在必须匹配目标进程特征；不再把容器端口转发
  （OrbStack / Docker Desktop helper）当成 dev 进程杀掉。

### 文档

- README 补充 WarpStation / Git Proxy / wparse-proxy 的链路、端口、密钥边界与安全待办；
  说明 `values/value.yml` 只放现场覆盖值、密钥仍走 `.wist/sec-value.yml`。

### 说明

- `sys/sandbox/`（沙盒容器原型）随仓保留，但 v1 编排**未启用**；WarpStation 目前直接执行
  真实工具链（开发态用 `WARP_STATION_SKIP_SANDBOX=1`，生产启用前需去掉）。

## [0.1.16-alpha] - 2026-10-18

### 变更（组件版本）

- **中心 / 前端镜像 tag 跟进**：`CENTER_TAG → v0.17.2-alpha`、`WEB_TAG → v0.10.2-alpha`。本轮：
  - 中心：安装包来源配置 `[packages.sources]` + `GET /api/v1/admin/package-sources`、
    `.../package-sources/latest`；未配置/非法来源返回 400（不再 502）；GitHub tag 兼容带/不带 `v`；
    COS 制品 key 覆盖 `v` / 裸版本 × 平台制品 × 单制品。
  - 前端：录入页按版本号拼地址、自动探测最新版本并预填；操作者手改后不再被自动结果覆盖。
- **`[packages.sources]` 自本版起真正生效**（0.1.15 已把段写进模板，但钉的中心 0.17.1 会忽略它）。

### 文档

- 纠正 `contract` 与 `backup` 的关系：`gops prj backup` **只收 `backup:` 表**，不含 `identity/`；
  站点身份走显式 `gops prj contract export`（归档含私钥，注意收紧权限并离机保存）。
- 补「升级时端口被占 -> 回滚停在中间态（容器无网络）」的处置；`gops run *` 必须在系统根执行；
  中心 API 实为 HTTPS。

## [0.1.15-alpha] - 2026-10-18

### 变更

- **中心挂载按语义拆开**（与 `wist-gateway-stack` 对齐）：`configs/center` 不再是整目录读写挂载源，
  改成 `wist-center.toml`（只读）+ `state/`（读写，JSON store）+ `logs/`（读写）。
  compose 契约与真实意图一致，权限对齐能精确到「配置只读、运行态可写」。
- **权限对齐统一走 `gops sys perms`**（gops ≥ 2.7，本栈硬要求），删除 `scripts/align-host-perms.sh`。
  名单从 `docker compose config` 派生（服务 `user:` + `volumes.read_only`），增减挂载只需改 compose。
  `gops sys localize` 的阶段流程末尾自动 `gops sys perms --apply`；`gops run start` preflight
  会在未对齐时拦住启动。
- **安装包来源配置进模板**：`wist-center.toml.tpl` 新增 `[[packages.sources]]`（wist-agentd /
  wist-gateway-stack / wist-gwlinkd / galaxy-ops / galaxy-flow / wist-knowledge 的 GitHub 仓库与
  COS 桶前缀）。录入页可按版本号自动拼地址 + 探活，不再每次手填完整 URL。
  注：解析 `[packages]` 需要中心 ≥ 0.17.2；当前钉的 `CENTER_TAG=v0.17.1-alpha` 会**忽略**该段
  （serde 不拒未知字段，启动不受影响），升中心后自动生效。
- `dev/configs/` 纳入 `.gitignore` 与 `sys-prj.yml` 的 `ignore`/`protect`（开发态运行物，含密钥）。
- `dev/push-images.sh` 收尾提示改成本栈真实变量（`WIST_SPC` / `PG_SPC` / `VM_SPC`）—— 之前是从
  gateway-stack 拷来的，写的是 `WARP_SPC`。

### 升级要求

- **gops ≥ 2.7**（`gops sys perms`）、**gx ≥ 0.14**（`localize` 阶段流程）。
- 升级后先 `gops sys localize`（备料 + 渲染 + 末尾权限对齐），再 `gops run start`。
  直接 `docker compose up` 会绕过 preflight —— 别这么做。

## [0.1.14-alpha] - 2026-10-18

### 变更

- **中心 / 前端镜像 tag 跟进**：`CENTER_TAG → v0.17.1-alpha`、`WEB_TAG → v0.10.1-alpha`。本轮：
  - 创建升级计划时 **`target_version` 必填**：前端禁用提交并点名缺版本的组件，
    服务端同样 400 —— 空版本派生不出制品，计划会永远停在「已下发」。
  - gwlinkd 对存量的空版本计划回执 `failed` + 落游标（不再静默、不再每 30s 重取）。

## [0.1.13-alpha] - 2026-10-18

### 变更（组件版本）

- **VictoriaMetrics `v1.153.0 → v1.154.0`**（常规小版本；中心与网关两个栈同步）。

### 备注

- 中心 / 前端 / 网关镜像不变：`CENTER_TAG v0.17.0-alpha`、`WEB_TAG v0.10.0-alpha`、
  `GATEWAY_IMAGE v0.17.0-alpha`。

## [0.1.12-alpha] - 2026-10-18

### 变更

- **中心 / 前端镜像 tag 跟进**：`CENTER_TAG → v0.17.0-alpha`、`WEB_TAG → v0.10.0-alpha`。本轮：
  - 中心：落库并暴露网关宿主依赖工具版本（`gateways.gops_version` / `gx_version`，幂等补列），
    Prometheus 增 `gateway_gops_info` / `gateway_gx_info`。
  - 前端：网关详情状态卡新增 `gops` / `gx` 两个读数（缺失为「—」）。
- **`GATEWAY_IMAGE` 对齐 `v0.17.0-alpha`**（生成的网关安装命令用）。

### 升级顺序

- 先升 **网关（v0.17.0-alpha）**，再升本栈；gwlinkd 0.14 由中心推送升级。

## [0.1.11-alpha] - 2026-10-18

### 变更

- **中心 / 前端镜像 tag 跟进**：`CENTER_TAG → v0.16.0-alpha`、`WEB_TAG → v0.9.0-alpha`。本轮：
  - 中心：知识库包**管理**（复用 release 通道，组件 `wist-knowledge`，发布时连带镜像 `.sig`）
    与**下发**（计划动作 `push-knowledge-package`，`activate` 缺省不激活）。
  - 前端：「安装包管理 / 录入」新增知识库组件；「发布计划」新增「③ 知识库下发」。
- **`GATEWAY_IMAGE` 对齐 `v0.16.0-alpha`**（生成的网关安装命令用）。

### 升级顺序

- 先升**网关**（`v0.16.0-alpha`）与**宿主侧 gwlinkd**（`0.13.0-alpha`），再升本栈。
  旧 gwlinkd 不认识 `push-knowledge-package`，会把它当 `upgrade` 去跑 gops。

## [0.1.10-alpha] - 2026-10-17

### 变更

- **镜像 tag 跟进**：中心 `v0.15.1-alpha`、前端 `v0.7.0-alpha`；**网关镜像默认值**（中心生成
  「网关安装命令」时写进渲染配置的那条）跟随 `wist-gateway-stack v0.1.40-alpha` 对齐到 `v0.12.0-alpha`。
  本轮带来：中心支持 **`wist-gwlinkd` 作为升级计划目标**（宿主侧自更新，计划里带 `artifact_sha256`），
  并把 gwlinkd 安装布局改为可自更新（真实二进制 `/usr/local/lib/wist-gwlinkd/` + `/usr/local/bin` 符号链接）；
  新增**单台网关手动升级脚本**端点（`POST /api/v1/admin/gateways/{id}/upgrade-script`，生成
  `curl … | bash` 一行命令，按组件 + 版本命名、30 分钟 HMAC 短命签名，**不建计划、不下发任务**）。
  前端网关详情页新增「手动升级」面板；发布页 ① 可选 `wist-gwlinkd`。

### 升级注意

- **中心与前端必须同版升级**：手动升级面板依赖中心新增的
  `/api/v1/admin/gateways/{id}/upgrade-script` 与网关面 `/api/v1/gateway/upgrade-script`；
  页面 `0.7.0` 已同步，中心仍是旧版时面板会报 404。
- **gwlinkd 走升级计划（自更新）要求宿主侧 ≥ `0.12.0-alpha`**：旧版 gwlinkd 不认识该组件，
  先执行一次「只装 gwlinkd」脚本完成本体替换与布局迁移。**不建计划的手动升级不受此限** ——
  脚本直接下载指定版本、校验 sha256 后覆盖二进制并重启服务。

## [0.1.9-alpha] - 2026-10-15

### 变更

- **镜像 tag 跟进**：中心 `v0.13.0-alpha`、前端 `v0.5.0-alpha`；**网关镜像默认值**（中心生成「网关安装命令」
  时写进渲染配置的那条）跟随网关栈对齐到 `v0.10.0-alpha`。
  本轮带来：中心**「录入安装包」支持腾讯云 COS 路径一键填充**（新端点 `POST /api/v1/admin/cos/resolve`）、
  网关安装脚本拆成 `install-all`（全量）与 `install-linkd`（网关已部署时只补装宿主侧 gwlinkd）；
  前端**新增浅色主题**（默认仍深色）、管理令牌入口挪到右上角状态条。

### 升级注意

- **中心与前端必须同版升级**：`wist-center 0.13.0` 改了安装脚本端点与安装材料字段名
  （`/api/v1/gateway/install-script` → `/install-all`、`install_script_command` → `install_all_command`，
  并新增 `install_linkd_command`；错误码 `install_script_unavailable` → `install_all_unavailable`）——
  页面 `0.5.0` 已同步，两者不同版会出现「拿不到安装命令」。旧端点 / 旧错误码不再提供。

## [0.1.8-alpha] - 2026-10-14

### 变更

- **制品推送到 COS 时自带 sha256**：上传的对象带自定义元数据 `x-cos-meta-artifact-sha256`
  （COS 只存 MD5 ETag，GitHub 资产摘要过不来）；可用 `coscli stat`（HEAD）读回。`x-cos-meta-`
  是 COS 对自定义元数据的强制前缀。

## [0.1.7-alpha] - 2026-10-14

### 修复

- **`public_url` 少了端口 → 网关 link-upstream 指错口**。center 生成的 link-upstream / `init_url` /
  `control_center_endpoint` 全部**原样取自 `public_url`、不补端口**（`wist-center` 侧代码）。而本栈 prod 的
  `scripts/init-center-pub.sh` 把它拼成了 `https://<WEB_WGC_DOMAIN>`（**无端口**）→ 网关拿到的是
  `https://<域>/api/v1/gateway/link-upstream`，落到 **443**（web 前端），而非网关应**直连**的 **3100**
  （443 那层 nginx 终止 TLS、不透传客户端证书 → mTLS 认不了人）。现在 `CENTER_PUBLIC_URL` 拼成
  `https://<WEB_WGC_DOMAIN>:<CENTER_PORT>`（端口为 443 时省略），与 dev 侧口径（`dev/lib.sh`）一致。
  > 既有现场：`identity/center/.env` 里的值**非空一律保留**，需手工把 `CENTER_PUBLIC_URL` 改成带端口的
  > 值（或删掉该键再 `gops sys localize`）。

## [0.1.6-alpha] - 2026-10-14

### 修复

- **全新现场装不起来：补上「网关客户端 CA（CA-G）」的备料**。center 启动时若 `identity/center/` 里没有
  `gateway-client-ca.{pem,key.pem}`，会**尝试现生成**并写 `/wist-center/ca/gateway-client-ca.tmp`，而该目录是
  **只读挂载** → `failed to write …: Read-only file system` → center 无限重启（新装现场、以及从旧版本升上来
  但没搬过 CA-G 的现场都会踩）。现在 `scripts/init-center.sh` 缺失时用 openssl 生成 CA-G（EC P-256、自签、
  `basicConstraints=CA:TRUE`）落 `identity/center/`，随 `gops sys localize` 一步备齐；幂等，已存在即跳过
  （换 CA-G = 已入网网关需重入网，非缺失不碰）。
- **`scripts/align-host-perms.sh` 让 CA-G 私钥按 640 处理**：公开 glob `identity/center/*.pem` 也会命中
  `gateway-client-ca.key.pem`，会把它改成 644（容器能读、但**私钥变全局可读**）。现在把 `identity/center/*.key.pem`
  归入私钥组，并让**私钥优先**、不被公开项改回 644。

## [0.1.5-alpha] - 2026-10-14

### 修复

- **宿主权限对齐补上栈根密钥目录 `.wist/`**：`scripts/align-host-perms.sh` 过去只对齐 `configs/`、`identity/`，
  漏了 `.wist/`；而 `.wist/sec-value.yml` 由 `scripts/init-center.sh` 以 `chmod 600` 生成、属主是部署账号，
  center 容器（固定 `999:999`）读不到 `/secrets/sec-value.yml` → `${SEC_CENTER_ADMIN_TOKEN}` /
  `${SEC_CENTER_HMAC_SECRET}` 解析不出来 → 中心拒启（容器无限重启）。现在 `.wist/`（2755）与
  `.wist/sec-value.yml`（640）一并纳入 `gops sys localize` 的自动对齐，一步到位。

### 变更

- **镜像源前缀拆分，可各自指向不同 registry**：`IMAGE_SPC` → `WIST_SPC`（中心后端/前端）、
  `VM_SPC`（VictoriaMetrics）、`PG_SPC`（PostgreSQL）；`sys/docker-compose.yml` 的 `image:` 与
  README 服务表同步改到位，内网/客户环境可逐项覆盖镜像源。
- **新增 `dev/push-images.sh`**：把 compose 里非 `wist*` 的上游镜像（VictoriaMetrics 等）同步到指定
  registry / 命名空间（默认腾讯云 TCR），取镜像源以 `docker compose config --images` 为准。

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
  证书 = 站点身份 `identity/center/control-center-server.{crt,key}`（由站点 CA 签、SAN 覆盖 `WEB_WGC_DOMAIN`）；
  新增 `scripts/ensure-center-server-cert.sh`（幂等：SAN 覆盖就不重签，换域名/加 SAN 只重签**叶**、CA 不动）。
  于是**不再需要**外部反代即可 `https://<WEB_WGC_DOMAIN>:${WEB_PORT}`。
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

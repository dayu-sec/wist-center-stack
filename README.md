# wist-center-stack

`wist-center`（中心后端） + `wist-center-web`（管理前端） 的一站式编排。

本仓**只做编排**：两个组件的镜像制品来自各自 release 流水线，这里引用它们并负责把它们连起来跑。

## 两种运行方式

- **发布态**：Docker 编排（gops 系统，`kind: docker-compose`），`gops run start` 拉起整个栈 ——
  变量定义与本地化见「发布态」。
- **开发态**：不依赖镜像，直接跑本地编译的二进制 + vite dev（`dev/`）。

两者共用**同一份** `sys/docker-compose.yml`（发布态整栈，开发态只取其 `postgres` / `victoria-metrics`
两个依赖服务），避免两处漂移。

## 组件

| 服务 | 作用 | 端口（宿主:容器） | 镜像来源 |
|---|---|---|---|
| `center` | 中心后端（HTTP API；规则发布兼容入口） | `${CENTER_PORT}:3100`<br>`${WPARSE_PROXY_PORT}:3101` | `${WIST_SPC}/wist-center:${CENTER_TAG}` |
| `web` | 管理前端入口（nginx：**终止 TLS** + 静态 + `/api` 反代到 center） | `${WEB_PORT}:443`（**HTTPS**） | `${WIST_SPC}/wist-center-web:${WEB_TAG}` |
| `postgres` | 中心存储（PgStore） | `${PG_PORT}:5432` | `${PG_SPC}/postgres:${PG_TAG}` |
| `victoria-metrics` | 状态历史时序库 | `${VM_PORT}:8428` | `${VM_SPC}/victoria-metrics:${VM_TAG}` |
| `db-init` | 一次性：创建 `center_app` / `station_app` 角色与库，收紧 `CONNECT` | 无 | `${PG_SPC}/postgres:${PG_TAG}` |
| `db-schema` | 一次性：以 `center_app` 幂等套一遍 `sys/db/initdb/01_schema.sql` | 无 | `${PG_SPC}/postgres:${PG_TAG}` |
| `warp-station` | **规则管理 / 发布控制台**（自带前端 + API；v1 单容器直接执行工具链） | `${STATION_PORT}:8081` | `${STATION_SPC}/wp-station:${STATION_TAG}` |
| `warp-toolchain` | 一次性：把 `wparse/wpgen/wproj` 复制进命名卷 | 无 | `${WARP_SPC}/warp-parse:${WARPPARSE_TAG}` |
| `git-proxy` | Gateway 只读拉取外部 Git 的 Git 反代（路径白名单） | `${GIT_PROXY_PORT}:8443` | `${NGINX_SPC}/nginx:${NGINX_TAG}` |

> `db-schema` 是**一次性任务**（exit 0 即完），`center` 依赖 `db-init` / `db-schema`
> `service_completed_successfully`。存在原因：`docker-entrypoint-initdb.d` **只在空 data 卷首次
> 初始化时**执行，之后 `01_schema.sql` 的改动（新增列）到不了已有库；而该文件全是
> `CREATE/ALTER … IF NOT EXISTS`，每次套一遍是安全的。

> **镜像两处源**：wist\* 镜像由发布流水线双推 —— `ghcr.io/dayu-sec/*`（境外）与
> `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量：
> 改**产品默认**改 `sys/setting/vars.yml`，改**本环境用什么**改 `values/value.yml`（推荐）。
>
> **新增三个上游镜像**（`wp-station` / `nginx` / `warp-parse`）TCR 里没有；发布前用
> `./dev/push-images.sh --dry-run` 检查、需要时实推（脚本会自动从 compose 取镜像，不限于 wist*）。
> `ghcr.io/wp-labs/wp-station` 可能是私有包，推之前先 `docker login ghcr.io`。
>
> **v1 是单容器**：WarpStation 直接执行真实 `wparse/wpgen/wproj`（`warp-toolchain` 卷）。
> “沙盒拆独立容器”作为后续安全加固项保留在 `sys/sandbox/`，当前 compose **不启用**。
>
> **TLS**：`web` nginx 在容器内 **443** 上**终止 TLS**（证书 = 站点身份 `identity/center/control-center-server.{crt,key}`，
> 由站点 CA 签、SAN 覆盖 `CENTER_DOMAIN`；`scripts/init-center.sh` 幂等备齐），宿主发布到 **`${WEB_PORT}`**，
> 于是 `https://<CENTER_DOMAIN>:${WEB_PORT}` 直接用。`center` **自身不做 TLS**（容器网络内明文），`/api` 由 web 反代过去。
> `CENTER_DOMAIN`（= `public_url` 的 host）必须落在服务器证书 SAN 内。
> `git-proxy` 复用同一张服务器证书，Gateway 用 Center CA 校验。
>
> **端口避让**：本栈 VictoriaMetrics 用 `28429`、前端入口 `18080`、WarpStation `18081`、
> Git Proxy `18082`、wparse-proxy `18083`，**刻意避开** `wist-gateway-stack` 的 `18429` / `8443` / `9000`
> —— 两个栈同机同时运行是常态，各自跑独立实例。
>
> **WarpStation 是可选的“规则管理面”**：不接 Gateway 时它也能独立维护规则/配置、跑沙盒；
> 要真正发布到 Gateway 的 WarpParse，还需要 Gateway 侧开启 admin API + project_remote、
> Center 提供 `wparse-proxy`、gwlinkd 轮询执行（见下文「规则管理（WarpStation）」）。

## 目录

```
wist-center-stack/
  sys-prj.yml               # gops 项目描述（ignore / protect / backup / contract）
  sys/                      # gops 系统定义（声明文件；随库入库/交付）
    docker-compose.yml      # 发布态：Docker 编排（易变量用 ${VAR} 占位）
    sys_model.yml           # kind: docker-compose（gops run 据此分发到 docker compose）
    setting/vars.yml        # 系统变量定义（改默认值改这里）
    merged_vars.yml         # 生成：gops sys update
    db/initdb/01_schema.sql # PostgreSQL 建表（空卷首次初始化 + 每次 start 由 db-schema 幂等套一遍；与 wist-center 同源）
    workflows/operators.gxl # 系统运维流程（本地定义；含 localize 阶段扩展点）
    configs/
      center/wist-center.toml.tpl       # 中心**主配置**模板（渲染出 configs/center/wist-center.toml）
      center/wist-center-pub.toml.tpl   # **现场态声明**模板（渲染出 identity/center/wist-center-pub.toml）
      web/nginx.conf.tpl                # 前端站点配置模板（渲染出 configs/web/nginx.conf）
      station/config.toml.tpl           # WarpStation 主配置模板（渲染出 configs/station/config.toml）
      git-proxy/nginx.conf.tpl          # Center Git Proxy 模板（渲染出 configs/git-proxy/nginx.conf）
    sandbox/                  # 后续安全加固用（Go runner/client + Dockerfile）；v1 未启用
  values/                   # gops 值文件（sys_value.yml 生成；value.yml 客户覆盖，版本化）
  configs/                  # 运行期配置（现场生成，不入 git / 不入包）
    center/                 # 发布态：wist-center.toml（由模板渲染）+ state/（JSON store）+ logs/（中心日志）
    web/                    # 发布态：nginx.conf（由模板渲染）
    station/                # WarpStation 运行期（随 configs/ 备份）：
                            #   config.toml / station.env（渲染配置 + 密钥）
                            #   gitea/wparse__models、gitea/wparse__infra（外部 Git 仓库工作副本）
                            #   gitea/wfusion__models、gitea/wfusion__infra（WarpStation 自动补齐）
    git-proxy/              # Git Proxy 渲染物（nginx.conf + value.json；含 Git 读凭据，600）
  identity/                 # 站点身份 + 现场态（dev/prod 共用，含私钥，不入 git / 不入包）：
                            #   center/（CA + 服务器证书/私钥 + wist-center-pub.toml 声明 + .env 值）
                            #   station/warparse-ca.pem（WarpStation 预加载的 WarpParse 信任根）
  artifacts/                # 制品镜像（版本发布下载下来的安装包；本地数据，不入 git / 不入包）
  .wist/                    # 运行期密钥（现场生成，不入 git）：
                            #   sec-value.yml（admin token / hmac secret / DB app 密码 / Git 读写 token）
  scripts/                  # 发布态初始化脚本（幂等；由 localize 阶段流程调用）
    gen-center-ca.sh        # 控制中心 CA + 服务器证书（一次性，手动或由 init-center 调用）
    init-center.sh          # 中心配置渲染值 + CA 备料 + center.env（center_app）+ 密钥文件
    ensure-center-server-cert.sh  # 服务器证书（叶）SAN 覆盖对外域名（幂等重签，不动 CA）
    init-center-pub.sh      # 现场态**值**（CENTER_PUBLIC_URL）→ identity/center/.env（按缺补齐）
    init-web-conf.sh        # 前端站点配置的渲染值（幂等；域名取 CENTER_DOMAIN）
    init-station.sh         # WarpStation/Git Proxy 渲染值 + 外部 Git 预克隆 + WarpParse CA + 对接片段
    db-init.sh              # 一次性：创建 center_app / station_app 角色与库，收紧 CONNECT
  dev/                      # 开发态：本地二进制 + vite（单一入口 svc.sh）
    svc.sh                  # 统一入口：start / stop / restart / status / token（组件 deps|center|web）
    lib.sh                  # 公共函数（svc.sh source 它）
  .github/workflows/release.yml     # 打包发布（见「制品包」）
  .run.gxl / _gal/                  # gx 工作区（版本 / 标签流程）
  version.txt
  README.md
```

> **数据目录**：
> - 开发态的本地 JSON store 落在 `wist-center-stack/.run/`（已 gitignore；可随手清）。
> - **站点身份 + 现场态统一落 `<栈根>/identity/`**（dev/prod 共用）：
>   `center/` 下是中心 CA / 服务器证书 / 私钥 + `wist-center-pub.toml` 声明 + `.env` 值；
>   `station/` 下是 WarpStation 预加载的 `warparse-ca.pem`（默认 = 中心 CA）。整体作**对外契约**
>   （`sys-prj.yml` 的 `contract: - identity`），不随资源树被升级覆盖；compose 只读挂载其中需要的文件。
>   丢了中心 CA 私钥 = 换锚（所有网关要重发信任根），故备份/迁移必带它。
>   **备份走 `gops prj contract export`**（产物在 `ops-prj.yml: contract.target`）：`gops prj backup`
>   **只收 `sys-prj.yml: backup` 表里的 `configs/` + `.wist/`，不含 `identity/`** —— 两者是两条
>   互不合并的通路。归档含私钥，请收紧权限并离机保存。
> - **制品镜像统一落 `<栈根>/artifacts/`**（开发态与发布态同一个位置；发布态由 compose 挂到容器
>   `/wist-center/artifacts`）—— 它是发布时下载/镜像下来的安装包，属数据、不属配置，故与 `configs/`
>   分开（便于单独备份；哪些进 `gops prj backup` 见 `sys-prj.yml` 的 `backup:` 表）。
> - 发布态配置落挂载卷 `configs/center/`（`state/` 存 JSON store；用 PostgreSQL 时不用）。
> - WarpStation 的规则/配置/密钥落 `configs/station/`（随 `configs/` 进 `gops prj backup`）；
>   git 历史以外部 Git 私有仓库为准（本地工作副本可重建）。

## 发布态（经 gops 管理）

本栈是一个 gops 系统（`sys/sys_model.yml` 里 `kind: docker-compose`），起停走 `gops run`，它分发到
对应的 `docker compose` 子命令：

| 命令 | 实际执行 |
|---|---|
| `gops run download` | `docker compose pull` |
| `gops run install` | `docker compose create` |
| `gops run start` | `docker compose up -d` |
| `gops run stop` | `docker compose stop` |
| `gops run uninstall` | `docker compose down` |
| `gops run status` | `docker compose ps` |
| `gops run diagnose` | `docker compose config` |

### 前置：主机要求

| 项 | 要求 | 怎么验 |
|---|---|---|
| Docker + Compose V2 | `docker compose` 是 **CLI 插件**；只有老的 `docker-compose` v1 不够 | `docker compose version` 能打印 `v2.x` |
| gops | **必须 ≥ 2.7**（权限对齐由 `gops sys perms` 提供；旧版没有该子命令） | `gops -V` |
| gx | **≥ 0.14**（`localize` 阶段流程；缺失时 `localize` 只写 `.env`，权限 `--apply` 也不会执行） | `gx -V` |
| 执行账号 | 普通账号 + **已加入 `docker` 组**；部署目录由它拥有 | `id -nG`（输出里应含 `docker`） |
| 端口 | 宿主 `${CENTER_PORT}` / `${WPARSE_PROXY_PORT}` / `${WEB_PORT}` / `${PG_PORT}` / `${VM_PORT}` / `${STATION_PORT}` / `${GIT_PROXY_PORT}` | 见 `sys/setting/vars.yml` |

### 变量与本地化

**一条规则：现场值只写 `values/value.yml`（入库），改完跑 `gops sys localize` 即生效** ——
不需要 `update`，也不用动 `sys/merged_vars.yml`。覆盖值会在同一次 localize 内一致地进入 `.env`
与渲染出的配置（`wist-center.toml` / `nginx.conf`）。

```bash
vim values/value.yml      # 改域名 / 宿主端口等现场值（已跟踪，不忽略）
gops sys localize         # 一条命令：渲染配置 + 导出 .env（compose 读它）
```

`sys/setting/vars.yml` 是**产品默认值**（随仓走的基线），现场一般**不用碰**。确实要改产品默认时：

```bash
gops sys update           # 解析 vars.yml → sys/merged_vars.yml（入库，要一起提交）
gops sys localize
```

**`localize` 还会跑项目自己的阶段流程**：本栈把它定义在 `sys/workflows/operators.gxl`
（**本地定义**，不引外部 ops-gxl），由 `_gal/work.gxl` 的 `mod main : operators` 纳入；合并后的值以
**环境变量**注入该流程（用 `$(printenv XXX)` 读）。流程里做六件**幂等**的事：

1. 确保 `configs/center`、`configs/web`、`configs/station`、`configs/git-proxy`、`identity/center`、`artifacts` 存在；
2. 备料控制中心：CA（信任根 + 服务器证书，落站点身份 `identity/center/`）+ 渲染值
   `configs/center/wist-center.value.json` + 凭据密钥文件 `<栈根>/.wist/sec-value.yml`
   + `configs/center/center.env`（`center_app` 的 PG 凭据，600；`scripts/init-center.sh`，缺什么补什么）；
   再**渲染现场态声明** `identity/center/wist-center-pub.toml`（`gx.tpl`，只有 `${VAR}`、可重渲）
   并由 `scripts/init-center-pub.sh` 按缺补齐**现场态值** `identity/center/.env`（永不重渲）；
3. 渲染 `configs/center/wist-center.toml`（模板在 `sys/configs/center/wist-center.toml.tpl`）；
4. 备料 WarpStation / Git Proxy：补齐 `.wist/sec-value.yml` 的 `station_db_password`（自动生成）
   与 `wp_git_push_token` / `wp_git_pub_token`（由运维提供，也可写 `wp_git_*_user`）；预克隆两个外部 Git 私有仓库到
   `configs/station/gitea/wparse__models` / `wparse__infra`；写 `station.env` / `git-proxy.value.json`；复制中心 CA 到
   `identity/station/warparse-ca.pem`；生成 Gateway 对接片段；渲染 `configs/station/config.toml` 与
   `configs/git-proxy/nginx.conf`；
5. 写前端站点配置的渲染值 + 渲染 `configs/web/nginx.conf`（`scripts/init-web-conf.sh` + 模板）；
6. **宿主属主/权限对齐**（`gops sys perms --apply`，gops ≥ 2.7；见下「权限与运行身份」；非 Linux 自动跳过）——
   必须在 `docker compose up` **之前**：Docker 会把缺失的挂载源目录自行建成 `root:root`，
   属主一旦是 root，之后的部署账号就写不动了。

`gops sys localize --no-flow` 可跳过该流程；未装 gx 或无该流程时静默跳过（此时权限 `--apply` 也不会执行，
但 `gops run start` 的 preflight 会拦住未对齐的启动）。

### 密钥（不落盘）

密钥统一写栈根 `.wist/sec-value.yml`（600）。`gops sys localize` 会补齐缺失的键，已有值保留：

```yaml
# <栈根>/.wist/sec-value.yml
center_admin_token: <中心管理面 token>            # init-center.sh 自动生成
center_hmac_secret: <RegistToken 派生密钥>         # init-center.sh 自动生成
center_db_password: <center_app 的 PG 密码>        # init-center.sh 自动生成（c 前缀）
station_db_password: <station_app 的 PG 密码>      # init-station.sh 自动生成（s 前缀）

# 外部 Git（与提供商无关；用户名不是密钥，也放这里方便现场维护）
#   push = WarpStation 写上游（clone/push/tag）；pub = Git Proxy 读上游（供 Gateway 拉取）
wp_git_push_user: <写账号>                         # 留空则回退到 WP_GIT_PUSH_USER
wp_git_push_token: <写 token>
wp_git_pub_user: <读账号>                          # 留空则回退到 WP_GIT_PUB_USER
wp_git_pub_token: <读 token>
```

两组凭据是**两个独立身份**，可以指向同一个账号，也可以分别用写/只读 token：
`wp_git_push_*` 只出现在 WarpStation 的 `station.env`；`wp_git_pub_*` 只出现在
Git Proxy 的 `nginx.conf`（注入 `WP_GIT_AUTH_HEADER`，默认 `Authorization: Basic ...`）。
换 Git 提供商时只改 URL 与可选的头名，不改变量名。

CNB 的权限坑（实测）：token 必须带 **`repo-code:r`**（读）；`wp_git_push_token` 还要
**`repo-code:w`**（写）。作用域要覆盖 **两个仓库**（建议建在 `dy-sec/jingang-cust` 组上）。
缺 `repo-code:r` 时 push 会失败（git push 先要读 ref）；作用域不含某仓库时 CNB 返回
`Repository Not Found`（而不是 403），容易误判成“仓库写错”。

- 中心配置里只写 `${SEC_CENTER_*}` 占位，由 `WIST_CENTER_SEC_FILE` 指向本文件解析；
- `db-init` 从本文件读取两个 app 密码，创建角色并收紧 `CONNECT`；
- `init-station.sh` 把写 token/账号写进 `configs/station/station.env`、把读账号/token 写进
  `configs/git-proxy/nginx.conf`（两者都 600，且随 `configs/` 进备份）；
- 两个 DB 密码都**不能是纯数字**（WarpStation 用 `config` crate 的 `try_parsing`，纯数字会被当成整数
  导致反序列化失败）；自动生成值都带字母前缀。

推进外部 Git 凭据的两种方式（**不要写进 `values/` 或 `vars.yml`**）：

**方式 A（日常推荐）：直接写 `.wist/sec-value.yml`**

```yaml
wp_git_push_user: <写账号>
wp_git_push_token: <写 token>
wp_git_pub_user: <读账号>
wp_git_pub_token: <读 token>
```

然后：

```bash
gops sys localize
```

`init-station.sh` 会从 `.wist` 读取这四个键，渲染 `station.env` 与 `configs/git-proxy/nginx.conf`。
文件本身是 600、已在 `.gitignore` 里；这是最稳的日常做法，不会进 shell history / 进程列表。

**方式 B（CI / 一次性轮换）：用环境变量覆盖**

```bash
WP_GIT_PUSH_USER=<write-user> WP_GIT_PUSH_TOKEN=<write-token> \
WP_GIT_PUB_USER=<read-user>   WP_GIT_PUB_TOKEN=<read-token> gops sys localize
# 已有值不会被空环境变量覆盖；轮换时带新值跑一次即可。
```

两种方式效果相同；环境变量只在**非空**时覆盖 `.wist` 里的已有值。

> **改完 token 后要重建容器**：`station.env` 是 `env_file`（容器创建时读取），
> `configs/git-proxy/nginx.conf` 是单文件 bind mount（原子替换后 inode 变）。
> `gops run start` 本质是 `docker compose up -d`，**不保证**重建；请显式执行：

```bash
docker compose --project-directory . -f sys/docker-compose.yml \
  up -d --force-recreate warp-station git-proxy
```

### 前置：挂载文件

compose 还挂这些路径：

1. `configs/center/` —— 中心渲染配置与 JSON store。**仓库不含**，由 `scripts/init-center.sh` 现场备料
   + 模板渲染。compose **只挂其中三块**：`wist-center.toml`（只读）、`state/`（读写）、`logs/`（读写）；
   `wist-center.value.json` 是渲染源、不进容器。凭据在 `<栈根>/.wist/sec-value.yml`（见上「密钥」），
   `configs/center/wist-center.toml` 里只写占位符。
   > `configs/center/` **本身不再是挂载源**：它必须由 `gops sys localize` 以**部署账号**创建。
   > **不要先 `docker compose up` 再 localize** —— Docker 会以 root 建出缺失的挂载源，而且缺失的
   > `wist-center.toml` 会被建成同名**目录**（之后渲染会失败）。
2. `identity/center/` —— **站点身份 + 现场态**（dev/prod 共用，整体作对外契约）。**仓库不含**：
   `control-center.pem`（分发给网关的信任根）/ `control-center-ca.key` / `control-center-server.{crt,key}`，
   以及 `gateway-client-ca.{pem,key.pem}`（**网关客户端 CA / CA-G**：中心用它给注册入网的网关签客户端证书），
   均由 `scripts/init-center.sh` 现场生成（缺什么补什么）；`wist-center-pub.toml`（**现场态声明**，只写 `${VAR}`）由
   `gx.tpl` 渲染；同目录 `.env`（**现场态值**）由 `scripts/init-center-pub.sh` 按缺补齐。compose 把本目录
   只读挂到容器 `/wist-center/ca`，并用 `WIST_CENTER_PUB_CONFIG=/wist-center/ca/wist-center-pub.toml` 指向它。
3. `sys/configs/web/nginx.conf.tpl` —— 前端站点配置**模板**。**仓库自带**，由 `gops sys localize`
   渲染到 `configs/web/nginx.conf`（容器内 **443 终止 TLS** + 静态托管 + SPA 深链回退 + 把 `/api` 反代到 `center:3100`）。
   证书/私钥只读挂载自 `identity/center/control-center-server.{crt,key}`。
4. `sys/db/initdb/01_schema.sql` —— PostgreSQL 建表脚本（**仓库自带**）。挂**两处**：
   ① `/docker-entrypoint-initdb.d`（**仅首次**初始化空数据卷时由 postgres 入口脚本执行）；
   ② `db-schema` 一次性服务挂到 `/schema`，**每次 `start` 幂等套一遍**（覆盖既有数据卷的补列）。
   它与 `wist-center/docker/initdb/01_schema.sql` 同源，改中心 schema 时两处要同步。
5. `configs/station/` —— WarpStation 渲染配置（`config.toml`，只读）、`station.env`（env_file）与
   两个外部 Git 工作副本（`gitea/wparse__models/` / `gitea/wparse__infra/`，读写）。由 `init-station.sh` + `gx.tpl`
   现场生成；**不要**把 token 写进这两个 git 工作副本。
6. `configs/git-proxy/nginx.conf` —— Git Proxy 的完整 nginx 配置（只读挂到 `/etc/nginx/nginx.conf`）。
   含路径白名单与 Git 读凭据；由 `init-station.sh` 生成 value.json、`gx.tpl` 渲染，权限 600。
   证书复用 `identity/center/control-center-server.{crt,key}`。
7. `sys/sandbox/` —— **后续安全加固项**（仓库自带，v1 compose 不引用）。里面的 Go
   runner/client 用于“规则执行拆独立容器”；当前单容器模式直接使用 `warp-toolchain` 卷里的
   真实 `wparse`/`wpgen`/`wproj`。

### 权限与运行身份（Linux 必读）

`center` 镜像**固定以 `999:999` 运行**（镜像里 `useradd -r wist`；compose 里 `user:` 已显式钉死）。
bind 挂载在 Linux 上**不改变属主**，所以宿主侧必须显式对齐，否则容器写不出 `state/`、读不到 CA 私钥。

**统一入口是 `gops sys perms`（gops ≥ 2.7，本栈硬要求）**：

```bash
gops sys perms            # 只检查（未对齐 exit≠0）
gops sys perms --apply    # 幂等修复
```

它从 `docker compose config` 派生每个 bind 挂载的 `source` 与 `read_only`，按服务 `user:` 对齐，**不需要本仓维护名单**：

- **属主 = 部署账号**（`SUDO_UID`/euid），**属组 = 容器 gid**；部署账号要改配置、跑备份/恢复，所以不需要提权；
- **读写挂载**（`configs/center/state`、`configs/center/logs`、`artifacts`）→ 文件 `0660`、目录 `2770`（setgid）；
  **只读挂载**（`wist-center.toml`、`identity/center`、`.wist`）→ 文件 `0640`、目录 `2750`；
- **容器自己创建的**（owner = 容器 uid，如 JSON store）不碰 —— 零 sudo 幂等；
- 只处理**系统根内**的 bind source；根外路径要在 `sys-prj.yml: perms.allow_external` 显式声明；
- rootless / userns-remap：必须配 `sys-prj.yml: perms.container_uid/gid`（gops 会明确报错，不静默按 999 对齐）；
- 不跟随符号链接、不碰 named volume；**仅 Linux**（macOS / OrbStack 打印 `[SKIP]`）。

生命周期：`gops sys localize` 末尾做一次**只告警**的自检；`gops run start` preflight（未对齐即停）；
`gops prj restore` / `prj upgrade` 自动 `--apply`。`localize` 的阶段流程也会在最后跑一次 `gops sys perms --apply`，
保证「localize 完就能 start」。

> **这些保证只覆盖 gops 入口**：`gops sys localize`（阶段流程 apply）、`gops run start`（preflight）、
> `gops prj restore/upgrade`（自动 apply）。直接 `docker compose up` 会绕过全部检查 —— 部署请始终走 gops。

> `web` / `postgres` / `db-schema` 的身份不需要对齐：`web` 以 **root** 运行（镜像没有 `user:`，`gops sys perms`
> 会提示「身份无法确定」并跳过它的只读挂载）；`postgres` 用 named volume（不在 bind 范围内）。

常见症状（Linux 部署事故）：

| 症状 | 日志 | 原因 |
|---|---|---|
| center 无限重启 | store 打开失败 / `Permission denied (os error 13)` | `configs/center/state` 属主不是 999 且组不可写 |
| center 拒启 | `failed to load secrets /secrets/sec-value.yml` | `.wist/sec-value.yml` 是 `600` 且属主不是 999 |
| center 不提供信任根 | 读 `ca/control-center.pem` / `*.key` 失败 | `identity/center` 未对齐（目录 2750 / 私钥 640） |
| 制品无法写入 | 上传 / 镜像落盘报错 | `artifacts/` 属主是 root（被 `docker compose up` 先建出来了） |

### 起来之后

- 管理页面：`https://<CENTER_DOMAIN>:${WEB_PORT}`（如 `https://center.dev.wist.lab:18080`；用站点 CA `identity/center/control-center.pem` 校验）
- 中心 API：`https://<host>:${CENTER_PORT}`（compose 配了服务器证书 → 中心本身就是 **HTTPS**；
  网关侧走 mTLS，浏览器/脚本可用 `-k` 或带站点 CA 校验证书）
- 管理 token：见上「密钥」里的 `center_admin_token`
- 规则管理（WarpStation）：`http://<host>:${STATION_PORT}`（默认 `18081`；默认 `admin / 123456`）
- 起停与排查：

```bash
gops run start
gops run status
gops run stop
```

> 别用裸 `docker compose up` 起栈：它绕过 `gops run start` 的 preflight（权限未对齐会直接拦住）
> 和 `gops prj restore/upgrade` 的自动 `--apply`。

#### 升级时端口被占（`failed to set up container networking: Bind for 0.0.0.0:443 failed`）

`gops prj upgrade` 的 `up` 阶段会因端口冲突失败并触发回滚，而**回滚可能停在中间态**：
文件已经换成新包，但失败的容器被留在**没有网络**的状态（`docker inspect` 里
`.NetworkSettings.Networks` 为空）——此时再 `up` 会报「Container Started」却反复重启，
日志是 `connect postgres … failed to lookup address information`（容器根本没接上网络，
不是 Pg 的问题）。

处置：先腾出端口，再**强制重建**（普通 `up` 不会修无网络的容器）：

```bash
gops run stop                     # 或停掉占用 443/8443 的另一个栈
docker compose -f sys/docker-compose.yml --project-directory . up -d --force-recreate
gops prj upgrade <sys> <version>  # 端口空着时重跑一次，把版本落账
gops run status
```

`CENTER_PORT` / `WEB_PORT` 的**默认值（3100 / 18080）刻意避开了网关栈的 443 / 8443**；
现场把它们改成 443 / 8443 后就**不能与网关栈同机同时运行**（端口冲突，与容器名无关：
本栈容器名是 `wist-center-stack-*`，网关栈是 `wist-gateway-stack-*`）。

> 上面这些命令都在**系统根**（本目录，即 `.../wist-center-stack/`）执行。
> 在维护工程根（如 `wcenter-alpha/`）执行 `gops run start` 会被当成工程的 `main` 流程，
> 报 `Galaxy Flow Parse Error … detail: start` —— 不是栈坏了，是目录错了。

## 规则管理（WarpStation）

WarpStation 是**独立的规则/配置控制台**（镜像自带前端 + API），与中心后端解耦：中心挂了不影响
规则维护；但“发布到 Gateway”依赖 Center 的命令通道。

| 项 | 值 |
|---|---|
| 控制台 | `http://127.0.0.1:${STATION_PORT}`（默认 `18081`，**只绑回环**） |
| 默认账号 | `admin / 123456`（**首次登录后立即修改**） |
| 暴露面 | **⚠ 上游 v0.2.14 的 API 没有鉴权**：登录只发 token，后端不校验；因此 compose **只发布到 `127.0.0.1`**。不要改成 `0.0.0.0`/对外端口；远程访问用 SSH 隧道，或在 Center web 前加认证反代（TODO） |
| 规则/配置主数据源 | `configs/station/gitea/wparse__models/`（wpl / oml / knowledge）<br>`configs/station/gitea/wparse__infra/`（conf / topology / connectors） |
| 版本仓库 | 外部 **Git 私有仓库**（当前部署为 CNB：`wp-rules` / `wp-infra`）；**git-only**，不依赖 Git 服务 API |
| 沙盒校验 | v1 单容器：`warp-toolchain` 卷里的真实 `wparse` / `wpgen` / `wproj`（来自 `${WARP_SPC}/warp-parse:${WARPPARSE_TAG}`） |
| 系统库 | 与中心共用 PostgreSQL 实例，但**独立库/账号**：`station_app` → `wp-station`；`center_app` → `insight_demo` |
| 密钥 | Git 写 token：`.wist/sec-value.yml` → `configs/station/station.env`<br>DB：`station_db_password` 渲染进 `config.toml` 并写入 `station.env`（均 600/640） |

### Git 链路（规则/配置版本化）

```text
WarpStation --(git push/tag, CNB 写 token)--> CNB 私有仓库
Gateway wparse --(git fetch, 无 CNB 凭据)--> Center Git Proxy :${GIT_PROXY_PORT} --(CNB 读 token)--> CNB
```

- `init-station.sh` 预克隆两个仓库到 `gitea/wparse__models/` / `gitea/wparse__infra/`；已有 `.git` 且 `origin`
  未变时保留现场改动；**`origin` 变了会先校验工作区无未提交改动，再 fetch + 硬重置到新远端 `main`**（否则旧历史
  会被下次 push 带到新仓库）。默认分支必须是 `main`，并校验 `wp-rules/models/`、`wp-infra/conf/`
  （可用 `STATION_SKIP_REPO_CHECK=1` 临时跳过）。
- WarpStation 检测到 `.git` 已存在会跳过 `init_gitea_repo`，因此**不会调用任何 Git 服务 API**。
- CNB 写 token 只在 WarpStation 主容器；读 token 只在 Git Proxy。
- Gateway 的 `[project_remote]` 用 `${WPARSE_PROJECT_*_REPO}` 占位，真实地址由 Gateway 容器环境注入。

### 控制链路（发布触发）

```text
WarpStation --(HTTPS + per-gateway proxy token)--> Center wparse-proxy :3101
Center --(gateway_commands 队列)--> gwlinkd --(出站 mTLS，1–2s 轮询)--> 本机 wparse :19090
```

- WarpStation 设备填 **Center `wparse-proxy`** 的地址与 token（`POST /api/v1/admin/gateways/{id}/wparse-proxy-token`
  生成，绑定 `gateway_id`），**不要**填 Gateway 管理面地址，也不要用网关 mTLS 证书或 wparse admin token。
- Center 只接受 `POST /admin/v1/reloads/model` 与 `GET /admin/v1/runtime/status`；超时返回 `202`，
  WarpStation 后续轮询状态。
- Gateway **不开放任何入站端口**：wparse 在容器内绑 `0.0.0.0:19090` + TLS，宿主只发布
  `127.0.0.1:19090`；只有本机 gwlinkd 能访问。

**备份**：`configs/station/`（工作副本、`config.toml`、`station.env`）与 `configs/git-proxy/`
随 `configs/` 进 `gops prj backup`；**版本历史以 CNB 为准**，本地工作副本可重建。备份含 CNB token
与 DB 密码，必须加密并限制访问；泄露后立即轮换 token（重跑 localize 并带新环境变量即可）。

**工作流**：规则/配置保存 → commit/push 到 CNB → 沙盒验证（v1 在 WarpStation 容器内跑真实 `wparse/wpgen`）
→ 打 tag → 调 Center `wparse-proxy` 触发目标 Gateway 重载。发布前必须有一次通过的沙盒任务
（可用 `WARP_STATION_SKIP_SANDBOX=1` 跳过，不推荐）。

> **改了 `config.toml` / `nginx.conf` / token 后要重建容器**：`config.toml`、`nginx.conf` 是
> **单文件 bind mount**（`gx.tpl` 原子替换后 inode 变，旧容器仍看旧文件），`station.env` 是
> `env_file`（容器创建时读取）。`gops run start` 是 `docker compose up -d`，不保证重建；
> 请显式用 `docker compose ... up -d --force-recreate warp-station git-proxy`。

> **首次启动后必须先改 infra 的 `conf/wparse.toml`**：WarpStation 的内置默认配置里
> `[project_remote]` 指向上游自带的 `localhost:3000`。请在「配置管理」里把
> `[project_remote]` / `[admin_api]` 改成 `configs/station/gateway-wparse-snippet.toml` 的内容，
> 保存并发布一次 infra；否则 Gateway 拉到 infra 后会把配置改回 localhost。

### 对接 Gateway 的 WarpParse

WarpStation 只负责“规则维护 + 版本化 + 发布指令”，真正落地还需要 Gateway 侧满足下面四条。
**当前 `wist-gateway-stack` 的 wparse 把 `data-plane/*` 只读挂载、且未暴露管理面；
直接发布是走不通的，需要按本节改造 Gateway 的运行方式。**

1. **管理面（容器内 TLS，宿主回环）**：`conf/wparse.toml` 开启 `[admin_api]`，绑定
   `0.0.0.0:19090`，开启 `[admin_api.tls]`（WarpParse 规定非回环绑定必须 TLS），
   `[admin_api.auth].token_file` 指向 Gateway localize 生成的 `data-plane-run/.run/admin_api.token`。
   compose **只发布** `127.0.0.1:19090:19090`；**不要**写成 `0.0.0.0:19090:19090`。
   - 证书复用 Gateway 的 `admin-tls`；gwlinkd 用 `identity/gateway/public/gateway-ca.crt.pem` 校验。
2. **工作根可写**：`[project_remote]` 会往工作根写 `models/ conf/ topology/ connectors/`，
   所以 wparse 的 `--work-root` 必须是**可写目录**。推荐：`data-plane/` 只读挂到 `/seed`，
   `data-plane-run/work` 可写挂到 `/data`，启动时 `cp -an /seed/. /data/`（只补缺失）。
3. **双仓库远端**：`conf/wparse.toml` 配 `[project_remote] enabled = true`、`repo = ""`，并分别配
   `[project_remote.models].repo` / `[project_remote.infra].repo` 为 `${WPARSE_PROJECT_*_REPO}` 占位；
   值由 Gateway 容器环境注入（Center Git Proxy 地址，见 `configs/station/gateway-wparse-snippet.toml`）。
4. **网络**：Gateway 主机能访问 Center `${GIT_PROXY_PORT}`（Git）与 `${CENTER_PORT}`（gwlinkd mTLS）；
   Gateway 不需要能访问 CNB。

然后在 WarpStation「设备管理」新增设备：

- **IP/域名 + 端口**：Center `wparse-proxy`（`https://<center-domain>:${WPARSE_PROXY_PORT}`）；
- **Token**：Center 为该 `gateway_id` 生成的 proxy token（明文只显示一次）。

发布按 **models / infra** 分组；WarpStation 对每台设备调用
`POST /admin/v1/reloads/model`（`update=true` + `group=models|infra` + `version=<tag>`），
Center 入队，gwlinkd 在 1–2s 内取到并热重载。

## 开发态（本地二进制）

```bash
# 起全套（deps + center + web）：
./dev/svc.sh start

# 只起/另起某组件（deps | center | web），可组合：
./dev/svc.sh start center         # 只起后端
./dev/svc.sh start web            # 只起前端
./dev/svc.sh start deps           # 第三方依赖：PostgreSQL 55432 + VictoriaMetrics 28429
./dev/svc.sh start all            # = start（全部组件）

# 看状态 / 停止 / 取管理 token：
./dev/svc.sh status
./dev/svc.sh stop                 # 停全部（也可 ./dev/svc.sh stop web）
./dev/svc.sh token

# 重启（停 → 起）：改了配置/代码要生效时用
./dev/svc.sh restart center       # 只重启中心（也可 restart web、restart 全量）

# 跳过 cargo build / 只看计划不执行：
./dev/svc.sh start center --no-build
./dev/svc.sh restart center --dry-run
```

起完后：

- 管理页面 `http://127.0.0.1:5173`（vite dev，`/api` 反代到中心 `https://127.0.0.1:3100`）
- 中心 API `https://127.0.0.1:3100`（dev **默认 TLS**：用**共享站点 CA**签的本地叶证书；`WIST_CENTER_TLS=0` 可关成明文 HTTP）
- **管理 token**：首次启动生成在中心配置文件里（`<栈>/dev/configs/center/wist-center.toml`），之后每次启动
  复用同一份并打印 —— 不再每次变。填入管理页面即可开启 5s 轮询刷新
- 日志：`/tmp/wist-center.log`、`/tmp/wist-center-web.log`

开发态用 `wist-center init-config` 生成 `<栈>/dev/configs/center/wist-center.toml`（随机 admin token /
hmac secret）；发布态不用它，改走上面的 gops 密钥。dev 的**站点身份**（CA 信任根 + CA-G）与发布态**共用**
`identity/center/`（dev 只用共享 CA 签**自己的**叶证书，落 `dev/configs/center/tls/`）—— 同一站、同一信任根；
配置/运行态落**栈内** `dev/configs/center/`（不再用 `~/.wist-center/`）。

> **接入本机网关**：把本机网关栈接到这个中心，在网关页「链接上级」提交接入链接即可 —— gwlinkd
> （网关**宿主侧**常驻、随网关走）归 `wist-gateway-stack` 仓，由那边 `./dev/svc.sh start` 带起。

前端如果没有装依赖，先执行一次：

```bash
(cd ../wist-center-web && npm install)
```

## 制品包（发布）

打 tag（`v*.*.*`）时 `.github/workflows/release.yml` 用 `git archive` 把**整仓（除 `.github`）**
打成 `wist-center-stack-<tag>.tar.gz` 挂到 Release，供 `gops prj import` / 中心作为版本制品引用。
`sys/merged_vars.yml` 随仓入库、进包，所以 CI 里不必现算 —— 但改了 `sys/setting/vars.yml` 后，
本地要跑一次 `gops sys update` 并把 `merged_vars.yml` 的变更一起提交。

同一制品包还会（可选）推到**腾讯云 COS**，走官方 `coscli`，供中心 / CDN 按稳定 URL 拉取。
**未设置 `COS_BUCKET` 时该步骤自动跳过，不会让发布失败；一旦设置就视为启用，密钥缺失会直接报错（便于发现漏配）。** 需要一次性配置：

| 类型 | 名称 | 说明 |
|---|---|---|
| Variables | `COS_BUCKET` | 桶名，含 APPID，如 `example-1250000000` |
| Variables | `COS_REGION` | 地域，如 `ap-guangzhou` |
| Variables | `COS_PREFIX` | 可选，对象键前缀，默认 `wist-center-stack` |
| Secrets | `COS_SECRET_ID` | 腾讯云访问密钥 ID |
| Secrets | `COS_SECRET_KEY` | 腾讯云访问密钥 Key |
| Secrets | `COS_SESSION_TOKEN` | 可选，仅临时密钥（STS）场景需要 |

上传的对象键（`<prefix>` = `COS_PREFIX`）：

```
<prefix>/<tag>/wist-center-stack-<tag>.tar.gz     # 按版本钉住，不可变
<prefix>/latest/wist-center-stack-<tag>.tar.gz    # 便于“取最新”，文件名仍带版本
```

建议给这对密钥最小权限，只授权目标桶 / 前缀的写入（`PutObject`）。

版本以仓库根 `version.txt` 为权威，用 `gx adm v_patch` / `v_feat` 升级、`gx adm tag_alpha` 打标签。

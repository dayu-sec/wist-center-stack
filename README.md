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
| `center` | 中心后端（HTTP API） | `${CENTER_PORT}:3100` | `dy-sec.tencentcloudcr.com/cloud/wist-center` |
| `web` | 管理前端入口（nginx：静态 + `/api` 反代到 center） | `${WEB_PORT}:80`（HTTP） | `dy-sec.tencentcloudcr.com/cloud/wist-center-web` |
| `postgres` | 中心存储（PgStore） | `${PG_PORT}:5432` | `postgres:${PG_TAG}` |
| `victoria-metrics` | 状态历史时序库 | `${VM_PORT}:8428` | `victoriametrics/victoria-metrics` |
| `db-schema` | 一次性：每次 `start` 幂等套一遍 `sys/db/initdb/01_schema.sql` | 无 | `postgres:${PG_TAG}` |

> `db-schema` 是**一次性任务**（exit 0 即完），`center` 依赖它 `service_completed_successfully`。
> 存在原因：`docker-entrypoint-initdb.d` **只在空 data 卷首次初始化时**执行，之后 `01_schema.sql`
> 的改动（新增列）到不了已有库；而该文件全是 `CREATE/ALTER … IF NOT EXISTS`，每次套一遍是安全的。

> **镜像两处源**：两个发布流水线都双推 —— `ghcr.io/dayu-sec/*`（境外）与
> `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量：
> 改**产品默认**改 `sys/setting/vars.yml`，改**本环境用什么**改 `values/value.yml`（推荐）。
>
> **TLS**：中心与前端入口**自身都不做 TLS**（center 是明文 HTTP，web nginx 也在容器内 80 跑明文）。
> 对外 HTTPS 由**前面的反代**终止，并由它持有控制中心服务器证书；`CENTER_DOMAIN` / `public_url`
> 的 host 必须落在该证书 SAN 内（`scripts/gen-center-ca.sh` 可生成一整套 CA + 服务器证书）。
>
> **端口避让**：本栈 VictoriaMetrics 用 `28429`、前端入口 `18080`，**刻意避开** `wist-gateway-stack`
> 的 `18429` / `8443` —— 两个栈同机同时运行是常态，各自跑独立实例。

## 目录

```
wist-center-stack/
  sys-prj.yml               # gops 项目描述（ignore / preserve / backup）
  sys/                      # gops 系统定义（声明文件；随库入库/交付）
    docker-compose.yml      # 发布态：Docker 编排（易变量用 ${VAR} 占位）
    sys_model.yml           # kind: docker-compose（gops run 据此分发到 docker compose）
    setting/vars.yml        # 系统变量定义（改默认值改这里）
    merged_vars.yml         # 生成：gops sys update
    db/initdb/01_schema.sql # PostgreSQL 建表（空卷首次初始化 + 每次 start 由 db-schema 幂等套一遍；与 wist-center 同源）
    workflows/operators.gxl # 系统运维流程（本地定义；含 localize 阶段扩展点）
    configs/
      center/wist-center.toml.tpl   # 中心配置模板（渲染出 configs/center/wist-center.toml）
      web/nginx.conf.tpl            # 前端站点配置模板（渲染出 configs/web/nginx.conf）
  values/                   # gops 值文件（sys_value.yml 生成；value.yml 客户覆盖，版本化）
  configs/                  # 运行期配置/密钥（现场生成，不入 git / 不入包）
    center/                 # 发布态：wist-center.toml（由模板渲染）+ ca/（CA/证书）+ state/
    web/                    # 发布态：nginx.conf（由模板渲染）
  artifacts/                # 制品镜像（版本发布下载下来的安装包；本地数据，不入 git / 不入包）
  scripts/                  # 发布态初始化脚本（幂等；由 localize 阶段流程调用）
    gen-center-ca.sh        # 控制中心 CA + 服务器证书（一次性，手动或由 init-center 调用）
    init-center.sh          # 中心配置渲染值 + CA 备料（幂等）
    init-web-conf.sh        # 前端站点配置的渲染值（幂等；域名取 CENTER_DOMAIN）
    align-host-perms.sh     # 宿主属主/权限对齐（属主=部署账号、属组=容器 gid 999；幂等）
  dev/                      # 开发态：本地二进制 + vite（单一入口 svc.sh）
    svc.sh                  # 统一入口：start / stop / status / token（组件 deps|center|web）
    lib.sh                  # 公共函数（svc.sh source 它）
  .github/workflows/release.yml     # 打包发布（见「制品包」）
  .run.gxl / _gal/                  # gx 工作区（版本 / 标签流程）
  version.txt
  README.md
```

> **数据目录**：
> - 开发态的本地 JSON store 落在 `wist-center-stack/.run/`（已 gitignore；可随手清）。
> - **制品镜像统一落 `<栈根>/artifacts/`**（开发态与发布态同一个位置；发布态由 compose 挂到容器
>   `/wist-center/artifacts`）—— 它是发布时下载/镜像下来的安装包，属数据、不属配置，故与 `configs/`
>   分开（便于单独备份；备份分级见 `sys-prj.yml`）。
> - 发布态配置/密钥落挂载卷 `configs/center/`（`state/` 存 JSON store；用 PostgreSQL 时不用）。

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
| 执行账号 | 普通账号 + **已加入 `docker` 组**；部署目录由它拥有 | `id -nG`（输出里应含 `docker`） |
| 端口 | 宿主 `${CENTER_PORT}` / `${WEB_PORT}` / `${PG_PORT}` / `${VM_PORT}` | 见 `sys/setting/vars.yml` |

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
**环境变量**注入该流程（用 `$(printenv XXX)` 读）。流程里做四件**幂等**的事：

1. 确保 `configs/center`、`configs/web` 存在；
2. 备料控制中心：CA（信任根 + 服务器证书）+ 渲染值 `configs/center/wist-center.value.json`
   （`scripts/init-center.sh`，缺什么补什么）；
3. 渲染 `configs/center/wist-center.toml`（模板在 `sys/configs/center/wist-center.toml.tpl`），
   并写前端站点配置的渲染值 + 渲染 `configs/web/nginx.conf`（`scripts/init-web-conf.sh` + 模板）；
4. **宿主属主/权限对齐**（`scripts/align-host-perms.sh`；非 Linux 自动跳过）——
   必须在 `docker compose up` **之前**：Docker 会把缺失的挂载源目录自行建成 `root:root`，
   属主一旦是 root，之后的部署账号就写不动了。

`gops sys localize --no-flow` 可跳过该流程。

### 密钥（不落盘）

两个运行期密钥走 gops `.galaxy` 密钥，**不写进 `.env` / 不入库**：

```yaml
# ~/.galaxy/sec_value.yml
center_admin_token: <管理面 token>
center_hmac_secret: <RegistToken 派生密钥>
```

`gops run start` 会把它们以 `SEC_CENTER_ADMIN_TOKEN` / `SEC_CENTER_HMAC_SECRET` 注入
`docker compose` 子进程；compose 再把它们映射进 `center` 容器的环境变量，
模板里的 `admin_token` / `hmac_secret` 引用这两个环境变量在运行期解析。

### 前置：挂载文件

compose 还挂这些路径：

1. `configs/center/` —— 中心配置与密钥。**仓库不含**，由 `scripts/init-center.sh` 现场备料 + 模板
   渲染；`configs/center/ca/control-center.pem` 是分发给网关的信任根。
2. `sys/configs/web/nginx.conf.tpl` —— 前端站点配置**模板**。**仓库自带**，由 `gops sys localize`
   渲染到 `configs/web/nginx.conf`（静态托管 + SPA 深链回退 + 把 `/api` 反代到 `center:3100`）。
3. `sys/db/initdb/01_schema.sql` —— PostgreSQL 建表脚本（**仓库自带**）。挂**两处**：
   ① `/docker-entrypoint-initdb.d`（**仅首次**初始化空数据卷时由 postgres 入口脚本执行）；
   ② `db-schema` 一次性服务挂到 `/schema`，**每次 `start` 幂等套一遍**（覆盖既有数据卷的补列）。
   它与 `wist-center/docker/initdb/01_schema.sql` 同源，改中心 schema 时两处要同步。

### 权限与运行身份（Linux 必读）

`center` 镜像**固定以 `999:999` 运行**（镜像里 `useradd -r wist`；compose 里 `user:` 已显式钉死）。
bind 挂载在 Linux 上**不改变属主**，所以宿主侧必须显式对齐，否则容器写不出 `state/`、读不到 CA 私钥。
`scripts/align-host-perms.sh`（localize 流程会自动跑）把 `configs/center` 与 `artifacts/` 对齐成
属主=部署账号、属组=999、目录 2770(setgid)、私钥 640。

### 起来之后

- 管理页面：`http://<host>:${WEB_PORT}`（前面反代终止 TLS 后即 `https://<CENTER_DOMAIN>`）
- 中心 API：`http://<host>:${CENTER_PORT}`
- 管理 token：见上「密钥」里的 `center_admin_token`
- 起停与排查：

```bash
gops run start            # 或 docker compose -f sys/docker-compose.yml --project-directory . up -d
gops run status
gops run stop
```

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

# 跳过 cargo build：
./dev/svc.sh start center --no-build
```

起完后：

- 管理页面 `http://127.0.0.1:5173`（vite dev，`/api` 反代到中心 `https://127.0.0.1:3100`）
- 中心 API `https://127.0.0.1:3100`（dev **默认 TLS**：自签 CA-S + 服务器证书；`WIST_CENTER_TLS=0` 可关成明文 HTTP）
- **管理 token**：首次启动生成在中心配置文件里（`~/.wist-center/wist-center.toml`），之后每次启动
  复用同一份并打印 —— 不再每次变。填入管理页面即可开启 5s 轮询刷新
- 日志：`/tmp/wist-center.log`、`/tmp/wist-center-web.log`

开发态仍用 `wist-center init-config` 生成 `~/.wist-center/wist-center.toml`（随机 admin token /
hmac secret）；发布态不用它，改走上面的 gops 密钥。

> **接入本机网关（dev 快速路）**：把本机网关栈接到这个中心，用 `wist-gateway-stack` 仓的
> `./dev/link_local_center.sh` —— gwlinkd 是网关**宿主侧**常驻、随网关走，所以它归那仓而非本仓。
> 产品路径是网关页面「链接上级」；CLI 只是 dev 捷径。

前端如果没有装依赖，先执行一次：

```bash
(cd ../wist-center-web && npm install)
```

## 制品包（发布）

打 tag（`v*.*.*`）时 `.github/workflows/release.yml` 用 `git archive` 把**整仓（除 `.github`）**
打成 `wist-center-stack-<tag>.tar.gz` 挂到 Release，供 `gops prj import` / 中心作为版本制品引用。
`sys/merged_vars.yml` 随仓入库、进包，所以 CI 里不必现算 —— 但改了 `sys/setting/vars.yml` 后，
本地要跑一次 `gops sys update` 并把 `merged_vars.yml` 的变更一起提交。

版本以仓库根 `version.txt` 为权威，用 `gx adm v_patch` / `v_feat` 升级、`gx adm tag_alpha` 打标签。

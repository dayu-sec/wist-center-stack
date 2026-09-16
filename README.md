# wist-center-stack

`wist-center`（中心后端） + `wist-center-web`（管理前端） 的一站式编排。

## 两种运行方式

- **开发态**（当前已可用）：不依赖镜像，直接跑本地编译的二进制 + vite dev（`sysrun/`）。
- **发布态**（待补）：Docker 编排，`docker compose up -d` 拉起整个栈 —— **尚未提供**。

> **发布态进展**：镜像能力已就绪 —— `wist-center` 补了 `docker/Dockerfile`，`wist-center-web`
> 也有 Dockerfile，两个仓的 release 流水线在打 tag 时会构建多架构镜像并**双推**
> `ghcr.io/dayu-sec/*` 与 `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内拉取快）。
> 但**镜像要等发一次 tag 才存在**，此刻还没有，所以本仓暂不写 `center` / `web` 两个服务，
> 避免出现“引用不存在镜像”的编排。
>
> 补齐时与 `wist-gateway-stack` 同构，两处要特别处理：
>
> - `center`：挂载配置目录（`wist-center.toml` + state），且容器内 `listen_addr` 必须是
>   `0.0.0.0:3100`（代码默认 `127.0.0.1:3100`）；
> - `web`：nginx 静态托管 + `/api` 反代到 `center`，站点配置需自备（镜像内不含）。
>   中心自身不做 TLS，对外 HTTPS 由前面的反代终止，`public_url` 的 host 要落在服务器证书 SAN 内。
>   端口需与网关栈的 `8443` 避让。

## 组件

| 服务 | 作用 | 端口 | 来源 |
|---|---|---|---|
| `center` | 中心后端（HTTP API） | 开发态本地 `3100` | `wist-center`，本地 `cargo build` |
| `web` | 管理前端（开发态 vite dev；容器态将改为 nginx 静态 + `/api` 反代） | 开发态本地 `5173` | `wist-center-web`，本地 `npm run dev` |
| `postgres` | 中心存储（`PgStore`；不可达时中心退回 JSON 文件存储） | `55432:5432` | `postgres:16` |
| `victoria-metrics` | 状态历史时序库 | `28429:8428` | `victoriametrics/victoria-metrics` |

两处**有意不做**：

- **不含 WarpParse（数据面）**：ELT 是网关/数据侧的事，中心不消费日志（`wist-center` 自带 compose 也只有 postgres + VM）。
- **不含对象存储**：中心的版本发布制品默认落本地 `artifact_dir`；需要 S3 兼容存储时再配 `WARP_INSIGHT_CENTER_OBJECT_STORAGE_*`。

> **端口避让**：本栈的 VictoriaMetrics 用 `28429`，**刻意避开** `wist-gateway-stack` 的 `18429`——
> 两个栈同机同时运行是常态，各自跑独立实例（都是开发/测试态，不共享）。其余端口与网关栈
> （`3000` / `5174`）也不冲突：中心栈是 `3100` / `5173` / `55432`。
> 宿主端口都可用 `PG_PORT` / `VM_PORT` 覆盖（在 `sysrun/start.sh` 与 `docker-compose.yml` 里同名同值）。

## 目录

```
wist-center-stack/
  docker-compose.yml       # 仅第三方依赖（postgres / victoria-metrics），开发态复用
  sysrun/                  # 开发态：本地二进制 + vite
    lib.sh                 # 公共函数（下面几个入口脚本 source 它）
    start-deps.sh / stop-deps.sh      # 第三方依赖
    start-center.sh / stop-center.sh  # 中心后端
    start-web.sh    / stop-web.sh     # 管理前端
    start.sh                          # 一键：center + web
    gen-center-ca.sh                  # 控制中心 CA 信任根 + 服务器证书（一次性生成，手动跑）
  README.md
```

> **数据目录**：开发态的本地 JSON store 与制品镜像落在 `wist-center-stack/.run/center/`
> （已 gitignore），与运行期临时产物同处；清 `.run` 只丢本地数据，不影响 PostgreSQL 里的数据
> （探测到 PG 可达时用 `PgStore`，否则才退回文件存储）。

## 开发态（本地二进制）

```bash
# 1. 第三方依赖（用 Docker 起；不起也能跑，只是退回文件存储且不推时序）
./sysrun/start-deps.sh   # PostgreSQL 55432 + VictoriaMetrics 28429
#                         # 也可只起其中一个：./sysrun/start-deps.sh postgres

# 2. 后端与前端各自独立，可单独起/停/重启
./sysrun/start-center.sh
./sysrun/start-web.sh

# 或者一条命令起两个：
./sysrun/start.sh

# 停止：前台跑的直接 Ctrl+C；后台起的、或终端已经关了就用
./sysrun/stop-center.sh
./sysrun/stop-web.sh
```

`start-*.sh` 会把自己拉起的 pid 写进 `.run/center.pid` / `.run/web.pid`，`stop-*.sh` 据此停服
（会校验 pid 确实指向目标进程，防 pid 复用误杀）；pidfile 失效时退化为按监听端口找进程
（这一层同时兜住 `npm run dev` 派生的 node/vite 子孙进程）。外部停掉后，前台那个 `start-*.sh`
会因为 `wait` 返回而自己退出并收尾。

三个入口脚本各自对应一个进程，互不依赖：`start-web.sh` 在中心没跑时也能起
（前端会回退到内置 example 数据）；`start-center.sh` 在依赖没跑时也能起（退回文件存储、不推时序）。

起完后：

- 管理页面 `http://127.0.0.1:5173`（vite dev，`/api` 反代到中心）
- 中心 API `http://127.0.0.1:3100`
- **管理 token**：首次启动生成在中心配置文件里（`~/.wist-center/wist-center.toml`），
  之后每次启动复用同一份并打印 —— 不再每次变。填入管理页面即可开启 5s 轮询刷新
- 日志：`/tmp/wist-center.log`、`/tmp/wist-center-web.log`

中心配置：`start-center.sh` 会在配置文件不存在时调 `wist-center init-config` 生成一份
（随机 admin token / hmac secret），已存在则直接复用；运行态（监听地址、存储与制品目录、
PG / VM 地址）仍由脚本用 env 覆盖。所以：改 token 就改配置文件，删配置文件 = 重新生成凭据
（已发出去的 token 随之失效）。详见 wist-center 仓库 README 的 Configuration。

env 覆盖项（每个脚本头部也各自列了一份）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WEB_URL` | `http://127.0.0.1:5173` | 前端地址，端口跟随它 |
| `WIST_CENTER_CONFIG` | `~/.wist-center/wist-center.toml` | 中心配置文件路径（不存在则用 `init-config` 生成） |
| `WARP_INSIGHT_CENTER_LISTEN` | `127.0.0.1:3100` | 中心监听地址（也决定前端的 `/api` 反代目标） |
| `WARP_INSIGHT_CENTER_ADMIN_TOKEN` | 取配置文件里的值 | 管理面 token；显式设置则覆盖配置文件 |
| `WARP_INSIGHT_CENTER_HMAC_SECRET` | 取配置文件里的值 | RegistToken 派生密钥；显式设置则覆盖配置文件 |
| `WARP_INSIGHT_CENTER_DATABASE_URL` | 探测 `PG_PORT` | PostgreSQL DSN；未设置→探测，显式置空→文件存储 |
| `WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL` | 探测 `VM_PORT` | 时序库地址；未设置→探测，显式置空→不推送 |
| `PG_PORT` / `VM_PORT` | `55432` / `28429` | 依赖服务的宿主端口；同时决定探测端口与容器端口映射 |

前端如果没有装依赖，先执行一次：

```bash
(cd ../wist-center-web && npm install)
```

## 发布态（待补）

见开头「发布态为什么还没做」。补齐后形态与 `wist-gateway-stack` 同构：`docker compose up -d`
拉起 `center` + `web` + `postgres` + `victoria-metrics`，前端入口走 nginx（静态 + `/api` 反代到
`center`），容器配置通过挂载注入。届时前端端口需与网关栈的 `8443` 避让。

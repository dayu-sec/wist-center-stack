# wist-center-stack

`wist-center`（中心后端） + `wist-center-web`（管理前端） 的一站式编排。

## 两种运行方式

- **开发态**（当前已可用）：不依赖镜像，直接跑本地编译的二进制 + vite dev（`sysrun/`）。
- **发布态**（待补）：Docker 编排，`docker compose up -d` 拉起整个栈 —— **尚未提供**，原因见下。

> **发布态为什么还没做**：`wist-gateway-stack` 能直接 `docker compose up -d`，是因为它引用的两个镜像
> 真实存在（`ghcr.io/dayu-sec/wist-gateway`、`ghcr.io/dayu-sec/wist-gateway-web`，两个仓库各有
> `Dockerfile` 且 release 流水线会推镜像）。中心这边 `wist-center` 与 `wist-center-web`
> **都还没有 Dockerfile**，也就没有镜像可引用（`wist-center` 的 release 流水线目前只出二进制
> tarball）。所以本仓暂不写 `center` / `web` 两个服务，避免出现"引用不存在镜像"的编排。
> 待两个 Dockerfile + 镜像 job 就绪后补齐即可。

## 组件

| 服务 | 作用 | 端口 | 来源 |
|---|---|---|---|
| `center` | 中心后端（HTTP API） | 开发态本地 `3100` | `wist-center`，本地 `cargo build` |
| `web` | 管理前端（开发态 vite dev；容器态将改为 nginx 静态 + `/api` 反代） | 开发态本地 `5173` | `wist-center-web`，本地 `npm run dev` |
| `postgres` | 中心存储（`PgStore`；不可达时中心退回 JSON 文件存储） | `55432:5432` | `postgres:16` |
| `victoria-metrics` | 状态历史时序库 | `18429:8428` | `victoriametrics/victoria-metrics` |

两处**有意不做**：

- **不含 WarpParse（数据面）**：ELT 是网关/数据侧的事，中心不消费日志（`wist-center` 自带 compose 也只有 postgres + VM）。
- **不含对象存储**：中心的版本发布制品默认落本地 `artifact_dir`；需要 S3 兼容存储时再配 `WARP_INSIGHT_CENTER_OBJECT_STORAGE_*`。

> **端口避让**：本栈的 VictoriaMetrics 用 `18429`，与 `wist-gateway-stack` 相同。两者同机同时运行时
> 会撞端口 —— 各自是独立实例，需手动改一边的映射。中心栈的 `3100` / `5173` / `55432` 与网关栈
> （`3000` / `5174` / 无 PG）不冲突。

## 目录

```
wist-center-stack/
  docker-compose.yml       # 仅第三方依赖（postgres / victoria-metrics），开发态复用
  sysrun/                  # 开发态：本地二进制 + vite
    start.sh               # 中心两件套（center + web）
    start-pg.sh / stop-pg.sh
    start-vm.sh / stop-vm.sh
  README.md
```

> **数据目录**：开发态的本地 JSON store 与制品镜像落在 `wist-center-stack/.run/center/`
> （已 gitignore），与运行期临时产物同处；清 `.run` 只丢本地数据，不影响 PostgreSQL 里的数据
> （`start.sh` 探测到 PG 可达时用 `PgStore`，否则才退回文件存储）。

## 开发态（本地二进制）

```bash
# 1. 第三方依赖（用 Docker 起；不起也能跑，只是退回文件存储且不推时序）
./sysrun/start-pg.sh      # PostgreSQL 55432
./sysrun/start-vm.sh      # VictoriaMetrics 18429

# 2. 中心两件套
./sysrun/start.sh
```

起完后：

- 管理页面 `http://127.0.0.1:5173`（vite dev，`/api` 反代到中心）
- 中心 API `http://127.0.0.1:3100`
- **管理 token**：`start.sh` 每次启动随机生成并打印，填入管理页面即可开启 5s 轮询刷新
- 日志：`/tmp/wist-center.log`、`/tmp/wist-center-web.log`

`start.sh` 读取的 env 覆盖项：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WEB_URL` | `http://127.0.0.1:5173` | 前端地址，端口跟随它 |
| `SKIP_WEB=1` | – | 只起中心后端 |
| `WARP_INSIGHT_CENTER_LISTEN` | `127.0.0.1:3100` | 中心监听地址 |
| `WARP_INSIGHT_CENTER_ADMIN_TOKEN` | 随机生成 | 管理面 token；显式指定可让多次启动保持一致 |
| `WARP_INSIGHT_CENTER_HMAC_SECRET` | 随机生成 | RegistToken 派生密钥（轮换不影响既有凭据，中心只存派生结果） |
| `WARP_INSIGHT_CENTER_DATABASE_URL` | 探测 `55432` | PostgreSQL DSN；未设置→探测 `PG_PORT`，显式置空→文件存储 |
| `WARP_INSIGHT_CENTER_VICTORIAMETRICS_URL` | 探测 `18429` | 时序库地址；未设置→探测 `VM_PORT`，显式置空→不推送 |
| `PG_PORT` / `VM_PORT` | `55432` / `18429` | 未显式给 URL 时的探测端口 |

前端如果没有装依赖，先执行一次：

```bash
(cd ../wist-center-web && npm install)
```

## 发布态（待补）

见开头「发布态为什么还没做」。补齐后形态与 `wist-gateway-stack` 同构：`docker compose up -d`
拉起 `center` + `web` + `postgres` + `victoria-metrics`，前端入口走 nginx（静态 + `/api` 反代到
`center`），容器配置通过挂载注入。届时前端端口需与网关栈的 `8443` 避让。

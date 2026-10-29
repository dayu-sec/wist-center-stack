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
| `center` | 中心后端（HTTP API；规则发布兼容入口） | `${CENTER_API_HOST_PORT}:3100`<br>`${WPARSE_PROXY_HOST_PORT}:3101` | `${CENTER_REGISTRY}/wist-center:${CENTER_IMAGE_TAG}` |
| `web` | 管理前端入口（nginx：**终止 TLS** + 静态 + `/api` 反代到 center） | `${WEB_HOST_PORT}:443`（**HTTPS**） | `${CENTER_REGISTRY}/wist-center-web:${CENTER_WEB_IMAGE_TAG}` |
| `postgres` | 中心存储（PgStore） | `${PG_HOST_PORT}:5432` | `${PG_REGISTRY}/postgres:${PG_IMAGE_TAG}` |
| `victoria-metrics` | 状态历史时序库 | `${VM_HOST_PORT}:8428` | `${VM_REGISTRY}/victoria-metrics:${VM_IMAGE_TAG}` |
| `db-init` | 一次性：创建 `center_app` 角色与库，收紧 `CONNECT` | 无 | `${PG_REGISTRY}/postgres:${PG_IMAGE_TAG}` |
| `db-schema` | 一次性：以 `center_app` 幂等套一遍 `sys/db/initdb/01_schema.sql` | 无 | `${PG_REGISTRY}/postgres:${PG_IMAGE_TAG}` |
| `git-proxy` | Gateway 只读拉取外部 Git 的 Git 反代（路径白名单） | `${GIT_PROXY_HOST_PORT}:8443` | `${GIT_PROXY_REGISTRY}/nginx:${GIT_PROXY_IMAGE_TAG}` |

> `db-schema` 是**一次性任务**（exit 0 即完），`center` 依赖 `db-init` / `db-schema`
> `service_completed_successfully`。存在原因：`docker-entrypoint-initdb.d` **只在空 data 卷首次
> 初始化时**执行，之后 `01_schema.sql` 的改动（新增列）到不了已有库；而该文件全是
> `CREATE/ALTER … IF NOT EXISTS`，每次套一遍是安全的。

> **镜像两处源**：wist\* 镜像由发布流水线双推 —— `ghcr.io/dayu-sec/*`（境外）与
> `dy-sec.tencentcloudcr.com/cloud/*`（腾讯云 TCR，国内快）。compose 里的镜像源与 tag 都是变量：
> 改**产品默认**改 `sys/setting/vars.yml`，改**本环境用什么**改 ops-prj 的
> `values/<系统名>/sys_value.yml`（推荐；本仓不再跟踪 `values/`）。
>
> **上游镜像**：`nginx` 不在 TCR 里（`postgres` / `victoria-metrics` 同样来自上游）；
> 发布前用 `./dev/push-images.sh --dry-run` 检查、需要时实推（脚本会自动从 compose 取镜像）。
>
> **TLS + 两个域名、两个面**：`web` nginx 在容器内 **443** 上终止 TLS（证书 = 站点身份
> `identity/center/control-center-server.{crt,key}`，由站点 CA 签，SAN 覆盖 `WEB_WGC_DOMAIN` /
> `API_WGC_DOMAIN`；`scripts/init-center.sh` 幂等备齐），宿主发布到
> **`${WEB_BIND_IP}:${WEB_HOST_PORT}`**（默认回环）：
> - `WEB_WGC_DOMAIN`——**管理面 / Web UI**（浏览器）；
> - `API_WGC_DOMAIN`（默认 `api.<WEB_WGC_DOMAIN>`）——**网关面**：gwlinkd 直连 `:3100`（mTLS），
>   Gateway 从 `:18082` 拉仓库；`public_url` 用的也是它。
>
> `center` 自身在容器内跑 **HTTPS**：`:3100` 只挂网关面路由，`:3102` 只挂管理面路由（两者互斥）。
> Web 的 `/api` 反代到 `:3102`。两个域名都必须能解析到本机，且在服务器证书 SAN 内。
> `git-proxy` 复用同一张证书，server_name = `API_WGC_DOMAIN`，Gateway 用 Center CA 校验。
>
> **端口避让**：本栈 VictoriaMetrics 用 `28429`、前端入口 `2443`、Git Proxy `18082`、
> wparse-proxy `18083`、管理面 `3102`，**刻意避开** `wist-gateway-stack` 的 `18429` / `8443` / `9000`
> —— 两个栈同机同时运行是常态，各自跑独立实例。
>
> **Web 入口**：`web` nginx 在同一个 `${WEB_HOST_PORT}` 上只服务 `<WEB_WGC_DOMAIN>`（中心前端）。

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
      git-proxy/nginx.conf.tpl          # Center Git Proxy 模板（渲染出 configs/git-proxy/nginx.conf）
  # 注：本仓**不含** values/ —— 现场值由 ops-prj 维护在 <ops-prj>/values/<系统名>/sys_value.yml
  configs/                  # 运行期配置（现场生成，不入 git / 不入包）
    center/                 # 发布态：wist-center.toml（由模板渲染）+ state/（JSON store）+ logs/（中心日志）
    web/                    # 发布态：nginx.conf（由模板渲染）
    git-proxy/              # Git Proxy 渲染物（nginx.conf + value.json；含 Git 读凭据，600）
  identity/                 # 站点身份 + 现场态（dev/prod 共用，含私钥，不入 git / 不入包）：
                            #   center/（CA + 服务器证书/私钥 + wist-center-pub.toml 声明 + .env 值）
  artifacts/                # 制品镜像（版本发布下载下来的安装包；本地数据，不入 git / 不入包）
  .wist/                    # 运行期密钥（现场生成，不入 git）：
                            #   sec-value.yml（admin token / hmac secret / DB app 密码 / Git 读写 token）
  scripts/                  # 发布态初始化脚本（幂等；由 localize 阶段流程调用）
    lib/sec.sh              # 宿主机侧密钥读取的唯一入口（转调 `gops sec get`，见下）
    gen-center-ca.sh        # 控制中心 CA + 服务器证书（一次性，手动或由 init-center 调用）
    init-center.sh          # 中心配置渲染值 + CA 备料 + center.env（center_app）+ 密钥文件
    ensure-center-server-cert.sh  # 服务器证书（叶）SAN 覆盖对外域名（幂等重签，不动 CA）
    init-center-pub.sh      # 现场态**值**（CENTER_PUBLIC_URL）→ identity/center/.env（按缺补齐）
    init-web-conf.sh        # 前端站点配置的渲染值（幂等；域名取 WEB_WGC_DOMAIN）
    init-git-proxy-conf.sh  # Git Proxy 渲染值（路径白名单 / 上游读凭据 / 客户端证书策略）
    check-stack.sh          # 栈级配置检查薄壳（选本机 triple 的预编译件；开发态回落 cargo run）
    db-init.sh              # 一次性：创建 center_app 角色与库，收紧 CONNECT
  tools/stackcheck/          # 本栈 profile + TLS 策略（通用引擎在 wist-stack-tools/stackcheck-core）
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
>   `center/` 下是中心 CA / 服务器证书 / 私钥 + `wist-center-pub.toml` 声明 + `.env` 值。整体作**对外契约**
>   （`sys-prj.yml` 的 `contract: - identity`），不随资源树被升级覆盖；compose 只读挂载其中需要的文件。
>   丢了中心 CA 私钥 = 换锚（所有网关要重发信任根），故备份/迁移必带它。
>   **备份走 `gops prj contract export`**（产物在 `ops-prj.yml: contract.target`）：`gops prj backup`
>   **只收 `sys-prj.yml: backup` 表里的 `configs/` + `.wist/`，不含 `identity/`** —— 两者是两条
>   互不合并的通路。归档含私钥，请收紧权限并离机保存。
> - **制品镜像统一落 `<栈根>/artifacts/`**（开发态与发布态同一个位置；发布态由 compose 挂到容器
>   `/wist-center/artifacts`）—— 它是发布时下载/镜像下来的安装包，属数据、不属配置，故与 `configs/`
>   分开（便于单独备份；哪些进 `gops prj backup` 见 `sys-prj.yml` 的 `backup:` 表）。
> - 发布态配置落挂载卷 `configs/center/`（`state/` 存 JSON store；用 PostgreSQL 时不用）。

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
| `gops run diagnose` | `docker compose config` + `flow diagnose`（追加 `checks[]`，含栈级配置 15 项） |

### 前置：主机要求

| 项 | 要求 | 怎么验 |
|---|---|---|
| Docker + Compose V2 | `docker compose` 是 **CLI 插件**；只有老的 `docker-compose` v1 不够 | `docker compose version` 能打印 `v2.x` |
| gops | **必须 ≥ 2.9**（`secrets.mode` / `perms.services` 需要；旧版会在解析 `sys-prj.yml` 时失败） | `gops -V` |
| gx | **≥ 0.14**（`localize` 阶段流程；缺失时 `localize` 只写 `.env`，权限 `--apply` 也不会执行） | `gx -V` |
| 执行账号 | 普通账号 + **已加入 `docker` 组**；部署目录由它拥有 | `id -nG`（输出里应含 `docker`） |
| 端口 | 宿主 `${CENTER_API_HOST_PORT}` / `${WPARSE_PROXY_HOST_PORT}` / `${WEB_HOST_PORT}` / `${PG_HOST_PORT}` / `${VM_HOST_PORT}` / `${GIT_PROXY_HOST_PORT}` | 见 `sys/setting/vars.yml` |

### 变量与本地化

**一条规则：现场值写在 ops-prj 的 `values/<系统名>/sys_value.yml`（不在本仓），改完跑 `gops sys localize` 即生效** ——
不需要 `update`，也不用动 `sys/merged_vars.yml`。覆盖值会在同一次 localize 内一致地进入 `.env`
与渲染出的配置（`wist-center.toml` / `nginx.conf`）。

```bash
vim <ops-prj>/values/wist-center-stack/sys_value.yml   # 改域名 / 宿主端口等现场值
gops sys localize         # 一条命令：渲染配置 + 导出 .env（compose 读它）
```

`sys/setting/vars.yml` 是**产品默认值**（随仓走的基线），现场一般**不用碰**。确实要改产品默认时：

```bash
gops sys update           # 解析 vars.yml → sys/merged_vars.yml（入库，要一起提交）
gops sys localize
```

**`localize` 还会跑项目自己的阶段流程**：本栈把它定义在 `sys/workflows/operators.gxl`
（**本地定义**，不引外部 ops-gxl），由 `_gal/work.gxl` 的 `mod main : operators` 纳入；合并后的值以
**环境变量**注入该流程（用 `$(printenv XXX)` 读）。流程里做七件**幂等**的事：

1. 确保 `configs/center`、`configs/web`、`configs/git-proxy`、`identity/center`、`artifacts` 存在；
2. 备料控制中心：CA（信任根 + 服务器证书，落站点身份 `identity/center/`）+ 渲染值
   `configs/center/wist-center.value.json` + `configs/center/center.env`
   （`center_app` 的 PG 凭据，600；`scripts/init-center.sh`，密钥缺失/为空直接报错）；
   再**渲染现场态声明** `identity/center/wist-center-pub.toml`（`gx.tpl`，只有 `${VAR}`、可重渲）
   并由 `scripts/init-center-pub.sh` 按缺补齐**现场态值** `identity/center/.env`（永不重渲）；
3. 渲染 `configs/center/wist-center.toml`（模板在 `sys/configs/center/wist-center.toml.tpl`）；
4. 备料 Git Proxy：读 `.wist/sec-value.yml` 的 `wp_git_pub_token` / `wp_git_pub_user`
   （只读，不生成不补键；center 侧缺 token 会直接报错，Git Proxy 侧缺则降级为「不带上游鉴权头」并告警），
   由 `scripts/init-git-proxy-conf.sh` 写 `git-proxy.value.json`，再渲染 `configs/git-proxy/nginx.conf`；
5. 写前端站点配置的渲染值 + 渲染 `configs/web/nginx.conf`（`scripts/init-web-conf.sh` + 模板）；
6. **宿主属主/权限对齐**（`gops sys perms --apply`，gops ≥ 2.7；见下「权限与运行身份」；非 Linux 自动跳过）——
   必须在 `docker compose up` **之前**：Docker 会把缺失的挂载源目录自行建成 `root:root`，
   属主一旦是 root，之后的部署账号就写不动了。
7. **配置守门**（`scripts/check-stack.sh --gate`）：刚渲染完就自检，**阻断类 FAIL 直接让 localize 失败**。
   `gops prj upgrade` 的 `regenerate` 阶段调用的就是 `gops sys localize`，所以错误的渲染会在
   `pull` / `up` 之前暴露并触发回滚。判据见下「栈级配置检查」。

`gops sys localize --no-flow` 可跳过该流程；未装 gx 或无该流程时静默跳过（此时权限 `--apply` 也不会执行，
但 `gops run start` 的 preflight 会拦住未对齐的启动）。

#### 规则 / 配置仓库地址（本栈不带客户地址）

`WP_RULES_REPO_URL` / `WP_INFRA_REPO_URL` 的产品默认值是**空** —— 模板里不写任何客户 / 仓库路径。
两项都留空时中心可以正常启动，只是**规则能力不可用**：

| 留空时 | 表现 |
|---|---|
| `[wparse_release]` | `enabled = false` → 发布页没有 ④ wparse-rules / ⑤ wparse-infra |
| Git Proxy 白名单 | 为空 → `info/refs` 等一律拒绝，网关 `project_remote` 拉不到规则 |
| 包发布 / 网关管理 | 不受影响 |

要启用时在 values 里补（示例，两个仓库必须**同主机**）：

```yaml
# <ops-prj>/values/wist-center-stack/sys_value.yml
WP_RULES_REPO_URL: https://cnb.cool/<组>/<项目>/wp-rules
WP_INFRA_REPO_URL: https://cnb.cool/<组>/<项目>/wp-infra
```

- `localize` 会打一行提示（`wparse_release 关闭` / `Git Proxy 白名单为空`），不是报错；
- 只配一个时发布入口保持关闭、Git Proxy 只放行已配的那个，并打印告警；
- 模板里 `provider` 固定为 `cnb`（GitHub / manual 需要改中心的 `[wparse_release.repos]`）；
- **升级注意**：老现场若一直靠默认值（values 里没写这两项），升级后会被置空 —— 升级前先显式写上。

#### 脚本读密钥的唯一入口

宿主机侧的初始化脚本不自己解析 `.wist/sec-value.yml`，统一 `source scripts/lib/sec.sh` 后调：

```bash
pw="$(sec_get "${STACK_ROOT}" center_db_password)"      # 缺失/文件不合格 → 报错退出
maybe="$(sec_get_optional "${STACK_ROOT}" some_key)"    # 键缺失 → 空串；文件本身不合格仍报错
```

它转调 `gops sec get --show`（**需 gops ≥ 2.8**），因此路径解析（`sys-prj.yml: secrets.file`）、
权限/属主/硬链接校验、值类型校验与运行期注入完全同一套规则，脚本侧不再有第二份解析实现。

脚本也**不写**密钥文件：`.wist/sec-value.yml` 完全由运维提供（0640：属主=部署账号、属组=容器 gid 999；
对应 `sys-prj.yml: secrets.mode: "0640"`），`gops sys localize` 只校验，
不生成、不补键、不迁移、不改 mtime。

例外：`scripts/db-init.sh` 在 **postgres 容器里**执行（容器内没有 gops，且挂载文件属主是宿主账号），
保留最小解析，见脚本内的说明。

### 密钥（运维输入）

> **需要 gops ≥ 2.9.0**：`sys-prj.yml: secrets.mode` 是新字段，2.8.0 的
> `secrets` 节会拒绝未知字段。升级 gops 后再部署本版本。

密钥统一放栈根 `.wist/sec-value.yml`（0640：属主=部署账号、属组=容器 gid 999），**由运维预先提供**。
共享靠属组、不靠改属主：部署账号按 owner 读，center(999) 按 group 读；**不需要 root 运行 gops**。
`gops sys localize` 只做校验：
缺失或为空直接报错（连同可用的键名一起列出），**不生成、不补键、不迁移、不写文件**。

```yaml
# <栈根>/.wist/sec-value.yml（权限 0640：属主=部署账号、属组=999）
center_admin_token: <中心管理面 token>
center_hmac_secret: <RegistToken 派生密钥>
center_db_password: <center_app 的 PG 密码>        # 不能是纯数字

# 外部 Git 只读凭据（Git Proxy 用；供 Gateway 拉取仓库）
wp_git_pub_user: <读账号>
wp_git_pub_token: <读 token>
```

Git Proxy 把 `wp_git_pub_*` 注入 `WP_GIT_AUTH_HEADER`（默认 `Authorization: Basic ...`）写进
`configs/git-proxy/nginx.conf`；换 Git 提供商时只改 URL 与可选的头名，不改变量名。

CNB 的权限坑（实测）：token 必须带 **`repo-code:r`**（读），作用域要覆盖 **两个仓库**
（建在两个仓库的公共上级组上即可，例如 URL 是 `<组>/<项目>/wp-*` 就建在 `<组>` 上）。
作用域不含某仓库时 CNB 返回 `Repository Not Found`（而不是 403），容易误判成“仓库写错”。

- 中心配置里只写 `${SEC_CENTER_*}` 占位，由 `WIST_CENTER_SEC_FILE` 指向本文件解析；
- `db-init` 从本文件读取 `center_db_password`，创建角色并收紧 `CONNECT`；
- `center_db_password` **不能是纯数字**（避免被配置加载层的 `try_parsing` 误判类型）；脚本会直接拒绝。

外部 Git 凭据**只从** `.wist/sec-value.yml` 读取（不要写进 `values/` 或 `vars.yml`）。
然后跑 `gops sys localize`：流程从该文件读取这两个键（缺失/为空直接报错），
渲染 `configs/git-proxy/nginx.conf`。密钥文件是 0640（属主=部署账号、属组=999）、
已在 `.gitignore` 里，不会进 shell history / 进程列表。

> 一次性前置（管理员）：部署账号加入 gid 999（`usermod -aG 999 <deploy>`），`.wist` 用 setgid
> 让新建文件继承该组。**不要**把密钥 chown 给 999，也不需要 sudo 运行 gops。
>
> 同一份 `sys-prj.yml` 还声明了 `perms.services.postgres: {uid: 999, gid: 999}`：官方 postgres
> 以 root 启动、`gosu` 到 999 后才读 `/docker-entrypoint-initdb.d`；让 `gops sys perms` 按 999
> 对齐该目录（否则它会被当作 root 服务跳过）。

> CI 场景：先由部署账号把密钥文件写到目标机（0640，属组=999），再跑 `gops sys localize`。
> token **不接受**环境变量注入。

> **改完 token 后要重建容器**：`configs/git-proxy/nginx.conf` 是单文件 bind mount（原子替换后 inode 变）。
> `gops run start` 本质是 `docker compose up -d`，**不保证**重建；请显式执行：

```bash
docker compose --project-directory . -f sys/docker-compose.yml \
  up -d --force-recreate git-proxy
```

#### Git Proxy 的短路径（`/<repo>` 也能拉）

两个仓库 URL 的**公共上级目录**会被自动补上。例如仓库是 `cnb.cool/<组>/<项目>/wp-*`，
公共上级就是 `<组>/<项目>`，于是下面两种写法等价（`git clone` 都可以）：

```text
https://<wp-git>:18082/<组>/<项目>/wp-infra
https://<wp-git>:18082/wp-infra
```

- 留空 = 自动推导；`GIT_PROXY_SHORT_PREFIX=off` 关闭；也可以显式写一个前缀
  （必须**同时**是两个仓库的前缀，否则只告警并关闭别名，不阻断 localize）。
- **白名单没有变宽**：别名命中后 `rewrite ... last` 回到同一组全路径 location，仍然只放行
  「两个仓库 × `info/refs` / `git-upload-pack` / `HEAD`」；`/wp-infra/objects/...` 之类仍是 404，
  仍然没有「带 CNB token 的通用反代」。
- 网关侧 `WPARSE_PROJECT_MODELS_REPO` / `WPARSE_PROJECT_INFRA_REPO` 可以随之写短地址。
  **升级顺序：先升 Center（本栈），再改网关侧的值** —— 旧 Center 不认短路径。

#### Git Proxy 的客户端认证（mTLS）

网关的客户端证书由 **CA-G** 签发（`identity/center/gateway-client-ca.pem`），与中心网关面 `:3100`
是**同一套 per-gateway 身份**（URI SAN = `gateway_id`，有效期约 30 天）；证书与私钥在网关侧
`identity/gwlinkd/credential.json`。中心侧只挂 CA-G 的**公钥证书**（不挂私钥），行为由一个变量控制：

| `GIT_PROXY_CLIENT_CERT_VERIFY` | 行为 |
|---|---|
| `off`（默认） | 只验服务端证书（与旧行为一致） |
| `optional` | 验链但放行，只把结果记进日志（灰度用） |
| `on` | 未带证书或验链失败 → 拒绝 |

灰度顺序：`off` → `optional` → `on`。access log 已带 `verify=$ssl_client_verify`
（`NONE` = 没带证书 / `SUCCESS` / `FAILED:...`），`optional` 阶段直接统计覆盖率再切 `on`。

> 日志落在容器内 `/var/log/nginx/access.log`：compose 把 `/var/log/nginx` 挂成 tmpfs，
> 所以 **`docker logs` 看不到**，要这样读：
> ```bash
> docker exec wist-center-stack-git-proxy cat /var/log/nginx/access.log | tail
> ```

> 换 `off → optional/on` 不需要重建容器以外的动作；但 `configs/git-proxy/nginx.conf` 是 bind mount，
> 同上面的 `--force-recreate git-proxy`。
>
> 尚未做：**撤销**（删掉一台网关后，它手里的证书最长还能用 30 天）—— 需要 `ssl_crl`
> 或更短有效期；见仓根 `TODO.md` P1。

#### 双 IP（可选）：让 Git Proxy 用 443、网关侧地址不带端口

一个 IP 的一个端口只能有一个监听者。所以「不用端口」靠的不是新域名，而是**第二个 IP**：

| 变量 | 主 IP（现状） | 双 IP（可选） |
|---|---|---|
| `CENTER_API_BIND_IP` | `0.0.0.0` | 主私网 IP，如 `10.168.0.149` |
| `CENTER_API_HOST_PORT` | `3100`（alpha 为 `443`） | `443` |
| `GIT_PROXY_BIND_IP` | `0.0.0.0` | 第二/辅助私网 IP，如 `10.168.0.150` |
| `GIT_PROXY_HOST_PORT` | `18082` | `443` |
| `GIT_PROXY_DOMAIN` | 留空（= `API_WGC_DOMAIN`） | `wp-git.<zone>` |

就是这四个**既有**变量，没有为双 IP 另造新名字。三个要点：

1. **绑私网 IP，不绑公网 IP**：云上公网 IP（EIP）是 NAT，不在网卡上；绑它会报
   `bind: cannot assign requested address`；
2. **两个 `*_BIND_IP` 必须不同且不能是 `0.0.0.0`**，否则 443 会冲突。`scripts/init-git-proxy-conf.sh`
   在 `localize` 阶段就会拦住并打印两种出路（不用等到 `compose up` 的 `EADDRINUSE`）；
3. **证书与网关侧要同步**：新域名要进 `EXTRA_SANS` 重签叶证书（CA 不动），
   且 `WPARSE_PROJECT_MODELS_REPO` / `WPARSE_PROJECT_INFRA_REPO` 要改成不带端口的地址。

> 叶证书 SAN 变化会**重新生成私钥**（`scripts/ensure-center-server-cert.sh`），
> 而 center / web / git-proxy 挂的是同一个证书文件 —— 三个容器要一起重启。
> 完整步骤与本阶段的取舍见仓根 `TODO.md` P1。

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
5. `configs/git-proxy/nginx.conf` —— Git Proxy 的完整 nginx 配置（只读挂到 `/etc/nginx/nginx.conf`）。
   含路径白名单与 Git 读凭据；由流程生成 value.json、`gx.tpl` 渲染，权限 600。
   证书复用 `identity/center/control-center-server.{crt,key}`。

### 权限与运行身份（Linux 必读）

`center` 镜像**固定以 `999:999` 运行**（镜像里 `useradd -r wist`；compose 里 `user:` 已显式钉死）。
bind 挂载在 Linux 上**不改变属主**，所以宿主侧必须显式对齐，否则容器写不出 `state/`、读不到 CA 私钥。

**统一入口是 `gops sys perms`（gops ≥ 2.7 引入，本栈硬要求 ≥ 2.9）**：

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
| center 拒启 | `failed to load secrets /secrets/sec-value.yml` | 密钥权限/属主不符：应为 `部署账号:999 0640` 且 `secrets.mode: "0640"`；或部署账号不在 gid 999 |
| center 不提供信任根 | 读 `ca/control-center.pem` / `*.key` 失败 | `identity/center` 未对齐（目录 2750 / 私钥 640） |
| 制品无法写入 | 上传 / 镜像落盘报错 | `artifacts/` 属主是 root（被 `docker compose up` 先建出来了） |

### 栈级配置检查（`wist-stackcheck`）

栈自己生成的配置互相矛盾时，组件往往不会报错：解析通过、进程起来、只有真用到那一项时才炸。
所以本栈带一个**只读**检查器（Rust，`tools/stackcheck`），在 localize 末尾与体检时跑：

```bash
./scripts/check-stack.sh                 # 人读：0 全好 / 1 有 WARN / 2 有 FAIL
./scripts/check-stack.sh --format json   # Flow Result v1
./scripts/check-stack.sh --gate          # 闸门：只有阻断类 FAIL 才非零退出（localize 用）
STACKCHECK_OFFLINE=1 ./scripts/check-stack.sh   # 离线站点：跳过镜像可达
```

它只查「栈自己生成的东西」；组件键的语义（取值 / 依赖 / 结构体归属）仍由组件自己的严格解析与
`diagnose` 负责。判据（15 项，全部只读）：

| code | 判什么 | 失败时阻断 |
|---|---|---|
| `config.vars` | `.env` / `sys/merged_vars.yml` 能读出变量 | ✓ |
| `render.freshness.{center,git-proxy,web,center-pub}` | 渲染产物不早于值文件/模板（改了值没重渲） | ✓ |
| `render.placeholder` | 渲染产物里没有 `example.com` / `warpinsight.example` 等占位值 | ✓ |
| `domain.configured` | `WEB_WGC_DOMAIN` / `API_WGC_DOMAIN` 不是默认占位值 | ✓ |
| `secret.file_mode` | `.wist`、`center.env`、含口令的渲染物没有 world 位 | ✓ |
| `secret.private_key_mode` | `identity/` 下私钥不对其他用户可读 | ✓ |
| `identity.center_files` | 站点身份（CA / 叶证书 / 私钥 / CA-G）齐全 | 部分（CA-G、CA 私钥不拦升级） |
| `tls.san_covers_domain` | 叶证书在有效期内，SAN **精确**覆盖两个域名 | ✓ |
| `layout.mounts` | compose 挂载 ↔ 变量展开 ↔ localize 实际落点三者一致，源存在 | ✓ |
| `layout.public_url` | 主配置不重复定义 `public_url`；`.env` 的 `CENTER_PUBLIC_URL` 与当前域名/端口一致 | 部分（重复定义拦；`.env` 漂移不拦） |
| `database.initdb` | `sys/db/initdb/01_schema.sql` 存在且非空 | ✓ |
| `port.available` | 排除本栈自己的容器后，宿主端口能 bind | ✓ |
| `image.reachable` | 镜像本地有或远端 manifest 可达 | ✗ |

> **生效值优先**：检查器读栈根 `.env`（`gops sys localize` 产物），只有它不存在时才回落
> `sys/merged_vars.yml` 并在结果里标明来源 —— 拿默认值去判会把合法的现场覆盖误判成错误。
>
> **不阻断 ≠ 不严重**：`image.reachable`、CA-G 缺失等是 FAIL（该修），但当前跑着的栈是好的，
> 不该因此拦下升级。阻断类只放「会让本次部署直接坏掉」的项。

发布包里带三平台预编译件（`bin/<triple>/wist-stackcheck`），`scripts/check-stack.sh` 按本机 triple 选；
开发态没有预编译件时自动回落 `cargo run`；**找不到可执行件直接退出 2**（静默跳过等于检查没做）。

**通用引擎在公共仓 [`wist-stack-tools`](https://github.com/dayu-sec/wist-stack-tools) 的
`stackcheck-core`**：已发布为 crates.io 的 `wist-stackcheck-core`；本仓只保留
`tools/stackcheck/src/profile.rs`（center 的路径/变量/挂载对）和 `checks.rs`（center 的
TLS 策略）。依赖按 `wist-stackcheck-core = "0.1"`（registry）固定。

> 升版本（`gx adm v_patch` / `v_feat`）只会改 `version.txt` 与带 marker 的 `Cargo.toml`，**不动 `Cargo.lock`**：
> 记得补一次 `cargo update -p wist-center-stackcheck --manifest-path tools/stackcheck/Cargo.toml`，
> 连同 `Cargo.lock` 一起提交，否则 CI 的 `--locked` 会失败。

### 起来之后

- 管理页面：`https://<WEB_WGC_DOMAIN>:${WEB_HOST_PORT}`（如 `https://wgc.dev.wist.lab:2443`；用站点 CA `identity/center/control-center.pem` 校验）
- 中心 API：`https://<host>:${CENTER_API_HOST_PORT}`（compose 配了服务器证书 → 中心本身就是 **HTTPS**；
  网关侧走 mTLS，浏览器/脚本可用 `-k` 或带站点 CA 校验证书）
- 管理 token：见上「密钥」里的 `center_admin_token`
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

`CENTER_API_HOST_PORT` / `WEB_HOST_PORT` 的**默认值（3100 / 2443）刻意避开了网关栈的 443 / 8443**；
现场把它们改成 443 / 8443 后就**不能与网关栈同机同时运行**（端口冲突，与容器名无关：
本栈容器名是 `wist-center-stack-*`，网关栈是 `wist-gateway-stack-*`）。

> 上面这些命令都在**系统根**（本目录，即 `.../wist-center-stack/`）执行。
> 在维护工程根（如 `wcenter-alpha/`）执行 `gops run start` 会被当成工程的 `main` 流程，
> 报 `Galaxy Flow Parse Error … detail: start` —— 不是栈坏了，是目录错了。

## 规则管理（WarpStation 集成已移除）

本栈**不再部署** wp-station / warp-toolchain，也不再创建 `station_app` 库/角色、不再提供
`station.*` 虚拟主机与 basic auth；`sys/sandbox/`、`knowledge/station/`、`configs/station/`
随之移除。规则/配置的编辑与沙盒验证改由外部流程承担。

Center 仍保留三项与规则发布相关、且**与 WarpStation 解耦**的能力：

| 能力 | 位置 | 说明 |
|---|---|---|
| tag 列表 | `[wparse_release]`（`sys/configs/center/wist-center.toml.tpl`） | 只读 CNB 仓库 tag；`WP_RULES_REPO_URL` / `WP_INFRA_REPO_URL` 配齐才启用 |
| 发布命令通道 | `wparse-proxy`（`${WPARSE_PROXY_HOST_PORT}:3101`）+ 命令队列 | 调用方投递命令 → `gwlinkd` 轮询 → 本机 `wparse` admin API |
| 仓库只读代理 | `git-proxy`（`${GIT_PROXY_HOST_PORT}:8443`） | Gateway 的 `project_remote` 从这里拉规则/配置 |

Gateway 侧要支持「从 Center 拉取规则」，仍需开启 `admin_api`（TLS）与 `project_remote`、
并用中心 CA 校验 Git Proxy 的服务器证书；字段见 `wist-gateway-stack` 的
`data-plane/conf/wparse.toml`。

## 开发态（本地二进制）

```bash
# 起全套（deps + proxy + center + web）：
./dev/svc.sh start

# 只起/另起某组件（deps | proxy | center | web），可组合：
./dev/svc.sh start center         # 只起后端
./dev/svc.sh start web            # 只起前端
./dev/svc.sh start deps           # 第三方依赖：PostgreSQL 55432 + VictoriaMetrics 28429
./dev/svc.sh start proxy          # Git Proxy 18082（发布 wparse-rules / wparse-infra 必需）
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

> **发布规则 / 配置必须起 `proxy`**：dev 的中心只负责**读 tag**（直连 CNB），真正把规则拉下来的是
> 网关里的 `wparse`，它走 `project_remote` 从 Git Proxy（`:18082`）拉 `wp-rules` / `wp-infra`。
> 不起 Git Proxy 时发布会在网关侧失败：`wparse 上游返回 500` / `Info: fetch remote tags failed`。
> Git Proxy 直接用发布态渲染好的 `configs/git-proxy/nginx.conf` + `identity/center/control-center-server.{crt,key}`，
> 缺这两份就先在发布态 `gops sys localize`（证书缺还要跑 `scripts/gen-center-ca.sh`）。

`deps` / `proxy` 刻意**复用发布态的容器**：两栈目录同名（`wist-center-stack`），compose 项目名相同，
所以 dev 与发布态共用 postgres / victoria-metrics / git-proxy 的容器与数据卷（省一套实例，但**清库即两边都清**）。

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

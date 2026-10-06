# Changelog

本仓是 `wist-center`（中心后端）+ `wist-center-web`（管理前端）的一站式编排。
版本以仓库根 `version.txt` 为权威，标签 `v<version>-<channel>`。

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

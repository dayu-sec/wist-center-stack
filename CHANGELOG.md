# Changelog

本仓是 `wist-center`（中心后端）+ `wist-center-web`（管理前端）的一站式编排。
版本以仓库根 `version.txt` 为权威，标签 `v<version>-<channel>`。

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

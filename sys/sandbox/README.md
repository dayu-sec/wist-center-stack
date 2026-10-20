# 沙盒（wist-center-sandbox）

WarpStation 的规则/OML 是**用户可控输入**。上游默认在 WarpStation 主容器里直接 spawn
`wparse` / `wpgen` / `wproj`，而主容器同时持有 CNB 写 token、Center proxy token 和 DB 密码
（见设计文档 R2）。本目录把这段执行拆到独立的、**无密钥、无外网、只读 rootfs** 的 worker。

## 组件

| 文件 | 作用 |
|---|---|
| `main.go` | 单二进制双角色：`wist-sandbox run` = runner；以 `wparse`/`wpgen`/`wproj` 调用 = client |
| `Dockerfile` | Go builder → `warp-parse` 基镜像（与 Gateway 的 `WARPPARSE_IMAGE_TAG` 对齐） |

## 协议

Unix socket `/run/sandbox/control.sock`，4 字节大端长度 + JSON 帧：

```text
client → runner: {"cmd":"wparse","args":[...],"cwd":"/app/tmp/sandbox/<task>/project"}
client → runner: {"type":"stdin","data":"<base64>"} / {"type":"signal","signal":"TERM"}
runner → client: {"type":"stdout|stderr","data":"<base64>"}
runner → client: {"type":"exit","code":0}
runner → client: {"type":"error","message":"..."}
```

约束：

- `cmd` 只允许 `wparse` / `wpgen` / `wproj`；
- `cwd` 必须存在，且 `EvalSymlinks` 后仍位于 `/app/tmp/sandbox/` 下；
- 不经 shell、不继承 WarpStation 的业务环境（只注入 `PATH`/`HOME`/`TMPDIR`/`LANG`/`TZ`）；
- 并发上限 2，超限直接返回错误；
- client 断开（WarpStation 杀掉包装进程）时，runner 立刻 `SIGKILL` 整个进程组。

## 构建

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg WARP_BASE=ghcr.io/wp-labs/warp-parse:0.30.0-alpha \
  -t ghcr.io/dayu-sec/wist-center-sandbox:v0.1.0-alpha --push sys/sandbox
```

`WARP_BASE` 必须与 Gateway 侧 `WPARSE_TAG` 一致；升级时按 digest 固定并做 CVE 扫描。

# wist-center-sandbox —— WarpStation 沙盒 worker / client 镜像
#
# 基镜像必须是 **与 Gateway 对齐的 warp-parse 版本**（提供 /usr/local/bin/{wparse,wpgen,wproj}）。
# 构建（多架构示例）：
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --build-arg WARP_BASE=ghcr.io/wp-labs/warp-parse:0.30.0-alpha \
#     -t ghcr.io/dayu-sec/wist-center-sandbox:v0.1.0-alpha --push sys/sandbox
#
# 运行：compose 里 `user: 999:999`、`read_only`、`network_mode: none`、`cap_drop: ALL`；
# 入口固定为 runner，不接收外部命令。

ARG WARP_BASE=ghcr.io/wp-labs/warp-parse:0.30.0-alpha

FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/wist-sandbox .

FROM ${WARP_BASE}

COPY --from=build /out/wist-sandbox /usr/local/bin/wist-sandbox
# go build 产物已经是 0755；基镜像以 uid 999 运行，不能再 chmod /usr/local/bin。

# 与上游 warp-parse 镜像一致（uid/gid 999）。compose 里也会显式钉死。
USER 999:999
WORKDIR /app

ENTRYPOINT ["/usr/local/bin/wist-sandbox", "run"]

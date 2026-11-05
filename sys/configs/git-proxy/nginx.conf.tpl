# Center Git Proxy —— Gateway 的 wparse 只读拉取 CNB 私有仓库
#
# src: sys/configs/git-proxy/nginx.conf.tpl
# dst: configs/git-proxy/nginx.conf（compose 挂到 /etc/nginx/nginx.conf:ro；600，含 CNB 读凭据）
# 渲染值: configs/git-proxy/git-proxy.value.json（本栈 localize 流程生成，600）
#
# 安全边界（设计文档 §5.2.1）：
#   · 只允许**两个仓库**的 smart HTTP 读端点（info/refs、git-upload-pack、HEAD）；
#   · 短路径别名（`/<repo>`）只对已配置的仓库生成，命中后 `rewrite ... last` 回到全路径白名单，
#     不是第二条通路（见 `GIT_PROXY_SHORT_PREFIX`）；
#   · 绝不写 `location / { proxy_pass ...; }` —— 否则等于把带 CNB token 的通用 SSRF 暴露出去；
#   · CNB 读 token 只在本容器/本文件里，Gateway 不持有任何 CNB 凭据；
#   · 来源 IP 可选 allowlist（GIT_PROXY_ALLOW_CIDR，空 = 不限）；
#   · 客户端认证（双向证书）由 GIT_PROXY_CLIENT_CERT_VERIFY 控制：
#       off（默认，只验服务端）| optional（校验但放行，只记录）| on（强制）；
#     客户端证书由 CA-G 签发，与中心网关面（:3100）是同一套 per-gateway 身份。

worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # 认证结果进日志：`optional` 灰度期间靠它统计「多少网关真的带了证书」。
    #   NONE = 没带证书；SUCCESS = CA-G 链验通过；FAILED:... = 验不过。
    # 注意：`off` 模式下也会打（恒为 NONE），便于开前置对比；
    #   格式里**不含请求头**，所以 Authorization 依旧不会进日志。
    log_format gitproxy '$remote_addr - [$time_local] "$request" $status $body_bytes_sent verify=$ssl_client_verify';
    access_log /var/log/nginx/access.log gitproxy;
    server_tokens off;

    sendfile          on;
    tcp_nopush        on;
    keepalive_timeout 65;

    # git smart HTTP 的 POST（upload-pack）body 很小；这里给足余量但设上限。
    client_max_body_size      16m;
    client_header_buffer_size 16k;
    large_client_header_buffers 4 32k;

    limit_req_zone  $binary_remote_addr zone=gitproxy:10m rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=gitconn:10m;

    server {
        listen      8443 ssl;
        server_name {{{git_proxy_server_name}}};

        # 复用中心服务器证书/私钥（Gateway 信任 Center CA）。
        ssl_certificate     /certs/server.crt;
        ssl_certificate_key /certs/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        # 双向证书（mTLS）—— 具体开关与指令由 GIT_PROXY_CLIENT_CERT_VERIFY 渲染。
{{{git_proxy_client_ca}}}

        limit_conn gitconn 32;

        # 可选 IP allowlist（GIT_PROXY_ALLOW_CIDR，逗号分隔）。
{{{git_proxy_allow}}}

        # 只放行两个仓库的 smart HTTP 读端点。proxy_pass **不带 URI**，保留原始路径/查询串。
        location ~ ^{{{git_proxy_repo_regex}}}/(info/refs|git-upload-pack)$ {
            if ($arg_service = "git-receive-pack") { return 403; }
            if ($request_method !~ ^(GET|POST)$) { return 403; }

            limit_req zone=gitproxy burst=60 nodelay;

            proxy_pass https://{{{git_authority}}};
            proxy_http_version 1.1;
            proxy_set_header Host {{{git_authority}}};
            proxy_set_header Connection "";
{{{git_auth_header_line}}}

            proxy_ssl_server_name on;
            proxy_ssl_name {{{git_host}}};
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
            proxy_ssl_verify_depth 3;
            proxy_redirect off;

            # 流式转发，避免 clone 大仓库时落临时文件/内存。
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_max_temp_file_size 0;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }

        # 部分 Git 客户端会探测 HEAD（dumb 协议）；仍只限两个仓库。
        location ~ ^{{{git_proxy_repo_regex}}}/HEAD$ {
            if ($request_method != GET) { return 403; }

            limit_req zone=gitproxy burst=60 nodelay;

            proxy_pass https://{{{git_authority}}};
            proxy_http_version 1.1;
            proxy_set_header Host {{{git_authority}}};
            proxy_set_header Connection "";
{{{git_auth_header_line}}}

            proxy_ssl_server_name on;
            proxy_ssl_name {{{git_host}}};
            proxy_ssl_verify on;
            proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
            proxy_redirect off;
            proxy_buffering off;
        }

        # 短路径别名：客户端写 `/<repo>`（可省上游的公共上级目录，如 `/<组>/<项目>`），
        # 代理补回真实路径后**重新走一次 location 匹配**（`rewrite ... last`）→ 命中上面的全路径白名单。
        # 因此白名单 / 端点限制 / 限流 / 上游凭据只有一份，别名不绕过任何一条。
        # {{{git_proxy_short_note}}}
        location ~ ^{{{git_proxy_short_regex}}}/(info/refs|git-upload-pack|HEAD)$ {
            rewrite {{{git_proxy_short_rewrite}}}
        }

        # 其它路径一律拒绝：不做“带 CNB token 的通用反代”。
        location / {
            return 404;
        }
    }
}

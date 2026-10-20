# wist-center-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（sys/docker-compose.yml 把它挂到 /etc/nginx/conf.d/default.conf）
# 渲染值：configs/web/nginx.value.json（scripts/init-web-conf.sh 从环境变量 WEB_WGC_DOMAIN 生成）
#
# 职责：**终止 TLS** + 托管前端静态产物 + SPA 深链回退 + 把 /api 反代到 center 容器的**管理面**。
# 本页 nginx 在容器内 **443** 上跑 **HTTPS**：服务器证书/私钥只读挂载自站点身份
# `identity/center/control-center-server.{crt,key}`（由站点 CA 签，SAN 覆盖对外域名；见 scripts/init-center.sh），
# 宿主发布到 `${WEB_BIND_IP}:${WEB_HOST_PORT}`（默认 127.0.0.1，**内网**）。
# /api 反代到 center 容器的 **3102（管理面 listener）** —— 不是网关面的 3100：
# 两边路由白名单互斥，管理面（含 `/api/v1/admin/**`）永远不在公网上。

server {
    listen 443 ssl;
    server_name {{web_domain}};

    # 站点服务器证书（由站点 CA 签；SAN 覆盖对外域名）。由 compose 只读挂载进 /certs。
    ssl_certificate     /certs/server.crt;
    ssl_certificate_key /certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /usr/share/nginx/html;
    index index.html;

    # 静态资源 + SPA 深链回退：找不到实体文件就交给前端路由（index.html）。
    location / {
        try_files $uri $uri/ /index.html;
    }

    # /api 反代到中心的**管理面 listener（3102）**（**https**）。proxy_pass 不带 URI、也不 rewrite —— 原样透传 /api/...。
    # 管理面不校客户端证书（浏览器没有网关证书），仍是服务器证书 TLS + Bearer admin token。
    # proxy_ssl_verify off：中心的服务器证书由站点 CA-S 签发，容器内这一跳不做链校验（同一份只读挂载身份）。
    location /api/ {
        proxy_pass https://center:3102;
        proxy_ssl_verify off;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# ── WarpStation：同一端口、不同 server_name ──
# WarpStation 上游没有鉴权，且 GET /api/devices 会返回 proxy token 明文，
# 因此这个虚拟主机必须至少有一层认证；这里用 basic auth（密码文件由 init-web-conf.sh 生成）。
#
# proxy_pass 用变量 + resolver：station 容器重建后 nginx 能重新解析，避免缓存旧 IP。
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    server_name {{station_domain}};

    ssl_certificate     /certs/server.crt;
    ssl_certificate_key /certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    auth_basic           "WarpStation";
    auth_basic_user_file /certs/htpasswd;

    client_max_body_size 32m;

    resolver 127.0.0.11 valid=10s ipv6=off;
    set $station_upstream http://warp-station:8081;

    location / {
        proxy_pass         $station_upstream;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection $connection_upgrade;
        # 沙盒日志/长任务：不缓冲，超时放宽。
        proxy_buffering    off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}

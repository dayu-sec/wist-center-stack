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

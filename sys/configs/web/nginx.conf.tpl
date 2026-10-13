# wist-center-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（sys/docker-compose.yml 把它挂到 /etc/nginx/conf.d/default.conf）
# 渲染值：configs/web/nginx.value.json（scripts/init-web-conf.sh 从环境变量 CENTER_DOMAIN 生成）
#
# 职责：**终止 TLS** + 托管前端静态产物 + SPA 深链回退 + 把 /api 反代到 center 容器。
# 本页 nginx 在容器内 **443** 上跑 **HTTPS**：服务器证书/私钥只读挂载自站点身份
# `identity/center/control-center-server.{crt,key}`（由站点 CA 签，SAN 覆盖对外域名；见 scripts/init-center.sh），
# 宿主发布到 ${WEB_PORT}（默认 18080）。/api 反代到 center 容器 3100（容器网络内**明文**，中心自身不做 TLS）。
# 与开发态 vite 代理对齐：/api 前缀保留、原样透传。

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

    # /api 反代到中心（容器内 3100）。proxy_pass 不带 URI、也不 rewrite —— 原样透传 /api/...。
    location /api/ {
        proxy_pass http://center:3100;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

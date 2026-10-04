# wist-center-web 站点配置**模板**（handlebars，由 localize 渲染）。
# src: 本文件（sys/configs/web/nginx.conf.tpl）
# dst: configs/web/nginx.conf（sys/docker-compose.yml 把它挂到 /etc/nginx/conf.d/default.conf）
# 渲染值：configs/web/nginx.value.json（scripts/init-web-conf.sh 从环境变量 CENTER_DOMAIN 生成）
#
# 职责：托管前端静态产物 + SPA 深链回退 + 把 /api 反代到 center 容器。
# 本页 nginx 在容器内 **80** 上跑**明文** HTTP —— 中心自身不做 TLS，对外 HTTPS 由前面的反代终止；
# 反代只要把请求转到本页的 ${WEB_PORT}，并由它自己持有页面证书（本栈不管 TLS 证书）。
# 与开发态 vite 代理对齐：/api 前缀保留、原样透传，目标 = 中心容器 3100。

server {
    listen 80;
    server_name {{web_domain}};

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

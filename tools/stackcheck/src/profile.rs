//! center-stack 的判据参数（`StackProfile`）。
//!
//! 类型定义在 `wist-stackcheck-core::profile`；这里只放本栈的常量。

pub use wist_stackcheck_core::profile::{
    DeriveSpec, DomainSpec, IdentityFile, Missing, MountKind, MountSpec, Profile, PublicUrlSpec,
    RenderPair, SecretFile,
};

pub const CENTER: Profile = Profile {
    project_fallback: "wist-center-stack",

    render_pairs: &[
        RenderPair {
            code: "render.freshness.center",
            rendered: "configs/center/wist-center.toml",
            source: "configs/center/wist-center.value.json",
        },
        RenderPair {
            code: "render.freshness.git-proxy",
            rendered: "configs/git-proxy/nginx.conf",
            source: "configs/git-proxy/git-proxy.value.json",
        },
        RenderPair {
            code: "render.freshness.web",
            rendered: "configs/web/nginx.conf",
            source: "configs/web/nginx.value.json",
        },
        // 现场态**声明**由模板渲染；值在旁边的 `.env`（永不重渲），所以比模板而不是比值。
        RenderPair {
            code: "render.freshness.center-pub",
            rendered: "identity/center/wist-center-pub.toml",
            source: "sys/configs/center/wist-center-pub.toml.tpl",
        },
    ],

    placeholder_files: &[
        "configs/center/wist-center.toml",
        "configs/center/wist-center.value.json",
        "configs/center/center.env",
        "configs/git-proxy/nginx.conf",
        "configs/git-proxy/git-proxy.value.json",
        "configs/web/nginx.conf",
        // 现场态**声明**故意保留 `${CENTER_PUBLIC_URL:-https://center.warpinsight.example}`
        // 作为最终回落值：不能按「占位值」扫它（真值在旁边的 `.env`，由 layout.public_url 判）。
        "identity/center/.env",
    ],
    placeholder_patterns: wist_stackcheck_core::profile::PLACEHOLDER_PATTERNS,

    domains: &[
        DomainSpec {
            var: "WEB_WGC_DOMAIN",
            derive: None,
        },
        DomainSpec {
            var: "API_WGC_DOMAIN",
            derive: Some(DeriveSpec {
                from: "WEB_WGC_DOMAIN",
                pattern: "api.{}",
            }),
        },
    ],

    secret_files: &[
        SecretFile {
            path: ".wist/sec-value.yml",
            label: "栈根密钥（admin token / hmac / DB 口令 / Git token）",
            missing: Missing::Fail,
            blocking: true,
        },
        SecretFile {
            path: "configs/center/center.env",
            label: "PG app 凭据（db-schema 的 env_file）",
            missing: Missing::Fail,
            blocking: true,
        },
        SecretFile {
            path: "configs/center/wist-center.value.json",
            label: "中心渲染值（含 DB 口令）",
            missing: Missing::Fail,
            blocking: true,
        },
        SecretFile {
            path: "configs/git-proxy/git-proxy.value.json",
            label: "Git Proxy 渲染值（含 CNB 读凭据）",
            missing: Missing::Fail,
            blocking: true,
        },
        SecretFile {
            path: "configs/git-proxy/nginx.conf",
            label: "Git Proxy 配置（含 CNB 读凭据）",
            missing: Missing::Fail,
            blocking: true,
        },
    ],

    private_key_roots: &["identity"],

    identity_files: &[
        IdentityFile {
            path: "identity/center/control-center.pem",
            label: "控制中心 CA 信任根",
            blocking: true,
        },
        IdentityFile {
            path: "identity/center/control-center-server.crt",
            label: "中心服务器叶证书",
            blocking: true,
        },
        IdentityFile {
            path: "identity/center/control-center-server.key",
            label: "中心服务器私钥",
            blocking: true,
        },
        IdentityFile {
            path: "identity/center/control-center-server.san",
            label: "叶证书 SAN 记录（幂等重签用）",
            blocking: false,
        },
        IdentityFile {
            path: "identity/center/control-center-ca.key",
            label: "CA 私钥（续签 / 新叶证书）",
            blocking: false,
        },
        IdentityFile {
            path: "identity/center/gateway-client-ca.pem",
            label: "网关客户端 CA（CA-G）证书",
            blocking: false,
        },
        IdentityFile {
            path: "identity/center/gateway-client-ca.key.pem",
            label: "网关客户端 CA（CA-G）私钥",
            blocking: false,
        },
    ],

    mounts: &[
        MountSpec {
            source_expr: "${CENTER_CONFIG_DIR}/wist-center.toml",
            target: "/wist-center/wist-center.toml",
            expected_host: "configs/center/wist-center.toml",
            kind: MountKind::File,
        },
        MountSpec {
            source_expr: "${CENTER_CONFIG_DIR}/state",
            target: "/wist-center/state",
            expected_host: "configs/center/state",
            kind: MountKind::Dir,
        },
        MountSpec {
            source_expr: "${CENTER_CONFIG_DIR}/logs",
            target: "/wist-center/logs",
            expected_host: "configs/center/logs",
            kind: MountKind::Dir,
        },
        MountSpec {
            source_expr: "${CENTER_ARTIFACT_DIR}",
            target: "/wist-center/artifacts",
            expected_host: "artifacts",
            kind: MountKind::Dir,
        },
        MountSpec {
            source_expr: "${GIT_PROXY_CONFIG_DIR}/nginx.conf",
            target: "/etc/nginx/nginx.conf",
            expected_host: "configs/git-proxy/nginx.conf",
            kind: MountKind::File,
        },
        MountSpec {
            source_expr: "${WEB_NGINX_CONF}",
            target: "/etc/nginx/conf.d/default.conf",
            expected_host: "configs/web/nginx.conf",
            kind: MountKind::File,
        },
        MountSpec {
            source_expr: "${PG_INITDB_DIR}",
            target: "/docker-entrypoint-initdb.d",
            expected_host: "sys/db/initdb",
            kind: MountKind::Dir,
        },
        MountSpec {
            source_expr: "./identity/center",
            target: "/wist-center/ca",
            expected_host: "identity/center",
            kind: MountKind::Dir,
        },
        MountSpec {
            source_expr: "./identity/center/control-center-server.crt",
            target: "/certs/server.crt",
            expected_host: "identity/center/control-center-server.crt",
            kind: MountKind::File,
        },
        MountSpec {
            source_expr: "./identity/center/control-center-server.key",
            target: "/certs/server.key",
            expected_host: "identity/center/control-center-server.key",
            kind: MountKind::File,
        },
        MountSpec {
            source_expr: "./.wist",
            target: "/secrets",
            expected_host: ".wist",
            kind: MountKind::Dir,
        },
    ],

    schema_file: Some("sys/db/initdb/01_schema.sql"),

    public_url: Some(PublicUrlSpec {
        main_config: "configs/center/wist-center.toml",
        declaration: "identity/center/wist-center-pub.toml",
        env: "identity/center/.env",
        env_var: "CENTER_PUBLIC_URL",
        port_var: "CENTER_HOST_PORT",
        default_port: "3100",
        host_var: "API_WGC_DOMAIN",
    }),

    server_cert: Some("identity/center/control-center-server.crt"),
};

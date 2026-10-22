//! center-stack 的判据参数（`StackProfile`）。
//!
//! 检查逻辑只认这里的「声明」：路径、变量名、挂载对、必填身份文件。网关栈沿用同一形状
//! （见 `wist-design/doc/design/foundation/stack-config-check.md` §11），所以换栈时**只换
//! profile，不改检查器**。路径一律相对栈根。

/// 渲染产物 ↔ 值文件（或模板）。产物 mtime 早于来源 = 改了值没重渲。
pub struct RenderPair {
    pub code: &'static str,
    pub rendered: &'static str,
    pub source: &'static str,
}

/// 文件缺失时的处理方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Missing {
    /// 未生成（例如尚未 localize）：不报。
    Skip,
    /// 该有但没有：WARN。
    Warn,
    /// 缺了就会坏：FAIL。
    Fail,
}

/// 不该对其他用户开放的文件（含口令 / token）。
pub struct SecretFile {
    pub path: &'static str,
    pub label: &'static str,
    pub missing: Missing,
    /// 命中（缺文件 / world 位）时是否阻断部署。安全类问题通常阻断；配置文件仅提示。
    pub blocking: bool,
}

/// 站点身份材料（`identity/center/`）。
pub struct IdentityFile {
    pub path: &'static str,
    pub label: &'static str,
    /// 缺失是否阻断部署：叶证书/私钥/信任根会直接坏；CA 私钥与 CA-G 只影响以后的操作。
    pub blocking: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MountKind {
    File,
    Dir,
}

/// compose bind 挂载 ↔ 变量 ↔ 实际落点。
pub struct MountSpec {
    /// compose 里**字面**出现的源（含 `${VAR}`），例如 `${CENTER_CONFIG_DIR}/wist-center.toml`。
    pub source_expr: &'static str,
    /// 容器内目标路径。
    pub target: &'static str,
    /// localize 实际写入 / 创建的宿主路径（相对栈根）。
    pub expected_host: &'static str,
    pub kind: MountKind,
}

/// server 叶证书与它必须覆盖的域名。
pub struct TlsSpec {
    pub cert: &'static str,
}

/// 现场态 `public_url`：声明（只写 `${VAR}`）、值（`.env`）、主配置（不得重复定义）。
pub struct PublicUrlSpec {
    pub main_config: &'static str,
    pub declaration: &'static str,
    pub env: &'static str,
    pub env_var: &'static str,
    pub port_var: &'static str,
    pub default_port: &'static str,
}

pub struct Profile {
    /// 包名 / compose 项目名回落值。
    pub project_fallback: &'static str,
    pub render_pairs: &'static [RenderPair],
    pub placeholder_files: &'static [&'static str],
    pub placeholder_patterns: &'static [&'static str],
    pub secret_files: &'static [SecretFile],
    pub private_key_roots: &'static [&'static str],
    pub identity_files: &'static [IdentityFile],
    pub tls: TlsSpec,
    pub mounts: &'static [MountSpec],
    pub schema_file: &'static str,
    pub public_url: PublicUrlSpec,
}

pub const PLACEHOLDER_PATTERNS: &[&str] =
    &["example.com", "warpinsight.example", "CHANGEME", "changeme"];

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
    placeholder_patterns: PLACEHOLDER_PATTERNS,

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

    tls: TlsSpec {
        cert: "identity/center/control-center-server.crt",
    },

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

    schema_file: "sys/db/initdb/01_schema.sql",

    public_url: PublicUrlSpec {
        main_config: "configs/center/wist-center.toml",
        declaration: "identity/center/wist-center-pub.toml",
        env: "identity/center/.env",
        env_var: "CENTER_PUBLIC_URL",
        port_var: "CENTER_HOST_PORT",
        default_port: "3100",
    },
};

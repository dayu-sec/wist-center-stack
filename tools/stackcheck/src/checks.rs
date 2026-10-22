//! center-stack 专属判据 + 通用判据的 re-export。
//!
//! 通用逻辑全部在 `wist-stackcheck-core::checks`；这里只保留：
//! - `tls_certificate`：center 的叶证书是**固定路径**，且 SAN 要覆盖两个域名；
//! - `api_domain`：测试与本地脚本用的派生 helper。

use std::fs;

use wist_stackcheck_core::profile::Profile;
use wist_stackcheck_core::{Finding, Stack};

pub use wist_stackcheck_core::checks::*;
pub use wist_stackcheck_core::x509::*;

/// 与 `scripts/init-center.sh` 同口径：`API_WGC_DOMAIN` 留空 = `api.<WEB_WGC_DOMAIN>`。
pub fn api_domain(vars: &Vars) -> Option<String> {
    crate::profile::CENTER
        .domains
        .iter()
        .find(|domain| domain.var == "API_WGC_DOMAIN")
        .and_then(|domain| domain_value(vars, domain))
}

/// 中心叶证书必须在有效期内、且 SAN 覆盖 profile 里的每个域名（管理面 + 网关面）。
pub fn tls_certificate(stack: &Stack, vars: &Vars, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "tls.san_covers_domain";

    let Some(relative) = profile.server_cert else {
        return Vec::new();
    };
    let path = stack.at(relative);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(err) => {
            return vec![
                Finding::fail(
                    CODE,
                    "中心服务器叶证书读不到",
                    format!("{}：{err}", path.display()),
                )
                .with_hint("跑一次 `gops sys localize`（init-center.sh 会签发）"),
            ];
        }
    };
    let leaf = match wist_stackcheck_core::x509::parse_pem(&bytes) {
        Ok(leaf) => leaf,
        Err(err) => {
            return vec![Finding::fail(
                CODE,
                format!("中心服务器叶证书：{err}"),
                path.display().to_string(),
            )];
        }
    };

    if !leaf.valid {
        return vec![
            Finding::fail(
                CODE,
                "中心服务器叶证书不在有效期内",
                format!(
                    "notBefore={} notAfter={}",
                    leaf.not_before, leaf.not_after
                ),
            )
            .with_hint("重新签发：`gops sys localize`（ensure-center-server-cert.sh 会重签）"),
        ];
    }

    if !vars.ok() {
        return vec![Finding::warn(
            CODE,
            "读不到变量，跳过 SAN 判定",
            "证书本身在有效期内（这一项只能判 expire）",
        )];
    }

    let mut domains: Vec<(&str, String)> = Vec::new();
    for spec in profile.domains {
        if let Some(value) = domain_value(vars, spec)
            && !value.trim().is_empty()
        {
            domains.push((spec.var, value));
        }
    }
    if domains.is_empty() {
        return vec![Finding::warn(
            CODE,
            "站点域名为空，跳过 SAN 判定",
            "证书本身在有效期内（这一项只能判 expire）",
        )];
    }

    let mut uncovered = Vec::new();
    for (label, domain) in &domains {
        if !wist_stackcheck_core::x509::covers(&leaf, domain) {
            uncovered.push(format!("{label}={domain}"));
        }
    }

    if uncovered.is_empty() {
        vec![Finding::ok(
            CODE,
            "叶证书 SAN 覆盖站点域名",
            format!(
                "{} ∈ [{}]",
                domains
                    .iter()
                    .map(|(label, value)| format!("{label}={value}"))
                    .collect::<Vec<_>>()
                    .join("，"),
                wist_stackcheck_core::x509::san_summary(&leaf)
            ),
        )]
    } else {
        vec![
            Finding::fail(
                CODE,
                "叶证书 SAN 不覆盖站点域名",
                format!(
                    "未覆盖：{}；证书 SAN=[{}]",
                    uncovered.join("，"),
                    wist_stackcheck_core::x509::san_summary(&leaf)
                ),
            )
            .with_hint(
                "跑一次 `gops sys localize`（ensure-center-server-cert.sh 发现 SAN 缺域名会重签）",
            ),
        ]
    }
}
#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::time::Duration;

    use super::*;
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};
    use std::time::SystemTime;
    use crate::Status;
    use crate::profile;

    /// 临时栈根；`Drop` 时清理。
    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        fn new(tag: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "wist-center-stackcheck-{}-{tag}-{nanos}",
                std::process::id()
            ));
            fs::create_dir_all(&root).unwrap();
            Self { root }
        }

        fn write(&self, rel: &str, body: &str) -> PathBuf {
            let path = self.root.join(rel);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&path, body).unwrap();
            path
        }

        fn mkdir(&self, rel: &str) -> PathBuf {
            let path = self.root.join(rel);
            fs::create_dir_all(&path).unwrap();
            path
        }

        fn stack(&self) -> Stack {
            Stack::new(&self.root)
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    const VARS: &str = "\
- name: WEB_WGC_DOMAIN
  value: center.dev.wist.lab
- name: API_WGC_DOMAIN
  value: api.dev.wist.lab
- name: CENTER_HOST_PORT
  value: '3100'
- name: CENTER_CONFIG_DIR
  value: ./configs/center
- name: CENTER_ARTIFACT_DIR
  value: ./artifacts
- name: GIT_PROXY_CONFIG_DIR
  value: ./configs/git-proxy
- name: WEB_NGINX_CONF
  value: ./configs/web/nginx.conf
- name: PG_INITDB_DIR
  value: ./sys/db/initdb
";

    fn vars(tree: &Tree) -> Vars {
        Vars::load(&tree.stack())
    }

    #[test]
    fn prefers_effective_env_over_defaults() {
        let tree = Tree::new("effective-vars");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            ".env",
            "CENTER_CONFIG_DIR=./data/center\nAPI_WGC_DOMAIN=api.site.test\n",
        );
        let vars = vars(&tree);
        assert!(vars.ok(), "{:?}", vars.error);
        assert_eq!(vars.source, ".env");
        assert_eq!(vars.get("CENTER_CONFIG_DIR"), Some("./data/center"));
        assert_eq!(api_domain(&vars).as_deref(), Some("api.site.test"));
    }

    #[test]
    fn derives_api_domain_when_empty() {
        let tree = Tree::new("derive-api");
        tree.write(
            "sys/merged_vars.yml",
            "- name: WEB_WGC_DOMAIN\n  value: center.site.test\n- name: API_WGC_DOMAIN\n  value: ''\n",
        );
        let vars = vars(&tree);
        assert_eq!(api_domain(&vars).as_deref(), Some("api.center.site.test"));
    }

    #[test]
    fn unknown_merged_vars_shape_fails_loudly() {
        let tree = Tree::new("vars-shape");
        tree.write("sys/merged_vars.yml", "variables:\n  WEB_WGC_DOMAIN: x\n");
        let vars = vars(&tree);
        assert!(!vars.ok());
        assert!(vars.error.unwrap().contains("格式不认识"));
    }

    #[test]
    fn flags_a_render_older_than_its_value_file() {
        let tree = Tree::new("stale-render");
        let rendered = tree.write(
            "configs/center/wist-center.toml",
            "protocol_version = \"1.0\"\n",
        );
        tree.write("configs/center/wist-center.value.json", "{}\n");
        let file = File::options().write(true).open(&rendered).unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();

        let findings = render_freshness(&tree.stack(), &profile::CENTER);
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.center")
            .expect("应有 center 的新鲜度检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
    }

    #[test]
    fn accepts_a_render_that_is_newer_than_its_value_file() {
        let tree = Tree::new("fresh-render");
        tree.write("configs/center/wist-center.value.json", "{}\n");
        tree.write(
            "configs/center/wist-center.toml",
            "protocol_version = \"1.0\"\n",
        );

        let findings = render_freshness(&tree.stack(), &profile::CENTER);
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.center")
            .expect("应有新鲜度检查");
        assert_eq!(finding.status, Status::Ok, "{finding:#?}");
    }

    #[test]
    fn flags_placeholder_values_in_rendered_config() {
        let tree = Tree::new("placeholder");
        tree.write(
            "configs/center/wist-center.toml",
            "[server]\npublic_url = \"https://center.warpinsight.example\"\n",
        );
        let findings = render_placeholders(&tree.stack(), &profile::CENTER);
        let finding = &findings[0];
        assert_eq!(finding.status, Status::Fail);
        assert!(
            finding.detail.contains("warpinsight.example"),
            "{}",
            finding.detail
        );
    }

    #[test]
    fn placeholder_scan_with_no_files_is_a_warning_not_ok() {
        let tree = Tree::new("placeholder-empty");
        let findings = render_placeholders(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
    }

    #[test]
    fn placeholder_domains_respect_label_boundaries() {
        assert!(is_placeholder("center.example.com"));
        assert!(is_placeholder("example.com"));
        assert!(is_placeholder("center.warpinsight.example"));
        assert!(is_placeholder("CHANGEME"));
        // 真实域名不能因为子串被误判。
        assert!(!is_placeholder("myexample.com"));
        assert!(!is_placeholder("wgc.dev.wist.lab"));
    }

    #[test]
    fn flags_placeholder_domains() {
        let tree = Tree::new("domain-placeholder");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            ".env",
            "WEB_WGC_DOMAIN=center.example.com\nAPI_WGC_DOMAIN=\n",
        );
        let findings = domain_configured(&vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);
    }

    #[test]
    fn accepts_real_domains() {
        let tree = Tree::new("domain-ok");
        tree.write("sys/merged_vars.yml", VARS);
        let findings = domain_configured(&vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[cfg(unix)]
    #[test]
    fn flags_a_missing_root_secret_file() {
        use std::os::unix::fs::PermissionsExt;

        let tree = Tree::new("no-secret");
        for spec in profile::CENTER.secret_files {
            if spec.missing == crate::profile::Missing::Fail && spec.path != ".wist/sec-value.yml" {
                let path = tree.write(spec.path, "x\n");
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            }
        }
        let findings = secret_perms(&tree.stack(), &profile::CENTER);
        let finding = findings
            .iter()
            .find(|finding| finding.code == "secret.file_mode")
            .expect("应有密钥权限检查");
        assert_eq!(finding.status, Status::Fail, "{finding:#?}");
        assert!(finding.blocking, "缺运行期密钥会让中心起不来，应阻断");
    }

    #[cfg(unix)]
    #[test]
    fn grades_secret_file_modes() {
        use std::os::unix::fs::PermissionsExt;

        let tree = Tree::new("secret-modes");
        for spec in profile::CENTER.secret_files {
            let path = tree.write(spec.path, "x\n");
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let findings = secret_perms(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");

        let path = tree.root.join("configs/center/center.env");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        let findings = secret_perms(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);
    }

    #[test]
    fn flags_missing_identity_files_and_only_blocks_on_real_ones() {
        let tree = Tree::new("identity-missing");
        let findings = identity_files(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail);
        assert!(findings[0].blocking, "缺叶证书会让中心/TLS 直接坏");

        for spec in profile::CENTER.identity_files {
            tree.write(spec.path, "x\n");
        }
        let findings = identity_files(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok);
    }

    #[test]
    fn san_wildcard_covers_only_one_label() {
        assert!(san_covers("*.a.b", "x.a.b"));
        assert!(!san_covers("*.a.b", "a.b"));
        assert!(!san_covers("*.a.b", "x.y.a.b"));
        assert!(!san_covers("gw.a.b", "gw.a.b.evil.net"));
        assert!(san_covers("GW.A.B.", "gw.a.b"));
    }

    #[test]
    fn accepts_short_and_long_compose_mounts() {
        let short = "services:\n  x:\n    volumes:\n      - ${CENTER_ARTIFACT_DIR}:/wist-center/artifacts\n";
        assert_eq!(
            compose_mount_target(short, "${CENTER_ARTIFACT_DIR}").as_deref(),
            Some("/wist-center/artifacts")
        );
        let long = "\
services:
  x:
    volumes:
      - type: bind
        source: ${CENTER_ARTIFACT_DIR}
        target: /wist-center/artifacts
";
        assert_eq!(
            compose_mount_target(long, "${CENTER_ARTIFACT_DIR}").as_deref(),
            Some("/wist-center/artifacts")
        );
    }

    fn full_compose() -> String {
        let mut out = String::from("services:\n  x:\n    volumes:\n");
        for spec in profile::CENTER.mounts {
            out.push_str(&format!(
                "      - {}:{}:ro\n",
                spec.source_expr, spec.target
            ));
        }
        out
    }

    #[test]
    fn mount_layout_is_consistent() {
        let tree = Tree::new("mount-ok");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", &full_compose());
        for spec in profile::CENTER.mounts {
            match spec.kind {
                crate::profile::MountKind::File => {
                    tree.write(spec.expected_host, "x\n");
                }
                crate::profile::MountKind::Dir => {
                    tree.mkdir(spec.expected_host);
                }
            }
        }
        let findings = layout_mounts(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn flags_a_var_that_moves_the_mount_away_from_localize() {
        let tree = Tree::new("mount-moved");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            ".env",
            "CENTER_CONFIG_DIR=./data/center\n\
             CENTER_ARTIFACT_DIR=./artifacts\n\
             GIT_PROXY_CONFIG_DIR=./configs/git-proxy\n\
             WEB_NGINX_CONF=./configs/web/nginx.conf\n\
             PG_INITDB_DIR=./sys/db/initdb\n",
        );
        tree.write("sys/docker-compose.yml", &full_compose());
        for spec in profile::CENTER.mounts {
            match spec.kind {
                crate::profile::MountKind::File => {
                    tree.write(spec.expected_host, "x\n");
                }
                crate::profile::MountKind::Dir => {
                    tree.mkdir(spec.expected_host);
                }
            }
        }
        let findings = layout_mounts(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(
            findings[0].detail.contains("configs/center"),
            "{}",
            findings[0].detail
        );
    }

    #[test]
    fn flags_public_url_drift_after_domain_change() {
        let tree = Tree::new("public-url-drift");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "configs/center/wist-center.toml",
            "[server]\nlisten_addr = \"0.0.0.0:3100\"\n",
        );
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://center.warpinsight.example}\"\n",
        );
        tree.write(
            "identity/center/.env",
            "CENTER_PUBLIC_URL=https://api.old.wist.lab:3100\n",
        );

        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(
            !findings[0].blocking,
            "旧 public_url 不该拦住当前运行正常的升级"
        );
        assert!(
            findings[0].detail.contains("CENTER_PUBLIC_URL"),
            "{findings:#?}"
        );
    }

    #[test]
    fn accepts_public_url_derived_from_current_vars() {
        let tree = Tree::new("public-url-ok");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "configs/center/wist-center.toml",
            "[server]\nlisten_addr = \"0.0.0.0:3100\"\n",
        );
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://center.warpinsight.example}\"\n",
        );
        tree.write(
            "identity/center/.env",
            "CENTER_PUBLIC_URL=https://api.dev.wist.lab:3100\n",
        );

        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn flags_public_url_duplicated_in_main_config() {
        let tree = Tree::new("public-url-duplicate");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            "configs/center/wist-center.toml",
            "[server]\npublic_url = \"https://api.dev.wist.lab:3100\"\n",
        );
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://x}\"\n",
        );
        tree.write(
            "identity/center/.env",
            "CENTER_PUBLIC_URL=https://api.dev.wist.lab:3100\n",
        );
        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].detail.contains("重复"), "{findings:#?}");
    }

    #[test]
    fn flags_missing_schema_file() {
        let tree = Tree::new("schema-missing");
        let findings = database_initdb(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail);
        assert!(findings[0].blocking);

        tree.write("sys/db/initdb/01_schema.sql", "CREATE TABLE t (id int);\n");
        let findings = database_initdb(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok);
    }

    #[test]
    fn published_ports_parse_across_docker_ps_lines() {
        // `docker ps --format` 每个容器一行；行之间没有逗号。
        let output = "80/tcp, 127.0.0.1:1443->443/tcp\n0.0.0.0:3100->3100/tcp, 127.0.0.1:3102->3102/tcp\n127.0.0.1:55432->5432/tcp\n";
        let ports = published_ports_from_ps(output);
        for expected in [1443, 3100, 3102, 55432] {
            assert!(ports.contains(&expected), "漏了 {expected}：{ports:?}");
        }
        assert!(!ports.contains(&443), "容器端口不能算宿主端口");
    }

    #[test]
    fn parses_center_ports_with_bind_ip() {
        let vars = BTreeMap::from([
            ("CENTER_BIND_IP".to_string(), "0.0.0.0".to_string()),
            ("CENTER_HOST_PORT".to_string(), "3100".to_string()),
            ("WEB_BIND_IP".to_string(), "127.0.0.1".to_string()),
            ("WEB_HOST_PORT".to_string(), "2443".to_string()),
        ]);
        let compose = "\
services:
  center:
    ports:
      - \"${CENTER_BIND_IP}:${CENTER_HOST_PORT}:3100\"
  web:
    ports:
      - \"${WEB_BIND_IP}:${WEB_HOST_PORT}:443\"
";
        let ports = compose_ports(compose, &vars);
        assert_eq!(
            ports,
            vec![
                PublishedPort {
                    host_port: 3100,
                    protocol: "tcp".to_string(),
                    bind_ip: Some("0.0.0.0".to_string()),
                },
                PublishedPort {
                    host_port: 2443,
                    protocol: "tcp".to_string(),
                    bind_ip: Some("127.0.0.1".to_string()),
                },
            ]
        );
    }

    #[test]
    fn scans_all_ports_blocks_not_just_the_first() {
        let vars = BTreeMap::new();
        let compose = "\
services:
  vm:
    ports:
      - \"127.0.0.1:28429:8428\"
  web:
    ports:
      - \"127.0.0.1:2443:443\"
";
        let ports = compose_ports(compose, &vars);
        let host_ports: Vec<u16> = ports.iter().map(|port| port.host_port).collect();
        assert_eq!(host_ports, vec![28429, 2443]);
    }

    #[test]
    fn long_mount_parsing_stays_inside_its_own_entry() {
        // 回归：source 前面有上一个条目的 target 时，不能把上一个 target 配给这个 source。
        let compose = "\
services:
  x:
    volumes:
      - type: bind
        target: /first
        source: ${A}
      - type: bind
        source: ${B}
        target: /second
";
        assert_eq!(
            compose_mount_target(compose, "${A}").as_deref(),
            Some("/first")
        );
        assert_eq!(
            compose_mount_target(compose, "${B}").as_deref(),
            Some("/second")
        );
    }

    #[test]
    fn compose_ports_support_long_syntax_host_ip_and_protocol() {
        let vars = BTreeMap::new();
        let compose = "\
services:
  a:
    ports:
      - target: 3100
        published: 3100
        host_ip: 127.0.0.1
        protocol: tcp
      - target: 5353
        published: 5353
        protocol: udp
";
        let ports = compose_ports(compose, &vars);
        assert_eq!(ports.len(), 2, "{ports:#?}");
        assert_eq!(ports[0].bind_ip.as_deref(), Some("127.0.0.1"));
        assert_eq!(ports[1].protocol, "udp");
    }

    #[test]
    fn freshness_warns_when_the_rendered_product_is_missing() {
        let tree = Tree::new("freshness-missing");
        tree.write("configs/center/wist-center.value.json", "{}\n");
        let findings = render_freshness(&tree.stack(), &profile::CENTER);
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.center")
            .expect("应有 center 的新鲜度检查");
        assert_eq!(finding.status, Status::Warn, "{finding:#?}");
    }

    #[test]
    fn freshness_warns_when_only_the_rendered_product_exists() {
        let tree = Tree::new("freshness-no-source");
        tree.write("configs/center/wist-center.toml", "[server]\n");
        let findings = render_freshness(&tree.stack(), &profile::CENTER);
        let finding = findings
            .iter()
            .find(|finding| finding.code == "render.freshness.center")
            .expect("应有 center 的新鲜度检查");
        assert_eq!(finding.status, Status::Warn, "{finding:#?}");
    }

    #[test]
    fn unreadable_env_does_not_silently_fall_back_to_defaults() {
        let tree = Tree::new("env-unreadable");
        tree.write("sys/merged_vars.yml", VARS);
        // 用同名目录模拟「.env 存在但读不了」（跨平台都不依赖 chmod）。
        tree.mkdir(".env");
        let vars = vars(&tree);
        assert!(!vars.ok(), "读不了 .env 不能回落默认值");
        let findings = crate::run_with(&tree.stack(), &crate::Options { offline: true, only: None });
        assert!(
            findings
                .iter()
                .any(|finding| finding.code == "config.vars" && finding.status == Status::Fail),
            "{findings:#?}"
        );
    }

    #[test]
    fn empty_env_does_not_silently_fall_back_to_defaults() {
        let tree = Tree::new("env-empty");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(".env", "# 只有注释\n\n");
        let vars = vars(&tree);
        assert!(!vars.ok(), "空 .env 不能回落默认值");
        assert!(vars.error.unwrap().contains("没有"));
    }

    #[test]
    fn falls_back_to_merged_defaults_and_labels_the_source() {
        let tree = Tree::new("vars-default");
        tree.write("sys/merged_vars.yml", VARS);
        let vars = vars(&tree);
        assert!(vars.ok());
        assert_eq!(vars.source, "sys/merged_vars.yml（默认值）");
        assert_eq!(vars.get("WEB_WGC_DOMAIN"), Some("center.dev.wist.lab"));
    }

    #[test]
    fn main_config_parse_error_blocks_public_url_check() {
        let tree = Tree::new("public-url-bad-main");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("configs/center/wist-center.toml", "[server\nbroken");
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://x}\"\n",
        );
        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);
    }

    #[test]
    fn tls_skips_san_when_vars_are_unavailable_but_still_reads_the_cert() {
        let tree = Tree::new("tls-no-vars");
        tree.write("identity/center/control-center-server.crt", TEST_CERT);
        let vars = vars(&tree);
        assert!(!vars.ok());
        let findings = tls_certificate(&tree.stack(), &vars, &profile::CENTER);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
    }

    #[test]
    fn empty_schema_file_is_a_failure() {
        let tree = Tree::new("schema-empty");
        tree.write("sys/db/initdb/01_schema.sql", "");
        let findings = database_initdb(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail);
        assert!(findings[0].title.contains("为空"), "{findings:#?}");
    }

    #[test]
    fn run_with_broken_vars_reports_one_config_vars_and_no_duplicate_codes() {
        let tree = Tree::new("run-broken-vars");
        tree.write("sys/merged_vars.yml", "variables:\n  WEB_WGC_DOMAIN: x\n");
        let findings = crate::run_with(&tree.stack(), &crate::Options { offline: true, only: None });
        let vars_findings: Vec<_> = findings
            .iter()
            .filter(|finding| finding.code == "config.vars")
            .collect();
        assert_eq!(vars_findings.len(), 1, "{findings:#?}");

        let mut codes: Vec<&str> = findings.iter().map(|f| f.code.as_str()).collect();
        let total = codes.len();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), total, "同一次运行里 code 不能重复");
    }

    #[test]
    fn offline_skips_image_probe() {
        let tree = Tree::new("offline");
        tree.write("sys/merged_vars.yml", VARS);
        let findings = image_reachable(&tree.stack(), &vars(&tree), &profile::CENTER, true);
        assert_eq!(findings[0].status, Status::Ok);
        assert_eq!(findings[0].code, "image.reachable");
    }

    #[test]
    fn image_probe_all_ok() {
        let images = vec!["a:1".to_string(), "b:1".to_string()];
        let findings = image_reachable_with(&images, &|_| Ok(()));
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn image_probe_collapses_network_errors_to_one_warning() {
        let images = vec!["a:1".to_string(), "b:1".to_string()];
        let findings = image_reachable_with(&images, &|_| Err("no such host".to_string()));
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].title.contains("不可达"), "{findings:#?}");
    }

    #[test]
    fn image_probe_reports_broken_tags_without_blocking() {
        let images = vec!["a:1".to_string()];
        let findings = image_reachable_with(&images, &|_| Err("manifest unknown".to_string()));
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(!findings[0].blocking);
        assert!(findings[0].title.contains("取不到"), "{findings:#?}");
    }

    // ── 第二轮补充：变量 / 通用工具 / compose 发现 ─────────────────────────

    #[test]
    fn expand_handles_defaults_and_missing_values() {
        let vars = BTreeMap::from([
            ("A".to_string(), "x".to_string()),
            ("EMPTY".to_string(), "".to_string()),
        ]);
        assert_eq!(expand("${A}", &vars), "x");
        assert_eq!(expand("${MISSING:-d}", &vars), "d");
        // 空值也按「没配」处理（与 gops 的 localize 一致）。
        assert_eq!(expand("${EMPTY:-d}", &vars), "d");
        assert_eq!(expand("${MISSING}", &vars), "");
        assert_eq!(expand("pre-${A}-post", &vars), "pre-x-post");
    }

    #[test]
    fn env_file_values_keep_embedded_equals_and_quotes() {
        let tree = Tree::new("env-equals");
        tree.write(".env", "URL=postgres://u:p@h/db?x=1\nQP='a=b'\nDQ=\"x\"\n");
        let vars = vars(&tree);
        assert_eq!(vars.get("URL"), Some("postgres://u:p@h/db?x=1"));
        assert_eq!(vars.get("QP"), Some("a=b"));
        assert_eq!(vars.get("DQ"), Some("x"));
    }

    #[test]
    fn lexical_path_normalization_does_not_touch_the_filesystem() {
        let path = normalize(Path::new("./a/./b/../c"));
        assert_eq!(path, PathBuf::from("a/c"));
    }

    #[test]
    fn discovers_compose_by_candidate_order() {
        let tree = Tree::new("compose-order");
        assert!(compose_file(&tree.stack()).is_none());
        tree.write("compose.yaml", "services: {}\n");
        assert_eq!(
            compose_file(&tree.stack()).unwrap(),
            tree.root.join("compose.yaml")
        );
        tree.write("sys/compose.yml", "services: {}\n");
        assert_eq!(
            compose_file(&tree.stack()).unwrap(),
            tree.root.join("sys/compose.yml")
        );
        tree.write("sys/docker-compose.yml", "services: {}\n");
        assert_eq!(
            compose_file(&tree.stack()).unwrap(),
            tree.root.join("sys/docker-compose.yml")
        );
    }

    #[test]
    fn project_name_ignores_indented_volume_names() {
        // 环境里显式设了项目名时，函数按设计优先用它；这个用例只验证「从 compose 推断」。
        if let Ok(value) = std::env::var("COMPOSE_PROJECT_NAME")
            && !value.trim().is_empty()
        {
            return;
        }
        let tree = Tree::new("project-name");
        let compose = "\
services:
  x:
    volumes:
      - v:
          name: not-the-project
";
        // 没有顶格 `name:` 时，compose 项目名 = 栈目录名（不是缩进的卷名）。
        let expected = tree.root.file_name().unwrap().to_str().unwrap().to_string();
        assert_eq!(
            compose_project_name(&tree.stack(), compose, &profile::CENTER),
            expected
        );
        let compose = "name: real-project\nservices: {}\n";
        assert_eq!(
            compose_project_name(&tree.stack(), compose, &profile::CENTER),
            "real-project"
        );
    }

    // ── 第三轮补充：端口（IPv6 / 行内写法 / 冲突归属）────────────────────

    #[test]
    fn compose_ports_support_ipv6_and_inline_lists() {
        let vars = BTreeMap::new();
        let compose = "\
services:
  a:
    ports:
      - \"[::1]:18080:8080\"
      - \"18081:8081/udp\"
      - \"3000\"
  b:
    ports: [\"127.0.0.1:18082:8443\"]
";
        let ports = compose_ports(compose, &vars);
        let by_port = |port: u16| {
            ports
                .iter()
                .find(|item| item.host_port == port)
                .unwrap_or_else(|| panic!("缺 {port}：{ports:#?}"))
        };
        assert_eq!(by_port(18080).bind_ip.as_deref(), Some("::1"));
        assert_eq!(by_port(18081).protocol, "udp");
        assert_eq!(by_port(18081).bind_ip, None);
        assert_eq!(by_port(18082).bind_ip.as_deref(), Some("127.0.0.1"));
        // 只写容器端口 = 不发布到宿主，不能拿去查冲突。
        assert!(ports.iter().all(|item| item.host_port != 3000));
    }

    #[test]
    fn port_state_detects_a_live_listener_on_loopback() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        assert_eq!(port_state(Some("127.0.0.1"), port), PortState::InUse);
        drop(listener);
        // 不断言释放后的结果：端口可能被其它进程立刻抢走，避免测试依赖时序。
    }

    #[test]
    fn port_conflicts_ignore_own_containers_and_docker_absence() {
        let tree = Tree::new("ports-own");
        tree.write("sys/merged_vars.yml", VARS);
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let held = listener.local_addr().unwrap().port();
        let compose =
            format!("services:\n  center:\n    ports:\n      - \"127.0.0.1:{held}:3100\"\n");
        tree.write("sys/docker-compose.yml", &compose);
        let vars = vars(&tree);

        let mut ours = std::collections::HashSet::new();
        ours.insert(held);
        let findings = ports_available_with(
            &tree.stack(),
            &vars,
            &profile::CENTER,
            &compose,
            Some(&ours),
        );
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");

        let none = std::collections::HashSet::new();
        let findings = ports_available_with(
            &tree.stack(),
            &vars,
            &profile::CENTER,
            &compose,
            Some(&none),
        );
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);

        let findings = ports_available_with(&tree.stack(), &vars, &profile::CENTER, &compose, None);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
    }

    // ── 第四轮补充：TLS / 身份 / 私钥 ─────────────────────────────────────

    const TEST_CERT: &str = include_str!("../tests/fixtures/test-server-cert.pem");

    fn tls_tree(tag: &str, web: &str, api: &str) -> Tree {
        let tree = Tree::new(tag);
        tree.write("sys/merged_vars.yml", VARS);
        tree.write(
            ".env",
            &format!("WEB_WGC_DOMAIN={web}\nAPI_WGC_DOMAIN={api}\n"),
        );
        tree.write("identity/center/control-center-server.crt", TEST_CERT);
        tree
    }

    #[test]
    fn tls_accepts_cert_san_covers_both_domains() {
        let tree = tls_tree("tls-ok", "center.test", "api.test");
        let findings = tls_certificate(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn tls_accepts_wildcard_one_level_and_ip_san() {
        let tree = tls_tree("tls-wild", "x.wild.test", "127.0.0.1");
        let findings = tls_certificate(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn tls_rejects_two_level_wildcard_and_suffix_attack() {
        let tree = tls_tree("tls-bad", "y.x.wild.test", "center.test.evil.net");
        let findings = tls_certificate(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);
        assert!(
            findings[0].detail.contains("y.x.wild.test"),
            "{findings:#?}"
        );
    }

    #[test]
    fn tls_reports_missing_and_invalid_cert() {
        let tree = Tree::new("tls-missing");
        tree.write("sys/merged_vars.yml", VARS);
        let findings = tls_certificate(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail);
        assert!(findings[0].blocking);

        tree.write("identity/center/control-center-server.crt", "not a pem");
        let findings = tls_certificate(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail);
        assert!(findings[0].title.contains("PEM"), "{findings:#?}");
    }

    #[cfg(unix)]
    #[test]
    fn flags_world_readable_private_keys_and_accepts_640() {
        use std::os::unix::fs::PermissionsExt;

        let tree = Tree::new("private-key");
        let key = tree.write(
            "identity/center/control-center-server.key",
            "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
        );
        fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).unwrap();
        let findings = private_key_mode(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);

        fs::set_permissions(&key, fs::Permissions::from_mode(0o640)).unwrap();
        let findings = private_key_mode(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn private_key_scan_warns_when_nothing_found() {
        let tree = Tree::new("private-key-none");
        let findings = private_key_mode(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
    }

    #[test]
    fn identity_files_only_block_on_startup_critical_material() {
        let tree = Tree::new("identity-partial");
        tree.write("identity/center/control-center.pem", "x");
        tree.write("identity/center/control-center-server.crt", "x");
        tree.write("identity/center/control-center-server.key", "x");
        let findings = identity_files(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail);
        assert!(!findings[0].blocking, "缺 CA-G / CA 私钥不该拦升级");
    }

    #[cfg(unix)]
    #[test]
    fn group_writable_secret_is_a_warning_not_a_failure() {
        use std::os::unix::fs::PermissionsExt;

        let tree = Tree::new("secret-group-write");
        for spec in profile::CENTER.secret_files {
            tree.write(spec.path, "x\n");
            let path = tree.root.join(spec.path);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let secret = tree.root.join(".wist/sec-value.yml");
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o660)).unwrap();
        let findings = secret_perms(&tree.stack(), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
    }

    // ── 第五轮补充：挂载 / public_url / 端到端 ───────────────────────────

    fn create_expected_mount_sources(tree: &Tree) {
        for spec in profile::CENTER.mounts {
            match spec.kind {
                crate::profile::MountKind::File => {
                    tree.write(spec.expected_host, "x\n");
                }
                crate::profile::MountKind::Dir => {
                    tree.mkdir(spec.expected_host);
                }
            }
        }
    }

    #[test]
    fn missing_compose_is_reported_by_layout() {
        let tree = Tree::new("mount-no-compose");
        tree.write("sys/merged_vars.yml", VARS);
        let findings = layout_mounts(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
    }

    #[test]
    fn wrong_mount_target_and_missing_source_are_reported() {
        let tree = Tree::new("mount-wrong");
        tree.write("sys/merged_vars.yml", VARS);
        let compose = full_compose().replace("/wist-center/artifacts", "/wrong/artifacts");
        tree.write("sys/docker-compose.yml", &compose);
        create_expected_mount_sources(&tree);
        let findings = layout_mounts(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].detail.contains("挂到"), "{findings:#?}");

        // 挂载点对，但宿主侧的目录没建：Docker 会把它建成 root:root。
        let tree = Tree::new("mount-missing-src");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", &full_compose());
        create_expected_mount_sources(&tree);
        fs::remove_dir_all(tree.root.join("configs/center/logs")).unwrap();
        let findings = layout_mounts(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(
            findings[0].detail.contains("configs/center/logs"),
            "{findings:#?}"
        );
    }

    #[test]
    fn long_syntax_mounts_are_accepted_end_to_end() {
        let tree = Tree::new("mount-long");
        tree.write("sys/merged_vars.yml", VARS);
        let mut compose = String::from("services:\n  x:\n    volumes:\n");
        for spec in profile::CENTER.mounts {
            compose.push_str(&format!(
                "      - type: bind\n        source: {}\n        target: {}\n",
                spec.source_expr, spec.target
            ));
        }
        tree.write("sys/docker-compose.yml", &compose);
        create_expected_mount_sources(&tree);
        let findings = layout_mounts(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn public_url_missing_env_is_a_warning() {
        let tree = Tree::new("public-url-no-env");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("configs/center/wist-center.toml", "[server]\n");
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://x}\"\n",
        );
        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
    }

    #[test]
    fn public_url_hardcoded_in_declaration_is_a_warning() {
        let tree = Tree::new("public-url-hardcoded");
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("configs/center/wist-center.toml", "[server]\n");
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"https://api.dev.wist.lab:3100\"\n",
        );
        tree.write(
            "identity/center/.env",
            "CENTER_PUBLIC_URL=https://api.dev.wist.lab:3100\n",
        );
        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Warn, "{findings:#?}");
        assert!(findings[0].detail.contains("写死"), "{findings:#?}");
    }

    #[test]
    fn public_url_with_port_443_omits_the_port() {
        let tree = Tree::new("public-url-443");
        tree.write(
            "sys/merged_vars.yml",
            "- name: WEB_WGC_DOMAIN\n  value: center.test\n- name: API_WGC_DOMAIN\n  value: api.test\n- name: CENTER_HOST_PORT\n  value: '443'\n",
        );
        tree.write("configs/center/wist-center.toml", "[server]\n");
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://x}\"\n",
        );
        tree.write(
            "identity/center/.env",
            "CENTER_PUBLIC_URL=https://api.test/\n",
        );
        let findings = public_url(&tree.stack(), &vars(&tree), &profile::CENTER);
        assert_eq!(findings[0].status, Status::Ok, "{findings:#?}");
    }

    #[test]
    fn end_to_end_green_stack_has_unique_codes() {
        let tree = Tree::new("end-to-end");
        tree.write(
            ".env",
            "WEB_WGC_DOMAIN=center.test\n\
             API_WGC_DOMAIN=api.test\n\
             CENTER_HOST_PORT=3100\n\
             CENTER_CONFIG_DIR=./configs/center\n\
             CENTER_ARTIFACT_DIR=./artifacts\n\
             GIT_PROXY_CONFIG_DIR=./configs/git-proxy\n\
             WEB_NGINX_CONF=./configs/web/nginx.conf\n\
             PG_INITDB_DIR=./sys/db/initdb\n",
        );
        tree.write("sys/merged_vars.yml", VARS);
        tree.write("sys/docker-compose.yml", &full_compose());

        // 渲染对：先写来源，再写产物。
        tree.write("configs/center/wist-center.value.json", "{}\n");
        tree.write(
            "configs/center/wist-center.toml",
            "[server]\nlisten_addr = \"0.0.0.0:3100\"\n",
        );
        tree.write("configs/git-proxy/git-proxy.value.json", "{}\n");
        tree.write("configs/git-proxy/nginx.conf", "events {}\nhttp {}\n");
        tree.write("configs/web/nginx.value.json", "{}\n");
        tree.write("configs/web/nginx.conf", "server {}\n");
        tree.write(
            "sys/configs/center/wist-center-pub.toml.tpl",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL}\"\n",
        );
        tree.write(
            "identity/center/wist-center-pub.toml",
            "[server]\npublic_url = \"${CENTER_PUBLIC_URL:-https://x}\"\n",
        );
        tree.write(
            "identity/center/.env",
            "CENTER_PUBLIC_URL=https://api.test:3100\n",
        );

        // 密钥 / 含口令文件（600）。已经渲染过的文件只改权限，不重写（否则会刷新 mtime，
        // 让上面的「渲染产物不早于值文件」误判）。
        for rel in [
            ".wist/sec-value.yml",
            "configs/center/center.env",
            "configs/center/wist-center.value.json",
            "configs/git-proxy/git-proxy.value.json",
            "configs/git-proxy/nginx.conf",
        ] {
            let path = tree.root.join(rel);
            if !path.exists() {
                tree.write(rel, "x\n");
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            }
        }

        // 站点身份：叶证书用固定 fixture（SAN 覆盖 center.test / api.test / IP）。
        tree.write("identity/center/control-center.pem", "x\n");
        tree.write("identity/center/control-center-server.crt", TEST_CERT);
        for rel in [
            "identity/center/control-center-server.key",
            "identity/center/control-center-ca.key",
            "identity/center/gateway-client-ca.pem",
            "identity/center/gateway-client-ca.key.pem",
        ] {
            tree.write(
                rel,
                "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
            );
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(tree.root.join(rel), fs::Permissions::from_mode(0o600))
                    .unwrap();
            }
        }
        tree.write("identity/center/control-center-server.san", "x\n");

        // 运行目录与建表脚本。
        for rel in [
            "configs/center/state",
            "configs/center/logs",
            "artifacts",
            "sys/db/initdb",
        ] {
            tree.mkdir(rel);
        }
        tree.write("sys/db/initdb/01_schema.sql", "CREATE TABLE t (id int);\n");

        let findings = crate::run_with(&tree.stack(), &crate::Options { offline: true, only: None });
        let bad: Vec<_> = findings
            .iter()
            .filter(|finding| finding.status != Status::Ok)
            .collect();
        assert!(bad.is_empty(), "非 OK：{bad:#?}");

        let mut codes: Vec<&str> = findings.iter().map(|f| f.code.as_str()).collect();
        let total = codes.len();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(codes.len(), total, "同一次运行里 code 不能重复");
        assert_eq!(total, 15, "判据数量变了要同步文档");
    }
}

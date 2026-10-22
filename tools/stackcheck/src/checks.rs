//! 栈级检查（center-stack）。每组只回答一个问题，输出 `Finding`（Flow Result v1 的 `checks[]`）。
//!
//! 判据全部来自**栈自己生成的东西**：`sys/merged_vars.yml` / `.env`（变量）、`configs/*`
//! （渲染产物）、`sys/docker-compose.yml`（挂载）、`identity/center/`（站点身份）、`.wist/`（密钥）。
//!
//! 每个 `code` 在一次运行里**只出现一次**（gops 对重复 code 会整份拒收结果文件）。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::profile::{MountKind, Profile};
use crate::{Finding, Stack};

// ── 变量：生效值，不是默认值 ───────────────────────────────────────────────

/// 生效变量。`error` 有值时所有依赖变量的检查都返回空 —— 由 `config.vars` 一条报出，
/// 不让同一件事刷出十几条 FAIL。
pub struct Vars {
    pub map: BTreeMap<String, String>,
    /// `.env` 或 `sys/merged_vars.yml（默认值）`。
    pub source: &'static str,
    pub error: Option<String>,
}

impl Vars {
    pub fn load(stack: &Stack) -> Self {
        match effective_vars(stack) {
            Ok((map, source)) => Self {
                map,
                source,
                error: None,
            },
            Err(err) => Self {
                map: BTreeMap::new(),
                source: "不可用",
                error: Some(err),
            },
        }
    }

    pub fn ok(&self) -> bool {
        self.error.is_none()
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.map
            .get(key)
            .map(String::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    }
}

/// 读 `sys/merged_vars.yml` 的 `- name: / value:` 对。
///
/// 用行扫描而不是引入 YAML 依赖：该文件由 gops 生成、形状固定（`- name: X` 紧接
/// `  value: Y`）。读不到时返回 `Err` —— 让检查报 FAIL，而不是静默当成「没配」。
fn merged_vars(stack: &Stack) -> Result<BTreeMap<String, String>, String> {
    let path = stack.at("sys/merged_vars.yml");
    let text =
        fs::read_to_string(&path).map_err(|err| format!("读不到 {}：{err}", path.display()))?;
    let mut out = BTreeMap::new();
    let mut name: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("- name:") {
            name = Some(unquote(rest.trim()).to_string());
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("value:")
            && let Some(current) = name.take()
        {
            out.insert(current, unquote(rest.trim()).to_string());
        }
    }
    // 文件在但一条也没解出来 = 形状变了（改名 / 截断 / 换成别的 YAML 风格）。
    // 不能静默返回空表：下面的检查会回落到缺省值，于是「什么都没配」看起来像「配对了」。
    if out.is_empty() {
        return Err(format!(
            "{} 里没有任何 `- name:` / `value:` 条目（格式不认识）",
            path.display()
        ));
    }
    Ok(out)
}

/// 读**生效值**：`gops sys localize` 把合并后的值写在栈根 `.env`。
///
/// 拿 `sys/merged_vars.yml`（INITIAL / 默认值）去判会错：现场把 `CENTER_CONFIG_DIR` 覆盖成
/// 别的路径（完全合法的现场选择）时，路径自洽会永远对不上，而这类项一旦误判就变成
/// 「升级被闸门拦住」。
fn effective_vars(stack: &Stack) -> Result<(BTreeMap<String, String>, &'static str), String> {
    let env = stack.at(".env");
    match fs::read_to_string(&env) {
        Ok(text) => {
            let mut out = BTreeMap::new();
            for line in text.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                if let Some((key, value)) = line.split_once('=') {
                    out.insert(key.trim().to_string(), unquote(value.trim()).to_string());
                }
            }
            // 文件在但一条也没解出来：不能当「不存在」去回落默认值 ——
            // 现场覆盖全丢时，拿默认值判会得出一份假绿。
            if out.is_empty() {
                return Err(format!(
                    "{} 里没有任何 KEY=VALUE 条目（空文件或格式不认识）",
                    env.display()
                ));
            }
            return Ok((out, ".env"));
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        // `.env` 存在但读不了（权限 / 是个目录）：**不能**静默回落默认值 ——
        // 那正是「检查器读默认值、现场用生效值」导致误判/漏判的那条老路。
        Err(err) => return Err(format!("读不到 {}：{err}", env.display())),
    }
    // 还没 localize 过（首次部署）：只能拿默认值，并在 detail 里写明来源。
    Ok((merged_vars(stack)?, "sys/merged_vars.yml（默认值）"))
}

fn unquote(value: &str) -> &str {
    let bytes = value.as_bytes();
    if bytes.len() >= 2
        && ((bytes[0] == b'\'' && bytes[bytes.len() - 1] == b'\'')
            || (bytes[0] == b'"' && bytes[bytes.len() - 1] == b'"'))
    {
        &value[1..value.len() - 1]
    } else {
        value
    }
}

fn env_var(path: &Path, key: &str) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((name, value)) = line.split_once('=')
            && name.trim() == key
        {
            return Some(unquote(value.trim()).to_string());
        }
    }
    None
}

// ── 通用工具 ────────────────────────────────────────────────────────────────

/// 在 TOML 文档里定位某个键，返回它**所在段的路径**（文档根 = 空串）。
fn locate_key(value: &toml::Value, key: &str, prefix: &str) -> Option<String> {
    match value {
        toml::Value::Table(table) => {
            if table.contains_key(key) {
                return Some(prefix.to_string());
            }
            for (name, child) in table {
                let child_prefix = if prefix.is_empty() {
                    name.clone()
                } else {
                    format!("{prefix}.{name}")
                };
                if let Some(hit) = locate_key(child, key, &child_prefix) {
                    return Some(hit);
                }
            }
            None
        }
        toml::Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                if let Some(hit) = locate_key(child, key, &format!("{prefix}[{index}]")) {
                    return Some(hit);
                }
            }
            None
        }
        _ => None,
    }
}

fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path)
        .ok()
        .and_then(|meta| meta.modified().ok())
}

fn trim_slash(value: &str) -> &str {
    value.trim_end_matches('/')
}

/// 词法归一：去掉 `.` 分量并折叠 `..`。
///
/// 不能用 `canonicalize`：被检查的路径可能还不存在（现场首次部署），而且它会把符号链接
/// 解析成真身 —— 而这里要比的是「配置里写的那个路径」。
fn normalize(path: &Path) -> PathBuf {
    use std::path::Component;

    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// 展开 compose 里的 `${VAR}` / `${VAR:-default}`（只认这两种）。
fn expand(raw: &str, vars: &BTreeMap<String, String>) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let expr = &after[..end];
        let (name, default) = match expr.split_once(":-") {
            Some((name, default)) => (name, Some(default)),
            None => (expr, None),
        };
        match vars.get(name.trim()) {
            Some(value) if !value.trim().is_empty() => out.push_str(value),
            _ => out.push_str(default.unwrap_or("")),
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

fn resolve_host_path(stack: &Stack, raw: &str) -> PathBuf {
    let path = Path::new(raw);
    if path.is_absolute() {
        normalize(path)
    } else {
        normalize(&stack.root.join(path))
    }
}

fn display_rel(stack: &Stack, path: &Path) -> String {
    path.strip_prefix(&stack.root)
        .unwrap_or(path)
        .display()
        .to_string()
}

fn compose_file(stack: &Stack) -> Option<PathBuf> {
    // 与 gops 的 compose 发现同口径（`sys/docker-compose.yml` 优先，也认仓根旧布局）。
    const CANDIDATES: &[&str] = &[
        "sys/docker-compose.yml",
        "sys/docker-compose.yaml",
        "sys/compose.yml",
        "sys/compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ];
    CANDIDATES
        .iter()
        .map(|name| stack.at(name))
        .find(|path| path.is_file())
}

fn is_placeholder(value: &str) -> bool {
    let lowered = value.trim().trim_end_matches('.').to_ascii_lowercase();
    // 按**域名边界**判，不用裸子串：`myexample.com` 不是占位值。
    lowered == "example.com"
        || lowered.ends_with(".example.com")
        || lowered == "warpinsight.example"
        || lowered.ends_with(".warpinsight.example")
        || lowered.contains("changeme")
}

fn api_domain(vars: &Vars) -> Option<String> {
    if let Some(raw) = vars.get("API_WGC_DOMAIN") {
        return Some(raw.to_string());
    }
    // 与 scripts/init-center.sh 同口径：留空 = 派生 `api.<WEB_WGC_DOMAIN>`。
    vars.get("WEB_WGC_DOMAIN").map(|web| format!("api.{web}"))
}

// ── 1. 渲染产物新鲜度 ──────────────────────────────────────────────────────

/// 渲染产物（`gx.tpl` 的输出）必须不早于它的值文件 —— 否则就是「改了值没重渲」。
pub fn render_freshness(stack: &Stack, profile: &Profile) -> Vec<Finding> {
    let mut out = Vec::new();
    for pair in profile.render_pairs {
        let rendered = stack.at(pair.rendered);
        let source = stack.at(pair.source);
        let (rendered_at, source_at) = (modified(&rendered), modified(&source));
        match (rendered_at, source_at) {
            // 两侧都在：正常判。
            (Some(rendered_at), Some(source_at)) => {
                if rendered_at < source_at {
                    out.push(
                        Finding::fail(
                            pair.code,
                            "渲染产物比它的值文件旧",
                            format!("{} 早于 {}", pair.rendered, pair.source),
                        )
                        .with_hint("跑一次 `gops sys localize`（改了值必须重渲才生效）"),
                    );
                } else {
                    out.push(Finding::ok(
                        pair.code,
                        "渲染产物不早于值文件",
                        pair.rendered.to_string(),
                    ));
                }
            }
            // 只有值文件：渲染没生成 → 该跑 localize（不能当成「这个组未部署」而静默跳过）。
            (None, Some(_)) => out.push(
                Finding::warn(
                    pair.code,
                    "值文件在，但渲染产物缺失",
                    pair.rendered.to_string(),
                )
                .with_hint("跑一次 `gops sys localize`"),
            ),
            // 只有渲染产物：来源（值文件 / 模板）不见了，判不了新旧，但也不能报绿。
            (Some(_), None) => out.push(
                Finding::warn(
                    pair.code,
                    "有渲染产物但找不到它的值文件/模板",
                    format!("{}；无法判定是否过期", pair.rendered),
                )
                .with_hint("确认包里没少文件；再跑一次 `gops sys localize`"),
            ),
            // 两侧都没有：这个组未部署，静默跳过。
            (None, None) => {}
        }
    }
    out
}

// ── 2. 占位符 ──────────────────────────────────────────────────────────────

/// 渲染产物里不该留占位值（`example.com` / `warpinsight.example` 之类）——
/// 否则脚本会拿它当真值去连，而且往往没人发现。
pub fn render_placeholders(stack: &Stack, profile: &Profile) -> Vec<Finding> {
    let mut hits = Vec::new();
    let mut scanned = 0usize;
    for rel in profile.placeholder_files {
        let Ok(text) = fs::read_to_string(stack.at(rel)) else {
            continue;
        };
        scanned += 1;
        for (index, line) in text.lines().enumerate() {
            let lowered = line.to_ascii_lowercase();
            for pattern in profile.placeholder_patterns {
                if lowered.contains(&pattern.to_ascii_lowercase()) {
                    hits.push(format!("{rel}:{}: {pattern}", index + 1));
                }
            }
        }
    }

    if hits.is_empty() {
        // 一个文件都没扫到 = `--root` 指错了，或配置根本还没渲染。不能报绿：
        // 那会让「什么都没查」看起来像「都没问题」。
        if scanned == 0 {
            return vec![Finding::warn(
                "render.placeholder",
                "找不到任何渲染产物，跳过占位值检查",
                "configs/ 下没有可读的配置文件（--root 指对了吗？跑过 localize 吗？）",
            )];
        }
        return vec![Finding::ok(
            "render.placeholder",
            "渲染产物里没有占位值",
            format!("扫描 {scanned} 个文件"),
        )];
    }
    let shown = hits.iter().take(10).cloned().collect::<Vec<_>>().join("；");
    vec![
        Finding::fail(
            "render.placeholder",
            "渲染产物里还有占位值",
            format!("{} 处：{shown}", hits.len()),
        )
        .with_hint(
            "把 WEB_WGC_DOMAIN / API_WGC_DOMAIN 写进 values/ 后重渲；\
             占位值会让网关连到不存在的域名",
        ),
    ]
}

// ── 3. 域名 ────────────────────────────────────────────────────────────────

/// 两个域名都必须由现场给出（或从 `WEB_WGC_DOMAIN` 派生），不能停在默认占位值。
pub fn domain_configured(vars: &Vars) -> Vec<Finding> {
    const CODE: &str = "domain.configured";
    if !vars.ok() {
        return Vec::new();
    }

    let mut problems = Vec::new();
    let web = vars.get("WEB_WGC_DOMAIN");
    let api = api_domain(vars);

    match web {
        None => problems.push("WEB_WGC_DOMAIN 为空".to_string()),
        Some(value) if is_placeholder(value) => {
            problems.push(format!("WEB_WGC_DOMAIN 还是占位值 `{value}`"));
        }
        Some(_) => {}
    }
    match api.as_deref() {
        None => problems.push("API_WGC_DOMAIN 为空（且无法从 WEB_WGC_DOMAIN 派生）".to_string()),
        Some(value) if is_placeholder(value) => {
            problems.push(format!("API_WGC_DOMAIN 还是占位值 `{value}`"));
        }
        Some(_) => {}
    }

    if problems.is_empty() {
        vec![Finding::ok(
            CODE,
            "两个域名都已配置",
            format!(
                "WEB_WGC_DOMAIN={}，API_WGC_DOMAIN={}（变量来源 {}）",
                web.unwrap_or_default(),
                api.as_deref().unwrap_or_default(),
                vars.source
            ),
        )]
    } else {
        vec![
            Finding::fail(
                CODE,
                "站点域名还是默认值",
                format!("{}（变量来源 {}）", problems.join("；"), vars.source),
            )
            .with_hint(
                "在 ops-prj 的 values/<系统名>/sys_value.yml 里写 WEB_WGC_DOMAIN（和可选的 \
                 API_WGC_DOMAIN），再 `gops sys localize`",
            ),
        ]
    }
}

// ── 4. 密钥文件权限 ────────────────────────────────────────────────────────

/// 栈根密钥与含凭据的渲染物不能被「其他用户」读到。权限位语义各家不同，这里只看 world 位。
#[cfg(not(unix))]
pub fn secret_perms(_stack: &Stack, _profile: &Profile) -> Vec<Finding> {
    vec![Finding::ok(
        "secret.file_mode",
        "非 unix 平台，跳过权限检查",
        "",
    )]
}

#[cfg(unix)]
pub fn secret_perms(stack: &Stack, profile: &Profile) -> Vec<Finding> {
    use crate::profile::Missing;
    use std::os::unix::fs::PermissionsExt;

    let mut problems = Vec::new();
    let mut warnings = Vec::new();
    let mut blocking = false;
    let mut checked = 0usize;

    for spec in profile.secret_files {
        let path = stack.at(spec.path);
        match fs::metadata(&path) {
            Ok(meta) => {
                checked += 1;
                let mode = meta.permissions().mode() & 0o777;
                if mode & 0o007 != 0 {
                    problems.push(format!(
                        "{}（{}）权限 {:o}：其他用户可读",
                        spec.path, spec.label, mode
                    ));
                    blocking |= spec.blocking;
                } else if mode & 0o020 != 0 {
                    // 属组可写 = 同组任何人都能改写口令牌。不能一律阻断（有些现场靠 660
                    // 让容器属组写入），但必须提示。
                    warnings.push(format!("{} 权限 {:o}：属组可写", spec.path, mode));
                }
            }
            Err(_) => match spec.missing {
                Missing::Skip => {}
                Missing::Warn => warnings.push(format!("缺少 {}（{}）", spec.path, spec.label)),
                Missing::Fail => {
                    problems.push(format!("缺少 {}（{}）", spec.path, spec.label));
                    blocking |= spec.blocking;
                }
            },
        }
    }

    let mut detail = problems.join("；");
    if !warnings.is_empty() {
        if !detail.is_empty() {
            detail.push_str("；另：");
        }
        detail.push_str(&warnings.join("；"));
    }

    if !problems.is_empty() {
        let mut finding = Finding::fail("secret.file_mode", "密钥 / 含凭据文件权限不合格", detail)
            .with_hint("栈根密钥与含口令的渲染物应为 600/640；world 位一律收回");
        if !blocking {
            finding = finding.non_blocking();
        }
        return vec![finding];
    }
    if !warnings.is_empty() {
        return vec![
            Finding::warn("secret.file_mode", "密钥 / 含凭据文件权限需注意", detail)
                .with_hint("若不需要属组写入，收到 640"),
        ];
    }
    vec![Finding::ok(
        "secret.file_mode",
        "密钥与凭据文件权限正常",
        format!("检查 {checked} 个文件"),
    )]
}

/// 私钥：扫 `identity/`，按**内容**识别（不靠文件名猜），world 可读一律 FAIL。
pub fn private_key_mode(stack: &Stack, profile: &Profile) -> Vec<Finding> {
    #[cfg(not(unix))]
    {
        let _ = (stack, profile);
        return vec![Finding::ok(
            "secret.private_key_mode",
            "非 unix 平台，跳过权限检查",
            "",
        )];
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let mut files = Vec::new();
        for root in profile.private_key_roots {
            walk_files(&stack.at(root), 5, &mut files);
        }

        let mut leaked = Vec::new();
        let mut checked = 0usize;
        for path in files {
            let Ok(meta) = fs::metadata(&path) else {
                continue;
            };
            if meta.len() > 512 * 1024 {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else {
                continue;
            };
            if !text.contains("PRIVATE KEY") {
                continue;
            }
            checked += 1;
            let mode = meta.permissions().mode() & 0o777;
            if mode & 0o007 != 0 {
                leaked.push(format!("{}（{:o}）", display_rel(stack, &path), mode));
            }
        }

        if !leaked.is_empty() {
            return vec![
                Finding::fail(
                    "secret.private_key_mode",
                    "私钥对其他用户可读",
                    leaked.join("；"),
                )
                .with_hint("私钥应为 600/640；world 位一律收回"),
            ];
        }
        if checked == 0 {
            // 没扫到 ≠ 没问题：`identity/` 可能还没生成，或私钥被挪走了。
            return vec![Finding::warn(
                "secret.private_key_mode",
                "没有扫到任何私钥文件",
                format!(
                    "扫描 {} 个根目录；站点身份尚未生成？",
                    profile.private_key_roots.join("、")
                ),
            )];
        }
        vec![Finding::ok(
            "secret.private_key_mode",
            "私钥文件不对其他用户开放",
            format!("检查 {checked} 个私钥文件"),
        )]
    }
}

fn walk_files(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_files(&path, depth - 1, out);
        } else if path.is_file() {
            out.push(path);
        }
    }
}

// ── 5. 站点身份文件 ────────────────────────────────────────────────────────

/// 身份是「证书 + 私钥」一对：缺叶证书/私钥会直接坏；缺 CA 私钥或 CA-G 只影响以后的操作。
pub fn identity_files(stack: &Stack, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "identity.center_files";
    let mut missing = Vec::new();
    let mut blocking = false;
    let mut checked = 0usize;

    for spec in profile.identity_files {
        checked += 1;
        if stack.at(spec.path).is_file() {
            continue;
        }
        missing.push(format!("{}（{}）", spec.path, spec.label));
        blocking |= spec.blocking;
    }

    if missing.is_empty() {
        return vec![Finding::ok(
            CODE,
            "站点身份文件齐全",
            format!("检查 {checked} 项"),
        )];
    }
    let mut finding = Finding::fail(CODE, "站点身份文件缺失", missing.join("；")).with_hint(
        "跑一次 `gops sys localize`（init-center.sh 会补齐身份）；\
         CA 私钥与 CA-G 丢了要显式轮换，不能静默重生成",
    );
    if !blocking {
        finding = finding.non_blocking();
    }
    vec![finding]
}

// ── 6. TLS 证书 ────────────────────────────────────────────────────────────

/// 中心叶证书必须在有效期内、且 SAN 覆盖**两个**域名（管理面 + 网关面）。
///
/// 不能用子串匹配：`*.a.b` 只覆盖**一层**，`gw.example.com.evil.net` 也不能算覆盖
/// `gw.example.com`。
pub fn tls_certificate(stack: &Stack, vars: &Vars, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "tls.san_covers_domain";

    let path = stack.at(profile.tls.cert);
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
    let Ok((_, pem)) = x509_parser::pem::parse_x509_pem(&bytes) else {
        return vec![Finding::fail(
            CODE,
            "中心服务器叶证书不是合法 PEM",
            path.display().to_string(),
        )];
    };
    let Ok((_, cert)) = x509_parser::parse_x509_certificate(&pem.contents) else {
        return vec![Finding::fail(
            CODE,
            "中心服务器叶证书无法解析",
            path.display().to_string(),
        )];
    };

    let validity = cert.validity();
    if !validity.is_valid() {
        return vec![
            Finding::fail(
                CODE,
                "中心服务器叶证书不在有效期内",
                format!(
                    "notBefore={} notAfter={}",
                    validity.not_before, validity.not_after
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
    if let Some(web) = vars.get("WEB_WGC_DOMAIN") {
        domains.push(("WEB_WGC_DOMAIN", web.to_string()));
    }
    if let Some(api) = api_domain(vars) {
        domains.push(("API_WGC_DOMAIN", api));
    }
    domains.retain(|(_, value)| !value.trim().is_empty());
    if domains.is_empty() {
        return vec![Finding::warn(
            CODE,
            "WEB_WGC_DOMAIN / API_WGC_DOMAIN 都为空，跳过 SAN 判定",
            "证书本身在有效期内（这一项只能判 expire）",
        )];
    }

    let dns = certificate_dns_names(&cert);
    let ips = certificate_ip_names(&cert);
    let mut uncovered = Vec::new();
    for (label, domain) in &domains {
        let domain = domain.trim();
        // 允许 `[::1]` 这种方括号写法（与 compose 的 IPv6 书写一致）。
        let ip_candidate = domain
            .strip_prefix('[')
            .and_then(|value| value.strip_suffix(']'))
            .unwrap_or(domain);
        let ok = match ip_candidate.parse::<std::net::IpAddr>() {
            Ok(ip) => ips.contains(&ip),
            Err(_) => dns.iter().any(|san| san_covers(san, domain)),
        };
        if !ok {
            uncovered.push(format!("{label}={domain}"));
        }
    }

    if uncovered.is_empty() {
        vec![Finding::ok(
            CODE,
            "叶证书 SAN 覆盖两个域名",
            format!(
                "{} ∈ [{}]",
                domains
                    .iter()
                    .map(|(label, value)| format!("{label}={value}"))
                    .collect::<Vec<_>>()
                    .join("，"),
                dns.join(", ")
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
                    dns.join(", ")
                ),
            )
            .with_hint(
                "跑一次 `gops sys localize`（ensure-center-server-cert.sh 发现 SAN 缺域名会重签）",
            ),
        ]
    }
}

fn certificate_dns_names(cert: &x509_parser::prelude::X509Certificate<'_>) -> Vec<String> {
    cert.subject_alternative_name()
        .ok()
        .flatten()
        .map(|extension| {
            extension
                .value
                .general_names
                .iter()
                .filter_map(|name| match name {
                    x509_parser::extensions::GeneralName::DNSName(dns) => Some((*dns).to_string()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn certificate_ip_names(cert: &x509_parser::prelude::X509Certificate<'_>) -> Vec<std::net::IpAddr> {
    cert.subject_alternative_name()
        .ok()
        .flatten()
        .map(|extension| {
            extension
                .value
                .general_names
                .iter()
                .filter_map(|name| match name {
                    x509_parser::extensions::GeneralName::IPAddress(bytes) => ip_from_bytes(bytes),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn ip_from_bytes(bytes: &[u8]) -> Option<std::net::IpAddr> {
    match bytes.len() {
        4 => Some(std::net::IpAddr::from([
            bytes[0], bytes[1], bytes[2], bytes[3],
        ])),
        16 => {
            let mut raw = [0u8; 16];
            raw.copy_from_slice(bytes);
            Some(std::net::IpAddr::from(raw))
        }
        _ => None,
    }
}

/// 证书 SAN 是否覆盖某个域名：**精确相等**，或通配符只覆盖**一层**。
fn san_covers(san: &str, domain: &str) -> bool {
    let san = san.trim().trim_end_matches('.').to_ascii_lowercase();
    let domain = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    if san == domain {
        return true;
    }
    let Some(suffix) = san.strip_prefix("*.") else {
        return false;
    };
    domain
        .strip_suffix(suffix)
        .and_then(|head| head.strip_suffix('.'))
        .is_some_and(|label| !label.is_empty() && !label.contains('.'))
}

// ── 7. 挂载 / 落点自洽 ────────────────────────────────────────────────────

/// compose 里的 bind 挂载、变量展开后的落点、localize 实际写入的位置，三者必须对得上。
///
/// 这一组防的是「配置写在一处、容器读另一处」：现场把 `CENTER_CONFIG_DIR` 覆盖成别的路径，
/// 而 `operators.gxl` 仍渲染到 `configs/center` —— 解析通过、容器起来、中心读到的是旧文件。
pub fn layout_mounts(stack: &Stack, vars: &Vars, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "layout.mounts";

    let Some(compose_path) = compose_file(stack) else {
        return vec![
            Finding::fail(
                CODE,
                "找不到 compose 文件",
                "按 gops 的候选顺序（sys/docker-compose.yml 等）都没找到",
            )
            .with_hint("确认栈目录完整（`sys/docker-compose.yml` 随制品发布）"),
        ];
    };
    let compose = match fs::read_to_string(&compose_path) {
        Ok(text) => text,
        Err(err) => {
            return vec![Finding::fail(
                CODE,
                "读不到 compose 文件",
                format!("{}：{err}", compose_path.display()),
            )];
        }
    };
    if !vars.ok() {
        return Vec::new();
    }

    let mut problems = Vec::new();
    for spec in profile.mounts {
        match compose_mount_target(&compose, spec.source_expr) {
            None => {
                problems.push(format!(
                    "compose 里找不到 `{}:{}` 的挂载",
                    spec.source_expr, spec.target
                ));
                continue;
            }
            Some(found) if trim_slash(&found) != trim_slash(spec.target) => {
                problems.push(format!(
                    "`{}` 挂到 `{found}`，配置期望 `{}`",
                    spec.source_expr, spec.target
                ));
                continue;
            }
            Some(_) => {}
        }

        let expanded = expand(spec.source_expr, &vars.map);
        let actual = resolve_host_path(stack, &expanded);
        let expected = resolve_host_path(stack, spec.expected_host);
        if actual != expected {
            problems.push(format!(
                "`{}` 展开为 `{}`，但 localize 写到 `{}`（变量被覆盖成别的路径？）",
                spec.source_expr,
                display_rel(stack, &actual),
                spec.expected_host
            ));
        }

        let exists = match spec.kind {
            MountKind::File => expected.is_file(),
            MountKind::Dir => expected.is_dir(),
        };
        if !exists {
            problems.push(format!(
                "`{}` 不存在（{}）",
                spec.expected_host,
                match spec.kind {
                    MountKind::File => "文件",
                    MountKind::Dir => "目录",
                }
            ));
        }
    }

    if problems.is_empty() {
        vec![Finding::ok(
            CODE,
            "compose 挂载与落点自洽",
            format!(
                "检查 {} 条挂载（变量来源 {}）",
                profile.mounts.len(),
                vars.source
            ),
        )]
    } else {
        vec![
            Finding::fail(CODE, "compose 挂载与落点不一致", problems.join("；")).with_hint(
                "别单独覆盖 CENTER_CONFIG_DIR / CENTER_ARTIFACT_DIR / GIT_PROXY_CONFIG_DIR / \
                 PG_INITDB_DIR / WEB_NGINX_CONF：localize 按固定路径渲染；\
                 缺目录先跑 `gops sys localize`（Docker 会把缺失目录建成 root:root）",
            ),
        ]
    }
}

/// 从 compose 文本里取某个 `${VAR}` 源对应的容器 target。
/// 短语法（`- src:dst[:ro]`）与长语法（`source:` + `target:`）都认。
fn compose_mount_target(compose: &str, source_expr: &str) -> Option<String> {
    let lines: Vec<&str> = compose.lines().collect();

    // 短语法：`- ${PACKAGE_DIR}:/packages:ro`
    for line in &lines {
        let Some(rest) = line.trim().strip_prefix("- ") else {
            continue;
        };
        let rest = rest.trim_matches('"').trim_matches('\'');
        let Some((src, dst)) = rest.split_once(':') else {
            continue;
        };
        if src.trim() != source_expr {
            continue;
        }
        return Some(
            dst.split(':')
                .next()
                .unwrap_or(dst)
                .trim()
                .trim_matches('"')
                .trim_matches('\'')
                .to_string(),
        );
    }

    // 长语法：
    //   - type: bind
    //     source: ${PACKAGE_DIR}
    //     target: /packages
    // `target` 可能在本条目的 source 之前或之后；只在**同一条目**里找
    // （遇到下一条 `- ` 就停），否则会把上一个挂载的 target 配给下一个 source。
    for (index, line) in lines.iter().enumerate() {
        let Some((_, value)) = line.split_once("source:") else {
            continue;
        };
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .trim_end_matches(',');
        if value != source_expr {
            continue;
        }
        for candidate in lines.iter().skip(index + 1) {
            if candidate.trim().starts_with("- ") {
                break;
            }
            if let Some((_, target)) = candidate.split_once("target:") {
                return Some(clean_mount_value(target));
            }
        }
        for candidate in lines[..index].iter().rev() {
            if candidate.trim().starts_with("- ") {
                // 本条目的起始行：它自己也可能带 target（`- target: /packages`）。
                if let Some((_, target)) = candidate.split_once("target:") {
                    return Some(clean_mount_value(target));
                }
                break;
            }
            if let Some((_, target)) = candidate.split_once("target:") {
                return Some(clean_mount_value(target));
            }
        }
    }
    None
}

fn clean_mount_value(value: &str) -> String {
    value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim_end_matches(',')
        .to_string()
}

// ── 8. 现场态 public_url ──────────────────────────────────────────────────

/// `public_url` 是站点现场事实：声明只写 `${VAR}`，真值在 `identity/center/.env`。
///
/// 两个必须查的矛盾：
/// 1. 主配置里**不能**再出现 `public_url`（两份配置叶子键重复会让中心拒启）；
/// 2. `.env` 里的值必须与当前 `API_WGC_DOMAIN` / `CENTER_HOST_PORT` 一致 —— 改了域名但
///    `.env` 不跟着改（localize 永不覆盖现场值），脚本会继续 POST 到旧域名，且长期没人发现。
pub fn public_url(stack: &Stack, vars: &Vars, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "layout.public_url";
    let spec = &profile.public_url;
    let mut blocking_problems = Vec::new();
    let mut soft_problems = Vec::new();
    let mut warnings = Vec::new();

    // 1) 主配置不得重复定义 public_url。
    let main = stack.at(spec.main_config);
    match fs::read_to_string(&main) {
        Ok(text) => match toml::from_str::<toml::Value>(&text) {
            Ok(doc) => {
                if let Some(section) = locate_key(&doc, "public_url", "") {
                    let where_ = if section.is_empty() {
                        "文档根".to_string()
                    } else {
                        format!("段 `{section}`")
                    };
                    blocking_problems.push(format!(
                        "主配置 {} 的{where_}里出现了 public_url；两份配置叶子键重复会让中心拒启",
                        spec.main_config
                    ));
                }
            }
            Err(err) => {
                blocking_problems.push(format!("主配置 {} 无法解析：{err}", spec.main_config))
            }
        },
        Err(_) => warnings.push(format!(
            "主配置 {} 尚未渲染（跳过重复键检查）",
            spec.main_config
        )),
    }

    // 2) 现场态声明必须在。
    let declaration = stack.at(spec.declaration);
    if !declaration.is_file() {
        blocking_problems.push(format!(
            "缺少现场态声明 {}（`WIST_CENTER_PUB_CONFIG` 指向它）",
            spec.declaration
        ));
    } else if let Ok(text) = fs::read_to_string(&declaration)
        && let Ok(doc) = toml::from_str::<toml::Value>(&text)
    {
        let value = doc
            .get("server")
            .and_then(|server| server.get("public_url"))
            .and_then(|value| value.as_str());
        match value {
            None => {
                blocking_problems.push(format!("{} 里没有 `[server] public_url`", spec.declaration))
            }
            Some(raw) if !raw.contains(&format!("${{{}", spec.env_var)) => warnings.push(format!(
                "{} 的 public_url 不是 `${{{}}}` 引用（值被写死，改域名不会生效）",
                spec.declaration, spec.env_var
            )),
            Some(_) => {}
        }
    }

    // 3) `.env` 的生效值必须与当前域名 / 端口一致。
    if vars.ok() {
        match env_var(&stack.at(spec.env), spec.env_var) {
            None => warnings.push(format!(
                "{} 没有 {}；中心会回落到声明里的默认值（占位域名）",
                spec.env, spec.env_var
            )),
            Some(value) if value.trim().is_empty() => warnings.push(format!(
                "{} 的 {} 为空；中心会回落到声明里的默认值（占位域名）",
                spec.env, spec.env_var
            )),
            Some(value) => {
                if let Some(expected) = expected_public_url(vars, spec)
                    && normalize_url(&value) != normalize_url(&expected)
                {
                    soft_problems.push(format!(
                        "{}={}，但按当前变量应为 {}（改域名后 .env 不会自动更新）",
                        spec.env_var, value, expected
                    ));
                }
            }
        }
    }

    if !blocking_problems.is_empty() {
        return vec![
            Finding::fail(
                CODE,
                "现场态 public_url 与主配置冲突",
                blocking_problems.join("；"),
            )
            .with_hint("主配置里不能出现 public_url（叶子键与现场态声明重复会拒启）"),
        ];
    }
    if !soft_problems.is_empty() {
        // 不阻断：跑着的栈还是好的，错的只是「以后生成的网关安装 URL」。
        return vec![
            Finding::fail(
                CODE,
                "现场态 public_url 与当前域名/端口不一致",
                soft_problems.join("；"),
            )
            .non_blocking()
            .with_hint(
                "改 identity/center/.env 的 CENTER_PUBLIC_URL（localize 永不覆盖现场值）；\
                 改域名后必须手动跟着改，否则网关会连到旧地址",
            ),
        ];
    }
    if !warnings.is_empty() {
        return vec![Finding::warn(
            CODE,
            "现场态 public_url 尚未定型",
            warnings.join("；"),
        )];
    }
    vec![Finding::ok(
        CODE,
        "现场态 public_url 与站点域名一致",
        format!("{}（变量来源 {}）", spec.declaration, vars.source),
    )]
}

fn expected_public_url(vars: &Vars, spec: &crate::profile::PublicUrlSpec) -> Option<String> {
    let host = api_domain(vars)?;
    if host.trim().is_empty() {
        return None;
    }
    let port = vars.get(spec.port_var).unwrap_or(spec.default_port);
    if port == "443" {
        Some(format!("https://{host}"))
    } else {
        Some(format!("https://{host}:{port}"))
    }
}

fn normalize_url(value: &str) -> String {
    value.trim().trim_end_matches('/').to_ascii_lowercase()
}

// ── 9. 数据库初始化脚本 ───────────────────────────────────────────────────

/// `db-schema` 每次 start 都会读 `01_schema.sql`；文件丢了不是「以后再说」，是本次启动就坏。
pub fn database_initdb(stack: &Stack, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "database.initdb";
    let path = stack.at(profile.schema_file);
    match fs::metadata(&path) {
        Ok(meta) if meta.is_file() && meta.len() > 0 => vec![Finding::ok(
            CODE,
            "PG 建表脚本就位",
            profile.schema_file.to_string(),
        )],
        Ok(_) => vec![
            Finding::fail(CODE, "PG 建表脚本为空", profile.schema_file.to_string())
                .with_hint("从版本包恢复 sys/db/initdb/01_schema.sql"),
        ],
        Err(err) => vec![
            Finding::fail(
                CODE,
                "缺少 PG 建表脚本",
                format!("{}：{err}", path.display()),
            )
            .with_hint("db-schema 每次 start 都会读它；从版本包恢复 sys/db/initdb/"),
        ],
    }
}

// ── 10. 宿主端口 ──────────────────────────────────────────────────────────

/// 一个发布到宿主的端口。
#[derive(Debug, Clone, PartialEq, Eq)]
struct PublishedPort {
    host_port: u16,
    protocol: String,
    bind_ip: Option<String>,
}

/// 取 compose 里**所有**同名块键（`ports:`）下缩进更深的行。
fn compose_blocks<'a>(compose: &'a str, key: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut block_indent: Option<usize> = None;
    let header = format!("{key}:");
    for line in compose.lines() {
        let trimmed = line.trim();
        let indent = line.len() - line.trim_start().len();
        let is_header = trimmed == header || trimmed.starts_with(&header);
        match block_indent {
            Some(base) if indent > base => {
                if !trimmed.is_empty() && !trimmed.starts_with('#') {
                    out.push(line);
                }
            }
            Some(_) | None => {
                block_indent = is_header.then_some(indent);
            }
        }
    }
    out
}

fn compose_ports(compose: &str, vars: &BTreeMap<String, String>) -> Vec<PublishedPort> {
    let mut out = Vec::new();

    // 行内写法：`ports: ["127.0.0.1:3100:3100"]`。块写法不会命中这里（冒号后为空）。
    for line in compose.lines() {
        let trimmed = line.trim();
        let Some(rest) = trimmed.strip_prefix("ports:") else {
            continue;
        };
        let rest = rest.trim();
        if rest.is_empty() || rest.starts_with('{') {
            continue;
        }
        let list = rest.trim_start_matches('[').trim_end_matches(']');
        for item in list.split(',') {
            if let Some(port) = parse_short_port(item) {
                out.push(port);
            }
        }
    }

    let lines = compose_blocks(compose, "ports");
    let mut index = 0usize;
    while index < lines.len() {
        let line = lines[index].trim();
        index += 1;
        let Some(item) = line.strip_prefix("- ") else {
            continue; // 长语法的后续键，已在上一个条目里处理
        };
        // 长语法：`- target: 3000` 加后续 `published: 443` / `host_ip: 127.0.0.1` / `protocol: udp`
        if item.contains("target:") || item.contains("published:") {
            let mut published = None;
            let mut protocol = "tcp".to_string();
            let mut bind_ip = None;
            let mut scan = |text: &str| {
                if let Some((_, value)) = text.split_once("published:")
                    && let Ok(port) = value.trim().trim_matches('"').trim_end_matches(',').parse()
                {
                    published = Some(port);
                }
                if let Some((_, value)) = text.split_once("protocol:") {
                    protocol = value
                        .trim()
                        .trim_matches('"')
                        .trim_end_matches(',')
                        .to_string();
                }
                if let Some((_, value)) = text.split_once("host_ip:") {
                    let value = value.trim().trim_matches('"').trim_end_matches(',');
                    if !value.is_empty() {
                        bind_ip = Some(value.to_string());
                    }
                }
            };
            scan(item);
            while index < lines.len() && !lines[index].trim().starts_with("- ") {
                scan(lines[index]);
                index += 1;
            }
            if let Some(host_port) = published {
                out.push(PublishedPort {
                    host_port,
                    protocol,
                    bind_ip,
                });
            }
            continue;
        }
        // 短语法：`"[ip:]host:container[/proto]"`
        let expanded = expand(item.trim().trim_matches('"'), vars);
        if let Some(port) = parse_short_port(&expanded) {
            out.push(port);
        }
    }
    out
}

/// 短语法 `"[ip:]host:container[/proto]"`。
///
/// IPv6 的宿主地址必须带方括号（`[::1]:8080:80`）：直接按 `:` 切会把它
/// 错当成「段数不对」而**静默跳过**，于是端口冲突永远查不出来。
fn parse_short_port(raw: &str) -> Option<PublishedPort> {
    let owned = raw.trim().trim_matches('"').trim_matches('\'');
    let (spec, protocol) = match owned.split_once('/') {
        Some((spec, protocol)) => (spec, protocol.to_string()),
        None => (owned, "tcp".to_string()),
    };

    let (bracket_ip, rest) = match spec.strip_prefix('[') {
        Some(after) => {
            let (ip, tail) = after.split_once(']')?;
            (Some(ip.to_string()), tail.strip_prefix(':')?)
        }
        None => (None, spec),
    };

    let parts: Vec<&str> = rest.split(':').collect();
    // 2 段时**第一段**才是宿主端口 —— 取错就会拿容器端口去查宿主，永远查不出冲突。
    let (host, bind_ip) = match (parts.as_slice(), bracket_ip) {
        ([host, _container], None) => (*host, None),
        ([ip, host, _container], None) => (*host, Some((*ip).to_string())),
        ([host, _container], Some(ip)) => (*host, Some(ip)),
        _ => return None, // 只写了容器端口 / 形状不认识 = 不发布到宿主
    };
    let host_port = host.trim().parse::<u16>().ok()?;
    Some(PublishedPort {
        host_port,
        protocol,
        bind_ip,
    })
}

fn compose_images(compose: &str, vars: &BTreeMap<String, String>) -> Vec<String> {
    let mut out = Vec::new();
    for line in compose.lines() {
        let trimmed = line.trim();
        let Some(value) = trimmed.strip_prefix("image:") else {
            continue;
        };
        let image = expand(value.trim().trim_matches('"').trim_matches('\''), vars);
        // 同一镜像常被多个一次性任务复用（db-init / db-schema 都用 postgres）：
        // 去重后再并行探，避免同一次体检对一个 registry 发多份请求。
        if !image.is_empty() && !out.contains(&image) {
            out.push(image);
        }
    }
    out
}

/// 解析 `docker ps --format '{{.Ports}}'` 的发布端口（`0.0.0.0:443->3000/tcp, …`）。
///
/// **必须同时按逗号和换行切**：`--format` 每个容器一行，行之间没有逗号；
/// 只按逗号切会把「上一行最后一个映射 + 下一行第一个映射」并成一块，
/// 而 `split_once("->")` 只取第一个 —— 下一行第一个发布的端口会被静默漏掉。
fn published_ports_from_ps(output: &str) -> std::collections::HashSet<u16> {
    let mut ours = std::collections::HashSet::new();
    for chunk in output.split([',', '\n']) {
        let Some((host_side, _)) = chunk.split_once("->") else {
            continue;
        };
        let Some((_, port)) = host_side.trim().rsplit_once(':') else {
            continue;
        };
        if let Ok(port) = port.parse::<u16>() {
            ours.insert(port);
        }
    }
    ours
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PortState {
    Free,
    InUse,
    Unknown,
}

fn port_state(bind_ip: Option<&str>, port: u16) -> PortState {
    let try_bind = |addr: &str| -> PortState {
        match std::net::TcpListener::bind((addr, port)) {
            Ok(_) => PortState::Free,
            Err(err) if err.kind() == std::io::ErrorKind::AddrInUse => PortState::InUse,
            Err(_) => PortState::Unknown,
        }
    };

    // 先按 compose 里写的 bind IP 试：中心多数端口只绑 127.0.0.1。
    // 绑不上（IP 不在本机 / 权限）时回落到通配，别把「地址不可用」误报成「端口被占」。
    if let Some(ip) = bind_ip.filter(|ip| !ip.is_empty() && *ip != "0.0.0.0") {
        match try_bind(ip) {
            PortState::Free => return PortState::Free,
            PortState::InUse => return PortState::InUse,
            PortState::Unknown => {}
        }
    }
    try_bind("0.0.0.0")
}

/// compose 的**项目名**（容器标签 `com.docker.compose.project` 的值）。
///
/// 不用 `project.working_dir`：栈目录搬过位置后，仍在跑的容器带的是**旧路径**标签，
/// 按路径过滤会漏掉自己。项目名跨路径稳定。
fn compose_project_name(stack: &Stack, compose: &str, profile: &Profile) -> String {
    if let Ok(value) = std::env::var("COMPOSE_PROJECT_NAME")
        && !value.trim().is_empty()
    {
        return value.trim().to_string();
    }
    for line in compose.lines() {
        // 只认**顶格**的 `name:`（项目名）。缩进的是 volumes/networks 里的名字。
        if line.starts_with(' ') || line.starts_with('\t') {
            continue;
        }
        let Some(value) = line.strip_prefix("name:") else {
            continue;
        };
        let value = value.trim().trim_matches('"').trim_matches('\'');
        if !value.is_empty() {
            return value.to_string();
        }
        break;
    }
    stack
        .root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(profile.project_fallback)
        .to_string()
}

fn our_published_ports(
    stack: &Stack,
    compose: &str,
    profile: &Profile,
) -> Option<std::collections::HashSet<u16>> {
    let filter = format!(
        "label=com.docker.compose.project={}",
        compose_project_name(stack, compose, profile)
    );
    let (ok, stdout, _) = run_with_timeout(
        "docker",
        &["ps", "--filter", &filter, "--format", "{{.Ports}}"],
        10,
    )?;
    ok.then(|| published_ports_from_ps(&stdout))
}

/// 发布到宿主的端口是否真的空着。
///
/// 必须排除**本栈自己**占着的端口：升级的 `localize` 阶段容器正在跑，
/// 不排除就会每次误报。
pub fn ports_available(stack: &Stack, vars: &Vars, profile: &Profile) -> Vec<Finding> {
    const CODE: &str = "port.available";
    if !vars.ok() {
        return Vec::new();
    }
    let Some(compose_path) = compose_file(stack) else {
        return Vec::new(); // 缺 compose 已由 layout.mounts 报
    };
    let Ok(compose) = fs::read_to_string(&compose_path) else {
        return vec![Finding::warn(CODE, "读不到 compose，跳过端口检查", "")];
    };
    let ours = our_published_ports(stack, &compose, profile);
    ports_available_with(stack, vars, profile, &compose, ours.as_ref())
}

/// 可注入「本栈已发布的端口」的版本：测试里不需要真的起 docker。
fn ports_available_with(
    stack: &Stack,
    vars: &Vars,
    profile: &Profile,
    compose: &str,
    ours: Option<&std::collections::HashSet<u16>>,
) -> Vec<Finding> {
    const CODE: &str = "port.available";
    let _ = (stack, profile);
    if !vars.ok() {
        return Vec::new();
    }
    let ports = compose_ports(compose, &vars.map);
    if ports.is_empty() {
        return vec![Finding::ok(CODE, "没有发布到宿主的端口", "")];
    }
    let Some(ours) = ours else {
        return vec![
            Finding::warn(
                CODE,
                "无法确认端口归属，跳过占用检查",
                "docker 不可用（没装或守护进程没起）",
            )
            .with_hint("栈跑着时端口本就被自己占着；手工确认用 `docker ps` / `lsof -i`"),
        ];
    };

    let mut conflicts = Vec::new();
    let mut unknown = Vec::new();
    let mut skipped = 0usize;
    for port in &ports {
        if port.protocol != "tcp" || ours.contains(&port.host_port) {
            skipped += 1;
            continue;
        }
        match port_state(port.bind_ip.as_deref(), port.host_port) {
            PortState::InUse => conflicts.push(port.host_port),
            PortState::Unknown => unknown.push(port.host_port),
            PortState::Free => {}
        }
    }
    conflicts.sort_unstable();
    conflicts.dedup();

    if !conflicts.is_empty() {
        return vec![
            Finding::fail(
                CODE,
                "宿主端口已被别的进程占用",
                format!(
                    "占用中：{}",
                    conflicts
                        .iter()
                        .map(u16::to_string)
                        .collect::<Vec<_>>()
                        .join("、")
                ),
            )
            .with_hint("`compose up` 会失败（port is already allocated）；腾端口或改 *_PORT"),
        ];
    }
    if !unknown.is_empty() {
        unknown.sort_unstable();
        unknown.dedup();
        return vec![
            Finding::warn(
                CODE,
                "部分端口无法判定（bind IP 不在本机或无权限）",
                format!(
                    "无法判定：{}",
                    unknown
                        .iter()
                        .map(u16::to_string)
                        .collect::<Vec<_>>()
                        .join("、")
                ),
            )
            .with_hint("确认 *_BIND_IP 是本机网卡地址；`compose up` 前用 `lsof -i` 核对"),
        ];
    }
    let checked = ports.len() - skipped;
    if checked == 0 {
        return vec![Finding::ok(
            CODE,
            "端口都由本栈自己占着，跳过占用检查",
            format!("{} 个发布端口（栈在运行）", ports.len()),
        )];
    }
    vec![Finding::ok(
        CODE,
        "宿主端口都空着",
        format!(
            "已检查 {checked}/{}（{} 个由本栈占着 / udp）",
            ports.len(),
            skipped
        ),
    )]
}

fn run_with_timeout(program: &str, args: &[&str], secs: u64) -> Option<(bool, String, String)> {
    use std::process::{Command, Stdio};

    let mut child = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = child.wait_with_output().ok()?;
                return Some((
                    status.success(),
                    String::from_utf8_lossy(&output.stdout).to_string(),
                    String::from_utf8_lossy(&output.stderr).to_string(),
                ));
            }
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Some((false, String::new(), format!("超时（{secs}s）")));
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(err) => return Some((false, String::new(), err.to_string())),
        }
    }
}

// ── 11. 镜像可达 ──────────────────────────────────────────────────────────

/// 网络类错误（整个站点离线时会全部命中）—— 收敛成一条提示，不按镜像刷屏。
fn looks_like_network_error(message: &str) -> bool {
    let lowered = message.to_ascii_lowercase();
    [
        "no such host",
        "timeout",
        "超时",
        "connection refused",
        "temporary failure in name resolution",
        "network is unreachable",
        "i/o timeout",
        "tls handshake timeout",
        "context deadline exceeded",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
}

pub fn image_reachable(
    stack: &Stack,
    vars: &Vars,
    profile: &Profile,
    offline: bool,
) -> Vec<Finding> {
    const CODE: &str = "image.reachable";
    let _ = profile;
    if offline {
        return vec![Finding::ok(CODE, "跳过镜像可达检查（--offline）", "")];
    }
    if !vars.ok() {
        return Vec::new();
    }
    let Some(compose_path) = compose_file(stack) else {
        return Vec::new();
    };
    let Ok(compose) = fs::read_to_string(&compose_path) else {
        return Vec::new();
    };
    let images = compose_images(&compose, &vars.map);
    if images.is_empty() {
        return vec![Finding::ok(CODE, "compose 里没有镜像", "")];
    }

    image_reachable_with(&images, &|image| {
        // 本地已有 → 不需要网络（`pull` 也会直接跳过）；这一步 55ms，远端 manifest 可能 34s。
        if let Some((true, _, _)) = run_with_timeout("docker", &["image", "inspect", image], 5) {
            return Ok(());
        }
        let Some((ok, _, stderr)) = run_with_timeout("docker", &["manifest", "inspect", image], 6)
        else {
            return Err("docker 不可用".to_string());
        };
        if ok {
            Ok(())
        } else {
            Err(stderr
                .trim()
                .lines()
                .next()
                .unwrap_or("未知错误")
                .to_string())
        }
    })
}

fn image_reachable_with(
    images: &[String],
    probe: &(dyn Fn(&str) -> Result<(), String> + Sync),
) -> Vec<Finding> {
    const CODE: &str = "image.reachable";
    let mut broken = Vec::new();
    let mut offline = 0usize;
    // 并行探测：串行时一个慢 registry 会把体检拖成几十秒（实测单个 34s）。
    let results: Vec<Result<(), String>> = std::thread::scope(|scope| {
        let handles: Vec<_> = images
            .iter()
            .map(|image| scope.spawn(move || probe(image)))
            .collect();
        handles
            .into_iter()
            .map(|handle| {
                handle
                    .join()
                    .unwrap_or_else(|_| Err("探测线程崩溃".to_string()))
            })
            .collect()
    });
    for (image, result) in images.iter().zip(results) {
        match result {
            Ok(()) => {}
            Err(err) if looks_like_network_error(&err) => offline += 1,
            Err(err) => broken.push(format!("{image}（{err}）")),
        }
    }

    if !broken.is_empty() {
        let shown = broken
            .iter()
            .take(5)
            .cloned()
            .collect::<Vec<_>>()
            .join("；");
        return vec![
            Finding::warn(
                CODE,
                "镜像在源上取不到",
                format!("{} 个：{shown}", broken.len()),
            )
            .non_blocking()
            .with_hint(
                "确认 tag 与镜像源前缀（*_REGISTRY / *_IMAGE_TAG）；`compose pull` 会失败在这里",
            ),
        ];
    }
    if offline == images.len() {
        return vec![
            Finding::warn(
                CODE,
                "镜像源不可达（离线？）",
                format!("{offline} 个镜像全部拿不到 manifest"),
            )
            .with_hint("离线站点用 `--offline` 跳过本项，免得每次体检都报"),
        ];
    }
    vec![Finding::ok(
        CODE,
        "镜像在源上都能取到",
        format!("{} 个", images.len()),
    )]
}

// ── 测试 ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::time::Duration;

    use super::*;
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
        let findings = domain_configured(&vars(&tree));
        assert_eq!(findings[0].status, Status::Fail, "{findings:#?}");
        assert!(findings[0].blocking);
    }

    #[test]
    fn accepts_real_domains() {
        let tree = Tree::new("domain-ok");
        tree.write("sys/merged_vars.yml", VARS);
        let findings = domain_configured(&vars(&tree));
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
        let findings = crate::run_with(&tree.stack(), &crate::Options { offline: true });
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
        let findings = crate::run_with(&tree.stack(), &crate::Options { offline: true });
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

        let findings = crate::run_with(&tree.stack(), &crate::Options { offline: true });
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

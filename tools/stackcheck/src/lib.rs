//! 栈级配置检查（`wist-stackcheck`，center-stack profile）。
//!
//! **只校验「栈自己生成的东西」**：渲染产物及其新鲜度、目录/挂载约定、密钥文件权限、
//! 站点证书与域名、现场态 `public_url`。组件配置键的语义（某个值是否合法、某个键属于哪个
//! 结构体）由**组件自己**负责 —— 那里有 `deny_unknown_fields` 与 `diagnose`。
//!
//! 为什么这样切分：本检查器与**栈**同版本发布（它随栈的约定一起变），所以不需要知道组件版本；
//! 组件则相反。
//!
//! 判据按 [`profile::Profile`] 参数化（gateway-stack 的 `StackProfile` 方案），换栈只换 profile，
//! 不要把路径常量散进检查逻辑。
//!
//! 输出对齐 `gops run diagnose` 的 Flow Result v1（`schema_version` + `checks[]`），
//! 便于聚合到同一次体检里。

use std::path::PathBuf;

pub mod checks;
pub mod profile;

/// 单条检查的结论等级。`Ord` 用于取「最差」（`Fail > Warn > Ok`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Ok,
    Warn,
    Fail,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Warn => "warn",
            Status::Fail => "fail",
        }
    }

    /// 进程退出码：0 = 全好，1 = 有 WARN，2 = 有 FAIL。
    pub fn exit_code(self) -> u8 {
        match self {
            Status::Ok => 0,
            Status::Warn => 1,
            Status::Fail => 2,
        }
    }
}

/// 一条检查结果。字段名与 Flow Result v1 的 `checks[]` 一致。
#[derive(Debug, Clone)]
pub struct Finding {
    pub code: String,
    pub status: Status,
    /// 它「修不好就别升级 / 别启动」吗？
    ///
    /// `Fail` 但**不阻断**的例子：网关客户端 CA（CA-G）缺失 —— 中心照常运行，只是新网关
    /// 注册时会失败；不能因此拦下一个升级。
    pub blocking: bool,
    pub title: String,
    pub detail: String,
    pub hint: String,
}

impl Finding {
    pub fn ok(
        code: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            status: Status::Ok,
            blocking: false,
            title: title.into(),
            detail: detail.into(),
            hint: String::new(),
        }
    }

    pub fn warn(
        code: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            status: Status::Warn,
            ..Self::ok(code, title, detail)
        }
    }

    pub fn fail(
        code: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            status: Status::Fail,
            blocking: true,
            ..Self::ok(code, title, detail)
        }
    }

    /// 标记「失败但不阻断升级/启动」（见 [`Finding::blocking`]）。
    pub fn non_blocking(mut self) -> Self {
        self.blocking = false;
        self
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = hint.into();
        self
    }
}

/// 被检查的栈根（应含 `sys/`、`configs/`、`identity/`、`artifacts/`、`.wist/`）。
#[derive(Debug, Clone)]
pub struct Stack {
    pub root: PathBuf,
}

impl Stack {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// 栈内相对路径的绝对化。**不做** `canonicalize` —— 被检查的目标可能还不存在，
    /// 而且宿主要求的是「配置里写的那个路径」，不是它解析后的真身。
    pub fn at(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }
}

/// 运行选项（由 CLI 传入）。
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// 跳过需要联网的检查（镜像可达）。离线站点应该打开。
    pub offline: bool,
}

/// 跑全部检查（默认选项）。顺序固定（输出可 diff、可回归）。
pub fn run(stack: &Stack) -> Vec<Finding> {
    run_with(stack, &Options::default())
}

pub fn run_with(stack: &Stack, options: &Options) -> Vec<Finding> {
    let profile = &profile::CENTER;
    let vars = checks::Vars::load(stack);

    let mut out = Vec::new();
    if let Some(err) = &vars.error {
        out.push(
            Finding::fail("config.vars", "读不到系统变量", err.clone())
                .with_hint("先跑一次 `gops sys localize`（生成 .env / sys/merged_vars.yml）再检查"),
        );
    }

    out.extend(checks::render_freshness(stack, profile));
    out.extend(checks::render_placeholders(stack, profile));
    out.extend(checks::domain_configured(&vars));
    out.extend(checks::secret_perms(stack, profile));
    out.extend(checks::private_key_mode(stack, profile));
    out.extend(checks::identity_files(stack, profile));
    out.extend(checks::tls_certificate(stack, &vars, profile));
    out.extend(checks::layout_mounts(stack, &vars, profile));
    out.extend(checks::public_url(stack, &vars, profile));
    out.extend(checks::database_initdb(stack, profile));
    out.extend(checks::ports_available(stack, &vars, profile));
    out.extend(checks::image_reachable(
        stack,
        &vars,
        profile,
        options.offline,
    ));
    out
}

/// 最差等级（没有检查项 = `Ok`）。
pub fn worst(findings: &[Finding]) -> Status {
    findings
        .iter()
        .map(|finding| finding.status)
        .max()
        .unwrap_or(Status::Ok)
}

/// 是否存在**阻断类**失败（`--gate` 的判据）。
pub fn has_blocking_failure(findings: &[Finding]) -> bool {
    findings
        .iter()
        .any(|finding| finding.status == Status::Fail && finding.blocking)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worst_of_nothing_is_ok() {
        assert_eq!(worst(&[]), Status::Ok);
        assert!(!has_blocking_failure(&[]));
    }

    #[test]
    fn blocking_flag_separates_gate_failures_from_soft_ones() {
        let soft = Finding::fail("identity.center_files", "t", "").non_blocking();
        let warn = Finding::warn("secret.file_mode", "t", "");
        assert!(!has_blocking_failure(&[soft.clone(), warn.clone()]));
        // 对体检（diagnose）而言它仍然是 FAIL：该修。
        assert_eq!(worst(&[soft, warn]), Status::Fail);

        let hard = Finding::fail("tls.san_covers_domain", "t", "");
        assert!(has_blocking_failure(&[hard]));
    }
}

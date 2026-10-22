//! 栈级配置检查（`wist-stackcheck`，center-stack profile）。
//!
//! 通用引擎（Flow Result / CLI / 渲染/密钥/挂载/端口/镜像判据）在
//! `wist-stackcheck-core`；本 crate 只提供：
//! - [`profile::CENTER`]：路径、变量、挂载对、身份文件；
//! - center 专属的 TLS 策略（固定叶证书 + 两个域名）；
//! - [`run_with`] 的判据编排。
//!
//! 输出对齐 `gops run diagnose` 的 Flow Result v1（`schema_version` + `checks[]`）。

pub mod checks;
pub mod profile;

pub use wist_stackcheck_core::{Finding, Options, Stack, Status};

/// 跑本栈的全部检查。顺序固定（输出可 diff、可回归）。
pub fn run_with(stack: &Stack, options: &Options) -> Vec<Finding> {
    let profile = &profile::CENTER;
    let vars = checks::Vars::load(stack);

    let mut out = Vec::new();
    if options.wants("config")
        && let Some(err) = &vars.error
    {
        out.push(
            Finding::fail("config.vars", "读不到系统变量", err.clone())
                .with_hint("先跑一次 `gops sys localize`（生成 .env / sys/merged_vars.yml）再检查"),
        );
    }

    if options.wants("render") {
        out.extend(checks::render_freshness(stack, profile));
        out.extend(checks::render_placeholders(stack, profile));
    }
    if options.wants("domain") {
        out.extend(checks::domain_configured(&vars, profile));
    }
    if options.wants("secret") {
        out.extend(checks::secret_perms(stack, profile));
        out.extend(checks::private_key_mode(stack, profile));
    }
    if options.wants("identity") {
        out.extend(checks::identity_files(stack, profile));
    }
    if options.wants("tls") {
        out.extend(checks::tls_certificate(stack, &vars, profile));
    }
    if options.wants("layout") {
        out.extend(checks::layout_mounts(stack, &vars, profile));
        out.extend(checks::public_url(stack, &vars, profile));
    }
    if options.wants("database") {
        out.extend(checks::database_initdb(stack, profile));
    }
    if options.wants("port") {
        out.extend(checks::ports_available(stack, &vars, profile));
    }
    if options.wants("image") {
        out.extend(checks::image_reachable(
            stack,
            &vars,
            profile,
            options.offline,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_prefix_runs_one_group() {
        let options = Options {
            offline: true,
            only: Some("render".to_string()),
        };
        assert!(options.wants("render"));
        assert!(!options.wants("tls"));
    }
}

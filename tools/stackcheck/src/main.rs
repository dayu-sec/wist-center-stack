//! `wist-stackcheck` CLI（center-stack profile）。
//!
//! 参数解析、JSON / 文本输出、结果文件、退出码都在 `wist-stackcheck-core::cli`；
//! 这里只提供本栈的 usage 与 `run_with`。

use std::process::ExitCode;

const USAGE: &str = "\
wist-stackcheck — 栈级配置检查（center-stack）

检查栈自己生成的东西：渲染新鲜度、占位值/域名、compose 挂载与落点、密钥权限、
站点证书 SAN、现场态 public_url、PG 建表脚本、宿主端口、镜像可达。
组件配置键的语义不在这里（由组件启动时的严格解析与 `diagnose` 负责）。

用法：
  wist-stackcheck [--root <栈根>] [--format text|json] [--result <文件>] [--only <前缀>]

选项：
  --root <dir>     栈根（含 sys/ configs/ identity/ artifacts/ .wist/），缺省 = 当前目录
  --format <fmt>   text（缺省，人读）| json（Flow Result v1）
  --result <file>  另写一份 JSON 结果；也认环境变量 GOPS_DIAGNOSE_RESULT
                   （**追加**到已有 `checks[]`：同一份体检里可以多个流程段各自报）
  --only <前缀>    只跑某一组（按 code 前缀过滤，如 `render` / `tls` / `layout`）
  --gate           闸门模式：只有**阻断类** FAIL 才非零退出（WARN / 非阻断 FAIL 都放行）。
                   给 `flow localize` 用 —— 渲染完就守门，别把坏配置带进 `up`。
  --offline        跳过需要联网的检查（镜像可达）—— 离线站点应该打开
  -V, --version    打印版本
  -h, --help       本帮助

退出码：
  --gate → 0（无阻断类 FAIL）/ 2（有）；**优先于**下面的结果文件规则；
  写了结果文件（diagnose 模式）→ 始终 0，结论看 checks[];
  否则 → 0 全好 / 1 有 WARN / 2 有 FAIL。
";

fn main() -> ExitCode {
    wist_stackcheck_core::cli::run(
        USAGE,
        format!(
            "wist-stackcheck {} (center-stack)",
            env!("CARGO_PKG_VERSION")
        ),
        wist_center_stackcheck::run_with,
    )
}

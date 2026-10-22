//! `wist-stackcheck` CLI（center-stack profile）。
//!
//! 两种消费方式：
//! - **`gops run diagnose`**：由 `GOPS_DIAGNOSE_RESULT`（或 `--result`）指定结果文件，
//!   写 Flow Result v1 后**始终退出 0**——判定结论在 `checks[]` 里，不该让流程中断；
//! - **CI / 手工 / localize 闸门**：不写结果文件时，退出码就是判定（0 ok / 1 warn / 2 fail）。

use std::path::PathBuf;
use std::process::ExitCode;

use wist_center_stackcheck::{
    Finding, Options, Stack, Status, has_blocking_failure, run_with, worst,
};

const USAGE: &str = "\
wist-stackcheck — 栈级配置检查（center-stack）

检查栈自己生成的东西：渲染新鲜度、占位值/域名、compose 挂载与落点、密钥权限、
站点证书 SAN、现场态 public_url、PG 建表脚本、宿主端口、镜像可达。
组件配置键的语义不在这里（由组件启动时的严格解析与 `diagnose` 负责）。

用法：
  wist-stackcheck [--root <栈根>] [--format text|json] [--result <文件>]

选项：
  --root <dir>     栈根（含 sys/ configs/ identity/ artifacts/ .wist/），缺省 = 当前目录
  --format <fmt>   text（缺省，人读）| json（Flow Result v1）
  --result <file>  另写一份 JSON 结果；也认环境变量 GOPS_DIAGNOSE_RESULT
                   （**追加**到已有 `checks[]`：同一份体检里可以多个流程段各自报）
  --gate           闸门模式：只有**阻断类** FAIL 才非零退出（WARN / 非阻断 FAIL 都放行）。
                   给 `flow localize` 用 —— 渲染完就守门，别把坏配置带进 `up`。
  --offline        跳过需要联网的检查（镜像可达）—— 离线站点应该打开
  -V, --version    打印版本
  -h, --help       本帮助

退出码：
  --gate → 0（无阻断类 FAIL）/ 2（有）；**优先于**下面的结果文件规则；
  写了结果文件（diagnose 模式）→ 始终 0，结论看 checks[]；
  否则 → 0 全好 / 1 有 WARN / 2 有 FAIL。
";

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    // `--version` 不走完整解析：排障时运维只想拿一行版本号。
    if argv.iter().any(|arg| arg == "--version" || arg == "-V") {
        println!("{}", version_line());
        return ExitCode::SUCCESS;
    }
    let args = match Args::parse(argv.into_iter()) {
        Ok(Some(args)) => args,
        Ok(None) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(message) => {
            eprintln!("{message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };

    let findings = run_with(
        &Stack::new(&args.root),
        &Options {
            offline: args.offline,
        },
    );
    let verdict = worst(&findings);

    if args.json {
        println!("{}", to_json(&findings));
    } else {
        print_text(&findings, verdict);
    }

    // 闸门模式（`flow localize`）：只拦「阻断类」失败 —— WARN 与「失败但不阻断」
    // 都不应该让一次升级/部署停下来。
    let Some(path) = &args.result else {
        return ExitCode::from(exit_code_for(args.gate, false, &findings));
    };
    if let Err(err) = write_result(path, &to_json(&findings)) {
        eprintln!("写结果文件失败 {}：{err}", path.display());
        return ExitCode::from(2);
    }
    ExitCode::from(exit_code_for(args.gate, true, &findings))
}

/// 退出码优先级：**闸门 > 结果文件 > 严重度**。
///
/// 闸门放第一位是必须的：如果环境里恰好有 `GOPS_DIAGNOSE_RESULT`（或调用方同时传了
/// `--result`），「结果模式始终退 0」会把守门彻底绕过——那时 localize 永远是绿的。
fn exit_code_for(gate: bool, has_result: bool, findings: &[Finding]) -> u8 {
    if gate {
        return if has_blocking_failure(findings) { 2 } else { 0 };
    }
    if has_result {
        return 0;
    }
    worst(findings).exit_code()
}

/// 写 Flow Result v1；文件已存在时**追加** `checks[]`。
///
/// `gops run diagnose` 只读**一个**结果文件，而一个 flow 里可以有多个诊断动作。
/// 谁都不该默默覆盖前面那份，所以这里做追加：先读旧 `checks`，再接上自己的。
/// 旧文件不是合法 JSON 时告警后重写（不静默丢数据）。
fn write_result(path: &std::path::Path, mine: &serde_json::Value) -> std::io::Result<()> {
    // 保留旧文件里的**其他顶层字段**（schema_version / source / 以后新增的），只换 `checks`。
    let mut doc = serde_json::Map::new();
    let mut checks: Vec<serde_json::Value> = Vec::new();

    if let Ok(text) = std::fs::read_to_string(path)
        && !text.trim().is_empty()
    {
        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(existing) => {
                if let Some(object) = existing.as_object() {
                    if let Some(items) = object.get("checks").and_then(|value| value.as_array()) {
                        checks.extend(items.iter().cloned());
                    }
                    doc = object.clone();
                    doc.remove("checks");
                }
            }
            Err(err) => eprintln!(
                "提示：{} 不是合法的 Flow Result（{err}），将覆盖",
                path.display()
            ),
        }
    }

    if let Some(items) = mine.get("checks").and_then(|value| value.as_array()) {
        // gops 对**同一次运行内重复的 code** 直接拒收整份结果文件，所以这里去重：
        // 已经报过的 code 不再追加（同一份体检里重复报也无信息量）。
        let mut seen: std::collections::HashSet<String> = checks
            .iter()
            .filter_map(|check| check.get("code").and_then(|value| value.as_str()))
            .map(str::to_string)
            .collect();
        for item in items {
            let code = item.get("code").and_then(|value| value.as_str());
            match code {
                Some(code) if !seen.insert(code.to_string()) => {
                    eprintln!("提示：code={code} 已存在，跳过一条重复结果");
                }
                _ => checks.push(item.clone()),
            }
        }
    }

    doc.entry("schema_version".to_string())
        .or_insert_with(|| serde_json::json!("1"));
    doc.entry("source".to_string())
        .or_insert_with(|| serde_json::json!("diagnose"));
    doc.insert("checks".to_string(), serde_json::Value::Array(checks));

    let merged = serde_json::Value::Object(doc);
    std::fs::write(path, format!("{merged}\n"))
}

struct Args {
    root: PathBuf,
    json: bool,
    gate: bool,
    offline: bool,
    result: Option<PathBuf>,
}

fn version_line() -> String {
    format!(
        "wist-stackcheck {} (center-stack)",
        env!("CARGO_PKG_VERSION")
    )
}

impl Args {
    fn parse(mut args: impl Iterator<Item = String>) -> Result<Option<Self>, String> {
        let mut root: Option<PathBuf> = None;
        let mut format = String::from("text");
        let mut gate = false;
        let mut offline = false;
        let mut result: Option<PathBuf> = None;

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "-h" | "--help" => return Ok(None),
                "--gate" => gate = true,
                "--offline" => offline = true,
                "--root" => {
                    let value = args.next().ok_or("--root 需要一个路径")?;
                    root = Some(PathBuf::from(value));
                }
                "--format" => {
                    format = args.next().ok_or("--format 需要 text 或 json")?;
                }
                "--result" => {
                    let value = args.next().ok_or("--result 需要一个路径")?;
                    result = Some(PathBuf::from(value));
                }
                other => return Err(format!("未知参数：{other}")),
            }
        }

        let json = match format.as_str() {
            "text" => false,
            "json" => true,
            other => return Err(format!("--format 只支持 text / json，收到 {other}")),
        };

        // gops 的体检契约：结果写进这个文件，流程本身不该失败。
        if result.is_none()
            && let Ok(path) = std::env::var("GOPS_DIAGNOSE_RESULT")
            && !path.trim().is_empty()
        {
            result = Some(PathBuf::from(path));
        }

        Ok(Some(Self {
            root: root.unwrap_or_else(|| PathBuf::from(".")),
            json,
            gate,
            offline,
            result,
        }))
    }
}

fn to_json(findings: &[Finding]) -> serde_json::Value {
    let checks: Vec<serde_json::Value> = findings
        .iter()
        .map(|finding| {
            serde_json::json!({
                "code": finding.code,
                "status": finding.status.as_str(),
                // `blocking=false`：该修，但不该拦住升级/启动。
                // gops 按 key 读、不认识就忽略，所以加字段是安全的。
                "blocking": finding.blocking,
                "title": finding.title,
                "detail": finding.detail,
                "hint": finding.hint,
            })
        })
        .collect();
    serde_json::json!({
        "schema_version": "1",
        "source": "diagnose",
        "checks": checks,
    })
}

fn print_text(findings: &[Finding], verdict: Status) {
    for finding in findings {
        println!(
            "[{:<4}] {} — {}",
            finding.status.as_str().to_uppercase(),
            finding.code,
            finding.title
        );
        if !finding.detail.trim().is_empty() {
            println!("       {}", finding.detail);
        }
        if !finding.hint.trim().is_empty() {
            println!("       → {}", finding.hint);
        }
        if finding.status == Status::Fail && !finding.blocking {
            println!("       （不阻断升级/启动）");
        }
    }

    let total = findings.len();
    let fails = findings.iter().filter(|f| f.status == Status::Fail).count();
    let warns = findings.iter().filter(|f| f.status == Status::Warn).count();
    let oks = total - fails - warns;
    println!();
    println!(
        "{total} 项检查：{oks} ok / {warns} warn / {fails} fail（结论：{}）",
        verdict.as_str()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Option<Args>, String> {
        Args::parse(args.iter().map(|value| value.to_string()))
    }

    #[test]
    fn defaults_to_text_and_current_directory() {
        let args = parse(&[]).unwrap().unwrap();
        assert!(!args.json);
        assert_eq!(args.root, PathBuf::from("."));
    }

    #[test]
    fn accepts_root_and_json() {
        let args = parse(&["--root", "/tmp/stack", "--format", "json"])
            .unwrap()
            .unwrap();
        assert!(args.json);
        assert_eq!(args.root, PathBuf::from("/tmp/stack"));
    }

    #[test]
    fn rejects_unknown_format() {
        assert!(parse(&["--format", "yaml"]).is_err());
    }

    #[test]
    fn rejects_unknown_flag() {
        assert!(parse(&["--nope"]).is_err());
    }

    #[test]
    fn gate_takes_precedence_over_result_mode() {
        let hard = vec![Finding::fail("tls.san_covers_domain", "t", "")];
        let soft = vec![
            Finding::fail("identity.center_files", "t", "").non_blocking(),
            Finding::warn("secret.file_mode", "t", ""),
        ];

        // 同时有结果文件时，闸门不能被「结果模式退 0」绕过。
        assert_eq!(exit_code_for(true, true, &hard), 2);
        assert_eq!(exit_code_for(true, true, &soft), 0);
        // 结果模式（diagnose）：总是 0，结论在 checks[]。
        assert_eq!(exit_code_for(false, true, &hard), 0);
        // 普通模式：严重度即退出码。
        assert_eq!(exit_code_for(false, false, &hard), Status::Fail.exit_code());
    }

    #[test]
    fn to_json_carries_blocking_and_hint() {
        let findings = vec![
            Finding::fail("tls.san_covers_domain", "t", "d").with_hint("h"),
            Finding::fail("identity.center_files", "t", "d").non_blocking(),
        ];
        let doc = to_json(&findings);
        assert_eq!(doc["schema_version"], "1");
        assert_eq!(doc["source"], "diagnose");
        let checks = doc["checks"].as_array().unwrap();
        assert_eq!(checks.len(), 2);
        assert_eq!(checks[0]["blocking"], true);
        assert_eq!(checks[0]["hint"], "h");
        assert_eq!(checks[1]["blocking"], false);
    }

    #[test]
    fn write_result_preserves_other_top_level_fields() {
        let dir = std::env::temp_dir().join(format!(
            "wist-center-stackcheck-preserve-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("result.json");
        std::fs::write(
            &path,
            r#"{"schema_version":"1","source":"diagnose","extra":{"a":1},"checks":[]}"#,
        )
        .unwrap();

        let mine = serde_json::json!({
            "checks": [{"code": "layout.mounts", "status": "ok", "title": "t"}]
        });
        write_result(&path, &mine).unwrap();

        let merged: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(merged["extra"]["a"], 1);
        assert_eq!(merged["source"], "diagnose");
        assert_eq!(merged["checks"].as_array().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_result_drops_duplicate_codes() {
        let dir = std::env::temp_dir().join(format!(
            "wist-center-stackcheck-dedup-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("result.json");
        std::fs::write(
            &path,
            r#"{"schema_version":"1","source":"diagnose","checks":[{"code":"a","status":"ok","title":"t"}]}"#,
        )
        .unwrap();

        let mine = serde_json::json!({
            "checks": [
                {"code": "a", "status": "fail", "title": "dup"},
                {"code": "b", "status": "ok", "title": "new"}
            ]
        });
        write_result(&path, &mine).unwrap();

        let merged: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let codes: Vec<&str> = merged["checks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|check| check["code"].as_str().unwrap())
            .collect();
        // gops 对重复 code 会**整份拒收**，所以重复的必须去掉。
        assert_eq!(codes, vec!["a", "b"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn appends_findings_to_an_existing_result_file() {
        let dir = std::env::temp_dir().join(format!(
            "wist-center-stackcheck-merge-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("result.json");
        std::fs::write(
            &path,
            r#"{"schema_version":"1","source":"diagnose","checks":[{"code":"other.check","status":"ok","title":"t","detail":"","hint":""}]}"#,
        )
        .unwrap();

        let mine = serde_json::json!({
            "checks": [{"code": "layout.mounts", "status": "fail", "title": "t", "detail": "", "hint": ""}]
        });
        write_result(&path, &mine).unwrap();

        let merged: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let codes: Vec<&str> = merged["checks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|check| check["code"].as_str().unwrap())
            .collect();
        assert_eq!(codes, vec!["other.check", "layout.mounts"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_result_overwrites_an_unparseable_file() {
        let dir = std::env::temp_dir().join(format!(
            "wist-center-stackcheck-badjson-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("result.json");
        std::fs::write(&path, "这不是 JSON").unwrap();

        let mine = serde_json::json!({
            "checks": [{"code": "tls.san_covers_domain", "status": "ok", "title": "t"}]
        });
        write_result(&path, &mine).unwrap();

        let merged: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(merged["schema_version"], "1");
        assert_eq!(merged["checks"].as_array().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn version_line_is_stable() {
        let line = version_line();
        assert!(line.starts_with("wist-stackcheck "), "{line}");
        assert!(!line.trim().ends_with(' '), "{line}");
    }
}

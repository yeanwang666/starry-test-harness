use std::{
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
    process::Command,
    time::Instant,
};

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Local};
use clap::{Parser, ValueEnum};
use serde::{Deserialize, Serialize};

fn main() -> Result<()> {
    let cli = Cli::parse();
    let workspace = fs::canonicalize(&cli.workspace)
        .with_context(|| format!("failed to resolve workspace {}", cli.workspace.display()))?;

    match cli.action {
        Action::Run => run_suite(cli.suite, &workspace),
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "starry-test-harness",
    version,
    about = "Rust harness for Starry OS test suites"
)]
struct Cli {
    #[arg(value_enum)]
    suite: Suite,
    #[arg(value_enum, default_value = "run")]
    action: Action,
    #[arg(long, default_value = ".")]
    workspace: PathBuf,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Suite {
    #[value(name = "ci-test")]
    CiTest,
    #[value(name = "stress-test")]
    StressTest,
    #[value(name = "daily-test")]
    DailyTest,
}

impl Suite {
    fn dir_name(&self) -> &'static str {
        match self {
            Suite::CiTest => "ci",
            Suite::StressTest => "stress",
            Suite::DailyTest => "daily",
        }
    }

    fn display_name(&self) -> &'static str {
        match self {
            Suite::CiTest => "CI Test",
            Suite::StressTest => "Stress Test",
            Suite::DailyTest => "Daily Test",
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Action {
    Run,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    name: Option<String>,
    description: Option<String>,
    build_script: Option<String>,
    arch: Option<String>,
    #[serde(default = "default_timeout")]
    default_timeout_secs: u64,
    #[serde(default)]
    cases: Vec<TestCase>,
}

#[derive(Debug, Deserialize, Clone)]
struct TestCase {
    name: String,
    description: Option<String>,
    path: String,
    #[serde(default)]
    args: Vec<String>,
    timeout_secs: Option<u64>,
    #[serde(default)]
    allow_failure: bool,
}

#[derive(Debug, Serialize)]
struct CaseDetail {
    name: String,
    status: String,
    duration_ms: u128,
    exit_code: Option<i32>,
    allow_failure: bool,
    log_path: PathBuf,
}

#[derive(Debug, Serialize)]
struct RunSummary {
    suite: String,
    action: String,
    description: Option<String>,
    arch: Option<String>,
    started_at: DateTime<Local>,
    finished_at: DateTime<Local>,
    total: usize,
    passed: usize,
    failed: usize,
    soft_failed: usize,
    log_file: PathBuf,
    error_log: Option<PathBuf>,
    case_logs_root: PathBuf,
    artifacts_root: PathBuf,
    cases: Vec<CaseDetail>,
}

#[derive(Debug)]
struct CaseOutcome {
    status: CaseStatus,
    duration_ms: u128,
    exit_code: Option<i32>,
    log_path: PathBuf,
}

#[derive(Debug)]
enum CaseStatus {
    Passed,
    Failed,
    SoftFailed,
}

impl CaseStatus {
    fn as_str(&self) -> &'static str {
        match self {
            CaseStatus::Passed => "passed",
            CaseStatus::Failed => "failed",
            CaseStatus::SoftFailed => "soft_failed",
        }
    }
}

fn default_timeout() -> u64 {
    600
}

fn run_suite(suite: Suite, workspace: &Path) -> Result<()> {
    let manifest = load_manifest(workspace, suite)?;
    if manifest.cases.is_empty() {
        bail!(
            "suite {} has no cases defined - add entries to {}",
            suite.display_name(),
            manifest_path(workspace, suite).display()
        );
    }

    let logs_root = workspace.join("logs").join(suite.dir_name());
    fs::create_dir_all(&logs_root)?;
    let timestamp = Local::now().format("%Y%m%d-%H%M%S").to_string();
    let run_dir = logs_root.join(&timestamp);
    fs::create_dir_all(&run_dir)?;
    let run_log_path = run_dir.join("suite.log");
    let case_logs_root = run_dir.join("cases");
    fs::create_dir_all(&case_logs_root)?;
    let artifacts_root = run_dir.join("artifacts");
    fs::create_dir_all(&artifacts_root)?;
    let mut run_log = File::create(&run_log_path)?;
    let start = Local::now();
    let suite_label = manifest
        .name
        .clone()
        .unwrap_or_else(|| suite.display_name().to_string());

    writeln!(
        run_log,
        "[suite] {} ({}) - {}",
        suite_label,
        manifest.arch.as_deref().unwrap_or("unknown arch"),
        manifest
            .description
            .as_deref()
            .unwrap_or("no description provided")
    )?;

    maybe_run_build(&manifest, suite, workspace, &mut run_log)?;

    let mut case_details = Vec::new();
    let mut passed = 0usize;
    let mut failed = 0usize;
    let mut soft_failed = 0usize;

    for case in &manifest.cases {
        let case_slug = sanitize_case_name(&case.name);
        let case_log_path = case_logs_root.join(format!("{case_slug}.log"));
        let case_artifact_dir = artifacts_root.join(&case_slug);
        fs::create_dir_all(&case_artifact_dir)?;
        writeln!(
            run_log,
            "[case] starting {} -> {}",
            case.name,
            rel_path(&case_log_path, workspace).display()
        )?;
        if let Some(desc) = &case.description {
            writeln!(run_log, "        {}", desc)?;
        }
        let outcome = run_case(
            case,
            workspace,
            &case_log_path,
            manifest.default_timeout_secs,
            &run_dir,
            &case_artifact_dir,
            &timestamp,
            &case_slug,
        )?;

        let status_str = outcome.status.as_str();
        writeln!(
            run_log,
            "[case] {} finished in {} ms (exit {:?})",
            case.name, outcome.duration_ms, outcome.exit_code
        )?;

        match outcome.status {
            CaseStatus::Passed => passed += 1,
            CaseStatus::Failed => failed += 1,
            CaseStatus::SoftFailed => soft_failed += 1,
        }

        case_details.push(CaseDetail {
            name: case.name.clone(),
            status: status_str.to_string(),
            duration_ms: outcome.duration_ms,
            exit_code: outcome.exit_code,
            allow_failure: case.allow_failure,
            log_path: rel_path(&outcome.log_path, workspace),
        });
    }

    let end = Local::now();
    let error_log_path = run_dir.join("error.log");
    let mut error_log = None;
    if failed > 0 {
        let message = format!(
            "{} cases failed. See {} for details.",
            failed,
            rel_path(&run_log_path, workspace).display()
        );
        fs::write(&error_log_path, message)?;
        error_log = Some(rel_path(&error_log_path, workspace));
    } else if error_log_path.exists() {
        let _ = fs::remove_file(&error_log_path);
    }

    let summary = RunSummary {
        suite: suite_label,
        action: "run".into(),
        description: manifest.description.clone(),
        arch: manifest.arch.clone(),
        started_at: start,
        finished_at: end,
        total: manifest.cases.len(),
        passed,
        failed,
        soft_failed,
        log_file: rel_path(&run_log_path, workspace),
        error_log,
        case_logs_root: rel_path(&case_logs_root, workspace),
        artifacts_root: rel_path(&artifacts_root, workspace),
        cases: case_details,
    };

    let summary_path = logs_root.join("last_run.json");
    fs::write(&summary_path, serde_json::to_string_pretty(&summary)?)?;

    println!(
        "{} completed: {}/{} passed ({} soft failures). Log: {}",
        suite.display_name(),
        passed,
        summary.total,
        soft_failed,
        summary.log_file.display()
    );

    if failed > 0 {
        bail!(
            "{} failed. Consult {}",
            suite.display_name(),
            summary.log_file.display()
        );
    }

    Ok(())
}

fn run_case(
    case: &TestCase,
    workspace: &Path,
    log_path: &Path,
    default_timeout: u64,
    run_dir: &Path,
    case_artifact_dir: &Path,
    run_id: &str,
    case_slug: &str,
) -> Result<CaseOutcome> {
    let script_path = workspace.join(&case.path);
    if !script_path.exists() {
        bail!(
            "test case {} missing script {}",
            case.name,
            script_path.display()
        );
    }

    let mut log_file = File::create(log_path)?;
    writeln!(log_file, "[case] {}", case.name)?;
    writeln!(
        log_file,
        "[case] command: {} {}",
        script_path.display(),
        case.args.join(" ")
    )?;
    let timeout_secs = case.timeout_secs.unwrap_or(default_timeout);
    writeln!(log_file, "[case] timeout budget: {}s", timeout_secs)?;

    let mut command = Command::new(&script_path);
    command.current_dir(workspace);
    if !case.args.is_empty() {
        command.args(&case.args);
    }
    fs::create_dir_all(case_artifact_dir)?;
    let case_log_dir = log_path.parent().unwrap_or_else(|| Path::new("."));
    command.env("STARRY_WORKSPACE_ROOT", workspace);
    command.env("STARRY_RUN_ID", run_id);
    command.env("STARRY_RUN_DIR", run_dir);
    command.env("STARRY_CASE_NAME", &case.name);
    command.env("STARRY_CASE_SLUG", case_slug);
    command.env("STARRY_CASE_LOG_PATH", log_path);
    command.env("STARRY_CASE_LOG_DIR", case_log_dir);
    command.env("STARRY_CASE_ARTIFACT_DIR", case_artifact_dir);
    command.env("STARRY_CASE_TIMEOUT_SECS", timeout_secs.to_string());

    let start = Instant::now();
    let output = command
        .output()
        .with_context(|| format!("failed to run {}", case.name))?;
    let duration = start.elapsed().as_millis();

    log_file.write_all(&output.stdout)?;
    log_file.write_all(&output.stderr)?;

    let status = if output.status.success() {
        CaseStatus::Passed
    } else if case.allow_failure {
        CaseStatus::SoftFailed
    } else {
        CaseStatus::Failed
    };

    Ok(CaseOutcome {
        status,
        duration_ms: duration,
        exit_code: output.status.code(),
        log_path: log_path.to_path_buf(),
    })
}

fn load_manifest(workspace: &Path, suite: Suite) -> Result<Manifest> {
    let path = manifest_path(workspace, suite);
    let content = fs::read_to_string(&path)
        .with_context(|| format!("failed to read manifest {}", path.display()))?;
    toml::from_str(&content).with_context(|| format!("failed to parse manifest {}", path.display()))
}

fn manifest_path(workspace: &Path, suite: Suite) -> PathBuf {
    workspace
        .join("tests")
        .join(suite.dir_name())
        .join("suite.toml")
}

fn maybe_run_build(
    manifest: &Manifest,
    suite: Suite,
    workspace: &Path,
    log: &mut File,
) -> Result<()> {
    let script = manifest
        .build_script
        .as_deref()
        .unwrap_or("scripts/build_stub.sh");
    let script_path = workspace.join(script);
    if !script_path.exists() {
        writeln!(
            log,
            "[build] skipped build step because {} does not exist",
            script_path.display()
        )?;
        return Ok(());
    }

    writeln!(
        log,
        "[build] executing {} for {}",
        script_path.display(),
        suite.display_name()
    )?;
    let output = Command::new(&script_path)
        .arg(suite.dir_name())
        .current_dir(workspace)
        .output()
        .with_context(|| format!("failed to run build script {}", script_path.display()))?;
    log.write_all(&output.stdout)?;
    log.write_all(&output.stderr)?;
    Ok(())
}

fn rel_path(path: &Path, workspace: &Path) -> PathBuf {
    path.strip_prefix(workspace).unwrap_or(path).to_path_buf()
}

fn sanitize_case_name(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

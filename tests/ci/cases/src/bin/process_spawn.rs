use std::process::Command;
use test_utils::{ensure_success, run_command};

fn main() {
    if let Err(err) = run() {
        eprintln!("FAIL: process-spawn -> {err}");
        std::process::exit(1);
    }
    println!("PASS: process-spawn");
}

fn run() -> Result<(), String> {

    let expected = "starry-ci-process";
    let mut command = Command::new("sh");
    command.arg("-c").arg("echo starry-ci-process");

    let output = run_command(command)
    .map_err(|e| e.to_string())?;

    ensure_success(&output, "echo starry-ci-process")
        .map_err(|e| e.to_string())?;

    let stdout = output.trimmed_stdout();

    if stdout != expected {
        return Err(format!(
            "输出不匹配: expected `{expected}`, got `{stdout}`"
        ));
    }

    Ok(())
}


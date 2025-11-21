pub mod macros;

use anyhow::{anyhow, Context, Result};
use rand::{distributions::Alphanumeric, Rng};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, ExitStatus, Stdio},
};

/// 生成一个位于系统临时目录下的唯一文件路径。
/// 如果 `create` 为 true，则会立即创建空文件。
pub fn temp_file(prefix: &str, create: bool) -> Result<PathBuf> {
    let mut path = std::env::temp_dir();
    let suffix: String = rand::thread_rng()
        .sample_iter(Alphanumeric)
        .take(8)
        .map(char::from)
        .collect();
    let filename = format!("{}-{}", prefix, suffix);
    path.push(filename);
    if create {
        File::create(&path).with_context(|| format!("无法创建临时文件 {}", path.display()))?;
    }
    Ok(path)
}

/// 将字节写入文件，覆盖之前的内容。
pub fn write_bytes<P: AsRef<Path>>(path: P, data: &[u8]) -> Result<()> {
    fs::write(&path, data).with_context(|| format!("写入文件失败: {}", path.as_ref().display()))
}

/// 以追加方式向文件写入字节。
pub fn append_bytes<P: AsRef<Path>>(path: P, data: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)
        .with_context(|| format!("以追加方式打开文件失败: {}", path.as_ref().display()))?;
    file.write_all(data)
        .with_context(|| format!("追加写入失败: {}", path.as_ref().display()))?;
    file.flush()
        .with_context(|| format!("刷新写入失败: {}", path.as_ref().display()))
}

/// 读取文件全部内容。
pub fn read_bytes<P: AsRef<Path>>(path: P) -> Result<Vec<u8>> {
    let mut buffer = Vec::new();
    let mut file = OpenOptions::new()
        .read(true)
        .open(&path)
        .with_context(|| format!("打开文件失败: {}", path.as_ref().display()))?;
    file.read_to_end(&mut buffer)
        .with_context(|| format!("读取文件失败: {}", path.as_ref().display()))?;
    Ok(buffer)
}

/// 删除文件，忽略不存在的情况。
pub fn cleanup_file<P: AsRef<Path>>(path: P) -> Result<()> {
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(anyhow!(
            "删除文件失败: {} -> {err}",
            path.as_ref().display()
        )),
    }
}

/// 生成指定长度的随机字节数组，可用于临时数据。
pub fn random_bytes(len: usize) -> Vec<u8> {
    rand::thread_rng()
        .sample_iter(rand::distributions::Standard)
        .take(len)
        .collect()
}

/// 检查系统调用返回值是否成功 (>= 0)，失败时返回错误。
pub fn ensure_syscall_success(ret: i64, context: &str) -> Result<i64> {
    if ret < 0 {
        Err(anyhow!("{context} -> syscall 返回 {ret}"))
    } else {
        Ok(ret)
    }
}

/// 子进程执行结果，包含退出状态以及标准输出/错误（UTF-8）。
#[derive(Debug)]
pub struct CommandOutput {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
}

impl CommandOutput {
    /// 返回去除首尾空白后的标准输出。
    pub fn trimmed_stdout(&self) -> &str {
        self.stdout.trim()
    }
}

/// 运行命令并捕获标准输出/错误，默认使用管道。
pub fn run_command(mut command: Command) -> Result<CommandOutput> {
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let output = command
        .output()
        .with_context(|| "执行子进程失败".to_string())?;

    let stdout = String::from_utf8(output.stdout)
        .with_context(|| "子进程 stdout 不是有效的 UTF-8".to_string())?;
    let stderr = String::from_utf8(output.stderr)
        .with_context(|| "子进程 stderr 不是有效的 UTF-8".to_string())?;

    Ok(CommandOutput {
        status: output.status,
        stdout,
        stderr,
    })
}

/// 确保子进程成功退出，否则返回错误并携带 stderr。
pub fn ensure_success(output: &CommandOutput, context: &str) -> Result<()> {
    if output.status.success() {
        Ok(())
    } else {
        Err(anyhow!(
            "{context} -> exit={:?}, stderr={}",
            output.status,
            output.stderr.trim()
        ))
    }
}

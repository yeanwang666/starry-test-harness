//! POSIX `waitpid` 状态宏的 Rust 实现
//!
//! 这些宏用于解析 `waitpid` 返回的状态码，判断子进程的退出、信号、停止等状态。
//! 实现基于常见的 POSIX `sys/wait.h` 定义。

/// 检查子进程是否正常退出 (WIFEXITED)
#[macro_export]
macro_rules! wifexited {
    ($status:expr) => {
        ($status & 0x7f) == 0
    };
}

/// 获取子进程的退出码 (WEXITSTATUS)
#[macro_export]
macro_rules! wexitstatus {
    ($status:expr) => {
        ($status >> 8) & 0xff
    };
}

/// 检查子进程是否被信号终止 (WIFSIGNALED)
#[macro_export]
macro_rules! wifsignaled {
    ($status:expr) => {
        ((($status & 0x7f) + 1) as i8 >> 1) > 0
    };
}

/// 获取终止子进程的信号 (WTERMSIG)
#[macro_export]
macro_rules! wtermsig {
    ($status:expr) => {
        $status & 0x7f
    };
}

/// 检查子进程是否被信号停止 (WIFSTOPPED)
#[macro_export]
macro_rules! wifstopped {
    ($status:expr) => {
        ($status & 0xff) == 0x7f
    };
}

/// 获取停止子进程的信号 (WSTOPSIG)
#[macro_export]
macro_rules! wstopsig {
    ($status:expr) => {
        ($status >> 8) & 0xff
    };
}

/// 检查子进程是否从停止状态恢复 (WIFCONTINUED)
#[macro_export]
macro_rules! wifcontinued {
    ($status:expr) => {
        $status == 0xffff
    };
}

/// 检查子进程终止时是否生成了核心转储 (WCOREDUMP)
#[macro_export]
macro_rules! wcoredump {
    ($status:expr) => {
        ($status & 0x80) != 0
    };
}

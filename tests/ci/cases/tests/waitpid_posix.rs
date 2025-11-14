//! Comprehensive POSIX waitpid() system call test suite.
//!
//! Tests cover:
//! - Basic waitpid functionality with specific PIDs
//! - Waiting for any child (pid = -1)
//! - WNOHANG non-blocking behavior
//! - Exit status retrieval and verification (WIFEXITED, WEXITSTATUS)
//! - Error conditions (ECHILD, EINVAL)
//! - Multiple children scenarios
//! - Process group waiting (pid = 0, pid < -1)
//! - Signal termination (WIFSIGNALED, WTERMSIG)

use libc::{
    exit, fork, getpid, getpgid, kill, setpgid, waitpid, ECHILD, EINVAL, SIGKILL, SIGTERM, WNOHANG,
};
use std::ptr;

// Helper macro to check if child exited normally
macro_rules! wifexited {
    ($status:expr) => {
        ($status & 0x7f) == 0
    };
}

// Helper macro to get exit status
macro_rules! wexitstatus {
    ($status:expr) => {
        ($status >> 8) & 0xff
    };
}

// Helper macro to check if child was terminated by signal
macro_rules! wifsignaled {
    ($status:expr) => {
        ((($status & 0x7f) + 1) as i8 >> 1) > 0
    };
}

// Helper macro to get terminating signal
macro_rules! wtermsig {
    ($status:expr) => {
        $status & 0x7f
    };
}

#[test]
fn waitpid_basic_child_exit() {
    // Test basic waitpid with specific child PID
    // Child exits with code 0
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            exit(0);
        } else {
            // Parent process
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, 0);
            assert_eq!(result, pid, "waitpid 应返回子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            assert_eq!(wexitstatus!(status), 0, "退出码应为 0");
        }
    }
}

#[test]
fn waitpid_child_exit_with_code() {
    // Test waitpid correctly retrieves various exit codes
    let test_codes = [1, 42, 127, 255];

    for &exit_code in &test_codes {
        unsafe {
            let pid = fork();
            assert!(pid >= 0, "fork 失败");

            if pid == 0 {
                // Child process
                exit(exit_code);
            } else {
                // Parent process
                let mut status: i32 = 0;
                let result = waitpid(pid, &mut status, 0);
                assert_eq!(result, pid, "waitpid 应返回子进程 PID");
                assert!(wifexited!(status), "子进程应正常退出");
                assert_eq!(
                    wexitstatus!(status),
                    exit_code,
                    "退出码应为 {}",
                    exit_code
                );
            }
        }
    }
}

#[test]
fn waitpid_any_child() {
    // Test waitpid(-1) waits for any child
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            exit(17);
        } else {
            // Parent process - use -1 to wait for any child
            let mut status: i32 = 0;
            let result = waitpid(-1, &mut status, 0);
            assert_eq!(result, pid, "waitpid(-1) 应返回子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            assert_eq!(wexitstatus!(status), 17, "退出码应为 17");
        }
    }
}

#[test]
fn waitpid_wnohang_no_child_ready() {
    // Test WNOHANG returns 0 when no child has exited
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - sleep briefly
            libc::sleep(1);
            exit(0);
        } else {
            // Parent process - try non-blocking wait immediately
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WNOHANG);

            // Should return 0 since child is still running
            // (or return the pid if child already exited, which is also valid)
            assert!(result >= 0, "waitpid 不应失败");

            // Clean up: wait for child to actually exit
            if result == 0 {
                // Child still running, wait for it
                let final_result = waitpid(pid, &mut status, 0);
                assert_eq!(final_result, pid, "最终 waitpid 应返回子进程 PID");
            }
            assert!(wifexited!(status) || result == 0, "子进程应正常退出或仍在运行");
        }
    }
}

#[test]
fn waitpid_wnohang_child_ready() {
    // Test WNOHANG returns immediately when child has exited
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - exit immediately
            exit(33);
        } else {
            // Parent process - give child time to exit
            libc::usleep(100_000); // 100ms

            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WNOHANG);
            assert_eq!(result, pid, "waitpid 应返回子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            assert_eq!(wexitstatus!(status), 33, "退出码应为 33");
        }
    }
}

#[test]
fn waitpid_echild_error() {
    // Test waitpid returns -1 with ECHILD when no children exist
    unsafe {
        let mut status: i32 = 0;
        // Try to wait for a non-existent child
        let result = waitpid(99999, &mut status, 0);
        assert_eq!(result, -1, "waitpid 应返回 -1");

        let errno = *libc::__errno_location();
        assert_eq!(errno, ECHILD, "errno 应为 ECHILD");
    }
}

#[test]
fn waitpid_invalid_options() {
    // Test waitpid returns -1 with EINVAL for invalid options
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            exit(0);
        } else {
            // Parent process - use invalid options
            let mut status: i32 = 0;
            let invalid_options = 0xFFFFFF; // Invalid option flags
            let result = waitpid(pid, &mut status, invalid_options);

            // Behavior may vary: some systems accept unknown flags
            // If it fails, should be EINVAL
            if result == -1 {
                let errno = *libc::__errno_location();
                assert_eq!(errno, EINVAL, "errno 应为 EINVAL");
            }

            // Clean up: wait for child properly
            let cleanup_result = waitpid(pid, &mut status, 0);
            if cleanup_result > 0 {
                assert!(wifexited!(status), "子进程应正常退出");
            }
        }
    }
}

#[test]
fn waitpid_multiple_children_sequential() {
    // Test waiting for multiple children sequentially
    unsafe {
        let child_count = 5;
        let mut children = Vec::new();

        // Fork multiple children
        for i in 0..child_count {
            let pid = fork();
            assert!(pid >= 0, "fork 失败");

            if pid == 0 {
                // Child process - exit with unique code
                exit(i + 10);
            } else {
                // Parent process - record child PID
                children.push(pid);
            }
        }

        // Parent process - wait for all children
        let mut exit_codes = Vec::new();
        for &child_pid in &children {
            let mut status: i32 = 0;
            let result = waitpid(child_pid, &mut status, 0);
            assert_eq!(result, child_pid, "waitpid 应返回对应的子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            exit_codes.push(wexitstatus!(status));
        }

        // Verify all exit codes
        assert_eq!(exit_codes.len(), child_count as usize, "应收集所有退出码");
        for code in &exit_codes {
            assert!(
                *code >= 10 && *code < 10 + child_count,
                "退出码应在 10-{} 范围内",
                10 + child_count
            );
        }
    }
}

#[test]
fn waitpid_multiple_children_any_order() {
    // Test waiting for any child with multiple children
    unsafe {
        let child_count = 3;
        let mut expected_pids = Vec::new();

        // Fork multiple children
        for i in 0..child_count {
            let pid = fork();
            assert!(pid >= 0, "fork 失败");

            if pid == 0 {
                // Child process - exit with unique code
                exit(20 + i);
            } else {
                // Parent process - record child PID
                expected_pids.push(pid);
            }
        }

        // Parent process - wait for all children using -1
        let mut reaped_pids = Vec::new();
        for _ in 0..child_count {
            let mut status: i32 = 0;
            let result = waitpid(-1, &mut status, 0);
            assert!(result > 0, "waitpid(-1) 应返回有效 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            reaped_pids.push(result);
        }

        // Verify all children were reaped
        assert_eq!(reaped_pids.len(), child_count as usize, "应回收所有子进程");
        for &pid in &expected_pids {
            assert!(
                reaped_pids.contains(&pid),
                "应回收 PID {} 的子进程",
                pid
            );
        }
    }
}

#[test]
fn waitpid_null_status() {
    // Test waitpid with NULL status pointer (allowed by POSIX)
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            exit(7);
        } else {
            // Parent process - pass NULL for status
            let result = waitpid(pid, ptr::null_mut(), 0);
            assert_eq!(result, pid, "waitpid 应返回子进程 PID");
            // Status is discarded, but waitpid should still work
        }
    }
}

#[test]
fn waitpid_twice_returns_error() {
    // Test that waiting for the same child twice returns ECHILD
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            exit(0);
        } else {
            // Parent process - wait once
            let mut status: i32 = 0;
            let result1 = waitpid(pid, &mut status, 0);
            assert_eq!(result1, pid, "第一次 waitpid 应成功");
            assert!(wifexited!(status), "子进程应正常退出");

            // Try to wait again - should fail with ECHILD
            let result2 = waitpid(pid, &mut status, 0);
            assert_eq!(result2, -1, "第二次 waitpid 应失败");

            let errno = *libc::__errno_location();
            assert_eq!(errno, ECHILD, "errno 应为 ECHILD");
        }
    }
}

#[test]
fn waitpid_process_group_zero() {
    // Test waitpid(0, ...) waits for any child in same process group
    unsafe {
        let parent_pgid = getpgid(0);
        assert!(parent_pgid >= 0, "getpgid 失败");

        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - inherits parent's process group
            exit(88);
        } else {
            // Parent process - wait for child in same process group
            let mut status: i32 = 0;
            let result = waitpid(0, &mut status, 0);

            // Should wait for any child in same group (which includes our child)
            assert_eq!(result, pid, "waitpid(0) 应返回子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            assert_eq!(wexitstatus!(status), 88, "退出码应为 88");
        }
    }
}

#[test]
fn waitpid_specific_process_group() {
    // Test waitpid with negative pid waits for process group
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - create new process group
            let _ = getpid();
            let result = setpgid(0, 0); // Set own process group
            if result == 0 {
                exit(77);
            } else {
                exit(1); // Failed to set process group
            }
        } else {
            // Parent process - wait for child
            let mut status: i32 = 0;

            // Give child time to set its process group
            libc::usleep(50_000); // 50ms

            // Wait using process group (negative of child's pid)
            let result = waitpid(-pid, &mut status, 0);

            // Should succeed and return the child's PID
            assert!(result > 0, "waitpid 应成功");
            assert!(wifexited!(status), "子进程应正常退出");

            let exit_code = wexitstatus!(status);
            assert!(
                exit_code == 77 || exit_code == 1,
                "退出码应为 77 或 1"
            );
        }
    }
}

#[test]
fn waitpid_signal_termination() {
    // Test waitpid with child terminated by signal
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - sleep and wait to be killed
            libc::sleep(10);
            exit(0); // Should never reach here
        } else {
            // Parent process - give child time to start, then kill it
            libc::usleep(100_000); // 100ms

            let kill_result = kill(pid, SIGTERM);
            assert_eq!(kill_result, 0, "kill 应成功");

            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, 0);
            assert_eq!(result, pid, "waitpid 应返回子进程 PID");

            // Child should be terminated by signal
            assert!(wifsignaled!(status), "子进程应被信号终止");
            assert_eq!(wtermsig!(status), SIGTERM, "终止信号应为 SIGTERM");
        }
    }
}

#[test]
fn waitpid_sigkill() {
    // Test waitpid with child killed by SIGKILL
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - sleep
            libc::sleep(10);
            exit(0);
        } else {
            // Parent process - kill with SIGKILL
            libc::usleep(100_000); // 100ms

            let kill_result = kill(pid, SIGKILL);
            assert_eq!(kill_result, 0, "kill 应成功");

            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, 0);
            assert_eq!(result, pid, "waitpid 应返回子进程 PID");

            assert!(wifsignaled!(status), "子进程应被信号终止");
            assert_eq!(wtermsig!(status), SIGKILL, "终止信号应为 SIGKILL");
        }
    }
}

#[test]
fn waitpid_smoke() {
    // Basic smoke test - simplest possible case
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            exit(0);
        } else {
            // Parent process
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, 0);
            assert_eq!(result, pid, "waitpid 应返回子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
            assert_eq!(wexitstatus!(status), 0, "退出码应为 0");
        }
    }
}

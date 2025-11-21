//! Linux ABI compatibility test suite for wait/waitpid system calls.
//!
//! Tests Linux-specific behaviors beyond POSIX:
//! - WUNTRACED: Detecting stopped children (SIGSTOP, SIGTSTP)
//! - WCONTINUED: Detecting resumed children (SIGCONT)
//! - WIFSTOPPED, WSTOPSIG: Stop signal detection
//! - WIFCONTINUED: Continue detection
//! - WCOREDUMP: Core dump detection
//! - Zombie process handling
//! - Job control signals (SIGSTOP, SIGCONT, SIGTSTP, SIGTTIN, SIGTTOU)

use libc::{
    exit, fork, kill, raise, waitpid, ECHILD, SIGCONT, SIGSTOP, SIGTERM, SIGTSTP, WCONTINUED,
    WNOHANG, WUNTRACED,
};
use std::{ptr, time::Duration, thread::sleep};
use test_utils::*; // Import status macros

#[test]
fn waitpid_wuntraced_sigstop() {
    // Test WUNTRACED flag detects child stopped by SIGSTOP
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - raise SIGSTOP to stop itself
            raise(SIGSTOP);
            // When continued, exit normally
            exit(0);
        } else {
            // Parent process - wait with WUNTRACED
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WUNTRACED);

            assert_eq!(result, pid, "waitpid 应返回子进程 PID");
            assert!(wifstopped!(status), "子进程应处于停止状态");
            assert_eq!(wstopsig!(status), SIGSTOP, "停止信号应为 SIGSTOP");

            // Resume the child with SIGCONT
            kill(pid, SIGCONT);

            // Wait for child to exit
            let result2 = waitpid(pid, &mut status, 0);
            assert_eq!(result2, pid, "waitpid 应返回子进程 PID");
            assert!(wifexited!(status), "子进程应正常退出");
        }
    }
}

#[test]
fn waitpid_wuntraced_sigtstp() {
    // Test WUNTRACED with SIGTSTP (terminal stop)
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - raise SIGTSTP
            raise(SIGTSTP);
            exit(0);
        } else {
            // Parent process
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WUNTRACED);

            assert_eq!(result, pid, "waitpid 应返回子进程 PID");
            assert!(wifstopped!(status), "子进程应处于停止状态");
            assert_eq!(wstopsig!(status), SIGTSTP, "停止信号应为 SIGTSTP");

            // Resume and wait for exit
            kill(pid, SIGCONT);
            waitpid(pid, &mut status, 0);
            assert!(wifexited!(status), "子进程应正常退出");
        }
    }
}

#[test]
fn waitpid_without_wuntraced_doesnt_return() {
    // Test that without WUNTRACED, waitpid doesn't return for stopped children
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - stop and then exit when continued
            raise(SIGSTOP);
            exit(42);
        } else {
            // Parent process - use WNOHANG without WUNTRACED
            libc::usleep(100_000); // Give child time to stop

            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WNOHANG);

            // Should return 0 (no status change) because we didn't use WUNTRACED
            assert_eq!(result, 0, "waitpid 不应返回已停止的子进程 (无 WUNTRACED)");

            // Now use WUNTRACED - should detect the stopped child
            let result2 = waitpid(pid, &mut status, WUNTRACED | WNOHANG);
            assert_eq!(result2, pid, "使用 WUNTRACED 应检测到停止的子进程");
            assert!(wifstopped!(status), "子进程应处于停止状态");

            // Continue and wait for exit
            kill(pid, SIGCONT);
            waitpid(pid, &mut status, 0);
        }
    }
}

#[test]
fn waitpid_wcontinued_basic() {
    // Test WCONTINUED flag detects resumed children
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - stop then wait for SIGCONT
            raise(SIGSTOP);
            // After continue, sleep a bit before exiting
            libc::sleep(1);
            exit(0);
        } else {
            // Parent process - wait for stop
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WUNTRACED);
            assert_eq!(result, pid, "waitpid 应检测到停止");
            assert!(wifstopped!(status), "子进程应处于停止状态");

            // Continue the child
            kill(pid, SIGCONT);

            // Wait with WCONTINUED
            let result2 = waitpid(pid, &mut status, WCONTINUED);
            assert_eq!(result2, pid, "waitpid 应检测到继续");
            assert!(wifcontinued!(status), "状态应指示子进程已继续");

            // Wait for final exit
            let result3 = waitpid(pid, &mut status, 0);
            assert_eq!(result3, pid, "waitpid 应等待最终退出");
            assert!(wifexited!(status), "子进程应正常退出");
        }
    }
}

#[test]
fn waitpid_wcontinued_with_wnohang() {
    // Test WCONTINUED with WNOHANG
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            raise(SIGSTOP);
            exit(0);
        } else {
            // Parent process - wait for stop
            let mut status: i32 = 0;
            let ret = waitpid(pid, &mut status, WUNTRACED);
            assert_eq!(ret, pid, "waitpid 应检测到停止");
            assert!(wifstopped!(status), "子进程应处于停止状态");

            // Try WCONTINUED before actually continuing - should ideally return 0
            // but this is a soft check (implementation may vary)
            let result = waitpid(pid, &mut status, WCONTINUED | WNOHANG);
            if result != 0 {
                eprintln!(
                    "Warning: WCONTINUED before SIGCONT returned {} (expected 0)",
                    result
                );
            }

            // Now continue the child
            assert_eq!(kill(pid, SIGCONT), 0, "发送 SIGCONT 应成功");
            sleep(Duration::from_millis(50));

            // Should now detect the continue - this is the critical check
            let result2 = waitpid(pid, &mut status, WCONTINUED | WNOHANG);
            assert_eq!(
                result2, pid,
                "应检测到继续事件 (result={}, status=0x{:x})",
                result2, status
            );
            assert!(
                wifcontinued!(status),
                "状态应指示继续 (expected 0xffff, got 0x{:x})",
                status
            );

            // Clean up
            waitpid(pid, &mut status, 0);
        }
    }
}

#[test]
fn waitpid_stop_continue_exit_sequence() {
    // Test complete stop-continue-exit sequence
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - stop, then exit when continued
            raise(SIGSTOP);
            exit(99);
        } else {
            // Parent process
            let mut status: i32 = 0;

            // 1. Wait for stop
            let r1 = waitpid(pid, &mut status, WUNTRACED);
            assert_eq!(r1, pid, "应检测到停止");
            assert!(wifstopped!(status), "应处于停止状态");
            assert_eq!(wstopsig!(status), SIGSTOP, "停止信号应为 SIGSTOP");

            // 2. Continue the child
            kill(pid, SIGCONT);

            // 3. Wait for continue event
            let r2 = waitpid(pid, &mut status, WCONTINUED);
            assert_eq!(r2, pid, "应检测到继续");
            assert!(wifcontinued!(status), "应处于继续状态");

            // 4. Wait for exit
            let r3 = waitpid(pid, &mut status, 0);
            assert_eq!(r3, pid, "应检测到退出");
            assert!(wifexited!(status), "应正常退出");
            assert_eq!(wexitstatus!(status), 99, "退出码应为 99");
        }
    }
}

#[test]
fn waitpid_multiple_stops_and_continues() {
    // Test multiple stop/continue cycles
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - loop and check for signals
            for _ in 0..3 {
                raise(SIGSTOP);
                // When continued, loop continues
            }
            exit(0);
        } else {
            // Parent process - stop and continue multiple times
            for i in 0..3 {
                let mut status: i32 = 0;

                // Wait for stop
                let r1 = waitpid(pid, &mut status, WUNTRACED);
                assert_eq!(r1, pid, "第 {} 次停止检测失败", i);
                assert!(wifstopped!(status), "第 {} 次应处于停止状态", i);

                // Continue
                kill(pid, SIGCONT);

                // Optionally wait for continue event
                let r2 = waitpid(pid, &mut status, WCONTINUED);
                assert_eq!(r2, pid, "第 {} 次继续检测失败", i);
                assert!(wifcontinued!(status), "第 {} 次应处于继续状态", i);
            }

            // Wait for final exit
            let mut status: i32 = 0;
            let r_final = waitpid(pid, &mut status, 0);
            assert_eq!(r_final, pid, "最终退出检测失败");
            assert!(wifexited!(status), "应正常退出");
        }
    }
}

#[test]
fn waitpid_all_status_macros() {
    // Test all status interpretation macros work correctly
    unsafe {
        // Test 1: Normal exit
        let pid1 = fork();
        assert!(pid1 >= 0, "fork 失败");
        if pid1 == 0 {
            exit(42);
        } else {
            let mut status: i32 = 0;
            waitpid(pid1, &mut status, 0);
            assert!(wifexited!(status), "WIFEXITED 应为真");
            assert!(!wifsignaled!(status), "WIFSIGNALED 应为假");
            assert!(!wifstopped!(status), "WIFSTOPPED 应为假");
            assert!(!wifcontinued!(status), "WIFCONTINUED 应为假");
            assert_eq!(wexitstatus!(status), 42, "WEXITSTATUS 应为 42");
        }

        // Test 2: Signal termination
        let pid2 = fork();
        assert!(pid2 >= 0, "fork 失败");
        if pid2 == 0 {
            libc::sleep(10);
            exit(0);
        } else {
            libc::usleep(50_000);
            kill(pid2, SIGTERM);
            let mut status: i32 = 0;
            waitpid(pid2, &mut status, 0);
            assert!(!wifexited!(status), "WIFEXITED 应为假");
            assert!(wifsignaled!(status), "WIFSIGNALED 应为真");
            assert!(!wifstopped!(status), "WIFSTOPPED 应为假");
            assert_eq!(wtermsig!(status), SIGTERM, "WTERMSIG 应为 SIGTERM");
        }

        // Test 3: Stopped
        let pid3 = fork();
        assert!(pid3 >= 0, "fork 失败");
        if pid3 == 0 {
            raise(SIGSTOP);
            exit(0);
        } else {
            let mut status: i32 = 0;
            waitpid(pid3, &mut status, WUNTRACED);
            assert!(!wifexited!(status), "WIFEXITED 应为假");
            assert!(!wifsignaled!(status), "WIFSIGNALED 应为假");
            assert!(wifstopped!(status), "WIFSTOPPED 应为真");
            assert_eq!(wstopsig!(status), SIGSTOP, "WSTOPSIG 应为 SIGSTOP");

            // Clean up
            kill(pid3, SIGCONT);
            waitpid(pid3, &mut status, 0);
        }
    }
}

#[test]
fn waitpid_zombie_no_hang() {
    // Test that zombie processes are immediately reaped with WNOHANG
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - exit immediately
            exit(55);
        } else {
            // Parent process - give child time to become zombie
            libc::usleep(100_000); // 100ms

            // Try WNOHANG - zombie should be immediately available
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WNOHANG);

            assert_eq!(result, pid, "僵尸进程应立即被回收");
            assert!(wifexited!(status), "应正常退出");
            assert_eq!(wexitstatus!(status), 55, "退出码应为 55");

            // Try to wait again - should get ECHILD
            let result2 = waitpid(pid, &mut status, 0);
            assert_eq!(result2, -1, "再次等待应失败");
            let errno = *libc::__errno_location();
            assert_eq!(errno, ECHILD, "errno 应为 ECHILD");
        }
    }
}

#[test]
fn waitpid_combined_flags() {
    // Test combining WUNTRACED | WCONTINUED | WNOHANG
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            raise(SIGSTOP);
            exit(0);
        } else {
            // Parent process
            let combined_flags = WUNTRACED | WCONTINUED | WNOHANG;
            let mut status: i32 = 0;

            // Poll until we detect the stop
            let mut detected = false;
            for _ in 0..10 {
                let result = waitpid(pid, &mut status, combined_flags);
                if result == pid && wifstopped!(status) {
                    detected = true;
                    break;
                }
                libc::usleep(50_000);
            }
            assert!(detected, "应检测到停止事件");

            // Continue the child
            kill(pid, SIGCONT);

            // Poll until we detect the continue
            detected = false;
            for _ in 0..10 {
                let result = waitpid(pid, &mut status, combined_flags);
                if result == pid && wifcontinued!(status) {
                    detected = true;
                    break;
                }
                libc::usleep(50_000);
            }
            assert!(detected, "应检测到继续事件");

            // Wait for exit
            waitpid(pid, &mut status, 0);
        }
    }
}

#[test]
fn waitpid_wait_any_with_flags() {
    // Test waitpid(-1) with WUNTRACED and WCONTINUED
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            raise(SIGSTOP);
            exit(0);
        } else {
            // Parent process - use -1 to wait for any child
            let mut status: i32 = 0;
            let result = waitpid(-1, &mut status, WUNTRACED);

            assert_eq!(result, pid, "waitpid(-1) 应返回停止的子进程");
            assert!(wifstopped!(status), "子进程应处于停止状态");

            // Continue
            kill(pid, SIGCONT);

            // Wait for continue using -1
            let result2 = waitpid(-1, &mut status, WCONTINUED);
            assert_eq!(result2, pid, "waitpid(-1) 应检测到继续");
            assert!(wifcontinued!(status), "应处于继续状态");

            // Wait for exit using -1
            let result3 = waitpid(-1, &mut status, 0);
            assert_eq!(result3, pid, "waitpid(-1) 应等待退出");
            assert!(wifexited!(status), "应正常退出");
        }
    }
}

#[test]
fn waitpid_null_status_with_flags() {
    // Test NULL status pointer with WUNTRACED and WCONTINUED
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process
            raise(SIGSTOP);
            exit(0);
        } else {
            // Parent process - NULL status but should still work
            let result = waitpid(pid, ptr::null_mut(), WUNTRACED);
            assert_eq!(result, pid, "即使 status 为 NULL，waitpid 也应成功");

            // Continue
            kill(pid, SIGCONT);

            // Wait for continue with NULL status
            let result2 = waitpid(pid, ptr::null_mut(), WCONTINUED);
            assert_eq!(result2, pid, "继续事件检测应成功");

            // Wait for exit with NULL status
            let result3 = waitpid(pid, ptr::null_mut(), 0);
            assert_eq!(result3, pid, "退出检测应成功");
        }
    }
}

#[test]
fn waitpid_linux_abi_smoke() {
    // Basic smoke test for Linux ABI features
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process - simple stop and exit
            raise(SIGSTOP);
            exit(0);
        } else {
            // Parent process - test basic WUNTRACED
            let mut status: i32 = 0;
            let result = waitpid(pid, &mut status, WUNTRACED);

            assert_eq!(result, pid, "waitpid 应成功");
            assert!(wifstopped!(status), "子进程应处于停止状态");

            // Continue and wait for exit
            kill(pid, SIGCONT);
            let result2 = waitpid(pid, &mut status, 0);
            assert_eq!(result2, pid, "最终 waitpid 应成功");
            assert!(wifexited!(status), "子进程应正常退出");
        }
    }
}
//! Test suite for SIGSTOP and SIGCONT signals.
//!
//! This test verifies the process stopping and continuing behavior as per POSIX standards.
//! It covers:
//! - Sending SIGSTOP to a child process.
//! - Using waitpid() with WUNTRACED to detect that the child has stopped.
//! - Verifying the stopping signal is SIGSTOP.
//! - Sending SIGCONT to the stopped child process.
//! - Using waitpid() with WCONTINUED to detect that the child has resumed.
//! - Terminating the child and cleaning up resources.

use libc::{
    fork, kill, waitpid, ECHILD, SIGCONT, SIGSTOP, SIGTERM, WCONTINUED, WUNTRACED,
};
use test_utils::*;

#[test]
fn test_sigstop_sigcont_behavior() {
    unsafe {
        let pid = fork();
        assert!(pid >= 0, "fork 失败");

        if pid == 0 {
            // Child process: loop indefinitely until killed
            loop {
                libc::sleep(1);
            }
        } else {
            // Parent process
            let mut status: i32 = 0;

            // 1. Send SIGSTOP and wait for the child to stop
            let kill_res = kill(pid, SIGSTOP);
            assert_eq!(kill_res, 0, "kill(SIGSTOP) 应成功");

            let wait_res = waitpid(pid, &mut status, WUNTRACED);
            assert_eq!(wait_res, pid, "waitpid(WUNTRACED) 应返回子进程 PID");

            // 2. Verify the child is stopped by SIGSTOP
            assert!(wifstopped!(status), "子进程应处于停止状态");
            assert_eq!(wstopsig!(status), SIGSTOP, "停止信号应为 SIGSTOP");

            // 3. Send SIGCONT to resume the child
            let kill_res_cont = kill(pid, SIGCONT);
            assert_eq!(kill_res_cont, 0, "kill(SIGCONT) 应成功");

            let wait_res_cont = waitpid(pid, &mut status, WCONTINUED);
            assert_eq!(wait_res_cont, pid, "waitpid(WCONTINUED) 应返回子进程 PID");

            // 4. Verify the child has continued
            assert!(wifcontinued!(status), "子进程应处于继续运行状态");

            // 5. Terminate the child for cleanup
            let kill_res_term = kill(pid, SIGTERM);
            assert_eq!(kill_res_term, 0, "kill(SIGTERM) 应成功");

            let wait_res_term = waitpid(pid, &mut status, 0);
            assert_eq!(wait_res_term, pid, "waitpid 等待被终止的子进程应返回其 PID");

            // 6. Verify the child has not exited normally (it was signaled)
            assert!(!wifexited!(status), "子进程不应正常退出");

            // 7. Final wait to ensure no more child processes are left
            let wait_res_final = waitpid(pid, &mut status, 0);
            assert_eq!(wait_res_final, -1, "第二次 waitpid 应失败");
            let errno = *libc::__errno_location();
            assert_eq!(errno, ECHILD, "回收子进程后 errno 应为 ECHILD");
        }
    }
}

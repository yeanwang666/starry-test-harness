#!/usr/bin/env python3
import argparse
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

READY_MSG = "QEMU waiting for connection"
PROMPT = "starry:~#"


def log(msg: str):
    print(f"[starry-ci] {msg}")


def read_stderr(proc: subprocess.Popen, ready_event: threading.Event):
    try:
        for line in proc.stderr:
            sys.stderr.write(line)
            if READY_MSG in line:
                ready_event.set()
    finally:
        ready_event.set()


def connect(port: int, retries: int, delay: float):
    last_err = None
    for _ in range(retries):
        try:
            return socket.create_connection(("localhost", port), timeout=5)
        except OSError as err:
            last_err = err
            time.sleep(delay)
    raise last_err if last_err else RuntimeError("unable to connect")


def run(args):
    root = Path(args.root).resolve()
    if not root.is_dir():
        raise SystemExit(f"StarryOS root not found: {root}")

    plat_config = root / ".axconfig.toml"
    if not plat_config.exists():
        raise SystemExit(f"missing {plat_config}, run make ARCH={args.arch} build first")

    cmd = [
        "make",
        f"ARCH={args.arch}",
        f"PLAT_CONFIG={plat_config}",
        "NET=n",
        "VSOCK=n",
        "ACCEL=n",
        "justrun",
        f"QEMU_ARGS=-monitor none -serial tcp::{args.port},server=on",
    ]
    log(f"spawning {' '.join(cmd)} at {root}")
    env = os.environ.copy()
    env["PWD"] = str(root)
    proc = subprocess.Popen(
        cmd,
        cwd=root,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    ready = threading.Event()
    thread = threading.Thread(target=read_stderr, args=(proc, ready), daemon=True)
    thread.start()

    try:
        if not ready.wait(timeout=args.boot_timeout):
            raise RuntimeError("QEMU did not signal readiness")
        if proc.poll() is not None:
            raise RuntimeError("QEMU exited prematurely")

        buffer = ""
        prompt_seen = False
        attempt = 0
        while attempt < args.retries:
            try:
                sock = connect(args.port, retries=1, delay=1)
                sock.settimeout(2)
            except OSError as err:
                attempt += 1
                if prompt_seen and attempt >= args.retries:
                    break
                if attempt >= args.retries:
                    raise err
                time.sleep(1)
                continue

            try:
                while True:
                    try:
                        data = sock.recv(1024)
                    except socket.timeout:
                        if prompt_seen:
                            break
                        continue
                    if not data:
                        break
                    chunk = data.decode("utf-8", errors="ignore")
                    print(chunk, end="")
                    buffer += chunk
                    if not prompt_seen and PROMPT in buffer:
                        prompt_seen = True
                        log("shell prompt detected, sending exit")
                        sock.sendall(b"exit\n")
            except ConnectionResetError:
                if not prompt_seen:
                    attempt += 1
                    continue
            finally:
                try:
                    sock.close()
                except OSError:
                    pass

            if prompt_seen:
                break
            attempt += 1

        if not prompt_seen:
            raise RuntimeError("shell prompt not observed")
        log("BusyBox shell exited cleanly")
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run StarryOS under QEMU and verify shell prompt")
    parser.add_argument("--root", required=True, help="Path to StarryOS repository root")
    parser.add_argument("--arch", default="aarch64")
    parser.add_argument("--port", type=int, default=4444)
    parser.add_argument("--boot-timeout", type=int, default=60)
    parser.add_argument("--retries", type=int, default=5)
    args = parser.parse_args()
    run(args)

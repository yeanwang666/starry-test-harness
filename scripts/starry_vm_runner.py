#!/usr/bin/env python3
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

READY_MSG = "QEMU waiting for connection"
PROMPT = "starry:~#"
EXIT_PATTERN = re.compile(r"__EXIT:(-?\d+)__")


def log(msg: str) -> None:
    print(f"[starry-ci] {msg}")


def read_stderr(proc: subprocess.Popen, ready_event: threading.Event) -> None:
    try:
        for line in proc.stderr:
            sys.stderr.write(line)
            if READY_MSG in line:
                ready_event.set()
    finally:
        ready_event.set()


def connect(port: int, retries: int, delay: float) -> socket.socket:
    last_err = None
    for _ in range(retries):
        try:
            return socket.create_connection(("localhost", port), timeout=5)
        except OSError as err:
            last_err = err
            time.sleep(delay)
    raise last_err if last_err else RuntimeError("unable to connect")


def sanitize_output(raw: str, command: str, full_command: str) -> str:
    text = raw.replace("\r", "")
    for token in (full_command, command, PROMPT):
        if token:
            text = text.replace(token, "")
    text = text.strip()
    if "__EXIT:" in text:
        text = EXIT_PATTERN.split(text)[0].strip()
    if not text:
        return ""

    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end >= start:
        candidate = text[start : end + 1].strip()
        try:
            json.loads(candidate)
            return candidate
        except json.JSONDecodeError:
            pass
    return text


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

    exit_code = 0
    payload = None
    command = args.command
    full_command = f"{command}; echo __EXIT:$?__" if command else None

    try:
        if not ready.wait(timeout=args.boot_timeout):
            raise RuntimeError("QEMU did not signal readiness")
        if proc.poll() is not None:
            raise RuntimeError("QEMU exited prematurely")

        attempt = 0
        completed = False
        last_err = None
        while attempt < args.retries and not completed:
            try:
                sock = connect(args.port, retries=1, delay=1)
                sock.settimeout(2)
            except OSError as err:
                last_err = err
                attempt += 1
                time.sleep(1)
                continue

            try:
                buffer = ""
                command_buffer = ""
                prompt_seen = False
                command_sent = False
                command_start = None

                while True:
                    try:
                        data = sock.recv(1024)
                    except socket.timeout:
                        if prompt_seen and not command_sent:
                            break
                        if command_sent and command_start is not None:
                            if time.monotonic() - command_start > args.command_timeout:
                                raise RuntimeError("command timed out")
                        continue

                    if not data:
                        break

                    chunk = data.decode("utf-8", errors="ignore")
                    if command:
                        sys.stderr.write(chunk)
                    else:
                        print(chunk, end="")

                    buffer += chunk

                    if not prompt_seen and PROMPT in buffer:
                        prompt_seen = True
                        if command:
                            log("shell prompt detected, executing command")
                            sock.sendall(full_command.encode("utf-8") + b"\n")
                            command_sent = True
                            command_start = time.monotonic()
                            command_buffer = ""
                            buffer = ""
                        else:
                            log("shell prompt detected, sending exit")
                            sock.sendall(b"exit\n")
                            completed = True
                            break

                    if command_sent:
                        command_buffer += chunk
                        match = EXIT_PATTERN.search(command_buffer)
                        if match:
                            exit_code = int(match.group(1))
                            payload = sanitize_output(command_buffer, command, full_command)
                            log(f"command completed with exit code {exit_code}")
                            sock.sendall(b"exit\n")
                            completed = True
                            break
                        if command_start is not None and (time.monotonic() - command_start) > args.command_timeout:
                            raise RuntimeError("command timed out")
                if completed:
                    break
            finally:
                try:
                    sock.close()
                except OSError:
                    pass
            attempt += 1

        if command:
            if payload is None:
                raise RuntimeError("shell prompt not observed or command output missing")
        elif not completed:
            raise last_err or RuntimeError("shell prompt not observed")

        log("BusyBox shell exited cleanly")
        return exit_code, payload
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run StarryOS under QEMU and optionally execute a command")
    parser.add_argument("--root", required=True, help="Path to StarryOS repository root")
    parser.add_argument("--arch", default="aarch64")
    parser.add_argument("--port", type=int, default=4444)
    parser.add_argument("--boot-timeout", type=int, default=60)
    parser.add_argument("--retries", type=int, default=5)
    parser.add_argument("--command", help="Shell command to execute once the prompt is ready")
    parser.add_argument("--command-timeout", type=int, default=600)
    args = parser.parse_args()

    try:
        exit_code, payload = run(args)
    except Exception as exc:
        log(f"ERROR: {exc}")
        sys.exit(1)

    if payload is not None:
        if payload and not payload.endswith("\n"):
            print(payload)
        else:
            print(payload, end="")
    sys.exit(exit_code)

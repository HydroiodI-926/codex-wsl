from __future__ import annotations

import os
import shutil
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

from .config import BrokerConfig
from .workspaces import WorkspaceError, WorkspaceStore


SAFE_ENV_KEYS = {
    "CI",
    "COLUMNS",
    "LANG",
    "LC_ALL",
    "LINES",
    "NO_COLOR",
    "TERM",
}


@dataclass
class ExecutionResult:
    exit_code: Optional[int]
    stdout: str
    stderr: str
    duration_ms: int
    timed_out: bool
    output_limited: bool


class SandboxExecutor:
    def __init__(self, config: BrokerConfig, store: WorkspaceStore):
        self.config = config
        self.store = store

    def execute(
        self,
        workspace_id: str,
        command: str,
        cwd: str = ".",
        timeout_seconds: Optional[int] = None,
        network: bool = False,
        env: Optional[Dict[str, str]] = None,
    ) -> ExecutionResult:
        if not command or len(command) > 128 * 1024:
            raise WorkspaceError("command must be between 1 and 131072 characters")
        if network and not self.config.allow_network:
            raise WorkspaceError("network access is disabled by broker policy")
        metadata = self.store.get(workspace_id)
        if not metadata.imported_at:
            raise WorkspaceError("workspace has no imported source baseline")
        timeout = timeout_seconds or self.config.command_timeout_seconds
        if timeout < 1 or timeout > self.config.command_timeout_seconds:
            raise WorkspaceError(
                f"timeout must be between 1 and {self.config.command_timeout_seconds} seconds"
            )
        requested_env = env or {}
        invalid_env = sorted(set(requested_env) - SAFE_ENV_KEYS)
        if invalid_env:
            raise WorkspaceError(f"unsupported environment keys: {', '.join(invalid_env)}")

        workspace = self.store.path(workspace_id)
        resolved_cwd = self.store.resolve_cwd(workspace_id, cwd)
        relative_cwd = resolved_cwd.relative_to(workspace).as_posix()
        command_line = self._build_command(
            workspace, relative_cwd, command, network, requested_env
        )
        return _run_limited(
            command_line,
            timeout_seconds=timeout,
            output_limit=self.config.max_output_bytes,
        )

    def _build_command(
        self,
        workspace: Path,
        relative_cwd: str,
        command: str,
        network: bool,
        env: Dict[str, str],
    ) -> List[str]:
        bwrap = shutil.which(self.config.bwrap_path)
        if not bwrap:
            raise WorkspaceError("bubblewrap is unavailable; refusing unsandboxed execution")

        args = [
            bwrap,
            "--die-with-parent",
            "--new-session",
            "--unshare-user",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-uts",
            "--unshare-cgroup-try",
        ]
        if not network:
            args.append("--unshare-net")
        args.extend(
            [
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--tmpfs",
                "/home",
                "--tmpfs",
                "/root",
                "--tmpfs",
                "/mnt",
                "--tmpfs",
                "/run",
                "--tmpfs",
                "/srv/codexbox",
                "--tmpfs",
                "/etc/codexbox",
                "--dir",
                "/workspace",
                "--bind",
                str(workspace),
                "/workspace",
                "--ro-bind",
                str(workspace / ".git"),
                "/workspace/.git",
                "--proc",
                "/proc",
                "--dev",
                "/dev",
                "--chdir",
                "/workspace" if relative_cwd == "." else f"/workspace/{relative_cwd}",
                "--clearenv",
                "--setenv",
                "PATH",
                "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "--setenv",
                "HOME",
                "/home/codex",
                "--setenv",
                "TMPDIR",
                "/tmp",
                "--setenv",
                "LANG",
                "C.UTF-8",
            ]
        )
        for key, value in sorted(env.items()):
            if "\x00" in value or len(value) > 4096:
                raise WorkspaceError(f"invalid environment value for {key}")
            args.extend(["--setenv", key, value])
        args.extend(["--", "/bin/bash", "--noprofile", "--norc", "-lc", command])
        return args


def _run_limited(
    argv: List[str], timeout_seconds: int, output_limit: int
) -> ExecutionResult:
    started = time.monotonic()
    process = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    stdout = bytearray()
    stderr = bytearray()
    limit_event = threading.Event()
    lock = threading.Lock()

    def reader(pipe, target: bytearray) -> None:
        try:
            while True:
                chunk = pipe.read(64 * 1024)
                if not chunk:
                    return
                with lock:
                    remaining = output_limit - len(stdout) - len(stderr)
                    if remaining <= 0:
                        limit_event.set()
                        return
                    target.extend(chunk[:remaining])
                    if len(chunk) > remaining:
                        limit_event.set()
                        return
        finally:
            pipe.close()

    threads = [
        threading.Thread(target=reader, args=(process.stdout, stdout), daemon=True),
        threading.Thread(target=reader, args=(process.stderr, stderr), daemon=True),
    ]
    for thread in threads:
        thread.start()

    timed_out = False
    while process.poll() is None:
        if limit_event.is_set():
            _kill_process_group(process)
            break
        if time.monotonic() - started >= timeout_seconds:
            timed_out = True
            _kill_process_group(process)
            break
        time.sleep(0.05)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _kill_process_group(process, force=True)
        process.wait()
    for thread in threads:
        thread.join(timeout=2)

    return ExecutionResult(
        exit_code=process.returncode,
        stdout=bytes(stdout).decode("utf-8", "replace"),
        stderr=bytes(stderr).decode("utf-8", "replace"),
        duration_ms=int((time.monotonic() - started) * 1000),
        timed_out=timed_out,
        output_limited=limit_event.is_set(),
    )


def _kill_process_group(process: subprocess.Popen, force: bool = False) -> None:
    if process.poll() is not None:
        return
    sig = signal.SIGKILL if force else signal.SIGTERM
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        return
    if not force:
        try:
            process.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            _kill_process_group(process, force=True)

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Dict, Iterable, List, Optional


NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,47}$")
ID_RE = re.compile(r"^(?:p-[a-z0-9][a-z0-9._-]{0,47}|i-[a-f0-9]{16})$")


class WorkspaceError(RuntimeError):
    pass


@dataclass
class WorkspaceMetadata:
    workspace_id: str
    mode: str
    name: str
    created_at: str
    imported_at: Optional[str] = None
    source_sha256: Optional[str] = None
    baseline_tree: Optional[str] = None


class WorkspaceStore:
    def __init__(
        self,
        root: Path,
        max_files: int = 100_000,
        max_extract_bytes: int = 1024 * 1024 * 1024,
    ):
        self.root = root.resolve()
        self.max_files = max_files
        self.max_extract_bytes = max_extract_bytes
        self.persistent_root = self.root / "persistent"
        self.isolated_root = self.root / "isolated"
        self.metadata_root = self.root / "metadata"
        for directory in (
            self.persistent_root,
            self.isolated_root,
            self.metadata_root,
        ):
            directory.mkdir(parents=True, exist_ok=True)

    def create(self, mode: str, name: Optional[str] = None) -> WorkspaceMetadata:
        if mode not in {"persistent", "isolated"}:
            raise WorkspaceError("mode must be persistent or isolated")
        if mode == "persistent":
            if not name or not NAME_RE.fullmatch(name):
                raise WorkspaceError(
                    "persistent workspace name must match [a-z0-9][a-z0-9._-]{0,47}"
                )
            workspace_id = f"p-{name}"
            workspace_path = self.persistent_root / workspace_id
        else:
            safe_name = name or "task"
            if not NAME_RE.fullmatch(safe_name):
                raise WorkspaceError(
                    "isolated workspace label must match [a-z0-9][a-z0-9._-]{0,47}"
                )
            workspace_id = f"i-{uuid.uuid4().hex[:16]}"
            workspace_path = self.isolated_root / workspace_id

        if workspace_path.exists() or self._metadata_path(workspace_id).exists():
            raise WorkspaceError(f"workspace already exists: {workspace_id}")
        workspace_path.mkdir(mode=0o700, parents=False)
        metadata = WorkspaceMetadata(
            workspace_id=workspace_id,
            mode=mode,
            name=name or "task",
            created_at=_utc_now(),
        )
        self._write_metadata(metadata)
        return metadata

    def list(self) -> List[WorkspaceMetadata]:
        result: List[WorkspaceMetadata] = []
        for path in sorted(self.metadata_root.glob("*.json")):
            try:
                result.append(WorkspaceMetadata(**json.loads(path.read_text("utf-8"))))
            except (OSError, ValueError, TypeError):
                continue
        return result

    def get(self, workspace_id: str) -> WorkspaceMetadata:
        self._validate_id(workspace_id)
        path = self._metadata_path(workspace_id)
        if not path.is_file():
            raise WorkspaceError(f"workspace not found: {workspace_id}")
        try:
            return WorkspaceMetadata(**json.loads(path.read_text("utf-8")))
        except (OSError, ValueError, TypeError) as exc:
            raise WorkspaceError(f"invalid workspace metadata: {workspace_id}") from exc

    def path(self, workspace_id: str) -> Path:
        metadata = self.get(workspace_id)
        base = self.persistent_root if metadata.mode == "persistent" else self.isolated_root
        result = (base / workspace_id).resolve()
        if result.parent != base.resolve() or not result.is_dir():
            raise WorkspaceError(f"workspace directory is unavailable: {workspace_id}")
        return result

    def resolve_cwd(self, workspace_id: str, relative_cwd: str) -> Path:
        if not relative_cwd:
            relative_cwd = "."
        relative = PurePosixPath(relative_cwd)
        if relative.is_absolute() or ".." in relative.parts:
            raise WorkspaceError("cwd must be a relative path inside the workspace")
        root = self.path(workspace_id)
        candidate = (root / Path(*relative.parts)).resolve()
        try:
            candidate.relative_to(root)
        except ValueError as exc:
            raise WorkspaceError("cwd escapes the workspace") from exc
        if not candidate.is_dir():
            raise WorkspaceError("cwd does not exist or is not a directory")
        return candidate

    def import_archive(
        self,
        workspace_id: str,
        stream: BinaryIO,
        source_sha256: Optional[str] = None,
    ) -> WorkspaceMetadata:
        workspace = self.path(workspace_id)
        if any(workspace.iterdir()):
            raise WorkspaceError("workspace must be empty before import")

        staging = Path(tempfile.mkdtemp(prefix="import-", dir=str(workspace.parent)))
        try:
            with tarfile.open(fileobj=stream, mode="r|gz") as archive:
                self._safe_extract(archive, staging)
            for child in staging.iterdir():
                child.replace(workspace / child.name)
        except Exception as exc:
            _rmtree(staging, ignore_errors=True)
            if isinstance(exc, WorkspaceError):
                raise
            raise WorkspaceError(f"invalid source archive: {exc}") from exc
        _rmtree(staging, ignore_errors=True)

        self._initialize_baseline(workspace)
        metadata = self.get(workspace_id)
        metadata.imported_at = _utc_now()
        metadata.source_sha256 = source_sha256
        metadata.baseline_tree = self._git_output(workspace, "rev-parse", "HEAD^{tree}")
        self._write_metadata(metadata)
        return metadata

    def change_bundle(self, workspace_id: str) -> bytes:
        workspace = self.path(workspace_id)
        metadata = self.get(workspace_id)
        if not (workspace / ".git").is_dir() or not metadata.baseline_tree:
            raise WorkspaceError("workspace has no imported baseline")

        self._git(workspace, "add", "-A")
        patch = self._staged_patch(workspace)
        status_raw = subprocess.run(
            [
                "git",
                "-C",
                str(workspace),
                "diff",
                "--cached",
                "--name-status",
                "-z",
                "HEAD",
                "--",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
        manifest = {
            "schema": 1,
            "workspace_id": metadata.workspace_id,
            "mode": metadata.mode,
            "created_at": metadata.created_at,
            "generated_at": _utc_now(),
            "source_sha256": metadata.source_sha256,
            "baseline_tree": metadata.baseline_tree,
            "changes": _parse_name_status(status_raw),
            "patch_sha256": hashlib.sha256(patch).hexdigest(),
        }

        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            _add_bytes(archive, "change.patch", patch)
            _add_bytes(
                archive,
                "manifest.json",
                json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n",
            )
        return output.getvalue()

    def checkpoint_persistent(
        self,
        workspace_id: str,
        confirmation: str,
        expected_patch_sha256: str,
    ) -> WorkspaceMetadata:
        metadata = self.get(workspace_id)
        if metadata.mode != "persistent":
            raise WorkspaceError("only persistent workspaces support checkpoints")
        if confirmation != workspace_id:
            raise WorkspaceError("confirmation must exactly match the workspace id")
        workspace = self.path(workspace_id)
        self._git(workspace, "add", "-A")
        patch_sha256 = hashlib.sha256(self._staged_patch(workspace)).hexdigest()
        if not re.fullmatch(r"[a-f0-9]{64}", expected_patch_sha256):
            raise WorkspaceError("expected patch hash is invalid")
        if patch_sha256 != expected_patch_sha256:
            raise WorkspaceError(
                "workspace changed after the reviewed bundle was exported; checkpoint refused"
            )
        staged = subprocess.run(
            ["git", "-C", str(workspace), "diff", "--cached", "--quiet", "HEAD", "--"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if staged.returncode not in {0, 1}:
            raise WorkspaceError("cannot inspect persistent checkpoint changes")
        if staged.returncode == 1:
            self._git(
                workspace,
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--quiet",
                "-m",
                "CodexBox reviewed checkpoint",
            )
        metadata.baseline_tree = self._git_output(workspace, "rev-parse", "HEAD^{tree}")
        self._write_metadata(metadata)
        return metadata

    @staticmethod
    def _staged_patch(workspace: Path) -> bytes:
        return subprocess.run(
            [
                "git",
                "-C",
                str(workspace),
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "HEAD",
                "--",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout

    def delete_isolated(self, workspace_id: str, confirmation: str) -> None:
        metadata = self.get(workspace_id)
        if metadata.mode != "isolated":
            raise WorkspaceError("persistent workspaces cannot be deleted through the broker")
        if confirmation != workspace_id:
            raise WorkspaceError("confirmation must exactly match the workspace id")
        workspace = self.path(workspace_id)
        _rmtree(workspace)
        self._metadata_path(workspace_id).unlink(missing_ok=True)

    def _safe_extract(self, archive: tarfile.TarFile, destination: Path) -> None:
        members = 0
        extracted_bytes = 0
        deferred_links: List[tarfile.TarInfo] = []
        for member in archive:
            members += 1
            if members > self.max_files:
                raise WorkspaceError("archive contains too many entries")
            if member.size < 0:
                raise WorkspaceError("archive member has an invalid size")
            extracted_bytes += member.size
            if extracted_bytes > self.max_extract_bytes:
                raise WorkspaceError("archive expands beyond the configured size limit")
            relative = _safe_member_path(member.name)
            if not relative.parts:
                continue
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)

            if member.isdir():
                target.mkdir(exist_ok=True)
            elif member.isfile():
                source = archive.extractfile(member)
                if source is None:
                    raise WorkspaceError(f"cannot read archive member: {member.name}")
                with target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                target.chmod(0o755 if member.mode & stat.S_IXUSR else 0o644)
            elif member.issym():
                deferred_links.append(member)
            else:
                raise WorkspaceError(f"unsupported archive member: {member.name}")

        for member in deferred_links:
            relative = _safe_member_path(member.name)
            link_target = PurePosixPath(member.linkname)
            if link_target.is_absolute():
                raise WorkspaceError(f"absolute symlink is not allowed: {member.name}")
            normalized = _normalize_link(relative.parent, link_target)
            if normalized is None:
                raise WorkspaceError(f"symlink escapes workspace: {member.name}")
            target = destination.joinpath(*relative.parts)
            os.symlink(member.linkname, target)

    def _initialize_baseline(self, workspace: Path) -> None:
        self._git(workspace, "init", "--quiet")
        self._git(workspace, "config", "user.name", "CodexBox Baseline")
        self._git(workspace, "config", "user.email", "codexbox@localhost")
        self._git(workspace, "add", "-A", "-f")
        self._git(
            workspace,
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "CodexBox baseline",
        )

    def _git(self, workspace: Path, *args: str) -> None:
        try:
            subprocess.run(
                ["git", "-C", str(workspace), *args],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            detail = getattr(exc, "stderr", b"")
            message = detail.decode("utf-8", "replace").strip() if detail else str(exc)
            raise WorkspaceError(f"git operation failed: {message}") from exc

    def _git_output(self, workspace: Path, *args: str) -> str:
        try:
            return subprocess.run(
                ["git", "-C", str(workspace), *args],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError) as exc:
            raise WorkspaceError("cannot read baseline tree") from exc

    def _metadata_path(self, workspace_id: str) -> Path:
        return self.metadata_root / f"{workspace_id}.json"

    def _write_metadata(self, metadata: WorkspaceMetadata) -> None:
        path = self._metadata_path(metadata.workspace_id)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(asdict(metadata), indent=2, sort_keys=True) + "\n", "utf-8"
        )
        os.chmod(temporary, 0o600)
        temporary.replace(path)

    @staticmethod
    def _validate_id(workspace_id: str) -> None:
        if not ID_RE.fullmatch(workspace_id):
            raise WorkspaceError("invalid workspace id")


def _safe_member_path(name: str) -> PurePosixPath:
    if "\\" in name or "\x00" in name:
        raise WorkspaceError(f"invalid archive path: {name!r}")
    path = PurePosixPath(name)
    parts = tuple(part for part in path.parts if part not in {"", "."})
    if path.is_absolute() or ".." in parts:
        raise WorkspaceError(f"archive path escapes workspace: {name}")
    if ".git" in parts:
        raise WorkspaceError("source archives must not contain .git")
    return PurePosixPath(*parts)


def _normalize_link(
    parent: PurePosixPath, target: PurePosixPath
) -> Optional[PurePosixPath]:
    stack: List[str] = [part for part in parent.parts if part not in {"", "."}]
    for part in target.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                return None
            stack.pop()
        else:
            stack.append(part)
    return PurePosixPath(*stack)


def _parse_name_status(raw: bytes) -> List[Dict[str, str]]:
    tokens = raw.decode("utf-8", "surrogateescape").split("\x00")
    changes: List[Dict[str, str]] = []
    index = 0
    while index < len(tokens) and tokens[index]:
        status = tokens[index]
        index += 1
        if index >= len(tokens):
            break
        path = tokens[index]
        index += 1
        entry = {"status": status, "path": path}
        if status.startswith(("R", "C")) and index < len(tokens):
            entry["target"] = tokens[index]
            index += 1
        changes.append(entry)
    return changes


def _add_bytes(archive: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name=name)
    info.size = len(data)
    info.mode = 0o600
    info.mtime = 0
    archive.addfile(info, io.BytesIO(data))


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _rmtree(path: Path, ignore_errors: bool = False) -> None:
    def make_writable_and_retry(function, target, _exc_info):
        os.chmod(target, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        function(target)

    shutil.rmtree(path, ignore_errors=ignore_errors, onerror=make_writable_and_retry)

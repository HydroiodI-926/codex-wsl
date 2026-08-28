from __future__ import annotations

import hmac
import io
import json
import logging
import re
import threading
from dataclasses import asdict
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse

from . import __version__
from .config import BrokerConfig
from .executor import SandboxExecutor
from .workspaces import WorkspaceError, WorkspaceStore


WORKSPACE_PATH_RE = re.compile(
    r"^/v1/workspaces/(?P<id>(?:p-[a-z0-9][a-z0-9._-]{0,47}|i-[a-f0-9]{16}))/(?P<action>import|exec|changes|checkpoint|delete)$"
)


class BrokerApplication:
    def __init__(self, config: BrokerConfig):
        self.config = config
        self.token = _read_token(config.token_file)
        self.store = WorkspaceStore(
            config.root,
            max_files=config.max_files,
            max_extract_bytes=config.max_extract_bytes,
        )
        self.executor = SandboxExecutor(config, self.store)
        self._locks_guard = threading.Lock()
        self._workspace_locks: Dict[str, threading.Lock] = {}

    def workspace_lock(self, workspace_id: str) -> threading.Lock:
        with self._locks_guard:
            return self._workspace_locks.setdefault(workspace_id, threading.Lock())

    def handler_class(self):
        application = self

        class Handler(BaseHTTPRequestHandler):
            server_version = f"CodexBox/{__version__}"

            def do_GET(self) -> None:
                if not self._authorized():
                    return
                path = urlparse(self.path).path
                if path == "/v1/health":
                    self._json(
                        HTTPStatus.OK,
                        {
                            "status": "ok",
                            "version": __version__,
                            "network_allowed": application.config.allow_network,
                        },
                    )
                    return
                if path == "/v1/workspaces":
                    self._json(
                        HTTPStatus.OK,
                        {"workspaces": [asdict(item) for item in application.store.list()]},
                    )
                    return
                match = WORKSPACE_PATH_RE.fullmatch(path)
                if match and match.group("action") == "changes":
                    try:
                        workspace_id = match.group("id")
                        with application.workspace_lock(workspace_id):
                            bundle = application.store.change_bundle(workspace_id)
                    except WorkspaceError as exc:
                        self._error(HTTPStatus.BAD_REQUEST, str(exc))
                        return
                    self.send_response(HTTPStatus.OK)
                    self.send_header("Content-Type", "application/gzip")
                    self.send_header("Content-Length", str(len(bundle)))
                    self.send_header(
                        "Content-Disposition",
                        f'attachment; filename="{match.group("id")}-changes.tar.gz"',
                    )
                    self.end_headers()
                    self.wfile.write(bundle)
                    return
                self._error(HTTPStatus.NOT_FOUND, "endpoint not found")

            def do_POST(self) -> None:
                if not self._authorized():
                    return
                path = urlparse(self.path).path
                try:
                    if path == "/v1/workspaces":
                        body = self._read_json()
                        metadata = application.store.create(
                            str(body.get("mode", "")), body.get("name")
                        )
                        self._json(HTTPStatus.CREATED, asdict(metadata))
                        return

                    match = WORKSPACE_PATH_RE.fullmatch(path)
                    if not match:
                        self._error(HTTPStatus.NOT_FOUND, "endpoint not found")
                        return
                    workspace_id = match.group("id")
                    action = match.group("action")
                    if action == "import":
                        length = self._content_length()
                        if length > application.config.max_upload_bytes:
                            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "upload too large")
                            return
                        with application.workspace_lock(workspace_id):
                            metadata = application.store.import_archive(
                                workspace_id,
                                _LimitedReader(self.rfile, length),
                                source_sha256=self.headers.get("X-Source-SHA256"),
                            )
                        self._json(HTTPStatus.OK, asdict(metadata))
                        return
                    if action == "exec":
                        body = self._read_json()
                        with application.workspace_lock(workspace_id):
                            result = application.executor.execute(
                                workspace_id=workspace_id,
                                command=str(body.get("command", "")),
                                cwd=str(body.get("cwd", ".")),
                                timeout_seconds=body.get("timeout_seconds"),
                                network=bool(body.get("network", False)),
                                env=body.get("env"),
                            )
                        self._json(HTTPStatus.OK, asdict(result))
                        return
                    if action == "delete":
                        body = self._read_json()
                        with application.workspace_lock(workspace_id):
                            application.store.delete_isolated(
                                workspace_id, str(body.get("confirmation", ""))
                            )
                        self._json(HTTPStatus.OK, {"deleted": workspace_id})
                        return
                    if action == "checkpoint":
                        body = self._read_json()
                        with application.workspace_lock(workspace_id):
                            metadata = application.store.checkpoint_persistent(
                                workspace_id,
                                str(body.get("confirmation", "")),
                                str(body.get("expected_patch_sha256", "")),
                            )
                        self._json(HTTPStatus.OK, asdict(metadata))
                        return
                    self._error(HTTPStatus.METHOD_NOT_ALLOWED, "method not allowed")
                except WorkspaceError as exc:
                    self._error(HTTPStatus.BAD_REQUEST, str(exc))
                except (ValueError, TypeError, json.JSONDecodeError):
                    self._error(HTTPStatus.BAD_REQUEST, "invalid request")
                except Exception:
                    logging.exception("unexpected request failure")
                    self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal server error")

            def log_message(self, format: str, *args: object) -> None:
                logging.info("%s - %s", self.address_string(), format % args)

            def _authorized(self) -> bool:
                supplied = self.headers.get("Authorization", "")
                expected = f"Bearer {application.token}"
                if not hmac.compare_digest(supplied, expected):
                    self._error(HTTPStatus.UNAUTHORIZED, "unauthorized")
                    return False
                return True

            def _content_length(self) -> int:
                raw = self.headers.get("Content-Length")
                if raw is None:
                    raise ValueError("Content-Length is required")
                length = int(raw)
                if length < 0:
                    raise ValueError("invalid Content-Length")
                return length

            def _read_json(self) -> Dict[str, Any]:
                length = self._content_length()
                if length > 1024 * 1024:
                    raise ValueError("JSON body too large")
                raw = self.rfile.read(length)
                value = json.loads(raw.decode("utf-8"))
                if not isinstance(value, dict):
                    raise ValueError("JSON body must be an object")
                return value

            def _json(self, status: HTTPStatus, value: Dict[str, Any]) -> None:
                data = json.dumps(value, ensure_ascii=False).encode("utf-8") + b"\n"
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _error(self, status: HTTPStatus, message: str) -> None:
                self._json(status, {"error": message})

        return Handler


def serve(config: Optional[BrokerConfig] = None) -> None:
    active_config = config or BrokerConfig.from_env()
    application = BrokerApplication(active_config)
    server = ThreadingHTTPServer(
        (active_config.host, active_config.port), application.handler_class()
    )
    logging.info("CodexBox broker listening on %s:%d", active_config.host, active_config.port)
    server.serve_forever()


def _read_token(path: Path) -> str:
    try:
        token = path.read_text("utf-8").strip()
    except OSError as exc:
        raise RuntimeError(f"cannot read broker token: {path}") from exc
    if len(token) < 32:
        raise RuntimeError("broker token must contain at least 32 characters")
    return token


class _LimitedReader(io.RawIOBase):
    def __init__(self, source, length: int):
        self.source = source
        self.remaining = length

    def readable(self) -> bool:
        return True

    def read(self, size: int = -1) -> bytes:
        if self.remaining <= 0:
            return b""
        if size < 0 or size > self.remaining:
            size = self.remaining
        data = self.source.read(size)
        self.remaining -= len(data)
        return data

    def readinto(self, buffer) -> int:
        data = self.read(len(buffer))
        count = len(data)
        buffer[:count] = data
        return count

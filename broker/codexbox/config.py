from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BrokerConfig:
    root: Path
    token_file: Path
    host: str = "127.0.0.1"
    port: int = 18081
    allow_network: bool = False
    max_upload_bytes: int = 256 * 1024 * 1024
    max_extract_bytes: int = 1024 * 1024 * 1024
    max_output_bytes: int = 8 * 1024 * 1024
    max_files: int = 100_000
    command_timeout_seconds: int = 600
    bwrap_path: str = "bwrap"

    @classmethod
    def from_env(cls) -> "BrokerConfig":
        return cls(
            root=Path(os.environ.get("CODEXBOX_ROOT", "/srv/codexbox")),
            token_file=Path(
                os.environ.get("CODEXBOX_TOKEN_FILE", "/etc/codexbox/token")
            ),
            host=os.environ.get("CODEXBOX_HOST", "127.0.0.1"),
            port=_env_int("CODEXBOX_PORT", 18081, 1, 65535),
            allow_network=_env_bool("CODEXBOX_ALLOW_NETWORK", False),
            max_upload_bytes=_env_int(
                "CODEXBOX_MAX_UPLOAD_BYTES", 256 * 1024 * 1024, 1, 2**31
            ),
            max_extract_bytes=_env_int(
                "CODEXBOX_MAX_EXTRACT_BYTES", 1024 * 1024 * 1024, 1, 2**34
            ),
            max_output_bytes=_env_int(
                "CODEXBOX_MAX_OUTPUT_BYTES", 8 * 1024 * 1024, 1024, 2**31
            ),
            max_files=_env_int("CODEXBOX_MAX_FILES", 100_000, 1, 1_000_000),
            command_timeout_seconds=_env_int(
                "CODEXBOX_COMMAND_TIMEOUT", 600, 1, 86_400
            ),
            bwrap_path=os.environ.get("CODEXBOX_BWRAP", "bwrap"),
        )


def _env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value

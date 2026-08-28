---
name: wsl2-bridge
description: Compatibility router for requests and older skills that refer to WSL2 Bridge, Invoke-WSLBridge, or the legacy C++/Python runners. Delegate Linux execution to the restricted codexbox-wsl skill; never use the unauthenticated TCP 18080 socat bridge or embedded sudo credentials.
---

# WSL2 Bridge compatibility router

This name is retained for older callers. Before any Linux execution, read and follow [../codexbox-wsl/SKILL.md](../codexbox-wsl/SKILL.md). CodexBox is the execution backend.

## Routing

- Use CodexBox `isolated` mode for algorithm solutions, unfamiliar repositories, one-off compilation, stress tests, and disposable experiments.
- Use CodexBox `persistent` mode only for a trusted project that intentionally needs retained Linux dependencies or build caches.
- Use the installed CodexBox client for health checks, workspace creation, execution, change export, validation, and cleanup.
- For internet research, use the platform web tool. Do not enable CodexBox network access unless broker policy permits it and the user explicitly authorizes the networked task.

## Legacy PowerShell entrypoints

The scripts in `scripts/` are compatibility adapters:

- `Invoke-WSLBridge` runs one command in a fresh CodexBox isolated workspace and then removes it.
- `Invoke-CppRun` and `Invoke-PyRun` copy only the selected source/input into a fresh isolated workspace, execute there, and remove it.
- `Invoke-WebSearch` and `Invoke-WebFetch` fail closed and direct the agent to the platform web tool.
- `-Sudo` is rejected. CodexBox task commands never receive root or the broker token.

## Prohibited fallback

Never connect to `127.0.0.1:18080`, start `socat`, invoke the old `codex-bridge` service, expose Windows drives, or reuse stored sudo passwords. If CodexBox health or sandbox checks fail, report the failure instead of falling back to a direct WSL shell.

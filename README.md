<<<<<<< HEAD
# codex-wsl
一个让wsl成为codex沙盒的skill
=======
# CodexBox WSL

CodexBox provides persistent and disposable WSL2 engineering workspaces for the Windows Codex interface. It replaces the original unauthenticated `socat` shell with a localhost-authenticated broker, an unprivileged service account, Bubblewrap command isolation, and reviewable Git change bundles.

## Modes

- `persistent`: a named Linux workspace for trusted, long-lived projects.
- `isolated`: a generated task workspace for unfamiliar code, broad automated changes, or disposable experiments.

Both modes run commands with `/workspace` as the only writable project location. Windows drives, WSL homes, broker metadata, and the broker token are masked. Network access is disabled by default.

The bootstrap installs the shared Linux foundation plus a C++ development toolchain: Git, Python 3, Bubblewrap, GCC/G++, Make, CMake, Ninja, and GDB. Project-specific dependencies still belong in an explicitly maintained environment rather than task-level sudo commands.

The Windows client starts a hidden, unprivileged `sleep infinity` WSL session on first use when the broker is offline. This keeps the dedicated distribution alive without changing the global WSL idle timeout; terminating the distribution stops the keeper as well.

## Repository layout

```text
broker/                  Python standard-library broker
client/                  Development entrypoints
guest/                   WSL bootstrap, preflight, and systemd service
host/                    WSL lifecycle and Skill installation scripts
skill/codexbox-wsl/      Self-contained Codex Skill
tests/                   Security and workflow tests
docs/architecture.md     Design and trust boundaries
```

## Safe setup sequence

1. Prepare a clean Ubuntu rootfs tar. Do not export a personal WSL distribution containing private files.
2. Review `host/Install-CodexBox.ps1` and `guest/bootstrap.sh`.
3. Run the installer interactively. It requires confirmation before importing and configuring the dedicated distribution.
4. Restart the distribution so `/etc/wsl.conf` disables Windows drive automount and Windows interop.
5. Run `guest/preflight.sh` as root and resolve every failed check.
6. Install the Skill with `host/Install-CodexBoxSkill.ps1` after reviewing its contents.

The scripts are intentionally not executed automatically by this repository. Resetting a distribution destroys its Linux filesystem and requires the exact distribution name plus interactive confirmation.

## Development verification

```powershell
python -m unittest discover -s "tests" -v
python -m compileall -q "broker"
```

PowerShell entrypoint:

```powershell
./client/codexbox.ps1 health
./client/codexbox.ps1 create -Mode Persistent -Name example -SourcePath "D:/projects/example"
./client/codexbox.ps1 create -Mode Isolated -Name task -SourcePath "D:/projects/example"
./client/codexbox.ps1 exec -WorkspaceId "i-0123456789abcdef" -Command "python -m pytest"
./client/codexbox.ps1 export -WorkspaceId "i-0123456789abcdef" -DestinationPath "D:/review/task.tar.gz"
./client/codexbox.ps1 check -BundlePath "D:/review/task.tar.gz" -ProjectPath "D:/projects/example"
```

`apply`, persistent `checkpoint`, isolated `delete`, WSL installation, and WSL reset are explicit state-changing operations. Review the exact project, bundle, or workspace ID before confirming them.

Run the complete local verification suite with:

```powershell
python -m unittest discover -s "tests" -v
./tests/test_client.ps1
./tests/test_e2e.ps1
```

See `skill/codexbox-wsl/references/` for the mode-specific workflow and security invariants.
>>>>>>> fe3d7c4 (first commit)

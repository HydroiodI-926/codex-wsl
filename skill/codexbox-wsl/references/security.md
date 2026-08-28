# Security model

CodexBox targets accidental damage, dependency pollution, and over-broad filesystem access. It is not a substitute for a separate Hyper-V VM when executing deliberately hostile kernel exploits.

The current command sandbox relies on Linux namespaces, read-only and masked mounts, an unprivileged service account, and systemd hardening. It does not install a custom seccomp filter, so use a full VM for adversarial native binaries or kernel-facing exploit research.

## Enforced boundaries

- The broker listens on localhost and requires a bearer token.
- The broker service runs as the unprivileged `codexbox` user with no sudo access.
- Commands fail if Bubblewrap is unavailable.
- `/home`, `/root`, `/mnt`, `/run`, `/srv/codexbox`, and `/etc/codexbox` are masked inside each command.
- Only the selected workspace is mounted read-write at `/workspace`.
- The broker-owned `.git` baseline is remounted read-only inside task commands.
- Network namespaces are isolated by default.
- Working directories are relative and resolved inside the workspace.
- Source archives reject absolute paths, traversal, devices, hard links, escaping symlinks, and caller-supplied `.git` metadata.
- Output and execution time are bounded. Timed-out or overflowing process groups are terminated.
- Only isolated workspaces can be deleted through the broker.
- If WSL has stopped the distribution, the Windows client starts a hidden keepalive session as the unprivileged `codexbox` account before contacting the broker.

## Trusted and untrusted configuration

Broker policy, client authentication, mode selection defaults, and network policy belong outside project-controlled files. Never let a checked-out repository modify the broker configuration or enable network access.

The client token authorizes access to the restricted broker; it is not a sudo credential. Do not commit it or echo it into task output.

## Failures

Stop and report the error when authentication, path checks, Bubblewrap startup, Git baseline creation, patch hashing, or `git apply --check` fails. Do not fall back to direct Bash, the old port 18080 bridge, full-access mode, or manual directory replacement.

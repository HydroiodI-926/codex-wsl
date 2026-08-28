# Legacy bridge design retired

The former localhost TCP 18080 + `socat` Bash design is retired and must not be restored or used as a fallback. It lacked request authentication, exposed a broad interactive shell, and embedded sudo handling in client code.

All current Linux execution is routed through the installed `codexbox-wsl` Skill and its authenticated localhost broker. CodexBox uses an unprivileged service account, Bubblewrap command isolation, masked Windows and broker paths, network-off-by-default policy, bounded commands, and reviewable change bundles.

This file remains only so old links fail safely. Follow `../SKILL.md` for the current workflow.

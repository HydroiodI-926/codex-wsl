---
name: codexbox-wsl
description: Run engineering commands in persistent or disposable WSL2 workspaces through the restricted CodexBox broker. Use for Linux builds, tests, debugging, dependency work, or isolated code changes when Windows files outside the selected project must remain inaccessible.
---

# CodexBox WSL

Use CodexBox as a Linux execution backend without exposing an unrestricted WSL shell. Commands run as an unprivileged user inside Bubblewrap and see the selected workspace as `/workspace`.

## Choose a mode

- Use **persistent** for trusted, long-lived projects whose Linux workspace should survive between tasks. Read [references/persistent.md](references/persistent.md) before creating or promoting a persistent workspace.
- Use **isolated** for unfamiliar repositories, dependency upgrades, large automated edits, or tasks that should be discarded after exporting a reviewed change bundle. Read [references/isolated.md](references/isolated.md) before creating or deleting one.

If the risk is unclear, use isolated mode.

## Essential workflow

1. Run `scripts/codexbox.ps1 health`. Stop if the broker is unavailable or reports an unexpected policy.
2. List existing workspaces before creating another one.
3. Create the selected mode from an explicit source directory. Source packaging excludes Git metadata, common credential files, dependencies, and build outputs.
4. Execute commands only through `scripts/codexbox.ps1 exec`. Keep paths relative to `/workspace`.
5. Run the relevant build, test, lint, or debugger checks in the same workspace.
6. Export a change bundle. Validate it against the intended host project with `check` before proposing application.
7. Apply a bundle only when the user explicitly requests that mutation and confirms the exact host project.
8. Advance a persistent checkpoint only from the exact reviewed bundle after it has been applied or safely archived.
9. Delete an isolated workspace only after preserving required output and confirming its exact generated ID.

## Invariants

- Never use the legacy unauthenticated `socat` Bash bridge or request WSL sudo.
- Treat network access as opt-in. `-Network` is valid only when the broker policy permits it and the user authorized the task's network use.
- Never copy an entire WSL workspace over a host project. Export and validate the generated change bundle.
- Do not expose `/mnt/c`, `/mnt/d`, Windows interop, the broker token, or another workspace to a sandboxed command.
- Fail closed when Bubblewrap, authentication, path validation, or baseline checks fail.
- Installation, WSL reset, and distro unregister operations are outside routine Skill use and require explicit user confirmation.

For threat boundaries, protected paths, and failure behavior, read [references/security.md](references/security.md).

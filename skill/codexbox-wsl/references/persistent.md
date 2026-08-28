# Persistent mode

Use persistent mode when the project is trusted, Linux-first, and likely to need repeated work across tasks.

## Workflow

1. Create the workspace once from an explicit host source directory:

   ```powershell
   ./scripts/codexbox.ps1 create -Mode Persistent -Name my-project -SourcePath "D:/projects/my-project"
   ```

2. Reuse the returned `p-my-project` ID for later commands.
3. Keep toolchains, dependency caches, and build outputs inside WSL.
4. Export a change bundle at meaningful checkpoints and before WSL maintenance.
5. Keep an external Git remote or reviewed bundles as disaster recovery. A persistent workspace must not be the only copy of irreplaceable work.

## Promotion

Run `check` against the intended host repository first. Apply only after the user requests it and the diff has been reviewed. Do not overwrite the host directory with a full archive.

After the reviewed bundle has been applied or safely archived, the user may explicitly run `checkpoint` with that bundle and the exact persistent workspace ID. The broker verifies the bundle's patch hash still matches the current workspace before advancing the internal baseline. Never checkpoint before preserving the current bundle.

Persistent workspaces cannot be deleted through the broker. Use the host maintenance scripts with explicit confirmation when lifecycle changes are required.

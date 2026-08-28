# Isolated mode

Use isolated mode for unfamiliar code, dependency changes, broad automated edits, or any task where disposal is preferable to recovery.

## Workflow

1. Create a fresh task workspace:

   ```powershell
   ./scripts/codexbox.ps1 create -Mode Isolated -Name dependency-audit -SourcePath "D:/projects/my-project"
   ```

2. Run all edits, builds, services, and tests against the returned `i-...` workspace.
3. Export a bundle and run `check` against the unchanged host project.
4. Apply only the reviewed patch when the user explicitly asks.
5. Delete the isolated workspace only after exporting anything that must survive. The delete command requires the exact workspace ID twice and an interactive confirmation.

If the host project changed after the workspace was created, do not force the patch. Create a new isolated workspace from the updated source or resolve the conflict in a reviewable host worktree.


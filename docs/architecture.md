# CodexBox architecture

CodexBox keeps the Windows Codex interface while moving Linux execution into a dedicated, replaceable WSL2 distribution.

```text
Windows Codex / Skill
        |
        | authenticated localhost HTTP
        v
CodexBox broker (unprivileged systemd service)
        |
        | validated workspace + bounded command
        v
Bubblewrap process sandbox
        |
        +-- /workspace  selected persistent or isolated workspace (rw)
        +-- /tmp        ephemeral tmpfs
        +-- /mnt        masked
        +-- /home       masked
        +-- network     isolated by default
```

## Workspace modes

`persistent` stores a named workspace under `/srv/codexbox/persistent`. It survives broker restarts and is intended for trusted, repeated work. The broker deliberately refuses to delete persistent workspaces.

`isolated` stores a generated task workspace under `/srv/codexbox/isolated`. It begins from an uploaded source snapshot, can export a Git binary patch plus manifest, and can be deleted only with an exact-ID confirmation.

Both modes create an internal Git baseline from source files after rejecting caller-supplied `.git` metadata. This makes exported patches independent of host Git configuration and prevents imported hooks or repository configuration from running in WSL.

## Trust boundaries

The bearer token prevents accidental access by unrelated localhost clients. The token does not make arbitrary commands safe; filesystem, user, namespace, timeout, output, and mode policies are enforced independently by the broker and Bubblewrap.

WSL is the replaceable outer environment. Bubblewrap is the per-command inner sandbox. A clean WSL distribution disables Windows drive automount and Windows executable interop so a broker compromise does not automatically expose the user's Windows profile.


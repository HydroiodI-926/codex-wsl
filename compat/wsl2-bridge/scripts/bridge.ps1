# Compatibility adapter: legacy WSL2 Bridge calls now use CodexBox.

function Initialize-CodexBoxCompatibility {
    if (Get-Command Test-CodexBox -ErrorAction SilentlyContinue) {
        return
    }
    $candidates = @(
        (Join-Path $PSScriptRoot "../../codexbox-wsl/scripts/CodexBox.Client.psm1"),
        (Join-Path $env:USERPROFILE ".codex/skills/codexbox-wsl/scripts/CodexBox.Client.psm1")
    )
    $modulePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $modulePath) {
        throw "The codexbox-wsl client module is not installed."
    }
    Import-Module $modulePath -Force -ErrorAction Stop
}

function global:Invoke-WSLBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 10,
        [int]$InitialWaitMs = 0,
        [int]$PostCommandWaitMs = 0,
        [switch]$Sudo,
        [switch]$RawOutput,
        [string]$SourcePath
    )

    if ($Sudo) {
        throw "Legacy -Sudo execution is disabled. CodexBox commands run without root."
    }
    Initialize-CodexBoxCompatibility

    $temporarySource = $null
    $workspaceId = $null
    try {
        if ($SourcePath) {
            $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
        } else {
            $temporarySource = Join-Path ([IO.Path]::GetTempPath()) (
                "codexbox-bridge-" + [guid]::NewGuid()
            )
            New-Item -ItemType Directory -Path $temporarySource | Out-Null
            $source = $temporarySource
        }

        $workspace = New-CodexBoxWorkspace `
            -Mode Isolated `
            -Name legacy-bridge `
            -SourcePath $source
        $workspaceId = [string]$workspace.workspace_id
        $result = Invoke-CodexBoxCommand `
            -WorkspaceId $workspaceId `
            -Command $Command `
            -TimeoutSeconds $TimeoutSec
        $global:LASTEXITCODE = [int]$result.exit_code

        $output = @([string]$result.stdout, [string]$result.stderr) `
            | Where-Object { $_ } `
            | Join-String -Separator "`n"
        if ($RawOutput) {
            return $output
        }
        return $output.TrimEnd()
    } finally {
        if ($workspaceId) {
            try {
                Remove-CodexBoxIsolatedWorkspace `
                    -WorkspaceId $workspaceId `
                    -ConfirmWorkspaceId $workspaceId `
                    -Confirm:$false | Out-Null
            } catch {
                Write-Warning "Could not remove compatibility workspace $workspaceId."
            }
        }
        if ($temporarySource) {
            Remove-Item -LiteralPath $temporarySource -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function global:Test-WSLBridge {
    try {
        Initialize-CodexBoxCompatibility
        return (Test-CodexBox).status -eq "ok"
    } catch {
        return $false
    }
}

Write-Host "[wsl2-bridge] Compatibility adapter loaded; backend: CodexBox" -ForegroundColor Green

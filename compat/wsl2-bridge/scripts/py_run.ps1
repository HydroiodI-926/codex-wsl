# Python compatibility runner backed by a disposable CodexBox workspace.

. (Join-Path $PSScriptRoot "bridge.ps1")

function global:Invoke-PyRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [string]$InputPath,
        [string]$Flags = "",
        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 30,
        [switch]$KeepFiles
    )

    if ($Flags -notmatch '^[A-Za-z0-9_=.,/: -]*$') {
        throw "Python flags contain unsupported shell characters."
    }
    $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
    $input = if ($InputPath) {
        (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
    } else {
        $null
    }
    if ($KeepFiles) {
        Write-Warning "KeepFiles is ignored; compatibility workspaces are always removed."
    }

    Initialize-CodexBoxCompatibility
    $staging = Join-Path ([IO.Path]::GetTempPath()) (
        "codexbox-python-" + [guid]::NewGuid()
    )
    $workspaceId = $null
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath $source -Destination (Join-Path $staging "solution.py")
        if ($input) {
            Copy-Item -LiteralPath $input -Destination (Join-Path $staging "input.txt")
        }
        $workspace = New-CodexBoxWorkspace `
            -Mode Isolated `
            -Name python-run `
            -SourcePath $staging
        $workspaceId = [string]$workspace.workspace_id
        $run = if ($input) {
            "python3 $Flags solution.py < input.txt"
        } else {
            "python3 $Flags solution.py"
        }
        $result = Invoke-CodexBoxCommand `
            -WorkspaceId $workspaceId `
            -Command $run `
            -TimeoutSeconds $TimeoutSec
        $global:LASTEXITCODE = [int]$result.exit_code
        if ($result.stdout) { Write-Output ([string]$result.stdout).TrimEnd() }
        if ($result.stderr) { Write-Error ([string]$result.stderr).TrimEnd() }
    } finally {
        if ($workspaceId) {
            Remove-CodexBoxIsolatedWorkspace `
                -WorkspaceId $workspaceId `
                -ConfirmWorkspaceId $workspaceId `
                -Confirm:$false | Out-Null
        }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[wsl2-bridge] Python runner loaded; backend: CodexBox" -ForegroundColor Green

# C++ compatibility runner backed by a disposable CodexBox workspace.

. (Join-Path $PSScriptRoot "bridge.ps1")

function global:Invoke-CppRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [string]$InputPath,
        [string]$Flags = "-O2 -std=c++17",
        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 15,
        [switch]$KeepFiles
    )

    if ($Flags -notmatch '^[A-Za-z0-9+_=.,/: -]+$') {
        throw "Compiler flags contain unsupported shell characters."
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
        "codexbox-cpp-" + [guid]::NewGuid()
    )
    $workspaceId = $null
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Copy-Item -LiteralPath $source -Destination (Join-Path $staging "solution.cpp")
        if ($input) {
            Copy-Item -LiteralPath $input -Destination (Join-Path $staging "input.txt")
        }
        $workspace = New-CodexBoxWorkspace `
            -Mode Isolated `
            -Name cpp-run `
            -SourcePath $staging
        $workspaceId = [string]$workspace.workspace_id
        $run = if ($input) { "./solution < input.txt" } else { "./solution" }
        $result = Invoke-CodexBoxCommand `
            -WorkspaceId $workspaceId `
            -Command "g++ $Flags -o solution solution.cpp && $run" `
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

Write-Host "[wsl2-bridge] C++ runner loaded; backend: CodexBox" -ForegroundColor Green

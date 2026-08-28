Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("codexbox-e2e-" + [guid]::NewGuid())
$data = Join-Path $temporary "data"
$source = Join-Path $temporary "source"
$tokenFile = Join-Path $temporary "token"
$configFile = Join-Path $temporary "client.json"
$stdoutLog = Join-Path $temporary "broker.stdout.log"
$stderrLog = Join-Path $temporary "broker.stderr.log"
$process = $null
New-Item -ItemType Directory -Path $data, $source | Out-Null

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$token = "e" * 64
Set-Content -LiteralPath $tokenFile -Value $token -NoNewline
@{ url = "http://127.0.0.1:$port"; token = $token } |
    ConvertTo-Json |
    Set-Content -LiteralPath $configFile -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $source "hello.txt") -Value "hello"

try {
    $process = Start-Process `
        -FilePath "python" `
        -ArgumentList @("-m", "broker.codexbox") `
        -WorkingDirectory $repoRoot `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -Environment @{
            PYTHONPATH = $repoRoot
            CODEXBOX_ROOT = $data
            CODEXBOX_TOKEN_FILE = $tokenFile
            CODEXBOX_HOST = "127.0.0.1"
            CODEXBOX_PORT = [string]$port
        }

    Import-Module (Join-Path $repoRoot "skill/codexbox-wsl/scripts/CodexBox.Client.psm1") -Force
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $health = Test-CodexBox -ConfigPath $configFile
            if ($health.status -eq "ok") {
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) {
        throw "Temporary CodexBox broker did not become ready."
    }

    $workspace = New-CodexBoxWorkspace `
        -Mode Isolated `
        -Name e2e `
        -SourcePath $source `
        -ConfigPath $configFile
    if ($workspace.workspace_id -notmatch '^i-[a-f0-9]{16}$') {
        throw "The client did not create an isolated workspace."
    }
    $workspaceFile = Join-Path $data "isolated/$($workspace.workspace_id)/hello.txt"
    Set-Content -LiteralPath $workspaceFile -Value "changed"
    $bundle = Join-Path $temporary "changes.tar.gz"
    Export-CodexBoxChanges `
        -WorkspaceId $workspace.workspace_id `
        -DestinationPath $bundle `
        -ConfigPath $configFile | Out-Null
    if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) {
        throw "The client did not export a change bundle."
    }
    $check = Test-CodexBoxChangeBundle -BundlePath $bundle -ProjectPath $source
    if (-not $check.Valid -or $check.ChangeCount -ne 1) {
        throw "The client did not validate the exported change bundle."
    }
    Update-CodexBoxProject `
        -BundlePath $bundle `
        -ProjectPath $source `
        -Confirm:$false | Out-Null
    if ((Get-Content -LiteralPath (Join-Path $source "hello.txt") -Raw).Trim() -ne "changed") {
        throw "The client did not apply the verified change bundle."
    }
    Remove-CodexBoxIsolatedWorkspace `
        -WorkspaceId $workspace.workspace_id `
        -ConfirmWorkspaceId $workspace.workspace_id `
        -ConfigPath $configFile `
        -Confirm:$false | Out-Null
    Write-Output "PowerShell-to-broker end-to-end test passed."
} catch {
    if (Test-Path -LiteralPath $stderrLog) {
        Get-Content -LiteralPath $stderrLog | Write-Host
    }
    throw
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$DistroName = "CodexBox",

    [Parameter(Mandatory)]
    [string]$RootfsPath,

    [Parameter(Mandatory)]
    [string]$InstallPath,

    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ClientConfigPath = (Join-Path $env:USERPROFILE ".codexbox/client.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rootfs = (Resolve-Path -LiteralPath $RootfsPath -ErrorAction Stop).Path
$source = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path
$install = [IO.Path]::GetFullPath($InstallPath)
$existing = @(& wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($existing -contains $DistroName) {
    throw "WSL distribution already exists: $DistroName"
}
if (Test-Path -LiteralPath $install) {
    $items = @(Get-ChildItem -LiteralPath $install -Force)
    if ($items.Count -gt 0) {
        throw "InstallPath must be empty: $install"
    }
}

if (-not $PSCmdlet.ShouldProcess($DistroName, "Import and configure dedicated CodexBox WSL distribution")) {
    return
}

New-Item -ItemType Directory -Path $install -Force | Out-Null
& wsl.exe --import $DistroName $install $rootfs --version 2
if ($LASTEXITCODE -ne 0) {
    throw "wsl --import failed for $DistroName"
}

try {
    $linuxSource = (& wsl.exe -d $DistroName -u root -- wslpath -a $source).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $linuxSource) {
        throw "Could not translate the CodexBox source path into WSL."
    }
    & wsl.exe -d $DistroName -u root -- bash "$linuxSource/guest/bootstrap.sh" $linuxSource
    if ($LASTEXITCODE -ne 0) {
        throw "CodexBox guest bootstrap failed."
    }
    $token = (& wsl.exe -d $DistroName -u root -- cat /etc/codexbox/token).Trim()
    if ($LASTEXITCODE -ne 0 -or $token.Length -lt 32) {
        throw "Could not retrieve the CodexBox broker token."
    }
    $clientPath = [IO.Path]::GetFullPath($ClientConfigPath)
    $clientDirectory = Split-Path -Parent $clientPath
    New-Item -ItemType Directory -Path $clientDirectory -Force | Out-Null
    @{
        url = "http://127.0.0.1:18081"
        token = $token
        distro = $DistroName
    } | ConvertTo-Json | Set-Content -LiteralPath $clientPath -Encoding utf8NoBOM

    & wsl.exe --terminate $DistroName
    if ($LASTEXITCODE -ne 0) {
        throw "CodexBox was installed, but WSL termination failed. Restart it manually."
    }
    [pscustomobject]@{
        DistroName = $DistroName
        InstallPath = $install
        ClientConfigPath = $clientPath
        NextStep = "Start the distro, then run /opt/codexbox/preflight.sh as root."
    }
} catch {
    Write-Warning "CodexBox installation is incomplete. The imported distribution was preserved for diagnosis."
    throw
}

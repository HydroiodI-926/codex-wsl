[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$DistroName = "CodexBox",

    [Parameter(Mandatory)]
    [string]$ConfirmDistroName,

    [Parameter(Mandatory)]
    [string]$RootfsPath,

    [Parameter(Mandatory)]
    [string]$InstallPath,

    [string]$BackupPath,
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ClientConfigPath = (Join-Path $env:USERPROFILE ".codexbox/client.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($ConfirmDistroName -cne $DistroName) {
    throw "ConfirmDistroName must exactly match DistroName."
}
$existing = @(& wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($existing -notcontains $DistroName) {
    throw "WSL distribution does not exist: $DistroName"
}
if (-not $PSCmdlet.ShouldProcess(
    $DistroName,
    "Destroy the existing WSL filesystem and recreate it from the supplied rootfs"
)) {
    return
}

if ($BackupPath) {
    & (Join-Path $PSScriptRoot "Backup-CodexBox.ps1") `
        -DistroName $DistroName `
        -DestinationPath $BackupPath
}

& wsl.exe --unregister $DistroName
if ($LASTEXITCODE -ne 0) {
    throw "Failed to unregister $DistroName."
}

& (Join-Path $PSScriptRoot "Install-CodexBox.ps1") `
    -DistroName $DistroName `
    -RootfsPath $RootfsPath `
    -InstallPath $InstallPath `
    -SourceRoot $SourceRoot `
    -ClientConfigPath $ClientConfigPath `
    -Confirm


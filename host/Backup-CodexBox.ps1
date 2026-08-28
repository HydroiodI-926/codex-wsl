[CmdletBinding()]
param(
    [string]$DistroName = "CodexBox",
    [Parameter(Mandatory)][string]$DestinationPath,
    [switch]$Vhd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$destination = [IO.Path]::GetFullPath($DestinationPath)
$parent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "Backup destination directory does not exist: $parent"
}
if (Test-Path -LiteralPath $destination) {
    throw "Backup destination already exists: $destination"
}
$arguments = @("--export", $DistroName, $destination)
if ($Vhd) {
    $arguments += "--vhd"
}
& wsl.exe @arguments
if ($LASTEXITCODE -ne 0) {
    throw "CodexBox backup failed."
}
Get-Item -LiteralPath $destination


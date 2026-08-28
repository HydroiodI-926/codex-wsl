[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) "skill/codexbox-wsl"),
    [string]$DestinationRoot = (Join-Path $env:USERPROFILE ".codex/skills")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
$root = [IO.Path]::GetFullPath($DestinationRoot)
$destination = Join-Path $root "codexbox-wsl"
if (Test-Path -LiteralPath $destination) {
    throw "Skill destination already exists: $destination"
}
if (-not $PSCmdlet.ShouldProcess($destination, "Install CodexBox WSL skill")) {
    return
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $destination -Recurse
Get-Item -LiteralPath $destination


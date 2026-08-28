[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet("health", "list", "create", "exec", "export", "check", "apply", "checkpoint", "delete")]
    [string]$Action,

    [ValidateSet("Persistent", "Isolated")]
    [string]$Mode,
    [string]$Name = "task",
    [string]$SourcePath,
    [string]$WorkspaceId,
    [string]$Command,
    [string]$WorkingDirectory = ".",
    [int]$TimeoutSeconds = 600,
    [switch]$Network,
    [string]$DestinationPath,
    [string]$BundlePath,
    [string]$ProjectPath,
    [string]$ConfirmWorkspaceId,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "CodexBox.Client.psm1") -Force

switch ($Action) {
    "health" {
        Test-CodexBox -ConfigPath $ConfigPath
    }
    "list" {
        Get-CodexBoxWorkspace -ConfigPath $ConfigPath
    }
    "create" {
        New-CodexBoxWorkspace `
            -Mode $Mode `
            -Name $Name `
            -SourcePath $SourcePath `
            -ConfigPath $ConfigPath
    }
    "exec" {
        Invoke-CodexBoxCommand `
            -WorkspaceId $WorkspaceId `
            -Command $Command `
            -WorkingDirectory $WorkingDirectory `
            -TimeoutSeconds $TimeoutSeconds `
            -Network:$Network `
            -ConfigPath $ConfigPath
    }
    "export" {
        Export-CodexBoxChanges `
            -WorkspaceId $WorkspaceId `
            -DestinationPath $DestinationPath `
            -ConfigPath $ConfigPath
    }
    "check" {
        Test-CodexBoxChangeBundle -BundlePath $BundlePath -ProjectPath $ProjectPath
    }
    "apply" {
        Update-CodexBoxProject `
            -BundlePath $BundlePath `
            -ProjectPath $ProjectPath `
            -Confirm
    }
    "delete" {
        Remove-CodexBoxIsolatedWorkspace `
            -WorkspaceId $WorkspaceId `
            -ConfirmWorkspaceId $ConfirmWorkspaceId `
            -ConfigPath $ConfigPath `
            -Confirm
    }
    "checkpoint" {
        Set-CodexBoxPersistentCheckpoint `
            -WorkspaceId $WorkspaceId `
            -ConfirmWorkspaceId $ConfirmWorkspaceId `
            -BundlePath $BundlePath `
            -ConfigPath $ConfigPath `
            -Confirm
    }
}

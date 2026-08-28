Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CodexBoxClientConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    if (-not $ConfigPath) {
        $ConfigPath = if ($env:CODEXBOX_CLIENT_CONFIG) {
            $env:CODEXBOX_CLIENT_CONFIG
        } else {
            Join-Path $env:USERPROFILE ".codexbox/client.json"
        }
    }
    $resolved = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    $config = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    if (-not $config.url -or -not $config.token) {
        throw "CodexBox client config must contain url and token."
    }
    $uri = [Uri]$config.url
    if ($uri.Scheme -ne "http" -or $uri.Host -notin @("127.0.0.1", "localhost")) {
        throw "CodexBox broker URL must use HTTP on localhost."
    }
    $distroProperty = $config.PSObject.Properties["distro"]
    $distro = if ($distroProperty) { [string]$distroProperty.Value } else { "" }
    if ($distro -and $distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "CodexBox distro name contains unsupported characters."
    }
    $result = [pscustomobject]@{
        Url = $uri.AbsoluteUri.TrimEnd("/")
        Token = [string]$config.token
        Distro = $distro
        ConfigPath = $resolved
    }
    Ensure-CodexBoxDistro -Config $result -Uri $uri
    $result
}

function Ensure-CodexBoxDistro {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][Uri]$Uri
    )

    if (-not $Config.Distro -or (Test-CodexBoxTcpEndpoint -Uri $Uri)) {
        return
    }
    $wsl = Get-Command wsl.exe -ErrorAction Stop
    Start-Process `
        -FilePath $wsl.Source `
        -ArgumentList @(
            "-d", $Config.Distro,
            "-u", "codexbox",
            "--", "/usr/bin/sleep", "infinity"
        ) `
        -WindowStyle Hidden | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        if (Test-CodexBoxTcpEndpoint -Uri $Uri) {
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "CodexBox distro started but the broker did not become reachable within 30 seconds."
}

function Test-CodexBoxTcpEndpoint {
    param([Parameter(Mandatory)][Uri]$Uri)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connection = $client.ConnectAsync($Uri.Host, $Uri.Port)
        if (-not $connection.Wait(250)) {
            return $false
        }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-CodexBox {
    [CmdletBinding()]
    param([string]$ConfigPath)

    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    Invoke-CodexBoxJsonRequest -Config $config -Method Get -Path "/v1/health"
}

function Get-CodexBoxWorkspace {
    [CmdletBinding()]
    param([string]$ConfigPath)

    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    (Invoke-CodexBoxJsonRequest -Config $config -Method Get -Path "/v1/workspaces").workspaces
}

function New-CodexBoxWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Persistent", "Isolated")]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [string]$Name = "task",
        [string]$ConfigPath,
        [string[]]$AdditionalExclude = @()
    )

    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "SourcePath must be a directory."
    }
    if ($Name -notmatch '^[a-z0-9][a-z0-9._-]{0,47}$') {
        throw "Name must match [a-z0-9][a-z0-9._-]{0,47}."
    }

    $body = @{
        mode = $Mode.ToLowerInvariant()
        name = $Name
    }
    $workspace = Invoke-CodexBoxJsonRequest `
        -Config $config `
        -Method Post `
        -Path "/v1/workspaces" `
        -Body $body

    $archive = New-CodexBoxSourceArchive `
        -SourcePath $source `
        -AdditionalExclude $AdditionalExclude
    try {
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        $headers = @{
            Authorization = "Bearer $($config.Token)"
            "X-Source-SHA256" = $hash
        }
        $uri = "$($config.Url)/v1/workspaces/$($workspace.workspace_id)/import"
        Invoke-WebRequest `
            -Uri $uri `
            -Method Post `
            -Headers $headers `
            -ContentType "application/gzip" `
            -InFile $archive | Out-Null
        Invoke-CodexBoxJsonRequest `
            -Config $config `
            -Method Get `
            -Path "/v1/workspaces" |
            Select-Object -ExpandProperty workspaces |
            Where-Object workspace_id -eq $workspace.workspace_id
    } catch {
        if ($Mode -eq "Isolated") {
            try {
                Invoke-CodexBoxJsonRequest `
                    -Config $config `
                    -Method Post `
                    -Path "/v1/workspaces/$($workspace.workspace_id)/delete" `
                    -Body @{ confirmation = $workspace.workspace_id } | Out-Null
            } catch {
                Write-Warning "Failed to clean incomplete isolated workspace $($workspace.workspace_id)."
            }
        }
        throw
    } finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CodexBoxCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId,

        [Parameter(Mandatory)]
        [string]$Command,

        [string]$WorkingDirectory = ".",
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 600,
        [switch]$Network,
        [hashtable]$Environment = @{},
        [string]$ConfigPath
    )

    Assert-CodexBoxWorkspaceId -WorkspaceId $WorkspaceId
    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    Invoke-CodexBoxJsonRequest `
        -Config $config `
        -Method Post `
        -Path "/v1/workspaces/$WorkspaceId/exec" `
        -Body @{
            command = $Command
            cwd = $WorkingDirectory
            timeout_seconds = $TimeoutSeconds
            network = [bool]$Network
            env = $Environment
        }
}

function Export-CodexBoxChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$ConfigPath
    )

    Assert-CodexBoxWorkspaceId -WorkspaceId $WorkspaceId
    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Destination directory does not exist: $parent"
    }
    $headers = @{ Authorization = "Bearer $($config.Token)" }
    Invoke-WebRequest `
        -Uri "$($config.Url)/v1/workspaces/$WorkspaceId/changes" `
        -Method Get `
        -Headers $headers `
        -OutFile $destination
    Get-Item -LiteralPath $destination
}

function Test-CodexBoxChangeBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BundlePath,

        [Parameter(Mandatory)]
        [string]$ProjectPath
    )

    Invoke-CodexBoxChangeBundle -BundlePath $BundlePath -ProjectPath $ProjectPath
}

function Update-CodexBoxProject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    param(
        [Parameter(Mandatory)]
        [string]$BundlePath,

        [Parameter(Mandatory)]
        [string]$ProjectPath
    )

    if (-not $PSCmdlet.ShouldProcess($ProjectPath, "Apply verified CodexBox changes")) {
        return
    }
    Invoke-CodexBoxChangeBundle `
        -BundlePath $BundlePath `
        -ProjectPath $ProjectPath `
        -Apply
}

function Remove-CodexBoxIsolatedWorkspace {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId,

        [Parameter(Mandatory)]
        [string]$ConfirmWorkspaceId,

        [string]$ConfigPath
    )

    if ($WorkspaceId -notmatch '^i-[a-f0-9]{16}$') {
        throw "Only isolated workspaces can be deleted through this command."
    }
    if ($ConfirmWorkspaceId -cne $WorkspaceId) {
        throw "ConfirmWorkspaceId must exactly match WorkspaceId."
    }
    if (-not $PSCmdlet.ShouldProcess($WorkspaceId, "Delete isolated CodexBox workspace")) {
        return
    }
    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    Invoke-CodexBoxJsonRequest `
        -Config $config `
        -Method Post `
        -Path "/v1/workspaces/$WorkspaceId/delete" `
        -Body @{ confirmation = $WorkspaceId }
}

function Set-CodexBoxPersistentCheckpoint {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId,

        [Parameter(Mandatory)]
        [string]$ConfirmWorkspaceId,

        [Parameter(Mandatory)]
        [string]$BundlePath,

        [string]$ConfigPath
    )

    if ($WorkspaceId -notmatch '^p-[a-z0-9][a-z0-9._-]{0,47}$') {
        throw "Only persistent workspaces support checkpoints."
    }
    if ($ConfirmWorkspaceId -cne $WorkspaceId) {
        throw "ConfirmWorkspaceId must exactly match WorkspaceId."
    }
    if (-not $PSCmdlet.ShouldProcess($WorkspaceId, "Advance the reviewed persistent baseline")) {
        return
    }
    $bundle = Get-CodexBoxBundleMetadata -BundlePath $BundlePath
    if ([string]$bundle.Manifest.workspace_id -cne $WorkspaceId) {
        throw "The reviewed bundle belongs to a different workspace."
    }
    $config = Get-CodexBoxClientConfig -ConfigPath $ConfigPath
    Invoke-CodexBoxJsonRequest `
        -Config $config `
        -Method Post `
        -Path "/v1/workspaces/$WorkspaceId/checkpoint" `
        -Body @{
            confirmation = $WorkspaceId
            expected_patch_sha256 = $bundle.PatchSha256
        }
}

function New-CodexBoxSourceArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string[]]$AdditionalExclude = @()
    )

    $tar = Get-Command tar.exe -ErrorAction Stop
    $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
    $archive = Join-Path ([IO.Path]::GetTempPath()) ("codexbox-" + [guid]::NewGuid() + ".tar.gz")
    $excludes = @(
        ".git",
        "*/.git",
        ".env",
        ".env.*",
        "*/.env",
        "*/.env.*",
        ".ssh",
        ".aws",
        ".azure",
        ".config/gcloud",
        ".docker",
        ".kube",
        ".netrc",
        ".npmrc",
        ".pypirc",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        "target",
        "dist",
        "build"
    ) + $AdditionalExclude
    $arguments = @("-czf", $archive)
    foreach ($exclude in $excludes) {
        if ($exclude -match '(^[A-Za-z]:)|(^[/\\])|\.\.') {
            throw "Exclude patterns must be relative and cannot contain '..': $exclude"
        }
        $arguments += "--exclude=$exclude"
    }
    $arguments += @("-C", $source, ".")
    & $tar.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        throw "Failed to create CodexBox source archive."
    }
    $archive
}

function Invoke-CodexBoxChangeBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BundlePath,
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [switch]$Apply
    )

    $bundle = (Resolve-Path -LiteralPath $BundlePath -ErrorAction Stop).Path
    $project = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $project -PathType Container)) {
        throw "ProjectPath must be a directory."
    }
    $git = Get-Command git.exe -ErrorAction Stop
    $tar = Get-Command tar.exe -ErrorAction Stop
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("codexbox-bundle-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        Assert-CodexBoxBundleEntries -TarPath $tar.Source -BundlePath $bundle
        & $tar.Source "-xzf" $bundle "-C" $temporary "change.patch" "manifest.json"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract CodexBox change bundle."
        }
        $unexpected = Get-ChildItem -LiteralPath $temporary -Force |
            Where-Object Name -notin @("change.patch", "manifest.json")
        if ($unexpected) {
            throw "Change bundle contains unexpected files."
        }
        $patch = Join-Path $temporary "change.patch"
        $manifestPath = Join-Path $temporary "manifest.json"
        if (-not (Test-Path -LiteralPath $patch -PathType Leaf) -or
            -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Change bundle is missing change.patch or manifest.json."
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $actualPatchHash = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualPatchHash -cne [string]$manifest.patch_sha256) {
            throw "Change bundle patch hash does not match its manifest."
        }
        foreach ($change in $manifest.changes) {
            Assert-CodexBoxRelativePath -Path ([string]$change.path)
            Assert-CodexBoxHostPath -ProjectPath $project -RelativePath ([string]$change.path)
            $targetProperty = $change.PSObject.Properties["target"]
            if ($targetProperty -and $targetProperty.Value) {
                Assert-CodexBoxRelativePath -Path ([string]$targetProperty.Value)
                Assert-CodexBoxHostPath `
                    -ProjectPath $project `
                    -RelativePath ([string]$targetProperty.Value)
            }
        }
        & $git.Source "-C" $project "apply" "--check" "--binary" "--" $patch
        if ($LASTEXITCODE -ne 0) {
            throw "The change bundle does not apply cleanly to the project."
        }
        if ($Apply) {
            & $git.Source "-C" $project "apply" "--binary" "--" $patch
            if ($LASTEXITCODE -ne 0) {
                throw "Git failed while applying the verified change bundle."
            }
        }
        [pscustomobject]@{
            Valid = $true
            Applied = [bool]$Apply
            WorkspaceId = [string]$manifest.workspace_id
            Mode = [string]$manifest.mode
            ChangeCount = @($manifest.changes).Count
            PatchSha256 = $actualPatchHash
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CodexBoxJsonRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet("Get", "Post")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body
    )

    $parameters = @{
        Uri = "$($Config.Url)$Path"
        Method = $Method
        Headers = @{ Authorization = "Bearer $($Config.Token)" }
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    Invoke-RestMethod @parameters
}

function Assert-CodexBoxWorkspaceId {
    param([Parameter(Mandatory)][string]$WorkspaceId)
    if ($WorkspaceId -notmatch '^(p-[a-z0-9][a-z0-9._-]{0,47}|i-[a-f0-9]{16})$') {
        throw "Invalid CodexBox workspace id."
    }
}

function Assert-CodexBoxRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path -or
        [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains("\") -or
        $Path.Contains([char]0) -or
        ($Path -split "/") -contains "..") {
        throw "Unsafe path in change bundle: $Path"
    }
}

function Assert-CodexBoxHostPath {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $project = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $candidate = [IO.Path]::GetFullPath((Join-Path $project $RelativePath))
    $prefix = $project + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Change path escapes the project: $RelativePath"
    }

    $parent = Split-Path -Parent $candidate
    while ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $parent = Split-Path -Parent $parent
    }
    if ($parent) {
        $resolvedParent = (Resolve-Path -LiteralPath $parent -ErrorAction Stop).Path
        if ($resolvedParent -cne $project -and
            -not $resolvedParent.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Change path traverses a link outside the project: $RelativePath"
        }
    }
}

function Get-CodexBoxBundleMetadata {
    param([Parameter(Mandatory)][string]$BundlePath)

    $bundle = (Resolve-Path -LiteralPath $BundlePath -ErrorAction Stop).Path
    $tar = Get-Command tar.exe -ErrorAction Stop
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("codexbox-metadata-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        Assert-CodexBoxBundleEntries -TarPath $tar.Source -BundlePath $bundle
        & $tar.Source "-xzf" $bundle "-C" $temporary "change.patch" "manifest.json"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract CodexBox change bundle."
        }
        $patch = Join-Path $temporary "change.patch"
        $manifestPath = Join-Path $temporary "manifest.json"
        if (-not (Test-Path -LiteralPath $patch -PathType Leaf) -or
            -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Change bundle is missing change.patch or manifest.json."
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $patchHash = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($patchHash -cne [string]$manifest.patch_sha256) {
            throw "Change bundle patch hash does not match its manifest."
        }
        [pscustomobject]@{
            Manifest = $manifest
            PatchSha256 = $patchHash
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-CodexBoxBundleEntries {
    param(
        [Parameter(Mandatory)][string]$TarPath,
        [Parameter(Mandatory)][string]$BundlePath
    )
    $entries = @(& $TarPath "-tzf" $BundlePath)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect CodexBox change bundle."
    }
    $expected = @("change.patch", "manifest.json")
    if ($entries.Count -ne $expected.Count) {
        throw "Change bundle must contain exactly change.patch and manifest.json."
    }
    if (@($entries | Sort-Object -Unique).Count -ne $expected.Count) {
        throw "Change bundle contains duplicate entries."
    }
    foreach ($entry in $entries) {
        if ($entry -notin $expected) {
            throw "Unsafe or unexpected change bundle entry: $entry"
        }
    }
}

Export-ModuleMember -Function @(
    "Get-CodexBoxClientConfig",
    "Test-CodexBox",
    "Get-CodexBoxWorkspace",
    "New-CodexBoxWorkspace",
    "Invoke-CodexBoxCommand",
    "Export-CodexBoxChanges",
    "Test-CodexBoxChangeBundle",
    "Update-CodexBoxProject",
    "Set-CodexBoxPersistentCheckpoint",
    "Remove-CodexBoxIsolatedWorkspace"
)

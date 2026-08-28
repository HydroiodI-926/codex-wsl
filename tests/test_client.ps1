Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "../skill/codexbox-wsl/scripts/CodexBox.Client.psm1"
Import-Module $modulePath -Force
$module = Get-Module CodexBox.Client
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("codexbox-client-test-" + [guid]::NewGuid())
$source = Join-Path $temporary "source"
$archive = $null
New-Item -ItemType Directory -Path $source | Out-Null

function New-TestBundle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet("Traversal", "Duplicate")][string]$Kind
    )
    $pythonSource = @'
import io
import sys
import tarfile

def add(archive, name, content):
    info = tarfile.TarInfo(name)
    info.size = len(content)
    archive.addfile(info, io.BytesIO(content))

with tarfile.open(sys.argv[1], "w:gz") as archive:
    if sys.argv[2] == "Traversal":
        add(archive, "change.patch", b"")
        add(archive, "manifest.json", b"{}")
        add(archive, "../escaped.txt", b"unsafe")
    else:
        add(archive, "change.patch", b"first")
        add(archive, "change.patch", b"second")
'@
    & python -c $pythonSource $Path $Kind
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the malicious test bundle."
    }
}

function Assert-BundleRejected {
    param([Parameter(Mandatory)][string]$Path)
    try {
        & $module {
            param($BundlePath)
            $tar = Get-Command tar.exe -ErrorAction Stop
            Assert-CodexBoxBundleEntries -TarPath $tar.Source -BundlePath $BundlePath
        } $Path
    } catch {
        return
    }
    throw "Malicious change bundle was accepted: $Path"
}

try {
    New-Item -ItemType Directory -Path (Join-Path $source ".git") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $source "node_modules") | Out-Null
    Set-Content -LiteralPath (Join-Path $source "visible.txt") -Value "visible"
    Set-Content -LiteralPath (Join-Path $source ".env") -Value "secret"
    Set-Content -LiteralPath (Join-Path $source ".git/config") -Value "git"
    Set-Content -LiteralPath (Join-Path $source "node_modules/cache.txt") -Value "cache"

    $archive = & $module {
        param($Path)
        New-CodexBoxSourceArchive -SourcePath $Path
    } $source
    $entries = @(& tar.exe -tzf $archive)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect generated source archive."
    }
    if (-not ($entries -match 'visible\.txt$')) {
        throw "Source archive is missing visible.txt."
    }
    if ($entries -match '(^|/)\.git/' -or
        $entries -match '(^|/)\.env$' -or
        $entries -match '(^|/)node_modules/') {
        throw "Source archive contains an excluded file."
    }

    $traversalBundle = Join-Path $temporary "traversal.tar.gz"
    New-TestBundle -Path $traversalBundle -Kind Traversal
    Assert-BundleRejected -Path $traversalBundle

    $duplicateBundle = Join-Path $temporary "duplicate.tar.gz"
    New-TestBundle -Path $duplicateBundle -Kind Duplicate
    Assert-BundleRejected -Path $duplicateBundle

    Write-Output "PowerShell client archive and bundle safety tests passed."
} finally {
    if ($archive -and (Test-Path -LiteralPath $archive)) {
        Remove-Item -LiteralPath $archive -Force
    }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

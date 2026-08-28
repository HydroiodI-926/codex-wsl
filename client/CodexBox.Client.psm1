$canonicalModule = Join-Path $PSScriptRoot "../skill/codexbox-wsl/scripts/CodexBox.Client.psm1"
if (-not (Test-Path -LiteralPath $canonicalModule -PathType Leaf)) {
    throw "Canonical CodexBox client module was not found: $canonicalModule"
}
. $canonicalModule


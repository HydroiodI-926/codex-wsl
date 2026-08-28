function global:Invoke-WebFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$MaxLines = 200,
        [int]$TimeoutSec = 15,
        [switch]$HeadOnly,
        [switch]$RawHtml
    )
    throw "Legacy WSL web fetch is disabled. Use the platform web open/fetch tool instead."
}

Write-Host "[wsl2-bridge] Legacy web fetch disabled; use the platform web tool" -ForegroundColor Yellow

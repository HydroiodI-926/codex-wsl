function global:Invoke-WebSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$MaxResults = 10,
        [int]$TimeoutSec = 15
    )
    throw "Legacy WSL web search is disabled. Use the platform web search tool instead."
}

Write-Host "[wsl2-bridge] Legacy web search disabled; use the platform web tool" -ForegroundColor Yellow

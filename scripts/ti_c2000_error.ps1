#requires -Version 7.0
<# Error mode: offline lookup only. Never touches a target or build. #>
[CmdletBinding()]
param(
    [string]$Code = '',
    [string]$LogPath = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')
Write-Output ('SKILL   : ti-c2000-ccs-auto@' + (Get-SkillIdentity).version)
try {
    $index = Get-Content -LiteralPath (Join-Path $root 'references/error-index.json') -Raw -Encoding utf8 | ConvertFrom-Json
    if ($LogPath) {
        if (-not (Test-Path -LiteralPath $LogPath)) { Write-Output 'USAGE: LOG_NOT_FOUND'; Write-Output 'RESULT: FAIL'; exit 2 }
        $log = Get-Content -LiteralPath $LogPath -Raw -Encoding utf8
        if (-not $Code) {
            $failures = @([regex]::Matches($log,'(?m)^(?:FAILURE|USAGE):\s*(\S+)'))
            if ($failures.Count -gt 0) { $Code = $failures[-1].Groups[1].Value }
            # A final reset wrapper may hide the GEL cause. Earlier recovered GEL errors
            # must not override a later, unrelated explicit failure.
            if ($Code -eq 'RESET_FAILED' -and $log -match 'Error -1138|Device refused to allow debug mode') { $Code = '-1138' }
            if (-not $Code) {
                $raw = @([regex]::Matches($log,'(?<!\d)(?:-1138|-1041|-150)(?!\d)'))
                if ($raw.Count -gt 0) { $Code = $raw[-1].Value }
            }
        }
    }
    if (-not $Code) { Write-Output 'USAGE: NEED_ERROR_CODE'; Write-Output 'RESULT: FAIL'; exit 2 }
    $entry = $index.errors.PSObject.Properties[$Code]
    $group = @($index.groups | Where-Object { @($_.codes) -contains $Code }) | Select-Object -First 1
    if (-not $entry -and -not $group) { Write-Output 'USAGE: ERROR_NOT_INDEXED'; Write-Output "CODE    : $Code"; Write-Output 'RESULT: FAIL'; Write-Output 'HINT    : record the original log and add an evidence-based remedy to references/error-index.json'; exit 2 }
    $category = 'validation'
    foreach ($p in $index.categories.PSObject.Properties) {
        if (@($p.Value) -contains $Code) { $category = $p.Name; break }
    }
    if (-not $entry) { $category = [string]$group.category }
    Write-Output "MODE    : Error (offline)"
    Write-Output ('CATEGORY: ' + $category)
    Write-Output "CODE    : $Code"
    Write-Output ('ACTION  : ' + $(if ($entry) { [string]$entry.Value } else { [string]$group.action }))
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Write-Output 'FAILURE: ERROR_INDEX_INVALID'
    Write-Output ('REASON: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'
    exit 1
}

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
        $log = Get-Content -LiteralPath $LogPath -Raw -Encoding utf8
        if (-not $Code) {
            # A GEL -1138 in the DSS log overrides a generic RESET_FAILED wrapper.
            foreach ($fatal in @('-1138','-1041','-150')) {
                if ($log -match [regex]::Escape($fatal)) { $Code = $fatal; break }
            }
            if (-not $Code) {
                $failures = @([regex]::Matches($log,'(?m)^FAILURE:\s*(\S+)'))
                for ($i = $failures.Count - 1; $i -ge 0; $i--) {
                    $candidate = $failures[$i].Groups[1].Value
                    if ($index.errors.PSObject.Properties[$candidate]) { $Code = $candidate; break }
                }
            }
        }
    }
    if (-not $Code) { Write-Output 'FAILURE: NEED_ERROR_CODE'; Write-Output 'RESULT: FAIL'; exit 2 }
    $entry = $index.errors.PSObject.Properties[$Code]
    if (-not $entry) { Write-Output 'FAILURE: ERROR_NOT_INDEXED'; Write-Output "CODE    : $Code"; Write-Output 'RESULT: FAIL'; exit 2 }
    Write-Output "MODE    : Error (offline)"
    Write-Output "CODE    : $Code"
    Write-Output ('ACTION  : ' + [string]$entry.Value)
    Write-Output 'RESULT: OK'
    exit 0
} catch {
    Write-Output 'FAILURE: ERROR_INDEX_INVALID'
    Write-Output ('REASON: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'
    exit 2
}

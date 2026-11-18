#requires -Version 7.0
# Every literal public code must be searchable from the offline Error mode.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
try {
    $index = Get-Content -LiteralPath (Join-Path $root 'references/error-index.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $grouped = @($index.groups | ForEach-Object { $_.codes })
    $codes = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File |
        ForEach-Object {
            $source = [IO.File]::ReadAllText($_.FullName)
            [regex]::Matches($source,'(?:USAGE|FAILURE):\s*([A-Z][A-Z_0-9]+)|\bFail\s+(?:[^\r\n]*?\s+\d+\s+)?''([A-Z][A-Z_0-9]+)''') |
                ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } }
        } | Sort-Object -Unique)
    $missing = @($codes | Where-Object { -not $index.errors.PSObject.Properties[$_] -and $grouped -notcontains $_ })
    if ($missing.Count) {
        'FAILURE: ERROR_INDEX_INCOMPLETE'
        $missing | ForEach-Object { 'VIOLATION: ' + $_ }
        'RESULT: FAIL'; exit 1
    }
    'CHECK   : {0} emitted error codes have an offline Error action' -f $codes.Count
    'RESULT: OK'; exit 0
} catch {
    'FAILURE: ERROR_INDEX_INVALID'; 'REASON: ' + $_.Exception.Message; 'RESULT: FAIL'; exit 1
}

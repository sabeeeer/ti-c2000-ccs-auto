#requires -Version 7.0
# Offline protocol test: an incomplete response or halted target must not become data.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/ti_c2000_readmode.ps1')
$project = Join-Path ([IO.Path]::GetTempPath()) ('c2000-response-' + [guid]::NewGuid().ToString('N'))
$service = Join-Path $project 'readout/.service'
try {
    New-Item -ItemType Directory -Force -Path $service | Out-Null
    foreach ($case in @(
        @{ name='complete'; reply="HALTED 0`nV gMsTick 12`nEND`n"; expected=$true },
        @{ name='missing END'; reply="HALTED 0`nV gMsTick 12`n"; expected=$false },
        @{ name='halted'; reply="HALTED 1`nV gMsTick 12`nEND`n"; expected=$false }
    )) {
        $job = Start-ThreadJob -ArgumentList @($service,$case.reply) -ScriptBlock {
            param($dir,$reply)
            $cmd = Join-Path $dir 'cmd.txt'
            $res = Join-Path $dir 'res.txt'
            $deadline = (Get-Date).AddSeconds(5)
            while (-not (Test-Path -LiteralPath $cmd) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
            if (Test-Path -LiteralPath $cmd) { [IO.File]::WriteAllText($res,$reply) }
        }
        try {
            $lines = Get-SessionExpressions -ProjectPath $project -Exprs @('gMsTick') -TimeoutMs 3000
            if (([bool]$lines) -ne [bool]$case.expected) { throw "$($case.name) was judged incorrectly: $($lines -join '|')" }
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $service 'cmd.txt') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $service 'res.txt') -Force -ErrorAction SilentlyContinue
        }
    }
    'RESULT: OK'
} catch {
    'FAILURE: TEST_FAILED'; 'REASON: ' + $_.Exception.Message; 'RESULT: FAIL'; exit 1
} finally {
    Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
}

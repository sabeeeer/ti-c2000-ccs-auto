#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-timing-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    . (Join-Path $root 'scripts/ti_c2000_readmode.ps1')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Wait-MinReadGap -ProjectPath $fixture | Out-Null
    Wait-MinReadGap -ProjectPath $fixture | Out-Null
    $sw.Stop()
    if ($sw.ElapsedMilliseconds -lt 350) { throw "read gap only $($sw.ElapsedMilliseconds) ms" }
    Mark-LoadAttemptEnd -ProjectPath $fixture
    $path = Join-Path $fixture 'readout/.service/last-load-attempt-ms.txt'
    $mark = [long]([IO.File]::ReadAllText($path))
    if ($mark -le 0) { throw 'load timestamp not recorded' }
    [IO.File]::WriteAllText($path,[string]($mark - 4700))
    $sw.Restart()
    Wait-MinLoadGap -ProjectPath $fixture | Out-Null
    $sw.Stop()
    if ($sw.ElapsedMilliseconds -lt 240) { throw "load gap only $($sw.ElapsedMilliseconds) ms" }
    $contract = Get-FwContract
    if ($contract.timing.minLoadGapMs -lt 5000 -or $contract.timing.minReadGapMs -lt 400 -or $contract.timing.minReconnectGapMs -lt 400) {
        throw 'unsafe timing contract'
    }
    Write-Output 'CHECK   : read gap >= 400 ms; load gap >= 5 s from prior attempt; reconnect minimum recorded'
    Write-Output 'RESULT: OK'; exit 0
} catch {
    Write-Output 'FAILURE: TEST_FAILED'; Write-Output ('REASON: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'; exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

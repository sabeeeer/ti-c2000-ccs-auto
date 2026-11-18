#requires -Version 7.0
# Offline timing test. The callback is synthetic; no probe or target is contacted.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/ti_c2000_probe.ps1')
$project = Join-Path ([IO.Path]::GetTempPath()) ('c2000-probe-wait-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $project | Out-Null
    $cfgDir = Join-Path $project 'targetConfigs'
    New-Item -ItemType Directory -Path $cfgDir | Out-Null
    $cfg = Join-Path $cfgDir 'target.ccxml'
    [IO.File]::WriteAllText($cfg, '<probe>A</probe>')
    $start = Get-Date
    $ready = Wait-ProbeUsable -ProjectPath $project -ProbeCheck { $true } -MaxSeconds 8 -Quiet
    if (-not $ready -or ((Get-Date) - $start).TotalSeconds -gt 2) { throw 'an already available probe was delayed' }
    $script:checks = 0
    $ready = Wait-ProbeUsable -ProjectPath $project -ProbeCheck { $script:checks++; return ($script:checks -ge 2) } -MaxSeconds 8 -Quiet
    $state = Get-ProbeWaitState -ProjectPath $project
    if (-not $ready -or $script:checks -ne 2 -or $state.okMs -lt 4900 -or $state.failMs -ne 0) {
        throw ('recovery timing was not recorded as elapsed time: ' + ($state | ConvertTo-Json -Compress))
    }
    $oldKey = $state.probe
    [IO.File]::WriteAllText($cfg, '<probe>B</probe>')
    $script:checks = 0
    $ready = Wait-ProbeUsable -ProjectPath $project -ProbeCheck { $script:checks++; return ($script:checks -ge 2) } -MaxSeconds 8 -Quiet
    $state = Get-ProbeWaitState -ProjectPath $project
    if (-not $ready -or $state.probe -eq $oldKey -or $state.okMs -lt 4900) { throw 'a changed target configuration reused the old probe timing' }

    # Simulate a 7 s DSS connect failure and a later 16 s verified connection.
    # PnP success alone must not update this separate driver-access record.
    Mark-ProbeReleased -ProjectPath $project -Ccxml $cfg
    $driver = Get-ProbeDriverState -ProjectPath $project -Ccxml $cfg
    $driver.stoppedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 7000
    Save-ProbeDriverState $driver
    Mark-ProbeDriverFailure -ProjectPath $project -Ccxml $cfg
    $driver = Get-ProbeDriverState -ProjectPath $project -Ccxml $cfg
    if ($driver.badMs -lt 6900 -or (Get-ProbeDriverTargetMs $driver) -lt 11900) { throw 'failed DSS access did not add a 5 s recovery step' }
    $driver.stoppedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 16000
    Save-ProbeDriverState $driver
    Mark-ProbeDriverSuccess -ProjectPath $project -Ccxml $cfg
    $driver = Get-ProbeDriverState -ProjectPath $project -Ccxml $cfg
    $mid = Get-ProbeDriverTargetMs $driver
    if ($driver.goodMs -lt 15900 -or $mid -le $driver.badMs -or $mid -ge $driver.goodMs) { throw 'verified DSS access did not create a bisection interval' }
    [IO.File]::WriteAllText($cfg, '<probe>C</probe>')
    $changedDriver = Get-ProbeDriverState -ProjectPath $project -Ccxml $cfg
    if ($changedDriver.badMs -ne 0 -or $changedDriver.goodMs -ne 0) { throw 'driver timing leaked to a changed probe configuration' }
    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'; 'REASON: ' + $_.Exception.Message; 'RESULT: FAIL'; exit 1
} finally {
    Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
}

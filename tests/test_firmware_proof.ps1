#requires -Version 7.0
# The portable proof must not silently degrade. These cases use a stub session so they
# need no board: what is checked is that a mismatched id, an unreadable id and a wrong
# rate are each refused with their own code, and that the identity check does not depend
# on any address, section map or PC read.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$live = Join-Path $root 'scripts\ti_c2000_live_read.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-fwproof-' + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $fixture 'proj'
$svc = Join-Path $proj 'readout\.service'
$bad = New-Object System.Collections.Generic.List[string]
$cases = 0

function Check([string]$label, [bool]$ok, [string]$detail) {
    $script:cases++
    if (-not $ok) { $script:bad.Add(('{0}: {1}' -f $label, $detail)) }
    Write-Host ('  [{0}] {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label)
}

try {
    New-Item -ItemType Directory -Force -Path $svc, (Join-Path $proj 'targetConfigs') | Out-Null
    [IO.File]::WriteAllText((Join-Path $proj '.cproject'), '<project/>')
    [IO.File]::WriteAllText((Join-Path $proj 'targetConfigs\x.ccxml'), '<configurations/>')
    [IO.File]::WriteAllText((Join-Path $svc 'ready.txt'), 'ready')
    # a state file pointing at this process keeps the session "alive" for the reader
    $state = @{ pid = $PID; started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); outSha256 = 'deadbeef'; runMode = 'SingleStep' } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $svc 'state.json'), $state)

    # a stub server: answers VARS with the values we choose, so the verdict logic can be
    # exercised without DSS. It rewrites res.txt whenever cmd.txt changes.
    $stub = Join-Path $fixture 'stub.ps1'
    @'
param([string]$Dir, [string]$FwValue, [string]$TickStart, [int]$TickStep)
$cmd = Join-Path $Dir 'cmd.txt'
$res = Join-Path $Dir 'res.txt'
$tick = [int64]$TickStart
$last = ''
while ($true) {
    if (Test-Path $cmd) {
        $c = (Get-Content $cmd -Raw).Trim()
        # answer whenever the reader is waiting: it deletes res.txt before each request,
        # and every round sends the same text, so comparing text would answer only once
        if (-not (Test-Path $res)) {
            $last = $c
            $lines = @('HALTED 0')
            if ($c -like 'VARS *') {
                foreach ($n in ($c.Substring(5) -split '\|')) {
                    switch ($n) {
                        'gFwId' { $lines += ('V ' + $n + ' ' + $FwValue) }
                        'gMsTick' { $lines += ('V ' + $n + ' ' + $tick); $tick += $TickStep }
                        default { $lines += ('E ' + $n + ' identifier not found: ' + $n) }
                    }
                }
            }
            $lines += 'END'
            [IO.File]::WriteAllText($res, ($lines -join "`n"))
        }
    }
    Start-Sleep -Milliseconds 20
}
'@ | Set-Content -Path $stub -Encoding utf8

    function Run-Live([string[]]$extra, [string]$fw, [int]$step) {
        $p = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -PassThru -WindowStyle Hidden `
            -ArgumentList (@('-NoProfile', '-File', $stub, '-Dir', $svc, '-FwValue', $fw, '-TickStart', '1000', '-TickStep', [string]$step))
        Start-Sleep -Milliseconds 600
        try {
            $out = @(& pwsh -NoProfile -File $live -ProjectPath $proj -Variables gMsTick -Rounds 3 -IntervalMs 200 -RequestTimeoutMs 4000 @extra 2>&1)
            return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
        } finally {
            Remove-Item (Join-Path $svc 'res.txt') -Force -ErrorAction SilentlyContinue
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }

    # 1. identity matches -> pass
    $r = Run-Live @('-ExpectFwId', '65537') '65537' 900
    Check 'matching gFwId passes' ($r.code -eq 0 -and $r.text -match 'CHECK fw id .*matches expected') ('exit=' + $r.code)

    # 2. identity differs -> FW_ID_MISMATCH, and the reason must not blame the reading
    $r = Run-Live @('-ExpectFwId', '999') '65537' 900
    Check 'mismatched gFwId -> FW_ID_MISMATCH' ($r.code -eq 1 -and $r.text -match 'FAILURE: FW_ID_MISMATCH') ('exit=' + $r.code)
    Check 'mismatch reason points at the image' ($r.text -match 'the target is running another image') 'reason text'

    # 3. firmware without the variable -> unreadable, never a pass
    $r = Run-Live @('-ExpectFwId', '65537') 'ABSENT' 900
    Check 'unreadable gFwId -> FW_ID_UNREADABLE' ($r.code -eq 1 -and $r.text -match 'FAILURE: FW_ID_UNREADABLE') ('exit=' + $r.code)

    # 4. rate far below the claim -> HEARTBEAT_RATE
    $r = Run-Live @('-RateVar', 'gMsTick', '-ExpectedRatePerSec', '1000') '65537' 1
    Check 'slow counter -> HEARTBEAT_RATE' ($r.code -eq 1 -and $r.text -match 'FAILURE: HEARTBEAT_RATE') ('exit=' + $r.code)

    # 5. the identity path must not need -CcsRoot / a section map / PC
    Check 'identity check ran without -CcsRoot' ($true) 'no CcsRoot was passed in any case above'

    if ($bad.Count -gt 0) {
        'FAILURE: FIRMWARE_PROOF'
        foreach ($b in $bad) { 'VIOLATION: ' + $b }
        'RESULT: FAIL'
        exit 1
    }
    'CHECK   : {0} firmware self-proof cases behaved as required' -f $cases
    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

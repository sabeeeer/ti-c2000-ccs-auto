#requires -Version 7.0
# PREFLIGHT must refuse BEFORE any data exists. The cases here fail on purpose and check
# that (a) the run stops, (b) no data.csv survives, and (c) verdict.txt says FAIL.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$read = Join-Path $root 'scripts\ti_c2000_run_read.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-preflight-' + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $fixture 'proj'
$svc = Join-Path $proj 'readout\.service'
$data = Join-Path $proj 'readout\data'
$check = Join-Path $proj 'readout\check'
$bad = New-Object System.Collections.Generic.List[string]
$cases = 0

function Check([string]$label, [bool]$ok, [string]$detail) {
    $script:cases++
    if (-not $ok) { $script:bad.Add(('{0}: {1}' -f $label, $detail)) }
    Write-Host ('  [{0}] {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label)
    if (-not $ok) { Write-Host ('      ' + $detail) }
}
function Reset-Stale {
    [IO.File]::WriteAllText((Join-Path $data 'data.csv'), "round,hostMs,hostTime,gMsTick`n1,0,00:00,1`n")
    [IO.File]::WriteAllText((Join-Path $check 'verdict.txt'), "result: OK`n")
    [IO.File]::WriteAllText((Join-Path $check 'variables.csv'), "role,name,first,last,delta,status`n")
}

try {
    New-Item -ItemType Directory -Force -Path $svc, $data, $check, (Join-Path $proj 'targetConfigs'), (Join-Path $proj 'Debug') | Out-Null
    [IO.File]::WriteAllText((Join-Path $proj '.cproject'), '<project/>')
    [IO.File]::WriteAllText((Join-Path $proj 'targetConfigs\x.ccxml'), '<configurations/>')

    # the reader compares sha256(.out) with the session record first
    $outFile = Join-Path $proj 'Debug\proj.out'
    [IO.File]::WriteAllBytes($outFile, [byte[]](1..64))
    $sha = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash

    # the session says it loaded firmware 65537; each case makes the stub answer something
    # different, which is exactly "the board is running another build"
    $state = @{ pid = $PID; started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); outSha256 = $sha; out = $outFile; runMode = 'SingleStep'; loadIndex = 3; fwId = '65537' } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $svc 'state.json'), $state)
    [IO.File]::WriteAllText((Join-Path $svc 'ready.txt'), 'ready')

    $stub = Join-Path $fixture 'stub.ps1'
    @'
param([string]$Dir, [string]$Fw, [int]$Step)
$cmd = Join-Path $Dir 'cmd.txt'
$res = Join-Path $Dir 'res.txt'
$tick = 1000
$first = $true
while ($true) {
    if ($first) { [IO.File]::WriteAllText((Join-Path $Dir 'stub-ready.txt'), 'up'); $first = $false }
    if (Test-Path $cmd) {
        $c = (Get-Content $cmd -Raw).Trim()
        if (-not (Test-Path $res)) {
            $lines = @('HALTED 0')
            if ($c -like 'VARS *') {
                foreach ($n in ($c.Substring(5) -split '\|')) {
                    switch ($n) {
                        'gFwId' { $lines += ('V gFwId ' + $Fw) }
                        'gMsTick' { $lines += ('V gMsTick ' + $tick); $tick += $Step }
                        'PC' { $lines += 'V PC 32972' }
                        default { $lines += ('E ' + $n + ' identifier not found: ' + $n) }
                    }
                }
            }
            $lines += 'END'
            [IO.File]::WriteAllText($res, ($lines -join "`n"))
            # The real service consumes the command after answering. Without this the stub
            # keeps answering the SAME cmd.txt every 20 ms, so once the client clears res.txt
            # for its next request it immediately reads the PREVIOUS answer - and the preflight
            # check sees a stale value (2026-11-15: gFwId read as empty for that reason).
            Remove-Item -LiteralPath $cmd -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 20
}
'@ | Set-Content -Path $stub -Encoding utf8

    function Run-Read([string]$fw, [int]$step) {
        $p = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -PassThru -WindowStyle Hidden `
            -ArgumentList (@('-NoProfile', '-File', $stub, '-Dir', $svc, '-Fw', $fw, '-Step', [string]$step))
        $ready = Join-Path $svc 'stub-ready.txt'
        if (Test-Path $ready) { Remove-Item $ready -Force -ErrorAction SilentlyContinue }
        $waited = 0
        while (-not (Test-Path $ready) -and $waited -lt 8000) { Start-Sleep -Milliseconds 100; $waited += 100 }
        # The stub writes its marker from inside the serving loop, but the first request
        # still needs a moment to land on a polling cycle; 250 ms was occasionally short
        # and run_read then reported TARGET_NOT_CONNECTED before PREFLIGHT even printed.
        Start-Sleep -Milliseconds 600
        try {
            $argv = @('-NoProfile', '-File', $read, '-ProjectPath', $proj, '-Variables', 'gMsTick',
                '-Mode', 'ReadOnly', '-Rounds', '2', '-IntervalMs', '200', '-NoProbeCheck')
            $out = @(& pwsh @argv 2>&1)
            return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
        } finally {
            # kill first, then clear: a stub still running would answer the next case's
            # requests with the previous firmware value
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            try { $p.WaitForExit(2000) | Out-Null } catch { }
            foreach ($n in @('res.txt', 'cmd.txt', 'stub-ready.txt')) {
                Remove-Item (Join-Path $svc $n) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 1. firmware identity differs from what the session loaded -> refuse, clear stale data
    Reset-Stale
    $r = Run-Read '999' 900
    Check 'different firmware -> PREFLIGHT_FAILED' ($r.code -eq 4 -and $r.text -match 'FAILURE: PREFLIGHT_FAILED') ('exit=' + $r.code + ' text=' + ($r.text -replace "`n", ' | '))
    Check 'reason names the identity' ($r.text -match 'ANOTHER BUILD') ('text=' + ($r.text -replace "`n", ' | '))
    Check 'stale data.csv removed' (-not (Test-Path (Join-Path $data 'data.csv'))) 'data.csv survived a refusal'
    $v = Get-Content (Join-Path $check 'verdict.txt') -Raw
    Check 'verdict overwritten with FAIL' ($v -match 'result: FAIL' -and $v -notmatch 'result: OK') ('verdict=' + ($v -replace "`n", ' | '))

    # 2. counter frozen -> refuse before reading
    Reset-Stale
    $r = Run-Read '65537' 0
    Check 'frozen counter -> PREFLIGHT_FAILED' ($r.code -eq 4 -and $r.text -match 'not advancing') ('exit=' + $r.code + ' text=' + ($r.text -replace "`n", ' | '))
    Check 'no data written for a frozen program' (-not (Test-Path (Join-Path $data 'data.csv'))) 'data.csv written'

    # 3. identity matches and counter advances -> the read proceeds
    Reset-Stale
    $r = Run-Read '65537' 900
    Check 'matching identity + advancing -> reads' ($r.text -match 'PREFLIGHT: all conditions hold') ('exit=' + $r.code + ' text=' + ($r.text -replace "`n", ' | '))
    Check 'PREFLIGHT reports location' ($r.text -match 'LOCATION : ') 'no LOCATION line'
    Check 'PREFLIGHT reports LOADS' ($r.text -match 'LOADS    : #') 'no LOADS line'
    Check 'PREFLIGHT reports identity' ($r.text -match 'IMAGE    : gFwId = 65537') 'no IMAGE line'

    # One automatic re-run. Each case drives an external stub process over files in %TEMP%,
    # and on this machine such a request is occasionally lost to process-startup jitter
    # (measured 2026-11-15: "no IMAGE line" in roughly 1 run out of 4, always the first
    # case). A genuine regression fails both attempts, so the retry keeps the signal while
    # removing the noise. The child is a separate process: exit inside it must not kill
    # the parent's reporting path.
    if ($bad.Count -gt 0 -and -not $env:TI_C2000_TEST_RETRY) {
        Write-Host '  -- retrying once (external-stub jitter, not a verdict) --'
        $env:TI_C2000_TEST_RETRY = '1'
        try {
            & pwsh -NoProfile -File $PSCommandPath
            exit $LASTEXITCODE
        } finally {
            Remove-Item Env:TI_C2000_TEST_RETRY -ErrorAction SilentlyContinue
        }
    }

    if ($bad.Count -gt 0) {
        'FAILURE: PREFLIGHT_TEST'
        foreach ($b in $bad) { 'VIOLATION: ' + $b }
        'RESULT: FAIL'
        exit 1
    }
    'CHECK   : {0} preflight cases behaved as required' -f $cases
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

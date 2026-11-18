#requires -Version 7.0
<#
ti_c2000_live_read.ps1 -- read a running target without touching it.

Attaches to the service started by ti_c2000_service.ps1 and asks it for values.
Nothing is reset, reloaded or halted here: the session that loaded the RAM image
is still open, the target is still running, so every read describes the same
program. That is the whole point -- a reader that reconnects and reloads makes
two consecutive reads describe two different runs.

Protocol (files in <project>\readout\.service):
  request  cmd.txt : "VARS a|b|c" | "ARRAY name|rows|cols" | "PING" | "STOP"
  response res.txt : HALTED 0|1, "V <name> <value>", "A <index> <value>",
                     "E <message>", then END

Verdict: heartbeat must advance across rounds, the frozen window must not change
while it is being copied, and the service must still hold the same .out (its
sha256 is stored when the session loaded it). The startup-window check of the
one-shot readers is NOT applied here: a long-running session legitimately has a
large tick value.

Exit code: 0 OK | 1 verdict/read failure | 2 environment/argument problem
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [string[]]$Variables = @(),
    [string]$ArrayName = '',
    [int]$Rows = 1,
    [int]$Columns = 1,
    [string]$FrozenFlag = 'gDmaReady',
    [string]$FrozenValue = 'true',
    [string]$SeqVar = 'gDmaSeq',
    [switch]$LatestFrame,
    [string]$BankVar = '',
    [string]$Bank0Array = '',
    [string]$Bank1Array = '',
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    # ---- firmware self-proof: the portable way to ask "is this image running?" ----
    # A number the firmware owns (gFwId) plus the rate of a counter it increments.
    # Nothing here depends on the device's memory map, the boot configuration or the
    # probe model: one memory read answers all of it, so it survives a different part,
    # a different linker layout and a different debugger.
    [string]$FwIdVar = 'gFwId',
    [Nullable[double]]$ExpectFwId = $null,
    [string]$RateVar = '',
    [double]$ExpectedRatePerSec = 0,
    [double]$RateTolerancePct = 20,
    [int]$Rounds = 10,
    [int]$IntervalMs = 500,
    [int]$RequestTimeoutMs = 15000,
    [int]$WaitMs = 10000,
    [Nullable[double]]$ValueMin = $null,
    [Nullable[double]]$ValueMax = $null,
    [string]$PreflightIssues = '',
    [switch]$NoHeartbeat,
    # This protocol client is internal; the public readers hold the project lock and
    # complete the probe/image preflight before they launch it.
    [int]$ParentPid = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')

# Compare a firmware flag with the value the caller expects. In C "true" and 1 are the same
# statement and a flag may surface either way, so normalise both spellings instead of
# string-comparing them. An empty expectation means "do not check equality", which is what
# -FrozenValue "" asks for.
#
# This must be defined before the frozen-window check that calls it: an earlier edit added
# the call but not the function, so -FrozenBufferReady failed with "Test-FlagEquals is not
# recognized" on the board (2026-11-15).
function Test-FlagEquals {
    param([string]$Actual, [string]$Expected)
    $a = ([string]$Actual).Trim()
    $e = ([string]$Expected).Trim()
    if (-not $e) { return $true }
    if ($a -ieq $e) { return $true }
    $truthy = @('true', '1')
    $falsy = @('false', '0')
    $al = $a.ToLower()
    $el = $e.ToLower()
    $an = if ($truthy -contains $al) { 'T' } elseif ($falsy -contains $al) { 'F' } else { $al }
    $en = if ($truthy -contains $el) { 'T' } elseif ($falsy -contains $el) { 'F' } else { $el }
    if ($an -eq $en) { return $true }
    $na = 0.0; $ne = 0.0
    if ([double]::TryParse($a, [ref]$na) -and [double]::TryParse($e, [ref]$ne)) { return ($na -eq $ne) }
    return $false
}

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 'USAGE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$owner = Get-TargetLockInfo -ProjectPath $ProjectPath
if ($ParentPid -le 0 -or -not $owner -or $owner.pid -ne $ParentPid -or $owner.mode -ne 'ReadOnly' -or
    -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
    Out2 'USAGE: INTERNAL_ONLY'; Out2 'RESULT: FAIL'
    Out2 'REASON: use ti_c2000_run_read.ps1 or ti_c2000_read_dma.ps1; their preflight owns the ReadOnly lock'
    exit 2
}
$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0 -and -not $ArrayName -and -not $LatestFrame) {
    Out2 'USAGE: NEED_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: pass -Variables or -ArrayName'; exit 2
}
if ($names.Count -gt 0 -and ($ArrayName -or $LatestFrame)) {
    Out2 'USAGE: AMBIGUOUS_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use -Variables or -ArrayName, not both'; exit 2
}
if ($LatestFrame -and (-not $SeqVar -or -not $BankVar -or -not $Bank0Array -or -not $Bank1Array)) {
    Out2 'USAGE: INVALID_LATEST_FRAME'; Out2 'RESULT: FAIL'
    Out2 'REASON: a ping-pong latest-frame read needs sequence, completed-bank selector and both array symbols'; exit 2
}
if ($ArrayName -and -not $LatestFrame -and -not $FrozenValue.Trim()) {
    Out2 'USAGE: FROZEN_VALUE_REQUIRED'; Out2 'RESULT: FAIL'
    Out2 'REASON: a frozen array requires an explicit completed flag value'; exit 2
}
if ($NoHeartbeat) {
    Out2 'USAGE: READ_PROOF_BYPASS'; Out2 'RESULT: FAIL'
    Out2 'REASON: a trusted live read requires a heartbeat'; exit 2
}
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# the rate variable is read the same way as a heartbeat (own tolerant request), so the
# counter the caller wants timed does not have to appear in -Variables as well
if ($RateVar -and $heartbeats -notcontains $RateVar) { $heartbeats += $RateVar }
if ($env:TI_C2000_DEBUG_HEARTBEAT) { [IO.File]::AppendAllText((Join-Path $env:TEMP 'c2000-fw-dbg.log'), ('HEARTBEATS hb=[' + ($heartbeats -join ',') + '] names=[' + ($names -join ',') + '] expect=[' + $ExpectFwId + ']' + [Environment]::NewLine)) }

$svcDir = Join-Path $ProjectPath 'readout\.service'
$stateFile = Join-Path $svcDir 'state.json'
$readyFile = Join-Path $svcDir 'ready.txt'
$cmdFile = Join-Path $svcDir 'cmd.txt'
$resFile = Join-Path $svcDir 'res.txt'

function Get-ServiceState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

$state = Get-ServiceState
$alive = $false
if ($state -and (Test-Path -LiteralPath $readyFile)) {
    $alive = [bool](Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)
}
if (-not $alive) {
    Out2 'FAILURE: NO_SERVICE'; Out2 'RESULT: FAIL'
    Out2 ('REASON: no running session for this project - start it once with: pwsh -File ti_c2000_service.ps1 -ProjectPath "{0}" -Start' -f $ProjectPath)
    exit 4
}
$svcPid = [int]$state.pid

# the session may still hold an image that was replaced on disk since it started.
# Guard the field itself: a state.json written by an older version (or trimmed by hand)
# may have no "out", and Test-Path -LiteralPath $null throws a parameter-binding error that
# would abort the read for a purely bookkeeping reason (measured 2026-11-15).
if ($state.out -and (Test-Path -LiteralPath $state.out)) {
    $nowSha = (Get-FileHash -LiteralPath $state.out -Algorithm SHA256).Hash
    if ($nowSha -ne $state.outSha256) {
        $shaIssue = (Split-Path -Leaf $state.out) + ' changed after this session loaded it'
        $PreflightIssues = (@($PreflightIssues, $shaIssue) | Where-Object { $_ }) -join ' | '
    }
}

function Send-Request([string]$Text, [int]$TimeoutMs) {
    # Clear the previous reply, and prove it is gone. A single Remove-Item with
    # -ErrorAction SilentlyContinue can leave the old res.txt in place (a scanner or the
    # service still holding the handle), and then the wait below returns the PREVIOUS
    # response - the caller parses a stale answer and reports a bogus result while the
    # request was never sent. Retry, and treat "cannot clear" as a timeout instead.
    for ($c = 0; $c -lt 10 -and (Test-Path -LiteralPath $resFile); $c++) {
        Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $resFile)) { break }
        Start-Sleep -Milliseconds 30
    }
    if (Test-Path -LiteralPath $resFile) { return $null }
    Wait-MinReadGap -ProjectPath $ProjectPath
    # Write the request through a temp file and rename: the service polls cmd.txt with
    # readText(), and a direct WriteAllText truncates it first, so the service can read an
    # empty or half-written command and answer "E unknown command" - which the caller then
    # reports as VALUE_READ_FAILED on perfectly good data. The service already writes its
    # replies atomically; this makes the other direction symmetric.
    $tmpCmd = $cmdFile + '.tmp'
    [IO.File]::WriteAllText($tmpCmd, $Text, [Text.Encoding]::ASCII)
    try { Move-Item -LiteralPath $tmpCmd -Destination $cmdFile -Force -ErrorAction Stop }
    catch {
        [IO.File]::WriteAllText($cmdFile, $Text, [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $tmpCmd -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resFile) { return (Get-Content -LiteralPath $resFile -Raw) }
        if (-not (Get-Process -Id $svcPid -ErrorAction SilentlyContinue)) { return $null }
        Start-Sleep -Milliseconds 40
    }
    return $null
}
function ConvertFrom-Response([string]$raw) {
    # arr must be a plain hashtable, NOT [ordered]@{}: OrderedDictionary exposes both an
    # [object key] and an [int index] overload, so `$arr[[int]$n] = v` silently takes the
    # positional one and throws "index out of range" for every sample. That dropped all
    # 400 values and surfaced as COUNT_MISMATCH "got 0 values, expected 400" (2026-11-15).
    $o = [ordered]@{ halted = $false; statusCount = 0; end = $false; endCount = 0; vars = [ordered]@{}; arr = @{}; errors = @() }
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^HALTED ([01])\s*$') { $o.halted = ($Matches[1] -eq '1'); $o.statusCount++ }
        elseif ($line -match '^V (\S+) (.*)$') { $o.vars[$Matches[1]] = $Matches[2].Trim() }
        elseif ($line -match '^A (\d+) (\S+)\s*$') { $o.arr[[int]$Matches[1]] = $Matches[2] }
        elseif ($line -match '^E (.*)$') { $o.errors += $Matches[1] }
        elseif ($line -match '^END\s*$') { $o.end = $true; $o.endCount++ }
    }
    return $o
}
function Request([string]$Text) {
    $raw = Send-Request $Text $RequestTimeoutMs
    if ($null -eq $raw) {
        Out2 'FAILURE: SERVICE_TIMEOUT'; Out2 'RESULT: FAIL'
        Out2 ('REASON: no response within {0} ms - is the target still running? see {1}' -f $RequestTimeoutMs, (Join-Path $svcDir 'server.log'))
        exit 1
    }
    $r = ConvertFrom-Response $raw
    if ($r.statusCount -ne 1 -or $r.endCount -ne 1) {
        Out2 'FAILURE: SERVICE_PROTOCOL'; Out2 'RESULT: FAIL'
        Out2 'REASON: response must contain one HALTED status and one END marker'; exit 1
    }
    if ($r.halted) {
        Out2 'FAILURE: TARGET_HALTED_DURING_READ'; Out2 'RESULT: FAIL'
        Out2 'REASON: the target is halted, so its RAM is not a running state'; exit 1
    }
    if ($r.errors.Count -gt 0) {
        Out2 'FAILURE: VALUE_READ_FAILED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: ' + ($r.errors -join '; '))
        $all = ($r.errors -join ' ')
        if ($all -match "member '([^']+)' not found") {
            Out2 ('HINT    : member ' + $Matches[1] + ' was not found; check the selected device header and register field path')
        } elseif ($all -match 'identifier not found') {
            Out2 'HINT    : identifier not found - check the exact spelling against the .map of THIS build; a renamed, static or optimised-out symbol looks the same'
        }
        exit 1
    }
    return $r
}

<#
Request-Soft -- same exchange, but "identifier not found" is an acceptable answer.
It exists for the liveness candidates only: a build that does not define gRunMs is
normal (documented), and asking for it must not fail the user's read. A hard failure
(timeout, no END, halted target) still returns $null, which the caller reports as an
unverifiable heartbeat rather than a read error.
#>
function Request-Soft([string]$Text) {
    $raw = Send-Request $Text $RequestTimeoutMs
    if ($null -eq $raw) { return $null }
    $r = ConvertFrom-Response $raw
    if ($r.statusCount -ne 1 -or $r.endCount -ne 1) { return $null }
    if ($r.halted) { return $null }
    return $r
}

$dataDir = Join-Path $ProjectPath 'readout\data'
$checkDir = Join-Path $ProjectPath 'readout\check'
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
New-Item -ItemType Directory -Path $checkDir -Force | Out-Null
foreach ($old in @((Join-Path $dataDir 'data.csv'),(Join-Path $dataDir 'array.csv'),(Join-Path $checkDir 'verdict.txt'))) {
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
}
$utf8Bom = New-Object Text.UTF8Encoding($true)
$verdictScript = Join-Path $PSScriptRoot 'ti_c2000_check_read.ps1'
if (-not (Test-Path -LiteralPath $verdictScript)) {
    Out2 'FAILURE: ENV_NO_VERDICT_SCRIPT'; Out2 'RESULT: FAIL'
    Out2 'REASON: mandatory CSV verdict script is missing'; exit 1
}
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

Info2 "PROJECT : $ProjectPath"
Info2 ('SERVICE : pid {0}, loaded {1}' -f $svcPid, $state.started)
Info2 'MODE    : ReadOnly attach - this process never downloads'
. (Join-Path $PSScriptRoot 'ti_c2000_loadcount.ps1')
$loadIdx = $state.loadIndex
if (-not $loadIdx) {
    $cn = Get-LoadCount -ProjectPath $ProjectPath
    if ($state.outSha256 -and $state.outSha256 -eq $cn.lastSha256) { $loadIdx = $cn.count }
}
Info2 ('LOAD    : #{0} (this session), reads never download' -f $(if ($loadIdx) { $loadIdx } else { '?' }))
Info2 ('OUT     : {0}' -f $state.out)

# ---------------------------------------------------------------- array ------
if ($ArrayName -or $LatestFrame) {
    $total = $Rows * $Columns
    $softFail = New-Object System.Collections.Generic.List[string]
    if ($PreflightIssues) { $softFail.Add($PreflightIssues) }
    $fwBeforeValue = ''
    if ($FwIdVar) {
        $fwBefore = Request-Soft ('VARS ' + $FwIdVar)
        if ($fwBefore -and $fwBefore.errors.Count -eq 0) { $fwBeforeValue = [string]$fwBefore.vars[$FwIdVar] }
    }
    if (-not $fwBeforeValue -or $null -eq $ExpectFwId) {
        $softFail.Add('firmware identity was not proven before the array copy')
    } elseif (-not (Test-FlagEquals $fwBeforeValue ([string]$ExpectFwId))) {
        $softFail.Add(('firmware identity before copy was {0}, expected {1}' -f $fwBeforeValue,$ExpectFwId))
    }
    if (-not $LatestFrame -and $FrozenFlag) {
        $probe = Request-Soft ('VARS ' + $FrozenFlag)
        if (-not $probe -or $probe.errors.Count -gt 0 -or -not $probe.vars.Contains($FrozenFlag)) {
            $softFail.Add(('{0} was not readable before the array copy; the array will be returned without freeze proof' -f $FrozenFlag))
        }
    }
    if ($LatestFrame) {
        $pre = Request-Soft ('VARS ' + $SeqVar + '|' + $BankVar)
    } else {
        $deadline = (Get-Date).AddMilliseconds($WaitMs)
        do {
            $pre = Request-Soft (('VARS ' + $FrozenFlag + '|' + $SeqVar).Trim('|'))
            if (-not $pre -or $pre.errors.Count -gt 0) { break }
            if (Test-FlagEquals ([string]$pre.vars[$FrozenFlag]) $FrozenValue) { break }
        } while ((Get-Date) -lt $deadline)
        if (-not $pre -or -not (Test-FlagEquals ([string]$pre.vars[$FrozenFlag]) $FrozenValue)) {
            $softFail.Add(('{0} did not reach {1} within {2} ms' -f $FrozenFlag,$FrozenValue,$WaitMs))
        }
    }
    if (-not $pre) { $pre = [pscustomobject]@{ vars = [ordered]@{}; errors = @('no evidence response') } }
    if ($pre.errors.Count -gt 0) { $softFail.Add(('pre-copy evidence read failed: ' + ($pre.errors -join '; '))) }
    $preBank = if ($LatestFrame) { [string]$pre.vars[$BankVar] } else { '' }
    if ($LatestFrame) {
        if ($preBank -eq '0') { $ArrayName = $Bank0Array }
        elseif ($preBank -eq '1') { $ArrayName = $Bank1Array }
        else {
            $ArrayName = $Bank0Array
            $softFail.Add(('{0} did not identify completed bank 0 or 1; bank 0 was copied for diagnosis' -f $BankVar))
        }
    }
    $arr = Request ('ARRAY ' + $ArrayName + '|' + $Rows + '|' + $Columns)
    $post = if ($LatestFrame) { Request-Soft ('VARS ' + $SeqVar + '|' + $BankVar) }
            else { Request-Soft (('VARS ' + $FrozenFlag + '|' + $SeqVar).Trim('|')) }
    if (-not $post) { $post = [pscustomobject]@{ vars = [ordered]@{}; errors = @('no evidence response') } }
    if ($post.errors.Count -gt 0) { $softFail.Add(('post-copy evidence read failed: ' + ($post.errors -join '; '))) }

    $preFlag = [string]$pre.vars[$FrozenFlag]
    $postFlag = [string]$post.vars[$FrozenFlag]

    # Data judgements no longer abort the read. The samples are already in memory, so
    # withholding them helps nobody: the caller gets array.csv plus a verdict naming what
    # is wrong. Only "there are no samples" (probe/timeout/protocol) still stops earlier.
    # The expected value was declared and documented but never read: a flag that sits at 0
    # does not change while the window is copied, so "did it change?" passed on a buffer
    # that was never frozen and the copy could mix old and new samples. Equality is what
    # proves "frozen"; stability alone only proves "constant" (found 2026-11-15 by
    # tools/audit_dead_params.ps1).
    if (-not $LatestFrame -and $FrozenFlag -and -not (Test-FlagEquals $preFlag $FrozenValue)) {
        Out2 ('CHECK frozen: FAILED - {0} = {1}, expected {2}' -f $FrozenFlag, $preFlag, $FrozenValue)
        $softFail.Add(('{0} = {1}, expected {2}: the copy is not from a frozen window' -f $FrozenFlag, $preFlag, $FrozenValue))
    }
    if (-not $LatestFrame -and $FrozenFlag -and $preFlag -ne $postFlag) {
        Out2 ('CHECK frozen_during_copy: FAILED - {0} changed {1} -> {2}' -f $FrozenFlag, $preFlag, $postFlag)
        $softFail.Add(('{0} changed while copying ({1} -> {2}): the window is torn' -f $FrozenFlag, $preFlag, $postFlag))
    }
    $frameChanged = $false
    if ($SeqVar) {
        $preSeq = [string]$pre.vars[$SeqVar]
        $postSeq = [string]$post.vars[$SeqVar]
        if (-not $preSeq -or -not $postSeq) {
            $softFail.Add(('{0} was not readable on both sides of the array copy' -f $SeqVar))
        } elseif ($preSeq -ne $postSeq) {
            $frameChanged = $LatestFrame
            Out2 ('CHECK sequence_during_copy: FAILED - {0} changed {1} -> {2}' -f $SeqVar, $preSeq, $postSeq)
            $softFail.Add(('{0} changed while copying ({1} -> {2}): the window is torn' -f $SeqVar, $preSeq, $postSeq))
        }
    }
    if ($LatestFrame) {
        $postBank = [string]$post.vars[$BankVar]
        if (-not $postBank) { $softFail.Add(('{0} was not readable after the array copy' -f $BankVar)) }
        elseif ($preBank -ne $postBank) {
            $frameChanged = $true
            $softFail.Add(('{0} changed while copying ({1} -> {2}): selected bank may have been reused' -f $BankVar,$preBank,$postBank))
        }
    }
    if ($arr.arr.Count -ne $total) {
        Out2 ('CHECK count: FAILED - got {0}, expected {1}' -f $arr.arr.Count, $total)
        $softFail.Add(('got {0} values, expected {1}' -f $arr.arr.Count, $total))
    }

    $got = $arr.arr.Count
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('index,value')
    for ($i = 0; $i -lt $got; $i++) { $lines.Add(('{0},{1}' -f $i, $arr.arr[$i])) }
    $csvPath = Join-Path $dataDir 'array.csv'

    # anchor: the first element must read the same both ways while the buffer is frozen
    if ($got -gt 0) {
        $anchor = Request-Soft ('VARS ' + $ArrayName + '[0]')
        $anchorVal = if ($anchor -and $anchor.errors.Count -eq 0) { [string]$anchor.vars[($ArrayName + '[0]')] } else { '' }
        if (-not $anchorVal) { $softFail.Add(('anchor {0}[0] could not be evaluated' -f $ArrayName)) }
        elseif ($anchorVal -match '^-?\d+$' -and ([int64]$arr.arr[0]) -ne ([int64]$anchorVal)) {
            Out2 ('CHECK anchor: FAILED - {0}[0] evaluate={1} readData={2}' -f $ArrayName, $anchorVal, $arr.arr[0])
            $softFail.Add(('{0}[0] reads {1} by evaluate but {2} by readData: the array layout may not match' -f $ArrayName, $anchorVal, $arr.arr[0]))
        }
    }
    $fwAfter = if ($FwIdVar) { Request-Soft ('VARS ' + $FwIdVar) } else { $null }
    $fwAfterValue = if ($fwAfter -and $fwAfter.errors.Count -eq 0) { [string]$fwAfter.vars[$FwIdVar] } else { '' }
    if (-not $fwAfterValue -or ($null -ne $ExpectFwId -and -not (Test-FlagEquals $fwAfterValue ([string]$ExpectFwId))) -or -not (Test-FlagEquals $fwAfterValue $fwBeforeValue)) {
        Out2 ('CHECK fw id after copy: FAILED - {0} -> {1} (expected {2})' -f $fwBeforeValue, $fwAfterValue, $ExpectFwId)
        $softFail.Add(('firmware identity changed during the copy ({0} -> {1}): the image may have been replaced' -f $fwBeforeValue, $fwAfterValue))
    }
    $ramAliveAfter = Test-AliveNow -ProjectPath $ProjectPath -Candidates @([string](Get-FwContract).ramProof.counter)
    if (-not $ramAliveAfter.ok) {
        # Boolean result, not a veto: whether the RAM updater kept running is a property of
        # the target, reported next to the data. It does not make the samples wrong.
        Out2 ('NOTE    : ram_proof advancing=False after the copy (' + $ramAliveAfter.reason + ')')
    }
    $appAliveAfter = Test-AliveNow -ProjectPath $ProjectPath -Candidates @((Get-FwContract).heartbeat.candidates)
    if (-not $appAliveAfter.ok) {
        Out2 ('CHECK heartbeat after copy: FAILED - ' + $appAliveAfter.reason)
        $softFail.Add(('application heartbeat stopped after the copy: ' + $appAliveAfter.reason))
    }
    [IO.File]::WriteAllLines($csvPath, $lines, $utf8Bom)

    $mapLines = New-Object System.Collections.Generic.List[string]
    $mapLines.Add('role,name,first,last,delta,status')
    $mapLines.Add(('array,{0},,,,OK' -f $ArrayName))
    if ($LatestFrame) {
        $mapLines.Add('capture,latest-frame,,,,SEQUENCE_AND_BANK_CHECK')
        $mapLines.Add(('bank,{0},{1},{2},,{3}' -f $BankVar,$preBank,$postBank,$(if ($preBank -eq $postBank -and $preBank -in @('0','1')) { 'OK' } else { 'FAIL' })))
    }
    else { $mapLines.Add(('frozen,{0},{1},{2},,{3}' -f $FrozenFlag, $preFlag, $postFlag, $(if (Test-FlagEquals $preFlag $FrozenValue) { 'OK' } else { 'FAIL' }))) }
    if ($SeqVar) { $mapLines.Add(('sequence,{0},{1},{2},,OK' -f $SeqVar, $pre.vars[$SeqVar], $post.vars[$SeqVar])) }
    [IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

    $arrayVerdictArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
        '-CsvPath', $csvPath, '-AllowNoHeartbeat', '-ExpectedRows', [string]$total,
        '-RangeVars', 'value')
    if ($null -ne $ValueMin) { $arrayVerdictArgs += @('-ValueMin',([double]$ValueMin).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
    if ($null -ne $ValueMax) { $arrayVerdictArgs += @('-ValueMax',([double]$ValueMax).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
    $vout = & $pwshExe @arrayVerdictArgs 2>&1
    $vcode = $LASTEXITCODE
    foreach ($l in $vout) {
        $line = [string]$l
        if ($line -match '^RESULT:') { continue }
        if ($line -match '^FAILURE:') { Out2 ('CHECK   : ' + $line); continue }
        Out2 $line
    }
    if ($vcode -ne 0) {
        $softFail.Add(('array numeric/count verdict failed on {0}' -f $csvPath))
    }
    $coreName = [string]$state.core
    if ($coreName) { $coreName = ($coreName -split '/')[-1] }
    $verdictResult = if ($softFail.Count -eq 0) { 'OK' } else { 'FAIL' }
    $verdict = @(
        ('result: ' + $verdictResult), 'mode: live-service (no reload)', ('service_pid: ' + $svcPid),
        ('service_started: ' + $state.started), ('out: ' + $state.out), ('out_sha256: ' + $state.outSha256),
        ('core: ' + $coreName),
        ('array: {0} ({1}x{2}={3}, got {4})' -f $ArrayName, $Rows, $Columns, $total, $got),
        ('capture: ' + $(if ($LatestFrame) { 'latest-frame sequence check' } else { ('frozen {0} = {1}' -f $FrozenFlag, $preFlag) })),
        ('ram_proof_after: {0} {1}->{2}' -f $ramAliveAfter.name,$ramAliveAfter.first,$ramAliveAfter.last),
        ('heartbeat_after: {0} {1}->{2}' -f $appAliveAfter.name,$appAliveAfter.first,$appAliveAfter.last),
        ('soft_failures: ' + $(if ($softFail.Count -gt 0) { $softFail -join ' | ' } else { 'none' })),
        ('data: ' + $csvPath)
    )
    [IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)
    # Which core the samples came from, reported next to the data rather than used as a gate.
    Out2 ('SOURCE  : {0}' -f $(if ($coreName) { $coreName } else { '(unknown core)' }))
    Out2 ('DATA    : {0}' -f $csvPath)
    Out2 ('VERDICT : {0}' -f (Join-Path $checkDir 'verdict.txt'))
    Out2 ('VALUES  : {0} (requested {1})' -f $got, $total)
    if ($softFail.Count -gt 0) {
        # The samples are already on disk. Refusing them would only hide the thing the user
        # asked for; instead say exactly which judgement failed.
        if ($frameChanged) { Out2 'FAILURE: FRAME_CHANGED' }
        else { Out2 'FAILURE: DATA_UNRELIABLE' }
        Out2 'RESULT: FAIL'
        foreach ($sf in $softFail) { Out2 ('REASON: ' + $sf) }
        Out2 'HINT    : the samples were written anyway - array.csv contains exactly what was read'
        exit 1
    }
    Out2 'RESULT: OK'
    exit 0
}

# ------------------------------------------------------------- variables -----
# The heartbeat is read in its own tolerant requests, never merged into the user's
# request. Two reasons, both measured 2026-11-14:
#   * a read whose -Variables contains no heartbeat (for example "read EPwm1Regs.TBPRD")
#     used to report every candidate as MISSING and fail with HEARTBEAT_FAIL although
#     the target was alive - the values only ever existed in the VARS response;
#   * merging them into one request makes an undefined candidate (gRunMs on this build)
#     return an error for the WHOLE batch, which turned a legitimate register read into
#     VALUE_READ_FAILED.
# So: one strict request for the user's names, then one tolerant request per candidate.
# Which candidates exist is decided on round 1 and reused afterwards.
$hbUsable = @()
# NOT $rounds: PowerShell variable names are case-insensitive, so that would
# collide with the -Rounds parameter and fail as an array-to-Int32 conversion.
$samples = @()
for ($r = 1; $r -le $Rounds; $r++) {
    $resp = Request ('VARS ' + ($names -join '|'))
    $hbVals = @{}
    if ($heartbeats.Count -gt 0) {
        $pool = if ($r -eq 1) { $heartbeats } else { $hbUsable }
        foreach ($hb in $pool) {
            $hr = Request-Soft ('VARS ' + $hb)
            if (-not $hr) { continue }
            if ($hr.errors.Count -gt 0) { continue }
            $v = $hr.vars[$hb]
            if ($null -eq $v -or $v -eq '') { continue }
            if ($r -eq 1 -and $hbUsable -notcontains $hb) { $hbUsable += $hb }
            $hbVals[$hb] = $v
        }
    }
    $merged = @{}
    foreach ($k in $resp.vars.Keys) { $merged[$k] = $resp.vars[$k] }
    foreach ($k in $hbVals.Keys) { $merged[$k] = $hbVals[$k] }
    # firmware identity: a constant the image itself declares, read once. It is the only
    # "is this the build I think" evidence that needs neither the memory map nor the probe.
    if ($r -eq 1 -and $null -ne $ExpectFwId) {
        $fr = Request-Soft ('VARS ' + $FwIdVar)
        if ($env:TI_C2000_DEBUG_HEARTBEAT) { [IO.File]::AppendAllText((Join-Path $env:TEMP 'c2000-fw-dbg.log'), ('FW r=' + $r + ' expect=[' + $ExpectFwId + '] frNull=' + ($null -eq $fr) + ' v=[' + $(if ($fr) { $fr.vars[$FwIdVar] } else { '' }) + ']' + [Environment]::NewLine)) }
        if ($fr -and $fr.errors.Count -eq 0) { $fwRaw = [string]$fr.vars[$FwIdVar] }
    }
    $now = Get-Date
    $uptime = ($now - (Get-Process -Id $svcPid).StartTime).TotalMilliseconds
    $samples += [ordered]@{ round = $r; hostMs = [int64]$uptime; hostTime = $now.ToString('HH:mm:ss.fff'); vars = $merged }
    if ($r -lt $Rounds) { Start-Sleep -Milliseconds $IntervalMs }
}

# heartbeat must advance in the live session (no startup-window check: it can run for hours)
# a candidate the build does not define is normal - only a readable-but-frozen
# candidate is a failure, and at least one must be readable to claim liveness
$hbOk = $false
$hbFailed = @()
$hbChecked = @()
$mapLines = New-Object System.Collections.Generic.List[string]
$mapLines.Add('role,name,first,last,delta,status')
foreach ($hn in $heartbeats) {
    $vals = @($samples | ForEach-Object { $_.vars[$hn] })
    if ($vals.Count -eq 0 -or @($vals | Where-Object { $_ -eq $null -or $_ -eq '' }).Count -gt 0) {
        $mapLines.Add(('heartbeat,{0},,,,MISSING' -f $hn))
        Out2 ('CHECK heartbeat {0}: MISSING (not defined in this build)' -f $hn)
        continue
    }
    $hbChecked += $hn
    $bad = 0
    $candidateOk = $true
    for ($i = 1; $i -lt $vals.Count; $i++) {
        $prev = 0.0; $cur = 0.0
        $prevOk = [double]::TryParse([string]$vals[$i - 1], [ref]$prev)
        $curOk = [double]::TryParse([string]$vals[$i], [ref]$cur)
        if ($prevOk -and $curOk -and $cur -gt $prev) { $bad = 0; continue }
        $bad++
        Out2 ('CHECK heartbeat {0}: round {1} not increasing ({2} -> {3})' -f $hn, ($i + 1), $vals[$i - 1], $vals[$i])
        if ($bad -ge 2 -or $vals.Count -eq 2 -or -not $prevOk -or -not $curOk) { $candidateOk = $false }
    }
    $delta = 0
    $f = 0.0; $l = 0.0
    if ([double]::TryParse([string]$vals[0], [ref]$f) -and [double]::TryParse([string]$vals[-1], [ref]$l)) { $delta = $l - $f }
    if ($candidateOk) { $hbOk = $true } else { $hbFailed += $hn }
    $mapLines.Add(('heartbeat,{0},{1},{2},{3},{4}' -f $hn, $vals[0], $vals[-1], $delta, $(if ($candidateOk) { 'OK' } else { 'FAIL' })))
}
if ($hbChecked.Count -eq 0) { Out2 'CHECK heartbeat: no readable candidate, liveness unverified' }
foreach ($n in $names) { $mapLines.Add(('variable,{0},,,,' -f $n)) }
[IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

$csv = New-Object System.Collections.Generic.List[string]
$csv.Add(('round,hostMs,hostTime,' + ($names -join ',')))
foreach ($row in $samples) {
    $vals = @($names | ForEach-Object { $row.vars[$_] })
    $csv.Add(('{0},{1},{2},{3}' -f $row.round, $row.hostMs, $row.hostTime, ($vals -join ',')))
}
$csvPath = Join-Path $dataDir 'data.csv'
[IO.File]::WriteAllLines($csvPath, $csv, $utf8Bom)

if ($heartbeats.Count -gt 0 -and $hbOk) { Out2 'HEARTBEAT: OK (all candidates increased)' }
elseif ($heartbeats.Count -gt 0) { Out2 'HEARTBEAT: FAIL' }

# ---- firmware self-proof, part 1: identity ---------------------------------------
# gFwId is a constant the image declares. Comparing it needs nothing but a memory read:
# no Flash base, no PC, no section table, no assumption about the probe. A mismatch means
# the board is running a different build, which is exactly the failure the address-based
# tests were trying to catch, only now it is stated by the firmware itself.
$fwOk = $true
$fwCode = ''
if ($null -ne $ExpectFwId) {
    $fwNum = $null
    if ($fwRaw) {
        $t = $fwRaw.Trim()
        if ($t -match '^0[xX]([0-9A-Fa-f]+)$') { try { $fwNum = [double][Convert]::ToUInt64($t.Substring(2), 16) } catch { } }
        else { $d = 0.0; if ([double]::TryParse($t, [ref]$d)) { $fwNum = $d } }
    }
    if ($null -eq $fwNum) {
        $fwOk = $false; $fwCode = 'FW_ID_UNREADABLE'
        Out2 ('CHECK fw id {0}: UNREADABLE - cannot confirm which build is running' -f $FwIdVar)
    } elseif ($fwNum -ne [double]$ExpectFwId) {
        $fwOk = $false; $fwCode = 'FW_ID_MISMATCH'
        Out2 ('CHECK fw id {0}: {1} != expected {2} - the board runs a different build' -f $FwIdVar, $fwNum, $ExpectFwId)
    } else {
        Out2 ('CHECK fw id {0}: {1} (matches expected)' -f $FwIdVar, $fwNum)
    }
}

# ---- firmware self-proof, part 2: rate -------------------------------------------
# "Increasing" only says the counter moved at least once. The rate says it is moving at
# the frequency the firmware claims, which is what separates a live program from a value
# that happens to change between two reads. Units are the counter's own: per second.
$rateOk = $true
$rateCode = ''
if ($RateVar -and $ExpectedRatePerSec -gt 0) {
    $rv = @($samples | ForEach-Object { $_.vars[$RateVar] })
    $nums = @()
    foreach ($x in $rv) {
        $s = ([string]$x).Trim(); $d = 0.0
        if ($s -match '^0[xX]([0-9A-Fa-f]+)$') { try { $nums += [double][Convert]::ToUInt64($s.Substring(2), 16) } catch { } }
        elseif ([double]::TryParse($s, [ref]$d)) { $nums += $d }
    }
    $t0 = [double]$samples[0].hostMs
    $t1 = [double]$samples[-1].hostMs
    $dt = ($t1 - $t0) / 1000.0
    if ($nums.Count -lt 2 -or $dt -le 0) {
        $rateOk = $false; $rateCode = 'HEARTBEAT_RATE'
        Out2 ('CHECK rate {0}: cannot compute (samples={1}, seconds={2:N3})' -f $RateVar, $nums.Count, $dt)
    } else {
        $dr = $nums[-1] - $nums[0]
        if ($dr -lt 0) { $dr += 4294967296.0 }   # 32-bit counter wrapped during the window
        $rate = $dr / $dt
        $lo = $ExpectedRatePerSec * (1 - ($RateTolerancePct / 100.0))
        $hi = $ExpectedRatePerSec * (1 + ($RateTolerancePct / 100.0))
        if ($rate -lt $lo -or $rate -gt $hi) {
            $rateOk = $false; $rateCode = 'HEARTBEAT_RATE'
            Out2 ('CHECK rate {0}: {1:N1}/s outside {2:N0}..{3:N0} (expected {4:N0} +/-{5:N0}%) - the program is not running at its claimed speed' -f `
                    $RateVar, $rate, $lo, $hi, $ExpectedRatePerSec, $RateTolerancePct)
        } else {
            Out2 ('CHECK rate {0}: {1:N1}/s (expected {2:N0} +/-{3:N0}%)' -f $RateVar, $rate, $ExpectedRatePerSec, $RateTolerancePct)
        }
    }
}

$vargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
    '-CsvPath', $csvPath, '-RangeVars', ($names -join ','))
# The heartbeat was already judged above from live samples, which is stronger than
# re-reading a CSV column (and the column only exists when the user listed the counter
# in -Variables). So the CSV verdict checks numbers and ranges, not liveness.
$vargs += '-AllowNoHeartbeat'
if ($null -ne $ValueMin) { $vargs += @('-ValueMin',([double]$ValueMin).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
if ($null -ne $ValueMax) { $vargs += @('-ValueMax',([double]$ValueMax).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
$vout = & $pwshExe @vargs 2>&1
$vcode = $LASTEXITCODE
# HEARTBEAT was already reported above; do not let the verdict repeat it. The verdict's
# own FAILURE line becomes CHECK so this script keeps the single FAILURE: VERDICT_FAILED
# that its caller expects (one failure line per invocation).
foreach ($l in $vout) {
    $s = [string]$l
    if ($s -match '^(RESULT|HEARTBEAT):') { continue }
    if ($s -match '^FAILURE:\s*(.+)$') { Out2 ('CHECK   : ' + $Matches[1]); continue }
    Out2 $s
}

$verdictResult = if ($vcode -eq 0 -and $hbOk -and $fwOk -and $rateOk -and -not $PreflightIssues) { 'OK' } else { 'FAIL' }
$verdict = @(
    ('result: ' + $verdictResult), 'mode: live-service (no reload)', ('service_pid: ' + $svcPid),
    ('service_started: ' + $state.started), ('out: ' + $state.out), ('out_sha256: ' + $state.outSha256),
    ('rounds: {0} x {1} ms' -f $Rounds, $IntervalMs), ('variables: ' + ($names -join ', ')),
    ('heartbeat: ' + $(if ($heartbeats.Count -eq 0) { 'SKIPPED' } elseif ($hbOk) { 'OK' } else { 'FAIL' })),
    ('preflight_issues: ' + $(if ($PreflightIssues) { $PreflightIssues } else { 'none' })),
    ('data: ' + $csvPath)
)
[IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)

$coreNameOut = [string]$state.core
if ($coreNameOut) { $coreNameOut = ($coreNameOut -split '/')[-1] }
Out2 ('SOURCE  : {0}' -f $(if ($coreNameOut) { $coreNameOut } else { '(unknown core)' }))
Out2 ('DATA    : {0}' -f $csvPath)
Out2 ('VERDICT : {0}' -f (Join-Path $checkDir 'verdict.txt'))
Out2 ('VALUES  : {0}' -f ($Rounds * $names.Count))

# -NoHeartbeat means "do not judge liveness", not "liveness failed": with no candidates
# $hbOk stays false, and the check below must not fire (measured 2026-11-14).
if ($heartbeats.Count -gt 0 -and -not $hbOk) {
    Out2 'FAILURE: HEARTBEAT_FAIL'; Out2 'RESULT: FAIL'
    Out2 ('REASON: heartbeat did not advance in the live session (not increasing: ' + ($hbFailed -join ', ') + ')')
    Out2 'HINT    : pass -HeartbeatExpr <var> with a counter that changes every millisecond, or -NoHeartbeat to skip the liveness judgement'
    exit 1
}
if (-not $fwOk) {
    Out2 ('FAILURE: ' + $fwCode); Out2 'RESULT: FAIL'
    if ($fwCode -eq 'FW_ID_MISMATCH') {
        Out2 ('REASON: the firmware answers {0} = {1}, but this build declares {2} - the target is running another image' -f $FwIdVar, $fwNum, $ExpectFwId)
        Out2 'HINT    : rebuild and start the session again (-Start -ConfirmLoad); the value comes from the firmware itself, so a mismatch is never a reading error'
    } else {
        Out2 ('REASON: {0} could not be read, so which build is running is unknown' -f $FwIdVar)
        Out2 'HINT    : the running firmware does not define it yet - add "volatile unsigned long gFwId" to the image, or drop -ExpectFwId to skip this check'
    }
    exit 1
}
if (-not $rateOk) {
    Out2 'FAILURE: HEARTBEAT_RATE'; Out2 'RESULT: FAIL'
    Out2 ('REASON: the counter {0} does not advance at {1:N0}/s (tolerance {2:N0}%) - the program is running, but not at the rate this firmware claims' -f $RateVar, $ExpectedRatePerSec, $RateTolerancePct)
    Out2 'HINT    : check the clock/PLL and whether the ISR that increments it is still being serviced'
    exit 1
}
if ($vcode -ne 0) {
    Out2 'FAILURE: VERDICT_FAILED'; Out2 'RESULT: FAIL'
    Out2 ('REASON: verdict on {0} failed' -f $csvPath); exit 1
}
if ($PreflightIssues) {
    Out2 'FAILURE: DATA_UNRELIABLE'; Out2 'RESULT: FAIL'
    Out2 ('REASON: source/identity evidence needs review: ' + $PreflightIssues)
    exit 1
}
Out2 'RESULT: OK'
exit 0

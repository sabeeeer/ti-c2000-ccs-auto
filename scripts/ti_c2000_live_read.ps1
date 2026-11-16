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
    Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$owner = Get-TargetLockInfo -ProjectPath $ProjectPath
if ($ParentPid -le 0 -or -not $owner -or $owner.pid -ne $ParentPid -or $owner.mode -ne 'ReadOnly' -or
    -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
    Out2 'FAILURE: INTERNAL_ONLY'; Out2 'RESULT: FAIL'
    Out2 'REASON: use ti_c2000_run_read.ps1 or ti_c2000_read_dma.ps1; their preflight owns the ReadOnly lock'
    exit 2
}
$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0 -and -not $ArrayName) {
    Out2 'FAILURE: NEED_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: pass -Variables or -ArrayName'; exit 2
}
if ($names.Count -gt 0 -and $ArrayName) {
    Out2 'FAILURE: AMBIGUOUS_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use -Variables or -ArrayName, not both'; exit 2
}
if ($ArrayName -and -not $FrozenValue.Trim()) {
    Out2 'FAILURE: FROZEN_VALUE_REQUIRED'; Out2 'RESULT: FAIL'
    Out2 'REASON: a frozen array requires an explicit completed flag value'; exit 2
}
if ($NoHeartbeat) {
    Out2 'FAILURE: READ_PROOF_BYPASS'; Out2 'RESULT: FAIL'
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
    exit 2
}
$svcPid = [int]$state.pid

# the session may still hold an image that was replaced on disk since it started.
# Guard the field itself: a state.json written by an older version (or trimmed by hand)
# may have no "out", and Test-Path -LiteralPath $null throws a parameter-binding error that
# would abort the read for a purely bookkeeping reason (measured 2026-11-15).
if ($state.out -and (Test-Path -LiteralPath $state.out)) {
    $nowSha = (Get-FileHash -LiteralPath $state.out -Algorithm SHA256).Hash
    if ($nowSha -ne $state.outSha256) {
        Out2 'FAILURE: STALE_SERVICE'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0} changed after the session loaded it - restart the service so a read cannot describe a stale image' -f (Split-Path -Leaf $state.out))
        exit 2
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
    Out2 'REASON: mandatory CSV verdict script is missing'; exit 2
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
if ($ArrayName) {
    $total = $Rows * $Columns
    if ($null -eq $ExpectFwId -or -not $FwIdVar) {
        Out2 'FAILURE: FW_ID_UNREADABLE'; Out2 'RESULT: FAIL'
        Out2 'REASON: frozen array reads require the loaded firmware identity'; exit 4
    }
    $fwBefore = Request ('VARS ' + $FwIdVar)
    $fwBeforeValue = [string]$fwBefore.vars[$FwIdVar]
    if (-not (Test-FlagEquals $fwBeforeValue ([string]$ExpectFwId))) {
        Out2 'FAILURE: FW_ID_MISMATCH'; Out2 'RESULT: FAIL'
        Out2 ('REASON: firmware identity before array copy was {0}, expected {1}' -f $fwBeforeValue,$ExpectFwId); exit 4
    }
    if ($FrozenFlag) {
        # a build without the freeze flag has nothing safe to copy; say so plainly
        # instead of failing with a generic symbol error
        $probeRaw = Send-Request ('VARS ' + $FrozenFlag) $RequestTimeoutMs
        if ($null -eq $probeRaw) {
            Out2 'FAILURE: SERVICE_TIMEOUT'; Out2 'RESULT: FAIL'
            Out2 ('REASON: no response within {0} ms - see {1}' -f $RequestTimeoutMs, (Join-Path $svcDir 'server.log')); exit 1
        }
        $probe = ConvertFrom-Response $probeRaw
        if ($probe.errors.Count -gt 0) {
            if (($probe.errors -join ';') -match 'identifier not found') {
                Out2 'FAILURE: NO_FROZEN_FLAG'; Out2 'RESULT: FAIL'
                Out2 ('REASON: this build has no {0} - the firmware never freezes a buffer, so there is no consistent window to copy' -f $FrozenFlag)
                exit 1
            }
            Out2 'FAILURE: VALUE_READ_FAILED'; Out2 'RESULT: FAIL'
            Out2 ('REASON: ' + ($probe.errors -join '; ')); exit 1
        }
    }
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    do {
        $pre = Request (('VARS ' + $FrozenFlag + '|' + $SeqVar).Trim('|'))
        if (Test-FlagEquals ([string]$pre.vars[$FrozenFlag]) $FrozenValue) { break }
    } while ((Get-Date) -lt $deadline)
    if (-not (Test-FlagEquals ([string]$pre.vars[$FrozenFlag]) $FrozenValue)) {
        Out2 'FAILURE: BUFFER_NOT_FROZEN'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0} did not reach {1} within {2} ms' -f $FrozenFlag,$FrozenValue,$WaitMs)
        exit 1
    }
    $arr = Request ('ARRAY ' + $ArrayName + '|' + $Rows + '|' + $Columns)
    $post = Request (('VARS ' + $FrozenFlag + '|' + $SeqVar).Trim('|'))

    $preFlag = [string]$pre.vars[$FrozenFlag]
    $postFlag = [string]$post.vars[$FrozenFlag]
    # The expected value was declared and documented but never read: a flag that sits at 0
    # does not change while the window is copied, so "did it change?" passed on a buffer
    # that was never frozen and the copy could mix old and new samples. Equality is what
    # proves "frozen"; stability alone only proves "constant" (found 2026-11-15 by
    # tools/audit_dead_params.ps1).
    if ($FrozenFlag -and -not (Test-FlagEquals $preFlag $FrozenValue)) {
        Out2 'FAILURE: BUFFER_NOT_FROZEN'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0} = {1}, expected {2} - the buffer is not in its frozen state, so a copy taken now could mix old and new samples' -f $FrozenFlag, $preFlag, $FrozenValue)
        Out2 'HINT    : check the firmware freeze protocol and expected completed flag value'
        exit 1
    }
    if ($FrozenFlag -and $preFlag -ne $postFlag) {
        Out2 'FAILURE: BUF_CHANGED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0} changed while copying ({1} -> {2})' -f $FrozenFlag, $preFlag, $postFlag); exit 1
    }
    if ($SeqVar) {
        $preSeq = [string]$pre.vars[$SeqVar]
        $postSeq = [string]$post.vars[$SeqVar]
        if ($preSeq -ne $postSeq) {
            Out2 'FAILURE: BUF_CHANGED'; Out2 'RESULT: FAIL'
            Out2 ('REASON: {0} changed while copying ({1} -> {2})' -f $SeqVar, $preSeq, $postSeq); exit 1
        }
    }
    if ($arr.arr.Count -ne $total) {
        Out2 'FAILURE: COUNT_MISMATCH'; Out2 'RESULT: FAIL'
        Out2 ('REASON: got {0} values, expected {1}' -f $arr.arr.Count, $total); exit 1
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('index,value')
    for ($i = 0; $i -lt $total; $i++) { $lines.Add(('{0},{1}' -f $i, $arr.arr[$i])) }
    $csvPath = Join-Path $dataDir 'array.csv'

    # anchor: the first element must read the same both ways while the buffer is frozen
    $anchor = Request ('VARS ' + $ArrayName + '[0]')
    $anchorVal = [string]$anchor.vars[($ArrayName + '[0]')]
    if ($anchorVal -match '^-?\d+$' -and ([int64]$arr.arr[0]) -ne ([int64]$anchorVal)) {
        Out2 'FAILURE: ARRAY_LAYOUT_MISMATCH'; Out2 'RESULT: FAIL'
        Out2 ('REASON: {0}[0] evaluate={1} readData={2}' -f $ArrayName, $anchorVal, $arr.arr[0]); exit 1
    }
    $fwAfter = Request ('VARS ' + $FwIdVar)
    $fwAfterValue = [string]$fwAfter.vars[$FwIdVar]
    if (-not (Test-FlagEquals $fwAfterValue ([string]$ExpectFwId)) -or -not (Test-FlagEquals $fwAfterValue $fwBeforeValue)) {
        Out2 'FAILURE: FW_ID_MISMATCH'; Out2 'RESULT: FAIL'
        Out2 ('REASON: firmware identity changed during array copy ({0} -> {1})' -f $fwBeforeValue,$fwAfterValue); exit 4
    }
    $ramAliveAfter = Test-AliveNow -ProjectPath $ProjectPath -Candidates @([string](Get-FwContract).ramProof.counter)
    if (-not $ramAliveAfter.ok) {
        Out2 'FAILURE: RAM_PROOF_NOT_ADVANCING'; Out2 'RESULT: FAIL'
        Out2 ('REASON: RAM updater stopped after the array copy: ' + $ramAliveAfter.reason); exit 4
    }
    $appAliveAfter = Test-AliveNow -ProjectPath $ProjectPath -Candidates @((Get-FwContract).heartbeat.candidates)
    if (-not $appAliveAfter.ok) {
        Out2 'FAILURE: HEARTBEAT_FAIL'; Out2 'RESULT: FAIL'
        Out2 ('REASON: application heartbeat stopped after the array copy: ' + $appAliveAfter.reason); exit 4
    }
    [IO.File]::WriteAllLines($csvPath, $lines, $utf8Bom)

    $mapLines = New-Object System.Collections.Generic.List[string]
    $mapLines.Add('role,name,first,last,delta,status')
    $mapLines.Add(('array,{0},,,,OK' -f $ArrayName))
    $mapLines.Add(('frozen,{0},{1},{2},,OK' -f $FrozenFlag, $preFlag, $postFlag))
    if ($SeqVar) { $mapLines.Add(('sequence,{0},{1},{2},,OK' -f $SeqVar, $pre.vars[$SeqVar], $post.vars[$SeqVar])) }
    [IO.File]::WriteAllLines((Join-Path $checkDir 'variables.csv'), $mapLines, $utf8Bom)

    $arrayVerdictArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verdictScript,
        '-CsvPath', $csvPath, '-AllowNoHeartbeat', '-ExpectedRows', [string]$total,
        '-RangeVars', 'value')
    if ($null -ne $ValueMin) { $arrayVerdictArgs += @('-ValueMin',([double]$ValueMin).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
    if ($null -ne $ValueMax) { $arrayVerdictArgs += @('-ValueMax',([double]$ValueMax).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
    $vout = & $pwshExe @arrayVerdictArgs 2>&1
    $vcode = $LASTEXITCODE
    foreach ($l in $vout) { if ([string]$l -notmatch '^RESULT:') { Out2 ([string]$l) } }
    if ($vcode -ne 0) {
        Out2 'FAILURE: ARRAY_VERDICT_FAILED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: verdict on {0} failed' -f $csvPath); exit 1
    }
    $verdict = @(
        'result: OK', 'mode: live-service (no reload)', ('service_pid: ' + $svcPid),
        ('service_started: ' + $state.started), ('out: ' + $state.out), ('out_sha256: ' + $state.outSha256),
        ('array: {0} ({1}x{2}={3})' -f $ArrayName, $Rows, $Columns, $total),
        ('frozen: {0} = {1}' -f $FrozenFlag, $preFlag),
        ('ram_proof_after: {0} {1}->{2}' -f $ramAliveAfter.name,$ramAliveAfter.first,$ramAliveAfter.last),
        ('heartbeat_after: {0} {1}->{2}' -f $appAliveAfter.name,$appAliveAfter.first,$appAliveAfter.last),
        ('data: ' + $csvPath)
    )
    [IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)
    Out2 ('DATA    : {0}' -f $csvPath)
    Out2 ('VERDICT : {0}' -f (Join-Path $checkDir 'verdict.txt'))
    Out2 ('VALUES  : {0}' -f $total)
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

$verdictResult = if ($vcode -eq 0 -and $hbOk -and $fwOk -and $rateOk) { 'OK' } else { 'FAIL' }
$verdict = @(
    ('result: ' + $verdictResult), 'mode: live-service (no reload)', ('service_pid: ' + $svcPid),
    ('service_started: ' + $state.started), ('out: ' + $state.out), ('out_sha256: ' + $state.outSha256),
    ('rounds: {0} x {1} ms' -f $Rounds, $IntervalMs), ('variables: ' + ($names -join ', ')),
    ('heartbeat: ' + $(if ($heartbeats.Count -eq 0) { 'SKIPPED' } elseif ($hbOk) { 'OK' } else { 'FAIL' })),
    ('data: ' + $csvPath)
)
[IO.File]::WriteAllLines((Join-Path $checkDir 'verdict.txt'), $verdict, $utf8Bom)

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
Out2 'RESULT: OK'
exit 0

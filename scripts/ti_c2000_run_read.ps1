#requires -Version 7.0
<#
ti_c2000_run_read.ps1 -- low-speed read. Two read modes, one execution mode.

  -Mode ReadOnly (default) : never downloads. Attaches to the live session started by
        ti_c2000_service.ps1 (load once, run forever) and asks it for values, after
        proofs: probe available, session and target alive, selected out/map hashes
        match the retained load, RAM updater and counter addresses lie in RAM,
        and the RAM counter advances. A failed proof means refusal (exit 4).
  -Mode LoadRead           : downloads once, runs, reads, retains session. Requires
        -ConfirmLoad; the caller may only pass it after the user said yes to
        "是否编译下载并运行". -MaxLoads N repeats the whole cycle until -Expect
        passes, keeping every attempt under readout\loadread\attempt-N.

- Standalone is a legacy alias for -Mode LoadRead (old command lines keep working).

Liveness proof (see references/data-read-verdict.md):
  - every readable heartbeat candidate is checked for advancement
  - numeric values must strictly increase across rounds
  - gMsTick / gRunMs style counters must advance; requested rate is checked
  - -NoHeartbeat is rejected for trusted ReadOnly

Exit code: 0 OK | 1 failure | 2 environment/argument | 3 no probe
           4 refused before downloading | 5 target held by another operation
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    # AllowEmptyString so an empty -Variables reaches the NEED_VARIABLES guard
    # (exit 2) instead of failing parameter binding with exit 1.
    [AllowEmptyString()][Parameter(Mandatory)][string[]]$Variables,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '',
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    # ---- portable "is this image running" proof (see references/data-read-verdict.md) --
    # Nothing below depends on the device memory map, the boot configuration or the probe:
    # the image declares gFwId and increments a counter, and both are plain memory reads.
    #   -ExpectFwId 0x00010001          read FwIdVar, compare with this build's FW_ID
    #   -RateVar gMsTick -ExpectedRatePerSec 1000
    #                                   the counter must advance at the claimed rate
    [string]$FwIdVar = 'gFwId',
    [Nullable[double]]$ExpectFwId = $null,
    [string]$RateVar = '',
    [double]$ExpectedRatePerSec = 0,
    [double]$RateTolerancePct = 20,
    # explicit linker map, when the build left it somewhere other than next to the .out
    [string]$MapFile = '',
    # optional value range for the read-back variables (判据 4). Pass both to enable it;
    # counters such as gMsTick must not be mixed into an ADC range, so name the columns
    # you actually want bounded with -Variables and keep the counters to the heartbeat.
    [Nullable[double]]$ValueMin = $null,
    [Nullable[double]]$ValueMax = $null,
    # default: 5 s total, 0.5 s interval -> 10 rounds
    [int]$Rounds = 10,
    [int]$IntervalMs = 500,
    [int]$WarmupMs = 500,
    [switch]$Build,
    [switch]$NoHeartbeat,
    [switch]$Quiet,
    # ReadOnly: attach and read, never download. LoadRead: download once, then read.
    # no [ValidateSet]: an illegal value must reach Resolve-ReadModeSpec, otherwise the
    # documented FAILURE: INVALID_READ_MODE (exit 2) can never be produced
    [string]$Mode = 'ReadOnly',
    # pass only after the user said yes to "compile/download and run?"
    [switch]$ConfirmLoad,
    # LoadRead only: repeat the download+read cycle until these conditions hold
    [string[]]$Expect = @(),
    [int]$MaxLoads = 1,
    # legacy alias for -Mode LoadRead
    [switch]$Standalone,
    # ReadOnly: skip the probe enumeration (fast, but an unplugged probe then shows
    # up as a read timeout instead of NO_PROBE)
    [switch]$NoProbeCheck,
    # ReadOnly: read even when the entry symbol cannot be read, i.e. RAM is unproven
    [switch]$AllowUnverified
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
# single exit point for success, so a run emits exactly one RESULT: OK no matter which
# branch finished (one-shot, ReadOnly attach, or a converged -MaxLoads loop)
function Complete-Run { Out2 'RESULT: OK'; exit 0 }
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')

# -Standalone is the old spelling of "download this time"; fold it into -Mode so
# there is exactly one state, then let the interlock validate the combination.
if ($Standalone) { $Mode = 'LoadRead' }
$spec = Resolve-ReadModeSpec -Mode $Mode -ConfirmLoad:$ConfirmLoad -Build:$Build -Expect $Expect -MaxLoads $MaxLoads -NoProbeCheck:$NoProbeCheck -AllowUnverified:$AllowUnverified
try { if ($CorePattern) { [void][regex]::new($CorePattern) } }
catch { Out2 'FAILURE: INVALID_CORE_PATTERN'; Out2 'RESULT: FAIL'; exit 2 }
if ($spec.mode -eq 'ReadOnly' -and ($NoProbeCheck -or $AllowUnverified -or $NoHeartbeat)) {
    Out2 'FAILURE: READ_PROOF_BYPASS'; Out2 'RESULT: FAIL'
    Out2 'REASON: ReadOnly requires probe, firmware and heartbeat proofs; bypass switches are disabled'
    exit 2
}

$names = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0) { Out2 'FAILURE: NEED_VARIABLES'; Out2 'RESULT: FAIL'; Out2 'REASON: -Variables requires at least one expression'; exit 2 }
if (@($names | Sort-Object -Unique).Count -ne $names.Count) {
    Out2 'FAILURE: DUPLICATE_VARIABLES'; Out2 'RESULT: FAIL'; Out2 'REASON: each variable may appear only once'; exit 2
}
if ($NoHeartbeat) { $HeartbeatExpr = '' }
$pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (@($names | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    @($heartbeats | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    $Rounds -lt 2 -or $IntervalMs -lt 0 -or $WarmupMs -lt 0) {
    Out2 'FAILURE: INVALID_READ_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use simple read paths, at least two rounds and nonnegative timing values'; exit 2
}

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) { Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2 }
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName

# a read never writes the target, so a leftover copy of a skill script is reported but
# not fatal; the run is still stamped so check_project_entry.ps1 can prove later that
# this read came from the skill
Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_run_read.ps1' -Mode $spec.mode -Block -Quiet:$Quiet

# a continuous run owns the target while it lasts: it re-downloads every round, so an
# attached read would describe a run that is already gone, and a second downloader
# would fight its loop. Both are refused here, before any DSS work.
Assert-RunModeInterlock -ProjectPath $ProjectPath -ReadMode $spec.mode

$projName = Split-Path -Leaf $ProjectPath
$projectFile = Join-Path $ProjectPath '.project'
if (Test-Path -LiteralPath $projectFile) {
    try {
        [xml]$projectXml = Get-Content -LiteralPath $projectFile -Raw
        if ($projectXml.projectDescription.name) { $projName = [string]$projectXml.projectDescription.name }
    } catch { Out2 'FAILURE: INVALID_PROJECT_NAME'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $_.Exception.Message); exit 2 }
}
$projName = [IO.Path]::GetFileName($projName)
$projName = [regex]::Replace($projName, '[^A-Za-z0-9._-]+', '_').Trim('.', '_')

if (-not $Ccxml) {
    $c = @(Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -First 1
    if ($c) { $Ccxml = $c.FullName }
}
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) { Out2 'FAILURE: NO_CCXML'; Out2 'RESULT: FAIL'; Out2 'REASON: no .ccxml found; pass -Ccxml <file>'; exit 2 }
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }

$skillRoot = Split-Path $PSScriptRoot -Parent
$debugScript = Join-Path $skillRoot 'scripts\ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debugScript)) { Out2 'FAILURE: ENV_NO_DEBUG_SCRIPT'; Out2 'RESULT: FAIL'; Out2 'REASON: ti_c2000_debug.ps1 is missing from this skill installation'; exit 2 }
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

# ---------- LoadRead with -MaxLoads N: repeat the one-shot cycle until -Expect ----
# Each attempt is a separate process that downloads, runs and reads, so the load
# path stays single. The child never loops itself (env marker).
if ($spec.maxLoads -gt 1 -and -not $env:TI_C2000_LOADREAD_CHILD) {
    $loop = Invoke-LoadReadLoop -ScriptPath $PSCommandPath -Bound $PSBoundParameters `
        -Expect $spec.expect -MaxLoads $spec.maxLoads -ProjectPath $ProjectPath `
        -CsvPath (Join-Path $ProjectPath 'readout\data\data.csv') `
        -VerdictPath (Join-Path $ProjectPath 'readout\check\verdict.txt') -Quiet:$Quiet
    if ($loop.converged) { Complete-Run }
    Out2 'FAILURE: LOADREAD_NOT_CONVERGED'; Out2 'RESULT: FAIL'
    Out2 ('REASON: ' + $loop.reason + ' (' + $loop.attempts + ' download(s) tried)')
    Out2 'HINT    : attempts are kept under readout\loadread - decide whether the firmware or the expectation is wrong'
    exit 1
}
if ($spec.mode -eq 'LoadRead') {
    Invoke-RetainedLoadRead -ScriptPath $PSCommandPath -Bound $PSBoundParameters -ProjectPath $ProjectPath -Quiet:$Quiet
}

# ---------- ReadOnly: attach to the one live session, never load -----------------
# Loading on every call means every call restarts the program, so two reads never
# describe the same run. The service loads once and keeps running; this reader only
# asks it for values, after proving it is still our image running from RAM.
if ($spec.mode -eq 'ReadOnly') {
    $s = Get-LiveSessionInfo -ProjectPath $ProjectPath
    if (-not $s.alive) {
        $cnt = Get-LoadCount -ProjectPath $ProjectPath
        Out2 'FAILURE: NO_SESSION'; Out2 'RESULT: FAIL'
        Out2 ('REASON: ReadOnly never downloads, and ' + $s.reason)
        Out2 'HINT    : ask the user "是否编译下载并运行？" first, then re-run with -Mode LoadRead -ConfirmLoad'
        Out2 ('          (that would be download #' + ([int]$cnt.count + 1) + ' for this project)')
        exit 4
    }
    if (-not $s.state.core -or ($CorePattern -and [string]$s.state.core -notmatch $CorePattern)) {
        Out2 'FAILURE: CORE_UNVERIFIED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: retained session core {0} does not match the requested core pattern {1}' -f $s.state.core,$CorePattern); exit 4
    }
    # a session whose JTAG link died still has a live pid and a matching sha256, so
    # "process alive" is not enough - the probe has to be enumerated first
    Assert-ProbeOnline -ProjectPath $ProjectPath -DebugScript $debugScript -CcsRoot $CcsRoot -Skip:$NoProbeCheck -Quiet:$Quiet

    if (-not (Test-Path -LiteralPath $OutFile)) {
        Out2 'FAILURE: NO_OUT_FILE'; Out2 'RESULT: FAIL'; Out2 ('REASON: missing ' + $OutFile); exit 2
    }
    $curSha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    if ($curSha -ne [string]$s.state.outSha256) {
        Out2 'FAILURE: STALE_SERVICE'; Out2 'RESULT: FAIL'
        Out2 ('REASON: the session loaded a different image (session {0}, disk {1})' -f $s.state.outSha256, $curSha)
        Out2 'HINT    : the .out was rebuilt after the load; reading it now would mix two builds'
        Out2 'HINT    : -Stop the session and start it again (-Start -ConfirmLoad) to load the new image'
        exit 2
    }
    $lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'ReadOnly'
    if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 5 }
    try {
        Initialize-ReadFailureVerdict -ProjectPath $ProjectPath
        Info2 ('JUDGE   : session alive (pid {0}, loaded {1}, LOAD #{2})' -f $s.state.pid, $s.state.started, $(if ($s.state.loadIndex) { $s.state.loadIndex } else { '?' }))
        Info2 ('JUDGE   : image matches this build (sha256 {0})' -f $curSha.Substring(0, 16))
        # ---- PREFLIGHT: report the state of the target BEFORE reading anything --------
        # Reading first and reporting afterwards is the pattern that produced the original
        # bug (ADC values from an old project, discovered only when they made no sense).
        # Every fact below is gathered first; a hard failure stops here, with no CSV and no
        # verdict written, so nothing can be mistaken for a reading.
        $blocking = New-Object System.Collections.Generic.List[string]
        $cnt = Get-LoadCount -ProjectPath $ProjectPath
        $fresh = Get-SelectedOutFreshEvidence -ProjectPath $ProjectPath -OutFile $OutFile
        if (-not $fresh.ok) { $blocking.Add(('selected image is stale: {0} ({1})' -f $fresh.reason,$fresh.file)) }

        # 1. RAM execution: pinned map + RAM updater/counter + moving counter;
        # no program-counter read or fixed device address.
        $loc = Get-RamProofEvidence -ProjectPath $ProjectPath -OutFile $OutFile -MapFile $MapFile -SessionState $s.state
        if ($loc.code -eq 'TARGET_NOT_CONNECTED') {
            Out2 'FAILURE: TARGET_NOT_CONNECTED'; Out2 'RESULT: FAIL'
            Out2 'REASON: the session process is alive and the probe is enumerated, but the target does not answer a register read - the JTAG link is gone'
            Out2 'HINT    : run -Stop then -Start -ConfirmLoad; a live session cannot reconnect to a board that disappeared and came back'
            Out2 'HINT    : this is an environment fault, so -AllowUnverified does not apply'
            exit 4
        }

        # 2. firmware identity: compare with what -Start recorded, automatically
        $fwNow = ''
        $fwLine = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @($FwIdVar)
        foreach ($line in $fwLine) {
            $m = [regex]::Match([string]$line, ('^V\s+' + [regex]::Escape($FwIdVar) + '\s+(\S+)\s*$'))
            if ($m.Success) { $fwNow = $m.Groups[1].Value; break }
        }
        $fwExpect = if ($null -ne $ExpectFwId) { [string]$ExpectFwId } else { [string]$s.state.fwId }

        # 3. is it running right now
        # Filter empties: with no -RateVar the first element is '', and that produced a
        # request for "VARS " with no name, which the service answers with an E line.
        # The liveness verdict then read as "no readable counter" instead of naming the
        # real result (2026-11-15).
        $aliveCands = @(@($RateVar) + @((Get-FwContract).heartbeat.candidates) | Where-Object { $_ } | Select-Object -Unique)
        $alive = Test-AliveNow -ProjectPath $ProjectPath -Candidates $aliveCands

        Out2 'PREFLIGHT: 读之前必须确认的事'
        Out2 '  PROBE    : online and usable; retained DSS session responded'
        Out2 ('  CORE     : {0}' -f $s.state.core)
        Out2 ('  LOCATION : {0} ({1})' -f $loc.kind,$loc.text)
        Out2 ('  BUILD    : {0}   sha256 {1}' -f $OutFile, $curSha.Substring(0, 16))
        Out2 ('  FRESH    : {0}{1}' -f $(if ($fresh.ok) { 'project inputs are no newer than .out' } else { 'STALE' }), $(if ($fresh.file) { ' (' + $fresh.file + ')' } else { '' }))
        Out2 ('  LOADS    : #{0} total for this project; this session is load #{1} (started {2})' -f $cnt.count, $(if ($s.state.loadIndex) { $s.state.loadIndex } else { '?' }), $s.state.started)
        if ($fwNow) {
            $same = (-not $fwExpect) -or ($fwNow -eq $fwExpect)
            Out2 ('  IMAGE    : {0} = {1} {2}' -f $FwIdVar, $fwNow, $(if (-not $fwExpect) { '(no recorded value to compare - pass -ExpectFwId)' } elseif ($same) { '(same build as this session loaded)' } else { ('!= recorded ' + $fwExpect + ' - ANOTHER BUILD') }))
            if (-not $same) { $blocking.Add(('the firmware answers {0} = {1}, but this session loaded a build that declared {2}' -f $FwIdVar, $fwNow, $fwExpect)) }
        } else {
            Out2 ('  IMAGE    : {0} not readable - the running firmware does not declare it, so build identity rests on sha256 only' -f $FwIdVar)
            $blocking.Add(('{0} could not be read; firmware identity is required' -f $FwIdVar))
        }
        if (-not $fwExpect) { $blocking.Add('this session recorded no firmware identity at load; a matching .out hash on disk is insufficient') }
        Out2 ('  ALIVE    : {0}' -f $(if ($alive.ok) { '{0} {1} -> {2}, {3}' -f $alive.name, $alive.first, $alive.last, $alive.reason } else { 'NOT RUNNING - ' + $alive.reason }))
        if (-not $alive.ok) { $blocking.Add('the program is not advancing, so any values read now describe a stopped or missing program') }

        if (-not $loc.ok) {
            $blocking.Add(('RAM execution proof failed: {0} ({1})' -f $loc.code,$loc.text))
        }

        if ($blocking.Count -gt 0) {
            # a refusal must not leave the previous run's data or its "result: OK" behind
            $dDir = Join-Path $ProjectPath 'readout\data'
            $cDir = Join-Path $ProjectPath 'readout\check'
            foreach ($n in @('data.csv', 'array.csv', 'variables.csv')) {
                $p = Join-Path $dDir $n
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
            }
            if (Test-Path -LiteralPath $cDir) {
                $v = @('result: FAIL', 'failure: PREFLIGHT_FAILED',
                    ('mode: ' + $spec.mode),
                    ('out: ' + $OutFile), ('out_sha256: ' + $curSha),
                    ('location: ' + $loc.kind + ' ' + $loc.text),
                    ('image: ' + $(if ($fwNow) { $FwIdVar + '=' + $fwNow } else { 'not declared' })),
                    ('reason: ' + ($blocking -join '; ')),
                    ('at: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
                [IO.File]::WriteAllLines((Join-Path $cDir 'verdict.txt'), $v, (New-Object Text.UTF8Encoding($true)))
            }
            Out2 'FAILURE: PREFLIGHT_FAILED'; Out2 'RESULT: FAIL'
            foreach ($b in $blocking) { Out2 ('REASON: ' + $b) }
            Out2 'HINT    : nothing was read; the previous data.csv and verdict.txt were cleared so no stale result survives'
            exit 4
        }
        Out2 'PREFLIGHT: all conditions hold - reading'
        Info2 ''
        Info2 ('JUDGE   : firmware identity will be re-checked while sampling: {0} must equal {1}' -f $FwIdVar, $fwExpect)
        if ($RateVar -and $ExpectedRatePerSec -gt 0) {
            Info2 ('JUDGE   : firmware rate will be checked: {0} ~ {1:N0}/s' -f $RateVar, $ExpectedRatePerSec)
        }
        # say the sampling period out loud: a polled read is not a scope, and the
        # caller must be able to tell "1.8 Hz" from "my signal updates every 100 ms"
        $sEst = ($IntervalMs + 85) / 1000.0
        Info2 ('RATE    : ~{0:N2} s per sample ({1} ms wait + 50~120 ms tool) -> change period should be >= {2:N1} s' -f $sEst, $IntervalMs, (10 * $sEst))
        $largs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'ti_c2000_live_read.ps1'),
            '-ProjectPath', $ProjectPath, '-Variables', ($names -join ','),
            '-Rounds', [string]$Rounds, '-IntervalMs', [string]$IntervalMs, '-HeartbeatExpr', $HeartbeatExpr,
            '-ParentPid', [string]$PID)
        # range verdict (data-read-verdict.md 判据 4) belongs at read time: without it the
        # caller would have to read, then run check_read by hand on the CSV
        if ($null -ne $ValueMin) { $largs += @('-ValueMin',([double]$ValueMin).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
        if ($null -ne $ValueMax) { $largs += @('-ValueMax',([double]$ValueMax).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
        $largs += @('-ExpectFwId', [string]$fwExpect, '-FwIdVar', $FwIdVar)
        if ($RateVar) { $largs += @('-RateVar', $RateVar) }
        if ($ExpectedRatePerSec -gt 0) { $largs += @('-ExpectedRatePerSec', [string]$ExpectedRatePerSec, '-RateTolerancePct', [string]$RateTolerancePct) }
        if ($NoHeartbeat) { $largs += '-NoHeartbeat' }
        if ($Quiet) { $largs += '-Quiet' }
        & $pwshExe @largs
        exit $LASTEXITCODE
    } finally {
        Exit-TargetLock -ProjectPath $ProjectPath
    }
}

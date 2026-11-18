#requires -Version 7.0
<#
ti_c2000_read_dma.ps1 -- read a firmware-frozen RAM buffer. Two read modes, one
execution mode (ti_c2000_service.ps1 loads once and keeps running).

  -Mode ReadOnly (default) : never downloads. Attaches to the live session after
        probe and session/target checks, then reports image/map and RAM/Flash source
        evidence while copying one window. Unknown location is reported with the data.
  -Mode LoadRead           : downloads once, runs, waits, copies, retains session. Requires
        -ConfirmLoad; -MaxLoads N repeats the cycle until -Expect passes.
  -Standalone              : legacy alias of -Mode LoadRead.

PRECONDITION:
  The firmware must fill a RAM array and stop writing it when the frozen flag
  is set. A sequence counter is recommended when the buffer can be rearmed.
  Pass -FrozenBufferReady after checking the actual firmware; -DmaReady is kept
  as a compatible alias for projects that really use DMA.

Why one session: on targets that reset when JTAG closes (F28379D), a separate
read-only call cannot work, so the copy must happen inside the session that
loaded and ran the program.

Verdict (same rules as references/data-read-verdict.md, independent of mode):
  BUF_NOT_READY / NO_SEQ / BUF_CHANGED / COUNT_MISMATCH / VALUE_OUT_OF_RANGE

WHEN TO USE THIS INSTEAD OF ti_c2000_run_read.ps1:
  Sampling here happens on the TARGET (the timer that fills the buffer), so the
  sample spacing is the firmware's, not the PC's - that is what makes 100 ms or
  10 us data readable. The polled reader has a single-round period of
  IntervalMs + 50~120 ms (default ~0.55-0.62 s, so ~1.8 Hz), which under-samples
  anything that changes every 100 ms by ~5.5x: values are still true, but 5-6
  updates disappear between two samples and the curve is aliased.
  Use the polled reader only when the measured period is >= 10x its round period
  (>= 3x if you only need the trend). See references/single-session-read.md.

Exit code: 0 OK | 1 failure | 2 argument/environment | 3 no probe
           4 refused before downloading | 5 target held by another operation
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [string]$ArrayName = '',
    [int]$Rows = 1,
    [int]$Columns = 1,
    [string]$FrozenFlag = 'gDmaReady',
    [string]$FrozenValue = '1',
    [string]$SeqVar = 'gDmaSeq',
    [switch]$FrozenBufferReady,
    [switch]$DmaReady,

    # Read the newest completed frame and retry until the sequence counter is stable across
    # the copy. This is the correct read for ping-pong: the buffer is never frozen (the DMA
    # rewrites it every frame), so "frozen" can never become true and every attempt reads
    # DATA_UNRELIABLE. The proof of a coherent frame here is that gDmaSeq did not move
    # while that frame was being copied.
    [switch]$LatestFrame,
    [int]$LatestFrameTries = 5,
    # Ping-pong needs an explicit published completed-bank selector. DSS ARRAY resolves a
    # static symbol address and cannot infer which of two buffers is newest from gDmaSeq.
    [string]$BankVar = '',
    [string]$Bank0Array = '',
    [string]$Bank1Array = '',

    # Control-period view. A control loop does not consume "an arbitrary slice of RAM": it
    # consumes the samples taken between two control interrupts. CycleSamples is that count
    #   CycleSamples = ADC sample rate / control frequency
    # e.g. 1.28 MSPS / 10 kHz = 128, or 100 kSPS / 10 kHz = 10.
    # With it set, the rows are split into that many per window, a cycles.csv is written with
    # index, cycle, sample_in_cycle, t_us and raw, and the joins between windows are checked
    # so a DMA buffer switch in the middle of a window shows up instead of hiding in a plot.
    [int]$CycleSamples = 0,
    [int]$SampleRateHz = 0,
    [string[]]$Variables = @(),
    [string]$HeartbeatExpr = 'gMsTick,gRunMs,usMainLoop',
    [int]$WaitMs = 10000,
    [Nullable[double]]$ValueMin = $null,
    [Nullable[double]]$ValueMax = $null,
    [string]$Ccxml = '',
    [string]$OutFile = '',
    [string]$CcsRoot = '',
    [string]$CorePattern = '',
    [switch]$Build,
    [switch]$Quiet,
    # ReadOnly: attach to the live session, never download. LoadRead: download once.
    # no [ValidateSet]: see ti_c2000_run_read.ps1 - INVALID_READ_MODE (exit 2) must stay reachable
    [string]$Mode = 'ReadOnly',
    # pass only after the user said yes to "compile/download and run?"
    [switch]$ConfirmLoad,
    # LoadRead only: repeat the download+copy cycle until these conditions hold
    [string[]]$Expect = @(),
    [int]$MaxLoads = 1,
    # legacy alias for -Mode LoadRead
    [switch]$Standalone,
    # ReadOnly: skip the probe enumeration (an unplugged probe then shows up as a
    # buffer timeout instead of NO_PROBE)
    [switch]$NoProbeCheck,
    # ReadOnly: copy even when the entry symbol cannot be read, i.e. RAM is unproven
    [switch]$AllowUnverified,
    [string]$MapFile = ''
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
catch { Out2 'USAGE: INVALID_CORE_PATTERN'; Out2 'RESULT: FAIL'; exit 2 }
if ($spec.mode -eq 'ReadOnly' -and ($NoProbeCheck -or $AllowUnverified)) {
    Out2 'USAGE: READ_PROOF_BYPASS'; Out2 'RESULT: FAIL'
    Out2 'REASON: ReadOnly requires a probe and retained session; bypass switches are disabled'
    exit 2
}

if ($LatestFrame -and ($FrozenBufferReady -or $DmaReady)) {
    Out2 'USAGE: MUTUALLY_EXCLUSIVE'; Out2 'RESULT: FAIL'
    Out2 'REASON: -LatestFrame retries until the sequence stops moving; a frozen-buffer promise says there is nothing to move'
    Out2 'HINT    : use one or the other, not both'
    exit 2
}
if ($LatestFrame -and $ArrayName) {
    Out2 'USAGE: MUTUALLY_EXCLUSIVE'; Out2 'RESULT: FAIL'
    Out2 'REASON: -LatestFrame selects -Bank0Array or -Bank1Array from -BankVar; omit -ArrayName'; exit 2
}
if ($LatestFrame -and (-not $SeqVar -or $LatestFrameTries -lt 1 -or $LatestFrameTries -gt 20 -or
    -not $BankVar -or -not $Bank0Array -or -not $Bank1Array)) {
    Out2 'USAGE: INVALID_LATEST_FRAME'; Out2 'RESULT: FAIL'
    Out2 'REASON: -LatestFrame requires -SeqVar, -BankVar, -Bank0Array, -Bank1Array and 1..20 attempts'; exit 2
}

if (-not ($FrozenBufferReady -or $DmaReady -or $LatestFrame)) {
    Out2 'USAGE: BUFFER_NOT_CONFIRMED'
    Out2 'RESULT: FAIL'
    Out2 'REASON: confirm the firmware fills and freezes this RAM buffer, then pass -FrozenBufferReady'
    exit 2
}
$pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$extraNames = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ((-not $LatestFrame -and -not $ArrayName) -or ($ArrayName -and $ArrayName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') -or
    $FrozenFlag -notmatch "^$pathPattern$" -or $FrozenValue -notmatch '^(?:true|[1-9][0-9]*)$' -or
    ($SeqVar -and $SeqVar -notmatch "^$pathPattern$") -or
    ($LatestFrame -and ($BankVar -notmatch "^$pathPattern$" -or
        $Bank0Array -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $Bank1Array -notmatch '^[A-Za-z_][A-Za-z0-9_]*$')) -or
    $heartbeats.Count -eq 0 -or @($heartbeats | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    @($extraNames | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    $WaitMs -lt 1) {
    Out2 'USAGE: INVALID_READ_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use a simple array/flag/counter name, valid heartbeat candidates and positive wait time'; exit 2
}
if ($Rows -lt 1 -or $Columns -lt 1) { Out2 'USAGE: BAD_DIMENSIONS'; Out2 'RESULT: FAIL'; Out2 'REASON: Rows/Columns must be positive'; exit 2 }
if ($null -ne $ValueMin -and $null -ne $ValueMax -and $ValueMin -gt $ValueMax) {
    Out2 'USAGE: BAD_VALUE_RANGE'; Out2 'RESULT: FAIL'; Out2 'REASON: ValueMin exceeds ValueMax'; exit 2
}
$total = [long]$Rows * [long]$Columns
if ($total -gt 100000) { Out2 'USAGE: ARRAY_TOO_LARGE'; Out2 'RESULT: FAIL'; Out2 'REASON: one capture is limited to 100000 values'; exit 2 }

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) { Out2 'USAGE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2 }
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName

# stamp the run with this skill's identity (a read cannot damage anything, so a
# leftover copy is only reported); see ti_c2000_readmode.ps1 Initialize-SkillRun
Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_read_dma.ps1' -Mode $spec.mode -Block -Quiet:$Quiet

# a continuous run owns the target while it lasts (see ti_c2000_readmode.ps1)
Assert-RunModeInterlock -ProjectPath $ProjectPath -ReadMode $spec.mode

$projName = Split-Path -Leaf $ProjectPath
$projectFile = Join-Path $ProjectPath '.project'
if (Test-Path -LiteralPath $projectFile) {
    try {
        [xml]$projectXml = Get-Content -LiteralPath $projectFile -Raw
        if ($projectXml.projectDescription.name) { $projName = [string]$projectXml.projectDescription.name }
    } catch { Out2 'USAGE: INVALID_PROJECT_NAME'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $_.Exception.Message); exit 2 }
}
$projName = [IO.Path]::GetFileName($projName)
$projName = [regex]::Replace($projName, '[^A-Za-z0-9._-]+', '_').Trim('.', '_')

if (-not $Ccxml) {
    $c = @(Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -First 1
    if ($c) { $Ccxml = $c.FullName }
}
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) { Out2 'USAGE: NO_CCXML'; Out2 'RESULT: FAIL'; Out2 'REASON: no .ccxml found; pass -Ccxml <file>'; exit 2 }
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }
$skillRoot = Split-Path $PSScriptRoot -Parent
$debugScript = Join-Path $skillRoot 'scripts\ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debugScript)) { Out2 'FAILURE: ENV_NO_DEBUG_SCRIPT'; Out2 'RESULT: FAIL'; Out2 'REASON: ti_c2000_debug.ps1 is missing from this skill installation'; exit 1 }
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

# ---------- LoadRead with -MaxLoads N: repeat the one-shot cycle until -Expect ----
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
# A reconnecting reader would reset the target and reload the program, so the
# frozen window it copies would belong to a different run. Attach instead, after
# checking that the retained target still responds; source location is reported separately.
if ($spec.mode -eq 'ReadOnly') {
    $s = Get-LiveSessionInfo -ProjectPath $ProjectPath
    if (-not $s.alive) {
        $cnt = Get-LoadCount -ProjectPath $ProjectPath
        Out2 'FAILURE: NO_SESSION'; Out2 'RESULT: FAIL'
        Out2 ('REASON: ReadOnly never downloads, and ' + $s.reason)
        Out2 'HINT    : a frozen buffer only exists in the running session; ask the user, then use -Mode LoadRead -ConfirmLoad'
        Out2 ('          (that would be download #' + ([int]$cnt.count + 1) + ' for this project)')
        exit 4
    }
    if ($CorePattern -and [string]$s.state.core -notmatch $CorePattern) {
        Out2 'FAILURE: CORE_UNVERIFIED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: retained session core {0} does not match the requested core pattern {1}' -f $s.state.core,$CorePattern); exit 4
    }
    if (-not $s.state.core) { Out2 'SOURCE  : target core was not recorded by the retained session; continuing to read and report data' }
    # same rule as the polled reader: an unplugged probe leaves a live pid behind,
    # so the enumeration is part of "can this session answer at all"
    Assert-ProbeOnline -ProjectPath $ProjectPath -DebugScript $debugScript -CcsRoot $CcsRoot -Skip:$NoProbeCheck -Quiet:$Quiet

    $outExists = Test-Path -LiteralPath $OutFile
    $curSha = if ($outExists) { (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash } else { '' }
    $staleServiceIssue = if (-not $outExists) {
        'selected disk .out is missing; the retained session may still be readable but its image cannot be checked against disk'
    } elseif ($curSha -ne [string]$s.state.outSha256) {
        'disk .out SHA differs from the image recorded at load; data source identity is unverified'
    } else { '' }
    $lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'ReadOnly'
    if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 4 }
    try {
        Initialize-ReadFailureVerdict -ProjectPath $ProjectPath
        Info2 ('JUDGE   : session alive (pid {0}, loaded {1}, LOAD #{2})' -f $s.state.pid, $s.state.started, $(if ($s.state.loadIndex) { $s.state.loadIndex } else { '?' }))
        Info2 ('IMAGE   : disk SHA256 {0}; load-record match {1}' -f $(if ($curSha) { $curSha.Substring(0,16) } else { 'MISSING' }),$(if ($staleServiceIssue) { 'NO' } else { 'YES' }))
        $fresh = Get-SelectedOutFreshEvidence -ProjectPath $ProjectPath -OutFile $OutFile
        $preflightIssues = New-Object System.Collections.Generic.List[string]
        if ($staleServiceIssue) { $preflightIssues.Add($staleServiceIssue) }
        if (-not $fresh.ok) { $preflightIssues.Add(('selected image is stale: {0}: {1}' -f $fresh.reason,$fresh.file)) }
        # Report where the core runs. A frozen buffer read from Flash is legitimate,
        # but the source must be labelled; location never decides the data verdict.
        $loc = Get-RamProofEvidence -ProjectPath $ProjectPath -OutFile $OutFile -MapFile $MapFile -SessionState $s.state
        if ($loc.code -eq 'TARGET_NOT_CONNECTED') {
            Out2 'FAILURE: TARGET_NOT_CONNECTED'; Out2 'RESULT: FAIL'
            Out2 'REASON: the session process is alive and the probe is enumerated, but the target does not answer a symbol-address request - the JTAG link is gone'
            Out2 'HINT    : run -Stop then -Start -ConfirmLoad; a live session cannot reconnect to a board that disappeared and came back'
            Out2 'HINT    : this is an environment fault, so -AllowUnverified does not apply'
            exit 4
        }
        Info2 ('RUNNING : {0}   ({1})' -f $loc.kind,$loc.text)
        if (-not $loc.ok) { Out2 ('SOURCE  : UNKNOWN ({0}); location is informational' -f $loc.code) }
        $idName = [string](Get-FwContract).identity.var
        $idLines = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @($idName)
        $idNow = ''
        foreach ($line in $idLines) {
            $m = [regex]::Match([string]$line,('^V\s+' + [regex]::Escape($idName) + '\s+(\S+)\s*$'))
            if ($m.Success) { $idNow = $m.Groups[1].Value; break }
        }
        if (-not $idNow -or -not $s.state.fwId -or $idNow -ne [string]$s.state.fwId) {
            $preflightIssues.Add(('firmware identity missing or differs from load record ({0} vs {1})' -f $idNow,$s.state.fwId))
        }
        $alive = Test-AliveNow -ProjectPath $ProjectPath -Candidates @((Get-FwContract).heartbeat.candidates)
        if (-not $alive.ok) { $preflightIssues.Add(('application heartbeat did not advance: ' + $alive.reason)) }
        $cnt = Get-LoadCount -ProjectPath $ProjectPath
        Out2 ('FRESH   : {0} ({1})' -f $(if ($fresh.ok) { 'selected .out is current for known project inputs' } else { 'selected .out may be stale' }),$fresh.file)
        Out2 ('PREFLIGHT: probe enumerated; core {0}; session pid {1}; source {2}; SHA256 {3}; firmware {4}={5}; heartbeat advancing={6}; loads #{7}; reading' -f `
            $s.state.core,$s.state.pid,$loc.kind,$(if ($curSha) { $curSha.Substring(0,16) } else { 'MISSING' }),$idName,$idNow,$alive.ok,$cnt.count)
        $largs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'ti_c2000_live_read.ps1'),
            '-ProjectPath', $ProjectPath, '-ArrayName', $ArrayName,
            '-Rows', [string]$Rows, '-Columns', [string]$Columns,
            '-FrozenFlag', $FrozenFlag, '-FrozenValue', $FrozenValue, '-SeqVar', $SeqVar,
            '-BankVar', $BankVar, '-Bank0Array', $Bank0Array, '-Bank1Array', $Bank1Array,
            '-HeartbeatExpr', $HeartbeatExpr, '-ParentPid', [string]$PID,
            '-WaitMs', [string]$WaitMs)
        if ($null -ne $ValueMin) { $largs += @('-ValueMin',([double]$ValueMin).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
        if ($null -ne $ValueMax) { $largs += @('-ValueMax',([double]$ValueMax).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
        if ($Quiet) { $largs += '-Quiet' }
        $expectedId = if ($s.state.fwId) { [string]$s.state.fwId } else { '' }
        if ($expectedId) { $largs += @('-ExpectFwId',$expectedId) }
        $largs += @('-FwIdVar',$idName,'-PreflightIssues',($preflightIssues -join ' | '))
        if ($LatestFrame) { $largs += '-LatestFrame' }

        if ($LatestFrame) {
            # Copy, then prove the copy was coherent. live_read already compares $SeqVar
            # before and after the transfer and reports DATA_UNRELIABLE when it moved, so
            # this loop only has to decide whether that verdict is worth another attempt.
            # Anything else (no session, firmware mismatch, dead heartbeat) is not a race
            # and must not be retried.
            $tries = $LatestFrameTries
            $lrc = 4
            for ($t = 1; $t -le $tries; $t++) {
                Out2 ('ATTEMPT : {0}/{1} copy the newest frame, then re-read {2}' -f $t, $tries, $SeqVar)
                $lr = @(& $pwshExe @largs 2>&1)
                $rc = $LASTEXITCODE
                $lrText = (@($lr | ForEach-Object { [string]$_ }) -join "`n")
                if ($rc -eq 0) {
                    foreach ($line in $lr) { Out2 ([string]$line) }
                    $lrc = 0; break
                }
                if ($lrText -notmatch 'FAILURE: FRAME_CHANGED') {
                    foreach ($line in $lr) { Out2 ([string]$line) }
                    $lrc = $rc; break
                }
                if ($t -lt $tries) {
                    Out2 ('RETRY   : {0} moved during the copy - copying again' -f $SeqVar)
                    continue
                }
                Out2 'FAILURE: FRAME_NOT_STABLE'; Out2 'RESULT: FAIL'
                Out2 ('REASON: {0} moved on all {1} copies; the last array.csv is retained with a FAIL verdict' -f $SeqVar,$tries)
            }
        } else {
            & $pwshExe @largs
            $lrc = $LASTEXITCODE
        }
        # Do not exit early: even a failed frame verdict retains array.csv, and the
        # control-period split below can help diagnose the torn copy.

        # Control-period view: what a real control loop consumes is "the N samples taken
        # between two control interrupts", not an arbitrary slice of a buffer. So split the
        # rows that were just written into CycleSamples-wide windows and check the seams:
        # if the DMA switched buffers mid-window, the join would show a large jump.
        if ($CycleSamples -gt 0) {
            $srcCsv = Join-Path $ProjectPath 'readout\data\array.csv'
            if (Test-Path -LiteralPath $srcCsv) {
                # Plain line parsing, not Import-Csv: inside this script the cmdlet raised
                # MetadataError on a file it reads fine standalone (measured 2026-11-16),
                # and the format here is two scalar columns, so there is nothing to gain.
                $raw = [IO.File]::ReadAllLines($srcCsv)
                $vals = New-Object System.Collections.Generic.List[double]
                $rawVals = New-Object System.Collections.Generic.List[string]
                $badValues = 0
                $allInteger = $true
                for ($li = 1; $li -lt $raw.Count; $li++) {
                    $cols = $raw[$li] -split ','
                    $v = 0.0
                    $cell = if ($cols.Count -ge 2) { $cols[1].Trim() } else { '' }
                    if ([double]::TryParse($cell,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$v) -and [double]::IsFinite($v)) {
                        $vals.Add($v); $rawVals.Add($cell)
                        if ($cell -notmatch '^-?\d+$') { $allInteger = $false }
                    } else { $badValues++ }
                }
                $n = $vals.Count
                if ($badValues -gt 0) {
                    Out2 ('SEGMENT : skipped; {0} nonnumeric or nonfinite row(s) in array.csv (original data retained)' -f $badValues)
                } elseif ($n -gt 0) {
                    $cycles = [int][Math]::Ceiling($n / $CycleSamples)
                    $outCsv = Join-Path $ProjectPath 'readout\data\cycles.csv'
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.AppendLine('index,cycle,sample_in_cycle,t_us,raw')
                    for ($i = 0; $i -lt $n; $i++) {
                        $c = [int][Math]::Floor($i / $CycleSamples)
                        $s = $i % $CycleSamples
                        if ($SampleRateHz -gt 0) {
                            $t = [Math]::Round($i * 1000000.0 / $SampleRateHz, 3)
                            [void]$sb.AppendLine(('{0},{1},{2},{3},{4}' -f $i, $c, $s, $t.ToString('R',[Globalization.CultureInfo]::InvariantCulture), $rawVals[$i]))
                        } else {
                            [void]$sb.AppendLine(('{0},{1},{2},,{3}' -f $i, $c, $s, $rawVals[$i]))
                        }
                    }
                    [IO.File]::WriteAllText($outCsv, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

                    $maxDelta = 0
                    $worstAt = -1
                    for ($c = 1; $c -lt $cycles; $c++) {
                        $a = $vals[($c * $CycleSamples) - 1]
                        $b = $vals[$c * $CycleSamples]
                        $d = [Math]::Abs($a - $b)
                        if ($d -gt $maxDelta) { $maxDelta = $d; $worstAt = $c }
                    }
                    $durUs = if ($SampleRateHz -gt 0) { $n * 1000000.0 / $SampleRateHz } else { 0 }
                    $perUs = if ($SampleRateHz -gt 0) { $CycleSamples * 1000000.0 / $SampleRateHz } else { 0 }
                    Out2 ('SEGMENT : {0} cycle(s) x {1} samples = {2} points, {3} us per cycle, {4} us total' -f `
                            $cycles, $CycleSamples, $n, [Math]::Round($perUs, 1), [Math]::Round($durUs, 1))
                    if ($cycles -gt 1) {
                        $unit = if ($allInteger) { ' LSB' } else { ' raw units' }
                        $interpret = if (-not $allInteger) { '  (interpret against the signal scale)' }
                            elseif ($maxDelta -le 8) { '  (continuous)' }
                            elseif ($maxDelta -le 40) { '  (small step, check waveform)' }
                            else { ('  (DISCONTINUITY at cycle ' + $worstAt + ')') }
                        Out2 ('SEAMS   : {0} join(s), max |delta| = {1}{2}{3}' -f ($cycles - 1), $maxDelta, $unit, $interpret)
                    }
                    Out2 ('DATA    : {0}  ({1} rows, columns index,cycle,sample_in_cycle,t_us,raw)' -f $outCsv, ($n + 1))
                }
            }
        }
        exit $lrc
    } finally {
        Exit-TargetLock -ProjectPath $ProjectPath
    }
}

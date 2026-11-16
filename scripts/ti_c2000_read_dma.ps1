#requires -Version 7.0
<#
ti_c2000_read_dma.ps1 -- read a firmware-frozen RAM buffer. Two read modes, one
execution mode (ti_c2000_service.ps1 loads once and keeps running).

  -Mode ReadOnly (default) : never downloads. Attaches to the live session after
        probe, session/target, image/map hashes and firmware RAM proof, then waits
        for the freeze and copies one frozen window. Unprovable RAM is a refusal.
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
    [Parameter(Mandatory)][string]$ArrayName,
    [int]$Rows = 1,
    [int]$Columns = 1,
    [string]$FrozenFlag = 'gDmaReady',
    [string]$FrozenValue = '1',
    [string]$SeqVar = 'gDmaSeq',
    [switch]$FrozenBufferReady,
    [switch]$DmaReady,
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
catch { Out2 'FAILURE: INVALID_CORE_PATTERN'; Out2 'RESULT: FAIL'; exit 2 }
if ($spec.mode -eq 'ReadOnly' -and ($NoProbeCheck -or $AllowUnverified)) {
    Out2 'FAILURE: READ_PROOF_BYPASS'; Out2 'RESULT: FAIL'
    Out2 'REASON: ReadOnly requires the probe and RAM image proofs; bypass switches are disabled'
    exit 2
}

if (-not ($FrozenBufferReady -or $DmaReady)) {
    Out2 'FAILURE: BUFFER_NOT_CONFIRMED'
    Out2 'RESULT: FAIL'
    Out2 'REASON: confirm the firmware fills and freezes this RAM buffer, then pass -FrozenBufferReady'
    exit 2
}
$pathPattern = '[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|->)[A-Za-z_][A-Za-z0-9_]*|\[(?:0|[1-9][0-9]*)\])*'
$heartbeats = @($HeartbeatExpr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$extraNames = @($Variables | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($ArrayName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
    $FrozenFlag -notmatch "^$pathPattern$" -or $FrozenValue -notmatch '^(?:true|[1-9][0-9]*)$' -or
    ($SeqVar -and $SeqVar -notmatch "^$pathPattern$") -or
    $heartbeats.Count -eq 0 -or @($heartbeats | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    @($extraNames | Where-Object { $_ -notmatch "^$pathPattern$" }).Count -gt 0 -or
    $WaitMs -lt 1) {
    Out2 'FAILURE: INVALID_READ_REQUEST'; Out2 'RESULT: FAIL'
    Out2 'REASON: use a simple array/flag/counter name, valid heartbeat candidates and positive wait time'; exit 2
}
if ($Rows -lt 1 -or $Columns -lt 1) { Out2 'FAILURE: BAD_DIMENSIONS'; Out2 'RESULT: FAIL'; Out2 'REASON: Rows/Columns must be positive'; exit 2 }
if ($null -ne $ValueMin -and $null -ne $ValueMax -and $ValueMin -gt $ValueMax) {
    Out2 'FAILURE: BAD_VALUE_RANGE'; Out2 'RESULT: FAIL'; Out2 'REASON: ValueMin exceeds ValueMax'; exit 2
}
$total = [long]$Rows * [long]$Columns
if ($total -gt 100000) { Out2 'FAILURE: ARRAY_TOO_LARGE'; Out2 'RESULT: FAIL'; Out2 'REASON: one capture is limited to 100000 values'; exit 2 }

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) { Out2 'FAILURE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2 }
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
# proving the target still runs our image from RAM.
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
    if (-not $s.state.core -or ($CorePattern -and [string]$s.state.core -notmatch $CorePattern)) {
        Out2 'FAILURE: CORE_UNVERIFIED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: retained session core {0} does not match the requested core pattern {1}' -f $s.state.core,$CorePattern); exit 4
    }
    # same rule as the polled reader: an unplugged probe leaves a live pid behind,
    # so the enumeration is part of "can this session answer at all"
    Assert-ProbeOnline -ProjectPath $ProjectPath -DebugScript $debugScript -CcsRoot $CcsRoot -Skip:$NoProbeCheck -Quiet:$Quiet

    if (-not (Test-Path -LiteralPath $OutFile)) {
        Out2 'FAILURE: NO_OUT_FILE'; Out2 'RESULT: FAIL'; Out2 ('REASON: missing ' + $OutFile); exit 2
    }
    $curSha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    if ($curSha -ne [string]$s.state.outSha256) {
        Out2 'FAILURE: STALE_SERVICE'; Out2 'RESULT: FAIL'
        Out2 ('REASON: the session loaded a different image (session {0}, disk {1})' -f $s.state.outSha256, $curSha)
        Out2 'HINT    : the .out was rebuilt after the load; the frozen window would mix two builds'
        Out2 'HINT    : -Stop the session and start it again (-Start -ConfirmLoad) to load the new image'
        exit 2
    }
    $lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'ReadOnly'
    if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 5 }
    try {
        Initialize-ReadFailureVerdict -ProjectPath $ProjectPath
        Info2 ('JUDGE   : session alive (pid {0}, loaded {1}, LOAD #{2})' -f $s.state.pid, $s.state.started, $(if ($s.state.loadIndex) { $s.state.loadIndex } else { '?' }))
        Info2 ('JUDGE   : image matches this build (sha256 {0})' -f $curSha.Substring(0, 16))
        $fresh = Get-SelectedOutFreshEvidence -ProjectPath $ProjectPath -OutFile $OutFile
        if (-not $fresh.ok) {
            Out2 'FAILURE: STALE_ARTEFACT'; Out2 'RESULT: FAIL'
            Out2 ('REASON: {0}: {1}' -f $fresh.reason,$fresh.file); exit 4
        }
        # Report where the core runs; refuse only when the caller demands RAM.
        # A frozen buffer read in Flash is a legitimate mode, but it must be labelled.
        $loc = Get-RamProofEvidence -ProjectPath $ProjectPath -OutFile $OutFile -MapFile $MapFile -SessionState $s.state
        if ($loc.code -eq 'TARGET_NOT_CONNECTED') {
            Out2 'FAILURE: TARGET_NOT_CONNECTED'; Out2 'RESULT: FAIL'
            Out2 'REASON: the session process is alive and the probe is enumerated, but the target does not answer a symbol-address request - the JTAG link is gone'
            Out2 'HINT    : run -Stop then -Start -ConfirmLoad; a live session cannot reconnect to a board that disappeared and came back'
            Out2 'HINT    : this is an environment fault, so -AllowUnverified does not apply'
            exit 4
        }
        Info2 ('RUNNING : {0}   ({1})' -f $loc.kind,$loc.text)
        if (-not $loc.ok) {
            Out2 'FAILURE: NOT_RAM_IMAGE'; Out2 'RESULT: FAIL'
            Out2 ('REASON: RAM execution proof failed: {0} ({1})' -f $loc.code,$loc.text)
            exit 4
        }
        $idName = [string](Get-FwContract).identity.var
        $idLines = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @($idName)
        $idNow = ''
        foreach ($line in $idLines) {
            $m = [regex]::Match([string]$line,('^V\s+' + [regex]::Escape($idName) + '\s+(\S+)\s*$'))
            if ($m.Success) { $idNow = $m.Groups[1].Value; break }
        }
        if (-not $idNow -or -not $s.state.fwId -or $idNow -ne [string]$s.state.fwId) {
            Out2 'FAILURE: FW_ID_UNREADABLE'; Out2 'RESULT: FAIL'
            Out2 ('REASON: firmware identity is missing or differs from the load record ({0} vs {1})' -f $idNow,$s.state.fwId)
            exit 4
        }
        $alive = Test-AliveNow -ProjectPath $ProjectPath -Candidates @((Get-FwContract).heartbeat.candidates)
        if (-not $alive.ok) {
            Out2 'FAILURE: HEARTBEAT_FAIL'; Out2 'RESULT: FAIL'
            Out2 ('REASON: ' + $alive.reason); exit 4
        }
        $cnt = Get-LoadCount -ProjectPath $ProjectPath
        Out2 ('FRESH   : project inputs are no newer than selected .out ({0})' -f $fresh.file)
        Out2 ('PREFLIGHT: probe online; core {0}; session pid {1}; RAM image {2}; SHA256 {3}; firmware {4}={5}; heartbeat {6} advanced; loads #{7}; reading' -f `
            $s.state.core,$s.state.pid,$loc.region,$curSha.Substring(0,16),$idName,$idNow,$alive.name,$cnt.count)
        $largs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'ti_c2000_live_read.ps1'),
            '-ProjectPath', $ProjectPath, '-ArrayName', $ArrayName,
            '-Rows', [string]$Rows, '-Columns', [string]$Columns,
            '-FrozenFlag', $FrozenFlag, '-FrozenValue', $FrozenValue, '-SeqVar', $SeqVar,
            '-HeartbeatExpr', $HeartbeatExpr, '-ParentPid', [string]$PID,
            '-WaitMs', [string]$WaitMs)
        if ($null -ne $ValueMin) { $largs += @('-ValueMin',([double]$ValueMin).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
        if ($null -ne $ValueMax) { $largs += @('-ValueMax',([double]$ValueMax).ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
        if ($Quiet) { $largs += '-Quiet' }
        $largs += @('-ExpectFwId',[string]$idNow,'-FwIdVar',$idName)
        & $pwshExe @largs
        exit $LASTEXITCODE
    } finally {
        Exit-TargetLock -ProjectPath $ProjectPath
    }
}

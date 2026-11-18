#requires -Version 7.0
<#
ti_c2000_service.ps1 -- the ONE place that loads. RUN MODE decides how often.

Why this exists: every read needs the JTAG session that loaded the RAM image. A
script that connects -> loads -> reads -> disconnects re-flashes the target on
every call, so two consecutive reads never describe the same running program.
Instead the load happens ONCE here, the session is kept open, and each read
(ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1) is a request against that live
session: no reload, no reset, no re-download.

  start : connect -> reset -> loadProgram -> runAsynch -> wait for requests
  read  : write cmd.txt, read res.txt (see ti_c2000_live_read.ps1)
  stop  : write STOP; the DSS script disconnects and exits

RUN MODE (two, see ti_c2000_readmode.ps1):
  SingleStep (default) - load once, run forever, read many. A load restarts the
      program and wears the target, so it happens only after a human said yes:
      -Start needs -ConfirmLoad (ask "是否编译下载并运行" first). A second -Start
      while it runs is a no-op: it reports ALREADY_RUNNING and downloads nothing.
  Iterate - continuous; driven by ti_c2000_iterate.ps1 -UserApproved, which stops
      this session, starts it again with -Build -RunMode Iterate, reads, checks
      -Expect and repeats. Inside an iterate loop this script is off limits to
      everyone else (ITERATE_IN_PROGRESS).

Reads are not part of this script. ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1
attach to the live session (ReadOnly, no download) or download once themselves
(LoadRead, see ti_c2000_readmode.ps1). The target lock keeps a download and a read
from overlapping.

Every successful load increments <project>\readout\load-count.json, so the output
says "LOAD #N" and a runaway reload loop is visible immediately.

State lives in <project>\readout\.service\:
  state.json   pid / out / outSha256 / started / loadIndex (identity of the image)
  ready.txt    written after runAsynch; its presence + a live pid == service up
  cmd.txt      request queue (one file at a time)
  res.txt      response for the last request
  server.log   DSS stdout/stderr

Exit code: 0 OK | 1 runtime failure | 2 environment/argument problem
           3 no probe | 4 load not confirmed by the user | 5 target held elsewhere
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status,
    [string]$Ccxml = '',
    # Physical probe serial to pin at run time. Empty = resolve automatically:
    # $env:TI_C2000_PROBE_SERIAL -> targetConfigs\probe-serial.txt -> xds100serial -l.
    # The project .ccxml is then used as-is when it already pins that serial, otherwise a
    # resolved COPY is generated next to the session and the project file stays portable.
    [string]$ProbeSerial = '',
    # Debug/diagnostic switch: use the .ccxml exactly as written, without resolving the
    # attached probe serial at run time. Needed to run a clean A/B experiment (e.g. does
    # "Only one XDS100" really fail?), because the resolver would otherwise rewrite it.
    [switch]$NoProbeResolve,
    [string]$OutFile = '',
    [string]$MapFile = '',
    # The gate refuses only when the .out entry symbol CONFLICTS with the .cproject
    # declaration (linkerID.ENTRY_POINT). It is NOT a check for "_c_int00": that earlier
    # wording was a misdiagnosis (see ram-and-linker.md 入口点). Set this switch only for a
    # symbol you have verified on this board, bypassing the conflict check.
    [switch]$AllowNonDefaultEntry,
    [string]$CcsRoot = '',
    # Which CPU to open. Empty = choose automatically:
    #   single C28xx core      -> that core (all single-core parts)
    #   several C28xx cores    -> C28xx_CPU1, with a note saying so (F28379D is dual-core)
    #   nothing identifiable   -> USAGE: AMBIGUOUS_CORE, list the names and stop
    # A hard-coded 'CPU1' default would silently open the wrong core on a CPU2 project,
    # and no default at all made every dual-core -Start fail. Automatic selection with an
    # explicit note is the only form that works on both.
    [string]$CorePattern = '',
    [switch]$Build,
    # set this only after the user answered yes to "compile/download and run?"
    [switch]$ConfirmLoad,
    # SingleStep = load once and stay (default). Iterate = continuous, driven by
    # ti_c2000_iterate.ps1 -UserApproved, which passes -RunMode Iterate every round.
    # no [ValidateSet]: an illegal value must reach Resolve-RunModeSpec, which reports
    # USAGE: INVALID_RUN_MODE (exit 2). A binding-time rejection exits 1 with an English
    # message, and the documented classification would be unreachable.
    [string]$RunMode = 'SingleStep',
    [switch]$UserApproved,
    [int]$StartTimeoutSec = 90,
    # -Status enumerates the JTAG probe by default: the session process outlives the USB
    # link, so "RUNNING" alone is how a dead board looks healthy (measured 2026-11-15).
    # -NoProbeCheck skips the ~1 s enumeration when you only want the state files.
    [switch]$NoProbeCheck,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')

$modes = @($Start, $Stop, $Status) | Where-Object { $_ }
if ($modes.Count -ne 1) {
    Out2 'USAGE: NEED_MODE'; Out2 'RESULT: FAIL'
    Out2 'REASON: pass exactly one of -Start / -Stop / -Status'; exit 2
}

if (-not (Test-Path (Join-Path $ProjectPath '.cproject'))) {
    Out2 'USAGE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName

# ---- identity + hygiene ------------------------------------------------------
# -Start writes the target, so a stale copy of a skill script inside the project is a
# hard refusal there (that copy is what would decide the download); -Stop/-Status only
# report it. Either way the run is stamped into readout\skill-runs.jsonl, which is how
# a later check can prove the operation came from this skill.
if ($Start) {
    Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_service.ps1' -Mode 'Start' -Block -Quiet:$Quiet
} elseif ($Stop) {
    Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_service.ps1' -Mode 'Stop' -Quiet:$Quiet
} else {
    Initialize-SkillRun -ProjectPath $ProjectPath -Script 'ti_c2000_service.ps1' -Mode 'Status'
}

# ---- run mode ----------------------------------------------------------------
# SingleStep (default) or Iterate (continuous, only via ti_c2000_iterate.ps1).
# -Status is pure reporting and stays available; Start/Stop must not fight a
# running iterate loop over the same target.
$runSpec = Resolve-RunModeSpec -RunMode $RunMode -ConfirmLoad:$ConfirmLoad -UserApproved:$UserApproved -MaxLoads 1
try { if ($CorePattern) { [void][regex]::new($CorePattern) } }
catch { Out2 'USAGE: INVALID_CORE_PATTERN'; Out2 'RESULT: FAIL'; exit 2 }
if (-not $Status) {
    $opName = if ($Start) { 'service -Start' } else { 'service -Stop' }
    Assert-RunModeInterlock -ProjectPath $ProjectPath -What $opName
}

$svcDir = Join-Path $ProjectPath 'readout\.service'
$stateFile = Join-Path $svcDir 'state.json'
$readyFile = Join-Path $svcDir 'ready.txt'
$stoppedFile = Join-Path $svcDir 'stopped.txt'
$errorFile = Join-Path $svcDir 'error.txt'
$cmdFile = Join-Path $svcDir 'cmd.txt'
$resFile = Join-Path $svcDir 'res.txt'
$coreFile = Join-Path $svcDir 'core.txt'
$logFile = Join-Path $svcDir 'server.log'

function Get-ServiceState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) } catch { return $null }
}
function Test-ServiceAlive {
    $st = Get-ServiceState
    if (-not $st) { return $false }
    if (-not (Test-Path -LiteralPath $readyFile)) { return $false }
    if (Test-Path -LiteralPath $stoppedFile) { return $false }
    $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    return $true
}

$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

# Learned probe wait (ti_c2000_probe.ps1): 5 s first, +5 s per failure, bisected against the
# last remembered failure. Probes differ in how long Windows takes to enumerate them
# after the DSS process releases the handle, so a fixed window turns a normal
# re-enumeration into a false "the probe went missing" report.
. (Join-Path $PSScriptRoot 'ti_c2000_probe.ps1')

# ---------------------------------------------------------------- status -----
if ($Status) {
    $st = Get-ServiceState
    $cnt = Get-LoadCount -ProjectPath $ProjectPath
    if (Test-ServiceAlive) {
        # sessions started before the counter existed have no loadIndex; if the
        # image matches the last counted download we can still name it
        $idx = $st.loadIndex
        if (-not $idx -and $st.outSha256 -and $st.outSha256 -eq $cnt.lastSha256) { $idx = $cnt.count }
        Out2 ('SERVICE : RUNNING (pid {0}, since {1})' -f $st.pid, $st.started)
        if (-not $NoProbeCheck) {
            # the process survives an unplugged probe, so "RUNNING" alone cannot answer
            # "can I still read?" - enumerate the hardware and say so (measured 2026-11-15:
            # pid alive, XDS100 gone, every read refused with NO_PROBE)
            $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'ti_c2000_debug.ps1'),
                '-ProjectPath', $ProjectPath, '-ProbeCheckOnly')
            if ($CcsRoot) { $pa += @('-CcsRoot', $CcsRoot) }
            $po = @(& $pwshExe @pa 2>&1)
            if ($LASTEXITCODE -eq 0) {
                foreach ($l in $po) { if ([string]$l -match '^PROBE') { Out2 ([string]$l) } }
            } else {
                Out2 'PROBE   : NOT FOUND - Windows enumerates no JTAG probe; the session process is alive but cannot reach the target'
                Out2 'HINT    : check the USB cable / board power, then run -Stop and start the session again'
            }
        }
        $rm = if ($st.runMode) { [string]$st.runMode } else { 'SingleStep' }
        # runMode=Iterate in the state file only means "a loop put this image here"; whether
        # a loop is running NOW is the marker's job (see Get-RunModeInfo)
        $miLive = Get-RunModeInfo -ProjectPath $ProjectPath
        $rmText = if ($miLive.active) { 'Iterate (continuous - a loop owns the target)' }
                  elseif ($rm -eq 'Iterate') { 'SingleStep (image left by a finished continuous run; reads attach)' }
                  else { 'SingleStep (load once, run forever; reads attach)' }
        Out2 ('RUN MODE: {0}' -f $rmText)
        Out2 ('LOAD    : #' + $(if ($idx) { $idx } else { '?' }) + ' (this session)')
        Out2 ('LOADS   : #{0} total for this project, last at {1}' -f $cnt.count, $cnt.lastLoad)
        Out2 ('OUT     : {0}' -f $st.out)
        Out2 ('CORE    : {0}' -f $st.core)
        Out2 ('SHA256  : {0}' -f $st.outSha256)
        Out2 ('DIR     : {0}' -f $svcDir)
        Out2 'RESULT: OK'
        exit 0
    }
    $mi = Get-RunModeInfo -ProjectPath $ProjectPath
    Out2 'SERVICE : STOPPED'
    if ($mi.active) {
        Out2 ('RUN MODE: Iterate (continuous run in progress, pid {0}, round {1}/{2})' -f $mi.pid, $mi.round, $mi.maxLoads)
    } else {
        $lastRm = if ($cnt.lastMode -eq 'Iterate') { 'Iterate (last download was a continuous round)' } else { 'SingleStep' }
        Out2 ('RUN MODE: {0} - no session right now' -f $lastRm)
    }
    Out2 ('LOADS   : #{0} total for this project, last at {1}' -f $cnt.count, $cnt.lastLoad)
    if (Test-Path -LiteralPath $logFile) { Out2 ('LAST LOG: {0}' -f $logFile) }
    Out2 'RESULT: OK'
    exit 0
}

# ----------------------------------------------------------------- stop ------
if ($Stop) {
    if (-not (Test-ServiceAlive)) {
        foreach ($f in @($readyFile, $stateFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        Out2 'SERVICE : ALREADY_STOPPED'
        Out2 'RESULT: OK'
        exit 0
    }
    $lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'Stop'
    if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 4 }
    $st = Get-ServiceState
    # ask the DSS script to leave its loop and disconnect, so the probe is released
    [IO.File]::WriteAllText($cmdFile, 'STOP', [Text.Encoding]::ASCII)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if ($alive) {
        # the loop is stuck; kill the process tree so the probe is not held open
        & cmd.exe /d /c "taskkill /PID $($st.pid) /T /F" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        Info2 'NOTE    : service did not stop on request; process tree killed'
    }
    $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if ($alive) {
        Exit-TargetLock -ProjectPath $ProjectPath
        Out2 'FAILURE: STOP_FAILED'; Out2 'RESULT: FAIL'
        Out2 ('REASON: DSS pid {0} survived the STOP request and forced termination; state files were retained' -f $st.pid)
        exit 1
    }
    $cleanStop = (-not $alive) -and (Test-Path -LiteralPath $stoppedFile)
    if (-not $alive) { Mark-ProbeReleased -ProjectPath $ProjectPath -Ccxml ([string]$st.ccxml) }
    foreach ($f in @($cmdFile, $resFile, $readyFile, $stateFile)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    # On the observed XDS100 setup, releasing the DSS process also releases the FTDI
    # handle and the probe temporarily disappears from PnP. Other probes may differ.
    # Wait for Windows enumeration after DSS releases its handle. This callback does not
    # open a DSS target, so a PnP hit is not yet proof that the probe is usable.
    $debugScript = Join-Path $PSScriptRoot 'ti_c2000_debug.ps1'
    $probeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$debugScript,
        '-ProjectPath',$ProjectPath,'-ProbeCheckOnly','-Quiet')
    if ($CcsRoot) { $probeArgs += @('-CcsRoot',$CcsRoot) }
    $probeBack = $false
    if (-not $alive) {
        $probeBack = Wait-ProbeUsable -ProjectPath $ProjectPath -ProbeCheck {
            $o = @(& $pwshExe @probeArgs 2>&1)
            return ($LASTEXITCODE -eq 0 -and (@($o | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count -gt 0))
        } -Ccxml ([string]$st.ccxml) -MaxSeconds 90
    }
    if ($probeBack) {
        Info2 'PROBE   : enumerated again after the session exited; DSS access is checked on the next Start'
    } else {
        Out2 'WARN    : the probe was not observed after Stop (or the DSS process still owns it)'
        Out2 'WARN    : inspect the USB and driver state; no cable or power cause is proven here'
    }
    $cnt = Get-LoadCount -ProjectPath $ProjectPath
    Exit-TargetLock -ProjectPath $ProjectPath
    if (-not $cleanStop) {
        Out2 'FAILURE: STOP_UNCLEAN'; Out2 'RESULT: FAIL'
        Out2 'REASON: DSS did not write stopped.txt after disconnect; the process was forced down or exited early'
        exit 1
    }
    if (-not $probeBack) {
        Out2 'FAILURE: PROBE_NOT_READY'; Out2 'RESULT: FAIL'
        Out2 'REASON: DSS stopped, but Windows did not enumerate the probe within the wait budget'
        exit 3
    }
    Out2 'SERVICE : STOPPED'
    Out2 ('LOADS   : #{0} kept (the next -Start would be load #{1})' -f $cnt.count, ([int]$cnt.count + 1))
    Out2 'RESULT: OK'
    exit 0
}

# ---------------------------------------------------------------- start ------
if (Test-ServiceAlive) {
    $st = Get-ServiceState
    $cnt0 = Get-LoadCount -ProjectPath $ProjectPath
    Out2 ('SERVICE : ALREADY_RUNNING (pid {0})' -f $st.pid)
    Out2 ('LOAD    : #' + $(if ($st.loadIndex) { $st.loadIndex } else { '?' }) + ' is still the loaded image - no download happened')
    Out2 ('LOADS   : #{0} total for this project' -f $cnt0.count)
    if ($Build) { Out2 'NOTE    : -Build ignored, the running session already holds a loaded image; stop it first to reload' }
    Out2 'RESULT: OK'
    exit 0
}

# ---- download guard ----------------------------------------------------------
# A load rewrites the whole image, restarts the program and wears the target. The
# only execution mode never does that without a human saying yes first. Reads are
# never affected: they attach to the session and never come through here.
if (-not $ConfirmLoad) {
    $cnt = Get-LoadCount -ProjectPath $ProjectPath
    Out2 'FAILURE: LOAD_NOT_CONFIRMED'
    Out2 'RESULT: FAIL'
    Out2 'REASON: nothing was written to the target - this start would compile/download and restart the program'
    Out2 ('HINT    : ask the user "是否编译下载并运行？" first, then re-run the same command with -ConfirmLoad (next download would be #' + ([int]$cnt.count + 1) + ')')
    if ($runSpec.continuous) { Out2 'HINT    : continuous mode also needs -UserApproved; ti_c2000_iterate.ps1 passes both for you' }
    Out2 'HINT    : reading does not need this - ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1 attach to a running session (-Mode ReadOnly)'
    exit 4
}

# ---- stale-artefact guard ----------------------------------------------------
# build.ps1 keeps its product in %TEMP% unless -Stage is given, while -Start loads
# <project>\Debug\*.out. So "-Start -ConfirmLoad" without -Build can load a build that
# predates the current sources, and the failure looks like broken firmware: measured
# 2026-11-15, a 20:23 .out was loaded at 21:48 while the sources had been edited at
# 21:42, and every read of the new DMA symbols failed with "identifier not found".
# Warn loudly instead of letting a stale image look like a code bug.
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
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) {
    Out2 'USAGE: NO_CCXML'; Out2 'RESULT: FAIL'; Out2 'REASON: no .ccxml found; pass -Ccxml <file>'; exit 2
}
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }

# Judge the exact image that DSS will load. A different, newer *.out in Debug must
# never excuse a stale -OutFile (nor condemn a current one).
if (-not $Build) { Assert-SelectedOutFresh -ProjectPath $ProjectPath -OutFile $OutFile }

$skillRoot = Split-Path $PSScriptRoot -Parent
$debugScript = Join-Path $skillRoot 'scripts\ti_c2000_debug.ps1'
if (-not (Test-Path -LiteralPath $debugScript)) {
    Out2 'FAILURE: ENV_NO_DEBUG_SCRIPT'; Out2 'RESULT: FAIL'
    Out2 'REASON: ti_c2000_debug.ps1 is missing from this skill installation'; exit 1
}

$probeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $debugScript, '-ProjectPath', $ProjectPath, '-ProbeCheckOnly')
if ($CcsRoot) { $probeArgs += @('-CcsRoot', $CcsRoot) }
# Learned wait, not a fixed window: 5 s first, +5 s per failure, starting next time from the
# bisection of the last success and the last failure. Adapters differ (FTDI XDS100v2, CDC
# XDS110, XDS200), so a number tuned on one of them turns a normal USB re-enumeration into a
# false "the probe is gone / the board is under-powered" report on another.
$script:c2000ProbeOut = @()
$script:c2000ProbeCode = 1
$script:c2000ProbeText = ''
$probeOk = Wait-ProbeUsable -ProjectPath $ProjectPath -ProbeCheck {
    $o = @(& $pwshExe @probeArgs 2>&1)
    $script:c2000ProbeOut = $o
    $script:c2000ProbeCode = $LASTEXITCODE
    $script:c2000ProbeText = (@($o | ForEach-Object { [string]$_ }) -join "`n")
    return ($LASTEXITCODE -eq 0 -and $script:c2000ProbeText -match 'RESULT: OK')
} -Ccxml $Ccxml -MaxSeconds 90
$probeOut = @($script:c2000ProbeOut)
$probeCode = [int]$script:c2000ProbeCode
$probeText = [string]$script:c2000ProbeText
if (-not $probeOk) {
    foreach ($line in $probeOut) { Out2 ([string]$line) }
    if ($probeText -match 'NO_PROBE') {
        Out2 'FAILURE: NO_PROBE'; Out2 'RESULT: FAIL'
        Out2 'REASON: Windows did not enumerate the probe within the learned wait budget; driver access was not tested'
        Out2 'HINT    : readout\.service\probe-wait.json records okMs/failMs; a slow first run on a new adapter is normal'
        Out2 'HINT    : inspect enumeration and the DSS log before diagnosing hardware'
        exit 3
    }
    Out2 'FAILURE: PROBE_CHECK_FAILED'; Out2 'RESULT: FAIL'; Out2 'REASON: probe pre-check did not return RESULT: OK'; exit 3
}
if ($Build) {
    $buildScript = Join-Path $skillRoot 'scripts\ti_c2000_build.ps1'
    $bargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $ProjectPath, '-Stage', '-KeepLaunches')
    if ($CcsRoot) { $bargs += @('-CcsRoot', $CcsRoot) }
    Info2 'STEP    : build'
    $bout = & $pwshExe @bargs 2>&1
    $bcode = $LASTEXITCODE
    foreach ($line in $bout) { if (-not $Quiet -and [string]$line -notmatch '^RESULT:') { Out2 ([string]$line) } }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail; Out2 'RESULT: FAIL'; Out2 'REASON: build failed - service not started'; exit 1
    }
    Info2 'BUILD   : OK (this is the one compile for the session)'
}
if (-not (Test-Path -LiteralPath $OutFile)) {
    Out2 'FAILURE: NO_OUT_FILE'; Out2 'RESULT: FAIL'
    Out2 "REASON: '$OutFile' not found - add -Build or build/stage first"; exit 4
}
Assert-SelectedOutFresh -ProjectPath $ProjectPath -OutFile $OutFile
if (-not $MapFile) { $MapFile = [IO.Path]::ChangeExtension($OutFile, '.map') }
$mapSha = ''
if (-not (Test-Path -LiteralPath $MapFile)) {
    Out2 ('NOTE    : linker map unavailable: ' + $MapFile + '; location will be UNKNOWN, download may proceed')
    $MapFile = ''
} else {
    $MapFile = (Get-Item -LiteralPath $MapFile).FullName
    $mapSha = (Get-FileHash -LiteralPath $MapFile -Algorithm SHA256).Hash
}
if ($MapFile -and [Math]::Abs(((Get-Item -LiteralPath $MapFile).LastWriteTimeUtc - (Get-Item -LiteralPath $OutFile).LastWriteTimeUtc).TotalSeconds) -gt 120) {
    # Reported, not refused. A timestamp gap means the map MAY describe a different build;
    # the readers report it as source metadata and the data judgements still run. Blocking
    # here only prevented a download the board was perfectly able to accept.
    Out2 'NOTE    : .map and .out timestamps differ by more than two minutes - the map may describe a different build'
}

# ---- entry-point gate (HARD) -------------------------------------------------
# Measured twice in this project (2026-11-15 and again 2026-11-18):
#   * built with the linker default _c_int00  -> a normal 0x16a8 .text write, loads fine
#   * built with -EntryPoint code_start       -> the first write becomes Length 0x800
#     (one RAMLS block), fails with -1041 + FTDI -150, and leaves the core in a state
#     where a further load reports 'Target reset failed. Error: -1' until retried.
# The 2026-11-18 failure came from SKILL.md itself telling callers to pass
# -EntryPoint code_start; the other conversation followed it exactly. That doc line was
# wrong and has been corrected. A warning was not enough protection while the doc said
# otherwise, so this gate refuses such an image at the entry, before the board is touched.
# A project that genuinely needs another entry symbol must say so explicitly.
if ($MapFile -and -not $AllowNonDefaultEntry) {
    $mapTxt = ''
    try { $mapTxt = [IO.File]::ReadAllText($MapFile) } catch { }
    $em = [regex]::Match($mapTxt, 'ENTRY POINT SYMBOL:\s*"([^"]+)"')
    if ($em.Success) {
        $entrySym = $em.Groups[1].Value
        # `.cproject` 的 linkerID.ENTRY_POINT 是工程自己声明的权威值；与它一致就放行。
        # 2026-11-18 事故：本工程声明 code_start，一份 code_start 镜像（LOAD #103、#116 用的）
        # 曾被这里无条件拒绝——把唯一能成功的镜像挡在门外。判据必须是"与声明冲突"，不是"不是 _c_int00"。
        $declaredEntrySym = ''
        try {
            $cpPath = Join-Path $ProjectPath '.cproject'
            if (Test-Path -LiteralPath $cpPath) {
                $cpTxt = [IO.File]::ReadAllText($cpPath)
                $dm = [regex]::Match($cpTxt, 'linkerID\.ENTRY_POINT[^>]*\bvalue="([^"]+)"')
                if ($dm.Success) { $declaredEntrySym = $dm.Groups[1].Value }
            }
        } catch { }
        if ($entrySym -ne '_c_int00' -and $entrySym -ne $declaredEntrySym) {
            Out2 'FAILURE: NON_DEFAULT_ENTRY_POINT'
            Out2 'RESULT: FAIL'
            Out2 ("REASON: the .out entry symbol '{0}' conflicts with the .cproject declaration '{1}'" -f $entrySym, $(if ($declaredEntrySym) { $declaredEntrySym } else { 'none' }))
            Out2 ("        map: {0}" -f $MapFile)
            Out2 'FIX     : rebuild so the link uses --entry_point=<declared>. build.ps1 does this automatically'
            Out2 '          (long form only - the short form "-e <sym>" is swallowed by cl2000, which leaves the'
            Out2 '          .out on _c_int00 while the log claims otherwise; that mismatch is what produced the'
            Out2 '          0x800-word .text pieces and -1041 / FTDI -150 on 2026-11-18).'
            Out2 'FIX     : confirm build.ps1 printed "entry point verified in map".'
            Out2 '          Pass -AllowNonDefaultEntry only for a symbol you have verified on this board.'
            exit 4
        }
        Info2 ("ENTRY    : {0} (matches the .cproject declaration)" -f $entrySym)
    } else {
        Out2 'NOTE    : the map has no ENTRY POINT SYMBOL line - entry point could not be checked'
    }
}

$ccsPath = ''
if ($probeText -match '(?m)^CCS\s*:\s*(.+?)\s+\(v') { $ccsPath = $Matches[1].Trim() }
if (-not $ccsPath -and $CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) { $ccsPath = (Get-Item -LiteralPath $CcsRoot).FullName }
if (-not $ccsPath) { Out2 'FAILURE: ENV_NO_CCS'; Out2 'RESULT: FAIL'; Out2 'REASON: cannot resolve CCS; pass -CcsRoot'; exit 1 }
$dss = Join-Path $ccsPath 'ccs_base\scripting\bin\dss.bat'
if (-not (Test-Path -LiteralPath $dss)) { Out2 'FAILURE: ENV_NO_DSS'; Out2 'RESULT: FAIL'; Out2 "REASON: dss.bat not found under '$ccsPath'"; exit 1 }

# ---- resolve the probe serial at run time ------------------------------------
# The project .ccxml is NOT required to name a serial (it would tie the project to one
# physical probe). Priority: -ProbeSerial -> $env:TI_C2000_PROBE_SERIAL ->
# targetConfigs\probe-serial.txt -> xds100serial -l (physical identity) -> .ccxml as-is.
# When the resolved serial differs from what the project file pins, a resolved COPY is
# written under readout\.service and handed to DSS; the project file is never modified.
# This is what makes the same project work with any attached probe.
$ccxmlOriginal = $Ccxml
# ---------------------------------------------------------------------------
# 探针确认（串号的唯一用途）。
#   上机前自动识别"现在插着哪一块"，把它的串号写进工程 .ccxml，让 DSS 精确寻址
#   一块已知设备，而不是去枚举（枚举在多残留实例的机器上会 -215 semaphore timeout，
#   同路径 A/B 实测两次复现）。除此之外，编译/下载/读取/判据/报告都不引用串号。
#   读不到串号时**什么都不改**，也不判失败——那不是错误，只是没有身份信息。
# ---------------------------------------------------------------------------
if ($NoProbeResolve) {
    $attachedInfo = @(Get-AttachedProbeSerials -CcsPath $ccsPath `
        -Xds100Tool (Join-Path $ccsPath 'ccs_base\common\uscif\xds100serial.exe'))
    if ($attachedInfo.Count -gt 0) {
        Info2 ('PROBE   : attached {0}' -f (($attachedInfo | ForEach-Object { $_.Model + '/' + $_.Serial }) -join ', '))
    }
    Info2 'PROBE   : confirmation skipped (-NoProbeResolve); ccxml used verbatim'
    $resolvedCfg = [pscustomobject]@{ Serial = ''; SerialSource = 'disabled'; Changed = $false; Path = $Ccxml; Ok = $true; Note = '' }
} else {
    $resolvedCfg = Sync-ProbeSerialToCcxml -ProjectPath $ProjectPath -Ccxml $Ccxml -Serial $ProbeSerial `
        -CcsPath $ccsPath -Xds100Tool (Join-Path $ccsPath 'ccs_base\common\uscif\xds100serial.exe')
    if ($resolvedCfg.Serial) {
        Info2 ('PROBE   : confirmed {0} (source={1}) - identity only, no other check depends on it' -f $resolvedCfg.Serial, $resolvedCfg.SerialSource)
    }
    if ($resolvedCfg.Changed) {
        Info2 ('CCXML   : serial written into the project .ccxml (previous copy kept as .bak)')
    } elseif ($resolvedCfg.Note) {
        Info2 ('NOTE    : ' + $resolvedCfg.Note)
    }
}
if ($resolvedCfg.Serial) {
    Info2 ('PROBE   : serial {0} (source={1})' -f $resolvedCfg.Serial, $resolvedCfg.SerialSource)
}
if ($resolvedCfg.Path -ne $ccxmlOriginal) {
    $Ccxml = $resolvedCfg.Path
    Info2 ('CCXML   : resolved copy -> {0}' -f $Ccxml)
    Info2 'CCXML   : project file untouched (portable; see targetConfigs\probe-serial.txt)'
} elseif ($resolvedCfg.Note) {
    Info2 ('NOTE    : ' + $resolvedCfg.Note)
}

New-Item -ItemType Directory -Path $svcDir -Force | Out-Null
# from here on the target is being taken: hold the lock so no read can attach while
# the image is being written (checked after the cheap build/probe work on purpose)
$lk = Enter-TargetLock -ProjectPath $ProjectPath -Mode 'Start'
if (-not $lk.ok) { foreach ($l in $lk.message) { Out2 $l }; exit 4 }
foreach ($f in @($readyFile, $stoppedFile, $errorFile, $cmdFile, $resFile, $coreFile, $stateFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
$outSha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash

# forward slashes: the DSS script is JavaScript, not PowerShell
$workJs = $svcDir.Replace('\', '/')
$ccxmlJs = (Get-Item -LiteralPath $Ccxml).FullName.Replace('\', '/')
$outJs = (Get-Item -LiteralPath $OutFile).FullName.Replace('\', '/')
$coreJs = $CorePattern.Replace('\', '\\').Replace('"', '\"')

$jsPath = Join-Path $svcDir 'server.js'
$js = @'
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);

var WORK  = "__WORK__";
var CCXML = "__CCXML__";
var OUT   = "__OUT__";
var CORE  = "__CORE__";

function sleepMs(ms) { java.lang.Thread.sleep(ms); }
function exists(p) { return (new java.io.File(p)).exists(); }
// Rhino cannot call java.nio.file.Paths.get (varargs), so plain java.io it is
function readText(p) {
    try {
        var r = new java.io.BufferedReader(new java.io.InputStreamReader(new java.io.FileInputStream(p), "UTF-8"));
        var sb = "", line;
        while ((line = r.readLine()) !== null) { sb += line + "\n"; }
        r.close();
        return sb;
    } catch (e) { return ""; }
}
// File.delete() cannot be called from Rhino ("delete" is a JS keyword); toPath()
// is argument-free, so delete through java.nio instead.
function deleteFile(p) {
    try {
        var f = new java.io.File(p);
        if (f.exists()) { java.nio.file.Files.deleteIfExists(f.toPath()); }
    } catch (e) { }
}
function writeText(p, s) {
    var tmp = p + ".tmp";
    var w = new java.io.BufferedWriter(new java.io.OutputStreamWriter(new java.io.FileOutputStream(tmp), "UTF-8"));
    w.write("" + s);
    w.close();
    deleteFile(p);
    var src = new java.io.File(tmp), dst = new java.io.File(p);
    if (!src.renameTo(dst)) {
        var w2 = new java.io.BufferedWriter(new java.io.OutputStreamWriter(new java.io.FileOutputStream(p), "UTF-8"));
        w2.write("" + s);
        w2.close();
    }
}
function removeIfExists(p) { deleteFile(p); }

var env = ScriptingEnvironment.instance();
try { env.setScriptTimeout(0); } catch (eT) { }
var server = env.getServer("DebugServer.1");
server.setConfig(CCXML);
var cpuList = server.getListOfCPUs();
var cpuMatches = [];

if (CORE) {
    var cpuPattern = new RegExp(CORE);
    for (var ci = 0; ci < cpuList.length; ci++) {
        if (cpuPattern.test("" + cpuList[ci])) { cpuMatches.push("" + cpuList[ci]); }
    }
} else {
    // No pattern: pick one instead of demanding one. getListOfCPUs() on an F28379D returns
    // C28xx_CPU1, C28xx_CPU2, CLA cores and more, so "match everything" can never work;
    // and a hard-coded CPU1 would open the wrong core on a CPU2-only project. So:
    //   exactly one C28xx core  -> use it (every single-core part)
    //   several C28xx cores     -> CPU1, and say so (dual-core part, CPU1 is the default run)
    var c28 = [];
    for (var cj = 0; cj < cpuList.length; cj++) {
        if (("" + cpuList[cj]).indexOf("C28xx") >= 0) { c28.push("" + cpuList[cj]); }
    }
    if (c28.length === 1) {
        cpuMatches = [c28[0]];
    } else if (c28.length > 1) {
        var cpu1 = [];
        for (var ck = 0; ck < c28.length; ck++) {
            if (/C28xx_CPU1$/.test(c28[ck])) { cpu1.push(c28[ck]); }
        }
        if (cpu1.length === 1) {
            cpuMatches = [cpu1[0]];
            print("DSS: dual-core device - selected CPU1 (pass -CorePattern '.*C28xx_CPU2$' for CPU2)");
        }
    }
}

if (cpuMatches.length !== 1) {
    // Name what was actually enumerated: without it the user cannot tell whether the
    // pattern was too loose or the target simply has several cores.
    var allNames = [];
    var c28Count = 0;
    for (var cn = 0; cn < cpuList.length; cn++) {
        allNames.push("" + cpuList[cn]);
        if (("" + cpuList[cn]).indexOf("C28xx") >= 0) { c28Count++; }
    }
    var hint = "pass -CorePattern for exactly one target core";
    if (c28Count > 1) {
        // Dual-core part (F28379D enumerates C28xx_CPU1 and C28xx_CPU2 plus CLA cores).
        // Say so, and name the two patterns that matter, instead of a generic complaint.
        hint = "this is a dual-core device (F28379D): use '.*C28xx_CPU1$' for CPU1 or '.*C28xx_CPU2$' for CPU2";
    }
    writeText(WORK + "/error.txt", "AMBIGUOUS_CORE matched " + cpuMatches.length + " of [" + allNames.join(" | ") + "]; " + hint);
    throw "expected exactly one CPU, got " + cpuMatches.length;
}
var session = server.openSession(cpuMatches[0]);
var actualCpu = "" + session.getCPUName();
// getListOfCPUs() hands back the short form ("C28xx_CPU1") while getCPUName() returns
// the full path ("Texas Instruments XDS100v2 USB Debug Probe_0/C28xx_CPU1"), so a strict
// !== reports CORE_MISMATCH for the very CPU that was just opened (measured 2026-11-16).
// Accept either direction of substring containment.
if (actualCpu !== cpuMatches[0] && actualCpu.indexOf(cpuMatches[0]) < 0 && cpuMatches[0].indexOf(actualCpu) < 0) {
    writeText(WORK + "/error.txt", "CORE_MISMATCH opened " + actualCpu + " instead of " + cpuMatches[0]);
    throw "DSS opened a different CPU";
}
writeText(WORK + "/core.txt", actualCpu);
// Do NOT set realtime options before connect. A fresh session is already realtime-off;
// loadti.bat never sets them and connects fine, while setting PoliteRealtimeMode(true)
// here made a running core reject connect with -1133. They are switched ON only after
// load+run (see below), once the session exists to serve ReadOnly variable reads.
// Note: options are readonly until the target is connected, so this is not the place
// to force them false either - leaving them untouched IS the loadti behaviour.

// connect() returning normally does NOT prove the link is up: measured 2026-11-15, it
// returned cleanly and the very next reset() failed with "target is not connected", after
// which every load attempt operated on a dead link. So verify with an operation that must
// touch the target (isHalted) and retry the whole connect when it throws.
//__BOOT__
// connect / reset / load / run come from ti_c2000_dss_boot.js, shared with the two
// one-shot readers. Writing error.txt here (not inside the shared code) keeps each
// entry point's wording its own.
if (!dssConnectVerified(session, print)) {
    writeText(WORK + "/error.txt", "CONNECT_FAILED the link never became usable");
    throw "connect failed";
}
if (!dssResetVerified(session, print)) {
    writeText(WORK + "/error.txt", "RESET_FAILED the target refused reset");
    throw "reset failed";
}
if (!dssLoadWithRetry(session, OUT, print)) {
    writeText(WORK + "/error.txt", "LOAD_FAILED memory.loadProgram failed after 3 attempts");
    throw "load failed";
}
if (!dssRunVerified(session, print, 300)) {
    writeText(WORK + "/error.txt", "TARGET_HALTED_AFTER_RUN");
    throw "halted after run";
}
// The image is loaded and the core is running. Now turn realtime back on so the
// ReadOnly readers attached to this session can read variables without halting it.
// Keeping these on during connect caused -1133; setting them only here is the point.
try { session.options.setBoolean("AllowInterruptsWhenHalted", true); } catch (eA) { print("DSS: AllowInterruptsWhenHalted on failed: " + eA); }
try { session.options.setBoolean("PoliteRealtimeMode", true); } catch (eR) { print("DSS: PoliteRealtimeMode on failed: " + eR); }
writeText(WORK + "/ready.txt", "ready");
print("SERVICE: READY");

var running = true;
while (running) {
    var cmdPath = WORK + "/cmd.txt";
    if (!exists(cmdPath)) { sleepMs(60); continue; }
    var cmd = readText(cmdPath).replace(/\s+$/, "");
    removeIfExists(cmdPath);
    if (cmd.length === 0) { continue; }
    if (cmd === "STOP") {
        running = false;
        break;
    }

    var out = [];
    var halted = session.target.isHalted();
    out.push("HALTED " + (halted ? "1" : "0"));
    try {
        if (cmd.indexOf("PING") === 0) {
            out.push("END");
        } else if (cmd.indexOf("ADDR ") === 0) {
            var syms = cmd.substring(5).split("|");
            for (var si = 0; si < syms.length; si++) {
                if (!syms[si]) { continue; }
                try { out.push("P " + syms[si] + " " + session.symbol.getAddress(syms[si])); }
                catch (eP) { out.push("E " + syms[si] + " " + eP); }
            }
            out.push("END");
        } else if (cmd.indexOf("VARS ") === 0) {
            var vs = cmd.substring(5).split("|");
            for (var vi = 0; vi < vs.length; vi++) {
                if (!vs[vi]) { continue; }
                try { out.push("V " + vs[vi] + " " + session.expression.evaluate(vs[vi])); }
                catch (eV) { out.push("E " + vs[vi] + " " + eV); }
            }
            out.push("END");
        } else if (cmd.indexOf("ARRAY ") === 0) {
            // ARRAY <name>|<rows>|<cols>
            var parts = cmd.substring(6).split("|");
            var name = parts[0], rows = parseInt(parts[1], 10), cols = parseInt(parts[2], 10);
            var total = rows * cols;
            var base = null;
            try { base = Number(session.symbol.getAddress(name)); } catch (eB) { base = null; }
            if (base === null || isNaN(base)) {
                out.push("E " + name + " address unresolved");
            } else {
                for (var off = 0; off < total; off += 2000) {
                    var cnt = Math.min(2000, total - off);
                    var vals = session.memory.readData(1, base + off, 16, cnt);
                    if (vals === null || vals.length !== cnt) { out.push("E " + name + " count mismatch"); break; }
                    for (var k = 0; k < cnt; k++) { out.push("A " + (off + k) + " " + vals[k]); }
                }
            }
            out.push("END");
        } else {
            out.push("E unknown command");
            out.push("END");
        }
    } catch (eR) {
        out.push("E " + eR);
        out.push("END");
    }
    writeText(WORK + "/res.txt", out.join("\n"));
}
// Explicit Stop is disruptive; the shared shutdown halts only if needed, then
// verifies disconnect and terminates. A failed shutdown must not look clean.
if (dssShutdown(session, print)) {
    writeText(WORK + "/stopped.txt", "stopped");
    print("SERVICE: STOPPED");
} else {
    writeText(WORK + "/error.txt", "STOP_UNCLEAN disconnect or terminate failed");
    print("SERVICE: STOP_UNCLEAN");
}
'@
$js = $js.Replace('__WORK__', $workJs).Replace('__CCXML__', $ccxmlJs).Replace('__OUT__', $outJs).Replace('__CORE__', $coreJs)
$bootJs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ti_c2000_dss_boot.js'))
if ($js.Contains('//__BOOT__')) { $js = $js.Replace('//__BOOT__', $bootJs) }
else { Write-Output 'FAILURE: DSS_BOOT_MISSING'; Write-Output 'RESULT: FAIL'; Write-Output 'REASON: the DSS template has no //__BOOT__ placeholder, so connect/reset/load would run unshared code'; exit 1 }
[IO.File]::WriteAllText($jsPath, $js, [Text.Encoding]::ASCII)

Info2 "PROJECT : $ProjectPath"
Info2 "CCS     : $ccsPath"
Info2 "CCXML   : $ccxmlOriginal"
if ($Ccxml -ne $ccxmlOriginal) { Info2 "CCXML   : using resolved copy $Ccxml" }
Info2 "OUT     : $OutFile"
Info2 "SESSION : $svcDir"
Info2 'STEP    : connect -> reset -> load once -> run forever'

# cmd /s /c "<whole command>" : /s makes cmd strip only the outer quotes, so
# paths with spaces survive. Output is redirected by cmd itself; Start-Process
# redirection would tie the log to this process and stop once it exits.
$cmdLine = '/d /s /c ""' + $dss + '" "' + $jsPath + '" > "' + $logFile + '" 2>&1"'
# Enumeration is only the first layer. Let build and setup time count toward the
# learned Stop-to-DSS interval; the later connect result updates this record.
Wait-ProbeDriverGap -ProjectPath $ProjectPath -Ccxml $ccxmlOriginal -Quiet:$Quiet
Wait-MinLoadGap -ProjectPath $ProjectPath
$psi = $null
try { $psi = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -PassThru -WindowStyle Hidden -ErrorAction Stop }
catch {
    Exit-TargetLock -ProjectPath $ProjectPath
    Out2 'FAILURE: DSS_START_FAILED'; Out2 'RESULT: FAIL'
    Out2 ('REASON: could not start the DSS process: ' + $_.Exception.Message)
    exit 1
}
$cmdPid = $psi.Id

$deadline = (Get-Date).AddSeconds($StartTimeoutSec)
$failReason = ''
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $readyFile) { break }
    if (Test-Path -LiteralPath $errorFile) { $failReason = (Get-Content -LiteralPath $errorFile -Raw).Trim(); break }
    if (-not (Get-Process -Id $cmdPid -ErrorAction SilentlyContinue)) { $failReason = 'service process exited before ready'; break }
    Start-Sleep -Milliseconds 300
}

if (-not (Test-Path -LiteralPath $readyFile)) {
    $tail = @()
    if (Test-Path -LiteralPath $logFile) { $tail = @(Get-Content -LiteralPath $logFile -Tail 12 -ErrorAction SilentlyContinue) }
    if (-not $failReason) { $failReason = 'no ready signal within the startup timeout' }
    & cmd.exe /d /c "taskkill /PID $cmdPid /T /F" 2>&1 | Out-Null
    Mark-LoadAttemptEnd -ProjectPath $ProjectPath
    Exit-TargetLock -ProjectPath $ProjectPath
    foreach ($line in $tail) { Out2 ([string]$line) }
    # Decide the classification BEFORE printing FAILURE: a -1138 that is about to be retried
    # in a fresh process is not a failure the caller should see, and printing it first made
    # a successful retry look like a failed start (measured 2026-11-15).
    # The whole log, not -Tail 12: -1138 appears near the top (GEL output first), and by
    # the time the load retries have run it is dozens of lines above the end.
    $logText = ''
    if (Test-Path -LiteralPath $logFile) { try { $logText = Get-Content -LiteralPath $logFile -Raw -Encoding utf8 } catch { } }
    if ($failReason -match '^(AMBIGUOUS_CORE|CORE_MISMATCH)\b') {
        # USAGE, not FAILURE: nothing was measured and nothing was judged - the command
        # could not say which core to open. exit 2 = "fix the command", while exit 3/4
        # means "the board or the data is not trustworthy". Mixing the two made a missing
        # parameter look like a validation that refused to download (2026-11-16).
        Out2 ('USAGE: ' + $Matches[1]); Out2 'RESULT: FAIL'
        Out2 ('REASON: ' + $failReason); exit 2
    }
    if ($failReason -match '^CONNECT_FAILED\b') {
        # No reset or load has happened yet. A PnP hit may precede driver access, so
        # add 5 s to the observed failed Stop-to-connect interval and retry once in a
        # fresh process. Subsequent Stop/Start cycles begin at the good/bad midpoint.
        Mark-ProbeDriverFailure -ProjectPath $ProjectPath -Ccxml $ccxmlOriginal
        if (-not $env:TI_C2000_CONNECT_RETRY) {
            Out2 'NOTE    : DSS connect failed before load; increasing the recovery interval for this probe configuration and retrying once'
            $env:TI_C2000_CONNECT_RETRY = '1'
            $retryArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
                '-ProjectPath',$ProjectPath,'-Start','-ConfirmLoad','-OutFile',$OutFile,'-Ccxml',$Ccxml,
                '-RunMode',$RunMode,'-StartTimeoutSec',[string]$StartTimeoutSec)
            if ($MapFile) { $retryArgs += @('-MapFile',$MapFile) }
            if ($AllowNonDefaultEntry) { $retryArgs += '-AllowNonDefaultEntry' }
            if ($CcsRoot) { $retryArgs += @('-CcsRoot',$CcsRoot) }
            if ($CorePattern) { $retryArgs += @('-CorePattern',$CorePattern) }
            if ($UserApproved) { $retryArgs += '-UserApproved' }
            if ($Quiet) { $retryArgs += '-Quiet' }
            try { & pwsh @retryArgs; exit $LASTEXITCODE }
            finally { Remove-Item Env:TI_C2000_CONNECT_RETRY -ErrorAction SilentlyContinue }
        }
        Out2 'FAILURE: CONNECT_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $failReason)
        Out2 'HINT    : inspect DSS log and probe-driver-wait.json; two failed connections do not prove a cable or power fault'
        exit 3
    }
    if ($logText -match 'Error -1138|Device refused to allow debug mode' -or $failReason -match 'board refused debug mode') {
        # -1138 is intermittent, and a fresh DSS process usually clears it on the first try:
        # measured 2026-11-15, the very same command failed with -1138 and then succeeded
        # on the next invocation at loads #35, #37 and #44. Retrying inside one DSS process
        # is what damages the probe (-1041 -> -150), so the retry here is a NEW process,
        # exactly once. Only if that also fails is this a board state the user must fix.
        if (-not $env:TI_C2000_START_RETRY) {
            Out2 'NOTE    : the chip refused debug mode (Error -1138) - retrying once with a fresh DSS process'
            $env:TI_C2000_START_RETRY = '1'
            $retryArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-ProjectPath', $ProjectPath, '-Start', '-ConfirmLoad', '-RunMode', $RunMode,
                '-StartTimeoutSec', [string]$StartTimeoutSec)
            if ($CcsRoot) { $retryArgs += @('-CcsRoot', $CcsRoot) }
            if ($Ccxml) { $retryArgs += @('-Ccxml', $Ccxml) }
            if ($OutFile) { $retryArgs += @('-OutFile', $OutFile) }
            if ($MapFile) { $retryArgs += @('-MapFile', $MapFile) }
            if ($AllowNonDefaultEntry) { $retryArgs += '-AllowNonDefaultEntry' }
            if ($CorePattern) { $retryArgs += @('-CorePattern', $CorePattern) }
            if ($UserApproved) { $retryArgs += '-UserApproved' }
            if ($Quiet) { $retryArgs += '-Quiet' }
            try {
                & pwsh @retryArgs
                exit $LASTEXITCODE
            } finally {
                Remove-Item Env:TI_C2000_START_RETRY -ErrorAction SilentlyContinue
            }
        }
        # Two attempts failed; this does not by itself identify the physical cause.
        Out2 'FAILURE: SERVICE_START_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $failReason)
        Out2 'HINT    : Error -1138 occurred twice; check probe recovery time, DSS logs and target configuration before changing hardware'
        exit 3
    }
    if ($tail -join "`n" -match 'Error -150|FTDI driver functions') {
        Out2 'HINT    : the probe driver did not become usable after the previous session; consult Error mode for this adapter'
        Out2 'HINT    : PnP enumeration passed, but DSS access failed; wait and inspect the DSS log before another Start'
    } elseif ($failReason -match 'Load failed|Failed to remove the debug state') {
        # measured 2026-11-15: the first load after an unclean disconnect can fail even
        # with in-process retries, and the very next whole -Start then succeeds
        Out2 'HINT    : the target still holds debug state from an earlier session - run -Start again (a fresh DSS process usually clears it)'
        Out2 'HINT    : if it fails twice in a row, power-cycle the board (unplug USB, wait 3 s, plug back in) and start again'
    }
    Out2 'FAILURE: SERVICE_START_FAILED'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $failReason)
    exit 1
}

# READY is written only after DSS connected, verified the target, loaded and ran.
Mark-ProbeDriverSuccess -ProjectPath $ProjectPath -Ccxml $ccxmlOriginal

$resolvedCore = if (Test-Path -LiteralPath $coreFile) { ([string](Get-Content -LiteralPath $coreFile -Raw)).Trim() } else { '' }
if (-not $resolvedCore) {
    & cmd.exe /d /c "taskkill /PID $cmdPid /T /F" 2>&1 | Out-Null
    Mark-LoadAttemptEnd -ProjectPath $ProjectPath
    Exit-TargetLock -ProjectPath $ProjectPath
    Out2 'FAILURE: CORE_UNVERIFIED'; Out2 'RESULT: FAIL'
    Out2 'REASON: DSS did not report the exact selected target core'; exit 4
}
Info2 ('CORE    : selected {0}' -f $resolvedCore)
$state = [ordered]@{
    # Store the time of the finished load, so the next round cannot start immediately.
    pid       = $cmdPid
    started   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    project   = $ProjectPath
    out       = $OutFile
    outSha256 = $outSha
    map       = $MapFile
    mapSha256 = $mapSha
    ccxml     = (Get-Item -LiteralPath $ccxmlOriginal).FullName
    # The project file stays the recorded identity; the resolved copy (if any) is extra state.
    ccxmlResolved = $(if ($Ccxml -ne $ccxmlOriginal) { (Get-Item -LiteralPath $Ccxml).FullName } else { '' })
    probeSerial   = [string]$resolvedCfg.Serial
    core      = $resolvedCore
    corePattern = $CorePattern
    status    = 'RUNNING'
    loadIndex = 0
    runMode   = $runSpec.mode
}
Mark-LoadAttemptEnd -ProjectPath $ProjectPath
Write-JsonAtomic -Path $stateFile -Object $state

# the image is on the target now: this is a real download, so the shared counter
# moves (kept in readout\, outside .service, -Stop never resets it)
$rec = Add-LoadRecord -ProjectPath $ProjectPath -Mode $runSpec.mode -Out $OutFile -Sha256 $outSha
$state.loadIndex = $rec.count

# Remember the firmware's own identity while we still hold the lock and the session is
# freshly started. Later reads compare against this, so "is the board running the image
# this session loaded" becomes an automatic check instead of a parameter the caller has
# to remember. A build without gFwId simply records an empty value.
$fwIdSeen = ''
try {
    $fwLines = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @((Get-FwContract).identity.var)
    foreach ($line in $fwLines) {
        $m = [regex]::Match([string]$line, '^V\s+gFwId\s+(\S+)\s*$')
        if ($m.Success) { $fwIdSeen = $m.Groups[1].Value; break }
    }
} catch { }
if ($fwIdSeen) { $state.fwId = $fwIdSeen; Info2 ('IMAGE   : gFwId = {0} (recorded; later reads compare against it)' -f $fwIdSeen) }
else { $state.fwId = ''; Info2 'IMAGE   : no gFwId in this build - identity cannot be re-checked later (add "volatile unsigned long gFwId" to enable it)' }

Write-JsonAtomic -Path $stateFile -Object $state
Exit-TargetLock -ProjectPath $ProjectPath

Info2 ('SERVICE : RUNNING (pid {0})' -f $cmdPid)
Info2 ('RUN MODE: {0}' -f $(if ($runSpec.continuous) {
            'Iterate (continuous - this session is one round; a loop re-downloads)'
        } else {
            'SingleStep (load once, run forever; reads attach, ReadOnly never downloads)'
        }))
Info2 ('LOAD    : #{0} (this is download number {0} for this project, previous {1})' -f $rec.count, $rec.previous)
Info2 ('LOG     : {0}' -f $logFile)
# 工程改动留痕（工程 AGENTS.md 硬性规则⑤）：每次成功下载写一条，便于回溯"哪个镜像跑出过什么结果"。
try {
    $chgLog = Join-Path $ProjectPath 'BUILD_VERIFICATION.txt'
    if (-not (Test-Path -LiteralPath $chgLog)) {
        [IO.File]::WriteAllText($chgLog, ("工程改动留痕（BUILD_VERIFICATION.txt）`r`n`r`n只追加，不覆盖。`r`n--------------------------------------------------------------------------------`r`n"), (New-Object Text.UTF8Encoding($false)))
    }
    $oLen = if (Test-Path -LiteralPath $OutFile) { (Get-Item -LiteralPath $OutFile).Length } else { 0 }
    $chgRec = ('  {0} | load | LOAD #{1} OK, {2} | out {3:N0} B sha {4}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $rec.count, $runSpec.mode, $oLen, $outSha.Substring(0,12))
    [IO.File]::AppendAllText($chgLog, $chgRec + "`r`n", (New-Object Text.UTF8Encoding($false)))
    Info2 'CHGLOG  : appended to BUILD_VERIFICATION.txt'
} catch {
    Info2 ('NOTE    : BUILD_VERIFICATION.txt append failed: ' + $_.Exception.Message)
}
Out2 'RESULT: OK'
exit 0

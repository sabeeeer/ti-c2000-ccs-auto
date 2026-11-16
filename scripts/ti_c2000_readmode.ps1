#requires -Version 7.0
<#
ti_c2000_readmode.ps1 -- the two orthogonal dimensions (RUN mode x READ mode) and the
interlocks between them. Dot-source it in every entry point that touches the target:

    . "$PSScriptRoot\ti_c2000_readmode.ps1"

RUN MODE (how the program gets onto the target; -RunMode on ti_c2000_service.ps1):
  SingleStep (default) load ONCE (-Start -ConfirmLoad), keep the session alive, and
             every later read attaches to it. Day-to-day work lives here.
  Iterate    continuous: re-build + re-download every round until the data is right.
             Entered ONLY through ti_c2000_iterate.ps1 -UserApproved, never by
             passing -RunMode by hand. A marker in readout\iterate\active.json
             (with the owning pid) keeps everything else out while it runs.

READ MODE (how data comes back; -Mode on the two readers):
  ReadOnly  (default) never downloads. It attaches to the live session after proving
            four things; a failure refuses (exit 4) instead of quietly downloading:
              probe online   the selected probe adapter confirms availability
              session alive  state.json + ready.txt + pid
              same image     sha256(out) == state.outSha256
              from RAM       pinned map, RAM updater address and advancing RAM counter
            "Cannot prove it from RAM" is a refusal, not a pass: a stale Flash image
            answering on the target would otherwise come back as fresh data. The only
            way past it is to integrate the firmware RAM proof contract.
  LoadRead  downloads once, runs, reads through the retained session. Needs -ConfirmLoad. -MaxLoads N
            repeats the cycle until -Expect passes.

INTERLOCKS (checked before any hardware work; a violation reports one FAILURE line
and one exit code, it never crashes):
  ReadOnly + -ConfirmLoad/-Build/-Standalone/-Expect/-MaxLoads>1 -> MUTUALLY_EXCLUSIVE exit 2
  LoadRead  without -ConfirmLoad                                 -> LOAD_NOT_CONFIRMED  exit 4
  ReadOnly  without a live session                                -> NO_SESSION           exit 4
  Iterate   without -UserApproved                                 -> ITERATE_NOT_APPROVED exit 4
  ReadOnly  while Iterate runs                                    -> READONLY_IN_ITERATE  exit 4
  LoadRead  while Iterate runs                                    -> MUTUALLY_EXCLUSIVE   exit 2
  any Start/Stop/Iterate while Iterate runs                       -> ITERATE_IN_PROGRESS  exit 4
  another script holds the target                                 -> TARGET_BUSY          exit 5

Exit codes: 0 OK | 1 failure | 2 environment/argument | 3 no probe
            4 refused before downloading | 5 target held elsewhere
#>

. (Join-Path $PSScriptRoot 'ti_c2000_loadcount.ps1')
. (Join-Path $PSScriptRoot 'ti_c2000_fwcontract.ps1')

$script:ReadModeNames = @('ReadOnly', 'LoadRead')
$script:RunModeNames = @('SingleStep', 'Iterate')

# Called only under the project's target lock, immediately before a program load.
# Store attempts as well as successes: a failed load may already have touched target
# memory, so the next try must observe the same quiet period.
function Wait-MinLoadGap {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $gap = [int](Get-FwContract -Quiet).timing.minLoadGapMs
    if ($gap -lt 5000) { $gap = 5000 }
    $path = Join-Path $ProjectPath 'readout\.service\last-load-attempt-ms.txt'
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $last = [long]0
    if (Test-Path -LiteralPath $path) {
        [void][long]::TryParse(([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim(), [ref]$last)
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $wait = [int][Math]::Max([long]0, ([long]$gap - ($now - $last)))
    if ($wait -gt 0) {
        Write-Output ('LOAD_GAP: waiting {0} ms before another program load' -f $wait)
        Start-Sleep -Milliseconds $wait
    }
    [IO.File]::WriteAllText($path, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), [Text.Encoding]::ASCII)
}

function Mark-LoadAttemptEnd {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $path = Join-Path $ProjectPath 'readout\.service\last-load-attempt-ms.txt'
    [IO.File]::WriteAllText($path, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), [Text.Encoding]::ASCII)
}

function Wait-MinReadGap {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $gap = [int](Get-FwContract -Quiet).timing.minReadGapMs
    if ($gap -lt 400) { $gap = 400 }
    $path = Join-Path $ProjectPath 'readout\.service\last-read-request-ms.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $last = [long]0
    if (Test-Path -LiteralPath $path) {
        [void][long]::TryParse(([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim(), [ref]$last)
    }
    $wait = [int][Math]::Max([long]0, ([long]$gap - ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $last)))
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    [IO.File]::WriteAllText($path, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), [Text.Encoding]::ASCII)
}

function Get-SelectedOutFreshEvidence {
    param([Parameter(Mandatory)][string]$ProjectPath,[Parameter(Mandatory)][string]$OutFile)
    if (-not (Test-Path -LiteralPath $OutFile)) {
        return [ordered]@{ ok = $false; file = $OutFile; reason = 'selected .out does not exist' }
    }
    $out = Get-Item -LiteralPath $OutFile
    $newest = @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in @('.c','.cpp','.h','.hpp','.asm','.cla','.cmd','.inc') -or
            $_.Name -in @('.cproject','.project')
        } |
        Where-Object { $_.FullName -notmatch '[\\/](?:Debug|Release|readout|\.git)[\\/]' } |
        Sort-Object LastWriteTime -Descending) | Select-Object -First 1
    if ($newest -and $newest.LastWriteTimeUtc -gt $out.LastWriteTimeUtc.AddSeconds(2)) {
        return [ordered]@{ ok = $false; file = $newest.FullName; reason = 'a project input is newer than the selected .out' }
    }
    return [ordered]@{ ok = $true; file = $(if ($newest) { $newest.FullName } else { '' }); reason = 'project inputs are no newer than the selected .out' }
}

function Assert-SelectedOutFresh {
    param([Parameter(Mandatory)][string]$ProjectPath,[Parameter(Mandatory)][string]$OutFile)
    if (-not (Test-Path -LiteralPath $OutFile)) { return }
    $evidence = Get-SelectedOutFreshEvidence -ProjectPath $ProjectPath -OutFile $OutFile
    if (-not $evidence.ok) {
        Write-Output 'FAILURE: STALE_ARTEFACT'; Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: {0}: {1}' -f $evidence.reason,$evidence.file)
        Write-Output 'HINT    : rebuild and stage this exact -OutFile before download'
        exit 4
    }
}

function Get-TargetLockPath {
    param([Parameter(Mandatory)][string]$ProjectPath)
    return (Join-Path (Join-Path $ProjectPath 'readout\.service') 'target.lock')
}

# Once a reader owns the target, invalidate any previous success before touching DSS.
# A failure halfway through preflight then cannot leave a plausible old CSV/verdict.
function Initialize-ReadFailureVerdict {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $dataDir = Join-Path $ProjectPath 'readout\data'
    $checkDir = Join-Path $ProjectPath 'readout\check'
    New-Item -ItemType Directory -Path $dataDir,$checkDir -Force | Out-Null
    foreach ($path in @((Join-Path $dataDir 'data.csv'),(Join-Path $dataDir 'array.csv'),
                       (Join-Path $checkDir 'variables.csv'),(Join-Path $checkDir 'verdict.txt'))) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText((Join-Path $checkDir 'verdict.txt'),"result: FAIL`nfailure: READ_INCOMPLETE`n",[Text.Encoding]::UTF8)
}

function Get-TargetLockInfo {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Get-TargetLockPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $parts = (Get-Content -LiteralPath $p -Raw -Encoding utf8).Trim() -split '\|'
        return [ordered]@{ pid = [int]$parts[0]; mode = [string]$parts[1]; at = [string]$parts[2] }
    } catch { return [ordered]@{ pid = 0; mode = '?'; at = '?' } }
}

<#
one target operation at a time; a lock left by a dead process is taken over.

Returns an OBJECT, never a bare bool next to diagnostic output: a function that
Write-Output's four lines and then `return $false` hands the caller a five-element array,
and `if (-not (Enter-TargetLock ...))` evaluates that as "truthy" - so a busy target would
have been treated as acquired and two operations would have driven the same probe.
Measured 2026-11-14 by tests/test_state_chaos.ps1.
#>
function Enter-TargetLock {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Mode,
        [int]$WaitSeconds = 0
    )
    $dir = Join-Path $ProjectPath 'readout\.service'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Get-TargetLockPath -ProjectPath $ProjectPath
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (Test-Path -LiteralPath $path) {
        $info = Get-TargetLockInfo -ProjectPath $ProjectPath
        $holder = $null
        if ($info -and $info.pid -gt 0) { $holder = Get-Process -Id $info.pid -ErrorAction SilentlyContinue }
        if (-not $holder) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; break }
        if ((Get-Date) -ge $deadline) {
            return [ordered]@{
                ok      = $false
                message = @(
                    'FAILURE: TARGET_BUSY'
                    'RESULT: FAIL'
                    ("REASON: {0} (pid {1}) holds the target since {2}" -f $info.mode, $info.pid, $info.at)
                    'HINT    : one operation at a time - wait, or check that process'
                )
            }
        }
        Start-Sleep -Milliseconds 200
    }
    $text = '{0}|{1}|{2}' -f $PID, $Mode, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    try {
        # CreateNew is atomic. The previous Test-Path + WriteAllText let two processes
        # both observe no lock, overwrite each other, and drive the same DSS session.
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes($text)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
        return [ordered]@{ ok = $true; message = @() }
    } catch {
        $owner = Get-TargetLockInfo -ProjectPath $ProjectPath
        return [ordered]@{
            ok = $false
            message = @('FAILURE: TARGET_BUSY', 'RESULT: FAIL',
                ('REASON: target lock could not be acquired atomically; owner pid {0}' -f $(if ($owner) { $owner.pid } else { '?' })))
        }
    }
}

function Exit-TargetLock {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $path = Get-TargetLockPath -ProjectPath $ProjectPath
    try {
        $info = Get-TargetLockInfo -ProjectPath $ProjectPath
        if ($info -and $info.pid -eq $PID -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

<# session facts from disk; alive requires state + ready + no stopped marker + pid #>
function Get-LiveSessionInfo {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $svcDir = Join-Path $ProjectPath 'readout\.service'
    $stateFile = Join-Path $svcDir 'state.json'
    $readyFile = Join-Path $svcDir 'ready.txt'
    $stoppedFile = Join-Path $svcDir 'stopped.txt'
    $r = [ordered]@{ alive = $false; state = $null; reason = 'no session has ever been started for this project' }
    if (-not (Test-Path -LiteralPath $stateFile)) { return $r }
    if (Test-Path -LiteralPath $stoppedFile) { $r.reason = 'the session was stopped'; return $r }
    if (-not (Test-Path -LiteralPath $readyFile)) { $r.reason = 'session files exist but ready.txt is missing (starting or died)'; return $r }
    try { $r.state = Get-Content -LiteralPath $stateFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $r.reason = 'state.json is unreadable'; return $r }
    if (-not (Get-Process -Id ([int]$r.state.pid) -ErrorAction SilentlyContinue)) { $r.reason = 'the session process is gone'; return $r }
    $r.alive = $true
    $r.reason = ''
    return $r
}

<#
RUN MODE SIDE. "Is a continuous run in progress?" is answered from disk, because the
iterate loop stops and restarts the session between rounds: a marker with the owning
pid covers the gap, the live session's runMode covers the rest, and a marker left by a
dead process is ignored (never blocks a normal read for ever).
#>
function Get-IterateMarkerPath {
    param([Parameter(Mandatory)][string]$ProjectPath)
    return (Join-Path (Join-Path $ProjectPath 'readout\iterate') 'active.json')
}

function Get-IterateMarker {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Get-IterateMarkerPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $m = $null
    try { $m = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
    if (-not $m) { return $null }
    if (-not (Get-Process -Id ([int]$m.pid) -ErrorAction SilentlyContinue)) { return $null }
    return $m
}

function Set-IterateMarker {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [int]$Round = 1,
        [int]$MaxLoads = 1,
        [string[]]$Expect = @()
    )
    $p = Get-IterateMarkerPath -ProjectPath $ProjectPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = [ordered]@{
        mode     = 'Iterate'
        pid      = $PID
        round    = $Round
        maxLoads = $MaxLoads
        expect   = @($Expect)
        started  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    try { Write-JsonAtomic -Path $p -Object $o } catch { }
}

function Clear-IterateMarker {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Get-IterateMarkerPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $m = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
        if ([int]$m.pid -ne $PID) { return }
    } catch { }
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
}

<# one summary of "which run mode owns this project right now" #>
function Get-RunModeInfo {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $r = [ordered]@{ mode = 'SingleStep'; active = $false; source = 'none'; pid = 0; round = 0; maxLoads = 0 }
    $m = Get-IterateMarker -ProjectPath $ProjectPath
    if ($m) {
        $r.mode = 'Iterate'; $r.active = $true; $r.source = 'iterate marker'
        $r.pid = [int]$m.pid; $r.round = [int]$m.round; $r.maxLoads = [int]$m.maxLoads
        return $r
    }
    $s = Get-LiveSessionInfo -ProjectPath $ProjectPath
    if ($s.alive) {
        $r.source = 'live session'
        $r.pid = [int]$s.state.pid
        # A session left behind by a FINISHED continuous run still carries runMode=Iterate
        # in its state file. That is history, not an owner: only the marker proves a loop
        # is running right now. Treating the leftover as active locked every later read
        # out with READONLY_IN_ITERATE - measured 2026-11-14 right after one
        # "-MaxLoads 2" run, and the project could not be read again until -Stop.
        if ($s.state.runMode -eq 'Iterate') {
            $r.mode = 'Iterate'
            if ($s.state.loadIndex) { $r.round = [int]$s.state.loadIndex }
        }
    }
    return $r
}

<# children spawned by the iterate loop must be able to work while the marker is up #>
function Test-IterateChild {
    return ($env:TI_C2000_ITERATE_CHILD -eq '1')
}

<#
Assert-RunModeInterlock -- the RUN mode side of the interlock. -ReadMode is empty for
control operations (Start/Stop/Iterate); pass ReadOnly/LoadRead from a reader so the
message names the real conflict.
#>
function Assert-RunModeInterlock {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$ReadMode = '',
        [string]$What = 'this operation'
    )
    if (Test-IterateChild) { return }
    $mi = Get-RunModeInfo -ProjectPath $ProjectPath
    if (-not $mi.active) { return }

    $who = ('continuous run in progress (pid {0}, round {1}/{2}, {3})' -f $mi.pid, $mi.round, $mi.maxLoads, $mi.source)
    if ($ReadMode -eq 'ReadOnly') {
        Write-Output 'FAILURE: READONLY_IN_ITERATE'
        Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + $who)
        Write-Output 'REASON: every round re-downloads and restarts the program, so an attached read would describe a run that is already gone'
        Write-Output 'HINT    : let ti_c2000_iterate.ps1 finish (it reads each round itself), or wait and read the session that it leaves behind'
        exit 4
    }
    if ($ReadMode -eq 'LoadRead') {
        Write-Output 'FAILURE: MUTUALLY_EXCLUSIVE'
        Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + $who)
        Write-Output 'REASON: the continuous run already owns the download loop - one downloader at a time'
        Write-Output 'HINT    : stop it (or wait for it to converge) before asking for a one-shot LoadRead'
        exit 2
    }
    Write-Output 'FAILURE: ITERATE_IN_PROGRESS'
    Write-Output 'RESULT: FAIL'
    Write-Output ('REASON: ' + $who)
    Write-Output ('REASON: ' + $What + ' would fight the running iterate loop over the same target')
    Write-Output 'HINT    : let ti_c2000_iterate.ps1 finish; it leaves the last round''s session in place'
    exit 4
}

<# validate -RunMode and its companions; returns the spec or exits with the right code #>
function Resolve-RunModeSpec {
    param(
        [string]$RunMode = 'SingleStep',
        [switch]$ConfirmLoad,
        [switch]$UserApproved,
        [int]$MaxLoads = 1
    )

    $norm = ([string]$RunMode).Trim()
    if (@($script:RunModeNames | Where-Object { $_ -eq $norm }).Count -eq 0) {
        Write-Output 'FAILURE: INVALID_RUN_MODE'
        Write-Output 'RESULT: FAIL'
        Write-Output ("REASON: -RunMode must be SingleStep or Iterate, got '{0}'" -f $norm)
        exit 2
    }
    if ($MaxLoads -lt 1 -or $MaxLoads -gt 20) {
        Write-Output 'FAILURE: INVALID_MAX_LOADS'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: -MaxLoads must be 1..20'
        exit 2
    }
    if ($norm -eq 'Iterate') {
        # continuous mode re-downloads on purpose; only a user asking for it may enter.
        # No env-var exemption here on purpose: the iterate loop already passes
        # -UserApproved explicitly to its children (ti_c2000_iterate.ps1), so honouring
        # TI_C2000_ITERATE_CHILD would only turn a marker into an approval bypass.
        if (-not $UserApproved) {
            Write-Output 'FAILURE: ITERATE_NOT_APPROVED'
            Write-Output 'RESULT: FAIL'
            Write-Output 'REASON: continuous mode compiles and downloads again every round - it only runs when the user asked for it'
            Write-Output 'HINT    : the user says "连续运行，反复编译下载直到数据对" first; then run ti_c2000_iterate.ps1 -UserApproved'
            Write-Output 'HINT    : for a plain read use -Mode ReadOnly; for one download use -Mode LoadRead -ConfirmLoad'
            exit 4
        }
        return [ordered]@{ mode = $norm; downloads = $true; continuous = $true; maxLoads = $MaxLoads }
    }
    return [ordered]@{ mode = $norm; downloads = [bool]$ConfirmLoad; continuous = $false; maxLoads = $MaxLoads }
}

<# validate -Mode and its companions; returns the spec or exits with the right code #>
function Resolve-ReadModeSpec {
    param(
        [string]$Mode = 'ReadOnly',
        [switch]$ConfirmLoad,
        [switch]$Build,
        [switch]$Standalone,
        [string[]]$Expect = @(),
        [int]$MaxLoads = 1,
        [switch]$NoProbeCheck,
        [switch]$AllowUnverified
    )

    $norm = ([string]$Mode).Trim()
    if (@($script:ReadModeNames | Where-Object { $_ -eq $norm }).Count -eq 0) {
        Write-Output 'FAILURE: INVALID_READ_MODE'
        Write-Output 'RESULT: FAIL'
        Write-Output ("REASON: -Mode must be ReadOnly or LoadRead, got '{0}'" -f $norm)
        exit 2
    }
    if ($MaxLoads -lt 1 -or $MaxLoads -gt 20) {
        Write-Output 'FAILURE: INVALID_MAX_LOADS'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: -MaxLoads must be 1..20'
        exit 2
    }
    if ($norm -eq 'ReadOnly') {
        $clash = @()
        if ($ConfirmLoad) { $clash += '-ConfirmLoad' }
        if ($Build) { $clash += '-Build' }
        if ($Standalone) { $clash += '-Standalone' }
        if (@($Expect).Count -gt 0) { $clash += '-Expect' }
        if ($MaxLoads -gt 1) { $clash += '-MaxLoads' }
        if ($clash.Count -gt 0) {
            Write-Output 'FAILURE: MUTUALLY_EXCLUSIVE'
            Write-Output 'RESULT: FAIL'
            Write-Output ('REASON: ReadOnly never downloads, so ' + ($clash -join ' / ') + ' cannot be combined with it')
            Write-Output 'HINT    : drop them for a plain read, or use -Mode LoadRead -ConfirmLoad to download first'
            exit 2
        }
    } elseif ($NoProbeCheck -or $AllowUnverified) {
        # both switches weaken a proof that only ReadOnly has to make; a download
        # needs the probe and writes the image itself, so they make no sense here
        $which = @()
        if ($NoProbeCheck) { $which += '-NoProbeCheck' }
        if ($AllowUnverified) { $which += '-AllowUnverified' }
        Write-Output 'FAILURE: MUTUALLY_EXCLUSIVE'
        Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + ($which -join ' / ') + ' only applies to -Mode ReadOnly')
        Write-Output 'HINT    : LoadRead checks the probe and loads the image itself - drop the switch'
        exit 2
    } elseif (-not $ConfirmLoad) {
        Write-Output 'FAILURE: LOAD_NOT_CONFIRMED'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: LoadRead writes the image and restarts the program; it only runs after the user said yes'
        Write-Output 'HINT    : ask "是否编译下载并运行？" first, then re-run with -Mode LoadRead -ConfirmLoad'
        Write-Output 'HINT    : -Mode ReadOnly (default) reads the running program and never downloads'
        exit 4
    }
    return [ordered]@{ mode = $norm; downloads = ($norm -eq 'LoadRead'); expect = @($Expect); maxLoads = $MaxLoads }
}

<# one variable or address request against the retained session (caller holds lock) #>
function Get-SessionExpressions {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string[]]$Exprs,
        [ValidateSet('VARS','ADDR')][string]$Kind = 'VARS',
        [int]$TimeoutMs = 6000
    )
    $svcDir = Join-Path $ProjectPath 'readout\.service'
    $cmdFile = Join-Path $svcDir 'cmd.txt'
    $resFile = Join-Path $svcDir 'res.txt'
    # The same two hazards as ti_c2000_live_read.ps1 Send-Request, and the same fixes:
    #   * one Remove-Item can leave the previous res.txt behind (a scanner or the service
    #     holding the handle), and then the wait below returns the PREVIOUS answer while
    #     the request was never sent - the caller reads a stale value and believes it;
    #   * a direct WriteAllText lets the service read a half-written command and answer
    #     "E unknown command", which surfaces as a value read failure on good data.
    # Keep both implementations in step: tests/test_dss_boot_shared.ps1 checks that each
    # one clears with a retry loop and writes through a temp file.
    for ($c = 0; $c -lt 10 -and (Test-Path -LiteralPath $resFile); $c++) {
        Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $resFile)) { break }
        Start-Sleep -Milliseconds 30
    }
    if (Test-Path -LiteralPath $resFile) { return $null }
    Wait-MinReadGap -ProjectPath $ProjectPath
    $req = $Kind + ' ' + ($Exprs -join '|')
    $tmpCmd = $cmdFile + '.tmp'
    try {
        [IO.File]::WriteAllText($tmpCmd, $req, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $tmpCmd -Destination $cmdFile -Force -ErrorAction Stop
    } catch {
        try { [IO.File]::WriteAllText($cmdFile, $req, [Text.Encoding]::ASCII) } catch { return $null }
        Remove-Item -LiteralPath $tmpCmd -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resFile) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $resFile)) { return $null }
    try {
        $lines = @(Get-Content -LiteralPath $resFile -Encoding utf8)
        if (@($lines | Where-Object { $_ -match '^HALTED 0\s*$' }).Count -ne 1) { return $null }
        if (@($lines | Where-Object { $_ -match '^END\s*$' }).Count -ne 1) { return $null }
        return $lines
    } catch { return $null }
}

<#
Assert-ProbeOnline -- ReadOnly still needs the probe. A session whose JTAG link died
keeps a live pid and a matching sha256, so "process alive" alone would happily report
numbers from a board that is no longer answering. Enumerating Windows devices takes
about a second and touches no target state.
#>
function Assert-ProbeOnline {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$DebugScript,
        [string]$CcsRoot = '',
        [switch]$Skip,
        [switch]$Quiet
    )
    if ($Skip) { return }

    # Probe enumeration belongs in the device/probe adapter (debug.ps1). Retry that
    # adapter until it says usable; no emulator-name patterns live in this read gate.
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $DebugScript, '-ProjectPath', $ProjectPath, '-ProbeCheckOnly')
    if ($CcsRoot) { $a += @('-CcsRoot', $CcsRoot) }
    # Retry the check itself, not just the PnP scan: right after a session exits the device
    # re-enumerates, and for a moment PnP lists it while its driver is still loading - a
    # single scan reports NO_PROBE for a probe that works one second later (measured
    # 2026-11-15: -Stop printed "PROBE : re-enumerated", the very next -Start still failed).
    $out = @()
    $code = 1
    # Up to 12 s, because after a session exits the device is listed in PnP well before its
    # driver can actually open it: measured 2026-11-15, -Stop reported "PROBE :
    # re-enumerated" and the next -Start still failed NO_PROBE three times in a row
    # (3.6 s). A probe that is genuinely absent still ends up as NO_PROBE, just later.
    for ($try = 1; $try -le 6; $try++) {
        $out = @(& $pwshExe @a 2>&1)
        $code = $LASTEXITCODE
        $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
        if ($code -eq 0 -and $text -match 'RESULT: OK') { break }
        if ($try -lt 6) { Start-Sleep -Milliseconds 2000 }
    }
    $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
    if ($code -eq 0 -and $text -match 'RESULT: OK') {
        if (-not $Quiet) {
            foreach ($l in $out) { if ([string]$l -match '^PROBE') { Write-Output ([string]$l).TrimEnd() } }
        }
        return
    }
    # forward the child's diagnosis only (it knows which vendors it looked for);
    # the FAILURE/RESULT lines below are the single ones this call reports
    foreach ($l in $out) { if ([string]$l -match '^REASON') { Write-Output ([string]$l) } }
    if ($code -eq 3 -or $text -match 'NO_PROBE') {
        Write-Output 'FAILURE: NO_PROBE'
        Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: no JTAG probe is enumerated by Windows, so the session this read would attach to cannot answer'
        Write-Output 'HINT    : connect the probe and the board (check the USB light), then read again'
        exit 3
    }
    Write-Output 'FAILURE: PROBE_CHECK_FAILED'
    Write-Output 'RESULT: FAIL'
    Write-Output 'REASON: probe pre-check did not return RESULT: OK'
    exit 2
}

<#
Test-AliveNow -- is the program running RIGHT NOW, before any data is read?

Reading first and judging liveness afterwards answers the wrong question: by then the
values are already on disk and a failure only tells you to throw them away. This takes
two samples of a counter the firmware increments, a known gap apart, and reports the
movement. It must be called while holding the target lock (it talks over cmd/res).

Returns @{ ok; name; first; last; gapMs; reason }
#>
function Test-AliveNow {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        # Empty means "use the contract". These three names were hard-coded here and in
        # three other files, in different orders (see references\firmware-contract.json).
        [string[]]$Candidates = @(),
        [int]$GapMs = 150
    )
    if ($Candidates.Count -eq 0) { $Candidates = @((Get-FwContract).heartbeat.candidates) }
    $r = [ordered]@{ ok = $false; name = ''; first = ''; last = ''; gapMs = $GapMs; reason = '' }

    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        $a = $null
        $lines = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @($c)
        foreach ($line in $lines) {
            $m = [regex]::Match([string]$line, ('^V\s+' + [regex]::Escape($c) + '\s+(\S+)\s*$'))
            if ($m.Success) { $a = $m.Groups[1].Value; break }
        }
        if (-not $a) { continue }
        Start-Sleep -Milliseconds $GapMs
        $b = $null
        $lines2 = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs @($c)
        foreach ($line in $lines2) {
            $m = [regex]::Match([string]$line, ('^V\s+' + [regex]::Escape($c) + '\s+(\S+)\s*$'))
            if ($m.Success) { $b = $m.Groups[1].Value; break }
        }
        if (-not $b) { continue }
        $r.name = $c; $r.first = $a; $r.last = $b
        $da = 0.0; $db = 0.0
        if ([double]::TryParse([string]$a, [ref]$da) -and [double]::TryParse([string]$b, [ref]$db)) {
            $r.ok = ($db -gt $da)
            $r.reason = if ($r.ok) { ('advanced by {0:N0} in {1} ms' -f ($db - $da), $GapMs) }
                        else { ('did not advance ({0} -> {1})' -f $a, $b) }
            return $r
        }
        $r.reason = ('unreadable value ({0} -> {1})' -f $a, $b)
        return $r
    }
    $r.reason = 'no readable counter among ' + ($Candidates -join ', ')
    return $r
}
<#
Get-ImageMemoryMap -- where can this image run, according to its own build?

"RAM or Flash?" is checked against the exact linker map pinned at load. The .map
file lists every MEMORY region with its name, origin and length:

    MEMORY CONFIGURATION
             name            origin    length      used     unused   attr
    PAGE 0:
      RAMM0                 00000123   000002dd  00000074  00000269  RWIX
      RAMLS0                00008000   00000800  000007fb  00000005  RWIX
      FLASHA                00080002   00001ffe  00000000  00001ffe  RWIX

No PC or fixed device address is involved. Unknown region names fail closed.

Returns @{ regions = @(@{name;start;end;isFlash}); source = <path> } or $null.
#>
$script:MemoryMapCache = @{}

function Get-ImageMemoryMap {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$OutFile = '',
        [string]$MapFile = ''
    )
    $candidates = if ($MapFile) { @($MapFile) } elseif ($OutFile) { @([IO.Path]::ChangeExtension($OutFile, '.map')) } else { @() }

    $map = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
    if (-not $map) { return $null }
    if ($script:MemoryMapCache.ContainsKey($map)) { return $script:MemoryMapCache[$map] }

    $regions = @()
    $inMem = $false
    foreach ($line in [IO.File]::ReadAllLines($map)) {
        if ($line -match 'MEMORY CONFIGURATION') { $inMem = $true; continue }
        if (-not $inMem) { continue }
        # "  RAMLS0                00008000   00000800  000007fb  00000005  RWIX"
        $m = [regex]::Match($line, '^\s{2,}(\S+)\s+([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+[0-9a-fA-F]{8}\s+[0-9a-fA-F]{8}')
        if (-not $m.Success) {
            if ($line -match '^\s*SECTION ALLOCATION MAP') { break }
            continue
        }
        $start = [Convert]::ToInt64($m.Groups[2].Value, 16)
        $size = [Convert]::ToInt64($m.Groups[3].Value, 16)
        if ($size -le 0) { continue }
        $name = $m.Groups[1].Value
        # The linker names the region; an unrecognised name is not guessed into RAM.
        $kind = if ($name -match '^FLASH|^OTP|^SECURE') { 'FLASH' }
                elseif ($name -match '^RAM') { 'RAM' }
                else { 'OTHER' }
        $regions += [pscustomobject]@{ name = $name; start = $start; end = $start + $size; kind = $kind }
    }
    if ($regions.Count -eq 0) { $script:MemoryMapCache[$map] = $null; return $null }
    $result = [ordered]@{ regions = @($regions | Sort-Object start); source = $map }
    $script:MemoryMapCache[$map] = $result
    return $result
}

# No PC read. The selected map is pinned by SHA256 at load time. The updater
# function and its counter must both resolve into RAM regions of that map, .text
# must also be RAM-linked, and the counter must move while this session runs.
function Get-RamProofEvidence {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)]$SessionState,
        [string]$MapFile = ''
    )
    $r = [ordered]@{ ok = $false; kind = 'UNKNOWN'; region = ''; code = 'RAM_PROOF_UNAVAILABLE'; text = ''; counter = ''; first = ''; last = ''; mapSha256 = '' }
    if (-not $MapFile) { $MapFile = [string]$SessionState.map }
    if (-not $MapFile -or -not (Test-Path -LiteralPath $MapFile)) {
        $r.text = 'the selected image has no linker map'; return $r
    }
    $MapFile = (Get-Item -LiteralPath $MapFile).FullName
    if ([string]$SessionState.map -ne $MapFile -or -not $SessionState.mapSha256) {
        $r.text = 'the map is not the one pinned by the retained load'; return $r
    }
    $sha = (Get-FileHash -LiteralPath $MapFile -Algorithm SHA256).Hash
    $r.mapSha256 = $sha
    if ($sha -ne [string]$SessionState.mapSha256) {
        $r.code = 'STALE_MAP'; $r.text = 'the map changed after the image was loaded'; return $r
    }
    $map = Get-ImageMemoryMap -ProjectPath $ProjectPath -OutFile $OutFile -MapFile $MapFile
    if (-not $map -or $map.source -ne $MapFile) {
        $r.text = 'the selected map has no readable MEMORY configuration'; return $r
    }
    $codeSections = @()
    $inAlloc = $false
    foreach ($line in [IO.File]::ReadAllLines($MapFile)) {
        if ($line -match 'SECTION ALLOCATION MAP') { $inAlloc = $true; continue }
        if (-not $inAlloc) { continue }
        $m = [regex]::Match($line,'^\s*(\.text(?:[.:]\S+)?)\s+0\s+([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})')
        if (-not $m.Success) { continue }
        $start = [Convert]::ToInt64($m.Groups[2].Value,16)
        $size = [Convert]::ToInt64($m.Groups[3].Value,16)
        if ($size -le 0) { continue }
        $hit = @($map.regions | Where-Object { $start -ge $_.start -and ($start+$size) -le $_.end }) | Select-Object -First 1
        $codeSections += [pscustomobject]@{ name=$m.Groups[1].Value; region=$hit; start=$start; size=$size }
    }
    if ($codeSections.Count -eq 0) { $r.text = 'no allocated .text section in the selected map'; return $r }
    $badText = @($codeSections | Where-Object { -not $_.region -or $_.region.kind -ne 'RAM' })
    if ($badText.Count -gt 0) {
        $r.kind = if (@($badText | Where-Object { $_.region -and $_.region.kind -eq 'FLASH' }).Count) { 'FLASH' } else { 'UNKNOWN' }
        $r.code = 'NOT_RAM_IMAGE'; $r.text = '.text is not entirely RAM-linked'; return $r
    }
    $contract = Get-FwContract
    $symbols = @([string]$contract.ramProof.updater,[string]$contract.ramProof.counter)
    $lines = Get-SessionExpressions -ProjectPath $ProjectPath -Exprs $symbols -Kind ADDR
    if (-not $lines) { $r.code = 'TARGET_NOT_CONNECTED'; $r.text = 'DSS did not answer the symbol-address request'; return $r }
    $addresses = @{}
    foreach ($line in $lines) {
        $m = [regex]::Match([string]$line,'^P\s+(\S+)\s+(\S+)\s*$')
        if (-not $m.Success) { continue }
        $raw = $m.Groups[2].Value
        $v = [long]0
        if ($raw -match '^0[xX]([0-9A-Fa-f]+)$') { try { $v = [Convert]::ToInt64($Matches[1],16) } catch { } }
        else { [void][long]::TryParse($raw,[ref]$v) }
        if ($v -gt 0) { $addresses[$m.Groups[1].Value] = $v }
    }
    foreach ($symbol in $symbols) {
        if (-not $addresses.ContainsKey($symbol)) { $r.text = "symbol $symbol has no address in the loaded image"; return $r }
        $address = [long]$addresses[$symbol]
        $region = @($map.regions | Where-Object { $address -ge $_.start -and $address -lt $_.end }) | Select-Object -First 1
        if (-not $region -or $region.kind -ne 'RAM') {
            $r.kind = if ($region -and $region.kind -eq 'FLASH') { 'FLASH' } else { 'UNKNOWN' }
            $r.code = 'NOT_RAM_IMAGE'; $r.text = "$symbol is not in a RAM run region"; return $r
        }
        if ($symbol -eq $contract.ramProof.updater) { $r.region = [string]$region.name }
    }
    $alive = Test-AliveNow -ProjectPath $ProjectPath -Candidates @([string]$contract.ramProof.counter)
    if (-not $alive.ok) { $r.code = 'RAM_PROOF_NOT_ADVANCING'; $r.text = $alive.reason; return $r }
    $r.ok = $true; $r.kind = 'RAM'; $r.code = ''; $r.counter = $alive.name
    $r.first = $alive.first; $r.last = $alive.last
    $r.text = ('RAM-linked .text and updater {0} in {1}; {2} advanced {3}->{4}; map SHA256 {5}' -f `
        $contract.ramProof.updater,$r.region,$r.counter,$r.first,$r.last,$sha.Substring(0,16))
    return $r
}

<#
Invoke-LoadReadLoop -- -MaxLoads N of LoadRead: re-run this same reader once per
download, keep every attempt, stop as soon as -Expect passes. The child run is the
normal one-shot LoadRead, so there is still exactly one code path that loads.
#>
function Invoke-LoadReadLoop {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bound,
        [string[]]$Expect = @(),
        [int]$MaxLoads = 1,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$CsvPath,
        [string]$VerdictPath = '',
        [switch]$Quiet
    )

    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $iterDir = Join-Path $ProjectPath 'readout\loadread'
    New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
    $start = [int](Get-LoadCount -ProjectPath $ProjectPath).count
    $converged = $false
    $reason = 'no attempt ran'
    $done = 0

    for ($i = 1; $i -le $MaxLoads; $i++) {
        Write-Output ('ATTEMPT : {0}/{1} (this one is download #{2})' -f $i, $MaxLoads, ($start + $i))
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
        foreach ($k in @($Bound.Keys)) {
            if ($k -eq 'MaxLoads') { continue }
            $v = $Bound[$k]
            if ($v -is [System.Management.Automation.SwitchParameter]) {
                if ($v.IsPresent) { $a += ('-' + $k) }
            } elseif ($v -is [array]) {
                $a += ('-' + $k); $a += (@($v) -join ',')
            } else {
                $a += ('-' + $k); $a += [string]$v
            }
        }
        $env:TI_C2000_LOADREAD_CHILD = '1'
        try { $out = & $pwshExe @a 2>&1; $code = $LASTEXITCODE } finally { Remove-Item Env:TI_C2000_LOADREAD_CHILD -ErrorAction SilentlyContinue }
        $done = $i
        foreach ($l in $out) { if ([string]$l -notmatch '^RESULT:') { Write-Output ([string]$l) } }

        $keep = Join-Path $iterDir ('attempt-' + $i)
        New-Item -ItemType Directory -Path $keep -Force | Out-Null
        foreach ($f in @($CsvPath, $VerdictPath)) {
            if ($f -and (Test-Path -LiteralPath $f)) { Copy-Item -LiteralPath $f -Destination (Join-Path $keep (Split-Path -Leaf $f)) -Force }
        }

        if ($code -ne 0) { $reason = ('attempt {0} failed (exit {1})' -f $i, $code); continue }
        if (@($Expect).Count -eq 0) { $converged = $true; break }

        $values = @{}
        if (Test-Path -LiteralPath $CsvPath) {
            try {
                $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding utf8)
                if ($rows.Count -gt 0) {
                    foreach ($p in $rows[-1].PSObject.Properties) { $values[$p.Name] = [string]$p.Value }
                }
            } catch { }
        }
        $check = Test-LoadExpectation -Expect $Expect -Values $values
        foreach ($c in $check.checks) { Write-Output ('EXPECT  : ' + $c) }
        if ($check.ok) { $converged = $true; break }
        $reason = ('attempt {0} data did not match -Expect' -f $i)
    }

    Write-Output ('LOADS   : {0} download(s) in this loop, attempts kept in {1}' -f ($done), $iterDir)
    return [ordered]@{ converged = $converged; attempts = $done; reason = $reason }
}

# A confirmed load is performed by the retained service, followed by the normal
# ReadOnly gate in the SAME DSS session. The service is left running for further
# reads; no end-of-read halt/disconnect is necessary.
function Invoke-RetainedLoadRead {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory)][string]$ProjectPath,
        [switch]$Quiet
    )
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
    $service = Join-Path $PSScriptRoot 'ti_c2000_service.ps1'
    $live = Get-LiveSessionInfo -ProjectPath $ProjectPath
    if ($live.alive) {
        Write-Output 'STEP    : replacing the existing session for the approved load'
        $stopArgs = @('-NoProfile','-File',$service,'-ProjectPath',$ProjectPath,'-Stop')
        if ($Bound.ContainsKey('CcsRoot') -and [string]$Bound['CcsRoot']) { $stopArgs += @('-CcsRoot',[string]$Bound['CcsRoot']) }
        $stop = @(& $pwshExe @stopArgs 2>&1)
        if ($LASTEXITCODE -ne 0 -or -not @($stop | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
            foreach ($line in $stop) { if ([string]$line -notmatch '^(RESULT|FAILURE):') { Write-Output ([string]$line) } }
            Write-Output 'FAILURE: STOP_FAILED'; Write-Output 'RESULT: FAIL'; exit 1
        }
    }
    $startArgs = @('-NoProfile','-File',$service,'-ProjectPath',$ProjectPath,'-Start','-ConfirmLoad')
    foreach ($key in @('Ccxml','OutFile','MapFile','CcsRoot','CorePattern')) {
        if ($Bound.ContainsKey($key) -and [string]$Bound[$key]) { $startArgs += @('-' + $key,[string]$Bound[$key]) }
    }
    if ($Bound.ContainsKey('Build') -and $Bound['Build']) { $startArgs += '-Build' }
    if ($Quiet) { $startArgs += '-Quiet' }
    $start = @(& $pwshExe @startArgs 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not @($start | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        foreach ($line in $start) { if ([string]$line -notmatch '^(RESULT|FAILURE):') { Write-Output ([string]$line) } }
        Write-Output 'FAILURE: LOAD_FAILED'; Write-Output 'RESULT: FAIL'; exit 1
    }
    foreach ($line in $start) { if ([string]$line -match '^(LOAD|LOADS|IMAGE|SERVICE|PROBE)') { Write-Output ([string]$line) } }
    $readArgs = @('-NoProfile','-File',$ScriptPath,'-ProjectPath',$ProjectPath,'-Mode','ReadOnly')
    foreach ($key in @($Bound.Keys)) {
        if ($key -in @('ProjectPath','Mode','ConfirmLoad','Build','Standalone','Expect','MaxLoads','NoProbeCheck','AllowUnverified')) { continue }
        $value = $Bound[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $readArgs += ('-' + $key) }
        } elseif ($value -is [array]) {
            $readArgs += ('-' + $key); $readArgs += (@($value) -join ',')
        } else {
            $readArgs += ('-' + $key); $readArgs += [string]$value
        }
    }
    & $pwshExe @readArgs
    exit $LASTEXITCODE
}

<#
SKILL IDENTITY AND PROJECT HYGIENE -- the two things that make "the run went through
the skill" checkable instead of assumed.

A document can only ask an AI to use the skill; it cannot prove the run did. So every
entry point calls Initialize-SkillRun once, which
  1. refuses (or at least shouts) when the project still holds a copy of a skill
     script, because that copy is what actually executes,
  2. appends one line to <project>\readout\skill-runs.jsonl naming this script, this
     skill directory and its version, so check_project_entry.ps1 -MaxRunAgeMinutes can
     later prove the last operation came from the skill and not from somewhere else.

The version is the first 8 hex of a SHA256 over sorted paths and content hashes of
the entrypoint, runtime scripts, references and maintenance tools. Script-only edits
therefore change the version too.
#>
$script:SkillCopyNamePattern = '^ti_c2000_.*\.(ps1|js)$'
$script:SkillCopyExact = @('verify_on_target.ps1', 'dss_load_run_read.js', 'run_hold.js')

function Get-SkillIdentity {
    param([string]$SkillRoot = '')
    if (-not $SkillRoot) { $SkillRoot = Split-Path $PSScriptRoot -Parent }
    $skillRoot = $SkillRoot
    $ver = 'unknown'
    $md = Join-Path $skillRoot 'SKILL.md'
    if (Test-Path -LiteralPath $md) {
        try {
            $files = @($md, (Join-Path $skillRoot 'AGENTS.md'))
            foreach ($sub in @('scripts','references','tools')) {
                $dir = Join-Path $skillRoot $sub
                if (Test-Path -LiteralPath $dir) {
                    $files += @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.js','.md','.json') } | ForEach-Object { $_.FullName })
                }
            }
            $manifest = New-Object Text.StringBuilder
            foreach ($file in @($files | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)) {
                $rel = [IO.Path]::GetRelativePath($skillRoot,$file).Replace('\','/')
                $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                [void]$manifest.Append($rel).Append(' ').Append($hash).Append("`n")
            }
            $h = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest.ToString()))
            $ver = [Convert]::ToHexString($h).Substring(0,8).ToLowerInvariant()
        } catch { }
    }
    return [ordered]@{ root = $skillRoot; version = $ver }
}

function Get-SkillScriptCopies {
    param([Parameter(Mandatory)][string]$ProjectPath)
    if (-not (Test-Path -LiteralPath $ProjectPath)) { return @() }
    return @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Include *.ps1, *.js -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        Where-Object { $_.Name -match $script:SkillCopyNamePattern -or $script:SkillCopyExact -contains $_.Name })
}

function Write-SkillRunRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Script,
        [string]$Mode = '',
        [Parameter(Mandatory)]$Identity
    )
    $dir = Join-Path $ProjectPath 'readout'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'skill-runs.jsonl'
    $rec = [ordered]@{
        at      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        pid     = $PID
        script  = $Script
        mode    = $Mode
        skill   = $Identity.root
        version = $Identity.version
    }
    try {
        $line = ($rec | ConvertTo-Json -Compress)
        # keep the file bounded: rotate to the last 200 lines instead of growing forever
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 120KB)) {
            $tail = @(Get-Content -LiteralPath $path -Encoding utf8 | Select-Object -Last 200)
            [IO.File]::WriteAllLines($path, $tail, (New-Object Text.UTF8Encoding($false)))
        }
        [IO.File]::AppendAllText($path, ($line + "`n"), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

<#
Initialize-SkillRun -- one call per entry point. -Block makes a project that still holds
a skill copy a hard refusal (used where the target is written: a download must not be
decided by stale logic); without it the run continues but says so.
#>
function Initialize-SkillRun {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$Script = '',
        [string]$Mode = '',
        [switch]$Block,
        [switch]$Quiet
    )
    if (-not $Script) { $Script = Split-Path -Leaf $PSCommandPath }
    $id = Get-SkillIdentity
    Write-Output ('SKILL   : ti-c2000-ccs-auto@' + $id.version)

    $copies = Get-SkillScriptCopies -ProjectPath $ProjectPath
    if ($copies.Count -gt 0) {
        if ($Block) {
            Write-Output 'FAILURE: PROJECT_NOT_CLEAN'
            Write-Output 'RESULT: FAIL'
            Write-Output ('REASON: {0} copy/copies of skill scripts sit inside the project, so the run may execute that copy instead of the skill' -f $copies.Count)
            foreach ($c in $copies | Select-Object -First 5) {
                Write-Output ('         ' + $c.FullName.Substring($ProjectPath.Length).TrimStart('\'))
            }
            Write-Output 'HINT    : delete them (they are superseded by this skill), then re-run'
            Write-Output ('HINT    : verify with check_project_entry.ps1 -ProjectPath ' + $ProjectPath)
            exit 2
        }
        Write-Output ('WARN    : {0} copy/copies of skill scripts in this project - reads may follow stale logic' -f $copies.Count)
        foreach ($c in $copies | Select-Object -First 3) {
            Write-Output ('WARN    :   ' + $c.FullName.Substring($ProjectPath.Length).TrimStart('\'))
        }
    }
    Write-SkillRunRecord -ProjectPath $ProjectPath -Script $Script -Mode $Mode -Identity $id
    # callers use the console lines; the object is kept here rather than returned so a
    # plain `Initialize-SkillRun ...` call passes the SKILL line straight through
    $script:LastSkillIdentity = $id
}

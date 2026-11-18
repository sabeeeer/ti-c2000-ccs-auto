#requires -Version 7.0
<#
ti_c2000_probe.ps1 -- how long to wait for a probe to come back, learned per project.

A probe that was just released does NOT return at a fixed time:

  * Windows re-enumerates the FTDI/USB device when the DSS process that owned it exits.
    Measured on XDS100v2 (2026-11-16): ~7 s before it reappears in PnP.
  * Reappearing in PnP is not the same as being usable - the driver needs roughly another
    ~10 s before it can be opened. Measuring the two separately matters, because a check
    that only looks at PnP passes too early and the very next open fails with NO_PROBE.
  * Different probes are different USB implementations (XDS100v2 = FTDI, XDS110 = CDC,
    XDS200 = its own driver), so their re-enumeration times differ by seconds. A number
    tuned on one probe is simply wrong on another.

Therefore the wait is learned, not hard-coded:

  first time    start at 5 s
  each failure  +5 s (and remember that value as a known-bad wait)
  on success    remember the wait that worked
  next time     start at (lastGood + lastBad) / 2 -- a bisection. A fast probe is not
                punished by a slow probe's number, and a slow probe does not pay the fast
                probe's optimism.

Why this exists: a fixed 12 s window produced "the probe went missing again" reports that
looked like hardware faults (power, cable) while the device was simply still enumerating.

Usage:
  . (Join-Path $PSScriptRoot 'ti_c2000_probe.ps1')
  $ok = Wait-ProbeUsable -ProjectPath $pr -ProbeCheck { <returns $true when usable> }
#>

function Get-ProbeWaitState {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Join-Path (Join-Path $ProjectPath 'readout\.service') 'probe-wait.json'
    $r = [ordered]@{ path = $p; okMs = 0; failMs = 0; probe = '' }
    if (-not (Test-Path -LiteralPath $p)) { return $r }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
        if ($null -ne $j.okMs) { $r.okMs = [int]$j.okMs }
        if ($null -ne $j.failMs) { $r.failMs = [int]$j.failMs }
        if ($null -ne $j.probe) { $r.probe = [string]$j.probe }
    } catch { }
    return $r
}

function Get-ProbeConfigKey {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    if ($Ccxml -and (Test-Path -LiteralPath $Ccxml)) {
        return ((Get-Item -LiteralPath $Ccxml).FullName + ':' + (Get-FileHash -LiteralPath $Ccxml -Algorithm SHA256).Hash)
    }
    $dir = Join-Path $ProjectPath 'targetConfigs'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    return (@(Get-ChildItem -LiteralPath $dir -Filter '*.ccxml' -File | Sort-Object Name |
        ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ';')
}

function Save-ProbeWaitState {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [int]$OkMs = 0,
        [int]$FailMs = 0,
        [string]$Probe = ''
    )
    $st = Get-ProbeWaitState -ProjectPath $ProjectPath
    $dir = Split-Path $st.path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{
        okMs      = $OkMs
        failMs    = $FailMs
        probe     = $(if ($Probe) { $Probe } else { $st.probe })
        updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $st.path -Encoding utf8
}

# Windows enumeration and DSS driver access are separate observations. This second
# record learns the elapsed Stop -> verified DSS connection interval for the selected
# target configuration. It is deliberately never updated by a PnP-only check.
function Get-ProbeDriverState {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $path = Join-Path (Join-Path $ProjectPath 'readout\.service') 'probe-driver-wait.json'
    $key = Get-ProbeConfigKey -ProjectPath $ProjectPath -Ccxml $Ccxml
    $s = [ordered]@{ path=$path; probe=$key; stoppedAtMs=0L; badMs=0; goodMs=0 }
    if (Test-Path -LiteralPath $path) {
        try {
            $old = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            if ([string]$old.probe -eq $key) {
                $s.stoppedAtMs = [long]$old.stoppedAtMs
                $s.badMs = [int]$old.badMs
                $s.goodMs = [int]$old.goodMs
            }
        } catch { }
    }
    return $s
}
function Save-ProbeDriverState {
    param([Parameter(Mandatory)]$State)
    $dir = Split-Path $State.path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ordered]@{ probe=$State.probe; stoppedAtMs=$State.stoppedAtMs; badMs=$State.badMs; goodMs=$State.goodMs } |
        ConvertTo-Json | Set-Content -LiteralPath $State.path -Encoding utf8
}
function Mark-ProbeReleased {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $s.stoppedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Save-ProbeDriverState $s
}
function Get-ProbeDriverElapsedMs {
    param([Parameter(Mandatory)]$State)
    if ($State.stoppedAtMs -le 0) { return -1 }
    return [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $State.stoppedAtMs)
}
function Get-ProbeDriverTargetMs {
    param([Parameter(Mandatory)]$State)
    if ($State.goodMs -gt $State.badMs) { return [int](($State.goodMs + $State.badMs) / 2) }
    if ($State.badMs -gt 0) { return [int]($State.badMs + 5000) }
    return 0
}
function Wait-ProbeDriverGap {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '', [switch]$Quiet)
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $elapsed = Get-ProbeDriverElapsedMs $s
    if ($elapsed -lt 0 -or $elapsed -gt 90000) { return }
    $target = [Math]::Min(90000, (Get-ProbeDriverTargetMs $s))
    $wait = [Math]::Max(0, $target - $elapsed)
    if ($wait -gt 0) {
        if (-not $Quiet) { Write-Host ('PROBE   : DSS access delay {0:N1} s (Stop-to-connect target {1:N1} s; bad={2} ms good={3} ms)' -f ($wait/1000.0),($target/1000.0),$s.badMs,$s.goodMs) }
        Start-Sleep -Milliseconds $wait
    }
}
function Mark-ProbeDriverFailure {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $elapsed = Get-ProbeDriverElapsedMs $s
    if ($elapsed -lt 0 -or $elapsed -gt 90000) { return }
    $s.badMs = [Math]::Max($s.badMs, [Math]::Max(1, $elapsed))
    if ($s.goodMs -le $s.badMs) { $s.goodMs = 0 }
    Save-ProbeDriverState $s
}
function Mark-ProbeDriverSuccess {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $elapsed = Get-ProbeDriverElapsedMs $s
    if ($elapsed -lt 0 -or $elapsed -gt 90000) { return }
    if ($elapsed -gt $s.badMs -and ($s.goodMs -eq 0 -or $elapsed -lt $s.goodMs)) { $s.goodMs = $elapsed }
    Save-ProbeDriverState $s
}

<#
Wait-ProbeUsable -- check immediately, then wait and retry until the callback succeeds
or the budget runs out. Its result is only as strong as -ProbeCheck: the current
-ProbeCheckOnly callback checks Windows enumeration, while DSS verifies target access
later with connect and isConnected. Do not call a PnP result "openable".
#>
function Wait-ProbeUsable {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][scriptblock]$ProbeCheck,
        [string]$Ccxml = '',
        [int]$MaxSeconds = 90,
        [switch]$Quiet
    )
    $st = Get-ProbeWaitState -ProjectPath $ProjectPath
    $probeKey = Get-ProbeConfigKey -ProjectPath $ProjectPath -Ccxml $Ccxml
    if ($probeKey -and $st.probe -ne $probeKey) {
        $st.okMs = 0; $st.failMs = 0; $st.probe = $probeKey
    }
    $step = 5000
    $started = Get-Date
    $deadline = $started.AddSeconds($MaxSeconds)

    # A probe that is already present must not pay the recovery delay on every read.
    # This check is also the zero-ms lower bound for a new recovery episode.
    if (& $ProbeCheck) { return $true }
    $lastFailedMs = [int]$st.failMs

    # Bisection start: halfway between the smallest wait that has worked and the smallest
    # that has failed. With no failure recorded yet, trust the last good value; with no
    # history at all, begin at one step.
    if ($st.okMs -gt 0 -and $st.failMs -ge 0 -and $st.failMs -lt $st.okMs) {
        $nextAtMs = [int](($st.okMs + $st.failMs) / 2)
    } elseif ($st.okMs -gt 0) { $nextAtMs = $st.okMs }
    else { $nextAtMs = $step }
    if ($nextAtMs -lt 1000) { $nextAtMs = 1000 }

    while ((Get-Date) -lt $deadline) {
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        $remainingMs = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($remainingMs -le 0) { break }
        $wait = [Math]::Min([Math]::Max(0, $nextAtMs - $elapsedMs), $remainingMs)
        if (-not $Quiet) {
            $src = if ($st.okMs -gt 0 -and $st.failMs -gt 0) { 'bisect' } elseif ($st.okMs -gt 0) { 'learned' } else { 'first run' }
            Write-Host ('PROBE   : waiting {0:N1} s ({1}); history ok={2} ms, fail={3} ms' -f ($wait / 1000.0), $src, $st.okMs, $st.failMs)
        }
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
        $total = [int]((Get-Date) - $started).TotalMilliseconds
        if (& $ProbeCheck) {
            if (-not $Quiet) { Write-Host ('PROBE   : check passed after {0:N1} s total' -f ($total / 1000.0)) }
            Save-ProbeWaitState -ProjectPath $ProjectPath -OkMs $total -FailMs $lastFailedMs -Probe $probeKey
            return $true
        }
        # Store elapsed recovery time, not the last sleep duration. A failed 5 s check
        # followed by a successful 10 s sleep means readiness at 15 s, not 10 s.
        $lastFailedMs = $total
        $st.failMs = $total
        $nextAtMs = $total + $step
    }
    Save-ProbeWaitState -ProjectPath $ProjectPath -OkMs $st.okMs -FailMs $lastFailedMs -Probe $probeKey
    if (-not $Quiet) {
        Write-Host ('PROBE   : still not usable after {0:N0} s; recorded fail={1} ms for the next attempt' -f $MaxSeconds, $st.failMs)
    }
    return $false
}

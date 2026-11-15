#requires -Version 7.0
<#
ti_c2000_loadcount.ps1 -- download counter for one project. Dot-source it:

    . "$PSScriptRoot\ti_c2000_loadcount.ps1"
    $c = Get-LoadCount -ProjectPath $ProjectPath
    $r = Add-LoadRecord -ProjectPath $ProjectPath -Mode SingleStep -Out $Out -Sha256 $sha

File: <project>\readout\load-count.json
It lives OUTSIDE readout\.service on purpose: -Stop deletes the session files but
never the history, so "this is the Nth download" keeps counting across sessions
and across reboots of the service.

Why a counter at all: every loadProgram writes the whole image and connects the
probe again. Frequent reloads wear the target and -- worse -- restart the program,
so two reads describe two different runs. Seeing "LOAD #12" in the output is the
signal that something is reloading in a loop.

Fields:
  count        successful downloads so far (0 = never downloaded)
  firstLoad    timestamp of load #1
  lastLoad     timestamp of the most recent successful load
  lastSha256   sha256 of the image that was loaded
  lastMode     SingleStep | Iterate | LoadRead | Explicit  (every way to download)
  history      last 20 loads, newest last (n / at / mode / out / sha256)

Exit codes: not applicable (dot-source library, no side effects on import).
#>

function Get-LoadCountPath {
    param([Parameter(Mandatory)][string]$ProjectPath)
    return (Join-Path (Join-Path $ProjectPath 'readout') 'load-count.json')
}

function Get-LoadCount {
    param([Parameter(Mandatory)][string]$ProjectPath)

    $o = [ordered]@{
        count      = 0
        firstLoad  = ''
        lastLoad   = ''
        lastSha256 = ''
        lastMode   = ''
        history    = @()
    }
    $path = Get-LoadCountPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $path)) { return $o }
    try {
        $j = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        if ($null -ne $j.count) { $o.count = [int]$j.count }
        if ($null -ne $j.firstLoad) { $o.firstLoad = [string]$j.firstLoad }
        if ($null -ne $j.lastLoad) { $o.lastLoad = [string]$j.lastLoad }
        if ($null -ne $j.lastSha256) { $o.lastSha256 = [string]$j.lastSha256 }
        if ($null -ne $j.lastMode) { $o.lastMode = [string]$j.lastMode }
        if ($null -ne $j.history) { $o.history = @($j.history) }
    } catch {
        # a corrupt counter must never block a load; it only costs the history
    }
    return $o
}

<#
Write-JsonAtomic -- write a JSON file so a concurrent reader never sees half of it.

state.json and load-count.json are read by other processes: a read attaches while -Stop
moves the lock, two readers race, check_project_entry inspects state while a session
starts. A plain WriteAllText truncates the file first, so a reader inside that window gets
an empty or partial document, ConvertFrom-Json throws, the helper returns $null, and the
caller concludes "no session" - a transient race reported as a hard fact.

Write to a sibling temp file and rename over the target: rename on the same volume is
atomic, so a reader sees either the whole old file or the whole new one.

Lives here because this file is the bottom of the dot-source chain (readmode.ps1 sources
it, everything else sources readmode.ps1), so every caller can use it.
#>
function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 6
    )
    $text = $Object | ConvertTo-Json -Depth $Depth
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
    try {
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        # rename blocked (an open handle): fall back to a direct write, which is what the
        # old code did anyway, but at least the temp file is cleaned up
        [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
function Add-LoadRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [ValidateSet('SingleStep', 'Iterate', 'LoadRead', 'Explicit')][string]$Mode = 'SingleStep',
        [string]$Out = '',
        [string]$Sha256 = '',
        [string]$At = ''
    )

    if (-not $At) { $At = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $cur = Get-LoadCount -ProjectPath $ProjectPath
    $n = [int]$cur.count + 1

    $entry = [ordered]@{ n = $n; at = $At; mode = $Mode; out = $Out; sha256 = $Sha256 }
    $history = @(@($cur.history) + @($entry))
    if ($history.Count -gt 20) { $history = @($history[($history.Count - 20)..($history.Count - 1)]) }

    $out2 = [ordered]@{
        count      = $n
        firstLoad  = $(if ($cur.firstLoad) { $cur.firstLoad } else { $At })
        lastLoad   = $At
        lastSha256 = $Sha256
        lastMode   = $Mode
        history    = $history
    }

    try {
        $dir = Split-Path -Parent (Get-LoadCountPath -ProjectPath $ProjectPath)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-JsonAtomic -Path (Get-LoadCountPath -ProjectPath $ProjectPath) -Object $out2
    } catch {
        # counting is bookkeeping, not a reason to fail a load that already ran
    }

    return [ordered]@{ count = $n; previous = [int]$cur.count; at = $At; totalHistory = $history.Count }
}

<#
Test-LoadExpectation -- evaluate "name OP value" checks against one sample row.

  $r = Test-LoadExpectation -Expect @('gBufSeq>=3','gErr==0') -Values @{ gBufSeq='1'; gErr='0' }
  $r.ok        -> $false
  $r.checks    -> @('gBufSeq>=3 -> got 1, FAIL', 'gErr==0 -> got 0, OK')

Used by the LoadRead -MaxLoads loop to decide "data is right, stop reloading".
Badly formed expressions are reported as UNPARSED and count as a failure, so a
typo can never be mistaken for success.
#>
function Test-LoadExpectation {
    param(
        [string[]]$Expect = @(),
        [hashtable]$Values = @{}
    )

    $checks = New-Object System.Collections.Generic.List[string]
    $ok = $true
    foreach ($e in @($Expect)) {
        $text = ([string]$e).Trim()
        if (-not $text) { continue }
        $m = [regex]::Match($text, '^([A-Za-z_][\w\.\[\]]*)\s*(>=|<=|==|!=|>|<)\s*(-?\d+(?:\.\d+)?)$')
        if (-not $m.Success) {
            $ok = $false
            $checks.Add(('{0} -> UNPARSED (use name>=value / name<=value / name==value)' -f $text))
            continue
        }
        $name = $m.Groups[1].Value
        $op = $m.Groups[2].Value
        $want = [double]$m.Groups[3].Value
        $raw = [string]$Values[$name]
        $got = 0.0
        if (-not [double]::TryParse($raw, [ref]$got)) {
            $ok = $false
            $checks.Add(('{0} -> MISSING (no numeric value for {1})' -f $text, $name))
            continue
        }
        $pass = switch ($op) {
            '>=' { $got -ge $want }
            '<=' { $got -le $want }
            '==' { $got -eq $want }
            '!=' { $got -ne $want }
            '>' { $got -gt $want }
            '<' { $got -lt $want }
            default { $false }
        }
        if (-not $pass) { $ok = $false }
        $checks.Add(('{0} -> got {1}, {2}' -f $text, $raw, $(if ($pass) { 'OK' } else { 'FAIL' })))
    }
    return [ordered]@{ ok = $ok; checks = @($checks) }
}

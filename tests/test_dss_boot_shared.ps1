#requires -Version 7.0
# The connect / reset / load / run sequence used to be copy-pasted into three DSS
# templates. On 2026-11-15 the service learned to verify connect() and to stop on Error
# -1138 while both one-shot readers kept the old, broken copy. This test makes that
# class of drift impossible to reintroduce: one shared file, three injection points.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $root 'scripts'
$boot = Join-Path $scripts 'ti_c2000_dss_boot.js'
$entries = @('ti_c2000_service.ps1', 'ti_c2000_run_read.ps1', 'ti_c2000_read_dma.ps1')
$problems = New-Object System.Collections.Generic.List[string]

# 1. the shared file exists, defines the sequence, and does not contain the marker itself
if (-not (Test-Path -LiteralPath $boot)) {
    $problems.Add('ti_c2000_dss_boot.js is missing')
} else {
    $b = [IO.File]::ReadAllText($boot)
    foreach ($fn in @('dssLinkIsUp', 'dssBoardRefusedDebug', 'dssConnectVerified', 'dssResetVerified', 'dssLoadWithRetry', 'dssRunVerified', 'dssShutdown')) {
        if ($b -notmatch ('function\s+' + [regex]::Escape($fn) + '\s*\(')) { $problems.Add("$fn is not defined in ti_c2000_dss_boot.js") }
    }
    # a comment naming the marker makes "did the placeholder survive?" unusable
    if ($b -match '//__BOOT__') { $problems.Add('ti_c2000_dss_boot.js mentions its own injection marker, which defeats the placeholder check') }
}

# 2. every entry point uses the shared sequence
foreach ($e in $entries) {
    $p = Join-Path $scripts $e
    if (-not (Test-Path -LiteralPath $p)) { $problems.Add("$e is missing"); continue }
    $t = [IO.File]::ReadAllText($p)

    if (-not $t.Contains('//__BOOT__')) { $problems.Add("$e has no //__BOOT__ placeholder, so the shared sequence is never injected") }
    if ($t -notmatch 'ti_c2000_dss_boot\.js') { $problems.Add("$e does not read ti_c2000_dss_boot.js") }
    foreach ($fn in @('dssConnectVerified', 'dssResetVerified', 'dssLoadWithRetry', 'dssRunVerified')) {
        if ($t -notmatch [regex]::Escape($fn) + '\s*\(') { $problems.Add("$e does not call $fn") }
    }

    # 3. no entry point may keep its own copy of the sequence
    foreach ($legacy in @('var connected = false', 'for (var i = 1; i <= 3 && !connected', 'function linkIsUp', 'function boardRefusedDebug')) {
        if ($t.Contains($legacy)) { $problems.Add("$e still carries its own copy of the boot sequence ($legacy) - import it from ti_c2000_dss_boot.js instead") }
    }
    # exactly one concrete loadProgram call site per generated script: inside the shared file
    if ($t -match 'session\.memory\.loadProgram') { $problems.Add("$e calls session.memory.loadProgram directly - that belongs in dssLoadWithRetry") }
}

if ($problems.Count -gt 0) {
    Write-Output 'FAILURE: DSS_BOOT_NOT_SHARED'
    foreach ($p in $problems) { Write-Output ('VIOLATION: ' + $p) }
    Write-Output 'RESULT: FAIL'
    exit 1
}

Write-Output ('CHECK   : {0} entry points all inject the shared boot sequence' -f $entries.Count)
Write-Output 'RESULT: OK'
exit 0

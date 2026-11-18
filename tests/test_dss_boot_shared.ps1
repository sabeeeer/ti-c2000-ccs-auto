#requires -Version 7.0
# Only the retained service owns DSS connect/reset/load/run. Public readers attach
# through it, so a read cannot end by halting or disconnecting a one-shot session.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $root 'scripts'
$boot = Join-Path $scripts 'ti_c2000_dss_boot.js'
$entries = @('ti_c2000_service.ps1')
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
foreach ($reader in @('ti_c2000_run_read.ps1','ti_c2000_read_dma.ps1')) {
    $t = [IO.File]::ReadAllText((Join-Path $scripts $reader))
    if ($t -notmatch 'Invoke-RetainedLoadRead' -or $t -match 'dssLoadWithRetry|dssShutdown|session\.target\.halt\(') {
        $problems.Add("$reader must load through the retained service and never shut down DSS after reading")
    }
}

# 3b. the two implementations of the cmd.txt/res.txt exchange must stay in step. They live
# in different files (readmode for the preflight helpers, live_read for sampling), and on
# 2026-11-15 one of them was fixed while the other kept returning the previous response.
$ioChecks = @(
    @{ file = 'ti_c2000_readmode.ps1'; what = 'Get-SessionExpressions' },
    @{ file = 'ti_c2000_live_read.ps1'; what = 'Send-Request' }
)
foreach ($io in $ioChecks) {
    $p = Join-Path $scripts $io.file
    if (-not (Test-Path -LiteralPath $p)) { $problems.Add("$($io.file) is missing"); continue }
    $t = [IO.File]::ReadAllText($p)
    if ($t -notmatch 'for \(\$c = 0; \$c -lt 10') {
        $problems.Add("$($io.what) in $($io.file) must retry clearing res.txt; a single Remove-Item can leave the previous response and the caller then parses a stale answer")
    }
    if ($t -notmatch "Move-Item -LiteralPath \`$tmp") {
        $problems.Add("$($io.what) in $($io.file) must write cmd.txt through a temp file; a direct WriteAllText lets the service read half a command")
    }
}

# 4. every constant a DSS template uses must be defined in it. A template is JavaScript
# inside a here-string: PowerShell cannot type-check it, so a leftover reference (WARMUP,
# after the boot sequence moved out) only fails inside Rhino on the board. The audit runs
# its own self-test first, so "clean" here means a detector that has been proven to fire.
$audit = Join-Path $root 'tools\audit_js_identifiers.ps1'
if (Test-Path -LiteralPath $audit) {
    $selfOut = @(& pwsh -NoProfile -File $audit -SelfTest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $problems.Add('the JS identifier detector failed its own self-test: ' + (($selfOut | ForEach-Object { [string]$_ }) -join '; '))
    } else {
        $auditOut = @(& pwsh -NoProfile -File $audit 2>&1)
        if ($LASTEXITCODE -ne 0) {
            foreach ($l in $auditOut) { if ([string]$l -match '^REASON:') { $problems.Add([string]$l) } }
            if (-not @($auditOut | Where-Object { [string]$_ -match '^REASON:' }).Count) {
                $problems.Add('the JS identifier audit failed without a reason: ' + (($auditOut | ForEach-Object { [string]$_ }) -join '; '))
            }
        }
    }
} else {
    $problems.Add('tools\audit_js_identifiers.ps1 is missing, so undefined identifiers in DSS templates go unnoticed')
}

# 5. a parameter nothing reads is a documented promise the code cannot keep. -FrozenValue
# was declared on live_read, documented, forwarded by read_dma, and never used, so the DMA
# freezing criterion only ever checked "the flag did not change" - which an always-0 flag
# satisfies while the buffer is still being written.
$deadAudit = Join-Path $root 'tools\audit_dead_params.ps1'
if (Test-Path -LiteralPath $deadAudit) {
    $deadOut = @(& pwsh -NoProfile -File $deadAudit 2>&1)
    if ($LASTEXITCODE -ne 0) {
        foreach ($l in $deadOut) { if ([string]$l -match '^REASON:') { $problems.Add([string]$l) } }
        if (-not @($deadOut | Where-Object { [string]$_ -match '^REASON:' }).Count) {
            $problems.Add('the dead-parameter audit failed without a reason: ' + (($deadOut | ForEach-Object { [string]$_ }) -join '; '))
        }
    }
} else {
    $problems.Add('tools\audit_dead_params.ps1 is missing, so parameters nobody reads go unnoticed')
}

# 6. every script must agree with references\firmware-contract.json. These firmware
# symbols used to be hard-coded in twelve places and had already drifted (FrozenValue
# 'true' vs '1'; the heartbeat candidate set differing across four files).
$fwAudit = Join-Path $root 'tools\audit_fw_contract.ps1'
if (Test-Path -LiteralPath $fwAudit) {
    $selfOut = @(& pwsh -NoProfile -File $fwAudit -SelfTest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $problems.Add('the firmware-contract detector failed its own self-test: ' + (($selfOut | ForEach-Object { [string]$_ }) -join '; '))
    } else {
        $fwOut = @(& pwsh -NoProfile -File $fwAudit 2>&1)
        if ($LASTEXITCODE -ne 0) {
            foreach ($l in $fwOut) { if ([string]$l -match '^REASON:') { $problems.Add([string]$l) } }
            if (-not @($fwOut | Where-Object { [string]$_ -match '^REASON:' }).Count) {
                $problems.Add('the firmware-contract audit failed without a reason: ' + (($fwOut | ForEach-Object { [string]$_ }) -join '; '))
            }
        }
    }
} else {
    $problems.Add('tools\audit_fw_contract.ps1 is missing, so firmware symbols can drift between scripts again')
}

# 7. every error code must use the prefix matching its exit code: USAGE + exit 2 for a wrong
# command, FAILURE + exit 1/3/4 for a failed validation. Mixing them made a missing
# -CorePattern read as "a check refused to download" (2026-11-16). Environment problems
# (ENV_*, NO_*, MAP_MISSING) legitimately keep FAILURE + exit 2.
$prefixAudit = Join-Path $root 'tools\audit_error_prefix.ps1'
if (Test-Path -LiteralPath $prefixAudit) {
    $selfOut = @(& pwsh -NoProfile -File $prefixAudit -SelfTest 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $problems.Add('the error-prefix detector failed its own self-test: ' + (($selfOut | ForEach-Object { [string]$_ }) -join '; '))
    } else {
        $prefOut = @(& pwsh -NoProfile -File $prefixAudit 2>&1)
        if ($LASTEXITCODE -ne 0) {
            foreach ($l in $prefOut) { if ([string]$l -match '^\s{2}\S+:\d+') { $problems.Add([string]$l) } }
            if (-not @($prefOut | Where-Object { [string]$_ -match '^\s{2}\S+:\d+' }).Count) {
                $problems.Add('the error-prefix audit failed without naming a site: ' + (($prefOut | ForEach-Object { [string]$_ }) -join '; '))
            }
        }
    }
} else {
    $problems.Add('tools\audit_error_prefix.ps1 is missing, so USAGE/FAILURE can drift apart again')
}

if ($problems.Count -gt 0) {
    Write-Output 'FAILURE: DSS_BOOT_NOT_SHARED'
    foreach ($p in $problems) { Write-Output ('VIOLATION: ' + $p) }
    Write-Output 'RESULT: FAIL'
    exit 1
}

Write-Output 'CHECK   : retained service is the sole DSS loader; both readers use it'
Write-Output 'RESULT: OK'
exit 0

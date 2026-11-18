#requires -Version 7.0
# Regression for the service.ps1 entry-point gate.
#
# What the gate must do (corrected 2026-11-18; the first版本 of this test asserted the
# retracted rule and was wrong):
#   * refuse an .out whose ENTRY POINT SYMBOL CONFLICTS with the .cproject declaration
#     (linkerID.ENTRY_POINT)
#   * accept an .out whose entry matches that declaration
#   * accept _c_int00 when no declaration exists (the linker default is always legal)
#
# Do NOT read this test as "code_start is forbidden" - code_start is exactly what this
# project declares, and --entry_point=code_start is the correct build (LOAD #116/#119).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $skillRoot 'scripts/ti_c2000_service.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('c2000-entry-gate-' + [guid]::NewGuid().ToString('N'))
$targetDir = Join-Path $tempRoot 'targetConfigs'
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

function New-MapFixture([string]$entrySymbol) {
    $nl = "`r`n"
    @(
        '******************************************************************************'
        '             TMS320C2000 Linker PC v15.12.1'
        '******************************************************************************'
        '>> Linked Wed Nov 18 17:57:55 2026'
        ''
        'OUTPUT FILE NAME:   <x.out>'
        ('ENTRY POINT SYMBOL: "{0}"  address: 00000000' -f $entrySymbol)
        ''
        'MEMORY CONFIGURATION'
    ) -join $nl | Set-Content -LiteralPath (Join-Path $tempRoot 'x.map') -Encoding utf8 -NoNewline
}

function Invoke-Gate {
    param([string]$MapPath, [switch]$Allow)
    $args = @('-NoProfile', '-File', $scriptPath, '-ProjectPath', $tempRoot, '-Start', '-ConfirmLoad',
              '-OutFile', (Join-Path $tempRoot 'x.out'), '-MapFile', $MapPath)
    if ($Allow) { $args += '-AllowNonDefaultEntry' }
    $out = & pwsh @args 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

try {
    # A .out is required to exist before the gate runs; content does not matter for the gate.
    Set-Content -LiteralPath (Join-Path $tempRoot 'x.out') -Value 'placeholder' -Encoding utf8
    # ...and the entry checks run before the gate, so the project must look like a CCS project.
    Set-Content -LiteralPath (Join-Path $tempRoot '.cproject') -Value '<cproject/>' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $targetDir 'x.ccxml') -Value '<configurations/>' -Encoding utf8

    # NOTE: this fixture deliberately has NO linkerID.ENTRY_POINT, so the gate is in its
    # "no declaration to compare against" mode and only _c_int00 is legal. That is the one
    # branch that can be exercised without letting the gate pass and start a real DSS
    # session. The "declaration matches -> accept" branch is covered by the live run
    # (2026-11-18: .cproject declares code_start, --entry_point=code_start, LOAD #116/#119)
    # and by test_doc_entry_point_rule.ps1, which asserts the comparison logic exists.
    New-MapFixture 'code_start'
    $r = Invoke-Gate -MapPath (Join-Path $tempRoot 'x.map')
    # Machines without CCS (CI runner) or without a usable probe fail earlier with
    # ENV_NO_CCS / PROBE_CHECK_FAILED, so the entry-point gate can never be reached.
    # Skip instead of reporting a false failure; equipped machines run every assertion.
    if ($r.Text -match 'ENV_NO_CCS|PROBE_CHECK_FAILED|PROBE_DRIVER_UNUSABLE') {
        Write-Output 'SKIP: no CCS/probe on this machine - entry-point gate cannot be exercised'
        Write-Output 'RESULT: OK'
        exit 0
    }
    if ($r.Code -ne 4) { throw "code_start must be refused with exit 4, got $($r.Code): $($r.Text)" }
    if ($r.Text -notmatch 'FAILURE: NON_DEFAULT_ENTRY_POINT') { throw "missing NON_DEFAULT_ENTRY_POINT: $($r.Text)" }
    if ($r.Text -notmatch 'RESULT: FAIL') { throw 'refusal must print RESULT: FAIL' }
    # The refusal must happen before any DSS work: no session/log artefacts may appear.
    if (Test-Path (Join-Path $tempRoot 'readout\.service\server.log')) { throw 'gate ran after DSS started (server.log exists)' }

    New-MapFixture '_c_int00'
    $r2 = Invoke-Gate -MapPath (Join-Path $tempRoot 'x.map')
    if ($r2.Text -match 'NON_DEFAULT_ENTRY_POINT') { throw "_c_int00 must not be refused: $($r2.Text)" }
    if ($r2.Text -notmatch 'ENTRY    : _c_int00') { throw "_c_int00 pass should be reported: $($r2.Text)" }

    New-MapFixture 'code_start'
    $r3 = Invoke-Gate -MapPath (Join-Path $tempRoot 'x.map') -Allow
    if ($r3.Text -match 'NON_DEFAULT_ENTRY_POINT') { throw '-AllowNonDefaultEntry must bypass the gate' }

    Write-Output 'PASS: gate refuses code_start only when .cproject declares nothing; _c_int00 always passes; -AllowNonDefaultEntry bypasses'
    Write-Output 'RESULT: OK'
    exit 0
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output 'RESULT: FAIL'
    exit 1
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

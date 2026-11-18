#requires -Version 7.0
<#
audit_build_options.ps1 -- report every .cproject build option that ti_c2000_build.ps1
does not map to a compiler/linker flag.

Why this exists: the build script mirrors the CCS build by hand, and a hand-written mirror
drifts silently. Measured 2026-11-15: .cproject declared ENTRY_POINT=code_start,
CLA_SUPPORT=cla1, VCU_SUPPORT=vcu2 and XML_LINK_INFO, and the script passed none of them.
Nothing failed - the .out simply had a different entry point than the CCS build of the same
sources - which is the worst kind of divergence: invisible until a Flash boot vector or a
CLA task behaves differently.

This is a REPORT, not a gate: some declared options genuinely have no command-line form
(for example DEBUGGING_MODEL is folded into -g). Read each UNMAPPED line and decide.

    pwsh -NoProfile -File tools/audit_build_options.ps1 -ProjectPath <ccs project>

Exit code: 0 = every declared option is mapped or explained, 1 = UNMAPPED options remain.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

$cproj = Join-Path $ProjectPath '.cproject'
if (-not (Test-Path -LiteralPath $cproj)) {
    Out2 'USAGE: NO_PROJECT'; Out2 'RESULT: FAIL'; Out2 "REASON: no .cproject under '$ProjectPath'"; exit 2
}

# Options the build script really consumes (keep in sync with Get-OptionValue/Get-OptionList
# calls in ti_c2000_build.ps1).
$mapped = @(
    'compilerID.SILICON_VERSION'
    'compilerID.LARGE_MEMORY_MODEL'
    'compilerID.UNIFIED_MEMORY'
    'compilerID.FLOAT_SUPPORT'
    'compilerID.TMU_SUPPORT'
    'compilerID.CLA_SUPPORT'
    'compilerID.VCU_SUPPORT'
    'compilerID.DEFINE'
    'compilerID.OPT_LEVEL'
    'compilerID.OPT_FOR_SPEED'
    'compilerID.FP_MODE'
    'compilerID.LANGUAGE_MODE'
    'compilerID.DIAG_WARNING'
    'compilerID.DIAG_SUPPRESS'
    'compilerID.OTHER_FLAGS'
    'compilerID.INCLUDE_PATH'
    'compilerID.DISPLAY_ERROR_NUMBER'
    'compilerID.DEBUGGING_MODEL'
    'linkerID.STACK_SIZE'
    'linkerID.RAM_MODEL'
    'linkerID.SEARCH_PATH'
    'linkerID.DIAG_SUPPRESS'
    'linkerID.PRIORITY'
    'linkerID.ENTRY_POINT'
    'linkerID.XML_LINK_INFO'
    'linkerID.LIBRARY'
    'linkerID.OUTPUT_FILE'
    'linkerID.MAP_FILE'
    'linkerID.DISPLAY_ERROR_NUMBER'
)
# Declared by CCS but expressed as something other than a flag we can pass verbatim.
$explained = @{
    'compilerID.DEBUGGING_MODEL' = 'folded into -g'
    'linkerID.OUTPUT_FILE'       = 'the script names the .out itself'
    'linkerID.MAP_FILE'          = 'the script names the .map itself'
    'linkerID.DISPLAY_ERROR_NUMBER' = 'always passed'
    'compilerID.DISPLAY_ERROR_NUMBER' = 'always passed'
}

[xml]$c = Get-Content -LiteralPath $cproj -Raw
$declared = @($c.SelectNodes('//option') |
    ForEach-Object { $_.GetAttribute('superClass') } |
    Where-Object { $_ -match 'compilerID\.|linkerID\.' } |
    ForEach-Object {
        # com.ti.ccstudio.buildDefinitions.C2000_15.12.compilerID.X -> compilerID.X
        # (the version part contains dots, so a single [^.]+ does not work)
        $s = $_ -replace '^com\.ti\.ccstudio\.buildDefinitions\.', ''
        $s = $s -replace '^C2000_[0-9.]+\.', ''
        $s
    } |
    Sort-Object -Unique)

$unmapped = @()
$rows = @()
foreach ($d in $declared) {
    if ($mapped -contains $d) {
        $note = if ($explained.ContainsKey($d)) { 'mapped (' + $explained[$d] + ')' } else { 'mapped' }
    } else {
        $unmapped += $d
        $note = 'UNMAPPED'
    }
    $rows += ('  {0,-34} {1}' -f ($d -replace '^.*\.', ''), $note)
}

Info2 ('PROJECT : ' + (Get-Item -LiteralPath $ProjectPath).FullName)
Info2 ('DECLARED: {0} compiler/linker options in .cproject' -f $declared.Count)
Info2 '--- option                              status'
$rows | ForEach-Object { Info2 $_ }

if ($unmapped.Count -gt 0) {
    Out2 ''
    Out2 'FAILURE: BUILD_OPTIONS_UNMAPPED'; Out2 'RESULT: FAIL'
    foreach ($u in $unmapped) {
        Out2 ('REASON: .cproject declares {0}, which ti_c2000_build.ps1 never passes - the .out may differ from a CCS build of the same sources' -f $u)
    }
    Out2 'HINT    : add the mapping to ti_c2000_build.ps1, or record it in this script''s $explained table with a reason'
    exit 1
}

Out2 ''
Out2 ('CHECK   : all {0} declared build options are mapped or explained' -f $declared.Count)
Out2 'RESULT: OK'
exit 0

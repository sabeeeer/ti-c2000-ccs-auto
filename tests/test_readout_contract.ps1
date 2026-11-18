#requires -Version 7.0
# The retained service is the only loader; all public reads attach to it and
# the protocol client publishes a verdict in the one project readout directory.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $root 'scripts'
$bad = New-Object System.Collections.Generic.List[string]
foreach ($name in @('ti_c2000_run_read.ps1','ti_c2000_read_continuous.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $scripts $name))
    if ($text -notmatch 'Invoke-RetainedLoadRead' -or $text -notmatch 'ti_c2000_live_read.ps1') {
        $bad.Add("$name does not route LoadRead and ReadOnly through the retained service")
    }
    if ($text -match 'dss\.bat|dssShutdown|session\.target\.halt\(') {
        $bad.Add("$name can still open or halt a one-shot DSS session")
    }
}
$live = [IO.File]::ReadAllText((Join-Path $scripts 'ti_c2000_live_read.ps1'))
foreach ($required in @("Join-Path `$ProjectPath 'readout\data'",'FW_ID_UNREADABLE','HEARTBEAT_FAIL','DATA_UNRELIABLE','verdict.txt','INTERNAL_ONLY')) {
    if ($live -notmatch [regex]::Escape($required)) { $bad.Add("live_read missing $required") }
}
foreach ($required in @("'-RangeVars', 'value'", "'-ExpectedRows'", 'ramAliveAfter', 'appAliveAfter')) {
    if ($live -notmatch [regex]::Escape($required)) { $bad.Add("array verdict omits $required") }
}
foreach ($gone in @('ti_c2000_read_runtime.ps1','ti_c2000_read_array_runtime.ps1','dss_template.js')) {
    if (Test-Path -LiteralPath (Join-Path $scripts $gone)) { $bad.Add("obsolete reader returned: $gone") }
}
if ($bad.Count) {
    Write-Output 'FAILURE: READOUT_CONTRACT'; foreach ($item in $bad) { Write-Output "VIOLATION: $item" }
    Write-Output 'RESULT: FAIL'; exit 1
}
Write-Output 'CHECK   : one retained loader, two public readers, one verdict-writing protocol client'
Write-Output 'RESULT: OK'

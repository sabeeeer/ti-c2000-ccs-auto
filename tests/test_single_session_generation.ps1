#requires -Version 7.0
# Generate the retained service DSS script with a fake executable; no board or
# actual load occurs. Public readers must not generate their own DSS program.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-service-js-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'skill/scripts'
$refs = Join-Path $fixture 'skill/references'
$project = Join-Path $fixture 'project'
$ccs = Join-Path $fixture 'ccs'
$dssDir = Join-Path $ccs 'ccs_base/scripting/bin'
try {
    New-Item -ItemType Directory -Force -Path $scripts,$refs,$project,$dssDir,(Join-Path $project 'Debug'),(Join-Path $project 'targetConfigs') | Out-Null
    Copy-Item (Join-Path $root 'scripts/*') $scripts -Recurse -Force
    Copy-Item (Join-Path $root 'references/firmware-contract.json') $refs
    @'
param([string]$ProjectPath,[string]$CcsRoot,[switch]$ProbeCheckOnly)
Write-Output 'RESULT: OK'
exit 0
'@ | Set-Content (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding utf8
    '<project/>' | Set-Content (Join-Path $project '.cproject')
    '<projectDescription><name>DemoImage</name></projectDescription>' | Set-Content (Join-Path $project '.project')
    '<configurations/>' | Set-Content (Join-Path $project 'targetConfigs/target.ccxml')
    'fake' | Set-Content (Join-Path $project 'Debug/DemoImage.out')
    "MEMORY CONFIGURATION`nPAGE 0:`n  RAMLS0   00008000   00001000   00000000   00001000 RWIX`nSECTION ALLOCATION MAP`n  .text  0  00008000  00000010`n" | Set-Content (Join-Path $project 'Debug/DemoImage.map')
    $capture = Join-Path $fixture 'service.js'
    @"
@echo off
copy /Y "%~1" "$capture" >nul
exit /b 1
"@ | Set-Content (Join-Path $dssDir 'dss.bat') -Encoding ASCII
    $result = @(& pwsh -NoProfile -File (Join-Path $scripts 'ti_c2000_service.ps1') -ProjectPath $project -CcsRoot $ccs -Start -ConfirmLoad -StartTimeoutSec 3 2>&1)
    $generated = Join-Path $project 'readout/.service/server.js'
    if ($LASTEXITCODE -eq 0 -or -not (Test-Path -LiteralPath $generated)) { throw "fake service did not generate DSS: $($result -join '; ')" }
    $js = [IO.File]::ReadAllText($generated)
    foreach ($needed in @('getListOfCPUs()','cpuMatches.length !== 1','server.openSession(cpuMatches[0])','session.getCPUName()','core.txt','dssConnectVerified(session','dssResetVerified(session','dssLoadWithRetry(session, OUT','dssRunVerified(session','isConnected(true)','SERVICE: READY')) {
        if (-not $js.Contains($needed)) { throw "generated service lacks $needed" }
    }
    if ([regex]::Matches($js,'dssLoadWithRetry\(session, OUT').Count -ne 1) { throw 'generated service has multiple load call sites' }
    Write-Output 'CHECK   : one generated retained DSS loader; connect verification and single load call present'
    Write-Output 'RESULT: OK'; exit 0
} catch {
    Write-Output 'FAILURE: TEST_FAILED'; Write-Output ('REASON: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'; exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

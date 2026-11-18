#requires -Version 7.0
# Offline stop test: simulated DSS process state, real service control flow.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-stop-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'skill/scripts'
$refs = Join-Path $fixture 'skill/references'
$project = Join-Path $fixture 'project'
$serviceDir = Join-Path $project 'readout/.service'
try {
    New-Item -ItemType Directory -Force -Path $scripts,$refs,$serviceDir | Out-Null
    foreach ($name in @('ti_c2000_service.ps1','ti_c2000_readmode.ps1','ti_c2000_probe.ps1','ti_c2000_loadcount.ps1','ti_c2000_fwcontract.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "scripts/$name") -Destination $scripts
    }
    Copy-Item -LiteralPath (Join-Path $root 'references/firmware-contract.json') -Destination $refs
    Set-Content -LiteralPath (Join-Path $project '.cproject') -Value '<project/>'
    @'
param([switch]$ProbeCheckOnly)
Write-Output 'RESULT: OK'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $scripts 'ti_c2000_debug.ps1')

    foreach ($clean in @($true,$false)) {
        Remove-Item -LiteralPath (Join-Path $serviceDir 'stopped.txt'),(Join-Path $serviceDir 'cmd.txt') -Force -ErrorAction SilentlyContinue
        $state = @{ pid=12345; started='fixture'; out='fixture.out'; outSha256='fixture'; core='CPU1'; runMode='SingleStep' } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $serviceDir 'state.json') -Value $state
        Set-Content -LiteralPath (Join-Path $serviceDir 'ready.txt') -Value 'ready'
        $job = Start-ThreadJob -ArgumentList @((Join-Path $scripts 'ti_c2000_service.ps1'),$project,$clean) -ScriptBlock {
            param($serviceScript,$projectPath,$markClean)
            $script:fakeCmd = Join-Path $projectPath 'readout/.service/cmd.txt'
            $script:fakeStopped = Join-Path $projectPath 'readout/.service/stopped.txt'
            $script:fakeClean = $markClean
            function Get-Process {
                param([int]$Id,[object]$ErrorAction)
                if ($Id -eq 12345 -and -not (Test-Path -LiteralPath $script:fakeCmd)) { return [pscustomobject]@{ Id=12345 } }
                if ($Id -eq 12345 -and $script:fakeClean) { Set-Content -LiteralPath $script:fakeStopped -Value 'clean' }
                return $null
            }
            . $serviceScript -ProjectPath $projectPath -Stop -Quiet
        }
        $null = Wait-Job $job -Timeout 12
        if ($job.State -ne 'Completed') { throw 'simulated stop did not finish' }
        $result = @(Receive-Job $job)
        $joined = $result -join "`n"
        if ($clean -and $joined -notmatch 'RESULT: OK') { throw "clean stop failed: $joined" }
        if (-not $clean -and $joined -notmatch 'STOP_UNCLEAN') { throw "unclean stop was accepted: $joined" }
        if (Test-Path -LiteralPath (Join-Path $serviceDir 'state.json')) { throw 'stop retained active state' }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    'RESULT: OK'
} catch {
    'FAILURE: TEST_FAILED'; 'REASON: ' + $_.Exception.Message; 'RESULT: FAIL'; exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

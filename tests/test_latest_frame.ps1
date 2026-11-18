#requires -Version 7.0
# Offline DSS-file-protocol test: the first ping-pong copy races a bank switch;
# the second must select the newly published bank and keep only that frame.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('c2000-latest-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $tmp 'skill/scripts'
$project = Join-Path $tmp 'project'
$svc = Join-Path $project 'readout/.service'
try {
    New-Item -ItemType Directory -Force -Path $scripts,$svc,(Join-Path $tmp 'skill/references'),(Join-Path $project 'targetConfigs'),(Join-Path $project 'Debug') | Out-Null
    Copy-Item (Join-Path $root 'scripts/*') $scripts -Recurse -Force
    Copy-Item (Join-Path $root 'references/firmware-contract.json') (Join-Path $tmp 'skill/references')
    @'
param([string]$ProjectPath,[string]$CcsRoot,[switch]$ProbeCheckOnly)
'RESULT: OK'
exit 0
'@ | Set-Content (Join-Path $scripts 'ti_c2000_debug.ps1') -Encoding utf8
    [IO.File]::WriteAllText((Join-Path $project '.cproject'), '<project/>')
    [IO.File]::WriteAllText((Join-Path $project 'targetConfigs/target.ccxml'), '<configurations/>')
    $out = Join-Path $project 'Debug/project.out'
    $map = Join-Path $project 'Debug/project.map'
    [IO.File]::WriteAllBytes($out, [byte[]](1..64))
    [IO.File]::WriteAllText($map, "MEMORY CONFIGURATION`nPAGE 0:`n  RAMLS0   00008000   00001000   00000000   00001000  RWIX`nSECTION ALLOCATION MAP`n  .text  0  00008000  00000100`n")
    $sha = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
    $mapSha = (Get-FileHash -LiteralPath $map -Algorithm SHA256).Hash
    @{pid=$PID; started=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); out=$out; outSha256=$sha; map=$map; mapSha256=$mapSha; core='C28xx_CPU1'; fwId='65537'; loadIndex=1} |
        ConvertTo-Json | Set-Content (Join-Path $svc 'state.json') -Encoding utf8
    [IO.File]::WriteAllText((Join-Path $svc 'ready.txt'), 'ready')
    $stub = Join-Path $tmp 'stub.ps1'
    @'
param([string]$Dir)
$cmd = Join-Path $Dir 'cmd.txt'; $res = Join-Path $Dir 'res.txt'
$tick = 1000; $bankReads = 0
[IO.File]::WriteAllText((Join-Path $Dir 'stub-ready.txt'), 'up')
while ($true) {
    if ((Test-Path $cmd) -and -not (Test-Path $res)) {
        $c = (Get-Content $cmd -Raw).Trim()
        $lines = @('HALTED 0')
        if ($c -like 'ADDR *') {
            foreach ($n in ($c.Substring(5) -split '\|')) {
                if ($n -eq 'TiC2000_RamProofTick') { $lines += 'P TiC2000_RamProofTick 32960' }
                elseif ($n -eq 'gRamProofTick') { $lines += 'P gRamProofTick 32964' }
            }
        } elseif ($c -like 'VARS *') {
            if ($c -match 'gDmaSeq' -and $c -match 'gDmaBank') { $bankReads++ }
            foreach ($n in ($c.Substring(5) -split '\|')) {
                switch ($n) {
                    'gFwId' { $lines += 'V gFwId 65537' }
                    'gMsTick' { $lines += ('V gMsTick ' + $tick); $tick += 1000 }
                    'gRamProofTick' { $lines += ('V gRamProofTick ' + $tick); $tick += 1000 }
                    'gDmaSeq' { $lines += ('V gDmaSeq ' + $(if ($bankReads -eq 1) { 1 } else { 2 })) }
                    'gDmaBank' { $lines += ('V gDmaBank ' + $(if ($bankReads -eq 1) { 0 } else { 1 })) }
                    'buffer0[0]' { $lines += 'V buffer0[0] 10' }
                    'buffer1[0]' { $lines += 'V buffer1[0] 20' }
                }
            }
        } elseif ($c -like 'ARRAY *') {
            $first = if ($c -like 'ARRAY buffer1*') { 20 } else { 10 }
            for ($i=0; $i -lt 3; $i++) { $lines += ('A ' + $i + ' ' + ($first + $i)) }
        }
        $lines += 'END'
        [IO.File]::WriteAllText($res, ($lines -join "`n"))
        Remove-Item -LiteralPath $cmd -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 20
}
'@ | Set-Content $stub -Encoding utf8
    $job = Start-ThreadJob -FilePath $stub -ArgumentList @($svc)
    $ready = Join-Path $svc 'stub-ready.txt'; $waited = 0
    while (-not (Test-Path $ready) -and $waited -lt 8000) { Start-Sleep -Milliseconds 100; $waited += 100 }
    if (-not (Test-Path $ready)) { throw 'mock DSS service did not start' }
    Start-Sleep -Milliseconds 300
    $args = @('-NoProfile','-File',(Join-Path $scripts 'ti_c2000_read_dma.ps1'),'-ProjectPath',$project,
        '-Mode','ReadOnly','-LatestFrame','-SeqVar','gDmaSeq','-BankVar','gDmaBank',
        '-Bank0Array','buffer0','-Bank1Array','buffer1','-Rows','1','-Columns','3','-LatestFrameTries','3','-CycleSamples','2')
    $result = @(& pwsh @args 2>&1)
    $rc = $LASTEXITCODE
    $text = (@($result | ForEach-Object { [string]$_ }) -join "`n")
    $csv = Join-Path $project 'readout/data/array.csv'
    $cycles = Join-Path $project 'readout/data/cycles.csv'
    $verdict = Join-Path $project 'readout/check/verdict.txt'
    if ($rc -ne 0 -or $text -notmatch 'ATTEMPT\s*:\s*2/3' -or
        -not (Test-Path $csv) -or (Get-Content $csv -Raw) -notmatch '0,20' -or
        -not (Test-Path $cycles) -or (Get-Content $cycles -Raw) -notmatch '0,0,0,,20' -or
        -not (Test-Path $verdict) -or (Get-Content $verdict -Raw) -notmatch 'result: OK') {
        throw ('latest-frame retry/bank selection failed: exit=' + $rc + ' ' + $text)
    }
    'RESULT: OK'; exit 0
} catch {
    'FAILURE: TEST_FAILED'; 'REASON: ' + $_.Exception.Message; 'RESULT: FAIL'; exit 1
} finally {
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

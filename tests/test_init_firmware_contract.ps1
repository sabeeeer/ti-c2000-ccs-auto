#requires -Version 7.0
# Offline regression for tools/init_firmware_contract.ps1. No CCS, no board.
# A tool that generates judgement symbols must never silently overwrite a counter
# someone wrote by hand, and must classify a wrong argument as USAGE/exit 2.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tool = Join-Path $root 'tools/init_firmware_contract.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('fwcontract-test-' + [guid]::NewGuid().ToString('N'))

function Invoke-Tool([string[]]$a) {
    $out = @(& pwsh @a 2>&1)
    return [ordered]@{ code = $LASTEXITCODE; text = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
}
function Write-Text([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function New-Project([string]$name, [string]$cmdText = 'MEMORY { ramgs1 : origin = 0xD000, length = 0x1000 }') {
    $p = Join-Path $fixture $name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Write-Text (Join-Path $p '.cproject') '<project/>'
    if ($cmdText) { Write-Text (Join-Path $p '2837xD_RAM_lnk_cpu1.cmd') $cmdText }
    return $p
}
function Assert($ok, $msg) { if (-not $ok) { throw $msg } }

try {
    # ---- 1. no .cproject => parameter error, exit 2 ------------------------
    $bare = Join-Path $fixture 'bare'
    New-Item -ItemType Directory -Force -Path $bare | Out-Null
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$bare)
    Assert ($r.code -eq 2 -and $r.text -match 'USAGE: NO_PROJECT') "NO_PROJECT not classified as USAGE/2`n$($r.text)"

    # ---- 2. default generation: all four modules, commented ---------------
    $p1 = New-Project 'full'
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p1)
    Assert ($r.code -eq 0 -and $r.text -match 'RESULT: OK') "generation failed`n$($r.text)"
    Assert ($r.text -match 'SKILL   : ti-c2000-ccs-auto@') 'no skill identity line'
    $hdr = [IO.File]::ReadAllText((Join-Path $p1 'ti_c2000_contract\ti_c2000_contract.h'))
    $src = [IO.File]::ReadAllText((Join-Path $p1 'ti_c2000_contract\ti_c2000_contract.c'))
    foreach ($s in @('gFwId','gMsTick','usMainLoop','gRamProofTick','gDmaSeq','gDmaHalf','gDmaReady')) {
        Assert ($hdr -match ('\b' + $s + '\b') -and $src -match ('\b' + $s + '\b')) "$s missing from generated module"
    }
    Assert ($hdr -match '这些不是业务数据，是判据' -and $hdr -match 'DATA JUDGEMENTS') 'generated header is not commented as judgements'
    Assert ($hdr -match 'gDmaHalf' -and $hdr -match '无法自己判断哪块缓冲最新') 'bank selector rationale missing'
    Assert ($src -match 'FUNC_CANNOT_INLINE' -and $src -match 'DATA_SECTION') 'RAM proof / DMA section pragmas missing'
    Assert ($src -match 'volatile unsigned long gFwId = 0x[0-9A-F]{8}UL') 'FW_ID not generated as a unique literal'

    # ---- 3. idempotent: a second run skips everything, gFwId unchanged ----
    $hash1 = (Get-FileHash -LiteralPath (Join-Path $p1 'ti_c2000_contract\ti_c2000_contract.h') -Algorithm SHA256).Hash
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p1)
    $hash2 = (Get-FileHash -LiteralPath (Join-Path $p1 'ti_c2000_contract\ti_c2000_contract.h') -Algorithm SHA256).Hash
    Assert ($r.code -eq 0 -and $r.text -match 'SKIP   : identity' -and $r.text -match 'SKIP   : dmaFrame') "second run did not skip`n$($r.text)"
    Assert ($hash1 -eq $hash2) 'second run overwrote the generated header'

    # ---- 4. hand-written counter is never overwritten ---------------------
    $p2 = New-Project 'conflict'
    Write-Text (Join-Path $p2 'User\main.c') 'volatile unsigned long gMsTick = 0;  /* user owned */'
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p2,'-Heartbeat')
    Assert ($r.code -eq 0 -and $r.text -match 'SKIP   : heartbeat - gMsTick in User.main.c') "existing counter not reported as SKIP`n$($r.text)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $p2 'ti_c2000_contract\ti_c2000_contract.h'))) 'tool generated a module despite a conflicting symbol'

    # ---- 5. missing DMA section is a real failure, not a silent placement -
    $p3 = New-Project 'nosection' 'MEMORY { RAM : origin = 0x20000000, length = 0x10000 }'
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p3,'-DmaFrame')
    Assert ($r.code -eq 1 -and $r.text -match 'FAILURE: DMA_SECTION_MISSING') "missing section not caught`n$($r.text)"

    # ---- 6. argument errors stay in the parameter category ---------------
    $p4 = New-Project 'args'
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p4,'-DmaSection','bad-section!')
    Assert ($r.code -eq 2 -and $r.text -match 'USAGE: BAD_SECTION_NAME') "bad section name not USAGE/2`n$($r.text)"
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p4,'-DmaRows','0')
    Assert ($r.code -eq 2 -and $r.text -match 'USAGE: BAD_DIMENSIONS') "bad rows not USAGE/2`n$($r.text)"

    # ---- 7. explicit module selection does not emit the others ------------
    $p5 = New-Project 'identityonly'
    $r = Invoke-Tool @('-NoProfile','-File',$tool,'-ProjectPath',$p5,'-Identity')
    Assert ($r.code -eq 0) "identity-only run failed`n$($r.text)"
    $src5 = [IO.File]::ReadAllText((Join-Path $p5 'ti_c2000_contract\ti_c2000_contract.c'))
    Assert ($src5 -match 'gFwId' -and $src5 -notmatch 'gDmaSeq' -and $src5 -notmatch 'gMsTick') 'explicit selection generated unrelated modules'

    'RESULT: OK'
    exit 0
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

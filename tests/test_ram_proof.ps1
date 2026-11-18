#requires -Version 7.0
# Offline behavior test for the firmware-side RAM proof. No target is contacted.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/ti_c2000_readmode.ps1')
$dir = Join-Path ([IO.Path]::GetTempPath()) ('c2000-ram-proof-' + [guid]::NewGuid().ToString('N'))
$script:updaterAddr = '0x00008010'
$script:counterAddr = '0x00008020'
$script:advance = $true
function Get-SessionExpressions {
    param([string]$ProjectPath,[string[]]$Exprs,[string]$Kind)
    if ($Kind -ne 'ADDR') { throw 'unexpected target request' }
    return @("P TiC2000_RamProofTick $script:updaterAddr", "P gRamProofTick $script:counterAddr")
}
function Test-AliveNow {
    param([string]$ProjectPath,[string[]]$Candidates)
    if ($script:advance) { return @{ ok=$true; name='gRamProofTick'; first='3'; last='4' } }
    return @{ ok=$false; reason='counter frozen' }
}
function Write-Map([string]$sectionAddress,[string]$sectionName='.text') {
    @"
MEMORY CONFIGURATION
  RAMLS0                00008000   00000800  00000700  00000100  RWIX
  FLASHA                00010000   00000800  00000700  00000100  RWIX
SECTION ALLOCATION MAP
 $sectionName             0    $sectionAddress    00000040
"@ | Set-Content -LiteralPath $mapPath
}
function Check([string]$label,[bool]$expected,[string]$code='') {
    $state.mapSha256 = (Get-FileHash -LiteralPath $mapPath -Algorithm SHA256).Hash
    $script:MemoryMapCache.Clear()
    $r = Get-RamProofEvidence -ProjectPath $dir -OutFile $outPath -MapFile $mapPath -SessionState $state
    if ($r.ok -ne $expected -or ($code -and $r.code -ne $code)) { throw "$label failed: $($r | ConvertTo-Json -Compress)" }
}
try {
    New-Item -ItemType Directory -Path $dir | Out-Null
    $outPath = Join-Path $dir 'app.out'
    $mapPath = Join-Path $dir 'app.map'
    Set-Content -LiteralPath $outPath -Value 'fixture'
    $state = @{ map=$mapPath; mapSha256='' }
    Write-Map '00008000'
    Check 'RAM updater and moving counter' $true
    Write-Map '00008000' '.text.2'
    Check 'split text section in RAM' $true
    Write-Map '00010000'
    Check 'Flash text reported, not refused' $true ''
    Write-Map '00008000'
    $script:updaterAddr = '0x00010010'
    Check 'Flash updater reported, not refused' $true ''
    $script:updaterAddr = '0x00008010'
    $script:advance = $false
    Check 'frozen counter reported, not refused' $true ''
    $script:advance = $true
    $state.mapSha256 = 'wrong'
    $r = Get-RamProofEvidence -ProjectPath $dir -OutFile $outPath -MapFile $mapPath -SessionState $state
    if ($r.code -ne 'STALE_MAP') { throw 'changed map was accepted' }
    'RESULT: OK'
} catch {
    'FAILURE: TEST_FAILED'
    'REASON: ' + $_.Exception.Message
    'RESULT: FAIL'
    exit 1
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

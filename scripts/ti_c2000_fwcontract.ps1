#requires -Version 7.0
<#
ti_c2000_fwcontract.ps1 -- the firmware side of the contract, read from one file.

references\firmware-contract.json is the single source of truth for the ONLY firmware
symbols this skill knows by name: the identity constant, the heartbeat counters, the rate
counter and the frozen-buffer trio. They used to be hard-coded in twelve places and had
already drifted (FrozenValue was 'true' in one script and '1' in another; the heartbeat
candidate sets differed in both membership and order).

Everything else about the target - memory map, Flash base, section layout, probe model - is
discovered at run time, never assumed. That distinction is the point: a contract you can
audit (tools/audit_fw_contract.ps1) versus knowledge that must be guessed.

The contract is mandatory at runtime. A missing or malformed file is a refusal: silently
using defaults would undo the audit and could weaken a read gate after a partial install.
#>

$script:FwContractCache = $null
$script:FwContractWarned = $false

function Get-FwContractPaths {
    $root = Split-Path $PSScriptRoot -Parent
    return @(
        (Join-Path $root 'references\firmware-contract.json')
    )
}

<#
Get-FwContract -- the parsed contract, cached for this process.

Fields: identity.var, heartbeat.candidates (array), rate.{var,perSec,tolerancePct},
frozenBuffer.{array,flag,flagValue,seq}. The shape is fixed here even when the file is
missing, so callers never have to null-check a field.
#>
function Get-FwContract {
    param([switch]$Quiet)

    if ($script:FwContractCache) { return $script:FwContractCache }

    # documented defaults: what the file would say if it existed
    $default = [ordered]@{
        identity     = [ordered]@{ var = 'gFwId' }
        ramProof     = [ordered]@{ counter = 'gRamProofTick'; updater = 'TiC2000_RamProofTick' }
        heartbeat    = [ordered]@{ candidates = @('gMsTick', 'usMainLoop', 'gRunMs') }
        rate         = [ordered]@{ var = 'gMsTick'; perSec = 1000; tolerancePct = 20 }
        frozenBuffer = [ordered]@{ array = 'gDmaFrameA'; flag = 'gDmaReady'; flagValue = '1'; seq = 'gDmaSeq' }
        readGate     = [ordered]@{ requireProbe = $true; requireLiveSession = $true; requireCompleteDssResponse = $true }
        dataVerdict  = [ordered]@{ checkOutSha256 = $true; checkSourceFreshness = $true; checkFirmwareIdentity = $true; checkHeartbeat = $true }
        sourceMetadata = [ordered]@{ reportRam = $true }
        timing       = [ordered]@{ minLoadGapMs = 5000; minReadGapMs = 400; minReconnectGapMs = 400 }
        source       = '(built-in defaults)'
    }

    $path = @(Get-FwContractPaths) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $path) {
        Write-Output 'FAILURE: FW_CONTRACT_MISSING'; Write-Output 'RESULT: FAIL'
        Write-Output 'REASON: references\firmware-contract.json is required'; exit 1
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Output 'FAILURE: FW_CONTRACT_INVALID'; Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: ' + $_.Exception.Message); exit 1
    }
    $invalid = New-Object System.Collections.Generic.List[string]
    if ([int]$raw.version -lt 4) { $invalid.Add('version < 4') }
    if (-not $raw.ramProof.counter -or -not $raw.ramProof.updater) { $invalid.Add('ramProof.counter/updater') }
    foreach ($key in @('requireProbe','requireLiveSession','requireCompleteDssResponse')) {
        if ($raw.readGate.$key -isnot [bool] -or -not $raw.readGate.$key) { $invalid.Add("readGate.$key") }
    }
    foreach ($key in @('checkOutSha256','checkSourceFreshness','checkFirmwareIdentity','checkHeartbeat')) {
        if ($raw.dataVerdict.$key -isnot [bool] -or -not $raw.dataVerdict.$key) { $invalid.Add("dataVerdict.$key") }
    }
    if ($raw.sourceMetadata.reportRam -isnot [bool] -or -not $raw.sourceMetadata.reportRam) { $invalid.Add('sourceMetadata.reportRam') }
    foreach ($pair in @(@('minLoadGapMs',5000),@('minReadGapMs',400),@('minReconnectGapMs',400))) {
        $v = 0
        if (-not [int]::TryParse([string]$raw.timing.($pair[0]),[ref]$v) -or $v -lt [int]$pair[1]) {
            $invalid.Add("timing.$($pair[0])")
        }
    }
    if ($invalid.Count -gt 0) {
        Write-Output 'FAILURE: FW_CONTRACT_INVALID'; Write-Output 'RESULT: FAIL'
        Write-Output ('REASON: missing or unsafe fields: ' + ($invalid -join ', ')); exit 1
    }

    # merge over the defaults, so a partial file still yields a complete shape
    $c = [ordered]@{
        identity = [ordered]@{ var = $(if ($raw.identity.var) { [string]$raw.identity.var } else { $default.identity.var }) }
        ramProof = [ordered]@{ counter = [string]$raw.ramProof.counter; updater = [string]$raw.ramProof.updater }
        heartbeat = [ordered]@{ candidates = @() }
        rate = [ordered]@{
            var          = $(if ($raw.rate.var) { [string]$raw.rate.var } else { $default.rate.var })
            perSec       = $(if ($raw.rate.perSec) { [double]$raw.rate.perSec } else { $default.rate.perSec })
            tolerancePct = $(if ($raw.rate.tolerancePct) { [double]$raw.rate.tolerancePct } else { $default.rate.tolerancePct })
        }
        frozenBuffer = [ordered]@{
            array      = $(if ($raw.frozenBuffer.array) { [string]$raw.frozenBuffer.array } else { $default.frozenBuffer.array })
            flag       = $(if ($raw.frozenBuffer.flag) { [string]$raw.frozenBuffer.flag } else { $default.frozenBuffer.flag })
            flagValue  = $(if ($null -ne $raw.frozenBuffer.flagValue) { [string]$raw.frozenBuffer.flagValue } else { $default.frozenBuffer.flagValue })
            seq        = $(if ($raw.frozenBuffer.seq) { [string]$raw.frozenBuffer.seq } else { $default.frozenBuffer.seq })
        }
        readGate = [ordered]@{
            requireProbe            = $true
            requireLiveSession      = $true
            requireCompleteDssResponse = $true
        }
        dataVerdict = $default.dataVerdict
        sourceMetadata = $default.sourceMetadata
        timing = [ordered]@{
            minLoadGapMs      = [int]$raw.timing.minLoadGapMs
            minReadGapMs      = [int]$raw.timing.minReadGapMs
            minReconnectGapMs = [int]$raw.timing.minReconnectGapMs
        }
        source = (Split-Path $path -Leaf)
    }

    $cands = @($raw.heartbeat.candidates | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $c.heartbeat.candidates = $(if ($cands.Count) { $cands } else { $default.heartbeat.candidates })
    foreach ($key in @('minLoadGapMs','minReadGapMs','minReconnectGapMs')) {
        if ($c.timing[$key] -le 0) { $c.timing[$key] = $default.timing[$key] }
    }

    $script:FwContractCache = $c
    return $script:FwContractCache
}

<# The heartbeat candidates as one comma-separated string, ready for -HeartbeatExpr. #>
function Get-FwHeartbeatExpr {
    param([switch]$Quiet)
    return ((Get-FwContract -Quiet:$Quiet).heartbeat.candidates -join ',')
}
